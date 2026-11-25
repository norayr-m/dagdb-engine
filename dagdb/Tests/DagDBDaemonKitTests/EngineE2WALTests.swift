import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// The bulk verbs' WAL records: one record per bulk, replayed whole or not at
/// all. Uses the new appender API, so on the older code without it its red is its
/// compile errors.
final class EngineE2WALTests: XCTestCase {

    private var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "engine-e2w-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    func engine(side: Int = 8) throws -> DagDBEngine {
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side), maxRank: 8)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        return e
    }

    /// A record replays whole: every edge, every truth byte, in order.
    func testBulkRecordsReplayWhole() throws {
        let p = tmp + "a.wal"
        let w = try DagDBWAL.Appender(path: p, nodeCount: 64)
        try w.connectBackBulk([(1, 2), (3, 4), (1, 2)])
        try w.setTruthBulk([(5, 1), (6, 200), (5, 0)])
        w.barrier()
        let e = try engine()
        let r = try DagDBWAL.replay(engine: e, nodeCount: 64, path: p)
        print("E2 WAL whole: applied=\(r.recordsApplied) skipped=\(r.recordsSkipped) back=\(e.backEdgeSrcs)->\(e.backEdgeDsts)")
        XCTAssertEqual(r.recordsApplied, 2)
        XCTAssertEqual(r.recordsSkipped, 0)
        XCTAssertEqual(e.backEdgeSrcs, [1, 3, 1]); XCTAssertEqual(e.backEdgeDsts, [2, 4, 2])
        let t = e.readTruthStates()
        XCTAssertEqual(t[5], 0); XCTAssertEqual(t[6], 200)
    }

    /// An entry the single record's replay rule refuses (state diverged from
    /// the live one: the destination became ternary; SET TRUTH 7 on a ternary
    /// node) refuses the record, named — nothing of it applied.
    func testBulkRecordRefusedWholeOnReplay() throws {
        let p = tmp + "b.wal"
        let w = try DagDBWAL.Appender(path: p, nodeCount: 64)
        try w.connectBackBulk([(1, 2), (3, 9)])
        try w.setTruthBulk([(5, 1), (9, 7)])
        w.barrier()
        let e = try engine()
        e.setNodeMode(9, TernaryReference.kindTThresh)
        let r = try DagDBWAL.replay(engine: e, nodeCount: 64, path: p)
        print("E2 WAL refused: \(r.refusals)")
        XCTAssertEqual(r.recordsApplied, 0)
        XCTAssertEqual(r.refusals.count, 2)
        XCTAssertTrue(r.refusals[0].contains("CONNECT_BACK_BULK of 2: entry 1: CONNECT BACK into ternary node 9"), r.refusals[0])
        XCTAssertTrue(r.refusals[1].contains("SET_TRUTH_BULK of 2: entry 1: node 9: SET TRUTH 7 on a ternary node"), r.refusals[1])
        XCTAssertEqual(e.backEdgeCount, 0)
        XCTAssertEqual(e.readTruthStates()[5], 0)
    }

    /// A record cut short (a crash mid-append) is a torn tail, not applied; a
    /// record whose count disagrees with its length is skipped as bad length.
    func testTornAndMisshapenBulkRecords() throws {
        let p = tmp + "c.wal"
        let w = try DagDBWAL.Appender(path: p, nodeCount: 64)
        try w.setTruthBulk([(5, 1)])
        try w.connectBackBulk([(1, 2), (3, 4)])
        w.barrier()
        var d = try Data(contentsOf: URL(fileURLWithPath: p))
        let full = d
        d.removeLast(3)
        try d.write(to: URL(fileURLWithPath: p))
        let e = try engine()
        let r = try DagDBWAL.replay(engine: e, nodeCount: 64, path: p)
        XCTAssertEqual(r.recordsApplied, 1)
        XCTAssertNotNil(r.truncatedAtOffset)
        XCTAssertEqual(e.backEdgeCount, 0)
        // The count field says 3 entries; the payload holds 2.
        var bad = full
        let second = DagDBWAL.headerSize + 5 + (4 + 5)
        bad[second + 5] = 3
        try bad.write(to: URL(fileURLWithPath: p))
        let e2 = try engine()
        let r2 = try DagDBWAL.replay(engine: e2, nodeCount: 64, path: p)
        XCTAssertEqual(r2.recordsApplied, 1)
        XCTAssertEqual(r2.skipReasons.badLength, 1)
        XCTAssertEqual(e2.backEdgeCount, 0)
    }

    /// The daemon's verbs on a log that will not take the record (a version-2
    /// log): refused by the append, nothing written.
    func testBulkOnAVersion2LogWritesNothing() throws {
        let p = tmp + "v2.wal"
        // A version-2 header, no records.
        var hdr = Data(DagDBWAL.magic)
        for v in [UInt32(2), UInt32(16), UInt32(0)] { withUnsafeBytes(of: v.littleEndian) { hdr.append(contentsOf: $0) } }
        try hdr.write(to: URL(fileURLWithPath: p))
        let f = try HandlerFixture(side: 4, wal: try DagDBWAL.Appender(path: p, nodeCount: 16))
        let h = f.shm.bindMemory(to: UInt32.self, capacity: 4)
        h[0] = 1; h[1] = shm1Word1(.connectBackBulk); h[2] = 1; h[3] = 2
        let r = f.handler.handle("CONNECT_BACK_BULK")
        print("E2 WAL v2 log: \(r)")
        XCTAssertTrue(r.hasPrefix("ERROR wal: append: "), r)
        XCTAssertEqual(f.handler.engine.backEdgeCount, 0)
        f.handler.walAppender?.barrier()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: p)).count, DagDBWAL.headerSize)
    }
}
