import XCTest
@testable import DagDB

/// Acceptance tests for the load-bearing engine invariants the rest of
/// the system assumes but nothing was pinning (Fable review T3/M2/M3/M4):
///   - the GPU shader evaluates an arbitrary LUT6 identically to the
///     reference Boolean semantics (slot-packing correctness);
///   - the hex 7-colouring is race-free (no two adjacent nodes share a
///     colour) — the whole lock-free tick model depends on it;
///   - the engine-level two-phase BACK_EDGE latch lags chained registers
///     by exactly one tick (latch from pre-tick state).
final class DagDBInvariantTests: XCTestCase {

    private func makeEngine(side: Int, maxRank: Int = 8) throws -> DagDBEngine {
        let grid = HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: maxRank)
        let nb = engine.neighborsBuf.contents().bindMemory(
            to: Int32.self, capacity: engine.nodeCount * 6)
        for i in 0..<(engine.nodeCount * 6) { nb[i] = -1 }
        return engine
    }

    // MARK: - GPU/CPU LUT6 equivalence (slot packing)

    /// For 50 random (LUT, input-pattern) pairs, the GPU tick must produce
    /// the same output bit as the reference `(lut >> pattern) & 1`. A
    /// bit-order regression in the shader's `input_bits |= bit << d` packing
    /// would slip past every preset/ripple test but fail here — especially
    /// patterns that exercise input slots 4 and 5.
    func testGPUMatchesReferenceLUT6OverRandomInputs() throws {
        // Deterministic LCG so the test is reproducible (no Date/random).
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return seed >> 11
        }

        for trial in 0..<50 {
            let eng = try makeEngine(side: 8)
            let n = eng.nodeCount
            let rank  = eng.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
            let truth = eng.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
            let low   = eng.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
            let high  = eng.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
            let nb    = eng.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)

            for i in 0..<n { rank[i] = 0; truth[i] = 0; low[i] = 0; high[i] = 0 }

            let pattern = UInt8(next() & 0x3F)         // 6-bit input index
            let lut = next() | (next() << 32)          // arbitrary 64-bit LUT

            // Gate node 0 at rank 1; six leaf inputs at rank 2 (evaluated
            // first). Each leaf's LUT is const0/const1 so after its own
            // evaluation it holds the desired input bit.
            let gate = 0
            rank[gate] = 1
            low[gate]  = UInt32(lut & 0xFFFF_FFFF)
            high[gate] = UInt32((lut >> 32) & 0xFFFF_FFFF)
            for d in 0..<6 {
                let leaf = 1 + d
                rank[leaf] = 2
                let bit = (pattern >> d) & 1
                let leafLUT = bit == 1 ? LUT6Preset.const1 : LUT6Preset.const0
                low[leaf]  = UInt32(leafLUT & 0xFFFF_FFFF)
                high[leaf] = UInt32((leafLUT >> 32) & 0xFFFF_FFFF)
                nb[gate * 6 + d] = Int32(leaf)
            }

            eng.tick(tickNumber: UInt32(trial + 1))

            let expected = UInt8((lut >> UInt64(pattern)) & 1)
            XCTAssertEqual(truth[gate], expected,
                "trial \(trial): GPU LUT eval disagreed with reference for "
                + "pattern=\(pattern) lut=0x\(String(lut, radix: 16))")
        }
    }

    // MARK: - 7-colouring race-freedom

    /// The lock-free intra-rank tick depends on the hex 7-colouring placing
    /// no two adjacent nodes in the same colour group. Verify across several
    /// grid sizes, including non-power-of-two.
    func testSevenColoringIsRaceFree() {
        for side in [8, 16, 17, 31, 64] {
            let grid = HexGrid(width: side, height: side)
            XCTAssertTrue(grid.verifyColoring(),
                "7-colouring placed adjacent nodes in the same group at side=\(side)")
        }
    }

    /// Every node must appear in exactly one colour group, and the groups
    /// must partition the node set (no gaps, no duplicates).
    func testColorGroupsPartitionNodes() {
        let side = 16
        let grid = HexGrid(width: side, height: side)
        var seen = Set<Int32>()
        var total = 0
        for group in grid.colorGroups {
            for node in group {
                XCTAssertFalse(seen.contains(node), "node \(node) appears in two colour groups")
                seen.insert(node)
                total += 1
            }
        }
        XCTAssertEqual(total, grid.nodeCount)
        XCTAssertEqual(seen.count, grid.nodeCount, "colour groups must cover every node exactly once")
    }

    // MARK: - Engine-level two-phase BACK_EDGE latch

    /// Chained registers must latch from pre-tick state: with back-edges
    /// (comb → r2) and (r2 → r3), r3 receives r2's value from BEFORE this
    /// tick, lagging r2 by exactly one tick. This is the two-phase property
    /// tested at the engine level (tick() uses DagDBEngine.latchBackEdges,
    /// a separate implementation from the DagDBState one already covered).
    func testEngineChainedLatchLagsByOneTick() throws {
        let eng = try makeEngine(side: 8)
        let n = eng.nodeCount
        let rank  = eng.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let truth = eng.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let low   = eng.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high  = eng.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)

        for i in 0..<n { rank[i] = 0; truth[i] = 0; low[i] = 0; high[i] = 0 }

        // comb (node 1): rank 1, LUT const1 → settles to 1 every tick.
        let comb = 1, r2 = 2, r3 = 3
        rank[comb] = 1
        low[comb]  = UInt32(LUT6Preset.const1 & 0xFFFF_FFFF)
        high[comb] = UInt32((LUT6Preset.const1 >> 32) & 0xFFFF_FFFF)

        // r2, r3 registers (zero combinational fan-in already — neighbours
        // are all -1). Chain: comb → r2, r2 → r3.
        try eng.addBackEdge(src: UInt32(comb), dst: UInt32(r2))
        try eng.addBackEdge(src: UInt32(r2), dst: UInt32(r3))

        // Tick 1: comb settles to 1. Latch snapshots r2's pre-tick value (0)
        // for r3, and comb's (1) for r2 → r2=1, r3=0.
        eng.tick(tickNumber: 1)
        XCTAssertEqual(truth[r2], 1, "r2 latches comb after tick 1")
        XCTAssertEqual(truth[r3], 0, "r3 latches r2's PRE-tick value (0) after tick 1")

        // Tick 2: r2's value (now 1) propagates to r3.
        eng.tick(tickNumber: 2)
        XCTAssertEqual(truth[r2], 1)
        XCTAssertEqual(truth[r3], 1, "r3 catches up to r2 one tick later")
    }
}
