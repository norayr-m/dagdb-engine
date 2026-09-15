import XCTest
@testable import DagDB

/// C6 · BFS is bounded and says what it excludes —
/// `docs/contracts/CORE_DURABILITY_GATES_FROZEN.md`.
final class CoreDurabilityBFSTests: XCTestCase {

    private func bareEngine(side: Int) throws -> DagDBEngine {
        let e = try DagDBEngine(grid: HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side),
                                maxRank: 8)
        let nb = e.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        return e
    }

    private func nbPtr(_ e: DagDBEngine) -> UnsafeMutablePointer<Int32> {
        e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
    }

    // MARK: - every neighbour index is checked, in the walk too

    func testUndirectedWalkIgnoresAnOutOfRangeNeighbour() throws {
        let e = try bareEngine(side: 8)
        let n = e.nodeCount
        let nb = nbPtr(e)
        nb[0 * 6 + 0] = 1                    // a real edge, 1 → 0
        nb[0 * 6 + 1] = Int32(n + 5)         // planted, past the table

        let r = try DagDBBFS.bfsDepthsUndirected(engine: e, nodeCount: n, from: 0)
        XCTAssertEqual(r.depths[0], 0)
        XCTAssertEqual(r.depths[1], 1)
        XCTAssertEqual(r.reached, 2, "the out-of-range slot contributes nothing")
    }

    func testBackwardWalkIgnoresAnOutOfRangeNeighbour() throws {
        let e = try bareEngine(side: 8)
        let n = e.nodeCount
        let nb = nbPtr(e)
        nb[0 * 6 + 0] = 1
        nb[0 * 6 + 1] = Int32(n + 5)

        let r = try DagDBBFS.bfsDepthsBackward(engine: e, nodeCount: n, from: 0)
        XCTAssertEqual(r.reached, 2)
        XCTAssertEqual(r.depths[1], 1)
    }

    // MARK: - the nodeCount parameter is checked against the engine

    func testBFSRefusesANodeCountLargerThanTheEngine() throws {
        let e = try bareEngine(side: 8)
        XCTAssertThrowsError(
            try DagDBBFS.bfsDepthsUndirected(engine: e, nodeCount: e.nodeCount + 1, from: 0))
        XCTAssertThrowsError(
            try DagDBBFS.bfsDepthsBackward(engine: e, nodeCount: e.nodeCount + 1, from: 0))
    }

    func testTruthRankIndexNamesANodeCountItCannotHonour() throws {
        let e = try bareEngine(side: 8)
        let idx = TruthRankIndex()
        idx.rebuild(engine: e, nodeCount: e.nodeCount + 1)
        XCTAssertNotNil(idx.lastRefusal, "a count the engine cannot back must be named")
        XCTAssertTrue((idx.lastRefusal ?? "").contains("\(e.nodeCount + 1)"),
                      idx.lastRefusal ?? "")
        XCTAssertEqual(idx.bucketSizes.values.reduce(0, +), e.nodeCount,
                       "the index covers the engine's nodes, not the caller's number")
        // An honest count leaves no refusal standing.
        idx.rebuild(engine: e, nodeCount: e.nodeCount)
        XCTAssertNil(idx.lastRefusal)
    }

    // MARK: - the disclosure

    /// A graph whose ONLY path from seed to target runs through a BACK_EDGE.
    /// The walk reads `neighborsBuf`, which back edges are not in; the result
    /// says so rather than reporting an unreachable target as a fact about
    /// the graph.
    func testBackEdgeOnlyPathIsUnreachableAndTheResultSaysWhy() throws {
        let e = try bareEngine(side: 8)
        let n = e.nodeCount
        // 1 --BACK_EDGE--> 2, and no combinational edge anywhere.
        try e.addBackEdge(src: 1, dst: 2)

        let r = try DagDBBFS.bfsDepthsUndirected(engine: e, nodeCount: n, from: 1)
        XCTAssertEqual(r.depths[2], -1,
                       "the latch edge is not a combinational edge")
        XCTAssertTrue(r.backEdgesExcluded)
        XCTAssertEqual(r.disclosure, "back_edges=excluded")
        XCTAssertEqual(r.backEdgeCount, 1,
                       "and the count of what was left out is reported")

        let b = try DagDBBFS.bfsDepthsBackward(engine: e, nodeCount: n, from: 2)
        XCTAssertEqual(b.depths[1], -1)
        XCTAssertTrue(b.backEdgesExcluded)
        XCTAssertEqual(b.backEdgeCount, 1)
    }

    func testAGraphWithNoBackEdgesStillCarriesTheDisclosure() throws {
        let e = try bareEngine(side: 8)
        let r = try DagDBBFS.bfsDepthsUndirected(engine: e, nodeCount: e.nodeCount, from: 0)
        XCTAssertTrue(r.backEdgesExcluded)
        XCTAssertEqual(r.backEdgeCount, 0)
    }
}
