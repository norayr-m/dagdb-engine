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

`body.dags` is exactly the existing DagDBSnapshot v3 format —
nothing new. The halos are slimmer (just the boundary nodes'
truth states + their node IDs). `meta.json` holds the
tile-to-tile edge lookup table.

Data root: still `~/dag_databases/` (per the persistence policy).
Tiled graphs are subdirectories under it; the guardPath() check
is unchanged.

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

BFS from a seed node:

1. Start at the seed's tile. Run `bfsDepthsBackward` inside the
   tile, bounded by `depth` or tile boundary.
2. If frontier reaches the tile boundary and `depth` is not
   exhausted, write unresolved frontier to a queue with
   continuation markers (target tile IDs).
3. Load the next tile (evict current if memory pressure; keep
   depth vector in a compressed sparse representation on disk).
4. Resume BFS in the new tile, using the continuation queue as
   the initial frontier.
5. Repeat until queue drains or `depth` is exhausted.

Output format becomes sparse `(node_id, depth)` pairs already
used by `ANCESTRY` — scales with reachable set size, not with
global N.

`SIMILAR_DECISIONS` and distance metrics:
- `Jaccard`, `WL-1 histogram`, `rankL1`, `rankL2` — all
  decomposable across tiles via inclusion-exclusion on
  rank-disjoint shards. Approximately exact.
- `boundedGED` — scales with subgraph size, not global N. Safe.
- `spectralL2` via dense Laplacian — **not** decomposable.
  Would need Nyström or random-projection sketches at scale.
  Research-grade, not in this spec.

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
