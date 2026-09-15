# Current state — DagDB

One-page snapshot of what is live right now. Read this before
trusting any older doc's claim about version, test count, or
ownership.

> **Humble disclaimer.** Amateur engineering project. We are not
> HPC professionals and make no competitive claims. The numbers
> here come from a single M5 Max laptop, no controlled benchmark,
> no peer review. Errors likely. Numbers speak.

Last refreshed: 2026-09-12, branches `dag/core-durability` and
`dag/daemon-bounds` (see the core durability and daemon bounds sections
below). Before that: 2026-09-10, branch
`dag/ticking` (built on
`dag/tiling`/`main`, not yet merged to main; main: interface phase
merged 2026-09-06, startup recovery merged 2026-09-09, fold API merged
2026-09-10, derived views merged 2026-09-10). Tiling, step one (`SAVE
TILED`, `TILED OPEN/BFS/SELECT/STATUS/LIST/CLOSE`) landed on
`dag/tiling` the same day; step two — ticking across tiles (`TILED
TICK`/`TILED GET`, per-tile flush + crash recovery + partial-round
completion at open) — landed on `dag/ticking` the same day too — see
the "Tiling" and "Ticking across tiles" sections below; neither is
part of the twin-verb family count above (routers aren't a twin
registry).

**Core durability — branch `dag/core-durability` (2026-09-12, not yet
merged).** Audit A (`docs/contracts/AUDIT_A_engine_core.md`) read the
engine core and the durable formats and found 48 defects, every one
public in shipped v0.2.0. This branch closes the 38 of them that are not
the backup family — findings 1–2, 34–40, and 45 (the fixture that gates
finding 1) are being repaired on their own branch. Gate contract:
`docs/contracts/CORE_DURABILITY_GATES_FROZEN.md`. What changed, in the
shapes an operator sees:

- **WAL version 2.** `CONNECT`, `CLEAR <n> EDGES` and the three bulk
  installs are now logged before the buffer write; until this they
  bypassed the log entirely, so a crash after `CONNECT` and before
  `SAVE` lost the graph's structure with no trace. A version-1 log still
  replays; a version above 2 is refused by name.
- **Replay says what it skipped.** `ReplayResult` carries
  `recordsSkipped` with a bad-length / out-of-range / unknown-opcode
  histogram and the file's version; startup prints them. A replay that
  applied nothing used to return success in silence.
- **A compressed `SAVE` that returns success can be `LOAD`ed.** The
  compressor sized its output for the input size, so an incompressible
  body encoded to zero bytes and the file was written, manifested and
  reported as a success that no load could read.
- **Every public engine entry point is bounded.** `clearBackEdges`,
  `isRegister`, `addBackEdgeUnchecked`, `writeTruthStates` and the
  engine `init` refuse out-of-range input by name; `dagdb_tick_rank`
  takes `node_count` and treats a neighbour index past it as an empty
  slot, like the other two kernels always did.
- **Grid files have a magic and a version**, every section is
  length-checked against the node count, and a grid the Morton layout
  cannot encode is refused at construction rather than aliased.
- **BFS is bounded and discloses**: `back_edges=excluded` on the result,
  with the count of what was left out.
- **Reader sessions copy all ten lanes and the back edges** — they
  copied six, so every session saw registers as ordinary combinational
  nodes.
- **`EXPORT MORTON` writes eleven files, not six**, and `IMPORT MORTON`
  resets what `LOAD` resets.
- **Documented, not changed:** the UNDEFINED truth state collapses to
  FALSE at the next tick in both tick modes. That is the kernel's
  semantics; it is now written down in the shader and in CHANGES rather
  than left to be rediscovered.

Wire changes are appended fields only: the `VALIDATE` rank-bound line
gains the dispatch's coverage and, when there is one, the count of nodes
outside every dispatch; `OK EXPORT bytes=` reports what was actually
written; the startup WAL line carries `skipped=`.

**Daemon bounds — branch `dag/daemon-bounds` (2026-09-12, not yet
merged).** Answers audit B (27 findings) through
`docs/contracts/DAEMON_BOUNDS_GATES_FROZEN.md`. One family: values
taken from the wire were bounded above but not below or not at all, the
shared-memory read side checked capacity while the write side did not,
two verbs sat on the reader allowlist and moved daemon-global state, one
bulk installer skipped an invariant nothing could re-check, the socket
parsed a truncated prefix as a whole command, and four loops ran
unbounded on the single-threaded accept loop. The ruling applied
everywhere is refuse or count, never silently, and name the true extent
in the refusal: every node id, depth, count and offset is now checked on
both sides before any pointer is touched; every shm writer checks
capacity first; the four trapping byte-count sites use
overflow-reporting arithmetic; the socket reads to the newline and
answers `ERROR too_long` at 4,095 bytes without parsing; `FOLD RUN` is
forbidden to reader sessions and off the web bridge's read-only set,
along with `OPEN_READER`/`CLOSE_READER`, whose inner command the bridge
now classifies; `SET_NEIGHBORS_BULK` range-checks its whole vector
before writing a word; and `EVAL`, `NODES`, `ALARM CORRUPT` and both
bulk installers say on the wire what they omitted or skipped.
`SocketServer` moved into `DagDBDaemonKit` so the framing contract is
driven over a real AF_UNIX socket in the suite.

**Rank-bound correction — branch `dag/rank-bound` (2026-09-10, not
yet merged).** Rank-mode `TICK` used to dispatch only the rank levels
below the configured `maxRank`; a node at or above it was never
computed, while `TICK_SYNC` computed it, and no verb refused the
state. The likeliest way to reach it is a restore: a snapshot saved
under a large bound, loaded into a daemon started with a small one.
Fixed by computing, not refusing — the dispatch now sizes itself to
`max(maxRank, highest rank present + 1)` (`DagDBEngine`
`effectiveRankCount` / `highestRankPresent`). Wire changes:
`OK TICK` and `OK TICK_SYNC` carry ` nodes_computed=<n>` always, plus
` ranks=<levels> bound=<maxRank>` when the levels dispatched exceed
the bound; `STATUS` carries ` ranks=<levels> rank_max=<highest
present>` beside the existing `maxRank=` (every old field kept, same
relative order); `SET <node> RANK <v>` with `v >= nodeCount` is
refused with `ERROR out_of_range: rank <v> not in 0..<<nodeCount>`
and `SET_RANKS_BULK` validates the whole vector before writing any of
it, naming the first offending node; `VALIDATE` adds a rank-bound
line with the count, the first node and the highest rank found. A
rank in `[maxRank, nodeCount)` is accepted and computed. The load
path still accepts a snapshot written under any bound. Gate contract:
`docs/contracts/RANK_BOUND_GATES_FROZEN.md`. Full suite green: 761
tests, 45 skipped.

**Backup format 2 — branch `dag/backup-rank-width` (2026-09-12, not
yet merged).** Backup diffs kept 4 of the engine's 8 rank bytes per
node (so ranks for nodes `N/2..<N` were dropped on restore) and
carried six of the ten buffers, losing every back edge, register,
edge weight, activation and node value; `.diff` format 2 now covers
all of them, a format-1 chain is refused by name on RESTORE/APPEND,
and RESTORE/INFO print `rank_bytes=`/`format=`/`twin=not_covered`;
the same pass stopped XOR from clamping mismatched lengths, made the
header's sequence number (not the filename) order a replay, gave every
diff a verified sha256 sidecar, and made COMPACT write its base from
the chain's tip at the chain's tick count instead of from the caller's
engine.
Gate contract: `docs/contracts/BACKUP_RANK_WIDTH_GATES_FROZEN.md`.

**Twin primitives merged to main 2026-09-05** (rollback tag
`pre-merge-twin-r3-20260905`). Seven types (`NamedStream`,
`StreamHeader`, `StreamRecord`, `BudgetLayout`, `CrossConvolutionCheck`,
`GearedRings`, `MasterClock`/`PhaseGear`) plus, since the interface
phase (merged 2026-09-06), the
alarm-stream type (twin spec line 4: `AlarmRecord`, `SealedCourt`,
`AlarmFixture`, `CorruptionModel`, `SuccessorCourt`, `AllocatorCourt`)
— see `ARCHITECTURE.md` §13.3.

**interface phase — twin verbs wired.** All seven primitives plus
the alarm-stream court types are now reachable over the daemon
socket (DSL) and over MCP, not just in-process. Nine verb families —
`STREAM`, `HEADER`, `RECORD`, `RINGS`, `CLOCK`, `GEAR`, `XCONV`,
`BUDGET`, `ALARM` — dispatch through one `TwinCommand` grammar
(`dagdb/Sources/DagDBDaemonKit/TwinCommand.swift`); state lives in a
daemon-global `TwinState` of typed-id registries (`s`/`t`/`n`/`c`/`g`/
`b`/`a` prefixes), persisted via WAL opcodes `0x20`–`0x2B` and a
snapshot v7 `TWIN` section (below). On branch `dag/spec8-mouth`
(2026-09-10, merged 2026-09-10) a tenth verb family, `BANK`, and an
eighth registry (`w` prefix, `WaveBank`) land the same way — see
below. On branch `dag/derived-views` (2026-09-10, off `dag/spec8-mouth`,
merged with `main` here) an eleventh verb family, `VIEW`, and a ninth
registry (`v` prefix, alarm-set derived views over the sealed cortex v4
world — spec line 4's second view family) land the same way; WAL
opcode `0x2D`, snapshot v7's `views` field. Gate contract:
`docs/contracts/DERIVED_VIEWS_GATES_FROZEN.md`. On branch
`dag/fold-api` (2026-09-10, built on `dag/spec8-mouth`, merged to main
2026-09-10) a twelfth verb family, `FOLD`
(`RUN`/`KEPT`/`SOURCE`/`TIER`/`INFO`), dispatches through the same
`TwinCommand` grammar but mints no registry entry and touches no WAL —
it is a pure read of the engine's current lanes via
`LadderFold.Object(engine:grid:)`, so `STATUS`'s `twin_open=<n>` is
unaffected by it. On branch `dag/kernels` (2026-09-10, built on
`main`, merged 2026-09-10) a thirteenth verb family, `KERNEL`
(`LOAD`/`INFO`/`LIST`/`CLOSE`), and a tenth registry (`k` prefix,
`KernelSet` wrapping a `KernelPair`) land the same way — spec line 6's
per-path kernel storage; WAL opcode `0x2E`, snapshot v7's `kernels`
field. The same branch adds `XCONV SEALED <id> <n> [<warmup>]`
alongside the pre-existing `XCONV CHECK` — the W1 court's own frozen
residual, reached over the socket via `SealedCrossConvolution`,
**not** `XCONV CHECK`. `XCONV CHECK` (`CrossConvolutionCheck.check`)
is now documented as deprecated: it compares over the full convolution
length with a symmetric denominator and Float32 inputs, and on the
190 sealed W1 trials it flips 50 of 190 court gates — every one a true
recording. It stays wired for compatibility; `XCONV SEALED` is spec
line 6's standing cheap check as of 2026-09-10. Gate contract:
`docs/contracts/KERNELS_GATES_FROZEN.md` (K1–K5, 3 amendments).
On branch `dag/hook` (2026-09-10, built on `main`, merged 2026-09-10) a
fourteenth verb family, `HOOK`
(`OPEN`/`STEP`/`STATE`/`LEDGER`/`INFO`/`LIST`/`CLOSE`), and an eleventh
registry (`h` prefix, `HookEntry` wrapping an `AttentionHook`) land the
same way — roadmap item 7, the sealed allocator court as a
daemon-global ticked process: one hook = one alarm set + one budget
layout (sealed by default) + a per-frame budget B + a lag Δ (3) + one
of three lagged policies (allocator, greedy, uniform) + an optional
master clock. `HOOK STEP` advances the hook's own frame counter;
bound to a clock, `CLOCK ADVANCE` steps every bound hook once per
tick, AFTER that tick's gears, and `HOOK STEP` then refuses `ERROR
forbidden: bound to clock <c>`; `CLOCK CLOSE` reports
`hooks_closed=<n>` beside `gears_closed=<n>` and cascades to bound
hooks the same way it cascades to gears. WAL opcode `0x2F`
(`hookOpen`) / `0x30` (`hookStep`), snapshot v7's `hooks` field
(parameters plus the frame counter t only — the per-frame ledger is
DERIVED, never stored, rebuilt by re-stepping on restore). Closing an
alarm set or budget layout a live hook depends on refuses the same way
ALARM/BUDGET already refuse a dependent view or bank, naming the hook.
Gate contract: `docs/contracts/HOOK_GATES_FROZEN.md` (H1–H6, amendment
1 fixing the 40-byte ledger row layout).
`STATUS` now reports
`twin_open=<n>` alongside the existing fields.
`docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md` is the frozen gate contract (incl.
amendment 1, an independent hostile read); `docs/contracts/FOLD_API_GATES_FROZEN.md`
is FOLD's own frozen gate contract (F1–F5).

## Tiling, step one (2026-09-10, branch `dag/tiling`)

`docs/tiled-streaming.md`'s build steps 3–4, gate contract
`docs/contracts/TILING_GATES_FROZEN.md` (T1–T6, amendments 1–2).
Deliberately NOT a twin-spec verb family — a `TiledGraphRouter` is
never persisted, never WAL-logged, never part of a snapshot; the tile
directory on disk written by `SAVE TILED` IS the durable state, and
`TILED OPEN` just rebuilds an in-memory view of it.

- **Tile files**: `TiledGraphFiles.write` splits a DAG by rank range
  into `tile_<lo>_<hi>/{body.dags, halo_lower.bin, halo_upper.bin,
  meta.json}` plus a graph `manifest.json`. Two entry points: the
  original `write(object:dataRoot:name:boundaries:)` over a
  `TiledFixture.Object`, and `write(engine:grid:dataRoot:name:
  boundaries:)` over any live `DagDBEngine` + `HexGrid` — what `SAVE
  TILED` calls, splitting the daemon's OWN current graph.
- **Engine allocation fix** (amendment 1 item 4, landed before this
  session's daemon work): `DagDBEngine.init` used to fail to allocate
  for grids under 11 nodes (an empty 7-colour bucket asked Metal for a
  zero-length buffer) — fixed to allocate at least one element per
  bucket, so tile-local engines of any size (including the degenerate
  1-node tile) construct without padding.
- **Router**: `TiledGraphRouter` (actor) — LRU-bounded resident tile
  set, cross-tile `runBFS`/`runAncestry`/`runSelect` matching the
  single engine's own `DagDBBFS`/`TruthRankIndex` answers exactly
  (T2), a torn tile body (sha256 mismatch) refused and recorded, never
  loaded silently (T4).
- **Daemon verbs** (T5): `SAVE TILED <dir> <b1,b2,...>`, `TILED OPEN
  <dir> [<K>]`, `TILED BFS <id> <globalId> <depth> [BACK]`, `TILED
  SELECT <id> <truth> <lo> <hi>`, `TILED STATUS <id>`, `TILED LIST`,
  `TILED CLOSE <id>`. Routers live on the daemon HANDLER
  (`tiledRouters: [String: TiledRouterEntry]`), ids `x%08x` from a
  handler-local counter — a different id shape from the twin
  registries' single-letter prefixes, and outside `dagdb_twin_list`/
  `dagdb_twin_close`'s reach. `STATUS` carries `tiled_open=<n>`
  alongside `twin_open=<n>`; routers do not count toward the latter.
  Reader sessions may run `BFS`/`SELECT`/`STATUS`/`LIST`; `OPEN`/
  `CLOSE`/`SAVE TILED` are forbidden there. The actor/synchronous
  bridge is one helper, `DagDBCommandHandler.runTiledSync` (in
  `DagDBCommandHandler+Tiled.swift`) — a `DispatchSemaphore`-blocked
  `Task` per call; the daemon's existing one-command-at-a-time
  discipline is unchanged.
- **Not done** (out of this contract's scope): pre-fetch, the cold
  tier, thermal pauses, the 10¹¹-node run, `TILED BACKUP`. Ticking
  across tiles is step two, below — no longer on this list.

## Ticking across tiles, step two (2026-09-10, branch `dag/ticking`)

`docs/tiled-streaming.md`'s build step 5 (minus the optional pre-fetch
thread), gate contract `docs/contracts/TICKING_GATES_FROZEN.md`
(W1–W6, amendments 1–3).

- **Mechanism**: a world tick ticks every tile once with ghost inputs
  for its cross-tile sources (register-flagged nodes appended to the
  tile-local engine, rewriting `-2` slots to point at them); rank mode
  ticks tiles in descending id order within one round so a tile's
  cross-tile sources (always a higher-numbered tile) are already
  fresh; sync mode's ghosts always come from the previous round's
  committed strip. Each tile flushes atomically every round: BEGIN
  (now carrying the mode as its third field) → body (atomic snapshot)
  → halo strip → meta → manifest entry (`bodySHA256`, `tickEpoch` —
  the per-tile authority, refreshed every flush, one check for both
  the query path and the ticker) → COMMIT.
- **Per-tile epochs, no router-global counter**: each manifest
  `TileEntry` carries its own `tickEpoch`; the router's notion of "the
  world's epoch" is the (min, max) over every tile's entry — equal
  except mid-recovery. `TILED STATUS` prints `epoch=<min>/<max>`.
- **Roles at open**: `TiledGraphRouter.init(role:)` — **writer**
  (default, the daemon's `TILED OPEN`) recovers any dangling flush
  then completes a partial round (a between-tiles crash, every
  `flush.wal` clean but epochs mixed) before returning, reported as
  `OpenReport(recovered:, completed:)`; **reader** refuses a torn
  world outright (`RouterError.worldTorn`) rather than fixing it.
  `worldTick` itself always starts from `min == max`.
- **Daemon verbs (W5)**: `TILED TICK <id> [<n>] [SYNC]` → `OK TILED
  TICK id=<id> ticks=<epoch after> tiles_ticked=<n> loads=<n>
  evicts=<n> flushes=<n> halo_bytes=<n>`; `TILED GET <id> <globalId>
  TRUTH` → `OK TILED GET id=<id> node=<globalId> truth=<0|1|2>`.
  `TILED OPEN`'s OK line gained `recovered=<n> completed=<m>`. `SAVE
  TILED` refuses a cross-tile BACK_EDGE before writing anything:
  `ERROR bad_value: back edge crosses a tile boundary (<src>→<dst>)`.
  Reader sessions may run `TILED GET`; `TILED TICK` is forbidden
  there (flushes every tile to disk). MCP: `dagdb_tiled_tick`,
  `dagdb_tiled_get_truth`; bridge.py's read-only allowlist gained
  `TILED GET`.
- **Not done** (out of this contract's scope): the pre-fetch thread
  (optional — changes no result if added), the cold tier, thermal
  pauses, the 10¹¹-node run, `TILED BACKUP`.

## Engine

- **Rank**: 64-bit (`UInt64`). Widened from 32-bit on 2026-04-21.
- **Snapshot format**: **v7** (2026-09-06, interface phase).
  v7 adds a `TWIN` section between the WGTS lane section and the ENVS
  trailer: magic `"TWIN"` (4 bytes) + `u32 byteLength` + `JSONEncoder`
  (`.sortedKeys`) payload of `TwinState.Snapshot` — 0 length when no
  twin state is passed. Always uncompressed. Load accepts v1..v7
  (version gates are `>=`); a v≤6 file carries no TWIN section and
  resets the twin state to empty on load. Previously: v6 (2026-08-22,
  E1) adds the WGTS lane section between the back-edge section and
  the ENVS trailer: edge weights (Float × 6N), activation (Int16 × N),
  nodeValue (Float × N) — each written only when non-default, so
  Boolean-mode snapshots pay 5 bytes. Lanes reset to defaults on every
  load path. Before that: v5 Header unchanged from v3. Body 42
  bytes per node (34 + 8). v5 adds the env-origin trailer
  (`ENVS` + 1 byte for `unspecified`/`dev`/`test`/`prod`); v4
  added the back-edge trailer. Cross-env loads are rejected
  when both sides are env-tagged and the tags disagree.
- **WAL opcodes 0x20–0x2B** (interface phase, 2026-09): one opcode per `TwinOp` case
  (`streamOpen` … `close`), encoded/decoded by `TwinWALCodec`
  (little-endian, u16-length-prefixed strings, f32/f64 as bit
  patterns). `STREAM NEXT` logs the post-draw state, not the draw
  count, so replay is O(1); `RINGS WRITE` logs the written values;
  `CLOCK ADVANCE` logs the tick count plus value as one record. A
  malformed twin payload is skipped on replay, never fatal.
- **BACK_EDGE**: present. Recurrence-in-time edge type, latched
  at tick boundary (two-phase: snapshot-all then write-all).
  Used by AC-3 Australia, counters, cellular automata, a
  record-supersession example (not in this tree).
- **Rank invariant**: `rank(src) > rank(dst)` on combinational
  edges. Hard. Tile-routing and rank-range queries depend on it.
- **Weight lanes (E1, 2026-08-22)**: `edgeWeights` (Float × 6 per
  node, GPU weighted-tick kernel pre-existing) + new `nodeValue`
  (Float per node, solver state; accumulate Float64, store Float32).
  Persisted in snapshot v6; WAL opcodes 0x04/0x05/0x06; daemon
  commands `SET <n> WEIGHT <dir> <f>` and `SET <n> VALUE <f>`
  (log-first, bounds-checked, finite-only).
- **LadderFold (fold API, branch `dag/fold-api`, 2026-09-10, not yet
  merged)**: the E3 tier ladder — Kron/Schur fold of a rank ring at a
  time, operator stored Float32 between folds, solved in Float64 via
  LAPACK `dgesv` — moved out of the sealed `E3Ladder` runner into
  `dagdb/Sources/DagDB/LadderFold.swift`, arithmetic unchanged.
  `LadderFold.Object(engine:grid:)` reads the neighbor, edge-weight,
  `nodeValue`-as-leak, and rank lanes; `e3-ladder` is now a thin CLI
  over it. Gate contract: `docs/contracts/FOLD_API_GATES_FROZEN.md`
  (F1–F5, all held).

## Test suite

- **446 Swift XCTest cases on main** (2026-09-09, `swift test`), full
  suite ~56 s, zero failures, **9 skipped**. On branch
  `dag/spec8-mouth` (2026-09-10, merged 2026-09-10) the spec-8 waveform
  mouth (`WaveBank`, `BANK` verb family) adds to **506 Swift XCTest
  cases**, same 9 fixture-gated skips, 0 failures. On branch
  `dag/derived-views` (2026-09-10, off `dag/spec8-mouth`, merged with
  `main` here) the alarm-set derived views (`NpzReader`, `CortexFixture`,
  `DerivedViews`, `VIEW` verb family) add to **570 Swift XCTest
  cases**: **32 skipped** with neither fixture env set (the 9
  pre-existing `DAGDB_W2_FIXTURE`-gated skips, unchanged, plus 23 new
  `DAGDB_CORTEX_V4_FIXTURE`-gated skips — 14 in `TwinViewCommandTests`,
  6 in `CortexFixtureTests`, 3 in `DerivedViewsTests`), **9 skipped**
  with `DAGDB_CORTEX_V4_FIXTURE` set (the pre-existing
  `DAGDB_W2_FIXTURE` skips only), 0 failures. The sealed fixture
  (`cortex_v4_world.npz`, 15,145,646 bytes, out of repo) is pinned by
  its own sha256, independent of the `DAGDB_W2_FIXTURE` pin above.
  On branch `dag/fold-api` (2026-09-10, built on `dag/spec8-mouth`,
  merged to main 2026-09-10) the fold API (`LadderFold`, `FOLD` verb
  family) adds **37 Swift XCTest cases (5 `LadderFoldTests` +
  17 `TwinFoldCommandTests` + 15 `parseFold` grammar cases in
  `DSLParserTwinTests`), 10 fixture-gated skips without
  `DAGDB_E3_RUNS` set (9 with it)**, 0 failures — the tenth skip is
  `LadderFoldTests.testF2CourtLaddersBitForBit`, which `throw
  XCTSkip(...)` when the sealed, out-of-repo E3 court run files
  (`DAGDB_E3_RUNS=<dir>`) are absent; present with a mismatched hash
  is a gate **FAIL**, never a skip, same rule as the W2 fixture below.
  **Merged total on `dag/derived-views` (merged to main): 607 Swift
  XCTest cases — 33 skipped with neither fixture env set (the 32
  derived-views skips above plus the FOLD F2 skip), 10 skipped with
  `DAGDB_CORTEX_V4_FIXTURE` set (the pre-existing `DAGDB_W2_FIXTURE`
  9 skips plus the FOLD F2 skip), 0 failures.** On branch
  `dag/kernels` (2026-09-10, built on `main`, merged 2026-09-10) the
  per-path kernel storage and the sealed cross-convolution residual
  (`KernelPair`, `SealedCrossConvolution`, `KERNEL` verb family, `XCONV
  SEALED`) add **655 Swift XCTest cases: 39 skipped with neither
  fixture env set** (the 33 skips above plus 5 new
  `DAGDB_W1_RECORDS`-gated skips — 3 in `SealedCrossConvolutionTests`,
  2 in `TwinKernelCommandTests`; the in-repo `w1_kernels.json`/
  `w1_residuals_v1.json` fixtures are sha-checked and never skip), **0
  failures**. The sealed run against the 190 W1 records
  (`DAGDB_W1_RECORDS`, 18,580,321 bytes, out of repo, sha256 pinned)
  takes ≈10 minutes in a debug build. Gate contract:
  `docs/contracts/KERNELS_GATES_FROZEN.md`.
  On branch `dag/hook` (2026-09-10, built on `main`, merged 2026-09-10)
  the attention hook (`AttentionHook`, `HOOK` verb family — `7
  AttentionHookTests` + `24 TwinHookCommandTests`, plus hook cases in
  `DSLParserTwinTests`/`TwinRegistryTests`/`DagDBWALTwinTests`/
  `DagDBSnapshotTwinTests`) adds to **710 Swift XCTest cases: 45
  skipped with neither fixture env set, 30 skipped with
  `DAGDB_W2_FIXTURE` set alone**, **0 failures**. No new fixture: the
  two sealed hook tests (`testSealedHookStepAllocatorRichestPoint`,
  `testSealedHookStepUniformPolicyRichestPoint`) are gated on the same
  `DAGDB_W2_FIXTURE` as the allocator court. Gate contract:
  `docs/contracts/HOOK_GATES_FROZEN.md`.
  On branch `dag/tiling` (2026-09-10, built on `main`, not yet
  merged): tiling step one — tile files, router, cross-tile BFS/
  ancestry/select (`TiledGraphFiles`, `TiledGraphRouter`,
  `GlobalNodeID`, `TileHalo` — this session found **726 Swift XCTest
  cases already green** on the branch going in — plus this session's
  daemon-layer build (`SAVE TILED`/`TILED` verb family,
  `Tests/DagDBDaemonKitTests/TiledCommandTests.swift`, 26 cases: DSL
  grammar, SAVE TILED/TILED OPEN summary lines checked against an
  independently computed `WriteReport`, TILED BFS/SELECT cross-checked
  row-for-row against the daemon's own `BFS_DEPTHS`/`SELECT` verbs,
  the T4 torn-body refusal over the socket, the reader-session split,
  `TILED CLOSE` → `LIST count=0`) brings the suite to **752 Swift
  XCTest cases: 45 skipped with neither fixture env set (unchanged),
  0 failures**. Gate contract: `docs/contracts/TILING_GATES_FROZEN.md`
  (T1–T6, amendments 1–2). See the "Tiling" section above.
  On branch `dag/ticking` (2026-09-10, built on `dag/tiling`, not yet
  merged): ticking step two — per-tile epochs, manifest refresh at
  every flush, writer/reader roles at open with automatic recovery
  and partial-round completion, `TILED TICK`/`TILED GET`
  (`TiledGraphRouter`'s ticking path, `TiledGraphFiles`'s flush-WAL
  and manifest helpers, `DagDBCommandHandler+Tiled.swift`) brings the
  suite to **782 Swift XCTest cases: 45 skipped (unchanged), 0
  failures**. Gate contract: `docs/contracts/TICKING_GATES_FROZEN.md`
  (W1–W6, amendments 1–3). See the "Ticking across tiles" section
  above.
  The 9 W2 skips are fixture-gated, not unconditional: three tests in
  `SealedGateTests` and six across `TwinAlarmCommandTests`/
  `DagDBSnapshotTwinTests`/etc. call `throw XCTSkip(...)` only when
  the environment variable `DAGDB_W2_FIXTURE` is unset (precedent:
  `DagDBTickPerfTests.swift:206`). Set it to the sealed 29 MB fixture
  path to run them:
  ```
  DAGDB_W2_FIXTURE=/path/to/w2_records.json cd dagdb && swift test
  ```
  The fixture is SHA-256 pinned; the pinned hash is
  `be5c431f8ba410c632bbb18b89bce2b93d74dfcbc7f069ea9051f44e37618303`.
  **This file's earlier "no skips" claim is amended** (contract
  amendment 1, §15, 2026-09-06): a fixture that is *present* but whose
  hash does not match the pin is a gate **FAIL**, never a skip and
  never a warn — only an *absent* fixture skips. Includes E1
  weight-lane tests, the seven twin-primitive tests (2026-09-05
  merge), and the full interface-phase suite (Codable round-trips,
  `TwinRegistry`/`TwinState`, WAL twin ops, snapshot v7 TWIN section,
  DSL/daemon STREAM/HEADER/RECORD/RINGS/CLOCK/GEAR/XCONV/BUDGET/ALARM
  verb tests, MCP + bridge import checks).
  ```
  cd dagdb && swift test
  ```
- **Python plugin tests**: 16 Loom-adapter tests green (`python3 -m
  pytest plugins/loom` from `dagdb/`, 2026-09-10); the earlier
  collection error is gone.

## Twin registries (2026-09-06)

- Seven typed-id registries (`TwinRegistry<Entry>`, prefixes `s`
  stream, `t` record, `n` rings, `c` clock, `g` gear, `b` budget
  layout, `a` alarm set) live on one **daemon-global** `TwinState` —
  there is no per-connection or per-reader-session twin state.
- An eighth registry, `w` (wave bank, `BankEntry` wrapping a
  `WaveBank`), lands on branch `dag/spec8-mouth` (2026-09-10, not yet
  merged) — spec 8's waveform mouth. WAL opcode `0x2C`
  (`twinBankOpen`); snapshot v7's `TwinState.Snapshot` gains a `banks`
  field, decoded tolerantly so an older v7 file with no `banks` key
  still loads (empty bank registry).
- A ninth registry, `v` (view set, wrapping a `DerivedViews` over a
  loaded `CortexFixture`), lands on branch `dag/derived-views`
  (2026-09-10, off `dag/spec8-mouth`, merged 2026-09-10) — spec line 4's
  second view family. WAL opcode `0x2D` (`twinViewLoad`); snapshot v7's
  `TwinState.Snapshot` gains a `views` field, decoded tolerantly the
  same way. View sets persist **by reference** (path + sha256), never
  their bytes; a missing or hash-changed file on restore drops that
  one entry with a stderr `WARN`, same rule as the alarm registry.
  `READER <id> <twin verb>` permits only the read-only twin verbs
  (`STATE`/`LIST`/`INFO`/`CHECK`/`REPLAY`/`VERIFY`/`RECALL`/
  `ALLOCATE`/`FRAME`/`COURT`/`SUCCESSOR`/`CORRUPT`/`REFLEX`/`RUNG`/
  `CEILING`/`FEATURES`); every mutating twin verb inside a reader
  session returns
  `ERROR forbidden: twin verb mutates daemon-global twin state; not
  allowed in reader session`.
- A tenth registry, `k` (kernel pair, `KernelSet` wrapping a
  `KernelPair`), lands on branch `dag/kernels` (2026-09-10, built on
  `main`, merged 2026-09-10) — spec line 6's per-path kernel storage.
  WAL opcode `0x2E` (`twinKernelLoad`); snapshot v7's
  `TwinState.Snapshot` gains a `kernels` field, decoded tolerantly the
  same way. Kernel pairs persist **by reference** (path + sha256,
  plus the DECLARED τ_A/τ_B/σ_source/warmup — K4: never read from the
  kernels file), never the taps; a missing or hash-changed file on
  restore drops that one entry with a stderr `WARN`, same rule as the
  alarm/view registries. `XCONV SEALED` (the W1 court's frozen
  residual) and `KERNEL INFO`/`LIST` are read-only for reader
  sessions; `KERNEL LOAD`/`CLOSE` are forbidden, same shape as every
  other twin family. This is a *second* entry point for spec line 6,
  beside the pre-existing `XCONV CHECK` (`CrossConvolutionCheck`,
  2026-08-30) — `XCONV CHECK` is now documented as the deprecated
  patrol check (it flips 50 of 190 court gates on the sealed W1
  records, all true recordings, per `docs/contracts/
  KERNELS_GATES_FROZEN.md` K5); `XCONV SEALED` is the standing cheap
  check.
- An eleventh registry, `h` (attention hook, `HookEntry` wrapping an
  `AttentionHook`), lands on branch `dag/hook` (2026-09-10, built on
  `main`, merged 2026-09-10) — roadmap item 7, the sealed allocator court
  (`AllocatorCourt.run`) as a daemon-global ticked process: one alarm
  set + one budget layout (sealed by default) + a per-frame budget B +
  a lag Δ (3) + one of three lagged policies (allocator, greedy,
  uniform — the oracle has no lag and stays a court arm) + an optional
  master clock. WAL opcode `0x2F` (`twinHookOpen`) / `0x30`
  (`twinHookStep`); snapshot v7's `TwinState.Snapshot` gains a `hooks`
  field, decoded tolerantly the same way — persisted by parameters
  plus the frame counter t only, never the ledger (DERIVED, rebuilt by
  re-stepping on restore). `ClockEntry.hookIds` lists the hooks a
  clock drives: `CLOCK ADVANCE` steps each bound hook once per tick,
  AFTER that tick's gears; `CLOCK CLOSE`'s reply gains
  `hooks_closed=<n>` beside `gears_closed=<n>` and cascades to bound
  hooks the same way it cascades to gears. Closing an alarm set or
  budget layout a live hook depends on refuses `ERROR forbidden: hook
  <h> depends on <id>`, same shape as the view/bank dependency
  refusals. `HOOK STATE`/`LEDGER`/`INFO`/`LIST` are read-only for
  reader sessions; `HOOK OPEN`/`STEP`/`CLOSE` are forbidden, same
  shape as every other twin family — a hook bound to a clock also
  refuses `HOOK STEP` directly (`ERROR forbidden: bound to clock <c>`)
  so its frame counter has exactly one driver. Gate contract:
  `docs/contracts/HOOK_GATES_FROZEN.md` (H1–H6, amendment 1).
- `STATUS` reports the live total: `... twin_open=<n>` (sum of every
  registry's open count).
- Gate contract (allocator-court replay + successor dyadic lattice):
  `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md`, including AMENDMENT 1 (an independent
  hostile read, 2026-09-06).

## Daemon supervision

- **Prod owner**: `launchd`, label `com.hari.dagdb`, plist at
  `~/Library/LaunchAgents/com.hari.dagdb.plist`.
- **Prod socket**: `/tmp/dagdb.sock`.
- **MCP bridge**: `com.dagdb.mcpo` on port `8787`, plist at
  `~/Library/LaunchAgents/com.dagdb.mcpo.plist`.
- **Prod binary**: `<prod checkout>/dagdb/.build/release/dagdb-daemon`.
- **Prod data root**: `~/dag_databases/prod/`.
- A separate process supervisor is **not** the prod owner; the
  launchd plist above is. If that ever changes, the one-prod-owner
  rule still holds: bootout launchd first, then hand over the socket
  and env.

## Known gaps

- **Restart after SAVE — FIXED 2026-09-09 (opt-in).** Set
  `DAGDB_STARTUP_LOAD=<path>` and the daemon loads that snapshot before
  WAL replay (`DagDBStartup.recover`, DaemonKit); every durable snapshot
  (`SAVE`, and now the autosave on graceful shutdown) checkpoints the WAL
  right after itself, so snapshot + replayed tail = the state at the last
  word. Without the env var the daemon behaves exactly as before (empty
  until an operator `LOAD`). A configured snapshot that is unreadable or
  outside the data root is fatal (exit 2), never a silent empty start.
  Verified by `StartupRecoveryTests` (7) and the live socket smoke
  `examples/twin_primitives/socket_smoke.sh` (23/23). The prod launchd
  plist does not yet set the var — the operator's call.

## DSL drift to know about

- `SET_RANKS_BULK` reads a **u64** rank vector from shm offset 8.
  Older docs (README, `docs/bfs_usage.md`, `docs/wiki/README.md`,
  `docs/wiki/dsl.md`) still say "u32 vector". They are stale.
- `NODES AT RANK <n>` accepts the full u64 range as of
  2026-05-11. The previous `UInt32(r)` narrowing cast was
  removed in `dag/u64-scar-fix`.

## Per-node footprints

Two numbers, often confused:

- **Snapshot body**: 42 bytes / node (post-v3, body layout
  `34 + sizeof(rank)`).
- **Result row** (shm + socket): 24 bytes / row (`u64 node + u64
  rank + u8 truth + u8 type + 6 pad`).
- **Hot RAM footprint** in the architecture deck quoted ~43 B is
  a separate accounting (truth + rank + neighbours + LUT etc),
  not the snapshot body.

## Recent merges to main

- 2026-05-11 — `dag/u64-scar-fix`: NODES AT RANK accepts u64
  values past `UInt32.max`. Acceptance test
  `DagDBU64RankTests`.
- 2026-05-01 — `dag/env-split` phases 2-4: `DAGDB_ENV` →
  derived `DATA_ROOT`, snapshot v5 env-origin trailer,
  socket path derives from env when not explicit.

## What this file is

Pointer of last resort. If a wiki page, README section, or memo
says something different about version / test count / ownership,
trust this file. If this file is wrong, fix it here first, then
the downstream pages.
