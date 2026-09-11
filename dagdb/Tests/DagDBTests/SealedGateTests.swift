import XCTest
@testable import DagDB

/// the interface phase — the two sealed gates. Gate 1 (`AllocatorCourt`) replays the
/// alarm-stream fixture and needs `DAGDB_W2_FIXTURE`; gate 2
/// (`CorruptionModel`/`SuccessorCourt`) needs only the sealed class counts
/// and never skips. `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md` (with AMENDMENT 1)
/// is the frozen criterion — every literal below is copied from it
/// verbatim; a mismatch here is a finding, never a moved threshold.
///
/// Amendment 1 §15: fixture absent -> XCTSkip with a printed reason;
/// fixture present with hash != pinned -> the gate-1 tests FAIL (the load
/// throws `shaMismatch`, which propagates as a test failure), never skip.
final class SealedGateTests: XCTestCase {

    private func loadSealedOrSkip() throws -> AlarmFixture {
        guard let path = AlarmFixture.envPath else {
            throw XCTSkip("DAGDB_W2_FIXTURE not set — sealed gate skipped")
        }
        return try AlarmFixture.load(path: path, expectedSHA256: AlarmFixture.sealedSHA256)
    }

    // MARK: - Gate 1: derived frame table

    func testGate1DerivedFrameTableMatchesCourt() throws {
        let fixture = try loadSealedOrSkip()
        let frames = AllocatorCourt.frames(fixture.records)
        XCTAssertEqual(frames.count, 200)

        for f in frames[0..<50] {
            XCTAssertEqual(f.rawClass, "quiet")
            XCTAssertNil(f.pocket)
            XCTAssertNil(f.classLabel)
            XCTAssertNil(f.ear)
        }
        let liarEars = frames[50..<100].map { $0.ear }
        XCTAssertEqual(liarEars.filter { $0 == .A }.count, 17)
        XCTAssertEqual(liarEars.filter { $0 == .B }.count, 17)
        XCTAssertEqual(liarEars.filter { $0 == .C }.count, 16)
        for f in frames[50..<100] {
            XCTAssertEqual(f.rawClass, "liar")
            XCTAssertNotNil(f.pocket)
        }
        for f in frames[100..<150] {
            XCTAssertEqual(f.rawClass, "deep")
            XCTAssertEqual(f.pocket, 6)
            XCTAssertEqual(f.classLabel, "deep")
        }
        for f in frames[150..<200] {
            XCTAssertEqual(f.rawClass, "drift")
            XCTAssertEqual(f.pocket, 6)
            XCTAssertNil(f.ear)
            XCTAssertEqual(f.classLabel, "drift")
        }
        XCTAssertEqual(frames[0].key, "quiet_1")
        XCTAssertEqual(frames[50].key, "liar_1")
        XCTAssertEqual(frames[100].key, "deep_1")
        XCTAssertEqual(frames[199].key, "drift_50")
    }

    // MARK: - Gate 1: allocator court, bit-for-bit

    private struct ExpectedArm {
        let misses: Int, served: Int, cost: Double, dummy: Int, dominated: Int
        let perClass: [String: AllocatorCourt.Tally]
        let perEar: [String: AllocatorCourt.Tally]
        let burst: AllocatorCourt.Burst
        let maxSpendRatio: Double
        let warmupCostExcluded: Double
        let servedTrialIdsCount: Int
    }

    private func tally(_ served: Int, _ missed: Int) -> AllocatorCourt.Tally {
        var t = AllocatorCourt.Tally()
        t.served = served
        t.missed = missed
        return t
    }

    private func burst(_ served: Int, _ missed: Int, _ total: Int) -> AllocatorCourt.Burst {
        var b = AllocatorCourt.Burst()
        b.served = served
        b.missed = missed
        b.total = total
        return b
    }

    /// The sealed table, copied field-for-field from
    /// `market/court_allocator_runs.json` (the record
    /// `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md`'s Sealed literals were
    /// summarized from) — one row per (point, arm), all 5 points x 4 arms.
    private func expectedGate1() -> [[AllocatorCourt.Arm: ExpectedArm]] {
        func row(
            misses: Int, served: Int, cost: Double,
            liar: (Int, Int), deep: (Int, Int), drift: (Int, Int),
            a: (Int, Int), b: (Int, Int), c: (Int, Int),
            burst burstT: (Int, Int, Int),
            maxSpendRatio: Double, warmupCostExcluded: Double = 0.0
        ) -> ExpectedArm {
            ExpectedArm(
                misses: misses, served: served, cost: cost, dummy: 0, dominated: 0,
                perClass: ["quiet": tally(0, 0), "liar": tally(liar.0, liar.1),
                           "deep": tally(deep.0, deep.1), "drift": tally(drift.0, drift.1)],
                perEar: ["A": tally(a.0, a.1), "B": tally(b.0, b.1), "C": tally(c.0, c.1)],
                burst: burst(burstT.0, burstT.1, burstT.2),
                maxSpendRatio: maxSpendRatio, warmupCostExcluded: warmupCostExcluded,
                servedTrialIdsCount: 150)
        }

        // Point 0 — B=16164.352484758914
        let p0AllocOracle = row(misses: 0, served: 150, cost: 819218,
                                 liar: (50, 0), deep: (50, 0), drift: (50, 0),
                                 a: (17, 0), b: (17, 0), c: (16, 0),
                                 burst: (116, 0, 116), maxSpendRatio: 0.9365051903114187)
        let p0Uniform = row(misses: 100, served: 50, cost: 94400,
                             liar: (0, 50), deep: (50, 0), drift: (0, 50),
                             a: (0, 17), b: (0, 17), c: (0, 16),
                             burst: (50, 66, 116), maxSpendRatio: 0.029200056138656998,
                             warmupCostExcluded: 1416)
        let p0Greedy = row(misses: 0, served: 150, cost: 1095218,
                            liar: (50, 0), deep: (50, 0), drift: (50, 0),
                            a: (17, 0), b: (17, 0), c: (16, 0),
                            burst: (116, 0, 116), maxSpendRatio: 0.9365051903114187)

        // Point 1 — B=13491.480553724456
        let p1AllocOracle = row(misses: 17, served: 133, cost: 561872,
                                 liar: (33, 17), deep: (50, 0), drift: (50, 0),
                                 a: (0, 17), b: (17, 0), c: (16, 0),
                                 burst: (116, 0, 116), maxSpendRatio: 0.811771544004234)
        let p1Uniform = row(misses: 100, served: 50, cost: 94400,
                             liar: (0, 50), deep: (50, 0), drift: (0, 50),
                             a: (0, 17), b: (0, 17), c: (0, 16),
                             burst: (50, 66, 116), maxSpendRatio: 0.03498504097607729,
                             warmupCostExcluded: 1416)
        let p1Greedy = row(misses: 17, served: 133, cost: 903696,
                            liar: (33, 17), deep: (50, 0), drift: (50, 0),
                            a: (0, 17), b: (17, 0), c: (16, 0),
                            burst: (116, 0, 116), maxSpendRatio: 0.811771544004234)

        // Point 2 — B=11528.02214532872
        let p2AllocOracle = row(misses: 17, served: 133, cost: 561872,
                                 liar: (33, 17), deep: (50, 0), drift: (50, 0),
                                 a: (0, 17), b: (17, 0), c: (16, 0),
                                 burst: (116, 0, 116), maxSpendRatio: 0.9500328731097962)
        let p2Uniform = row(misses: 100, served: 50, cost: 94400,
                             liar: (0, 50), deep: (50, 0), drift: (0, 50),
                             a: (0, 17), b: (0, 17), c: (0, 16),
                             burst: (50, 66, 116), maxSpendRatio: 0.04094371038237982,
                             warmupCostExcluded: 1416)
        let p2Greedy = row(misses: 17, served: 133, cost: 903696,
                            liar: (33, 17), deep: (50, 0), drift: (50, 0),
                            a: (0, 17), b: (17, 0), c: (16, 0),
                            burst: (116, 0, 116), maxSpendRatio: 0.9500328731097962)

        // Point 3 — B=7426.473868436935
        let p3AllocOracle = row(misses: 34, served: 116, cost: 375688,
                                 liar: (16, 34), deep: (50, 0), drift: (50, 0),
                                 a: (0, 17), b: (0, 17), c: (16, 0),
                                 burst: (116, 0, 116), maxSpendRatio: 0.7564828341855369)
        let p3Uniform = row(misses: 100, served: 50, cost: 94400,
                             liar: (0, 50), deep: (50, 0), drift: (0, 50),
                             a: (0, 17), b: (0, 17), c: (0, 16),
                             burst: (50, 66, 116), maxSpendRatio: 0.06355640757130178,
                             warmupCostExcluded: 1416)
        let p3Greedy = row(misses: 34, served: 116, cost: 764058,
                            liar: (16, 34), deep: (50, 0), drift: (50, 0),
                            a: (0, 17), b: (0, 17), c: (16, 0),
                            burst: (116, 0, 116), maxSpendRatio: 0.7564828341855369)

        // Point 4 — B=3128.126645687496
        let p4AllocOracle = row(misses: 100, served: 50, cost: 4900,
                                 liar: (0, 50), deep: (50, 0), drift: (0, 50),
                                 a: (0, 17), b: (0, 17), c: (0, 16),
                                 burst: (50, 66, 116), maxSpendRatio: 0.03132865484685697)
        let p4Uniform = row(misses: 100, served: 50, cost: 94400,
                             liar: (0, 50), deep: (50, 0), drift: (0, 50),
                             a: (0, 17), b: (0, 17), c: (0, 16),
                             burst: (50, 66, 116), maxSpendRatio: 0.15088903150731112,
                             warmupCostExcluded: 1416)
        let p4Greedy = row(misses: 100, served: 50, cost: 229274,
                            liar: (0, 50), deep: (50, 0), drift: (0, 50),
                            a: (0, 17), b: (0, 17), c: (0, 16),
                            burst: (50, 66, 116), maxSpendRatio: 0.8752842548030039)

        return [
            [.allocator: p0AllocOracle, .oracle: p0AllocOracle, .uniform: p0Uniform, .greedy: p0Greedy],
            [.allocator: p1AllocOracle, .oracle: p1AllocOracle, .uniform: p1Uniform, .greedy: p1Greedy],
            [.allocator: p2AllocOracle, .oracle: p2AllocOracle, .uniform: p2Uniform, .greedy: p2Greedy],
            [.allocator: p3AllocOracle, .oracle: p3AllocOracle, .uniform: p3Uniform, .greedy: p3Greedy],
            [.allocator: p4AllocOracle, .oracle: p4AllocOracle, .uniform: p4Uniform, .greedy: p4Greedy],
        ]
    }

    func testGate1AllocatorCourtBitForBit() throws {
        let fixture = try loadSealedOrSkip()
        let grid = AllocatorCourt.runGrid(records: fixture.records)
        let expected = expectedGate1()
        XCTAssertEqual(grid.count, 5)

        for gi in 0..<5 {
            let actual = grid[gi].arms
            XCTAssertEqual(grid[gi].budget, SealedCourt.budgetGrid[gi].budget, "point \(gi) budget")
            XCTAssertEqual(grid[gi].k7, SealedCourt.budgetGrid[gi].k7, "point \(gi) k7")

            for arm in AllocatorCourt.Arm.allCases {
                let a = actual[arm]!
                let e = expected[gi][arm]!
                XCTAssertEqual(a.misses, e.misses, "point \(gi) arm \(arm) misses")
                XCTAssertEqual(a.served, e.served, "point \(gi) arm \(arm) served")
                XCTAssertEqual(a.cost, e.cost, "point \(gi) arm \(arm) cost")
                XCTAssertEqual(a.dummy, e.dummy, "point \(gi) arm \(arm) dummy")
                XCTAssertEqual(a.dominated, e.dominated, "point \(gi) arm \(arm) dominated")
                XCTAssertEqual(a.perClass, e.perClass, "point \(gi) arm \(arm) perClass")
                XCTAssertEqual(a.perEar, e.perEar, "point \(gi) arm \(arm) perEar")
                XCTAssertEqual(a.burst, e.burst, "point \(gi) arm \(arm) burst")
                XCTAssertEqual(a.maxSpendRatio, e.maxSpendRatio, "point \(gi) arm \(arm) maxSpendRatio")
                XCTAssertEqual(a.warmupCostExcluded, e.warmupCostExcluded, "point \(gi) arm \(arm) warmupCostExcluded")
                XCTAssertEqual(a.servedTrialIds.count, e.servedTrialIdsCount, "point \(gi) arm \(arm) servedTrialIds count")
                XCTAssertEqual(a.warmupFramesExcluded, 3)
                XCTAssertEqual(a.tailFramesAppended, 3)
            }

            // oracle == allocator at every point (contract: "allocator == oracle at every point").
            XCTAssertEqual(actual[.allocator]!, actual[.oracle]!, "point \(gi) allocator == oracle")

            // Conservation: every non-quiet trial served exactly once per arm.
            let nonQuietIds = Set(fixture.records.compactMap { $0.claim != nil ? $0.index : nil })
            XCTAssertEqual(nonQuietIds.count, 150, "point \(gi) non-quiet trial count")
            for arm in AllocatorCourt.Arm.allCases {
                XCTAssertEqual(Set(actual[arm]!.servedTrialIds), nonQuietIds, "point \(gi) arm \(arm) conservation")
            }
        }
    }

    // MARK: - Gate 2: successor dyadic ε lattice, bit-for-bit

    /// One (misses_alloc, misses_greedy, cost_alloc) triple at one ε index.
    private struct G2 { let missAlloc: Double, missGreedy: Double, cost: Double }

    /// eps index {0,16,32,48,64} -> eps {0, .25, .5, .75, 1}. `sameGreedy`
    /// sweeps (m, s) share missAlloc == missGreedy at every index.
    private func rowSame(_ missAlloc: [Double], _ cost: [Double]) -> [G2] {
        zip(missAlloc, cost).map { G2(missAlloc: $0, missGreedy: $0, cost: $1) }
    }
    private func rowDistinct(_ missAlloc: [Double], _ missGreedy: [Double], _ cost: [Double]) -> [G2] {
        zip(zip(missAlloc, missGreedy), cost).map { G2(missAlloc: $0.0, missGreedy: $0.1, cost: $1) }
    }

    /// Full gate-2 table, copied verbatim from
    /// `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md`'s Sealed literals (points 0..3,
    /// the four sweeps m/s/n/diag, ε index {0,16,32,48,64}).
    private func expectedGate2() -> [[SuccessorCourt.Sweep: [G2]]] {
        let p0m = rowSame([0, 12.5, 25, 37.5, 50],
                           [819218, 817361.25, 815504.5, 813647.75, 811791])
        let p0s = rowSame([0, 12.5, 25, 37.5, 50],
                           [819218, 748993, 678768, 608543, 538318])
        let p0n = rowDistinct(
            [0, 3.8014984130859375, 6.769287109375, 8.993637084960938, 10.55859375],
            [0, 22.4775390625, 42.2734375, 59.5576171875, 74.5],
            [819218, 1041690.066192627, 1213177.9028320312, 1340986.4319152832, 1431884.6953125])
        let p0diag = rowDistinct(
            [0, 26.718769073486328, 48.9779052734375, 67.59994125366211, 83.3046875],
            [0, 43.032386779785156, 75.825927734375, 100.32415008544922, 118.1875],
            [819218, 1000275.4085350037, 1177890.404663086, 1341537.1816596985, 1483686.75390625])

        let p1m = rowSame([17, 25.25, 33.5, 41.75, 50],
                           [561872, 561907.5, 561943, 561978.5, 562014])
        let p1s = rowSame([17, 29.5, 42, 54.5, 67],
                           [561872, 491647, 421422, 351197, 280972])
        let p1n = rowDistinct(
            [17, 17.99609375, 18.859375, 19.58984375, 20.1875],
            [17, 39.4775390625, 59.2734375, 76.5576171875, 91.5],
            [561872, 750619.064453125, 909904.546875, 1041813.880859375, 1148432.5])
        let p1diag = rowDistinct(
            [17, 37.34912109375, 54.90234375, 69.85595703125, 82.40625],
            [17, 56.048011779785156, 85.388427734375, 106.96477508544922, 122.4375],
            [561872, 701026.6247558594, 845521.25390625, 988514.2438964844, 1124046.25])

        // P2 m/s identical to P1; n/diag misses identical to P1, own cost.
        let p2m = p1m
        let p2s = p1s
        let p2n = rowDistinct(
            [17, 17.99609375, 18.859375, 19.58984375, 20.1875],
            [17, 39.4775390625, 59.2734375, 76.5576171875, 91.5],
            [561872, 672415.3046875, 773656.21875, 865594.7421875, 948230.875])
        let p2diag = rowDistinct(
            [17, 37.34912109375, 54.90234375, 69.85595703125, 82.40625],
            [17, 56.048011779785156, 85.388427734375, 106.96477508544922, 122.4375],
            [561872, 614551.3134765625, 680451.1640625, 756379.4169921875, 839143.9375])

        let p3m = rowSame([34, 38, 42, 46, 50],
                           [375688, 377092.5, 378497, 379901.5, 381306])
        let p3s = rowSame([34, 46.5, 59, 71.5, 84],
                           [375688, 305463, 235238, 165013, 94788])
        let p3n = rowDistinct(
            [34, 34, 34, 34, 34],
            [34, 54.4189453125, 72.2890625, 87.7802734375, 101.0625],
            [375688, 422432.5, 469177, 515921.5, 562666])
        let p3diag = rowDistinct(
            [34, 49.46875, 62.875, 74.21875, 83.5],
            [34, 67.37079620361328, 92.302978515625, 110.55953216552734, 123.6328125],
            [375688, 357913.28125, 348741.125, 348171.53125, 356204.5])

        return [
            [.m: p0m, .s: p0s, .n: p0n, .diag: p0diag],
            [.m: p1m, .s: p1s, .n: p1n, .diag: p1diag],
            [.m: p2m, .s: p2s, .n: p2n, .diag: p2diag],
            [.m: p3m, .s: p3s, .n: p3n, .diag: p3diag],
        ]
    }

    func testGate2SuccessorDyadicLatticeBitForBit() throws {
        let expected = expectedGate2()
        let epsIdxs = [0, 16, 32, 48, 64]

        for gi in 0..<4 {
            let budget = SealedCourt.budgetGrid[gi].budget
            for sweep in SuccessorCourt.Sweep.allCases {
                let rows = expected[gi][sweep]!
                for (col, idx) in epsIdxs.enumerated() {
                    let eps = Double(idx) / 64.0
                    let k = SuccessorCourt.knobs(sweep, eps: eps)
                    let model = try CorruptionModel(epsM: k.m, epsS: k.s, epsN: k.n)
                    let ft = SuccessorCourt.frameTotals(model: model, budget: budget)
                    let e = rows[col]
                    XCTAssertEqual(ft.missesAlloc, e.missAlloc, "point \(gi) sweep \(sweep) idx \(idx) missesAlloc")
                    XCTAssertEqual(ft.missesGreedy, e.missGreedy, "point \(gi) sweep \(sweep) idx \(idx) missesGreedy")
                    XCTAssertEqual(ft.costAlloc, e.cost, "point \(gi) sweep \(sweep) idx \(idx) costAlloc")
                    XCTAssertEqual(ft.maxWeightDev, 0.0, "point \(gi) sweep \(sweep) idx \(idx) maxWeightDev")
                }
            }
        }

        // Anchors.
        let misses0 = [0.0, 17.0, 17.0, 34.0]
        for gi in 0..<4 {
            let budget = SealedCourt.budgetGrid[gi].budget
            let baseline = try CorruptionModel(epsM: 0, epsS: 0, epsN: 0)
            let ftBase = SuccessorCourt.frameTotals(model: baseline, budget: budget)
            XCTAssertEqual(ftBase.missesAlloc, misses0[gi], "misses0 point \(gi)")
            XCTAssertEqual(ftBase.missesGreedy, misses0[gi], "misses0 point \(gi)")

            let corner = try CorruptionModel(epsM: 1.0, epsS: 1.0, epsN: 0.0)
            let ftCorner = SuccessorCourt.frameTotals(model: corner, budget: budget)
            XCTAssertEqual(ftCorner.missesAlloc, 100.0, "corner point \(gi)")
            XCTAssertEqual(ftCorner.missesGreedy, 100.0, "corner point \(gi)")
        }

        // max |1 - weightSum| == 0.0 over the full 65-point lattice.
        let classes: [CulpritClass] = [.liar(.A), .liar(.B), .liar(.C), .deep, .drift, .quiet]
        var maxDev = 0.0
        for sweep in SuccessorCourt.Sweep.allCases {
            for i in 0...64 {
                let eps = Double(i) / 64.0
                let k = SuccessorCourt.knobs(sweep, eps: eps)
                let model = try CorruptionModel(epsM: k.m, epsS: k.s, epsN: k.n)
                for culprit in classes {
                    let outcomes = model.enumerateOutcomes(for: culprit)
                    let sum = outcomes.reduce(0.0) { $0 + $1.weight }
                    maxDev = max(maxDev, abs(1.0 - sum))
                }
            }
        }
        XCTAssertEqual(maxDev, 0.0)
    }

    /// Contract amendment 1 §8: pocket-6 r7 (5618) is affordable at every
    /// non-cut budget point, while the cheapest r7 pair (16570) exceeds
    /// every one — the mechanical fact that makes the merge rule and the
    /// successor's partial-tier options coincide in VALUE on the sealed
    /// grid, pinned as numbers here (never as rule equivalence).
    func testGate2MergeRuleCoincidesWithPartialOptions() {
        let pocket6r7 = SealedCourt.tariff[6]![7]!
        XCTAssertLessThan(pocket6r7, SealedCourt.budgetGrid[3].budget)

        let cheapestR7Pair = SealedCourt.tariff[5]![7]! + SealedCourt.tariff[6]![7]!
        XCTAssertGreaterThan(cheapestR7Pair, SealedCourt.budgetGrid[0].budget)
    }
}
