# Current state — DagDB

One-page snapshot of what is live right now. Read this before
trusting any older doc's claim about version, test count, or
ownership.

> **Humble disclaimer.** Amateur engineering project. We are not
> HPC professionals and make no competitive claims. The numbers
> here come from a single M5 Max laptop, no controlled benchmark,
> no peer review. Errors likely. Numbers speak.

Last refreshed: 2026-09-10 (main: interface phase merged 2026-09-06,
startup recovery merged 2026-09-09).

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
snapshot v7 `TWIN` section (below). `STATUS` now reports
`twin_open=<n>` alongside the existing fields.
`docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md` is the frozen gate contract (incl.
amendment 1, an independent hostile read).

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

## Test suite

- **446 Swift XCTest cases** (2026-09-09, `swift test` on main),
  full suite ~56 s, zero failures, **9 skipped**.
  The 9 skips are fixture-gated, not unconditional: three tests in
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
- **Python plugin tests**: currently not runnable from the
  worktree layout — collection fails due to module path. Do not
  cite a green Python count until the path is repaired.

## Twin registries (2026-09-06)

- Seven typed-id registries (`TwinRegistry<Entry>`, prefixes `s`
  stream, `t` record, `n` rings, `c` clock, `g` gear, `b` budget
  layout, `a` alarm set) live on one **daemon-global** `TwinState` —
  there is no per-connection or per-reader-session twin state.
  `READER <id> <twin verb>` permits only the read-only twin verbs
  (`STATE`/`LIST`/`INFO`/`CHECK`/`REPLAY`/`VERIFY`/`RECALL`/
  `ALLOCATE`/`FRAME`/`COURT`/`SUCCESSOR`/`CORRUPT`); every mutating
  twin verb inside a reader session returns
  `ERROR forbidden: twin verb mutates daemon-global twin state; not
  allowed in reader session`.
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
- **Prod binary**: `004_Active_Doing_DagDB-prod/dagdb/.build/release/dagdb-daemon`.
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
