#include <metal_stdlib>
using namespace metal;

// ═══════════════════════════════════════════════════════════════
// DagDB — 6-Bounded Ranked DAG Evaluator
// Forked from savanna.metal, generalized for logical reasoning.
// ═══════════════════════════════════════════════════════════════

// ── Truth states ──
constant uint8_t TRUTH_FALSE     = 0;
constant uint8_t TRUTH_TRUE      = 1;
constant uint8_t TRUTH_UNDEFINED = 2;  // Paradox Horizon (Gemini Deep Think)

// ── Node types ──
constant uint8_t NODE_REAL    = 0;
constant uint8_t NODE_VIRTUAL = 1;  // Hub split (6-ary fractal fan-in)
constant uint8_t NODE_GHOST   = 2;  // Skip-connection identity padding

// ── LUT6 evaluation (the core primitive) ──
// Given 6 input truth values as a 6-bit index (0-63),
// return the output from the 64-bit programmable LUT.
//
// ── The UNDEFINED collapse, documented (audit A, finding 20) ──
// This returns ONE BIT, and every tick writes 0 or 1 into truth_state,
// while the truth state is tri-valued (TRUTH_UNDEFINED = 2 above, and
// DagDBState.swift's doc). So a node holding UNDEFINED is collapsed to
// FALSE by the next tick, in rank mode and in sync mode alike. The only
// writer of 2 is DagDBEngine+Graph.tickWithResonance, at the
// maxMicroTicks edge, and nothing preserves it after the following tick.
//
// This is the kernel's SEMANTICS, not an oversight, and it is written
// down here rather than left to be rediscovered: an input's UNDEFINED is
// read as 0 for the LUT index (see the gather loop below), and an
// output is TRUE or FALSE. Preserving it would need a two-bit LUT result
// and a truth lattice for the inputs — a design change, not a repair —
// and the core-durability contract's "not promised" list rules it out of
// that pass on purpose.
inline uint8_t eval_lut6(uint32_t lut_low, uint32_t lut_high, uint8_t input_bits) {
    uint idx = uint(input_bits) & 0x3F;
    if (idx < 32) {
        return uint8_t((lut_low >> idx) & 1u);
    } else {
        return uint8_t((lut_high >> (idx - 32)) & 1u);
    }
}

// ── Tick kernel: evaluate all nodes at a specific rank ──
// Called once per (rank, color) combination. Within a color group,
// all nodes are non-adjacent (7-coloring) → safe parallel update.
// ── Weighted activation (continuous mode) ──
// Sum of (neighbor_truth * edge_weight), compared against threshold.
// When edge weights are all 1.0 and threshold is 0, behaves like Boolean mode.
inline float weighted_activation(
    device const uint8_t* truth_state,
    device const float* edge_weights,
    device const int32_t* neighbors,
    uint node
) {
    float sum = 0.0;
    for (int d = 0; d < 6; d++) {
        int32_t nb = neighbors[node * 6 + d];
        if (nb < 0) continue;
        float w = edge_weights[node * 6 + d];
        float val = (truth_state[nb] == TRUTH_TRUE) ? 1.0 :
                    (truth_state[nb] == TRUTH_UNDEFINED) ? 0.5 : 0.0;
        sum += val * w;
    }
    return sum;
}

kernel void dagdb_tick_rank(
    device uint8_t*         truth_state  [[ buffer(0) ]],
    device const uint64_t*  rank         [[ buffer(1) ]],
    device const uint32_t*  lut6_low     [[ buffer(2) ]],
    device const uint32_t*  lut6_high    [[ buffer(3) ]],
    device const int32_t*   neighbors    [[ buffer(4) ]],
    device const uint32_t*  group        [[ buffer(5) ]],
    constant uint32_t&      group_size   [[ buffer(6) ]],
    constant uint64_t&      current_rank [[ buffer(7) ]],
    device const uint8_t*   is_register  [[ buffer(8) ]],
    constant uint32_t&      node_count   [[ buffer(9) ]],
    uint                    gid          [[ thread_position_in_grid ]]
) {
    if (gid >= group_size) return;
    uint node = group[gid];
    // C4 · every index this kernel dereferences is checked against the node
    // count, the same way dagdb_reset_rank and dagdb_tick_sync already do.
    // A neighbour index at or past node_count is reachable from an
    // unvalidated grid file, an unvalidated snapshot load, and the bulk
    // neighbour install; it used to be dereferenced (audit A, finding 19).
    if (node >= node_count) return;

    // Only process nodes at the current rank being evaluated
    if (rank[node] != current_rank) return;

    // Skip BACK_EDGE destinations: their truth comes from the latch phase,
    // not from the combinational pass. Treating them as registers keeps
    // their state intact across rank evaluation.
    if (is_register[node] != 0) return;

    // Gather 6 input bits from neighbors
    uint8_t input_bits = 0;
    for (int d = 0; d < 6; d++) {
        int32_t nb = neighbors[node * 6 + d];
        // An out-of-range slot is exactly an empty slot.
        if (nb < 0 || uint(nb) >= node_count) continue;

        uint8_t nb_truth = truth_state[nb];
        // Treat UNDEFINED as 0 for LUT input (paradox horizon propagation)
        uint8_t bit = (nb_truth == TRUTH_TRUE) ? 1u : 0u;
        input_bits |= (bit << d);
    }

    // Evaluate LUT6 → new truth state
    uint8_t result = eval_lut6(lut6_low[node], lut6_high[node], input_bits);
    truth_state[node] = result;
}

// ── Weighted tick kernel (continuous mode) ──
// Uses edge weights for weighted sum activation instead of Boolean LUT.
kernel void dagdb_tick_weighted(
    device uint8_t*         truth_state  [[ buffer(0) ]],
    device const uint64_t*  rank         [[ buffer(1) ]],
    device const float*     edge_weights [[ buffer(2) ]],
    device const int32_t*   neighbors    [[ buffer(3) ]],
    device const uint32_t*  group        [[ buffer(4) ]],
    constant uint32_t&      group_size   [[ buffer(5) ]],
    constant uint64_t&      current_rank [[ buffer(6) ]],
    constant float&         threshold    [[ buffer(7) ]],
    device const uint8_t*   is_register  [[ buffer(8) ]],
    uint                    gid          [[ thread_position_in_grid ]]
) {
    if (gid >= group_size) return;
    uint node = group[gid];
    if (rank[node] != current_rank) return;
    if (is_register[node] != 0) return;

    float activation = weighted_activation(truth_state, edge_weights, neighbors, node);

    // Threshold: activation >= threshold → TRUE, else FALSE
    truth_state[node] = (activation >= threshold) ? TRUTH_TRUE : TRUTH_FALSE;
}

// ── Reset kernel: clear truth states (optional, for fresh evaluation) ──
kernel void dagdb_reset_rank(
    device uint8_t*         truth_state  [[ buffer(0) ]],
    device const uint64_t*  rank         [[ buffer(1) ]],
    constant uint64_t&      current_rank [[ buffer(2) ]],
    constant uint32_t&      node_count   [[ buffer(3) ]],
    uint                    gid          [[ thread_position_in_grid ]]
) {
    if (gid >= node_count) return;
    if (rank[gid] == current_rank) {
        truth_state[gid] = TRUTH_FALSE;
    }
}

kernel void dagdb_tick_sync(
    device const uint8_t*   truth_in     [[ buffer(0) ]],
    device uint8_t*         truth_out    [[ buffer(1) ]],
    device const uint32_t*  lut6_low     [[ buffer(2) ]],
    device const uint32_t*  lut6_high    [[ buffer(3) ]],
    device const int32_t*   neighbors    [[ buffer(4) ]],
    device const uint8_t*   is_register  [[ buffer(5) ]],
    constant uint32_t&      node_count   [[ buffer(6) ]],
    uint                    gid          [[ thread_position_in_grid ]]
) {
    if (gid >= node_count) return;
    // Registers hold: their next value comes from the latch phase,
    // exactly as in rank mode.
    if (is_register[gid] != 0) { truth_out[gid] = truth_in[gid]; return; }
    uint8_t input_bits = 0;
    for (int d = 0; d < 6; d++) {
        int32_t nb = neighbors[gid * 6 + d];
        if (nb < 0) continue;
        uint8_t bit = (truth_in[nb] == TRUTH_TRUE) ? 1u : 0u;
        input_bits |= (bit << d);
    }
    truth_out[gid] = eval_lut6(lut6_low[gid], lut6_high[gid], input_bits);
}
