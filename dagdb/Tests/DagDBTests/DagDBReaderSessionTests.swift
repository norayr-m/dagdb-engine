import XCTest
@testable import DagDB

final class DagDBReaderSessionTests: XCTestCase {

    private func makePrimary(side: Int) throws -> (DagDBEngine, HexGrid, DagDBState, Int) {
        let grid = HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        // zero neighbors like the daemon does
        let nb = engine.neighborsBuf.contents().bindMemory(
            to: Int32.self, capacity: engine.nodeCount * 6)
        for i in 0..<(engine.nodeCount * 6) { nb[i] = -1 }
        return (engine, grid, state, side)
    }

    private func seedChain(_ engine: DagDBEngine) {
        let r = engine.rankBuf.contents().bindMemory(
            to: UInt64.self, capacity: engine.nodeCount)
        let t = engine.truthStateBuf.contents().bindMemory(
            to: UInt8.self, capacity: engine.nodeCount)
        r[0] = 2; r[1] = 1; r[2] = 0
        t[0] = 1; t[1] = 0; t[2] = 0
    }

    // MARK: - Session lifecycle

    func testOpenCreatesIndependentSnapshot() throws {
        let (primary, grid, state, _) = try makePrimary(side: 8)
        seedChain(primary)

        let mgr = DagDBReaderSessionManager()
        let session = try mgr.open(
            primary: primary, grid: grid, stateTemplate: state,
            maxRank: 8, tickCount: 42
        )

        XCTAssertEqual(mgr.openCount, 1)
        XCTAssertEqual(session.tickCountAtOpen, 42)
        XCTAssertEqual(session.nodeCount, primary.nodeCount)

        // Snapshot engine should have matching state.
        let snapRanks = session.snapshotEngine.rankBuf.contents().bindMemory(
            to: UInt64.self, capacity: primary.nodeCount)
        XCTAssertEqual(snapRanks[0], 2)
        XCTAssertEqual(snapRanks[1], 1)
        XCTAssertEqual(snapRanks[2], 0)
    }

    func testSnapshotIsolatedFromPrimaryWrites() throws {
        let (primary, grid, state, _) = try makePrimary(side: 8)
        seedChain(primary)

        let mgr = DagDBReaderSessionManager()
        let session = try mgr.open(
            primary: primary, grid: grid, stateTemplate: state,
            maxRank: 8, tickCount: 0
        )

        // Mutate the primary after session open.
        let primaryTruth = primary.truthStateBuf.contents().bindMemory(
            to: UInt8.self, capacity: primary.nodeCount)
        primaryTruth[0] = 99  // invalid value on purpose — proves isolation

        let snapTruth = session.snapshotEngine.truthStateBuf.contents().bindMemory(
            to: UInt8.self, capacity: session.nodeCount)
        XCTAssertEqual(snapTruth[0], 1, "snapshot must retain pre-mutation value")
        XCTAssertEqual(primaryTruth[0], 99, "primary has the mutation")
    }

    func testMultipleSessionsIndependent() throws {
        let (primary, grid, state, _) = try makePrimary(side: 8)
        seedChain(primary)

        let mgr = DagDBReaderSessionManager()
        let s1 = try mgr.open(primary: primary, grid: grid, stateTemplate: state,
                              maxRank: 8, tickCount: 1)

        // Mutate primary.
        let pt = primary.truthStateBuf.contents().bindMemory(
            to: UInt8.self, capacity: primary.nodeCount)
        pt[1] = 2

        let s2 = try mgr.open(primary: primary, grid: grid, stateTemplate: state,
                              maxRank: 8, tickCount: 2)

        XCTAssertEqual(mgr.openCount, 2)
        XCTAssertNotEqual(s1.id, s2.id)

        let t1 = s1.snapshotEngine.truthStateBuf.contents().bindMemory(
            to: UInt8.self, capacity: s1.nodeCount)
        let t2 = s2.snapshotEngine.truthStateBuf.contents().bindMemory(
            to: UInt8.self, capacity: s2.nodeCount)
        // s1 opened before the mutation → sees the old value.
        XCTAssertEqual(t1[1], 0)
        // s2 opened after → sees the new value.
        XCTAssertEqual(t2[1], 2)
    }

    func testCloseReleasesSession() throws {
        let (primary, grid, state, _) = try makePrimary(side: 8)
        seedChain(primary)

        let mgr = DagDBReaderSessionManager()
        let session = try mgr.open(
            primary: primary, grid: grid, stateTemplate: state,
            maxRank: 8, tickCount: 0
        )
        XCTAssertEqual(mgr.openCount, 1)

        let ok = mgr.close(session.id)
        XCTAssertTrue(ok)
        XCTAssertEqual(mgr.openCount, 0)
        XCTAssertNil(mgr.get(session.id))

        // Closing twice returns false.
        XCTAssertFalse(mgr.close(session.id))
    }

    func testGetUnknownSessionReturnsNil() throws {
        let mgr = DagDBReaderSessionManager()
        XCTAssertNil(mgr.get("r00000000"))
        XCTAssertFalse(mgr.close("r00000000"))
    }

    func testCloseAllReleasesEverything() throws {
        let (primary, grid, state, _) = try makePrimary(side: 8)
        seedChain(primary)

        let mgr = DagDBReaderSessionManager()
        _ = try mgr.open(primary: primary, grid: grid, stateTemplate: state,
                          maxRank: 8, tickCount: 0)
        _ = try mgr.open(primary: primary, grid: grid, stateTemplate: state,
                          maxRank: 8, tickCount: 0)
        _ = try mgr.open(primary: primary, grid: grid, stateTemplate: state,
                          maxRank: 8, tickCount: 0)
        XCTAssertEqual(mgr.openCount, 3)

        mgr.closeAll()
        XCTAssertEqual(mgr.openCount, 0)
    }

    // MARK: - Snapshot integrity

    func testRankBufferCopiedCorrectly() throws {
        let (primary, grid, state, _) = try makePrimary(side: 8)
        let r = primary.rankBuf.contents().bindMemory(
            to: UInt64.self, capacity: primary.nodeCount)
        // High-rank values that need u32 — previously would have been truncated.
        r[0] = 100_000
        r[1] = 4_000_000_000
        r[2] = 12345

        let mgr = DagDBReaderSessionManager()
        let session = try mgr.open(primary: primary, grid: grid, stateTemplate: state,
                                    maxRank: 8, tickCount: 0)
        let sr = session.snapshotEngine.rankBuf.contents().bindMemory(
            to: UInt64.self, capacity: session.nodeCount)
        XCTAssertEqual(sr[0], 100_000)
        XCTAssertEqual(sr[1], 4_000_000_000)
        XCTAssertEqual(sr[2], 12345)
    }

    func testNeighborsBufferCopiedCorrectly() throws {
        let (primary, grid, state, _) = try makePrimary(side: 8)
        let nb = primary.neighborsBuf.contents().bindMemory(
            to: Int32.self, capacity: primary.nodeCount * 6)
        nb[0 * 6 + 0] = 5
        nb[0 * 6 + 1] = 6
        nb[2 * 6 + 3] = 4

        let mgr = DagDBReaderSessionManager()
        let session = try mgr.open(primary: primary, grid: grid, stateTemplate: state,
                                    maxRank: 8, tickCount: 0)
        let snb = session.snapshotEngine.neighborsBuf.contents().bindMemory(
            to: Int32.self, capacity: session.nodeCount * 6)
        XCTAssertEqual(snb[0 * 6 + 0], 5)
        XCTAssertEqual(snb[0 * 6 + 1], 6)
        XCTAssertEqual(snb[2 * 6 + 3], 4)

        // Tamper primary → snapshot unchanged.
        nb[0 * 6 + 0] = -1
        XCTAssertEqual(snb[0 * 6 + 0], 5)
    }

    func testSessionIDIsUnique() throws {
        let (primary, grid, state, _) = try makePrimary(side: 8)

        let mgr = DagDBReaderSessionManager()
        var ids: Set<String> = []
        for _ in 0..<10 {
            let s = try mgr.open(primary: primary, grid: grid, stateTemplate: state,
                                  maxRank: 8, tickCount: 0)
            ids.insert(s.id)
        }
        XCTAssertEqual(ids.count, 10)
    }
}
