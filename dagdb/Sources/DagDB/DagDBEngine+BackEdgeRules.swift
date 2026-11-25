/// DagDBEngine+BackEdgeRules — one rule set for back edges on every path.
///
/// `CONNECT BACK` refuses, per entry and in this order, a source or a
/// destination out of range, a self-loop, a ternary destination (a register
/// stays BINARY) and a destination with a live combinational slot (a register
/// has zero combinational fan-in). `CONNECT_BACK_BULK` runs the same checks on
/// every entry. The loaders once installed their lists with a range check only:
/// IMPORT MORTON's `back_edges.bin`, LOAD's back-edge section, LOAD JSON's
/// `backEdges`, LOAD CSV's `back_edges.csv`, BACKUP RESTORE's back-edge
/// section — the ternary rule was met there only as a lane rule, by node.
///
/// `backEdgeRule` is the one function; each path hands it the lanes it is
/// about to make live: the live engine's (CONNECT BACK, CONNECT_BACK_BULK,
/// SAVE) or a loader's STAGED lanes (the file's mode and neighbour lanes,
/// before anything is committed — never the live engine's, which still holds
/// the previous graph). It reads the destination's mode byte and its six
/// slots, never the back-edge list, so an entry's verdict does not depend on
/// the entries before it. The words are CONNECT BACK's (`backEdgeRuleWords`);
/// the daemon composes its replies from them.

import Foundation

extension DagDBEngine {

    /// The rule a back edge `src → dst` breaks, in CONNECT BACK's order.
    public enum BackEdgeRule: Equatable, Sendable {
        case sourceOutOfRange(nodeCount: Int)
        case destinationOutOfRange(nodeCount: Int)
        case selfLoop
        case destinationIsTernary(mode: UInt8)
        case destinationHasCombinationalInDegree(slot: Int, source: Int32)
    }

    /// One back edge against CONNECT BACK's rules on the given lanes, or nil.
    /// `mode`: the mode lane (nil = every node BINARY, as unallocated lanes
    /// read); `neighbors`: the slot lane, 6 per node.
    @inline(__always)
    public static func backEdgeRule(src: UInt32, dst: UInt32, nodeCount: Int,
                                    mode: UnsafePointer<UInt8>?,
                                    neighbors: UnsafePointer<Int32>) -> BackEdgeRule? {
        guard Int(src) < nodeCount else { return .sourceOutOfRange(nodeCount: nodeCount) }
        guard Int(dst) < nodeCount else { return .destinationOutOfRange(nodeCount: nodeCount) }
        if src == dst { return .selfLoop }
        let d = Int(dst)
        if let m = mode, TernaryReference.isTernary(m[d]) { return .destinationIsTernary(mode: m[d]) }
        for k in 0..<6 where neighbors[d * 6 + k] >= 0 {
            return .destinationHasCombinationalInDegree(slot: k, source: neighbors[d * 6 + k])
        }
        return nil
    }

    /// CONNECT BACK's reply for a rule: its category and its words.
    public static func backEdgeRuleWords(_ rule: BackEdgeRule, src: UInt32, dst: UInt32)
        -> (category: String, words: String) {
        switch rule {
        case .sourceOutOfRange(let n):
            return ("out_of_range", "src \(src) not in 0..<\(n)")
        case .destinationOutOfRange(let n):
            return ("out_of_range", "dst \(dst) not in 0..<\(n)")
        case .selfLoop:
            return ("schema", "self-loop: src == dst (\(src))")
        case .destinationIsTernary:
            return ("bad_value", "ternary: CONNECT BACK into ternary node \(dst); a register (BACK_EDGE destination) stays BINARY — SET \(dst) MODE BINARY first")
        case let .destinationHasCombinationalInDegree(slot, source):
            return ("schema", BackEdgeError.destinationHasCombinationalInDegree(dst: dst, slot: slot, src: source).description)
        }
    }

    /// A list refused by its first entry that breaks a rule: where the list
    /// came from, the entry, the pair and the rule. The description is the
    /// library's (the list, the entry, CONNECT BACK's words); the daemon
    /// replies `ERROR schema: <VERB> <list> entry <i>: <words>; nothing <…>`.
    public struct BackEdgeEntryRefusal: Error, Equatable, CustomStringConvertible {
        public let list: String
        public let entry: Int
        public let src: UInt32
        public let dst: UInt32
        public let rule: BackEdgeRule
        public var words: String { DagDBEngine.backEdgeRuleWords(rule, src: src, dst: dst).words }
        public var description: String { "\(list) entry \(entry): \(words)" }
    }

    /// The first entry of a list, in order, that breaks a rule on the given
    /// lanes, or nil.
    public static func backEdgeListRefusal(list: String, srcs: [UInt32], dsts: [UInt32], nodeCount: Int,
                                           mode: UnsafePointer<UInt8>?,
                                           neighbors: UnsafePointer<Int32>) -> BackEdgeEntryRefusal? {
        for i in 0..<min(srcs.count, dsts.count) {
            if let r = backEdgeRule(src: srcs[i], dst: dsts[i], nodeCount: nodeCount, mode: mode, neighbors: neighbors) {
                return BackEdgeEntryRefusal(list: list, entry: i, src: srcs[i], dst: dsts[i], rule: r)
            }
        }
        return nil
    }

    /// The same, the lanes given as bytes (a staged file's): `mode` n bytes or
    /// nil, `neighbors` 24 n bytes. Copied once when a lane is not aligned
    /// for its type.
    public static func backEdgeListRefusal(list: String, srcs: [UInt32], dsts: [UInt32], nodeCount: Int,
                                           modeBytes: UnsafeRawBufferPointer?,
                                           neighborBytes: UnsafeRawBufferPointer) -> BackEdgeEntryRefusal? {
        if srcs.isEmpty { return nil }
        func withNeighbors<R>(_ body: (UnsafePointer<Int32>) -> R) -> R {
            if let b = neighborBytes.baseAddress, Int(bitPattern: b) % MemoryLayout<Int32>.alignment == 0 {
                return body(b.assumingMemoryBound(to: Int32.self))
            }
            var copy = [Int32](repeating: -1, count: nodeCount * 6)
            copy.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: neighborBytes.prefix(nodeCount * 24))) }
            return copy.withUnsafeBufferPointer { body($0.baseAddress!) }
        }
        return withNeighbors { nb in
            backEdgeListRefusal(list: list, srcs: srcs, dsts: dsts, nodeCount: nodeCount,
                                mode: modeBytes?.baseAddress?.assumingMemoryBound(to: UInt8.self), neighbors: nb)
        }
    }

    // MARK: - S4 alone (the slot model)

    /// S4 — a slot into a register — alone: the first entry of a list, in order,
    /// whose destination holds a live combinational slot on `neighbors`, in
    /// CONNECT BACK's words (`destinationHasCombinationalInDegree`), or nil.
    /// The other rules of `backEdgeRule` are not asked: the lists this checks
    /// (the live list LOAD JSON v1 and LOAD CSV v1 keep, the live list the
    /// daemon's writers would write) passed them where they were installed.
    /// BACKUP COMPACT once asked it of a chain's tip; it now asks RESTORE's
    /// rules (`DagDBBackup.compact(refuseWhatRestoreRefuses:)`).
    public static func slotIntoRegisterRefusal(list: String, srcs: [UInt32], dsts: [UInt32], nodeCount: Int,
                                               neighbors: UnsafePointer<Int32>) -> BackEdgeEntryRefusal? {
        for i in 0..<min(srcs.count, dsts.count) where Int(dsts[i]) < nodeCount {
            let d = Int(dsts[i])
            for k in 0..<6 where neighbors[d * 6 + k] >= 0 {
                return BackEdgeEntryRefusal(list: list, entry: i, src: srcs[i], dst: dsts[i],
                                            rule: .destinationHasCombinationalInDegree(slot: k, source: neighbors[d * 6 + k]))
            }
        }
        return nil
    }

    /// The live list against the live slots, S4 alone (the daemon's writers).
    public func liveSlotIntoRegisterRefusal(list: String) -> BackEdgeEntryRefusal? {
        if backEdgeSrcs.isEmpty { return nil }
        let nb = neighborsBuf.contents().bindMemory(to: Int32.self, capacity: max(nodeCount * 6, 1))
        return Self.slotIntoRegisterRefusal(list: list, srcs: backEdgeSrcs, dsts: backEdgeDsts,
                                            nodeCount: nodeCount, neighbors: nb)
    }

    /// Every slot into a register the live state holds — a register being a
    /// back-edge destination or a node whose register flag is set — by
    /// register, then slot. Empty on every state the daemon builds; a log
    /// written before the slot-into-register rule can replay one.
    public func slotsIntoRegisters() -> [(register: Int, slot: Int, source: Int32)] {
        let n = nodeCount
        guard n > 0 else { return [] }
        let flags = isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let nb = neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        var out: [(register: Int, slot: Int, source: Int32)] = []
        for i in 0..<n where flags[i] != 0 {
            for k in 0..<6 where nb[i * 6 + k] >= 0 { out.append((i, k, nb[i * 6 + k])) }
        }
        // A list destination whose flag is not set (only a crafted state).
        let unflagged = Set(backEdgeDsts.lazy.map(Int.init).filter { $0 < n && flags[$0] == 0 })
        if !unflagged.isEmpty {
            for i in unflagged { for k in 0..<6 where nb[i * 6 + k] >= 0 { out.append((i, k, nb[i * 6 + k])) } }
            out.sort { ($0.register, $0.slot) < ($1.register, $1.slot) }
        }
        return out
    }

    /// The way out of a state holding a slot
    /// into register `dst`, with verbs that exist: either one makes the
    /// state one SAVE writes.
    public static func slotIntoRegisterWayOut(dst: UInt32) -> String {
        "the way out: CLEAR \(dst) EDGES (drops the register's combinational inputs) or CLEAR \(dst) BACK_EDGES (unmakes the register)"
    }

    /// The live back-edge list against the live lanes (SAVE's check: SAVE
    /// refuses what LOAD refuses). Never allocates a lane.
    public func liveBackEdgeRefusal(list: String) -> BackEdgeEntryRefusal? {
        let nb = neighborsBuf.contents().bindMemory(to: Int32.self, capacity: max(nodeCount * 6, 1))
        return Self.backEdgeListRefusal(list: list, srcs: backEdgeSrcs, dsts: backEdgeDsts, nodeCount: nodeCount,
                                        mode: ternaryLaneView?.mode, neighbors: nb)
    }
}
