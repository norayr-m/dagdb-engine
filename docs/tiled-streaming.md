# Tiled streaming for DagDB — 10^11 nodes on one M5 Max

> **Forward-looking architecture spec.** Describes a build path,
> not a shipped feature. Nothing in this doc is yet implemented
> in the engine.
>
> **Amateur engineering project.** Reasoning follows from one
> existence proof (Savanna) and one codebase (DagDB). Numbers are
> design estimates, not measurements. Errors likely. Don't ship
> this as truth until it's been built and run.

## 1. Why — and why "tiled streaming", not "federation"

Original reading: to go past a single M5 Max UMA ceiling (~10⁹
nodes) you need a federation of engines across multiple boxes.
That reading is wrong, and Savanna already disproved it on this
very hardware: **100 billion cells, 9 hours of wall time, 500 GB
state file, one M5, GPU thermal ceiling hit (display blackouts).**
Single box.

The trick Savanna uses — and DagDB needs to inherit — is **tiled
streaming**: at any moment only the hot working-set sits in UMA;
the rest lives as cold files on NVMe and is paged in on demand.
The "tile" is an addressable sub-region of the global graph; the
"halo" is a 3-cell-deep ghost zone each tile loads from its
neighbors so boundary cells can sense across tile edges.

Scaffolding for this already exists in the DagDB tree, ported
from Savanna:

- `dagdb/Sources/DagDB/TileHalo.swift` — `HaloEdge` (NSEW), the
  `HaloStrip` struct (entity/energy/ternary/gauge/orientation/
  scents) and the disk I/O (`writeHalos` / `readHalos` +
  `loadAdjacentHalos`). Today it carries Savanna's fields, not
  DagDB's. Same file-format pattern will work for DagDB fields.
- `dagdb/Sources/DagDB/GPUDecoder.swift` — GPU-side buffer
  decoding, extensible to per-tile layouts.
- `dagdb/Sources/DagDB/SimRecorder.swift` + `SimRecorder+Archive.swift`
  — time-series snapshot/playback plumbing, which the tile-streaming
  loop would reuse for checkpoint/restore.

This spec is **not a build**. It's the written contract for
what the port looks like and which DagDB invariants make the
port clean or dirty.

## 1.5 Scale regimes — when to tile, when not to

Don't build tile machinery for workloads that fit a single
engine. Three regimes, with clean decision criteria:

| Regime | Node count | Footprint (v3, 42 B/node) | Action |
|---|---|---|---|
| **Toy / dev** | ≤ 10⁶ | ≤ 42 MB | Default `--grid`. Nothing to do. |
| **Near-term production** (hepatocyte target) | 10⁶ – 10⁸ | 42 MB – 4.2 GB | Single engine, larger `--grid`. No tiling. Fits UMA comfortably, leaves most of 128 GB free. Savanna routinely runs **10⁸ cells LIVE** on this hardware (reported 2026-04-21); DagDB's per-node footprint is ~2× Savanna's (rank + LUT add bytes), so 10⁸ DagDB is ~4 GB UMA and still comfortable. |
| **Single-tile ceiling** | 10⁸ – 10⁹ | 4.2 GB – 42 GB | Single engine, max grid. Still no tiling, but you've consumed a third of UMA — thermal discipline matters if you tick continuously, WAL paranoid. |
| **Tile-required** (stretch target) | 10⁹ – 10¹¹ | 42 GB – 4.2 TB | Tiled streaming. This spec applies. |
| **Beyond tile-required** | > 10¹¹ | > 4.2 TB | Out of scope for M5. Needs distributed story. |

Decision points:

- **Below 10⁹ nodes: single engine is right.** The 10⁷ hepatocyte
  target (the near-term pin) lives here. Tiling it would be
  adding complexity without unlocking capacity. The entire graph
  is hot; no paging benefit.
- **Savanna's 10⁸-live proof is load-bearing for this tier.** Same
  M5 Max, same Metal dispatch pattern, same Morton / 7-coloring
  machinery. If Savanna ticks 10⁸ cells continuously, DagDB can
  hold 10⁸ nodes — our only additional cost is the extra rank +
  LUT bytes, which is a constant factor and doesn't change the
  regime.
- **10⁹–10¹⁰: judgment call.** A single engine technically fits,
  but the GPU tick becomes thermally expensive on long runs and
  any WAL replay at this scale is slow. Tiling starts paying off
  for resilience, not just capacity.
- **Above 10¹⁰: tile or die.** The engine tick kernel saturates
  GPU bandwidth, NVMe becomes the durability path whether you
  want it or not. Tile streaming is cheaper than fighting the
  hardware.

Note on DagDB vs Savanna load character: Savanna's 10⁸ is a
**live tick** workload (full engine tick every frame). DagDB's
typical load is event-driven (ticks on demand, not continuously).
So DagDB at 10⁸ is less thermally stressed than Savanna at 10⁸
in equivalent fields — holding 10⁸ nodes is cheaper than ticking
them 60× a second.

Implication for Pass 2 of the rank-widening sprint: the 10⁷ hepatocyte
workload runs on today's engine. No spec-dependency. The spec
below is for the stretch target only.

## 2. The rank-monotone invariant makes tiling almost-free

DagDB has one hard invariant: `rank(src) > rank(dst)` on every
edge. The graph is a DAG; rank is the topological-order index.

**Tile the graph by rank ranges.** Partition `[0, maxRank]` into
ordered tile-intervals `[R₀, R₁), [R₁, R₂), …`. Every edge
`u → v` has `rank(u) > rank(v)` by the invariant, so:

- If both `u` and `v` are in the same tile's range, the edge is
  **intra-tile**.
- If they're in different tiles, the edge goes from a
  higher-range tile to a lower-range tile — **always in one
  direction.** Tiling respects the DAG structure.

Cross-tile edges live in the "halo" strip at the tile boundary
(analogous to Savanna's NSEW halo — here it's a one-direction
halo: each tile exposes the nodes it writes, the lower-rank tile
reads them as ghost-source inputs).

Implication: **cross-tile edges never form cycles**, because
they inherit rank monotonicity. The router never has to detect
cycles while stitching tiles.

## 3. Which buffers are paged, which stay resident

Per node today, DagDB tracks:

| Field | Bytes | Access pattern | Paging decision |
|---|---|---|---|
| `rank` (u64) | 8 | Read every tick (dispatch gate) | **Hot** — resident |
| `truth` (u8) | 1 | Read + write every tick | **Hot** — resident |
| `nodeType` (u8) | 1 | Read rarely (validation/EVAL) | Warm |
| `lut6Low/High` (u32×2) | 8 | Read every tick (gate eval) | **Hot** — resident |
| `neighbors` (i32 × 6) | 24 | Read every tick | **Hot** — resident |
| `edgeWeights` (f32 × 6) | 24 | Weighted mode only | Cold unless weighted |
| Secondary index | varies | Rare (SELECT / hive queries) | Cold, page on demand |

Hot footprint per node: ~42 B (rank + truth + LUT + neighbors).
UMA ceiling 128 GB → ~3 × 10⁹ nodes can be hot *simultaneously*.
The rest sit cold.

**Tile size target: 10⁹ nodes resident = ~42 GB**. Leaves ~85 GB
free for OS, Metal driver, WAL buffers, and the paging
machinery. Two tiles resident at a time (active + pre-fetching
next) fits.

## 4. Tile file format (inherits TileHalo pattern)

Each tile lives on disk as a directory:

```
~/dag_databases/<graph>/tile_<R_lo>_<R_hi>/
├── body.dags          # full v3 snapshot body for the tile
├── halo_lower.bin     # nodes on the boundary exposed to the
│                      #   next-lower-rank tile (read-only to it)
├── halo_upper.bin     # nodes incoming from the next-higher-rank
│                      #   tile (read as source values only)
└── meta.json          # tile bounds, rank range, node-count,
                       #   cross-tile edge map, version
```

### 4.1 `body.dags` layout

Unchanged from the current `DagDBSnapshot` v3 format:

```
offset  bytes  field
0       4      magic "DAGS"
4       4      u32 version = 3
8       4      u32 nodeCount (tile-local)
12      4      u32 gridW  (tile-local)
16      4      u32 gridH  (tile-local)
20      4      u32 tickCount
24      4      u32 flags (bit 0 = zlib-compressed body)
28      4      u32 bodyBytes (on-disk)
32      8*N    rank  buffer  (u64 per node)
        N      truth buffer  (u8 per node)
        N      type  buffer  (u8 per node)
        4*N    lut6Low       (u32 per node)
        4*N    lut6High      (u32 per node)
        24*N   neighbors     (6 × i32 per node — tile-LOCAL node IDs)
```

Tile-local IDs. Global node IDs are reconstructed at the router
layer as `(tile_id, local_id)` → `u64 global_id`. Neighbour
indices that cross tile boundaries are stored as the sentinel
`-2` (distinct from `-1` = no edge) and the meta.json maps slot
→ (foreign_tile_id, foreign_local_id).

### 4.2 `halo_lower.bin` / `halo_upper.bin` layout

Slim strip of boundary state exposed to an adjacent tile:

```
offset  bytes  field
0       4      magic "DAHA"
4       4      u32 version = 1
8       4      u32 strip_kind (0 = lower, 1 = upper)
12      4      u32 nodeCount (nodes on this boundary)
16      8      u64 source_tile_id  (the tile that wrote this strip)
24      8      u64 target_tile_id  (the tile meant to read this strip)
32      8      u64 tick_epoch      (which tick cycle this strip belongs to)
40      16*N   per-boundary-node: u64 local_id + u8 truth + u8 type + 6 pad
```

`tick_epoch` is the load-bearing field for crash correctness
(see §7.2). A stale halo strip is easy to detect: its epoch
doesn't match the router's current epoch. The router refuses
to tick tile A against a halo_lower/halo_upper whose
`tick_epoch` is older than A's own last-ticked epoch.

### 4.3 `meta.json` shape

```json
{
  "format": "dagdb-tile-meta",
  "version": 1,
  "tile_id": 7,
  "rank_lo": 1000000,
  "rank_hi": 1999999,
  "node_count_local": 100000,
  "crossings_out": [
    {"local_slot": [dst_local_id, slot_index],
     "foreign": [foreign_tile_id, foreign_local_id]}
  ],
  "crossings_in": [
    {"foreign_tile_id": 6,
     "exposes_boundary_count": 350}
  ],
  "last_persisted_tick_epoch": 42
}
```

`crossings_out` is the list of neighbour-slot entries that
used sentinel `-2` in the body — tells the router "when
loading tile 7, for these boundary nodes go consult those
foreign tiles". `crossings_in` is the symmetric "here's who
expects my halo strips". Both are sorted by (foreign_tile_id,
foreign_local_id) for binary-search lookup at hot path.

### 4.4 Data root

Still `~/dag_databases/` per the persistence policy. Tiled
graphs are subdirectories; `guardPath()` is unchanged.
Individual tile dirs inherit the 0700 parent mode.

## 5. Metal kernel dispatch across tiles

Per tick, the active tile dispatches its Metal kernel on its own
`rank[]`, `truth[]`, `lut[]`, `neighbors[]` buffers — **no
changes to the shader**. The shader already processes one
rank-range at a time (7-colouring within a rank). As long as one
tile is resident, one tick of its rank range is a standard
engine tick.

Cross-tile data flow happens at tile boundaries, outside the
shader:

1. When tile A (lower ranks) ticks, it reads truth values from
   the halo_upper file of tile B (the upper-rank neighbor tile)
   for any edge whose source is in B and destination is in A.
   These halo values are staged into A's neighbor-truth cache
   before A's tick starts.
2. Tile A writes its own halo_lower after tick, for
   consumption by the next-lower tile at its tick time.

A full "world tick" sweeps high-rank tile first, then lower
tiles, because rank-monotonicity means high-rank tile's outputs
are the low-rank tile's inputs. This matches DagDB's
leaves-up (high-rank → low-rank) tick order already implemented
in `DagDBEngine.tick`.

## 6. BFS, ancestry, similarity across tiles

### 6.1 Cross-tile BFS — continuation queue

At BFS frontier-crosses-tile-boundary, push a continuation
record to a bounded-memory queue rather than expand the frontier
in place:

```swift
struct BFSContinuation {
    let foreignTileId: UInt64
    let foreignLocalId: UInt32
    let depthSoFar: UInt32     // distance from original seed
    let parentGlobalId: UInt64 // for path reconstruction
}

actor CrossTileBFS {
    private var queue: [BFSContinuation] = []  // FIFO by tile
    private var visited: Set<UInt64> = []      // global IDs
    private var output: [(nodeId: UInt64, depth: UInt32)] = []
    private let maxDepth: UInt32
    private weak var router: TiledGraphRouter?

    func walk(seed: UInt64) async throws -> [(UInt64, UInt32)] {
        enqueue(BFSContinuation(
            foreignTileId: router!.tileOf(seed),
            foreignLocalId: router!.localIdOf(seed),
            depthSoFar: 0,
            parentGlobalId: seed
        ))
        while let batch = drainBatchForNextTile() {
            let tile = try await router!.load(tileId: batch.tileId)
            let (reachedLocally, exits) = tile.runBoundedBFS(
                seeds: batch.localIds,
                depthBudget: maxDepth - batch.depthSoFar
            )
            recordReached(reachedLocally, tileId: batch.tileId,
                          depthOffset: batch.depthSoFar)
            exits.forEach { enqueue(BFSContinuation(
                foreignTileId: $0.targetTile,
                foreignLocalId: $0.targetLocal,
                depthSoFar: $0.depthFromSeed,
                parentGlobalId: $0.parentGlobal
            )) }
        }
        return output
    }
}
```

**Queue bound**: sort by `foreignTileId` so one tile-load
drains a whole batch. Typical frontier at depth d ≈ fanout^d.
At fanout 6 and depth 10: 6¹⁰ ≈ 60 M entries × 24 B each =
~1.4 GB. Fits UMA. At depth 15: 6¹⁵ ≈ 470 G entries — doesn't
fit. For practical DagDB queries, cap `maxDepth` at 12
(saturates at ~10 G entries in the queue worst case, which
spills to disk). Beyond that, BFS is the wrong primitive —
use rank-range SELECT.

### 6.2 Ancestry and similarity

`ANCESTRY` is BFS-backward-only, same continuation pattern
above with inputs-only neighbour expansion.

`SIMILAR_DECISIONS` and distance metrics:

- `Jaccard`, `WL-1 histogram`, `rankL1`, `rankL2` — all
  decomposable across tiles via inclusion-exclusion on
  rank-disjoint shards. Approximately exact. Run the metric
  per-tile, combine pairwise.
- `boundedGED` — scales with subgraph size, not global N.
  Safe.
- `spectralL2` via dense Laplacian — **not** decomposable.
  Would need Nyström or random-projection sketches at scale.
  Research-grade, not in this spec.

## 6.5 `TiledGraph` Swift signature

The minimum-viable Swift API for the router:

```swift
public actor TiledGraphRouter {
    // — public surface —
    public init(dataRoot: String, graphName: String) async throws
    public func status() async -> TiledStatus
    public func save() async throws
    public func close() async throws

    // — routing primitives (used by DSL + MCP) —
    public func runQuery(_ dsl: String) async throws -> String
    public func runBFS(seed: UInt64, depth: UInt32,
                       backward: Bool) async throws
                       -> [(UInt64, UInt32)]
    public func runAncestry(node: UInt64, depth: UInt32) async throws
                       -> [(UInt64, UInt32)]
    public func runSelect(truth: UInt8, rankLo: UInt64,
                          rankHi: UInt64) async throws -> [UInt64]

    // — tile-resident queries (short-circuit when seed's tile is hot) —
    public func tileOf(_ globalId: UInt64) -> UInt64
    public func localIdOf(_ globalId: UInt64) -> UInt32

    // — resident-set management —
    private func load(tileId: UInt64) async throws -> ResidentTile
    private func evict(tileId: UInt64) async throws
    private func preFetch(tileId: UInt64)   // async, fire-and-forget
}

struct ResidentTile {
    let id: UInt64
    let engine: DagDBEngine       // full DagDB engine, tile-local
    let meta: TileMeta            // from meta.json
    let upperHalo: HaloStrip      // read-only; source values from rank+1 tile
    var lowerHalo: HaloStrip      // owned; exposes our boundary to rank-1 tile
    var dirtyBuffers: Set<TileBuffer>  // for selective flush
    var lastTickEpoch: UInt64
}

struct TileMeta: Codable { … }  // matches meta.json shape above

enum TileBuffer { case rank, truth, nodeType, lut, neighbors, halo }
```

Router is `actor`-isolated so the single-threaded daemon
serialization discipline extends naturally: one router
method runs at a time, and within it the actor switches
serve async load/evict without interleaving with queries.

Two tiles resident at a time (active + pre-fetch) is the
design budget. The router tracks tiles by `id`, maps
`globalId → tileId` in constant time from the high bits of
the u64 global ID (tile_id is top 24 bits, local_id is
bottom 40 — gives 16 M tiles × 1 T local IDs).

## 6.6 NVMe bandwidth math — can tile streaming keep up?

M5 Max specs (rounded):

| Resource | Bandwidth |
|---|---|
| UMA (LPDDR5X) | ~400 GB/s |
| Internal SSD (NVMe) read | ~7 GB/s |
| Internal SSD (NVMe) write | ~7 GB/s |

Ratio: **UMA is ~57× faster than NVMe**. For tile streaming
to not dominate wall time, tile ticks must be slow enough that
pre-fetch completes before the next tile is needed.

### 6.6.1 Tile-swap time

At the design budget of 10⁹ nodes resident per tile (~42 GB
hot footprint):

- Write dirty tile to NVMe: 42 GB ÷ 7 GB/s = **6.0 s**
- Read next tile from NVMe: 42 GB ÷ 7 GB/s = **6.0 s**
- Total tile-swap: **12 s** (or 6 s if pre-fetch overlaps the
  current tick)

### 6.6.2 Tick budget per tile

A single Metal tick of 10⁹ nodes on M5 Max is estimated from
the 1 M-node baseline (one tick ~2 ms scaled linearly):

- Naive linear scale: 1 M nodes × 2 ms = 2 ms per tick;
  1 G nodes × 2 ms = **~2 s per tick**.
- Non-linear (memory bandwidth bound): Savanna's 100 B-cell
  run, 9 hours, suggests ~0.3 μs/cell/tick — so 1 G nodes ×
  0.3 μs = **~300 ms per tick**, an order of magnitude faster
  than the naive scale. Savanna is simpler per-node, so DagDB
  would be slower — call it **0.5–2 s per tick** at 10⁹.

### 6.6.3 Conclusion

Pre-fetch (~6 s per hop) is **slower than one DagDB tick
(~0.5–2 s)**. Tile streaming is NVMe-bound at the single-tile
resident scale. That's fine as long as:

1. World ticks don't require tile swaps every tick. At 10⁹
   nodes resident fitting one tile, there's nothing to swap
   for a single-tile-resident workload.
2. At 10¹⁰ nodes, we'd have ~10 tiles; a world tick means
   10 swaps × 6 s = 60 s just for paging, plus 10 × 0.5–2 s
   for the actual ticks. Tick dominated by paging.
3. At 10¹¹ nodes, 100 tiles per world tick. Paging budget
   = 100 × 6 s = 600 s = 10 minutes per world tick just on
   NVMe. GPU tick adds another ~3 minutes. Savanna's 9-hour
   run had ~50 M cells/sec — DagDB at 10¹¹ nodes would match
   if one world tick is the unit, and a workload that
   ticks < 1× per hour is natural for liver-scale biology.

**Bottom line**: tile streaming is viable at 10¹⁰–10¹¹ with
minute-scale world-tick latency. For interactive queries
(BFS, ancestry, SELECT) that only need one or two tiles
hot, latency is much lower: seed-tile already resident →
instant; one hop to an adjacent tile → 6 s pre-fetch +
query cost. Fine for analytical workloads; not fine for
per-second ingestion of 10¹¹-scale graphs.

## 7. Page-in / page-out policy

Kept deliberately simple:

- **Active tile**: one tile fully resident on UMA.
- **Pre-fetch**: the next-lower-rank tile is streamed in on a
  background thread while the active tile ticks. Hides the NVMe
  latency.
- **Eviction**: after a world tick completes, the oldest tile
  is flushed to its `body.dags` on NVMe. Dirty-bit tracking
  per-buffer (rank rarely dirty; truth always dirty; LUT/
  neighbors rarely dirty) minimises unnecessary writes.
- **Cold tier**: tiles not touched in the last K world ticks
  can be moved to a colder store (local NAS / external SSD /
  object storage). Not needed for the 10¹¹-on-laptop target;
  cold is just "not in UMA, still on NVMe".

Thermal discipline:

- GPU thermal blackouts are real on M5 at full utilisation (per
  the 9-hour live-sim run). Design assumption: after K minutes of
  full tick load, enforce a cool-down tick pause. Parameterise
  K empirically. Don't fight the thermals, yield to them.

### 7.1 Dirty-bit tracking (which buffers actually need flushing)

After a tile ticks, typically only `truth[]` changes. `rank`,
`lut6Low/High`, `neighbors`, `nodeType` are stable structural
data — they rarely change outside explicit mutation commands
(`SET_RANK`, `SET_LUT`, `CONNECT`, `CLEAR EDGES`).

`ResidentTile.dirtyBuffers: Set<TileBuffer>` tracks which
buffers the engine has actually mutated since last flush.
Eviction flushes only those buffers (re-writing `body.dags`
as a partial-patch on the stable-field prefix — new format
version `v3-patch` or similar, decided at build time).

Savings: at 10⁹ nodes, a tick-only flush writes just the 1 GB
`truth` buffer instead of the full 42 GB body. 6× fewer NVMe
cycles, 6× less thermal load on sustained runs.

### 7.2 Crash-mid-swap semantics

The hard correctness case: power loss or OOM kill during an
active tile flush. We need either the pre-flush state or the
post-flush state durable; never a half-written `body.dags`.

The rules:

- **Write-ahead log per tile.** Before a tile's flush begins,
  write a `TILE_FLUSH_BEGIN <tile_id> <epoch>` record to the
  tile's WAL. On flush complete, write `TILE_FLUSH_COMMIT
  <tile_id> <epoch>`. A crash between the two means the
  flush didn't finish.
- **Atomic body.dags replacement.** Same discipline as
  single-engine DagDB: write to `body.dags.tmp`, F_FULLFSYNC,
  rename, dir fsync. Reuses the existing `DagDBSnapshot.save`
  implementation.
- **Tile-epoch authority lives in meta.json.** The router
  reads `meta.json.last_persisted_tick_epoch` on load. If that
  matches the `body.dags`'s stored `tickCount`, the tile is
  consistent. If `meta.json` claims epoch N+1 but the body
  says epoch N, the flush crashed mid-way; the router rejects
  the load and replays from the per-tile WAL.
- **Halo strips are epoch-tagged.** A halo_lower/halo_upper
  file whose `tick_epoch` doesn't match the reader-tile's
  `last_persisted_tick_epoch + 1` is stale. The router
  regenerates stale halos before ticking the downstream tile.

Worst case on crash: lose one world-tick's worth of
propagation (the one that was mid-flush). Recover by
re-running the interrupted tile tick; rank monotonicity
guarantees no duplicate state.

**What we don't promise**: surviving simultaneous crashes of
both the source and target tile of a halo. If tile A is
mid-flush AND tile B's halo_lower is also mid-write, both are
rebuilt from rank.bin / lut.bin (stable-field) plus replay of
truth.bin updates from WAL. Slower recovery but correct.

### 7.3 Multi-tile durability — the "backup chain" analogue

The existing single-engine `BACKUP INIT / APPEND / RESTORE /
COMPACT / INFO` chain works per-tile. Tile backup chains are
independent — a crash in tile 5 doesn't corrupt tile 7's
backup. Operator-facing: `BACKUP TILED <dir>` creates a
backup directory that fan-outs per-tile.

Reusing the existing XOR-diff semantics (single-bit mutation
produces < 5 % diff size) means incremental tiled backups
are cheap even at 10¹¹ scale — most tiles don't change
between snapshots, so the diff chain is sparse.

## 8. What this spec doesn't commit to

- **Distributed / federated tiles across machines.** Out of
  scope. Single-box story only, as per current scope.
- **Wide-u64 node indices inside the engine buffer.** Current
  i32 neighbors are fine within one tile (single tile ceiling
  is ~10⁹ nodes on M5, well under i32 range). Global node
  addressing uses the existing `(tile_id, local_node_id)` pair,
  encoded as u64 for shm / DSL / snapshot metadata only.
- **Automatic rank-range selection.** First cut: operator
  supplies rank-range bounds for each tile. Heuristic
  auto-tiling is a later enhancement.
- **Live mutation across tile boundaries.** First cut: writes
  stay within the active tile; cross-tile ingestion is a batch
  operation (rebuild halos, not incremental).

## 9. Order of operations to build this (rough)

1. Port `TileHalo.swift` from Savanna fields to DagDB fields.
   Re-use the file-format pattern; replace the struct members
   with `rank, truth, nodeType, lut6Low/High, neighbors`.
2. Add a `TiledGraph` type that wraps one or more `DagDBEngine`
   instances bound to rank ranges, with a router that chooses
   which engine handles which query.
3. Teach `DagDBSnapshot.save` / `.load` about tile directories
   (new verb: `SAVE TILED <dir>`).
4. Extend `bfsDepths` with a continuation-queue variant for
   cross-tile walks.
5. Wire the pre-fetch thread behind the active-tile tick loop.
6. Run the equivalent of Savanna's 100-billion-cell test on a
   DagDB target. Collect wall time, file size, thermal profile,
   compare to Savanna's baseline.

Each step is a separate engineering pass. None of it ships this
week. This doc is the map.

## 10. Open questions

- Exact tile-size vs throughput curve on M5 — untested.
  Savanna's single data point (100B cells, 9 hr, 500 GB) is
  suggestive but was a simulation workload, not a query
  workload. DagDB's tick pattern (leaves-up per world tick) may
  exhibit different UMA / NVMe bandwidth ratios.
- Whether the WAL can be tile-local (one WAL per tile) or must
  stay global (one WAL across all tiles). Tile-local is simpler
  for crash recovery but costs replay-order reconstruction.
- Whether secondary index (TruthRankIndex) can go per-tile or
  must stay global. Per-tile is memory-cheap; global is
  query-cheap but doesn't stream.
- Whether BFS continuation-queue state itself needs paging.
  At depth `d` on a graph with fanout `f`, frontier can hit
  `f^d`. For worst-case `f=6`, `d=10` gives ~60 M nodes in the
  queue — still fits UMA. At `d=15` it doesn't. Unclear
  whether DagDB workloads will ever want `d>10`.

## 11. How this relates to the u64 refactor

The u64 rank widen (shipped today, `DagDBSnapshot` v3) is the
prerequisite for addressing rank values that span across a
billion-node tile. Without it, tile ranks would have to stay
under 4.3 × 10⁹ across the entire graph — which caps the 10¹¹
target by construction. With u64 rank, tiles can freely
allocate their own non-overlapping rank windows anywhere in the
u64 space. So: Phase 1 of u64 was necessary. Phase 2 (neighbor
widening) is NOT necessary for this spec, because neighbor IDs
are tile-local and each tile lives under its own node count.

## 12. Standing charge

This spec is internal. No public wiki page, no README mention,
no Pub-staging. If we build to this spec and the build passes
an honest benchmark, we publish what the benchmark showed, not
what the spec claimed. Numbers speak. Ego doesn't.

If anything here turns out to be wrong when built, the spec
itself is stale; the build is the source of truth.

— `dag-2026-04-21-01`
