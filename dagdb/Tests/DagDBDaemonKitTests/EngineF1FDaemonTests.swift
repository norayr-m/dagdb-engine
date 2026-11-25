import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// The latch plan's rebuild after a back-edge edit. In a plain daemon `TICK` the
/// first tick after a back-edge edit takes the CPU latch (the reference,
/// the pre-frontier cost) and builds nothing; the plan is built at the second
/// consecutive plain `TICK` with no back-edge edit between; `TICK
/// UNTIL_STABLE` keeps building it on entry. The build is one O(back edges)
/// pass over plain arrays.
///
/// The cost and the equivalence are measured live against release daemons.
/// These tests are the
/// policy's shape and its exactness in-process: a twin A takes the CPU latch
/// on every tick (`latchOnGPU = false`, the pre-frontier latch); B runs the policy.
/// After every command both replies (elapsed stripped) and every truth byte
/// are equal. Only members that exist before this change are read, so the class
/// compiles on the older code and its red is a runtime one.
///
/// "A back-edge edit" is read as a change to either back-edge list between
/// two plain `TICK`s: the engine's first plain `TICK` has no `TICK` before
/// it, so it builds the plan as before (the GPU-latch policy test asserts
/// the GPU latch on the first plain `TICK` of a graph built with 65,536
/// back edges).
final class EngineF1FDaemonTests: XCTestCase {

    typealias Rng = EngineE1DaemonTests.Rng

    private var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "engine-f1f-\(UUID().uuidString)"
        for d in ["", "/A", "/B"] {
            try FileManager.default.createDirectory(atPath: tmp + d, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - Helpers

    static let registers = 65_536

    /// The policy graph of `EngineF1DaemonTests.testF1PolicyAndPlanCache`:
    /// side 300, 90,000 nodes; nodes 0 ..< 65,536 at rank 1 with no slot (the
    /// registers), every other node at rank 0 reading three distinct ones
    /// (that builder may draw one twice, which SAVE refuses as a duplicate
    /// edge; this test SAVEs and LOADs); `edges` back edges, the k-th into
    /// register k mod 65,536 from a random source at or above 65,536. Random
    /// LUTs and truth.
    func policyGraph(edges: Int, root: String) throws -> HandlerFixture {
        let f = try HandlerFixture(side: 300, dataRoot: root)
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
            rank[i] = i < Self.registers ? 1 : 0
            if i >= Self.registers {
                var picked: [Int32] = []
                while picked.count < 3 {
                    let s = Int32(g.below(Self.registers))
                    if !picked.contains(s) { picked.append(s) }
                }
                for d in 0..<3 { nb[i * 6 + d] = picked[d] }
            }
        }
        e.markRankTopologyDirty()
        for k in 0..<edges {
            try e.addBackEdge(src: UInt32(Self.registers + g.below(n - Self.registers)), dst: UInt32(k % Self.registers))
        }
        return f
    }

    /// A (the CPU latch on every tick) and B (the policy) on the same graph.
    func twins(edges: Int) throws -> (HandlerFixture, HandlerFixture) {
        let fa = try policyGraph(edges: edges, root: tmp + "/A"), fb = try policyGraph(edges: edges, root: tmp + "/B")
        fa.handler.engine.latchOnGPU = false
        XCTAssertNil(fb.handler.engine.latchOnGPU, "B: the policy")
        return (fa, fb)
    }

    func differing(_ a: DagDBEngine, _ b: DagDBEngine) -> Int {
        let n = a.nodeCount
        let pa = a.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let pb = b.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        var d = 0
        for i in 0..<n where pa[i] != pb[i] { d += 1 }
        return d
    }

    func strip(_ r: String) -> String {
        r.split(separator: " ").filter { !$0.hasPrefix("elapsed=") && !$0.hasPrefix("path=")
            && !$0.hasPrefix("dir=") && !$0.hasPrefix("ratio=") }.joined(separator: " ")
    }

    /// Running totals of one test, printed at its end.
    struct Tally {
        var commands = 0, ticks = 0, replyMismatches = 0, mismatchCommands = 0, mismatchBytes = 0
        var line: String {
            "commands \(commands) (plain TICK lines \(ticks)), reply mismatches \(replyMismatches), "
                + "commands after which the truth differed \(mismatchCommands) (\(mismatchBytes) bytes)"
        }
    }

    /// One command on both handlers (`line(root)`: paths under each root),
    /// replies and truth bytes compared. Returns B's reply.
    @discardableResult
    func both(_ fa: HandlerFixture, _ fb: HandlerFixture, _ tally: inout Tally, _ line: (String) -> String,
              file: StaticString = #filePath, at: UInt = #line) -> String {
        let la = line(tmp + "/A"), lb = line(tmp + "/B")
        let ra = fa.handler.handle(la), rb = fb.handler.handle(lb)
        tally.commands += 1
        if lb.hasPrefix("TICK ") && !lb.hasPrefix("TICK UNTIL_STABLE") { tally.ticks += 1 }
        let na = strip(ra).replacingOccurrences(of: tmp + "/A", with: "<root>")
        let nb = strip(rb).replacingOccurrences(of: tmp + "/B", with: "<root>")
        if na != nb { tally.replyMismatches += 1 }
        XCTAssertEqual(na, nb, lb, file: file, line: at)
        XCTAssertTrue(rb.hasPrefix("OK"), "\(lb): \(rb)", file: file, line: at)
        let d = differing(fa.handler.engine, fb.handler.engine)
        if d != 0 { tally.mismatchCommands += 1; tally.mismatchBytes += d }
        XCTAssertEqual(d, 0, "\(lb): truth bytes differ", file: file, line: at)
        return rb
    }

    @discardableResult
    func both(_ fa: HandlerFixture, _ fb: HandlerFixture, _ tally: inout Tally, _ line: String,
              file: StaticString = #filePath, at: UInt = #line) -> String {
        both(fa, fb, &tally, { _ in line }, file: file, at: at)
    }

    /// A back edge that moves a register's effective source (a new last edge).
    func edit(_ g: inout Rng, _ n: Int) -> String {
        "CONNECT BACK FROM \(Self.registers + g.below(n - Self.registers)) TO \(g.below(Self.registers))"
    }

    /// The plan the lists give now, computed the plainest way (the last index
    /// per destination in a dictionary; the effective edges in list order;
    /// two-phase when an effective source is a destination); nil when an
    /// index is outside the table, the lists differ in length, or are empty.
    func referencePlan(_ e: DagDBEngine) -> (src: [UInt32], dst: [UInt32], twoPhase: Bool)? {
        let s = e.backEdgeSrcs, d = e.backEdgeDsts
        guard !s.isEmpty, s.count == d.count else { return nil }
        guard s.allSatisfy({ Int($0) < e.nodeCount }), d.allSatisfy({ Int($0) < e.nodeCount }) else { return nil }
        var last: [UInt32: Int] = [:]
        for (i, x) in d.enumerated() { last[x] = i }
        var rs: [UInt32] = [], rd: [UInt32] = []
        for i in 0..<d.count where last[d[i]] == i { rs.append(s[i]); rd.append(d[i]) }
        let dests = Set(d)
        return (rs, rd, rs.contains { dests.contains($0) })
    }

    /// The engine's cached plan equals the plan its lists give now (no stale
    /// plan). True when there is no cached plan.
    func planIsCurrent(_ e: DagDBEngine) -> Bool {
        guard let p = e.latchPlan else { return true }
        guard let r = referencePlan(e), r.src.count == p.count, r.twoPhase == p.twoPhase else { return false }
        let es = p.effSrc.contents().bindMemory(to: UInt32.self, capacity: p.count)
        let ed = p.effDst.contents().bindMemory(to: UInt32.self, capacity: p.count)
        for j in 0..<p.count where es[j] != r.src[j] || ed[j] != r.dst[j] { return false }
        return true
    }

    // MARK: - The policy, step by step

    func testF1FFirstTickAfterAnEditTakesTheCPULatch() throws {
        let (fa, fb) = try twins(edges: Self.registers)
        let b = fb.handler.engine, n = b.nodeCount
        var t = Tally()
        var g = Rng(s: 0xF1F2)
        func plainTick(_ label: String, gpu: Bool, builds: Int, at: UInt = #line) {
            both(fa, fb, &t, "TICK 1", at: at)
            XCTAssertFalse(fa.handler.engine.lastLatchOnGPU, "\(label): A latched on the CPU", line: at)
            XCTAssertEqual(b.lastLatchOnGPU, gpu, "\(label): B on the GPU", line: at)
            XCTAssertEqual(b.latchPlanBuildCount, builds, "\(label): plans built", line: at)
            XCTAssertTrue(planIsCurrent(b), "\(label): B's plan is the lists' plan", line: at)
        }
        // The engine's first plain TICKs (no TICK before them: no edit between two TICKs) build a plan.
        for k in 0..<3 { plainTick("first TICKs \(k)", gpu: true, builds: 1) }
        var builds = 1
        // (edit, TICK) alternating: every TICK is the first after an edit — the CPU latch, nothing built.
        for k in 0..<20 {
            both(fa, fb, &t, edit(&g, n))
            plainTick("alternating \(k)", gpu: false, builds: builds)
            XCTAssertNil(b.latchPlan, "alternating \(k): no plan")
        }
        // (edit, TICK, TICK, TICK): the first on the CPU, the second builds, the third reuses.
        for k in 0..<5 {
            both(fa, fb, &t, edit(&g, n))
            plainTick("triple \(k) first", gpu: false, builds: builds)
            builds += 1
            plainTick("triple \(k) second", gpu: true, builds: builds)
            plainTick("triple \(k) third", gpu: true, builds: builds)
        }
        // TICK 3 right after an edit: CPU, then built, then reused.
        both(fa, fb, &t, edit(&g, n))
        both(fa, fb, &t, "TICK 3")
        builds += 1
        XCTAssertTrue(b.lastLatchOnGPU); XCTAssertEqual(b.latchPlanBuildCount, builds, "TICK 3 after an edit")
        // Writes that are not back-edge edits do not reset it: TICK (first: CPU), truth/LUT/SAVE, TICK (second: built).
        both(fa, fb, &t, edit(&g, n))
        plainTick("before other writes", gpu: false, builds: builds)
        both(fa, fb, &t, "SET 70000 TRUTH 1")
        both(fa, fb, &t, "SET 70001 LUT AND")
        both(fa, fb, &t, { "SAVE \($0)/f1f.dags" })
        builds += 1
        plainTick("after other writes", gpu: true, builds: builds)
        // EVAL and TICK_SYNC are not plain TICKs: the TICK after them is still the first after the edit.
        both(fa, fb, &t, edit(&g, n))
        both(fa, fb, &t, "EVAL")
        both(fa, fb, &t, "TICK_SYNC 1")
        plainTick("after EVAL and TICK_SYNC", gpu: false, builds: builds)
        builds += 1
        plainTick("second after EVAL and TICK_SYNC", gpu: true, builds: builds)
        // TICK UNTIL_STABLE right after an edit builds on entry; the next plain TICK uses that plan.
        both(fa, fb, &t, edit(&g, n))
        both(fa, fb, &t, "TICK UNTIL_STABLE MAX 4")
        builds += 1
        XCTAssertTrue(b.lastLatchOnGPU, "UNTIL_STABLE latches on the GPU")
        XCTAssertEqual(b.latchPlanBuildCount, builds, "UNTIL_STABLE builds on entry")
        plainTick("after UNTIL_STABLE", gpu: true, builds: builds)
        // Every back-edge writer: the first TICK after it on the CPU, the second builds.
        var rows: [(UInt32, UInt32)] = []
        for _ in 0..<5 { rows.append((UInt32(Self.registers + g.below(n - Self.registers)), UInt32(g.below(Self.registers)))) }
        for f in [fa, fb] {
            let h = f.shm.bindMemory(to: UInt32.self, capacity: 2 + 2 * rows.count)
            h[0] = UInt32(rows.count); h[1] = shm1Word1(.connectBackBulk)
            for (i, r) in rows.enumerated() { h[2 + 2 * i] = r.0; h[3 + 2 * i] = r.1 }
        }
        let writers: [(String, (String) -> String)] = [
            ("CONNECT_BACK_BULK", { _ in "CONNECT_BACK_BULK" }),
            ("CLEAR … BACK_EDGES", { _ in "CLEAR \(rows[0].1) BACK_EDGES" }),
            ("LOAD", { "LOAD \($0)/f1f.dags" }),
            ("CONNECT BACK", { _ in "CONNECT BACK FROM \(Self.registers + 7) TO \(rows[0].1)" }),
        ]
        for (name, line) in writers {
            plainTick("before \(name)", gpu: true, builds: builds)
            both(fa, fb, &t, line)
            XCTAssertNil(b.latchPlan, "\(name) dropped the plan")
            plainTick("first after \(name)", gpu: false, builds: builds)
            builds += 1
            plainTick("second after \(name)", gpu: true, builds: builds)
        }
        print("F1F policy, step by step: " + t.line + "; B built \(b.latchPlanBuildCount) plans")
    }

    /// Crossing the threshold: 65,535 back edges (the CPU latch by the
    /// policy), an edit that makes 65,536: the first TICK after it on the
    /// CPU, the second builds.
    func testF1FThresholdCrossedByAnEdit() throws {
        let (fa, fb) = try twins(edges: Self.registers - 1)
        let b = fb.handler.engine
        var t = Tally()
        for _ in 0..<2 {
            both(fa, fb, &t, "TICK 1")
            XCTAssertFalse(b.lastLatchOnGPU); XCTAssertEqual(b.latchPlanBuildCount, 0, "below the threshold")
        }
        both(fa, fb, &t, "CONNECT BACK FROM \(Self.registers + 11) TO \(Self.registers - 1)")
        XCTAssertEqual(b.backEdgeCount, Self.registers)
        both(fa, fb, &t, "TICK 1")
        XCTAssertFalse(b.lastLatchOnGPU, "the first TICK after the edit"); XCTAssertEqual(b.latchPlanBuildCount, 0)
        both(fa, fb, &t, "TICK 1")
        XCTAssertTrue(b.lastLatchOnGPU, "the second"); XCTAssertEqual(b.latchPlanBuildCount, 1)
        print("F1F threshold crossed by an edit: " + t.line)
    }

    // MARK: - The workload the cost measurement times: strict alternation never builds

    /// 200 × (a back-edge edit, `TICK 1`), the edits CONNECT BACK, CLEAR …
    /// BACK_EDGES and a 3-row CONNECT_BACK_BULK: B never builds a plan and
    /// every tick latches on the CPU, equal to A. (The control,
    /// the plan built on the first tick after an edit, builds 200 here.)
    func testF1FStrictAlternationNeverBuilds() throws {
        let (fa, fb) = try twins(edges: Self.registers + 2_000)
        let b = fb.handler.engine, n = b.nodeCount
        var t = Tally()
        var g = Rng(s: 0xF1F3)
        both(fa, fb, &t, "TICK 1")                              // the engine's first plain TICK builds
        let builds0 = b.latchPlanBuildCount
        XCTAssertEqual(builds0, 1)
        var cpu = 0
        for k in 0..<200 {
            switch k % 4 {
            case 3:
                for f in [fa, fb] {
                    let h = f.shm.bindMemory(to: UInt32.self, capacity: 8)
                    var gg = g
                    h[0] = 3; h[1] = shm1Word1(.connectBackBulk)
                    for i in 0..<3 {
                        h[2 + 2 * i] = UInt32(Self.registers + gg.below(n - Self.registers))
                        h[3 + 2 * i] = UInt32(gg.below(Self.registers))
                    }
                    if f === fb { g = gg }
                }
                both(fa, fb, &t, "CONNECT_BACK_BULK")
            case 2:
                both(fa, fb, &t, "CLEAR \(g.below(Self.registers)) BACK_EDGES")
            default:
                both(fa, fb, &t, edit(&g, n))
            }
            XCTAssertGreaterThanOrEqual(b.backEdgeCount, DagDBEngine.gpuLatchMinBackEdges, "above the threshold")
            both(fa, fb, &t, "TICK 1")
            if !b.lastLatchOnGPU { cpu += 1 }
            XCTAssertFalse(b.lastLatchOnGPU, "alternation \(k): the first TICK after an edit latches on the CPU")
        }
        XCTAssertEqual(b.latchPlanBuildCount, builds0, "strict alternation builds no plan")
        print("F1F strict alternation: " + t.line + "; B's ticks on the CPU \(cpu) of 200, plans built after the first TICK "
              + "\(b.latchPlanBuildCount - builds0)")
    }

    // MARK: - The build: one pass, the same plan

    /// `buildLatchPlan` against `referencePlan` on lists of every shape:
    /// random (sources anywhere: two-phase), sources that are never
    /// destinations (one kernel), chains (head-first and tail-first),
    /// self-loops, every edge into one register, more edges than nodes,
    /// single edges; and nil for an index outside the table, lists of unequal
    /// length, or no lists. Each built plan is checked buffer by buffer.
    func testF1FPlanBuildEqualsTheReference() throws {
        let f = try HandlerFixture(side: 64)
        let e = f.handler.engine
        let n = e.nodeCount
        var g = Rng(s: 0xF1F4)
        var cases = 0, twoPhase = 0, entries = 0
        func check(_ s: [UInt32], _ d: [UInt32], _ label: String, at: UInt = #line) {
            e.backEdgeSrcs = s; e.backEdgeDsts = d
            XCTAssertNil(e.latchPlan, "\(label): the lists' change dropped the plan", line: at)
            let builds = e.latchPlanBuildCount
            let p = e.buildLatchPlan()
            cases += 1
            guard let r = referencePlan(e) else {
                XCTAssertNil(p, "\(label): no plan", line: at)
                XCTAssertEqual(e.latchPlanBuildCount, builds, "\(label): nothing counted", line: at)
                return
            }
            guard let p = p else { XCTFail("\(label): no plan built", line: at); return }
            XCTAssertEqual(e.latchPlanBuildCount, builds + 1, label, line: at)
            XCTAssertEqual(p.count, r.src.count, "\(label): effective back edges", line: at)
            XCTAssertEqual(p.twoPhase, r.twoPhase, "\(label): two-phase", line: at)
            XCTAssertEqual(p.effSrc.length, 4 * r.src.count, label, line: at)
            XCTAssertEqual(p.effDst.length, 4 * r.src.count, label, line: at)
            XCTAssertEqual(p.scratch?.length, r.twoPhase ? r.src.count : nil, "\(label): scratch", line: at)
            XCTAssertEqual(p.counter.length, 4, label, line: at)
            guard p.count == r.src.count else { return }
            let es = p.effSrc.contents().bindMemory(to: UInt32.self, capacity: p.count)
            let ed = p.effDst.contents().bindMemory(to: UInt32.self, capacity: p.count)
            XCTAssertEqual(Array(UnsafeBufferPointer(start: es, count: p.count)), r.src, "\(label): sources", line: at)
            XCTAssertEqual(Array(UnsafeBufferPointer(start: ed, count: p.count)), r.dst, "\(label): destinations", line: at)
            if p.twoPhase { twoPhase += 1 }
            entries += s.count
        }
        func r(_ k: Int) -> UInt32 { UInt32(g.below(k)) }
        for size in [1, 2, 3, 5, 17, 100, 1_000, n, 3 * n] {
            for regs in [1, 7, 64, n / 2, n] {
                let k = max(1, min(regs, n))
                let d = (0..<size).map { _ in r(k) }
                check((0..<size).map { _ in r(n) }, d, "random \(size) into \(k)")
                let lo = min(k, n - 1)                          // sources at or above every destination
                check((0..<size).map { _ in UInt32(lo) + r(max(1, n - lo)) }, d, "direct \(size) into \(k)")
                check(Array(d.reversed()), (0..<size).map { _ in r(n) }, "reversed roles \(size)")
            }
        }
        for len in [2, 3, 5, 17, 64] {
            let nodes = (0..<(len + 1)).map { UInt32(($0 * 37 + 5) % n) }
            let head = (0..<len).map { (nodes[$0 + 1], nodes[$0]) }       // dst of one is the src of the next
            check(head.map { $0.0 }, head.map { $0.1 }, "chain \(len) head-first")
            check(head.reversed().map { $0.0 }, head.reversed().map { $0.1 }, "chain \(len) tail-first")
        }
        check([5, 6, 6], [5, 6, 7], "self-loops")
        check([9], [9], "one self-loop")
        check((0..<50).map { UInt32($0) }, [UInt32](repeating: 3, count: 50), "fifty into one register")
        check([1, 2], [3, 4], "two direct")
        check([1, UInt32(n)], [3, 4], "a source outside the table")
        check([1, 2], [3, UInt32(n)], "a destination outside the table")
        check([1, 2, 3], [3, 4], "lists of unequal length")
        check([], [], "no back edges")
        print("F1F plan build: \(cases) lists, \(entries) back edges in the built ones, two-phase \(twoPhase)")
    }

    // MARK: - Twins under a mixed workload, the plan never stale

    /// 400 random steps on the policy graph — back-edge edits (CONNECT BACK,
    /// CLEAR … BACK_EDGES, a 3-row CONNECT_BACK_BULK), runs of plain `TICK 1`
    /// and `TICK 2`, `TICK UNTIL_STABLE MAX 1|3|8`, `SET … TRUTH`, `EVAL`,
    /// `TICK_SYNC 1` — A against B: every reply and every truth byte equal, and
    /// B's cached plan, whenever there is one, is the plan its lists give.
    func testF1FTwinsUnderAMixedWorkload() throws {
        let (fa, fb) = try twins(edges: Self.registers + 500)
        let b = fb.handler.engine, n = b.nodeCount
        var t = Tally()
        var g = Rng(s: 0xF1F5)
        var cpuTicks = 0, gpuTicks = 0, stale = 0
        for _ in 0..<400 {
            let op = g.below(100)
            switch op {
            case 0..<18: both(fa, fb, &t, edit(&g, n))
            case 18..<22: both(fa, fb, &t, "CLEAR \(g.below(Self.registers)) BACK_EDGES")
            case 22..<26:
                var rows: [(UInt32, UInt32)] = []
                for _ in 0..<3 { rows.append((UInt32(g.below(n)), UInt32(g.below(Self.registers)))) }
                for f in [fa, fb] {
                    let h = f.shm.bindMemory(to: UInt32.self, capacity: 8)
                    h[0] = 3; h[1] = shm1Word1(.connectBackBulk)
                    for (i, r) in rows.enumerated() { h[2 + 2 * i] = r.0; h[3 + 2 * i] = r.1 }
                }
                both(fa, fb, &t, "CONNECT_BACK_BULK")
            case 26..<66:
                for _ in 0..<(1 + g.below(3)) {
                    both(fa, fb, &t, "TICK 1")
                    if b.backEdgeCount >= DagDBEngine.gpuLatchMinBackEdges { if b.lastLatchOnGPU { gpuTicks += 1 } else { cpuTicks += 1 } }
                }
            case 66..<74: both(fa, fb, &t, "TICK 2")
            case 74..<82: both(fa, fb, &t, "TICK UNTIL_STABLE MAX \([1, 3, 8][g.below(3)])")
            case 82..<90: both(fa, fb, &t, "SET \(g.below(n)) TRUTH \(g.below(2))")
            case 90..<95: both(fa, fb, &t, "EVAL")
            default: both(fa, fb, &t, "TICK_SYNC 1")
            }
            if !planIsCurrent(b) { stale += 1 }
            XCTAssertTrue(planIsCurrent(b), "B's plan is stale")
        }
        XCTAssertGreaterThan(cpuTicks, 0, "not vacuous: some plain TICKs were the first after an edit")
        XCTAssertGreaterThan(gpuTicks, 0, "not vacuous: some ran on a plan")
        print("F1F twins, mixed workload: " + t.line + "; B's plain TICK 1 above the threshold: CPU \(cpuTicks), "
              + "GPU \(gpuTicks); plans built \(b.latchPlanBuildCount); stale plans \(stale)")
    }
}
