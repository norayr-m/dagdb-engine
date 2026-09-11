import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Derived-views gate contract — daemon-level tests for the real VIEW verb
/// family (DagDBCommandHandler+TwinView.swift): LOAD/REFLEX/RUNG/CEILING/
/// FEATURES/INFO/LIST/CLOSE. Error-path tests (nonexistent file, outside
/// data root, malformed npz layout) run unconditionally with a synthetic
/// mini-npz written by python3 (numpy present in this environment, same
/// precedent as NpzReaderTests.swift); the sealed-fixture tests replay the
/// real `cortex_v4_world.npz` and skip (XCTSkip) when
/// `DAGDB_CORTEX_V4_FIXTURE` is unset — gate contract:
/// docs/contracts/DERIVED_VIEWS_GATES_FROZEN.md, gate V6 for the reply
/// shapes and V1-V5 for the sealed numbers.
final class TwinViewCommandTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-viewcmd-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - synthetic mini-npz (python3 + numpy, precedent: NpzReaderTests)

    @discardableResult
    private func runPython(_ code: String) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", code]
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// A tiny, well-typed npz with EVERY key `CortexFixture.load` expects,
    /// but M = 8 train frames instead of 129*54 = 6966 — triggers the
    /// contract's ruling (c) refusal ("X_train frame count ... != 129*54")
    /// rather than a missing-key or bad-dtype error.
    private func writeSyntheticMiniNpz(in dir: String, named name: String = "mini_cortex.npz") throws -> String {
        let path = dir + name
        let code = """
        import numpy as np
        M = 8
        np.savez(r'\(path)',
                 X_train=np.zeros((M, 8, 64), dtype=np.float32),
                 Y_train=np.zeros((M,), dtype=np.int64),
                 X_test=np.zeros((300, 8, 64), dtype=np.float32),
                 Y_test=np.zeros((300,), dtype=np.int64),
                 TAU=np.zeros((129, 8), dtype=np.float64),
                 TAU_raw=np.zeros((129, 8), dtype=np.float64),
                 SCAN=np.arange(8, dtype=np.int64),
                 CAND=np.arange(129, dtype=np.int64),
                 SPEED=np.float64(1500.0),
                 dt=np.float64(1.0 / 24000),
                 OS=np.int64(8),
                 FS=np.float64(3000.0))
        """
        let status = try runPython(code)
        XCTAssertEqual(status, 0, "python3 failed to write synthetic mini npz")
        return path
    }

    /// Reads the f32 vector shm layout `writeFloatVector` produces:
    /// [u32 count][u32 4][f32 x count] (verbatim from TwinBankCommandTests).
    private func readFloatVectorOut(_ f: HandlerFixture) -> [Float] {
        let headerPtr = f.shm.bindMemory(to: UInt32.self, capacity: 2)
        let count = Int(headerPtr[0])
        let dataPtr = f.shm.advanced(by: 8).bindMemory(to: Float.self, capacity: max(1, count))
        return (0..<count).map { dataPtr[$0] }
    }

    // MARK: - VIEW LOAD: errors (unconditional, no fixture needed)

    func testViewLoadNonexistentPathIsIOError() throws {
        let f = try HandlerFixture(side: 10)
        let reply = f.handler.handle("VIEW LOAD /nonexistent.npz")
        XCTAssertTrue(reply.hasPrefix("ERROR io"), reply)
    }

    func testViewLoadPathOutsideDataRootIsIOError() throws {
        let f = try HandlerFixture(side: 10, dataRoot: tmpDir)
        let reply = f.handler.handle("VIEW LOAD /etc/dagdb-view-escape.npz")
        XCTAssertTrue(reply.hasPrefix("ERROR io"), reply)
        XCTAssertTrue(reply.contains("outside DAGDB_DATA_ROOT"), reply)
    }

    func testViewLoadBadLayoutMiniFixtureIsIOError() throws {
        let path = try writeSyntheticMiniNpz(in: tmpDir)
        let f = try HandlerFixture(side: 10, dataRoot: tmpDir)
        let reply = f.handler.handle("VIEW LOAD \(path)")
        XCTAssertTrue(reply.hasPrefix("ERROR io"), reply)
        XCTAssertTrue(reply.contains("129*54") || reply.contains("6966"), reply)
        XCTAssertNil(f.handler.twin.views.get("v00000001"))
    }

    // MARK: - sealed fixture (skipped without DAGDB_CORTEX_V4_FIXTURE)

    private func sealedPathOrSkip() throws -> String {
        guard let path = CortexFixture.envPath else {
            throw XCTSkip("DAGDB_CORTEX_V4_FIXTURE not set — sealed gate skipped")
        }
        return path
    }

    func testSealedViewLoadWrongSHAIsIOErrorContainingMismatch() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 10, dataRoot: root)
        let reply = f.handler.handle("VIEW LOAD \(path) SHA not-a-real-sha")
        XCTAssertTrue(reply.hasPrefix("ERROR io"), reply)
        XCTAssertTrue(reply.contains("sha256 mismatch"), reply)
        XCTAssertNil(f.handler.twin.views.get("v00000001"))
    }

    @discardableResult
    private func loadSealed(_ f: HandlerFixture, path: String) -> String {
        let reply = f.handler.handle("VIEW LOAD \(path) SHA \(CortexFixture.sealedSHA256)")
        XCTAssertTrue(reply.hasPrefix("OK VIEW LOAD id=v00000001"), reply)
        return reply
    }

    func testSealedViewLoadExactOKLine() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 10, dataRoot: root)
        let reply = loadSealed(f, path: path)
        let expected = "OK VIEW LOAD id=v00000001 train=6966 test=300 stations=8 samples=64 " +
            "candidates=129 sha256=\(CortexFixture.sealedSHA256)"
        XCTAssertEqual(reply, expected)
    }

    func testSealedViewReflexS8() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 10, dataRoot: root)
        loadSealed(f, path: path)

        let reply = f.handler.handle("VIEW REFLEX v00000001 8")
        let expected = "OK VIEW REFLEX id=v00000001 S=8 reflex=18 oracle=65 tie_min=1 tie_median=2.0 " +
            "tie_max=23 frames_with_tie=231 near_edge=\(reflexNearEdge(f, id: "v00000001", s: 8))"
        XCTAssertEqual(reply, expected)
    }

    /// Verifier gap (2026-09-10): the interface spot-checked only S = 2 and 8;
    /// V1–V5 are pinned at S = 4 and 6 too.
    func testSealedViewS4AndS6ReflexRungCeiling() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 10, dataRoot: root)
        loadSealed(f, path: path)

        XCTAssertEqual(f.handler.handle("VIEW REFLEX v00000001 4"),
            "OK VIEW REFLEX id=v00000001 S=4 reflex=11 oracle=72 tie_min=1 tie_median=5.0 " +
            "tie_max=129 frames_with_tie=253 near_edge=\(reflexNearEdge(f, id: "v00000001", s: 4))")
        XCTAssertEqual(f.handler.handle("VIEW REFLEX v00000001 6"),
            "OK VIEW REFLEX id=v00000001 S=6 reflex=15 oracle=76 tie_min=1 tie_median=4.0 " +
            "tie_max=129 frames_with_tie=242 near_edge=\(reflexNearEdge(f, id: "v00000001", s: 6))")
        XCTAssertTrue(f.handler.handle("VIEW RUNG v00000001 4").hasPrefix("OK VIEW RUNG id=v00000001 S=4 hits=28 min_margin="))
        XCTAssertTrue(f.handler.handle("VIEW RUNG v00000001 6").hasPrefix("OK VIEW RUNG id=v00000001 S=6 hits=29 min_margin="))
        XCTAssertEqual(f.handler.handle("VIEW CEILING v00000001 4"),
            "OK VIEW CEILING id=v00000001 S=4 identifiable=19 of=129 ceiling=0.147287 exact_twin_pairs=1015 unique=8 groups=11")
        XCTAssertEqual(f.handler.handle("VIEW CEILING v00000001 6"),
            "OK VIEW CEILING id=v00000001 S=6 identifiable=27 of=129 ceiling=0.209302 exact_twin_pairs=711 unique=12 groups=15")
    }

    func testSealedViewReflexS2() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 10, dataRoot: root)
        loadSealed(f, path: path)

        let reply = f.handler.handle("VIEW REFLEX v00000001 2")
        let expected = "OK VIEW REFLEX id=v00000001 S=2 reflex=3 oracle=233 tie_min=52 tie_median=77.0 " +
            "tie_max=129 frames_with_tie=300 near_edge=\(reflexNearEdge(f, id: "v00000001", s: 2))"
        XCTAssertEqual(reply, expected)
    }

    /// `near_edge` is printed-only (contract's V1 honest clause, not
    /// gated) — computed once via the library directly so the exact-line
    /// assertions above don't hardcode a number the contract never sealed.
    private func reflexNearEdge(_ f: HandlerFixture, id: String, s: Int) -> Int {
        f.handler.twin.views.get(id)!.views.reflexSummary(stations: s).nearEdgeTotal
    }

    func testSealedViewRungS8() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 10, dataRoot: root)
        loadSealed(f, path: path)

        let reply = f.handler.handle("VIEW RUNG v00000001 8")
        XCTAssertTrue(reply.hasPrefix("OK VIEW RUNG id=v00000001 S=8 hits=39"), reply)
    }

    func testSealedViewCeilingS8() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 10, dataRoot: root)
        loadSealed(f, path: path)

        let reply = f.handler.handle("VIEW CEILING v00000001 8")
        let expected = "OK VIEW CEILING id=v00000001 S=8 identifiable=35 of=129 ceiling=0.271318 " +
            "exact_twin_pairs=467 unique=15 groups=20"
        XCTAssertEqual(reply, expected)
    }

    func testSealedViewFeaturesMatchesLibraryComputation() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 10, dataRoot: root)
        loadSealed(f, path: path)

        let set = f.handler.twin.views.get("v00000001")!
        let centroids = set.views.centroids(stations: 8)
        let frame = set.views.fixture.frame(test: 0)
        let feat = DerivedViews.features(frame: frame, stations: 8, fs: set.views.fixture.fs)
        let expected = (0..<feat.count).map { Float((feat[$0] - centroids.mean[$0]) / centroids.std[$0]) }

        let reply = f.handler.handle("VIEW FEATURES v00000001 0 8")
        XCTAssertTrue(reply.hasPrefix("OK VIEW FEATURES id=v00000001 frame=0 S=8 count=24"), reply)

        let got = readFloatVectorOut(f)
        XCTAssertEqual(got.count, 24)
        XCTAssertEqual(got, expected)
    }

    // MARK: - VIEW INFO / LIST / CLOSE

    func testSealedViewInfoListClose() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 10, dataRoot: root)
        loadSealed(f, path: path)

        let info = f.handler.handle("VIEW INFO v00000001")
        XCTAssertTrue(info.contains("id=v00000001"), info)
        XCTAssertTrue(info.contains("path=\(path)"), info)
        XCTAssertTrue(info.contains("sha256=\(CortexFixture.sealedSHA256)"), info)
        XCTAssertTrue(info.contains("train=6966"), info)
        XCTAssertTrue(info.contains("test=300"), info)
        XCTAssertTrue(info.contains("stations=8"), info)
        XCTAssertTrue(info.contains("samples=64"), info)
        XCTAssertTrue(info.contains("candidates=129"), info)

        XCTAssertEqual(f.handler.handle("VIEW LIST"), "OK VIEW LIST count=1 v00000001")

        XCTAssertEqual(f.handler.handle("VIEW CLOSE v00000001"), "OK VIEW CLOSE id=v00000001")
        XCTAssertTrue(f.handler.handle("VIEW INFO v00000001").hasPrefix("ERROR not_found"))
        XCTAssertEqual(f.handler.handle("VIEW LIST"), "OK VIEW LIST count=0")
    }

    // MARK: - out-of-range

    func testSealedViewStationsOutOfRange() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 10, dataRoot: root)
        loadSealed(f, path: path)

        XCTAssertTrue(f.handler.handle("VIEW REFLEX v00000001 9").hasPrefix("ERROR out_of_range"))
        XCTAssertTrue(f.handler.handle("VIEW RUNG v00000001 9").hasPrefix("ERROR out_of_range"))
        XCTAssertTrue(f.handler.handle("VIEW CEILING v00000001 9").hasPrefix("ERROR out_of_range"))
        XCTAssertTrue(f.handler.handle("VIEW FEATURES v00000001 0 9").hasPrefix("ERROR out_of_range"))
    }

    func testSealedViewFrameOutOfRange() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 10, dataRoot: root)
        loadSealed(f, path: path)

        XCTAssertTrue(f.handler.handle("VIEW FEATURES v00000001 300 8").hasPrefix("ERROR out_of_range"))
    }

    func testViewReflexUnknownIdIsNotFound() throws {
        let f = try HandlerFixture(side: 10, dataRoot: tmpDir)
        XCTAssertTrue(f.handler.handle("VIEW REFLEX v00000001 8").hasPrefix("ERROR not_found"))
    }

    // MARK: - STATUS twin_open

    func testSealedStatusReplyCountsView() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 10, dataRoot: root)
        XCTAssertTrue(f.handler.handle("STATUS").contains("twin_open=0"))
        loadSealed(f, path: path)
        XCTAssertTrue(f.handler.handle("STATUS").contains("twin_open=1"))
    }

    // MARK: - READER session: allows REFLEX/INFO, forbids LOAD/CLOSE

    private func openReaderId(_ f: HandlerFixture) throws -> String {
        let openReply = f.handler.handle("OPEN_READER")
        guard let ridRange = openReply.range(of: "id="),
              let spaceRange = openReply.range(of: " ", range: ridRange.upperBound..<openReply.endIndex) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not parse reader id out of: \(openReply)"])
        }
        return String(openReply[ridRange.upperBound..<spaceRange.lowerBound])
    }

    func testSealedReaderSessionAllowsReflexAndInfoForbidsLoadAndClose() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 10, dataRoot: root)
        loadSealed(f, path: path)
        let rid = try openReaderId(f)

        let reflexReply = f.handler.handle("READER \(rid) VIEW REFLEX v00000001 8")
        XCTAssertFalse(reflexReply.hasPrefix("ERROR forbidden"), reflexReply)

        let infoReply = f.handler.handle("READER \(rid) VIEW INFO v00000001")
        XCTAssertFalse(infoReply.hasPrefix("ERROR forbidden"), infoReply)

        let loadReply = f.handler.handle("READER \(rid) VIEW LOAD \(path) SHA \(CortexFixture.sealedSHA256)")
        XCTAssertTrue(loadReply.hasPrefix("ERROR forbidden"), loadReply)

        let closeReply = f.handler.handle("READER \(rid) VIEW CLOSE v00000001")
        XCTAssertTrue(closeReply.hasPrefix("ERROR forbidden"), closeReply)
    }

    // MARK: - SAVE / LOAD round trip by reference

    func testSealedSaveLoadRoundTripsViewByReference() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        // VIEW LOAD needs guardPath to admit the sealed fixture's own
        // directory (`root`, a real fixtures dir outside the repo); SAVE/
        // LOAD need it to admit tmpDir (this test's scratch dir) — no
        // single dataRoot is an ancestor of both, and this test isn't
        // exercising guardPath's restriction, so it runs with no data
        // root at all (guardPath admits any path when dataRoot is nil).
        let f1 = try HandlerFixture(side: 10, dataRoot: nil)
        loadSealed(f1, path: path)

        let snapPath = tmpDir + "snap.dags"
        let saveReply = f1.handler.handle("SAVE \(snapPath)")
        XCTAssertTrue(saveReply.hasPrefix("OK SAVE"), saveReply)

        let f2 = try HandlerFixture(side: 10, dataRoot: nil)
        let loadReply = f2.handler.handle("LOAD \(snapPath)")
        XCTAssertTrue(loadReply.hasPrefix("OK LOAD"), loadReply)

        XCTAssertEqual(f1.handler.handle("VIEW INFO v00000001"), f2.handler.handle("VIEW INFO v00000001"))
        XCTAssertEqual(f1.handler.handle("VIEW REFLEX v00000001 8"), f2.handler.handle("VIEW REFLEX v00000001 8"))
    }

    // MARK: - WAL replay reloads by reference

    func testSealedWalReplayReloadsView() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let walPath = tmpDir + "twin.wal"
        let appender = try DagDBWAL.Appender(path: walPath, nodeCount: 100)
        let f = try HandlerFixture(side: 10, dataRoot: root, wal: appender)

        loadSealed(f, path: path)

        let fresh = TwinState()
        let grid = HexGrid(width: 10, height: 10)
        let state = DagDBState(width: 10, height: 10)
        let freshEngine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        _ = try DagDBWAL.replay(engine: freshEngine, nodeCount: freshEngine.nodeCount, path: walPath, twin: fresh)

        guard let set = fresh.views.get("v00000001") else {
            return XCTFail("replay did not restore v00000001")
        }
        XCTAssertEqual(set.ref.path, path)
        let summary = set.views.reflexSummary(stations: 8)
        XCTAssertEqual(summary.hits, 18)
        XCTAssertEqual(summary.oracleHits, 65)
        XCTAssertEqual(summary.tieMin, 1)
        XCTAssertEqual(summary.tieMedian, 2.0)
        XCTAssertEqual(summary.tieMax, 23)
        XCTAssertEqual(summary.framesWithTie, 231)
    }
}
