# SPEC — tick performance recovery (compaction + TICK_SYNC)

Date: 2026-07-07 · Owner: dag · Branch: dag/tick-perf

## Why

DagDB's measured 1M-node throughput is 0.71 GCUPS vs ~14.4 for the
Savanna CA engine. Mechanism (from the tick-loop read, 2026-07-01):
rank×color serialization (up to maxRank×7 = 112 encoders/tick vs ~7),
early-out thread waste (each color dispatch launches the whole color
group; nodes not at the current rank exit immediately — at 16 ranks,
~15/16 of threads are waste), and per-tick CPU/GPU sync. Part of the
gap is the price of in-place dependency-ordered evaluation (inherent);
the rest is recoverable.

## Claims

- C1. **Compaction is exact**: dispatching precomputed per-(rank,color)
  node lists produces bit-for-bit identical truth states to the legacy
  whole-color-group path, over randomized graphs (seeded), LUTs,
  ranks, back-edges, and multi-tick runs.
- C2. **Compaction is invalidated correctly**: mutating ranks (single,
  bulk, LOAD) with the dirty-flag path yields the same states as a
  fresh engine on the mutated topology.
- C3. **TICK_SYNC is exact synchronous semantics**: equals a pure-CPU
  double-buffered reference simulation bit-for-bit (including register
  latching) over randomized graphs and ticks.
- C4. **Sync ≠ rank on purpose**: a rank-ordered chain settles in one
  rank TICK but takes depth ticks under TICK_SYNC — asserted, so the
  modes cannot be silently conflated.
- C5. **Perf is measured, not promised**: committed benchmark prints
  ms/tick + GCUPS for legacy / compacted / sync on the 1M grid
  (16-rank spread = worst-case waste, and 3-rank = the old bench
  shape). Results go in results.md + wiki Benchmarks as measured
  numbers on M5 Max; no target number is asserted in tests.
- C6. The mult4 microcircuit test (rank mode) and full 192-suite stay
  green — compaction is the new default rank path.

## Non-goals

- No change to rank-mode semantics (dependency-ordered, in-place).
- No Savanna parity claim — sync mode removes the ordering overhead;
  scatter-gather neighbor reads and LUT indexing remain different
  work per cell than Savanna's stencil. The benchmark reports what it
  reports.
- No indirect command buffers / GPU-driven encoding in v1.
- No daemon protocol break: TICK unchanged; TICK_SYNC is additive.

## Acceptance

Full suite green including the new equivalence tests; benchmark test
runs and prints all three modes on the 1M grid.
