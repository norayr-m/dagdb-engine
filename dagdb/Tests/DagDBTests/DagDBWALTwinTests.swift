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
        let grid = try HexGrid(width: side, height: side)
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
            let (opcode, payload) = try TwinWALCodec.encode(op)
            let decoded = TwinWALCodec.decode(opcode: opcode.rawValue, payload: payload)
            XCTAssertEqual(decoded, op, "round trip mismatch for \(op)")
        }
    }

    func testCodecDecodeRejectsTruncatedPayload() throws {
        let (opcode, payload) = try TwinWALCodec.encode(.clockOpen(id: "c00000001"))
        let truncated = payload.prefix(payload.count - 1)
        XCTAssertNil(TwinWALCodec.decode(opcode: opcode.rawValue, payload: Data(truncated)))
    }

    func testCodecDecodeRejectsTrailingBytes() throws {
        let (opcode, payload) = try TwinWALCodec.encode(.clockOpen(id: "c00000001"))
        var extended = payload
        extended.append(0xFF)
        XCTAssertNil(TwinWALCodec.decode(opcode: opcode.rawValue, payload: extended))
    }

    func testCodecDecodeRejectsUnknownOpcode() {
        XCTAssertNil(TwinWALCodec.decode(opcode: 0x99, payload: Data()))
    }

    // MARK: - bankOpen codec round trip

    func testBankOpenCodecRoundTrip() throws {
        let referenceOp = TwinOp.bankOpen(id: "w00000001", name: "mouth", spec: .reference)
        let (refOpcode, refPayload) = try TwinWALCodec.encode(referenceOp)
        XCTAssertEqual(TwinWALCodec.decode(opcode: refOpcode.rawValue, payload: refPayload), referenceOp)

        let tinySpec = WaveBank.Spec(samples: 64, sampleRate: 3000, f0: 60, harmonics: 3,
                                      gaborCenters: 0, gaborFreqs: 0, gaborSigmaFrac: 0.02)
        let tinyOp = TwinOp.bankOpen(id: "w00000002", name: "tiny", spec: tinySpec)
        let (tinyOpcode, tinyPayload) = try TwinWALCodec.encode(tinyOp)
        XCTAssertEqual(TwinWALCodec.decode(opcode: tinyOpcode.rawValue, payload: tinyPayload), tinyOp)
    }

    // MARK: - viewLoad codec round trip

    /// Verbatim shape from TwinRegistryTests.stubCortexFixture — see its
    /// doc comment for why the memberwise init (reachable via `@testable`)
    /// is used instead of a real npz-backed `CortexFixture.load` here.
    private func stubCortexFixture(path: String = "synthetic", sha256: String = "deadbeef") -> CortexFixture {
        CortexFixture(
            path: path, sha256: sha256,
            stations: 8, samples: 64, candidates: 129,
            xTrain: [], yTrain: [], xTest: [], yTest: [],
            tau: [], tauRaw: [],
            scan: Array(0..<8), cand: Array(0..<129),
            speed: 1500, dt: 1.0 / 24000, os: 8, fs: 3000
        )
    }

    func testViewLoadCodecRoundTrip() throws {
        let op = TwinOp.viewLoad(id: "v00000001", path: "/data/cortex_v4_world.npz",
                                   sha256: String(repeating: "a", count: 64))
        let (opcode, payload) = try TwinWALCodec.encode(op)
        XCTAssertEqual(opcode, .twinViewLoad)
        XCTAssertEqual(TwinWALCodec.decode(opcode: opcode.rawValue, payload: payload), op)
    }

    /// `DagDBWAL.replay(twin:)` applies every twin op with the DEFAULT
    /// loader (no per-op injection point — see `.alarmLoad`'s replay path,
    /// which always re-reads the real fixture file), so a `.viewLoad`
    /// record can't be replayed through the binary WAL without a real npz.
    /// This exercises the same decode-then-apply step replay performs,
    /// but with the loader `TwinState.apply` exposes for exactly this
    /// case: a stub that records the (path, sha) it was called with.
    func testViewLoadReplayDecodeThenApplyWithStubLoader() throws {
        let path = tmpDir! + "wal_view_replay.log"
        let eng = try makeEngine(side: 8)
        let appender = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
        let op = TwinOp.viewLoad(id: "v00000001", path: "/fake/cortex_v4_world.npz", sha256: "deadbeef")
        _ = try appender.twin(op)

        // Confirm the record actually landed on disk (appender.twin wrote
        // it), then decode the SAME encoding replay would walk and apply
        // into a fresh TwinState via the injectable viewLoader, recording
        // what it was called with.
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(data.count, DagDBWAL.headerSize, "sanity: the record was appended")
        let (opcode, payload) = try TwinWALCodec.encode(op)
        let decoded = TwinWALCodec.decode(opcode: opcode.rawValue, payload: payload)
        XCTAssertEqual(decoded, op)

        var recordedPath: String?
        var recordedSha: String?
        let stub = stubCortexFixture(path: "/fake/cortex_v4_world.npz", sha256: "deadbeef")
        let fresh = TwinState()
        try fresh.apply(decoded!, viewLoader: { p, s in
            recordedPath = p
            recordedSha = s
            return stub
        })

        XCTAssertEqual(recordedPath, "/fake/cortex_v4_world.npz")
        XCTAssertEqual(recordedSha, "deadbeef")
        XCTAssertNotNil(fresh.views.get("v00000001"))
        XCTAssertEqual(fresh.views.get("v00000001")?.ref.path, "/fake/cortex_v4_world.npz")
    }

    // MARK: - kernelLoad codec round trip (gates K3/K4)

    func testKernelLoadCodecRoundTripWithOptionals() throws {
        let op = TwinOp.kernelLoad(
            id: "k00000001", path: "/data/w1_kernels.json",
            sha256: String(repeating: "a", count: 64),
            tauA: 0.18227148035108542, tauB: 0.18382585465904366,
            sigmaSource: 0.02, declaredWarmup: 185
        )
        let (opcode, payload) = try TwinWALCodec.encode(op)
        XCTAssertEqual(opcode, .twinKernelLoad)
        XCTAssertEqual(TwinWALCodec.decode(opcode: opcode.rawValue, payload: payload), op)
    }

    func testKernelLoadCodecRoundTripWithoutOptionals() throws {
        let op = TwinOp.kernelLoad(
            id: "k00000002", path: "/data/w1_kernels.json",
            sha256: String(repeating: "b", count: 64),
            tauA: nil, tauB: nil, sigmaSource: nil, declaredWarmup: nil
        )
        let (opcode, payload) = try TwinWALCodec.encode(op)
        XCTAssertEqual(opcode, .twinKernelLoad)
        XCTAssertEqual(TwinWALCodec.decode(opcode: opcode.rawValue, payload: payload), op)
    }

    func testKernelLoadCodecRoundTripWithSomeOptionals() throws {
        // A mix: declaredWarmup only, no TAU/SIGMA — the "WARMUP n given,
        // no TAU/SIGMA" load shape (K4: derived=0).
        let op = TwinOp.kernelLoad(
            id: "k00000003", path: "/x.json", sha256: "deadbeef",
            tauA: nil, tauB: nil, sigmaSource: nil, declaredWarmup: 42
        )
        let (opcode, payload) = try TwinWALCodec.encode(op)
        XCTAssertEqual(TwinWALCodec.decode(opcode: opcode.rawValue, payload: payload), op)
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

    // MARK: - bankOpen replays into fresh state

    func testBankOpenReplaysIntoFreshState() throws {
        let path = tmpDir! + "wal_twin_bankopen_replay.log"
        let eng = try makeEngine(side: 8)

        let appender = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
        _ = try appender.twin(.bankOpen(id: "w00000001", name: "mouth", spec: .reference))

        let engR = try makeEngine(side: 8)
        let actual = TwinState()
        let r = try DagDBWAL.replay(engine: engR, nodeCount: engR.nodeCount, path: path, twin: actual)

        XCTAssertEqual(r.recordsApplied, 1)
        let entry = actual.banks.get("w00000001")
        XCTAssertEqual(entry?.bank.K, 160)

        let directBank = try WaveBank(spec: .reference)
        let probe = WaveBank.referenceProbe(spec: .reference)
        let replayedResidual = "\(entry!.bank.fit(probe)!.residual)"
        let directResidual = "\(directBank.fit(probe)!.residual)"
        XCTAssertEqual(replayedResidual, directResidual)
    }

    // MARK: - twin: nil skips the twin opcode range entirely

    func testBankOpenSkippedWithoutTwinParam() throws {
        let path = tmpDir! + "wal_twin_bankopen_skip.log"
        let eng = try makeEngine(side: 8)
        let appender = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
        _ = try appender.twin(.bankOpen(id: "w00000001", name: "mouth", spec: .reference))

        let engR = try makeEngine(side: 8)
        let r = try DagDBWAL.replay(engine: engR, nodeCount: engR.nodeCount, path: path)

        XCTAssertEqual(r.recordsApplied, 0, "bankOpen is not applied without a TwinState")
        XCTAssertNil(r.truncatedAtOffset)
    }

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

    // MARK: - hookOpen/hookStep codec round trip (HOOK_GATES_FROZEN.md, H3)

    func testHookOpsCodecRoundTrip() throws {
        let withBoth = TwinOp.hookOpen(
            id: "h00000001",
            params: AttentionHook.Params(alarmId: "a00000001", layoutId: "b00000001", budget: 16164.352484758914,
                                          delta: 3, policy: .allocator, clockId: "c00000001"))
        let (opWith, payloadWith) = try TwinWALCodec.encode(withBoth)
        XCTAssertEqual(opWith, .twinHookOpen)
        XCTAssertEqual(TwinWALCodec.decode(opcode: opWith.rawValue, payload: payloadWith), withBoth)

        let withoutEither = TwinOp.hookOpen(
            id: "h00000002",
            params: AttentionHook.Params(alarmId: "a00000001", layoutId: nil, budget: 3128.126645687496,
                                          delta: 3, policy: .uniform, clockId: nil))
        let (opWithout, payloadWithout) = try TwinWALCodec.encode(withoutEither)
        XCTAssertEqual(TwinWALCodec.decode(opcode: opWithout.rawValue, payload: payloadWithout), withoutEither)

        // Every policy byte round trips.
        for policy in AttentionHook.Policy.allCases {
            let op = TwinOp.hookOpen(
                id: "h00000003",
                params: AttentionHook.Params(alarmId: "a00000001", layoutId: nil, budget: 100, delta: 3, policy: policy))
            let (opcode, payload) = try TwinWALCodec.encode(op)
            XCTAssertEqual(TwinWALCodec.decode(opcode: opcode.rawValue, payload: payload), op, "policy \(policy)")
        }

        let step = TwinOp.hookStep(id: "h00000001", count: 203)
        let (stepOpcode, stepPayload) = try TwinWALCodec.encode(step)
        XCTAssertEqual(stepOpcode, .twinHookStep)
        XCTAssertEqual(TwinWALCodec.decode(opcode: stepOpcode.rawValue, payload: stepPayload), step)
    }

    // MARK: - hookOpen/hookStep replay into a fresh state

    func testHookOpsReplayIntoFreshState() throws {
        let path = tmpDir! + "wal_twin_hook_replay.log"
        let eng = try makeEngine(side: 8)
        let (alarmPath, alarmSha) = try writeSyntheticAlarmFixture()

        let hookParams = AttentionHook.Params(alarmId: "a00000001", layoutId: nil, budget: 100_000,
                                               delta: 3, policy: .allocator, clockId: nil)
        let ops: [TwinOp] = [
            .alarmLoad(id: "a00000001", path: alarmPath, sha256: alarmSha),
            .hookOpen(id: "h00000001", params: hookParams),
            .hookStep(id: "h00000001", count: 8),
        ]

        let expected = TwinState()
        for op in ops { try expected.apply(op) }

        let appender = try DagDBWAL.Appender(path: path, nodeCount: eng.nodeCount)
        for op in ops { _ = try appender.twin(op) }

        let engR = try makeEngine(side: 8)
        let actual = TwinState()
        let r = try DagDBWAL.replay(engine: engR, nodeCount: engR.nodeCount, path: path, twin: actual)

        XCTAssertEqual(r.recordsApplied, ops.count)
        XCTAssertTrue(actual.hooks.get("h00000001")!.hook.done)
        XCTAssertEqual(actual.hooks.get("h00000001")!.hook.result, expected.hooks.get("h00000001")!.hook.result)
        XCTAssertEqual(actual.export(), expected.export())
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
