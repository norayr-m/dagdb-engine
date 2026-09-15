import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// the interface phase — daemon-level tests for the real RINGS/CLOCK/GEAR verbs
/// (DagDBCommandHandler+TwinClocks.swift). The rings fixture (gear 6,
/// rings 4, cells 8, spikes at ticks 3/250/500/1200 over 1500 ticks) is
/// reused verbatim from GearedRingsTests.testSignedRecallAcrossOrders.
final class TwinClockCommandTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-twinclock-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - Fixture: the sealed GearedRingsTests spikes over 1500 ticks

    private let spikes: [UInt64: Float] = [3: -5.0, 250: 7.5, 500: -9.25, 1200: 4.0]

    private func fixtureValues() -> [Float] {
        (0..<1500).map { t in spikes[UInt64(t)] ?? (t % 2 == 0 ? 0.01 : -0.01) }
    }

    /// Writes the 1500-value fixture to `id` as 15 RINGS WRITE lines of 100
    /// values each, matching the plan's "1500 values via 15 WRITE lines".
    @discardableResult
    private func writeFixture(_ f: HandlerFixture, id: String) -> [String] {
        let values = fixtureValues()
        var replies: [String] = []
        for chunk in stride(from: 0, to: values.count, by: 100) {
            let slice = values[chunk..<(chunk + 100)]
            let line = "RINGS WRITE \(id) " + slice.map { "\($0)" }.joined(separator: " ")
            replies.append(f.handler.handle(line))
        }
        return replies
    }

    // MARK: - RINGS OPEN

    func testRingsOpenReturnsIdAndCapacity() throws {
        let f = try HandlerFixture(side: 4)
        let reply = f.handler.handle("RINGS OPEN 6 4 8")
        XCTAssertEqual(reply, "OK RINGS OPEN id=n00000001 gear=6 rings=4 cells=8 capacity=32", reply)
    }

    func testRingsOpenBadShapeIsBadValue() throws {
        let f = try HandlerFixture(side: 4)
        let reply = f.handler.handle("RINGS OPEN 1 1 1")
        XCTAssertTrue(reply.hasPrefix("ERROR bad_value"), reply)
        // a rejected open never advances the counter: the next successful
        // open still mints n00000001.
        let ok = f.handler.handle("RINGS OPEN 6 4 8")
        XCTAssertEqual(ok, "OK RINGS OPEN id=n00000001 gear=6 rings=4 cells=8 capacity=32", ok)
    }

    // MARK: - RINGS WRITE / RECALL across lags

    func testRingsWriteAndRecallAcrossLags() throws {
        let f = try HandlerFixture(side: 4)
        XCTAssertEqual(f.handler.handle("RINGS OPEN 6 4 8"), "OK RINGS OPEN id=n00000001 gear=6 rings=4 cells=8 capacity=32")

        let writeReplies = writeFixture(f, id: "n00000001")
        XCTAssertEqual(writeReplies.count, 15)
        XCTAssertTrue(writeReplies.first!.hasPrefix("OK RINGS WRITE id=n00000001 n=100"), writeReplies.first!)
        XCTAssertTrue(writeReplies.last!.hasPrefix("OK RINGS WRITE id=n00000001 n=100 now=1500"), writeReplies.last!)

        // lag 1250 -> target tick 250 -> spike 7.5
        let r1250 = f.handler.handle("RINGS RECALL n00000001 1250")
        XCTAssertTrue(r1250.contains("value=7.5"), r1250)
        XCTAssertTrue(r1250.contains("tick=250"), r1250)

        // lag 1497 -> target tick 3 -> spike -5.0
        let r1497 = f.handler.handle("RINGS RECALL n00000001 1497")
        XCTAssertTrue(r1497.contains("value=-5.0"), r1497)
        XCTAssertTrue(r1497.contains("tick=3"), r1497)

        // lag 0 is never recallable
        let r0 = f.handler.handle("RINGS RECALL n00000001 0")
        XCTAssertEqual(r0, "OK RINGS RECALL id=n00000001 lag=0 value=none", r0)
    }

    func testRingsWriteUnknownIdIsNotFound() throws {
        let f = try HandlerFixture(side: 4)
        XCTAssertTrue(f.handler.handle("RINGS WRITE n99999999 1.0").hasPrefix("ERROR not_found"))
    }

    // MARK: - CLOCK OPEN / GEAR OPEN

    func testClockOpenAndGearOpen() throws {
        let f = try HandlerFixture(side: 4)
        XCTAssertEqual(f.handler.handle("CLOCK OPEN"), "OK CLOCK OPEN id=c00000001 tick=0")
        let reply = f.handler.handle("GEAR OPEN c00000001 g 3/7")
        XCTAssertEqual(reply, "OK GEAR OPEN id=g00000001 clock=c00000001 name=g ratio=3/7", reply)
    }

    func testGearOpenUnknownClockIsNotFound() throws {
        let f = try HandlerFixture(side: 4)
        let reply = f.handler.handle("GEAR OPEN c99999999 g 3/7")
        XCTAssertTrue(reply.hasPrefix("ERROR not_found"), reply)
    }

    func testGearOpenZeroRatioIsBadValue() throws {
        let f = try HandlerFixture(side: 4)
        _ = f.handler.handle("CLOCK OPEN")
        let reply = f.handler.handle("GEAR OPEN c00000001 g 0/5")
        XCTAssertTrue(reply.hasPrefix("ERROR bad_value"), reply)
    }

    // MARK: - CLOCK ADVANCE / GEAR STATE fires

    func testClockAdvanceTenThousandGivesExpectedFires() throws {
        let f = try HandlerFixture(side: 4)
        _ = f.handler.handle("CLOCK OPEN")
        _ = f.handler.handle("GEAR OPEN c00000001 g 3/7")
        let advance = f.handler.handle("CLOCK ADVANCE c00000001 10000")
        XCTAssertTrue(advance.hasPrefix("OK CLOCK ADVANCE id=c00000001 n=10000"), advance)
        XCTAssertTrue(advance.contains("gears=1"), advance)
        let state = f.handler.handle("GEAR STATE g00000001")
        XCTAssertTrue(state.contains("fires=4285"), state)
    }

    func testGearLatchExactTickValueAndPhase() throws {
        let f = try HandlerFixture(side: 4)
        _ = f.handler.handle("CLOCK OPEN")
        XCTAssertEqual(f.handler.handle("GEAR OPEN c00000001 g 1/5"), "OK GEAR OPEN id=g00000001 clock=c00000001 name=g ratio=1/5")
        for i in 1...12 {
            let reply = f.handler.handle("CLOCK ADVANCE c00000001 1 VALUE \(i)")
            XCTAssertTrue(reply.hasPrefix("OK CLOCK ADVANCE"), reply)
        }
        let state = f.handler.handle("GEAR STATE g00000001")
        XCTAssertTrue(state.contains("latched_tick=10"), state)
        XCTAssertTrue(state.contains("latched_value=10.0"), state)
        XCTAssertTrue(state.contains("phase=2/5"), state)
    }

    // MARK: - CLOCK CLOSE cascades to gears

    func testClockCloseCascadesGearsAndGearStateNotFoundAfter() throws {
        let f = try HandlerFixture(side: 4)
        _ = f.handler.handle("CLOCK OPEN")
        XCTAssertEqual(f.handler.handle("GEAR OPEN c00000001 g1 3/7"), "OK GEAR OPEN id=g00000001 clock=c00000001 name=g1 ratio=3/7")
        XCTAssertEqual(f.handler.handle("GEAR OPEN c00000001 g2 1/5"), "OK GEAR OPEN id=g00000002 clock=c00000001 name=g2 ratio=1/5")

        let close = f.handler.handle("CLOCK CLOSE c00000001")
        XCTAssertEqual(close, "OK CLOCK CLOSE id=c00000001 gears_closed=2 hooks_closed=0", close)

        XCTAssertTrue(f.handler.handle("GEAR STATE g00000001").hasPrefix("ERROR not_found"))
        XCTAssertTrue(f.handler.handle("GEAR STATE g00000002").hasPrefix("ERROR not_found"))
    }

    // MARK: - WAL append-first / replay continuity

    func testWalReplayReproducesGearFires() throws {
        let walPath = tmpDir + "twinclock.wal"
        let appender = try DagDBWAL.Appender(path: walPath, nodeCount: 16)
        let f = try HandlerFixture(side: 4, wal: appender)

        _ = f.handler.handle("CLOCK OPEN")
        _ = f.handler.handle("GEAR OPEN c00000001 g 3/7")
        XCTAssertTrue(f.handler.handle("CLOCK ADVANCE c00000001 10000").hasPrefix("OK CLOCK ADVANCE"))

        let fresh = TwinState()
        let grid = try HexGrid(width: 4, height: 4)
        let state = DagDBState(width: 4, height: 4)
        let freshEngine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        _ = try DagDBWAL.replay(engine: freshEngine, nodeCount: freshEngine.nodeCount, path: walPath, twin: fresh)

        guard let entry = fresh.gears.get("g00000001") else {
            return XCTFail("replay did not restore g00000001")
        }
        XCTAssertEqual(entry.gear.fires, 4285)
    }

    // MARK: - READER session: allows RECALL/STATE, forbids WRITE/ADVANCE

    private func openReaderId(_ f: HandlerFixture) throws -> String {
        let openReply = f.handler.handle("OPEN_READER")
        guard let ridRange = openReply.range(of: "id="),
              let spaceRange = openReply.range(of: " ", range: ridRange.upperBound..<openReply.endIndex) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not parse reader id out of: \(openReply)"])
        }
        return String(openReply[ridRange.upperBound..<spaceRange.lowerBound])
    }

    func testReaderAllowsRecallAndStateForbidsWriteAndAdvance() throws {
        let f = try HandlerFixture(side: 4)
        XCTAssertEqual(f.handler.handle("RINGS OPEN 6 4 8"), "OK RINGS OPEN id=n00000001 gear=6 rings=4 cells=8 capacity=32")
        XCTAssertTrue(f.handler.handle("RINGS WRITE n00000001 1.0").hasPrefix("OK RINGS WRITE"))
        _ = f.handler.handle("CLOCK OPEN")
        _ = f.handler.handle("GEAR OPEN c00000001 g 3/7")

        let rid = try openReaderId(f)

        let recall = f.handler.handle("READER \(rid) RINGS RECALL n00000001 1")
        XCTAssertFalse(recall.hasPrefix("ERROR forbidden"), recall)
        XCTAssertTrue(recall.contains("session=\(rid)"), recall)

        let clockState = f.handler.handle("READER \(rid) CLOCK STATE c00000001")
        XCTAssertFalse(clockState.hasPrefix("ERROR forbidden"), clockState)
        XCTAssertTrue(clockState.contains("session=\(rid)"), clockState)

        let gearState = f.handler.handle("READER \(rid) GEAR STATE g00000001")
        XCTAssertFalse(gearState.hasPrefix("ERROR forbidden"), gearState)
        XCTAssertTrue(gearState.contains("session=\(rid)"), gearState)

        let write = f.handler.handle("READER \(rid) RINGS WRITE n00000001 2.0")
        XCTAssertTrue(write.hasPrefix("ERROR forbidden"), write)

        let advance = f.handler.handle("READER \(rid) CLOCK ADVANCE c00000001 1")
        XCTAssertTrue(advance.hasPrefix("ERROR forbidden"), advance)
    }
}
