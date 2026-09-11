import XCTest
@testable import DagDB

/// T1 (tile files), T4 (torn/inconsistent tiles), T6 (printed sizes/times) —
/// `docs/contracts/TILING_GATES_FROZEN.md`. Style follows
/// `TiledGraphRouterTests.swift`.
final class TiledGraphFilesTests: XCTestCase {

    // MARK: - Scratch dirs (NSTemporaryDirectory, never the repo)

    private func scratchDir(_ label: String) -> String {
        let dir = NSTemporaryDirectory() + "dagdb-tiling-\(label)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeScratch(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - Generator determinism

    func testGeneratorIsDeterministic() throws {
        let a = try TiledFixture.generate(side: 16)
        let b = try TiledFixture.generate(side: 16)
        let n = a.nodeCount
        XCTAssertEqual(n, b.nodeCount)

        let ra = a.engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let rb = b.engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let ta = a.engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let tb = b.engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let na = a.engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        let nb = b.engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)

        var rankMismatch = 0, truthMismatch = 0, nbMismatch = 0
        for i in 0..<n {
            if ra[i] != rb[i] { rankMismatch += 1 }
            if ta[i] != tb[i] { truthMismatch += 1 }
        }
        for i in 0..<(n * 6) where na[i] != nb[i] { nbMismatch += 1 }
        XCTAssertEqual(rankMismatch, 0)
        XCTAssertEqual(truthMismatch, 0)
        XCTAssertEqual(nbMismatch, 0)

        // AMENDMENT 1, item 1: a node's slots hold HIGHER-rank sources (the
        // engine's own inputs convention, `rank(src) > rank(dst)`) — a
        // violation is a target whose rank is <= the node's own rank.
        var edgeCount = 0
        var crossRankEdge = 0
        for i in 0..<n {
            for d in 0..<6 {
                let target = na[i * 6 + d]
                if target >= 0 {
                    edgeCount += 1
                    if ra[Int(target)] <= ra[i] { crossRankEdge += 1 }
                }
            }
        }
        print("testGeneratorIsDeterministic: side=16 nodes=\(n) edges=\(edgeCount) rank-violations=\(crossRankEdge)")
        XCTAssertEqual(crossRankEdge, 0, "every written edge must target a strictly higher rank (rank(src) > rank(dst))")
        XCTAssertEqual(a.maxRank, b.maxRank)
        XCTAssertEqual(a.maxRank, 8)
    }

    // MARK: - Boundaries and seeds

    func testBoundariesAndSeeds() throws {
        for side in TiledFixture.sides {
            let object = try TiledFixture.generate(side: side)
            for tiles in [2, 4, 8] {
                let b = TiledFixture.boundaries(side: side, tiles: tiles)
                print("side=\(side) tiles=\(tiles) boundaries=\(b) maxRank=\(object.maxRank)")
                XCTAssertEqual(b.count, tiles - 1)
                XCTAssertEqual(b, b.sorted())
                if let last = b.last { XCTAssertLessThanOrEqual(last, object.maxRank) }
            }
            let seeds = TiledFixture.seeds(for: object)
            print("side=\(side) seeds=\(seeds)")
            XCTAssertEqual(seeds.count, 5)
            for s in seeds {
                XCTAssertGreaterThanOrEqual(s, 0)
                XCTAssertLessThan(s, object.nodeCount)
            }
        }
    }

    // MARK: - T1: write / reload bit-for-bit

    func testT1WriteReloadBitForBit() throws {
        for side in [16, 44, 128] {
            let object = try TiledFixture.generate(side: side)
            let n = object.nodeCount
            let rankPtr = object.engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
            let truthPtr = object.engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
            let typePtr = object.engine.nodeTypeBuf.contents().bindMemory(to: UInt8.self, capacity: n)
            let lutLowPtr = object.engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
            let lutHighPtr = object.engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
            let nbPtr = object.engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)

            for tiles in [2, 4, 8] {
                let dir = scratchDir("t1-\(side)-\(tiles)")
                defer { removeScratch(dir) }
                let boundaries = TiledFixture.boundaries(side: side, tiles: tiles)
                let report = try TiledGraphFiles.write(
                    object: object, dataRoot: dir, name: "g", boundaries: boundaries
                )
                XCTAssertEqual(report.tiles, tiles)
                XCTAssertEqual(report.nodes, n)

                let manifest = try TiledGraphFiles.readManifest(dataRoot: dir, name: "g")
                XCTAssertEqual(manifest.tiles.count, tiles)
                let totalNodes = manifest.tiles.reduce(0) { $0 + Int($1.nodeCount) }
                XCTAssertEqual(totalNodes, n)

                for entry in manifest.tiles {
                    let bodyPath = "\(TiledGraphFiles.tileDirectory(dataRoot: dir, name: "g", entry: entry))/body.dags"
                    let bodyData = try Data(contentsOf: URL(fileURLWithPath: bodyPath))
                    XCTAssertEqual(DagDBSnapshot.sha256Hex(bodyData), entry.bodySHA256)

                    let loaded = try TiledGraphFiles.loadTile(
                        dataRoot: dir, name: "g", manifest: manifest, tileId: entry.id
                    )
                    let ln = Int(entry.nodeCount)
                    let lr = loaded.engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: ln)
                    let lt = loaded.engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: ln)
                    let lty = loaded.engine.nodeTypeBuf.contents().bindMemory(to: UInt8.self, capacity: ln)
                    let llow = loaded.engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: ln)
                    let lhigh = loaded.engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: ln)
                    let lnb = loaded.engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: ln * 6)

                    // Reconstruct expected tile-local buffers from the original
                    // object's own buffers via report.globalOf (engine index ->
                    // GlobalNodeID.raw), independent of TiledGraphFiles' internals.
                    var expectedRank = [UInt64](repeating: 0, count: ln)
                    var expectedTruth = [UInt8](repeating: 0, count: ln)
                    var expectedType = [UInt8](repeating: 0, count: ln)
                    var expectedLow = [UInt32](repeating: 0, count: ln)
                    var expectedHigh = [UInt32](repeating: 0, count: ln)
                    var expectedNb = [Int32](repeating: -1, count: ln * 6)

                    for m in 0..<n {
                        let gid = GlobalNodeID(raw: report.globalOf[m])
                        guard gid.tileId == entry.id else { continue }
                        let li = Int(gid.localNodeId)
                        expectedRank[li] = rankPtr[m]
                        expectedTruth[li] = truthPtr[m]
                        expectedType[li] = typePtr[m]
                        expectedLow[li] = lutLowPtr[m]
                        expectedHigh[li] = lutHighPtr[m]
                        for d in 0..<6 {
                            let target = nbPtr[m * 6 + d]
                            if target < 0 { continue }
                            let tgid = GlobalNodeID(raw: report.globalOf[Int(target)])
                            expectedNb[li * 6 + d] = tgid.tileId == entry.id ? Int32(tgid.localNodeId) : -2
                        }
                    }

                    XCTAssertEqual(Array(UnsafeBufferPointer(start: lr, count: ln)), expectedRank, "tile \(entry.id) rank")
                    XCTAssertEqual(Array(UnsafeBufferPointer(start: lt, count: ln)), expectedTruth, "tile \(entry.id) truth")
                    XCTAssertEqual(Array(UnsafeBufferPointer(start: lty, count: ln)), expectedType, "tile \(entry.id) type")
                    XCTAssertEqual(Array(UnsafeBufferPointer(start: llow, count: ln)), expectedLow, "tile \(entry.id) lut low")
                    XCTAssertEqual(Array(UnsafeBufferPointer(start: lhigh, count: ln)), expectedHigh, "tile \(entry.id) lut high")
                    XCTAssertEqual(Array(UnsafeBufferPointer(start: lnb, count: ln * 6)), expectedNb, "tile \(entry.id) neighbors")
                }
            }
        }
    }

    // MARK: - T1 ruling: every boundary has crossings both ways (T6 printed)

    func testEveryBoundaryHasCrossingsBothWays() throws {
        for side in TiledFixture.sides {
            let object = try TiledFixture.generate(side: side)
            for tiles in [2, 4, 8] {
                let dir = scratchDir("boundaries-\(side)-\(tiles)")
                defer { removeScratch(dir) }
                let boundaries = TiledFixture.boundaries(side: side, tiles: tiles)
                let report = try TiledGraphFiles.write(
                    object: object, dataRoot: dir, name: "g", boundaries: boundaries
                )
                print("side=\(side) tiles=\(tiles) crossings=\(report.crossings) perBoundary=\(report.perBoundary.map { "(\($0.lower)-\($0.upper): down=\($0.down) up=\($0.up))" })")
                for bc in report.perBoundary {
                    XCTAssertGreaterThanOrEqual(bc.down, 1, "boundary \(bc.lower)-\(bc.upper) down")
                    XCTAssertGreaterThanOrEqual(bc.up, 1, "boundary \(bc.lower)-\(bc.upper) up")
                    XCTAssertEqual(bc.down, bc.up, "boundary \(bc.lower)-\(bc.upper) mirror counts")
                }
            }
        }
        // Contract-required print: side 44 x 4 tiles.
        let object44 = try TiledFixture.generate(side: 44)
        let dir = scratchDir("boundaries-44-4-report")
        defer { removeScratch(dir) }
        let boundaries44 = TiledFixture.boundaries(side: 44, tiles: 4)
        let report44 = try TiledGraphFiles.write(object: object44, dataRoot: dir, name: "g", boundaries: boundaries44)
        print("REPORT side=44 tiles=4 boundaries=\(boundaries44) crossings=\(report44.crossings)")
        for bc in report44.perBoundary {
            print("  boundary \(bc.lower)-\(bc.upper): down=\(bc.down) up=\(bc.up)")
        }
    }

    // MARK: - T4: torn body refused

    func testTornBodyRefused() throws {
        let object = try TiledFixture.generate(side: 16)
        let dir = scratchDir("torn")
        defer { removeScratch(dir) }
        let boundaries = TiledFixture.boundaries(side: 16, tiles: 4)
        _ = try TiledGraphFiles.write(object: object, dataRoot: dir, name: "g", boundaries: boundaries)
        let manifest = try TiledGraphFiles.readManifest(dataRoot: dir, name: "g")
        let entry = manifest.tiles[0]
        let bodyPath = "\(TiledGraphFiles.tileDirectory(dataRoot: dir, name: "g", entry: entry))/body.dags"

        var bytes = try Data(contentsOf: URL(fileURLWithPath: bodyPath))
        XCTAssertGreaterThan(bytes.count, 40)
        bytes[40] = bytes[40] ^ 0xFF  // flip one byte inside the body
        try bytes.write(to: URL(fileURLWithPath: bodyPath))

        do {
            _ = try TiledGraphFiles.loadTile(dataRoot: dir, name: "g", manifest: manifest, tileId: entry.id)
            XCTFail("expected tileHashMismatch")
        } catch RouterError.tileHashMismatch(let id, _, _) {
            XCTAssertEqual(id, entry.id)
        }
    }

    // MARK: - T4: epoch mismatch refused

    func testEpochMismatchRefused() throws {
        let object = try TiledFixture.generate(side: 16)
        let dir = scratchDir("epoch")
        defer { removeScratch(dir) }
        let boundaries = TiledFixture.boundaries(side: 16, tiles: 4)
        _ = try TiledGraphFiles.write(object: object, dataRoot: dir, name: "g", boundaries: boundaries)
        let manifest = try TiledGraphFiles.readManifest(dataRoot: dir, name: "g")
        let entry = manifest.tiles[0]
        let metaPath = "\(TiledGraphFiles.tileDirectory(dataRoot: dir, name: "g", entry: entry))/meta.json"

        var meta = try JSONDecoder().decode(TileMeta.self, from: Data(contentsOf: URL(fileURLWithPath: metaPath)))
        meta.lastPersistedTickEpoch = 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(meta).write(to: URL(fileURLWithPath: metaPath))

        do {
            _ = try TiledGraphFiles.loadTile(dataRoot: dir, name: "g", manifest: manifest, tileId: entry.id)
            XCTFail("expected tileInconsistent")
        } catch RouterError.tileInconsistent(let id, let metaEpoch, let bodyEpoch) {
            XCTAssertEqual(id, entry.id)
            XCTAssertEqual(metaEpoch, 1)
            XCTAssertEqual(bodyEpoch, 0)
        }
    }

    // MARK: - Leftover .tmp reported

    func testLeftoverTempReported() throws {
        let object = try TiledFixture.generate(side: 16)
        let dir = scratchDir("leftover")
        defer { removeScratch(dir) }
        let boundaries = TiledFixture.boundaries(side: 16, tiles: 4)
        _ = try TiledGraphFiles.write(object: object, dataRoot: dir, name: "g", boundaries: boundaries)
        let manifest = try TiledGraphFiles.readManifest(dataRoot: dir, name: "g")
        let entry = manifest.tiles[0]
        let bodyPath = "\(TiledGraphFiles.tileDirectory(dataRoot: dir, name: "g", entry: entry))/body.dags"
        try Data("stray-tmp".utf8).write(to: URL(fileURLWithPath: bodyPath + ".tmp"))

        let loaded = try TiledGraphFiles.loadTile(dataRoot: dir, name: "g", manifest: manifest, tileId: entry.id)
        XCTAssertTrue(loaded.leftoverTemp)
    }

    // MARK: - Halo files parse

    func testHaloFilesParse() throws {
        let object = try TiledFixture.generate(side: 44)
        let dir = scratchDir("halo")
        defer { removeScratch(dir) }
        let boundaries = TiledFixture.boundaries(side: 44, tiles: 4)
        let report = try TiledGraphFiles.write(object: object, dataRoot: dir, name: "g", boundaries: boundaries)
        let manifest = try TiledGraphFiles.readManifest(dataRoot: dir, name: "g")

        var totalUpper = 0, totalLower = 0
        for entry in manifest.tiles {
            let tdir = TiledGraphFiles.tileDirectory(dataRoot: dir, name: "g", entry: entry)
            let upper = try TiledGraphFiles.readRankHalo(path: "\(tdir)/halo_upper.bin")
            let lower = try TiledGraphFiles.readRankHalo(path: "\(tdir)/halo_lower.bin")
            XCTAssertEqual(upper.version, 1)
            XCTAssertEqual(upper.kind, 1)
            XCTAssertEqual(lower.version, 1)
            XCTAssertEqual(lower.kind, 0)
            XCTAssertEqual(upper.entries.count, entry.crossingsOut.count)
            XCTAssertEqual(lower.entries.count, entry.crossingsIn.count)
            totalUpper += upper.entries.count
            totalLower += lower.entries.count
        }
        XCTAssertEqual(totalUpper, report.crossings)
        XCTAssertEqual(totalLower, report.crossings)
        print("testHaloFilesParse: side=44 tiles=4 totalUpperEntries=\(totalUpper) totalLowerEntries=\(totalLower)")
    }

    // MARK: - T6: sizes and times

    func testT6PrintsSizesAndTimes() throws {
        let object = try TiledFixture.generate(side: 128)
        let dir = scratchDir("t6")
        defer { removeScratch(dir) }
        let boundaries = TiledFixture.boundaries(side: 128, tiles: 8)
        let report = try TiledGraphFiles.write(object: object, dataRoot: dir, name: "g", boundaries: boundaries)

        let singlePath = dir + "/single.dags"
        let (singleBytes, _, singleMs) = try DagDBSnapshot.save(
            engine: object.engine, nodeCount: object.nodeCount, gridW: 128, gridH: 128,
            tickCount: 0, path: singlePath
        )

        print("T6 side=128 tiles=8: single snapshot bytes=\(singleBytes) ms=\(String(format: "%.3f", singleMs))")
        var sumTileBytes = 0
        for (i, b) in report.bytesPerTile.enumerated() {
            print("  tile \(i): bytes=\(b) write_ms=\(String(format: "%.3f", report.writeMsPerTile[i]))")
            sumTileBytes += b
        }
        print("  sum(tile bytes)=\(sumTileBytes) vs single=\(singleBytes)")
        XCTAssertEqual(report.bytesPerTile.count, 8)
        XCTAssertEqual(report.writeMsPerTile.count, 8)
    }
}
