import XCTest
@testable import DagDB

/// Nested-LUT microcircuit acceptance test — the committed receipt for
/// "a multi-rank LUT6 network computes a continuous law exactly where a
/// single LUT6 provably cannot."
///
/// Ohm's V = I·R, 4-bit × 4-bit → exact 8-bit product, built as
/// 16 AND2 partial products reduced carry-save (Wallace) by XOR/MAJ
/// full/half adders. Product bits P3..P7 each depend on all 8 input
/// bits (exhaustive census in the edt prototype), so no single LUT6 —
/// which reads at most 6 — can compute them; the composed network must.
///
/// Python twin: 111_experiments/edt/prototypes/nested_lut/ (2026-07-01).
final class DagDBMicrocircuitTests: XCTestCase {

    // ── tiny netlist spec, mirrored from the Python compiler ─────────

    private enum Kind { case and2, xor2, xor3, maj3 }

    private struct Gate {
        let kind: Kind
        let srcs: [Int]
    }

    /// 64-bit LUT for a k-input gate, replicated over don't-care slots
    /// (absent neighbors read 0, so only low-slot bits ever fire).
    private static func lut(_ kind: Kind) -> UInt64 {
        func f(_ b: [Int]) -> Int {
            switch kind {
            case .and2: return b[0] & b[1]
            case .xor2: return b[0] ^ b[1]
            case .xor3: return b[0] ^ b[1] ^ b[2]
            case .maj3: return (b[0] + b[1] + b[2]) >= 2 ? 1 : 0
            }
        }
        let k = (kind == .and2 || kind == .xor2) ? 2 : 3
        var lut: UInt64 = 0
        for idx in 0..<64 {
            let bits = (0..<k).map { (idx >> $0) & 1 }
            if f(bits) == 1 { lut |= (1 << UInt64(idx)) }
        }
        return lut
    }

    /// Build the mult4 netlist: node ids 0..7 = I0..I3,R0..R3, then gates.
    /// Returns (gates by id, output ids P0..P7).
    private static func buildMult4() -> (gates: [Int: Gate], outputs: [Int]) {
        var gates: [Int: Gate] = [:]
        var next = 8
        func add(_ kind: Kind, _ srcs: [Int]) -> Int {
            gates[next] = Gate(kind: kind, srcs: srcs)
            next += 1
            return next - 1
        }

        // partial-product rows, row j shifted by j (bit-vecs: pos -> id)
        var rows: [[Int: Int]] = []
        for j in 0..<4 {
            var row: [Int: Int] = [:]
            for i in 0..<4 { row[i + j] = add(.and2, [i, 4 + j]) }
            rows.append(row)
        }

        // carry-save 3→2 compressor
        func csa(_ x: [Int: Int], _ y: [Int: Int], _ z: [Int: Int])
            -> ([Int: Int], [Int: Int]) {
            var s: [Int: Int] = [:], c: [Int: Int] = [:]
            for p in Set(x.keys).union(y.keys).union(z.keys).sorted() {
                let ins = [x[p], y[p], z[p]].compactMap { $0 }
                switch ins.count {
                case 3:
                    s[p] = add(.xor3, ins); c[p + 1] = add(.maj3, ins)
                case 2:
                    s[p] = add(.xor2, ins); c[p + 1] = add(.and2, ins)
                default:
                    s[p] = ins[0]                    // pass-through
                }
            }
            return (s, c)
        }

        // final ripple add of two bit-vectors
        func ripple(_ a: [Int: Int], _ b: [Int: Int]) -> [Int: Int] {
            var out: [Int: Int] = [:]
            var carry: Int? = nil
            let lo = min(a.keys.min() ?? 0, b.keys.min() ?? 0)
            let hi = max(a.keys.max() ?? 0, b.keys.max() ?? 0)
            for p in lo...hi {
                var ins = [a[p], b[p], carry].compactMap { $0 }
                switch ins.count {
                case 3:
                    out[p] = add(.xor3, ins); carry = add(.maj3, ins)
                case 2:
                    out[p] = add(.xor2, ins); carry = add(.and2, ins)
                case 1:
                    out[p] = ins[0]; carry = nil
                default:
                    break
                }
                ins.removeAll()
            }
            if let c = carry { out[(out.keys.max() ?? 0) + 1] = c }
            return out
        }

        let (s1, c1) = csa(rows[0], rows[1], rows[2])
        let (s2, c2) = csa(s1, c1, rows[3])
        let p = ripple(s2, c2)
        return (gates, (0..<8).map { p[$0]! })
    }

    /// Longest-path-to-consumer ranks: outputs 0, sources strictly above.
    private static func ranks(gates: [Int: Gate], nodeCount: Int) -> [Int] {
        var consumers: [[Int]] = Array(repeating: [], count: nodeCount)
        for (g, gate) in gates {
            for s in gate.srcs { consumers[s].append(g) }
        }
        var rank = [Int](repeating: -1, count: nodeCount)
        func compute(_ n: Int) -> Int {
            if rank[n] >= 0 { return rank[n] }
            rank[n] = consumers[n].isEmpty
                ? 0 : 1 + consumers[n].map(compute).max()!
            return rank[n]
        }
        for n in 0..<nodeCount { _ = compute(n) }
        return rank
    }

    // ── the acceptance test ──────────────────────────────────────────

    func testNestedLUTMult4ComputesExactProduct() throws {
        let (gates, outputs) = Self.buildMult4()
        let nodeCount = 8 + gates.count
        let rank = Self.ranks(gates: gates, nodeCount: nodeCount)

        XCTAssertEqual(gates.count, 40, "canonical mult4 netlist is 40 gates")
        let depth = rank.max()!
        XCTAssertLessThanOrEqual(depth, 15, "must fit maxRank 16")

        // Build the graph in id order so graph ids == spec ids.
        let g = DagDBGraph()
        for i in 0..<8 {
            let id = g.addLeaf(label: i < 4 ? "I\(i)" : "R\(i - 4)",
                               rank: UInt64(rank[i]), truth: false)
            XCTAssertEqual(id, i)
        }
        for id in 8..<nodeCount {
            let gate = gates[id]!
            let got = g.addGate(label: "g\(id)", rank: UInt64(rank[id]),
                                lut6: Self.lut(gate.kind))
            XCTAssertEqual(got, id)
        }
        for id in 8..<nodeCount {           // slot order == LUT bit order
            for s in gates[id]!.srcs {
                try g.connect(from: s, to: id)
            }
        }
        XCTAssertTrue(g.validate().isEmpty, "graph must validate clean")

        let engine = try DagDBEngine(graph: g)

        // Per vector: poke the 8 input leaves' LUTs to CONST0/CONST1
        // through the same buffers the daemon's SET LUT writes, then one
        // tick settles the whole combinational network.
        let low = engine.lut6LowBuf.contents().bindMemory(
            to: UInt32.self, capacity: engine.nodeCount)
        let high = engine.lut6HighBuf.contents().bindMemory(
            to: UInt32.self, capacity: engine.nodeCount)

        for v in 0..<256 {
            for b in 0..<8 {
                let one = (v >> b) & 1 == 1
                low[b] = one ? 0xFFFF_FFFF : 0
                high[b] = one ? 0xFFFF_FFFF : 0
            }
            engine.tick(tickNumber: UInt32(v + 1))
            let s = engine.readTruthStates()
            var got = 0
            for k in 0..<8 { got |= Int(s[outputs[k]]) << k }
            let iv = v & 0xF, rv = v >> 4
            XCTAssertEqual(got, iv * rv,
                           "I=\(iv) R=\(rv): network must be exact")
        }
    }
}
