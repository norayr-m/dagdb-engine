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
    └── DagDBSecondaryIndex       — TruthRankIndex (T15)
          ├── per-truth rank-sorted list, lazy rebuild on dirty flag
          └── select(truth, rankLo, rankHi) → O(log N + matches)
```

Interfaces on top:

```
DagDBCLI        — command-line driver over the library
DagDBDaemon     — Unix-socket server, DSL parser + dispatch,
                   WAL-aware, session-aware, error-taxonomy prefixes
mcp_server.py   — Python MCP wrapping the daemon (37 tools)
pg_dagdb/       — PostgreSQL C extension
web/bridge.py   — browser bridge (HTTP → daemon socket)

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
v2 (32-bit rank, 38 bytes/node body, 2026-04-20 T1), and v3 (64-bit
rank, 42 bytes/node body, 2026-04-21 T1b). Load reads all three
and widens the rank field on v1/v2; save always writes v3.

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
    `~/jarvis_workspace/dagdb_ingest_ctx.json`.
  - `backfill.py` — one-shot JSONL → DagDB ingester with
    `--reset-ctx` and `--start N` resume.
  - `test_adapter.py` — 16 pytest tests.

## 9. Testing

`dagdb/Tests/DagDBTests/` contains 98 Swift unit + integration
tests running in ~2.8 s:

| Suite | Tests | What it covers |
|---|---:|---|
| `DagDBTests` | 27 | Core engine, state, LUT6, tick, graph walks. |
| `DagDBSnapshotTests` | 10 | Round-trip, compression, validators, atomic-save durability. |
| `DagDBJSONIOTests` | 5 | JSON + CSV round-trips, tampered-file rejection. |
| `DagDBBackupTests` | 6 | Chain init / append / restore / compact, diff size. |
| `DagDBDistanceTests` | 15 | All eight metrics, axioms, Laplacian spectra. |
| `DagDBWALTests` | 8 | Append, replay, checkpoint, truncated tail, reopen. |
| `DagDBBFSTests` | 7 | Undirected and backward BFS, single-node-per-residue encoding. |
| `DagDBReaderSessionTests` | 9 | Open/close, snapshot isolation, u64 rank fidelity, unique ids. |
| `DagDBSecondaryIndexTests` | 11 | Dirty flag, lazy rebuild, range correctness, Loom-window scenario. |

Plus:
- `dagdb/plugins/biology/rank_policies.py::_selftest` — self-test
  covering all three rank policies.
- `dagdb/plugins/loom/test_adapter.py` — 16 pytest tests on the
  event adapter + ingest-context serialisation.

Total: **98 Swift + 16 Python pytest = 114 green.** Full suite under
five seconds.

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

---

## Humble disclaimer

This repository is a research prototype by a working mathematician,
not a production database. Every guarantee here is the honest result
of reading the code and running the tests on one machine on one day.
Errors likely. No competitive claims.
