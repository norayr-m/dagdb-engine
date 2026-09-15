# DSL reference

Every verb the daemon's DSL parser recognizes. Source of truth:
[`dagdb/Sources/DagDBDaemon/DSLParser.swift`](../../dagdb/Sources/DagDBDaemon/DSLParser.swift).

Commands are newline-delimited text on `/tmp/dagdb.sock`. Every
response is either `OK …` or `ERROR <category>: <detail>` (see
[`invariants.md`](invariants.md) for categories).

**The frame.** A command is at most **4,095 bytes** followed by a
newline. The daemon reads until that newline, completing a short read
by reading again — AF_UNIX may split a write even well under the cap.
A line that reaches 4,095 bytes without a newline is answered

```
ERROR too_long: command exceeds 4095 bytes
```

and is **not parsed**. This matters for the verbs whose argument list
has no length of its own: `RINGS WRITE <id> <f> <f> …` takes an
arbitrary float list and `SAVE <path>` an arbitrary path. Earlier
builds did one 4,095-byte read, trimmed, and executed the PREFIX — so
a long `RINGS WRITE` was answered `OK` over a truncated value list and
no client could tell a complete command from a truncated one. Both
Python clients (`mcp_server.py`, `web/bridge.py`) now refuse an
over-long line themselves, with the same wording, instead of sending
it.

**Bounds.** Every wire integer is checked on BOTH sides before any
pointer is touched. A node id, a depth or an offset outside its range
is refused as

```
ERROR out_of_range: <name> <value> not in 0..<<extent>
```

— the refusal names the offending value AND the true extent. Counts
that drive loops carry a stated cap in `TILED TICK`'s closed-range
vocabulary, `ERROR out_of_range: <name> <value> not in <lo>...<hi>`:
`TICK`, `TICK_SYNC` and `CLOCK ADVANCE` at 10,000 per command,
`BANK NOISE`'s seed at 1,000,000, `SIMILAR_DECISIONS`'s candidate pool
at 4,096. A cap is a refusal, never a silent clip.

`tickCount` is a 32-bit field in the snapshot header, so a tick that
would carry it past `4294967295` is refused rather than wrapped:

```
ERROR out_of_range: tick total <t>+<n> not in 0...4294967295 — tickCount is a 32-bit field in the snapshot header; SAVE and restart to reset it
```

**Shared memory.** Every writer checks capacity before writing a byte,
as the readers always did. A result that does not fit is refused as

```
ERROR out_of_range: result needs <bytes> bytes, shm holds <capacity>
```

and the previous result in shm is left intact. `STREAM NEXT`'s `n` and
`RECORD SLICE`'s `count` are bounded by that capacity, not by a
hardcoded restatement of it.

---

## Lifecycle

```
STATUS
  → OK STATUS nodes=<N> ticks=<k> gpu=<model> grid=<W>x<H> maxRank=<M>
    ranks=<levels> rank_max=<highest rank present> twin_open=<n> tiled_open=<n>
  # maxRank  = the CONFIGURED bound the daemon was started with.
  # ranks    = the rank levels the rank-mode tick actually dispatches,
  #            max(maxRank, rank_max + 1).
  # rank_max = the highest rank actually present in the graph.
  # ranks > maxRank means the running bound is smaller than the graph —
  # a health check compares rank_max against maxRank directly, without
  # having to tick. VALIDATE names the nodes involved.

TICK <n>
  → OK TICK <n> elapsed=<ms>ms total=<tickCount> nodes_computed=<k>
    [ranks=<levels> bound=<maxRank>]

TICK_SYNC <n>
  → OK TICK_SYNC <n> elapsed=<ms>ms total=<tickCount> nodes_computed=<k>
    [rank_max=<highest rank present> bound=<maxRank>]
  # nodes_computed is the WHOLE command's node-evaluations: the node
  # slots one tick dispatches times <n>. Printed always.
  # The bound pair appears only when the graph reaches past the
  # configured bound — the state a graph saved under a large maxRank
  # and restored under a small one lands in. It is computed, not
  # refused (docs/contracts/RANK_BOUND_GATES_FROZEN.md).
  # The two verbs word it differently ON PURPOSE: rank mode reports
  # the levels it dispatched (ranks=), sync mode does not dispatch by
  # rank at all, so it states the same news about the GRAPH (rank_max=)
  # rather than implying a bounded dispatch it never performed.

EVAL [WHERE <field><op><value>] [RANK <lo> TO <hi>]
  → writes matching roots to shm
  → OK EVAL rows=<k> tick=<t> scope=roots nodes_computed=<n>
      [ranks=<r> bound=<M>]
  # EVAL ticks the WHOLE graph and then reports only rank-0 roots —
  # `scope=roots` says so on the wire. It dispatched by rank exactly
  # as TICK did, so it carries TICK's `nodes_computed` and the same
  # `ranks=`/`bound=` pair when the graph reaches past the bound.

VALIDATE
  → OK VALIDATE  |  FAIL VALIDATE <first-violation>
  # Edge violations first (bounds, self-loop, rank monotonicity,
  # duplicates). Then the register invariant (a BACK_EDGE destination
  # with combinational fan-in), the range of every back-edge index, and
  # the agreement between the register flags and the back-edge list.
  # Then the rank bound:
  #   FAIL VALIDATE rank bound: <k> node(s) at or above maxRank <M>
  #     (first node <i> rank <r>, highest rank <h>); rank dispatch
  #     covers <c> of <N> node(s) over <L> rank level(s)
  #     [; <u> node(s) at rank >= <L> are outside every dispatch
  #        (first node <j> rank <s>)]
  # The old sentence is unchanged; the two clauses after it are new.
  # `maxRank` alone conflated two different states. A rank ABOVE the
  # configured bound but inside the dispatch IS computed — that is the
  # stale-bound warning, and the coverage clause says so by printing
  # <c> == <N>. A rank at or above the dispatch's own level count is
  # computed by NOBODY; the last clause names it and <c> falls short.
  # `nodes_computed` on the TICK reply is the same shortfall on the wire.
```

`<field>` ∈ `truth`, `state` (alias for `truth`), `rank`, `type`.
`<op>` ∈ `=`, `!=`, `<`, `>`, `<=`, `>=`. One clause per WHERE.

---

## Read

```
NODES [AT RANK <n>] [WHERE <field><op><value>]
  → writes rows (node, rank, truth, type) to shm
  → OK NODES rows=<k> omitted=<n>

TRAVERSE FROM <node> DEPTH <n>
  → writes rows (node, rank, truth, type) to shm
  → OK TRAVERSE rows=<k> from=<node> depth=<n>

GRAPH INFO
  → OK GRAPH nodes=<N> true=<k> r0=<n> r1=<n> …
```

`NODES` with no rank filter drops every node whose rank AND truth are
both zero — the "likely unused" default filter. `omitted=<n>` is how
many it dropped. The filter is disclosed, not changed.

`TRAVERSE` keeps a global visited set, so a node reachable at several
depths is reported once and the row count is bounded by `nodeCount`.
`depth` is bounded by `nodeCount` too: no path in a DAG on N nodes is
longer than N−1 hops.

---

## Mutate

Every mutation that changes a node's `(truth, rank)` flips the
secondary-index dirty flag. WAL (if enabled) appends the record
before the buffer is touched.

```
SET <node> TRUTH <0|1|2>
SET <node> RANK  <u64>
  → OK SET node=<n> rank=<v>
  → ERROR out_of_range: rank <v> not in 0..<<nodeCount>
  # A rank of nodeCount or more is refused and the rank buffer is left
  # alone: no valid DAG on N nodes holds a rank of N or more. A rank
  # between maxRank and nodeCount is ACCEPTED and computed — the bound
  # is a sizing hint, not a limit.
SET <node> LUT   <PRESET>

CONNECT FROM <src> TO <dst>
CLEAR   <node> EDGES

SET_RANKS_BULK
  → OK SET_RANKS_BULK nodes=<N> validation=skipped
      skipped=rank_monotonicity recheck=VALIDATE
  → ERROR out_of_range: node <i> rank <v> not in 0..<<nodeCount>
  # Caller writes a u64 rank vector of length nodeCount to shm at
  # offset 8 BEFORE calling this. Daemon memcpys into rankBuf in
  # one round-trip. No per-insert MONOTONICITY validation — run
  # VALIDATE after if paranoid. The RANGE is checked: the whole
  # vector is inspected before a single rank is written, so a bad
  # entry leaves every rank exactly as it was and the refusal names
  # the first offending node.

SET_LUTS_BULK
  # Caller writes a u64 LUT vector of length nodeCount to shm at
  # offset 8 BEFORE calling this. Daemon splits each u64 into low/
  # high u32 and commits to lut6Low/lut6High in one round-trip.
  # No WAL — pair with SAVE for durability.

SET_NEIGHBORS_BULK
  → OK SET_NEIGHBORS_BULK nodes=<N> edges_slot=<6N>
      validation=skipped skipped=back_edge_register_fanin
      recheck=VALIDATE
  → ERROR out_of_range: slot <i> (node <n> dir <d>) neighbour <v>
      not in -1..<<nodeCount>
  → ERROR out_of_range: result needs <bytes> bytes, shm holds <cap>
  # Caller writes an Int32 vector of length (nodeCount * 6) to shm
  # at offset 8 BEFORE calling this. Daemon memcpys to neighborsBuf.
  # -1 in any slot means "no neighbour"; every other element must be
  # a real node id. The WHOLE vector is range-checked before a single
  # word is written, so a bad slot leaves every neighbour exactly as
  # it was, and the refusal names the FIRST offender. The read is
  # size-checked against the mapping first.
  # It still bypasses the BACK_EDGE/register invariant CONNECT
  # enforces (a register must not gain combinational fan-in) — the
  # reply says so rather than let a caller assume otherwise.
```

The three bulk verbs together compile a million-node microcircuit
graph in three shm writes + three verbs. See
[`microcircuit-compilation.md`](microcircuit-compilation.md) for the
full recipe on approximating continuous functions at substrate
throughput.

LUT presets: `AND`, `OR`, `XOR`, `MAJ` (MAJORITY6), `IDENTITY`,
`CONST0`, `CONST1`, `VETO`, `NOR`, `NAND`, `AND3`, `OR3`, `MAJ3`.

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

## Persistence — binary `.dags`

```
SAVE <path> [COMPRESSED]
  → OK SAVE bytes=<b> elapsed=<ms>ms ratio=<pct>% path=<p>

LOAD <path>
  → OK LOAD bytes=<b> nodes=<N> ticks=<t>

EXPORT MORTON <dir>
  → writes eleven raw-buffer files; OK EXPORT bytes=<b> dir=<d>
  # The reply line is unchanged; the VALUE of bytes= grew, because it
  # used to report nodeCount * 42 — the six body lanes — while the
  # engine holds ten persisted lanes plus the back-edge list. It now
  # reports what was actually written. See the wiki's data-and-
  # persistence page for the file list.

IMPORT MORTON <dir>
  → reads the six body files (required) and the five lane/back-edge
    files (when present), validates, commits; lanes a directory does
    not carry come back at their defaults, not at the destination's
    previous values
```

Atomic save discipline: tmp → `F_FULLFSYNC` → `replaceItemAt` → dir
fsync. A kill -9 at any point leaves either pre-save state or the
complete new file, never a truncation.

v1 (u8 rank), v2 (u32 rank), v3 (u64 rank), v4 (v3 + back-edge
trailer), and **v5** (v4 + env-origin trailer) snapshot formats
all load; save always writes v5.

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
BACKUP COMPACT <dir>       # fold the chain → new base → drop diffs
BACKUP INFO    <dir>       # base presence, diff count, sizes, format
```

XOR diffs per engine buffer, zlib-compressed per segment. Single-bit
mutations typically produce diffs under 5 % of raw snapshot size.

Replies carry the diff format and what a restore actually wrote:

```
OK BACKUP_APPEND bytes=<n> elapsed=<t>ms path=<file> format=2
OK BACKUP_RESTORE diffs_replayed=<n> elapsed=<t>ms rank_bytes=<8·N> twin=not_covered
OK BACKUP_INFO base=<bool> base_bytes=<n> diffs=<n> total_diff_bytes=<n> format=<v> twin=not_covered
```

`rank_bytes` is the width the restore wrote back — 8 bytes per node,
the engine's u64 rank buffer. `twin=not_covered` is literal: twin
state (streams, rings, clocks, banks, alarms, folds, views) is not in
a backup, and a restore leaves any open twin objects as they are.

**Format 2** (2026-09-12) covers rank (8·N), truth, nodeType, both LUT
halves, neighbours, isRegister, edgeWeights, activation, nodeValue and
the back-edge list. **Format 1** carried six buffers and only 4 of the
8 rank bytes per node, so RESTORE and APPEND refuse such a chain by
name — there is nothing to migrate, the bytes were never written:

```
ERROR io: backup format 1 carries 4 of 8 rank bytes per node and no registers, back edges, weights, activation or node values; cannot restore ranks for nodes N/2..<N; re-create the backup
```

`BACKUP INFO` is read-only: it reports `format=1` and repeats that
sentence as ` caveat=…` instead of refusing.

Seven more refusals, each returned as its own sentence:

```
ERROR io: backup diff <seq> segment <name> is <a> bytes, expected <b>
ERROR io: backup chain is missing diff sequence <n>; the chain is incomplete
ERROR io: backup chain has two diffs with sequence <n>: <file> and <file>
ERROR io: backup diff <file> already exists; refusing to overwrite
ERROR io: backup diff <file> does not match its sha256 sidecar; the file is corrupt or truncated
ERROR io: backup diff <file> has no sha256 sidecar; re-create the backup
ERROR io: backup diff <seq> back-edge section is <a> bytes, expected <b> for <n> pairs
```

Diffs apply in the order of the sequence number in their own header,
never in filename order, and each is verified against its `.sha256`
sidecar before it is decoded. `BACKUP COMPACT` writes its new base
from the chain's own replayed tip at the chain's own tick count — it
neither reads nor changes the live engine.

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
  → OK BFS_DEPTHS seed=<s> dir=<undirected|backward> reached=<r>
    max_depth=<d> elapsed=<f>ms shm_bytes=<4n>
    back_edges=excluded back_edge_count=<b>
  # Post-merge follow-up F2 (core C6). BOTH walks read the
  # COMBINATIONAL edge table. BACK_EDGEs are tick-boundary latches, not
  # edges the rank order constrains, and the engine evaluates them in a
  # separate phase — so they are EXCLUDED from the walk, and the reply
  # says so and says how many were left out rather than folding a latch
  # into a geodesic distance. `back_edge_count` is the graph's total
  # BACK_EDGE count, not the number on any particular path. A caller
  # that wants the latch edges walks them itself. The reader-session
  # form (`READER <id> BFS_DEPTHS ...`) carries the same two fields.
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

### TILED

Tiling, step one (roadmap item 8, branch `dag/tiling`, 2026-09-10,
built on `main`, not yet merged) plus step two — ticking across tiles
(branch `dag/ticking`, same day, built on `dag/tiling`). Gate
contracts: `docs/contracts/TILING_GATES_FROZEN.md` (T1–T6) and
`docs/contracts/TICKING_GATES_FROZEN.md` (W1–W6). **The TILED family is
NOT a twin registry** — despite the superficially similar
OPEN/…/STATUS/LIST/CLOSE shape, a `TiledGraphRouter` is never
persisted, never WAL-logged, and never part of a snapshot: the tile
directory on disk written by `SAVE TILED` IS the durable state, and
`TILED OPEN` only rebuilds an in-memory view of it (recovering any
dangling flush and completing a partial round first — see "Roles at
open" below). It parses at the DSL top level (not through the twin
verb dispatcher), routers live on the daemon handler (not in
`TwinState`), and its ids are `x%08x` from a handler-local counter — a
different shape from the twin registries' single-letter prefixes, and
unreachable through `dagdb_twin_list`/`dagdb_twin_close`.

```
SAVE TILED <dir> <b1,b2,...>
  # Splits the daemon's OWN current engine (not a saved snapshot) into
  # tile files under <dir> by rank range. Boundaries are ascending
  # rank values, comma-separated, no spaces; at least one required.
  → OK SAVE TILED dir=<dir> tiles=<n> nodes=<N> crossings=<c>
  (empty/unsorted/duplicate boundaries → ERROR bad_value; a BACK_EDGE
  whose src and dst would fall in different tiles under these
  boundaries → ERROR bad_value: back edge crosses a tile boundary
  (<src>→<dst>), checked and refused BEFORE any directory is written;
  guardPath failure or a write error → ERROR io)

TILED OPEN <dir> [<K>]
  # Opens a router over <dir>'s manifest.json (written by a prior SAVE
  # TILED). K = max resident tiles, default 2, checked 1...64. Writer
  # role (the only role the daemon opens with): recovers any tile
  # whose last flush crashed mid-way, then completes a partial round
  # left by a between-tiles interruption, BEFORE returning — a torn
  # world is never handed out. Loads no tile bodies until the first
  # query touches them.
  → OK TILED OPEN id=x%08x tiles=<n> nodes=<N> resident_max=<K>
    recovered=<n> completed=<m>
  # Since 2026-09-12 (subsystems bounds, audit C) OPEN also refuses, by
  # name: a manifest whose `format`/`version` are not this reader's; a
  # tile whose manifest / meta.json / body.dags node counts disagree
  # (checked before any engine is allocated); a manifest entry whose
  # engineIndexOf is the wrong length or names an index outside the
  # graph; and a tile whose flush.wal ends in a TORN record (a
  # half-written line, an unknown verb, a three-field BEGIN, or a BEGIN
  # at epoch 0) — that last used to read as "clean" and the tile loaded.
  (K out of range → ERROR out_of_range; missing/corrupt manifest, or
  an unresolvable tear → ERROR io)

TILED BFS <id> <globalId> <depth> [BACK]
  # Cross-tile BFS (undirected, default) or ancestry (BACK,
  # inputs-only), level-synchronous across tile boundaries — depth
  # 0...12. <globalId> is the packed GlobalNodeID (raw u64: 24-bit
  # tile id high, 40-bit local node id low), NOT a plain engine index.
  # shm: [u32 count][u32 rowSize=16] header, then 16-byte rows (u64
  # global id, u32 depth, 4 pad).
  → OK TILED BFS id=<id> seed=<globalId> depth=<d> back=<0|1>
    count=<n> loads=<n> evicts=<n>
  (unknown id → ERROR not_found; depth < 0 → ERROR bad_value; depth >
  12, or a torn tile body's sha256 mismatch (T4) → ERROR io, and the
  refusal is also recorded in TILED STATUS)

TILED SELECT <id> <truth> <lo> <hi>
  # Cross-tile truth/rank-range select — every tile whose span could
  # overlap [lo, hi] is loaded and queried against its own secondary
  # index. shm: [u32 count][u32 rowSize=8] header, then sorted u64 ids.
  → OK TILED SELECT id=<id> truth=<t> lo=<lo> hi=<hi> count=<n>

TILED STATUS <id>
  → OK TILED STATUS id=<id> resident=<n>/<K> loads=<n> evicts=<n>
    refused=<n> last=<error|none> epoch=<min>/<max>
  # loads=/evicts= are ROUTER-WIDE counters, not per-session: any
  # session's query moves them, a READER session's and the web
  # bridge's included. They report the router's residency cache, not
  # the caller's work.
  # epoch is the (min, max) world tick over every tile's own
  # last-flushed epoch (the router holds no global counter) — equal
  # except mid-recovery; a router the daemon opened is never torn.
  # Since 2026-09-12 (subsystems bounds, audit C finding 16) `resident`
  # and the router's high-water mark count the TICKING path's resident
  # set as well as the query path's, and the ticking path's refusals
  # are recorded in `refused`/`last`. A router mid-tick used to report
  # zero residency and no refusals at all.

TILED LIST        → OK TILED LIST count=<n> [id@dir=... tiles=... nodes=... resident_max=... ...]
TILED CLOSE <id>  → OK TILED CLOSE id=<id> open=<n>
  # Nothing to flush — the tile directory on disk is already the
  # durable state.

TILED TICK <id> [<n>] [SYNC]
  # Advances the world <n> ticks (default 1, checked 1...10000), rank
  # mode unless SYNC trails. Durable: every tile is ticked and flushed
  # to disk every round (BEGIN <tile> <epoch> <rank|sync>, body, halo
  # strip, meta, manifest entry, COMMIT, in that order), so a crash
  # mid-flush is detected and recovered the next time the directory is
  # opened.
  → OK TILED TICK id=<id> ticks=<epoch after> tiles_ticked=<n>
    loads=<n> evicts=<n> flushes=<n> halo_bytes=<n>
  (n out of range → ERROR out_of_range; unknown id → ERROR not_found;
  a router error — a stale halo strip that couldn't regenerate, a
  manifest/sidecar sha256 disagreement on a clean tile, a tile epoch
  that would not fit body.dags's 32-bit tick field (refused at flush
  since 2026-09-12, rather than truncated — widening that header field
  is a separate core-format letter), a partial-round
  mode disagreement — → ERROR io)

TILED GET <id> <globalId> TRUTH
  # One node's current truth byte, decimal — a cheap readback that
  # doesn't need a BFS/SELECT.
  → OK TILED GET id=<id> node=<globalId> truth=<0|1|2>
  (no such node → ERROR out_of_range; unknown id → ERROR not_found)
```

**Roles at open.** A mixed-epoch ("torn") tiled world must never
answer a query — BFS/SELECT over tiles at different epochs would be a
tear with no name on it. `TiledGraphRouter.init(role:)` is `.writer`
(the daemon's `TILED OPEN`, and the library default) or `.reader`. A
writer recovers any dangling flush and completes any partial round
before returning, so its world is never torn when it starts answering
or ticking; a reader refuses to open at all over a torn world
(`RouterError.worldTorn`) rather than fixing anything. The daemon only
ever opens writer routers — `TILED OPEN`'s reply always carries what
that open did (`recovered=`/`completed=`).

**STATUS.** The daemon's own `STATUS` line carries `tiled_open=<n>`
alongside `twin_open=<n>` — open routers are counted separately and do
NOT add to `twin_open` (they aren't a twin registry entry).

**Reader allowlist.** `TILED BFS`, `TILED SELECT`, `TILED STATUS`,
`TILED LIST`, and `TILED GET` are read-only and permitted inside
`READER <id> …` (routers are daemon-global, like twin state, so a
reader session may query the same routers the primary path opened).
They DO move the router's tile residency and its `loads=`/`evicts=`
counters — tile residency is a cache, not graph state, which is why
they stay allowed, and why `TILED STATUS`'s counters are documented
above as router-wide;
`TILED OPEN`, `TILED CLOSE`, `SAVE TILED`, and `TILED TICK` mutate the
router registry, the filesystem, or (TICK) flush every tile to disk,
and are forbidden there.

**Not done** (explicit "Not promised" list in the ticking gate
contract): the pre-fetch thread (optional — the contract's letters say
adding it changes no result), the cold tier, thermal pauses, the
10¹¹-node run, `TILED BACKUP`.

---

## Twin primitives

The seven twin-spec primitives (`NamedStream`, `StreamHeader`,
`StreamRecord`, `BudgetLayout`, `CrossConvolutionCheck`, `GearedRings`,
`MasterClock`/`PhaseGear`) plus the alarm-stream court types
(`AlarmRecord`, `SealedCourt`, `AlarmFixture`, `CorruptionModel`,
`SuccessorCourt`, `AllocatorCourt` — twin spec line 4) landed over the
daemon socket in the interface phase (2026-09-06); a tenth family,
`BANK` (spec 8's waveform mouth, § below), lands on branch
`dag/spec8-mouth` (2026-09-10, not yet merged to main). An eleventh
family, `VIEW` (alarm-set derived views, spec line 4's second view
family, § below), lands on branch `dag/derived-views` (2026-09-10, off
`dag/spec8-mouth`, merged with `main` here); a twelfth family, `FOLD`
(the E3 tier ladder, § below), lands on branch `dag/fold-api`
(2026-09-10, built on `dag/spec8-mouth`, merged to main 2026-09-10). A
thirteenth family, `KERNEL` (per-path kernel storage, spec line 6's
second half, § below), plus a second entry point on the pre-existing
`XCONV` family (`XCONV SEALED`, beside `XCONV CHECK`), lands on branch
`dag/kernels` (2026-09-10, built on `main`, not yet merged). A
fourteenth family, `HOOK` (the sealed allocator court as a ticked
process, roadmap item 7, § below), lands on branch `dag/hook`
(2026-09-10, built on `main`, not yet merged).
Fourteen verb families dispatch through one `TwinCommand` grammar
(`dagdb/Sources/DagDBDaemonKit/TwinCommand.swift`,
`DSLParser+Twin.swift`, `DagDBCommandHandler+Twin*.swift`) — `FOLD` is
the one family that mints no registry entry and writes no WAL: every
verb is a pure read of the engine's current lanes.

Every mutating verb follows the WAL-first pattern used elsewhere in
this daemon: validate → mint an id → append to the WAL (abort on
failure, registry untouched) → apply → reply. State lives in one
**daemon-global** `TwinState` (§ below) — there is no per-connection
twin state, unlike `OPEN_READER`'s snapshot-on-read sessions.

### Id prefixes

Every twin id is `"<letter>%08x"` of a per-registry counter that never
reuses a value:

| Prefix | Registry |
|---|---|
| `s` | stream (`NamedStream`) |
| `t` | record (`StreamRecord`) |
| `n` | rings (`GearedRings`) |
| `c` | clock (`MasterClock`) |
| `g` | gear (`PhaseGear`) |
| `b` | budget layout (`BudgetLayout`) |
| `a` | alarm set (`AlarmFixture`) |
| `w` | wave bank (`WaveBank`) — branch `dag/spec8-mouth`, 2026-09-10, not yet merged |
| `v` | view set (`DerivedViews` over a loaded `CortexFixture`) — branch `dag/derived-views`, 2026-09-10, off `dag/spec8-mouth`, not yet merged |
| `k` | kernel pair (`KernelPair`) — branch `dag/kernels`, 2026-09-10, built on `main`, not yet merged |
| `h` | attention hook (`AttentionHook`) — branch `dag/hook`, 2026-09-10, built on `main`, not yet merged |

### STREAM / HEADER / RECORD

```
STREAM OPEN <name> <stateHi> <stateLo> <incHi> <incLo>
  → OK STREAM OPEN id=<id> name=<name> draws=0

STREAM NEXT <id> <n>   (1 <= n <= nodeCount*3)
  → shm [u32 count][u32 8][u64 x count]; then
    OK STREAM NEXT id=<id> n=<n> draws=<d> state=0x<hi>:0x<lo> shm_bytes=<8n>
  # WAL logs the POST-draw state (.streamState), not the draw count —
  # replay restores the boundary in O(1), it never redraws.

STREAM STATE <id>
  → OK STREAM STATE id=<id> name=<name> draws=<d> state=0x<hi>:0x<lo>

STREAM CLOSE <id>  →  OK STREAM CLOSE id=<id>
STREAM LIST        →  OK STREAM LIST count=<n> [id id ...]

HEADER CHECK <band> <tau> <comb> <echo> <record> <step> <floor>
  → OK HEADER CHECK admissible=1
    | FAIL HEADER CHECK violations=<k> <tag>;<tag>...
  # a non-finite field returns ERROR bad_value instead of FAIL
  # Post-merge follow-up F4: the count and the tags now cover the
  # CLOCK-SYNC half of the judgement too, so this verb and RECORD OPEN
  # answer the same header the same way. Until then a floor coarser
  # than the step, or one reaching the record window, was answered
  # `admissible=1` here and refused by RECORD OPEN. The two extra tags:
  #   floorAboveStep(<floor>,<step>)
  #   floorOutlivesRecord(<floor>,<window>)
  # A single-clock stream declares floor 0 and is unaffected.

RECORD OPEN <name> <7 header numbers> <stateHi> <stateLo> <incHi> <incLo>
  → OK RECORD OPEN id=<id> name=<name> slices=0
    (inadmissible header → ERROR schema: inadmissible header: <tags>)
    (quantity 7, the clock sync floor, is now COMPARED as well as
     declared: a floor above the integrator step, or one reaching the
     record window, → ERROR schema: inadmissible clock sync floor: ...
     A single-clock stream declares 0 and is unaffected.)

RECORD SLICE <id> <count>   (1 <= count <= nodeCount*3, and <= 10000)
  → OK RECORD SLICE id=<id> index=<i> count=<count> slices=<total>
    (a count above the replay cap of 10000 → ERROR bad_value: count <n>
     not in 0...10000 — the same ceiling the WAL replay of this verb
     applies, so a record that replays is a record that could have been
     written)

RECORD REPLAY <id> <index>
  → shm [u32 count][u32 8][u64 x count]; then
    OK RECORD REPLAY id=<id> index=<i> count=<c> match=<0|1> shm_bytes=<8c>

RECORD VERIFY <id>
  → OK RECORD VERIFY id=<id> failing=<k>[ failing_indices=<i,j,...>]

RECORD INFO <id>   → OK RECORD INFO id=<id> name=<name> slices=<n> draws=<d>
RECORD CLOSE <id>  → OK RECORD CLOSE id=<id>
RECORD LIST        → OK RECORD LIST count=<n> [id id ...]
```

### RINGS / CLOCK / GEAR

```
RINGS OPEN <gear> <rings> <cells>
  → OK RINGS OPEN id=<id> gear=<g> rings=<r> cells=<c> capacity=<r*c>
    (shape violation — gear<2, rings outside 1..16, cells outside
    2..4096, or a gear whose gear^(rings-1) overflows UInt64 (the
    coarsest span would wrap to zero and the next write would divide by
    it) — → ERROR bad_value: <reason>)

RINGS WRITE <id> <v1> [<v2> ...]
  → OK RINGS WRITE id=<id> n=<count> now=<tick>

RINGS RECALL <id> <lag>
  → OK RINGS RECALL id=<id> lag=<lag> value=<f> tick=<t> ring=<r> span=<s>
    | OK RINGS RECALL id=<id> lag=<lag> value=none   (lag beyond every horizon)

RINGS INFO <id>   → OK RINGS INFO id=<id> gear=<g> rings=<r> cells=<c> capacity=<cap> now=<tick>
RINGS CLOSE <id>  → OK RINGS CLOSE id=<id> open=<remaining>
RINGS LIST        → OK RINGS LIST count=<n> [id id ...]

CLOCK OPEN  → OK CLOCK OPEN id=<id> tick=0

CLOCK ADVANCE <id> [<n>] [VALUE <f>]
  → OK CLOCK ADVANCE id=<id> n=<n> tick=<t> gears=<count>
    (n above the replay cap of 10000 → ERROR bad_value: n <n> not in
     0...10000)
  # n ticks + value logged as ONE WAL record (§ below) — replay re-runs
  # the same count-tick loop, it does not replay tick by tick, so live
  # and replayed gear fires/latchedTick/latchedValue agree exactly. The
  # cap matters because the record is 20 bytes and the work it commands
  # is n: replay applies the same 10000 ceiling.

CLOCK STATE <id>  → OK CLOCK STATE id=<id> tick=<t> gears=[<id,id,...>]
CLOCK CLOSE <id>  → OK CLOCK CLOSE id=<id> gears_closed=<n>   (cascades)
CLOCK LIST        → OK CLOCK LIST count=<n> [id id ...]

GEAR OPEN <clockId> <name> <num>/<den>
  → OK GEAR OPEN id=<id> clock=<clockId> name=<name> ratio=<p>/<q>
    (reduced via GearRatio.reduced; both terms must be > 0)

GEAR STATE <id>
  → OK GEAR STATE id=<id> name=<name> ratio=<p>/<q> fires=<n>
    phase=<a>/<q> latched_tick=<t|none> latched_value=<f|none>

GEAR CLOSE <id>  → OK GEAR CLOSE id=<id>
  # closing a gear prunes it from its owning clock's gearIds first, so a
  # later CLOCK ADVANCE never trips on a stale gear id (T8.3 finding).
```

### XCONV / BUDGET

`XCONV CHECK` is DEPRECATED (2026-09-10, `docs/contracts/
KERNELS_GATES_FROZEN.md` amendment 3): not a court check; flags every
true recording at the court's tolerance (K5, 50/50). It stays wired
for compatibility. `XCONV SEALED` (§ KERNEL, below) is spec line 6's
standing cheap check.

```
XCONV CHECK <nA> <nB> <kA> <kB> <warmup>
  # shm in, f32 vectors back to back at offset 8: recordA(nA), recordB(nB),
  # kernelA taps(kA), kernelB taps(kB)
  → OK XCONV CHECK residual=<d> compared=<n>
    (input past shm capacity → ERROR out_of_range)
  # Two corrections, 2026-09-12 (subsystems bounds, audit C findings 29
  # and 30). `compared` is now bounded by the RECORDS — min(nA, nB)
  # minus the warmup — where it used to run taps−1 samples past the end
  # of the shorter recording, over the convolution tail. And a warmup at
  # or past that window is REFUSED rather than clamped: `compared` is 0
  # and `residual` is inf, where the clamp used to report residual 0 and
  # a check that had compared nothing passed every tolerance.

BUDGET OPEN <nPockets> <nTiers> <nClasses>
  # shm in at offset 8: f64 cost[nPockets][nTiers] row-major, then
  # u32 minTier[nClasses]
  → OK BUDGET OPEN id=<id> pockets=<p> tiers=<t> classes=<c>
    (ragged/NaN/oversized → ERROR bad_value | ERROR out_of_range)

BUDGET SEALED
  → OK BUDGET SEALED id=<id> pockets=4 tiers=8 classes=2
    (opens SealedCourt.makeLayout() — the frozen 4x8 tariff table,
    minTier [4, 1])

BUDGET ALLOCATE <id> <budget> <pocket>:<class> [<pocket>:<class> ...]
  → OK BUDGET ALLOCATE id=<id> value=<v> cost=<c> served=<p,p,...>
    purchases=<pocket:tier:cost:readValue,...>
    (bad pocket/class index or too many claimed pockets → ERROR out_of_range)

BUDGET INFO <id>   → OK BUDGET INFO id=<id> pockets=<p> tiers=<t> classes=<c>
BUDGET CLOSE <id>  → OK BUDGET CLOSE id=<id> open=<remaining>
BUDGET LIST        → OK BUDGET LIST count=<n> [id id ...]
```

### ALARM

```
ALARM LOAD <path> [SHA <hex64>]
  # guardPath() rejects traversal / outside-DATA_ROOT paths before any
  # file I/O. The loaded fixture's OWN computed sha256 (not the caller's
  # optional SHA argument) is what gets WAL-logged and later verified on
  # restore.
  → OK ALARM LOAD id=<id> records=<n> control=<0|1> sha256=<hex>
    quiet=<n> liar=<n> deep=<n> drift=<n> ears=A<n>/B<n>/C<n>
    (missing file, sha mismatch, malformed/unknown-class entry — every
    case → ERROR io: ...; a sha mismatch line always contains the
    literal phrase "sha256 mismatch")

ALARM INFO <id>   → OK ALARM INFO id=<id> path=<p> records=<n> sha256=<hex>
ALARM LIST        → OK ALARM LIST count=<n> [id id ...]
ALARM CLOSE <id>  → OK ALARM CLOSE id=<id>

ALARM FRAME <id> <idx>   (1 <= idx <= records.count)
  → OK ALARM FRAME id=<id> idx=<i> key=<k> class=<raw> ear=<A|B|C|-)
    label=<label|-> pocket=<p|-> burst=<0|1>

ALARM COURT <id> <budget>
  → OK ALARM COURT id=<id> B=<budget> misses=<m> served=<s> cost=<c>
    dummy=<d> dominated=<dm> burst=<served>/<missed>/<total>
  # runs AllocatorCourt.run and reports the allocator arm

ALARM SUCCESSOR <id> <budget> <epsM> <epsS> <epsN>
  → OK ALARM SUCCESSOR id=<id> B=<budget> misses_alloc=<ma>
    misses_greedy=<mg> cost_alloc=<ca> cost_greedy=<cg> weight_dev=<d>
    missing_class_counts=<n>
    (a knob outside [0,1] or non-finite → ERROR bad_value)
    (a fixture whose counts omit a label declared in classSpecs →
     ERROR out_of_range: missing class count <label>)
  # Post-merge follow-up F3 (audit C finding 51). The per-class
  # expectations are scaled by the loaded fixture's own class counts;
  # a label declared in `classSpecs` but absent from that table used to
  # contribute zero silently, making the totals short by a whole class.
  # The counts are validated first and the FIRST missing label, in
  # declaration order (liar_A, liar_B, liar_C, deep, drift, then
  # quiet), is named. `missing_class_counts` is therefore 0 on every OK
  # line; it is printed so a caller reads the fact rather than assumes
  # it.

ALARM CORRUPT <id> <idx> <epsM> <epsS> <epsN>
  # shm out: [u32 count][u32 rowSize=40] header at offset 0, then
  # `count` 40-byte rows at offset 8, each:
  #   f64 weight | u32 nClaims | u32 reserved0 |
  #   5 x (u8 pocket, u8 row(0=L,1=D), u8 phantom, u8 pad) | 4 pad
  → OK ALARM CORRUPT id=<id> idx=<i> outcomes=<n> weight_sum=<w>
    shm_bytes=<40n> claims_truncated=<t>
  # w sums to exactly 1.0 over the full enumeration
  # The row holds 5 claim slots while `nClaims` carries the TRUE
  # count, so a wider outcome would be lossy. `claims_truncated=<t>`
  # is how many rows lost a claim. Under the sealed model it is
  # always 0 — the widest outcome is 4 phantom pockets plus the
  # branch claim, exactly 5 — but the reply states it rather than
  # leave the reader to assume it.
  # The rows are size-checked against the mapping before any is
  # written; too many for this daemon's shm is an out_of_range
  # refusal, not an overrun.
```

### BANK

Spec 8, the waveform mouth (branch `dag/spec8-mouth`, 2026-09-10, not
yet merged to main): one frozen `WaveBank` — a T×K matrix Φ of
unit-norm atoms (harmonic cos/sin columns, then Gabor atoms on a
center/frequency grid) — per open id. `GENERATE` is one matrix product
W = Φ·C; `FIT` is a least-squares solve for the coefficients that best
reproduce a target waveform in the bank's span; every bank declares
its own rank and condition number at OPEN and on INFO. Gate contract:
`docs/contracts/SPEC8_MOUTH_GATES_FROZEN.md`.

```
BANK OPEN <name> [<T> <fs> <f0> <H> <centers> <freqs> <sigmaFrac> [ALIASED]]
  → OK BANK OPEN id=<id> name=<name> T=<T> K=<K> atoms_bytes=<T*K*4>
    rank=<int> cond=<d> rank_deficient=<0|1>
  # No numbers ⇒ WaveBank.Spec.referenceNyquistSafe, the repaired bank
  # (T=4096, fs=3000, f0=60, H=24, centers=8, freqs=6, sigma_frac=0.02,
  # K=144, rank=144). All seven numbers or none; K = 2*H + 2*centers*freqs
  # is derived, not passed. A spec whose top harmonic reaches or exceeds
  # Nyquist (H*f0 >= fs/2) is refused — ERROR bad_value naming the first
  # aliasing harmonic and its frequency — unless the line ends ALIASED
  # (the library itself builds either spec unconditionally; only the
  # daemon gates). The sealed 160-atom CONTROL bank (H=32 at the
  # reference rates) needs its seven numbers plus ALIASED and prints
  # K=160 rank=146 — 14 of its atoms alias above Nyquist.
  # (spec doesn't admit a bank → ERROR bad_value: <reason>)
  # Since 2026-09-12 (subsystems bounds, audit C findings 31 and 32) the
  # Nyquist refusal covers EVERY atom family, not the harmonics alone:
  # the highest Gabor centre (fs/4 by construction) plus that atom's
  # bandwidth 1/(2*pi*sigma_t) is tested against fs/2 under the same
  # ALIASED opt-out. Both sealed specs stay clear of it — at the
  # reference rates the bandwidth is about 5.8 Hz against a 750 Hz grid
  # top — so no reply above changes. The harmonic the message names is
  # also clamped into 1...H: for H*f0 exactly at fs/2 it used to name
  # harmonic H+1, an atom the bank does not contain.

BANK GENERATE <id> <M>
  # M is bounded by the library's declared ceiling of 100 000 columns
  # (the clamp `BANK BENCH` always applied); above it the product is
  # refused by name rather than sized — past 2^31 the BLAS argument
  # conversion trapped, and below it the T*M allocation was unbounded.
  # A coefficient count other than K*M is likewise named, not silently
  # answered with an empty vector (subsystems bounds, findings 34/35).
  # shm in: f32 C[K*M] at offset 8, row-major K×M (C[k*M+m])
  # shm out: [u32 T*M][u32 4] header, then f32 W, T*M values row-major
  # (W[t*M+m])
  → OK BANK GENERATE id=<id> T=<T> M=<M> samples=<T*M> elapsed_ms=<f>
    (input 8+K*M*4 or output 8+T*M*4 past shm capacity → ERROR out_of_range)
    (a column count above the ceiling, or a coefficient count other
     than K*M → ERROR bad_value: BANK GENERATE refused: <reason>)
  # Post-merge follow-up F5: the handler goes through the library's
  # THROWING door (`generateChecked`). Before it, the non-throwing
  # `generate` wrote its named reason to the daemon's stderr and handed
  # back an empty vector, which this verb printed under an `OK` line —
  # a refusal a socket client could not see.

BANK FIT <id>
  # shm in: f32 x[T] at offset 8
  # shm out: [u32 K][u32 4] header, then f32 coefficients, K values
  → OK BANK FIT id=<id> residual=<d> norm=<d> coefficients=<K>
  # residual = ‖x − Φc*‖₂ / ‖x‖₂, both norms Double; norm = ‖x‖₂
    (input 8+T*4 past shm capacity → ERROR out_of_range)

BANK NOISE <id> <seed> <n>   (seed >= 0; 1 <= n <= 200)
  → OK BANK NOISE id=<id> n=<n> expected=<d> mean=<d> min=<d> max=<d>
  # n probes of the engine's own Gaussian noise (PCG stream advanced by
  # `seed` draws, then 2*T*i per probe i), each fit against the bank;
  # expected = sqrt(1 - K/T), the out-of-bank law

BANK BENCH <id> <M> <reps>   (M clamped [1,100000]; reps clamped [1,20])
  → OK BANK BENCH id=<id> M=<M> reps=<reps> best_ms=<f> samples_per_s=<f>
  # best of `reps` timed GENERATE calls, one untimed warm-up first

BANK INFO <id>
  → OK BANK INFO id=<id> name=<name> T=<T> fs=<fs> f0=<f0> H=<H>
    centers=<c> freqs=<f> sigma_frac=<frac> K=<K> rank=<int> cond=<d>
    rank_deficient=<0|1>
  # rank/cond recomputed fresh on every call (~10 ms at 4096x160)
  # `rank_deficient` (post-merge follow-up F5, audit C finding 33) is
  # the library's stricter reading of its own declaration: 1 when the
  # smallest singular value sits at or below the rank threshold
  # (sigmaMax * 1e-9), so `cond` is a finite number that states nothing
  # useful about the bank. It is DISCLOSED, not refused: the sealed
  # 160-atom control bank is deliberately rank deficient (146 of 160)
  # and its `rank=146` is a frozen gate. The repaired default bank
  # prints `rank_deficient=0`. What IS refused, through the throwing
  # door, is a declaration whose LAPACK solve failed or whose smallest
  # singular value is zero or non-finite — the numbers then mean
  # nothing at all:
  #   ERROR bad_value: BANK OPEN refused: <reason>
  #   ERROR bad_value: BANK INFO refused: <reason>

BANK LIST        → OK BANK LIST count=<n> [id id ...]
BANK CLOSE <id>  → OK BANK CLOSE id=<id>
```

The `8 + K*M*4` (GENERATE input) and `8 + T*M*4` (GENERATE output)
capacity rule is the same shm-fits check every twin verb with a shm
payload uses; both are checked before the product runs, so an
oversized request never partially writes.

### VIEW

Spec line 4's second view family (branch `dag/derived-views`,
2026-09-10, off `dag/spec8-mouth`, merged with `main` here): three
alarm-set derived views over the sealed cortex v4 world — reflex,
geometry-then-energy rung, and arrival-geometry ceiling — one loaded
fixture per open id. Grammar mirrors `ALARM`'s LOAD/INFO/LIST/CLOSE
shape; `REFLEX`/`RUNG`/`CEILING`/`FEATURES` are new, pure reads over
the loaded `DerivedViews` (no WAL, no mutation). Gate contract:
`docs/contracts/DERIVED_VIEWS_GATES_FROZEN.md`.

```
VIEW LOAD <path> [SHA <hex64>]
  # guardPath() rejects traversal / outside-DATA_ROOT paths before any
  # file I/O. The loaded fixture's OWN computed sha256 (not the
  # caller's optional SHA argument) is what gets WAL-logged and later
  # verified on restore — mirrors ALARM LOAD.
  → OK VIEW LOAD id=<id> train=6966 test=300 stations=8 samples=64
    candidates=129 sha256=<hex>
    (missing file, sha mismatch, malformed npz layout — every case →
    ERROR io: ...; a sha mismatch line always contains the literal
    phrase "sha256 mismatch")
  # Since 2026-09-12 (subsystems bounds, audit C findings 20-23) the
  # library's `CortexFixture.load` DEFAULTS its sha pin to the sealed
  # constant, so a caller that names no sha gets the pin the type
  # promises; passing nil is an explicit opt-out that prints
  # `WARN unpinned fixture` once. The npz reader also refuses, by name:
  # an .npy major version other than 1, 2 or 3 (every other value used
  # to be parsed as if it were v2) and any minor other than 0; a
  # negative or overflowing shape component (the product is a
  # non-wrapping multiply and used to trap); and zip64 placeholders in
  # the end-of-central-directory or a central record. The daemon's own
  # reply lines are unchanged — it always passes its SHA argument.

VIEW REFLEX <id> <S>   (1 <= S <= 8)
  # Post-merge follow-up F5: the daemon's guard is now the LIBRARY's
  # (`DerivedViews.checkStations`), so the two cannot drift apart about
  # what S a fixture admits. The refusal keeps its wording and gains the
  # library's own named reason after an em dash:
  #   ERROR out_of_range: S <s> not in [1, <stations>] — stations <s>
  #   exceeds the fixture's own station count <stations>
  # It applies to REFLEX, RUNG, CEILING and FEATURES alike. Underneath it the
  # library gained the same bound (subsystems bounds, audit C findings
  # 41-44): every `DerivedViews` entry point refuses a station count
  # outside 1...fixture.stations by name — above it, `tau[c*stride + s]`
  # read silently into the NEXT candidate's row for every candidate but
  # the last, and the frame index then trapped. Three more: a candidate
  # whose least-squares fit FAILS is now skipped and counted (`skipped=`
  # on the decision, `skippedTotal` on the summary) instead of being
  # scored from a fabricated (alpha, beta) = (0, 0) that could win the
  # tie-break; a non-finite k = 1/(speed*dt*os) refuses instead of
  # making every class size 1 and the ceiling 1.0; and the 16-sample
  # front window's zero-filled convention at the end of a record is now
  # gated as a control against the short-window convention. On the
  # sealed fixture nothing is skipped and no sealed number moves.
  # Per station s in 0..<S: arrival = first index |x_s| > 0.25*max|x_s|
  # on the S-station slice, re-zeroed. Per candidate: 2-parameter
  # least-squares fit (alpha, beta) over normalized tau (global
  # tau_max), alpha clipped at 0 after the fit; tie rule
  # r <= r_min + 1e-9*max(1, r_min); winner = lowest tied index.
  → OK VIEW REFLEX id=<id> S=<S> reflex=<n> oracle=<n> tie_min=<n>
    tie_median=<d> tie_max=<n> frames_with_tie=<n> near_edge=<n>
  # reflex/oracle/tie_*/frames_with_tie are gate V1-V3's numbers;
  # near_edge is printed only (V1's honest-clause floor, never gated)

VIEW RUNG <id> <S>
  # Reflex tied set resolved by nearest standardized-feature class
  # centroid (Euclidean; exact-distance ties keep the lowest index),
  # over 3*S front-aligned energy features standardized with the 6966
  # train frames' (mean, std) pairs (one per station/channel, std
  # floored at 1e-12, never pooled). Centroids recomputed on every
  # call.
  → OK VIEW RUNG id=<id> S=<S> hits=<n> min_margin=<d>
  # hits is gate V4's number; min_margin is printed only

VIEW CEILING <id> <S>
  # k = 1/(SPEED*dt*OS); A = k*tau_raw[:, :S], row-shifted by its min.
  # Exact-twin pairs: max-norm < 1e-9. Identifiable classes: unique +
  # groups under the max-norm < 1.0 transitive-closure relation.
  → OK VIEW CEILING id=<id> S=<S> identifiable=<n> of=129
    ceiling=<%.6f> exact_twin_pairs=<n> unique=<n> groups=<n>
  # gate V5's numbers, ceiling printed at six decimals

VIEW FEATURES <id> <frame> <S>   (0 <= frame < 300)
  # shm out: [u32 count=3*S][u32 4] header at offset 0, then `count`
  # little-endian f32 standardized values at offset 8 — station-major:
  # for each station in the S-subset, (ii) log front-window energy
  # ratio, (iii) magnitude-weighted spectral centroid (Hz), (iv) log
  # second/first-window energy ratio.
  → OK VIEW FEATURES id=<id> frame=<frame> S=<S> count=<3*S>
  # (S or frame out of range → ERROR out_of_range)

VIEW INFO <id>
  → OK VIEW INFO id=<id> path=<p> sha256=<hex> train=<n> test=<n>
    stations=<n> samples=<n> candidates=<n>
VIEW LIST        → OK VIEW LIST count=<n> [id id ...]
VIEW CLOSE <id>  → OK VIEW CLOSE id=<id>
```

Persistence follows `ALARM`'s pattern exactly: view sets persist BY
REFERENCE (path + sha256, WAL opcode `0x2D`, snapshot v7's `views`
field), never their bytes; a missing or hash-changed file on restore
drops that one entry with a stderr `WARN`, it does not refuse the
whole snapshot load. Reader-session allowlist: `REFLEX`, `RUNG`,
`CEILING`, `FEATURES`, `INFO`, `LIST` are read-only; `LOAD` and
`CLOSE` are forbidden inside `READER <id> ...`, same shape as every
other twin family.

### FOLD

The E3 tier ladder (branch `dag/fold-api`, built on `dag/spec8-mouth`,
2026-09-10, merged to main 2026-09-10): Kron/Schur fold of a rank ring
into the kept set at a time, operator stored to Float32 between folds,
solved in Float64 via LAPACK `dgesv` — `LadderFold.run` promoted from
the sealed `E3Ladder` runner, arithmetic unchanged. Unlike every other
twin family, `FOLD` mints no id and touches no WAL: it is a pure,
read-only computation over the engine's current lanes (neighbors,
edge weights, `nodeValue` as leak, rank) — the same lanes
`CONNECT`/`SET` write, so a fresh daemon (neighbor table wiped) folds
whatever graph is there, hex adjacency only if it was written there.
The handler holds only the last `FOLD RUN` result; every other FOLD
verb reads back from it. Gate contract:
`docs/contracts/FOLD_API_GATES_FROZEN.md`.

```
FOLD RUN <maxRank> <keepRank> <f1> <f2> [<f3>] [CHECK <l1,l2,...>]
  # shm out: [u32 k*k][u32 4] header, then f32 final_operator, k*k
  # values row-major (k = kept count)
  → OK FOLD RUN kept=<k> folds=<n> bytes=<k*k*4> wall_ms=<f>
    (a node whose rank sits above <maxRank>, a rank lane value above
     Int.max, or a singular fold → ERROR bad_value: FOLD RUN refused:
     <reason>. The source-index and rank/keepRank arguments are still
     caught earlier by this handler's own out_of_range guards.)
  # Post-merge follow-up F5: the handler goes through the library's
  # throwing door (`runChecked`). Before it, `run` reported a refusal
  # as an empty result plus a stderr line, which this verb printed as
  # `OK FOLD RUN kept=0 folds=0 bytes=0` — and that empty result was
  # stored as the last fold, so FOLD KEPT/SOURCE/TIER read it back. A
  # refused fold now leaves the previous result untouched.
  # kept-set size k is predicted before any O(k^3) work; a result that
  # would exceed shm capacity is ERROR out_of_range before computing.
  # (bad rank/node/checkpoint args → ERROR out_of_range; any FOLD verb
  # before the first FOLD RUN → ERROR not_found)
  # The daemon's own guards above are unchanged. Underneath them the
  # library's fold gained four refusals (subsystems bounds, findings
  # 36-39), each carried on the result and printed as a named
  # `ERROR ladder_fold:` line: a schedule whose maxRank is BELOW the
  # object's own highest rank (those nodes were silently dropped at the
  # first fold, with their rows and columns of the operator); a source
  # index outside the node range; a singular fold or tier operator
  # (which used to abort the process on a LAPACK precondition); and a
  # rank the engine's u64 lane holds but Int cannot represent.

FOLD KEPT
  # shm out: [u32 k][u32 8] header, then u64 keptIds, k values
  → OK FOLD KEPT kept=<k>

FOLD SOURCE <1|2|3>
  # shm out: [u32 k][u32 4] header, then f32 foldedSource, k values
  # (3 with no f3 given to RUN → a vector of zeros)
  → OK FOLD SOURCE which=<i> kept=<k>

FOLD TIER <level|final> <1|2|3>
  # shm out: [u32 k][u32 8] header, then f64 tier answer, k values
  # (level not a checkpoint passed to RUN, or which=3 with no f3
  # given to RUN → ERROR not_found)
  → OK FOLD TIER level=<level> which=<i> count=<k>

FOLD INFO        → OK FOLD INFO kept=<k> folds=<n> tiers=<l1,l2,...,final>
                    bytes=<k*k*4> wall_ms=<f>
  # no shm output
```

Every FOLD verb is read-only, `RUN` included — reader sessions may
run all five (§ MVCC reader sessions, below).

### KERNEL / XCONV SEALED

Spec line 6's second half (branch `dag/kernels`, 2026-09-10, built on
`main`, not yet merged): per-path kernels (impulse responses
root→ear, 2048 taps) stored by reference and by id, a per-pair
warmup declared or derived, and the W1 court's own frozen
cross-convolution residual R reached over the socket — a **second**
entry point for spec line 6, distinct from the pre-existing `XCONV
CHECK` (now deprecated, § XCONV/BUDGET above). Grammar mirrors
`ALARM`/`VIEW`'s LOAD/INFO/LIST/CLOSE shape; `KERNEL LOAD`'s optional
groups are in a FIXED order — `[SHA <hex64>] [TAU <τA> <τB> SIGMA
<σ>] [WARMUP <n>]` — any other order, or a group twice, is
`.unknown`, never reordered/matched. Gate contract:
`docs/contracts/KERNELS_GATES_FROZEN.md`.

```
KERNEL LOAD <path> [SHA <hex64>] [TAU <τA> <τB> SIGMA <σ>] [WARMUP <n>]
  # guardPath() rejects traversal / outside-DATA_ROOT paths before any
  # file I/O. The loaded kernels file's OWN computed sha256 (not the
  # caller's optional SHA argument) is what gets WAL-logged and later
  # verified on restore — mirrors ALARM LOAD / VIEW LOAD. TAU/SIGMA
  # (τ_A, τ_B, σ_source, seconds) are the pair's path delays and the
  # source bank's Gaussian envelope sigma — DECLARED here, K4: never
  # read from the kernels file — and derive the warmup; an explicit
  # WARMUP is used only when TAU/SIGMA are absent (TAU/SIGMA's derived
  # warmup always wins when both are present).
  → OK KERNEL LOAD id=<id> taps=<n> fs=<hz> window=<n> ears=<A>/<B>
    warmup=<v|none> derived=<0|1> sha256=<hex>
    (a resolved warmup at or above the file's own window_samples →
     ERROR io: bad layout: warmup <v> leaves no comparison window
     against window_samples <w> (taps <n>))
  # That refusal comes from the LIBRARY loader, which has checked it
  # since 2026-09-12 (subsystems bounds, audit C finding 28). Post-merge
  # follow-up F5 changed the ORDER, not the refusal: the daemon now
  # resolves the warmup through the same throwing door BEFORE the id is
  # minted and before the op reaches the WAL, so no path through this
  # handler can install a kernel whose warmup leaves no comparison
  # window. The handler's own wording for that case
  # (ERROR bad_value: KERNEL LOAD refused: ...) is defence in depth and
  # unreachable while the loader keeps the check.
    (missing file, sha mismatch, malformed/empty kernel array — every
    case → ERROR io: ...; a sha mismatch line always contains the
    literal phrase "sha256 mismatch")
  # Since 2026-09-12 (subsystems bounds, audit C findings 23, 26-28)
  # the library's `KernelPair.load` defaults its sha pin to the sealed
  # W1 constant (nil is an explicit opt-out that warns once), refuses a
  # non-integral or out-of-Int `window_samples` instead of truncating
  # it, refuses a non-finite fs/tau or a non-finite/negative sigma
  # (which used to trap inside the derived-warmup conversion or yield a
  # negative warmup), and refuses a resolved warmup that leaves no
  # comparison window against `window_samples`. The daemon's replies are
  # unchanged for the sealed fixture — its derived warmup is still 185
  # against a 2048-sample window.

XCONV SEALED <id> <n> [<warmup>]
  # shm in: f64 a[n] then f64 b[n] at offset 8 (rowSize 8, no gap) —
  # the sealed records to check against the loaded pair `id`.
  # `warmup`, if given, OVERRIDES the pair's own resolution and is
  # reported "declared, not derived" (derived=0); omitted, the pair's
  # own warmup is used (derived from TAU/SIGMA if present, else the
  # pair's declared WARMUP, else ERROR bad_value — no default).
  # Residual: yAB = (kB ⋆ a)[:n], yBA = (kA ⋆ b)[:n], window
  # [warmup, n) on BOTH numerator and denominator, denominator
  # one-sided max|yAB| + 1e-300, float64 end to end — the W1 court's
  # frozen formula, NOT XCONV CHECK's.
  → OK XCONV SEALED id=<id> n=<n> warmup=<v> derived=<0|1>
    residual=<R Double> compared=<n − warmup>
    (a warmup at or above the pair's window_samples →
     ERROR bad_value: XCONV SEALED refused: <reason>)
  # Post-merge follow-up F5. This refusal is ordered BEFORE the
  # `warmup < n` bound, so an override that violates both is reported
  # as the window violation.
    (n < 2 → ERROR bad_value; no warmup available and none given →
    ERROR bad_value; warmup >= n, or input past shm capacity →
    ERROR out_of_range; unknown id → ERROR not_found)

KERNEL INFO <id>
  → OK KERNEL INFO id=<id> path=<p> sha256=<hex> taps=<n> fs=<hz>
    window=<n> ears=<A>/<B> tau_a=<v|none> tau_b=<v|none>
    sigma=<v|none> warmup=<v|none> derived=<0|1>
    (as above → ERROR bad_value: KERNEL INFO refused: <reason>)
KERNEL LIST        → OK KERNEL LIST count=<n> [id id ...]
KERNEL CLOSE <id>  → OK KERNEL CLOSE id=<id>
```

For the sealed W1 pair (`Tests/Fixtures/w1_kernels.json`, τ_A
0.18227148035108542, τ_B 0.18382585465904366, σ_source 0.02), the
derived warmup is 185 — K4's number, printed on both `KERNEL LOAD`
and `KERNEL INFO`.

Persistence follows `ALARM`'s / `VIEW`'s pattern exactly: kernel pairs
persist BY REFERENCE (path + sha256, plus the declared τ_A/τ_B/
σ_source/warmup, WAL opcode `0x2E`, snapshot v7's `kernels` field),
never the taps; a missing or hash-changed file on restore drops that
one entry with a stderr `WARN`, it does not refuse the whole snapshot
load. Reader-session allowlist: `XCONV SEALED`, `KERNEL INFO`,
`KERNEL LIST` are read-only; `KERNEL LOAD` and `KERNEL CLOSE` are
forbidden inside `READER <id> ...`, same shape as every other twin
family. `XCONV CHECK` was already reader-allowed (§ XCONV/BUDGET,
above; unchanged).

### HOOK

Roadmap item 7 (branch `dag/hook`, 2026-09-10, built on `main`, not
yet merged): the sealed allocator court (`AllocatorCourt.run`) as a
daemon-global ticked process — instead of one batch call, an
`AttentionHook` advances one frame per `HOOK STEP`, appending one
derived ledger row each time. Grammar mirrors `ALARM`/`VIEW`/`KERNEL`'s
LOAD→OPEN/INFO/LIST/CLOSE shape; `HOOK OPEN`'s optional groups are in
a FIXED order — `[DELTA <d>] [POLICY allocator|greedy|uniform] [CLOCK
<c>]` — any other order, or a group twice, is `.unknown`, never
reordered/matched. Gate contract: `docs/contracts/HOOK_GATES_FROZEN.md`.

```
HOOK OPEN <alarmId> <layoutId|SEALED> <budget> [DELTA <d>] [POLICY allocator|greedy|uniform] [CLOCK <c>]
  # layoutId "SEALED" resolves to nil at the parser (SealedCourt.makeLayout());
  # delta/policy absent here resolve to the sealed defaults (3, allocator)
  # in the HANDLER, not the parser, so the reply always prints the
  # resolved value. budget must be finite and > 0; the budget is
  # CONSTANT per hook — a different B is a different hook, never a
  # mid-run re-declaration (no HOOK BUDGET).
  → OK HOOK OPEN id=<id> alarm=<id> layout=<id|SEALED> B=<f> delta=<n>
    policy=<allocator|greedy|uniform> clock=<id|none> frames=<n>
    (frames = the alarm set's record count + delta)
    (unknown alarm/layout/clock → ERROR not_found; budget not finite
    or <= 0 → ERROR bad_value; delta < 0 → ERROR out_of_range)

HOOK STEP <id> <n>
  # Advances up to n frames, or until done, whichever comes first — a
  # step past the last frame is a no-op (stepped=0, done=1). Refused
  # on a clock-bound hook: its one driver is CLOCK ADVANCE.
  → OK HOOK STEP id=<id> t=<t> stepped=<n> done=<0|1> served=<n>
    misses=<n> cost=<f>
    (n < 1 → ERROR out_of_range; unknown id → ERROR not_found; bound
    to a clock → ERROR forbidden: bound to clock <c>)

HOOK STATE <id>
  → OK HOOK STATE id=<id> t=<t> done=<0|1> served=<n> misses=<n>
    cost=<f> dummy=<n> dominated=<n> max_spend_ratio=<f>
    warmup_cost=<f> burst=<served>/<missed>/<total>

HOOK LEDGER <id> [<from> <count>]
  # Omitting from/count returns every row. shm: [u32 count][u32
  # rowSize=40] header at offset 0, then `count` 40-byte rows at
  # offset 8, each 8-byte aligned:
  #   u32 t | i32 src | u8 judged | u8 outcome (0 none, 1 hit, 2 miss)
  #   | i8 tier (-1 none) | i8 pocket (-1 none) | 4 pad | f64 spend |
  #   f64 cumulativeCost | u8 countsTowardCost | 7 pad = 40 bytes/row.
  # The ledger is DERIVED, never stored — rebuilt by re-stepping.
  → OK HOOK LEDGER id=<id> from=<n> count=<n> of=<n>
    (range outside [0, ledger.count], or the requested bytes exceed
    shm capacity → ERROR out_of_range; unknown id → ERROR not_found)

HOOK INFO <id>
  → OK HOOK INFO id=<id> alarm=<id> layout=<id|SEALED> B=<f> delta=<n>
    policy=<p> clock=<id|none> frames=<n> t=<n> done=<0|1>
HOOK LIST        → OK HOOK LIST count=<n> [id id ...]
HOOK CLOSE <id>  → OK HOOK CLOSE id=<id>
  # Refused if the alarm set or budget layout it was opened against is
  # closed while this hook is still open — see ALARM/BUDGET CLOSE below.
```

**One step, one frame.** At frame `t` the hook reads the alarm of
source frame `src = t − Δ`; the frame is judged iff `1 ≤ src ≤ N`
(the alarm set's record count). Warm-up rows (`t = 1..Δ`) are `judged
= false` — for `uniform` they still pay the flat frame cost, booked
into `warmupCostExcluded` (never into `cost`) while `maxSpendRatio`
still sees them; `allocator`/`greedy` warm-up rows spend 0. A judged
frame whose source is quiet is outcome `none`: `uniform` still pays
its flat cost and books `cost` with no hit/miss; `allocator`/`greedy`
book nothing. `allocator` buys the cheapest tier with read value 1 in
the claimed pocket; `greedy` buys the deepest affordable tier in the
source alarm's own pocket (no "loudest" from residuals — one alarm per
frame); the oracle has no lag and is not a hook policy, it stays a
court arm only.

**Refusals.** A hook bound to a clock (`HOOK OPEN … CLOCK <c>`)
refuses `HOOK STEP` directly — `ERROR forbidden: bound to clock <c>`
— so its frame counter has exactly one driver; step it via `CLOCK
ADVANCE` instead. `CLOCK ADVANCE` steps every hook bound to that clock
once per tick, AFTER that tick's gears (`TwinState.apply` order:
clock tick, gears, hooks) — attention is spent on the engine's clock,
not by a batch call. `CLOCK CLOSE` cascades to bound hooks the same
way it cascades to gears, and its reply gains `hooks_closed=<n>`
beside `gears_closed=<n>`. Closing the alarm set or budget layout a
live hook depends on refuses the same way: `ALARM CLOSE`/`BUDGET
CLOSE` on an id a hook still references returns `ERROR forbidden: hook
<h> depends on <id>`, naming the hook — close the hook first.

**Reader allowlist.** `HOOK STATE`, `HOOK LEDGER`, `HOOK INFO`, and
`HOOK LIST` are read-only and permitted inside `READER <id> …`; `HOOK
OPEN`, `HOOK STEP`, and `HOOK CLOSE` mutate daemon-global twin state
and are forbidden there, same shape as every other twin family.

Over the sealed W2 records (`DAGDB_W2_FIXTURE`), `HOOK STEP` to
completion (203 steps) at the richest sealed budget point (B =
16164.352484758914) prints `served=150 misses=0 cost=819218.0` for
the allocator policy — the interface-phase gate-1 line, bit for bit — and
`served=50 misses=100 cost=94400.0` for uniform.

### Persistence

WAL opcodes `0x20`–`0x2B` (`TwinWALCodec`, little-endian, u16-length-
prefixed strings, f32/f64 as bit patterns): `twinStreamOpen`,
`twinStreamState`, `twinRecordOpen`, `twinRecordSlice`, `twinRingsOpen`,
`twinRingsWrite`, `twinClockOpen`, `twinClockAdvance`, `twinGearOpen`,
`twinLayoutOpen`, `twinAlarmLoad`, `twinClose`. Opcode `0x2C`,
`twinBankOpen` (branch `dag/spec8-mouth`, 2026-09-10, not yet merged),
logs a `BANK OPEN` the same way — `GENERATE`/`FIT`/`NOISE`/`BENCH`
never touch the WAL, only shm. Opcode `0x2D`, `twinViewLoad` (branch
`dag/derived-views`, 2026-09-10, off `dag/spec8-mouth`, not yet
merged), logs a `VIEW LOAD` the same way — `REFLEX`/`RUNG`/`CEILING`/
`FEATURES`/`INFO`/`LIST` never touch the WAL, `REFLEX`/`RUNG`/
`CEILING` reply directly and `FEATURES` writes shm only. Opcode
`0x2E`, `twinKernelLoad` (branch `dag/kernels`, 2026-09-10, built on
`main`, not yet merged), logs a `KERNEL LOAD` the same way —
`XCONV SEALED`/`INFO`/`LIST` never touch the WAL, `XCONV SEALED`
reads shm input and replies directly. Opcodes `0x2F`/`0x30`,
`twinHookOpen`/`twinHookStep` (branch `dag/hook`, 2026-09-10, built on
`main`, not yet merged), log `HOOK OPEN`/`HOOK STEP` the same way —
`HOOK CLOSE` logs the same plain `twinClose` (`0x2B`) every other
CLOSE verb logs; `HOOK STATE`/`LEDGER`/`INFO`/`LIST` never touch the
WAL. A malformed
twin payload decodes to `nil` and is skipped on replay, never fatal —
a following non-twin record still applies.

Snapshot **v7** adds a `TWIN` section (magic `"TWIN"` + `u32`
byteLength + sorted-keys JSON of `TwinState.Snapshot`) between the
WGTS lane section and the ENVS trailer; `save`/`load` default to no
twin state (length 0 / section ignored) unless a `TwinState` is
threaded through. `TwinState.Snapshot`'s `banks` field (branch
`dag/spec8-mouth`), `views` field (branch `dag/derived-views`),
`kernels` field (branch `dag/kernels`), and `hooks` field (branch
`dag/hook`) decode tolerantly — an older
v7 file with no `banks`/`views`/`kernels`/`hooks` key still loads, with an
empty registry. Alarm sets, view sets, and kernel pairs all persist
**by reference** (path + sha256, kernel pairs also carrying the
declared τ_A/τ_B/σ_source/warmup),
never their bytes; on restore a missing or hash-mismatched file
drops that one entry with a stderr `WARN`, it does not refuse the
whole snapshot load — the gate path's stricter "wrong hash FAILS" rule
(`docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md` amendment 1,
`docs/contracts/DERIVED_VIEWS_GATES_FROZEN.md` for `VIEW`, and
`docs/contracts/KERNELS_GATES_FROZEN.md` for `KERNEL`) applies only
to `ALARM LOAD`'s / `VIEW LOAD`'s / `KERNEL LOAD`'s live load path,
not to restore. Hooks persist differently: a `HookRef` is trusted
parameters + the frame counter `t` (no path/hash of its own — nothing
external to check), rebuilt on restore by re-opening against its
already-restored alarm/layout/clock and re-stepping `t` times, which
also rebuilds the ledger (DERIVED, never stored); a hook whose
referenced alarm or layout failed to restore throws rather than
warn-and-drop, since that is real corruption, not a missing external
file.

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
`BFS_DEPTHS`, `DISTANCE`, `SELECT`, `ANCESTRY`, `VALIDATE`, and the
read-only twin verbs (§ Twin primitives, above) — `STREAM STATE`/
`LIST`, `HEADER CHECK`, `RECORD REPLAY`/`VERIFY`/`INFO`/`LIST`,
`RINGS RECALL`/`INFO`/`LIST`, `CLOCK STATE`/`LIST`, `GEAR STATE`,
`XCONV CHECK`, `BUDGET ALLOCATE`/`INFO`/`LIST`, `ALARM INFO`/`LIST`/
`FRAME`/`COURT`/`SUCCESSOR`/`CORRUPT`, and (branch `dag/spec8-mouth`,
2026-09-10) `BANK GENERATE`/`FIT`/`NOISE`/`BENCH`/`INFO`/`LIST` —
`GENERATE`/`FIT` write shm only, never the daemon-global twin state,
so they count as read-only the same way `RECORD REPLAY` does; and
(branch `dag/derived-views`, 2026-09-10, off `dag/spec8-mouth`)
`VIEW REFLEX`/`RUNG`/`CEILING`/`FEATURES`/`INFO`/`LIST` — `FEATURES`
writes shm only, the rest reply directly, none touch the daemon-global
twin state. Four of the five FOLD verbs (branch `dag/fold-api`, 2026-09-10) —
`FOLD KEPT`/`SOURCE`/`TIER`/`INFO` — are allowed too. **`FOLD RUN` is
NOT** (branch `dag/daemon-bounds`): it mints no id and touches no WAL,
but it ASSIGNS the daemon-global last-fold result those four read, so
a reader session — or a browser through `web/bridge.py` — silently
overwrote what the primary saw. A reader issuing it gets
`ERROR forbidden: FOLD RUN assigns the daemon-global last-fold result
that FOLD KEPT/SOURCE/TIER/INFO read; not allowed in reader session`,
and the primary's `FOLD INFO` is unchanged. And (branch `dag/kernels`, 2026-09-10,
built on `main`) `XCONV SEALED`, `KERNEL INFO`, `KERNEL LIST` — `XCONV
SEALED` reads shm input and replies directly, neither touches the
daemon-global twin state; `KERNEL LOAD`/`CLOSE` are mutating and
forbidden, same as `ALARM`/`VIEW`. Writes,
`EVAL`, nested
`READER`, `SIMILAR_DECISIONS`, and every mutating twin verb (twin
registries are daemon-global — convention 13 of the interface-phase gate contract, there is
no reader-scoped twin state to serve) are rejected with
`ERROR forbidden:`.

---

## Error taxonomy

Every error response starts with `ERROR <category>: <detail>`. See
[`invariants.md`](invariants.md) for the full table.

Categories: `out_of_range`, `dsl_parse`, `unknown_command`,
`schema`, `io`, `wal`, `bfs`, `not_found`, `forbidden`, `bad_value`,
`too_long`, `reader`.

`too_long` (added at gate D4): the one framing refusal —
`ERROR too_long: command exceeds 4095 bytes`. See "The frame" at the
top of this file.

`bad_value` (added with the twin verbs, the interface phase): a non-finite
number, an out-of-[0,1] corruption knob, or a shape violation
(`RINGS OPEN`'s gear/rings/cells bounds, `BUDGET OPEN`'s ragged/NaN
cost table) — a validating front door catching what would otherwise
be a `precondition` trap. Post-merge follow-up F5 added five more of
exactly that kind, all in the form `ERROR bad_value: <VERB> refused:
<reason>`: `FOLD RUN`, `BANK GENERATE`, `BANK OPEN`/`BANK INFO`,
`KERNEL LOAD`/`KERNEL INFO` and `XCONV SEALED`. Each is a subsystem
refusal that previously travelled only as a line on the daemon's
stderr plus an empty or default-valued result under an `OK` line — a
refusal no socket client could see.

Outside the DSL, post-merge follow-up F1 made `HexGrid`'s ordinary
initialiser throwing, so a grid whose axes fall outside the 16-bit
Morton encoding, or whose node count exceeds the Int32 index space, is
refused by name at construction instead of aborting the process with a
`precondition`. This is the daemon's `--grid` argument at startup, not
a wire command; the refusal names the axis, the value and the bound. `reader` predates the twin verbs (a
reader-session-bound node-range check in `TRAVERSE`/`ANCESTRY`) but
was missing from this list. Those two reader-side checks now print
`out_of_range` like every other bounds refusal, so nothing in the
current daemon emits `reader:`; the category stays listed because
older logs carry it.
