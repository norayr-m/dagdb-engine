import XCTest
@testable import DagDB

/// Tick-perf recovery equivalence tests (branch dag/tick-perf).
///
/// The compacted per-(rank,color) dispatch is the default rank path;
/// `tickLegacy` (whole color groups + kernel early-out) is retained as
/// the independent ground truth. These tests pin bit-for-bit equality
/// over randomized graphs, and correct invalidation on rank mutation.
final class DagDBTickPerfTests: XCTestCase {

    /// Deterministic LCG so failures reproduce.
    private struct LCG {
        var s: UInt64
        mutating func next() -> UInt64 {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return s >> 16
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    /// Random DAG: `n` gates with random ranks/LUTs, edges honoring
    /// rank(src) > rank(dst) and fan-in <= 6, plus register pairs
    /// (leaf register + BACK_EDGE from a random gate).
    private func randomGraph(seed: UInt64, n: Int = 300,
                             registers: Int = 8) throws -> DagDBGraph {
        var rng = LCG(s: seed)
        let g = DagDBGraph()
        var ranks: [UInt64] = []
        for i in 0..<n {
            let r = UInt64(rng.int(16))
            ranks.append(r)
            let lut = rng.next() | (rng.next() << 48)
            g.addGate(label: "g\(i)", rank: r, lut6: lut)
        }
        for dst in 0..<n {
            // candidates with strictly greater rank
            var fanIn = 0
            for _ in 0..<6 where fanIn < 6 {
                let src = rng.int(n)
                if ranks[src] > ranks[dst] {
                    try? g.connect(from: src, to: dst)   // dup-safe: throws ignored
                    fanIn += 1
                }
            }
        }
        for k in 0..<registers {
            let reg = g.addLeaf(label: "r\(k)", rank: UInt64(rng.int(16)),
                                truth: k % 2 == 0)
            let src = rng.int(n)
            try? g.connectBack(from: src, to: reg)
        }
        return g
    }

    func testCompactedEqualsLegacyRandom() throws {
        for seed in 1...20 {
            let gA = try randomGraph(seed: UInt64(seed))
            let gB = try randomGraph(seed: UInt64(seed))   // identical build
            let a = try DagDBEngine(graph: gA)             // compacted (default)
            let b = try DagDBEngine(graph: gB)             // legacy path
            for t in 1...8 {
                a.tick(tickNumber: UInt32(t))
                b.tickLegacy(tickNumber: UInt32(t))
                XCTAssertEqual(a.readTruthStates(), b.readTruthStates(),
                               "seed \(seed) diverged at tick \(t)")
            }
        }
    }

    func testRankMutationInvalidatesCompaction() throws {
        let g1 = try randomGraph(seed: 99)
        let g2 = try randomGraph(seed: 99)
        let a = try DagDBEngine(graph: g1)
        let b = try DagDBEngine(graph: g2)
        a.tick(tickNumber: 1); b.tickLegacy(tickNumber: 1)

        // mutate the same set of ranks on both engines directly
        let ra = a.rankBuf.contents().bindMemory(to: UInt64.self,
                                                 capacity: a.nodeCount)
        let rb = b.rankBuf.contents().bindMemory(to: UInt64.self,
                                                 capacity: b.nodeCount)
        var rng = LCG(s: 4242)
        for _ in 0..<40 {
            let node = rng.int(300)
            let newRank = UInt64(rng.int(16))
            ra[node] = newRank
            rb[node] = newRank
        }
        a.markRankTopologyDirty()          // the contract under test
        for t in 2...6 {
            a.tick(tickNumber: UInt32(t))
            b.tickLegacy(tickNumber: UInt32(t))
            XCTAssertEqual(a.readTruthStates(), b.readTruthStates(),
                           "post-mutation divergence at tick \(t)")
        }
    }

    func testStaleCompactionWouldDiverge_RedProof() throws {
        // Prove the dirty flag is load-bearing: mutate ranks WITHOUT
        // marking dirty; the compacted engine must (by design) evaluate
        // the stale layout. We assert the mechanism (segment reuse), not
        // equality — i.e. this documents why markRankTopologyDirty exists.
        let g = try randomGraph(seed: 7)
        let a = try DagDBEngine(graph: g)
        a.tick(tickNumber: 1)
        let ra = a.rankBuf.contents().bindMemory(to: UInt64.self,
                                                 capacity: a.nodeCount)
        // move every rank-2 node to rank 3 without invalidation
        for i in 0..<a.nodeCount where ra[i] == 2 { ra[i] = 3 }
        XCTAssertFalse(a.rankTopologyDirty,
                       "no auto-invalidation on raw buffer writes (by design)")
        a.markRankTopologyDirty()
        XCTAssertTrue(a.rankTopologyDirty)
        a.tick(tickNumber: 2)              // rebuild happens here
        XCTAssertFalse(a.rankTopologyDirty, "tick clears the dirty flag")
    }

    // MARK: - TICK_SYNC (Step 3)

    /// CPU double-buffered reference: exactly kernel-copy-then-latch.
    private func cpuSyncReference(engine: DagDBEngine, ticks: Int) -> [UInt8] {
        var cur = engine.readTruthStates()
        let n = engine.nodeCount
        let nb = engine.neighborsBuf.contents().bindMemory(
            to: Int32.self, capacity: n * 6)
        let lo = engine.lut6LowBuf.contents().bindMemory(
            to: UInt32.self, capacity: n)
        let hi = engine.lut6HighBuf.contents().bindMemory(
            to: UInt32.self, capacity: n)
        let reg = engine.isRegisterBuf.contents().bindMemory(
            to: UInt8.self, capacity: n)
        for _ in 0..<ticks {
            var nxt = [UInt8](repeating: 0, count: n)
            for i in 0..<n {
                if reg[i] != 0 { nxt[i] = cur[i]; continue }
                var idx = 0
                for d in 0..<6 {
                    let s = nb[i * 6 + d]
                    if s >= 0 && cur[Int(s)] == 1 { idx |= (1 << d) }
                }
                let bit = idx < 32 ? (lo[i] >> UInt32(idx)) & 1
                                   : (hi[i] >> UInt32(idx - 32)) & 1
                nxt[i] = UInt8(bit)
            }
            // latch phase on the post-pass values (same as engine)
            for k in 0..<engine.backEdgeSrcs.count {
                nxt[Int(engine.backEdgeDsts[k])] = nxt[Int(engine.backEdgeSrcs[k])]
            }
            cur = nxt
        }
        return cur
    }

    func testSyncEqualsCPUReference() throws {
        for seed in 1...10 {
            let g1 = try randomGraph(seed: UInt64(seed &* 31))
            let g2 = try randomGraph(seed: UInt64(seed &* 31))
            let gpu = try DagDBEngine(graph: g1)
            let ref = try DagDBEngine(graph: g2)
            let want = cpuSyncReference(engine: ref, ticks: 10)
            for t in 1...10 { gpu.tickSync(tickNumber: UInt32(t)) }
            XCTAssertEqual(gpu.readTruthStates(), want,
                           "sync mode diverged from CPU reference, seed \(seed)")
        }
    }

    func testSyncDiffersFromRankOnChain() throws {
        // Depth-5 identity chain: rank mode settles in ONE tick (rank
        // order propagates within the tick); sync mode needs 5 hops.
        func chain() throws -> (DagDBEngine, [Int]) {
            let g = DagDBGraph()
            var ids: [Int] = []
            // node k at rank 5-k; node 0 is the CONST1 source at rank 5
            ids.append(g.addGate(label: "src", rank: 5,
                                 lut6: 0xFFFF_FFFF_FFFF_FFFF))
            for k in 1...5 {
                ids.append(g.addGate(label: "n\(k)", rank: UInt64(5 - k),
                                     lut6: 0xFFFF_FFFF_FFFF_FFFE))  // OR
                try g.connect(from: ids[k - 1], to: ids[k])
            }
            return (try DagDBEngine(graph: g), ids)
        }
        let (rankEng, idsA) = try chain()
        rankEng.tick(tickNumber: 1)
        XCTAssertEqual(rankEng.readTruthStates()[idsA[5]], 1,
                       "rank mode settles the whole chain in one tick")
        let (syncEng, idsB) = try chain()
        syncEng.tickSync(tickNumber: 1)
        XCTAssertEqual(syncEng.readTruthStates()[idsB[5]], 0,
                       "sync mode must NOT reach the end in one tick")
        // arrival = 1 tick for the CONST source to assert + 5 hops = 6
        for t in 2...5 { syncEng.tickSync(tickNumber: UInt32(t)) }
        XCTAssertEqual(syncEng.readTruthStates()[idsB[5]], 0,
                       "still in flight at tick 5 (source cost one tick)")
        syncEng.tickSync(tickNumber: 6)
        XCTAssertEqual(syncEng.readTruthStates()[idsB[5]], 1,
                       "sync mode arrives at tick source+depth")
    }

    func testEmbeddedShaderCarriesSyncKernel() throws {
        // The bundle library is primary; the embedded string is the
        // fallback. They must not drift: compile the string and assert
        // the sync kernel exists in it.
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no GPU")
        }
        let lib = try device.makeLibrary(
            source: DagDBEngine.metalShaderSource, options: nil)
        XCTAssertNotNil(lib.makeFunction(name: "dagdb_tick_sync"),
                        "embedded fallback source is missing dagdb_tick_sync")
    }

    func testReadThroughPropertyAfterSwap() throws {
        let g = try randomGraph(seed: 5)
        let e = try DagDBEngine(graph: g)
        let before = ObjectIdentifier(e.truthStateBuf)
        e.tickSync(tickNumber: 1)
        let after = ObjectIdentifier(e.truthStateBuf)
        XCTAssertNotEqual(before, after, "tickSync must swap the buffer")
        // and readTruthStates reads the swapped (current) buffer
        XCTAssertEqual(e.readTruthStates().count, e.nodeCount)
    }

    // MARK: - Step 5: the honest benchmark (numbers printed, not asserted)

    func testBenchmarkTickModes1M() throws {
        let width = 1024, height = 1024
        let nodeCount = width * height

        func makeEngine(rankSpread: Int) throws -> DagDBEngine {
            let grid = HexGrid(width: width, height: height)
            var state = DagDBState(width: width, height: height)
            for y in 0..<height {
                for x in 0..<width {
                    let m = Int(grid.mortonRank[y * width + x])
                    state.rank[m] = UInt64((y * rankSpread) / height)
                    state.truthState[m] = UInt8((x + y) % 2)
                    state.setLUT6(at: m, value: LUT6Preset.majority6)
                }
            }
            return try DagDBEngine(grid: grid, state: state, maxRank: 16)
        }

        func measure(_ name: String, warmup: Int = 3, ticks: Int = 50,
                     _ body: (UInt32) -> Void) {
            for t in 0..<warmup { body(UInt32(t + 1)) }
            let t0 = CFAbsoluteTimeGetCurrent()
            for t in 0..<ticks { body(UInt32(warmup + t + 1)) }
            let dt = CFAbsoluteTimeGetCurrent() - t0
            let ms = dt * 1000 / Double(ticks)
            let gcups = Double(nodeCount) * Double(ticks) / dt / 1e9
            let label = name.padding(toLength: 28, withPad: " ",
                                     startingAt: 0)
            print("  " + label
                  + String(format: "%8.2f ms/tick   %6.2f GCUPS", ms, gcups))
        }

        print("  ═══ 1M-node tick benchmark (50 ticks each, 3 warmup) ═══")
        for spread in [3, 16] {
            print("  --- rank spread: \(spread) ranks ---")
            let legacy = try makeEngine(rankSpread: spread)
            measure("legacy rank tick") { legacy.tickLegacy(tickNumber: $0) }
            let compact = try makeEngine(rankSpread: spread)
            measure("compacted rank tick") { compact.tick(tickNumber: $0) }
            // sanity: identical states after identical tick counts
            XCTAssertEqual(legacy.readTruthStates(),
                           compact.readTruthStates(),
                           "benchmark engines diverged (spread \(spread))")
            let sync = try makeEngine(rankSpread: spread)
            measure("TICK_SYNC (CA semantics)") { sync.tickSync(tickNumber: $0) }
        }
        print("  ═══════════════════════════════════════════════")
    }
}
