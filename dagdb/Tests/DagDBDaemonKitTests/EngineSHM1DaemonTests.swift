import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// An input verb reads only a frame its client wrote (client_protocol 2; the
/// in-process checks; the wire checks and the old-build comparisons (also over the wire) run
/// outside the suite).
///
/// The 14 input verbs read a client frame `[u32 count][u32 0x314D48<VV>]` at
/// shm bytes 0..7, VV the verb's code (the verb-bound mark), the
/// payload at 8. The replies are written here from their specified text, never
/// read from the code under test:
///   - no mark: `ERROR stale_frame: <VERB> reads a client frame; the shm
///     header is (<w0>, <w1>), not (<count>, 0x314D48<VV>): write [u32
///     count][u32 0x314D48<VV>] at bytes 0..7, then the payload at 8; nothing
///     written`;
///   - the mark with another count: `ERROR bad_value: <VERB> frame count
///     <w0>, the verb reads <count>; nothing written`.
/// For CONNECT_BACK_BULK and SET_TRUTH_BULK the count is word0 itself. A frame
/// marked for another verb is tested in EngineSHM1A2DaemonTests.swift.
///
/// Every input verb × every writer of the `EnginePAD1DaemonTests` legs (the graph of
/// `EngineE1DaemonTests.buildGraph` at 24² binary and ternary, FOLD's control object at 12², the sealed cortex
/// fixture at 10²), plus daemon start (a never-written buffer): the client
/// writes a correct marked frame, the writer runs, the verb is sent →
/// stale_frame, with the state hash, the WAL length and the buffer unchanged.
final class EngineSHM1DaemonTests: XCTestCase {

    typealias E1 = EngineE1DaemonTests
    typealias Writer = EnginePAD1DaemonTests.Writer

    var tmp: String!
    private var tiledSeeds: [Int]?

    static var fixturesDir: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/DagDBDaemonKitTests/
            .deletingLastPathComponent()   // Tests/
            .appendingPathComponent("Fixtures").path
    }
    static let kernelsSHA = "2523d3a8a4de44b56268ee31a703b6bcc6522c7c66a305651f8ec7c03e5c56b8"
    static let pcg = "0x853c49e6748fea9b 0xda3e39cb94b95bdb 0x5851f42d4c957f2d 0x14057b7ef767814f"
    static let forbidden = "ERROR forbidden: command not allowed in reader session (read-only)"

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "shm1-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: Self.fixturesDir + "/w1_kernels.json", toPath: tmp + "/w1_kernels.json")
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - The replies, written from their specification

    static func stale(_ verb: String, _ w0: UInt32, _ w1: UInt32, _ count: Int) -> String {
        let vv = String(format: "0x314D48%02X", SHM1Verb.named(verb).rawValue)
        return "ERROR stale_frame: \(verb) reads a client frame; the shm header is (\(w0), \(w1)), not (\(count), \(vv)): "
            + "write [u32 count][u32 \(vv)] at bytes 0..7, then the payload at 8; nothing written"
    }

    /// The input verb a command line sends (a `READER <id>` prefix and the arguments dropped).
    static func verbOf(_ line: String) -> SHM1Verb {
        var w = line.split(separator: " ").map(String.init)
        if w.first == "READER" { w.removeFirst(2) }
        return SHM1Verb.named(["XCONV", "BUDGET", "BANK"].contains(w[0]) ? w[0] + " " + w[1] : w[0])
    }

    static func badCount(_ verb: String, _ w0: UInt32, _ count: Int) -> String {
        "ERROR bad_value: \(verb) frame count \(w0), the verb reads \(count); nothing written"
    }

    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    static func raw<T>(_ v: [T]) -> [UInt8] { v.withUnsafeBytes { Array($0) } }
    static func header(_ shm: UnsafeMutableRawPointer) -> (UInt32, UInt32) {
        (shm.load(fromByteOffset: 0, as: UInt32.self), shm.load(fromByteOffset: 4, as: UInt32.self))
    }

    // MARK: - The 14 input verbs, each with a correct marked frame

    struct Input {
        let verb: String        // the verb as its refusal names it
        let line: String        // the command sent
        let count: Int          // the elements it reads, in the verb's unit
        let framed: Bool        // CONNECT_BACK_BULK, SET_TRUTH_BULK: the count is word0 itself
        let write: () -> Void   // the client's correct marked frame
    }

    /// The fixture needs a kernel (k00000001, no TAU: XCONV SEALED takes its
    /// warmup on the line), the K=6, T=64 bank (w00000001) and a non-empty
    /// library (SET_TTABLE_IDS_BULK refuses every vector on an empty one).
    /// None of these commands writes the shm.
    func twinInputs(_ f: HandlerFixture) {
        let h = f.handler
        ok(f, "KERNEL LOAD \(tmp!)/w1_kernels.json SHA \(Self.kernelsSHA)")
        if h.twin.banks.get("w00000001") == nil { ok(f, "BANK OPEN small 64 1000 10 3 0 0 0.02") }
        if h.engine.ttableCount == 0 { ok(f, "TTABLE PRESET 0 TSUM 2") }
    }

    /// One correct frame per input verb, from the fixture's live lanes, so an
    /// accepted frame of the client's own would leave the state as it is.
    func inputs(_ f: HandlerFixture) -> [Input] {
        let e = f.handler.engine, n = e.nodeCount, s = f.shm
        func put(_ bytes: [UInt8], _ count: Int, _ verb: SHM1Verb) {
            if !bytes.isEmpty { bytes.withUnsafeBytes { s.advanced(by: 8).copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
            shm1Header(s, count: count, verb: verb)
        }
        let ranks = e.readRanks()
        let lo = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let hi = e.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let luts = (0..<n).map { UInt64(hi[$0]) << 32 | UInt64(lo[$0]) }
        let nb = Array(UnsafeBufferPointer(start: e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6), count: n * 6))
        let modes = (0..<n).map { e.modeByte($0) }
        let truth = e.readTruthStates()
        // One back edge CONNECT_BACK_BULK accepts: into a binary node with no
        // live slot (a register is one), from the next node; none if no node qualifies.
        var back: [UInt8] = []
        if let d = (0..<n).first(where: { i in modes[i] == 0 && (0..<6).allSatisfy { nb[i * 6 + $0] < 0 } }) {
            back = Self.le32(UInt32((d + 1) % n)) + Self.le32(UInt32(d))
        }
        var truthRows: [UInt8] = []
        for i in min(64, n - 1)..<min(80, n) { truthRows += Self.le32(UInt32(i)) + [truth[i], 0, 0, 0] }
        let table0 = e.tableBytes(0) ?? []
        let ids = [UInt16](repeating: 0, count: n)
        let thresh = (0..<n).flatMap { _ in [Float(-0.5), Float(0.5)] }
        let xconv: [Float] = [0, 0, 0, 0, 0, 0, 1, 1]
        let sealed = (0..<256).map { sin(Double($0) * 0.1) }
        let budget = Self.raw([Double(1)]) + Self.raw([UInt32(0)])
        let bankG = (0..<6).map { Float(sin(Double($0) * 0.37)) }
        let bankF = (0..<64).map { Float(sin(Double($0) * 0.37)) }
        return [
            Input(verb: "SET_RANKS_BULK", line: "SET_RANKS_BULK", count: n, framed: false) { put(Self.raw(ranks), n, .setRanksBulk) },
            Input(verb: "SET_LUTS_BULK", line: "SET_LUTS_BULK", count: n, framed: false) { put(Self.raw(luts), n, .setLutsBulk) },
            Input(verb: "SET_NEIGHBORS_BULK", line: "SET_NEIGHBORS_BULK", count: n, framed: false) { put(Self.raw(nb), n, .setNeighborsBulk) },
            Input(verb: "SET_MODES_BULK", line: "SET_MODES_BULK", count: n, framed: false) { put(modes, n, .setModesBulk) },
            Input(verb: "SET_TTABLE_IDS_BULK", line: "SET_TTABLE_IDS_BULK", count: n, framed: false) { put(Self.raw(ids), n, .setTTableIdsBulk) },
            Input(verb: "SET_THRESH_BULK", line: "SET_THRESH_BULK", count: n, framed: false) { put(Self.raw(thresh), n, .setThreshBulk) },
            Input(verb: "TTABLE_BULK", line: "TTABLE_BULK 0 1", count: 1, framed: false) { put(table0, 1, .ttableBulk) },
            Input(verb: "CONNECT_BACK_BULK", line: "CONNECT_BACK_BULK", count: back.count / 8, framed: true) { put(back, back.count / 8, .connectBackBulk) },
            Input(verb: "SET_TRUTH_BULK", line: "SET_TRUTH_BULK", count: truthRows.count / 8, framed: true) { put(truthRows, truthRows.count / 8, .setTruthBulk) },
            Input(verb: "XCONV CHECK", line: "XCONV CHECK 3 3 1 1 1", count: 8, framed: false) { put(Self.raw(xconv), 8, .xconvCheck) },
            Input(verb: "XCONV SEALED", line: "XCONV SEALED k00000001 128 100", count: 256, framed: false) { put(Self.raw(sealed), 256, .xconvSealed) },
            Input(verb: "BUDGET OPEN", line: "BUDGET OPEN 1 1 1", count: 2, framed: false) { put(budget, 2, .budgetOpen) },
            Input(verb: "BANK GENERATE", line: "BANK GENERATE w00000001 1", count: 6, framed: false) { put(Self.raw(bankG), 6, .bankGenerate) },
            Input(verb: "BANK FIT", line: "BANK FIT w00000001", count: 64, framed: false) { put(Self.raw(bankF), 64, .bankFit) },
        ]
    }

    // MARK: - Fixtures (the `EnginePAD1DaemonTests` legs, each with a WAL)

    final class Leg {
        let name: String
        let f: HandlerFixture
        let walPath: String
        let writers: [Writer]
        init(_ name: String, _ f: HandlerFixture, _ walPath: String, _ writers: [Writer]) {
            self.name = name; self.f = f; self.walPath = walPath; self.writers = writers
        }
    }

    func ok(_ f: HandlerFixture, _ line: String, file: StaticString = #filePath, l: UInt = #line) {
        let r = f.handler.handle(line)
        XCTAssertTrue(r.hasPrefix("OK"), "\(line): \(r)", file: file, line: l)
    }

    func openReader(_ f: HandlerFixture) throws -> String {
        let r = f.handler.handle("OPEN_READER")
        guard r.hasPrefix("OK OPEN_READER id="), let id = r.split(separator: " ").dropFirst(2).first?.dropFirst(3) else {
            throw NSError(domain: "shm1", code: 1, userInfo: [NSLocalizedDescriptionKey: r])
        }
        return String(id)
    }

    /// The Loom codes of `EnginePAD1DaemonTests`: (200+i) mod 256 on the binary nodes among 0..63.
    func loomTruths(_ f: HandlerFixture) {
        let e = f.handler.engine
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: e.nodeCount)
        for i in 0..<min(64, e.nodeCount) where !TernaryReference.isTernary(e.modeByte(i)) {
            truth[i] = UInt8(truncatingIfNeeded: 200 + i)
        }
        f.handler.truthRankIndex.markDirty()
    }

    func alarmFixture() throws -> String {
        let path = tmp + "/mini.json"
        if FileManager.default.fileExists(atPath: path) { return path }
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
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// The tiled object of `EnginePAD1DaemonTests` (side 16, 4 tiles), written once per test.
    func tiled() throws -> [Int] {
        if let s = tiledSeeds { return s }
        let tiles = try TiledFixture.generate(side: 16)
        let report = try TiledGraphFiles.write(object: tiles, dataRoot: tmp, name: "t16",
                                               boundaries: TiledFixture.boundaries(side: 16, tiles: 4))
        let s = TiledFixture.seeds(for: tiles).map { Int(report.globalOf[$0]) }
        tiledSeeds = s
        return s
    }

    func clientFrame(_ f: HandlerFixture) -> Writer {
        Writer(name: "client frame", layout: .plain) {
            for k in 0..<f.shmBytes { f.shm.storeBytes(of: UInt8(0x80 | ((k &* 37 &+ 11) & 0x7F)), toByteOffset: k, as: UInt8.self) }
            return "OK client frame"
        }
    }

    func walFixture(side: Int, shmBytes: Int? = nil, dataRoot: String? = nil) throws -> (HandlerFixture, String) {
        let walPath = tmp + "/l-\(UUID().uuidString).wal"
        let f = try HandlerFixture(side: side, dataRoot: dataRoot ?? tmp,
                                   wal: try DagDBWAL.Appender(path: walPath, nodeCount: side * side), shmBytes: shmBytes)
        return (f, walPath)
    }

    /// The graph of `EngineE1DaemonTests.buildGraph` at 24² with the main-leg writers of `EnginePAD1DaemonTests`. `start`: no command that
    /// writes the shm runs (daemon start: the buffer is never written).
    func mainLeg(ternary: Bool, start: Bool = false) throws -> Leg {
        let side = 24, n = side * side
        let (f, walPath) = try walFixture(side: side)
        let h = f.handler
        try E1.buildGraph(h.engine, seed: 0x9AD1_0000 &+ UInt64(n) &+ (ternary ? 1 : 0), ternary: ternary)
        loomTruths(f)
        twinInputs(f)
        let name = "E1 \(side)² \(ternary ? "ternary" : "binary")"
        if start { return Leg(name, f, walPath, []) }
        ok(f, "ALARM LOAD \(try alarmFixture())")
        ok(f, "HOOK OPEN a00000001 SEALED 100000")
        ok(f, "HOOK STEP h00000001 100")
        ok(f, "STREAM OPEN ref \(Self.pcg)")
        ok(f, "RECORD OPEN court 1500 0.6827 3000 1.0 0.6827 0.00001 0 \(Self.pcg)")
        ok(f, "RECORD SLICE t00000001 30")
        let seeds = try tiled()
        ok(f, "TILED OPEN \(tmp!)/t16 2")
        ok(f, "EVAL")
        let rid = try openReader(f)
        let bankIn: (Int, SHM1Verb) -> Void = { count, verb in
            for k in 0..<count { f.shm.storeBytes(of: Float(sin(Double(k) * 0.37)), toByteOffset: 8 + 4 * k, as: Float.self) }
            shm1Header(f.shm, count: count, verb: verb)
        }
        func w(_ name: String, _ line: String) -> Writer { Writer(name: name, layout: .plain) { h.handle(line) } }
        let r = "READER \(rid) "
        let writers: [Writer] = [
            clientFrame(f),
            w("EVAL", "EVAL"), w("NODES", "NODES"), w("TRAVERSE", "TRAVERSE FROM 0 DEPTH 4"),
            w("SELECT", "SELECT TRUTH 1 RANK 0-7"), w("BFS_DEPTHS", "BFS_DEPTHS FROM 5"),
            w("BFS_DEPTHS BACKWARD", "BFS_DEPTHS FROM 5 BACKWARD"), w("ANCESTRY", "ANCESTRY FROM 3 DEPTH 7"),
            w("SIMILAR_DECISIONS", "SIMILAR_DECISIONS TO 3 DEPTH 2 K 8 AMONG TRUTH 1"),
            w("TRUTH_SLICE NODES BYTES", "TRUTH_SLICE NODES 0-\(n - 1) BYTES"), w("TRUTH_SLICE NODES", "TRUTH_SLICE NODES 73-502"),
            w("TRUTH_SLICE RANK r-r", "TRUTH_SLICE RANK 3-3"), w("TRUTH_SLICE RANK lo-hi", "TRUTH_SLICE RANK 1-4"),
            w("TRUTH_SLICE RANK BYTES", "TRUTH_SLICE RANK 2-2 BYTES"),
            w("TILED BFS", "TILED BFS x00000001 \(seeds[0]) 4"), w("TILED BFS BACK", "TILED BFS x00000001 \(seeds[1]) 4 BACK"),
            w("TILED SELECT", "TILED SELECT x00000001 1 0 8"), w("ALARM CORRUPT", "ALARM CORRUPT a00000001 3 0.5 0 1"),
            w("HOOK LEDGER", "HOOK LEDGER h00000001"), w("STREAM NEXT", "STREAM NEXT s00000001 40"),
            w("RECORD REPLAY", "RECORD REPLAY t00000001 0"),
            Writer(name: "BANK GENERATE", layout: .plain) { bankIn(6, .bankGenerate); return h.handle("BANK GENERATE w00000001 1") },
            Writer(name: "BANK FIT", layout: .plain) { bankIn(64, .bankFit); return h.handle("BANK FIT w00000001") },
            w("READER NODES", r + "NODES"), w("READER TRAVERSE", r + "TRAVERSE FROM 0 DEPTH 4"),
            w("READER SELECT", r + "SELECT TRUTH 1 RANK 0-7"), w("READER BFS_DEPTHS", r + "BFS_DEPTHS FROM 5"),
            w("READER ANCESTRY", r + "ANCESTRY FROM 3 DEPTH 7"),
            w("READER TRUTH_SLICE NODES BYTES", r + "TRUTH_SLICE NODES 0-\(n - 1) BYTES"),
            w("READER TRUTH_SLICE NODES", r + "TRUTH_SLICE NODES 73-502"), w("READER TRUTH_SLICE RANK", r + "TRUTH_SLICE RANK 1-4"),
            w("READER TILED BFS", r + "TILED BFS x00000001 \(seeds[2]) 4"), w("READER TILED SELECT", r + "TILED SELECT x00000001 0 0 8"),
            w("READER ALARM CORRUPT", r + "ALARM CORRUPT a00000001 2 0.25 0.5 0"),
            w("READER HOOK LEDGER", r + "HOOK LEDGER h00000001 1 5"), w("READER RECORD REPLAY", r + "RECORD REPLAY t00000001 0"),
            Writer(name: "READER BANK GENERATE", layout: .plain) { bankIn(6, .bankGenerate); return h.handle(r + "BANK GENERATE w00000001 1") },
            Writer(name: "READER BANK FIT", layout: .plain) { bankIn(64, .bankFit); return h.handle(r + "BANK FIT w00000001") },
        ]
        return Leg(name, f, walPath, writers)
    }

    /// FOLD's control object at 12² (the buffer sized to the 49x49 f32 result) with the FOLD-leg writers of `EnginePAD1DaemonTests`.
    func foldLeg(start: Bool = false) throws -> Leg {
        let (f, walPath) = try walFixture(side: 12, shmBytes: 8 + 49 * 49 * 4)
        let h = f.handler
        let nb = h.engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: f.grid.neighbors.count)
        for i in 0..<f.grid.neighbors.count { nb[i] = f.grid.neighbors[i] }
        _ = LadderFold.Objects.control(engine: h.engine, grid: f.grid)
        loomTruths(f)
        twinInputs(f)
        if start { return Leg("FOLD control 12²", f, walPath, []) }
        ok(f, "FOLD RUN 6 3 78 78")
        let rid = try openReader(f)
        func w(_ name: String, _ line: String) -> Writer { Writer(name: name, layout: .plain) { h.handle(line) } }
        let r = "READER \(rid) "
        let writers: [Writer] = [
            clientFrame(f),
            w("FOLD RUN", "FOLD RUN 6 3 78 78"), w("FOLD KEPT", "FOLD KEPT"), w("FOLD SOURCE", "FOLD SOURCE 1"),
            w("FOLD TIER", "FOLD TIER final 1"), w("NODES", "NODES"), w("TRAVERSE", "TRAVERSE FROM 0 DEPTH 3"),
            w("TRUTH_SLICE NODES BYTES", "TRUTH_SLICE NODES 0-143 BYTES"),
            w("READER NODES", r + "NODES"), w("READER TRAVERSE", r + "TRAVERSE FROM 0 DEPTH 3"),
            w("READER FOLD KEPT", r + "FOLD KEPT"), w("READER FOLD SOURCE", r + "FOLD SOURCE 3"),
            w("READER FOLD TIER", r + "FOLD TIER final 1"),
        ]
        return Leg("FOLD control 12²", f, walPath, writers)
    }

    /// The sealed cortex fixture (cloned into the data root) with the graph of
    /// `EngineE1DaemonTests.buildGraph` at 10² and the VIEW-leg writers of `EnginePAD1DaemonTests`; nil when `DAGDB_CORTEX_V4_FIXTURE` is unset.
    func viewLeg(start: Bool = false) throws -> Leg? {
        guard let path = CortexFixture.envPath else { return nil }
        let cortex = tmp + "/cortex_v4_world.npz"
        if !FileManager.default.fileExists(atPath: cortex) { try FileManager.default.copyItem(atPath: path, toPath: cortex) }
        let side = 10, n = side * side
        let (f, walPath) = try walFixture(side: side)
        let h = f.handler
        try E1.buildGraph(h.engine, seed: 0x9AD1_0000 &+ UInt64(n), ternary: false)
        loomTruths(f)
        twinInputs(f)
        ok(f, "VIEW LOAD \(cortex) SHA \(CortexFixture.sealedSHA256)")
        if start { return Leg("VIEW E1 10²", f, walPath, []) }
        let rid = try openReader(f)
        func w(_ name: String, _ line: String) -> Writer { Writer(name: name, layout: .plain) { h.handle(line) } }
        let r = "READER \(rid) "
        let writers: [Writer] = [
            clientFrame(f),
            w("VIEW FEATURES", "VIEW FEATURES v00000001 0 8"), w("EVAL", "EVAL"), w("NODES", "NODES"),
            w("TRAVERSE", "TRAVERSE FROM 0 DEPTH 3"), w("TRUTH_SLICE NODES BYTES", "TRUTH_SLICE NODES 0-\(n - 1) BYTES"),
            w("READER VIEW FEATURES", r + "VIEW FEATURES v00000001 5 6"), w("READER NODES", r + "NODES"),
            w("READER TRAVERSE", r + "TRAVERSE FROM 0 DEPTH 3"),
        ]
        return Leg("VIEW E1 10²", f, walPath, writers)
    }

    // MARK: - A cell

    struct Snap: Equatable {
        let state: String, status: String, budgets: String
        let wal: Int
        let shm: Data
    }

    /// The state hash (every lane, the library, the back edges: `TernaryR5DaemonTests.stateHash`), the
    /// twin registries' visible counts (STATUS, BUDGET LIST: neither writes
    /// the shm), the WAL's length and the whole buffer.
    func snap(_ f: HandlerFixture, _ walPath: String) -> Snap {
        let h = f.handler
        h.walAppender?.barrier()
        let wal = ((try? FileManager.default.attributesOfItem(atPath: walPath))?[.size] as? NSNumber)?.intValue ?? -1
        return Snap(state: TernaryR5DaemonTests.stateHash(h.engine), status: h.handle("STATUS"),
                    budgets: h.handle("BUDGET LIST"), wal: wal, shm: Data(bytes: f.shm, count: f.shmBytes))
    }

    struct Tally {
        var cells = 0, green = 0, accepted = 0, otherReply = 0, changed = 0, writerFailed = 0
        var redByVerb: [String: Int] = [:], acceptedByVerb: [String: Int] = [:], redByWriter: [String: Int] = [:]
        mutating func add(_ o: Tally) {
            cells += o.cells; green += o.green; accepted += o.accepted; otherReply += o.otherReply
            changed += o.changed; writerFailed += o.writerFailed
            redByVerb.merge(o.redByVerb, uniquingKeysWith: +); acceptedByVerb.merge(o.acceptedByVerb, uniquingKeysWith: +)
            redByWriter.merge(o.redByWriter, uniquingKeysWith: +)
        }
        var line: String {
            "cells=\(cells) green=\(green) red=\(cells - green) (accepted \(accepted), other reply \(otherReply), "
                + "state/WAL/shm changed \(changed), writer did not run \(writerFailed))"
        }
    }

    /// V after W (or after daemon start when `w` is nil): green when the
    /// reply is exactly stale_frame and nothing changed.
    @discardableResult
    func cell(_ leg: String, _ f: HandlerFixture, _ walPath: String, _ v: Input, _ w: Writer?, _ t: inout Tally) -> Bool {
        let wname = w?.name ?? "daemon start"
        if let w = w {
            v.write()
            let r = w.send()
            guard r.hasPrefix("OK") else {
                t.writerFailed += 1; t.redByWriter[wname, default: 0] += 1; t.redByVerb[v.verb, default: 0] += 1
                XCTFail("SHM1 S1.1 \(leg): writer \(wname) did not run before \(v.verb): \(r)")
                return false
            }
        }
        let (w0, w1) = Self.header(f.shm)
        let before = snap(f, walPath)
        let reply = f.handler.handle(v.line)
        let after = snap(f, walPath)
        let want = Self.stale(v.verb, w0, w1, v.framed ? Int(w0) : v.count)
        t.cells += 1
        let same = after == before
        if reply == want && same { t.green += 1; return true }
        if reply.hasPrefix("OK") { t.accepted += 1; t.acceptedByVerb[v.verb, default: 0] += 1 } else if reply != want { t.otherReply += 1 }
        if !same { t.changed += 1 }
        t.redByVerb[v.verb, default: 0] += 1; t.redByWriter[wname, default: 0] += 1
        XCTFail("SHM1 S1.1 \(leg): \(v.verb) after \(wname), header (\(w0), \(w1)): '\(reply.prefix(150))'"
                + (same ? "" : "; the state, the WAL or the buffer changed"))
        return false
    }

    /// Every input verb × daemon start, then × every writer of the leg. A
    /// fresh fixture per verb, and again after any red cell (on the older code an
    /// accepted stale frame changes the state the next writer runs on).
    func s11(_ make: (Bool) throws -> Leg) throws -> Tally {
        var total = Tally(), start = Tally()
        var name = ""
        for vi in 0..<14 {
            let s = try make(true)
            name = s.name
            XCTAssertTrue(Data(bytes: s.f.shm, count: s.f.shmBytes).allSatisfy { $0 == 0 }, "\(s.name): daemon start writes no shm")
            cell(s.name, s.f, s.walPath, inputs(s.f)[vi], nil, &start)
            var leg = try make(false)
            for wi in 0..<leg.writers.count {
                let v = inputs(leg.f)[vi]
                if !cell(leg.name, leg.f, leg.walPath, v, leg.writers[wi], &total) { leg = try make(false) }
            }
        }
        print("SHM1 S1.1 \(name) daemon start: \(start.line); red by verb \(start.redByVerb.sorted { $0.key < $1.key })")
        print("SHM1 S1.1 \(name) writers: \(total.line)")
        print("SHM1 S1.1 \(name) red by verb: \(total.redByVerb.sorted { $0.key < $1.key }); "
              + "accepted by verb: \(total.acceptedByVerb.sorted { $0.key < $1.key })")
        print("SHM1 S1.1 \(name) red by writer: \(total.redByWriter.sorted { $0.key < $1.key })")
        total.add(start)
        print("SHM1 S1.1 \(name) total: \(total.line)")
        return total
    }

    // MARK: - Every input verb after every writer

    func testS1_1EveryInputVerbAfterEveryWriterE1Binary() throws {
        _ = try s11 { try self.mainLeg(ternary: false, start: $0) }
    }

    func testS1_1EveryInputVerbAfterEveryWriterE1Ternary() throws {
        _ = try s11 { try self.mainLeg(ternary: true, start: $0) }
    }

    func testS1_1EveryInputVerbAfterEveryWriterFold() throws {
        _ = try s11 { try self.foldLeg(start: $0) }
    }

    func testS1_1EveryInputVerbAfterEveryWriterViewSealed() throws {
        guard CortexFixture.envPath != nil else { throw XCTSkip("DAGDB_CORTEX_V4_FIXTURE not set — the VIEW leg skipped") }
        _ = try s11 { try self.viewLeg(start: $0)! }
    }

    /// The defect's own cases, by name: a never-written buffer (daemon start)
    /// is refused by every input verb, BANK GENERATE and XCONV SEALED among them.
    func testS1_1NeverWrittenBufferIsRefusedByEveryInputVerb() throws {
        var t = Tally()
        for vi in 0..<14 {
            let s = try mainLeg(ternary: false, start: true)
            cell(s.name, s.f, s.walPath, inputs(s.f)[vi], nil, &t)
        }
        XCTAssertEqual(t.green, 14)
        print("SHM1 S1.1 never-written buffer, E1 24² binary: \(t.line)")
    }

    // MARK: - The count

    /// A marked frame whose word0 is not the count the verb reads is refused
    /// by the bad_value line, nothing written. For CONNECT_BACK_BULK and
    /// SET_TRUTH_BULK the count is word0 itself, so there is no other count
    /// to differ from; they are listed as not applicable.
    func testS1_3AMarkedFrameWithAnotherCountIsRefused() throws {
        var cells = 0, green = 0
        var red: [String: Int] = [:]
        for vi in 0..<14 {
            let (f, walPath) = try walFixture(side: 16)
            try E1.buildGraph(f.handler.engine, seed: 0x5A1_0300, ternary: false)
            twinInputs(f)
            let v = inputs(f)[vi]
            if v.framed { continue }
            var wrong = [v.count + 1, v.count - 1, 0, Int(UInt32.max)].filter { $0 >= 0 && $0 != v.count }
            wrong = Array(Set(wrong)).sorted()
            for k in wrong {
                v.write()
                f.shm.storeBytes(of: UInt32(k), toByteOffset: 0, as: UInt32.self)
                let before = snap(f, walPath)
                let reply = f.handler.handle(v.line)
                let after = snap(f, walPath)
                cells += 1
                let want = Self.badCount(v.verb, UInt32(k), v.count)
                if reply == want && after == before { green += 1; continue }
                red[v.verb, default: 0] += 1
                XCTFail("SHM1 S1.3 \(v.verb): frame count \(k), the verb reads \(v.count): '\(reply.prefix(150))'"
                        + (after == before ? "" : "; the state, the WAL or the buffer changed"))
            }
        }
        XCTAssertEqual(cells, 47, "11 verbs x 4 wrong counts, TTABLE_BULK (count 1) x 3")
        print("SHM1 S1.3: \(cells) cells over the 12 verbs with a daemon or line count, green \(green), red \(cells - green) "
              + "by verb \(red.sorted { $0.key < $1.key }); CONNECT_BACK_BULK and SET_TRUTH_BULK: not applicable (count = word0)")
    }

    // MARK: - The order

    /// The pre-read refusals of the 14 verbs (argument, reader-session,
    /// overflow and capacity checks), each under
    /// four buffer states: never written (0, 0), a writer's header (7, 24),
    /// a v1 framed header (3, 8), a header marked for the verb with an
    /// unrelated count (5, its mark). Every reply is the literal the old build gives; the same
    /// assertions pass on the frozen commit's build (the red run) and on the
    /// new one.
    func testS1_4PreReadRefusalsAnswerAsBefore() throws {
        let states: [(UInt32, UInt32?)] = [(0, 0), (7, 24), (3, 8), (5, nil)]   // nil: the case's verb's mark
        // A 20-byte buffer: every verb's input is larger.
        let (c, _) = try walFixture(side: 4, shmBytes: 20)
        twinInputs(c)
        let crid = try openReader(c)
        // A side-16 buffer (6,152 bytes) for the argument and the larger capacity cases.
        let (d, _) = try walFixture(side: 16)
        try E1.buildGraph(d.handler.engine, seed: 0x5A1_0400, ternary: false)
        twinInputs(d)
        let drid = try openReader(d)
        let huge = 2_305_843_009_213_693_951
        let cap20 = "shm capacity 20", cap = "shm capacity 6152"
        let cases: [(HandlerFixture, String, String)] = [
            (c, "SET_RANKS_BULK", "ERROR out_of_range: result needs 136 bytes, shm holds 20"),
            (c, "SET_LUTS_BULK", "ERROR out_of_range: result needs 136 bytes, shm holds 20"),
            (c, "SET_NEIGHBORS_BULK", "ERROR out_of_range: result needs 392 bytes, shm holds 20"),
            (c, "SET_MODES_BULK", "ERROR out_of_range: result needs 24 bytes, shm holds 20"),
            (c, "SET_TTABLE_IDS_BULK", "ERROR out_of_range: result needs 40 bytes, shm holds 20"),
            (c, "SET_THRESH_BULK", "ERROR out_of_range: result needs 136 bytes, shm holds 20"),
            (c, "TTABLE_BULK 0 1", "ERROR out_of_range: result needs 737 bytes, shm holds 20"),
            (c, "XCONV CHECK 3 3 1 1 1", "ERROR out_of_range: XCONV CHECK input 40 bytes exceeds \(cap20)"),
            (c, "XCONV SEALED k00000001 2", "ERROR out_of_range: XCONV SEALED input 40 bytes exceeds \(cap20)"),
            (c, "BUDGET OPEN 2 1 1", "ERROR out_of_range: BUDGET OPEN input 28 bytes exceeds \(cap20)"),
            (c, "BANK GENERATE w00000001 1", "ERROR out_of_range: BANK GENERATE input 32 bytes exceeds \(cap20)"),
            (c, "BANK FIT w00000001", "ERROR out_of_range: BANK FIT input 264 bytes exceeds \(cap20)"),
            (c, "READER \(crid) XCONV SEALED k00000001 2", "ERROR out_of_range: XCONV SEALED input 40 bytes exceeds \(cap20)"),
            (c, "READER \(crid) BANK FIT w00000001", "ERROR out_of_range: BANK FIT input 264 bytes exceeds \(cap20)"),
            (d, "TTABLE_BULK 0 0", "ERROR bad_value: ternary: table count 0 not in 1...65536"),
            (d, "TTABLE_BULK 0 65537", "ERROR bad_value: ternary: table count 65537 not in 1...65536"),
            (d, "TTABLE_BULK 0 9", "ERROR out_of_range: result needs 6569 bytes, shm holds 6152"),
            (d, "TTABLE_BULK 5 1", "ERROR bad_value: ternary: table id 5 leaves a gap: the library holds 1 table(s), ids 0..<1; define id 1 next"),
            (d, "XCONV CHECK -1 1 1 1 0", "ERROR out_of_range: XCONV CHECK counts must be non-negative"),
            (d, "XCONV CHECK \(huge) 1 1 1 0",
             "ERROR out_of_range: XCONV CHECK input byte count overflows Int for nA=\(huge) nB=1 kA=1 kB=1; shm holds 6152"),
            (d, "XCONV CHECK 2000 72 6 9 16", "ERROR out_of_range: XCONV CHECK input 8356 bytes exceeds \(cap)"),
            (d, "XCONV SEALED k00000001 1", "ERROR out_of_range: n must be >= 2"),
            (d, "XCONV SEALED k09999999 128 100", "ERROR not_found: \"k09999999\""),
            (d, "XCONV SEALED k00000001 \(huge)",
             "ERROR out_of_range: XCONV SEALED input byte count overflows Int for n=\(huge); shm holds 6152"),
            (d, "XCONV SEALED k00000001 1000", "ERROR out_of_range: XCONV SEALED input 16008 bytes exceeds \(cap)"),
            (d, "XCONV SEALED k00000001 128", "ERROR bad_value: warmup: neither derived (TAU/SIGMA) nor declared"),
            (d, "XCONV SEALED k00000001 100 100", "ERROR out_of_range: warmup 100 must be < n 100"),
            (d, "XCONV SEALED k00000001 300 2048",
             "ERROR bad_value: XCONV SEALED refused: warmup 2048 leaves no comparison window against window_samples 2048 (taps 2048)"),
            (d, "BUDGET OPEN -1 1 1", "ERROR out_of_range: BUDGET OPEN dimensions must be non-negative"),
            (d, "BUDGET OPEN 4000000000 4000000000 0",
             "ERROR out_of_range: BUDGET OPEN input byte count overflows Int for nPockets=4000000000 nTiers=4000000000 nClasses=0; shm holds 6152"),
            (d, "BUDGET OPEN 100 100 0", "ERROR out_of_range: BUDGET OPEN input 80008 bytes exceeds \(cap)"),
            (d, "BANK GENERATE w00000001 0", "ERROR out_of_range: M must be >= 1"),
            (d, "BANK GENERATE w09999999 1", "ERROR not_found: \"w09999999\""),
            (d, "BANK GENERATE w00000001 300", "ERROR out_of_range: BANK GENERATE input 7208 bytes exceeds \(cap)"),
            (d, "BANK GENERATE w00000001 30", "ERROR out_of_range: BANK GENERATE output 7688 bytes exceeds \(cap)"),
            (d, "BANK FIT w09999999", "ERROR not_found: \"w09999999\""),
            (d, "READER \(drid) XCONV SEALED k00000001 1", "ERROR out_of_range: n must be >= 2"),
            (d, "READER \(drid) BANK GENERATE w00000001 0", "ERROR out_of_range: M must be >= 1"),
            (d, "READER \(drid) XCONV CHECK -1 1 1 1 0", "ERROR out_of_range: XCONV CHECK counts must be non-negative"),
        ] + ["SET_RANKS_BULK", "SET_LUTS_BULK", "SET_NEIGHBORS_BULK", "SET_MODES_BULK", "SET_TTABLE_IDS_BULK",
             "SET_THRESH_BULK", "TTABLE_BULK 0 1", "CONNECT_BACK_BULK", "SET_TRUTH_BULK"].map {
            (d, "READER \(drid) \($0)", Self.forbidden)
        } + [(d, "READER \(drid) BUDGET OPEN 1 1 1",
              "ERROR forbidden: twin verb mutates daemon-global twin state; not allowed in reader session")]
        var cells = 0, green = 0
        for (f, line, want) in cases {
            for (w0, w1v) in states {
                let w1 = w1v ?? shm1Word1(Self.verbOf(line))
                f.shm.storeBytes(of: w0, toByteOffset: 0, as: UInt32.self)
                f.shm.storeBytes(of: w1, toByteOffset: 4, as: UInt32.self)
                let before = Data(bytes: f.shm, count: f.shmBytes)
                let reply = f.handler.handle(line)
                cells += 1
                if reply == want && Data(bytes: f.shm, count: f.shmBytes) == before { green += 1; continue }
                XCTFail("SHM1 S1.4 '\(line)' under header (\(w0), \(w1)): got '\(reply)'\n want '\(want)'")
            }
        }
        print("SHM1 S1.4 pre-read refusals: \(cases.count) refusals × \(states.count) buffer states = \(cells) cells, green \(green)")
    }

    /// The two framed verbs read their count from word0, so their mark check
    /// stands first, in the row-size check's place: an
    /// unmarked header-only frame with a huge count is stale_frame; marked,
    /// the same frame answers today's capacity refusal, and a
    /// marked frame of count 0 answers OK with nothing to do.
    func testS1_4HeaderOnlyFrames() throws {
        var cells = 0, green = 0
        for verb in ["CONNECT_BACK_BULK", "SET_TRUTH_BULK"] {
            let (f, walPath) = try walFixture(side: 4)
            let cap = f.shmBytes
            let zero = verb == "CONNECT_BACK_BULK" ? "OK CONNECT_BACK_BULK edges=0 back_edges=0" : "OK SET_TRUTH_BULK nodes=0"
            var frames: [(UInt32, UInt32, String)] = []
            for k in [UInt32(1_000_000), UInt32.max] {
                frames.append((k, 8, Self.stale(verb, k, 8, Int(k))))
                frames.append((k, 0, Self.stale(verb, k, 0, Int(k))))
                frames.append((k, shm1Word1(.named(verb)), "ERROR out_of_range: result needs \(Int(k) * 8 + 8) bytes, shm holds \(cap);"
                               + " \(verb) count \(k) (row 8) does not fit; nothing written"))
            }
            frames += [(0, 8, Self.stale(verb, 0, 8, 0)), (0, 0, Self.stale(verb, 0, 0, 0)), (1, 4, Self.stale(verb, 1, 4, 1)),
                       (0, shm1Word1(.named(verb)), zero)]
            for (w0, w1, want) in frames {
                f.shm.storeBytes(of: w0, toByteOffset: 0, as: UInt32.self)
                f.shm.storeBytes(of: w1, toByteOffset: 4, as: UInt32.self)
                let before = snap(f, walPath)
                let reply = f.handler.handle(verb)
                let after = snap(f, walPath)
                cells += 1
                if reply == want && after == before { green += 1; continue }
                XCTFail("SHM1 S1.4 \(verb) header (\(w0), \(w1)): got '\(reply)'\n want '\(want)'"
                        + (after == before ? "" : "; the state, the WAL or the buffer changed"))
            }
        }
        print("SHM1 S1.4 header-only frames: \(cells) cells, green \(green)")
    }

    // MARK: - STATUS ends with client_protocol=2 (in-process half; the prefix against the old build runs over the wire)

    func testS1_5StatusEndsWithClientProtocol2() throws {
        let f = try HandlerFixture(side: 4)
        let s = f.handler.handle("STATUS")
        XCTAssertTrue(s.hasSuffix(" client_protocol=2"), s)
        XCTAssertEqual(s.components(separatedBy: "client_protocol=").count, 2, s)
        let prefix = String(s.dropLast(" client_protocol=2".count))
        XCTAssertTrue(prefix.hasPrefix("OK STATUS nodes=16 ticks=0 gpu="), prefix)
        XCTAssertTrue(prefix.hasSuffix(" twin_open=0 tiled_open=0 tiled_refused=0"), prefix)
        let rid = try openReader(f)
        let r = f.handler.handle("READER \(rid) STATUS")
        XCTAssertEqual(r, "OK STATUS session=\(rid) nodes=16 grid=4x4 client_protocol=2")
        print("SHM1 S1.5 STATUS: '\(s)'; READER STATUS: '\(r)'")
    }
}
