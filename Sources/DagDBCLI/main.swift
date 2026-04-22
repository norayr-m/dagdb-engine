// DagDB 4-cycle engine CLI.
// Stub: constructs a tiny 3-node DAG, runs one tick, prints telemetry.
// Real benchmarks and toy-deduction wiring land in subsequent commits.

import Foundation
import Metal
import DagDBEngine

guard let device = MTLCreateSystemDefaultDevice() else {
    print("ERROR: no Metal device available.")
    exit(1)
}
print("device: \(device.name)")

// Tiny circuit, Option A rank convention (thesis v3.8).
// Leaves = rank 0 (circuit inputs), Queen = rank N (circuit root).
// Edges: rank(src) < rank(dst). Forward wave ascends rank.
//
//   n0 (Leaf, rank 0, constant-true input)
//   n1 (Leaf, rank 0, constant-true input)
//   n2 (Leaf, rank 0, constant-false input)
//     │
//   n3 (rank 1, identity gate consuming n0)
//   n4 (rank 1, identity gate consuming n1)
//     │   │
//   n5 (Queen, rank 2, identity gate consuming n3) — the query/answer node
//
// Target LUTs:
//   - constant-true:          0xFFFF_FFFF_FFFF_FFFF
//   - constant-false:         0x0000_0000_0000_0000
//   - identity-on-input-0:    0xAAAA_AAAA_AAAA_AAAA  (output = input[0])

let allTrueLUT:  UInt64 = 0xFFFF_FFFF_FFFF_FFFF
let allFalseLUT: UInt64 = 0x0000_0000_0000_0000
let identityLUT: UInt64 = 0xAAAA_AAAA_AAAA_AAAA

let nodes: [DagNode] = [
    // Rank 0 — three circuit-input leaves.
    DagNode(id: 0, rank: 0,
            inputs: (-1, -1, -1, -1, -1, -1),
            lut: allTrueLUT, state: 1),
    DagNode(id: 1, rank: 0,
            inputs: (-1, -1, -1, -1, -1, -1),
            lut: allTrueLUT, state: 1),
    DagNode(id: 2, rank: 0,
            inputs: (-1, -1, -1, -1, -1, -1),
            lut: allFalseLUT, state: 0),
    // Rank 1 — two intermediate gates consuming leaves.
    DagNode(id: 3, rank: 1,
            inputs: (0, -1, -1, -1, -1, -1),
            lut: identityLUT),
    DagNode(id: 4, rank: 1,
            inputs: (1, -1, -1, -1, -1, -1),
            lut: identityLUT),
    // Rank 2 — Queen (circuit root), consumes one of the rank-1 gates.
    DagNode(id: 5, rank: 2,
            inputs: (3, -1, -1, -1, -1, -1),
            lut: identityLUT),
]
let dag    = DagDB(device: device, nodes: nodes, maxRank: 2, queenIdx: 5)
let engine = try Engine4Cycle(dag: dag)

print("DAG: \(nodes.count) nodes, maxRank=\(dag.maxRank), queenIdx=\(dag.queenIdx)")
let preStates = dag.nodes.prefix(nodes.count).map { String($0.state) }.joined(separator: " ")
print("pre-tick states: \(preStates)")

let telem = try engine.tick()
let postStates = dag.nodes.prefix(nodes.count).map { String($0.state) }.joined(separator: " ")
print("post-tick states: \(postStates)")
print("epoch \(telem.epochIndex): wavelines=\(telem.wavelinesProcessed), "
      + "entropy(fp ×1000)=\(telem.entropyBits), wall=\(String(format: "%.3f", telem.wallTimeMs))ms")
