import Foundation

/// AttentionHook — twin spec line 6, `docs/contracts/HOOK_GATES_FROZEN.md`.
/// The sealed allocator court (`AllocatorCourt.run`) as a ticked engine
/// process: instead of replaying frames 1...(200+delta) in one batch call,
/// a hook advances one frame per `step()`, appending one ledger row each
/// time. `step()` reproduces `AllocatorCourt.run`'s lagged-arm loop body
/// FRAME BY FRAME for exactly the hook's one policy — quiet/warmup letters,
/// counter order, everything — calling `AllocatorCourt.recordOutcome` /
/// `.newArmBucket` / `.cheapestValue1Tier` / `.deepestAffordableTier`
/// directly so the arithmetic can never drift from the sealed court's. No
/// new number: H1 requires `hook.result == AllocatorCourt.run(...)[policy]`
/// bit for bit at every sealed grid point.
public struct AttentionHook: Equatable {
    public enum Policy: String, Codable, CaseIterable, Equatable {
        case allocator, greedy, uniform
    }

    public enum Outcome: String, Codable, Equatable {
        case hit, miss, none
    }

    /// A hook's fixed identity: which alarm set, which budget layout
    /// (`layoutId == nil` means the sealed default, `SealedCourt.
    /// makeLayout()`), the per-frame budget B, the lag delta, the lagged
    /// policy this hook replays, and (optionally) the clock it is bound
    /// to. The budget is constant per hook (ruling (d), HOOK_GATES_FROZEN
    /// §"Rulings"): a different B is a different hook, never a mid-run
    /// re-declaration.
    public struct Params: Equatable, Codable {
        public let alarmId: String
        public let layoutId: String?
        public let budget: Double
        public let delta: Int
        public let policy: Policy
        public let clockId: String?

        public init(alarmId: String, layoutId: String?, budget: Double,
                    delta: Int = SealedCourt.delta, policy: Policy, clockId: String? = nil) {
            self.alarmId = alarmId
            self.layoutId = layoutId
            self.budget = budget
            self.delta = delta
            self.policy = policy
            self.clockId = clockId
        }
    }

    /// One ledger line — H2's per-frame row. `rawClass`/`ear`/`pocket` are
    /// nil on an unjudged (warm-up) frame, or if the source record could
    /// not be resolved by index (never happens on a contiguous fixture —
    /// defensive only, mirrors the court's own `byIndex` guard). `tierBought`
    /// is nil whenever nothing was purchased (quiet allocator/greedy frames,
    /// allocator/greedy misses). `cumulativeCost` is the running
    /// `result.cost` AFTER this step (so `warmupCostExcluded` spend never
    /// shows up here — only `cost` does).
    public struct Row: Equatable {
        public let t: Int
        public let src: Int
        public let judged: Bool
        public let outcome: Outcome
        public let rawClass: String?
        public let ear: Ear?
        public let pocket: Int?
        public let tierBought: Int?
        public let spend: Double
        public let countsTowardCost: Bool
        public let cumulativeCost: Double
    }

    public let params: Params
    /// records.count + delta — the court's own frame count (warmupFrames
    /// excluded (delta) plus 200 judged plus... no: frames = 1...(200+delta),
    /// i.e. records.count + delta total steps).
    public let frames: Int
    public private(set) var t: Int = 0
    public private(set) var result: AllocatorCourt.ArmResult
    public private(set) var ledger: [Row] = []

    private let recordsCount: Int
    private let byIndex: [Int: AlarmRecord]
    private let layout: BudgetLayout

    public init(params: Params, records: [AlarmRecord], layout: BudgetLayout) {
        self.params = params
        self.recordsCount = records.count
        self.frames = records.count + params.delta
        self.byIndex = Dictionary(uniqueKeysWithValues: records.map { ($0.index, $0) })
        self.layout = layout
        self.result = AllocatorCourt.newArmBucket()
    }

    public var done: Bool { t >= frames }

    /// Advance one frame — nil (no-op) once `done`. Mirrors one iteration
    /// of `AllocatorCourt.run`'s `for tfrm in 1...(200 + delta)` loop for
    /// this hook's single policy.
    @discardableResult
    public mutating func step() -> Row? {
        guard !done else { return nil }
        t += 1
        let srcIdx = t - params.delta
        let isJudged = srcIdx >= 1 && srcIdx <= recordsCount

        if !isJudged {
            let row: Row
            if params.policy == .uniform {
                // Warm-up/tail frame, uniform: the court books the flat
                // frame cost into warmupCostExcluded (never into cost) and
                // still updates maxSpendRatio there, before `continue`.
                result.warmupCostExcluded += SealedCourt.uniformFrameCost
                let ratio = params.budget > 0 ? SealedCourt.uniformFrameCost / params.budget : 0.0
                result.maxSpendRatio = max(result.maxSpendRatio, ratio)
                row = Row(t: t, src: srcIdx, judged: false, outcome: .none, rawClass: nil, ear: nil,
                          pocket: nil, tierBought: nil, spend: SealedCourt.uniformFrameCost,
                          countsTowardCost: false, cumulativeCost: result.cost)
            } else {
                // allocator/greedy: the court just `continue`s — nothing
                // booked, nothing spent.
                row = Row(t: t, src: srcIdx, judged: false, outcome: .none, rawClass: nil, ear: nil,
                          pocket: nil, tierBought: nil, spend: 0, countsTowardCost: false,
                          cumulativeCost: result.cost)
            }
            ledger.append(row)
            return row
        }

        guard let src = byIndex[srcIdx] else {
            // Defensive: the court's own `byIndex` guard — never trips on a
            // contiguous fixture (byIndex covers 1...recordsCount exactly).
            let row = Row(t: t, src: srcIdx, judged: true, outcome: .none, rawClass: nil, ear: nil,
                          pocket: nil, tierBought: nil, spend: 0, countsTowardCost: false,
                          cumulativeCost: result.cost)
            ledger.append(row)
            return row
        }

        let row: Row

        if params.policy == .uniform {
            // Uniform always pays the flat frame cost into `cost` (and
            // updates the ratio) BEFORE the quiet check — a quiet source
            // still costs the frame, it just buys no hit/miss.
            let spend = SealedCourt.uniformFrameCost
            let ratio = params.budget > 0 ? spend / params.budget : 0.0
            result.maxSpendRatio = max(result.maxSpendRatio, ratio)
            result.cost += spend

            if let claim = src.claim {
                let hit = SealedCourt.value(claim.row, tier: SealedCourt.uniformTier) == 1
                if hit { result.served += 1 } else { result.misses += 1 }
                if hit { result.perClass[src.rawClass]?.served += 1 } else { result.perClass[src.rawClass]?.missed += 1 }
                if let ear = src.ear {
                    if hit { result.perEar[ear.rawValue]?.served += 1 } else { result.perEar[ear.rawValue]?.missed += 1 }
                }
                result.servedTrialIds.append(srcIdx)
                if src.pocket == SealedCourt.concentrationPocket {
                    result.burst.total += 1
                    if hit { result.burst.served += 1 } else { result.burst.missed += 1 }
                }
                // r4 is neither dummy(3) nor dominated(8-10) on the sealed
                // grid; checked mechanically anyway, matching the court.
                if SealedCourt.uniformTier == SealedCourt.dummyTier { result.dummy += 1 }
                if SealedCourt.dominatedTiers.contains(SealedCourt.uniformTier) { result.dominated += 1 }
                row = Row(t: t, src: srcIdx, judged: true, outcome: hit ? .hit : .miss, rawClass: src.rawClass,
                          ear: src.ear, pocket: src.pocket, tierBought: SealedCourt.uniformTier, spend: spend,
                          countsTowardCost: true, cumulativeCost: result.cost)
            } else {
                // quiet: cost paid, no hit/miss (mirrors the court's `continue`).
                row = Row(t: t, src: srcIdx, judged: true, outcome: .none, rawClass: src.rawClass, ear: src.ear,
                          pocket: src.pocket, tierBought: SealedCourt.uniformTier, spend: spend,
                          countsTowardCost: true, cumulativeCost: result.cost)
            }
        } else if let claim = src.claim {
            if params.policy == .allocator {
                let (r, c) = AllocatorCourt.cheapestValue1Tier(
                    row: claim.row, pocket: claim.pocket, budget: params.budget, layout: layout)
                let hit = r != nil
                let spend = hit ? c : 0
                AllocatorCourt.recordOutcome(&result, src, hit: hit, spend: spend, tierBought: r, budget: params.budget)
                row = Row(t: t, src: srcIdx, judged: true, outcome: hit ? .hit : .miss, rawClass: src.rawClass,
                          ear: src.ear, pocket: src.pocket, tierBought: r, spend: spend,
                          countsTowardCost: true, cumulativeCost: result.cost)
            } else {
                // greedy: deepest affordable tier in the SOURCE alarm's
                // pocket (no "loudest" from residuals — one alarm per frame).
                let (r, c) = AllocatorCourt.deepestAffordableTier(pocket: claim.pocket, budget: params.budget)
                let hit = (r != nil) && (SealedCourt.value(claim.row, tier: r!) == 1)
                let spend = r != nil ? c : 0
                AllocatorCourt.recordOutcome(&result, src, hit: hit, spend: spend, tierBought: r, budget: params.budget)
                row = Row(t: t, src: srcIdx, judged: true, outcome: hit ? .hit : .miss, rawClass: src.rawClass,
                          ear: src.ear, pocket: src.pocket, tierBought: r, spend: spend,
                          countsTowardCost: true, cumulativeCost: result.cost)
            }
        } else {
            // allocator/greedy, quiet source: nothing booked, nothing spent.
            row = Row(t: t, src: srcIdx, judged: true, outcome: .none, rawClass: src.rawClass, ear: src.ear,
                      pocket: src.pocket, tierBought: nil, spend: 0, countsTowardCost: false,
                      cumulativeCost: result.cost)
        }

        ledger.append(row)
        return row
    }

    /// Step until done or `n` frames have been stepped, whichever comes
    /// first. Returns the number of frames actually stepped.
    @discardableResult
    public mutating func step(_ n: Int) -> Int {
        var stepped = 0
        while stepped < n, !done {
            _ = step()
            stepped += 1
        }
        return stepped
    }
}
