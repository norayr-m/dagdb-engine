import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// the interface phase — daemon-level tests for the real BANK verbs
/// (DagDBCommandHandler+TwinBank.swift), spec 8's waveform mouth. Every
/// fixture uses `HandlerFixture(side: 64)` — shm capacity 8 + 4096·24 =
/// 98,312 bytes, enough to hold the reference bank's K=160 GENERATE M=5
/// output (20,480 f32 samples = 81,920 bytes) but not its M=7 output
/// (114,696 bytes), which is exactly the boundary GENERATE's out-of-range
/// guard is tested against.
final class TwinBankCommandTests: XCTestCase {

    // MARK: - shm pokes / reads (mirroring TwinBudgetCommandTests)

    private func writeFloats(_ v: [Float], at byteOffset: Int, into f: HandlerFixture) {
        let ptr = f.shm.advanced(by: byteOffset).bindMemory(to: Float.self, capacity: max(1, v.count))
        for (i, x) in v.enumerated() { ptr[i] = x }
    }

    /// Reads the f32 vector shm layout `writeFloatVector` produces:
    /// [u32 count][u32 4][f32 × count].
    private func readFloatVectorOut(_ f: HandlerFixture) -> [Float] {
        let headerPtr = f.shm.bindMemory(to: UInt32.self, capacity: 2)
        let count = Int(headerPtr[0])
        let dataPtr = f.shm.advanced(by: 8).bindMemory(to: Float.self, capacity: max(1, count))
        return (0..<count).map { dataPtr[$0] }
    }

    private func parseField(_ reply: String, _ key: String) -> String? {
        guard let r = reply.range(of: "\(key)=") else { return nil }
        let rest = reply[r.upperBound...]
        let end = rest.firstIndex(of: " ") ?? rest.endIndex
        return String(rest[rest.startIndex..<end])
    }

    /// The same PCG constants used everywhere else in the twin-spec test
    /// suite (TwinStreamCommandTests' `referenceState*`/`referenceInc*`).
    private func referenceGaussians(_ count: Int) -> [Float] {
        var stream = NamedStream(
            name: "ref",
            stateHi: 0x853c_49e6_748f_ea9b, stateLo: 0xda3e_39cb_94b9_5bdb,
            incHi: 0x5851_f42d_4c95_7f2d, incLo: 0x1405_7b7e_f767_814f
        )
        return WaveBank.gaussianNoise(count: count, stream: &stream)
    }

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-twinbank-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - BANK OPEN

    /// The daemon default is now the repaired bank (K=144) — AMENDMENT 2 (d)
    /// amends the earlier K=160 default. This is the same assertion as the
    /// spec-8-mandated `testOpenDefaultIsRepairedBank` below; kept here too
    /// since this test predates that name and exercised the same line.
    func testBankOpenReferenceSpec() throws {
        let f = try HandlerFixture(side: 64)
        let reply = f.handler.handle("BANK OPEN mouth")
        XCTAssertTrue(
            reply.hasPrefix("OK BANK OPEN id=w00000001 name=mouth T=4096 K=144 atoms_bytes=2359296 rank=144 cond="),
            reply
        )
    }

    /// The control (K=160) bank, needed by several tests below that compare
    /// against `WaveBank(spec: .reference)` directly, must now be opened
    /// with its seven numbers plus ALIASED (AMENDMENT 2 (c)/(d)) — the
    /// default over the socket opens the repaired K=144 bank instead.
    private func openControlBank(_ f: HandlerFixture) -> String {
        f.handler.handle("BANK OPEN mouth 4096 3000 60 32 8 6 0.02 ALIASED")
    }

    func testOpenDefaultIsRepairedBank() throws {
        let f = try HandlerFixture(side: 64)
        let reply = f.handler.handle("BANK OPEN mouth")
        XCTAssertTrue(
            reply.hasPrefix("OK BANK OPEN id=w00000001 name=mouth T=4096 K=144 atoms_bytes=2359296 rank=144 cond="),
            reply
        )
    }

    func testOpenControlBankNeedsAliased() throws {
        let f = try HandlerFixture(side: 64)

        let noAliased = f.handler.handle("BANK OPEN mouth 4096 3000 60 32 8 6 0.02")
        XCTAssertTrue(noAliased.hasPrefix("ERROR bad_value"), noAliased)
        XCTAssertTrue(noAliased.contains("Nyquist"), noAliased)

        let f2 = try HandlerFixture(side: 64)
        let aliased = openControlBank(f2)
        XCTAssertTrue(aliased.hasPrefix("OK BANK OPEN"), aliased)
        XCTAssertEqual(parseField(aliased, "K"), "160", aliased)
        XCTAssertEqual(parseField(aliased, "rank"), "146", aliased)
    }

    func testInfoCarriesRankAndCond() throws {
        let f = try HandlerFixture(side: 64)
        _ = f.handler.handle("BANK OPEN mouth")
        let reply = f.handler.handle("BANK INFO w00000001")
        XCTAssertTrue(reply.hasPrefix("OK BANK INFO"), reply)
        XCTAssertEqual(parseField(reply, "rank"), "144", reply)
        XCTAssertNotNil(parseField(reply, "cond"), reply)
    }

    func testBankOpenExplicitSpecK6() throws {
        let f = try HandlerFixture(side: 64)
        let reply = f.handler.handle("BANK OPEN small 64 1000 10 3 0 0 0.02")
        XCTAssertTrue(reply.hasPrefix("OK BANK OPEN"), reply)
        XCTAssertEqual(parseField(reply, "K"), "6", reply)
    }

    func testBankOpenBadSpecIsBadValue() throws {
        let f = try HandlerFixture(side: 64)
        let reply = f.handler.handle("BANK OPEN bad 64 1000 10 0 0 0 0.02")
        XCTAssertTrue(reply.hasPrefix("ERROR bad_value"), reply)
    }

    // MARK: - BANK GENERATE

    func testBankGenerateMatchesDirectCallExactly() throws {
        let f = try HandlerFixture(side: 64)
        _ = openControlBank(f)

        let coefficients = referenceGaussians(160 * 5)
        writeFloats(coefficients, at: 8, into: f)

        let reply = f.handler.handle("BANK GENERATE w00000001 5")
        XCTAssertTrue(reply.hasPrefix("OK BANK GENERATE"), reply)
        XCTAssertEqual(parseField(reply, "samples"), "20480", reply)

        let bank = try WaveBank(spec: .reference)
        let expected = bank.generate(coefficients: coefficients, columns: 5)
        let actual = readFloatVectorOut(f)
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertEqual(actual, expected)
    }

    func testBankGenerateOversizedOutputIsOutOfRange() throws {
        let f = try HandlerFixture(side: 64)
        _ = openControlBank(f)
        let coefficients = referenceGaussians(160 * 7)
        writeFloats(coefficients, at: 8, into: f)

        let reply = f.handler.handle("BANK GENERATE w00000001 7")
        XCTAssertTrue(reply.hasPrefix("ERROR out_of_range"), reply)
    }

    func testBankGenerateUnknownIdIsNotFound() throws {
        let f = try HandlerFixture(side: 64)
        let reply = f.handler.handle("BANK GENERATE w09999999 1")
        XCTAssertTrue(reply.hasPrefix("ERROR not_found: w09999999"), reply)
    }

    // MARK: - BANK FIT

    func testBankFitMatchesDirectCallResidualAndCoefficients() throws {
        let f = try HandlerFixture(side: 64)
        _ = openControlBank(f)

        let probe = WaveBank.referenceProbe(spec: .reference)
        writeFloats(probe, at: 8, into: f)

        let reply = f.handler.handle("BANK FIT w00000001")
        XCTAssertTrue(reply.hasPrefix("OK BANK FIT"), reply)

        let bank = try WaveBank(spec: .reference)
        guard let fit = bank.fit(probe) else { return XCTFail("direct fit() returned nil") }
        XCTAssertEqual(parseField(reply, "residual"), "\(fit.residual)", reply)
        XCTAssertEqual(parseField(reply, "coefficients"), "160", reply)

        let shmCoefficients = readFloatVectorOut(f)
        XCTAssertEqual(shmCoefficients, fit.coefficients)
    }

    /// AMENDMENT 2: G7's residual string-equality refers to the REPAIRED
    /// (default) bank; the control bank's fit is G4's, in the library tests.
    func testBankFitOnDefaultRepairedBankMatchesLibraryStringEqual() throws {
        let f = try HandlerFixture(side: 64)
        let open = f.handler.handle("BANK OPEN mouth")
        XCTAssertTrue(open.hasPrefix("OK BANK OPEN id=w00000001 name=mouth T=4096 K=144"), open)

        let probe = WaveBank.referenceProbe(spec: .referenceNyquistSafe)
        writeFloats(probe, at: 8, into: f)
        let reply = f.handler.handle("BANK FIT w00000001")
        XCTAssertTrue(reply.hasPrefix("OK BANK FIT"), reply)

        let bank = try WaveBank(spec: .referenceNyquistSafe)
        guard let fit = bank.fit(probe) else { return XCTFail("direct fit() returned nil") }
        XCTAssertEqual(parseField(reply, "residual"), "\(fit.residual)", reply)
        XCTAssertEqual(parseField(reply, "coefficients"), "144", reply)
        XCTAssertEqual(readFloatVectorOut(f), fit.coefficients)
    }

    func testBankFitUnknownIdIsNotFound() throws {
        let f = try HandlerFixture(side: 64)
        let reply = f.handler.handle("BANK FIT w09999999")
        XCTAssertTrue(reply.hasPrefix("ERROR not_found: w09999999"), reply)
    }

    // MARK: - BANK NOISE

    func testBankNoiseExpectedAndMeanWithinTolerance() throws {
        let f = try HandlerFixture(side: 64)
        _ = openControlBank(f)

        let reply = f.handler.handle("BANK NOISE w00000001 0 20")
        XCTAssertTrue(reply.hasPrefix("OK BANK NOISE"), reply)
        XCTAssertTrue(reply.contains("expected=0.98027419633488"), reply)

        guard let expectedStr = parseField(reply, "expected"), let expected = Double(expectedStr),
              let meanStr = parseField(reply, "mean"), let mean = Double(meanStr) else {
            return XCTFail("could not parse expected/mean out of: \(reply)")
        }
        XCTAssertEqual(mean, expected, accuracy: 0.008)
    }

    func testBankNoiseCountOutOfRange() throws {
        let f = try HandlerFixture(side: 64)
        _ = f.handler.handle("BANK OPEN mouth")
        XCTAssertTrue(f.handler.handle("BANK NOISE w00000001 0 0").hasPrefix("ERROR out_of_range"))
        XCTAssertTrue(f.handler.handle("BANK NOISE w00000001 0 201").hasPrefix("ERROR out_of_range"))
    }

    // MARK: - BANK BENCH

    func testBankBenchSamplesPerSecondPositive() throws {
        let f = try HandlerFixture(side: 64)
        _ = f.handler.handle("BANK OPEN mouth")

        let reply = f.handler.handle("BANK BENCH w00000001 1000 2")
        XCTAssertTrue(reply.hasPrefix("OK BANK BENCH"), reply)
        guard let spsStr = parseField(reply, "samples_per_s"), let sps = Double(spsStr) else {
            return XCTFail("could not parse samples_per_s out of: \(reply)")
        }
        XCTAssertGreaterThan(sps, 0)
    }

    // MARK: - BANK INFO / LIST / CLOSE

    func testBankInfoFields() throws {
        let f = try HandlerFixture(side: 64)
        _ = openControlBank(f)
        let reply = f.handler.handle("BANK INFO w00000001")
        XCTAssertTrue(reply.hasPrefix("OK BANK INFO"), reply)
        XCTAssertEqual(parseField(reply, "name"), "mouth", reply)
        XCTAssertEqual(parseField(reply, "T"), "4096", reply)
        XCTAssertEqual(parseField(reply, "H"), "32", reply)
        XCTAssertEqual(parseField(reply, "centers"), "8", reply)
        XCTAssertEqual(parseField(reply, "freqs"), "6", reply)
        XCTAssertEqual(parseField(reply, "K"), "160", reply)
        XCTAssertEqual(parseField(reply, "rank"), "146", reply)
    }

    func testBankInfoUnknownIdIsNotFound() throws {
        let f = try HandlerFixture(side: 64)
        XCTAssertTrue(f.handler.handle("BANK INFO w09999999").hasPrefix("ERROR not_found: w09999999"))
    }

    func testBankListCountOne() throws {
        let f = try HandlerFixture(side: 64)
        _ = f.handler.handle("BANK OPEN mouth")
        XCTAssertEqual(f.handler.handle("BANK LIST"), "OK BANK LIST count=1 w00000001")
    }

    func testBankCloseThenListIsEmpty() throws {
        let f = try HandlerFixture(side: 64)
        _ = f.handler.handle("BANK OPEN mouth")
        XCTAssertEqual(f.handler.handle("BANK CLOSE w00000001"), "OK BANK CLOSE id=w00000001")
        XCTAssertEqual(f.handler.handle("BANK LIST"), "OK BANK LIST count=0")
    }

    // MARK: - STATUS twin_open

    func testStatusReflectsOpenBank() throws {
        let f = try HandlerFixture(side: 64)
        _ = f.handler.handle("BANK OPEN mouth")
        XCTAssertTrue(f.handler.handle("STATUS").contains("twin_open=1"))
    }

    // MARK: - READER session: allows FIT/INFO, forbids OPEN/CLOSE

    private func openReaderId(_ f: HandlerFixture) throws -> String {
        let openReply = f.handler.handle("OPEN_READER")
        guard let ridRange = openReply.range(of: "id="),
              let spaceRange = openReply.range(of: " ", range: ridRange.upperBound..<openReply.endIndex) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not parse reader id out of: \(openReply)"])
        }
        return String(openReply[ridRange.upperBound..<spaceRange.lowerBound])
    }

    func testReaderAllowsFitAndInfoForbidsOpenAndClose() throws {
        let f = try HandlerFixture(side: 64)
        _ = f.handler.handle("BANK OPEN mouth")
        let rid = try openReaderId(f)

        let probe = WaveBank.referenceProbe(spec: .reference)
        writeFloats(probe, at: 8, into: f)
        let fitReply = f.handler.handle("READER \(rid) BANK FIT w00000001")
        XCTAssertTrue(fitReply.hasPrefix("OK BANK FIT session=\(rid)"), fitReply)

        let infoReply = f.handler.handle("READER \(rid) BANK INFO w00000001")
        XCTAssertTrue(infoReply.hasPrefix("OK BANK INFO session=\(rid)"), infoReply)

        let openReply = f.handler.handle("READER \(rid) BANK OPEN other")
        XCTAssertTrue(openReply.hasPrefix("ERROR forbidden"), openReply)

        let closeReply = f.handler.handle("READER \(rid) BANK CLOSE w00000001")
        XCTAssertTrue(closeReply.hasPrefix("ERROR forbidden"), closeReply)
    }

    // MARK: - WAL replay restores the bank

    func testWalReplayRestoresBankFitResidualStringEqual() throws {
        let walPath = tmpDir + "twin.wal"
        let appender = try DagDBWAL.Appender(path: walPath, nodeCount: 4096)
        let f = try HandlerFixture(side: 64, wal: appender)

        // Opened via the control-bank ALIASED grammar — the WAL op that was
        // recorded is a plain spec (AMENDMENT 2's aliasing gate is a
        // write-time-only check, per the comment at the OPEN handler);
        // replay must restore it without re-checking aliasing.
        let openReply = openControlBank(f)
        XCTAssertTrue(openReply.hasPrefix("OK BANK OPEN id=w00000001 name=mouth T=4096 K=160 atoms_bytes=2621440"), openReply)

        let probe = WaveBank.referenceProbe(spec: .reference)
        writeFloats(probe, at: 8, into: f)
        let beforeFit = f.handler.handle("BANK FIT w00000001")
        XCTAssertTrue(beforeFit.hasPrefix("OK BANK FIT"), beforeFit)

        let fresh = TwinState()
        let grid = HexGrid(width: 64, height: 64)
        let state = DagDBState(width: 64, height: 64)
        let freshEngine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        _ = try DagDBWAL.replay(engine: freshEngine, nodeCount: freshEngine.nodeCount, path: walPath, twin: fresh)

        guard let restored = fresh.banks.get("w00000001") else {
            return XCTFail("bank w00000001 missing after WAL replay")
        }
        XCTAssertEqual(restored.bank.K, 160)

        let f2 = try HandlerFixture(side: 64, twin: fresh)
        writeFloats(probe, at: 8, into: f2)
        let afterFit = f2.handler.handle("BANK FIT w00000001")
        XCTAssertTrue(afterFit.hasPrefix("OK BANK FIT"), afterFit)

        XCTAssertEqual(parseField(beforeFit, "residual"), parseField(afterFit, "residual"))

        let afterInfo = f2.handler.handle("BANK INFO w00000001")
        XCTAssertEqual(parseField(afterInfo, "K"), "160", afterInfo)
    }

    // MARK: - SAVE / LOAD round-trip (v7 TWIN section)

    func testSaveLoadRoundTripsBankThroughV7() throws {
        let path = tmpDir + "snap.dags"
        let f1 = try HandlerFixture(side: 64)
        let openReply = openControlBank(f1)
        XCTAssertTrue(openReply.hasPrefix("OK BANK OPEN id=w00000001 name=mouth T=4096 K=160 atoms_bytes=2621440"), openReply)

        let saveReply = f1.handler.handle("SAVE \(path)")
        XCTAssertTrue(saveReply.hasPrefix("OK SAVE"), saveReply)

        let f2 = try HandlerFixture(side: 64)
        let loadReply = f2.handler.handle("LOAD \(path)")
        XCTAssertTrue(loadReply.hasPrefix("OK LOAD"), loadReply)

        let infoReply = f2.handler.handle("BANK INFO w00000001")
        XCTAssertTrue(infoReply.hasPrefix("OK BANK INFO"), infoReply)
        XCTAssertEqual(parseField(infoReply, "name"), "mouth", infoReply)
        XCTAssertEqual(parseField(infoReply, "K"), "160", infoReply)
    }
}
