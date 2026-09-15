import XCTest
@testable import DagDB

/// Audit C, scope α — the tile-file / router / fixture half.
/// `docs/contracts/SUBSYSTEMS_BOUNDS_GATES_FROZEN.md`, findings 1-19 and
/// test items 75, 76, 78, 81, 82.
///
/// Every failing input below is built BY HAND — a hand-written header, a
/// corrupted JSON field, an out-of-range argument — never something the
/// writer under test produced. That is the contract's general letter: a
/// test that reads back what the writer just wrote can only observe the
/// writer's own constant (item 75's complaint).
///
/// Amateur engineering project, no competitive claims, errors likely.
final class SubsystemsBoundsTiledTests: XCTestCase {

    // MARK: - Scratch

    private func scratchDir(_ label: String) -> String {
        let dir = NSTemporaryDirectory() + "dagdb-audit-c-\(label)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeScratch(_ dir: String) { try? FileManager.default.removeItem(atPath: dir) }

    /// A written tiling to corrupt: side 16, `tiles` tiles, in a scratch root.
    private func writeTiling(_ label: String, side: Int = 16, tiles: Int = 4)
        throws -> (dir: String, manifest: TiledGraphFiles.Manifest, report: TiledGraphFiles.WriteReport) {
        let object = try TiledFixture.generate(side: side)
        let dir = scratchDir(label)
        let boundaries = TiledFixture.boundaries(side: side, tiles: tiles)
        let report = try TiledGraphFiles.write(
            object: object, dataRoot: dir, name: "g", boundaries: boundaries)
        let manifest = try TiledGraphFiles.readManifest(dataRoot: dir, name: "g")
        return (dir, manifest, report)
    }

    private func tilePath(_ dir: String, _ entry: TiledGraphFiles.TileEntry, _ file: String) -> String {
        "\(TiledGraphFiles.tileDirectory(dataRoot: dir, name: "g", entry: entry))/\(file)"
    }

    private func rewriteManifest(_ dir: String, _ manifest: TiledGraphFiles.Manifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(
            to: URL(fileURLWithPath: "\(TiledGraphFiles.graphDirectory(dataRoot: dir, name: "g"))/manifest.json"))
    }

    private func readMeta(_ path: String) throws -> TileMeta {
        try JSONDecoder().decode(TileMeta.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func writeMeta(_ path: String, _ meta: TileMeta) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(meta).write(to: URL(fileURLWithPath: path))
    }

    /// A `DAHA` header built by hand, so the version / kind / count fields
    /// are the TEST's, not the writer's.
    private func handBuiltStrip(version: UInt32, kind: UInt32, entries: Int,
                                sourceTile: UInt64 = 0, targetTile: UInt64 = 0,
                                epoch: UInt64 = 0, entryBytes: Int = 16) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        data.append(contentsOf: [0x44, 0x41, 0x48, 0x41])   // "DAHA"
        u32(version)
        u32(kind)
        u32(UInt32(entries))
        u64(sourceTile)
        u64(targetTile)
        u64(epoch)
        for i in 0..<entries {
            u64(UInt64(i))
            data.append(contentsOf: [UInt8](repeating: 0, count: entryBytes - 8))
        }
        return data
    }

    // MARK: - 1 · rank-halo reader refuses a version that is not its own

    func testF1RankHaloVersionRefusedByName() throws {
        let path = scratchDir("f1") + "/halo_upper.bin"
        defer { removeScratch((path as NSString).deletingLastPathComponent) }

        // BEFORE the fix: any version parsed with the v1 layout, silently.
        try handBuiltStrip(version: 2, kind: 1, entries: 3)
            .write(to: URL(fileURLWithPath: path))
        do {
            let halo = try TiledGraphFiles.readRankHalo(path: path)
            XCTFail("expected badVersion(2); got a v\(halo.version) halo with \(halo.entries.count) entries")
        } catch TiledGraphFiles.RankHaloError.badVersion(let v) {
            XCTAssertEqual(v, 2)
        }

        // The reader's own version still opens.
        try handBuiltStrip(version: TiledGraphFiles.rankHaloFormatVersion, kind: 1, entries: 3)
            .write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(try TiledGraphFiles.readRankHalo(path: path).entries.count, 3)
    }

    // MARK: - 2 · manifest decode refuses a version / format that is not its own

    func testF2ManifestFormatAndVersionRefusedByName() throws {
        let t = try writeTiling("f2")
        defer { removeScratch(t.dir) }

        let bumped = TiledGraphFiles.Manifest(
            format: t.manifest.format, version: 2, name: t.manifest.name,
            boundaries: t.manifest.boundaries, globalNodeCount: t.manifest.globalNodeCount,
            tiles: t.manifest.tiles)
        try rewriteManifest(t.dir, bumped)
        do {
            _ = try TiledGraphFiles.readManifest(dataRoot: t.dir, name: "g")
            XCTFail("expected manifestVersionUnsupported")
        } catch TiledGraphFiles.FilesError.manifestVersionUnsupported(let found, let expected) {
            XCTAssertEqual(found, 2)
            XCTAssertEqual(expected, TiledGraphFiles.manifestFormatVersion)
        }

        let renamed = TiledGraphFiles.Manifest(
            format: "dagdb-tiled-manifest-v2", version: 1, name: t.manifest.name,
            boundaries: t.manifest.boundaries, globalNodeCount: t.manifest.globalNodeCount,
            tiles: t.manifest.tiles)
        try rewriteManifest(t.dir, renamed)
        do {
            _ = try TiledGraphFiles.readManifest(dataRoot: t.dir, name: "g")
            XCTFail("expected manifestFormatUnsupported")
        } catch TiledGraphFiles.FilesError.manifestFormatUnsupported(let found, let expected) {
            XCTAssertEqual(found, "dagdb-tiled-manifest-v2")
            XCTAssertEqual(expected, TiledGraphFiles.manifestFormat)
        }
    }

    // MARK: - 3 · lower strip refuses a kind other than 0

    func testF3LowerStripKindRefused() throws {
        let dir = scratchDir("f3")
        defer { removeScratch(dir) }
        let path = dir + "/halo_lower.0.bin"

        try handBuiltStrip(version: TiledGraphFiles.lowerStripFormatVersion, kind: 1, entries: 2)
            .write(to: URL(fileURLWithPath: path))
        do {
            let strip = try TiledGraphFiles.readLowerStripFile(path: path)
            XCTFail("expected badKind(1); got kind \(strip.kind)")
        } catch TiledGraphFiles.RankHaloError.badKind(let k) {
            XCTAssertEqual(k, 1)
        }

        try handBuiltStrip(version: TiledGraphFiles.lowerStripFormatVersion, kind: 0, entries: 2)
            .write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(try TiledGraphFiles.readLowerStripFile(path: path).entries.count, 2)
    }

    // MARK: - 75 / 78 · the strip version test reads a DELIBERATELY overwritten field

    func testItem75StripVersionReadFromAnOverwrittenField() throws {
        let t = try writeTiling("item75")
        defer { removeScratch(t.dir) }
        let entry = t.manifest.tiles[0]
        let path = tilePath(t.dir, entry, "halo_lower.0.bin")

        // The writer's own strip opens at the writer's own version — the
        // only thing the pre-audit test could observe.
        XCTAssertEqual(try TiledGraphFiles.readLowerStripFile(path: path).version,
                       TiledGraphFiles.lowerStripFormatVersion)

        // Now overwrite the version field in place: bytes 4..7.
        var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        var bogus = UInt32(3).littleEndian
        withUnsafeBytes(of: &bogus) { raw in
            for i in 0..<4 { bytes[bytes.startIndex + 4 + i] = raw[i] }
        }
        try bytes.write(to: URL(fileURLWithPath: path))

        do {
            _ = try TiledGraphFiles.readLowerStripFile(path: path)
            XCTFail("expected badVersion(3) from a strip whose version field was overwritten")
        } catch TiledGraphFiles.RankHaloError.badVersion(let v) {
            XCTAssertEqual(v, 3)
        }
    }

    // MARK: - 4 · a manifest claiming more nodes than the graph holds is refused
    //            BEFORE any engine is allocated

    func testF4ManifestNodeCountRefusedBeforeAllocation() throws {
        let t = try writeTiling("f4")
        defer { removeScratch(t.dir) }
        let victim = t.manifest.tiles[0]

        // 2^40 nodes claimed for a tile of a few — the pre-audit code ran
        // `Int(entry.nodeCount)` and then sized a HexGrid + engine of that
        // width before a single file byte was read.
        let huge: UInt64 = 1 << 40
        let tiles = t.manifest.tiles.map { e -> TiledGraphFiles.TileEntry in
            guard e.id == victim.id else { return e }
            return TiledGraphFiles.TileEntry(
                id: e.id, rankLo: e.rankLo, rankHi: e.rankHi, nodeCount: huge,
                bodySHA256: e.bodySHA256, crossingsOut: e.crossingsOut, crossingsIn: e.crossingsIn,
                engineIndexOf: e.engineIndexOf, tickEpoch: e.tickEpoch)
        }
        let corrupted = TiledGraphFiles.Manifest(
            format: t.manifest.format, version: t.manifest.version, name: t.manifest.name,
            boundaries: t.manifest.boundaries, globalNodeCount: t.manifest.globalNodeCount,
            tiles: tiles)

        let started = Date()
        do {
            _ = try TiledGraphFiles.loadTile(
                dataRoot: t.dir, name: "g", manifest: corrupted, tileId: victim.id)
            XCTFail("expected tileNodeCountInconsistent")
        } catch RouterError.tileNodeCountInconsistent(let id, let m, _, let body, let detail) {
            XCTAssertEqual(id, victim.id)
            XCTAssertEqual(m, huge)
            XCTAssertNil(body, "the body must not even be read before this refusal")
            XCTAssertTrue(detail.contains("whole graph"), detail)
        }
        // The refusal precedes the allocation, so it is immediate.
        XCTAssertLessThan(Date().timeIntervalSince(started), 5.0)
    }

    // MARK: - 5 / 81 · meta.json's node count one larger than the manifest's

    func testF5MetaNodeCountDisagreementRefused() throws {
        let t = try writeTiling("f5")
        defer { removeScratch(t.dir) }
        let entry = t.manifest.tiles[0]
        let metaPath = tilePath(t.dir, entry, "meta.json")

        let meta = try readMeta(metaPath)
        let bumped = TileMeta(
            id: meta.id, rankLo: meta.rankLo, rankHi: meta.rankHi,
            nodeCount: meta.nodeCount + 1,
            lastPersistedTickEpoch: meta.lastPersistedTickEpoch,
            crossingsOut: meta.crossingsOut, crossingsIn: meta.crossingsIn)
        try writeMeta(metaPath, bumped)

        do {
            _ = try TiledGraphFiles.loadTile(
                dataRoot: t.dir, name: "g", manifest: t.manifest, tileId: entry.id)
            XCTFail("expected tileNodeCountInconsistent")
        } catch RouterError.tileNodeCountInconsistent(let id, let m, let mt, _, let detail) {
            XCTAssertEqual(id, entry.id)
            XCTAssertEqual(m, entry.nodeCount)
            XCTAssertEqual(mt, entry.nodeCount + 1)
            XCTAssertTrue(detail.contains("meta.json"), detail)
        }
    }

    // MARK: - 6 · a crossing naming a local at the tile's own node count

    func testF6CrossingLocalAtNodeCountRefused() throws {
        let t = try writeTiling("f6")
        defer { removeScratch(t.dir) }
        let entry = t.manifest.tiles[1]
        let n = Int(entry.nodeCount)
        XCTAssertGreaterThan(n, 0)

        // A hand-built crossingsIn entry naming local == nodeCount: one
        // past the end of the tile's own truth/type buffers.
        let remote = try GlobalNodeID(tileId: 0, localNodeId: 0)
        let tiles = t.manifest.tiles.map { e -> TiledGraphFiles.TileEntry in
            guard e.id == entry.id else { return e }
            return TiledGraphFiles.TileEntry(
                id: e.id, rankLo: e.rankLo, rankHi: e.rankHi, nodeCount: e.nodeCount,
                bodySHA256: e.bodySHA256, crossingsOut: e.crossingsOut,
                crossingsIn: [Crossing(localNode: UInt64(n), remoteNode: remote)],
                engineIndexOf: e.engineIndexOf, tickEpoch: e.tickEpoch)
        }
        let corrupted = TiledGraphFiles.Manifest(
            format: t.manifest.format, version: t.manifest.version, name: t.manifest.name,
            boundaries: t.manifest.boundaries, globalNodeCount: t.manifest.globalNodeCount,
            tiles: tiles)

        let loaded = try TiledGraphFiles.loadTile(
            dataRoot: t.dir, name: "g", manifest: t.manifest, tileId: entry.id)
        do {
            _ = try TiledGraphFiles.writeLowerStrip(
                dataRoot: t.dir, name: "g", manifest: corrupted, tileId: entry.id,
                engine: loaded.engine, realNodeCount: n, epoch: 0)
            XCTFail("expected crossingLocalOutOfRange")
        } catch TiledGraphFiles.FilesError.crossingLocalOutOfRange(let tile, let local, let count) {
            XCTAssertEqual(tile, entry.id)
            XCTAssertEqual(local, UInt64(n))
            XCTAssertEqual(count, n)
        }
    }

    // MARK: - 7 / 81 · the body's `-2` slots and meta's crossings must agree

    func testF7SlotCountVersusCrossingsRefused() throws {
        let t = try writeTiling("f7")
        defer { removeScratch(t.dir) }

        // Find a tile whose meta lists at least one crossing.
        guard let entry = t.manifest.tiles.first(where: { !$0.crossingsOut.isEmpty }) else {
            return XCTFail("no tile with crossingsOut in the side-16 4-tile fixture")
        }
        let metaPath = tilePath(t.dir, entry, "meta.json")
        let meta = try readMeta(metaPath)
        guard let victimLocal = meta.crossingsOut.first?.localNode else {
            return XCTFail("meta.json has no crossingsOut for tile \(entry.id)")
        }
        let before = meta.crossingsOut.filter { $0.localNode == victimLocal }.count

        // FEWER crossings than `-2` slots: drop one for that local. The
        // pre-audit loader wired the surplus slot to nothing and left the
        // sentinel in place, silently.
        var fewer = meta.crossingsOut
        if let idx = fewer.firstIndex(where: { $0.localNode == victimLocal }) { fewer.remove(at: idx) }
        try writeMeta(metaPath, TileMeta(
            id: meta.id, rankLo: meta.rankLo, rankHi: meta.rankHi, nodeCount: meta.nodeCount,
            lastPersistedTickEpoch: meta.lastPersistedTickEpoch,
            crossingsOut: fewer, crossingsIn: meta.crossingsIn))
        do {
            _ = try TiledGraphFiles.loadTileWithGhosts(
                dataRoot: t.dir, name: "g", manifest: t.manifest, tileId: entry.id)
            XCTFail("expected crossingSlotCountMismatch (fewer crossings than slots)")
        } catch TiledGraphFiles.FilesError.crossingSlotCountMismatch(let tile, let local, let slots, let crossings) {
            XCTAssertEqual(tile, entry.id)
            XCTAssertEqual(local, victimLocal)
            XCTAssertEqual(slots, before)
            XCTAssertEqual(crossings, before - 1)
        }

        // MORE crossings than `-2` slots: the pre-audit loader TRAPPED here
        // (`list[cursor]` out of range).
        var more = meta.crossingsOut
        if let sample = more.first(where: { $0.localNode == victimLocal }) { more.append(sample) }
        try writeMeta(metaPath, TileMeta(
            id: meta.id, rankLo: meta.rankLo, rankHi: meta.rankHi, nodeCount: meta.nodeCount,
            lastPersistedTickEpoch: meta.lastPersistedTickEpoch,
            crossingsOut: more, crossingsIn: meta.crossingsIn))
        do {
            _ = try TiledGraphFiles.loadTileWithGhosts(
                dataRoot: t.dir, name: "g", manifest: t.manifest, tileId: entry.id)
            XCTFail("expected crossingSlotCountMismatch (more crossings than slots)")
        } catch TiledGraphFiles.FilesError.crossingSlotCountMismatch(let tile, let local, let slots, let crossings) {
            XCTAssertEqual(tile, entry.id)
            XCTAssertEqual(local, victimLocal)
            XCTAssertEqual(slots, before)
            XCTAssertEqual(crossings, before + 1)
        }
    }

    // MARK: - 8 · a crossing naming a foreign local past the source tile's node count

    func testF8ForeignLocalBeyondSourceTileRefused() async throws {
        let t = try writeTiling("f8", side: 16, tiles: 2)
        defer { removeScratch(t.dir) }

        guard let lower = t.manifest.tiles.first(where: { !$0.crossingsOut.isEmpty }) else {
            return XCTFail("no tile with crossingsOut")
        }
        let metaPath = tilePath(t.dir, lower, "meta.json")
        let meta = try readMeta(metaPath)
        guard let sample = meta.crossingsOut.first else { return XCTFail("no crossing") }
        let sourceTileId = sample.remoteNode.tileId
        guard let source = t.manifest.tiles.first(where: { $0.id == sourceTileId }) else {
            return XCTFail("crossing names tile \(sourceTileId), absent from the manifest")
        }

        // Repoint every crossing of that one local at a local id the SOURCE
        // tile does not have. The slot count is untouched, so this is
        // exactly the out-of-range read finding 8 describes.
        let beyond = source.nodeCount + 7
        let rewritten = try meta.crossingsOut.map { c -> Crossing in
            guard c.localNode == sample.localNode else { return c }
            return Crossing(localNode: c.localNode,
                            remoteNode: try GlobalNodeID(tileId: sourceTileId, localNodeId: beyond),
                            foreignRank: c.foreignRank)
        }
        try writeMeta(metaPath, TileMeta(
            id: meta.id, rankLo: meta.rankLo, rankHi: meta.rankHi, nodeCount: meta.nodeCount,
            lastPersistedTickEpoch: meta.lastPersistedTickEpoch,
            crossingsOut: rewritten, crossingsIn: meta.crossingsIn))

        let router = try await TiledGraphRouter(
            dataRoot: t.dir, graphName: "g", maxResidentTiles: 2, role: .writer)
        do {
            _ = try await router.worldTick(mode: .rank, count: 1)
            XCTFail("expected crossTileBoundsExceeded from the resident-source ghost path")
        } catch RouterError.crossTileBoundsExceeded(let id) {
            XCTAssertEqual(id, sourceTileId)
        }
    }

    // MARK: - 9 / 82 · an epoch that does not fit the body header's 32-bit tick field

    func testF9EpochAboveUInt32RefusedAtFlush() async throws {
        let t = try writeTiling("f9", side: 16, tiles: 2)
        defer { removeScratch(t.dir) }

        // Start every tile at UInt32.max: the body header's tick field,
        // meta.json's epoch and the manifest entry's epoch all pinned by
        // hand, so the very next world tick would need 2^32.
        let ceiling = UInt64(UInt32.max)
        var entries: [TiledGraphFiles.TileEntry] = []
        for e in t.manifest.tiles {
            let bodyPath = tilePath(t.dir, e, "body.dags")
            var body = try Data(contentsOf: URL(fileURLWithPath: bodyPath))
            for i in 0..<4 { body[body.startIndex + 20 + i] = 0xFF }   // tickCount = 0xFFFFFFFF
            try body.write(to: URL(fileURLWithPath: bodyPath))
            let sha = DagDBSnapshot.sha256Hex(body)
            try Data(sha.utf8).write(to: URL(fileURLWithPath: bodyPath + ".sha256"))

            let metaPath = tilePath(t.dir, e, "meta.json")
            let meta = try readMeta(metaPath)
            try writeMeta(metaPath, TileMeta(
                id: meta.id, rankLo: meta.rankLo, rankHi: meta.rankHi, nodeCount: meta.nodeCount,
                lastPersistedTickEpoch: ceiling,
                crossingsOut: meta.crossingsOut, crossingsIn: meta.crossingsIn))

            entries.append(TiledGraphFiles.TileEntry(
                id: e.id, rankLo: e.rankLo, rankHi: e.rankHi, nodeCount: e.nodeCount,
                bodySHA256: sha, crossingsOut: e.crossingsOut, crossingsIn: e.crossingsIn,
                engineIndexOf: e.engineIndexOf, tickEpoch: ceiling))
        }
        try rewriteManifest(t.dir, TiledGraphFiles.Manifest(
            format: t.manifest.format, version: t.manifest.version, name: t.manifest.name,
            boundaries: t.manifest.boundaries, globalNodeCount: t.manifest.globalNodeCount,
            tiles: entries))

        let router = try await TiledGraphRouter(
            dataRoot: t.dir, graphName: "g", maxResidentTiles: 2, role: .writer)
        let openStatus = await router.status()
        XCTAssertEqual(openStatus.epochMax, ceiling)
        do {
            _ = try await router.worldTick(mode: .rank, count: 1)
            XCTFail("expected tileEpochUnrepresentable — the next epoch is 2^32")
        } catch RouterError.tileEpochUnrepresentable(_, let epoch, let limit) {
            XCTAssertEqual(epoch, ceiling + 1)
            XCTAssertEqual(limit, ceiling)
        }
    }

    // MARK: - 10 · a hand-written BEGIN at epoch 0

    func testF10FlushWALBeginAtEpochZeroRefused() async throws {
        let t = try writeTiling("f10")
        defer { removeScratch(t.dir) }
        let entry = t.manifest.tiles[0]
        let dir = TiledGraphFiles.tileDirectory(dataRoot: t.dir, name: "g", entry: entry)

        try Data("TILE_FLUSH_BEGIN \(entry.id) 0 rank\n".utf8)
            .write(to: URL(fileURLWithPath: "\(dir)/flush.wal"))

        // Classified torn, not pending — so `beginEpoch - 1` is never taken.
        guard case .torn(let detail) = TiledGraphFiles.flushState(dir: dir) else {
            return XCTFail("a BEGIN at epoch 0 must be torn, not pending or clean")
        }
        XCTAssertTrue(detail.contains("epoch 0"), detail)

        do {
            _ = try await TiledGraphRouter(dataRoot: t.dir, graphName: "g", role: .writer)
            XCTFail("expected tileFlushMalformed")
        } catch RouterError.tileFlushMalformed(let id, let d) {
            XCTAssertEqual(id, entry.id)
            XCTAssertTrue(d.contains("epoch 0"), d)
        }
    }

    // MARK: - 11 · a torn flush.wal is never "clean"

    func testF11TornFlushWALRefused() throws {
        let t = try writeTiling("f11")
        defer { removeScratch(t.dir) }
        let entry = t.manifest.tiles[0]
        let dir = TiledGraphFiles.tileDirectory(dataRoot: t.dir, name: "g", entry: entry)
        let walPath = "\(dir)/flush.wal"

        // (a) a final record cut off mid-write (no trailing newline).
        try Data("TILE_FLUSH_BEGIN \(entry.id) 4 rank\nTILE_FLUSH_COMMIT \(entry.id) 4\nTILE_FLUSH_BEG".utf8)
            .write(to: URL(fileURLWithPath: walPath))
        guard case .torn = TiledGraphFiles.flushState(dir: dir) else {
            return XCTFail("a truncated final record must be torn, not clean")
        }
        do {
            _ = try TiledGraphFiles.loadTile(
                dataRoot: t.dir, name: "g", manifest: t.manifest, tileId: entry.id)
            XCTFail("expected tileFlushMalformed, not a clean load")
        } catch RouterError.tileFlushMalformed(let id, _) {
            XCTAssertEqual(id, entry.id)
        }

        // (b) a three-field BEGIN, the shape that predates the mode field.
        try Data("TILE_FLUSH_BEGIN \(entry.id) 4\n".utf8).write(to: URL(fileURLWithPath: walPath))
        guard case .torn(let detail) = TiledGraphFiles.flushState(dir: dir) else {
            return XCTFail("a three-field BEGIN must be torn, not clean")
        }
        XCTAssertTrue(detail.contains("3 field"), detail)

        // (c) a well-formed COMMIT is still clean, and a well-formed BEGIN
        //     is still PENDING — the classification did not become a blanket
        //     refusal.
        try Data("TILE_FLUSH_COMMIT \(entry.id) 4\n".utf8).write(to: URL(fileURLWithPath: walPath))
        XCTAssertEqual(TiledGraphFiles.flushState(dir: dir), .clean)
        try Data("TILE_FLUSH_BEGIN \(entry.id) 5 sync\n".utf8).write(to: URL(fileURLWithPath: walPath))
        XCTAssertEqual(TiledGraphFiles.flushState(dir: dir), .pending(epoch: 5, mode: .sync))
    }

    // MARK: - 12 · engineIndexOf validated at router init

    func testF12EngineIndexOfValidatedAtInit() async throws {
        let t = try writeTiling("f12")
        defer { removeScratch(t.dir) }
        let victim = t.manifest.tiles[0]

        func withEngineIndex(_ replacement: [UInt64]) -> TiledGraphFiles.Manifest {
            let tiles = t.manifest.tiles.map { e -> TiledGraphFiles.TileEntry in
                guard e.id == victim.id else { return e }
                return TiledGraphFiles.TileEntry(
                    id: e.id, rankLo: e.rankLo, rankHi: e.rankHi, nodeCount: e.nodeCount,
                    bodySHA256: e.bodySHA256, crossingsOut: e.crossingsOut, crossingsIn: e.crossingsIn,
                    engineIndexOf: replacement, tickEpoch: e.tickEpoch)
            }
            return TiledGraphFiles.Manifest(
                format: t.manifest.format, version: t.manifest.version, name: t.manifest.name,
                boundaries: t.manifest.boundaries, globalNodeCount: t.manifest.globalNodeCount,
                tiles: tiles)
        }

        // (a) the memberwise default — an EMPTY array, which made
        //     `engineIndexOf[li]` trap at local 0.
        try rewriteManifest(t.dir, withEngineIndex([]))
        do {
            _ = try await TiledGraphRouter(dataRoot: t.dir, graphName: "g", role: .writer)
            XCTFail("expected engineIndexInvalid for an empty engineIndexOf")
        } catch RouterError.engineIndexInvalid(let id, let detail) {
            XCTAssertEqual(id, victim.id)
            XCTAssertTrue(detail.contains("0 entr"), detail)
        }

        // (b) the right length, one index past the graph's own node count.
        var outOfRange = victim.engineIndexOf
        outOfRange[0] = t.manifest.globalNodeCount
        try rewriteManifest(t.dir, withEngineIndex(outOfRange))
        do {
            _ = try await TiledGraphRouter(dataRoot: t.dir, graphName: "g", role: .writer)
            XCTFail("expected engineIndexInvalid for an out-of-range engineIndexOf")
        } catch RouterError.engineIndexInvalid(let id, let detail) {
            XCTAssertEqual(id, victim.id)
            XCTAssertTrue(detail.contains("globalNodeCount"), detail)
        }
    }

    // MARK: - 13 · crossings that skip a tile are counted, not lost

    func testF13TileSkippingCrossingsCounted() throws {
        var sawSkipping = false
        for tiles in [2, 3, 4, 6, 8] {
            let t = try writeTiling("f13-\(tiles)", side: 16, tiles: tiles)
            defer { removeScratch(t.dir) }
            let adjacentUp = t.report.perBoundary.reduce(0) { $0 + $1.up }
            // S5 (iii): the identity `adjacent + skipping == crossings` was
            // asserted against the writer's own subtraction
            // (`skipping = crossings − adjacentUp`), so it could not fail.
            // Both counts are now walked out of the manifest's crossings
            // lists here: every crossing this tiling wrote, classified by
            // whether its remote node sits on the very next tile or further
            // up, and compared to the three numbers the report states.
            var derivedTotal = 0
            var derivedAdjacent = 0
            var derivedSkipping = 0
            for entry in t.manifest.tiles {
                for c in entry.crossingsOut {
                    derivedTotal += 1
                    if c.remoteNode.tileId == entry.id + 1 { derivedAdjacent += 1 }
                    else { derivedSkipping += 1 }
                }
            }
            XCTAssertEqual(derivedTotal, t.report.crossings, "tiles=\(tiles)")
            XCTAssertEqual(derivedAdjacent, adjacentUp, "tiles=\(tiles)")
            XCTAssertEqual(derivedSkipping, t.report.crossingsSkippingATile, "tiles=\(tiles)")
            if t.report.crossingsSkippingATile > 0 {
                sawSkipping = true
                // The finding's own observable: perBoundary undercounts.
                XCTAssertLessThan(adjacentUp, t.report.crossings, "tiles=\(tiles)")
                print("F13 tiles=\(tiles): crossings=\(t.report.crossings) "
                      + "adjacent=\(adjacentUp) skipping=\(t.report.crossingsSkippingATile)")
            }
        }
        XCTAssertTrue(sawSkipping,
                      "no tiling of side 16 produced a crossing that skips a tile — the "
                      + "undercount finding 13 describes would be unreachable")
    }

    // MARK: - 14 · the halo's source_tile_id is the MODAL foreign tile

    func testF14HaloSourceTileIsModal() throws {
        var checkedMultiForeign = 0
        for tiles in [2, 3, 4, 6, 8] {
            let t = try writeTiling("f14-\(tiles)", side: 16, tiles: tiles)
            defer { removeScratch(t.dir) }
            for entry in t.manifest.tiles where !entry.crossingsOut.isEmpty {
                var counts: [UInt32: Int] = [:]
                for c in entry.crossingsOut { counts[c.remoteNode.tileId, default: 0] += 1 }
                guard counts.count > 1 else { continue }
                checkedMultiForeign += 1
                let modal = counts.sorted { a, b in
                    a.value != b.value ? a.value > b.value : a.key < b.key
                }[0].key
                let halo = try TiledGraphFiles.readRankHalo(
                    path: tilePath(t.dir, entry, "halo_upper.bin"))
                XCTAssertEqual(halo.sourceTileId, UInt64(modal),
                               "tiles=\(tiles) tile=\(entry.id) foreign counts \(counts)")
            }
        }
        XCTAssertGreaterThan(checkedMultiForeign, 0,
                             "no tile referenced more than one foreign tile — finding 14's "
                             + "divergence would be unreachable")
    }

    // MARK: - 15 · a residency budget below 1

    func testF15MaxResidentTilesBelowOneRefused() async throws {
        let t = try writeTiling("f15")
        defer { removeScratch(t.dir) }
        for k in [0, -1] {
            do {
                _ = try await TiledGraphRouter(dataRoot: t.dir, graphName: "g", maxResidentTiles: k)
                XCTFail("expected residencyBudgetInvalid for K=\(k)")
            } catch RouterError.residencyBudgetInvalid(let got) {
                XCTAssertEqual(got, k)
            }
        }
        // K = 1 still opens.
        _ = try await TiledGraphRouter(dataRoot: t.dir, graphName: "g", maxResidentTiles: 1)
    }

    // MARK: - 16 · status() sees the ticking path

    func testF16StatusCountsTheTickingPath() async throws {
        let t = try writeTiling("f16", side: 16, tiles: 4)
        defer { removeScratch(t.dir) }
        let router = try await TiledGraphRouter(
            dataRoot: t.dir, graphName: "g", maxResidentTiles: 1, role: .writer)

        let before = await router.status()
        XCTAssertEqual(before.maxResidentSeen, 0)
        _ = try await router.worldTick(mode: .rank, count: 1)
        let s = await router.status()
        print("F16 after one world tick at K=1: resident=\(s.residentTileCount) "
              + "loads=\(s.loads) evicts=\(s.evicts) maxResidentSeen=\(s.maxResidentSeen)")
        XCTAssertGreaterThanOrEqual(s.maxResidentSeen, 1)
        XCTAssertLessThanOrEqual(s.maxResidentSeen, s.maxResidentTiles)
        XCTAssertGreaterThanOrEqual(s.residentTileCount, 1)
        XCTAssertGreaterThanOrEqual(s.loads, 4)
    }

    // MARK: - 17 · a negative world-tick count

    func testF17WorldTickNegativeCountRefused() async throws {
        let t = try writeTiling("f17")
        defer { removeScratch(t.dir) }
        let router = try await TiledGraphRouter(dataRoot: t.dir, graphName: "g", role: .writer)
        do {
            _ = try await router.worldTick(mode: .rank, count: -1)
            XCTFail("expected tickCountNegative")
        } catch RouterError.tickCountNegative(let c) {
            XCTAssertEqual(c, -1)
        }
    }

    // MARK: - 18 · populate against a mismatched engine

    func testF18PopulateSizeMismatchThrows() throws {
        // An engine sized for side 16, a grid sized for side 20: the
        // pre-audit `populate` bound every Metal buffer at the GRID's size
        // and wrote past the engine's.
        let smallGrid = try HexGrid(width: 16, height: 16)
        let engine = try DagDBEngine(
            grid: smallGrid, state: DagDBState(width: 16, height: 16), maxRank: 64)
        let bigGrid = try HexGrid(width: 20, height: 20)
        do {
            try TiledFixture.populate(engine: engine, grid: bigGrid, side: 20)
            XCTFail("expected sizeMismatch")
        } catch TiledFixture.FixtureError.sizeMismatch(let g, let e, let side) {
            XCTAssertEqual(g, 400)
            XCTAssertEqual(e, 256)
            XCTAssertEqual(side, 20)
        }
        // The matched pairing still populates.
        try TiledFixture.populate(engine: engine, grid: smallGrid, side: 16)
    }

    // MARK: - 19 · seeds over an object whose centre it cannot address

    func testF19SeedsRefusesAnObjectItCannotAddress() throws {
        let real = try TiledFixture.generate(side: 16)
        // A hand-built Object whose `side` does not match its grid — the
        // centre row-major index (22·44 + 22 = 990) is past the 256-entry
        // Morton table, the same unchecked-argument shape as the `% 0` the
        // finding names (a genuinely zero-node engine cannot be built:
        // `DagDBEngine.init` refuses a zero-length Metal buffer).
        let mismatched = TiledFixture.Object(
            side: 44, engine: real.engine, grid: real.grid, maxRank: real.maxRank)
        XCTAssertEqual(TiledFixture.seeds(for: mismatched), [],
                       "an object whose centre index is outside its own Morton table must be "
                       + "refused, not indexed")
        // The real object still yields its five seeds.
        XCTAssertEqual(TiledFixture.seeds(for: real).count, 5)
    }

    // MARK: - 76 · the depth cap, driven past its edge

    func testItem76DepthCapRefused() async throws {
        let t = try writeTiling("item76")
        defer { removeScratch(t.dir) }
        let router = try await TiledGraphRouter(dataRoot: t.dir, graphName: "g", role: .writer)
        let seed = try GlobalNodeID(tileId: 0, localNodeId: 0)

        // 12 is the cap; every pre-audit BFS test stopped exactly AT it.
        _ = try await router.runBFS(seed: seed, depth: 12)
        do {
            _ = try await router.runBFS(seed: seed, depth: 13)
            XCTFail("expected depthCapExceeded at depth 13")
        } catch RouterError.depthCapExceeded(let d) {
            XCTAssertEqual(d, 13)
        }
    }
}
