import XCTest
@testable import DagDB

/// C1 (b)–(e) and the C10 legacy-rank fixtures —
/// `docs/contracts/CORE_DURABILITY_GATES_FROZEN.md`.
///
/// Every log here is built byte by byte from the format documented at the top
/// of `DagDBWAL.swift`, never by today's appender: a fixture written by the
/// writer it is meant to police cannot fail.
final class CoreDurabilityWALTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-c1wal-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    private func makeEngine(side: Int) throws -> DagDBEngine {
        let grid = try HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        return try DagDBEngine(grid: grid, state: state, maxRank: 8)
    }

    // MARK: - byte-level fixture builders

    private func u32(_ v: UInt32) -> Data { var x = v; return Data(bytes: &x, count: 4) }
    private func u64(_ v: UInt64) -> Data { var x = v; return Data(bytes: &x, count: 8) }

    private func walHeader(version: UInt32, nodeCount: Int) -> Data {
        var d = Data()
        d.append(contentsOf: DagDBWAL.magic)
        d.append(u32(version))
        d.append(u32(UInt32(nodeCount)))
        d.append(u32(0))
        return d
    }

    /// length u32 (payload only) + opcode u8 + payload.
    private func rec(_ opcode: UInt8, _ payload: Data) -> Data {
        var d = u32(UInt32(payload.count))
        d.append(opcode)
        d.append(payload)
        return d
    }

    private func write(_ data: Data, _ name: String) throws -> String {
        let p = tmpDir! + name
        try data.write(to: URL(fileURLWithPath: p))
        return p
    }

    // MARK: - C1b · the replay says what it skipped

    func testReplayReportsSkippedRecordsWithAReasonHistogram() throws {
        let eng = try makeEngine(side: 8)
        let n = eng.nodeCount

        var f = walHeader(version: DagDBWAL.version, nodeCount: n)
        // Two bad lengths: SET_TRUTH needs 5 payload bytes, these carry 4 and 6.
        f.append(rec(0x01, u32(1)))
        f.append(rec(0x01, u32(2) + Data([1, 0])))
        // Three out-of-range node indices.
        f.append(rec(0x01, u32(UInt32(n)) + Data([1])))
        f.append(rec(0x01, u32(UInt32(n + 5)) + Data([1])))
        f.append(rec(0x02, u32(UInt32(n)) + u64(3)))
        // One unknown opcode.
        f.append(rec(0x7F, Data([9, 9, 9])))
        // One good record, so "applied" stays honest too.
        f.append(rec(0x01, u32(4) + Data([1])))
        let path = try write(f, "skips.log")

        let r = try DagDBWAL.replay(engine: eng, nodeCount: n, path: path)
        XCTAssertEqual(r.recordsApplied, 1)
        XCTAssertEqual(r.recordsSkipped, 6)
        XCTAssertEqual(r.skipReasons.badLength, 2)
        XCTAssertEqual(r.skipReasons.outOfRangeIndex, 3)
        XCTAssertEqual(r.skipReasons.unknownOpcode, 1)
        XCTAssertEqual(r.skipReasons.total, r.recordsSkipped)
        XCTAssertEqual(r.skipReasons.line,
                       "bad_length=2 out_of_range=3 unknown_opcode=1")
    }

    func testACleanLogReportsZeroSkipped() throws {
        let path = tmpDir! + "clean.log"
        let eng = try makeEngine(side: 8)
        do {
            let a = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
            _ = try a.setTruth(node: 1, value: 1)
            _ = try a.setRank(node: 2, value: 3)
        }
        let r = try DagDBWAL.replay(engine: eng, nodeCount: eng.nodeCount, path: path)
        XCTAssertEqual(r.recordsApplied, 2)
        XCTAssertEqual(r.recordsSkipped, 0)
        XCTAssertEqual(r.fileVersion, DagDBWAL.versionV2)
    }

    // MARK: - C1c · SET_RANK widths are a version question

    func testLegacyRankWidthsRejectedUnderVersionTwo() throws {
        let eng = try makeEngine(side: 8)
        let n = eng.nodeCount
        var f = walHeader(version: DagDBWAL.versionV2, nodeCount: n)
        // A 12-byte SET_RANK torn down to 8 bytes, and one torn to 5.
        f.append(rec(0x02, u32(3) + u32(7)))           // 8-byte payload
        f.append(rec(0x02, u32(4) + Data([9])))        // 5-byte payload
        f.append(rec(0x02, u32(5) + u64(11)))          // the legal 12-byte one
        let path = try write(f, "rank_v2.log")

        let r = try DagDBWAL.replay(engine: eng, nodeCount: n, path: path)
        let rank = eng.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        XCTAssertEqual(r.recordsApplied, 1, "only the 12-byte record is a rank write")
        XCTAssertEqual(r.recordsSkipped, 2)
        XCTAssertEqual(r.skipReasons.badLength, 2)
        XCTAssertEqual(rank[3], 0, "torn 8-byte record must not be applied")
        XCTAssertEqual(rank[4], 0, "torn 5-byte record must not be applied")
        XCTAssertEqual(rank[5], 11)
    }

    /// C10 · the legacy widths still replay where they are genuine: a v1 log.
    func testLegacyRankWidthsReplayUnderVersionOne() throws {
        let eng = try makeEngine(side: 8)
        let n = eng.nodeCount
        var f = walHeader(version: DagDBWAL.versionV1, nodeCount: n)
        f.append(rec(0x02, u32(3) + u32(7)))       // v2-era payload: u32 rank
        f.append(rec(0x02, u32(4) + Data([9])))    // v1-era payload: u8 rank
        f.append(rec(0x02, u32(5) + u64(11)))      // current payload: u64 rank
        let path = try write(f, "rank_v1.log")

        let r = try DagDBWAL.replay(engine: eng, nodeCount: n, path: path)
        let rank = eng.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        XCTAssertEqual(r.fileVersion, DagDBWAL.versionV1)
        XCTAssertEqual(r.recordsApplied, 3)
        XCTAssertEqual(r.recordsSkipped, 0)
        XCTAssertEqual(rank[3], 7)
        XCTAssertEqual(rank[4], 9)
        XCTAssertEqual(rank[5], 11)
    }

    // MARK: - C1d · the checkpoint payload is exactly 8 bytes

    func testTornCheckpointIsCountedAndDoesNotMoveTheReplayWindow() throws {
        let eng = try makeEngine(side: 8)
        let n = eng.nodeCount
        var f = walHeader(version: DagDBWAL.version, nodeCount: n)
        f.append(rec(0xF0, u32(9)))                  // 4-byte checkpoint: torn
        f.append(rec(0x01, u32(6) + Data([1])))      // the record after it
        let path = try write(f, "torn_ckpt.log")

        let r = try DagDBWAL.replay(engine: eng, nodeCount: n, path: path)
        let truth = eng.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        XCTAssertEqual(truth[6], 1,
                       "a torn checkpoint must not push the window past the next record")
        XCTAssertEqual(r.recordsApplied, 1)
        XCTAssertEqual(r.recordsSkipped, 1)
        XCTAssertEqual(r.skipReasons.badLength, 1)
        XCTAssertEqual(r.checkpointEpoch, 0, "a torn checkpoint is not a boundary")
    }

    func testWellFormedCheckpointStillBoundsTheWindow() throws {
        let eng = try makeEngine(side: 8)
        let n = eng.nodeCount
        var f = walHeader(version: DagDBWAL.version, nodeCount: n)
        f.append(rec(0x01, u32(1) + Data([1])))      // before — must not apply
        f.append(rec(0xF0, u64(42)))
        f.append(rec(0x01, u32(2) + Data([1])))      // after — must apply
        let path = try write(f, "good_ckpt.log")

        let r = try DagDBWAL.replay(engine: eng, nodeCount: n, path: path)
        let truth = eng.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        XCTAssertEqual(r.checkpointEpoch, 42)
        XCTAssertEqual(r.recordsAfterCheckpoint, 1)
        XCTAssertEqual(truth[1], 0)
        XCTAssertEqual(truth[2], 1)
        XCTAssertEqual(r.recordsSkipped, 0)
    }

    // MARK: - C1a · version gate

    func testVersionAboveTwoIsRefusedByName() throws {
        let eng = try makeEngine(side: 8)
        let n = eng.nodeCount
        let path = try write(walHeader(version: 3, nodeCount: n), "v3.log")
        XCTAssertThrowsError(try DagDBWAL.replay(engine: eng, nodeCount: n, path: path)) { err in
            guard let e = err as? DagDBWAL.WALError, case .unsupportedVersion(let v) = e else {
                return XCTFail("expected unsupportedVersion, got \(err)")
            }
            XCTAssertEqual(v, 3)
        }
        XCTAssertThrowsError(try DagDBWAL.Appender(path: path, nodeCount: n))
    }

    func testVersionOneLogStillReplays() throws {
        let eng = try makeEngine(side: 8)
        let n = eng.nodeCount
        var f = walHeader(version: DagDBWAL.versionV1, nodeCount: n)
        f.append(rec(0x01, u32(3) + Data([1])))
        f.append(rec(0x03, u32(4) + u64(0xDEAD_BEEF_CAFE_BABE)))
        f.append(rec(0x10, u32(5) + u32(6)))       // CONNECT_BACK
        let path = try write(f, "v1_replay.log")

        let r = try DagDBWAL.replay(engine: eng, nodeCount: n, path: path)
        XCTAssertEqual(r.recordsApplied, 3)
        XCTAssertEqual(r.recordsSkipped, 0)
        XCTAssertTrue(eng.isRegister(node: 6))
    }

    /// A v2-only opcode is refused by name rather than written into a log
    /// whose header promises a v1 reader it will not see one.
    func testVersionTwoOpcodeRefusedOnAVersionOneLog() throws {
        let eng = try makeEngine(side: 8)
        let n = eng.nodeCount
        let path = try write(walHeader(version: DagDBWAL.versionV1, nodeCount: n), "v1_append.log")
        let a = try DagDBWAL.Appender(path: path, nodeCount: n)
        XCTAssertEqual(a.fileVersion, DagDBWAL.versionV1)
        _ = try a.setTruth(node: 1, value: 1)       // v1 opcode: fine
        XCTAssertThrowsError(try a.connect(dst: 2, slot: 0, src: 3)) { err in
            guard let e = err as? DagDBWAL.WALError,
                  case .opcodeNeedsVersion(let op, let needs, let have) = e else {
                return XCTFail("expected opcodeNeedsVersion, got \(err)")
            }
            XCTAssertEqual(op, 0x12)
            XCTAssertEqual(needs, 2)
            XCTAssertEqual(have, 1)
        }
    }

    // MARK: - C1e · truncate refuses while an appender is open

    func testTruncateRefusesWhileAnAppenderIsOpen() throws {
        let path = tmpDir! + "trunc_guard.log"
        let eng = try makeEngine(side: 8)
        var a: DagDBWAL.Appender? = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
        _ = try a!.setTruth(node: 1, value: 1)

        XCTAssertTrue(DagDBWAL.hasOpenAppender(path: path))
        XCTAssertThrowsError(try DagDBWAL.truncate(path: path, nodeCount: eng.nodeCount)) { err in
            guard let e = err as? DagDBWAL.WALError, case .appenderOpen(let p) = e else {
                return XCTFail("expected appenderOpen, got \(err)")
            }
            XCTAssertEqual((p as NSString).lastPathComponent, "trunc_guard.log")
        }

        // The record survives the refused truncate — this is the gate from
        // audit A finding 33: append after a truncate, then replay.
        _ = try a!.setTruth(node: 2, value: 1)
        a = nil                                    // appender released

        XCTAssertFalse(DagDBWAL.hasOpenAppender(path: path))
        let engR = try makeEngine(side: 8)
        let r = try DagDBWAL.replay(engine: engR, nodeCount: engR.nodeCount, path: path)
        XCTAssertEqual(r.recordsApplied, 2, "no record was lost to an unlinked inode")

        // With the appender gone, truncate works as before.
        try DagDBWAL.truncate(path: path, nodeCount: engR.nodeCount)
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int ?? 0
        XCTAssertEqual(size, DagDBWAL.headerSize)
    }
}
