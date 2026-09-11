import XCTest
@testable import DagDB

/// the interface phase — NpzReader. Synthetic `.npz` archives are written by `python3`
/// (numpy present in this environment) so the reader is exercised against
/// what `np.savez`/`np.savez_compressed` actually produce, not a
/// hand-rolled zip. Whole class skips if `python3 -c "import numpy"` fails.
final class NpzReaderTests: XCTestCase {

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
            throw XCTSkip("python3 with numpy not available — NpzReader synthetic fixtures skipped")
        }

        tmpDir = NSTemporaryDirectory() + "dagdb-npz-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    @discardableResult
    private func runPython(_ code: String) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", code]
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// a: (3,4) f32 arange; b: (2,) f64 [1.5,-2.5]; c: scalar i8 (7);
    /// d: scalar f8 (3.25); e: (2,2) i8.
    private func writeSyntheticNpz() throws -> String {
        let path = tmpDir + "t.npz"
        let code = """
        import numpy as np
        np.savez(r'\(path)',
                 a=np.arange(12, dtype=np.float32).reshape(3, 4),
                 b=np.array([1.5, -2.5]),
                 c=np.int64(7),
                 d=np.array(3.25),
                 e=np.array([[1, 2], [3, 4]], dtype=np.int64))
        """
        let status = try runPython(code)
        XCTAssertEqual(status, 0, "python3 failed to write synthetic npz")
        return path
    }

    // MARK: - Entry names / shapes

    func testEntryNamesAndShapes() throws {
        let path = try writeSyntheticNpz()
        let entries = try NpzReader.entries(path: path)

        XCTAssertEqual(Set(entries.keys), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(entries["a"]?.shape, [3, 4])
        XCTAssertEqual(entries["b"]?.shape, [2])
        XCTAssertEqual(entries["c"]?.shape, [])
        XCTAssertEqual(entries["d"]?.shape, [])
        XCTAssertEqual(entries["e"]?.shape, [2, 2])
        for e in entries.values {
            XCTAssertFalse(e.fortranOrder)
        }
    }

    func testFloat32ValuesCOrder() throws {
        let path = try writeSyntheticNpz()
        let entries = try NpzReader.entries(path: path)
        let a = try NpzReader.float32(entries["a"]!)
        XCTAssertEqual(a, (0..<12).map { Float($0) })
    }

    func testFloat64ArrayB() throws {
        let path = try writeSyntheticNpz()
        let entries = try NpzReader.entries(path: path)
        let b = try NpzReader.float64(entries["b"]!)
        XCTAssertEqual(b, [1.5, -2.5])
    }

    func testInt64ScalarC() throws {
        let path = try writeSyntheticNpz()
        let entries = try NpzReader.entries(path: path)
        let c = try NpzReader.int64(entries["c"]!)
        XCTAssertEqual(c, [7])
        XCTAssertEqual(entries["c"]?.shape, [])
    }

    func testFloat64ScalarD() throws {
        let path = try writeSyntheticNpz()
        let entries = try NpzReader.entries(path: path)
        let d = try NpzReader.float64(entries["d"]!)
        XCTAssertEqual(d, [3.25])
    }

    func testInt64ArrayE() throws {
        let path = try writeSyntheticNpz()
        let entries = try NpzReader.entries(path: path)
        let e = try NpzReader.int64(entries["e"]!)
        XCTAssertEqual(e, [1, 2, 3, 4])
    }

    func testFloat32OnIntArrayThrowsBadDType() throws {
        let path = try writeSyntheticNpz()
        let entries = try NpzReader.entries(path: path)
        do {
            _ = try NpzReader.float32(entries["e"]!)
            XCTFail("expected badDType")
        } catch let NpzReader.NpzError.badDType(actual, expected) {
            XCTAssertEqual(actual, "<i8")
            XCTAssertEqual(expected, "<f4")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMissingKeyIsNil() throws {
        let path = try writeSyntheticNpz()
        let entries = try NpzReader.entries(path: path)
        XCTAssertNil(entries["nonexistent"])
    }

    // MARK: - Compressed / malformed archives

    func testCompressedNpzThrows() throws {
        let path = tmpDir + "compressed.npz"
        let code = """
        import numpy as np
        np.savez_compressed(r'\(path)', a=np.arange(12, dtype=np.float32).reshape(3, 4))
        """
        let status = try runPython(code)
        XCTAssertEqual(status, 0, "python3 failed to write compressed npz")

        do {
            _ = try NpzReader.entries(path: path)
            XCTFail("expected compressed error")
        } catch let NpzReader.NpzError.compressed(name) {
            XCTAssertTrue(name.hasSuffix("a.npy"), "\(name)")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testNonZipFileThrowsNotZip() throws {
        let path = tmpDir + "notazip.npz"
        try Data("this is not a zip file at all, just plain text bytes".utf8).write(to: URL(fileURLWithPath: path))
        do {
            _ = try NpzReader.entries(path: path)
            XCTFail("expected notZip")
        } catch NpzReader.NpzError.notZip {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTruncatedFileNeverCrashes() throws {
        let path = try writeSyntheticNpz()
        let full = try Data(contentsOf: URL(fileURLWithPath: path))
        let truncated = full.prefix(full.count / 2)
        let truncPath = tmpDir + "truncated.npz"
        try Data(truncated).write(to: URL(fileURLWithPath: truncPath))

        do {
            _ = try NpzReader.entries(path: truncPath)
            // If it didn't throw, that's acceptable only if it somehow
            // still produced a consistent (if empty) result — the
            // instrument is "never crash", not "must throw".
        } catch NpzReader.NpzError.truncated {
            // expected
        } catch NpzReader.NpzError.notZip {
            // also acceptable — EOCD may not be found in the truncated half
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
