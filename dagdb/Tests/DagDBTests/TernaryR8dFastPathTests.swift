import XCTest
@testable import DagDB

/// The binary-only fast path.
///
/// The engine keeps an exact count of non-binary nodes; while it is 0, `tick`,
/// `tickLegacy` and `tickSync` dispatch main's kernels (`dagdb_tick_rank_binary`,
/// `dagdb_tick_sync_binary`) with main's bindings. Gated here:
///   (i)   the fast path is taken iff the graph is binary-only: left on the first
///         non-binary node, re-entered when the count returns to 0; every write
///         path (single, bulk, load, replay, import, backup, reader session, tile
///         engines) keeps the count exact by itself (`nonBinaryCountTracked`);
///   (ii)  on binary-only graphs the fast kernel writes the same bytes as the
///         CPU reference and as the general kernel (`TernaryR1BinaryControlTests`
///         and `TernaryR3KernelTests` run unchanged);
///   (iii) the forced inline shader carries the fast kernels too and equals the
///         bundle's on them, bit for bit.
final class TernaryR8dFastPathTests: XCTestCase {

    private var tmp: String!
    private let side = 16

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "tern-r8d-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let d = tmp { try? FileManager.default.removeItem(atPath: d) } }

    // MARK: - Objects

    /// A binary graph: ranks i % 4, random LUTs, each node at rank r reading
    /// up to three nodes at rank r + 1, a register, Loom bytes. No mode write.
    private func binaryEngine() throws -> DagDBEngine {
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side), maxRank: 8)
        let n = e.nodeCount
        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let low = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high = e.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        for i in 0..<n {
            rank[i] = UInt64(i % 4)
            low[i] = UInt32(truncatingIfNeeded: i &* 2654435761)
            high[i] = UInt32(truncatingIfNeeded: i &* 40503 &+ 7)
            truth[i] = UInt8((i * 37) % 256)
            for d in 0..<6 { nb[i * 6 + d] = -1 }
        }
        for i in 0..<n where rank[i] < 3 {
            var slot = 0
            for j in 0..<n where rank[j] == rank[i] + 1 && (j + i) % 5 == 0 && slot < 3 {
                nb[i * 6 + slot] = Int32(j); slot += 1
            }
        }
        for d in 0..<6 { nb[3 * 6 + d] = -1 }
        try e.addBackEdge(src: 6, dst: 3)
        e.markRankTopologyDirty()
        return e
    }

    /// Make `count` nodes ternary through the engine's own writes: a library,
    /// table ids and thresholds, then TTABLE / TTHRESH (NOSKIP on half) on the
    /// non-register nodes 8, 9, 10, … Truth bytes are set to trit bytes first.
    private func makeTernary(_ e: DagDBEngine, count: Int) throws {
        if e.ttableCount == 0 {
            try e.writeTables(first: 0, bytes: try TernaryReference.presetTable(.tsum, k: 3))
        }
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: e.nodeCount)
        for k in 0..<count {
            let i = 8 + k
            truth[i] = UInt8(i % 3)
            e.ttableIdPtr[i] = 0
            e.thrLoPtr[i] = -0.5; e.thrHiPtr[i] = 0.5
            e.setNodeMode(i, UInt8(1 + k % 2) | (k % 4 < 2 ? 4 : 0))
        }
        XCTAssertNil(e.ternaryStateViolation())
    }

    /// The count, its independent scan and the kernel of all three tick
    /// paths — and whether the count was kept by the writes alone.
    private func assertPath(_ e: DagDBEngine, nonBinary: Int, tracked: Bool = true, _ what: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(e.ternaryNodeCount(), nonBinary, "\(what): the lane scan", file: file, line: line)
        XCTAssertEqual(e.nonBinaryNodeCount, nonBinary, "\(what): the engine's count", file: file, line: line)
        XCTAssertEqual(e.nonBinaryCountTracked, tracked, "\(what): count kept by the writes", file: file, line: line)
        let want: DagDBEngine.TickKernel = nonBinary == 0 ? .binaryOnly : .general
        e.tick(tickNumber: 1)
        XCTAssertEqual(e.lastTickKernel, want, "\(what): tick", file: file, line: line)
        e.tickLegacy(tickNumber: 2)
        XCTAssertEqual(e.lastTickKernel, want, "\(what): tickLegacy", file: file, line: line)
        e.tickSync(tickNumber: 3)
        XCTAssertEqual(e.lastTickKernel, want, "\(what): tickSync", file: file, line: line)
    }

    // MARK: - (i) taken iff binary-only, through the engine's write paths

    func testFastPathTakenIffBinaryOnly() throws {
        let e = try binaryEngine()
        XCTAssertNil(e.lastTickKernel)
        assertPath(e, nonBinary: 0, "fresh binary graph")

        // Left on the first non-binary node.
        try makeTernary(e, count: 1)
        assertPath(e, nonBinary: 1, "first non-binary node (SET MODE)")
        try makeTernary(e, count: 3)
        assertPath(e, nonBinary: 3, "three non-binary nodes")
        e.setNodeMode(9, 2)                         // non-binary → non-binary: no change
        assertPath(e, nonBinary: 3, "kind changed, still non-binary")
        e.setNodeMode(8, 0); e.setNodeMode(9, 0)
        assertPath(e, nonBinary: 1, "two back to BINARY")
        // Re-entered when the count returns to 0 (SET MODE back to BINARY).
        e.setNodeMode(10, 0)
        assertPath(e, nonBinary: 0, "the last one back to BINARY")
        e.setNodeMode(10, 0)                        // binary → binary: no change
        assertPath(e, nonBinary: 0, "BINARY written over BINARY")

        // Bulk: a whole lane in, then zeros.
        let n = e.nodeCount
        var lane = [UInt8](repeating: 0, count: n)
        for i in stride(from: 8, to: n, by: 7) where i != 3 { lane[i] = UInt8([1, 2, 5, 6][i % 4]) }
        let want = lane.filter { $0 != 0 }.count
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        for i in 0..<n where lane[i] != 0 { truth[i] = UInt8(i % 3) }
        lane.withUnsafeBytes { e.replaceModeLane(from: $0.baseAddress!) }
        assertPath(e, nonBinary: want, "bulk lane with \(want) non-binary nodes")
        let zeros = [UInt8](repeating: 0, count: n)
        zeros.withUnsafeBytes { e.replaceModeLane(from: $0.baseAddress!) }
        assertPath(e, nonBinary: 0, "bulk lane of zeros")
        e.writeModeLane { $0[20] = 2; $0[21] = 1 }
        assertPath(e, nonBinary: 2, "writeModeLane")
        e.resetTernaryLanes()
        assertPath(e, nonBinary: 0, "resetTernaryLanes")

        // Engine init from a state that carries non-binary nodes.
        var st = DagDBState(width: side, height: side)
        st.nodeMode[30] = 2; st.nodeMode[31] = 6
        let f = try DagDBEngine(grid: try HexGrid(width: side, height: side), state: st, maxRank: 8)
        assertPath(f, nonBinary: 2, "engine init from a state")
    }

    /// The public raw lane (`modePtr`, `nodeModeBuf`) hands out writes the
    /// engine cannot see: from the first such access every count read — every
    /// tick included — recounts, so even a pointer kept across ticks cannot
    /// leave the count stale.
    func testRawLaneAccessFallsBackToRecountingEveryTick() throws {
        let e = try binaryEngine()
        assertPath(e, nonBinary: 0, "before raw access")
        e.truthStateBuf.contents().storeBytes(of: 2, toByteOffset: 12, as: UInt8.self)
        e.modePtr[12] = 2
        assertPath(e, nonBinary: 1, tracked: false, "a write through modePtr")
        let held = e.modePtr
        held[12] = 0
        assertPath(e, nonBinary: 0, tracked: false, "the held pointer clears it")
        held[13] = 6
        e.truthStateBuf.contents().storeBytes(of: 1, toByteOffset: 13, as: UInt8.self)
        assertPath(e, nonBinary: 1, tracked: false, "the held pointer writes after two ticks")
        e.nodeModeBuf.contents().storeBytes(of: 0, toByteOffset: 13, as: UInt8.self)
        assertPath(e, nonBinary: 0, tracked: false, "a write through nodeModeBuf")
        // Reads through `modeLane` never hand the lane out.
        let g = try binaryEngine()
        try makeTernary(g, count: 2)
        _ = g.modeLane[8]; _ = g.firstNonBinaryNode(); _ = g.hasTernaryContent(); _ = g.ternaryStateViolation()
        assertPath(g, nonBinary: 2, "reads through modeLane")
    }

    // MARK: - (i) every load, import, replay and copy path keeps the count exact

    func testEveryLoadReplayImportAndCopyPathKeepsTheCountExact() throws {
        let k = 5
        let src = try binaryEngine()
        try makeTernary(src, count: k)
        let bin = try binaryEngine()
        let n = src.nodeCount

        // .dags v8 (ternary content) and v7 (binary), each loaded both ways.
        let v8 = tmp + "t.dags", v7 = tmp + "b.dags"
        _ = try DagDBSnapshot.save(engine: src, nodeCount: n, gridW: side, gridH: side, tickCount: 0, path: v8)
        _ = try DagDBSnapshot.save(engine: bin, nodeCount: n, gridW: side, gridH: side, tickCount: 0, path: v7)
        do {
            let e = try binaryEngine()
            _ = try DagDBSnapshot.load(engine: e, nodeCount: n, gridW: side, gridH: side, path: v8)
            assertPath(e, nonBinary: k, "LOAD v8 into a binary engine")
            _ = try DagDBSnapshot.load(engine: e, nodeCount: n, gridW: side, gridH: side, path: v7)
            assertPath(e, nonBinary: 0, "LOAD v7 into a ternary engine")
        }
        // Morton: with the lane files, then without them (an eleven-file export).
        do {
            let dir = tmp + "morton"
            _ = try DagDBSnapshot.exportMorton(engine: src, nodeCount: n, dir: dir)
            let e = try binaryEngine()
            _ = try DagDBSnapshot.importMorton(engine: e, nodeCount: n, dir: dir)
            assertPath(e, nonBinary: k, "IMPORT MORTON with mode.bin")
            for f in ["mode.bin", "ttable_id.bin", "thr_lo.bin", "thr_hi.bin", "ttables.bin"] {
                try FileManager.default.removeItem(atPath: dir + "/" + f)
            }
            _ = try DagDBSnapshot.importMorton(engine: e, nodeCount: n, dir: dir)
            assertPath(e, nonBinary: 0, "IMPORT MORTON without the lane files")
        }
        // JSON v2 and CSV v2, then the binary graph's (all-BINARY lanes).
        do {
            let e = try binaryEngine()
            _ = try DagDBJSONIO.saveJSON(engine: src, nodeCount: n, gridW: side, gridH: side, tickCount: 0, path: tmp + "t.json")
            _ = try DagDBJSONIO.saveJSON(engine: bin, nodeCount: n, gridW: side, gridH: side, tickCount: 0, path: tmp + "b.json")
            _ = try DagDBJSONIO.loadJSON(engine: e, nodeCount: n, gridW: side, gridH: side, path: tmp + "t.json")
            assertPath(e, nonBinary: k, "LOAD JSON v2")
            _ = try DagDBJSONIO.loadJSON(engine: e, nodeCount: n, gridW: side, gridH: side, path: tmp + "b.json")
            assertPath(e, nonBinary: 0, "LOAD JSON v2, binary graph")
            _ = try DagDBJSONIO.saveCSV(engine: src, nodeCount: n, dir: tmp + "tcsv")
            _ = try DagDBJSONIO.loadCSV(engine: e, nodeCount: n, dir: tmp + "tcsv")
            assertPath(e, nonBinary: k, "LOAD CSV v2")
            // A v1 CSV directory (no lanes.csv) describes a binary graph.
            try FileManager.default.removeItem(atPath: tmp + "tcsv/lanes.csv")
            _ = try DagDBJSONIO.loadCSV(engine: e, nodeCount: n, dir: tmp + "tcsv")
            assertPath(e, nonBinary: 0, "LOAD CSV v1")
        }
        // Backup: a binary base, then a diff carrying the ternary nodes; restore.
        do {
            let dir = tmp + "chain"
            let a = try binaryEngine()
            _ = try DagDBBackup.initializeChain(engine: a, nodeCount: n, gridW: side, gridH: side, tickCount: 0, dir: dir)
            try makeTernary(a, count: k)
            XCTAssertEqual(try DagDBBackup.appendDiff(engine: a, nodeCount: n, gridW: side, gridH: side, dir: dir).format, 3)
            let e = try binaryEngine()
            _ = try DagDBBackup.restore(engine: e, nodeCount: n, gridW: side, gridH: side, dir: dir)
            assertPath(e, nonBinary: k, "backup restore (diff 3)")
            for i in 8..<(8 + k) { a.setNodeMode(i, 0) }
            _ = try DagDBBackup.appendDiff(engine: a, nodeCount: n, gridW: side, gridH: side, dir: dir)
            _ = try DagDBBackup.restore(engine: e, nodeCount: n, gridW: side, gridH: side, dir: dir)
            assertPath(e, nonBinary: 0, "backup restore after the nodes went back to BINARY")
        }
        // WAL v3 replay: single records and the bulk record.
        do {
            let path = tmp + "t.wal"
            do {
                let w = try DagDBWAL.Appender(path: path, nodeCount: n)
                _ = try w.ttablePreset(tid: 0, preset: .tsum, k: 3)
                _ = try w.setMode(node: 8, mode: 1)
                _ = try w.setMode(node: 9, mode: 6)
                _ = try w.setMode(node: 8, mode: 0)
            }
            let e = try binaryEngine()
            // The replayed mode records check the truth they land on (< 3).
            for i in [8, 9] { e.truthStateBuf.contents().storeBytes(of: 2, toByteOffset: i, as: UInt8.self) }
            let r = try DagDBWAL.replay(engine: e, nodeCount: n, path: path)
            XCTAssertEqual(r.recordsSkipped, 0, "\(r.refusals)")
            assertPath(e, nonBinary: 1, "WAL replay, single records")
            let path2 = tmp + "t2.wal"
            do {
                let w2 = try DagDBWAL.Appender(path: path2, nodeCount: n)
                var modes = [UInt8](repeating: 0, count: n)
                for i in [40, 41, 42, 43] { modes[i] = 2 }
                _ = try w2.setModesBulk(&modes, count: n)
            }
            let e2 = try binaryEngine()
            for i in [40, 41, 42, 43] { e2.truthStateBuf.contents().storeBytes(of: 2, toByteOffset: i, as: UInt8.self) }
            let r2 = try DagDBWAL.replay(engine: e2, nodeCount: n, path: path2)
            XCTAssertEqual(r2.recordsSkipped, 0, "\(r2.refusals)")
            assertPath(e2, nonBinary: 4, "WAL replay, SET_MODES_BULK")
        }
        // A reader session's snapshot engine.
        do {
            let mgr = DagDBReaderSessionManager()
            let s = try mgr.open(primary: src, grid: try HexGrid(width: side, height: side),
                                 stateTemplate: DagDBState(width: side, height: side), maxRank: 8, tickCount: 0)
            assertPath(s.snapshotEngine, nonBinary: k, "reader session snapshot")
            let sb = try mgr.open(primary: bin, grid: try HexGrid(width: side, height: side),
                                  stateTemplate: DagDBState(width: side, height: side), maxRank: 8, tickCount: 0)
            assertPath(sb.snapshotEngine, nonBinary: 0, "reader session snapshot, binary graph")
        }
    }

    /// Tile engines — the plain tile load and the ghosted one the tiled tick
    /// runs — on the tiling tests' side-44 object, binary and mixed (the object of
    /// `TernaryR6TilingTests`).
    func testTileEnginesKeepTheCountExact() throws {
        for mixed in [false, true] {
            let o = try TiledFixture.generate(side: 44)
            if mixed { try TiledReference.mixTernary(engine: o.engine, side: 44) }
            let dir = tmp + "tiles_\(mixed)"
            _ = try TiledGraphFiles.write(object: o, dataRoot: dir, name: "g",
                                          boundaries: TiledFixture.boundaries(side: 44, tiles: 4))
            let manifest = try TiledGraphFiles.readManifest(dataRoot: dir, name: "g")
            var total = 0
            for entry in manifest.tiles {
                let t = try TiledGraphFiles.loadTile(dataRoot: dir, name: "g", manifest: manifest, tileId: entry.id).engine
                let c = t.ternaryNodeCount()
                total += c
                assertPath(t, nonBinary: c, "mixed=\(mixed) tile \(entry.id)")
                let g = try TiledGraphFiles.loadTileWithGhosts(dataRoot: dir, name: "g", manifest: manifest, tileId: entry.id).engine
                XCTAssertEqual(g.ternaryNodeCount(), c, "ghosts are BINARY")
                assertPath(g, nonBinary: c, "mixed=\(mixed) ghosted tile \(entry.id)")
            }
            XCTAssertEqual(total, o.engine.ternaryNodeCount(), "mixed=\(mixed): the tiles hold every non-binary node")
            if mixed { XCTAssertGreaterThan(total, 0) } else { XCTAssertEqual(total, 0) }
        }
    }

    // MARK: - (ii) and (iii) the fast kernel's bytes

    /// The objects of `TernaryR3KernelTests` (20 seeds × 64², 256², 1024²) with every node made BINARY —
    /// Loom bytes, registers, back edges, absent slots of both shapes kept;
    /// rank and sync; N ∈ {1, 5, 20}. At every checkpoint the fast kernel
    /// (bundle) equals the CPU reference, the forced inline shader's fast
    /// kernel, the general kernel on the same graph (fast path switched off)
    /// and, in rank mode, `tickLegacy` — bit for bit.
    func testFastKernelEqualsReferenceInlineGeneralAndLegacyOnBinaryGraphs() throws {
        typealias R3 = TernaryR3KernelTests
        var cells = 0, moves = 0
        let modes = ["rank", "sync"]
        for side in R3.sides {
            let grid = try HexGrid(width: side, height: side)
            let colors = R3.colorOf(grid)
            let t0 = Date()
            var graphs = [R3.Mixed?](repeating: nil, count: R3.seedsPerSize)
            var expected = [R3.Expected?](repeating: nil, count: R3.seedsPerSize * modes.count)
            var binaryMoves = [Int](repeating: 0, count: R3.seedsPerSize * modes.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: R3.seedsPerSize) { s in
                let seed = UInt64(0x7E1D_0000) &+ UInt64(side) << 8 &+ UInt64(s)
                let m = R3.makeMixed(grid: grid, colorOf: colors, seed: seed)
                var ref = m.ref
                ref.mode = [UInt8](repeating: 0, count: ref.nodeCount)
                let b = R3.Mixed(grid: grid, ref: ref, colorOf: colors)
                lock.lock(); graphs[s] = b; lock.unlock()
            }
            DispatchQueue.concurrentPerform(iterations: expected.count) { j in
                let m = graphs[j / modes.count]!
                let e = R3.reference(m, mode: modes[j % modes.count])
                let last = e.atCheckpoint[R3.checkpoints.last!]!
                var mv = 0
                for i in 0..<last.count where last[i] != m.ref.truth[i] { mv += 1 }
                lock.lock(); expected[j] = e; binaryMoves[j] = mv; lock.unlock()
            }
            moves += binaryMoves.reduce(0, +)
            for s in 0..<R3.seedsPerSize {
                let m = graphs[s]!
                // One autorelease pool per (seed, mode). Without it the
                // test method's pool kept about 34 bytes per node per engine (240 MB
                // per 1024² seed) until the method returned: 7.3 GB at the last seed.
                for (mi, mode) in modes.enumerated() { try autoreleasepool {
                    let exp = expected[s * modes.count + mi]!
                    let fast = try R3.makeEngine(m)
                    let inl = try R3.makeEngine(m, library: .inlineSource)
                    let gen = try R3.makeEngine(m)
                    gen.binaryFastPathEnabled = false
                    XCTAssertFalse(fast.usedInlineShader); XCTAssertTrue(inl.usedInlineShader)
                    XCTAssertEqual(fast.nonBinaryNodeCount, 0); XCTAssertTrue(fast.nonBinaryCountTracked)
                    let legacy = mode == "rank" ? try R3.makeEngine(m) : nil
                    for t in 0..<R3.checkpoints.last! {
                        if mode == "rank" {
                            fast.tick(tickNumber: UInt32(t)); inl.tick(tickNumber: UInt32(t))
                            gen.tick(tickNumber: UInt32(t)); legacy!.tickLegacy(tickNumber: UInt32(t))
                            XCTAssertEqual(legacy!.lastTickKernel, .binaryOnly)
                        } else {
                            fast.tickSync(tickNumber: UInt32(t)); inl.tickSync(tickNumber: UInt32(t))
                            gen.tickSync(tickNumber: UInt32(t))
                        }
                        XCTAssertEqual(fast.lastTickKernel, .binaryOnly)
                        XCTAssertEqual(inl.lastTickKernel, .binaryOnly)
                        XCTAssertEqual(gen.lastTickKernel, .general)
                        guard let want = exp.atCheckpoint[t + 1] else { continue }
                        let f = fast.readTruthStates()
                        let tag = "side \(side) seed \(s) \(mode) N=\(t + 1)"
                        XCTAssertTrue(f == want, "\(tag) fast vs CPU: \(R3.firstDiff(f, want))")
                        let iv = inl.readTruthStates()
                        XCTAssertTrue(iv == f, "\(tag) inline fast vs bundle fast: \(R3.firstDiff(iv, f))")
                        let gv = gen.readTruthStates()
                        XCTAssertTrue(gv == f, "\(tag) general vs fast: \(R3.firstDiff(gv, f))")
                        if let l = legacy {
                            let lv = l.readTruthStates()
                            XCTAssertTrue(lv == f, "\(tag) tickLegacy vs tick: \(R3.firstDiff(lv, f))")
                        }
                        cells += 1
                    }
                } }
            }
            print(String(format: "R8d binary side=%d seeds=%d total %.1fs", side, R3.seedsPerSize, Date().timeIntervalSince(t0)))
        }
        XCTAssertEqual(cells, R3.sides.count * R3.seedsPerSize * 2 * R3.checkpoints.count)
        XCTAssertGreaterThan(moves, 0)
        print("R8d fast-kernel cells=\(cells) binary_bytes_moved_at_N20=\(moves)")
    }

    /// The objects above are not vacuous: per size (seed 0) Loom bytes,
    /// registers and absent slots of both shapes are present, every node is
    /// BINARY, and one tick moves bytes.
    func testBinaryObjectsCarryLoomRegistersAndBothAbsentShapes() throws {
        typealias R3 = TernaryR3KernelTests
        for side in R3.sides {
            let grid = try HexGrid(width: side, height: side)
            let colors = R3.colorOf(grid)
            var ref = R3.makeMixed(grid: grid, colorOf: colors, seed: 0x7E1D_0000 &+ UInt64(side) << 8).ref
            ref.mode = [UInt8](repeating: 0, count: ref.nodeCount)
            var regs = 0, minus1 = 0, oor = 0, loom = 0
            for i in 0..<ref.nodeCount {
                if ref.isRegister[i] != 0 { regs += 1 }
                if ref.truth[i] >= 3 { loom += 1 }
                for d in 0..<6 {
                    let v = ref.neighbors[i * 6 + d]
                    if v == -1 { minus1 += 1 } else if Int(v) >= ref.nodeCount { oor += 1 }
                }
            }
            let before = ref.truth
            TernaryReference.tickRank(&ref, tickNumber: 0, colorOf: colors, colorCount: HexGrid.colorCount)
            var moved = 0
            for i in 0..<ref.nodeCount where ref.truth[i] != before[i] { moved += 1 }
            print("R8d binary object side=\(side): registers=\(regs) slots(-1)=\(minus1) slots(>=n)=\(oor) loom=\(loom) moved_by_1_tick=\(moved)")
            XCTAssertTrue(ref.mode.allSatisfy { $0 == 0 })
            XCTAssertGreaterThan(regs, 0); XCTAssertGreaterThan(minus1, 0)
            XCTAssertGreaterThan(oor, 0); XCTAssertGreaterThan(loom, 0); XCTAssertGreaterThan(moved, 0)
        }
    }
}
