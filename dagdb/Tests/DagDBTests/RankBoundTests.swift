import XCTest
@testable import DagDB

/// RANK BOUND gates — docs/contracts/RANK_BOUND_GATES_FROZEN.md
/// (AMENDMENT 1 replaces the original R1 with the reviewer's restore-path
/// fixture;
/// AMENDMENT 2 rules the remedy to be *compute*, not refuse.)
///
/// R1 · the restore path. A graph whose ranks run to 21, built in an
/// engine configured with `maxRank` 32, ticked to a fixed point, SAVEd,
/// then loaded into an engine configured with `maxRank` 8. The expected
/// fixed point is re-derived HERE from the LUT6 tables and the neighbour
/// slots — never by calling either tick.
///
/// The daemon-wire halves of the contract (R2's reply fields, R3's door,
/// R4's STATUS trio) live in `Tests/DagDBDaemonKitTests/RankBoundDaemonTests.swift`,
/// because `HandlerFixture` — which the contract names — belongs to that
/// target and this one cannot see it.
final class RankBoundTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-rankbound-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - Expectation computed outside the engine

    /// The unique fixed point of the combinational DAG, evaluated on the
    /// CPU in descending-rank order straight from the tables. Mirrors the
    /// kernel's own arithmetic: bit `d` of the LUT index is slot `d`'s
    /// neighbour being TRUE, an empty slot contributes 0, and the result
    /// is bit `index` of the 64-bit table.
    private func expectedFixedPoint(_ t: RankBoundFixture.Tables) -> [UInt8] {
        let n = RankBoundFixture.nodeCount
        var truth = [UInt8](repeating: 0, count: n)
        let order = (0..<n).sorted { t.rank[$0] > t.rank[$1] }
        for node in order {
            var bits: UInt8 = 0
            for d in 0..<6 {
                let src = t.neighbors[node * 6 + d]
                if src < 0 { continue }
                if truth[Int(src)] == 1 { bits |= UInt8(1 << d) }
            }
            let idx = UInt64(bits & 0x3F)
            truth[node] = UInt8((t.lut[node] >> idx) & 1)
        }
        return truth
    }

    private func mismatchReport(_ got: [UInt8], _ want: [UInt8],
                                _ rank: [UInt64]) -> String {
        var bad: [Int] = []
        for i in 0..<want.count where got[i] != want[i] { bad.append(i) }
        guard !bad.isEmpty else { return "no mismatch" }
        let ranks = Set(bad.map { Int(rank[$0]) }).sorted()
        let lo = ranks.first!, hi = ranks.last!
        let sample = bad.prefix(8).map {
            "node \($0) rank \(rank[$0]) got \(got[$0]) want \(want[$0])"
        }.joined(separator: "; ")
        return "\(bad.count) node(s) wrong, ranks \(lo)…\(hi) affected " +
               "(all ranks with a wrong node: \(ranks)); first: \(sample)"
    }

    // MARK: - The object itself

    /// The fixture must satisfy the contract's shape: every rank level
    /// 0…21 non-empty, and at least one edge crossing rank 8.
    func testR1_objectShape() throws {
        let t = RankBoundFixture.tables()
        for level in 0..<RankBoundFixture.levelCount {
            let count = t.rank.filter { $0 == UInt64(level) }.count
            XCTAssertGreaterThan(count, 0, "rank level \(level) is empty")
        }
        XCTAssertEqual(t.rank.max(), UInt64(RankBoundFixture.highestRank))

        // One edge whose source sits above rank 8 and whose destination
        // sits below it — the boundary is crossed, not landed on.
        var crossing = 0
        for dst in 0..<RankBoundFixture.nodeCount {
            for d in 0..<6 {
                let src = t.neighbors[dst * 6 + d]
                if src < 0 { continue }
                if t.rank[Int(src)] > 8 && t.rank[dst] < 8 { crossing += 1 }
            }
        }
        XCTAssertGreaterThan(crossing, 0, "no edge crosses rank 8")

        // Rank monotonicity along every edge, no self-loops, no duplicates.
        for dst in 0..<RankBoundFixture.nodeCount {
            var seen = Set<Int32>()
            for d in 0..<6 {
                let src = t.neighbors[dst * 6 + d]
                if src < 0 { continue }
                XCTAssertNotEqual(Int(src), dst, "self-loop at \(dst)")
                XCTAssertGreaterThan(t.rank[Int(src)], t.rank[dst],
                                     "edge \(src)→\(dst) is not rank-monotone")
                XCTAssertFalse(seen.contains(src), "duplicate edge into \(dst)")
                seen.insert(src)
            }
        }
    }

    // MARK: - R1 · the restore path

    func testR1_restorePathBothModesReachRecordedTruth() throws {
        let side = RankBoundFixture.side
        let n = RankBoundFixture.nodeCount

        // ── Under the large bound: build, tick both modes, record truth ──
        let gridA = try HexGrid(width: side, height: side)
        let stateA = DagDBState(width: side, height: side)
        let engA = try DagDBEngine(grid: gridA, state: stateA, maxRank: 32)
        let t = try RankBoundFixture.install(into: engA)
        let expected = expectedFixedPoint(t)

        RankBoundFixture.resetTruth(engA)
        for k in 0..<3 { engA.tick(tickNumber: UInt32(k)) }
        let rankTruthLarge = engA.readTruthStates()
        XCTAssertEqual(rankTruthLarge, expected,
                       "maxRank 32 rank mode: " +
                       mismatchReport(rankTruthLarge, expected, t.rank))

        RankBoundFixture.resetTruth(engA)
        for k in 0..<32 { engA.tickSync(tickNumber: UInt32(k)) }
        let syncTruthLarge = engA.readTruthStates()
        XCTAssertEqual(syncTruthLarge, expected,
                       "maxRank 32 sync mode: " +
                       mismatchReport(syncTruthLarge, expected, t.rank))

        // The recorded truth: what the graph is worth, taken under a bound
        // that covers it.
        let recorded = expected

        // Put the recorded truth in the buffer and SAVE it.
        let truthA = engA.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        for i in 0..<n { truthA[i] = recorded[i] }
        let path = tmpDir + "rankbound.dag"
        _ = try DagDBSnapshot.save(engine: engA, nodeCount: n,
                                   gridW: side, gridH: side,
                                   tickCount: 0, path: path)

        // ── Restore under the small bound ──
        let gridB = try HexGrid(width: side, height: side)
        let stateB = DagDBState(width: side, height: side)
        let engB = try DagDBEngine(grid: gridB, state: stateB, maxRank: 8)

        // 1. The load SUCCEEDS — a file written under any bound still loads.
        let result = try DagDBSnapshot.load(engine: engB, nodeCount: n,
                                            gridW: side, gridH: side, path: path)
        XCTAssertEqual(result.fileNodeCount, n)
        engB.markRankTopologyDirty()
        let restoredRanks = engB.readRanks()
        XCTAssertEqual(restoredRanks, t.rank, "ranks did not survive the restore")

        // 2. VALIDATE names every node at or above the running bound, with
        //    the count and the highest rank found.
        let violation = DagDBSnapshot.validate(engine: engB, nodeCount: n)
        XCTAssertEqual(
            violation,
            "rank bound: 42 node(s) at or above maxRank 8 " +
            "(first node 24 rank 8, highest rank 21)" +
            "; rank dispatch covers 81 of 81 node(s) over 22 rank level(s)")

        // 3a. Rank-mode TICK from the all-false start reaches the recorded
        //     truth, node for node, exact — including every node at rank ≥ 8.
        RankBoundFixture.resetTruth(engB)
        for k in 0..<3 { engB.tick(tickNumber: UInt32(k)) }
        let rankTruthSmall = engB.readTruthStates()
        XCTAssertEqual(rankTruthSmall, recorded,
                       "rank mode under maxRank 8: " +
                       mismatchReport(rankTruthSmall, recorded, t.rank))

        // 3b. Sync mode from the same start reaches the same recorded truth.
        RankBoundFixture.resetTruth(engB)
        for k in 0..<32 { engB.tickSync(tickNumber: UInt32(k)) }
        let syncTruthSmall = engB.readTruthStates()
        XCTAssertEqual(syncTruthSmall, recorded,
                       "sync mode under maxRank 8: " +
                       mismatchReport(syncTruthSmall, recorded, t.rank))

        // 4. A single rank-mode tick changes at least one node at rank ≥ 8 —
        //    the mechanism is exercised, not merely absent.
        RankBoundFixture.resetTruth(engB)
        let start = engB.readTruthStates()
        engB.tick(tickNumber: 0)
        let after = engB.readTruthStates()
        var changedAtOrAboveBound = 0
        for i in 0..<n where t.rank[i] >= 8 && after[i] != start[i] {
            changedAtOrAboveBound += 1
        }
        XCTAssertGreaterThan(changedAtOrAboveBound, 0,
                             "one rank-mode tick changed no node at rank >= 8")

        // 5. The bound itself is still what it was configured to be, and the
        //    engine reports the level count it actually dispatches.
        XCTAssertEqual(engB.maxRank, 8)
        XCTAssertEqual(engB.effectiveRankCount, 22)
        XCTAssertEqual(engB.highestRankPresent, 21)
    }

    // MARK: - R5 · no regression on shallow objects

    /// An object whose ranks are all below the bound must dispatch exactly
    /// the bound's levels and compute exactly as before.
    func testR5_shallowObjectKeepsTheConfiguredBound() throws {
        let grid = try HexGrid(width: 8, height: 8)
        let state = DagDBState(width: 8, height: 8)
        let eng = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        let n = eng.nodeCount
        let rank = eng.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let nb = eng.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        for i in 0..<(n * 6) { nb[i] = -1 }
        for i in 0..<n { rank[i] = UInt64(i % 4) }
        eng.markRankTopologyDirty()
        eng.tick(tickNumber: 0)
        XCTAssertEqual(eng.effectiveRankCount, 8, "shallow object widened the loop")
        XCTAssertEqual(eng.highestRankPresent, 3)
        XCTAssertNil(DagDBSnapshot.validate(engine: eng, nodeCount: n))
    }
}
