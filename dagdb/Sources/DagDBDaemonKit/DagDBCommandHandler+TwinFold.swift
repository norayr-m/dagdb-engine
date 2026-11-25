/// FOLD verb family. A
/// pure computation over the daemon's CURRENT lanes (neighbors, edge
/// weights, nodeValue-as-leak, rank): `LadderFold.Object(engine:grid:)`
/// reads the fabric, `LadderFold.run` folds it, and the handler keeps only
/// the last `LadderFold.Result` (`lastFold`) — nothing is minted, nothing
/// is persisted, no WAL, no registry entry. Every FOLD verb is read-only,
/// RUN included ("Reader sessions may run every FOLD verb").
///
/// FOLD RUN's shm-fits guard runs BEFORE `LadderFold.run` — the kept-set
/// size is predicted by replaying just the active-set bookkeeping of the
/// library's fold loop (`rank[node] < current`, level by level), which is
/// O(n · levels) and does none of the O(k³) LAPACK work. That prediction is
/// exact (same filter, same order) for any rank lane, including one where
/// some node's rank exceeds `maxRank` — such nodes never enter `keep` in
/// the real loop either, so they're excluded here too.
import Foundation
import DagDB

extension DagDBCommandHandler {

    /// Mirrors `LadderFold.run`'s `while current > keepRank { keep =
    /// active.filter { rank[$0] < current } }` bookkeeping without the
    /// per-fold LAPACK solves, to learn the final kept-set size (`k`) cheaply
    /// enough to size-check shm before committing to the real fold.
    private func foldProjectedKeptCount(rank: [Int], maxRank: Int, keepRank: Int) -> Int {
        var active = Array(rank.indices)
        var current = maxRank
        while current > keepRank {
            active = active.filter { rank[$0] < current }
            current -= 1
        }
        return active.count
    }

    /// The library's work in ns, walked ring by
    /// ring from maxRank down exactly as `LadderFold.run` folds (ring = rank ==
    /// current, keep = rank < current; it refuses at the first empty ring, so the
    /// walk stops there): a·N² for the dense operator; per fold a·m² (the block
    /// fill over the active set m = ka + kb) + b·ka²·kb (the scalar Schur loop) +
    /// c·kb³ (dgesv); per tier recorded (a CHECK level, and keepRank: "final")
    /// a·k² + 3·c·k³ (the Double lift and three solves). Called only when
    /// `LadderFold.violation` is nil (no rank above maxRank).
    func foldWorkNs(rank: [Int], maxRank: Int, keepRank: Int, checkpoints: [Int]) -> AdmitCount {
        let a = Self.alloc1aFoldFillNs, b = Self.alloc1aFoldSchurNs, c = Self.alloc1aFoldSolveNs
        var count: [Int: Int] = [:]
        for r in rank where r > keepRank { count[r, default: 0] += 1 }
        let tiers = Set(checkpoints)
        let n = Double(rank.count)
        var ns = a * n * n
        var active = rank.count
        var current = maxRank
        while current > keepRank {
            let kb = count[current] ?? 0
            if kb == 0 { break }
            let m = Double(active), B = Double(kb), K = Double(active - kb)
            ns += a * m * m + b * K * K * B + c * B * B * B
            active -= kb
            current -= 1
            if tiers.contains(current) || current == keepRank { ns += a * K * K + 3 * c * K * K * K }
        }
        return Self.nsCount(ns)
    }

    /// `result.tiers` keys sorted "as the runner orders them": numeric
    /// descending (the order checkpoints are actually hit, since `current`
    /// only decreases), then "final" last.
    private func foldSortedTierKeys(_ tiers: [String: LadderFold.Tier]) -> [String] {
        tiers.keys.sorted { a, b in
            if a == "final" { return false }
            if b == "final" { return true }
            return Int(a)! > Int(b)!
        }
    }

    func handleTwinFold(_ cmd: TwinCommand, sessionId: String?) -> String {
        switch cmd {

        case .foldRun(let maxRank, let keepRank, let f1, let f2, let f3, let checkpoints):
            guard keepRank >= 0 else {
                return "ERROR out_of_range: keepRank \(keepRank) must be >= 0"
            }
            guard maxRank > keepRank else {
                return "ERROR out_of_range: maxRank \(maxRank) must be > keepRank \(keepRank)"
            }
            guard f1 >= 0 && f1 < nodeCount else {
                return "ERROR out_of_range: f1 \(f1) not in [0, \(nodeCount))"
            }
            guard f2 >= 0 && f2 < nodeCount else {
                return "ERROR out_of_range: f2 \(f2) not in [0, \(nodeCount))"
            }
            guard f3 == -1 || (f3 >= 0 && f3 < nodeCount) else {
                return "ERROR out_of_range: f3 \(f3) not in [0, \(nodeCount)) or -1"
            }
            guard checkpoints.allSatisfy({ $0 > keepRank && $0 < maxRank }) else {
                return "ERROR out_of_range: checkpoint levels must be strictly between keepRank \(keepRank) and maxRank \(maxRank)"
            }

            // The projection's loop, (maxRank - keepRank) x N filter steps.
            if let e = admit("FOLD RUN", bytes: AdmitCount(8 + Self.alloc1aFoldObjectPerNode) * AdmitCount(nodeCount),
                             what: "the projection's active list and LadderFold.Object, (8 + 168)*N",
                             work: [AdmitWork(units: "filter steps ((maxRank - keepRank) x N)",
                                              needed: AdmitCount(maxRank - keepRank) * AdmitCount(nodeCount),
                                              cap: Self.alloc1aFoldFilterStepCap)]) { return e }

            let object = LadderFold.Object(engine: engine, grid: grid)

            // Predict k before doing any O(k^3) work, per the file header.
            let projectedKept = foldProjectedKeptCount(rank: object.rank, maxRank: maxRank, keepRank: keepRank)
            // A checked product; only nodeCount held it.
            guard let projectedBytes = checkedProduct(projectedKept, projectedKept, 4).flatMap({ checkedSum(8, $0) }) else {
                return "ERROR out_of_range: FOLD RUN result bytes 8 + k*k*4 (k=\(projectedKept)) overflow Int;"
                    + " nothing written"
            }
            guard projectedBytes <= shmCapacityBytes else {
                return "ERROR out_of_range: FOLD RUN result \(projectedBytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }

            let schedule = LadderFold.Schedule(maxRank: maxRank, keepRank: keepRank, checkpoints: checkpoints)
            let sources = LadderFold.Sources(f1: f1, f2: f2, f3: f3)
            // The library's dense operator over all N and its folds. A run
            // the library refuses at its own argument check allocates nothing; it is not charged.
            if LadderFold.violation(object: object, schedule: schedule, sources: sources) == nil {
                // The peak from the allocations live at it, CHECK's tier buffers included.
                let n = AdmitCount(object.nodeCount)
                let coef = checkpoints.isEmpty ? Self.alloc1aFoldPeakPerN2 : Self.alloc1aFoldPeakPerN2Check
                if let e = admit("FOLD RUN", bytes: AdmitCount(coef) * n * n + AdmitCount(Self.alloc1aFoldObjectPerNode) * n,
                                 what: checkpoints.isEmpty ? "the dense operator and a fold's blocks, \(coef)*N^2 + 168*N"
                                                           : "the dense operator, a fold's blocks and a CHECK tier, \(coef)*N^2 + 168*N",
                                 work: [AdmitWork(units: "fold work ns (a*N^2 + per fold a*m^2 + b*ka^2*kb + c*kb^3 + per tier a*k^2 + 3*c*k^3)",
                                                  needed: foldWorkNs(rank: object.rank, maxRank: maxRank,
                                                                     keepRank: keepRank, checkpoints: checkpoints),
                                                  cap: Self.alloc1aFoldWorkCapNs)]) { return e }
            }
            // The throwing door. `run` reports a refusal as an
            // empty result plus a stderr line, which this handler printed as
            // `OK FOLD RUN kept=0`; `runChecked` throws instead, so the
            // refusal reaches the wire and no empty result is left behind in
            // `lastFold` for FOLD KEPT/SOURCE/TIER to read.
            let result: LadderFold.Result
            do {
                result = try LadderFold.runChecked(object: object, schedule: schedule, sources: sources)
            } catch let e as LadderFold.FoldError {
                guard case .refused(let why) = e else { return Reply.errorLine("bad_value", verb: "FOLD RUN refused", e) }
                return "ERROR bad_value: FOLD RUN refused: \(why)"
            } catch {
                return Reply.errorLine("bad_value", verb: "FOLD RUN refused", error)
            }
            lastFold = result

            if let e = writeFloatVector(result.finalOperator) { return e }
            return twinResponse(
                "FOLD RUN", sessionId: sessionId,
                "kept=\(result.keptCount) folds=\(result.log.count) bytes=\(result.finalBytes) wall_ms=\(result.totalWallMs)"
            )

        case .foldKept:
            guard let result = lastFold else { return "ERROR not_found: no fold result yet" }
            if let e = writeU64Vector(result.keptNodes.map { UInt64($0) }) { return e }
            return twinResponse("FOLD KEPT", sessionId: sessionId, "kept=\(result.keptCount)")

        case .foldSource(let which):
            guard let result = lastFold else { return "ERROR not_found: no fold result yet" }
            let vec: [Float]
            switch which {
            case 1: vec = result.foldedF1
            case 2: vec = result.foldedF2
            default: vec = result.foldedF3   // no f3 ⇒ the library holds it as a vector of zeros.
            }
            if let e = writeFloatVector(vec) { return e }
            return twinResponse("FOLD SOURCE", sessionId: sessionId, "which=\(which) kept=\(result.keptCount)")

        case .foldTier(let level, let which):
            guard let result = lastFold else { return "ERROR not_found: no fold result yet" }
            guard let tier = result.tiers[level] else {
                return "ERROR not_found: no checkpoint \(Reply.quoted(level))"
            }
            let vec: [Double]
            switch which {
            case 1: vec = tier.f1
            case 2: vec = tier.f2
            default:
                guard let f3 = tier.f3 else {
                    return "ERROR not_found: FOLD RUN was called without f3"
                }
                vec = f3
            }
            if let e = writeDoubleVector(vec) { return e }
            return twinResponse("FOLD TIER", sessionId: sessionId, "level=\(level) which=\(which) count=\(vec.count)")

        case .foldInfo:
            guard let result = lastFold else { return "ERROR not_found: no fold result yet" }
            let tiersStr = foldSortedTierKeys(result.tiers).joined(separator: ",")
            return twinResponse(
                "FOLD INFO", sessionId: sessionId,
                "kept=\(result.keptCount) folds=\(result.log.count) tiers=\(tiersStr) bytes=\(result.finalBytes) wall_ms=\(result.totalWallMs)"
            )

        default:
            // Every case this family handler is dispatched (see handleTwin
            // in DagDBCommandHandler+Twin.swift) is covered above; this
            // branch exists only for switch exhaustiveness.
            return "ERROR unknown_command: twin verb not wired yet"
        }
    }
}
