/// E3Ladder — the exact tier ladder ON the engine, per CONTRACT_E3_FROZEN.md
/// (held outside this repository, frozen 2026-08-26).
///
/// Builder's half: topology, weights, leaks and ranks live in ENGINE lanes
/// (neighborsBuf, edgeWeightsBuf, nodeValueBuf as leak carrier, rankBuf);
/// fold arithmetic in Float64 via Accelerate; the reduced operator and the
/// folded sources are STORED to Float32 after every fold (the fabric the
/// court judges). Raw outputs only — the judge owns every ratio.
///
/// Usage:
///   e3-ladder control <out_dir>
///   e3-ladder ladder G1|G2 <out_dir>
///   (stress row: e3-ladder ladder G1_stress|G2_stress <out_dir>)

import Foundation
import DagDB
import Accelerate

let LCG_A: UInt64 = 1103515245, LCG_C: UInt64 = 12345, LCG_M: UInt64 = 2147483648
let WEIGHT_SEED: UInt64 = 20260821

var G2_SEED: UInt64 = WEIGHT_SEED  // overridable for calibration twins

struct LCG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func unit() -> Double { s = (LCG_A &* s &+ LCG_C) % LCG_M; return Double(s) / Double(LCG_M) }
}

// Dense symmetric solve helpers (Float64, LAPACK).
func solveSym(_ a: [Double], n: Int, rhs: [Double], nrhs: Int) -> [Double] {
    var A = a  // column-major == row-major for symmetric
    var B = rhs
    var N = __CLPK_integer(n), NRHS = __CLPK_integer(nrhs)
    var LDA = N, LDB = N, INFO: __CLPK_integer = 0
    var ipiv = [__CLPK_integer](repeating: 0, count: n)
    dgesv_(&N, &NRHS, &A, &LDA, &ipiv, &B, &LDB, &INFO)
    precondition(INFO == 0, "dgesv INFO=\(INFO)")
    return B
}

final class Ladder {
    let side: Int
    let n: Int
    let engine: DagDBEngine
    let grid: HexGrid
    let mortonOf: [Int]
    var leak: Double
    // Row-major adjacency with weights, built from ENGINE lanes.
    var adj: [[(j: Int, w: Double)]] = []
    var rank: [Int] = []

    init(side: Int, profile: String, leak: Double) throws {
        self.side = side; self.n = side * side; self.leak = leak
        self.grid = HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        self.engine = try DagDBEngine(grid: grid, state: state, maxRank: 64)
        var mo = [Int](repeating: 0, count: n)
        for i in 0..<n { mo[i] = Int(grid.mortonRank[i]) }
        self.mortonOf = mo

        // Ranks into the ENGINE rank lane (fabric-resident), read back.
        let c0 = side == 44 ? 22 : side / 2
        let rk = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        for i in 0..<n {
            let c = i % side, r = i / side
            rk[mo[i]] = UInt64(max(abs(c - c0), abs(r - c0)))
        }
        // Leaks into the nodeValue lane (fabric-resident).
        let nv = engine.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)
        for m in 0..<n { nv[m] = Float(leak) }

        // G2 weights into the ENGINE edge lane by frozen LCG, lex edge order.
        let nb = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        var ro = [Int](repeating: 0, count: n)
        for i in 0..<n { ro[mo[i]] = i }
        if profile.hasPrefix("G2") {
            let w = engine.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
            var edges: [(Int, Int)] = []
            for i in 0..<n {
                let m = mo[i]
                for d in 0..<6 {
                    let jm = nb[m * 6 + d]
                    if jm >= 0 {
                        let j = ro[Int(jm)]
                        if i < j { edges.append((i, j)) }
                    }
                }
            }
            edges.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            var lcg = LCG(G2_SEED)
            for (i, j) in edges {
                let cond = Float(pow(10.0, 2.0 * lcg.unit() - 1.0))
                let mi = mo[i], mj = mo[j]
                for d in 0..<6 where Int(nb[mi * 6 + d]) == mj { w[mi * 6 + d] = cond }
                for d in 0..<6 where Int(nb[mj * 6 + d]) == mi { w[mj * 6 + d] = cond }
            }
        }
        // Row-major adjacency read back FROM the engine lanes.
        let w = engine.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        adj = (0..<n).map { i in
            let m = mo[i]
            var row: [(Int, Double)] = []
            for d in 0..<6 {
                let jm = nb[m * 6 + d]
                if jm >= 0 { row.append((ro[Int(jm)], Double(w[m * 6 + d]))) }
            }
            return row
        }
        let rkBack = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        rank = (0..<n).map { Int(rkBack[mo[$0]]) }
    }

    // Run the ladder. Returns raw JSON dict.
    func run(maxRank: Int, keepRank: Int, checkpoints: [Int],
             f1Node: Int, f2Node: Int, f3Node: Int = -1) -> [String: Any] {
        // Active set ordered ascending row-major.
        var active = Array(0..<n)
        // Operator entries (stored as Float32 between folds; Float64 inside a fold).
        // Represent as dense [Float] over active set.
        var op: [Float] = {
            var A = [Double](repeating: 0, count: n * n)
            for i in 0..<n {
                A[i * n + i] = leak
                for (j, w) in adj[i] { A[i * n + i] += w; A[i * n + j] -= w }
            }
            return A.map { Float($0) }
        }()
        var f1 = [Float](repeating: 0, count: n); f1[f1Node] = 1.0
        var f2 = [Float](repeating: 0, count: n); f2[f2Node] = 1.0
        var f3 = [Float](repeating: 0, count: n); if f3Node >= 0 { f3[f3Node] = 1.0 }

        var foldLog: [[String: Any]] = []
        var tierAnswers: [String: Any] = [:]
        var tierBytes: [String: Any] = [:]

        func checkpointName(_ level: Int) -> String { level == keepRank ? "final" : String(level) }

        func recordTier(_ level: Int, activeSet: [Int], opF: [Float],
                        f1F: [Float], f2F: [Float], f3F: [Float]) {
            let k = activeSet.count
            let A = opF.map { Double($0) }
            let x1 = solveSym(A, n: k, rhs: f1F.map { Double($0) }, nrhs: 1)
            let x2 = solveSym(A, n: k, rhs: f2F.map { Double($0) }, nrhs: 1)
            var entry: [String: Any] = ["kept": activeSet, "f1": x1, "f2": x2]
            if f3Node >= 0 {
                entry["f3"] = solveSym(A, n: k, rhs: f3F.map { Double($0) }, nrhs: 1)
            }
            tierAnswers[checkpointName(level)] = entry
            tierBytes[checkpointName(level)] = k * k * 4 + k * 3 * 4
        }

        var current = maxRank
        while current > keepRank {
            let ring = active.filter { rank[$0] == current }
            let keep = active.filter { rank[$0] < current }
            let t0 = Date()
            let kb = ring.count, ka = keep.count
            // Build blocks from the Float32-stored operator, lift to Double.
            let idxOfActive = { () -> [Int: Int] in
                var d = [Int: Int](); for (p, node) in active.enumerated() { d[node] = p }; return d
            }()
            var ABB = [Double](repeating: 0, count: kb * kb)
            var ABA = [Double](repeating: 0, count: kb * ka)  // rows=B, cols=A
            var AAA = [Double](repeating: 0, count: ka * ka)
            let m = active.count
            for (bi, nodeB) in ring.enumerated() {
                let pb = idxOfActive[nodeB]!
                for (bj, nodeB2) in ring.enumerated() {
                    ABB[bi * kb + bj] = Double(op[pb * m + idxOfActive[nodeB2]!])
                }
                for (ai, nodeA) in keep.enumerated() {
                    ABA[bi * ka + ai] = Double(op[pb * m + idxOfActive[nodeA]!])
                }
            }
            for (ai, nodeA) in keep.enumerated() {
                let pa = idxOfActive[nodeA]!
                for (aj, nodeA2) in keep.enumerated() {
                    AAA[ai * ka + aj] = Double(op[pa * m + idxOfActive[nodeA2]!])
                }
            }
            let fB1 = ring.map { node in Double(f1[idxOfActive[node]!]) }
            let fB2 = ring.map { node in Double(f2[idxOfActive[node]!]) }
            let fB3 = ring.map { node in Double(f3[idxOfActive[node]!]) }
            let fA1 = keep.map { node in Double(f1[idxOfActive[node]!]) }
            let fA2 = keep.map { node in Double(f2[idxOfActive[node]!]) }
            let fA3 = keep.map { node in Double(f3[idxOfActive[node]!]) }

            // X = ABB^{-1} [ABA | fB1 | fB2]
            var rhs = [Double](repeating: 0, count: kb * (ka + 3))
            for bi in 0..<kb {
                for ai in 0..<ka { rhs[bi * (ka + 3) + ai] = ABA[bi * ka + ai] }
                rhs[bi * (ka + 3) + ka] = fB1[bi]
                rhs[bi * (ka + 3) + ka + 1] = fB2[bi]
                rhs[bi * (ka + 3) + ka + 2] = fB3[bi]
            }
            // LAPACK is column-major; our arrays are row-major. For symmetric
            // ABB it's fine; rhs needs transpose handling: build column-major.
            var Acm = [Double](repeating: 0, count: kb * kb)
            for r in 0..<kb { for c in 0..<kb { Acm[c * kb + r] = ABB[r * kb + c] } }
            var Bcm = [Double](repeating: 0, count: kb * (ka + 3))
            for r in 0..<kb { for c in 0..<(ka + 3) { Bcm[c * kb + r] = rhs[r * (ka + 3) + c] } }
            var N32 = __CLPK_integer(kb), NRHS32 = __CLPK_integer(ka + 3)
            var LDA32 = N32, LDB32 = N32, INFO: __CLPK_integer = 0
            var ipiv = [__CLPK_integer](repeating: 0, count: kb)
            dgesv_(&N32, &NRHS32, &Acm, &LDA32, &ipiv, &Bcm, &LDB32, &INFO)
            precondition(INFO == 0, "fold dgesv INFO=\(INFO)")
            // Schur: AAA -= ABA^T * X ; folded f similarly.
            var newOp = [Double](repeating: 0, count: ka * ka)
            for ai in 0..<ka {
                for aj in 0..<ka {
                    var s = AAA[ai * ka + aj]
                    for bi in 0..<kb {
                        s -= ABA[bi * ka + ai] * Bcm[aj * kb + bi]
                    }
                    newOp[ai * ka + aj] = s
                }
            }
            var newF1 = [Double](repeating: 0, count: ka)
            var newF2 = [Double](repeating: 0, count: ka)
            var newF3 = [Double](repeating: 0, count: ka)
            for ai in 0..<ka {
                var s1 = fA1[ai], s2 = fA2[ai], s3 = fA3[ai]
                for bi in 0..<kb {
                    s1 -= ABA[bi * ka + ai] * Bcm[ka * kb + bi]
                    s2 -= ABA[bi * ka + ai] * Bcm[(ka + 1) * kb + bi]
                    s3 -= ABA[bi * ka + ai] * Bcm[(ka + 2) * kb + bi]
                }
                newF1[ai] = s1; newF2[ai] = s2; newF3[ai] = s3
            }
            // STORE to Float32 (the fabric): operator and folded sources.
            op = newOp.map { Float($0) }
            var nf1 = [Float](repeating: 0, count: ka)
            var nf2 = [Float](repeating: 0, count: ka)
            var nf3 = [Float](repeating: 0, count: ka)
            for ai in 0..<ka { nf1[ai] = Float(newF1[ai]); nf2[ai] = Float(newF2[ai]); nf3[ai] = Float(newF3[ai]) }
            f1 = nf1; f2 = nf2; f3 = nf3
            active = keep
            let ms = Date().timeIntervalSince(t0) * 1000
            foldLog.append(["fold": foldLog.count + 1, "ring": current,
                            "eliminated": kb, "kept": ka, "wall_ms": ms])
            current -= 1
            if checkpoints.contains(current) || current == keepRank {
                recordTier(current, activeSet: active, opF: op, f1F: f1, f2F: f2, f3F: f3)
            }
        }

        let finalOp: [[Float]] = {
            let k = active.count
            return (0..<k).map { r in (0..<k).map { c in op[r * k + c] } }
        }()
        return ["kept_nodes": active, "final_operator": finalOp,
                "fold_log": foldLog, "tier_answers": tierAnswers,
                "tier_bytes": tierBytes,
                "folded_f1_final": f1.map { Double($0) },
                "folded_f2_final": f2.map { Double($0) }]
    }
}

func writeJSON(_ obj: Any, _ path: String) throws {
    let d = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    try d.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: e3-ladder control|ladder [profile] <out>"); exit(1) }

if args[1] == "control" {
    let out = args[2]
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let lad = try Ladder(side: 12, profile: "G1", leak: 1e-2)
    let c0 = 6
    let f1Node = c0 * 12 + c0
    let res = lad.run(maxRank: 6, keepRank: 3, checkpoints: [],
                      f1Node: f1Node, f2Node: f1Node, f3Node: -1)
    let outObj: [String: Any] = ["kept_nodes": res["kept_nodes"]!,
                                 "final_operator": res["final_operator"]!,
                                 "folded_f1": res["folded_f1_final"]!]
    try writeJSON(outObj, out + "/e3_control_engine.json")
    print("control written: kept=\((res["kept_nodes"] as! [Int]).count)")
} else if args[1] == "ladder" {
    guard args.count >= 4 else { print("ladder <profile> <out> [g2seed] [c,r;c,r;c,r]"); exit(1) }
    let profile = args[2], out = args[3]
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let leak = profile.hasSuffix("_stress") ? 1e-6 : 1e-2
    if args.count > 4, let sd = UInt64(args[4]) { G2_SEED = sd }
    let lad = try Ladder(side: 44, profile: profile, leak: leak)
    var f1Node = 22 * 44 + 22
    var f2Node = 31 * 44 + 10   // (c=10, r=31) -> r*44+c
    var f3Node = 22 * 44 + 2    // (c=2, r=22), rank 20 — folds first (E3v2)
    if args.count > 5 {
        let parts = args[5].split(separator: ";").map { pair -> Int in
            let cr = pair.split(separator: ",").map { Int($0)! }
            return cr[1] * 44 + cr[0]
        }
        precondition(parts.count == 3, "need 3 injections c,r;c,r;c,r")
        f1Node = parts[0]; f2Node = parts[1]; f3Node = parts[2]
    }
    let t0 = Date()
    let res = lad.run(maxRank: 22, keepRank: 3, checkpoints: [19, 15, 11, 7],
                      f1Node: f1Node, f2Node: f2Node, f3Node: f3Node)
    print("ladder \(profile): total \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
    try writeJSON(res, out + "/e3_ladder_\(profile).json")
    print("written e3_ladder_\(profile).json")
} else { print("unknown mode"); exit(1) }
