import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Three defects an independent check found in the tiled round's atomicity, in
/// process, on the same object as `EngineTiled2DaemonTests` (the side-44
/// fixture, 4 tiles; a twin B as the never-failed reference). This file uses
/// only the API of the code before these fixes (it compiles and runs there,
/// for the red).
///
/// **A torn last wal record is cut at open.** The disk a kill inside a
/// tile's wal append leaves (the record's first bytes, no newline): a torn
/// BEGIN (the tile at its pre-round files, the tiles before it in the round at
/// post) and a torn COMMIT (the tile at post but for its wal, which ends in
/// its BEGIN and the COMMIT's first bytes); the first, a middle and the last
/// tile, rank and SYNC, K = 1 and 4; and the first record a tile's wal ever
/// held (a world never ticked: the wal holds only the torn bytes). A fresh
/// `TILED OPEN` must cut the torn record (an incomplete append never started
/// its step), recover and complete as the record's absence implies, leave
/// every tile at its pre- or post-round files (the cut wal included), and a
/// following round must tick equal to the twin. Control: the open-time cut
/// removed (every cell refused by name, as on the code before the fix).
///
/// **An unreadable `flush.wal` refuses the open by name.** A tile's wal at
/// mode 0200 (writable, not readable) or 000, over a dangling BEGIN (recovery
/// case (i)) or a clean wal: `TILED OPEN` must be refused by name, counted
/// (`STATUS tiled_refused`), every file byte-identical (read after the mode is
/// restored); after the mode is restored, an open recovers the world whole and
/// a following round ticks equal to the twin. Control: the read's `try?`
/// restored (the wal read as clean: a second BEGIN, or a write).
///
/// **A TILED TICK refused after a failed write step is counted.** A round
/// whose write step failed (the seam's I/O error: the body's tmp, leaving a
/// dangling BEGIN; the BEGIN append, cut back, leaving a torn world; the
/// COMMIT append, cut back, leaving a dangling BEGIN) and the next `TILED
/// TICK`s on the same router, refused ("flush incomplete at epoch k" /
/// "world torn"): each refusal counted in `TILED STATUS` (`refused=` + 1,
/// `last=tile <t>: <the refusal>`), no file written. Control: the count
/// removed.
extension EngineTiled2DaemonTests {

    // MARK: - A torn last record, cut at open

    enum TornRecord: String { case begin = "a torn BEGIN", commit = "a torn COMMIT" }

    /// `n` of `record`'s bytes for the cell's tile index: 1 byte (the first
    /// tile), half (a middle tile), all but the newline (the last tile).
    static func tornLength(_ record: String, index: Int) -> Int {
        let c = record.utf8.count
        switch index {
        case 0: return 1
        case 3: return c - 1
        default: return c / 2
        }
    }

    func setWAL(_ root: String, _ id: UInt32, _ bytes: Data) throws {
        try bytes.write(to: URL(fileURLWithPath: "\(try tileDir(root, id))/flush.wal"))
    }

    func walBytes(_ root: String, _ id: UInt32) -> Data {
        (try? Data(contentsOf: URL(fileURLWithPath: "\(try tileDir(root, id))/flush.wal"))) ?? Data()
    }

    /// A and B at K, ticked once in rank mode (epoch 1) unless `fresh`; `pre` =
    /// A's files; B ticks one round (`sync`) to `post`. A is made the disk a
    /// kill inside tile `order[index]`'s wal append at that round's epoch
    /// leaves; a fresh open must cut the torn record and leave A whole.
    func tornRecordCell(sync: Bool, k: Int, index: Int, torn: TornRecord, fresh: Bool = false,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let order = Self.order(sync: sync)
        let t = order[index]
        let e: UInt64 = fresh ? 1 : 2
        let begin = "TILE_FLUSH_BEGIN \(t) \(e) \(sync ? "sync" : "rank")\n"
        let commit = "TILE_FLUSH_COMMIT \(t) \(e)\n"
        let n = Self.tornLength(torn == .begin ? begin : commit, index: index)
        let label = "\(torn.rawValue) (\(n) byte(s)) of tile \(t) at epoch \(e) (\(sync ? "SYNC" : "rank"), K=\(k)"
            + "\(fresh ? ", the wal's first record" : ""))"
        let w = try makeWorlds()
        let h = w.h
        let idA = open(h, w.dirA, k, label), idB = open(h, w.dirB, k, label)
        if !fresh {
            tickOK(h, idA, 1, sync: false, label); tickOK(h, idB, 1, sync: false, label)
            try assertTwins(w, idA: idA, idB: idB, "\(label): epoch 1", file: file, line: line)
        }
        close(h, idA)
        let pre = try snapshot(w.dirA)
        let walPre = walBytes(w.rootA, t)
        tickOK(h, idB, 1, sync: sync, label)
        let post = try snapshot(w.dirB)

        // The crafted disk: the tiles before t at post; t as the kill left it; the rest at pre.
        let fm = FileManager.default
        let mPre = try manifest(w.rootA), mPost = try manifest(w.rootB)
        var flushed = Set(order.prefix(index))
        for u in flushed {
            let da = try tileDir(w.rootA, u)
            try fm.removeItem(atPath: da)
            try fm.copyItem(atPath: try tileDir(w.rootB, u), toPath: da)
        }
        switch torn {
        case .begin:
            try setWAL(w.rootA, t, walPre + Data(begin.utf8.prefix(n)))
        case .commit:
            let da = try tileDir(w.rootA, t)
            try fm.removeItem(atPath: da)
            try fm.copyItem(atPath: try tileDir(w.rootB, t), toPath: da)
            let walPost = walBytes(w.rootB, t)
            XCTAssertTrue(walPost.suffix(commit.utf8.count) == Data(commit.utf8), "\(label): B's wal ends in the COMMIT")
            try setWAL(w.rootA, t, walPost.prefix(walPost.count - commit.utf8.count + n))
            flushed.insert(t)
        }
        try TiledGraphFiles.writeManifest(dataRoot: w.rootA, name: Self.graphName, manifest: TiledGraphFiles.Manifest(
            format: mPre.format, version: mPre.version, name: mPre.name, boundaries: mPre.boundaries,
            globalNodeCount: mPre.globalNodeCount,
            tiles: try mPre.tiles.map { x in flushed.contains(x.id) ? try XCTUnwrap(mPost.tiles.first { $0.id == x.id }) : x }))
        let crafted = walBytes(w.rootA, t)
        XCTAssertFalse(crafted.last == UInt8(ascii: "\n"), "\(label): the crafted wal ends mid-record", file: file, line: line)

        let refused0 = tiledRefused(h)
        let r = h.handle("TILED OPEN \(w.dirA) \(k)")
        let (recovered, completed) = torn == .commit ? (1, order.count - index - 1)
            : (0, index == 0 ? 0 : order.count - index)
        XCTAssertTrue(r.hasPrefix("OK TILED OPEN id=") && r.hasSuffix(" recovered=\(recovered) completed=\(completed)"),
                      "\(label): the fresh open cuts the torn record: \(r)", file: file, line: line)
        XCTAssertEqual(tiledRefused(h), refused0, "\(label): no refused open", file: file, line: line)
        guard r.hasPrefix("OK") else { return }
        let id = token(r, "id") ?? "none"
        let at = try assertWhole(w, id: id, pre: pre, post: post, label, file: file, line: line)
        XCTAssertEqual(at, torn == .begin && index == 0 ? .pre : .post, "\(label): the reference", file: file, line: line)
        if let at { try assertFollowingRound(w, idA: id, idB: idB, at: at, sync: sync, label, file: file, line: line) }
    }

    func testT2F_1TornLastRecordCutAtOpenRank() throws {
        for k in [1, 4] {
            for index in [0, 1, 3] {
                for torn in [TornRecord.begin, .commit] { try tornRecordCell(sync: false, k: k, index: index, torn: torn) }
            }
        }
    }

    func testT2F_1TornLastRecordCutAtOpenSync() throws {
        for k in [1, 4] {
            for index in [0, 1, 3] {
                for torn in [TornRecord.begin, .commit] { try tornRecordCell(sync: true, k: k, index: index, torn: torn) }
            }
        }
    }

    /// A world never ticked: the torn BEGIN is the first record its wal ever
    /// held (the first and a middle tile of the round).
    func testT2F_1TornFirstRecordOfANewWAL() throws {
        for sync in [false, true] {
            for index in [0, 1] {
                try tornRecordCell(sync: sync, k: 1, index: index, torn: .begin, fresh: true)
            }
        }
    }

    // MARK: - An unreadable flush.wal refuses the open by name

    /// A and B at K = 2, ticked once in rank mode (epoch 1); `pre` = A; B
    /// ticks one round (`sync`) to `post`. With `pending`, A is the disk a kill
    /// after the middle tile's BEGIN leaves (the tile before it at post; the
    /// tile at pre with `TILE_FLUSH_BEGIN <t> 2 <mode>` appended); otherwise A
    /// stays at pre (a clean wal). Tile t's wal is made mode `mode`; the open
    /// must be refused by name and counted, every file byte-identical; with the
    /// mode restored, an open recovers A whole and its following round equals
    /// the twin's.
    func unreadableWALCell(sync: Bool, pending: Bool, mode: mode_t,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let order = Self.order(sync: sync)
        let index = 1, t = order[index]
        let label = "flush.wal mode \(String(mode, radix: 8)) of tile \(t) over "
            + "\(pending ? "a dangling BEGIN (recovery case (i))" : "a clean wal") (\(sync ? "SYNC" : "rank"), K=2)"
        let w = try makeWorlds()
        let h = w.h
        let idA = open(h, w.dirA, 2, label), idB = open(h, w.dirB, 2, label)
        tickOK(h, idA, 1, sync: false, label); tickOK(h, idB, 1, sync: false, label)
        close(h, idA)
        let pre = try snapshot(w.dirA)
        tickOK(h, idB, 1, sync: sync, label)
        let post = try snapshot(w.dirB)
        if pending {
            let fm = FileManager.default
            let mPre = try manifest(w.rootA), mPost = try manifest(w.rootB)
            let flushed = Set(order.prefix(index))
            for u in flushed {
                let da = try tileDir(w.rootA, u)
                try fm.removeItem(atPath: da)
                try fm.copyItem(atPath: try tileDir(w.rootB, u), toPath: da)
            }
            try appendWAL(w.rootA, t, "TILE_FLUSH_BEGIN \(t) 2 \(sync ? "sync" : "rank")")
            try TiledGraphFiles.writeManifest(dataRoot: w.rootA, name: Self.graphName, manifest: TiledGraphFiles.Manifest(
                format: mPre.format, version: mPre.version, name: mPre.name, boundaries: mPre.boundaries,
                globalNodeCount: mPre.globalNodeCount,
                tiles: try mPre.tiles.map { x in flushed.contains(x.id) ? try XCTUnwrap(mPost.tiles.first { $0.id == x.id }) : x }))
        }
        let before = try snapshot(w.dirA)
        let wal = "\(try tileDir(w.rootA, t))/flush.wal"
        XCTAssertEqual(chmod(wal, mode), 0, "\(label): chmod", file: file, line: line)
        let refused0 = tiledRefused(h) ?? -1
        let r = h.handle("TILED OPEN \(w.dirA) 2")
        let refused1 = tiledRefused(h) ?? -1
        XCTAssertEqual(chmod(wal, 0o644), 0, "\(label): chmod back", file: file, line: line)
        // The flush.wal read goes through the read helper, whose refusals name the errno (EACCES) and quote
        // the path, in place of the older "errno 13" detail; the
        // router's own "tile <t> flush.wal cannot be read (…); refused, nothing written" is unchanged.
        XCTAssertTrue(r.hasPrefix("ERROR io: ") && r.contains("tile \(t) flush.wal cannot be read")
                      && (r.contains("EACCES") || r.contains("errno 13")),
                      "\(label): refused by name: \(r)", file: file, line: line)
        XCTAssertEqual(refused1, refused0 + 1, "\(label): counted in STATUS tiled_refused", file: file, line: line)
        if r.hasPrefix("OK"), let id = token(r, "id") { close(h, id) }
        try assertUnchanged(before, w.dirA, "\(label): the refused open", file: file, line: line)

        let r2 = h.handle("TILED OPEN \(w.dirA) 2")
        let (recovered, completed) = pending ? (1, order.count - index - 1) : (0, 0)
        XCTAssertTrue(r2.hasPrefix("OK TILED OPEN id=") && r2.hasSuffix(" recovered=\(recovered) completed=\(completed)"),
                      "\(label): the open after the mode is restored: \(r2)", file: file, line: line)
        guard r2.hasPrefix("OK") else { return }
        let id = token(r2, "id") ?? "none"
        let at = try assertWhole(w, id: id, pre: pre, post: post, label, file: file, line: line)
        XCTAssertEqual(at, pending ? .post : .pre, "\(label): the reference", file: file, line: line)
        if let at { try assertFollowingRound(w, idA: id, idB: idB, at: at, sync: sync, label, file: file, line: line) }
    }

    func testT2F_2UnreadableWALRefusedByName() throws {
        for mode: mode_t in [0o200, 0o000] {
            for sync in [false, true] { try unreadableWALCell(sync: sync, pending: true, mode: mode) }
            try unreadableWALCell(sync: false, pending: false, mode: mode)
        }
    }

    // MARK: - A TICK refused after a failed write step, counted

    /// A at K, ticked once in rank mode (epoch 1); its round (`sync`) meets the
    /// seam's I/O error at `point` of tile `order[index]` at epoch 2; then two
    /// more `TILED TICK`s on the same router, each refused with `words`, each
    /// counted (`refused=1`, then 2, `last=tile <tile>: …`), no file written.
    func postFailureCell(sync: Bool, k: Int, index: Int, point: TiledWritePoint, words: String, tile: UInt32,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let order = Self.order(sync: sync)
        let t = order[index]
        let label = "a TICK after an I/O error at \(point.rawValue) of tile \(t) (\(sync ? "SYNC" : "rank"), K=\(k))"
        let w = try makeWorlds(twin: false)
        let h = w.h
        let id = open(h, w.dirA, k, label)
        tickOK(h, id, 1, sync: false, label)
        let box = SeamBox()
        let ra = try XCTUnwrap(h.tiledRouters[id]).router
        let s = seam(point, tile: t, epoch: 2, pass: .round, .ioError, tileDir: try tileDir(w.rootA, t), box: box)
        try h.runTiledSync { await ra.setWriteSeamForTesting(s) }
        let r = tick(h, id, 1, sync: sync)
        try h.runTiledSync { await ra.setWriteSeamForTesting(nil) }
        XCTAssertTrue(r.hasPrefix("ERROR io: TILED TICK: ") && r.contains("write step '\(Self.stepName(point))'"),
                      "\(label): the failed step: \(r)", file: file, line: line)
        let st0 = h.handle("TILED STATUS \(id)")
        XCTAssertTrue(st0.contains(" refused=0 last=none "), "\(label): nothing refused yet: \(st0)", file: file, line: line)
        let before = try snapshot(w.dirA)
        for n in 1...2 {
            // The second in the other mode: the refusal is the router's, whatever the mode.
            let rr = tick(h, id, 1, sync: n == 1 ? sync : !sync)
            XCTAssertTrue(rr.hasPrefix("ERROR io: TiledGraphRouter: ") && rr.contains(words),
                          "\(label): TICK \(n) refused: \(rr)", file: file, line: line)
            let st = h.handle("TILED STATUS \(id)")
            XCTAssertTrue(st.contains(" refused=\(n) last=\"tile \(tile): ") && st.contains(words),
                          "\(label): TICK \(n)'s refusal counted: \(st)", file: file, line: line)
        }
        try assertUnchanged(before, w.dirA, "\(label): the refused ticks", file: file, line: line)
        close(h, id)
    }

    func testT2F_3PostFailureTickRefusalsCounted() throws {
        for k in [1, 4] {
            for sync in [false, true] {
                let order = Self.order(sync: sync)
                // The body's tmp fails: tile order[i]'s BEGIN dangles.
                for index in [0, 1, 3] {
                    try postFailureCell(sync: sync, k: k, index: index, point: .bodyTmpDone,
                                        words: "flush incomplete at epoch 2", tile: order[index])
                }
                // The BEGIN append fails and is cut back: the tiles before it at 2, the world torn.
                for index in [1, 3] {
                    let below = order.suffix(from: index).min()!
                    try postFailureCell(sync: sync, k: k, index: index, point: .beginMid,
                                        words: "world torn", tile: below)
                }
                // The COMMIT append fails and is cut back: tile order[1]'s BEGIN dangles.
                try postFailureCell(sync: sync, k: k, index: 1, point: .commitMid,
                                    words: "flush incomplete at epoch 2", tile: order[1])
            }
        }
    }
}
