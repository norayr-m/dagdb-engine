/// TiledGraphFiles — the tile file writer/reader (layout
/// `docs/tiled-streaming.md` §4, except that `body.dags` is the CURRENT
/// `DagDBSnapshot` format, not a frozen v3).
///
/// Splits one `TiledFixture.Object` into tile directories by rank range:
/// `<dataRoot>/<name>/tile_<lo>_<hi>/{body.dags, halo_lower.bin,
/// halo_upper.bin, meta.json}` plus a graph-level `manifest.json`.
///
/// Edge direction note (frozen by the fixture's own draw order, see
/// `TiledFixture.generate`, as corrected): a node `u`'s
/// neighbour slots hold references to strictly HIGHER-rank nodes (its
/// inputs, the engine's own convention — `rank(src) > rank(dst)`). Given
/// rank-ascending tile numbering (`tileOf(rank)` increases with rank), a
/// cross-tile reference always runs from `u`'s tile UP to a numerically
/// higher-or-equal tile — never downward. `crossingsOut` is recorded on
/// the *referencing* (lower-rank) tile; `crossingsIn` is the mirror entry
/// on the *referenced* (higher-rank) tile. `halo_upper.bin` (kind 1)
/// caches the referenced foreign nodes' values for the referencing tile
/// to read without loading the foreign tile (§4.2's "the foreign boundary
/// nodes this tile references"); if a tile's crossings span more than one
/// foreign tile (the "far" 3-ring draw can, on narrow tilings, skip more
/// than one tile), `source_tile_id` names the most-referenced foreign
/// tile — the halo file is a cache, not the source of truth
/// (`manifest.json` / `meta.json` crossings are).
import Foundation
import Metal

public enum TiledGraphFiles {

    // MARK: - Manifest types

    public struct TileEntry: Codable, Equatable {
        public let id: UInt32
        public let rankLo: UInt64
        public let rankHi: UInt64
        public let nodeCount: UInt64
        public let bodySHA256: String
        public let crossingsOut: [Crossing]
        public let crossingsIn: [Crossing]
        /// `engineIndexOf[localId]` = this node's index in the ORIGINAL
        /// untiled engine's own buffers
        /// (`TiledGraphRouter.truthArray`'s index-order requirement) — the
        /// inverse of `WriteReport.globalOf`, persisted so a router
        /// re-opened without the original in-memory `WriteReport` can
        /// still reconstruct untiled order. Defaulted to `[]` only so the
        /// memberwise init keeps compiling for any caller that builds a
        /// `TileEntry` by hand without it (no on-disk manifest in this
        /// repo predates this field, so the JSON-decode path always finds
        /// it present); every `TileEntry` `write` itself emits populates
        /// it from `membersByTile[t]`, which is already exactly this
        /// array — see that function's local var.
        public let engineIndexOf: [UInt64]
        /// This tile's own last-flushed world epoch (per-tile epochs, no
        /// graph-level counter). Set to the daemon's own tickCount at `SAVE TILED`/
        /// `write` time (0 for every `TiledFixture.Object` — the fixtures
        /// carry no tick history — and for any manifest written before tiled
        /// ticking, default on decode); rewritten to the flushed epoch by every
        /// tile flush, atomically, before that flush's COMMIT. The
        /// router's own notion of "the world's epoch" is the (min, max)
        /// over every tile's `tickEpoch` — see `TiledGraphRouter`'s
        /// `TiledStatus.epochMin`/`epochMax`.
        public let tickEpoch: UInt64

        public init(
            id: UInt32, rankLo: UInt64, rankHi: UInt64, nodeCount: UInt64,
            bodySHA256: String, crossingsOut: [Crossing], crossingsIn: [Crossing],
            engineIndexOf: [UInt64] = [], tickEpoch: UInt64 = 0
        ) {
            self.id = id
            self.rankLo = rankLo
            self.rankHi = rankHi
            self.nodeCount = nodeCount
            self.bodySHA256 = bodySHA256
            self.crossingsOut = crossingsOut
            self.crossingsIn = crossingsIn
            self.engineIndexOf = engineIndexOf
            self.tickEpoch = tickEpoch
        }
    }

    public struct Manifest: Codable, Equatable {
        public let format: String
        public let version: Int
        public let name: String
        public let boundaries: [UInt64]
        public let globalNodeCount: UInt64
        public let tiles: [TileEntry]

        public init(
            format: String, version: Int, name: String, boundaries: [UInt64],
            globalNodeCount: UInt64, tiles: [TileEntry]
        ) {
            self.format = format
            self.version = version
            self.name = name
            self.boundaries = boundaries
            self.globalNodeCount = globalNodeCount
            self.tiles = tiles
        }
    }

    public struct BoundaryCount: Equatable {
        public let lower: UInt32
        public let upper: UInt32
        public let down: Int
        public let up: Int

        public init(lower: UInt32, upper: UInt32, down: Int, up: Int) {
            self.lower = lower
            self.upper = upper
            self.down = down
            self.up = up
        }
    }

    public struct WriteReport: Equatable {
        public let tiles: Int
        public let nodes: Int
        public let crossings: Int
        /// `perBoundary`'s `up`/`down` count only the
        /// crossings whose remote tile is exactly `k + 1`, while this
        /// file's own header says a 3-ring draw can skip more than one
        /// tile and `crossings` counts every one. The gap would be a SILENT
        /// undercount in `perBoundary`; it is counted and reported here
        /// instead — `crossings == sum(perBoundary.up) + crossingsSkippingATile`
        /// is an identity, and a tiling with a tile-skipping edge makes
        /// `sum(perBoundary.up) < crossings` observable.
        public let crossingsSkippingATile: Int
        public let perBoundary: [BoundaryCount]
        public let bytesPerTile: [Int]
        public let writeMsPerTile: [Double]
        public let globalOf: [UInt64]
        /// Over an existing world, the old directory is renamed
        /// aside and removed after the new one landed; when that removal fails
        /// its path is here (the save stands; SAVE TILED's reply names it).
        public var oldWorldLeft: String? = nil
    }

    public struct LoadedTile {
        public let engine: DagDBEngine
        public let meta: TileMeta
        public let leftoverTemp: Bool
    }

    public enum FilesError: Error, CustomStringConvertible {
        case manifestMissing(String)
        case manifestDecode(String)
        case tileEntryMissing(UInt32)
        case metaDecode(String)
        /// `write` refuses a live engine whose
        /// `backEdgeSrcs`/`backEdgeDsts` contains an edge whose two ends
        /// fall in different tiles under the given boundaries — checked
        /// BEFORE any directory is created, so a refused `SAVE TILED`
        /// leaves nothing on disk. `src`/`dst` are the ENGINE node indices
        /// (not `GlobalNodeID`s — the graph was never split, so there is
        /// no tile assignment to encode them with).
        case crossTileBackEdge(src: UInt32, dst: UInt32)
        /// `manifest.json`'s own `format`/`version` fields, stamped by
        /// `write`, are read back: unread, any format string and any version
        /// would decode with the v1 layout.
        case manifestFormatUnsupported(found: String, expected: String)
        case manifestVersionUnsupported(found: Int, expected: Int)
        /// A `crossingsIn` entry naming a local id at or
        /// past the tile's own node count — an out-of-bounds Metal-buffer
        /// read written straight into the parity strip.
        case crossingLocalOutOfRange(tile: UInt32, local: UInt64, nodeCount: Int)
        /// The body's `-2` cross-tile slot count for a
        /// local and the number of `crossingsOut` entries `meta.json` lists
        /// for that same local are two independent file-derived numbers.
        /// More slots than crossings would trap; fewer would wire the graph
        /// wrong and leave a sentinel in place.
        case crossingSlotCountMismatch(tile: UInt32, local: UInt64, slots: Int, crossings: Int)

        public var description: String {
            switch self {
            case .manifestMissing(let p): return "TiledGraphFiles: manifest not found at \(Reply.quoted(p))"
            case .manifestDecode(let e): return "TiledGraphFiles: manifest decode failed: \(e)"
            case .tileEntryMissing(let id): return "TiledGraphFiles: tile \(id) not present in manifest"
            case .metaDecode(let e): return "TiledGraphFiles: meta.json decode failed: \(e)"
            case .crossTileBackEdge(let src, let dst):
                return "TiledGraphFiles: back edge crosses a tile boundary (\(src)→\(dst))"
            case .manifestFormatUnsupported(let found, let expected):
                return "TiledGraphFiles: manifest format \(Reply.quoted(found)) is not '\(expected)'"
            case .manifestVersionUnsupported(let found, let expected):
                return "TiledGraphFiles: manifest version \(found) is not the only version this "
                    + "reader knows (\(expected))"
            case .crossingLocalOutOfRange(let tile, let local, let n):
                return "TiledGraphFiles: tile \(tile) lists a crossing at local id \(local), "
                    + "at or past its own node count \(n)"
            case .crossingSlotCountMismatch(let tile, let local, let slots, let crossings):
                return "TiledGraphFiles: tile \(tile) local \(local) has \(slots) cross-tile (-2) "
                    + "slot(s) in body.dags but \(crossings) crossingsOut entr(ies) in meta.json"
            }
        }
    }

    // MARK: - Paths

    public static func graphDirectory(dataRoot: String, name: String) -> String {
        "\(dataRoot)/\(name)"
    }

    /// `"<dataRoot>/<name>/tile_<lo>_<hi>"`.
    public static func tileDirectory(dataRoot: String, name: String, entry: TileEntry) -> String {
        "\(graphDirectory(dataRoot: dataRoot, name: name))/tile_\(entry.rankLo)_\(entry.rankHi)"
    }

    private static func tileDirName(lo: UInt64, hi: UInt64) -> String { "tile_\(lo)_\(hi)" }

    /// `DagDBEngine.init` handles the engine's own
    /// zero-length-Metal-buffer failure for empty colour buckets, so this
    /// file no longer needs to pad tile-local engines up to 11 nodes — the
    /// tile-local grid is sized EXACTLY to the tile. The only remaining
    /// guard is `max(ln, 1)`: a literally empty tile (`ln == 0`, not
    /// expected for any side/tiling combo the tests use, but not
    /// excluded in general) still needs a `HexGrid` with a positive
    /// width; the tile's true node count is still what's passed as
    /// `nodeCount`/`gridW` to `DagDBSnapshot.save`/`.load` (a byte-count,
    /// not a bound check), so a padding-of-one slot, if ever used, stays
    /// inert.
    private static func tileLocalEngine(nodeCount ln: Int) throws -> DagDBEngine {
        let width = max(ln, 1)
        let grid = try HexGrid(width: width, height: 1)
        let state = DagDBState(width: width, height: 1)
        return try DagDBEngine(grid: grid, state: state, maxRank: 64)
    }

    // MARK: - Write

    /// Splits `object` into tile directories by rank range and writes the
    /// graph manifest. `boundaries` is the `tiles - 1` interior boundary
    /// list from `TiledFixture.boundaries(side:tiles:)`.
    public static func write(
        object: TiledFixture.Object, dataRoot: String, name: String, boundaries: [UInt64]
    ) throws -> WriteReport {
        try write(
            engine: object.engine, maxRank: object.maxRank,
            dataRoot: dataRoot, name: name, boundaries: boundaries
        )
    }

    /// General form: split the DAEMON'S OWN live engine (not a
    /// `TiledFixture.Object`) into tile directories, for `SAVE TILED`.
    /// `grid` is accepted for parity with `TiledFixture.Object`'s
    /// shape (and any future halo work that needs spatial adjacency) — the
    /// tile-splitting math below is purely rank-driven and does not read it.
    ///
    /// Unlike the fixture path, there is no externally-known "true max
    /// rank" for an arbitrary live engine — `engine.maxRank` is only the
    /// allocated rank-bucket COUNT (`DagDBEngine.init`'s coloring/dispatch
    /// sizing), not necessarily the highest rank actually written into any
    /// node. Using it as the last tile's `rankHi` would leave real data
    /// above the recorded bound, silently breaking `runSelect`'s overlap
    /// test (`rankLo <= entry.rankHi`) for ranges inside the true tail.
    /// So this variant scans `rankBuf` for the actual maximum instead — the
    /// same "highest rank present" meaning `TiledFixture.Object.maxRank`
    /// already carries for the fixture path.
    public static func write(
        engine: DagDBEngine, grid: HexGrid, dataRoot: String, name: String, boundaries: [UInt64],
        tickCount: UInt32 = 0
    ) throws -> WriteReport {
        let n = engine.nodeCount
        let rankScanPtr = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: max(n, 1))
        var observedMaxRank: UInt64 = 0
        for i in 0..<n { observedMaxRank = max(observedMaxRank, rankScanPtr[i]) }
        return try write(
            engine: engine, maxRank: observedMaxRank,
            dataRoot: dataRoot, name: name, boundaries: boundaries, tickCount: tickCount
        )
    }

    /// Shared implementation behind both `write(object:...)` and
    /// `write(engine:grid:...)` — everything from here down is unchanged
    /// from the original fixture writer, just parameterized on `engine` +
    /// `maxRank` instead of reading them off a `TiledFixture.Object`.
    private static func write(
        engine: DagDBEngine, maxRank: UInt64, dataRoot: String, name: String, boundaries: [UInt64],
        tickCount: UInt32 = 0
    ) throws -> WriteReport {
        let n = engine.nodeCount
        let tileCount = boundaries.count + 1

        let rankPtr = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let truthPtr = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let typePtr = engine.nodeTypeBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let lutLowPtr = engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let lutHighPtr = engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let nbPtr = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        // The four ternary lanes, the edge weights TTHRESH reads, and the
        // library travel into every tile engine.
        // nil while the lanes are not allocated (every node BINARY).
        let lanes = engine.ternaryLaneView
        let wPtr = engine.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: max(n * 6, 1))
        let library = engine.libraryBytes()

        func tileOf(rank: UInt64) -> Int {
            for (i, b) in boundaries.enumerated() where rank < b { return i }
            return boundaries.count
        }

        var tileOfNode = [Int](repeating: 0, count: n)
        for m in 0..<n { tileOfNode[m] = tileOf(rank: rankPtr[m]) }

        // Refuse a cross-tile BACK_EDGE before touching
        // disk — a register whose latch crosses a tile boundary has no
        // ghost-sourcing story (ghosts are combinational sources, sourced
        // fresh every world tick; a BACK_EDGE's whole point is to persist
        // across ticks, which the tiling boundary would silently break).
        // Checked against `engine.backEdgeSrcs`/`backEdgeDsts` directly —
        // the live engine's own back-edge registry — BEFORE
        // `graphDir` is created, so a refusal leaves nothing on disk.
        for i in 0..<engine.backEdgeSrcs.count {
            let src = engine.backEdgeSrcs[i]
            let dst = engine.backEdgeDsts[i]
            guard tileOfNode[Int(src)] == tileOfNode[Int(dst)] else {
                throw FilesError.crossTileBackEdge(src: src, dst: dst)
            }
        }

        // Tile-local numbering: ascending (rank, engine/Morton index).
        var membersByTile = [[Int]](repeating: [], count: tileCount)
        for m in 0..<n { membersByTile[tileOfNode[m]].append(m) }
        for t in 0..<tileCount {
            membersByTile[t].sort { a, b in
                rankPtr[a] != rankPtr[b] ? rankPtr[a] < rankPtr[b] : a < b
            }
        }

        var localOfNode = [UInt64](repeating: 0, count: n)
        for t in 0..<tileCount {
            for (li, gm) in membersByTile[t].enumerated() { localOfNode[gm] = UInt64(li) }
        }

        var globalOf = [UInt64](repeating: 0, count: n)
        for m in 0..<n {
            globalOf[m] = try GlobalNodeID(tileId: UInt32(tileOfNode[m]), localNodeId: localOfNode[m]).raw
        }

        // Back edges, in TILE-LOCAL numbering. Every one of them is
        // intra-tile (the cross-tile check above already refused the rest),
        // so each belongs to exactly one tile. The repaired objects carry
        // registers, and a tile body that dropped them would tick a
        // different graph from the untiled engine — the tiled-against-untiled
        // tick comparisons would fail on a correct ticker.
        var backEdgesByTile = [[(src: UInt32, dst: UInt32)]](repeating: [], count: tileCount)
        for i in 0..<engine.backEdgeSrcs.count {
            let src = Int(engine.backEdgeSrcs[i])
            let dst = Int(engine.backEdgeDsts[i])
            backEdgesByTile[tileOfNode[src]].append(
                (src: UInt32(localOfNode[src]), dst: UInt32(localOfNode[dst]))
            )
        }

        var rankLoOf = [UInt64](repeating: 0, count: tileCount)
        var rankHiOf = [UInt64](repeating: 0, count: tileCount)
        for t in 0..<tileCount {
            rankLoOf[t] = t == 0 ? 0 : boundaries[t - 1]
            rankHiOf[t] = t == tileCount - 1 ? maxRank : boundaries[t]
        }

        // The whole world is written into a stage beside it and swapped in by
        // rename at the end, so a failure part-way leaves the world as it was.
        // Overwriting the tile directories one by one and the manifest last
        // would let a failure leave new tile bodies under the old manifest
        // (the next TILED OPEN would refuse on hash).
        let swap = try StagedDirectorySwap.begin(final: graphDirectory(dataRoot: dataRoot, name: name))
        let graphDir = swap.stage
        do {
        var built = try { () throws -> WriteReport in

        struct HaloEntry { let localId: UInt64; let truth: UInt8; let type: UInt8; let foreignTile: UInt32 }

        var crossingsOutByTile = [[Crossing]](repeating: [], count: tileCount)
        var crossingsInByTile = [[Crossing]](repeating: [], count: tileCount)
        var upperEntriesByTile = [[HaloEntry]](repeating: [], count: tileCount)
        var lowerEntriesByTile = [[HaloEntry]](repeating: [], count: tileCount)
        var totalCrossings = 0

        var bytesPerTile = [Int](repeating: 0, count: tileCount)
        var writeMsPerTile = [Double](repeating: 0, count: tileCount)
        var tileEntries = [TileEntry](repeating: TileEntry(
            id: 0, rankLo: 0, rankHi: 0, nodeCount: 0, bodySHA256: "", crossingsOut: [], crossingsIn: []
        ), count: tileCount)

        // Pass 1: compute every tile's local buffers AND every crossing
        // (both directions). `crossingsInByTile[t]` receives entries while
        // processing OTHER (higher) tiles, so it can only be complete once
        // every tile has been visited — meta.json/manifest construction
        // (pass 2, below) must not start until this loop finishes.
        var tileLocalRank = [[UInt64]](repeating: [], count: tileCount)
        var tileLocalTruth = [[UInt8]](repeating: [], count: tileCount)
        var tileLocalType = [[UInt8]](repeating: [], count: tileCount)
        var tileLocalLutLow = [[UInt32]](repeating: [], count: tileCount)
        var tileLocalLutHigh = [[UInt32]](repeating: [], count: tileCount)
        var tileLocalNeighbors = [[Int32]](repeating: [], count: tileCount)
        var tileLocalMode = [[UInt8]](repeating: [], count: tileCount)
        var tileLocalTid = [[UInt16]](repeating: [], count: tileCount)
        var tileLocalLo = [[Float]](repeating: [], count: tileCount)
        var tileLocalHi = [[Float]](repeating: [], count: tileCount)
        var tileLocalWeights = [[Float]](repeating: [], count: tileCount)

        for t in 0..<tileCount {
            let members = membersByTile[t]
            let ln = members.count

            var lr = [UInt64](repeating: 0, count: ln)
            var ltState = [UInt8](repeating: 0, count: ln)
            var lty = [UInt8](repeating: 0, count: ln)
            var llow = [UInt32](repeating: 0, count: ln)
            var lhigh = [UInt32](repeating: 0, count: ln)
            var lnb = [Int32](repeating: -1, count: ln * 6)
            var lmode = [UInt8](repeating: 0, count: ln)
            var ltid = [UInt16](repeating: 0, count: ln)
            var llo = [Float](repeating: 0, count: ln)
            var lhi = [Float](repeating: 0, count: ln)
            var lw = [Float](repeating: 1, count: ln * 6)

            for (li, gm) in members.enumerated() {
                lr[li] = rankPtr[gm]
                ltState[li] = truthPtr[gm]
                lty[li] = typePtr[gm]
                llow[li] = lutLowPtr[gm]
                lhigh[li] = lutHighPtr[gm]
                if let v = lanes {
                    lmode[li] = v.mode[gm]
                    ltid[li] = v.ttableId[gm]
                    llo[li] = v.thrLo[gm]
                    lhi[li] = v.thrHi[gm]
                }
                for d in 0..<6 { lw[li * 6 + d] = wPtr[gm * 6 + d] }
                for d in 0..<6 {
                    let target = nbPtr[gm * 6 + d]
                    guard target >= 0 else { continue }
                    let tm = Int(target)
                    let foreignTile = tileOfNode[tm]
                    if foreignTile == t {
                        lnb[li * 6 + d] = Int32(localOfNode[tm])
                    } else {
                        lnb[li * 6 + d] = -2
                        let foreignLocal = localOfNode[tm]
                        let remote = try GlobalNodeID(tileId: UInt32(foreignTile), localNodeId: foreignLocal)
                        // foreignRank: the rank of the node EACH
                        // Crossing's remoteNode names, in the original untiled
                        // engine's rank space — `rankPtr[tm]` for the crossingsOut
                        // entry (remoteNode = the foreign source `tm`), `rankPtr[gm]`
                        // for its crossingsIn mirror (remoteNode = the referencing
                        // node `gm`, from the referenced tile's point of view).
                        crossingsOutByTile[t].append(Crossing(localNode: UInt64(li), remoteNode: remote, foreignRank: rankPtr[tm]))
                        let backRemote = try GlobalNodeID(tileId: UInt32(t), localNodeId: UInt64(li))
                        crossingsInByTile[foreignTile].append(Crossing(localNode: foreignLocal, remoteNode: backRemote, foreignRank: rankPtr[gm]))
                        upperEntriesByTile[t].append(HaloEntry(
                            localId: foreignLocal, truth: truthPtr[tm], type: typePtr[tm],
                            foreignTile: UInt32(foreignTile)
                        ))
                        lowerEntriesByTile[foreignTile].append(HaloEntry(
                            localId: foreignLocal, truth: truthPtr[tm], type: typePtr[tm],
                            foreignTile: UInt32(t)
                        ))
                        totalCrossings += 1
                    }
                }
            }

            tileLocalRank[t] = lr
            tileLocalTruth[t] = ltState
            tileLocalType[t] = lty
            tileLocalLutLow[t] = llow
            tileLocalLutHigh[t] = lhigh
            tileLocalNeighbors[t] = lnb
            tileLocalMode[t] = lmode
            tileLocalTid[t] = ltid
            tileLocalLo[t] = llo
            tileLocalHi[t] = lhi
            tileLocalWeights[t] = lw
        }

        // Pass 2: crossingsOutByTile/crossingsInByTile are now complete for
        // every tile — build+save each tile's engine, meta.json, and
        // manifest entry.
        for t in 0..<tileCount {
            let ln = membersByTile[t].count

            // Tile-local engine, sized (ln, 1) exactly — see
            // `tileLocalEngine`'s doc comment.
            let tileEngine = try tileLocalEngine(nodeCount: ln)
            if ln > 0 {
                tileEngine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: ln)
                    .update(from: tileLocalRank[t], count: ln)
                tileEngine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: ln)
                    .update(from: tileLocalTruth[t], count: ln)
                tileEngine.nodeTypeBuf.contents().bindMemory(to: UInt8.self, capacity: ln)
                    .update(from: tileLocalType[t], count: ln)
                tileEngine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: ln)
                    .update(from: tileLocalLutLow[t], count: ln)
                tileEngine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: ln)
                    .update(from: tileLocalLutHigh[t], count: ln)
                tileEngine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: ln * 6)
                    .update(from: tileLocalNeighbors[t], count: ln * 6)
                if tileEngine.nodeCount == ln {
                    // An all-default tile leaves its lanes unallocated.
                    tileEngine.installTernaryLanes(mode: tileLocalMode[t], ttableId: tileLocalTid[t],
                                                   thrLo: tileLocalLo[t], thrHi: tileLocalHi[t])
                } else {
                    tileEngine.writeModeLane { $0.update(from: tileLocalMode[t], count: ln) }
                    tileEngine.ttableIdPtr.update(from: tileLocalTid[t], count: ln)
                    tileEngine.thrLoPtr.update(from: tileLocalLo[t], count: ln)
                    tileEngine.thrHiPtr.update(from: tileLocalHi[t], count: ln)
                }
                tileEngine.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: ln * 6)
                    .update(from: tileLocalWeights[t], count: ln * 6)
            }
            try tileEngine.replaceLibrary(library)
            // Registers + back edges (unchecked: the source engine already
            // validated the zero-combinational-fan-in rule, and the local
            // copy is the same graph). `DagDBSnapshot.save` writes them as
            // the v7 back-edge section; `load` restores the register flags.
            for be in backEdgesByTile[t] {
                try tileEngine.addBackEdgeUnchecked(src: be.src, dst: be.dst)
            }

            let dir = "\(graphDir)/\(tileDirName(lo: rankLoOf[t], hi: rankHiOf[t]))"
            _ = try DaemonFile.makeDirectories(dir)                  // contained, no link followed
            let bodyPath = "\(dir)/body.dags"

            let (bytesWritten, _, elapsedMs) = try DagDBSnapshot.save(
                engine: tileEngine, nodeCount: ln, gridW: ln, gridH: 1,
                tickCount: tickCount, path: bodyPath
            )
            bytesPerTile[t] = bytesWritten
            writeMsPerTile[t] = elapsedMs

            // The body's hash streamed back through the read helper (no copy of its size).
            let bodyHash = try DaemonFile.digest(bodyPath).map { String(format: "%02x", $0) }.joined()

            let meta = TileMeta(
                id: UInt32(t), rankLo: rankLoOf[t], rankHi: rankHiOf[t], nodeCount: UInt64(ln),
                lastPersistedTickEpoch: UInt64(tickCount),
                crossingsOut: crossingsOutByTile[t], crossingsIn: crossingsInByTile[t]
            )
            let metaEncoder = JSONEncoder()
            metaEncoder.outputFormatting = [.sortedKeys]
            let metaData = try metaEncoder.encode(meta)
            try DaemonFile.atomicWrite(metaData, to: "\(dir)/meta.json", sync: false)

            tileEntries[t] = TileEntry(
                id: UInt32(t), rankLo: rankLoOf[t], rankHi: rankHiOf[t], nodeCount: UInt64(ln),
                bodySHA256: bodyHash,
                crossingsOut: crossingsOutByTile[t], crossingsIn: crossingsInByTile[t],
                engineIndexOf: membersByTile[t].map { UInt64($0) },
                tickEpoch: UInt64(tickCount)
            )
        }

        // Pass 3: halo strips, now that every tile's crossings (and
        // therefore every foreign-tile-value snapshot) are known.
        //
        // ONE EPOCH EVERYWHERE. The
        // saved tick count `k` goes on the manifest entry, `meta.json`, the
        // body header AND BOTH parity strips: the parity-`k mod 2` strip is
        // the world's current truth at epoch `k`, and the other parity
        // carries the SAME truth values with its own recorded epoch
        // `k − 1` (both at 0 when `k == 0`). Stamping the count on the
        // manifest entry alone and 0 into the other three would leave sync
        // mode's first world tick at `k + 1` looking for a `k` strip that was
        // never written.
        let savedEpoch = UInt64(tickCount)
        let priorEpoch: UInt64 = savedEpoch == 0 ? 0 : savedEpoch - 1
        /// The file header documents `source_tile_id` /
        /// `target_tile_id` as "the most-referenced foreign tile"; `.first`'s
        /// would be a different tile whenever a tile
        /// references more than one foreign tile (the far 3-ring draw can
        /// skip a tile on a narrow tiling). The MODE is what the doc says,
        /// so the mode is what is recorded; ties break to the lowest tile
        /// id, so the choice is deterministic.
        func modalForeignTile(_ entries: [HaloEntry]) -> UInt32? {
            guard !entries.isEmpty else { return nil }
            var counts: [UInt32: Int] = [:]
            for e in entries { counts[e.foreignTile, default: 0] += 1 }
            return counts.sorted { a, b in
                a.value != b.value ? a.value > b.value : a.key < b.key
            }.first?.key
        }

        for t in 0..<tileCount {
            let upperTarget = modalForeignTile(upperEntriesByTile[t])
            try writeRankHalo(
                entries: upperEntriesByTile[t].map { ($0.localId, $0.truth, $0.type, $0.foreignTile) },
                kind: 1,
                sourceTileId: UInt64(upperTarget ?? UInt32(t)), targetTileId: UInt64(t),
                tickEpoch: savedEpoch,
                path: "\(graphDir)/\(tileDirName(lo: rankLoOf[t], hi: rankHiOf[t]))/halo_upper.bin"
            )
            let lowerSource = modalForeignTile(lowerEntriesByTile[t])
            try writeRankHalo(
                entries: lowerEntriesByTile[t].map { ($0.localId, $0.truth, $0.type, $0.foreignTile) },
                kind: 0,
                sourceTileId: UInt64(t), targetTileId: UInt64(lowerSource ?? UInt32(t)),
                tickEpoch: savedEpoch,
                path: "\(graphDir)/\(tileDirName(lo: rankLoOf[t], hi: rankHiOf[t]))/halo_lower.bin"
            )

            // Both parity strips, in the deduped shape
            // `writeLowerStrip`/`readLowerStrip` expect (one entry per
            // DISTINCT local referenced by any lower tile's crossingsOut —
            // i.e. by `crossingsInByTile[t]`'s distinct localNode set —
            // not the possibly-repeated-per-edge `lowerEntriesByTile[t]`
            // above, which stays exactly as step one wrote it for
            // `testHaloFilesParse`'s non-deduped count check).
            //
            // Both truth bytes of every entry carry the SAME
            // saved truth in both parity strips. At rest there is no round
            // and therefore no latch to be before or after — the world's
            // current vector is both the pre- and the post-latch value a
            // reader of either mode is entitled to.
            let dedupedLocals = Set(crossingsInByTile[t].map { $0.localNode }).sorted()
            let dedupedEntries = dedupedLocals.map { local -> LowerStripEntry in
                let truth = tileLocalTruth[t][Int(local)]
                return LowerStripEntry(
                    localId: local, truthPre: truth, truthPost: truth,
                    type: tileLocalType[t][Int(local)])
            }
            let tileDirPath = "\(graphDir)/\(tileDirName(lo: rankLoOf[t], hi: rankHiOf[t]))"
            try writeLowerStripFile(
                entries: dedupedEntries,
                sourceTileId: UInt64(t), targetTileId: UInt64(t), tickEpoch: savedEpoch,
                path: "\(tileDirPath)/halo_lower.\(savedEpoch % 2).bin"
            )
            if priorEpoch % 2 != savedEpoch % 2 {
                try writeLowerStripFile(
                    entries: dedupedEntries,
                    sourceTileId: UInt64(t), targetTileId: UInt64(t), tickEpoch: priorEpoch,
                    path: "\(tileDirPath)/halo_lower.\(priorEpoch % 2).bin"
                )
            } else {
                // k == 0: both parities exist and both record epoch 0.
                try writeLowerStripFile(
                    entries: dedupedEntries,
                    sourceTileId: UInt64(t), targetTileId: UInt64(t), tickEpoch: savedEpoch,
                    path: "\(tileDirPath)/halo_lower.\(1 - savedEpoch % 2).bin"
                )
            }
        }

        let manifest = Manifest(
            format: "dagdb-tiled-manifest", version: 1, name: name, boundaries: boundaries,
            globalNodeCount: UInt64(n), tiles: tileEntries
        )
        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = [.sortedKeys]
        try writeFileAtomically(try manifestEncoder.encode(manifest), to: "\(graphDir)/manifest.json")

        // A node's slots hold HIGHER-rank
        // sources, so `tile(dst) <= tile(src)` always — a cross-tile
        // reference between adjacent tiles k and k+1 runs ONLY from k
        // (the referencing/dst tile, lower rank range) to k+1 (the
        // referenced/src tile, higher rank range), never the reverse.
        // `down`/`up` are therefore mirror bookkeeping of that SAME
        // edge subset (crossingsOut recorded on the referencing tile k,
        // crossingsIn recorded on the referenced tile k+1) — not two
        // opposite data-flow directions; they're asserted equal by
        // construction (`testEveryBoundaryHasCrossingsBothWays`).
        var perBoundary: [BoundaryCount] = []
        for k in 0..<(tileCount - 1) {
            let up = crossingsOutByTile[k].filter { $0.remoteNode.tileId == UInt32(k + 1) }.count
            let down = crossingsInByTile[k + 1].filter { $0.remoteNode.tileId == UInt32(k) }.count
            perBoundary.append(BoundaryCount(lower: UInt32(k), upper: UInt32(k + 1), down: down, up: up))
        }

        let adjacentUp = perBoundary.reduce(0) { $0 + $1.up }
        return WriteReport(
            tiles: tileCount, nodes: n, crossings: totalCrossings,
            crossingsSkippingATile: totalCrossings - adjacentUp,
            perBoundary: perBoundary,
            bytesPerTile: bytesPerTile, writeMsPerTile: writeMsPerTile, globalOf: globalOf
        )
        }()
        built.oldWorldLeft = try swap.commit()
        return built
        } catch {
            if let left = swap.abort() { throw StagedWriteError.refused("\(Reply.errorWords(error)); and the stage could not be removed: \(left)") }
            throw error
        }
    }

    // MARK: - Read manifest

    /// The only manifest format string and version this reader knows —
    /// the pair `write` stamps.
    public static let manifestFormat = "dagdb-tiled-manifest"
    public static let manifestFormatVersion = 1

    /// `<graphDir>/manifest.json`, the one path `readManifest` reads.
    public static func manifestPath(dataRoot: String, name: String) -> String {
        "\(graphDirectory(dataRoot: dataRoot, name: name))/manifest.json"
    }

    public static func readManifest(dataRoot: String, name: String) throws -> Manifest {
        let path = manifestPath(dataRoot: dataRoot, name: name)
        // Through the read helper (the daemon itself reads the manifest in TILED OPEN's admitted
        // reader; this library entry has no daemon caller).
        guard let data = try? DaemonFile.read(path) else {
            throw FilesError.manifestMissing(path)
        }
        return try decodeManifest(data)
    }

    /// A tile body's bound before it is read: the v8 body (53 B per node) with every lane and
    /// a generous back-edge list (128 B per node in all), plus the library's most (47.8 MB) and slack.
    static func bodyMaxBytes(nodes n: UInt64) -> Int {
        Int(clamping: n.multipliedReportingOverflow(by: 128).overflow ? UInt64.max : n * 128) &+ (64 << 20)
    }

    /// A tile file through the read helper (non-blocking, a regular file inside the root,
    /// bounded, unchanged while read).
    static func readTileFile(_ path: String, _ rule: DaemonFile.Size = .any) throws -> Data {
        try DaemonFile.read(path, rule)
    }

    /// `readManifest`'s decode and checks on bytes the caller has read
    /// (the daemon's TILED OPEN reads the file once, as a regular file, and decodes that copy).
    public static func decodeManifest(_ data: Data) throws -> Manifest {
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw FilesError.manifestDecode(Reply.errorWords(error))
        }
        // Both stamped fields are read back and refused by name.
        guard manifest.format == manifestFormat else {
            throw FilesError.manifestFormatUnsupported(found: manifest.format, expected: manifestFormat)
        }
        guard manifest.version == manifestFormatVersion else {
            throw FilesError.manifestVersionUnsupported(
                found: manifest.version, expected: manifestFormatVersion)
        }
        return manifest
    }

    /// Overwrites `<graphDir>/manifest.json` with `manifest` — atomic
    /// write (temp file in the same directory, then rename; `.atomic` is
    /// Foundation's implementation of exactly that on Darwin), same
    /// discipline as `writeMeta`'s. Every tile
    /// flush calls this to rewrite that tile's entry (`bodySHA256`,
    /// `tickEpoch`) before its `TILE_FLUSH_COMMIT` — one authority for
    /// both the query path (`loadTile`) and the ticker
    /// (`loadTileWithGhosts`).
    ///
    /// Through `writeFileAtomically` (the same temp-and-rename);
    /// `mid` is its test seam.
    static func writeManifest(dataRoot: String, name: String, manifest: Manifest,
                              mid: (() throws -> Void)? = nil) throws {
        let graphDir = graphDirectory(dataRoot: dataRoot, name: name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try writeFileAtomically(data, to: "\(graphDir)/manifest.json", mid: mid)
    }

    // MARK: - Load one tile

    /// Loads one tile's `body.dags` + `meta.json`. Recovery precedes the
    /// hash check: a torn tile
    /// (`flush.wal` ends in an unmatched `TILE_FLUSH_BEGIN`) is detected
    /// FIRST and refused as `RouterError.tileFlushIncomplete` — the query
    /// path defers to recovery exactly like the ticker does, rather than
    /// reporting a confusing hash mismatch for a body that is mid-flush,
    /// not corrupt. Only once `flush.wal` is clean does the manifest-vs-
    /// sidecar sha256 check run (`RouterError.tileHashMismatch` — a CLEAN
    /// tile whose sidecar and manifest disagree is the real touched
    /// body); then the meta/body epoch check (`RouterError.tileInconsistent`).
    /// A stale `body.dags.tmp` beside the committed body loads the
    /// committed body and reports the leftover via `leftoverTemp`.
    public static func loadTile(
        dataRoot: String, name: String, manifest: Manifest, tileId: UInt32
    ) throws -> LoadedTile {
        guard let entry = manifest.tiles.first(where: { $0.id == tileId }) else {
            throw FilesError.tileEntryMissing(tileId)
        }
        let dir = tileDirectory(dataRoot: dataRoot, name: name, entry: entry)
        let bodyPath = "\(dir)/body.dags"
        let metaPath = "\(dir)/meta.json"

        switch flushState(dir: dir) {
        case .clean: break
        case .pending(let epoch, _):
            let bodyEpoch = (try? bodyTickCountRaw(path: bodyPath)) ?? 0
            throw RouterError.tileFlushIncomplete(tileId, epoch: epoch, bodyEpoch: bodyEpoch)
        case .torn(let detail):
            // A torn flush is a torn flush, never "clean".
            throw RouterError.tileFlushMalformed(tileId, detail: detail)
        case .unreadable(let detail):
            // An unreadable wal is never "clean" either.
            throw RouterError.tileFlushUnreadable(tileId, detail: detail)
        }

        // The body read ONCE: its hash, its header fields and its decode all from this copy (not read for
        // the hash, then again by the load, and its sidecar too).
        let bodyData = try readTileFile(bodyPath, .atMost(bodyMaxBytes(nodes: entry.nodeCount)))
        let actualHash = DagDBSnapshot.sha256Hex(bodyData)
        guard actualHash == entry.bodySHA256 else {
            throw RouterError.tileHashMismatch(tileId, expected: entry.bodySHA256, actual: actualHash)
        }

        let metaData = try DaemonFile.readAdmitted(metaPath)                     // admitted on its true size
        let meta: TileMeta
        do {
            meta = try JSONDecoder().decode(TileMeta.self, from: metaData)
        } catch {
            throw FilesError.metaDecode(Reply.errorWords(error))
        }

        // The three counts agree, or nothing is allocated.
        let n = try tileNodeCount(
            entry: entry, meta: meta, globalNodeCount: manifest.globalNodeCount,
            bodyPath: bodyPath, bodyData: bodyData)
        let engine = try tileLocalEngine(nodeCount: n)

        // validate:true — the fixture's generator
        // matches the engine's own convention (a node's slots hold
        // strictly-higher-rank sources, `rank(src) > rank(dst)`), so
        // DagDBSnapshot's general DAG-invariant check applies and must
        // pass. verifyManifest:true — `DagDBSnapshot.save` always writes a
        // side-by-side `<path>.sha256` sidecar (see its manifest comment), so
        // the sidecar is NOT absent here; this is a second, redundant
        // check on top of the router's own manifest-based hash comparison
        // above (RouterError.tileHashMismatch, which fires first and is
        // the authority) — defense in depth, not a substitute.
        // A tiled graph stays a rank-mode object —
        // the tile body is held to the rank-mode rule (a source out of range,
        // S2 and S3 refused; S1 accepted, as rank TICK runs it), not the slot
        // model's persistence rule.
        let loadResult = try DagDBSnapshot.load(
            engine: engine, nodeCount: n, gridW: n, gridH: 1,
            path: bodyPath, data: bodyData, validate: true, slotRule: .rankModeDAG, verifyManifest: true
        )

        guard UInt64(loadResult.fileTicks) == meta.lastPersistedTickEpoch else {
            throw RouterError.tileInconsistent(
                tileId, metaEpoch: meta.lastPersistedTickEpoch, bodyEpoch: UInt64(loadResult.fileTicks)
            )
        }

        let leftoverTemp = !DaemonFile.leftoverTemporaries(of: bodyPath).isEmpty     // a leftover temporary beside it (the daemon's marked one or `<path>.tmp`)

        return LoadedTile(engine: engine, meta: meta, leftoverTemp: leftoverTemp)
    }

    // MARK: - Ghosted tile load

    public struct LoadedGhostedTile {
        /// Sized `realNodeCount + ghostCount`. Nodes `0..<realNodeCount`
        /// are this tile's own; `-2` cross-tile slots are rewritten to
        /// point at the ghost they resolve to. Nodes
        /// `realNodeCount..<realNodeCount+ghostCount` are the ghost
        /// registers (`isRegister = 1`, `rank` = the foreign source's own
        /// rank, `truth = 0` until the caller stages a real value).
        public let engine: DagDBEngine
        public let meta: TileMeta
        public let realNodeCount: Int
        public let ghostCount: Int
        /// Ghost `g`'s foreign source; engine node `realNodeCount + g`.
        /// Ascending `(tile, local)` order.
        public let ghostSources: [(tile: UInt32, local: UInt64)]
        public let leftoverTemp: Bool
    }

    /// Generic same-size buffer copy — `count` elements of `T` from
    /// `src` to `dst`. No-op for `count == 0` (an `MTLBuffer.contents()`
    /// pointer over a zero-length region is not a safe `update(from:)`
    /// source).
    private static func copyBuf<T>(_ src: MTLBuffer, _ dst: MTLBuffer, count: Int, as type: T.Type) {
        guard count > 0 else { return }
        let s = src.contents().bindMemory(to: T.self, capacity: count)
        let d = dst.contents().bindMemory(to: T.self, capacity: count)
        d.update(from: s, count: count)
    }

    /// The four ternary lanes and the edge-weight lane of the first `count`
    /// nodes.
    static func copyTernaryLanes(from src: DagDBEngine, to dst: DagDBEngine, count n: Int) {
        guard n > 0 else { return }
        copyBuf(src.edgeWeightsBuf, dst.edgeWeightsBuf, count: n * 6, as: Float.self)
        // Nothing to copy while both lane sets are unallocated
        // (every node BINARY on both sides); otherwise the source's lanes,
        // or zeros for a source that never allocated them.
        guard let v = src.ternaryLaneView else {
            guard dst.ternaryLanesAllocated else { return }
            dst.writeModeLane { $0.update(repeating: 0, count: n) }
            memset(dst.ttableIdBuf.contents(), 0, n * 2)
            memset(dst.thrLoBuf.contents(), 0, n * 4)
            memset(dst.thrHiBuf.contents(), 0, n * 4)
            return
        }
        dst.writeModeLane { $0.update(from: v.mode, count: n) }   // keeps dst's count exact
        dst.ttableIdPtr.update(from: v.ttableId, count: n)
        dst.thrLoPtr.update(from: v.thrLo, count: n)
        dst.thrHiPtr.update(from: v.thrHi, count: n)
    }

    /// Loads `body.dags` + `meta.json` — IDENTICALLY to `loadTile`
    /// (one authority for both paths — the
    /// manifest-recorded `bodySHA256`, refreshed by every flush before its
    /// COMMIT, is checked here exactly as `loadTile` checks it), then
    /// builds the GHOSTED engine described by `LoadedGhostedTile`:
    ///
    /// 1. Ghost set = the distinct foreign `(tile, local)` sources in
    ///    `meta.crossingsOut`, ascending `(tile, local)` order.
    /// 2. A fresh engine of size `realNodeCount + ghostCount`
    ///    (`HexGrid(width:, height: 1)`) — NOT the loaded real-size
    ///    engine reused, so the real engine's `-2` sentinels stay intact
    ///    for anything that inspects it (nothing does, today; it's
    ///    discarded after copying).
    /// 3. The first `realNodeCount` nodes' buffers copied from the real
    ///    engine.
    /// 4. Ghost `g` (engine index `realNodeCount + g`) gets
    ///    `rank = ghostSources[g]`'s `foreignRank` (from `crossingsOut`,
    ///    written at tiling time — no foreign-tile file read needed),
    ///    `truth = 0`, `isRegister = 1`, no inputs.
    /// 5. Every `-2` neighbour slot among the first `realNodeCount` nodes
    ///    is rewritten to the ghost engine index it resolves to. Slot
    ///    order determinism: `meta.crossingsOut`'s array order is the
    ///    SAME order `TiledGraphFiles.write` appended them in (ascending
    ///    local id, then ascending slot — see that function's pass 1), so
    ///    grouping by `localNode` and consuming each group in order,
    ///    once per encountered `-2` slot (ascending `d`), reconstructs
    ///    the exact slot↔crossing correspondence without a separate
    ///    per-slot field.
    ///
    /// `ignorePendingFlush`: recovery (`TiledGraphRouter`'s writer-role
    /// `init`) needs to load a tile that DOES have an unmatched
    /// `TILE_FLUSH_BEGIN` in its `flush.wal` (that IS the tile it's
    /// fixing) — every other caller leaves this `false` so a torn flush is
    /// refused (`RouterError.tileFlushIncomplete`) rather than silently
    /// loaded (recovery precedes the hash check —
    /// the manifest-vs-sidecar sha256 comparison below only runs on a tile
    /// whose `flush.wal` is clean). Recovery's whole job is reconciling a
    /// `meta.json`/`body.dags` epoch MISMATCH (case i: meta ahead of a
    /// body that never got renamed; case ii: body ahead of a meta that
    /// never got rewritten) — so `true` also bypasses the ordinary
    /// `tileHashMismatch`/`tileInconsistent` checks below, which exist to
    /// refuse exactly those mismatches for every NON-recovery caller.
    ///
    /// `tornTailSetAside`: a writer open's plan, before the
    /// open cuts a torn last wal record, reads the wal without it (as the
    /// load after the cut will); every check below still runs.
    public static func loadTileWithGhosts(
        dataRoot: String, name: String, manifest: Manifest, tileId: UInt32,
        ignorePendingFlush: Bool = false, tornTailSetAside: Bool = false
    ) throws -> LoadedGhostedTile {
        guard let entry = manifest.tiles.first(where: { $0.id == tileId }) else {
            throw FilesError.tileEntryMissing(tileId)
        }
        let dir = tileDirectory(dataRoot: dataRoot, name: name, entry: entry)
        let bodyPath = "\(dir)/body.dags"
        let metaPath = "\(dir)/meta.json"

        if !ignorePendingFlush {
            // `tornTailSetAside` — the wal as a writer open's
            // plan reads it, before its cut (`flushStateForWriter`).
            switch tornTailSetAside ? flushStateForWriter(dir: dir).state : flushState(dir: dir) {
            case .clean: break
            case .pending(let epoch, _):
                let bodyEpoch = (try? bodyTickCountRaw(path: bodyPath)) ?? 0
                throw RouterError.tileFlushIncomplete(tileId, epoch: epoch, bodyEpoch: bodyEpoch)
            case .torn(let detail):
                throw RouterError.tileFlushMalformed(tileId, detail: detail)
            case .unreadable(let detail):
                throw RouterError.tileFlushUnreadable(tileId, detail: detail)
            }
        }

        let metaData = try DaemonFile.readAdmitted(metaPath)                     // admitted on its true size
        let meta: TileMeta
        do {
            meta = try JSONDecoder().decode(TileMeta.self, from: metaData)
        } catch {
            throw FilesError.metaDecode(Reply.errorWords(error))
        }

        // The body read ONCE (hash, header fields and decode from this copy).
        var bodyBytes: Data? = nil
        if ignorePendingFlush {
            bodyBytes = try readTileFile(bodyPath, .atMost(bodyMaxBytes(nodes: entry.nodeCount)))
        } else {
            let bodyData = try readTileFile(bodyPath, .atMost(bodyMaxBytes(nodes: entry.nodeCount)))
            let actualHash = DagDBSnapshot.sha256Hex(bodyData)
            guard actualHash == entry.bodySHA256 else {
                throw RouterError.tileHashMismatch(tileId, expected: entry.bodySHA256, actual: actualHash)
            }
            bodyBytes = bodyData
        }

        // The three counts agree, or nothing is allocated.
        let n = try tileNodeCount(
            entry: entry, meta: meta, globalNodeCount: manifest.globalNodeCount,
            bodyPath: bodyPath, bodyData: bodyBytes)
        let realEngine = try tileLocalEngine(nodeCount: n)
        // The rank-mode rule, as above.
        let loadResult = try DagDBSnapshot.load(
            engine: realEngine, nodeCount: n, gridW: n, gridH: 1,
            path: bodyPath, data: bodyBytes!, validate: true, slotRule: .rankModeDAG, verifyManifest: true
        )

        if !ignorePendingFlush {
            guard UInt64(loadResult.fileTicks) == meta.lastPersistedTickEpoch else {
                throw RouterError.tileInconsistent(
                    tileId, metaEpoch: meta.lastPersistedTickEpoch, bodyEpoch: UInt64(loadResult.fileTicks)
                )
            }
        }

        // Ghost set: distinct foreign sources, ascending (tile, local).
        let sortedCrossings = meta.crossingsOut.sorted {
            ($0.remoteNode.tileId, $0.remoteNode.localNodeId) < ($1.remoteNode.tileId, $1.remoteNode.localNodeId)
        }
        var seen = Set<UInt64>()
        var ghostSources: [(tile: UInt32, local: UInt64)] = []
        var ghostRankOf: [UInt64: UInt64] = [:]
        for c in sortedCrossings where !seen.contains(c.remoteNode.raw) {
            seen.insert(c.remoteNode.raw)
            ghostSources.append((tile: c.remoteNode.tileId, local: c.remoteNode.localNodeId))
            ghostRankOf[c.remoteNode.raw] = c.foreignRank
        }
        let g = ghostSources.count
        var ghostIndexOf: [UInt64: Int] = [:]
        for (i, s) in ghostSources.enumerated() {
            ghostIndexOf[try GlobalNodeID(tileId: s.tile, localNodeId: s.local).raw] = i
        }

        let ghosted = try tileLocalEngine(nodeCount: n + g)
        if n > 0 {
            copyBuf(realEngine.rankBuf, ghosted.rankBuf, count: n, as: UInt64.self)
            copyBuf(realEngine.truthStateBuf, ghosted.truthStateBuf, count: n, as: UInt8.self)
            copyBuf(realEngine.nodeTypeBuf, ghosted.nodeTypeBuf, count: n, as: UInt8.self)
            copyBuf(realEngine.lut6LowBuf, ghosted.lut6LowBuf, count: n, as: UInt32.self)
            copyBuf(realEngine.lut6HighBuf, ghosted.lut6HighBuf, count: n, as: UInt32.self)
            copyBuf(realEngine.neighborsBuf, ghosted.neighborsBuf, count: n * 6, as: Int32.self)
            // The ternary lanes, the weights TTHRESH reads.
            // Ghosts keep the defaults: BINARY registers holding a byte.
            copyTernaryLanes(from: realEngine, to: ghosted, count: n)
        }
        try ghosted.replaceLibrary(realEngine.libraryBytes())

        // Registers + back edges the body carried.
        // `DagDBSnapshot.load` restored them onto `realEngine`; the ghosted
        // engine is a fresh, larger instance, so they must be re-registered
        // on it or the tile would tick a register-free graph.
        for i in 0..<realEngine.backEdgeSrcs.count {
            try ghosted.addBackEdgeUnchecked(
                src: realEngine.backEdgeSrcs[i], dst: realEngine.backEdgeDsts[i])
        }

        let rankPtr = ghosted.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n + g)
        let truthPtr = ghosted.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n + g)
        let regPtr = ghosted.isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: n + g)
        for i in 0..<g {
            let raw = try GlobalNodeID(tileId: ghostSources[i].tile, localNodeId: ghostSources[i].local).raw
            rankPtr[n + i] = ghostRankOf[raw] ?? 0
            truthPtr[n + i] = 0
            regPtr[n + i] = 1
        }

        if n > 0 {
            // Grouped over the ORIGINAL (not rank-sorted) crossingsOut
            // order — `write`'s pass 1 appended in ascending local id then
            // ascending slot, so each group's element order already IS
            // the ascending-slot order its node's `-2` slots were found
            // in; `Dictionary(grouping:by:)` preserves per-key order.
            let crossByLocal = Dictionary(grouping: meta.crossingsOut, by: { $0.localNode })
            let nbPtr = ghosted.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: (n + g) * 6)
            // The body's `-2` slot count for a local and the number of
            // crossings meta.json lists for it are two INDEPENDENT
            // file-derived numbers. More slots than crossings would TRAP on
            // `list[cursor]`; fewer would wire the graph wrong, ignore the
            // surplus crossings and leave a `-2` sentinel in place. Both are
            // refused by name, and the whole tile is
            // checked before a single slot is rewritten.
            for li in 0..<n {
                var slots = 0
                for slot in 0..<6 where nbPtr[li * 6 + slot] == -2 { slots += 1 }
                let crossings = crossByLocal[UInt64(li)]?.count ?? 0
                guard slots == crossings else {
                    throw FilesError.crossingSlotCountMismatch(
                        tile: tileId, local: UInt64(li), slots: slots, crossings: crossings)
                }
            }
            // The same out-of-range shape on the read side: a crossing naming a local
            // at or past this tile's own node count can index nothing here.
            for c in meta.crossingsOut where c.localNode >= UInt64(n) {
                throw FilesError.crossingLocalOutOfRange(
                    tile: tileId, local: c.localNode, nodeCount: n)
            }
            for li in 0..<n {
                guard let list = crossByLocal[UInt64(li)] else { continue }
                var cursor = 0
                for slot in 0..<6 {
                    guard nbPtr[li * 6 + slot] == -2 else { continue }
                    let c = list[cursor]
                    cursor += 1
                    guard let gi = ghostIndexOf[c.remoteNode.raw] else { continue }
                    nbPtr[li * 6 + slot] = Int32(n + gi)
                }
            }
        }

        let leftoverTemp = !DaemonFile.leftoverTemporaries(of: bodyPath).isEmpty     // a leftover temporary beside it (the daemon's marked one or `<path>.tmp`)
        return LoadedGhostedTile(
            engine: ghosted, meta: meta, realNodeCount: n, ghostCount: g,
            ghostSources: ghostSources, leftoverTemp: leftoverTemp
        )
    }

    /// Real-size (non-ghosted) copy of a ghosted tick engine's first
    /// `realNodeCount` nodes, `-2` sentinels RESTORED on any slot that
    /// currently points at a ghost index (`>= realNodeCount`) — the
    /// persisted `body.dags` format's contract is the `-2` sentinel
    /// (`docs/tiled-streaming.md` §4.1), never a ghost's ephemeral
    /// in-buffer index, which is meaningless once the engine is
    /// discarded. This is what `TiledGraphRouter`'s per-tile flush saves.
    static func scratchRealEngine(from ghosted: DagDBEngine, realNodeCount n: Int) throws -> DagDBEngine {
        let scratch = try tileLocalEngine(nodeCount: n)
        guard n > 0 else { return scratch }
        copyBuf(ghosted.rankBuf, scratch.rankBuf, count: n, as: UInt64.self)
        copyBuf(ghosted.truthStateBuf, scratch.truthStateBuf, count: n, as: UInt8.self)
        copyBuf(ghosted.nodeTypeBuf, scratch.nodeTypeBuf, count: n, as: UInt8.self)
        copyBuf(ghosted.lut6LowBuf, scratch.lut6LowBuf, count: n, as: UInt32.self)
        copyBuf(ghosted.lut6HighBuf, scratch.lut6HighBuf, count: n, as: UInt32.self)
        copyTernaryLanes(from: ghosted, to: scratch, count: n)
        try scratch.replaceLibrary(ghosted.libraryBytes())
        let nbSrc = ghosted.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        let nbDst = scratch.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        for i in 0..<(n * 6) {
            let v = nbSrc[i]
            nbDst[i] = v >= Int32(n) ? -2 : v
        }
        // Back edges: both endpoints are always REAL nodes (a ghost is an
        // input, never a register destination), so they copy across
        // unchanged. Without this the flushed body would lose its
        // registers one world tick after the first flush.
        for i in 0..<ghosted.backEdgeSrcs.count {
            try scratch.addBackEdgeUnchecked(
                src: ghosted.backEdgeSrcs[i], dst: ghosted.backEdgeDsts[i])
        }
        return scratch
    }

    // MARK: - Per-tile flush WAL

    /// A write of a tiled verb that failed, by POSIX call and
    /// errno; or a wal record whose cut-back failed too.
    public enum WriteError: Error, CustomStringConvertible {
        case posix(call: String, path: String, errno: Int32)
        /// The record could not be cut back after a failed write: the file
        /// ends in a torn record (`flushState` reads it torn; a reader open
        /// refuses the tile by name, a writer open cuts it).
        case walTorn(path: String, written: Int, of: Int, cause: String, cutErrno: Int32)
        /// After a body save: its `.sha256` sidecar missing (the save swallows
        /// a failed sidecar write) or not the body's digest.
        case sidecar(path: String, found: String?)
        /// The target refused by the write helper (not a regular file, a link, outside the root).
        case refused(DaemonFile.Refusal)

        public var description: String {
            switch self {
            case .refused(let r): return "\(r)"
            case .sidecar(let path, let found):
                let name = (path as NSString).lastPathComponent
                return found.map { "\(name) holds \($0), not the body's digest" }
                    ?? "\(name) missing after the body's save (its write failed; the save does not report it)"
            case .posix(let call, let path, let e):
                return "\(call) " + Reply.errnoWords(e, path: (path as NSString).lastPathComponent)
            case .walTorn(let path, let written, let of, let cause, let cutErrno):
                return "\((path as NSString).lastPathComponent): \(written)/\(of) byte(s) of a record written "
                    + "(\(cause)) and the cut back failed (errno \(cutErrno)); it ends in a torn record"
            }
        }
    }

    /// `bytes[range]` to `fd`, every byte or a throw.
    private static func writeAll(_ fd: Int32, _ bytes: [UInt8], _ range: Range<Int>, path: String) throws {
        var at = range.lowerBound
        while at < range.upperBound {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + at, range.upperBound - at) }
            if n < 0 {
                if errno == EINTR { continue }
                throw WriteError.posix(call: "write", path: path, errno: errno)
            }
            at += n
        }
    }

    /// `data` to `path` whole or not at all — written to a temporary,
    /// then renamed over `path` (as `Data.write(options: .atomic)` would:
    /// no fsync, a process kill is the model). A
    /// failure before the rename removes the tmp file and leaves `path` as
    /// it was. `mid` (a test seam) runs with half the bytes written.
    static func writeFileAtomically(_ data: Data, to path: String, mid: (() throws -> Void)? = nil) throws {
        #if DEBUG || DAGDB_FAULT_INJECTION
        if DagDBFaultInjection.writeFails(path) {   // fault-injection seam (SAVE TILED's manifest, a flush's files)
            throw WriteError.posix(call: "open", path: path + ".tmp", errno: ENOSPC)
        }
        #endif
        // The canonical path inside the root; the tmp opened without blocking, no link followed, a regular
        // file (a FIFO there would block the open); renamed with no link followed. The tmp is always a NEW
        // file (O_EXCL; a stale single-link one unlinked first, a hard-linked one refused by name), never
        // opened O_TRUNC, which would write into whatever inode the name held.
        let path = try DaemonFile.forWrite(path)
        // The target is nothing or a regular single-link file, not a live file of the daemon; asked again
        // just before the rename.
        if let r = DaemonFile.renameTargetRefusal(path) { throw WriteError.refused(r) }
        let tmp = DaemonFile.tmpName(for: path)                  // the daemon's marked temporary name (not <path>.tmp)
        let bytes = [UInt8](data)
        let fd: Int32
        do { fd = try DaemonFile.createTemporary(tmp) }
        catch let r as DaemonFile.Refusal { throw WriteError.refused(r) }
        do {
            let half = bytes.count / 2
            try writeAll(fd, bytes, 0..<half, path: tmp)
            try mid?()
            try writeAll(fd, bytes, half..<bytes.count, path: tmp)
        } catch {
            Darwin.close(fd)
            DaemonFile.unlinkNoFollow(tmp)
            throw error
        }
        Darwin.close(fd)
        if let r = DaemonFile.renameTargetRefusal(path) { DaemonFile.unlinkNoFollow(tmp); throw WriteError.refused(r) }
        let e = DaemonFile.renameNoFollow(tmp, path)
        guard e == 0 else {
            DaemonFile.unlinkNoFollow(tmp)
            throw WriteError.posix(call: "rename", path: path, errno: e)
        }
    }

    /// Appends one text record (`"TILE_FLUSH_BEGIN <tile> <epoch>
    /// <rank|sync>"` / `"TILE_FLUSH_COMMIT <tile> <epoch>"`) to
    /// `<tileDir>/flush.wal`, creating the file if absent. Not fsync'd (a
    /// process kill is the model; a power loss is not).
    ///
    /// Whole or not at all (the same measure the daemon's WAL takes). The
    /// record is written with POSIX `write` (`FileHandle.write` raises an
    /// Objective-C exception on an I/O error: the process stops); a write
    /// that fails after some bytes is cut back
    /// to the record's start (`ftruncate`) before the error is thrown, so the
    /// log ends at a record boundary again. If the cut fails too, the error
    /// says the log ends in a torn record. `mid` (a test seam) runs with half
    /// the record written.
    ///
    /// One `write(2)` per record in production. Writing every record in two
    /// (the seam's split, taken with no seam too) let a kill between them
    /// leave a record with no newline that every open refused. The record is
    /// split only when `mid`
    /// is set (the test seam). A kill inside the one write (or a short write
    /// `writeAll` completes with a second) still can leave a torn last record:
    /// a writer open cuts it (`flushStateForWriter`, `cutTornTail`).
    static func appendFlushWAL(path: String, record: String, mid: (() throws -> Void)? = nil) throws {
        let bytes = Array((record + "\n").utf8)
        // Without blocking (a FIFO planted after TILED OPEN would block TILED TICK's commit), no link
        // followed, a regular file inside the root.
        let fd: Int32
        do { fd = try DaemonFile.openForWrite(try DaemonFile.forWrite(path), create: true, append: true) }
        catch let r as DaemonFile.Refusal { throw WriteError.refused(r) }
        defer { Darwin.close(fd) }
        let start = Darwin.lseek(fd, 0, SEEK_END)
        guard start >= 0 else { throw WriteError.posix(call: "lseek", path: path, errno: errno) }
        do {
            if let mid {
                let half = bytes.count / 2
                try writeAll(fd, bytes, 0..<half, path: path)
                try mid()
                try writeAll(fd, bytes, half..<bytes.count, path: path)
            } else {
                try writeAll(fd, bytes, 0..<bytes.count, path: path)
            }
        } catch {
            let end = Darwin.lseek(fd, 0, SEEK_END)
            guard Darwin.ftruncate(fd, start) == 0 else {
                throw WriteError.walTorn(path: path, written: Int(max(0, end - start)), of: bytes.count,
                                         cause: Reply.errorWords(error), cutErrno: errno)
            }
            throw error
        }
    }

    /// `nil` if `<dir>/flush.wal` is absent or its last record is a
    /// `TILE_FLUSH_COMMIT` (clean); the `BEGIN`'s `(epoch, mode)` if the
    /// last record is an unmatched `TILE_FLUSH_BEGIN` (torn flush) —
    /// the BEGIN record carries the mode as its third field, so recovery
    /// needs nothing outside the tile directory to know which mode's
    /// ghost-sourcing rule to replay.
    /// `flush.wal`'s last record, classified. A reader that returned `nil`
    /// — i.e. "clean" — for ANYTHING that was not a well-formed four-field
    /// BEGIN would read a torn final write (the file is unfsynced appended
    /// text) and a three-field BEGIN predating the mode field as committed,
    /// and load the tile.
    enum FlushState: Equatable {
        /// No `flush.wal`, or its last record is a well-formed
        /// `TILE_FLUSH_COMMIT`.
        case clean
        /// The last record is an unmatched, well-formed `TILE_FLUSH_BEGIN`.
        case pending(epoch: UInt64, mode: TickMode)
        /// The last record is neither — a torn write, a truncated line, an
        /// unknown verb, an unparsable epoch or mode token, or
        /// a `BEGIN` at epoch 0, which cannot be a legitimate record: every
        /// flush writes epoch >= 1 and recovery's own `beginEpoch - 1`
        /// would underflow on it.
        case torn(String)
        /// `flush.wal` is present but cannot be read (a permission, an I/O
        /// error). Read as clean (`try?`), a dangling BEGIN would go unseen
        /// and its tile be re-ticked under a second BEGIN. Every open refuses it by name
        /// (`RouterError.tileFlushUnreadable`), nothing written.
        case unreadable(String)
    }

    /// `flush.wal`'s bytes; nil when the file is absent (a
    /// tile that never flushed); any other failure thrown (`WALReadError`),
    /// never read as absent.
    struct WALReadError: Error, CustomStringConvertible {
        let call: String
        let errno: Int32
        var description: String { "\(call) flush.wal: " + Reply.errnoWords(errno) }
    }

    /// Through the read helper — opened without blocking (a FIFO here would hang every TILED OPEN past
    /// SIGTERM), a regular file inside the root (a link to /dev/zero grew the daemon by ~12 GB/s), read
    /// once and bounded by `flushWALMaxBytes`; nil only when the file is absent; every other failure thrown
    /// by name (callers read it as `.unreadable`).
    static func readFlushWAL(dir: String) throws -> Data? {
        try DaemonFile.readIfPresent("\(dir)/flush.wal", .atMost(flushWALMaxBytes))
    }

    /// The most flush.wal bytes a tile load reads (about 3 million flushes of 80 bytes).
    static let flushWALMaxBytes = 256 << 20

    static func flushState(dir: String) -> FlushState {
        let data: Data
        do {
            guard let d = try readFlushWAL(dir: dir) else { return .clean }
            data = d
        } catch {
            return .unreadable(Reply.carriedLine(error) ?? Reply.errorWords(error))
        }
        return classifyFlushWAL(data)
    }

    /// A torn last record — the bytes
    /// after the wal's last newline. An append that never returned never
    /// started its step (the flush goes on only after the append returns),
    /// so the records before it are the wal's state; `keep` is their length.
    struct TornTail: Equatable {
        let keep: Int
        let tail: String
    }

    /// `flushState` as a writer open reads it: a last record that ends
    /// mid-record (a kill inside its append) is set aside (`cut`) and the
    /// records before it classified; the open cuts it (`cutTornTail`) once
    /// its plan has passed, before its first other write. Every other form
    /// reads as `flushState` reads it (a reader open, and `loadTile`, still
    /// refuse a torn tail by name).
    static func flushStateForWriter(dir: String) -> (state: FlushState, cut: TornTail?) {
        let data: Data
        do {
            guard let d = try readFlushWAL(dir: dir) else { return (.clean, nil) }
            data = d
        } catch {
            return (.unreadable(Reply.carriedLine(error) ?? Reply.errorWords(error)), nil)
        }
        guard let last = data.last, last != UInt8(ascii: "\n") else { return (classifyFlushWAL(data), nil) }
        let keep = data.lastIndex(of: UInt8(ascii: "\n")).map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
        let tail = String(decoding: data.suffix(from: data.index(data.startIndex, offsetBy: keep)), as: UTF8.self)
        return (classifyFlushWAL(data.prefix(keep)), TornTail(keep: keep, tail: tail))
    }

    /// `flush.wal` cut back to its first `keep` bytes (its
    /// whole records); removed when that leaves nothing (a tile that never
    /// flushed has no `flush.wal`). One `ftruncate` (or `unlink`).
    static func cutTornTail(dir: String, keep: Int) throws {
        let path: String
        do { path = try DaemonFile.forWrite("\(dir)/flush.wal") } catch let r as DaemonFile.Refusal { throw WriteError.refused(r) }
        if keep == 0 {
            let e = DaemonFile.unlinkNoFollow(path)
            guard e == 0 else { throw WriteError.posix(call: "unlink", path: path, errno: e) }
            return
        }
        let fd: Int32
        do { fd = try DaemonFile.openForWrite(path, create: false) } catch let r as DaemonFile.Refusal { throw WriteError.refused(r) }
        defer { Darwin.close(fd) }
        guard Darwin.ftruncate(fd, off_t(keep)) == 0 else {
            throw WriteError.posix(call: "ftruncate", path: path, errno: errno)
        }
    }

    /// `flush.wal`'s bytes, classified (`flushState`'s rules).
    static func classifyFlushWAL(_ data: Data) -> FlushState {
        guard let text = String(data: data, encoding: .utf8) else {
            return .torn("flush.wal is not valid UTF-8")
        }
        // A record is one LINE; the file always ends in "\n" when the write
        // completed, so a missing trailing newline is itself a torn write.
        guard !text.isEmpty else { return .clean }
        guard text.hasSuffix("\n") else {
            let tail = text.split(separator: "\n").last.map(String.init) ?? text
            return .torn("flush.wal ends mid-record, with no newline after \(Reply.quoted(tail))")
        }
        guard let last = text.split(separator: "\n").last else { return .clean }
        let parts = last.split(separator: " ").map(String.init)
        guard let verb = parts.first else { return .torn("flush.wal's last record is empty") }
        switch verb {
        case "TILE_FLUSH_COMMIT":
            guard parts.count == 3, UInt64(parts[2]) != nil else {
                return .torn("flush.wal's last record is a COMMIT with \(parts.count) field(s), "
                             + "not 3: '\(last)'")
            }
            return .clean
        case "TILE_FLUSH_BEGIN":
            guard parts.count == 4 else {
                return .torn("flush.wal's last record is a BEGIN with \(parts.count) field(s), "
                             + "not 4: '\(last)'")
            }
            guard let epoch = UInt64(parts[2]) else {
                return .torn("flush.wal's last BEGIN carries an unparsable epoch \(Reply.quoted(parts[2]))")
            }
            guard let mode = TickMode(walToken: parts[3]) else {
                return .torn("flush.wal's last BEGIN carries an unknown mode token \(Reply.quoted(parts[3]))")
            }
            // `bodyEpoch == beginEpoch - 1` would underflow on UInt64.
            guard epoch >= 1 else {
                return .torn("flush.wal's last BEGIN records epoch 0; every flush writes an "
                             + "epoch >= 1, and recovery's own epoch - 1 has no value at 0")
            }
            return .pending(epoch: epoch, mode: mode)
        default:
            return .torn("flush.wal's last record starts with \(Reply.quoted(verb)), "
                         + "neither TILE_FLUSH_BEGIN nor TILE_FLUSH_COMMIT")
        }
    }

    /// `flushState`, reduced to what older callers ask for: the
    /// unmatched BEGIN's `(epoch, mode)`. A TORN wal reports the
    /// epoch it was last seen at (0 when unknown) rather than "clean" —
    /// callers that must distinguish use `flushState` directly.
    ///
    /// An unreadable wal is thrown, never "no pending flush".
    static func pendingFlush(dir: String) throws -> (epoch: UInt64, mode: TickMode)? {
        guard let data = try readFlushWAL(dir: dir) else { return nil }
        switch classifyFlushWAL(data) {
        case .clean, .torn, .unreadable: return nil
        case .pending(let epoch, let mode): return (epoch, mode)
        }
    }

    /// The last COMMITTED `TILE_FLUSH_BEGIN`'s mode token for `epoch` —
    /// a partial round's mode comes from the tiles
    /// already AT the target epoch, read off their own `flush.wal` (the
    /// third field of the BEGIN that reached that epoch), never from a
    /// caller-supplied mode. `nil` if no such record exists (shouldn't
    /// happen for a tile actually at `epoch` via ordinary ticking).
    ///
    /// The router reads through `committedBeginMode`, which
    /// throws a read error; this form (a read error is nil) is kept for the
    /// committed tests that call it.
    static func lastCommittedBeginMode(dir: String, epoch: UInt64) -> String? {
        (try? committedBeginMode(dir: dir, epoch: epoch)) ?? nil
    }

    /// `lastCommittedBeginMode`, a read
    /// error thrown (`WALReadError`), never "no record". Only whole records
    /// (newline-terminated) are read: a torn last record never started its
    /// step (a writer open cuts it).
    static func committedBeginMode(dir: String, epoch: UInt64) throws -> String? {
        guard var data = try readFlushWAL(dir: dir) else { return nil }
        if let last = data.last, last != UInt8(ascii: "\n") {
            data = data.prefix(data.lastIndex(of: UInt8(ascii: "\n")).map {
                data.distance(from: data.startIndex, to: $0) + 1 } ?? 0)
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            let parts = line.split(separator: " ")
            guard parts.count == 4, parts[0] == "TILE_FLUSH_BEGIN",
                  let e = UInt64(parts[2]), e == epoch else { continue }
            return String(parts[3])
        }
        return nil
    }

    /// `body.dags`'s own tick count, read straight off the header (offset
    /// 20, per `DagDBSnapshot`'s documented layout) without a full
    /// `DagDBSnapshot.load` — so this never trips the sha256 / DAG-
    /// invariant checks a full load enforces. Shared by `peekTileEpochs`
    /// and the `pendingFlush`-refusal path in `loadTile`/
    /// `loadTileWithGhosts` (which need a body epoch for their error
    /// before they'd otherwise touch the body at all).
    /// `body.dags`'s own `nodeCount` field, read straight off the header
    /// (offset 8, per `DagDBSnapshot`'s documented 32-byte layout) without
    /// a full load — the three-count check needs the body's own count
    /// BEFORE any engine is allocated from the manifest's.
    static func bodyNodeCountRaw(path: String) throws -> UInt64 {
        // The header alone (a 4-byte field), not the whole body.
        try bodyNodeCount(of: try readTileFile(path, .prefix(DagDBSnapshot.headerSize)))
    }

    /// Same field, off bytes the caller already has — the load paths read
    /// `body.dags` once for its sha256 and must not read it twice.
    static func bodyNodeCount(of bodyData: Data) throws -> UInt64 {
        guard bodyData.count >= DagDBSnapshot.headerSize else {
            throw FilesError.metaDecode("body.dags shorter than the header")
        }
        let base = bodyData.startIndex
        let nodeCount = UInt32(bodyData[base + 8]) | UInt32(bodyData[base + 9]) << 8
            | UInt32(bodyData[base + 10]) << 16 | UInt32(bodyData[base + 11]) << 24
        return UInt64(nodeCount)
    }

    /// The three node counts a tile carries — `manifest.json`'s entry,
    /// `meta.json`'s, and `body.dags`'s own header field — agreed, or a
    /// refusal naming all three (three counts, one truth). Run BEFORE any
    /// engine is allocated: `Int(entry.nodeCount)` TRAPS above `Int.max`
    /// and, below it, would size an arbitrarily large Metal allocation from an
    /// unbounded `UInt64` read out of a JSON file.
    static func tileNodeCount(
        entry: TileEntry, meta: TileMeta, globalNodeCount: UInt64, bodyPath: String,
        bodyData: Data? = nil
    ) throws -> Int {
        // (a) the manifest's own claim, against the graph it belongs to.
        guard entry.nodeCount <= globalNodeCount else {
            throw RouterError.tileNodeCountInconsistent(
                entry.id, manifest: entry.nodeCount, meta: meta.nodeCount, body: nil,
                detail: "the manifest claims more nodes for this tile than the whole graph holds "
                    + "(globalNodeCount \(globalNodeCount))")
        }
        guard let n = Int(exactly: entry.nodeCount) else {
            throw RouterError.tileNodeCountInconsistent(
                entry.id, manifest: entry.nodeCount, meta: meta.nodeCount, body: nil,
                detail: "the manifest's node count is not representable as an Int")
        }
        // (b) the manifest's against meta.json's.
        guard entry.nodeCount == meta.nodeCount else {
            throw RouterError.tileNodeCountInconsistent(
                entry.id, manifest: entry.nodeCount, meta: meta.nodeCount, body: nil,
                detail: "manifest.json and meta.json disagree")
        }
        // (c) both against the body's own header field.
        let bodyCount = try bodyData.map { try bodyNodeCount(of: $0) }
            ?? bodyNodeCountRaw(path: bodyPath)
        guard bodyCount == entry.nodeCount else {
            throw RouterError.tileNodeCountInconsistent(
                entry.id, manifest: entry.nodeCount, meta: meta.nodeCount, body: bodyCount,
                detail: "body.dags's own header disagrees")
        }
        return n
    }

    private static func bodyTickCountRaw(path: String) throws -> UInt64 {
        // The header alone, through the read helper.
        let bodyData = try readTileFile(path, .prefix(DagDBSnapshot.headerSize))
        guard bodyData.count >= DagDBSnapshot.headerSize else {
            throw FilesError.metaDecode("body.dags shorter than the header")
        }
        let tickCount = UInt32(bodyData[20]) | UInt32(bodyData[21]) << 8
            | UInt32(bodyData[22]) << 16 | UInt32(bodyData[23]) << 24
        return UInt64(tickCount)
    }

    /// `(meta.json's lastPersistedTickEpoch, body.dags's own tickCount)` —
    /// exactly what a writer-role router's recovery needs to classify
    /// WHICH crash point a torn tile is at before choosing a repair path.
    static func peekTileEpochs(
        dataRoot: String, name: String, manifest: Manifest, tileId: UInt32
    ) throws -> (metaEpoch: UInt64, bodyEpoch: UInt64) {
        guard let entry = manifest.tiles.first(where: { $0.id == tileId }) else {
            throw FilesError.tileEntryMissing(tileId)
        }
        let dir = tileDirectory(dataRoot: dataRoot, name: name, entry: entry)
        let metaData = try DaemonFile.readAdmitted("\(dir)/meta.json")           // admitted on its true size
        let meta = try JSONDecoder().decode(TileMeta.self, from: metaData)
        let bodyEpoch = try bodyTickCountRaw(path: "\(dir)/body.dags")
        return (meta.lastPersistedTickEpoch, bodyEpoch)
    }

    /// Overwrites `<tileDir>/meta.json` with `meta` (atomic write, same
    /// discipline as `write`'s own meta.json write; through
    /// `writeFileAtomically`, `mid` its test seam).
    static func writeMeta(
        dataRoot: String, name: String, manifest: Manifest, tileId: UInt32, meta: TileMeta,
        mid: (() throws -> Void)? = nil
    ) throws {
        guard let entry = manifest.tiles.first(where: { $0.id == tileId }) else {
            throw FilesError.tileEntryMissing(tileId)
        }
        let dir = tileDirectory(dataRoot: dataRoot, name: name, entry: entry)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeFileAtomically(try encoder.encode(meta), to: "\(dir)/meta.json", mid: mid)
    }

    // MARK: - Lower strips by parity

    /// Parity lower-strip format version.
    /// v1 carried ONE truth byte per entry and the two modes contradicted
    /// each other on it (a rank-mode reader at `k` wants a register's
    /// PRE-latch value; a sync-mode reader at `k + 1` reads the same
    /// parity file wanting the POST-latch vector at `k`). v2 carries both.
    /// The step-one `halo_upper.bin`/`halo_lower.bin` snapshots (written
    /// once at tiling time, read by nothing in the ticker) stay v1.
    static let lowerStripFormatVersion: UInt32 = 2

    /// Writes `<tileDir>/halo_lower.<epoch mod 2>.bin` — this tile's
    /// boundary nodes' `(local id, truthPre, truthPost, type)` for every
    /// local referenced by any lower tile's `crossingsOut` (the distinct
    /// `localNode` set of this tile's own `crossingsIn`), at `epoch`.
    /// Ping-pong by parity so the previous epoch's strip survives this
    /// write (sync mode still needs it). Returns the byte count written
    /// (the `haloBytes` a test reads).
    ///
    /// **Two truth bytes**. `truthPost` is the
    /// source's value AFTER this round's latch — the engine's current
    /// truth, which is what a sync-mode reader of this parity file one
    /// world tick later wants (the previous vector). `truthPre` is its
    /// value BEFORE the latch — what a rank-mode reader at this same epoch
    /// wants, because the untiled engine evaluates every rank and only
    /// then latches, so a node reading a register sees the value it held
    /// before this tick's latch, while the tiled
    /// ticker latches each tile at the end of its own tick and flushes.
    /// For a combinational source the two are equal by construction: the
    /// kernel writes it during the pass and the latch never touches it.
    /// `preLatchOverrides` therefore carries exactly the register locals,
    /// read off the engine BEFORE the tick; anything absent from it gets
    /// `truthPre == truthPost`.
    @discardableResult
    static func writeLowerStrip(
        dataRoot: String, name: String, manifest: Manifest, tileId: UInt32,
        engine: DagDBEngine, realNodeCount: Int, epoch: UInt64,
        preLatchOverrides: [UInt64: UInt8] = [:], mid: (() throws -> Void)? = nil
    ) throws -> Int {
        guard let entry = manifest.tiles.first(where: { $0.id == tileId }) else {
            throw FilesError.tileEntryMissing(tileId)
        }
        let dir = tileDirectory(dataRoot: dataRoot, name: name, entry: entry)
        let locals = Set(entry.crossingsIn.map { $0.localNode }).sorted()
        // `local` comes from `manifest.json`'s crossingsIn; not compared to
        // the buffers' own bound, an out-of-range entry would read past the
        // end of the tile's Metal buffers and write whatever it found into
        // the strip.
        for local in locals where local >= UInt64(realNodeCount) {
            throw FilesError.crossingLocalOutOfRange(
                tile: tileId, local: local, nodeCount: realNodeCount)
        }
        let truthPtr = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: max(realNodeCount, 1))
        let typePtr = engine.nodeTypeBuf.contents().bindMemory(to: UInt8.self, capacity: max(realNodeCount, 1))
        let entries = locals.map { local -> LowerStripEntry in
            let post = truthPtr[Int(local)]
            return LowerStripEntry(
                localId: local, truthPre: preLatchOverrides[local] ?? post,
                truthPost: post, type: typePtr[Int(local)])
        }
        let path = "\(dir)/halo_lower.\(epoch % 2).bin"
        try writeLowerStripFile(
            entries: entries, sourceTileId: UInt64(tileId), targetTileId: UInt64(tileId),
            tickEpoch: epoch, path: path, mid: mid
        )
        return 40 + entries.count * 16
    }

    /// Reads `<tileDir>/halo_lower.<parity>.bin` — `(epoch, [local id:
    /// (pre, post, type)])`. Caller checks `epoch` against what it expected
    /// and picks the byte its own mode calls for (rank: `pre` at `k`;
    /// sync: `post` at `k − 1`); a mismatch is `RouterError.haloStale`, not
    /// thrown here (this is a dumb reader — staleness is a router-level,
    /// not a file-format, concept).
    static func readLowerStrip(
        dataRoot: String, name: String, manifest: Manifest, tileId: UInt32, parity: UInt64
    ) throws -> (epoch: UInt64, values: [UInt64: (pre: UInt8, post: UInt8, type: UInt8)]) {
        guard let entry = manifest.tiles.first(where: { $0.id == tileId }) else {
            throw FilesError.tileEntryMissing(tileId)
        }
        let dir = tileDirectory(dataRoot: dataRoot, name: name, entry: entry)
        let strip = try readLowerStripFile(path: "\(dir)/halo_lower.\(parity).bin")
        var values: [UInt64: (pre: UInt8, post: UInt8, type: UInt8)] = [:]
        for e in strip.entries { values[e.localId] = (e.truthPre, e.truthPost, e.type) }
        return (strip.tickEpoch, values)
    }

    // MARK: - Parity lower-strip file format (v2)

    /// One strip entry: `local_id u64 + truth_pre u8 + truth_post u8 +
    /// type u8 + 5 pad` = 16 bytes (v1's single truth byte plus one of its
    /// six pad bytes — the entry size is unchanged, the version is not).
    struct LowerStripEntry: Equatable {
        let localId: UInt64
        let truthPre: UInt8
        let truthPost: UInt8
        let type: UInt8
    }

    /// A parsed parity lower strip — the independent-parser side, exposed
    /// `internal` for `@testable import` use.
    struct LowerStripFile: Equatable {
        let version: UInt32
        let kind: UInt32
        let sourceTileId: UInt64
        let targetTileId: UInt64
        let tickEpoch: UInt64
        let entries: [LowerStripEntry]
    }

    /// `DAHA` v2 parity lower strip: magic(4) version(4)=2 strip_kind(4)=0
    /// nodeCount(4) source_tile_id(8) target_tile_id(8) tick_epoch(8) = 40
    /// bytes, then `nodeCount` × 16-byte `LowerStripEntry`.
    static func writeLowerStripFile(
        entries: [LowerStripEntry], sourceTileId: UInt64, targetTileId: UInt64,
        tickEpoch: UInt64, path: String, mid: (() throws -> Void)? = nil
    ) throws {
        var data = Data()
        func appendU32(_ v: UInt32) { var x = v; data.append(Data(bytes: &x, count: 4)) }
        func appendU64(_ v: UInt64) { var x = v; data.append(Data(bytes: &x, count: 8)) }
        data.append(contentsOf: [0x44, 0x41, 0x48, 0x41])  // "DAHA"
        appendU32(lowerStripFormatVersion)
        appendU32(0)  // kind 0 — lower strip
        appendU32(UInt32(entries.count))
        appendU64(sourceTileId)
        appendU64(targetTileId)
        appendU64(tickEpoch)
        for e in entries {
            appendU64(e.localId)
            data.append(e.truthPre)
            data.append(e.truthPost)
            data.append(e.type)
            data.append(contentsOf: [UInt8](repeating: 0, count: 5))
        }
        try writeFileAtomically(data, to: path, mid: mid)     // whole or not at all
    }

    static func readLowerStripFile(path: String) throws -> LowerStripFile {
        let data = try DaemonFile.readAdmitted(path)                           // admitted on its true size
        guard data.count >= 40 else { throw RankHaloError.truncated }
        func u32(_ off: Int) -> UInt32 {
            UInt32(data[off]) | UInt32(data[off + 1]) << 8 | UInt32(data[off + 2]) << 16 | UInt32(data[off + 3]) << 24
        }
        func u64(_ off: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(data[off + i]) << (8 * i) }
            return v
        }
        guard data[0] == 0x44, data[1] == 0x41, data[2] == 0x48, data[3] == 0x41 else {
            throw RankHaloError.badMagic
        }
        let version = u32(4)
        guard version == lowerStripFormatVersion else { throw RankHaloError.badVersion(version) }
        let kind = u32(8)
        // The writer always stamps 0 (kind 0 == lower strip);
        // anything else is a file this reader must not interpret.
        guard kind == 0 else { throw RankHaloError.badKind(kind) }
        let nodeCount = Int(u32(12))
        guard data.count >= 40 + nodeCount * 16 else { throw RankHaloError.truncated }
        var entries: [LowerStripEntry] = []
        entries.reserveCapacity(nodeCount)
        for i in 0..<nodeCount {
            let off = 40 + i * 16
            entries.append(LowerStripEntry(
                localId: u64(off), truthPre: data[off + 8], truthPost: data[off + 9], type: data[off + 10]))
        }
        return LowerStripFile(
            version: version, kind: kind, sourceTileId: u64(16), targetTileId: u64(24),
            tickEpoch: u64(32), entries: entries
        )
    }

    // MARK: - Rank-tile halo strips (§4.2)

    /// `DAHA` v1 rank-tile halo strip: magic(4) version(4) strip_kind(4)
    /// nodeCount(4) source_tile_id(8) target_tile_id(8) tick_epoch(8), then
    /// `nodeCount` × (local_id u64 + truth u8 + type u8 + 6 pad) = 16 bytes
    /// each. Distinct from `TileHalo`'s NSEW spatial-halo format (same
    /// magic, different per-strip shape — §4.2 vs §3.1 of the parent doc).
    private static func writeRankHalo(
        entries: [(localId: UInt64, truth: UInt8, type: UInt8, foreignTile: UInt32)],
        kind: UInt32, sourceTileId: UInt64, targetTileId: UInt64, tickEpoch: UInt64, path: String
    ) throws {
        var data = Data()
        func appendU32(_ v: UInt32) { var x = v; data.append(Data(bytes: &x, count: 4)) }
        func appendU64(_ v: UInt64) { var x = v; data.append(Data(bytes: &x, count: 8)) }
        data.append(contentsOf: [0x44, 0x41, 0x48, 0x41])  // "DAHA"
        appendU32(1)
        appendU32(kind)
        appendU32(UInt32(entries.count))
        appendU64(sourceTileId)
        appendU64(targetTileId)
        appendU64(tickEpoch)
        for e in entries {
            appendU64(e.localId)
            data.append(e.truth)
            data.append(e.type)
            data.append(contentsOf: [UInt8](repeating: 0, count: 6))
        }
        try DaemonFile.atomicWrite(data, to: path, sync: false)          // through the write helper (SAVE TILED's halo files)
    }

    /// Rank-tile halo reader — the independent parser side, exposed
    /// `internal` for `@testable import` use (`testHaloFilesParse`).
    struct RankHaloEntry: Equatable { let localId: UInt64; let truth: UInt8; let type: UInt8 }
    struct RankHalo: Equatable {
        let version: UInt32
        let kind: UInt32
        let sourceTileId: UInt64
        let targetTileId: UInt64
        let tickEpoch: UInt64
        let entries: [RankHaloEntry]
    }
    enum RankHaloError: Error, Equatable {
        case badMagic
        case truncated
        case badVersion(UInt32)
        /// The lower strip's `strip_kind` is checked: the writer always stamps 0.
        case badKind(UInt32)
    }

    /// The step-one rank-halo files
    /// (`halo_upper.bin` / `halo_lower.bin`) are v1 — `writeRankHalo`
    /// stamps 1 — and the reader refuses any other version
    /// (`RankHaloError.badVersion`) instead of reading it with the v1 layout.
    /// (The parity lower strips are a different format at
    /// `lowerStripFormatVersion` = 2 and already refused their own.)
    static let rankHaloFormatVersion: UInt32 = 1

    static func readRankHalo(path: String) throws -> RankHalo {
        let data = try readTileFile(path)                                      // through the read helper
        guard data.count >= 40 else { throw RankHaloError.truncated }
        func u32(_ off: Int) -> UInt32 {
            UInt32(data[off]) | UInt32(data[off + 1]) << 8 | UInt32(data[off + 2]) << 16 | UInt32(data[off + 3]) << 24
        }
        func u64(_ off: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(data[off + i]) << (8 * i) }
            return v
        }
        guard data[0] == 0x44, data[1] == 0x41, data[2] == 0x48, data[3] == 0x41 else {
            throw RankHaloError.badMagic
        }
        let version = u32(4)
        guard version == rankHaloFormatVersion else { throw RankHaloError.badVersion(version) }
        let kind = u32(8)
        let nodeCount = Int(u32(12))
        let sourceTileId = u64(16)
        let targetTileId = u64(24)
        let tickEpoch = u64(32)
        guard data.count >= 40 + nodeCount * 16 else { throw RankHaloError.truncated }
        var entries: [RankHaloEntry] = []
        entries.reserveCapacity(nodeCount)
        for i in 0..<nodeCount {
            let off = 40 + i * 16
            let localId = u64(off)
            let truth = data[off + 8]
            let type = data[off + 9]
            entries.append(RankHaloEntry(localId: localId, truth: truth, type: type))
        }
        return RankHalo(
            version: version, kind: kind, sourceTileId: sourceTileId, targetTileId: targetTileId,
            tickEpoch: tickEpoch, entries: entries
        )
    }
}
