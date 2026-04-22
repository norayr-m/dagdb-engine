import XCTest
@testable import DagDB

final class DagDBBFSTests: XCTestCase {

    private func makeEngine(side: Int) throws -> DagDBEngine {
        let grid = HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        // Zero the neighbor table — DagDB tests start with no edges.
        let nb = engine.neighborsBuf.contents().bindMemory(
            to: Int32.self, capacity: engine.nodeCount * 6)
        for i in 0..<(engine.nodeCount * 6) { nb[i] = -1 }
        return engine
    }

    /// Set inputs[dst] slot d to src. Caller ensures rank(src) > rank(dst).
    private func connect(_ engine: DagDBEngine, src: Int, dst: Int, slot: Int) {
        let nb = engine.neighborsBuf.contents().bindMemory(
            to: Int32.self, capacity: engine.nodeCount * 6)
        nb[dst * 6 + slot] = Int32(src)
    }

    private func setRank(_ engine: DagDBEngine, node: Int, rank: UInt8) {
        let r = engine.rankBuf.contents().bindMemory(
            to: UInt8.self, capacity: engine.nodeCount)
        r[node] = rank
    }

    // MARK: - Error path

    func testSeedOutOfRangeThrows() throws {
        let eng = try makeEngine(side: 8)
        XCTAssertThrowsError(
            try DagDBBFS.bfsDepthsUndirected(engine: eng, nodeCount: eng.nodeCount, from: 999999)
        )
        XCTAssertThrowsError(
            try DagDBBFS.bfsDepthsBackward(engine: eng, nodeCount: eng.nodeCount, from: -1)
        )
    }

    // MARK: - Backward BFS

    /// Linear chain: 0 ← 1 ← 2 ← 3 ← 4 (higher id = higher rank).
    /// Backward BFS from 0 follows inputs, reaching 1, 2, 3, 4 at depths 1..4.
    func testBackwardBFSLinearChain() throws {
        let eng = try makeEngine(side: 8)
        for i in 0...4 { setRank(eng, node: i, rank: UInt8(4 - i)) }
        // Inputs: 0's input is 1, 1's input is 2, 2's input is 3, 3's input is 4.
        connect(eng, src: 1, dst: 0, slot: 0)
        connect(eng, src: 2, dst: 1, slot: 0)
        connect(eng, src: 3, dst: 2, slot: 0)
        connect(eng, src: 4, dst: 3, slot: 0)

        let r = try DagDBBFS.bfsDepthsBackward(engine: eng, nodeCount: eng.nodeCount, from: 0)
        XCTAssertEqual(r.depths[0], 0)
        XCTAssertEqual(r.depths[1], 1)
        XCTAssertEqual(r.depths[2], 2)
        XCTAssertEqual(r.depths[3], 3)
        XCTAssertEqual(r.depths[4], 4)
        XCTAssertEqual(r.reached, 5)
        XCTAssertEqual(r.maxDepth, 4)
        // Nodes beyond the chain are unreachable.
        XCTAssertEqual(r.depths[5], -1)
    }

    /// Backward BFS from the "top" of the chain (node 4) reaches nothing since
    /// its inputs array is empty.
    func testBackwardBFSTopOfChain() throws {
        let eng = try makeEngine(side: 8)
        for i in 0...4 { setRank(eng, node: i, rank: UInt8(4 - i)) }
        connect(eng, src: 1, dst: 0, slot: 0)
        connect(eng, src: 2, dst: 1, slot: 0)

        let r = try DagDBBFS.bfsDepthsBackward(engine: eng, nodeCount: eng.nodeCount, from: 2)
        XCTAssertEqual(r.depths[2], 0)
        XCTAssertEqual(r.reached, 1)
        XCTAssertEqual(r.maxDepth, 0)
    }

    // MARK: - Undirected BFS

    /// Linear chain with undirected BFS from middle node 2 reaches all four
    /// neighbours at symmetric depths.
    func testUndirectedBFSLinearChainFromMiddle() throws {
        let eng = try makeEngine(side: 8)
        for i in 0...4 { setRank(eng, node: i, rank: UInt8(4 - i)) }
        connect(eng, src: 1, dst: 0, slot: 0)
        connect(eng, src: 2, dst: 1, slot: 0)
        connect(eng, src: 3, dst: 2, slot: 0)
        connect(eng, src: 4, dst: 3, slot: 0)

        let r = try DagDBBFS.bfsDepthsUndirected(engine: eng, nodeCount: eng.nodeCount, from: 2)
        XCTAssertEqual(r.depths[0], 2)  // 2 → 1 → 0
        XCTAssertEqual(r.depths[1], 1)
        XCTAssertEqual(r.depths[2], 0)
        XCTAssertEqual(r.depths[3], 1)
        XCTAssertEqual(r.depths[4], 2)
        XCTAssertEqual(r.reached, 5)
        XCTAssertEqual(r.maxDepth, 2)
    }

    // MARK: - Single-node-per-residue encoding (the correct one)
    //
    // For protein contact graphs, the right DagDB encoding is one node per
    // residue with `rank = maxRank - seqIndex`. Every contact (p, q) with
    // p < q becomes one directed edge (src = higher-rank residue p, dst =
    // lower-rank residue q). Undirected BFS recovers contact-graph
    // geodesic distance directly.

    /// Three-residue chain, single-node encoding. Contacts (0,1), (1,2).
    /// Undirected BFS from residue 0 gives {0:0, 1:1, 2:2} — matches the
    /// reference contact-graph geodesic.
    func testSingleNodeThreeResidueChain() throws {
        let eng = try makeEngine(side: 8)
        // maxRank = 3, so residue i gets rank (3 - i): res0→rank3 res1→rank2 res2→rank1
        setRank(eng, node: 0, rank: 3)
        setRank(eng, node: 1, rank: 2)
        setRank(eng, node: 2, rank: 1)
        // Contact (0, 1): edge res0 → res1 (rank 3 > rank 2 ✓)
        connect(eng, src: 0, dst: 1, slot: 0)
        // Contact (1, 2): edge res1 → res2 (rank 2 > rank 1 ✓)
        connect(eng, src: 1, dst: 2, slot: 0)

        let r = try DagDBBFS.bfsDepthsUndirected(engine: eng, nodeCount: eng.nodeCount, from: 0)
        XCTAssertEqual(r.depths[0], 0)
        XCTAssertEqual(r.depths[1], 1)
        XCTAssertEqual(r.depths[2], 2)
    }

    /// Four-residue clique under single-node encoding. Every pair is a contact.
    /// Residue graph is K_4 — every residue one step from every other.
    func testSingleNodeClique4() throws {
        let eng = try makeEngine(side: 8)
        // rank(i) = 4 - i: res0=4, res1=3, res2=2, res3=1
        for i in 0..<4 {
            setRank(eng, node: i, rank: UInt8(4 - i))
        }
        // All contacts (p, q) for p < q — src=p (higher rank), dst=q (lower rank)
        var slotForDst = [Int](repeating: 0, count: 4)
        for p in 0..<4 {
            for q in (p + 1)..<4 {
                connect(eng, src: p, dst: q, slot: slotForDst[q])
                slotForDst[q] += 1
            }
        }

        let r = try DagDBBFS.bfsDepthsUndirected(engine: eng, nodeCount: eng.nodeCount, from: 0)
        XCTAssertEqual(r.depths[0], 0)
        XCTAssertEqual(r.depths[1], 1)
        XCTAssertEqual(r.depths[2], 1)
        XCTAssertEqual(r.depths[3], 1)
    }

    // MARK: - Isolated + disconnected

    func testUnreachableNodeGetsMinusOne() throws {
        let eng = try makeEngine(side: 8)
        setRank(eng, node: 0, rank: 1)
        setRank(eng, node: 1, rank: 0)
        connect(eng, src: 0, dst: 1, slot: 0)
        // Node 5 has no edges — isolated.

        let r = try DagDBBFS.bfsDepthsUndirected(engine: eng, nodeCount: eng.nodeCount, from: 0)
        XCTAssertEqual(r.depths[0], 0)
        XCTAssertEqual(r.depths[1], 1)
        XCTAssertEqual(r.depths[5], -1)
    }
}
