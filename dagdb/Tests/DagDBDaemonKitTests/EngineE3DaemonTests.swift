import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Per-rank contiguous dispatch, through the daemon's handler.
///
/// The daemon's rank-mode TICK (and TICK UNTIL_STABLE) checks the graph's
/// rank order before it ticks; having found no edge rank
/// mode cannot order, it ticks with one dispatch per rank. Each test builds
/// two identical handlers: one ticks through the DSL, the other's engine
/// ticks through `tick(tickNumber:)` — the colour-segment path, the rank-mode
/// tick as it was — with the same tick numbers. Every truth byte must agree
/// after every tick, binary and ternary graphs, registers included. EVAL
/// asks the same check and refuses the graphs TICK
/// refuses; on a graph that passes it keeps the colour path.
final class EngineE3DaemonTests: XCTestCase {

    typealias E1 = EngineE1DaemonTests

    func fixture(side: Int, seed: UInt64, ternary: Bool) throws -> HandlerFixture {
        let f = try HandlerFixture(side: side)
        try E1.buildGraph(f.handler.engine, seed: seed, ternary: ternary)
        return f
    }

    static func nonEmptyRanks(_ e: DagDBEngine) -> Int {
        e.ensureRankTopology()
        let r = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: e.nodeCount)
        var seen = Set<UInt64>()
        for i in 0..<e.nodeCount where r[i] < UInt64(e.effectiveRankCount) { seen.insert(r[i]) }
        return seen.count
    }

    static func nonEmptySegments(_ e: DagDBEngine) -> Int {
        e.ensureRankTopology()
        let r = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: e.nodeCount)
        var seen = Set<UInt64>()
        for (c, group) in e.grid.colorGroups.enumerated() {
            for m in group where r[Int(m)] < UInt64(e.effectiveRankCount) { seen.insert(r[Int(m)] &* 8 &+ UInt64(c)) }
        }
        return seen.count
    }

    func testE3TickDispatchesPerRankAndEqualsTheColourPath() throws {
        var ticks = 0, moved = 0
        for side in [16, 32] {
            for ternary in [false, true] {
                let seed = UInt64(0xE3_D000) &+ UInt64(side) &+ (ternary ? 1 : 0)
                let fa = try fixture(side: side, seed: seed, ternary: ternary)
                let fb = try fixture(side: side, seed: seed, ternary: ternary)
                let a = fa.handler.engine, b = fb.handler.engine
                XCTAssertEqual(a.readTruthStates(), b.readTruthStates())
                XCTAssertEqual(a.nonBinaryNodeCount > 0, ternary)
                let ranks = Self.nonEmptyRanks(a), segments = Self.nonEmptySegments(b)
                XCTAssertGreaterThan(segments, ranks, "the object must have more segments than ranks")
                var t: UInt32 = 0
                for count in [1, 1, 1, 5, 1, 3] {
                    let before = a.readTruthStates()
                    let r = fa.handler.handle("TICK \(count)")
                    XCTAssertTrue(r.hasPrefix("OK TICK \(count) "), r)
                    for _ in 0..<count { b.tick(tickNumber: t); t += 1 }
                    XCTAssertEqual(a.lastRankTickDispatchCount, ranks, "TICK: one dispatch per rank")
                    XCTAssertEqual(b.lastRankTickDispatchCount, segments)
                    XCTAssertEqual(a.lastTickKernel, ternary ? .general : .binaryOnly)
                    let x = a.readTruthStates(), y = b.readTruthStates()
                    XCTAssertEqual(x, y, "side \(side) ternary=\(ternary) after TICK \(count) (total \(t))")
                    for i in 0..<x.count where x[i] != before[i] { moved += 1 }
                    ticks += count
                }
            }
        }
        XCTAssertGreaterThan(moved, 0)
        print("E3 daemon TICK per-rank vs colour path: \(ticks) ticks equal, \(moved) truth bytes moved")
    }

    func testE3TickUntilStableTakesThePerRankPathAndAgrees() throws {
        for ternary in [false, true] {
            let fa = try fixture(side: 24, seed: 0xE3_5AB1 &+ (ternary ? 1 : 0), ternary: ternary)
            let fb = try fixture(side: 24, seed: 0xE3_5AB1 &+ (ternary ? 1 : 0), ternary: ternary)
            let r = fa.handler.handle("TICK UNTIL_STABLE MAX 9")
            XCTAssertTrue(r.hasPrefix("OK TICK UNTIL_STABLE "), r)
            let run = try XCTUnwrap(r.split(separator: " ").first { $0.hasPrefix("run=") }.flatMap { Int($0.dropFirst(4)) })
            XCTAssertGreaterThan(run, 0)
            let b = fb.handler.engine
            for t in 0..<run { b.tick(tickNumber: UInt32(t)) }
            XCTAssertEqual(fa.handler.engine.lastRankTickDispatchCount, Self.nonEmptyRanks(fa.handler.engine))
            XCTAssertEqual(fa.handler.engine.readTruthStates(), b.readTruthStates(), "ternary=\(ternary) after run=\(run)")
        }
    }

    func testE3RefusedTickDispatchesNothingAndEvalRefusesToo() throws {
        // A same-rank edge: TICK is refused before any dispatch.
        let f = try fixture(side: 16, seed: 0xE3_0BAD, ternary: false)
        let e = f.handler.engine
        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: e.nodeCount)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        let (dst, src) = (Int32(3), Int32(5))
        XCTAssertEqual(rank[3], rank[5])
        nb[Int(dst) * 6 + 5] = src
        let before = e.readTruthStates()
        let r = f.handler.handle("TICK 1")
        XCTAssertTrue(r.hasPrefix("ERROR invalid_graph: rank-mode TICK refused"), r)
        XCTAssertEqual(e.lastRankTickDispatchCount, 0, "nothing dispatched")
        XCTAssertEqual(e.readTruthStates(), before)
        // EVAL asks
        // the same verdict and refuses in TICK's words, only the verb changed.
        let ticks = f.handler.tickCount
        let ev = f.handler.handle("EVAL")
        XCTAssertEqual(ev, r.replacingOccurrences(of: "rank-mode TICK refused", with: "EVAL refused"), ev)
        XCTAssertTrue(ev.hasPrefix("ERROR invalid_graph: EVAL refused, validation: "), ev)
        XCTAssertEqual(e.lastRankTickDispatchCount, 0, "EVAL dispatched nothing")
        XCTAssertEqual(e.readTruthStates(), before, "EVAL left the truth unchanged")
        XCTAssertEqual(f.handler.tickCount, ticks, "EVAL left the tick count unchanged")
    }
}
