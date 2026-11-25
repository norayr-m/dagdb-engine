import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Every loader that replaces the engine's state leaves the WAL consistent.
///
/// Recovery is `DAGDB_STARTUP_LOAD` (the last SAVE) plus the WAL records past
/// the last checkpoint. LOAD, LOAD JSON, LOAD CSV and BACKUP RESTORE wrote no
/// record, so recovery rebuilt on the snapshot from before the load, and the
/// relative records that followed (SET_LUTS MAP, a RANK selection, SET_TRUTH
/// RANK FILL) landed on the wrong base. The fix: with the WAL on and a startup
/// snapshot path configured, a successful load ends with SAVE's own durable
/// snapshot to that path plus a WAL checkpoint, so recovery restarts from the
/// loaded state. IMPORT MORTON already logs its bytes.
///
/// The check (in-process; the kill -9 of a real daemon is the live harness):
/// the shape load → relative G verbs + absolute writers → restart through
/// `DagDBStartup.recover` recovers every lane (EXPORT MORTON's files), the
/// truth, the twin and the SAVE bytes equal to live, for every loader, binary
/// and ternary.
final class EngineDUR1DaemonTests: XCTestCase {

    typealias E1 = EngineE1DaemonTests

    static let side = 8
    static let maxRank = 16

    private var tmp: String!
    private var walPath: String { tmp + "live.wal" }
    private var snapPath: String { tmp + "snap.dags" }

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "engine-dur1-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    /// The loaders, each with the command that writes its source at state A
    /// and the command that loads it.
    static let loaders: [(name: String, source: (String) -> String, load: (String) -> String)] = [
        ("LOAD", { "SAVE \($0)a.dags" }, { "LOAD \($0)a.dags" }),
        ("LOAD JSON", { "SAVE JSON \($0)a.json" }, { "LOAD JSON \($0)a.json" }),
        ("LOAD CSV", { "SAVE CSV \($0)a_csv" }, { "LOAD CSV \($0)a_csv" }),
        ("BACKUP RESTORE", { "BACKUP INIT \($0)a_bak" }, { "BACKUP RESTORE \($0)a_bak" }),
        ("IMPORT MORTON", { "EXPORT MORTON \($0)a_mx" }, { "IMPORT MORTON \($0)a_mx" }),
    ]

    func fixture(wal: Bool, startup: String?) throws -> HandlerFixture {
        let n = Self.side * Self.side
        let f = try HandlerFixture(side: Self.side, dataRoot: tmp,
                                   wal: wal ? try DagDBWAL.Appender(path: walPath, nodeCount: n) : nil,
                                   maxRank: Self.maxRank)
        f.handler.startupSnapshotPath = startup
        return f
    }

    @discardableResult
    func ok(_ f: HandlerFixture, _ line: String, _ prefix: String = "OK",
            file: StaticString = #filePath, l: UInt = #line) -> String {
        let r = f.handler.handle(line)
        XCTAssertTrue(r.hasPrefix(prefix), "\(line) -> \(r)", file: file, line: l)
        return r
    }

    func lutsBulk(_ f: HandlerFixture, _ v: (Int) -> UInt64) {
        for i in 0..<(Self.side * Self.side) { f.shm.storeBytes(of: v(i), toByteOffset: 8 + 8 * i, as: UInt64.self) }
        shm1Header(f.shm, count: Self.side * Self.side, verb: .setLutsBulk)
        ok(f, "SET_LUTS_BULK")
    }

    func truthBulk(_ f: HandlerFixture, _ rows: [(UInt32, UInt8)]) {
        f.shm.storeBytes(of: UInt32(rows.count), toByteOffset: 0, as: UInt32.self)
        f.shm.storeBytes(of: shm1Word1(.setTruthBulk), toByteOffset: 4, as: UInt32.self)
        for (i, (node, v)) in rows.enumerated() {
            f.shm.storeBytes(of: node, toByteOffset: 8 + 8 * i, as: UInt32.self)
            f.shm.storeBytes(of: UInt32(v), toByteOffset: 8 + 8 * i + 4, as: UInt32.self)   // u8 value + 3 zero pad bytes
        }
        ok(f, "SET_TRUTH_BULK")
    }

    struct Observation: Equatable {
        var files: [String: Data]
        var save: Data
        var ticks: UInt32
        var clock: String
    }

    /// EXPORT MORTON's files, through the library.
    func lanes(_ f: HandlerFixture, _ tag: String) throws -> [String: Data] {
        let dir = tmp + "x_\(tag)"
        try? FileManager.default.removeItem(atPath: dir)
        _ = try DagDBSnapshot.exportMorton(engine: f.handler.engine, nodeCount: Self.side * Self.side, dir: dir)
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir) {
            files[name] = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + name))
        }
        return files
    }

    /// Every lane (EXPORT MORTON's files), the snapshot bytes (as SAVE writes
    /// them, through the library so the live WAL gains no checkpoint), the
    /// tick count and the twin clock.
    func observe(_ f: HandlerFixture, _ tag: String) throws -> Observation {
        let n = Self.side * Self.side
        let files = try lanes(f, tag)
        let p = tmp + "save_\(tag).dags"
        _ = try DagDBSnapshot.save(engine: f.handler.engine, nodeCount: n, gridW: Self.side, gridH: Self.side,
                                   tickCount: f.handler.tickCount, path: p, daemonEnv: .from(envString: nil),
                                   twin: f.handler.twin)
        return Observation(files: files, save: try Data(contentsOf: URL(fileURLWithPath: p)),
                           ticks: f.handler.tickCount, clock: f.handler.handle("CLOCK STATE c00000001"))
    }

    struct Shape {
        var reply: String
        var live: Observation
        var rec: Observation
        var stateA: [String: Data]       // after the source was written
        var stateA2: [String: Data]      // the startup snapshot's state
        var afterLoad: [String: Data]    // right after the loader
    }

    /// The shape, on a live handler.
    func shape(_ loader: Int, ternary: Bool, seed: UInt64, startup: String?) throws -> Shape {
        let n = Self.side * Self.side
        let (_, source, load) = Self.loaders[loader]
        try? FileManager.default.removeItem(atPath: walPath)
        try? FileManager.default.removeItem(atPath: snapPath)
        let f = try fixture(wal: true, startup: startup)
        try E1.buildGraph(f.handler.engine, seed: seed, ternary: ternary)
        f.handler.engine.markRankTopologyDirty()
        ok(f, "CLOCK OPEN")
        // State A, and the loader's source written at A.
        lutsBulk(f) { UInt64($0 % 4) }
        truthBulk(f, stride(from: 0, to: n, by: 5).map { (UInt32($0), UInt8(($0 * 7 + 1) % 2)) })
        ok(f, source(tmp))
        let stateA = try lanes(f, "A")
        // State A': every rank + 1 (the order kept), the LUTs shifted, truth on a stride, the clock advanced.
        let r = f.handler.engine.readRanks()
        for i in 0..<n { f.shm.storeBytes(of: r[i] + 1, toByteOffset: 8 + 8 * i, as: UInt64.self) }
        shm1Header(f.shm, count: n, verb: .setRanksBulk)
        ok(f, "SET_RANKS_BULK")
        lutsBulk(f) { UInt64(($0 + 1) % 4) }
        truthBulk(f, stride(from: 0, to: n, by: 3).map { (UInt32($0), UInt8(($0 * 7) % 2)) })
        ok(f, "CLOCK ADVANCE c00000001 5")
        ok(f, "SAVE \(snapPath)", "OK SAVE")
        let stateA2 = try lanes(f, "A2")
        // The loader: live := A.
        let reply = f.handler.handle(load(tmp))
        let afterLoad = try lanes(f, "L")
        // Relative G verbs, then absolute writers.
        let top = Int(f.handler.engine.readRanks().max()!)
        ok(f, "SET_LUTS NODES 0-\(n - 1) MAP 0x0=0x10 0x1=0x11")
        ok(f, "SET_LUTS RANK \(top)-\(top) FILL 0x2a")
        ok(f, "SET_TRUTH RANK \(top)-\(top) FILL 1")
        ok(f, "SET_LUTS RANK 2-3 MAP 0x2=0x22")
        truthBulk(f, stride(from: 1, to: n, by: 7).map { (UInt32($0), 1) })
        ok(f, "SET \(n / 2) TRUTH 0")
        ok(f, "CLOCK ADVANCE c00000001 7")
        let live = try observe(f, "live")
        // The restart: main.swift's order over a fresh engine.
        let g = try fixture(wal: false, startup: nil)
        let res = try DagDBStartup.recover(
            engine: g.handler.engine, nodeCount: n, width: Self.side, height: Self.side,
            dagdbEnv: nil, dataRoot: tmp, twin: g.handler.twin, truthRankIndex: g.handler.truthRankIndex,
            snapshotPath: snapPath, walPath: walPath, log: { _ in })
        XCTAssertNil(res.replayError)
        g.handler.tickCount = res.tickCount
        return Shape(reply: reply, live: live, rec: try observe(g, "rec"),
                     stateA: stateA, stateA2: stateA2, afterLoad: afterLoad)
    }

    func mismatch(_ a: Observation, _ b: Observation) -> [String] {
        var m = Set(a.files.keys).union(b.files.keys).filter { a.files[$0] != b.files[$0] }.sorted()
        if a.save != b.save { m.append("SAVE bytes") }
        if a.ticks != b.ticks { m.append("ticks") }
        if a.clock != b.clock { m.append("clock") }
        return m
    }

    // MARK: - Every loader, binary and ternary

    func testDUR1EveryLoaderRecoversEqualToLive() throws {
        var cells = 0
        for (k, l) in Self.loaders.enumerated() {
            for ternary in [false, true] {
                let sh = try shape(k, ternary: ternary, seed: 0xD0E1 + UInt64(k), startup: snapPath)
                let (reply, live, rec) = (sh.reply, sh.live, sh.rec)
                let label = "\(l.name) \(ternary ? "ternary" : "binary")"
                XCTAssertTrue(reply.hasPrefix("OK"), "\(label): \(reply)")
                if l.name != "IMPORT MORTON" {
                    XCTAssertTrue(Reply.withoutVolatile(reply).hasSuffix(" wal_base=\"\(snapPath)\""), "\(label): \(reply)")
                }
                XCTAssertEqual(mismatch(live, rec), [], "\(label): recovered != live")
                XCTAssertEqual(live.files.count, rec.files.count, label)
                cells += 1
                print("DUR1.1 \(label): \(reply.prefix(60)) … mismatches=\(mismatch(live, rec).count)")
            }
        }
        XCTAssertEqual(cells, 10)
    }

    /// The shape sees the loader: right after it the lanes it carries are
    /// state A's, and the startup snapshot's state A' differs from A in every
    /// one of those lanes but neighbors, so an equal recovery cannot come from
    /// a base that was never moved.
    func testDUR1TheShapeSeesTheLoader() throws {
        for (k, l) in Self.loaders.enumerated() {
            let sh = try shape(k, ternary: k % 2 == 1, seed: 0xD0F1 + UInt64(k), startup: snapPath)
            for lane in ["rank.bin", "lut_low.bin", "lut_high.bin", "truth.bin", "neighbors.bin"] {
                XCTAssertEqual(sh.afterLoad[lane], sh.stateA[lane], "\(l.name): \(lane) after the loader is A's")
            }
            for lane in ["rank.bin", "lut_low.bin", "truth.bin"] {
                XCTAssertNotEqual(sh.stateA[lane], sh.stateA2[lane], "\(l.name): \(lane) differs between A and A'")
            }
            XCTAssertEqual(sh.live, sh.rec, l.name)
        }
    }

    // MARK: - the readings: no startup path, no WAL, a snapshot that fails

    /// With the WAL on and no startup snapshot path, recovery has no snapshot
    /// base at all (the log alone never recovered a SAVE or a TICK); the
    /// loaders are refused there before any change, the
    /// remedy named: no snapshot, no checkpoint, no record.
    func testDUR1WithoutAStartupPathTheLoaderIsRefused() throws {
        for (name, source, load) in Self.loaders.dropLast() {
            try? FileManager.default.removeItem(atPath: walPath)
            let f = try fixture(wal: true, startup: nil)
            try E1.buildGraph(f.handler.engine, seed: 0xD1, ternary: false)
            ok(f, source(tmp))
            let before = try Data(contentsOf: URL(fileURLWithPath: walPath))
            let r = ok(f, load(tmp), "ERROR wal: \(name) refused")
            XCTAssertTrue(r.contains("set DAGDB_STARTUP_LOAD"), r)
            XCTAssertFalse(r.contains("wal_base="), r)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: walPath)), before, "no record, no checkpoint: \(r)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: snapPath))
        }
    }

    /// With the WAL off the loaders are unchanged even when a startup path is set.
    func testDUR1WithTheWALOffTheLoaderIsUnchanged() throws {
        for (_, source, load) in Self.loaders.dropLast() {
            let f = try fixture(wal: false, startup: snapPath)
            try E1.buildGraph(f.handler.engine, seed: 0xD2, ternary: false)
            ok(f, source(tmp))
            let r = ok(f, load(tmp))
            XCTAssertFalse(r.contains("wal_base="), r)
            XCTAssertFalse(FileManager.default.fileExists(atPath: snapPath))
        }
    }

    /// A durable snapshot that cannot be written after a successful load is
    /// named: the state is loaded, the WAL is not rebased, and the reply says
    /// a restart would recover the state from before the load.
    func testDUR1AFailedDurableSnapshotIsNamed() throws {
        for (name, source, load) in Self.loaders.dropLast() {
            try? FileManager.default.removeItem(atPath: walPath)
            let blocked = tmp + "no_such_dir/snap.dags"
            let f = try fixture(wal: true, startup: blocked)      // its directory does not exist: the snapshot cannot be written
            try E1.buildGraph(f.handler.engine, seed: 0xD3, ternary: false)
            ok(f, source(tmp))
            let r = f.handler.handle(load(tmp))
            XCTAssertTrue(r.hasPrefix("ERROR wal: \(name) loaded the state, but its durable snapshot to \(blocked) failed"), r)
            XCTAssertTrue(r.contains("a restart would recover the state from before \(name)"), r)
        }
    }
}
