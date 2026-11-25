import XCTest
@testable import DagDB

/// The CPU reference (control).
///
/// The expectations here are written from the RULES, not read back from
/// `TernaryReference`: each preset's formula, the trit view, the threshold
/// rule and the NOSKIP rule are restated below in this file's own words and
/// compared against what the reference computes — through its table
/// generator AND through its node evaluator, so a wrong evaluator cannot
/// hide behind a right table.
final class TernaryR2ReferenceTests: XCTestCase {

    // MARK: - The rules, restated

    /// The trit view: 0 → −1, 1 → +1, 2 → 0, ≥ 3 → 0.
    private func tritA(_ b: UInt8) -> Int {
        switch b { case 0: return -1; case 1: return 1; default: return 0 }
    }
    /// The trit view, back to bytes: −1 ↔ 0, 0 ↔ 2, +1 ↔ 1.
    private func byteA(_ t: Int) -> UInt8 {
        switch t { case -1: return 0; case 1: return 1; default: return 2 }
    }
    /// The table index: index = Σ 3^d · (t_d + 1); inputs enumerated in that order.
    private func tritsA(_ index: Int) -> [Int] {
        var v = index
        return (0..<6).map { _ in let t = v % 3 - 1; v /= 3; return t }
    }
    /// Each preset's formula on slots 0..<k.
    private func formulaA(_ name: String, _ k: Int, _ t: [Int]) -> Int {
        let a = Array(t.prefix(k))
        switch name {
        case "TMIN":  // Kleene AND: −1 dominates, then 0, else +1
            if a.contains(-1) { return -1 }
            if a.contains(0) { return 0 }
            return 1
        case "TMAX":  // Kleene OR: +1 dominates, then 0, else −1
            if a.contains(1) { return 1 }
            if a.contains(0) { return 0 }
            return -1
        case "TSUM":
            var s = 0
            for x in a { s += x }
            return s == 0 ? 0 : (s > 0 ? 1 : -1)
        case "TCONS":
            let first = a[0]
            if first == 0 { return 0 }
            for x in a where x != first { return 0 }
            return first
        case "TID": return a[0]
        case "TNEG": return -a[0]
        case "TCONST-1": return -1
        case "TCONST0": return 0
        case "TCONST+1": return 1
        default: fatalError(name)
        }
    }
    private let presetArities: [(String, ClosedRange<Int>)] = [
        ("TMIN", 1...6), ("TMAX", 1...6), ("TSUM", 1...6), ("TCONS", 1...6),
        ("TID", 1...1), ("TNEG", 1...1),
        ("TCONST-1", 1...6), ("TCONST0", 1...6), ("TCONST+1", 1...6),
    ]

    // MARK: - A one-node harness for the evaluator

    /// Node 0 is the node under test; nodes 1...6 are its six sources (slot
    /// d reads node d + 1). `bytes[d]` is source d's truth byte; `absent`
    /// slots are -1 (or `nodeCount + d` when `outOfRange`).
    private func harness(mode: UInt8, sourceBytes: [UInt8], absent: Set<Int> = [],
                         outOfRange: Set<Int> = [], weights: [Float] = Array(repeating: 1, count: 6),
                         lo: Float = 0, hi: Float = 0, tables: [UInt8] = [], tid: UInt16 = 0,
                         previous: UInt8 = 2) -> UInt8 {
        let n = 7
        var nb = [Int32](repeating: -1, count: n * 6)
        for d in 0..<6 {
            if absent.contains(d) { nb[d] = -1 }
            else if outOfRange.contains(d) { nb[d] = Int32(n + d) }
            else { nb[d] = Int32(d + 1) }
        }
        var truth = [UInt8](repeating: 0, count: n)
        truth[0] = previous
        for d in 0..<6 { truth[d + 1] = sourceBytes[d] }
        var w = [Float](repeating: 1, count: n * 6)
        for d in 0..<6 { w[d] = weights[d] }
        var mode7 = [UInt8](repeating: 0, count: n); mode7[0] = mode
        var tid7 = [UInt16](repeating: 0, count: n); tid7[0] = tid
        var lo7 = [Float](repeating: 0, count: n); lo7[0] = lo
        var hi7 = [Float](repeating: 0, count: n); hi7[0] = hi
        let g = TernaryReference.Graph(
            truth: truth, rank: [UInt64](repeating: 0, count: n),
            lutLow: [UInt32](repeating: 0, count: n), lutHigh: [UInt32](repeating: 0, count: n),
            neighbors: nb, isRegister: [UInt8](repeating: 0, count: n), edgeWeights: w,
            mode: mode7, ttableId: tid7, thrLo: lo7, thrHi: hi7, tables: tables,
            backEdgeSrcs: [], backEdgeDsts: [])
        return TernaryReference.evaluate(g, node: 0, read: truth, previous: previous)
    }

    // MARK: - Presets, exhaustively

    func testR2EveryPresetEveryArityAllInputs() throws {
        var checked = 0
        for (name, arities) in presetArities {
            let p = try XCTUnwrap(TernaryReference.Preset(rawValue: name), name)
            XCTAssertEqual(p.arities, arities, name)
            for k in arities {
                let table = try TernaryReference.presetTable(p, k: k)
                XCTAssertEqual(table.count, 729)
                for i in 0..<729 {
                    let t = tritsA(i)
                    let want = byteA(formulaA(name, k, t))
                    XCTAssertEqual(table[i], want, "\(name) k=\(k) index \(i) trits \(t)")
                    // Through the evaluator: a TTABLE node whose sources hold t.
                    let got = harness(mode: 1, sourceBytes: t.map(byteA), tables: table)
                    XCTAssertEqual(got, want, "evaluator \(name) k=\(k) index \(i)")
                    checked += 1
                }
            }
            // Arities outside the definition are refused by name.
            for k in [0, 7] where !arities.contains(k) {
                XCTAssertThrowsError(try TernaryReference.presetTable(p, k: k))
            }
            if name == "TID" || name == "TNEG" {
                XCTAssertThrowsError(try TernaryReference.presetTable(p, k: 2))
            }
        }
        // 7 presets × 6 arities + 2 presets × 1 arity, 729 inputs each.
        XCTAssertEqual(checked, (7 * 6 + 2 * 1) * 729)
        print("R2 presets: \(checked) (preset, k, input) cases equal to the formulas")
    }

    func testR2TableIndexIsTheLetter() {
        for i in 0..<729 {
            let t = tritsA(i)
            var idx = 0, p = 1
            for d in 0..<6 { idx += p * (t[d] + 1); p *= 3 }
            XCTAssertEqual(idx, i)
            XCTAssertEqual(TernaryReference.tableIndex(t), i)
            XCTAssertEqual(TernaryReference.trits(ofIndex: i), t)
        }
    }

    // MARK: - TTHRESH at and around its edges

    func testR2ThresholdEdges() {
        let lo: Float = -1.5, hi: Float = 2.0
        // One present slot reading +1 with weight w gives s = w exactly;
        // reading −1 gives s = −w. The other five slots are absent.
        func eval(_ w: Float, sign: Int, extraAbsentWeight: Float = 1000) -> UInt8 {
            var weights = [Float](repeating: extraAbsentWeight, count: 6)
            weights[0] = w
            return harness(mode: 2, sourceBytes: [byteA(sign), 1, 1, 1, 1, 1],
                           absent: [1, 2, 3, 4, 5], weights: weights, lo: lo, hi: hi)
        }
        // s = hi → 0 (equality gives 0); just above → +1; just below → 0.
        XCTAssertEqual(eval(hi, sign: 1), byteA(0))
        XCTAssertEqual(eval(hi.nextUp, sign: 1), byteA(1))
        XCTAssertEqual(eval(hi.nextDown, sign: 1), byteA(0))
        // s = lo → 0; just below → −1; just above → 0.
        XCTAssertEqual(eval(-lo, sign: -1), byteA(0))                 // s = −1.5
        XCTAssertEqual(eval((-lo).nextUp, sign: -1), byteA(-1))       // s just below lo
        XCTAssertEqual(eval((-lo).nextDown, sign: -1), byteA(0))      // s just above lo
        // Absent slots contribute nothing even with huge weights; the same
        // weights on PRESENT slots reading +1 would push s over hi.
        XCTAssertEqual(eval(0, sign: 1, extraAbsentWeight: 1e30), byteA(0))
        let present = harness(mode: 2, sourceBytes: [1, 1, 1, 1, 1, 1],
                              weights: [0, 1e30, 0, 0, 0, 0], lo: lo, hi: hi)
        XCTAssertEqual(present, byteA(1))
        // An out-of-range slot (nb ≥ node count) is absent too.
        let oor = harness(mode: 2, sourceBytes: [1, 1, 1, 1, 1, 1], outOfRange: [1],
                          weights: [0, 1e30, 0, 0, 0, 0], lo: lo, hi: hi)
        XCTAssertEqual(oor, byteA(0))
        // A zero trit times a weight adds nothing: sources reading UNDEFINED.
        XCTAssertEqual(harness(mode: 2, sourceBytes: [2, 2, 2, 2, 2, 2],
                               weights: [5, 5, 5, 5, 5, 5], lo: lo, hi: hi), byteA(0))
        // The sum runs in slot order in f32: 1e8 + 1 − 1e8 = 0 (the 1 is
        // absorbed), not 1 — the order is the definition.
        let order = harness(mode: 2, sourceBytes: [1, 1, 0, 1, 1, 1], absent: [3, 4, 5],
                            weights: [1e8, 1, 1e8, 0, 0, 0], lo: -0.5, hi: 0.5)
        XCTAssertEqual(order, byteA(0))
        // Refusals of the lanes themselves.
        XCTAssertNil(TernaryReference.thresholdRefusal(lo: lo, hi: hi))
        XCTAssertNil(TernaryReference.thresholdRefusal(lo: 1, hi: 1))
        XCTAssertNotNil(TernaryReference.thresholdRefusal(lo: 2, hi: 1))
        XCTAssertNotNil(TernaryReference.thresholdRefusal(lo: .nan, hi: 1))
        XCTAssertNotNil(TernaryReference.thresholdRefusal(lo: 0, hi: .nan))
        XCTAssertNotNil(TernaryReference.thresholdRefusal(lo: -.infinity, hi: 1))
    }

    // MARK: - NOSKIP, all nine pairs

    func testR2NoskipAllNinePairs() throws {
        var cases = 0
        for prev in [-1, 0, 1] {
            for comp in [-1, 0, 1] {
                let want = (prev != 0 && comp == -prev) ? 0 : comp
                XCTAssertEqual(TernaryReference.noskip(previous: prev, computed: comp), want,
                               "prev \(prev) comp \(comp)")
                // Through the evaluator: TTABLE TCONST<comp> with NOSKIP, the
                // node's previous byte encoding `prev`.
                let name = comp < 0 ? "TCONST-1" : (comp > 0 ? "TCONST+1" : "TCONST0")
                let table = try TernaryReference.presetTable(
                    try XCTUnwrap(TernaryReference.Preset(rawValue: name)), k: 1)
                let withNoskip = harness(mode: 1 | 4, sourceBytes: [2, 2, 2, 2, 2, 2],
                                         tables: table, previous: byteA(prev))
                XCTAssertEqual(withNoskip, byteA(want), "evaluator NOSKIP prev \(prev) comp \(comp)")
                let without = harness(mode: 1, sourceBytes: [2, 2, 2, 2, 2, 2],
                                      tables: table, previous: byteA(prev))
                XCTAssertEqual(without, byteA(comp))
                cases += 1
            }
        }
        XCTAssertEqual(cases, 9)
        // A Loom byte as the previous value is "unknown" (0): no skip.
        let table = try TernaryReference.presetTable(.tconstPos, k: 1)
        XCTAssertEqual(harness(mode: 5, sourceBytes: [2, 2, 2, 2, 2, 2], tables: table, previous: 200),
                       byteA(1))
    }

    // MARK: - Loom bytes ≥ 3 read as 0

    func testR2LoomBytesReadAsZero() throws {
        let tid = try TernaryReference.presetTable(.tid, k: 1)
        for b in 0...255 {
            let byte = UInt8(b)
            XCTAssertEqual(TernaryReference.trit(ofByte: byte), tritA(byte))
            let got = harness(mode: 1, sourceBytes: [byte, 2, 2, 2, 2, 2], tables: tid)
            XCTAssertEqual(got, byteA(tritA(byte)), "byte \(b)")
            if b >= 3 { XCTAssertEqual(got, 2, "Loom byte \(b) must read as 0") }
        }
        // And through TTHRESH: a Loom byte contributes w · 0.
        XCTAssertEqual(harness(mode: 2, sourceBytes: [7, 2, 2, 2, 2, 2],
                               weights: [10, 0, 0, 0, 0, 0], lo: -1, hi: 1), byteA(0))
    }

    // MARK: - The mode lane

    func testR2ModeByteLegalSet() {
        var legal: [UInt8] = []
        for m in 0...255 where TernaryReference.modeRefusal(UInt8(m)) == nil { legal.append(UInt8(m)) }
        // Kinds 0/1/2, NOSKIP only on 1/2, bits 3–7 zero.
        XCTAssertEqual(legal, [0, 1, 2, 5, 6])
    }

    // MARK: - Binary nodes evaluate as the LUT6 kernel does

    func testR2BinaryNodeIsTheLUT6Rule() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let bytes = (0..<6).map { _ in UInt8.random(in: 0...255, using: &rng) }
            let lut = UInt64.random(in: 0...UInt64.max, using: &rng)
            var bits = 0
            for d in 0..<6 where bytes[d] == 1 { bits |= 1 << d }
            let want = UInt8((lut >> UInt64(bits)) & 1)
            let n = 7
            var nb = [Int32](repeating: -1, count: n * 6)
            for d in 0..<6 { nb[d] = Int32(d + 1) }
            var truth = [UInt8](repeating: 0, count: n)
            for d in 0..<6 { truth[d + 1] = bytes[d] }
            var low = [UInt32](repeating: 0, count: n), high = low
            low[0] = UInt32(lut & 0xFFFF_FFFF); high[0] = UInt32(lut >> 32)
            let g = TernaryReference.Graph(
                truth: truth, rank: [UInt64](repeating: 0, count: n), lutLow: low, lutHigh: high,
                neighbors: nb, isRegister: [UInt8](repeating: 0, count: n),
                edgeWeights: [Float](repeating: 1, count: n * 6), mode: [UInt8](repeating: 0, count: n),
                ttableId: [UInt16](repeating: 0, count: n), thrLo: [Float](repeating: 0, count: n),
                thrHi: [Float](repeating: 0, count: n), tables: [], backEdgeSrcs: [], backEdgeDsts: [])
            XCTAssertEqual(TernaryReference.evaluate(g, node: 0, read: truth, previous: 0), want)
        }
    }

    // MARK: - COMPOSE on tables is pointwise

    func testR2ComposeTablesPointwise() throws {
        let a = try TernaryReference.presetTable(.tsum, k: 3)
        let b = try TernaryReference.presetTable(.tcons, k: 2)
        let and = try XCTUnwrap(TernaryReference.composeTables(op: "AND", a, b))
        let or = try XCTUnwrap(TernaryReference.composeTables(op: "OR", a, b))
        let not = try XCTUnwrap(TernaryReference.composeTables(op: "NOT", a, nil))
        for i in 0..<729 {
            XCTAssertEqual(and[i], byteA(min(tritA(a[i]), tritA(b[i]))))
            XCTAssertEqual(or[i], byteA(max(tritA(a[i]), tritA(b[i]))))
            XCTAssertEqual(not[i], byteA(-tritA(a[i])))
        }
        XCTAssertNil(TernaryReference.composeTables(op: "XOR", a, b))
    }
}
