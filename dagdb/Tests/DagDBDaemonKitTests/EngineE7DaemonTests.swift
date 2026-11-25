import XCTest
import CryptoKit
import Metal
@testable import DagDB
@testable import DagDBDaemonKit

/// The slot model.
///
/// It names four slot shapes: S1 a duplicate
/// source within one node's six slots, S2 a slot self-loop, S3 a rank
/// inversion (the source's rank ≤ the destination's), S4 a slot into a
/// register. Persistence accepts S1–S3; S4 is refused everywhere; rank-mode
/// TICK keeps its refusals; TICK_SYNC is defined on these graphs.
///
/// This file: every persistence path round-trips
/// a graph holding S1–S3, and TICK_SYNC k (k = 1, 7, 64) on the loaded
/// daemon equals TICK_SYNC k on a never-saved daemon holding the same graph
/// through SET_NEIGHBORS_BULK; the crash cells recover from the startup path
/// and the WAL. Also this file: rank-mode TICK still refuses S2/S3 graphs by
/// name after every loader, over a daemon whose cached verdict was "valid".
/// S4 and the older S4 states: `EngineE7DaemonTests+S4.swift`.
///
/// The file uses only verbs and library calls that exist before the slot
/// model, so it runs on the older code (the red run) and on the new (the
/// green run).
final class EngineE7DaemonTests: XCTestCase {

    static let maxRank = 16

    var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "engine-e7-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - Objects

    /// SplitMix64, so every run builds the same graphs.
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

    enum Shape: String, CaseIterable { case s1 = "S1", s2 = "S2", s3 = "S3" }

    /// A graph and every lane the daemon is given; the slots go in through
    /// SET_NEIGHBORS_BULK, the rest in-process.
    struct Graph {
        var name: String
        var side: Int
        var n: Int { side * side }
        var rank: [UInt64]
        var truth: [UInt8]
        var lut: [UInt64]
        var weight: [Float]
        var value: [Float]
        var nb: [Int32]
        var isReg: [Bool]
        var regs: [(UInt32, UInt32)]
        var ternary: Bool
        /// node, mode byte, table id, lo, hi
        var modes: [(Int, UInt8, UInt16, Float, Float)]
        var shapes: Set<Shape>
        /// The slots the tail's SET_NEIGHBORS_BULK installs (more S1–S3 of the same kinds).
        var tailNb: [Int32]
    }

    /// The two-table library (TSUM over six inputs and its negation), built as `EngineE1DaemonTests` builds it.
    static let tables: [UInt8] = {
        var t0 = [UInt8](repeating: 2, count: TernaryReference.tableSize)
        var t1 = t0
        for idx in 0..<TernaryReference.tableSize {
            var s = 0, x = idx
            for _ in 0..<6 { s += x % 3 - 1; x /= 3 }
            let trit = s > 0 ? 1 : (s < 0 ? -1 : 0)
            t0[idx] = TernaryReference.byte(ofTrit: trit)
            t1[idx] = TernaryReference.byte(ofTrit: -trit)
        }
        return t0 + t1
    }()

    /// Injects the requested shapes into free slots of non-register nodes
    /// (about `rate` % of them); returns the nodes each shape went to.
    static func inject(_ nb: inout [Int32], rank: [UInt64], isReg: [Bool], shapes: Set<Shape>,
                       g: inout Rng, rate: Int) -> [Shape: [Int]] {
        let n = rank.count
        let kinds = Shape.allCases.filter { shapes.contains($0) }
        var at: [Shape: [Int]] = [:]
        guard !kinds.isEmpty else { return at }
        for i in 0..<n where !isReg[i] {
            guard g.below(100) < rate, let f = (0..<6).first(where: { nb[i * 6 + $0] < 0 }) else { continue }
            let s = kinds[g.below(kinds.count)]
            switch s {
            case .s1:
                guard let k = (0..<6).first(where: { nb[i * 6 + $0] >= 0 }) else { continue }
                nb[i * 6 + f] = nb[i * 6 + k]
            case .s2:
                nb[i * 6 + f] = Int32(i)
            case .s3:
                var pick: Int32 = -1
                for _ in 0..<32 {
                    let c = g.below(n)
                    if c != i && rank[c] <= rank[i] && !(0..<6).contains(where: { nb[i * 6 + $0] == Int32(c) }) {
                        pick = Int32(c); break
                    }
                }
                guard pick >= 0 else { continue }
                nb[i * 6 + f] = pick
            }
            at[s, default: []].append(i)
        }
        return at
    }

    /// Ranks 0–5 at random, registers every 11th node from 5 (no slots, a
    /// back edge from a random other node), up to three legal sources per
    /// other node (strictly higher rank, distinct), then the shapes. With
    /// `ternary`, the library and TTABLE / TTHRESH nodes, the first S1 and the
    /// first S2 node among them.
    static func slotGraph(side: Int, seed: UInt64, shapes: Set<Shape>, ternary: Bool) -> Graph {
        let n = side * side
        var g = Rng(s: seed)
        let rank = (0..<n).map { _ in UInt64(g.below(6)) }
        var isReg = [Bool](repeating: false, count: n)
        var regs: [(UInt32, UInt32)] = []
        for d in stride(from: 5, to: n, by: 11) {
            isReg[d] = true
            var s = g.below(n); if s == d { s = (s + 1) % n }
            regs.append((UInt32(s), UInt32(d)))
        }
        var nb = [Int32](repeating: -1, count: n * 6)
        for i in 0..<n where !isReg[i] {
            let want = g.below(4)
            var k = 0
            for _ in 0..<24 where k < want {
                let s = g.below(n)
                if rank[s] > rank[i] && !(0..<k).contains(where: { nb[i * 6 + $0] == Int32(s) }) {
                    nb[i * 6 + k] = Int32(s); k += 1
                }
            }
        }
        var at = inject(&nb, rank: rank, isReg: isReg, shapes: shapes, g: &g, rate: 30)
        while shapes.contains(where: { at[$0] == nil }) {
            for (k, v) in inject(&nb, rank: rank, isReg: isReg, shapes: shapes, g: &g, rate: 100) {
                at[k, default: []] += v
            }
        }
        var tailNb = nb
        _ = inject(&tailNb, rank: rank, isReg: isReg, shapes: shapes, g: &g, rate: 25)
        var truth = (0..<n).map { _ in UInt8(g.below(2)) }
        let lut = (0..<n).map { _ in g.next() }
        let weight = (0..<(n * 6)).map { _ in Float(g.below(400)) / 100 - 2 }
        let value = (0..<n).map { _ in Float(g.below(2001)) / 1000 - 1 }
        var modes: [(Int, UInt8, UInt16, Float, Float)] = []
        if ternary {
            var tern = Set((0..<n).filter { !isReg[$0] && $0 % 4 == 1 })
            if let a = at[.s1]?.first { tern.insert(a) }
            if let b = at[.s2]?.first { tern.insert(b) }
            for i in tern.sorted() {
                if g.below(3) == 0 {
                    let lo = Float(g.below(200)) / 100 - 1
                    modes.append((i, 2, 0, lo, lo + Float(g.below(100)) / 100))
                } else {
                    modes.append((i, 1 | (g.below(2) == 0 ? TernaryReference.noskipBit : 0), UInt16(g.below(2)), 0, 0))
                }
                truth[i] = UInt8(g.below(3))
            }
        }
        let name = "side\(side) \(shapes.map(\.rawValue).sorted().joined(separator: "+")) \(ternary ? "ternary" : "binary")"
        return Graph(name: name, side: side, rank: rank, truth: truth, lut: lut, weight: weight, value: value,
                     nb: nb, isReg: isReg, regs: regs, ternary: ternary, modes: modes, shapes: shapes, tailNb: tailNb)
    }

    /// The voxel client's layout-B object: a 4-neighbour torus, every rank 0 (S3 on
    /// every slot), LUT = OR of the inputs (a flood); registers every 37th
    /// node from 3 (their slots cleared, a back edge from the next node).
    static func lattice(side: Int, seed: UInt64) -> Graph {
        let n = side * side
        var g = Rng(s: seed)
        var nb = [Int32](repeating: -1, count: n * 6)
        var isReg = [Bool](repeating: false, count: n)
        var regs: [(UInt32, UInt32)] = []
        for d in stride(from: 3, to: n, by: 37) { isReg[d] = true; regs.append((UInt32((d + 1) % n), UInt32(d))) }
        for y in 0..<side {
            for x in 0..<side {
                let i = y * side + x
                guard !isReg[i] else { continue }
                let nbrs = [y * side + (x + side - 1) % side, y * side + (x + 1) % side,
                            ((y + side - 1) % side) * side + x, ((y + 1) % side) * side + x]
                for d in 0..<4 { nb[i * 6 + d] = Int32(nbrs[d]) }
            }
        }
        var tailNb = nb
        // The tail: a self-loop slot on every 5th non-register node (slot 4).
        for i in stride(from: 0, to: n, by: 5) where !isReg[i] { tailNb[i * 6 + 4] = Int32(i) }
        let truth = (0..<n).map { _ in UInt8(g.below(40) == 0 ? 1 : 0) }
        return Graph(name: "lattice \(side)x\(side) S3 binary", side: side,
                     rank: [UInt64](repeating: 0, count: n), truth: truth,
                     lut: [UInt64](repeating: 0xFFFF_FFFF_FFFF_FFFE, count: n),
                     weight: [Float](repeating: 1, count: n * 6), value: [Float](repeating: 0, count: n),
                     nb: nb, isReg: isReg, regs: regs, ternary: false, modes: [], shapes: [.s3], tailNb: tailNb)
    }

    /// The persistence round trip's object: each shape alone and all three, binary and ternary,
    /// sides 8 and 16; the lattice at 16² and 64².
    static func graphs() -> [Graph] {
        var out: [Graph] = []
        var seed: UInt64 = 0xE7_0000
        for side in [8, 16] {
            for ternary in [false, true] {
                for shapes in [[Shape.s1], [.s2], [.s3], [.s1, .s2, .s3]] {
                    seed &+= 1
                    out.append(slotGraph(side: side, seed: seed, shapes: Set(shapes), ternary: ternary))
                }
            }
        }
        out.append(lattice(side: 16, seed: 0xE7_1616))
        out.append(lattice(side: 64, seed: 0xE7_6464))
        return out
    }

    // MARK: - Daemons

    func fixture(side: Int, wal: String? = nil, startup: String? = nil) throws -> HandlerFixture {
        let f = try HandlerFixture(side: side, dataRoot: tmp,
                                   wal: try wal.map { try DagDBWAL.Appender(path: $0, nodeCount: side * side) },
                                   maxRank: Self.maxRank)
        f.handler.startupSnapshotPath = startup
        return f
    }

    @discardableResult
    func ok(_ f: HandlerFixture, _ line: String, file: StaticString = #filePath, l: UInt = #line) -> String {
        let r = f.handler.handle(line)
        XCTAssertTrue(r.hasPrefix("OK"), "\(line) -> \(r)", file: file, line: l)
        return r
    }

    func putNeighbors(_ f: HandlerFixture, _ nb: [Int32]) {
        let v = f.shm.advanced(by: 8).bindMemory(to: Int32.self, capacity: nb.count)
        for i in 0..<nb.count { v[i] = nb[i] }
        shm1Header(f.shm, count: nb.count / 6, verb: .setNeighborsBulk)
    }

    /// The graph's lanes in-process, its registers (checked: no slot is live
    /// yet), then its slots through SET_NEIGHBORS_BULK. Returns the bulk's reply.
    @discardableResult
    func install(_ f: HandlerFixture, _ gr: Graph) throws -> String {
        let e = f.handler.engine, n = gr.n
        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let low = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high = e.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let w = e.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        let v = e.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)
        for i in 0..<n {
            rank[i] = gr.rank[i]; truth[i] = gr.truth[i]; v[i] = gr.value[i]
            low[i] = UInt32(gr.lut[i] & 0xFFFF_FFFF); high[i] = UInt32(gr.lut[i] >> 32)
            for d in 0..<6 { w[i * 6 + d] = gr.weight[i * 6 + d] }
        }
        if gr.ternary {
            try e.writeTables(first: 0, bytes: Self.tables)
            for (i, m, t, lo, hi) in gr.modes {
                e.setNodeMode(i, m); e.ttableIdPtr[i] = t; e.thrLoPtr[i] = lo; e.thrHiPtr[i] = hi
            }
            XCTAssertNil(e.ternaryStateViolation(), gr.name)
        }
        for (s, d) in gr.regs { try e.addBackEdge(src: s, dst: d) }
        e.markRankTopologyDirty()
        f.handler.truthRankIndex.markDirty()
        putNeighbors(f, gr.nb)
        return f.handler.handle("SET_NEIGHBORS_BULK")
    }

    /// A daemon holding the graph, never saved.
    func daemon(_ gr: Graph, wal: String? = nil, startup: String? = nil) throws -> HandlerFixture {
        let f = try fixture(side: gr.side, wal: wal, startup: startup)
        let r = try install(f, gr)
        XCTAssertTrue(r.hasPrefix("OK SET_NEIGHBORS_BULK"), "\(gr.name): \(r)")
        return f
    }

    /// The tail: logged writes after the persistence op (more S1–S3 through
    /// SET_NEIGHBORS_BULK, a truth write).
    func tail(_ f: HandlerFixture, _ gr: Graph) {
        putNeighbors(f, gr.tailNb)
        ok(f, "SET_NEIGHBORS_BULK")
        ok(f, "SET 0 TRUTH 1")
    }

    /// The daemon's start over a fresh engine (main.swift's order).
    func recover(side: Int, snapshot: String?, wal: String) throws -> (HandlerFixture, [String]) {
        let g = try fixture(side: side)
        var lines: [String] = []
        let r = try DagDBStartup.recover(
            engine: g.handler.engine, nodeCount: side * side, width: side, height: side,
            dagdbEnv: nil, dataRoot: tmp, twin: g.handler.twin, truthRankIndex: g.handler.truthRankIndex,
            snapshotPath: snapshot, walPath: wal, log: { lines.append($0) })
        if let e = r.replayError { lines.append("replayError: \(e)") }
        g.handler.tickCount = r.tickCount
        return (g, lines)
    }

    /// The state hash: every EXPORT MORTON file (through the verb), GRAPH
    /// INFO, STATUS, the register flags and the back-edge list.
    func observe(_ f: HandlerFixture) throws -> [String: Data] {
        var o: [String: Data] = [:]
        let dir = tmp + "obs_\(UUID().uuidString)"
        let r = f.handler.handle("EXPORT MORTON \(dir)")
        if r.hasPrefix("OK EXPORT") {
            for name in try FileManager.default.contentsOfDirectory(atPath: dir) {
                o["export/" + name] = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + name))
            }
        } else {
            o["export"] = Data(r.utf8)      // a state EXPORT refuses is observed by its refusal
        }
        try? FileManager.default.removeItem(atPath: dir)
        o["GRAPH INFO"] = Data(f.handler.handle("GRAPH INFO").utf8)
        o["STATUS"] = Data(f.handler.handle("STATUS").utf8)
        let e = f.handler.engine
        o["isRegister"] = Data(bytes: e.isRegisterBuf.contents(), count: e.nodeCount)
        o["backEdges"] = Data("\(e.backEdgeSrcs) \(e.backEdgeDsts)".utf8)
        return o
    }

    func diff(_ a: [String: Data], _ b: [String: Data]) -> [String] {
        Set(a.keys).union(b.keys).sorted().filter { a[$0] != b[$0] }
    }

    func walBytes(_ f: HandlerFixture, _ path: String) throws -> Data {
        f.handler.walAppender?.barrier()
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    static func walVersion(_ path: String) -> UInt32? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), d.count >= 8 else { return nil }
        return d[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    // MARK: - Every persistence path round-trips S1–S3

    enum Path: String, CaseIterable {
        case saveLoad = "SAVE->LOAD"
        case saveCompressedLoad = "SAVE COMPRESSED->LOAD"
        case startupRecovery = "DAGDB_STARTUP_LOAD recovery (crash)"
        case rebase = "DUR1 rebase after LOAD (crash)"
        case exportImport = "EXPORT->IMPORT"
        case importReplay = "WAL replay of the logged import (crash)"
        case json = "SAVE JSON->LOAD JSON v2"
        case csv = "SAVE CSV->LOAD CSV v2"
        case backup = "BACKUP INIT->APPEND->RESTORE"
        case compact = "BACKUP COMPACT->RESTORE"
    }

    struct Cell {
        var accepted: Bool
        var reply: String
        var target: HandlerFixture?
        var notes: [String] = []
    }

    /// One persistence path on the graph. `ref` is the never-saved daemon; it
    /// is given the tail where the source took one.
    func persist(_ p: Path, _ gr: Graph, ref: HandlerFixture) throws -> Cell {
        let side = gr.side
        let id = UUID().uuidString
        func fail(_ r: String) -> Cell { Cell(accepted: false, reply: r, target: nil) }
        switch p {
        case .saveLoad, .saveCompressedLoad:
            let src = try daemon(gr)
            let file = tmp + "s_\(id).dags"
            let s = src.handler.handle(p == .saveLoad ? "SAVE \(file)" : "SAVE \(file) COMPRESSED")
            guard s.hasPrefix("OK SAVE") else { return fail(s) }
            let t = try fixture(side: side)
            let l = t.handler.handle("LOAD \(file)")
            return Cell(accepted: l.hasPrefix("OK LOAD"), reply: l, target: t)
        case .startupRecovery:
            let wal = tmp + "w_\(id).wal", snap = tmp + "snap_\(id).dags"
            let src = try daemon(gr, wal: wal, startup: snap)
            let s = src.handler.handle("SAVE \(snap)")
            guard s.hasPrefix("OK SAVE") else { return fail(s) }
            tail(src, gr); tail(ref, gr)
            src.handler.walAppender?.barrier()                  // the in-process kill: the handler is abandoned
            let (t, lines) = try recover(side: side, snapshot: snap, wal: wal)
            return Cell(accepted: true, reply: s, target: t, notes: lines)
        case .rebase:
            let src = try daemon(gr)
            let file = tmp + "r_\(id).dags"
            let s = src.handler.handle("SAVE \(file)")
            guard s.hasPrefix("OK SAVE") else { return fail(s) }
            let wal = tmp + "w_\(id).wal", snap = tmp + "snap_\(id).dags"
            let t0 = try fixture(side: side, wal: wal, startup: snap)
            let l = t0.handler.handle("LOAD \(file)")
            guard l.hasPrefix("OK LOAD"), l.contains("wal_base=") else { return fail(l) }
            tail(t0, gr); tail(ref, gr)
            t0.handler.walAppender?.barrier()
            let (t, lines) = try recover(side: side, snapshot: snap, wal: wal)
            return Cell(accepted: true, reply: l, target: t, notes: lines)
        case .exportImport:
            let src = try daemon(gr)
            let dir = tmp + "x_\(id)"
            let s = src.handler.handle("EXPORT MORTON \(dir)")
            guard s.hasPrefix("OK EXPORT") else { return fail(s) }
            let t = try fixture(side: side)
            let l = t.handler.handle("IMPORT MORTON \(dir)")
            return Cell(accepted: l.hasPrefix("OK IMPORT"), reply: l, target: t)
        case .importReplay:
            let src = try daemon(gr)
            let dir = tmp + "x_\(id)"
            let s = src.handler.handle("EXPORT MORTON \(dir)")
            guard s.hasPrefix("OK EXPORT") else { return fail(s) }
            let wal = tmp + "w_\(id).wal"
            let t0 = try fixture(side: side, wal: wal)
            let v0 = Self.walVersion(wal)
            let l = t0.handler.handle("IMPORT MORTON \(dir)")
            guard l.hasPrefix("OK IMPORT") else { return fail(l) }
            t0.handler.walAppender?.barrier()
            let v1 = Self.walVersion(wal)
            tail(t0, gr); tail(ref, gr)
            t0.handler.walAppender?.barrier()
            try FileManager.default.removeItem(atPath: dir)     // the log alone carries the import
            let (t, lines) = try recover(side: side, snapshot: nil, wal: wal)
            return Cell(accepted: true, reply: l, target: t,
                        notes: ["log version before the import \(v0.map(String.init) ?? "?"), after \(v1.map(String.init) ?? "?")"] + lines)
        case .json:
            let src = try daemon(gr)
            let file = tmp + "j_\(id).json"
            let s = src.handler.handle("SAVE JSON \(file)")
            guard s.hasPrefix("OK SAVE_JSON") else { return fail(s) }
            let t = try fixture(side: side)
            let l = t.handler.handle("LOAD JSON \(file)")
            return Cell(accepted: l.hasPrefix("OK LOAD_JSON"), reply: l, target: t)
        case .csv:
            let src = try daemon(gr)
            let dir = tmp + "c_\(id)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let s = src.handler.handle("SAVE CSV \(dir)")
            guard s.hasPrefix("OK SAVE_CSV") else { return fail(s) }
            let t = try fixture(side: side)
            let l = t.handler.handle("LOAD CSV \(dir)")
            return Cell(accepted: l.hasPrefix("OK LOAD_CSV"), reply: l, target: t)
        case .backup, .compact:
            let src = try daemon(gr)
            let dir = tmp + "b_\(id)"
            let i = src.handler.handle("BACKUP INIT \(dir)")
            guard i.hasPrefix("OK BACKUP_INIT") else { return fail(i) }
            putNeighbors(src, gr.tailNb); ok(src, "SET_NEIGHBORS_BULK")     // S1–S3 brought by a diff
            putNeighbors(ref, gr.tailNb); ok(ref, "SET_NEIGHBORS_BULK")
            let a = src.handler.handle("BACKUP APPEND \(dir)")
            guard a.hasPrefix("OK BACKUP_APPEND") else { return fail(a) }
            if p == .compact {
                let c = src.handler.handle("BACKUP COMPACT \(dir)")
                guard c.hasPrefix("OK BACKUP_COMPACT") else { return fail(c) }
            }
            let t = try fixture(side: side)
            let l = t.handler.handle("BACKUP RESTORE \(dir)")
            return Cell(accepted: l.hasPrefix("OK BACKUP_RESTORE"), reply: l, target: t)
        }
    }

    struct Tally {
        var cells = 0, accepted = 0, equal0 = 0, equal1 = 0, equal7 = 0, equal64 = 0
        var line: String { "cells=\(cells) accepted=\(accepted) hash_equal=\(equal0) tick_sync_equal k=1:\(equal1) k=7:\(equal7) k=64:\(equal64)" }
    }

    func testE71PersistenceAcceptsS1toS3AndTickSyncAfterLoadEqualsTheNeverSavedRun() throws {
        var tally: [Path: Tally] = [:]
        var firstRefusal: [Path: String] = [:]
        let gs = Self.graphs()
        for gr in gs {
            // The source equals its builder: two daemons built alike agree.
            XCTAssertEqual(diff(try observe(try daemon(gr)), try observe(try daemon(gr))), [], gr.name)
            for p in Path.allCases {
                let what = "E7.1 \(p.rawValue) [\(gr.name)]"
                let ref = try daemon(gr)
                let c = try persist(p, gr, ref: ref)
                var t = tally[p] ?? Tally()
                t.cells += 1
                defer { tally[p] = t }
                XCTAssertTrue(c.accepted, "\(what): \(c.reply)")
                guard c.accepted, let tgt = c.target else {
                    if firstRefusal[p] == nil { firstRefusal[p] = c.reply }
                    continue
                }
                t.accepted += 1
                if p == .importReplay {
                    XCTAssertTrue(c.notes.first?.hasSuffix("before the import 3, after 4") == true,
                                  "\(what): the log goes to v4 in place (W-up): \(c.notes.first ?? "")")
                }
                var d = diff(try observe(tgt), try observe(ref))
                XCTAssertEqual(d, [], "\(what): the loaded state differs \(c.notes)")
                if d.isEmpty { t.equal0 += 1 }
                for (k, step) in [(1, 1), (7, 6), (64, 57)] {
                    let a = tgt.handler.handle("TICK_SYNC \(step)"), b = ref.handler.handle("TICK_SYNC \(step)")
                    XCTAssertTrue(a.hasPrefix("OK TICK_SYNC") && b.hasPrefix("OK TICK_SYNC"), "\(what): \(a) | \(b)")
                    d = diff(try observe(tgt), try observe(ref))
                    XCTAssertEqual(d, [], "\(what): TICK_SYNC to \(k) differs")
                    if d.isEmpty {
                        switch k { case 1: t.equal1 += 1; case 7: t.equal7 += 1; default: t.equal64 += 1 }
                    }
                }
            }
        }
        for p in Path.allCases {
            print("E7.1 \(p.rawValue): \(tally[p]?.line ?? "-")" + (firstRefusal[p].map { " first refusal: \($0)" } ?? ""))
        }
        print("E7.1 graphs=\(gs.count) paths=\(Path.allCases.count)")
    }

    // MARK: - Rank-mode TICK refuses S2/S3 after every loader

    /// The loaders of the persistence round trip, each from a source daemon holding `gr`, into `t`
    /// (a running daemon); the recovery paths give a fresh daemon instead.
    func load(_ p: Path, _ gr: Graph, into t: HandlerFixture) throws -> (String, HandlerFixture) {
        let id = UUID().uuidString
        let src = try daemon(gr)
        switch p {
        case .saveLoad, .saveCompressedLoad, .rebase:
            let file = tmp + "l_\(id).dags"
            let s = src.handler.handle(p == .saveCompressedLoad ? "SAVE \(file) COMPRESSED" : "SAVE \(file)")
            guard s.hasPrefix("OK") else { return (s, t) }
            return (t.handler.handle("LOAD \(file)"), t)
        case .exportImport:
            let dir = tmp + "l_\(id)"
            _ = src.handler.handle("EXPORT MORTON \(dir)")
            return (t.handler.handle("IMPORT MORTON \(dir)"), t)
        case .json:
            let file = tmp + "l_\(id).json"
            _ = src.handler.handle("SAVE JSON \(file)")
            return (t.handler.handle("LOAD JSON \(file)"), t)
        case .csv:
            let dir = tmp + "l_\(id)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            _ = src.handler.handle("SAVE CSV \(dir)")
            return (t.handler.handle("LOAD CSV \(dir)"), t)
        case .backup, .compact:
            let dir = tmp + "l_\(id)"
            _ = src.handler.handle("BACKUP INIT \(dir)")
            if p == .compact { _ = src.handler.handle("BACKUP APPEND \(dir)"); _ = src.handler.handle("BACKUP COMPACT \(dir)") }
            return (t.handler.handle("BACKUP RESTORE \(dir)"), t)
        case .startupRecovery:
            let wal = tmp + "l_\(id).wal", snap = tmp + "l_\(id).dags"
            let s2 = try daemon(gr, wal: wal, startup: snap)
            let s = s2.handler.handle("SAVE \(snap)")
            guard s.hasPrefix("OK") else { return (s, t) }
            s2.handler.walAppender?.barrier()
            let (g, lines) = try recover(side: gr.side, snapshot: snap, wal: wal)
            return ("OK recovered " + lines.joined(separator: " | "), g)
        case .importReplay:
            let dir = tmp + "l_\(id)", wal = tmp + "l_\(id).wal"
            _ = src.handler.handle("EXPORT MORTON \(dir)")
            let t0 = try fixture(side: gr.side, wal: wal)
            let l = t0.handler.handle("IMPORT MORTON \(dir)")
            guard l.hasPrefix("OK") else { return (l, t) }
            t0.handler.walAppender?.barrier()
            let (g, lines) = try recover(side: gr.side, snapshot: nil, wal: wal)
            return ("OK recovered " + lines.joined(separator: " | "), g)
        }
    }

    func testE73RankModeTickStillRefusesS2AndS3AfterEveryLoader() throws {
        let side = 8
        let legal = Self.slotGraph(side: side, seed: 0xE7_3000, shapes: [], ternary: false)
        var cells = 0, loaded = 0, tickRefused = 0, untilRefused = 0, unchanged = 0, syncRuns = 0
        for shape in [Shape.s2, .s3] {
            let gr = Self.slotGraph(side: side, seed: 0xE7_3100 &+ (shape == .s2 ? 1 : 2), shapes: [shape], ternary: false)
            // The single verbs' words: TICK and TICK UNTIL_STABLE on a never-saved daemon holding the graph.
            let fresh = try daemon(gr)
            let wantTick = fresh.handler.handle("TICK 3")
            let wantUntil = fresh.handler.handle("TICK UNTIL_STABLE")
            XCTAssertTrue(wantTick.hasPrefix("ERROR invalid_graph: rank-mode TICK refused, validation: "), wantTick)
            XCTAssertEqual(wantTick, wantUntil)
            for p in Path.allCases {
                cells += 1
                let what = "E7.3 \(p.rawValue) [\(shape.rawValue)]"
                let t = try daemon(legal)
                XCTAssertTrue(t.handler.handle("TICK 1").hasPrefix("OK TICK 1"), "\(what): the legal graph ticks")
                XCTAssertTrue(t.handler.dagVerdict.checked && t.handler.dagVerdict.violation == nil, "\(what): the cached verdict is valid")
                let (reply, d) = try load(p, gr, into: t)
                XCTAssertTrue(reply.hasPrefix("OK"), "\(what): \(reply)")
                guard reply.hasPrefix("OK") else { continue }
                loaded += 1
                let truth0 = d.handler.engine.readTruthStates()
                let status0 = d.handler.handle("STATUS")
                let a = d.handler.handle("TICK 3")
                XCTAssertEqual(a, wantTick, what)
                if a == wantTick { tickRefused += 1 }
                let b = d.handler.handle("TICK UNTIL_STABLE")
                XCTAssertEqual(b, wantUntil, what)
                if b == wantUntil { untilRefused += 1 }
                let same = d.handler.engine.readTruthStates() == truth0 && d.handler.handle("STATUS") == status0
                XCTAssertTrue(same, "\(what): a refused TICK changed truth or the tick count")
                if same { unchanged += 1 }
                let s = d.handler.handle("TICK_SYNC 2")
                XCTAssertTrue(s.hasPrefix("OK TICK_SYNC 2"), "\(what): \(s)")
                if s.hasPrefix("OK TICK_SYNC") { syncRuns += 1 }
            }
        }
        print("E7.3 cells=\(cells) loaded=\(loaded) tick_refused_by_name=\(tickRefused) until_stable_refused=\(untilRefused) truth_and_ticks_unchanged=\(unchanged) tick_sync_runs=\(syncRuns)")

        // An S1-only graph: rank TICK runs after every loader and equals the CPU reference.
        let s1 = Self.slotGraph(side: side, seed: 0xE7_3300, shapes: [.s1], ternary: true)
        var ran = 0, equal = 0
        for p in Path.allCases {
            let t = try daemon(legal)
            XCTAssertTrue(t.handler.handle("TICK 1").hasPrefix("OK"))
            let (reply, d) = try load(p, s1, into: t)
            XCTAssertTrue(reply.hasPrefix("OK"), "E7.3 S1 \(p.rawValue): \(reply)")
            guard reply.hasPrefix("OK") else { continue }
            var g = Self.refGraph(d.handler.engine)
            let t0 = d.handler.tickCount
            let r = d.handler.handle("TICK 3")
            XCTAssertTrue(r.hasPrefix("OK TICK 3"), "E7.3 S1 \(p.rawValue): \(r)")
            if r.hasPrefix("OK TICK 3") { ran += 1 }
            let colorOf = Self.colorOf(d.handler.engine)
            for j in 0..<3 { TernaryReference.tickRank(&g, tickNumber: t0 &+ UInt32(j), colorOf: colorOf, colorCount: 7) }
            XCTAssertEqual(d.handler.engine.readTruthStates(), g.truth, "E7.3 S1 \(p.rawValue): rank TICK against the CPU reference")
            if d.handler.engine.readTruthStates() == g.truth { equal += 1 }
        }
        print("E7.3 S1-only: rank TICK ran=\(ran) of \(Path.allCases.count), equal to the CPU reference=\(equal)")
    }

    static func colorOf(_ e: DagDBEngine) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: e.nodeCount)
        for (k, group) in e.grid.colorGroups.enumerated() { for i in group { c[Int(i)] = UInt8(k) } }
        return c
    }

    /// The CPU reference's graph, read from the engine's lanes.
    static func refGraph(_ e: DagDBEngine) -> TernaryReference.Graph {
        let n = e.nodeCount
        func arr<T>(_ b: MTLBuffer, _ c: Int) -> [T] {
            Array(UnsafeBufferPointer(start: b.contents().bindMemory(to: T.self, capacity: c), count: c))
        }
        let lv = e.ternaryLaneView
        return TernaryReference.Graph(
            truth: arr(e.truthStateBuf, n), rank: arr(e.rankBuf, n),
            lutLow: arr(e.lut6LowBuf, n), lutHigh: arr(e.lut6HighBuf, n),
            neighbors: arr(e.neighborsBuf, n * 6), isRegister: arr(e.isRegisterBuf, n),
            edgeWeights: arr(e.edgeWeightsBuf, n * 6),
            mode: lv.map { Array(UnsafeBufferPointer(start: $0.mode, count: n)) } ?? [UInt8](repeating: 0, count: n),
            ttableId: lv.map { Array(UnsafeBufferPointer(start: $0.ttableId, count: n)) } ?? [UInt16](repeating: 0, count: n),
            thrLo: lv.map { Array(UnsafeBufferPointer(start: $0.thrLo, count: n)) } ?? [Float](repeating: 0, count: n),
            thrHi: lv.map { Array(UnsafeBufferPointer(start: $0.thrHi, count: n)) } ?? [Float](repeating: 0, count: n),
            tables: e.libraryBytes(), backEdgeSrcs: e.backEdgeSrcs, backEdgeDsts: e.backEdgeDsts)
    }
}
