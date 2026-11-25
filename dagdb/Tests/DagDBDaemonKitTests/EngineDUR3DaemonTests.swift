import XCTest
import Darwin
@testable import DagDB
@testable import DagDBDaemonKit

/// Two durability holes of the durable snapshot, found by a live check and
/// tested here in-process. (The third, SIGTERM mid-command, is checked live
/// against a running daemon; its shutdown gate, `DagDBShutdownGate`, has a unit test in `EngineDUR3DaemonTests+Shutdown.swift`.)
///
/// A torn append. A WAL record is `u32 length + opcode + payload`,
/// appended with `write(2)`. A record cut by a crash (a kill after k of its
/// bytes) or by a failed write (write(2) wrote k bytes and failed) must never
/// be half-applied, and the records after it must replay correctly. Before
/// this fix the cut bytes stayed in the file and the next record was appended
/// after them, inside the torn record's declared length: the next replay
/// read the torn record over the later records' bytes (applied with garbage,
/// or skipped as a bad length) and walked on misaligned.
///
/// Both cuts are made with the older code's own API, at EVERY byte offset k of the
/// record (strided for the import records, which are kilobytes):
/// - crash: the command runs whole, then the log is truncated to the
///   record's first k bytes — exactly the file a kill after k bytes leaves
///   (`write(2)` puts the bytes in the file; nothing else touches it). For
///   the snapshot's bind record (written before the rename) the old snapshot
///   and its manifest are put back, as the kill leaves them. Then a restart
///   (recovery, then a new appender on the same log, main.swift's order), a
///   non-idempotent record mix, and a second restart.
/// - failed write: `RLIMIT_FSIZE` set to the record's start + k, so the
///   appender's own `write(2)` writes k bytes and fails with EFBIG — a real
///   failed write, not a seam. The command is refused (or, for the
///   checkpoint, named in a WARN); the same daemon goes on with the mix;
///   then a restart.
///
/// The claim, every cell: the first restart equals the live state before
/// the command (the cut record was never acknowledged); the last restart
/// equals the live state the replies claimed, and its replay is clean — no
/// record skipped, refused or truncated (a misaligned walk is never clean).
/// Record kinds: SET TRUTH (0x01), SET_LUTS MAP (0x4F), SET_TRUTH_BULK
/// (0x4E), SET_LUTS_BULK (0x15, a bulk lane), RINGS WRITE (0x25, a twin
/// record), SAVE's SNAPSHOT_BIND (0x51) and CHECKPOINT (0xF0), IMPORT
/// MORTON as one record (0x4C, written in pieces) and as a group of
/// IMPORT_PART records closed by one IMPORT_MORTON (the import's chunk size
/// lowered; the group is the unit: a cut anywhere in it).
///
/// No snapshot loaded. With `DAGDB_STARTUP_LOAD` set but never
/// written (or not set), recovery runs over an empty engine; before this fix it
/// still honoured the last checkpoint (or bind record) a SAVE to ANOTHER
/// path left, and replayed only the records after it. The claim: recovery
/// equals the live state (every logged record replayed).
final class EngineDUR3DaemonTests: XCTestCase {

    typealias E1 = EngineE1DaemonTests

    static let side = 4
    static let maxRank = 16
    static var n: Int { side * side }

    var tmp: String!
    var walPath: String { tmp + "live.wal" }
    var snapPath: String { tmp + "snap.dags" }

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "engine-dur3-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - the live daemon

    struct Twin { var s = "", r = "", c = "" }

    func fixture(wal: Bool, startup: Bool = true) throws -> HandlerFixture {
        let f = try HandlerFixture(side: Self.side, dataRoot: tmp,
                                   wal: wal ? try DagDBWAL.Appender(path: walPath, nodeCount: Self.n) : nil,
                                   maxRank: Self.maxRank)
        f.handler.startupSnapshotPath = wal && startup ? snapPath : nil
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

    func putLuts(_ f: HandlerFixture, _ v: (Int) -> UInt64) {
        for i in 0..<Self.n { f.shm.storeBytes(of: v(i), toByteOffset: 8 + 8 * i, as: UInt64.self) }
        shm1Header(f.shm, count: Self.n, verb: .setLutsBulk)
    }

    func putTruthRows(_ f: HandlerFixture, _ rows: [(UInt32, UInt8)]) {
        f.shm.storeBytes(of: UInt32(rows.count), toByteOffset: 0, as: UInt32.self)
        f.shm.storeBytes(of: shm1Word1(.setTruthBulk), toByteOffset: 4, as: UInt32.self)
        for (i, (node, v)) in rows.enumerated() {
            f.shm.storeBytes(of: node, toByteOffset: 8 + 8 * i, as: UInt32.self)
            f.shm.storeBytes(of: UInt32(v), toByteOffset: 8 + 8 * i + 4, as: UInt32.self)
        }
    }

    static let streamLine =
        "STREAM OPEN ref 0x853c49e6748fea9b 0xda3e39cb94b95bdb 0x5851f42d4c957f2d 0x14057b7ef767814f"

    func openTwin(_ f: HandlerFixture) -> Twin {
        var t = Twin()
        t.s = id(ok(f, Self.streamLine))
        ok(f, "STREAM NEXT \(t.s) 4")
        t.r = id(ok(f, "RINGS OPEN 6 4 8"))
        ok(f, "RINGS WRITE \(t.r) 0.5 1.5")
        t.c = id(ok(f, "CLOCK OPEN"))
        ok(f, "CLOCK ADVANCE \(t.c) 5")
        return t
    }

    /// The base: the graph, `pad` SET_LUTS_BULK records (absolute; they make
    /// the log longer than a snapshot, so the failed-write cells of SAVE's
    /// records can cut the log without cutting the snapshot file), the twin
    /// registries, and the durable snapshot at the startup path.
    func base(ternary: Bool, seed: UInt64, pad: Int = 0) throws -> (HandlerFixture, Twin) {
        for p in [walPath, snapPath, snapPath + ".sha256"] { try? FileManager.default.removeItem(atPath: p) }
        let f = try fixture(wal: true)
        try E1.buildGraph(f.handler.engine, seed: seed, ternary: ternary)
        f.handler.engine.markRankTopologyDirty()
        for p in 0..<pad { putLuts(f) { UInt64(($0 + p) % 4) }; ok(f, "SET_LUTS_BULK") }
        putLuts(f) { UInt64($0 % 4) }
        ok(f, "SET_LUTS_BULK")
        let t = openTwin(f)
        ok(f, "SAVE \(snapPath)", "OK SAVE")
        return (f, t)
    }

    /// A non-idempotent record mix: a LUT rotation (twice is not once), a
    /// RANK swap, a FILL, a SET, a SET_TRUTH_BULK, three twin records.
    func mix(_ f: HandlerFixture, _ t: Twin, _ round: Int) {
        let n = Self.n
        let top = Int(f.handler.engine.readRanks().max()!)
        ok(f, "SET_LUTS NODES 0-\(n - 1) MAP 0x0=0x1 0x1=0x2 0x2=0x3 0x3=0x0")
        ok(f, "SET_LUTS RANK 2-2 MAP 0x1=0x2 0x2=0x1")
        ok(f, "SET_TRUTH RANK \(top)-\(top) FILL \(round % 2)")
        ok(f, "SET \((round * 5) % n) TRUTH 1")
        putTruthRows(f, [(UInt32((round + 3) % n), 1), (UInt32((round + 6) % n), 0), (UInt32((round + 9) % n), 1)])
        ok(f, "SET_TRUTH_BULK")
        ok(f, "STREAM NEXT \(t.s) 3")
        ok(f, "RINGS WRITE \(t.r) 1.5 -2.25 \(round)")
        ok(f, "CLOCK ADVANCE \(t.c) 10000")
        ok(f, "SET_LUTS NODES 0-\(n - 1) MAP 0x0=0x1 0x1=0x2 0x2=0x3 0x3=0x0")
    }

    // MARK: - observing and recovering

    struct Observation: Equatable {
        var files: [String: Data]
        var save: Data
        var ticks: UInt32
        var twin: [String]
    }

    func observe(_ f: HandlerFixture, _ t: Twin) throws -> Observation {
        let dir = tmp + "x_\(UUID().uuidString.prefix(8))"
        _ = try DagDBSnapshot.exportMorton(engine: f.handler.engine, nodeCount: Self.n, dir: dir)
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir) {
            files[name] = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + name))
        }
        let p = dir + ".dags"
        _ = try DagDBSnapshot.save(engine: f.handler.engine, nodeCount: Self.n, gridW: Self.side, gridH: Self.side,
                                   tickCount: f.handler.tickCount, path: p, daemonEnv: .from(envString: nil),
                                   twin: f.handler.twin)
        let save = try Data(contentsOf: URL(fileURLWithPath: p))
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.removeItem(atPath: p)
        try? FileManager.default.removeItem(atPath: p + ".sha256")
        let h = f.handler
        return Observation(
            files: files, save: save, ticks: h.tickCount,
            twin: [h.handle("STREAM STATE \(t.s)"), h.handle("RINGS INFO \(t.r)"),
                   h.handle("RINGS RECALL \(t.r) 0"), h.handle("RINGS RECALL \(t.r) 2"),
                   h.handle("CLOCK STATE \(t.c)")])
    }

    func mismatch(_ a: Observation, _ b: Observation) -> [String] {
        var m = Set(a.files.keys).union(b.files.keys).filter { a.files[$0] != b.files[$0] }.sorted()
        if a.save != b.save { m.append("SAVE bytes") }
        if a.ticks != b.ticks { m.append("ticks") }
        for (k, (x, y)) in zip(a.twin, b.twin).enumerated() where x != y { m.append("twin[\(k)]") }
        return m
    }

    /// The daemon's start (main.swift's order) over a fresh engine: recovery
    /// from the startup snapshot and the log; with `attach`, then a new
    /// appender on the same log — the restarted daemon.
    func restart(snapshot: String?, attach: Bool) throws -> (HandlerFixture, DagDBStartup.Result, [String]) {
        let g = try fixture(wal: false)
        var lines: [String] = []
        let r = try DagDBStartup.recover(
            engine: g.handler.engine, nodeCount: Self.n, width: Self.side, height: Self.side,
            dagdbEnv: nil, dataRoot: tmp, twin: g.handler.twin, truthRankIndex: g.handler.truthRankIndex,
            snapshotPath: snapshot, walPath: walPath, log: { lines.append($0) })
        XCTAssertNil(r.replayError)
        g.handler.tickCount = r.tickCount
        if attach {
            g.handler.walAppender = try DagDBWAL.Appender(path: walPath, nodeCount: Self.n)
            g.handler.startupSnapshotPath = snapshot
        }
        return (g, r, lines)
    }

    /// A replay that walked every record whole: nothing skipped, refused or
    /// truncated. A misaligned walk is never clean.
    static func clean(_ r: DagDBStartup.Result) -> Bool {
        guard let p = r.replay else { return false }
        return p.recordsSkipped == 0 && p.refusals.isEmpty && p.truncatedAtOffset == nil
    }

    static func size(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? -1
    }

    // MARK: - A torn append: the record kinds

    enum Kind: String, CaseIterable {
        case setTruth = "SET TRUTH 0x01"
        case map = "SET_LUTS MAP 0x4F"
        case truthBulk = "SET_TRUTH_BULK 0x4E"
        case lutsBulk = "SET_LUTS_BULK 0x15"
        case rings = "RINGS WRITE 0x25"
        case bind = "SAVE SNAPSHOT_BIND 0x51"
        case checkpoint = "SAVE CHECKPOINT 0xF0"
        case importOne = "IMPORT MORTON 0x4C"
        case importGroup = "IMPORT_PART group 0x4B-0x4C"

        var isSave: Bool { self == .bind || self == .checkpoint }
        var isImport: Bool { self == .importOne || self == .importGroup }
    }

    /// The import sources (exported from scratch engines) for the import kinds.
    var importDirs: [Bool: (String, String)] = [:]

    func importSources(ternary: Bool) throws -> (String, String) {
        if let d = importDirs[ternary] { return d }
        var out: [String] = []
        for (k, seed) in [UInt64(0xD3A1), 0xD3A2].enumerated() {
            let g = try fixture(wal: false)
            try E1.buildGraph(g.handler.engine, seed: seed + (ternary ? 16 : 0), ternary: ternary)
            let dir = tmp + "imp_\(ternary ? "t" : "b")\(k)"
            _ = try DagDBSnapshot.exportMorton(engine: g.handler.engine, nodeCount: Self.n, dir: dir)
            out.append(dir)
        }
        importDirs[ternary] = (out[0], out[1])
        return (out[0], out[1])
    }

    /// The import kinds' chunk size for the group: several IMPORT_PART
    /// records and the closing IMPORT_MORTON.
    static let groupChunkBytes = 300

    func withChunk<T>(_ kind: Kind, _ body: () throws -> T) rethrows -> T {
        guard kind == .importGroup else { return try body() }
        let old = DagDBWAL.importChunkBytes
        DagDBWAL.importChunkBytes = Self.groupChunkBytes
        defer { DagDBWAL.importChunkBytes = old }
        return try body()
    }

    /// The command under test.
    func issue(_ kind: Kind, _ f: HandlerFixture, _ t: Twin, ternary: Bool) throws -> String {
        let n = Self.n
        switch kind {
        case .setTruth: return f.handler.handle("SET 7 TRUTH 1")
        case .map: return f.handler.handle("SET_LUTS NODES 0-\(n - 1) MAP 0x0=0x1 0x1=0x2 0x2=0x3 0x3=0x0")
        case .truthBulk:
            putTruthRows(f, (0..<6).map { (UInt32((3 * $0 + 1) % n), UInt8($0 % 2)) })
            return f.handler.handle("SET_TRUTH_BULK")
        case .lutsBulk:
            putLuts(f) { UInt64(0x0123_4567_89AB_CDEF) &* UInt64($0 + 1) }
            return f.handler.handle("SET_LUTS_BULK")
        case .rings: return f.handler.handle("RINGS WRITE \(t.r) 7.25 -0.5 3")
        case .bind, .checkpoint: return f.handler.handle("SAVE \(snapPath)")
        case .importOne, .importGroup:
            let dir = try importSources(ternary: ternary).0
            return withChunk(kind) { f.handler.handle("IMPORT MORTON \(dir)") }
        }
    }

    /// The records after the cut command (the second restart's subject). For
    /// the import kinds a second import first (as a group for the group kind:
    /// parts left behind by the cut one would be staged into it), then the mix.
    func after(_ kind: Kind, _ f: HandlerFixture, _ t: Twin, ternary: Bool) throws {
        if kind.isImport {
            let dir = try importSources(ternary: ternary).1
            let r = withChunk(kind) { f.handler.handle("IMPORT MORTON \(dir)") }
            XCTAssertTrue(r.hasPrefix("OK IMPORT"), r)
        }
        mix(f, t, 2)
    }

    /// The bytes of the unit cut: [start, start + len) of the log, from its
    /// size before (`s0`) and after (`s1`) the command.
    static func unit(_ kind: Kind, _ s0: Int, _ s1: Int) -> (start: Int, len: Int) {
        switch kind {
        case .bind: return (s0, 45)
        case .checkpoint: return (s0 + 45, 13)
        default: return (s0, s1 - s0)
        }
    }

    /// Every offset, or (the import records, kilobytes) the first 64, every
    /// 23rd, each record boundary ± 1 and the last 8.
    func offsets(_ kind: Kind, len: Int, boundaries: [Int]) -> [Int] {
        guard kind.isImport else { return Array(0..<len) }
        var s = Set(0..<min(64, len))
        s.formUnion(stride(from: 0, to: len, by: 23))
        for b in boundaries { for d in -1...1 where b + d >= 0 && b + d < len { s.insert(b + d) } }
        s.formUnion(max(0, len - 8)..<len)
        return s.sorted()
    }

    /// The record boundaries inside [start, start + len) of the log.
    static func boundaries(_ path: String, _ start: Int, _ len: Int) throws -> [Int] {
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        var out: [Int] = []
        var off = start
        while off + 5 <= start + len {
            out.append(off - start)
            let l = Int(d[off]) | Int(d[off + 1]) << 8 | Int(d[off + 2]) << 16 | Int(d[off + 3]) << 24
            off += 5 + l
        }
        return out
    }

    struct Tally {
        var cells = 0, ok = 0
        var failures: [String] = []
        mutating func add(_ good: Bool, _ why: @autoclosure () -> String) {
            cells += 1
            if good { ok += 1 } else if failures.count < 6 { failures.append(why()) }
        }
    }

    /// The shape of a kind: the unit's length and record boundaries (one run).
    func probe(_ kind: Kind, ternary: Bool, seed: UInt64) throws -> (len: Int, boundaries: [Int]) {
        let (f, t) = try base(ternary: ternary, seed: seed)
        mix(f, t, 1)
        let s0 = Self.size(walPath)
        let reply = try issue(kind, f, t, ternary: ternary)
        XCTAssertTrue(reply.hasPrefix("OK"), "\(kind.rawValue): \(reply)")
        let u = Self.unit(kind, s0, Self.size(walPath))
        return (u.len, try Self.boundaries(walPath, u.start, u.len))
    }

    /// A crash after k bytes of the unit.
    func crashCell(_ kind: Kind, ternary: Bool, seed: UInt64, k: Int) throws -> (Bool, String) {
        let (f, t) = try base(ternary: ternary, seed: seed)
        mix(f, t, 1)
        let before = try observe(f, t)
        let s0 = Self.size(walPath)
        var old: (Data, Data)? = nil
        if kind == .bind {
            old = (try Data(contentsOf: URL(fileURLWithPath: snapPath)),
                   try Data(contentsOf: URL(fileURLWithPath: snapPath + ".sha256")))
        }
        let reply = try issue(kind, f, t, ternary: ternary)
        guard reply.hasPrefix("OK") else { return (false, "k=\(k): the command failed whole: \(reply)") }
        let u = Self.unit(kind, s0, Self.size(walPath))
        f.handler.walAppender = nil                       // the process is gone
        guard truncate(walPath, off_t(u.start + k)) == 0 else { return (false, "truncate errno \(errno)") }
        if let (snap, man) = old {                        // killed before the rename
            try snap.write(to: URL(fileURLWithPath: snapPath))
            try man.write(to: URL(fileURLWithPath: snapPath + ".sha256"))
        }
        let (g, r1, _) = try restart(snapshot: snapPath, attach: true)
        let m1 = mismatch(before, try observe(g, t))
        try after(kind, g, t, ternary: ternary)
        let live = try observe(g, t)
        let (h, r2, lines) = try restart(snapshot: snapPath, attach: false)
        let m2 = mismatch(live, try observe(h, t))
        let good = m1.isEmpty && m2.isEmpty && Self.clean(r2)
        let p = r2.replay
        return (good, "k=\(k): first restart vs before \(m1), second restart vs live \(m2), "
                + "replayed=\(p?.recordsAfterCheckpoint ?? -1) skipped=\(p?.skipReasons.line ?? "-") "
                + "refusals=\(p?.refusals.prefix(2) ?? []) truncated_at=\(p?.truncatedAtOffset.map(String.init) ?? "nil") "
                + "first_replay=\(r1.replay?.recordsAfterCheckpoint ?? -1) lines=\(lines.suffix(3))")
    }

    /// write(2) writes k bytes of the unit and fails (RLIMIT_FSIZE, EFBIG).
    func failedWriteCell(_ kind: Kind, ternary: Bool, seed: UInt64, k: Int) throws -> (Bool, String) {
        // The SAVE kinds need the log longer than the snapshot file, so the
        // limit cuts the log's record and not the snapshot's tmp file.
        let (f, t) = try base(ternary: ternary, seed: seed, pad: kind.isSave ? 40 : 0)
        mix(f, t, 1)
        let before = try observe(f, t)
        let s0 = Self.size(walPath)
        let start = kind == .checkpoint ? s0 + 45 : s0
        if kind.isSave {
            let snapBytes = Self.size(snapPath)
            guard snapBytes + 512 < s0 else { return (false, "k=\(k): log \(s0) B not longer than the snapshot \(snapBytes) B") }
        }
        signal(SIGXFSZ, SIG_IGN)
        var lim = rlimit()
        getrlimit(RLIMIT_FSIZE, &lim)
        let saved = lim
        lim.rlim_cur = rlim_t(start + k)
        setrlimit(RLIMIT_FSIZE, &lim)
        let reply = try issue(kind, f, t, ternary: ternary)
        var restore = saved
        setrlimit(RLIMIT_FSIZE, &restore)
        let sizeAfter = Self.size(walPath)
        let refusedRight = kind == .checkpoint
            ? reply.hasPrefix("OK SAVE") && reply.contains("WARN wal: checkpoint not written")
            : !reply.hasPrefix("OK")
        let m0 = mismatch(before, try observe(f, t))       // a refused command changed nothing
        try after(kind, f, t, ternary: ternary)
        let live = try observe(f, t)
        let (h, r, lines) = try restart(snapshot: snapPath, attach: false)
        let m = mismatch(live, try observe(h, t))
        let good = refusedRight && m0.isEmpty && m.isEmpty && Self.clean(r)
        let p = r.replay
        return (good, "k=\(k): reply=\(reply.prefix(150)) log \(s0)->\(sizeAfter) (unit at \(start)) "
                + "state changed by the refused command \(m0), restart vs live \(m), "
                + "replayed=\(p?.recordsAfterCheckpoint ?? -1) skipped=\(p?.skipReasons.line ?? "-") "
                + "refusals=\(p?.refusals.prefix(2) ?? []) truncated_at=\(p?.truncatedAtOffset.map(String.init) ?? "nil") lines=\(lines.suffix(3))")
    }

    /// Every offset of one kind, both cuts, binary and ternary.
    func sweep(_ kind: Kind) throws {
        var crash = Tally(), failed = Tally()
        var lens: [String] = []
        for ternary in [false, true] {
            let seed: UInt64 = 0xD320 + (ternary ? 1 : 0)
            let shape = try probe(kind, ternary: ternary, seed: seed)
            let ks = offsets(kind, len: shape.len, boundaries: shape.boundaries)
            lens.append("\(ternary ? "ternary" : "binary") \(shape.len) B, \(shape.boundaries.count) record(s), \(ks.count) offsets")
            for k in ks {
                let (c, cw) = try crashCell(kind, ternary: ternary, seed: seed, k: k)
                crash.add(c, "\(ternary ? "ternary" : "binary") crash \(cw)")
                let (w, ww) = try failedWriteCell(kind, ternary: ternary, seed: seed, k: k)
                failed.add(w, "\(ternary ? "ternary" : "binary") failed write \(ww)")
            }
        }
        print("DUR3.2 \(kind.rawValue): \(lens.joined(separator: "; ")); crash \(crash.ok)/\(crash.cells) equal and clean; "
              + "failed write \(failed.ok)/\(failed.cells) equal and clean")
        for f in crash.failures + failed.failures { print("DUR3.2 \(kind.rawValue) FAIL \(f)") }
        XCTAssertEqual(crash.ok, crash.cells, "\(kind.rawValue): crash cells: \(crash.failures.prefix(3))")
        XCTAssertEqual(failed.ok, failed.cells, "\(kind.rawValue): failed-write cells: \(failed.failures.prefix(3))")
        XCTAssertGreaterThan(crash.cells, 0)
    }

    func testDUR32TornSetTruth() throws { try sweep(.setTruth) }
    func testDUR32TornSetLutsMap() throws { try sweep(.map) }
    func testDUR32TornSetTruthBulk() throws { try sweep(.truthBulk) }
    func testDUR32TornSetLutsBulk() throws { try sweep(.lutsBulk) }
    func testDUR32TornRingsWrite() throws { try sweep(.rings) }
    func testDUR32TornSnapshotBind() throws { try sweep(.bind) }
    func testDUR32TornCheckpoint() throws { try sweep(.checkpoint) }
    func testDUR32TornImportRecord() throws { try sweep(.importOne) }
    func testDUR32TornImportGroup() throws { try sweep(.importGroup) }

    // MARK: - No snapshot loaded: the whole log

    /// The live check's reproducer, in-process: the WAL on, the startup path
    /// set but never written (or not set); the graph by IMPORT MORTON (a
    /// logged record), the twin registries, a mix, a SAVE to ANOTHER path
    /// (its bind record and checkpoint), a second mix; a restart. Recovery
    /// loads no snapshot, so it must replay the whole log.
    func testDUR33NoSnapshotLoadedReplaysTheWholeLog() throws {
        var cells = 0, equal = 0
        for ternary in [false, true] {
            for startupSet in [true, false] {
                let label = "\(ternary ? "ternary" : "binary") startup path \(startupSet ? "set, never written" : "not set")"
                for p in [walPath, snapPath] { try? FileManager.default.removeItem(atPath: p) }
                let f = try fixture(wal: true, startup: startupSet)
                let dir = try importSources(ternary: ternary).0
                ok(f, "IMPORT MORTON \(dir)", "OK IMPORT")
                let t = openTwin(f)
                mix(f, t, 1)
                ok(f, "SAVE \(tmp!)other.dags", "OK SAVE")
                mix(f, t, 2)
                let live = try observe(f, t)
                let (g, r, lines) = try restart(snapshot: startupSet ? snapPath : nil, attach: false)
                XCTAssertFalse(FileManager.default.fileExists(atPath: snapPath), label)
                XCTAssertNil(r.snapshot, label)
                let m = mismatch(live, try observe(g, t))
                XCTAssertEqual(m, [], "\(label): recovered != live; lines \(lines)")
                XCTAssertTrue(Self.clean(r), "\(label): replay not clean: \(r.replay?.skipReasons.line ?? "-")")
                print("DUR3.3 \(label): recovered vs live \(m.isEmpty ? "equal" : "\(m)") "
                      + "replayed=\(r.replay?.recordsAfterCheckpoint ?? -1) epoch=\(r.replay?.checkpointEpoch ?? 0) "
                      + "bound=\(r.replay?.boundAtOffset.map(String.init) ?? "nil") lines=\(lines)")
                cells += 1
                if m.isEmpty { equal += 1 }
            }
        }
        print("DUR3.3 in-process: \(equal)/\(cells) equal")
        XCTAssertEqual(cells, 4)
    }
}
