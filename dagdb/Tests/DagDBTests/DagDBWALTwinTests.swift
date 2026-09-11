import XCTest
@testable import DagDB

/// the interface phase — WAL opcodes 0x20–0x2B for twin registry ops: `TwinWALCodec`
/// encode/decode and `DagDBWAL.replay(twin:)`. Fixtures reused verbatim
/// from `TwinRegistryTests` (itself reused from `TwinCodableStreamTests` /
/// `TwinCodableClockRingsTests` / `AlarmFixtureTests`).
final class DagDBWALTwinTests: XCTestCase {
    // MARK: - Fixtures (verbatim from TwinRegistryTests)

    private let referenceName = "ref"
    private let referenceStateHi: UInt64 = 0x853c_49e6_748f_ea9b
    private let referenceStateLo: UInt64 = 0xda3e_39cb_94b9_5bdb
    private let referenceIncHi: UInt64 = 0x5851_f42d_4c95_7f2d
    private let referenceIncLo: UInt64 = 0x1405_7b7e_f767_814f

    private func w1Like() -> StreamHeader {
        StreamHeader(signalBandHz: 1500, tauWindowSec: 0.6827, combRateHz: 3000,
                     firstEchoSec: 1.0, recordWindowSec: 0.6827, stepSec: 1.0 / 24000,
                     clockSyncFloorSec: 0)
    }

    private func ringsSpikes() -> (values: [Float], spikes: [UInt64: Float], total: UInt64) {
        let spikes: [UInt64: Float] = [3: -5.0, 250: 7.5, 500: -9.25, 1200: 4.0]
        let total: UInt64 = 1500
        var values: [Float] = []
        values.reserveCapacity(Int(total))
        for t in 0..<total {
            values.append(spikes[t] ?? (t % 2 == 0 ? 0.01 : -0.01))
        }
        return (values, spikes, total)
    }

    /// Verbatim shape from TwinRegistryTests.writeSyntheticAlarmFixture.
    private func writeSyntheticAlarmFixture(named name: String = "mini.json") throws -> (path: String, sha256: String) {
        func wave(_ base: Float) -> [Float] { [base, base + 1, base + 2, base + 3] }
        func entry(_ cls: String, _ base: Float, ear: String? = nil) -> [String: Any] {
            var e: [String: Any] = [
                "class": cls,
                "a": wave(base), "b": wave(base + 10), "c": wave(base + 20),
            ]
            if let ear = ear { e["liar_ear"] = ear }
            return e
        }
        let obj: [String: Any] = [
            "quiet_1": entry("quiet", 0),
            "quiet_2": entry("quiet", 100),
            "liar_1": entry("liar", 200, ear: "B"),
            "deep_1": entry("deep", 300),
            "drift_1": entry("drift", 400),
            "cal0_1": entry("cal0", 500),
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        let path = tmpDir + name
        try data.write(to: URL(fileURLWithPath: path))
        return (path, DagDBSnapshot.sha256Hex(data))
    }

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-waltwin-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    private func makeEngine(side: Int) throws -> DagDBEngine {
        let grid = HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        return try DagDBEngine(grid: grid, state: state, maxRank: 8)
    }

    // MARK: - Codec round trip, all 12 ops

    func testCodecRoundTripsAllTwelveOps() throws {
        let sealed = SealedCourt.makeLayout()
        XCTAssertEqual(sealed.cost.count, 4, "sanity: sealed layout is the 4-pocket table")
        XCTAssertEqual(sealed.cost[0].count, 8, "sanity: sealed layout is the 8-tier table (4x8)")

        let longPath = String(repeating: "p", count: 300)
        let sha = String(repeating: "f", count: 64)

        let ops: [TwinOp] = [
            .streamOpen(id: "s00000001", name: referenceName, stateHi: referenceStateHi,
                        stateLo: referenceStateLo, incHi: referenceIncHi, incLo: referenceIncLo),
            .streamState(id: "s00000001", stateHi: referenceStateHi, stateLo: referenceStateLo, draws: 6),
            .recordOpen(id: "t00000001", name: referenceName, header: w1Like(),
                        stateHi: referenceStateHi, stateLo: referenceStateLo,
                        incHi: referenceIncHi, incLo: referenceIncLo),
            .recordSlice(id: "t00000001", count: 7),
            .ringsOpen(id: "n00000001", gear: 6, rings: 4, cells: 8),
            .ringsWrite(id: "n00000001", values: [1.5, -2.25, 0.0, 3.75, -0.0]),
            .clockOpen(id: "c00000001"),
            .clockAdvance(id: "c00000001", count: 10_000, value: 0.5),
            .gearOpen(id: "g00000001", clockId: "c00000001", name: "g", num: 3, den: 7),
            .layoutOpen(id: "b00000001", cost: sealed.cost, minTier: sealed.minTier),
            .alarmLoad(id: "a00000001", path: longPath, sha256: sha),
            .close(id: "s00000001"),
        ]
        XCTAssertEqual(ops.count, 12, "sanity: exactly the 12 TwinOp cases")

        for op in ops {
            let (opcode, payload) = TwinWALCodec.encode(op)
            let decoded = TwinWALCodec.decode(opcode: opcode.rawValue, payload: payload)
            XCTAssertEqual(decoded, op, "round trip mismatch for \(op)")
        }
    }

    func testCodecDecodeRejectsTruncatedPayload() {
        let (opcode, payload) = TwinWALCodec.encode(.clockOpen(id: "c00000001"))
        let truncated = payload.prefix(payload.count - 1)
        XCTAssertNil(TwinWALCodec.decode(opcode: opcode.rawValue, payload: Data(truncated)))
    }

    func testCodecDecodeRejectsTrailingBytes() {
        let (opcode, payload) = TwinWALCodec.encode(.clockOpen(id: "c00000001"))
        var extended = payload
        extended.append(0xFF)
        XCTAssertNil(TwinWALCodec.decode(opcode: opcode.rawValue, payload: extended))
    }

    func testCodecDecodeRejectsUnknownOpcode() {
        XCTAssertNil(TwinWALCodec.decode(opcode: 0x99, payload: Data()))
    }

    // MARK: - replay(twin:) applies into fresh state

    func testTwinOpsReplayIntoFreshState() throws {
        let path = tmpDir! + "wal_twin_replay.log"
        let eng = try makeEngine(side: 8)

        let ringsFixture = ringsSpikes()
        let (alarmPath, alarmSha) = try writeSyntheticAlarmFixture()

        let ops: [TwinOp] = [
            .streamOpen(id: "s00000001", name: referenceName, stateHi: referenceStateHi,
                        stateLo: referenceStateLo, incHi: referenceIncHi, incLo: referenceIncLo),
            .streamState(id: "s00000001", stateHi: referenceStateHi, stateLo: referenceStateLo, draws: 6),
            .recordOpen(id: "t00000001", name: referenceName, header: w1Like(),
                        stateHi: referenceStateHi, stateLo: referenceStateLo,
                        incHi: referenceIncHi, incLo: referenceIncLo),
            .recordSlice(id: "t00000001", count: 5),
            .recordSlice(id: "t00000001", count: 7),
            .recordSlice(id: "t00000001", count: 3),
            .ringsOpen(id: "n00000001", gear: 6, rings: 4, cells: 8),
            .ringsWrite(id: "n00000001", values: ringsFixture.values),
            .clockOpen(id: "c00000001"),
            .gearOpen(id: "g00000001", clockId: "c00000001", name: "g", num: 3, den: 7),
            .clockAdvance(id: "c00000001", count: 100, value: 0.5),
            .layoutOpen(id: "b00000001", cost: SealedCourt.makeLayout().cost,
                        minTier: SealedCourt.makeLayout().minTier),
            .alarmLoad(id: "a00000001", path: alarmPath, sha256: alarmSha),
        ]

        // Expected: build directly against a TwinState via apply(), exactly
        // as the daemon's live path (and TwinRegistryTests) do.
        let expected = TwinState()
        for op in ops { try expected.apply(op) }

        // Actual: log every op to the WAL, then replay into a fresh
        // TwinState — this must reach the identical exported snapshot.
        let appender = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
        for op in ops { _ = try appender.twin(op) }

        let engR = try makeEngine(side: 8)
        let actual = TwinState()
        let r = try DagDBWAL.replay(engine: engR, nodeCount: engR.nodeCount, path: path, twin: actual)

        XCTAssertEqual(r.recordsApplied, ops.count)
        XCTAssertEqual(actual.export(), expected.export())
    }

    // MARK: - twin: nil skips the twin opcode range entirely

    func testTwinOpsSkippedWithoutTwinParam() throws {
        let path = tmpDir! + "wal_twin_skip.log"
        let eng = try makeEngine(side: 8)
        let appender = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
        _ = try appender.twin(.streamOpen(id: "s00000001", name: referenceName,
                                           stateHi: referenceStateHi, stateLo: referenceStateLo,
                                           incHi: referenceIncHi, incLo: referenceIncLo))
        _ = try appender.twin(.clockOpen(id: "c00000001"))
        _ = try appender.twin(.close(id: "s00000001"))

        let engR = try makeEngine(side: 8)
        // No `twin:` argument — defaults to nil.
        let r = try DagDBWAL.replay(engine: engR, nodeCount: engR.nodeCount, path: path)

        XCTAssertEqual(r.recordsApplied, 0, "twin ops are not applied without a TwinState")
        XCTAssertNil(r.truncatedAtOffset)
    }

    // MARK: - malformed twin payload is skipped, not fatal

    func testMalformedTwinPayloadSkipped() throws {
        let path = tmpDir! + "wal_twin_malformed.log"
        let eng = try makeEngine(side: 8)
        let appender = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)

        // Hand-written 0x20 (twinStreamOpen) record with a bad internal
        // length: the id-string prefix claims 100 bytes but only 2 are
        // actually present. The outer WAL record framing is well-formed
        // (its own length prefix matches the bytes that follow), so this
        // is NOT a truncated-tail case — it's a payload TwinWALCodec must
        // reject on decode.
        var badPayload = Data()
        badPayload.append(0x64)          // u16 len low byte  = 100
        badPayload.append(0x00)          // u16 len high byte
        badPayload.append(contentsOf: [0x41, 0x42])  // only 2 of the 100 claimed bytes
        _ = try appender.append(opcode: .twinStreamOpen, payload: badPayload)

        // A normal, well-formed record follows — it must still apply.
        _ = try appender.setTruth(node: 9, value: 3)

        let engR = try makeEngine(side: 8)
        let twin = TwinState()
        let r = try DagDBWAL.replay(engine: engR, nodeCount: engR.nodeCount, path: path, twin: twin)

        XCTAssertEqual(r.recordsApplied, 1, "only the SET_TRUTH record counts; the malformed twin record is skipped")
        XCTAssertEqual(twin.totalOpen, 0, "nothing was opened from the malformed record")
        let t = engR.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: engR.nodeCount)
        XCTAssertEqual(t[9], 3, "the record following the malformed one still applies")
    }

    // MARK: - checkpoint boundary applies to twin ops too

    func testTwinOpsRespectCheckpoint() throws {
        let path = tmpDir! + "wal_twin_checkpoint.log"
        let eng = try makeEngine(side: 8)
        let appender = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)

        _ = try appender.twin(.streamOpen(id: "s00000001", name: "before",
                                           stateHi: 1, stateLo: 1, incHi: 1, incLo: 1))
        _ = try appender.checkpoint(epoch: 7)
        _ = try appender.twin(.streamOpen(id: "s00000002", name: "after",
                                           stateHi: 2, stateLo: 2, incHi: 1, incLo: 1))

        let engR = try makeEngine(side: 8)
        let twin = TwinState()
        let r = try DagDBWAL.replay(engine: engR, nodeCount: engR.nodeCount, path: path, twin: twin)

        XCTAssertEqual(r.checkpointEpoch, 7)
        XCTAssertEqual(r.recordsAfterCheckpoint, 1, "only the post-checkpoint streamOpen replays")
        XCTAssertNil(twin.streams.get("s00000001"), "pre-checkpoint op is already in the snapshot — must not replay")
        XCTAssertNotNil(twin.streams.get("s00000002"), "post-checkpoint op must replay")
    }

    // MARK: - truncated tail on a twin record is dropped, not applied

    func testTruncatedTwinTailDropped() throws {
        let path = tmpDir! + "wal_twin_truncated.log"
        let eng = try makeEngine(side: 8)
        do {
            let appender = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
            let n1 = try appender.twin(.clockOpen(id: "c00000001"))
            XCTAssertEqual(n1, 16, "sanity: 4B len + 1B opcode + (2B strlen + 9B id) = 16")
            let n2 = try appender.twin(.clockOpen(id: "c00000002"))
            XCTAssertEqual(n2, 16)
        }
        let fullSize = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int ?? 0
        XCTAssertEqual(fullSize, DagDBWAL.headerSize + 32)

        // Tear the tail: keep the whole first record but only 8 of the
        // second record's 16 bytes.
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let truncTo = DagDBWAL.headerSize + 16 + 8
        try data.subdata(in: 0..<truncTo).write(to: URL(fileURLWithPath: path + ".t"))

        let engR = try makeEngine(side: 8)
        let twin = TwinState()
        let r = try DagDBWAL.replay(engine: engR, nodeCount: engR.nodeCount, path: path + ".t", twin: twin)

        XCTAssertEqual(r.recordsApplied, 1, "only the whole first clockOpen record replays")
        XCTAssertEqual(r.truncatedAtOffset, DagDBWAL.headerSize + 16, "torn record starts right after the first")
        XCTAssertNotNil(twin.clocks.get("c00000001"))
        XCTAssertNil(twin.clocks.get("c00000002"), "torn record does NOT apply")
    }
}
