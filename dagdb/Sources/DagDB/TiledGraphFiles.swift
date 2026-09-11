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

        public init(
            id: UInt32, rankLo: UInt64, rankHi: UInt64, nodeCount: UInt64,
            bodySHA256: String, crossingsOut: [Crossing], crossingsIn: [Crossing]
        ) {
            self.id = id
            self.rankLo = rankLo
            self.rankHi = rankHi
            self.nodeCount = nodeCount
            self.bodySHA256 = bodySHA256
            self.crossingsOut = crossingsOut
            self.crossingsIn = crossingsIn
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

        public var description: String {
            switch self {
            case .manifestMissing(let p): return "TiledGraphFiles: manifest not found at '\(p)'"
            case .manifestDecode(let e): return "TiledGraphFiles: manifest decode failed: \(e)"
            case .tileEntryMissing(let id): return "TiledGraphFiles: tile \(id) not present in manifest"
            case .metaDecode(let e): return "TiledGraphFiles: meta.json decode failed: \(e)"
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
        let grid = HexGrid(width: width, height: 1)
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
        engine: DagDBEngine, grid: HexGrid, dataRoot: String, name: String, boundaries: [UInt64]
    ) throws -> WriteReport {
        let n = engine.nodeCount
        let rankScanPtr = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: max(n, 1))
        var observedMaxRank: UInt64 = 0
        for i in 0..<n { observedMaxRank = max(observedMaxRank, rankScanPtr[i]) }
        return try write(
            engine: engine, maxRank: observedMaxRank,
            dataRoot: dataRoot, name: name, boundaries: boundaries
        )
    }

    /// Shared implementation behind both `write(object:...)` and
    /// `write(engine:grid:...)` — everything from here down is unchanged
    /// from the original T1 writer, just parameterized on `engine` +
    /// `maxRank` instead of reading them off a `TiledFixture.Object`.
    private static func write(
        engine: DagDBEngine, maxRank: UInt64, dataRoot: String, name: String, boundaries: [UInt64]
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
                        crossingsOutByTile[t].append(Crossing(localNode: UInt64(li), remoteNode: remote))
                        let backRemote = try GlobalNodeID(tileId: UInt32(t), localNodeId: UInt64(li))
                        crossingsInByTile[foreignTile].append(Crossing(localNode: foreignLocal, remoteNode: backRemote))
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

            let dir = "\(graphDir)/\(tileDirName(lo: rankLoOf[t], hi: rankHiOf[t]))"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let bodyPath = "\(dir)/body.dags"

            let (bytesWritten, _, elapsedMs) = try DagDBSnapshot.save(
                engine: tileEngine, nodeCount: ln, gridW: ln, gridH: 1,
                tickCount: 0, path: bodyPath
            )
            bytesPerTile[t] = bytesWritten
            writeMsPerTile[t] = elapsedMs

            let bodyData = try Data(contentsOf: URL(fileURLWithPath: bodyPath))
            let bodyHash = DagDBSnapshot.sha256Hex(bodyData)

            let meta = TileMeta(
                id: UInt32(t), rankLo: rankLoOf[t], rankHi: rankHiOf[t], nodeCount: UInt64(ln),
                lastPersistedTickEpoch: 0,
                crossingsOut: crossingsOutByTile[t], crossingsIn: crossingsInByTile[t]
            )
            let metaEncoder = JSONEncoder()
            metaEncoder.outputFormatting = [.sortedKeys]
            let metaData = try metaEncoder.encode(meta)
            try metaData.write(to: URL(fileURLWithPath: "\(dir)/meta.json"), options: [.atomic])

            tileEntries[t] = TileEntry(
                id: UInt32(t), rankLo: rankLoOf[t], rankHi: rankHiOf[t], nodeCount: UInt64(ln),
                bodySHA256: bodyHash,
                crossingsOut: crossingsOutByTile[t], crossingsIn: crossingsInByTile[t]
            )
        }

        // Pass 3: halo strips, now that every tile's crossings (and
        // therefore every foreign-tile-value snapshot) are known.
        for t in 0..<tileCount {
            let upperTarget = upperEntriesByTile[t].first?.foreignTile
            try writeRankHalo(
                entries: upperEntriesByTile[t].map { ($0.localId, $0.truth, $0.type, $0.foreignTile) },
                kind: 1,
                sourceTileId: UInt64(upperTarget ?? UInt32(t)), targetTileId: UInt64(t),
                tickEpoch: 0,
                path: "\(graphDir)/\(tileDirName(lo: rankLoOf[t], hi: rankHiOf[t]))/halo_upper.bin"
            )
            let lowerSource = lowerEntriesByTile[t].first?.foreignTile
            try writeRankHalo(
                entries: lowerEntriesByTile[t].map { ($0.localId, $0.truth, $0.type, $0.foreignTile) },
                kind: 0,
                sourceTileId: UInt64(t), targetTileId: UInt64(lowerSource ?? UInt32(t)),
                tickEpoch: 0,
                path: "\(graphDir)/\(tileDirName(lo: rankLoOf[t], hi: rankHiOf[t]))/halo_lower.bin"
            )
        }

        let manifest = Manifest(
            format: "dagdb-tiled-manifest", version: 1, name: name, boundaries: boundaries,
            globalNodeCount: UInt64(n), tiles: tileEntries
        )
        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = [.sortedKeys]
        let manifestData = try manifestEncoder.encode(manifest)
        try manifestData.write(to: URL(fileURLWithPath: "\(graphDir)/manifest.json"), options: [.atomic])

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

        return WriteReport(
            tiles: tileCount, nodes: n, crossings: totalCrossings, perBoundary: perBoundary,
            bytesPerTile: bytesPerTile, writeMsPerTile: writeMsPerTile, globalOf: globalOf
        )
    }

    // MARK: - Read manifest

    public static func readManifest(dataRoot: String, name: String) throws -> Manifest {
        let path = "\(graphDirectory(dataRoot: dataRoot, name: name))/manifest.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw FilesError.manifestMissing(path)
        }
        do {
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw FilesError.manifestDecode("\(error)")
        }
    }

    // MARK: - Load one tile (T4)

    /// Loads one tile's `body.dags` + `meta.json`. Refuses (never loads
    /// silently) a body whose sha256 differs from the manifest
    /// (`RouterError.tileHashMismatch`) or whose `meta.json` epoch disagrees
    /// with the body's own tick count (`RouterError.tileInconsistent`). A
    /// stale `body.dags.tmp` beside the committed body loads the committed
    /// body and reports the leftover via `leftoverTemp`.
    public static func loadTile(
        dataRoot: String, name: String, manifest: Manifest, tileId: UInt32
    ) throws -> LoadedTile {
        guard let entry = manifest.tiles.first(where: { $0.id == tileId }) else {
            throw FilesError.tileEntryMissing(tileId)
        }
        let dir = tileDirectory(dataRoot: dataRoot, name: name, entry: entry)
        let bodyPath = "\(dir)/body.dags"
        let metaPath = "\(dir)/meta.json"

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

        let n = Int(entry.nodeCount)
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
    enum RankHaloError: Error { case badMagic; case truncated }

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
