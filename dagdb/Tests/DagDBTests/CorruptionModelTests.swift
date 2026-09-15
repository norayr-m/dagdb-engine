import XCTest
@testable import DagDB

/// the interface phase — CorruptionModel / SuccessorCourt, no fixture needed. Numbers
/// copied verbatim from `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md`'s sealed
/// gate-2 table and cross-checked against
/// `market/build_pregate_successor.py`'s own enumeration.
final class CorruptionModelTests: XCTestCase {

    // MARK: - trueBranches / phantomSubsets shape

    func testZeroKnobsGiveSingleOutcomePerClass() throws {
        let model = try CorruptionModel(epsM: 0, epsS: 0, epsN: 0)
        let allClasses: [(CulpritClass, String)] =
            [(.quiet, "quiet")] + SuccessorCourt.classSpecs.map { ($0.culprit, $0.label) }
        for (culprit, label) in allClasses {
            let outcomes = model.enumerateOutcomes(for: culprit)
            XCTAssertEqual(outcomes.count, 1, label)
            XCTAssertEqual(outcomes[0].weight, 1.0, label)
        }
    }

    func testLiarSwapBranchesAndOrder() throws {
        let half = try CorruptionModel(epsM: 0.5, epsS: 0, epsN: 0)
        let branches = half.trueBranches(for: .liar(.A))
        XCTAssertEqual(branches.count, 3)
        XCTAssertEqual(branches[0].weight, 0.5)
        XCTAssertEqual(branches[0].claim?.pocket, 3)
        XCTAssertEqual(branches[1].weight, 0.25)
        XCTAssertEqual(branches[1].claim?.pocket, 5)
        XCTAssertEqual(branches[2].weight, 0.25)
        XCTAssertEqual(branches[2].claim?.pocket, 6)

        let full = try CorruptionModel(epsM: 1.0, epsS: 0, epsN: 0)
        let atOne = full.trueBranches(for: .liar(.A)).filter { $0.weight > 0 }
        XCTAssertEqual(atOne.count, 2)
        XCTAssertEqual(Set(atOne.map { $0.claim!.pocket }), [5, 6])
        for b in atOne { XCTAssertEqual(b.weight, 0.5) }
    }

    func testDriftUnreadAtEpsSOne() throws {
        let model = try CorruptionModel(epsM: 0, epsS: 1.0, epsN: 0)
        let outcomes = model.enumerateOutcomes(for: .drift)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes[0].weight, 1.0)
        XCTAssertTrue(outcomes[0].claims.isEmpty)
        XCTAssertTrue(outcomes[0].pocketClaims.isEmpty)
    }

    func testDeepUntouchedByAllKnobs() throws {
        for (m, s) in [(0.0, 0.0), (0.3, 0.7), (1.0, 1.0)] {
            let model = try CorruptionModel(epsM: m, epsS: s, epsN: 0)
            let branches = model.trueBranches(for: .deep)
            XCTAssertEqual(branches.count, 1)
            XCTAssertEqual(branches[0].weight, 1.0)
            XCTAssertEqual(branches[0].claim, SealedClaim(pocket: 6, row: .D, isPhantom: false))
        }
    }

    func testPhantomSubsetsMaskOrderAndWeights() throws {
        let model = try CorruptionModel(epsM: 0, epsS: 0, epsN: 1.0)
        let subsets = model.phantomSubsets()
        XCTAssertEqual(subsets.count, 16)
        XCTAssertEqual(subsets[5].pockets, [3, 5])
        XCTAssertEqual(subsets[5].weight, 0.25 * 0.25 * 0.75 * 0.75)
        let sum = subsets.reduce(0.0) { $0 + $1.weight }
        XCTAssertEqual(sum, 1.0)
    }

    func testWeightSumsExactlyOneOverFullLattice() throws {
        let classes: [CulpritClass] = [.liar(.A), .liar(.B), .liar(.C), .deep, .drift, .quiet]
        for sweep in SuccessorCourt.Sweep.allCases {
            for i in 0...64 {
                let eps = Double(i) / 64.0
                let k = SuccessorCourt.knobs(sweep, eps: eps)
                let model = try CorruptionModel(epsM: k.m, epsS: k.s, epsN: k.n)
                for culprit in classes {
                    let outcomes = model.enumerateOutcomes(for: culprit)
                    let sum = outcomes.reduce(0.0) { $0 + $1.weight }
                    XCTAssertEqual(sum, 1.0, "sweep \(sweep) i \(i) culprit \(culprit)")
                }
            }
        }
    }

    // MARK: - Sealed anchors (allocator/greedy court)

    func testMisses0Baseline() throws {
        let model = try CorruptionModel(epsM: 0, epsS: 0, epsN: 0)
        let expectedMisses0 = [0.0, 17.0, 17.0, 34.0]
        for gi in 0..<4 {
            let budget = SealedCourt.budgetGrid[gi].budget
            let ft = SuccessorCourt.frameTotals(model: model, budget: budget)
            XCTAssertEqual(ft.missesAlloc, expectedMisses0[gi], "point \(gi)")
            XCTAssertEqual(ft.missesGreedy, expectedMisses0[gi], "point \(gi)")
        }
    }

    func testCornerTouch() throws {
        let model = try CorruptionModel(epsM: 1.0, epsS: 1.0, epsN: 0.0)
        for gi in 0..<4 {
            let budget = SealedCourt.budgetGrid[gi].budget
            let ft = SuccessorCourt.frameTotals(model: model, budget: budget)
            XCTAssertEqual(ft.missesAlloc, 100.0, "point \(gi)")
            XCTAssertEqual(ft.missesGreedy, 100.0, "point \(gi)")
        }
    }

    func testKnobRangeRejected() {
        XCTAssertThrowsError(try CorruptionModel(epsM: 1.5, epsS: 0, epsN: 0)) { error in
            guard case CorruptionModel.CorruptionError.knobOutOfRange(let name, let v) = error else {
                XCTFail("wrong error type: \(error)")
                return
            }
            XCTAssertEqual(name, "epsM")
            XCTAssertEqual(v, 1.5)
        }
        XCTAssertThrowsError(try CorruptionModel(epsM: 0, epsS: -0.1, epsN: 0))
        XCTAssertThrowsError(try CorruptionModel(epsM: 0, epsS: 0, epsN: Double.nan))
        XCTAssertThrowsError(try CorruptionModel(epsM: 0, epsS: 0, epsN: Double.infinity))
    }

    // MARK: - Staircase mechanism (direct SuccessorCourt.allocatorDecide check)

    func testStaircaseAtPoint0() throws {
        let B0 = SealedCourt.budgetGrid[0].budget
        let homeByEar: [Ear: Int] = [.A: 3, .B: 5, .C: 6]
        let expectedDisplacedBy: [Ear: Set<Int>] = [.A: [4, 5, 6], .B: [6], .C: []]
        for ear in Ear.allCases {
            let home = homeByEar[ear]!
            var displacedBy: Set<Int> = []
            for q in SealedCourt.pockets where q != home {
                let pocketClaims: [Int: [ValueRow]] = [home: [.L], q: [.L]]
                let (served, _) = try SuccessorCourt.allocatorDecide(pocketClaims: pocketClaims, budget: B0)
                if !served.contains(home) {
                    displacedBy.insert(q)
                }
            }
            XCTAssertEqual(displacedBy, expectedDisplacedBy[ear], "ear \(ear)")
        }
    }

    // MARK: - Gate-2 dyadic preview (point 0 only; T4 tests the whole table)

    func testGate2DyadicPreviewPoint0() throws {
        let B0 = SealedCourt.budgetGrid[0].budget
        XCTAssertEqual(B0, 16164.352484758914)

        let km = SuccessorCourt.knobs(.m, eps: 0.25)
        let modelM = try CorruptionModel(epsM: km.m, epsS: km.s, epsN: km.n)
        let ftM = SuccessorCourt.frameTotals(model: modelM, budget: B0)
        XCTAssertEqual(ftM.missesAlloc, 12.5)
        XCTAssertEqual(ftM.costAlloc, 817361.25)

        let kn = SuccessorCourt.knobs(.n, eps: 0.25)
        let modelN = try CorruptionModel(epsM: kn.m, epsS: kn.s, epsN: kn.n)
        let ftN = SuccessorCourt.frameTotals(model: modelN, budget: B0)
        XCTAssertEqual(ftN.missesAlloc, 3.8014984130859375)
        XCTAssertEqual(ftN.missesGreedy, 22.4775390625)
        XCTAssertEqual(ftN.costAlloc, 1041690.066192627)
    }
}
