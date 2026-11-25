import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Result rows carry no stale bytes.
///
/// Every writer of the shared result file, each followed by each: for every
/// ordered pair (A, B) the result buffer is zeroed, A runs and the rows it
/// reports are checked, then B runs and its rows are checked. Then every
/// writer in four orders (forward, backward, two seeded shuffles) with
/// nothing reset between, each writer's rows checked after it runs.
///
/// A row's pad bytes are the bytes its layout gives no field:
///   - EVAL, NODES, TRAVERSE, READER NODES, READER TRAVERSE (`writeResults`):
///     24-byte rows (u64 node, u64 rank, u8 truth, u8 type, u8 mode), pad 19..23;
///   - HOOK LEDGER: 40-byte rows, pad 12..15 and 33..39;
///   - ALARM CORRUPT: 40-byte rows, pad 12..15, each claim slot's byte 3 (an
///     unused slot: all 4 bytes) and 36..39;
///   - TILED BFS: 16-byte rows, pad 12..15;
///   - TRUTH_SLICE (every form): the bits of the last byte past the slice.
/// The other writers' layouts have no pad (SELECT, BFS_DEPTHS, ANCESTRY,
/// SIMILAR_DECISIONS, the u64 / f32 / f64 vectors). They run as A and as B,
/// so their bytes are the leftovers the padded rows must not show. The
/// client's own writes (every bulk verb's input frame, BANK's inputs) are one
/// more writer, `client frame`: every byte of the buffer, nonzero.
///
/// The legs: the graph of `EngineE1DaemonTests.buildGraph` at 24² binary and ternary (every writer but
/// FOLD and VIEW), FOLD's control object at 12² (the FOLD verbs), and that graph at 10²
/// with the sealed cortex fixture (VIEW FEATURES; skipped when
/// `DAGDB_CORTEX_V4_FIXTURE` is unset). An independent check's reproducer is its own
/// test: truths (200+i) mod 256 on nodes 0..63, `TRUTH_SLICE NODES 0-63 BYTES`, `EVAL`.
final class EnginePAD1DaemonTests: XCTestCase {

    typealias E1 = EngineE1DaemonTests

    enum Layout: String { case result24, hook40, alarm40, tiled16, slice, plain }

    struct Writer {
        let name: String
        let layout: Layout
        let send: () -> String
    }

    var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "pad1-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - The pad check

    static func byte(_ shm: UnsafeMutableRawPointer, _ k: Int) -> UInt8 { shm.load(fromByteOffset: k, as: UInt8.self) }

    /// The pad offsets of one row (relative to the row), by layout; for
    /// ALARM CORRUPT they depend on the row's claim count.
    static func padOffsets(_ layout: Layout, row: UnsafeMutableRawPointer) -> [Int] {
        switch layout {
        case .result24: return Array(19..<24)
        case .hook40: return Array(12..<16) + Array(33..<40)
        case .tiled16: return Array(12..<16)
        case .alarm40:
            let claims = Int(row.load(fromByteOffset: 8, as: UInt32.self))
            var o = Array(12..<16)
            for slot in 0..<5 {
                let s = 16 + slot * 4
                o += slot < claims ? [s + 3] : Array(s..<(s + 4))
            }
            return o + Array(36..<40)
        case .slice, .plain: return []
        }
    }

    static func rowSize(_ layout: Layout) -> Int {
        switch layout {
        case .result24: return 24
        case .hook40, .alarm40: return 40
        case .tiled16: return 16
        case .slice, .plain: return 0
        }
    }

    /// The rows the reply reported (for TRUTH_SLICE: its last byte) and how
    /// many carry a nonzero pad byte; the first such, in hex.
    static func pads(_ layout: Layout, _ reply: String, shm: UnsafeMutableRawPointer, capacity: Int)
        -> (rows: Int, stale: Int, first: String?, header: String?) {
        guard layout != .plain, reply.hasPrefix("OK") else { return (0, 0, nil, nil) }
        let count = Int(shm.load(fromByteOffset: 0, as: UInt32.self))
        let second = Int(shm.load(fromByteOffset: 4, as: UInt32.self))
        if layout == .slice {
            let used = count * second
            let nb = (used + 7) / 8
            guard nb > 0 else { return (0, 0, nil, nil) }
            guard 8 + nb <= capacity else { return (0, 0, nil, "slice of \(nb) bytes past the capacity \(capacity)") }
            let last = byte(shm, 8 + nb - 1)
            let keep = used % 8
            let stale = keep != 0 && (last >> UInt8(keep)) != 0
            return (1, stale ? 1 : 0,
                    stale ? "last byte \(String(format: "%02x", last)), bits \(keep)..7 past the slice" : nil, nil)
        }
        let size = rowSize(layout)
        guard second == size else { return (0, 0, nil, "header row size \(second), expected \(size)") }
        guard 8 + count * size <= capacity else { return (0, 0, nil, "\(count) rows past the capacity \(capacity)") }
        var stale = 0
        var first: String?
        for i in 0..<count {
            let row = shm.advanced(by: 8 + i * size)
            let offs = padOffsets(layout, row: row)
            let bad = offs.filter { byte(row, $0) != 0 }
            if !bad.isEmpty {
                stale += 1
                if first == nil {
                    first = "row \(i): pad " + offs.map { String(format: "%02x", byte(row, $0)) }.joined(separator: " ")
                }
            }
        }
        return (count, stale, first, nil)
    }

    // MARK: - A leg

    struct Tally {
        var commands = 0, pairs = 0, staleRows = 0, staleReports = 0
        var rows: [String: Int] = [:]
    }

    /// Each followed by each, then four orders; every reported row checked.
    @discardableResult
    func runLeg(_ leg: String, _ f: HandlerFixture, _ writers: [Writer], reset: () -> Void) -> Tally {
        var t = Tally()
        func run(_ w: Writer, after: String) {
            let r = w.send()
            t.commands += 1
            guard r.hasPrefix("OK") else {
                XCTFail("PAD1 \(leg): \(w.name) after \(after) did not run: \(r)")
                return
            }
            let p = Self.pads(w.layout, r, shm: f.shm, capacity: f.shmBytes)
            if let h = p.header { XCTFail("PAD1 \(leg): \(w.name) after \(after): \(h)") }
            t.rows[w.name, default: 0] += p.rows
            if p.stale > 0 {
                t.staleRows += p.stale
                t.staleReports += 1
                XCTFail("PAD1 \(leg): \(w.name) after \(after): \(p.stale) of \(p.rows) rows carry nonzero pad bytes; "
                        + "first \(p.first ?? "?")")
            }
        }
        for a in writers {
            for b in writers {
                memset(f.shm, 0, f.shmBytes)
                reset()
                run(a, after: "a zeroed buffer")
                run(b, after: a.name)
                t.pairs += 1
            }
        }
        var orders = [writers, Array(writers.reversed())]
        var g = E1.Rng(s: 0x9AD1_0000 &+ UInt64(writers.count))
        for _ in 0..<2 {
            var o = writers
            for i in stride(from: o.count - 1, to: 0, by: -1) { o.swapAt(i, g.below(i + 1)) }
            orders.append(o)
        }
        for o in orders {
            var prev = "the previous order"
            for w in o { run(w, after: prev); prev = w.name }
        }
        // Non-vacuous: every padded writer reported rows.
        for w in writers where w.layout != .plain {
            XCTAssertGreaterThan(t.rows[w.name] ?? 0, 0, "PAD1 \(leg): \(w.name) reported no row; its check is vacuous")
        }
        let byLayout = Dictionary(grouping: writers.filter { $0.layout != .plain }, by: { $0.layout.rawValue })
            .mapValues { ws in ws.reduce(0) { $0 + (t.rows[$1.name] ?? 0) } }
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("PAD1 P1.1 \(leg): writers=\(writers.count) (padded \(writers.filter { $0.layout != .plain }.count)) "
              + "pairs=\(t.pairs) commands=\(t.commands) rows checked: \(byLayout); "
              + "rows with nonzero pad bytes=\(t.staleRows) in \(t.staleReports) reports")
        return t
    }

    // MARK: - Shared writers and setup

    /// The client's own write: every byte of the buffer, nonzero.
    func clientFrame(_ f: HandlerFixture) -> Writer {
        Writer(name: "client frame", layout: .plain) {
            for k in 0..<f.shmBytes { f.shm.storeBytes(of: UInt8(0x80 | ((k &* 37 &+ 11) & 0x7F)), toByteOffset: k, as: UInt8.self) }
            return "OK client frame"
        }
    }

    func openReader(_ f: HandlerFixture) throws -> String {
        let r = f.handler.handle("OPEN_READER")
        guard r.hasPrefix("OK OPEN_READER id="), let id = r.split(separator: " ").dropFirst(2).first?.dropFirst(3) else {
            throw NSError(domain: "pad1", code: 1, userInfo: [NSLocalizedDescriptionKey: r])
        }
        return String(id)
    }

    /// Loom codes (200+i) mod 256 on the binary nodes among 0..63 (the
    /// reproducer's truths), so TRUTH_SLICE BYTES leaves high bytes behind.
    func loomTruths(_ f: HandlerFixture) {
        let e = f.handler.engine
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: e.nodeCount)
        for i in 0..<min(64, e.nodeCount) where !TernaryReference.isTernary(e.modeByte(i)) {
            truth[i] = UInt8(truncatingIfNeeded: 200 + i)
        }
        f.handler.truthRankIndex.markDirty()
    }

    /// TwinAlarmCommandTests' synthetic mini-fixture (5 judged records + cal0).
    func writeAlarmFixture() throws -> String {
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
        let path = tmp + "/mini.json"
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: path))
        return path
    }

    static let pcg = "0x853c49e6748fea9b 0xda3e39cb94b95bdb 0x5851f42d4c957f2d 0x14057b7ef767814f"

    func expectOK(_ f: HandlerFixture, _ line: String) {
        let r = f.handler.handle(line)
        XCTAssertTrue(r.hasPrefix("OK"), "\(line): \(r)")
    }

    /// The main leg: the graph of `EngineE1DaemonTests.buildGraph` at side 24 with every writer but FOLD and VIEW.
    func mainLeg(ternary: Bool) throws {
        let side = 24, n = side * side
        let f = try HandlerFixture(side: side, dataRoot: tmp)
        let h = f.handler
        try E1.buildGraph(h.engine, seed: 0x9AD1_0000 &+ UInt64(n) &+ (ternary ? 1 : 0), ternary: ternary)
        XCTAssertNil(DagDBSnapshot.rankOrderViolation(engine: h.engine, nodeCount: n))
        loomTruths(f)

        // Twin and tiled state the writers read.
        expectOK(f, "ALARM LOAD \(try writeAlarmFixture())")
        expectOK(f, "HOOK OPEN a00000001 SEALED 100000")
        expectOK(f, "HOOK STEP h00000001 100")
        expectOK(f, "STREAM OPEN ref \(Self.pcg)")
        expectOK(f, "RECORD OPEN court 1500 0.6827 3000 1.0 0.6827 0.00001 0 \(Self.pcg)")
        expectOK(f, "RECORD SLICE t00000001 30")
        expectOK(f, "BANK OPEN small 64 1000 10 3 0 0 0.02")
        let tiles = try TiledFixture.generate(side: 16)
        let report = try TiledGraphFiles.write(object: tiles, dataRoot: tmp, name: "t16",
                                               boundaries: TiledFixture.boundaries(side: 16, tiles: 4))
        expectOK(f, "TILED OPEN \(tmp!)/t16 2")
        let seeds = TiledFixture.seeds(for: tiles).map { report.globalOf[$0] }
        expectOK(f, "EVAL")   // a rank-mode tick first: RANK r-r takes the per-rank list path
        let rid = try openReader(f)

        let bankIn: (Int, SHM1Verb) -> Void = { count, verb in
            for k in 0..<count {
                f.shm.storeBytes(of: Float(sin(Double(k) * 0.37)), toByteOffset: 8 + 4 * k, as: Float.self)
            }
            shm1Header(f.shm, count: count, verb: verb)
        }
        func w(_ name: String, _ layout: Layout, _ line: String) -> Writer {
            Writer(name: name, layout: layout) { h.handle(line) }
        }
        var writers: [Writer] = [
            clientFrame(f),
            w("EVAL", .result24, "EVAL"),
            w("NODES", .result24, "NODES"),
            w("TRAVERSE", .result24, "TRAVERSE FROM 0 DEPTH 4"),
            w("SELECT", .plain, "SELECT TRUTH 1 RANK 0-7"),
            w("BFS_DEPTHS", .plain, "BFS_DEPTHS FROM 5"),
            w("BFS_DEPTHS BACKWARD", .plain, "BFS_DEPTHS FROM 5 BACKWARD"),
            w("ANCESTRY", .plain, "ANCESTRY FROM 3 DEPTH 7"),
            w("SIMILAR_DECISIONS", .plain, "SIMILAR_DECISIONS TO 3 DEPTH 2 K 8 AMONG TRUTH 1"),
            w("TRUTH_SLICE NODES BYTES", .slice, "TRUTH_SLICE NODES 0-\(n - 1) BYTES"),
            w("TRUTH_SLICE NODES", .slice, "TRUTH_SLICE NODES 73-502"),
            w("TRUTH_SLICE RANK r-r", .slice, "TRUTH_SLICE RANK 3-3"),
            w("TRUTH_SLICE RANK lo-hi", .slice, "TRUTH_SLICE RANK 1-4"),
            w("TRUTH_SLICE RANK BYTES", .slice, "TRUTH_SLICE RANK 2-2 BYTES"),
            w("TILED BFS", .tiled16, "TILED BFS x00000001 \(seeds[0]) 4"),
            w("TILED BFS BACK", .tiled16, "TILED BFS x00000001 \(seeds[1]) 4 BACK"),
            w("TILED SELECT", .plain, "TILED SELECT x00000001 1 0 8"),
            w("ALARM CORRUPT", .alarm40, "ALARM CORRUPT a00000001 3 0.5 0 1"),
            w("HOOK LEDGER", .hook40, "HOOK LEDGER h00000001"),
            w("STREAM NEXT", .plain, "STREAM NEXT s00000001 40"),
            w("RECORD REPLAY", .plain, "RECORD REPLAY t00000001 0"),
            Writer(name: "BANK GENERATE", layout: .plain) { bankIn(6, .bankGenerate); return h.handle("BANK GENERATE w00000001 1") },
            Writer(name: "BANK FIT", layout: .plain) { bankIn(64, .bankFit); return h.handle("BANK FIT w00000001") },
        ]
        let r = "READER \(rid) "
        writers += [
            w("READER NODES", .result24, r + "NODES"),
            w("READER TRAVERSE", .result24, r + "TRAVERSE FROM 0 DEPTH 4"),
            w("READER SELECT", .plain, r + "SELECT TRUTH 1 RANK 0-7"),
            w("READER BFS_DEPTHS", .plain, r + "BFS_DEPTHS FROM 5"),
            w("READER ANCESTRY", .plain, r + "ANCESTRY FROM 3 DEPTH 7"),
            w("READER TRUTH_SLICE NODES BYTES", .slice, r + "TRUTH_SLICE NODES 0-\(n - 1) BYTES"),
            w("READER TRUTH_SLICE NODES", .slice, r + "TRUTH_SLICE NODES 73-502"),
            w("READER TRUTH_SLICE RANK", .slice, r + "TRUTH_SLICE RANK 1-4"),
            w("READER TILED BFS", .tiled16, r + "TILED BFS x00000001 \(seeds[2]) 4"),
            w("READER TILED SELECT", .plain, r + "TILED SELECT x00000001 0 0 8"),
            w("READER ALARM CORRUPT", .alarm40, r + "ALARM CORRUPT a00000001 2 0.25 0.5 0"),
            w("READER HOOK LEDGER", .hook40, r + "HOOK LEDGER h00000001 1 5"),
            w("READER RECORD REPLAY", .plain, r + "RECORD REPLAY t00000001 0"),
            Writer(name: "READER BANK GENERATE", layout: .plain) { bankIn(6, .bankGenerate); return h.handle(r + "BANK GENERATE w00000001 1") },
            Writer(name: "READER BANK FIT", layout: .plain) { bankIn(64, .bankFit); return h.handle(r + "BANK FIT w00000001") },
        ]
        runLeg("E1 \(side)² \(ternary ? "ternary" : "binary")", f, writers) { loomTruths(f) }
    }

    // MARK: - An independent check's reproducer

    /// That reproducer, as found: truths (200+i) mod 256 on nodes 0..63,
    /// `TRUTH_SLICE NODES 0-63 BYTES`, then `EVAL`. On the older code rows 0 and 1
    /// carry the slice's bytes 19..23 and 43..47 in their pads.
    func testP1_1TheVerifiersReproducer() throws {
        let side = 16, n = side * side
        let f = try HandlerFixture(side: side)
        try E1.buildGraph(f.handler.engine, seed: 0x9AD1_0000 &+ UInt64(n), ternary: false)
        for i in 0..<64 { expectOK(f, "SET \(i) TRUTH \((200 + i) % 256)") }
        expectOK(f, "TRUTH_SLICE NODES 0-63 BYTES")
        let r = f.handler.handle("EVAL")
        XCTAssertTrue(r.hasPrefix("OK EVAL rows=32 "), r)
        let p = Self.pads(.result24, r, shm: f.shm, capacity: f.shmBytes)
        XCTAssertNil(p.header)
        XCTAssertEqual(p.rows, 32)
        for i in 0..<2 {
            let row = f.shm.advanced(by: 8 + 24 * i)
            let pad = (19..<24).map { Self.byte(row, $0) }
            XCTAssertEqual(pad, [0, 0, 0, 0, 0],
                           "PAD1 reproducer: EVAL row \(i) pad " + pad.map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        XCTAssertEqual(p.stale, 0, "PAD1 reproducer: \(p.stale) of \(p.rows) EVAL rows carry nonzero pad bytes; first \(p.first ?? "-")")
        print("PAD1 P1.1 reproducer: EVAL rows=\(p.rows), rows with nonzero pad bytes=\(p.stale), first \(p.first ?? "-")")
    }

    func testP1_1EveryWriterFollowedByEveryWriterBinary() throws { try mainLeg(ternary: false) }

    func testP1_1EveryWriterFollowedByEveryWriterTernary() throws { try mainLeg(ternary: true) }

    /// FOLD's verbs on FOLD's control object (TwinFoldCommandTests' fixture:
    /// side 12, the buffer sized to the 49x49 f32 result), with the 24-byte
    /// writers that run on it.
    func testP1_1FoldLeg() throws {
        let f = try HandlerFixture(side: 12, shmBytes: 8 + 49 * 49 * 4)
        let h = f.handler
        let nb = h.engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: f.grid.neighbors.count)
        for i in 0..<f.grid.neighbors.count { nb[i] = f.grid.neighbors[i] }
        _ = LadderFold.Objects.control(engine: h.engine, grid: f.grid)
        loomTruths(f)
        expectOK(f, "FOLD RUN 6 3 78 78")
        let rid = try openReader(f)
        func w(_ name: String, _ layout: Layout, _ line: String) -> Writer {
            Writer(name: name, layout: layout) { h.handle(line) }
        }
        let r = "READER \(rid) "
        let writers: [Writer] = [
            clientFrame(f),
            w("FOLD RUN", .plain, "FOLD RUN 6 3 78 78"),
            w("FOLD KEPT", .plain, "FOLD KEPT"),
            w("FOLD SOURCE", .plain, "FOLD SOURCE 1"),
            w("FOLD TIER", .plain, "FOLD TIER final 1"),
            w("NODES", .result24, "NODES"),
            w("TRAVERSE", .result24, "TRAVERSE FROM 0 DEPTH 3"),
            w("TRUTH_SLICE NODES BYTES", .slice, "TRUTH_SLICE NODES 0-143 BYTES"),
            w("READER NODES", .result24, r + "NODES"),
            w("READER TRAVERSE", .result24, r + "TRAVERSE FROM 0 DEPTH 3"),
            w("READER FOLD KEPT", .plain, r + "FOLD KEPT"),
            w("READER FOLD SOURCE", .plain, r + "FOLD SOURCE 3"),
            w("READER FOLD TIER", .plain, r + "FOLD TIER final 1"),
        ]
        runLeg("FOLD control 12²", f, writers) { loomTruths(f) }
    }

    /// VIEW FEATURES on the sealed cortex fixture (the data root is the
    /// fixture's own directory, read only), with the 24-byte writers on the graph of
    /// `EngineE1DaemonTests.buildGraph` at 10².
    func testP1_1ViewLegSealed() throws {
        guard let path = CortexFixture.envPath else {
            throw XCTSkip("DAGDB_CORTEX_V4_FIXTURE not set — the VIEW leg skipped")
        }
        let side = 10, n = side * side
        let f = try HandlerFixture(side: side, dataRoot: (path as NSString).deletingLastPathComponent)
        let h = f.handler
        try E1.buildGraph(h.engine, seed: 0x9AD1_0000 &+ UInt64(n), ternary: false)
        loomTruths(f)
        expectOK(f, "VIEW LOAD \(path) SHA \(CortexFixture.sealedSHA256)")
        let rid = try openReader(f)
        func w(_ name: String, _ layout: Layout, _ line: String) -> Writer {
            Writer(name: name, layout: layout) { h.handle(line) }
        }
        let r = "READER \(rid) "
        let writers: [Writer] = [
            clientFrame(f),
            w("VIEW FEATURES", .plain, "VIEW FEATURES v00000001 0 8"),
            w("EVAL", .result24, "EVAL"),
            w("NODES", .result24, "NODES"),
            w("TRAVERSE", .result24, "TRAVERSE FROM 0 DEPTH 3"),
            w("TRUTH_SLICE NODES BYTES", .slice, "TRUTH_SLICE NODES 0-\(n - 1) BYTES"),
            w("READER VIEW FEATURES", .plain, r + "VIEW FEATURES v00000001 5 6"),
            w("READER NODES", .result24, r + "NODES"),
            w("READER TRAVERSE", .result24, r + "TRAVERSE FROM 0 DEPTH 3"),
        ]
        runLeg("VIEW E1 10²", f, writers) { loomTruths(f) }
    }
}
