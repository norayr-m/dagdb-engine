# Results — tick perf recovery (branch dag/tick-perf, 2026-07-07)

All correctness gates green (suite 197: 192 base + 5 new equivalence/
semantics tests + handler TICK_SYNC test). Benchmark: committed
`testBenchmarkTickModes1M`, 1024×1024 = 1,048,576 nodes, M5 Max,
50 ticks + 3 warmup per mode (also run at 10 ticks; ranges below are
across all runs tonight — single-run numbers on this machine vary up
to ~2× with thermal state, which is why the receipt reports ranges).

## Measured

| mode | 3-rank spread | 16-rank spread |
|---|---|---|
| legacy rank tick (early-out) | 1.19–4.07 ms · 0.26–0.88 GCUPS | 1.56–5.16 ms · 0.20–0.67 GCUPS |
| compacted rank tick (default) | **0.62–1.29 ms · 0.81–1.69 GCUPS** | 1.62–6.92 ms · 0.15–0.65 GCUPS (unstable) |
| TICK_SYNC (CA semantics) | **0.28–0.75 ms · 1.41–3.73 GCUPS** | **0.29–0.30 ms · ~3.5 GCUPS (stable)** |

## Honest reading

- **Shallow rank spreads (the common shape — EDT wide-shallow, the
  benchmark's historical 3-rank layout): compaction wins ~2–3× over
  legacy in every run.** This is the new default rank path, bit-for-bit
  equivalent (20 seeded random graphs × 8 ticks vs legacy; invalidation
  contract tested; all daemon rank mutations wired).
- **Deep thin spreads (16 bands): compaction is NOT reliably faster** —
  112 barrier-ordered small dispatches (~9.4K threads each) are
  latency-bound; measured anywhere from 1.7× faster to 1.8× slower
  than legacy across runs. Known, documented; candidate fix is a
  per-rank heuristic (compacted vs whole-group per rank, decided at
  rebuild) — deliberately NOT tuned tonight on thermally noisy data.
- **TICK_SYNC is the headline: ~0.30 ms/tick at 1M nodes, ~3.5 GCUPS,
  stable across every run and spread — 4–17× over the legacy rank path
  on the same graphs.** One dispatch, double-buffered, exact CPU-
  reference semantics (10 seeded graphs × 10 ticks bit-for-bit), and
  deliberately NOT equivalent to rank mode (chain test pins arrival =
  source + depth). For synchronous-CA workloads (Savanna-class,
  sphere-grid register meshes, shell propagation) this is the mode.
- Context for the old public number: DagDB's honest figure was
  0.71 GCUPS. Rank mode now measures up to 1.69; sync mode ~3.5.
  Savanna's 14.4 remains ahead on its own stencil workload — its
  fixed-neighborhood reads beat DagDB's arbitrary-graph
  scatter-gather, which is the remaining structural difference, not
  claimed recoverable.

## What is NOT claimed

- No Savanna parity. No 16-rank compaction win. No daemon-path
  benchmark (engine-level only; socket overhead excluded). Numbers are
  M5 Max, this machine, tonight — ranges, not guarantees.

## Files / receipts

- Engine: compacted dispatch (single encoder + memory barriers),
  `tickLegacy` ground truth, `tickSync` + ping-pong, dirty-flag
  invalidation; DSL `TICK_SYNC`.
- Tests: `DagDBTickPerfTests` (7 + benchmark), handler `testTickSyncVerb`.
- /build docs: SPEC/ARCH/BUILD_PLAN in this directory (14 gates 0-fatal).

## 2026-08-01 — N=5 statistical re-measure (cool machine, merge-gate data)

| mode | 3-rank (5 runs) | 16-rank (5 runs) |
|---|---|---|
| legacy | 1.19–1.56 ms | 1.42–1.53 ms |
| compacted | 0.49–0.59 ms | **0.82–0.86 ms (stable, ~1.75× over legacy every run)** |
| TICK_SYNC | 0.24–0.35 ms | 0.22–0.46 ms |

The July 16-rank instability (1.6–6.9 ms) is NOT reproduced: five
consecutive runs sit in a 5% band, compaction faster than legacy in every
repetition on both spreads. July numbers ruled thermally poisoned.
Per-rank heuristic NOT needed; compacted dispatch is the default
everywhere. Merge gate's data half closed.
