/// DagDBEngine+SetLuts — `SET_LUTS … FILL | MAP [MASK]` by selection.
///
/// A selection — the ids lo…hi (`NODES`), or every node whose rank is in
/// lo…hi (`RANK`) — and one write to its nodes' 64-bit LUTs, landing in
/// `lut6Low` / `lut6High` exactly as SET_LUTS_BULK splits a vector:
///   - FILL v: every node of the selection := v.
///   - MAP [MASK m] f₁=t₁ …: a node whose LUT ANDed with m equals f_j gets t_j.
///     A simultaneous substitution on the node's value before the verb: each
///     node is read once, before its own write, so a `to` that equals another
///     pair's `from` is never followed (no chaining). 1…16 pairs; every key
///     inside the mask (a key with a bit outside it could never be equalled by
///     a LUT ANDed with the mask — refused, so "ANDed with the mask equals
///     from" and "keys distinct after masking" are one rule); keys distinct,
///     so no node can match two pairs. MASK defaults to all ones.
///
/// One kernel (`dagdb_set_luts`, in both shader sources), one thread per node
/// of the dispatch, over: the id range (NODES); rank lo's per-rank list when lo ==
/// hi and the per-rank lists exist — made current first: a rank write since
/// the last tick has marked them stale, and they are rebuilt here, as the next
/// tick would rebuild them; or one pass over the rank lane. Every node of the
/// selection is written by exactly one thread, so the threads never conflict.
/// The kernel counts the selection and the nodes written (one atomic add per
/// SIMD group). The CPU twin (`setLutsOnCPU`) is the reference and the
/// fallback when no command buffer can be had; the bytes are the same.
///
/// Nothing else moves: no rank, slot, back edge, register flag or truth byte —
/// the DAG verdict, the per-rank lists, the frontier index, the latch plan
/// and the (truth, rank) index all stay valid.

import Metal
import Foundation

extension DagDBEngine {

    /// The nodes a SET_LUTS verb writes: ids lo…hi, or every node whose rank
    /// is in lo…hi (TRUTH_SLICE's selectors).
    public enum LutSelection: Equatable, Sendable, CustomStringConvertible {
        case nodes(UInt64, UInt64)
        case rank(UInt64, UInt64)

        public var description: String {
            switch self {
            case let .nodes(lo, hi): return "NODES \(lo)-\(hi)"
            case let .rank(lo, hi): return "RANK \(lo)-\(hi)"
            }
        }
    }

    /// One MAP pair: a node whose LUT ANDed with the mask equals `from` gets `to`.
    public struct LutPair: Equatable, Sendable {
        public let from: UInt64
        public let to: UInt64
        public init(from: UInt64, to: UInt64) { self.from = from; self.to = to }
    }

    public enum LutOp: Equatable, Sendable {
        case fill(UInt64)
        case map(mask: UInt64, pairs: [LutPair])
    }

    /// The dispatch a verb took: the id range, a rank's rank list, the rank lane.
    public enum SetLutsPath: String, Sendable { case range, rankList, rankLane }

    /// MAP's pair limit.
    public static let setLutsMaxPairs = 16

    /// Why a verb is refused: the error category and its words.
    /// `selection`: the refusal is the selection's (TRUTH_SLICE's words, no suffix).
    public struct SetLutsRefusal: Error, Equatable, CustomStringConvertible {
        public let category: String
        public let detail: String
        public let selection: Bool
        public var description: String { "\(category): \(detail)" }
    }

    public struct SetLutsResult: Equatable, Sendable {
        /// Nodes in the selection.
        public let selected: Int
        /// Nodes written (FILL: every one; MAP: those whose key matched).
        public let written: Int
        public let onGPU: Bool
        public let path: SetLutsPath
    }

    static func setLutsHex(_ v: UInt64) -> String { "0x" + String(v, radix: 16, uppercase: true) }

    /// The verb's refusal against a graph of `nodeCount` nodes, or nil. The
    /// selection first, in TRUTH_SLICE's words (lo > hi; an id past the lane); then
    /// MAP's rules: 1…16 pairs, every key inside the mask, keys distinct.
    /// Reads no engine state, so the daemon and WAL replay ask the same rule.
    public static func setLutsRefusal(_ sel: LutSelection, _ op: LutOp, nodeCount n: Int) -> SetLutsRefusal? {
        switch sel {
        case let .nodes(lo, hi), let .rank(lo, hi):
            if lo > hi { return SetLutsRefusal(category: "out_of_range", detail: "range \(lo)-\(hi) is empty (lo > hi)", selection: true) }
        }
        if case let .nodes(_, hi) = sel, hi >= UInt64(max(n, 0)) {
            return SetLutsRefusal(category: "out_of_range", detail: "node \(hi) not in 0..<\(n)", selection: true)
        }
        if case let .map(mask, pairs) = op {
            guard (1...setLutsMaxPairs).contains(pairs.count) else {
                return SetLutsRefusal(category: "out_of_range",
                                      detail: "SET_LUTS MAP pairs \(pairs.count) not in 1...\(setLutsMaxPairs)", selection: false)
            }
            for (j, p) in pairs.enumerated() where p.from & ~mask != 0 {
                return SetLutsRefusal(category: "bad_value",
                                      detail: "SET_LUTS MAP pair \(j): from \(setLutsHex(p.from)) has bits outside MASK "
                                        + "\(setLutsHex(mask)) (a LUT ANDed with the mask never equals it)", selection: false)
            }
            for j in pairs.indices {
                for i in 0..<j where pairs[i].from == pairs[j].from {
                    return SetLutsRefusal(category: "bad_value",
                                          detail: "SET_LUTS MAP pairs \(i) and \(j) have the same key \(setLutsHex(pairs[j].from)) "
                                            + "under MASK \(setLutsHex(mask)) (keys must be distinct after masking)", selection: false)
                }
            }
        }
        return nil
    }

    /// Runs the verb (see the file's header). Throws the refusal, or the
    /// command buffer's `CommandBufferFailure` (also set as `gpuFailure`)
    /// when the GPU's buffer did not complete: nothing claimed, the LUT lane
    /// may hold part of its writes.
    ///
    /// `useRankLists: false` takes the rank lane for every rank selection
    /// (WAL replay: its rank writes do not mark the lists stale).
    /// `allowGPU: false` runs the CPU twin (WAL replay).
    @discardableResult
    public func setLuts(_ sel: LutSelection, _ op: LutOp, useRankLists: Bool = true,
                        allowGPU: Bool = true) throws -> SetLutsResult {
        if let r = Self.setLutsRefusal(sel, op, nodeCount: nodeCount) { throw r }
        var path = SetLutsPath.range
        var base = 0, count = 0, listOffset = 0
        var rLo: UInt64 = 0, rHi: UInt64 = 0
        switch sel {
        case let .nodes(lo, hi):
            base = Int(lo); count = Int(hi - lo) + 1
        case let .rank(lo, hi):
            rLo = lo; rHi = hi
            var span: (offset: Int, count: Int)?
            if useRankLists && lo == hi && rankListBuf != nil {
                ensureRankTopology()      // lists a rank write left stale are rebuilt before they are read
                if lo < UInt64(rankSpanTable.count) { span = rankSpanTable[Int(lo)] }
            }
            if let s = span {
                path = .rankList; listOffset = s.offset; count = s.count
            } else {
                path = .rankLane; count = nodeCount
            }
        }
        lastSetLutsPath = path
        lastSetLutsOnGPU = false
        if count == 0 { return SetLutsResult(selected: 0, written: 0, onGPU: false, path: path) }

        let cpu = !allowGPU || (setLutsCPUForTesting.map { count >= $0 } ?? false)
        if !cpu, !commandBufferFailsForTesting(), let counter = setLutsCounter(),
           let cb = makeGPUCommandBuffer(), let enc = cb.makeComputeCommandEncoder() {
            counter.contents().storeBytes(of: UInt64(0), as: UInt64.self)
            // The kernel's parameters, one u64 each: [0] the dispatch (0 range,
            // 1 list, 2 rank lane), [1] the op (0 FILL, 1 MAP), [2] threads with
            // work, [3] the first id (range), [4] [5] the rank range, [6] FILL's
            // value, [7] MAP's mask, [8] its pair count, [9 …] the keys, [25 …]
            // the values.
            var p = [UInt64](repeating: 0, count: 9 + 2 * Self.setLutsMaxPairs)
            p[0] = path == .range ? 0 : (path == .rankList ? 1 : 2)
            p[2] = UInt64(count); p[3] = UInt64(base); p[4] = rLo; p[5] = rHi
            switch op {
            case .fill(let v):
                p[1] = 0; p[6] = v
            case let .map(mask, pairs):
                p[1] = 1; p[7] = mask; p[8] = UInt64(pairs.count)
                for (j, pr) in pairs.enumerated() { p[9 + j] = pr.from; p[9 + Self.setLutsMaxPairs + j] = pr.to }
            }
            enc.setComputePipelineState(setLutsPipeline)
            enc.setBuffer(lut6LowBuf, offset: 0, index: 0)
            enc.setBuffer(lut6HighBuf, offset: 0, index: 1)
            enc.setBuffer(rankBuf, offset: 0, index: 2)
            if path == .rankList, let list = rankListBuf {
                enc.setBuffer(list, offset: listOffset * 4, index: 3)
            } else {
                enc.setBuffer(rankBuf, offset: 0, index: 3)                  // not read
            }
            p.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 4) }
            enc.setBuffer(counter, offset: 0, index: 5)
            let tpg = setLutsPipeline.maxTotalThreadsPerThreadgroup
            enc.dispatchThreadgroups(MTLSize(width: (count + tpg - 1) / tpg, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            lastSetLutsOnGPU = true
            guard commandBufferCompleted(cb) else { throw gpuFailure! }    // a failed command buffer claims nothing
            let c = counter.contents().bindMemory(to: UInt32.self, capacity: 2)
            return SetLutsResult(selected: Int(c[0]), written: Int(c[1]), onGPU: true, path: path)
        }
        let (k, w) = setLutsOnCPU(path: path, base: base, count: count, listOffset: listOffset, rLo: rLo, rHi: rHi, op)
        return SetLutsResult(selected: k, written: w, onGPU: false, path: path)
    }

    private func setLutsCounter() -> MTLBuffer? {
        if setLutsCounterBuf == nil {
            setLutsCounterBuf = device.makeBuffer(length: 8, options: .storageModeShared)
        }
        return setLutsCounterBuf
    }

    /// The CPU twin: the same dispatch, scalar. Returns (selected, written).
    func setLutsOnCPU(path: SetLutsPath, base: Int, count: Int, listOffset: Int,
                      rLo: UInt64, rHi: UInt64, _ op: LutOp) -> (Int, Int) {
        let n = max(nodeCount, 1)
        let low = lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high = lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let rank = rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let list = rankListBuf?.contents().bindMemory(to: UInt32.self, capacity: n)
        var selected = 0, written = 0
        var fillLo: UInt32 = 0, fillHi: UInt32 = 0, isFill = true
        var mask: UInt64 = 0
        var keys: [UInt64] = [], tos: [UInt64] = []
        switch op {
        case .fill(let v):
            fillLo = UInt32(truncatingIfNeeded: v); fillHi = UInt32(truncatingIfNeeded: v >> 32)
        case let .map(m, pairs):
            isFill = false; mask = m
            keys = pairs.map(\.from); tos = pairs.map(\.to)
        }
        let np = keys.count
        keys.withUnsafeBufferPointer { kp in
            tos.withUnsafeBufferPointer { tp in
                @inline(__always) func apply(_ i: Int) {
                    selected += 1
                    if isFill {
                        low[i] = fillLo; high[i] = fillHi; written += 1
                        return
                    }
                    let key = (UInt64(high[i]) << 32 | UInt64(low[i])) & mask
                    for j in 0..<np where kp[j] == key {
                        let t = tp[j]
                        low[i] = UInt32(truncatingIfNeeded: t); high[i] = UInt32(truncatingIfNeeded: t >> 32)
                        written += 1
                        break
                    }
                }
                switch path {
                case .range:
                    for i in base..<(base + count) { apply(i) }
                case .rankList:
                    if let l = list { for j in listOffset..<(listOffset + count) { apply(Int(l[j])) } }
                case .rankLane:
                    for i in 0..<count where rank[i] >= rLo && rank[i] <= rHi { apply(i) }
                }
            }
        }
        return (selected, written)
    }
}
