import XCTest
@testable import DagDB

/// C5 · HexGrid files are versioned and every section is length-checked —
/// `docs/contracts/CORE_DURABILITY_GATES_FROZEN.md`.
final class CoreDurabilityGridTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-c5-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - construction refuses what the encoding cannot carry

    func testConstructionRefusesAnAxisBeyondTheMortonRange() {
        // q is one 16-bit Morton axis: a column index must fit in 16 bits.
        XCTAssertNotNil(HexGrid.refusalReason(width: 70_000, height: 2))
        XCTAssertThrowsError(try HexGrid.validated(width: 70_000, height: 2))
        // The cube-row fold is the other axis, and it is SIGNED: the negative
        // half is what a wide grid produces at row 0.
        XCTAssertNotNil(HexGrid.refusalReason(width: 4, height: 40_000))
        XCTAssertThrowsError(try HexGrid.validated(width: 4, height: 40_000))
    }

    func testConstructionRefusesANodeCountBeyondTheIndexSpace() {
        // The node index space is Int32 (`neighbors`, `mortonRank`).
        XCTAssertNotNil(HexGrid.refusalReason(width: 65_536, height: 32_768))
        XCTAssertThrowsError(try HexGrid.validated(width: 65_536, height: 32_768))
    }

    func testConstructionRefusesANonPositiveAxis() {
        XCTAssertNotNil(HexGrid.refusalReason(width: 0, height: 4))
        XCTAssertNotNil(HexGrid.refusalReason(width: 4, height: -1))
    }

    func testOrdinaryGridsAreAccepted() throws {
        XCTAssertNil(HexGrid.refusalReason(width: 8, height: 8))
        let g = try HexGrid.validated(width: 8, height: 8)
        XCTAssertEqual(g.nodeCount, 64)
        XCTAssertEqual(Set(g.mortonRank).count, 64, "Morton ranks stay a permutation")
        XCTAssertTrue(g.verifyColoring())
    }

    // MARK: - F1 · the plain initialiser is the refusing one

    /// `HexGrid.init(width:height:)` itself throws what `validated` throws:
    /// there is no non-throwing door that skips `refusalReason`.
    func testPlainInitIsTheRefusingConstructor() {
        XCTAssertThrowsError(try HexGrid(width: 70_000, height: 1)) { e in
            guard let g = e as? HexGrid.GridError,
                  case .axesOutOfRange(let why) = g else {
                return XCTFail("expected GridError.axesOutOfRange, got \(e)")
            }
            XCTAssertEqual(why, HexGrid.refusalReason(width: 70_000, height: 1),
                           "the init refuses by the same name `refusalReason` gives")
            XCTAssertTrue(why.contains("70000"), "the refusal carries the value: \(why)")
        }
        // The other two refusals reach the same door.
        XCTAssertThrowsError(try HexGrid(width: 4, height: 40_000))
        XCTAssertThrowsError(try HexGrid(width: 65_536, height: 32_768))
        XCTAssertThrowsError(try HexGrid(width: 0, height: 4))
    }

    /// ...and every grid the tree actually builds still constructs.
    func testTheGridsTheTreeBuildsAllStillConstruct() throws {
        for (w, h) in [(4, 4), (6, 6), (8, 8), (16, 16), (32, 32), (64, 64),
                       (78, 78), (128, 128), (256, 256), (1_024, 1), (65_536, 1)] {
            let g = try HexGrid(width: w, height: h)
            XCTAssertEqual(g.nodeCount, w * h, "\(w)x\(h)")
        }
    }

    // MARK: - the file gains a magic and a version

    func testSaveLoadRoundTrip() throws {
        let g = try HexGrid(width: 6, height: 6)
        let p = tmpDir! + "grid.bin"
        try g.save(to: p)
        let back = try HexGrid.load(from: p)
        XCTAssertEqual(back.width, g.width)
        XCTAssertEqual(back.height, g.height)
        XCTAssertEqual(back.neighbors, g.neighbors)
        XCTAssertEqual(back.mortonOrder, g.mortonOrder)
        XCTAssertEqual(back.mortonToNode, g.mortonToNode)
        XCTAssertEqual(back.mortonRank, g.mortonRank)
        XCTAssertEqual(back.colors, g.colors)
        XCTAssertEqual(back.colorGroups.map { $0 }, g.colorGroups.map { $0 })
    }

    func testLoadRefusesAFileWithNoMagic() throws {
        let g = try HexGrid(width: 6, height: 6)
        let p = tmpDir! + "grid.bin"
        try g.save(to: p)
        var bytes = try Data(contentsOf: URL(fileURLWithPath: p))
        bytes[0] = 0x00
        let bad = tmpDir! + "nomagic.bin"
        try bytes.write(to: URL(fileURLWithPath: bad))
        XCTAssertThrowsError(try HexGrid.load(from: bad)) { err in
            guard let e = err as? HexGrid.GridError, case .invalidMagic = e else {
                return XCTFail("expected invalidMagic, got \(err)")
            }
        }
    }

    func testLoadRefusesAnUnknownVersionByName() throws {
        let g = try HexGrid(width: 6, height: 6)
        let p = tmpDir! + "grid.bin"
        try g.save(to: p)
        var bytes = try Data(contentsOf: URL(fileURLWithPath: p))
        bytes[4] = 9                     // version field, little-endian low byte
        let bad = tmpDir! + "v9.bin"
        try bytes.write(to: URL(fileURLWithPath: bad))
        XCTAssertThrowsError(try HexGrid.load(from: bad)) { err in
            guard let e = err as? HexGrid.GridError,
                  case .unsupportedVersion(let v) = e else {
                return XCTFail("expected unsupportedVersion, got \(err)")
            }
            XCTAssertEqual(v, 9)
        }
    }

    /// Truncate at every section boundary; every one is a named refusal, and
    /// never a grid whose arrays are shorter than its own node count.
    func testEverySectionBoundaryIsRefusedWhenTruncated() throws {
        let g = try HexGrid(width: 6, height: 6)
        let p = tmpDir! + "grid.bin"
        try g.save(to: p)
        let full = try Data(contentsOf: URL(fileURLWithPath: p))
        let n = g.nodeCount

        // Offsets just inside each section: header, neighbours, mortonOrder,
        // mortonToNode, mortonRank, colors, and the colour groups.
        var cuts: [Int] = [4, 10, 16]
        var off = 16
        for size in [n * 6 * 4, n * 4, n * 4, n * 4, n] {
            cuts.append(off + size / 2)
            off += size
        }
        cuts.append(off + 2)             // mid first colour-group count
        for cut in cuts where cut < full.count {
            let bad = tmpDir! + "cut_\(cut).bin"
            try full.subdata(in: 0..<cut).write(to: URL(fileURLWithPath: bad))
            XCTAssertThrowsError(try HexGrid.load(from: bad),
                                 "truncation at \(cut) must be refused by name")
        }
    }

    func testLoadRefusesAnOverflowingHeader() throws {
        var bytes = Data()
        bytes.append(contentsOf: HexGrid.fileMagic)
        func u32(_ v: UInt32) -> Data { var x = v; return Data(bytes: &x, count: 4) }
        bytes.append(u32(HexGrid.fileVersion))
        bytes.append(u32(0xFFFF_FFFF))   // width
        bytes.append(u32(0xFFFF_FFFF))   // height
        let bad = tmpDir! + "overflow.bin"
        try bytes.write(to: URL(fileURLWithPath: bad))
        XCTAssertThrowsError(try HexGrid.load(from: bad))
    }

    func testLoadRefusesAnOutOfRangeColourGroupEntry() throws {
        let g = try HexGrid(width: 6, height: 6)
        let p = tmpDir! + "grid.bin"
        try g.save(to: p)
        var bytes = try Data(contentsOf: URL(fileURLWithPath: p))
        let n = g.nodeCount
        // First colour-group entry sits after the count that follows `colors`.
        let groupsStart = 16 + n * 6 * 4 + n * 4 * 3 + n
        var poison = Int32(n + 7)
        let entryOff = groupsStart + 4
        withUnsafeBytes(of: &poison) { raw in
            for (i, b) in raw.enumerated() { bytes[entryOff + i] = b }
        }
        let bad = tmpDir! + "badgroup.bin"
        try bytes.write(to: URL(fileURLWithPath: bad))
        XCTAssertThrowsError(try HexGrid.load(from: bad)) { err in
            XCTAssertTrue("\(err)".contains("\(n + 7)"), "\(err)")
        }
    }
}
