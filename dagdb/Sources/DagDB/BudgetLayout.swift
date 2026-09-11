import Foundation

/// Per-frame budget layout — twin spec line 5, the knapsack primitive.
///
/// The decision letters were frozen and sealed twice (allocator court,
/// successor court) and are load-bearing: a legal optimizer with a different
/// tie-break breaks sealed theorems. Shipped here as code, verbatim:
///
///   1. maximize total READ value over in-budget purchase sets;
///   2. ties on value → minimum total cost;
///   3. residual tie → lexicographically smallest sorted pocket set;
///   • claims of one pocket MERGE: one purchase covers them all, their read
///     values add, and the purchase tier is the cheapest tier sufficient for
///     the deepest requirement among the pocket's claims.
///
/// The primitive judges nothing (misses are the court's affair, scored
/// against truth elsewhere) — it only lays out a frame's budget.
public struct BudgetLayout: Equatable, Codable {
    /// cost[pocket][tier] — answer-flop tariff, printed by the fold ladder.
    public let cost: [[Double]]
    /// minTier[class] — cheapest tier index sufficient for the class.
    public let minTier: [Int]

    public init(cost: [[Double]], minTier: [Int]) {
        self.cost = cost
        self.minTier = minTier
    }

    public struct Claim: Equatable, Codable {
        public let pocket: Int
        public let classIndex: Int
        public init(pocket: Int, classIndex: Int) {
            self.pocket = pocket
            self.classIndex = classIndex
        }
    }

    public struct Purchase: Equatable, Codable {
        public let pocket: Int
        public let tier: Int
        public let cost: Double
        public let readValue: Int
        public init(pocket: Int, tier: Int, cost: Double, readValue: Int) {
            self.pocket = pocket
            self.tier = tier
            self.cost = cost
            self.readValue = readValue
        }
    }

    public struct Layout: Equatable, Codable {
        public let purchases: [Purchase]     // sorted by pocket
        public let readValue: Int
        public let totalCost: Double
        public var servedPockets: [Int] { purchases.map(\.pocket) }
        public init(purchases: [Purchase], readValue: Int, totalCost: Double) {
            self.purchases = purchases
            self.readValue = readValue
            self.totalCost = totalCost
        }
    }

    /// Guard: subset search is exact and exponential in CLAIMED pockets.
    public static let maxClaimedPockets = 20

    public enum LayoutError: Error { case tooManyClaimedPockets(Int) }

    /// Validating front door for a `(cost, minTier)` pair, for callers (the
    /// daemon's BUDGET OPEN) that must never precondition-trap on bad input.
    /// nil iff: `cost` is rectangular, every entry is finite, `cost.count`
    /// is within `maxClaimedPockets`, and every `minTier` entry is a valid
    /// column index (< tier count).
    public static func validationError(cost: [[Double]], minTier: [Int]) -> String? {
        guard cost.count <= maxClaimedPockets else {
            return "pocket count \(cost.count) exceeds maxClaimedPockets \(maxClaimedPockets)"
        }
        let tierCount = cost.first?.count ?? 0
        for (i, row) in cost.enumerated() {
            guard row.count == tierCount else {
                return "row \(i) has \(row.count) tiers, expected \(tierCount) (ragged cost table)"
            }
            for (j, v) in row.enumerated() {
                guard v.isFinite else {
                    return "cost[\(i)][\(j)] is not finite"
                }
            }
        }
        for (k, m) in minTier.enumerated() {
            guard m >= 0 && m < tierCount else {
                return "minTier[\(k)]=\(m) out of range for tier count \(tierCount)"
            }
        }
        return nil
    }

    /// Validating front door for one claim against this layout's shape.
    /// nil iff `pocket` and `classIndex` are both in range.
    public func claimError(_ c: Claim) -> String? {
        guard c.pocket >= 0 && c.pocket < cost.count else {
            return "pocket \(c.pocket) out of range [0, \(cost.count))"
        }
        guard c.classIndex >= 0 && c.classIndex < minTier.count else {
            return "classIndex \(c.classIndex) out of range [0, \(minTier.count))"
        }
        return nil
    }

    /// Lay out one frame's budget over the frame's (lag-paired) claims.
    public func allocate(claims: [Claim], budget: Double) throws -> Layout {
        // Merge claims per pocket: value adds, tier = deepest requirement.
        var perPocket: [Int: (value: Int, tier: Int)] = [:]
        for c in claims {
            let need = minTier[c.classIndex]
            if let cur = perPocket[c.pocket] {
                perPocket[c.pocket] = (cur.value + 1, max(cur.tier, need))
            } else {
                perPocket[c.pocket] = (1, need)
            }
        }
        let pockets = perPocket.keys.sorted()
        guard pockets.count <= Self.maxClaimedPockets else {
            throw LayoutError.tooManyClaimedPockets(pockets.count)
        }
        let options: [(pocket: Int, value: Int, tier: Int, cost: Double)] = pockets.map {
            let m = perPocket[$0]!
            return ($0, m.value, m.tier, cost[$0][m.tier])
        }

        var best: (value: Int, cost: Double, set: [Int], buys: [Purchase])? = nil
        let n = options.count
        for mask in 0..<(1 << n) {
            var v = 0
            var cst = 0.0
            var set: [Int] = []
            var buys: [Purchase] = []
            for i in 0..<n where mask & (1 << i) != 0 {
                let o = options[i]
                v += o.value
                cst += o.cost
                set.append(o.pocket)
                buys.append(Purchase(pocket: o.pocket, tier: o.tier, cost: o.cost, readValue: o.value))
            }
            guard cst <= budget else { continue }
            if let b = best {
                if v < b.value { continue }
                if v == b.value {
                    if cst > b.cost { continue }
                    // residual tie: lexicographically smallest sorted pocket set
                    if cst == b.cost && !Self.lexSmaller(set, than: b.set) { continue }
                }
            }
            best = (v, cst, set, buys)
        }
        let b = best ?? (0, 0.0, [], [])
        return Layout(purchases: b.buys, readValue: b.value, totalCost: b.cost)
    }

    private static func lexSmaller(_ a: [Int], than b: [Int]) -> Bool {
        for (x, y) in zip(a, b) {
            if x != y { return x < y }
        }
        return a.count < b.count
    }
}
