import XCTest
@testable import DagDB

final class DagDBWALTests: XCTestCase {

    /// Per-test unique temp dir (Fable review T4 — fixed /tmp names race
    /// when princes run swift test concurrently in the shared dagdb dir).
    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-wal-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    private func makeEngine(side: Int) throws -> DagDBEngine {
        let grid = HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        return try DagDBEngine(grid: grid, state: state, maxRank: 8)
    }

    private func wipe(_ path: String) {
        _ = try? FileManager.default.removeItem(atPath: path)
    }

    func testAppendCreatesFileWithValidHeader() throws {
        let path = tmpDir! + "wal_create.log"
        wipe(path)

        let eng = try makeEngine(side: 8)
        let appender = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)

        // No records yet — file exists and has exactly the header bytes.
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int ?? 0
        XCTAssertEqual(size, DagDBWAL.headerSize)

        // Append one record — file grows.
        _ = try appender.setTruth(node: 3, value: 1)
        let size2 = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size2, DagDBWAL.headerSize)
    }

    func testReplayAppliesSetTruth() throws {
        let path = tmpDir! + "wal_truth.log"
        wipe(path)

        let eng = try makeEngine(side: 8)
        let truth = eng.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: eng.nodeCount)
        truth[5] = 0

        let appender = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
        _ = try appender.setTruth(node: 5, value: 1)
        _ = try appender.setTruth(node: 7, value: 2)
        // Simulate fresh engine on restart — replay.
        let engRestart = try makeEngine(side: 8)
        let replay = try DagDBWAL.replay(
            engine: engRestart, nodeCount: engRestart.nodeCount, path: path
        )
        XCTAssertEqual(replay.recordsApplied, 2)
        let t = engRestart.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: engRestart.nodeCount)
        XCTAssertEqual(t[5], 1)
        XCTAssertEqual(t[7], 2)
    }

    func testReplayAppliesSetRankAndSetLUT() throws {
        let path = tmpDir! + "wal_mixed.log"
        wipe(path)

        let eng = try makeEngine(side: 8)
        let appender = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
        _ = try appender.setRank(node: 2, value: 3)
        _ = try appender.setLUT(node: 4, lut: 0xDEADBEEFCAFEBABE)
        _ = try appender.setRank(node: 2, value: 4)  // overwrite previous
        _ = try appender.setLUT(node: 4, lut: 0x11223344AABBCCDD)  // overwrite previous

        let engRestart = try makeEngine(side: 8)
        let r = try DagDBWAL.replay(
            engine: engRestart, nodeCount: engRestart.nodeCount, path: path
        )
        XCTAssertEqual(r.recordsApplied, 4)

        let rank = engRestart.rankBuf.contents().bindMemory(to: UInt64.self, capacity: engRestart.nodeCount)
        let low  = engRestart.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: engRestart.nodeCount)
        let high = engRestart.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: engRestart.nodeCount)
        XCTAssertEqual(rank[2], 4)
        let replayed = UInt64(low[4]) | (UInt64(high[4]) << 32)
        XCTAssertEqual(replayed, 0x11223344AABBCCDD)
    }

    func testCheckpointDropsPriorRecords() throws {
        let path = tmpDir! + "wal_checkpoint.log"
        wipe(path)

        let eng = try makeEngine(side: 8)
        let appender = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)

        // Three records before checkpoint — should be skipped on replay.
        _ = try appender.setTruth(node: 1, value: 1)
        _ = try appender.setTruth(node: 2, value: 1)
        _ = try appender.setTruth(node: 3, value: 1)
        _ = try appender.checkpoint(epoch: 42)
        // Two records after checkpoint — should be applied.
        _ = try appender.setTruth(node: 4, value: 1)
        _ = try appender.setTruth(node: 5, value: 1)

        let engRestart = try makeEngine(side: 8)
        let r = try DagDBWAL.replay(
            engine: engRestart, nodeCount: engRestart.nodeCount, path: path
        )
        XCTAssertEqual(r.recordsAfterCheckpoint, 2)
        XCTAssertEqual(r.checkpointEpoch, 42)

        let t = engRestart.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: engRestart.nodeCount)
        XCTAssertEqual(t[1], 0)  // before checkpoint — skipped
        XCTAssertEqual(t[2], 0)
        XCTAssertEqual(t[3], 0)
        XCTAssertEqual(t[4], 1)  // after checkpoint — applied
        XCTAssertEqual(t[5], 1)
    }

    func testTruncatedTailRecordIsDropped() throws {
        let path = tmpDir! + "wal_trunc.log"
        wipe(path)

        let eng = try makeEngine(side: 8)
        let appender = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
        _ = try appender.setTruth(node: 1, value: 1)
        _ = try appender.setTruth(node: 2, value: 1)
        // Close by letting appender go out of scope.

        // Simulate a crash mid-append: truncate the file by 3 bytes so the
        // last record is partial.
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        try data.subdata(in: 0..<(data.count - 3))
            .write(to: URL(fileURLWithPath: path))

        let engRestart = try makeEngine(side: 8)
        let r = try DagDBWAL.replay(
            engine: engRestart, nodeCount: engRestart.nodeCount, path: path
        )
        XCTAssertEqual(r.recordsApplied, 1, "only the complete record applies")
        XCTAssertNotNil(r.truncatedAtOffset)

        let t = engRestart.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: engRestart.nodeCount)
        XCTAssertEqual(t[1], 1)
        XCTAssertEqual(t[2], 0, "truncated record does NOT apply")
    }

    /// G73 step-1 acceptance test — deterministic torn-tail fixture.
    /// Pins the CURRENT replay truth: a partially-written last record must be
    /// dropped, prior records replay exactly, and the truncation is surfaced at
    /// the byte offset where the torn record begins. No kill, no timing.
    ///
    /// Layout for setTruth records: header 16 B, each record = len(4)+op(1)+
    /// payload(5) = 10 B. So records begin at offsets 16, 26, 36.
    func testTornTailFixtureDeterministic() throws {
        let path = tmpDir! + "wal_torn_fixture.log"
        wipe(path)

        let eng = try makeEngine(side: 8)
        do {
            let a = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
            XCTAssertEqual(try a.setTruth(node: 1, value: 1), 10)  // rec @16
            XCTAssertEqual(try a.setTruth(node: 2, value: 1), 10)  // rec @26
            XCTAssertEqual(try a.setTruth(node: 3, value: 1), 10)  // rec @36
        }
        let fullSize = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int ?? 0
        XCTAssertEqual(fullSize, 46)

        // Case A: torn payload — keep 4 of the 3rd record's 10 bytes (file → 40).
        // Case B: torn length prefix — keep 2 bytes of the 3rd record (file → 38).
        for truncTo in [40, 38] {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            try data.subdata(in: 0..<truncTo).write(to: URL(fileURLWithPath: path + ".t"))

            let engR = try makeEngine(side: 8)
            let r = try DagDBWAL.replay(
                engine: engR, nodeCount: engR.nodeCount, path: path + ".t")
            XCTAssertEqual(r.recordsApplied, 2, "truncTo=\(truncTo): two whole records replay")
            XCTAssertEqual(r.truncatedAtOffset, 36,
                           "truncTo=\(truncTo): truncation surfaced at torn record start")
            let t = engR.truthStateBuf.contents()
                .bindMemory(to: UInt8.self, capacity: engR.nodeCount)
            XCTAssertEqual(t[1], 1)
            XCTAssertEqual(t[2], 1)
            XCTAssertEqual(t[3], 0, "torn record does NOT apply")
        }
    }

    func testAppendingToExistingLogWorks() throws {
        let path = tmpDir! + "wal_reopen.log"
        wipe(path)

        let eng = try makeEngine(side: 8)
        do {
            let a1 = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
            _ = try a1.setTruth(node: 1, value: 1)
        }
        // Reopen.
        let a2 = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
        _ = try a2.setTruth(node: 2, value: 1)

        let engRestart = try makeEngine(side: 8)
        let r = try DagDBWAL.replay(
            engine: engRestart, nodeCount: engRestart.nodeCount, path: path
        )
        XCTAssertEqual(r.recordsApplied, 2)
    }

    func testTruncateResetsToHeaderOnly() throws {
        let path = tmpDir! + "wal_reset.log"
        wipe(path)

        let eng = try makeEngine(side: 8)
        do {
            let a = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
            _ = try a.setTruth(node: 1, value: 1)
            _ = try a.setTruth(node: 2, value: 1)
        }
        try DagDBWAL.truncate(path: path, nodeCount: eng.nodeCount)

        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int ?? 0
        XCTAssertEqual(size, DagDBWAL.headerSize)

        // Replay — nothing to apply.
        let engRestart = try makeEngine(side: 8)
        let r = try DagDBWAL.replay(
            engine: engRestart, nodeCount: engRestart.nodeCount, path: path
        )
        XCTAssertEqual(r.recordsApplied, 0)
    }

    func testNodeCountMismatchFails() throws {
        let path = tmpDir! + "wal_mismatch.log"
        wipe(path)

        let eng8 = try makeEngine(side: 8)  // 64 nodes
        let a = try DagDBWAL.Appender(path: path, nodeCount: eng8.nodeCount)
        _ = try a.setTruth(node: 0, value: 1)

        // Try to open with a different nodeCount.
        XCTAssertThrowsError(
            try DagDBWAL.Appender(path: path, nodeCount: 999)
        )

        // Replay with mismatched nodeCount also fails.
        XCTAssertThrowsError(
            try DagDBWAL.replay(engine: eng8, nodeCount: 999, path: path)
        )
    }

    // MARK: - G73 group-commit fsync policy

    /// Default policy is `.everyRecord` and the on-disk bytes are identical to
    /// the pre-G73 per-record path: every record is durable on return
    /// (unsyncedCount stays 0), and replay reproduces state exactly.
    func testEveryRecordDefaultUnchanged() throws {
        let path = tmpDir! + "wal_default.log"
        wipe(path)
        let eng = try makeEngine(side: 8)
        let a = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
        XCTAssertEqual(a.policy, .everyRecord)
        for n in 0..<5 {
            _ = try a.setTruth(node: UInt32(n), value: 1)
            XCTAssertEqual(a.unsyncedCount, 0, "everyRecord leaves nothing unsynced")
        }
        let engR = try makeEngine(side: 8)
        let r = try DagDBWAL.replay(engine: engR, nodeCount: engR.nodeCount, path: path)
        XCTAssertEqual(r.recordsApplied, 5)
    }

    /// Group bound: in `.grouped(n, ms)` the count of records written but not
    /// yet fsync'd never exceeds n — it fsyncs and resets exactly on reaching n.
    func testGroupedBoundHonored() throws {
        let path = tmpDir! + "wal_grouped_bound.log"
        wipe(path)
        let eng = try makeEngine(side: 8)
        // Large ms so the timer never fires during the test — only the count
        // bound drives fsync here.
        let a = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount,
                                      policy: .grouped(n: 4, ms: 100_000))
        var maxSeen = 0
        for n in 0..<20 {
            _ = try a.setTruth(node: UInt32(n % 60), value: 1)
            let u = a.unsyncedCount
            maxSeen = max(maxSeen, u)
            XCTAssertLessThanOrEqual(u, 4, "unsynced must never exceed n=4")
        }
        // After 20 appends at n=4 the counter lands back on 0 (20 % 4 == 0).
        XCTAssertEqual(a.unsyncedCount, 0)
        XCTAssertGreaterThan(maxSeen, 0, "grouped mode actually deferred some fsyncs")
        // Records are write()-en immediately, so replay sees all 20 regardless.
        let engR = try makeEngine(side: 8)
        let r = try DagDBWAL.replay(engine: engR, nodeCount: engR.nodeCount, path: path)
        XCTAssertEqual(r.recordsApplied, 20)
    }

    /// A forced barrier flushes the deferred tail and resets the counter.
    func testBarrierFlushesDeferredTail() throws {
        let path = tmpDir! + "wal_barrier.log"
        wipe(path)
        let eng = try makeEngine(side: 8)
        let a = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount,
                                      policy: .grouped(n: 100, ms: 100_000))
        _ = try a.setTruth(node: 1, value: 1)
        _ = try a.setTruth(node: 2, value: 1)
        XCTAssertEqual(a.unsyncedCount, 2)
        a.barrier()
        XCTAssertEqual(a.unsyncedCount, 0, "barrier flushed the group")
    }

    /// The deferred-fsync timer fires on its own and flushes the group even
    /// when neither the count bound nor a barrier is hit.
    func testGroupedTimerFlushes() throws {
        let path = tmpDir! + "wal_timer.log"
        wipe(path)
        let eng = try makeEngine(side: 8)
        let a = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount,
                                      policy: .grouped(n: 100, ms: 30))
        _ = try a.setTruth(node: 1, value: 1)
        XCTAssertEqual(a.unsyncedCount, 1)
        // Wait past the timer deadline; poll so the test isn't wall-clock brittle.
        let deadline = Date().addingTimeInterval(2.0)
        while a.unsyncedCount != 0 && Date() < deadline {
            usleep(5_000)
        }
        XCTAssertEqual(a.unsyncedCount, 0, "deferred timer should have flushed")
    }

    /// A nonsensical group config (n<=0 or ms<=0) degrades to everyRecord so
    /// durability is never left unbounded.
    func testGroupedDegradesOnBadConfig() throws {
        let path = tmpDir! + "wal_badcfg.log"
        wipe(path)
        let eng = try makeEngine(side: 8)
        let a = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount,
                                      policy: .grouped(n: 0, ms: 0))
        XCTAssertEqual(a.policy, .everyRecord)
        _ = try a.setTruth(node: 1, value: 1)
        XCTAssertEqual(a.unsyncedCount, 0)
    }

    // MARK: - BACK_EDGE WAL records

    func testReplayAppliesConnectBack() throws {
        let path = tmpDir! + "wal_connect_back.log"
        wipe(path)

        let eng = try makeEngine(side: 8)
        let appender = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
        _ = try appender.connectBack(src: 5, dst: 2)
        _ = try appender.connectBack(src: 7, dst: 9)

        let engRestart = try makeEngine(side: 8)
        let r = try DagDBWAL.replay(engine: engRestart,
                                    nodeCount: engRestart.nodeCount, path: path)
        XCTAssertEqual(r.recordsApplied, 2)
        XCTAssertEqual(engRestart.backEdgeCount, 2)
        XCTAssertTrue(engRestart.isRegister(node: 2))
        XCTAssertTrue(engRestart.isRegister(node: 9))
        XCTAssertFalse(engRestart.isRegister(node: 5))
    }

    func testReplayAppliesClearBackEdges() throws {
        let path = tmpDir! + "wal_clear_back.log"
        wipe(path)

        let eng = try makeEngine(side: 8)
        let appender = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
        _ = try appender.connectBack(src: 5, dst: 2)
        _ = try appender.connectBack(src: 7, dst: 9)
        _ = try appender.clearBackEdges(dst: 2)

        let engRestart = try makeEngine(side: 8)
        let r = try DagDBWAL.replay(engine: engRestart,
                                    nodeCount: engRestart.nodeCount, path: path)
        XCTAssertEqual(r.recordsApplied, 3, "two creates + one clear all replayed")
        XCTAssertEqual(engRestart.backEdgeCount, 1, "clear removed one back-edge")
        XCTAssertFalse(engRestart.isRegister(node: 2),
                       "register flag dropped after clear")
        XCTAssertTrue(engRestart.isRegister(node: 9),
                      "the other back-edge survived the targeted clear")
    }

    func testReplayBackEdgeSurvivesCheckpointBoundary() throws {
        // CONNECT_BACK before a CHECKPOINT must NOT replay (it's already in
        // the snapshot). CONNECT_BACK after a CHECKPOINT must replay.
        let path = tmpDir! + "wal_back_checkpoint.log"
        wipe(path)

        let eng = try makeEngine(side: 8)
        let appender = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
        _ = try appender.connectBack(src: 1, dst: 4)  // pre-checkpoint
        _ = try appender.checkpoint(epoch: 7)
        _ = try appender.connectBack(src: 2, dst: 5)  // post-checkpoint

        let engRestart = try makeEngine(side: 8)
        let r = try DagDBWAL.replay(engine: engRestart,
                                    nodeCount: engRestart.nodeCount, path: path)
        // Only the post-checkpoint connectBack should replay (one record).
        XCTAssertEqual(r.recordsAfterCheckpoint, 1)
        XCTAssertEqual(engRestart.backEdgeCount, 1)
        XCTAssertTrue(engRestart.isRegister(node: 5))
        XCTAssertFalse(engRestart.isRegister(node: 4))
    }
}
