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
