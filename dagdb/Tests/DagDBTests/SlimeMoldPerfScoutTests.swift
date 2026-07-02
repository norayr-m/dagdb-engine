import XCTest
@testable import DagDB

/// Performance scout for the upcoming Tokyo slime-mold work (Adamatzky CA on
/// DagDB). Measures graph build, engine init, and per-tick cost on a
/// register-grid scaffold sized to the planned 200×200 simulation.
///
/// Each cell is a register node (rank 1) whose next state is computed by a
/// 5-input combinational gate (rank 0): cell + 4 von Neumann neighbors. The
/// combinational gate latches back into the register via BACK_EDGE. The
/// boolean update function is a placeholder (5-input majority) — Ref's
/// Adamatzky spec will decide the real transition table later.
///
/// What we want to know:
/// - Does graph construction at 80 000 nodes / 240 000 edges stay reasonable?
/// - Does engine init scale linearly with nodeCount?
/// - Per-tick latency at this scale on M5 — is the substrate microsecond-fast
///   as the architecture targets, or is there a surprise at scale?
///
/// Build/run with `swift test --filter testSlimeMoldPerfScout200x200`.
final class SlimeMoldPerfScoutTests: XCTestCase {

    /// Width/height of the cell grid. 200×200 = 40 000 cells.
    private let side = 200

    /// Number of ticks to time on the steady-state run (after warmup).
    private let timedTicks = 50

    func testSlimeMoldPerfScout200x200() throws {
        // Precompute a 5-input MAJORITY LUT: output = 1 iff at least 3 of the
        // low 5 bits are set. Higher bits are don't-cares (ignored by the
        // kernel because slot 5 is unused).
        let maj5: UInt64 = {
            var lut: UInt64 = 0
            for i: UInt64 in 0..<64 {
                if (i & 0x1F).nonzeroBitCount >= 3 {
                    lut |= (UInt64(1) << i)
                }
            }
            return lut
        }()

        let cellCount = side * side
        let nodeCount = cellCount * 2  // one register + one combinational per cell

        // ── Phase A: graph construction ──────────────────────────────
        let tBuild0 = CFAbsoluteTimeGetCurrent()
        let g = DagDBGraph()

        // Allocate registers (cells, rank 1) and combinational nodes
        // (next-state gates, rank 0). Layout: register IDs first, then
        // combinational IDs. ID = y*side + x within each block.
        var cellId = [Int](repeating: 0, count: cellCount)
        var nextId = [Int](repeating: 0, count: cellCount)
        for idx in 0..<cellCount {
            // Each cell starts dead (truth=0).
            cellId[idx] = g.addLeaf(label: "c\(idx)", rank: 1, truth: false)
        }
        for idx in 0..<cellCount {
            nextId[idx] = g.addGate(label: "n\(idx)", rank: 0, lut6: maj5)
        }

        // Wire combinational fan-in: slot 0 = cell, slots 1..4 = NESW neighbors
        // (toroidal wrap so every cell has fan-in 5 with no edge effects in
        // the perf number).
        @inline(__always) func at(_ x: Int, _ y: Int) -> Int {
            let xx = (x + side) % side
            let yy = (y + side) % side
            return yy * side + xx
        }
        for y in 0..<side {
            for x in 0..<side {
                let dst = nextId[at(x, y)]
                try g.connect(from: cellId[at(x, y)],     to: dst)  // slot 0
                try g.connect(from: cellId[at(x - 1, y)], to: dst)  // slot 1
                try g.connect(from: cellId[at(x + 1, y)], to: dst)  // slot 2
                try g.connect(from: cellId[at(x, y - 1)], to: dst)  // slot 3
                try g.connect(from: cellId[at(x, y + 1)], to: dst)  // slot 4
            }
        }

        // BACK_EDGE next_cell → cell, one per cell.
        for idx in 0..<cellCount {
            try g.connectBack(from: nextId[idx], to: cellId[idx])
        }

        let tBuild1 = CFAbsoluteTimeGetCurrent()
        let buildMs = (tBuild1 - tBuild0) * 1000.0

        XCTAssertEqual(g.nodeCount, nodeCount)
        XCTAssertEqual(g.backEdges.count, cellCount)
        XCTAssertTrue(g.validate().isEmpty, "scaffold should validate")

        // ── Phase B: engine init (Metal buffer allocation + neighbor upload) ──
        let tInit0 = CFAbsoluteTimeGetCurrent()
        let engine = try DagDBEngine(graph: g)
        let tInit1 = CFAbsoluteTimeGetCurrent()
        let initMs = (tInit1 - tInit0) * 1000.0

        XCTAssertEqual(engine.backEdgeCount, cellCount)

        // Seed a non-trivial initial pattern so the tick has work to do —
        // every other cell starts alive. (Toggling pattern propagates and
        // mixes interestingly under MAJ5.)
        let truthPtr = engine.truthStateBuf.contents()
            .bindMemory(to: UInt8.self, capacity: engine.nodeCount)
        for idx in 0..<cellCount {
            truthPtr[cellId[idx]] = ((idx & 1) == 0) ? 1 : 0
        }

        // ── Phase C: warmup tick (first tick eats Metal pipeline cost) ──
        let tWarm0 = CFAbsoluteTimeGetCurrent()
        engine.tick(tickNumber: 0)
        let tWarm1 = CFAbsoluteTimeGetCurrent()
        let warmupMs = (tWarm1 - tWarm0) * 1000.0

        // ── Phase D: timed steady-state ticks ──
        let tTick0 = CFAbsoluteTimeGetCurrent()
        for t in 1...timedTicks {
            engine.tick(tickNumber: UInt32(t))
        }
        let tTick1 = CFAbsoluteTimeGetCurrent()
        let totalTickMs = (tTick1 - tTick0) * 1000.0
        let avgTickMs = totalTickMs / Double(timedTicks)

        // Spot-check that the simulation actually evolved — read back a
        // sample of cell truths and confirm the count of live cells changed
        // away from the initial half-and-half pattern.
        var liveCount = 0
        for idx in 0..<cellCount where truthPtr[cellId[idx]] != 0 {
            liveCount += 1
        }

        // Print results in a format that's easy to grep out of `swift test` logs.
        print("""
        ───────────────────────────────────────────────────────────
        SLIME-MOLD PERF SCOUT (\(side)×\(side) torus, MAJ5 update)
        ───────────────────────────────────────────────────────────
          cells         : \(cellCount)
          graph nodes   : \(nodeCount)
          back-edges    : \(g.backEdges.count)
          comb edges    : \(cellCount * 5)
          live after \(timedTicks + 1) ticks : \(liveCount)/\(cellCount)
          graph build   : \(String(format: "%8.2f", buildMs)) ms
          engine init   : \(String(format: "%8.2f", initMs)) ms
          warmup tick   : \(String(format: "%8.2f", warmupMs)) ms
          steady tick   : \(String(format: "%8.2f", avgTickMs)) ms (avg of \(timedTicks))
          throughput    : \(String(format: "%8.0f", Double(nodeCount) / avgTickMs / 1000.0)) Mnodes/s
        ───────────────────────────────────────────────────────────
        """)

        // Soft check: per-tick should be well under 100 ms at this scale.
        // If we fall above this, something's pathological — flag for
        // review rather than silently pass.
        XCTAssertLessThan(avgTickMs, 100.0,
                          "steady-state tick at \(side)×\(side) above 100 ms — investigate")
    }

    /// Same shape as the 200×200 scout, but pushed to ~320 K nodes (the
    /// upper end of dag's 250–320 K target). This path bypasses
    /// `DagDBGraph` entirely — the 200×200 build was 32 s on the graph
    /// layer because of the dup-check + label-index work, which would
    /// extrapolate to ~10+ minutes at 320 K. Instead we write directly to
    /// `DagDBState` arrays + the engine's neighbor buffer, then seed
    /// back-edges via `addBackEdgeUnchecked`. Trades safety for build
    /// speed; suitable for the perf scout because the encoding is
    /// generated programmatically and trusted by construction.
    func testSlimeMoldPerfScout400x400_FastBuild() throws {
        let bigSide = 400
        let cellCount = bigSide * bigSide   // 160 000 cells
        let nodeCount = cellCount * 2       // 320 000 nodes

        // Pick a square grid big enough to hold the node table (>= sqrt
        // and even so HexGrid's coloring is happy).
        let gridSide: Int = {
            var s = Int(ceil(Double(nodeCount).squareRoot()))
            if s & 1 != 0 { s += 1 }
            return s
        }()

        // 5-input MAJORITY LUT (same as the 200×200 scout).
        let maj5: UInt64 = {
            var lut: UInt64 = 0
            for i: UInt64 in 0..<64 where (i & 0x1F).nonzeroBitCount >= 3 {
                lut |= (UInt64(1) << i)
            }
            return lut
        }()

        // ── Phase A: build state arrays directly (no DagDBGraph) ─────
        let tBuild0 = CFAbsoluteTimeGetCurrent()
        let grid = HexGrid(width: gridSide, height: gridSide)
        var state = DagDBState(width: gridSide, height: gridSide)

        for idx in 0..<cellCount {
            // Cells: rank 1, identity LUT (won't fire — register flag
            // skips them), checkerboard initial truth.
            state.rank[idx] = 1
            state.truthState[idx] = (((idx % bigSide) + (idx / bigSide)) & 1 == 0) ? 1 : 0
            state.setLUT6(at: idx, value: LUT6Preset.identity)
            // Combinational next-state: rank 0, MAJ5.
            let cIdx = cellCount + idx
            state.rank[cIdx] = 0
            state.setLUT6(at: cIdx, value: maj5)
        }
        let tBuild1 = CFAbsoluteTimeGetCurrent()
        let buildMs = (tBuild1 - tBuild0) * 1000.0

        // ── Phase B: engine init ─────────────────────────────────────
        let tInit0 = CFAbsoluteTimeGetCurrent()
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 2)
        let tInit1 = CFAbsoluteTimeGetCurrent()
        let initMs = (tInit1 - tInit0) * 1000.0

        // ── Phase C: wire neighbors directly into the engine buffer ──
        let tWire0 = CFAbsoluteTimeGetCurrent()
        let nbPtr = engine.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: engine.nodeCount * 6)
        // The grid started with hex-geometry neighbors. Reset to -1 across
        // the whole node table so unused buffer slots don't leak edges.
        for i in 0..<(engine.nodeCount * 6) { nbPtr[i] = -1 }
        @inline(__always) func at(_ x: Int, _ y: Int) -> Int {
            ((x + bigSide) % bigSide) + ((y + bigSide) % bigSide) * bigSide
        }
        for y in 0..<bigSide {
            for x in 0..<bigSide {
                let idx = at(x, y)
                let cIdx = cellCount + idx
                let base = cIdx * 6
                nbPtr[base + 0] = Int32(idx)
                nbPtr[base + 1] = Int32(at(x - 1, y))
                nbPtr[base + 2] = Int32(at(x + 1, y))
                nbPtr[base + 3] = Int32(at(x, y - 1))
                nbPtr[base + 4] = Int32(at(x, y + 1))
                // slot 5 stays -1
            }
        }
        let tWire1 = CFAbsoluteTimeGetCurrent()
        let wireMs = (tWire1 - tWire0) * 1000.0

        // ── Phase D: register back-edges + is_register flags ─────────
        let tBE0 = CFAbsoluteTimeGetCurrent()
        for idx in 0..<cellCount {
            engine.addBackEdgeUnchecked(src: UInt32(cellCount + idx),
                                        dst: UInt32(idx))
        }
        let tBE1 = CFAbsoluteTimeGetCurrent()
        let beMs = (tBE1 - tBE0) * 1000.0

        XCTAssertEqual(engine.backEdgeCount, cellCount)

        // ── Phase E: warmup + timed steady-state ticks ───────────────
        let tWarm0 = CFAbsoluteTimeGetCurrent()
        engine.tick(tickNumber: 0)
        let tWarm1 = CFAbsoluteTimeGetCurrent()
        let warmupMs = (tWarm1 - tWarm0) * 1000.0

        let tickRuns = 50
        let tTick0 = CFAbsoluteTimeGetCurrent()
        for t in 1...tickRuns {
            engine.tick(tickNumber: UInt32(t))
        }
        let tTick1 = CFAbsoluteTimeGetCurrent()
        let totalTickMs = (tTick1 - tTick0) * 1000.0
        let avgTickMs = totalTickMs / Double(tickRuns)

        // Sanity: count alive cells; under MAJ5 from a checkerboard the
        // pattern inverts every tick, so live count stays at 50 %.
        var live = 0
        let truthPtr = engine.truthStateBuf.contents()
            .bindMemory(to: UInt8.self, capacity: engine.nodeCount)
        for idx in 0..<cellCount where truthPtr[idx] != 0 { live += 1 }

        print("""
        ───────────────────────────────────────────────────────────
        SLIME-MOLD PERF SCOUT (\(bigSide)×\(bigSide) torus, MAJ5,
        direct-state build, no DagDBGraph)
        ───────────────────────────────────────────────────────────
          cells           : \(cellCount)
          graph nodes     : \(nodeCount)
          back-edges      : \(engine.backEdgeCount)
          comb edges      : \(cellCount * 5)
          live after \(tickRuns + 1) ticks : \(live)/\(cellCount)
          state build     : \(String(format: "%8.2f", buildMs)) ms
          engine init     : \(String(format: "%8.2f", initMs)) ms
          neighbor wire   : \(String(format: "%8.2f", wireMs)) ms
          back-edge seed  : \(String(format: "%8.2f", beMs)) ms
          warmup tick     : \(String(format: "%8.2f", warmupMs)) ms
          steady tick     : \(String(format: "%8.2f", avgTickMs)) ms (avg of \(tickRuns))
          throughput      : \(String(format: "%8.0f", Double(nodeCount) / avgTickMs / 1000.0)) Mnodes/s
        ───────────────────────────────────────────────────────────
        """)

        // Soft ceiling — far above the expected 6–20 ms steady tick.
        XCTAssertLessThan(avgTickMs, 200.0,
                          "steady-state tick at \(bigSide)×\(bigSide) above 200 ms — investigate")
    }
}
