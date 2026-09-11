import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// the interface phase — daemon-level tests for the real ALARM verb family
/// (DagDBCommandHandler+TwinAlarm.swift): LOAD/INFO/LIST/CLOSE/FRAME/COURT/
/// SUCCESSOR/CORRUPT. Synthetic-fixture tests exercise every verb without
/// the sealed file; the sealed-fixture tests replay the real 200-record
/// `w2_records.json` and skip (XCTSkip) when `DAGDB_W2_FIXTURE` is unset —
/// precedent `AlarmFixtureTests.swift` / `DagDBTickPerfTests.swift:206`.
///
/// `side: 10` (nodeCount 100, shm capacity 8 + 100*24 = 2408 bytes) is used
/// throughout instead of the usual `side: 4` — `ALARM CORRUPT`'s shm rows
/// are 40 bytes each and a liar class can produce up to 48 outcomes
/// (3 true-branches × 16 phantom masks), needing 1928 bytes past the
/// 8-byte header; `side: 4`'s 392-byte buffer (nodeCount 16) is too small.
final class TwinAlarmCommandTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-alarmcmd-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - Synthetic mini-fixture (verbatim from AlarmFixtureTests.swift)
    // quiet_1, quiet_2, liar_1 (ear B), deep_1, drift_1, cal0_1 — each with
    // 4-sample a/b/c waveform arrays. File order gives idx 1..5 =
    // quiet_1, quiet_2, liar_1, deep_1, drift_1; cal0_1 is the control.

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

    /// shm reader for `ALARM CORRUPT`'s row layout: [u32 count][u32 40] +
    /// rows of f64 weight | u32 nClaims | u32 0 |
    /// 5×(u8 pocket, u8 row, u8 phantom, u8 0) | 4 pad.
    private func readCorruptionRows(_ f: HandlerFixture, count: Int) -> [(weight: Double, claims: [(pocket: Int, row: Int, phantom: Int)])] {
        var rows: [(weight: Double, claims: [(pocket: Int, row: Int, phantom: Int)])] = []
        for i in 0..<count {
            let rowOffset = 8 + i * 40
            let weightPtr = f.shm.advanced(by: rowOffset).bindMemory(to: Double.self, capacity: 1)
            let weight = weightPtr[0]
            let nClaimsPtr = f.shm.advanced(by: rowOffset + 8).bindMemory(to: UInt32.self, capacity: 1)
            let nClaims = Int(nClaimsPtr[0])
            var claims: [(pocket: Int, row: Int, phantom: Int)] = []
            for slot in 0..<nClaims {
                let slotPtr = f.shm.advanced(by: rowOffset + 16 + slot * 4).bindMemory(to: UInt8.self, capacity: 4)
                claims.append((Int(slotPtr[0]), Int(slotPtr[1]), Int(slotPtr[2])))
            }
            rows.append((weight, claims))
        }
        return rows
    }

    // MARK: - ALARM LOAD: errors

    func testAlarmLoadNonexistentPathIsIOError() throws {
        let f = try HandlerFixture(side: 10)
        let reply = f.handler.handle("ALARM LOAD /nonexistent.json")
        XCTAssertTrue(reply.hasPrefix("ERROR io"), reply)
    }

    func testAlarmLoadPathOutsideDataRootIsIOError() throws {
        let f = try HandlerFixture(side: 10, dataRoot: tmpDir)
        let reply = f.handler.handle("ALARM LOAD /etc/dagdb-alarm-escape.json")
        XCTAssertTrue(reply.hasPrefix("ERROR io"), reply)
        XCTAssertTrue(reply.contains("outside DAGDB_DATA_ROOT"), reply)
    }

    func testAlarmLoadWrongSHAIsIOErrorContainingMismatch() throws {
        let path = try writeSyntheticFixture(in: tmpDir)
        let f = try HandlerFixture(side: 10, dataRoot: tmpDir)
        let reply = f.handler.handle("ALARM LOAD \(path) SHA not-a-real-sha")
        XCTAssertTrue(reply.hasPrefix("ERROR io"), reply)
        XCTAssertTrue(reply.contains("sha256 mismatch"), reply)
        XCTAssertNil(f.handler.twin.alarms.get("a00000001"))
    }

    // MARK: - ALARM LOAD: synthetic success

    @discardableResult
    private func loadSynthetic(_ f: HandlerFixture) throws -> String {
        let path = try writeSyntheticFixture(in: tmpDir)
        let reply = f.handler.handle("ALARM LOAD \(path)")
        XCTAssertTrue(reply.hasPrefix("OK ALARM LOAD id=a00000001"), reply)
        return reply
    }

    func testAlarmLoadSyntheticRecordsAndControl() throws {
        let f = try HandlerFixture(side: 10, dataRoot: tmpDir)
        let reply = try loadSynthetic(f)
        XCTAssertTrue(reply.contains("records=5 control=1"), reply)
        XCTAssertTrue(reply.contains("quiet=2 liar=1 deep=1 drift=1"), reply)
        XCTAssertTrue(reply.contains("ears=A0/B1/C0"), reply)
    }

    func testAlarmInfoListClose() throws {
        let f = try HandlerFixture(side: 10, dataRoot: tmpDir)
        _ = try loadSynthetic(f)

        let info = f.handler.handle("ALARM INFO a00000001")
        XCTAssertTrue(info.contains("records=5"), info)
        XCTAssertTrue(info.contains("id=a00000001"), info)

        XCTAssertTrue(f.handler.handle("ALARM LIST").contains("a00000001"))

        XCTAssertEqual(f.handler.handle("ALARM CLOSE a00000001"), "OK ALARM CLOSE id=a00000001")
        XCTAssertTrue(f.handler.handle("ALARM INFO a00000001").hasPrefix("ERROR not_found"))
        XCTAssertEqual(f.handler.handle("ALARM LIST"), "OK ALARM LIST count=0")
    }

    // MARK: - ALARM FRAME

    func testAlarmFrameLiarBEar() throws {
        let f = try HandlerFixture(side: 10, dataRoot: tmpDir)
        _ = try loadSynthetic(f)

        let reply = f.handler.handle("ALARM FRAME a00000001 3")
        XCTAssertTrue(reply.contains("class=liar"), reply)
        XCTAssertTrue(reply.contains("ear=B"), reply)
        XCTAssertTrue(reply.contains("label=liar_B"), reply)
        XCTAssertTrue(reply.contains("pocket=5"), reply)
        XCTAssertTrue(reply.contains("burst=0"), reply)
    }

    func testAlarmFrameOutOfRange() throws {
        let f = try HandlerFixture(side: 10, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        XCTAssertTrue(f.handler.handle("ALARM FRAME a00000001 0").hasPrefix("ERROR out_of_range"))
        XCTAssertTrue(f.handler.handle("ALARM FRAME a00000001 6").hasPrefix("ERROR out_of_range"))
    }

    // MARK: - ALARM CORRUPT

    func testAlarmCorruptOutcomesWeightSumAndShmRows() throws {
        let f = try HandlerFixture(side: 10, dataRoot: tmpDir)
        _ = try loadSynthetic(f)

        let reply = f.handler.handle("ALARM CORRUPT a00000001 3 0.5 0 1")
        XCTAssertTrue(reply.contains("outcomes=48"), reply)
        XCTAssertTrue(reply.contains("weight_sum=1.0"), reply)
        XCTAssertTrue(reply.contains("shm_bytes=1920"), reply)

        let model = try CorruptionModel(epsM: 0.5, epsS: 0, epsN: 1)
        let expected = model.enumerateOutcomes(for: .liar(.B))
        XCTAssertEqual(expected.count, 48)

        let rows = readCorruptionRows(f, count: expected.count)
        XCTAssertEqual(rows.count, expected.count)
        for (row, outcome) in zip(rows, expected) {
            XCTAssertEqual(row.weight, outcome.weight)
            XCTAssertEqual(row.claims.count, outcome.claims.count)
            for (got, want) in zip(row.claims, outcome.claims) {
                XCTAssertEqual(got.pocket, want.pocket)
                XCTAssertEqual(got.row, want.row == .L ? 0 : 1)
                XCTAssertEqual(got.phantom, want.isPhantom ? 1 : 0)
            }
        }
    }

    func testAlarmCorruptBadEpsIsBadValue() throws {
        let f = try HandlerFixture(side: 10, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        XCTAssertTrue(f.handler.handle("ALARM CORRUPT a00000001 3 2.0 0 0").hasPrefix("ERROR bad_value"))
    }

    // MARK: - ALARM SUCCESSOR

    func testAlarmSuccessorBadEpsIsBadValue() throws {
        let f = try HandlerFixture(side: 10, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        XCTAssertTrue(f.handler.handle("ALARM SUCCESSOR a00000001 100 -0.5 0 0").hasPrefix("ERROR bad_value"))
    }

    // MARK: - ALARM COURT: matches in-test AllocatorCourt.run

    func testAlarmCourtMatchesAllocatorCourtRun() throws {
        let f = try HandlerFixture(side: 10, dataRoot: tmpDir)
        _ = try loadSynthetic(f)
        let budget = SealedCourt.budgetGrid[0].budget

        let reply = f.handler.handle("ALARM COURT a00000001 \(budget)")

        let set = f.handler.twin.alarms.get("a00000001")!
        let arms = AllocatorCourt.run(records: set.fixture.records, budget: budget)
        let result = arms[.allocator]!
        let expected = "OK ALARM COURT id=a00000001 B=\(budget) misses=\(result.misses) served=\(result.served) " +
            "cost=\(result.cost) dummy=\(result.dummy) dominated=\(result.dominated) " +
            "burst=\(result.burst.served)/\(result.burst.missed)/\(result.burst.total)"
        XCTAssertEqual(reply, expected)
    }

    // MARK: - SAVE / LOAD round-trip by reference

    func testSaveLoadRoundTripsAlarmByReference() throws {
        let f1 = try HandlerFixture(side: 10, dataRoot: tmpDir)
        _ = try loadSynthetic(f1)

        let snapPath = tmpDir + "snap.dags"
        let saveReply = f1.handler.handle("SAVE \(snapPath)")
        XCTAssertTrue(saveReply.hasPrefix("OK SAVE"), saveReply)

        let f2 = try HandlerFixture(side: 10, dataRoot: tmpDir)
        let loadReply = f2.handler.handle("LOAD \(snapPath)")
        XCTAssertTrue(loadReply.hasPrefix("OK LOAD"), loadReply)

        XCTAssertEqual(f1.handler.handle("ALARM INFO a00000001"), f2.handler.handle("ALARM INFO a00000001"))
    }

    // MARK: - WAL replay

    func testWalReplayReloadsAlarm() throws {
        let path = try writeSyntheticFixture(in: tmpDir)
        let walPath = tmpDir + "twin.wal"
        let appender = try DagDBWAL.Appender(path: walPath, nodeCount: 100)
        let f = try HandlerFixture(side: 10, dataRoot: tmpDir, wal: appender)

        let reply = f.handler.handle("ALARM LOAD \(path)")
        XCTAssertTrue(reply.hasPrefix("OK ALARM LOAD id=a00000001"), reply)

        let fresh = TwinState()
        let grid = HexGrid(width: 10, height: 10)
        let state = DagDBState(width: 10, height: 10)
        let freshEngine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        _ = try DagDBWAL.replay(engine: freshEngine, nodeCount: freshEngine.nodeCount, path: walPath, twin: fresh)

        guard let set = fresh.alarms.get("a00000001") else {
            return XCTFail("replay did not restore a00000001")
        }
        XCTAssertEqual(set.fixture.records.count, 5)
        XCTAssertEqual(set.ref.path, path)
    }

    // MARK: - Sealed fixture (skipped without DAGDB_W2_FIXTURE)

    private func sealedPathOrSkip() throws -> String {
        guard let path = AlarmFixture.envPath else {
            throw XCTSkip("DAGDB_W2_FIXTURE not set — sealed gate skipped")
        }
        return path
    }

    func testSealedAlarmLoad() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 10, dataRoot: root)
        let reply = f.handler.handle("ALARM LOAD \(path) SHA \(AlarmFixture.sealedSHA256)")
        XCTAssertTrue(reply.hasPrefix("OK ALARM LOAD id=a00000001"), reply)
        XCTAssertTrue(reply.contains("records=200"), reply)
        XCTAssertTrue(reply.contains("control=1"), reply)
        XCTAssertTrue(reply.contains("ears=A17/B17/C16"), reply)
    }

    func testSealedAlarmCourt() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 10, dataRoot: root)
        _ = f.handler.handle("ALARM LOAD \(path) SHA \(AlarmFixture.sealedSHA256)")

        let reply = f.handler.handle("ALARM COURT a00000001 16164.352484758914")
        XCTAssertTrue(reply.contains("misses=0"), reply)
        XCTAssertTrue(reply.contains("served=150"), reply)
        XCTAssertTrue(reply.contains("cost=819218.0"), reply)
        XCTAssertTrue(reply.contains("burst=116/0/116"), reply)
    }

    func testSealedAlarmSuccessor() throws {
        let path = try sealedPathOrSkip()
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 10, dataRoot: root)
        _ = f.handler.handle("ALARM LOAD \(path) SHA \(AlarmFixture.sealedSHA256)")

        let reply = f.handler.handle("ALARM SUCCESSOR a00000001 13491.480553724456 0.25 0 0")
        XCTAssertTrue(reply.contains("misses_alloc=25.25"), reply)
        XCTAssertTrue(reply.contains("misses_greedy=25.25"), reply)
        XCTAssertTrue(reply.contains("cost_alloc=561907.5"), reply)
    }
}
