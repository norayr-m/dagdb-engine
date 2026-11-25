import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// TICK UNTIL_STABLE takes its per-tick counts from the tick itself — the counting
/// kernel's changed-node count and the latch's own count — with no copy or
/// scan of the truth buffer.
///
/// Every test compares the new counts against the earlier byte-compare definition, computed here
/// the slow way, outside the engine: `changed` = the truth bytes that differ
/// after a tick from before it (a byte compare), `latched` = the distinct
/// back-edge destinations whose byte the latch changed (for a register the
/// byte before the latch is its byte before the tick; for a destination the
/// kernel also evaluates — no fan-in, so its kernel byte is its LUT's bit 0 —
/// that byte). Graphs: `EngineE1DaemonTests.buildGraph` (binary and ternary, sides 16–32), random
/// truth bytes ≥ 3, duplicate back-edge destinations, destinations whose
/// register flag was cleared under them, and the flood / oscillator / stable
/// cases of `EngineE2DaemonTests`.
final class EngineE5DaemonTests: XCTestCase {

    typealias Rng = EngineE1DaemonTests.Rng

    func field(_ reply: String, _ key: String) -> String? {
        reply.split(separator: " ").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    /// The graph of `EngineE1DaemonTests.buildGraph`, plus: extra back edges into binary no-fan-in nodes
    /// (duplicates when `dup`), a few truth bytes ≥ 3, and `evaluated`
    /// destinations whose register flag is cleared (the kernel then evaluates
    /// them before the latch overwrites them).
    func graph(side: Int, seed: UInt64, ternary: Bool, dup: Bool, evaluated: Int) throws -> HandlerFixture {
        let f = try HandlerFixture(side: side)
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
            try e.addBackEdge(src: UInt32(g.below(n)), dst: d0)                  // two edges, one register
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
        return f
    }

    /// The byte-compare counts for one tick, from outside: (changed, latched).
    func reference(_ e: DagDBEngine, before: [UInt8], after: [UInt8], regBefore: [UInt8]) -> (Int, Int) {
        var changed = 0
        for i in 0..<before.count where before[i] != after[i] { changed += 1 }
        let low = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: e.nodeCount)
        var latched = 0
        for d in Set(e.backEdgeDsts.map(Int.init)) {
            let preLatch = regBefore[d] != 0 ? before[d] : UInt8(low[d] & 1)
            if after[d] != preLatch { latched += 1 }
        }
        return (changed, latched)
    }

    /// Every tick of a counting session against the reference, tick by tick.
    func cell(side: Int, seed: UInt64, ternary: Bool, dup: Bool, evaluated: Int, ticks: Int) throws -> (Int, Int) {
        let f = try graph(side: side, seed: seed, ternary: ternary, dup: dup, evaluated: evaluated)
        let h = f.handler, e = h.engine
        XCTAssertNil(h.rankTickDagRefusal())
        try e.prepareRankLists()
        let regBefore = Array(UnsafeBufferPointer(
            start: e.isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: e.nodeCount), count: e.nodeCount))
        var moved = 0, checked = 0
        try e.countingLatchChanges { c in
            for t in 0..<ticks {
                let before = e.readTruthStates()
                c.lastCount = 0
                e.tick(tickNumber: UInt32(t), rankOrderVerified: true)
                XCTAssertTrue(e.lastRankTickCounted)
                let after = e.readTruthStates()
                let (rc, rl) = reference(e, before: before, after: after, regBefore: regBefore)
                XCTAssertEqual(c.lastChanged, rc, "side \(side) seed \(seed) ternary \(ternary) tick \(t): changed")
                XCTAssertEqual(c.lastCount, rl, "side \(side) seed \(seed) ternary \(ternary) tick \(t): latched")
                moved += rc; checked += 1
            }
        }
        return (checked, moved)
    }

    func testE5CountingTickEqualsByteCompareTickByTick() throws {
        var cells = 0, ticks = 0, moved = 0
        for side in [16, 24, 32] {
            for ternary in [false, true] {
                for seed: UInt64 in [1, 2, 3] {
                    for (dup, ev) in [(false, 0), (true, 0), (true, 3)] {
                        let (c, m) = try cell(side: side, seed: seed &* 31 &+ UInt64(side), ternary: ternary,
                                              dup: dup, evaluated: ev, ticks: 12)
                        cells += 1; ticks += c; moved += m
                    }
                }
            }
        }
        print("E5 tick-by-tick: \(cells) cells, \(ticks) ticks, \(moved) truth bytes moved; "
              + "changed and latched equal to E2's definition on every tick")
        XCTAssertGreaterThan(moved, 0, "not vacuous")
    }

    /// The reference loop, the slow way, on a twin: TICK 1 until a tick changes no
    /// byte and no register, UNTIL_STABLE's reply fields (ticks, run, changed, latched,
    /// stable) and the tick total.
    func referenceReply(_ f: HandlerFixture, max k: Int) -> String {
        let e = f.handler.engine
        let regBefore = Array(UnsafeBufferPointer(
            start: e.isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: e.nodeCount), count: e.nodeCount))
        var run = 0, changing = 0, changed = 0, latched = 0, stable = false
        for _ in 0..<k {
            let before = e.readTruthStates()
            XCTAssertTrue(f.handler.handle("TICK 1").hasPrefix("OK TICK"))
            run += 1
            (changed, latched) = reference(e, before: before, after: e.readTruthStates(), regBefore: regBefore)
            if changed == 0 && latched == 0 { stable = true; break }
            changing += 1
        }
        let head = stable ? "OK TICK UNTIL_STABLE stable" : "OK TICK UNTIL_STABLE not stable after MAX \(k)"
        return head + " ticks=\(changing) run=\(run) changed=\(changed) latched=\(latched) total=\(f.handler.tickCount)"
    }

    func strip(_ r: String) -> String {
        r.split(separator: " ").filter { !$0.hasPrefix("elapsed=") && !$0.hasPrefix("nodes_computed=")
            && !$0.hasPrefix("rank_") && !$0.hasPrefix("dispatch") }.joined(separator: " ")
    }

    func testE5UntilStableRepliesEqualE2DefinitionOnRandomGraphs() throws {
        var cases = 0, stableN = 0
        for side in [16, 32] {
            for ternary in [false, true] {
                for seed: UInt64 in [5, 6] {
                    for (dup, ev) in [(false, 0), (true, 2)] {
                        for k in [1, 3, 50] {
                            let s = seed &* 13 &+ UInt64(side) &+ (ternary ? 1000 : 0)
                            let fa = try graph(side: side, seed: s, ternary: ternary, dup: dup, evaluated: ev)
                            let fb = try graph(side: side, seed: s, ternary: ternary, dup: dup, evaluated: ev)
                            let r = fa.handler.handle("TICK UNTIL_STABLE MAX \(k)")
                            let ref = referenceReply(fb, max: k)
                            let got = strip(r).split(separator: " ").filter { !$0.hasPrefix("rank") }
                                .joined(separator: " ")
                            let mine = got.components(separatedBy: " total=")[0] + " total=\(fa.handler.tickCount)"
                            XCTAssertEqual(mine, ref, "side \(side) ternary \(ternary) seed \(s) dup \(dup) ev \(ev) MAX \(k): \(r)")
                            XCTAssertEqual(fa.handler.engine.readTruthStates(), fb.handler.engine.readTruthStates())
                            XCTAssertEqual(fa.handler.tickCount, fb.handler.tickCount)
                            cases += 1; if ref.contains(" stable ticks") && !ref.contains("not stable") { stableN += 1 }
                        }
                    }
                }
            }
        }
        print("E5 replies: \(cases) cases equal to E2's definition (\(stableN) stable, \(cases - stableN) at MAX)")
    }

    /// The three cases of `EngineE2DaemonTests` (flood, already stable, oscillator) and the
    /// mid-seeded flood, against the same slow reference.
    /// The register chain of `EngineE2DaemonTests.floodChain`, copied.
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

    /// The oscillators of `EngineE2DaemonTests.oscillators`, copied.
    func oscillators(_ f: HandlerFixture, k: Int) {
        let h = f.handler
        for j in 0..<k {
            XCTAssertTrue(h.handle("SET \(200 + j) RANK 1").hasPrefix("OK"))
            XCTAssertTrue(h.handle("SET \(220 + j) LUT NOR").hasPrefix("OK"))
            XCTAssertTrue(h.handle("CONNECT FROM \(200 + j) TO \(220 + j)").hasPrefix("OK"))
            XCTAssertTrue(h.handle("CONNECT BACK FROM \(220 + j) TO \(200 + j)").hasPrefix("OK"))
        }
    }

    func testE5E2GateCasesEqualReference() throws {
        let side = 16
        let fa = try HandlerFixture(side: side), fb = try HandlerFixture(side: side)
        floodChain(fa, m: 40); floodChain(fb, m: 40)
        let r1 = fa.handler.handle("TICK UNTIL_STABLE"), s1 = referenceReply(fb, max: 10_000)
        let r2 = fa.handler.handle("TICK UNTIL_STABLE MAX 5"), s2 = referenceReply(fb, max: 5)
        let oa = try HandlerFixture(side: side), ob = try HandlerFixture(side: side)
        oscillators(oa, k: 5); oscillators(ob, k: 5)
        let r3 = oa.handler.handle("TICK UNTIL_STABLE MAX 7"), s3 = referenceReply(ob, max: 7)
        let ma = try HandlerFixture(side: side), mb = try HandlerFixture(side: side)
        floodChain(ma, m: 30, seed: false); floodChain(mb, m: 30, seed: false)
        _ = ma.handler.handle("SET 12 TRUTH 1"); _ = mb.handler.handle("SET 12 TRUTH 1")
        let r4 = ma.handler.handle("TICK UNTIL_STABLE MAX 100"), s4 = referenceReply(mb, max: 100)
        for (r, s, name) in [(r1, s1, "flood"), (r2, s2, "stable"), (r3, s3, "oscillator"), (r4, s4, "mid-seeded")] {
            print("E5 \(name): '\(r)' reference '\(s)'")
            XCTAssertEqual(strip(r).components(separatedBy: " total=")[0], s.components(separatedBy: " total=")[0], name)
            XCTAssertEqual(field(r, "total"), field(s, "total"), name)
        }
        XCTAssertTrue(r1.hasPrefix("OK TICK UNTIL_STABLE stable ticks=39 run=40 changed=0 latched=0 "), r1)
        XCTAssertTrue(r2.hasPrefix("OK TICK UNTIL_STABLE stable ticks=0 run=1 "), r2)
        XCTAssertTrue(r3.hasPrefix("OK TICK UNTIL_STABLE not stable after MAX 7 ticks=7 run=7 changed=10 latched=5 "), r3)
        XCTAssertEqual(fa.handler.engine.readTruthStates(), fb.handler.engine.readTruthStates())
        XCTAssertEqual(oa.handler.engine.readTruthStates(), ob.handler.engine.readTruthStates())
        XCTAssertEqual(ma.handler.engine.readTruthStates(), mb.handler.engine.readTruthStates())
    }

    /// Plain TICK, TICK_SYNC and EVAL dispatch today's kernels: the counting
    /// twins run only inside UNTIL_STABLE.
    func testE5PlainTicksDoNotCount() throws {
        let f = try graph(side: 16, seed: 9, ternary: true, dup: true, evaluated: 0)
        let h = f.handler, e = h.engine
        XCTAssertTrue(h.handle("TICK 3").hasPrefix("OK TICK"))
        XCTAssertFalse(e.lastRankTickCounted)
        XCTAssertNil(e.latchChangeCounter)
        XCTAssertTrue(h.handle("TICK UNTIL_STABLE MAX 4").hasPrefix("OK TICK UNTIL_STABLE"))
        XCTAssertTrue(e.lastRankTickCounted)
        XCTAssertNil(e.latchChangeCounter, "the session closes with the verb")
        XCTAssertTrue(h.handle("TICK 1").hasPrefix("OK TICK"))
        XCTAssertFalse(e.lastRankTickCounted)
        XCTAssertTrue(h.handle("EVAL").hasPrefix("OK"))
        XCTAssertFalse(e.lastRankTickCounted)
        XCTAssertTrue(h.handle("TICK_SYNC 1").hasPrefix("OK"))
        XCTAssertNil(e.latchChangeCounter)
    }

    /// The counting session's counter cannot be allocated: refused by name,
    /// nothing ticked.
    func testE5CounterAllocationFailureIsRefused() throws {
        let f = try graph(side: 16, seed: 4, ternary: false, dup: false, evaluated: 0)
        let h = f.handler, e = h.engine
        let truth = e.readTruthStates()
        e.changeCounterAllocationFailsForTesting = true
        let r = h.handle("TICK UNTIL_STABLE MAX 5")
        XCTAssertEqual(r, "ERROR resource: TICK UNTIL_STABLE refused: change counter: buffer allocation failed (4 bytes); nothing ticked")
        XCTAssertEqual(h.tickCount, 0)
        XCTAssertEqual(e.readTruthStates(), truth)
        e.changeCounterAllocationFailsForTesting = false
        XCTAssertTrue(h.handle("TICK UNTIL_STABLE MAX 5").hasPrefix("OK TICK UNTIL_STABLE"))
    }
}
