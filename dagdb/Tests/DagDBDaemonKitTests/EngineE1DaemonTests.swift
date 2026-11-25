import XCTest
import CryptoKit
@testable import DagDB
@testable import DagDBDaemonKit

/// The IMPORT MORTON WAL record and SAVE's refusals, through the daemon's own
/// handler.
///
/// IMPORT MORTON writes a WAL record: the live session's log,
/// replayed into a fresh engine through the daemon's startup path, gives a
/// state whose snapshot bytes equal the live state's — with the import
/// directory deleted before the replay, so the log alone carries it.
/// (The kill -9 of a real daemon is `test_engine_e1_live.py`.)
///
/// SAVE refuses what LOAD refuses, by LOAD's own words, writing
/// nothing; rank-mode TICK on a graph that fails the DAG check is refused by
/// name; TICK_SYNC is unaffected.
///
/// The file uses only verbs and library calls that exist on main, so it runs
/// against main's code (the red run) and against the fix (the green run).
final class EngineE1DaemonTests: XCTestCase {

    private var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "engine-e1-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - Objects

    /// A deterministic generator (SplitMix64), so every run builds the same graphs.
    struct Rng {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    /// A valid DAG on `e` (ranks by blocks, every edge from a strictly higher
    /// rank, no duplicates), random LUTs and truth, registers at the top rank
    /// fed by back edges, non-default weights and node values; with
    /// `ternary`, a two-table library and TTABLE / TTHRESH / NOSKIP nodes.
    static func buildGraph(_ e: DagDBEngine, seed: UInt64, ternary: Bool) throws {
        let n = e.nodeCount
        var g = Rng(s: seed)
        let levels = 8
        let block = (n + levels - 1) / levels
        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let low = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high = e.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        let w = e.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        let v = e.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)
        for i in 0..<n {
            rank[i] = UInt64(i / block)
            truth[i] = UInt8(g.below(2))
            let lut = g.next()
            low[i] = UInt32(lut & 0xFFFF_FFFF); high[i] = UInt32(lut >> 32)
            v[i] = Float(g.below(2001)) / 1000 - 1
            for d in 0..<6 { nb[i * 6 + d] = -1; w[i * 6 + d] = Float(g.below(400)) / 100 - 2 }
        }
        for i in 0..<n where Int(rank[i]) < levels - 1 {
            let nextLo = (Int(rank[i]) + 1) * block
            let nextHi = min(n, nextLo + block)
            guard nextHi > nextLo else { continue }
            var used = Set<Int32>()
            for d in 0..<(1 + g.below(6)) {
                let s = Int32(nextLo + g.below(nextHi - nextLo))
                if used.insert(s).inserted { nb[i * 6 + d] = s }
            }
        }
        // Registers: top-rank nodes (no combinational inputs), each fed by a back edge.
        let top = (levels - 1) * block
        for k in 0..<min(12, n - top) {
            let dst = UInt32(top + k)
            let src = UInt32(g.below(top))
            try e.addBackEdge(src: src, dst: dst)
        }
        guard ternary else { return }
        // Library: TSUM over 6 inputs and its negation.
        var t0 = [UInt8](repeating: 2, count: TernaryReference.tableSize)
        var t1 = t0
        for idx in 0..<TernaryReference.tableSize {
            var s = 0, x = idx
            for _ in 0..<6 { s += x % 3 - 1; x /= 3 }
            let trit = s > 0 ? 1 : (s < 0 ? -1 : 0)
            t0[idx] = TernaryReference.byte(ofTrit: trit)
            t1[idx] = TernaryReference.byte(ofTrit: -trit)
        }
        try e.writeTables(first: 0, bytes: t0 + t1)
        for i in stride(from: 3, to: top, by: 5) {
            let kind = g.below(3)
            if kind == 0 {
                e.setNodeMode(i, 1 | (g.below(2) == 0 ? TernaryReference.noskipBit : 0))
                e.ttableIdPtr[i] = UInt16(g.below(2))
            } else if kind == 1 {
                e.setNodeMode(i, 2)
                let lo = Float(g.below(200)) / 100 - 1
                e.thrLoPtr[i] = lo; e.thrHiPtr[i] = lo + Float(g.below(100)) / 100
            } else { continue }
            truth[i] = UInt8(g.below(3))
        }
        XCTAssertNil(e.ternaryStateViolation())
    }

    /// The snapshot bytes of `e` (library SAVE: no WAL checkpoint, tick 0).
    func snapshotBytes(_ e: DagDBEngine, side: Int, name: String) throws -> Data {
        let p = tmp + name
        _ = try DagDBSnapshot.save(engine: e, nodeCount: e.nodeCount, gridW: side, gridH: side,
                                   tickCount: 0, path: p)
        return try Data(contentsOf: URL(fileURLWithPath: p))
    }

    func freshEngine(side: Int, maxRank: Int = 8) throws -> DagDBEngine {
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side), maxRank: maxRank)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        return e
    }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    // MARK: - IMPORT MORTON writes a WAL record

    /// One cell: a source graph exported; a live daemon (WAL on) takes SETs,
    /// the IMPORT, more SETs; the directory is deleted; the log alone, through
    /// the startup path, rebuilds a state whose snapshot bytes equal the live
    /// one's.
    func importReplayCell(side: Int, seed: UInt64, ternary: Bool) throws -> (equal: Bool, line: String) {
        let n = side * side
        let src = try freshEngine(side: side)
        try Self.buildGraph(src, seed: seed, ternary: ternary)
        let dir = tmp + "imp-\(seed)"
        _ = try DagDBSnapshot.exportMorton(engine: src, nodeCount: n, dir: dir)

        let walPath = tmp + "live-\(seed).wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: n)
        let f = try HandlerFixture(side: side, dataRoot: tmp, wal: wal)
        let h = f.handler
        XCTAssertTrue(h.handle("SET 5 TRUTH 1").hasPrefix("OK"))
        XCTAssertTrue(h.handle("SET 7 RANK 3").hasPrefix("OK"))
        let imp = h.handle("IMPORT MORTON \(dir)")
        XCTAssertTrue(imp.hasPrefix("OK IMPORT"), imp)
        try FileManager.default.removeItem(atPath: dir)          // the log must carry the import alone
        XCTAssertTrue(h.handle("SET 9 TRUTH 0").hasPrefix("OK"))
        XCTAssertTrue(h.handle("SET 2 LUT 0xF0F0").hasPrefix("OK"))
        h.walAppender?.barrier()
        let live = try snapshotBytes(h.engine, side: side, name: "live-\(seed).dags")

        let fresh = try freshEngine(side: side)
        let r = try DagDBStartup.recover(
            engine: fresh, nodeCount: n, width: side, height: side, dagdbEnv: nil, dataRoot: tmp,
            twin: TwinState(), truthRankIndex: TruthRankIndex(), snapshotPath: nil, walPath: walPath,
            log: { _ in })
        XCTAssertNil(r.replayError)
        let replayed = try snapshotBytes(fresh, side: side, name: "replayed-\(seed).dags")
        let line = "E1.1 side=\(side) ternary=\(ternary) records=\(r.replay?.recordsApplied ?? -1) " +
            "skipped=\(r.replay?.recordsSkipped ?? -1) live=\(Self.sha(live).prefix(12)) " +
            "replayed=\(Self.sha(replayed).prefix(12)) equal=\(live == replayed)"
        print(line)
        return (live == replayed, line)
    }

    func testItem1ImportMortonReplaysByteIdentical() throws {
        var equal = 0
        let cells: [(Int, UInt64, Bool)] = [(16, 0xE11, false), (16, 0xE12, true), (24, 0xE13, true)]
        for (side, seed, ternary) in cells {
            let c = try importReplayCell(side: side, seed: seed, ternary: ternary)
            XCTAssertTrue(c.equal, c.line)
            if c.equal { equal += 1 }
        }
        print("E1.1 handler+startup replay: \(equal)/\(cells.count) EQUAL (snapshot bytes)")
    }

    /// Control: the replay of a log WITHOUT an import equals its live state
    /// (the comparison is not vacuous: the import cell's inequality on main
    /// comes from the import alone).
    func testItem1ControlNoImportReplaysEqual() throws {
        let side = 16, n = side * side
        let walPath = tmp + "control.wal"
        let f = try HandlerFixture(side: side, dataRoot: tmp, wal: try DagDBWAL.Appender(path: walPath, nodeCount: n))
        for (i, cmd) in ["SET 5 TRUTH 1", "SET 7 RANK 3", "SET 9 LUT 0xFF", "CONNECT FROM 7 TO 9"].enumerated() {
            XCTAssertTrue(f.handler.handle(cmd).hasPrefix("OK"), "\(i): \(cmd)")
        }
        f.handler.walAppender?.barrier()
        let live = try snapshotBytes(f.handler.engine, side: side, name: "c-live.dags")
        let fresh = try freshEngine(side: side)
        _ = try DagDBStartup.recover(engine: fresh, nodeCount: n, width: side, height: side, dagdbEnv: nil,
                                     dataRoot: tmp, twin: TwinState(), truthRankIndex: TruthRankIndex(),
                                     snapshotPath: nil, walPath: walPath, log: { _ in })
        XCTAssertEqual(live, try snapshotBytes(fresh, side: side, name: "c-replayed.dags"))
    }

    // MARK: - SAVE refuses what LOAD refuses; rank-mode TICK refuses an invalid graph

    /// The voxel client's layout-B object, small: a 4-neighbour torus lattice, every
    /// rank 0 (a cyclic graph TICK_SYNC is defined on).
    func cyclicLattice(_ f: HandlerFixture, side: Int) -> String {
        let n = side * side
        let v = f.shm.advanced(by: 8).bindMemory(to: Int32.self, capacity: n * 6)
        for y in 0..<side {
            for x in 0..<side {
                let i = y * side + x
                let nbrs = [y * side + (x + side - 1) % side, y * side + (x + 1) % side,
                            ((y + side - 1) % side) * side + x, ((y + 1) % side) * side + x]
                for d in 0..<6 { v[i * 6 + d] = d < 4 ? Int32(nbrs[d]) : -1 }
            }
        }
        shm1Header(f.shm, count: n, verb: .setNeighborsBulk)
        return f.handler.handle("SET_NEIGHBORS_BULK")
    }

    /// Under the slot model the lattice's rank inversions (S3) are a store
    /// shape. An earlier build's SAVE refused them in LOAD's words and wrote
    /// nothing; now SAVE and SAVE
    /// COMPRESSED write the file and its manifest, the WAL gains the
    /// snapshot's bind record and checkpoint, and LOAD of the file gives the
    /// same state. VALIDATE still names the rank-mode DAG property.
    func testItem2SaveWritesTheCyclicLatticeAndLoadGivesItBack() throws {
        let side = 16
        let walPath = tmp + "e12.wal"
        let f = try HandlerFixture(side: side, dataRoot: tmp,
                                   wal: try DagDBWAL.Appender(path: walPath, nodeCount: side * side))
        XCTAssertTrue(cyclicLattice(f, side: side).hasPrefix("OK SET_NEIGHBORS_BULK"))
        let v = f.handler.handle("VALIDATE")
        XCTAssertTrue(v.hasPrefix("FAIL VALIDATE node 0 slot 0: src rank 0 must be > dst rank 0"), v)
        let live = try snapshotBytes(f.handler.engine, side: side, name: "live.dags")
        for (verb, name) in [("SAVE", "b.dags"), ("SAVE COMPRESSED", "bz.dags")] {
            f.handler.walAppender?.barrier()
            let walBefore = try Data(contentsOf: URL(fileURLWithPath: walPath))
            let path = tmp + name
            let r = f.handler.handle(verb == "SAVE" ? "SAVE \(path)" : "SAVE \(path) COMPRESSED")
            print("E1.2 \(verb) cyclic lattice -> \(r)")
            XCTAssertTrue(r.hasPrefix("OK SAVE"), "\(verb): \(r)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "\(verb) wrote no file")
            XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".sha256"), "\(verb) wrote no manifest")
            XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".tmp"), "\(verb) left its tmp file")
            f.handler.walAppender?.barrier()
            let walAfter = try Data(contentsOf: URL(fileURLWithPath: walPath))
            var ops: [UInt8] = [], off = walBefore.count
            while off + 5 <= walAfter.count {
                let len = walAfter[off..<(off + 4)].withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
                ops.append(walAfter[off + 4]); off += 5 + len
            }
            XCTAssertEqual(ops, [0x51, 0xF0], "\(verb): the WAL gains a bind record and a checkpoint")
            let g = try HandlerFixture(side: side, dataRoot: tmp)
            let l = g.handler.handle("LOAD \(path)")
            XCTAssertTrue(l.hasPrefix("OK LOAD"), "\(verb): \(l)")
            XCTAssertEqual(try snapshotBytes(g.handler.engine, side: side, name: "back_\(name)"), live,
                           "\(verb): LOAD gives the same state")
        }
    }

    /// LOAD's four DAG rules as they were before the slot model, one cell each. The source out
    /// of range: the rule broken in a file LOAD reads gives LOAD's refusal;
    /// the same rule broken in the live graph gives SAVE's — the same words
    /// after the verb. Under the slot model the self-loop, the rank order and the duplicate are store shapes (S2, S3,
    /// S1) — LOAD loads the file, SAVE writes the live graph, and the saved
    /// file loads back to the same state. Control: the valid graph SAVEs and
    /// LOADs.
    func testItem2SaveAndLoadRefuseTheSameRulesWithTheSameWords() throws {
        let side = 16, n = side * side
        let f = try HandlerFixture(side: side, dataRoot: tmp)
        let e = f.handler.engine
        try Self.buildGraph(e, seed: 0xE2, ternary: false)
        let good = tmp + "good.dags"
        XCTAssertTrue(f.handler.handle("SAVE \(good)").hasPrefix("OK SAVE"))
        XCTAssertTrue(f.handler.handle("LOAD \(good)").hasPrefix("OK LOAD"), "control: the valid graph loads")
        let fileData = try Data(contentsOf: URL(fileURLWithPath: good))
        XCTAssertEqual(fileData.prefix(8).suffix(4).withUnsafeBytes { $0.load(as: UInt32.self) }, 7, "v7 body")
        let nbOff = 32 + 18 * n
        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        // A node with a free slot 5 and at least one input, below the top rank.
        let dst = (0..<n).first { nb[$0 * 6] >= 0 && nb[$0 * 6 + 5] < 0 }!
        let sameRank = (0..<n).first { $0 != dst && rank[$0] == rank[dst] }!
        let cells: [(String, Int32)] = [("out of range", Int32(n + 3)), ("self-loop", Int32(dst)),
                                        ("rank order", Int32(sameRank)), ("duplicate", nb[dst * 6])]
        var same = 0, roundTrips = 0
        for (rule, src) in cells {
            // LOAD's verdict, from a file.
            var bytes = fileData
            withUnsafeBytes(of: src.littleEndian) { bytes.replaceSubrange((nbOff + (dst * 6 + 5) * 4)..<(nbOff + (dst * 6 + 5) * 4 + 4), with: $0) }
            let bad = tmp + "bad.dags"
            try bytes.write(to: URL(fileURLWithPath: bad))
            try Data((Self.sha(bytes) + "\n").utf8).write(to: URL(fileURLWithPath: bad + ".sha256"))
            let load = f.handler.handle("LOAD \(bad)")
            // SAVE's verdict, from the live graph broken the same way.
            XCTAssertTrue(f.handler.handle("LOAD \(good)").hasPrefix("OK LOAD"))
            nb[dst * 6 + 5] = src
            let out = tmp + "out.dags"
            let save = f.handler.handle("SAVE \(out)")
            let liveBytes = try snapshotBytes(e, side: side, name: "live_\(same + roundTrips).dags")
            nb[dst * 6 + 5] = -1
            print("E1.2 \(rule): LOAD -> \(load) | SAVE -> \(save)")
            if rule == "out of range" {
                XCTAssertTrue(load.hasPrefix("ERROR io: load: validation: "), "\(rule): \(load)")
                XCTAssertEqual(save, load.replacingOccurrences(of: "ERROR io: load: ", with: "ERROR io: save: "), rule)
                XCTAssertFalse(FileManager.default.fileExists(atPath: out), "\(rule): SAVE wrote a file")
                if save == load.replacingOccurrences(of: "ERROR io: load: ", with: "ERROR io: save: ") { same += 1 }
            } else {
                XCTAssertTrue(load.hasPrefix("OK LOAD"), "\(rule): \(load)")
                XCTAssertTrue(save.hasPrefix("OK SAVE"), "\(rule): \(save)")
                let g = try HandlerFixture(side: side, dataRoot: tmp)
                XCTAssertTrue(g.handler.handle("LOAD \(out)").hasPrefix("OK LOAD"), rule)
                let back = try snapshotBytes(g.handler.engine, side: side, name: "back_\(same + roundTrips).dags")
                XCTAssertEqual(back, liveBytes, "\(rule): the saved file loads back to the same state")
                if load.hasPrefix("OK LOAD") && save.hasPrefix("OK SAVE") && back == liveBytes { roundTrips += 1 }
                for p in [out, out + ".sha256"] { try? FileManager.default.removeItem(atPath: p) }
            }
        }
        print("E1.2 SAVE == LOAD refusal: \(same)/1 rule (out of range); loaded, saved and round-tripped: \(roundTrips)/3 shapes")
        XCTAssertTrue(f.handler.handle("SAVE \(tmp!)again.dags").hasPrefix("OK SAVE"), "control after the cells")
    }

    func testItem2RankTickRefusesTheCyclicLatticeTickSyncRuns() throws {
        let side = 16
        let f = try HandlerFixture(side: side, dataRoot: tmp)
        let h = f.handler
        XCTAssertTrue(cyclicLattice(f, side: side).hasPrefix("OK SET_NEIGHBORS_BULK"))
        let truth = h.engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: side * side)
        truth[0] = 1
        let lut = f.shm.advanced(by: 8).bindMemory(to: UInt64.self, capacity: side * side)
        for i in 0..<(side * side) { lut[i] = 0xFFFF_FFFF_FFFF_FFFE }          // OR of the inputs: a flood
        shm1Header(f.shm, count: side * side, verb: .setLutsBulk)
        XCTAssertTrue(h.handle("SET_LUTS_BULK").hasPrefix("OK"))
        let before = Array(UnsafeBufferPointer(start: truth, count: side * side))
        let t = h.handle("TICK 1")
        print("E1.2 rank-mode TICK on the cyclic lattice -> \(t)")
        XCTAssertTrue(t.hasPrefix("ERROR "), t)
        XCTAssertTrue(t.contains("node 0 slot 0: src rank 0 must be > dst rank 0"), t)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: h.engine.truthStateBuf.contents()
            .bindMemory(to: UInt8.self, capacity: side * side), count: side * side)), before,
            "a refused TICK computes nothing")
        XCTAssertTrue(h.handle("STATUS").contains(" ticks=0 "), "a refused TICK does not count")
        let s = h.handle("TICK_SYNC 1")
        XCTAssertTrue(s.hasPrefix("OK TICK_SYNC 1"), s)
        let after = h.engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: side * side)
        XCTAssertEqual(after[1], 1, "TICK_SYNC floods one hop on the cyclic lattice")
        // The graph made valid again: rank-mode TICK runs (the verdict is not stale).
        let v = f.shm.advanced(by: 8).bindMemory(to: Int32.self, capacity: side * side * 6)
        for i in 0..<(side * side * 6) { v[i] = -1 }
        shm1Header(f.shm, count: side * side, verb: .setNeighborsBulk)
        XCTAssertTrue(h.handle("SET_NEIGHBORS_BULK").hasPrefix("OK"))
        XCTAssertTrue(h.handle("TICK 1").hasPrefix("OK TICK 1"))
    }

    func testItem2ControlValidGraphTicksAndSaves() throws {
        let side = 16
        let f = try HandlerFixture(side: side, dataRoot: tmp)
        try Self.buildGraph(f.handler.engine, seed: 0xC2, ternary: true)
        for (c, want) in [("VALIDATE", "OK VALIDATE"), ("TICK 3", "OK TICK 3"),
                          ("SAVE \(tmp!)v.dags", "OK SAVE"), ("LOAD \(tmp!)v.dags", "OK LOAD")] {
            let r = f.handler.handle(c)
            XCTAssertTrue(r.hasPrefix(want), "\(c) -> \(r)")
        }
    }
}
