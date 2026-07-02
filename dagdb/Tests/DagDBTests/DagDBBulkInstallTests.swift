import XCTest
@testable import DagDB

/// Bulk-install primitives for compiling large microcircuits.
///
/// Tests the buffer-write semantics that `SET_LUTS_BULK` and
/// `SET_NEIGHBORS_BULK` use under the hood — same loop the daemon
/// dispatcher runs, exercised directly against the engine's MTLBuffers.
/// Round-trip + end-to-end tick: bulk-install a tiny AND circuit and
/// verify the GPU evaluates it correctly.
final class DagDBBulkInstallTests: XCTestCase {

    private func makeEngine(side: Int) throws -> DagDBEngine {
        let grid = HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        let nb = engine.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: engine.nodeCount * 6)
        for i in 0..<(engine.nodeCount * 6) { nb[i] = -1 }
        return engine
    }

    /// Mirrors the daemon's SET_LUTS_BULK dispatcher: split each u64 into
    /// low/high u32 and commit. Test-side surrogate so the unit test can
    /// exercise the exact same memory layout the live daemon writes.
    private func bulkInstallLUTs(_ engine: DagDBEngine, _ vector: [UInt64]) {
        let n = engine.nodeCount
        precondition(vector.count == n)
        let low = engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high = engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        for i in 0..<n {
            let v = vector[i]
            low[i] = UInt32(v & 0xFFFF_FFFF)
            high[i] = UInt32((v >> 32) & 0xFFFF_FFFF)
        }
    }

    private func bulkInstallNeighbors(_ engine: DagDBEngine, _ vector: [Int32]) {
        let count = engine.nodeCount * 6
        precondition(vector.count == count)
        let dst = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: count)
        for i in 0..<count { dst[i] = vector[i] }
    }

    private func bulkInstallRanks(_ engine: DagDBEngine, _ vector: [UInt64]) {
        let n = engine.nodeCount
        precondition(vector.count == n)
        let dst = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        for i in 0..<n { dst[i] = vector[i] }
    }

    // MARK: - Round-trip integrity

    func testBulkLUTRoundTrip() throws {
        let eng = try makeEngine(side: 4)
        let n = eng.nodeCount

        var luts = [UInt64](repeating: 0, count: n)
        for i in 0..<n {
            // Spread bits across both u32 halves so the high/low split is exercised.
            luts[i] = UInt64(i) | (UInt64(i) << 32) | 0x1234_5678_ABCD_EF00
        }

        bulkInstallLUTs(eng, luts)

        let low = eng.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high = eng.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        for i in 0..<n {
            let recomposed = UInt64(low[i]) | (UInt64(high[i]) << 32)
            XCTAssertEqual(recomposed, luts[i],
                "node \(i): low/high split must reconstitute the original u64 LUT")
        }
    }

    func testBulkNeighborsRoundTrip() throws {
        let eng = try makeEngine(side: 4)
        let n = eng.nodeCount

        var nbr = [Int32](repeating: -1, count: n * 6)
        for i in 0..<n {
            // Cycle through some non-empty patterns; keep -1 sentinel for the
            // remaining slots so the test exercises both filled and empty.
            nbr[i * 6 + 0] = Int32((i + 1) % n)
            nbr[i * 6 + 1] = Int32((i + 2) % n)
            nbr[i * 6 + 2] = -1
            nbr[i * 6 + 3] = Int32((i + 3) % n)
            nbr[i * 6 + 4] = -1
            nbr[i * 6 + 5] = -1
        }

        bulkInstallNeighbors(eng, nbr)

        let dst = eng.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        for i in 0..<(n * 6) {
            XCTAssertEqual(dst[i], nbr[i], "slot \(i) must memcpy intact")
        }
    }

    // MARK: - End-to-end: bulk-install a tiny AND3 circuit, tick, verify

    /// 4-node circuit:
    ///   inputs  : nodes 1, 2, 3 — all truth=1 at rank 2 (LUT const1)
    ///   output  : node 0 with LUT=AND3 reading slots 0,1,2, rank=1
    /// Empty slots 3,4,5 default to 0 in the kernel; AND3 ignores them.
    /// After one tick, truth[0] should be 1.
    func testBulkInstallAnd3CircuitEvaluatesCorrectly() throws {
        let eng = try makeEngine(side: 4)
        let n = eng.nodeCount

        var ranks = [UInt64](repeating: 0, count: n)
        ranks[0] = 1
        ranks[1] = 2; ranks[2] = 2; ranks[3] = 2
        bulkInstallRanks(eng, ranks)

        var luts = [UInt64](repeating: 0, count: n)
        luts[0] = LUT6Preset.and3
        luts[1] = LUT6Preset.const1
        luts[2] = LUT6Preset.const1
        luts[3] = LUT6Preset.const1
        bulkInstallLUTs(eng, luts)

        var nbr = [Int32](repeating: -1, count: n * 6)
        nbr[0 * 6 + 0] = 1
        nbr[0 * 6 + 1] = 2
        nbr[0 * 6 + 2] = 3
        bulkInstallNeighbors(eng, nbr)

        let truth = eng.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        for i in 0..<n { truth[i] = 0 }
        truth[1] = 1; truth[2] = 1; truth[3] = 1

        eng.tick(tickNumber: 1)

        XCTAssertEqual(truth[0], 1,
            "AND3 gate at node 0 must evaluate to 1 after bulk-install + tick")
    }

    func testBulkInstallSetsConsistentNodeCount() throws {
        let eng = try makeEngine(side: 8)
        let n = eng.nodeCount

        // Slightly larger fixture: 64 nodes. Bulk-install a uniform pattern
        // and verify the engine sees consistent state across all of them.
        let uniform: UInt64 = LUT6Preset.identity
        bulkInstallLUTs(eng, Array(repeating: uniform, count: n))

        let low = eng.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high = eng.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        for i in 0..<n {
            XCTAssertEqual(low[i], UInt32(uniform & 0xFFFF_FFFF))
            XCTAssertEqual(high[i], UInt32((uniform >> 32) & 0xFFFF_FFFF))
        }
    }
}
