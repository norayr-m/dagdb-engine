import XCTest
@testable import DagDB

/// TTHRESH arithmetic under flush-to-zero.
///
/// The rule, restated: TTHRESH arithmetic flushes to zero. Every operand
/// (each w_d, lo, hi) and every partial sum s, after each addition in
/// slot order, is replaced by a zero of the same sign
/// when it is subnormal, before the comparison. Signed zeros compare equal.
///
/// Two checks, both CPU (the reference) == GPU (rank and sync; the bundle's
/// library and the forced inline source; the general kernels — a graph with
/// a ternary node never takes the binary-only fast path):
///   · added to the reference cases (`TernaryR2ReferenceTests`): every case over a boundary set B of 16 values (±0,
///     the least, a middle and the largest subnormal, the least normal and
///     its successor, 1.5·2^-126 and 2^-125, both signs) — one, two and three
///     present slots, each weight from B, each trit ±1 (and 0 with one
///     slot), each threshold pair lo ≤ hi from B — with the reference and the
///     GPU also checked against the rule restated in this file;
///   · added to the GPU-against-CPU sweep (`TernaryR3KernelTests`): its own
///     objects, sizes, seeds, modes and checkpoints, with weights and
///     thresholds redrawn from its pools plus subnormal and
///     least-normal values.
final class TernaryA6SubnormalR2Tests: XCTestCase {

    // MARK: - The rule, restated in this file's own words

    /// A subnormal (exponent bits 0, mantissa not 0) becomes the zero of its sign.
    @inline(__always) static func flushA(_ x: Float) -> Float {
        let b = x.bitPattern
        if b & 0x7F80_0000 == 0 && b & 0x007F_FFFF != 0 { return Float(bitPattern: b & 0x8000_0000) }
        return x
    }

    /// One case: k present slots in slot order, weight w_d and trit t_d.
    struct Case {
        var k: Int
        var w0: Float, w1: Float, w2: Float
        var t0: Int, t1: Int, t2: Int
        var lo: Float, hi: Float
        var pattern: Int
        func w(_ d: Int) -> Float { d == 0 ? w0 : (d == 1 ? w1 : w2) }
        func t(_ d: Int) -> Int { d == 0 ? t0 : (d == 1 ? t1 : t2) }
    }

    /// The TTHRESH rule, with the flush to zero.
    @_optimize(speed) static func letterA(_ c: Case) -> Int {
        var s: Float = 0
        for d in 0..<c.k { s = flushA(s + flushA(c.w(d)) * Float(c.t(d))) }
        let lo = flushA(c.lo), hi = flushA(c.hi)
        if s > hi { return 1 }
        if s < lo { return -1 }
        return 0
    }

    /// The TTHRESH rule as it was before the flush (no flush). Counted only: the cases where it
    /// differs from `letterA` are the ones this test decides.
    @_optimize(speed) static func letterBefore(_ c: Case) -> Int {
        var s: Float = 0
        for d in 0..<c.k { s = s + c.w(d) * Float(c.t(d)) }
        if s > c.hi { return 1 }
        if s < c.lo { return -1 }
        return 0
    }

    @inline(__always) static func byteA(_ t: Int) -> UInt8 { t < 0 ? 0 : (t > 0 ? 1 : 2) }

    // MARK: - The boundary set and the case enumeration

    static let magnitudes: [Float] = [
        0,
        Float(bitPattern: 0x0000_0001),   // 2^-149, the least subnormal
        Float(bitPattern: 0x0040_0000),   // 2^-127, a middle subnormal
        Float(bitPattern: 0x007F_FFFF),   // 2^-126 − 2^-149, the largest subnormal
        Float(bitPattern: 0x0080_0000),   // 2^-126, the least normal
        Float(bitPattern: 0x0080_0001),   // its successor (minus 2^-126 → 2^-149)
        Float(bitPattern: 0x00C0_0000),   // 1.5·2^-126 (minus 2^-126 → 2^-127)
        Float(bitPattern: 0x0100_0000),   // 2^-125 (minus 1.5·2^-126 → 2^-127)
    ]
    /// B: the eight magnitudes with both signs (−0 included), 16 values.
    static let boundary: [Float] = magnitudes + magnitudes.map { Float(bitPattern: $0.bitPattern | 0x8000_0000) }
    /// Every (lo, hi) from B with lo ≤ hi — the legal threshold pairs.
    static let pairs: [(Float, Float)] = {
        var out: [(Float, Float)] = []
        for a in boundary { for b in boundary where a <= b { out.append((a, b)) } }
        return out
    }()
    static var n1: Int { boundary.count * 3 * pairs.count }
    static var n2: Int { boundary.count * boundary.count * 4 * pairs.count }
    static var n3: Int { boundary.count * boundary.count * boundary.count * 8 * pairs.count }
    static var caseCount: Int { n1 + n2 + n3 }

    @_optimize(speed) static func caseAt(_ c: Int) -> Case {
        let B = boundary, P = pairs.count, nb = B.count
        var r: Int
        var out = Case(k: 0, w0: 0, w1: 0, w2: 0, t0: 0, t1: 0, t2: 0, lo: 0, hi: 0, pattern: c % 3)
        if c < n1 {
            r = c
            (out.lo, out.hi) = pairs[r % P]; r /= P
            out.k = 1; out.t0 = r % 3 - 1; r /= 3
            out.w0 = B[r]
        } else if c < n1 + n2 {
            r = c - n1
            (out.lo, out.hi) = pairs[r % P]; r /= P
            out.k = 2
            let tb = r % 4; r /= 4
            out.t0 = tb & 1 != 0 ? 1 : -1; out.t1 = tb & 2 != 0 ? 1 : -1
            out.w1 = B[r % nb]; out.w0 = B[r / nb]
        } else {
            r = c - n1 - n2
            (out.lo, out.hi) = pairs[r % P]; r /= P
            out.k = 3
            let tb = r % 8; r /= 8
            out.t0 = tb & 1 != 0 ? 1 : -1; out.t1 = tb & 2 != 0 ? 1 : -1; out.t2 = tb & 4 != 0 ? 1 : -1
            out.w2 = B[r % nb]; r /= nb
            out.w1 = B[r % nb]; out.w0 = B[r / nb]
        }
        return out
    }

    /// Where the k present slots sit: pattern 0 the first k slots, pattern 1
    /// the last k, pattern 2 spread. Every other slot is absent: −1 at even
    /// slots, ≥ node count at odd ones (`makeGraph`).
    static func presentSlots(k: Int, pattern: Int) -> [Int] {
        switch pattern {
        case 0: return Array(0..<k)
        case 1: return Array((6 - k)..<6)
        default: return k == 1 ? [3] : (k == 2 ? [1, 4] : [0, 2, 5])
        }
    }

    // MARK: - The graphs

    /// Side 1024: 1,048,576 nodes. Nodes 0, 1, 2 are TTABLE constants at rank
    /// 1 (TCONST-1, TCONST0, TCONST+1; bytes 0, 2, 1), every other node a
    /// TTHRESH case at rank 0 reading them; unused nodes stay BINARY (LUT 0).
    static let side = 1024

    @_optimize(speed)
    static func makeGraph(grid: HexGrid, colors: [UInt8], first: Int, count: Int) throws -> TernaryR3KernelTests.Mixed {
        let n = grid.nodeCount
        var truth = [UInt8](repeating: 0, count: n)
        var rank = [UInt64](repeating: 0, count: n)
        var mode = [UInt8](repeating: 0, count: n)
        var tid = [UInt16](repeating: 0, count: n)
        var lo = [Float](repeating: 0, count: n), hi = lo
        var w = [Float](repeating: 1, count: n * 6)
        var nb = [Int32](repeating: -1, count: n * 6)
        let tables = try TernaryReference.presetTable(.tconstNeg, k: 1)
            + TernaryReference.presetTable(.tconstZero, k: 1)
            + TernaryReference.presetTable(.tconstPos, k: 1)
        for s in 0..<3 {
            rank[s] = 1; mode[s] = TernaryReference.kindTTable; tid[s] = UInt16(s)
            truth[s] = [UInt8(0), 2, 1][s]
        }
        for j in 0..<count {
            let node = 3 + j
            let c = caseAt(first + j)
            mode[node] = TernaryReference.kindTThresh
            truth[node] = 2
            lo[node] = c.lo; hi[node] = c.hi
            let slots = presentSlots(k: c.k, pattern: c.pattern)
            for d in 0..<6 { nb[node * 6 + d] = d % 2 == 0 ? -1 : Int32(n + d) }
            for (i, d) in slots.enumerated() {
                nb[node * 6 + d] = Int32(c.t(i) + 1)          // source node of trit t
                w[node * 6 + d] = c.w(i)
            }
        }
        let g = TernaryReference.Graph(
            truth: truth, rank: rank, lutLow: [UInt32](repeating: 0, count: n),
            lutHigh: [UInt32](repeating: 0, count: n), neighbors: nb,
            isRegister: [UInt8](repeating: 0, count: n), edgeWeights: w, mode: mode, ttableId: tid,
            thrLo: lo, thrHi: hi, tables: tables, backEdgeSrcs: [], backEdgeDsts: [])
        return TernaryR3KernelTests.Mixed(grid: grid, ref: g, colorOf: colors)
    }

    struct CheckResult {
        var perK = [0, 0, 0], decisive = [0, 0, 0]
        var mismatch: [String: Int] = [:]
        var examples: [String] = []
        var helperCases = 0
    }

    /// Each case of one graph: the restated rule (`letterA`) against the
    /// reference's truth, every GPU truth, and the reference's `thresholdSum` /
    /// `threshold`; the rule before the flush (`letterBefore`) only counted.
    @_optimize(speed)
    static func checkCases(first: Int, count: Int, reference: [UInt8], gpuNames: [String],
                           gpu: [[UInt8]]) -> CheckResult {
        var r = CheckResult()
        func miss(_ what: String, _ detail: @autoclosure () -> String) {
            r.mismatch[what, default: 0] += 1
            if r.examples.count < 12 { r.examples.append("\(what): \(detail())") }
        }
        var trits = [0, 0, 0, 0, 0, 0], present = [false, false, false, false, false, false]
        var weights = [Float](repeating: 1, count: 6)
        for j in 0..<count {
            let node = 3 + j
            let c = caseAt(first + j)
            let a = letterA(c)
            let want = byteA(a)
            r.perK[c.k - 1] += 1
            if letterBefore(c) != a { r.decisive[c.k - 1] += 1 }
            if reference[node] != want {
                miss("reference vs letter", "case \(first + j) \(c) letter \(want) reference \(reference[node])")
            }
            for q in 0..<gpu.count where gpu[q][node] != want {
                miss("GPU \(gpuNames[q]) vs letter", "case \(first + j) \(c) letter \(want) gpu \(gpu[q][node])")
            }
            // thresholdSum + threshold, the reference's public form of the TTHRESH rule.
            for d in 0..<6 { trits[d] = 0; present[d] = false; weights[d] = 1 }
            for (i, d) in presentSlots(k: c.k, pattern: c.pattern).enumerated() {
                trits[d] = c.t(i); present[d] = true; weights[d] = c.w(i)
            }
            let s = TernaryReference.thresholdSum(trits: trits, present: present, weights: weights)
            if byteA(TernaryReference.threshold(sum: s, lo: c.lo, hi: c.hi)) != want {
                miss("thresholdSum/threshold vs letter", "case \(first + j) \(c)")
            }
            r.helperCases += 1
        }
        return r
    }

    // MARK: - The gate

    func testR2SubnormalBoundaryExhaustiveCPUEqualsGPU() throws {
        let grid = try HexGrid(width: Self.side, height: Self.side)
        let colors = TernaryR3KernelTests.colorOf(grid)
        let perGraph = grid.nodeCount - 3
        let total = Self.caseCount
        XCTAssertEqual(Self.boundary.count, 16)
        XCTAssertEqual(Self.pairs.count, 137)
        var decisive = [0, 0, 0], perK = [0, 0, 0]
        var mismatch: [String: Int] = [:]
        var examples: [String] = []
        func miss(_ what: String, _ detail: @autoclosure () -> String) {
            mismatch[what, default: 0] += 1
            if examples.count < 12 { examples.append("\(what): \(detail())") }
        }
        // The public helpers (the TTHRESH rule's sum and comparison) against the restated rule.
        var helperCases = 0
        let t0 = Date()
        var first = 0
        var graphs = 0
        while first < total {
            let count = min(perGraph, total - first)
            let m = try Self.makeGraph(grid: grid, colors: colors, first: first, count: count)
            var refRank = m.ref, refSync = m.ref
            TernaryReference.tickRank(&refRank, tickNumber: 0, colorOf: colors, colorCount: HexGrid.colorCount)
            TernaryReference.tickSync(&refSync)
            var gpu: [String: [UInt8]] = [:]
            for (lname, lib) in [("bundle", DagDBEngine.ShaderLibrary.automatic), ("inline", .inlineSource)] {
                for mode in ["rank", "sync"] {
                    let e = try TernaryR3KernelTests.makeEngine(m, library: lib)
                    XCTAssertEqual(e.usedInlineShader, lname == "inline")
                    if mode == "rank" { e.tick(tickNumber: 0) } else { e.tickSync(tickNumber: 0) }
                    XCTAssertEqual(e.lastTickKernel, .general, "a graph with ternary nodes takes the general kernel")
                    gpu["\(lname) \(mode)"] = e.readTruthStates()
                }
            }
            for (key, g) in gpu {
                let ref = key.hasSuffix("rank") ? refRank.truth : refSync.truth
                if g != ref { miss("GPU \(key) vs reference", TernaryR3KernelTests.firstDiff(g, ref)) }
            }
            if refRank.truth != refSync.truth { miss("reference rank vs sync", TernaryR3KernelTests.firstDiff(refRank.truth, refSync.truth)) }
            let named = gpu.sorted { $0.key < $1.key }
            let r = Self.checkCases(first: first, count: count, reference: refRank.truth,
                                    gpuNames: named.map { $0.key }, gpu: named.map { $0.value })
            for k in 0..<3 { perK[k] += r.perK[k]; decisive[k] += r.decisive[k] }
            for (what, n) in r.mismatch { mismatch[what, default: 0] += n }
            for e in r.examples where examples.count < 12 { examples.append(e) }
            helperCases += r.helperCases
            first += count
            graphs += 1
        }
        XCTAssertEqual(perK, [Self.n1, Self.n2, Self.n3])
        XCTAssertEqual(helperCases, total)
        // The object can fail: the rule before the flush differs from the restated one
        // on cases of every arity.
        XCTAssertTrue(decisive.allSatisfy { $0 > 0 }, "decisive \(decisive)")
        XCTAssertTrue(mismatch.isEmpty, "mismatches \(mismatch.sorted { $0.key < $1.key }) e.g. \(examples)")
        print("A6 R2 subnormal cases=\(total) (k1=\(Self.n1) k2=\(Self.n2) k3=\(Self.n3)) graphs=\(graphs) " +
              "decisive k1=\(decisive[0]) k2=\(decisive[1]) k3=\(decisive[2]) " +
              "mismatches=\(mismatch.isEmpty ? "none" : "\(mismatch.sorted { $0.key < $1.key })") " +
              String(format: "%.1fs", Date().timeIntervalSince(t0)))
        for e in examples { print("A6 R2 example \(e)") }
    }
}

/// The GPU-against-CPU sweep of `TernaryR3KernelTests` with subnormal values
/// in the weight and threshold pools. Its own objects — kinds, NOSKIP, registers, back
/// edges, absent slots of both shapes, Loom bytes — from its generator with
/// its seeds shifted; then every node's weights and thresholds are redrawn
/// from a second stream over its pools plus the values below. 20 seeds ×
/// 64², 256², 1024²; rank and sync; N ∈ {1, 5, 20}; GPU (bundle) == CPU
/// reference, forced inline == bundle, `tickLegacy` == `tick`.
final class TernaryA6SubnormalR3Tests: XCTestCase {

    static let subnormalWeights: [Float] = [
        Float(bitPattern: 0x0000_0001), Float(bitPattern: 0x8000_0001),     // ±2^-149
        Float(bitPattern: 0x0040_0000), Float(bitPattern: 0x8040_0000),     // ±2^-127
        Float(bitPattern: 0x007F_FFFF), Float(bitPattern: 0x807F_FFFF),     // ±the largest subnormal
        Float(bitPattern: 0x0080_0000), Float(bitPattern: 0x8080_0000),     // ±2^-126 (normal)
        Float(bitPattern: 0x00C0_0000), Float(bitPattern: 0x80C0_0000),     // ±1.5·2^-126 (normal)
    ]
    static let subnormalThresholds: [Float] = [
        Float(bitPattern: 0x0000_0001), Float(bitPattern: 0x8000_0001),
        Float(bitPattern: 0x0040_0000), Float(bitPattern: 0x8040_0000),
        Float(bitPattern: 0x007F_FFFF), Float(bitPattern: 0x807F_FFFF),
        Float(bitPattern: 0x0080_0000), Float(bitPattern: 0x8080_0000),
        Float(bitPattern: 0x8000_0000),                                     // −0
    ]
    static let weightPool = TernaryR3KernelTests.weightPool + subnormalWeights
    static let thresholdPool = TernaryR3KernelTests.thresholdPool + subnormalThresholds

    static func makeMixed(grid: HexGrid, colorOf: [UInt8], seed: UInt64) -> TernaryR3KernelTests.Mixed {
        let base = TernaryR3KernelTests.makeMixed(grid: grid, colorOf: colorOf, seed: seed)
        var g = base.ref
        var rng = TernaryR3KernelTests.SplitMix64(s: seed ^ 0xA6A6_A6A6_A6A6_A6A6)
        for i in 0..<g.nodeCount {
            let a = thresholdPool[rng.below(thresholdPool.count)]
            let b = thresholdPool[rng.below(thresholdPool.count)]
            g.thrLo[i] = a <= b ? a : b; g.thrHi[i] = a <= b ? b : a
            for d in 0..<6 { g.edgeWeights[i * 6 + d] = weightPool[rng.below(weightPool.count)] }
        }
        return TernaryR3KernelTests.Mixed(grid: grid, ref: g, colorOf: colorOf)
    }

    /// TTHRESH nodes whose first sync evaluation the flush decides: the restated
    /// rule with and without the flush differ on the object's initial truth.
    static func decisiveAtFirstSyncTick(_ m: TernaryR3KernelTests.Mixed) -> Int {
        let g = m.ref
        var count = 0
        let flush = TernaryA6SubnormalR2Tests.flushA
        for i in 0..<g.nodeCount where g.mode[i] & 3 == 2 && g.isRegister[i] == 0 {
            var s: Float = 0, sOld: Float = 0
            for d in 0..<6 {
                let nb = Int(g.neighbors[i * 6 + d])
                if nb < 0 || nb >= g.nodeCount { continue }
                let b = g.truth[nb]
                let t: Float = b == 0 ? -1 : (b == 1 ? 1 : 0)
                let w = g.edgeWeights[i * 6 + d]
                s = flush(s + flush(w) * t)
                sOld = sOld + w * t
            }
            let lo = flush(g.thrLo[i]), hi = flush(g.thrHi[i])
            let now = s > hi ? 1 : (s < lo ? -1 : 0)
            let before = sOld > g.thrHi[i] ? 1 : (sOld < g.thrLo[i] ? -1 : 0)
            if now != before { count += 1 }
        }
        return count
    }

    func testR3SubnormalPoolsGPUEqualsCPUReferenceAndInlineAndLegacy() throws {
        var cells = 0
        var ternaryMoves = 0
        var decisive = 0
        var failures: [String] = []
        let modes = ["rank", "sync"]
        let checkpoints = TernaryR3KernelTests.checkpoints
        for side in TernaryR3KernelTests.sides {
            let grid = try HexGrid(width: side, height: side)
            let colors = TernaryR3KernelTests.colorOf(grid)
            let t0 = Date()
            let seeds = TernaryR3KernelTests.seedsPerSize
            var graphs = [TernaryR3KernelTests.Mixed?](repeating: nil, count: seeds)
            var expected = [TernaryR3KernelTests.Expected?](repeating: nil, count: seeds * modes.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: seeds) { s in
                let seed = UInt64(0x7E1A_6000_0000) &+ UInt64(side) << 8 &+ UInt64(s)
                let m = Self.makeMixed(grid: grid, colorOf: colors, seed: seed)
                lock.lock(); graphs[s] = m; lock.unlock()
            }
            DispatchQueue.concurrentPerform(iterations: expected.count) { j in
                let e = TernaryR3KernelTests.reference(graphs[j / modes.count]!, mode: modes[j % modes.count])
                lock.lock(); expected[j] = e; lock.unlock()
            }
            var sideDecisive = 0
            for s in 0..<seeds {
                let m = graphs[s]!
                sideDecisive += Self.decisiveAtFirstSyncTick(m)
                // One autorelease pool per (seed, mode), so what the engines'
                // setup and ticks autorelease is freed here, not when the method returns.
                for (mi, mode) in modes.enumerated() { try autoreleasepool {
                    let exp = expected[s * modes.count + mi]!
                    ternaryMoves += exp.ternaryMoves
                    let gpu = try TernaryR3KernelTests.makeEngine(m)
                    let inl = try TernaryR3KernelTests.makeEngine(m, library: .inlineSource)
                    XCTAssertFalse(gpu.usedInlineShader)
                    XCTAssertTrue(inl.usedInlineShader)
                    let legacy = mode == "rank" ? try TernaryR3KernelTests.makeEngine(m) : nil
                    for t in 0..<checkpoints.last! {
                        if mode == "rank" {
                            gpu.tick(tickNumber: UInt32(t))
                            inl.tick(tickNumber: UInt32(t))
                            legacy!.tickLegacy(tickNumber: UInt32(t))
                        } else {
                            gpu.tickSync(tickNumber: UInt32(t))
                            inl.tickSync(tickNumber: UInt32(t))
                        }
                        guard let want = exp.atCheckpoint[t + 1] else { continue }
                        let g = gpu.readTruthStates()
                        let iv = inl.readTruthStates()
                        if g != want { failures.append("side \(side) seed \(s) \(mode) N=\(t + 1) GPU vs CPU: \(TernaryR3KernelTests.firstDiff(g, want))") }
                        if iv != g { failures.append("side \(side) seed \(s) \(mode) N=\(t + 1) inline vs bundle: \(TernaryR3KernelTests.firstDiff(iv, g))") }
                        if let l = legacy {
                            let lv = l.readTruthStates()
                            if lv != g { failures.append("side \(side) seed \(s) N=\(t + 1) tickLegacy vs tick: \(TernaryR3KernelTests.firstDiff(lv, g))") }
                        }
                        cells += 1
                    }
                } }
            }
            decisive += sideDecisive
            XCTAssertGreaterThan(sideDecisive, 0, "side \(side): no node's first evaluation is decided by the flush")
            print(String(format: "A6 R3 side=%d seeds=%d decisive_at_tick1=%d total %.1fs", side, seeds, sideDecisive,
                         Date().timeIntervalSince(t0)))
        }
        XCTAssertEqual(cells, TernaryR3KernelTests.sides.count * TernaryR3KernelTests.seedsPerSize * 2 * checkpoints.count)
        XCTAssertGreaterThan(ternaryMoves, 0)
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures, first: \(failures.prefix(8))")
        print("A6 R3 subnormal cells=\(cells) failures=\(failures.count) ternary_node_changes=\(ternaryMoves) decisive_at_tick1=\(decisive)")
        for f in failures.prefix(8) { print("A6 R3 failure \(f)") }
    }
}
