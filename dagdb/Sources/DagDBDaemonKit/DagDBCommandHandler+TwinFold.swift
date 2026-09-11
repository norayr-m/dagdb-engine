/// FOLD verb family — gate F4, docs/contracts/FOLD_API_GATES_FROZEN.md. A
/// pure computation over the daemon's CURRENT lanes (neighbors, edge
/// weights, nodeValue-as-leak, rank): `LadderFold.Object(engine:grid:)`
/// reads the fabric, `LadderFold.run` folds it, and the handler keeps only
/// the last `LadderFold.Result` (`lastFold`) — nothing is minted, nothing
/// is persisted, no WAL, no registry entry. Every FOLD verb is read-only,
/// RUN included (§F4: "Reader sessions may run every FOLD verb").
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

            let object = LadderFold.Object(engine: engine, grid: grid)

            // Predict k before doing any O(k^3) work, per the file header.
            let projectedKept = foldProjectedKeptCount(rank: object.rank, maxRank: maxRank, keepRank: keepRank)
            let projectedBytes = 8 + projectedKept * projectedKept * 4
            guard projectedBytes <= shmCapacityBytes else {
                return "ERROR out_of_range: FOLD RUN result \(projectedBytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }

            let schedule = LadderFold.Schedule(maxRank: maxRank, keepRank: keepRank, checkpoints: checkpoints)
            let sources = LadderFold.Sources(f1: f1, f2: f2, f3: f3)
            let result = LadderFold.run(object: object, schedule: schedule, sources: sources)
            lastFold = result

            writeFloatVector(result.finalOperator)
            return twinResponse(
                "FOLD RUN", sessionId: sessionId,
                "kept=\(result.keptCount) folds=\(result.log.count) bytes=\(result.finalBytes) wall_ms=\(result.totalWallMs)"
            )

        case .foldKept:
            guard let result = lastFold else { return "ERROR not_found: no fold result yet" }
            writeU64Vector(result.keptNodes.map { UInt64($0) })
            return twinResponse("FOLD KEPT", sessionId: sessionId, "kept=\(result.keptCount)")

        case .foldSource(let which):
            guard let result = lastFold else { return "ERROR not_found: no fold result yet" }
            let vec: [Float]
            switch which {
            case 1: vec = result.foldedF1
            case 2: vec = result.foldedF2
            default: vec = result.foldedF3   // no f3 ⇒ the library holds it as a vector of zeros.
            }
            writeFloatVector(vec)
            return twinResponse("FOLD SOURCE", sessionId: sessionId, "which=\(which) kept=\(result.keptCount)")

        case .foldTier(let level, let which):
            guard let result = lastFold else { return "ERROR not_found: no fold result yet" }
            guard let tier = result.tiers[level] else {
                return "ERROR not_found: no checkpoint '\(level)'"
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
            writeDoubleVector(vec)
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
