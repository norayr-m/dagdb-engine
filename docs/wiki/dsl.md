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
  → writes matching roots to shm, OK EVAL rows=<k> tick=<t>

VALIDATE
  → OK VALIDATE  |  FAIL VALIDATE <first-violation>
  # Edge violations first (bounds, self-loop, rank monotonicity,
  # duplicates). Then the rank bound:
  #   FAIL VALIDATE rank bound: <k> node(s) at or above maxRank <M>
  #     (first node <i> rank <r>, highest rank <h>)
  # Those nodes ARE computed — the line is how a pre-existing graph
  # restored under a smaller bound is caught without ticking.
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
  → OK SET_RANKS_BULK nodes=<N>
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

### TILED

Tiling, step one (roadmap item 8, branch `dag/tiling`, 2026-09-10,
built on `main`, not yet merged). Gate contract:
`docs/contracts/TILING_GATES_FROZEN.md` (T1–T6). **The TILED family is
NOT a twin registry** — despite the superficially similar
OPEN/…/STATUS/LIST/CLOSE shape, a `TiledGraphRouter` is never
persisted, never WAL-logged, and never part of a snapshot: the tile
directory on disk written by `SAVE TILED` IS the durable state, and
`TILED OPEN` only rebuilds an in-memory view of it. It parses at the
DSL top level (not through the twin verb dispatcher), routers live on
the daemon handler (not in `TwinState`), and its ids are `x%08x` from
a handler-local counter — a different shape from the twin registries'
single-letter prefixes, and unreachable through `dagdb_twin_list`/
`dagdb_twin_close`.

```
SAVE TILED <dir> <b1,b2,...>
  # Splits the daemon's OWN current engine (not a saved snapshot) into
  # tile files under <dir> by rank range. Boundaries are ascending
  # rank values, comma-separated, no spaces; at least one required.
  → OK SAVE TILED dir=<dir> tiles=<n> nodes=<N> crossings=<c>
  (empty/unsorted/duplicate boundaries → ERROR bad_value; guardPath
  failure or a write error → ERROR io)

TILED OPEN <dir> [<K>]
  # Opens a router over <dir>'s manifest.json (written by a prior SAVE
  # TILED). K = max resident tiles, default 2, checked 1...64. Loads
  # no tile bodies yet — those load lazily on first touch.
  → OK TILED OPEN id=x%08x tiles=<n> nodes=<N> resident_max=<K>
  (K out of range → ERROR out_of_range; missing/corrupt manifest →
  ERROR io)

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
    refused=<n> last=<error|none>

TILED LIST        → OK TILED LIST count=<n> [id@dir=... tiles=... nodes=... resident_max=... ...]
TILED CLOSE <id>  → OK TILED CLOSE id=<id> open=<n>
  # Nothing to flush — the tile directory on disk is already the
  # durable state.
```

**STATUS.** The daemon's own `STATUS` line carries `tiled_open=<n>`
alongside `twin_open=<n>` — open routers are counted separately and do
NOT add to `twin_open` (they aren't a twin registry entry).

**Reader allowlist.** `TILED BFS`, `TILED SELECT`, `TILED STATUS`, and
`TILED LIST` are read-only and permitted inside `READER <id> …`
(routers are daemon-global, like twin state, so a reader session may
query the same routers the primary path opened); `TILED OPEN`, `TILED
CLOSE`, and `SAVE TILED` mutate the router registry or the filesystem
and are forbidden there.

**Not done** (explicit "Not promised" list in the gate contract):
pre-fetch, ticking across tiles, the cold tier, thermal pauses, the
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
    rank=<int> cond=<d>
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

BANK GENERATE <id> <M>
  # shm in: f32 C[K*M] at offset 8, row-major K×M (C[k*M+m])
  # shm out: [u32 T*M][u32 4] header, then f32 W, T*M values row-major
  # (W[t*M+m])
  → OK BANK GENERATE id=<id> T=<T> M=<M> samples=<T*M> elapsed_ms=<f>
    (input 8+K*M*4 or output 8+T*M*4 past shm capacity → ERROR out_of_range)

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
  # rank/cond recomputed fresh on every call (~10 ms at 4096x160)

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

VIEW REFLEX <id> <S>   (1 <= S <= 8)
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
  # kept-set size k is predicted before any O(k^3) work; a result that
  # would exceed shm capacity is ERROR out_of_range before computing.
  # (bad rank/node/checkpoint args → ERROR out_of_range; any FOLD verb
  # before the first FOLD RUN → ERROR not_found)

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
    (missing file, sha mismatch, malformed/empty kernel array — every
    case → ERROR io: ...; a sha mismatch line always contains the
    literal phrase "sha256 mismatch")

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
    (n < 2 → ERROR bad_value; no warmup available and none given →
    ERROR bad_value; warmup >= n, or input past shm capacity →
    ERROR out_of_range; unknown id → ERROR not_found)

KERNEL INFO <id>
  → OK KERNEL INFO id=<id> path=<p> sha256=<hex> taps=<n> fs=<hz>
    window=<n> ears=<A>/<B> tau_a=<v|none> tau_b=<v|none>
    sigma=<v|none> warmup=<v|none> derived=<0|1>
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
twin state. All five FOLD verbs (branch `dag/fold-api`, 2026-09-10) —
`FOLD RUN`/`KEPT`/`SOURCE`/`TIER`/`INFO` — are allowed too, `RUN`
included: FOLD mints no id and touches no WAL, so even its "run" is a
pure read of the current lanes. And (branch `dag/kernels`, 2026-09-10,
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
`reader`.

`bad_value` (added with the twin verbs, the interface phase): a non-finite
number, an out-of-[0,1] corruption knob, or a shape violation
(`RINGS OPEN`'s gear/rings/cells bounds, `BUDGET OPEN`'s ragged/NaN
cost table) — a validating front door catching what would otherwise
be a `precondition` trap. `reader` predates the twin verbs (a
reader-session-bound node-range check in `TRAVERSE`/`ANCESTRY`) but
was missing from this list.
