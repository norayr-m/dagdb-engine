import XCTest
import CryptoKit
@testable import DagDB

/// GPU equals the CPU reference (control).
///
/// Random mixed graphs — binary, TTABLE, TTHRESH, NOSKIP on and off,
/// registers, back edges, absent slots (−1 and ≥ node count), Loom bytes —
/// 20 seeds × sizes 4,096, 65,536 and 1,048,576; rank and sync mode;
/// N ∈ {1, 5, 20}; bit for bit against `TernaryReference`. The inline
/// shader, forced, equals the bundle's; `tickLegacy` agrees.
final class TernaryR3KernelTests: XCTestCase {

    struct SplitMix64 {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    /// The sizes: 64², 256², 1024².
    static let sides = [64, 256, 1024]
    /// 20 seeds per size.
    static let seedsPerSize = 20
    static let checkpoints = [1, 5, 20]
    static let rankLevels = 16
    static let libraryTables = 16
    /// Weights drawn from values that make slot order observable in f32
    /// (±1e8 absorbs ±1) and land sums exactly on the thresholds below.
    static let weightPool: [Float] = [1, -1, 0.5, -0.5, 2, -2.5, 3.25, 1e8, -1e8, 0.1, -0.3, 0]
    /// Thresholds in half steps, so integer and half-integer sums hit them.
    static let thresholdPool: [Float] = [-3, -2.5, -2, -1.5, -1, -0.5, 0, 0.5, 1, 1.5, 2, 2.5, 3]

    struct Mixed {
        let grid: HexGrid
        let ref: TernaryReference.Graph
        let colorOf: [UInt8]
    }

    /// One random mixed graph. Slots read strictly higher ranks (or are
    /// absent), so no (rank, colour) segment reads itself; registers are
    /// BINARY, have no combinational slot, and latch
    /// one random node of any kind.
    static func makeMixed(grid: HexGrid, colorOf: [UInt8], seed: UInt64) -> Mixed {
        let n = grid.nodeCount
        var rng = SplitMix64(s: seed)
        var tables = [UInt8](repeating: 2, count: libraryTables * 729)
        for t in 0..<libraryTables {
            if t < TernaryReference.Preset.allCases.count {
                let p = TernaryReference.Preset.allCases[t]
                let k = p.arities.upperBound == 1 ? 1 : 1 + rng.below(6)
                let tb = try! TernaryReference.presetTable(p, k: k)
                for i in 0..<729 { tables[t * 729 + i] = tb[i] }
            } else {
                for i in 0..<729 { tables[t * 729 + i] = UInt8(rng.below(3)) }
            }
        }
        var truth = [UInt8](repeating: 0, count: n)
        var rank = [UInt64](repeating: 0, count: n)
        var low = [UInt32](repeating: 0, count: n), high = low
        var mode = [UInt8](repeating: 0, count: n)
        var tid = [UInt16](repeating: 0, count: n)
        var lo = [Float](repeating: 0, count: n), hi = lo
        var w = [Float](repeating: 1, count: n * 6)
        var isReg = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            rank[i] = UInt64(rng.below(rankLevels))
            low[i] = UInt32(truncatingIfNeeded: rng.next())
            high[i] = UInt32(truncatingIfNeeded: rng.next())
            let reg = rng.below(64) == 0
            let kind = rng.below(3)
            if reg || kind == 0 {
                mode[i] = 0
                truth[i] = UInt8(truncatingIfNeeded: rng.next())        // Loom codes included
            } else {
                mode[i] = UInt8(kind) | (rng.below(2) == 0 ? 4 : 0)     // NOSKIP on and off
                truth[i] = UInt8(rng.below(3))
            }
            isReg[i] = reg ? 1 : 0
            tid[i] = UInt16(rng.below(libraryTables))
            let a = thresholdPool[rng.below(thresholdPool.count)]
            let b = thresholdPool[rng.below(thresholdPool.count)]
            lo[i] = min(a, b); hi[i] = max(a, b)
            for d in 0..<6 { w[i * 6 + d] = weightPool[rng.below(weightPool.count)] }
        }
        var byRank = [[Int32]](repeating: [], count: rankLevels)
        for i in 0..<n { byRank[Int(rank[i])].append(Int32(i)) }
        var sorted = [Int32](); sorted.reserveCapacity(n)
        var start = [Int](repeating: 0, count: rankLevels + 1)
        for r in 0..<rankLevels { start[r] = sorted.count; sorted.append(contentsOf: byRank[r]) }
        start[rankLevels] = sorted.count
        var nb = [Int32](repeating: -1, count: n * 6)
        for i in 0..<n where isReg[i] == 0 {
            let first = start[Int(rank[i]) + 1]
            let count = n - first
            for d in 0..<6 {
                let u = rng.next()
                switch u % 16 {
                case 0, 1, 2, 3: nb[i * 6 + d] = -1                               // absent
                case 4: nb[i * 6 + d] = Int32(n + Int((u >> 8) % 1000))           // ≥ node count
                default:
                    if count > 0 { nb[i * 6 + d] = sorted[first + Int((u >> 8) % UInt64(count))] }
                }
            }
        }
        var srcs: [UInt32] = [], dsts: [UInt32] = []
        for i in 0..<n where isReg[i] != 0 {
            srcs.append(UInt32(rng.below(n))); dsts.append(UInt32(i))
        }
        let g = TernaryReference.Graph(
            truth: truth, rank: rank, lutLow: low, lutHigh: high, neighbors: nb,
            isRegister: isReg, edgeWeights: w, mode: mode, ttableId: tid, thrLo: lo, thrHi: hi,
            tables: tables, backEdgeSrcs: srcs, backEdgeDsts: dsts)
        return Mixed(grid: grid, ref: g, colorOf: colorOf)
    }

    static func makeEngine(_ m: Mixed, library: DagDBEngine.ShaderLibrary = .automatic) throws -> DagDBEngine {
        var st = DagDBState(width: m.grid.width, height: m.grid.height)
        let g = m.ref
        st.truthState = g.truth; st.rank = g.rank; st.lut6Low = g.lutLow; st.lut6High = g.lutHigh
        st.edgeWeights = g.edgeWeights; st.nodeMode = g.mode; st.ttableId = g.ttableId
        st.thrLo = g.thrLo; st.thrHi = g.thrHi; st.ttables = g.tables
        let e = try DagDBEngine(grid: m.grid, state: st, maxRank: rankLevels, shaderLibrary: library)
        let p = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { p[i] = g.neighbors[i] }
        for i in 0..<g.backEdgeSrcs.count {
            try e.addBackEdge(src: g.backEdgeSrcs[i], dst: g.backEdgeDsts[i])
        }
        return e
    }

    static func colorOf(_ grid: HexGrid) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: grid.nodeCount)
        for (k, group) in grid.colorGroups.enumerated() { for m in group { c[Int(m)] = UInt8(k) } }
        return c
    }

    static func firstDiff(_ a: [UInt8], _ b: [UInt8]) -> String {
        var count = 0, first = -1
        for i in 0..<min(a.count, b.count) where a[i] != b[i] { count += 1; if first < 0 { first = i } }
        return count == 0 ? "equal" : "\(count) bytes differ, first node \(first) (\(a[first]) vs \(b[first]))"
    }

    // MARK: - The gate

    /// The CPU reference's truth at every checkpoint, for one (seed, mode),
    /// and how many ternary-node bytes it moved over the run.
    struct Expected { var atCheckpoint: [Int: [UInt8]] = [:]; var ternaryMoves = 0 }

    static func reference(_ m: Mixed, mode: String) -> Expected {
        var ref = m.ref
        var e = Expected()
        for t in 0..<checkpoints.last! {
            let before = ref.truth
            if mode == "rank" {
                TernaryReference.tickRank(&ref, tickNumber: UInt32(t), colorOf: m.colorOf,
                                          colorCount: HexGrid.colorCount)
            } else {
                TernaryReference.tickSync(&ref)
            }
            ref.truth.withUnsafeBufferPointer { a in before.withUnsafeBufferPointer { b in
                ref.mode.withUnsafeBufferPointer { md in
                    for i in 0..<a.count where md[i] != 0 && a[i] != b[i] { e.ternaryMoves += 1 }
                }
            }}
            if checkpoints.contains(t + 1) { e.atCheckpoint[t + 1] = ref.truth }
        }
        return e
    }

    func testR3GPUEqualsCPUReferenceAndInlineAndLegacy() throws {
        var cells = 0
        var ternaryMoves = 0
        let modes = ["rank", "sync"]
        for side in Self.sides {
            let grid = try HexGrid(width: side, height: side)
            let colors = Self.colorOf(grid)
            let t0 = Date()
            // The objects and the CPU reference, in parallel (the reference
            // never touches the GPU); the GPU runs below, one engine at a time.
            var graphs = [Mixed?](repeating: nil, count: Self.seedsPerSize)
            var expected = [Expected?](repeating: nil, count: Self.seedsPerSize * modes.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: Self.seedsPerSize) { s in
                let seed = UInt64(0x7E13_0000) &+ UInt64(side) << 8 &+ UInt64(s)
                let m = Self.makeMixed(grid: grid, colorOf: colors, seed: seed)
                lock.lock(); graphs[s] = m; lock.unlock()
            }
            DispatchQueue.concurrentPerform(iterations: expected.count) { j in
                let e = Self.reference(graphs[j / modes.count]!, mode: modes[j % modes.count])
                lock.lock(); expected[j] = e; lock.unlock()
            }
            let tRef = Date().timeIntervalSince(t0)
            for s in 0..<Self.seedsPerSize {
                let m = graphs[s]!
                // One autorelease pool per (seed, mode), so what the engines'
                // setup and ticks autorelease is freed here, not when the method returns.
                for (mi, mode) in modes.enumerated() { try autoreleasepool {
                    let exp = expected[s * modes.count + mi]!
                    ternaryMoves += exp.ternaryMoves
                    let gpu = try Self.makeEngine(m)
                    let inl = try Self.makeEngine(m, library: .inlineSource)
                    XCTAssertFalse(gpu.usedInlineShader, "the default engine must use the bundle's library")
                    XCTAssertTrue(inl.usedInlineShader)
                    let legacy = mode == "rank" ? try Self.makeEngine(m) : nil
                    for t in 0..<Self.checkpoints.last! {
                        if mode == "rank" {
                            gpu.tick(tickNumber: UInt32(t))
                            inl.tick(tickNumber: UInt32(t))
                            legacy!.tickLegacy(tickNumber: UInt32(t))
                        } else {
                            gpu.tickSync(tickNumber: UInt32(t))
                            inl.tickSync(tickNumber: UInt32(t))
                        }
                        guard let want = exp.atCheckpoint[t + 1] else { continue }
                        let g = gpu.readTruthStates()
                        let iv = inl.readTruthStates()
                        XCTAssertTrue(g == want, "side \(side) seed \(s) \(mode) N=\(t + 1) GPU vs CPU: \(Self.firstDiff(g, want))")
                        XCTAssertTrue(iv == g, "side \(side) seed \(s) \(mode) N=\(t + 1) inline vs bundle: \(Self.firstDiff(iv, g))")
                        if let l = legacy {
                            let lv = l.readTruthStates()
                            XCTAssertTrue(lv == g, "side \(side) seed \(s) N=\(t + 1) tickLegacy vs tick: \(Self.firstDiff(lv, g))")
                        }
                        cells += 1
                    }
                } }
            }
            print(String(format: "R3 side=%d seeds=%d reference %.1fs, total %.1fs", side, Self.seedsPerSize,
                         tRef, Date().timeIntervalSince(t0)))
        }
        // 3 sizes × 20 seeds × 2 modes × 3 checkpoints.
        XCTAssertEqual(cells, Self.sides.count * Self.seedsPerSize * 2 * Self.checkpoints.count)
        XCTAssertGreaterThan(ternaryMoves, 0)
        print("R3 cells=\(cells) ternary_node_changes=\(ternaryMoves)")
    }

    /// The pieces the sweep above must actually exercise, counted on one
    /// object per size so the sweep cannot be vacuous: every kind, NOSKIP
    /// both ways, registers, absent slots of both shapes, Loom bytes, and
    /// the ternary nodes' outputs spread over all three trits.
    func testR3ObjectsCarryEveryFeature() throws {
        for side in Self.sides {
            let grid = try HexGrid(width: side, height: side)
            let m = Self.makeMixed(grid: grid, colorOf: Self.colorOf(grid), seed: 0x7E13_0000 &+ UInt64(side) << 8)
            let g = m.ref
            var kinds = [0, 0, 0], noskip = 0, regs = 0, minus1 = 0, oor = 0, loom = 0
            for i in 0..<g.nodeCount {
                kinds[Int(g.mode[i] & 3)] += 1
                if g.mode[i] & 4 != 0 { noskip += 1 }
                if g.isRegister[i] != 0 { regs += 1 }
                if g.truth[i] >= 3 { loom += 1 }
                for d in 0..<6 {
                    let v = g.neighbors[i * 6 + d]
                    if v == -1 { minus1 += 1 } else if Int(v) >= g.nodeCount { oor += 1 }
                }
            }
            var ref = g
            TernaryReference.tickRank(&ref, tickNumber: 0, colorOf: m.colorOf, colorCount: HexGrid.colorCount)
            var trits = [0, 0, 0]
            for i in 0..<ref.nodeCount where ref.mode[i] != 0 { trits[Int(ref.truth[i])] += 1 }
            print("R3 object side=\(side): binary=\(kinds[0]) ttable=\(kinds[1]) tthresh=\(kinds[2]) noskip=\(noskip) registers=\(regs) slots(-1)=\(minus1) slots(>=n)=\(oor) loom=\(loom) trits after 1 tick: -=\(trits[0]) 0=\(trits[2]) +=\(trits[1])")
            XCTAssertTrue(kinds.allSatisfy { $0 > 0 })
            XCTAssertGreaterThan(noskip, 0); XCTAssertGreaterThan(regs, 0)
            XCTAssertGreaterThan(minus1, 0); XCTAssertGreaterThan(oor, 0); XCTAssertGreaterThan(loom, 0)
            XCTAssertTrue(trits.allSatisfy { $0 > 0 })
        }
    }
}

/// `tickWithResonance` (its 2 means "non-converged")
/// refuses a graph with any non-binary node, by name, before dispatching;
/// on a binary graph it runs as before.
final class TernaryT3ResonanceTests: XCTestCase {

    private func andGraph() throws -> DagDBEngine {
        let g = DagDBGraph()
        let a = g.addLeaf(label: "a", rank: 2, truth: true)
        let b = g.addLeaf(label: "b", rank: 2, truth: true)
        let r = g.addGate(label: "r", rank: 0, lut6: 0)
        var and2: UInt64 = 0                                  // AND of slots 0 and 1
        for i: UInt64 in 0..<64 where i & 3 == 3 { and2 |= 1 << i }
        let m = g.addGate(label: "m", rank: 1, lut6: and2)
        try g.connect(from: a, to: m)
        try g.connect(from: b, to: m)
        try g.connect(from: m, to: r)
        return try DagDBEngine(graph: g)
    }

    /// The binary behaviour is main's, written down from main's code (the
    /// function is unchanged but for the buffer bindings and the refusal):
    /// a rank "converges" only when, from the second micro-tick on, no node
    /// differs from the snapshot taken BEFORE the rank's micro-ticks. Rank 2
    /// (constant leaves) and rank 0 (constant-0 root) never change; rank 1's
    /// AND node goes 0 → 1 on the first micro-tick and keeps differing from
    /// that snapshot, so rank 1 runs all 8 micro-ticks, does not converge,
    /// and the node is written 2 ("non-converged").
    func testResonanceRunsOnABinaryGraph() throws {
        let e = try andGraph()
        let r = try e.tickWithResonance(tickNumber: 0, maxMicroTicks: 8)
        XCTAssertEqual(r.microTicks, [2, 8, 2])
        XCTAssertEqual(r.converged, [true, false, true])
        XCTAssertEqual(Array(e.readTruthStates().prefix(4)), [1, 1, 0, 2])
    }

    func testResonanceRefusesANonBinaryGraphByName() throws {
        let e = try andGraph()
        try e.writeTables(first: 0, bytes: try TernaryReference.presetTable(.tmin, k: 2))
        e.modePtr[3] = TernaryReference.kindTTable
        let before = e.readTruthStates()
        XCTAssertThrowsError(try e.tickWithResonance(tickNumber: 0)) { err in
            XCTAssertTrue("\(err)".contains("tickWithResonance refuses a graph with a non-binary node (first: node 3"), "\(err)")
        }
        XCTAssertEqual(e.readTruthStates(), before, "a refusal dispatches nothing")
    }
}
