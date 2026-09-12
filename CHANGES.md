# Changes

Session-by-session log. Most recent first. Humble disclaimer: amateur
engineering project, no competitive claims.

---

## 2026-09-10 — correction: the rank bound stopped bounding the computation

Branch `dag/rank-bound`, built on `main`. Gate contract:
`docs/contracts/RANK_BOUND_GATES_FROZEN.md` (R1–R5, amendments 1–2).
Kind of run: CONTROL / RE-DERIVATION for R1 (both tick modes must
agree, and both must equal an expectation computed on the CPU outside
the engine), INTERFACE for R2–R4.

**The defect.** `DagDBEngine.rebuildCompaction()` put a node in its
(rank, colour) dispatch bucket only when its rank was below the
configured `maxRank`, and both rank-mode loops strode over exactly
those levels. A node at or above `maxRank` was therefore never
computed by rank-mode `TICK` — while `tickSync` dispatches over all
nodes and did compute it. Nothing refused the state: `SET RANK`
checked only that the node index existed, and the bulk rank commit
said in its own comment that it skipped validation. The daemon
answered `TICK` with `OK` and a rising tick count while part of the
graph stood still. Present in the engine as shipped, including public
v0.2.0.

**The path that reaches it in the field** (the hole named by an independent hostile read, adopted as R1):
not a hand-injected rank, but a restore. A graph saved from a daemon
configured with a large bound and loaded into one configured with a
small one carries ranks above the running bound without touching any
refused verb — and moving a graph between configurations is exactly
what SAVE/LOAD is for.

**Ruled: compute, do not refuse.** The bound is an allocation hint,
not a property of the graph — the field's own comment calls it
"Number of ranks in the DAG" and defaults it to 16 — and nothing in
Metal is sized by it. The segment table and the rank loop are
CPU-side, so covering every rank present costs a longer loop over
mostly-empty segments and nothing else. Refusing instead would leave
a graph restored under a smaller bound dead in rank mode until the
operator restarted the daemon.

- **R1 (the fix).** `rebuildCompaction()` now scans `rankBuf` for the
  highest rank actually present and sizes the buckets and the segment
  table to `effectiveRankCount = max(maxRank, highestRankPresent + 1)`;
  both rank-mode loops (`tick`, `tickLegacy`) stride over
  `effectiveRankCount`. `maxRank` keeps its meaning everywhere else —
  engine init, STATUS, the fold schedules. `effectiveRankCount` and
  `highestRankPresent` are public read-only on the engine. The scan is
  clamped at `nodeCount`, so a corrupt buffer carrying an absurd rank
  cannot turn the table allocation into a denial of service.
- **R2 (the operation says how much it did).** `OK TICK` and
  `OK TICK_SYNC` now carry ` nodes_computed=<n>` always — the whole
  command's node-evaluations, per-tick slots times the tick count —
  and, when the graph reaches past the configured bound, also the
  bound pair: rank mode prints ` ranks=<levels> bound=<maxRank>` (the
  levels it dispatched), sync mode prints
  ` rank_max=<highest> bound=<maxRank>` — the same news as a fact about
  the graph, because sync does not dispatch by rank and `ranks=` there
  would imply a bounded dispatch it never performed. A
  restored-under-a-smaller-bound graph announces itself on the wire at
  the first tick either way.
- **R3 (the door).** `SET <node> RANK <v>` with `v >= nodeCount` is
  refused with `ERROR out_of_range: rank <v> not in 0..<<nodeCount>`
  and the rank buffer is untouched; no valid DAG on N nodes holds a
  rank of N or more. `SET_RANKS_BULK` checks the whole vector before
  writing anything and names the first offending node. A rank in
  `[maxRank, nodeCount)` is accepted and computed — that is the point.
- **R4 (pre-existing state, catchable without ticking).** `VALIDATE`
  adds a rank-bound line naming the count of nodes at or above the
  running bound, the first of them, and the highest rank found —
  reported after the edge checks, so a genuine edge violation still
  surfaces first. The load path does NOT refuse: a snapshot written
  under any bound still loads. `STATUS` prints `ranks=<levels>` and
  `rank_max=<highest present>` beside the existing `maxRank=`, so a
  health check compares two printed numbers instead of doing
  arithmetic on one. Every field STATUS printed before is still
  printed, in the same relative order.
- **R5 (no regression).** Full suite green: 761 tests, 45 skipped, 0
  failures.

New: `dagdb/Sources/DagDB/RankBoundFixture.swift` (the 22-level object,
one edge crossing rank 8), `dagdb/Tests/DagDBTests/RankBoundTests.swift`
(R1 control, expectation re-derived in the test from the LUT6 tables
and the neighbour slots), and
`dagdb/Tests/DagDBDaemonKitTests/RankBoundDaemonTests.swift` (R2–R4 on
the wire — the contract names `HandlerFixture`, which lives in that
target).

The third rank-mode loop, fixed with the other two:
`DagDBEngine+Graph.tickWithResonance` — a public method with no caller
in the tree — strode over `maxRank` and carried the identical defect.
The builder named it rather than touching it, correctly, since it sits
outside the contract's scope. It is fixed here anyway by the same
mechanism (`ensureRankTopology()` then `effectiveRankCount`), because
shipping a correction for one instance of a defect while a second
instance of it stands in the same file is the very shape this contract
was written against. It is NOT separately gated — nothing calls it —
and that is stated rather than implied.

---

## 2026-09-10 — tiling, step one: tile files, router load/evict, cross-tile BFS/select

Branch `dag/tiling`, built on `main`. Roadmap item 8, step one of
`docs/tiled-streaming.md`'s build order (spec steps 3–4). Gate
contract: `docs/contracts/TILING_GATES_FROZEN.md` (T1–T6, amendments
1–2). Kind of run: CONTROL / RE-DERIVATION for the cross-tile queries
(tiled == untiled, exactly), INTERFACE for the files and daemon verbs,
MEASUREMENT for load/evict cost — no new number, the single engine's
own answers are the truth.

- **T1 (tile files).** `TiledGraphFiles.write` splits a DAG by rank
  range into `tile_<lo>_<hi>/{body.dags, halo_lower.bin, halo_upper.bin,
  meta.json}` plus a graph `manifest.json` (tile list, crossings,
  per-tile body sha256). `body.dags` is the CURRENT snapshot format
  (v7), not a frozen v3 — the contract's one amendment to the spec's
  wording. This session added a second entry point,
  `TiledGraphFiles.write(engine:grid:dataRoot:name:boundaries:)`,
  splitting the DAEMON'S OWN live engine directly (`SAVE TILED`'s
  object) rather than only a `TiledFixture.Object` — it scans
  `rankBuf` for the true highest rank present instead of trusting
  `engine.maxRank` (that's an allocated bucket count, not necessarily
  the highest rank actually written), so `runSelect`'s overlap test
  stays correct for a live engine whose rank lane doesn't use every
  allocated level. `TiledFixture.populate(engine:grid:side:)` was
  split out of `TiledFixture.generate` so a caller that already owns
  an engine (a daemon test fixture) can write the frozen object into
  it directly; `generate` is now a thin wrapper around it.
- **T2 (tiled == untiled).** Cross-tile `runBFS` (undirected/backward,
  level-synchronous across tiles, minimum depth over all paths),
  `runAncestry`, `runSelect` on `TiledGraphRouter` match the single
  engine's `DagDBBFS.bfsDepthsUndirected`/`bfsDepthsBackward` and the
  truth/rank secondary index exactly, independent of K.
- **T3/T4 (router).** LRU load/evict bounded by K; a torn tile body
  (sha256 mismatch against the manifest) is refused, never loaded
  silently, and the refusal is recorded (`TILED STATUS`'s
  `refused=<n> last=<error>`).
- **T5 (daemon, this session's main build).** `SAVE TILED <dir>
  <b1,b2,...>` → `OK SAVE TILED dir=<dir> tiles=<n> nodes=<N>
  crossings=<c>`; `TILED OPEN <dir> [<K>]` → `OK TILED OPEN
  id=x%08x tiles=<n> nodes=<N> resident_max=<K>`; `TILED BFS <id>
  <globalId> <depth> [BACK]` → shm `[u32 count][u32 16]` rows (u64
  global id, u32 depth, 4 pad) → `OK TILED BFS ... count= loads=
  evicts=`; `TILED SELECT <id> <truth> <lo> <hi>` → shm `[u32
  count][u32 8]` sorted u64 ids → `OK TILED SELECT ... count=`;
  `TILED STATUS <id>` → `OK TILED STATUS id= resident=<n>/<K> loads=
  evicts= refused=<n> last=<error|none>`; `TILED LIST` / `TILED CLOSE
  <id>`. Routers live on the HANDLER (`tiledRouters: [String:
  TiledRouterEntry]`), NOT in `TwinState` — a router is never
  persisted, never WAL-logged, never part of a snapshot; the tile
  directory on disk IS the durable state. `STATUS` gained
  `tiled_open=<n>`; routers do NOT count toward `twin_open`.
  `TiledGraphRouter` is a Swift actor and the handler's dispatch is
  synchronous, so one small helper (`runTiledSync`, in the new
  `DagDBCommandHandler+Tiled.swift`) bridges a single actor call
  through a `DispatchSemaphore`-blocked `Task` — the daemon's existing
  one-command-at-a-time serialization is unchanged, this only gives
  the synchronous dispatcher a way to make one `await` call and wait
  for it. Reader sessions may run `BFS`/`SELECT`/`STATUS`/`LIST`;
  `OPEN`/`CLOSE`/`SAVE TILED` are forbidden there (mutate the router
  registry or the filesystem). MCP: `dagdb_save_tiled`,
  `dagdb_tiled_open/bfs/select/status/close`; bridge.py's read-only
  allowlist gained the four read-only TILED sub-verbs.
- **Tests**: `Tests/DagDBDaemonKitTests/TiledCommandTests.swift` (26
  cases — DSL grammar, SAVE TILED/TILED OPEN summary lines checked
  against an independently computed `WriteReport` rather than
  hardcoded numbers, TILED BFS/SELECT cross-checked row-for-row
  against the daemon's own `BFS_DEPTHS`/`SELECT` verbs, the T4 torn-
  body refusal end to end over the socket, the reader-session split,
  `TILED CLOSE` → `LIST count=0`). Full suite: **752 Swift XCTest
  cases, 45 skipped (unchanged from baseline), 0 failures.**

**Not done** (explicitly out of this contract's scope, per its "Not
promised" list — steps 5–6 of the spec's build order): pre-fetch,
ticking across tiles, the cold tier, thermal pauses, the 10¹¹-node
run, `TILED BACKUP`.

---

## 2026-09-10 — attention hook: the sealed allocator as a ticked process (roadmap item 7)

Branch `dag/hook`, built on `main`. Roadmap item 7: the sealed
allocator court as a daemon-global ticked engine process. Instead of
one batch `AllocatorCourt.run` call, an attention "hook" is bound to
an alarm set, a budget layout (the tariff; sealed by default), a
per-frame budget B, a lag Δ (3), and one of three lagged policies
(allocator, greedy, uniform — the oracle has no lag and stays a court
arm, not a hook policy) plus, optionally, a master clock. Each `HOOK
STEP` advances the hook's frame counter t by one: at frame t it reads
the alarm of source frame t − Δ, decides what to buy under B (cheapest
tier with read value 1 in the claimed pocket for allocator, the
deepest affordable tier in the source alarm's pocket for greedy,
nothing decided for uniform beyond its flat frame cost), books the
purchase, and appends one line to its ledger. Bound to a clock, one
CLOCK ADVANCE tick is exactly one hook step, applied after the gears —
attention is spent on the engine's clock, not by a batch call. Kind of
run: CONTROL / RE-DERIVATION against the sealed allocator court (P4
gate 1) — no new number.

Gate contract: `docs/contracts/HOOK_GATES_FROZEN.md` (H1–H6, amendment
1 fixing the ledger row layout at 40 bytes aligned and the
countsTowardCost-on-a-judged-non-quiet-miss letter).

- H1 (ledger equals the court, control): `hook.result ==
  AllocatorCourt.run(records:budget:)[policy]` — Swift `Equatable`, no
  tolerance — held at all 5 sealed grid points × 3 policies.
- H2 (per-frame ledger, interface): one row per step — t, src, judged,
  outcome ∈ {hit, miss, none}, class, ear, pocket, tierBought, spend,
  countsTowardCost, cumulativeCost. A judged frame whose source is
  quiet is `none`: allocator/greedy buy and book nothing, uniform pays
  its flat frame cost and books cost with no hit/miss. Warm-up rows (t
  = 1..Δ) are `judged = false`; uniform books their spend into
  `warmupCostExcluded` (never into `cost`) and still updates
  `maxSpendRatio`; allocator/greedy warm-up rows spend 0.
  `cumulativeCost` is judged spend only. Identities held over the 203
  sealed rows. The ledger is DERIVED, never stored — rebuilt by
  re-stepping.
- H3 (persistence and replay): WAL opcode 0x2F (`hookOpen`) / 0x30
  (`hookStep`); snapshot v7's `hooks` field persists parameters plus
  the frame counter t only, the ledger rebuilt by re-stepping on
  restore. Closing an alarm set or budget layout a hook depends on
  refuses: `ERROR forbidden: hook <h> depends on <id>`.
- H4 (clock binding, ruled): a hook bound to a clock has one driver —
  `HOOK STEP` refuses `ERROR forbidden: bound to clock <c>`; `CLOCK
  ADVANCE` steps every bound hook once per tick, after the gears;
  `CLOCK CLOSE` cascades to bound hooks (`hooks_closed=<n>` beside
  `gears_closed=<n>`), same shape as a gear. Bound and unbound hooks
  gave equal results at one grid point, asserted both ways.
- H5 (daemon): `HOOK OPEN/STEP/STATE/LEDGER/INFO/LIST/CLOSE` over the
  socket, DSL, MCP, and the web bridge; reader sessions may run
  STATE/LEDGER/INFO/LIST, never OPEN/STEP/CLOSE. The ledger's shm row
  is 40 bytes fixed-width, 8-byte aligned. Over the socket, `HOOK
  STATE` after 203 steps at the richest sealed grid point prints
  `served=150 misses=0 cost=819218.0` for the allocator policy (the P4
  line) and `served=50 misses=100 cost=94400.0` for uniform.
- H6 (printed, not gated): ≈0.9 µs per step (allocator policy, sealed
  layout, debug build); cumulative cost 0 / 501710 / 538024 / 819218
  at t = 50/100/150/203 at the richest sealed grid point.

New engine surface: `AttentionHook` (`dagdb/Sources/DagDB/
AttentionHook.swift`) — fixed params (alarm id, layout id or nil for
the sealed default, budget B, lag Δ, policy, optional clock id),
`step()`/`step(n:)`, the derived per-frame ledger. An eleventh
daemon-global registry (`TwinState.hooks`, prefix `h`) plus
`ClockEntry.hookIds` (hooks a clock drives, stepped after its gears,
closed on `CLOCK CLOSE`). Wired over the daemon socket/DSL/MCP/bridge
as `HOOK OPEN/STEP/STATE/LEDGER/INFO/LIST/CLOSE`
(`dagdb/Sources/DagDBDaemonKit/DagDBCommandHandler+TwinHook.swift`,
`DSLParser+Twin.swift` `parseHook`).

Results: H1 `==` at all 5 grid points × 3 policies; H4 bound vs
unbound equal; H5 lines exact over the socket; H6 ≈ 0.9 µs/step,
cumulative cost 0/501710/538024/819218 at t = 50/100/150/203.

Suite: 710 tests. 45 skips with neither fixture env set (30 with the
`DAGDB_W2_FIXTURE` fixture alone — the sealed hook tests are gated on
the same W2 fixture as the allocator court, no new fixture). 0
failures.

Not done: not merged to main (Haruth merges); the hook does not yet
consume the derived-views feed (roadmap item 7's own note on that);
no `HOOK BUDGET` re-declaration (ruled out — a different B is a
different hook).

---

## 2026-09-10 — kernels: per-path storage and the sealed cross-convolution residual (spec line 6)

Branch `dag/kernels`. The second half of spec line 6: per-path
kernels (impulse responses root→ear, 2048 taps at fs = 3000 Hz)
stored in the engine by reference and by id, a per-pair warmup
declared or derived, and the cross-convolution identity
kB ⋆ a = kA ⋆ b judged by the W1 court's own frozen residual R —
not the engine's pre-existing `CrossConvolutionCheck.check` ("XCONV
CHECK", the standing patrol check from the summer's twin-primitives
pass). Kind of run: CONTROL / RE-DERIVATION against the sealed W1
court (PASS: G0 bridge, G1 court 50/50, G2 fakes 50/50, G3 perturbed
50/50).

One finding, stated up front by the contract itself: `XCONV CHECK`
is NOT the court's R. It compares over the full convolution length
(n + m − 1 samples) instead of the record window, divides by a
symmetric denominator `max(|kB⋆a|, |kA⋆b|)` instead of the one-sided
`max|kB⋆a| + 1e-300`, and takes Float32 records and taps instead of
Float64 end to end. On the 190 sealed W1 trials the patrol check
flips 50 of 190 court gates — every one of them a TRUE court
recording — because it compares past where the identity actually
holds. `XCONV CHECK` stays wired, documented as a compatibility
patrol check, not a court check; `XCONV SEALED` is now spec line 6's
standing cheap check.

Gate contract: `docs/contracts/KERNELS_GATES_FROZEN.md` (K1–K5, 3
amendments — the trial count corrected to 190, K1's absolute bound
recorded as an expected FAIL at the float64 floor and replaced as
the standing gate by a relative bound K1', and XCONV CHECK formally
deprecated in favor of XCONV SEALED).

- K1 (absolute, frozen, recorded as a floor finding): FAIL on 2 of
  190 trials — fake_34 (R 16.44) and fake_48 (R 24.70) miss the
  2.533e-14 absolute control tolerance by 3.9e-14 / 6.4e-14, relative
  2.4e-15 / 2.6e-15 — the float64 summation-order floor of two
  different convolution orders, not the identity. K1' (amendment 3,
  the standing gate): |R_engine − R_python| ≤ 3e-15·max(1, R_python)
  holds on all 190.
- K2 every court line re-derived: G0 6.151e-15 vs the court's
  4.101e-15 (both ≤ 2.533e-14, the printed digits are summation-order
  noise at the floor); worst court trial 5.415e-03, 50/50 within
  tolerance; fakes 50/50 over 10×tolerance; perturbed 50/50 over
  tolerance, quartiles 1.019e-01 / 1.032e-01 / 1.052e-01; cal
  reference max 3.348e-03 (not gated).
- K3 storage and reach: `KERNEL LOAD`/`INFO`/`LIST`/`CLOSE` and
  `XCONV SEALED` over the socket, DSL, and MCP; kernels persist BY
  REFERENCE (path + sha256), never their taps — registry prefix `k`,
  WAL opcode 0x2E, snapshot v7's `kernels` field (tolerant decode); a
  missing or hash-changed file on restore drops that entry with a
  WARN, same rule as ALARM/VIEW/BANK.
- K4 warmup = ceil((|τ_A − τ_B| + 3·σ_source)·fs), 185 for W1,
  derived from τ_A/τ_B/σ_source DECLARED on `KERNEL LOAD` (never read
  from the kernels file); an explicit warmup on `XCONV SEALED`
  overrides and prints "declared, not derived"; a pair loaded without
  TAU/SIGMA has no default and `XCONV SEALED` then requires one
  explicitly.
- K5 printed, not gated: wall ms per sealed check; the patrol
  check's residual beside the sealed R, attributed to its three
  formula differences separately (full-length window, symmetric
  denominator, float32 inputs) — each attributed variant matches its
  numpy reference to ≤ 6.4e-14; max |R_patrol − R_sealed| = 23.68 at
  fake_48.

New engine surface: `KernelPair` (load-by-path with sha check, the
K4 derived-warmup rule) and `SealedCrossConvolution` (the frozen
formula plus the K5 attribution breakdown) in `dagdb/Sources/DagDB/`;
wired over the daemon socket/DSL/MCP as `KERNEL LOAD/INFO/LIST/CLOSE`
+ `XCONV SEALED`
(`dagdb/Sources/DagDBDaemonKit/DagDBCommandHandler+TwinKernel.swift`,
`DSLParser+Twin.swift` `parseKernel`). Read-only for reader sessions:
`XCONV SEALED`, `KERNEL INFO`, `KERNEL LIST`.

Fixtures: `dagdb/Tests/Fixtures/w1_kernels.json` (in repo, 144,554
bytes, sha256 pinned) and `w1_residuals_v1.json` (in repo, ≈34 KB,
the frozen-formula reference per trial plus the court's gate lines,
sha256 pinned, produced by `dagdb/scripts/w1_residuals.py`); the 190
W1 records themselves (18,580,321 bytes) stay out of repo, env
`DAGDB_W1_RECORDS`, sha256 pinned — absent skips the sealed tests,
present with the wrong hash FAILs, never a silent load of a
different fixture. The sealed run takes ≈10 minutes in a debug
build.

Suite: 655 tests, 39 skips without `DAGDB_W1_RECORDS` set (5 new
kernel skips: 3 in `SealedCrossConvolutionTests`, 2 in
`TwinKernelCommandTests`, on top of the prior branch's skips), 0
failures.

Not done: not merged to main (Haruth merges); kernels do not yet feed
the allocator court or the derived views.

---

## 2026-09-10 — derived views (spec line 4, second view family)

Branch `dag/derived-views`. A second view family over the alarm-set
world, sitting beside the allocator court that already covers spec
line 4: three views the twin's cortex lane needs, each judged against
numbers its own reference hand sealed the same day — front-aligned
energy features and a geometry-then-energy rung, the amended-letter
reflex with its tied sets and oracle-tie count, and the
arrival-geometry ceiling from τ alone. Kind of run: CONTROL /
RE-DERIVATION — every pin already exists, no learner number is asked
of the engine.

Gate contract: `docs/contracts/DERIVED_VIEWS_GATES_FROZEN.md` (1
amendment, letter e3's 3·S pair count; no gate bound moved). All gates
held exactly at S = 2/4/6/8:

- V1 Reflex hits: 3 / 11 / 15 / 18.
- V2 Oracle-tie hits: 233 / 72 / 76 / 65.
- V3 Tied sets: size min/median/max 52/77.0/129 · 1/5.0/129 ·
  1/4.0/129 · 1/2.0/23; frames with a tie (size > 1) = 300/253/242/231.
- V4 Geometry-then-energy hits (centroids from the 6966 train frames):
  38 / 28 / 29 / 39.
- V5 Ceiling: 0.069767 / 0.147287 / 0.209302 / 0.271318 (identifiable
  9/19/27/35 = unique 3/8/12/15 + groups 6/11/15/20; exact-twin pairs
  2495/1015/711/467).
- V6 daemon interface (VIEW LOAD/REFLEX/RUNG/CEILING/FEATURES/INFO/
  LIST/CLOSE, exact reply shapes) holds.
- V7 printed, not gated: wall time per view; near-edge candidate
  counts 22048/3814/2640/1017; rung margin (second − best distance,
  min over tied frames) 7.1e-4/1.6e-3/8.1e-4/2.1e-4.

New engine surface: a hand-rolled `NpzReader` for STORED
(uncompressed) npz archives — zip central-directory sizes, npy v1–v3
headers, f4/f8/i8 — no third-party code, because the fixture
(`cortex_v4_world.npz`, 15,145,646 bytes, out of repo, env
`DAGDB_CORTEX_V4_FIXTURE`, sha-pinned, skip if absent / FAIL on hash
mismatch) needed reading. `CortexFixture` loads and validates it
(shapes, label range 0..128, 6966 = 129·54 with every class exactly
54). `DerivedViews` computes the three views, the per-candidate
least-squares fit going through LAPACK `dgelsd_` (Accelerate) with one
workspace query per frame. Wired over the daemon socket/DSL/MCP/bridge
as an eight-verb `VIEW` family (LOAD/REFLEX/RUNG/CEILING/FEATURES/
INFO/LIST/CLOSE), registry prefix `v`, WAL opcode 0x2D, snapshot
`views` field (tolerant decode); view sets persist BY REFERENCE (path
+ sha256) — a missing or changed file on restore drops that entry with
a WARN, same rule as ALARM. Read-only for reader sessions: REFLEX,
RUNG, CEILING, FEATURES, INFO, LIST.

Tasks: V-S1 built `NpzReader` + `CortexFixture` and surfaced the
label/shape assertions. V-S2 built `DerivedViews` (arrivals, the
amended reflex with tied sets and the printed near-edge floor,
front-aligned energy features with 3·S per-(station, channel)
standardization, the centroid rung, and the ceiling under both
relations) — V1–V5 exact at every S. V-S3 wired the daemon `VIEW` verb
family, MCP tools, and the bridge's read-only allowlist.

Suite: 570 tests. 32 skips with neither fixture env set (the 9
pre-existing `DAGDB_W2_FIXTURE`-gated skips, unchanged, plus 23 new
`DAGDB_CORTEX_V4_FIXTURE`-gated skips: 14 in `TwinViewCommandTests`, 6
in `CortexFixtureTests`, 3 in `DerivedViewsTests`); 9 skips with
`DAGDB_CORTEX_V4_FIXTURE` set (the pre-existing `DAGDB_W2_FIXTURE`
skips only — unrelated fixture, still unset). 0 failures.

Not done: not merged to main (Haruth merges); the views registry does
not yet feed the allocator court (spec line 4's first family) or the
tick loop.

---

## 2026-09-10 — fold API (roadmap item 3)

Branch `dag/fold-api`. The E3 tier ladder — Kron/Schur fold of a rank
ring into the kept set, operator stored to Float32 between folds,
solves in Float64 via LAPACK `dgesv` — moved out of the sealed runner
(`E3Ladder/main.swift`, last arithmetic change 2026-08-26) into a
library call, `LadderFold.run(object:schedule:sources:)`, arithmetic
unchanged, and a daemon verb, `FOLD`. `e3-ladder` is now a thin CLI
over the library. `LadderFold.Object(engine:grid:)` reads the daemon's
own lanes — neighbors, edge weights, `nodeValue` as leak, rank — back
exactly as the runner's `Ladder.init` did; `LadderFold.Objects.control`/
`.court` write the frozen court objects INTO those same lanes before
reading them back, so a fresh daemon (neighbor table wiped, edges come
from `CONNECT`) folds whatever graph the lanes currently hold, hex
adjacency only if it was written there.

Gate contract: `docs/contracts/FOLD_API_GATES_FROZEN.md` (F1–F5). All
gates held:

- F1 control (in repo, `dagdb/Tests/Fixtures/e3_control_engine.json`,
  sha pinned): `kept_nodes`, `final_operator`, `folded_f1` bit-for-bit.
- F2 court ladders (out of repo, `DAGDB_E3_RUNS`; skip if absent, FAIL
  on hash mismatch): G1/G2 bit-for-bit against the sealed run files —
  G1 19 folds, ~153 s in a debug build (the court's ~1.6 s/profile was
  a release build).
- F3 the rebuilt `e3-ladder control` CLI's output sha equals the
  control fixture's pin.
- F4 daemon verbs — `FOLD RUN <maxRank> <keepRank> <f1> <f2> [<f3>]
  [CHECK l1,l2,...]`, `FOLD KEPT`, `FOLD SOURCE <1|2|3>`, `FOLD TIER
  <level|final> <1|2|3>`, `FOLD INFO` — bit-identical to the library
  call over the socket; all read-only, nothing persisted (the last
  result is held in the handler, recomputable from the lanes); a FOLD
  verb before any RUN is `ERROR not_found`. A FOLD RUN whose predicted
  kept-set size would overflow shm is rejected before any O(k³) work
  runs, via a configurable `shmBytes` capacity on the handler.
- F5 price, printed not gated: per fold, ring/eliminated/kept/wall ms;
  per tier, bytes = k²·4 + k·3·4.

Test suite: 544 Swift XCTest cases, 10 fixture-gated skips without
`DAGDB_E3_RUNS` set (9 with it). New: `LadderFoldTests.swift` (5,
library-level F1/F2/F3) and `TwinFoldCommandTests.swift` (17,
daemon-level F4), plus new `parseFold` grammar cases in
`DSLParserTwinTests.swift`.

Tasks: F-S1 built `LadderFold` against the frozen contract, moved the
runner's arithmetic verbatim, closed F1–F3. F-S2 wired the `FOLD` verb
family over the daemon socket, DSL grammar, and MCP, closed F4/F5.

---

## 2026-09-10 — spec 8 waveform mouth

Branch `dag/spec8-mouth`. Spec 8 of the twin's nine-line list: a frozen
bank Φ of T×K atoms (harmonic cos/sin columns plus Gabor atoms on a
center/frequency grid, each column unit-normalized), hosted by the
engine as `WaveBank`. Generating M waveforms is one matrix product
W = Φ·C via `cblas_sgemm`; fitting a target waveform back to
coefficients is a least-squares solve via LAPACK `dgelsd` (SVD); the
bank declares its own rank and condition number (`dgesdd`) at creation,
printed before any probe. Wired over the daemon socket and MCP as an
eight-verb `BANK` family (OPEN/GENERATE/FIT/NOISE/BENCH/INFO/LIST/
CLOSE), WAL opcode 0x2C, snapshot v7's `banks` field, following the same
log-first pattern as the other twin verb families.

Gate contract: `docs/contracts/SPEC8_MOUTH_GATES_FROZEN.md` (3
amendments, no gate bound moved). All gates held:

- G1 Φ bridge (control): max diff 0.0 against the numpy mouth (tol 2e-6).
- G2 W bridge (control): max diff 0.0, Frobenius relative error 2.1e-7.
- G3 out-of-bank noise law (claim, control bank): engine mean
  0.9816015 vs. law √(1−160/4096) = 0.9802742 (per-seed range
  0.9750986–0.9855909, bands 0.035 per seed / 0.008 mean); numpy mean
  0.9823351 printed beside it.
- G4 probe bridge (control): engine residual 0.9989332144 vs. the
  fixture's numpy residual 0.9989332557 (tol 1e-3).
- G5 in-bank sanity: residual ~1e-7 (bound 1e-5).
- G6 throughput (measured, not gated): 2.46e9 samples/s at K=160,
  2.83e9 at K=144, M=10000, best-of-3 — beside the numpy mouth's
  2.23e9 (control) / 1.95e9 (repair, one timing).
- G7 daemon round trips (WAL replay, snapshot v7 save/load) hold.
- G8 declaration: control bank rank 146 of K=160 (cond 5.6e15
  printed); repaired bank K=144, rank 144, cond 2.666132 (tol 0.01);
  aliasing message names harmonic 26 at 1560 Hz against Nyquist
  1500 Hz (fs 3000); repaired-bank probe residual 0.998949, noise
  mean 0.981743 vs. law 0.982265.

Finding: the sealed 160-atom reference bank is rank-deficient — at
H=32, harmonics 26..32 lie above Nyquist and alias exactly onto
harmonics 24..18, so fourteen of its atoms are linearly dependent
(true deficiency, float64 condition number 2.408e12, not a float32
artifact). The twin lane diagnosed and repaired it: H=24 keeps every
harmonic below Nyquist, giving K=144, full rank 144, condition number
2.666. The engine keeps the 160-atom bank as the sealed CONTROL object
for G1–G5 and adopts the repaired bank (K=144) as the default the
daemon opens; a spec whose top harmonic reaches Nyquist is refused
unless the caller writes `ALIASED` on the OPEN line.

Tasks: S1 built the library (`WaveBank.swift`) against the frozen spec
and surfaced the rank-deficiency finding. S2 wired the daemon/DSL/MCP
`BANK` verb family and the WAL/snapshot persistence. S3 ran G1–G7
against the fixture and the live socket. S3b re-derived amendment 2's
noise-law literal, caught a second author arithmetic slip (amendment
3), and closed out G8.

Suite: 506 tests, 9 fixture-gated skips (unchanged set), 0 failures.

Not done: the bank is not fused into the tick loop; no Metal path
(Accelerate on the CPU side of the UMA is the host).

---

## 2026-09-09 — startup recovery (roadmap item 4)

Branch `dag/startup-recovery` off main. One gap, found by the socket
smoke on 2026-09-06: a daemon restart after `SAVE` came up empty because
`SAVE` checkpoints the WAL, startup replays only records past the last
checkpoint, and nothing loaded the snapshot.

- `DagDBStartup.recover` (DaemonKit): optional snapshot load (env
  `DAGDB_STARTUP_LOAD`) BEFORE WAL replay, in one function that
  `main.swift` and the tests share. Missing file = first boot, starts
  empty. Unreadable file or a path outside the data root = fatal exit 2:
  starting empty over a WAL whose checkpoint already assumes that state
  would silently diverge. WAL replay failure keeps the old "continue
  without WAL" behaviour. A snapshot older than the WAL's last checkpoint
  prints a WARN (ticks are the only shared clock, so this catches some
  misconfigurations, not all).
- `DagDBCommandHandler.durableSnapshot(path:compressed:)`: snapshot then
  WAL checkpoint, factored out of `SAVE`; the autosave on graceful
  shutdown now uses it too. Before, the autosave wrote no checkpoint —
  with a startup load in place that would have replayed the tail twice,
  and `RECORD SLICE`, `RINGS WRITE`, `CLOCK ADVANCE` are not idempotent.
- `main.swift`: the WAL block moved below the data-root/index setup so
  recovery can use them; handler starts at the snapshot's tick count;
  stdout line-buffered (`setlinebuf`) so a redirected or launchd log
  shows startup lines before a hard kill.
- Tests: `StartupRecoveryTests` (7) — restart after SAVE restores graph +
  twin with no LOAD and replays exactly the post-SAVE tail; nothing
  configured = no-op; missing snapshot starts empty and replays the whole
  log (tick-derived truth is not recoverable from the log alone, which is
  the reason the snapshot load exists); outside-root and `..` rejected;
  corrupt snapshot throws; durable snapshot → 0 records replayed; older
  snapshot warns. Suite 446 (9 fixture-gated skips).
- Live socket smoke `examples/twin_primitives/socket_smoke.sh`: 23/23 on
  the wire — SAVE, hard kill, restart with no LOAD (`twin_open=4`, stream
  state byte-identical, `fires=4285`, truth restored, 0 records replayed);
  graceful stop then restart (autosave + checkpoint, 0 replayed); tail
  then hard kill (exactly 2 replayed); corrupt and out-of-root snapshots
  exit 2. Refuses to run while any daemon is alive (shared shm file).
- Not done: the prod launchd plist still lacks `DAGDB_STARTUP_LOAD`;
  adding `…/prod/auto.dags` there is a config change for the operator to make.

---

## 2026-09-06 — interface phase

Branch `dag/p4-interface`, off main at the 2026-09-05 twin-primitives
merge (baseline 249/249). One goal: make the seven twin-spec primitives
restorable (state-bearing inits + Codable) and reachable over the
daemon (DSL + MCP), and add the spec-4 alarm-stream type whose engine
implementation reproduces the sealed allocator court and successor
lattice bit-for-bit. Full suite at the end of the phase: **439 tests,
9 skipped (fixture-gated), 0 failures** (`swift test`, 2026-09-06).
Merged to main 2026-09-06 (rollback tag `pre-merge-p4-20260906`).

**Contract, frozen before any gate code:**
`docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md` commits the two gate tables as the
frozen criterion — prior work the two Python courts
(`market/build_court_allocator_runs.py` / `court_allocator_runs.json`,
`market/build_pregate_successor.py` / `pregate_successor_v1.json`),
delta = engine (Swift) re-implementation, run kind **control /
re-derivation**, never a claim. **AMENDMENT 1** (2026-09-06, an independent
hostile read, applied before any gate code existed, no number moved):
restore path keeps drop-with-WARN on a missing/mismatched alarm file,
but the **gate path is different — fixture absent → `XCTSkip` with a
printed reason; fixture present with hash ≠ pinned → the test FAILS,
printed as a finding, never skips, never warns.** Also corrected: the
frame-level burst phrase is NOT implemented (116 = pocket 6 count, not
150 = every non-quiet frame); the partial-tier/merge-rule coincidence
reason (pocket-6 r7 affordability is necessary, not sufficient — the
one-slot fact makes it infeasible to beat, and the best partial combo
loses on cost); the residual tie-break is unexercised on this object;
gate-2 exactness comes from every intermediate being an exact dyadic
rational inside 53 bits (not from loop-order superstition, though the
Python loop order is still mirrored, harmlessly); the gate-2 diagonal
column is **retention scoring** (a coincidental rescue counts; a
phantom is never itself a judged alarm).

**§0 conventions (17, resolved sealed-record ambiguities, sent out
for an independent hostile read), in brief:** file order reconstructed from
`(block rank quiet<liar<deep<drift, numeric suffix)`, 1-based `idx`;
`cal0_1` kept as `AlarmFixture.control`, never an `AlarmRecord`
(`records.count == 200`); quiet culprits carry `claim == nil` (buy
nothing under allocator/greedy/oracle, uniform still pays 472); drift
has `ear == nil`, pocket 6, row `L`; burst is alarm-level
(`pocket == 6`), the frame-level phrase is not implemented; phantoms
are `SealedClaim` values only, never an `AlarmRecord`; sealed ids
(pockets 3..6, tiers r3..r10) convert to `BudgetLayout`'s zero-based
indices via `pocketIndex(p) = p−3`, `tierIndex(r) = r−3`, `L→0`/`D→1`;
the merge rule and the successor's partial-tier options coincide in
value on the sealed grid only (pocket-6 r7 is affordable everywhere
non-cut, the cheapest r7 pair never is) — not rule equivalence; the
tie-break is unexercised on this object; gate 1 covers all 5 grid
points, gate 2 the 4 non-cut points (k7=0 is cut by the successor);
greedy/uniform are court rules (`AllocatorCourt`/`SuccessorCourt`),
not primitives, so gate and daemon share one implementation; twin
registries are daemon-global (a `READER` session may only read them);
id format is `"<letter>%08x"` of a per-registry counter that never
reuses a value, prefixes `s`/`t`/`n`/`c`/`g`/`b`/`a`; WAL logs
post-state for `STREAM NEXT` (O(1) replay), the count for
`RECORD SLICE`, the values for `RINGS WRITE`, `n`+value for
`CLOCK ADVANCE`; alarm sets persist by reference (path + sha256), a
missing/mismatched file on **restore** drops that entry with a stderr
`WARN` rather than refusing the whole load — the gate path's
wrong-hash-FAILS rule (above) is stricter and does not apply to
restore.

**Gate numbers reproduced bit-for-bit (T4, `SealedGateTests`, run
against the real 29 MB fixture, `DAGDB_W2_FIXTURE` set):**
- **Gate 1** (allocator-court replay): 5 budget-grid points × 4 arms
  (allocator, uniform, greedy, oracle), every field exact — misses,
  served, cost, dummy, dominated, per-class/per-ear tallies, burst,
  `maxSpendRatio`, `servedTrialIds`. Allocator == oracle at every
  point (P0 0/150/819218 … P4 100/50/4900).
- **Gate 2** (successor dyadic ε lattice): 4 non-cut budget points ×
  4 sweeps (m, s, n, diag) × 5 ε values {0, .25, .5, .75, 1}, compared
  with exact `XCTAssertEqual` on `Double` (never `accuracy:`) —
  misses_alloc, misses_greedy, cost_alloc all exact. Anchors: the
  corner (εm=1, εs=1, εn=0) gives misses = 100.0 exactly at all four
  points under both policies; `max |1 − weightSum| == 0.0` over the
  full 65-point lattice.

**Per-task entries (each is one commit on `dag/p4-interface`):**
- **Contract first** — `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md` committed before any
  gate code exists; the §0 conventions list sent out for an independent hostile
  read, applied as AMENDMENT 1 the same day.
- **T1a** — `NamedStream`/`StreamHeader`/`StreamRecord` gain
  state-bearing inits and `Codable` (public `Slice` init), so a
  daemon-held stream/record survives a restart in O(1) rather than
  redrawing.
- **T1b** — `BudgetLayout`/`CrossConvolutionCheck`/`GearedRings`/
  `MasterClock`+`GearRatio`+`PhaseGear` gain state-bearing inits,
  `Codable`, public output-struct inits, and throwing shape guards
  (`validationError`, `shapeViolation`) so a daemon front door can
  reject a bad shape with `ERROR bad_value` instead of trapping.
- **T2** — `AlarmRecord` + `SealedCourt` (sealed pocket/tier/tariff
  mapping) + `AlarmFixture` (SHA-pinned loader, env
  `DAGDB_W2_FIXTURE`, skip-if-absent) — twin spec line 4's fixed
  vocabulary, reconstructing file order from the sealed keys.
- **T3** — `CorruptionModel` (εm/εs/εn exact-enumeration weights,
  phantoms as `SealedClaim` values, never as `AlarmRecord`s) +
  `SuccessorCourt` (the counting hand: `allocatorDecide`,
  `greedyDecide`, `classStats`, `frameTotals`).
- **T4** — `AllocatorCourt` (mirrors `run_point` bit-for-bit) + the
  two sealed gates in `SealedGateTests`, against
  `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md`; wrong-hash-fails rule applied.
- **T5** — `TwinRegistry<Entry>` (the generalized reader-session
  pattern) + `TwinState` (one daemon-global instance of all seven
  registries, `TwinOp` apply, `Codable` `Snapshot`, `export`/`restore`).
- **T6** — WAL opcodes `0x20`–`0x2B`, `TwinWALCodec` (encode/decode,
  little-endian, malformed payload skipped not fatal),
  `DagDBWAL.replay(twin:)`.
- **T7** — Snapshot **v7**: `TWIN` section (magic `"TWIN"` + u32
  length + sorted-keys JSON) between the WGTS lane section and the
  ENVS trailer; loads v1..v7; a v≤6 file resets the twin state.
- **T8.1** — `TwinCommand` grammar (47 verb-lines), `DSLParser+Twin`,
  handler dispatch skeleton + the `READER` read-only allowlist, and
  the shared `HandlerFixture` test helper. Stub replies until T8.2–T8.5.
- **T8.2** — real STREAM/HEADER/RECORD handlers (log-first WAL
  pattern); `twinState` wired into the daemon's replay and save paths.
- **T8.3** — real RINGS/CLOCK/GEAR handlers; found and fixed a gear-
  close bug the same session: closing a `GEAR` left its id inside the
  owning `CLOCK`'s `gearIds`, so a later `CLOCK ADVANCE` would trip on
  a stale gear id — `TwinState.apply(.close)` on a `g` id now prunes
  the gear from its clock's `gearIds` before closing it.
- **T8.4** — real XCONV CHECK (reads two records + two path kernels
  out of shm, runs the sealed W1 identity, never touches the WAL) and
  BUDGET OPEN/SEALED/ALLOCATE/INFO/CLOSE/LIST handlers.
- **T8.5** — real ALARM handlers: LOAD (guardPath first, then
  SHA-pinned load — any `AlarmFixture.FixtureError`, including a
  hash mismatch, becomes `ERROR io:` containing the literal phrase
  "sha256 mismatch"), INFO/FRAME/COURT/SUCCESSOR/CORRUPT as pure reads
  over `AllocatorCourt`/`SuccessorCourt`/`CorruptionModel`.
- **T9** — MCP wrappers (26 twin verb tools) in `mcp_server.py`, the
  `dagdb_query` catalog's `Twin:` block + id-prefix map, the
  `dagdb_reader_query` allowed-list update; `web/bridge.py` gains
  `READ_ONLY_TWIN` (a set of `(verb, subverb)` pairs mirroring
  `TwinCommand.isReadOnly`) checked alongside the existing
  single-token `READ_ONLY_VERBS`.

**Live daemon socket smoke (2026-09-06, scratch env, concurrent with
this writeup):** 10 of 13 checks passed on the wire as expected —
`STATUS twin_open=`, `STREAM OPEN`/`STREAM NEXT` (the six reference
words read back from shm exactly), `CLOCK`/`GEAR` (`fires=4285`),
`BUDGET SEALED`/`BUDGET ALLOCATE` (`served=3 cost=5618.0`),
`HEADER CHECK` (`combBelowNyquist`), `SAVE` to a v7 snapshot, and an
explicit `LOAD` restoring the full twin state exactly (`draws=6`,
`fires=4285`, `twin_open=4`). The remaining 3 expectations exposed a
**pre-existing, pre-existing gap**: a plain daemon **restart** after `SAVE`
(no explicit `LOAD`) comes up with empty twin state — `SAVE`
checkpoints the WAL and startup only replays records past the last
checkpoint, with nothing auto-loading a snapshot at startup. Same
behavior for ordinary graph state (the prod launchd plist passes no
load step either); tracked as a new roadmap item, not an interface-phase defect.

---

## 2026-05-13 → 2026-09-05 — bulk verbs to twin-spec primitives

Ten sessions, May to September: bulk DSL
install verbs, a full Fable source-review sweep and its fixes,
nested-LUT microcircuits sanitized for the public tree, tick-
performance compaction, G73 durability hardening, weight-lane
persistence (E1) and its raw-throughput riders (E2/E3), a roadmap
draft, and seven twin-spec primitives merged to main. Full Swift
suite: **165 → 191** (June) → **218** (Aug 22) → **249** (Aug 30,
holds through the Sep 5 merge).

### 2026-05-13 — bulk-install DSL verbs for microcircuit compilation

`SET_LUTS_BULK` and `SET_NEIGHBORS_BULK` parallel the existing
`SET_RANKS_BULK`: each reads a vector from shm and memcpys it into
the matching engine buffer in one round-trip. Motivation: compiling
continuous-function approximators (EDT-style microcircuits) one
round-trip per node made a million-node graph build take a million
round-trips through `SET LUT` + `CONNECT`; bulk install collapses
the same compile to three shm writes (ranks + LUTs + neighbours) and
three verbs. Both bypass per-node WAL and rank-monotonicity
validation, matching the `SET_RANKS_BULK` contract (pair with
`VALIDATE` if the caller's compiler isn't trusted); both rejected
inside reader sessions. New `docs/wiki/microcircuit-compilation.md`
walks the recipe end to end — compile-time vs. eval-time speed, LUT
input packing, `BACK_EDGE` for recurrence instead of growing rank
depth, a worked x² example, and an anti-pattern list.

### Fable review fixes (June)

A full Fable source-review pass (engine, persistence, daemon, tile
layer, Python surface, tests) produced a findings report with one
live correctness bug, two crash/corruption hazards, Python contract
bugs, a security hole, and a structural test gap. All fixed in one
06-09 session bar one deferred item:

- **C1** — the reader-session snapshot copied `n*4` bytes of the
  rank buffer, but rank is u64 (`n*8`); every `OPEN_READER` session
  returned correct ranks for the lower half of the graph and
  zero/garbage for the upper half — silently wrong data on the
  shipped MVCC path. Fixed the copy width and strengthened four
  other tests that only checked the lower half and would have
  passed on this bug class.
- **H1** — a corrupt/crafted snapshot's back-edge trailer could
  carry a `dst` past `nodeCount`, corrupting the heap via an
  unchecked `isRegisterBuf` write; now bounds-checked and throws,
  matching what the WAL replay path already did.
- **H2** — a snapshot truncated mid-write (the crash-during-write
  case) trapped on an out-of-range `subdata` slice and killed the
  daemon instead of throwing; added length guards before both
  subdata calls.
- **P1-P3** — Python docstrings and helpers still claimed u32 for
  the bulk-rank vector after the daemon moved to u64; the two new
  bulk verbs were invisible to MCP clients; the "unbounded" rank cap
  used for hive queries was still 2^32-1 on a u64 axis. All
  corrected; the MCP query catalog regenerated from the actual
  parser surface (~20 missing verbs restored).
- **S1/S2/S3/B4** — the WebSocket browser bridge relayed any
  received string to the daemon's full write surface with no
  allowlist or Origin check; now read-only by default with an
  opt-in write flag, an Origin allowlist, control-char rejection
  (defends against command smuggling), and a socket timeout so a
  stalled daemon can't wedge an executor thread forever.
  `mcp_server.py`'s auto-`pip install` on import was deleted in
  favor of a printed instruction.
- **T1** — the DSL parser and command handler lived inside the
  daemon's executable target, untestable by the suite (the same
  drift hazard that hid C1 one layer up); extracted into a new
  `DagDBDaemonKit` library target with a testable
  `DagDBCommandHandler`.
- **T2-T4** — regression coverage for the fixes above, plus
  invariant-locking tests (GPU-vs-reference LUT6 equivalence,
  race-free 7-coloring, colour-group partition, chained `BACK_EDGE`
  one-tick latch), plus per-test temp directories so concurrent
  `swift test` runs stop racing on shared `/tmp` fixture names (the
  several checkouts share one dagdb working directory).

Full suite climbed **165 → 191** across the sweep (README corrected
06-24 after an adversarial read of the deck claims caught the stale
figure).

### Nested-LUT microcircuit + public-tree sanitization (July 1-2)

Committed the composition claim behind the microcircuit-compilation
recipe: a 40-gate, depth-7 LUT6 network (Wallace carry-save adder)
computes 4-bit × 4-bit multiplication exactly for all 256 inputs on
the Metal engine — P3..P7 need all 8 input bits, beyond any single
LUT6. Suite **191 → 192**. New `docs/wiki/nested-luts.md` documents
the single-LUT6 ceiling and the build idioms.

Same window, a honesty and public-tree sanitization pass:

- The 14 GCUPS figure quoted on the site and in doc comments
  belonged to the Savanna engine, not DagDB (DagDB's own
  measured number is 0.71 GCUPS at 1M nodes) — corrected across the
  slide deck, site HTML, and source doc comments.
- Deployment names, internal task lists, and inter-agent work-order
  prose were genericized or removed from the AC-3 example and
  troubleshooting docs ahead of the public push, matching the
  public-release sanitization pass.
- License/NOTICE aligned to Apache 2.0 at both repo levels (stops
  the GPL drift recurring from dev); the AC-3 Australia example was
  actually run against a scratch daemon (exit 0, converges in 2
  ticks) and the receipt committed — the package had existed since
  June, only the run receipt was missing.

### Tick-perf compaction + TICK_SYNC + AC-3 XCTest (July 7)

- **Per-(rank,color) compacted dispatch** becomes the default
  rank-mode tick path: a flat segment buffer + offset table, lazily
  rebuilt on a dirty flag; the old per-tick full scan (`tickLegacy`)
  kept as independent ground truth. Verified bit-for-bit against
  legacy across 20 seeded random graphs × 8 ticks. All 8
  `truthRankIndex.markDirty()` call sites (every rank-mutating
  daemon path) now also invalidate the compacted segments, so the
  fast path can never evaluate stale topology.
- **`TICK_SYNC`** adds a double-buffered synchronous tick mode
  (kernel + engine + DSL verb) for workloads needing simultaneous
  rather than rank-ordered updates (registers latch in-kernel, as in
  rank mode). Verified against a CPU double-buffer reference across
  10 seeded graphs × 10 ticks.
- **Benchmark receipt** — a 50-tick committed run, three modes, two
  rank spreads, honest ranges (thermal variance ~2x run to run).
  Compacted dispatch wins every shallow-spread run; a 16-band spread
  is documented unstable (latency-bound small dispatches) rather
  than tuned on noisy data. `TICK_SYNC` holds ~3.5 GCUPS stable — no
  Savanna-parity claim.
- **AC-3 Australia as an engine-level XCTest** ports the daemon-level
  demo to a committed regression: the 96-node `BACK_EDGE` encoding
  ticks the 21 domain registers against the pure-Python synchronous
  AC-3 reference, converging at tick 2 (tick 3 confirms the fixed
  point). Closes the run-receipt gap flagged in the sanitization
  pass above.
- Removed a redundant placeholder test made dead by the real
  `DagDBCommandHandlerTests`; documented the reserved `nf` snapshot
  header field with an honest one-liner instead of a bare
  placeholder comment.

(Same window, 07-15, unrelated: `image_mcp.py` prepends `/usr/sbin`
to `PATH` so the mflux `system_profiler` probe survives MCP's
PATH-stripping — battle-tested.)

### G73 durability (July 31)

Four-step durability hardening plus a stress probe:

- **Torn-tail audit** — WAL replay already tolerated a
  partially-written last record correctly (stops at the first
  record whose declared length overruns the remaining bytes,
  reports the byte offset); no code change needed, pinned with a
  deterministic truncated-WAL fixture.
- **Group-commit fsync policy** — the appender gains a
  `.grouped(n, ms)` mode alongside the default `.everyRecord`; a
  single serial queue owns every write, `F_FULLFSYNC`, and the
  deferred-fsync timer so they can't race each other. In grouped
  mode a record is visible to replay immediately but its fsync
  defers to the earlier of n unsynced records / ms elapsed / an
  explicit barrier — a crash loses at most the unsynced tail,
  bounded by n. Forced barriers on snapshot save and daemon
  shutdown. Production ignores the env override and always runs
  `.everyRecord` (asserted at startup).
- **Snapshot SHA-256 side-by-side manifest** — `save()` hashes the
  final on-disk bytes after the atomic rename and writes a `.sha256`
  manifest; `load()` verifies it before touching any buffer (a bad
  digest refuses with a named error, no half-load; a missing
  manifest warns and accepts, so legacy snapshots keep loading).
- **Kill-9 stress probe** — a scratch daemon (never prod, own socket
  and data root) driven at ~1k ops/s under grouped commit, killed
  mid-write, restarted via WAL replay, then SAVE/LOAD round-tripped
  through the new manifest. 10/10 clean; the loss bound matches the
  group-commit N (kill -9 can't induce the media-loss case
  `F_FULLFSYNC` actually guards against — that's what the
  deterministic torn-tail fixture from step one covers instead).

Separately, a 16-rank / N=5 cell run confirmed the July "unstable"
compaction reading from the tick-perf benchmark was thermal, not a
correctness issue: stable, ~1.75x compaction speedup every run.

### E1 — weight-lane persistence (Aug 22)

The engine has carried Float edge weights and a weighted GPU tick
kernel since birth, but neither lane survived save/load and the WAL
couldn't record weight writes — this closed the gap. New `nodeValue`
Float lane (solver state; the legacy Int16 activation lane stays).
Snapshot v6 adds a `WGTS` section between the back-edge section and
the trailer, storing only non-default lanes so boolean-mode
snapshots pay 5 bytes; both lanes reset to defaults on every load
path (fixes a latent stale-lane-after-load hazard on pre-v6 files).
Loader accepts v1..v6. WAL gains `setEdgeWeight`/`setActivation`/
`setNodeValue` opcodes with the same bounds discipline as the
existing ones. 7 new tests (roundtrip, default-lane economy,
compressed path, WAL replay incl. rejection) — suite **217**. Daemon
`SET WEIGHT` / `SET VALUE` commands followed the same day (log-first,
bounds-checked, finite-only values); `CURRENT_STATE.md` refreshed —
suite **218/218**.

### E2 runner (Aug 22)

`E2Runner`, a new executable target: a frozen-schedule smoother
built directly on the engine. Maps a row-major reference contract
onto the engine's own Morton wiring (`grid.mortonRank`/
`mortonToNode`, no rule duplication); G2 conductances from a frozen
LCG in lexicographic edge order written into the engine's edge-weight
lane; Float64 accumulation over the Float32 `nodeValue` storage lane;
per-cell fresh schedule stream (seed 77, slot-order consumption,
skipping absent slots); D=0 structurally trapped per the contract.
Control mode traces the first 100 rounds (sup norm, hash, vectors)
and merges in the Python reference trace for comparison — E2Runner
builds raw outputs only, a separate judge owns the pass/fail ratios.
A second pass added per-profile tolerance and output naming.

### E3 ladder (Aug 26)

`E3Ladder`, another new executable target: an exact tier ladder run
on the same engine lanes (ranks/leaks/weights fabric-resident,
fp32-per-rung storage, Accelerate-backed folds), producing tier
answers alongside their folded sources. A second pass moved the
third injection (f3) to rank 20 so it folds first — the worst
rolling case. A third pass parameterized the G2 seed and injection
nodes so different runs can compare as calibration twins rather than
one-off scripts.

### Roadmap draft + seven twin-spec primitives (Aug 30)

A roadmap draft (`ROADMAP_DRAFT.md`) distilled from the sealed E1-E3
record, refined against a "twin spec" list of primitives a
drift-twin engine needs. Seven of those lines shipped the same day,
each a small sealed engine primitive with its own test file:

- **`NamedStream`** (twin spec line 3 foundation) — PCG64 XSL-RR
  128/64 generator with a numpy state-bridge and pinned test vectors.
- **`StreamHeader`** (line 7) — the "t-zero law" as an engine
  admission check: seven declared quantities, arithmetic refusals
  for inadmissible headers.
- **`StreamRecord`** (line 3) — slice replay bit-for-bit from
  boundary states; inadmissible headers refused at birth.
- **`BudgetLayout`** (line 5) — twice-sealed decision letters
  encoded as engine logic: merge, min-cost tie-break, lexicographic
  residual.
- **`CrossConvolutionCheck`** (line 6) — the sealed W1 identity as a
  standing engine check (pass / scream / flash states).
- **`GearedRings`** (line 1, memory half) — a sealed odometer as a
  recording primitive: signed extremum recall across orders of lag.
- **`MasterClock` + `PhaseGear`** (line 2) — one tick, rational
  gears, drift-free by integer arithmetic, with a latch.

Suite reaches **249**.

### Merge to main (2026-09-05)

`dag/twin-r3-replay` merged to main: twin spec lines 1, 2, 3, 5, 6,
7 — named streams, t-zero header, slice replay, budget layout,
cross-convolution check, geared rings, master clock. **249 tests**,
no regressions from the Aug 30 branch tip.

---

## 2026-05-11 — u64 scar fix + docs current-state pass

### u64 scar fix (`dag/u64-scar-fix`)

Codex flagged 2026-05-09: the daemon's `NODES AT RANK` filter still
narrowed rank queries to `UInt32`, hiding any node whose rank
exceeded 2^32 − 1. Both call sites (writer + reader-session mirror)
now compare against `UInt64(r)`. Rank storage was widened to u64
in T1b; the filter expression had not caught up.

Acceptance test `DagDBU64RankTests` (three cases) exercises the
engine rank buffer and the filter expression at 2^32 + 4. Codex's
explicit pattern — `SET 0 RANK 4294967300; NODES AT RANK 4294967300`
returns node 0 — is covered. Full Swift suite **162 → 165 green,
zero failures.**

Merged to main and promoted to prod via launchctl bootout/bootstrap
the same day. Live daemon's `NODES AT RANK 4294967300` now returns
`OK NODES rows=0` cleanly; the old binary would have trapped on
the same input.

### Docs current-state pass (`dag/docs-current-state`)

Codex's priority #3. New `CURRENT_STATE.md` at repo root: canonical
pointer for snapshot version, test count, daemon supervision, DSL
drift, per-node footprints. Inline drift fixed in:

- `README.md` — test count 98 → 165; `SET_RANKS_BULK` u32 → u64
  wording; tree-listing test count.
- `ARCHITECTURE.md` — snapshot version list updated through v5;
  per-suite test breakdown converted to a topical map (count
  drifts faster than the headline); total 98 → 165.
- `CONTRIBUTING.md` — test count and Python-pytest status.
- `dagdb/README.md`, `site/README.md` — test count + version.
- `docs/wiki/data-and-persistence.md` — snapshot row to v5,
  42 B/node body, fixed trailers.
- `docs/wiki/dsl.md` — `<u32>` rank → `<u64>`; version list
  through v5.
- `docs/wiki/mvcc.md` — per-session RAM cost 38 → 42 B/node.
- `docs/wiki/back-edges.md` — 120 figure marked as the
  back-edge-landing snapshot; current count cross-referenced.
- `docs/wiki/quick-start.md`, `docs/bfs_usage.md` — Swift count
  and Python collection-error caveat; bulk example widened to u64.
- `docs/wiki/README.md` — T3 description widened to u64.

Surfaces left alone: `dev-test-prod-memo-2026-05-01.md` keeps its
"a separate supervisor will own prod" framing as a forward-looking plan the
launchctl-current state has not flipped to; `tiled-streaming.md`
and the 04-29 memo keep their landing-time numbers with a pointer
to `CURRENT_STATE.md` where needed.

---

## 2026-04-21 (pm) — T1b u64 rank widen + tiled-streaming spec

### T1b — u32 → u64 rank refactor

Follow-on to T1. Rank field widens from 32-bit to 64-bit across
the full stack to support the 10¹¹-on-laptop stretch target (via
tiled streaming, spec below).

- **Core**: `DagDBState.rank: [UInt64]`, `rankBuf` allocation 4 →
  8 bytes/node, `bindMemory(to: UInt64.self)` everywhere.
- **Shader**: `uint64_t* rank` + `uint64_t& current_rank` in both
  `Shaders/dagdb.metal` and the inline fallback source.
- **Snapshot format v3**: 42 B/node body. Header unchanged. Load
  is backward-compat with v1 (u8, widens) and v2 (u32, widens);
  save always writes v3.
- **WAL `SET_RANK` v3 payload**: u32 node + u64 rank = 12 bytes.
  Replay accepts v1 (5 B) and v2 (8 B).
- **Shm row v3**: 12 B → 24 B per row. Layout: u64 node + u64
  rank + u8 truth + u8 type + 6 pad. Python MCP readers must
  update row stride.
- **DSL parser**: RANK / DISTANCE / SELECT rank args parsed as
  UInt64.
- **Secondary index** (`TruthRankIndex`) keys UInt64.
- **Distance module** rank-profile histogram keys UInt64.

Acceptance criterion (per coordination call): `rank=300` (u8-impossible) and
`rank=4_294_967_300` (u32-impossible) both round-trip through
SAVE/LOAD. Green: `testU64RankRoundTrip` in
`Tests/DagDBTests/DagDBSnapshotTests.swift`.

Full test suite: **98 Swift + 16 Python = 114 green, no skips**.

Phase 2b (neighbor i32 → i64 widening) **deferred** per the coordination
call: doubling the neighbor buffer drops the single-engine
ceiling ~40 % on M5 UMA without unlocking addressing we could
physically allocate. Will revisit if/when a single tile
approaches 2 × 10⁹ distinct node IDs.

### Tiled-streaming spec

New internal doc at `docs/tiled-streaming.md`. Frames Savanna's
existence proof (100 B cells / 9 hr / 500 GB / single M5) as the
pattern DagDB inherits for the stretch target. Covers scale
regimes (when to tile and when not to), rank-range tile mapping
aligned with the rank-monotone invariant, hot/cold buffer
decisions, tile file format reuse of `TileHalo.swift`, Metal
kernel dispatch per-tile, sparse BFS with continuation queue,
thermal discipline, open questions.

Internal only. No code yet. Build follows spec after it matures.

### Daemon bounce #2

the launchd daemon was bounced onto the u64 binary. Verify
pass: all five gates green (u64 rank surface accepts 2⁶³-1 and
> 2⁶³, BFS_DEPTHS callable, shm + socket 0600, DATA_ROOT
enforcement, SAVE file size byte-exact match for v3 format —
44 040 224 bytes = 32 header + 42 × 1 048 576 body). MVCC,
ANCESTRY, SET_RANKS_BULK all still surface-exposed.

### Security + data-root hardening

- shm file mode 0o666 → 0o600 + explicit chmod.
- Unix socket chmod 0o600 after bind.
- `guardPath()` rejects `..` traversal and out-of-root paths
  under `DAGDB_DATA_ROOT`. Applied to every file-path DSL verb.
- `~/dag_databases/` as the single persistent DB root (plist env
  vars `DAGDB_DATA_ROOT`, `DAGDB_WAL`, `DAGDB_AUTOSAVE`).
- Gitignore allow-list tightened to ONE sample
  (`dagdb/sample_db/demo_graph.dagdb`); `liver.dagdb` moved to
  `~/dag_databases/`.

---

## 2026-04-21 (am) — consolidation and archive

- `ARCHIVE/1_Active_Doing_Graph_Database/` — tree 2 (the original
  `dagdb-engine` staging repo) moved into
  an archive directory outside this repository alongside other deprecated
  projects. The DagDB codebase under 004 is now unambiguously
  canonical.
- `dagdb/mcpo_config.json` — mcpo config relocated into 004. `dagdb`
  endpoint points at 004's mcp_server.py; the three non-DagDB MCP
  scripts (dialogue, image, diagram) still resolve via the ARCHIVE/
  path (no canonical home yet).
- `~/Library/LaunchAgents/com.hari.dagdb.plist` — rewired to the 004
  release binary + grid 1024. Old plist backed up as `.pre-t1.bak`.
- `~/Library/LaunchAgents/com.dagdb.mcpo.plist` — rewired to 004's
  mcpo config. Old plist backed up as `.pre-archive.bak`.
- The full Pass 1 re-run landed clean on the new
  launchd-supervised daemon: **694 Loom events** (archives + live
  JSONL), ~140 ms wall clock, ~5 k events/sec, zero schema errors.
  Fallback import deleted from `capture_latest.py`; adapter resolves
  exclusively via `dagdb.plugins.loom.adapter` from 004.

## 2026-04-20 — rank-widening sprint

Seven tickets shipped against the rank-widening + MVCC sprint:

### T1 — u32 rank refactor (commit `7d49476`)

Rank `UInt8` → `UInt32` across the whole stack. Caps per-instance
rank at 4.3 billion; unblocks Loom's insert-counter and
full-protein biology ingestion (> 255 residues).

- Core: `DagDBState.rank`, `DagDBEngine.rankBuf`, `readRanks`,
  validator.
- Metal shader (both `.metal` file and inline source): `DagNode`
  rank `uint8_t` → `uint32_t`; `current_rank` widened.
- Snapshot v2 (rank = 4 bytes/node; body 35N → 38N). Load accepts
  v1 (u8) and v2 (u32). Save always writes v2.
- WAL `SET_RANK` payload 5 → 8 bytes. Replay accepts both.
- JSONIO + CSV parse rank as `UInt32`.
- Backup chain segment sizes updated.
- Distance module: rank-profile histogram dense `[256]` → sparse
  `[UInt32: Int]`.
- Daemon: shm result row layout 8 → 12 bytes (rank field widened);
  `Predicate.evaluate` takes `UInt32`; DSL parser widened.

### T2 — rankPolicy protocol + three defaults (commit `c73b824`)

Python module `dagdb/plugins/biology/rank_policies.py`:

- `RankPolicy` Protocol — `assign_ranks(node_count, max_rank,
  **context) → numpy.uint32` array.
- `SequencePositionPolicy` — single chain.
- `ChainBandPolicy` — multi-chain assembly, rank bands per chain.
- `TopologicalSortPolicy` — BFS-depth from a chosen root;
  disconnected components land one depth deeper.
- Self-test covers monotonicity, inter-chain ordering, and a
  4-node cycle with BFS from root-0.

### T3 — SET_RANKS_BULK DSL (commit `579ff1d`)

New DSL command + MCP tool. Plugin writes a precomputed u32 rank
vector of length `nodeCount` to shm offset 8, calls
`SET_RANKS_BULK`, daemon commits to `rankBuf` in one round-trip. No
per-insert validation — pair with `VALIDATE` if paranoid.

### T7 — MVCC snapshot-on-read (commit `d4b008d`)

Reader sessions:

- `DagDBReaderSession` + `DagDBReaderSessionManager`.
- `OPEN_READER` memcpys the six primary buffers into a fresh
  `DagDBEngine`. Returns a 17-char session id.
- `READER <id> <inner>` routes a read-only inner command to the
  session's snapshot. Writes, `EVAL`, nested sessions,
  `SIMILAR_DECISIONS` all rejected with `ERROR forbidden:`.
- `CLOSE_READER` / `LIST_READERS` for lifecycle + introspection.
- 9 tests: isolation under mid-session mutation, multi-session
  independence, u32 rank fidelity in the snapshot, neighbours-buffer
  copy integrity, unique ids across 10 opens.

### T15 — secondary index (truth, rank-range) (commit `8876feb`)

`TruthRankIndex`:

- Per-truth-code rank-sorted list of `(rank, nodeId)` tuples.
- Lazy rebuild on dirty flag. Mutations that can change `(truth,
  rank)` flip the flag; next `SELECT` rebuilds once.
- Lookup: O(log N + matches) via binary search for the first rank
  ≥ lo, linear scan while rank ≤ hi.
- DSL `SELECT truth <k> rank <lo>-<hi>` — matching node IDs written
  to shm at offset 8 as `Int32[]`.
- MCP tool `dagdb_select_by_truth_rank`.
- 11 tests including a Loom-specific "last-N dialogue_turn events"
  scenario under insert-counter rank.

### T8 — ANCESTRY / SIMILAR_DECISIONS / HIVE_QUERY (commit `1e5c410`)

Three agent-friendly hive-query primitives:

- **`ANCESTRY FROM <node> DEPTH <d>`** — reverse BFS bounded by
  depth. Output: `(Int32 node, Int32 depth) × count`.
- **`SIMILAR_DECISIONS TO <node> DEPTH <d> K <k> [AMONG TRUTH <t>]`**
  — WL-1 histogram L1 distance over per-candidate local ancestral
  subgraphs. Output: `(Int32 node, Float32 distance) × k`.
- **`HIVE_QUERY …`** — MCP-level alias over `SELECT`; sidecar
  filters client-side.

### Error taxonomy (same commit)

All daemon responses now carry `ERROR <category>: <detail>` prefix.
Nine categories: `out_of_range`, `dsl_parse`, `unknown_command`,
`schema`, `io`, `wal`, `bfs`, `not_found`, `forbidden`. Additive —
existing payload preserved after the prefix.

### BFS primitive (earlier on the same day, commit `c1c306c`)

`DagDBBFS.swift`:

- `bfsDepthsUndirected(from:)` — merge inputs + on-the-fly fanout.
- `bfsDepthsBackward(from:)` — follow inputs only.
- DSL `BFS_DEPTHS FROM <seed> [BACKWARD]`; zero-copy Int32 vector
  to shm.
- MCP `dagdb_bfs_depths`.
- Caught and corrected a dual-node encoding bug in the same
  session: under bipartite B→A edges, BFS shortcut collapses
  contact-graph geodesics. Switched to single-node-per-residue
  encoding with `rank = maxRank - seqIndex`. Amendment drop
  captured the fix; tests updated.

### Rename `legacy/` → `dagdb/` (commit `c184721`)

The "legacy" label was an artefact of 2026-04-19's `git subtree add
--prefix=legacy` — backwards in meaning since all live work
happened inside it. `git mv` preserved blame. Path references
updated across README, ARCHITECTURE, CHANGES, CONTRIBUTING, docs,
dashboard features.yaml, gitignore. Fresh `.build` clean-rebuild
(Swift's precompiled module cache baked the old path in).

### Consolidation into 004 (commit post-rename)

Pulled forward from tree 2:

- `dagdb/plugins/loom/` — the pure-function adapter, backfill
  script, 16-test pytest suite. `capture_latest.py` now imports
  from `dagdb.plugins.loom.adapter`.

## 2026-04-19 — first four phases

- **Phase 0 — merge.** `git subtree add --prefix=legacy` pulled
  tree 2's `norayr-m/dagdb-engine` repo into 004 under `legacy/`.
  38-commit history preserved. Tagged tree 2
  `pre-merge-2026-04-19` as safety. Both builds green post-merge.
- **Phase 1 — dashboard.** `dashboard/features.yaml` +
  `gen_dashboard.py` + dark-gold `index.html`. Auto-refresh every
  30 s in Chrome. `--watch` flag regenerates every 10 s.
- **Phase 2 — ACID atomic-save.** `DagDBSnapshot.save` rewritten:
  tmp + `F_FULLFSYNC` + `replaceItemAt` + dir fsync. Three
  durability tests: dangling `.tmp` ignored, successful save leaves
  no tmp, overwrite is atomic. A and D become **pass**.
- **Phase 3 — JSON + CSV IO.** `DagDBJSONIO.swift`. JSON
  (`dagdb-json` v1) mirrors the six engine buffers; CSV is two
  files (`nodes.csv` + `edges.csv`). Atomic-save + pre-commit rank
  validation. Five round-trip tests.
- **Phase 4 — subgraph distances.** `DagDBDistance.swift` — Jaccard
  (nodes + edges), rank-profile L1/L2, nodeType L1, bounded GED,
  WL-1, spectral L2 via inline Jacobi eigensolver. 9 tests.
- **Docs layer.** Wrote README / ARCHITECTURE / CONTRIBUTING /
  `docs/engine.md`, copied `legacy/LICENSE` to the root, hardened
  `.gitignore`. Humble disclaimer on every top-level doc. Did not
  push anywhere.

Ended 2026-04-19 with 51 / 51 tests green (from a 27-test baseline).

---

## Running test counts by date

| Date | Swift | Python | Total | Delta |
|---|---:|---:|---:|---|
| 2026-04-18 baseline | 27 | — | 27 | — |
| 2026-04-19 evening | 51 | — | 51 | +24 (snapshot, JSONIO, distance) |
| 2026-04-20 evening | 98 | 16 + 11 | 125 | +47 Swift, +27 Python |
| 2026-04-21 | 98 | 16 | 114 green | rank-policy self-test folded into adapter tests |

(The 11-count for rank-policy self-test is a single Python script
with multiple asserts, not a pytest suite — counted once as a
smoke check, not tracked day-by-day.)

---

## Deferred / parked

- **Dense Laplacian → Accelerate / LAPACK.** Current Jacobi
  eigensolver is self-contained but O(n³). Fine up to ~300-node
  subgraphs. Larger work (protein complexes, whole graphs) wants
  `dsyevd_` through `Accelerate`.
- **Threaded daemon accept.** Serial loop today. Full MVCC (per-node
  versions + GC) is a separate future step after threading.
- **`WHERE … AND …` compound predicates.** DSL supports one
  field-op-value per clause. Compose client-side.
- **Cross-project MCP scripts** (`dialogue_mcp.py`, `image_mcp.py`,
  `diagram_mcp.py`, `kokoro_tts_proxy.py`) — live in ARCHIVE/ for
  now. Proper home TBD.

---

## Humble disclaimer

Amateur engineering project. Research prototype. Errors likely.
Numbers speak. No competitive claims.
