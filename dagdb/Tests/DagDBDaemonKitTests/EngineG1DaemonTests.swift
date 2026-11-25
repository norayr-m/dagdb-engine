import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// `SET_LUTS NODES|RANK <lo>-<hi> FILL <hex64>` and
/// `SET_LUTS NODES|RANK <lo>-<hi> MAP [MASK <hex64>] <from>=<to> …`.
///
/// Equivalence. After EVERY verb the LUT lane (both u32 buffers, every
/// node) equals a twin's after SET_LUTS_BULK with the equivalent vector — the
/// vector computed by this file's own reference (`reference`), from the
/// twin's lane before the verb:
///   (i)  the voxel morphology layout A at 8³, 16³, 32³, 64³ in-process, binary
///        and ternary, in the morphology driver's order (surface — seeded on the
///        first pass, seed + surface on the
///        second —, closing 1–3, cavity), the O tags in the import LUTs (inside
///        bit 62, outside bit 61), every phase as the three lines; after the
///        three lines the lane also equals the phase's whole vector as the voxel
///        client computes it; the
///        replies of every TICK and TICK UNTIL_STABLE equal; the EXPORT MORTON
///        files (16) byte-equal after every phase and after every flood;
///   (ii) 300 seeds of random selections on random graphs (sides 8, 40, 64,
///        128; ranks few/many/wide/huge/chain, a bad edge in some, ternary
///        modes, registers, Loom bytes): id ranges and rank ranges (one node,
///        the whole lane, a range ending on the last id, rank lists and the
///        rank lane, a rank holding no node), random lanes, FILL and MAP of
///        1–16 pairs with and without masks, keys matching no node, keys
///        taken from registers and ternary nodes, a pair whose `to` is another
///        pair's `from`, refusals; SET RANK, SET_RANKS_BULK, TICK, TICK_SYNC,
///        UNTIL_STABLE between them. Three handlers: G (the GPU; the inline
///        shader source on every fifth seed), C (the CPU twin by the seam), V
///        (SET_LUTS_BULK of the reference's vector).
/// The controls (each one line, run in the worktree, restored): (1) MAP
/// applied pair by pair (chaining) — the `to == from` case; (2) the grid
/// rounded down to whole threadgroups — B's six nodes; (3) the mask ignored —
/// the voxel phases; (4) the rank lists without the staleness check — a SET
/// RANK between two FILLs of that rank (`testG1_1RankListStaleness`).
///
/// After SET_LUTS the DAG verdict is kept (`dagVerdictCheckCount`), the
/// frontier index is not rebuilt (`frontierIndexBuildCount`), the latch plan is
/// kept (`latchPlanBuildCount`), the (truth, rank) index is not dirtied.
///
/// WAL: the record's size by the log's size delta; replay of IMPORT
/// MORTON + 20 random verbs (SET RANK among them) reproduces the LUT lane,
/// against the live engine and against the reference; a record whose
/// selector is out of range for the replayed node count is skipped, counted
/// and named.
///
/// On the code before these verbs the file does not compile: no `SET_LUTS` verb, no
/// `lastSetLutsOnGPU` seam, no `dagVerdictCheckCount`.
final class EngineG1DaemonTests: XCTestCase {

    typealias Rng = EngineE1DaemonTests.Rng
    typealias Sel = DagDBEngine.LutSelection
    typealias Op = DagDBEngine.LutOp
    typealias Pair = DagDBEngine.LutPair

    private var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "engine-g1-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - A handler over a given engine (HandlerFixture's construction)

    final class H {
        let handler: DagDBCommandHandler
        let shm: UnsafeMutableRawPointer
        let n: Int
        var e: DagDBEngine { handler.engine }

        init(_ engine: DagDBEngine, side: Int, maxRank: Int, wal: DagDBWAL.Appender? = nil) {
            n = engine.nodeCount
            let bytes = 8 + n * 24
            shm = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
            shm.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
            handler = DagDBCommandHandler(
                engine: engine, grid: engine.grid, nodeCount: n, width: side, height: side, maxRank: maxRank,
                tickCount: 0, walAppender: wal, sessionManager: DagDBReaderSessionManager(),
                truthRankIndex: TruthRankIndex(), shmBase: shm, resultRowSize: 24,
                dataRoot: nil, dagdbEnv: nil)
        }
        deinit { shm.deallocate() }

        func cmd(_ s: String) -> String { handler.handle(s) }

        func put<T>(_ v: [T], count: Int, verb: SHM1Verb) {
            v.withUnsafeBytes { shm.advanced(by: 8).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            shm1Header(shm, count: count, verb: verb)
        }
        func lutsBulk(_ v: [UInt64]) -> String { put(v, count: v.count, verb: .setLutsBulk); return cmd("SET_LUTS_BULK") }
        func rows(_ verb: String, _ r: [(UInt32, UInt32)]) -> String {
            let h = shm.bindMemory(to: UInt32.self, capacity: 2 + 2 * r.count)
            h[0] = UInt32(r.count); h[1] = shm1Word1(.named(verb))
            for (i, x) in r.enumerated() { h[2 + 2 * i] = x.0; h[3 + 2 * i] = x.1 }
            return cmd(verb)
        }

        func lane() -> [UInt64] {
            let lo = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
            let hi = e.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
            return (0..<n).map { UInt64(hi[$0]) << 32 | UInt64(lo[$0]) }
        }
        func ranks() -> [UInt64] { e.readRanks() }
    }

    /// Both u32 LUT buffers of two engines, every node: the count of nodes that differ.
    static func laneDiff(_ a: DagDBEngine, _ b: DagDBEngine) -> Int {
        let n = a.nodeCount
        let la = a.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let ha = a.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let lb = b.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let hb = b.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        var d = 0
        for i in 0..<n where la[i] != lb[i] || ha[i] != hb[i] { d += 1 }
        return d
    }

    static func truthDiff(_ a: DagDBEngine, _ b: DagDBEngine) -> Int {
        let n = a.nodeCount
        let pa = a.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let pb = b.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        var d = 0
        for i in 0..<n where pa[i] != pb[i] { d += 1 }
        return d
    }

    static func strip(_ r: String) -> String {
        r.split(separator: " ").filter { !$0.hasPrefix("elapsed=") }.joined(separator: " ")
    }

    // MARK: - The reference (this file's own; never the engine's code)

    /// One verb on `lane`: the selection (ids lo…hi, or every node whose rank
    /// is in lo…hi), then FILL, or MAP — a node whose value before the verb,
    /// ANDed with the mask, equals a pair's `from` gets that pair's `to`
    /// (keys are distinct, so at most one pair matches; no chaining).
    /// Returns (nodes in the selection, nodes written).
    @discardableResult
    static func reference(_ lane: inout [UInt64], ranks: [UInt64], _ sel: Sel, _ op: Op) -> (k: Int, w: Int) {
        var written: [Int] = []
        return reference(&lane, ranks: ranks, sel, op, written: &written)
    }

    static func reference(_ lane: inout [UInt64], ranks: [UInt64], _ sel: Sel, _ op: Op,
                          written: inout [Int]) -> (k: Int, w: Int) {
        var ids: [Int] = []
        switch sel {
        case let .nodes(lo, hi): ids = Array(Int(lo)...Int(hi))
        case let .rank(lo, hi): ids = ranks.indices.filter { ranks[$0] >= lo && ranks[$0] <= hi }
        }
        written = []
        for i in ids {
            switch op {
            case .fill(let v):
                lane[i] = v; written.append(i)
            case let .map(mask, pairs):
                let old = lane[i]
                for p in pairs where (old & mask) == p.from { lane[i] = p.to; written.append(i); break }
            }
        }
        return (ids.count, written.count)
    }

    /// The refusal's category the verb's rules give, or nil:
    /// the selection first (lo > hi, then an id past the lane),
    /// then MAP's pair count (1…16), a key with a bit outside the mask, two
    /// equal keys.
    static func expectedRefusal(_ sel: Sel, _ op: Op, n: Int) -> String? {
        switch sel {
        case let .nodes(lo, hi):
            if lo > hi { return "ERROR out_of_range: range \(lo)-\(hi) is empty (lo > hi)" }
            if hi >= UInt64(n) { return "ERROR out_of_range: node \(hi) not in 0..<\(n)" }
        case let .rank(lo, hi):
            if lo > hi { return "ERROR out_of_range: range \(lo)-\(hi) is empty (lo > hi)" }
        }
        if case let .map(mask, pairs) = op {
            if pairs.isEmpty || pairs.count > 16 { return "ERROR out_of_range: SET_LUTS MAP pairs \(pairs.count) not in 1...16" }
            for (j, p) in pairs.enumerated() where p.from & ~mask != 0 { return "ERROR bad_value: SET_LUTS MAP pair \(j): from" }
            for j in pairs.indices { for i in 0..<j where pairs[i].from == pairs[j].from { return "ERROR bad_value: SET_LUTS MAP pairs \(i) and \(j)" } }
        }
        return nil
    }

    static func hex(_ v: UInt64, _ style: Int) -> String {
        switch style % 3 {
        case 0: return "0x" + String(v, radix: 16, uppercase: true)
        case 1: return "0X" + String(v, radix: 16, uppercase: false)
        default: return String(v, radix: 16, uppercase: style % 2 == 0)
        }
    }

    static func line(_ sel: Sel, _ op: Op, style: Int = 0) -> String {
        var s = "SET_LUTS \(sel)"
        switch op {
        case .fill(let v): s += " FILL \(hex(v, style))"
        case let .map(mask, pairs):
            s += " MAP"
            if mask != ~0 || style % 4 == 3 { s += " MASK \(hex(mask, style))" }
            for p in pairs { s += " \(hex(p.from, style + 1))=\(hex(p.to, style))" }
        }
        return style % 5 == 4 ? s.lowercased() : s
    }

    // MARK: - The voxel morphology layout A (EngineF2DaemonTests.VoxelA, ported), with the O tags

    struct VoxelA {
        let n: Int, N: Int, L: Int
        let levels: [Int], levelStarts: [Int]
        let side: Int
        var V0: Int { 0 }
        var A0: Int { N }
        var O0: Int { 2 * N }
        var B0: Int { 3 * N }
        var nodeCount: Int { side * side }
        var maxRank: Int { L + 3 }
        var rankV: Int { L + 2 }
        var rankA: Int { L + 1 }
        var rankO: Int { L }

        init(n: Int) {
            self.n = n; N = n * n * n
            var lv = [(N + 2) / 3]
            while lv.last! > 1 { lv.append((lv.last! + 5) / 6) }
            levels = lv; L = lv.count
            var st: [Int] = [], s = 3 * N + 6
            for sz in lv { st.append(s); s += sz }
            levelStarts = st
            var q = Int(Double(s - 1).squareRoot())
            while q * q > s - 1 { q -= 1 }
            while (q + 1) * (q + 1) <= s - 1 { q += 1 }
            side = q + 1
        }

        func ranks() -> [UInt64] {
            var r = [UInt64](repeating: 0, count: nodeCount)
            for v in 0..<N { r[V0 + v] = UInt64(L + 2); r[A0 + v] = UInt64(L + 1); r[O0 + v] = UInt64(L) }
            for d in 0..<6 { r[B0 + d] = UInt64(L + 2) }
            for (j, (st, sz)) in zip(levelStarts, levels).enumerated() {
                for i in st..<(st + sz) { r[i] = UInt64(L - 1 - j) }
            }
            return r
        }

        func neighbors() -> [Int32] {
            var nb = [Int32](repeating: -1, count: nodeCount * 6)
            for v in 0..<N {
                let z = v / (n * n), y = (v / n) % n, x = v % n
                let moves = [(x, -1, 0), (x, 1, n - 1), (y, -n, 0), (y, n, n - 1), (z, -n * n, 0), (z, n * n, n - 1)]
                for (d, (coord, step, lim)) in moves.enumerated() {
                    nb[(A0 + v) * 6 + d] = Int32(coord != lim ? V0 + v + step : B0 + d)
                }
                nb[(O0 + v) * 6 + 0] = Int32(V0 + v)
                nb[(O0 + v) * 6 + 1] = Int32(A0 + v)
            }
            let st0 = levelStarts[0]
            for i in 0..<levels[0] {
                for p in 0..<3 where 3 * i + p < N {
                    nb[(st0 + i) * 6 + 2 * p] = Int32(O0 + 3 * i + p)
                    nb[(st0 + i) * 6 + 2 * p + 1] = Int32(V0 + 3 * i + p)
                }
            }
            for j in 1..<L {
                for i in 0..<levels[j] {
                    for p in 0..<6 where 6 * i + p < levels[j - 1] {
                        nb[(levelStarts[j] + i) * 6 + p] = Int32(levelStarts[j - 1] + 6 * i + p)
                    }
                }
            }
            return nb
        }

        static let c0: UInt64 = 0, c1: UInt64 = ~0
        static let or6: UInt64 = 0xFFFF_FFFF_FFFF_FFFE, and6: UInt64 = 0x8000_0000_0000_0000
        static var xor3: UInt64 {
            var v: UInt64 = 0
            for i in 0..<64 {
                let b = (0..<6).map { (i >> $0) & 1 }
                if (b[0] ^ b[1]) | (b[2] ^ b[3]) | (b[4] ^ b[5]) != 0 { v |= 1 << UInt64(i) }
            }
            return v
        }
        /// The O classes: inside voxels carry bit 62, outside bit 61,
        /// in bits the O rule never reads (it reads idx = V + 2A ∈ 0…3).
        static let tagIn: UInt64 = 1 << 62, tagOut: UInt64 = 1 << 61
        static let mask: UInt64 = 0x6000_0000_0000_0000

        /// A's LUT, O's rule inside and outside (tags not included), the border.
        static func constants(_ phase: String) -> (a: UInt64, oIn: UInt64, oOut: UInt64, border: UInt64) {
            switch phase {
            case "seed":    return (c0, 0b1111, 0, c0)          // the field constant: 1 over idx 0…3 inside
            case "surface": return (and6, 0b0010, 0b0010, c0)
            case "dilate":  return (or6, 0b1110, 0b1110, c0)
            case "erode":   return (and6, 0b1000, 0b1000, c0)
            case "flood":   return (or6, 0, 0b1110, c1)
            case "extract": return (c0, 0, 0b0101, c0)
            default:        return (c0, 0, 0, c0)               // "zero"
            }
        }

        /// The phase's whole vector (the vector path), tags included.
        func luts(_ phase: String, field: [Bool]) -> [UInt64] {
            let c = Self.constants(phase)
            var lut = [UInt64](repeating: 0, count: nodeCount)
            for v in 0..<N {
                lut[A0 + v] = c.a
                lut[O0 + v] = field[v] ? Self.tagIn | c.oIn : Self.tagOut | c.oOut
            }
            for d in 0..<6 { lut[B0 + d] = c.border }
            for (j, (st, sz)) in zip(levelStarts, levels).enumerated() {
                for i in st..<(st + sz) { lut[i] = j == 0 ? Self.xor3 : Self.or6 }
            }
            return lut
        }

        /// The phase as the three verbs.
        func verbs(_ phase: String) -> [(Sel, Op)] {
            let c = Self.constants(phase)
            return [(.rank(UInt64(rankA), UInt64(rankA)), .fill(c.a)),
                    (.rank(UInt64(rankO), UInt64(rankO)),
                     .map(mask: Self.mask, pairs: [Pair(from: Self.tagIn, to: Self.tagIn | c.oIn),
                                                   Pair(from: Self.tagOut, to: Self.tagOut | c.oOut)])),
                    (.nodes(UInt64(B0), UInt64(B0 + 5)), .fill(c.border))]
        }

        func field(seed: UInt64) -> [Bool] {
            var g = Rng(s: seed)
            var f = [Bool](repeating: false, count: N)
            let c = Double(n - 1) / 2
            for v in 0..<N {
                let z = Double(v / (n * n)) - c, y = Double((v / n) % n) - c, x = Double(v % n) - c
                let r = (x * x + y * y + z * z).squareRoot()
                f[v] = r < c * 0.8 && !(r < c * 0.3) && g.below(17) != 0
            }
            return f
        }

        func makeEngine(field: [Bool], ternary: Bool) throws -> DagDBEngine {
            let grid = try HexGrid(width: side, height: side)
            var st = DagDBState(width: side, height: side)
            st.rank = ranks()
            for v in 0..<N { st.truthState[V0 + v] = field[v] ? 1 : 0 }
            let e = try DagDBEngine(grid: grid, state: st, maxRank: maxRank)
            let nb = neighbors()
            let p = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)
            for i in 0..<(nodeCount * 6) { p[i] = nb[i] }
            let lut = luts("surface", field: field)                  // the import LUTs, tags in them
            let lo = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
            let hi = e.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
            for i in 0..<nodeCount { lo[i] = UInt32(lut[i] & 0xFFFF_FFFF); hi[i] = UInt32(lut[i] >> 32) }
            for v in 0..<N { try e.addBackEdge(src: UInt32(O0 + v), dst: UInt32(V0 + v)) }
            if ternary {
                try e.writeTables(first: 0, bytes: try TernaryReference.presetTable(.tmax, k: 6)
                                                   + TernaryReference.presetTable(.tsum, k: 6))
                let mode = e.modePtr, tid = e.ttableIdPtr, tlo = e.thrLoPtr, thi = e.thrHiPtr
                for v in stride(from: 0, to: N, by: 3) {
                    mode[A0 + v] = v % 2 == 0 ? 6 : 2
                    tlo[A0 + v] = -0.5; thi[A0 + v] = 0.5
                }
                for j in 1..<L {
                    for i in levelStarts[j]..<(levelStarts[j] + levels[j]) {
                        mode[i] = i % 4 == 0 ? 5 : 1
                        tid[i] = UInt16(i % 2)
                    }
                }
            }
            return e
        }
    }

    /// The EXPORT MORTON files of both handlers, compared byte for byte.
    func exportsEqual(_ g: H, _ v: H, _ label: String) throws -> Int {
        let dg = tmp + "xg", dv = tmp + "xv"
        XCTAssertTrue(g.cmd("EXPORT MORTON \(dg)").hasPrefix("OK EXPORT"), label)
        XCTAssertTrue(v.cmd("EXPORT MORTON \(dv)").hasPrefix("OK EXPORT"), label)
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: dg).sorted()
        XCTAssertEqual(names, try fm.contentsOfDirectory(atPath: dv).sorted(), label)
        XCTAssertEqual(names.count, 16, "\(label): the 16 export files")
        var unequal = 0
        for f in names {
            let a = try Data(contentsOf: URL(fileURLWithPath: "\(dg)/\(f)"))
            let b = try Data(contentsOf: URL(fileURLWithPath: "\(dv)/\(f)"))
            if a != b { unequal += 1 }
            XCTAssertEqual(a, b, "\(label): \(f)")
        }
        try fm.removeItem(atPath: dg); try fm.removeItem(atPath: dv)
        return unequal
    }

    struct VoxTally {
        var cells = 0, verbs = 0, laneMismatchVerbs = 0, phaseVectorMismatches = 0, replyMismatches = 0
        var exports = 0, exportMismatches = 0, listVerbs = 0, laneVerbs = 0, rangeVerbs = 0, gpuVerbs = 0
        var truthStates = Set<Int>()
        var line: String {
            "cells \(cells), verbs \(verbs) (rank list \(listVerbs), rank lane \(laneVerbs), id range \(rangeVerbs); "
                + "on the GPU \(gpuVerbs)), lane-mismatching verbs \(laneMismatchVerbs), phase-vector mismatches "
                + "\(phaseVectorMismatches), tick-reply mismatches \(replyMismatches), export checks \(exports) "
                + "(unequal \(exportMismatches)), distinct truth states \(truthStates.count)"
        }
    }

    /// One voxel phase: on G the three lines, each followed on V by the
    /// reference's vector of the same verb; the lanes compared after every
    /// verb; after the three, both lanes equal the phase's whole vector.
    func phase(_ lay: VoxelA, _ ph: String, field: [Bool], _ g: H, _ v: H, _ t: inout VoxTally, _ label: String) {
        let ranks = lay.ranks()
        for (k, (sel, op)) in lay.verbs(ph).enumerated() {
            let r = g.cmd(Self.line(sel, op, style: k))
            var lane = v.lane()
            let (kk, ww) = Self.reference(&lane, ranks: ranks, sel, op)
            XCTAssertEqual(r, "OK SET_LUTS nodes=\(kk) written=\(ww)", "\(label) \(ph) verb \(k)")
            XCTAssertEqual(v.lutsBulk(lane), "OK SET_LUTS_BULK nodes=\(lay.nodeCount)")
            let d = Self.laneDiff(g.e, v.e)
            t.verbs += 1
            if d != 0 { t.laneMismatchVerbs += 1 }
            XCTAssertEqual(d, 0, "\(label) \(ph) verb \(k): the LUT lane against the vector")
            XCTAssertTrue(g.e.lastSetLutsOnGPU, "\(label) \(ph) verb \(k): on the GPU")
            if g.e.lastSetLutsOnGPU { t.gpuVerbs += 1 }
            switch g.e.lastSetLutsPath {
            case .rankList?: t.listVerbs += 1
            case .rankLane?: t.laneVerbs += 1
            case .range?: t.rangeVerbs += 1
            case nil: break
            }
            if k == 1 { XCTAssertEqual(ww, lay.N, "\(label) \(ph): MAP writes every O node (both classes)") }
            if k == 2 { XCTAssertEqual(kk, 6, "\(label) \(ph): B is six nodes") }
        }
        let want = lay.luts(ph, field: field)
        if g.lane() != want || v.lane() != want { t.phaseVectorMismatches += 1 }
        XCTAssertEqual(g.lane(), want, "\(label) \(ph): the three lines leave the phase's vector")
    }

    func voxelCell(n: Int, ternary: Bool, _ t: inout VoxTally) throws {
        let lay = VoxelA(n: n)
        let field = lay.field(seed: 0x61_0000 &+ UInt64(n))
        let g = H(try lay.makeEngine(field: field, ternary: ternary), side: lay.side, maxRank: lay.maxRank)
        let v = H(try lay.makeEngine(field: field, ternary: ternary), side: lay.side, maxRank: lay.maxRank)
        XCTAssertNil(DagDBSnapshot.rankOrderViolation(engine: g.e, nodeCount: g.e.nodeCount))
        XCTAssertEqual(g.e.nonBinaryNodeCount > 0, ternary)
        let label = "voxel layout A n=\(n) ternary=\(ternary)"
        for pass in 0..<2 {
            var ops: [(String, [(String, String)])] = []
            ops.append(("surface", pass == 0 ? [("surface", "TICK 1")] : [("seed", "TICK 1"), ("surface", "TICK 1")]))
            for k in 1...3 { ops.append(("closing\(k)", [("seed", "TICK 1"), ("dilate", "TICK \(k)"), ("erode", "TICK \(k)")])) }
            ops.append(("cavity", [("zero", "TICK 1"), ("flood", "TICK UNTIL_STABLE"), ("extract", "TICK 1")]))
            for (op, phases) in ops {
                for (ph, tick) in phases {
                    let pl = "\(label) pass \(pass) \(op)"
                    phase(lay, ph, field: field, g, v, &t, pl)
                    let rg = g.cmd(tick), rv = v.cmd(tick)
                    XCTAssertTrue(rg.hasPrefix("OK TICK"), "\(pl) \(ph): \(rg)")
                    if Self.strip(rg) != Self.strip(rv) { t.replyMismatches += 1 }
                    XCTAssertEqual(Self.strip(rg), Self.strip(rv), "\(pl) \(ph)")
                    if tick.hasPrefix("TICK UNTIL_STABLE") { XCTAssertTrue(rg.hasPrefix("OK TICK UNTIL_STABLE stable"), rg) }
                    t.exports += 1
                    t.exportMismatches += try exportsEqual(g, v, "\(pl) \(ph)")
                    t.truthStates.insert(g.e.readTruthStates().hashValue)
                }
            }
        }
        t.cells += 1
    }

    /// Equivalence (i), the voxel layout A at 8³ and 16³ (binary and ternary).
    func testG1_1VoxelLayoutASmall() throws {
        var t = VoxTally()
        for n in [8, 16] { for ternary in [false, true] { try voxelCell(n: n, ternary: ternary, &t) } }
        print("G1.1 (i) voxel layout A 8³/16³: " + t.line)
        XCTAssertEqual(t.cells, 4)
        XCTAssertGreaterThan(t.listVerbs, 0); XCTAssertGreaterThan(t.laneVerbs, 0); XCTAssertGreaterThan(t.rangeVerbs, 0)
    }

    /// Equivalence (i), the voxel layout A at 32³ and 64³ (binary and ternary).
    func testG1_1VoxelLayoutALarge() throws {
        var t = VoxTally()
        for n in [32, 64] { for ternary in [false, true] { try voxelCell(n: n, ternary: ternary, &t) } }
        print("G1.1 (i) voxel layout A 32³/64³: " + t.line)
        XCTAssertEqual(t.cells, 4)
    }

    // MARK: - Equivalence (ii): random selections on random graphs

    struct FuzzTally {
        var seeds = 0, verbs = 0, refused = 0, laneMismatchVerbs = 0, cpuMismatchVerbs = 0, replyMismatches = 0
        var fills = 0, maps = 0, masked = 0, pairsMax = 0, chainHazards = 0, keysNoNode = 0
        var writtenRegisters = 0, writtenTernary = 0, listPath = 0, lanePath = 0, rangePath = 0, emptySel = 0
        var wholeLane = 0, lastId = 0, oneNode = 0, inlineSeeds = 0, ticks = 0, rankWrites = 0, bulkLanes = 0
        var tickMismatches = 0
        var line: String {
            "seeds \(seeds) (inline shader \(inlineSeeds)), verbs \(verbs) (refused \(refused); FILL \(fills), "
                + "MAP \(maps) (masked \(masked), up to \(pairsMax) pairs, to==from hazards \(chainHazards), keys "
                + "matching no node \(keysNoNode)); paths: rank list \(listPath), rank lane \(lanePath), id range "
                + "\(rangePath); empty selections \(emptySel), whole lane \(wholeLane), ending on the last id \(lastId), "
                + "one node \(oneNode); written on registers \(writtenRegisters), on ternary nodes \(writtenTernary)); "
                + "lane-mismatching verbs G/V \(laneMismatchVerbs), C/V \(cpuMismatchVerbs), reply mismatches "
                + "\(replyMismatches); between: ticks \(ticks) (truth mismatches \(tickMismatches)), rank writes "
                + "\(rankWrites), random lanes \(bulkLanes)"
        }
    }

    /// fuzz.py's graph (verify_e3, ported): ranks by shape, slots from
    /// strictly higher ranks (a bad edge in 12 %), a LUT lane with repeats,
    /// truth with Loom bytes, ternary modes in 60 %, registers.
    func fuzzGraph(_ hs: [H], side: Int, rng: inout Rng) -> (ranks: [UInt64], registers: Set<Int>, ternary: Set<Int>) {
        let N = side * side
        let shape = rng.below(5)
        let R = min([3, 14, 40, N - 1, 200][shape], N - 1)      // ranks below N (SET_RANKS_BULK's door)
        var ranks = [UInt64](repeating: 0, count: N)
        for i in 0..<N {
            ranks[i] = shape == 3 ? UInt64([0, 1, 2, rng.below(N)][rng.below(4)]) : UInt64(rng.below(R))
        }
        var byRank: [UInt64: [Int]] = [:]
        for i in 0..<N { byRank[ranks[i], default: []].append(i) }
        let sorted = byRank.keys.sorted()
        var nb = [Int32](repeating: -1, count: N * 6)
        for i in 0..<N {
            let k = [0, 1, 2, 3, 6, 6, 6][rng.below(7)]
            let higher = sorted.filter { $0 > ranks[i] }
            guard !higher.isEmpty else { continue }
            var used = Set<Int32>()
            for d in 0..<k {
                let rr = rng.below(10) < 7 ? higher[rng.below(min(6, higher.count))] : higher[rng.below(higher.count)]
                let bucket = byRank[rr]!
                let c = Int32(bucket[rng.below(bucket.count)])
                if used.insert(c).inserted { nb[i * 6 + d] = c }
            }
        }
        if rng.below(100) < 12 {                      // a same-rank or lower-rank edge
            let i = rng.below(N)
            nb[i * 6 + rng.below(6)] = Int32(byRank[ranks[i]]!.filter { $0 != i }.first ?? i)
        }
        // A lane with repeats (MAP keys then match), and wholly random words.
        let palette = (0..<8).map { _ in rng.next() }
        let luts = (0..<N).map { _ in rng.below(2) == 0 ? palette[rng.below(8)] : rng.next() }
        let truth: [UInt8] = (0..<N).map { _ in rng.below(100) < 3 ? UInt8(3 + rng.below(253)) : [0, 1, 1, 0, 2][rng.below(5)] }
        var modes = [UInt8](repeating: 0, count: N)
        let tern = rng.below(10) < 6
        for h in hs {
            h.put([UInt8](repeating: 0, count: N), count: N, verb: .setModesBulk); XCTAssertTrue(h.cmd("SET_MODES_BULK").hasPrefix("OK"))
            h.put(ranks, count: N, verb: .setRanksBulk); XCTAssertTrue(h.cmd("SET_RANKS_BULK").hasPrefix("OK"))
            h.put(nb, count: N, verb: .setNeighborsBulk); XCTAssertTrue(h.cmd("SET_NEIGHBORS_BULK").hasPrefix("OK"))
            XCTAssertTrue(h.lutsBulk(luts).hasPrefix("OK"))
            XCTAssertTrue(h.rows("SET_TRUTH_BULK", truth.enumerated().map { (UInt32($0.offset), UInt32($0.element)) }).hasPrefix("OK"))
        }
        var ternarySet = Set<Int>()
        if tern {
            for i in 0..<N where truth[i] < 3 && rng.below(10) < 4 { modes[i] = [1, 2, 5, 6][rng.below(4)]; ternarySet.insert(i) }
            let tids = (0..<N).map { _ in UInt16(rng.below(3)) }
            var th: [Float] = []
            for _ in 0..<N { let lo = [-2.5, -1.0, -0.5, 0.0][rng.below(4)]; th += [Float(lo), Float(lo + [0, 0.5, 1, 2][rng.below(4)])] }
            for h in hs {
                for c in ["TTABLE PRESET 0 TMIN 6", "TTABLE PRESET 1 TSUM 6", "TTABLE PRESET 2 TCONS 3"] {
                    XCTAssertTrue(h.cmd(c).hasPrefix("OK"), c)
                }
                h.put(tids, count: N, verb: .setTTableIdsBulk); XCTAssertTrue(h.cmd("SET_TTABLE_IDS_BULK").hasPrefix("OK"))
                h.put(th, count: N, verb: .setThreshBulk); XCTAssertTrue(h.cmd("SET_THRESH_BULK").hasPrefix("OK"))
                h.put(modes, count: N, verb: .setModesBulk); XCTAssertTrue(h.cmd("SET_MODES_BULK").hasPrefix("OK"))
            }
        }
        var registers = Set<Int>()
        let cands = (0..<N).filter { i in (0..<6).allSatisfy { nb[i * 6 + $0] < 0 } && modes[i] == 0 }
        var rows: [(UInt32, UInt32)] = []
        for _ in 0..<min(cands.count, [0, 3, 20][rng.below(3)]) {
            let d = cands[rng.below(cands.count)]
            let src = (d + 1 + rng.below(N - 1)) % N                // never a self-loop
            rows.append((UInt32(src), UInt32(d))); registers.insert(d)
        }
        if !rows.isEmpty { for h in hs { XCTAssertTrue(h.rows("CONNECT_BACK_BULK", rows).hasPrefix("OK")) } }
        return (ranks, registers, ternarySet)
    }

    /// A random verb on a lane: a selection and an op, with the cases the header lists.
    func randomVerb(n: Int, ranks: [UInt64], lane: [UInt64], registers: Set<Int>, ternary: Set<Int>,
                    rng: inout Rng, tally: inout FuzzTally) -> (Sel, Op) {
        let present = Array(Set(ranks)).sorted()
        var sel: Sel
        switch rng.below(12) {
        case 0: sel = .nodes(0, UInt64(n - 1)); tally.wholeLane += 1
        case 1: let lo = rng.below(n); sel = .nodes(UInt64(lo), UInt64(n - 1)); tally.lastId += 1
        case 2: let i = rng.below(n); sel = .nodes(UInt64(i), UInt64(i)); tally.oneNode += 1
        case 3: let lo = rng.below(n); sel = .nodes(UInt64(lo), UInt64(min(n - 1, lo + rng.below(71))))
        case 4: let lo = rng.below(n), hi = rng.below(n); sel = .nodes(UInt64(min(lo, hi)), UInt64(max(lo, hi)))
        case 5, 6, 7: let r = present[rng.below(present.count)]; sel = .rank(r, r)
        case 8: let a = present[rng.below(present.count)], b = present[rng.below(present.count)]; sel = .rank(min(a, b), max(a, b))
        case 9: let r = UInt64(n + rng.below(1000)); sel = .rank(r, r); tally.emptySel += 1    // a rank holding no node
        case 10:                                                                                  // refusals by the selection
            sel = rng.below(2) == 0 ? .nodes(UInt64(rng.below(n)), UInt64(n + rng.below(5))) : .rank(5, 4)
        default: sel = .rank(0, UInt64.max)
        }
        if rng.below(3) == 0 { return (sel, .fill(rng.below(4) == 0 ? lane[rng.below(n)] : rng.next())) }
        // MAP: a mask, keys from nodes of the selection (and from registers and ternary nodes), keys matching nothing.
        let maskKind = rng.below(10)
        let mask: UInt64 = maskKind < 4 ? ~0 : (maskKind < 7 ? rng.next() & rng.next() : 0x6000_0000_0000_0000 | (rng.below(2) == 0 ? 0xF : 0))
        var ids: [Int]
        switch sel {
        case let .nodes(lo, hi) where hi < UInt64(n) && lo <= hi: ids = Array(Int(lo)...Int(hi))
        case let .rank(lo, hi) where lo <= hi: ids = ranks.indices.filter { ranks[$0] >= lo && ranks[$0] <= hi }
        default: ids = []
        }
        let np = 1 + rng.below(16)
        var keys: [UInt64] = []
        let regs = Array(registers), terns = Array(ternary)
        for _ in 0..<(np * 3) where keys.count < np {
            let src = rng.below(10)
            var k: UInt64
            if src < 5, !ids.isEmpty { k = lane[ids[rng.below(ids.count)]] & mask }
            else if src == 5, !regs.isEmpty { k = lane[regs[rng.below(regs.count)]] & mask }
            else if src == 6, !terns.isEmpty { k = lane[terns[rng.below(terns.count)]] & mask }
            else { k = rng.next() & mask; tally.keysNoNode += 1 }
            if !keys.contains(k) { keys.append(k) }
        }
        var pairs = keys.map { Pair(from: $0, to: rng.below(3) == 0 ? lane[rng.below(n)] : rng.next()) }
        if pairs.count >= 2 && rng.below(2) == 0 {                 // a `to` that is another pair's `from`
            let a = rng.below(pairs.count), b = (a + 1 + rng.below(pairs.count - 1)) % pairs.count
            pairs[a] = Pair(from: pairs[a].from, to: pairs[b].from | (rng.next() & ~mask))
            tally.chainHazards += 1
        }
        switch rng.below(25) {                                      // refusals by the op
        case 0: pairs = []
        case 1: pairs = (0..<17).map { Pair(from: UInt64($0) & mask, to: 0) }
        case 2 where pairs.count >= 2: pairs[1] = Pair(from: pairs[0].from, to: 7)
        case 3 where mask != ~0: pairs[0] = Pair(from: pairs[0].from | (~mask & (1 << UInt64(rng.below(64)))) | ~mask & 1, to: 0)
        default: break
        }
        if mask != ~0 { tally.masked += 1 }
        tally.pairsMax = max(tally.pairsMax, pairs.count)
        return (sel, .map(mask: mask, pairs: pairs))
    }

    func testG1_1RandomSelections300Seeds() throws {
        var t = FuzzTally()
        for seed in 0..<300 {
            var rng = Rng(s: 0x6100_0000 &+ UInt64(seed) &* 0x9E37)
            let side = [8, 40, 64, 128][seed % 4]
            let inline = seed % 5 == 4
            func engine(_ lib: DagDBEngine.ShaderLibrary) throws -> DagDBEngine {
                let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                        state: DagDBState(width: side, height: side), maxRank: 16, shaderLibrary: lib)
                let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
                for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
                return e
            }
            let g = H(try engine(inline ? .inlineSource : .automatic), side: side, maxRank: 16)
            let c = H(try engine(.automatic), side: side, maxRank: 16)
            let v = H(try engine(.automatic), side: side, maxRank: 16)
            c.e.setLutsCPUForTesting = 0                  // every verb through the CPU twin
            if inline { XCTAssertTrue(g.e.usedInlineShader); t.inlineSeeds += 1 }
            let hs = [g, c, v]
            let n = side * side
            var (ranks, registers, ternary) = fuzzGraph(hs, side: side, rng: &rng)
            XCTAssertEqual(ranks, g.ranks(), "seed \(seed): the rank model is the engine's")
            t.seeds += 1
            for step in 0..<(12 + rng.below(14)) {
                let label = "seed \(seed) step \(step)"
                let x = rng.below(100)
                if x < 55 {
                    let lane = v.lane()
                    let (sel, op) = randomVerb(n: n, ranks: ranks, lane: lane, registers: registers, ternary: ternary,
                                               rng: &rng, tally: &t)
                    let text = Self.line(sel, op, style: rng.below(10))
                    let rg = g.cmd(text), rc = c.cmd(text)
                    t.verbs += 1
                    if rg != rc { t.replyMismatches += 1 }
                    XCTAssertEqual(rg, rc, "\(label) \(text)")
                    if let why = Self.expectedRefusal(sel, op, n: n) {
                        t.refused += 1
                        XCTAssertTrue(rg.hasPrefix(why), "\(label) \(text): '\(rg)' expected '\(why)…'")
                    } else {
                        var want = lane, written: [Int] = []
                        let (k, w) = Self.reference(&want, ranks: ranks, sel, op, written: &written)
                        if rg != "OK SET_LUTS nodes=\(k) written=\(w)" { t.replyMismatches += 1 }
                        XCTAssertEqual(rg, "OK SET_LUTS nodes=\(k) written=\(w)", "\(label) \(text)")
                        XCTAssertEqual(v.lutsBulk(want), "OK SET_LUTS_BULK nodes=\(n)")
                        for i in written {
                            if registers.contains(i) { t.writtenRegisters += 1 }
                            if ternary.contains(i) { t.writtenTernary += 1 }
                        }
                        if case .fill = op { t.fills += 1 } else { t.maps += 1 }
                        XCTAssertTrue(g.e.lastSetLutsOnGPU || k == 0, "\(label): G on the GPU")
                        XCTAssertFalse(c.e.lastSetLutsOnGPU, "\(label): C through the CPU twin")
                        switch g.e.lastSetLutsPath {
                        case .rankList?: t.listPath += 1
                        case .rankLane?: t.lanePath += 1
                        case .range?: t.rangePath += 1
                        case nil: break
                        }
                    }
                    let dg = Self.laneDiff(g.e, v.e), dc = Self.laneDiff(c.e, v.e)
                    if dg != 0 { t.laneMismatchVerbs += 1 }
                    if dc != 0 { t.cpuMismatchVerbs += 1 }
                    XCTAssertEqual(dg, 0, "\(label) \(text): G's lane against the vector")
                    XCTAssertEqual(dc, 0, "\(label) \(text): C's lane against the vector")
                } else if x < 70 {
                    let k = [1, 1, 2, 3][rng.below(4)]
                    let rs = hs.map { $0.cmd("TICK \(k)") }
                    XCTAssertEqual(Self.strip(rs[0]), Self.strip(rs[1]), label); XCTAssertEqual(Self.strip(rs[0]), Self.strip(rs[2]), label)
                    t.ticks += 1
                    let d = Self.truthDiff(g.e, v.e) + Self.truthDiff(c.e, v.e)
                    if d != 0 { t.tickMismatches += 1 }
                    XCTAssertEqual(d, 0, "\(label): truth after TICK")
                } else if x < 80 {
                    let i = rng.below(n), r = UInt64(rng.below(min(n, 60)))
                    for h in hs { XCTAssertEqual(h.cmd("SET \(i) RANK \(r)"), "OK SET node=\(i) rank=\(r)") }
                    ranks[i] = r; t.rankWrites += 1
                } else if x < 83 {
                    let s = UInt64(1 + rng.below(29))
                    ranks = ranks.map { min($0 + s, UInt64(n - 1)) }
                    for h in hs { h.put(ranks, count: n, verb: .setRanksBulk); XCTAssertTrue(h.cmd("SET_RANKS_BULK").hasPrefix("OK")) }
                    t.rankWrites += 1
                } else if x < 88 {
                    let palette = (0..<6).map { _ in rng.next() }
                    let l = (0..<n).map { _ in rng.below(3) == 0 ? rng.next() : palette[rng.below(6)] }
                    for h in hs { XCTAssertTrue(h.lutsBulk(l).hasPrefix("OK")) }
                    t.bulkLanes += 1
                } else if x < 93 {
                    let mx = [1, 5, 20][rng.below(3)]
                    let rs = hs.map { $0.cmd("TICK UNTIL_STABLE MAX \(mx)") }
                    XCTAssertEqual(Self.strip(rs[0]), Self.strip(rs[2]), label)
                    t.ticks += 1
                    XCTAssertEqual(Self.truthDiff(g.e, v.e), 0, "\(label): truth after UNTIL_STABLE")
                } else if x < 96 {
                    let rs = hs.map { $0.cmd("TICK_SYNC 1") }
                    XCTAssertEqual(Self.strip(rs[0]), Self.strip(rs[2]), label)
                    t.ticks += 1
                } else {
                    let i = rng.below(n), lut = rng.next()
                    for h in hs { XCTAssertTrue(h.cmd("SET \(i) LUT 0x\(String(lut, radix: 16))").hasPrefix("OK")) }
                }
            }
            XCTAssertEqual(Self.laneDiff(g.e, v.e), 0, "seed \(seed): final lane")
        }
        print("G1.1 (ii) random selections: " + t.line)
        XCTAssertEqual(t.seeds, 300)
        for (name, c) in [("rank list", t.listPath), ("rank lane", t.lanePath), ("id range", t.rangePath),
                          ("FILL", t.fills), ("MAP", t.maps), ("masked", t.masked), ("refused", t.refused),
                          ("to==from", t.chainHazards), ("registers written", t.writtenRegisters),
                          ("ternary written", t.writtenTernary), ("empty selections", t.emptySel)] {
            XCTAssertGreaterThan(c, 0, "not vacuous: \(name)")
        }
        XCTAssertEqual(t.pairsMax, 17)
    }

    // MARK: - The control cases, one test each, deterministic

    /// Control (1)'s case: `to` of one pair is another pair's `from`. A
    /// simultaneous substitution writes each node once from its value before
    /// the verb; chaining would carry the a-nodes on to c.
    func testG1_1MapIsSimultaneousNotChained() throws {
        let f = try HandlerFixture(side: 16)
        let h = f.handler, n = h.engine.nodeCount
        var lane = (0..<n).map { UInt64($0 % 3) }                 // keys 0, 1, 2
        let lo = h.engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let hi = h.engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        for i in 0..<n { lo[i] = UInt32(lane[i]); hi[i] = 0 }
        let op = Op.map(mask: ~0, pairs: [Pair(from: 0, to: 1), Pair(from: 1, to: 2), Pair(from: 2, to: 0)])
        let r = h.handle(Self.line(.nodes(0, UInt64(n - 1)), op))
        let (k, w) = Self.reference(&lane, ranks: h.engine.readRanks(), .nodes(0, UInt64(n - 1)), op)
        XCTAssertEqual(r, "OK SET_LUTS nodes=\(k) written=\(w)")
        var wrong = 0
        for i in 0..<n where UInt64(hi[i]) << 32 | UInt64(lo[i]) != lane[i] { wrong += 1 }
        print("G1.1 MAP 0=1 1=2 2=0 over \(n) nodes: \(r); nodes off the simultaneous substitution: \(wrong)")
        XCTAssertEqual(wrong, 0)
        XCTAssertEqual(lane[0], 1); XCTAssertEqual(lane[1], 2); XCTAssertEqual(lane[2], 0)
    }

    /// Ranges of every length 1…70 at every offset 0…9 against the lane end
    /// and the lane start (the tail of a range not a multiple of the
    /// threadgroup, control (2)), on the GPU and on the CPU twin.
    func testG1_1RangeTails() throws {
        for cpu in [false, true] {
            let f = try HandlerFixture(side: 40)
            let h = f.handler, n = h.engine.nodeCount
            if cpu { h.engine.setLutsCPUForTesting = 0 }
            var wrong = 0, verbs = 0
            for len in 1...70 {
                for off in 0..<10 {
                    for lo in [off, n - len - off] where lo >= 0 && lo + len <= n {
                        let v = UInt64(len) << 40 | UInt64(off) << 8 | UInt64(lo)
                        var lane = (0..<n).map { i -> UInt64 in
                            let p = h.engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
                            let q = h.engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
                            return UInt64(q[i]) << 32 | UInt64(p[i])
                        }
                        let sel = Sel.nodes(UInt64(lo), UInt64(lo + len - 1))
                        let r = h.handle(Self.line(sel, .fill(v)))
                        _ = Self.reference(&lane, ranks: [], sel, .fill(v))
                        XCTAssertEqual(r, "OK SET_LUTS nodes=\(len) written=\(len)")
                        let p = h.engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
                        let q = h.engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
                        for i in 0..<n where UInt64(q[i]) << 32 | UInt64(p[i]) != lane[i] { wrong += 1 }
                        verbs += 1
                    }
                }
            }
            print("G1.1 range tails (\(cpu ? "CPU twin" : "GPU")): \(verbs) verbs, wrong nodes \(wrong)")
            XCTAssertEqual(wrong, 0)
            XCTAssertEqual(h.engine.lastSetLutsOnGPU, !cpu)
        }
    }

    /// Control (4)'s case: TICK (the per-rank lists built), FILL rank r, a
    /// SET RANK that moves a node out of r and another into it, FILL rank r
    /// again — the members of r now, not the old ones, get the second value.
    func testG1_1RankListStaleness() throws {
        let f = try HandlerFixture(side: 16)
        let h = f.handler, n = h.engine.nodeCount
        let rank = h.engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        for i in 0..<n { rank[i] = UInt64(i % 5) }
        h.engine.markRankTopologyDirty()
        XCTAssertTrue(h.handle("TICK 1").hasPrefix("OK TICK"))
        XCTAssertNotNil(h.engine.rankListBuf, "the per-rank lists exist")
        XCTAssertEqual(h.handle("SET_LUTS RANK 2-2 FILL 0xAA"), "OK SET_LUTS nodes=\(n / 5 + (n % 5 > 2 ? 1 : 0)) written=\(n / 5 + (n % 5 > 2 ? 1 : 0))")
        XCTAssertEqual(h.engine.lastSetLutsPath, .rankList)
        XCTAssertEqual(h.handle("SET 2 RANK 3"), "OK SET node=2 rank=3")   // node 2 leaves rank 2
        XCTAssertEqual(h.handle("SET 4 RANK 2"), "OK SET node=4 rank=2")   // node 4 joins it
        let r = h.handle("SET_LUTS RANK 2-2 FILL 0xBB")
        XCTAssertEqual(h.engine.lastSetLutsPath, .rankList)
        let lo = h.engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        var lane = (0..<n).map { i in i % 5 == 2 ? UInt64(0xAA) : 0 }
        let ranks = h.engine.readRanks()
        let (k, w) = Self.reference(&lane, ranks: ranks, .rank(2, 2), .fill(0xBB))
        XCTAssertEqual(r, "OK SET_LUTS nodes=\(k) written=\(w)")
        var wrong = 0
        for i in 0..<n where UInt64(lo[i]) != lane[i] { wrong += 1 }
        print("G1.1 rank-list staleness: \(r); node 2 lut 0x\(String(lo[2], radix: 16)), node 4 lut 0x\(String(lo[4], radix: 16)); wrong nodes \(wrong)")
        XCTAssertEqual(wrong, 0)
        XCTAssertEqual(lo[2], 0xAA, "node 2 left rank 2 before the second FILL")
        XCTAssertEqual(lo[4], 0xBB, "node 4 joined rank 2 before the second FILL")
    }

    /// The seams and the fallback: on the GPU by default; the CPU twin by the
    /// seam and when no command buffer can be had (the reply is the same); a
    /// command buffer that does not complete is refused by name.
    func testG1_1GPUAndCPUTwinAndNoCommandBuffer() throws {
        let f = try HandlerFixture(side: 16)
        let h = f.handler
        XCTAssertEqual(h.handle("SET_LUTS NODES 0-9 FILL 0x5"), "OK SET_LUTS nodes=10 written=10")
        XCTAssertTrue(h.engine.lastSetLutsOnGPU)
        h.engine.tickCommandBufferFailsAfterForTesting = 0           // no command buffer
        XCTAssertEqual(h.handle("SET_LUTS NODES 0-9 MAP 0x5=0x6"), "OK SET_LUTS nodes=10 written=10")
        XCTAssertFalse(h.engine.lastSetLutsOnGPU)
        h.engine.tickCommandBufferFailsAfterForTesting = nil
        h.engine.setLutsCPUForTesting = 11
        XCTAssertEqual(h.handle("SET_LUTS NODES 0-9 MAP 0x6=0x7"), "OK SET_LUTS nodes=10 written=10")
        XCTAssertTrue(h.engine.lastSetLutsOnGPU, "10 nodes, under the seam's 11")
        XCTAssertEqual(h.handle("SET_LUTS NODES 0-10 MAP 0x7=0x8"), "OK SET_LUTS nodes=11 written=10")
        XCTAssertFalse(h.engine.lastSetLutsOnGPU, "11 nodes: the CPU twin")
        h.engine.setLutsCPUForTesting = nil
        h.engine.commandBufferStatusFailsAfterForTesting = 0
        let r = h.handle("SET_LUTS NODES 0-9 FILL 0x9")
        print("G1.1 a failed command buffer: \(r)")
        XCTAssertEqual(r, "ERROR gpu: SET_LUTS: command buffer status error (no error object); nothing claimed, "
                       + "the LUT lane may hold part of that command buffer's writes")
        XCTAssertEqual(h.handle("SET_LUTS NODES 0-9 FILL 0x9"), "OK SET_LUTS nodes=10 written=10")
    }

    /// The grammar: both selectors, FILL, MAP with and without MASK, hex with
    /// and without 0x, any case; malformed lines are unknown; MAP's pair rules
    /// and the selection's are refused by name; reader sessions forbid it.
    func testG1_1GrammarAndRefusals() throws {
        guard case let .setLuts(s1, o1) = DSLParser.parse("SET_LUTS NODES 3-9 FILL 0xFF") else { return XCTFail() }
        XCTAssertEqual(s1, .nodes(3, 9)); XCTAssertEqual(o1, .fill(255))
        guard case let .setLuts(s2, o2) = DSLParser.parse("set_luts rank 2-2 map mask 0x6000000000000000 4000000000000000=0x400000000000000e 0X2000000000000000=2") else { return XCTFail() }
        XCTAssertEqual(s2, .rank(2, 2))
        XCTAssertEqual(o2, .map(mask: 0x6000_0000_0000_0000, pairs: [Pair(from: 0x4000_0000_0000_0000, to: 0x4000_0000_0000_000E),
                                                                     Pair(from: 0x2000_0000_0000_0000, to: 2)]))
        guard case let .setLuts(_, o3) = DSLParser.parse("SET_LUTS RANK 2-2 MAP 5=6") else { return XCTFail() }
        XCTAssertEqual(o3, .map(mask: ~0, pairs: [Pair(from: 5, to: 6)]))
        for bad in ["SET_LUTS NODES 3-9", "SET_LUTS NODES 3-9 FILL", "SET_LUTS NODES 3-9 FILL 0xZZ", "SET_LUTS NODES 3 FILL 1",
                    "SET_LUTS EDGES 3-9 FILL 1", "SET_LUTS NODES 3-9 FILL 1 2", "SET_LUTS NODES 3-9 MAP MASK",
                    "SET_LUTS NODES 3-9 MAP 1=", "SET_LUTS NODES 3-9 MAP 1=2=3", "SET_LUTS NODES 3-9 FILL 0x10000000000000000",
                    "SET_LUTS NODES -1-9 FILL 1", "SET_LUTS NODES 3-9 COPY 1"] {
            guard case .unknown = DSLParser.parse(bad) else { XCTFail(bad); continue }
        }
        let f = try HandlerFixture(side: 8)
        let h = f.handler
        XCTAssertEqual(h.handle("SET_LUTS NODES 9-3 FILL 1"), "ERROR out_of_range: range 9-3 is empty (lo > hi)")
        XCTAssertEqual(h.handle("SET_LUTS NODES 3-64 FILL 1"), "ERROR out_of_range: node 64 not in 0..<64")
        XCTAssertEqual(h.handle("SET_LUTS RANK 9-3 FILL 1"), "ERROR out_of_range: range 9-3 is empty (lo > hi)")
        XCTAssertEqual(h.handle("SET_LUTS RANK 40-90 FILL 1"), "OK SET_LUTS nodes=0 written=0")
        XCTAssertEqual(h.handle("SET_LUTS NODES 0-3 MAP"), "ERROR out_of_range: SET_LUTS MAP pairs 0 not in 1...16; nothing written")
        let seventeen = (0..<17).map { "\($0)=1" }.joined(separator: " ")
        XCTAssertEqual(h.handle("SET_LUTS NODES 0-3 MAP \(seventeen)"), "ERROR out_of_range: SET_LUTS MAP pairs 17 not in 1...16; nothing written")
        XCTAssertEqual(h.handle("SET_LUTS NODES 0-3 MAP MASK 0xF0 0x10=1 0x21=2"),
                       "ERROR bad_value: SET_LUTS MAP pair 1: from 0x21 has bits outside MASK 0xF0 (a LUT ANDed with the mask never equals it); nothing written")
        XCTAssertEqual(h.handle("SET_LUTS NODES 0-3 MAP MASK 0xF0 0x10=1 0x20=2 0x10=3"),
                       "ERROR bad_value: SET_LUTS MAP pairs 0 and 2 have the same key 0x10 under MASK 0xF0 (keys must be distinct after masking); nothing written")
        let rd = h.handle("OPEN_READER")
        let id = rd.split(separator: " ").first { $0.hasPrefix("id=") }!.dropFirst(3)
        XCTAssertEqual(h.handle("READER \(id) SET_LUTS NODES 0-3 FILL 1"), "ERROR forbidden: command not allowed in reader session (read-only)")
        XCTAssertEqual(h.handle("SET_LUTS NODES 0-63 FILL 0xFFFFFFFFFFFFFFFF"), "OK SET_LUTS nodes=64 written=64")
    }

    // MARK: - The allow-list

    /// After SET_LUTS (every form, refusals included): the DAG verdict kept,
    /// no index or plan rebuilt, the (truth, rank) index clean; the next
    /// TICK and UNTIL_STABLE re-verify and rebuild nothing.
    func testG1_2SetLutsKeepsTheVerdictTheIndexAndThePlan() throws {
        let side = 16
        let f = try HandlerFixture(side: side, maxRank: 8)
        let h = f.handler, e = h.engine
        try EngineE1DaemonTests.buildGraph(e, seed: 0x612, ternary: false)
        e.markRankTopologyDirty()
        XCTAssertGreaterThan(e.backEdgeCount, 0)
        XCTAssertTrue(h.handle("TICK UNTIL_STABLE MAX 20").hasPrefix("OK TICK UNTIL_STABLE"))
        XCTAssertTrue(h.handle("TICK 2").hasPrefix("OK TICK 2"))
        XCTAssertTrue(h.handle("SELECT TRUTH 1 RANK 0-7").hasPrefix("OK SELECT"))
        let v0 = h.dagVerdictCheckCount, ix0 = e.frontierIndexBuildCount, pl0 = e.latchPlanBuildCount
        let rt0 = e.rankTopologyRebuildCount
        XCTAssertEqual(v0, 1); XCTAssertEqual(ix0, 1); XCTAssertEqual(pl0, 1)
        XCTAssertFalse(h.truthRankIndex.isDirty)
        let verbs = ["SET_LUTS NODES 0-255 FILL 0x8000000000000001", "SET_LUTS RANK 3-3 FILL 0x7",
                     "SET_LUTS RANK 0-7 MAP MASK 0xF 0x7=0x3 0x1=0x2", "SET_LUTS NODES 9-3 FILL 1",
                     "SET_LUTS RANK 5-5 MAP 0x3=0x0 0x0=0x3"]
        for verb in verbs {
            let r = h.handle(verb)
            XCTAssertTrue(r.hasPrefix(verb.contains("9-3") ? "ERROR" : "OK SET_LUTS"), "\(verb): \(r)")
            XCTAssertTrue(h.dagVerdict.checked, "\(verb) keeps the DAG verdict")
            XCTAssertTrue(e.hasFrontierIndex, "\(verb) keeps the frontier index")
            XCTAssertFalse(h.truthRankIndex.isDirty, "\(verb) leaves the (truth, rank) index clean")
            XCTAssertTrue(h.handle("TICK 1").hasPrefix("OK TICK 1"))
            XCTAssertTrue(h.handle("TICK UNTIL_STABLE MAX 5").hasPrefix("OK TICK UNTIL_STABLE"))
            XCTAssertTrue(h.handle("SELECT TRUTH 1 RANK 0-7").hasPrefix("OK SELECT"))
        }
        print("G1.2: verdict checks \(v0) -> \(h.dagVerdictCheckCount), index builds \(ix0) -> \(e.frontierIndexBuildCount), "
              + "plan builds \(pl0) -> \(e.latchPlanBuildCount), rank-topology rebuilds \(rt0) -> \(e.rankTopologyRebuildCount)")
        XCTAssertEqual(h.dagVerdictCheckCount, v0, "no rank-order re-verification after SET_LUTS")
        XCTAssertEqual(e.frontierIndexBuildCount, ix0, "the frontier index not rebuilt")
        XCTAssertEqual(e.latchPlanBuildCount, pl0, "F1's plan kept")
        XCTAssertEqual(e.rankTopologyRebuildCount, rt0, "the rank lists not rebuilt")
    }

    // MARK: - The WAL

    /// The record: FILL 31 bytes, MAP of p pairs 32 + 16p (by the log's size
    /// delta); a voxel phase's three verbs 31, 64, 31.
    func testG1_3RecordSizes() throws {
        let p = tmp + "sizes.wal"
        let w = try DagDBWAL.Appender(path: p, nodeCount: 64)
        let f = try HandlerFixture(side: 8, wal: w)
        var size = try Data(contentsOf: URL(fileURLWithPath: p)).count
        func delta(_ line: String) throws -> Int {
            XCTAssertTrue(f.handler.handle(line).hasPrefix("OK SET_LUTS"), line)
            w.barrier()
            let s = try Data(contentsOf: URL(fileURLWithPath: p)).count
            defer { size = s }
            return s - size
        }
        var lines: [String] = []
        let fill = try delta("SET_LUTS RANK 10-10 FILL 0x8000000000000000")
        XCTAssertEqual(fill, 31)
        lines.append("FILL \(fill)")
        let vox = try delta("SET_LUTS RANK 9-9 MAP MASK 0x6000000000000000 0x4000000000000000=0x400000000000000E 0x2000000000000000=0x2000000000000000")
        XCTAssertEqual(vox, 64)
        XCTAssertEqual(try delta("SET_LUTS NODES 58-63 FILL 0xFFFFFFFFFFFFFFFF"), 31)
        lines.append("voxel MAP(2) \(vox)")
        for np in 1...16 {
            let pairs = (0..<np).map { "\(String(UInt64($0) << 48 | 0xABCDEF, radix: 16))=\(String(~UInt64($0), radix: 16))" }.joined(separator: " ")
            let d = try delta("SET_LUTS NODES 0-63 MAP \(pairs)")
            XCTAssertEqual(d, 32 + 16 * np, "MAP of \(np)")
            if np <= 14 { XCTAssertLessThanOrEqual(d, 256, "MAP of \(np)") }
            lines.append("MAP(\(np)) \(d)")
        }
        print("G1.3 record bytes: " + lines.joined(separator: ", "))
    }

    /// IMPORT MORTON + 20 random verbs (SET RANK among them) on a daemon with
    /// a WAL; a fresh engine replays the log alone: the LUT lane equals the
    /// live one and the reference's, byte for byte.
    func testG1_3ReplayImportAndTwentyVerbs() throws {
        let side = 16, n = side * side
        let src = try DagDBEngine(grid: try HexGrid(width: side, height: side), state: DagDBState(width: side, height: side), maxRank: 8)
        try EngineE1DaemonTests.buildGraph(src, seed: 0x613, ternary: true)
        let dir = tmp + "imp"
        _ = try DagDBSnapshot.exportMorton(engine: src, nodeCount: n, dir: dir)
        let p = tmp + "replay.wal"
        let w = try DagDBWAL.Appender(path: p, nodeCount: n)
        let f = try HandlerFixture(side: side, wal: w, maxRank: 8)
        let h = f.handler
        XCTAssertTrue(h.handle("IMPORT MORTON \(dir)").hasPrefix("OK IMPORT"))
        XCTAssertTrue(h.handle("TICK 1").hasPrefix("OK TICK 1"))       // the per-rank lists built (a tick is not logged)
        var lane = H.laneOf(h.engine), ranks = h.engine.readRanks()
        var rng = Rng(s: 0x6133)
        var t = FuzzTally()
        var verbs: [String] = []
        for i in 0..<20 {
            if i % 7 == 3 {
                let node = rng.below(n), r = UInt64(rng.below(8))
                let line = "SET \(node) RANK \(r)"
                XCTAssertEqual(h.handle(line), "OK SET node=\(node) rank=\(r)")
                ranks[node] = r; verbs.append(line)
                continue
            }
            var (sel, op) = randomVerb(n: n, ranks: ranks, lane: lane, registers: [], ternary: [], rng: &rng, tally: &t)
            if Self.expectedRefusal(sel, op, n: n) != nil { sel = .rank(UInt64(i % 8), UInt64(i % 8)); op = .fill(rng.next()) }
            let line = Self.line(sel, op, style: i)
            let (k, wr) = Self.reference(&lane, ranks: ranks, sel, op)
            XCTAssertEqual(h.handle(line), "OK SET_LUTS nodes=\(k) written=\(wr)", line)
            verbs.append(line)
        }
        XCTAssertEqual(H.laneOf(h.engine), lane, "live against the reference")
        w.barrier()
        let fresh = try DagDBEngine(grid: try HexGrid(width: side, height: side), state: DagDBState(width: side, height: side), maxRank: 8)
        let r = try DagDBWAL.replay(engine: fresh, nodeCount: n, path: p)
        print("G1.3 replay: applied=\(r.recordsApplied) skipped=\(r.recordsSkipped) refusals=\(r.refusals); verbs: \(verbs.count)")
        XCTAssertEqual(r.recordsApplied, 21)
        XCTAssertEqual(r.recordsSkipped, 0)
        XCTAssertEqual(H.laneOf(fresh), lane, "replayed against the reference")
        XCTAssertEqual(Self.laneDiff(fresh, h.engine), 0, "replayed against live")
        XCTAssertEqual(fresh.readRanks(), h.engine.readRanks())
    }

    /// A record whose selector is out of range for the replayed node count is
    /// skipped, counted under out_of_range and named; the records around it
    /// apply. A version-2 log refuses the verb by name, nothing written.
    func testG1_3OutOfRangeRecordSkippedByNameAndV2LogRefuses() throws {
        let p = tmp + "oor.wal"
        let w = try DagDBWAL.Appender(path: p, nodeCount: 64)
        try w.setLuts(.nodes(0, 3), .fill(0x11))
        try w.setLuts(.nodes(10, 64), .fill(0x22))
        try w.setLuts(.rank(0, 0), .map(mask: 0xFF, pairs: [Pair(from: 0x11, to: 0x33)]))
        w.barrier()
        let e = try DagDBEngine(grid: try HexGrid(width: 8, height: 8), state: DagDBState(width: 8, height: 8), maxRank: 8)
        let r = try DagDBWAL.replay(engine: e, nodeCount: 64, path: p)
        print("G1.3 out of range: applied=\(r.recordsApplied) skipped=\(r.skipReasons.line) refusals=\(r.refusals)")
        XCTAssertEqual(r.recordsApplied, 2)
        XCTAssertEqual(r.skipReasons.outOfRangeIndex, 1)
        XCTAssertEqual(r.refusals.count, 1)
        XCTAssertTrue(r.refusals[0].contains("SET_LUTS NODES 10-64: node 64 not in 0..<64; not applied"), r.refusals[0])
        let lane = H.laneOf(e)
        XCTAssertEqual(Array(lane[0..<4]), [0x33, 0x33, 0x33, 0x33])
        XCTAssertEqual(lane[10], 0)
        // A version-2 log.
        let p2 = tmp + "v2.wal"
        var hdr = Data(DagDBWAL.magic)
        for v in [UInt32(2), UInt32(16), UInt32(0)] { withUnsafeBytes(of: v.littleEndian) { hdr.append(contentsOf: $0) } }
        try hdr.write(to: URL(fileURLWithPath: p2))
        let f = try HandlerFixture(side: 4, wal: try DagDBWAL.Appender(path: p2, nodeCount: 16))
        let rr = f.handler.handle("SET_LUTS NODES 0-3 FILL 0x1")
        // The refusal names the way to a log that takes the record.
        XCTAssertEqual(rr, "ERROR wal: append: opcode 0x4f needs log version 3, this log is version 2"
                       + "; nothing written; this log cannot be upgraded in place: first stop every writer (a write between this SAVE and the stop stays in the log moved aside, and is lost); then SAVE a snapshot to a file, stop the daemon, move \(p2) aside" + " and start it again with DAGDB_STARTUP_LOAD naming that file (it loads the file and opens a fresh version-3 log;" + " the fresh log takes this record)")
        XCTAssertEqual(H.laneOf(f.handler.engine)[0], 0)
    }
}

extension EngineG1DaemonTests.H {
    static func laneOf(_ e: DagDBEngine) -> [UInt64] {
        let n = e.nodeCount
        let lo = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let hi = e.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        return (0..<n).map { UInt64(hi[$0]) << 32 | UInt64(lo[$0]) }
    }
}
