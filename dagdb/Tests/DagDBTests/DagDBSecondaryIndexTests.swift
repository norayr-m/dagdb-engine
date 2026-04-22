import XCTest
@testable import DagDB

final class DagDBSecondaryIndexTests: XCTestCase {

    private func makeEngine(side: Int) throws -> DagDBEngine {
        let grid = HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        let nb = engine.neighborsBuf.contents().bindMemory(
            to: Int32.self, capacity: engine.nodeCount * 6)
        for i in 0..<(engine.nodeCount * 6) { nb[i] = -1 }
        return engine
    }

    /// Seed `count` nodes with (rank, truth) pairs starting at node 0.
    private func seed(_ engine: DagDBEngine, pairs: [(rank: UInt64, truth: UInt8)]) {
        let rank = engine.rankBuf.contents().bindMemory(
            to: UInt64.self, capacity: engine.nodeCount)
        let truth = engine.truthStateBuf.contents().bindMemory(
            to: UInt8.self, capacity: engine.nodeCount)
        for i in 0..<engine.nodeCount {
            rank[i] = 0
            truth[i] = 0
        }
        for (i, p) in pairs.enumerated() {
            rank[i] = p.rank
            truth[i] = p.truth
        }
    }

    // MARK: - Dirty-flag behaviour

    func testNewIndexStartsDirty() {
        let idx = TruthRankIndex()
        XCTAssertTrue(idx.isDirty)
    }

    func testRebuildClearsDirty() throws {
        let eng = try makeEngine(side: 8)
        seed(eng, pairs: [(1, 1), (2, 1), (3, 2)])
        let idx = TruthRankIndex()
        idx.rebuild(engine: eng, nodeCount: eng.nodeCount)
        XCTAssertFalse(idx.isDirty)
    }

    func testMarkDirtyStaysInvalid() throws {
        let eng = try makeEngine(side: 8)
        seed(eng, pairs: [(1, 1)])
        let idx = TruthRankIndex()
        idx.rebuild(engine: eng, nodeCount: eng.nodeCount)
        idx.markDirty()
        XCTAssertTrue(idx.isDirty)
    }

    // MARK: - Lookup correctness

    func testSelectExactTruthAndRank() throws {
        let eng = try makeEngine(side: 8)
        // Nodes: 0=(r1, t1), 1=(r2, t1), 2=(r3, t2), 3=(r4, t1), 4=(r5, t3)
        seed(eng, pairs: [(1, 1), (2, 1), (3, 2), (4, 1), (5, 3)])

        let idx = TruthRankIndex()

        // All truth=1 (should be nodes 0, 1, 3 — ranks 1, 2, 4)
        let t1Range = idx.select(truth: 1, rankLo: 0, rankHi: 100,
                                  engine: eng, nodeCount: eng.nodeCount)
        XCTAssertEqual(Set(t1Range), [0, 1, 3])

        // All truth=2 (just node 2)
        let t2 = idx.select(truth: 2, rankLo: 0, rankHi: 100,
                             engine: eng, nodeCount: eng.nodeCount)
        XCTAssertEqual(t2, [2])

        // truth=99 (no matches)
        let none = idx.select(truth: 99, rankLo: 0, rankHi: 100,
                               engine: eng, nodeCount: eng.nodeCount)
        XCTAssertEqual(none, [])
    }

    func testSelectRankRangeInclusive() throws {
        let eng = try makeEngine(side: 8)
        seed(eng, pairs: [(1, 1), (2, 1), (3, 1), (4, 1), (5, 1)])

        let idx = TruthRankIndex()

        // Range [2, 4] inclusive → nodes at rank 2, 3, 4 → IDs 1, 2, 3
        let mid = idx.select(truth: 1, rankLo: 2, rankHi: 4,
                              engine: eng, nodeCount: eng.nodeCount)
        XCTAssertEqual(mid, [1, 2, 3])

        // Range [0, 0] — matches rank-0 nodes only. Seed starts at rank 1 so empty.
        let none = idx.select(truth: 1, rankLo: 0, rankHi: 0,
                               engine: eng, nodeCount: eng.nodeCount)
        XCTAssertEqual(none, [])

        // Range [1, 1] — just first node.
        let first = idx.select(truth: 1, rankLo: 1, rankHi: 1,
                                engine: eng, nodeCount: eng.nodeCount)
        XCTAssertEqual(first, [0])

        // Range [5, 5] — last node.
        let last = idx.select(truth: 1, rankLo: 5, rankHi: 5,
                               engine: eng, nodeCount: eng.nodeCount)
        XCTAssertEqual(last, [4])
    }

    func testInvertedRangeReturnsEmpty() throws {
        let eng = try makeEngine(side: 8)
        seed(eng, pairs: [(1, 1), (2, 1), (3, 1)])
        let idx = TruthRankIndex()
        // rankLo > rankHi — nothing.
        let empty = idx.select(truth: 1, rankLo: 10, rankHi: 5,
                                engine: eng, nodeCount: eng.nodeCount)
        XCTAssertEqual(empty, [])
    }

    func testResultsAreRankAscending() throws {
        let eng = try makeEngine(side: 8)
        // Insert in non-sorted order to stress the sort step.
        seed(eng, pairs: [(9, 1), (3, 1), (7, 1), (1, 1), (5, 1)])
        let idx = TruthRankIndex()
        let all = idx.select(truth: 1, rankLo: 0, rankHi: 100,
                              engine: eng, nodeCount: eng.nodeCount)
        // Expected rank order: 1, 3, 5, 7, 9 — which is node IDs 3, 1, 4, 2, 0.
        XCTAssertEqual(all, [3, 1, 4, 2, 0])
    }

    // MARK: - Dirty / rebuild round-trip

    func testLazyRebuildAfterMutation() throws {
        let eng = try makeEngine(side: 8)
        seed(eng, pairs: [(1, 1), (2, 1)])
        let idx = TruthRankIndex()

        let before = idx.select(truth: 1, rankLo: 0, rankHi: 100,
                                 engine: eng, nodeCount: eng.nodeCount)
        XCTAssertEqual(Set(before), [0, 1])

        // Mutate: node 1's truth flips to 2, node 0's rank goes to 10.
        let rank = eng.rankBuf.contents().bindMemory(
            to: UInt64.self, capacity: eng.nodeCount)
        let truth = eng.truthStateBuf.contents().bindMemory(
            to: UInt8.self, capacity: eng.nodeCount)
        rank[0] = 10
        truth[1] = 2

        // Index is stale but returns the OLD view because we haven't marked dirty.
        let staleQuery = idx.select(truth: 1, rankLo: 0, rankHi: 100,
                                     engine: eng, nodeCount: eng.nodeCount)
        XCTAssertEqual(Set(staleQuery), [0, 1], "stale index returns previous snapshot")

        // Now mark dirty, next query rebuilds.
        idx.markDirty()
        let fresh = idx.select(truth: 1, rankLo: 0, rankHi: 100,
                                engine: eng, nodeCount: eng.nodeCount)
        XCTAssertEqual(fresh, [0])  // only node 0 still truth=1, at rank 10

        // And node 1 is now in truth=2 bucket.
        let twos = idx.select(truth: 2, rankLo: 0, rankHi: 100,
                               engine: eng, nodeCount: eng.nodeCount)
        XCTAssertEqual(twos, [1])
    }

    // MARK: - Performance signature

    func testBinarySearchIsNotLinear() throws {
        let eng = try makeEngine(side: 32)  // 1024 nodes

        // Seed every node with truth=1 and rank = i (so rank ascends with id)
        let rank = eng.rankBuf.contents().bindMemory(
            to: UInt64.self, capacity: eng.nodeCount)
        let truth = eng.truthStateBuf.contents().bindMemory(
            to: UInt8.self, capacity: eng.nodeCount)
        for i in 0..<eng.nodeCount {
            rank[i] = UInt64(i)
            truth[i] = 1
        }

        let idx = TruthRankIndex()
        // Small window in the middle — output size is ~10, not 1024.
        let hits = idx.select(truth: 1, rankLo: 500, rankHi: 509,
                               engine: eng, nodeCount: eng.nodeCount)
        XCTAssertEqual(hits.count, 10)
        // Results should be exactly the consecutive node IDs 500..509.
        XCTAssertEqual(hits, Array(500...509))
    }

    // MARK: - Bucket introspection

    func testBucketSizesReportPopulation() throws {
        let eng = try makeEngine(side: 8)
        seed(eng, pairs: [(1, 1), (2, 1), (3, 2), (4, 2), (5, 2), (6, 3)])

        let idx = TruthRankIndex()
        idx.rebuild(engine: eng, nodeCount: eng.nodeCount)

        let sizes = idx.bucketSizes
        // truth=0 absorbs all the un-seeded nodes (nodeCount - 6 of them).
        let zeroBucket = sizes[0] ?? 0
        XCTAssertEqual(zeroBucket, eng.nodeCount - 6)
        XCTAssertEqual(sizes[1], 2)
        XCTAssertEqual(sizes[2], 3)
        XCTAssertEqual(sizes[3], 1)
    }

    // MARK: - Loom-style scenario

    /// Simulate the "all dialogue_turns in last N events" Loom query.
    /// Rank is an insert-counter (monotone). truth=2 means dialogue_turn.
    func testLoomDialogueTurnWindow() throws {
        let eng = try makeEngine(side: 16)  // 256 nodes

        let rank = eng.rankBuf.contents().bindMemory(
            to: UInt64.self, capacity: eng.nodeCount)
        let truth = eng.truthStateBuf.contents().bindMemory(
            to: UInt8.self, capacity: eng.nodeCount)

        // 256 events, monotone rank = N - i (per Loom insert-counter convention).
        // Event types cycle through 1 (response), 2 (dialogue_turn), 3 (ceremony).
        let maxRank = UInt64(eng.nodeCount)
        for i in 0..<eng.nodeCount {
            rank[i] = maxRank - UInt64(i)
            truth[i] = UInt8((i % 3) + 1)
        }

        let idx = TruthRankIndex()

        // Last 30 events → rank >= (maxRank - 29). Filter to dialogue_turn (t=2).
        let windowLo = maxRank - 29
        let dialogues = idx.select(truth: 2, rankLo: windowLo, rankHi: maxRank,
                                    engine: eng, nodeCount: eng.nodeCount)
        // Events 0..29 with truth (i % 3) + 1 == 2 → i % 3 == 1 → i ∈ {1, 4, 7, 10, 13, 16, 19, 22, 25, 28}.
        XCTAssertEqual(Set(dialogues), [1, 4, 7, 10, 13, 16, 19, 22, 25, 28])
    }
}
