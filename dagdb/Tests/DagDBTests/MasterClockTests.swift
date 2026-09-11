import XCTest
@testable import DagDB

final class MasterClockTests: XCTestCase {
    func testNoDriftExactFireCount() {
        // clicks without drift: fires == floor(N * p / q) exactly
        var g = PhaseGear(name: "g", ratio: GearRatio(3, over: 7))
        var clock = MasterClock()
        let n: UInt64 = 10_000
        for _ in 0..<n {
            clock.advance()
            g.advance(masterTick: clock.tick, value: 0)
        }
        XCTAssertEqual(g.fires, n * 3 / 7)
    }

    func testBandLadderSixToOne() {
        // the 6:1 ladder: each band fires exactly 6x less than the one above
        var bands = (0..<4).map { j -> PhaseGear in
            var den: UInt64 = 1
            for _ in 0..<j { den *= 6 }
            return PhaseGear(name: "band\(j)", ratio: GearRatio(1, over: den))
        }
        var clock = MasterClock()
        let n: UInt64 = 6 * 6 * 6 * 10
        for _ in 0..<n {
            clock.advance()
            for i in bands.indices { bands[i].advance(masterTick: clock.tick, value: 0) }
        }
        XCTAssertEqual(bands.map(\.fires), [n, n / 6, n / 36, n / 216])
    }

    func testGearCompositionIsExact() {
        // (1/6) of (1/6) == 1/36, reduced and printed
        let a = GearRatio(1, over: 6)
        XCTAssertEqual(a.composed(with: a), GearRatio(1, over: 36))
        XCTAssertEqual(GearRatio(4, over: 6), GearRatio(2, over: 3)) // reduction
        XCTAssertEqual(GearRatio(2, over: 3).description, "2/3")
    }

    func testLatchCapturesExactTickAndValue() {
        var g = PhaseGear(name: "latch", ratio: GearRatio(1, over: 5))
        var clock = MasterClock()
        for i in 1...12 {
            clock.advance()
            g.advance(masterTick: clock.tick, value: Float(i))
        }
        // fires at ticks 5 and 10; the latch holds the LAST fire
        XCTAssertEqual(g.fires, 2)
        XCTAssertEqual(g.latchedTick, 10)
        XCTAssertEqual(g.latchedValue, 10)
        XCTAssertEqual(g.phase.num, 2) // 12 mod 5
    }

    func testOverdrivenGearMultiFires() {
        // p > q: a gear may fire more than once per master tick, still exact
        var g = PhaseGear(name: "fast", ratio: GearRatio(5, over: 2))
        var clock = MasterClock()
        clock.advance()
        let fired = g.advance(masterTick: clock.tick, value: 1)
        XCTAssertEqual(fired, 2)
        XCTAssertEqual(g.phase.num, 1)
    }
}
