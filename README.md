# DagDB

**6-bounded ranked DAG database on Apple Silicon, with a 4-cycle runtime on top.**

> **Humble disclaimer.** Amateur engineering project. We are not HPC
> professionals and make no competitive claims. The numbers here come
> from a single M5 Max laptop, no controlled benchmark, no peer
> review. Errors likely. Numbers speak.

---

## What it is

A graph database where every node has at most six directed inputs, a
64-bit programmable truth table (LUT6), a one-byte truth state, and a
64-bit rank. Edges always go from higher rank to lower rank, so the
graph is acyclic by construction.

The truth byte means 0 = FALSE, 1 = TRUE, 2 = UNDEFINED; values 3–255
are event codes an adapter may store on binary nodes (the Loom plug-in
does). It is not a −1/0/+1 state on every node. A **binary** node — the
default, and the only kind before the ternary build — reads an input
as the bit `byte == 1`, so UNDEFINED and event codes read as FALSE, and
writes 0 or 1 through its LUT6: an UNDEFINED does not survive its next
evaluation.
A **ternary-mode** node (TTABLE or TTHRESH, the native ternary tick)
reads the same byte
as a trit — 0 → −1, 1 → +1, 2 → 0, any code ≥ 3 → 0, an absent input
→ 0 — and stores its trit as −1 → 0, 0 → 2, +1 → 1, so its UNDEFINED is
never collapsed. Binary nodes compute bit for bit as before.

Three trees in one repo:

| Layer | Path | Role |
|---|---|---|
| **Database** | `dagdb/` | 6-bounded ranked DAG store: library, `dagdb-cli`, `dagdb-daemon`, Python biology and Loom plug-ins, MCP server, PostgreSQL extension, sample graphs. All active development lives here. |
| **Runtime** | `Sources/` + `Package.swift` at repo root | 4-cycle optimiser-executor (paper 4 scaffold). Independent build. Uses a DagDB substrate as its computation graph. |
| **Site** | `site/` | Slide decks, podcasts, HTML demos. Folded in from the former `norayr-m/DagDB` repo on 2026-04-22; see [`site/README.md`](site/README.md). GitHub Pages publishes this subtree. |

Between 2026-04-19 and 2026-04-21 the database layer was extended
with a rank-widening + MVCC + secondary-index pass — u32→u64 rank,
WAL, snapshot-on-read, ancestry and similarity primitives. Summer
2026 added a parallel `Float32` weight/value lane beside the
truth-table record (snapshot v6, new WAL opcodes) and seven twin
primitives — deterministic replayable streams, a sealed knapsack
allocator, a cross-ear identity check, a geared recording odometer, a
rational-gear master clock — and, since 2026-09-10, a waveform bank
(generate = one matrix product, residual and rank printed), derived
views over a sealed alarm-set record (reflex, energy rung, geometry
ceiling) reproduced exactly against the twin project's reference numbers,
and the exact tier ladder as a library and a daemon verb (fold API),
and an attention hook that spends the sealed budget frame by frame on
the engine's clock. Since the interface phase (merged 2026-09-06) those seven
primitives, plus a sealed alarm-stream type, are reachable over the
daemon socket (DSL) and MCP, not just in-process (`ARCHITECTURE.md`
§13), per-path kernels with the sealed cross-convolution residual
(the old patrol check is deprecated); since 2026-09-09 the daemon can
reload its last snapshot at startup (`DAGDB_STARTUP_LOAD`); and since
2026-09-10, tiling step one splits a graph into on-disk tile files
with a load/evict router answering cross-tile BFS/ancestry/select
exactly like the single engine (`SAVE TILED`, `TILED
OPEN/BFS/SELECT/STATUS/LIST/CLOSE` — deliberately not a twin verb
family), and step two ticks that tiled graph durably across world
ticks with crash recovery and partial-round completion at open
(`TILED TICK`/`TILED GET`).

**Ship-storm 2026-04-21.** Six items landed on the engine in a single
day, all tests green:

- **u32 rank refactor** (2026-04-20) — address space 255 → 4.3 billion;
  snapshot format v2 (38 B/node).
- **u64 rank refactor** (2026-04-21) — address space 4.3 billion →
  1.8 × 10¹⁹; snapshot format v3 (42 B/node). Backward-compat load
  accepts v1 (u8) and v2 (u32) and widens on read.
- **`rankPolicy` Protocol + three defaults** —
  sequence-position / chain-band / topological-sort.
- **`SET_RANKS_BULK`** — shm-fed u64 vector rewrite (was
  u32 at landing; widened by the u64 rank refactor), bypasses per-edge validation.
  The frame now carries the header
  `[u32 nodeCount][u32 0x314D4801]` at bytes 0..7 (`docs/wiki/dsl.md`
  § Input frames).
- **MVCC snapshot-on-read** — `OPEN_READER` / `READER id …`
  sessions memcpy a stable engine copy; writers unblocked.
- **`bfsDepths` primitive + `BFS_DEPTHS FROM <seed>` DSL** —
  undirected and backward.
- **Loom Pass 1 complete** — 694 events ingested end-to-end on the
  004 / u32 daemon, nodes 0–693, ~140 ms aggregate, ~4.6–5.2 k
  events/sec. Adapter conforms to the Protocol. Dual-write through
  `capture_latest` is live.

**Tests.** 1,540 Swift tests, 0 failures, 49 skipped (DagDBTests 722 +
DagDBDaemonKitTests 818), in one full `swift test` run from `dagdb/` on a clean
export of this tree, 2026-11-24 (about 78 minutes on an M5 Max); 48 of the skips are tests gated on the
out-of-repo sealed fixtures (see Development below) and one is an opt-in test.
The top-level runtime package's one test passes. Python, the same run: the
Loom adapter's 16 tests and the browser bridge's 10 (`python3 -m pytest plugins web`
from `dagdb/`), 26 passed. See [`CURRENT_STATE.md`](CURRENT_STATE.md) for
the live picture.

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

Roadmap: [`ROADMAP.md`](ROADMAP.md) · Plan: [`PROJECT_PLAN.md`](PROJECT_PLAN.md)
· Capabilities: [`CAPABILITIES.md`](CAPABILITIES.md) · Demo:
[`examples/twin_primitives/`](examples/twin_primitives/)

---

## Quick start — database

```
cd dagdb
swift build -c release
```

Start the daemon (listens on `/tmp/dagdb.sock`, grid 1024 ≈ 1 M nodes). `--shm-file` is required
(the result-row file query results land in; there is no default, so they never land in `/tmp` by
accident); unknown flags, unparsable numbers and numbers out of range are refused with the usage line.
The ranges: `--grid n`, 1 to 32768 (the grid is n × n; the Morton axes bound it); `--max-rank n`, 1 to
max(16, n²) for the grid's n (no node of an N-node graph holds a rank of N or more); `--mem-budget-gb G`,
2^-30 ≤ G < 2^33 (the budget in bytes, ⌊G × 2^30⌋, must be at least 1 and below 2^63):

```
mkdir -p ~/.dagdb
.build/release/dagdb-daemon --grid 1024 --socket /tmp/dagdb.sock --shm-file ~/.dagdb/dagdb_shm
```

Durability envs (point these inside `~/dag_databases/`):

```
DAGDB_DATA_ROOT=$HOME/dag_databases \
DAGDB_WAL=$HOME/dag_databases/live.wal \
DAGDB_AUTOSAVE=$HOME/dag_databases/auto.dags \
DAGDB_STARTUP_LOAD=$HOME/dag_databases/auto.dags \
  .build/release/dagdb-daemon --grid 1024 --shm-file $HOME/dag_databases/dagdb_shm
```

Every file the daemon opens, read or write, must lie inside `DAGDB_DATA_ROOT` (the WAL and the
autosave included: a path outside it refuses the start), must be a regular file, and is read once;
anything else is refused by name.

**Memory budget.** The daemon refuses, by name and
before allocating, any command whose bytes would take its physical
footprint past its budget, or whose work would pass a per-command cap of
about 60 s (`ERROR out_of_budget: …; nothing written`). The claim: a
command is admitted only if its work, at the slowest rate measured on
sequential, strided and random access, fits in 60 s. Memory is bounded for
the writes, loads, ticks and first-use allocations named here, and for the
read verbs: GRAPH INFO, NODES, TRAVERSE, ANCESTRY, SIMILAR_DECISIONS,
DISTANCE, EVAL's reads, VALIDATE, SAVE JSON / CSV / TILED and the BACKUP
verbs, in the primary and in reader sessions, are each admitted before
they run, at a charge measured at grids up to 2048 + 10 % (where the
measurement was masked by the boot's own peak, as for VALIDATE's check,
the charge comes from the code's allocations; the charges were
re-measured by an independent verifier). The Metal pool is a fixed
reservation in the fixed state (see "The Metal pool" below). Where the
bound is weaker, it says so: the tiled read verbs (TILED BFS, SELECT, GET,
STATUS, LIST) are bounded by their router's admitted residency and were
measured only at grid 256; several read charges are worst-case per node
(ANCESTRY, SIMILAR_DECISIONS, SAVE JSON …), so a daemon near its budget
can refuse them on a small result. Time is a bound on the patterns measured, on the M5's performance
cores: under background QoS (`taskpolicy -c background`, efficiency
cores) a command can take about 2x its admitted time. The daemon's boot
log and `start_sandbox.sh` state the QoS it runs at; the bounds were measured
at user-interactive QoS (a daemon started from a shell), with the machine at
the load it carries in use: measured at 1-minute load average 3.0–4.4.
The default
budget is min(max(8 GiB, 2 × fixed state), 32 GiB), with the fixed state
191 B per node + 2.55 MB; `--mem-budget-gb <G>` (GiB) overrides it, and
then STATUS ends with ` mem_budget_gb=<G>`. **Launch the daemon with
`MallocLargeCache=0` in its environment** (`scripts/start_sandbox.sh`
does): the budget reads the process's phys_footprint, which otherwise
keeps counting the large blocks malloc frees and caches, so the memory
of a big command is not given back between commands. A launchd plist
sets it under `EnvironmentVariables`.

**What accumulates is admitted too.** Every command
that creates a resident object (a twin OPEN or LOAD, CONNECT BACK and
CONNECT_BACK_BULK, TILED OPEN, OPEN_READER) is admitted at creation
against max(footprint, fixed state + committed bytes): the committed
bytes are the sum of every live object's admitted size (its measured
factor + 10 %), so an object the footprint under-counts is still
counted, and a close gives its bytes back. TILED TICK admits its
preflight (every tile at once), CLOCK ADVANCE its work over its gears
and bound hooks. Count caps: 1,024 of each twin kind, 4,096 slices on a
record, 16 tiled routers, 64 reader sessions; back edges are bounded
by bytes only. TILED OPEN reads `manifest.json` once, only as a regular file
(anything else is refused as "tile manifest not found"); it admits the read
and the decode from the file's bytes and its `, : [ {` count, and the router
from every field of the decoded manifest.

**The Metal pool: a fixed reservation.** The first GPU
command of a burst (TICK, TILED TICK and the like) brings in a Metal
allocation pool, 112.25 MiB on this machine (M5 Max) at every grid and
on every GPU verb; it drains about 1.5 s after the burst. The daemon
reserves 1.1 x that, 129,472,922 B, in its fixed state at boot (the boot
line states it), so a budget that cannot hold the fixed state with the
reservation refuses the start by name with the size to pass. When the pool
is not resident, a GPU verb's footprint check holds the reservation's room.
On another machine the daemon measures its pool whenever an engine (the
primary or a tile engine) makes its first command buffer; a larger
pool raises the reservation (logged), and if the budget cannot hold the
raised reservation, GPU verbs are refused by name. The tick verbs'
transients, the first-use allocations (the ternary lanes, the rank table,
SELECT's index, BFS_DEPTHS, the first ticks' buffers), BACKUP RESTORE and
SAVE's body are admitted at their measured factors; STATUS never
allocates. Names stored in twin state are capped at 16,384 bytes on the
live verbs (an older over-long name loads and is named).

`DAGDB_DATA_ROOT` is the single persistent-DB root; any `SAVE`/
`LOAD`/`BACKUP` path outside it is rejected with
`ERROR io: path: "<p>" outside DAGDB_DATA_ROOT`. On the author's
machine a per-user launchd agent plist (local, not in this repository)
wires all three envs automatically.

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
# Write the header [u32 N][u32 0x314D4801] (SET_RANKS_BULK's code 1)
# at shm bytes 0..7 and `ranks` at shm offset 8, then call
# SET_RANKS_BULK — or use per-node SET <id> RANK <r> calls if you prefer.
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

Ingest context lives at `<workspace>/dagdb_ingest_ctx.json` by
convention. See `dagdb/plugins/loom/backfill.py` for the one-shot
JSONL → DagDB ingester used for historical loads.

---

## Features

Authoritative ledger: `dashboard/features.yaml`. At a glance:

### Core engine
- 6-bounded ranked DAG, 64-bit rank (u8 → u32 on 2026-04-20,
  then u32 → u64 on 2026-04-21; address space now 1.8 × 10¹⁹).
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
- **Python MCP server** (`dagdb/mcp_server.py`) — 116 tools on
  `http://localhost:8787/dagdb/…` via `mcpo`.
- **PostgreSQL extension** (`dagdb/pg_dagdb/`).
- **Browser bridge** (`dagdb/web/bridge.py`).
- **Plugins**:
  - `dagdb/plugins/biology/rank_policies.py` — `RankPolicy` Protocol
    + three defaults (sequence-position / chain-band /
    topological-sort).
  - `dagdb/plugins/loom/` — event-log adapter (`adapter.py`,
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

Newer classes exist beside these: `out_of_budget`, `stale_frame`,
`control_character`, `gpu`, `invalid_graph`, `resource` and `shutdown`.
The text after the prefix quotes and escapes any client or file text,
so match on the class word, not on the wording; the release entry at
the top of `CHANGES.md` gives the reply rules.

---

## Repository layout

```
.
├── README.md                       you are here
├── ARCHITECTURE.md                 module map, data model, invariants
├── CHANGES.md                      session-by-session log
├── CONTRIBUTING.md                 short contributor note
├── LICENSE                         Apache-2.0
├── Package.swift                   runtime build (4-cycle engine)
├── Sources/DagDBEngine/            4-cycle runtime engine + shader
├── Sources/DagDBCLI/               engine CLI
├── tests/                          runtime test scaffold (Python)
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
    ├── Tests/                      1,540 tests in two targets (49 skip
    │                                without the sealed fixtures and an opt-in; see below)
    ├── mcp_server.py               Python MCP server (116 tools)
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

Full grammar in `dagdb/Sources/DagDBDaemonKit/DSLParser.swift`.

```
# Lifecycle
STATUS
TICK <n>
EVAL [WHERE <field><op><value>]          # rank-0 roots; a RANK clause is refused
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
SET_RANKS_BULK          # reads [u32 N][u32 0x314D4801] at 0..7, u64 vector at shm offset 8

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

# BFS and ancestry queries
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
server: 116 tools, among them `dagdb_query`, which sends any DSL command
above. `mcpo` bridges them to HTTP on port 8787:

```
http://localhost:8787/dagdb/<tool_name>
http://localhost:8787/dagdb/openapi.json       # tool catalog
```

Launched via `~/Library/LaunchAgents/com.dagdb.mcpo.plist` (local,
not in repo). The daemon itself is supervised by a second per-user
launchd agent plist (local, not in this repository) that points at
`dagdb/.build/release/dagdb-daemon --grid 1024 --shm-file <path>` (`--shm-file` is required).

---

## Development

```
cd dagdb
swift test                                      # 1,540 tests, 0 failures;
                                                # 49 skip (48 unless the sealed
                                                # fixtures are present, below);
                                                # DagDBTests in one process
                                                # peaks above 7 GB
python3 plugins/biology/rank_policies.py        # self-test
python3 -m pytest plugins/loom/test_adapter.py -q   # 16 tests (2026-11-19)
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

Apache-2.0. See `LICENSE`.

## Humble disclaimer

Amateur engineering project. Research prototype. Errors likely.
Numbers speak. No competitive claims.
