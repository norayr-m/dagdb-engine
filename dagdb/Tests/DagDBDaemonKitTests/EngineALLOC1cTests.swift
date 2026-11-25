/// In process:
/// - a twin record its own decoder would refuse is refused by the appender, by name, before a byte is written;
///   the largest legal record round-trips; the main WAL's typed appenders refuse a shape replay would not apply.
/// - LOAD and the startup load refuse a twin section over a live cap or with a ring set's shape a live open
///   refuses; a log from before the caps replays faithfully and the boot names the excess.
/// - SAVE, LOAD's decode, the files a snapshot names, banks, hook rows and the boot are admitted; a refusal
///   names its bytes; SAVE's token bound covers what the encoder writes for every kind.
/// - replay reads the log in bounded windows; its scan matches the whole-log rules byte for byte.
/// The live checks (red on main, controls, the measured peaks) run on sandbox daemons.
///
/// Amateur engineering project; no competitive claims; errors likely.
import XCTest
import Foundation
import CryptoKit
@testable import DagDB
@testable import DagDBDaemonKit

final class EngineALLOC1cTests: XCTestCase {
    private var tmpDir: String!

    override func setUpWithError() throws {
        // DAGDB_TEST_SCRATCH (the build's scratch) when set: NSTemporaryDirectory() ignores TMPDIR here.
        let env = ProcessInfo.processInfo.environment["DAGDB_TEST_SCRATCH"] ?? ""
        tmpDir = (env.isEmpty ? NSTemporaryDirectory() : env + "/") + "dagdb-alloc1c-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    private func bytes(_ path: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }

    /// A BUDGET OPEN frame: p*t f64 costs, then c u32 classes, at shm offset 8.
    private func budgetFrame(_ f: HandlerFixture, p: Int, t: Int, c: Int) {
        shm1Header(f.shm, count: p * t + c, verb: .budgetOpen)
        let d = f.shm.advanced(by: 8).bindMemory(to: Double.self, capacity: max(p * t, 1))
        for i in 0..<(p * t) { d[i] = Double(i % 7 + 1) }
        let u = f.shm.advanced(by: 8 + 8 * p * t).bindMemory(to: UInt32.self, capacity: max(c, 1))
        for i in 0..<c { u[i] = UInt32(i % max(t, 1)) }
    }

    // MARK: - Twin records the decoder would refuse

    func testC1AnOversizedTwinRecordIsRefusedByNameBeforeAByteIsWritten() throws {
        let walPath = tmpDir + "c1.wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 65536)
        let f = try HandlerFixture(side: 256, wal: wal)
        let before = try bytes(walPath)
        budgetFrame(f, p: 20, t: 6553, c: 0)
        XCTAssertEqual(f.handler.handle("BUDGET OPEN 20 6553 0"),
                       "ERROR wal: append: TWIN_LAYOUT_OPEN b00000001: the record's payload is 1048579 bytes, above the"
                       + " 1048576-byte cap its replay decodes (TwinWALCodec.maxPayloadBytes), so a restart would drop it;"
                       + " refused before a byte was written, nothing changed")
        XCTAssertEqual(try bytes(walPath), before, "the WAL is byte-identical")
        XCTAssertEqual(f.handler.twin.layouts.openCount, 0)
        XCTAssertEqual(f.handler.twin.nextId(prefix: "b"), "b00000001", "no id consumed")
        // The largest record a live verb can write (19 + 4k bytes never equals 2^20): accepted, and it replays.
        budgetFrame(f, p: 20, t: 6552, c: 39)
        XCTAssertEqual(f.handler.handle("BUDGET OPEN 20 6552 39"), "OK BUDGET OPEN id=b00000001 pockets=20 tiers=6552 classes=39")
        XCTAssertEqual(try bytes(walPath).count, before.count + 5 + 1_048_575)
        let g = try HandlerFixture(side: 256)
        let r = try DagDBWAL.replay(engine: g.handler.engine, nodeCount: 65536, path: walPath, twin: g.handler.twin, wholeLog: true)
        XCTAssertEqual(r.recordsSkipped, 0)
        XCTAssertEqual(g.handler.twin.layouts.get("b00000001"), f.handler.twin.layouts.get("b00000001"))
    }

    func testC1TheCapIsTheDecodersOwnBoundary() throws {
        let walPath = tmpDir + "cap.wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 16)
        // RINGS WRITE n1 with 262,142 values: 2 + 2 + 4 + 4*262142 = 1,048,576 payload bytes, exactly the cap.
        let atCap = TwinOp.ringsWrite(id: "n1", values: [Float](repeating: 0.5, count: 262_142))
        XCTAssertEqual(try TwinWALCodec.encode(atCap).payload.count, TwinWALCodec.maxPayloadBytes)
        XCTAssertNoThrow(try wal.twin(atCap))
        XCTAssertNotNil(TwinWALCodec.decode(opcode: DagDBWAL.Opcode.twinRingsWrite.rawValue, payload: try TwinWALCodec.encode(atCap).payload))
        let n = try bytes(walPath).count
        let over = TwinOp.ringsWrite(id: "n12", values: [Float](repeating: 0.5, count: 262_142))
        XCTAssertThrowsError(try wal.twin(over)) {
            XCTAssertEqual(Reply.errorWords($0), "TWIN_RINGS_WRITE n12: the record's payload is 1048577 bytes, above the 1048576-byte"
                           + " cap its replay decodes (TwinWALCodec.maxPayloadBytes), so a restart would drop it; refused before a"
                           + " byte was written, nothing changed")
        }
        // A record the decoder refuses for its shape: a sweep that names no binding (decode wants n >= 1).
        XCTAssertThrowsError(try wal.twin(.hookSweep(bindings: []))) {
            XCTAssertTrue(Reply.errorWords($0).hasPrefix("TWIN_HOOK_SWEEP : its 4-byte payload is one the log's replay cannot decode"), Reply.errorWords($0))
        }
        XCTAssertEqual(try bytes(walPath).count, n, "neither refusal wrote a byte, nor upgraded the header")
        XCTAssertEqual(try bytes(walPath)[4], 3, "still version 3: the sweep's refusal came before its upgrade")
    }

    func testA3ARecordReplayWouldReadBackChangedIsRefusedByName() throws {
        let walPath = tmpDir + "rt.wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 16)
        let n = try bytes(walPath).count
        // A leading U+FEFF, which Foundation's UTF-8 decode drops.
        XCTAssertThrowsError(try wal.twin(.streamOpen(id: "s00000001", name: "\u{FEFF}bom", stateHi: 1, stateLo: 2, incHi: 3, incLo: 5))) {
            XCTAssertEqual(Reply.errorWords($0), "TWIN_STREAM_OPEN s00000001: its replay would read back a different record (a field the log"
                           + " cannot hold as given: a string's leading U+FEFF, or a value wider than its 32-bit slot), so a restart would"
                           + " change it; refused before a byte was written, nothing changed")
        }
        // A declared WARMUP above the u32 slot.
        XCTAssertThrowsError(try wal.twin(.kernelLoad(id: "k00000001", path: "/k.json", sha256: "ab", tauA: 1, tauB: 2,
                                                      sigmaSource: 0.5, declaredWarmup: 4_294_967_301))) {
            XCTAssertTrue(Reply.errorWords($0).hasPrefix("TWIN_KERNEL_LOAD k00000001: its replay would read back a different record"), Reply.errorWords($0))
        }
        XCTAssertEqual(try bytes(walPath).count, n, "nothing written")
        // A BOM inside a name, the largest u32 warmup, and a NaN value still round-trip and are written.
        XCTAssertNoThrow(try wal.twin(.streamOpen(id: "s00000001", name: "in\u{FEFF}side", stateHi: 1, stateLo: 2, incHi: 3, incLo: 5)))
        XCTAssertNoThrow(try wal.twin(.kernelLoad(id: "k00000001", path: "/k.json", sha256: "ab", tauA: nil, tauB: nil,
                                                  sigmaSource: nil, declaredWarmup: Int(UInt32.max))))
        XCTAssertNoThrow(try wal.twin(.ringsWrite(id: "n00000001", values: [.nan, 1.5])))
        // Through the daemon: STREAM OPEN with a BOM-leading name is refused by name, nothing opened.
        let f = try HandlerFixture(side: 4, wal: wal)
        let r = f.handler.handle("STREAM OPEN \u{FEFF}bomstream 0x1 0x2 0x3 0x5")
        XCTAssertTrue(r.hasPrefix("ERROR wal: append: TWIN_STREAM_OPEN s00000001: its replay would read back a different record"), r)
        XCTAssertEqual(f.handler.twin.streams.openCount, 0)
    }

    func testC1TheMainWALsTypedAppendersRefuseAShapeReplayWouldNotApply() throws {
        let walPath = tmpDir + "shape.wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 16)
        let n = try bytes(walPath).count
        let ranks = [UInt64](repeating: 1, count: 15)
        XCTAssertThrowsError(try ranks.withUnsafeBufferPointer { try wal.setRanksBulk($0.baseAddress!, count: 15) }) {
            XCTAssertEqual(Reply.errorWords($0), "opcode 0x14: its count is 15; replay applies only a count equal to the log's 16"
                           + " nodes; refused before a byte was written, nothing changed")
        }
        let pairs = (0..<256).map { DagDBEngine.LutPair(from: UInt64($0), to: 1) }
        XCTAssertThrowsError(try wal.setLuts(.nodes(0, 1), .map(mask: 1, pairs: pairs))) {
            XCTAssertTrue(Reply.errorWords($0).hasPrefix("opcode 0x4f: a SET_LUTS payload of"), Reply.errorWords($0))
        }
        XCTAssertEqual(try bytes(walPath).count, n)
        // Every shape the typed appenders write passes the mirror.
        XCTAssertNoThrow(try wal.setTruth(node: 1, value: 1))
        XCTAssertNoThrow(try wal.setLuts(.nodes(0, 1), .map(mask: 1, pairs: Array(pairs.prefix(16)))))
        XCTAssertNoThrow(try wal.connectBackBulk([(src: 1, dst: 2)]))
    }

    // MARK: - Caps on load and at the startup load

    /// A v7 snapshot of a side x side engine (4 unless named) whose twin section is `twin`'s export, in `dir`.
    private func snapshot(_ name: String, _ twin: TwinState, side: Int = 4, dir: String? = nil) throws -> String {
        let grid = try HexGrid(width: side, height: side)
        let engine = try DagDBEngine(grid: grid, state: DagDBState(width: side, height: side), maxRank: 8)
        let n = side * side
        let nb = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        for i in 0..<(n * 6) { nb[i] = -1 }
        let path = (dir ?? tmpDir) + name
        _ = try DagDBSnapshot.save(engine: engine, nodeCount: n, gridW: side, gridH: side, tickCount: 0, path: path, twin: twin)
        return path
    }

    /// The same file with `old` replaced by `new` (same length) in its twin JSON, and its manifest rewritten.
    private func patched(_ path: String, _ old: String, _ new: String) throws -> String {
        XCTAssertEqual(old.utf8.count, new.utf8.count)
        var d = try bytes(path)
        guard let r = d.range(of: Data(old.utf8)) else { XCTFail("\(old) not in \(path)"); return path }
        d.replaceSubrange(r, with: Data(new.utf8))
        try d.write(to: URL(fileURLWithPath: path))
        try Data(DagDBSnapshot.sha256Hex(d).utf8).write(to: URL(fileURLWithPath: DagDBSnapshot.manifestPathFor(path)))
        return path
    }

    func testC2LoadRefusesATwinSectionOverACapOrWithARingShapeALiveOpenRefuses() throws {
        let clocks = TwinState()
        for i in 1...1025 { try clocks.apply(.clockOpen(id: TwinIdFormat.format(prefix: "c", UInt64(i)))) }
        let rec = TwinState()
        let header = StreamHeader(signalBandHz: 1500, tauWindowSec: 0.6827, combRateHz: 3000, firstEchoSec: 1.0,
                                  recordWindowSec: 0.6827, stepSec: 0.00001, clockSyncFloorSec: 0)
        try rec.apply(.recordOpen(id: "t00000001", name: "court", header: header, stateHi: 1, stateLo: 2, incHi: 3, incLo: 5))
        for _ in 0..<4097 { try rec.apply(.recordSlice(id: "t00000001", count: 1)) }
        let rings = TwinState()
        try rings.apply(.ringsOpen(id: "n00000001", gear: 6, rings: 6, cells: 32))
        let cases: [(String, String)] = [
            (try snapshot("clocks.dags", clocks), "it holds 1025 clocks, above the clocks cap of 1024 a live open allows"),
            (try snapshot("slices.dags", rec), "record t00000001 holds 4097 slices, above the cap of 4096 RECORD SLICE allows"),
            (try patched(try snapshot("cells.dags", rings), "\"cellsPerRing\":32", "\"cellsPerRing\":17"),
             "ring set n00000001: its ring 0 holds 32 cells, its cellsPerRing field says 17, a shape RINGS OPEN refuses"),
            (try patched(try snapshot("gear.dags", rings), "\"gear\":6", "\"gear\":1"),
             "ring set n00000001: gear 1 must be >= 2, a shape RINGS OPEN refuses"),
            (try patched(try snapshot("rings.dags", rings), "\"rings\":6", "\"rings\":7"),
             "ring set n00000001: its cells array holds 6 rings, its rings field says 7, a shape RINGS OPEN refuses"),
        ]
        for (path, why) in cases {
            let f = try HandlerFixture(side: 4)
            XCTAssertTrue(f.handler.handle("CLOCK OPEN").hasPrefix("OK"))
            XCTAssertEqual(f.handler.handle("LOAD \(path)"), "ERROR io: load: v7 twin section refused: \(why); nothing loaded")
            XCTAssertEqual(f.handler.twin.totalOpen, 1, "nothing changed")
            XCTAssertNotNil(f.handler.twin.clocks.get("c00000001"))
            // The startup load: a ring shape no build writes refuses the start, naming the cause,
            // the file and the remedy; over-cap COUNTS are the era's, loaded and named.
            let g = try HandlerFixture(side: 4)
            var lines: [String] = []
            let start = { try DagDBStartup.recover(engine: g.handler.engine, nodeCount: 16, width: 4, height: 4,
                                                   dagdbEnv: nil, dataRoot: nil, twin: g.handler.twin,
                                                   truthRankIndex: g.handler.truthRankIndex, snapshotPath: path,
                                                   walPath: nil, log: { lines.append($0) }) }
            if why.contains("ring set") {
                XCTAssertThrowsError(try start()) {
                    XCTAssertEqual(Reply.errorWords($0), "startup snapshot refused: '\(path)' — v7 twin section refused: \(why):"
                                   + " the file holds a shape no build writes (corruption); start from a good snapshot or the backup"
                                   + " chain (BACKUP RESTORE), or set DAGDB_STARTUP_LOAD to another snapshot; refusing to start")
                }
            } else {
                XCTAssertNoThrow(try start())
                XCTAssertTrue(lines.contains { $0.hasPrefix("  WARN: the startup snapshot") }, lines.joined(separator: "\n"))
            }
        }
        // The era's own case: an over-cap state replayed from an old log, SAVEd to the startup path, starts again.
        do {
            let walPath = tmpDir + "era.wal", base = tmpDir + "era.dags"
            do {
                let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 16)
                for i in 1...1030 { _ = try wal.twin(.ringsOpen(id: TwinIdFormat.format(prefix: "n", UInt64(i)), gear: 3, rings: 2, cells: 4)) }
            }
            let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 16)
            let f = try HandlerFixture(side: 4, wal: wal)
            f.handler.startupSnapshotPath = base
            _ = try DagDBStartup.recover(engine: f.handler.engine, nodeCount: 16, width: 4, height: 4, dagdbEnv: nil, dataRoot: nil,
                                         twin: f.handler.twin, truthRankIndex: f.handler.truthRankIndex, snapshotPath: base,
                                         walPath: walPath, log: { _ in })
            XCTAssertTrue(f.handler.handle("SAVE \(base)").hasPrefix("OK SAVE"))
            XCTAssertTrue(f.handler.handle("LOAD \(base)").hasPrefix("ERROR io: load: v7 twin section refused: it holds 1030 rings"),
                          "a live LOAD is a new import: refused")
            let g = try HandlerFixture(side: 4)
            var lines: [String] = []
            XCTAssertNoThrow(try DagDBStartup.recover(engine: g.handler.engine, nodeCount: 16, width: 4, height: 4, dagdbEnv: nil,
                                                       dataRoot: nil, twin: g.handler.twin, truthRankIndex: g.handler.truthRankIndex,
                                                       snapshotPath: base, walPath: walPath, log: { lines.append($0) }))
            XCTAssertEqual(g.handler.twin.rings.openCount, 1030)
            XCTAssertTrue(lines.contains("  WARN: the startup snapshot holds rings count 1030, above the cap 1,024 (state an older build"
                                         + " held, carried by SAVE); new opens are refused until below"), lines.joined(separator: "\n"))
            XCTAssertFalse(lines.contains { $0.contains("WARN: replayed rings") }, "named once, from the snapshot")
            XCTAssertEqual(g.handler.handle("RINGS OPEN"), "ERROR out_of_budget: RINGS OPEN needs 1031 open rings, the rings cap is 1024; nothing written")
        }
        // At the caps exactly, the same files load.
        let atCap = TwinState()
        for i in 1...1024 { try atCap.apply(.clockOpen(id: TwinIdFormat.format(prefix: "c", UInt64(i)))) }
        let f = try HandlerFixture(side: 4)
        XCTAssertTrue(f.handler.handle("LOAD \(try snapshot("cap.dags", atCap))").hasPrefix("OK LOAD"))
        XCTAssertEqual(f.handler.twin.clocks.openCount, 1024)
    }

    func testC2ALogFromBeforeTheCapsReplaysFaithfullyAndTheBootNamesTheExcess() throws {
        // What an older daemon, before the registry caps, wrote: 1,025 CLOCK OPEN records (the codec's bytes, as it appended them).
        let walPath = tmpDir + "old.wal"
        do {
            let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 16)
            for i in 1...1025 { _ = try wal.twin(.clockOpen(id: TwinIdFormat.format(prefix: "c", UInt64(i)))) }
        }
        let f = try HandlerFixture(side: 4)
        var lines: [String] = []
        _ = try DagDBStartup.recover(engine: f.handler.engine, nodeCount: 16, width: 4, height: 4, dagdbEnv: nil,
                                     dataRoot: nil, twin: f.handler.twin, truthRankIndex: f.handler.truthRankIndex,
                                     snapshotPath: nil, walPath: walPath, log: { lines.append($0) })
        XCTAssertEqual(f.handler.twin.clocks.openCount, 1025, "replayed as that daemon held it, not refused")
        XCTAssertTrue(lines.contains("  WARN: replayed clocks count 1025 exceeds the cap 1,024; new opens are refused until below"),
                      lines.joined(separator: "\n"))
        XCTAssertEqual(f.handler.handle("CLOCK OPEN"),
                       "ERROR out_of_budget: CLOCK OPEN needs 1026 open clocks, the clocks cap is 1024; nothing written")
        XCTAssertTrue(f.handler.handle("CLOCK CLOSE c00000001").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("CLOCK CLOSE c00000002").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("CLOCK OPEN").hasPrefix("OK CLOCK OPEN"), "below the cap again")
    }

    /// The files for the live check of the caps (grid 64, 4,096 nodes), written only when DAGDB_ALLOC1C_FIXTURES
    /// names a directory: the snapshots over each cap and with each bad ring shape, one at the cap, and a log from
    /// before the caps (1,025 CLOCK OPEN records, as the codec appends them). That check LOADs and boots them on an
    /// older build, this build and a control build.
    func testZWriteTheLiveC2GatesFiles() throws {
        let out = ProcessInfo.processInfo.environment["DAGDB_ALLOC1C_FIXTURES"] ?? ""
        guard !out.isEmpty else { throw XCTSkip("DAGDB_ALLOC1C_FIXTURES not set: the live gate's files are not written") }
        let dir = out + "/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func clocks(_ k: Int) throws -> TwinState {
            let t = TwinState(); for i in 1...k { try t.apply(.clockOpen(id: TwinIdFormat.format(prefix: "c", UInt64(i)))) }; return t
        }
        _ = try snapshot("clocks1025.dags", try clocks(1025), side: 64, dir: dir)
        _ = try snapshot("clocks1024.dags", try clocks(1024), side: 64, dir: dir)
        let rec = TwinState()
        let header = StreamHeader(signalBandHz: 1500, tauWindowSec: 0.6827, combRateHz: 3000, firstEchoSec: 1.0,
                                  recordWindowSec: 0.6827, stepSec: 0.00001, clockSyncFloorSec: 0)
        try rec.apply(.recordOpen(id: "t00000001", name: "court", header: header, stateHi: 1, stateLo: 2, incHi: 3, incLo: 5))
        for _ in 0..<4097 { try rec.apply(.recordSlice(id: "t00000001", count: 1)) }
        _ = try snapshot("slices4097.dags", rec, side: 64, dir: dir)
        let rings = TwinState()
        try rings.apply(.ringsOpen(id: "n00000001", gear: 6, rings: 6, cells: 32))
        _ = try patched(try snapshot("ringcells.dags", rings, side: 64, dir: dir), "\"cellsPerRing\":32", "\"cellsPerRing\":17")
        _ = try patched(try snapshot("ringgear.dags", rings, side: 64, dir: dir), "\"gear\":6", "\"gear\":1")
        _ = try patched(try snapshot("ringrings.dags", rings, side: 64, dir: dir), "\"rings\":6", "\"rings\":7")
        let wal = try DagDBWAL.Appender(path: dir + "prealloc1c.wal", nodeCount: 4096)
        for i in 1...1025 { _ = try wal.twin(.clockOpen(id: TwinIdFormat.format(prefix: "c", UInt64(i)))) }
    }

    // MARK: - Admission of SAVE, LOAD's decode, named files, banks, hook rows and the boot

    private func budget(_ f: HandlerFixture, bytes: Int, footprint: Int) {
        f.handler.memoryBudget = DaemonMemoryBudget(budgetBytes: bytes, source: "--mem-budget-gb", footprint: { footprint },
                                                    fixedStateBytes: 0)
    }

    func testC3SaveIsAdmittedOnItsTokensBeforeAnythingIsWritten() throws {
        let f = try HandlerFixture(side: 4)
        for _ in 0..<4 { XCTAssertTrue(f.handler.handle("RINGS OPEN 6 16 64").hasPrefix("OK")) }
        let tokens = f.handler.twin.exportTokenBound(), strings = f.handler.twin.exportStringBytes()
        XCTAssertEqual(tokens, 61 + 4 * (40 + 9 * 16 * 64))
        XCTAssertEqual(strings, try encodedStringBytes(f.handler.twin.export()), "S is the string bytes the encoder writes")
        budget(f, bytes: 2_000_000, footprint: 0)
        let path = tmpDir + "s.dags"
        // The body's transient is in SAVE's charge too.
        let body = AdmissionCharge.saveBody(compressed: false, nodes: 16, v8: false, backEdges: 0, libraryBytes: 0)
        let need = Int((1.1 * (79.0 * Double(tokens) + 2.95 * Double(strings) + body)).rounded(.up))
        XCTAssertEqual(f.handler.handle("SAVE \(path)"),
                       "ERROR out_of_budget: SAVE needs \(need) bytes (the twin section's encode, 1.1*(79.0 B per token + 2.95 B"
                       + " per escaped string byte) for \(tokens) tokens and \(strings) string bytes, counted from the registries,"
                       + " and the body's write, the digest's read of at most 8 MiB, 16 B per back edge for 0 and 320 KiB),"
                       + " the budget is 2000000; nothing written footprint=0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        budget(f, bytes: 8 << 20, footprint: 0)
        XCTAssertTrue(f.handler.handle("SAVE \(path)").hasPrefix("OK SAVE"))
        // Names' bytes count, escaped as JSONEncoder writes them ('/' as two bytes).
        let g = try HandlerFixture(side: 4)
        XCTAssertTrue(g.handler.handle("STREAM OPEN " + String(repeating: "/", count: 100) + " 0x1 0x2 0x3 0x5").hasPrefix("OK"))
        XCTAssertEqual(g.handler.twin.exportStringBytes(), try encodedStringBytes(g.handler.twin.export()))
        XCTAssertGreaterThanOrEqual(g.handler.twin.exportStringBytes(), 11 + 202, "the id and the name escaped")
    }

    /// The escaped string bytes (keys and values, quotes included) actually present in `JSONEncoder`'s output for
    /// `value`, encoded as SAVE encodes the twin section (`.sortedKeys`), read off the bytes.
    private func encodedStringBytes<T: Encodable>(_ value: T) throws -> Int {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        let d = try e.encode(value)
        var n = 0, cur = 0, inString = false, escaped = false
        for b in d {
            if inString {
                cur += 1
                if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false; n += cur }
            } else if b == 0x22 { inString = true; cur = 1 }
        }
        return n
    }

    /// S is counted by enumeration. For every twin kind, with names that exercise every escape
    /// JSONEncoder makes ('/', '"', '\\', the named controls, other controls) and none (non-ASCII, U+FEFF inside,
    /// U+2028, DEL), `exportStringBytes` equals the string bytes present in the encoded section. The by-reference
    /// kinds (alarms, views, kernels, hooks) are also checked in the snapshot form `export()` writes for them.
    func testA32ExportStringBytesEqualsTheStringBytesTheEncoderWritesForEveryKind() throws {
        let odd = ["plain", String(repeating: "/", count: 300), "q\"uo\\te", "tab\tnl\nback\u{8}ff\u{C}cr\rctl\u{1}\u{1F}",
                   "\u{E9}\u{6F22}\u{1F389}", "in\u{FEFF}side", "ls\u{2028}ps\u{2029}", "del\u{7F}"]
        var rows: [String] = []
        func check(_ name: String, _ t: TwinState, file: StaticString = #filePath, line: UInt = #line) throws {
            let s = t.exportStringBytes(), e = try encodedStringBytes(t.export())
            rows.append("\(name): S \(s) encoded \(e)")
            XCTAssertEqual(s, e, name, file: file, line: line)
        }
        let header = StreamHeader(signalBandHz: 1500, tauWindowSec: 0.6827, combRateHz: 3000, firstEchoSec: 1.0,
                                  recordWindowSec: 0.6827, stepSec: 0.00001, clockSyncFloorSec: 0)
        let all = TwinState()
        try check("empty", all)
        let s = TwinState(), r = TwinState(), n = TwinState(), c = TwinState(), l = TwinState(), w = TwinState()
        for (i, name) in odd.enumerated() {
            let k = UInt64(i + 1)
            for t in [s, all] { try t.apply(.streamOpen(id: TwinIdFormat.format(prefix: "s", k), name: name, stateHi: .max, stateLo: 1, incHi: 3, incLo: 5)) }
            for t in [r, all] {
                try t.apply(.recordOpen(id: TwinIdFormat.format(prefix: "t", k), name: name, header: header, stateHi: 1, stateLo: 2, incHi: 3, incLo: 5))
                try t.apply(.recordSlice(id: TwinIdFormat.format(prefix: "t", k), count: 7))
            }
            for t in [n, all] {
                try t.apply(.ringsOpen(id: TwinIdFormat.format(prefix: "n", k), gear: 3, rings: 2, cells: 4))
                try t.apply(.ringsWrite(id: TwinIdFormat.format(prefix: "n", k), values: [0.5, 1.5, 2.5]))
            }
            for t in [c, all] {
                try t.apply(.clockOpen(id: TwinIdFormat.format(prefix: "c", k)))
                try t.apply(.gearOpen(id: TwinIdFormat.format(prefix: "g", k), clockId: TwinIdFormat.format(prefix: "c", k), name: name, num: 3, den: 7))
                try t.apply(.clockAdvance(id: TwinIdFormat.format(prefix: "c", k), count: 5, value: 0.25))
            }
            for t in [l, all] { try t.apply(.layoutOpen(id: TwinIdFormat.format(prefix: "b", k), cost: [[1, 2, 3], [4, 5, 6]], minTier: [0, 2])) }
            for t in [w, all] { try t.apply(.bankOpen(id: TwinIdFormat.format(prefix: "w", k), name: name, spec: .referenceNyquistSafe)) }
        }
        try check("streams", s); try check("records", r); try check("rings", n); try check("clocks and gears", c)
        try check("layouts", l); try check("banks", w); try check("every in-process kind together", all)
        // Alarms and hooks (a layout's and a sealed one), through the daemon on a real alarm file.
        let h = try HandlerFixture(side: 4)
        XCTAssertTrue(h.handler.handle("ALARM LOAD \(try writeAlarm())").hasPrefix("OK"))
        budgetFrame(h, p: 2, t: 3, c: 2)
        XCTAssertTrue(h.handler.handle("BUDGET OPEN 2 3 2").hasPrefix("OK"))
        XCTAssertTrue(h.handler.handle("CLOCK OPEN").hasPrefix("OK"))
        XCTAssertTrue(h.handler.handle("HOOK OPEN a00000001 SEALED 10").hasPrefix("OK"))
        XCTAssertTrue(h.handler.handle("HOOK OPEN a00000001 b00000001 10").hasPrefix("OK"))
        XCTAssertTrue(h.handler.handle("HOOK STEP h00000001 3").hasPrefix("OK"))
        XCTAssertEqual(h.handler.twin.hooks.openCount, 2)
        try check("alarms and hooks", h.handler.twin)
        // Kernels, through the daemon on the repository's kernel fixture.
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures").path
        let kf = try HandlerFixture(side: 4, dataRoot: fixtures)
        let kr = kf.handler.handle("KERNEL LOAD \(fixtures)/w1_kernels.json TAU 0.001 0.002 SIGMA 0.0001")
        XCTAssertTrue(kr.hasPrefix("OK KERNEL LOAD"), kr)
        try check("kernels", kf.handler.twin)
        // The by-reference kinds in the snapshot form export() writes (views need a sealed fixture to open).
        var snap = all.export()
        for (i, name) in odd.enumerated() {
            snap.alarms["a\(i)"] = TwinState.AlarmRef(path: "/p/" + name + ".json", sha256: String(repeating: "f", count: 64))
            snap.views["v\(i)"] = TwinState.ViewRef(path: "/p/" + name + ".npz", sha256: String(repeating: "e", count: 64))
            snap.kernels["k\(i)"] = TwinState.KernelRef(path: "/p/" + name, sha256: "d", tauA: i % 2 == 0 ? 1.5 : nil, tauB: nil,
                                                        sigmaSource: nil, declaredWarmup: i % 3 == 0 ? nil : 128)
            snap.hooks["h\(i)"] = TwinState.HookRef(params: AttentionHook.Params(alarmId: "a\(i)", layoutId: i % 2 == 0 ? "b1" : nil, budget: 12.5,
                                                                                 delta: 3, policy: .greedy, clockId: i % 3 == 0 ? nil : "c1"), t: 1234)
        }
        let cs = try JSONStringBytes.count(snap), es = try encodedStringBytes(snap)
        rows.append("refs, every kind: S \(cs) encoded \(es)")
        XCTAssertEqual(cs, es)
        // A large section: equal, and what the walk costs against the encode itself (this build's timing, printed).
        let big = TwinState()
        for i in 1...16 { try big.apply(.ringsOpen(id: TwinIdFormat.format(prefix: "n", UInt64(i)), gear: 6, rings: 16, cells: 4096)) }
        let t0 = Date(); let sb = big.exportStringBytes(); let t1 = Date()
        let eb = try encodedStringBytes(big.export()); let t2 = Date()
        XCTAssertEqual(sb, eb, "16 ring sets of 16 x 4,096")
        rows.append(String(format: "16 ring sets of 16 x 4,096: S %d encoded %d; the walk %.0f ms, the encode and scan %.0f ms",
                           sb, eb, t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000))
        print("ALLOC1c A3.2 S by enumeration:\n" + rows.joined(separator: "\n"))
    }

    func testC3ExportTokenBoundCoversWhatTheEncoderWritesForEveryKind() throws {
        func scanned(_ t: TwinState) throws -> Int {
            let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
            return AdmissionCharge.jsonTokens(try e.encode(t.export()))
        }
        var rows: [String] = []
        func check(_ name: String, _ t: TwinState, file: StaticString = #filePath, line: UInt = #line) throws {
            let s = try scanned(t), b = t.exportTokenBound()
            rows.append("\(name): scanned \(s) bound \(b) ratio \(String(format: "%.4f", Double(b) / Double(s)))")
            XCTAssertGreaterThanOrEqual(b, s, name, file: file, line: line)
        }
        try check("empty", TwinState())
        let header = StreamHeader(signalBandHz: 1500, tauWindowSec: 0.6827, combRateHz: 3000, firstEchoSec: 1.0,
                                  recordWindowSec: 0.6827, stepSec: 0.00001, clockSyncFloorSec: 0)
        for k in [1, 7] {
            let s = TwinState(); for i in 1...k { try s.apply(.streamOpen(id: TwinIdFormat.format(prefix: "s", UInt64(i)), name: "stream\(i)", stateHi: .max, stateLo: .max, incHi: .max, incLo: .max)) }
            try check("streams \(k)", s)
            let r = TwinState()
            for i in 1...k {
                try r.apply(.recordOpen(id: TwinIdFormat.format(prefix: "t", UInt64(i)), name: "court", header: header, stateHi: .max, stateLo: .max, incHi: .max, incLo: .max))
                for c in [1, 100, 10_000] { try r.apply(.recordSlice(id: TwinIdFormat.format(prefix: "t", UInt64(i)), count: UInt32(c))) }
            }
            try check("records \(k)", r)
            let n = TwinState()
            for i in 1...k {
                try n.apply(.ringsOpen(id: TwinIdFormat.format(prefix: "n", UInt64(i)), gear: 6, rings: i == 1 ? 16 : 6, cells: i == 1 ? 4096 : 32))
                try n.apply(.ringsWrite(id: TwinIdFormat.format(prefix: "n", UInt64(i)), values: (0..<5000).map { Float($0) * 1.37e-7 }))
            }
            try check("rings \(k)", n)
            let c = TwinState()
            for i in 1...k {
                try c.apply(.clockOpen(id: TwinIdFormat.format(prefix: "c", UInt64(i))))
                for j in 1...3 { try c.apply(.gearOpen(id: TwinIdFormat.format(prefix: "g", UInt64(i * 10 + j)), clockId: TwinIdFormat.format(prefix: "c", UInt64(i)), name: "gear\(j)", num: 3, den: 7)) }
                try c.apply(.clockAdvance(id: TwinIdFormat.format(prefix: "c", UInt64(i)), count: 10_000, value: 0.123456789))
            }
            try check("clocks and gears \(k)", c)
            let l = TwinState()
            for i in 1...k {
                try l.apply(.layoutOpen(id: TwinIdFormat.format(prefix: "b", UInt64(i)), cost: (0..<20).map { r in (0..<600).map { Double(r * 600 + $0) * 1.234567890123e-3 } },
                                        minTier: (0..<50).map { $0 % 600 }))
            }
            try check("layouts \(k)", l)
            let w = TwinState()
            for i in 1...k { try w.apply(.bankOpen(id: TwinIdFormat.format(prefix: "w", UInt64(i)), name: "bank\(i)", spec: .referenceNyquistSafe)) }
            try check("banks \(k)", w)
        }
        // The by-reference kinds, through the snapshot shape itself (their files are not opened by export).
        var snap = TwinState().export()
        for i in 1...5 {
            snap.alarms["a\(i)"] = TwinState.AlarmRef(path: "/a/very/long/path/alarm\(i).json", sha256: String(repeating: "f", count: 64))
            snap.views["v\(i)"] = TwinState.ViewRef(path: "/p/view\(i).npz", sha256: String(repeating: "e", count: 64))
            snap.kernels["k\(i)"] = TwinState.KernelRef(path: "/p/k\(i).json", sha256: String(repeating: "d", count: 64),
                                                        tauA: 1.5, tauB: 2.5, sigmaSource: 0.25, declaredWarmup: 128)
            snap.hooks["h\(i)"] = TwinState.HookRef(params: AttentionHook.Params(alarmId: "a\(i)", layoutId: "b1", budget: 12.5,
                                                                                 delta: 3, policy: .greedy, clockId: "c1"), t: 1234)
        }
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        let s = AdmissionCharge.jsonTokens(try e.encode(snap))
        let b = TwinState.ExportTokens.section + 1 + 5 * (TwinState.ExportTokens.alarmRef + TwinState.ExportTokens.viewRef
                                                           + TwinState.ExportTokens.kernelRef + TwinState.ExportTokens.hook)
        rows.append("refs 5 each: scanned \(s) bound \(b)")
        XCTAssertGreaterThanOrEqual(b, s)
        print("ALLOC1c C3.1 token bound:\n" + rows.joined(separator: "\n"))
    }

    func testC3LoadAdmitsItsDecodeTheFilesItNamesItsBanksAndItsHookRows() throws {
        // The decode, on the section's tokens.
        let src = TwinState()
        for i in 1...4 { try src.apply(.ringsOpen(id: "n0000000\(i)", gear: 6, rings: 16, cells: 64)) }
        let path = try snapshot("r.dags", src)
        let f = try HandlerFixture(side: 4)
        budget(f, bytes: 1_000_000, footprint: 0)
        let reply = f.handler.handle("LOAD \(path)")
        XCTAssertTrue(reply.hasPrefix("ERROR out_of_budget: LOAD needs "), reply)
        XCTAssertTrue(reply.contains("(the twin section's decode, 58.3 B per token + 1.26 B per byte for "), reply)
        XCTAssertTrue(reply.hasSuffix("the budget is 1000000; nothing written footprint=0"), reply)
        XCTAssertEqual(f.handler.twin.totalOpen, 0)
        // A bank's atoms: the default spec's 4*T*K, admitted before they are built.
        let banks = TwinState()
        try banks.apply(.bankOpen(id: "w00000001", name: "mouth", spec: .referenceNyquistSafe))
        let bpath = try snapshot("w.dags", banks)
        let spec = WaveBank.Spec.referenceNyquistSafe
        let atoms = 4 * spec.samples * spec.atomCount
        let g = try HandlerFixture(side: 4)
        budget(g, bytes: atoms, footprint: 0)
        let breply = g.handler.handle("LOAD \(bpath)")
        XCTAssertTrue(breply.contains("(bank w00000001's atoms, 4*T*K for T=\(spec.samples) K=\(spec.atomCount), 1.1 x the bytes)"), breply)
        XCTAssertEqual(g.handler.twin.banks.openCount, 0)
        budget(g, bytes: 64 << 20, footprint: 0)
        XCTAssertTrue(g.handler.handle("LOAD \(bpath)").hasPrefix("OK LOAD"))
        XCTAssertFalse(g.handler.twin.banks.get("w00000001")!.bank.atomsDeferred, "the atoms were built")
        XCTAssertEqual(g.handler.twin.banks.get("w00000001")!.bank, banks.banks.get("w00000001")!.bank)
        // A file it names, at its live verb's charge (ALARM LOAD: 8.6*file + 300 KB), on the opened file's size.
        let alarmPath = try writeAlarm()
        let h = try HandlerFixture(side: 4)
        XCTAssertTrue(h.handler.handle("ALARM LOAD \(alarmPath)").hasPrefix("OK"))
        XCTAssertTrue(h.handler.handle("HOOK OPEN a00000001 SEALED 10").hasPrefix("OK"))
        XCTAssertTrue(h.handler.handle("HOOK STEP h00000001 3").hasPrefix("OK"))
        let apath = tmpDir + "a.dags"
        XCTAssertTrue(h.handler.handle("SAVE \(apath)").hasPrefix("OK"))
        let fb = try bytes(alarmPath).count
        let k = try HandlerFixture(side: 4)
        // Under 1.1 x the LOAD family's floor, even this small file's read is refused, floored.
        budget(k, bytes: 300_000, footprint: 0)
        let freply = k.handler.handle("LOAD \(apath)")
        XCTAssertTrue(freply.hasPrefix("ERROR out_of_budget: LOAD needs 450561 bytes (the file's "), freply)
        XCTAssertTrue(freply.contains(" B, read once into its staged sections, floored at the LOAD family's 409600 B, 1.1 x the bytes)"), freply)
        // The alarm's charge (above the floor) is the one that refuses between the two: the one JSON pair, 98.4 B per token + 2.52 B per byte before the parse (it was 8.6*file + 300 KB).
        let at = AdmissionCharge.jsonTokens(try bytes(alarmPath))
        let alarmCharge = Int((1.1 * (98.4 * Double(at) + 2.52 * Double(fb))).rounded(.up))
        budget(k, bytes: (450_561 + alarmCharge) / 2, footprint: 0)
        let areply = k.handler.handle("LOAD \(apath)")
        XCTAssertTrue(areply.contains("(alarm set a00000001: \"\(alarmPath)\" parsed at ALARM LOAD's charge, 98.4 B per token + 2.52 B per byte for \(at) tokens and \(fb) B, 1.1 x the bytes)"), areply)
        XCTAssertTrue(areply.contains("; alarm set a00000001 names that file; nothing loaded"), areply)
        XCTAssertEqual(k.handler.twin.totalOpen, 0)
        budget(k, bytes: 64 << 20, footprint: 0)
        XCTAssertTrue(k.handler.handle("LOAD \(apath)").hasPrefix("OK LOAD"))
        XCTAssertEqual(k.handler.twin.hooks.get("h00000001")?.hook.t, 3, "the hook's rows re-stepped")
    }

    private func writeAlarm() throws -> String {
        func wave(_ base: Float) -> [Float] { [base, base + 1, base + 2, base + 3] }
        func entry(_ cls: String, _ base: Float, ear: String? = nil) -> [String: Any] {
            var e: [String: Any] = ["class": cls, "a": wave(base), "b": wave(base + 10), "c": wave(base + 20)]
            if let ear = ear { e["liar_ear"] = ear }
            return e
        }
        var obj: [String: Any] = ["quiet_1": entry("quiet", 0), "quiet_2": entry("quiet", 100), "liar_1": entry("liar", 200, ear: "B"),
                                  "deep_1": entry("deep", 300), "drift_1": entry("drift", 400), "cal0_1": entry("cal0", 500)]
        // Enough records that ALARM LOAD's charge (8.6*file + 300 KB) is above the LOAD family's floor.
        for i in 3...200 { obj["quiet_\(i)"] = entry("quiet", Float(1000 + i)) }
        let path = tmpDir + "mini.json"
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: path))
        return path
    }

    func testC3TheBootRefusesToStartOverItsBudgetAndNamesTheRemedy() throws {
        // A log that replays 8 ring sets of 16 x 4,096 (1.41*32*r*c each): over a 4 MiB budget at the first one.
        let walPath = tmpDir + "boot.wal"
        do {
            let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 16)
            for i in 1...8 { _ = try wal.twin(.ringsOpen(id: TwinIdFormat.format(prefix: "n", UInt64(i)), gear: 6, rings: 16, cells: 4096)) }
        }
        let f = try HandlerFixture(side: 4)
        let b = DaemonMemoryBudget(budgetBytes: 4 << 20, source: "--mem-budget-gb", footprint: { 1_000_000 }, fixedStateBytes: 0)
        let boot = DagDBBootAdmission(budget: b, engine: f.handler.engine, twin: f.handler.twin)
        XCTAssertThrowsError(try DagDBStartup.recover(engine: f.handler.engine, nodeCount: 16, width: 4, height: 4, dagdbEnv: nil,
                                                       dataRoot: nil, twin: f.handler.twin, truthRankIndex: f.handler.truthRankIndex,
                                                       snapshotPath: nil, walPath: walPath, log: { _ in }, boot: boot)) {
            let w = Reply.errorWords($0)
            XCTAssertTrue(w.hasPrefix("ERROR out_of_budget: the boot needs at least "), w)
            XCTAssertTrue(w.contains(" bytes (this step; later steps may need more): "), w)
            XCTAssertTrue(w.contains("replayed TWIN_RINGS_OPEN n00000001: RINGS OPEN's charge"), w)
            XCTAssertTrue(w.contains("the memory budget is 4194304 B (0.004 GiB"), w)
            XCTAssertTrue(w.contains("start the daemon with --mem-budget-gb 0.00"), w)
            XCTAssertTrue(w.contains("DAGDB_SANDBOX_MEM_BUDGET_GB=0.00"), w)
            XCTAssertTrue(w.hasSuffix("; refusing to start"), w)
        }
        // With the size the line names (rounded up), that step is admitted; the whole log needs a larger budget.
        let g = try HandlerFixture(side: 4)
        let big = DaemonMemoryBudget(budgetBytes: 64 << 20, source: "--mem-budget-gb", footprint: { 1_000_000 }, fixedStateBytes: 0)
        XCTAssertNoThrow(try DagDBStartup.recover(engine: g.handler.engine, nodeCount: 16, width: 4, height: 4, dagdbEnv: nil,
                                                   dataRoot: nil, twin: g.handler.twin, truthRankIndex: g.handler.truthRankIndex,
                                                   snapshotPath: nil, walPath: walPath, log: { _ in },
                                                   boot: DagDBBootAdmission(budget: big, engine: g.handler.engine, twin: g.handler.twin)))
        XCTAssertEqual(g.handler.twin.rings.openCount, 8)
        // The state at the end is checked too: a footprint over the budget refuses the start.
        let h = try HandlerFixture(side: 4)
        let over = DaemonMemoryBudget(budgetBytes: 64 << 20, source: "default", footprint: { 65 << 20 }, fixedStateBytes: 0)
        let ob = DagDBBootAdmission(budget: over, engine: h.handler.engine, twin: h.handler.twin)
        XCTAssertTrue(ob.finalRefusal()?.hasPrefix("ERROR out_of_budget: the boot needs at least 68157440 bytes (this step, the state it rebuilt") ?? false)
    }

    // MARK: - LOAD's back-edge staging and its rebase SAVE, admitted first

    func testA2LoadAdmitsTheBackEdgeStagingBeforeItIsBuilt() throws {
        // A snapshot of 16 nodes holding 40,000 back edges (8 B each in the file).
        let grid = try HexGrid(width: 4, height: 4)
        let engine = try DagDBEngine(grid: grid, state: DagDBState(width: 4, height: 4), maxRank: 8)
        let nb = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: 96)
        for i in 0..<96 { nb[i] = -1 }
        for i in 0..<40_000 { try engine.addBackEdgeUnchecked(src: UInt32(i % 16), dst: UInt32((i + 1) % 16)) }
        let path = tmpDir + "be.dags"
        _ = try DagDBSnapshot.save(engine: engine, nodeCount: 16, gridW: 4, gridH: 4, tickCount: 0, path: path)
        let fb = try bytes(path).count
        let staging = Int((1.1 * (8.1 * 40_000 + 262_144)).rounded(.up))
        let f = try HandlerFixture(side: 4)
        // The file's 1.1 x fits; the staging on top of it does not.
        budget(f, bytes: Int(1.1 * Double(fb)) + 40_000 + 200_000, footprint: 0)
        let r = f.handler.handle("LOAD \(path)")
        XCTAssertEqual(r, "ERROR out_of_budget: LOAD needs \(staging) bytes (the back-edge section's staging, 8.1 B per edge + 256 KiB"
                       + " for 40000 edges, 1.1 x the bytes), the budget is \(Int(1.1 * Double(fb)) + 240_000); nothing written footprint=0")
        XCTAssertEqual(f.handler.engine.backEdgeCount, 0, "nothing loaded")
        budget(f, bytes: 64 << 20, footprint: 0)
        XCTAssertTrue(f.handler.handle("LOAD \(path)").hasPrefix("OK LOAD"))
        XCTAssertEqual(f.handler.engine.backEdgeCount, 40_000)
        XCTAssertLessThan(f.handler.engine.backEdgeSrcs.capacity, 40_000 * 103 / 100,
                          "restored at their count (A1's choice 4; malloc's size class rounds it up a little)")
    }

    func testA2LoadPreAdmitsItsRebaseSaveSoABudgetRefusalNeverLandsInTheHold() throws {
        let src = TwinState()
        for i in 1...4 { try src.apply(.ringsOpen(id: TwinIdFormat.format(prefix: "n", UInt64(i)), gear: 6, rings: 16, cells: 256)) }
        // Records, whose names the encoder writes twice (streamName and the generator's name).
        let header = StreamHeader(signalBandHz: 1500, tauWindowSec: 0.6827, combRateHz: 3000, firstEchoSec: 1.0,
                                  recordWindowSec: 0.6827, stepSec: 0.00001, clockSyncFloorSec: 0)
        for i in 1...8 {
            try src.apply(.recordOpen(id: TwinIdFormat.format(prefix: "t", UInt64(i)), name: String(repeating: "/", count: 3900),
                                      header: header, stateHi: 1, stateLo: 2, incHi: 3, incLo: 5))
        }
        let path = try snapshot("rings.dags", src)
        let wal = try DagDBWAL.Appender(path: tmpDir + "live.wal", nodeCount: 16)
        let f = try HandlerFixture(side: 4, wal: wal)
        f.handler.startupSnapshotPath = tmpDir + "base.dags"
        // The pre-check's S is the string bytes the encoder writes for the state the load leaves (the snapshot's own).
        let tokens = src.exportTokenBound(), strings = try encodedStringBytes(src.export())
        XCTAssertGreaterThan(strings, 8 * 2 * 7800, "each record's name counted twice")
        // The rebase SAVE's charge carries its body too.
        let body = AdmissionCharge.saveBody(compressed: false, nodes: 16, v8: false, backEdges: 0, libraryBytes: 0)
        let save = Int((1.1 * (79.0 * Double(tokens) + 2.95 * Double(strings) + body)).rounded(.up))
        // The load's decode fits (1.1 x (58.3 B per token + 1.26 B per byte)); its rebase SAVE (1.1 x 79.0 B per token) does not.
        let section = try bytes(path).count
        let b = Int(1.1 * (58.3 * Double(tokens) + 1.26 * Double(section))) + 300_000
        XCTAssertLessThan(b, save)
        budget(f, bytes: b, footprint: 0)
        let r = f.handler.handle("LOAD \(path)")
        XCTAssertEqual(r, "ERROR out_of_budget: LOAD needs \(save) bytes (its rebase SAVE to \"\(tmpDir!)base.dags\", admitted with the"
                       + " load before anything is loaded: the twin section's encode, 1.1*(79.0 B per token + 2.95 B per escaped string"
                       + " byte) for \(tokens) tokens and \(strings) string bytes of the state it leaves, and the body's write, the"
                       + " digest's read of at most 8 MiB, 16 B per back edge for 0 and 320 KiB), the budget is \(b);"
                       + " nothing written footprint=0")
        XCTAssertEqual(f.handler.twin.rings.openCount, 0, "nothing loaded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir + "base.dags"))
        XCTAssertTrue(f.handler.handle("SET 1 TRUTH 1").hasPrefix("OK"), "no HOOK1 hold: writes go on")
        budget(f, bytes: 64 << 20, footprint: 0)
        XCTAssertTrue(f.handler.handle("LOAD \(path)").hasPrefix("OK LOAD"))
        XCTAssertEqual(f.handler.twin.rings.openCount, 4)
    }

    // MARK: - Replay in bounded windows

    /// An import logged whole in one record replays on the record's own bytes, never through
    /// the assembly (the bounded replay's copy of every file, the 2.2 x an independent restart measured), with a 0-byte file in its
    /// manifest (EXPORT MORTON writes an empty ttables.bin; the appender writes no chunk for it). The same import
    /// split into parts goes through the assembly, so the refusing admission below can see that path.
    func testA3AnImportWholeInItsRecordReplaysWithoutTheAssemblyCopy() throws {
        let src = try HandlerFixture(side: 16)
        let n = 256
        XCTAssertTrue(src.handler.handle("SET 5 TRUTH 1").hasPrefix("OK"))
        let dir = tmpDir + "exp"
        _ = try DagDBSnapshot.exportMorton(engine: src.handler.engine, nodeCount: n, dir: dir)
        var files: [DagDBSnapshot.MortonFile] = []
        for name in DagDBSnapshot.mortonImportFileNames where FileManager.default.fileExists(atPath: dir + "/" + name) {
            files.append((name, try bytes(dir + "/" + name)))
        }
        XCTAssertTrue(files.contains { $0.data.isEmpty }, "the export holds a 0-byte file (the case under test)")
        let saved = DagDBWAL.importChunkBytes
        defer { DagDBWAL.importChunkBytes = saved }
        for chunk in [DagDBWAL.defaultImportChunkBytes, 4096] {
            DagDBWAL.importChunkBytes = chunk
            let walPath = tmpDir + "imp-\(chunk).wal"
            do {
                let wal = try DagDBWAL.Appender(path: walPath, nodeCount: n)
                XCTAssertEqual(try wal.importMorton(dir: dir, files: files) == 1, chunk == DagDBWAL.defaultImportChunkBytes)
                wal.barrier()
            }
            var assembly: [String] = []
            let f = try HandlerFixture(side: 16)
            let r = try DaemonFile.$admission.withValue({ bytes, what in
                guard what.contains("assembled from the log") else { return nil }
                assembly.append(what); return "ERROR out_of_budget: refused by the test (\(bytes) B for \(what))"
            }) { try? DagDBWAL.replay(engine: f.handler.engine, nodeCount: n, path: walPath) }
            if chunk == DagDBWAL.defaultImportChunkBytes {
                XCTAssertEqual(assembly, [], "the whole record went through the assembly copy")
                XCTAssertEqual(r?.refusals ?? ["no replay"], [])
                XCTAssertEqual(r?.recordsApplied, 1)
                XCTAssertEqual(f.handler.engine.readTruthStates()[5], 1, "the import applied")
            } else {
                XCTAssertEqual(assembly.count, 1, "a split import is assembled (the control of this test's admission)")
                XCTAssertNil(r, "the refusing admission stops the replay")
            }
        }
    }

    func testC4ReplayReadsTheLogInBoundedWindowsAndItsScanMatchesTheWholeLogRules() throws {
        let walPath = tmpDir + "big.wal"
        do {
            let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 16, policy: .grouped(n: 100_000, ms: 60_000))
            // About 2.6 MB of 13-byte records, crossing every window boundary at every phase.
            for i in 0..<200_000 { _ = try wal.setTruth(node: UInt32(i % 16), value: UInt8(i % 2)) }
            _ = try wal.checkpoint(epoch: 7)
            // A record larger than a window (1.6 MB): read whole, alone.
            _ = try wal.connectBackBulk((0..<200_000).map { (src: UInt32($0 % 16), dst: UInt32(($0 + 1) % 16)) })
            _ = try wal.tickNote(total: 42)
            _ = try wal.setTruth(node: 3, value: 1)
            // A torn import at the tail (an IMPORT_PART with no closing record), then a record cut short.
            _ = try wal.append(opcode: .importPart, payload: Data([0, 0, 0, 0]))
            wal.barrier()
        }
        let fh = FileHandle(forWritingAtPath: walPath)!
        fh.seekToEndOfFile(); fh.write(Data([0xFF, 0xFF, 0x00, 0x00, 0x01, 0x02])); fh.closeFile()
        let whole = try bytes(walPath)
        var asked: [Int] = []
        let f = try HandlerFixture(side: 4)
        let r = try DaemonFile.$admission.withValue({ n, _ in asked.append(n); return nil }) {
            try DagDBWAL.replay(engine: f.handler.engine, nodeCount: 16, path: walPath, twin: f.handler.twin, wholeLog: true,
                                hashAt: [0, 16, 1_000_003, whole.count - 6])
        }
        let validEnd = whole.count - 6
        XCTAssertEqual(r.truncatedAtOffset, validEnd)
        XCTAssertEqual(r.hashedLength, validEnd)
        XCTAssertEqual(r.hashState.map { $0.finalize().map { String(format: "%02x", $0) }.joined() },
                       DagDBHOOK1Era.prefixHash(whole, length: validEnd))
        for o in [0, 16, 1_000_003, validEnd] { XCTAssertEqual(r.prefixDigests[o], DagDBHOOK1Era.prefixHash(whole, length: o), "offset \(o)") }
        let (end, why) = DagDBWAL.wholeEnd(whole, version: r.fileVersion)
        XCTAssertEqual(r.found?.wholeEnd, end)
        XCTAssertEqual(r.found?.wholeWhy, why)
        XCTAssertEqual(r.found?.size, whole.count)
        XCTAssertEqual(r.checkpointEpoch, 7)
        XCTAssertEqual(r.tickNoteWindowMax, 42)
        XCTAssertEqual(f.handler.engine.backEdgeCount, 200_000)
        XCTAssertEqual(f.handler.engine.readTruthStates()[3], 1)
        XCTAssertEqual(r.recordsApplied, 200_000 + 1 + 1)
        // Every read admitted was a window: at most the window or the one record larger than it, never the log.
        XCTAssertLessThanOrEqual(asked.max() ?? 0, 5 + 4 + 8 * 200_000)
        XCTAssertTrue(asked.allSatisfy { $0 < whole.count })
        // The appender opens on the scan's facts: the torn tail is cut, and its running hash continues the replay's.
        let a = try DagDBWAL.Appender(path: walPath, nodeCount: 16, prefixHash: r.hashState.map { (r.hashedLength, $0) }, found: r.found)
        XCTAssertEqual(a.tornTailCut?.offset, end)
        XCTAssertEqual(try bytes(walPath).count, end)
        XCTAssertEqual(a.durableDigest().sha256, DagDBHOOK1Era.prefixHash(whole, length: end))
    }
}
