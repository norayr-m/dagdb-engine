import XCTest
@testable import DagDB

/// C2 · a SAVE that returns success can be LOADed —
/// `docs/contracts/CORE_DURABILITY_GATES_FROZEN.md`.
final class CoreDurabilitySnapshotTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-c2-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    private func makeEngine(side: Int, maxRank: Int = 8) throws -> DagDBEngine {
        try DagDBEngine(grid: HexGrid(width: side, height: side),
                        state: DagDBState(width: side, height: side), maxRank: maxRank)
    }

    /// Deterministic, poorly-compressible bytes.
    private struct LCG {
        var s: UInt64
        mutating func next() -> UInt64 {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            var x = s
            x ^= x >> 33; x = x &* 0xff51afd7ed558ccd
            x ^= x >> 33; x = x &* 0xc4ceb9fe1a85ec53
            x ^= x >> 33
            return x
        }
    }

    /// Fill every persisted buffer with seeded noise — the case zlib expands.
    private func fillIncompressible(_ e: DagDBEngine, seed: UInt64) {
        var g = LCG(s: seed)
        let n = e.nodeCount
        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let low  = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high = e.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let type = e.nodeTypeBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        for i in 0..<n {
            rank[i] = g.next()
            low[i]  = UInt32(truncatingIfNeeded: g.next())
            high[i] = UInt32(truncatingIfNeeded: g.next())
            truth[i] = UInt8(truncatingIfNeeded: g.next())
            type[i]  = UInt8(truncatingIfNeeded: g.next())
        }
        for i in 0..<(n * 6) { nb[i] = Int32(truncatingIfNeeded: g.next()) }
    }

    private func bodyEqual(_ a: DagDBEngine, _ b: DagDBEngine) -> String? {
        let n = a.nodeCount
        func cmp<T: Equatable>(_ name: String, _ buf: (DagDBEngine) -> UnsafeMutableRawPointer,
                               _ t: T.Type, _ count: Int) -> String? {
            let pa = buf(a).bindMemory(to: T.self, capacity: count)
            let pb = buf(b).bindMemory(to: T.self, capacity: count)
            for i in 0..<count where pa[i] != pb[i] {
                return "\(name)[\(i)] differs"
            }
            return nil
        }
        return cmp("rank", { $0.rankBuf.contents() }, UInt64.self, n)
            ?? cmp("truth", { $0.truthStateBuf.contents() }, UInt8.self, n)
            ?? cmp("nodeType", { $0.nodeTypeBuf.contents() }, UInt8.self, n)
            ?? cmp("lutLow", { $0.lut6LowBuf.contents() }, UInt32.self, n)
            ?? cmp("lutHigh", { $0.lut6HighBuf.contents() }, UInt32.self, n)
            ?? cmp("neighbors", { $0.neighborsBuf.contents() }, Int32.self, n * 6)
    }

    // MARK: - control gate

    /// An incompressible body SAVEs compressed and LOADs back equal. Today
    /// `zlibCompress` sizes its output at `input.count`, zlib expands, the
    /// encode returns 0, and the file is written with `bodyBytes = 0`.
    func testIncompressibleBodySavesCompressedAndLoadsBackEqual() throws {
        let side = 16
        let src = try makeEngine(side: side)
        fillIncompressible(src, seed: 0x5EED)

        let path = tmpDir! + "incompressible.dags"
        let saved = try DagDBSnapshot.save(
            engine: src, nodeCount: src.nodeCount,
            gridW: side, gridH: side, tickCount: 3,
            path: path, compressed: true)
        XCTAssertGreaterThan(saved.bytesWritten, DagDBSnapshot.headerSize,
                             "a SAVE that returns success wrote a body")

        let dst = try makeEngine(side: side)
        _ = try DagDBSnapshot.load(
            engine: dst, nodeCount: dst.nodeCount,
            gridW: side, gridH: side, path: path, validate: false)
        XCTAssertNil(bodyEqual(src, dst))
    }

    /// The compressor itself: a growth-aware encode never returns nothing.
    func testZlibCompressHandlesExpansion() throws {
        var g = LCG(s: 99)
        var raw = Data(count: 64 * 1024)
        raw.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            for i in 0..<p.count { p[i] = UInt8(truncatingIfNeeded: g.next()) }
        }
        let packed = DagDBSnapshot.zlibCompress(raw)
        XCTAssertFalse(packed.isEmpty, "incompressible input must still encode")
        let back = DagDBSnapshot.zlibDecompress(packed, expectedSize: raw.count)
        XCTAssertEqual(back, raw)
    }

    // MARK: - header fields refuse instead of trapping

    func testHeaderRefusesOutOfRangeNodeCountByName() {
        XCTAssertThrowsError(try DagDBSnapshot.buildHeader(
            nodeCount: Int(UInt32.max) + 1, gridW: 4, gridH: 4,
            tickCount: 0, flags: DagDBSnapshot.Flags(), bodyBytes: 100)) { err in
            guard let e = err as? DagDBSnapshot.SnapError,
                  case .headerFieldOverflow(let field, _) = e else {
                return XCTFail("expected headerFieldOverflow, got \(err)")
            }
            XCTAssertEqual(field, "nodeCount")
        }
    }

    func testHeaderRefusesOutOfRangeBodyBytesByName() {
        XCTAssertThrowsError(try DagDBSnapshot.buildHeader(
            nodeCount: 16, gridW: 4, gridH: 4,
            tickCount: 0, flags: DagDBSnapshot.Flags(),
            bodyBytes: Int(UInt32.max) + 1)) { err in
            guard let e = err as? DagDBSnapshot.SnapError,
                  case .headerFieldOverflow(let field, _) = e else {
                return XCTFail("expected headerFieldOverflow, got \(err)")
            }
            XCTAssertEqual(field, "bodyBytes")
        }
    }

    // MARK: - unknown lane bit

    /// A v6 file whose lane flags carry bit 3 names the unknown lane instead
    /// of surfacing later as an "ENVS magic mismatch".
    func testUnknownLaneFlagBitRefusedByName() throws {
        let side = 4
        let src = try makeEngine(side: side)
        let srcNb = src.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: src.nodeCount * 6)
        for i in 0..<(src.nodeCount * 6) { srcNb[i] = -1 }
        let plain = tmpDir! + "lanes.dags"
        _ = try DagDBSnapshot.save(engine: src, nodeCount: src.nodeCount,
                                   gridW: side, gridH: side, tickCount: 0, path: plain)
        var bytes = try Data(contentsOf: URL(fileURLWithPath: plain))
        // Find the WGTS section: header + body + back-edge section (count 0).
        let laneStart = DagDBSnapshot.headerSize + src.nodeCount * 42 + 4
        XCTAssertEqual([UInt8](bytes[laneStart..<laneStart + 4]),
                       DagDBSnapshot.laneSectionMagic)
        bytes[laneStart + 4] = 0x08            // unknown lane bit
        let crafted = tmpDir! + "lanes_bit3.dags"
        try bytes.write(to: URL(fileURLWithPath: crafted))

        let dst = try makeEngine(side: side)
        XCTAssertThrowsError(try DagDBSnapshot.load(
            engine: dst, nodeCount: dst.nodeCount, gridW: side, gridH: side,
            path: crafted, verifyManifest: false)) { err in
            guard let e = err as? DagDBSnapshot.SnapError,
                  case .unknownLaneFlag(let bits) = e else {
                return XCTFail("expected unknownLaneFlag, got \(err)")
            }
            XCTAssertEqual(bits, 0x08)
        }
    }


    // MARK: - load marks the rank topology dirty itself

    /// The library API, with no daemon to compensate: after LOAD the rank
    /// topology must be rebuilt, or the next tick dispatches the PRE-load
    /// rank shape.
    func testLoadMarksRankTopologyDirtyThroughTheLibraryAPI() throws {
        let side = 8
        let src = try makeEngine(side: side)
        // No combinational edges, so the rank spread below is a valid DAG.
        let srcNb = src.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: src.nodeCount * 6)
        for i in 0..<(src.nodeCount * 6) { srcNb[i] = -1 }
        let rank = src.rankBuf.contents().bindMemory(to: UInt64.self, capacity: src.nodeCount)
        for i in 0..<src.nodeCount { rank[i] = UInt64(i % 6) }
        let path = tmpDir! + "ranks.dags"
        _ = try DagDBSnapshot.save(engine: src, nodeCount: src.nodeCount,
                                   gridW: side, gridH: side, tickCount: 0, path: path)

        // A destination whose topology is CLEAN: every rank 0, already compacted.
        let dst = try makeEngine(side: side)
        dst.ensureRankTopology()
        XCTAssertEqual(dst.highestRankPresent, 0)
        XCTAssertFalse(dst.rankTopologyDirty)

        _ = try DagDBSnapshot.load(engine: dst, nodeCount: dst.nodeCount,
                                   gridW: side, gridH: side, path: path)
        XCTAssertTrue(dst.rankTopologyDirty,
                      "load must mark the rank topology dirty itself")
        dst.ensureRankTopology()
        XCTAssertEqual(dst.highestRankPresent, 5)
    }
}
