import XCTest
@testable import DagDB

/// T1b: state-bearing inits + Codable round-trips for BudgetLayout,
/// CrossConvolutionCheck, GearedRings, and MasterClock/GearRatio/PhaseGear —
/// so a daemon-held instance survives restart in O(1).
///
/// Fixtures are reused verbatim from the sibling test classes:
/// `BudgetLayoutTests.layoutEngine()`, `GearedRingsTests`' signed-spike
/// fixture, and `MasterClockTests`' gear fixtures.
final class TwinCodableClockRingsTests: XCTestCase {
    // MARK: - BudgetLayout

    /// Verbatim copy of BudgetLayoutTests.layoutEngine().
    private func layoutEngine() -> BudgetLayout {
        func row(r4: Double, r7: Double) -> [Double] {
            [r4 / 2, r4, r4 * 2, r4 * 4, r7, r7 * 2, r7 * 3, r7 * 4]
        }
        return BudgetLayout(cost: [
            row(r4: 162, r7: 15138),   // pocket 0 (liar A home)
            row(r4: 50, r7: 12168),    // pocket 1 (never a culprit home)
            row(r4: 162, r7: 10952),   // pocket 2 (liar B home)
            row(r4: 98, r7: 5618),     // pocket 3 (liar C / deep / drift home)
        ], minTier: [4, 1, 4])
    }

    func testBudgetLayoutCodableRoundTripAllocatesSame() throws {
        let e = layoutEngine()
        let data = try JSONEncoder().encode(e)
        let decoded = try JSONDecoder().decode(BudgetLayout.self, from: data)
        XCTAssertEqual(decoded, e)

        // Same claims allocated against original and decoded must agree.
        let claims = [BudgetLayout.Claim(pocket: 0, classIndex: 0),
                      BudgetLayout.Claim(pocket: 0, classIndex: 0),
                      BudgetLayout.Claim(pocket: 3, classIndex: 0)]
        let originalLayout = try e.allocate(claims: claims, budget: 16164)
        let decodedLayout = try decoded.allocate(claims: claims, budget: 16164)
        XCTAssertEqual(originalLayout, decodedLayout)

        // validationError: nil for the fixture...
        XCTAssertNil(BudgetLayout.validationError(cost: e.cost, minTier: e.minTier))
        // ...non-nil for a ragged table (rows of different length)...
        XCTAssertNotNil(BudgetLayout.validationError(cost: [[1, 2], [1]], minTier: [0]))
        // ...non-nil for minTier: [8] against the fixture's 8-tier table
        // (8 tiers means valid indices are 0..<8; 8 itself is out of range).
        XCTAssertNotNil(BudgetLayout.validationError(cost: e.cost, minTier: [8]))
    }

    // MARK: - CrossConvolutionCheck

    func testCrossConvResultCodable() throws {
        let r = CrossConvolutionCheck.Result(residual: 0.125, comparedSamples: 42)
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(CrossConvolutionCheck.Result.self, from: data)
        XCTAssertEqual(decoded, r)
        XCTAssertEqual(decoded.residual, 0.125)
        XCTAssertEqual(decoded.comparedSamples, 42)
    }

    // MARK: - GearedRings

    /// Verbatim fixture shape from GearedRingsTests.testSignedRecallAcrossOrders.
    private func ringsSpikeFixture() throws -> (rings: GearedRings, spikes: [UInt64: Float], total: UInt64) {
        var r = try GearedRings(gear: 6, rings: 4, cellsPerRing: 8)
        let spikes: [UInt64: Float] = [3: -5.0, 250: 7.5, 500: -9.25, 1200: 4.0]
        let total: UInt64 = 1500
        for t in 0..<total {
            r.write(spikes[t] ?? (t % 2 == 0 ? 0.01 : -0.01))
        }
        return (r, spikes, total)
    }

    func testGearedRingsCodableRoundTripRecalls() throws {
        let (r, spikes, total) = try ringsSpikeFixture()
        let data = try JSONEncoder().encode(r)
        var decoded = try JSONDecoder().decode(GearedRings.self, from: data)
        XCTAssertEqual(decoded, r)

        for (t, v) in spikes {
            let lag = total - t
            let original = r.recall(lag: lag)
            let restored = decoded.recall(lag: lag)
            XCTAssertEqual(restored, original, "lag \(lag)")
            XCTAssertEqual(restored?.value, v, "lag \(lag)")
        }

        var mutableOriginal = r
        mutableOriginal.write(1.0)
        decoded.write(1.0)
        XCTAssertEqual(mutableOriginal.recall(lag: 1), decoded.recall(lag: 1))
    }

    func testGearedRingsStateBearingInitRejectsMismatch() throws {
        let okCells = Array(
            repeating: Array(repeating: GearedRings.Cell(value: 0, tick: 0, span: 0, occupied: false),
                              count: 8),
            count: 4)
        XCTAssertNoThrow(try GearedRings(gear: 6, rings: 4, cellsPerRing: 8, now: 0, cells: okCells))

        // cells shaped for 3 rings but 4 declared: cellsMismatch.
        let mismatchedCells = Array(
            repeating: Array(repeating: GearedRings.Cell(value: 0, tick: 0, span: 0, occupied: false),
                              count: 8),
            count: 3)
        XCTAssertThrowsError(
            try GearedRings(gear: 6, rings: 4, cellsPerRing: 8, now: 0, cells: mismatchedCells)
        ) { error in
            guard case GearedRings.RingsError.cellsMismatch(expectedRings: 4, expectedCells: 8) = error else {
                XCTFail("expected cellsMismatch(4, 8), got \(error)"); return
            }
        }

        XCTAssertNotNil(GearedRings.shapeViolation(gear: 1, rings: 4, cellsPerRing: 8))
    }

    // MARK: - MasterClock / PhaseGear / GearRatio

    func testPhaseGearCodableRoundTripKeepsExactFires() throws {
        // Verbatim gear from MasterClockTests.testNoDriftExactFireCount (3/7).
        var g = PhaseGear(name: "g", ratio: try GearRatio(3, over: 7))
        var clock = MasterClock()
        let n: UInt64 = 5_000
        for _ in 0..<n {
            clock.advance()
            g.advance(masterTick: clock.tick, value: 0)
        }

        let data = try JSONEncoder().encode(g)
        var decoded = try JSONDecoder().decode(PhaseGear.self, from: data)
        XCTAssertEqual(decoded, g)

        for _ in 0..<n {
            clock.advance()
            decoded.advance(masterTick: clock.tick, value: 0)
        }
        XCTAssertEqual(decoded.fires, 10_000 * 3 / 7)
    }

    func testLatchRoundTrip() throws {
        // Verbatim gear/loop from MasterClockTests.testLatchCapturesExactTickAndValue.
        var g = PhaseGear(name: "latch", ratio: try GearRatio(1, over: 5))
        var clock = MasterClock()
        for i in 1...12 {
            clock.advance()
            g.advance(masterTick: clock.tick, value: Float(i))
        }

        let data = try JSONEncoder().encode(g)
        let decoded = try JSONDecoder().decode(PhaseGear.self, from: data)
        XCTAssertEqual(decoded, g)
        XCTAssertEqual(decoded.latchedTick, 10)
        XCTAssertEqual(decoded.latchedValue, 10)
        XCTAssertEqual(decoded.phase.num, 2)
    }

    func testGearRatioReducedReturnsNilOnZero() throws {
        XCTAssertNil(GearRatio.reduced(0, over: 5))
        XCTAssertNil(GearRatio.reduced(5, over: 0))
        XCTAssertNil(GearRatio.reduced(0, over: 0))
        XCTAssertEqual(GearRatio.reduced(4, over: 6), try GearRatio(2, over: 3))
    }
}
