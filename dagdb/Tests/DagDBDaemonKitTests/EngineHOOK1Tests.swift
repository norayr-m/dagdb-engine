import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// The in-process halves of the hook checks. The wire reproducers and the era
/// fixture written by a real older build (one whose HOOK CLOSE logged no
/// sweep) run against daemons; these pin the same rules in process: HOOK
/// CLOSE's logged sweep, the older logs' replay rule and its label, the one
/// sweep after recovery, LOAD's env check before the commit, the hook list
/// rebuilt on restore, CLOCK CLOSE's count, and the header put back after a
/// failed append.
final class EngineHOOK1Tests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-hook1-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("DAGDB_FI_WRITE_FAIL")
        unsetenv("DAGDB_FI_WAL_FAIL_OPCODE")
        unsetenv("DAGDB_FI_FULLFSYNC_FAIL")
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    /// The synthetic five-record alarm fixture (EngineALLOC1bTests' helper, copied).
    private func writeSyntheticAlarmFixture() throws -> String {
        func wave(_ base: Float) -> [Float] { [base, base + 1, base + 2, base + 3] }
        func entry(_ cls: String, _ base: Float, ear: String? = nil) -> [String: Any] {
            var e: [String: Any] = ["class": cls, "a": wave(base), "b": wave(base + 10), "c": wave(base + 20)]
            if let ear = ear { e["liar_ear"] = ear }
            return e
        }
        let obj: [String: Any] = [
            "quiet_1": entry("quiet", 0), "quiet_2": entry("quiet", 100), "liar_1": entry("liar", 200, ear: "B"),
            "deep_1": entry("deep", 300), "drift_1": entry("drift", 400), "cal0_1": entry("cal0", 500),
        ]
        let path = tmpDir + "mini.json"
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func walOps(_ path: String) throws -> [UInt8] {
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        var off = DagDBWAL.headerSize, out: [UInt8] = []
        while off + 5 <= d.count {
            let n = Int(d[off]) | Int(d[off + 1]) << 8 | Int(d[off + 2]) << 16 | Int(d[off + 3]) << 24
            out.append(d[off + 4]); off += 5 + n
        }
        return out
    }

    private func walVersion(_ path: String) throws -> UInt32 {
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        return UInt32(d[4]) | UInt32(d[5]) << 8 | UInt32(d[6]) << 16 | UInt32(d[7]) << 24
    }

    /// A handler with a WAL, a clock, a gear and a hook bound to the clock,
    /// advanced once.
    private func boundHookHandler(wal walPath: String) throws -> HandlerFixture {
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 64)
        let f = try HandlerFixture(side: 8, dataRoot: tmpDir, wal: wal)
        let alarm = try writeSyntheticAlarmFixture()
        for line in ["ALARM LOAD \(alarm)", "CLOCK OPEN", "GEAR OPEN c00000001 g1 1/1",
                     "HOOK OPEN a00000001 SEALED 10 CLOCK c00000001", "CLOCK ADVANCE c00000001 1"] {
            let r = f.handler.handle(line)
            XCTAssertTrue(r.hasPrefix("OK"), "\(line) -> \(r)")
        }
        return f
    }

    private func replayTwin(_ walPath: String) throws -> (TwinState, DagDBWAL.ReplayResult) {
        let grid = try HexGrid(width: 8, height: 8)
        let engine = try DagDBEngine(grid: grid, state: DagDBState(width: 8, height: 8), maxRank: 8)
        let twin = TwinState()
        let r = try DagDBWAL.replay(engine: engine, nodeCount: 64, path: walPath, twin: twin, wholeLog: true)
        return (twin, r)
    }

    // MARK: - HOOK CLOSE sweeps its clock, logged beside its close

    func testHookCloseSweepsTheClockAndAdvanceMovesN() throws {
        let walPath = tmpDir + "a.wal"
        let f = try boundHookHandler(wal: walPath)
        XCTAssertEqual(f.handler.handle("HOOK CLOSE h00000001"), "OK HOOK CLOSE id=h00000001")
        XCTAssertEqual(f.handler.twin.clocks.get("c00000001")?.hookIds, [])
        let ops = try walOps(walPath)
        XCTAssertEqual(Array(ops.suffix(2)), [DagDBWAL.Opcode.twinClose.rawValue, DagDBWAL.Opcode.twinHookSweep.rawValue])
        XCTAssertEqual(try walVersion(walPath), DagDBWAL.versionV6)
        for k in 1...3 {
            XCTAssertEqual(f.handler.handle("CLOCK ADVANCE c00000001 3"),
                           "OK CLOCK ADVANCE id=c00000001 n=3 tick=\(1 + 3 * k) gears=1")
        }
        let (twin, r) = try replayTwin(walPath)
        XCTAssertEqual(twin.clocks.get("c00000001")?.clock.tick, 10)
        XCTAssertEqual(twin.gears.get("g00000001")?.gear.fires, 10)
        XCTAssertEqual(r.recordsSkipped, 0)
        XCTAssertEqual(r.preHOOK1Stops, [])
        XCTAssertEqual(twin.danglingHookBindings(), [])
    }

    func testUnboundHookCloseLogsTheCloseAlone() throws {
        let walPath = tmpDir + "u.wal"
        let f = try boundHookHandler(wal: walPath)
        XCTAssertTrue(f.handler.handle("HOOK OPEN a00000001 SEALED 10").hasPrefix("OK HOOK OPEN id=h00000002"))
        XCTAssertEqual(f.handler.handle("HOOK CLOSE h00000002"), "OK HOOK CLOSE id=h00000002")
        XCTAssertEqual(try walOps(walPath).last, DagDBWAL.Opcode.twinClose.rawValue)
        XCTAssertEqual(try walVersion(walPath), DagDBWAL.version, "a log that took no sweep keeps its version")
    }

    // MARK: - An older log replays as the old daemon ran it

    func testPreHOOK1CloseThenAdvanceReplaysOneTickLabelledAsItsOwn() throws {
        let walPath = tmpDir + "old.wal"
        let f = try boundHookHandler(wal: walPath)
        // The two records an older daemon (no logged sweep) wrote: TWIN_CLOSE alone (no sweep),
        // then the advance it ran as one tick and an ERROR.
        _ = try f.handler.walAppender!.append(opcode: .twinClose, payload: TwinWALCodec.encode(.close(id: "h00000001")).payload)
        _ = try f.handler.walAppender!.append(
            opcode: .twinClockAdvance,
            payload: TwinWALCodec.encode(.clockAdvance(id: "c00000001", count: 3, value: 0)).payload)
        let (twin, r) = try replayTwin(walPath)
        XCTAssertEqual(twin.clocks.get("c00000001")?.clock.tick, 2, "tick 1 then the stop, as live")
        XCTAssertEqual(twin.gears.get("g00000001")?.gear.fires, 2)
        XCTAssertEqual(r.preHOOK1Stops.count, 1)
        XCTAssertTrue(r.preHOOK1Stops[0].contains("CLOCK ADVANCE c00000001 3 stopped at h00000001"), r.preHOOK1Stops[0])
        XCTAssertEqual(r.recordsSkipped, 0, "a record that changed state is never 'skipped'")
        XCTAssertEqual(twin.danglingHookBindings(), [TwinHookBinding(clockId: "c00000001", hookId: "h00000001")])
    }

    // MARK: - The one logged sweep after recovery

    func testRecoverySweepIsOneLoggedRecordAndHappensOnce() throws {
        let walPath = tmpDir + "sweep.wal"
        do {
            let f = try boundHookHandler(wal: walPath)
            _ = try f.handler.walAppender!.append(opcode: .twinClose, payload: TwinWALCodec.encode(.close(id: "h00000001")).payload)
        }
        let (twin, _) = try replayTwin(walPath)
        let before = try walOps(walPath).count
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 64)
        let f = try HandlerFixture(side: 8, dataRoot: tmpDir, wal: wal, twin: twin)
        XCTAssertEqual(f.handler.sweepDanglingHookIdsAfterRecovery(),
                       "Twin: swept 1 dangling hook ids left by pre-HOOK1 logs (1 removed, one TWIN_HOOK_SWEEP record: c00000001:h00000001)")
        let ops = try walOps(walPath)
        XCTAssertEqual(ops.count, before + 1)
        XCTAssertEqual(ops.last, DagDBWAL.Opcode.twinHookSweep.rawValue)
        XCTAssertEqual(try walVersion(walPath), DagDBWAL.versionV6)
        XCTAssertEqual(f.handler.handle("CLOCK ADVANCE c00000001 3"), "OK CLOCK ADVANCE id=c00000001 n=3 tick=4 gears=1")
        // The next boot replays the sweep: 0 removed.
        let (twin2, r2) = try replayTwin(walPath)
        XCTAssertEqual(r2.recordsSkipped, 0)
        XCTAssertEqual(twin2.clocks.get("c00000001")?.clock.tick, 4)
        let f2 = try HandlerFixture(side: 8, dataRoot: tmpDir, twin: twin2)
        XCTAssertEqual(f2.handler.sweepDanglingHookIdsAfterRecovery(),
                       "Twin: swept 0 dangling hook ids left by pre-HOOK1 logs (0 removed)")
    }

    func testOlderReaderSeesTheSweepRecordAsUnknownBelowVersion6() throws {
        // A v5 log cannot carry 0x31: it is counted unknown, never applied.
        let walPath = tmpDir + "v5.wal"
        do {
            let f = try boundHookHandler(wal: walPath)
            _ = try f.handler.walAppender!.tickNote(total: 0)    // the log goes to v5
        }
        XCTAssertEqual(try walVersion(walPath), DagDBWAL.versionV5)
        let payload = try TwinWALCodec.encode(.hookSweep(bindings: [TwinHookBinding(clockId: "c00000001", hookId: "h00000001")])).payload
        var rec = Data()
        var n = UInt32(payload.count).littleEndian
        rec.append(Data(bytes: &n, count: 4)); rec.append(DagDBWAL.Opcode.twinHookSweep.rawValue); rec.append(payload)
        let h = FileHandle(forWritingAtPath: walPath)!
        h.seekToEndOfFile(); h.write(rec); h.closeFile()
        let (_, r) = try replayTwin(walPath)
        XCTAssertEqual(r.skipReasons.unknownOpcode, 1)
    }

    func testVersion1LogRefusesTheSweepByNameAndNothingChanges() throws {
        let walPath = tmpDir + "v1.wal"
        var head = Data("DAGW".utf8)
        for v in [UInt32(1), 64, 0] { var x = v.littleEndian; head.append(Data(bytes: &x, count: 4)) }
        try head.write(to: URL(fileURLWithPath: walPath))
        let f = try boundHookHandler(wal: walPath)
        let before = try Data(contentsOf: URL(fileURLWithPath: walPath))
        let r = f.handler.handle("HOOK CLOSE h00000001")
        XCTAssertTrue(r.hasPrefix("ERROR wal: append: "), r)
        XCTAssertTrue(r.contains("opcode 0x31 needs log version 6, this log is version 1"), r)
        // The way out is named (no startup path in this fixture).
        XCTAssertTrue(r.contains("; nothing written; this log cannot be upgraded in place: first stop every writer (a write between this SAVE and the stop stays in the log moved aside, and is lost); then SAVE a snapshot to a file,"
                                 + " stop the daemon, move \(walPath) aside and start it again with DAGDB_STARTUP_LOAD naming that file"), r)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: walPath)), before)
        XCTAssertNotNil(f.handler.twin.hooks.get("h00000001"))
        XCTAssertEqual(f.handler.twin.clocks.get("c00000001")?.hookIds, ["h00000001"])
    }

    // MARK: - Refused before the WAL; the version refusal's way out; an unlogged sweep

    func testRecordSliceAboveTheReplayCapIsRefusedBeforeTheWAL() throws {
        // The result file holds 3N = 12 288 u64s at side 64, the replay cap is 10 000.
        let walPath = tmpDir + "slice.wal"
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir, wal: try DagDBWAL.Appender(path: walPath, nodeCount: 4096))
        let pcg = "0x853c49e6748fea9b 0xda3e39cb94b95bdb 0x5851f42d4c957f2d 0x14057b7ef767814f"
        XCTAssertTrue(f.handler.handle("RECORD OPEN court 1500 0.6827 3000 1.0 0.6827 0.00001 0 \(pcg)").hasPrefix("OK RECORD OPEN"))
        let before = try Data(contentsOf: URL(fileURLWithPath: walPath))
        XCTAssertEqual(f.handler.handle("RECORD SLICE t00000001 10001"), "ERROR bad_value: count 10001 not in 0...10000")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: walPath)), before)
        XCTAssertTrue(f.handler.handle("RECORD SLICE t00000001 10000").hasPrefix("OK RECORD SLICE"))
        let (_, r) = try replayTwinSide64(walPath)
        XCTAssertEqual(r.refusals, [])
        XCTAssertEqual(r.recordsSkipped, 0)
    }

    private func replayTwinSide64(_ walPath: String) throws -> (TwinState, DagDBWAL.ReplayResult) {
        let grid = try HexGrid(width: 64, height: 64)
        let engine = try DagDBEngine(grid: grid, state: DagDBState(width: 64, height: 64), maxRank: 8)
        let twin = TwinState()
        let r = try DagDBWAL.replay(engine: engine, nodeCount: 4096, path: walPath, twin: twin, wholeLog: true)
        return (twin, r)
    }

    func testAWrappedIdCounterIsRefusedBeforeTheWAL() throws {
        // Found by a mechanical enumeration: past 2^32 opens the minted id lands on a live entry.
        let walPath = tmpDir + "wrap.wal"
        let f = try HandlerFixture(side: 8, dataRoot: tmpDir, wal: try DagDBWAL.Appender(path: walPath, nodeCount: 64))
        XCTAssertTrue(f.handler.handle("STREAM OPEN sx 1 2 3 5").hasPrefix("OK STREAM OPEN id=s00000001"))
        f.handler.twin.streams.resetCounter(to: 1 << 32)   // the next id formats as s00000001 again
        XCTAssertEqual(f.handler.twin.nextId(prefix: "s"), "s00000001")
        let before = try Data(contentsOf: URL(fileURLWithPath: walPath))
        let r = f.handler.handle("STREAM OPEN sy 1 2 3 5")
        XCTAssertTrue(r.hasPrefix("ERROR bad_value: duplicate id: s00000001; STREAM OPEN would mint"), r)
        XCTAssertTrue(r.hasSuffix("nothing written"), r)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: walPath)), before)
        XCTAssertEqual(f.handler.twin.streams.openCount, 1)
    }

    func testVersionRefusalNamesTheStartupPathWhenThereIsOne() throws {
        let walPath = tmpDir + "v1s.wal"
        var head = Data("DAGW".utf8)
        for v in [UInt32(1), 64, 0] { var x = v.littleEndian; head.append(Data(bytes: &x, count: 4)) }
        try head.write(to: URL(fileURLWithPath: walPath))
        let f = try boundHookHandler(wal: walPath)
        f.handler.startupSnapshotPath = tmpDir + "base.dags"
        let r = f.handler.handle("HOOK CLOSE h00000001")
        XCTAssertTrue(r.hasSuffix("; nothing written; this log cannot be upgraded in place: first stop every writer (a write between this SAVE and the stop stays in the log moved aside, and is lost); then SAVE \(tmpDir!)base.dags, stop the daemon,"
                                  + " move \(walPath) aside and start it again (it loads \(tmpDir!)base.dags and opens a fresh"
                                  + " version-3 log; the fresh log takes this record)"), r)
    }

    func testAnUnloggedSweepSaysItRepeatsUntilASave() throws {
        // With the WAL off, nothing records the sweep.
        let f = try boundHookHandler(wal: tmpDir + "x.wal")
        try f.handler.twin.apply(.close(id: "h00000001"))    // an older close: the id stays on the clock
        let g = try HandlerFixture(side: 8, dataRoot: tmpDir, twin: f.handler.twin)
        g.handler.startupSnapshotPath = tmpDir + "base.dags"
        XCTAssertEqual(g.handler.sweepDanglingHookIdsAfterRecovery(),
                       "Twin: swept 1 dangling hook ids left by pre-HOOK1 logs (1 removed: c00000001:h00000001); not logged"
                       + " (the WAL is off), so every boot sweeps them again until a SAVE \(tmpDir!)base.dags writes the state without them")
    }

    // MARK: - Restore rebuilds each clock's hook list

    func testRestoreListsEachBoundHookOnceAndKeepsTheFilesDanglingIdOnlyForRecovery() throws {
        let f = try boundHookHandler(wal: tmpDir + "r.wal")
        var snap = f.handler.twin.export()
        snap.clocks["c00000001"]!.hookIds = ["h00000001", "h00000001", "h00000009"]   // an older file's shape
        let load = TwinState()
        try load.restore(snap)
        XCTAssertEqual(load.clocks.get("c00000001")?.hookIds, ["h00000001"])
        let recovery = TwinState()
        try recovery.restore(snap, keepDanglingHookIds: true)
        XCTAssertEqual(recovery.clocks.get("c00000001")?.hookIds, ["h00000001", "h00000009"])
        try load.apply(.clockAdvance(id: "c00000001", count: 1, value: 0))
        XCTAssertEqual(load.hooks.get("h00000001")?.hook.t, 2, "one step per tick after a restore")
    }

    // MARK: - CLOCK CLOSE counts only live hooks

    func testClockCloseCountsOnlyLiveHooks() throws {
        let f = try boundHookHandler(wal: tmpDir + "c.wal")
        try f.handler.twin.apply(.close(id: "h00000001"))    // an older close: the id stays on the clock
        XCTAssertEqual(f.handler.handle("CLOCK CLOSE c00000001"), "OK CLOCK CLOSE id=c00000001 gears_closed=1 hooks_closed=0")
    }

    func testAdvanceOverAnUnsweptIdIsRefusedBeforeAnyChange() throws {
        let f = try boundHookHandler(wal: tmpDir + "d.wal")
        try f.handler.twin.apply(.close(id: "h00000001"))
        let wal = try Data(contentsOf: URL(fileURLWithPath: tmpDir + "d.wal"))
        let r = f.handler.handle("CLOCK ADVANCE c00000001 3")
        XCTAssertTrue(r.hasPrefix("ERROR forbidden: clock c00000001 holds h00000001"), r)
        XCTAssertTrue(r.contains(" (left by a log or snapshot from an older build that this daemon could not sweep); nothing changed;"), r)
        XCTAssertTrue(r.contains("; nothing changed; to sweep it: first stop every writer (a write between this SAVE and the stop stays in the log moved aside, and is lost); then SAVE a snapshot to a file, stop the daemon, move "), r)
        XCTAssertTrue(r.hasSuffix("its recovery sweeps the id with one logged record), or CLOCK CLOSE c00000001"), r)
        XCTAssertEqual(f.handler.twin.clocks.get("c00000001")?.clock.tick, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: tmpDir + "d.wal")), wal)
    }

    // MARK: - LOAD's env check comes before the commit

    func testCrossEnvLoadChangesNothing() throws {
        let a = try HandlerFixture(side: 8, dataRoot: tmpDir, dagdbEnv: "test")
        XCTAssertTrue(a.handler.handle("SET 5 TRUTH 1").hasPrefix("OK"))
        XCTAssertTrue(a.handler.handle("CLOCK OPEN").hasPrefix("OK"))
        XCTAssertTrue(a.handler.handle("CLOCK ADVANCE c00000001 5").hasPrefix("OK"))
        XCTAssertTrue(a.handler.handle("SAVE \(tmpDir!)test_env.dags").hasPrefix("OK SAVE"))

        let b = try HandlerFixture(side: 8, dataRoot: tmpDir, dagdbEnv: "prod")
        XCTAssertTrue(b.handler.handle("SET 9 TRUTH 1").hasPrefix("OK"))
        XCTAssertTrue(b.handler.handle("CLOCK OPEN").hasPrefix("OK"))
        XCTAssertTrue(b.handler.handle("CLOCK ADVANCE c00000001 2").hasPrefix("OK"))
        XCTAssertTrue(b.handler.handle("SAVE \(tmpDir!)b_before.dags").hasPrefix("OK SAVE"))
        let r = b.handler.handle("LOAD \(tmpDir!)test_env.dags")
        XCTAssertTrue(r.hasPrefix("ERROR io: load: "), r)
        XCTAssertTrue(r.contains("test") && r.contains("prod"), r)
        XCTAssertTrue(b.handler.handle("SAVE \(tmpDir!)b_after.dags").hasPrefix("OK SAVE"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: tmpDir + "b_before.dags")),
                       try Data(contentsOf: URL(fileURLWithPath: tmpDir + "b_after.dags")))
        XCTAssertEqual(b.handler.handle("GET 5 TRUTH"), "OK GET node=5 truth=0")
        XCTAssertEqual(b.handler.handle("CLOCK STATE c00000001"), "OK CLOCK STATE id=c00000001 tick=2 gears=[]")
    }

    // MARK: - A failed append puts the header's version back (seam)

    func testFailedNoteAppendPutsTheHeaderBack() throws {
        let walPath = tmpDir + "h.wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 64)
        XCTAssertEqual(try walVersion(walPath), DagDBWAL.versionV3)
        let before = try Data(contentsOf: URL(fileURLWithPath: walPath))
        setenv("DAGDB_FI_WAL_FAIL_OPCODE", "52", 1)
        XCTAssertThrowsError(try wal.tickNote(total: 7)) { e in
            XCTAssertTrue("\(e)".contains("the header's version put back to 3"), "\(e)")
        }
        unsetenv("DAGDB_FI_WAL_FAIL_OPCODE")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: walPath)), before)
        XCTAssertEqual(wal.fileVersion, DagDBWAL.versionV3)
    }

    // MARK: - The finite rule before the WAL; the hold after a failed rebase; loaders with the WAL on

    /// RECORD OPEN runs HEADER CHECK's finite rule before the WAL.
    func testRecordOpenWithANanFloorIsRefusedBeforeTheWAL() throws {
        let walPath = tmpDir + "nan.wal"
        let f = try HandlerFixture(side: 8, dataRoot: tmpDir, wal: try DagDBWAL.Appender(path: walPath, nodeCount: 64))
        let before = try Data(contentsOf: URL(fileURLWithPath: walPath))
        let r = f.handler.handle("RECORD OPEN rx 1500 0.6827 3000 1.0 0.6827 0.00001 nan 1 2 3 5")
        XCTAssertEqual(r, "ERROR bad_value: header fields must be finite; nothing written")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: walPath)), before)
        XCTAssertEqual(f.handler.handle("RECORD LIST"), "OK RECORD LIST count=0")
        XCTAssertTrue(f.handler.handle("SAVE \(tmpDir!)s.dags").hasPrefix("OK SAVE"))
    }

    /// After a failed rebase every write is refused by name,
    /// before any change, until SAVE <base>; reads answer; STATUS names it.
    func testAfterAFailedRebaseEveryWriteIsRefusedUntilTheBaseIsSaved() throws {
        let walPath = tmpDir + "hold.wal", base = tmpDir + "base.dags", j = tmpDir + "j.json"
        let f = try HandlerFixture(side: 8, dataRoot: tmpDir, wal: try DagDBWAL.Appender(path: walPath, nodeCount: 64))
        f.handler.startupSnapshotPath = base
        XCTAssertTrue(f.handler.handle("SET 2 RANK 2").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("SAVE JSON \(j)").hasPrefix("OK SAVE_JSON"))
        XCTAssertTrue(f.handler.handle("SAVE \(base)").hasPrefix("OK SAVE"))
        // SAVE's temporary is not `<path>.tmp` (it carries the daemon's marker, a name a directory cannot
        // squat in advance), so the rebase's write is failed through the write fault seam.
        setenv("DAGDB_FI_WRITE_FAIL", "base.dags", 1)
        XCTAssertTrue(f.handler.handle("LOAD JSON \(j)").hasPrefix("ERROR wal: LOAD JSON loaded the state"))
        let before = try Data(contentsOf: URL(fileURLWithPath: walPath))
        for w in ["SET 3 TRUTH 1", "SET_TRUTH RANK 2-2 FILL 1", "TICK 1", "CLOCK OPEN", "SAVE \(tmpDir!)other.dags"] {
            let r = f.handler.handle(w)
            XCTAssertEqual(r, "ERROR wal: refused: LOAD JSON's durable snapshot to \(base) failed, so the live state is not the"
                           + " durable base and a write now would replay on the pre-load base after a restart; SAVE \(base) makes"
                           + " the loaded state durable, or LOAD \(base) returns to the durable state; nothing changed", w)
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: walPath)), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir + "other.dags"))
        XCTAssertTrue(f.handler.handle("STATUS").hasSuffix(" rebase_pending=\(base)"))
        XCTAssertEqual(f.handler.handle("GET 3 TRUTH"), "OK GET node=3 truth=0")
        XCTAssertTrue(f.handler.handle("CLOCK LIST").hasPrefix("OK CLOCK LIST"))
        unsetenv("DAGDB_FI_WRITE_FAIL")
        XCTAssertTrue(f.handler.handle("SAVE \(base)").hasPrefix("OK SAVE"))
        XCTAssertFalse(f.handler.handle("STATUS").contains("rebase_pending"))
        XCTAssertTrue(f.handler.handle("SET 3 TRUTH 1").hasPrefix("OK"))
    }

    /// With the WAL on and no startup snapshot path every
    /// loader is refused before any change, and the boot warning names it.
    func testWithTheWALOnAndNoStartupPathTheLoadersAreRefused() throws {
        let walPath = tmpDir + "mode.wal", s = tmpDir + "s.dags"
        let f = try HandlerFixture(side: 8, dataRoot: tmpDir, wal: try DagDBWAL.Appender(path: walPath, nodeCount: 64))
        XCTAssertTrue(f.handler.walWithoutStartupWarning()?.contains("LOAD, LOAD JSON, LOAD CSV and BACKUP RESTORE are refused") == true)
        XCTAssertTrue(f.handler.handle("SAVE \(s)").hasPrefix("OK SAVE"))
        XCTAssertTrue(f.handler.handle("SAVE JSON \(tmpDir!)s.json").hasPrefix("OK SAVE_JSON"))
        XCTAssertTrue(f.handler.handle("SET 3 TRUTH 1").hasPrefix("OK"))
        let before = try Data(contentsOf: URL(fileURLWithPath: walPath))
        for (verb, arg) in [("LOAD", s), ("LOAD JSON", tmpDir + "s.json")] {
            let r = f.handler.handle("\(verb) \(arg)")
            XCTAssertTrue(r.hasPrefix("ERROR wal: \(verb) refused: the WAL is on and no startup snapshot is set") && r.contains("set DAGDB_STARTUP_LOAD"), r)
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: walPath)), before)
        XCTAssertEqual(f.handler.handle("GET 3 TRUTH"), "OK GET node=3 truth=1")
        f.handler.startupSnapshotPath = tmpDir + "base.dags"
        XCTAssertNil(f.handler.walWithoutStartupWarning())
        XCTAssertTrue(f.handler.handle("LOAD \(s)").hasPrefix("OK LOAD"))
        XCTAssertNil(try HandlerFixture(side: 8, dataRoot: tmpDir).handler.walWithoutStartupWarning())
    }

    // MARK: - A nan record in an older log; a double-listed hook; loaders and autosave during the hold

    /// The daemon's own recovery onto a fresh 8×8 handler; every line it logged.
    private func recoverLines(snapshot: String?, wal: String) throws -> (HandlerFixture, [String]) {
        let f = try HandlerFixture(side: 8, dataRoot: tmpDir)
        var lines: [String] = []
        let r = try DagDBStartup.recover(
            engine: f.handler.engine, nodeCount: 64, width: 8, height: 8, dagdbEnv: nil, dataRoot: tmpDir,
            twin: f.handler.twin, truthRankIndex: f.handler.truthRankIndex,
            snapshotPath: snapshot, walPath: wal, log: { lines.append($0) })
        XCTAssertNil(r.replayError)
        return (f, lines)
    }

    /// A nan RECORD OPEN in an older log replays as written; the boot
    /// names it and the way out; SAVE refuses by name, writing nothing, until
    /// RECORD CLOSE.
    func testAReplayedNanRecordIsNamedAtBootAndSaveNamesRecordClose() throws {
        let walPath = tmpDir + "oldnan.wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 64)
        let header = StreamHeader(signalBandHz: 1500, tauWindowSec: 0.6827, combRateHz: 3000, firstEchoSec: 1.0,
                                  recordWindowSec: 0.6827, stepSec: 0.00001, clockSyncFloorSec: .nan)
        _ = try wal.twins([.recordOpen(id: "t00000001", name: "rx", header: header, stateHi: 1, stateLo: 2, incHi: 3, incLo: 5)])
        let (f, lines) = try recoverLines(snapshot: nil, wal: walPath)
        XCTAssertEqual(lines.filter { $0.contains("HEADER CHECK") },
                       ["  WARN: replayed RECORD t00000001 carries a header HEADER CHECK refuses; SAVE refuses until RECORD CLOSE t00000001, then SAVE"])
        XCTAssertEqual(f.handler.handle("RECORD LIST"), "OK RECORD LIST count=1 t00000001")
        let p = tmpDir + "after.dags"
        XCTAssertEqual(f.handler.handle("SAVE \(p)"),
                       "ERROR bad_value: save: RECORD t00000001 carries a header HEADER CHECK refuses (replayed from a log older"
                       + " than this build); SAVE refuses until RECORD CLOSE t00000001, then SAVE; nothing written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: p))
        XCTAssertTrue(f.handler.handle("RECORD CLOSE t00000001").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("SAVE \(p)").hasPrefix("OK SAVE"))
    }

    /// A snapshot whose clock lists a bound hook
    /// twice (an older restore wrote it so) restores it once; recovery
    /// steps it once per replayed tick and the boot names it with its ids.
    func testARestoredDoubleListedHookIsSingleSteppedAndNamedAtBoot() throws {
        let f = try boundHookHandler(wal: tmpDir + "w.wal")          // clock tick 1, hook t 1
        let p = tmpDir + "dup.dags"
        XCTAssertTrue(f.handler.handle("SAVE \(p)").hasPrefix("OK SAVE"))
        var d = try Data(contentsOf: URL(fileURLWithPath: p))
        let ti = try XCTUnwrap(d.range(of: Data("TWIN".utf8), options: .backwards)).lowerBound
        let n = Int(d[ti + 4]) | Int(d[ti + 5]) << 8 | Int(d[ti + 6]) << 16 | Int(d[ti + 7]) << 24
        var snap = try JSONDecoder().decode(TwinState.Snapshot.self, from: d.subdata(in: (ti + 8)..<(ti + 8 + n)))
        snap.clocks["c00000001"]!.hookIds = ["h00000001", "h00000001"]  // what main's restore wrote after a LOAD
        let nj = try JSONEncoder().encode(snap)
        var len = UInt32(nj.count).littleEndian
        d = d.subdata(in: 0..<(ti + 4)) + Data(bytes: &len, count: 4) + nj + d.subdata(in: (ti + 8 + n)..<d.count)
        try d.write(to: URL(fileURLWithPath: p))
        try FileManager.default.removeItem(atPath: p + ".sha256")
        let staged = TwinState()
        try staged.restore(snap, keepDanglingHookIds: true)
        // Every restored bound hook, with the times its clock lists it.
        XCTAssertEqual(staged.restoredBoundHooks,
                       [TwinState.RestoredBoundHook(clockId: "c00000001", hookId: "h00000001", times: 2, tick: 1, t: 1)])
        XCTAssertEqual(staged.clocks.get("c00000001")?.hookIds, ["h00000001"])

        let walPath = tmpDir + "ticks.wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 64)
        _ = try wal.twins([.clockAdvance(id: "c00000001", count: 3, value: 0)])
        // Never "did"; the twice-listed snapshot is stated as evidence.
        let did = "h00000001 on clock c00000001 (the restored snapshot lists it 2 times; 3 tick(s) before the era's start replayed, frame 1 -> 4 at one step per tick)"
        // The first boot on that log: the era sidecar is written for its whole length, so its 3 ticks are pre-era,
        // and the twice-listed snapshot is given as evidence (the word is "may have").
        let (g, lines) = try recoverLines(snapshot: p, wal: walPath)
        XCTAssertEqual(g.handler.twin.hooks.get("h00000001")?.hook.t, 4, "one step per replayed tick")
        XCTAssertTrue(FileManager.default.fileExists(atPath: walPath + ".hook1_era"))
        let named = lines.filter { $0.contains("single-stepped") }
        XCTAssertEqual(named.count, 1, "\(lines)")
        XCTAssertTrue(named.first?.contains("may have double-stepped") == true && named.first?.contains(did) == true, "\(named)")
        XCTAssertFalse(named.first?.contains("did step") == true)
        // 2 ticks appended past the sidecar's mark by no sealing handler (as an older build's
        // appends, or a crash tail) are named past the mark; the 3 pre-era ticks keep their line (the frame at the era 4).
        _ = try wal.twins([.clockAdvance(id: "c00000001", count: 2, value: 0)])
        let (g2, lines2) = try recoverLines(snapshot: p, wal: walPath)
        XCTAssertEqual(g2.handler.twin.hooks.get("h00000001")?.hook.t, 6)
        XCTAssertEqual(lines2.filter { $0.contains("single-stepped") }.count, 2, "\(lines2)")
        XCTAssertTrue(lines2.contains { $0.contains(did) && $0.contains("may have double-stepped") }, "\(lines2)")
        XCTAssertTrue(lines2.contains { $0.contains("past the era sidecar's high-water mark")
            && $0.contains("h00000001 on clock c00000001 (the restored snapshot lists it 2 times; 2 tick(s) replayed past the mark, frame 4 -> 6") }, "\(lines2)")
        // No replayed tick of that clock: nothing to name.
        let empty = tmpDir + "empty.wal"
        _ = try DagDBWAL.Appender(path: empty, nodeCount: 64)
        XCTAssertEqual(try recoverLines(snapshot: p, wal: empty).1.filter { $0.contains("single-stepped") }, [])
    }

    /// A loader that keeps the twin state is refused
    /// before the load while a record HEADER CHECK refuses is open (its
    /// rebase would refuse, and the hold would then refuse RECORD CLOSE).
    func testATwinKeepingLoaderIsRefusedBeforeTheLoadWhileANanRecordIsOpen() throws {
        let walPath = tmpDir + "trap.wal", base = tmpDir + "base.dags", j = tmpDir + "j.json"
        let f = try HandlerFixture(side: 8, dataRoot: tmpDir, wal: try DagDBWAL.Appender(path: walPath, nodeCount: 64))
        f.handler.startupSnapshotPath = base
        XCTAssertTrue(f.handler.handle("SAVE \(base)").hasPrefix("OK SAVE"))
        XCTAssertTrue(f.handler.handle("SAVE JSON \(j)").hasPrefix("OK SAVE_JSON"))
        let header = StreamHeader(signalBandHz: 1500, tauWindowSec: 0.6827, combRateHz: 3000, firstEchoSec: 1.0,
                                  recordWindowSec: 0.6827, stepSec: 0.00001, clockSyncFloorSec: .nan)
        try f.handler.twin.apply(.recordOpen(id: "t00000001", name: "rx", header: header, stateHi: 1, stateLo: 2, incHi: 3, incLo: 5))
        let before = try Data(contentsOf: URL(fileURLWithPath: walPath))
        XCTAssertEqual(f.handler.handle("LOAD JSON \(j)"),
                       "ERROR bad_value: LOAD JSON refused: RECORD t00000001 carries a header HEADER CHECK refuses (replayed"
                       + " from a log older than this build), so this load's durable snapshot would refuse and leave the loaded"
                       + " state not durable; RECORD CLOSE t00000001, then LOAD JSON; nothing loaded")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: walPath)), before)
        XCTAssertFalse(f.handler.handle("STATUS").contains("rebase_pending"))
        XCTAssertTrue(f.handler.handle("RECORD CLOSE t00000001").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("LOAD JSON \(j)").contains("wal_base=\"\(base)\""))
    }

    /// While the hold is on, the shutdown autosave
    /// does not run, and the line names it; once the base is saved it runs.
    func testTheShutdownAutosaveIsSkippedWhileTheHoldIsOn() throws {
        let walPath = tmpDir + "auto.wal", base = tmpDir + "base.dags", j = tmpDir + "j.json"
        let f = try HandlerFixture(side: 8, dataRoot: tmpDir, wal: try DagDBWAL.Appender(path: walPath, nodeCount: 64))
        f.handler.startupSnapshotPath = base
        XCTAssertTrue(f.handler.handle("SAVE JSON \(j)").hasPrefix("OK SAVE_JSON"))
        XCTAssertTrue(f.handler.handle("SAVE \(base)").hasPrefix("OK SAVE"))
        // SAVE's temporary is not `<path>.tmp` (it carries the daemon's marker, a name a directory cannot
        // squat in advance), so the rebase's write is failed through the write fault seam.
        setenv("DAGDB_FI_WRITE_FAIL", "base.dags", 1)
        XCTAssertTrue(f.handler.handle("LOAD JSON \(j)").hasPrefix("ERROR wal: LOAD JSON loaded the state"))
        unsetenv("DAGDB_FI_WRITE_FAIL")
        let before = try Data(contentsOf: URL(fileURLWithPath: walPath))
        let baseBefore = try Data(contentsOf: URL(fileURLWithPath: base))
        for path in [base, tmpDir + "other.dags"] {
            XCTAssertEqual(f.handler.autosaveAtShutdown(path: path),
                           "autosave skipped: the live state is not the durable base (rebase pending to \(base)); the loaded"
                           + " state is not kept; SAVE \(base) before stopping to keep it")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: walPath)), before)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: base)), baseBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir + "other.dags"))
        XCTAssertTrue(f.handler.handle("SAVE \(base)").hasPrefix("OK SAVE"))
        XCTAssertTrue(f.handler.autosaveAtShutdown(path: base).hasPrefix("OK SAVE"))
    }

    // MARK: - The era mark and the running hash

    /// The handler seals the mark at a durable
    /// snapshot from the appender's running hash (equal to the whole log's); a
    /// short seal never matches; a mismatch is named once and re-sealed.
    func testTheEraMarkIsSealedShortSealsNeverMatchAndAMismatchIsResealedOnce() throws {
        let walPath = tmpDir + "seal.wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 64)
        let (_, first) = try recoverLines(snapshot: nil, wal: walPath)        // header only: the era at 16, silently
        XCTAssertTrue(first.contains { $0.contains("HOOK1 era begins at byte 16") }, "\(first)")
        let head = wal.durableDigest()
        XCTAssertEqual(head.length, 16)
        let f = try HandlerFixture(side: 8, dataRoot: tmpDir, wal: wal)
        f.handler.eraSeal = DagDBStartup.EraSeal(offset: 16, eraSha256: head.sha256)
        XCTAssertTrue(f.handler.handle("SET 3 TRUTH 1").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("SAVE \(tmpDir!)s.dags").hasPrefix("OK SAVE"))
        let side = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: walPath + ".hook1_era"))) as! [String: Any]
        let d = wal.durableDigest()
        XCTAssertEqual(side["mark"] as? Int, d.length)
        XCTAssertEqual(side["length"] as? Int, 16)
        // The running hash is the whole log's (version-blanked), through the durable offset.
        wal.barrier()
        let whole = try Data(contentsOf: URL(fileURLWithPath: walPath))
        XCTAssertEqual(wal.durableDigest().sha256, DagDBHOOK1Era.prefixHash(whole, length: whole.count))
        XCTAssertEqual(wal.durableDigest().length, whole.count)
        let c = try XCTUnwrap(DagDBHOOK1Era.read(walPath: walPath, dataRoot: tmpDir).claim)
        XCTAssertEqual(c.mark, d.length)
        // A header-only seal proves nothing.
        XCTAssertNil(DagDBHOOK1Era.write(walPath: walPath, era: 0, eraSha256: DagDBHOOK1Era.emptySha256, mark: 16, markSha256: head.sha256,
                                         dataRoot: tmpDir))
        let short = DagDBHOOK1Era.read(walPath: walPath, dataRoot: tmpDir)
        XCTAssertNil(short.claim)
        XCTAssertTrue(short.unknown?.contains("seals only 16 bytes") == true, "\(String(describing: short.unknown))")
        // The boot names it once and re-seals; the next boot is silent.
        let (_, b1) = try recoverLines(snapshot: nil, wal: walPath)
        XCTAssertEqual(b1.filter { $0.contains("WARN: the era sidecar") }.count, 1, "\(b1)")
        XCTAssertTrue(b1.contains { $0.contains("re-sealed at byte \(whole.count)") }, "\(b1)")
        let (_, b2) = try recoverLines(snapshot: nil, wal: walPath)
        XCTAssertEqual(b2.filter { $0.contains("WARN: the era sidecar") }, [], "\(b2)")
    }

    /// The era sidecar's `note` is free text that no reader parses: `DagDBHOOK1Era.read` decodes it with the
    /// rest of the file and builds its claim from the format, the era, the mark and their hashes only. The
    /// writer writes the plain note; a sidecar holding the note older builds wrote still loads with the same
    /// claim, and a boot over it finds the era sealed and matching.
    func testAnEraSidecarWithTheOlderNoteLoadsAndTheWriterWritesThePlainNote() throws {
        let walPath = tmpDir + "note.wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 64)
        _ = try wal.setTruth(node: 1, value: 1)
        wal.barrier()
        let whole = try Data(contentsOf: URL(fileURLWithPath: walPath))
        let era = DagDBWAL.headerSize, mark = whole.count
        XCTAssertNil(DagDBHOOK1Era.write(walPath: walPath, era: era, eraSha256: DagDBHOOK1Era.prefixHash(whole, length: era),
                                         mark: mark, markSha256: DagDBHOOK1Era.prefixHash(whole, length: mark), dataRoot: tmpDir))
        let sp = DagDBHOOK1Era.sidecarPath(walPath)
        var side = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: sp))) as? [String: Any])
        let tail = "; records past \(mark) are foreign or an unsealed tail"
            + "; each hash covers its prefix with the header's version field (bytes 4-7) blanked"
        XCTAssertEqual(side["note"] as? String,
                       "era: records before byte \(era) of this log come from older builds or are of unknown origin"
                       + "; records in [\(era), \(mark)) were written by a build that keeps this sidecar (its last seal)" + tail)
        let plain = try XCTUnwrap(DagDBHOOK1Era.read(walPath: walPath, dataRoot: tmpDir).claim)
        // The note as older builds wrote it, byte for byte.
        side["note"] = "ENGINE HOOK1 era: records before byte \(era) of this log are pre-HOOK1 or of unknown origin"
            + "; records in [\(era), \(mark)) were written by a HOOK1 build (its last seal)" + tail
        try JSONSerialization.data(withJSONObject: side).write(to: URL(fileURLWithPath: sp))
        let older = DagDBHOOK1Era.read(walPath: walPath, dataRoot: tmpDir)
        XCTAssertNil(older.unknown, "\(String(describing: older.unknown))")
        XCTAssertEqual(older.claim, plain)
        let (_, lines) = try recoverLines(snapshot: nil, wal: walPath)
        XCTAssertTrue(lines.contains { $0.contains("sealed to byte \(mark)") && $0.contains("matches") }, "\(lines)")
        XCTAssertEqual(lines.filter { $0.contains("WARN: the era sidecar") }, [], "\(lines)")
    }

    /// The running hash follows every write path (sync:false records and
    /// a barrier, a twin group, a version upgrade in place) and equals the
    /// whole log's version-blanked hash through the durable offset; the replay
    /// hands the same state over.
    func testTheRunningHashEqualsTheWholeLogsThroughTheDurableOffset() throws {
        let walPath = tmpDir + "run.wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 64)
        _ = try wal.setTruth(node: 1, value: 1)
        _ = try wal.append(opcode: .checkpoint, payload: Data(count: 8), sync: false)
        let before = wal.durableDigest().length
        wal.barrier()
        XCTAssertGreaterThan(wal.durableDigest().length, before, "a sync:false record joins the hash at the barrier")
        let alarm = try writeSyntheticAlarmFixture()
        let f = try HandlerFixture(side: 8, dataRoot: tmpDir, wal: wal)
        for l in ["ALARM LOAD \(alarm)", "CLOCK OPEN", "HOOK OPEN a00000001 SEALED 10 CLOCK c00000001", "HOOK CLOSE h00000001"] {
            XCTAssertTrue(f.handler.handle(l).hasPrefix("OK"), l)                  // the bound close: v6 in place
        }
        XCTAssertEqual(try walVersion(walPath), DagDBWAL.versionV6)
        let whole = try Data(contentsOf: URL(fileURLWithPath: walPath))
        XCTAssertEqual(wal.durableDigest().length, whole.count)
        XCTAssertEqual(wal.durableDigest().sha256, DagDBHOOK1Era.prefixHash(whole, length: whole.count))
        let grid = try HexGrid(width: 8, height: 8)
        let engine = try DagDBEngine(grid: grid, state: DagDBState(width: 8, height: 8), maxRank: 8)
        let r = try DagDBWAL.replay(engine: engine, nodeCount: 64, path: walPath, twin: TwinState(), wholeLog: true, hashAt: [16])
        XCTAssertEqual(r.hashedLength, whole.count)
        XCTAssertEqual(r.hashState.map { $0.finalize().map { String(format: "%02x", $0) }.joined() }, wal.durableDigest().sha256)
        XCTAssertEqual(r.prefixDigests[16], DagDBHOOK1Era.prefixHash(whole, length: 16))
    }

    /// The running hash advances only when F_FULLFSYNC succeeds
    /// (seam DAGDB_FI_FULLFSYNC_FAIL), and a seal covers only the durable prefix.
    /// A failed sync poisons the
    /// appender: the record whose sync failed is cut back and refused by name, and
    /// every later write is refused until restart (in an earlier build the record stayed,
    /// unsynced, and joined the hash at the next good sync). The hash still never
    /// passes the last durable offset.
    func testTheRunningHashStaysAtTheLastDurableOffsetWhenTheSyncFails() throws {
        let walPath = tmpDir + "fs.wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 64)
        _ = try wal.setTruth(node: 1, value: 1)
        let durable = wal.durableDigest()
        let durableBytes = try Data(contentsOf: URL(fileURLWithPath: walPath))
        setenv("DAGDB_FI_FULLFSYNC_FAIL", "1", 1)
        XCTAssertThrowsError(try wal.setTruth(node: 2, value: 1)) {
            XCTAssertTrue("\($0)".contains("F_FULLFSYNC"), "\($0)")
        }
        wal.barrier()
        XCTAssertEqual(wal.durableDigest().length, durable.length, "a failed sync never advances the hash")
        XCTAssertEqual(wal.durableDigest().sha256, durable.sha256)
        XCTAssertEqual(durable.sha256, DagDBHOOK1Era.prefixHash(durableBytes, length: durableBytes.count))
        XCTAssertEqual(DagDBHOOK1Era.logLength(walPath), durable.length, "the record whose sync failed was cut back")
        unsetenv("DAGDB_FI_FULLFSYNC_FAIL")
        XCTAssertThrowsError(try wal.setTruth(node: 3, value: 1), "poisoned until restart")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: walPath)), durableBytes)
        XCTAssertEqual(wal.durableDigest().sha256, durable.sha256)
    }
}
