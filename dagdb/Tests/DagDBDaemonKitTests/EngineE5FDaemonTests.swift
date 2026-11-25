import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Three follow-up fixes to the counting session.
///
/// 1. A tick inside a counting session that gets no command buffer reports
///    changed=0 and latched=0 — the earlier byte compare saw no byte move and its
///    latch did not run — so TICK UNTIL_STABLE stops "stable" there, as it
///    did before the counts came from the GPU tick and the latch.
/// 2. The counting session's precondition (the back-edge layout is fixed for
///    the session; sessions do not nest) is enforced: a nested call, and a
///    change of the layout seen by more than the count (a checksum of the
///    destinations and their register flags), are refused by name.
/// 3. The session's per-node marks: a failed allocation is a refusal by name
///    with nothing ticked, not a trap.
///
/// The counts are checked against the byte-compare definition computed outside the
/// engine (as EngineE5DaemonTests does; its helpers are copied here).
final class EngineE5FDaemonTests: XCTestCase {

    typealias Rng = EngineE1DaemonTests.Rng

    // MARK: - Helpers (copied from EngineE5DaemonTests)

    /// The graph of `EngineE1DaemonTests.buildGraph`, plus extra back edges into binary no-fan-in nodes
    /// (duplicates when `dup`), a few truth bytes ≥ 3, and `evaluated`
    /// destinations whose register flag is cleared.
    func graph(side: Int, seed: UInt64, ternary: Bool, dup: Bool, evaluated: Int) throws -> HandlerFixture {
        let f = try HandlerFixture(side: side)
        let e = f.handler.engine
        try EngineE1DaemonTests.buildGraph(e, seed: seed, ternary: ternary)
        let n = e.nodeCount
        var g = Rng(s: seed &+ 77)
        let free = freeNodes(e)
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
        return f
    }

    /// Binary nodes with no combinational input (legal back-edge destinations).
    func freeNodes(_ e: DagDBEngine) -> [Int] {
        let n = e.nodeCount
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        return (0..<n).filter { i in
            !TernaryReference.isTernary(e.modeByte(i)) && (0..<6).allSatisfy { nb[i * 6 + $0] < 0 }
        }
    }

    func registers(_ e: DagDBEngine) -> [UInt8] {
        Array(UnsafeBufferPointer(
            start: e.isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: e.nodeCount), count: e.nodeCount))
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

    /// One counted tick inside an open session, checked against the byte-compare numbers.
    func tickChecked(_ e: DagDBEngine, _ c: DagDBEngine.LatchChangeCounter, t: Int, _ regBefore: [UInt8],
                     _ label: String) {
        let before = e.readTruthStates()
        c.lastCount = 0
        e.tick(tickNumber: UInt32(t), rankOrderVerified: true)
        XCTAssertTrue(e.lastRankTickCounted, "\(label) tick \(t): counted")
        let (rc, rl) = reference(e, before: before, after: e.readTruthStates(), regBefore: regBefore)
        XCTAssertEqual(c.lastChanged, rc, "\(label) tick \(t): changed")
        XCTAssertEqual(c.lastCount, rl, "\(label) tick \(t): latched")
    }

    /// The reference loop, the slow way, on a twin (`EngineE5DaemonTests.referenceReply`).
    func referenceReply(_ f: HandlerFixture, max k: Int) -> String {
        let e = f.handler.engine
        let regBefore = registers(e)
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
        return head + " ticks=\(changing) run=\(run) changed=\(changed) latched=\(latched)"
    }

    /// The register chain of `EngineE2DaemonTests.floodChain`, copied.
    func floodChain(_ f: HandlerFixture, m: Int) {
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

    // MARK: - A tick with no command buffer counts nothing

    /// UNTIL_STABLE whose k-th tick gets no command buffer: the earlier loop saw no
    /// byte move on that tick and its latch did not run, so it stopped there,
    /// "stable", with the failed tick counted in run= and in the tick total.
    func testE5FFailedCommandBufferStopsUntilStableAsE2Did() throws {
        var cells = 0, reachedFailure = 0
        // The flood of `EngineE2DaemonTests` (40 registers; each of its first 39 ticks changes something).
        for after in [0, 1, 3, 10] {
            let fa = try HandlerFixture(side: 16), fb = try HandlerFixture(side: 16)
            floodChain(fa, m: 40); floodChain(fb, m: 40)
            fa.handler.engine.tickCommandBufferFailsAfterForTesting = after
            let r = fa.handler.handle("TICK UNTIL_STABLE MAX 50")
            XCTAssertTrue(r.hasPrefix("OK TICK UNTIL_STABLE stable ticks=\(after) run=\(after + 1) changed=0 latched=0 "),
                          "flood, command buffer fails after \(after) ticks: \(r)")
            XCTAssertEqual(fa.handler.tickCount, UInt32(after + 1))
            for _ in 0..<after { XCTAssertTrue(fb.handler.handle("TICK 1").hasPrefix("OK TICK")) }
            XCTAssertEqual(fa.handler.engine.readTruthStates(), fb.handler.engine.readTruthStates(), "flood \(after)")
            cells += 1; reachedFailure += 1
        }
        // The graphs of `EngineE1DaemonTests.buildGraph`, binary and ternary, duplicates and evaluated destinations.
        for ternary in [false, true] {
            for seed: UInt64 in [31, 32, 33] {
                for after in [1, 2, 4] {
                    let fa = try graph(side: 16, seed: seed, ternary: ternary, dup: true, evaluated: 2)
                    let fb = try graph(side: 16, seed: seed, ternary: ternary, dup: true, evaluated: 2)
                    fa.handler.engine.tickCommandBufferFailsAfterForTesting = after
                    let r = fa.handler.handle("TICK UNTIL_STABLE MAX 20")
                    // The reference loop on the twin for `after` ticks; if it is not stable by
                    // then, the next tick (the failed one) moved nothing.
                    var expected = referenceReply(fb, max: after)
                    var total = fb.handler.tickCount
                    if expected.contains("not stable") {
                        expected = "OK TICK UNTIL_STABLE stable ticks=\(after) run=\(after + 1) changed=0 latched=0"
                        total += 1
                        reachedFailure += 1
                    }
                    XCTAssertTrue(r.hasPrefix(expected + " "), "ternary \(ternary) seed \(seed) after \(after): \(r) / \(expected)")
                    XCTAssertEqual(fa.handler.tickCount, total)
                    XCTAssertEqual(fa.handler.engine.readTruthStates(), fb.handler.engine.readTruthStates())
                    cells += 1
                }
            }
        }
        print("E5F item 1: \(cells) cells, \(reachedFailure) reached the failed command buffer; every reply E2's")
        XCTAssertGreaterThan(reachedFailure, 10, "not vacuous")
    }

    /// In a library session: a tick with no command buffer leaves both counts
    /// 0 even when the caller does not zero `lastCount` itself, ticks
    /// nothing, and the next tick counts as before.
    func testE5FFailedCommandBufferZeroesBothCountsInASession() throws {
        let f = try HandlerFixture(side: 16)
        floodChain(f, m: 40)
        let e = f.handler.engine
        XCTAssertNil(f.handler.rankTickDagRefusal())
        try e.prepareRankLists()
        let regBefore = registers(e)
        try e.countingLatchChanges { c in
            tickChecked(e, c, t: 0, regBefore, "flood")
            XCTAssertGreaterThan(c.lastChanged, 0, "not vacuous")
            XCTAssertGreaterThan(c.lastCount, 0, "not vacuous")
            let before = e.readTruthStates()
            e.tickCommandBufferFailsAfterForTesting = 0
            e.tick(tickNumber: 1, rankOrderVerified: true)
            e.tick(tickNumber: 2, rankOrderVerified: true)
            XCTAssertEqual(e.readTruthStates(), before, "nothing ticked")
            XCTAssertEqual(c.lastChanged, 0, "changed after a tick with no command buffer")
            XCTAssertEqual(c.lastCount, 0, "latched after a tick with no command buffer")
            e.tickCommandBufferFailsAfterForTesting = nil
            for t in 3..<8 { tickChecked(e, c, t: t, regBefore, "flood after") }
        }
    }

    // MARK: - The session's precondition, enforced

    func testE5FNestedSessionIsRefused() throws {
        for ternary in [false, true] {
            let f = try graph(side: 16, seed: 21, ternary: ternary, dup: true, evaluated: 2)
            let e = f.handler.engine
            XCTAssertNil(f.handler.rankTickDagRefusal())
            try e.prepareRankLists()
            let regBefore = registers(e)
            var innerRan = false, refusal = "(none)"
            try e.countingLatchChanges { c in
                tickChecked(e, c, t: 0, regBefore, "outer")
                do { try e.countingLatchChanges { _ in innerRan = true } } catch { refusal = "\(error)" }
                XCTAssertTrue(e.latchChangeCounter === c, "the outer session is still the open one")
                for t in 1..<4 { tickChecked(e, c, t: t, regBefore, "outer after the nested call") }
            }
            XCTAssertEqual(refusal, "counting session refused: a counting session is already open "
                + "(sessions do not nest); nothing ran", "ternary \(ternary)")
            XCTAssertFalse(innerRan, "ternary \(ternary)")
            XCTAssertNil(e.latchChangeCounter)
        }
    }

    enum LayoutEdit: CaseIterable {
        /// A back edge added through the engine (the count moves).
        case addEdge
        /// One destination moved to another free node, flags kept in step
        /// (the count does not move).
        case moveDestination
        /// A raw write clears a register destination's flag (lists untouched).
        case clearRegisterFlag
        /// A raw write sets the flag of a destination the kernel evaluated.
        case setEvaluatedFlag
        /// The destination list replaced by an equal one in new storage:
        /// NOT a change, not refused.
        case sameListNewStorage
    }

    func testE5FLayoutChangeInsideASessionIsRefused() throws {
        var cells = 0
        for ternary in [false, true] {
            for seed: UInt64 in [41, 42] {
                for edit in LayoutEdit.allCases {
                    let label = "\(edit) ternary \(ternary) seed \(seed)"
                    let f = try graph(side: 16, seed: seed, ternary: ternary, dup: false, evaluated: 2)
                    let e = f.handler.engine
                    XCTAssertNil(f.handler.rankTickDagRefusal())
                    try e.prepareRankLists()
                    let regBefore = registers(e)
                    let edgesAtOpen = e.backEdgeCount
                    let reg = e.isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: e.nodeCount)
                    let dsts = Set(e.backEdgeDsts.map(Int.init))
                    let spare = freeNodes(e).filter { !dsts.contains($0) }
                    XCTAssertFalse(spare.isEmpty, label)
                    var thrown: String?
                    do {
                        try e.countingLatchChanges { c in
                            tickChecked(e, c, t: 0, regBefore, label)
                            switch edit {
                            case .addEdge:
                                try e.addBackEdge(src: UInt32((spare[0] + 1) % e.nodeCount), dst: UInt32(spare[0]))
                            case .moveDestination:
                                let k = e.backEdgeDsts.firstIndex { reg[Int($0)] != 0 }!
                                let old = Int(e.backEdgeDsts[k])
                                e.backEdgeDsts[k] = UInt32(spare[0])
                                reg[old] = 0; reg[spare[0]] = 1
                            case .clearRegisterFlag:
                                reg[Int(e.backEdgeDsts.first { reg[Int($0)] != 0 }!)] = 0
                            case .setEvaluatedFlag:
                                reg[Int(e.backEdgeDsts.first { reg[Int($0)] == 0 }!)] = 1
                            case .sameListNewStorage:
                                var copy = e.backEdgeDsts
                                copy.append(0); copy.removeLast()          // forces its own storage
                                e.backEdgeDsts = copy
                            }
                            switch edit {
                            case .addEdge, .moveDestination:
                                // An edit of the lists: the next tick is refused, nothing ticked.
                                let before = e.readTruthStates()
                                for t in 1...2 {
                                    c.lastCount = 0
                                    e.tick(tickNumber: UInt32(t), rankOrderVerified: true)
                                    XCTAssertEqual(e.readTruthStates(), before, "\(label): tick \(t) refused, nothing ticked")
                                    XCTAssertEqual(c.lastChanged, 0, label)
                                    XCTAssertEqual(c.lastCount, 0, label)
                                }
                            case .clearRegisterFlag, .setEvaluatedFlag:
                                // A raw flag write: not seen per tick (that would be a scan);
                                // the session is refused when it closes.
                                for t in 1...2 {
                                    let before = e.readTruthStates()
                                    c.lastCount = 0
                                    e.tick(tickNumber: UInt32(t), rankOrderVerified: true)
                                    let (rc, rl) = self.reference(e, before: before, after: e.readTruthStates(),
                                                                  regBefore: self.registers(e))
                                    print("E5F \(label) tick \(t) after the raw write: changed \(c.lastChanged) "
                                          + "(E2 \(rc)), latched \(c.lastCount) (E2 \(rl))")
                                }
                            case .sameListNewStorage:
                                for t in 1...3 { tickChecked(e, c, t: t, regBefore, label) }
                            }
                        }
                    } catch {
                        thrown = "\(error)"
                    }
                    let edgesNow = e.backEdgeCount
                    let head = "counting session refused: the back-edge layout changed inside the session "
                        + "(back edges \(edgesAtOpen) → \(edgesNow); the count, the destinations or their register "
                        + "flags differ from the session's plan)"
                    switch edit {
                    case .addEdge, .moveDestination:
                        XCTAssertEqual(thrown, head + "; tick 2 of the session and every later one ticked nothing", label)
                    case .clearRegisterFlag, .setEvaluatedFlag:
                        XCTAssertEqual(thrown, head + ", found when the session closed; its ticks after the change "
                            + "ran on a stale plan and their counts are refused", label)
                    case .sameListNewStorage:
                        XCTAssertNil(thrown, label)
                    }
                    XCTAssertNil(e.latchChangeCounter, label)
                    cells += 1
                }
            }
        }
        print("E5F item 2: \(cells) layout cells")
    }

    // MARK: - The marks allocation refuses, never traps

    func testE5FMarksAllocationFailureIsRefused() throws {
        let f = try graph(side: 16, seed: 4, ternary: true, dup: true, evaluated: 1)
        let h = f.handler, e = h.engine
        let truth = e.readTruthStates()
        e.changeMarksAllocationFailsForTesting = true
        let r = h.handle("TICK UNTIL_STABLE MAX 5")
        XCTAssertEqual(r, "ERROR resource: TICK UNTIL_STABLE refused: change marks: buffer allocation failed "
            + "(\(e.nodeCount) bytes); nothing ticked")
        XCTAssertEqual(h.tickCount, 0)
        XCTAssertEqual(e.readTruthStates(), truth)
        XCTAssertNil(e.latchChangeCounter)
        var ran = false, refusal = "(none)"
        do { try e.countingLatchChanges { _ in ran = true } } catch { refusal = "\(error)" }
        XCTAssertEqual(refusal, "change marks: buffer allocation failed (\(e.nodeCount) bytes)")
        XCTAssertFalse(ran)
        XCTAssertNil(e.latchChangeCounter)
        e.changeMarksAllocationFailsForTesting = false
        XCTAssertTrue(h.handle("TICK UNTIL_STABLE MAX 5").hasPrefix("OK TICK UNTIL_STABLE"))
        XCTAssertGreaterThan(h.tickCount, 0)
    }
}
