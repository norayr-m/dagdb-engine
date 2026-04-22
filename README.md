# DagDB

**6-bounded ranked DAG database on Apple Silicon, with a 4-cycle runtime on top.**

> **Humble disclaimer.** Amateur engineering project. We are not HPC
> professionals and make no competitive claims. The numbers here come
> from a single M5 Max laptop, no controlled benchmark, no peer
> review. Errors likely. Numbers speak.

---

## What it is

A graph database where every node has at most six directed inputs, a
64-bit programmable truth table (LUT6), a ternary state (−1, 0, +1),
and a 64-bit rank. Edges always go from higher rank to lower rank, so
the graph is acyclic by construction.

Two layers in one tree:

| Layer | Path | Role |
|---|---|---|
| **Database** | `dagdb/` | 6-bounded ranked DAG store: library, `dagdb-cli`, `dagdb-daemon`, Python biology and Loom plug-ins, MCP server, PostgreSQL extension, sample graphs. All active development lives here. |
| **Runtime** | `Sources/` + `Package.swift` at repo root | 4-cycle optimiser-executor (paper 4 scaffold). Independent build. Uses a DagDB substrate as its computation graph. |

Between 2026-04-19 and 2026-04-21 the database layer was extended
with a rank-widening + MVCC + secondary-index pass — u32→u64 rank,
WAL, snapshot-on-read, ancestry and similarity primitives.

**Ship-storm 2026-04-21.** Six items landed on the engine in a single
day, all tests green:

- **u32 rank refactor** (T1, 2026-04-20) — address space 255 → 4.3 billion;
  snapshot format v2 (38 B/node).
- **u64 rank refactor** (T1b, 2026-04-21) — address space 4.3 billion →
  1.8 × 10¹⁹; snapshot format v3 (42 B/node). Backward-compat load
  accepts v1 (u8) and v2 (u32) and widens on read.
- **`rankPolicy` Protocol + three defaults** (T2) —
  sequence-position / chain-band / topological-sort.
- **`SET_RANKS_BULK`** (T3) — shm-fed u32 vector rewrite, bypasses
  per-edge validation.
- **MVCC snapshot-on-read** (T7) — `OPEN_READER` / `READER id …`
  sessions memcpy a stable engine copy; writers unblocked.
- **`bfsDepths` primitive + `BFS_DEPTHS FROM <seed>` DSL** —
  undirected and backward.
- **Loom Pass 1 complete** — 694 events ingested end-to-end on the
  004 / u32 daemon, nodes 0–693, ~140 ms aggregate, ~4.6–5.2 k
  events/sec. Adapter conforms to the Protocol. Dual-write through
  `capture_latest` is live.

**Tests.** 98 Swift test cases + 16 Python adapter tests green as of
2026-04-21. No skips, no xfails. Counts cited separately on purpose.

**Persistence policy (standing rule).** All persistent DagDB state on
this machine lives under `~/dag_databases/`. The daemon enforces this
via `DAGDB_DATA_ROOT`; any out-of-root `SAVE`/`LOAD`/`BACKUP` is
rejected. Gitignore is tightened to allow exactly one sample
(`dagdb/sample_db/demo_graph.dagdb`); every other `.dags`/`.dagdb`/
`.wal` is blocked. See
[`docs/wiki/data-and-persistence.md`](docs/wiki/data-and-persistence.md)
for the contract.

**The wiki** is at [`docs/wiki/`](docs/wiki/README.md). Start with
[`data-and-persistence.md`](docs/wiki/data-and-persistence.md) if
you want to know where every byte lives before you run anything.

---

## Quick start — database

```
cd dagdb
swift build -c release
```

Start the daemon (listens on `/tmp/dagdb.sock`, grid 1024 ≈ 1 M nodes):

```
.build/release/dagdb-daemon --grid 1024 --socket /tmp/dagdb.sock
```

Durability envs (point these inside `~/dag_databases/`):

```
DAGDB_DATA_ROOT=$HOME/dag_databases \
DAGDB_WAL=$HOME/dag_databases/live.wal \
DAGDB_AUTOSAVE=$HOME/dag_databases/auto.dags \
  .build/release/dagdb-daemon --grid 1024
```

`DAGDB_DATA_ROOT` is the single persistent-DB root; any `SAVE`/
`LOAD`/`BACKUP` path outside it is rejected with
`ERROR io: path: '<p>' outside DAGDB_DATA_ROOT`. The launchd plist
(`~/Library/LaunchAgents/com.hari.dagdb.plist`) wires all three
envs automatically on this machine.

Send a command from another terminal:

```
echo "STATUS" | nc -U /tmp/dagdb.sock
```

## Quick start — 4-cycle runtime

```
swift build                 # builds the engine at the repo root
.build/debug/dagdb-engine-cli
```

The runtime depends on nothing under `dagdb/` — the two layers are
decoupled. Paper: `paper/dagdb_intermezzo.pdf`.

## Quick start — dashboard

```
python3 -m pip install pyyaml
python3 dashboard/gen_dashboard.py
open -a "Google Chrome" dashboard/index.html
```

Auto-refreshes every 30 seconds. Edit `dashboard/features.yaml` to
change the ledger.

## Quick start — biology ingestion

```python
from dagdb.plugins.biology.rank_policies import SequencePositionPolicy
import numpy as np

policy = SequencePositionPolicy()
ranks = policy.assign_ranks(
    node_count=N,
    max_rank=N,
    seq_indices=np.arange(N),
)
# Write `ranks` to shm offset 8 and call SET_RANKS_BULK — or use
# per-node SET <id> RANK <r> calls if you prefer.
```

See `dagdb/plugins/biology/rank_policies.py` for all three default
policies (sequence-position / chain-band / topological-sort).

## Quick start — Loom events

Stop-hook adapter in `dagdb/plugins/loom/adapter.py`:

```python
from dagdb.plugins.loom.adapter import event_to_node, apply_ingest

record = event_to_node(loom_event, ctx)  # pure function
_submit_insert(record)                   # your socket / MCP call
ctx = apply_ingest(record, ctx)
```

Ingest context lives at `~/jarvis_workspace/dagdb_ingest_ctx.json` by
convention. See `dagdb/plugins/loom/backfill.py` for the one-shot
JSONL → DagDB ingester used for historical loads.

---

## Features

Authoritative ledger: `dashboard/features.yaml`. At a glance:

### Core engine
- 6-bounded ranked DAG, 64-bit rank (u8 → u32 on 2026-04-20 T1,
  then u32 → u64 on 2026-04-21 T1b; address space now 1.8 × 10¹⁹).
- LUT6 per node — any six-input Boolean function is one table lookup
  per tick.
- Ternary state; zero is the free level.
- Morton Z-curve memory layout + 7-colouring for lock-free intra-rank
  parallelism on the GPU.
- Metal tick kernel, hex-grid substrate, Apple Silicon UMA.

### Persistence
- **Snapshot v3** (`.dags`) — atomic save via tmp + `F_FULLFSYNC` +
  `replaceItemAt` + dir fsync. Body is 42 B/node (u64 rank + truth +
  type + LUT + 6 neighbor slots). Loads v1 (u8 rank), v2 (u32 rank),
  and v3 (u64 rank), widening in place. Optional zlib body compression.
- **JSON / CSV round-trip** — `dagdb-json` schema mirrors the six
  engine buffers; CSV is two files (`nodes.csv` + `edges.csv`). Both
  paths use the same atomic-save discipline.
- **Backup chain** — `base.dags` + ordered `NNNNN.diff` XOR diffs,
  append / compact / restore. Single-bit mutations produce diffs
  under 5 % of raw state.
- **WAL** — append-only log (`DAGW` format), fsync-before-apply per
  mutation. Truncated-tail records drop silently on replay.
  `CHECKPOINT` markers bound replay after snapshot. Opt-in via
  `DAGDB_WAL` env.

### Query
- **`SELECT truth <k> rank <lo>-<hi>`** — secondary index
  (`TruthRankIndex`) with lazy rebuild on a dirty flag. Common
  "all events of type X in rank window Y" query, O(log N +
  matches).
- **`BFS_DEPTHS FROM <seed> [BACKWARD]`** — per-node depth vector,
  undirected (inputs ∪ fanout) or backward (inputs only). Zero-copy
  shared-memory output.
- **`ANCESTRY FROM <node> DEPTH <n>`** — reverse BFS bounded by
  depth, shared-memory `(node, depth)` pairs.
- **`SIMILAR_DECISIONS TO <node> DEPTH <d> K <k> [AMONG TRUTH <t>]`** —
  top-K ranked by Weisfeiler-Lehman-1 histogram L1 distance over
  local ancestral subgraphs. Truth filter narrows the candidate pool.
- **`TRAVERSE FROM <node> DEPTH <n>`** — k-rank expansion, legacy
  walk.
- **Eight built-in subgraph distance metrics** — Jaccard nodes,
  Jaccard edges, rank-profile L1 + L2, node-type L1, bounded GED,
  Weisfeiler-Lehman-1 histogram L1, spectral L2 over Laplacian
  eigenvalues via an inline Jacobi eigensolver.

### Isolation (MVCC)
- **`OPEN_READER` / `CLOSE_READER` / `LIST_READERS`** — open a
  snapshot-on-read session (memcpy of the six buffers into a fresh
  `DagDBEngine`). Writers run unblocked on primary.
- **`READER <id> <inner command>`** — route a read-only command to
  the session's snapshot. Writes and `EVAL` are rejected.

### ACID status

| | Property | Status | Evidence |
|---|---|---|---|
| A | Atomicity | **pass** | `DagDBSnapshot.save`: tmp + F_FULLFSYNC + `replaceItemAt` + dir fsync. 3 durability tests. |
| C | Consistency | partial | Rank monotonicity on insert + validator on load. No cross-transaction invariant checking. |
| I | Isolation | **pass** | Serial accept loop + snapshot-on-read MVCC. Readers get a stable point-in-time view; writers unblocked. |
| D | Durability | **pass** | F_FULLFSYNC on snapshot body + dir fsync on rename + WAL fsync-before-apply. |

### Interfaces
- **CLI** — `dagdb`, `dagdb-cli`, `dagdb-daemon`.
- **Python MCP server** (`dagdb/mcp_server.py`) — 37 tools on
  `http://localhost:8787/dagdb/…` via `mcpo`.
- **PostgreSQL extension** (`dagdb/pg_dagdb/`).
- **Browser bridge** (`dagdb/web/bridge.py`).
- **Plugins**:
  - `dagdb/plugins/biology/rank_policies.py` — `RankPolicy` Protocol
    + three defaults (sequence-position / chain-band /
    topological-sort).
  - `dagdb/plugins/loom/` — hive-event adapter (`adapter.py`,
    `backfill.py`, `test_adapter.py`) for Loom-as-DagDB.

### Error taxonomy

Daemon error responses carry a category prefix so scripts can
distinguish failure modes without phrase matching:

```
ERROR out_of_range: …     node/index bounds
ERROR dsl_parse: …        bad args, unknown LUT preset, unknown metric
ERROR unknown_command: …  entire verb not recognized
ERROR schema: …           rank violation, self-loop, duplicate edge,
                          6-bound overflow
ERROR io: …               save / load / import / export / backup /
                          json / csv
ERROR wal: …              WAL append or replay failure
ERROR bfs: …              BFS primitive failure
ERROR not_found: …        missing session id, missing file
ERROR forbidden: …        reader-session write attempt
```

Additive — payloads after the prefix are preserved verbatim, so
legacy substring matchers still hit.

---

## Repository layout

```
.
├── README.md                       you are here
├── ARCHITECTURE.md                 module map, data model, invariants
├── CHANGES.md                      session-by-session log
├── CONTRIBUTING.md                 short contributor note
├── LICENSE                         GPL-3.0
├── Package.swift                   runtime build (4-cycle engine)
├── Sources/DagDBEngine/            4-cycle runtime engine + shader
├── Sources/DagDBCLI/               engine CLI
├── tests/                          runtime test scaffold (Python M0)
├── paper/                          dagdb_intermezzo.tex / .pdf
├── dashboard/                      feature ledger + HTML status page
│   ├── features.yaml
│   ├── gen_dashboard.py
│   ├── index.html
│   └── README.md
├── docs/
│   ├── engine.md                   the 4-cycle runtime in depth
│   ├── bfs_usage.md                BFS primitive cheat sheet
│   └── (internal architecture sketches live outside the repo)
└── dagdb/                          the DagDB database (canonical)
    ├── Package.swift               database layer build
    ├── Sources/DagDB/              engine, persistence, WAL, backup,
    │                                distance, BFS, MVCC, index
    ├── Sources/DagDBCLI/           dagdb CLI
    ├── Sources/DagDBDaemon/        dagdb-daemon + socket + DSL
    ├── Tests/DagDBTests/           98 tests, ~2.8 s
    ├── mcp_server.py               Python MCP server (37 tools)
    ├── mcpo_config.json            local MCP bridge config (gitignored)
    ├── pg_dagdb/                   PostgreSQL extension
    ├── web/bridge.py               browser bridge
    ├── sample_db/                  one allow-listed demo graph
    ├── plugins/
    │   ├── biology/                rank_policies.py
    │   └── loom/                   adapter.py, backfill.py, tests
    └── README.md                   database-layer overview
```

---

## DSL reference

Full grammar in `dagdb/Sources/DagDBDaemon/DSLParser.swift`.

```
# Lifecycle
STATUS
TICK <n>
EVAL [WHERE <field><op><value>] [RANK <lo> TO <hi>]
VALIDATE

# Read
NODES [AT RANK <n>] [WHERE <field><op><value>]
TRAVERSE FROM <node> DEPTH <n>
GRAPH INFO

# Mutate
SET <node> TRUTH <0|1|2>
SET <node> RANK <n>
SET <node> LUT <PRESET>
CONNECT FROM <src> TO <dst>
CLEAR <node> EDGES
SET_RANKS_BULK          # reads u32 vector from shm offset 8

# Persistence
SAVE <path> [COMPRESSED]
LOAD <path>
EXPORT MORTON <dir>
IMPORT MORTON <dir>

# JSON / CSV
SAVE JSON <path>
LOAD JSON <path>
SAVE CSV <dir>
LOAD CSV <dir>

# Backup chain
BACKUP INIT    <dir>
BACKUP APPEND  <dir>
BACKUP RESTORE <dir>
BACKUP COMPACT <dir>
BACKUP INFO    <dir>

# Secondary index
SELECT truth <k> rank <lo>-<hi>

# BFS and hive queries
BFS_DEPTHS FROM <seed> [BACKWARD]
ANCESTRY FROM <node> DEPTH <d>
SIMILAR_DECISIONS TO <node> DEPTH <d> K <k> [AMONG TRUTH <t>]

# Subgraph distances (rank-range subgraphs)
DISTANCE <metric> <loA>-<hiA> <loB>-<hiB>

# MVCC reader sessions
OPEN_READER
CLOSE_READER <id>
LIST_READERS
READER <id> <inner read-only command>
```

Metrics: `jaccardNodes`, `jaccardEdges`, `rankL1`, `rankL2`, `typeL1`,
`boundedGED`, `wlL1`, `spectralL2`.

---

## MCP server

`dagdb/mcp_server.py` exposes the daemon as a Model Context Protocol
server. 37 tools wrap every DSL command above. `mcpo` bridges them to
HTTP on port 8787:

```
http://localhost:8787/dagdb/<tool_name>
http://localhost:8787/dagdb/openapi.json       # tool catalog
```

Launched via `~/Library/LaunchAgents/com.dagdb.mcpo.plist` (local,
not in repo). The daemon itself is supervised by
`~/Library/LaunchAgents/com.hari.dagdb.plist` and points at
`dagdb/.build/release/dagdb-daemon --grid 1024`.

---

## Development

```
cd dagdb
swift test                                      # 98 tests, ~2.8 s
python3 plugins/biology/rank_policies.py        # self-test
python3 -m pytest plugins/loom/test_adapter.py -q   # 16 tests
```

Per-module Swift test suites:

```
swift test --filter DagDBSnapshotTests
swift test --filter DagDBJSONIOTests
swift test --filter DagDBBackupTests
swift test --filter DagDBDistanceTests
swift test --filter DagDBWALTests
swift test --filter DagDBBFSTests
swift test --filter DagDBReaderSessionTests
swift test --filter DagDBSecondaryIndexTests
```

---

## License

GPL-3.0. See `LICENSE`.

## Humble disclaimer

Amateur engineering project. Research prototype. Errors likely.
Numbers speak. No competitive claims.
