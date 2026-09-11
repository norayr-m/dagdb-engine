/// E3Ladder — thin CLI over `LadderFold` (dagdb/Sources/DagDB/LadderFold.swift),
/// per CONTRACT_E3_FROZEN.md (frozen 2026-08-26; contract held outside this repository)
/// and docs/contracts/FOLD_API_GATES_FROZEN.md (F3: the rebuilt CLI's output
/// must equal the sealed runner's, bit for bit).
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

func writeJSON(_ obj: Any, _ path: String) throws {
    let d = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    try d.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: e3-ladder control|ladder [profile] <out>"); exit(1) }

if args[1] == "control" {
    let out = args[2]
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let grid = HexGrid(width: 12, height: 12)
    let state = DagDBState(width: 12, height: 12)
    let engine = try DagDBEngine(grid: grid, state: state, maxRank: 64)
    let object = LadderFold.Objects.control(engine: engine, grid: grid)
    let res = LadderFold.run(object: object,
                              schedule: LadderFold.Objects.controlSchedule,
                              sources: LadderFold.Objects.controlSources)
    let full = res.jsonDictionary()
    let outObj: [String: Any] = ["kept_nodes": full["kept_nodes"]!,
                                 "final_operator": full["final_operator"]!,
                                 "folded_f1": full["folded_f1_final"]!]
    try writeJSON(outObj, out + "/e3_control_engine.json")
    print("control written: kept=\(res.keptCount)")
} else if args[1] == "ladder" {
    guard args.count >= 4 else { print("ladder <profile> <out> [g2seed] [c,r;c,r;c,r]"); exit(1) }
    let profile = args[2], out = args[3]
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    var g2Seed: UInt64 = 20260821
    if args.count > 4, let sd = UInt64(args[4]) { g2Seed = sd }
    let grid = HexGrid(width: 44, height: 44)
    let state = DagDBState(width: 44, height: 44)
    let engine = try DagDBEngine(grid: grid, state: state, maxRank: 64)
    let object = LadderFold.Objects.court(profile: profile, g2Seed: g2Seed, engine: engine, grid: grid)
    var sources = LadderFold.Objects.courtSources
    if args.count > 5 {
        let parts = args[5].split(separator: ";").map { pair -> Int in
            let cr = pair.split(separator: ",").map { Int($0)! }
            return cr[1] * 44 + cr[0]
        }
        precondition(parts.count == 3, "need 3 injections c,r;c,r;c,r")
        sources = LadderFold.Sources(f1: parts[0], f2: parts[1], f3: parts[2])
    }
    let t0 = Date()
    let res = LadderFold.run(object: object,
                              schedule: LadderFold.Objects.courtSchedule,
                              sources: sources)
    print("ladder \(profile): total \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
    print(res.priceTable())
    print("court reference: ~1.6 s/profile (release build, 2026-08-26)")
    try writeJSON(res.jsonDictionary(), out + "/e3_ladder_\(profile).json")
    print("written e3_ladder_\(profile).json")
} else { print("unknown mode"); exit(1) }
