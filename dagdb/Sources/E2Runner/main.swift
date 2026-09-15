/// E2Runner — the smoother ON the engine, per the frozen E2 contract
/// (held outside this repository, frozen 2026-08-22).
///
/// Builder's half only: runs the frozen async Jacobi schedule on the
/// engine's own fabric (HexGrid wiring, Float32 nodeValue lane,
/// Float64 accumulation) and writes RAW per-cell results. No ratios
/// are computed here — the judge (the gate script, outside this repository) owns denominators.
///
/// Usage:
///   e2-runner control <python_control_reference.json> <out_dir>
///   e2-runner cells <u_star_G1.json> <u_star_G2.json> <out_dir>

import Foundation
import DagDB
import CryptoKit

// MARK: - Frozen constants

let LCG_A: UInt64 = 1103515245
let LCG_C: UInt64 = 12345
let LCG_M: UInt64 = 2147483648  // 2^31
let SCHEDULE_SEED: UInt64 = 77
let WEIGHT_SEED: UInt64 = 20260821
let TOL_DEFAULT = 1e-6  // E2 v1 (superseded); v2 passes per-profile tol
let CAP = 600_000

struct LCG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = (LCG_A &* state &+ LCG_C) % LCG_M
        return state
    }
    mutating func unit() -> Double { Double(next()) / Double(LCG_M) }
}

// MARK: - Object construction (row-major spec over engine wiring)

final class E2Object {
    let side: Int
    let n: Int
    let grid: HexGrid
    let engine: DagDBEngine
    let mortonOf: [Int]      // row-major i -> morton index
    let rowMajorOf: [Int]    // morton index -> row-major i
    let pinned: [Bool]       // row-major
    let slots: [[(slot: Int, j: Int)]]  // row-major i -> present slots (slot d, row-major j)
    let f: [Double]          // row-major
    let injectionRowMajor: Int

    init(side: Int, profile: String) throws {
        self.side = side
        self.n = side * side
        self.grid = try HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        self.engine = try DagDBEngine(grid: grid, state: state, maxRank: 8)

        var mo = [Int](repeating: 0, count: n)
        var ro = [Int](repeating: 0, count: n)
        for i in 0..<n {
            let m = Int(grid.mortonRank[i])
            mo[i] = m
            ro[m] = i
        }
        self.mortonOf = mo
        self.rowMajorOf = ro

        var pin = [Bool](repeating: false, count: n)
        for c in 0..<side {
            for r in 0..<side {
                if r == 0 || r == side - 1 || c == 0 || c == side - 1 {
                    pin[r * side + c] = true
                }
            }
        }
        self.pinned = pin

        // Row-major adjacency through the ENGINE's own wiring.
        let nb = engine.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: n * 6)
        var sl = [[(slot: Int, j: Int)]](repeating: [], count: n)
        for i in 0..<n {
            let m = mo[i]
            var row: [(slot: Int, j: Int)] = []
            for d in 0..<6 {
                let jm = nb[m * 6 + d]
                if jm >= 0 { row.append((slot: d, j: ro[Int(jm)])) }
            }
            sl[i] = row
        }
        self.slots = sl

        // Injection at (c=21, r=21) for side 44; center (6,6) for side 12.
        let cc = side == 44 ? 21 : side / 2
        self.injectionRowMajor = cc * 1 + cc * side  // r=cc, c=cc -> r*side+c
        var ff = [Double](repeating: 0, count: n)
        ff[injectionRowMajor] = 1.0
        self.f = ff

        // Edge weights into the ENGINE lane.
        let w = engine.edgeWeightsBuf.contents()
            .bindMemory(to: Float.self, capacity: n * 6)
        if profile == "G2" {
            // Lexicographic undirected edge order keyed (min,max).
            var edges: [(i: Int, j: Int)] = []
            for i in 0..<n {
                for (_, j) in sl[i] where i < j { edges.append((i, j)) }
            }
            edges.sort { $0.i != $1.i ? $0.i < $1.i : $0.j < $1.j }
            var lcg = LCG(seed: WEIGHT_SEED)
            for (i, j) in edges {
                let u = lcg.unit()
                let cond = Float(pow(10.0, 2.0 * u - 1.0))
                // both directions
                let mi = mo[i], mj = mo[j]
                for d in 0..<6 where Int(nb[mi * 6 + d]) == mj { w[mi * 6 + d] = cond }
                for d in 0..<6 where Int(nb[mj * 6 + d]) == mi { w[mj * 6 + d] = cond }
            }
        }
        // G1: engine default is already 1.0 everywhere.
    }
}

// MARK: - One cell of the frozen schedule

struct CellResult: Codable {
    let profile: String
    let p: Double
    let D: Int
    let q: Double
    let work: Int
    let rounds: Int
    let final_rel_err: Double
    let hit_cap: Bool
}

struct ControlTrace {
    var supPerRound: [Double] = []
    var shaPerRound: [String] = []
    var vecPerRound: [[Float]] = []
}

func runCell(obj: E2Object, p: Double, D: Int, q: Double,
             uStar: [Double], uStarInf: Double,
             tol: Double = TOL_DEFAULT,
             trace: Bool = false) -> (CellResult, ControlTrace) {
    let n = obj.n
    let lane = obj.engine.nodeValueBuf.contents()
        .bindMemory(to: Float.self, capacity: n)
    let w = obj.engine.edgeWeightsBuf.contents()
        .bindMemory(to: Float.self, capacity: n * 6)

    // Fresh state per cell.
    for m in 0..<n { lane[m] = 0.0 }
    var hist = [[Float]](repeating: [Float](repeating: 0, count: n),
                         count: max(D, 1))
    var lastAccepted = [Float](repeating: 0, count: n * 6)
    var lcg = LCG(seed: SCHEDULE_SEED)
    var work = 0
    var rounds = 0
    var relErr = Double.infinity
    var tr = ControlTrace()

    // Precompute per-node denominators (Float64 of the Float32 weights).
    var denom = [Double](repeating: 0, count: n)
    for i in 0..<n {
        var s = 0.0
        let m = obj.mortonOf[i]
        for (d, _) in obj.slots[i] { s += Double(w[m * 6 + d]) }
        denom[i] = s
    }

    var t = 0
    while t < CAP {
        t += 1
        let delayedValid = (t - D) >= 1
        let delayedIdx = delayedValid ? (t - D) % max(D, 1) : -1

        for i in 0..<n {
            if obj.pinned[i] { continue }
            let draw = lcg.unit()
            if draw < p {
                work += 1
                var num = obj.f[i]
                let m = obj.mortonOf[i]
                for (d, j) in obj.slots[i] {
                    let dq = lcg.unit()
                    let key = i * 6 + d
                    var val: Float
                    if dq < q {
                        val = lastAccepted[key]
                    } else {
                        if D == 0 {
                            // Contractually excluded; kept as trap.
                            fatalError("D=0 does not exist in this contract")
                        }
                        val = delayedValid ? hist[delayedIdx][obj.mortonOf[j]]
                                           : 0.0
                        lastAccepted[key] = val
                    }
                    num += Double(w[m * 6 + d]) * Double(val)
                }
                lane[m] = Float(num / denom[i])
            }
        }

        // Snapshot AFTER the round (state as of round t).
        let slot = t % max(D, 1)
        for m in 0..<n { hist[slot][m] = lane[m] }

        // Convergence check (Float64, vs external u*).
        var maxDiff = 0.0
        for i in 0..<n where !obj.pinned[i] {
            let d = abs(Double(lane[obj.mortonOf[i]]) - uStar[i])
            if d > maxDiff { maxDiff = d }
        }
        relErr = maxDiff / uStarInf
        rounds = t

        if trace && t <= 100 {
            var sup = 0.0
            var raw = Data(capacity: n * 4)
            var vec = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let v = lane[obj.mortonOf[i]]  // row-major serialization
                vec[i] = v
                if Double(abs(v)) > sup { sup = Double(abs(v)) }
                withUnsafeBytes(of: v.bitPattern.littleEndian) { raw.append(contentsOf: $0) }
            }
            tr.supPerRound.append(sup)
            tr.shaPerRound.append(SHA256.hash(data: raw)
                .map { String(format: "%02x", $0) }.joined())
            tr.vecPerRound.append(vec)
        }

        if relErr <= tol { break }
    }

    let res = CellResult(profile: "", p: p, D: D, q: q, work: work,
                         rounds: rounds, final_rel_err: relErr,
                         hit_cap: rounds >= CAP && relErr > tol)
    return (res, tr)
}

// MARK: - IO helpers

func loadUStar(_ path: String) throws -> (u: [Double], uInf: Double) {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let u = (obj["u"] as! [Any]).map { ($0 as! NSNumber).doubleValue }
    let uInf = (obj["u_inf"] as! NSNumber).doubleValue
    return (u, uInf)
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: e2-runner control <ref.json> <out_dir> | cells <uG1.json> <uG2.json> <out_dir>")
    exit(1)
}

let mode = args[1]

if mode == "control" {
    guard args.count == 4 else { print("control <ref.json> <out_dir>"); exit(1) }
    let refPath = args[2], outDir = args[3]
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    let refData = try Data(contentsOf: URL(fileURLWithPath: refPath))
    let ref = try JSONSerialization.jsonObject(with: refData) as! [String: Any]
    let pyRounds = (ref["rounds_to_tol"] as! NSNumber).intValue
    let pyVecs = (ref["traj_vec_first_100"] as! [[Any]]).map {
        $0.map { ($0 as! NSNumber).floatValue } }
    let u12 = (ref["u12_star"] as! [Any]).map { ($0 as! NSNumber).doubleValue }
    let u12Inf = u12.map { abs($0) }.max()!

    let obj = try E2Object(side: 12, profile: "G1")
    let (res, tr) = runCell(obj: obj, p: 1.0, D: 1, q: 0.0,
                            uStar: u12, uStarInf: u12Inf, trace: true)

    var maxSupDiff = 0.0
    let upto = min(tr.vecPerRound.count, pyVecs.count)
    for r in 0..<upto {
        var d = 0.0
        for i in 0..<obj.n {
            let dd = abs(Double(tr.vecPerRound[r][i]) - Double(pyVecs[r][i]))
            if dd > d { d = dd }
        }
        if d > maxSupDiff { maxSupDiff = d }
    }

    let merged: [String: Any] = [
        "engine_rounds": res.rounds,
        "python_rounds": pyRounds,
        "max_per_round_sup_diff_first_100": maxSupDiff,
        "rounds_compared": upto,
        "engine_final_rel_err": res.final_rel_err,
        "engine_traj_sha_first_100": tr.shaPerRound,
    ]
    let out = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
    try out.write(to: URL(fileURLWithPath: outDir + "/e2_control.json"))
    print("control: engine_rounds=\(res.rounds) python_rounds=\(pyRounds) max_sup_diff=\(maxSupDiff)")
} else if mode == "cells" {
    guard args.count >= 5 else { print("cells <uG1.json> <uG2.json> <out_dir> [tolG1 tolG2 [outName]]"); exit(1) }
    let outDir = args[4]
    let tolG1 = args.count > 5 ? Double(args[5])! : TOL_DEFAULT
    let tolG2 = args.count > 6 ? Double(args[6])! : TOL_DEFAULT
    let outName = args.count > 7 ? args[7] : "e2_cells.json"
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    var results: [[String: Any]] = []
    let t0 = Date()
    for (profile, uPath) in [("G1", args[2]), ("G2", args[3])] {
        let (uStar, uInf) = try loadUStar(uPath)
        let tol = profile == "G1" ? tolG1 : tolG2
        let obj = try E2Object(side: 44, profile: profile)
        for p in [1.0, 0.5, 0.25] {
            for D in [1, 4, 16] {
                for q in [0.0, 0.1, 0.3] {
                    let (res, _) = runCell(obj: obj, p: p, D: D, q: q,
                                           uStar: uStar, uStarInf: uInf,
                                           tol: tol)
                    results.append([
                        "profile": profile, "p": p, "D": D, "q": q,
                        "work": res.work, "rounds": res.rounds,
                        "final_rel_err": res.final_rel_err,
                        "hit_cap": res.hit_cap,
                    ])
                    let el = String(format: "%.1f", Date().timeIntervalSince(t0))
                    print("[\(el)s] \(profile) p=\(p) D=\(D) q=\(q) -> rounds=\(res.rounds) work=\(res.work) err=\(res.final_rel_err)")
                }
            }
        }
    }
    let out = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
    try out.write(to: URL(fileURLWithPath: outDir + "/" + outName))
    print("cells: \(results.count) written")
} else {
    print("unknown mode \(mode)")
    exit(1)
}
