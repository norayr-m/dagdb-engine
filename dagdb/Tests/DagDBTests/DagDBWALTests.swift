import XCTest
@testable import DagDB

final class DagDBWALTests: XCTestCase {

    private func makeEngine(side: Int) throws -> DagDBEngine {
        let grid = HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        return try DagDBEngine(grid: grid, state: state, maxRank: 8)
    }

    private func wipe(_ path: String) {
        _ = try? FileManager.default.removeItem(atPath: path)
    }

    func testAppendCreatesFileWithValidHeader() throws {
        let path = NSTemporaryDirectory() + "wal_create.log"
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
        let path = NSTemporaryDirectory() + "wal_truth.log"
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
        let path = NSTemporaryDirectory() + "wal_mixed.log"
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
        let path = NSTemporaryDirectory() + "wal_checkpoint.log"
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
        let path = NSTemporaryDirectory() + "wal_trunc.log"
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

    func testAppendingToExistingLogWorks() throws {
        let path = NSTemporaryDirectory() + "wal_reopen.log"
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
        let path = NSTemporaryDirectory() + "wal_reset.log"
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
        let path = NSTemporaryDirectory() + "wal_mismatch.log"
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
}
