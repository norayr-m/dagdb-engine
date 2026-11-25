import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// The frontier session.
///
/// Equivalence per tick. Three engines tick the same graph:
///   A — the plain per-rank path (`tick(rankOrderVerified: true)`, no session,
///       the CPU latch: TICK as it ran before the frontier session existed),
///       the byte reference;
///   C — the counting session (`countingLatchChanges`, the CPU counting
///       latch: TICK UNTIL_STABLE as it ran before the frontier session
///       existed), the count
///       reference;
///   B — the frontier session (`frontierSession`).
/// After EVERY tick of every session: B's truth bytes equal A's (every node,
/// ternary nodes, Loom bytes and UNDEFINED included), C's equal A's, and B's
/// `lastChanged` / `lastCount` equal C's. ≥ 40 ticks per case; the bytes must
/// move on ≥ 1 tick per case. Cases: the random mixed graphs (6 seeds at
/// 64², 4 at 256², 2 at 1024²) with duplicate and chained back edges added,
/// each with the default whole-rank threshold and with lists only; the
/// flood, oscillator, mid-seeded, stable (a Loom byte written before the
/// session) and a register written before the session; the voxel morphology layout A at 8³
/// and 16³, binary and ternary, one session per phase; the floor-probe graph
/// (16³ at its fixed point plus the 2-node NOT loop); a NOSKIP walk driven by
/// a register ring (chained back edges); B compiled from the inline source.
///
/// Invalidation: every enumerated writer between two TICK UNTIL_STABLEs, A
/// (as before the frontier session existed: the counting session, CPU latch) against B (the
/// handler's frontier seam), replies and bytes equal, and the index rebuilt
/// after the topology writers only (`frontierIndexBuildCount`).
///
/// Memory: `allocationBytes` names the session's buffers, by formula;
/// 0 bytes on an engine that never opened a session.
///
/// Each test prints its totals, so a control run (one line of the frontier
/// changed in the worktree) is read from the same lines.
final class EngineF2DaemonTests: XCTestCase {

    typealias Rng = EngineE1DaemonTests.Rng

    private var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "engine-f2-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - The comparison

    struct Tally {
        var cases = 0
        var ticks = 0                 // ticks compared
        var mismatchTicks = 0         // ticks whose B bytes differed from A's
        var mismatchBytes = 0
        var referenceMismatches = 0   // ticks whose C bytes differed from A's (the references disagree)
        var countMismatches = 0       // ticks whose B counts differed from C's
        var moved = 0                 // bytes A's ticks changed
        var changingTicks = 0         // ticks that changed a byte
        var latched = 0               // registers C's latches changed
        var incremental = 0           // B's ticks after a session's first
        var evaluated = 0             // rank entries B dispatched on those ticks
        var plainNodes = 0            // node slots the plain tick dispatches on those ticks
        var wholeRanks = 0            // ranks B dispatched whole on those ticks
        var listRanks = 0             // ranks B dispatched from a non-empty list on those ticks
        var latchListed = 0           // effective back edges B's latch dispatched on those ticks
        var vacuousCases: [String] = []
        mutating func add(_ o: Tally) {
            cases += o.cases; ticks += o.ticks; mismatchTicks += o.mismatchTicks; mismatchBytes += o.mismatchBytes
            referenceMismatches += o.referenceMismatches; countMismatches += o.countMismatches; moved += o.moved
            changingTicks += o.changingTicks; latched += o.latched; incremental += o.incremental
            evaluated += o.evaluated; plainNodes += o.plainNodes; wholeRanks += o.wholeRanks
            listRanks += o.listRanks; latchListed += o.latchListed; vacuousCases += o.vacuousCases
        }
        var line: String {
            "cases \(cases), ticks \(ticks), mismatching ticks \(mismatchTicks), mismatching bytes \(mismatchBytes), "
                + "count mismatches \(countMismatches), reference disagreements \(referenceMismatches); "
                + "bytes moved \(moved) on \(changingTicks) ticks, registers latched \(latched); "
                + "incremental ticks \(incremental): evaluated \(evaluated) of \(plainNodes) plain node slots, "
                + "ranks whole \(wholeRanks) / listed \(listRanks), back edges latched \(latchListed)"
        }
    }

    /// Three engines on one graph: A plain, B frontier, C counting.
    struct Trio {
        let a: DagDBEngine, b: DagDBEngine, c: DagDBEngine
        init(_ a: DagDBEngine, _ b: DagDBEngine, _ c: DagDBEngine) {
            self.a = a; self.b = b; self.c = c
            a.latchOnGPU = false     // pre-F's CPU latch
            c.latchOnGPU = false     // pre-F's CPU counting latch
        }
    }

    func differing(_ a: DagDBEngine, _ b: DagDBEngine) -> Int {
        let n = a.nodeCount
        let pa = a.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let pb = b.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        var d = 0
        for i in 0..<n where pa[i] != pb[i] { d += 1 }
        return d
    }

    /// Plain ticks on all three engines (no session), compared.
    func plainTicks(_ t: Trio, _ k: Int, _ tick: inout UInt32, _ label: String) {
        for _ in 0..<k {
            t.a.tick(tickNumber: tick, rankOrderVerified: true)
            t.b.tick(tickNumber: tick, rankOrderVerified: true)
            t.c.tick(tickNumber: tick, rankOrderVerified: true)
            tick += 1
            XCTAssertEqual(differing(t.a, t.b), 0, "\(label) plain tick \(tick)")
            XCTAssertEqual(differing(t.a, t.c), 0, "\(label) plain tick \(tick)")
        }
    }

    /// One session of `k` ticks: C in a counting session, B in a frontier
    /// session, A plain; every tick compared. Returns the bytes A moved.
    @discardableResult
    func session(_ t: Trio, _ k: Int, _ tick: inout UInt32, _ tally: inout Tally, _ label: String) throws -> Int {
        var moved = 0
        var local = tally
        var tk = tick
        try t.c.countingLatchChanges { cc in
            try t.b.frontierSession { cb in
                XCTAssertTrue(cb.frontierActive, "\(label): the frontier index was had")
                for s in 0..<k {
                    let before = t.a.readTruthStates()
                    t.a.tick(tickNumber: tk, rankOrderVerified: true)
                    cc.lastCount = 0; cb.lastCount = 0
                    t.c.tick(tickNumber: tk, rankOrderVerified: true)
                    t.b.tick(tickNumber: tk, rankOrderVerified: true)
                    tk += 1
                    XCTAssertTrue(t.b.lastTickFrontier, "\(label) tick \(s): through the frontier")
                    XCTAssertEqual(t.b.lastTickFrontierFull, s == 0, "\(label) tick \(s): whole only first")
                    let after = t.a.readTruthStates()
                    var m = 0
                    for i in 0..<after.count where after[i] != before[i] { m += 1 }
                    moved += m
                    local.moved += m
                    if m > 0 { local.changingTicks += 1 }
                    let d = differing(t.a, t.b)
                    local.ticks += 1
                    if d != 0 { local.mismatchTicks += 1; local.mismatchBytes += d }
                    XCTAssertEqual(d, 0, "\(label) session tick \(s): B's truth bytes differ from the plain tick's")
                    let dc = differing(t.a, t.c)
                    if dc != 0 { local.referenceMismatches += 1 }
                    XCTAssertEqual(dc, 0, "\(label) session tick \(s): the two pre-F references disagree")
                    if cb.lastChanged != cc.lastChanged || cb.lastCount != cc.lastCount { local.countMismatches += 1 }
                    XCTAssertEqual(cb.lastChanged, cc.lastChanged, "\(label) session tick \(s): lastChanged")
                    XCTAssertEqual(cb.lastCount, cc.lastCount, "\(label) session tick \(s): lastCount")
                    local.latched += cc.lastCount
                    if s > 0 {
                        local.incremental += 1
                        local.evaluated += t.b.lastFrontierEvaluated
                        local.plainNodes += t.a.rankDispatchNodeCount()
                        local.wholeRanks += t.b.lastFrontierWholeRanks
                        local.listRanks += t.b.lastFrontierListedRanks
                        local.latchListed += t.b.lastFrontierLatched
                    }
                }
            }
        }
        tick = tk
        tally = local
        return moved
    }

    /// The four ternary lanes and the library, equal on A and B (a tick never writes them).
    func assertLanesEqual(_ t: Trio, _ label: String) {
        XCTAssertEqual(t.a.ternaryLaneBytes, t.b.ternaryLaneBytes, label)
        if let la = t.a.ternaryLaneView, let lb = t.b.ternaryLaneView {
            let n = t.a.nodeCount
            XCTAssertEqual(memcmp(la.mode, lb.mode, n), 0, label)
            XCTAssertEqual(memcmp(la.ttableId, lb.ttableId, 2 * n), 0, label)
            XCTAssertEqual(memcmp(la.thrLo, lb.thrLo, 4 * n), 0, label)
            XCTAssertEqual(memcmp(la.thrHi, lb.thrHi, 4 * n), 0, label)
        }
        XCTAssertEqual(t.a.libraryBytes(), t.b.libraryBytes(), label)
    }

    func finishCase(_ moved: Int, _ label: String, _ tally: inout Tally) {
        tally.cases += 1
        if moved == 0 { tally.vacuousCases.append(label) }
        XCTAssertGreaterThan(moved, 0, "\(label): the states must change on at least one tick (not vacuous)")
    }

    // MARK: - Random mixed graphs (TernaryR3KernelTests.makeMixed, ported)

    static let r3RankLevels = 16
    static let r3Tables = 16
    static let r3Weights: [Float] = [1, -1, 0.5, -0.5, 2, -2.5, 3.25, 1e8, -1e8, 0.1, -0.3, 0]
    static let r3Thresholds: [Float] = [-3, -2.5, -2, -1.5, -1, -0.5, 0, 0.5, 1, 1.5, 2, 2.5, 3]

    /// The random mixed object (binary, TTABLE, TTHRESH, NOSKIP on and off, registers,
    /// absent slots of both shapes, Loom bytes and UNDEFINED on binary
    /// nodes), the same generator and stream as `TernaryR3KernelTests.makeMixed`.
    static func r3Mixed(side: Int, seed: UInt64) -> TernaryReference.Graph {
        let n = side * side
        var rng = Rng(s: seed)
        var tables = [UInt8](repeating: 2, count: r3Tables * 729)
        for t in 0..<r3Tables {
            if t < TernaryReference.Preset.allCases.count {
                let p = TernaryReference.Preset.allCases[t]
                let k = p.arities.upperBound == 1 ? 1 : 1 + rng.below(6)
                let tb = try! TernaryReference.presetTable(p, k: k)
                for i in 0..<729 { tables[t * 729 + i] = tb[i] }
            } else {
                for i in 0..<729 { tables[t * 729 + i] = UInt8(rng.below(3)) }
            }
        }
        var truth = [UInt8](repeating: 0, count: n)
        var rank = [UInt64](repeating: 0, count: n)
        var low = [UInt32](repeating: 0, count: n), high = low
        var mode = [UInt8](repeating: 0, count: n)
        var tid = [UInt16](repeating: 0, count: n)
        var lo = [Float](repeating: 0, count: n), hi = lo
        var w = [Float](repeating: 1, count: n * 6)
        var isReg = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            rank[i] = UInt64(rng.below(r3RankLevels))
            low[i] = UInt32(truncatingIfNeeded: rng.next())
            high[i] = UInt32(truncatingIfNeeded: rng.next())
            let reg = rng.below(64) == 0
            let kind = rng.below(3)
            if reg || kind == 0 {
                mode[i] = 0
                truth[i] = UInt8(truncatingIfNeeded: rng.next())        // Loom codes and UNDEFINED included
            } else {
                mode[i] = UInt8(kind) | (rng.below(2) == 0 ? 4 : 0)     // NOSKIP on and off
                truth[i] = UInt8(rng.below(3))
            }
            isReg[i] = reg ? 1 : 0
            tid[i] = UInt16(rng.below(r3Tables))
            let a = r3Thresholds[rng.below(r3Thresholds.count)]
            let b = r3Thresholds[rng.below(r3Thresholds.count)]
            lo[i] = min(a, b); hi[i] = max(a, b)
            for d in 0..<6 { w[i * 6 + d] = r3Weights[rng.below(r3Weights.count)] }
        }
        var byRank = [[Int32]](repeating: [], count: r3RankLevels)
        for i in 0..<n { byRank[Int(rank[i])].append(Int32(i)) }
        var sorted = [Int32](); sorted.reserveCapacity(n)
        var start = [Int](repeating: 0, count: r3RankLevels + 1)
        for r in 0..<r3RankLevels { start[r] = sorted.count; sorted.append(contentsOf: byRank[r]) }
        start[r3RankLevels] = sorted.count
        var nb = [Int32](repeating: -1, count: n * 6)
        for i in 0..<n where isReg[i] == 0 {
            let first = start[Int(rank[i]) + 1]
            let count = n - first
            for d in 0..<6 {
                let u = rng.next()
                switch u % 16 {
                case 0, 1, 2, 3: nb[i * 6 + d] = -1                               // absent
                case 4: nb[i * 6 + d] = Int32(n + Int((u >> 8) % 1000))           // >= node count
                default:
                    if count > 0 { nb[i * 6 + d] = sorted[first + Int((u >> 8) % UInt64(count))] }
                }
            }
        }
        var srcs: [UInt32] = [], dsts: [UInt32] = []
        for i in 0..<n where isReg[i] != 0 { srcs.append(UInt32(rng.below(n))); dsts.append(UInt32(i)) }
        return TernaryReference.Graph(
            truth: truth, rank: rank, lutLow: low, lutHigh: high, neighbors: nb,
            isRegister: isReg, edgeWeights: w, mode: mode, ttableId: tid, thrLo: lo, thrHi: hi,
            tables: tables, backEdgeSrcs: srcs, backEdgeDsts: dsts)
    }

    /// The engine of a random mixed object, plus duplicate back edges (8 extra edges
    /// into existing registers) and chains (8 register → register edges,
    /// listed last, so they are the effective ones).
    static func r3Engine(_ g: TernaryReference.Graph, side: Int, seed: UInt64,
                         library: DagDBEngine.ShaderLibrary = .automatic) throws -> DagDBEngine {
        var st = DagDBState(width: side, height: side)
        st.truthState = g.truth; st.rank = g.rank; st.lut6Low = g.lutLow; st.lut6High = g.lutHigh
        st.edgeWeights = g.edgeWeights; st.nodeMode = g.mode; st.ttableId = g.ttableId
        st.thrLo = g.thrLo; st.thrHi = g.thrHi; st.ttables = g.tables
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side), state: st, maxRank: r3RankLevels,
                                shaderLibrary: library)
        let p = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { p[i] = g.neighbors[i] }
        for i in 0..<g.backEdgeSrcs.count { try e.addBackEdge(src: g.backEdgeSrcs[i], dst: g.backEdgeDsts[i]) }
        let regs = g.backEdgeDsts
        var r = Rng(s: seed ^ 0xF2D0_F2D0)
        for _ in 0..<8 { try e.addBackEdge(src: UInt32(r.below(e.nodeCount)), dst: regs[r.below(regs.count)]) }
        for _ in 0..<8 {
            let s = regs[r.below(regs.count)], d = regs[r.below(regs.count)]
            if s != d { try e.addBackEdge(src: s, dst: d) }
        }
        return e
    }

    func r3Cases(_ sizes: [(Int, Int)], fraction: Double, ticks: Int, label: String,
                 inlineB: Bool = false) throws -> Tally {
        var tally = Tally()
        for (side, seeds) in sizes {
            for s in 0..<seeds {
                let seed = UInt64(0x7E13_F200) &+ UInt64(side) << 8 &+ UInt64(s)
                let g = Self.r3Mixed(side: side, seed: seed)
                let t = Trio(try Self.r3Engine(g, side: side, seed: seed),
                             try Self.r3Engine(g, side: side, seed: seed, library: inlineB ? .inlineSource : .automatic),
                             try Self.r3Engine(g, side: side, seed: seed))
                if inlineB { XCTAssertTrue(t.b.usedInlineShader) }
                XCTAssertNil(DagDBSnapshot.rankOrderViolation(engine: t.a, nodeCount: t.a.nodeCount))
                XCTAssertGreaterThan(t.a.nonBinaryNodeCount, 0)
                t.b.frontierWholeFraction = fraction
                var tick: UInt32 = 0
                let name = "\(label) R3 side \(side) seed \(s)"
                let moved = try session(t, ticks, &tick, &tally, name)
                assertLanesEqual(t, name)
                finishCase(moved, name, &tally)
            }
        }
        return tally
    }

    func testF2_1R3MixedGraphsDefaultThreshold() throws {
        let t = try r3Cases([(64, 6), (256, 4), (1024, 2)], fraction: 0.25, ticks: 40, label: "τ=0.25")
        print("F2.1 R3 mixed, default threshold: " + t.line)
        XCTAssertEqual(t.cases, 12)
        XCTAssertGreaterThan(t.listRanks, 0, "some rank dispatched from its list")
    }

    func testF2_1R3MixedGraphsListsOnly() throws {
        let t = try r3Cases([(64, 6), (256, 4), (1024, 2)], fraction: .infinity, ticks: 40, label: "lists only")
        print("F2.1 R3 mixed, lists only: " + t.line)
        XCTAssertEqual(t.cases, 12)
        XCTAssertEqual(t.wholeRanks, 0, "no rank dispatched whole after the first tick")
    }

    func testF2_1R3InlineShaderFrontier() throws {
        let t = try r3Cases([(64, 3)], fraction: .infinity, ticks: 40, label: "inline", inlineB: true)
        print("F2.1 R3 mixed, B from the inline source: " + t.line)
    }

    func testF2_1R3MixedGraphsWholeWheneverListed() throws {
        let t = try r3Cases([(64, 6)], fraction: 0, ticks: 40, label: "τ=0")
        print("F2.1 R3 mixed, whole whenever anything is listed: " + t.line)
        XCTAssertEqual(t.listRanks, 0, "τ = 0: every rank with a listed node is dispatched whole")
    }

    // MARK: - Kernel-evaluated back-edge destinations (the cleared-flag case of `EngineE5DaemonTests`)

    /// The graph of `EngineE1DaemonTests.buildGraph` plus, as `EngineF1DaemonTests.e1Graph` builds it:
    /// extra back edges into binary no-fan-in nodes from any source (so a
    /// source can be a destination), duplicates, truth bytes >= 3, and
    /// `evaluated` destinations whose register flag is cleared by a raw write.
    func e1Graph(side: Int, seed: UInt64, ternary: Bool, evaluated: Int) throws -> HandlerFixture {
        let f = try HandlerFixture(side: side)
        let e = f.handler.engine
        try EngineE1DaemonTests.buildGraph(e, seed: seed, ternary: ternary)
        let n = e.nodeCount
        var g = Rng(s: seed &+ 0xF2)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        let free = (0..<n).filter { i in
            !TernaryReference.isTernary(e.modeByte(i)) && (0..<6).allSatisfy { nb[i * 6 + $0] < 0 }
        }
        for _ in 0..<min(24, free.count) {
            let d = free[g.below(free.count)], s = g.below(n)
            if s != d { try e.addBackEdge(src: UInt32(s), dst: UInt32(d)) }
        }
        if let d0 = e.backEdgeDsts.first, let d1 = e.backEdgeDsts.dropFirst(3).first {
            try e.addBackEdge(src: UInt32(g.below(n)), dst: d0)
            try e.addBackEdge(src: UInt32(g.below(n)), dst: d1)
            try e.addBackEdge(src: UInt32(g.below(n)), dst: d0)
        }
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        for _ in 0..<(n / 40) {
            let i = g.below(n)
            if !TernaryReference.isTernary(e.modeByte(i)) { truth[i] = UInt8(3 + g.below(250)) }
        }
        if evaluated > 0 {
            let reg = e.isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: n)
            let ds = Array(Set(e.backEdgeDsts)).sorted()
            for k in 0..<min(evaluated, ds.count) { reg[Int(ds[(k * 7) % ds.count])] = 0 }
        }
        XCTAssertNil(f.handler.rankTickDagRefusal())
        return f
    }

    /// The `evaluatedSource` graph of `EngineF1DaemonTests`: an oscillator s = NOT t (t a register),
    /// back edges s→t, s→d1, d1→d2, d1's flag cleared: the kernel evaluates
    /// d1 (its LUT's bit 0: 1) before the latch writes s into it, and d2's
    /// source is that kernel-evaluated destination.
    func evaluatedSource(_ f: HandlerFixture) {
        let h = f.handler
        let (t, s, d1, d2) = (90, 91, 92, 93)
        XCTAssertTrue(h.handle("SET \(t) RANK 1").hasPrefix("OK"))
        XCTAssertTrue(h.handle("SET \(s) RANK 0").hasPrefix("OK"))
        XCTAssertTrue(h.handle("SET \(s) LUT 5555555555555555").hasPrefix("OK"))
        XCTAssertTrue(h.handle("CONNECT FROM \(t) TO \(s)").hasPrefix("OK"))
        XCTAssertTrue(h.handle("SET \(d1) LUT FFFFFFFFFFFFFFFF").hasPrefix("OK"))
        for (a, b) in [(s, t), (s, d1), (d1, d2)] {
            XCTAssertEqual(h.handle("CONNECT BACK FROM \(a) TO \(b)"), "OK CONNECT BACK from=\(a) to=\(b)")
        }
        h.engine.isRegisterBuf.contents().storeBytes(of: UInt8(0), toByteOffset: d1, as: UInt8.self)
    }

    func testF2_1KernelEvaluatedDestinations() throws {
        var tally = Tally()
        for side in [16, 24, 32] {
            for ternary in [false, true] {
                for seed: UInt64 in [1, 2] {
                    let s = seed &* 0x53 &+ UInt64(side) &+ (ternary ? 7000 : 0)
                    let fs = try (0..<3).map { _ in try e1Graph(side: side, seed: s, ternary: ternary, evaluated: 3) }
                    let t = Trio(fs[0].handler.engine, fs[1].handler.engine, fs[2].handler.engine)
                    var tick: UInt32 = 0
                    let label = "E1 evaluated side \(side) ternary \(ternary) seed \(s)"
                    var moved = try session(t, 20, &tick, &tally, label)
                    moved += try session(t, 20, &tick, &tally, label + " (second session)")
                    finishCase(moved, label, &tally)
                }
            }
        }
        do {
            let (t, _) = try e2Trio { self.evaluatedSource($0) }
            var tick: UInt32 = 0
            let moved = try session(t, 40, &tick, &tally, "evaluated source")
            XCTAssertTrue(t.b.lastLatchTwoPhase, "d1 is a destination and a source")
            finishCase(moved, "evaluated source", &tally)
        }
        print("F2.1 kernel-evaluated destinations: " + tally.line)
        XCTAssertEqual(tally.cases, 13)
    }

    /// A tick with no command buffer inside a frontier session runs nothing
    /// and reports 0 / 0, as the counting session does, and the session carries on exact.
    func testF2_1FailedCommandBufferInsideAFrontierSession() throws {
        let (t, _) = try e2Trio { self.floodChain($0, m: 30) }
        var tick: UInt32 = 0
        var tally = Tally()
        try session(t, 5, &tick, &tally, "before")
        try t.b.frontierSession { cb in
            try t.c.countingLatchChanges { cc in
                for k in 0..<20 {
                    if k == 3 || k == 9 {
                        let before = t.b.readTruthStates()
                        t.b.tickCommandBufferFailsAfterForTesting = 0
                        t.b.tick(tickNumber: tick, rankOrderVerified: true)
                        t.b.tickCommandBufferFailsAfterForTesting = nil
                        XCTAssertEqual(t.b.readTruthStates(), before, "nothing ticked")
                        XCTAssertEqual(cb.lastChanged, 0); XCTAssertEqual(cb.lastCount, 0)
                    }
                    t.a.tick(tickNumber: tick, rankOrderVerified: true)
                    t.c.tick(tickNumber: tick, rankOrderVerified: true)
                    t.b.tick(tickNumber: tick, rankOrderVerified: true)
                    tick += 1
                    XCTAssertEqual(differing(t.a, t.b), 0, "tick \(k)")
                    XCTAssertEqual(cb.lastChanged, cc.lastChanged, "tick \(k)")
                    XCTAssertEqual(cb.lastCount, cc.lastCount, "tick \(k)")
                }
            }
        }
    }

    // MARK: - The cases of EngineE2DaemonTests.floodChain / oscillators

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

    func oscillators(_ f: HandlerFixture, k: Int) {
        let h = f.handler
        for j in 0..<k {
            XCTAssertTrue(h.handle("SET \(200 + j) RANK 1").hasPrefix("OK"))
            XCTAssertTrue(h.handle("SET \(220 + j) LUT NOR").hasPrefix("OK"))
            XCTAssertTrue(h.handle("CONNECT FROM \(200 + j) TO \(220 + j)").hasPrefix("OK"))
            XCTAssertTrue(h.handle("CONNECT BACK FROM \(220 + j) TO \(200 + j)").hasPrefix("OK"))
        }
    }

    /// Three handlers built the same way; their engines as a trio.
    func e2Trio(_ build: (HandlerFixture) -> Void) throws -> (Trio, [HandlerFixture]) {
        let fs = try (0..<3).map { _ in try HandlerFixture(side: 16) }
        for f in fs { build(f); XCTAssertNil(f.handler.rankTickDagRefusal()) }
        return (Trio(fs[0].handler.engine, fs[1].handler.engine, fs[2].handler.engine), fs)
    }

    func testF2_1E2Cases() throws {
        var tally = Tally()
        // 1 · the flood (40 registers), 45 ticks: 40 changing, then stable.
        do {
            let (t, _) = try e2Trio { self.floodChain($0, m: 40) }
            var tick: UInt32 = 0
            let moved = try session(t, 45, &tick, &tally, "E2 flood")
            finishCase(moved, "E2 flood", &tally)
        }
        // 2 · already stable, with a Loom byte written on a combinational node
        //     before the session: the whole first tick repairs it, then 39
        //     ticks of an empty frontier.
        do {
            let (t, fs) = try e2Trio { self.floodChain($0, m: 40) }
            var tick: UInt32 = 0
            plainTicks(t, 45, &tick, "E2 stable warm-up")
            for f in fs { XCTAssertTrue(f.handler.handle("SET 107 TRUTH 200").hasPrefix("OK")) }
            let moved = try session(t, 40, &tick, &tally, "E2 stable + Loom byte")
            finishCase(moved, "E2 stable + Loom byte", &tally)
        }
        // 3 · the oscillator (5 NOR registers), 40 ticks.
        do {
            let (t, _) = try e2Trio { self.oscillators($0, k: 5) }
            var tick: UInt32 = 0
            let moved = try session(t, 40, &tick, &tally, "E2 oscillator")
            finishCase(moved, "E2 oscillator", &tally)
        }
        // 4 · the flood seeded mid-chain (30 registers, seeded at 12), 40 ticks.
        do {
            let (t, fs) = try e2Trio { self.floodChain($0, m: 30, seed: false) }
            for f in fs { XCTAssertTrue(f.handler.handle("SET 12 TRUTH 1").hasPrefix("OK")) }
            var tick: UInt32 = 0
            let moved = try session(t, 40, &tick, &tally, "E2 mid-seeded")
            finishCase(moved, "E2 mid-seeded", &tally)
        }
        // 5 · a register written by SET TRUTH before the session: the
        //     oscillator after 7 ticks, one register flipped (its phase moves
        //     for good), then 40 ticks.
        do {
            let (t, fs) = try e2Trio { self.oscillators($0, k: 5) }
            var tick: UInt32 = 0
            plainTicks(t, 7, &tick, "E2 register-written warm-up")
            let v = t.a.readTruthStates()[202] == 1 ? 0 : 1
            for f in fs { XCTAssertTrue(f.handler.handle("SET 202 TRUTH \(v)").hasPrefix("OK")) }
            let moved = try session(t, 40, &tick, &tally, "E2 register written")
            finishCase(moved, "E2 register written", &tally)
        }
        print("F2.1 E2 cases: " + tally.line)
        XCTAssertEqual(tally.cases, 5)
    }

    // MARK: - The voxel morphology layout A (EngineE3DispatchTests.VoxelA, ported)

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
        var used: Int { levelStarts.last! + levels.last! }

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
            setLuts(e, luts("surface", field: field))
            for v in 0..<N { try e.addBackEdge(src: UInt32(O0 + v), dst: UInt32(V0 + v)) }
            if ternary {
                try e.writeTables(first: 0, bytes: try TernaryReference.presetTable(.tmax, k: 6)
                                                   + TernaryReference.presetTable(.tsum, k: 6))
                let mode = e.modePtr, tid = e.ttableIdPtr, lo = e.thrLoPtr, hi = e.thrHiPtr
                for v in stride(from: 0, to: N, by: 3) {
                    mode[A0 + v] = v % 2 == 0 ? 6 : 2
                    lo[A0 + v] = -0.5; hi[A0 + v] = 0.5
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

        func setLuts(_ e: DagDBEngine, _ lut: [UInt64]) {
            let lo = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
            let hi = e.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
            for i in 0..<nodeCount { lo[i] = UInt32(lut[i] & 0xFFFF_FFFF); hi[i] = UInt32(lut[i] >> 32) }
        }
    }

    /// The phases, one session each (a LUT write between two sessions keeps
    /// the index: built once per case).
    func testF2_1VoxelLayoutA() throws {
        var tally = Tally()
        for n in [8, 16] {
            let lay = VoxelA(n: n)
            let field = lay.field(seed: 0xF2_0000 &+ UInt64(n))
            for ternary in [false, true] {
                let t = Trio(try lay.makeEngine(field: field, ternary: ternary),
                             try lay.makeEngine(field: field, ternary: ternary),
                             try lay.makeEngine(field: field, ternary: ternary))
                XCTAssertNil(DagDBSnapshot.rankOrderViolation(engine: t.a, nodeCount: t.a.nodeCount))
                XCTAssertEqual(t.a.nonBinaryNodeCount > 0, ternary)
                var tick: UInt32 = 0, moved = 0
                let phases: [(String, Int)] = [("seed", 1), ("surface", 1), ("seed", 1), ("dilate", 3),
                                               ("erode", 3), ("zero", 1), ("flood", 32), ("extract", 1)]
                let label = "voxel layout A n=\(n) ternary=\(ternary)"
                for (phase, k) in phases {
                    let lut = lay.luts(phase, field: field)
                    for e in [t.a, t.b, t.c] { lay.setLuts(e, lut) }
                    moved += try session(t, k, &tick, &tally, "\(label) \(phase)")
                }
                XCTAssertGreaterThanOrEqual(tick, 40)
                XCTAssertEqual(t.b.frontierIndexBuildCount, 1, "\(label): one index across the LUT writes")
                XCTAssertEqual(t.b.lastTickKernel, ternary ? .general : .binaryOnly)
                assertLanesEqual(t, label)
                finishCase(moved, label, &tally)
            }
        }
        print("F2.1 voxel layout A: " + tally.line)
        XCTAssertEqual(tally.cases, 4)
        XCTAssertLessThan(tally.evaluated, tally.plainNodes, "the frontier evaluates fewer nodes than the plain ticks")
    }

    /// The floor-probe graph, in-process: the voxel layout A 16³ at its fixed point
    /// (the flood run to the end), then a 2-node loop on two spare nodes (R,
    /// rank 1, a register; B = NOT R, rank 0; back edge B → R): exactly two
    /// bytes change per tick.
    func testF2_1FloorProbeGraph() throws {
        var tally = Tally()
        for ternary in [false, true] {
            let lay = VoxelA(n: 16)
            let field = lay.field(seed: 0xF2F0)
            let t = Trio(try lay.makeEngine(field: field, ternary: ternary),
                         try lay.makeEngine(field: field, ternary: ternary),
                         try lay.makeEngine(field: field, ternary: ternary))
            var tick: UInt32 = 0
            for e in [t.a, t.b, t.c] { lay.setLuts(e, lay.luts("zero", field: field)) }
            plainTicks(t, 1, &tick, "probe zero")
            for e in [t.a, t.b, t.c] { lay.setLuts(e, lay.luts("flood", field: field)) }
            var settled = false
            for _ in 0..<200 {
                let before = t.a.readTruthStates()
                plainTicks(t, 1, &tick, "probe flood")
                if t.a.readTruthStates() == before { settled = true; break }
            }
            XCTAssertTrue(settled, "the flood reaches its fixed point")
            let r = lay.used, bn = lay.used + 1
            XCTAssertLessThan(bn, lay.nodeCount, "two spare nodes past the layout")
            for e in [t.a, t.b, t.c] {
                e.rankBuf.contents().storeBytes(of: UInt64(1), toByteOffset: r * 8, as: UInt64.self)
                e.markRankTopologyDirty()
                e.lut6LowBuf.contents().storeBytes(of: UInt32(0x5555_5555), toByteOffset: bn * 4, as: UInt32.self)
                e.lut6HighBuf.contents().storeBytes(of: UInt32(0x5555_5555), toByteOffset: bn * 4, as: UInt32.self)
                e.neighborsBuf.contents().storeBytes(of: Int32(r), toByteOffset: bn * 6 * 4, as: Int32.self)
                e.dropFrontierIndex()
                try e.addBackEdge(src: UInt32(bn), dst: UInt32(r))
            }
            XCTAssertNil(DagDBSnapshot.rankOrderViolation(engine: t.a, nodeCount: t.a.nodeCount))
            let label = "floor probe ternary=\(ternary)"
            var local = Tally()
            let moved = try session(t, 40, &tick, &local, label)
            XCTAssertEqual(moved, 2 * 40, "\(label): exactly two bytes per tick (B by the kernel, R by the latch)")
            XCTAssertLessThanOrEqual(local.evaluated, 8 * local.incremental,
                                     "\(label): the frontier evaluates a handful of nodes per tick")
            finishCase(moved, label, &local)
            tally.add(local)
        }
        print("F2.1 floor probe: " + tally.line)
    }

    /// A NOSKIP walk: TTHRESH NOSKIP nodes read a register ring whose bytes
    /// hold each value two ticks (R0 → R1 → R2 → R3 → R0 back edges, a chain
    /// latched in two phases; bytes 1,1,0,0). When the ring's byte flips, a
    /// NOSKIP node can only reach 0; on the next tick its input is unchanged
    /// and only its own previous byte moved it on (NOSKIP self-dirty).
    func noskipWalk(_ f: HandlerFixture, units: Int) {
        let h = f.handler
        XCTAssertTrue(h.handle("TTABLE PRESET 0 TSUM 6").hasPrefix("OK"))
        for u in 0..<units {
            let ring = (0..<4).map { 10 * u + $0 }
            let x = 10 * u + 5, y = 10 * u + 6
            for r in ring { XCTAssertTrue(h.handle("SET \(r) RANK 3").hasPrefix("OK")) }
            XCTAssertTrue(h.handle("SET \(x) RANK 2").hasPrefix("OK"))
            XCTAssertTrue(h.handle("SET \(y) RANK 1").hasPrefix("OK"))
            XCTAssertTrue(h.handle("CONNECT FROM \(ring[0]) TO \(x)").hasPrefix("OK"))
            XCTAssertTrue(h.handle("CONNECT FROM \(x) TO \(y)").hasPrefix("OK"))
            for k in 0..<4 {
                XCTAssertEqual(h.handle("CONNECT BACK FROM \(ring[k]) TO \(ring[(k + 1) % 4])"),
                               "OK CONNECT BACK from=\(ring[k]) to=\(ring[(k + 1) % 4])")
            }
            for (k, r) in ring.enumerated() { XCTAssertTrue(h.handle("SET \(r) TRUTH \(k < 2 ? 1 : 0)").hasPrefix("OK")) }
            XCTAssertTrue(h.handle("SET \(x) TRUTH 0").hasPrefix("OK"))   // −1
            XCTAssertTrue(h.handle("SET \(x) MODE TTHRESH NOSKIP").hasPrefix("OK"))
            XCTAssertTrue(h.handle("SET \(x) THRESH -0.5 0.5").hasPrefix("OK"))
            // y: a binary reader of x (x's byte as a bit).
            XCTAssertTrue(h.handle("SET \(y) LUT AAAAAAAAAAAAAAAA").hasPrefix("OK"))
        }
    }

    func testF2_1NoskipWalkAndChainedRing() throws {
        var tally = Tally()
        // Lists only (no rank dispatched whole after the first tick), so the
        // NOSKIP nodes are evaluated only when something listed them.
        for fraction in [Double.infinity, 0.25] {
            let (t, _) = try e2Trio { self.noskipWalk($0, units: 8) }
            t.b.frontierWholeFraction = fraction
            var tick: UInt32 = 0
            let label = "NOSKIP walk τ=\(fraction)"
            let moved = try session(t, 40, &tick, &tally, label)
            finishCase(moved, label, &tally)
            XCTAssertTrue(t.b.lastLatchTwoPhase, "the ring's back edges are chained: two phases")
        }
        print("F2.1 NOSKIP walk on a chained register ring: " + tally.line)
    }

    // MARK: - The session's refusals

    func testF2SessionRefusesATopologyChangeAndKeepsE5FRefusals() throws {
        let (t, fs) = try e2Trio { self.floodChain($0, m: 20) }
        let b = t.b
        // A rank write through the engine inside the session: refused by name.
        var refusal = "(none)"
        do {
            try b.frontierSession { _ in
                b.tick(tickNumber: 0, rankOrderVerified: true)
                let before = b.readTruthStates()
                b.markRankTopologyDirty()
                b.tick(tickNumber: 1, rankOrderVerified: true)
                b.tick(tickNumber: 2, rankOrderVerified: true)
                XCTAssertEqual(b.readTruthStates(), before, "nothing ticked after the change")
            }
        } catch { refusal = "\(error)" }
        XCTAssertEqual(refusal, "frontier session refused: the graph's topology changed inside the session "
            + "(a slot, rank or back-edge writer dropped the session's reverse index); tick 2 of the session "
            + "and every later one ticked nothing")
        // An index dropped (a slot writer) found when the session closes.
        refusal = "(none)"
        do { try b.frontierSession { _ in b.tick(tickNumber: 3, rankOrderVerified: true); b.dropFrontierIndex() } }
        catch { refusal = "\(error)" }
        XCTAssertEqual(refusal, "frontier session refused: the graph's topology changed inside the session "
            + "(a slot, rank or back-edge writer dropped the session's reverse index), found when the session closed")
        // A back edge added inside: the counting session's own refusal, first.
        refusal = "(none)"
        do {
            try b.frontierSession { _ in
                b.tick(tickNumber: 4, rankOrderVerified: true)
                try b.addBackEdge(src: 105, dst: 60)
                b.tick(tickNumber: 5, rankOrderVerified: true)
            }
        } catch { refusal = "\(error)" }
        XCTAssertTrue(refusal.hasPrefix("counting session refused: the back-edge layout changed inside the session"),
                      refusal)
        // Nested sessions: refused as the counting session refuses them.
        refusal = "(none)"
        try fs[2].handler.engine.frontierSession { _ in
            do { try fs[2].handler.engine.frontierSession { _ in } } catch { refusal = "\(error)" }
        }
        XCTAssertEqual(refusal, "counting session refused: a counting session is already open "
            + "(sessions do not nest); nothing ran")
        // A colour-path tick inside a session runs the plain path; the next
        // frontier tick is whole again.
        let e = t.a
        try e.frontierSession { _ in
            e.tick(tickNumber: 10, rankOrderVerified: true)
            XCTAssertTrue(e.lastTickFrontierFull)
            e.tick(tickNumber: 11, rankOrderVerified: true)
            XCTAssertTrue(e.lastTickFrontier); XCTAssertFalse(e.lastTickFrontierFull)
            e.tick(tickNumber: 12)
            XCTAssertFalse(e.lastTickFrontier, "the colour path is not the frontier")
            e.tick(tickNumber: 13, rankOrderVerified: true)
            XCTAssertTrue(e.lastTickFrontierFull, "whole again after a plain tick")
        }
    }

    // MARK: - Invalidation: every writer, then TICK UNTIL_STABLE

    /// A: as before the frontier session existed (the counting session, CPU latch). B: the handler's frontier seam.
    func f22Pair() throws -> (HandlerFixture, HandlerFixture) {
        let fa = try HandlerFixture(side: 16, dataRoot: tmp + "A")
        let fb = try HandlerFixture(side: 16, dataRoot: tmp + "B")
        for (f, root) in [(fa, "A"), (fb, "B")] {
            try FileManager.default.createDirectory(atPath: tmp + root, withIntermediateDirectories: true)
            try EngineE1DaemonTests.buildGraph(f.handler.engine, seed: 0xF22, ternary: true)
        }
        fa.handler.engine.latchOnGPU = false
        fb.handler.frontierUntilStableForTesting = true
        return (fa, fb)
    }

    func strip(_ r: String) -> String {
        r.split(separator: " ").filter { !$0.hasPrefix("elapsed=") && !$0.hasPrefix("path=")
            && !$0.hasPrefix("dir=") && !$0.hasPrefix("ratio=") }.joined(separator: " ")
    }

    /// Every lane the engine holds, hashed: a writer must change one (not vacuous).
    func digest(_ e: DagDBEngine) -> Int {
        var h = Hasher()
        let n = e.nodeCount
        for b in [e.truthStateBuf, e.rankBuf, e.lut6LowBuf, e.lut6HighBuf, e.neighborsBuf, e.edgeWeightsBuf,
                  e.nodeValueBuf, e.isRegisterBuf] {
            h.combine(Data(bytes: b.contents(), count: b.length))
        }
        if let v = e.ternaryLaneView {
            h.combine(Data(bytes: v.mode, count: n)); h.combine(Data(bytes: v.ttableId, count: 2 * n))
            h.combine(Data(bytes: v.thrLo, count: 4 * n)); h.combine(Data(bytes: v.thrHi, count: 4 * n))
        }
        h.combine(e.libraryBytes()); h.combine(e.backEdgeSrcs); h.combine(e.backEdgeDsts)
        return h.finalize()
    }

    enum Kind: String { case topology, table, mode, truth, tick, read }

    struct Writer {
        let name: String
        let kind: Kind
        /// Prepares the shm (if any) of the fixture and returns the command line.
        let make: (HandlerFixture) throws -> String
    }

    func source(seed: UInt64) throws -> DagDBEngine {
        let e = try DagDBEngine(grid: try HexGrid(width: 16, height: 16), state: DagDBState(width: 16, height: 16),
                                maxRank: 8)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        try EngineE1DaemonTests.buildGraph(e, seed: seed, ternary: true)
        return e
    }

    /// The enumerated writers (DSLCommand, every case that writes the primary
    /// engine), plus three tick verbs and three reads.
    func writers() -> [Writer] {
        let n = 256
        func rows(_ f: HandlerFixture, _ verb: SHM1Verb, _ r: [(UInt32, UInt32)]) {
            f.shm.storeBytes(of: UInt32(r.count), toByteOffset: 0, as: UInt32.self)
            f.shm.storeBytes(of: shm1Word1(verb), toByteOffset: 4, as: UInt32.self)
            for (i, x) in r.enumerated() {
                f.shm.storeBytes(of: x.0, toByteOffset: 8 + 8 * i, as: UInt32.self)
                f.shm.storeBytes(of: x.1, toByteOffset: 12 + 8 * i, as: UInt32.self)
            }
        }
        // The graph of `EngineE1DaemonTests.buildGraph`: ranks 0..7 by blocks of 32 ids; registers 224..235 (rank
        // 7, no slots) fed by back edges; ternary nodes at 3, 8, 13, … (< 224).
        let table729 = String((0..<729).map { i in ["-", "0", "+"][(i * 7 + 1) % 3] })
        let t2 = (0..<729).map { i -> UInt8 in UInt8((i * 5 + 2) % 3) }
        return [
            // ── topology: slots / edges ──
            Writer(name: "CONNECT", kind: .topology) { f in
                // rank 1 node 40 reads rank-2 node 70 (free slot, no duplicate).
                let nb = f.handler.engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
                var dst = 40
                while (0..<6).allSatisfy({ nb[dst * 6 + $0] >= 0 }) || (0..<6).contains(where: { nb[dst * 6 + $0] == 70 }) { dst += 1 }
                return "CONNECT FROM 70 TO \(dst)"
            },
            Writer(name: "CLEAR EDGES", kind: .topology) { _ in "CLEAR 41 EDGES" },
            Writer(name: "SET_NEIGHBORS_BULK", kind: .topology) { f in
                let nb = f.handler.engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
                for i in 0..<(n * 6) { f.shm.storeBytes(of: nb[i], toByteOffset: 8 + 4 * i, as: Int32.self) }
                for d in 0..<6 { f.shm.storeBytes(of: Int32(-1), toByteOffset: 8 + 4 * (42 * 6 + d), as: Int32.self) }
                f.shm.storeBytes(of: Int32(100), toByteOffset: 8 + 4 * (42 * 6), as: Int32.self)   // 42 (rank 1) reads 100 (rank 3)
                shm1Header(f.shm, count: n, verb: .setNeighborsBulk)
                return "SET_NEIGHBORS_BULK"
            },
            // ── topology: ranks ──
            Writer(name: "SET RANK", kind: .topology) { _ in "SET 255 RANK 8" },
            Writer(name: "SET_RANKS_BULK", kind: .topology) { f in
                let r = f.handler.engine.readRanks()
                for i in 0..<n { f.shm.storeBytes(of: r[i] + 1, toByteOffset: 8 + 8 * i, as: UInt64.self) }
                shm1Header(f.shm, count: n, verb: .setRanksBulk)
                return "SET_RANKS_BULK"
            },
            // ── topology: back edges and register flags ──
            Writer(name: "CONNECT BACK", kind: .topology) { _ in "CONNECT BACK FROM 10 TO 240" },
            Writer(name: "CLEAR BACK_EDGES", kind: .topology) { _ in "CLEAR 226 BACK_EDGES" },
            Writer(name: "CONNECT_BACK_BULK", kind: .topology) { f in rows(f, .connectBackBulk, [(11, 241), (77, 242)]); return "CONNECT_BACK_BULK" },
            // ── topology: loaders (every lane) ──
            Writer(name: "LOAD", kind: .topology) { f in
                let p = f.handler.dataRoot! + "/src.dags"
                if !FileManager.default.fileExists(atPath: p) {
                    _ = try DagDBSnapshot.save(engine: try self.source(seed: 0xF2A1), nodeCount: n, gridW: 16, gridH: 16,
                                               tickCount: 3, path: p)
                }
                return "LOAD \(p)"
            },
            Writer(name: "IMPORT MORTON", kind: .topology) { f in
                let d = f.handler.dataRoot! + "/src-morton"
                if !FileManager.default.fileExists(atPath: d) {
                    _ = try DagDBSnapshot.exportMorton(engine: try self.source(seed: 0xF2A2), nodeCount: n, dir: d)
                }
                return "IMPORT MORTON \(d)"
            },
            Writer(name: "LOAD JSON", kind: .topology) { f in
                let p = f.handler.dataRoot! + "/src.json"
                if !FileManager.default.fileExists(atPath: p) {
                    _ = try DagDBJSONIO.saveJSON(engine: try self.source(seed: 0xF2A3), nodeCount: n, gridW: 16, gridH: 16,
                                                 tickCount: 3, path: p)
                }
                return "LOAD JSON \(p)"
            },
            Writer(name: "LOAD CSV", kind: .topology) { f in
                let d = f.handler.dataRoot! + "/src-csv"
                if !FileManager.default.fileExists(atPath: d) {
                    _ = try DagDBJSONIO.saveCSV(engine: try self.source(seed: 0xF2A4), nodeCount: n, dir: d)
                }
                return "LOAD CSV \(d)"
            },
            Writer(name: "BACKUP RESTORE", kind: .topology) { f in
                let d = f.handler.dataRoot! + "/src-backup"
                if !FileManager.default.fileExists(atPath: d) {
                    _ = try DagDBBackup.initializeChain(engine: try self.source(seed: 0xF2A5), nodeCount: n,
                                                        gridW: 16, gridH: 16, tickCount: 3, dir: d)
                }
                return "BACKUP RESTORE \(d)"
            },
            // ── tables and rule parameters ──
            Writer(name: "SET LUT", kind: .table) { _ in "SET 70 LUT 96696996F00FF00F" },
            Writer(name: "SET_LUTS_BULK", kind: .table) { f in
                let lo = f.handler.engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
                let hi = f.handler.engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
                for i in 0..<n {
                    let v = (UInt64(hi[i]) << 32 | UInt64(lo[i])) ^ (i % 3 == 0 ? 0xFFFF_0000_FFFF_0000 : 0)
                    f.shm.storeBytes(of: v, toByteOffset: 8 + 8 * i, as: UInt64.self)
                }
                shm1Header(f.shm, count: n, verb: .setLutsBulk)
                return "SET_LUTS_BULK"
            },
            Writer(name: "COMPOSE (binary)", kind: .table) { _ in "COMPOSE NOT 70 INTO 71" },
            Writer(name: "COMPOSE (tables)", kind: .table) { f in
                let e = f.handler.engine
                let tt = (0..<224).filter { e.modeByte($0) & 3 == 1 }
                return "COMPOSE NOT \(tt[0]) INTO \(tt[1])"
            },
            Writer(name: "TTABLE DEFINE", kind: .table) { _ in "TTABLE DEFINE 0 \(table729)" },
            Writer(name: "TTABLE PRESET", kind: .table) { _ in "TTABLE PRESET 1 TMAX 6" },
            Writer(name: "TTABLE_BULK", kind: .table) { f in
                for (i, b) in t2.enumerated() { f.shm.storeBytes(of: b, toByteOffset: 8 + i, as: UInt8.self) }
                shm1Header(f.shm, count: 1, verb: .ttableBulk)
                return "TTABLE_BULK 0 1"
            },
            Writer(name: "SET TTABLE", kind: .table) { f in
                let e = f.handler.engine
                let tt = (0..<224).filter { e.modeByte($0) & 3 == 1 }
                return "SET \(tt[2]) TTABLE \(1 - Int(e.ttableIdPtr[tt[2]]))"
            },
            Writer(name: "SET_TTABLE_IDS_BULK", kind: .table) { f in
                let e = f.handler.engine
                for i in 0..<n {
                    let v: UInt16 = e.modeByte(i) & 3 == 1 ? 1 - e.ttableIdPtr[i] : e.ttableIdPtr[i]
                    f.shm.storeBytes(of: v, toByteOffset: 8 + 2 * i, as: UInt16.self)
                }
                shm1Header(f.shm, count: n, verb: .setTTableIdsBulk)
                return "SET_TTABLE_IDS_BULK"
            },
            Writer(name: "SET THRESH", kind: .table) { f in
                let e = f.handler.engine
                let th = (0..<224).filter { e.modeByte($0) & 3 == 2 }
                return "SET \(th[0]) THRESH -0.25 0.25"
            },
            Writer(name: "SET_THRESH_BULK", kind: .table) { f in
                for i in 0..<n {
                    f.shm.storeBytes(of: Float(-0.75), toByteOffset: 8 + 8 * i, as: Float.self)
                    f.shm.storeBytes(of: Float(0.5), toByteOffset: 12 + 8 * i, as: Float.self)
                }
                shm1Header(f.shm, count: n, verb: .setThreshBulk)
                return "SET_THRESH_BULK"
            },
            Writer(name: "SET WEIGHT", kind: .table) { f in
                let e = f.handler.engine
                let th = (0..<224).filter { e.modeByte($0) & 3 == 2 }
                return "SET \(th[1]) WEIGHT 0 -2.5"
            },
            Writer(name: "SET VALUE", kind: .table) { _ in "SET 70 VALUE 0.75" },
            // ── modes ──
            Writer(name: "SET MODE", kind: .mode) { f in
                let e = f.handler.engine
                let tr = e.readTruthStates()
                let i = (0..<224).first { e.modeByte($0) == 0 && tr[$0] < 3 && !e.isRegister(node: UInt32($0)) && $0 >= 32 }!
                return "SET \(i) MODE TTHRESH NOSKIP"
            },
            Writer(name: "SET_MODES_BULK", kind: .mode) { f in
                let e = f.handler.engine
                let tr = e.readTruthStates()
                for i in 0..<n {
                    var m = e.modeByte(i)
                    if m & 3 != 0 { m ^= 4 }                                   // NOSKIP flipped on every ternary node
                    else if i % 7 == 0 && tr[i] < 3 && !e.isRegister(node: UInt32(i)) && i < 224 { m = 2 }
                    f.shm.storeBytes(of: m, toByteOffset: 8 + i, as: UInt8.self)
                }
                shm1Header(f.shm, count: n, verb: .setModesBulk)
                return "SET_MODES_BULK"
            },
            // ── truth ──
            Writer(name: "SET TRUTH", kind: .truth) { _ in "SET 229 TRUTH 200" },
            Writer(name: "SET_TRUTH_BULK", kind: .truth) { f in rows(f, .setTruthBulk, [(1, 1), (40, 0), (230, 1), (231, 0)]); return "SET_TRUTH_BULK" },
            Writer(name: "SET TRIT", kind: .truth) { f in
                let e = f.handler.engine
                let tt = (0..<224).filter { e.modeByte($0) & 3 == 1 }
                return "SET \(tt[3]) TRIT \(e.readTruthStates()[tt[3]] == 0 ? 1 : -1)"
            },
            // ── tick verbs ──
            Writer(name: "TICK 3", kind: .tick) { _ in "TICK 3" },
            Writer(name: "TICK_SYNC 1", kind: .tick) { _ in "TICK_SYNC 1" },
            Writer(name: "EVAL", kind: .tick) { _ in "EVAL" },
            // ── reads (kept; listed so the counter shows them) ──
            Writer(name: "BFS_DEPTHS", kind: .read) { _ in "BFS_DEPTHS FROM 5" },
            Writer(name: "SAVE", kind: .read) { f in "SAVE \(f.handler.dataRoot!)/r.dags" },
            Writer(name: "VALIDATE", kind: .read) { _ in "VALIDATE" },
        ]
    }

    /// Runs each writer between two UNTIL_STABLEs; returns the per-writer lines.
    func runWriters(max: Int = 25, file: StaticString = #filePath, line: UInt = #line) throws
        -> (lines: [String], mismatches: Int, failedWriters: [String]) {
        var lines: [String] = [], mismatches = 0, failed: [String] = []
        for w in writers() {
            let (fa, fb) = try f22Pair()
            let b = fb.handler.engine
            let r0a = fa.handler.handle("TICK UNTIL_STABLE MAX \(max)"), r0b = fb.handler.handle("TICK UNTIL_STABLE MAX \(max)")
            XCTAssertEqual(strip(r0a), strip(r0b), "\(w.name): the first UNTIL_STABLE", file: file, line: line)
            XCTAssertTrue(b.lastTickFrontier, "\(w.name): B ticked through the frontier", file: file, line: line)
            XCTAssertEqual(b.frontierIndexBuildCount, 1, w.name, file: file, line: line)
            let dA = digest(fa.handler.engine)
            let ca = fa.handler.handle(try w.make(fa)), cb = fb.handler.handle(try w.make(fb))
            XCTAssertTrue(ca.hasPrefix("OK"), "\(w.name): \(ca)", file: file, line: line)
            XCTAssertEqual(strip(ca).components(separatedBy: "elapsed")[0], strip(cb).components(separatedBy: "elapsed")[0],
                           w.name, file: file, line: line)
            let changed = digest(fa.handler.engine) != dA
            if w.kind != .read && w.kind != .tick {
                XCTAssertTrue(changed, "\(w.name): the writer must change the engine (not vacuous)", file: file, line: line)
            }
            let kept = b.hasFrontierIndex
            let expectKept = w.kind != .topology
            XCTAssertEqual(kept, expectKept, "\(w.name): index kept", file: file, line: line)
            let r1a = fa.handler.handle("TICK UNTIL_STABLE MAX \(max)"), r1b = fb.handler.handle("TICK UNTIL_STABLE MAX \(max)")
            XCTAssertTrue(r1a.hasPrefix("OK TICK UNTIL_STABLE"), "\(w.name): \(r1a)", file: file, line: line)
            let equal = strip(r1a) == strip(r1b)
            let d = differing(fa.handler.engine, b)
            XCTAssertTrue(equal, "\(w.name): UNTIL_STABLE after the writer: A '\(r1a)' B '\(r1b)'", file: file, line: line)
            XCTAssertEqual(d, 0, "\(w.name): truth bytes after the UNTIL_STABLE", file: file, line: line)
            XCTAssertEqual(fa.handler.tickCount, fb.handler.tickCount, w.name, file: file, line: line)
            XCTAssertTrue(b.lastTickFrontier, "\(w.name): B's second UNTIL_STABLE ticked through the frontier",
                          file: file, line: line)
            let builds = b.frontierIndexBuildCount
            XCTAssertEqual(builds, expectKept ? 1 : 2, "\(w.name): index builds after the writer", file: file, line: line)
            // A third UNTIL_STABLE with no writer between: the index is reused.
            let r2a = fa.handler.handle("TICK UNTIL_STABLE MAX 5"), r2b = fb.handler.handle("TICK UNTIL_STABLE MAX 5")
            XCTAssertEqual(strip(r2a), strip(r2b), w.name, file: file, line: line)
            XCTAssertEqual(b.frontierIndexBuildCount, builds, "\(w.name): no writer, no rebuild", file: file, line: line)
            let sa = fa.handler.handle("SAVE \(fa.handler.dataRoot!)/end.dags"), sb = fb.handler.handle("SAVE \(fb.handler.dataRoot!)/end.dags")
            let saveEqual = sa.hasPrefix("OK") && FileManager.default.contents(atPath: fa.handler.dataRoot! + "/end.dags")
                == FileManager.default.contents(atPath: fb.handler.dataRoot! + "/end.dags")
            XCTAssertTrue(saveEqual, "\(w.name): SAVE bytes equal (\(sa) / \(sb))", file: file, line: line)
            let bad = !equal || d != 0 || !saveEqual || strip(r2a) != strip(r2b)
            if bad { mismatches += 1; failed.append(w.name) }
            lines.append("\(w.name) [\(w.kind.rawValue)]: index kept \(kept), builds \(builds), engine changed \(changed), "
                         + "reply equal \(equal), bytes differing \(d), save equal \(saveEqual); '\(strip(r1a))'")
        }
        return (lines, mismatches, failed)
    }

    func testF2_2EveryWriterThenUntilStableEqualsPreF() throws {
        let (lines, mismatches, failed) = try runWriters()
        for l in lines { print("F2.2 " + l) }
        let ws = writers()
        print("F2.2 writers: \(ws.count) (topology \(ws.filter { $0.kind == .topology }.count), "
              + "table \(ws.filter { $0.kind == .table }.count), mode \(ws.filter { $0.kind == .mode }.count), "
              + "truth \(ws.filter { $0.kind == .truth }.count), tick \(ws.filter { $0.kind == .tick }.count), "
              + "read \(ws.filter { $0.kind == .read }.count)); mismatching writers \(mismatches) \(failed)")
        XCTAssertEqual(mismatches, 0)
    }

    /// The control case: a back edge added between two
    /// UNTIL_STABLEs, the second run longer, so a stale index (the new
    /// register never latched) shows.
    func testF2_2ConnectBackBetweenTwoUntilStables() throws {
        var mismatches = 0
        for (s, d) in [(10, 240), (70, 243), (150, 244)] {
            let (fa, fb) = try f22Pair()
            for f in [fa, fb] { XCTAssertTrue(f.handler.handle("TICK UNTIL_STABLE MAX 10").hasPrefix("OK")) }
            for f in [fa, fb] { XCTAssertEqual(f.handler.handle("CONNECT BACK FROM \(s) TO \(d)"), "OK CONNECT BACK from=\(s) to=\(d)") }
            let ra = fa.handler.handle("TICK UNTIL_STABLE MAX 30"), rb = fb.handler.handle("TICK UNTIL_STABLE MAX 30")
            let dd = differing(fa.handler.engine, fb.handler.engine)
            if strip(ra) != strip(rb) || dd != 0 { mismatches += 1 }
            XCTAssertEqual(strip(ra), strip(rb), "CONNECT BACK \(s)→\(d)")
            XCTAssertEqual(dd, 0, "CONNECT BACK \(s)→\(d): bytes")
            XCTAssertEqual(fb.handler.engine.frontierIndexBuildCount, 2)
        }
        print("F2.2 CONNECT BACK between two UNTIL_STABLEs: 3 cases, mismatching \(mismatches)")
    }

    // MARK: - Memory

    func testF2_3AllocationBytesNamedAndZeroWithoutASession() throws {
        let lay = VoxelA(n: 16)
        let field = lay.field(seed: 0xF23)
        let e = try lay.makeEngine(field: field, ternary: false)
        func frontierBytes() -> [String: Int] {
            var d: [String: Int] = [:]
            for (k, v) in e.allocationBytes() where k.hasPrefix("frontier.") { d[k] = v }
            return d
        }
        let names = ["frontier.csrOffsets", "frontier.csrEntries", "frontier.lists", "frontier.bits",
                     "frontier.latchLists", "frontier.latchBits", "frontier.counters", "frontier.rankInfo",
                     "frontier.meta", "frontier.evaluatedSeeds"]
        XCTAssertEqual(Set(frontierBytes().keys), Set(names))
        // Plain ticks and a counting session: no frontier bytes.
        for t in 0..<3 { e.tick(tickNumber: UInt32(t), rankOrderVerified: true) }
        try e.countingLatchChanges { _ in e.tick(tickNumber: 3, rankOrderVerified: true) }
        XCTAssertEqual(frontierBytes().values.reduce(0, +), 0, "0 bytes on an engine that never opened a session")
        XCTAssertEqual(e.frontierIndexBuildCount, 0)
        // A session: every buffer by formula.
        let n = e.nodeCount, L = e.effectiveRankCount
        var slots = 0
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        for i in 0..<(n * 6) where nb[i] >= 0 && Int(nb[i]) < n { slots += 1 }
        let m = Set(e.backEdgeDsts).count
        var during: [String: Int] = [:]
        try e.frontierSession { _ in
            e.tick(tickNumber: 4, rankOrderVerified: true)
            during = frontierBytes()
        }
        let want: [String: Int] = [
            "frontier.csrOffsets": (n + 1) * 4, "frontier.csrEntries": (slots + m) * 4,
            "frontier.lists": 2 * n * 4, "frontier.bits": 2 * ((n + 31) / 32) * 4,
            "frontier.latchLists": 2 * m * 4, "frontier.latchBits": 2 * ((m + 31) / 32) * 4,
            "frontier.counters": (2 * L + 4) * 4, "frontier.rankInfo": (3 * L + 1) * 4,
            "frontier.meta": (5 * L + 5) * 4, "frontier.evaluatedSeeds": 0]
        XCTAssertEqual(during, want)
        let total = during.values.reduce(0, +)
        let latch = e.allocationBytes().filter { $0.name.hasPrefix("latch.") }.reduce(0) { $0 + $1.bytes }
        print(String(format: "F2.3 voxel layout A 16³ (%d nodes, %d slots, %d back edges, %d ranks): frontier %d bytes "
                     + "(%.3f B/node), with F1's plan %d bytes (%.3f B/node)", n, slots, m, L, total,
                     Double(total) / Double(n), total + latch, Double(total + latch) / Double(n)))
        // Kept after the session (the index and its buffers; the state is reset
        // at the next open), dropped by a topology write.
        XCTAssertEqual(frontierBytes().values.reduce(0, +), total - during["frontier.evaluatedSeeds"]!)
        e.markRankTopologyDirty()
        XCTAssertEqual(frontierBytes().values.reduce(0, +), 0, "a rank write drops the index and its buffers")
    }
}
