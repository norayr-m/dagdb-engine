import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// The wire side of `docs/contracts/CORE_DURABILITY_GATES_FROZEN.md`:
/// C4's kernel gate as the daemon sees it, and C10's rank-bound fixture.
final class CoreDurabilityDaemonTests: XCTestCase {

    /// C4 · a hand-corrupted neighbour index leaves the truth buffer alone
    /// and the daemon still answers with `nodes_computed`.
    func testCorruptNeighbourIndexLeavesTruthAloneAndTickStillReports() throws {
        let f = try HandlerFixture(side: 8, maxRank: 4)   // neighbours all -1
        let e = f.handler.engine
        let n = e.nodeCount

        XCTAssertTrue(f.handler.handle("SET 5 TRUTH 1").hasPrefix("OK"))
        // The corruption: a neighbour index one past the table.
        e.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: n * 6)[5 * 6 + 0] = Int32(n + 1)

        let before = e.readTruthStates()
        let reply = f.handler.handle("TICK 1")
        XCTAssertTrue(reply.hasPrefix("OK TICK 1"), reply)
        XCTAssertTrue(reply.contains("nodes_computed=\(n)"), reply)

        // Every LUT is CONST0 on a fresh fixture, so the whole buffer goes to
        // false: the corrupted slot contributes nothing and nothing outside
        // the buffer is read for it.
        let after = e.readTruthStates()
        XCTAssertEqual(after, [UInt8](repeating: 0, count: n))
        XCTAssertEqual(before[5], 1, "the fixture really did set node 5 first")
    }

    /// C10 · a node held at rank ≥ `nodeCount` by a DIRECT write — the shape
    /// no verb accepts and only a corrupt buffer or an old file can produce.
    /// The existing rank-bound fixture runs 0…21 over 81 nodes and never
    /// reaches the clamp, so that gate could not fail on it (audit A, 48).
    func testARankAtOrAboveNodeCountIsNamedAndLeftOutOfTheDispatch() throws {
        let f = try HandlerFixture(side: 8, maxRank: 8)   // 64 nodes
        let e = f.handler.engine
        let n = e.nodeCount

        // Direct write: SET RANK refuses this value at the door (R3).
        XCTAssertTrue(f.handler.handle("SET 7 RANK 150").hasPrefix("ERROR out_of_range"))
        e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)[7] = 150
        e.markRankTopologyDirty()

        // VALIDATE names it, with the node and the rank.
        let v = f.handler.handle("VALIDATE")
        XCTAssertTrue(v.hasPrefix("FAIL VALIDATE rank bound:"), v)
        XCTAssertTrue(v.contains("node 7"), v)
        XCTAssertTrue(v.contains("150"), v)
        XCTAssertTrue(v.contains("outside every dispatch"), v)

        // And the tick leaves it out — one node short, on the wire.
        let tick = f.handler.handle("TICK 1")
        XCTAssertTrue(tick.contains("nodes_computed=\(n - 1)"), tick)
        XCTAssertEqual(e.rankDispatchNodeCount(), n - 1)
    }

    // MARK: - C12(iii) · CONNECT BACK logs before it applies

    private func walDir() throws -> String {
        let d = NSTemporaryDirectory() + "dagdb-c12-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    /// The order, gated from the end that CAN be observed. Killing the
    /// process between the append and the buffer write is not simulable, so
    /// the gate is its consequence: a log that will not take the record must
    /// leave the back edge unregistered. If the apply ran first — as it did
    /// before C12 — the edge would be registered and the log would be empty,
    /// which is precisely the state a crash in that window used to leave.
    func testConnectBackLeavesNoEdgeWhenTheLogRefusesTheRecord() throws {
        let dir = try walDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "refuse.log"
        let appender = try DagDBWAL.Appender(path: path, nodeCount: 64)
        let f = try HandlerFixture(side: 8, wal: appender, maxRank: 8)
        let e = f.handler.engine

        appender.refuseAppendsForGate = true
        let reply = f.handler.handle("CONNECT BACK FROM 11 TO 12")

        XCTAssertTrue(reply.hasPrefix("ERROR wal:"), reply)
        XCTAssertEqual(e.backEdgeCount, 0,
                       "a record the log refused must not leave a registered edge")
        XCTAssertFalse(e.isRegister(node: 12),
                       "nor a register flag on its destination")

        // And the log really is empty — header only, no torn record.
        appender.refuseAppendsForGate = false
        appender.barrier()
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(bytes.count, DagDBWAL.headerSize)
    }

    /// The other half of the same order: validation runs BEFORE the append,
    /// so an edge the engine refuses writes no record at all.
    func testRefusedBackEdgeWritesNoRecord() throws {
        let dir = try walDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "refused.log"
        let appender = try DagDBWAL.Appender(path: path, nodeCount: 64)
        let f = try HandlerFixture(side: 8, wal: appender, maxRank: 8)
        let e = f.handler.engine

        // Give node 12 a combinational input, so it cannot become a register.
        e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: 64)[5] = 3
        e.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: 64 * 6)[12 * 6 + 0] = 5

        let reply = f.handler.handle("CONNECT BACK FROM 11 TO 12")
        XCTAssertTrue(reply.hasPrefix("ERROR schema:"), reply)
        XCTAssertTrue(reply.contains("combinational"), reply)
        XCTAssertEqual(e.backEdgeCount, 0)

        appender.barrier()
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(bytes.count, DagDBWAL.headerSize,
                       "a refused edge writes no record — the log is header-only")
    }

    /// And the accepted path still does both, in that order: the record is
    /// in the log and the edge is in the engine.
    func testAcceptedBackEdgeIsBothLoggedAndApplied() throws {
        let dir = try walDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "accepted.log"
        let appender = try DagDBWAL.Appender(path: path, nodeCount: 64)
        let f = try HandlerFixture(side: 8, wal: appender, maxRank: 8)
        let e = f.handler.engine

        XCTAssertTrue(f.handler.handle("CONNECT BACK FROM 11 TO 12").hasPrefix("OK"))
        XCTAssertEqual(e.backEdgeCount, 1)
        XCTAssertTrue(e.isRegister(node: 12))

        appender.barrier()
        // One CONNECT_BACK record: len(4) + opcode(1) + payload(8).
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(bytes.count, DagDBWAL.headerSize + 13)
        XCTAssertEqual(bytes[DagDBWAL.headerSize + 4],
                       DagDBWAL.Opcode.connectBack.rawValue)

        // Replay reproduces it in a fresh engine.
        let fresh = try DagDBEngine(grid: HexGrid(width: 8, height: 8),
                                    state: DagDBState(width: 8, height: 8), maxRank: 8)
        let r = try DagDBWAL.replay(engine: fresh, nodeCount: 64, path: path)
        XCTAssertEqual(r.recordsApplied, 1)
        XCTAssertEqual(fresh.backEdgeSrcs, [11])
        XCTAssertEqual(fresh.backEdgeDsts, [12])
    }
}
