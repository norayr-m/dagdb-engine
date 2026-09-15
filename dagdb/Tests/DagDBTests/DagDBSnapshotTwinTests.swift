import XCTest
@testable import DagDB

/// the interface phase — Snapshot v7 TWIN section: a length-prefixed, Codable
/// `TwinState.Snapshot` between the WGTS lane section and the ENVS
/// trailer. Fixtures mirror `TwinRegistryTests` (T5) and the v6
/// `DagDBSnapshotTests` / `DagDBWeightLaneTests` byte-accounting shape.
final class DagDBSnapshotTwinTests: XCTestCase {

    // MARK: - Fixtures (verbatim from TwinRegistryTests / TwinCodableStreamTests)

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

    /// Verbatim shape from GearedRingsTests / TwinCodableClockRingsTests.
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

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-snaptwin-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    /// Build a tiny engine and return it along with its grid dims. Verbatim
    /// shape from DagDBSnapshotTests — these tests don't care about engine
    /// buffer content, only about the TWIN section riding alongside it.
    private func makeEngine(side: Int) throws -> (DagDBEngine, Int, Int) {
        let grid = try HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        return (engine, side, side)
    }

    /// Verbatim shape from TwinRegistryTests.writeSyntheticFixture — writes
    /// the file and returns (path, sha256Hex of its bytes).
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

    /// Populate every one of the seven twin registries: a stream advanced
    /// 6 draws, a 3-slice record, geared rings after 1500 writes, a
    /// clock+gear pair, the sealed budget layout, and an alarm set loaded
    /// by reference from a synthetic fixture file. Returns the stream id
    /// (for the continuation check) and the alarm fixture's path (for the
    /// missing-file test).
    @discardableResult
    private func populateTwin(_ twin: TwinState) throws -> (streamId: String, alarmPath: String) {
        let streamId = twin.nextId(prefix: "s")
        try twin.apply(.streamOpen(id: streamId, name: referenceName,
                                    stateHi: referenceStateHi, stateLo: referenceStateLo,
                                    incHi: referenceIncHi, incLo: referenceIncLo))
        try twin.streams.update(streamId) { s in
            for _ in 0..<6 { _ = s.next64() }
        }
        let advanced = twin.streams.get(streamId)!
        try twin.apply(.streamState(id: streamId, stateHi: advanced.stateWords.hi,
                                     stateLo: advanced.stateWords.lo, draws: advanced.draws))

        let recId = twin.nextId(prefix: "t")
        try twin.apply(.recordOpen(id: recId, name: referenceName, header: w1Like(),
                                    stateHi: referenceStateHi, stateLo: referenceStateLo,
                                    incHi: referenceIncHi, incLo: referenceIncLo))
        try twin.apply(.recordSlice(id: recId, count: 5))
        try twin.apply(.recordSlice(id: recId, count: 7))
        try twin.apply(.recordSlice(id: recId, count: 3))

        let ringsId = twin.nextId(prefix: "n")
        try twin.apply(.ringsOpen(id: ringsId, gear: 6, rings: 4, cells: 8))
        let (values, _, _) = ringsSpikes()
        try twin.apply(.ringsWrite(id: ringsId, values: values))

        let clockId = twin.nextId(prefix: "c")
        try twin.apply(.clockOpen(id: clockId))
        let gearId = twin.nextId(prefix: "g")
        try twin.apply(.gearOpen(id: gearId, clockId: clockId, name: "g", num: 3, den: 7))
        try twin.apply(.clockAdvance(id: clockId, count: 100, value: 0.5))

        let layoutId = twin.nextId(prefix: "b")
        let sealed = SealedCourt.makeLayout()
        try twin.apply(.layoutOpen(id: layoutId, cost: sealed.cost, minTier: sealed.minTier))

        let (path, sha) = try writeSyntheticAlarmFixture()
        let alarmId = twin.nextId(prefix: "a")
        try twin.apply(.alarmLoad(id: alarmId, path: path, sha256: sha))

        return (streamId, path)
    }

    // MARK: - v7 round trip

    func testV7RoundTripPopulatedTwinState() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        let twin1 = TwinState()
        let (streamId, _) = try populateTwin(twin1)

        let path = tmpDir! + "twin_v7_roundtrip.dags"
        _ = try DagDBSnapshot.save(engine: eng1, nodeCount: eng1.nodeCount,
                                   gridW: gw, gridH: gh, tickCount: 1, path: path,
                                   twin: twin1)

        let (eng2, _, _) = try makeEngine(side: 8)
        let twin2 = TwinState()
        _ = try DagDBSnapshot.load(engine: eng2, nodeCount: eng2.nodeCount,
                                   gridW: gw, gridH: gh, path: path, validate: false, twin: twin2)

        XCTAssertEqual(twin2.export(), twin1.export())

        var restoredStream = twin2.streams.get(streamId)!
        XCTAssertEqual(restoredStream.draws, 6)
        XCTAssertEqual(restoredStream.next64(), 0x0f7335761d46764a)
        XCTAssertEqual(restoredStream.next64(), 0x7be48d99e6014011)
    }

    // MARK: - v7 round trip: bank

    func testV7RoundTripBank() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        let twin1 = TwinState()
        let bankId = twin1.nextId(prefix: "w")
        try twin1.apply(.bankOpen(id: bankId, name: "mouth", spec: .reference))

        let path = tmpDir! + "twin_v7_bank.dags"
        _ = try DagDBSnapshot.save(engine: eng1, nodeCount: eng1.nodeCount,
                                   gridW: gw, gridH: gh, tickCount: 1, path: path,
                                   twin: twin1)

        let (eng2, _, _) = try makeEngine(side: 8)
        let twin2 = TwinState()
        _ = try DagDBSnapshot.load(engine: eng2, nodeCount: eng2.nodeCount,
                                   gridW: gw, gridH: gh, path: path, validate: false, twin: twin2)

        XCTAssertEqual(twin2.export(), twin1.export())

        let probe = WaveBank.referenceProbe(spec: .reference)
        let residual1 = "\(twin1.banks.get(bankId)!.bank.fit(probe)!.residual)"
        let residual2 = "\(twin2.banks.get(bankId)!.bank.fit(probe)!.residual)"
        XCTAssertEqual(residual1, residual2)
    }

    func testSnapshotJSONWithoutBanksFieldDecodes() throws {
        let twin = TwinState()
        try twin.apply(.clockOpen(id: twin.nextId(prefix: "c")))
        let snap = twin.export()

        let encoder = JSONEncoder()
        let data = try encoder.encode(snap)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(obj["banks"], "sanity: the field is present before we strip it")
        obj.removeValue(forKey: "banks")
        let strippedData = try JSONSerialization.data(withJSONObject: obj)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TwinState.Snapshot.self, from: strippedData)
        XCTAssertEqual(decoded.banks, [:])
        XCTAssertEqual(decoded.counters, snap.counters)
    }

    func testSnapshotJSONWithoutViewsFieldDecodes() throws {
        let twin = TwinState()
        try twin.apply(.clockOpen(id: twin.nextId(prefix: "c")))
        let snap = twin.export()

        let encoder = JSONEncoder()
        let data = try encoder.encode(snap)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(obj["views"], "sanity: the field is present before we strip it")
        obj.removeValue(forKey: "views")
        let strippedData = try JSONSerialization.data(withJSONObject: obj)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TwinState.Snapshot.self, from: strippedData)
        XCTAssertEqual(decoded.views, [:])
        XCTAssertEqual(decoded.counters, snap.counters)
    }

    func testSnapshotJSONWithoutKernelsFieldDecodes() throws {
        let twin = TwinState()
        try twin.apply(.clockOpen(id: twin.nextId(prefix: "c")))
        let snap = twin.export()

        let encoder = JSONEncoder()
        let data = try encoder.encode(snap)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(obj["kernels"], "sanity: the field is present before we strip it")
        obj.removeValue(forKey: "kernels")
        let strippedData = try JSONSerialization.data(withJSONObject: obj)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TwinState.Snapshot.self, from: strippedData)
        XCTAssertEqual(decoded.kernels, [:])
        XCTAssertEqual(decoded.counters, snap.counters)
    }

    func testSnapshotJSONWithoutHooksFieldDecodes() throws {
        let twin = TwinState()
        try twin.apply(.clockOpen(id: twin.nextId(prefix: "c")))
        let snap = twin.export()

        let encoder = JSONEncoder()
        let data = try encoder.encode(snap)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(obj["hooks"], "sanity: the field is present before we strip it")
        obj.removeValue(forKey: "hooks")
        let strippedData = try JSONSerialization.data(withJSONObject: obj)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TwinState.Snapshot.self, from: strippedData)
        XCTAssertEqual(decoded.hooks, [:])
        XCTAssertEqual(decoded.counters, snap.counters)
    }

    // MARK: - v7 round trip: hook (by parameters and frame counter)

    func testV7RoundTripHookByParametersAndT() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        let twin1 = TwinState()
        let (path, sha) = try writeSyntheticAlarmFixture()
        let alarmId = twin1.nextId(prefix: "a")
        try twin1.apply(.alarmLoad(id: alarmId, path: path, sha256: sha))

        let hookId = twin1.nextId(prefix: "h")
        let params = AttentionHook.Params(alarmId: alarmId, layoutId: nil, budget: 100_000,
                                           delta: 3, policy: .allocator, clockId: nil)
        try twin1.apply(.hookOpen(id: hookId, params: params))
        try twin1.apply(.hookStep(id: hookId, count: 5))

        let snapPath = tmpDir! + "twin_v7_hook.dags"
        _ = try DagDBSnapshot.save(engine: eng1, nodeCount: eng1.nodeCount,
                                   gridW: gw, gridH: gh, tickCount: 1, path: snapPath,
                                   twin: twin1)

        let (eng2, _, _) = try makeEngine(side: 8)
        let twin2 = TwinState()
        _ = try DagDBSnapshot.load(engine: eng2, nodeCount: eng2.nodeCount,
                                   gridW: gw, gridH: gh, path: snapPath, validate: false, twin: twin2)

        XCTAssertEqual(twin2.export(), twin1.export())
        XCTAssertEqual(twin2.hooks.get(hookId)?.params, params)
        XCTAssertEqual(twin2.hooks.get(hookId)?.hook.t, 5)
        // The ledger is derived, never stored — restore rebuilds it by
        // re-stepping, and it must match the original's exactly.
        XCTAssertEqual(twin2.hooks.get(hookId)?.hook.ledger, twin1.hooks.get(hookId)?.hook.ledger)
        XCTAssertEqual(twin2.hooks.get(hookId)?.hook.result, twin1.hooks.get(hookId)?.hook.result)
    }

    // MARK: - empty section byte accounting

    func testEmptyTwinSectionIsEightBytes() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        let path = tmpDir! + "twin_empty.dags"
        let saved = try DagDBSnapshot.save(engine: eng1, nodeCount: eng1.nodeCount,
                                           gridW: gw, gridH: gh, tickCount: 0, path: path)
        // Audit C test item 74: the guard used to restate, term for term,
        // the sum `save` builds its own return value from — the writer
        // grading its own arithmetic. The independent measurement is the
        // file itself, the pattern `DagDBWALTwinTests` already uses.
        let onDisk = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
        XCTAssertEqual(onDisk, saved.bytesWritten,
                       "the writer's tally must equal the bytes actually on disk")
        // The term-by-term sum is kept BESIDE the stat, as the layout
        // documentation it always was: header(32) + body(42N) + back-edge
        // count(4, no back-edges) + WGTS header(5, default lanes) + TWIN
        // section(8: 4 B magic + 4 B u32 length, empty payload) + ENVS
        // trailer(5).
        XCTAssertEqual(onDisk, 32 + eng1.nodeCount * 42 + 4 + 5 + 8 + 5)
    }

    // MARK: - v6 file resets twin

    func testLoadV6FileResetsTwin() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        let path = tmpDir! + "twin_v6_from_v7.dags"
        _ = try DagDBSnapshot.save(engine: eng1, nodeCount: eng1.nodeCount,
                                   gridW: gw, gridH: gh, tickCount: 0, path: path)

        var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        // Patch the version byte (offset 4, little-endian u32) from 7 to 6.
        XCTAssertEqual(bytes[4], 7)
        bytes[4] = 6
        // Splice out the empty TWIN section (8 bytes: magic + zero length)
        // between the WGTS header and the ENVS trailer, so the remaining
        // bytes are exactly what a real v6 file would have looked like.
        let n = eng1.nodeCount
        let twinStart = 32 + n * 42 + 4 + 5
        bytes.removeSubrange(twinStart..<(twinStart + 8))
        try bytes.write(to: URL(fileURLWithPath: path))

        let (eng2, _, _) = try makeEngine(side: 8)
        let twin = TwinState()
        try twin.apply(.clockOpen(id: twin.nextId(prefix: "c")))
        XCTAssertEqual(twin.totalOpen, 1)

        _ = try DagDBSnapshot.load(engine: eng2, nodeCount: eng2.nodeCount,
                                   gridW: gw, gridH: gh, path: path, validate: false,
                                   verifyManifest: false, twin: twin)
        XCTAssertEqual(twin.totalOpen, 0, "a v6 file (no TWIN section) resets the passed twin state")
    }

    // MARK: - malformed TWIN section hardening

    func testTwinMagicMismatchThrows() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        let twin1 = TwinState()
        try populateTwin(twin1)
        let path = tmpDir! + "twin_bad_magic.dags"
        _ = try DagDBSnapshot.save(engine: eng1, nodeCount: eng1.nodeCount,
                                   gridW: gw, gridH: gh, tickCount: 0, path: path, twin: twin1)

        var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let n = eng1.nodeCount
        let twinStart = 32 + n * 42 + 4 + 5
        bytes[twinStart] ^= 0xFF  // corrupt the first magic byte ('T' → garbage)
        try bytes.write(to: URL(fileURLWithPath: path))

        let (eng2, _, _) = try makeEngine(side: 8)
        let twin2 = TwinState()
        XCTAssertThrowsError(
            try DagDBSnapshot.load(engine: eng2, nodeCount: eng2.nodeCount,
                                   gridW: gw, gridH: gh, path: path, validate: false,
                                   verifyManifest: false, twin: twin2)
        ) { err in
            guard case DagDBSnapshot.SnapError.ioFailure(let msg) = err else {
                XCTFail("expected ioFailure, got \(err)"); return
            }
            XCTAssertTrue(msg.contains("magic mismatch"), msg)
        }
    }

    func testTruncatedTwinSectionThrows() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        let twin1 = TwinState()
        try populateTwin(twin1)
        let path = tmpDir! + "twin_truncated.dags"
        _ = try DagDBSnapshot.save(engine: eng1, nodeCount: eng1.nodeCount,
                                   gridW: gw, gridH: gh, tickCount: 0, path: path, twin: twin1)

        let full = try Data(contentsOf: URL(fileURLWithPath: path))
        let n = eng1.nodeCount
        let twinStart = 32 + n * 42 + 4 + 5
        // Keep the 8-byte TWIN header (magic + the real, large declared
        // length) but chop the file 4 bytes into the JSON payload — well
        // short of the declared length.
        let truncated = full.prefix(twinStart + 8 + 4)
        try truncated.write(to: URL(fileURLWithPath: path))

        let (eng2, _, _) = try makeEngine(side: 8)
        let twin2 = TwinState()
        XCTAssertThrowsError(
            try DagDBSnapshot.load(engine: eng2, nodeCount: eng2.nodeCount,
                                   gridW: gw, gridH: gh, path: path, validate: false,
                                   verifyManifest: false, twin: twin2)
        ) { err in
            guard case DagDBSnapshot.SnapError.ioFailure(let msg) = err else {
                XCTFail("expected ioFailure, got \(err)"); return
            }
            XCTAssertTrue(msg.contains("truncated"), msg)
        }
    }

    // MARK: - twin: nil ignores the section

    func testLoadV7WithoutTwinParamIgnoresSection() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        let twin1 = TwinState()
        try populateTwin(twin1)
        let path = tmpDir! + "twin_ignored.dags"
        let saved = try DagDBSnapshot.save(engine: eng1, nodeCount: eng1.nodeCount,
                                           gridW: gw, gridH: gh, tickCount: 3, path: path,
                                           twin: twin1)

        let (eng2, _, _) = try makeEngine(side: 8)
        // No `twin:` argument — the section's bytes must still be parsed
        // for magic/length (so bytesRead lands on the ENVS trailer
        // correctly) but nothing is decoded or applied anywhere.
        let loaded = try DagDBSnapshot.load(engine: eng2, nodeCount: eng2.nodeCount,
                                            gridW: gw, gridH: gh, path: path, validate: false)
        XCTAssertEqual(loaded.bytesRead, saved.bytesWritten)
        XCTAssertEqual(loaded.fileTicks, 3)
    }

    // MARK: - alarm-by-reference: missing backing file

    func testAlarmRefMissingFileWarnsAndDrops() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        let twin1 = TwinState()
        let (_, alarmPath) = try populateTwin(twin1)
        let path = tmpDir! + "twin_alarm_missing.dags"
        _ = try DagDBSnapshot.save(engine: eng1, nodeCount: eng1.nodeCount,
                                   gridW: gw, gridH: gh, tickCount: 0, path: path, twin: twin1)

        // Remove the alarm fixture's backing file before load — restore
        // must drop that one entry (warn to stderr, interface-phase convention 15) and still
        // succeed for everything else, never refusing the whole load.
        try FileManager.default.removeItem(atPath: alarmPath)

        let (eng2, _, _) = try makeEngine(side: 8)
        let twin2 = TwinState()
        XCTAssertNoThrow(
            try DagDBSnapshot.load(engine: eng2, nodeCount: eng2.nodeCount,
                                   gridW: gw, gridH: gh, path: path, validate: false, twin: twin2)
        )
        XCTAssertEqual(twin2.alarms.openCount, 0, "the missing-file alarm set is dropped")
        XCTAssertGreaterThan(twin2.streams.openCount, 0, "the rest of the twin state still restores")
    }

    // MARK: - view-by-reference: missing backing file

    /// A minimal `CortexFixture` for view-registry plumbing tests.
    /// `CortexFixture.load`'s own asserts (M == 129*54, every class exactly
    /// 54 train frames, FS == 3000, OS == 8, ruling (c)) make a real
    /// npz-backed fixture too heavy to build here — this test isolates the
    /// restore-side WARN-and-drop behavior (the mechanic under test), not
    /// `CortexFixture.load`'s own validation (exercised for real in
    /// TwinViewCommandTests's synthetic-npz tests). See TwinRegistryTests.
    /// stubCortexFixture's doc comment for the same reasoning.
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

    /// Verifier gap (2026-09-10): a view file that EXISTS but whose hash
    /// changed is dropped on restore with a WARN, exactly like a missing one.
    func testViewRefChangedHashWarnsAndDrops() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        let twin1 = TwinState()
        try populateTwin(twin1)
        let viewPath = tmpDir! + "changed_cortex_v4_world.npz"
        let viewId = twin1.nextId(prefix: "v")
        let stub = stubCortexFixture(path: viewPath, sha256: "deadbeef")
        try twin1.apply(.viewLoad(id: viewId, path: viewPath, sha256: "deadbeef"), viewLoader: { _, _ in stub })
        try Data("not the sealed fixture".utf8).write(to: URL(fileURLWithPath: viewPath))

        let path = tmpDir! + "twin_view_changed.dags"
        _ = try DagDBSnapshot.save(engine: eng1, nodeCount: eng1.nodeCount,
                                   gridW: gw, gridH: gh, tickCount: 0, path: path, twin: twin1)
        let (eng2, _, _) = try makeEngine(side: 8)
        let twin2 = TwinState()
        XCTAssertNoThrow(
            try DagDBSnapshot.load(engine: eng2, nodeCount: eng2.nodeCount,
                                   gridW: gw, gridH: gh, path: path, validate: false, twin: twin2)
        )
        XCTAssertEqual(twin2.views.openCount, 0, "the changed-hash view set is dropped")
        XCTAssertGreaterThan(twin2.streams.openCount, 0, "the rest of the twin state still restores")
    }

    func testViewRefMissingFileWarnsAndDrops() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        let twin1 = TwinState()
        try populateTwin(twin1)

        // A view set loaded by reference to a path that is never actually
        // written to disk (a stub loader stands in for CortexFixture.load
        // at populate time, mirroring the alarm test's injected loader —
        // see stubCortexFixture's doc comment). At restore time the
        // DEFAULT viewLoader (real CortexFixture.load) will find nothing
        // there.
        let viewPath = tmpDir! + "missing_cortex_v4_world.npz"
        let viewId = twin1.nextId(prefix: "v")
        let stub = stubCortexFixture(path: viewPath, sha256: "deadbeef")
        try twin1.apply(.viewLoad(id: viewId, path: viewPath, sha256: "deadbeef"), viewLoader: { _, _ in stub })

        let path = tmpDir! + "twin_view_missing.dags"
        _ = try DagDBSnapshot.save(engine: eng1, nodeCount: eng1.nodeCount,
                                   gridW: gw, gridH: gh, tickCount: 0, path: path, twin: twin1)

        let (eng2, _, _) = try makeEngine(side: 8)
        let twin2 = TwinState()
        XCTAssertNoThrow(
            try DagDBSnapshot.load(engine: eng2, nodeCount: eng2.nodeCount,
                                   gridW: gw, gridH: gh, path: path, validate: false, twin: twin2)
        )
        XCTAssertEqual(twin2.views.openCount, 0, "the missing-file view set is dropped")
        XCTAssertGreaterThan(twin2.streams.openCount, 0, "the rest of the twin state still restores")
        XCTAssertGreaterThan(twin2.alarms.openCount, 0, "the alarm set (real backing file) still restores")
    }
}
