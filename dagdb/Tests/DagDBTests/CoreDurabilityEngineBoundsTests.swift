import XCTest
@testable import DagDB

/// C4 · public engine APIs do not read or write past their buffers —
/// `docs/contracts/CORE_DURABILITY_GATES_FROZEN.md`. One out-of-range call
/// per site, plus the rank kernel against a hand-corrupted neighbour index.
final class CoreDurabilityEngineBoundsTests: XCTestCase {

    private func bareEngine(side: Int, maxRank: Int = 8) throws -> DagDBEngine {
        let e = try DagDBEngine(grid: HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side),
                                maxRank: maxRank)
        let nb = e.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        return e
    }

    // MARK: - one out-of-range call per public site

    func testClearBackEdgesRefusesAnOutOfRangeNode() throws {
        let e = try bareEngine(side: 4)
        XCTAssertThrowsError(try e.clearBackEdges(toNode: UInt32(e.nodeCount))) { err in
            guard let be = err as? DagDBEngine.BackEdgeError,
                  case .nodeIndexOutOfRange(let node, let n) = be else {
                return XCTFail("expected nodeIndexOutOfRange, got \(err)")
            }
            XCTAssertEqual(Int(node), e.nodeCount)
            XCTAssertEqual(n, e.nodeCount)
        }
    }

    func testIsRegisterRefusesAnOutOfRangeNode() throws {
        let e = try bareEngine(side: 4)
        XCTAssertFalse(e.isRegister(node: UInt32(e.nodeCount)),
                       "a node outside the table is not a register — and must " +
                       "not be read for")
        XCTAssertFalse(e.isRegister(node: UInt32(e.nodeCount + 1000)))
    }

    func testAddBackEdgeUncheckedRefusesAnOutOfRangeIndex() throws {
        let e = try bareEngine(side: 4)
        let n = UInt32(e.nodeCount)
        XCTAssertThrowsError(try e.addBackEdgeUnchecked(src: 1, dst: n))
        XCTAssertThrowsError(try e.addBackEdgeUnchecked(src: n, dst: 1))
        XCTAssertEqual(e.backEdgeCount, 0, "no partial state after a refusal")
    }

    func testWriteTruthStatesRefusesAShortArray() throws {
        let e = try bareEngine(side: 4)
        let before = e.readTruthStates()
        XCTAssertThrowsError(
            try e.writeTruthStates([UInt8](repeating: 1, count: e.nodeCount - 1)))
        XCTAssertEqual(e.readTruthStates(), before, "a refused write changes nothing")
        // The exact-length call still works.
        try e.writeTruthStates([UInt8](repeating: 1, count: e.nodeCount))
        XCTAssertEqual(e.readTruthStates(), [UInt8](repeating: 1, count: e.nodeCount))
    }

    func testEngineInitRefusesAStateSmallerThanItsGrid() throws {
        XCTAssertThrowsError(
            try DagDBEngine(grid: HexGrid(width: 8, height: 8),
                            state: DagDBState(width: 4, height: 4))) { err in
            XCTAssertTrue("\(err)".contains("nodeCount"), "\(err)")
        }
    }

    /// The `+Graph` convenience init is the one back-edge installer that did
    /// not check, and it is also the producer `latchBackEdges` then trusts.
    /// A legitimate graph still builds — the check is a guard, not a wall.
    func testGraphConvenienceInitStillInstallsLegitimateBackEdges() throws {
        let g = DagDBGraph()
        let a = g.addLeaf(label: "a", rank: 1, truth: true)
        let r = g.addLeaf(label: "r", rank: 0, truth: false)
        try g.connectBack(from: a, to: r)
        let e = try DagDBEngine(graph: g)
        XCTAssertEqual(e.backEdgeCount, 1)
        XCTAssertTrue(e.isRegister(node: UInt32(r)))
    }

    // MARK: - the rank kernel against a corrupted neighbour index

    /// A neighbour index at or past `nodeCount` must be treated exactly as an
    /// empty slot (`-1`): the kernel reads nothing past the truth buffer, and
    /// the node evaluates from its remaining inputs alone.
    func testRankKernelTreatsAnOutOfRangeNeighbourAsAnEmptySlot() throws {
        let side = 8
        let e = try bareEngine(side: side, maxRank: 4)
        let n = e.nodeCount
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let low  = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high = e.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let nb   = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)

        // Everything CONST0 and false, so the only node that can move is the
        // one under test.
        for i in 0..<n {
            rank[i] = 0
            truth[i] = 0
            low[i] = UInt32(LUT6Preset.const0 & 0xFFFF_FFFF)
            high[i] = UInt32((LUT6Preset.const0 >> 32) & 0xFFFF_FFFF)
        }
        // Node 5: IDENTITY on slot 0, and slot 0 is corrupted past the table.
        let victim = 5
        low[victim]  = UInt32(LUT6Preset.identity & 0xFFFF_FFFF)
        high[victim] = UInt32((LUT6Preset.identity >> 32) & 0xFFFF_FFFF)
        nb[victim * 6 + 0] = Int32(n + 1)
        truth[victim] = 1
        e.markRankTopologyDirty()

        e.tick(tickNumber: 0)

        let after = e.readTruthStates()
        XCTAssertEqual(after[victim], 0,
                       "an out-of-range slot contributes nothing, so IDENTITY " +
                       "on an empty input vector is false")
        for i in 0..<n where i != victim {
            XCTAssertEqual(after[i], 0, "node \(i) moved")
        }
    }
}
