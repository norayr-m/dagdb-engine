import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// The binary-only fast path through the daemon's verbs.
///
/// TICK and TICK_SYNC take the binary-only kernel iff no node is non-binary:
/// left on the first `SET <id> MODE TTABLE|TTHRESH`, re-entered when the count
/// returns to 0 through `SET <id> MODE BINARY`, `SET_MODES_BULK` or `LOAD`.
/// Every verb the daemon runs — the reads included (GRAPH INFO, result rows,
/// SET TRUTH's and CONNECT BACK's checks, COMPOSE) — keeps the count by the
/// writes alone (the raw lane is never handed out), and the session's WAL
/// replays into a fresh engine with the same exact count.
final class TernaryR8dDaemonFastPathTests: XCTestCase {

    private var fixture: HandlerFixture!
    private var tmpDir: String!
    private var walPath: String!
    private let side = 8

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "tern-r8d-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        walPath = tmpDir + "r8d.wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: side * side)
        fixture = try HandlerFixture(side: side, wal: wal, maxRank: 8)
    }

    override func tearDownWithError() throws {
        fixture = nil
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    @discardableResult
    private func ok(_ line: String, file: StaticString = #filePath, line ln: UInt = #line) -> String {
        let r = fixture.handler.handle(line)
        XCTAssertTrue(r.hasPrefix("OK"), "\(line) -> \(r)", file: file, line: ln)
        return r
    }

    /// The kernel TICK and TICK_SYNC ran, the count and its scan.
    private func assertKernel(_ nonBinary: Int, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let e = fixture.handler.engine
        XCTAssertEqual(e.ternaryNodeCount(), nonBinary, "\(what): lane scan", file: file, line: line)
        XCTAssertEqual(e.nonBinaryNodeCount, nonBinary, "\(what): engine count", file: file, line: line)
        let want: DagDBEngine.TickKernel = nonBinary == 0 ? .binaryOnly : .general
        ok("TICK 1", file: file, line: line)
        XCTAssertEqual(e.lastTickKernel, want, "\(what): TICK", file: file, line: line)
        ok("TICK_SYNC 1", file: file, line: line)
        XCTAssertEqual(e.lastTickKernel, want, "\(what): TICK_SYNC", file: file, line: line)
        XCTAssertTrue(e.nonBinaryCountTracked, "\(what): a verb handed the raw mode lane out", file: file, line: line)
    }

    private func modesBulk(_ modes: [UInt8]) {
        let p = fixture.shm.advanced(by: 8).bindMemory(to: UInt8.self, capacity: modes.count)
        for i in 0..<modes.count { p[i] = modes[i] }
        shm1Header(fixture.shm, count: modes.count, verb: .setModesBulk)
        ok("SET_MODES_BULK")
    }

    func testFastPathFollowsEveryModeVerbAndLoad() throws {
        let n = side * side
        let e = fixture.handler.engine
        // Ranks i % 4 and one slot each, so the ticks have work.
        let rk = fixture.shm.advanced(by: 8).bindMemory(to: UInt64.self, capacity: n)
        for i in 0..<n { rk[i] = UInt64(i % 4) }
        shm1Header(fixture.shm, count: n, verb: .setRanksBulk)
        ok("SET_RANKS_BULK")
        for i in 0..<(n - 1) where i % 4 < 3 { ok("CONNECT FROM \(i + 1) TO \(i)") }
        ok("TTABLE PRESET 0 TSUM 2")
        assertKernel(0, "binary graph")

        // Left on the first non-binary node; re-entered via SET MODE BINARY.
        ok("SET 5 MODE TTABLE")
        assertKernel(1, "SET 5 MODE TTABLE")
        ok("SET 9 MODE TTHRESH NOSKIP")
        assertKernel(2, "SET 9 MODE TTHRESH NOSKIP")
        ok("SET 9 MODE TTABLE")
        assertKernel(2, "SET 9 MODE TTABLE (kind changed)")
        ok("SET 5 MODE BINARY")
        assertKernel(1, "SET 5 MODE BINARY")
        ok("SET 9 MODE BINARY")
        assertKernel(0, "SET 9 MODE BINARY")

        // Reads that consult the lane: none of them may untrack the count.
        ok("SET 12 MODE TTHRESH")
        ok("GRAPH INFO")
        ok("NODES AT RANK 0")
        XCTAssertTrue(fixture.handler.handle("SET 12 TRUTH 7").hasPrefix("ERROR bad_value: ternary"))
        ok("SET 13 TRUTH 7")
        XCTAssertTrue(fixture.handler.handle("CONNECT BACK FROM 1 TO 12").hasPrefix("ERROR"))
        ok("EVAL")
        assertKernel(1, "after the reads")

        // Bulk: in, then zeros.
        var modes = [UInt8](repeating: 0, count: n)
        for i in [20, 21, 22, 23, 24] { modes[i] = [1, 2, 5, 6, 1][i - 20] }
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        for i in 0..<n where modes[i] != 0 { truth[i] = 2 }
        modesBulk(modes)
        assertKernel(5, "SET_MODES_BULK with five non-binary nodes")

        // The session's WAL so far (no SAVE yet, so no checkpoint) into a
        // fresh engine: the same exact count, kept by the replay's writes.
        fixture.handler.walAppender?.barrier()
        let fresh = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                    state: DagDBState(width: side, height: side), maxRank: 8)
        let r = try DagDBWAL.replay(engine: fresh, nodeCount: n, path: walPath)
        XCTAssertEqual(r.recordsSkipped, 0, "\(r.refusals)")
        XCTAssertGreaterThan(r.recordsApplied, 0)
        XCTAssertTrue(fresh.nonBinaryCountTracked)
        XCTAssertEqual(fresh.ternaryNodeCount(), 5)
        XCTAssertEqual(fresh.nonBinaryNodeCount, 5)
        fresh.tick(tickNumber: 0)
        XCTAssertEqual(fresh.lastTickKernel, .general)
        print("R8d daemon: replay records=\(r.recordsApplied) skipped=\(r.recordsSkipped) non_binary=\(fresh.nonBinaryNodeCount)")
        modesBulk([UInt8](repeating: 0, count: n))
        assertKernel(0, "SET_MODES_BULK of zeros")

        // LOAD: a ternary snapshot, a binary one, the ternary one again.
        // With the WAL on, a loader needs a
        // startup snapshot path (refused without one); each LOAD rebases to it.
        fixture.handler.startupSnapshotPath = tmpDir + "base.dags"
        modesBulk(modes)
        let tPath = tmpDir + "t.dags", bPath = tmpDir + "b.dags"
        ok("SAVE \(tPath)")
        modesBulk([UInt8](repeating: 0, count: n))
        ok("SAVE \(bPath)")
        ok("LOAD \(tPath)")
        assertKernel(5, "LOAD of a v8 file with five non-binary nodes")
        ok("LOAD \(bPath)")
        assertKernel(0, "LOAD of a v7 binary file")
        ok("LOAD \(tPath)")
        assertKernel(5, "LOAD of the v8 file again")

    }
}
