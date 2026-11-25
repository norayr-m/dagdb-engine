/// TernaryReference — the CPU reference for the native ternary tick.
///
/// Every rule the GPU kernels implement for a ternary node is written here
/// first, as plain Swift, and the kernels are tested against it bit for bit.
///
///   · The trit view of the truth byte: a ternary node stores its
///     trit as the byte −1 ↔ 0 (FALSE), 0 ↔ 2 (UNDEFINED), +1 ↔ 1 (TRUE); it
///     reads ANY neighbour's byte as 0 → −1, 1 → +1, 2 → 0, ≥ 3 → 0 (a Loom
///     code is "unknown" to logic). An absent slot (nb < 0 or nb ≥ node
///     count) reads as 0.
///   · The mode lane: bits 0–1 the kind (0 BINARY, 1 TTABLE,
///     2 TTHRESH; 3 refused), bit 2 NOSKIP, bits 3–7 zero.
///   · TTABLE: index = Σ_{d=0..5} 3^d · (t_d + 1) into a 729-byte
///     table whose bytes are the truth-byte encoding of the output trit.
///   · TTHRESH: s = Σ_d w_d · t_d over present slots, in slot
///     order 0…5 in Float; +1 if s > hi, −1 if s < lo, else 0 (equality 0).
///     Flush-to-zero: every operand (each w_d, lo, hi)
///     and every partial sum s after each addition is replaced by the zero
///     of its sign when it is subnormal, before the comparison — the GPU's
///     hardware behaviour, written down.
///   · NOSKIP: previous and computed trits opposite and non-zero
///     ⇒ write 0 instead.
///   · Presets: each defined by a formula below; its table is
///     generated from the formula.
///   · Binary nodes are evaluated exactly as the LUT6 kernel does today.

import Foundation

public enum TernaryReference {

    // MARK: - Mode lane

    public static let kindMask: UInt8 = 0x03
    public static let kindBinary: UInt8 = 0
    public static let kindTTable: UInt8 = 1
    public static let kindTThresh: UInt8 = 2
    public static let noskipBit: UInt8 = 0x04
    /// Bits 3–7 of the mode byte must be zero.
    public static let reservedModeMask: UInt8 = 0xF8

    /// Bytes per table: 3^6.
    public static let tableSize = 729
    /// The library holds at most this many tables (ids are u16).
    public static let maxTables = 65_536

    /// Why a mode byte is refused, or nil when it is legal. NOSKIP is a
    /// ternary rule; on a BINARY node it is refused.
    public static func modeRefusal(_ m: UInt8) -> String? {
        if m & reservedModeMask != 0 {
            return String(format: "mode 0x%02x sets reserved bits 3-7 (0x%02x)", m, m & reservedModeMask)
        }
        let k = m & kindMask
        if k == 3 { return String(format: "mode 0x%02x has kind 3, which is not a kind", m) }
        if k == kindBinary && m & noskipBit != 0 {
            return String(format: "mode 0x%02x sets NOSKIP on a BINARY node; NOSKIP applies to ternary kinds only", m)
        }
        return nil
    }

    @inline(__always) public static func isTernary(_ mode: UInt8) -> Bool { mode & kindMask != 0 }

    // MARK: - The trit view

    /// Byte → trit, for any reader of any node.
    @inline(__always) public static func trit(ofByte b: UInt8) -> Int {
        b == 0 ? -1 : (b == 1 ? 1 : 0)
    }

    /// Trit → the byte a ternary node stores.
    @inline(__always) public static func byte(ofTrit t: Int) -> UInt8 {
        t < 0 ? 0 : (t > 0 ? 1 : 2)
    }

    /// The character form used by `TTABLE DEFINE`: '-' for −1, '0', '+'.
    public static func char(ofTableByte b: UInt8) -> Character {
        b == 0 ? "-" : (b == 1 ? "+" : "0")
    }

    public static func tableByte(ofChar c: Character) -> UInt8? {
        switch c { case "-": return 0; case "0": return 2; case "+": return 1; default: return nil }
    }

    // MARK: - TTABLE

    /// Σ_{d=0..5} 3^d · (t_d + 1); `trits` has six entries (absent = 0).
    public static func tableIndex(_ trits: [Int]) -> Int {
        precondition(trits.count == 6)
        var idx = 0
        var p = 1
        for d in 0..<6 { idx += p * (trits[d] + 1); p *= 3 }
        return idx
    }

    /// The inverse of `tableIndex`: the six trits of index `i` in 0..<729.
    public static func trits(ofIndex i: Int) -> [Int] {
        var v = i
        var out = [Int](repeating: 0, count: 6)
        for d in 0..<6 { out[d] = v % 3 - 1; v /= 3 }
        return out
    }

    // MARK: - TTHRESH

    /// A subnormal becomes the zero of its sign (+0.0 or
    /// −0.0); every other value, zeros included, is unchanged.
    @inline(__always) public static func flushToZero(_ x: Float) -> Float {
        x.isSubnormal ? Float(signOf: x, magnitudeOf: 0) : x
    }

    /// s = Σ w_d · t_d over the present slots, in slot order, in Float, with
    /// each weight and each partial sum flushed to zero.
    public static func thresholdSum(trits: [Int], present: [Bool], weights: [Float]) -> Float {
        var s: Float = 0
        for d in 0..<6 where present[d] {
            s = flushToZero(s + flushToZero(weights[d]) * Float(trits[d]))
        }
        return s
    }

    /// +1 if s > hi, −1 if s < lo, else 0; s, lo and hi flushed to zero first
    /// (signed zeros compare equal).
    public static func threshold(sum s: Float, lo: Float, hi: Float) -> Int {
        let s = flushToZero(s), lo = flushToZero(lo), hi = flushToZero(hi)
        if s > hi { return 1 }
        if s < lo { return -1 }
        return 0
    }

    /// Thresholds are finite with lo ≤ hi, otherwise refused.
    public static func thresholdRefusal(lo: Float, hi: Float) -> String? {
        if !lo.isFinite || !hi.isFinite {
            return "threshold lo=\(lo) hi=\(hi) is not finite"
        }
        if lo > hi { return "threshold lo=\(lo) > hi=\(hi)" }
        return nil
    }

    // MARK: - Whole-state checks (the persistence refusals, on load and on write)

    /// A library is a whole number of tables, at most `maxTables`, every
    /// byte 0, 1 or 2. Nil when valid.
    public static func libraryRefusal(_ bytes: [UInt8]) -> String? {
        if bytes.count % tableSize != 0 {
            return "library is \(bytes.count) bytes, not a whole number of \(tableSize)-byte tables"
        }
        let count = bytes.count / tableSize
        if count > maxTables { return "library holds \(count) tables, more than \(maxTables)" }
        for i in 0..<bytes.count where bytes[i] >= 3 {
            return "table \(i / tableSize) byte \(i % tableSize) is \(bytes[i]); table bytes are 0, 1 or 2"
        }
        return nil
    }

    // MARK: - The mode-write rules

    /// Where a mode write is judged: the daemon's verbs (`live`) or WAL replay
    /// (`replay`). The context selects only the words of a refusal, never the
    /// verdict — replay applies every rule live applies.
    public enum ModeWriteContext: Sendable { case live, replay }

    /// The rule a mode write breaks: the verdict, which no context changes.
    public enum ModeWriteRule: Equatable, Sendable {
        /// Reserved bits 3–7, kind 3, NOSKIP on
        /// BINARY — `modeRefusal`'s text.
        case modeByte(String)
        /// A ternary kind on a node whose truth byte is ≥ 3.
        case truthByte(UInt8)
        /// A register (BACK_EDGE destination) stays BINARY.
        case register
        /// A TTABLE node names a table below the library size.
        case ttableId(UInt16, tableCount: Int)
    }

    /// The verdict on giving a node the mode byte `m`, against the node's
    /// truth byte, register flag and table id and the library size, in the
    /// order every caller has always named the rules: the mode byte; then, for
    /// a ternary kind only, the truth byte, the register, the table id. Nil
    /// when the write is legal. No context: the verdict is the same everywhere.
    public static func modeWriteViolation(mode m: UInt8, truth: UInt8, isRegister: Bool,
                                          ttableId tid: UInt16, tableCount: Int) -> ModeWriteRule? {
        if let why = modeRefusal(m) { return .modeByte(why) }
        guard isTernary(m) else { return nil }
        if truth >= 3 { return .truthByte(truth) }
        if isRegister { return .register }
        if m & kindMask == kindTTable && Int(tid) >= tableCount { return .ttableId(tid, tableCount: tableCount) }
        return nil
    }

    /// The words of a refusal for node `i`. Live: the daemon's reply text,
    /// with the remedy. Replay: the text `ReplayResult.refusals` carries. Both
    /// are the texts each path gave before this checker (the ternary daemon, persistence and replay-and-save
    /// tests pin them).
    public static func modeWriteWords(_ rule: ModeWriteRule, node i: Int, context: ModeWriteContext) -> String {
        switch (rule, context) {
        case let (.modeByte(why), _):
            return "node \(i): \(why)"
        case let (.truthByte(t), .live):
            return "node \(i) holds truth byte \(t); a ternary node holds 0, 1 or 2 — SET \(i) TRUTH first"
        case let (.truthByte(t), .replay):
            return "node \(i): truth byte \(t) on a ternary node"
        case (.register, .live):
            return "node \(i) is a register (BACK_EDGE destination); registers stay BINARY"
        case (.register, .replay):
            return "node \(i): a register must be BINARY"
        case let (.ttableId(tid, c), .live):
            return "node \(i): ttableId \(tid) is not below the library size \(c) — SET \(i) TTABLE <tid> first"
        case let (.ttableId(tid, c), .replay):
            return "node \(i): ttableId \(tid) is not below the library size \(c)"
        }
    }

    /// The one mode-write checker. The command handler
    /// (SET MODE, SET_MODES_BULK) calls it with `.live`, WAL replay (SET_MODE,
    /// SET_MODES_BULK records) with `.replay`; the verdict is
    /// `modeWriteViolation`'s, the context picks the words. Nil when legal.
    public static func modeWriteRefusal(node i: Int, mode m: UInt8, truth: UInt8, isRegister: Bool,
                                        ttableId tid: UInt16, tableCount: Int,
                                        context: ModeWriteContext) -> String? {
        modeWriteViolation(mode: m, truth: truth, isRegister: isRegister, ttableId: tid, tableCount: tableCount)
            .map { modeWriteWords($0, node: i, context: context) }
    }

    /// One node's lanes against the mode, table and threshold rules:
    /// mode legal; thresholds finite with lo ≤ hi; a ternary node holds a
    /// truth byte < 3, is not a register, and (TTABLE) names a defined table.
    /// The mode rules' verdict is `modeWriteViolation`'s (one copy of the
    /// rules); the threshold rule sits between the mode byte and the rest,
    /// as it always has, and the words are this check's own (a test pins
    /// them).
    public static func nodeViolation(node i: Int, mode m: UInt8, ttableId tid: UInt16,
                                     lo: Float, hi: Float, truth: UInt8, isRegister: Bool,
                                     tableCount: Int) -> String? {
        if let why = modeRefusal(m) { return "node \(i): \(why)" }
        if let why = thresholdRefusal(lo: lo, hi: hi) { return "node \(i): \(why)" }
        switch modeWriteViolation(mode: m, truth: truth, isRegister: isRegister, ttableId: tid, tableCount: tableCount) {
        case nil:
            return nil
        case let .modeByte(why)?:            // not reached: the mode byte was checked above
            return "node \(i): \(why)"
        case let .truthByte(t)?:
            return "node \(i): truth byte \(t) on a ternary node (a ternary node holds 0, 1 or 2)"
        case .register?:
            return "node \(i): a register (BACK_EDGE destination) must be BINARY"
        case let .ttableId(t, c)?:
            return "node \(i): ttableId \(t) is not below the library size \(c)"
        }
    }

    /// Every node and the library, first violation named. `isRegister`
    /// may be nil (no registers).
    public static func stateViolation(n: Int, mode: UnsafePointer<UInt8>, ttableId: UnsafePointer<UInt16>,
                                      thrLo: UnsafePointer<Float>, thrHi: UnsafePointer<Float>,
                                      truth: UnsafePointer<UInt8>, isRegister: UnsafePointer<UInt8>?,
                                      tables: UnsafeBufferPointer<UInt8>) -> String? {
        if tables.count % tableSize != 0 {
            return "library is \(tables.count) bytes, not a whole number of \(tableSize)-byte tables"
        }
        let tableCount = tables.count / tableSize
        if tableCount > maxTables { return "library holds \(tableCount) tables, more than \(maxTables)" }
        for i in 0..<tables.count where tables[i] >= 3 {
            return "table \(i / tableSize) byte \(i % tableSize) is \(tables[i]); table bytes are 0, 1 or 2"
        }
        for i in 0..<n {
            let m = mode[i]
            // Fast path: a binary node with default-legal thresholds.
            if m == 0 && thrLo[i].isFinite && thrHi[i].isFinite && thrLo[i] <= thrHi[i] { continue }
            if let why = nodeViolation(node: i, mode: m, ttableId: ttableId[i], lo: thrLo[i], hi: thrHi[i],
                                       truth: truth[i], isRegister: (isRegister?[i] ?? 0) != 0,
                                       tableCount: tableCount) {
                return why
            }
        }
        return nil
    }

    // MARK: - NOSKIP

    /// Opposite and non-zero ⇒ 0. Otherwise the computed trit.
    @inline(__always) public static func noskip(previous p: Int, computed c: Int) -> Int {
        (p != 0 && c != 0 && p == -c) ? 0 : c
    }

    // MARK: - Presets

    public enum Preset: String, CaseIterable, Sendable {
        case tmin = "TMIN"            // Kleene AND
        case tmax = "TMAX"            // Kleene OR
        case tsum = "TSUM"            // sign of the sum
        case tcons = "TCONS"          // all k equal and non-zero → that value, else 0
        case tid = "TID"              // k = 1
        case tneg = "TNEG"            // k = 1
        case tconstNeg = "TCONST-1"
        case tconstZero = "TCONST0"
        case tconstPos = "TCONST+1"

        /// The arities the preset is defined for.
        public var arities: ClosedRange<Int> {
            switch self {
            case .tid, .tneg: return 1...1
            default: return 1...6
            }
        }
        /// Stable code for the WAL record (`TTABLE PRESET`).
        public var code: UInt8 {
            UInt8(Preset.allCases.firstIndex(of: self)!)
        }
        public static func from(code: UInt8) -> Preset? {
            Int(code) < allCases.count ? allCases[Int(code)] : nil
        }
    }

    /// The preset's formula on slots 0..<k (slots ≥ k are don't-care).
    public static func presetFormula(_ p: Preset, k: Int, trits t: [Int]) -> Int {
        let a = Array(t[0..<k])
        switch p {
        case .tmin: return a.min()!
        case .tmax: return a.max()!
        case .tsum:
            let s = a.reduce(0, +)
            return s > 0 ? 1 : (s < 0 ? -1 : 0)
        case .tcons:
            let v = a[0]
            return (v != 0 && a.allSatisfy { $0 == v }) ? v : 0
        case .tid: return a[0]
        case .tneg: return -a[0]
        case .tconstNeg: return -1
        case .tconstZero: return 0
        case .tconstPos: return 1
        }
    }

    public enum PresetError: Error, CustomStringConvertible {
        case arity(Preset, Int)
        public var description: String {
            switch self {
            case let .arity(p, k):
                return "preset \(p.rawValue) is defined for k in \(p.arities.lowerBound)...\(p.arities.upperBound), not \(k)"
            }
        }
    }

    /// The 729-byte table generated from the preset's formula.
    public static func presetTable(_ p: Preset, k: Int) throws -> [UInt8] {
        guard p.arities.contains(k) else { throw PresetError.arity(p, k) }
        var out = [UInt8](repeating: 2, count: tableSize)
        for i in 0..<tableSize {
            out[i] = byte(ofTrit: presetFormula(p, k: k, trits: trits(ofIndex: i)))
        }
        return out
    }

    // MARK: - COMPOSE on tables

    /// Pointwise on trits: AND → min, OR → max, NOT → negation. Inputs are
    /// table bytes; the output is a table of bytes.
    public static func composeTables(op: String, _ a: [UInt8], _ b: [UInt8]?) -> [UInt8]? {
        var out = [UInt8](repeating: 2, count: tableSize)
        for i in 0..<tableSize {
            let x = trit(ofByte: a[i])
            switch op {
            case "NOT": out[i] = byte(ofTrit: -x)
            case "AND":
                guard let b = b else { return nil }
                out[i] = byte(ofTrit: min(x, trit(ofByte: b[i])))
            case "OR":
                guard let b = b else { return nil }
                out[i] = byte(ofTrit: max(x, trit(ofByte: b[i])))
            default: return nil
            }
        }
        return out
    }

    // MARK: - The evaluator

    /// Everything one evaluation reads, as plain arrays (engine order).
    public struct Graph {
        public var truth: [UInt8]
        public var rank: [UInt64]
        public var lutLow: [UInt32]
        public var lutHigh: [UInt32]
        public var neighbors: [Int32]
        public var isRegister: [UInt8]
        public var edgeWeights: [Float]
        public var mode: [UInt8]
        public var ttableId: [UInt16]
        public var thrLo: [Float]
        public var thrHi: [Float]
        /// The library, `tableSize` bytes per table.
        public var tables: [UInt8]
        public var backEdgeSrcs: [UInt32]
        public var backEdgeDsts: [UInt32]

        public var nodeCount: Int { truth.count }
        public var tableCount: Int { tables.count / TernaryReference.tableSize }

        public init(truth: [UInt8], rank: [UInt64], lutLow: [UInt32], lutHigh: [UInt32],
                    neighbors: [Int32], isRegister: [UInt8], edgeWeights: [Float],
                    mode: [UInt8], ttableId: [UInt16], thrLo: [Float], thrHi: [Float],
                    tables: [UInt8], backEdgeSrcs: [UInt32], backEdgeDsts: [UInt32]) {
            self.truth = truth; self.rank = rank; self.lutLow = lutLow; self.lutHigh = lutHigh
            self.neighbors = neighbors; self.isRegister = isRegister; self.edgeWeights = edgeWeights
            self.mode = mode; self.ttableId = ttableId; self.thrLo = thrLo; self.thrHi = thrHi
            self.tables = tables; self.backEdgeSrcs = backEdgeSrcs; self.backEdgeDsts = backEdgeDsts
        }
    }

    /// The byte node `node` computes when it reads `read` (the truth array
    /// its evaluation sees) and its previous byte is `previous`. Registers
    /// are not evaluated (callers skip them).
    public static func evaluate(_ g: Graph, node: Int, read: [UInt8], previous: UInt8) -> UInt8 {
        read.withUnsafeBufferPointer { r in
            Lanes.with(g) { lanes in lanes.evaluate(node: node, read: r.baseAddress!, previous: previous) }
        }
    }

    /// Raw views of every lane one evaluation reads — the reference's inner
    /// loop, kept allocation-free so the GPU-against-reference sweep at 1,048,576 nodes runs in
    /// a debug test build.
    struct Lanes {
        let n: Int
        let neighbors: UnsafePointer<Int32>
        let lutLow: UnsafePointer<UInt32>
        let lutHigh: UnsafePointer<UInt32>
        let weights: UnsafePointer<Float>
        let mode: UnsafePointer<UInt8>
        let ttableId: UnsafePointer<UInt16>
        let thrLo: UnsafePointer<Float>
        let thrHi: UnsafePointer<Float>
        let tables: UnsafePointer<UInt8>
        let tableCount: Int

        static func with<R>(_ g: Graph, _ body: (Lanes) -> R) -> R {
            // A zero-length array's base address may be nil; one spare byte
            // keeps every pointer valid (the library may be empty).
            let tables = g.tables.isEmpty ? [UInt8](repeating: 2, count: 1) : g.tables
            return g.neighbors.withUnsafeBufferPointer { nb in
            g.lutLow.withUnsafeBufferPointer { lo in
            g.lutHigh.withUnsafeBufferPointer { hi in
            g.edgeWeights.withUnsafeBufferPointer { w in
            g.mode.withUnsafeBufferPointer { m in
            g.ttableId.withUnsafeBufferPointer { tid in
            g.thrLo.withUnsafeBufferPointer { tl in
            g.thrHi.withUnsafeBufferPointer { th in
            tables.withUnsafeBufferPointer { tb in
                body(Lanes(n: g.nodeCount, neighbors: nb.baseAddress!, lutLow: lo.baseAddress!,
                           lutHigh: hi.baseAddress!, weights: w.baseAddress!, mode: m.baseAddress!,
                           ttableId: tid.baseAddress!, thrLo: tl.baseAddress!, thrHi: th.baseAddress!,
                           tables: tb.baseAddress!, tableCount: g.tableCount))
            }}}}}}}}}
        }

        @_optimize(speed)
        func evaluate(node: Int, read: UnsafePointer<UInt8>, previous: UInt8) -> UInt8 {
            let m = mode[node]
            let kind = m & TernaryReference.kindMask
            if kind == TernaryReference.kindBinary {
                // Today's LUT6 rule: input bit d = 1 iff the source byte is
                // 1; an absent slot (nb < 0 or nb ≥ n) contributes 0.
                var bits: UInt64 = 0
                for d in 0..<6 {
                    let nb = Int(neighbors[node * 6 + d])
                    if nb < 0 || nb >= n { continue }
                    if read[nb] == 1 { bits |= UInt64(1) << UInt64(d) }
                }
                let lut = (UInt64(lutHigh[node]) << 32) | UInt64(lutLow[node])
                return UInt8((lut >> bits) & 1)
            }
            var computed = 0
            if kind == TernaryReference.kindTTable {
                // index = Σ 3^d · (t_d + 1); an absent slot reads 0.
                var idx = 0
                var p = 1
                for d in 0..<6 {
                    let nb = Int(neighbors[node * 6 + d])
                    var t = 0
                    if nb >= 0 && nb < n { t = TernaryReference.trit(ofByte: read[nb]) }
                    idx += p * (t + 1)
                    p *= 3
                }
                let tid = Int(ttableId[node])
                // tid ≥ library size is refused on every write and load path;
                // the kernel's guard gives the same answer if it ever happens.
                computed = tid < tableCount
                    ? TernaryReference.trit(ofByte: tables[tid * TernaryReference.tableSize + idx])
                    : 0
            } else {
                // s = Σ w_d · t_d over present slots, slot order, Float;
                // each weight and each partial sum flushed to zero, and lo
                // and hi flushed in `threshold`.
                var s: Float = 0
                for d in 0..<6 {
                    let nb = Int(neighbors[node * 6 + d])
                    if nb < 0 || nb >= n { continue }
                    let t = TernaryReference.trit(ofByte: read[nb])
                    s = TernaryReference.flushToZero(s + TernaryReference.flushToZero(weights[node * 6 + d]) * Float(t))
                }
                computed = TernaryReference.threshold(sum: s, lo: thrLo[node], hi: thrHi[node])
            }
            if m & TernaryReference.noskipBit != 0 {
                computed = TernaryReference.noskip(previous: TernaryReference.trit(ofByte: previous),
                                                   computed: computed)
            }
            return TernaryReference.byte(ofTrit: computed)
        }
    }

    /// Latch phase: snapshot every source byte, then write every destination.
    public static func latch(_ g: inout Graph) {
        let snap = g.backEdgeSrcs.map { g.truth[Int($0)] }
        for i in 0..<g.backEdgeDsts.count { g.truth[Int(g.backEdgeDsts[i])] = snap[i] }
    }

    /// The colour order a rank tick dispatches in for `tickNumber` — the
    /// engine's own shuffle, restated.
    public static func colorOrder(tickNumber: UInt32, colorCount: Int) -> [Int] {
        var order = Array(0..<colorCount)
        var seed = tickNumber &* 2654435761
        for i in stride(from: order.count - 1, through: 1, by: -1) {
            seed = seed &* 1103515245 &+ 12345
            let j = Int(seed >> 16) % (i + 1)
            order.swapAt(i, j)
        }
        return order
    }

    /// One rank-mode tick: ranks from the highest present down to 0; within
    /// a rank, colour groups in the tick's shuffled order; every node of one
    /// (rank, colour) segment reads the truth as it stood before that
    /// segment (the GPU dispatches a segment in parallel — the segment's
    /// writes are applied after it); registers are skipped; then the latch.
    /// `colorOf[node]` is the node's colour.
    @_optimize(speed)
    public static func tickRank(_ g: inout Graph, tickNumber: UInt32, colorOf: [UInt8], colorCount: Int) {
        let n = g.nodeCount
        var highest: UInt64 = 0
        for i in 0..<n where g.rank[i] < UInt64(n) && g.rank[i] > highest { highest = g.rank[i] }
        let levels = Int(highest) + 1
        // Bucket by (rank, colour) in one flat list.
        var counts = [Int](repeating: 0, count: levels * colorCount + 1)
        for i in 0..<n where g.rank[i] <= highest {
            counts[Int(g.rank[i]) * colorCount + Int(colorOf[i]) + 1] += 1
        }
        for k in 1..<counts.count { counts[k] += counts[k - 1] }
        var fill = counts
        var flat = [Int](repeating: 0, count: counts[counts.count - 1])
        for i in 0..<n where g.rank[i] <= highest {
            let k = Int(g.rank[i]) * colorCount + Int(colorOf[i])
            flat[fill[k]] = i
            fill[k] += 1
        }
        let order = colorOrder(tickNumber: tickNumber, colorCount: colorCount)
        var writes = [UInt8](repeating: 0, count: n)
        let isReg = g.isRegister
        Lanes.with(g) { lanes in
            for r in stride(from: levels - 1, through: 0, by: -1) {
                for c in order {
                    let k = r * colorCount + c
                    let a = counts[k], b = counts[k + 1]
                    if a == b { continue }
                    g.truth.withUnsafeMutableBufferPointer { truth in
                        let base = UnsafePointer(truth.baseAddress!)
                        for j in a..<b {
                            let node = flat[j]
                            if isReg[node] != 0 { continue }
                            writes[j - a] = lanes.evaluate(node: node, read: base, previous: base[node])
                        }
                        for j in a..<b {
                            let node = flat[j]
                            if isReg[node] != 0 { continue }
                            truth[node] = writes[j - a]
                        }
                    }
                }
            }
        }
        latch(&g)
    }

    /// One sync-mode tick: every non-register node reads the previous
    /// vector; registers hold; then the latch.
    @_optimize(speed)
    public static func tickSync(_ g: inout Graph) {
        let before = g.truth
        var next = before
        let isReg = g.isRegister
        Lanes.with(g) { lanes in
            before.withUnsafeBufferPointer { b in
                for i in 0..<g.nodeCount where isReg[i] == 0 {
                    next[i] = lanes.evaluate(node: i, read: b.baseAddress!, previous: b[i])
                }
            }
        }
        g.truth = next
        latch(&g)
    }
}
