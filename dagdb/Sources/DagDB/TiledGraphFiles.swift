/// TiledGraphFiles — T1 tile file writer/reader for the tiling gate
/// contract (`docs/contracts/TILING_GATES_FROZEN.md`, gate T1; layout
/// `docs/tiled-streaming.md` §4, with the contract's amendment that
/// `body.dags` is the CURRENT `DagDBSnapshot` format, not a frozen v3).
///
/// Splits one `TiledFixture.Object` into tile directories by rank range:
/// `<dataRoot>/<name>/tile_<lo>_<hi>/{body.dags, halo_lower.bin,
/// halo_upper.bin, meta.json}` plus a graph-level `manifest.json`.
///
/// Edge direction note (frozen by the fixture's own draw order, see
/// `TiledFixture.generate`, corrected by AMENDMENT 1 item 1): a node `u`'s
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
        /// untiled engine's own buffers (ticking gates item 5,
        /// `TiledGraphRouter.truthArray`'s index-order requirement) — the
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
        /// This tile's own last-flushed world epoch (ticking gates
        /// AMENDMENT 2, letter 2: per-tile epochs, no graph-level
        /// counter). Set to the daemon's own tickCount at `SAVE TILED`/
        /// `write` time (0 for every `TiledFixture.Object` — the fixtures
        /// carry no tick history — and for any pre-ticking-gate manifest,
        /// default on decode); rewritten to the flushed epoch by every
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
        /// Audit C finding 13: `perBoundary`'s `up`/`down` count only the
        /// crossings whose remote tile is exactly `k + 1`, while this
        /// file's own header says a 3-ring draw can skip more than one
        /// tile and `crossings` counts every one. The gap was a SILENT
        /// undercount in `perBoundary`; it is counted and reported here
        /// instead — `crossings == sum(perBoundary.up) + crossingsSkippingATile`
        /// is an identity, and a tiling with a tile-skipping edge makes
        /// `sum(perBoundary.up) < crossings` observable.
        public let crossingsSkippingATile: Int
        public let perBoundary: [BoundaryCount]
        public let bytesPerTile: [Int]
        public let writeMsPerTile: [Double]
        public let globalOf: [UInt64]
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
        /// Ticking gates W5: `write` refuses a live engine whose
        /// `backEdgeSrcs`/`backEdgeDsts` contains an edge whose two ends
        /// fall in different tiles under the given boundaries — checked
        /// BEFORE any directory is created, so a refused `SAVE TILED`
        /// leaves nothing on disk. `src`/`dst` are the ENGINE node indices
        /// (not `GlobalNodeID`s — the graph was never split, so there is
        /// no tile assignment to encode them with).
        case crossTileBackEdge(src: UInt32, dst: UInt32)
        /// Audit C finding 2: `manifest.json`'s own `format`/`version`
        /// fields were stamped by `write` and never read back, so any
        /// format string and any version decoded with the v1 layout.
        case manifestFormatUnsupported(found: String, expected: String)
        case manifestVersionUnsupported(found: Int, expected: Int)
        /// Audit C finding 6: a `crossingsIn` entry naming a local id at or
        /// past the tile's own node count — an out-of-bounds Metal-buffer
        /// read written straight into the parity strip.
        case crossingLocalOutOfRange(tile: UInt32, local: UInt64, nodeCount: Int)
        /// Audit C finding 7: the body's `-2` cross-tile slot count for a
        /// local and the number of `crossingsOut` entries `meta.json` lists
        /// for that same local are two independent file-derived numbers.
        /// More slots than crossings trapped; fewer wired the graph wrong
        /// and left a sentinel in place.
        case crossingSlotCountMismatch(tile: UInt32, local: UInt64, slots: Int, crossings: Int)

        public var description: String {
            switch self {
            case .manifestMissing(let p): return "TiledGraphFiles: manifest not found at '\(p)'"
            case .manifestDecode(let e): return "TiledGraphFiles: manifest decode failed: \(e)"
            case .tileEntryMissing(let id): return "TiledGraphFiles: tile \(id) not present in manifest"
            case .metaDecode(let e): return "TiledGraphFiles: meta.json decode failed: \(e)"
            case .crossTileBackEdge(let src, let dst):
                return "TiledGraphFiles: back edge crosses a tile boundary (\(src)→\(dst))"
            case .manifestFormatUnsupported(let found, let expected):
                return "TiledGraphFiles: manifest format '\(found)' is not '\(expected)'"
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

    /// T-S2 (`DagDBEngine.init`, AMENDMENT 1 item 4) fixed the engine's own
    /// zero-length-Metal-buffer failure for empty colour buckets, so this
    /// file no longer needs to pad tile-local engines up to 11 nodes — the
    /// tile-local grid is sized EXACTLY to the tile. The only remaining
    /// guard is `max(ln, 1)`: a literally empty tile (`ln == 0`, not
    /// expected for any side/tiling combo in the gate contract, but not
    /// ruled out in general) still needs a `HexGrid` with a positive
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

    // MARK: - Write (T1)

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
    /// `TiledFixture.Object`) into tile directories, for `SAVE TILED`
    /// (gate T5). `grid` is accepted for parity with `TiledFixture.Object`'s
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
    /// from the original T1 writer, just parameterized on `engine` +
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

        func tileOf(rank: UInt64) -> Int {
            for (i, b) in boundaries.enumerated() where rank < b { return i }
            return boundaries.count
        }

        var tileOfNode = [Int](repeating: 0, count: n)
        for m in 0..<n { tileOfNode[m] = tileOf(rank: rankPtr[m]) }

        // Ticking gates W5: refuse a cross-tile BACK_EDGE before touching
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
        // so each belongs to exactly one tile. Ticking gates AMENDMENT 6,
        // letter 1: the repaired objects carry registers, and a tile body
        // that dropped them would tick a different graph from the untiled
        // engine — W1/W2 would fail on a correct ticker.
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

        let graphDir = graphDirectory(dataRoot: dataRoot, name: name)
        try FileManager.default.createDirectory(atPath: graphDir, withIntermediateDirectories: true)

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

        for t in 0..<tileCount {
            let members = membersByTile[t]
            let ln = members.count

            var lr = [UInt64](repeating: 0, count: ln)
            var ltState = [UInt8](repeating: 0, count: ln)
            var lty = [UInt8](repeating: 0, count: ln)
            var llow = [UInt32](repeating: 0, count: ln)
            var lhigh = [UInt32](repeating: 0, count: ln)
            var lnb = [Int32](repeating: -1, count: ln * 6)

            for (li, gm) in members.enumerated() {
                lr[li] = rankPtr[gm]
                ltState[li] = truthPtr[gm]
                lty[li] = typePtr[gm]
                llow[li] = lutLowPtr[gm]
                lhigh[li] = lutHighPtr[gm]
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
                        // foreignRank (ticking gates): the rank of the node EACH
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
            }
            // Registers + back edges (unchecked: the source engine already
            // validated the zero-combinational-fan-in rule, and the local
            // copy is the same graph). `DagDBSnapshot.save` writes them as
            // the v7 back-edge section; `load` restores the register flags.
            for be in backEdgesByTile[t] {
                try tileEngine.addBackEdgeUnchecked(src: be.src, dst: be.dst)
            }

            let dir = "\(graphDir)/\(tileDirName(lo: rankLoOf[t], hi: rankHiOf[t]))"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let bodyPath = "\(dir)/body.dags"

            let (bytesWritten, _, elapsedMs) = try DagDBSnapshot.save(
                engine: tileEngine, nodeCount: ln, gridW: ln, gridH: 1,
                tickCount: tickCount, path: bodyPath
            )
            bytesPerTile[t] = bytesWritten
            writeMsPerTile[t] = elapsedMs

            let bodyData = try Data(contentsOf: URL(fileURLWithPath: bodyPath))
            let bodyHash = DagDBSnapshot.sha256Hex(bodyData)

            let meta = TileMeta(
                id: UInt32(t), rankLo: rankLoOf[t], rankHi: rankHiOf[t], nodeCount: UInt64(ln),
                lastPersistedTickEpoch: UInt64(tickCount),
                crossingsOut: crossingsOutByTile[t], crossingsIn: crossingsInByTile[t]
            )
            let metaEncoder = JSONEncoder()
            metaEncoder.outputFormatting = [.sortedKeys]
            let metaData = try metaEncoder.encode(meta)
            try metaData.write(to: URL(fileURLWithPath: "\(dir)/meta.json"), options: [.atomic])

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
        // Ticking gates AMENDMENT 4, letter 1 — ONE EPOCH EVERYWHERE. The
        // saved tick count `k` goes on the manifest entry, `meta.json`, the
        // body header AND BOTH parity strips: the parity-`k mod 2` strip is
        // the world's current truth at epoch `k`, and the other parity
        // carries the SAME truth values with its own recorded epoch
        // `k − 1` (both at 0 when `k == 0`). Before this, `write` stamped
        // the count on the manifest entry alone and hard-coded 0 into the
        // other three, which left sync mode's first world tick at `k + 1`
        // looking for a `k` strip that was never written — the W5 FAIL the
        // blind verifier found.
        let savedEpoch = UInt64(tickCount)
        let priorEpoch: UInt64 = savedEpoch == 0 ? 0 : savedEpoch - 1
        /// Audit C finding 14: the file header documents `source_tile_id` /
        /// `target_tile_id` as "the most-referenced foreign tile", but the
        /// writer took `.first`'s — a different tile whenever a tile
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
            // AMENDMENT 8: both truth bytes of every entry carry the SAME
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
        try writeManifest(dataRoot: dataRoot, name: name, manifest: manifest)

        // AMENDMENT 1, item 1: post-fix, a node's slots hold HIGHER-rank
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
    }

    // MARK: - Read manifest

    /// The only manifest format string and version this reader knows —
    /// the pair `write` stamps. Audit C finding 2.
    public static let manifestFormat = "dagdb-tiled-manifest"
    public static let manifestFormatVersion = 1

    public static func readManifest(dataRoot: String, name: String) throws -> Manifest {
        let path = "\(graphDirectory(dataRoot: dataRoot, name: name))/manifest.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw FilesError.manifestMissing(path)
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw FilesError.manifestDecode("\(error)")
        }
        // Finding 2: both stamped fields are read back and refused by name.
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
    /// discipline as `writeMeta`'s. Ticking gates AMENDMENT 1: every tile
    /// flush calls this to rewrite that tile's entry (`bodySHA256`,
    /// `tickEpoch`) before its `TILE_FLUSH_COMMIT` — one authority for
    /// both the query path (`loadTile`) and the ticker
    /// (`loadTileWithGhosts`).
    static func writeManifest(dataRoot: String, name: String, manifest: Manifest) throws {
        let graphDir = graphDirectory(dataRoot: dataRoot, name: name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: URL(fileURLWithPath: "\(graphDir)/manifest.json"), options: [.atomic])
    }

    // MARK: - Load one tile (T4)

    /// Loads one tile's `body.dags` + `meta.json`. Ticking gates AMENDMENT
    /// 2, letter 1 ("recovery precedes the hash check"): a torn tile
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
            // Findings 10/11: a torn flush is a torn flush, never "clean".
            throw RouterError.tileFlushMalformed(tileId, detail: detail)
        }

        let bodyData = try Data(contentsOf: URL(fileURLWithPath: bodyPath))
        let actualHash = DagDBSnapshot.sha256Hex(bodyData)
        guard actualHash == entry.bodySHA256 else {
            throw RouterError.tileHashMismatch(tileId, expected: entry.bodySHA256, actual: actualHash)
        }

        let metaData = try Data(contentsOf: URL(fileURLWithPath: metaPath))
        let meta: TileMeta
        do {
            meta = try JSONDecoder().decode(TileMeta.self, from: metaData)
        } catch {
            throw FilesError.metaDecode("\(error)")
        }

        // Findings 4, 5: the three counts agree, or nothing is allocated.
        let n = try tileNodeCount(
            entry: entry, meta: meta, globalNodeCount: manifest.globalNodeCount,
            bodyPath: bodyPath, bodyData: bodyData)
        let engine = try tileLocalEngine(nodeCount: n)

        // validate:true (AMENDMENT 1, item 1) — the fixture's generator now
        // matches the engine's own convention (a node's slots hold
        // strictly-higher-rank sources, `rank(src) > rank(dst)`), so
        // DagDBSnapshot's general DAG-invariant check applies and must
        // pass. verifyManifest:true — `DagDBSnapshot.save` always writes a
        // side-by-side `<path>.sha256` sidecar (see its "G73" comment), so
        // the sidecar is NOT absent here; this is a second, redundant
        // check on top of the router's own manifest-based hash comparison
        // above (RouterError.tileHashMismatch, which fires first and is
        // the gate's authority) — defense in depth, not a substitute.
        let loadResult = try DagDBSnapshot.load(
            engine: engine, nodeCount: n, gridW: n, gridH: 1,
            path: bodyPath, validate: true, verifyManifest: true
        )

        guard UInt64(loadResult.fileTicks) == meta.lastPersistedTickEpoch else {
            throw RouterError.tileInconsistent(
                tileId, metaEpoch: meta.lastPersistedTickEpoch, bodyEpoch: UInt64(loadResult.fileTicks)
            )
        }

        let leftoverTemp = FileManager.default.fileExists(atPath: bodyPath + ".tmp")

        return LoadedTile(engine: engine, meta: meta, leftoverTemp: leftoverTemp)
    }

    // MARK: - Ghosted tile load (ticking gates, item 1)

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

    /// Loads `body.dags` + `meta.json` — IDENTICALLY to `loadTile` now
    /// (ticking gates AMENDMENT 1: "one authority for both paths" — the
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
    /// loaded (AMENDMENT 2, letter 1: recovery precedes the hash check —
    /// the manifest-vs-sidecar sha256 comparison below only runs on a tile
    /// whose `flush.wal` is clean). Recovery's whole job is reconciling a
    /// `meta.json`/`body.dags` epoch MISMATCH (case i: meta ahead of a
    /// body that never got renamed; case ii: body ahead of a meta that
    /// never got rewritten) — so `true` also bypasses the ordinary
    /// `tileHashMismatch`/`tileInconsistent` checks below, which exist to
    /// refuse exactly those mismatches for every NON-recovery caller.
    public static func loadTileWithGhosts(
        dataRoot: String, name: String, manifest: Manifest, tileId: UInt32,
        ignorePendingFlush: Bool = false
    ) throws -> LoadedGhostedTile {
        guard let entry = manifest.tiles.first(where: { $0.id == tileId }) else {
            throw FilesError.tileEntryMissing(tileId)
        }
        let dir = tileDirectory(dataRoot: dataRoot, name: name, entry: entry)
        let bodyPath = "\(dir)/body.dags"
        let metaPath = "\(dir)/meta.json"

        if !ignorePendingFlush {
            switch flushState(dir: dir) {
            case .clean: break
            case .pending(let epoch, _):
                let bodyEpoch = (try? bodyTickCountRaw(path: bodyPath)) ?? 0
                throw RouterError.tileFlushIncomplete(tileId, epoch: epoch, bodyEpoch: bodyEpoch)
            case .torn(let detail):
                throw RouterError.tileFlushMalformed(tileId, detail: detail)
            }
        }

        let metaData = try Data(contentsOf: URL(fileURLWithPath: metaPath))
        let meta: TileMeta
        do {
            meta = try JSONDecoder().decode(TileMeta.self, from: metaData)
        } catch {
            throw FilesError.metaDecode("\(error)")
        }

        var bodyBytes: Data? = nil
        if !ignorePendingFlush {
            let bodyData = try Data(contentsOf: URL(fileURLWithPath: bodyPath))
            let actualHash = DagDBSnapshot.sha256Hex(bodyData)
            guard actualHash == entry.bodySHA256 else {
                throw RouterError.tileHashMismatch(tileId, expected: entry.bodySHA256, actual: actualHash)
            }
            bodyBytes = bodyData
        }

        // Findings 4, 5: the three counts agree, or nothing is allocated.
        let n = try tileNodeCount(
            entry: entry, meta: meta, globalNodeCount: manifest.globalNodeCount,
            bodyPath: bodyPath, bodyData: bodyBytes)
        let realEngine = try tileLocalEngine(nodeCount: n)
        let loadResult = try DagDBSnapshot.load(
            engine: realEngine, nodeCount: n, gridW: n, gridH: 1,
            path: bodyPath, validate: true, verifyManifest: true
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
        }

        // Registers + back edges the body carried (AMENDMENT 6, letter 1).
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
            // Audit C finding 7: the body's `-2` slot count for a local and
            // the number of crossings meta.json lists for it are two
            // INDEPENDENT file-derived numbers. More slots than crossings
            // TRAPPED on `list[cursor]`; fewer wired the graph wrong,
            // ignored the surplus crossings and left a `-2` sentinel in
            // place. Both are refused by name, and the whole tile is
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
            // Finding 6's shape on the read side: a crossing naming a local
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

        let leftoverTemp = FileManager.default.fileExists(atPath: bodyPath + ".tmp")
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

    // MARK: - Per-tile flush WAL (ticking gates item 4, §7.2)

    /// Appends one text record (`"TILE_FLUSH_BEGIN <tile> <epoch>
    /// <rank|sync>"` / `"TILE_FLUSH_COMMIT <tile> <epoch>"`) to
    /// `<tileDir>/flush.wal`, creating the file if absent. Not fsync'd —
    /// the crash points this gate contract simulates are crafted directly
    /// on the test's copy of the files (§ W4), not induced by an actual
    /// process kill mid-write.
    static func appendFlushWAL(path: String, record: String) throws {
        let line = Data((record + "\n").utf8)
        if FileManager.default.fileExists(atPath: path) {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
        } else {
            try line.write(to: URL(fileURLWithPath: path))
        }
    }

    /// `nil` if `<dir>/flush.wal` is absent or its last record is a
    /// `TILE_FLUSH_COMMIT` (clean); the `BEGIN`'s `(epoch, mode)` if the
    /// last record is an unmatched `TILE_FLUSH_BEGIN` (torn flush) —
    /// AMENDMENT 2, letter 4: the BEGIN record carries the mode as its
    /// third field, so recovery needs nothing outside the tile directory
    /// to know which mode's ghost-sourcing rule to replay.
    /// Audit C finding 11: `flush.wal`'s last record, classified. The old
    /// reader returned `nil` — i.e. "clean" — for ANYTHING that was not a
    /// well-formed four-field BEGIN, so a torn final write (the file is
    /// unfsynced appended text) and a three-field BEGIN predating the mode
    /// field both read as committed and the tile loaded.
    enum FlushState: Equatable {
        /// No `flush.wal`, or its last record is a well-formed
        /// `TILE_FLUSH_COMMIT`.
        case clean
        /// The last record is an unmatched, well-formed `TILE_FLUSH_BEGIN`.
        case pending(epoch: UInt64, mode: TickMode)
        /// The last record is neither — a torn write, a truncated line, an
        /// unknown verb, an unparsable epoch or mode token, or (finding 10)
        /// a `BEGIN` at epoch 0, which cannot be a legitimate record: every
        /// flush writes epoch >= 1 and recovery's own `beginEpoch - 1`
        /// would underflow on it.
        case torn(String)
    }

    static func flushState(dir: String) -> FlushState {
        let path = "\(dir)/flush.wal"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return .clean }
        guard let text = String(data: data, encoding: .utf8) else {
            return .torn("flush.wal is not valid UTF-8")
        }
        // A record is one LINE; the file always ends in "\n" when the write
        // completed, so a missing trailing newline is itself a torn write.
        guard !text.isEmpty else { return .clean }
        guard text.hasSuffix("\n") else {
            let tail = text.split(separator: "\n").last.map(String.init) ?? text
            return .torn("flush.wal ends mid-record, with no newline after '\(tail)'")
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
                return .torn("flush.wal's last BEGIN carries an unparsable epoch '\(parts[2])'")
            }
            guard let mode = TickMode(walToken: parts[3]) else {
                return .torn("flush.wal's last BEGIN carries an unknown mode token '\(parts[3])'")
            }
            // Finding 10: `bodyEpoch == beginEpoch - 1` on UInt64 underflowed.
            guard epoch >= 1 else {
                return .torn("flush.wal's last BEGIN records epoch 0; every flush writes an "
                             + "epoch >= 1, and recovery's own epoch - 1 has no value at 0")
            }
            return .pending(epoch: epoch, mode: mode)
        default:
            return .torn("flush.wal's last record starts with '\(verb)', "
                         + "neither TILE_FLUSH_BEGIN nor TILE_FLUSH_COMMIT")
        }
    }

    /// `flushState`, reduced to what the pre-audit callers asked for: the
    /// unmatched BEGIN's `(epoch, mode)`. A TORN wal now reports the
    /// epoch it was last seen at (0 when unknown) rather than "clean" —
    /// callers that must distinguish use `flushState` directly.
    static func pendingFlush(dir: String) -> (epoch: UInt64, mode: TickMode)? {
        switch flushState(dir: dir) {
        case .clean: return nil
        case .pending(let epoch, let mode): return (epoch, mode)
        case .torn: return nil
        }
    }

    /// The last COMMITTED `TILE_FLUSH_BEGIN`'s mode token for `epoch` —
    /// AMENDMENT 3, letter 2: a partial round's mode comes from the tiles
    /// already AT the target epoch, read off their own `flush.wal` (the
    /// third field of the BEGIN that reached that epoch), never from a
    /// caller-supplied mode. `nil` if no such record exists (shouldn't
    /// happen for a tile actually at `epoch` via ordinary ticking).
    static func lastCommittedBeginMode(dir: String, epoch: UInt64) -> String? {
        let path = "\(dir)/flush.wal"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) else { return nil }
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
    /// invariant gates a full load enforces. Shared by `peekTileEpochs`
    /// and the `pendingFlush`-refusal path in `loadTile`/
    /// `loadTileWithGhosts` (which need a body epoch for their error
    /// before they'd otherwise touch the body at all).
    /// `body.dags`'s own `nodeCount` field, read straight off the header
    /// (offset 8, per `DagDBSnapshot`'s documented 32-byte layout) without
    /// a full load — audit C findings 4 and 5 need the body's own count
    /// BEFORE any engine is allocated from the manifest's.
    static func bodyNodeCountRaw(path: String) throws -> UInt64 {
        try bodyNodeCount(of: try Data(contentsOf: URL(fileURLWithPath: path)))
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
    /// refusal naming all three (audit C findings 4, 5 and 12; contract
    /// ruling "Tile files: three counts, one truth"). Run BEFORE any
    /// engine is allocated: `Int(entry.nodeCount)` TRAPPED above `Int.max`
    /// and, below it, sized an arbitrarily large Metal allocation from an
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
        let bodyData = try Data(contentsOf: URL(fileURLWithPath: path))
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
        let metaData = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/meta.json"))
        let meta = try JSONDecoder().decode(TileMeta.self, from: metaData)
        let bodyEpoch = try bodyTickCountRaw(path: "\(dir)/body.dags")
        return (meta.lastPersistedTickEpoch, bodyEpoch)
    }

    /// Overwrites `<tileDir>/meta.json` with `meta` (atomic write, same
    /// discipline as `write`'s own meta.json write).
    static func writeMeta(
        dataRoot: String, name: String, manifest: Manifest, tileId: UInt32, meta: TileMeta
    ) throws {
        guard let entry = manifest.tiles.first(where: { $0.id == tileId }) else {
            throw FilesError.tileEntryMissing(tileId)
        }
        let dir = tileDirectory(dataRoot: dataRoot, name: name, entry: entry)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(meta).write(to: URL(fileURLWithPath: "\(dir)/meta.json"), options: [.atomic])
    }

    // MARK: - Lower strips by parity (ticking gates item 2)

    /// Parity lower-strip format version — ticking gates AMENDMENT 8.
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
    /// (W6's `haloBytes`).
    ///
    /// **Two truth bytes** (ticking gates AMENDMENT 8). `truthPost` is the
    /// source's value AFTER this round's latch — the engine's current
    /// truth, which is what a sync-mode reader of this parity file one
    /// world tick later wants (the previous vector). `truthPre` is its
    /// value BEFORE the latch — what a rank-mode reader at this same epoch
    /// wants, because the untiled engine evaluates every rank and only
    /// then latches, so a node reading a register sees the value it held
    /// before this tick's latch (AMENDMENT 7, finding A), while the tiled
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
        preLatchOverrides: [UInt64: UInt8] = [:]
    ) throws -> Int {
        guard let entry = manifest.tiles.first(where: { $0.id == tileId }) else {
            throw FilesError.tileEntryMissing(tileId)
        }
        let dir = tileDirectory(dataRoot: dataRoot, name: name, entry: entry)
        let locals = Set(entry.crossingsIn.map { $0.localNode }).sorted()
        // Audit C finding 6: `local` comes from `manifest.json`'s
        // crossingsIn and was never compared to the buffers' own bound —
        // an out-of-range entry read past the end of the tile's Metal
        // buffers and wrote whatever it found into the strip.
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
            tickEpoch: epoch, path: path
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

    // MARK: - Parity lower-strip file format (v2, AMENDMENT 8)

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
        tickEpoch: UInt64, path: String
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
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    }

    static func readLowerStripFile(path: String) throws -> LowerStripFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
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
        // Finding 3: the writer always stamps 0 (kind 0 == lower strip);
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
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
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
        /// Audit C finding 3: the lower strip's `strip_kind` was read and
        /// returned unchecked, though the writer always stamps 0.
        case badKind(UInt32)
    }

    /// Audit C finding 1: the step-one rank-halo files
    /// (`halo_upper.bin` / `halo_lower.bin`) are v1 — `writeRankHalo`
    /// stamps 1 — and the reader accepted ANY version with the v1 layout
    /// even though `RankHaloError.badVersion` existed for exactly this.
    /// (The parity lower strips are a different format at
    /// `lowerStripFormatVersion` = 2 and already refused their own.)
    static let rankHaloFormatVersion: UInt32 = 1

    static func readRankHalo(path: String) throws -> RankHalo {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
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
