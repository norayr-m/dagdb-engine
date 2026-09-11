import Foundation

/// Successor counting hand — twin spec line 4's second sealed court. Mirrors
/// `market/build_pregate_successor.py`'s `allocator_decide` / `greedy_decide`
/// / `class_stats_at` / `frame_totals_at` bit-for-bit over the corrupted-read
/// enumeration produced by `CorruptionModel`.
///
/// `allocatorDecide` reproduces the SUCCESSOR's own multi-claim allocator
/// (law 39's second bite): per-pocket Pareto frontiers of (cost, value,
/// tier), `itertools.product` over occupied pockets, max value → min cost →
/// residual lexicographic tie-break. This is deliberately NOT
/// `BudgetLayout.allocate` — the successor allows a pocket to buy a tier
/// that satisfies only PART of its claims (e.g. the deep row at tier 4
/// while an L claim at the same pocket goes unserved), a partial-tier
/// option `BudgetLayout`'s merge rule does not express. Contract amendment
/// 1 §8: the two rules coincide in VALUE on the sealed grid only because
/// no two pockets are ever affordable at r7 together there — the gate pins
/// numbers, not rule equivalence.
public enum SuccessorCourt {
    public enum Sweep: String, CaseIterable {
        case m, s, n, diag
    }

    /// (εm, εs, εn) for one point on a sweep's lattice (mirrors `eps_triple`).
    public static func knobs(_ sweep: Sweep, eps: Double) -> (m: Double, s: Double, n: Double) {
        switch sweep {
        case .m: return (eps, 0.0, 0.0)
        case .s: return (0.0, eps, 0.0)
        case .n: return (0.0, 0.0, eps)
        case .diag: return (eps, eps, eps)
        }
    }

    /// The five non-quiet classes, in the sealed accumulation order
    /// (liar_A, liar_B, liar_C, deep, drift — mirrors `CLASS_SPECS`).
    public static let classSpecs: [(culprit: CulpritClass, label: String)] = [
        (.liar(.A), "liar_A"),
        (.liar(.B), "liar_B"),
        (.liar(.C), "liar_C"),
        (.deep, "deep"),
        (.drift, "drift"),
    ]

    /// Pareto frontier of (cost, value, tier) for one pocket given the
    /// multiset of value rows claimed there — mirrors `pocket_options`.
    /// Always includes the baseline (0 cost, 0 value, no tier); every
    /// other entry strictly increases value over the previous frontier
    /// point as cost rises.
    private static func pocketOptions(
        pattern: [ValueRow], pocket: Int, layout: BudgetLayout
    ) -> [(cost: Double, value: Int, tier: Int?)] {
        var opts: [(cost: Double, value: Int, tier: Int?)] = [(0.0, 0, nil)]
        let pi = SealedCourt.pocketIndex(pocket)
        for r in SealedCourt.tiers {
            let val = pattern.reduce(0) { $0 + SealedCourt.value($1, tier: r) }
            if val > 0 {
                let ti = SealedCourt.tierIndex(r)
                opts.append((layout.cost[pi][ti], val, r))
            }
        }
        opts.sort { $0.cost < $1.cost }
        var frontier: [(cost: Double, value: Int, tier: Int?)] = []
        var bestVal = -1
        for o in opts where o.value > bestVal {
            frontier.append(o)
            bestVal = o.value
        }
        return frontier
    }

    private static func lexLess(_ a: [Int], _ b: [Int]) -> Bool {
        for (x, y) in zip(a, b) {
            if x != y { return x < y }
        }
        return a.count < b.count
    }

    /// Multi-claim allocator: maximize total READ value over in-budget
    /// purchase sets across occupied pockets; tie -> minimum total cost;
    /// residual tie -> lowest-pocket-first tiebreak tuple (law 39's
    /// second-bite rule). Feasibility test mirrored exactly:
    /// `total_cost > budget + 1e-9` is infeasible (contract amendment 1
    /// §10). `served` is the set of occupied pockets where the winning
    /// combo bought a non-baseline option (value > 0 at the chosen tier),
    /// regardless of whether every claim at that pocket is satisfied.
    public static func allocatorDecide(
        pocketClaims: [Int: [ValueRow]], budget: Double, layout: BudgetLayout = SealedCourt.makeLayout()
    ) -> (served: Set<Int>, cost: Double) {
        let occ = pocketClaims.keys.sorted()
        guard !occ.isEmpty else { return ([], 0.0) }
        let optLists = occ.map { pocketOptions(pattern: pocketClaims[$0]!, pocket: $0, layout: layout) }

        var bestValue = -1
        var bestCost = 0.0
        var bestTiebreak: [Int] = []
        var bestCombo: [(cost: Double, value: Int, tier: Int?)]? = nil

        func consider(_ combo: [(cost: Double, value: Int, tier: Int?)]) {
            let totalCost = combo.reduce(0.0) { $0 + $1.cost }
            if totalCost > budget + 1e-9 { return }
            let totalValue = combo.reduce(0) { $0 + $1.value }
            let tiebreak = combo.map { $0.tier != nil ? 0 : 1 }
            if bestCombo == nil
                || totalValue > bestValue
                || (totalValue == bestValue && totalCost < bestCost)
                || (totalValue == bestValue && totalCost == bestCost && lexLess(tiebreak, bestTiebreak))
            {
                bestValue = totalValue
                bestCost = totalCost
                bestTiebreak = tiebreak
                bestCombo = combo
            }
        }

        func recurse(_ idx: Int, _ combo: [(cost: Double, value: Int, tier: Int?)]) {
            if idx == optLists.count {
                consider(combo)
                return
            }
            for o in optLists[idx] {
                recurse(idx + 1, combo + [o])
            }
        }
        recurse(0, [])

        guard let combo = bestCombo else { return ([], 0.0) }
        var served: Set<Int> = []
        var totalCost = 0.0
        for (i, o) in combo.enumerated() {
            totalCost += o.cost
            if o.tier != nil { served.insert(occ[i]) }
        }
        return (served, totalCost)
    }

    /// Greedy: lowest occupied pocket, deepest tier affordable there by
    /// cost alone (independent of what the claims at that pocket actually
    /// need — mirrors `greedy_decide` / `deepest_affordable`).
    public static func greedyDecide(
        pocketClaims: [Int: [ValueRow]], budget: Double
    ) -> (pocket: Int?, tier: Int?, cost: Double) {
        guard let pMin = pocketClaims.keys.min() else { return (nil, nil, 0.0) }
        for r in SealedCourt.tiers.reversed() {
            let c = SealedCourt.tariff[pMin]![r]!
            if c <= budget {
                return (pMin, r, c)
            }
        }
        return (pMin, nil, 0.0)
    }

    public struct ClassStats: Equatable {
        public let weightSum: Double
        public let missAlloc: Double?
        public let missGreedy: Double?
        public let costAlloc: Double
        public let costGreedy: Double
        public init(weightSum: Double, missAlloc: Double?, missGreedy: Double?, costAlloc: Double, costGreedy: Double) {
            self.weightSum = weightSum
            self.missAlloc = missAlloc
            self.missGreedy = missGreedy
            self.costAlloc = costAlloc
            self.costGreedy = costGreedy
        }
    }

    /// Per-class expectation at one (model, budget) point — mirrors
    /// `class_stats_at`. Scoring always checks the FIXED true pocket/row
    /// (`CorruptionModel.truePocketRow`), never the per-branch read pocket:
    /// a swapped-away or unread true claim can still be served if some
    /// OTHER claim (typically a phantom) independently occupies the true
    /// pocket at a sufficient tier — that coincidence is real under this
    /// model (retention scoring) and must not be scored as an automatic
    /// miss. Quiet has no miss probability (no true alarm to miss); cost
    /// still accrues.
    public static func classStats(culprit: CulpritClass, model: CorruptionModel, budget: Double) -> ClassStats {
        let outcomes = model.enumerateOutcomes(for: culprit)
        let truth = CorruptionModel.truePocketRow(for: culprit)
        let isQuiet = (culprit == .quiet)

        var weightSum = 0.0
        var missA = 0.0
        var missG = 0.0
        var costA = 0.0
        var costG = 0.0

        for outcome in outcomes {
            let w = outcome.weight
            weightSum += w
            let (servedA, cA) = allocatorDecide(pocketClaims: outcome.pocketClaims, budget: budget)
            let (pMinG, tierG, cG) = greedyDecide(pocketClaims: outcome.pocketClaims, budget: budget)
            costA += w * cA
            costG += w * cG
            if !isQuiet, let truth = truth {
                let hitA = servedA.contains(truth.pocket)
                let hitG = (pMinG == truth.pocket) && (tierG != nil) && (SealedCourt.value(truth.row, tier: tierG!) == 1)
                missA += w * (hitA ? 0.0 : 1.0)
                missG += w * (hitG ? 0.0 : 1.0)
            }
        }

        return ClassStats(
            weightSum: weightSum,
            missAlloc: isQuiet ? nil : missA,
            missGreedy: isQuiet ? nil : missG,
            costAlloc: costA,
            costGreedy: costG)
    }

    public struct FrameTotals: Equatable {
        public let missesAlloc: Double
        public let missesGreedy: Double
        public let costAlloc: Double
        public let costGreedy: Double
        public let maxWeightDev: Double
        public let perClass: [String: ClassStats]
        public init(
            missesAlloc: Double, missesGreedy: Double, costAlloc: Double, costGreedy: Double,
            maxWeightDev: Double, perClass: [String: ClassStats]
        ) {
            self.missesAlloc = missesAlloc
            self.missesGreedy = missesGreedy
            self.costAlloc = costAlloc
            self.costGreedy = costGreedy
            self.maxWeightDev = maxWeightDev
            self.perClass = perClass
        }
    }

    /// Frame-level expectation over all 200 judged trials at one (model,
    /// budget) point — mirrors `frame_totals_at`. Accumulation order
    /// mirrors the Python loop exactly: liar_A, liar_B, liar_C, deep,
    /// drift, then quiet's cost (harmless on the sealed dyadic five per
    /// contract amendment 1 §10, but mirrored anyway).
    public static func frameTotals(
        counts: [String: Int] = SealedCourt.classCounts, model: CorruptionModel, budget: Double
    ) -> FrameTotals {
        var missA = 0.0
        var missG = 0.0
        var costA = 0.0
        var costG = 0.0
        var maxDev = 0.0
        var perClass: [String: ClassStats] = [:]

        for (culprit, label) in classSpecs {
            let st = classStats(culprit: culprit, model: model, budget: budget)
            let n = Double(counts[label] ?? 0)
            missA += n * (st.missAlloc ?? 0.0)
            missG += n * (st.missGreedy ?? 0.0)
            costA += n * st.costAlloc
            costG += n * st.costGreedy
            maxDev = max(maxDev, abs(1.0 - st.weightSum))
            perClass[label] = st
        }

        let stQ = classStats(culprit: .quiet, model: model, budget: budget)
        let nQ = Double(counts["quiet"] ?? 0)
        costA += nQ * stQ.costAlloc
        costG += nQ * stQ.costGreedy
        maxDev = max(maxDev, abs(1.0 - stQ.weightSum))
        perClass["quiet"] = stQ

        return FrameTotals(
            missesAlloc: missA, missesGreedy: missG, costAlloc: costA, costGreedy: costG,
            maxWeightDev: maxDev, perClass: perClass)
    }
}
