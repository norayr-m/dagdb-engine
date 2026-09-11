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
- Rank-mode TICK covers every rank present in the graph, not just the
  levels below the configured `maxRank` (correction 2026-09-10, gate
  contract `docs/contracts/RANK_BOUND_GATES_FROZEN.md`). `maxRank` is
  the initial table size; the dispatch sizes itself to
  `max(maxRank, highest rank present + 1)`. Before that correction —
  in every release up to and including public v0.2.0 — a node at or
  above `maxRank` was silently skipped by rank mode while `TICK_SYNC`
  computed it; the usual way to land there was restoring a snapshot
  into a daemon configured with a smaller bound. `TICK`/`TICK_SYNC`
  now report `nodes_computed`, and `STATUS` reports `ranks=` and
  `rank_max=` beside `maxRank=`.

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

### Waveform mouth (spec 8, 2026-09-10)
- `WaveBank` (branch `dag/spec8-mouth`, not yet merged to main): a
  frozen T×K bank Φ of unit-norm atoms — harmonic cos/sin columns plus
  Gabor atoms on a center/frequency grid — built in Float64, cast to
  Float32. Reachable over the daemon socket/MCP as an eight-verb
  `BANK` family (OPEN/GENERATE/FIT/NOISE/BENCH/INFO/LIST/CLOSE), WAL
  opcode `0x2C`, snapshot v7's `banks` field.
- **Generate**: W = Φ·C, one `cblas_sgemm` call (Accelerate), no atoms
  copy.
- **Fit**: least squares c* = argmin ‖x − Φc‖ via LAPACK `dgelsd`
  (SVD), rcond = eps(Float32)·max(T,K) — numpy's own truncation rule
  for a Float32 bank; a plain QR solve is numerically meaningless on
  this Φ (see the rank finding below). Residual = ‖x − Φc*‖/‖x‖,
  printed, never hidden.
- **Declaration**: rank (count of singular values above σ_max·1e-9)
  and condition number (σ_max/σ_min), via LAPACK `dgesdd`, printed at
  bank creation and on `INFO`, before any probe.
- **Nyquist line**: a spec whose top harmonic reaches or exceeds
  Nyquist (H·f0 ≥ fs/2) is refused by the daemon with
  `ERROR bad_value` naming the first aliasing harmonic, unless the
  operator writes `ALIASED` on the `BANK OPEN` line; the library
  itself builds either spec unconditionally.
- **The law**: i.i.d. white noise projected onto a fixed K-dimensional
  subspace of ℝ^T has expected residual √(1 − K/T). Found while
  building this: the sealed 160-atom reference bank (H=32) is
  rank-deficient — harmonics 26..32 alias exactly onto 24..18 above
  Nyquist, a true dependency (float64 condition number 2.408e12), not
  a float32 artifact. The twin lane repaired it: H=24 keeps every
  harmonic below Nyquist, K=144, full rank 144, condition number
  2.666132. The daemon now opens the repaired bank by default; the
  160-atom bank stays reachable as the sealed CONTROL object with
  `ALIASED` (rank 146 of 160).
- **Measured throughput** (one M5 laptop, best-of-3, no controlled
  benchmark): 2.46e9 samples/s at K=160, 2.83e9 at K=144 (M=10000) —
  beside the twin lane's numpy mouth: 2.23e9 (control), 1.95e9
  (repair, one timing).
- Fixture: `dagdb/Tests/Fixtures/mouth_reference_v1.json` (+ `.sha256`,
  checked in, never skipped), built by
  `dagdb/scripts/mouth_reference.py`. Gate contract:
  `docs/contracts/SPEC8_MOUTH_GATES_FROZEN.md`.

### Derived views (2026-09-10)
- Branch `dag/derived-views` (off `dag/spec8-mouth`, not yet merged to
  main): spec line 4's second view family, three alarm-set views over
  a sealed frame set — M frames × 8 stations × 64 samples, a
  candidate-by-station arrival table τ (129 × 8), station scan order,
  and the world constants SPEED/dt/OS/FS. `NpzReader` is a hand-rolled
  reader for STORED (uncompressed) npz archives — zip
  central-directory sizes, npy v1–v3 headers, f4/f8/i8 — no
  third-party code. `CortexFixture` loads and validates the fixture
  (shapes, label range 0..128, 6966 = 129·54 with every class exactly
  54). `DerivedViews` computes the three views. Reachable over the
  daemon socket/MCP as an eight-verb `VIEW` family (LOAD/REFLEX/RUNG/
  CEILING/FEATURES/INFO/LIST/CLOSE), WAL opcode `0x2D`, snapshot v7's
  `views` field.
- **Reflex** (amended letter): per station, arrival = first index
  where |x| > 0.25·max|x| on the S-station slice, re-zeroed over that
  subset. Per candidate: a 2-parameter least-squares fit (α, β) over
  normalized τ (global tau_max) via LAPACK `dgelsd_`, α clipped at 0
  after the fit; tie rule r ≤ r_min + 1e-9·max(1, r_min); winner =
  lowest index in the tied set; oracle-tie = truth inside the tied
  set.
- **Geometry-then-energy rung**: 3·S front-aligned energy features per
  frame (station-major: log front-window energy ratio, magnitude-
  weighted spectral centroid, log second/first-window energy ratio),
  standardized with 3·S train (mean, std) pairs — one per (station,
  channel), never pooled, std floored at 1e-12 — then nearest class
  centroid (Euclidean, standardized space) over the reflex tied set;
  exact ties keep the lowest index.
- **Geometry ceiling**: k = 1/(SPEED·dt·OS); shifted arrival rows from
  τ_raw alone; exact-twin pairs under max-norm < 1e-9; identifiable
  classes under max-norm < 1.0 with transitive closure (unique +
  groups); ceiling = classes / 129.
- Gates held exactly at S = 2/4/6/8: reflex 3/11/15/18; oracle-tie
  233/72/76/65; tie sizes min/median/max 52/77.0/129 · 1/5.0/129 ·
  1/4.0/129 · 1/2.0/23 (frames with a tie 300/253/242/231); rung
  38/28/29/39; ceiling 0.069767/0.147287/0.209302/0.271318
  (identifiable 9/19/27/35 = unique 3/8/12/15 + groups 6/11/15/20;
  exact-twin pairs 2495/1015/711/467). Printed, not gated: near-edge
  candidates 22048/3814/2640/1017; rung margin (min over tied frames)
  7.1e-4/1.6e-3/8.1e-4/2.1e-4; wall time per view.
- Fixture: `cortex_v4_world.npz` (15,145,646 bytes, out of repo, env
  `DAGDB_CORTEX_V4_FIXTURE`), sha256-pinned — skip if absent, FAIL on
  hash mismatch, never a silent load of a different fixture. View sets
  persist by reference (path + sha256); a missing or changed file on
  restore drops that entry with a WARN, same rule as `ALARM LOAD`.
  Gate contract: `docs/contracts/DERIVED_VIEWS_GATES_FROZEN.md`.

### Kernels and the sealed cross-convolution check (2026-09-10)
- Branch `dag/kernels` (built on `main`, not yet merged): per-path
  kernels (impulse responses root→ear, 2048 taps at fs = 3000 Hz)
  stored by reference and by id — `KernelPair` (path + sha256, τ_A/
  τ_B/σ_source/declared-warmup all DECLARED at load, never read from
  the kernels file) — and `SealedCrossConvolution`, the W1 court's own
  frozen residual R (full convolution truncated to the record length
  n, window [warmup, n) on both numerator and denominator, one-sided
  denominator max|kB⋆a| + 1e-300, float64 end to end). Reachable over
  the daemon socket/DSL/MCP as `KERNEL LOAD/INFO/LIST/CLOSE` +
  `XCONV SEALED`, registry prefix `k`, WAL opcode `0x2E`, snapshot v7's
  `kernels` field (tolerant decode). Kernel pairs persist BY REFERENCE,
  never the taps; a missing or changed file on restore drops that
  entry with a WARN, same rule as `ALARM`/`VIEW`.
- **The patrol-check finding, stated plainly.** The engine's
  pre-existing `XCONV CHECK` (`CrossConvolutionCheck.check`,
  2026-08-30) is **not** the court's R: it compares over the full
  convolution length (n + m − 1 samples) instead of the record window,
  divides by a symmetric denominator `max(|kB⋆a|, |kA⋆b|)` instead of
  the one-sided `max|kB⋆a| + 1e-300`, and takes Float32 records and
  taps instead of Float64 end to end. On the 190 sealed W1 trials the
  patrol check's residual would flip 50 of 190 court gates — every one
  of them a **true** court recording, not a fake or a perturbed one —
  because it measures past where the identity actually holds. `XCONV
  CHECK` stays wired, unchanged, documented as a compatibility patrol
  check, not a court check; `XCONV SEALED` is spec line 6's standing
  cheap check as of this branch.
- Warmup (K4): `ceil((|τ_A − τ_B| + 3·σ_source)·fs)` = 185 for W1,
  derived from τ/σ declared on `KERNEL LOAD`; an explicit warmup on
  `XCONV SEALED` overrides and prints "declared, not derived"; a pair
  loaded without TAU/SIGMA has no default and `XCONV SEALED` then
  requires one explicitly.
- Results on the 190 sealed W1 trials: K2 every court line reproduced
  (G0 6.151e-15 vs the court's 4.101e-15, both ≤ 2.533e-14 — the
  printed digits are summation-order noise at the floor; worst court
  5.415e-03, 50/50 within tolerance; fakes 50/50; perturbed 50/50,
  quartiles 1.019e-01/1.032e-01/1.052e-01; cal reference max
  3.348e-03, not gated). K1 (absolute, frozen) FAILs as an expected
  floor finding on 2 of 190 (fake_34 R 16.44, fake_48 R 24.70 — the
  float64 summation-order floor, absolute miss 3.9e-14/6.4e-14,
  relative 2.4e-15/2.6e-15); K1' (the standing relative bound,
  amendment 3, 3e-15·max(1, R)) holds on all 190. K5 (printed, not
  gated): max |R_patrol − R_sealed| = 23.7; the three attributed
  formula differences (full-length window, symmetric denominator,
  float32 inputs) each match their numpy reference to ≤ 6.4e-14.
- Fixtures: `w1_kernels.json` (in repo, 144,554 bytes, sha256 pinned)
  and `w1_residuals_v1.json` (in repo, ≈34 KB, the frozen-formula
  reference per trial, sha256 pinned) — always present, never skip.
  The 190 W1 records (18,580,321 bytes) stay out of repo, env
  `DAGDB_W1_RECORDS`, sha256 pinned — absent skips the sealed tests,
  present with the wrong hash FAILs. The sealed run takes ≈10 minutes
  in a debug build. Gate contract:
  `docs/contracts/KERNELS_GATES_FROZEN.md`.

### Attention hook (2026-09-10)
- Branch `dag/hook` (built on `main`, not yet merged): the sealed
  allocator court (`AllocatorCourt.run`) as a daemon-global ticked
  process instead of one batch call. `AttentionHook` binds one alarm
  set + one budget layout (sealed by default) + a per-frame budget B +
  a lag Δ (3) + one of three lagged policies (allocator, greedy,
  uniform — the oracle has no lag and stays a court arm, never a hook
  policy) + an optional master clock. Each step advances the hook's
  own frame counter t by one: at frame t it reads the alarm of source
  frame t − Δ, decides what to buy under B by the policy's rule
  (allocator: cheapest tier with read value 1 in the claimed pocket;
  greedy: the deepest affordable tier in the source alarm's pocket;
  uniform: the fixed tier at its flat frame cost), books the purchase
  through the court's own `recordOutcome`, and appends one line to its
  ledger — so the arithmetic can never drift from the sealed court's.
- Bound to a clock, one `CLOCK ADVANCE` tick is exactly one hook step,
  applied AFTER that tick's gears — attention is spent on the engine's
  clock, not by a batch call. A clock-bound hook refuses `HOOK STEP`
  directly (`ERROR forbidden: bound to clock <c>`) so its frame
  counter has exactly one driver; `CLOCK CLOSE` cascades to bound
  hooks the same way it cascades to gears, reporting
  `hooks_closed=<n>` beside `gears_closed=<n>`.
- Per-frame ledger row (gate H2): `t, src, judged, outcome ∈ {hit,
  miss, none}, class, ear, pocket, tierBought, spend,
  countsTowardCost, cumulativeCost`. A judged frame whose source is
  quiet is `none` — allocator/greedy buy and book nothing, uniform
  pays its flat frame cost and books cost with no hit/miss. Warm-up
  rows (`t = 1..Δ`) are `judged = false`; uniform books their spend
  into `warmupCostExcluded` (never into `cost`) while still updating
  `maxSpendRatio`; allocator/greedy warm-up rows spend 0. The ledger
  is DERIVED, never stored — rebuilt by re-stepping.
- Reachable over the daemon socket/DSL/MCP/bridge as `HOOK
  OPEN/STEP/STATE/LEDGER/INFO/LIST/CLOSE`, registry prefix `h`, WAL
  opcode `0x2F` (`hookOpen`) / `0x30` (`hookStep`), snapshot v7's
  `hooks` field (parameters plus the frame counter t only, decoded
  tolerantly). Closing an alarm set or budget layout a live hook
  depends on refuses `ERROR forbidden: hook <h> depends on <id>`, same
  shape as ALARM/BUDGET's other dependency refusals. Read-only for
  reader sessions: `HOOK STATE`, `LEDGER`, `INFO`, `LIST`; `HOOK
  OPEN`/`STEP`/`CLOSE` are forbidden, same shape as every other twin
  family. The ledger's shm row is 40 bytes, 8-byte aligned: `u32 t |
  i32 src | u8 judged | u8 outcome | i8 tier | i8 pocket | 4 pad | f64
  spend | f64 cumulativeCost | u8 countsTowardCost | 7 pad`.
- Results on the sealed W2 records (`DAGDB_W2_FIXTURE`): H1 —
  `hook.result == AllocatorCourt.run(...)[policy]`, Swift `Equatable`,
  no tolerance — holds at all 5 sealed budget grid points × 3
  policies; H2's ledger identities hold over the 203 sealed rows; H3 —
  WAL replay and snapshot v7 restore reproduce both the result and the
  ledger line by line; H4 — a bound and an unbound hook agree exactly
  at one grid point; H5 — every socket reply line matches exactly,
  including `HOOK STATE` after 203 steps at the richest sealed point:
  `served=150 misses=0 cost=819218.0` for the allocator policy (the P4
  gate-1 line) and `served=50 misses=100 cost=94400.0` for uniform; H6
  (printed, not gated) — ≈0.9 µs per step (allocator policy, sealed
  layout, debug build), cumulative cost 0 / 501710 / 538024 / 819218
  at t = 50/100/150/203.
- Fixtures: gated on the same `DAGDB_W2_FIXTURE` the allocator court
  already uses — no new fixture. Gate contract:
  `docs/contracts/HOOK_GATES_FROZEN.md` (H1–H6, amendment 1 fixing the
  40-byte ledger row layout and the countsTowardCost-on-a-judged-
  non-quiet-miss letter).

### Fold API (2026-09-10)
- `LadderFold` (branch `dag/fold-api`, built on `dag/spec8-mouth`, not
  yet merged to main): the E3 tier ladder — Kron/Schur fold of a rank
  ring into the kept set at a time, operator stored to Float32 between
  folds, solved in Float64 via LAPACK `dgesv` — promoted from the
  sealed `E3Ladder` runner (`dagdb/Sources/E3Ladder/main.swift`, last
  arithmetic change 2026-08-26) into a library call,
  `LadderFold.run(object:schedule:sources:)`, arithmetic unchanged.
  `e3-ladder` is now a thin CLI over it.
- `LadderFold.Object(engine:grid:)` reads the fabric it folds from the
  engine's own lanes — neighbors, edge weights, `nodeValue` as leak,
  rank — the same lanes `CONNECT`/`SET` write; a fresh daemon starts
  with the neighbor table wiped, so FOLD folds whatever graph the
  lanes hold, hex adjacency only if it was written there.
  `LadderFold.Objects.control`/`.court` write the frozen E3 court
  objects into those lanes for the gate re-derivation.
- Reachable over the daemon socket and MCP as a five-verb `FOLD`
  family (`RUN`/`KEPT`/`SOURCE`/`TIER`/`INFO`) dispatching through the
  same `TwinCommand` grammar as the other twin verbs, but minting no
  registry entry and touching no WAL: every verb is a pure, read-only
  computation over the current lanes, nothing persisted, the last
  result held in the handler and recomputable from the lanes. `FOLD
  RUN` predicts its kept-set size before any O(k³) work, so an
  oversized result is rejected against a configurable shm capacity
  before it runs. Reader sessions may run every FOLD verb, RUN
  included.
- Gate contract: `docs/contracts/FOLD_API_GATES_FROZEN.md` (F1–F5, all
  held) — F1/F2 bit-for-bit against the sealed E3v3 runner outputs
  (control fixture in repo; G1/G2 court ladders out of repo via
  `DAGDB_E3_RUNS`, skip if absent, FAIL on hash mismatch), F3 the
  rebuilt CLI's output sha matches the pin, F4 the daemon verbs match
  the library bit-for-bit, F5 price (bytes/tier, wall ms/fold)
  printed, not gated.

### Tiling, step one (2026-09-10)
- Branch `dag/tiling`, built on `main`, not yet merged. Gate contract:
  `docs/contracts/TILING_GATES_FROZEN.md` (T1–T6, amendments 1–2) —
  `docs/tiled-streaming.md` build steps 3–4 (steps 5–6: pre-fetch,
  ticking across tiles, the cold tier, thermal pauses, the 10¹¹-node
  run, `TILED BACKUP` — explicitly not promised by this contract).
- `TiledGraphFiles.write` splits a DAG by rank range into
  `tile_<lo>_<hi>/{body.dags, halo_lower.bin, halo_upper.bin,
  meta.json}` plus a graph `manifest.json`. Two entry points: over a
  `TiledFixture.Object` (the frozen synthetic gate objects), and over
  a live `DagDBEngine` + `HexGrid` directly — the daemon's own current
  graph, what `SAVE TILED` calls. `body.dags` is the CURRENT snapshot
  format (v7), not a frozen v3.
- `TiledGraphRouter` (a Swift actor): LRU-bounded resident tile set
  (load-on-touch, evict least-recently-used past K); cross-tile
  `runBFS`/`runAncestry` (level-synchronous across tile boundaries,
  minimum depth over all paths, depth capped at 12) and `runSelect`
  (truth/rank-range) match the single engine's own
  `DagDBBFS.bfsDepthsUndirected`/`bfsDepthsBackward` and
  `TruthRankIndex` answers exactly, independent of K. A tile whose
  `body.dags` sha256 disagrees with the manifest is refused, never
  loaded silently, and the refusal is recorded (not just thrown).
- Reachable over the daemon socket and MCP as `SAVE TILED <dir>
  <b1,b2,...>`, `TILED OPEN <dir> [<K>]`, `TILED BFS <id> <globalId>
  <depth> [BACK]`, `TILED SELECT <id> <truth> <lo> <hi>`, `TILED
  STATUS <id>`, `TILED LIST`, `TILED CLOSE <id>` — deliberately NOT a
  twin-spec verb family: a router is never persisted, never
  WAL-logged, never part of a snapshot (the tile directory on disk IS
  the durable state); it lives on the daemon handler
  (`tiledRouters: [String: TiledRouterEntry]`), ids `x%08x` from a
  handler-local counter. `STATUS` carries `tiled_open=<n>` separately
  from `twin_open=<n>`. Reader sessions may run
  `BFS`/`SELECT`/`STATUS`/`LIST`; `OPEN`/`CLOSE`/`SAVE TILED` are
  forbidden there (mutate the registry or the filesystem). MCP:
  `dagdb_save_tiled`, `dagdb_tiled_open/bfs/select/status/close`.
- Gate contract: T1 (tile files, bit-for-bit reload) held; T2 (tiled
  == untiled) held across sides 16/44/128 × tilings 2/4/8 × K ∈
  {1,2,4,8}; T3 (residency, K-bounded, evicts printed) held; T4 (torn
  tiles refused, recorded) held; T5 (daemon verbs) held, including the
  socket-level cross-check against the daemon's own `BFS`/`SELECT`
  verbs on the side-44 object; T6 (bytes/write-time/crossing counts)
  printed, not gated.

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
  BFS depths (undirected/backward), twin primitives (above), bank
  registry (waveform mouth, above).

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
