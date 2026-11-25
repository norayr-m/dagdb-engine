import Foundation
import Metal
@testable import DagDB

/// TiledReference gains the ternary evaluator.
///
/// Written from the rules, never calling `DagDBEngine` or
/// `TernaryReference` to evaluate anything. An extension in its own file, so
/// the frozen TiledReference.swift stays unchanged; it re-derives what it
/// needs from TiledReference's internal lets. Shared into the daemon-kit test
/// target by symlink, as TiledReference.swift is.
///
/// The ternary rules, restated:
/// - trits: any byte reads as a trit 0 → −1, 1 → +1, 2 and ≥ 3 → 0; a
///   ternary node stores −1 as 0, 0 as 2, +1 as 1; an absent slot reads 0;
///   a binary node reads and writes exactly as today (TiledReference's bit
///   rule);
/// - TTABLE: output = table[ttableId][Σ 3^d (t_d + 1)];
/// - TTHRESH: s = Σ w_d·t_d over present
///   slots, slot order 0…5, f32; +1 if s > hi, −1 if s < lo, else 0;
/// - NOSKIP: turns an opposite non-zero step into 0, "previous"
///   being the node's byte before this evaluation (rank) or the previous
///   vector's (sync).
extension TiledReference {

    struct TernaryLanes {
        let mode: [UInt8]
        let ttableId: [UInt16]
        let thrLo: [Float]
        let thrHi: [Float]
        let weights: [Float]
        let tables: [UInt8]

        init(engine e: DagDBEngine) {
            let n = e.nodeCount
            func lane<T>(_ b: MTLBuffer, _ c: Int) -> [T] {
                Array(UnsafeBufferPointer(start: b.contents().bindMemory(to: T.self, capacity: c), count: c))
            }
            mode = lane(e.nodeModeBuf, n)
            ttableId = lane(e.ttableIdBuf, n)
            thrLo = lane(e.thrLoBuf, n)
            thrHi = lane(e.thrHiBuf, n)
            weights = lane(e.edgeWeightsBuf, n * 6)
            tables = e.libraryBytes()
        }
    }

    /// What the reference saw while it ticked one tiling: the coverage lines
    /// of the ternary tiling test, so the object is shown able to fail it — every kind
    /// evaluated, NOSKIP firing, TTHRESH sums landing ON a threshold, absent
    /// slots under ternary readers, and the reads a ghost has to carry: a
    /// ternary reader taking a trit across a tile boundary (UNDEFINED
    /// included, which a ghost that kept only a bit would turn into −1), Loom
    /// bytes crossing, registers read across. Counted by the reference, never
    /// by the engine.
    final class TernaryCoverage {
        let tileOf: [Int]
        let mode: [UInt8]
        let isRegister: [Bool]
        /// Evaluations by kind: BINARY, TTABLE, TTHRESH.
        var evals = [0, 0, 0]
        /// Ternary outputs −1, 0, +1.
        var outTrits = [0, 0, 0]
        /// NOSKIP turned a ±1 opposite to the previous trit into 0.
        var noskipFired = 0
        /// TTHRESH sums equal to lo or hi (equality gives 0).
        var threshOnBound = 0
        /// Absent slots (nb < 0 or nb ≥ node count) of a ternary node.
        var absentIntoTernary = 0
        /// Present slots whose source sits in another tile (a ghost's read).
        var crossReads = 0
        /// Cross-tile reads by a ternary node, by the byte read: 0, 1, 2.
        var crossIntoTernaryByByte = [0, 0, 0]
        /// Cross-tile reads by a ternary node of a TERNARY source.
        var crossTernarySourceIntoTernary = 0
        /// Cross-tile reads of a Loom byte (≥ 3), any reader / ternary reader.
        var crossLoom = 0
        var crossLoomIntoTernary = 0
        /// Cross-tile reads of a register, any reader / ternary reader.
        var crossRegister = 0
        var crossRegisterIntoTernary = 0

        init(tileOf: [Int], mode: [UInt8], isRegister: [Bool]) {
            self.tileOf = tileOf
            self.mode = mode
            self.isRegister = isRegister
        }

        func add(_ o: TernaryCoverage) {
            for i in 0..<3 {
                evals[i] += o.evals[i]
                outTrits[i] += o.outTrits[i]
                crossIntoTernaryByByte[i] += o.crossIntoTernaryByByte[i]
            }
            noskipFired += o.noskipFired
            threshOnBound += o.threshOnBound
            absentIntoTernary += o.absentIntoTernary
            crossReads += o.crossReads
            crossTernarySourceIntoTernary += o.crossTernarySourceIntoTernary
            crossLoom += o.crossLoom
            crossLoomIntoTernary += o.crossLoomIntoTernary
            crossRegister += o.crossRegister
            crossRegisterIntoTernary += o.crossRegisterIntoTernary
        }

        var line: String {
            "evals(bin,ttable,tthresh)=\(evals) trits(-,0,+)=\(outTrits) noskip_fired=\(noskipFired) "
                + "thresh_on_bound=\(threshOnBound) absent_into_ternary=\(absentIntoTernary) "
                + "cross_reads=\(crossReads) cross_into_ternary_by_byte(0,1,2)=\(crossIntoTernaryByByte) "
                + "cross_ternary_src_into_ternary=\(crossTernarySourceIntoTernary) "
                + "cross_loom=\(crossLoom) cross_loom_into_ternary=\(crossLoomIntoTernary) "
                + "cross_register=\(crossRegister) cross_register_into_ternary=\(crossRegisterIntoTernary)"
        }
    }

    private static func tritA(_ b: UInt8) -> Int { b == 0 ? -1 : (b == 1 ? 1 : 0) }
    private static func byteA(_ t: Int) -> UInt8 { t < 0 ? 0 : (t > 0 ? 1 : 2) }

    /// The reads of one node, counted (coverage only; changes no value).
    private func observe(_ node: Int, kind: Int, _ cov: TernaryCoverage, _ read: (Int) -> UInt8) {
        for d in 0..<6 {
            let nb = Int(slots[node * 6 + d])
            if nb < 0 || nb >= nodeCount {
                if kind != 0 { cov.absentIntoTernary += 1 }
                continue
            }
            guard cov.tileOf[nb] != cov.tileOf[node] else { continue }
            let b = read(nb)
            cov.crossReads += 1
            if b >= 3 {
                cov.crossLoom += 1
                if kind != 0 { cov.crossLoomIntoTernary += 1 }
            }
            if cov.isRegister[nb] {
                cov.crossRegister += 1
                if kind != 0 { cov.crossRegisterIntoTernary += 1 }
            }
            if kind != 0 {
                if b < 3 { cov.crossIntoTernaryByByte[Int(b)] += 1 }
                if cov.mode[nb] != 0 { cov.crossTernarySourceIntoTernary += 1 }
            }
        }
    }

    /// One node's output byte reading `read(src)` for each present slot.
    private func evaluate(_ node: Int, _ L: TernaryLanes, previous: UInt8,
                          coverage cov: TernaryCoverage? = nil,
                          _ read: (Int) -> UInt8) -> UInt8 {
        let m = L.mode[node]
        if let cov {
            observe(node, kind: Int(m & 3), cov, read)
            cov.evals[Int(m & 3)] += 1
        }
        if m & 3 == 0 {
            var idx = 0
            for d in 0..<6 {
                let nb = Int(slots[node * 6 + d])
                if nb < 0 || nb >= nodeCount { continue }
                if read(nb) == 1 { idx |= 1 << d }
            }
            return idx < 32 ? UInt8((lutLow[node] >> UInt32(idx)) & 1)
                            : UInt8((lutHigh[node] >> UInt32(idx - 32)) & 1)
        }
        var out: Int
        if m & 3 == 1 {
            var idx = 0, p = 1
            for d in 0..<6 {
                let nb = Int(slots[node * 6 + d])
                let t = (nb < 0 || nb >= nodeCount) ? 0 : Self.tritA(read(nb))
                idx += p * (t + 1); p *= 3
            }
            let tid = Int(L.ttableId[node])
            out = tid < L.tables.count / 729 ? Self.tritA(L.tables[tid * 729 + idx]) : 0
        } else {
            var s: Float = 0
            for d in 0..<6 {
                let nb = Int(slots[node * 6 + d])
                if nb < 0 || nb >= nodeCount { continue }
                s = s + L.weights[node * 6 + d] * Float(Self.tritA(read(nb)))
            }
            out = s > L.thrHi[node] ? 1 : (s < L.thrLo[node] ? -1 : 0)
            if let cov, s == L.thrLo[node] || s == L.thrHi[node] { cov.threshOnBound += 1 }
        }
        if m & 4 != 0 {
            let p = Self.tritA(previous)
            if p != 0 && out == -p {
                out = 0
                cov?.noskipFired += 1
            }
        }
        cov?.outTrits[out + 1] += 1
        return Self.byteA(out)
    }

    private func latchT(_ t: inout [UInt8]) {
        guard !backEdgeSrc.isEmpty else { return }
        let snap = backEdgeSrc.map { t[$0] }
        for i in 0..<backEdgeDst.count { t[backEdgeDst[i]] = snap[i] }
    }

    /// Rank mode: levels highest-present → 0, in place, registers skipped,
    /// then the latch.
    func tickRank(_ truth: [UInt8], ternary L: TernaryLanes,
                  coverage cov: TernaryCoverage? = nil) -> [UInt8] {
        var t = truth
        var byLevel = [[Int]](repeating: [], count: Int(maxRankPresent) + 1)
        for i in 0..<nodeCount { byLevel[Int(rank[i])].append(i) }
        for r in stride(from: Int(maxRankPresent), through: 0, by: -1) {
            for node in byLevel[r] where !isRegister[node] {
                t[node] = evaluate(node, L, previous: t[node], coverage: cov) { t[$0] }
            }
        }
        latchT(&t)
        return t
    }

    /// Sync mode: every node from the previous vector, registers holding,
    /// then the latch.
    func tickSync(_ truth: [UInt8], ternary L: TernaryLanes,
                  coverage cov: TernaryCoverage? = nil) -> [UInt8] {
        var out = truth
        for node in 0..<nodeCount where !isRegister[node] {
            out[node] = evaluate(node, L, previous: truth[node], coverage: cov) { truth[$0] }
        }
        latchT(&out)
        return out
    }

    // MARK: - The mixed object

    /// SplitMix64 — the seeded stream the mixing pass draws from.
    struct R6SplitMix64 {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    static let r6WeightPool: [Float] = [1, -1, 0.5, 2, -2.5, 1e8, -1e8, 3.25]
    static let r6ThresholdPool: [Float] = [-2, -1.5, -1, -0.5, 0, 0.5, 1, 1.5, 2]

    /// The mixed object, made in place on a frozen TILING object's engine
    /// (TiledFixture.generate or .populate, side `side`): a library of the
    /// nine presets (random arity) and four random tables; per node a seeded
    /// kind — a third stay binary, a third TTABLE, a third TTHRESH — NOSKIP
    /// on half the ternary nodes, thresholds and weights from pools that land
    /// sums on the thresholds; registers stay binary.
    /// Then Loom bytes 3…255 on a quarter of the binary nodes and on
    /// every register, from a second stream so the first pass's draws are
    /// unchanged: a binary node reads a Loom byte as 0 and a ternary node as
    /// trit 0, the strips carry the byte whole, and a register's
    /// Loom byte is what its readers see before the first latch. And
    /// every register's back-edge source is made an oscillator in its own
    /// kind (see below), so no side's world goes static.
    static func mixTernary(engine e: DagDBEngine, side: Int) throws {
        var rng = R6SplitMix64(s: 0x7E16_0000 &+ UInt64(side))
        var tables: [UInt8] = []
        for p in TernaryReference.Preset.allCases {
            tables += try TernaryReference.presetTable(p, k: p.arities.upperBound == 1 ? 1 : 2 + rng.below(5))
        }
        for _ in 0..<4 { tables += (0..<729).map { _ in UInt8(rng.below(3)) } }
        try e.replaceLibrary(tables)
        let libSize = tables.count / 729
        let n = e.nodeCount
        let w = e.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        for i in 0..<n {
            let kind = rng.below(3)
            let noskip = rng.below(2) == 0
            let a = r6ThresholdPool[rng.below(r6ThresholdPool.count)]
            let b = r6ThresholdPool[rng.below(r6ThresholdPool.count)]
            e.thrLoPtr[i] = min(a, b); e.thrHiPtr[i] = max(a, b)
            e.ttableIdPtr[i] = UInt16(rng.below(libSize))
            for d in 0..<6 { w[i * 6 + d] = r6WeightPool[rng.below(r6WeightPool.count)] }
            guard kind != 0, !e.isRegister(node: UInt32(i)), truth[i] < 3 else { continue }
            e.modePtr[i] = UInt8(kind) | (noskip ? 4 : 0)
        }
        // Every register keeps oscillating, whatever kind its back-edge
        // source S drew. The fixture's pair is R ← S with S's only present
        // slot (slot 0) reading R; a BINARY S keeps the fixture's
        // complemented parity (S = ¬R, a Loom R reads 0). A TERNARY S is
        // given the rule "−1 if R reads +1, else +1": TTABLE S takes one
        // appended library table that is exactly that function of slot 0;
        // TTHRESH S takes w0 = −1 and lo = hi = −0.5 (s = −t: +1 for t ∈
        // {−1, 0}, −1 for t = +1). Without NOSKIP R then cycles 1, 0, 1, …;
        // with NOSKIP every opposite step passes through 0, so R cycles
        // through UNDEFINED (… 2, 1, 2, 1 …). Before this, a ternary S drew a
        // random table or threshold and side 16's only oscillator died: the
        // world went static after tick 3 (rank) and 8 (sync), and every
        // later equality on that side was free. Applied after the draws
        // above, so no other node's draw moves.
        let oscillatorTid = libSize
        tables += (0..<729).map { idx in idx % 3 == 2 ? UInt8(0) : UInt8(1) }
        try e.replaceLibrary(tables)
        for s in Set(e.backEdgeSrcs.map { Int($0) }) {
            switch e.modePtr[s] & 3 {
            case 1:
                e.ttableIdPtr[s] = UInt16(oscillatorTid)
            case 2:
                w[s * 6 + 0] = -1
                e.thrLoPtr[s] = -0.5
                e.thrHiPtr[s] = -0.5
            default:
                break
            }
        }
        var loom = R6SplitMix64(s: 0x7E16_1000 &+ UInt64(side))
        for i in 0..<n where e.modePtr[i] == 0 {
            let pick = loom.below(4)
            let byte = UInt8(3 + loom.below(253))
            if pick == 0 || e.isRegister(node: UInt32(i)) { truth[i] = byte }
        }
        precondition(e.ternaryStateViolation() == nil)
    }
}
