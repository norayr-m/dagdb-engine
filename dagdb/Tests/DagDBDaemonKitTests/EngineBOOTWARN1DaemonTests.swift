import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Each tick-family command that ran leaves one 13-byte
/// TICK_NOTE, unsynced (the log goes to v5 at the first), replay applies none, and the
/// boot line sets the highest total among the window's notes against the
/// recovered tick count. The live checks (kill -9, the pre-change build, a corpus) run
/// against daemons.
final class EngineBOOTWARN1DaemonTests: XCTestCase {

    private var tmp: String!
    private let side = 8, n = 64

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "dagdb-bootwarn1-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("DAGDB_FI_WRITE_FAIL")
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    /// Two inputs into an AND at rank 0, and a CONST0 node holding 1, so a
    /// tick changes truth and TICK UNTIL_STABLE runs more than one tick.
    private let writes = ["SET 1 RANK 1", "SET 2 RANK 1", "SET 0 LUT AND", "CONNECT FROM 1 TO 0",
                          "CONNECT FROM 2 TO 0", "SET 1 TRUTH 1", "SET 2 TRUTH 1", "SET 5 LUT CONST0", "SET 5 TRUTH 1"]

    private func daemon(_ wal: String) throws -> HandlerFixture {
        let f = try HandlerFixture(side: side, dataRoot: tmp, wal: DagDBWAL.Appender(path: wal, nodeCount: n), maxRank: 16)
        for w in writes { XCTAssertTrue(f.handler.handle(w).hasPrefix("OK"), w) }
        return f
    }

    private func bytes(_ p: String) -> Data { (try? Data(contentsOf: URL(fileURLWithPath: p))) ?? Data() }
    private func version(_ p: String) -> UInt32 { bytes(p)[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }

    /// The daemon's own recovery onto a fresh engine; the tick line(s) it logged.
    private func recover(snapshot: String?, wal: String) throws -> (HandlerFixture, [String]) {
        let f = try HandlerFixture(side: side, dataRoot: tmp, maxRank: 16)
        var lines: [String] = []
        let r = try DagDBStartup.recover(
            engine: f.handler.engine, nodeCount: n, width: side, height: side, dagdbEnv: nil, dataRoot: tmp,
            twin: f.handler.twin, truthRankIndex: f.handler.truthRankIndex,
            snapshotPath: snapshot, walPath: wal, log: { lines.append($0) })
        XCTAssertNil(r.replayError)
        f.handler.tickCount = r.tickCount
        return (f, lines.filter { $0.contains("tick history") || $0.contains("lost ticks") || $0.contains("were not recovered") })
    }

    private func loss(_ l: Int, _ t: Int, _ s: Int) -> String {
        "  WAL: at least \(l) ticks were not recovered (highest logged total \(t), recovered tick count \(s)); the recovered truth is the pre-tick state; earlier restarts, a command interrupted before it replied, and a power loss can each hide more"
    }

    // MARK: - one fixed-size record per tick command that ran

    func testEveryTickCommandThatRanLeavesOneThirteenByteNote() throws {
        let wal = tmp + "notes.wal"
        let f = try daemon(wal)
        XCTAssertEqual(version(wal), DagDBWAL.versionV3, "writes alone keep the log's version")
        var size = bytes(wal).count
        let unsynced0 = f.handler.walAppender!.unsyncedCount
        for (k, cmd) in ["TICK 2", "TICK_SYNC 1", "TICK UNTIL_STABLE MAX 9", "EVAL", "TICK 0"].enumerated() {
            let reply = f.handler.handle(cmd)
            XCTAssertTrue(reply.hasPrefix("OK"), "\(cmd): \(reply)")
            XCTAssertEqual(f.handler.walAppender!.unsyncedCount, unsynced0 + k + 1, "\(cmd): the note is written unsynced")
            let d = bytes(wal)
            XCTAssertEqual(d.count - size, 13, "\(cmd): one TICK_NOTE")
            let rec = d.suffix(13)
            XCTAssertEqual(Array(rec.prefix(5)), [8, 0, 0, 0, 0x52], cmd)
            XCTAssertEqual(rec.dropFirst(5).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) },
                           UInt64(f.handler.tickCount), "\(cmd): the note carries the tick total")
            XCTAssertEqual(version(wal), DagDBWAL.versionV5)
            size = d.count
        }
        for cmd in ["TICK UNTIL_STABLE MAX 0", "TICK -1"] {
            XCTAssertTrue(f.handler.handle(cmd).hasPrefix("ERROR"), cmd)
            XCTAssertEqual(bytes(wal).count, size, "\(cmd): a refusal writes no note")
        }
        XCTAssertTrue(f.handler.handle("SET 3 TRUTH 1").hasPrefix("OK"))
        XCTAssertEqual(f.handler.walAppender!.unsyncedCount, 0, "the next synced append carries the notes to disk")
    }

    // MARK: - the boot line

    func testTheBootLineSetsTheLastNoteAgainstTheSnapshot() throws {
        // No snapshot: the whole log over an empty engine, S = 0.
        let w1 = tmp + "a.wal"
        let a = try daemon(w1)
        XCTAssertTrue(a.handler.handle("TICK 7").hasPrefix("OK TICK 7"))
        XCTAssertEqual(try recover(snapshot: nil, wal: w1).1,
                       [loss(7, 7, 0)])

        // A bound snapshot at 2 ticks, then 5 more; then SAVE after the ticks.
        let w2 = tmp + "b.wal", snap = tmp + "b.dags"
        let b = try daemon(w2)
        XCTAssertTrue(b.handler.handle("TICK 2").hasPrefix("OK"))
        XCTAssertTrue(b.handler.handle("SAVE \(snap)").hasPrefix("OK SAVE"))
        XCTAssertTrue(b.handler.handle("TICK 5").hasPrefix("OK"))
        XCTAssertEqual(try recover(snapshot: snap, wal: w2).1,
                       [loss(5, 7, 2)])
        XCTAssertTrue(b.handler.handle("SAVE \(snap)").hasPrefix("OK SAVE"))
        XCTAssertEqual(try recover(snapshot: snap, wal: w2).1,
                       ["  WAL: no lost ticks logged (highest logged total 7, recovered tick count 7; earlier restarts, an interrupted command, or a power loss can hide ticks)"])

        // No note in the log: unknown, never "0 lost".
        let w3 = tmp + "c.wal"
        _ = try daemon(w3)
        XCTAssertEqual(try recover(snapshot: nil, wal: w3).1, ["  WAL: tick history unknown"])
    }

    // MARK: - The highest note in the window; the counter's range

    func testALowerLaterNoteNeverHidesAHigherOneAndAHugeTotalIsUnknown() throws {
        let wal = tmp + "max.wal"
        let f = try daemon(wal)
        XCTAssertTrue(f.handler.handle("TICK 5").hasPrefix("OK"))
        try f.handler.walAppender!.tickNote(total: 0)        // NOTE(S) after NOTE(S+5), S = 0
        XCTAssertEqual(try recover(snapshot: nil, wal: wal).1, [loss(5, 5, 0)])
        try f.handler.walAppender!.tickNote(total: UInt64(UInt32.max) + 1)
        XCTAssertEqual(try recover(snapshot: nil, wal: wal).1,
                       ["  WAL: tick history unknown (the highest logged total 4294967296 is above the tick counter's range, 4294967295)"])
    }

    // MARK: - A counter drop with no successful rebase

    func testALoadWhoseRebaseFailsLeavesACounterDropAndTheBootSaysUnknown() throws {
        let wal = tmp + "drop.wal", base = tmp + "base.dags", old0 = tmp + "old0.dags"
        let f = try daemon(wal)
        f.handler.startupSnapshotPath = base
        XCTAssertTrue(f.handler.handle("SAVE \(old0)").hasPrefix("OK SAVE"))
        XCTAssertTrue(f.handler.handle("TICK 5").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("SAVE \(base)").hasPrefix("OK SAVE"))
        // A squatted temporary: the rebase's tmp file cannot be written.
        // SAVE's temporary is not `<path>.tmp` (it carries the daemon's marker, a name a directory cannot
        // squat in advance), so the rebase's write is failed through the write fault seam.
        setenv("DAGDB_FI_WRITE_FAIL", "base.dags", 1)
        let size = bytes(wal).count
        let load = f.handler.handle("LOAD \(old0)")
        XCTAssertTrue(load.hasPrefix("ERROR wal: LOAD loaded the state"), load)
        XCTAssertEqual(f.handler.tickCount, 0)
        let d = bytes(wal)
        XCTAssertEqual(d.count - size, 13, "one COUNTER_DROP")
        XCTAssertEqual(Array(d.suffix(13).prefix(5)), [8, 0, 0, 0, 0x53])
        // After the failed rebase every write is refused until SAVE <base>.
        XCTAssertTrue(f.handler.handle("TICK 5").hasPrefix("ERROR wal: refused"))
        XCTAssertEqual(try recover(snapshot: base, wal: wal).1, [moved])
    }

    private let moved = "  WAL: tick history unknown (the tick counter moved within this window without a durable rebase: a load whose rebase failed)"

    /// A LOAD that RAISES the counter with a failed rebase.
    func testALoadThatRaisesTheCounterWithAFailedRebaseLeavesAMarker() throws {
        let wal = tmp + "rise.wal", base = tmp + "base.dags", old0 = tmp + "old0.dags", hi9 = tmp + "hi9.dags"
        let f = try daemon(wal)
        f.handler.startupSnapshotPath = base
        XCTAssertTrue(f.handler.handle("SAVE \(old0)").hasPrefix("OK SAVE"))
        XCTAssertTrue(f.handler.handle("TICK 9").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("SAVE \(hi9)").hasPrefix("OK SAVE"))
        XCTAssertTrue(f.handler.handle("LOAD \(old0)").contains("wal_base="), "a successful rebase: no marker")
        // SAVE's temporary is not `<path>.tmp` (it carries the daemon's marker, a name a directory cannot
        // squat in advance), so the rebase's write is failed through the write fault seam.
        setenv("DAGDB_FI_WRITE_FAIL", "base.dags", 1)
        let size = bytes(wal).count
        XCTAssertTrue(f.handler.handle("LOAD \(hi9)").hasPrefix("ERROR wal: LOAD loaded the state"))
        XCTAssertEqual(f.handler.tickCount, 9)
        let d = bytes(wal)
        XCTAssertEqual(d.count - size, 13)
        XCTAssertEqual(Array(d.suffix(13).prefix(5)), [8, 0, 0, 0, 0x53])
        // After the failed rebase every write is refused until SAVE <base>.
        XCTAssertTrue(f.handler.handle("TICK 2").hasPrefix("ERROR wal: refused"))
        XCTAssertEqual(try recover(snapshot: base, wal: wal).1, [moved])
    }

    // MARK: - replay applies no note

    func testReplayWithAndWithoutTheNotesGivesTheSameState() throws {
        let wal = tmp + "inert.wal"
        let f = try daemon(wal)
        for cmd in ["TICK 2", "SET 3 TRUTH 1", "TICK_SYNC 1", "SET 4 RANK 2", "TICK UNTIL_STABLE MAX 9", "EVAL", "SET 6 TRUTH 1"] {
            XCTAssertTrue(f.handler.handle(cmd).hasPrefix("OK"), cmd)
        }
        // The same log with every 0x52 record cut out.
        let d = bytes(wal)
        var stripped = Data(d.prefix(DagDBWAL.headerSize)), off = DagDBWAL.headerSize, notes = 0
        while off < d.count {
            let len = Int(d[off..<(off + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            if d[off + 4] == 0x52 { notes += 1 } else { stripped.append(d[off..<(off + 5 + len)]) }
            off += 5 + len
        }
        XCTAssertEqual(notes, 4)
        let bare = tmp + "bare.wal"
        try stripped.write(to: URL(fileURLWithPath: bare))
        let (g1, l1) = try recover(snapshot: nil, wal: wal)
        let (g2, l2) = try recover(snapshot: nil, wal: bare)
        XCTAssertEqual(l2, ["  WAL: tick history unknown"])
        XCTAssertEqual(l1, [loss(Int(f.handler.tickCount), Int(f.handler.tickCount), 0)])
        let s1 = tmp + "s1.dags", s2 = tmp + "s2.dags"
        XCTAssertTrue(g1.handler.handle("SAVE \(s1)").hasPrefix("OK SAVE"))
        XCTAssertTrue(g2.handler.handle("SAVE \(s2)").hasPrefix("OK SAVE"))
        XCTAssertEqual(bytes(s1), bytes(s2), "the notes change no recovered byte")
        XCTAssertFalse(bytes(s1).isEmpty)
    }
}
