import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Per-path kernel storage and the sealed cross-convolution residual over
/// the socket — daemon-level tests for KERNEL LOAD/INFO/LIST/CLOSE and
/// XCONV SEALED (DagDBCommandHandler+TwinKernel.swift). Gate contract:
/// docs/contracts/KERNELS_GATES_FROZEN.md, gates K3 and K4.
///
/// Unlike VIEW (which gates on an out-of-repo sealed npz), the kernels
/// fixture itself (`Tests/Fixtures/w1_kernels.json`, 144,554 bytes) is
/// IN-REPO and always available — every LOAD/INFO/LIST/CLOSE/replay/
/// snapshot test below runs unconditionally, sha-checked. Only the two
/// residual-vs-190-W1-records tests need `DAGDB_W1_RECORDS` (the 18.5 MB
/// records fixture) and XCTSkip when it's unset — precedent
/// SealedCrossConvolutionTests.
final class TwinKernelCommandTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-kernelcmd-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - Fixture path (in-repo, always present)

    private static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/DagDBDaemonKitTests/
            .deletingLastPathComponent()   // Tests/
            .appendingPathComponent("Fixtures")
    }

    private static let kernelsPath = fixturesDir.appendingPathComponent("w1_kernels.json").path
    private static let kernelsSHA = "2523d3a8a4de44b56268ee31a703b6bcc6522c7c66a305651f8ec7c03e5c56b8"
    private static let tauA = 0.18227148035108542
    private static let tauB = 0.18382585465904366
    private static let sigma = 0.02
    private static let w1RecordsSHA = "ba899eeff82a85b74ce5572d8a5297eee479d9eb4b72b11ea0add2359f633f1a"

    // MARK: - shm helpers

    /// Writes little-endian Float64s into shm at `byteOffset` — the input
    /// half of `XCONV SEALED`'s shm layout (rowSize 8), the mirror of
    /// `readFloatVectorOut` in the sibling command-test files.
    private func writeDoublesIn(_ f: HandlerFixture, _ values: [Double], at byteOffset: Int) {
        let ptr = f.shm.advanced(by: byteOffset).bindMemory(to: Double.self, capacity: max(1, values.count))
        for (i, v) in values.enumerated() { ptr[i] = v }
    }

    // MARK: - KERNEL LOAD helper

    @discardableResult
    private func loadKernel(_ f: HandlerFixture, withTauSigma: Bool = true, sha: String? = TwinKernelCommandTests.kernelsSHA) -> String {
        var cmd = "KERNEL LOAD \(Self.kernelsPath)"
        if let sha = sha { cmd += " SHA \(sha)" }
        if withTauSigma { cmd += " TAU \(Self.tauA) \(Self.tauB) SIGMA \(Self.sigma)" }
        return f.handler.handle(cmd)
    }

    // MARK: - KERNEL LOAD: exact OK line

    func testKernelLoadExactOKLine() throws {
        let f = try HandlerFixture(side: 64, dataRoot: Self.fixturesDir.path)
        let reply = loadKernel(f)
        let expected = "OK KERNEL LOAD id=k00000001 taps=2048 fs=3000 window=2048 ears=170/236 " +
            "warmup=185 derived=1 sha256=\(Self.kernelsSHA)"
        XCTAssertEqual(reply, expected)
    }

    // MARK: - KERNEL LOAD: errors

    func testKernelLoadWrongSHAIsIOError() throws {
        let f = try HandlerFixture(side: 64, dataRoot: Self.fixturesDir.path)
        let wrongSha = String(repeating: "d", count: 64)
        let reply = f.handler.handle("KERNEL LOAD \(Self.kernelsPath) SHA \(wrongSha)")
        XCTAssertTrue(reply.hasPrefix("ERROR io"), reply)
        XCTAssertTrue(reply.contains("sha256 mismatch"), reply)
        XCTAssertNil(f.handler.twin.kernels.get("k00000001"))
    }

    func testKernelLoadMissingFileIsIOError() throws {
        let f = try HandlerFixture(side: 64, dataRoot: Self.fixturesDir.path)
        let reply = f.handler.handle("KERNEL LOAD \(Self.fixturesDir.path)/nonexistent_kernels.json")
        XCTAssertTrue(reply.hasPrefix("ERROR io"), reply)
        XCTAssertNil(f.handler.twin.kernels.get("k00000001"))
    }

    // MARK: - KERNEL LOAD without TAU: no derived warmup

    func testKernelLoadWithoutTauHasNoWarmupAndXConvSealedNeedsExplicitOne() throws {
        let f = try HandlerFixture(side: 64, dataRoot: Self.fixturesDir.path)
        let reply = loadKernel(f, withTauSigma: false)
        XCTAssertTrue(reply.hasPrefix("OK KERNEL LOAD id=k00000001"), reply)
        XCTAssertTrue(reply.contains("warmup=none derived=0"), reply)

        let sealedNoWarmup = f.handler.handle("XCONV SEALED k00000001 2048")
        XCTAssertTrue(sealedNoWarmup.hasPrefix("ERROR bad_value"), sealedNoWarmup)

        let sealedWithWarmup = f.handler.handle("XCONV SEALED k00000001 2048 185")
        XCTAssertTrue(sealedWithWarmup.hasPrefix("OK XCONV SEALED"), sealedWithWarmup)
    }

    // MARK: - XCONV SEALED matches the library directly (a == b synthetic)

    func testXConvSealedMatchesLibraryWhenAEqualsB() throws {
        let f = try HandlerFixture(side: 64, dataRoot: Self.fixturesDir.path)
        loadKernel(f)

        let (pair, _) = try KernelPair.load(path: Self.kernelsPath, expectedSHA256: Self.kernelsSHA)
        let a = pair.kA
        writeDoublesIn(f, a, at: 8)
        writeDoublesIn(f, a, at: 8 + a.count * 8)

        let reply = f.handler.handle("XCONV SEALED k00000001 2048 185")
        let expected = SealedCrossConvolution.residual(a: a, b: a, pair: pair, warmup: 185)
        XCTAssertTrue(reply.hasPrefix("OK XCONV SEALED id=k00000001 n=2048 warmup=185 derived=0 "), reply)
        XCTAssertTrue(reply.contains("residual=\(expected.residual)"), reply)
        XCTAssertTrue(reply.hasSuffix("compared=\(2048 - 185)"), reply)
    }

    // MARK: - too-small shm

    func testXConvSealedTooSmallShmIsOutOfRange() throws {
        // side 4 -> nodeCount 16 -> shmBytes 8 + 16*24 = 392; input needs
        // 8 + 2*2048*8 = 32,776 bytes.
        let f = try HandlerFixture(side: 4, dataRoot: Self.fixturesDir.path)
        loadKernel(f)
        let reply = f.handler.handle("XCONV SEALED k00000001 2048 185")
        XCTAssertTrue(reply.hasPrefix("ERROR out_of_range"), reply)
    }

    func testXConvSealedNMustBeAtLeastTwo() throws {
        let f = try HandlerFixture(side: 64, dataRoot: Self.fixturesDir.path)
        loadKernel(f)
        XCTAssertTrue(f.handler.handle("XCONV SEALED k00000001 1 0").hasPrefix("ERROR"))
    }

    func testXConvSealedWarmupMustBeLessThanN() throws {
        let f = try HandlerFixture(side: 64, dataRoot: Self.fixturesDir.path)
        loadKernel(f)
        let reply = f.handler.handle("XCONV SEALED k00000001 2048 2048")
        XCTAssertTrue(reply.hasPrefix("ERROR out_of_range"), reply)
    }

    func testXConvSealedUnknownIdIsNotFound() throws {
        let f = try HandlerFixture(side: 64, dataRoot: Self.fixturesDir.path)
        XCTAssertTrue(f.handler.handle("XCONV SEALED k00000001 2048 185").hasPrefix("ERROR not_found"))
    }

    // MARK: - KERNEL INFO / LIST / CLOSE

    func testKernelInfoFields() throws {
        let f = try HandlerFixture(side: 64, dataRoot: Self.fixturesDir.path)
        loadKernel(f)
        let info = f.handler.handle("KERNEL INFO k00000001")
        XCTAssertTrue(info.contains("id=k00000001"), info)
        XCTAssertTrue(info.contains("path=\(Self.kernelsPath)"), info)
        XCTAssertTrue(info.contains("sha256=\(Self.kernelsSHA)"), info)
        XCTAssertTrue(info.contains("taps=2048"), info)
        XCTAssertTrue(info.contains("fs=3000"), info)
        XCTAssertTrue(info.contains("window=2048"), info)
        XCTAssertTrue(info.contains("ears=170/236"), info)
        XCTAssertTrue(info.contains("tau_a=\(Self.tauA)"), info)
        XCTAssertTrue(info.contains("tau_b=\(Self.tauB)"), info)
        XCTAssertTrue(info.contains("sigma=\(Self.sigma)"), info)
        XCTAssertTrue(info.contains("warmup=185"), info)
        XCTAssertTrue(info.contains("derived=1"), info)
    }

    func testKernelInfoUnknownIdIsNotFound() throws {
        let f = try HandlerFixture(side: 64, dataRoot: Self.fixturesDir.path)
        XCTAssertTrue(f.handler.handle("KERNEL INFO k00000001").hasPrefix("ERROR not_found"))
    }

    func testKernelListAndClose() throws {
        let f = try HandlerFixture(side: 64, dataRoot: Self.fixturesDir.path)
        loadKernel(f)
        XCTAssertEqual(f.handler.handle("KERNEL LIST"), "OK KERNEL LIST count=1 k00000001")
        XCTAssertEqual(f.handler.handle("KERNEL CLOSE k00000001"), "OK KERNEL CLOSE id=k00000001")
        XCTAssertEqual(f.handler.handle("KERNEL LIST"), "OK KERNEL LIST count=0")
        XCTAssertTrue(f.handler.handle("KERNEL INFO k00000001").hasPrefix("ERROR not_found"))
    }

    // MARK: - STATUS twin_open

    func testStatusReplyCountsKernel() throws {
        let f = try HandlerFixture(side: 64, dataRoot: Self.fixturesDir.path)
        XCTAssertTrue(f.handler.handle("STATUS").contains("twin_open=0"))
        loadKernel(f)
        XCTAssertTrue(f.handler.handle("STATUS").contains("twin_open=1"))
    }

    // MARK: - READER session: allows XCONV SEALED and KERNEL INFO, forbids LOAD/CLOSE

    private func openReaderId(_ f: HandlerFixture) throws -> String {
        let openReply = f.handler.handle("OPEN_READER")
        guard let ridRange = openReply.range(of: "id="),
              let spaceRange = openReply.range(of: " ", range: ridRange.upperBound..<openReply.endIndex) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not parse reader id out of: \(openReply)"])
        }
        return String(openReply[ridRange.upperBound..<spaceRange.lowerBound])
    }

    func testReaderSessionAllowsXConvSealedAndInfoForbidsLoadAndClose() throws {
        let f = try HandlerFixture(side: 64, dataRoot: Self.fixturesDir.path)
        loadKernel(f)
        let (pair, _) = try KernelPair.load(path: Self.kernelsPath, expectedSHA256: Self.kernelsSHA)
        writeDoublesIn(f, pair.kA, at: 8)
        writeDoublesIn(f, pair.kA, at: 8 + pair.kA.count * 8)
        let rid = try openReaderId(f)

        let sealedReply = f.handler.handle("READER \(rid) XCONV SEALED k00000001 2048 185")
        XCTAssertFalse(sealedReply.hasPrefix("ERROR forbidden"), sealedReply)

        let infoReply = f.handler.handle("READER \(rid) KERNEL INFO k00000001")
        XCTAssertFalse(infoReply.hasPrefix("ERROR forbidden"), infoReply)

        let loadReply = f.handler.handle("READER \(rid) KERNEL LOAD \(Self.kernelsPath) SHA \(Self.kernelsSHA)")
        XCTAssertTrue(loadReply.hasPrefix("ERROR forbidden"), loadReply)

        let closeReply = f.handler.handle("READER \(rid) KERNEL CLOSE k00000001")
        XCTAssertTrue(closeReply.hasPrefix("ERROR forbidden"), closeReply)
    }

    // MARK: - WAL replay reloads by reference

    func testWalReplayReloadsKernelByReference() throws {
        let walPath = tmpDir + "twin_kernel.wal"
        let appender = try DagDBWAL.Appender(path: walPath, nodeCount: 100)
        let f = try HandlerFixture(side: 64, dataRoot: Self.fixturesDir.path, wal: appender)
        loadKernel(f)

        let fresh = TwinState()
        let grid = HexGrid(width: 10, height: 10)
        let state = DagDBState(width: 10, height: 10)
        let freshEngine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        _ = try DagDBWAL.replay(engine: freshEngine, nodeCount: freshEngine.nodeCount, path: walPath, twin: fresh)

        guard let set = fresh.kernels.get("k00000001") else {
            return XCTFail("replay did not restore k00000001")
        }
        XCTAssertEqual(set.ref.path, Self.kernelsPath)
        XCTAssertEqual(set.ref.sha256, Self.kernelsSHA)
        XCTAssertEqual(set.pair.taps, 2048)
        XCTAssertEqual(set.pair.derivedWarmup, 185)
    }

    // MARK: - SAVE / LOAD round trip by reference

    func testSaveLoadRoundTripsKernelByReference() throws {
        // KERNEL LOAD needs guardPath to admit the in-repo fixtures dir;
        // SAVE/LOAD need it to admit tmpDir — no single dataRoot is an
        // ancestor of both, so this runs with no data root at all
        // (guardPath admits any path when dataRoot is nil), mirroring
        // TwinViewCommandTests's SAVE/LOAD test.
        let f1 = try HandlerFixture(side: 64, dataRoot: nil)
        let reply = loadKernel(f1)
        XCTAssertTrue(reply.hasPrefix("OK KERNEL LOAD id=k00000001"), reply)

        let snapPath = tmpDir + "snap.dags"
        let saveReply = f1.handler.handle("SAVE \(snapPath)")
        XCTAssertTrue(saveReply.hasPrefix("OK SAVE"), saveReply)

        let f2 = try HandlerFixture(side: 64, dataRoot: nil)
        let loadReply = f2.handler.handle("LOAD \(snapPath)")
        XCTAssertTrue(loadReply.hasPrefix("OK LOAD"), loadReply)

        XCTAssertEqual(f1.handler.handle("KERNEL INFO k00000001"), f2.handler.handle("KERNEL INFO k00000001"))
    }

    // MARK: - changed-hash file dropped on restore, with a WARN

    func testChangedHashKernelFileWarnsAndDropsOnRestore() throws {
        // Copy the in-repo fixture into tmpDir so it can be mutated without
        // touching the real file, load+save by reference, then corrupt the
        // copy and reload into a fresh state — mirrors
        // DagDBSnapshotTwinTests.testViewRefChangedHashWarnsAndDrops.
        let copyPath = tmpDir + "w1_kernels_copy.json"
        try FileManager.default.copyItem(atPath: Self.kernelsPath, toPath: copyPath)

        let f1 = try HandlerFixture(side: 64, dataRoot: nil)
        let loadReply = f1.handler.handle("KERNEL LOAD \(copyPath) SHA \(Self.kernelsSHA)")
        XCTAssertTrue(loadReply.hasPrefix("OK KERNEL LOAD id=k00000001"), loadReply)

        let snapPath = tmpDir + "snap_changed.dags"
        let saveReply = f1.handler.handle("SAVE \(snapPath)")
        XCTAssertTrue(saveReply.hasPrefix("OK SAVE"), saveReply)

        // Corrupt the copy after the reference (path + sha) has been saved.
        var bytes = try Data(contentsOf: URL(fileURLWithPath: copyPath))
        bytes[0] ^= 0xFF
        try bytes.write(to: URL(fileURLWithPath: copyPath))

        let f2 = try HandlerFixture(side: 64, dataRoot: nil)
        let reloadReply = f2.handler.handle("LOAD \(snapPath)")
        XCTAssertTrue(reloadReply.hasPrefix("OK LOAD"), reloadReply)
        XCTAssertEqual(f2.handler.twin.kernels.openCount, 0, "the changed-hash kernel set is dropped")
    }

    // MARK: - Sealed (env DAGDB_W1_RECORDS)

    private struct Trial: Decodable {
        let a: [Double]
        let b: [Double]
    }

    private static var cachedRecords: [String: Trial]?

    private static func loadSealedRecordsOrSkip() throws -> [String: Trial] {
        guard let path = ProcessInfo.processInfo.environment["DAGDB_W1_RECORDS"] else {
            throw XCTSkip("DAGDB_W1_RECORDS not set — sealed XCONV SEALED handler gate skipped")
        }
        if let cached = cachedRecords { return cached }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let actualSHA = DagDBSnapshot.sha256Hex(data)
        guard actualSHA == w1RecordsSHA else {
            XCTFail("DAGDB_W1_RECORDS sha256 mismatch: expected \(w1RecordsSHA), got \(actualSHA)")
            struct SealedHashMismatch: Error {}
            throw SealedHashMismatch()
        }
        let records = try JSONDecoder().decode([String: Trial].self, from: data)
        cachedRecords = records
        return records
    }

    private func assertXConvSealedMatchesLibrary(trial: Trial) throws {
        let f = try HandlerFixture(side: 64, dataRoot: Self.fixturesDir.path)
        loadKernel(f)
        let (pair, _) = try KernelPair.load(path: Self.kernelsPath, expectedSHA256: Self.kernelsSHA)
        writeDoublesIn(f, trial.a, at: 8)
        writeDoublesIn(f, trial.b, at: 8 + trial.a.count * 8)

        let reply = f.handler.handle("XCONV SEALED k00000001 \(trial.a.count) 185")
        let expected = SealedCrossConvolution.residual(a: trial.a, b: trial.b, pair: pair, warmup: 185)
        XCTAssertTrue(reply.contains("residual=\(expected.residual)"), reply)
    }

    func testSealedXConvSealedMatchesLibraryOnCal01() throws {
        let records = try Self.loadSealedRecordsOrSkip()
        guard let trial = records["cal0_1"] else { return XCTFail("no cal0_1 trial in DAGDB_W1_RECORDS") }
        try assertXConvSealedMatchesLibrary(trial: trial)
    }

    func testSealedXConvSealedMatchesLibraryOnCourt1() throws {
        let records = try Self.loadSealedRecordsOrSkip()
        // The worst court trial = the max R among class "court" in w1_residuals_v1.json (court_28).
        guard let trial = records["court_28"] else { return XCTFail("no court_28 trial in DAGDB_W1_RECORDS") }
        try assertXConvSealedMatchesLibrary(trial: trial)
    }
}
