import XCTest
@testable import DagDB

/// C10 · fixtures that reach the edge —
/// `docs/contracts/CORE_DURABILITY_GATES_FROZEN.md`.
///
/// Every file here is built byte by byte from the layout documented at the
/// top of `DagDBSnapshot.swift`. No old writer is kept alive to produce
/// them: a fixture written by the code it is meant to police cannot fail,
/// which is exactly what audit A found for v1…v6 (finding 46) — 23 snapshot
/// tests, all of them round-tripping through today's v7 writer.
final class CoreDurabilityFixtureTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-c10-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - the known graph, in Swift values

    private let side = 4
    private var n: Int { side * side }

    private var ranks: [UInt64] { (0..<n).map { UInt64($0 % 4) } }
    private var truth: [UInt8]  { (0..<n).map { UInt8($0 % 3) } }
    private var types: [UInt8]  { (0..<n).map { UInt8($0 % 2) } }
    private var low: [UInt32]   { (0..<n).map { UInt32(0x1000 + $0) } }
    private var high: [UInt32]  { (0..<n).map { UInt32(0x2000 + $0) } }
    /// One real edge: node 0 (rank 0) reads node 3 (rank 3). Everything else
    /// empty, so the file's own validator has exactly one edge to check.
    private var neighbors: [Int32] {
        var nb = [Int32](repeating: -1, count: n * 6)
        nb[0 * 6 + 0] = 3
        return nb
    }

    // MARK: - byte helpers

    private func u32(_ v: UInt32) -> Data { var x = v; return Data(bytes: &x, count: 4) }
    private func f32(_ v: Float) -> Data { var x = v; return Data(bytes: &x, count: 4) }

    private func header(version: UInt32, flags: UInt32, bodyBytes: UInt32) -> Data {
        var d = Data()
        d.append(contentsOf: DagDBSnapshot.magic)
        d.append(u32(version))
        d.append(u32(UInt32(n)))
        d.append(u32(UInt32(side)))
        d.append(u32(UInt32(side)))
        d.append(u32(7))                    // tickCount
        d.append(u32(flags))
        d.append(u32(bodyBytes))
        return d
    }

    /// rank[N·w] · truth[N] · type[N] · low[N·4] · high[N·4] · neighbors[N·24]
    private func body(rankWidth: Int) -> Data {
        var d = Data()
        for r in ranks {
            switch rankWidth {
            case 1: d.append(UInt8(r))
            case 4: d.append(u32(UInt32(r)))
            default: var x = r; d.append(Data(bytes: &x, count: 8))
            }
        }
        d.append(contentsOf: truth)
        d.append(contentsOf: types)
        for v in low  { d.append(u32(v)) }
        for v in high { d.append(u32(v)) }
        for v in neighbors { d.append(u32(UInt32(bitPattern: v))) }
        return d
    }

    /// u32 count + count × (u32 src + u32 dst). One back edge: 5 → 6.
    private func backEdgeSection() -> Data {
        var d = u32(1)
        d.append(u32(5))
        d.append(u32(6))
        return d
    }

    /// "WGTS" + lane flags u8 + the present lanes. Here: the edge-weight
    /// lane only, every weight 2.0, so a v6 load is distinguishable from the
    /// default-reset every earlier version gets.
    private func laneSection() -> Data {
        var d = Data()
        d.append(contentsOf: DagDBSnapshot.laneSectionMagic)
        d.append(0x01)
        for _ in 0..<(n * 6) { d.append(f32(2.0)) }
        return d
    }

    private func envTrailer() -> Data {
        var d = Data()
        d.append(contentsOf: DagDBSnapshot.envTrailerMagic)
        d.append(DagDBSnapshot.SnapshotEnv.unspecified.rawValue)
        return d
    }

    private func file(version: UInt32) -> Data {
        let rankWidth = version == 1 ? 1 : (version == 2 ? 4 : 8)
        let b = body(rankWidth: rankWidth)
        // v1 files predate the flags/bodyBytes fields: those bytes were
        // reserved zero, and `load` falls back to computing the body size.
        var d = header(version: version, flags: 0,
                       bodyBytes: version == 1 ? 0 : UInt32(b.count))
        d.append(b)
        if version >= 4 { d.append(backEdgeSection()) }
        if version >= 6 { d.append(laneSection()) }
        if version >= 5 { d.append(envTrailer()) }
        return d
    }

    private func freshEngine() throws -> DagDBEngine {
        let e = try DagDBEngine(grid: HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side),
                                maxRank: 8)
        // Unrelated prior state, so a version that must RESET something is
        // caught doing it.
        let nb = e.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        let w = e.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: e.nodeCount * 6)
        w[0] = 9.0
        try e.addBackEdge(src: 1, dst: 2)
        return e
    }

    // MARK: - v1…v6 load and reproduce the known graph

    func testHandBuiltV1ThroughV6FilesLoadAndReproduceTheGraph() throws {
        for version in UInt32(1)...UInt32(6) {
            let path = tmpDir! + "fixture_v\(version).dags"
            try file(version: version).write(to: URL(fileURLWithPath: path))

            let e = try freshEngine()
            let r = try DagDBSnapshot.load(engine: e, nodeCount: n,
                                           gridW: side, gridH: side, path: path,
                                           verifyManifest: false)
            XCTAssertEqual(r.fileNodeCount, n, "v\(version)")
            XCTAssertEqual(r.fileTicks, 7, "v\(version)")
            XCTAssertEqual(r.bytesRead, file(version: version).count,
                           "v\(version): every section was accounted for")

            XCTAssertEqual(e.readRanks(), ranks, "v\(version) ranks")
            XCTAssertEqual(e.readTruthStates(), truth, "v\(version) truth")
            let typePtr = e.nodeTypeBuf.contents().bindMemory(to: UInt8.self, capacity: n)
            XCTAssertEqual(Array(UnsafeBufferPointer(start: typePtr, count: n)), types,
                           "v\(version) nodeType")
            let luts = e.readLUT6()
            XCTAssertEqual(luts.map { $0.low }, low, "v\(version) lut low")
            XCTAssertEqual(luts.map { $0.high }, high, "v\(version) lut high")
            let nbPtr = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
            XCTAssertEqual(Array(UnsafeBufferPointer(start: nbPtr, count: n * 6)), neighbors,
                           "v\(version) neighbours")

            // v1–v3 carry no back-edge section: load resets the list.
            // v4+ carry 5 → 6, and the earlier graph's 1 → 2 is gone either way.
            let wPtr = e.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
            if version >= 4 {
                XCTAssertEqual(e.backEdgeSrcs, [5], "v\(version) back-edge src")
                XCTAssertEqual(e.backEdgeDsts, [6], "v\(version) back-edge dst")
                XCTAssertTrue(e.isRegister(node: 6), "v\(version)")
            } else {
                XCTAssertEqual(e.backEdgeCount, 0, "v\(version) resets the back-edge list")
            }
            XCTAssertFalse(e.isRegister(node: 2),
                           "v\(version): the pre-load register flag is cleared")
            // Only v6 carries a lane; every earlier version resets to 1.0.
            XCTAssertEqual(wPtr[0], version >= 6 ? 2.0 : 1.0, "v\(version) edge weight")

            XCTAssertNil(DagDBSnapshot.validate(engine: e, nodeCount: n),
                         "v\(version) loaded a graph that validates")
        }
    }

    /// The v1 fallback specifically: `bodyBytes == 0` in the header, which is
    /// what a pre-flags writer left there, and the 1-byte rank width.
    func testV1LegacyBodyBytesZeroPathIsExercised() throws {
        let path = tmpDir! + "v1_zero.dags"
        let bytes = file(version: 1)
        try bytes.write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(bytes.count, DagDBSnapshot.headerSize + n * 35,
                       "a v1 body is 35 bytes per node")
        // The header's bodyBytes field really is zero.
        XCTAssertEqual(Array(bytes[28..<32]), [0, 0, 0, 0])

        let e = try freshEngine()
        _ = try DagDBSnapshot.load(engine: e, nodeCount: n, gridW: side, gridH: side,
                                   path: path, verifyManifest: false)
        XCTAssertEqual(e.readRanks(), ranks)
    }
}
