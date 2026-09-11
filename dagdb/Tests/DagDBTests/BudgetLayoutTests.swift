import XCTest
@testable import DagDB

/// Fixtures use the sealed court's numbers: pockets 0..3 stand for the tree's
/// four rank-2 pockets; tiers 0..7 for r3..r10. Classes: 0=liar, 1=deep,
/// 2=drift; liar/drift need tier index 4 (r7), deep needs index 1 (r4).
final class BudgetLayoutTests: XCTestCase {
    private func layoutEngine() -> BudgetLayout {
        // cost[pocket][tier]: only the two load-bearing tiers carry sealed
        // numbers (r4, r7); the rest are monotone fillers.
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

    func testColocationRescue() throws {
        // True liar + phantom liar in the same pocket merge to value 2 and
        // beat a lone cheaper phantom elsewhere — the sealed rescue.
        let e = layoutEngine()
        let claims = [BudgetLayout.Claim(pocket: 0, classIndex: 0),
                      BudgetLayout.Claim(pocket: 0, classIndex: 0),
                      BudgetLayout.Claim(pocket: 3, classIndex: 0)]
        let l = try e.allocate(claims: claims, budget: 16164)
        XCTAssertEqual(l.servedPockets, [0])
        XCTAssertEqual(l.readValue, 2)
    }

    func testMinCostTieHandsSlotToCheapPocket() throws {
        // Equal value 1 vs 1: the lone pocket-3 claim (5618) legally beats
        // the pocket-0 claim (15138) — the sealed "legal miss" mechanism.
        let e = layoutEngine()
        let claims = [BudgetLayout.Claim(pocket: 0, classIndex: 0),
                      BudgetLayout.Claim(pocket: 3, classIndex: 0)]
        let l = try e.allocate(claims: claims, budget: 16164)
        XCTAssertEqual(l.servedPockets, [3])
        XCTAssertEqual(l.totalCost, 5618)
    }

    func testBothAffordableTakesBoth() throws {
        let e = layoutEngine()
        let claims = [BudgetLayout.Claim(pocket: 2, classIndex: 0),
                      BudgetLayout.Claim(pocket: 3, classIndex: 0)]
        let l = try e.allocate(claims: claims, budget: 20000)
        XCTAssertEqual(l.servedPockets, [2, 3])
        XCTAssertEqual(l.readValue, 2)
    }

    func testMergeTierIsDeepestRequirement() throws {
        // liar + deep in one pocket: one purchase at r7 covers both.
        let e = layoutEngine()
        let claims = [BudgetLayout.Claim(pocket: 3, classIndex: 1),
                      BudgetLayout.Claim(pocket: 3, classIndex: 0)]
        let l = try e.allocate(claims: claims, budget: 6000)
        XCTAssertEqual(l.purchases.count, 1)
        XCTAssertEqual(l.purchases[0].tier, 4)
        XCTAssertEqual(l.readValue, 2)
    }

    func testResidualTiePrefersLowestPockets() throws {
        // Two pockets, identical value and cost — lexicographically smallest
        // pocket set wins.
        let e = BudgetLayout(cost: [[10], [10]], minTier: [0])
        let claims = [BudgetLayout.Claim(pocket: 0, classIndex: 0),
                      BudgetLayout.Claim(pocket: 1, classIndex: 0)]
        let l = try e.allocate(claims: claims, budget: 10)
        XCTAssertEqual(l.servedPockets, [0])
    }

    func testEmptyClaimsAndBudgetGuard() throws {
        let e = layoutEngine()
        let empty = try e.allocate(claims: [], budget: 100)
        XCTAssertTrue(empty.purchases.isEmpty)
        let starved = try e.allocate(claims: [BudgetLayout.Claim(pocket: 3, classIndex: 0)],
                                     budget: 100)
        XCTAssertTrue(starved.purchases.isEmpty) // nothing affordable → buy nothing
    }
}
