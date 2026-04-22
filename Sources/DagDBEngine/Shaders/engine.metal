// DagDB 4-cycle engine — Metal compute kernels.
//
// One epoch of the 4-cycle engine = one full pass through all four kernels
// over a ranked DagDB buffer resident in Apple-silicon unified memory.
//
// Node layout (matches Swift DagNode struct; see Core/DagDB.swift):
//   - id           : uint32   (index into the node table)
//   - rank         : uint32   (Queen = 0, Leaves = N; rank(src) < rank(dst))
//   - inputs[6]    : int32    (index of each input; -1 for absent)
//   - lut          : uint64   (LUT6 truth table; bit k = output for input pattern k)
//   - state        : int8     (ternary value: -1, 0, +1)
//   - active       : uint8    (flag: 1 if node is in the current wave-front, else 0)
//
// Buffers:
//   - nodes        : device DagNode*                       [nodeCount]
//   - activeCount  : device atomic_uint                    (per tick)
//   - entropyAcc   : device atomic_ulong                   (H(t) accumulator)
//
// All four kernels dispatch one thread per node; guards by rank band.

#include <metal_stdlib>
using namespace metal;

// ─────────────────────────────────────────────────────────────
// Node layout (must match DagNode in Swift — 64-byte alignment)
// ─────────────────────────────────────────────────────────────
struct DagNode {
    uint32_t  id;
    uint32_t  rank;
    int32_t   inputs[6];
    uint64_t  lut;          // LUT6 truth table; 64 entries, one bit each
    int8_t    state;        // ternary: -1, 0, +1
    uint8_t   active;       // wave-front membership
    uint8_t   _pad[2];
    uint32_t  _pad2[3];     // pad to 64 bytes total
};

// ─────────────────────────────────────────────────────────────
// LUT6 evaluation helper.
// Pack the six input bits (0 if state<=0, 1 if state>0) into an index,
// then read the corresponding bit from the 64-bit truth table.
// Inputs with index -1 are treated as 0 (input tied low).
// ─────────────────────────────────────────────────────────────
inline int8_t evalLUT6(device const DagNode* nodes,
                       const thread DagNode& n) {
    uint idx = 0;
    for (uint k = 0; k < 6; k++) {
        int32_t j = n.inputs[k];
        if (j < 0) continue;
        int8_t s = nodes[j].state;
        if (s > 0) idx |= (1u << k);
    }
    uint64_t bit = (n.lut >> idx) & 1ull;
    return bit ? (int8_t)+1 : (int8_t)0;
}

// ─────────────────────────────────────────────────────────────
// Kernel 1 — Forward wave.
// For each node in the current rank band, compute its new state from its
// inputs' states via LUT6 evaluation. Propagates from low rank (Queen)
// to high rank (Leaves).
// Dispatch: one thread per node; predicate on rank == waveRank.
// ─────────────────────────────────────────────────────────────
kernel void forwardWave(device DagNode*        nodes       [[buffer(0)]],
                        constant uint&         waveRank    [[buffer(1)]],
                        constant uint&         nodeCount   [[buffer(2)]],
                        uint                   gid         [[thread_position_in_grid]])
{
    if (gid >= nodeCount) return;
    DagNode local = nodes[gid];
    if (local.rank != waveRank) return;
    local.state  = evalLUT6(nodes, local);
    local.active = 1;
    nodes[gid]   = local;
}

// ─────────────────────────────────────────────────────────────
// Kernel 2 — Leaf mirror.
// At the leaf rank (waveRank == maxRank), copy each leaf's state to its
// mirror node. No entropy change; this is the reflection point of the
// forward wave into the backward wave.
// Dispatch: one thread per node; predicate on rank == maxRank.
// The mirror-leaf index equals gid + nodeCount (convention: mirror
// occupies the second half of the buffer).
// ─────────────────────────────────────────────────────────────
kernel void leafMirror(device DagNode*        nodes       [[buffer(0)]],
                       constant uint&         maxRank     [[buffer(1)]],
                       constant uint&         nodeCount   [[buffer(2)]],
                       uint                   gid         [[thread_position_in_grid]])
{
    if (gid >= nodeCount) return;
    DagNode leaf = nodes[gid];
    if (leaf.rank != maxRank) return;
    // Mirror node lives at gid + nodeCount, with rank = 2*maxRank - rank + 1
    uint mirrorIdx = gid + nodeCount;
    if (mirrorIdx >= 2 * nodeCount) return;
    DagNode mirror   = nodes[mirrorIdx];
    mirror.state     = leaf.state;
    mirror.active    = 1;
    nodes[mirrorIdx] = mirror;
}

// ─────────────────────────────────────────────────────────────
// Kernel 3 — Backward wave.
// Traverses the mirror half of the buffer from mirror-queen
// (rank maxRank+1) outward to mirror-leaves (rank 2*maxRank).
// Algorithm (V1): mirror-propagation.
//
// Each mirror node at index `gid` is paired with forward node at
// index `gid - nodeCount`. The backward wave copies the forward
// node's post-forward-wave state into the mirror pair. Combined
// with the leaf-mirror + queen-mirror phases, this produces an
// identity fold: the queen's computed answer persists across
// epochs, encoding the "ouroboros with rank monotonicity" — the
// wave completes one full cycle without rewriting the answer.
//
// V1 does NOT implement the 14 validation gates; those come in a
// future E2 increment. For now, the mirror carries the forward
// result faithfully and the fold is identity. Any validation
// algorithm in V2 will XOR or mask onto this baseline.
// ─────────────────────────────────────────────────────────────
kernel void backwardWave(device DagNode*       nodes       [[buffer(0)]],
                         constant uint&        waveRank    [[buffer(1)]],
                         constant uint&        nodeCount   [[buffer(2)]],
                         uint                  gid         [[thread_position_in_grid]])
{
    if (gid >= 2 * nodeCount) return;
    // Only process mirror-half nodes (indices in [nodeCount, 2*nodeCount)).
    if (gid < nodeCount) return;
    DagNode local = nodes[gid];
    if (local.rank != waveRank) return;
    uint fIdx = gid - nodeCount;
    local.state  = nodes[fIdx].state;
    local.active = 1;
    nodes[gid]   = local;
}

// ─────────────────────────────────────────────────────────────
// Kernel 4 — Queen mirror.
// At mirror-queen (rank 2*maxRank), fold the aggregated result back
// into a new query state for the next epoch. Rank advances here.
// Dispatch: a single thread (the mirror-queen node).
// ─────────────────────────────────────────────────────────────
kernel void queenMirror(device DagNode*        nodes       [[buffer(0)]],
                        constant uint&         queenMirrorIdx [[buffer(1)]],
                        constant uint&         queenIdx    [[buffer(2)]],
                        uint                   gid         [[thread_position_in_grid]])
{
    if (gid != 0) return;
    DagNode mirrorQueen = nodes[queenMirrorIdx];
    DagNode queen       = nodes[queenIdx];
    queen.state   = mirrorQueen.state;
    queen.active  = 1;
    nodes[queenIdx] = queen;
}

// ─────────────────────────────────────────────────────────────
// Instrumentation — Shannon-entropy contribution.
// Each node with state != 0 contributes log2(1 + degree) bits to H(t).
// (Placeholder model; real H(t) tracked via Swift-side observables.)
// ─────────────────────────────────────────────────────────────
kernel void entropyContribution(device DagNode*           nodes      [[buffer(0)]],
                                device atomic_uint*       acc        [[buffer(1)]],
                                constant uint&            nodeCount  [[buffer(2)]],
                                uint                      gid        [[thread_position_in_grid]])
{
    if (gid >= nodeCount) return;
    if (nodes[gid].state == 0) return;
    uint deg = 0;
    for (uint k = 0; k < 6; k++) {
        if (nodes[gid].inputs[k] >= 0) deg++;
    }
    // fixed-point bits: 1000 * log2(1 + deg) truncated.
    uint contrib = (uint)(1000.0f * log2(1.0f + (float)deg));
    atomic_fetch_add_explicit(acc, contrib, memory_order_relaxed);
}
