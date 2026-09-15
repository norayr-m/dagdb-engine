import XCTest
@testable import DagDB

/// C7 · reader sessions see the whole graph —
/// `docs/contracts/CORE_DURABILITY_GATES_FROZEN.md`.
final class CoreDurabilityReaderTests: XCTestCase {

    /// A primary with registers, non-default lanes and no hex adjacency, so
    /// the session's view is exactly what `open` copied.
    private func makePrimary(side: Int) throws -> (DagDBEngine, HexGrid, DagDBState) {
        let grid = try HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        let e = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        let n = e.nodeCount
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        for i in 0..<(n * 6) { nb[i] = -1 }
        return (e, grid, state)
    }

    /// Control gate: a reader on a graph with registers ticks bit-for-bit
    /// with the primary. A session that copied six of ten buffers saw the
    /// registers as ordinary combinational nodes, so the two diverged on the
    /// first tick (audit A, finding 41).
    func testReaderOnAGraphWithRegistersTicksBitForBitWithThePrimary() throws {
        let side = 8
        let (primary, grid, state) = try makePrimary(side: side)
        let n = primary.nodeCount

        let truth = primary.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let low   = primary.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high  = primary.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let w     = primary.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        let act   = primary.activationBuf.contents().bindMemory(to: Int16.self, capacity: n)
        let val   = primary.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)

        // A register that holds a true value, and a plain node next to it.
        for i in 0..<n {
            low[i]  = UInt32(LUT6Preset.const0 & 0xFFFF_FFFF)
            high[i] = UInt32((LUT6Preset.const0 >> 32) & 0xFFFF_FFFF)
        }
        low[3]  = UInt32(LUT6Preset.const1 & 0xFFFF_FFFF)
        high[3] = UInt32((LUT6Preset.const1 >> 32) & 0xFFFF_FFFF)
        truth[3] = 1
        truth[4] = 1
        try primary.addBackEdge(src: 3, dst: 4)      // node 4 is a register

        // Non-default lanes, so the six-of-ten copy is visible if it returns.
        w[7 * 6 + 2] = 0.25
        act[9] = -3
        val[11] = 1.5

        let mgr = DagDBReaderSessionManager()
        let session = try mgr.open(primary: primary, grid: grid,
                                   stateTemplate: state, maxRank: 8, tickCount: 0)
        let snap = session.snapshotEngine

        XCTAssertEqual(snap.backEdgeCount, 1, "the session installed the back edge")
        XCTAssertTrue(snap.isRegister(node: 4))
        XCTAssertEqual(snap.edgeWeightsBuf.contents()
            .bindMemory(to: Float.self, capacity: n * 6)[7 * 6 + 2], 0.25)
        XCTAssertEqual(snap.activationBuf.contents()
            .bindMemory(to: Int16.self, capacity: n)[9], -3)
        XCTAssertEqual(snap.nodeValueBuf.contents()
            .bindMemory(to: Float.self, capacity: n)[11], 1.5)

        for k in 0..<3 {
            primary.tick(tickNumber: UInt32(k))
            snap.tick(tickNumber: UInt32(k))
        }
        XCTAssertEqual(snap.readTruthStates(), primary.readTruthStates(),
                       "the session must tick bit-for-bit with the primary")
    }

    func testOpenRefusesAGridSmallerThanThePrimary() throws {
        let (primary, _, _) = try makePrimary(side: 8)
        let smallGrid = try HexGrid(width: 4, height: 4)
        let smallState = DagDBState(width: 4, height: 4)
        let mgr = DagDBReaderSessionManager()
        XCTAssertThrowsError(
            try mgr.open(primary: primary, grid: smallGrid,
                         stateTemplate: smallState, maxRank: 8, tickCount: 0)) { err in
            guard let e = err as? DagDBReaderSessionManager.MVCCError,
                  case .snapshotFailed(let why) = e else {
                return XCTFail("expected snapshotFailed, got \(err)")
            }
            XCTAssertTrue(why.contains("16") && why.contains("64"), why)
        }
        XCTAssertEqual(mgr.openCount, 0, "a refused open leaves no session")
    }

    func testSessionIdCarriesA64BitTimeField() throws {
        let (primary, grid, state) = try makePrimary(side: 4)
        let mgr = DagDBReaderSessionManager()
        let a = try mgr.open(primary: primary, grid: grid, stateTemplate: state,
                             maxRank: 8, tickCount: 0)
        let b = try mgr.open(primary: primary, grid: grid, stateTemplate: state,
                             maxRank: 8, tickCount: 0)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertTrue(a.id.hasPrefix("r"))
        // "r" + 16 hex of seconds + 16 hex of counter.
        XCTAssertEqual(a.id.count, 33, a.id)
    }
}
