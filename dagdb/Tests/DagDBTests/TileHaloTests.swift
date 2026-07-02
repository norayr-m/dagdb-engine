import XCTest
@testable import DagDB

final class TileHaloTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dagdb-tile-halo-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeStrip(edge: HaloEdge, width: Int, epoch: UInt64) -> DagHaloStrip {
        var s = DagHaloStrip(edge: edge, width: width, depth: 3, tickEpoch: epoch)
        for i in 0..<s.cellCount {
            s.rank[i]       = UInt64(i) * 7 &+ epoch
            s.truth[i]      = UInt8(i & 1)
            s.nodeType[i]   = UInt8((i % 3) + 1)
            s.lut6Low[i]    = UInt32(truncatingIfNeeded: i &* 0x1234_5678)
            s.lut6High[i]   = UInt32(truncatingIfNeeded: i &* 0xDEAD_BEEF)
            s.isRegister[i] = UInt8(i % 2)
            for k in 0..<6 {
                s.neighbors[i * 6 + k] = Int32(i * 6 + k) - 1
            }
        }
        return s
    }

    func testRoundTripSingleStrip() throws {
        let original = makeStrip(edge: .north, width: 16, epoch: 42)
        let path = tmpDir.appendingPathComponent("one.bin").path

        try TileHalo.writeHalos([original], to: path)
        guard let read = try TileHalo.readHalos(from: path) else {
            XCTFail("expected non-nil halos for written file")
            return
        }

        XCTAssertEqual(read.count, 1)
        let r = read[0]
        XCTAssertEqual(r.edge, original.edge)
        XCTAssertEqual(r.width, original.width)
        XCTAssertEqual(r.depth, original.depth)
        XCTAssertEqual(r.tickEpoch, original.tickEpoch)
        XCTAssertEqual(r.rank, original.rank)
        XCTAssertEqual(r.truth, original.truth)
        XCTAssertEqual(r.nodeType, original.nodeType)
        XCTAssertEqual(r.lut6Low, original.lut6Low)
        XCTAssertEqual(r.lut6High, original.lut6High)
        XCTAssertEqual(r.neighbors, original.neighbors)
        XCTAssertEqual(r.isRegister, original.isRegister)
    }

    func testRoundTripAllFourEdges() throws {
        let strips: [DagHaloStrip] = HaloEdge.allCases.map {
            makeStrip(edge: $0, width: 8, epoch: UInt64($0.rawValue) + 100)
        }
        let path = tmpDir.appendingPathComponent("four.bin").path

        try TileHalo.writeHalos(strips, to: path)
        guard let read = try TileHalo.readHalos(from: path) else {
            XCTFail("expected non-nil halos")
            return
        }
        XCTAssertEqual(read.count, 4)
        for (orig, got) in zip(strips, read) {
            XCTAssertEqual(orig.edge, got.edge)
            XCTAssertEqual(orig.tickEpoch, got.tickEpoch)
            XCTAssertEqual(orig.rank, got.rank)
            XCTAssertEqual(orig.neighbors, got.neighbors)
            XCTAssertEqual(orig.isRegister, got.isRegister)
        }
    }

    func testReadMissingFileReturnsNil() throws {
        let path = tmpDir.appendingPathComponent("does-not-exist.bin").path
        let result = try TileHalo.readHalos(from: path)
        XCTAssertNil(result)
    }

    func testRejectsBadMagic() throws {
        let path = tmpDir.appendingPathComponent("bad-magic.bin").path
        var data = Data()
        var bogusMagic: UInt32 = 0xBADC_AFE
        data.append(Data(bytes: &bogusMagic, count: 4))
        try data.write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try TileHalo.readHalos(from: path)) { err in
            guard case TileHalo.HaloError.badMagic(let m) = err else {
                XCTFail("expected badMagic, got \(err)")
                return
            }
            XCTAssertEqual(m, 0xBADC_AFE)
        }
    }

    func testRejectsUnsupportedVersion() throws {
        let path = tmpDir.appendingPathComponent("bad-version.bin").path
        var data = Data()
        var magic = TileHalo.magic
        var futureVersion: UInt32 = 99
        data.append(Data(bytes: &magic, count: 4))
        data.append(Data(bytes: &futureVersion, count: 4))
        try data.write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try TileHalo.readHalos(from: path)) { err in
            guard case TileHalo.HaloError.badVersion(let v) = err else {
                XCTFail("expected badVersion, got \(err)")
                return
            }
            XCTAssertEqual(v, 99)
        }
    }

    func testTruncatedFileReportsError() throws {
        let strip = makeStrip(edge: .east, width: 4, epoch: 1)
        let path = tmpDir.appendingPathComponent("truncated.bin").path
        try TileHalo.writeHalos([strip], to: path)

        let full = try Data(contentsOf: URL(fileURLWithPath: path))
        let chopped = full.prefix(20)
        try chopped.write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try TileHalo.readHalos(from: path)) { err in
            if case TileHalo.HaloError.truncated = err { return }
            XCTFail("expected truncated error, got \(err)")
        }
    }

    func testExtractPerimeterNorth() throws {
        let tileW = 8
        let tileH = 8
        let n = tileW * tileH
        var rank = [UInt64](repeating: 0, count: n)
        var truth = [UInt8](repeating: 0, count: n)
        var nodeType = [UInt8](repeating: 0, count: n)
        let lut6Low = [UInt32](repeating: 0, count: n)
        let lut6High = [UInt32](repeating: 0, count: n)
        let neighbors = [Int32](repeating: -1, count: n * 6)
        var isRegister = [UInt8](repeating: 0, count: n)

        // Mark the top three rows so we can identify them in the strip.
        for row in 0..<3 {
            for col in 0..<tileW {
                let idx = row * tileW + col
                rank[idx] = UInt64(row * 100 + col)
                truth[idx] = 1
                nodeType[idx] = UInt8(row + 1)
                isRegister[idx] = UInt8(col & 1)
            }
        }

        let strip = TileHalo.extractPerimeter(
            rank: rank, truth: truth, nodeType: nodeType,
            lut6Low: lut6Low, lut6High: lut6High,
            neighbors: neighbors, isRegister: isRegister,
            tileW: tileW, tileH: tileH, edge: .north,
            tickEpoch: 5
        )

        XCTAssertEqual(strip.edge, .north)
        XCTAssertEqual(strip.width, tileW)
        XCTAssertEqual(strip.depth, 3)
        XCTAssertEqual(strip.tickEpoch, 5)
        XCTAssertEqual(strip.rank.count, tileW * 3)
        for row in 0..<3 {
            for col in 0..<tileW {
                let si = row * tileW + col
                XCTAssertEqual(strip.rank[si], UInt64(row * 100 + col))
                XCTAssertEqual(strip.truth[si], 1)
                XCTAssertEqual(strip.nodeType[si], UInt8(row + 1))
                XCTAssertEqual(strip.isRegister[si], UInt8(col & 1))
            }
        }
    }

    func testLoadAdjacentHalosWorldBoundaryReturnsEmpty() throws {
        // (tx=0, ty=0) corner — north and west neighbors don't exist.
        let halos = try TileHalo.loadAdjacentHalos(
            dir: tmpDir.path, tx: 0, ty: 0,
            nTilesX: 4, nTilesY: 4,
            tileW: 16, tileH: 16
        )
        XCTAssertEqual(halos.count, 4)
        for edge in HaloEdge.allCases {
            let s = halos[edge]!
            XCTAssertEqual(s.tickEpoch, 0)
            XCTAssertTrue(s.rank.allSatisfy { $0 == 0 })
            XCTAssertTrue(s.isRegister.allSatisfy { $0 == 0 })
        }
    }
}
