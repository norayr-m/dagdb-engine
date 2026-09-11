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
  → OK STATUS nodes=<N> ticks=<k> gpu=<model> grid=<W>x<H> maxRank=<M> twin_open=<n>

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
SET <node> RANK  <u64>
SET <node> LUT   <PRESET>

CONNECT FROM <src> TO <dst>
CLEAR   <node> EDGES

SET_RANKS_BULK
  # Caller writes a u64 rank vector of length nodeCount to shm at
  # offset 8 BEFORE calling this. Daemon memcpys into rankBuf in
  # one round-trip. No per-insert validation — run VALIDATE after
  # if paranoid.

SET_LUTS_BULK
  # Caller writes a u64 LUT vector of length nodeCount to shm at
  # offset 8 BEFORE calling this. Daemon splits each u64 into low/
  # high u32 and commits to lut6Low/lut6High in one round-trip.
  # No WAL — pair with SAVE for durability.

SET_NEIGHBORS_BULK
  # Caller writes an Int32 vector of length (nodeCount * 6) to shm
  # at offset 8 BEFORE calling this. Daemon memcpys to neighborsBuf.
  # No rank-monotonicity validation — run VALIDATE after if
  # paranoid. -1 in any slot means "no neighbour".
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
  → writes six raw-buffer files; OK EXPORT bytes=<b> dir=<d>

IMPORT MORTON <dir>
  → reads six raw-buffer files, validates, commits
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

## Twin primitives

The seven twin-spec primitives (`NamedStream`, `StreamHeader`,
`StreamRecord`, `BudgetLayout`, `CrossConvolutionCheck`, `GearedRings`,
`MasterClock`/`PhaseGear`) plus the alarm-stream court types
(`AlarmRecord`, `SealedCourt`, `AlarmFixture`, `CorruptionModel`,
`SuccessorCourt`, `AllocatorCourt` — twin spec line 4) landed over the
daemon socket in the interface phase (2026-09-06). Nine verb
families dispatch through one `TwinCommand` grammar
(`dagdb/Sources/DagDBDaemonKit/TwinCommand.swift`,
`DSLParser+Twin.swift`, `DagDBCommandHandler+Twin*.swift`).

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

RECORD OPEN <name> <7 header numbers> <stateHi> <stateLo> <incHi> <incLo>
  → OK RECORD OPEN id=<id> name=<name> slices=0
    (inadmissible header → ERROR schema: inadmissible header: <tags>)

RECORD SLICE <id> <count>   (1 <= count <= nodeCount*3)
  → OK RECORD SLICE id=<id> index=<i> count=<count> slices=<total>

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
    2..4096 — → ERROR bad_value: <reason>)

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
  # n ticks + value logged as ONE WAL record (§ below) — replay re-runs
  # the same count-tick loop, it does not replay tick by tick, so live
  # and replayed gear fires/latchedTick/latchedValue agree exactly.

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

```
XCONV CHECK <nA> <nB> <kA> <kB> <warmup>
  # shm in, f32 vectors back to back at offset 8: recordA(nA), recordB(nB),
  # kernelA taps(kA), kernelB taps(kB)
  → OK XCONV CHECK residual=<d> compared=<n>
  (compatibility entry point; not the court's sealed cross-convolution; see XCONV SEALED (next window))
    (input past shm capacity → ERROR out_of_range)

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
    (a knob outside [0,1] or non-finite → ERROR bad_value)

ALARM CORRUPT <id> <idx> <epsM> <epsS> <epsN>
  # shm out: [u32 count][u32 rowSize=40] header at offset 0, then
  # `count` 40-byte rows at offset 8, each:
  #   f64 weight | u32 nClaims | u32 reserved0 |
  #   5 x (u8 pocket, u8 row(0=L,1=D), u8 phantom, u8 pad) | 4 pad
  → OK ALARM CORRUPT id=<id> idx=<i> outcomes=<n> weight_sum=<w>
    shm_bytes=<40n>
  # w sums to exactly 1.0 over the full enumeration
```

### Persistence

WAL opcodes `0x20`–`0x2B` (`TwinWALCodec`, little-endian, u16-length-
prefixed strings, f32/f64 as bit patterns): `twinStreamOpen`,
`twinStreamState`, `twinRecordOpen`, `twinRecordSlice`, `twinRingsOpen`,
`twinRingsWrite`, `twinClockOpen`, `twinClockAdvance`, `twinGearOpen`,
`twinLayoutOpen`, `twinAlarmLoad`, `twinClose`. A malformed twin
payload decodes to `nil` and is skipped on replay, never fatal — a
following non-twin record still applies.

Snapshot **v7** adds a `TWIN` section (magic `"TWIN"` + `u32`
byteLength + sorted-keys JSON of `TwinState.Snapshot`) between the
WGTS lane section and the ENVS trailer; `save`/`load` default to no
twin state (length 0 / section ignored) unless a `TwinState` is
threaded through. Alarm sets persist **by reference** (path + sha256),
never their bytes; on restore a missing or hash-mismatched alarm file
drops that one entry with a stderr `WARN`, it does not refuse the
whole snapshot load — the gate path's stricter "wrong hash FAILS" rule
(`docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md` amendment 1) applies only to
`ALARM LOAD`'s live load path, not to restore.

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
`FRAME`/`COURT`/`SUCCESSOR`/`CORRUPT`. Writes, `EVAL`, nested
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
`reader`.

`bad_value` (added with the twin verbs, the interface phase): a non-finite
number, an out-of-[0,1] corruption knob, or a shape violation
(`RINGS OPEN`'s gear/rings/cells bounds, `BUDGET OPEN`'s ragged/NaN
cost table) — a validating front door catching what would otherwise
be a `precondition` trap. `reader` predates the twin verbs (a
reader-session-bound node-range check in `TRAVERSE`/`ANCESTRY`) but
was missing from this list.
