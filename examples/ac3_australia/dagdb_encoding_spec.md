# DagDB encoding spec — AC-3 Australia on BACK_EDGE

Implementation spec. Translate this directly into DSL calls
(or programmatic engine setup); the only judgement calls are node-
ID layout choices and test plumbing.

The Python reference (`reference_ac3.py`) converges in 2 synchronous
ticks. Your DagDB encoding must match this trajectory tick-by-tick.

---

## 1. Node count

96 nodes total:
- **21 register nodes** — one per (region, color) pair. 7 regions ×
  3 colors. Truth value = "this color is still in this region's
  domain."
- **54 support nodes** — combinational. One per (region, color,
  neighbor) triple. Computes "this neighbor has at least one color
  different from `color`."
- **21 keep nodes** — combinational. One per (region, color).
  Computes "this color survives this round" = current domain bit AND
  all neighbor supports.

T (Tasmania) has no neighbors. T's keep nodes are identity copies of
T's register nodes — three trivial keep nodes, no support nodes for
T.

Recompute the count: WA(2) + NT(3) + SA(5) + Q(3) + NSW(3) + V(2) +
T(0) = 18 region-neighbor edge-half pairs × 3 colors = 54 support
nodes. Confirmed.

## 2. Node ID layout (suggested)

Linear scheme — choose differently if you like, as long as VALIDATE
passes:

| ID range | Role | Count |
|---|---|---|
| 0–20  | register nodes (domain bits) | 21 |
| 21–74 | support nodes | 54 |
| 75–95 | keep nodes | 21 |

Within each block, order by (region_index, color_index) using:
- regions: WA=0, NT=1, SA=2, Q=3, NSW=4, V=5, T=6
- colors:  red=0, green=1, blue=2

So `domain(WA, red)` = node 0, `domain(WA, green)` = node 1, ...,
`domain(T, blue)` = node 20.

Support nodes ordered by (region, color, neighbor_index_within_region).
Keep nodes ordered same as register nodes (one keep per register).

A small sidecar JSON (`node_map.json`) recording the actual mapping is
recommended for debug/verification — saves you mental arithmetic.

## 3. Rank assignment

Verified against engine (`DagDBEngine.swift:134`): tick evaluation
walks ranks from `maxRank-1` down to `0`. Edge convention: `src → dst`
with `rank(src) > rank(dst)`. So source nodes (inputs to combinational
logic) live at higher rank, evaluated first; destination nodes
(outputs) live at lower rank, consume those values.

| Layer | Rank | Node IDs | Role |
|---|---|---|---|
| register nodes (state across ticks) | 2 | 0–20 | inputs |
| support nodes (intermediate) | 1 | 21–74 | inner |
| keep nodes (output of one round) | 0 | 75–95 | outputs |

Combinational edges:
- register (rank 2) → support (rank 1): rank(src)=2 > rank(dst)=1 ✓
- register (rank 2) → keep (rank 0): rank(src)=2 > rank(dst)=0 ✓
- support (rank 1) → keep (rank 0): rank(src)=1 > rank(dst)=0 ✓

BACK_EDGEs go from `keep` (rank 0) back to `domain` register (rank 2).
This is `rank(src)=0 < rank(dst)=2` — violates standard rank invariant
on purpose. That's why BACK_EDGE is a separate typed edge: exempt from
rank monotonicity, evaluated only in the latch phase, not during the
combinational pass.

## 4. LUT assignments

### Register nodes (IDs 0–20)
- LUT: identity over self (or unused — purely state, latched only).
- Initial truth value: per `australia.py` `initial_domains()`:
  - WA: domain(WA, red)=1, others=0 (pre-assignment).
  - All other regions: all three domain bits = 1.
  - T: same as other non-WA regions.
- Combinational fan-in: **zero**. Critical — VALIDATE enforces this.
  Truth comes only from BACK_EDGE latch (or initial conditions).

### Support nodes (IDs 21–74)
For `support(R, c, N)`:
- Inputs: 2 register nodes — `domain(N, c1)` and `domain(N, c2)`,
  where `{c1, c2} = COLORS \ {c}`.
- LUT: 2-input OR.
  - LUT6 truth table for 2-input OR on inputs (a, b):
    output = a | b. As a 64-bit integer (canonical LUT6 encoding):
    bits where input vector implies a=1 OR b=1 are set. You should
    compute this via existing `LUT_PRESET_OR` if available, or
    derive the integer from a small Python script.

### Keep nodes (IDs 75–95)
For `keep(R, c)`:
- Inputs: `domain(R, c)` register + all `support(R, c, N)` for each
  neighbor N of R.
- LUT: AND of all inputs.
- Fan-in: 1 + |neighbors(R)|. Maximum case is SA with 5 neighbors →
  fan-in 6, exactly at DagDB's bound.
- For T (Tasmania, 0 neighbors): keep(T, c) = identity over
  domain(T, c). Use `LUT_PRESET_IDENTITY` or equivalent.

### LUT integer derivations (reference)

LUT6 stores f(i0, i1, i2, i3, i4, i5) as a 64-bit integer where bit k
= f(input_vector(k)). Given fewer than 6 actual inputs, unused inputs
are don't-cares and the truth table is replicated across them.

If your engine has `LUT_PRESET_AND`, `LUT_PRESET_OR`,
`LUT_PRESET_AND3`, etc., prefer those over hand-rolled integers.
For odd fan-ins (e.g., AND of 6 inputs for SA's keep), check whether
the AND6 preset exists; if not, compose via existing `LUT_PRESET_AND`
applications — your fresh `COMPOSE` DSL verb makes this easy:

```
SET 75 LUT AND
SET 76 LUT AND
COMPOSE AND 75 76 INTO 95   # combines two AND2 LUTs into one
```

That said, for fan-in 6 you can construct AND6 via a binary tree of
AND2s — but that adds intermediate nodes. Simpler: use the existing
`LUT_PRESET_*` family if AND6 is there, otherwise build AND6 once in
`engine.lut6_low/high` directly (it's just `0x8000000000000000` —
output bit set only when all 6 inputs are 1).

## 5. Combinational wiring

Build edges (ordinary `CONNECT FROM <src> TO <dst>`):

For each region R, color c, neighbor N of R:
- node_id_src1 = `domain(N, c1)` where c1 = first color != c
- node_id_src2 = `domain(N, c2)` where c2 = second color != c
- node_id_dst = `support(R, c, N)`
- Edges: src1 → dst, src2 → dst.

For each region R, color c:
- support_ids = [support(R, c, N) for N in neighbors(R)]
- domain_id = `domain(R, c)`
- keep_id = `keep(R, c)`
- Edges: domain_id → keep_id, plus each support_id → keep_id.

Total combinational edges:
- support stage: 54 supports × 2 inputs = 108 edges
- keep stage: 21 keeps × (1 self + |nbrs| supports) = 21 + 54 = 75 edges
- T: keep(T, c) has only the self-edge (no supports), so 3 edges
  (already counted in the 21 above).
- Total: 183 combinational edges.

## 6. BACK_EDGE wiring

For each region R, color c:
- src = `keep(R, c)` (rank 0, output of round)
- dst = `domain(R, c)` (rank 2, register)
- DSL: `CONNECT BACK FROM <keep_id> TO <domain_id>`

21 BACK_EDGEs total — one per register node.

Each register has exactly one incoming BACK_EDGE and zero
combinational fan-in. VALIDATE rule satisfied.

## 7. Tick execution

Each `TICK 1` performs:
1. **Combinational pass.** Rank 2 (registers) → rank 1 (supports) →
   rank 0 (keeps). Each node's truth recomputed from its inputs via
   its LUT. Standard DagDB tick semantics.
2. **Latch phase.** For each BACK_EDGE, copy `keep(R,c).truth` →
   `domain(R,c).truth`. The `keep` value computed in step 1 is now
   the new register value for the next tick.

After step 2, the tick is closed. Readers see the post-latch state.

## 8. Convergence detection

After each tick, read all 21 register truth values via:
```
NODES WHERE id<21
```
or
```
SELECT truth=1 rank=2-2     # all registers with truth=1
```

Compare to previous tick's snapshot. When two consecutive ticks
produce identical register state, AC-3 has converged.

For Australia 3-coloring with WA=red, expected convergence at tick 2:
- Tick 0 (initial): WA={red}, others all-3
- Tick 1: WA={red}, NT={green,blue}, SA={green,blue}, others all-3
- Tick 2 (= tick 1): converged.

## 9. Verification against Python reference

`verify.py` (sketch only):

```python
from reference_ac3 import ac3_synchronous, initial_domains
ref_trajectory = ac3_synchronous()

# Read DagDB tick-by-tick state via socket DSL
dag_trajectory = []
# Setup graph
# For each tick: TICK 1, read registers, compose into domain dict
# Append to dag_trajectory

assert dag_trajectory == ref_trajectory, "tick mismatch"
```

Per-tick equality. If a single tick differs, BACK_EDGE has a bug or
the encoding has a wiring error.

## 10. Implementation order (suggested)

Do NOT build the encoding before BACK_EDGE works at the engine level.
Sequence:

1. Engine: BACK_EDGE buffer, latch kernel, snapshot v4, WAL, VALIDATE
   rule, basic DSL parsing.
2. **Manual smoke test** in DSL: 3-node graph (1 register, 1
   combinational, 1 BACK_EDGE forming a 1-bit toggle). Verify state
   flips between 0 and 1 across ticks.
3. **Multi-bit smoke test**: 4-bit ripple counter — registers + AND/
   XOR combinational logic + BACK_EDGE feedback. Verify counter
   increments per tick.
4. AC-3 Australia encoding (this spec). Run, verify against Python
   reference.
5. Record the results.

The 1-bit toggle and 4-bit counter are NOT in this spec — write them
yourself as warmups. They debug the primitive at the simplest possible
scale before you load the AC-3 graph. If AC-3 fails, having debugged
the toggle and counter first means you know the engine works and the
bug is in your encoding.

## 11. Edge cases to test

- **VALIDATE rejects bad encoding.** Write a small test: try to
  CONNECT a combinational edge into a node that's already a BACK_EDGE
  destination. VALIDATE should fail loudly.
- **Snapshot v3 → v4 migration.** Save an existing DagDB graph (no
  BACK_EDGEs) in v4 format; load and verify VALIDATE passes.
- **Save with BACK_EDGEs, kill -9, reload.** Atomic-save discipline
  must extend to the new BACK_EDGE buffer/section.
- **WAL replay reconstructs BACK_EDGEs.** Mutate, crash before
  snapshot, replay WAL, verify state.
- **MVCC reader during convergence.** Open a reader at tick 1, verify
  it sees tick-1 state even as the writer advances.

## 12. Open implementation choices

Things you decide; either choice is fine:

- **Edge type encoding**: separate buffer for BACK_EDGEs, or a
  type-flag bit on the existing edge buffer. Both work; pick whichever
  fits cleaner with the existing buffer layout.
- **Latch kernel**: pure GPU (Metal compute shader) or CPU loop. GPU
  is consistent with existing tick infrastructure; CPU is fine for
  v1 since the back-edge count is tiny relative to combinational
  edges. Stretch goal: GPU.
- **DSL keyword**: `CONNECT BACK FROM <src> TO <dst>` is my
  suggestion. Alternatives: `CONNECT_BACK`, `CONNECT BACK_EDGE`,
  `BACK_EDGE FROM ... TO ...` as standalone verb. Pick what reads
  cleanest in the DSL grammar.
- **CLEAR**: `CLEAR <node> BACK_EDGES` parallel to `CLEAR <node>
  EDGES`. Suggested but adjustable.


---

## Summary

96 nodes, 183 combinational edges, 21 BACK_EDGEs, 3 ranks, converges
in 2 ticks. Smallest possible non-trivial AC-3 instance, smallest
possible BACK_EDGE verification. If this matches Python reference
tick-by-tick, the primitive works.
