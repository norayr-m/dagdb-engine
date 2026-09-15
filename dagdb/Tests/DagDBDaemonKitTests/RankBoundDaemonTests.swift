import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// RANK BOUND gates on the wire — docs/contracts/RANK_BOUND_GATES_FROZEN.md.
///
/// R2 · the operation says how much it did (`nodes_computed`, and
/// `ranks=`/`bound=` when the levels dispatched exceed the configured
/// bound). R3 · the door (a rank at or above `nodeCount` is refused, a
/// rank in `[maxRank, nodeCount)` is accepted and computed). R4 · STATUS
/// carries `maxRank=` `ranks=` `rank_max=` so a stale bound is catchable
/// without ticking.
///
/// These live here rather than in `Tests/DagDBTests/RankBoundTests.swift`
/// because the contract names `HandlerFixture`, which belongs to this
/// target. The engine-level R1 control is in that file.
final class RankBoundDaemonTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-rankbound-wire-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    /// Save the deep-rank object from a `maxRank` 32 engine, then restore it
    /// into the fixture's `maxRank` 8 handler — the reviewer's restore path.
    private func restoredFixture() throws -> (HandlerFixture, RankBoundFixture.Tables) {
        let side = RankBoundFixture.side
        let n = RankBoundFixture.nodeCount

        let gridA = try HexGrid(width: side, height: side)
        let stateA = DagDBState(width: side, height: side)
        let engA = try DagDBEngine(grid: gridA, state: stateA, maxRank: 32)
        let t = try RankBoundFixture.install(into: engA)
        engA.tick(tickNumber: 0)

        let path = tmpDir + "restore.dag"
        _ = try DagDBSnapshot.save(engine: engA, nodeCount: n,
                                   gridW: side, gridH: side,
                                   tickCount: 0, path: path)

        let f = try HandlerFixture(side: side)
        XCTAssertEqual(f.handler.engine.nodeCount, n)
        XCTAssertEqual(f.handler.maxRank, 8)
        _ = try DagDBSnapshot.load(engine: f.handler.engine, nodeCount: n,
                                   gridW: side, gridH: side, path: path)
        f.handler.engine.markRankTopologyDirty()
        RankBoundFixture.resetTruth(f.handler.engine)
        return (f, t)
    }

    // MARK: - R2 · the reply says how much it did

    func testR2_firstRankTickAfterRestoreAnnouncesTheStaleBound() throws {
        let (f, _) = try restoredFixture()
        let n = RankBoundFixture.nodeCount

        let reply = f.handler.handle("TICK 1")
        XCTAssertTrue(reply.hasPrefix("OK TICK 1 elapsed="), reply)
        XCTAssertTrue(reply.hasSuffix(" nodes_computed=\(n) ranks=22 bound=8"), reply)
        XCTAssertTrue(reply.contains("nodes_computed=81"), reply)

        // The same news on the sync verb, in the vocabulary that is true
        // there: sync does not dispatch by rank, so it reports the graph's
        // highest rank against the bound rather than "levels dispatched".
        let syncReply = f.handler.handle("TICK_SYNC 1")
        XCTAssertTrue(syncReply.hasPrefix("OK TICK_SYNC 1 elapsed="), syncReply)
        XCTAssertTrue(syncReply.hasSuffix(" nodes_computed=\(n) rank_max=21 bound=8"), syncReply)
        XCTAssertFalse(syncReply.contains("ranks="), syncReply)
    }

    /// A graph that fits inside the bound gets `nodes_computed` and nothing
    /// else — `ranks=`/`bound=` appear only when there is something to say.
    func testR2_nodesComputedAlwaysRanksOnlyWhenOverTheBound() throws {
        let f = try HandlerFixture(side: 9)   // 81 nodes, all rank 0, maxRank 8
        let reply = f.handler.handle("TICK 1")
        XCTAssertEqual(reply.hasSuffix(" nodes_computed=81"), true, reply)
        XCTAssertFalse(reply.contains("ranks="), reply)
        XCTAssertFalse(reply.contains("bound="), reply)

        // `nodes_computed` counts the whole command, not one tick.
        let three = f.handler.handle("TICK 3")
        XCTAssertTrue(three.hasSuffix(" nodes_computed=243"), three)
    }

    // MARK: - R4 · STATUS makes a stale bound catchable without ticking

    func testR4_statusCarriesBoundLevelsAndHighestRank() throws {
        let (f, _) = try restoredFixture()
        let status = f.handler.handle("STATUS")
        XCTAssertTrue(status.contains("maxRank=8 ranks=22 rank_max=21"), status)
        // Every field STATUS printed before is still printed.
        for field in ["nodes=81", "ticks=0", "gpu=", "grid=9x9",
                      "twin_open=0", "tiled_open=0"] {
            XCTAssertTrue(status.contains(field), "STATUS lost \(field): \(status)")
        }
    }

    func testR4_validateNamesTheNodesAtOrAboveTheBound() throws {
        let (f, _) = try restoredFixture()
        let reply = f.handler.handle("VALIDATE")
        XCTAssertEqual(
            reply,
            "FAIL VALIDATE rank bound: 42 node(s) at or above maxRank 8 " +
            "(first node 24 rank 8, highest rank 21)" +
            "; rank dispatch covers 81 of 81 node(s) over 22 rank level(s)")
    }

    // MARK: - R3 · the door

    func testR3_setRankRefusesAtOrAboveNodeCountAndAcceptsBelowIt() throws {
        let f = try HandlerFixture(side: 9)   // 81 nodes, maxRank 8
        let n = 81
        let eng = f.handler.engine
        let rank = eng.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let low = eng.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high = eng.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)

        // Node 3: no inputs (the fixture wipes every slot to -1), CONST1.
        low[3] = 0xFFFF_FFFF; high[3] = 0xFFFF_FFFF

        // A rank in [maxRank, nodeCount) is ACCEPTED — and computed.
        XCTAssertEqual(f.handler.handle("SET 3 RANK 20"), "OK SET node=3 rank=20")
        XCTAssertEqual(rank[3], 20)
        let tickReply = f.handler.handle("TICK 1")
        XCTAssertTrue(tickReply.hasSuffix(" nodes_computed=81 ranks=21 bound=8"), tickReply)
        let truth = eng.readTruthStates()
        XCTAssertEqual(truth[3], 1, "a node at rank 20 under bound 8 was not computed")

        // A rank at nodeCount is refused, and the buffer is unchanged.
        XCTAssertEqual(f.handler.handle("SET 3 RANK 81"),
                       "ERROR out_of_range: rank 81 not in 0..<81")
        XCTAssertEqual(rank[3], 20, "a refused SET RANK still wrote")

        // And above it.
        XCTAssertEqual(f.handler.handle("SET 3 RANK 4096"),
                       "ERROR out_of_range: rank 4096 not in 0..<81")
        XCTAssertEqual(rank[3], 20)

        // The last legal value is accepted.
        XCTAssertEqual(f.handler.handle("SET 3 RANK 80"), "OK SET node=3 rank=80")
        XCTAssertEqual(rank[3], 80)
    }

    func testR3_bulkRankCommitRefusesWholeVectorNamingFirstOffender() throws {
        let f = try HandlerFixture(side: 9)
        let n = 81
        let eng = f.handler.engine
        let rank = eng.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        for i in 0..<n { rank[i] = UInt64(i % 3) }
        let before = (0..<n).map { rank[$0] }

        // A vector that is legal except for two entries; the refusal names
        // the FIRST, and not one rank moves.
        let src = f.shm.advanced(by: 8).bindMemory(to: UInt64.self, capacity: n)
        for i in 0..<n { src[i] = UInt64(i % 7) }
        src[7] = 81
        src[40] = 9_999

        XCTAssertEqual(f.handler.handle("SET_RANKS_BULK"),
                       "ERROR out_of_range: node 7 rank 81 not in 0..<81")
        let after = (0..<n).map { rank[$0] }
        XCTAssertEqual(after, before, "a refused bulk commit still wrote")

        // Made legal, the same vector commits — including ranks above the
        // configured bound of 8.
        src[7] = 80
        src[40] = 9
        // The disclosure suffix is appended at gate D6 (audit B finding 15):
        // per-insert rank monotonicity is skipped for speed and the reply
        // now says so, and says where to re-check.
        XCTAssertEqual(f.handler.handle("SET_RANKS_BULK"),
                       "OK SET_RANKS_BULK nodes=81 validation=skipped"
                       + " skipped=rank_monotonicity recheck=VALIDATE")
        XCTAssertEqual(rank[7], 80)
        XCTAssertEqual(rank[40], 9)
    }
}
