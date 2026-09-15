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

        // ── AMENDMENT 6, letter 1: the repaired object ──

        // LUTs are identical between the two generations, and every one of
        // them is parity (or complemented parity) over that node's present
        // slots — recomputed here from the slot set, not read back from the
        // generator.
        let la = a.engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let lb = b.engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let ha = a.engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let hb = b.engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        var lutMismatch = 0, nonParity = 0, complemented = 0
        var constantWithInputs = 0, inputlessNodes = 0
        for i in 0..<n {
            if la[i] != lb[i] || ha[i] != hb[i] { lutMismatch += 1 }
            var mask = 0
            for d in 0..<6 where na[i * 6 + d] >= 0 { mask |= 1 << d }
            if mask == 0 { inputlessNodes += 1 }
            // A node WITH inputs whose table is constant is the vacuity
            // this amendment repairs. A node with none is a source: its
            // parity over an empty mask is the constant `choice`, which is
            // what the letter's own formula gives.
            let isConstant = (la[i] == 0 && ha[i] == 0) || (la[i] == .max && ha[i] == .max)
            if mask != 0 && isConstant { constantWithInputs += 1 }
            let choice = Int(la[i] & 1)          // bit(0) = (0 + choice) & 1
            if choice == 1 { complemented += 1 }
            for idx in 0..<64 {
                let want = UInt32(((idx & mask).nonzeroBitCount + choice) & 1)
                let got = idx < 32 ? (la[i] >> UInt32(idx)) & 1 : (ha[i] >> UInt32(idx - 32)) & 1
                if want != got { nonParity += 1; break }
            }
        }
        XCTAssertEqual(lutMismatch, 0, "two generations must write identical LUT6 words")
        XCTAssertEqual(nonParity, 0, "every LUT6 must be parity or complemented parity over its present slots")
        XCTAssertEqual(
            constantWithInputs, 0,
            "a node with inputs whose table is constant is the vacuity this amendment repairs")
        print("testGeneratorIsDeterministic: side=16 complemented_tables=\(complemented) of \(n) "
            + "inputless_nodes=\(inputlessNodes)")

        // Registers: same set, same back edges, `S = ¬R` with `R` a strictly
        // higher rank, `R`'s only reader is `S`, and no back edge crosses a
        // tile boundary of ANY frozen tiling.
        XCTAssertEqual(a.engine.backEdgeSrcs, b.engine.backEdgeSrcs, "back-edge sources")
        XCTAssertEqual(a.engine.backEdgeDsts, b.engine.backEdgeDsts, "back-edge destinations")
        XCTAssertGreaterThanOrEqual(a.engine.backEdgeCount, 1, "the repaired object carries registers")
        let boundaryUnion = Set([2, 4, 8].flatMap { TiledFixture.boundaries(side: 16, tiles: $0) })
        var registerReaderCounts: [Int] = []
        for i in 0..<a.engine.backEdgeCount {
            let src = Int(a.engine.backEdgeSrcs[i]), dst = Int(a.engine.backEdgeDsts[i])
            XCTAssertTrue(a.engine.isRegister(node: UInt32(dst)), "back-edge dst \(dst) must be a register")
            XCTAssertEqual(a.engine.combinationalFanIn(node: UInt32(dst)), 0, "register \(dst) fan-in")
            XCTAssertEqual(ra[src] + 1, ra[dst], "S must sit exactly one rank below its R")
            XCTAssertFalse(
                boundaryUnion.contains(ra[dst]),
                "a register at a frozen-tiling boundary rank would be a cross-tile back edge")
            XCTAssertGreaterThanOrEqual(
                ra[dst], 2,
                "rank 0 is the single centre node, reserved as the frozen T2/T3 query seed")
            // S's only present slot is R, and its table is ¬(idx & 1).
            var present: [Int32] = []
            for d in 0..<6 where na[src * 6 + d] >= 0 { present.append(na[src * 6 + d]) }
            XCTAssertEqual(present, [Int32(dst)], "S's only present input must be R")
            XCTAssertEqual(la[src] & 1, 1, "S(R=0) must be 1")
            XCTAssertEqual((la[src] >> 1) & 1, 0, "S(R=1) must be 0")
            // `R` KEEPS its other readers (AMENDMENT 7, finding A rejected
            // the earlier build's clearing of them): the latch-timing
            // defect they expose is fixed in the ticker, not designed out
            // of the object. `S` must be among them.
            var readers = 0
            for u in 0..<n {
                for d in 0..<6 where na[u * 6 + d] == Int32(dst) { readers += 1 }
            }
            XCTAssertGreaterThanOrEqual(readers, 1, "register \(dst) must at least be read by its S")
            registerReaderCounts.append(readers)
        }
        print("testGeneratorIsDeterministic: side=16 readers_per_register=\(registerReaderCounts)")
        print("testGeneratorIsDeterministic: side=16 registers=\(a.engine.backEdgeCount)")
    }

    // MARK: - AMENDMENT 6: tile bodies carry their registers

    /// Every intra-tile back edge survives the split, the body write and
    /// the reload — on both the query path (`loadTile`) and the ticker's
    /// (`loadTileWithGhosts`). A tile writer that dropped them would tick a
    /// register-free graph and W1/W2 would fail for a reason nothing else
    /// in the suite names.
    func testTileBodiesCarryRegisters() throws {
        for side in [16, 44] {
            for tiles in [2, 4, 8] {
                let object = try TiledFixture.generate(side: side)
                let dir = scratchDir("registers-\(side)-\(tiles)")
                defer { removeScratch(dir) }
                let boundaries = TiledFixture.boundaries(side: side, tiles: tiles)
                let report = try TiledGraphFiles.write(
                    object: object, dataRoot: dir, name: "g", boundaries: boundaries)
                let manifest = try TiledGraphFiles.readManifest(dataRoot: dir, name: "g")

                // Expected, in tile-local numbering, straight off the engine.
                var expected: [UInt32: Set<[UInt64]>] = [:]
                for i in 0..<object.engine.backEdgeCount {
                    let src = GlobalNodeID(raw: report.globalOf[Int(object.engine.backEdgeSrcs[i])])
                    let dst = GlobalNodeID(raw: report.globalOf[Int(object.engine.backEdgeDsts[i])])
                    XCTAssertEqual(src.tileId, dst.tileId, "no back edge may cross a tile boundary")
                    expected[src.tileId, default: []].insert([src.localNodeId, dst.localNodeId])
                }

                var seenTotal = 0
                for entry in manifest.tiles {
                    let loaded = try TiledGraphFiles.loadTile(
                        dataRoot: dir, name: "g", manifest: manifest, tileId: entry.id)
                    var got = Set<[UInt64]>()
                    for i in 0..<loaded.engine.backEdgeCount {
                        got.insert([UInt64(loaded.engine.backEdgeSrcs[i]),
                                    UInt64(loaded.engine.backEdgeDsts[i])])
                        XCTAssertTrue(
                            loaded.engine.isRegister(node: loaded.engine.backEdgeDsts[i]),
                            "reloaded tile \(entry.id) must flag its register")
                    }
                    XCTAssertEqual(
                        got, expected[entry.id] ?? [],
                        "tile \(entry.id) (side=\(side) tiles=\(tiles)) back edges after reload")

                    let ghosted = try TiledGraphFiles.loadTileWithGhosts(
                        dataRoot: dir, name: "g", manifest: manifest, tileId: entry.id)
                    var ghostGot = Set<[UInt64]>()
                    for i in 0..<ghosted.engine.backEdgeCount {
                        ghostGot.insert([UInt64(ghosted.engine.backEdgeSrcs[i]),
                                         UInt64(ghosted.engine.backEdgeDsts[i])])
                    }
                    XCTAssertEqual(
                        ghostGot, expected[entry.id] ?? [],
                        "tile \(entry.id) ghosted engine back edges")
                    seenTotal += got.count
                }
                XCTAssertEqual(
                    seenTotal, object.engine.backEdgeCount,
                    "every back edge must land in exactly one tile (side=\(side) tiles=\(tiles))")
            }
        }
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
