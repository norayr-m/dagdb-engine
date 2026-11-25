import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// `TILED TICK` reads each tile engine's command-buffer status after the
/// tile's tick, as every other tick path does.
///
/// In-process. One handler holds the side-44 tiling fixture
/// (`TiledFixture.populate`: parity LUTs and period-2 registers, so a tick
/// whose latch is skipped differs from one that ran) and `SAVE TILED`s it
/// twice, to world A and to its twin B (the same graph name under two roots,
/// so every file can be compared byte for byte). A tile engine of A gets the
/// fault seam (`commandBufferStatusFailsAfterForTesting`: the (k + 1)-th
/// checked command buffer reads `.error`, once); `TILED TICK` on A must then
/// reply `ERROR gpu:` by name, naming the tile and the world tick, and claim
/// nothing: that tile is not flushed, so its files are byte-identical to
/// before the call (when it is the round's first tile, the whole world is).
/// A later `TILED TICK`, seam spent, succeeds, and A then equals B, a twin
/// that never failed: the router's truth and every file of the world, byte
/// for byte, at every later epoch checked.
///
/// Cases: rank and sync mode with the round's first tile failing at the
/// call's first tick; a `TILED TICK 3` whose second world tick fails (the
/// reply names tick 2 of 3, the total counts the one completed); and rank
/// mode with a tile in the middle of the round failing, where the tiles
/// before it are already flushed, so the world is torn: the reply says so,
/// the failed tile's files are byte-identical, the next `TILED TICK` refuses
/// the torn world by name (as it already did), and a writer `TILED OPEN`
/// completes the round, after which the world equals the twin.
///
/// Red on the older code (the test compiles there): the seam case replies OK and
/// the tile is flushed. Control that must fail: the check removed (one line),
/// the same.
///
/// Synchronous on purpose: the router's actor is reached through the
/// handler's own bridge (`runTiledSync`, the path the daemon takes), so every
/// assertion records on the test's own thread. The first form of this file
/// was `async`; in one of ten runs on the older code, XCTest counted 40 failures
/// where every other run counted 43: the three assertions of one helper call
/// went unrecorded while the calls around it recorded theirs.
final class EngineF3F2DaemonTests: XCTestCase {

    private var roots: [String] = []

    override func tearDown() {
        for r in roots { try? FileManager.default.removeItem(atPath: r) }
        roots = []
        super.tearDown()
    }

    // MARK: - Two worlds from one fixture

    private struct Worlds {
        let fixture: HandlerFixture
        let rootA: String, rootB: String
        let dirA: String, dirB: String
        let tileIds: [UInt32]
        var h: DagDBCommandHandler { fixture.handler }
    }

    private static let graphName = "g44"

    /// Side 44 split at ranks 5, 11, 17 (4 tiles, as `TiledCommandTests`),
    /// saved at tick 0 to A and B; A opened as `x00000001`, B as `x00000002`,
    /// both with every tile allowed resident (K = 4), so the seamed engine
    /// stays the one the round ticks.
    private func makeWorlds() throws -> Worlds {
        let root = NSTemporaryDirectory() + "f3f2_\(UUID().uuidString)"
        roots.append(root)
        let rootA = "\(root)/a", rootB = "\(root)/b"
        for d in [rootA, rootB] {
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        let f = try HandlerFixture(side: 44, dataRoot: root, maxRank: 64)
        try TiledFixture.populate(engine: f.handler.engine, grid: f.grid, side: 44)
        let dirA = "\(rootA)/\(Self.graphName)", dirB = "\(rootB)/\(Self.graphName)"
        for d in [dirA, dirB] {
            let r = f.handler.handle("SAVE TILED \(d) 5,11,17")
            XCTAssertTrue(r.hasPrefix("OK SAVE TILED"), r)
        }
        let ra = f.handler.handle("TILED OPEN \(dirA) 4")
        XCTAssertTrue(ra.hasPrefix("OK TILED OPEN id=x00000001 "), ra)
        let rb = f.handler.handle("TILED OPEN \(dirB) 4")
        XCTAssertTrue(rb.hasPrefix("OK TILED OPEN id=x00000002 "), rb)
        let manifest = try TiledGraphFiles.readManifest(dataRoot: rootA, name: Self.graphName)
        let ids = manifest.tiles.map { $0.id }.sorted()
        XCTAssertEqual(ids.count, 4)
        return Worlds(fixture: f, rootA: rootA, rootB: rootB, dirA: dirA, dirB: dirB, tileIds: ids)
    }

    /// Every file under `dir`, by path relative to it.
    private func snapshot(_ dir: String) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: dir) else { return out }
        for case let rel as String in e {
            var isDir: ObjCBool = false
            let path = "\(dir)/\(rel)"
            if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                out[rel] = try Data(contentsOf: URL(fileURLWithPath: path))
            }
        }
        return out
    }

    private func tileDir(_ root: String, _ tileId: UInt32) throws -> String {
        let m = try TiledGraphFiles.readManifest(dataRoot: root, name: Self.graphName)
        let entry = try XCTUnwrap(m.tiles.first { $0.id == tileId })
        return TiledGraphFiles.tileDirectory(dataRoot: root, name: Self.graphName, entry: entry)
    }

    private func field(_ line: String, _ key: String) -> Int? {
        for token in line.split(separator: " ") where token.hasPrefix("\(key)=") {
            return Int(token.dropFirst(key.count + 1))
        }
        return nil
    }

    /// A (router `idA`) equals B (`x00000002`): the routers' truth over every
    /// node, and every file of the two worlds byte for byte.
    private func assertWorldsEqual(_ w: Worlds, idA: String, _ label: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let ra = try XCTUnwrap(w.h.tiledRouters[idA]).router
        let rb = try XCTUnwrap(w.h.tiledRouters["x00000002"]).router
        let ta = try w.h.runTiledSync { try await ra.truthArray() }
        let tb = try w.h.runTiledSync { try await rb.truthArray() }
        XCTAssertEqual(ta, tb, "\(label): truth equals the twin's", file: file, line: line)
        let fa = try snapshot(w.dirA), fb = try snapshot(w.dirB)
        XCTAssertEqual(fa.keys.sorted(), fb.keys.sorted(), "\(label): the same files", file: file, line: line)
        let differing = fa.keys.sorted().filter { fa[$0] != fb[$0] }
        XCTAssertEqual(differing, [], "\(label): every file byte-identical to the twin's", file: file, line: line)
    }

    /// Ticks A and B `n` world ticks each (both must reply OK, the same epoch)
    /// and checks them equal.
    private func tickBothAndCompare(_ w: Worlds, idA: String, n: Int, sync: Bool, _ label: String,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let s = sync ? " SYNC" : ""
        let ra = w.h.handle("TILED TICK \(idA) \(n)\(s)")
        let rb = w.h.handle("TILED TICK x00000002 \(n)\(s)")
        XCTAssertTrue(ra.hasPrefix("OK TILED TICK id=\(idA) "), "\(label): \(ra)", file: file, line: line)
        XCTAssertTrue(rb.hasPrefix("OK TILED TICK id=x00000002 "), "\(label): \(rb)", file: file, line: line)
        XCTAssertEqual(field(ra, "ticks"), field(rb, "ticks"), "\(label): the same epoch", file: file, line: line)
        try assertWorldsEqual(w, idA: idA, label, file: file, line: line)
    }

    // MARK: - F3F2.1 · the round's first tile fails at the call's first tick

    func testF3F2_1RankFirstTileFailsNothingFlushedThenEqualsTwin() throws {
        try firstTileCase(sync: false)
    }

    func testF3F2_1SyncFirstTileFailsNothingFlushedThenEqualsTwin() throws {
        try firstTileCase(sync: true)
    }

    private func firstTileCase(sync: Bool) throws {
        let w = try makeWorlds()
        let h = w.h
        let mode = sync ? "sync" : "rank"
        let s = sync ? " SYNC" : ""
        // One good world tick on both first, so the failure starts from a
        // non-zero epoch with a flush history behind it.
        try tickBothAndCompare(w, idA: "x00000001", n: 1, sync: sync, "\(mode): the first tick")

        // Rank mode ticks tiles in descending id order, sync ascending.
        let first = sync ? w.tileIds.first! : w.tileIds.last!
        let router = try XCTUnwrap(h.tiledRouters["x00000001"]).router
        let tile = try h.runTiledSync { try await router.tickLoad(tileId: first) }
        let before = try snapshot(w.dirA)
        XCTAssertFalse(before.isEmpty)
        tile.engine.commandBufferStatusFailsAfterForTesting = 0

        let r = h.handle("TILED TICK x00000001 1\(s)")
        XCTAssertEqual(
            r,
            "ERROR gpu: TILED TICK: command buffer status error (no error object) at tick 1 of 1, "
                + "tile \(first) epoch 2; nothing claimed: tile \(first) not flushed (its files unchanged), "
                + "its engine dropped; tiles at epoch 2: 0 of 4; epoch=1/1; total=1",
            "\(mode): ERROR gpu by name, the tile and the tick named, nothing claimed")
        XCTAssertNil(tile.engine.commandBufferStatusFailsAfterForTesting, "\(mode): the seam fires once")

        // Nothing flushed: the failed tile's files, and (it was the round's
        // first) every file of the world, byte-identical to before the call.
        let after = try snapshot(w.dirA)
        let firstDir = try tileDir(w.rootA, first)
        let tilePrefix = String(firstDir.dropFirst(w.dirA.count + 1)) + "/"
        let tileFiles = before.keys.filter { $0.hasPrefix(tilePrefix) }
        XCTAssertGreaterThanOrEqual(tileFiles.count, 5, "\(mode): body, meta, two strips, flush.wal")
        for k in tileFiles { XCTAssertEqual(after[k], before[k], "\(mode): tile \(first)'s \(k) unchanged") }
        XCTAssertEqual(after.keys.sorted(), before.keys.sorted(), "\(mode): no file added or removed")
        XCTAssertEqual(before.keys.sorted().filter { after[$0] != before[$0] }, [],
                       "\(mode): every file of the world byte-identical to before the call")
        XCTAssertTrue(h.handle("TILED STATUS x00000001").contains("epoch=1/1"), "\(mode): no epoch claimed")

        // Seam spent: the next TILED TICK succeeds and equals the twin.
        try tickBothAndCompare(w, idA: "x00000001", n: 1, sync: sync, "\(mode): the tick after the failure")
        try tickBothAndCompare(w, idA: "x00000001", n: 3, sync: sync, "\(mode): three more")
    }

    // MARK: - F3F2.1 · the reply names the world tick of n

    func testF3F2_1TheSecondOfThreeWorldTicksFails() throws {
        let w = try makeWorlds()
        let h = w.h
        let first = w.tileIds.last!                     // rank mode's first tile
        let router = try XCTUnwrap(h.tiledRouters["x00000001"]).router
        let tile = try h.runTiledSync { try await router.tickLoad(tileId: first) }
        // The first checked buffer (world tick 1) completes; the second fails.
        tile.engine.commandBufferStatusFailsAfterForTesting = 1
        let r = h.handle("TILED TICK x00000001 3")
        XCTAssertEqual(
            r,
            "ERROR gpu: TILED TICK: command buffer status error (no error object) at tick 2 of 3, "
                + "tile \(first) epoch 2; nothing claimed: tile \(first) not flushed (its files unchanged), "
                + "its engine dropped; tiles at epoch 2: 0 of 4; epoch=1/1; total=1",
            "tick 2 of 3 named; the total counts the one world tick that completed")
        XCTAssertNil(tile.engine.commandBufferStatusFailsAfterForTesting, "the seam fires once")
        // The world holds exactly the one completed tick: equal to the twin after 1.
        let rb = h.handle("TILED TICK x00000002 1")
        XCTAssertTrue(rb.hasPrefix("OK TILED TICK id=x00000002 ticks=1 "), rb)
        try assertWorldsEqual(w, idA: "x00000001", "after the failed call")
        try tickBothAndCompare(w, idA: "x00000001", n: 2, sync: false, "the next call")
    }

    // MARK: - F3F2.1 · a tile in the middle of the round fails: torn, then completed

    func testF3F2_1RankMiddleTileFailsTornThenOpenCompletesTheRound() throws {
        let w = try makeWorlds()
        let h = w.h
        try tickBothAndCompare(w, idA: "x00000001", n: 1, sync: false, "the first tick")

        // Rank order: 3, 2, 1, 0. Tile 1 fails after 3 and 2 have flushed at epoch 2.
        let order = w.tileIds.sorted(by: >)
        let failing = order[2]
        let router = try XCTUnwrap(h.tiledRouters["x00000001"]).router
        let tile = try h.runTiledSync { try await router.tickLoad(tileId: failing) }
        let failingDir = try tileDir(w.rootA, failing)
        let tilePrefix = String(failingDir.dropFirst(w.dirA.count + 1)) + "/"
        let before = try snapshot(w.dirA)
        tile.engine.commandBufferStatusFailsAfterForTesting = 0

        let r = h.handle("TILED TICK x00000001 1")
        XCTAssertEqual(
            r,
            "ERROR gpu: TILED TICK: command buffer status error (no error object) at tick 1 of 1, "
                + "tile \(failing) epoch 2; nothing claimed: tile \(failing) not flushed (its files unchanged), "
                + "its engine dropped; tiles at epoch 2: 2 of 4; "
                + "epoch=1/2 (torn: a writer TILED OPEN completes the round); total=1",
            "the failing tile named, the tear stated")
        let after = try snapshot(w.dirA)
        let tileFiles = before.keys.filter { $0.hasPrefix(tilePrefix) }
        XCTAssertGreaterThanOrEqual(tileFiles.count, 5)
        XCTAssertEqual(tileFiles.sorted().filter { after[$0] != before[$0] }, [],
                       "tile \(failing)'s files byte-identical to before the call")
        // The two tiles before it did flush (a partial round, as a crash between tiles leaves).
        for t in order.prefix(2) {
            let p = String(try tileDir(w.rootA, t).dropFirst(w.dirA.count + 1)) + "/body.dags"
            XCTAssertNotEqual(after[p], before[p], "tile \(t) flushed before the failure")
        }

        // The torn world is refused by name, as before F3F2.
        let refused = h.handle("TILED TICK x00000001 1")
        XCTAssertTrue(refused.hasPrefix("ERROR io: ") && refused.contains("world torn"), refused)

        // A writer TILED OPEN completes the round (tiles 1 and 0 at epoch 2).
        XCTAssertTrue(h.handle("TILED CLOSE x00000001").hasPrefix("OK TILED CLOSE"))
        let reopen = h.handle("TILED OPEN \(w.dirA) 4")
        XCTAssertTrue(reopen.hasPrefix("OK TILED OPEN id=x00000003 ") && reopen.hasSuffix("recovered=0 completed=2"),
                      reopen)
        let rb = h.handle("TILED TICK x00000002 1")
        XCTAssertTrue(rb.hasPrefix("OK TILED TICK id=x00000002 ticks=2 "), rb)
        try assertWorldsEqual(w, idA: "x00000003", "after the round's completion")
        try tickBothAndCompare(w, idA: "x00000003", n: 3, sync: false, "three more")
    }
}
