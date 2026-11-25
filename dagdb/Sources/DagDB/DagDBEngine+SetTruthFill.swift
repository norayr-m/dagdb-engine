/// DagDBEngine+SetTruthFill — `SET_TRUTH NODES|RANK <lo>-<hi> FILL <v>`, the
/// zero tick folded.
///
/// The truth byte of every node in the selection := v — the ids lo…hi
/// (`NODES`), or every node whose rank is in lo…hi (`RANK`), TRUTH_SLICE's and
/// SET_LUTS's selectors. Registers are written like any node: a truth write
/// outside any session, as SET TRUTH is. A value of 3 or more is refused by
/// name when the graph holds a ternary node (a ternary node holds 0..2;
/// SET_TRUTH_BULK checks per node); 0, 1, 2 are legal on every mode, so the
/// common case reads one count (`nonBinaryNodeCount`).
///
/// The dispatch, on the CPU: a `memset` of the id range (NODES); rank lo's
/// per-rank list when lo == hi and the per-rank lists exist — made current first
/// (`currentRankList`: lists a rank write left stale are rebuilt, as SET_LUTS
/// and TRUTH_SLICE rebuild them) —, a scatter through it; else one pass over
/// the rank lane.
///
/// Nothing else moves: no rank, slot, back edge, register flag or LUT — the
/// DAG verdict, the per-rank lists, the frontier index and the latch plan
/// stay valid. The caller marks the (truth, rank) index dirty (a truth write).
///
/// A client's zero phase can become `SET_TRUTH NODES V0-(V0+N−1) FILL 0` and
/// no tick: the zero tick's only persisting effect is V := 0 (the flood's
/// first tick is whole and recomputes every other node from V and the LUTs),
/// so the state after the flood's first tick is the zero-tick path's.

import Foundation

extension DagDBEngine {

    /// Why a SET_TRUTH FILL is refused: the error category and its words.
    /// `value`: the value's refusal (ternary), else the selection's.
    public struct SetTruthFillRefusal: Error, Equatable, CustomStringConvertible {
        public let category: String
        public let detail: String
        public let value: Bool
        public var description: String { "\(category): \(detail)" }
    }

    /// The verb's refusal on a graph of `nodeCount` nodes holding
    /// `nonBinaryNodes` ternary nodes, or nil: the selection first, in TRUTH_SLICE's
    /// words (lo > hi; an id past the lane), then a value ≥ 3 on a graph with a
    /// ternary node. Reads no engine state, so the daemon and WAL replay ask
    /// the same rule.
    public static func setTruthFillRefusal(_ sel: LutSelection, _ v: UInt8, nodeCount n: Int,
                                           nonBinaryNodes: Int) -> SetTruthFillRefusal? {
        switch sel {
        case let .nodes(lo, hi), let .rank(lo, hi):
            if lo > hi { return SetTruthFillRefusal(category: "out_of_range", detail: "range \(lo)-\(hi) is empty (lo > hi)", value: false) }
        }
        if case let .nodes(_, hi) = sel, hi >= UInt64(max(n, 0)) {
            return SetTruthFillRefusal(category: "out_of_range", detail: "node \(hi) not in 0..<\(n)", value: false)
        }
        if v >= 3 && nonBinaryNodes > 0 {
            return SetTruthFillRefusal(category: "bad_value",
                                       detail: "the graph has \(nonBinaryNodes) ternary node(s), which hold 0..2; "
                                         + "write a value of 3 or more per node with SET_TRUTH_BULK", value: true)
        }
        return nil
    }

    /// Runs the verb (see the file's header); throws the refusal. Returns the
    /// nodes written and the dispatch taken. `useRankLists: false` takes the
    /// rank lane for every rank selection (WAL replay: its rank writes do not
    /// mark the per-rank lists stale).
    @discardableResult
    public func setTruthFill(_ sel: LutSelection, _ v: UInt8,
                             useRankLists: Bool = true) throws -> (selected: Int, path: SetLutsPath) {
        if let r = Self.setTruthFillRefusal(sel, v, nodeCount: nodeCount, nonBinaryNodes: nonBinaryNodeCount) { throw r }
        let n = max(nodeCount, 1)
        let truth = truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        switch sel {
        case let .nodes(lo, hi):
            let count = Int(hi - lo) + 1
            memset(truth + Int(lo), Int32(v), count)
            lastSetTruthFillPath = .range
            return (count, .range)
        case let .rank(lo, hi):
            if useRankLists && lo == hi, let list = currentRankList(lo) {
                for id in list { truth[Int(id)] = v }
                lastSetTruthFillPath = .rankList
                return (list.count, .rankList)
            }
            let rank = rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
            var k = 0
            for i in 0..<nodeCount where rank[i] >= lo && rank[i] <= hi { truth[i] = v; k += 1 }
            lastSetTruthFillPath = .rankLane
            return (k, .rankLane)
        }
    }
}
