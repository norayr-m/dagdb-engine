/// DagDBCommandHandler+EngineG2 — `TRUTH_SLICE` over the selection
/// only, 8 nodes per step, and its `BYTES` form.
///
/// The per-node loop (`truthSliceE2Loop`) makes two passes, one node at a time: the
/// first over the id range — for `RANK`, over the whole rank lane, reading
/// every node's rank — to count, find the first and last id, refuse the
/// first byte of 3 or more and see whether any byte is 2; the second to OR
/// each node's bits into its output byte. The batched path keeps that loop's behaviour — the width
/// rule (1 bit per node on a graph with no ternary node whose slice holds
/// only 0 and 1, else 2), the refusal of the first byte ≥ 3 in ascending id
/// by name, the reply's fields, the shm layout, reader sessions — and visits
/// only the selection, 8 nodes per step:
///   - `NODES lo-hi`: the ids lo…hi, one unaligned u64 load per 8 nodes;
///   - `RANK r-r`: rank r's rank list (ascending ids, made current first:
///     `DagDBEngine.currentRankList`); 8 entries whose ids span exactly 7 are
///     8 consecutive ids and one u64 load, else the 8 bytes are gathered;
///   - `RANK lo-hi` with lo < hi, a rank with no list (no rank-ordered TICK
///     yet; a reader session's engine), and the seam: the per-node loop, kept (the
///     ids of several ranks interleave; their order is the rank lane's scan).
/// Pass 1 checks each 8-byte word at once (a byte ≥ 3 is a bit above bit 1,
/// or bits 0 and 1 both set; the first such byte is the word's lowest, so
/// the first offender in ascending id is named, as the per-node loop names it) and ORs the
/// words (a byte of 2 is bit 1 set once no byte is ≥ 3). Nothing is written
/// before the slice is accepted: a refused slice leaves the shm untouched,
/// as the per-node loop's does. Pass 2 packs a word into a byte (bits: a u64
/// multiply, no C/NEON target) or two (trits: the low and high bits packed
/// apart and interleaved). Exactly the slice's bytes are written; the pad
/// bits of the last byte are 0.
///
/// `BYTES`: every truth byte of the slice verbatim, 8 bits per
/// node (a memcpy for a NODES range; the list's words for a rank), header
/// `bits per node = 8`, `format=bytes`. Nothing is refused for its value —
/// Loom codes (3…255) and a ternary node's 0/1/2 travel as they are; the
/// selection's refusals (an empty or out-of-range range) and the shm's
/// capacity are the other forms' own.

import Foundation
import DagDB

/// The nodes of one slice, 8 per step: `word(w)` holds nodes 8w…8w+7 of the
/// slice in its bytes (byte k: node 8w+k's truth byte), zero past the end.
protocol TruthSliceNodes {
    var count: Int { get }
    func word(_ w: Int) -> UInt64
    /// The id of the slice's node j.
    func id(_ j: Int) -> Int
    /// Every truth byte of the slice, in order, to `o` (BYTES).
    func copyRaw(to o: UnsafeMutablePointer<UInt8>)
}

/// A NODES range: the ids first…first+count−1.
struct TruthSliceRange: TruthSliceNodes {
    let truth: UnsafePointer<UInt8>
    let first: Int
    let count: Int

    @inline(__always) func word(_ w: Int) -> UInt64 {
        let j = w &* 8
        let p = truth + (first &+ j)
        if j &+ 8 <= count { return UnsafeRawPointer(p).loadUnaligned(as: UInt64.self) }
        var x: UInt64 = 0, k = 0
        while j &+ k < count { x |= UInt64(p[k]) &<< UInt64(8 &* k); k &+= 1 }
        return x
    }

    @inline(__always) func id(_ j: Int) -> Int { first &+ j }

    func copyRaw(to o: UnsafeMutablePointer<UInt8>) {
        if count > 0 { memcpy(o, truth + first, count) }
    }
}

/// `RANK r-r`: rank r's rank list — ascending ids, each once. Eight entries
/// whose ids span exactly 7 are eight consecutive ids (the list ascends
/// strictly): one u64 load; otherwise the eight bytes are gathered.
struct TruthSliceList: TruthSliceNodes {
    let truth: UnsafePointer<UInt8>
    let list: UnsafePointer<UInt32>
    let count: Int

    @inline(__always) func word(_ w: Int) -> UInt64 {
        let j = w &* 8
        if j &+ 8 <= count {
            let a = Int(list[j])
            if Int(list[j &+ 7]) &- a == 7 { return UnsafeRawPointer(truth + a).loadUnaligned(as: UInt64.self) }
            var x: UInt64 = 0
            for k in 0..<8 { x |= UInt64(truth[Int(list[j &+ k])]) &<< UInt64(8 &* k) }
            return x
        }
        var x: UInt64 = 0, k = 0
        while j &+ k < count { x |= UInt64(truth[Int(list[j &+ k])]) &<< UInt64(8 &* k); k &+= 1 }
        return x
    }

    @inline(__always) func id(_ j: Int) -> Int { Int(list[j]) }

    func copyRaw(to o: UnsafeMutablePointer<UInt8>) {
        let full = count / 8
        let raw = UnsafeMutableRawPointer(o)
        for w in 0..<full { raw.storeBytes(of: word(w), toByteOffset: 8 &* w, as: UInt64.self) }
        for j in (8 &* full)..<count { o[j] = truth[Int(list[j])] }
    }
}

extension DagDBCommandHandler {

    // MARK: - The 8-node word

    /// The bytes of `x` that are 3 or more — a bit above bit 1, or bits 0
    /// and 1 both set — as nonzero bytes (each byte's own bits only).
    @inline(__always) static func truthSliceBadBytes(_ x: UInt64) -> UInt64 {
        (x & 0xFCFC_FCFC_FCFC_FCFC) | (x & (x &>> 1) & 0x0101_0101_0101_0101)
    }

    /// Bit 0 of byte k → bit k: eight nodes' low bits in one byte, the
    /// slice's earlier node in the less significant bit (the per-node loop's layout). The
    /// u64 multiply: the eight products land on distinct bits,
    /// so nothing carries into the top byte.
    @inline(__always) static func truthSlicePack8(_ x: UInt64) -> UInt8 {
        UInt8(truncatingIfNeeded: ((x & 0x0101_0101_0101_0101) &* 0x0102_0408_1020_4080) &>> 56)
    }

    /// Bit k → bit 2k.
    @inline(__always) static func truthSliceSpread8(_ b: UInt8) -> UInt16 {
        var v = UInt16(b)
        v = (v | (v &<< 4)) & 0x0F0F
        v = (v | (v &<< 2)) & 0x3333
        v = (v | (v &<< 1)) & 0x5555
        return v
    }

    /// Eight bytes of 0, 1, 2 → 16 bits, node k at bits 2k (the byte's bit 0)
    /// and 2k+1 (its bit 1).
    @inline(__always) static func truthSliceTrits16(_ x: UInt64) -> UInt16 {
        truthSliceSpread8(truthSlicePack8(x)) | (truthSliceSpread8(truthSlicePack8(x &>> 1)) &<< 1)
    }

    // MARK: - TRUTH_SLICE

    /// `TRUTH_SLICE NODES|RANK <lo>-<hi> [BYTES]` (see the file's header).
    func truthSlice(byRank: Bool, lo: UInt64, hi: UInt64, bytes raw: Bool, engine e: DagDBEngine, nodeCount n: Int,
                    sessionId: String?) -> String {
        lastTruthSlicePath = ""
        guard lo <= hi else { return "ERROR out_of_range: range \(lo)-\(hi) is empty (lo > hi)" }
        // The line names the value the caller sent, not a clamp of it.
        if !byRank && hi >= UInt64(n) { return "ERROR out_of_range: node \(hi) not in 0..<\(n)" }
        let truth = UnsafePointer(e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: max(n, 1)))
        let nonBinary = e.nonBinaryNodeCount > 0
        if !truthSliceOldLoopForTesting {
            if !byRank {
                lastTruthSlicePath = "range"
                return truthSlicePacked(TruthSliceRange(truth: truth, first: Int(lo), count: Int(hi - lo) + 1),
                                        raw: raw, nonBinary: nonBinary, truth: truth, sessionId: sessionId)
            }
            if lo == hi, let list = e.currentRankList(lo) {
                lastTruthSlicePath = "rankList"
                guard let base = list.baseAddress, list.count > 0 else {
                    return truthSlicePacked(TruthSliceRange(truth: truth, first: 0, count: 0),
                                            raw: raw, nonBinary: nonBinary, truth: truth, sessionId: sessionId)
                }
                return truthSlicePacked(TruthSliceList(truth: truth, list: base, count: list.count),
                                        raw: raw, nonBinary: nonBinary, truth: truth, sessionId: sessionId)
            }
        }
        lastTruthSlicePath = "e2Loop"
        return truthSliceE2Loop(byRank: byRank, lo: lo, hi: hi, raw: raw, engine: e, nodeCount: n, sessionId: sessionId)
    }

    /// The slice `s`: checked (bits/trits), then packed, 8 nodes per step.
    func truthSlicePacked<S: TruthSliceNodes>(_ s: S, raw: Bool, nonBinary: Bool, truth: UnsafePointer<UInt8>,
                                              sessionId: String?) -> String {
        let c = s.count, words = (c &+ 7) / 8
        var bits = 8
        if !raw {
            // Pass 1: the first byte ≥ 3 in ascending id (refused by name, nothing written), any byte of 2.
            var offender = -1
            var seen: UInt64 = 0
            for w in 0..<words {
                let x = s.word(w)
                let bad = Self.truthSliceBadBytes(x)
                if bad != 0 { offender = w &* 8 &+ bad.trailingZeroBitCount &>> 3; break }
                seen |= x
            }
            if offender >= 0 {
                let i = s.id(offender)
                return "ERROR bad_value: TRUTH_SLICE node \(i) truth \(truth[i]) does not fit 2 bits (0, 1, 2); read it with NODES or GET"
            }
            bits = (!nonBinary && (seen & 0x0202_0202_0202_0202) == 0) ? 1 : 2
        }
        let nb = (c * bits + 7) / 8
        if let r = checkShmFits(rows: nb, rowSize: 1) { return r }
        let h = shmBase.bindMemory(to: UInt32.self, capacity: 2)
        h[0] = UInt32(c); h[1] = UInt32(bits)
        let out = shmBase.advanced(by: 8)
        let o = out.bindMemory(to: UInt8.self, capacity: max(nb, 1))
        // Pass 2: exactly nb bytes written.
        switch bits {
        case 1:
            for w in 0..<words { o[w] = Self.truthSlicePack8(s.word(w)) }
        case 2:
            let full = c / 8
            for w in 0..<full {
                out.storeBytes(of: Self.truthSliceTrits16(s.word(w)).littleEndian, toByteOffset: 2 &* w, as: UInt16.self)
            }
            if full < words {
                let t = Self.truthSliceTrits16(s.word(full))
                o[2 &* full] = UInt8(truncatingIfNeeded: t)
                if 2 &* full &+ 1 < nb { o[2 &* full &+ 1] = UInt8(truncatingIfNeeded: t &>> 8) }
            }
        default:
            s.copyRaw(to: o)
        }
        let session = sessionId.map { " session=\($0)" } ?? ""
        let first = c > 0 ? String(s.id(0)) : "-", last = c > 0 ? String(s.id(c - 1)) : "-"
        return "OK TRUTH_SLICE\(session) nodes=\(c) format=\(bits == 1 ? "bits" : (bits == 2 ? "trits" : "bytes")) "
            + "bits_per_node=\(bits) shm_bytes=\(nb) first=\(first) last=\(last)"
    }
}
