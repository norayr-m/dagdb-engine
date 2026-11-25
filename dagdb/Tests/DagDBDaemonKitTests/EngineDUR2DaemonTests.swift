import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Two holes in the durable snapshot (SAVE, the autosave, a loader's rebase).
///
/// Recovery is `DAGDB_STARTUP_LOAD` plus the WAL records the snapshot does not
/// hold. Before this fix it took "the records past the last CHECKPOINT", and the
/// checkpoint is appended after the snapshot's rename: (1) a kill between the
/// rename and the checkpoint's fsync recovers the NEW snapshot and replays the
/// records written before it a second time; (2) `durableSnapshot` swallowed a
/// failed checkpoint append (`try?`) and answered a plain OK over the same
/// state on disk. The non-idempotent records then diverge: a relative
/// `SET_LUTS … MAP` (here a rotation, which applied twice is not applied
/// once), a RANK selection, `RECORD SLICE`, `RINGS WRITE`, `CLOCK ADVANCE`,
/// `STREAM NEXT`.
///
/// The claim, every cell: recovery equals the state the reply claimed —
/// a SAVE that replied OK recovers the post-SAVE state (and the records after
/// it); one that never replied (killed) or refused recovers the pre-SAVE state
/// or the post-SAVE state, byte-equal, never a mixture. "Pre" is what recovery
/// gives from a copy of the disk taken just before the command; "post" is the
/// live state right after it. A `TICK` between the base snapshot and the
/// command (TICK writes no WAL record) makes the two differ, so a cell can
/// tell them apart.
///
/// This file uses only API that exists before this fix (the appender's
/// `refuseAppendsForGate` seam), so it runs on the older code too: a log that refuses
/// every append during SAVE is, there, a checkpoint append that fails
/// after the rename. `EngineDUR2DaemonTests+Seams.swift` holds the
/// step-boundary cells (they need the fix's seams).
final class EngineDUR2DaemonTests: XCTestCase {

    typealias E1 = EngineE1DaemonTests

    static let side = 8
    static let maxRank = 16
    static var n: Int { side * side }

    var tmp: String!
    var walPath: String { tmp + "live.wal" }
    var snapPath: String { tmp + "snap.dags" }
    var loadPath: String { tmp + "a.dags" }

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "engine-dur2-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - the live daemon

    /// The twin ids the shape opened.
    struct Twin { var s = "", t = "", r = "", c = "" }

    final class Live {
        let f: HandlerFixture
        var twin = Twin()
        init(_ f: HandlerFixture) { self.f = f }
        var h: DagDBCommandHandler { f.handler }
    }

    func fixture(wal: Bool) throws -> HandlerFixture {
        let f = try HandlerFixture(side: Self.side, dataRoot: tmp,
                                   wal: wal ? try DagDBWAL.Appender(path: walPath, nodeCount: Self.n) : nil,
                                   maxRank: Self.maxRank)
        f.handler.startupSnapshotPath = wal ? snapPath : nil
        return f
    }

    @discardableResult
    func ok(_ f: HandlerFixture, _ line: String, _ prefix: String = "OK",
            file: StaticString = #filePath, l: UInt = #line) -> String {
        let r = f.handler.handle(line)
        XCTAssertTrue(r.hasPrefix(prefix), "\(line) -> \(r)", file: file, line: l)
        return r
    }

    func id(_ reply: String) -> String {
        guard let r = reply.range(of: "id=") else { return "?" }
        return String(reply[r.upperBound...].prefix { !$0.isWhitespace })
    }

    func lutsBulk(_ f: HandlerFixture, _ v: (Int) -> UInt64) {
        for i in 0..<Self.n { f.shm.storeBytes(of: v(i), toByteOffset: 8 + 8 * i, as: UInt64.self) }
        shm1Header(f.shm, count: Self.n, verb: .setLutsBulk)
        ok(f, "SET_LUTS_BULK")
    }

    static let streamLine =
        "STREAM OPEN ref 0x853c49e6748fea9b 0xda3e39cb94b95bdb 0x5851f42d4c957f2d 0x14057b7ef767814f"
    static let recordLine =
        "RECORD OPEN court 1500 0.6827 3000 1.0 0.6827 0.00001 0 0x853c49e6748fea9b 0xda3e39cb94b95bdb 0x5851f42d4c957f2d 0x14057b7ef767814f"

    /// The graph, the twin registries, the base durable snapshot (a full SAVE
    /// to the startup path: bind record + checkpoint), and LOAD's source:
    /// written before the base's TICK (so its bytes differ from the base
    /// snapshot's), or, with `loadEqualsBase`, after the base SAVE (the same
    /// bytes).
    func liveBase(ternary: Bool, seed: UInt64, loadEqualsBase: Bool = false) throws -> Live {
        try? FileManager.default.removeItem(atPath: walPath)
        let live = Live(try fixture(wal: true))
        let f = live.f
        try E1.buildGraph(f.handler.engine, seed: seed, ternary: ternary)
        f.handler.engine.markRankTopologyDirty()
        lutsBulk(f) { UInt64($0 % 4) }
        live.twin.s = id(ok(f, Self.streamLine))
        ok(f, "STREAM NEXT \(live.twin.s) 4")
        live.twin.t = id(ok(f, Self.recordLine))
        ok(f, "RECORD SLICE \(live.twin.t) 3")
        live.twin.r = id(ok(f, "RINGS OPEN 6 4 8"))
        ok(f, "RINGS WRITE \(live.twin.r) 0.5 1.5")
        live.twin.c = id(ok(f, "CLOCK OPEN"))
        ok(f, "CLOCK ADVANCE \(live.twin.c) 5")
        // LOAD's source, through the library (the live WAL gains nothing).
        func writeLoadSource() throws {
            _ = try DagDBSnapshot.save(engine: f.handler.engine, nodeCount: Self.n, gridW: Self.side, gridH: Self.side,
                                       tickCount: f.handler.tickCount, path: loadPath, daemonEnv: .from(envString: nil),
                                       twin: f.handler.twin)
        }
        if !loadEqualsBase { try writeLoadSource() }
        ok(f, "TICK")
        ok(f, "SAVE \(snapPath)", "OK SAVE")
        if loadEqualsBase { try writeLoadSource() }
        return live
    }

    /// The records between the base snapshot and the command under test:
    /// relative and non-idempotent, an absolute write, and a TICK (no record).
    func preRecords(_ live: Live) {
        let f = live.f
        let top = Int(f.handler.engine.readRanks().max()!)
        ok(f, "SET_LUTS NODES 0-\(Self.n - 1) MAP 0x0=0x1 0x1=0x2 0x2=0x3 0x3=0x0")
        ok(f, "SET_LUTS RANK 2-2 MAP 0x1=0x2 0x2=0x1")
        ok(f, "SET_TRUTH RANK \(top)-\(top) FILL 1")
        ok(f, "SET 5 TRUTH 1")
        ok(f, "STREAM NEXT \(live.twin.s) 3")
        ok(f, "RECORD SLICE \(live.twin.t) 5")
        ok(f, "RINGS WRITE \(live.twin.r) 1.5 -2.25 3")
        ok(f, "CLOCK ADVANCE \(live.twin.c) 10000")
        ok(f, "TICK")
        ok(f, "SET_LUTS NODES 0-\(Self.n - 1) MAP 0x0=0x1 0x1=0x2 0x2=0x3 0x3=0x0")
    }

    /// The records after a command that replied.
    func postRecords(_ live: Live) {
        let f = live.f
        ok(f, "SET_LUTS NODES 0-\(Self.n - 1) MAP 0x0=0x1 0x1=0x2 0x2=0x3 0x3=0x0")
        ok(f, "SET_LUTS RANK 3-3 MAP 0x1=0x2 0x2=0x1")
        ok(f, "SET_TRUTH RANK 1-1 FILL 0")
        ok(f, "STREAM NEXT \(live.twin.s) 2")
        ok(f, "RECORD SLICE \(live.twin.t) 7")
        ok(f, "RINGS WRITE \(live.twin.r) 4 5")
        ok(f, "CLOCK ADVANCE \(live.twin.c) 100")
    }

    // MARK: - observing and recovering

    struct Observation: Equatable {
        var files: [String: Data]
        var save: Data
        var ticks: UInt32
        var twin: [String]
    }

    /// Every lane (EXPORT MORTON's files), the snapshot bytes through the
    /// library (lanes, tick count and the whole twin state; the live WAL gains
    /// nothing), the tick count, and the twin replies.
    func observe(_ f: HandlerFixture, _ twin: Twin, _ tag: String) throws -> Observation {
        let dir = tmp + "x_\(tag)_\(UUID().uuidString.prefix(8))"
        _ = try DagDBSnapshot.exportMorton(engine: f.handler.engine, nodeCount: Self.n, dir: dir)
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir) {
            files[name] = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + name))
        }
        let p = dir + ".dags"
        _ = try DagDBSnapshot.save(engine: f.handler.engine, nodeCount: Self.n, gridW: Self.side, gridH: Self.side,
                                   tickCount: f.handler.tickCount, path: p, daemonEnv: .from(envString: nil),
                                   twin: f.handler.twin)
        let h = f.handler
        return Observation(
            files: files, save: try Data(contentsOf: URL(fileURLWithPath: p)), ticks: h.tickCount,
            twin: [h.handle("STREAM STATE \(twin.s)"), h.handle("RECORD INFO \(twin.t)"),
                   h.handle("RINGS INFO \(twin.r)"), h.handle("RINGS RECALL \(twin.r) 0"),
                   h.handle("RINGS RECALL \(twin.r) 2"), h.handle("CLOCK STATE \(twin.c)")])
    }

    func mismatch(_ a: Observation, _ b: Observation) -> [String] {
        var m = Set(a.files.keys).union(b.files.keys).filter { a.files[$0] != b.files[$0] }.sorted()
        if a.save != b.save { m.append("SAVE bytes") }
        if a.ticks != b.ticks { m.append("ticks") }
        for (k, (x, y)) in zip(a.twin, b.twin).enumerated() where x != y { m.append("twin[\(k)]") }
        return m
    }

    struct Recovery {
        var obs: Observation?
        var result: DagDBStartup.Result?
        var error: String?
        var lines: [String]
    }

    /// The daemon's startup (main.swift's order) over a fresh engine, from
    /// the given snapshot and WAL.
    func recover(snapshot: String, wal: String, _ twin: Twin, _ tag: String) throws -> Recovery {
        let g = try fixture(wal: false)
        var lines: [String] = []
        do {
            let r = try DagDBStartup.recover(
                engine: g.handler.engine, nodeCount: Self.n, width: Self.side, height: Self.side,
                dagdbEnv: nil, dataRoot: tmp, twin: g.handler.twin, truthRankIndex: g.handler.truthRankIndex,
                snapshotPath: snapshot, walPath: wal, log: { lines.append($0) })
            XCTAssertNil(r.replayError, tag)
            g.handler.tickCount = r.tickCount
            return Recovery(obs: try observe(g, twin, tag), result: r, error: nil, lines: lines)
        } catch {
            return Recovery(obs: nil, result: nil, error: "\(error)", lines: lines)
        }
    }

    /// Recovery from a copy of the disk as it is now (the snapshot, its
    /// manifest, the WAL): the "pre" reference, taken before the command.
    func recoverFromCopy(_ twin: Twin, _ tag: String) throws -> Recovery {
        let d = tmp + "copy_\(tag)_\(UUID().uuidString.prefix(8))/"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        let fm = FileManager.default
        try fm.copyItem(atPath: snapPath, toPath: d + "snap.dags")
        if fm.fileExists(atPath: snapPath + ".sha256") {
            try fm.copyItem(atPath: snapPath + ".sha256", toPath: d + "snap.dags.sha256")
        }
        try fm.copyItem(atPath: walPath, toPath: d + "live.wal")
        return try recover(snapshot: d + "snap.dags", wal: d + "live.wal", twin, tag + "_pre")
    }

    /// A plain OK: the reply a SAVE gives when everything it promises held.
    static func isPlainOK(_ reply: String) -> Bool {
        reply.hasPrefix("OK") && !reply.contains("WARN") && !reply.contains("ERROR")
    }

    // MARK: - The failed checkpoint append, on the older code's own API: a log that refuses during SAVE

    /// The appender refuses every append while SAVE runs. On the older code that is
    /// a checkpoint append failing after the rename, swallowed: the reply is
    /// a plain OK and recovery replays the records before the SAVE onto the
    /// new snapshot. The claim: the reply names the failure, and recovery
    /// equals the state it claimed (OK: post; anything else: pre or post).
    func testDUR22ALogThatRefusesDuringSaveIsNamedAndRecovers() throws {
        var cells = 0
        for ternary in [false, true] {
            let label = ternary ? "ternary" : "binary"
            let live = try liveBase(ternary: ternary, seed: 0xD2A0 + (ternary ? 1 : 0))
            preRecords(live)
            let pre = try recoverFromCopy(live.twin, "pre_\(label)")
            let snapBefore = try Data(contentsOf: URL(fileURLWithPath: snapPath))
            let wal = try XCTUnwrap(live.h.walAppender)
            wal.refuseAppendsForGate = true
            let reply = live.h.handle("SAVE \(snapPath)")
            wal.refuseAppendsForGate = false
            let post = try observe(live.f, live.twin, "post_\(label)")
            let rec = try recover(snapshot: snapPath, wal: walPath, live.twin, "rec_\(label)")
            let preObs = try XCTUnwrap(pre.obs, "\(label): pre recovery: \(pre.error ?? "")")
            XCTAssertNotEqual(mismatch(preObs, post), [], "\(label): pre and post must differ (the TICK)")
            XCTAssertFalse(Self.isPlainOK(reply), "\(label): a refused append must be named: \(reply)")
            let snapAfter = try Data(contentsOf: URL(fileURLWithPath: snapPath))
            let got = try XCTUnwrap(rec.obs, "\(label): recovery failed: \(rec.error ?? "")")
            let vsPre = mismatch(preObs, got), vsPost = mismatch(post, got)
            if reply.hasPrefix("OK") {
                XCTAssertEqual(vsPost, [], "\(label): replied OK, recovered != post")
            } else {
                XCTAssertTrue(vsPre.isEmpty || vsPost.isEmpty,
                              "\(label): recovered is a mixture: vs pre \(vsPre), vs post \(vsPost)")
            }
            print("DUR2.2 refusing log \(label): reply=\(reply.prefix(140)) snapshot_changed=\(snapAfter != snapBefore) "
                  + "rec_vs_pre=\(vsPre) rec_vs_post=\(vsPost) "
                  + "replayed=\(rec.result?.replay?.recordsAfterCheckpoint ?? -1) lines=\(rec.lines)")
            cells += 1
        }
        XCTAssertEqual(cells, 2)
    }
}
