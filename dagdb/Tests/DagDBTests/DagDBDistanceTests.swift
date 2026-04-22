import XCTest
@testable import DagDB

final class DagDBDistanceTests: XCTestCase {

    private func makeEngine(side: Int) throws -> DagDBEngine {
        let grid = HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        return try DagDBEngine(grid: grid, state: state, maxRank: 8)
    }

    private func seed(_ engine: DagDBEngine) {
        let n = engine.nodeCount
        let rank  = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let truth = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let type  = engine.nodeTypeBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let low   = engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high  = engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let nb    = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)

        for i in 0..<n {
            rank[i] = 0; truth[i] = 0; type[i] = 0; low[i] = 0; high[i] = 0
            for d in 0..<6 { nb[i * 6 + d] = -1 }
        }
        // Leaves 1..6 at rank 2, type 1
        for i in 1...6 {
            rank[i] = 2; truth[i] = 1; type[i] = 1
            let lut = LUT6Preset.const1
            low[i]  = UInt32(lut & 0xFFFFFFFF)
            high[i] = UInt32((lut >> 32) & 0xFFFFFFFF)
        }
        // Aggregator 7 at rank 1, type 2
        rank[7] = 1; type[7] = 2
        let maj = LUT6Preset.majority6
        low[7]  = UInt32(maj & 0xFFFFFFFF)
        high[7] = UInt32((maj >> 32) & 0xFFFFFFFF)
        for d in 0..<6 { nb[7 * 6 + d] = Int32(1 + d) }
        // Root 8 at rank 0, type 3
        rank[8] = 0; type[8] = 3
        let idg = LUT6Preset.identity
        low[8]  = UInt32(idg & 0xFFFFFFFF)
        high[8] = UInt32((idg >> 32) & 0xFFFFFFFF)
        nb[8 * 6 + 0] = 7
    }

    // MARK: - Axioms each metric should obey

    func testIdenticalSubgraphsAreZeroDistance() throws {
        let eng = try makeEngine(side: 8)
        seed(eng)
        let s = DagSubgraph([1, 2, 3, 4, 5, 6, 7, 8])

        XCTAssertEqual(DagDBDistance.jaccardNodes(s, s), 0.0)
        XCTAssertEqual(DagDBDistance.jaccardEdges(engine: eng, nodeCount: eng.nodeCount, s, s), 0.0)
        XCTAssertEqual(DagDBDistance.rankProfileL1(engine: eng, nodeCount: eng.nodeCount, s, s), 0.0)
        XCTAssertEqual(DagDBDistance.rankProfileL2(engine: eng, nodeCount: eng.nodeCount, s, s), 0.0)
        XCTAssertEqual(DagDBDistance.nodeTypeProfileL1(engine: eng, nodeCount: eng.nodeCount, s, s), 0.0)
        XCTAssertEqual(DagDBDistance.boundedGED(engine: eng, nodeCount: eng.nodeCount, s, s), 0)
        XCTAssertEqual(DagDBDistance.weisfeilerLehmanL1(engine: eng, nodeCount: eng.nodeCount, s, s), 0.0)
    }

    func testDisjointSubgraphsHaveMaxJaccard() throws {
        let eng = try makeEngine(side: 8)
        seed(eng)
        let a = DagSubgraph([1, 2, 3])
        let b = DagSubgraph([4, 5, 6])

        XCTAssertEqual(DagDBDistance.jaccardNodes(a, b), 1.0)
    }

    func testSymmetry() throws {
        let eng = try makeEngine(side: 8)
        seed(eng)
        let a = DagSubgraph([1, 2, 3, 7])
        let b = DagSubgraph([4, 5, 6, 7, 8])

        let metrics: [DagDBDistance.Metric] = [.jaccardNodes, .jaccardEdges, .rankL1, .rankL2, .typeL1, .boundedGED, .wlL1]
        for m in metrics {
            let ab = DagDBDistance.compute(engine: eng, nodeCount: eng.nodeCount, metric: m, a, b)
            let ba = DagDBDistance.compute(engine: eng, nodeCount: eng.nodeCount, metric: m, b, a)
            XCTAssertEqual(ab, ba, accuracy: 1e-12, "\(m) is asymmetric")
        }
    }

    func testRankProfileDetectsShapeDifference() throws {
        let eng = try makeEngine(side: 8)
        seed(eng)

        // All leaves (rank 2 only) vs aggregator (rank 1) — different shapes.
        let leaves = DagSubgraph([1, 2, 3, 4, 5, 6])
        let top = DagSubgraph([7, 8])  // rank 1 + rank 0

        let dL1 = DagDBDistance.rankProfileL1(engine: eng, nodeCount: eng.nodeCount, leaves, top)
        XCTAssertGreaterThan(dL1, 0.5)

        // A subgraph of leaves has same shape as all leaves (modulo size) — lower distance.
        let someLeaves = DagSubgraph([1, 2, 3])
        let dSelfShape = DagDBDistance.rankProfileL1(engine: eng, nodeCount: eng.nodeCount, leaves, someLeaves)
        XCTAssertLessThan(dSelfShape, dL1)
    }

    func testJaccardEdgesDropsEdgesToOutside() throws {
        let eng = try makeEngine(side: 8)
        seed(eng)

        // Aggregator (7) alone — no induced edges (its inputs 1..6 are outside the set).
        let aggOnly = DagSubgraph([7])
        let aggPlusOneInput = DagSubgraph([7, 1])
        let aggPlusAllInputs = DagSubgraph([7, 1, 2, 3, 4, 5, 6])

        // aggOnly vs aggOnly: 0
        XCTAssertEqual(DagDBDistance.jaccardEdges(engine: eng, nodeCount: eng.nodeCount, aggOnly, aggOnly), 0.0)

        // aggOnly has 0 edges, aggPlusAllInputs has 6 edges — full symdiff.
        let d1 = DagDBDistance.jaccardEdges(engine: eng, nodeCount: eng.nodeCount, aggOnly, aggPlusAllInputs)
        XCTAssertEqual(d1, 1.0)

        // aggPlusOneInput (1 edge) ⊂ aggPlusAllInputs (6 edges) — 5 edges different out of 6 total.
        let d2 = DagDBDistance.jaccardEdges(engine: eng, nodeCount: eng.nodeCount, aggPlusOneInput, aggPlusAllInputs)
        XCTAssertEqual(d2, 5.0 / 6.0, accuracy: 1e-12)
    }

    func testBoundedGEDIsNonNegativeAndConsistent() throws {
        let eng = try makeEngine(side: 8)
        seed(eng)

        let a = DagSubgraph([1, 2, 3, 7])
        let b = DagSubgraph([4, 5, 6, 7])

        let ged = DagDBDistance.boundedGED(engine: eng, nodeCount: eng.nodeCount, a, b)
        XCTAssertGreaterThanOrEqual(ged, 0)
        // a and b share node 7 but differ in leaves 1..6 vs 4..6 — symdiff = 6 nodes (1,2,3,4,5,6).
        // Edges: both subgraphs have 0 induced edges (agg's inputs only partially covered in each).
        XCTAssertGreaterThanOrEqual(ged, 6)
    }

    func testWLPicksUpNeighborhoodStructure() throws {
        let eng = try makeEngine(side: 8)
        seed(eng)

        // Full tree has rich WL histogram.
        let full = DagSubgraph.all(engine: eng, nodeCount: eng.nodeCount)
        let fullHist = DagDBDistance.weisfeilerLehman1Histogram(
            engine: eng, nodeCount: eng.nodeCount, sub: full
        )
        XCTAssertGreaterThan(fullHist.count, 1)  // at least root + aggregator + leaves differ

        // Leaves-only subgraph has no induced edges → all leaves hash to same label.
        let leaves = DagSubgraph([1, 2, 3, 4, 5, 6])
        let leafHist = DagDBDistance.weisfeilerLehman1Histogram(
            engine: eng, nodeCount: eng.nodeCount, sub: leaves
        )
        XCTAssertEqual(leafHist.count, 1)
    }

    func testRankRangeConstructor() throws {
        let eng = try makeEngine(side: 8)
        seed(eng)

        let r2 = DagSubgraph.rankRange(engine: eng, nodeCount: eng.nodeCount, lo: 2, hi: 2)
        let expectedLeaves: Set<Int> = [1, 2, 3, 4, 5, 6]
        XCTAssertTrue(r2.nodeIds.isSuperset(of: expectedLeaves))
        // Other nodes in the grid at rank 0 don't count.
        for leaf in expectedLeaves { XCTAssertTrue(r2.nodeIds.contains(leaf)) }

        let r0 = DagSubgraph.rankRange(engine: eng, nodeCount: eng.nodeCount, lo: 0, hi: 0)
        XCTAssertTrue(r0.nodeIds.contains(8))  // root is at rank 0
    }

    func testDispatchCoversAllMetrics() throws {
        let eng = try makeEngine(side: 8)
        seed(eng)
        let a = DagSubgraph([1, 2, 3])
        let b = DagSubgraph([4, 5, 6])

        for m in [DagDBDistance.Metric.jaccardNodes, .jaccardEdges, .rankL1, .rankL2, .typeL1, .boundedGED, .wlL1, .spectralL2] {
            let v = DagDBDistance.compute(engine: eng, nodeCount: eng.nodeCount, metric: m, a, b)
            XCTAssertGreaterThanOrEqual(v, 0.0, "\(m) returned negative")
        }
    }

    // MARK: - Spectral L2

    /// Jacobi on a known 2x2 matrix: [[4,1],[1,4]] has eigenvalues {3, 5}.
    func testJacobiKnownEigenvalues() {
        let M = [4.0, 1.0, 1.0, 4.0]
        let eigs = DagDBDistance.eigenvaluesSymmetric(M, n: 2)
        XCTAssertEqual(eigs.count, 2)
        XCTAssertEqual(eigs[0], 3.0, accuracy: 1e-8)
        XCTAssertEqual(eigs[1], 5.0, accuracy: 1e-8)
    }

    /// Diagonal matrix: eigenvalues are the diagonal entries themselves.
    func testJacobiDiagonal() {
        // diag(7, 2, 5)
        let M = [
            7.0, 0.0, 0.0,
            0.0, 2.0, 0.0,
            0.0, 0.0, 5.0,
        ]
        let eigs = DagDBDistance.eigenvaluesSymmetric(M, n: 3)
        XCTAssertEqual(eigs.count, 3)
        XCTAssertEqual(eigs[0], 2.0, accuracy: 1e-8)
        XCTAssertEqual(eigs[1], 5.0, accuracy: 1e-8)
        XCTAssertEqual(eigs[2], 7.0, accuracy: 1e-8)
    }

    /// A connected graph's Laplacian has exactly one zero eigenvalue;
    /// the rest positive. For the 3-node path graph, L has spectrum {0, 1, 3}.
    func testLaplacianOfPathGraphHasExpectedSpectrum() {
        // 3-node path: 0 - 1 - 2. Degree (1, 2, 1). Adjacency symmetric.
        // Laplacian = [[1,-1,0],[-1,2,-1],[0,-1,1]]. Eigenvalues: 0, 1, 3.
        let L = [
             1.0, -1.0,  0.0,
            -1.0,  2.0, -1.0,
             0.0, -1.0,  1.0,
        ]
        let eigs = DagDBDistance.eigenvaluesSymmetric(L, n: 3)
        XCTAssertEqual(eigs.count, 3)
        XCTAssertEqual(eigs[0], 0.0, accuracy: 1e-8)
        XCTAssertEqual(eigs[1], 1.0, accuracy: 1e-8)
        XCTAssertEqual(eigs[2], 3.0, accuracy: 1e-8)
    }

    /// Identical subgraphs must give spectralL2 = 0.
    func testSpectralL2IdentityIsZero() throws {
        let eng = try makeEngine(side: 8)
        seed(eng)
        let s = DagSubgraph.all(engine: eng, nodeCount: eng.nodeCount)
        XCTAssertEqual(
            DagDBDistance.spectralL2(engine: eng, nodeCount: eng.nodeCount, s, s),
            0.0, accuracy: 1e-8
        )
    }

    /// Different-shaped subgraphs must have a non-zero spectral distance.
    func testSpectralL2DetectsStructureDifference() throws {
        let eng = try makeEngine(side: 8)
        seed(eng)

        // A single leaf (isolated) vs aggregator+all-leaves (a star graph).
        let leafAlone = DagSubgraph([1])
        let star = DagSubgraph([7, 1, 2, 3, 4, 5, 6])

        let d = DagDBDistance.spectralL2(
            engine: eng, nodeCount: eng.nodeCount, leafAlone, star)
        XCTAssertGreaterThan(d, 0.0)
    }

    /// Graph of just the aggregator + all six leaves is a 7-node star.
    /// Star K_{1,6} Laplacian has spectrum {0, 1, 1, 1, 1, 1, 7}. Sanity
    /// check spectralL2 to an isomorphic manual build.
    func testSpectralL2OnStar() throws {
        let eng = try makeEngine(side: 8)
        seed(eng)
        let star = DagSubgraph([7, 1, 2, 3, 4, 5, 6])
        let L = DagDBDistance.laplacian(engine: eng, nodeCount: eng.nodeCount, sub: star)
        let eigs = DagDBDistance.eigenvaluesSymmetric(L, n: 7)
        XCTAssertEqual(eigs.count, 7)
        XCTAssertEqual(eigs[0], 0.0, accuracy: 1e-8)  // connected → one zero
        XCTAssertEqual(eigs[6], 7.0, accuracy: 1e-8)  // largest = n for K_{1,n-1}
        // Interior eigenvalues all 1
        for i in 1...5 {
            XCTAssertEqual(eigs[i], 1.0, accuracy: 1e-8)
        }
    }
}
