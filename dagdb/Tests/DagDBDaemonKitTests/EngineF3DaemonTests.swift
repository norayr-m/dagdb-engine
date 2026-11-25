import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// `TICK UNTIL_STABLE` on the frontier session, k ticks per command buffer.
///
/// Every case runs on three handlers built the same way:
///   P — the pre-frontier loop (`untilStablePreFForTesting`, the engine's
///       `latchOnGPU = false`): the counting session, the CPU counting latch,
///       one tick per command buffer — TICK UNTIL_STABLE as it ran before the
///       frontier session;
///   F — the verb's default: the frontier session, 16 ticks per command buffer;
///   K — the same with one tick per command buffer (`untilStableBatchForTesting
///       = 1`).
///
/// Equal replies (in-process half): every TICK UNTIL_STABLE reply of F and K
/// equal to P's with `elapsed=` and `nodes_computed=` stripped; the truth
/// bytes and the tick totals equal after every call. `nodes_computed=` is the
/// honest count: F's equals K's (the ticks a batch ran past the fixed point
/// evaluated nothing) and is at most P's. Cases: the daemon cases of
/// `EngineE2DaemonTests`, the 48 reply cases of `EngineE5DaemonTests`, MAX
/// 1/3/16/17/32/33/39/40/41/48 on the 40-tick flood (MAX cutting a batch), the
/// random mixed graphs of `TernaryR3KernelTests`, the voxel morphology layout A
/// at 16³ (binary and ternary, every phase), a NOSKIP walk, kernel-evaluated
/// destinations, and 37 writers between two UNTIL_STABLEs (pre-frontier
/// against F, as they were compared before the frontier became the default).
/// After every `stable` reply a further `TICK 5` changes no byte (F, and
/// P), replies equal: the batch overrun is invisible.
/// The oscillator at MAX 7 and the already-stable graph (among those cases).
/// GPU waits (in process): the CPU's waits on the GPU
/// per UNTIL_STABLE ≤ ⌈run/4⌉ + 2 wherever the ticks batch (no kernel-evaluated
/// destination); a 68-register flood (the 128³ flood's run) takes 5; K takes
/// one per tick.
///
/// Red on the code before this change: does not compile — no `untilStablePreFForTesting`,
/// `untilStableBatchForTesting`, `lastUntilStableGPUWaits`, `sessionTicks`.
final class EngineF3DaemonTests: XCTestCase {

    typealias Rng = EngineE1DaemonTests.Rng

    private var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "engine-f3-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - Three handlers

    /// A handler around an engine built elsewhere (a mixed graph's, the voxel layout's), as
    /// `HandlerFixture` builds one.
    final class Held {
        let handler: DagDBCommandHandler
        let shm: UnsafeMutableRawPointer
        init(_ e: DagDBEngine, side: Int, maxRank: Int) throws {
            let grid = try HexGrid(width: side, height: side)
            let bytes = 8 + e.nodeCount * 24
            shm = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
            shm.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
            handler = DagDBCommandHandler(
                engine: e, grid: grid, nodeCount: e.nodeCount, width: side, height: side, maxRank: maxRank,
                tickCount: 0, walAppender: nil, sessionManager: DagDBReaderSessionManager(),
                truthRankIndex: TruthRankIndex(), shmBase: shm, resultRowSize: 24, dataRoot: nil, dagdbEnv: nil)
        }
        deinit { shm.deallocate() }
    }

    /// P, F, K (and whatever keeps their buffers alive).
    struct Three {
        let p: DagDBCommandHandler, f: DagDBCommandHandler, k: DagDBCommandHandler
        let keep: [AnyObject]
        init(_ p: DagDBCommandHandler, _ f: DagDBCommandHandler, _ k: DagDBCommandHandler, keep: [AnyObject]) {
            self.p = p; self.f = f; self.k = k; self.keep = keep
            p.untilStablePreFForTesting = true
            p.engine.latchOnGPU = false          // pre-F's CPU counting latch
            k.untilStableBatchForTesting = 1
        }
        var all: [DagDBCommandHandler] { [p, f, k] }
    }

    func three(side: Int = 16, _ build: (HandlerFixture) throws -> Void) throws -> Three {
        let fs = try (0..<3).map { _ in try HandlerFixture(side: side) }
        for f in fs { try build(f); XCTAssertNil(f.handler.rankTickDagRefusal()) }
        return Three(fs[0].handler, fs[1].handler, fs[2].handler, keep: fs)
    }

    func three(engines make: () throws -> DagDBEngine, side: Int, maxRank: Int) throws -> Three {
        let hs = try (0..<3).map { _ in try Held(try make(), side: side, maxRank: maxRank) }
        for h in hs { XCTAssertNil(h.handler.rankTickDagRefusal()) }
        return Three(hs[0].handler, hs[1].handler, hs[2].handler, keep: hs)
    }

    // MARK: - The comparison

    struct Tally {
        var cases = 0, calls = 0, mismatches = 0
        var stable = 0, notStable = 0, ticksRun = 0
        var f32Checks = 0                    // TICK 5 after `stable`, no byte moved
        var evaluatedF = 0, evaluatedP = 0   // nodes_computed=, F (= K) and P
        var batchesF = 0, waitsF = 0, waitsK = 0, waitsBounded = 0
        var movedBytes = 0
        mutating func add(_ o: Tally) {
            cases += o.cases; calls += o.calls; mismatches += o.mismatches; stable += o.stable
            notStable += o.notStable; ticksRun += o.ticksRun; f32Checks += o.f32Checks
            evaluatedF += o.evaluatedF; evaluatedP += o.evaluatedP; batchesF += o.batchesF
            waitsF += o.waitsF; waitsK += o.waitsK; waitsBounded += o.waitsBounded; movedBytes += o.movedBytes
        }
        var line: String {
            "cases \(cases), UNTIL_STABLE calls \(calls) (\(stable) stable, \(notStable) at MAX), ticks run \(ticksRun), "
                + "mismatching calls \(mismatches); F3.2 TICK 5 after stable \(f32Checks), no byte moved; "
                + "nodes_computed F \(evaluatedF) (= K) of pre-F \(evaluatedP); F batches \(batchesF), "
                + "CPU waits F \(waitsF) (\(waitsBounded) calls checked against ⌈run/4⌉ + 2), K \(waitsK); "
                + "truth bytes the calls moved \(movedBytes)"
        }
    }

    func strip(_ r: String) -> String {
        r.split(separator: " ").filter { !$0.hasPrefix("elapsed=") && !$0.hasPrefix("nodes_computed=")
            && !$0.hasPrefix("path=") && !$0.hasPrefix("dir=") && !$0.hasPrefix("ratio=") }.joined(separator: " ")
    }

    func field(_ reply: String, _ key: String) -> Int? {
        reply.split(separator: " ").first { $0.hasPrefix(key + "=") }.flatMap { Int($0.dropFirst(key.count + 1)) }
    }

    func differing(_ a: DagDBEngine, _ b: DagDBEngine) -> Int {
        let n = a.nodeCount
        let pa = a.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let pb = b.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        var d = 0
        for i in 0..<n where pa[i] != pb[i] { d += 1 }
        return d
    }

    /// Whether F's ticks batch here (no kernel-evaluated destination: those
    /// take one tick per call of `tick`, two command buffers each).
    func batches(_ h: DagDBCommandHandler) -> Bool {
        let e = h.engine
        let reg = e.isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: max(e.nodeCount, 1))
        return e.backEdgeDsts.allSatisfy { reg[Int($0)] != 0 }
    }

    /// The same command on P, F and K; replies (elapsed= and nodes_computed=
    /// stripped), truth bytes and tick totals compared; the honest
    /// count and the waits; after `stable`, TICK 5.
    @discardableResult
    func until(_ t: Three, _ cmd: String, _ tally: inout Tally, _ label: String,
               file: StaticString = #filePath, line: UInt = #line) -> String {
        let before = t.p.engine.readTruthStates()
        let rp = t.p.handle(cmd), rf = t.f.handle(cmd), rk = t.k.handle(cmd)
        tally.calls += 1
        XCTAssertTrue(rp.hasPrefix("OK TICK UNTIL_STABLE"), "\(label) '\(cmd)': \(rp)", file: file, line: line)
        XCTAssertEqual(strip(rf), strip(rp), "\(label) '\(cmd)': F against pre-F", file: file, line: line)
        XCTAssertEqual(strip(rk), strip(rp), "\(label) '\(cmd)': K against pre-F", file: file, line: line)
        let dF = differing(t.p.engine, t.f.engine), dK = differing(t.p.engine, t.k.engine)
        XCTAssertEqual(dF, 0, "\(label) '\(cmd)': F's truth bytes", file: file, line: line)
        XCTAssertEqual(dK, 0, "\(label) '\(cmd)': K's truth bytes", file: file, line: line)
        XCTAssertEqual(t.f.tickCount, t.p.tickCount, "\(label) '\(cmd)': F's tick total", file: file, line: line)
        XCTAssertEqual(t.k.tickCount, t.p.tickCount, "\(label) '\(cmd)': K's tick total", file: file, line: line)
        if strip(rf) != strip(rp) || strip(rk) != strip(rp) || dF != 0 || dK != 0
            || t.f.tickCount != t.p.tickCount || t.k.tickCount != t.p.tickCount { tally.mismatches += 1 }
        let after = t.p.engine.readTruthStates()
        for i in 0..<after.count where after[i] != before[i] { tally.movedBytes += 1 }
        guard rp.hasPrefix("OK TICK UNTIL_STABLE"), let run = field(rp, "run") else { return rp }
        tally.ticksRun += run
        // The honest nodes_computed=.
        let nf = field(rf, "nodes_computed") ?? -1, nk = field(rk, "nodes_computed") ?? -2
        let np = field(rp, "nodes_computed") ?? -3
        XCTAssertEqual(np, t.p.engine.rankDispatchNodeCount() * run, "\(label): pre-F's count", file: file, line: line)
        XCTAssertEqual(nf, nk, "\(label) '\(cmd)': F's evaluated node slots equal K's (the overrun evaluated nothing)",
                       file: file, line: line)
        XCTAssertLessThanOrEqual(nf, np, "\(label) '\(cmd)': the frontier evaluates no more than pre-F",
                                 file: file, line: line)
        XCTAssertEqual(nf, t.f.lastUntilStableEvaluated, file: file, line: line)
        tally.evaluatedF += nf; tally.evaluatedP += np
        // The GPU-wait bound's shape.
        tally.batchesF += t.f.lastUntilStableBatches
        tally.waitsF += t.f.lastUntilStableGPUWaits
        tally.waitsK += t.k.lastUntilStableGPUWaits
        XCTAssertGreaterThanOrEqual(t.k.lastUntilStableGPUWaits, run, "\(label): K waits once per tick at least",
                                    file: file, line: line)
        if batches(t.f) && t.f.engine.latchOnGPU != false {
            tally.waitsBounded += 1
            XCTAssertLessThanOrEqual(t.f.lastUntilStableGPUWaits, (run + 3) / 4 + 2,
                                     "\(label) '\(cmd)': F3.6, CPU waits per UNTIL_STABLE ≤ ⌈run/4⌉ + 2 (run \(run))",
                                     file: file, line: line)
            XCTAssertEqual(t.f.lastUntilStableBatches, t.f.lastUntilStableGPUWaits, file: file, line: line)
        }
        let stable = rp.hasPrefix("OK TICK UNTIL_STABLE stable ")
        if stable { tally.stable += 1 } else { tally.notStable += 1 }
        // A fixed point is absorbing; the batch's overrun left nothing behind.
        if stable {
            let fixed = t.f.engine.readTruthStates()
            let r5 = t.all.map { $0.handle("TICK 5") }
            XCTAssertTrue(r5[0].hasPrefix("OK TICK 5 "), "\(label): \(r5[0])", file: file, line: line)
            XCTAssertEqual(strip(r5[1]), strip(r5[0]), "\(label): F3.2 TICK 5", file: file, line: line)
            XCTAssertEqual(strip(r5[2]), strip(r5[0]), "\(label): F3.2 TICK 5", file: file, line: line)
            XCTAssertEqual(t.f.engine.readTruthStates(), fixed,
                           "\(label) '\(cmd)': F3.2, TICK 5 after stable changed a byte", file: file, line: line)
            XCTAssertEqual(t.p.engine.readTruthStates(), fixed, "\(label): F3.2 on pre-F", file: file, line: line)
            XCTAssertEqual(t.f.tickCount, t.p.tickCount, file: file, line: line)
            tally.f32Checks += 1
        }
        return rp
    }

    /// The same command on P, F and K (not an UNTIL_STABLE): replies up to
    /// `elapsed`, truth bytes compared.
    func each(_ t: Three, _ cmd: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let r = t.all.map { $0.handle(cmd) }
        XCTAssertTrue(r[0].hasPrefix("OK"), "\(label) '\(cmd)': \(r[0])", file: file, line: line)
        for x in r.dropFirst() {
            XCTAssertEqual(strip(x).components(separatedBy: "elapsed")[0], strip(r[0]).components(separatedBy: "elapsed")[0],
                           "\(label) '\(cmd)'", file: file, line: line)
        }
        XCTAssertEqual(differing(t.p.engine, t.f.engine), 0, "\(label) '\(cmd)': F", file: file, line: line)
        XCTAssertEqual(differing(t.p.engine, t.k.engine), 0, "\(label) '\(cmd)': K", file: file, line: line)
    }

    // MARK: - The cases of EngineE2DaemonTests.floodChain / oscillators (as EngineE5DaemonTests and EngineF2DaemonTests copy them)

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

    /// The frontier test seam's log line (the daemon prints it when DAGDB_FRONTIER_FOR_TESTING=1): one line
    /// per TICK UNTIL_STABLE, under its plain prefix.
    func testFrontierTestLogLineHasItsPlainPrefix() throws {
        let f = try HandlerFixture(side: 16)
        var lines: [String] = []
        f.handler.frontierTestLog = { lines.append($0) }
        floodChain(f, m: 8)
        let r = f.handler.handle("TICK UNTIL_STABLE MAX 40")
        XCTAssertTrue(r.hasPrefix("OK TICK UNTIL_STABLE"), r)
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.first?.hasPrefix("until_stable: run=") == true, "\(lines)")
    }

    func testF3_1E2GateCasesAndTheTwoEnds() throws {
        var tally = Tally()
        // The converging flood (40 registers): `stable ticks=39 run=40`,
        // its batches 16 + 16 + 16, the fixed point found at tick 40 of 48;
        // then again, already stable: `ticks=0 run=1`.
        do {
            let t = try three { self.floodChain($0, m: 40) }
            let r1 = until(t, "TICK UNTIL_STABLE", &tally, "E2 flood")
            XCTAssertTrue(r1.hasPrefix("OK TICK UNTIL_STABLE stable ticks=39 run=40 changed=0 latched=0 "), r1)
            // Was `XCTAssertEqual(t.f.lastUntilStableBatches, 3)` under a fixed k = 16; the bounds below are the binding form.
            XCTAssertLessThanOrEqual(t.f.lastUntilStableGPUWaits, (40 + 3) / 4 + 2, "F3.6: waits ≤ ⌈run/4⌉ + 2")
            XCTAssertLessThanOrEqual(t.f.lastUntilStableTicksEncoded, 2 * 40, "F3F.1: ticks encoded ≤ 2·run")
            XCTAssertEqual(t.f.engine.lastFrontierBatchTicks, 16, "the last batch ran past the fixed point")
            let r2 = until(t, "TICK UNTIL_STABLE MAX 5", &tally, "E2 already stable")
            XCTAssertTrue(r2.hasPrefix("OK TICK UNTIL_STABLE stable ticks=0 run=1 "), r2)
            tally.cases += 2
        }
        // The oscillator (5 NOR registers) at MAX 7: never stable.
        do {
            let t = try three { self.oscillators($0, k: 5) }
            let r = until(t, "TICK UNTIL_STABLE MAX 7", &tally, "E2 oscillator")
            XCTAssertTrue(r.hasPrefix("OK TICK UNTIL_STABLE not stable after MAX 7 ticks=7 run=7 changed=10 latched=5 "), r)
            until(t, "TICK UNTIL_STABLE MAX 40", &tally, "E2 oscillator, MAX 40")
            tally.cases += 1
        }
        // The flood seeded mid-chain (30 registers, seeded at 12): ticks 17, run 18.
        do {
            let t = try three { f in self.floodChain(f, m: 30, seed: false)
                XCTAssertTrue(f.handler.handle("SET 12 TRUTH 1").hasPrefix("OK")) }
            let r = until(t, "TICK UNTIL_STABLE MAX 100", &tally, "E2 mid-seeded")
            XCTAssertTrue(r.hasPrefix("OK TICK UNTIL_STABLE stable ticks=17 run=18 "), r)
            tally.cases += 1
        }
        // A graph stable from the start (no edge, no register).
        do {
            let t = try three { _ in }
            let r = until(t, "TICK UNTIL_STABLE", &tally, "empty graph")
            XCTAssertTrue(r.contains(" run=") , r)
            until(t, "TICK UNTIL_STABLE", &tally, "empty graph, again")
            tally.cases += 1
        }
        print("F3.1 E2 cases: " + tally.line)
        XCTAssertEqual(tally.mismatches, 0)
    }

    /// MAX cutting a batch (MAX 1, 3, 17, 33 on a 40-tick flood,
    /// and the batch edges 16, 32, 39–41, 48), then the rest of the flood.
    func testF3_1MaxCutsABatchOnThe40TickFlood() throws {
        var tally = Tally()
        for mx in [1, 3, 16, 17, 32, 33, 39, 40, 41, 48] {
            let t = try three { self.floodChain($0, m: 40) }
            let r = until(t, "TICK UNTIL_STABLE MAX \(mx)", &tally, "flood MAX \(mx)")
            if mx < 40 {
                XCTAssertTrue(r.hasPrefix("OK TICK UNTIL_STABLE not stable after MAX \(mx) ticks=\(mx) run=\(mx) "), r)
                // Was `XCTAssertEqual(t.f.lastUntilStableBatches, (mx + 15) / 16, …)` under a fixed k = 16.
                XCTAssertLessThanOrEqual(t.f.lastUntilStableGPUWaits, (mx + 3) / 4 + 2, "MAX \(mx): F3.6, waits ≤ ⌈run/4⌉ + 2")
                XCTAssertLessThanOrEqual(t.f.lastUntilStableTicksEncoded, 2 * mx, "MAX \(mx): F3F.1, ticks encoded ≤ 2·run")
                XCTAssertEqual(t.f.lastUntilStableEvaluated > 0, true)
            } else {
                XCTAssertTrue(r.hasPrefix("OK TICK UNTIL_STABLE stable ticks=39 run=40 "), r)
            }
            XCTAssertEqual(t.f.tickCount, UInt32(mx < 40 ? mx : 40 + 5), "the total moves by run (and F3.2's TICK 5)")
            until(t, "TICK UNTIL_STABLE", &tally, "flood after MAX \(mx)")
            tally.cases += 1
        }
        print("F3.1 MAX cuts on the 40-tick flood: " + tally.line)
        XCTAssertEqual(tally.mismatches, 0)
    }

    // MARK: - The 48 reply cases of EngineE5DaemonTests (its graph, copied)

    func e5Graph(_ f: HandlerFixture, seed: UInt64, ternary: Bool, dup: Bool, evaluated: Int) throws {
        let e = f.handler.engine
        try EngineE1DaemonTests.buildGraph(e, seed: seed, ternary: ternary)
        let n = e.nodeCount
        var g = Rng(s: seed &+ 77)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        let free = (0..<n).filter { i in
            !TernaryReference.isTernary(e.modeByte(i)) && (0..<6).allSatisfy { nb[i * 6 + $0] < 0 }
        }
        for _ in 0..<min(20, free.count) {
            let d = free[g.below(free.count)], s = g.below(n)
            if s != d { try e.addBackEdge(src: UInt32(s), dst: UInt32(d)) }
        }
        if dup, let d0 = e.backEdgeDsts.first {
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
    }

    func testF3_1E5ReplyCases() throws {
        var tally = Tally()
        for side in [16, 32] {
            for ternary in [false, true] {
                for seed: UInt64 in [5, 6] {
                    for (dup, ev) in [(false, 0), (true, 2)] {
                        for k in [1, 3, 50] {
                            let s = seed &* 13 &+ UInt64(side) &+ (ternary ? 1000 : 0)
                            let t = try three(side: side) { try self.e5Graph($0, seed: s, ternary: ternary, dup: dup, evaluated: ev) }
                            until(t, "TICK UNTIL_STABLE MAX \(k)", &tally,
                                  "E5 side \(side) ternary \(ternary) seed \(s) dup \(dup) ev \(ev) MAX \(k)")
                            tally.cases += 1
                        }
                    }
                }
            }
        }
        print("F3.1 E5's reply cases: " + tally.line)
        XCTAssertEqual(tally.cases, 48)
        XCTAssertEqual(tally.mismatches, 0)
    }

    // MARK: - Mixed graphs, the voxel morphology layout A, a NOSKIP walk, kernel-evaluated destinations

    func testF3_1R3MixedGraphsThroughTheVerb() throws {
        var tally = Tally()
        for (side, seeds) in [(64, 3), (256, 2)] {
            for s in 0..<seeds {
                let seed = UInt64(0x7E13_F300) &+ UInt64(side) << 8 &+ UInt64(s)
                let g = EngineF2DaemonTests.r3Mixed(side: side, seed: seed)
                let t = try three(engines: { try EngineF2DaemonTests.r3Engine(g, side: side, seed: seed) },
                                  side: side, maxRank: EngineF2DaemonTests.r3RankLevels)
                XCTAssertGreaterThan(t.p.engine.nonBinaryNodeCount, 0)
                let label = "R3 side \(side) seed \(s)"
                for cmd in ["TICK UNTIL_STABLE MAX 40", "TICK UNTIL_STABLE MAX 17", "TICK UNTIL_STABLE MAX 1",
                            "TICK UNTIL_STABLE MAX 50"] {
                    until(t, cmd, &tally, label)
                }
                each(t, "TICK 3", label)
                until(t, "TICK UNTIL_STABLE MAX 33", &tally, label + " after TICK 3")
                tally.cases += 1
            }
        }
        print("F3.1 R3 mixed graphs: " + tally.line)
        XCTAssertEqual(tally.mismatches, 0)
        XCTAssertGreaterThan(tally.movedBytes, 0, "not vacuous")
    }

    func testF3_1VoxelLayoutAPhases() throws {
        var tally = Tally()
        typealias VoxelA = EngineF2DaemonTests.VoxelA
        for ternary in [false, true] {
            let lay = VoxelA(n: 16)
            let fld = lay.field(seed: 0xF3_0016)
            let t = try three(engines: { try lay.makeEngine(field: fld, ternary: ternary) },
                              side: lay.side, maxRank: lay.maxRank)
            let label = "voxel layout A 16³ ternary=\(ternary)"
            for round in 0..<2 {
                for (phase, cmd) in [("surface", "TICK 1"), ("seed", "TICK 1"), ("dilate", "TICK 3"), ("erode", "TICK 3"),
                                     ("zero", "TICK 1"), ("flood", "TICK UNTIL_STABLE MAX 600"), ("extract", "TICK 1")] {
                    for h in t.all { lay.setLuts(h.engine, lay.luts(phase, field: fld)) }
                    if cmd.hasPrefix("TICK UNTIL_STABLE") {
                        let r = until(t, cmd, &tally, "\(label) round \(round) \(phase)")
                        XCTAssertTrue(r.hasPrefix("OK TICK UNTIL_STABLE stable "), r)
                        print("F3.1 \(label) round \(round) flood: \(strip(r))")
                    } else {
                        each(t, cmd, "\(label) round \(round) \(phase)")
                    }
                }
            }
            XCTAssertEqual(t.f.engine.frontierIndexBuildCount, 1, "\(label): one index across the LUT writes")
            tally.cases += 1
        }
        print("F3.1 voxel layout A 16³: " + tally.line)
        XCTAssertEqual(tally.mismatches, 0)
    }

    /// The NOSKIP walk of EngineF2DaemonTests.noskipWalk, copied: TTHRESH NOSKIP
    /// readers of a 4-register ring latched in two phases.
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
                XCTAssertTrue(h.handle("CONNECT BACK FROM \(ring[k]) TO \(ring[(k + 1) % 4])").hasPrefix("OK"))
            }
            for (k, r) in ring.enumerated() { XCTAssertTrue(h.handle("SET \(r) TRUTH \(k < 2 ? 1 : 0)").hasPrefix("OK")) }
            XCTAssertTrue(h.handle("SET \(x) TRUTH 0").hasPrefix("OK"))
            XCTAssertTrue(h.handle("SET \(x) MODE TTHRESH NOSKIP").hasPrefix("OK"))
            XCTAssertTrue(h.handle("SET \(x) THRESH -0.5 0.5").hasPrefix("OK"))
            XCTAssertTrue(h.handle("SET \(y) LUT AAAAAAAAAAAAAAAA").hasPrefix("OK"))
        }
    }

    func testF3_1NoskipWalkAndKernelEvaluatedDestinations() throws {
        var tally = Tally()
        for tau in [0.25, Double.infinity] {
            let t = try three { self.noskipWalk($0, units: 8) }
            t.f.engine.frontierWholeFraction = tau
            t.k.engine.frontierWholeFraction = tau
            let label = "NOSKIP walk τ=\(tau)"
            until(t, "TICK UNTIL_STABLE MAX 40", &tally, label)
            until(t, "TICK UNTIL_STABLE MAX 19", &tally, label)
            XCTAssertTrue(t.f.engine.lastLatchTwoPhase)
            tally.cases += 1
        }
        // Kernel-evaluated destinations (register flags cleared by a raw
        // write): one tick per call of `tick`, two command buffers each.
        for side in [16, 32] {
            for ternary in [false, true] {
                let s = UInt64(0xF3E0) &+ UInt64(side) &+ (ternary ? 9 : 0)
                let t = try three(side: side) { try self.e5Graph($0, seed: s, ternary: ternary, dup: true, evaluated: 3) }
                XCTAssertFalse(batches(t.f))
                let label = "evaluated destinations side \(side) ternary \(ternary)"
                until(t, "TICK UNTIL_STABLE MAX 30", &tally, label)
                until(t, "TICK UNTIL_STABLE MAX 5", &tally, label)
                tally.cases += 1
            }
        }
        print("F3.1 NOSKIP walk and kernel-evaluated destinations: " + tally.line)
        XCTAssertEqual(tally.mismatches, 0)
    }

    // MARK: - The CPU's waits on the GPU per UNTIL_STABLE

    /// A 68-register flood: run 68, the 128³ cavity flood's (run live at
    /// 128³); ⌈68/4⌉ + 2 = 19. F: batches of
    /// 16, 5 waits. K (k forced to 1, the control's shape): 68. Pre-frontier: 68.
    func testF3_6CPUWaitsPerUntilStable() throws {
        var tally = Tally()
        for (m, wantBatches) in [(68, 5), (40, 3), (17, 2), (16, 1)] {
            let t = try three { self.floodChain($0, m: m) }
            let r = until(t, "TICK UNTIL_STABLE", &tally, "flood of \(m)")
            XCTAssertTrue(r.hasPrefix("OK TICK UNTIL_STABLE stable ticks=\(m - 1) run=\(m) "), r)
            let bound = (m + 3) / 4 + 2
            XCTAssertLessThanOrEqual(t.f.lastUntilStableGPUWaits, bound, "F3.6: run \(m), bound \(bound)")
            // Was `XCTAssertEqual(t.f.lastUntilStableGPUWaits, wantBatches)` under a fixed k = 16 (5 / 3 / 2 / 1).
            XCTAssertLessThanOrEqual(t.f.lastUntilStableTicksEncoded, 2 * m,
                                     "F3F.1: ticks encoded ≤ 2·run (run \(m); F3's k = 16 took \(wantBatches) waits)")
            XCTAssertEqual(t.k.lastUntilStableGPUWaits, m, "one tick per command buffer: one wait per tick")
            XCTAssertEqual(t.p.lastUntilStableGPUWaits, m, "pre-F: one wait per tick")
            print("F3.6 flood of \(m): run \(m), bound \(bound); CPU waits F \(t.f.lastUntilStableGPUWaits) "
                  + "(\(t.f.lastUntilStableBatches) batches), K (k = 1) \(t.k.lastUntilStableGPUWaits), "
                  + "pre-F \(t.p.lastUntilStableGPUWaits)")
            tally.cases += 1
        }
        XCTAssertEqual(tally.mismatches, 0)
    }

    /// The engine's batch on its own: per-tick counts equal to a counting
    /// session's ticks one at a time, the bytes equal at every batch's end,
    /// and a batch that runs past a fixed point changes no byte.
    func testF3_2SessionTicksPastTheFixedPointChangeNothing() throws {
        let t = try three { self.floodChain($0, m: 40) }
        let a = t.p.engine, b = t.f.engine
        try a.prepareRankLists(); try b.prepareRankLists()
        var perTick: [DagDBEngine.SessionTick] = []
        try a.countingLatchChanges { ca in
            for n in 0..<48 {
                ca.lastCount = 0
                a.tick(tickNumber: UInt32(n), rankOrderVerified: true)
                perTick.append(DagDBEngine.SessionTick(changed: ca.lastChanged, latched: ca.lastCount))
            }
        }
        XCTAssertEqual(perTick[39], DagDBEngine.SessionTick(changed: 0, latched: 0))
        var got: [DagDBEngine.SessionTick] = []
        var states: [[UInt8]] = []
        var past: DagDBEngine.SessionBatch?
        try b.frontierSession { _ in
            for _ in 0..<3 {
                let batch = b.sessionTicks(16, tickNumber: 0)
                XCTAssertTrue(batch.batched)
                XCTAssertEqual(batch.ticks.count, 16)
                XCTAssertEqual(b.lastFrontierBatchTicks, 16)
                got += batch.ticks
                states.append(b.readTruthStates())
            }
            past = b.sessionTicks(16, tickNumber: 0)        // every tick past the fixed point
        }
        XCTAssertEqual(got, perTick, "per-tick counts of three batches of 16 against 48 single counting ticks")
        XCTAssertEqual(states[2], a.readTruthStates(), "the bytes after 48 ticks")
        XCTAssertTrue(got[39...].allSatisfy { $0 == DagDBEngine.SessionTick(changed: 0, latched: 0) },
                      "ticks 40–48 ran from the fixed point")
        XCTAssertEqual(b.readTruthStates(), states[2], "a batch from the fixed point changes no byte")
        XCTAssertEqual(past?.evaluated, 0, "and evaluates nothing")
        XCTAssertEqual(past?.ticks.count, 16)
        XCTAssertTrue(past?.ticks.allSatisfy { $0 == DagDBEngine.SessionTick(changed: 0, latched: 0) } ?? false)
        print("F3.2 engine: 48 ticks in 3 batches equal to 48 counting ticks; a 4th batch of 16 from the fixed point "
              + "changed \(past?.ticks.map(\.changed).reduce(0, +) ?? -1) bytes, evaluated \(past?.evaluated ?? -1) node slots")
    }

    // MARK: - The enumerated writers between two UNTIL_STABLEs, against the pre-frontier loop

    /// The writers' check as `EngineF2DaemonTests` ran it, with A the pre-frontier loop
    /// (a handler's default is now the frontier) and F, K the frontier.
    func f22Three() throws -> (Three, [HandlerFixture]) {
        var fs: [HandlerFixture] = []
        for root in ["P", "F", "K"] {
            try FileManager.default.createDirectory(atPath: tmp + root, withIntermediateDirectories: true)
            let f = try HandlerFixture(side: 16, dataRoot: tmp + root)
            try EngineE1DaemonTests.buildGraph(f.handler.engine, seed: 0xF22, ternary: true)
            fs.append(f)
        }
        return (Three(fs[0].handler, fs[1].handler, fs[2].handler, keep: fs), fs)
    }

    func source(seed: UInt64) throws -> DagDBEngine {
        let e = try DagDBEngine(grid: try HexGrid(width: 16, height: 16), state: DagDBState(width: 16, height: 16),
                                maxRank: 8)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        try EngineE1DaemonTests.buildGraph(e, seed: seed, ternary: true)
        return e
    }

    enum Kind: String { case topology, table, mode, truth, tick, read }

    struct Writer {
        let name: String
        let kind: Kind
        let make: (HandlerFixture) throws -> String
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

    /// Every lane the engine holds, hashed (a writer must change one).
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

    func testF3_1F22WritersBetweenTwoUntilStablesAgainstPreF() throws {
        var tally = Tally()
        var lines: [String] = []
        for w in writers() {
            let (t, fs) = try f22Three()
            let label = w.name
            until(t, "TICK UNTIL_STABLE MAX 25", &tally, label + ": the first UNTIL_STABLE")
            XCTAssertEqual(t.f.engine.frontierIndexBuildCount, 1, label)
            let d0 = digest(t.p.engine)
            let r = try fs.map { f in f.handler.handle(try w.make(f)) }
            XCTAssertTrue(r[0].hasPrefix("OK"), "\(label): \(r[0])")
            for x in r.dropFirst() {
                XCTAssertEqual(strip(x).components(separatedBy: "elapsed")[0], strip(r[0]).components(separatedBy: "elapsed")[0], label)
            }
            let changed = digest(t.p.engine) != d0
            if w.kind != .read && w.kind != .tick { XCTAssertTrue(changed, "\(label): the writer changes the engine") }
            XCTAssertEqual(t.f.engine.hasFrontierIndex, w.kind != .topology, "\(label): index kept")
            let r1 = until(t, "TICK UNTIL_STABLE MAX 25", &tally, label + ": after the writer")
            XCTAssertEqual(t.f.engine.frontierIndexBuildCount, w.kind == .topology ? 2 : 1, "\(label): index builds")
            until(t, "TICK UNTIL_STABLE MAX 5", &tally, label + ": a third")
            let saves = fs.map { f -> Data? in
                let p = f.handler.dataRoot! + "/end.dags"
                return f.handler.handle("SAVE \(p)").hasPrefix("OK") ? FileManager.default.contents(atPath: p) : nil
            }
            XCTAssertNotNil(saves[0], label)
            XCTAssertEqual(saves[1], saves[0], "\(label): SAVE bytes F")
            XCTAssertEqual(saves[2], saves[0], "\(label): SAVE bytes K")
            if saves[1] != saves[0] || saves[2] != saves[0] { tally.mismatches += 1 }
            lines.append("\(label) [\(w.kind.rawValue)]: engine changed \(changed), index builds "
                         + "\(t.f.engine.frontierIndexBuildCount); '\(strip(r1))'")
            tally.cases += 1
        }
        for l in lines { print("F3.1 F2.2 writer " + l) }
        print("F3.1 F2.2's writers against pre-F: " + tally.line)
        XCTAssertEqual(tally.cases, 37)
        XCTAssertEqual(tally.mismatches, 0)
    }
}
