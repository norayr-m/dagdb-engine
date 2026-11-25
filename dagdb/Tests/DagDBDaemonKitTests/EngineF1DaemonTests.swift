import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// The back-edge latch on the GPU. Equivalence.
///
/// Twins tick the same graph. A latches on the CPU (`latchOnGPU = false`: the
/// plain latch `latchBackEdges`, or inside a counting session the counting
/// latch) and is the reference; B latches on the GPU (`latchOnGPU = true`).
/// After every tick the truth bytes (ternary nodes' bytes included) must be
/// equal, and inside a counting session the latch's `lastCount` and the
/// tick's `lastChanged` must be equal too. Cases: the graph builder of
/// `EngineE1DaemonTests` (sides
/// 16/24/32, binary and ternary, with extra, duplicate and kernel-evaluated
/// back-edge destinations), a chain of 5 back edges (the destination of one is
/// the source of the next) listed head-first and tail-first, duplicate back
/// edges into one register in both orders, a register whose source is itself
/// a kernel-evaluated destination (the cleared-flag case), and 300 seeds of
/// a fuzzer's mix ported in-process. Plus the policy (plain TICK at
/// 65,536 back edges, every counting session) and the plan's cache.
///
/// Each test prints its tick and mismatch totals, so a control run (a line of
/// the GPU latch changed in the worktree) is read from the same lines.
final class EngineF1DaemonTests: XCTestCase {

    typealias Rng = EngineE1DaemonTests.Rng

    private var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "engine-f1-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - Helpers

    /// Running totals of one test, printed at its end.
    struct Tally {
        var ticks = 0               // ticks compared
        var mismatchTicks = 0       // ticks whose truth bytes differed
        var mismatchBytes = 0       // truth bytes that differed, summed over ticks
        var countMismatches = 0     // session ticks whose lastCount or lastChanged differed
        var gpuTicks = 0            // B's ticks whose latch ran on the GPU
        var twoPhaseTicks = 0       // of those, two-phase
        var moved = 0               // truth bytes the ticks changed (A, before vs after)
        var latched = 0             // registers the session latches changed (A's lastCount)
        var line: String {
            "ticks \(ticks), mismatching ticks \(mismatchTicks), mismatching bytes \(mismatchBytes), "
                + "count mismatches \(countMismatches); B on the GPU \(gpuTicks) (two-phase \(twoPhaseTicks)); "
                + "bytes moved \(moved), registers latched in sessions \(latched)"
        }
    }

    /// Truth bytes that differ between the two engines.
    func differing(_ a: DagDBEngine, _ b: DagDBEngine) -> Int {
        let n = a.nodeCount
        let pa = a.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let pb = b.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        var d = 0
        for i in 0..<n where pa[i] != pb[i] { d += 1 }
        return d
    }

    /// One tick on both engines (rank mode, as the daemon's TICK), compared.
    func tickBoth(_ a: DagDBEngine, _ b: DagDBEngine, _ t: UInt32, _ tally: inout Tally, _ label: String) {
        let before = a.readTruthStates()
        a.tick(tickNumber: t, rankOrderVerified: true)
        b.tick(tickNumber: t, rankOrderVerified: true)
        let after = a.readTruthStates()
        for i in 0..<before.count where before[i] != after[i] { tally.moved += 1 }
        noteLatch(a, b, &tally, label)
        let d = differing(a, b)
        tally.ticks += 1
        if d != 0 { tally.mismatchTicks += 1; tally.mismatchBytes += d }
        XCTAssertEqual(d, 0, "\(label) tick \(t): truth bytes differ (GPU latch vs CPU latch)")
    }

    func noteLatch(_ a: DagDBEngine, _ b: DagDBEngine, _ tally: inout Tally, _ label: String) {
        XCTAssertFalse(a.lastLatchOnGPU, "\(label): the reference latched on the CPU")
        if b.backEdgeCount > 0 {
            XCTAssertTrue(b.lastLatchOnGPU, "\(label): B latched on the GPU")
            if b.lastLatchOnGPU { tally.gpuTicks += 1; if b.lastLatchTwoPhase { tally.twoPhaseTicks += 1 } }
        }
    }

    /// `plain` plain ticks, then a counting session of `counted` ticks on both
    /// engines, every tick compared; in the session also the two counts.
    func run(_ a: DagDBEngine, _ b: DagDBEngine, plain: Int, counted: Int, _ tally: inout Tally,
             _ label: String) throws {
        a.latchOnGPU = false
        b.latchOnGPU = true
        var t: UInt32 = 0
        for _ in 0..<plain { tickBoth(a, b, t, &tally, label + " plain"); t += 1 }
        var local = tally
        try a.countingLatchChanges { ca in
            try b.countingLatchChanges { cb in
                for _ in 0..<counted {
                    ca.lastCount = 0; cb.lastCount = 0
                    tickBoth(a, b, t, &local, label + " session")
                    XCTAssertTrue(a.lastRankTickCounted); XCTAssertTrue(b.lastRankTickCounted)
                    if ca.lastCount != cb.lastCount || ca.lastChanged != cb.lastChanged { local.countMismatches += 1 }
                    XCTAssertEqual(cb.lastCount, ca.lastCount, "\(label) session tick \(t): lastCount")
                    XCTAssertEqual(cb.lastChanged, ca.lastChanged, "\(label) session tick \(t): lastChanged")
                    local.latched += ca.lastCount
                    t += 1
                }
            }
        }
        tally = local
    }

    /// The graph of `EngineE1DaemonTests.buildGraph`, plus: `extra` back edges
    /// into binary no-fan-in nodes from any source (so a source can be a
    /// destination: two-phase), a duplicate destination (`dup`), a few truth
    /// bytes >= 3, and `evaluated` destinations whose register flag is cleared
    /// (the kernel evaluates them before the latch overwrites them).
    func e1Graph(side: Int, seed: UInt64, ternary: Bool, extra: Bool, dup: Bool, evaluated: Int) throws
        -> HandlerFixture {
        let f = try HandlerFixture(side: side)
        let e = f.handler.engine
        try EngineE1DaemonTests.buildGraph(e, seed: seed, ternary: ternary)
        let n = e.nodeCount
        var g = Rng(s: seed &+ 0xF1)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        if extra {
            let free = (0..<n).filter { i in
                !TernaryReference.isTernary(e.modeByte(i)) && (0..<6).allSatisfy { nb[i * 6 + $0] < 0 }
            }
            for _ in 0..<min(24, free.count) {
                let d = free[g.below(free.count)], s = g.below(n)
                if s != d { try e.addBackEdge(src: UInt32(s), dst: UInt32(d)) }
            }
        }
        if dup, let d0 = e.backEdgeDsts.first, let d1 = e.backEdgeDsts.dropFirst(3).first {
            try e.addBackEdge(src: UInt32(g.below(n)), dst: d0)      // two edges, one register
            try e.addBackEdge(src: UInt32(g.below(n)), dst: d1)
            try e.addBackEdge(src: UInt32(g.below(n)), dst: d0)      // three into d0
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
        try e.prepareRankLists()
        return f
    }

    // MARK: - The graphs of `EngineE1DaemonTests.buildGraph`

    func testF1E1GraphsGPULatchEqualsCPULatch() throws {
        var tally = Tally(), cells = 0
        for side in [16, 24, 32] {
            for ternary in [false, true] {
                for seed: UInt64 in [1, 2, 3] {
                    for (extra, dup, ev) in [(false, false, 0), (true, false, 0), (true, true, 0), (true, true, 3)] {
                        let s = seed &* 0x51 &+ UInt64(side) &+ (ternary ? 7000 : 0)
                        let fa = try e1Graph(side: side, seed: s, ternary: ternary, extra: extra, dup: dup, evaluated: ev)
                        let fb = try e1Graph(side: side, seed: s, ternary: ternary, extra: extra, dup: dup, evaluated: ev)
                        try run(fa.handler.engine, fb.handler.engine, plain: 12, counted: 12, &tally,
                                "E1 side \(side) ternary \(ternary) seed \(s) extra \(extra) dup \(dup) ev \(ev)")
                        cells += 1
                    }
                }
            }
        }
        print("F1.1 E1 graphs: \(cells) cells; " + tally.line)
        XCTAssertGreaterThan(tally.moved, 0, "not vacuous")
        XCTAssertGreaterThan(tally.latched, 0, "not vacuous: the latch changed registers")
        XCTAssertGreaterThan(tally.twoPhaseTicks, 0, "some cell has a source that is a destination")
        XCTAssertLessThan(tally.twoPhaseTicks, tally.gpuTicks, "and some has none (one kernel)")
    }

    /// The same, B's kernels compiled from the inline source (the forced
    /// inline-shader path), A's from the bundle: the latch kernels exist in both sources.
    func testF1InlineShaderLatchEqualsBundleCPULatch() throws {
        var tally = Tally()
        for ternary in [false, true] {
            for seed: UInt64 in [11, 12] {
                let side = 24
                let fa = try e1Graph(side: side, seed: seed, ternary: ternary, extra: true, dup: true, evaluated: 0)
                let b = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                        state: DagDBState(width: side, height: side), maxRank: 8,
                                        shaderLibrary: .inlineSource)
                XCTAssertTrue(b.usedInlineShader)
                // B: the same graph, built the same way on an inline engine.
                try EngineE1DaemonTests.buildGraph(b, seed: seed, ternary: ternary)
                let g = try e1Graph(side: side, seed: seed, ternary: ternary, extra: true, dup: true, evaluated: 0)
                b.backEdgeSrcs = g.handler.engine.backEdgeSrcs
                b.backEdgeDsts = g.handler.engine.backEdgeDsts
                memcpy(b.isRegisterBuf.contents(), g.handler.engine.isRegisterBuf.contents(), b.nodeCount)
                memcpy(b.truthStateBuf.contents(), g.handler.engine.truthStateBuf.contents(), b.nodeCount)
                XCTAssertEqual(differing(fa.handler.engine, b), 0)
                try b.prepareRankLists()
                try run(fa.handler.engine, b, plain: 10, counted: 10, &tally, "inline ternary \(ternary) seed \(seed)")
            }
        }
        print("F1.1 inline shader: " + tally.line)
        XCTAssertGreaterThan(tally.gpuTicks, 0)
    }

    // MARK: - A chain of 5 back edges

    /// Head h (rank 8) = NOT of n5 (rank 9); registers n1…n5 with back edges
    /// h→n1, n1→n2, …, n4→n5 — the destination of each is the source of the
    /// next. Listed head-first (a single-phase latch done in list order
    /// writes through every link) or tail-first. The chain's bytes
    /// start alternating 0/1, so a write-through is always visible.
    func chain(headFirst: Bool, ternaryBackground: Bool) throws -> HandlerFixture {
        let f = try HandlerFixture(side: 16)
        let h = f.handler
        if ternaryBackground {
            try EngineE1DaemonTests.buildGraph(h.engine, seed: 0xC4A1, ternary: true)
            for d in Set(h.engine.backEdgeDsts) { try h.engine.clearBackEdges(toNode: d) }
        }
        let head = 200, regs = Array(201...205)          // n1…n5
        for i in 200...205 { XCTAssertTrue(h.handle("CLEAR \(i) EDGES").hasPrefix("OK")) }
        for r in regs { XCTAssertTrue(h.handle("SET \(r) MODE BINARY").hasPrefix("OK")) }
        XCTAssertTrue(h.handle("SET \(head) MODE BINARY").hasPrefix("OK"))
        // Ranks above the eight levels of `EngineE1DaemonTests.buildGraph`, so every reader of a chain node (rank
        // <= 7) still reads a strictly higher rank; n5 above the head.
        for r in regs { XCTAssertTrue(h.handle("SET \(r) RANK 9").hasPrefix("OK")) }
        XCTAssertTrue(h.handle("SET \(head) RANK 8").hasPrefix("OK"))
        XCTAssertTrue(h.handle("SET \(head) LUT 5555555555555555").hasPrefix("OK"))   // NOT of slot 0
        XCTAssertTrue(h.handle("CONNECT FROM \(regs[4]) TO \(head)").hasPrefix("OK"))
        var links = [(head, regs[0])]
        for k in 0..<4 { links.append((regs[k], regs[k + 1])) }
        if !headFirst { links.reverse() }
        for (s, d) in links {
            let r = h.handle("CONNECT BACK FROM \(s) TO \(d)")
            XCTAssertEqual(r, "OK CONNECT BACK from=\(s) to=\(d)")
        }
        for (k, r) in regs.enumerated() { XCTAssertTrue(h.handle("SET \(r) TRUTH \((k + 1) % 2)").hasPrefix("OK")) }
        XCTAssertTrue(h.handle("SET \(head) TRUTH 0").hasPrefix("OK"))
        XCTAssertNil(h.rankTickDagRefusal())
        try h.engine.prepareRankLists()
        return f
    }

    func testF1ChainedBackEdgesGPULatchEqualsCPULatch() throws {
        var tally = Tally()
        for headFirst in [true, false] {
            for bg in [false, true] {
                let fa = try chain(headFirst: headFirst, ternaryBackground: bg)
                let fb = try chain(headFirst: headFirst, ternaryBackground: bg)
                var t = Tally()
                try run(fa.handler.engine, fb.handler.engine, plain: 40, counted: 40, &t,
                        "chain headFirst \(headFirst) background \(bg)")
                XCTAssertEqual(t.twoPhaseTicks, t.gpuTicks, "a chain is latched in two phases")
                XCTAssertEqual(t.gpuTicks, 80)
                tally.ticks += t.ticks; tally.mismatchTicks += t.mismatchTicks; tally.mismatchBytes += t.mismatchBytes
                tally.countMismatches += t.countMismatches; tally.gpuTicks += t.gpuTicks
                tally.twoPhaseTicks += t.twoPhaseTicks; tally.moved += t.moved; tally.latched += t.latched
            }
        }
        print("F1.1 chain of 5: " + tally.line)
        XCTAssertGreaterThan(tally.latched, 0, "not vacuous")
    }

    // MARK: - Duplicate back edges into one register, both orders

    /// Register r (rank 1); a = NOT r and b = r (rank 0, both read r); back
    /// edges a→r and b→r in `order`, plus a triple (a→q, b→q, a→q) into a
    /// second register q fed the same way. The last edge wins: with b last, r
    /// holds; with a last, r toggles — so "first wins" differs in both orders.
    func duplicates(aFirst: Bool) throws -> HandlerFixture {
        let f = try HandlerFixture(side: 16)
        let h = f.handler
        let (r, a, b, q) = (50, 60, 61, 70)
        for (node, rank) in [(r, 1), (q, 1), (a, 0), (b, 0)] {
            XCTAssertTrue(h.handle("SET \(node) RANK \(rank)").hasPrefix("OK"))
        }
        XCTAssertTrue(h.handle("SET \(a) LUT 5555555555555555").hasPrefix("OK"))   // NOT slot 0
        XCTAssertTrue(h.handle("SET \(b) LUT AAAAAAAAAAAAAAAA").hasPrefix("OK"))   // slot 0
        XCTAssertTrue(h.handle("CONNECT FROM \(r) TO \(a)").hasPrefix("OK"))
        XCTAssertTrue(h.handle("CONNECT FROM \(r) TO \(b)").hasPrefix("OK"))
        let pair = aFirst ? [(a, r), (b, r)] : [(b, r), (a, r)]
        let triple = aFirst ? [(a, q), (b, q), (a, q)] : [(b, q), (a, q), (b, q)]
        for (s, d) in pair + triple {
            XCTAssertEqual(h.handle("CONNECT BACK FROM \(s) TO \(d)"), "OK CONNECT BACK from=\(s) to=\(d)")
        }
        XCTAssertTrue(h.handle("SET \(r) TRUTH 1").hasPrefix("OK"))
        XCTAssertNil(h.rankTickDagRefusal())
        try h.engine.prepareRankLists()
        return f
    }

    func testF1DuplicateBackEdgesBothOrders() throws {
        var tally = Tally()
        for aFirst in [true, false] {
            let fa = try duplicates(aFirst: aFirst), fb = try duplicates(aFirst: aFirst)
            try run(fa.handler.engine, fb.handler.engine, plain: 20, counted: 20, &tally, "duplicates aFirst \(aFirst)")
        }
        print("F1.1 duplicate back edges: " + tally.line)
        XCTAssertGreaterThan(tally.latched, 0, "not vacuous")
    }

    // MARK: - A register fed by a kernel-evaluated destination (the cleared-flag case of `EngineE5DaemonTests`)

    /// t (register, rank 1) and s = NOT t (rank 0): an oscillator, s→t. Back
    /// edges s→d1 and d1→d2; d1's register flag is then cleared (a raw write,
    /// the cleared-flag case of `EngineE5DaemonTests`), so the kernel evaluates d1 (no inputs: its
    /// LUT's bit 0, here 1) before the latch writes s into it, and d2's source
    /// is that kernel-evaluated destination.
    func evaluatedSource() throws -> HandlerFixture {
        let f = try HandlerFixture(side: 16)
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
        XCTAssertFalse(h.engine.isRegister(node: UInt32(d1)))
        XCTAssertNil(h.rankTickDagRefusal())
        try h.engine.prepareRankLists()
        return f
    }

    func testF1RegisterFedByKernelEvaluatedDestination() throws {
        var tally = Tally()
        let fa = try evaluatedSource(), fb = try evaluatedSource()
        try run(fa.handler.engine, fb.handler.engine, plain: 20, counted: 20, &tally, "evaluated source")
        XCTAssertEqual(tally.twoPhaseTicks, tally.gpuTicks, "d1 is a destination and a source")
        XCTAssertGreaterThan(tally.latched, 0, "not vacuous")
        print("F1.1 kernel-evaluated destination: " + tally.line)
        // Inside the graphs of `EngineE1DaemonTests.buildGraph` too, with three cleared flags (the variant of `EngineE5DaemonTests`).
        var e1 = Tally()
        for side in [16, 32] {
            let ga = try e1Graph(side: side, seed: 0xE5, ternary: true, extra: true, dup: true, evaluated: 3)
            let gb = try e1Graph(side: side, seed: 0xE5, ternary: true, extra: true, dup: true, evaluated: 3)
            try run(ga.handler.engine, gb.handler.engine, plain: 12, counted: 12, &e1, "E1 evaluated side \(side)")
        }
        print("F1.1 kernel-evaluated destinations in E1 graphs: " + e1.line)
        XCTAssertGreaterThan(e1.latched, 0, "not vacuous")
    }

    // MARK: - The policy and the plan's cache

    /// Plain TICK takes the GPU latch at >= 65,536 back edges and the CPU
    /// latch below; every counting session takes the GPU latch. The plan is built once per back-edge list and dropped by
    /// every change to it (CONNECT BACK, CLEAR BACK_EDGES, LOAD).
    func testF1PolicyAndPlanCache() throws {
        let side = 300                                     // 90,000 nodes; registers on 65,536 of them
        func build(_ edges: Int) throws -> HandlerFixture {
            let f = try HandlerFixture(side: side, dataRoot: tmp)
            let e = f.handler.engine
            var g = Rng(s: 0xF1F1)
            let n = e.nodeCount
            let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
            let low = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
            let high = e.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
            let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
            let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
            for i in 0..<n {
                let lut = g.next(); low[i] = UInt32(lut & 0xFFFF_FFFF); high[i] = UInt32(lut >> 32)
                truth[i] = UInt8(g.below(2))
                rank[i] = i < 65_536 ? 1 : 0
                if i >= 65_536 { for d in 0..<3 { nb[i * 6 + d] = Int32(g.below(65_536)) } }
            }
            e.markRankTopologyDirty()
            for k in 0..<edges { try e.addBackEdge(src: UInt32(65_536 + g.below(n - 65_536)), dst: UInt32(k)) }
            return f
        }
        for edges in [65_535, 65_536] {
            let fa = try build(edges), fb = try build(edges)
            fa.handler.engine.latchOnGPU = false
            XCTAssertNil(fb.handler.engine.latchOnGPU, "B: the policy")
            for _ in 0..<5 {
                XCTAssertTrue(fa.handler.handle("TICK 1").hasPrefix("OK TICK 1 "))
                XCTAssertTrue(fb.handler.handle("TICK 1").hasPrefix("OK TICK 1 "))
                XCTAssertEqual(fb.handler.engine.lastLatchOnGPU, edges >= 65_536, "plain TICK at \(edges) back edges")
                XCTAssertEqual(differing(fa.handler.engine, fb.handler.engine), 0, "plain TICK at \(edges)")
            }
            let ra = fa.handler.handle("TICK UNTIL_STABLE MAX 6"), rb = fb.handler.handle("TICK UNTIL_STABLE MAX 6")
            XCTAssertTrue(fb.handler.engine.lastLatchOnGPU, "a counting session latches on the GPU")
            XCTAssertEqual(strip(ra), strip(rb))
            XCTAssertEqual(differing(fa.handler.engine, fb.handler.engine), 0, "UNTIL_STABLE at \(edges)")
            print("F1 policy at \(edges) back edges: plain TICK on the GPU \(edges >= 65_536); UNTIL_STABLE '\(strip(rb))'")
        }
        // A small graph: plain TICK on the CPU, UNTIL_STABLE on the GPU.
        let small = try duplicates(aFirst: true)
        XCTAssertTrue(small.handler.handle("TICK 1").hasPrefix("OK TICK"))
        XCTAssertFalse(small.handler.engine.lastLatchOnGPU)
        XCTAssertEqual(small.handler.engine.latchPlanBuildCount, 0, "no plan for a CPU latch")
        XCTAssertTrue(small.handler.handle("TICK UNTIL_STABLE MAX 3").hasPrefix("OK TICK UNTIL_STABLE"))
        XCTAssertTrue(small.handler.engine.lastLatchOnGPU)
        XCTAssertEqual(small.handler.engine.latchPlanBuildCount, 1)
        // The cache: kept across ticks and verbs, rebuilt after each change to the list.
        let f = try HandlerFixture(side: 16, dataRoot: tmp)
        let h = f.handler, e = h.engine
        e.latchOnGPU = true
        floodChainF(f, m: 10)
        XCTAssertTrue(h.handle("TICK 3").hasPrefix("OK TICK 3"))
        XCTAssertTrue(h.handle("TICK UNTIL_STABLE").hasPrefix("OK TICK UNTIL_STABLE stable"))
        XCTAssertEqual(e.latchPlanBuildCount, 1, "one plan for one list")
        XCTAssertGreaterThan(e.allocationBytes().first { $0.name == "latch.effSrc" }?.bytes ?? 0, 0)
        var builds = 1
        for (cmd, changes) in [("SET 3 TRUTH 1", false), ("SET 20 LUT AND", false), ("CONNECT BACK FROM 105 TO 30", true),
                               ("CLEAR 30 BACK_EDGES", true), ("SAVE \(tmp!)/c.dags", false), ("CLEAR 2 BACK_EDGES", true),
                               ("LOAD \(tmp!)/c.dags", true)] {
            XCTAssertTrue(h.handle(cmd).hasPrefix("OK"), cmd)
            XCTAssertTrue(h.handle("TICK 2").hasPrefix("OK TICK 2"), cmd)
            if changes { builds += 1 }
            XCTAssertEqual(e.latchPlanBuildCount, builds, "after \(cmd)")
        }
    }

    /// The register chain of `EngineE2DaemonTests.floodChain`, as `EngineE5DaemonTests` copies it.
    func floodChainF(_ f: HandlerFixture, m: Int) {
        let h = f.handler
        for i in 0..<m {
            XCTAssertTrue(h.handle("SET \(i) RANK 1").hasPrefix("OK"))
            XCTAssertTrue(h.handle("SET \(100 + i) LUT OR").hasPrefix("OK"))
            if i > 0 { XCTAssertTrue(h.handle("CONNECT FROM \(i - 1) TO \(100 + i)").hasPrefix("OK")) }
            XCTAssertTrue(h.handle("CONNECT FROM \(i) TO \(100 + i)").hasPrefix("OK"))
            XCTAssertTrue(h.handle("CONNECT BACK FROM \(100 + i) TO \(i)").hasPrefix("OK"))
        }
        XCTAssertTrue(h.handle("SET 0 TRUTH 1").hasPrefix("OK"))
    }

    func strip(_ r: String) -> String {
        r.split(separator: " ").filter { !$0.hasPrefix("elapsed=") && !$0.hasPrefix("path=")
            && !$0.hasPrefix("dir=") && !$0.hasPrefix("ratio=") }.joined(separator: " ")
    }

    // MARK: - A random command mix, in-process (300 seeds)

    /// The fuzz's two daemons as two handlers: every command to both, replies
    /// compared with elapsed/path/dir stripped; after every tick-type step the
    /// truth bytes compared (after every single tick: `TICK k` is sent as k ×
    /// `TICK 1`), and the SAVE files' bytes. A latches on the CPU, B on the GPU.
    final class Twin {
        let a: HandlerFixture, b: HandlerFixture
        let rootA: String, rootB: String
        var seed: UInt64 = 0
        var cmds = 0, replyMismatches = 0, savesEqual = 0, saveMismatches = 0, stateChanged = 0
        var lastTruth: [UInt8] = []
        var saved = false, exported = false
        init(side: Int, root: String) throws {
            rootA = root + "/A"; rootB = root + "/B"
            for r in [rootA, rootB] { try FileManager.default.createDirectory(atPath: r, withIntermediateDirectories: true) }
            a = try HandlerFixture(side: side, dataRoot: rootA)
            b = try HandlerFixture(side: side, dataRoot: rootB)
            a.handler.engine.latchOnGPU = false
            b.handler.engine.latchOnGPU = true
        }
        static func norm(_ r: String) -> String {
            r.split(separator: " ").filter { !$0.hasPrefix("elapsed=") && !$0.hasPrefix("path=")
                && !$0.hasPrefix("dir=") && !$0.hasPrefix("ratio=") }.joined(separator: " ")
        }
        @discardableResult func both(_ line: String) -> String {
            let ra = a.handler.handle(line), rb = b.handler.handle(line)
            cmds += 1
            if Self.norm(ra) != Self.norm(rb) {
                replyMismatches += 1
                XCTFail("seed \(seed) '\(line)': reply A '\(ra)' B '\(rb)'")
            }
            return ra
        }
        func perTwin(_ make: (String) -> String) -> (String, String) {
            cmds += 1
            return (a.handler.handle(make(rootA)), b.handler.handle(make(rootB)))
        }
        @discardableResult func bulk(_ verb: String, count: Int, _ write: (UnsafeMutableRawPointer) -> Void) -> String {
            shm1Header(a.shm, count: count, verb: .named(verb)); shm1Header(b.shm, count: count, verb: .named(verb))
            write(a.shm); write(b.shm)
            return both(verb)
        }
        @discardableResult func rows(_ verb: String, _ rows: [(UInt32, UInt32)]) -> String {
            for f in [a, b] {
                f.shm.storeBytes(of: UInt32(rows.count), toByteOffset: 0, as: UInt32.self)
                f.shm.storeBytes(of: shm1Word1(.named(verb)), toByteOffset: 4, as: UInt32.self)
                for (i, r) in rows.enumerated() {
                    f.shm.storeBytes(of: r.0, toByteOffset: 8 + 8 * i, as: UInt32.self)
                    f.shm.storeBytes(of: r.1, toByteOffset: 12 + 8 * i, as: UInt32.self)
                }
            }
            return both(verb)
        }
    }

    /// The fuzz's script for one seed, with this file's Rng in place of
    /// Python's (the same shapes, choices and probabilities; not the same
    /// byte streams). EVAL runs only on a graph that passes the rank-order
    /// check: on a graph with a same-rank edge the colour path can race.
    func fuzzSeed(_ tw: Twin, seed: UInt64, side: Int, regsPrev: inout Set<Int>, _ tally: inout Tally) {
        var g = Rng(s: seed &* 0x9E37_79B9 &+ 0xF1)
        func random() -> Double { Double(g.next() >> 11) / Double(1 << 53) }
        func choice<T>(_ xs: [T]) -> T { xs[g.below(xs.count)] }
        func sample(_ xs: [Int], _ k: Int) -> [Int] {
            var v = xs
            for i in 0..<min(k, v.count) { v.swapAt(i, i + g.below(v.count - i)) }
            return Array(v.prefix(k))
        }
        tw.seed = seed
        let n = side * side
        let a = tw.a.handler.engine, b = tw.b.handler.engine
        func compare(_ label: String) {
            let d = differing(a, b)
            tally.ticks += 1
            if d != 0 { tally.mismatchTicks += 1; tally.mismatchBytes += d }
            XCTAssertEqual(d, 0, "seed \(seed) \(label): truth bytes differ")
            let now = a.readTruthStates()
            if now != tw.lastTruth { tw.stateChanged += 1; tw.lastTruth = now }
        }
        func compareState(_ label: String) {
            compare(label)
            let (ea, eb) = tw.perTwin { "EXPORT MORTON \($0)/ex" }
            if ea.hasPrefix("OK") && eb.hasPrefix("OK") { tw.exported = true }
            let (sa, sb) = tw.perTwin { "SAVE \($0)/s.dags" }
            if Twin.norm(sa) != Twin.norm(sb) { tw.replyMismatches += 1; XCTFail("seed \(seed) SAVE '\(sa)' '\(sb)'") }
            if sa.hasPrefix("OK") {
                tw.saved = true
                let da = FileManager.default.contents(atPath: tw.rootA + "/s.dags")
                let db = FileManager.default.contents(atPath: tw.rootB + "/s.dags")
                if da != nil && da == db { tw.savesEqual += 1 } else {
                    tw.saveMismatches += 1; XCTFail("seed \(seed) \(label): SAVE bytes differ")
                }
            }
        }
        func tickOnce(_ label: String) -> Bool {
            let before = a.readTruthStates()
            let r = tw.both("TICK 1")
            guard r.hasPrefix("OK TICK") else { return false }
            let after = a.readTruthStates()
            for i in 0..<n where before[i] != after[i] { tally.moved += 1 }
            noteLatch(a, b, &tally, "seed \(seed) \(label)")
            compare(label)
            return true
        }
        // Reset the back edges of the previous seed: every live register, not only the seed's own —
        // a LOAD or IMPORT of an earlier seed's file brings its registers
        // back, and SET_NEIGHBORS_BULK refuses a slot into a register (S4),
        // so a register left here would refuse the seed's install.
        for r in Set(tw.a.handler.engine.backEdgeDsts.map(Int.init)).union(regsPrev).sorted() { tw.both("CLEAR \(r) BACK_EDGES") }
        regsPrev = []
        let shape = choice(["few", "many", "wide", "huge", "chain"])
        let R = ["few": 3, "many": 14, "wide": 40, "huge": n - 1, "chain": 200][shape]!
        var ranks = [Int](repeating: 0, count: n)
        for i in 0..<n { ranks[i] = shape == "huge" ? choice([0, 1, 2, g.below(n)]) : g.below(R) }
        let dupseed = random() < 0.3
        var byRank: [Int: [Int]] = [:]
        for (i, r) in ranks.enumerated() { byRank[r, default: []].append(i) }
        let sortedR = byRank.keys.sorted()
        var nb = [Int32](repeating: -1, count: 6 * n)
        for i in 0..<n {
            let r = ranks[i]
            let hi = shape == "huge" ? [] : sortedR.filter { $0 > r }
            let k = choice([0, 1, 2, 3, 6, 6, 6])
            var slots = [Int](repeating: -1, count: 6)
            for d in sample(Array(0..<6), k) {
                if shape == "huge" {
                    let c = g.below(n)
                    if ranks[c] > r && !slots.contains(c) { slots[d] = c }
                } else if !hi.isEmpty {
                    let rr = random() < 0.7 ? choice(Array(hi.prefix(6))) : choice(hi)
                    let c = choice(byRank[rr]!)
                    if !slots.contains(c) { slots[d] = c }
                }
            }
            if dupseed && random() < 0.05, let s0 = slots.first(where: { $0 >= 0 }) {
                slots[slots.firstIndex(of: -1) ?? 0] = s0                              // duplicate source
            }
            for d in 0..<6 { nb[i * 6 + d] = Int32(slots[d]) }
        }
        if random() < 0.12 {                                                           // one same/lower-rank edge
            let i = g.below(n)
            let same = byRank[ranks[i]]!.filter { $0 != i }
            let c = !same.isEmpty && random() < 0.7 ? choice(same) : i
            nb[i * 6 + g.below(6)] = Int32(c)
        }
        tw.bulk("SET_MODES_BULK", count: n) { p in _ = memset(p + 8, 0, n) }
        tw.bulk("SET_RANKS_BULK", count: n) { p in for i in 0..<n { p.storeBytes(of: UInt64(ranks[i]), toByteOffset: 8 + 8 * i, as: UInt64.self) } }
        tw.bulk("SET_NEIGHBORS_BULK", count: n) { p in for i in 0..<(6 * n) { p.storeBytes(of: nb[i], toByteOffset: 8 + 4 * i, as: Int32.self) } }
        let luts = (0..<n).map { _ in g.next() }
        tw.bulk("SET_LUTS_BULK", count: n) { p in for i in 0..<n { p.storeBytes(of: luts[i], toByteOffset: 8 + 8 * i, as: UInt64.self) } }
        let truth = (0..<n).map { _ in random() > 0.03 ? choice([0, 1, 1, 0, 2]) : 3 + g.below(253) }
        for f in [tw.a, tw.b] {
            f.shm.storeBytes(of: UInt32(n), toByteOffset: 0, as: UInt32.self)
            f.shm.storeBytes(of: shm1Word1(.setTruthBulk), toByteOffset: 4, as: UInt32.self)
            for i in 0..<n {
                f.shm.storeBytes(of: UInt32(i), toByteOffset: 8 + 8 * i, as: UInt32.self)
                f.shm.storeBytes(of: UInt32(truth[i]), toByteOffset: 12 + 8 * i, as: UInt32.self)   // u8, pad 0
            }
        }
        tw.both("SET_TRUTH_BULK")
        var modes = [UInt8](repeating: 0, count: n)
        if random() < 0.6 {
            tw.both("TTABLE PRESET 0 TMIN 6"); tw.both("TTABLE PRESET 1 TSUM 6"); tw.both("TTABLE PRESET 2 TCONS 3")
            for i in 0..<n where truth[i] < 3 && random() < 0.4 { modes[i] = choice([1, 2, 5, 6]) }
            let tids = (0..<n).map { _ in UInt16(g.below(3)) }
            tw.bulk("SET_TTABLE_IDS_BULK", count: n) { p in for i in 0..<n { p.storeBytes(of: tids[i], toByteOffset: 8 + 2 * i, as: UInt16.self) } }
            var th: [Float] = []
            for _ in 0..<n { let lo = choice([Float(-2.5), -1.0, -0.5, 0.0]); th += [lo, lo + choice([Float(0), 0.5, 1.0, 2.0])] }
            tw.bulk("SET_THRESH_BULK", count: n) { p in for i in 0..<(2 * n) { p.storeBytes(of: th[i], toByteOffset: 8 + 4 * i, as: Float.self) } }
            tw.bulk("SET_MODES_BULK", count: n) { p in for i in 0..<n { p.storeBytes(of: modes[i], toByteOffset: 8 + i, as: UInt8.self) } }
            for _ in 0..<20 { tw.both("SET \(g.below(n)) WEIGHT \(g.below(6)) \(choice(["-1.5", "0.25", "2.0", "-0.75"]))") }
        }
        // Back edges into binary nodes with no combinational fan-in.
        let cands = (0..<n).filter { i in (0..<6).allSatisfy { nb[i * 6 + $0] < 0 } && modes[i] == 0 }
        var backRows: [(UInt32, UInt32)] = []
        for i in sample(cands, min(cands.count, choice([0, 3, 20]))) {
            backRows.append((UInt32(g.below(n)), UInt32(i))); regsPrev.insert(i)
        }
        if !backRows.isEmpty { tw.rows("CONNECT_BACK_BULK", backRows) }
        func dagOK() -> Bool { tw.a.handler.rankTickDagRefusal() == nil && tw.b.handler.rankTickDagRefusal() == nil }
        if random() < 0.5 && dagOK() { tw.both("EVAL") }
        for step in 0..<(4 + g.below(6)) {
            let op = random()
            if op < 0.35 {
                let k = choice([1, 1, 2, 3, 7])
                for _ in 0..<k { if !tickOnce("tick\(step)") { break } }
                compareState("tick\(step)")
            } else if op < 0.45 {
                let ra = tw.both("TICK UNTIL_STABLE MAX \(choice([1, 5, 50]))")
                if ra.hasPrefix("OK TICK UNTIL_STABLE") { noteLatch(a, b, &tally, "seed \(seed) until\(step)") }
                compareState("until\(step)")
            } else if op < 0.52 {
                tw.both("TICK_SYNC 1"); compareState("sync\(step)")
            } else if op < 0.58 {
                if dagOK() { tw.both("EVAL") }
                compareState("eval\(step)")
            } else if op < 0.68 {
                tw.both("SET \(g.below(n)) RANK \(g.below(min(n, R + 3)))")
            } else if op < 0.74 {
                tw.both("CONNECT FROM \(g.below(n)) TO \(g.below(n))")
            } else if op < 0.78 {
                tw.both("CLEAR \(g.below(n)) EDGES")
            } else if op < 0.83 {
                let d = g.below(n)
                if tw.both("CONNECT BACK FROM \(g.below(n)) TO \(d)").hasPrefix("OK") { regsPrev.insert(d) }
            } else if op < 0.88 {
                tw.both("SET \(g.below(n)) TRUTH \(choice([0, 1, 2, 7]))")
            } else if op < 0.92 {
                tw.both("SET \(g.below(n)) MODE \(choice(["BINARY", "TTABLE", "TTHRESH", "TTHRESH NOSKIP"]))")
            } else if op < 0.93 {
                let s = 1 + g.below(29)
                let nr = ranks.map { min($0 + s, n - 1) }
                tw.bulk("SET_RANKS_BULK", count: n) { p in for i in 0..<n { p.storeBytes(of: UInt64(nr[i]), toByteOffset: 8 + 8 * i, as: UInt64.self) } }
            } else {
                let x = random()
                if x < 0.4 && tw.saved {
                    let (la, lb) = tw.perTwin { "LOAD \($0)/s.dags" }
                    if Twin.norm(la).components(separatedBy: "elapsed")[0] != Twin.norm(lb).components(separatedBy: "elapsed")[0] {
                        tw.replyMismatches += 1; XCTFail("seed \(seed) LOAD '\(la)' '\(lb)'")
                    }
                    loads += 1
                } else if x < 0.8 && tw.exported {
                    let (ia, ib) = tw.perTwin { "IMPORT MORTON \($0)/ex" }
                    if Twin.norm(ia).components(separatedBy: "elapsed")[0] != Twin.norm(ib).components(separatedBy: "elapsed")[0] {
                        tw.replyMismatches += 1; XCTFail("seed \(seed) IMPORT '\(ia)' '\(ib)'")
                    }
                    imports += 1
                } else {
                    tw.both("VALIDATE")
                }
            }
        }
        for _ in 0..<choice([1, 3]) { if !tickOnce("final") { break } }
        compareState("final")
    }
    var loads = 0, imports = 0

    func fuzz(side: Int, seeds: Range<UInt64>) throws -> (Tally, Twin) {
        let tw = try Twin(side: side, root: tmp + "/fuzz\(side)")
        var tally = Tally(), regs = Set<Int>()
        for s in seeds { fuzzSeed(tw, seed: s, side: side, regsPrev: &regs, &tally) }
        return (tally, tw)
    }

    func testF1FuzzMixThreeHundredSeeds() throws {
        loads = 0; imports = 0
        let (t40, w40) = try fuzz(side: 40, seeds: 0..<300)
        print("F1.1 fuzz mix 40² seeds 0-299: \(w40.cmds) commands, reply mismatches \(w40.replyMismatches), "
              + "saves equal \(w40.savesEqual) (mismatches \(w40.saveMismatches)), state changed \(w40.stateChanged), "
              + "loads \(loads), imports \(imports); " + t40.line)
        loads = 0; imports = 0
        let (t8, w8) = try fuzz(side: 8, seeds: 1000..<1100)
        print("F1.1 fuzz mix 8² seeds 1000-1099: \(w8.cmds) commands, reply mismatches \(w8.replyMismatches), "
              + "saves equal \(w8.savesEqual) (mismatches \(w8.saveMismatches)), state changed \(w8.stateChanged), "
              + "loads \(loads), imports \(imports); " + t8.line)
        XCTAssertGreaterThan(t40.gpuTicks, 100, "not vacuous: B latched on the GPU")
        XCTAssertGreaterThan(t40.twoPhaseTicks, 0)
        XCTAssertGreaterThan(w40.stateChanged, 100)
    }
}
