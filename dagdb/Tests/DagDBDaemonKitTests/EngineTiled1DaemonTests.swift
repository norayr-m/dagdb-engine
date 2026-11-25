import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// A tiled tick never tears a tile directory over a tile the load refuses.
///
/// The object: tiles an older build wrote holding S2 (a slot self-loop) or S3
/// (a rank inversion). `SAVE TILED` now refuses both, so the tiles are
/// written here by the library writer (`TiledGraphFiles.write`), which stays
/// permissive and writes what the older `SAVE TILED` wrote. Tiles open
/// lazily; every tile body is loaded under the rank-mode rule
/// (`SlotRule.rankModeDAG`) in either tick mode, so a round reaching the bad
/// tile is refused by name. Before this fix that refusal came at the bad
/// tile's own turn: the tiles before it in the round had already flushed (a
/// torn directory, which the next writer `TILED OPEN` then failed to complete),
/// and `TILED STATUS` still said `refused=0 last=none`.
///
/// The check, in-process, on the side-44 tiling fixture split at ranks 5, 11
/// and 17 (4 tiles): S2 and S3, in the top tile (rank mode's first, sync's
/// last) and in the bottom tile (sync's first, rank's last), `TILED TICK 1` and
/// `TILED TICK 1 SYNC`, K = 1 and K = 4. Every cell: the reply names the rule;
/// every file of the directory is byte-identical to before the call; `TILED
/// STATUS` reads `refused=1`, names the tile and the rule, and keeps
/// `epoch=0/0`; a later `TILED OPEN` of the same directory opens it as before
/// (`recovered=0 completed=0`) and its tick is refused again, whole. Then a
/// writer `TILED OPEN` whose round completion would reach the bad tile second
/// (a world torn by a GPU failure) is refused by name with the directory
/// byte-identical. The query paths' refusals are counted too; S1 tiles tick in
/// both modes.
///
/// Red on the older code: `refused=0` in every cell, the torn cells' directories
/// changed, the open's completion advancing a tile. Control that must fail:
/// the validation moved back after the advance (the pre-flight removed).
final class EngineTiled1DaemonTests: XCTestCase {

    private var roots: [String] = []

    override func tearDown() {
        for r in roots { try? FileManager.default.removeItem(atPath: r) }
        roots = []
        super.tearDown()
    }

    private static let graphName = "g44"
    private static let boundaries = "5,11,17"

    private enum Shape: String { case s1 = "S1", s2 = "S2", s3 = "S3" }

    private struct World {
        let fixture: HandlerFixture
        let root: String
        let dir: String
        let badTile: UInt32
        let badGlobal: UInt64
        var h: DagDBCommandHandler { fixture.handler }
    }

    /// The rule's words in the tile load's refusal (`dagEdgeViolation`).
    private func words(_ shape: Shape) -> String {
        shape == .s2 ? "self-loop" : "must be > dst rank"
    }

    /// The side-44 fixture with one bad slot planted in the top tile (ranks
    /// >= 17) or the bottom tile (ranks < 5), written by the library writer
    /// to `<root>/g44`. `legalFirst`: also write the same graph WITHOUT the
    /// bad slot to `<root>/legal/g44` first (the completion case's twin).
    private func makeWorld(_ shape: Shape, top: Bool, legalFirst: Bool = false) throws -> World {
        let root = NSTemporaryDirectory() + "tiled1_\(UUID().uuidString)"
        roots.append(root)
        try FileManager.default.createDirectory(atPath: "\(root)/legal", withIntermediateDirectories: true)
        let f = try HandlerFixture(side: 44, dataRoot: root, maxRank: 64)
        let e = f.handler.engine
        try TiledFixture.populate(engine: e, grid: f.grid, side: 44)
        let n = e.nodeCount
        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        let regs = Set(e.backEdgeDsts.map(Int.init))
        let inTile: (Int) -> Bool = { top ? rank[$0] >= 17 : rank[$0] < 5 }
        let cands = (0..<n).filter { !regs.contains($0) && inTile($0) }
        let free = cands.filter { v in (0..<6).contains { nb[v * 6 + $0] == -1 } }
        // S2/S3: the node of highest rank in the tile with a free slot (in the
        // top tile a leaf, every slot free). S1: the first node of the tile
        // with a source and a free slot.
        let i = shape == .s1
            ? try XCTUnwrap(free.first { v in (0..<6).contains { nb[v * 6 + $0] >= 0 } })
            : try XCTUnwrap(free.max { (rank[$0], -$0) < (rank[$1], -$1) })
        let slot = try XCTUnwrap((0..<6).first { nb[i * 6 + $0] == -1 })
        let src: Int32
        switch shape {
        case .s1: src = try XCTUnwrap((0..<6).map { nb[i * 6 + $0] }.first { $0 >= 0 })   // a duplicate source
        case .s2: src = Int32(i)
        case .s3: src = Int32(try XCTUnwrap(cands.first { $0 != i && rank[$0] <= rank[i] }))
        }
        if legalFirst {
            _ = try TiledGraphFiles.write(engine: e, grid: f.grid, dataRoot: "\(root)/legal",
                                          name: Self.graphName, boundaries: [5, 11, 17])
        }
        nb[i * 6 + slot] = src
        if shape == .s1 {
            XCTAssertNil(DagDBSnapshot.rankOrderViolation(engine: e, nodeCount: n), "S1: rank TICK runs it")
        } else {
            let why = try XCTUnwrap(DagDBSnapshot.rankOrderViolation(engine: e, nodeCount: n))
            XCTAssertTrue(why.contains(words(shape)), why)
            // SAVE TILED refuses it under the slot model; the library writer stands for the older build.
            let saved = f.handler.handle("SAVE TILED \(root)/refused 5,11,17")
            XCTAssertTrue(saved.hasPrefix("ERROR invalid_graph: SAVE TILED refused"), saved)
        }
        let report = try TiledGraphFiles.write(engine: e, grid: f.grid, dataRoot: root,
                                               name: Self.graphName, boundaries: [5, 11, 17])
        let g = GlobalNodeID(raw: report.globalOf[i])
        return World(fixture: f, root: root, dir: "\(root)/\(Self.graphName)",
                     badTile: g.tileId, badGlobal: g.raw)
    }

    /// Every file under `dir`, by path relative to it.
    private func snapshot(_ dir: String) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return out }
        for case let rel as String in en {
            var isDir: ObjCBool = false
            let path = "\(dir)/\(rel)"
            if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                out[rel] = try Data(contentsOf: URL(fileURLWithPath: path))
            }
        }
        return out
    }

    private func assertUnchanged(_ before: [String: Data], _ dir: String, _ label: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let after = try snapshot(dir)
        XCTAssertEqual(after.keys.sorted(), before.keys.sorted(), "\(label): no file added or removed",
                       file: file, line: line)
        XCTAssertEqual(before.keys.sorted().filter { after[$0] != before[$0] }, [],
                       "\(label): every file of the directory byte-identical", file: file, line: line)
    }

    // MARK: - TILED TICK and TILED TICK SYNC over a bad tile

    func testTILED1_1S2TopTile() throws { try tickCells(.s2, top: true) }
    func testTILED1_1S3TopTile() throws { try tickCells(.s3, top: true) }
    func testTILED1_1S2BottomTile() throws { try tickCells(.s2, top: false) }
    func testTILED1_1S3BottomTile() throws { try tickCells(.s3, top: false) }

    private func tickCells(_ shape: Shape, top: Bool) throws {
        for sync in [false, true] {
            for k in [1, 4] {
                try tickCell(shape, top: top, sync: sync, k: k)
            }
        }
    }

    private func tickCell(_ shape: Shape, top: Bool, sync: Bool, k: Int) throws {
        let w = try makeWorld(shape, top: top)
        let h = w.h
        let label = "\(shape.rawValue) \(top ? "top" : "bottom") tile \(w.badTile), \(sync ? "SYNC" : "rank"), K=\(k)"
        XCTAssertEqual(w.badTile, top ? 3 : 0, label)
        let s = sync ? " SYNC" : ""
        let open = h.handle("TILED OPEN \(w.dir) \(k)")
        XCTAssertEqual(open, "OK TILED OPEN id=x00000001 tiles=4 nodes=1936 resident_max=\(k) recovered=0 completed=0",
                       label)
        XCTAssertTrue(h.handle("TILED STATUS x00000001").hasSuffix("refused=0 last=none epoch=0/0"), label)
        let before = try snapshot(w.dir)
        XCTAssertGreaterThanOrEqual(before.count, 9, "\(label): the manifest and every tile's files")

        let r = h.handle("TILED TICK x00000001 1\(s)")
        XCTAssertTrue(r.hasPrefix("ERROR io: validation: node ") && r.contains(words(shape)),
                      "\(label): refused by name: \(r)")
        try assertUnchanged(before, w.dir, "\(label): the refused tick")
        let st = h.handle("TILED STATUS x00000001")
        XCTAssertTrue(st.contains(" refused=1 last=\"tile \(w.badTile): validation: node "), "\(label): \(st)")
        XCTAssertTrue(st.contains(words(shape)) && st.hasSuffix(" epoch=0/0"), "\(label): \(st)")

        // A later writer TILED OPEN behaves as before the tick; its tick is refused again, whole.
        XCTAssertTrue(h.handle("TILED CLOSE x00000001").hasPrefix("OK TILED CLOSE"), label)
        let reopen = h.handle("TILED OPEN \(w.dir) \(k)")
        XCTAssertEqual(reopen,
                       "OK TILED OPEN id=x00000002 tiles=4 nodes=1936 resident_max=\(k) recovered=0 completed=0",
                       "\(label): the reopen")
        let r2 = h.handle("TILED TICK x00000002 1\(s)")
        XCTAssertEqual(r2, r, "\(label): the same refusal after the reopen")
        try assertUnchanged(before, w.dir, "\(label): the second refused tick")
        let st2 = h.handle("TILED STATUS x00000002")
        XCTAssertTrue(st2.contains(" refused=1 ") && st2.hasSuffix(" epoch=0/0"), "\(label): \(st2)")
    }

    // MARK: - A writer TILED OPEN whose round completion reaches the bad tile second

    /// The world: the legal twin ticked once in SYNC mode with tile 2's
    /// command buffer failing (F3F2's seam), so tiles 0 and 1 stand at epoch
    /// 1 and tiles 2 and 3 at 0 (torn); then tile 3 replaced by the same tile
    /// of the S2 world (the same epoch, meta, strips and wal; only the body,
    /// its sidecar and its manifest hash differ). The writer open's completion
    /// ticks tile 2, then tile 3, in sync order. It must refuse by name before
    /// tile 2 advances.
    func testTILED1_1OpenCompletionRefusedWhole() throws {
        let w = try makeWorld(.s2, top: true, legalFirst: true)
        let h = w.h
        let legalRoot = "\(w.root)/legal", legalDir = "\(legalRoot)/\(Self.graphName)"
        XCTAssertTrue(h.handle("TILED OPEN \(legalDir) 4").hasPrefix("OK TILED OPEN id=x00000001 "))
        let router = try XCTUnwrap(h.tiledRouters["x00000001"]).router
        let tile2 = try h.runTiledSync { try await router.tickLoad(tileId: 2) }
        tile2.engine.commandBufferStatusFailsAfterForTesting = 0
        let torn = h.handle("TILED TICK x00000001 1 SYNC")
        XCTAssertTrue(torn.hasPrefix("ERROR gpu: TILED TICK: ") && torn.contains("tiles at epoch 1: 2 of 4; epoch=0/1"),
                      torn)
        XCTAssertTrue(h.handle("TILED CLOSE x00000001").hasPrefix("OK TILED CLOSE"))

        // Tile 3 of the S2 world into the torn legal world.
        let fm = FileManager.default
        let mBad = try TiledGraphFiles.readManifest(dataRoot: w.root, name: Self.graphName)
        let mLegal = try TiledGraphFiles.readManifest(dataRoot: legalRoot, name: Self.graphName)
        let e3Bad = try XCTUnwrap(mBad.tiles.first { $0.id == 3 })
        let e3Legal = try XCTUnwrap(mLegal.tiles.first { $0.id == 3 })
        let d3Bad = TiledGraphFiles.tileDirectory(dataRoot: w.root, name: Self.graphName, entry: e3Bad)
        let d3Legal = TiledGraphFiles.tileDirectory(dataRoot: legalRoot, name: Self.graphName, entry: e3Legal)
        XCTAssertEqual(try snapshot(d3Bad).keys.sorted(), try snapshot(d3Legal).keys.sorted())
        let differing = try { () throws -> [String] in
            let a = try snapshot(d3Bad), b = try snapshot(d3Legal)
            return a.keys.sorted().filter { a[$0] != b[$0] }
        }()
        XCTAssertEqual(differing, ["body.dags", "body.dags.sha256"], "only the body differs")
        for name in ["body.dags", "body.dags.sha256"] {
            try fm.removeItem(atPath: "\(d3Legal)/\(name)")
            try fm.copyItem(atPath: "\(d3Bad)/\(name)", toPath: "\(d3Legal)/\(name)")
        }
        let patched = TiledGraphFiles.Manifest(
            format: mLegal.format, version: mLegal.version, name: mLegal.name, boundaries: mLegal.boundaries,
            globalNodeCount: mLegal.globalNodeCount,
            tiles: mLegal.tiles.map { $0.id == 3 ? e3Bad : $0 })
        XCTAssertEqual(e3Bad.tickEpoch, e3Legal.tickEpoch)
        try TiledGraphFiles.writeManifest(dataRoot: legalRoot, name: Self.graphName, manifest: patched)

        let before = try snapshot(legalDir)
        let open = h.handle("TILED OPEN \(legalDir) 4")
        XCTAssertTrue(open.hasPrefix("ERROR io: validation: node ") && open.contains("self-loop"),
                      "the open refused by name: \(open)")
        try assertUnchanged(before, legalDir, "the refused open (tile 2 not advanced)")
        XCTAssertEqual(h.handle("TILED OPEN \(legalDir) 4"), open, "the same refusal again")
        try assertUnchanged(before, legalDir, "the second refused open")
    }

    // MARK: - The query paths count their refusals; S1 tiles tick

    func testTILED1_1QueryPathsCountTheirRefusals() throws {
        let w = try makeWorld(.s2, top: true)
        let h = w.h
        XCTAssertTrue(h.handle("TILED OPEN \(w.dir) 1").hasPrefix("OK TILED OPEN id=x00000001 "))
        let before = try snapshot(w.dir)
        let get = h.handle("TILED GET x00000001 \(w.badGlobal) TRUTH")
        XCTAssertTrue(get.hasPrefix("ERROR io: validation: node ") && get.contains("self-loop"), get)
        XCTAssertTrue(h.handle("TILED STATUS x00000001").contains(" refused=1 last=\"tile 3: validation: "))
        let sel = h.handle("TILED SELECT x00000001 1 0 22")
        XCTAssertTrue(sel.hasPrefix("ERROR io: validation: node ") && sel.contains("self-loop"), sel)
        XCTAssertTrue(h.handle("TILED STATUS x00000001").contains(" refused=2 last=\"tile 3: validation: "))
        let bfs = h.handle("TILED BFS x00000001 \(w.badGlobal) 1")
        XCTAssertTrue(bfs.hasPrefix("ERROR io: validation: node ") && bfs.contains("self-loop"), bfs)
        let st = h.handle("TILED STATUS x00000001")
        XCTAssertTrue(st.contains(" refused=3 last=\"tile 3: validation: ") && st.hasSuffix(" epoch=0/0"), st)
        try assertUnchanged(before, w.dir, "the refused queries")
    }

    func testTILED1_2S1TilesTickInBothModes() throws {
        for top in [true, false] {
            let w = try makeWorld(.s1, top: top)
            let h = w.h
            XCTAssertTrue(h.handle("TILED OPEN \(w.dir) 2").hasPrefix("OK TILED OPEN id=x00000001 "))
            let before = try snapshot(w.dir)
            let r = h.handle("TILED TICK x00000001 1")
            XCTAssertTrue(r.hasPrefix("OK TILED TICK id=x00000001 ticks=1 tiles_ticked=4 "), r)
            let s = h.handle("TILED TICK x00000001 2 SYNC")
            XCTAssertTrue(s.hasPrefix("OK TILED TICK id=x00000001 ticks=3 tiles_ticked=8 "), s)
            XCTAssertNotEqual(try snapshot(w.dir), before, "the S1 world advanced")
            XCTAssertTrue(h.handle("TILED STATUS x00000001").hasSuffix("refused=0 last=none epoch=3/3"))
        }
    }
}
