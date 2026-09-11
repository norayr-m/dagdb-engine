# DagDB — capabilities

> **Humble disclaimer.** Amateur engineering project. We are not HPC
> professionals and make no competitive claims. All numbers come from
> one M5 Max laptop, no controlled benchmark, no peer review. Errors
> likely. Numbers speak.

Last refreshed: 2026-09-10, against main (interface phase merged
2026-09-06, startup recovery merged 2026-09-09): 446 tests, 9 skipped
(fixture-gated), 0 failures.

## What it can do today

### Core engine
- 6-bounded ranked DAG substrate, LUT6 gate evaluator, ternary state
  (−1, 0, +1), Morton + 7-coloring partition, hex-grid substrate
  option.
- Nested-LUT microcircuit compilation (mult4 exact on the engine),
  installed via `SET_LUTS_BULK` / `SET_NEIGHBORS_BULK`.

### Persistence & ACID
- Full-state SerDe + zlib, SIGTERM snapshot, crash recovery on load,
  write-ahead log with replay + truncate, atomic commit (fsync +
  rename), MVCC snapshot-on-read, secondary index (truth, rank-range).
- Snapshot format v7 (adds the twin `TWIN` section on top of v6's
  weight/value lane section); loads v1..v7.
- 446 Swift XCTest cases on main, full suite green, 9 skips
  (fixture-gated, see the twin interface phase section above).

### Performance (tick recovery, 2026-07)
- Per-(rank,color) compacted dispatch — now the default rank-tick
  path. Measured ~1.75–2x over the legacy path on the 16-rank cell
  (N=5 re-measure, cool machine, 2026-08-01); on the historical
  wide-shallow shape it runs ~2–3x over legacy.
- TICK_SYNC — double-buffered synchronous mode, one dispatch per
  tick, bit-for-bit against a CPU reference. Measured ~0.30 ms per
  tick at 1,048,576 nodes (~3.5 GCUPS), stable across repeated runs.
- Rank-topology invalidation: a dirty flag defers dispatch-list
  rebuilds to the next tick, not every mutation.

### Durability (G73, 2026-07)
- WAL group-commit fsync policy (`Appender.FsyncPolicy`:
  `.everyRecord` default / `.grouped(n, ms)`); production is
  hard-pinned to per-record `F_FULLFSYNC` regardless of config.
- Snapshot SHA-256 manifest, written after the atomic rename and
  verified before any buffer is touched on load.
- Torn-tail audit: WAL replay already tolerated a partially-written
  last record; behavior pinned by a hand-truncated fixture test, no
  code change needed.
- kill-9 stress probe: scratch daemon, ~1k writes/s, `kill -9`
  mid-write, restart + replay + verify — 10/10 clean, 0 observed
  loss within the configured bound.


### Startup recovery (2026-09-09)
- `DAGDB_STARTUP_LOAD=<path>` (opt-in): the daemon loads that snapshot
  before WAL replay, so a restart after `SAVE`/autosave restores graph +
  twin state with no operator `LOAD`. Every durable snapshot checkpoints
  the WAL right after itself (autosave included now), so snapshot +
  replayed tail = the state at the last word. Unreadable or out-of-root
  snapshot = refuse to start. `DagDBStartup.recover`; 7 tests; live
  socket smoke 23/23.
### Weight lanes (E1, 2026-08-22)
- Edge-weight lane, activation lane, and a Float `nodeValue` lane
  (Float64 accumulate, Float32 storage) sit beside the ternary core.
- Persisted in snapshot v6; three new WAL opcodes (edge weight,
  activation, node value); daemon commands `SET <n> WEIGHT <dir> <f>`
  and `SET <n> VALUE <f>` (log-first, bounds-checked, finite-only).

### Ladder / solver
- E2Runner: runs a frozen asynchronous Jacobi smoothing schedule on
  the engine's own fabric (HexGrid wiring, Float32 nodeValue lane).
- E3Ladder: exact tier ladder — fp32 per-rung storage, Float64 fold
  arithmetic via Accelerate/LAPACK. Measured 927x compression at
  1e-7 tolerance over 19 folds (sealed court, 30/30 passing).

### Twin primitives (2026-08-30)
Seven library types built to a frozen nine-line twin spec, each with
its own unit tests:
- NamedStream — PCG64 with a numpy state bridge.
- StreamHeader — mandatory t-zero admission, seven declared
  quantities, arithmetic refused on incompatible streams.
- StreamRecord — bit-exact slice replay.
- BudgetLayout — knapsack primitive (claim merge, min-cost tie,
  lexicographic residual).
- CrossConvolutionCheck — pass / scream / flash self-test.
- GearedRings — 6:1 signed-extremum odometer, 192 numbers covering
  six orders of lag.
- MasterClock + PhaseGear — one master clock, rational gears,
  integer-exact (no drift, no second clock).

### Twin interface phase (2026-09-06)
- All seven twin primitives, plus the twin spec line 4 alarm-stream
  type (`AlarmRecord`/`SealedCourt`/`AlarmFixture`/`CorruptionModel`/
  `SuccessorCourt`/`AllocatorCourt`), are reachable over the daemon
  socket (DSL) and MCP — nine verb families (`STREAM`, `HEADER`,
  `RECORD`, `RINGS`, `CLOCK`, `GEAR`, `XCONV`, `BUDGET`, `ALARM`), one
  daemon-global `TwinState` of typed-id registries, WAL opcodes
  `0x20`–`0x2B`, snapshot v7's `TWIN` section. See
  `docs/wiki/dsl.md`'s "Twin primitives" section for the grammar.
- **Sealed gate 1** (allocator-court replay) and **gate 2** (successor
  dyadic ε lattice) reproduce the frozen numbers in
  `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md` bit-for-bit against the real
  29 MB W2 fixture — 5 budget points × 4 arms (gate 1), 4 points ×
  4 sweeps × 5 ε values compared with exact `Double` equality (gate 2).
  Both gates run only when `DAGDB_W2_FIXTURE` is set; unset, the 9
  fixture-gated tests skip with a printed reason rather than run.

### Interfaces
- CLI, daemon + socket server, Python MCP server, PostgreSQL
  extension, web bridge, live status dashboard (this ledger).
- DSL coverage: JSON/CSV save/load, backup chain
  (init/append/restore/compact/info), 8 subgraph-distance metrics,
  BFS depths (undirected/backward), twin primitives (above).

## What it cannot do yet / known limits

- **Twin primitives are not fused into the tick loop.** The interface phase (2026-09-06) exposes all seven primitives plus the
  alarm-stream court types over the daemon socket and MCP — it does
  not wire any of them into `TICK`/`TICK_SYNC` dispatch. That fusion
  is spec 8 / P5 (see `ROADMAP.md`).
- **The two sealed gates need an out-of-repo fixture.** Gate 1
  (allocator-court replay) and gate 2 (successor dyadic ε lattice) —
  `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md` — only run with
  `DAGDB_W2_FIXTURE` set to the SHA-pinned 29 MB W2 fixture; a plain
  `swift test` run without it reports 9 skips, not a gate PASS. A
  fixture that is present but hash-mismatched is a gate FAIL, not a
  skip (contract amendment 1).
- **Python plugin tests are blocked.** `plugins/loom` test
  collection fails from this worktree layout on a module-path issue;
  do not cite a green Python test count until it's repaired
  (see `CURRENT_STATE.md`).
- **Tiled graph router is scaffold stubs.** `TiledGraphRouter` and
  `TileHalo` establish the public surface (types, signatures, a
  minimum-viable initializer); live tile load/evict/pre-fetch,
  halo bookkeeping, and the multi-engine memory budget are not
  implemented.
- **No distributed mode.** One machine holds the world; there is no
  multi-machine or clustered operation.
- **Single machine, uncontrolled benchmarking.** Every number above
  is from one M5 Max, no isolation from thermal state or background
  load, no peer review.
- **Float lanes are sidecar-style.** Edge weight / activation /
  node-value lanes sit beside the 42-byte ternary record; the
  ternary core itself carries no float.
- **No real grid data, ever, by policy.** Only synthetic graphs and
  standard test feeders are used anywhere in this project — no real
  network topology has been loaded, and none is planned.

## How claims are verified

Every numeric claim in this document traces to one of:

- A Swift XCTest in `dagdb/Tests/` (the 446-case suite on main, run
  with `swift test`), or a named
  benchmark test (`testBenchmarkTickModes1M`) with committed results.
- A frozen-contract court: a spec is written and sealed before any
  number exists (object, method, floor, prior work, run kind —
  claim / control / re-derivation — and a numeric PASS criterion),
  then run through blinded rooms with a mechanical notary. E3v3
  (927x/19-folds) and E2v2 are both court-gated results; their
  contracts, fixtures and verdicts are held outside this repository,
  so from this repository alone they are reproducible runs, not
  verifiable claims.
- A results ledger under `docs/`, cross-checked against the code it
  describes: `docs/perf_recovery/results.md` (tick performance),
  `docs/g73/RESULTS.md` (durability), `ROADMAP.md` (twin-spec status
  table with per-line evidence pointers), `CURRENT_STATE.md`
  (canonical version/test-count/ownership pointer — wins over any
  older doc that disagrees).

If a document elsewhere in this repo states a different number,
`CURRENT_STATE.md` is the tiebreaker; if this file and
`CURRENT_STATE.md` disagree, `CURRENT_STATE.md` wins and this file
is stale and should be fixed.
