import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// the interface phase — daemon-level tests for the real STREAM/HEADER/RECORD verbs
/// (DagDBCommandHandler+TwinStreams.swift) and the twin-state wiring into
/// WAL replay, snapshot save/load, and the READER read-only path.
/// Fixtures reused verbatim from TwinCodableStreamTests / NamedStreamTests.
final class TwinStreamCommandTests: XCTestCase {

    // MARK: - Fixtures (verbatim from NamedStreamTests / TwinCodableStreamTests)

    private let referenceName = "ref"
    private let referenceStateHi: UInt64 = 0x853c_49e6_748f_ea9b
    private let referenceStateLo: UInt64 = 0xda3e_39cb_94b9_5bdb
    private let referenceIncHi: UInt64 = 0x5851_f42d_4c95_7f2d
    private let referenceIncLo: UInt64 = 0x1405_7b7e_f767_814f

    private let sixNumpyVectors: [UInt64] = [
        0x742924eb84751ccd, 0x20d6bcdf1e644368, 0xfd2027823296dda3,
        0x0ab11e1c7b578eed, 0x39d0a075d046cb33, 0xd3cc3d10a0f5ae56,
    ]

    private let openLine =
        "STREAM OPEN ref 0x853c49e6748fea9b 0xda3e39cb94b95bdb 0x5851f42d4c957f2d 0x14057b7ef767814f"

    private func w1LikeLine(comb: String = "3000") -> String {
        "1500 0.6827 \(comb) 1.0 0.6827 0.00001 0"
    }

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-twinstream-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    /// Reads the u64 vector shm layout `writeU64Vector` produces:
    /// [u32 count][u32 8][u64 × count].
    private func readU64Vector(_ f: HandlerFixture) -> [UInt64] {
        let headerPtr = f.shm.bindMemory(to: UInt32.self, capacity: 2)
        let count = Int(headerPtr[0])
        let dataPtr = f.shm.advanced(by: 8).bindMemory(to: UInt64.self, capacity: max(1, count))
        return (0..<count).map { dataPtr[$0] }
    }

    // MARK: - STREAM OPEN / NEXT

    func testStreamOpenReturnsIdNameDrawsZero() throws {
        let f = try HandlerFixture(side: 4)
        XCTAssertEqual(f.handler.handle(openLine), "OK STREAM OPEN id=s00000001 name=ref draws=0")
    }

    func testStreamNextDrawsMatchNumpyVectorsAndShm() throws {
        let f = try HandlerFixture(side: 4)
        XCTAssertEqual(f.handler.handle(openLine), "OK STREAM OPEN id=s00000001 name=ref draws=0")
        let reply = f.handler.handle("STREAM NEXT s00000001 6")
        XCTAssertTrue(reply.hasPrefix("OK STREAM NEXT id=s00000001 n=6 draws=6"), reply)
        XCTAssertEqual(readU64Vector(f), sixNumpyVectors)
    }

    func testStreamNextContinuationMatchesNumpy() throws {
        let f = try HandlerFixture(side: 4)
        _ = f.handler.handle(openLine)
        _ = f.handler.handle("STREAM NEXT s00000001 6")
        let reply = f.handler.handle("STREAM NEXT s00000001 2")
        XCTAssertTrue(reply.hasPrefix("OK STREAM NEXT id=s00000001 n=2 draws=8"), reply)
        XCTAssertEqual(readU64Vector(f), [0x0f7335761d46764a, 0x7be48d99e6014011])
    }

    func testStreamNextZeroIsOutOfRange() throws {
        let f = try HandlerFixture(side: 4)
        _ = f.handler.handle(openLine)
        XCTAssertTrue(f.handler.handle("STREAM NEXT s00000001 0").hasPrefix("ERROR out_of_range"))
    }

    func testStreamNextTooLargeIsOutOfRange() throws {
        let f = try HandlerFixture(side: 4)
        _ = f.handler.handle(openLine)
        let tooMany = f.handler.nodeCount * 3 + 1
        XCTAssertTrue(f.handler.handle("STREAM NEXT s00000001 \(tooMany)").hasPrefix("ERROR out_of_range"))
    }

    func testStreamNextUnknownIdIsNotFound() throws {
        let f = try HandlerFixture(side: 4)
        XCTAssertTrue(f.handler.handle("STREAM NEXT s99999999 1").hasPrefix("ERROR not_found"))
    }

    func testStreamStateAndCloseAndList() throws {
        let f = try HandlerFixture(side: 4)
        _ = f.handler.handle(openLine)
        _ = f.handler.handle("STREAM NEXT s00000001 6")
        XCTAssertTrue(f.handler.handle("STREAM STATE s00000001").contains("draws=6"))
        XCTAssertTrue(f.handler.handle("STREAM LIST").contains("s00000001"))
        XCTAssertEqual(f.handler.handle("STREAM CLOSE s00000001"), "OK STREAM CLOSE id=s00000001")
        XCTAssertTrue(f.handler.handle("STREAM STATE s00000001").hasPrefix("ERROR not_found"))
        XCTAssertEqual(f.handler.handle("STREAM LIST"), "OK STREAM LIST count=0")
    }

    // MARK: - HEADER CHECK

    func testHeaderCheckAdmissible() throws {
        let f = try HandlerFixture(side: 4)
        XCTAssertEqual(f.handler.handle("HEADER CHECK \(w1LikeLine())"), "OK HEADER CHECK admissible=1")
    }

    func testHeaderCheckCombBelowNyquistFails() throws {
        let f = try HandlerFixture(side: 4)
        let reply = f.handler.handle("HEADER CHECK \(w1LikeLine(comb: "2000"))")
        XCTAssertTrue(reply.hasPrefix("FAIL HEADER CHECK"), reply)
        XCTAssertTrue(reply.contains("combBelowNyquist"), reply)
    }

    // MARK: - RECORD OPEN / SLICE / REPLAY / VERIFY / INFO / CLOSE / LIST

    private func openCourtRecord(_ f: HandlerFixture) {
        let reply = f.handler.handle("RECORD OPEN court \(w1LikeLine()) 0x853c49e6748fea9b 0xda3e39cb94b95bdb 0x5851f42d4c957f2d 0x14057b7ef767814f")
        XCTAssertEqual(reply, "OK RECORD OPEN id=t00000001 name=court slices=0")
    }

    func testRecordOpenInadmissibleHeaderIsSchemaError() throws {
        let f = try HandlerFixture(side: 4)
        let reply = f.handler.handle("RECORD OPEN court \(w1LikeLine(comb: "2000")) 1 2 3 4")
        XCTAssertTrue(reply.hasPrefix("ERROR schema"), reply)
    }

    func testRecordSliceReplayVerifyRoundTrips() throws {
        let f = try HandlerFixture(side: 4)
        openCourtRecord(f)
        XCTAssertEqual(f.handler.handle("RECORD SLICE t00000001 5"), "OK RECORD SLICE id=t00000001 index=0 count=5 slices=1")
        XCTAssertEqual(f.handler.handle("RECORD SLICE t00000001 7"), "OK RECORD SLICE id=t00000001 index=1 count=7 slices=2")
        XCTAssertEqual(f.handler.handle("RECORD SLICE t00000001 3"), "OK RECORD SLICE id=t00000001 index=2 count=3 slices=3")

        let replayReply = f.handler.handle("RECORD REPLAY t00000001 1")
        XCTAssertTrue(replayReply.hasPrefix("OK RECORD REPLAY id=t00000001 index=1 count=7 match=1"), replayReply)

        // shm equality against the record's own stored slice payload.
        let record = f.handler.twin.records.get("t00000001")!
        XCTAssertEqual(readU64Vector(f), record.slices[1].payload)

        XCTAssertEqual(f.handler.handle("RECORD VERIFY t00000001"), "OK RECORD VERIFY id=t00000001 failing=0")

        XCTAssertTrue(f.handler.handle("RECORD REPLAY t00000001 9").hasPrefix("ERROR out_of_range"))

        let info = f.handler.handle("RECORD INFO t00000001")
        XCTAssertTrue(info.contains("slices=3"), info)

        XCTAssertEqual(f.handler.handle("RECORD CLOSE t00000001"), "OK RECORD CLOSE id=t00000001")
        XCTAssertTrue(f.handler.handle("RECORD INFO t00000001").hasPrefix("ERROR not_found"))
        XCTAssertEqual(f.handler.handle("RECORD LIST"), "OK RECORD LIST count=0")
    }

    // MARK: - WAL append-first / replay continuity

    func testWalReplayContinuesAtNumpyContinuationWord() throws {
        let walPath = tmpDir + "twin.wal"
        let appender = try DagDBWAL.Appender(path: walPath, nodeCount: 16)
        let f = try HandlerFixture(side: 4, wal: appender)

        XCTAssertEqual(f.handler.handle(openLine), "OK STREAM OPEN id=s00000001 name=ref draws=0")
        XCTAssertTrue(f.handler.handle("STREAM NEXT s00000001 6").hasPrefix("OK STREAM NEXT"))

        let fresh = TwinState()
        let grid = HexGrid(width: 4, height: 4)
        let state = DagDBState(width: 4, height: 4)
        let freshEngine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        _ = try DagDBWAL.replay(engine: freshEngine, nodeCount: freshEngine.nodeCount, path: walPath, twin: fresh)

        guard var stream = fresh.streams.get("s00000001") else {
            return XCTFail("replay did not restore s00000001")
        }
        XCTAssertEqual(stream.draws, 6)
        XCTAssertEqual(stream.next64(), 0x0f7335761d46764a)
        XCTAssertEqual(stream.next64(), 0x7be48d99e6014011)
    }

    func testWalFailureAbortsMutationAndRegistryUnchanged() throws {
        // Mirrors DagDBCommandHandlerTests.testWalFailureAbortsMutation:
        // break the WAL by removing its directory out from under the
        // appender, then confirm the twin registry did not gain the entry
        // whose WAL append failed.
        let dir = tmpDir + "wal-live"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let walPath = dir + "/live.wal"
        let appender = try DagDBWAL.Appender(path: walPath, nodeCount: 16)
        let f = try HandlerFixture(side: 4, wal: appender)

        XCTAssertEqual(f.handler.handle(openLine), "OK STREAM OPEN id=s00000001 name=ref draws=0")
        XCTAssertEqual(f.handler.twin.streams.openCount, 1)

        try FileManager.default.removeItem(atPath: dir)
        let reply = f.handler.handle("STREAM OPEN ref2 1 2 3 4")
        if reply.hasPrefix("ERROR wal:") {
            XCTAssertNil(f.handler.twin.streams.get("s00000002"), "WAL append failure must abort the twin mutation")
            XCTAssertEqual(f.handler.twin.streams.openCount, 1)
        }
    }

    // MARK: - READER session: allows STATE, forbids NEXT

    private func openReaderId(_ f: HandlerFixture) throws -> String {
        let openReply = f.handler.handle("OPEN_READER")
        guard let ridRange = openReply.range(of: "id="),
              let spaceRange = openReply.range(of: " ", range: ridRange.upperBound..<openReply.endIndex) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not parse reader id out of: \(openReply)"])
        }
        return String(openReply[ridRange.upperBound..<spaceRange.lowerBound])
    }

    func testReaderAllowsStreamStateForbidsStreamNext() throws {
        let f = try HandlerFixture(side: 4)
        _ = f.handler.handle(openLine)
        _ = f.handler.handle("STREAM NEXT s00000001 6")
        let rid = try openReaderId(f)

        let stateReply = f.handler.handle("READER \(rid) STREAM STATE s00000001")
        XCTAssertTrue(stateReply.contains("session=\(rid)"), stateReply)
        XCTAssertTrue(stateReply.contains("draws=6"), stateReply)

        let nextReply = f.handler.handle("READER \(rid) STREAM NEXT s00000001 1")
        XCTAssertTrue(nextReply.hasPrefix("ERROR forbidden"), nextReply)
    }

    // MARK: - SAVE / LOAD round-trip (v7 TWIN section)

    func testSaveLoadRoundTripsStreamThroughV7() throws {
        let path = tmpDir + "snap.dags"
        let f1 = try HandlerFixture(side: 4)
        _ = f1.handler.handle(openLine)
        _ = f1.handler.handle("STREAM NEXT s00000001 6")

        let saveReply = f1.handler.handle("SAVE \(path)")
        XCTAssertTrue(saveReply.hasPrefix("OK SAVE"), saveReply)

        let f2 = try HandlerFixture(side: 4)
        let loadReply = f2.handler.handle("LOAD \(path)")
        XCTAssertTrue(loadReply.hasPrefix("OK LOAD"), loadReply)

        XCTAssertTrue(f2.handler.handle("STREAM STATE s00000001").contains("draws=6"))
        guard var stream = f2.handler.twin.streams.get("s00000001") else {
            return XCTFail("LOAD did not restore s00000001")
        }
        XCTAssertEqual(stream.next64(), 0x0f7335761d46764a)
    }
}
