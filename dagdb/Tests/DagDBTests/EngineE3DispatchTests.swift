import XCTest
@testable import DagDB

/// Per-rank contiguous dispatch.
///
/// `tick(tickNumber:rankOrderVerified: true)` dispatches each rank's span of
/// the precomputed per-(rank, colour) lists once; `tick(tickNumber:)` is the
/// rank-mode tick as it was (one dispatch per (rank, colour) segment, colour
/// order shuffled per tick). On a graph whose every in-range slot reads a
/// strictly higher rank the two must write the same bytes. Each test below
/// first asserts the fixture IS such a graph (`rankOrderViolation == nil`,
/// the daemon's own TICK check), then compares every truth byte after every
/// tick, ternary kinds and registers included:
///
/// - the frozen binary graphs of `TernaryR1BinaryControlTests` against the
///   hashes recorded before any ternary engine change, through the
///   binary-only kernel and through the general kernel, bundle and inline;
/// - the random mixed graphs of `TernaryR3KernelTests` (binary, TTABLE, TTHRESH, NOSKIP, registers,
///   absent slots of both shapes, Loom bytes) against the CPU reference and
///   against the colour path;
/// - the tick-perf suite's random DAGs (DagDBGraph, 16 ranks, registers);
/// - the voxel morphology layout A (V/A/O + change tree, O → V back edges),
///   every morphology phase, binary and with ternary kinds mixed in.
final class EngineE3DispatchTests: XCTestCase {

    typealias R1 = TernaryR1BinaryControlTests
    typealias R3 = TernaryR3KernelTests

    static func diff(_ a: [UInt8], _ b: [UInt8]) -> String { R3.firstDiff(a, b) }

    /// Ranks that hold at least one node the rank loop covers.
    static func nonEmptyRanks(_ e: DagDBEngine) -> Int {
        e.ensureRankTopology()
        let r = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: e.nodeCount)
        var seen = Set<UInt64>()
        for i in 0..<e.nodeCount where r[i] < UInt64(e.effectiveRankCount) { seen.insert(r[i]) }
        return seen.count
    }

    /// Non-empty (rank, colour) segments.
    static func nonEmptySegments(_ e: DagDBEngine) -> Int {
        e.ensureRankTopology()
        let r = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: e.nodeCount)
        var seen = Set<UInt64>()
        for (c, group) in e.grid.colorGroups.enumerated() {
            for m in group where r[Int(m)] < UInt64(e.effectiveRankCount) {
                seen.insert(r[Int(m)] &* 8 &+ UInt64(c))
            }
        }
        return seen.count
    }

    // MARK: - The recorded binary hashes through the per-rank path

    func testE3PerRankReproducesR1MainHashesBothKernels() throws {
        let data = try Data(contentsOf: R1.fixturesDir.appendingPathComponent(R1.fixtureName))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let graphs = try XCTUnwrap(obj["graphs"] as? [[String: Any]])
        var cells = 0, equal = 0
        for (i, c) in R1.cases.enumerated() {
            let want = try XCTUnwrap(graphs[i]["hashes"] as? [String: [String: String]])["rank"]
            let g = try R1.makeGraph(side: c.side, seed: c.seed)
            for lib in [DagDBEngine.ShaderLibrary.automatic, .inlineSource] {
                for fast in [true, false] {
                    let e = try TernaryA6R1GeneralKernelTests.makeEngine(g, library: lib)
                    XCTAssertNil(DagDBSnapshot.rankOrderViolation(engine: e, nodeCount: e.nodeCount),
                                 "R1 side \(c.side) is not rank-ordered; the per-rank path is not defined on it")
                    e.binaryFastPathEnabled = fast
                    for t in 0..<R1.checkpoints.last! {
                        e.tick(tickNumber: UInt32(t), rankOrderVerified: true)
                        XCTAssertEqual(e.lastTickKernel, fast ? .binaryOnly : .general)
                        XCTAssertEqual(e.lastRankTickDispatchCount, Self.nonEmptyRanks(e))
                        guard R1.checkpoints.contains(t + 1) else { continue }
                        let got = R1.hashTruth(e)
                        XCTAssertEqual(got, want?["\(t + 1)"],
                                       "E3 R1 side \(c.side) fast=\(fast) inline=\(lib == .inlineSource) N=\(t + 1)")
                        cells += 1
                        if got == want?["\(t + 1)"] { equal += 1 }
                    }
                }
            }
        }
        // 3 cases × 2 libraries × 2 kernels × 3 checkpoints.
        XCTAssertEqual(cells, 36)
        print("E3 R1 per-rank: \(equal)/\(cells) EQUAL to main's recorded rank hashes")
    }

    // MARK: - Mixed ternary graphs against the CPU reference and the colour path

    func testE3PerRankEqualsCPUReferenceAndColourPathOnR3Mixed() throws {
        var cells = 0
        for (side, seeds) in [(64, 6), (256, 4), (1024, 2)] {
            let grid = try HexGrid(width: side, height: side)
            let colors = R3.colorOf(grid)
            for s in 0..<seeds {
                let seed = UInt64(0x7E13_E300) &+ UInt64(side) << 8 &+ UInt64(s)
                let m = R3.makeMixed(grid: grid, colorOf: colors, seed: seed)
                let exp = R3.reference(m, mode: "rank")
                let perRank = try R3.makeEngine(m)
                let colour = try R3.makeEngine(m)
                let inline = try R3.makeEngine(m, library: .inlineSource)
                XCTAssertNil(DagDBSnapshot.rankOrderViolation(engine: perRank, nodeCount: perRank.nodeCount))
                XCTAssertGreaterThan(perRank.nonBinaryNodeCount, 0, "R3's object carries ternary nodes")
                for t in 0..<R3.checkpoints.last! {
                    perRank.tick(tickNumber: UInt32(t), rankOrderVerified: true)
                    XCTAssertEqual(perRank.lastTickKernel, .general)
                    XCTAssertEqual(perRank.lastRankTickDispatchCount, Self.nonEmptyRanks(perRank))
                    inline.tick(tickNumber: UInt32(t), rankOrderVerified: true)
                    colour.tick(tickNumber: UInt32(t))
                    XCTAssertEqual(colour.lastRankTickDispatchCount, Self.nonEmptySegments(colour))
                    let a = perRank.readTruthStates(), b = colour.readTruthStates()
                    XCTAssertTrue(a == b, "side \(side) seed \(s) tick \(t + 1) per-rank vs colour: \(Self.diff(a, b))")
                    let iv = inline.readTruthStates()
                    XCTAssertTrue(iv == a, "side \(side) seed \(s) tick \(t + 1) inline vs bundle: \(Self.diff(iv, a))")
                    if let want = exp.atCheckpoint[t + 1] {
                        XCTAssertTrue(a == want, "side \(side) seed \(s) N=\(t + 1) per-rank vs CPU: \(Self.diff(a, want))")
                        cells += 1
                    }
                }
            }
        }
        XCTAssertEqual(cells, (6 + 4 + 2) * R3.checkpoints.count)
        print("E3 R3 per-rank: \(cells) checkpoint cells vs the CPU reference, every tick vs the colour path")
    }

    // MARK: - The tick-perf suite's random DAGs (DagDBGraph)

    private struct LCG {
        var s: UInt64
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 16 }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    /// DagDBTickPerfTests.randomGraph, verbatim in effect (that one is private).
    private func randomGraph(seed: UInt64, n: Int = 300, registers: Int = 8) throws -> DagDBGraph {
        var rng = LCG(s: seed)
        let g = DagDBGraph()
        var ranks: [UInt64] = []
        for i in 0..<n {
            let r = UInt64(rng.int(16))
            ranks.append(r)
            g.addGate(label: "g\(i)", rank: r, lut6: rng.next() | (rng.next() << 48))
        }
        for dst in 0..<n {
            var fanIn = 0
            for _ in 0..<6 where fanIn < 6 {
                let src = rng.int(n)
                if ranks[src] > ranks[dst] { try? g.connect(from: src, to: dst); fanIn += 1 }
            }
        }
        for k in 0..<registers {
            let reg = g.addLeaf(label: "r\(k)", rank: UInt64(rng.int(16)), truth: k % 2 == 0)
            try? g.connectBack(from: rng.int(n), to: reg)
        }
        return g
    }

    func testE3PerRankEqualsColourAndLegacyOnTickPerfRandomDAGs() throws {
        var ticks = 0
        for seed in 1...20 {
            let a = try DagDBEngine(graph: try randomGraph(seed: UInt64(seed)))
            let b = try DagDBEngine(graph: try randomGraph(seed: UInt64(seed)))
            let c = try DagDBEngine(graph: try randomGraph(seed: UInt64(seed)))
            XCTAssertNil(DagDBSnapshot.rankOrderViolation(engine: a, nodeCount: a.nodeCount))
            for t in 1...8 {
                a.tick(tickNumber: UInt32(t), rankOrderVerified: true)
                b.tick(tickNumber: UInt32(t))
                c.tickLegacy(tickNumber: UInt32(t))
                XCTAssertEqual(a.readTruthStates(), b.readTruthStates(), "seed \(seed) tick \(t) per-rank vs colour")
                XCTAssertEqual(a.readTruthStates(), c.readTruthStates(), "seed \(seed) tick \(t) per-rank vs legacy")
                ticks += 1
            }
        }
        XCTAssertEqual(ticks, 160)
    }

    // MARK: - The voxel morphology layout A

    /// LayoutA, ported: V (rank L+2, registers), A (L+1, six face neighbours
    /// or a border node), O (L, slots V and A), six border nodes (L+2), the
    /// change tree (L−1 … 0); back edges O → V.
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

        /// The per-phase LUTs, ported from the voxel morphology client.
        func luts(_ phase: String, field: [Bool]) -> [UInt64] {
            var a: UInt64 = 0, border: UInt64 = 0
            var o: (Int) -> UInt64 = { _ in 0 }
            switch phase {
            case "seed":    o = { field[$0] ? Self.c1 : Self.c0 }
            case "surface": a = Self.and6; o = { _ in 0b0010 }
            case "dilate":  a = Self.or6; o = { _ in 0b1110 }
            case "erode":   a = Self.and6; o = { _ in 0b1000 }
            case "flood":   a = Self.or6; o = { field[$0] ? Self.c0 : 0b1110 }; border = Self.c1
            case "extract": o = { field[$0] ? Self.c0 : 0b0101 }
            default: break   // "zero"
            }
            var lut = [UInt64](repeating: 0, count: nodeCount)
            for v in 0..<N { lut[A0 + v] = a; lut[O0 + v] = o(v) }
            for d in 0..<6 { lut[B0 + d] = border }
            for (j, (st, sz)) in zip(levelStarts, levels).enumerated() {
                for i in st..<(st + sz) { lut[i] = j == 0 ? Self.xor3 : Self.or6 }
            }
            return lut
        }

        /// A random solid with holes, deterministic in `seed`.
        func field(seed: UInt64) -> [Bool] {
            var g = R3.SplitMix64(s: seed)
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
            setLuts(e, luts("surface", field: field))
            for v in 0..<N { try e.addBackEdge(src: UInt32(O0 + v), dst: UInt32(V0 + v)) }
            if ternary {
                // Library: TMAX (Kleene OR) and TSUM over six inputs.
                try e.writeTables(first: 0, bytes: try TernaryReference.presetTable(.tmax, k: 6)
                                                   + TernaryReference.presetTable(.tsum, k: 6))
                let mode = e.modePtr, tid = e.ttableIdPtr, lo = e.thrLoPtr, hi = e.thrHiPtr
                // Every third A node TTHRESH (NOSKIP on every other one of them),
                // thresholds ±0.5 over unit weights: the sign of the face sum.
                for v in stride(from: 0, to: N, by: 3) {
                    mode[A0 + v] = v % 2 == 0 ? 6 : 2
                    lo[A0 + v] = -0.5; hi[A0 + v] = 0.5
                }
                // The OR6 levels of the change tree TTABLE, alternating the two tables,
                // NOSKIP on a quarter of them.
                for j in 1..<L {
                    for i in levelStarts[j]..<(levelStarts[j] + levels[j]) {
                        mode[i] = i % 4 == 0 ? 5 : 1
                        tid[i] = UInt16(i % 2)
                    }
                }
            }
            return e
        }

        func setLuts(_ e: DagDBEngine, _ lut: [UInt64]) {
            let lo = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
            let hi = e.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
            for i in 0..<nodeCount { lo[i] = UInt32(lut[i] & 0xFFFF_FFFF); hi[i] = UInt32(lut[i] >> 32) }
        }
    }

    func testE3PerRankEqualsColourOnVoxelLayoutA() throws {
        var ticks = 0, moved = 0
        for n in [8, 16] {
            let lay = VoxelA(n: n)
            let field = lay.field(seed: 0xE3_0000 &+ UInt64(n))
            for ternary in [false, true] {
                let a = try lay.makeEngine(field: field, ternary: ternary)
                let b = try lay.makeEngine(field: field, ternary: ternary)
                XCTAssertNil(DagDBSnapshot.rankOrderViolation(engine: a, nodeCount: a.nodeCount),
                             "voxel layout A n=\(n) must be rank-ordered")
                XCTAssertEqual(a.nonBinaryNodeCount > 0, ternary)
                var t: UInt32 = 0
                let phases: [(String, Int)] = [("seed", 1), ("surface", 1), ("seed", 1), ("dilate", 3),
                                               ("erode", 3), ("zero", 1), ("flood", 2 * n), ("extract", 1)]
                for (phase, k) in phases {
                    let lut = lay.luts(phase, field: field)
                    lay.setLuts(a, lut); lay.setLuts(b, lut)
                    for _ in 0..<k {
                        let before = a.readTruthStates()
                        a.tick(tickNumber: t, rankOrderVerified: true)
                        b.tick(tickNumber: t)
                        t += 1
                        let x = a.readTruthStates(), y = b.readTruthStates()
                        XCTAssertTrue(x == y, "voxel layout A n=\(n) ternary=\(ternary) \(phase) tick \(t): \(Self.diff(x, y))")
                        XCTAssertEqual(a.lastRankTickDispatchCount, lay.maxRank, "one dispatch per rank (\(lay.maxRank) ranks)")
                        XCTAssertGreaterThan(b.lastRankTickDispatchCount, lay.maxRank)
                        XCTAssertEqual(a.lastTickKernel, ternary ? .general : .binaryOnly)
                        for i in 0..<x.count where x[i] != before[i] { moved += 1 }
                        ticks += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(moved, 0, "the phases must move truth, or the comparison is vacuous")
        print("E3 voxel layout A per-rank vs colour: \(ticks) ticks equal, \(moved) truth bytes moved")
    }

    // MARK: - The dispatch itself

    func testE3DispatchCountsAndTheColourPathUnchanged() throws {
        let lay = VoxelA(n: 8)
        let e = try lay.makeEngine(field: lay.field(seed: 1), ternary: false)
        e.tick(tickNumber: 0)
        let segments = Self.nonEmptySegments(e)
        XCTAssertEqual(e.lastRankTickDispatchCount, segments, "tick(tickNumber:) dispatches every non-empty (rank, colour) segment")
        e.tick(tickNumber: 1, rankOrderVerified: false)
        XCTAssertEqual(e.lastRankTickDispatchCount, segments)
        e.tick(tickNumber: 2, rankOrderVerified: true)
        XCTAssertEqual(e.lastRankTickDispatchCount, Self.nonEmptyRanks(e))
        XCTAssertEqual(Self.nonEmptyRanks(e), lay.maxRank)
        XCTAssertEqual(e.rankDispatchNodeCount(), e.nodeCount, "the spans cover every node, as the segments do")
        print("E3 dispatches at voxel layout A n=8: colour path \(segments), per-rank \(lay.maxRank)")
    }

    /// The per-rank lists cost nothing until the path is taken (4 bytes per
    /// node after), and are rebuilt with the colour lists when the rank
    /// topology changes: every rank shifted up by 2 (rank order kept),
    /// marked dirty, and the two paths still agree, over the new ranks.
    func testE3RankListsAllocatedOnFirstUseAndRebuiltOnRankChange() throws {
        let lay = VoxelA(n: 8)
        let field = lay.field(seed: 7)
        let a = try lay.makeEngine(field: field, ternary: true)
        let b = try lay.makeEngine(field: field, ternary: true)
        func listBytes(_ e: DagDBEngine) -> Int { e.allocationBytes().first { $0.name == "rankList" }!.bytes }
        a.tick(tickNumber: 0); b.tick(tickNumber: 0)
        XCTAssertEqual(listBytes(a), 0, "no per-rank list before the first per-rank tick")
        a.tick(tickNumber: 1, rankOrderVerified: true); b.tick(tickNumber: 1)
        XCTAssertEqual(listBytes(a), 4 * a.nodeCount)
        XCTAssertEqual(listBytes(b), 0)
        XCTAssertEqual(a.readTruthStates(), b.readTruthStates())
        for e in [a, b] {
            let r = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: e.nodeCount)
            for i in 0..<e.nodeCount { r[i] += 2 }
            e.markRankTopologyDirty()
        }
        XCTAssertNil(DagDBSnapshot.rankOrderViolation(engine: a, nodeCount: a.nodeCount))
        for t in 2..<12 {
            a.tick(tickNumber: UInt32(t), rankOrderVerified: true); b.tick(tickNumber: UInt32(t))
            XCTAssertEqual(a.readTruthStates(), b.readTruthStates(), "after the rank shift, tick \(t)")
            XCTAssertEqual(a.lastRankTickDispatchCount, lay.maxRank, "the same ranks, shifted: no empty rank dispatched")
            XCTAssertEqual(a.effectiveRankCount, lay.maxRank + 2)
        }
    }
}
