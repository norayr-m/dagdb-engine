import XCTest
import CryptoKit
@testable import DagDB
@testable import DagDBDaemonKit

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Daemon (interface).
///
/// Driven over a REAL AF_UNIX socket (the daemon's own `SocketServer`,
/// in-process, on a temp path), with the WAL on. Every ternary verb with
/// its exact reply; the session's WAL replayed into a
/// fresh engine through the daemon's own startup path gives an equal state
/// (hash of every lane plus the library); SELECT after TICK sees the
/// post-tick truth; every new mutating verb is refused in a reader session.
final class TernaryR5DaemonTests: XCTestCase {

    private var server: SocketServer!
    private var fixture: HandlerFixture!
    private var socketPath: String!
    private var tmpDir: String!
    private var walPath: String!
    private let side = 8

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "tern-r5-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        walPath = tmpDir + "r5.wal"
        socketPath = NSTemporaryDirectory() + "tr5-\(UInt32.random(in: 0..<0xFFFF_FFFF)).sock"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: side * side)
        fixture = try HandlerFixture(side: side, wal: wal, maxRank: 8)
        let handler = fixture.handler
        server = SocketServer(path: socketPath)
        server.onCommand = { handler.handle($0) }
        let started = expectation(description: "socket listening")
        let s = server!
        DispatchQueue.global().async { started.fulfill(); try? s.start() }
        wait(for: [started], timeout: 5)
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: socketPath) { usleep(10_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    override func tearDownWithError() throws {
        server?.stop(); server = nil; fixture = nil
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    /// One command, one connection — the daemon's contract.
    @discardableResult
    private func send(_ line: String) -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        var sunPath = addr.sun_path
        withUnsafeMutableBytes(of: &sunPath) { buf in
            let bytes = socketPath.utf8CString
            for i in 0..<min(bytes.count, buf.count) { buf[i] = UInt8(bitPattern: bytes[i]) }
        }
        addr.sun_path = sunPath
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(rc, 0)
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        var out = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            out.append(contentsOf: chunk[0..<n])
        }
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func expect(_ line: String, _ reply: String, file: StaticString = #filePath, line ln: UInt = #line) {
        XCTAssertEqual(send(line), reply, line, file: file, line: ln)
    }

    private func expectPrefix(_ line: String, _ prefix: String, contains: String? = nil,
                              file: StaticString = #filePath, line ln: UInt = #line) {
        let r = send(line)
        XCTAssertTrue(r.hasPrefix(prefix), "\(line) -> \(r)", file: file, line: ln)
        if let c = contains { XCTAssertTrue(r.contains(c), "\(line) -> \(r) (wanted '\(c)')", file: file, line: ln) }
    }

    /// SHA-256 over every lane, the back-edge list and the library.
    static func stateHash(_ e: DagDBEngine) -> String {
        let n = e.nodeCount
        var h = SHA256()
        func lane(_ b: MTLBuffer, _ bytes: Int) { h.update(data: Data(bytes: b.contents(), count: bytes)) }
        lane(e.rankBuf, n * 8); lane(e.truthStateBuf, n); lane(e.nodeTypeBuf, n)
        lane(e.lut6LowBuf, n * 4); lane(e.lut6HighBuf, n * 4); lane(e.neighborsBuf, n * 24)
        lane(e.isRegisterBuf, n); lane(e.edgeWeightsBuf, n * 24); lane(e.activationBuf, n * 2)
        lane(e.nodeValueBuf, n * 4); lane(e.nodeModeBuf, n); lane(e.ttableIdBuf, n * 2)
        lane(e.thrLoBuf, n * 4); lane(e.thrHiBuf, n * 4)
        h.update(data: Data(e.libraryBytes()))
        for i in 0..<e.backEdgeCount {
            var s = e.backEdgeSrcs[i], d = e.backEdgeDsts[i]
            h.update(data: Data(bytes: &s, count: 4)); h.update(data: Data(bytes: &d, count: 4))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func table(_ f: (Int) -> Character) -> String { String((0..<729).map(f)) }

    // MARK: - Every verb over the socket, then WAL replay

    func testR5EveryVerbOverTheSocketThenWALReplayEqualsTheLiveState() throws {
        let n = side * side
        let e = fixture.handler.engine
        // Ranks so CONNECT has somewhere to go: rank = i % 4.
        let rk = fixture.shm.advanced(by: 8).bindMemory(to: UInt64.self, capacity: n)
        for i in 0..<n { rk[i] = UInt64(i % 4) }
        shm1Header(fixture.shm, count: n, verb: .setRanksBulk)
        expectPrefix("SET_RANKS_BULK", "OK SET_RANKS_BULK nodes=\(n)")

        // ── the library ──
        expect("TTABLE PRESET 0 TMIN 2", "OK TTABLE PRESET tid=0 name=TMIN k=2 tables=1")
        let t1 = table { i in ["-", "0", "+"][(i * 7) % 3] }
        expect("TTABLE DEFINE 1 \(t1)", "OK TTABLE DEFINE tid=1 tables=2")
        expect("TTABLE GET 1", "OK TTABLE GET tid=1 table=\(t1)")
        let tminTable = String(try TernaryReference.presetTable(.tmin, k: 2).map { TernaryReference.char(ofTableByte: $0) })
        expect("TTABLE GET 0", "OK TTABLE GET tid=0 table=\(tminTable)")
        expect("TTABLE PRESET 2 TCONST+1 6", "OK TTABLE PRESET tid=2 name=TCONST+1 k=6 tables=3")
        expect("TTABLE PRESET 3 TNEG 1", "OK TTABLE PRESET tid=3 name=TNEG k=1 tables=4")
        // Refusals, by name, nothing written.
        expectPrefix("TTABLE DEFINE 9 \(t1)", "ERROR bad_value: ternary: table id 9 leaves a gap")
        expectPrefix("TTABLE DEFINE 4 \(String(t1.dropLast()))", "ERROR bad_value: ternary: a table is 729 characters")
        expectPrefix("TTABLE DEFINE 4 \(String(t1.dropLast()) + "x")", "ERROR bad_value: ternary: table character 728 is \"x\"")
        expectPrefix("TTABLE PRESET 4 TNEG 2", "ERROR bad_value: ternary: preset TNEG is defined for k in 1...1")
        expectPrefix("TTABLE PRESET 4 TFOO 2", "ERROR bad_value: ternary: preset \"TFOO\"")
        expectPrefix("TTABLE GET 4", "ERROR out_of_range: tid 4 not in 0..<4")
        XCTAssertEqual(e.ttableCount, 4)

        // ── single-node verbs ──
        expect("SET 10 TTABLE 1", "OK SET node=10 ttable=1")
        expect("SET 10 MODE TTABLE NOSKIP", "OK SET node=10 mode=TTABLE noskip=1")
        expect("SET 11 THRESH -0.5 1.5", "OK SET node=11 thresh=-0.5,1.5")
        expect("SET 11 MODE TTHRESH", "OK SET node=11 mode=TTHRESH noskip=0")
        expect("SET 12 MODE TTHRESH NOSKIP", "OK SET node=12 mode=TTHRESH noskip=1")
        expect("SET 12 TRIT -1", "OK SET node=12 trit=-1")
        expect("GET 12 TRIT", "OK GET node=12 trit=-1")
        expect("GET 12 TRUTH", "OK GET node=12 truth=0")
        expect("SET 12 TRIT 0", "OK SET node=12 trit=0")
        expect("GET 12 TRUTH", "OK GET node=12 truth=2")
        expect("SET 12 TRIT 1", "OK SET node=12 trit=1")
        expect("GET 12 TRIT", "OK GET node=12 trit=1")
        expect("SET 13 TRUTH 200", "OK SET node=13 truth=200")       // binary keeps Loom codes
        expect("GET 13 TRIT", "OK GET node=13 trit=0")                // … which read as 0
        expect("SET 14 MODE BINARY", "OK SET node=14 mode=BINARY noskip=0")
        // Refusals.
        expectPrefix("SET 30 MODE BINARY NOSKIP", "ERROR bad_value: ternary: node 30: mode 0x04 sets NOSKIP on a BINARY node")
        expectPrefix("SET 30 MODE TERNARY", "ERROR bad_value: ternary: mode kind \"TERNARY\"")
        expectPrefix("SET 13 MODE TTHRESH", "ERROR bad_value: ternary: node 13 holds truth byte 200")
        expectPrefix("SET 12 TRUTH 7", "ERROR bad_value: ternary: SET TRUTH on ternary node 12 accepts 0..2, not 7")
        expectPrefix("SET 12 TRIT 2", "ERROR bad_value: ternary: trit 2")
        expectPrefix("SET 12 THRESH 2 1", "ERROR bad_value: ternary: threshold lo=2.0 > hi=1.0")
        expectPrefix("SET 12 THRESH nan 1", "ERROR bad_value: ternary: threshold lo=nan hi=1.0 is not finite")
        expectPrefix("SET 12 TTABLE 4", "ERROR bad_value: ternary: ttableId 4 is not below the library size 4")
        expectPrefix("SET 99 MODE TTABLE", "ERROR out_of_range: node 99 not in 0..<64")
        expectPrefix("SET 15 TTABLE 3", "OK SET node=15 ttable=3")
        // A register stays BINARY, both ways round.
        expect("CONNECT BACK FROM 3 TO 16", "OK CONNECT BACK from=3 to=16")
        expectPrefix("SET 16 MODE TTABLE", "ERROR bad_value: ternary: node 16 is a register")
        expectPrefix("CONNECT BACK FROM 3 TO 10", "ERROR bad_value: ternary: CONNECT BACK into ternary node 10")

        // ── COMPOSE on tables ──
        expect("SET 20 TTABLE 0", "OK SET node=20 ttable=0")
        expect("SET 20 MODE TTABLE", "OK SET node=20 mode=TTABLE noskip=0")
        expect("SET 21 TTABLE 3", "OK SET node=21 ttable=3")
        expect("SET 21 MODE TTABLE", "OK SET node=21 mode=TTABLE noskip=0")
        expect("COMPOSE AND 10 20 INTO 21", "OK COMPOSE op=AND src1=10 src2=20 dst=21 ttable=4")
        let and = try TernaryReference.composeTables(op: "AND", e.tableBytes(1)!, e.tableBytes(0)!)!
        XCTAssertEqual(e.tableBytes(4), and)
        XCTAssertEqual(e.ttableIdPtr[21], 4)
        expect("COMPOSE OR 10 20 INTO 21", "OK COMPOSE op=OR src1=10 src2=20 dst=21 ttable=5")
        expect("COMPOSE NOT 20 INTO 21", "OK COMPOSE op=NOT src1=20 src2=— dst=21 ttable=6")
        expect("TTABLE GET 6", "OK TTABLE GET tid=6 table=\(String(TernaryReference.composeTables(op: "NOT", e.tableBytes(0)!, nil)!.map { TernaryReference.char(ofTableByte: $0) }))")
        expectPrefix("COMPOSE XOR 10 20 INTO 21", "ERROR bad_value: ternary: XOR on tables is not defined")
        expectPrefix("COMPOSE AND 10 11 INTO 21", "ERROR bad_value: ternary: COMPOSE on tables needs TTABLE sources")
        expectPrefix("COMPOSE AND 10 30 INTO 21", "ERROR bad_value: ternary: COMPOSE mixes a TTABLE source")
        expectPrefix("COMPOSE AND 30 31 INTO 21", "ERROR bad_value: ternary: binary COMPOSE aimed at ternary node 21")
        expectPrefix("COMPOSE AND 10 20 INTO 30", "ERROR bad_value: ternary: COMPOSE on tables needs a TTABLE destination")
        expectPrefix("COMPOSE AND 30 31 INTO 32", "OK COMPOSE op=AND src1=30 src2=31 dst=32 lut=")   // binary, as today
        XCTAssertEqual(e.ttableCount, 7)

        // ── bulk verbs through the result file ──
        let shm8 = fixture.shm.advanced(by: 8)
        let bulkTables = (0..<(2 * 729)).map { UInt8(($0 / 3) % 3) }
        shm8.copyMemory(from: bulkTables, byteCount: bulkTables.count)
        shm1Header(fixture.shm, count: 2, verb: .ttableBulk)
        expect("TTABLE_BULK 7 2", "OK TTABLE_BULK first=7 count=2 tables=9")
        shm1Header(fixture.shm, count: 1, verb: .ttableBulk)   // the same bytes resent as one table: the count changes, so the header is rewritten
        expectPrefix("TTABLE_BULK 11 1", "ERROR bad_value: ternary: table id 11 leaves a gap")
        shm8.storeBytes(of: 3, toByteOffset: 5, as: UInt8.self)
        expectPrefix("TTABLE_BULK 9 1", "ERROR bad_value: ternary: table 9 byte 5 is 3")
        XCTAssertEqual(e.ttableCount, 9)

        let ids = shm8.bindMemory(to: UInt16.self, capacity: n)
        for i in 0..<n { ids[i] = UInt16(i % 9) }
        shm1Header(fixture.shm, count: n, verb: .setTTableIdsBulk)
        expect("SET_TTABLE_IDS_BULK", "OK SET_TTABLE_IDS_BULK nodes=\(n)")
        ids[7] = 9
        expectPrefix("SET_TTABLE_IDS_BULK", "ERROR bad_value: ternary: node 7: ttableId 9 is not below the library size 9")
        XCTAssertEqual(e.ttableIdPtr[7], 7)

        let thr = shm8.bindMemory(to: Float.self, capacity: 2 * n)
        for i in 0..<n { thr[2 * i] = -Float(i % 3) / 2; thr[2 * i + 1] = Float(i % 4) / 2 }
        shm1Header(fixture.shm, count: n, verb: .setThreshBulk)
        expect("SET_THRESH_BULK", "OK SET_THRESH_BULK nodes=\(n)")
        let threshHash = Self.stateHash(e)
        thr[2 * 9] = 5
        expectPrefix("SET_THRESH_BULK", "ERROR bad_value: ternary: node 9: threshold lo=5.0 > hi=")
        thr[2 * 9] = -Float(9 % 3) / 2
        thr[2 * 20 + 1] = .infinity
        expectPrefix("SET_THRESH_BULK", "ERROR bad_value: ternary: node 20: threshold lo=")
        thr[2 * 20 + 1] = Float(20 % 4) / 2
        thr[2 * 33] = .nan
        expectPrefix("SET_THRESH_BULK", "ERROR bad_value: ternary: node 33: threshold lo=nan")
        thr[2 * 33] = -Float(33 % 3) / 2
        XCTAssertEqual(Self.stateHash(e), threshHash, "a refused threshold vector must write nothing")

        // Mode vector: a third binary, a third TTABLE, a third TTHRESH, NOSKIP
        // on every other ternary node; the register (16) and the Loom node
        // (13) stay binary.
        let modes = shm8.bindMemory(to: UInt8.self, capacity: n)
        var ternaryCount = 0
        for i in 0..<n {
            let k = UInt8(i % 3)
            modes[i] = (i == 16 || i == 13 || k == 0) ? 0 : k | ((i / 3) % 2 == 0 ? 4 : 0)
            if modes[i] != 0 { ternaryCount += 1 }
        }
        shm1Header(fixture.shm, count: n, verb: .setModesBulk)
        // First refused vectors, one violation each — nothing is written.
        let before = Self.stateHash(e)
        let refusedCells: [(node: Int, mode: UInt8, reply: String)] = [
            (40, 3, "ERROR bad_value: ternary: node 40: mode 0x03 has kind 3"),
            (40, 0x09, "ERROR bad_value: ternary: node 40: mode 0x09 sets reserved bits 3-7 (0x08)"),
            (3, 4, "ERROR bad_value: ternary: node 3: mode 0x04 sets NOSKIP on a BINARY node"),
            (16, 1, "ERROR bad_value: ternary: node 16 is a register"),
            (13, 2, "ERROR bad_value: ternary: node 13 holds truth byte 200"),
        ]
        for c in refusedCells {
            let keep = modes[c.node]
            modes[c.node] = c.mode
            expectPrefix("SET_MODES_BULK", c.reply)
            XCTAssertEqual(Self.stateHash(e), before, "a refused bulk vector must write nothing (\(c.reply))")
            modes[c.node] = keep
        }
        // Truth of every node a ternary kind will land on must be < 3 —
        // through the verb, so the log carries it.
        let tr = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        for i in 0..<n where modes[i] != 0 && tr[i] >= 3 { expect("SET \(i) TRUTH 2", "OK SET node=\(i) truth=2") }
        expect("SET_MODES_BULK", "OK SET_MODES_BULK nodes=\(n) ternary=\(ternaryCount)")
        // The vector as written down here, copied out of the result file:
        // the next verb that writes rows (NODES) overwrites those bytes.
        let modeVec = Array(UnsafeBufferPointer(start: modes, count: n))
        // Give ternary nodes of each kind every trit, so GRAPH INFO's three
        // counts can each be wrong (nodes 1, 2, 4, 5, 7: modes 5, 6, 1, 2, 5).
        for (i, t) in [(1, 1), (2, 0), (4, 1), (5, 0), (7, -1)] {
            expect("SET \(i) TRIT \(t)", "OK SET node=\(i) trit=\(t)")
        }

        // ── GRAPH INFO, counted here independently ──
        var minus = 0, zero = 0, plus = 0
        for i in 0..<n where modeVec[i] != 0 {
            switch tr[i] { case 0: minus += 1; case 1: plus += 1; default: zero += 1 }
        }
        XCTAssertTrue(minus > 0 && zero > 0 && plus > 0, "-:\(minus) 0:\(zero) +:\(plus)")
        let gi = send("GRAPH INFO")
        XCTAssertTrue(gi.hasPrefix("OK GRAPH nodes=\(n) "), gi)
        XCTAssertTrue(gi.hasSuffix(" ternary_nodes=\(ternaryCount) trits=-:\(minus) 0:\(zero) +:\(plus)"), gi)

        // ── result rows carry the mode in byte 18, over every rank ──
        var rowsSeen = 0
        var modesSeen = Set<UInt8>()
        for rk in 0..<4 {
            expectPrefix("NODES AT RANK \(rk)", "OK NODES rows=")
            let rows = Int(fixture.shm.load(as: UInt32.self))
            XCTAssertEqual(fixture.shm.load(fromByteOffset: 4, as: UInt32.self), 24, "the row size stays 24")
            for r in 0..<rows {
                let row = fixture.shm.advanced(by: 8 + r * 24)
                let id = Int(row.load(as: UInt64.self))
                XCTAssertEqual(row.load(fromByteOffset: 18, as: UInt8.self), modeVec[id], "rank \(rk) row \(r) node \(id)")
                modesSeen.insert(modeVec[id])
            }
            rowsSeen += rows
        }
        XCTAssertEqual(rowsSeen, n)
        XCTAssertEqual(modesSeen, [0, 1, 2, 5, 6], "the rows should carry every legal mode byte")

        // ── the WAL alone, into a fresh engine, through the daemon's startup ──
        let live = Self.stateHash(e)
        fixture.handler.walAppender?.barrier()
        let grid = try HexGrid(width: side, height: side)
        let fresh = try DagDBEngine(grid: grid, state: DagDBState(width: side, height: side), maxRank: 8)
        let nb = fresh.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        for i in 0..<(n * 6) { nb[i] = -1 }
        let r = try DagDBStartup.recover(
            engine: fresh, nodeCount: n, width: side, height: side, dagdbEnv: nil, dataRoot: nil,
            twin: TwinState(), truthRankIndex: TruthRankIndex(), snapshotPath: nil, walPath: walPath,
            log: { _ in })
        XCTAssertNil(r.replayError)
        XCTAssertEqual(r.replay?.recordsSkipped, 0)
        XCTAssertEqual(r.replay?.refusals, [])
        XCTAssertEqual(r.replay?.fileVersion, DagDBWAL.versionV3)
        XCTAssertEqual(Self.stateHash(fresh), live, "WAL replay into a fresh engine must equal the live state")
        print("R5 WAL replay: records=\(r.replay?.recordsApplied ?? -1) skipped=\(r.replay?.recordsSkipped ?? -1) hash_equal=\(Self.stateHash(fresh) == live)")
    }

    func testR5SelectAfterTickSeesThePostTickTruth() throws {
        // Node 5: rank 0, LUT CONST0, truth 1 — the next tick writes 0.
        expect("SET 5 LUT CONST0", "OK SET node=5 lut=CONST0")
        expect("SET 5 TRUTH 1", "OK SET node=5 truth=1")
        expectPrefix("SELECT truth 1 rank 0-0", "OK SELECT truth=1 rank=0-0 matches=", contains: nil)
        let m1 = Int(fixture.shm.load(as: UInt32.self))
        let ids1 = (0..<m1).map { Int(fixture.shm.load(fromByteOffset: 8 + 4 * $0, as: Int32.self)) }
        XCTAssertTrue(ids1.contains(5))
        for verb in ["TICK 1", "TICK_SYNC 1", "EVAL"] {
            expect("SET 5 TRUTH 1", "OK SET node=5 truth=1")
            _ = send("SELECT truth 1 rank 0-0")              // the index is built here
            expectPrefix(verb, "OK")
            XCTAssertEqual(send("GET 5 TRUTH"), "OK GET node=5 truth=0")
            _ = send("SELECT truth 1 rank 0-0")
            let m = Int(fixture.shm.load(as: UInt32.self))
            let ids = (0..<m).map { Int(fixture.shm.load(fromByteOffset: 8 + 4 * $0, as: Int32.self)) }
            XCTAssertFalse(ids.contains(5), "SELECT after \(verb) still saw node 5's pre-tick truth")
        }
    }

    /// TTABLE PRESET with every wire name at every
    /// arity it is defined for, then out of range; each table read back over
    /// the socket equals the reference's, and the WAL replays every preset
    /// code to the same library.
    func testR5EveryPresetNameAtEveryArityOverTheSocket() throws {
        let names = ["TMIN", "TMAX", "TSUM", "TCONS", "TID", "TNEG", "TCONST-1", "TCONST0", "TCONST+1"]
        var tid = 0
        for name in names {
            let p = try XCTUnwrap(TernaryReference.Preset(rawValue: name), name)
            let ks: ClosedRange<Int> = (name == "TID" || name == "TNEG") ? 1...1 : 1...6
            for k in ks {
                expect("TTABLE PRESET \(tid) \(name) \(k)",
                       "OK TTABLE PRESET tid=\(tid) name=\(name) k=\(k) tables=\(tid + 1)")
                let want = String(try TernaryReference.presetTable(p, k: k).map { TernaryReference.char(ofTableByte: $0) })
                expect("TTABLE GET \(tid)", "OK TTABLE GET tid=\(tid) table=\(want)")
                tid += 1
            }
            expectPrefix("TTABLE PRESET \(tid) \(name) \(ks.upperBound + 1)",
                         "ERROR bad_value: ternary: preset \(name) is defined for k in \(ks.lowerBound)...\(ks.upperBound)")
            expectPrefix("TTABLE PRESET \(tid) \(name) 0",
                         "ERROR bad_value: ternary: preset \(name) is defined for k in \(ks.lowerBound)...\(ks.upperBound)")
        }
        XCTAssertEqual(tid, 7 * 6 + 2 * 1)
        XCTAssertEqual(fixture.handler.engine.ttableCount, tid)

        fixture.handler.walAppender?.barrier()
        let fresh = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                    state: DagDBState(width: side, height: side), maxRank: 8)
        let r = try DagDBWAL.replay(engine: fresh, nodeCount: side * side, path: walPath)
        XCTAssertEqual(r.recordsApplied, tid)
        XCTAssertEqual(r.recordsSkipped, 0)
        XCTAssertEqual(fresh.libraryBytes(), fixture.handler.engine.libraryBytes())
    }

    func testR5EveryNewMutatingVerbIsRefusedInAReaderSession() throws {
        expect("TTABLE PRESET 0 TID 1", "OK TTABLE PRESET tid=0 name=TID k=1 tables=1")
        let open = send("OPEN_READER")
        XCTAssertTrue(open.hasPrefix("OK OPEN_READER id="), open)
        let id = String(open.split(separator: " ")[2].dropFirst(3))
        let t = String(repeating: "0", count: 729)
        let mutating = [
            "SET 1 MODE TTABLE", "SET 1 TTABLE 0", "SET 1 THRESH 0 1", "SET 1 TRIT 1",
            "TTABLE DEFINE 1 \(t)", "TTABLE PRESET 1 TMIN 2",
            "SET_MODES_BULK", "SET_TTABLE_IDS_BULK", "SET_THRESH_BULK", "TTABLE_BULK 1 1",
            "COMPOSE AND 1 2 INTO 3",
        ]
        for v in mutating {
            XCTAssertEqual(send("READER \(id) \(v)"),
                           "ERROR forbidden: command not allowed in reader session (read-only)", v)
        }
        XCTAssertEqual(fixture.handler.engine.ttableCount, 1)
        // The read-only ones are served from the session's snapshot.
        expect("READER \(id) GET 1 TRIT", "OK GET session=\(id) node=1 trit=-1")
        expect("READER \(id) TTABLE GET 0",
               "OK TTABLE GET session=\(id) tid=0 table=\(String(try TernaryReference.presetTable(.tid, k: 1).map { TernaryReference.char(ofTableByte: $0) }))")
        expectPrefix("READER \(id) GRAPH INFO", "OK GRAPH session=\(id)", contains: "ternary_nodes=0 trits=-:0 0:0 +:0")
    }
}
