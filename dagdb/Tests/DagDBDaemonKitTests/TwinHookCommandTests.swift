import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Gate H5 (docs/contracts/HOOK_GATES_FROZEN.md) — daemon-level tests for
/// the real HOOK verb family (DagDBCommandHandler+TwinHook.swift):
/// OPEN/STEP/STATE/LEDGER/INFO/LIST/CLOSE, the CLOCK-binding refusal (H4),
/// the ALARM/BUDGET-close dependency refusal (H3), WAL replay, and
/// SAVE/LOAD. Synthetic-fixture tests exercise every verb without the
/// sealed file (mirrors TwinAlarmCommandTests.swift's fixture verbatim: 5
/// records, so a hook's default delta 3 gives frames = 5 + 3 = 8); the
/// sealed-fixture tests replay the real 200-record `w2_records.json` and
/// skip (XCTSkip) when `DAGDB_W2_FIXTURE` is unset.
///
/// `side: 64` (nodeCount 4096, shm capacity 8 + 4096*24 = 98,312 bytes) is
/// used throughout instead of the usual small fixtures — `HOOK LEDGER`'s
/// 40-byte rows need 8 + 203*40 = 8,128 bytes at the sealed fixture's
/// richest point.
final class TwinHookCommandTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-hookcmd-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - Synthetic mini-fixture (verbatim from TwinAlarmCommandTests.swift)
    // quiet_1, quiet_2, liar_1 (ear B), deep_1, drift_1, cal0_1 — 5 judged
    // records + the cal0 control. Default delta 3 ⇒ frames = 5 + 3 = 8.

    @discardableResult
    private func writeSyntheticFixture(in dir: String, named name: String = "mini.json") throws -> String {
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
        let path = dir + name
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    @discardableResult
    private func loadSynthetic(_ f: HandlerFixture) throws -> String {
        let path = try writeSyntheticFixture(in: tmpDir)
        let reply = f.handler.handle("ALARM LOAD \(path)")
        XCTAssertTrue(reply.hasPrefix("OK ALARM LOAD id=a00000001"), reply)
        return reply
    }

    // MARK: - shm row decode: [u32 count][u32 40] + 40-byte rows, per
    // DagDBCommandHandler+TwinHook.swift's writeHookLedgerRows layout.

    private struct DecodedRow: Equatable {
        let t: UInt32
        let src: Int32
        let judged: UInt8
        let outcome: UInt8
        let tier: Int8
        let pocket: Int8
        let spend: Double
        let cumulativeCost: Double
        let countsTowardCost: UInt8
    }

    private func readLedgerRows(_ f: HandlerFixture, count: Int) -> [DecodedRow] {
        var rows: [DecodedRow] = []
        for i in 0..<count {
            let base = f.shm.advanced(by: 8 + i * 40)
            let t = base.bindMemory(to: UInt32.self, capacity: 1)[0]
            let src = base.advanced(by: 4).bindMemory(to: Int32.self, capacity: 1)[0]
            let judged = base.advanced(by: 8).bindMemory(to: UInt8.self, capacity: 1)[0]
            let outcome = base.advanced(by: 9).bindMemory(to: UInt8.self, capacity: 1)[0]
            let tier = base.advanced(by: 10).bindMemory(to: Int8.self, capacity: 1)[0]
            let pocket = base.advanced(by: 11).bindMemory(to: Int8.self, capacity: 1)[0]
            let spend = base.advanced(by: 16).bindMemory(to: Double.self, capacity: 1)[0]
            let cumulativeCost = base.advanced(by: 24).bindMemory(to: Double.self, capacity: 1)[0]
            let countsTowardCost = base.advanced(by: 32).bindMemory(to: UInt8.self, capacity: 1)[0]
            rows.append(DecodedRow(
                t: t, src: src, judged: judged, outcome: outcome, tier: tier, pocket: pocket,
                spend: spend, cumulativeCost: cumulativeCost, countsTowardCost: countsTowardCost
            ))
        }
        return rows
    }

    private func outcomeByte(_ o: AttentionHook.Outcome) -> UInt8 {
        switch o {
        case .none: return 0
        case .hit: return 1
        case .miss: return 2
        }
    }

    /// Strips the "id=<id> " field out of a twin reply so a bound and an
    /// unbound hook's otherwise-identical STATE lines can be compared.
    private func dropIdField(_ line: String) -> String {
        guard let idRange = line.range(of: "id="),
              let spaceAfter = line.range(of: " ", range: idRange.upperBound..<line.endIndex) else {
            return line
        }
        return String(line[..<idRange.lowerBound]) + String(line[spaceAfter.upperBound...])
    }

    private func openReaderId(_ f: HandlerFixture) throws -> String {
        let openReply = f.handler.handle("OPEN_READER")
        guard let ridRange = openReply.range(of: "id="),
              let spaceRange = openReply.range(of: " ", range: ridRange.upperBound..<openReply.endIndex) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not parse reader id out of: \(openReply)"])
        }
        return String(openReply[ridRange.upperBound..<spaceRange.lowerBound])
    }

    // MARK: - HOOK OPEN

    func testHookOpenSealedLayoutDefaultDeltaPolicy() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        let reply = f.handler.handle("HOOK OPEN a00000001 SEALED 16164.352484758914")
        XCTAssertEqual(
            reply,
            "OK HOOK OPEN id=h00000001 alarm=a00000001 layout=SEALED B=16164.352484758914 delta=3 policy=allocator clock=none frames=8"
        )
    }

    func testHookOpenWithExplicitBudgetLayoutId() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        let budgetReply = f.handler.handle("BUDGET SEALED")
        XCTAssertTrue(budgetReply.hasPrefix("OK BUDGET SEALED id=b00000001"), budgetReply)

        let reply = f.handler.handle("HOOK OPEN a00000001 b00000001 100000")
        XCTAssertTrue(reply.hasPrefix("OK HOOK OPEN id=h00000001"), reply)
        XCTAssertTrue(reply.contains("layout=b00000001"), reply)
    }

    func testHookOpenUnknownAlarmIsNotFound() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        XCTAssertTrue(f.handler.handle("HOOK OPEN a00000001 SEALED 100000").hasPrefix("ERROR not_found"))
    }

    func testHookOpenUnknownLayoutIsNotFound() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        XCTAssertTrue(f.handler.handle("HOOK OPEN a00000001 b00000099 100000").hasPrefix("ERROR not_found"))
    }

    func testHookOpenUnknownClockIsNotFound() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        XCTAssertTrue(f.handler.handle("HOOK OPEN a00000001 SEALED 100000 CLOCK c00000099").hasPrefix("ERROR not_found"))
    }

    func testHookOpenNonFiniteOrNonPositiveBudgetIsBadValue() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        XCTAssertTrue(f.handler.handle("HOOK OPEN a00000001 SEALED 0").hasPrefix("ERROR bad_value"))
        XCTAssertTrue(f.handler.handle("HOOK OPEN a00000001 SEALED -5").hasPrefix("ERROR bad_value"))
    }

    func testHookOpenNegativeDeltaIsOutOfRange() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        XCTAssertTrue(f.handler.handle("HOOK OPEN a00000001 SEALED 100000 DELTA -1").hasPrefix("ERROR out_of_range"))
    }

    // MARK: - HOOK STEP

    func testHookStepPartialThenCompleteThenNoop() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        _ = f.handler.handle("HOOK OPEN a00000001 SEALED 100000")

        let step1 = f.handler.handle("HOOK STEP h00000001 3")
        XCTAssertTrue(step1.contains("t=3 stepped=3 done=0"), step1)

        let step2 = f.handler.handle("HOOK STEP h00000001 100")
        XCTAssertTrue(step2.contains("t=8 stepped=5 done=1"), step2)

        let step3 = f.handler.handle("HOOK STEP h00000001 1")
        XCTAssertTrue(step3.contains("stepped=0 done=1"), step3)
    }

    func testHookStepZeroIsOutOfRange() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        _ = f.handler.handle("HOOK OPEN a00000001 SEALED 100000")
        XCTAssertTrue(f.handler.handle("HOOK STEP h00000001 0").hasPrefix("ERROR out_of_range"))
    }

    // MARK: - HOOK STATE

    func testHookStateFields() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        _ = f.handler.handle("HOOK OPEN a00000001 SEALED 100000")
        _ = f.handler.handle("HOOK STEP h00000001 100")
        let state = f.handler.handle("HOOK STATE h00000001")
        XCTAssertTrue(state.hasPrefix("OK HOOK STATE id=h00000001 t=8 done=1"), state)
        for key in ["served=", "misses=", "cost=", "dummy=", "dominated=", "max_spend_ratio=", "warmup_cost=", "burst="] {
            XCTAssertTrue(state.contains(key), state)
        }
    }

    // MARK: - HOOK LEDGER

    func testLedgerDefaultDecodesToLibraryLedgerExactly() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        _ = f.handler.handle("HOOK OPEN a00000001 SEALED 100000")
        let stepReply = f.handler.handle("HOOK STEP h00000001 100")
        XCTAssertTrue(stepReply.contains("done=1"), stepReply)

        let ledgerReply = f.handler.handle("HOOK LEDGER h00000001")
        XCTAssertEqual(ledgerReply, "OK HOOK LEDGER id=h00000001 from=0 count=8 of=8")

        let expected = f.handler.twin.hooks.get("h00000001")!.hook.ledger
        XCTAssertEqual(expected.count, 8)
        let rows = readLedgerRows(f, count: 8)
        XCTAssertEqual(rows.count, expected.count)
        for (row, want) in zip(rows, expected) {
            XCTAssertEqual(row.t, UInt32(want.t))
            XCTAssertEqual(row.src, Int32(want.src))
            XCTAssertEqual(row.judged, want.judged ? 1 : 0)
            XCTAssertEqual(row.outcome, outcomeByte(want.outcome))
            XCTAssertEqual(row.tier, Int8(want.tierBought ?? -1))
            XCTAssertEqual(row.pocket, Int8(want.pocket ?? -1))
            XCTAssertEqual(row.spend, want.spend)
            XCTAssertEqual(row.cumulativeCost, want.cumulativeCost)
            XCTAssertEqual(row.countsTowardCost, want.countsTowardCost ? 1 : 0)
        }
    }

    func testLedgerRangeFromCount() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        _ = f.handler.handle("HOOK OPEN a00000001 SEALED 100000")
        _ = f.handler.handle("HOOK STEP h00000001 100")
        let reply = f.handler.handle("HOOK LEDGER h00000001 2 3")
        XCTAssertEqual(reply, "OK HOOK LEDGER id=h00000001 from=2 count=3 of=8")
    }

    func testLedgerOutOfRangeIsOutOfRange() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        _ = f.handler.handle("HOOK OPEN a00000001 SEALED 100000")
        _ = f.handler.handle("HOOK STEP h00000001 100")
        XCTAssertTrue(f.handler.handle("HOOK LEDGER h00000001 6 10").hasPrefix("ERROR out_of_range"))
    }

    // MARK: - HOOK INFO / LIST / CLOSE

    func testHookInfoListClose() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        _ = f.handler.handle("HOOK OPEN a00000001 SEALED 100000")

        let info = f.handler.handle("HOOK INFO h00000001")
        XCTAssertTrue(info.hasPrefix("OK HOOK INFO id=h00000001 alarm=a00000001 layout=SEALED"), info)
        XCTAssertTrue(info.contains("frames=8 t=0 done=0"), info)

        XCTAssertEqual(f.handler.handle("HOOK LIST"), "OK HOOK LIST count=1 h00000001")
        XCTAssertEqual(f.handler.handle("HOOK CLOSE h00000001"), "OK HOOK CLOSE id=h00000001")
        XCTAssertTrue(f.handler.handle("HOOK INFO h00000001").hasPrefix("ERROR not_found"))
        XCTAssertEqual(f.handler.handle("HOOK LIST"), "OK HOOK LIST count=0")
    }

    // MARK: - CLOCK binding (H4)

    func testHookBoundToClockRefusesStepAndMatchesUnboundOnAdvance() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)

        let unboundOpen = f.handler.handle("HOOK OPEN a00000001 SEALED 100000")
        XCTAssertTrue(unboundOpen.hasPrefix("OK HOOK OPEN id=h00000001"), unboundOpen)
        _ = f.handler.handle("HOOK STEP h00000001 100")
        let unboundState = f.handler.handle("HOOK STATE h00000001")

        XCTAssertTrue(f.handler.handle("CLOCK OPEN").hasPrefix("OK CLOCK OPEN id=c00000001"))
        let boundOpen = f.handler.handle("HOOK OPEN a00000001 SEALED 100000 CLOCK c00000001")
        XCTAssertTrue(boundOpen.hasPrefix("OK HOOK OPEN id=h00000002"), boundOpen)
        XCTAssertTrue(boundOpen.contains("clock=c00000001"), boundOpen)

        XCTAssertEqual(f.handler.handle("HOOK STEP h00000002 1"), "ERROR forbidden: bound to clock c00000001")

        let advance = f.handler.handle("CLOCK ADVANCE c00000001 8")
        XCTAssertTrue(advance.hasPrefix("OK CLOCK ADVANCE"), advance)

        let boundState = f.handler.handle("HOOK STATE h00000002")
        XCTAssertTrue(boundState.contains("done=1"), boundState)
        XCTAssertEqual(dropIdField(boundState), dropIdField(unboundState))
    }

    func testClockCloseCascadesToBoundHook() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        _ = f.handler.handle("CLOCK OPEN")
        let boundOpen = f.handler.handle("HOOK OPEN a00000001 SEALED 100000 CLOCK c00000001")
        XCTAssertTrue(boundOpen.hasPrefix("OK HOOK OPEN id=h00000001"), boundOpen)

        let closeReply = f.handler.handle("CLOCK CLOSE c00000001")
        XCTAssertEqual(closeReply, "OK CLOCK CLOSE id=c00000001 gears_closed=0 hooks_closed=1")
        XCTAssertEqual(f.handler.handle("HOOK LIST"), "OK HOOK LIST count=0")
    }

    // MARK: - ALARM/BUDGET CLOSE dependency refusal (H3)

    func testAlarmCloseWithLiveHookRefusesForbidden() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        let openReply = f.handler.handle("HOOK OPEN a00000001 SEALED 100000")
        XCTAssertTrue(openReply.hasPrefix("OK HOOK OPEN id=h00000001"), openReply)

        let closeReply = f.handler.handle("ALARM CLOSE a00000001")
        XCTAssertTrue(closeReply.hasPrefix("ERROR forbidden"), closeReply)
        XCTAssertTrue(closeReply.contains("h00000001"), closeReply)
        XCTAssertTrue(closeReply.contains("a00000001"), closeReply)

        // After closing the hook, closing the alarm set succeeds.
        XCTAssertEqual(f.handler.handle("HOOK CLOSE h00000001"), "OK HOOK CLOSE id=h00000001")
        XCTAssertEqual(f.handler.handle("ALARM CLOSE a00000001"), "OK ALARM CLOSE id=a00000001")
    }

    func testBudgetCloseWithLiveHookRefusesForbidden() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        let budgetReply = f.handler.handle("BUDGET SEALED")
        XCTAssertTrue(budgetReply.hasPrefix("OK BUDGET SEALED id=b00000001"), budgetReply)
        let openReply = f.handler.handle("HOOK OPEN a00000001 b00000001 100000")
        XCTAssertTrue(openReply.hasPrefix("OK HOOK OPEN id=h00000001"), openReply)

        let closeReply = f.handler.handle("BUDGET CLOSE b00000001")
        XCTAssertTrue(closeReply.hasPrefix("ERROR forbidden"), closeReply)
        XCTAssertTrue(closeReply.contains("h00000001"), closeReply)
        XCTAssertTrue(closeReply.contains("b00000001"), closeReply)
    }

    // MARK: - READER session polarity

    func testReaderSessionAllowsLooksForbidsMutations() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        _ = f.handler.handle("HOOK OPEN a00000001 SEALED 100000")
        _ = f.handler.handle("HOOK STEP h00000001 3")

        let rid = try openReaderId(f)
        XCTAssertFalse(f.handler.handle("READER \(rid) HOOK STATE h00000001").hasPrefix("ERROR forbidden"))
        XCTAssertFalse(f.handler.handle("READER \(rid) HOOK LEDGER h00000001").hasPrefix("ERROR forbidden"))
        XCTAssertFalse(f.handler.handle("READER \(rid) HOOK INFO h00000001").hasPrefix("ERROR forbidden"))
        XCTAssertFalse(f.handler.handle("READER \(rid) HOOK LIST").hasPrefix("ERROR forbidden"))

        XCTAssertTrue(f.handler.handle("READER \(rid) HOOK OPEN a00000001 SEALED 100000").hasPrefix("ERROR forbidden"))
        XCTAssertTrue(f.handler.handle("READER \(rid) HOOK STEP h00000001 1").hasPrefix("ERROR forbidden"))
        XCTAssertTrue(f.handler.handle("READER \(rid) HOOK CLOSE h00000001").hasPrefix("ERROR forbidden"))
    }

    // MARK: - STATUS twin_open

    func testStatusTwinOpenCountsHooks() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        XCTAssertTrue(f.handler.handle("STATUS").contains("twin_open=1"))
        _ = f.handler.handle("HOOK OPEN a00000001 SEALED 100000")
        XCTAssertTrue(f.handler.handle("STATUS").contains("twin_open=2"))
    }

    // MARK: - WAL replay

    func testWalReplayRestoresTAndState() throws {
        let path = try writeSyntheticFixture(in: tmpDir)
        let walPath = tmpDir + "twin.wal"
        let appender = try DagDBWAL.Appender(path: walPath, nodeCount: 100)
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir, wal: appender)

        XCTAssertTrue(f.handler.handle("ALARM LOAD \(path)").hasPrefix("OK ALARM LOAD id=a00000001"))
        XCTAssertTrue(f.handler.handle("HOOK OPEN a00000001 SEALED 100000").hasPrefix("OK HOOK OPEN id=h00000001"))
        XCTAssertTrue(f.handler.handle("HOOK STEP h00000001 5").contains("t=5"))

        let fresh = TwinState()
        let grid = try HexGrid(width: 10, height: 10)
        let state = DagDBState(width: 10, height: 10)
        let freshEngine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        _ = try DagDBWAL.replay(engine: freshEngine, nodeCount: freshEngine.nodeCount, path: walPath, twin: fresh)

        guard let entry = fresh.hooks.get("h00000001") else {
            return XCTFail("replay did not restore h00000001")
        }
        XCTAssertEqual(entry.hook.t, 5)
        XCTAssertEqual(entry.hook.result, f.handler.twin.hooks.get("h00000001")!.hook.result)
        XCTAssertEqual(entry.hook.ledger, f.handler.twin.hooks.get("h00000001")!.hook.ledger)
    }

    // MARK: - SAVE / LOAD round-trip (v7)

    func testSaveLoadRoundTripsHookParamsAndT() throws {
        let f1 = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f1)
        _ = f1.handler.handle("HOOK OPEN a00000001 SEALED 100000")
        _ = f1.handler.handle("HOOK STEP h00000001 5")

        let snapPath = tmpDir + "snap.dags"
        let saveReply = f1.handler.handle("SAVE \(snapPath)")
        XCTAssertTrue(saveReply.hasPrefix("OK SAVE"), saveReply)

        let f2 = try HandlerFixture(side: 64, dataRoot: tmpDir)
        let loadReply = f2.handler.handle("LOAD \(snapPath)")
        XCTAssertTrue(loadReply.hasPrefix("OK LOAD"), loadReply)

        XCTAssertEqual(f1.handler.handle("HOOK INFO h00000001"), f2.handler.handle("HOOK INFO h00000001"))
        XCTAssertEqual(f1.handler.handle("HOOK STATE h00000001"), f2.handler.handle("HOOK STATE h00000001"))
    }

    // MARK: - Sealed fixture (skipped without DAGDB_W2_FIXTURE)

    private func sealedPathOrSkip() throws -> String {
        guard let path = AlarmFixture.envPath else {
            throw XCTSkip("DAGDB_W2_FIXTURE not set — sealed gate skipped")
        }
        return path
    }

    func testSealedHookStepAllocatorRichestPoint() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 64, dataRoot: root)
        XCTAssertTrue(f.handler.handle("ALARM LOAD \(path) SHA \(AlarmFixture.sealedSHA256)").hasPrefix("OK ALARM LOAD id=a00000001"))

        let openReply = f.handler.handle("HOOK OPEN a00000001 SEALED 16164.352484758914")
        XCTAssertTrue(openReply.hasPrefix("OK HOOK OPEN id=h00000001"), openReply)
        XCTAssertTrue(openReply.contains("frames=203"), openReply)

        let stepReply = f.handler.handle("HOOK STEP h00000001 203")
        XCTAssertTrue(stepReply.contains("served=150 misses=0 cost=819218.0"), stepReply)

        let stateReply = f.handler.handle("HOOK STATE h00000001")
        XCTAssertTrue(stateReply.contains("served=150 misses=0 cost=819218.0"), stateReply)
    }

    func testSealedHookStepUniformPolicyRichestPoint() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 64, dataRoot: root)
        _ = f.handler.handle("ALARM LOAD \(path) SHA \(AlarmFixture.sealedSHA256)")

        let openReply = f.handler.handle("HOOK OPEN a00000001 SEALED 16164.352484758914 POLICY uniform")
        XCTAssertTrue(openReply.hasPrefix("OK HOOK OPEN id=h00000001"), openReply)
        XCTAssertTrue(openReply.contains("policy=uniform"), openReply)

        let stepReply = f.handler.handle("HOOK STEP h00000001 203")
        XCTAssertTrue(stepReply.contains("served=50 misses=100 cost=94400.0"), stepReply)
    }

    // MARK: - D3 · wire arithmetic cannot trap

    /// Audit finding 23 — `HOOK LEDGER`'s `end = from + count` is an
    /// unchecked `Int` addition on two wire values; `Int.max` plus anything
    /// TRAPS before the range guard behind it can fire.
    func testHookLedgerRangeOverflowIsRefusedNotTrapped() throws {
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        _ = f.handler.handle("HOOK OPEN a00000001 SEALED 100000")
        _ = f.handler.handle("HOOK STEP h00000001 100")
        let reply = f.handler.handle("HOOK LEDGER h00000001 \(Int.max) 5")
        XCTAssertTrue(reply.hasPrefix("ERROR out_of_range"), reply)
        XCTAssertTrue(f.handler.handle("STATUS").hasPrefix("OK STATUS"),
                      "the handler did not survive the refusal")
    }

}
