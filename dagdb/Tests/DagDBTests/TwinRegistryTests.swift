import XCTest
@testable import DagDB

/// the interface phase — TwinRegistry (typed-id registries, reader-session pattern) and
/// TwinState (the seven daemon-global registries, TwinOp apply, Codable
/// snapshot). Fixtures are reused verbatim from the earlier
/// test classes and from `SealedCourt`.
final class TwinRegistryTests: XCTestCase {
    // MARK: - Fixtures (verbatim from TwinCodableStreamTests / TwinCodableClockRingsTests)

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
        tmpDir = NSTemporaryDirectory() + "dagdb-twinreg-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    /// Verbatim shape from AlarmFixtureTests.writeSyntheticFixture — writes
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

    /// A minimal `CortexFixture` for VIEW registry tests. `CortexFixture.
    /// load`'s own asserts (M == 129*54, every class exactly 54 train
    /// frames, FS == 3000, OS == 8) make a *real* npz-backed synthetic
    /// fixture heavy to build for tests that only care about registry
    /// mechanics (mint/close/export/restore) — so this uses the struct's
    /// synthesized memberwise init directly (internal access, reachable
    /// here via `@testable import DagDB`) instead of routing through
    /// `CortexFixture.load`. This never bypasses `load`'s own asserts —
    /// those are exercised for real in TwinViewCommandTests's synthetic-npz
    /// tests — it only lets `TwinState.apply`'s *injected* `viewLoader`
    /// hand back a fixture without touching a file at all, the same shape
    /// `AlarmFixture` stub tests would use if `AlarmFixture` had no on-disk
    /// synthetic-JSON precedent already in this file.
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

    // MARK: - TwinRegistry: id format, uniqueness, restore path

    func testOpenMintsPrefixedSequentialIds() throws {
        let reg = TwinRegistry<Int>(prefix: "s")
        let id1 = try reg.open(1)
        let id2 = try reg.open(2)
        XCTAssertEqual(id1, "s00000001")
        XCTAssertEqual(id2, "s00000002")
        XCTAssertEqual(reg.counter, 2)
        XCTAssertEqual(reg.openCount, 2)
        XCTAssertEqual(reg.get(id1), 1)
        XCTAssertEqual(reg.get(id2), 2)
    }

    func testOpenWithIdBumpsCounterAndRejectsBadOrDuplicate() throws {
        let reg = TwinRegistry<Int>(prefix: "t")
        try reg.open(1, id: "t00000005")
        XCTAssertEqual(reg.counter, 5)
        XCTAssertEqual(reg.get("t00000005"), 1)

        // duplicate id
        XCTAssertThrowsError(try reg.open(2, id: "t00000005")) { error in
            guard case TwinRegistry<Int>.RegistryError.duplicateId("t00000005") = error else {
                XCTFail("expected duplicateId, got \(error)"); return
            }
        }
        // wrong prefix
        XCTAssertThrowsError(try reg.open(3, id: "s00000006")) { error in
            guard case TwinRegistry<Int>.RegistryError.badId("s00000006") = error else {
                XCTFail("expected badId, got \(error)"); return
            }
        }
        // not 8 hex digits
        XCTAssertThrowsError(try reg.open(3, id: "t0000006")) { error in
            guard case TwinRegistry<Int>.RegistryError.badId("t0000006") = error else {
                XCTFail("expected badId, got \(error)"); return
            }
        }
        // non-hex digit
        XCTAssertThrowsError(try reg.open(3, id: "t0000000g")) { error in
            guard case TwinRegistry<Int>.RegistryError.badId("t0000000g") = error else {
                XCTFail("expected badId, got \(error)"); return
            }
        }
        // a later live open must not collide with the restored id
        let liveId = try reg.open(4)
        XCTAssertEqual(liveId, "t00000006")
    }

    func testUpdateReplaceCloseUnknownIdThrowNotFound() {
        let reg = TwinRegistry<Int>(prefix: "s")
        XCTAssertThrowsError(try reg.update("s00000001") { $0 += 1 }) { error in
            guard case TwinRegistry<Int>.RegistryError.notFound("s00000001") = error else {
                XCTFail("expected notFound, got \(error)"); return
            }
        }
        XCTAssertThrowsError(try reg.replace("s00000001", with: 9)) { error in
            guard case TwinRegistry<Int>.RegistryError.notFound("s00000001") = error else {
                XCTFail("expected notFound, got \(error)"); return
            }
        }
        XCTAssertFalse(reg.close("s00000001"))
    }

    func testCloseAllAndEntries() throws {
        let reg = TwinRegistry<Int>(prefix: "s")
        let a = try reg.open(1)
        let b = try reg.open(2)
        XCTAssertEqual(Set(reg.ids), Set([a, b]))
        XCTAssertEqual(reg.entries, [a: 1, b: 2])
        reg.closeAll()
        XCTAssertEqual(reg.openCount, 0)
        XCTAssertTrue(reg.ids.isEmpty)
    }

    // MARK: - TwinState: stream

    func testStreamOpenThenStreamStateContinuesSequence() throws {
        let twin = TwinState()
        let id = twin.nextId(prefix: "s")
        try twin.apply(.streamOpen(id: id, name: referenceName,
                                    stateHi: referenceStateHi, stateLo: referenceStateLo,
                                    incHi: referenceIncHi, incLo: referenceIncLo))
        XCTAssertEqual(id, "s00000001")
        XCTAssertEqual(twin.streams.get(id)?.draws, 0)

        // Advance 6 draws directly against the registry (this is what the
        // daemon's STREAM NEXT verb does in T8, before logging the
        // resulting post-state as `.streamState` — O(1) replay).
        try twin.streams.update(id) { s in
            for _ in 0..<6 { _ = s.next64() }
        }
        let advanced = twin.streams.get(id)!
        XCTAssertEqual(advanced.draws, 6)

        try twin.apply(.streamState(id: id, stateHi: advanced.stateWords.hi,
                                     stateLo: advanced.stateWords.lo, draws: advanced.draws))

        var restored = twin.streams.get(id)!
        XCTAssertEqual(restored.draws, 6)
        XCTAssertEqual(restored.next64(), 0x0f7335761d46764a)
        XCTAssertEqual(restored.next64(), 0x7be48d99e6014011)
    }

    func testStreamStateOnMissingIdThrowsNotFound() {
        let twin = TwinState()
        XCTAssertThrowsError(try twin.apply(.streamState(id: "s00000001", stateHi: 0, stateLo: 0, draws: 0))) { error in
            guard case TwinState.TwinError.notFound("s00000001") = error else {
                XCTFail("expected notFound, got \(error)"); return
            }
        }
    }

    // MARK: - TwinState: record

    func testRecordOpenAndSlicesVerify() throws {
        let twin = TwinState()
        let id = twin.nextId(prefix: "t")
        try twin.apply(.recordOpen(id: id, name: referenceName, header: w1Like(),
                                    stateHi: referenceStateHi, stateLo: referenceStateLo,
                                    incHi: referenceIncHi, incLo: referenceIncLo))
        try twin.apply(.recordSlice(id: id, count: 5))
        try twin.apply(.recordSlice(id: id, count: 7))
        try twin.apply(.recordSlice(id: id, count: 3))

        let record = twin.records.get(id)!
        XCTAssertEqual(record.slices.map(\.count), [5, 7, 3])
        XCTAssertTrue(record.verify().isEmpty)
        XCTAssertEqual(record.generatorState.draws, 15)
    }

    func testRecordOpenInadmissibleHeaderThrowsSchema() {
        let twin = TwinState()
        let id = twin.nextId(prefix: "t")
        var badHeader = w1Like()
        badHeader.combRateHz = 100
        XCTAssertThrowsError(try twin.apply(.recordOpen(id: id, name: referenceName, header: badHeader,
                                                          stateHi: referenceStateHi, stateLo: referenceStateLo,
                                                          incHi: referenceIncHi, incLo: referenceIncLo))) { error in
            guard case TwinState.TwinError.schema = error else {
                XCTFail("expected schema, got \(error)"); return
            }
        }
        XCTAssertNil(twin.records.get(id))
    }

    // MARK: - TwinState: rings

    func testRingsOpenAndWriteRecalls() throws {
        let twin = TwinState()
        let id = twin.nextId(prefix: "n")
        try twin.apply(.ringsOpen(id: id, gear: 6, rings: 4, cells: 8))

        let (values, spikes, total) = ringsSpikes()
        try twin.apply(.ringsWrite(id: id, values: values))

        let ring = twin.rings.get(id)!
        for (t, v) in spikes {
            let recall = ring.recall(lag: total - t)
            XCTAssertEqual(recall?.value, v, "spike at tick \(t)")
        }
    }

    func testRingsOpenInvalidShapeThrowsBadValue() {
        let twin = TwinState()
        let id = twin.nextId(prefix: "n")
        XCTAssertThrowsError(try twin.apply(.ringsOpen(id: id, gear: 1, rings: 4, cells: 8))) { error in
            guard case TwinState.TwinError.badValue = error else {
                XCTFail("expected badValue, got \(error)"); return
            }
        }
        XCTAssertNil(twin.rings.get(id))
    }

    // MARK: - TwinState: clock + gear

    func testClockGearAdvanceExactFireCount() throws {
        let twin = TwinState()
        let clockId = twin.nextId(prefix: "c")
        try twin.apply(.clockOpen(id: clockId))
        let gearId = twin.nextId(prefix: "g")
        try twin.apply(.gearOpen(id: gearId, clockId: clockId, name: "g", num: 3, den: 7))

        try twin.apply(.clockAdvance(id: clockId, count: 10_000, value: 0))

        XCTAssertEqual(twin.clocks.get(clockId)?.clock.tick, 10_000)
        XCTAssertEqual(twin.gears.get(gearId)?.gear.fires, 10_000 * 3 / 7)
        XCTAssertEqual(twin.gears.get(gearId)?.gear.fires, 4285)
    }

    func testGearOpenOnMissingClockThrowsNotFound() {
        let twin = TwinState()
        let gearId = twin.nextId(prefix: "g")
        XCTAssertThrowsError(try twin.apply(.gearOpen(id: gearId, clockId: "c00000099", name: "g", num: 3, den: 7))) { error in
            guard case TwinState.TwinError.notFound("c00000099") = error else {
                XCTFail("expected notFound, got \(error)"); return
            }
        }
        XCTAssertNil(twin.gears.get(gearId))
    }

    func testGearOpenRejectsZeroRatioAsBadValue() throws {
        let twin = TwinState()
        let clockId = twin.nextId(prefix: "c")
        try twin.apply(.clockOpen(id: clockId))
        let gearId = twin.nextId(prefix: "g")
        XCTAssertThrowsError(try twin.apply(.gearOpen(id: gearId, clockId: clockId, name: "g", num: 0, den: 7))) { error in
            guard case TwinState.TwinError.badValue = error else {
                XCTFail("expected badValue, got \(error)"); return
            }
        }
    }

    func testClockCloseCascadesToGears() throws {
        let twin = TwinState()
        let clockId = twin.nextId(prefix: "c")
        try twin.apply(.clockOpen(id: clockId))
        let gearId1 = twin.nextId(prefix: "g")
        try twin.apply(.gearOpen(id: gearId1, clockId: clockId, name: "g1", num: 1, den: 3))
        let gearId2 = twin.nextId(prefix: "g")
        try twin.apply(.gearOpen(id: gearId2, clockId: clockId, name: "g2", num: 1, den: 5))

        XCTAssertEqual(twin.gears.openCount, 2)

        try twin.apply(.close(id: clockId))

        XCTAssertNil(twin.clocks.get(clockId))
        XCTAssertNil(twin.gears.get(gearId1))
        XCTAssertNil(twin.gears.get(gearId2))
        XCTAssertEqual(twin.gears.openCount, 0)
    }

    // MARK: - TwinState: budget layout (sealed legal-miss)

    func testLayoutOpenSealedLegalMissServesCheaperPocket() throws {
        let twin = TwinState()
        let id = twin.nextId(prefix: "b")
        let sealed = SealedCourt.makeLayout()
        try twin.apply(.layoutOpen(id: id, cost: sealed.cost, minTier: sealed.minTier))

        let stored = twin.layouts.get(id)!
        let claims = [BudgetLayout.Claim(pocket: 0, classIndex: 0), BudgetLayout.Claim(pocket: 3, classIndex: 0)]
        let layout = try stored.allocate(claims: claims, budget: 16164.352484758914)

        // Both claims cannot fit together (15138 + 5618 > 16164.35); both
        // options carry the same read value (1), so the cheaper pocket
        // (3, cost 5618) wins the tie-break over pocket 0 (cost 15138).
        XCTAssertEqual(layout.servedPockets, [3])
        XCTAssertEqual(layout.totalCost, 5618)
    }

    func testLayoutOpenRejectsRaggedTableAsBadValue() {
        let twin = TwinState()
        let id = twin.nextId(prefix: "b")
        XCTAssertThrowsError(try twin.apply(.layoutOpen(id: id, cost: [[1, 2], [1]], minTier: [0]))) { error in
            guard case TwinState.TwinError.badValue = error else {
                XCTFail("expected badValue, got \(error)"); return
            }
        }
        XCTAssertNil(twin.layouts.get(id))
    }

    // MARK: - TwinState: alarm set

    func testAlarmLoadSyntheticFixture() throws {
        let (path, sha) = try writeSyntheticAlarmFixture()
        let twin = TwinState()
        let id = twin.nextId(prefix: "a")
        try twin.apply(.alarmLoad(id: id, path: path, sha256: sha))

        let set = twin.alarms.get(id)!
        XCTAssertEqual(set.ref.path, path)
        XCTAssertEqual(set.ref.sha256, sha)
        XCTAssertEqual(set.fixture.records.count, 5)
        XCTAssertEqual(set.fixture.control?.key, "cal0_1")
    }

    func testAlarmLoadWithWrongSHAThrowsIO() throws {
        let (path, _) = try writeSyntheticAlarmFixture()
        let twin = TwinState()
        let id = twin.nextId(prefix: "a")
        XCTAssertThrowsError(try twin.apply(.alarmLoad(id: id, path: path, sha256: "not-a-real-sha"))) { error in
            guard case TwinState.TwinError.io = error else {
                XCTFail("expected io, got \(error)"); return
            }
        }
        XCTAssertNil(twin.alarms.get(id))
    }

    // MARK: - TwinState: bank (spec 8 mouth)

    func testBankOpenMintsWIdAndRebuildsK160() throws {
        let twin = TwinState()
        let id = twin.nextId(prefix: "w")
        try twin.apply(.bankOpen(id: id, name: "mouth", spec: .reference))
        XCTAssertEqual(id, "w00000001")

        let entry = twin.banks.get(id)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.bank.K, 160)
        XCTAssertEqual(twin.totalOpen, 1)
    }

    func testBankOpenRejectsBadSpec() {
        let twin = TwinState()
        let id = twin.nextId(prefix: "w")
        var badSpec = WaveBank.Spec.reference
        badSpec = WaveBank.Spec(samples: badSpec.samples, sampleRate: badSpec.sampleRate,
                                 f0: badSpec.f0, harmonics: 0, gaborCenters: badSpec.gaborCenters,
                                 gaborFreqs: badSpec.gaborFreqs, gaborSigmaFrac: badSpec.gaborSigmaFrac)
        XCTAssertThrowsError(try twin.apply(.bankOpen(id: id, name: "mouth", spec: badSpec))) { error in
            guard case TwinState.TwinError.badValue = error else {
                XCTFail("expected badValue, got \(error)"); return
            }
        }
        XCTAssertNil(twin.banks.get(id))
    }

    func testCloseBankByPrefix() throws {
        let twin = TwinState()
        let id = twin.nextId(prefix: "w")
        try twin.apply(.bankOpen(id: id, name: "mouth", spec: .reference))
        XCTAssertEqual(twin.banks.openCount, 1)

        try twin.apply(.close(id: id))
        XCTAssertNil(twin.banks.get(id))
        XCTAssertEqual(twin.banks.openCount, 0)

        XCTAssertThrowsError(try twin.apply(.close(id: id))) { error in
            guard case TwinState.TwinError.notFound(id) = error else {
                XCTFail("expected notFound, got \(error)"); return
            }
        }
    }

    func testExportRestoreRoundTripsBank() throws {
        let twin = TwinState()
        let id = twin.nextId(prefix: "w")
        try twin.apply(.bankOpen(id: id, name: "mouth", spec: .reference))

        let snap = twin.export()
        XCTAssertEqual(snap.counters["w"], 1)

        let fresh = TwinState()
        try fresh.restore(snap)

        XCTAssertEqual(fresh.export(), snap)
        XCTAssertEqual(fresh.banks.counter, 1)
        XCTAssertNotNil(fresh.banks.get(id))

        let probe = WaveBank.referenceProbe(spec: .reference)
        let residualOld = "\(twin.banks.get(id)!.bank.fit(probe)!.residual)"
        let residualNew = "\(fresh.banks.get(id)!.bank.fit(probe)!.residual)"
        XCTAssertEqual(residualOld, residualNew)
    }

    // MARK: - TwinState: view (derived-view sets, spec line 4)

    /// The loader asserts M == 129*54 (contract ruling (c)) — a real npz
    /// fixture is too heavy for a registry-mechanics test, so this injects
    /// a stub loader via `TwinState.apply`'s `viewLoader:` parameter (same
    /// injection point `AlarmFixture`-backed tests would use), never
    /// touching `CortexFixture.load` at all. See `stubCortexFixture`'s doc
    /// comment for why this is the simplest option that keeps `load`'s own
    /// asserts intact.
    func testViewLoadMintsVIdViaInjectedLoader() throws {
        let twin = TwinState()
        let stub = stubCortexFixture(path: "/fake/cortex_v4_world.npz", sha256: "abc123")
        let id = twin.nextId(prefix: "v")
        try twin.apply(.viewLoad(id: id, path: "/fake/cortex_v4_world.npz", sha256: "abc123"),
                       viewLoader: { _, _ in stub })

        XCTAssertEqual(id, "v00000001")
        let set = twin.views.get(id)
        XCTAssertNotNil(set)
        XCTAssertEqual(set?.ref.path, "/fake/cortex_v4_world.npz")
        XCTAssertEqual(set?.ref.sha256, "abc123")
        XCTAssertEqual(set?.views.fixture.candidates, 129)
        XCTAssertEqual(twin.totalOpen, 1)
    }

    func testViewLoadWithWrongLoaderErrorThrowsIO() throws {
        let twin = TwinState()
        let id = twin.nextId(prefix: "v")
        struct Boom: Error {}
        XCTAssertThrowsError(
            try twin.apply(.viewLoad(id: id, path: "/x.npz", sha256: "abc"), viewLoader: { _, _ in throw Boom() })
        ) { error in
            guard case TwinState.TwinError.io = error else {
                XCTFail("expected io, got \(error)"); return
            }
        }
        XCTAssertNil(twin.views.get(id))
    }

    func testCloseViewByPrefix() throws {
        let twin = TwinState()
        let stub = stubCortexFixture()
        let id = twin.nextId(prefix: "v")
        try twin.apply(.viewLoad(id: id, path: "synthetic", sha256: "deadbeef"), viewLoader: { _, _ in stub })
        XCTAssertEqual(twin.views.openCount, 1)

        try twin.apply(.close(id: id))
        XCTAssertNil(twin.views.get(id))
        XCTAssertEqual(twin.views.openCount, 0)

        XCTAssertThrowsError(try twin.apply(.close(id: id))) { error in
            guard case TwinState.TwinError.notFound(id) = error else {
                XCTFail("expected notFound, got \(error)"); return
            }
        }
    }

    func testExportRestoreRoundTripsView() throws {
        let twin = TwinState()
        let stub = stubCortexFixture(path: "synthetic.npz", sha256: "cafef00d")
        let id = twin.nextId(prefix: "v")
        try twin.apply(.viewLoad(id: id, path: "synthetic.npz", sha256: "cafef00d"), viewLoader: { _, _ in stub })

        let snap = twin.export()
        XCTAssertEqual(snap.counters["v"], 1)
        XCTAssertEqual(snap.views[id], TwinState.ViewRef(path: "synthetic.npz", sha256: "cafef00d"))

        let fresh = TwinState()
        try fresh.restore(snap, viewLoader: { _, _ in stub })

        XCTAssertEqual(fresh.export(), snap)
        XCTAssertEqual(fresh.views.counter, 1)
        XCTAssertNotNil(fresh.views.get(id))
        XCTAssertEqual(fresh.views.get(id)?.ref, TwinState.ViewRef(path: "synthetic.npz", sha256: "cafef00d"))
    }

    // MARK: - TwinState: kernel (per-path kernel pairs, gates K3/K4)

    /// A minimal `KernelPair` for kernel-registry mechanics tests — the
    /// real `KernelPair.load` (file + sha check) is exercised for real in
    /// TwinKernelCommandTests's in-repo-fixture tests; this only needs a
    /// valid pair to hand back from the injected `kernelLoader`.
    private func stubKernelPair(fs: Double = 3000, window: Int = 4, earA: Int = 170, earB: Int = 236) -> KernelPair {
        try! KernelPair(kA: [1, 0.5, 0.25, 0.1], kB: [0.9, 0.4, 0.2, 0.05],
                         meta: .init(fs: fs, window: window, earA: earA, earB: earB))
    }

    func testExportRestoreRoundTripsKernelCounter() throws {
        let twin = TwinState()
        let pair = stubKernelPair()
        let id = twin.nextId(prefix: "k")
        try twin.apply(
            .kernelLoad(id: id, path: "synthetic.json", sha256: "cafef00d",
                        tauA: 0.18227148035108542, tauB: 0.18382585465904366, sigmaSource: 0.02, declaredWarmup: nil),
            kernelLoader: { _ in pair }
        )

        let snap = twin.export()
        XCTAssertEqual(snap.counters["k"], 1)
        XCTAssertEqual(
            snap.kernels[id],
            TwinState.KernelRef(path: "synthetic.json", sha256: "cafef00d",
                                 tauA: 0.18227148035108542, tauB: 0.18382585465904366, sigmaSource: 0.02, declaredWarmup: nil)
        )

        let fresh = TwinState()
        try fresh.restore(snap, kernelLoader: { _ in pair })

        XCTAssertEqual(fresh.export(), snap)
        XCTAssertEqual(fresh.kernels.counter, 1, "restore keeps the 'k' counter")
        XCTAssertNotNil(fresh.kernels.get(id))
        XCTAssertEqual(fresh.kernels.get(id)?.ref, snap.kernels[id])
    }

    func testKernelLoadWithWrongLoaderErrorThrowsIO() throws {
        let twin = TwinState()
        let id = twin.nextId(prefix: "k")
        struct Boom: Error {}
        XCTAssertThrowsError(
            try twin.apply(.kernelLoad(id: id, path: "/x.json", sha256: "abc", tauA: nil, tauB: nil, sigmaSource: nil, declaredWarmup: nil),
                            kernelLoader: { _ in throw Boom() })
        ) { error in
            guard case TwinState.TwinError.io = error else {
                XCTFail("expected io, got \(error)"); return
            }
        }
        XCTAssertNil(twin.kernels.get(id))
    }

    func testCloseKernelByPrefix() throws {
        let twin = TwinState()
        let pair = stubKernelPair()
        let id = twin.nextId(prefix: "k")
        try twin.apply(.kernelLoad(id: id, path: "synthetic.json", sha256: "deadbeef", tauA: nil, tauB: nil, sigmaSource: nil, declaredWarmup: nil),
                       kernelLoader: { _ in pair })
        XCTAssertEqual(twin.kernels.openCount, 1)

        try twin.apply(.close(id: id))
        XCTAssertNil(twin.kernels.get(id))
        XCTAssertEqual(twin.kernels.openCount, 0)
    }

    // MARK: - close(): prefix routing, unknown ids

    func testCloseUnknownIdThrowsNotFound() {
        let twin = TwinState()
        XCTAssertThrowsError(try twin.apply(.close(id: "s00000042"))) { error in
            guard case TwinState.TwinError.notFound("s00000042") = error else {
                XCTFail("expected notFound, got \(error)"); return
            }
        }
    }

    func testCloseUnrecognizedPrefixThrowsBadId() {
        let twin = TwinState()
        XCTAssertThrowsError(try twin.apply(.close(id: "z00000001"))) { error in
            guard case TwinState.TwinError.badId("z00000001") = error else {
                XCTFail("expected badId, got \(error)"); return
            }
        }
    }

    // MARK: - totalOpen / reset

    func testTotalOpenCountsAcrossRegistries() throws {
        let twin = TwinState()
        try twin.apply(.streamOpen(id: twin.nextId(prefix: "s"), name: "a",
                                    stateHi: 1, stateLo: 1, incHi: 1, incLo: 1))
        try twin.apply(.clockOpen(id: twin.nextId(prefix: "c")))
        XCTAssertEqual(twin.totalOpen, 2)

        twin.reset()
        XCTAssertEqual(twin.totalOpen, 0)
        XCTAssertEqual(twin.streams.counter, 0)
        XCTAssertEqual(twin.clocks.counter, 0)
    }

    // MARK: - export() / restore() round trip

    func testExportRestoreRoundTripPreservesStateAndCounters() throws {
        let twin = TwinState()

        // streams: open 3, close the LAST one (highest counter) so the
        // exported counter (3) exceeds every surviving id's numeric value.
        let s1 = twin.nextId(prefix: "s")
        try twin.apply(.streamOpen(id: s1, name: "a", stateHi: 1, stateLo: 1, incHi: 1, incLo: 1))
        let s2 = twin.nextId(prefix: "s")
        try twin.apply(.streamOpen(id: s2, name: "b", stateHi: 2, stateLo: 2, incHi: 1, incLo: 1))
        let s3 = twin.nextId(prefix: "s")
        try twin.apply(.streamOpen(id: s3, name: "c", stateHi: 3, stateLo: 3, incHi: 1, incLo: 1))
        try twin.apply(.close(id: s3))

        // record with 3 slices
        let recId = twin.nextId(prefix: "t")
        try twin.apply(.recordOpen(id: recId, name: referenceName, header: w1Like(),
                                    stateHi: referenceStateHi, stateLo: referenceStateLo,
                                    incHi: referenceIncHi, incLo: referenceIncLo))
        try twin.apply(.recordSlice(id: recId, count: 5))
        try twin.apply(.recordSlice(id: recId, count: 7))
        try twin.apply(.recordSlice(id: recId, count: 3))

        // rings
        let ringsId = twin.nextId(prefix: "n")
        try twin.apply(.ringsOpen(id: ringsId, gear: 6, rings: 4, cells: 8))
        let (values, _, _) = ringsSpikes()
        try twin.apply(.ringsWrite(id: ringsId, values: values))

        // clock + gear
        let clockId = twin.nextId(prefix: "c")
        try twin.apply(.clockOpen(id: clockId))
        let gearId = twin.nextId(prefix: "g")
        try twin.apply(.gearOpen(id: gearId, clockId: clockId, name: "g", num: 3, den: 7))
        try twin.apply(.clockAdvance(id: clockId, count: 100, value: 0.5))

        // budget layout
        let layoutId = twin.nextId(prefix: "b")
        let sealed = SealedCourt.makeLayout()
        try twin.apply(.layoutOpen(id: layoutId, cost: sealed.cost, minTier: sealed.minTier))

        // alarm set (by reference)
        let (path, sha) = try writeSyntheticAlarmFixture()
        let alarmId = twin.nextId(prefix: "a")
        try twin.apply(.alarmLoad(id: alarmId, path: path, sha256: sha))

        let snap = twin.export()
        XCTAssertEqual(snap.streams.count, 2)          // s3 was closed before export
        XCTAssertEqual(snap.counters["s"], 3)           // but the counter still remembers it

        let fresh = TwinState()
        try fresh.restore(snap)

        XCTAssertEqual(fresh.export(), snap)
        XCTAssertEqual(fresh.streams.counter, 3)
        XCTAssertEqual(fresh.streams.openCount, 2)
        XCTAssertNotNil(fresh.streams.get(s1))
        XCTAssertNotNil(fresh.streams.get(s2))
        XCTAssertNil(fresh.streams.get(s3))
        XCTAssertEqual(fresh.records.get(recId)?.verify(), [])
        XCTAssertEqual(fresh.rings.get(ringsId), twin.rings.get(ringsId))
        XCTAssertEqual(fresh.clocks.get(clockId)?.clock.tick, 100)
        XCTAssertEqual(fresh.gears.get(gearId)?.gear.fires, 100 * 3 / 7)
        XCTAssertEqual(fresh.layouts.get(layoutId), twin.layouts.get(layoutId))
        XCTAssertEqual(fresh.alarms.get(alarmId)?.ref, TwinState.AlarmRef(path: path, sha256: sha))
        XCTAssertEqual(fresh.alarms.get(alarmId)?.fixture.records.count, 5)
        XCTAssertEqual(fresh.totalOpen, twin.totalOpen)
    }

    func testRestoreDropsMissingAlarmFileAndWarnsOnce() throws {
        let twin = TwinState()
        let (path, sha) = try writeSyntheticAlarmFixture()
        let alarmId = twin.nextId(prefix: "a")
        try twin.apply(.alarmLoad(id: alarmId, path: path, sha256: sha))
        let streamId = twin.nextId(prefix: "s")
        try twin.apply(.streamOpen(id: streamId, name: "a", stateHi: 1, stateLo: 1, incHi: 1, incLo: 1))

        let snap = twin.export()

        // Remove the backing file before restore — the loader must throw.
        try FileManager.default.removeItem(atPath: path)

        var warnCount = 0
        var lastWarning = ""
        let fresh = TwinState()
        try fresh.restore(snap, warn: { msg in
            warnCount += 1
            lastWarning = msg
        })

        XCTAssertEqual(warnCount, 1)
        XCTAssertTrue(lastWarning.contains(alarmId))
        XCTAssertNil(fresh.alarms.get(alarmId))
        XCTAssertEqual(fresh.alarms.openCount, 0)
        // the rest of the state restores normally — one bad alarm entry
        // never refuses the whole load.
        XCTAssertNotNil(fresh.streams.get(streamId))
    }
}

// MARK: - Hook (docs/contracts/HOOK_GATES_FROZEN.md, twin spec line 6)
extension TwinRegistryTests {
    private func loadHookSealedOrSkip() throws -> AlarmFixture {
        guard let path = AlarmFixture.envPath else {
            throw XCTSkip("DAGDB_W2_FIXTURE not set — sealed gate skipped")
        }
        return try AlarmFixture.load(path: path, expectedSHA256: AlarmFixture.sealedSHA256)
    }

    func testHookOpenStepAndBindingRules() throws {
        let (path, sha) = try writeSyntheticAlarmFixture()
        let twin = TwinState()
        let alarmId = twin.nextId(prefix: "a")
        try twin.apply(.alarmLoad(id: alarmId, path: path, sha256: sha))

        // Unbound hook: HOOK STEP works directly. (5 records + delta 3 = 8 frames.)
        let unboundId = twin.nextId(prefix: "h")
        let unboundParams = AttentionHook.Params(alarmId: alarmId, layoutId: nil, budget: 100_000,
                                                   delta: 3, policy: .allocator, clockId: nil)
        try twin.apply(.hookOpen(id: unboundId, params: unboundParams))
        try twin.apply(.hookStep(id: unboundId, count: 8))
        XCTAssertTrue(twin.hooks.get(unboundId)!.hook.done)

        // Bound hook: HOOK STEP refuses with "bound to clock".
        let clockId = twin.nextId(prefix: "c")
        try twin.apply(.clockOpen(id: clockId))
        let boundId = twin.nextId(prefix: "h")
        let boundParams = AttentionHook.Params(alarmId: alarmId, layoutId: nil, budget: 100_000,
                                                 delta: 3, policy: .allocator, clockId: clockId)
        try twin.apply(.hookOpen(id: boundId, params: boundParams))
        XCTAssertEqual(twin.clocks.get(clockId)?.hookIds, [boundId])

        XCTAssertThrowsError(try twin.apply(.hookStep(id: boundId, count: 1))) { error in
            guard case TwinState.TwinError.badValue(let msg) = error else {
                XCTFail("expected badValue, got \(error)"); return
            }
            XCTAssertTrue(msg.contains("bound to clock"), msg)
            XCTAssertTrue(msg.contains(clockId), msg)
        }

        // CLOCK ADVANCE 8 steps the bound hook to done.
        try twin.apply(.clockAdvance(id: clockId, count: 8, value: 0))
        XCTAssertTrue(twin.hooks.get(boundId)!.hook.done)

        // CLOCK CLOSE cascades to the bound hook, like gears.
        try twin.apply(.close(id: clockId))
        XCTAssertNil(twin.clocks.get(clockId))
        XCTAssertNil(twin.hooks.get(boundId))

        // Closing the alarm set while the unbound hook is still live refuses.
        XCTAssertThrowsError(try twin.apply(.close(id: alarmId))) { error in
            guard case TwinState.TwinError.badValue(let msg) = error else {
                XCTFail("expected badValue, got \(error)"); return
            }
            XCTAssertTrue(msg.contains(unboundId), msg)
            XCTAssertTrue(msg.contains(alarmId), msg)
        }

        // After closing the hook, closing the alarm set succeeds.
        try twin.apply(.close(id: unboundId))
        XCTAssertNoThrow(try twin.apply(.close(id: alarmId)))
    }

    func testHookSnapshotRoundTripRebuildsLedger() throws {
        let (path, sha) = try writeSyntheticAlarmFixture()
        let twin = TwinState()
        let alarmId = twin.nextId(prefix: "a")
        try twin.apply(.alarmLoad(id: alarmId, path: path, sha256: sha))

        let hookId = twin.nextId(prefix: "h")
        let params = AttentionHook.Params(alarmId: alarmId, layoutId: nil, budget: 100_000,
                                           delta: 3, policy: .allocator, clockId: nil)
        try twin.apply(.hookOpen(id: hookId, params: params))
        try twin.apply(.hookStep(id: hookId, count: 5))

        let snap = twin.export()
        XCTAssertEqual(snap.hooks[hookId], TwinState.HookRef(params: params, t: 5))

        let fresh = TwinState()
        try fresh.restore(snap)

        XCTAssertEqual(fresh.hooks.get(hookId)?.hook.result, twin.hooks.get(hookId)?.hook.result)
        XCTAssertEqual(fresh.hooks.get(hookId)?.hook.ledger, twin.hooks.get(hookId)?.hook.ledger)
        XCTAssertEqual(fresh.hooks.get(hookId)?.hook.t, 5)
        XCTAssertEqual(fresh.export(), snap)
    }

    /// H4: "H1 is asserted both ways at one grid point" — bound (via
    /// CLOCK ADVANCE) and unbound (via HOOK STEP) hooks over the sealed
    /// fixture at the richest point must reach identical results and
    /// ledgers.
    func testH4BothWaysAtRichestPoint() throws {
        let fixture = try loadHookSealedOrSkip()
        XCTAssertEqual(fixture.records.count, 200, "sanity: the sealed fixture")
        let path = AlarmFixture.envPath!
        let budget = SealedCourt.budgetGrid[0].budget

        let twin = TwinState()
        let alarmId = twin.nextId(prefix: "a")
        try twin.apply(.alarmLoad(id: alarmId, path: path, sha256: AlarmFixture.sealedSHA256))

        // Unbound: HOOK STEP 203 directly.
        let unboundId = twin.nextId(prefix: "h")
        let unboundParams = AttentionHook.Params(alarmId: alarmId, layoutId: nil, budget: budget,
                                                   delta: SealedCourt.delta, policy: .allocator, clockId: nil)
        try twin.apply(.hookOpen(id: unboundId, params: unboundParams))
        try twin.apply(.hookStep(id: unboundId, count: 200 + SealedCourt.delta))

        // Bound: 203 CLOCK ADVANCE ticks.
        let clockId = twin.nextId(prefix: "c")
        try twin.apply(.clockOpen(id: clockId))
        let boundId = twin.nextId(prefix: "h")
        let boundParams = AttentionHook.Params(alarmId: alarmId, layoutId: nil, budget: budget,
                                                 delta: SealedCourt.delta, policy: .allocator, clockId: clockId)
        try twin.apply(.hookOpen(id: boundId, params: boundParams))
        try twin.apply(.clockAdvance(id: clockId, count: UInt64(200 + SealedCourt.delta), value: 0))

        let unbound = twin.hooks.get(unboundId)!.hook
        let bound = twin.hooks.get(boundId)!.hook
        XCTAssertTrue(unbound.done)
        XCTAssertTrue(bound.done)
        XCTAssertEqual(unbound.result, bound.result)
        XCTAssertEqual(unbound.ledger, bound.ledger)

        let expected = AllocatorCourt.run(records: fixture.records, budget: budget)[.allocator]!
        XCTAssertEqual(unbound.result, expected)
    }
}

// MARK: - Gear close prunes its clock (the interface phase finding)
extension TwinRegistryTests {
    func testDirectGearCloseIsPrunedFromClockThenAdvanceStillWorks() throws {
        let t = TwinState()
        try t.apply(.clockOpen(id: "c00000001"))
        try t.apply(.gearOpen(id: "g00000001", clockId: "c00000001", name: "a", num: 1, den: 6))
        try t.apply(.gearOpen(id: "g00000002", clockId: "c00000001", name: "b", num: 1, den: 36))
        try t.apply(.close(id: "g00000001"))
        XCTAssertEqual(t.clocks.get("c00000001")?.gearIds, ["g00000002"])
        XCTAssertNoThrow(try t.apply(.clockAdvance(id: "c00000001", count: 36, value: 0)))
        XCTAssertEqual(t.gears.get("g00000002")?.gear.fires, 1)
        XCTAssertNil(t.gears.get("g00000001"))
    }
}
