import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// DISTANCE spectralL2's Jacobi path is
/// admitted per side at min(the frozen worst case, G'), G' = 8.0*n^2 + 50*(1.273*n(n-1)/2 + 18.26*n*S) for
/// n <= 16,384, S the sum over the induced components of |C|(|C|-1)/2. In process; the 462 corpus lines, the
/// shape sweep and the control run over the wire.
final class EngineSPEC1Tests: XCTestCase {
    /// Input slots written as SET_NEIGHBORS_BULK does: (dst, src) puts src in dst's first free slot.
    func wire(_ f: HandlerFixture, _ edges: [(Int, Int)]) {
        let n = f.handler.engine.nodeCount
        let nb = f.handler.engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        for (dst, src) in edges {
            var d = 0
            while nb[dst * 6 + d] >= 0 { d += 1 }
            nb[dst * 6 + d] = Int32(src)
        }
    }

    func frozen(_ n: Double) -> Double { 1.11 * 50 * n * n * max(n - 1, 0) }
    func gPrime(_ n: Double, _ s: Double) -> Double { 8.0 * n * n + 50 * (1.273 * n * (n - 1) / 2 + 18.26 * n * s) }

    /// S from the union-find equals S from the components of the code's own Laplacian's off-diagonal pattern.
    func testComponentPairsMatchTheLaplacian() throws {
        let f = try HandlerFixture(side: 34)
        let N = f.handler.engine.nodeCount
        var x: UInt64 = 7
        func next() -> Int { x = x &* 6364136223846793005 &+ 1442695040888963407; return Int(x >> 33) }
        var edges: [(Int, Int)] = [(0, 1), (1, 2), (2, 3), (10, 11), (20, 20), (30, 31)]   // a 4-chain, a pair, a self slot
        for _ in 0..<400 { edges.append((next() % N, next() % N)) }
        var used = [Int: Int]()
        wire(f, edges.filter { used[$0.0, default: 0] += 1; return used[$0.0]! <= 6 })
        for trial in 0..<4 {
            let ids = Set((0..<N).filter { _ in next() % 4 != 0 || trial == 0 }).subtracting([31])
            let sub = DagSubgraph(ids)
            let L = DagDBDistance.laplacian(engine: f.handler.engine, nodeCount: N, sub: sub)
            let n = ids.count
            var parent = Array(0..<n)
            func find(_ v: Int) -> Int { var v = v; while parent[v] != v { v = parent[v] }; return v }
            for r in 0..<n { for c in (r + 1)..<n where L[r * n + c] != 0 { let a = find(r), b = find(c); if a != b { parent[a] = b } } }
            var size = [Int: Int](); for r in 0..<n { size[find(r), default: 0] += 1 }
            let s = size.values.reduce(0) { $0 + $1 * ($1 - 1) / 2 }
            XCTAssertGreaterThan(s, 6)
            XCTAssertEqual(DagDBCommandHandler.spectralComponentPairs(engine: f.handler.engine, nodeCount: N, sub: sub), s)
        }
        // The fixed part alone: a 4-chain (6) and a pair (1); the self slot and the edge to a non-member add nothing.
        let g = try HandlerFixture(side: 34)
        wire(g, [(0, 1), (1, 2), (2, 3), (10, 11), (20, 20), (30, 31)])
        let sub = DagSubgraph(Set(0..<1156).subtracting([31]))
        XCTAssertEqual(DagDBCommandHandler.spectralComponentPairs(engine: g.handler.engine, nodeCount: 1156, sub: sub), 7)
    }

    /// The side's unit: cheap without an edge; min(frozen, G') with one; a single component gives the frozen unit
    /// exactly; above n = 16,384 the frozen unit alone.
    func testSideUnit() throws {
        let f = try HandlerFixture(side: 34)
        let all = DagSubgraph(Set(0..<1156))
        let e = f.handler.engine
        XCTAssertEqual(DagDBCommandHandler.spectralSideNs(engine: e, nodeCount: 1156, sub: all), 8.0 * 1156 * 1156)
        wire(f, [(0, 1)])
        XCTAssertEqual(DagDBCommandHandler.spectralSideNs(engine: e, nodeCount: 1156, sub: all), gPrime(1156, 1))
        XCTAssertLessThan(gPrime(1156, 1), frozen(1156))
        // One component spanning all 1,156: G' is about 8.2x the frozen worst case, so the frozen unit, exactly.
        let h = try HandlerFixture(side: 34)
        wire(h, (1..<1156).map { ($0, $0 - 1) })
        XCTAssertEqual(DagDBCommandHandler.spectralComponentPairs(engine: h.handler.engine, nodeCount: 1156, sub: all), 1156 * 1155 / 2)
        XCTAssertGreaterThan(gPrime(1156, 1156 * 1155 / 2), frozen(1156))
        XCTAssertEqual(DagDBCommandHandler.spectralSideNs(engine: h.handler.engine, nodeCount: 1156, sub: all), frozen(1156))
        // n = 16,384 uses G'; n = 16,385 and above, the frozen worst case alone.
        let big = try HandlerFixture(side: 129)                    // 16,641 nodes
        wire(big, [(1, 0)])
        let at = DagSubgraph(Set(0..<16_384)), over = DagSubgraph(Set(0..<16_385))
        XCTAssertEqual(DagDBCommandHandler.spectralSideNs(engine: big.handler.engine, nodeCount: 16_641, sub: at), gPrime(16_384, 1))
        XCTAssertEqual(DagDBCommandHandler.spectralSideNs(engine: big.handler.engine, nodeCount: 16_641, sub: over), frozen(16_385))
    }

    /// Over the wire of the handler: one induced edge on 1,156 nodes is admitted and answers (an older build refused it);
    /// a single component spanning them is refused with the frozen number, as before.
    func testHandlerAdmitsAndRefuses() throws {
        let g = try HandlerFixture(side: 34)
        XCTAssertTrue(g.handler.handle("SET 1 RANK 1").hasPrefix("OK"))
        XCTAssertTrue(g.handler.handle("CONNECT FROM 1 TO 0").hasPrefix("OK"))
        XCTAssertTrue(g.handler.handle("DISTANCE spectralL2 0-1 5-5").hasPrefix("OK DISTANCE spectralL2 0-1 vs 5-5 value="))
        let h = try HandlerFixture(side: 34)
        wire(h, (1..<1156).map { ($0, $0 - 1) })
        XCTAssertEqual(h.handler.handle("DISTANCE spectralL2 0-0 5-5"),
                       "ERROR out_of_budget: DISTANCE needs 85662478441 spectralL2 work ns (per side: 8.0*n^2 without an"
                       + " induced edge; with one, 1.11*50*n^2*(n-1) worst-case Jacobi, or for n <= 16384 the smaller of"
                       + " that and 8.0*n^2 + 50*(1.273*n(n-1)/2 + 18.26*n*S), S = sum over the induced components of"
                       + " |C|(|C|-1)/2), the per-command work cap is 60000000000; nothing written")
    }
}
