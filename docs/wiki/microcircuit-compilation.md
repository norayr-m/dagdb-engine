# Microcircuit compilation — approximating continuous functions on DagDB

How to compile a continuous function `f: ℝⁿ → ℝᵐ` into a DagDB
subgraph that evaluates at substrate throughput. Engineering recipe,
not a representation-theory paper.

> **Humble disclaimer.** Amateur engineering project. Numbers below
> come from a single M5 Max, no controlled benchmark, no peer review.
> Errors likely.

---

## The move in one sentence

A physical node (a real thing — a feeder junction, a hepatocyte, a
sensor) does not have to be one DagDB node. It can compile into a
*subgraph* of LUT6 nodes that implements fixed-point arithmetic,
threshold logic, recurrence, and filtering. The substrate evaluates
the whole subgraph per tick at the underlying tick rate. Many
physical nodes share the same compiled subgraph shape, so memory and
GPU dispatch amortise.

This is FPGA logic synthesis applied to a software graph substrate.
The contribution here is not the synthesis idea — it is that on
DagDB every internal LUT is an addressable, queryable, persistable
node. You can read internal microcircuit state mid-tick across
millions of compiled units. FPGAs cannot.

## The two speed dimensions, kept separate

| Dimension | What it bounds | How to win |
|---|---|---|
| **Compile-time speed** | How long it takes to *build* the graph (allocate ranks, install LUTs, connect edges) | Use bulk-install verbs. See [Compile-time speed](#compile-time-speed). |
| **Evaluation speed** | How many ticks per second the substrate runs after the graph is built | Keep rank depth shallow, pack state into LUT inputs, use BACK_EDGE for recurrence. See [Evaluation speed](#evaluation-speed). |

Confusing these costs months. A microcircuit that takes 2 seconds to
compile and then ticks at the substrate's full measured rate forever
is a win. A microcircuit that
takes 30 minutes to compile because each LUT goes through its own
DSL round-trip is the same circuit, evaluated identically, that you
will not iterate on.

## Compile-time speed

The bulk-install primitives:

```
SET_RANKS_BULK       u64[nodeCount] rank vector at shm offset 8
SET_LUTS_BULK        u64[nodeCount] LUT vector at shm offset 8
SET_NEIGHBORS_BULK   Int32[nodeCount * 6] neighbour vector at shm offset 8
```

Each takes one shm write + one DSL verb + one daemon-side memcpy.
For a 1 M-node compiled graph, that is **three shm writes total**
instead of ~7 million individual DSL calls (`SET … RANK`, `SET … LUT`,
`CONNECT FROM … TO …` per edge).

What you give up by bulking:

- **No WAL entries.** The bulk verbs do not append to the write-ahead
  log. If durability matters, follow with `SAVE` to write a snapshot.
- **No rank-monotonicity validation.** `SET_NEIGHBORS_BULK` writes
  whatever the caller hands it. Run `VALIDATE` after if the
  compiler's correctness is not yet trusted.

Recommended compile pipeline:

1. Compiler emits three numpy arrays in memory: `ranks: uint64[N]`,
   `luts: uint64[N]`, `neighbours: int32[N, 6]`.
2. Memory-map the daemon's shm file at `/tmp/dagdb_shm_file`.
3. Three rounds:
   - Write ranks → call `SET_RANKS_BULK`.
   - Write LUTs → call `SET_LUTS_BULK`.
   - Write neighbours → call `SET_NEIGHBORS_BULK`.
4. Optional: run `VALIDATE` once to catch any invariant violation.
5. Optional: `SAVE` to persist.

For recurrence, follow up with one `CONNECT BACK FROM … TO …` per
back-edge. Back-edges are typically a small fraction of the graph
(register count ≪ combinational count); their per-edge cost rarely
matters at million-node scale.

## Evaluation speed

The Metal kernel evaluates one rank layer per dispatch, scanning
every node at that rank in parallel. Per-tick latency is bounded by:

```
ticks_per_second ≈ 1 / (max_rank × per_rank_dispatch_overhead
                        + memory_bandwidth_bound)
```

Two things you control:

### Rank depth

Every distinct rank value is one GPU dispatch per tick. A 16-bit
fixed-point adder built as a ripple-carry chain has 16 rank levels.
The same adder built as a **Wallace tree** or **Dadda tree** has
`⌈log₂(16)⌉ + carry-propagate ≈ 4-6` levels. Order-of-magnitude
shallower → order-of-magnitude faster ticks.

Rule of thumb: when compiling arithmetic, prefer tree shapes.
Use Wallace/Dadda for multiply, carry-save addition for chains of
adds, ripple only for the final carry-propagate stage where the tree
shape doesn't pay off.

### LUT input packing

LUT6 has six input bits. Six binary inputs is one obvious mapping
but wastes the LUT's representational capacity. Better:

- **One 6-bit input** for a unary function (saturating add by 1,
  threshold, sigmoid table) — the LUT holds the lookup table
  directly.
- **Two 3-bit inputs** for a binary function over 8-state quantised
  values — the LUT encodes the full 8×8 = 64 entry truth table.
- **Three 2-bit inputs** for a ternary function over 4-state values —
  64 entries for f(a,b,c).

For a digital-twin-style fixed-point multiplier on 8-bit signals, two-3-bit
input packing per LUT gives you a single-LUT-stage multiplier core
with 3-bit precision. Cascade two stages for 6-bit precision. The
representation-theoretic literature calls this the
Boolean-circuit form of the Kolmogorov-Arnold representation;
in practice it is just choosing your input bit allocation deliberately
so each LUT carries non-trivial work.

### BACK_EDGE for recurrence

Do not compile filters and integrators as deep rank chains. Use
`CONNECT BACK FROM … TO …` to register a one-tick delay (latched at
the tick boundary), then close the loop combinationally within one
rank layer. A biquad bandpass filter is two BACK_EDGEs (one for `z⁻¹`,
one for `z⁻²`) plus a five-input combinational sum — total rank
depth 2, not 4-5 like a feed-forward expansion.

Rule of thumb: any feedback in the physical model should map to a
BACK_EDGE, not to ranks growing across ticks.

## A worked example, end to end

ε-approximate `f(x) = x²` on `x ∈ [0, 1]` using 8-bit fixed-point
input, 16-bit fixed-point output, evaluated at substrate rate
across N physical nodes.

**Quantise.** Map `x ∈ [0,1]` to `q ∈ {0, 1, …, 255}` via
`q = round(255 · x)`. Map `x²` to 16-bit output `q² ∈ {0, …, 65025}`.

**Naive: one big LUT.** 8 input bits, 16 output bits → 2⁸ = 256-entry
lookup table per physical node. A LUT6 takes 6 input bits; you would
need 2² = 4 parallel LUT6s gated by input bits 6-7, then a 16-output
muxing layer. ~20 LUTs per physical node, rank depth ≈ 4-5.

**Tree: 4 × 4 → 4 staged squarings.** Split input into low and high
4-bit nibbles. Compute `x_low²`, `x_high² · 256`, and `2 · x_low · x_high · 16`.
Each component is a smaller LUT-based table; sum at the end with a
carry-save adder. ~12 LUTs per physical node, rank depth ≈ 6.

The tree shape uses more LUTs (12 vs 20 in this comparison) but the
deeper rank tradeoff isn't worth it for this small function — the
naive 256-entry decomposition wins. **For a larger function** (say
12-bit input) the tree wins because the naive table size explodes
exponentially.

Compile this for N = 10⁶ physical nodes: 10-20 LUTs per node = 1-2 ×
10⁷ DagDB nodes total. Three bulk-install verbs commit the whole graph
in three shm writes. Subsequent tick rate depends on how many rank
layers the compiler chose — for the 4-5 layer naive case at
~10⁷ nodes, you get the substrate's per-tick latency × 5 ≈ small
milliseconds per full evaluation pass.

## What to NOT do

- **Do not compile a function into rank depth proportional to
  precision.** Always look for tree shapes first. Linear depth means
  linear tick cost.
- **Do not use individual `SET … LUT` calls inside a compile loop.**
  Even for "small" graphs (10⁴ nodes) this adds seconds you don't
  need to spend. Use `SET_LUTS_BULK`.
- **Do not encode time-domain behaviour as combinational depth.**
  Use a master clock + per-subcircuit update masks. BACK_EDGE
  carries the state from tick t to tick t+1; that is what gives you
  multi-time-domain physics under one synchronous substrate.
- **Do not skip `VALIDATE` on a freshly-compiled graph the first
  time.** Compiler bugs that violate the rank invariant compile
  silently through bulk install. Run `VALIDATE` once after the first
  build of a new compiler version; trust subsequent builds only
  after the compiler is stable.

## What this earns

For approximation workloads that fit the "many identical
microcircuits, one per physical node" pattern:

- Million-node compile in seconds, not minutes.
- Evaluation at the substrate's measured throughput (0.71 GCUPS at
  1M nodes on M5 Max — see Benchmarks), parallel across all
  physical nodes per tick.
- Mid-tick introspection of any internal LUT state via `NODES AT
  RANK …` or reader-session snapshots — you can debug the
  microcircuit while it's running, which FPGA bitstreams cannot do.

For approximation workloads that **do not** fit this pattern —
heterogeneous per-node functions, low N (< 10⁴), one-shot
evaluations — the bulk-install primitives are wasted overhead.
Use the regular `SET LUT` / `CONNECT` DSL and accept the per-call
cost.

---

## See also

- [`back-edges.md`](back-edges.md) — recurrence primitive used for
  filters and integrators.
- [`dsl.md`](dsl.md) — full DSL grammar including the new bulk verbs.
- [`mvcc.md`](mvcc.md) — reader-session snapshots for mid-tick
  introspection of compiled microcircuits.
- The motivating application: electrical digital-twin modeling —
  approximating grid physics (Ohm, Kirchhoff, signal propagation)
  with compiled per-node microcircuits.

See also: [Nested LUTs](nested-luts.md) — why composition is necessary
and the exhaustively verified mult4 microcircuit.
