# DagDB — LLM reference

A single dense page written for a language model that needs to
operate DagDB correctly without reading the source. Everything an
agent needs to form valid commands, parse results, and avoid the
known footguns. If something here conflicts with
[`CURRENT_STATE.md`](../../CURRENT_STATE.md), trust that file — it
is the canonical disambiguator.

> Amateur engineering project. No competitive claims. Errors
> likely. Verify against source before relying on anything
> safety-relevant.

Last refreshed: 2026-05-18 (Fable review pass).

---

## 1. What DagDB is, precisely

A database where every record is a node in a **6-bounded ranked
directed acyclic graph**, and every node is a **64-bit lookup
table (LUT6)** — a programmable Boolean function of up to six
inputs. The graph is evaluated on the GPU, rank layer by rank
layer, in parallel. State persists like a database: snapshots,
write-ahead log, multi-version reads.

The five load-bearing facts:

1. **Every node has at most 6 directed inputs.** Hard limit from
   the hex-grid substrate. Wider fan-in is built with reduction
   trees.
2. **Every edge goes from higher rank to lower rank**:
   `rank(src) > rank(dst)`. This makes the graph acyclic by
   construction and gives the rank-layered evaluation order.
3. **Rank is u64** (0 = root, larger = leaf-ward). Widened from
   u8→u32→u64 across 2026-04. Max `2^64 − 1`.
4. **Truth is ternary**: 0 = false, 1 = true, 2 = undefined
   (the "paradox horizon"). The tick kernel treats undefined as 0
   when feeding it as a LUT input.
5. **Recurrence is a separate edge type** — the BACK_EDGE — that
   latches `truth[src]` into `truth[dst]` at the tick boundary,
   exempt from the rank invariant. This is how feedback, counters,
   filters, and cellular automata are built without breaking
   acyclicity.

Mental model: a software, mutable, queryable FPGA.

---

## 2. How to talk to it

A daemon listens on a Unix socket (default `/tmp/dagdb.sock`, or
`/tmp/dagdb-<env>.sock` when `DAGDB_ENV` ∈ {dev,test,prod}). You
send one DSL command as text, the daemon replies with one text
line beginning `OK ` or `ERROR `. Bulk results land in a shared
memory file, not the socket.

Three ways in:

- **Direct socket**: `echo "STATUS" | nc -U /tmp/dagdb.sock`
- **MCP** (for agents): `http://localhost:8787/dagdb/<tool>` —
  the bridge wraps each DSL verb as a tool. The catalog is at
  `/dagdb/openapi.json`. The generic escape hatch is
  `dagdb_query` with `{"command": "<DSL>"}`.
- **WebSocket bridge** (browser): see the security note in §8 —
  do not expose this externally.

One command per connection. The daemon does a single read of up
to ~4 KB; keep commands under that.

---

## 3. The complete DSL surface

Authoritative grammar lives in
`dagdb/Sources/DagDBDaemon/DSLParser.swift`. Verbs grouped by
function:

**Lifecycle / inspection**
- `STATUS` → `OK STATUS nodes=… ticks=… gpu=… grid=…x… maxRank=…`
- `TICK <n>` — run n evaluation ticks
- `GRAPH INFO` — node/true/per-rank counts
- `VALIDATE` — check every edge for rank ordering, bounds, no
  self-loops, no duplicates

**Read**
- `NODES [AT RANK <n>] [WHERE <field><op><value>]` — list nodes;
  results to shm
- `GET <node> TRUTH` — single node truth, returned inline on the
  socket (no shm needed)
- `EVAL [WHERE <pred>] [RANK <lo> TO <hi>]` — tick then return
  roots
- `TRAVERSE FROM <node> DEPTH <n>` — walk n ranks from a node
- `BFS_DEPTHS FROM <seed> [BACKWARD]` — depth vector to shm
- `ANCESTRY FROM <node> DEPTH <d>` — reverse BFS, bounded
- `SIMILAR_DECISIONS TO <node> DEPTH <d> K <k> [AMONG TRUTH <t>]`
  — top-k by Weisfeiler-Lehman-1 distance on local subgraphs
- `SELECT truth <k> rank <lo>-<hi>` — secondary-index fast path
- `DISTANCE <metric> <loA>-<hiA> <loB>-<hiB>` — subgraph distance

**Mutate**
- `SET <node> TRUTH <0|1|2>`
- `SET <node> RANK <u64>`
- `SET <node> LUT <PRESET>` — preset ∈ AND, OR, XOR, MAJ,
  IDENTITY, CONST0, CONST1, VETO, NOR, NAND, AND3, OR3, MAJ3
- `CONNECT FROM <src> TO <dst>` — combinational edge; rejected if
  it would violate `rank(src) > rank(dst)` or exceed 6 inputs
- `CONNECT BACK FROM <src> TO <dst>` — BACK_EDGE; dst must have
  zero combinational fan-in
- `CLEAR <node> EDGES` — remove combinational inputs
- `CLEAR <node> BACK_EDGES` — remove incoming back-edges
- `COMPOSE <NOT|AND|OR|XOR> <src1> [<src2>] INTO <dst>` — bitwise
  LUT composition into dst's LUT

**Bulk install** (the fast compile path — see §6)
- `SET_RANKS_BULK` — reads `u64[nodeCount]` from shm offset 8
- `SET_LUTS_BULK` — reads `u64[nodeCount]` from shm offset 8
- `SET_NEIGHBORS_BULK` — reads `int32[nodeCount*6]` from shm
  offset 8

**Persistence**
- `SAVE <path> [COMPRESSED]`, `LOAD <path>`
- `SAVE JSON <path>`, `LOAD JSON <path>`
- `SAVE CSV <dir>`, `LOAD CSV <dir>`
- `EXPORT MORTON <dir>`, `IMPORT MORTON <dir>` — raw per-buffer
  files
- `BACKUP INIT|APPEND|RESTORE|COMPACT|INFO <dir>` — base+diff
  chain

**MVCC reader sessions**
- `OPEN_READER` → `OK OPEN_READER id=r…`
- `READER <id> <inner read-only command>`
- `CLOSE_READER <id>`, `LIST_READERS`

Distance metrics (eight): `jaccardNodes`, `jaccardEdges`,
`rankL1`, `rankL2`, `typeL1`, `boundedGED`, `wlL1`, `spectralL2`.

Predicate fields: `truth`, `rank`, `type`. Operators: standard
comparisons.

---

## 4. Result format (shared memory)

Bulk read verbs (NODES, EVAL, TRAVERSE, etc.) write rows to the
shm file `/tmp/dagdb_shm_file`:

```
bytes 0..3   : row count (u32)
bytes 4..7   : row size  (u32, currently 24)
bytes 8..    : rows
```

Each row is **24 bytes** (post 2026-04-21 widening):

```
u64 node_id | u64 rank | u8 truth | u8 type | 6 bytes pad
```

To parse N rows in Python: read the u32 count at offset 0, then
`numpy.frombuffer(buf[8:8+count*24], dtype=…)` with a matching
struct. **Do not assume 12-byte rows** — that was the pre-widen
format and is the most common stale-client bug.

`SELECT` and `BFS_DEPTHS` write `int32` payloads to shm offset 8
instead of the 24-byte row format — check the verb's reply line
for the byte count.

---

## 5. The evaluation model

One `TICK` does leaves-up rank propagation: iterate rank from
`maxRank-1` down to 0; at each rank, all nodes evaluate in
parallel across 7 colour groups (the hex 7-colouring guarantees
no two adjacent nodes share a group, so the parallel update is
race-free). Each node reads its ≤6 neighbours' truth values,
packs them into a 6-bit index, and looks up its LUT6.

After the combinational pass, the **latch phase** runs: every
BACK_EDGE's source truth is snapshotted, then written to every
destination — two-phase, so chained registers latch from pre-tick
state. Register nodes are skipped by the combinational kernel
(their value comes only from the latch).

Consequence for callers: to build a counter or filter, wire the
combinational logic with `CONNECT` and close the time loop with
`CONNECT BACK`. One tick = one combinational settle + one latch.

---

## 6. Compiling large structures fast

The bulk verbs exist so a compiler can install a million-node
graph in **three shm writes + three verbs** instead of millions
of single `SET`/`CONNECT` round-trips. The pipeline:

1. Build three arrays in memory: `ranks: uint64[N]`,
   `luts: uint64[N]`, `neighbours: int32[N*6]` (−1 = empty slot).
2. mmap `/tmp/dagdb_shm_file`, write `ranks` to offset 8, call
   `SET_RANKS_BULK`. Repeat for luts and neighbours.
3. Add back-edges with individual `CONNECT BACK` calls (few
   relative to combinational edges).
4. `VALIDATE` after the first build of a new compiler (bulk verbs
   skip the rank-invariant check for speed).
5. `SAVE` if you need durability (bulk verbs skip the WAL).

Full recipe with rank-depth budgeting and LUT input packing:
[`microcircuit-compilation.md`](microcircuit-compilation.md).

**Known doc bug (2026-05-18):** the `dagdb_set_ranks_bulk` MCP
docstring currently says "u32 vector" — that is wrong, the daemon
reads u64. Write `numpy.uint64`. Tracked in
[`../REVIEW_FABLE_2026-05-18.md`](../REVIEW_FABLE_2026-05-18.md)
finding P1.

---

## 7. Persistence formats

**Snapshot (`.dags`)**: 32-byte header (magic `DAGS`, version,
nodeCount, gridW, gridH, tickCount, flags, bodySize) + body (six
buffers concatenated, optionally zlib) + optional trailers. Body
is **42 bytes/node** from v3 on (`34 + 8` for u64 rank). Versions:
v1 (u8 rank), v2 (u32), v3 (u64), v4 (+back-edge trailer), v5
(+env-origin trailer). Load reads all five and widens on read;
save always writes v5. Atomic: tmp → FULLFSYNC → rename → dir
fsync.

**WAL (`DAGW`)**: append-only mutation log, length-prefixed
records, fsync per record before the engine buffer is touched.
Replay skips records at/before the last CHECKPOINT.

**Env stamping**: v5 snapshots carry an env code (unspecified /
dev / test / prod). A load is rejected if both daemon and file
have a real env and they disagree — the dev/test/prod wall.
`unspecified` on either side passes (legacy compatibility).

Persistent state lives under `~/dag_databases/<env>/`. The daemon
enforces this via `DAGDB_DATA_ROOT`; out-of-root SAVE/LOAD is
rejected when env is set.

---

## 8. Footguns and current known issues

Operating cautions an LLM should respect:

- **Bulk verbs skip validation.** After `SET_NEIGHBORS_BULK` or
  `SET_RANKS_BULK`, run `VALIDATE` if you don't fully trust the
  data — they can create rank-invariant violations the engine
  won't catch until you check.
- **Reader sessions and ranks (live bug, 2026-05-18):** the
  shipped reader-session snapshot copies only half each node's
  rank. Until the one-line fix lands, **do not trust rank values
  from `READER <id> NODES …` for nodes in the upper half of the
  graph.** Tracked as finding C1 in the Fable review. Reads of
  truth, type, and LUT through a reader session are fine; only
  rank is affected.
- **Don't experiment on the prod store.** Spin a dev daemon:
  `DAGDB_ENV=dev DAGDB_DATA_ROOT=~/dag_databases/dev dagdb-daemon
  --grid 64`. Socket auto-derives to `/tmp/dagdb-dev.sock`.
- **The browser bridge is unauthenticated full-write.** Never
  expose `web/bridge.py` beyond localhost; any page's JavaScript
  could mutate the graph. Tracked as finding S1.
- **MCP "alive" ≠ daemon alive.** Verify with a socket `STATUS`,
  not just an MCP ping.
- **A truncated `.dags` file currently crashes the daemon on
  load** rather than throwing (finding H2). Don't `LOAD` a file
  you suspect was half-written; restore from WAL or a known-good
  snapshot.

---

## 9. Worked example — an AND gate, end to end

```
SET 1 RANK 1        # input node 1 at rank 1
SET 2 RANK 1        # input node 2 at rank 1
SET 0 RANK 0        # output node 0 at rank 0 (root)
SET 0 LUT AND       # node 0 computes AND of its inputs
CONNECT FROM 1 TO 0 # wire input 1 into node 0 (rank 1 > rank 0 ✓)
CONNECT FROM 2 TO 0
SET 1 TRUTH 1
SET 2 TRUTH 1
TICK 1
GET 0 TRUTH         # → OK GET node=0 truth=1
```

Three nodes, one tick, an AND gate runs. Scale this with the bulk
verbs (§6) to a million nodes.

---

## 10. Where to read more

- [`Home.md`](Home.md) — friendly first-time intro
- [`dsl.md`](dsl.md) — full verb-by-verb grammar
- [`back-edges.md`](back-edges.md) — recurrence primitive
- [`microcircuit-compilation.md`](microcircuit-compilation.md) —
  compiling continuous functions at substrate throughput
- [`mvcc.md`](mvcc.md) — reader sessions
- [`data-and-persistence.md`](data-and-persistence.md) — every
  byte's home on disk
- [`invariants.md`](invariants.md) — what the engine enforces
- [`../REVIEW_FABLE_2026-05-18.md`](../REVIEW_FABLE_2026-05-18.md)
  — current known bugs and fix order
- [`../../CURRENT_STATE.md`](../../CURRENT_STATE.md) — canonical
  live-state pointer

— amateur engineering; errors likely.
