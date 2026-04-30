# DSL reference

Every verb the daemon's DSL parser recognizes. Source of truth:
[`dagdb/Sources/DagDBDaemon/DSLParser.swift`](../../dagdb/Sources/DagDBDaemon/DSLParser.swift).

Commands are newline-delimited text on `/tmp/dagdb.sock`. Every
response is either `OK …` or `ERROR <category>: <detail>` (see
[`invariants.md`](invariants.md) for categories).

---

## Lifecycle

```
STATUS
  → OK STATUS nodes=<N> ticks=<k> gpu=<model> grid=<W>x<H> maxRank=<M>

TICK <n>
  → OK TICK <n> elapsed=<ms>ms total=<tickCount>

EVAL [WHERE <field><op><value>] [RANK <lo> TO <hi>]
  → writes matching roots to shm, OK EVAL rows=<k> tick=<t>

VALIDATE
  → OK VALIDATE  |  FAIL VALIDATE <first-violation>
```

`<field>` ∈ `truth`, `state` (alias for `truth`), `rank`, `type`.
`<op>` ∈ `=`, `!=`, `<`, `>`, `<=`, `>=`. One clause per WHERE.

---

## Read

```
NODES [AT RANK <n>] [WHERE <field><op><value>]
  → writes rows (node, rank, truth, type) to shm

TRAVERSE FROM <node> DEPTH <n>
  → writes rows (node, rank, truth, type) to shm

GRAPH INFO
  → OK GRAPH nodes=<N> true=<k> r0=<n> r1=<n> …
```

---

## Mutate

Every mutation that changes a node's `(truth, rank)` flips the
secondary-index dirty flag. WAL (if enabled) appends the record
before the buffer is touched.

```
SET <node> TRUTH <0|1|2>
SET <node> RANK  <u32>
SET <node> LUT   <PRESET>
SET <node> LUT   0x<hex>          # 16-digit raw 64-bit LUT integer

CONNECT FROM <src> TO <dst>
CLEAR   <node> EDGES

SET_RANKS_BULK
  # Caller writes a u64 rank vector of length nodeCount to shm at
  # offset 8 BEFORE calling this. Daemon memcpys into rankBuf in
  # one round-trip. No per-insert validation — run VALIDATE after
  # if paranoid.
```

LUT presets: `AND`, `OR`, `XOR`, `MAJ` (MAJORITY6), `IDENTITY`,
`CONST0`, `CONST1`, `VETO`, `NOR`, `NAND`, `AND3`, `OR3`, `MAJ3`.
The `0x<hex>` form takes any 16-digit hex literal and stores it
as the raw 64-bit LUT — useful for fan-in 4 and fan-in 6 functions
that have no preset.

### Bitwise LUT composition

Compose source LUTs into a destination LUT in a single bitwise
operation. Foundation for graph-simplification passes (collapse a
fused subtree into one node), policy composition ("fires when all
of {a, b, c} agree"), and any case where you'd otherwise evaluate
a tree of intermediate nodes per tick.

```
COMPOSE AND <src1> <src2> INTO <dst>     # dst.LUT = src1.LUT & src2.LUT
COMPOSE OR  <src1> <src2> INTO <dst>     # dst.LUT = src1.LUT | src2.LUT
COMPOSE XOR <src1> <src2> INTO <dst>     # dst.LUT = src1.LUT ^ src2.LUT
COMPOSE NOT <src>         INTO <dst>     # dst.LUT = ~src.LUT
```

Caller is responsible for the assumption that sources and
destination share a common input vector — the engine performs the
bitwise op directly on the 64-bit LUT integers, no input
remapping. WAL-logs the equivalent `SET_LUT` if enabled. Returns
`OK COMPOSE op=<OP> src1=<i> src2=<j|—> dst=<k> lut=0x<hex>`.
Rejected inside reader sessions (mutates the LUT buffer).

---

## Read (single value)

```
GET <node> TRUTH
  → OK GET node=<node> truth=<v>
```

Cheap socket-only readback for clients without shared-memory access.
`<v>` is the UInt8 truth value (0 = false, 1 = true, 2 = undefined).
One round-trip per node; for bulk reads use `NODES` or `EVAL`.

---

## Back edges — register state across tick boundaries

A second edge type. Combinational `CONNECT` edges feed the rank-pass
truth evaluation in a single tick. Back edges latch `truth[src]` into
`truth[dst]` *between* ticks, after the combinational pass settles.
Synchronous-circuit register pattern on a graph database — unlocks
in-substrate iteration to convergence: belief propagation, AC-3 style
constraint propagation, Hopfield associative recall, Boolean networks
with feedback.

```
CONNECT BACK FROM <src> TO <dst>
  → OK CONNECT BACK from=<src> to=<dst>

CLEAR <node> BACK_EDGES
  → OK CLEAR node=<node> back_edges removed=<removed>
```

Two-phase CPU latch on the `truthState` buffer: snapshot every
back-edge src first, then write every back-edge dst. Ordered after
the combinational rank pass within a single `TICK`. Chained
back-edges (one entry's dst is another entry's src) latch from
pre-tick state, never from values written earlier in the same latch
pass.

Validation rules (engine rejects with `ERROR schema:
back_edge_violation: …` if violated):

- `CONNECT BACK` destination must have **zero combinational fan-in**
  — `CONNECT FROM x TO dst` and `CONNECT BACK FROM y TO dst` cannot
  coexist on the same `dst`.
- `CONNECT FROM` destination must not already be a back-edge
  destination — symmetric of the rule above.

`CLEAR <node> BACK_EDGES` is the mirror of `CLEAR <node> EDGES`. The
combinational variant clears edges *into* `node`; the back-edge
variant clears back edges *into* `node` and clears the register flag.
Both reject inside reader sessions (writes on a session always do).

WAL opcodes: `CONNECT_BACK` (`0x10`, payload u32 src + u32 dst),
`CLEAR_BACK_EDGES` (`0x11`, payload u32 dst). Snapshot format `v4`
appends a back-edge trailer (u32 count + entries); `v3` files load
with an empty back-edge list (forward migration). `v4` always writes.

Reference demos in `examples/ac3_australia/`: 1-bit toggle (6 ticks,
register flips 0/1/0/1/0/1), 4-bit ripple counter (17 ticks,
0 → 15 → 0 wrap), and AC-3 Australia 3-coloring with WA pre-assigned
red — converges in 2 synchronous ticks, per-tick equality with the
pure-Python `reference_ac3.py`. See [`back-edges.md`](back-edges.md)
for the full feature page.

---

## Persistence — binary `.dags`

```
SAVE <path> [COMPRESSED]
  → OK SAVE bytes=<b> elapsed=<ms>ms ratio=<pct>% path=<p>

LOAD <path>
  → OK LOAD bytes=<b> nodes=<N> ticks=<t>

EXPORT MORTON <dir>
  → writes six raw-buffer files; OK EXPORT bytes=<b> dir=<d>

IMPORT MORTON <dir>
  → reads six raw-buffer files, validates, commits
```

Atomic save discipline: tmp → `F_FULLFSYNC` → `replaceItemAt` → dir
fsync. A kill -9 at any point leaves either pre-save state or the
complete new file, never a truncation.

v1 (u8 rank), v2 (u32 rank), and v3 (u64 rank) snapshot formats all load; save
always writes v2.

---

## JSON / CSV

```
SAVE JSON <path>
LOAD JSON <path>
  # dagdb-json v1 — mirrors the six engine buffers

SAVE CSV <dir>
LOAD CSV <dir>
  # two files: <dir>/nodes.csv + <dir>/edges.csv
```

Same atomic-save discipline. Pre-commit rank validation blocks
tampered files from reaching live buffers.

---

## Backup chain

```
BACKUP INIT    <dir>       # wipe + write base.dags
BACKUP APPEND  <dir>       # write NNNNN.diff vs current tip
BACKUP RESTORE <dir>       # replay base + all diffs
BACKUP COMPACT <dir>       # restore → new base → drop diffs
BACKUP INFO    <dir>       # base presence, diff count, sizes
```

XOR diffs per engine buffer, zlib-compressed per segment. Single-bit
mutations typically produce diffs under 5 % of raw snapshot size.

---

## Secondary index

```
SELECT truth <k> rank <lo>-<hi>
  → matching node IDs written to shm as Int32[],
    OK SELECT truth=<k> rank=<lo>-<hi> matches=<k> shm_bytes=<b>
```

Lazy rebuild on the first `SELECT` after any mutation that changes
`(truth, rank)`. O(log N + matches) lookup.

---

## BFS

```
BFS_DEPTHS FROM <seed>                  # undirected (inputs ∪ fanout)
BFS_DEPTHS FROM <seed> BACKWARD         # inputs only
  → writes Int32[nodeCount] to shm; depth[i] = -1 if unreachable
```

---

## Partition queries

```
ANCESTRY FROM <node> DEPTH <d>
  → reverse BFS bounded by depth; writes (Int32 node, Int32 depth)
    pairs to shm

SIMILAR_DECISIONS TO <node> DEPTH <d> K <k> [AMONG TRUTH <t>]
  → WL-1 histogram L1 distance on each candidate's local ancestral
    subgraph; returns top-K as (Int32 node, Float32 distance)
```

---

## Subgraph distances

```
DISTANCE <metric> <loA>-<hiA> <loB>-<hiB>
  → OK DISTANCE <metric> value=<v> |A|=<nA> |B|=<nB>
```

`<metric>` ∈ `jaccardNodes`, `jaccardEdges`, `rankL1`, `rankL2`,
`typeL1`, `boundedGED`, `wlL1`, `spectralL2`.

Subgraphs are defined by rank range `<lo>-<hi>` (inclusive).

---

## MVCC reader sessions

```
OPEN_READER
  → OK OPEN_READER id=<17-char-hex> tick=<t> open_sessions=<k>

CLOSE_READER <id>
  → OK CLOSE_READER id=<id>

LIST_READERS
  → OK LIST_READERS open_sessions=<k> <id1>@tick=<t> <id2>@tick=<t>

READER <id> <inner read-only command>
  → dispatches <inner> against the session's snapshot engine
```

Allowed inner commands: `STATUS`, `GRAPH INFO`, `NODES`, `TRAVERSE`,
`BFS_DEPTHS`, `DISTANCE`, `SELECT`, `ANCESTRY`, `VALIDATE`. Writes,
`EVAL`, nested `READER`, and `SIMILAR_DECISIONS` are rejected with
`ERROR forbidden:`.

---

## Error taxonomy

Every error response starts with `ERROR <category>: <detail>`. See
[`invariants.md`](invariants.md) for the full table.

Categories: `out_of_range`, `dsl_parse`, `unknown_command`,
`schema`, `io`, `wal`, `bfs`, `not_found`, `forbidden`.
