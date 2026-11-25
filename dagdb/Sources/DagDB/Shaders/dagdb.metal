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
// ── The UNDEFINED collapse, documented ──
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
// and a truth lattice for the inputs — a design change, not a repair.
//
// (2026-10-10: that design change
// now exists as a separate MODE — a TTABLE or TTHRESH node reads trits and
// writes −1/0/+1 below, in eval_ternary — and a BINARY node still takes
// this path, bit for bit, collapse included.)
inline uint8_t eval_lut6(uint32_t lut_low, uint32_t lut_high, uint8_t input_bits) {
    uint idx = uint(input_bits) & 0x3F;
    if (idx < 32) {
        return uint8_t((lut_low >> idx) & 1u);
    } else {
        return uint8_t((lut_high >> (idx - 32)) & 1u);
    }
}

// ── Ternary ──
// The mode lane: bits 0–1 the kind (0 BINARY, 1 TTABLE, 2 TTHRESH), bit 2
// NOSKIP. A BINARY node takes today's path, untouched, below.
constant uint8_t KIND_MASK   = 3;
constant uint8_t KIND_TTABLE = 1;
constant uint8_t NOSKIP_BIT  = 4;
constant uint     TABLE_SIZE  = 729;

// The trit view of any byte — 0 → −1, 1 → +1, 2 and ≥ 3 → 0.
inline int trit_of(uint8_t b) { return b == 0 ? -1 : (b == 1 ? 1 : 0); }
// A ternary node stores −1 as 0, 0 as 2, +1 as 1.
inline uint8_t byte_of(int t) { return t < 0 ? uint8_t(0) : (t > 0 ? uint8_t(1) : uint8_t(2)); }

// One ternary node's output byte. `src` is the truth array its pass reads
// (rank mode: the live array; sync mode: truth_in); `prev` its own previous
// byte (rank: before this evaluation; sync: truth_in). An absent slot
// (nb < 0 or nb ≥ node_count) reads 0 (TTABLE) / is skipped (TTHRESH).
inline uint8_t eval_ternary(
    device const uint8_t*   src,
    uint                    node,
    uint8_t                 mode,
    uint8_t                 prev,
    device const int32_t*   neighbors,
    uint                    node_count,
    device const uint16_t*  ttable_id,
    device const uint8_t*   ttables,
    uint                    ttable_count,
    device const float*     thr_lo,
    device const float*     thr_hi,
    device const float*     edge_weights
) {
    int computed;
    if ((mode & KIND_MASK) == KIND_TTABLE) {
        // TTABLE: index = Σ 3^d · (t_d + 1).
        uint idx = 0;
        uint p = 1;
        for (int d = 0; d < 6; d++) {
            int32_t nb = neighbors[node * 6 + d];
            int t = 0;
            if (nb >= 0 && uint(nb) < node_count) t = trit_of(src[nb]);
            idx += p * uint(t + 1);
            p *= 3;
        }
        uint tid = uint(ttable_id[node]);
        // tid ≥ the library size is refused on every write and load path;
        // the guard keeps the read inside the buffer if it ever happens.
        computed = tid < ttable_count ? trit_of(ttables[tid * TABLE_SIZE + idx]) : 0;
    } else {
        // TTHRESH: s = Σ w_d · t_d over present slots,
        // slot order 0…5, in float; +1 if s > hi, −1 if s < lo, else 0.
        float s = 0.0f;
        for (int d = 0; d < 6; d++) {
            int32_t nb = neighbors[node * 6 + d];
            if (nb < 0 || uint(nb) >= node_count) continue;
            s = s + edge_weights[node * 6 + d] * float(trit_of(src[nb]));
        }
        computed = s > thr_hi[node] ? 1 : (s < thr_lo[node] ? -1 : 0);
    }
    // NOSKIP: no direct −1 → +1; everything passes through 0.
    if ((mode & NOSKIP_BIT) != 0) {
        int p = trit_of(prev);
        if (p != 0 && computed == -p) computed = 0;
    }
    return byte_of(computed);
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
    device const uint8_t*   node_mode    [[ buffer(10) ]],
    device const uint16_t*  ttable_id    [[ buffer(11) ]],
    device const float*     thr_lo       [[ buffer(12) ]],
    device const float*     thr_hi       [[ buffer(13) ]],
    device const uint8_t*   ttables      [[ buffer(14) ]],
    constant uint32_t&      ttable_count [[ buffer(15) ]],
    device const float*     edge_weights [[ buffer(16) ]],
    uint                    gid          [[ thread_position_in_grid ]]
) {
    if (gid >= group_size) return;
    uint node = group[gid];
    // Every index this kernel dereferences is checked against the node
    // count, the same way dagdb_reset_rank and dagdb_tick_sync already do.
    // A neighbour index at or past node_count is reachable from an
    // unvalidated grid file, an unvalidated snapshot load, and the bulk
    // neighbour install; unchecked, it would be dereferenced.
    if (node >= node_count) return;

    // Only process nodes at the current rank being evaluated
    if (rank[node] != current_rank) return;

    // Skip BACK_EDGE destinations: their truth comes from the latch phase,
    // not from the combinational pass. Treating them as registers keeps
    // their state intact across rank evaluation.
    if (is_register[node] != 0) return;

    // Ternary kinds branch here; a BINARY node falls through to
    // today's LUT6 path below, unchanged.
    uint8_t mode = node_mode[node];
    if ((mode & KIND_MASK) != 0) {
        truth_state[node] = eval_ternary(truth_state, node, mode, truth_state[node],
                                         neighbors, node_count, ttable_id, ttables,
                                         ttable_count, thr_lo, thr_hi, edge_weights);
        return;
    }

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

// ── Binary-only fast path ──
// Dispatched instead of dagdb_tick_rank while the engine counts no non-binary
// node: the binary rank kernel with its original bindings, buffer(0…9) — no mode-lane
// read, none of the seven ternary buffers. On a binary-only graph every node
// takes dagdb_tick_rank's BINARY branch, so the two write the same bytes.
kernel void dagdb_tick_rank_binary(
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
    if (node >= node_count) return;
    if (rank[node] != current_rank) return;
    if (is_register[node] != 0) return;

    uint8_t input_bits = 0;
    for (int d = 0; d < 6; d++) {
        int32_t nb = neighbors[node * 6 + d];
        if (nb < 0 || uint(nb) >= node_count) continue;
        uint8_t nb_truth = truth_state[nb];
        uint8_t bit = (nb_truth == TRUTH_TRUE) ? 1u : 0u;
        input_bits |= (bit << d);
    }
    truth_state[node] = eval_lut6(lut6_low[node], lut6_high[node], input_bits);
}

// ── The counting twins of the two rank kernels ──
// Dispatched instead of dagdb_tick_rank / dagdb_tick_rank_binary only while
// a caller counts changes (TICK UNTIL_STABLE); every other tick dispatches
// the two kernels above, untouched. Same bindings plus buffer(17): one
// atomic counter, the number of nodes whose byte this pass changed (the new
// byte differs from the byte the node held when its thread read it). A node
// is written by one thread once per tick, so that is the pre-tick byte.
// Same guards, same reads, same byte written as the kernel it twins; the
// guards are nested instead of early returns so every thread reaches the
// SIMD-group sum, and one thread per SIMD group adds the group's count.
kernel void dagdb_tick_rank_counting(
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
    device const uint8_t*   node_mode    [[ buffer(10) ]],
    device const uint16_t*  ttable_id    [[ buffer(11) ]],
    device const float*     thr_lo       [[ buffer(12) ]],
    device const float*     thr_hi       [[ buffer(13) ]],
    device const uint8_t*   ttables      [[ buffer(14) ]],
    constant uint32_t&      ttable_count [[ buffer(15) ]],
    device const float*     edge_weights [[ buffer(16) ]],
    device atomic_uint*     changed      [[ buffer(17) ]],
    uint                    gid          [[ thread_position_in_grid ]]
) {
    uint did_change = 0;
    if (gid < group_size) {
        uint node = group[gid];
        if (node < node_count && rank[node] == current_rank && is_register[node] == 0) {
            uint8_t old = truth_state[node];
            uint8_t result;
            uint8_t mode = node_mode[node];
            if ((mode & KIND_MASK) != 0) {
                result = eval_ternary(truth_state, node, mode, old,
                                      neighbors, node_count, ttable_id, ttables,
                                      ttable_count, thr_lo, thr_hi, edge_weights);
            } else {
                uint8_t input_bits = 0;
                for (int d = 0; d < 6; d++) {
                    int32_t nb = neighbors[node * 6 + d];
                    if (nb < 0 || uint(nb) >= node_count) continue;
                    uint8_t bit = (truth_state[nb] == TRUTH_TRUE) ? 1u : 0u;
                    input_bits |= (bit << d);
                }
                result = eval_lut6(lut6_low[node], lut6_high[node], input_bits);
            }
            truth_state[node] = result;
            did_change = (result != old) ? 1u : 0u;
        }
    }
    uint group_changed = simd_sum(did_change);
    if (simd_is_first() && group_changed != 0) {
        atomic_fetch_add_explicit(changed, group_changed, memory_order_relaxed);
    }
}

kernel void dagdb_tick_rank_binary_counting(
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
    device atomic_uint*     changed      [[ buffer(17) ]],
    uint                    gid          [[ thread_position_in_grid ]]
) {
    uint did_change = 0;
    if (gid < group_size) {
        uint node = group[gid];
        if (node < node_count && rank[node] == current_rank && is_register[node] == 0) {
            uint8_t old = truth_state[node];
            uint8_t input_bits = 0;
            for (int d = 0; d < 6; d++) {
                int32_t nb = neighbors[node * 6 + d];
                if (nb < 0 || uint(nb) >= node_count) continue;
                uint8_t bit = (truth_state[nb] == TRUTH_TRUE) ? 1u : 0u;
                input_bits |= (bit << d);
            }
            uint8_t result = eval_lut6(lut6_low[node], lut6_high[node], input_bits);
            truth_state[node] = result;
            did_change = (result != old) ? 1u : 0u;
        }
    }
    uint group_changed = simd_sum(did_change);
    if (simd_is_first() && group_changed != 0) {
        atomic_fetch_add_explicit(changed, group_changed, memory_order_relaxed);
    }
}

// ── The back-edge latch on the GPU ──
// The plain latch (DagDBEngine.latchBackEdges) snapshots every back edge's
// source, then writes every destination, the last back edge into a
// destination winning. These kernels run over the EFFECTIVE back edges, one
// per distinct destination (its last back edge, in list order), built on the
// CPU when the back-edge list changes (DagDBEngine.LatchPlan). Each
// destination is written by one thread once, so no two writes conflict, and
// `changed` counts the destinations whose byte the latch changed, each once
// (the counting latch's count), one add per SIMD group. When no effective
// source is a destination, no thread reads a byte another writes and one
// kernel does it (dagdb_latch_direct); otherwise the snapshot and the writes
// are two dispatches, the plain latch's two phases.
//
// dagdb_latch_direct: thread j < stride takes entries j, j + stride, … (the
// engine dispatches one entry per thread: stride = count).
kernel void dagdb_latch_direct(
    device uint8_t*         truth_state [[ buffer(0) ]],
    device const uint32_t*  eff_src     [[ buffer(1) ]],
    device const uint32_t*  eff_dst     [[ buffer(2) ]],
    constant uint32_t&      count       [[ buffer(3) ]],
    device atomic_uint*     changed     [[ buffer(4) ]],
    constant uint32_t&      stride      [[ buffer(5) ]],
    uint                    gid         [[ thread_position_in_grid ]]
) {
    uint did_change = 0;
    if (gid < stride) {
        for (uint j = gid; j < count; j += stride) {
            uint8_t v = truth_state[eff_src[j]];
            uint d = eff_dst[j];
            uint8_t old = truth_state[d];
            truth_state[d] = v;
            did_change += (v != old) ? 1u : 0u;
        }
    }
    uint group_changed = simd_sum(did_change);
    if (simd_is_first() && group_changed != 0) {
        atomic_fetch_add_explicit(changed, group_changed, memory_order_relaxed);
    }
}

// Two phases, first: every effective source's byte, before any write.
kernel void dagdb_latch_snapshot(
    device const uint8_t*   truth_state [[ buffer(0) ]],
    device const uint32_t*  eff_src     [[ buffer(1) ]],
    device uint8_t*         scratch     [[ buffer(2) ]],
    constant uint32_t&      count       [[ buffer(3) ]],
    uint                    gid         [[ thread_position_in_grid ]]
) {
    if (gid >= count) return;
    scratch[gid] = truth_state[eff_src[gid]];
}

// Two phases, second: every destination from the snapshot.
kernel void dagdb_latch_write(
    device uint8_t*         truth_state [[ buffer(0) ]],
    device const uint32_t*  eff_dst     [[ buffer(1) ]],
    device const uint8_t*   scratch     [[ buffer(2) ]],
    constant uint32_t&      count       [[ buffer(3) ]],
    device atomic_uint*     changed     [[ buffer(4) ]],
    uint                    gid         [[ thread_position_in_grid ]]
) {
    uint did_change = 0;
    if (gid < count) {
        uint d = eff_dst[gid];
        uint8_t v = scratch[gid];
        uint8_t old = truth_state[d];
        truth_state[d] = v;
        did_change = (v != old) ? 1u : 0u;
    }
    uint group_changed = simd_sum(did_change);
    if (simd_is_first() && group_changed != 0) {
        atomic_fetch_add_explicit(changed, group_changed, memory_order_relaxed);
    }
}

// ── SET_LUTS … FILL | MAP by selection (DagDBEngine+SetLuts.swift) ──
// One thread per node of the dispatch: the id range (P[0] = 0: node P[3] +
// gid), a rank's per-rank list (1: list[gid], the buffer bound at the rank's span),
// or the rank lane (2: node gid, selected when P[4] <= rank <= P[5]). FILL
// (P[1] = 0) writes P[6]; MAP (1) reads the node's LUT once, ANDs it with the
// mask P[7] and writes the value P[25 + j] of the one key P[9 + j] (j < P[8])
// it equals — the value before the verb, so no pair's `to` is ever matched
// again (no chaining). Every node is written by one thread. counts[0] gets the
// nodes in the selection, counts[1] the nodes written, one add per SIMD group.
kernel void dagdb_set_luts(
    device uint32_t*        lut6_low    [[ buffer(0) ]],
    device uint32_t*        lut6_high   [[ buffer(1) ]],
    device const uint64_t*  rank        [[ buffer(2) ]],
    device const uint32_t*  list        [[ buffer(3) ]],
    constant uint64_t*      P           [[ buffer(4) ]],
    device atomic_uint*     counts      [[ buffer(5) ]],
    uint                    gid         [[ thread_position_in_grid ]]
) {
    uint sel = 0, wrote = 0;
    if (gid < uint(P[2])) {
        uint mode = uint(P[0]);
        uint i = gid;
        if (mode == 0u) { i = uint(P[3]) + gid; sel = 1u; }
        else if (mode == 1u) { i = list[gid]; sel = 1u; }
        else { uint64_t r = rank[gid]; sel = (r >= P[4] && r <= P[5]) ? 1u : 0u; }
        if (sel != 0u) {
            uint64_t old = (uint64_t(lut6_high[i]) << 32) | uint64_t(lut6_low[i]);
            uint64_t v = old;
            if (P[1] == 0) {
                v = P[6]; wrote = 1u;
            } else {
                uint64_t key = old & P[7];
                uint np = uint(P[8]);
                for (uint j = 0; j < np; ++j) {
                    if (key == P[9 + j]) { v = P[25 + j]; wrote = 1u; break; }
                }
            }
            if (wrote != 0u) {
                lut6_low[i] = uint32_t(v);
                lut6_high[i] = uint32_t(v >> 32);
            }
        }
    }
    uint s = simd_sum(sel), w = simd_sum(wrote);
    if (simd_is_first()) {
        if (s != 0u) atomic_fetch_add_explicit(&counts[0], s, memory_order_relaxed);
        if (w != 0u) atomic_fetch_add_explicit(&counts[1], w, memory_order_relaxed);
    }
}

// ── The frontier session ──
// Inside a frontier session (DagDBEngine.frontierSession, TICK UNTIL_STABLE)
// a rank-mode tick evaluates only the nodes that can change. The first tick
// of a session dispatches every rank and the latch whole (a plain tick that
// also records what it changed); every later tick dispatches, per rank, the
// nodes on that rank's worklist: readers (through a slot) of a node whose
// byte changed this tick at a higher rank, readers of a register the
// previous latch changed, NOSKIP nodes that changed in the previous tick, and
// the kernel-evaluated back-edge destinations (every tick). The latch writes
// only the effective back edges whose source changed since the previous
// latch's snapshot (and the evaluated destinations', every tick). A rank or
// a latch whose list holds more than its threshold is dispatched whole (the
// per-rank list, or every effective back edge). Every dispatched node is
// evaluated exactly as the counting kernels evaluate it (same guards, same
// reads, same byte), and its change is counted the same way.
//
// The push. A node whose byte changed appends each reader (the reverse
// index: CSR offsets per source, entries = reader node ids, or effective
// back-edge indices with bit 31 set) to that reader's rank list, once: a
// bit per node (per back edge) in this tick's bitmap, set by atomic OR; the
// thread that sets it takes a slot by an atomic add on the rank's count.
// Each rank's list lives at its per-rank span offset (a rank holds at most its
// span count of distinct nodes). Lists, bitmaps and counts come in two
// halves: `cur` is this tick's, 1 - cur the next tick's (NOSKIP self-dirty,
// readers of registers the latch changed, back edges fed by them). Every
// listed node is dispatched in this tick and clears its own bit; the args
// kernel zeroes a rank's count as it reads it — so at the end of a tick this
// tick's half is empty and becomes the next tick's next half.
//
// The session's
// first tick is whole (every args kernel takes the per-rank list), so nothing
// reads its half: there (p.push = 0) the rank and seed kernels push
// nothing into it. The pushes into the next half — a changed NOSKIP node,
// the readers of a register the latch changed and the back edges it feeds
// — are made on every tick, the first included, so tick 1's lists are
// what they were. The first tick's half stays as the session's open left
// it: every bit clear, every count zero.
//
// rinfo (per session, read-only), L = rank levels: [r] span offset,
//   [L + r] span count, [2L + r] whole threshold (whole iff listed > it),
//   [3L] the latch's whole threshold.
// cnt (atomic): [h·L + r] rank r's list length in half h; [2L + h] the
//   latch list's length in half h; [2L + 2] rank entries dispatched this
//   tick; [2L + 3] latch entries dispatched this tick.
// meta (written by the args kernels): [2r] whole, [2r + 1] entries for rank
//   r; [2L] / [2L + 1] the latch's; [2L + 2 + 3r …] rank r's indirect
//   threadgroups; [5L + 2 …] the latch's.
struct FrontierParams {
    uint rank;        // the rank this dispatch is for
    uint levels;      // rank levels the tick covers; ranks >= levels are never evaluated
    uint cur;         // this tick's half (0 or 1)
    uint full;        // 1 on the session's first tick: every rank and the latch whole
    uint tpg;         // threads per threadgroup of the dispatch an args kernel writes
    uint words;       // node bitmap words per half
    uint nodes;       // node list entries per half (the node count)
    uint edges;       // effective back edges (latch list entries per half)
    uint edge_words;  // latch bitmap words per half
    uint count;       // seed kernel: evaluated destinations
    uint push;        // 1 = a changed node pushes its readers into this tick's half;
                      //   0 on the session's first, whole tick, whose half nothing reads
};

inline void f2_push_node(uint u, uint hf, constant FrontierParams& p,
                         device const uint64_t* rank, device atomic_uint* bits,
                         device atomic_uint* cnt, device const uint* rinfo, device uint* lists) {
    uint64_t r = rank[u];
    if (r >= uint64_t(p.levels)) return;      // outside every rank list: never evaluated
    uint mask = 1u << (u & 31u);
    uint old = atomic_fetch_or_explicit(&bits[hf * p.words + (u >> 5)], mask, memory_order_relaxed);
    if ((old & mask) != 0) return;            // already listed
    uint ri = uint(r);
    uint pos = atomic_fetch_add_explicit(&cnt[hf * p.levels + ri], 1u, memory_order_relaxed);
    lists[hf * p.nodes + rinfo[ri] + pos] = u;
}

inline void f2_push_edge(uint e, uint hf, constant FrontierParams& p,
                         device atomic_uint* latch_bits, device atomic_uint* cnt, device uint* latch_list) {
    uint mask = 1u << (e & 31u);
    uint old = atomic_fetch_or_explicit(&latch_bits[hf * p.edge_words + (e >> 5)], mask, memory_order_relaxed);
    if ((old & mask) != 0) return;
    uint pos = atomic_fetch_add_explicit(&cnt[2u * p.levels + hf], 1u, memory_order_relaxed);
    latch_list[hf * p.edges + pos] = e;
}

// Every reader of `v` through a slot, and every effective back edge `v` feeds.
inline void f2_push_readers(uint v, uint hf, constant FrontierParams& p,
                            device const uint64_t* rank, device atomic_uint* bits,
                            device atomic_uint* cnt, device const uint* rinfo, device uint* lists,
                            device const uint* csr_off, device const uint* csr_ent,
                            device atomic_uint* latch_bits, device uint* latch_list) {
    uint a = csr_off[v], b = csr_off[v + 1];
    for (uint k = a; k < b; k++) {
        uint x = csr_ent[k];
        if ((x & 0x80000000u) != 0) {
            f2_push_edge(x & 0x7FFFFFFFu, hf, p, latch_bits, cnt, latch_list);
        } else {
            f2_push_node(x, hf, p, rank, bits, cnt, rinfo, lists);
        }
    }
}

// The push of one
// SIMD group, together. Lane i brings the CSR range [a_i, a_i + k_i) of the
// node whose readers it pushes (k_i = 0: none). The group's T = sum of k_i
// entries are walked 32 at a time, entry t by lane t mod 32 (its owner found
// by a binary search over the lanes' inclusive prefix sums), so a node's k
// readers are pushed by k lanes at once, not by one lane in k serial steps.
// Each entry is deduplicated by its half's bitmap exactly as f2_push_node and
// f2_push_edge do (one atomic OR); the entries new in a round then take
// their list slots with ONE atomic add per receiving list (rank r's, or the
// latch list's), each lane its slot by a prefix sum over the lanes with the
// same list. Every lane of the SIMD group calls it (uniform control flow:
// the frontier's threadgroups are whole SIMD groups of 32, checked when the
// pipelines are made).
constant uint H2_NONE = 0xFFFFFFFFu;
inline void h2_push_group(uint a, uint k, uint hf, ushort lane, constant FrontierParams& p,
                          device const uint64_t* rank, device atomic_uint* bits,
                          device atomic_uint* cnt, device const uint* rinfo, device uint* lists,
                          device const uint* csr_ent, device atomic_uint* latch_bits, device uint* latch_list) {
    uint incl = simd_prefix_inclusive_sum(k);
    uint total = simd_sum(k);
    uint excl = incl - k;
    for (uint t0 = 0u; t0 < total; t0 += 32u) {
        uint t = t0 + uint(lane);
        // The owner of entry t: the number of lanes whose inclusive sum is <= t (< 32 when t < total).
        uint j = 0u;
        for (uint s = 16u; s > 0u; s >>= 1u) {
            uint c = simd_shuffle(incl, ushort(j + s - 1u));
            j = (c <= t) ? j + s : j;
        }
        uint aj = simd_shuffle(a, ushort(j));
        uint ej = simd_shuffle(excl, ushort(j));
        uint tgt = H2_NONE, val = 0u;
        if (t < total) {
            uint x = csr_ent[aj + (t - ej)];
            if ((x & 0x80000000u) != 0u) {
                uint e = x & 0x7FFFFFFFu;
                uint mask = 1u << (e & 31u);
                uint old = atomic_fetch_or_explicit(&latch_bits[hf * p.edge_words + (e >> 5)], mask,
                                                    memory_order_relaxed);
                if ((old & mask) == 0u) { tgt = p.levels; val = e; }
            } else if (rank[x] < uint64_t(p.levels)) {      // outside every rank list: never evaluated
                uint mask = 1u << (x & 31u);
                uint old = atomic_fetch_or_explicit(&bits[hf * p.words + (x >> 5)], mask, memory_order_relaxed);
                if ((old & mask) == 0u) { tgt = uint(rank[x]); val = x; }
            }
        }
        // This round's new entries take their slots: one atomic add per receiving list.
        for (;;) {
            uint T = simd_min(tgt);
            if (T == H2_NONE) break;
            bool mine = tgt == T;
            uint before = simd_prefix_exclusive_sum(mine ? 1u : 0u);
            uint m = simd_sum(mine ? 1u : 0u);
            uint base = 0u;
            if (mine && before == 0u) {
                device atomic_uint* c = T == p.levels ? &cnt[2u * p.levels + hf] : &cnt[hf * p.levels + T];
                base = atomic_fetch_add_explicit(c, m, memory_order_relaxed);
            }
            base = simd_sum(base);                          // the first lane's; every other lane adds 0
            if (mine) {
                uint pos = base + before;
                if (T == p.levels) latch_list[hf * p.edges + pos] = val;
                else lists[hf * p.nodes + rinfo[T] + pos] = val;
                tgt = H2_NONE;
            }
        }
    }
}

// Clear one entry's bit in this tick's bitmap. A listed entry's bit is set;
// in a whole dispatch only the entries that were listed have theirs set.
inline void f2_clear_bit(uint i, uint whole, device atomic_uint* w) {
    uint mask = 1u << (i & 31u);
    if (whole == 0 || (atomic_load_explicit(w, memory_order_relaxed) & mask) != 0) {
        atomic_fetch_and_explicit(w, ~mask, memory_order_relaxed);
    }
}

// The kernel-evaluated back-edge destinations (register flag cleared), every
// tick: each is listed for its rank, its readers and the back edges it feeds
// are listed, and its own effective back edge is listed for the latch.
// `seeds`: (destination, its effective back edge) pairs.
kernel void dagdb_frontier_seed(
    device const uint64_t*  rank        [[ buffer(1) ]],
    constant FrontierParams& p          [[ buffer(7) ]],
    device uint*            lists       [[ buffer(8) ]],
    device atomic_uint*     bits        [[ buffer(9) ]],
    device atomic_uint*     cnt         [[ buffer(10) ]],
    device const uint*      rinfo       [[ buffer(11) ]],
    device const uint*      csr_off     [[ buffer(13) ]],
    device const uint*      csr_ent     [[ buffer(14) ]],
    device uint*            latch_list  [[ buffer(16) ]],
    device atomic_uint*     latch_bits  [[ buffer(17) ]],
    device const uint*      seeds       [[ buffer(19) ]],
    uint                    gid         [[ thread_position_in_grid ]],
    ushort                  lane        [[ thread_index_in_simdgroup ]]      // for the SIMD-group push
) {
    if (p.push == 0u) return;   // the whole first tick reads no list (uniform: every lane returns)
    uint pa = 0u, pk = 0u;      // the readers this lane brings to the group's push
    if (gid < p.count) {
        uint d = seeds[2u * gid], e = seeds[2u * gid + 1u];
        f2_push_node(d, p.cur, p, rank, bits, cnt, rinfo, lists);
        pa = csr_off[d]; pk = csr_off[d + 1u] - pa;
        f2_push_edge(e, p.cur, p, latch_bits, cnt, latch_list);
    }
    h2_push_group(pa, pk, p.cur, lane, p, rank, bits, cnt, rinfo, lists, csr_ent, latch_bits, latch_list);
}

// One thread, before rank p.rank's dispatch: that rank's list is final (only
// higher ranks push into it). Whole or listed, the entry count, the indirect
// threadgroups; the count is zeroed for the half's next use.
kernel void dagdb_frontier_rank_args(
    constant FrontierParams& p          [[ buffer(7) ]],
    device atomic_uint*     cnt         [[ buffer(10) ]],
    device const uint*      rinfo       [[ buffer(11) ]],
    device uint*            meta        [[ buffer(12) ]],
    uint                    gid         [[ thread_position_in_grid ]]
) {
    if (gid != 0) return;
    uint L = p.levels, r = p.rank;
    device atomic_uint* c = &cnt[p.cur * L + r];
    uint n = atomic_load_explicit(c, memory_order_relaxed);
    atomic_store_explicit(c, 0u, memory_order_relaxed);
    uint whole = (p.full != 0 || n > rinfo[2u * L + r]) ? 1u : 0u;
    uint m = whole != 0 ? rinfo[L + r] : n;
    meta[2u * r] = whole;
    meta[2u * r + 1u] = m;
    uint a = 2u * L + 2u + 3u * r;
    meta[a] = (m + p.tpg - 1u) / p.tpg;
    meta[a + 1u] = 1u;
    meta[a + 2u] = 1u;
    atomic_fetch_add_explicit(&cnt[2u * L + 2u], m, memory_order_relaxed);
}

// The same for the latch, after the last rank.
kernel void dagdb_frontier_latch_args(
    constant FrontierParams& p          [[ buffer(7) ]],
    device atomic_uint*     cnt         [[ buffer(10) ]],
    device const uint*      rinfo       [[ buffer(11) ]],
    device uint*            meta        [[ buffer(12) ]],
    uint                    gid         [[ thread_position_in_grid ]]
) {
    if (gid != 0) return;
    uint L = p.levels;
    device atomic_uint* c = &cnt[2u * L + p.cur];
    uint n = atomic_load_explicit(c, memory_order_relaxed);
    atomic_store_explicit(c, 0u, memory_order_relaxed);
    uint whole = (p.full != 0 || n > rinfo[3u * L]) ? 1u : 0u;
    uint m = whole != 0 ? p.edges : n;
    meta[2u * L] = whole;
    meta[2u * L + 1u] = m;
    uint a = 5u * L + 2u;
    meta[a] = (m + p.tpg - 1u) / p.tpg;
    meta[a + 1u] = 1u;
    meta[a + 2u] = 1u;
    atomic_fetch_add_explicit(&cnt[2u * L + 3u], m, memory_order_relaxed);
}

// Rank p.rank, the general kernel: the counting kernel's evaluation over the
// rank's list (or its per-rank list, whole), pushing the readers of every node
// whose byte changed, and a NOSKIP node that changed into the next tick.
kernel void dagdb_frontier_rank(
    device uint8_t*         truth_state  [[ buffer(0) ]],
    device const uint64_t*  rank         [[ buffer(1) ]],
    device const uint32_t*  lut6_low     [[ buffer(2) ]],
    device const uint32_t*  lut6_high    [[ buffer(3) ]],
    device const int32_t*   neighbors    [[ buffer(4) ]],
    device const uint8_t*   is_register  [[ buffer(5) ]],
    constant uint32_t&      node_count   [[ buffer(6) ]],
    constant FrontierParams& p           [[ buffer(7) ]],
    device uint*            lists        [[ buffer(8) ]],
    device atomic_uint*     bits         [[ buffer(9) ]],
    device atomic_uint*     cnt          [[ buffer(10) ]],
    device const uint*      rinfo        [[ buffer(11) ]],
    device const uint*      meta         [[ buffer(12) ]],
    device const uint*      csr_off      [[ buffer(13) ]],
    device const uint*      csr_ent      [[ buffer(14) ]],
    device const uint*      rank_list    [[ buffer(15) ]],
    device uint*            latch_list   [[ buffer(16) ]],
    device atomic_uint*     latch_bits   [[ buffer(17) ]],
    device atomic_uint*     changed      [[ buffer(18) ]],
    device const uint8_t*   node_mode    [[ buffer(19) ]],
    device const uint16_t*  ttable_id    [[ buffer(20) ]],
    device const float*     thr_lo       [[ buffer(21) ]],
    device const float*     thr_hi       [[ buffer(22) ]],
    device const uint8_t*   ttables      [[ buffer(23) ]],
    constant uint32_t&      ttable_count [[ buffer(24) ]],
    device const float*     edge_weights [[ buffer(25) ]],
    uint                    gid          [[ thread_position_in_grid ]],
    ushort                  lane         [[ thread_index_in_simdgroup ]]     // for the SIMD-group push
) {
    uint r = p.rank;
    uint whole = meta[2u * r], n = meta[2u * r + 1u];
    uint did_change = 0;
    uint pa = 0u, pk = 0u;      // the CSR range of readers this lane brings to the group's push
    if (gid < n) {
        uint off = rinfo[r];
        uint node = whole != 0 ? rank_list[off + gid] : lists[p.cur * p.nodes + off + gid];
        f2_clear_bit(node, whole, &bits[p.cur * p.words + (node >> 5)]);
        if (node < node_count && rank[node] == uint64_t(r) && is_register[node] == 0) {
            uint8_t old = truth_state[node];
            uint8_t result;
            uint8_t mode = node_mode[node];
            if ((mode & KIND_MASK) != 0) {
                result = eval_ternary(truth_state, node, mode, old,
                                      neighbors, node_count, ttable_id, ttables,
                                      ttable_count, thr_lo, thr_hi, edge_weights);
            } else {
                uint8_t input_bits = 0;
                for (int d = 0; d < 6; d++) {
                    int32_t nb = neighbors[node * 6 + d];
                    if (nb < 0 || uint(nb) >= node_count) continue;
                    uint8_t bit = (truth_state[nb] == TRUTH_TRUE) ? 1u : 0u;
                    input_bits |= (bit << d);
                }
                result = eval_lut6(lut6_low[node], lut6_high[node], input_bits);
            }
            truth_state[node] = result;
            if (result != old) {
                did_change = 1u;
                // Not on the session's first, whole tick (p.push = 0), whose half nothing reads.
                // Its readers are pushed by the SIMD group together, below.
                if (p.push != 0u) { pa = csr_off[node]; pk = csr_off[node + 1u] - pa; }
                // NOSKIP reads its own previous byte: it changed, so its next evaluation may differ.
                if ((mode & NOSKIP_BIT) != 0) {
                    f2_push_node(node, 1u - p.cur, p, rank, bits, cnt, rinfo, lists);
                }
            }
        }
    }
    h2_push_group(pa, pk, p.cur, lane, p, rank, bits, cnt, rinfo, lists, csr_ent, latch_bits, latch_list);   // the SIMD group's push
    uint group_changed = simd_sum(did_change);
    if (simd_is_first() && group_changed != 0) {
        atomic_fetch_add_explicit(changed, group_changed, memory_order_relaxed);
    }
}

// Rank p.rank, the binary-only kernel (no mode lane, no NOSKIP).
kernel void dagdb_frontier_rank_binary(
    device uint8_t*         truth_state  [[ buffer(0) ]],
    device const uint64_t*  rank         [[ buffer(1) ]],
    device const uint32_t*  lut6_low     [[ buffer(2) ]],
    device const uint32_t*  lut6_high    [[ buffer(3) ]],
    device const int32_t*   neighbors    [[ buffer(4) ]],
    device const uint8_t*   is_register  [[ buffer(5) ]],
    constant uint32_t&      node_count   [[ buffer(6) ]],
    constant FrontierParams& p           [[ buffer(7) ]],
    device uint*            lists        [[ buffer(8) ]],
    device atomic_uint*     bits         [[ buffer(9) ]],
    device atomic_uint*     cnt          [[ buffer(10) ]],
    device const uint*      rinfo        [[ buffer(11) ]],
    device const uint*      meta         [[ buffer(12) ]],
    device const uint*      csr_off      [[ buffer(13) ]],
    device const uint*      csr_ent      [[ buffer(14) ]],
    device const uint*      rank_list    [[ buffer(15) ]],
    device uint*            latch_list   [[ buffer(16) ]],
    device atomic_uint*     latch_bits   [[ buffer(17) ]],
    device atomic_uint*     changed      [[ buffer(18) ]],
    uint                    gid          [[ thread_position_in_grid ]],
    ushort                  lane         [[ thread_index_in_simdgroup ]]     // for the SIMD-group push
) {
    uint r = p.rank;
    uint whole = meta[2u * r], n = meta[2u * r + 1u];
    uint did_change = 0;
    uint pa = 0u, pk = 0u;      // the CSR range of readers this lane brings to the group's push
    if (gid < n) {
        uint off = rinfo[r];
        uint node = whole != 0 ? rank_list[off + gid] : lists[p.cur * p.nodes + off + gid];
        f2_clear_bit(node, whole, &bits[p.cur * p.words + (node >> 5)]);
        if (node < node_count && rank[node] == uint64_t(r) && is_register[node] == 0) {
            uint8_t old = truth_state[node];
            uint8_t input_bits = 0;
            for (int d = 0; d < 6; d++) {
                int32_t nb = neighbors[node * 6 + d];
                if (nb < 0 || uint(nb) >= node_count) continue;
                uint8_t bit = (truth_state[nb] == TRUTH_TRUE) ? 1u : 0u;
                input_bits |= (bit << d);
            }
            uint8_t result = eval_lut6(lut6_low[node], lut6_high[node], input_bits);
            truth_state[node] = result;
            if (result != old) {
                did_change = 1u;
                // Not on the session's first, whole tick (p.push = 0), whose half nothing reads.
                // Its readers are pushed by the SIMD group together, below.
                if (p.push != 0u) { pa = csr_off[node]; pk = csr_off[node + 1u] - pa; }
            }
        }
    }
    h2_push_group(pa, pk, p.cur, lane, p, rank, bits, cnt, rinfo, lists, csr_ent, latch_bits, latch_list);   // the SIMD group's push
    uint group_changed = simd_sum(did_change);
    if (simd_is_first() && group_changed != 0) {
        atomic_fetch_add_explicit(changed, group_changed, memory_order_relaxed);
    }
}

// The latch over the listed effective back edges (all of them, whole), one
// kernel when no effective source is a destination. A destination whose
// byte changed lists its readers for the next tick.
kernel void dagdb_frontier_latch_direct(
    device uint8_t*         truth_state  [[ buffer(0) ]],
    device const uint64_t*  rank         [[ buffer(1) ]],
    constant FrontierParams& p           [[ buffer(7) ]],
    device uint*            lists        [[ buffer(8) ]],
    device atomic_uint*     bits         [[ buffer(9) ]],
    device atomic_uint*     cnt          [[ buffer(10) ]],
    device const uint*      rinfo        [[ buffer(11) ]],
    device const uint*      meta         [[ buffer(12) ]],
    device const uint*      csr_off      [[ buffer(13) ]],
    device const uint*      csr_ent      [[ buffer(14) ]],
    device uint*            latch_list   [[ buffer(16) ]],
    device atomic_uint*     latch_bits   [[ buffer(17) ]],
    device atomic_uint*     changed      [[ buffer(18) ]],
    device const uint32_t*  eff_src      [[ buffer(26) ]],
    device const uint32_t*  eff_dst      [[ buffer(27) ]],
    uint                    gid          [[ thread_position_in_grid ]],
    ushort                  lane         [[ thread_index_in_simdgroup ]]     // for the SIMD-group push
) {
    uint L = p.levels;
    uint whole = meta[2u * L], n = meta[2u * L + 1u];
    uint did_change = 0;
    uint pa = 0u, pk = 0u;      // the CSR range of readers this lane brings to the group's push
    if (gid < n) {
        uint e = whole != 0 ? gid : latch_list[p.cur * p.edges + gid];
        f2_clear_bit(e, whole, &latch_bits[p.cur * p.edge_words + (e >> 5)]);
        uint8_t v = truth_state[eff_src[e]];
        uint d = eff_dst[e];
        uint8_t old = truth_state[d];
        truth_state[d] = v;
        if (v != old) {
            did_change = 1u;
            pa = csr_off[d]; pk = csr_off[d + 1u] - pa;   // pushed by the SIMD group, below
        }
    }
    h2_push_group(pa, pk, 1u - p.cur, lane, p, rank, bits, cnt, rinfo, lists, csr_ent, latch_bits, latch_list);   // the SIMD group's push
    uint group_changed = simd_sum(did_change);
    if (simd_is_first() && group_changed != 0) {
        atomic_fetch_add_explicit(changed, group_changed, memory_order_relaxed);
    }
}

// Two phases, first: every listed effective source's byte, before any write.
kernel void dagdb_frontier_latch_snapshot(
    device const uint8_t*   truth_state  [[ buffer(0) ]],
    constant FrontierParams& p           [[ buffer(7) ]],
    device const uint*      meta         [[ buffer(12) ]],
    device const uint*      latch_list   [[ buffer(16) ]],
    device const uint32_t*  eff_src      [[ buffer(26) ]],
    device uint8_t*         scratch      [[ buffer(28) ]],
    uint                    gid          [[ thread_position_in_grid ]]
) {
    uint L = p.levels;
    uint whole = meta[2u * L], n = meta[2u * L + 1u];
    if (gid >= n) return;
    uint e = whole != 0 ? gid : latch_list[p.cur * p.edges + gid];
    scratch[gid] = truth_state[eff_src[e]];
}

// Two phases, second: every listed destination from the snapshot; a changed
// destination lists its readers and the back edges it feeds for the next tick.
kernel void dagdb_frontier_latch_write(
    device uint8_t*         truth_state  [[ buffer(0) ]],
    device const uint64_t*  rank         [[ buffer(1) ]],
    constant FrontierParams& p           [[ buffer(7) ]],
    device uint*            lists        [[ buffer(8) ]],
    device atomic_uint*     bits         [[ buffer(9) ]],
    device atomic_uint*     cnt          [[ buffer(10) ]],
    device const uint*      rinfo        [[ buffer(11) ]],
    device const uint*      meta         [[ buffer(12) ]],
    device const uint*      csr_off      [[ buffer(13) ]],
    device const uint*      csr_ent      [[ buffer(14) ]],
    device uint*            latch_list   [[ buffer(16) ]],
    device atomic_uint*     latch_bits   [[ buffer(17) ]],
    device atomic_uint*     changed      [[ buffer(18) ]],
    device const uint32_t*  eff_dst      [[ buffer(27) ]],
    device const uint8_t*   scratch      [[ buffer(28) ]],
    uint                    gid          [[ thread_position_in_grid ]],
    ushort                  lane         [[ thread_index_in_simdgroup ]]     // for the SIMD-group push
) {
    uint L = p.levels;
    uint whole = meta[2u * L], n = meta[2u * L + 1u];
    uint did_change = 0;
    uint pa = 0u, pk = 0u;      // the CSR range of readers this lane brings to the group's push
    if (gid < n) {
        uint e = whole != 0 ? gid : latch_list[p.cur * p.edges + gid];
        f2_clear_bit(e, whole, &latch_bits[p.cur * p.edge_words + (e >> 5)]);
        uint d = eff_dst[e];
        uint8_t v = scratch[gid];
        uint8_t old = truth_state[d];
        truth_state[d] = v;
        if (v != old) {
            did_change = 1u;
            pa = csr_off[d]; pk = csr_off[d + 1u] - pa;   // pushed by the SIMD group, below
        }
    }
    h2_push_group(pa, pk, 1u - p.cur, lane, p, rank, bits, cnt, rinfo, lists, csr_ent, latch_bits, latch_list);   // the SIMD group's push
    uint group_changed = simd_sum(did_change);
    if (simd_is_first() && group_changed != 0) {
        atomic_fetch_add_explicit(changed, group_changed, memory_order_relaxed);
    }
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
    device const uint8_t*   node_mode    [[ buffer(7) ]],
    device const uint16_t*  ttable_id    [[ buffer(8) ]],
    device const float*     thr_lo       [[ buffer(9) ]],
    device const float*     thr_hi       [[ buffer(10) ]],
    device const uint8_t*   ttables      [[ buffer(11) ]],
    constant uint32_t&      ttable_count [[ buffer(12) ]],
    device const float*     edge_weights [[ buffer(13) ]],
    uint                    gid          [[ thread_position_in_grid ]]
) {
    if (gid >= node_count) return;
    // Registers hold: their next value comes from the latch phase,
    // exactly as in rank mode.
    if (is_register[gid] != 0) { truth_out[gid] = truth_in[gid]; return; }
    uint8_t mode = node_mode[gid];
    if ((mode & KIND_MASK) != 0) {
        truth_out[gid] = eval_ternary(truth_in, gid, mode, truth_in[gid],
                                      neighbors, node_count, ttable_id, ttables,
                                      ttable_count, thr_lo, thr_hi, edge_weights);
        return;
    }
    uint8_t input_bits = 0;
    for (int d = 0; d < 6; d++) {
        int32_t nb = neighbors[gid * 6 + d];
        // The bound the rank kernel already has — an out-of-range
        // slot is exactly an empty slot.
        if (nb < 0 || uint(nb) >= node_count) continue;
        uint8_t bit = (truth_in[nb] == TRUTH_TRUE) ? 1u : 0u;
        input_bits |= (bit << d);
    }
    truth_out[gid] = eval_lut6(lut6_low[gid], lut6_high[gid], input_bits);
}

// ── Binary-only fast path, sync mode ──
// The binary sync kernel with its original bindings, buffer(0…6), plus the
// `nb ≥ node_count` bound (the general kernel's; it keeps the two equal on
// every graph). No mode-lane read, no ternary buffers.
kernel void dagdb_tick_sync_binary(
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
    if (is_register[gid] != 0) { truth_out[gid] = truth_in[gid]; return; }
    uint8_t input_bits = 0;
    for (int d = 0; d < 6; d++) {
        int32_t nb = neighbors[gid * 6 + d];
        if (nb < 0 || uint(nb) >= node_count) continue;
        uint8_t bit = (truth_in[nb] == TRUTH_TRUE) ? 1u : 0u;
        input_bits |= (bit << d);
    }
    truth_out[gid] = eval_lut6(lut6_low[gid], lut6_high[gid], input_bits);
}
