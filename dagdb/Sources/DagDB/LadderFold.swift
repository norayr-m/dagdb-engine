import Foundation
import Accelerate

/// LadderFold — the E3 tier ladder (Kron/Schur fold of a rank ring into the
/// kept set) promoted from the sealed runner (`E3Ladder/main.swift`, last
/// arithmetic change 2026-08-26) to a library call, per
/// docs/contracts/FOLD_API_GATES_FROZEN.md.
///
/// CONTROL / RE-DERIVATION: every loop, LAPACK call, Float32 store point,
/// `Date()` timing point and checkpoint name below is moved verbatim from
/// `Ladder.run` / `Ladder.init` — the arithmetic is moved, never rewritten.
/// Renamed only what the new shape requires (`self.n` -> `object.nodeCount`,
/// `f1Node` -> `sources.f1`, etc).
public enum LadderFold {

    /// Audit C findings 36-39. `run` and `Object.init(engine:grid:)` are
    /// NON-throwing public entry points called from outside this file set,
    /// so the refusal travels two ways: as an appended `refusal` field on
    /// `Object`/`Result` together with a named `ERROR ladder_fold:` line on
    /// stderr (the contract's general letter allows exactly that in place
    /// of a throw), and as this thrown, typed error from `runChecked`, the
    /// door a library caller who wants a throw uses.
    public enum FoldError: Error, Equatable, CustomStringConvertible {
        case refused(String)
        public var description: String {
            switch self { case .refused(let m): return "LadderFold: \(m)" }
        }
    }

    private static func reportRefusal(_ message: String) {
        FileHandle.standardError.write(Data("ERROR ladder_fold: \(message)\n".utf8))
    }

    // MARK: - LCG (moved verbatim from E3Ladder/main.swift)

    static let LCG_A: UInt64 = 1103515245, LCG_C: UInt64 = 12345, LCG_M: UInt64 = 2147483648

    struct LCG {
        var s: UInt64
        init(_ seed: UInt64) { s = seed }
        mutating func unit() -> Double { s = (LCG_A &* s &+ LCG_C) % LCG_M; return Double(s) / Double(LCG_M) }
    }

    // MARK: - Dense symmetric solve (moved verbatim from E3Ladder/main.swift)

    /// Library code fed by the engine's own lanes (written by
    /// `Objects.control`/`Objects.court`, never by daemon/user input) — the
    /// `precondition` on INFO is unchanged from the sealed runner, which
    /// relied on the same guarantee (a well-posed symmetric system built
    /// from the frozen court objects).
    /// Audit C finding 38: the `precondition(INFO == 0)` here ABORTED the
    /// process, and `run(object:schedule:sources:)` is public — a
    /// caller-built `Object` with a singular operator could reach it, not
    /// only the frozen court objects the header assumed. `nil` on a LAPACK
    /// failure; the caller turns it into a named refusal.
    static func solveSym(_ a: [Double], n: Int, rhs: [Double], nrhs: Int) -> (values: [Double], info: Int32) {
        var A = a  // column-major == row-major for symmetric
        var B = rhs
        var N = __CLPK_integer(n), NRHS = __CLPK_integer(nrhs)
        var LDA = N, LDB = N, INFO: __CLPK_integer = 0
        var ipiv = [__CLPK_integer](repeating: 0, count: n)
        dgesv_(&N, &NRHS, &A, &LDA, &ipiv, &B, &LDB, &INFO)
        return (B, Int32(INFO))
    }

    // MARK: - Object

    public struct Object {
        public let nodeCount: Int
        public let adjacency: [[(j: Int, w: Double)]]
        public let rank: [Int]
        public let leak: Double
        /// Appended field, audit C finding 39: non-nil iff reading the
        /// engine's lanes produced a value this type cannot hold (a rank
        /// above `Int.max` in the UInt64 rank lane). `run` refuses such an
        /// object instead of folding a silently-wrong rank vector.
        public let refusal: String?

        public init(nodeCount: Int, adjacency: [[(j: Int, w: Double)]], rank: [Int], leak: Double,
                    refusal: String? = nil) {
            self.nodeCount = nodeCount
            self.adjacency = adjacency
            self.rank = rank
            self.leak = leak
            self.refusal = refusal
        }

        /// Reads neighborsBuf / edgeWeightsBuf / rankBuf / nodeValueBuf back
        /// exactly as `Ladder.init` read them, via grid.mortonRank — leak =
        /// nodeValue of row-major node 0, as the runner used one leak for
        /// all. Expects the ranks / leak / weights to already be written
        /// into the engine's lanes (by `Objects.control` / `Objects.court`).
        public init(engine: DagDBEngine, grid: HexGrid) {
            let n = grid.nodeCount
            var mo = [Int](repeating: 0, count: n)
            for i in 0..<n { mo[i] = Int(grid.mortonRank[i]) }
            var ro = [Int](repeating: 0, count: n)
            for i in 0..<n { ro[mo[i]] = i }

            let nb = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
            let w = engine.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
            let adj: [[(j: Int, w: Double)]] = (0..<n).map { i in
                let m = mo[i]
                var row: [(Int, Double)] = []
                for d in 0..<6 {
                    let jm = nb[m * 6 + d]
                    if jm >= 0 { row.append((ro[Int(jm)], Double(w[m * 6 + d]))) }
                }
                return row
            }
            // Audit C finding 39: `Int(rkBack[...])` TRAPPED for any rank
            // above `Int.max` — in a PUBLIC initializer reading a lane the
            // caller controls. The conversion is exact-or-refuse now; the
            // refusal names the node and the raw value and travels with the
            // object into `run`.
            let rkBack = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
            var rankOut = [Int](repeating: 0, count: n)
            var rankRefusal: String? = nil
            for i in 0..<n {
                let raw = rkBack[mo[i]]
                if let exact = Int(exactly: raw) {
                    rankOut[i] = exact
                } else if rankRefusal == nil {
                    rankRefusal = "node \(i) carries rank \(raw) in the engine's UInt64 rank lane, "
                        + "above the Int.max (\(Int.max)) this fold can represent"
                }
            }
            let nv = engine.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)
            let leakOut = n > 0 ? Double(nv[mo[0]]) : 0

            if let rankRefusal = rankRefusal { LadderFold.reportRefusal(rankRefusal) }
            self.nodeCount = n
            self.adjacency = adj
            self.rank = rankOut
            self.leak = leakOut
            self.refusal = rankRefusal
        }
    }

    // MARK: - Schedule / Sources

    public struct Schedule: Equatable {
        public let maxRank: Int
        public let keepRank: Int
        public let checkpoints: [Int]
        public init(maxRank: Int, keepRank: Int, checkpoints: [Int]) {
            self.maxRank = maxRank
            self.keepRank = keepRank
            self.checkpoints = checkpoints
        }
    }

    public struct Sources: Equatable {
        public let f1: Int
        public let f2: Int
        public let f3: Int
        public init(f1: Int, f2: Int, f3: Int = -1) {
            self.f1 = f1
            self.f2 = f2
            self.f3 = f3
        }
    }

    // MARK: - Tier / Step / Result

    public struct Tier: Equatable {
        public let kept: [Int]
        public let f1: [Double]
        public let f2: [Double]
        public let f3: [Double]?
        public let bytes: Int
        public init(kept: [Int], f1: [Double], f2: [Double], f3: [Double]?, bytes: Int) {
            self.kept = kept
            self.f1 = f1
            self.f2 = f2
            self.f3 = f3
            self.bytes = bytes
        }
    }

    public struct Step: Equatable {
        public let fold: Int
        public let ring: Int
        public let eliminated: Int
        public let kept: Int
        public let wallMs: Double
        public init(fold: Int, ring: Int, eliminated: Int, kept: Int, wallMs: Double) {
            self.fold = fold
            self.ring = ring
            self.eliminated = eliminated
            self.kept = kept
            self.wallMs = wallMs
        }
    }

    public struct Result {
        public let keptNodes: [Int]
        public let finalOperator: [Float]        // k×k row-major, the Float32 the fabric stores
        public let foldedF1: [Float]
        public let foldedF2: [Float]
        public let foldedF3: [Float]
        public let tiers: [String: Tier]         // keys "19","15","11","7","final" exactly as the runner names them
        public let log: [Step]
        /// Appended field, audit C findings 36-39: non-nil iff `run`
        /// REFUSED — an object above its schedule, an out-of-range source
        /// index, a rank the fold cannot represent, or a singular operator.
        /// Every other field is then empty; `runChecked` throws instead.
        public let refusal: String?

        public init(keptNodes: [Int], finalOperator: [Float], foldedF1: [Float], foldedF2: [Float],
                    foldedF3: [Float], tiers: [String: Tier], log: [Step], refusal: String? = nil) {
            self.keptNodes = keptNodes
            self.finalOperator = finalOperator
            self.foldedF1 = foldedF1
            self.foldedF2 = foldedF2
            self.foldedF3 = foldedF3
            self.tiers = tiers
            self.log = log
            self.refusal = refusal
        }

        public var keptCount: Int { keptNodes.count }
        public var finalBytes: Int { keptNodes.count * keptNodes.count * 4 }

        /// Audit C finding 40: `finalBytes` and `Tier.bytes` are FORMULAS
        /// (k²·4, k²·4 + k·3·4) and nothing ever measured them against
        /// bytes actually written — so any test restating the formula is a
        /// check that cannot fail. These two hand back the real payloads
        /// the price table prices, so the gate can stat a file instead.
        ///
        /// The final operator, row-major Float32 — exactly what the fabric
        /// stores and what `finalBytes` claims to cost.
        public func serializedFinalOperator() -> Data {
            var out = Data(capacity: finalOperator.count * 4)
            for v in finalOperator {
                var bits = v.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
            }
            return out
        }

        /// A tier's three folded source vectors as Float32 — the `k·3·4`
        /// half of `Tier.bytes`. `nil` for an unknown tier name. A tier
        /// without an f3 still prices three vectors (the runner's own
        /// formula), so the absent one is serialized as zeros.
        public func serializedTierSources(_ name: String) -> Data? {
            guard let tier = tiers[name] else { return nil }
            let k = tier.kept.count
            var out = Data(capacity: k * 3 * 4)
            func append(_ values: [Double]) {
                for i in 0..<k {
                    var bits = Float(i < values.count ? values[i] : 0).bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
                }
            }
            append(tier.f1)
            append(tier.f2)
            append(tier.f3 ?? [])
            return out
        }
        public var totalWallMs: Double { log.reduce(0) { $0 + $1.wallMs } }
        /// The price list, printed (contract F5): one line per fold
        /// (ring, eliminated, kept, wall ms) and one per tier (kept k,
        /// bytes = k²·4 + k·3·4), then the total. Never gated.
        public func priceTable() -> String {
            var lines: [String] = ["fold  ring  eliminated  kept  wall_ms"]
            for st in log {
                lines.append(String(format: "%4d  %4d  %10d  %4d  %9.3f", st.fold, st.ring, st.eliminated, st.kept, st.wallMs))
            }
            let order = tiers.keys.sorted { a, b in
                if a == "final" { return false }; if b == "final" { return true }
                return (Int(a) ?? 0) > (Int(b) ?? 0)
            }
            lines.append("tier  kept  bytes")
            for key in order { if let t = tiers[key] { lines.append(String(format: "%5@  %4d  %8d", key as NSString, t.kept.count, t.bytes)) } }
            lines.append(String(format: "total: %d folds, %.3f ms, final operator %d bytes", log.count, totalWallMs, finalBytes))
            return lines.joined(separator: "\n")
        }

        /// The runner's exact JSON dictionary: keys kept_nodes, final_operator
        /// ([[Float]] rows), fold_log, tier_answers (kept/f1/f2/[f3] as
        /// [Double]), tier_bytes, folded_f1_final, folded_f2_final (as
        /// [Double]) — same types the runner passed to JSONSerialization.
        public func jsonDictionary() -> [String: Any] {
            let k = keptNodes.count
            let finalOp: [[Float]] = (0..<k).map { r in (0..<k).map { c in finalOperator[r * k + c] } }

            var tierAnswers: [String: Any] = [:]
            var tierBytes: [String: Any] = [:]
            for (name, t) in tiers {
                var entry: [String: Any] = ["kept": t.kept, "f1": t.f1, "f2": t.f2]
                if let f3 = t.f3 { entry["f3"] = f3 }
                tierAnswers[name] = entry
                tierBytes[name] = t.bytes
            }

            let foldLog: [[String: Any]] = log.map { s in
                ["fold": s.fold, "ring": s.ring, "eliminated": s.eliminated,
                 "kept": s.kept, "wall_ms": s.wallMs]
            }

            return ["kept_nodes": keptNodes, "final_operator": finalOp,
                    "fold_log": foldLog, "tier_answers": tierAnswers,
                    "tier_bytes": tierBytes,
                    "folded_f1_final": foldedF1.map { Double($0) },
                    "folded_f2_final": foldedF2.map { Double($0) }]
        }
    }

    // MARK: - run (moved verbatim from Ladder.run)

    /// Audit C findings 36, 37, 39 — the front door. nil iff `run` can fold
    /// this object under this schedule from these sources; otherwise a
    /// message naming the value and the true extent.
    ///
    /// Finding 36 is the "bound below the graph" shape in the fold: the
    /// loop is bounded by `schedule.maxRank`, but a node whose rank EXCEEDS
    /// it is in neither `ring` (rank == current) nor `keep` (rank <
    /// current), so `active = keep` DROPPED it at the first fold together
    /// with its row and column of the operator — silently. Both frozen
    /// schedules sit exactly AT the bound, with zero headroom: the control
    /// object (side 12) reaches rank 6 against `controlSchedule.maxRank`
    /// 6, and the court object (side 44) reaches rank 22 against
    /// `courtSchedule.maxRank` 22. That is a fact, printed by
    /// `scheduleHeadroom`, not a margin.
    public static func violation(object: Object, schedule: Schedule, sources: Sources) -> String? {
        if let refusal = object.refusal { return refusal }
        let n = object.nodeCount
        if n <= 0 { return "object holds \(n) nodes; the fold needs at least 1" }
        if object.adjacency.count != n {
            return "object holds \(n) nodes but \(object.adjacency.count) adjacency rows"
        }
        if object.rank.count != n {
            return "object holds \(n) nodes but \(object.rank.count) ranks"
        }
        if schedule.keepRank < 0 { return "keepRank \(schedule.keepRank) must be >= 0" }
        if schedule.maxRank <= schedule.keepRank {
            return "maxRank \(schedule.maxRank) must be > keepRank \(schedule.keepRank)"
        }
        // Finding 36.
        let objectMax = object.rank.max() ?? 0
        if objectMax > schedule.maxRank {
            let above = object.rank.filter { $0 > schedule.maxRank }.count
            return "schedule.maxRank \(schedule.maxRank) is below the object's own highest rank "
                + "\(objectMax): \(above) node(s) sit above the schedule and would be dropped at "
                + "the first fold, with their rows and columns of the operator"
        }
        // Finding 37: only `f3` was guarded, and only against negatives.
        for (label, idx) in [("f1", sources.f1), ("f2", sources.f2)] {
            if idx < 0 || idx >= n {
                return "source \(label) index \(idx) not in [0, \(n))"
            }
        }
        if sources.f3 != -1 && (sources.f3 < 0 || sources.f3 >= n) {
            return "source f3 index \(sources.f3) not in [0, \(n)) or -1"
        }
        return nil
    }

    /// `(object's own highest rank, schedule.maxRank)` — the fact finding
    /// 36 asks be printed rather than assumed: both frozen pairings sit
    /// exactly at the bound (headroom 0).
    public static func scheduleHeadroom(object: Object, schedule: Schedule) -> (objectMaxRank: Int, scheduleMaxRank: Int, headroom: Int) {
        let objectMax = object.rank.max() ?? 0
        return (objectMax, schedule.maxRank, schedule.maxRank - objectMax)
    }

    /// Findings 36-39's throwing door: the fold or a typed refusal, never a
    /// dropped ring, a trap, or a process abort.
    public static func runChecked(object: Object, schedule: Schedule, sources: Sources) throws -> Result {
        let result = run(object: object, schedule: schedule, sources: sources)
        if let refusal = result.refusal { throw FoldError.refused(refusal) }
        return result
    }

    private static func refusedResult(_ message: String) -> Result {
        reportRefusal(message)
        return Result(keptNodes: [], finalOperator: [], foldedF1: [], foldedF2: [], foldedF3: [],
                      tiers: [:], log: [], refusal: message)
    }

    public static func run(object: Object, schedule: Schedule, sources: Sources) -> Result {
        if let violation = violation(object: object, schedule: schedule, sources: sources) {
            return refusedResult(violation)
        }
        let n = object.nodeCount
        let adj = object.adjacency
        let rank = object.rank
        let leak = object.leak
        let f1Node = sources.f1, f2Node = sources.f2, f3Node = sources.f3
        let maxRank = schedule.maxRank, keepRank = schedule.keepRank, checkpoints = schedule.checkpoints

        // Active set ordered ascending row-major.
        var active = Array(0..<n)
        // Operator entries (stored as Float32 between folds; Float64 inside a fold).
        // Represent as dense [Float] over active set.
        var op: [Float] = {
            var A = [Double](repeating: 0, count: n * n)
            for i in 0..<n {
                A[i * n + i] = leak
                for (j, w) in adj[i] { A[i * n + i] += w; A[i * n + j] -= w }
            }
            return A.map { Float($0) }
        }()
        var f1 = [Float](repeating: 0, count: n); f1[f1Node] = 1.0
        var f2 = [Float](repeating: 0, count: n); f2[f2Node] = 1.0
        var f3 = [Float](repeating: 0, count: n); if f3Node >= 0 { f3[f3Node] = 1.0 }

        var foldLog: [Step] = []
        var tiers: [String: Tier] = [:]

        func checkpointName(_ level: Int) -> String { level == keepRank ? "final" : String(level) }

        var tierRefusal: String? = nil
        func recordTier(_ level: Int, activeSet: [Int], opF: [Float],
                        f1F: [Float], f2F: [Float], f3F: [Float]) {
            let k = activeSet.count
            let A = opF.map { Double($0) }
            // Finding 38: a singular tier operator used to abort the
            // process here; it is a named refusal now.
            let r1 = solveSym(A, n: k, rhs: f1F.map { Double($0) }, nrhs: 1)
            let r2 = solveSym(A, n: k, rhs: f2F.map { Double($0) }, nrhs: 1)
            var x3: [Double]? = nil
            var info3: Int32 = 0
            if f3Node >= 0 {
                let r3 = solveSym(A, n: k, rhs: f3F.map { Double($0) }, nrhs: 1)
                x3 = r3.values
                info3 = r3.info
            }
            if r1.info != 0 || r2.info != 0 || info3 != 0 {
                if tierRefusal == nil {
                    let info = r1.info != 0 ? r1.info : (r2.info != 0 ? r2.info : info3)
                    tierRefusal = "tier '\(checkpointName(level))' operator is singular: dgesv "
                        + "returned info=\(info) over a \(k)x\(k) system"
                }
                return
            }
            tiers[checkpointName(level)] = Tier(kept: activeSet, f1: r1.values, f2: r2.values, f3: x3,
                                                 bytes: k * k * 4 + k * 3 * 4)
        }

        var current = maxRank
        while current > keepRank {
            let ring = active.filter { rank[$0] == current }
            let keep = active.filter { rank[$0] < current }
            let t0 = Date()
            let kb = ring.count, ka = keep.count
            // Build blocks from the Float32-stored operator, lift to Double.
            let idxOfActive = { () -> [Int: Int] in
                var d = [Int: Int](); for (p, node) in active.enumerated() { d[node] = p }; return d
            }()
            var ABB = [Double](repeating: 0, count: kb * kb)
            var ABA = [Double](repeating: 0, count: kb * ka)  // rows=B, cols=A
            var AAA = [Double](repeating: 0, count: ka * ka)
            let m = active.count
            for (bi, nodeB) in ring.enumerated() {
                let pb = idxOfActive[nodeB]!
                for (bj, nodeB2) in ring.enumerated() {
                    ABB[bi * kb + bj] = Double(op[pb * m + idxOfActive[nodeB2]!])
                }
                for (ai, nodeA) in keep.enumerated() {
                    ABA[bi * ka + ai] = Double(op[pb * m + idxOfActive[nodeA]!])
                }
            }
            for (ai, nodeA) in keep.enumerated() {
                let pa = idxOfActive[nodeA]!
                for (aj, nodeA2) in keep.enumerated() {
                    AAA[ai * ka + aj] = Double(op[pa * m + idxOfActive[nodeA2]!])
                }
            }
            let fB1 = ring.map { node in Double(f1[idxOfActive[node]!]) }
            let fB2 = ring.map { node in Double(f2[idxOfActive[node]!]) }
            let fB3 = ring.map { node in Double(f3[idxOfActive[node]!]) }
            let fA1 = keep.map { node in Double(f1[idxOfActive[node]!]) }
            let fA2 = keep.map { node in Double(f2[idxOfActive[node]!]) }
            let fA3 = keep.map { node in Double(f3[idxOfActive[node]!]) }

            // X = ABB^{-1} [ABA | fB1 | fB2]
            var rhs = [Double](repeating: 0, count: kb * (ka + 3))
            for bi in 0..<kb {
                for ai in 0..<ka { rhs[bi * (ka + 3) + ai] = ABA[bi * ka + ai] }
                rhs[bi * (ka + 3) + ka] = fB1[bi]
                rhs[bi * (ka + 3) + ka + 1] = fB2[bi]
                rhs[bi * (ka + 3) + ka + 2] = fB3[bi]
            }
            // LAPACK is column-major; our arrays are row-major. For symmetric
            // ABB it's fine; rhs needs transpose handling: build column-major.
            var Acm = [Double](repeating: 0, count: kb * kb)
            for r in 0..<kb { for c in 0..<kb { Acm[c * kb + r] = ABB[r * kb + c] } }
            var Bcm = [Double](repeating: 0, count: kb * (ka + 3))
            for r in 0..<kb { for c in 0..<(ka + 3) { Bcm[c * kb + r] = rhs[r * (ka + 3) + c] } }
            var N32 = __CLPK_integer(kb), NRHS32 = __CLPK_integer(ka + 3)
            var LDA32 = N32, LDB32 = N32, INFO: __CLPK_integer = 0
            var ipiv = [__CLPK_integer](repeating: 0, count: kb)
            dgesv_(&N32, &NRHS32, &Acm, &LDA32, &ipiv, &Bcm, &LDB32, &INFO)
            // Finding 38: a singular ring block aborted the process here.
            guard INFO == 0 else {
                return refusedResult(
                    "fold at ring \(current) is singular: dgesv returned info=\(INFO) over a "
                    + "\(kb)x\(kb) system (\(ka) node(s) kept)")
            }
            // Schur: AAA -= ABA^T * X ; folded f similarly.
            var newOp = [Double](repeating: 0, count: ka * ka)
            for ai in 0..<ka {
                for aj in 0..<ka {
                    var s = AAA[ai * ka + aj]
                    for bi in 0..<kb {
                        s -= ABA[bi * ka + ai] * Bcm[aj * kb + bi]
                    }
                    newOp[ai * ka + aj] = s
                }
            }
            var newF1 = [Double](repeating: 0, count: ka)
            var newF2 = [Double](repeating: 0, count: ka)
            var newF3 = [Double](repeating: 0, count: ka)
            for ai in 0..<ka {
                var s1 = fA1[ai], s2 = fA2[ai], s3 = fA3[ai]
                for bi in 0..<kb {
                    s1 -= ABA[bi * ka + ai] * Bcm[ka * kb + bi]
                    s2 -= ABA[bi * ka + ai] * Bcm[(ka + 1) * kb + bi]
                    s3 -= ABA[bi * ka + ai] * Bcm[(ka + 2) * kb + bi]
                }
                newF1[ai] = s1; newF2[ai] = s2; newF3[ai] = s3
            }
            // STORE to Float32 (the fabric): operator and folded sources.
            op = newOp.map { Float($0) }
            var nf1 = [Float](repeating: 0, count: ka)
            var nf2 = [Float](repeating: 0, count: ka)
            var nf3 = [Float](repeating: 0, count: ka)
            for ai in 0..<ka { nf1[ai] = Float(newF1[ai]); nf2[ai] = Float(newF2[ai]); nf3[ai] = Float(newF3[ai]) }
            f1 = nf1; f2 = nf2; f3 = nf3
            active = keep
            let ms = Date().timeIntervalSince(t0) * 1000
            foldLog.append(Step(fold: foldLog.count + 1, ring: current, eliminated: kb, kept: ka, wallMs: ms))
            current -= 1
            if checkpoints.contains(current) || current == keepRank {
                recordTier(current, activeSet: active, opF: op, f1F: f1, f2F: f2, f3F: f3)
            }
        }

        if let tierRefusal = tierRefusal { return refusedResult(tierRefusal) }
        return Result(keptNodes: active, finalOperator: op,
                      foldedF1: f1, foldedF2: f2, foldedF3: f3,
                      tiers: tiers, log: foldLog)
    }

    // MARK: - Objects (frozen court objects — writer half of Ladder.init, moved verbatim)

    public enum Objects {
        static let WEIGHT_SEED: UInt64 = 20260821

        /// Control object: side 12, G1 (unit weights — the engine's default
        /// edgeWeights are already 1.0), leak 1e-2.
        public static func control(engine: DagDBEngine, grid: HexGrid) -> Object {
            build(profile: "G1", g2Seed: WEIGHT_SEED, leak: 1e-2, engine: engine, grid: grid)
        }

        /// Court object: side 44, profile "G1" | "G2" | "G1_stress" |
        /// "G2_stress" (stress ⇒ leak 1e-6).
        public static func court(profile: String, g2Seed: UInt64 = 20260821,
                                  engine: DagDBEngine, grid: HexGrid) -> Object {
            let leak = profile.hasSuffix("_stress") ? 1e-6 : 1e-2
            return build(profile: profile, g2Seed: g2Seed, leak: leak, engine: engine, grid: grid)
        }

        public static let controlSchedule = Schedule(maxRank: 6, keepRank: 3, checkpoints: [])
        public static let controlSources = Sources(f1: 6 * 12 + 6, f2: 6 * 12 + 6)
        public static let courtSchedule = Schedule(maxRank: 22, keepRank: 3, checkpoints: [19, 15, 11, 7])
        public static let courtSources = Sources(f1: 22 * 44 + 22, f2: 31 * 44 + 10, f3: 22 * 44 + 2)

        /// Writer half of `Ladder.init`, moved verbatim: ranks (Chebyshev
        /// distance from the centre) into the engine's rank lane, leak into
        /// the nodeValue lane, and — for G2 profiles — weights into the edge
        /// lane by the frozen LCG over lexicographic edges. Then reads the
        /// Object back via `Object.init(engine:grid:)`, exactly as
        /// `Ladder.init` read its own fields back from the same lanes.
        private static func build(profile: String, g2Seed: UInt64, leak: Double,
                                   engine: DagDBEngine, grid: HexGrid) -> Object {
            let side = grid.width
            let n = grid.nodeCount
            var mo = [Int](repeating: 0, count: n)
            for i in 0..<n { mo[i] = Int(grid.mortonRank[i]) }

            // Ranks into the ENGINE rank lane (fabric-resident), read back later.
            let c0 = side == 44 ? 22 : side / 2
            let rk = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
            for i in 0..<n {
                let c = i % side, r = i / side
                rk[mo[i]] = UInt64(max(abs(c - c0), abs(r - c0)))
            }
            // Leaks into the nodeValue lane (fabric-resident).
            let nv = engine.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)
            for m in 0..<n { nv[m] = Float(leak) }

            // G2 weights into the ENGINE edge lane by frozen LCG, lex edge order.
            let nb = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
            var ro = [Int](repeating: 0, count: n)
            for i in 0..<n { ro[mo[i]] = i }
            if profile.hasPrefix("G2") {
                let w = engine.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
                var edges: [(Int, Int)] = []
                for i in 0..<n {
                    let m = mo[i]
                    for d in 0..<6 {
                        let jm = nb[m * 6 + d]
                        if jm >= 0 {
                            let j = ro[Int(jm)]
                            if i < j { edges.append((i, j)) }
                        }
                    }
                }
                edges.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
                var lcg = LCG(g2Seed)
                for (i, j) in edges {
                    let cond = Float(pow(10.0, 2.0 * lcg.unit() - 1.0))
                    let mi = mo[i], mj = mo[j]
                    for d in 0..<6 where Int(nb[mi * 6 + d]) == mj { w[mi * 6 + d] = cond }
                    for d in 0..<6 where Int(nb[mj * 6 + d]) == mi { w[mj * 6 + d] = cond }
                }
            }

            return Object(engine: engine, grid: grid)
        }
    }
}
