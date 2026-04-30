# BACK_EDGE — typed return-edges for synchronous-circuit recurrence

> Amateur engineering project. No competitive claims. Errors likely.

DagDB's primary edges are forward-only and rank-monotone — the DAG
property. **BACK_EDGEs are a second edge type** that is exempt from
rank monotonicity. They're never followed during the combinational
pass. At the tick boundary, a separate latch phase walks the
back-edge list and copies each source's truth value into its
destination. The destination behaves like a synchronous-circuit
register: its truth comes from the latch, not from a LUT6 evaluation.

This is the substrate that lets DagDB host iterative algorithms
natively — belief propagation to convergence, AC-3 arc consistency,
Hopfield-style recall, Boolean cellular automata with feedback,
synchronous-circuit emulation, and the harmonic-solver's epoch loop.

---

## Tick semantics

Every `TICK 1` runs in two phases, in order:

1. **Combinational pass.** Rank-ordered evaluation, leaves-up. Each
   node at the current rank computes its truth from its
   `inputs[6]` via its LUT6. Back-edges are ignored.
2. **Latch phase.** For every registered back-edge, copy
   `truth[src] → truth[dst]`. Two-phase semantics: every source's
   pre-tick truth is snapshotted first, then every destination is
   written. Chained back-edges (one entry's dst is another entry's
   src) latch from pre-tick state, never from values written
   earlier in the same latch pass.

Readers see consistent state at tick boundaries — both phases happen
inside one `tick()` call before the result is observable.

---

## Register pattern

A node that is the destination of any back-edge is treated as a
**register**. The combinational kernel skips it:

```c
if (is_register[node] != 0) return;   // node's truth comes only from the latch
```

Registers must have **zero combinational fan-in**. The invariant is
two-sided:

- `CONNECT BACK FROM <s> TO <d>` rejects if `d` already has any
  combinational input slot occupied.
- `CONNECT FROM <s> TO <d>` rejects if `d` is currently a
  back-edge destination.

To convert a register back to a regular gate, `CLEAR <d> BACK_EDGES`
drops every back-edge into `d` and clears the register flag.

---

## DSL surface

```
CONNECT BACK FROM <src> TO <dst>
  → register a back-edge: latch truth[src] into truth[dst] every tick.
  → fails with `ERROR schema: back_edge_violation: …` if dst has
    combinational fan-in.

CLEAR <node> BACK_EDGES
  → remove every back-edge whose destination is <node>; clears the
    register flag. Mirror of CLEAR <node> EDGES (combinational).

GET <node> TRUTH
  → return one node's current truth as plain text:
    `OK GET node=<n> truth=<v>`.  Cheap socket-only readback for
    clients that don't have shm access.

SET <node> LUT 0x<hex>
  → existing SET LUT verb now also accepts a 64-bit hex literal
    when the truth table doesn't match a named preset (useful for
    fan-in 4 and 5 AND-gates that don't have AND4 / AND5 presets).
```

The Python MCP server exposes `dagdb_connect_back` and
`dagdb_clear_back_edges` over the same bridge.

---

## Persistence

- **WAL** — two new opcodes: `0x10 CONNECT_BACK` (u32 src + u32 dst,
  payload 8 B) and `0x11 CLEAR_BACK_EDGES` (u32 dst, payload 4 B).
  Replay reconstructs the back-edge buffer; checkpoint boundary
  semantics are the same as for other opcodes.
- **Snapshot v4** — appends a back-edge trailer after the body:
  `u32 backEdgeCount` followed by `count × (u32 src, u32 dst)`. The
  trailer is always uncompressed; the existing `flags` compressed
  bit refers only to the v3 body. Load accepts v1, v2, v3 (back-edge
  list defaults empty), and v4. Save always writes v4.
- **MVCC reader sessions** — back-edge mutations are writes; rejected
  inside reader sessions like other mutations. Readers see the
  post-latch state of their snapshot tick.

---

## Worked example: 1-bit toggle

The simplest non-trivial circuit: a register whose next state is
its own NOT, driven through a back-edge. Truth flips 0/1/0/1 every
tick.

```
# register at rank 1 (combinational fan-in = 0).  LUT preset doesn't
# matter — register flag will skip it on the rank pass.
SET 0 RANK 1
SET 0 LUT IDENTITY
SET 0 TRUTH 0

# combinational NOT of the register, at rank 0.  LUT for "NOT input0"
# is bit k = 1 iff (k & 1) == 0 → 0x5555…5555.
SET 1 RANK 0
SET 1 LUT 0x5555555555555555
CONNECT FROM 0 TO 1

# back-edge: latch comb's truth into the register every tick.
CONNECT BACK FROM 1 TO 0

TICK 1
GET 0 TRUTH      # → OK GET node=0 truth=1
TICK 1
GET 0 TRUTH      # → OK GET node=0 truth=0
TICK 1
GET 0 TRUTH      # → OK GET node=0 truth=1
```

Running tests for AC-3 Australia (3-coloring with WA pre-assigned to
red) live in `examples/ac3_australia/`. The encoding spec there
(`dagdb_encoding_spec.md`) walks through 21 register + 54 support +
21 keep nodes — the next non-trivial example after the toggle.

---

## When NOT to use BACK_EDGE

- Pure feedforward decision trees — the rank-monotone DAG already
  handles those. Adding back-edges is overhead with no benefit.
- Patterns where the destination needs combinational inputs *plus*
  a latch from another node. Registers must have zero combinational
  fan-in by construction; if you need both, introduce an intermediate
  combinational node and back-edge from the intermediate.

---

## Verification

Three reference demos shipped under `examples/`:

1. **1-bit toggle.** One register fed by a `NOT` of itself via a
   back-edge. The truth value flips `0 → 1 → 0 → 1` over six ticks.
   Smallest possible test of the latch.
2. **4-bit ripple counter.** Four registers + standard binary-counter
   carry logic (`next_Q0 = NOT Q0`, `next_Q1 = Q1 ⊕ Q0`,
   `next_Q2 = Q2 ⊕ (Q1 ∧ Q0)`, `next_Q3 = Q3 ⊕ (Q2 ∧ Q1 ∧ Q0)`).
   Counts `0 → 15 → 0` (wraps) over 17 ticks. Tests fan-in into
   registers in slot order, multi-back-edge correctness, and the
   two-phase latch under chained reads.
3. **AC-3 Australia 3-coloring.** 21 register + 54 support + 21 keep
   nodes encoding the canonical Russell-Norvig AC-3 example with
   WA pre-assigned to red. Per-tick truth values are compared
   one-for-one against `examples/ac3_australia/reference_ac3.py`
   (a pure-Python synchronous AC-3 implementation). Converges in 2
   ticks; the verifier `examples/ac3_australia/verify.py` exits 0
   when DagDB matches the reference cell-by-cell.

Test suite landed at **120 Swift tests green** (was 104; +16 for the
back-edge work — engine state and CPU latch, GPU rank-skip integration,
two-phase chained-aliasing semantics, validation rejection paths on
both `CONNECT BACK` and `CONNECT`, WAL replay including
`CHECKPOINT`-survival, snapshot v3 → v4 round-trip).

---

## Out of scope (deferred to v2)

- **Transform-LUTs on registers.** Today's latch is a pure copy of
  `truth[src]` into `truth[dst]`. A v2 could let the back-edge apply
  a per-edge LUT (`saturating counter`, `edge detector`,
  `inverter-on-write`) during the latch. Deferred until a workload
  asks for it.
- **GPU latch kernel.** Currently the latch is a CPU loop over the
  unified-memory `truthState` buffer. Back-edge counts are small
  relative to combinational edges in every workload tested so far
  (AC-3: 21 back-edges vs 183 combinational; 200×200 slime mold:
  40 K back-edges vs 200 K combinational, latch is sub-millisecond
  per tick). When that ratio inverts, a Metal `dagdb_latch_back_edges`
  kernel becomes worth writing.

---

## Backward compatibility

- **v3 snapshot files** load unchanged on a v4-aware engine. The
  back-edge list is reset to empty on load.
- **Graphs with no back-edges** are bit-for-bit identical between v3
  and v4 save/load — the v4 trailer is just `count=0`.
- The rank kernel reads an `is_register` buffer that defaults to all
  zeros, so the per-tick combinational evaluation is unaffected on
  graphs that don't use back-edges. No regression on existing
  benchmarks.
- Engine's public `addBackEdge(src:dst:)` is `throws`; the previous
  signature didn't exist, so this is additive — no source-level
  break.

---

## Internals

- `is_register[]` — UInt8 per node. Set to 1 when the node becomes a
  back-edge destination. Read by `dagdb_tick_rank` and
  `dagdb_tick_weighted`; both kernels short-circuit when set.
- `backEdgeSrcs[]` / `backEdgeDsts[]` — parallel UInt32 arrays on
  `DagDBEngine`. CPU-side, not yet on the GPU (the latch is a CPU
  loop on the unified-memory `truthState` buffer; back-edge counts
  are small relative to combinational graphs at the scales we care
  about today). Stretch goal: a Metal `dagdb_latch_back_edges`
  kernel for the case where back-edge count rivals node count.
- `addBackEdgeUnchecked(src:dst:)` — internal-access shortcut used by
  the WAL replay path and direct-state perf scaffolds. Skips the
  combinational fan-in check; only callers that have already
  validated (or are loading from a previously-validated WAL/snapshot)
  should use it.
