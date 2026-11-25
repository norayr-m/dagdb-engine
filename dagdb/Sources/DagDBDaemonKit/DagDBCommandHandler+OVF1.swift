import Foundation
import DagDB

// MARK: - No wire number kills the daemon
//
// Swift's `*`, `+` and narrowing conversions
// trap on overflow, and a trap kills the daemon. Every site that did arithmetic
// or a narrowing conversion on a number taken from the wire, without a bound
// placed before it, now reports the overflow (or converts with `exactly:`) and
// is refused by name: `ERROR out_of_range: <VERB> <what> <value> …; nothing
// written` (`bad_value` for a negative rank), with nothing written and no WAL
// record. The refusals shared by the primary and the reader path live here.

extension DagDBCommandHandler {

    /// A rank is a u64. `NODES AT RANK r` compared `UInt64(r)` per node, which
    /// trapped on a negative r: refused before the loop.
    func nodesNegativeRankRefusal(_ r: Int) -> String? {
        guard r < 0 else { return nil }
        return "ERROR bad_value: NODES AT RANK \(r): a rank is never negative; nothing written"
    }

    /// `WHERE rank…` evaluates `Int(rank)`, which traps on a stored rank above
    /// Int.max (a rank that arrived by a crafted log or a snapshot;
    /// the live writers keep rank < nodeCount). Checked before the conversion,
    /// for the node the predicate is about to read: nil when the predicate does
    /// not read the rank or the rank fits Int.
    func nodesRankPredicateRefusal(_ pred: Predicate, node: Int, rank: UInt64) -> String? {
        guard pred.field == "rank", rank > UInt64(Int.max) else { return nil }
        return "ERROR out_of_range: NODES WHERE rank: node \(node) rank \(rank) exceeds Int.max \(Int.max);"
            + " nothing written"
    }

    /// The shm read helpers' bound (`readFloats`, `readDoubles`, `readU32s`):
    /// `byteOffset + count * elementSize <= shmCapacityBytes`,
    /// overflow-reporting. Every caller bounds its count first today; a new
    /// caller that did not would have trapped inside the helper, which now
    /// answers nil (the caller's own capacity refusal) instead.
    func shmReadFits(count: Int, elementSize: Int, at byteOffset: Int) -> Bool {
        guard count >= 0, byteOffset >= 0 else { return false }
        let (bytes, o1) = count.multipliedReportingOverflow(by: elementSize)
        let (end, o2) = byteOffset.addingReportingOverflow(bytes)
        return !o1 && !o2 && end <= shmCapacityBytes
    }
}
