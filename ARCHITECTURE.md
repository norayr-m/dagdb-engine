# Architecture

> **Humble disclaimer.** Amateur engineering project. Research prototype.
> Errors likely. Numbers speak. This doc describes what exists, not a
> production-grade system.

How the DagDB code is organised, how the pieces fit together, and what
the persistence / concurrency guarantees actually are. For the
high-level pitch and quick-start, see [`README.md`](README.md). For
session-level change history, see [`CHANGES.md`](CHANGES.md).

---

## 1. Two layers, one repo

```
              ┌──────────────────────────────────────────────┐
              │  docs/engine.md · paper 4 · 4-cycle runtime  │
 root Sources │  Sources/DagDBEngine  Sources/DagDBCLI       │
              │  Package.swift (engine build)                │
              └──────────────────────────────────────────────┘
                                   │
                                   ▼  (uses DagDB as substrate)
              ┌──────────────────────────────────────────────┐
              │  dagdb/ — the DagDB database                 │
              │  Sources/DagDB               Sources/DagDBCLI│
              │  Sources/DagDBDaemon         mcp_server.py   │
              │  pg_dagdb/                   web/bridge.py   │
              │  plugins/biology             plugins/loom    │
              │  sample_db/                  Tests/          │
              │  Package.swift (database build)              │
              └──────────────────────────────────────────────┘
```

Each layer builds independently, each with its own `Package.swift`.
Until 2026-04-20 the database directory was named `legacy/` — an
artefact of the 2026-04-19 `git subtree add`. It was renamed to
`dagdb/` once it became clear the "legacy" label was backwards. Git
history and blame preserved across the rename.

## 2. Data model

Every node carries six parallel fields:

| Field | Width | Purpose |
|---|---|---|
| `id` | 32-bit | Index into the node buffer. |
| `rank` | 64-bit | 0 at root (the "queen" node in the 4-cycle model; see `docs/engine.md`), higher toward leaves. Widened `UInt8 → UInt32` on 2026-04-20 (T1), then `UInt32 → UInt64` on 2026-04-21 (T1b) for the 10¹¹-on-laptop target. |
| `truth` | 8-bit | Ternary state 0 / 1 / 2, or an event-type code in adapter instances (instance-defined; the Loom adapter in `dagdb/plugins/loom/adapter.py` ships one example mapping). Instance-scoped semantics. |
| `nodeType` | 8-bit | User-assigned category. |
| `lut6Low / lut6High` | 2 × 32-bit | 64-bit truth table for the node's Boolean function of up to 6 inputs. |
| `inputs[0..5]` | 6 × 32-bit int | Directed-edge slots; −1 = absent. |

Invariants enforced on insert and load:

- **Rank monotonicity.** `rank(src) > rank(dst)` for every edge — the
  reason the graph is a DAG.
- **No self-loops.** `src ≠ dst`.
- **No duplicate edges per node.** The six input slots must reference
  distinct sources.
- **Bounds.** Every `src ∈ [0, nodeCount)`.

Storage is six parallel contiguous buffers of unified memory
(`MTLBuffer` with `storageModeShared`), Morton-ordered over the hex
grid, so CPU and GPU share pointers without copies. See
`dagdb/Sources/DagDB/DagDBEngine.swift` and
`dagdb/Sources/DagDB/HexGrid.swift`.

## 3. Module map (database layer)

```
DagDBEngine (Metal + state)
    │
    ├── DagDBState                — CPU-side node buffers (rank u32)
    ├── DagDBGraph                — graph primitives, traversal
    ├── HexGrid                   — hex topology + Morton + 7-coloring
    ├── Shaders/dagdb.metal       — tick kernel (LUT6 evaluation, u64 rank)
    │
    ├── DagDBSnapshot             — full-state SerDe (binary v1 + v2 + zlib)
    │     └── atomic-save:  tmp → F_FULLFSYNC → replace → dir fsync
    │
    ├── DagDBJSONIO               — JSON + two-file CSV round-trip
    │     └── same atomic-save discipline, pre-commit rank check
    │
    ├── DagDBBackup               — base.dags + NNNNN.diff chain
    │     ├── initializeChain / appendDiff / restore / compact / info
    │     └── XOR per-buffer diff, zlib-compressed per segment
    │
    ├── DagDBWAL                  — append-only mutation log
    │     ├── Appender.setTruth / setRank / setLUT / checkpoint
    │     └── replay skips records at/before last CHECKPOINT
    │
    ├── DagDBDelta                — truth-state time-series (playback)
    ├── CarlosDelta               — I-frame/P-frame spatial sim codec
    │
    ├── DagDBBFS                  — bfsDepthsUndirected / Backward
    │     └── fanout built on the fly; undirected merges inputs ∪ fanout
    │
    ├── DagDBDistance             — eight built-in subgraph metrics
    │     ├── DagSubgraph (node-set or rankRange)
    │     ├── jaccardNodes / jaccardEdges / rankL1 / rankL2 / typeL1
    │     ├── boundedGED (node + induced-edge symdiff)
    │     ├── weisfeilerLehman1Histogram + weisfeilerLehmanL1
    │     └── laplacian / eigenvaluesSymmetric (inline Jacobi) / spectralL2
    │
    ├── DagDBReaderSession        — snapshot-on-read MVCC (T7)
    │     └── open / close / get / closeAll; session-local DagDBEngine
    │
    ├── DagDBSecondaryIndex       — TruthRankIndex (T15)
    │     ├── per-truth rank-sorted list, lazy rebuild on dirty flag
    │     └── select(truth, rankLo, rankHi) → O(log N + matches)
    │
    ├── NamedStream / StreamHeader
    │   / StreamRecord            — twin spec: deterministic PCG64 stream,
    │                                t-zero admissibility header, slice-
    │                                boundary bit-for-bit replay (§13.3)
    ├── BudgetLayout              — twin spec: per-frame knapsack allocator
    │                                over sealed court decision letters (§13.3)
    ├── CrossConvolutionCheck     — twin spec: sealed cross-ear W1 identity
    │                                as a standing engine check (§13.3)
    ├── GearedRings               — twin spec: six-ring signed-extremum
    │                                recording odometer (§13.3)
    └── MasterClock / PhaseGear   — twin spec: one master tick, rational
                                     gears, integer-exact, no drift (§13.3)
```

Interfaces on top:

```
DagDBCLI        — command-line driver over the library
DagDBDaemon     — Unix-socket server, DSL parser + dispatch,
                   WAL-aware, session-aware, error-taxonomy prefixes
mcp_server.py   — Python MCP wrapping the daemon (37 tools)
pg_dagdb/       — PostgreSQL C extension
web/bridge.py   — browser bridge (HTTP → daemon socket)
E2Runner        — standalone executable, frozen async-Jacobi smoother
                   on the engine's own fabric (§13.2)
E3Ladder        — standalone executable, frozen exact tier-elimination
                   ladder on the engine's own fabric (§13.2)

plugins/biology/rank_policies.py   — Python `RankPolicy` Protocol
                                       + three defaults:
                                       SequencePositionPolicy,
                                       ChainBandPolicy,
                                       TopologicalSortPolicy
plugins/loom/                      — Stop-hook event adapter
                                       (T4 adapter): pure-function
                                       event_to_node, backfill script,
                                       16-test pytest suite
```

## 4. Persistence layer

DagDB has three ways to put state on disk, each using a shared
atomic-save discipline.

### 4.1 Snapshot (`.dags`)

Full engine state at a moment in time. 32-byte header (`DAGS` magic,
version, nodeCount, grid dims, tickCount, flags, body size) followed
by the six buffers concatenated, optionally zlib-compressed.

**Formats**: v1 (pre-2026-04-20, 8-bit rank, 35 bytes/node body),
v2 (32-bit rank, 38 bytes/node body, 2026-04-20 T1), v3 (64-bit
rank, 42 bytes/node body, 2026-04-21 T1b), v4 (v3 + back-edge
trailer), v5 (v4 + env-origin trailer, 2026-05-01 phase 3), and
**v6** (v5 + a `WGTS` weight/value-lane section between the
back-edge section and the `ENVS` trailer, 2026-08-22 E1 — see
§13.1). Load reads all six and widens v1/v2 on read; save always
writes v6. Body size is unchanged from v3 onward; v4, v5, and v6
add fixed trailers/sections, not per-node bytes. Cross-env loads
are rejected when both sides are env-tagged and disagree.

Atomic save on macOS APFS:

```swift
write(path + ".tmp")                    // data
fcntl(fd, F_FULLFSYNC)                  // flush the SSD, not just OS buffers
FileManager.replaceItemAt(path, tmp)    // atomic rename
fcntl(dirFd, F_FULLFSYNC)               // make the rename durable
```

`defer` removes the `.tmp` on any error. A crash at any step leaves
either the old file or the new file — never a truncated one.

### 4.2 Write-ahead log (`DAGW`)

Fixed 16-byte header (`DAGW` + version + nodeCount) followed by
length-prefixed records:

```
Record       = u32 payloadLen + u8 opcode + payload
SET_TRUTH      0x01  u32 node + u8 value                   5 bytes
SET_RANK       0x02  u32 node + u32 value                  8 bytes  (v2)
                     u32 node + u8 value                   5 bytes  (v1 — load-compat)
SET_LUT        0x03  u32 node + u64 lut                   12 bytes
CHECKPOINT     0xF0  u64 epoch                             8 bytes
```

The appender writes the record, then F_FULLFSYNC before returning —
log-first discipline. The daemon appends to the WAL before mutating
the engine buffer so crashed mutations either never happened (no
record) or are replayed on restart.

Replay:

1. Scan forward, note the offset of the **last** `CHECKPOINT`.
2. Scan again, apply only records at or past that offset.
3. If a record's declared length overruns the file end, drop the
   partial tail — treat it as a mid-append crash.

After a successful snapshot the daemon writes a new `CHECKPOINT` with
the current tick count. The next replay skips everything before.

### 4.3 Backup chain

```
<dir>/base.dags        a zlib-compressed snapshot
<dir>/00001.diff       XOR diff vs tip after base
<dir>/00002.diff       XOR diff vs tip after 00001
...
```

Each `.diff` is the XOR of the six engine buffers against the
chain's current tip, zlib-compressed per buffer. Most DagDB edits
touch a handful of bytes, so diffs compress to under 5 % of raw
state for single-bit mutations.

`restore` replays `base.dags` then applies each `.diff` in order.
`compact` restores, writes a new base, deletes the diffs — the chain
collapses to a single file without losing state. All backup writes
use the same atomic-save discipline.

## 5. Query layer

### 5.1 Subgraph type

A `DagSubgraph` is a `Set<Int>` of node IDs, plus convenience
constructors (`all`, `rankRange(lo: UInt64, hi: UInt64)`).

### 5.2 Distance metrics

| Metric | Shape | Complexity |
|---|---|---|
| `jaccardNodes` | node-set symdiff | O(\|A\| + \|B\|) |
| `jaccardEdges` | induced-edge symdiff | O(\|A\| + \|B\| + edges) |
| `rankProfileL1 / L2` | sparse histogram over seen ranks | O(\|A\| + \|B\|) |
| `nodeTypeProfileL1` | histogram over 256 types | O(\|A\| + \|B\|) |
| `boundedGED` | node + induced-edge symdiff count | O(\|A\| + \|B\| + edges) |
| `weisfeilerLehmanL1` | one-round WL hash histogram | O((\|A\| + \|B\|) · deg) |
| `spectralL2` | Jacobi eigenvalues of induced Laplacian | O(n³) per side |

All symmetric. Identical subgraphs produce distance 0. Rank-profile
histograms are sparse `[UInt64: Int]` post-u64-rank widen (2026-04-21
T1b); dense 256 slots were dropped at T1, u64 keys at T1b.

### 5.3 BFS primitives

- `bfsDepthsBackward(from:)` — follow `inputs[]` only. Cheap, no
  fanout build.
- `bfsDepthsUndirected(from:)` — merge inputs + on-the-fly fanout.
  Result: contact-graph geodesic distance from seed for protein /
  Loom encodings where edges are stored one-directional but
  semantically bidirectional.

Both return `[Int32]` of length `nodeCount`: −1 = unreachable, 0 =
seed, positive = depth.

### 5.4 Partition-query primitives

Built on top of BFS + WL-1 + SELECT:

- **`ANCESTRY FROM <node> DEPTH <d>`** — reverse BFS bounded by
  depth. Output: `(node, depth)` pairs to shared memory.
- **`SIMILAR_DECISIONS TO <node> DEPTH <d> K <k> [AMONG TRUTH <t>]`** —
  for each candidate node (optionally filtered by truth code),
  compute its local ancestral subgraph and its WL-1 histogram, L1
  distance to the query's. Return top-K sorted by distance. Cost
  O(C · 6^d) where C is the candidate pool.
- **`HIVE_QUERY …`** — MCP-level alias that dispatches to `SELECT`
  for the common `(truth, rank-range)` pattern. Sidecar-level
  filters (agent, timestamp, event-type name) are client-side on
  the returned node IDs.

### 5.5 Secondary index (T15)

`TruthRankIndex` — per-truth-code rank-sorted list of
`(rank, nodeId)`.

Maintenance:
- Mutations that can change a node's `(truth, rank)` flip a dirty
  bit: `SET_TRUTH`, `SET_RANK`, `SET_RANKS_BULK`, `LOAD`,
  `LOAD_JSON`, `LOAD_CSV`, `IMPORT`, `BACKUP_RESTORE`.
- Next `SELECT` triggers a full rebuild: O(N log N) — scan + sort
  per bucket.
- Memory ≈ 12 bytes × N per active truth code. ≈ 12 MB for 1 M
  events.

Lookup: O(log N + matches) — binary search for the first rank ≥ lo,
linear scan while rank ≤ hi.

Exposed as DSL `SELECT truth <k> rank <lo>-<hi>` and MCP
`dagdb_select_by_truth_rank`.

## 6. Concurrency and isolation

The daemon accepts connections in a **single-threaded serial loop**
(`dagdb/Sources/DagDBDaemon/SocketServer.swift`). Every client
request is handled to completion before the next `accept()`.
Requests cannot interleave at the buffer level and no mutexes are
needed, but throughput is capped at one request at a time.

**Snapshot-on-read MVCC** (T7) gives readers a point-in-time view
without full multi-version machinery:

- `OPEN_READER` allocates a fresh `DagDBEngine` and memcpys the six
  primary buffers into it. Returns a session id (17 chars, counter
  + timestamp).
- `READER <id> <inner>` routes a read-only inner command to the
  session's snapshot engine. Writes, `EVAL`, nested `READER`, and
  expensive `SIMILAR_DECISIONS` are rejected with
  `ERROR forbidden:`.
- `CLOSE_READER` releases the snapshot. `LIST_READERS` reports open
  sessions.

Cost per reader: ≈ 38 bytes × N RAM while the session is open (one
full snapshot body). Upgrade path to full per-node MVCC remains
open — snapshot-on-read was the smallest viable step.

## 7. Daemon DSL and error taxonomy

Commands are newline-delimited text. Full grammar:
`dagdb/Sources/DagDBDaemon/DSLParser.swift`. See `README.md` for the
complete list.

Every response begins with `OK …` on success or
`ERROR <category>: <detail>` on failure. Categories:

| Category | Cause |
|---|---|
| `out_of_range` | node id / rank index out of valid range |
| `dsl_parse` | bad args, unknown LUT preset, unknown metric |
| `unknown_command` | entire verb not recognised |
| `schema` | rank violation, self-loop, duplicate edge, 6-bound overflow |
| `io` | save / load / import / export / backup / json / csv |
| `wal` | append or replay failure |
| `bfs` | BFS primitive failure |
| `not_found` | missing session id or file |
| `forbidden` | write attempt inside a reader session |

Additive — the existing payload after the prefix is preserved
verbatim. Legacy substring matchers still hit.

Shared-memory outputs at `/tmp/dagdb_shm_file`, layout
`[4: count] [4: reserved] [records …]`. Record shapes:

| Command | Record bytes | Fields |
|---|---|---|
| `NODES`, `EVAL`, `TRAVERSE` | 12 | u64 node, u64 rank, u8 truth, u8 type, 6 pad |
| `BFS_DEPTHS` | 4 | i32 depth (indexed by node) |
| `SELECT` | 4 | i32 node |
| `ANCESTRY` | 8 | i32 node, i32 depth |
| `SIMILAR_DECISIONS` | 8 | i32 node, f32 distance |

## 8. Interfaces

### 8.1 CLI

- `dagdb-cli` — reference CLI over the library.
- `dagdb` — higher-level shell at `dagdb/dagdb`.

### 8.2 Daemon + socket

`dagdb-daemon` binds a Unix domain socket (default
`/tmp/dagdb.sock`) and writes shared-memory records to
`/tmp/dagdb_shm_file`. Launchd supervises it via
`~/Library/LaunchAgents/com.hari.dagdb.plist` (not in repo); the
plist points at `dagdb/.build/release/dagdb-daemon --grid 1024`.

Environment variables:

- `DAGDB_WAL=<path>` — enable WAL at the given path.
- `DAGDB_AUTOSAVE=<path>` — snapshot on SIGTERM / graceful exit.

### 8.3 MCP server

`dagdb/mcp_server.py` exposes the daemon as a Model Context Protocol
server. 37 tools, one per DSL command. `mcpo` bridges to HTTP on
`localhost:8787/dagdb/<tool_name>`. Config at
`dagdb/mcpo_config.json` (gitignored).

### 8.4 PostgreSQL extension

`dagdb/pg_dagdb/` — Postgres C extension for SQL-style access. See
its own README.

### 8.5 Plugins

- `dagdb/plugins/biology/rank_policies.py` — `RankPolicy` Protocol.
  Three default implementations:
  - `SequencePositionPolicy` (single chain).
  - `ChainBandPolicy` (multi-chain assembly, each chain in its own
    rank band).
  - `TopologicalSortPolicy` (BFS-depth from a chosen root).
  Python-side computation; output is a `numpy.uint32` rank vector
  committed via `SET_RANKS_BULK`.

- `dagdb/plugins/loom/` — Loom-event ingestion adapter:
  - `adapter.py` — pure-function `event_to_node` + `apply_ingest` +
    the `IngestContext` dataclass. Snapshot-serialisable to
    `<workspace>/dagdb_ingest_ctx.json`.
  - `backfill.py` — one-shot JSONL → DagDB ingester with
    `--reset-ctx` and `--start N` resume.
  - `test_adapter.py` — 16 pytest tests.

## 9. Testing

`dagdb/Tests/DagDBTests/` contains 249 Swift unit + integration
tests running in ~50 s as of 2026-09-05. Per-suite breakdown
drifts faster than the headline; run
`swift test --list-tests` for the current per-file count and
treat the table below as a topical map, not a tally.

| Suite | What it covers |
|---|---|
| `DagDBTests` | Core engine, state, LUT6, tick, graph walks. |
| `DagDBSnapshotTests` | Round-trip, compression, validators, atomic-save durability, v5 env-origin trailer. |
| `DagDBJSONIOTests` | JSON + CSV round-trips, tampered-file rejection. |
| `DagDBBackupTests` | Chain init / append / restore / compact, diff size. |
| `DagDBDistanceTests` | All eight metrics, axioms, Laplacian spectra. |
| `DagDBWALTests` | Append, replay, checkpoint, truncated tail, reopen. |
| `DagDBBFSTests` | Undirected and backward BFS, single-node-per-residue encoding. |
| `DagDBReaderSessionTests` | Open/close, snapshot isolation, u64 rank fidelity, unique ids. |
| `DagDBSecondaryIndexTests` | Dirty flag, lazy rebuild, range correctness, Loom-window scenario. |
| `DagDBU64RankTests` | NODES AT RANK over the u64 ceiling (2026-05-11). |
| `GlobalNodeIDTests` | 24+40 tile-local node ID encoding. |
| `TileHaloTests` | NSEW halo serialisation. |
| `TiledGraphRouterTests` | Tile router scaffold stubs. |
| `SlimeMoldPerfScoutTests` | Slime-mold workload perf scout. |

Plus:
- `dagdb/plugins/biology/rank_policies.py::_selftest` — self-test
  covering all three rank policies.
- `dagdb/plugins/loom/test_adapter.py` — pytest suite on the
  event adapter + ingest-context serialisation. **Currently
  broken at collection** (module-path drift after the worktree
  split); not blocking, repair pending.

Total: **249 Swift green, 2026-09-05.** Full suite ~50 s. Python
pytest temporarily off the green count (collection error).

## 10. Performance signature

Single M5 Max laptop, Apple Silicon, unified memory. Numbers are
illustrative, not certified:

- **Tick kernel.** Metal LUT6 evaluator, 7-colouring for intra-rank
  parallelism. Measured GCUPS: see `dagdb/README.md` for the
  bio-twin and Savanna benchmarks.
- **Snapshot.** Zlib body on a sparse 10 M-node graph compresses to
  20–30 % of the raw 380 MB (v2, 38 bytes/node).
- **Backup diff.** Single truth-bit flip on a 256-node grid produces
  a diff under 5 % of raw state after zlib.
- **Spectral L2.** Jacobi converges in tens of sweeps at `1e-10`
  tolerance for dense symmetric matrices up to ~300 × 300. Larger
  subgraphs need an Accelerate / LAPACK path (not shipped).
- **Loom ingest.** 694 events (archives + live JSONL) through the
  dual-write Stop-hook pipeline in ~140 ms wall clock (~5 k
  events/sec) on the grid-1024 daemon.
- **Secondary index.** Rebuild O(N log N); lookup O(log N +
  matches). Sub-millisecond on the 1 M-node grid for tight rank
  windows.
- **MVCC open.** `OPEN_READER` memcpys the six buffers (~38 MB on a
  1 M-node graph). One-shot cost at session open; reads are free
  thereafter.

## 11. What's intentionally not there

- **No cycles.** Rank monotonicity is a hard invariant.
- **No per-node versioning.** MVCC ships as snapshot-on-read, not
  full multi-version control. Upgrade path open.
- **No floating-point state on the hot path.** Everything in the
  kernel is `u8` / `u32` / `i32`. Distance metrics compute in
  `Double` client-side.
- **No cross-transaction invariant checking.** `C` in ACID is
  "partial" for this reason.
- **No distributed mode.** Single-node. Multi-machine would sit on
  Morton partitioning; not in this codebase.
- **No OR / AND among predicates in `WHERE`.** The DSL supports one
  field-op-value per clause; compose client-side.

## 12. Paper

`paper/dagdb_intermezzo.pdf` — the intermezzo note that seeded the
runtime layer. The database layer has its own companion notes in
`dagdb/docs/`. Neither is peer-reviewed; both are working notes.

## 13. Summer 2026 additions

### 13.1 Weight/value lanes

Two parallel ribbons ride beside the 42-byte-per-node record instead
of inside it: `edgeWeights` (`Float` × 6 per node, one per direction
slot — the GPU weighted-tick kernel already read this lane) and
`nodeValue` (`Float` per node, general solver state — accumulate in
`Double`, store in `Float32`). Both live on `DagDBState` and default
to weightless (`1.0`) / zero so Boolean-mode graphs are unaffected.

Persistence: snapshot **v6** adds a `WGTS` lane section between the
back-edge section and the `ENVS` trailer — magic + a lane-flags byte,
then each present lane (edge weights, an `Int16` activation lane,
node values), written only when non-default so a Boolean snapshot
still pays a handful of bytes. Lanes reset to their defaults on every
load path, including loads of pre-v6 files. WAL opcodes `0x04`
(`setEdgeWeight`, node + direction + `f32`), `0x05` (`setActivation`,
node + `i16`), `0x06` (`setNodeValue`, node + `f32`) extend the
existing log-first, fsync-before-apply discipline. Daemon surface:
`SET <n> WEIGHT <dir> <f>` and `SET <n> VALUE <f>`, bounds-checked
and finite-only before they touch the WAL or the buffer.

### 13.2 Solver ladder

Two standalone executables (`dagdb/Sources/E2Runner`,
`dagdb/Sources/E3Ladder`) run frozen numerical contracts directly on
the engine's own fabric rather than a side simulation, so what gets
judged is the actual DagDB substrate.

- **E2Runner** — the smoother, per the frozen E2 contract
  (held outside this repository, frozen 2026-08-22). Runs the frozen async
  Jacobi schedule over the engine's `HexGrid` wiring, reading and
  writing the `nodeValue` lane in `Float32` with `Float64`
  accumulation for the convergence check. It is the builder's half
  only — it writes raw per-cell results (work, rounds, final
  relative error); it computes no ratios, and it does not judge
  pass/fail. That belongs to the judge's gate, outside this repository.
- **E3Ladder** — the exact tier ladder, per the frozen E3 contract
  (held outside this repository, frozen 2026-08-26). Topology, per-edge
  weights, per-node leaks, and ranks all live fabric-resident — in
  the engine's `neighborsBuf`, `edgeWeightsBuf`, `nodeValue` (as the
  leak carrier), and `rankBuf` — rather than in a shadow array. Each
  fold eliminates one rank ring via a dense symmetric solve
  (`dgesv_` through Accelerate/LAPACK, `Float64` arithmetic), then
  stores the reduced operator and folded sources back to `Float32`
  per rung — the fabric width the court judges. Raw fold logs and
  per-checkpoint tier answers only; again, the judge owns every
  ratio.

### 13.3 Twin primitives

Seven small, independently-sealed types under `dagdb/Sources/DagDB/`,
each encoding one frozen "twin spec" contract as executable code
rather than as a description of one. Since the interface phase
(merged 2026-09-06) all seven — plus the twin spec line 4
alarm-stream type below — carry state-bearing inits and `Codable`, are
held in one daemon-global `TwinState` of typed-id registries, and are
reachable over the daemon socket (DSL) and MCP; see §13.5's replacement
note and `docs/wiki/dsl.md`'s "Twin primitives" section for the wire
grammar.

- **`NamedStream.swift`** — a deterministic named random stream:
  PCG64 (XSL-RR, 128-bit state as `(hi, lo)` `UInt64` pairs),
  bit-compatible with numpy's PCG64 when seeded from an explicitly
  printed generator state. Encodes twin spec line 3 (deterministic
  replay): the Python-fixture bridge is explicit state, not seed
  hashing, so both sides produce the identical draw sequence.
  Test file: `NamedStreamTests.swift`.
- **`StreamHeader.swift`** — the time-domain admissibility header,
  twin spec line 7 (the "t-zero law"). Seven quantities (signal
  band, τ-window, comb rate, first-echo time, record window,
  integrator step, clock-sync floor) must be declared before a
  stream is used; `violations()` catches a signal wider than its
  window, sub-Nyquist comb rate, a record window that reaches the
  first echo, and an above-Nyquist integrator step. Test file:
  `StreamHeaderTests.swift`.
- **`StreamRecord.swift`** — binds an admissible `StreamHeader` to a
  `NamedStream` and records draws in slices, each capturing the
  generator's state *at entry*. Any slice then replays bit-for-bit
  in isolation by reseeding from its boundary words — the property
  twin spec line 3's courts depend on. Refuses inadmissible headers
  at construction rather than at first use. Test file:
  `StreamRecordTests.swift`.
- **`BudgetLayout.swift`** — the per-frame knapsack primitive, twin
  spec line 5. Encodes the sealed decision letters from the
  allocator and successor courts verbatim: maximize total read
  value under budget; ties break on minimum total cost, then on the
  lexicographically smallest sorted pocket set; claims on one pocket
  merge, with read values adding and the purchase tier set to the
  cheapest tier sufficient for the deepest requirement among the
  pocket's claims. Exact search, capped at 20 claimed pockets
  (exponential in that count). Test file: `BudgetLayoutTests.swift`.
- **`CrossConvolutionCheck.swift`** — the sealed cross-ear W1
  identity, twin spec line 6, as a standing engine check rather than
  a one-off court exhibit. For two ears with per-path kernels from a
  common source, a true source-born signal satisfies
  `kB ⋆ a == kA ⋆ b`; a forged recording or a corrupted path model
  shows up as a large normalized residual after the declared
  warmup. Storage is `Float32` (engine lane width), accumulation is
  `Double`. Test file: `CrossConvolutionCheckTests.swift`.
- **`GearedRings.swift`** — the geared six-ring recording odometer,
  twin spec line 1's memory half, sealed at gear 6 / 6 rings / 32
  cells (192 numbers total). Ring `j` advances every `gear^j` ticks
  and keeps only the signed extremum of its span plus the tick it
  occurred; this gearing (not a uniform pyramid or an equal-budget
  tail) is what gives signed recall across six orders of lag from a
  fixed, small footprint. Test file: `GearedRingsTests.swift`.
- **`MasterClock.swift`** (with `GearRatio` and `PhaseGear`) — twin
  spec line 2: one master tick, every generator and scanner derived
  from it through a rational-gear phase accumulator with a latch.
  Integer arithmetic only, so a `p/q` gear fires exactly
  `floor(N·p/q)` times after `N` master ticks — drift-free by
  construction, and the printed gear graph makes the three-clock
  identity (oscillator = machine shove = body carrier) checkable
  rather than assumed, since only one clock exists. Test file:
  `MasterClockTests.swift`.
- **`AlarmRecord.swift`/`SealedCourt.swift`/`AlarmFixture.swift`/
  `CorruptionModel.swift`/`SuccessorCourt.swift`/`AllocatorCourt.swift`**
  (interface phase, 2026-09) — twin spec line 4, the alarm-stream contract.
  `AlarmFixture` loads the sealed, SHA-pinned, out-of-repo 29 MB W2
  fixture (`DAGDB_W2_FIXTURE`) and reconstructs file order from the
  sealed keys; `SealedCourt` holds the frozen pocket/tier/tariff
  vocabulary; `CorruptionModel` mirrors the Python
  `true_branches`/`phantom_subsets`/`enumerate_outcomes` exact
  enumeration (εm/εs/εn); `AllocatorCourt` and `SuccessorCourt` are the
  two engine courts — `AllocatorCourt.run` mirrors `run_point`
  bit-for-bit (gate 1), `SuccessorCourt.frameTotals` mirrors
  `frame_totals_at` bit-for-bit (gate 2). Both gates are pinned exactly
  in `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md` and reproduced by
  `SealedGateTests.swift` against the real fixture. Test files:
  `AlarmRecordTests.swift`, `AlarmFixtureTests.swift`,
  `CorruptionModelTests.swift`, `SealedGateTests.swift`.

**State-bearing inits, Codable, registries, WAL, snapshot v7 (the interface phasea/T1b/T5–T7, 2026-09-06).** Every primitive above gained a
state-bearing initializer and `Codable` conformance so a daemon-held
instance survives a restart in O(1) rather than being reconstructed
from scratch. `TwinRegistry<Entry>` (`dagdb/Sources/DagDB/
TwinRegistry.swift`) generalizes the existing reader-session
dictionary+counter+typed-error pattern to all seven kinds; one
`TwinState` (`TwinState.swift`) holds seven such registries
(prefixes `s`/`t`/`n`/`c`/`g`/`b`/`a`) as a single **daemon-global**
instance — there is no per-connection or per-reader-session twin
state. Every mutation is a `TwinOp` applied through `TwinState.apply`;
`TwinOp` is logged to the WAL as one new opcode per case, `0x20`–`0x2B`
(`TwinWAL.swift`'s `TwinWALCodec`, little-endian, malformed payload
skipped on replay rather than fatal), and the whole `TwinState` exports
as a `Codable` `Snapshot` written into snapshot **v7**'s new `TWIN`
section (magic `"TWIN"` + `u32` length + sorted-keys JSON, between the
WGTS lane section and the ENVS trailer; a v≤6 file resets the twin
state to empty on load). Alarm sets persist by reference (path +
sha256) — a missing or hash-mismatched file on restore drops that one
entry with a stderr `WARN` rather than refusing the whole load.

### 13.4 Durability (G73) and tick performance

**G73** (`docs/g73/SPEC_g73.md`) hardens the fsync/durability path:
an opt-in WAL group-commit batch knob (prod stays per-record +
`F_FULLFSYNC`; dev/test may batch by count or time, whichever
first, with an explicit and tested loss bound), a side-by-side
snapshot `.sha256` manifest verified *before* buffers are touched
(mismatch refuses the load rather than half-loading), and a kill-9
stress probe plus a deterministic in-suite torn-tail-WAL acceptance
test. See `docs/g73/` for the full spec and results.

**Tick performance** (`docs/perf_recovery/SPEC_tick_perf.md`)
recovers throughput lost to rank×color serialization and early-out
thread waste: precomputed per-(rank, color) node lists give a
**compacted dispatch** that is bit-for-bit identical to the legacy
whole-color-group path and is invalidated correctly on rank
mutation; an opt-in **`TICK_SYNC`** double-buffered synchronous mode
matches a pure-CPU reference simulation bit-for-bit, including
register latching, and is deliberately *not* the same schedule as
rank-ordered `TICK` (a rank-ordered chain settles in one rank tick
but takes `depth` ticks under `TICK_SYNC`). See `docs/perf_recovery/`
for measured ms/tick and GCUPS on the 1M-node grid.

### 13.5 What is still NOT wired

- The seven twin primitives plus the alarm-stream court types (§13.3)
  are reachable over the daemon socket (DSL) and MCP since the
  interface phase (2026-09-06) — every verb has a `TwinCommand` case,
  a handler, WAL persistence, and a snapshot v7 slot. What is still
  NOT done: they are not fused into the tick loop (the interface phase exposes them,
  does not wire them into `TICK`/`TICK_SYNC` dispatch — that is spec 8,
  per `ROADMAP.md`), and **the two sealed gates depend on an
  out-of-repo fixture** (`DAGDB_W2_FIXTURE`, SHA-pinned, 29 MB) — the
  9 fixture-gated tests in the 439-case suite skip (not fail) when
  that environment variable is unset, so "the suite is green" does not
  by itself mean the gates ran; see `CURRENT_STATE.md` and
  `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md`.
- **`TiledGraphRouter`** (with `GlobalNodeID`) remains a routing
  scaffold: cross-tile addressing and stubs exist and are tested,
  but there is no working multi-tile query path. Section 11's "no
  distributed mode" still holds in practice.

---

## Humble disclaimer

This repository is a research prototype by a working mathematician,
not a production database. Every guarantee here is the honest result
of reading the code and running the tests on one machine on one day.
Errors likely. No competitive claims.
