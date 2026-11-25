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

Last refreshed: 2026-05-18; the native ternary
tick (verbs, truth byte, result-row byte 18, formats) added 2026-10-10.

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
4. **Truth is one byte**: 0 = false, 1 = true, 2 = undefined
   (the "paradox horizon"); 3–255 are adapter event codes (Loom) on
   binary nodes. A BINARY node (the default) reads an input as the
   bit `byte == 1`, so undefined and event codes feed its LUT as 0,
   and it writes 0/1. A ternary-mode node (TTABLE or TTHRESH, see
   the Ternary verbs below) reads the byte as a trit — 0 → −1,
   1 → +1, 2 and ≥ 3 → 0, absent slot → 0 — and stores −1/0/+1 as
   0/2/1, so undefined survives the tick.
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
- `STATUS` → `OK STATUS nodes=… ticks=… gpu=… grid=…x… maxRank=… client_protocol=2`
  (the last token: input frames carry the header below; absent on older daemons)
- `TICK <n>` — run n evaluation ticks
- `GRAPH INFO` — node/true/per-rank counts, then
  `ternary_nodes=<t> trits=-:<a> 0:<b> +:<c>` (0s on a binary graph)
- `VALIDATE` — check every edge for rank ordering, bounds, no
  self-loops, no duplicates

**Read**
- `NODES [AT RANK <n>] [WHERE <field><op><value>]` — list nodes;
  results to shm
- `GET <node> TRUTH` — single node truth, returned inline on the
  socket (no shm needed)
- `EVAL [WHERE <pred>]` — tick then return the rank-0 roots (a
  RANK clause is refused by name: `ERROR dsl_parse:`; read other
  ranks with `NODES AT RANK <n>`)
- `TRAVERSE FROM <node> DEPTH <n>` — walk n ranks from a node
- `BFS_DEPTHS FROM <seed> [BACKWARD]` — depth vector to shm
- `ANCESTRY FROM <node> DEPTH <d>` — reverse BFS, bounded
- `SIMILAR_DECISIONS TO <node> DEPTH <d> K <k> [AMONG TRUTH <t>]`
  — top-k by Weisfeiler-Lehman-1 distance on local subgraphs
- `SELECT truth <k> rank <lo>-<hi>` — secondary-index fast path
- `DISTANCE <metric> <loA>-<hiA> <loB>-<hiB>` — subgraph distance

**Mutate**
- `SET <node> TRUTH <0|1|2>` — a binary node takes 0..255 (event
  codes); a ternary-mode node only 0..2
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
  LUT composition into dst's LUT; on TTABLE nodes, pointwise table
  composition (AND → min, OR → max, NOT → negation; XOR refused)

**Ternary** (every reply and
refusal in [`dsl.md`](dsl.md) § Ternary)
- `SET <node> MODE BINARY|TTABLE|TTHRESH [NOSKIP]` — mode byte: kind
  in bits 0–1 (0 BINARY, 1 TTABLE, 2 TTHRESH), NOSKIP bit 2; legal
  bytes 0, 1, 2, 5, 6. A register (BACK_EDGE destination) stays BINARY.
- `SET <node> TTABLE <tid>`, `SET <node> THRESH <lo> <hi>`
- `SET <node> TRIT -1|0|1`, `GET <node> TRIT` → `OK GET node=<n> trit=<t>`
- `TTABLE DEFINE <tid> <729 chars of - 0 +>`, `TTABLE PRESET <tid> <name> <k>`
  (TMIN TMAX TSUM TCONS TCONST-1 TCONST0 TCONST+1 for k = 1…6; TID TNEG
  for k = 1), `TTABLE GET <tid>`. The library is dense (ids 0 ..< size,
  at most 65,536); define id = size to append.
- Bulk: `SET_MODES_BULK` (u8[N]), `SET_TTABLE_IDS_BULK` (u16[N]),
  `SET_THRESH_BULK` (f32[2N], lo/hi pairs), `TTABLE_BULK <first> <count>`
  (u8[729·count]) — each a client frame: the header `[u32 N][u32 0x314D4804]`,
  `0x314D4805`, `0x314D4806` (count N, pairs for THRESH), or
  `[u32 count][u32 0x314D4807]` (tables) at shm bytes 0..7, the vector at
  offset 8, checked whole first (input frames, below).
- TTABLE: output = table[Σ 3^d·(t_d + 1)]. TTHRESH: s = Σ w_d·t_d in
  slot order (f32, the edge-weight lane); +1 if s > hi, −1 if s < lo,
  else 0. NOSKIP: a −1 ↔ +1 step writes 0 instead.
- A refused ternary write is `ERROR bad_value: ternary: <reason>` and
  changes nothing; binary nodes are unchanged bit for bit.

**Bulk install** (the fast compile path — see §6)
- `SET_RANKS_BULK` — header `[u32 nodeCount][u32 0x314D4801]` at shm
  bytes 0..7, then reads `u64[nodeCount]` from shm offset 8
- `SET_LUTS_BULK` — header `[u32 nodeCount][u32 0x314D4802]`, then reads
  `u64[nodeCount]` from shm offset 8
- `SET_NEIGHBORS_BULK` — header `[u32 nodeCount][u32 0x314D4803]` (the
  count is nodes), then reads `int32[nodeCount*6]` from shm
  offset 8

**Input frames** (client_protocol 2; the table in
[`dsl.md`](dsl.md) § Input frames). Every verb that reads input from
the shm reads only a frame its client wrote for it: `[u32 count][u32
0x314D4800 | code]` little-endian at bytes 0..7, the payload at offset
8. Codes: 1 `SET_RANKS_BULK`, 2 `SET_LUTS_BULK`, 3 `SET_NEIGHBORS_BULK`,
4 `SET_MODES_BULK`, 5 `SET_TTABLE_IDS_BULK`, 6 `SET_THRESH_BULK`,
7 `TTABLE_BULK`, 8 `CONNECT_BACK_BULK`, 9 `SET_TRUTH_BULK`, 10 `XCONV
CHECK`, 11 `XCONV SEALED`, 12 `BUDGET OPEN`, 13 `BANK GENERATE`, 14
`BANK FIT`; `count` in the verb's elements (nodeCount for the six lane
verbs, tables for `TTABLE_BULK`, rows for the two row verbs). A frame
without the header (a previous result, a never-written shm) or one
marked for another verb is refused as `ERROR stale_frame: …`, a wrong
count as `ERROR bad_value: <VERB> frame count …`; nothing is written.
Every command that writes the shm clears the mark, so write the header
with every new frame.

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

Bulk read verbs (NODES, EVAL, TRAVERSE) write rows to the result
file — the path given to the daemon's required `--shm-file` flag
(there is no default):

```
bytes 0..3   : row count (u32)
bytes 4..7   : row size  (u32, currently 24)
bytes 8..    : rows
```

Each row is **24 bytes** (post 2026-04-21 widening):

```
u64 node_id | u64 rank | u8 truth | u8 type | u8 mode | 5 bytes pad
```

Byte offsets: node 0–7, rank 8–15, truth 16, type 17, **mode 18**,
pad 19–23, written 0 on every row write. Byte 18 is the node's mode byte (since the ternary build):
bits 0–1 the kind (0 BINARY, 1 TTABLE, 2 TTHRESH), bit 2 NOSKIP. It
was pad (always 0) before; **the row size is still 24**, so a reader
that ignored the pad still reads correctly. The `truth` byte is the
stored byte — for a ternary node 0/1/2 mean −1/+1/0 as a trit.

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
race-free). Each BINARY node reads its ≤6 neighbours' truth values,
packs them into a 6-bit index, and looks up its LUT6. A TTABLE node
reads six trits and looks up its 729-entry table; a TTHRESH node sums
its weighted trits against two thresholds. One kernel per mode (rank,
sync) branches on the node's kind.

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
2. mmap the daemon's `--shm-file`, write the header `[u32 N][u32
   0x314D4801]` at bytes 0..7 and `ranks` at offset 8, call
   `SET_RANKS_BULK`. Repeat for luts (`0x314D4802`) and neighbours
   (`0x314D4803`, count N).
3. Add back-edges with individual `CONNECT BACK` calls (few
   relative to combinational edges).
4. `VALIDATE` after the first build of a new compiler (bulk verbs
   skip the rank-invariant check for speed).
5. `SAVE` for a snapshot. With a WAL on, the bulk verbs are logged
   too (opcodes 0x14–0x16; the ternary ones 0x47–0x4A), each as one
   record carrying its whole vector.

Full recipe with rank-depth budgeting and LUT input packing:
[`microcircuit-compilation.md`](microcircuit-compilation.md).

The `dagdb_set_ranks_bulk` MCP tool takes a u64 vector, as the daemon
reads it: write `numpy.uint64`.

---

## 7. Persistence formats

**Snapshot (`.dags`)**: 32-byte header (magic `DAGS`, version,
nodeCount, gridW, gridH, tickCount, flags, bodySize) + body (six
buffers concatenated, optionally zlib) + optional trailers. Body
is **42 bytes/node** from v3 on (`34 + 8` for u64 rank). Versions:
v1 (u8 rank), v2 (u32), v3 (u64), v4 (+back-edge trailer), v5
(+env-origin trailer), v6 (WGTS lanes), v7 (TWIN section), v8 (the
ternary build: **53 bytes/node** — mode, table id, two thresholds
after the v3 body — a u64 body length after the header with
bodySize@28 = 0xFFFFFFFF, and a TERN library section). Load reads all
eight and widens on read (v1–v7 load as binary graphs); save writes v7
for a graph with no ternary content (every mode, table id and
threshold bit pattern zero, empty library) and v8 otherwise, or when
the v7 body would not fit its u32 field. Atomic:
tmp → FULLFSYNC → rename → dir fsync.

**WAL (`DAGW`)**: append-only mutation log, length-prefixed
records, fsync per record before the engine buffer is touched.
Replay starts after the last SNAPSHOT_BIND record carrying the loaded
snapshot's digest (written before the snapshot's rename),
else after the last CHECKPOINT. Version 3 (the
ternary build) adds opcodes 0x40–0x4A; v1 and v2 logs still replay,
and a v2 log refuses a ternary op by name on append. A record is
written in chunks of at most 1 GiB per write(2), so a record of 2 GiB
or more (a 100M-node `SET_NEIGHBORS_BULK`) can be appended.

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
- **Don't experiment on the prod store.** Spin a dev daemon:
  `DAGDB_ENV=dev DAGDB_DATA_ROOT=~/dag_databases/dev dagdb-daemon
  --grid 64 --shm-file ~/dag_databases/dev/dagdb_shm` (`--shm-file` is
  required). Socket auto-derives to `/tmp/dagdb-dev.sock`.
- **The browser bridge is unauthenticated.** `web/bridge.py` binds
  localhost, admits only localhost origins and is read-only by
  default. `DAGDB_WS_ALLOW_WRITE=1` opens the full write surface to
  every admitted origin; set it only for a trusted local UI.
- **MCP "alive" ≠ daemon alive.** Verify with a socket `STATUS`,
  not just an MCP ping.
- **A truncated `.dags` file is refused on load** with
  `ERROR io: load: io: file truncated: expected <n> body bytes, …`;
  the daemon keeps running. Restore from WAL or a known-good
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
- [`../../CURRENT_STATE.md`](../../CURRENT_STATE.md) — canonical
  live-state pointer

