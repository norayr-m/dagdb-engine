/// DagDBSecondaryIndex — fast `(truth, rank-range)` lookup.
///
/// Shipped 2026-04-20.
///
/// Rationale: the "all events of type X in time window Y" query pattern
/// maps onto DagDB as `NODES WHERE truth = <code> AND rank BETWEEN
/// <lo> AND <hi>`. Without an index this is an O(N) scan, which bites
/// at roughly 100 k events — earlier than the initial "defer past
/// millions" estimate.
///
/// Design: per-truth-code rank-sorted list of (rank, nodeId). Binary
/// search for the first rank ≥ lo, scan forward while rank ≤ hi.
/// Lookup cost O(log N + |matching|).
///
/// Maintenance: lazy rebuild on a dirty flag. Any mutation that can
/// change a node's (truth, rank) sets the flag. Next `select(...)`
/// rebuilds once. For read-heavy workloads (many reads per write) this
/// is far cheaper than incremental updates per mutation.
///
/// Memory: one `(UInt64, Int)` pair per node per distinct truth value
/// it carries — ≈ 16 bytes × N. For 1 M events ≈ 16 MB. Fine.
///
/// Single-threaded. Daemon accept loop is serial; no concurrent
/// mutation of the index structure itself. Under the reader-session
/// MVCC path (T7), queries against a session use the *primary's*
/// index of the moment the session opened — good enough for Pass 2,
/// can tighten later if snapshot-specific indexes become a real need.

import Foundation

public final class TruthRankIndex {

    /// `lists[truth]` is the rank-ascending list of `(rank, nodeId)` for all
    /// nodes with that truth value. Present keys are the only ones with
    /// any matching nodes.
    private var lists: [UInt8: [(rank: UInt64, node: Int)]] = [:]
    private var dirty: Bool = true

    public init() {}

    public var isDirty: Bool { dirty }

    /// Bucket counts keyed by truth code — useful for introspection.
    public var bucketSizes: [UInt8: Int] {
        var out: [UInt8: Int] = [:]
        for (k, v) in lists { out[k] = v.count }
        return out
    }

    /// Mark the index stale. Call after any mutation that can change a
    /// node's (truth, rank). Cheap — O(1).
    public func markDirty() {
        dirty = true
    }

    /// Force a full rebuild from the engine state. O(N log N): scan + sort
    /// per truth bucket.
    public func rebuild(engine: DagDBEngine, nodeCount: Int) {
        let rank  = engine.rankBuf.contents().bindMemory(
            to: UInt64.self, capacity: nodeCount)
        let truth = engine.truthStateBuf.contents().bindMemory(
            to: UInt8.self, capacity: nodeCount)

        var buckets: [UInt8: [(rank: UInt64, node: Int)]] = [:]
        for i in 0..<nodeCount {
            buckets[truth[i], default: []].append((rank[i], i))
        }
        for key in buckets.keys {
            buckets[key]!.sort { $0.rank < $1.rank }
        }
        lists = buckets
        dirty = false
    }

    /// Find all nodes with `truth = k` and `rank ∈ [lo, hi]` (inclusive).
    /// Rebuilds the index first if dirty. Results in rank-ascending order.
    public func select(
        truth: UInt8, rankLo: UInt64, rankHi: UInt64,
        engine: DagDBEngine, nodeCount: Int
    ) -> [Int] {
        if dirty { rebuild(engine: engine, nodeCount: nodeCount) }
        guard let list = lists[truth], !list.isEmpty else { return [] }
        guard rankLo <= rankHi else { return [] }

        let start = lowerBound(list, rank: rankLo)
        if start >= list.count { return [] }

        var out: [Int] = []
        var i = start
        while i < list.count && list[i].rank <= rankHi {
            out.append(list[i].node)
            i += 1
        }
        return out
    }

    /// O(log N) binary-search for the first list index whose rank ≥ target.
    /// Returns list.count if no such index exists.
    private func lowerBound(
        _ list: [(rank: UInt64, node: Int)], rank target: UInt64
    ) -> Int {
        var lo = 0
        var hi = list.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if list[mid].rank < target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}
