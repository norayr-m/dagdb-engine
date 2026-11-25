import XCTest
import Metal
@testable import DagDB
@testable import DagDBDaemonKit

/// The batch ramp, the command-buffer status check, the depth guard.
///
/// Two handlers per case, built the same way:
///   P — the pre-frontier loop (`untilStablePreFForTesting`, the engine's
///       `latchOnGPU = false`): the counting session, the CPU counting latch,
///       one tick per command buffer — TICK UNTIL_STABLE as it ran before the
///       frontier session, the reference;
///   F — the verb's default.
/// Every TICK UNTIL_STABLE reply of F equals P's with `elapsed=` and
/// `nodes_computed=` stripped; truth bytes and tick totals equal after every
/// call; after every `stable` reply a `TICK 5` moves no byte.
///
/// Structure: the ticks encoded per UNTIL_STABLE ≤ 2·run on every call,
/// ≤ 2 on a stable graph; the waits bound, the CPU's waits ≤ ⌈run/4⌉ + 2, wherever
/// the ticks batch on the frontier; every command buffer holds ≤ 131,072
/// dispatches or exactly one tick (the dispatch cap, measured on deep chains
/// with the depth guard off). Cases: floods of 1…70 registers, register
/// rings of period 2…40 at MAX around their period and the batch edges, the
/// stable graphs (empty, a flood at its fixed point, a deep chain at R*).
/// Control that must fail: k fixed at 16 encodes 16 ticks on a stable graph.
///
/// Status: a fault-injection seam (`commandBufferStatusFailsAfterForTesting`)
/// makes the engine read a command buffer's status as failed after its wait;
/// every tick path — plain TICK, TICK_SYNC, EVAL, UNTIL_STABLE's batches, its
/// per-tick frontier (kernel-evaluated destinations) and its counting path
/// (past the depth guard), the pre-frontier loop — replies `ERROR gpu:` naming the
/// status, claims no state (no `OK`, no `stable`), and the tick total counts
/// only the ticks whose buffers completed. The next command, seam spent,
/// replies OK. Control that must fail: the check removed, the seam case
/// replies OK.
///
/// The depth guard's structural half (the full check runs live): the
/// frontier runs on graphs with ≤ R* non-empty rank levels, deeper graphs take
/// the counting path (no reverse index built), replies equal to the
/// pre-frontier loop's either side; R* in [16, 63]; a graph whose rank values
/// are large but whose non-empty levels are few stays on the frontier; the
/// 16-level random mixed graphs stay on it (the reason for R* ≥ 16).
///
/// Red on the older code: does not compile — no `lastUntilStableTicksEncoded`,
/// `commandBufferStatusFailsAfterForTesting`, `frontierMaxRankLevels`,
/// `frontierDepthGuardDefault`, `nonEmptyRankLevels`, `gpuFailure`.
final class EngineF3FDaemonTests: XCTestCase {

    typealias Held = EngineF3DaemonTests.Held

    // MARK: - Two handlers

    struct Pair {
        let p: DagDBCommandHandler, f: DagDBCommandHandler
        let keep: [AnyObject]
        init(_ p: DagDBCommandHandler, _ f: DagDBCommandHandler, keep: [AnyObject]) {
            self.p = p; self.f = f; self.keep = keep
            p.untilStablePreFForTesting = true
            p.engine.latchOnGPU = false          // pre-F's CPU counting latch
        }
        var both: [DagDBCommandHandler] { [p, f] }
    }

    func pair(side: Int = 16, _ build: (HandlerFixture) throws -> Void) throws -> Pair {
        let fs = try (0..<2).map { _ in try HandlerFixture(side: side) }
        for f in fs { try build(f); XCTAssertNil(f.handler.rankTickDagRefusal()) }
        return Pair(fs[0].handler, fs[1].handler, keep: fs)
    }

    func pair(engines make: () throws -> DagDBEngine, side: Int) throws -> Pair {
        let hs = try (0..<2).map { _ in try Held(try make(), side: side, maxRank: 16) }
        for h in hs { XCTAssertNil(h.handler.rankTickDagRefusal()) }
        return Pair(hs[0].handler, hs[1].handler, keep: hs)
    }

    // MARK: - Graphs

    /// The converging flood of EngineE2DaemonTests.floodChain, as EngineF3DaemonTests copies it.
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

    /// A ring of p registers, one 1 rotating: period p, never stable.
    func ring(_ f: HandlerFixture, p: Int) {
        let h = f.handler
        for i in 0..<p {
            XCTAssertTrue(h.handle("CONNECT BACK FROM \(i) TO \((i + 1) % p)").hasPrefix("OK"))
        }
        XCTAssertTrue(h.handle("SET 0 TRUTH 1").hasPrefix("OK"))
    }

    /// Deep objects with one node per rank: node i (i < L) at rank L − 1 − i
    /// reads node i − 1 through slot 0, IDENTITY; every other node rank 0, no
    /// input. Dense: node 1 is NOT and the bottom of the chain feeds node 0 (a
    /// register) by a back edge, so every chain node flips every tick. Stable:
    /// no NOT, no back edge, truth 0 — a fixed point. L non-empty rank levels.
    static func chainEngine(side: Int, levels L: Int, dense: Bool) throws -> DagDBEngine {
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side), maxRank: 16)
        let n = e.nodeCount
        precondition(L >= 3 && L <= n)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        for i in 0..<(n * 6) { nb[i] = -1 }
        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let lo = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let hi = e.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        for i in 0..<n {
            rank[i] = i < L ? UInt64(L - 1 - i) : 0
            lo[i] = 0xAAAA_AAAA; hi[i] = 0xAAAA_AAAA                    // IDENTITY of slot 0
        }
        for i in 1..<L { nb[i * 6] = Int32(i - 1) }
        if dense {
            lo[1] = 0x5555_5555; hi[1] = 0x5555_5555                    // NOT of slot 0
            try e.addBackEdge(src: UInt32(L - 1), dst: 0)
        }
        e.markRankTopologyDirty()
        return e
    }

    static func sideFor(_ nodes: Int) -> Int { Int(Double(nodes).squareRoot().rounded(.up)) }

    // MARK: - The comparison

    struct Tally {
        var calls = 0, mismatches = 0, stable = 0, ticksRun = 0, encodedF = 0, waitsF = 0, batchedCalls = 0
        var maxRatio = 0.0
        var line: String {
            "UNTIL_STABLE calls \(calls) (\(stable) stable), ticks run \(ticksRun), mismatching calls \(mismatches); "
                + "F: ticks encoded \(encodedF) (max encoded / run \(String(format: "%.4f", maxRatio))), "
                + "CPU waits \(waitsF) (\(batchedCalls) calls on the frontier checked against ⌈run/4⌉ + 2)"
        }
    }

    func strip(_ r: String) -> String {
        r.split(separator: " ").filter { !$0.hasPrefix("elapsed=") && !$0.hasPrefix("nodes_computed=") }
            .joined(separator: " ")
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

    /// Whether F's ticks can batch (no kernel-evaluated destination).
    func batchable(_ h: DagDBCommandHandler) -> Bool {
        let e = h.engine
        let reg = e.isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: max(e.nodeCount, 1))
        return e.backEdgeDsts.allSatisfy { reg[Int($0)] != 0 }
    }

    /// The same UNTIL_STABLE on P and F; equivalence and the structure bounds.
    @discardableResult
    func until(_ t: Pair, _ cmd: String, _ tally: inout Tally, _ label: String,
               file: StaticString = #filePath, line: UInt = #line) -> String {
        let rp = t.p.handle(cmd), rf = t.f.handle(cmd)
        tally.calls += 1
        XCTAssertTrue(rp.hasPrefix("OK TICK UNTIL_STABLE"), "\(label) '\(cmd)': \(rp)", file: file, line: line)
        XCTAssertEqual(strip(rf), strip(rp), "\(label) '\(cmd)': F against pre-F", file: file, line: line)
        let d = differing(t.p.engine, t.f.engine)
        XCTAssertEqual(d, 0, "\(label) '\(cmd)': F's truth bytes", file: file, line: line)
        XCTAssertEqual(t.f.tickCount, t.p.tickCount, "\(label) '\(cmd)': tick totals", file: file, line: line)
        if strip(rf) != strip(rp) || d != 0 || t.f.tickCount != t.p.tickCount { tally.mismatches += 1 }
        guard rp.hasPrefix("OK TICK UNTIL_STABLE"), let run = field(rp, "run") else { return rp }
        tally.ticksRun += run
        let stable = rp.hasPrefix("OK TICK UNTIL_STABLE stable ")
        // Ticks encoded ≤ 2·run; ≤ 2 on a stable graph; the pre-frontier loop encodes run.
        let enc = t.f.lastUntilStableTicksEncoded
        tally.encodedF += enc
        tally.maxRatio = max(tally.maxRatio, Double(enc) / Double(run))
        XCTAssertGreaterThanOrEqual(enc, run, "\(label) '\(cmd)': every tick run was encoded", file: file, line: line)
        XCTAssertLessThanOrEqual(enc, 2 * run, "\(label) '\(cmd)': F3F.1, ticks encoded ≤ 2·run (run \(run))",
                                 file: file, line: line)
        if stable && field(rp, "ticks") == 0 {
            XCTAssertLessThanOrEqual(enc, 2, "\(label) '\(cmd)': F3F.1, ≤ 2 ticks on a stable graph", file: file, line: line)
        }
        XCTAssertEqual(t.p.lastUntilStableTicksEncoded, run, "\(label): pre-F's loop encodes one tick per tick run",
                       file: file, line: line)
        // Every command buffer ≤ 131,072 dispatches, or exactly one tick.
        XCTAssertLessThanOrEqual(t.f.lastUntilStableMaxMultiTickBufferDispatches, DagDBEngine.maxDispatchesPerCommandBuffer,
                                 "\(label) '\(cmd)': F3F.1, a command buffer of ≥ 2 ticks over the dispatch cap",
                                 file: file, line: line)
        // The waits bound, wherever the ticks batch on the frontier (and the
        // dispatch cap leaves room for a full batch: a tick of more than
        // ⌊131,072 / 16⌋ dispatches batches fewer ticks, down to one a buffer).
        tally.waitsF += t.f.lastUntilStableGPUWaits
        let capBinds = 2 * t.f.engine.nonEmptyRankLevels + 3
            > DagDBEngine.maxDispatchesPerCommandBuffer / DagDBCommandHandler.untilStableBatchTicks
        if t.f.lastUntilStableFrontier && batchable(t.f) && !capBinds {
            tally.batchedCalls += 1
            XCTAssertLessThanOrEqual(t.f.lastUntilStableGPUWaits, (run + 3) / 4 + 2,
                                     "\(label) '\(cmd)': F3.6, CPU waits ≤ ⌈run/4⌉ + 2 (run \(run))", file: file, line: line)
        }
        // The overrun is invisible.
        if stable {
            tally.stable += 1
            let fixed = t.f.engine.readTruthStates()
            let r5 = t.both.map { $0.handle("TICK 5") }
            XCTAssertTrue(r5[0].hasPrefix("OK TICK 5 "), "\(label): \(r5[0])", file: file, line: line)
            XCTAssertEqual(strip(r5[1]).components(separatedBy: "elapsed")[0],
                           strip(r5[0]).components(separatedBy: "elapsed")[0], file: file, line: line)
            XCTAssertEqual(t.f.engine.readTruthStates(), fixed, "\(label) '\(cmd)': F3.2, TICK 5 after stable moved a byte",
                           file: file, line: line)
        }
        return rp
    }

    // MARK: - Structure

    /// Floods of 1…70 registers (EngineE2DaemonTests.floodChain; run = m), each run to its fixed point and
    /// then once more (already stable), and cut by MAX around the batch edges.
    func testF3F_1FloodsAndMaxCutsAgainstPreF() throws {
        var tally = Tally()
        var lines: [String] = []
        for m in 1...70 {
            let t = try pair { self.floodChain($0, m: m) }
            let r = until(t, "TICK UNTIL_STABLE", &tally, "flood of \(m)")
            let run = max(m, 2)                 // one register: its OR node changes on tick 1, tick 2 finds the fixed point
            XCTAssertTrue(r.hasPrefix("OK TICK UNTIL_STABLE stable ticks=\(run - 1) run=\(run) "), r)
            lines.append("m \(m): batches \(t.f.lastUntilStableBatches), waits \(t.f.lastUntilStableGPUWaits), "
                         + "encoded \(t.f.lastUntilStableTicksEncoded), largest buffer \(t.f.lastUntilStableMaxBufferTicks) ticks")
            until(t, "TICK UNTIL_STABLE MAX 5", &tally, "flood of \(m), again")
        }
        for mx in [1, 2, 3, 4, 7, 8, 15, 16, 17, 31, 32, 33, 39, 40, 41, 47, 48, 49] {
            let t = try pair { self.floodChain($0, m: 40) }
            until(t, "TICK UNTIL_STABLE MAX \(mx)", &tally, "40-flood MAX \(mx)")
            until(t, "TICK UNTIL_STABLE", &tally, "40-flood after MAX \(mx)")
        }
        print("F3F.1 floods: " + lines.joined(separator: "; "))
        print("F3F.1 floods and MAX cuts: " + tally.line)
        XCTAssertEqual(tally.mismatches, 0)
    }

    /// Register rings of period 2…40 (never stable), MAX around the period and
    /// the batch edges.
    func testF3F_1OscillatorSweepAgainstPreF() throws {
        var tally = Tally()
        for p in 2...40 {
            let t = try pair { self.ring($0, p: p) }
            let maxes = Set([1, max(1, p - 1), p, p + 1, 2 * p, 15, 16, 17, 31, 32, 33, 40, 41, 64, 65, 100]).sorted()
            for mx in maxes {
                let r = until(t, "TICK UNTIL_STABLE MAX \(mx)", &tally, "ring of \(p)")
                XCTAssertTrue(r.hasPrefix("OK TICK UNTIL_STABLE not stable after MAX \(mx) "), r)
                XCTAssertEqual(t.f.lastUntilStableTicksEncoded, mx, "ring of \(p) MAX \(mx): a batch never passes MAX")
            }
        }
        print("F3F.1 oscillator sweep (rings of 2…40): " + tally.line)
        XCTAssertEqual(tally.mismatches, 0)
    }

    /// Stable graphs: one tick encoded (≤ 2), one batch, one wait. The
    /// control (k fixed at 16) encodes 16 here.
    func testF3F_1StableGraphEncodesAtMostTwoTicks() throws {
        var tally = Tally()
        let empty = try pair { _ in }
        for cmd in ["TICK UNTIL_STABLE", "TICK UNTIL_STABLE MAX 5", "TICK UNTIL_STABLE"] {
            until(empty, cmd, &tally, "empty graph")
            XCTAssertLessThanOrEqual(empty.f.lastUntilStableTicksEncoded, 2, "empty graph: ≤ 2 ticks encoded")
        }
        let flood = try pair { self.floodChain($0, m: 40) }
        until(flood, "TICK UNTIL_STABLE", &tally, "40-flood")
        for cmd in ["TICK UNTIL_STABLE", "TICK UNTIL_STABLE MAX 100"] {
            let r = until(flood, cmd, &tally, "40-flood at its fixed point")
            XCTAssertTrue(r.hasPrefix("OK TICK UNTIL_STABLE stable ticks=0 run=1 "), r)
            XCTAssertLessThanOrEqual(flood.f.lastUntilStableTicksEncoded, 2, "a flood at its fixed point: ≤ 2 ticks encoded")
            XCTAssertEqual(flood.f.lastUntilStableGPUWaits, 1)
        }
        let L = DagDBEngine.frontierDepthGuardDefault
        let deep = try pair(engines: { try Self.chainEngine(side: 16, levels: L, dense: false) }, side: 16)
        for cmd in ["TICK UNTIL_STABLE", "TICK UNTIL_STABLE MAX 64"] {
            let r = until(deep, cmd, &tally, "a stable chain of \(L) levels (R*)")
            XCTAssertTrue(r.hasPrefix("OK TICK UNTIL_STABLE stable ticks=0 run=1 "), r)
            XCTAssertTrue(deep.f.lastUntilStableFrontier, "R* levels: on the frontier")
            XCTAssertLessThanOrEqual(deep.f.lastUntilStableTicksEncoded, 2, "a stable chain: ≤ 2 ticks encoded")
        }
        print("F3F.1 stable graphs: " + tally.line)
        XCTAssertEqual(tally.mismatches, 0)
    }

    /// The dispatch cap (≤ 131,072 dispatches per command buffer,
    /// k ≥ 1), on the dense chain with the depth guard off (past R* the guard
    /// takes the counting path, one tick per buffer, before the cap could
    /// bind). A frontier tick of L non-empty levels is 2L + 2 dispatches (an
    /// args kernel and a rank kernel per rank, the latch's args and kernel):
    /// at 20,000 levels the cap allows ⌊131,072 / 40,002⌋ = 3 ticks per
    /// buffer, at 70,000 levels (140,002 dispatches a tick) exactly one.
    func testF3F_1DispatchCapPerCommandBuffer() throws {
        var tally = Tally()
        for (L, mx) in [(20_000, 12), (70_000, 4)] {
            let side = Self.sideFor(L)
            let t = try pair(engines: { try Self.chainEngine(side: side, levels: L, dense: true) }, side: side)
            t.f.engine.frontierMaxRankLevels = Int.max            // the guard off: the frontier at any depth
            let perTick = 2 * L + 2
            let cap = max(1, DagDBEngine.maxDispatchesPerCommandBuffer / perTick)
            let r = until(t, "TICK UNTIL_STABLE MAX \(mx)", &tally, "dense chain of \(L) levels, guard off")
            XCTAssertTrue(r.hasPrefix("OK TICK UNTIL_STABLE not stable after MAX \(mx) "), r)
            XCTAssertTrue(t.f.lastUntilStableFrontier)
            XCTAssertEqual(t.f.engine.nonEmptyRankLevels, L)
            XCTAssertEqual(t.f.lastUntilStableMaxBufferTicks, min(cap, mx), "L \(L): ticks per buffer under the cap")
            if cap == 1 {
                XCTAssertEqual(t.f.lastUntilStableMaxMultiTickBufferDispatches, 0, "L \(L): every buffer exactly one tick")
                XCTAssertEqual(t.f.lastUntilStableGPUWaits, mx)
            } else {
                XCTAssertEqual(t.f.lastUntilStableMaxMultiTickBufferDispatches, cap * perTick, "L \(L): the largest buffer")
            }
            print("F3F.1 dispatch cap, L \(L): \(perTick) dispatches a tick, cap \(cap) ticks a buffer; "
                  + "largest buffer \(t.f.lastUntilStableMaxBufferTicks) ticks / "
                  + "\(t.f.lastUntilStableMaxMultiTickBufferDispatches) dispatches; waits \(t.f.lastUntilStableGPUWaits); '\(strip(r))'")
        }
        XCTAssertEqual(tally.mismatches, 0)
    }

    // MARK: - The command buffer's status on every tick path

    func assertFailed(_ r: String, _ verb: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(r.hasPrefix("ERROR gpu: \(verb)"), "\(label): \(r)", file: file, line: line)
        XCTAssertTrue(r.contains("status error"), "\(label): the status by name: \(r)", file: file, line: line)
        XCTAssertFalse(r.contains("OK") || r.contains(" stable"), "\(label): no state claimed: \(r)", file: file, line: line)
    }

    func testF3F_2StatusCheckedOnEveryTickPath() throws {
        var lines: [String] = []
        // Plain TICK (rank mode, one buffer a tick): the 3rd tick's buffer fails.
        do {
            let f = try HandlerFixture(side: 16)
            floodChain(f, m: 10)
            let h = f.handler
            XCTAssertTrue(h.handle("TICK 1").hasPrefix("OK"))
            let t0 = h.tickCount
            h.engine.commandBufferStatusFailsAfterForTesting = 2
            let r = h.handle("TICK 5")
            assertFailed(r, "TICK", "plain TICK 5")
            XCTAssertEqual(h.tickCount, t0 + 2, "plain TICK: the total counts the ticks whose buffers completed")
            XCTAssertNil(h.engine.commandBufferStatusFailsAfterForTesting, "the seam fires once")
            XCTAssertTrue(h.handle("TICK 1").hasPrefix("OK TICK 1 "), "the next TICK, seam spent")
            lines.append("TICK 5: '\(r)'")
        }
        // TICK_SYNC: the 2nd tick's buffer fails.
        do {
            let f = try HandlerFixture(side: 16)
            floodChain(f, m: 10)
            let h = f.handler
            let t0 = h.tickCount
            h.engine.commandBufferStatusFailsAfterForTesting = 1
            let r = h.handle("TICK_SYNC 3")
            assertFailed(r, "TICK_SYNC", "TICK_SYNC 3")
            XCTAssertEqual(h.tickCount, t0 + 1)
            XCTAssertTrue(h.handle("TICK_SYNC 1").hasPrefix("OK TICK_SYNC 1 "))
            lines.append("TICK_SYNC 3: '\(r)'")
        }
        // EVAL (the colour path): its one buffer fails; no rows written.
        do {
            let f = try HandlerFixture(side: 16)
            floodChain(f, m: 10)
            let h = f.handler
            let t0 = h.tickCount
            h.engine.commandBufferStatusFailsAfterForTesting = 0
            let r = h.handle("EVAL")
            assertFailed(r, "EVAL", "EVAL")
            XCTAssertEqual(h.tickCount, t0)
            XCTAssertTrue(h.handle("EVAL").hasPrefix("OK EVAL "))
            lines.append("EVAL: '\(r)'")
        }
        // UNTIL_STABLE's batches on the frontier: the first batch's buffer fails
        // (before this fix the counts read 0 and the verb replied `stable`), then the
        // third (ticks 4–7 of the ramp).
        for after in [0, 2] {
            let f = try HandlerFixture(side: 16)
            floodChain(f, m: 40)
            let h = f.handler
            let t0 = h.tickCount
            h.engine.commandBufferStatusFailsAfterForTesting = after
            let r = h.handle("TICK UNTIL_STABLE")
            assertFailed(r, "TICK UNTIL_STABLE", "UNTIL_STABLE batch, seam after \(after)")
            XCTAssertTrue(h.lastUntilStableFrontier)
            XCTAssertEqual(h.tickCount, t0 + UInt32(after == 0 ? 0 : 3), "the ticks of the completed batches (1 + 2)")
            let again = h.handle("TICK UNTIL_STABLE")
            XCTAssertTrue(again.hasPrefix("OK TICK UNTIL_STABLE "), again)
            lines.append("UNTIL_STABLE batch, seam after \(after): '\(r)'")
        }
        // UNTIL_STABLE past the depth guard (the counting path, one buffer a tick).
        do {
            let L = DagDBEngine.frontierDepthGuardDefault + 1
            let h = try Held(try Self.chainEngine(side: 16, levels: L, dense: true), side: 16, maxRank: 16)
            let t0 = h.handler.tickCount
            h.handler.engine.commandBufferStatusFailsAfterForTesting = 3
            let r = h.handler.handle("TICK UNTIL_STABLE MAX 20")
            assertFailed(r, "TICK UNTIL_STABLE", "UNTIL_STABLE counting path")
            XCTAssertFalse(h.handler.lastUntilStableFrontier, "past the guard: the counting path")
            XCTAssertEqual(h.handler.tickCount, t0 + 3)
            XCTAssertTrue(h.handler.handle("TICK UNTIL_STABLE MAX 20").hasPrefix("OK TICK UNTIL_STABLE not stable after MAX 20 "))
            lines.append("UNTIL_STABLE counting path (\(L) levels): '\(r)'")
        }
        // UNTIL_STABLE's per-tick frontier (a kernel-evaluated destination: two
        // buffers a tick, kernel then latch): the first tick's latch buffer fails.
        do {
            let f = try HandlerFixture(side: 16)
            floodChain(f, m: 10)
            let e = f.handler.engine
            e.isRegisterBuf.contents().storeBytes(of: UInt8(0), toByteOffset: 3, as: UInt8.self)   // raw write
            XCTAssertFalse(batchable(f.handler))
            let t0 = f.handler.tickCount
            e.commandBufferStatusFailsAfterForTesting = 1
            let r = f.handler.handle("TICK UNTIL_STABLE MAX 30")
            assertFailed(r, "TICK UNTIL_STABLE", "UNTIL_STABLE per-tick frontier, the latch buffer")
            XCTAssertTrue(f.handler.lastUntilStableFrontier)
            XCTAssertEqual(f.handler.tickCount, t0)
            XCTAssertTrue(f.handler.handle("TICK UNTIL_STABLE MAX 30").hasPrefix("OK TICK UNTIL_STABLE "))
            lines.append("UNTIL_STABLE per-tick frontier: '\(r)'")
        }
        // The pre-frontier loop (the test seam's reference path).
        do {
            let f = try HandlerFixture(side: 16)
            floodChain(f, m: 40)
            let h = f.handler
            h.untilStablePreFForTesting = true
            h.engine.latchOnGPU = false
            let t0 = h.tickCount
            h.engine.commandBufferStatusFailsAfterForTesting = 5
            let r = h.handle("TICK UNTIL_STABLE")
            assertFailed(r, "TICK UNTIL_STABLE", "pre-F's loop")
            XCTAssertEqual(h.tickCount, t0 + 5)
            lines.append("UNTIL_STABLE pre-F's loop: '\(r)'")
        }
        for l in lines { print("F3F.2 " + l) }
    }

    // MARK: - The depth guard, its structural half

    func testF3F_3DepthGuardNonEmptyLevels() throws {
        let rStar = DagDBEngine.frontierDepthGuardDefault
        XCTAssertTrue((16...63).contains(rStar), "R* in [16, 63], got \(rStar)")
        var tally = Tally()
        for (L, onFrontier) in [(rStar, true), (rStar + 1, false)] {
            for dense in [true, false] {
                let t = try pair(engines: { try Self.chainEngine(side: 16, levels: L, dense: dense) }, side: 16)
                let label = "\(dense ? "dense" : "stable") chain of \(L) levels"
                until(t, "TICK UNTIL_STABLE MAX 40", &tally, label)
                until(t, "TICK UNTIL_STABLE MAX 17", &tally, label)
                XCTAssertEqual(t.f.engine.nonEmptyRankLevels, L)
                XCTAssertEqual(t.f.lastUntilStableRankLevels, L)
                XCTAssertEqual(t.f.lastUntilStableFrontier, onFrontier, "\(label): R* = \(rStar)")
                XCTAssertEqual(t.f.engine.hasFrontierIndex, onFrontier, "\(label): an index only on the frontier")
                if !onFrontier {
                    XCTAssertEqual(t.f.engine.frontierIndexBuildCount, 0)
                    // The guard off (R* = ∞, the depth guard's control): the same graph on the frontier.
                    t.f.engine.frontierMaxRankLevels = Int.max
                    until(t, "TICK UNTIL_STABLE MAX 9", &tally, label + ", guard off")
                    XCTAssertTrue(t.f.lastUntilStableFrontier)
                }
            }
        }
        // Few non-empty levels at large rank values: node 0 at rank 200, node 1
        // (rank 0) reads it — 201 rank levels dispatched over, 2 non-empty.
        let sparse = try pair { f in
            let h = f.handler
            XCTAssertTrue(h.handle("SET 0 RANK 200").hasPrefix("OK"))
            XCTAssertTrue(h.handle("SET 1 LUT AAAAAAAAAAAAAAAA").hasPrefix("OK"))
            XCTAssertTrue(h.handle("CONNECT FROM 0 TO 1").hasPrefix("OK"))
            XCTAssertTrue(h.handle("SET 0 TRUTH 1").hasPrefix("OK"))
        }
        until(sparse, "TICK UNTIL_STABLE", &tally, "ranks 0 and 200")
        XCTAssertEqual(sparse.f.engine.nonEmptyRankLevels, 2)
        XCTAssertGreaterThan(sparse.f.engine.effectiveRankCount, 200)
        XCTAssertTrue(sparse.f.lastUntilStableFrontier, "2 non-empty levels: the frontier")
        // The random mixed 16-level graphs (committed tests run them through the verb on the frontier).
        let g = EngineF2DaemonTests.r3Mixed(side: 64, seed: 0x3F3F)
        let r3 = try pair(engines: { try EngineF2DaemonTests.r3Engine(g, side: 64, seed: 0x3F3F) }, side: 64)
        until(r3, "TICK UNTIL_STABLE MAX 20", &tally, "R3 64²")
        XCTAssertEqual(r3.f.engine.nonEmptyRankLevels, 16)
        XCTAssertTrue(r3.f.lastUntilStableFrontier, "R3's 16 levels: the frontier")
        print("F3F.3 depth guard (R* = \(rStar)): " + tally.line)
        XCTAssertEqual(tally.mismatches, 0)
    }
}
