import XCTest
@testable import DagDB

/// the interface phase — CortexFixture loader over the derived-views cortex v4 world
/// fixture. Synthetic-fixture tests exercise the loader's structural
/// asserts without the sealed file; sealed-fixture tests replay the real
/// `cortex_v4_world.npz` and skip (XCTSkip) when `DAGDB_CORTEX_V4_FIXTURE`
/// is unset — precedent `AlarmFixtureTests.swift`.
final class CortexFixtureTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        check.arguments = ["python3", "-c", "import numpy"]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        try check.run()
        check.waitUntilExit()
        guard check.terminationStatus == 0 else {
            throw XCTSkip("python3 with numpy not available — CortexFixture synthetic fixtures skipped")
        }

        tmpDir = NSTemporaryDirectory() + "dagdb-cortex-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    /// Full key set, right shapes/dtypes everywhere except M = 8
    /// (2 classes x 4) where the sealed contract fixes 129*54 = 6966.
    private func writeSyntheticFixture(trainCount: Int = 8, named name: String = "mini.npz") throws -> String {
        let path = tmpDir + name
        let code = """
        import numpy as np
        M = \(trainCount)
        y_train = (np.arange(M) // 4) % 129
        np.savez(r'\(path)',
                 X_train=np.zeros((M, 8, 64), dtype=np.float32),
                 Y_train=y_train.astype(np.int64),
                 X_test=np.zeros((300, 8, 64), dtype=np.float32),
                 Y_test=np.zeros(300, dtype=np.int64),
                 TAU=np.zeros((129, 8), dtype=np.float64),
                 TAU_raw=np.zeros((129, 8), dtype=np.float64),
                 SCAN=np.arange(8, dtype=np.int64),
                 CAND=np.arange(129, dtype=np.int64),
                 SPEED=np.float64(2646.5),
                 dt=np.float64(4.1666666666666665e-05),
                 OS=np.int64(8),
                 FS=np.float64(3000.0))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", code]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "python3 failed to write synthetic cortex fixture")
        return path
    }

    // MARK: - Synthetic structural asserts

    func testWrongTrainCountThrowsBadLayout() throws {
        let path = try writeSyntheticFixture(trainCount: 8)
        do {
            _ = try CortexFixture.load(path: path, expectedSHA256: nil)
            XCTFail("expected badLayout for M != 129*54")
        } catch CortexFixture.FixtureError.badLayout(let msg) {
            XCTAssertTrue(msg.contains("8"), "\(msg)")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testWrongSHAThrowsMismatch() throws {
        let path = try writeSyntheticFixture()
        do {
            _ = try CortexFixture.load(path: path, expectedSHA256: "not-a-real-sha")
            XCTFail("expected shaMismatch")
        } catch let CortexFixture.FixtureError.shaMismatch(expected, actual) {
            XCTAssertEqual(expected, "not-a-real-sha")
            XCTAssertNotEqual(actual, "not-a-real-sha")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMissingFileThrowsFileNotFound() {
        let path = tmpDir + "does-not-exist.npz"
        do {
            _ = try CortexFixture.load(path: path, expectedSHA256: nil)
            XCTFail("expected fileNotFound")
        } catch let CortexFixture.FixtureError.fileNotFound(p) {
            XCTAssertEqual(p, path)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Sealed fixture (skipped without DAGDB_CORTEX_V4_FIXTURE)

    private func loadSealedOrSkip() throws -> CortexFixture {
        guard let path = CortexFixture.envPath else {
            throw XCTSkip("DAGDB_CORTEX_V4_FIXTURE not set — sealed cortex gate skipped")
        }
        return try CortexFixture.load(path: path, expectedSHA256: CortexFixture.sealedSHA256)
    }

    func testSealedFixtureShaAndCounts() throws {
        let fixture = try loadSealedOrSkip()
        XCTAssertEqual(fixture.sha256, CortexFixture.sealedSHA256)
        XCTAssertEqual(fixture.stations, 8)
        XCTAssertEqual(fixture.samples, 64)
        XCTAssertEqual(fixture.candidates, 129)
        XCTAssertEqual(fixture.trainCount, 6966)
        XCTAssertEqual(fixture.testCount, 300)
        print("sealed cortex fixture: sha=\(fixture.sha256) train=\(fixture.trainCount) test=\(fixture.testCount)")
    }

    func testSealedFixtureScanAndTestLabels() throws {
        let fixture = try loadSealedOrSkip()
        XCTAssertEqual(fixture.scan, [18, 25, 42, 48, 63, 74, 94, 129])
        XCTAssertEqual(Array(fixture.yTest[0..<8]), [89, 92, 95, 23, 106, 114, 93, 59])
    }

    func testSealedFixtureWorldConstants() throws {
        let fixture = try loadSealedOrSkip()
        XCTAssertEqual(fixture.speed, 2646.524320434243)
        XCTAssertEqual(fixture.dt, 4.1666666666666665e-05)
        XCTAssertEqual(fixture.os, 8)
        XCTAssertEqual(fixture.fs, 3000)
        print("sealed cortex fixture: speed=\(fixture.speed) dt=\(fixture.dt) os=\(fixture.os) fs=\(fixture.fs)")
    }

    func testSealedFixtureEveryClassHas54TrainFrames() throws {
        let fixture = try loadSealedOrSkip()
        var counts = [Int](repeating: 0, count: 129)
        for y in fixture.yTrain {
            counts[y] += 1
        }
        XCTAssertTrue(counts.allSatisfy { $0 == 54 }, "\(counts.filter { $0 != 54 })")
    }

    func testSealedFixtureFrameSlicing() throws {
        let fixture = try loadSealedOrSkip()
        let frame0 = fixture.frame(test: 0)
        XCTAssertEqual(frame0.count, fixture.stations)
        for row in frame0 {
            XCTAssertEqual(row.count, fixture.samples)
        }
        for s in 0..<fixture.stations {
            let base = s * fixture.samples
            let expected = Array(fixture.xTest[base..<(base + fixture.samples)])
            XCTAssertEqual(frame0[s], expected)
        }
    }

    func testSealedFixtureTauNormalization() throws {
        let fixture = try loadSealedOrSkip()
        let globalMax = fixture.tauRaw.max()!
        print("sealed cortex fixture: global TAU_raw max = \(globalMax)")

        for i in 0..<8 {
            let expected = fixture.tauRaw[i] / globalMax
            let actual = fixture.tau[i]
            let relError = expected == 0 ? abs(actual - expected) : abs(actual - expected) / abs(expected)
            XCTAssertLessThan(relError, 1e-12, "index \(i): tau=\(actual) expected=\(expected)")
        }
    }
}
