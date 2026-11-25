import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// An I/O error at every write step, and the process killed at every step
/// boundary, of a tiled round and of `TILED OPEN`'s recovery and completion.
///
/// The in-process write seam (`TiledWriteSeam`, the router's for a round, the
/// handler's for an open) sees every instant of the round's write steps
/// (`TiledWritePoint`): inside a step (`…Mid`: half the record or the temp
/// file written) and after it (`…Done`), and the body save's own boundaries
/// (`bodyTmpDone`, `bodyOldSidecarRemoved`, `bodyRenamed`, `bodySidecarDone`).
/// A cell's action at its one instant:
/// - **I/O error** (`SeamIOError` thrown inside the step, or at the save's
///   boundary where a failed write ends it): the verb must reply an error
///   naming the step and the tile;
/// - **sidecar write lost** (at `bodySidecarDone`, the sidecar removed and
///   nothing thrown — what the save's swallowed failure leaves): the same;
/// - **kill** (`SeamKill` at a step boundary; the process is gone: the router
///   is dropped, the reply ignored; a kill before the body's rename leaves
///   `body.dags.tmp`, put back as a kill leaves it).
///
/// Then, after a fresh `TILED OPEN` (recovery and completion as they exist):
/// every tile's files byte-equal to its pre-round or its post-round reference
/// (the never-failed twin B's), never a mixture inside one tile; the epochs
/// agree with the files; a following round ticks equal to the twin. Rounds:
/// the first, a middle (`order[1]`) and the last tile, rank and SYNC, K = 1
/// and K = 4. Opens: recovery case (i) (from a kill after a middle tile's
/// BEGIN), case (ii) (after its body's rename: no sidecar), and completion's
/// first tile, at every step; and the strip regeneration step of a round.
///
/// Controls that must fail: each step's atomicity measure removed — the wal
/// append's cut-back, the strip/meta/manifest/sidecar temp-and-rename, the
/// sidecar check and rewrite, the re-flush without a second BEGIN — gives a
/// torn tile file or a mixture.
extension EngineTiled2DaemonTests {

    final class SeamBox: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var tmp: (path: String, data: Data)?
        var fired: Int { lock.lock(); defer { lock.unlock() }; return count }
        func fire() { lock.lock(); count += 1; lock.unlock() }
        func keepTmp(_ path: String) {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
            lock.lock(); tmp = (path, d); lock.unlock()
        }
        /// Puts back the `body.dags.tmp` a kill before the rename leaves (the
        /// in-process stop runs the save's `defer`, which removes it).
        /// The temporary carries the daemon's marker
        /// and its writer's pid; a killed writer's pid is dead, so it goes back
        /// under a dead pid, and the restart's boot sweep (run here on `root`,
        /// as the restart would) removes it before the world is opened again.
        func restoreTmp(sweeping root: String) throws {
            lock.lock(); let t = tmp; tmp = nil; lock.unlock()
            guard let t else { return }
            let dead = t.path.replacingOccurrences(of: ".dagdb-tmp-\(getpid())-", with: ".dagdb-tmp-99999999-")
            try t.data.write(to: URL(fileURLWithPath: dead))
            _ = DagDBStartup.sweepStages(root: root)
        }
    }

    struct SeamIOError: Error, CustomStringConvertible {
        var description: String { "io: write failed (TILED2 seam)" }
    }

    struct SeamKill: Error, CustomStringConvertible {
        var description: String { "killed (TILED2 seam)" }
    }

    enum SeamAction: String { case ioError = "I/O error", kill = "kill", lostSidecar = "sidecar write lost" }

    func seam(_ point: TiledWritePoint, tile: UInt32, epoch: UInt64, pass: TiledWritePass, _ action: SeamAction,
              tileDir: String, box: SeamBox) -> TiledWriteSeam {
        { ev in
            guard ev.point == point, ev.tile == tile, ev.epoch == epoch, ev.pass == pass else { return }
            box.fire()
            switch action {
            case .ioError:
                throw SeamIOError()
            case .kill:
                // The body's temporary carries the daemon's marker (it was body.dags.tmp).
                if point == .bodyTmpDone || point == .bodyOldSidecarRemoved {
                    box.keepTmp(DaemonFile.leftoverTemporaries(of: "\(tileDir)/body.dags").first ?? "\(tileDir)/body.dags.tmp")
                }
                throw SeamKill()
            case .lostSidecar:
                try? FileManager.default.removeItem(atPath: "\(tileDir)/body.dags.sha256")
            }
        }
    }

    /// The step a reply must name for an I/O error at `p` (a round's epoch 2,
    /// so its strip is parity 0; the regeneration cells regenerate tile 3's parity 1).
    static func stepName(_ p: TiledWritePoint) -> String {
        switch p {
        case .beginMid, .beginDone: return "flush.wal BEGIN"
        case .bodyTmpDone: return "body.dags.tmp"
        case .bodyOldSidecarRemoved, .bodyRenamed: return "body.dags rename"
        case .bodySidecarDone, .sidecarRewriteMid, .sidecarRewriteDone: return "body.dags.sha256"
        case .stripMid, .stripDone: return "halo_lower.0.bin"
        case .metaMid, .metaDone: return "meta.json"
        case .manifestMid, .manifestDone: return "manifest.json"
        case .commitMid, .commitDone: return "flush.wal COMMIT"
        case .regenerateMid, .regenerateDone: return "halo_lower.1.bin"
        }
    }

    static let roundIOErrors: [(TiledWritePoint, SeamAction)] = [
        (.beginMid, .ioError), (.bodyTmpDone, .ioError), (.bodyOldSidecarRemoved, .ioError),
        (.bodySidecarDone, .lostSidecar), (.stripMid, .ioError), (.metaMid, .ioError),
        (.manifestMid, .ioError), (.commitMid, .ioError),
    ]
    static let roundKills: [TiledWritePoint] = [
        .beginDone, .bodyTmpDone, .bodyOldSidecarRemoved, .bodyRenamed, .bodySidecarDone,
        .stripDone, .metaDone, .manifestDone, .commitDone,
    ]

    // MARK: - A failed or killed round

    /// A and B at K, ticked once in rank mode (epoch 1, equal); `pre` = A's
    /// files. A's round (`sync`) meets `action` at `point` of tile
    /// `order[index]`'s flush at epoch 2; B ticks the same round (`post`). A's
    /// router is dropped; a fresh open of A must leave it whole at pre or post,
    /// with the recovery and completion counts the step implies, and its
    /// following round equal the twin's.
    func roundCell(sync: Bool, k: Int, index: Int, point: TiledWritePoint, action: SeamAction,
                   file: StaticString = #filePath, line: UInt = #line) throws {
        let order = Self.order(sync: sync)
        let t = order[index]
        let label = "round \(sync ? "SYNC" : "rank") K=\(k) tile \(t) (index \(index)): \(action.rawValue) at \(point.rawValue)"
        let w = try makeWorlds()
        let h = w.h
        let idA = open(h, w.dirA, k, label), idB = open(h, w.dirB, k, label)
        tickOK(h, idA, 1, sync: false, label); tickOK(h, idB, 1, sync: false, label)
        try assertTwins(w, idA: idA, idB: idB, "\(label): epoch 1", file: file, line: line)
        let pre = try snapshot(w.dirA)

        let box = SeamBox()
        let ra = try XCTUnwrap(h.tiledRouters[idA]).router
        let s = seam(point, tile: t, epoch: 2, pass: .round, action, tileDir: try tileDir(w.rootA, t), box: box)
        try h.runTiledSync { await ra.setWriteSeamForTesting(s) }
        let r = tick(h, idA, 1, sync: sync)
        try h.runTiledSync { await ra.setWriteSeamForTesting(nil) }
        XCTAssertEqual(box.fired, 1, "\(label): the seam fired once", file: file, line: line)
        if action == .kill {
            XCTAssertFalse(r.hasPrefix("OK"), "\(label): \(r)", file: file, line: line)
        } else {
            XCTAssertTrue(r.hasPrefix("ERROR io: TILED TICK: ") && r.contains("write step '\(Self.stepName(point))'")
                          && r.contains("tile \(t) epoch 2"), "\(label): the reply names the step: \(r)",
                          file: file, line: line)
        }
        close(h, idA)
        try box.restoreTmp(sweeping: w.rootA)

        tickOK(h, idB, 1, sync: sync, label)
        let post = try snapshot(w.dirB)

        // What the step leaves: a dangling BEGIN (recovered), the tile committed, or neither.
        let pending = action == .kill ? point != .commitDone : point != .beginMid
        let committed = action == .kill && point == .commitDone
        let atK = index + (pending || committed ? 1 : 0)
        let (recovered, completed) = atK == 0 ? (0, 0)
            : (pending ? 1 : 0, order.count - index - 1 + (pending || committed ? 0 : 1))
        let reopen = h.handle("TILED OPEN \(w.dirA) \(k)")
        XCTAssertTrue(reopen.hasPrefix("OK TILED OPEN id=") && reopen.hasSuffix(" recovered=\(recovered) completed=\(completed)"),
                      "\(label): the fresh open: \(reopen)", file: file, line: line)
        let id = token(reopen, "id") ?? "none"
        guard let at = try assertWhole(w, id: id, pre: pre, post: post, label, file: file, line: line) else { return }
        XCTAssertEqual(at, atK == 0 ? .pre : .post, "\(label): the reference", file: file, line: line)
        try assertFollowingRound(w, idA: id, idB: idB, at: at, sync: sync, label, file: file, line: line)
    }

    func testT2_2RoundIOErrorAtEveryStepRank() throws { try roundIOErrors(sync: false) }
    func testT2_2RoundIOErrorAtEveryStepSync() throws { try roundIOErrors(sync: true) }
    func testT2_2RoundKilledAtEveryBoundaryRank() throws { try roundKills(sync: false) }
    func testT2_2RoundKilledAtEveryBoundarySync() throws { try roundKills(sync: true) }

    func roundIOErrors(sync: Bool) throws {
        for k in [1, 4] {
            for index in [0, 1, 3] {
                for (p, a) in Self.roundIOErrors { try roundCell(sync: sync, k: k, index: index, point: p, action: a) }
            }
        }
    }

    func roundKills(sync: Bool) throws {
        for k in [1, 4] {
            for index in [0, 1, 3] {
                for p in Self.roundKills { try roundCell(sync: sync, k: k, index: index, point: p, action: .kill) }
            }
        }
    }

    // MARK: - A failed or killed open (recovery case (i), case (ii), completion)

    enum OpenStart: String { case caseI = "recovery case (i)", caseII = "recovery case (ii)", completion }

    /// A round on A killed inside its middle tile's (`order[1]`) flush at
    /// epoch 2 — after the BEGIN (recovery case (i), and completion), or after
    /// the body's rename (case (ii): no sidecar); B ticks the same round
    /// (`post`). A's open meets `action` at `point` of that tile's recovery,
    /// or of completion's first tile (`order[2]`); then a second fresh open
    /// must leave A whole at post, and its following round equal the twin's.
    func openCell(sync: Bool, k: Int, start: OpenStart, point: TiledWritePoint, action: SeamAction,
                  file: StaticString = #filePath, line: UInt = #line) throws {
        let order = Self.order(sync: sync)
        let t = order[1]
        let target = start == .completion ? order[2] : t
        let pass: TiledWritePass = start == .completion ? .completion : .recovery
        let label = "open \(sync ? "SYNC" : "rank") K=\(k) \(start.rawValue) tile \(target): \(action.rawValue) at \(point.rawValue)"
        let w = try makeWorlds()
        let h = w.h
        let idA = open(h, w.dirA, k, label), idB = open(h, w.dirB, k, label)
        tickOK(h, idA, 1, sync: false, label); tickOK(h, idB, 1, sync: false, label)
        let pre = try snapshot(w.dirA)

        let killBox = SeamBox()
        let ra = try XCTUnwrap(h.tiledRouters[idA]).router
        let roundKill = seam(start == .caseII ? .bodyRenamed : .beginDone, tile: t, epoch: 2, pass: .round, .kill,
                             tileDir: try tileDir(w.rootA, t), box: killBox)
        try h.runTiledSync { await ra.setWriteSeamForTesting(roundKill) }
        XCTAssertFalse(tick(h, idA, 1, sync: sync).hasPrefix("OK"), label, file: file, line: line)
        XCTAssertEqual(killBox.fired, 1, "\(label): the round's kill", file: file, line: line)
        close(h, idA)
        tickOK(h, idB, 1, sync: sync, label)
        let post = try snapshot(w.dirB)

        let box = SeamBox()
        h.tiledWriteSeamForTesting = seam(point, tile: target, epoch: 2, pass: pass, action,
                                          tileDir: try tileDir(w.rootA, target), box: box)
        let r = h.handle("TILED OPEN \(w.dirA) \(k)")
        h.tiledWriteSeamForTesting = nil
        XCTAssertEqual(box.fired, 1, "\(label): the seam fired once", file: file, line: line)
        if action == .kill {
            XCTAssertFalse(r.hasPrefix("OK"), "\(label): \(r)", file: file, line: line)
        } else {
            XCTAssertTrue(r.hasPrefix("ERROR io: TILED OPEN: ") && r.contains("write step '\(Self.stepName(point))'")
                          && r.contains("tile \(target) epoch 2"), "\(label): the reply names the step: \(r)",
                          file: file, line: line)
        }
        try box.restoreTmp(sweeping: w.rootA)

        let reopen = h.handle("TILED OPEN \(w.dirA) \(k)")
        XCTAssertTrue(reopen.hasPrefix("OK TILED OPEN id="), "\(label): the second open: \(reopen)", file: file, line: line)
        let id = token(reopen, "id") ?? "none"
        guard let at = try assertWhole(w, id: id, pre: pre, post: post, label, file: file, line: line) else { return }
        XCTAssertEqual(at, .post, "\(label): the round completed", file: file, line: line)
        try assertFollowingRound(w, idA: id, idB: idB, at: at, sync: sync, label, file: file, line: line)
    }

    static let caseIIOErrors: [(TiledWritePoint, SeamAction)] = [
        (.bodyTmpDone, .ioError), (.bodyOldSidecarRemoved, .ioError), (.bodySidecarDone, .lostSidecar),
        (.stripMid, .ioError), (.metaMid, .ioError), (.manifestMid, .ioError), (.commitMid, .ioError),
    ]
    static let caseIKills: [TiledWritePoint] = [
        .bodyTmpDone, .bodyOldSidecarRemoved, .bodyRenamed, .bodySidecarDone,
        .stripDone, .metaDone, .manifestDone, .commitDone,
    ]
    static let caseIIIOErrorPoints: [TiledWritePoint] = [.sidecarRewriteMid, .stripMid, .metaMid, .manifestMid, .commitMid]
    static let caseIIKills: [TiledWritePoint] = [.sidecarRewriteDone, .stripDone, .metaDone, .manifestDone, .commitDone]

    func testT2_2OpenRecoveryCaseIAtEveryStep() throws {
        for sync in [false, true] {
            for k in [1, 4] {
                for (p, a) in Self.caseIIOErrors { try openCell(sync: sync, k: k, start: .caseI, point: p, action: a) }
                for p in Self.caseIKills { try openCell(sync: sync, k: k, start: .caseI, point: p, action: .kill) }
            }
        }
    }

    func testT2_2OpenRecoveryCaseIIAtEveryStep() throws {
        for sync in [false, true] {
            for k in [1, 4] {
                for p in Self.caseIIIOErrorPoints { try openCell(sync: sync, k: k, start: .caseII, point: p, action: .ioError) }
                for p in Self.caseIIKills { try openCell(sync: sync, k: k, start: .caseII, point: p, action: .kill) }
            }
        }
    }

    func testT2_2OpenCompletionAtEveryStep() throws {
        for sync in [false, true] {
            for k in [1, 4] {
                for (p, a) in Self.roundIOErrors { try openCell(sync: sync, k: k, start: .completion, point: p, action: a) }
                for p in Self.roundKills { try openCell(sync: sync, k: k, start: .completion, point: p, action: .kill) }
            }
        }
    }

    // MARK: - The strip regeneration inside a round

    /// Sync mode over A and B whose tile 3 strip at parity 1 (epoch 1) is
    /// stamped stale: at tile 2's turn (the round's third tile) the round
    /// regenerates it from tile 3's committed body. An I/O error inside that
    /// write, or a kill after it; then a fresh open completes the round (tiles
    /// 2 and 3) to the post reference, and a following round equals the twin's.
    func testT2_2RoundStripRegenerationStep() throws {
        for k in [1, 4] {
            for (p, a) in [(TiledWritePoint.regenerateMid, SeamAction.ioError), (.regenerateDone, .kill)] {
                let label = "R0 SYNC K=\(k): \(a.rawValue) at \(p.rawValue)"
                let w = try makeWorlds()
                let h = w.h
                let idA0 = open(h, w.dirA, 4, label), idB0 = open(h, w.dirB, 4, label)
                tickOK(h, idA0, 1, sync: false, label); tickOK(h, idB0, 1, sync: false, label)
                close(h, idA0); close(h, idB0)
                for root in [w.rootA, w.rootB] { try setStripEpoch(root, 3, parity: 1, 5) }
                let idA = open(h, w.dirA, k, label), idB = open(h, w.dirB, k, label)
                let pre = try snapshot(w.dirA)

                let box = SeamBox()
                let ra = try XCTUnwrap(h.tiledRouters[idA]).router
                let s = seam(p, tile: 3, epoch: 1, pass: .round, a, tileDir: try tileDir(w.rootA, 3), box: box)
                try h.runTiledSync { await ra.setWriteSeamForTesting(s) }
                let r = tick(h, idA, 1, sync: true)
                try h.runTiledSync { await ra.setWriteSeamForTesting(nil) }
                XCTAssertEqual(box.fired, 1, "\(label): the seam fired once")
                if a == .ioError {
                    XCTAssertTrue(r.hasPrefix("ERROR io: TILED TICK: ") && r.contains("write step 'halo_lower.1.bin'")
                                  && r.contains("tile 3 epoch 1"), "\(label): the reply names the step: \(r)")
                } else {
                    XCTAssertFalse(r.hasPrefix("OK"), "\(label): \(r)")
                }
                close(h, idA)
                tickOK(h, idB, 1, sync: true, label)
                let post = try snapshot(w.dirB)
                let reopen = h.handle("TILED OPEN \(w.dirA) \(k)")
                XCTAssertTrue(reopen.hasPrefix("OK TILED OPEN id=") && reopen.hasSuffix(" recovered=0 completed=2"),
                              "\(label): \(reopen)")
                let id = token(reopen, "id") ?? "none"
                guard let at = try assertWhole(w, id: id, pre: pre, post: post, label) else { continue }
                XCTAssertEqual(at, .post, label)
                try assertFollowingRound(w, idA: id, idB: idB, at: at, sync: true, label)
            }
        }
    }
}
