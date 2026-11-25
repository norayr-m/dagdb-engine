import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// A tiled verb never leaves a torn world. This file uses only the API of the
/// code before the fix (it
/// compiles and runs there, for the red); the in-process write seam's
/// cells are in `EngineTiled2DaemonTests+Seams.swift`.
///
/// The object everywhere: the side-44 tiling fixture (`TiledFixture.populate`:
/// parity LUTs, period-2 registers), split at ranks 5, 11, 17 into 4 tiles,
/// 1,936 nodes. Its crossings run tile 0 → 1 → 2 → 3 only (each tile reads
/// the tile above it); tiles 1, 2 and 3 carry two registers each in their
/// strips. Rank mode ticks tiles 3, 2, 1, 0; sync mode 0, 1, 2, 3.
///
/// **Refusals before writes:**
/// one crafted world per refusal of the list, `TILED TICK` (T-a … T-f) and
/// `TILED OPEN` (O-a … O-g), each placed so that on the older code the refusal fires
/// after an earlier tile (or an earlier recovered tile) was written. Every
/// cell: the verb refused by name; every file of the tiled directory
/// byte-identical before and after (all bytes compared); the epochs unchanged;
/// the refusal counted (`TILED STATUS refused=1 last=tile <t>: …` for a tick;
/// for a refused open, which leaves no router, the daemon's `STATUS`
/// `tiled_refused=<n>`); a later `TILED OPEN` behaves as before the verb.
/// Control that must fail: the check moved back to its old place (a torn
/// directory).
///
/// **The recovery measures, on the older code's API**: the disk a kill leaves
/// after a tile's BEGIN (case (i)) and after its body's rename (case (ii)),
/// crafted from a never-failed twin's pre- and post-round files, for the
/// first, a middle and the last tile of a rank and a sync round at K = 1 and
/// K = 4. After a fresh `TILED OPEN` every tile's files must equal its
/// pre-round or its post-round reference, the epochs agree with the files,
/// and a following round equals the twin's.
final class EngineTiled2DaemonTests: XCTestCase {

    var roots: [String] = []

    override func tearDown() {
        for r in roots { try? FileManager.default.removeItem(atPath: r) }
        roots = []
        super.tearDown()
    }

    static let graphName = "g44"

    // MARK: - Worlds

    struct Worlds {
        let fixture: HandlerFixture
        let rootA: String, rootB: String
        var dirA: String { "\(rootA)/\(EngineTiled2DaemonTests.graphName)" }
        var dirB: String { "\(rootB)/\(EngineTiled2DaemonTests.graphName)" }
        var h: DagDBCommandHandler { fixture.handler }
    }

    /// The fixture `SAVE TILED` to world A (and its twin B, the same graph
    /// under another root, so every file can be compared byte for byte), at
    /// the handler's tick count `tickCount`.
    func makeWorlds(tickCount: UInt32 = 0, twin: Bool = true) throws -> Worlds {
        let root = NSTemporaryDirectory() + "tiled2_\(UUID().uuidString)"
        roots.append(root)
        let rootA = "\(root)/a", rootB = "\(root)/b"
        for d in [rootA, rootB] {
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        let f = try HandlerFixture(side: 44, dataRoot: root, maxRank: 64)
        try TiledFixture.populate(engine: f.handler.engine, grid: f.grid, side: 44)
        f.handler.tickCount = tickCount
        for r in twin ? [rootA, rootB] : [rootA] {
            let reply = f.handler.handle("SAVE TILED \(r)/\(Self.graphName) 5,11,17")
            XCTAssertTrue(reply.hasPrefix("OK SAVE TILED"), reply)
        }
        return Worlds(fixture: f, rootA: rootA, rootB: rootB)
    }

    static func order(sync: Bool) -> [UInt32] { sync ? [0, 1, 2, 3] : [3, 2, 1, 0] }

    // MARK: - Handler helpers

    func token(_ line: String, _ key: String) -> String? {
        for t in line.split(separator: " ") where t.hasPrefix("\(key)=") {
            return String(t.dropFirst(key.count + 1))
        }
        return nil
    }

    /// `TILED OPEN`, asserted OK; the router id.
    @discardableResult
    func open(_ h: DagDBCommandHandler, _ dir: String, _ k: Int, _ label: String,
              file: StaticString = #filePath, line: UInt = #line) -> String {
        let r = h.handle("TILED OPEN \(dir) \(k)")
        XCTAssertTrue(r.hasPrefix("OK TILED OPEN id="), "\(label): open: \(r)", file: file, line: line)
        return token(r, "id") ?? "none"
    }

    func close(_ h: DagDBCommandHandler, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let r = h.handle("TILED CLOSE \(id)")
        XCTAssertTrue(r.hasPrefix("OK TILED CLOSE"), r, file: file, line: line)
    }

    func tick(_ h: DagDBCommandHandler, _ id: String, _ n: Int, sync: Bool) -> String {
        h.handle("TILED TICK \(id) \(n)\(sync ? " SYNC" : "")")
    }

    func tickOK(_ h: DagDBCommandHandler, _ id: String, _ n: Int, sync: Bool, _ label: String,
                file: StaticString = #filePath, line: UInt = #line) {
        let r = tick(h, id, n, sync: sync)
        XCTAssertTrue(r.hasPrefix("OK TILED TICK id=\(id) "), "\(label): \(r)", file: file, line: line)
    }

    /// The daemon `STATUS` field `tiled_refused` (nil when absent).
    func tiledRefused(_ h: DagDBCommandHandler) -> Int? {
        token(h.handle("STATUS"), "tiled_refused").flatMap { Int($0) }
    }

    // MARK: - Files

    /// Every file under `dir`, by path relative to it.
    func snapshot(_ dir: String) throws -> [String: Data] {
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

    func assertUnchanged(_ before: [String: Data], _ dir: String, _ label: String,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let after = try snapshot(dir)
        XCTAssertEqual(after.keys.sorted(), before.keys.sorted(), "\(label): no file added or removed",
                       file: file, line: line)
        XCTAssertEqual(before.keys.sorted().filter { after[$0] != before[$0] }, [],
                       "\(label): every file of the directory byte-identical", file: file, line: line)
    }

    func manifest(_ root: String) throws -> TiledGraphFiles.Manifest {
        try TiledGraphFiles.readManifest(dataRoot: root, name: Self.graphName)
    }

    func tileDir(_ root: String, _ id: UInt32) throws -> String {
        let entry = try XCTUnwrap(try manifest(root).tiles.first { $0.id == id })
        return TiledGraphFiles.tileDirectory(dataRoot: root, name: Self.graphName, entry: entry)
    }

    /// `tile_<lo>_<hi>/` — a tile's files' prefix in a `snapshot`.
    func tilePrefix(_ root: String, _ id: UInt32) throws -> String {
        let d = try tileDir(root, id)
        return String(d.dropFirst("\(root)/\(Self.graphName)/".count)) + "/"
    }

    func readMeta(_ root: String, _ id: UInt32) throws -> TileMeta {
        try JSONDecoder().decode(TileMeta.self, from: Data(contentsOf: URL(fileURLWithPath: "\(try tileDir(root, id))/meta.json")))
    }

    func editMeta(_ root: String, _ id: UInt32, _ body: (inout TileMeta) throws -> Void) throws {
        var meta = try readMeta(root, id)
        try body(&meta)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(meta).write(to: URL(fileURLWithPath: "\(try tileDir(root, id))/meta.json"))
    }

    func editEntry(_ root: String, _ id: UInt32,
                   _ body: (TiledGraphFiles.TileEntry) throws -> TiledGraphFiles.TileEntry) throws {
        let m = try manifest(root)
        let tiles = try m.tiles.map { $0.id == id ? try body($0) : $0 }
        try TiledGraphFiles.writeManifest(dataRoot: root, name: Self.graphName, manifest: TiledGraphFiles.Manifest(
            format: m.format, version: m.version, name: m.name, boundaries: m.boundaries,
            globalNodeCount: m.globalNodeCount, tiles: tiles))
    }

    func entry(_ e: TiledGraphFiles.TileEntry, crossingsIn: [Crossing]) -> TiledGraphFiles.TileEntry {
        TiledGraphFiles.TileEntry(
            id: e.id, rankLo: e.rankLo, rankHi: e.rankHi, nodeCount: e.nodeCount, bodySHA256: e.bodySHA256,
            crossingsOut: e.crossingsOut, crossingsIn: crossingsIn, engineIndexOf: e.engineIndexOf,
            tickEpoch: e.tickEpoch)
    }

    /// Appends `line` + "\n" to tile `id`'s `flush.wal` (plain bytes, as a
    /// crafted directory would hold them).
    func appendWAL(_ root: String, _ id: UInt32, _ line: String) throws {
        let path = "\(try tileDir(root, id))/flush.wal"
        var data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        data.append(contentsOf: Array((line + "\n").utf8))
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Tile `id`'s `halo_lower.<parity>.bin` with its recorded epoch (the 8
    /// bytes at offset 32, DAHA v2) replaced.
    func setStripEpoch(_ root: String, _ id: UInt32, parity: Int, _ epoch: UInt64) throws {
        let path = "\(try tileDir(root, id))/halo_lower.\(parity).bin"
        var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertGreaterThanOrEqual(bytes.count, 40)
        var e = epoch
        withUnsafeBytes(of: &e) { raw in for i in 0..<8 { bytes[32 + i] = raw[i] } }
        try bytes.write(to: URL(fileURLWithPath: path))
    }

    /// Tile `reader`'s first crossing re-pointed at `(tile, local)`.
    func repoint(_ root: String, reader: UInt32, tile: UInt32, local: UInt64) throws {
        try editMeta(root, reader) { m in
            let c = m.crossingsOut[0]
            m.crossingsOut[0] = Crossing(localNode: c.localNode,
                                         remoteNode: try GlobalNodeID(tileId: tile, localNodeId: local),
                                         foreignRank: c.foreignRank)
        }
    }

    func stripLocals(_ root: String, _ id: UInt32) throws -> Set<UInt64> {
        Set(try XCTUnwrap(try manifest(root).tiles.first { $0.id == id }).crossingsIn.map { $0.localNode })
    }

    /// A rank round over `dir` (a writer router at K = 4, closed after) whose
    /// tile `fail`'s command buffer fails (F3F2's seam): the tiles before it
    /// in rank or sync order flushed, it and the rest did not (a partial
    /// round with clean wals).
    func tearByGPU(_ h: DagDBCommandHandler, _ dir: String, sync: Bool, fail: UInt32, _ label: String) throws {
        let id = open(h, dir, 4, label)
        let router = try XCTUnwrap(h.tiledRouters[id]).router
        let tile = try h.runTiledSync { try await router.tickLoad(tileId: fail) }
        tile.engine.commandBufferStatusFailsAfterForTesting = 0
        let r = tick(h, id, 1, sync: sync)
        XCTAssertTrue(r.hasPrefix("ERROR gpu: TILED TICK: ") && r.contains("(torn: "), "\(label): \(r)")
        close(h, id)
    }

    // MARK: - TILED TICK refusals (T-a … T-f)

    /// One `TILED TICK` refusal cell: world A (no twin) ticked once in rank
    /// mode to epoch 1 (or saved at `tickCount`, unticked), crafted, opened at
    /// K; the tick (`n` world ticks, `sync`) must be refused with every word
    /// of `words`, the directory byte-identical, `TILED STATUS` `refused=1
    /// last=tile <tile>: …` at the same epoch; then `TILED CLOSE` and a
    /// later `TILED OPEN` reply as before the tick, and its tick is refused
    /// again with the same reply.
    func tickRefusalCell(_ label: String, sync: Bool, k: Int, n: Int = 1, tickCount: UInt32 = 0,
                         preTick: Bool = true, tile: UInt32, words: [String],
                         craft: (String) throws -> Void,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let label = "\(label) (\(sync ? "SYNC" : "rank"), K=\(k))"
        let w = try makeWorlds(tickCount: tickCount, twin: false)
        let h = w.h
        var epoch = UInt64(tickCount)
        if preTick {
            let id0 = open(h, w.dirA, 4, label)
            tickOK(h, id0, 1, sync: false, "\(label): the pre-tick")
            close(h, id0)
            epoch += 1
        }
        try craft(w.rootA)

        let openReply = h.handle("TILED OPEN \(w.dirA) \(k)")
        XCTAssertTrue(openReply.hasPrefix("OK TILED OPEN id=") && openReply.hasSuffix(" recovered=0 completed=0"),
                      "\(label): \(openReply)", file: file, line: line)
        let id = token(openReply, "id") ?? "none"
        XCTAssertTrue(h.handle("TILED STATUS \(id)").hasSuffix("refused=0 last=none epoch=\(epoch)/\(epoch)"),
                      label, file: file, line: line)
        let before = try snapshot(w.dirA)

        let r = tick(h, id, n, sync: sync)
        XCTAssertTrue(r.hasPrefix("ERROR io: "), "\(label): refused: \(r)", file: file, line: line)
        for word in words {
            XCTAssertTrue(r.contains(word), "\(label): the refusal names '\(word)': \(r)", file: file, line: line)
        }
        try assertUnchanged(before, w.dirA, "\(label): the refused tick", file: file, line: line)
        let st = h.handle("TILED STATUS \(id)")
        XCTAssertTrue(st.contains(" refused=1 last=\"tile \(tile): "), "\(label): counted: \(st)", file: file, line: line)
        XCTAssertTrue(st.contains(words[0]), "\(label): STATUS names the refusal: \(st)", file: file, line: line)
        XCTAssertTrue(st.hasSuffix(" epoch=\(epoch)/\(epoch)"), "\(label): epochs unchanged: \(st)", file: file, line: line)

        close(h, id)
        let reopen = h.handle("TILED OPEN \(w.dirA) \(k)")
        let id2 = token(reopen, "id") ?? "none"
        XCTAssertEqual(reopen.replacingOccurrences(of: "id=\(id2)", with: "id=\(id)"), openReply,
                       "\(label): a later TILED OPEN replies as before the tick", file: file, line: line)
        let r2 = tick(h, id2, n, sync: sync)
        XCTAssertEqual(r2, r, "\(label): its tick refused again, the same reply", file: file, line: line)
        try assertUnchanged(before, w.dirA, "\(label): the second refused tick", file: file, line: line)
        XCTAssertTrue(h.handle("TILED STATUS \(id2)").contains(" refused=1 "), label, file: file, line: line)
    }

    /// T-a: tile 1's first crossing names tile 9, which the manifest does not
    /// hold. Tile 1 is the third tile of a rank round and the second of a
    /// sync round.
    func testT2_1a_GhostSourceTileAbsent() throws {
        for sync in [false, true] {
            for k in [1, 4] {
                try tickRefusalCell("T-a", sync: sync, k: k, tile: 1,
                                    words: ["tile 1 local ", "names tile 9 local 0", "the manifest holds no tile 9"]) {
                    try self.repoint($0, reader: 1, tile: 9, local: 0)
                }
            }
        }
    }

    /// T-b: tile 1's first crossing names a local of tile 2 that tile 2's
    /// strip does not carry — in range (the older code served it from the resident
    /// buffer in rank mode at K = 4 and refused it at K = 1) and past tile 2's
    /// node count (648): that one is refused by the router's own bounds error
    /// (`crossTileBoundsExceeded`, pinned by the committed
    /// `SubsystemsBoundsTiledTests.testF8ForeignLocalBeyondSourceTileRefused`),
    /// before any write.
    func testT2_1b_GhostLocalNotCarried() throws {
        for sync in [false, true] {
            for k in [1, 4] {
                try tickRefusalCell("T-b in range", sync: sync, k: k, tile: 1,
                                    words: ["names tile 2 local ", "tile 2's strip does not carry it"]) { root in
                    let carried = try self.stripLocals(root, 2)
                    let local = try XCTUnwrap((0..<648).map(UInt64.init).first { !carried.contains($0) })
                    try self.repoint(root, reader: 1, tile: 2, local: local)
                }
                try tickRefusalCell("T-b past the count", sync: sync, k: k, tile: 1,
                                    words: ["TiledGraphRouter: tile 2 outside tile-id space"]) {
                    try self.repoint($0, reader: 1, tile: 2, local: 700)
                }
            }
        }
    }

    /// T-c: rank mode, tile 2's first crossing names a local tile 1's strip
    /// carries — a source BELOW its reader, not yet ticked at tile 2's turn.
    /// Sync mode serves the same world (the source's previous strip), as before.
    func testT2_1c_RankGhostSourceBelowItsReader() throws {
        let craft: (String) throws -> Void = { root in
            let local = try XCTUnwrap(try self.stripLocals(root, 1).min())
            try self.repoint(root, reader: 2, tile: 1, local: local)
        }
        for k in [1, 4] {
            try tickRefusalCell("T-c", sync: false, k: k, tile: 2,
                                words: ["tile 1 lower strip stale — expected epoch 2, found 1"], craft: craft)
            // Sync serves it: the world ticks.
            let w = try makeWorlds(twin: false)
            let id0 = open(w.h, w.dirA, 4, "T-c sync")
            tickOK(w.h, id0, 1, sync: false, "T-c sync: the pre-tick")
            close(w.h, id0)
            try craft(w.rootA)
            let id = open(w.h, w.dirA, k, "T-c sync")
            tickOK(w.h, id, 1, sync: true, "T-c: sync serves a source below its reader (K=\(k))")
        }
    }

    /// T-d (sync, the call's first world tick): tile 2 reads tile 3's strip
    /// at parity 1 (epoch 1). (d1) the file is missing; (d3) it is stale and
    /// its regeneration refuses, the previous-parity strip (which a
    /// register's pre-latch byte comes from) stale too.
    func testT2_1d_SyncSourceStripUnreadableOrNotRegenerable() throws {
        for k in [1, 4] {
            try tickRefusalCell("T-d missing strip", sync: true, k: k, tile: 2, words: ["halo_lower.1.bin"]) { root in
                try FileManager.default.removeItem(atPath: "\(try self.tileDir(root, 3))/halo_lower.1.bin")
            }
            try tickRefusalCell("T-d not regenerable", sync: true, k: k, tile: 2,
                                words: ["tile 3 lower strip stale — expected epoch 0, found 7"]) { root in
                try self.setStripEpoch(root, 3, parity: 1, 5)
                try self.setStripEpoch(root, 3, parity: 0, 7)
            }
        }
    }

    /// T-e: tile 1's manifest `crossingsIn` gains a local past its node count
    /// (360): refused at tile 1's strip step on the older code, after tile 1's own
    /// BEGIN and body rename.
    func testT2_1e_CrossingsInPastTheNodeCount() throws {
        for sync in [false, true] {
            for k in [1, 4] {
                try tickRefusalCell("T-e", sync: sync, k: k, tile: 1,
                                    words: ["tile 1 lists a crossing at local id 9999, at or past its own node count 360"]) { root in
                    try self.editEntry(root, 1) { e in
                        self.entry(e, crossingsIn: e.crossingsIn + [
                            Crossing(localNode: 9999, remoteNode: try GlobalNodeID(tileId: 0, localNodeId: 0))])
                    }
                }
            }
        }
    }

    /// T-f: a world saved at epoch 2^32 − 2; `TILED TICK 2`: the second world
    /// tick's epoch does not fit `body.dags`'s 32-bit tick field.
    func testT2_1f_ALaterWorldTickPastTheEpochField() throws {
        for sync in [false, true] {
            for k in [1, 4] {
                try tickRefusalCell("T-f", sync: sync, k: k, n: 2, tickCount: UInt32.max - 1, preTick: false,
                                    tile: Self.order(sync: sync)[0],
                                    words: ["epoch 4294967296 does not fit body.dags's 32-bit tick field"]) { _ in }
            }
        }
    }

    // MARK: - TILED OPEN refusals (O-a … O-g)

    /// One `TILED OPEN` refusal cell: world A (no twin) ticked once in rank
    /// mode to epoch 1 (or saved at `tickCount`), `prepare`d; the open at K
    /// must be refused with every word of `words`, the directory
    /// byte-identical, the daemon's `STATUS` `tiled_refused` one higher; a
    /// later open replies the same, the directory still byte-identical.
    func openRefusalCell(_ label: String, k: Int, tickCount: UInt32 = 0, preTick: Bool = true, words: [String],
                         prepare: (DagDBCommandHandler, String) throws -> Void,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let label = "\(label) (K=\(k))"
        let w = try makeWorlds(tickCount: tickCount, twin: false)
        let h = w.h
        if preTick {
            let id0 = open(h, w.dirA, 4, label)
            tickOK(h, id0, 1, sync: false, "\(label): the pre-tick")
            close(h, id0)
        }
        try prepare(h, w.rootA)
        let refused0 = tiledRefused(h)
        XCTAssertEqual(refused0, 0, "\(label): STATUS carries tiled_refused=0 before", file: file, line: line)
        let before = try snapshot(w.dirA)

        let r = h.handle("TILED OPEN \(w.dirA) \(k)")
        XCTAssertTrue(r.hasPrefix("ERROR io: "), "\(label): refused: \(r)", file: file, line: line)
        for word in words {
            XCTAssertTrue(r.contains(word), "\(label): the refusal names '\(word)': \(r)", file: file, line: line)
        }
        try assertUnchanged(before, w.dirA, "\(label): the refused open", file: file, line: line)
        XCTAssertEqual(tiledRefused(h), 1, "\(label): counted in STATUS", file: file, line: line)

        let r2 = h.handle("TILED OPEN \(w.dirA) \(k)")
        XCTAssertEqual(r2, r, "\(label): a later TILED OPEN refuses the same", file: file, line: line)
        try assertUnchanged(before, w.dirA, "\(label): the second refused open", file: file, line: line)
        XCTAssertEqual(tiledRefused(h), 2, "\(label): counted again", file: file, line: line)
    }

    /// O-a: tile 0 pending at its own epoch (case (ii), recovered first, it
    /// writes), tile 1 pending at epoch 5 over a body at 1.
    func testT2_1Oa_APendingBodyAtNeitherEpoch() throws {
        for k in [1, 4] {
            try openRefusalCell("O-a", k: k, words: ["tile 1 epoch mismatch — meta.json says 5, body says 1"]) { _, root in
                try self.appendWAL(root, 0, "TILE_FLUSH_BEGIN 0 1 rank")
                try self.appendWAL(root, 1, "TILE_FLUSH_BEGIN 1 5 rank")
            }
        }
    }

    /// O-b: tile 0 pending (case (ii)); tile 1 pending at 2 over a body at 1
    /// (case (i), rank): its source's strip at epoch 2 was never written.
    func testT2_1Ob_RecoveryCaseIGhostStripStale() throws {
        for k in [1, 4] {
            try openRefusalCell("O-b", k: k, words: ["tile 2 lower strip stale — expected epoch 2, found 0"]) { _, root in
                try self.appendWAL(root, 0, "TILE_FLUSH_BEGIN 0 1 rank")
                try self.appendWAL(root, 1, "TILE_FLUSH_BEGIN 1 2 rank")
            }
        }
    }

    /// O-c: tile 0 pending (case (ii)); tile 1 pending at its own epoch 1
    /// (case (ii)) with its previous-parity strip (epoch 0) stamped 7: a
    /// register's pre-latch byte has no source.
    func testT2_1Oc_RecoveryCaseIIPreviousStripStale() throws {
        for k in [1, 4] {
            try openRefusalCell("O-c", k: k, words: ["tile 1 lower strip stale — expected epoch 0, found 7"]) { _, root in
                try self.appendWAL(root, 0, "TILE_FLUSH_BEGIN 0 1 rank")
                try self.appendWAL(root, 1, "TILE_FLUSH_BEGIN 1 1 rank")
                try self.setStripEpoch(root, 1, parity: 0, 7)
            }
        }
    }

    /// O-d: a world saved at 2^32 − 1; tile 0 pending at it (case (ii)), tile
    /// 1 pending at 2^32 over a body at 2^32 − 1 (case (i), sync): its
    /// re-flush's epoch does not fit the body's tick field.
    func testT2_1Od_RecoveryCaseIEpochPastTheField() throws {
        for k in [1, 4] {
            try openRefusalCell("O-d", k: k, tickCount: UInt32.max, preTick: false,
                                words: ["tile 1 epoch 4294967296 does not fit body.dags's 32-bit tick field"]) { _, root in
                try self.appendWAL(root, 0, "TILE_FLUSH_BEGIN 0 4294967295 rank")
                try self.appendWAL(root, 1, "TILE_FLUSH_BEGIN 1 4294967296 sync")
            }
        }
    }

    /// O-e: a `crossingsIn` local past the node count on a recovered tile
    /// (tile 0 recovered first, then tile 1, case (ii)) and on a completed
    /// tile (a rank round torn at tile 1 by a GPU failure: completion ticks
    /// tile 1, then tile 0).
    func testT2_1Oe_CrossingsInPastTheNodeCountAtTheOpen() throws {
        for k in [1, 4] {
            try openRefusalCell("O-e recovery", k: k,
                                words: ["tile 1 lists a crossing at local id 9999, at or past its own node count 360"]) { _, root in
                try self.appendWAL(root, 0, "TILE_FLUSH_BEGIN 0 1 rank")
                try self.appendWAL(root, 1, "TILE_FLUSH_BEGIN 1 1 rank")
                try self.editEntry(root, 1) { e in
                    self.entry(e, crossingsIn: e.crossingsIn + [
                        Crossing(localNode: 9999, remoteNode: try GlobalNodeID(tileId: 0, localNodeId: 0))])
                }
            }
            try openRefusalCell("O-e completion", k: k,
                                words: ["tile 0 lists a crossing at local id 9999, at or past its own node count 81"]) { h, root in
                try self.tearByGPU(h, "\(root)/\(Self.graphName)", sync: false, fail: 1, "O-e completion")
                try self.editEntry(root, 0) { e in
                    self.entry(e, crossingsIn: e.crossingsIn + [
                        Crossing(localNode: 9999, remoteNode: try GlobalNodeID(tileId: 1, localNodeId: 0))])
                }
            }
        }
    }

    /// O-f: a rank round torn at tile 1 (tiles 3 and 2 at epoch 2), tile 0
    /// pending at its own epoch (recovered first, it writes); then the mode at
    /// the max epoch disagrees (tile 3's last BEGIN says sync), or no tile at
    /// the max carries a BEGIN for it.
    func testT2_1Of_CompletionModeRefusedAfterRecovery() throws {
        for k in [1, 4] {
            try openRefusalCell("O-f mismatch", k: k,
                                words: ["partial-round mode mismatch among tiles at max epoch: tile 2=\"rank\", tile 3=\"sync\""]) { h, root in
                try self.tearByGPU(h, "\(root)/\(Self.graphName)", sync: false, fail: 1, "O-f")
                try self.rewriteWAL(root, 3) { $0.replacingOccurrences(of: "TILE_FLUSH_BEGIN 3 2 rank", with: "TILE_FLUSH_BEGIN 3 2 sync") }
                try self.appendWAL(root, 0, "TILE_FLUSH_BEGIN 0 1 rank")
            }
            try openRefusalCell("O-f no mode", k: k, words: ["world torn — tiles span epochs 1..2"]) { h, root in
                try self.tearByGPU(h, "\(root)/\(Self.graphName)", sync: false, fail: 1, "O-f")
                for t: UInt32 in [2, 3] {
                    try self.rewriteWAL(root, t) { $0.replacingOccurrences(of: "TILE_FLUSH_BEGIN \(t) 2 rank\n", with: "") }
                }
                try self.appendWAL(root, 0, "TILE_FLUSH_BEGIN 0 1 rank")
            }
        }
    }

    /// O-g: completion's ghost refusals: a rank round torn at tile 1
    /// (completion ticks 1, then 0; tile 0's crossing names tile 9), and a
    /// sync round torn at tile 1 (completion ticks 1, 2, 3; tile 2's crossing
    /// names tile 9).
    func testT2_1Og_CompletionGhostReferenceRefused() throws {
        for k in [1, 4] {
            try openRefusalCell("O-g rank", k: k, words: ["tile 0 local ", "the manifest holds no tile 9"]) { h, root in
                try self.tearByGPU(h, "\(root)/\(Self.graphName)", sync: false, fail: 1, "O-g rank")
                try self.repoint(root, reader: 0, tile: 9, local: 0)
            }
            try openRefusalCell("O-g sync", k: k, words: ["tile 2 local ", "the manifest holds no tile 9"]) { h, root in
                try self.tearByGPU(h, "\(root)/\(Self.graphName)", sync: true, fail: 1, "O-g sync")
                try self.repoint(root, reader: 2, tile: 9, local: 0)
            }
        }
    }

    func rewriteWAL(_ root: String, _ id: UInt32, _ body: (String) -> String) throws {
        let path = "\(try tileDir(root, id))/flush.wal"
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let new = body(text)
        XCTAssertNotEqual(new, text, "the wal edit applies")
        try Data(new.utf8).write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Whole-world checks (the recovery measures)

    enum Reference: String { case pre, post }

    /// After a fresh open of A: every tile's files byte-equal to its pre-round
    /// or its post-round reference (never a mixture inside one tile), every
    /// tile the same one (a writer's world is never torn), the manifest equal
    /// to that reference's, and the epochs agreeing with the files. Returns
    /// which reference A equals (nil on a mixture).
    @discardableResult
    func assertWhole(_ w: Worlds, id: String, pre: [String: Data], post: [String: Data], _ label: String,
                     file: StaticString = #filePath, line: UInt = #line) throws -> Reference? {
        let now = try snapshot(w.dirA)
        var which: [UInt32: Reference] = [:]
        for t: UInt32 in 0..<4 {
            let p = try tilePrefix(w.rootA, t)
            let mine = now.filter { $0.key.hasPrefix(p) }
            let a = pre.filter { $0.key.hasPrefix(p) }, b = post.filter { $0.key.hasPrefix(p) }
            if mine == a { which[t] = .pre } else if mine == b { which[t] = .post } else {
                func diff(_ ref: [String: Data]) -> [String] {
                    Set(mine.keys).symmetricDifference(ref.keys).sorted()
                        + mine.keys.sorted().filter { ref[$0] != nil && ref[$0] != mine[$0] }
                }
                let (dPre, dPost) = (diff(a), diff(b))
                XCTFail("\(label): tile \(t)'s files equal neither its pre- nor its post-round reference: "
                        + (dPost.count <= dPre.count ? "against post \(dPost)" : "against pre \(dPre)"),
                        file: file, line: line)
            }
        }
        let kinds = Set(which.values)
        XCTAssertEqual(kinds.count, 1, "\(label): every tile at the same reference: \(which.sorted { $0.key < $1.key })",
                       file: file, line: line)
        guard kinds.count == 1, which.count == 4, let r = kinds.first else { return nil }
        let ref = r == .pre ? pre : post
        XCTAssertEqual(now["manifest.json"], ref["manifest.json"], "\(label): manifest.json equals the \(r) reference's",
                       file: file, line: line)
        XCTAssertEqual(now.keys.sorted(), ref.keys.sorted(), "\(label): the same files as the \(r) reference",
                       file: file, line: line)
        // The epochs agree with the files: the manifest entry, meta.json and the body's own field.
        let router = try XCTUnwrap(w.h.tiledRouters[id]).router
        let epochs = try w.h.runTiledSync { try await router.tileEpochs() }
        let m = try manifest(w.rootA)
        for e in m.tiles {
            let pe = try XCTUnwrap(epochs[e.id])
            XCTAssertTrue(pe.metaEpoch == e.tickEpoch && pe.bodyEpoch == e.tickEpoch,
                          "\(label): tile \(e.id) manifest \(e.tickEpoch) meta \(pe.metaEpoch) body \(pe.bodyEpoch)",
                          file: file, line: line)
        }
        let st = w.h.handle("TILED STATUS \(id)")
        let e = m.tiles[0].tickEpoch
        XCTAssertTrue(st.hasSuffix(" epoch=\(e)/\(e)"), "\(label): \(st)", file: file, line: line)
        return r
    }

    /// A (router `idA`) and B (`idB`): the routers' truth over every node and
    /// every file of the two worlds, byte for byte.
    func assertTwins(_ w: Worlds, idA: String, idB: String, _ label: String,
                     file: StaticString = #filePath, line: UInt = #line) throws {
        let ra = try XCTUnwrap(w.h.tiledRouters[idA]).router
        let rb = try XCTUnwrap(w.h.tiledRouters[idB]).router
        let ta = try w.h.runTiledSync { try await ra.truthArray() }
        let tb = try w.h.runTiledSync { try await rb.truthArray() }
        XCTAssertEqual(ta, tb, "\(label): truth equals the twin's", file: file, line: line)
        let fa = try snapshot(w.dirA), fb = try snapshot(w.dirB)
        XCTAssertEqual(fa.keys.sorted(), fb.keys.sorted(), "\(label): the same files", file: file, line: line)
        XCTAssertEqual(fa.keys.sorted().filter { fa[$0] != fb[$0] }, [],
                       "\(label): every file byte-identical to the twin's", file: file, line: line)
    }

    /// After A was found whole at `r`: a following round on A ticks equal to
    /// the never-failed twin B (at post). A at pre first catches up one round.
    func assertFollowingRound(_ w: Worlds, idA: String, idB: String, at r: Reference, sync: Bool, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        if r == .pre {
            tickOK(w.h, idA, 1, sync: sync, "\(label): A catches up", file: file, line: line)
            try assertTwins(w, idA: idA, idB: idB, "\(label): A after its round", file: file, line: line)
        }
        tickOK(w.h, idA, 1, sync: sync, "\(label): the following round on A", file: file, line: line)
        tickOK(w.h, idB, 1, sync: sync, "\(label): the following round on B", file: file, line: line)
        try assertTwins(w, idA: idA, idB: idB, "\(label): the following round", file: file, line: line)
    }

    // MARK: - The recovery measures, on the older code's API (crafted kill states)

    enum CraftedKill: String { case afterBegin = "after BEGIN", afterRename = "after the body's rename" }

    /// A and B ticked once in rank mode (epoch 1); `pre` = A's files; B ticks
    /// one `sync` round (`post`). A is made the disk a kill leaves inside tile
    /// `order[index]`'s flush at epoch 2: the tiles before it in the round at
    /// their post files and manifest entries; that tile at its pre files with
    /// `TILE_FLUSH_BEGIN <t> 2 <mode>` appended (after BEGIN), or also its body
    /// replaced by the post body and its sidecar gone (after the rename); the
    /// rest at pre. Then a fresh open must recover the tile and complete the
    /// round to the post reference, and a following round equal the twin's.
    func craftedKillCell(sync: Bool, k: Int, index: Int, kill: CraftedKill,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let order = Self.order(sync: sync)
        let t = order[index]
        let label = "crafted kill \(kill.rawValue) of tile \(t) (\(sync ? "SYNC" : "rank"), K=\(k))"
        let w = try makeWorlds()
        let h = w.h
        let idA = open(h, w.dirA, k, label), idB = open(h, w.dirB, k, label)
        tickOK(h, idA, 1, sync: false, label); tickOK(h, idB, 1, sync: false, label)
        try assertTwins(w, idA: idA, idB: idB, "\(label): epoch 1")
        close(h, idA)
        let pre = try snapshot(w.dirA)
        tickOK(h, idB, 1, sync: sync, label)
        let post = try snapshot(w.dirB)

        // The crafted disk.
        let fm = FileManager.default
        let mPre = try manifest(w.rootA), mPost = try manifest(w.rootB)
        let flushed = Set(order.prefix(index))
        for u in flushed {
            let da = try tileDir(w.rootA, u), db = try tileDir(w.rootB, u)
            try fm.removeItem(atPath: da)
            try fm.copyItem(atPath: db, toPath: da)
        }
        let dt = try tileDir(w.rootA, t)
        if kill == .afterRename {
            try fm.removeItem(atPath: "\(dt)/body.dags")
            try fm.copyItem(atPath: "\(try tileDir(w.rootB, t))/body.dags", toPath: "\(dt)/body.dags")
            try fm.removeItem(atPath: "\(dt)/body.dags.sha256")
        }
        try appendWAL(w.rootA, t, "TILE_FLUSH_BEGIN \(t) 2 \(sync ? "sync" : "rank")")
        try TiledGraphFiles.writeManifest(dataRoot: w.rootA, name: Self.graphName, manifest: TiledGraphFiles.Manifest(
            format: mPre.format, version: mPre.version, name: mPre.name, boundaries: mPre.boundaries,
            globalNodeCount: mPre.globalNodeCount,
            tiles: try mPre.tiles.map { e in flushed.contains(e.id) ? try XCTUnwrap(mPost.tiles.first { $0.id == e.id }) : e }))

        let r = h.handle("TILED OPEN \(w.dirA) \(k)")
        XCTAssertTrue(r.hasPrefix("OK TILED OPEN id=")
                      && r.hasSuffix(" recovered=1 completed=\(order.count - index - 1)"), "\(label): \(r)",
                      file: file, line: line)
        let id = token(r, "id") ?? "none"
        let at = try assertWhole(w, id: id, pre: pre, post: post, label, file: file, line: line)
        XCTAssertEqual(at, .post, "\(label): the round completed", file: file, line: line)
        if let at { try assertFollowingRound(w, idA: id, idB: idB, at: at, sync: sync, label, file: file, line: line) }
    }

    func testT2_2CraftedKillStatesRank() throws {
        for k in [1, 4] {
            for index in [0, 1, 3] {
                for kill in [CraftedKill.afterBegin, .afterRename] {
                    try craftedKillCell(sync: false, k: k, index: index, kill: kill)
                }
            }
        }
    }

    func testT2_2CraftedKillStatesSync() throws {
        for k in [1, 4] {
            for index in [0, 1, 3] {
                for kill in [CraftedKill.afterBegin, .afterRename] {
                    try craftedKillCell(sync: true, k: k, index: index, kill: kill)
                }
            }
        }
    }
}
