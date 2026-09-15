import XCTest
@testable import DagDB

/// C3 · VALIDATE covers what the engine evaluates —
/// `docs/contracts/CORE_DURABILITY_GATES_FROZEN.md`.
///
/// One directly injected violation per invariant.
final class CoreDurabilityValidateTests: XCTestCase {

    /// An engine with no combinational edges at all, so each test injects
    /// exactly one violation and nothing else.
    private func bareEngine(side: Int, maxRank: Int = 8) throws -> DagDBEngine {
        let e = try DagDBEngine(grid: HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side),
                                maxRank: maxRank)
        let nb = e.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        return e
    }

    private func setRank(_ e: DagDBEngine, _ node: Int, _ r: UInt64) {
        e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: e.nodeCount)[node] = r
        e.markRankTopologyDirty()
    }

    /// A clean engine validates clean — so every failure below is the
    /// injected violation and not the fixture.
    func testBareEngineValidatesClean() throws {
        let e = try bareEngine(side: 4)
        XCTAssertNil(DagDBSnapshot.validate(engine: e, nodeCount: e.nodeCount))
    }

    // MARK: - the register invariant

    func testValidateNamesARegisterThatHasCombinationalFanIn() throws {
        let e = try bareEngine(side: 4)
        setRank(e, 3, 1)                         // src outranks dst, so the
        setRank(e, 2, 0)                         // edge check itself passes
        try e.addBackEdge(src: 1, dst: 2)        // node 2 becomes a register
        // Inject the violation directly: a combinational input on a register.
        e.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: e.nodeCount * 6)[2 * 6 + 0] = 3

        let v = DagDBSnapshot.validate(engine: e, nodeCount: e.nodeCount)
        XCTAssertNotNil(v, "a register with combinational fan-in must be named")
        XCTAssertTrue((v ?? "").contains("register"), v ?? "")
        XCTAssertTrue((v ?? "").contains("node 2"), v ?? "")
    }

    // MARK: - back-edge index range

    func testValidateNamesAnOutOfRangeBackEdgeIndex() throws {
        let e = try bareEngine(side: 4)
        let n = e.nodeCount
        e.backEdgeSrcs.append(UInt32(n + 3))     // injected, past the table
        e.backEdgeDsts.append(2)
        e.isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: n)[2] = 1

        let v = DagDBSnapshot.validate(engine: e, nodeCount: n)
        XCTAssertNotNil(v, "a back-edge index past nodeCount must be named")
        XCTAssertTrue((v ?? "").contains("back-edge"), v ?? "")
        XCTAssertTrue((v ?? "").contains("\(n + 3)"), v ?? "")
    }

    // MARK: - isRegisterBuf ↔ back-edge destination agreement

    func testValidateNamesARegisterFlagWithNoBackEdge() throws {
        let e = try bareEngine(side: 4)
        e.isRegisterBuf.contents()
            .bindMemory(to: UInt8.self, capacity: e.nodeCount)[5] = 1

        let v = DagDBSnapshot.validate(engine: e, nodeCount: e.nodeCount)
        XCTAssertNotNil(v, "a register flag with no back-edge must be named")
        XCTAssertTrue((v ?? "").contains("node 5"), v ?? "")
    }

    func testValidateNamesABackEdgeDestinationThatIsNotFlagged() throws {
        let e = try bareEngine(side: 4)
        try e.addBackEdge(src: 1, dst: 6)
        // Injected disagreement: clear the flag but keep the back edge.
        e.isRegisterBuf.contents()
            .bindMemory(to: UInt8.self, capacity: e.nodeCount)[6] = 0

        let v = DagDBSnapshot.validate(engine: e, nodeCount: e.nodeCount)
        XCTAssertNotNil(v, "an unflagged back-edge destination must be named")
        XCTAssertTrue((v ?? "").contains("node 6"), v ?? "")
    }

    // MARK: - the rank bound against the dispatch's own thresholds

    /// Two nodes above the configured bound, ONE of which the dispatch
    /// actually reaches. The old line counted both and named neither
    /// distinctly, so "2 nodes at or above maxRank 8" read as two nodes the
    /// tick skips when only one of them is skipped (audit A, finding 10).
    func testValidateSeparatesRanksTheDispatchReachesFromRanksItDoesNot() throws {
        let e = try bareEngine(side: 8, maxRank: 8)     // 64 nodes, bound 8
        let n = e.nodeCount
        setRank(e, 9, 30)                               // above the bound, DISPATCHED
        setRank(e, 7, 150)                              // ≥ nodeCount, never dispatched

        let v = DagDBSnapshot.validate(engine: e, nodeCount: n)
        let s = v ?? ""
        XCTAssertNotNil(v)
        XCTAssertTrue(s.contains("2 node(s) at or above maxRank 8"), s)
        // The one the dispatch cannot reach is named on its own.
        XCTAssertTrue(s.contains("outside every dispatch"), s)
        XCTAssertTrue(s.contains("node 7"), s)
        XCTAssertTrue(s.contains("150"), s)
        // And the shortfall is a printed number, not an inference.
        XCTAssertEqual(e.rankDispatchNodeCount(), n - 1)
        XCTAssertTrue(s.contains("\(n - 1) of \(n)"), s)
        XCTAssertEqual(e.effectiveRankCount, 31)
    }

    /// A rank above the configured bound that the dispatch DOES reach: the
    /// line reports full coverage rather than implying a skipped node.
    func testValidateReportsFullCoverageForARankTheDispatchReaches() throws {
        let e = try bareEngine(side: 8, maxRank: 4)     // 64 nodes, bound 4
        let n = e.nodeCount
        setRank(e, 9, 20)

        let v = DagDBSnapshot.validate(engine: e, nodeCount: n)
        let s = v ?? ""
        XCTAssertNotNil(v)
        XCTAssertTrue(s.contains("at or above maxRank 4"), s)
        XCTAssertTrue(s.contains("\(n) of \(n)"),
                      "the node IS dispatched; the line must say so: \(s)")
        XCTAssertFalse(s.contains("outside every dispatch"), s)
        XCTAssertEqual(e.rankDispatchNodeCount(), n)
    }
}
