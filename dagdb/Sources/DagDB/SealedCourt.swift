import Foundation

/// Sealed numbers and index mapping for the W2 allocator/successor courts
/// — twin spec line 4's fixed vocabulary, frozen in
/// `market/pregate_allocator_v2.json` / `market/court_allocator_runs.json`
/// / `market/pregate_successor_v1.json`. Nothing here is derived; every
/// literal is copied from the sealed record. `BudgetLayoutTests.swift`
/// (an unrelated, pre-existing fixture) is untouched.
///
/// Index collision (interface-phase convention 7): sealed ids stay on `AlarmRecord`/
/// `SealedClaim` using pocket numbers 3..6 and tiers r3..r10.
/// `SealedCourt` converts to the zero-based indices `BudgetLayout` wants:
/// `pocketIndex(p) = p − 3`, `tierIndex(r) = r − 3`, class index by value
/// row `L → 0` (minTier 4 = r7), `D → 1` (minTier 1 = r4).
public enum SealedCourt {
    public static let pockets = [3, 4, 5, 6]
    public static let tiers = Array(3...10)
    public static let delta = 3
    public static let dummyTier = 3
    public static let dominatedTiers: Set<Int> = [8, 9, 10]

    public static let concentrationPocket = 6
    public static let uniformTier = 4
    public static let uniformFrameCost = 472.0

    public static let deepPocket = 6
    public static let driftPocket = 6

    /// Held-carrier boundary `m` per pocket/tier — the tariff is `2·m²`.
    public static let tariffM: [Int: [Int: Int]] = [
        3: [3: 3, 4: 9, 5: 20, 6: 44, 7: 87, 8: 174, 9: 356, 10: 725],
        4: [3: 2, 4: 5, 5: 13, 6: 32, 7: 78, 8: 166, 9: 347, 10: 706],
        5: [3: 3, 4: 9, 5: 19, 6: 37, 7: 74, 8: 152, 9: 308, 10: 625],
        6: [3: 3, 4: 7, 5: 13, 6: 27, 7: 53, 8: 105, 9: 207, 10: 405],
    ]

    /// Answer-flop tariff, `2·m²` per pocket/tier.
    public static let tariff: [Int: [Int: Double]] = {
        var t: [Int: [Int: Double]] = [:]
        for (pocket, row) in tariffM {
            var r: [Int: Double] = [:]
            for (tier, m) in row {
                r[tier] = Double(2 * m * m)
            }
            t[pocket] = r
        }
        return t
    }()

    /// (budget, k7) grid — the five sealed deficit points, richest first.
    public static let budgetGrid: [(budget: Double, k7: Int)] = [
        (16164.352484758914, 4),
        (13491.480553724456, 3),
        (11528.02214532872, 2),
        (7426.473868436935, 1),
        (3128.126645687496, 0),
    ]

    /// Class counts over the 200 judged trials (cal0 excluded).
    public static let classCounts: [String: Int] = [
        "quiet": 50,
        "liar_A": 17,
        "liar_B": 17,
        "liar_C": 16,
        "deep": 50,
        "drift": 50,
    ]

    /// EAR → pocket: A3, B5, C6.
    public static func pocket(for ear: Ear) -> Int {
        switch ear {
        case .A: return 3
        case .B: return 5
        case .C: return 6
        }
    }

    /// value(row, r) = 1 iff the culprit's carrier is held at tier r:
    /// L (liar/drift) needs r ≥ 7, D (deep) needs r ≥ 4.
    public static func value(_ row: ValueRow, tier: Int) -> Int {
        switch row {
        case .L: return tier >= 7 ? 1 : 0
        case .D: return tier >= 4 ? 1 : 0
        }
    }

    public static func pocketIndex(_ sealedPocket: Int) -> Int { sealedPocket - 3 }
    public static func tierIndex(_ sealedTier: Int) -> Int { sealedTier - 3 }
    public static func sealedTier(_ tierIndex: Int) -> Int { tierIndex + 3 }
    public static func sealedPocket(_ pocketIndex: Int) -> Int { pocketIndex + 3 }

    /// L → 0, D → 1.
    public static func classIndex(_ row: ValueRow) -> Int {
        row == .L ? 0 : 1
    }

    /// The sealed `BudgetLayout`: cost[4 pockets][8 tiers] from the
    /// tariff table, minTier = [tierIndex(7), tierIndex(4)] = [4, 1].
    public static func makeLayout() -> BudgetLayout {
        var cost = [[Double]](
            repeating: [Double](repeating: 0, count: tiers.count),
            count: pockets.count)
        for (pi, p) in pockets.enumerated() {
            for (ti, r) in tiers.enumerated() {
                cost[pi][ti] = tariff[p]![r]!
            }
        }
        return BudgetLayout(cost: cost, minTier: [tierIndex(7), tierIndex(4)])
    }

    /// Convert a sealed claim into `BudgetLayout`'s zero-based claim.
    public static func claim(_ c: SealedClaim) -> BudgetLayout.Claim {
        BudgetLayout.Claim(pocket: pocketIndex(c.pocket), classIndex: classIndex(c.row))
    }
}
