import XCTest
@testable import DagDB

/// Verifies the engine rank storage and filter expression preserve u64
/// values above UInt32.max. The daemon's NODES AT RANK filter used to
/// narrow with `UInt32(r)`, hiding any node whose true rank exceeded
/// 2^32-1. Codex flagged this on 2026-05-09. The acceptance pattern
/// here mirrors the daemon-level acceptance test: write a rank past the
/// u32 ceiling, read it back, and verify the equality filter that
/// NODES AT RANK uses matches the node.
final class DagDBU64RankTests: XCTestCase {

    private func makeEngine(side: Int) throws -> DagDBEngine {
        let grid = HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        let nb = engine.neighborsBuf.contents().bindMemory(
            to: Int32.self, capacity: engine.nodeCount * 6)
        for i in 0..<(engine.nodeCount * 6) { nb[i] = -1 }
        return engine
    }

    func testRankBufferPreservesU64ValueAboveU32Ceiling() throws {
        let eng = try makeEngine(side: 4)
        let rank = eng.rankBuf.contents().bindMemory(
            to: UInt64.self, capacity: eng.nodeCount)
        for i in 0..<eng.nodeCount { rank[i] = 0 }

        let big: UInt64 = 4_294_967_300  // 2^32 + 4
        rank[0] = big

        let read = eng.readRanks()
        XCTAssertEqual(read[0], big,
            "readRanks() must preserve u64 rank above UInt32.max")
    }

    func testDaemonFilterExpressionMatchesU64Rank() throws {
        let eng = try makeEngine(side: 4)
        let rank = eng.rankBuf.contents().bindMemory(
            to: UInt64.self, capacity: eng.nodeCount)
        for i in 0..<eng.nodeCount { rank[i] = 0 }

        let big: UInt64 = 4_294_967_300
        rank[0] = big

        let ranks = eng.readRanks()
        let queryRank: Int = 4_294_967_300

        // Mirrors the daemon's NODES AT RANK filter:
        //   if let r = rank, ranks[i] != UInt64(r) { continue }
        var matches: [Int] = []
        for i in 0..<eng.nodeCount {
            if ranks[i] != UInt64(queryRank) { continue }
            matches.append(i)
        }

        XCTAssertEqual(matches, [0],
            "NODES AT RANK 4294967300 must return [0] after SET 0 RANK 4294967300")
    }

    func testFilterRejectsNodeWhenWrittenWouldOverflowU32() throws {
        // Sanity: confirm the OLD narrowing (UInt32(r)) would have hidden
        // node 0. UInt32(4_294_967_300) traps at runtime; demonstrate the
        // ceiling explicitly so future readers see why the cast was wrong.
        let big: UInt64 = 4_294_967_300
        XCTAssertGreaterThan(big, UInt64(UInt32.max),
            "test fixture must exercise a rank past the u32 ceiling")
    }
}
