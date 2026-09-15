import XCTest
@testable import DagDB

/// C8 · Morton export/import carry all ten lanes and the back edges —
/// `docs/contracts/CORE_DURABILITY_GATES_FROZEN.md`.
final class CoreDurabilityMortonTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-c8-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    private func bareEngine(side: Int) throws -> DagDBEngine {
        let e = try DagDBEngine(grid: HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side),
                                maxRank: 8)
        let nb = e.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        return e
    }

    /// Round trip on a graph with registers and non-default lanes.
    func testExportImportCarriesEveryLaneAndTheBackEdges() throws {
        let side = 8
        let src = try bareEngine(side: side)
        let n = src.nodeCount

        let truth = src.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let rank  = src.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let type  = src.nodeTypeBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let low   = src.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high  = src.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let w     = src.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        let act   = src.activationBuf.contents().bindMemory(to: Int16.self, capacity: n)
        let val   = src.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)

        for i in 0..<n {
            truth[i] = UInt8(i % 3)
            rank[i]  = UInt64(i % 5)
            type[i]  = UInt8(i % 2)
            low[i]   = UInt32(0x1111_1111 &+ UInt32(i))
            high[i]  = UInt32(0x2222_2222 &+ UInt32(i))
            act[i]   = Int16(truncatingIfNeeded: -i)
            val[i]   = Float(i) * 0.5
        }
        for i in 0..<(n * 6) { w[i] = Float(i % 7) * 0.125 }
        try src.addBackEdge(src: 5, dst: 6)
        try src.addBackEdge(src: 7, dst: 8)

        let dir = tmpDir! + "morton"
        let out = try DagDBSnapshot.exportMorton(engine: src, nodeCount: n, dir: dir)
        XCTAssertGreaterThan(out.bytesWritten, n * 42,
                             "the reported size must cover every lane written")

        // A destination carrying UNRELATED state, so import has to reset what
        // `load` resets rather than leaving the previous graph's registers on.
        let dst = try bareEngine(side: side)
        try dst.addBackEdge(src: 1, dst: 2)
        dst.edgeWeightsBuf.contents()
            .bindMemory(to: Float.self, capacity: n * 6)[0] = 99.0
        dst.ensureRankTopology()

        _ = try DagDBSnapshot.importMorton(engine: dst, nodeCount: n, dir: dir,
                                           validate: false)

        XCTAssertTrue(dst.rankTopologyDirty, "import must mark the rank topology dirty")
        XCTAssertEqual(dst.backEdgeSrcs, src.backEdgeSrcs)
        XCTAssertEqual(dst.backEdgeDsts, src.backEdgeDsts)
        XCTAssertFalse(dst.isRegister(node: 2), "the previous graph's register is gone")
        XCTAssertTrue(dst.isRegister(node: 6))
        XCTAssertTrue(dst.isRegister(node: 8))

        func same<T: Equatable>(_ name: String, _ f: (DagDBEngine) -> UnsafeMutableRawPointer,
                                _ t: T.Type, _ count: Int) {
            let a = f(src).bindMemory(to: T.self, capacity: count)
            let b = f(dst).bindMemory(to: T.self, capacity: count)
            for i in 0..<count where a[i] != b[i] {
                return XCTFail("\(name)[\(i)]: \(a[i]) vs \(b[i])")
            }
        }
        same("rank", { $0.rankBuf.contents() }, UInt64.self, n)
        same("truth", { $0.truthStateBuf.contents() }, UInt8.self, n)
        same("nodeType", { $0.nodeTypeBuf.contents() }, UInt8.self, n)
        same("lutLow", { $0.lut6LowBuf.contents() }, UInt32.self, n)
        same("lutHigh", { $0.lut6HighBuf.contents() }, UInt32.self, n)
        same("neighbors", { $0.neighborsBuf.contents() }, Int32.self, n * 6)
        same("edgeWeights", { $0.edgeWeightsBuf.contents() }, Float.self, n * 6)
        same("activation", { $0.activationBuf.contents() }, Int16.self, n)
        same("nodeValue", { $0.nodeValueBuf.contents() }, Float.self, n)
        same("isRegister", { $0.isRegisterBuf.contents() }, UInt8.self, n)
    }

    /// A directory holding only the six original files still imports — and
    /// the lanes it does not carry come back at their documented defaults,
    /// not at the destination's previous values.
    func testImportOfASixFileDirectoryResetsTheLanesItDoesNotCarry() throws {
        let side = 4
        let src = try bareEngine(side: side)
        let n = src.nodeCount
        let dir = tmpDir! + "six"
        _ = try DagDBSnapshot.exportMorton(engine: src, nodeCount: n, dir: dir)
        for extra in ["edge_weights.bin", "activation.bin", "node_value.bin",
                      "is_register.bin", "back_edges.bin"] {
            try? FileManager.default.removeItem(atPath: "\(dir)/\(extra)")
        }

        let dst = try bareEngine(side: side)
        try dst.addBackEdge(src: 1, dst: 2)
        dst.edgeWeightsBuf.contents()
            .bindMemory(to: Float.self, capacity: n * 6)[0] = 99.0
        dst.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)[0] = 7.0

        _ = try DagDBSnapshot.importMorton(engine: dst, nodeCount: n, dir: dir,
                                           validate: false)
        XCTAssertEqual(dst.backEdgeCount, 0)
        XCTAssertFalse(dst.isRegister(node: 2))
        XCTAssertEqual(dst.edgeWeightsBuf.contents()
            .bindMemory(to: Float.self, capacity: n * 6)[0], 1.0)
        XCTAssertEqual(dst.nodeValueBuf.contents()
            .bindMemory(to: Float.self, capacity: n)[0], 0.0)
    }
}
