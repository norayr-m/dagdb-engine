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

    // MARK: - TwinRegistry: id format, uniqueness, restore path

    func testOpenMintsPrefixedSequentialIds() {
        let reg = TwinRegistry<Int>(prefix: "s")
        let id1 = reg.open(1)
        let id2 = reg.open(2)
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
        let liveId = reg.open(4)
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

    func testCloseAllAndEntries() {
        let reg = TwinRegistry<Int>(prefix: "s")
        let a = reg.open(1)
        let b = reg.open(2)
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
