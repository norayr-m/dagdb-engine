import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Startup recovery (roadmap item 4): snapshot load before WAL replay so a
/// restart after SAVE needs no operator LOAD; every durable snapshot
/// checkpoints the WAL so the tail is never applied twice.
final class StartupRecoveryTests: XCTestCase {
    private let openLine =
        "STREAM OPEN ref 0x853c49e6748fea9b 0xda3e39cb94b95bdb 0x5851f42d4c957f2d 0x14057b7ef767814f"
    private let recordLine =
        "RECORD OPEN court 1500 0.6827 3000 1.0 0.6827 0.00001 0 0x853c49e6748fea9b 0xda3e39cb94b95bdb 0x5851f42d4c957f2d 0x14057b7ef767814f"

    private var tmpDir: String!
    private var walPath: String { tmpDir + "live.wal" }
    private var snapPath: String { tmpDir + "auto.dags" }

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-startup-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    /// A live daemon: fixture with a WAL appender on `walPath`.
    private func liveFixture(dataRoot: String? = nil) throws -> HandlerFixture {
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 16)
        return try HandlerFixture(side: 4, dataRoot: dataRoot, wal: wal)
    }

    /// The pre-save workload: graph + every non-idempotent twin kind.
    private func workloadBeforeSave(_ h: DagDBCommandHandler) {
        XCTAssertTrue(h.handle("SET 5 TRUTH 1").hasPrefix("OK"))
        XCTAssertTrue(h.handle("TICK").hasPrefix("OK"))
        XCTAssertTrue(h.handle("TICK").hasPrefix("OK"))
        XCTAssertTrue(h.handle(openLine).hasPrefix("OK"))
        XCTAssertTrue(h.handle("STREAM NEXT s00000001 6").hasPrefix("OK"))
        XCTAssertTrue(h.handle(recordLine).hasPrefix("OK"))
        XCTAssertTrue(h.handle("RECORD SLICE t00000001 5").hasPrefix("OK"))
        XCTAssertTrue(h.handle("CLOCK OPEN").hasPrefix("OK"))
        XCTAssertTrue(h.handle("GEAR OPEN c00000001 g 3/7").hasPrefix("OK"))
        XCTAssertTrue(h.handle("CLOCK ADVANCE c00000001 10000").hasPrefix("OK"))
    }

    /// The post-save tail: four WAL records, none of them idempotent.
    private func workloadAfterSave(_ h: DagDBCommandHandler) {
        XCTAssertTrue(h.handle("SET 6 TRUTH 1").hasPrefix("OK"))
        XCTAssertTrue(h.handle("STREAM NEXT s00000001 2").hasPrefix("OK"))
        XCTAssertTrue(h.handle("RECORD SLICE t00000001 7").hasPrefix("OK"))
        XCTAssertTrue(h.handle("CLOCK ADVANCE c00000001 100").hasPrefix("OK"))
    }

    /// What a restarted daemon must reproduce exactly.
    private func observe(_ h: DagDBCommandHandler) -> [String] {
        [
            h.handle("GET 5 TRUTH"),
            h.handle("GET 6 TRUTH"),
            h.handle("STREAM STATE s00000001"),
            h.handle("RECORD INFO t00000001"),
            h.handle("GEAR STATE g00000001"),
            h.handle("CLOCK STATE c00000001"),
            "ticks=\(h.tickCount) twin_open=\(h.twin.totalOpen)",
        ]
    }

    /// The daemon's startup sequence over a fresh fixture (main.swift order).
    @discardableResult
    private func restart(_ f: HandlerFixture, snapshot: String?, wal: String?,
                         dataRoot: String? = nil, log: ((String) -> Void)? = nil) throws -> DagDBStartup.Result {
        let r = try DagDBStartup.recover(
            engine: f.handler.engine, nodeCount: 16, width: 4, height: 4,
            dagdbEnv: nil, dataRoot: dataRoot,
            twin: f.handler.twin, truthRankIndex: f.handler.truthRankIndex,
            snapshotPath: snapshot, walPath: wal,
            log: log ?? { _ in }
        )
        f.handler.tickCount = r.tickCount
        return r
    }

    // MARK: - the gate: restart after SAVE, no LOAD

    func testRestartAfterSaveRestoresGraphAndTwinWithoutLoad() throws {
        let live = try liveFixture()
        workloadBeforeSave(live.handler)
        XCTAssertTrue(live.handler.handle("SAVE \(snapPath)").hasPrefix("OK SAVE"))
        workloadAfterSave(live.handler)
        let expected = observe(live.handler)
        XCTAssertTrue(expected[2].contains("draws=8"), expected[2])
        XCTAssertEqual(expected[6], "ticks=2 twin_open=4")

        let fresh = try HandlerFixture(side: 4)
        let r = try restart(fresh, snapshot: snapPath, wal: walPath)
        XCTAssertNotNil(r.snapshot)
        XCTAssertEqual(r.snapshot?.fileTicks, 2)
        XCTAssertEqual(r.replay?.recordsAfterCheckpoint, 4, "exactly the post-SAVE tail")
        XCTAssertNil(r.replayError)
        XCTAssertEqual(observe(fresh.handler), expected)

        // The restored stream continues the identical sequence.
        guard var a = live.handler.twin.streams.get("s00000001"),
              var b = fresh.handler.twin.streams.get("s00000001") else {
            return XCTFail("stream missing after restart")
        }
        XCTAssertEqual(a.next64(), b.next64())
    }

    // MARK: - opt-in and absence

    func testRecoverWithNothingConfiguredIsANoOp() throws {
        let fresh = try HandlerFixture(side: 4)
        let r = try restart(fresh, snapshot: nil, wal: nil)
        XCTAssertNil(r.snapshot); XCTAssertNil(r.replay); XCTAssertNil(r.replayError)
        XCTAssertEqual(r.tickCount, 0)
        XCTAssertEqual(fresh.handler.twin.totalOpen, 0)
    }

    func testMissingSnapshotFileStartsEmptyAndReplaysWholeWal() throws {
        let live = try liveFixture()
        workloadBeforeSave(live.handler)
        workloadAfterSave(live.handler)
        let expected = observe(live.handler)

        var lines: [String] = []
        let fresh = try HandlerFixture(side: 4)
        let r = try restart(fresh, snapshot: tmpDir + "never-written.dags", wal: walPath) { lines.append($0) }
        XCTAssertNil(r.snapshot)
        XCTAssertTrue(lines.contains { $0.contains("no snapshot at") }, "\(lines)")
        XCTAssertEqual(r.replay?.checkpointEpoch, 0)
        let got = observe(fresh.handler)
        // TICK is not a WAL record: the tick counter and any truth the
        // kernel recomputed on those ticks (node 5 was injected as 1 and
        // then ticked back to 0 by its LUT) are not recoverable from the log
        // alone. That is exactly why the snapshot load exists; the gate test
        // above shows snapshot + tail reproducing both. Everything the log
        // does carry comes back exactly.
        XCTAssertEqual(got[0], "OK GET node=5 truth=1", "the injected value, un-ticked")
        XCTAssertEqual(expected[0], "OK GET node=5 truth=0", "live: two ticks recomputed it")
        XCTAssertEqual(Array(got[1...5]), Array(expected[1...5]))
        XCTAssertEqual(got[6], "ticks=0 twin_open=4")
    }

    // MARK: - refusals

    func testSnapshotOutsideDataRootIsRejected() throws {
        let root = tmpDir + "root"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let fresh = try HandlerFixture(side: 4)
        XCTAssertThrowsError(try restart(fresh, snapshot: tmpDir + "elsewhere.dags", wal: nil, dataRoot: root)) { e in
            guard case DagDBStartup.StartupError.snapshotPathRejected = e else {
                return XCTFail("wrong error: \(e)")
            }
        }
        XCTAssertThrowsError(try restart(fresh, snapshot: root + "/../x.dags", wal: nil, dataRoot: root))
        // Inside the root and absent: allowed, starts empty.
        XCTAssertNoThrow(try restart(fresh, snapshot: root + "/auto.dags", wal: nil, dataRoot: root))
    }

    func testCorruptSnapshotIsFatalNotSilent() throws {
        try Data("not a snapshot".utf8).write(to: URL(fileURLWithPath: snapPath))
        let fresh = try HandlerFixture(side: 4)
        XCTAssertThrowsError(try restart(fresh, snapshot: snapPath, wal: nil)) { e in
            guard case DagDBStartup.StartupError.snapshotUnreadable = e else {
                return XCTFail("wrong error: \(e)")
            }
        }
    }

    // MARK: - the checkpoint rule (non-idempotent twin records)

    func testDurableSnapshotCheckpointsSoTheTailIsNotAppliedTwice() throws {
        let live = try liveFixture()
        workloadBeforeSave(live.handler)
        // The autosave path on graceful shutdown uses the same helper as SAVE.
        XCTAssertTrue(live.handler.durableSnapshot(path: snapPath).hasPrefix("OK SAVE"))
        let expected = observe(live.handler)

        let fresh = try HandlerFixture(side: 4)
        let r = try restart(fresh, snapshot: snapPath, wal: walPath)
        XCTAssertEqual(r.replay?.recordsAfterCheckpoint, 0, "everything is in the snapshot")
        XCTAssertEqual(observe(fresh.handler), expected)
        XCTAssertTrue(expected[2].contains("draws=6"), expected[2])
        XCTAssertTrue(expected[3].contains("slices=1"), expected[3])
    }

    func testSnapshotOlderThanLastCheckpointWarns() throws {
        let live = try liveFixture()
        workloadBeforeSave(live.handler)
        let older = tmpDir + "older.dags"
        XCTAssertTrue(live.handler.handle("SAVE \(older)").hasPrefix("OK SAVE"))
        XCTAssertTrue(live.handler.handle("TICK").hasPrefix("OK"))
        workloadAfterSave(live.handler)
        XCTAssertTrue(live.handler.handle("SAVE \(snapPath)").hasPrefix("OK SAVE"))

        var lines: [String] = []
        let fresh = try HandlerFixture(side: 4)
        let r = try restart(fresh, snapshot: older, wal: walPath) { lines.append($0) }
        XCTAssertEqual(r.snapshot?.fileTicks, 2)
        XCTAssertEqual(r.replay?.checkpointEpoch, 3)
        XCTAssertTrue(lines.contains { $0.hasPrefix("  WARN: startup snapshot") }, "\(lines)")
    }
}
