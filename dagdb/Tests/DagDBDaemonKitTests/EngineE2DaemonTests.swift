import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// The bulk verbs and their companions through the daemon's own handler.
/// Pipelined connections is driven over a real socket in `EngineE2SocketTests`.
///
/// Every test here compares a new verb against its slow path, run on a second
/// handler built identically: the bulk verbs against N single commands (final
/// graph, snapshot bytes, and the WAL replayed through the daemon's startup
/// path), the truth slice against NODES' truth column, UNTIL_STABLE against
/// repeated `TICK 1`. The file speaks only the DSL and library calls that exist
/// before these verbs, so it compiles on the older code without them (the red run).
final class EngineE2DaemonTests: XCTestCase {

    private var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "engine-e2-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    typealias Rng = EngineE1DaemonTests.Rng

    // MARK: - Helpers

    /// A handler with its own WAL over the graph of `EngineE1DaemonTests.buildGraph` (written to the
    /// engine directly, so the log holds only what the test sends).
    func fixture(side: Int, seed: UInt64, ternary: Bool, name: String) throws -> (HandlerFixture, String) {
        let walPath = tmp + name + ".wal"
        let f = try HandlerFixture(side: side, dataRoot: tmp,
                                   wal: try DagDBWAL.Appender(path: walPath, nodeCount: side * side))
        try EngineE1DaemonTests.buildGraph(f.handler.engine, seed: seed, ternary: ternary)
        return (f, walPath)
    }

    func snapshot(_ e: DagDBEngine, side: Int, _ name: String) throws -> Data {
        let p = tmp + name
        _ = try DagDBSnapshot.save(engine: e, nodeCount: e.nodeCount, gridW: side, gridH: side,
                                   tickCount: 0, path: p)
        return try Data(contentsOf: URL(fileURLWithPath: p))
    }

    /// The log replayed through the daemon's startup path into a fresh engine
    /// holding the same base graph; that engine's snapshot bytes.
    func replayed(walPath: String, side: Int, seed: UInt64, ternary: Bool, _ name: String) throws
        -> (Data, DagDBWAL.ReplayResult?) {
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side), maxRank: 8)
        try EngineE1DaemonTests.buildGraph(e, seed: seed, ternary: ternary)
        let r = try DagDBStartup.recover(
            engine: e, nodeCount: side * side, width: side, height: side, dagdbEnv: nil, dataRoot: tmp,
            twin: TwinState(), truthRankIndex: TruthRankIndex(), snapshotPath: nil, walPath: walPath,
            log: { _ in })
        XCTAssertNil(r.replayError)
        return (try snapshot(e, side: side, name), r.replay)
    }

    /// The records of a log: (opcode, payload length).
    func walRecords(_ path: String) throws -> [(UInt8, Int)] {
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        var out: [(UInt8, Int)] = []
        var off = DagDBWAL.headerSize
        while off + 5 <= d.count {
            let len = Int(d[off]) | Int(d[off + 1]) << 8 | Int(d[off + 2]) << 16 | Int(d[off + 3]) << 24
            out.append((d[off + 4], len))
            off += 5 + len
        }
        return out
    }

    /// Write an input frame into the fixture's shm: u32 count, u32 the verb's mark (a
    /// row size other than 8 is written as itself, unmarked), then the rows at offset 8.
    func putRows(_ f: HandlerFixture, rowSize: Int, verb: SHM1Verb? = nil, _ rows: [[UInt8]]) {
        let h = f.shm.bindMemory(to: UInt32.self, capacity: 2)
        h[0] = UInt32(rows.count); h[1] = rowSize == 8 ? shm1Word1(verb!) : UInt32(rowSize)
        let p = f.shm.advanced(by: 8).bindMemory(to: UInt8.self, capacity: max(1, rows.count * rowSize))
        for (i, r) in rows.enumerated() { for (j, b) in r.enumerated() { p[i * rowSize + j] = b } }
    }

    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    func backRow(_ s: Int, _ d: Int) -> [UInt8] { Self.le32(UInt32(s)) + Self.le32(UInt32(d)) }
    func truthRow(_ n: Int, _ v: UInt8, pad: UInt8 = 0) -> [UInt8] { Self.le32(UInt32(n)) + [v, pad, pad, pad] }

    /// The bulk refusal is the single refusal, its entry named: the category
    /// stays, `<VERB> entry <i>: ` is inserted after it, `; nothing written`
    /// closes it.
    static func bulkForm(_ verb: String, _ i: Int, _ single: String) -> String {
        guard let r = single.range(of: ": ") else { return single }
        return String(single[..<r.lowerBound]) + ": \(verb) entry \(i): "
            + String(single[r.upperBound...]) + "; nothing written"
    }

    // MARK: - CONNECT_BACK_BULK

    /// Valid back-edge entries for `e`: binary destinations with no
    /// combinational input (in the graph of `EngineE1DaemonTests.buildGraph`: the top rank), sources anywhere,
    /// duplicates included (CONNECT BACK appends a duplicate; so must the bulk).
    func backEntries(_ e: DagDBEngine, seed: UInt64, count: Int) -> [(Int, Int)] {
        let n = e.nodeCount
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        let dsts = (0..<n).filter { i in
            !TernaryReference.isTernary(e.modeByte(i)) && (0..<6).allSatisfy { nb[i * 6 + $0] < 0 }
        }
        var g = Rng(s: seed)
        var out: [(Int, Int)] = []
        while out.count < count {
            let d = dsts[g.below(dsts.count)], s = g.below(n)
            if s != d { out.append((s, d)) }
        }
        out.append(out[3])                          // a duplicate entry
        return out
    }

    func connectBackCell(side: Int, seed: UInt64, ternary: Bool) throws -> String {
        let (fa, walA) = try fixture(side: side, seed: seed, ternary: ternary, name: "cbA\(seed)")
        let (fb, walB) = try fixture(side: side, seed: seed, ternary: ternary, name: "cbB\(seed)")
        let entries = backEntries(fa.handler.engine, seed: seed &+ 1, count: 40)
        putRows(fa, rowSize: 8, verb: .connectBackBulk, entries.map { backRow($0.0, $0.1) })
        let bulk = fa.handler.handle("CONNECT_BACK_BULK")
        for (s, d) in entries {
            let r = fb.handler.handle("CONNECT BACK FROM \(s) TO \(d)")
            XCTAssertEqual(r, "OK CONNECT BACK from=\(s) to=\(d)")
        }
        fa.handler.walAppender?.barrier(); fb.handler.walAppender?.barrier()
        let a = try snapshot(fa.handler.engine, side: side, "cbA\(seed).dags")
        let b = try snapshot(fb.handler.engine, side: side, "cbB\(seed).dags")
        let (ra, repA) = try replayed(walPath: walA, side: side, seed: seed, ternary: ternary, "cbA\(seed)-r.dags")
        let (rb, _) = try replayed(walPath: walB, side: side, seed: seed, ternary: ternary, "cbB\(seed)-r.dags")
        let recsA = try walRecords(walA), recsB = try walRecords(walB)
        let line = "E2.1 side=\(side) ternary=\(ternary) entries=\(entries.count) bulk='\(bulk)' "
            + "bulk==singles=\(a == b) replay(bulk)==live=\(ra == a) replay(singles)==live=\(rb == b) "
            + "records bulk=\(recsA.count) singles=\(recsB.count) "
            + "back_edges=\(fa.handler.engine.backEdgeCount)/\(fb.handler.engine.backEdgeCount) "
            + "skipped=\(repA?.recordsSkipped ?? -1)"
        print(line)
        XCTAssertEqual(bulk, "OK CONNECT_BACK_BULK edges=\(entries.count) back_edges=\(fb.handler.engine.backEdgeCount)", line)
        XCTAssertEqual(a, b, line)
        XCTAssertEqual(ra, a, line)
        XCTAssertEqual(rb, b, line)
        XCTAssertEqual(recsA.count, 1, line)
        XCTAssertEqual(recsB.count, entries.count, line)
        XCTAssertEqual(fa.handler.engine.backEdgeSrcs, fb.handler.engine.backEdgeSrcs, line)
        XCTAssertEqual(fa.handler.engine.backEdgeDsts, fb.handler.engine.backEdgeDsts, line)
        return line
    }

    func testE2_1ConnectBackBulkEqualsSinglesOnThreeGraphs() throws {
        for (side, seed, ternary) in [(16, UInt64(0xE21), false), (16, 0xE22, true), (24, 0xE23, true)] {
            _ = try connectBackCell(side: side, seed: seed, ternary: ternary)
        }
    }

    /// Refusals mid-file, one cell per rule the single verb has: the bulk
    /// refuses with the single's own words for the first offending entry, and
    /// writes nothing — no back edge, no WAL byte.
    func testE2_1ConnectBackBulkRefusalMidFileWritesNothing() throws {
        let side = 16, seed: UInt64 = 0xE24, n = side * side
        var checked = 0
        for rule in ["src out of range", "dst out of range", "self-loop", "fan-in", "ternary dst"] {
            let (fa, walA) = try fixture(side: side, seed: seed, ternary: true, name: "cbr-\(checked)A")
            let (fb, _) = try fixture(side: side, seed: seed, ternary: true, name: "cbr-\(checked)B")
            let e = fa.handler.engine
            var entries = backEntries(e, seed: seed, count: 20)
            let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
            let bad: (Int, Int)
            switch rule {
            case "src out of range": bad = (n + 7, entries[0].1)
            case "dst out of range": bad = (1, n)
            case "self-loop": bad = (entries[1].1, entries[1].1)
            case "fan-in": bad = (2, (0..<n).first { nb[$0 * 6] >= 0 && !TernaryReference.isTernary(e.modeByte($0)) }!)
            default: bad = (2, (0..<n).first { TernaryReference.isTernary(e.modeByte($0)) }!)
            }
            let at = 11
            entries.insert(bad, at: at)
            entries.insert((n + 99, 0), at: 15)         // a second offender after it: the first is named
            let before = try snapshot(e, side: side, "cbr-before-\(checked).dags")
            let backBefore = e.backEdgeCount
            putRows(fa, rowSize: 8, verb: .connectBackBulk, entries.map { backRow($0.0, $0.1) })
            let bulk = fa.handler.handle("CONNECT_BACK_BULK")
            // The slow path: singles up to the offender; its reply is the single's refusal.
            var single = ""
            for (i, (s, d)) in entries.enumerated() {
                let r = fb.handler.handle("CONNECT BACK FROM \(s) TO \(d)")
                if i < at { XCTAssertTrue(r.hasPrefix("OK"), r) } else { single = r; break }
            }
            fa.handler.walAppender?.barrier()
            let after = try snapshot(e, side: side, "cbr-after-\(checked).dags")
            let walBytes = try Data(contentsOf: URL(fileURLWithPath: walA)).count
            print("E2.1 refusal \(rule): single='\(single)' bulk='\(bulk)' state_unchanged=\(after == before) "
                  + "back_edges \(backBefore)->\(e.backEdgeCount) wal_bytes=\(walBytes)")
            XCTAssertTrue(single.hasPrefix("ERROR"), single)
            XCTAssertEqual(bulk, Self.bulkForm("CONNECT_BACK_BULK", at, single), rule)
            XCTAssertEqual(after, before, "\(rule): a refused bulk wrote state")
            XCTAssertEqual(e.backEdgeCount, backBefore, rule)
            XCTAssertEqual(walBytes, DagDBWAL.headerSize, "\(rule): a refused bulk wrote a WAL record")
            checked += 1
        }
        XCTAssertEqual(checked, 5)
    }

    /// The input frame is refused by name before any entry is read.
    func testE2_1ConnectBackBulkFrameRefusals() throws {
        let f = try HandlerFixture(side: 4)
        putRows(f, rowSize: 4, [[0, 0, 0, 0]])
        XCTAssertEqual(f.handler.handle("CONNECT_BACK_BULK"),
                       "ERROR stale_frame: CONNECT_BACK_BULK reads a client frame; the shm header is (1, 4), not (1, 0x314D4808): "
                           + "write [u32 count][u32 0x314D4808] at bytes 0..7, then the payload at 8; nothing written")
        let h = f.shm.bindMemory(to: UInt32.self, capacity: 2)
        h[0] = 1_000_000; h[1] = shm1Word1(.connectBackBulk)
        XCTAssertTrue(f.handler.handle("CONNECT_BACK_BULK").hasPrefix("ERROR out_of_range: result needs"))
        h[0] = 0; h[1] = shm1Word1(.connectBackBulk)
        XCTAssertEqual(f.handler.handle("CONNECT_BACK_BULK"), "OK CONNECT_BACK_BULK edges=0 back_edges=0")
        let id = field(f.handler.handle("OPEN_READER"), "id") ?? "?"
        XCTAssertEqual(f.handler.handle("READER \(id) CONNECT_BACK_BULK"), "ERROR forbidden: command not allowed in reader session (read-only)")
        XCTAssertEqual(f.handler.handle("READER \(id) SET_TRUTH_BULK"), "ERROR forbidden: command not allowed in reader session (read-only)")
    }

    // MARK: - SET_TRUTH_BULK

    /// Entries every single SET TRUTH accepts: ternary nodes 0..2, binary
    /// nodes 0..255 (Loom codes); repeated nodes (the last write wins).
    func truthEntries(_ e: DagDBEngine, seed: UInt64, count: Int) -> [(Int, UInt8)] {
        var g = Rng(s: seed)
        var out: [(Int, UInt8)] = []
        for _ in 0..<count {
            let i = g.below(e.nodeCount)
            let v = TernaryReference.isTernary(e.modeByte(i)) ? UInt8(g.below(3)) : UInt8(g.below(256))
            out.append((i, v))
        }
        out.append((out[5].0, out[5].1 == 0 ? 1 : 0))   // a repeated node
        return out
    }

    func setTruthCell(side: Int, seed: UInt64, ternary: Bool) throws {
        let (fa, walA) = try fixture(side: side, seed: seed, ternary: ternary, name: "stA\(seed)")
        let (fb, walB) = try fixture(side: side, seed: seed, ternary: ternary, name: "stB\(seed)")
        let entries = truthEntries(fa.handler.engine, seed: seed &+ 2, count: 60)
        putRows(fa, rowSize: 8, verb: .setTruthBulk, entries.map { truthRow($0.0, $0.1) })
        let bulk = fa.handler.handle("SET_TRUTH_BULK")
        for (i, v) in entries { XCTAssertEqual(fb.handler.handle("SET \(i) TRUTH \(v)"), "OK SET node=\(i) truth=\(v)") }
        fa.handler.walAppender?.barrier(); fb.handler.walAppender?.barrier()
        let a = try snapshot(fa.handler.engine, side: side, "stA\(seed).dags")
        let b = try snapshot(fb.handler.engine, side: side, "stB\(seed).dags")
        let (ra, _) = try replayed(walPath: walA, side: side, seed: seed, ternary: ternary, "stA\(seed)-r.dags")
        let (rb, _) = try replayed(walPath: walB, side: side, seed: seed, ternary: ternary, "stB\(seed)-r.dags")
        let recsA = try walRecords(walA)
        // SELECT after the bulk sees the new truth (the index is marked dirty, as SET TRUTH does).
        let selA = fa.handler.handle("SELECT TRUTH 1 RANK 0-7"), selB = fb.handler.handle("SELECT TRUTH 1 RANK 0-7")
        let line = "E2.2 side=\(side) ternary=\(ternary) entries=\(entries.count) bulk='\(bulk)' bulk==singles=\(a == b) "
            + "replay(bulk)==live=\(ra == a) replay(singles)==live=\(rb == b) records bulk=\(recsA.count)"
        print(line)
        XCTAssertEqual(bulk, "OK SET_TRUTH_BULK nodes=\(entries.count)", line)
        XCTAssertEqual(a, b, line); XCTAssertEqual(ra, a, line); XCTAssertEqual(rb, b, line)
        XCTAssertEqual(recsA.count, 1, line)
        XCTAssertEqual(selA, selB)
    }

    func testE2_2SetTruthBulkEqualsSinglesOnThreeGraphs() throws {
        for (side, seed, ternary) in [(16, UInt64(0xE25), false), (16, 0xE26, true), (24, 0xE27, true)] {
            try setTruthCell(side: side, seed: seed, ternary: ternary)
        }
    }

    func testE2_2SetTruthBulkRefusalMidFileWritesNothing() throws {
        let side = 16, seed: UInt64 = 0xE28, n = side * side
        var checked = 0
        for rule in ["node out of range", "ternary 3+"] {
            let (fa, walA) = try fixture(side: side, seed: seed, ternary: true, name: "str-\(checked)A")
            let (fb, _) = try fixture(side: side, seed: seed, ternary: true, name: "str-\(checked)B")
            let e = fa.handler.engine
            var entries = truthEntries(e, seed: seed, count: 30)
            let tern = (0..<n).first { TernaryReference.isTernary(e.modeByte($0)) }!
            let at = 17
            entries.insert(rule == "node out of range" ? (n + 1, 1) : (tern, 7), at: at)
            entries.insert((tern, 200), at: 25)
            let before = try snapshot(e, side: side, "str-before-\(checked).dags")
            putRows(fa, rowSize: 8, verb: .setTruthBulk, entries.map { truthRow($0.0, $0.1) })
            let bulk = fa.handler.handle("SET_TRUTH_BULK")
            var single = ""
            for (i, (node, v)) in entries.enumerated() {
                let r = fb.handler.handle("SET \(node) TRUTH \(v)")
                if i < at { XCTAssertTrue(r.hasPrefix("OK"), r) } else { single = r; break }
            }
            fa.handler.walAppender?.barrier()
            let after = try snapshot(e, side: side, "str-after-\(checked).dags")
            let walBytes = try Data(contentsOf: URL(fileURLWithPath: walA)).count
            print("E2.2 refusal \(rule): single='\(single)' bulk='\(bulk)' state_unchanged=\(after == before) wal_bytes=\(walBytes)")
            XCTAssertTrue(single.hasPrefix("ERROR"), single)
            XCTAssertEqual(bulk, Self.bulkForm("SET_TRUTH_BULK", at, single), rule)
            XCTAssertEqual(after, before, rule)
            XCTAssertEqual(walBytes, DagDBWAL.headerSize, rule)
            checked += 1
        }
        // The frame: a row's pad bytes must be zero (a u32 value written over u8 + pad is refused, not truncated).
        let f = try HandlerFixture(side: 4)
        putRows(f, rowSize: 8, verb: .setTruthBulk, [truthRow(1, 1), truthRow(2, 44, pad: 1)])
        XCTAssertEqual(f.handler.handle("SET_TRUTH_BULK"),
                       "ERROR bad_value: SET_TRUTH_BULK entry 1: pad bytes 5..7 must be 0 (row: u32 node, u8 value, 3 zero bytes); nothing written")
        XCTAssertEqual(f.handler.handle("GET 1 TRUTH"), "OK GET node=1 truth=0")
        putRows(f, rowSize: 5, [[1, 0, 0, 0, 1]])
        XCTAssertEqual(f.handler.handle("SET_TRUTH_BULK"),
                       "ERROR stale_frame: SET_TRUTH_BULK reads a client frame; the shm header is (1, 5), not (1, 0x314D4809): "
                           + "write [u32 count][u32 0x314D4809] at bytes 0..7, then the payload at 8; nothing written")
        XCTAssertEqual(checked, 2)
    }

    /// The NOSKIP rule (no jump from −1 straight to +1), measured, not checked: a single SET TRUTH
    /// moves a NOSKIP ternary node from −1 (byte 0) straight to +1 (byte 1)
    /// today. The bulk equals the single there too (it does not invent a
    /// refusal the single does not have).
    func testE2_2NoskipJumpMeasuredSingleAndBulkAgree() throws {
        let fa = try HandlerFixture(side: 4), fb = try HandlerFixture(side: 4)
        for f in [fa, fb] {
            XCTAssertTrue(f.handler.handle("TTABLE PRESET 0 TSUM 6").hasPrefix("OK"))
            XCTAssertEqual(f.handler.handle("SET 3 MODE TTABLE NOSKIP"), "OK SET node=3 mode=TTABLE noskip=1")
            XCTAssertEqual(f.handler.handle("SET 3 TRIT -1"), "OK SET node=3 trit=-1")
        }
        let single = fb.handler.handle("SET 3 TRUTH 1")
        putRows(fa, rowSize: 8, verb: .setTruthBulk, [truthRow(3, 1)])
        let bulk = fa.handler.handle("SET_TRUTH_BULK")
        print("E2.2 NOSKIP premise: node 3 TTABLE NOSKIP at -1; single 'SET 3 TRUTH 1' -> '\(single)'; bulk -> '\(bulk)'; "
              + "trit after: single \(fb.handler.handle("GET 3 TRIT")) bulk \(fa.handler.handle("GET 3 TRIT"))")
        XCTAssertEqual(fa.handler.handle("GET 3 TRIT"), fb.handler.handle("GET 3 TRIT"))
    }

    // MARK: - Truth-slice readback

    /// Decode the slice in shm: header (count, bits per node), packed LSB-first.
    func decodeSlice(_ f: HandlerFixture) -> (bits: Int, values: [UInt8]) {
        let h = f.shm.bindMemory(to: UInt32.self, capacity: 2)
        let count = Int(h[0]), bits = Int(h[1])
        guard bits == 1 || bits == 2, count <= f.shmBytes * 4 else { return (bits, []) }   // not a slice
        let p = f.shm.advanced(by: 8).bindMemory(to: UInt8.self, capacity: max(1, (count * bits + 7) / 8))
        let per = 8 / max(bits, 1), mask = UInt8((1 << bits) - 1)
        return (bits, (0..<count).map { (p[$0 / per] >> UInt8(($0 % per) * bits)) & mask })
    }

    /// NODES AT RANK r's rows, (id, truth), in row order.
    func nodesAtRank(_ f: HandlerFixture, _ r: Int) -> [(Int, UInt8)] {
        let reply = f.handler.handle("NODES AT RANK \(r)")
        XCTAssertTrue(reply.hasPrefix("OK NODES"), reply)
        let count = Int(f.shm.bindMemory(to: UInt32.self, capacity: 2)[0])
        return (0..<count).map { i in
            let row = f.shm.advanced(by: 8 + i * 24)
            return (Int(row.load(as: UInt64.self)), row.load(fromByteOffset: 16, as: UInt8.self))
        }
    }

    func sliceCell(side: Int, seed: UInt64, ternary: Bool) throws {
        let n = side * side
        let (f, _) = try fixture(side: side, seed: seed, ternary: ternary, name: "sl\(seed)")
        XCTAssertTrue(f.handler.handle("TICK 2").hasPrefix("OK TICK"))
        let ranks = f.handler.engine.readRanks()
        var nodesTruth = [UInt8](repeating: 0, count: n), seen = 0, sizeOK = true
        let wantBits = ternary ? 2 : 1
        for r in Set(ranks.map { Int($0) }).sorted() {
            let rows = nodesAtRank(f, r)
            for (id, t) in rows { nodesTruth[id] = t; seen += 1 }
            let reply = f.handler.handle("TRUTH_SLICE RANK \(r)-\(r)")
            let s = decodeSlice(f)
            XCTAssertEqual(s.bits, wantBits, reply)
            XCTAssertEqual(s.values, rows.map { $0.1 }, "rank \(r): \(reply)")
            let bytes = (rows.count * wantBits + 7) / 8
            sizeOK = sizeOK && reply.contains(" shm_bytes=\(bytes) ") && bytes * (ternary ? 4 : 8) <= rows.count + (ternary ? 3 : 7)
        }
        XCTAssertEqual(seen, n, "NODES AT RANK covers every node")
        let whole = f.handler.handle("TRUTH_SLICE NODES 0-\(n - 1)")
        let s = decodeSlice(f)
        let gets = (0..<n).map { i -> UInt8 in
            let g = f.handler.handle("GET \(i) TRUTH")
            return UInt8(g.split(separator: "=").last!)!
        }
        let line = "E2.4 side=\(side) ternary=\(ternary) whole='\(whole)' equal_to_NODES=\(s.values == nodesTruth) "
            + "equal_to_GET=\(s.values == gets) bytes_per_node_bound=\(sizeOK)"
        print(line)
        XCTAssertEqual(s.values, nodesTruth, line)
        XCTAssertEqual(s.values, gets, line)
        XCTAssertTrue(sizeOK, line)
        // A sub-range of ids: the same values, sliced.
        _ = f.handler.handle("TRUTH_SLICE NODES 37-\(n / 2)")
        XCTAssertEqual(decodeSlice(f).values, Array(nodesTruth[37...(n / 2)]))
    }

    func testE2_4TruthSliceEqualsNodesTruthColumn() throws {
        try sliceCell(side: 16, seed: 0xE41, ternary: false)
        try sliceCell(side: 24, seed: 0xE42, ternary: true)
        try sliceCell(side: 32, seed: 0xE43, ternary: true)
    }

    func testE2_4TruthSliceRefusesWhatItCannotCarry() throws {
        let f = try HandlerFixture(side: 4)
        XCTAssertTrue(f.handler.handle("SET 5 TRUTH 200").hasPrefix("OK"))     // a Loom code on a binary node
        XCTAssertEqual(f.handler.handle("TRUTH_SLICE NODES 0-15"),
                       "ERROR bad_value: TRUTH_SLICE node 5 truth 200 does not fit 2 bits (0, 1, 2); read it with NODES or GET")
        XCTAssertEqual(f.handler.handle("TRUTH_SLICE NODES 0-16"), "ERROR out_of_range: node 16 not in 0..<16")
        XCTAssertEqual(f.handler.handle("TRUTH_SLICE NODES 9-3"), "ERROR out_of_range: range 9-3 is empty (lo > hi)")
        XCTAssertTrue(f.handler.handle("TRUTH_SLICE NODES 0-4").hasPrefix("OK TRUTH_SLICE nodes=5 format=bits"))
        XCTAssertTrue(f.handler.handle("SET 2 TRUTH 2").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("TRUTH_SLICE NODES 0-4").hasPrefix("OK TRUTH_SLICE nodes=5 format=trits"))
        XCTAssertEqual(f.handler.handle("TRUTH_SLICE RANK 5-9"), "OK TRUTH_SLICE nodes=0 format=bits bits_per_node=1 shm_bytes=0 first=- last=-")
    }

    // MARK: - TICK UNTIL_STABLE [MAX k]

    /// A register chain (the voxel cavity flood, small): registers R_i (rank
    /// 1) at ids 0..<m, combinational C_i = OR(R_{i-1}, R_i) at 100+i, a back
    /// edge C_i → R_i. Seeded at R_0, it floods one register per tick.
    func floodChain(_ f: HandlerFixture, m: Int, seed: Bool = true) {
        let h = f.handler
        for i in 0..<m {
            XCTAssertTrue(h.handle("SET \(i) RANK 1").hasPrefix("OK"))
            XCTAssertTrue(h.handle("SET \(100 + i) LUT OR").hasPrefix("OK"))
            if i > 0 { XCTAssertTrue(h.handle("CONNECT FROM \(i - 1) TO \(100 + i)").hasPrefix("OK")) }
            XCTAssertTrue(h.handle("CONNECT FROM \(i) TO \(100 + i)").hasPrefix("OK"))
            XCTAssertTrue(h.handle("CONNECT BACK FROM \(100 + i) TO \(i)").hasPrefix("OK"))
        }
        if seed { XCTAssertTrue(h.handle("SET 0 TRUTH 1").hasPrefix("OK")) }
    }

    /// k independent oscillators: register R (rank 1, id 200+j), C = NOR(R)
    /// (id 220+j), back edge C → R. Every tick every R flips.
    func oscillators(_ f: HandlerFixture, k: Int) {
        let h = f.handler
        for j in 0..<k {
            XCTAssertTrue(h.handle("SET \(200 + j) RANK 1").hasPrefix("OK"))
            XCTAssertTrue(h.handle("SET \(220 + j) LUT NOR").hasPrefix("OK"))
            XCTAssertTrue(h.handle("CONNECT FROM \(200 + j) TO \(220 + j)").hasPrefix("OK"))
            XCTAssertTrue(h.handle("CONNECT BACK FROM \(220 + j) TO \(200 + j)").hasPrefix("OK"))
        }
    }

    /// The slow path: TICK 1 until a tick changes no truth byte, at most
    /// `max` ticks. Returns (changing ticks, ticks run, stable).
    func tickUntilFixedPoint(_ f: HandlerFixture, max: Int) -> (Int, Int, Bool) {
        var changing = 0
        for run in 1...max {
            let before = f.handler.engine.readTruthStates()
            XCTAssertTrue(f.handler.handle("TICK 1").hasPrefix("OK TICK"))
            if f.handler.engine.readTruthStates() == before { return (changing, run, true) }
            changing += 1
        }
        return (changing, max, false)
    }

    func field(_ reply: String, _ key: String) -> String? {
        reply.split(separator: " ").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    func testE2_5UntilStableEqualsRepeatedTickOnFloodOscillatorAndStable() throws {
        let side = 16
        // 1 · a converging flood (40 registers).
        let fa = try HandlerFixture(side: side), fb = try HandlerFixture(side: side)
        floodChain(fa, m: 40); floodChain(fb, m: 40)
        let r1 = fa.handler.handle("TICK UNTIL_STABLE")
        let s1 = tickUntilFixedPoint(fb, max: 10_000)
        print("E2.5 flood: until_stable='\(r1)' reference: changing=\(s1.0) run=\(s1.1) stable=\(s1.2)")
        XCTAssertTrue(r1.hasPrefix("OK TICK UNTIL_STABLE stable "), r1)
        XCTAssertEqual(field(r1, "ticks"), "\(s1.0)"); XCTAssertEqual(field(r1, "run"), "\(s1.1)")
        XCTAssertEqual(field(r1, "changed"), "0"); XCTAssertEqual(field(r1, "latched"), "0")
        XCTAssertEqual(s1.0, 39)
        XCTAssertEqual(fa.handler.engine.readTruthStates(), fb.handler.engine.readTruthStates())
        XCTAssertEqual(fa.handler.tickCount, fb.handler.tickCount)
        XCTAssertEqual(try snapshot(fa.handler.engine, side: side, "fl-a.dags"),
                       try snapshot(fb.handler.engine, side: side, "fl-b.dags"))

        // 2 · the same graph again: already stable, 0 ticks.
        let r2 = fa.handler.handle("TICK UNTIL_STABLE MAX 5")
        let s2 = tickUntilFixedPoint(fb, max: 5)
        print("E2.5 already stable: until_stable='\(r2)' reference: changing=\(s2.0) run=\(s2.1)")
        XCTAssertTrue(r2.hasPrefix("OK TICK UNTIL_STABLE stable ticks=0 run=1 "), r2)
        XCTAssertEqual(s2.0, 0)
        XCTAssertEqual(fa.handler.tickCount, fb.handler.tickCount)

        // 3 · an oscillator: it stops at MAX and says "not stable".
        let oa = try HandlerFixture(side: side), ob = try HandlerFixture(side: side)
        oscillators(oa, k: 5); oscillators(ob, k: 5)
        let r3 = oa.handler.handle("TICK UNTIL_STABLE MAX 7")
        let s3 = tickUntilFixedPoint(ob, max: 7)
        print("E2.5 oscillator: until_stable='\(r3)' reference: changing=\(s3.0) run=\(s3.1) stable=\(s3.2)")
        XCTAssertTrue(r3.hasPrefix("OK TICK UNTIL_STABLE not stable after MAX 7 "), r3)
        XCTAssertFalse(s3.2)
        XCTAssertEqual(field(r3, "ticks"), "7"); XCTAssertEqual(field(r3, "run"), "7")
        XCTAssertEqual(field(r3, "latched"), "5", "every register flips: the latch's own count")
        XCTAssertEqual(field(r3, "changed"), "10", "5 registers and 5 NOR nodes")
        XCTAssertEqual(oa.handler.engine.readTruthStates(), ob.handler.engine.readTruthStates())
        XCTAssertEqual(oa.handler.tickCount, ob.handler.tickCount)

        // 4 · a flood mixed with a latch that changes nothing combinationally:
        //     the register chain on a graph seeded mid-chain.
        let ma = try HandlerFixture(side: side), mb = try HandlerFixture(side: side)
        floodChain(ma, m: 30, seed: false); floodChain(mb, m: 30, seed: false)
        XCTAssertTrue(ma.handler.handle("SET 12 TRUTH 1").hasPrefix("OK")); XCTAssertTrue(mb.handler.handle("SET 12 TRUTH 1").hasPrefix("OK"))
        let r4 = ma.handler.handle("TICK UNTIL_STABLE MAX 100")
        let s4 = tickUntilFixedPoint(mb, max: 100)
        print("E2.5 mid-seeded flood: until_stable='\(r4)' reference: changing=\(s4.0) run=\(s4.1)")
        XCTAssertEqual(field(r4, "ticks"), "\(s4.0)"); XCTAssertEqual(field(r4, "run"), "\(s4.1)")
        XCTAssertEqual(ma.handler.engine.readTruthStates(), mb.handler.engine.readTruthStates())
    }

    func testE2_5UntilStableRefusals() throws {
        let f = try HandlerFixture(side: 4)
        XCTAssertEqual(f.handler.handle("TICK UNTIL_STABLE MAX 0"), "ERROR out_of_range: MAX 0 not in 1...10000")
        XCTAssertEqual(f.handler.handle("TICK UNTIL_STABLE MAX 10001"), "ERROR out_of_range: MAX 10001 not in 1...10000")
        XCTAssertTrue(f.handler.handle("TICK UNTIL_STABLE MAX x").hasPrefix("ERROR unknown_command"))
        XCTAssertEqual(f.handler.tickCount, 0, "a refusal ticks nothing")
        let id = field(f.handler.handle("OPEN_READER"), "id") ?? "?"
        XCTAssertEqual(f.handler.handle("READER \(id) TICK UNTIL_STABLE"), "ERROR forbidden: command not allowed in reader session (read-only)")
    }
}
