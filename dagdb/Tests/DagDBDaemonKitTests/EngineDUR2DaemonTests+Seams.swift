import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// The durable snapshot's step-boundary cells, the forced checkpoint
/// failure and the older disk shape, through the
/// handler's seams: `durableSnapshotStopForTesting` abandons the durable
/// snapshot at a step boundary and writes nothing more (the in-process kill:
/// the files a restart reads are as a kill -9 there leaves them, but for the
/// `<path>.tmp` a real kill would leave and recovery never reads);
/// `checkpointAppendFailureForTesting` makes the checkpoint append throw.
/// Every caller of `durableSnapshot`: the SAVE verb, the autosave (main.swift
/// calls `durableSnapshot(path:)` on graceful shutdown) and the rebase
/// after LOAD.
extension EngineDUR2DaemonTests {

    enum Caller: String, CaseIterable {
        case save = "SAVE"
        case autosave = "autosave"
        case load = "LOAD rebase"
    }

    typealias Step = DagDBCommandHandler.DurableSnapshotStep

    /// The steps before the rename: a kill there leaves the old snapshot.
    static let beforeRename: Set<Step> = [.beforeWrite, .tmpWritten, .bindAppended]

    func run(_ c: Caller, _ live: Live) -> String {
        switch c {
        case .save: return live.h.handle("SAVE \(snapPath)")
        case .autosave: return live.h.durableSnapshot(path: snapPath)
        case .load: return live.h.handle("LOAD \(loadPath)")
        }
    }

    struct Cell {
        var reply: String
        var pre: Observation
        var post: Observation
        var rec: Recovery
        var label: String
    }

    /// One cell: the base, the records before, the pre reference, the caller
    /// under the seams, the records after (when it replied), then a restart.
    func cell(_ c: Caller, ternary: Bool, seed: UInt64, stopAt: Step?, checkpointFails: Bool = false,
              thenPost: Bool, loadEqualsBase: Bool = false) throws -> Cell {
        let label = "\(c.rawValue) \(ternary ? "ternary" : "binary") \(stopAt?.rawValue ?? (checkpointFails ? "checkpoint_fails" : "full"))"
            + (loadEqualsBase ? " (source = the startup snapshot's bytes)" : "")
        let live = try liveBase(ternary: ternary, seed: seed, loadEqualsBase: loadEqualsBase)
        preRecords(live)
        let pre = try recoverFromCopy(live.twin, "pre")
        if let s = stopAt { live.h.durableSnapshotStopForTesting = { $0 == s } }
        if checkpointFails {
            live.h.checkpointAppendFailureForTesting = DagDBWAL.WALError.ioFailure("checkpoint append refused (DUR2.2 seam)")
        }
        let reply = run(c, live)
        live.h.durableSnapshotStopForTesting = nil
        live.h.checkpointAppendFailureForTesting = nil
        if thenPost { postRecords(live) }
        let post = try observe(live.f, live.twin, "post")
        let rec = try recover(snapshot: snapPath, wal: walPath, live.twin, "rec")
        let preObs = try XCTUnwrap(pre.obs, "\(label): pre recovery failed: \(pre.error ?? "")")
        return Cell(reply: reply, pre: preObs, post: post, rec: rec, label: label)
    }

    func line(_ x: Cell) -> String {
        let r = x.rec.result?.replay
        let got = x.rec.obs
        let vsPre = got.map { mismatch(x.pre, $0) }, vsPost = got.map { mismatch(x.post, $0) }
        return "\(x.label): reply=\(x.reply.prefix(150)) rec=\(got == nil ? "FAILED \(x.rec.error ?? "")" : "ok") "
            + "vs_pre=\(vsPre.map { $0.isEmpty ? "equal" : "\($0)" } ?? "-") vs_post=\(vsPost.map { $0.isEmpty ? "equal" : "\($0)" } ?? "-") "
            + "bound=\(r?.boundAtOffset.map(String.init) ?? "nil") replayed=\(r?.recordsAfterCheckpoint ?? -1) epoch=\(r?.checkpointEpoch ?? 0)"
    }

    // MARK: - A kill at every step boundary, every caller

    /// Killed at a step boundary (never replied): recovery equals the pre
    /// state or the post state, byte-equal, never a mixture — the pre state
    /// before the rename, the post state from the rename on.
    func testDUR21AKillAtEveryStepBoundaryRecoversPreOrPost() throws {
        var cells = 0, pres = 0, posts = 0
        for (k, c) in Caller.allCases.enumerated() {
            for step in Step.allCases {
                for ternary in [false, true] {
                    let x = try cell(c, ternary: ternary, seed: 0xD210 + UInt64(k * 100) + (ternary ? 1 : 0),
                                     stopAt: step, thenPost: false)
                    print("DUR2.1 \(line(x))")
                    XCTAssertTrue(x.reply.contains("durable snapshot stopped at \(step.rawValue)"),
                                  "\(x.label): the seam did not fire: \(x.reply)")
                    XCTAssertNotEqual(mismatch(x.pre, x.post), [], "\(x.label): pre and post must differ")
                    guard let got = x.rec.obs else {
                        XCTFail("\(x.label): recovery failed: \(x.rec.error ?? "")"); continue
                    }
                    let isPre = mismatch(x.pre, got).isEmpty, isPost = mismatch(x.post, got).isEmpty
                    XCTAssertTrue(isPre || isPost,
                                  "\(x.label): a mixture: vs pre \(mismatch(x.pre, got)), vs post \(mismatch(x.post, got))")
                    if Self.beforeRename.contains(step) {
                        XCTAssertTrue(isPre, "\(x.label): before the rename the old snapshot stands")
                    } else {
                        XCTAssertTrue(isPost, "\(x.label): from the rename on the new snapshot stands")
                    }
                    cells += 1; pres += isPre ? 1 : 0; posts += isPost ? 1 : 0
                }
            }
        }
        print("DUR2.1 cells=\(cells) pre=\(pres) post=\(posts)")
        XCTAssertEqual(cells, Caller.allCases.count * Step.allCases.count * 2)
    }

    /// The LOAD's source is byte-equal to the startup snapshot, so the old
    /// file and the rebase's new one have one digest and two bind records
    /// carry it: the base's (before the records the LOAD discarded) and the
    /// rebase's. Killed at the bind record (before the rename), the live
    /// state is the loaded one, which the old file also holds; recovery must
    /// start after the LAST bind record carrying the digest (the post state);
    /// the first would replay the discarded records (the pre state, which is
    /// not what the daemon held). Killed later, the same.
    func testDUR21ASnapshotEqualToAnOlderOneIsBoundToTheLastRecord() throws {
        var cells = 0
        for step in [Step.bindAppended, .renamed, .checkpointSynced] {
            for ternary in [false, true] {
                let x = try cell(.load, ternary: ternary, seed: 0xD250 + (ternary ? 1 : 0), stopAt: step,
                                 thenPost: false, loadEqualsBase: true)
                print("DUR2.1 \(line(x))")
                XCTAssertNotEqual(mismatch(x.pre, x.post), [], "\(x.label): pre and post must differ")
                guard let got = x.rec.obs else {
                    XCTFail("\(x.label): recovery failed: \(x.rec.error ?? "")"); continue
                }
                XCTAssertEqual(mismatch(x.post, got), [], "\(x.label): not the last bind record")
                cells += 1
            }
        }
        XCTAssertEqual(cells, 6)
    }

    /// Replied OK (no seam): the reply is a plain OK, and recovery after the
    /// records that follow equals live — from the snapshot's own bind record.
    func testDUR21RepliedOKRecoversThePostStateAndTheTail() throws {
        var cells = 0
        for (k, c) in Caller.allCases.enumerated() {
            for ternary in [false, true] {
                let x = try cell(c, ternary: ternary, seed: 0xD220 + UInt64(k * 100) + (ternary ? 1 : 0),
                                 stopAt: nil, thenPost: true)
                print("DUR2.1 \(line(x))")
                XCTAssertTrue(Self.isPlainOK(x.reply), "\(x.label): \(x.reply)")
                if c == .load { XCTAssertTrue(Reply.withoutVolatile(x.reply).hasSuffix(" wal_base=\"\(snapPath)\""), "\(x.label): \(x.reply)") }
                guard let got = x.rec.obs else {
                    XCTFail("\(x.label): recovery failed: \(x.rec.error ?? "")"); continue
                }
                XCTAssertEqual(mismatch(x.post, got), [], "\(x.label): replied OK, recovered != live")
                XCTAssertNotNil(x.rec.result?.replay?.boundAtOffset, "\(x.label): replay not bound to the snapshot")
                XCTAssertTrue(x.rec.lines.contains { $0.contains("snapshot's own bind record") }, "\(x.rec.lines)")
                cells += 1
            }
        }
        XCTAssertEqual(cells, 6)
    }

    // MARK: - The checkpoint append fails

    /// The checkpoint append throws: the reply names it (not a plain OK), the
    /// records after it are logged, and recovery equals live — the snapshot
    /// is bound by its own record, no checkpoint needed.
    func testDUR22ACheckpointAppendFailureIsNamedAndRecovers() throws {
        var cells = 0
        for (k, c) in Caller.allCases.enumerated() {
            for ternary in [false, true] {
                let x = try cell(c, ternary: ternary, seed: 0xD230 + UInt64(k * 100) + (ternary ? 1 : 0),
                                 stopAt: nil, checkpointFails: true, thenPost: true)
                print("DUR2.2 \(line(x))")
                XCTAssertFalse(Self.isPlainOK(x.reply), "\(x.label): a failed checkpoint must be named: \(x.reply)")
                XCTAssertTrue(x.reply.contains("WARN wal: checkpoint not written (io: checkpoint append refused (DUR2.2 seam))"),
                              "\(x.label): \(x.reply)")
                XCTAssertTrue(x.reply.hasPrefix(c == .load ? "OK LOAD" : "OK SAVE"), "\(x.label): \(x.reply)")
                if c == .load { XCTAssertTrue(x.reply.contains(" wal_base=\"\(snapPath)\" WARN wal:"), "\(x.label): \(x.reply)") }
                guard let got = x.rec.obs else {
                    XCTFail("\(x.label): recovery failed: \(x.rec.error ?? "")"); continue
                }
                XCTAssertEqual(mismatch(x.post, got), [], "\(x.label): recovered != live after a failed checkpoint")
                XCTAssertNotNil(x.rec.result?.replay?.boundAtOffset, x.label)
                cells += 1
            }
        }
        XCTAssertEqual(cells, 6)
    }

    // MARK: - The disk an older daemon left

    /// A snapshot and a log with no bind record (an older SAVE: the file,
    /// then a checkpoint): recovery takes the last checkpoint, as before.
    func testDUR23APreDUR2SnapshotAndLogRecoverByTheCheckpoint() throws {
        for ternary in [false, true] {
            try? FileManager.default.removeItem(atPath: walPath)
            let live = Live(try fixture(wal: true))
            let f = live.f
            try E1.buildGraph(f.handler.engine, seed: 0xD240 + (ternary ? 1 : 0), ternary: ternary)
            f.handler.engine.markRankTopologyDirty()
            lutsBulk(f) { UInt64($0 % 4) }
            live.twin.s = id(ok(f, Self.streamLine))
            live.twin.t = id(ok(f, Self.recordLine))
            live.twin.r = id(ok(f, "RINGS OPEN 6 4 8"))
            live.twin.c = id(ok(f, "CLOCK OPEN"))
            preRecords(live)
            _ = try DagDBSnapshot.save(engine: f.handler.engine, nodeCount: Self.n, gridW: Self.side, gridH: Self.side,
                                       tickCount: f.handler.tickCount, path: snapPath, daemonEnv: .from(envString: nil),
                                       twin: f.handler.twin)
            try XCTUnwrap(f.handler.walAppender).checkpoint(epoch: UInt64(f.handler.tickCount))
            postRecords(live)
            let post = try observe(f, live.twin, "post")
            let rec = try recover(snapshot: snapPath, wal: walPath, live.twin, "rec")
            let got = try XCTUnwrap(rec.obs, rec.error ?? "")
            let r = try XCTUnwrap(rec.result?.replay)
            print("DUR2.3 pre-DUR2 shape \(ternary ? "ternary" : "binary"): bind_records=\(r.bindRecords) bound=\(r.boundAtOffset.map(String.init) ?? "nil") replayed=\(r.recordsAfterCheckpoint) epoch=\(r.checkpointEpoch) mismatch=\(mismatch(post, got))")
            XCTAssertEqual(r.bindRecords, 0)
            XCTAssertNil(r.boundAtOffset)
            XCTAssertEqual(r.recordsAfterCheckpoint, 7, "the post records, by the checkpoint")
            XCTAssertEqual(mismatch(post, got), [])
        }
    }
}
