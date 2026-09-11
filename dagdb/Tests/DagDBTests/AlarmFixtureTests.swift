import XCTest
@testable import DagDB

/// the interface phase — AlarmFixture loader. The synthetic-fixture tests exercise the
/// loader without the sealed file; the sealed-fixture tests replay the
/// real 201-entry `w2_records.json` and skip (XCTSkip) when
/// `DAGDB_W2_FIXTURE` is unset — precedent `DagDBTickPerfTests.swift:206`.
final class AlarmFixtureTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-alarm-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - Synthetic mini-fixture

    /// quiet_1, quiet_2, liar_1 (ear B), deep_1, drift_1, cal0_1 — each
    /// with 4-sample a/b/c waveform arrays.
    private func writeSyntheticFixture(named name: String = "mini.json") throws -> String {
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
        return path
    }

    func testSyntheticFixtureOrderIdxAndControl() throws {
        let path = try writeSyntheticFixture()
        let fixture = try AlarmFixture.load(path: path, expectedSHA256: nil)

        XCTAssertEqual(fixture.records.count, 5)
        let byIndex = fixture.records.sorted { $0.index < $1.index }
        XCTAssertEqual(byIndex.map(\.key), ["quiet_1", "quiet_2", "liar_1", "deep_1", "drift_1"])
        XCTAssertEqual(byIndex.map(\.index), [1, 2, 3, 4, 5])

        XCTAssertEqual(fixture.control?.key, "cal0_1")
        XCTAssertEqual(fixture.control?.rawClass, "cal0")

        XCTAssertFalse(fixture.sealedStops().isEmpty)
    }

    func testSyntheticFixtureWrongSHAThrowsMismatch() throws {
        let path = try writeSyntheticFixture()
        do {
            _ = try AlarmFixture.load(path: path, expectedSHA256: "not-a-real-sha")
            XCTFail("expected shaMismatch")
        } catch let AlarmFixture.FixtureError.shaMismatch(expected, actual) {
            XCTAssertEqual(expected, "not-a-real-sha")
            XCTAssertNotEqual(actual, "not-a-real-sha")
        }
    }

    func testMissingFileThrowsFileNotFound() {
        let path = tmpDir + "does-not-exist.json"
        do {
            _ = try AlarmFixture.load(path: path, expectedSHA256: nil)
            XCTFail("expected fileNotFound")
        } catch let AlarmFixture.FixtureError.fileNotFound(p) {
            XCTAssertEqual(p, path)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testUnknownClassThrows() throws {
        let obj: [String: Any] = [
            "quiet_1": ["class": "mystery"],
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        let path = tmpDir + "bogus.json"
        try data.write(to: URL(fileURLWithPath: path))

        do {
            _ = try AlarmFixture.load(path: path, expectedSHA256: nil)
            XCTFail("expected unknownClass")
        } catch let AlarmFixture.FixtureError.unknownClass(key, value) {
            XCTAssertEqual(key, "quiet_1")
            XCTAssertEqual(value, "mystery")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testIncludeWaveformsPopulatesFourFloats() throws {
        let path = try writeSyntheticFixture()
        let fixture = try AlarmFixture.load(path: path, expectedSHA256: nil, includeWaveforms: true)
        let quiet1 = fixture.records.first { $0.key == "quiet_1" }
        XCTAssertEqual(quiet1?.waveforms?.a, [0, 1, 2, 3])
        XCTAssertEqual(quiet1?.waveforms?.b, [10, 11, 12, 13])
        XCTAssertEqual(quiet1?.waveforms?.c, [20, 21, 22, 23])
    }

    func testWaveformsNilWithoutIncludeFlag() throws {
        let path = try writeSyntheticFixture()
        let fixture = try AlarmFixture.load(path: path, expectedSHA256: nil)
        XCTAssertTrue(fixture.records.allSatisfy { $0.waveforms == nil })
    }

    // MARK: - Sealed fixture (skipped without DAGDB_W2_FIXTURE)

    private func loadSealedOrSkip() throws -> AlarmFixture {
        guard let path = AlarmFixture.envPath else {
            throw XCTSkip("DAGDB_W2_FIXTURE not set — sealed gate skipped")
        }
        return try AlarmFixture.load(path: path, expectedSHA256: AlarmFixture.sealedSHA256)
    }

    func testSealedFixtureSHAAndCount() throws {
        let fixture = try loadSealedOrSkip()
        XCTAssertEqual(fixture.sha256, AlarmFixture.sealedSHA256)
        XCTAssertEqual(fixture.records.count, 200)
    }

    func testSealedFixtureNoStops() throws {
        let fixture = try loadSealedOrSkip()
        XCTAssertTrue(fixture.sealedStops().isEmpty, "\(fixture.sealedStops())")
    }

    func testSealedFixtureClassCountsMatchSealedCourt() throws {
        let fixture = try loadSealedOrSkip()
        XCTAssertEqual(fixture.classCounts, SealedCourt.classCounts)
    }

    func testSealedFixtureBoundaryRecords() throws {
        let fixture = try loadSealedOrSkip()
        let byIndex = Dictionary(uniqueKeysWithValues: fixture.records.map { ($0.index, $0) })

        let quiet1 = byIndex[1]!
        XCTAssertEqual(quiet1.key, "quiet_1")
        XCTAssertNil(quiet1.claim)

        let liar1 = byIndex[51]!
        XCTAssertEqual(liar1.key, "liar_1")
        XCTAssertEqual(liar1.ear, .A)
        XCTAssertEqual(liar1.pocket, 3)

        let deep1 = byIndex[101]!
        XCTAssertEqual(deep1.key, "deep_1")
        XCTAssertEqual(deep1.pocket, 6)
        XCTAssertTrue(deep1.isBurst)

        let drift1 = byIndex[151]!
        XCTAssertEqual(drift1.key, "drift_1")
        XCTAssertNil(drift1.ear)

        let drift50 = byIndex[200]!
        XCTAssertEqual(drift50.key, "drift_50")

        XCTAssertEqual(fixture.control?.key, "cal0_1")
    }
}
