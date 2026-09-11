import XCTest
@testable import DagDB

final class GearedRingsTests: XCTestCase {
    /// The sealed property in miniature: plant signed spikes at known ticks,
    /// then recall across four orders of lag — value AND sign AND exact tick.
    func testSignedRecallAcrossOrders() {
        // Spikes live in DISTINCT coarsest-ring spans (216 ticks each):
        // consolidation legitimately merges same-span events into the span's
        // strongest, so cross-span placement is the recallable regime.
        var r = GearedRings(gear: 6, rings: 4, cellsPerRing: 8)
        let spikes: [UInt64: Float] = [3: -5.0, 250: 7.5, 500: -9.25, 1200: 4.0]
        let total: UInt64 = 1500
        for t in 0..<total {
            r.write(spikes[t] ?? (t % 2 == 0 ? 0.01 : -0.01))
        }
        for (t, v) in spikes {
            let lag = total - t
            guard let rec = r.recall(lag: lag) else {
                XCTFail("no recall at lag \(lag)"); continue
            }
            XCTAssertEqual(rec.value, v, "value at lag \(lag)")
            XCTAssertEqual(rec.tick, t, "tick at lag \(lag)")
        }
    }

    func testFinestResidentRingWins() {
        var r = GearedRings(gear: 6, rings: 3, cellsPerRing: 4)
        for t in 0..<30 { r.write(Float(t)) }
        // lag 2 is inside ring 0's window (4 cells x 1 tick... resident set is
        // small); it must come back at ring 0 with exact tick.
        let rec = r.recall(lag: 2)
        XCTAssertEqual(rec?.ring, 0)
        XCTAssertEqual(rec?.tick, 28)   // target = now(30) − lag(2)
        // a deep lag falls through to a coarser ring
        let deep = r.recall(lag: 25)
        XCTAssertNotNil(deep)
        XCTAssertGreaterThan(deep!.ring, 0)
    }

    func testBeyondHorizonIsNil() {
        var r = GearedRings(gear: 6, rings: 2, cellsPerRing: 4)
        for _ in 0..<1000 { r.write(1.0) }
        // horizon = cells x gear^(rings-1) = 4 x 6 = 24 ticks
        XCTAssertNil(r.recall(lag: 500))
        XCTAssertNotNil(r.recall(lag: 10))
        XCTAssertNil(r.recall(lag: 0))
    }

    func testSealedShapeCapacity() {
        let r = GearedRings()
        XCTAssertEqual(r.capacity, 192)
    }

    func testExtremumKeepsStrongestOfSpan() {
        var r = GearedRings(gear: 6, rings: 2, cellsPerRing: 4)
        // within one ring-1 span (6 ticks), the strongest signed value rules
        let vals: [Float] = [1, -8, 3, 2, -1, 4]
        for v in vals { r.write(v) }
        for _ in 0..<3 { r.write(0) }
        let rec = r.recall(lag: 9 - 1) // tick 1, where -8 lived (ring 1 span 0)
        XCTAssertEqual(rec?.value, -8)
        XCTAssertEqual(rec?.tick, 1)
    }
}
