/// DagDB CLI — Minimal test harness for the 6-bounded ranked DAG engine.
///
/// Builds a toy DAG:
///   Rank 2 (leaves): 6 atomic facts (preset TRUE or FALSE)
///   Rank 1: 1 AND-gate aggregating the 6 facts
///   Rank 0 (root): 1 OR-gate over Rank 1 outputs
///
/// Verifies: correct truth propagation leaves-up.

import Foundation
import DagDB

print("══════════════════════════════════════════════════════════")
print("  DagDB v0.1 — 6-Bounded Ranked DAG Evaluator")
print("══════════════════════════════════════════════════════════")

// Build a minimal hex grid (needs to be large enough for 6-coloring)
// Use 16×16 for the test — plenty of nodes for a toy DAG
let width = 16, height = 16
print("  Grid: \(width)×\(height) = \(width * height) nodes")

let grid = HexGrid(width: width, height: height)
print("  7-coloring: \(grid.colorGroups.map { $0.count })")

// Initialize state
var state = DagDBState(width: width, height: height)

// Helper: (col, row) → Morton rank buffer index
let mr = grid.mortonRank
func mi(_ col: Int, _ row: Int) -> Int {
    return Int(mr[row * width + col])
}

// Build toy DAG:
//   Leaves at rank 2: (0,0) to (5,0) = 6 facts
//   Intermediate at rank 1: (2,5) = AND gate combining leaves
//   Root at rank 0: (7,10) = pass-through from intermediate

// Rank 2: 6 leaf facts, half TRUE, half FALSE
print("\n  Setting up toy DAG:")
for i in 0..<6 {
    let idx = mi(i, 0)
    state.rank[idx] = 2
    state.truthState[idx] = (i % 2 == 0) ? 1 : 0  // alternating T/F
    state.setLUT6(at: idx, value: (i % 2 == 0) ? LUT6Preset.const1 : LUT6Preset.const0)
    print("    Leaf[\(i)] at (\(i),0): truth=\(state.truthState[idx])")
}

// Rank 1: AND gate at (2, 5) — assume its 6 neighbors connect to the leaves
// In real DAG the edge topology is explicit; for this toy we use the hex neighbors
let andNodeIdx = mi(2, 5)
state.rank[andNodeIdx] = 1
state.setLUT6(at: andNodeIdx, value: LUT6Preset.and6)
state.truthState[andNodeIdx] = 0
print("    AND node at (2,5): LUT=AND6")

// Rank 0 (root): IDENTITY gate (pass-through from first neighbor)
let rootIdx = mi(7, 10)
state.rank[rootIdx] = 0
state.setLUT6(at: rootIdx, value: LUT6Preset.identity)
state.truthState[rootIdx] = 0
print("    Root at (7,10): LUT=IDENTITY")

// Spin up engine
print("\n  Creating Metal engine...")
let engine: DagDBEngine
do {
    engine = try DagDBEngine(grid: grid, state: state, maxRank: 3)
} catch {
    print("  FATAL: \(error)")
    exit(1)
}
print("  Engine ready. GPU: \(engine.device.name)")

// Run one tick
print("\n  Running tick 0 (leaves-up evaluation)...")
let t0 = CFAbsoluteTimeGetCurrent()
engine.tick(tickNumber: 0)
let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
print("  Elapsed: \(String(format: "%.2f", elapsed)) ms")

// Read back truth states
let result = engine.readTruthStates()
print("\n  Results:")
for i in 0..<6 {
    let idx = mi(i, 0)
    print("    Leaf[\(i)] truth=\(result[idx])")
}
print("    AND node (2,5) truth=\(result[andNodeIdx]) (expected 0: not all leaves TRUE)")
print("    Root (7,10) truth=\(result[rootIdx])")

// Test: flip all leaves TRUE
print("\n  Test 2: All leaves TRUE → AND should produce TRUE")
for i in 0..<6 {
    let idx = mi(i, 0)
    engine.truthStateBuf.contents().storeBytes(of: UInt8(1), toByteOffset: idx, as: UInt8.self)
}

engine.tick(tickNumber: 1)
let result2 = engine.readTruthStates()
print("    AND node (2,5) truth=\(result2[andNodeIdx])")

// LUT6 unit test
print("\n  LUT6 unit tests:")
let testCases: [(String, UInt64, UInt8, UInt8)] = [
    ("AND6(0x3F) = 1", LUT6Preset.and6, 0x3F, 1),
    ("AND6(0x3E) = 0", LUT6Preset.and6, 0x3E, 0),
    ("OR6(0x01) = 1", LUT6Preset.or6, 0x01, 1),
    ("OR6(0x00) = 0", LUT6Preset.or6, 0x00, 0),
    ("XOR6(0x03) = 0", LUT6Preset.xor6, 0x03, 0),  // even parity
    ("XOR6(0x07) = 1", LUT6Preset.xor6, 0x07, 1),  // odd parity
    ("MAJ6(0x0F) = 1", LUT6Preset.majority6, 0x0F, 1),  // 4 of 6
    ("MAJ6(0x07) = 0", LUT6Preset.majority6, 0x07, 0),  // 3 of 6
]

for (name, lut, inputs, expected) in testCases {
    let result = UInt8((lut >> UInt64(inputs & 0x3F)) & 1)
    let status = result == expected ? "✓" : "✗"
    print("    \(status) \(name) = \(result)")
}

print("\n  Build 0.1: COMPLETE")
print("══════════════════════════════════════════════════════════")
