import Foundation

/// Allocator-court replay — twin spec line 4's gate 1. Mirrors
/// `market/build_court_allocator_runs.py`'s `run_point` bit-for-bit: four
/// arms (allocator, uniform, greedy, oracle) over the five sealed
/// budget-grid points. Mechanical replay only — no gate judgment lives
/// here; `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md` is the frozen criterion this
/// type is compared against (interface phase, 2026-09).
///
/// Burst (contract amendment 1 §5): the letter's frame-level burst
/// phrase, taken literally on one-alarm frames, would count every
/// non-quiet frame (150) as a "burst" — the sealed number is 116, which is
/// `liar_C(16) + deep(50) + drift(50)` = the concentration-pocket (6)
/// count, the letter's own parenthesis. The frame-level phrase is
/// therefore NOT implemented; burst here is exactly the alarm-level
/// definition (`pocket == concentrationPocket`), which coincides with the
/// frame level 1:1 because this replay has one alarm per frame.
public enum AllocatorCourt {
    public enum Arm: String, CaseIterable, Codable {
        case allocator, uniform, greedy, oracle
    }

    public struct Tally: Equatable, Codable {
        public var served = 0, missed = 0
    }

    public struct Burst: Equatable, Codable {
        public var served = 0, missed = 0, total = 0
    }

    public struct ArmResult: Equatable, Codable {
        public var misses = 0, served = 0, dummy = 0, dominated = 0
        public var cost = 0.0, maxSpendRatio = 0.0, warmupCostExcluded = 0.0
        public var perClass: [String: Tally]
        public var perEar: [String: Tally]
        public var burst = Burst()
        public var servedTrialIds: [Int] = []
        public let warmupFramesExcluded = 3, tailFramesAppended = 3
    }

    public struct Frame: Equatable {
        public let index: Int, key: String, rawClass: String, ear: Ear?, classLabel: String?, pocket: Int?
    }

    /// Derived per-frame view of the sealed records: same fields
    /// `run_point`'s trial dicts carry, `classLabel`/`pocket` nil for
    /// quiet (mirrors Python's `class_label, pocket = None, None`).
    public static func frames(_ records: [AlarmRecord]) -> [Frame] {
        records.map { r in
            let label: String?
            if case .quiet = r.culprit {
                label = nil
            } else {
                label = r.classLabel
            }
            return Frame(index: r.index, key: r.key, rawClass: r.rawClass, ear: r.ear,
                         classLabel: label, pocket: r.pocket)
        }
    }

    /// Smallest tier with value 1 for `row` that is affordable at `budget`
    /// — mirrors `cheapest_value1_tier`. `SealedCourt.tiers` is already
    /// ascending, so the first affordable candidate is the cheapest.
    public static func cheapestValue1Tier(
        row: ValueRow, pocket: Int, budget: Double, layout: BudgetLayout = SealedCourt.makeLayout()
    ) -> (tier: Int?, cost: Double) {
        let pi = SealedCourt.pocketIndex(pocket)
        for r in SealedCourt.tiers where SealedCourt.value(row, tier: r) == 1 {
            let c = layout.cost[pi][SealedCourt.tierIndex(r)]
            if c <= budget { return (r, c) }
        }
        return (nil, 0)
    }

    /// Deepest tier affordable at `budget`, independent of value — mirrors
    /// `deepest_affordable_tier`. Uses the sealed tariff directly (no
    /// `layout` parameter, matching Python's direct `cost[pocket][r]` read).
    public static func deepestAffordableTier(pocket: Int, budget: Double) -> (tier: Int?, cost: Double) {
        for r in SealedCourt.tiers.reversed() {
            let c = SealedCourt.tariff[pocket]![r]!
            if c <= budget { return (r, c) }
        }
        return (nil, 0)
    }

    /// `internal`, not `private`: `AttentionHook` (twin spec line 6, the
    /// incremental hook) reproduces this court's per-frame loop one frame
    /// at a time and calls this exact function so its arithmetic can never
    /// drift from the court's — never change what it computes.
    static func newArmBucket() -> ArmResult {
        ArmResult(
            perClass: ["quiet": Tally(), "liar": Tally(), "deep": Tally(), "drift": Tally()],
            perEar: ["A": Tally(), "B": Tally(), "C": Tally()])
    }

    /// Records the outcome of one judged, non-quiet trial into `arm` —
    /// mirrors `record_outcome`. Counter order matches the Python hand:
    /// maxSpendRatio, cost, dummy, dominated, served/misses, perClass (by
    /// raw class), perEar (when an ear is present), servedTrialIds, burst
    /// (when the trial's pocket is the concentration pocket).
    ///
    /// `internal`, not `private`: shared verbatim with `AttentionHook`
    /// (see `newArmBucket`'s comment) — never change its arithmetic.
    static func recordOutcome(
        _ arm: inout ArmResult, _ trial: AlarmRecord, hit: Bool, spend: Double, tierBought: Int?, budget: Double
    ) {
        let ratio = budget > 0 ? spend / budget : 0.0
        arm.maxSpendRatio = max(arm.maxSpendRatio, ratio)
        arm.cost += spend
        if tierBought == SealedCourt.dummyTier { arm.dummy += 1 }
        if let t = tierBought, SealedCourt.dominatedTiers.contains(t) { arm.dominated += 1 }
        if hit { arm.served += 1 } else { arm.misses += 1 }
        if hit { arm.perClass[trial.rawClass]?.served += 1 } else { arm.perClass[trial.rawClass]?.missed += 1 }
        if let ear = trial.ear {
            if hit { arm.perEar[ear.rawValue]?.served += 1 } else { arm.perEar[ear.rawValue]?.missed += 1 }
        }
        arm.servedTrialIds.append(trial.index)
        if trial.pocket == SealedCourt.concentrationPocket {
            arm.burst.total += 1
            if hit { arm.burst.served += 1 } else { arm.burst.missed += 1 }
        }
    }

    /// Replay all four arms at one budget point — mirrors `run_point`
    /// exactly. Frames t = 1...(200+delta): src = t - delta; frames whose
    /// src falls outside 1...200 are warmup/tail — uniform still books its
    /// flat frame cost into `warmupCostExcluded` and updates
    /// `maxSpendRatio` there, the other arms simply skip. Quiet-sourced
    /// judged frames buy nothing (not a miss) for allocator/greedy/oracle;
    /// uniform still pays its flat cost on every judged frame regardless
    /// of class. Oracle iterates the 200 trials directly with no lag.
    public static func run(records: [AlarmRecord], budget: Double, delta: Int = SealedCourt.delta) -> [Arm: ArmResult] {
        let layout = SealedCourt.makeLayout()
        let byIndex = Dictionary(uniqueKeysWithValues: records.map { ($0.index, $0) })
        var out: [Arm: ArmResult] = [:]

        // ---- Oracle: no lag, direct 1:1 on each trial's own frame ----
        var oracle = newArmBucket()
        for t in records {
            guard let claim = t.claim else { continue }  // quiet: nothing to judge
            let (r, c) = cheapestValue1Tier(row: claim.row, pocket: claim.pocket, budget: budget, layout: layout)
            let hit = r != nil
            recordOutcome(&oracle, t, hit: hit, spend: hit ? c : 0, tierBought: r, budget: budget)
        }
        out[.oracle] = oracle

        // ---- Lagged arms: allocator, uniform, greedy ----
        for armName in [Arm.allocator, .uniform, .greedy] {
            var arm = newArmBucket()
            for tfrm in 1...(200 + delta) {
                let srcIdx = tfrm - delta
                let isJudged = srcIdx >= 1 && srcIdx <= 200
                if !isJudged {
                    if armName == .uniform {
                        arm.warmupCostExcluded += SealedCourt.uniformFrameCost
                        let ratio = budget > 0 ? SealedCourt.uniformFrameCost / budget : 0.0
                        arm.maxSpendRatio = max(arm.maxSpendRatio, ratio)
                    }
                    continue
                }

                guard let src = byIndex[srcIdx] else { continue }

                if armName == .uniform {
                    let spend = SealedCourt.uniformFrameCost
                    let ratio = budget > 0 ? spend / budget : 0.0
                    arm.maxSpendRatio = max(arm.maxSpendRatio, ratio)
                    arm.cost += spend
                    guard let claim = src.claim else { continue }  // quiet: cost paid, no hit/miss
                    let hit = SealedCourt.value(claim.row, tier: SealedCourt.uniformTier) == 1
                    if hit { arm.served += 1 } else { arm.misses += 1 }
                    if hit { arm.perClass[src.rawClass]?.served += 1 } else { arm.perClass[src.rawClass]?.missed += 1 }
                    if let ear = src.ear {
                        if hit { arm.perEar[ear.rawValue]?.served += 1 } else { arm.perEar[ear.rawValue]?.missed += 1 }
                    }
                    arm.servedTrialIds.append(srcIdx)
                    if src.pocket == SealedCourt.concentrationPocket {
                        arm.burst.total += 1
                        if hit { arm.burst.served += 1 } else { arm.burst.missed += 1 }
                    }
                    // r4 is neither dummy(3) nor dominated(8-10) on the sealed grid;
                    // checked mechanically anyway, matching the Python hand.
                    if SealedCourt.uniformTier == SealedCourt.dummyTier { arm.dummy += 1 }
                    if SealedCourt.dominatedTiers.contains(SealedCourt.uniformTier) { arm.dominated += 1 }
                    continue
                }

                guard let claim = src.claim else { continue }  // quiet: no alarm, buys nothing

                if armName == .allocator {
                    let (r, c) = cheapestValue1Tier(row: claim.row, pocket: claim.pocket, budget: budget, layout: layout)
                    let hit = r != nil
                    recordOutcome(&arm, src, hit: hit, spend: hit ? c : 0, tierBought: r, budget: budget)
                } else if armName == .greedy {
                    let (r, c) = deepestAffordableTier(pocket: claim.pocket, budget: budget)
                    let hit = (r != nil) && (SealedCourt.value(claim.row, tier: r!) == 1)
                    recordOutcome(&arm, src, hit: hit, spend: r != nil ? c : 0, tierBought: r, budget: budget)
                }
            }
            out[armName] = arm
        }

        return out
    }

    /// `run` at every point of the sealed budget grid, richest first.
    public static func runGrid(records: [AlarmRecord]) -> [(budget: Double, k7: Int, arms: [Arm: ArmResult])] {
        SealedCourt.budgetGrid.map { g in
            (budget: g.budget, k7: g.k7, arms: run(records: records, budget: g.budget))
        }
    }
}
