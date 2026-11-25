import XCTest
@testable import DagDB

/// Tiling (control).
///
/// A tiled world tick equals the untiled tick, bit for bit, for mixed
/// ternary graphs in rank and sync mode, on the tiling tests' fixed sides 16, 44 and
/// 128 × tilings 2, 4 and 8, K ∈ {1, 2}; three-way: tiled == untiled
/// engine == TiledReference (its ternary evaluator, written from the
/// rules). Tile engines carry the lanes and
/// the library (asserted on the written tile bodies).
///
/// The objects: the tiling tests' fixed objects (TiledFixture.generate), made mixed
/// by `TiledReference.mixTernary` — a third stay binary, a third TTABLE, a
/// third TTHRESH, NOSKIP on half the ternary nodes, weights and thresholds
/// from pools that land sums on the thresholds; registers stay binary;
/// Loom bytes on a quarter of the binary nodes and on
/// every register.
///
/// A review of this file against the tiling check, clause by clause (the WIP version
/// passed 7/7 on first contact, so it was read before it was believed), and
/// what was added — nothing was removed or loosened:
/// 1. "bit for bit … a tiled world tick": the WIP compared at N = 1, 2, 5, 12
///    only. Added: every world tick 1…12 of every cell, three-way, through a
///    router ticked one round per call; the WIP's multi-round calls
///    (worldTick(count: n − prev)) are kept on a second router over a second
///    copy of the same tiles and compared at N = 1, 2, 5, 12.
/// 2. "mixed": the WIP object held no Loom byte (the fixture's truth is
///    0…2). Added to the mixing pass, from a second stream.
/// 3. "Tile engines carry the lanes": lanes were checked on side 44 × 4
///    tiles at write time only, and only the library after ticking. Added:
///    every side × tiling × K, at write time AND after 12 flushes, both
///    directories — the four lanes, the weights and the library, node for
///    node.
/// 4. The object's power to fail, counted by the reference (never by the
///    engine) and asserted: every kind evaluated, all three output trits,
///    NOSKIP firing, TTHRESH sums ON a threshold, absent slots under
///    ternary nodes, and the reads only a ghost carries — ternary readers
///    taking −1, +1 and UNDEFINED across a tile, from ternary sources, Loom
///    bytes and registers read across.
/// 5. All nodes are compared (the router's truthArray covers every real
///    node, mapped back through engineIndexOf), as the WIP already did.
/// 6. Staticity (the standing check of the tiled-tick tests, "a control that
///    cannot fail is not a control"): the WIP object went STATIC on side 16 —
///    changed bytes per tick [164, 62, 9, 0, 0, …] in rank mode and
///    [181, 107, 77, 51, 41, 19, 9, 1, 0, 0, 0, 0] in sync (reference, the
///    WIP mixing pass verbatim) — because mixing drew the side's only
///    register source TTHRESH with random weights and thresholds and the
///    oscillator died; ticks 4…12 (rank) and 9…12 (sync) were free
///    equalities, the WIP's checkpoints N = 5 and 12 among them. The
///    object now keeps every oscillator alive in its source's own kind
///    (`mixTernary`), and the test asserts, from the reference, that every
///    tick of every cell changes bytes and ternary nodes, that every cell's
///    ghosts carry a changed byte into a ternary reader on some tick, and
///    that on every tick some tiling's do.
final class TernaryR6TilingTests: XCTestCase {

    static let ns = [1, 2, 5, 12]
    static let tilings = [2, 4, 8]
    static let ks = [1, 2]

    /// The frozen object for `side`, made mixed in place.
    static func mixedObject(side: Int) throws -> TiledFixture.Object {
        let o = try TiledFixture.generate(side: side)
        try TiledReference.mixTernary(engine: o.engine, side: side)
        return o
    }

    private func scratch(_ label: String) -> String {
        let d = NSTemporaryDirectory() + "dagdb-tern-r6-\(label)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    /// Every tile body under `dir` (after however many flushes): v8, the
    /// whole library, and node for node the four lanes and the six edge
    /// weights of the untiled graph (tile-local numbering mapped back
    /// through `engineIndexOf`). Returns the number of nodes checked.
    @discardableResult
    private func assertTileBodiesCarryLanes(
        dir: String, lanes L: TiledReference.TernaryLanes, nodeCount: Int, tag: String
    ) throws -> Int {
        let manifest = try TiledGraphFiles.readManifest(dataRoot: dir, name: "g")
        var nodes = 0
        var differing = 0
        for entry in manifest.tiles {
            let body = TiledGraphFiles.tileDirectory(dataRoot: dir, name: "g", entry: entry) + "/body.dags"
            let d = try Data(contentsOf: URL(fileURLWithPath: body))
            XCTAssertEqual(d[4], 8, "\(tag) tile \(entry.id) body is v8")
            let t = try TiledGraphFiles.loadTile(dataRoot: dir, name: "g", manifest: manifest, tileId: entry.id).engine
            XCTAssertEqual(t.libraryBytes(), L.tables, "\(tag) tile \(entry.id) library")
            let tw = t.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: max(t.nodeCount * 6, 1))
            for (local, global) in entry.engineIndexOf.enumerated() {
                let g = Int(global)
                var same = t.modePtr[local] == L.mode[g]
                    && t.ttableIdPtr[local] == L.ttableId[g]
                    && t.thrLoPtr[local].bitPattern == L.thrLo[g].bitPattern
                    && t.thrHiPtr[local].bitPattern == L.thrHi[g].bitPattern
                for s in 0..<6 where tw[local * 6 + s].bitPattern != L.weights[g * 6 + s].bitPattern { same = false }
                if !same { differing += 1 }
                nodes += 1
            }
        }
        XCTAssertEqual(differing, 0, "\(tag): \(differing) nodes whose tile body lanes/weights differ from the untiled graph's")
        XCTAssertEqual(nodes, nodeCount, "\(tag): every node in exactly one tile body")
        return nodes
    }

    private func run(side: Int, mode: TickMode) async throws {
        var cells = 0
        var tickCompares = 0
        var multiRoundCompares = 0
        var laneChecks = 0
        var crossTernaryReaders = 0
        let last = Self.ns.last!
        var sideCoverage: TiledReference.TernaryCoverage? = nil
        var crossChangedByTiling: [Int: [Int]] = [:]
        for tiles in Self.tilings {
            let boundaries = TiledFixture.boundaries(side: side, tiles: tiles)
            var tilingCoverage: TiledReference.TernaryCoverage? = nil
            for k in Self.ks {
                let untiled = try Self.mixedObject(side: side)
                let tiledSrc = try Self.mixedObject(side: side)
                let dir = scratch("s\(side)-t\(tiles)-k\(k)-\(mode)")
                let dirMulti = scratch("s\(side)-t\(tiles)-k\(k)-\(mode)-multi")
                defer {
                    try? FileManager.default.removeItem(atPath: dir)
                    try? FileManager.default.removeItem(atPath: dirMulti)
                }
                let cellTag = "side=\(side) tiles=\(tiles) K=\(k) mode=\(mode)"
                _ = try TiledGraphFiles.write(object: tiledSrc, dataRoot: dir, name: "g", boundaries: boundaries)
                _ = try TiledGraphFiles.write(object: tiledSrc, dataRoot: dirMulti, name: "g", boundaries: boundaries)
                let lanes = TiledReference.TernaryLanes(engine: untiled.engine)
                try assertTileBodiesCarryLanes(dir: dir, lanes: lanes, nodeCount: untiled.nodeCount,
                                               tag: "\(cellTag) written")
                laneChecks += 1
                let router = try await TiledGraphRouter(dataRoot: dir, graphName: "g", maxResidentTiles: k)
                let routerMulti = try await TiledGraphRouter(dataRoot: dirMulti, graphName: "g", maxResidentTiles: k)

                let ref = TiledReference(engine: untiled.engine)
                var refVector = untiled.engine.readTruthStates()
                let tileOf = ref.tileAssignment(boundaries: boundaries)
                let crossings = ref.crossings(tileOf: tileOf)
                let ternaryReaders = crossings.filter { lanes.mode[$0.reader] != 0 }.count
                // The reference is the same at every K; count once per tiling.
                let cov: TiledReference.TernaryCoverage? = k == Self.ks.first
                    ? TiledReference.TernaryCoverage(tileOf: tileOf, mode: lanes.mode, isRegister: ref.isRegister)
                    : nil
                if cov != nil { crossTernaryReaders += ternaryReaders }

                // Router A: one world tick per call, three-way at every tick.
                var wantAt: [Int: [UInt8]] = [:]
                var movedTernary = 0
                var changedPerTick: [Int] = []
                var ternaryChangedPerTick: [Int] = []
                // Ghost traffic that matters: per tick, the cross-tile reads
                // by a ternary node whose byte differs from that read's byte
                // on the previous tick (a ghost left stale would show here).
                let ternaryCrossings = crossings.filter { lanes.mode[$0.reader] != 0 }
                var lastRead: [UInt8] = []
                var changedCrossPerTick: [Int] = []
                for t in 1...last {
                    let before = refVector
                    switch mode {
                    case .rank:
                        untiled.engine.tick(tickNumber: UInt32(t))
                        refVector = ref.tickRank(refVector, ternary: lanes, coverage: cov)
                    case .sync:
                        untiled.engine.tickSync(tickNumber: UInt32(t))
                        refVector = ref.tickSync(refVector, ternary: lanes, coverage: cov)
                    }
                    let movedNow = (0..<before.count).filter { lanes.mode[$0] != 0 && before[$0] != refVector[$0] }.count
                    movedTernary += movedNow
                    changedPerTick.append(TiledReference.differing(before, refVector).count)
                    ternaryChangedPerTick.append(movedNow)
                    // What the reader read: sync — the previous vector; rank —
                    // the source's value after its own (higher) evaluation,
                    // or a register's pre-latch byte.
                    let readNow = ternaryCrossings.map { c -> UInt8 in
                        mode == .sync || ref.isRegister[c.source] ? before[c.source] : refVector[c.source]
                    }
                    if !lastRead.isEmpty {
                        changedCrossPerTick.append((0..<readNow.count).filter { readNow[$0] != lastRead[$0] }.count)
                    }
                    lastRead = readNow
                    let report = try await router.worldTick(mode: mode, count: 1)
                    XCTAssertEqual(report.epoch, UInt64(t), "\(cellTag) epoch after tick \(t)")
                    let want = untiled.engine.readTruthStates()
                    let got = try await router.truthArray()
                    let tag = "\(cellTag) N=\(t)"
                    XCTAssertEqual(refVector, want, "\(tag) reference vs untiled engine: \(TiledReference.differing(refVector, want).count) bytes")
                    XCTAssertEqual(got, want, "\(tag) tiled vs untiled: \(TiledReference.differing(got, want).count) bytes")
                    tickCompares += 1
                    if Self.ns.contains(t) {
                        wantAt[t] = want
                        cells += 1
                    }
                }

                // Router B: the WIP's segments, worldTick(count: n − prev) per
                // call, over its own copy of the tiles.
                var prevN = 0
                for targetN in Self.ns {
                    let report = try await routerMulti.worldTick(mode: mode, count: targetN - prevN)
                    XCTAssertEqual(report.epoch, UInt64(targetN), "\(cellTag) multi-round epoch")
                    let got = try await routerMulti.truthArray()
                    let want = wantAt[targetN] ?? []
                    XCTAssertEqual(got, want, "\(cellTag) N=\(targetN) multi-round tiled vs untiled: \(TiledReference.differing(got, want).count) bytes")
                    multiRoundCompares += 1
                    prevN = targetN
                }

                // The object can fail the gate: ternary nodes move, and some
                // read across a tile boundary.
                XCTAssertGreaterThan(movedTernary, 0, "\(cellTag): ternary nodes never moved")
                // Staticity (the standing check of the tiled-tick tests): the
                // world moves on every tick, and so do its ternary nodes.
                if cov != nil {
                    print("R6 moved side=\(side) tiles=\(tiles) mode=\(mode) changed_per_tick=\(changedPerTick) ternary_changed_per_tick=\(ternaryChangedPerTick) cross_ternary_reads_changed_ticks2to\(last)=\(changedCrossPerTick)")
                }
                XCTAssertFalse(changedPerTick.contains(0), "\(cellTag): a tick changed nothing \(changedPerTick)")
                XCTAssertFalse(ternaryChangedPerTick.contains(0), "\(cellTag): a tick moved no ternary node \(ternaryChangedPerTick)")
                XCTAssertEqual(changedCrossPerTick.count, last - 1)
                XCTAssertGreaterThan(changedCrossPerTick.reduce(0, +), 0, "\(cellTag): no ternary reader ever saw a ghost change")
                if cov != nil { crossChangedByTiling[tiles] = changedCrossPerTick }
                XCTAssertGreaterThan(ternaryReaders, 0, "side=\(side) tiles=\(tiles): no ternary node reads across a tile")

                // Tile engines carry the lanes and the library — after 12
                // flushes, in both directories.
                try assertTileBodiesCarryLanes(dir: dir, lanes: lanes, nodeCount: untiled.nodeCount,
                                               tag: "\(cellTag) after \(last) world ticks")
                try assertTileBodiesCarryLanes(dir: dirMulti, lanes: lanes, nodeCount: untiled.nodeCount,
                                               tag: "\(cellTag) after \(last) world ticks, multi-round")
                laneChecks += 2
                if let cov { tilingCoverage = cov }
            }

            // Per tiling: a ghost carries a trit — ternary readers take −1, +1
            // AND UNDEFINED across the boundary, from ternary sources.
            if let c = tilingCoverage {
                print("R6 coverage side=\(side) tiles=\(tiles) mode=\(mode) \(c.line)")
                let tag = "side=\(side) tiles=\(tiles) mode=\(mode)"
                XCTAssertGreaterThan(c.crossIntoTernaryByByte[0], 0, "\(tag): no ternary reader read −1 across a tile")
                XCTAssertGreaterThan(c.crossIntoTernaryByByte[1], 0, "\(tag): no ternary reader read +1 across a tile")
                XCTAssertGreaterThan(c.crossIntoTernaryByByte[2], 0, "\(tag): no ternary reader read UNDEFINED across a tile")
                XCTAssertGreaterThan(c.crossTernarySourceIntoTernary, 0, "\(tag): no ternary source read across a tile by a ternary node")
                if let s = sideCoverage { s.add(c) } else { sideCoverage = c }
            }
        }
        // On every tick 2…12 some tiling's ghosts carry a CHANGED byte into a
        // ternary reader (side 16's 2-tiling in rank mode does not after
        // tick 4: its only oscillator and every path it drives sit above the
        // boundary — printed above, a property of the object).
        for i in 0..<(last - 1) {
            XCTAssertTrue(Self.tilings.contains { (crossChangedByTiling[$0]?[i] ?? 0) > 0 },
                          "side=\(side) mode=\(mode) tick \(i + 2): no tiling's ghosts carried a changed byte to a ternary reader")
        }
        print("R6 side=\(side) mode=\(mode) cells=\(cells) tick_compares=\(tickCompares) multi_round_compares=\(multiRoundCompares) lane_checks=\(laneChecks) cross_tile_edges_into_ternary_readers=\(crossTernaryReaders)")
        XCTAssertEqual(cells, Self.tilings.count * Self.ks.count * Self.ns.count)
        XCTAssertEqual(tickCompares, Self.tilings.count * Self.ks.count * last)
        XCTAssertEqual(multiRoundCompares, Self.tilings.count * Self.ks.count * Self.ns.count)
        XCTAssertEqual(laneChecks, Self.tilings.count * Self.ks.count * 3)

        // Per side and mode, over the three tilings: every mechanism of the
        // rules was exercised by the object.
        guard let c = sideCoverage else { XCTFail("no coverage"); return }
        print("R6 coverage side=\(side) mode=\(mode) all-tilings \(c.line)")
        let tag = "side=\(side) mode=\(mode)"
        for kind in 0..<3 { XCTAssertGreaterThan(c.evals[kind], 0, "\(tag): kind \(kind) never evaluated") }
        for trit in 0..<3 { XCTAssertGreaterThan(c.outTrits[trit], 0, "\(tag): output trit \(trit - 1) never produced") }
        XCTAssertGreaterThan(c.noskipFired, 0, "\(tag): NOSKIP never fired")
        XCTAssertGreaterThan(c.threshOnBound, 0, "\(tag): no TTHRESH sum landed on a threshold")
        XCTAssertGreaterThan(c.absentIntoTernary, 0, "\(tag): no ternary node had an absent slot")
        XCTAssertGreaterThan(c.crossLoom, 0, "\(tag): no Loom byte read across a tile")
        XCTAssertGreaterThan(c.crossRegister, 0, "\(tag): no register read across a tile")
    }

    func testR6Rank_Side16() async throws { try await run(side: 16, mode: .rank) }
    func testR6Rank_Side44() async throws { try await run(side: 44, mode: .rank) }
    func testR6Rank_Side128() async throws { try await run(side: 128, mode: .rank) }
    func testR6Sync_Side16() async throws { try await run(side: 16, mode: .sync) }
    func testR6Sync_Side44() async throws { try await run(side: 44, mode: .sync) }
    func testR6Sync_Side128() async throws { try await run(side: 128, mode: .sync) }

    /// The tile writer carries the four lanes and the weights node for node
    /// (tile-local numbering mapped back through `engineIndexOf`).
    func testTileBodiesCarryEveryTernaryLane() throws {
        let o = try Self.mixedObject(side: 44)
        let dir = scratch("lanes")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = try TiledGraphFiles.write(object: o, dataRoot: dir, name: "g",
                                      boundaries: TiledFixture.boundaries(side: 44, tiles: 4))
        let manifest = try TiledGraphFiles.readManifest(dataRoot: dir, name: "g")
        let e = o.engine
        let w = e.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: e.nodeCount * 6)
        var nodes = 0
        for entry in manifest.tiles {
            let t = try TiledGraphFiles.loadTile(dataRoot: dir, name: "g", manifest: manifest, tileId: entry.id).engine
            let tw = t.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: t.nodeCount * 6)
            for (local, global) in entry.engineIndexOf.enumerated() {
                let g = Int(global)
                XCTAssertEqual(t.modePtr[local], e.modePtr[g])
                XCTAssertEqual(t.ttableIdPtr[local], e.ttableIdPtr[g])
                XCTAssertEqual(t.thrLoPtr[local].bitPattern, e.thrLoPtr[g].bitPattern)
                XCTAssertEqual(t.thrHiPtr[local].bitPattern, e.thrHiPtr[g].bitPattern)
                for d in 0..<6 { XCTAssertEqual(tw[local * 6 + d].bitPattern, w[g * 6 + d].bitPattern) }
                nodes += 1
            }
        }
        XCTAssertEqual(nodes, e.nodeCount)
    }
}
