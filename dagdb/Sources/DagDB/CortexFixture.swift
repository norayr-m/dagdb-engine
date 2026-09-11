import Foundation

/// Loader for the sealed cortex v4 world fixture (`cortex_v4_world.npz`) —
/// derived-views spec line 4, second view family. By-reference, out of
/// repo, SHA-pinned; read only from `DAGDB_CORTEX_V4_FIXTURE`.
/// Contract: `docs/contracts/DERIVED_VIEWS_GATES_FROZEN.md`, prior-work
/// paragraph and rulings (a) and (c).
public struct CortexFixture {
    public static let envVar = "DAGDB_CORTEX_V4_FIXTURE"
    public static let sealedSHA256 =
        "7d732e58a4e68fc7c6357ce75346984b39aec1d71c4dccd4c76a666543890bc2"

    public static var envPath: String? {
        ProcessInfo.processInfo.environment[envVar]
    }

    public let path: String
    public let sha256: String

    public let stations: Int
    public let samples: Int
    public let candidates: Int

    /// C-order [m][s][t], flattened.
    public let xTrain: [Float]
    public let yTrain: [Int]
    /// C-order [m][s][t], flattened.
    public let xTest: [Float]
    public let yTest: [Int]

    /// 129 x 8, row-major.
    public let tau: [Double]
    /// 129 x 8, row-major.
    public let tauRaw: [Double]

    public let scan: [Int]
    public let cand: [Int]

    public let speed: Double
    public let dt: Double
    public let os: Int
    public let fs: Double

    public var trainCount: Int { yTrain.count }
    public var testCount: Int { yTest.count }

    public func frame(test m: Int) -> [[Float]] {
        frame(flat: xTest, m: m)
    }

    public func frame(train m: Int) -> [[Float]] {
        frame(flat: xTrain, m: m)
    }

    private func frame(flat: [Float], m: Int) -> [[Float]] {
        var rows: [[Float]] = []
        rows.reserveCapacity(stations)
        let frameBase = m * stations * samples
        for s in 0..<stations {
            let base = frameBase + s * samples
            rows.append(Array(flat[base..<(base + samples)]))
        }
        return rows
    }

    public enum FixtureError: Error, Equatable {
        case fileNotFound(String)
        case shaMismatch(expected: String, actual: String)
        case badLayout(String)
    }

    public static func load(path: String, expectedSHA256: String?) throws -> CortexFixture {
        guard FileManager.default.fileExists(atPath: path) else {
            throw FixtureError.fileNotFound(path)
        }
        let fileData = try Data(contentsOf: URL(fileURLWithPath: path))
        let actualSHA = DagDBSnapshot.sha256Hex(fileData)
        if let expected = expectedSHA256, expected != actualSHA {
            throw FixtureError.shaMismatch(expected: expected, actual: actualSHA)
        }

        let entries: [String: NpzReader.Entry]
        do {
            entries = try NpzReader.entries(path: path)
        } catch {
            throw FixtureError.badLayout("npz read failed: \(error)")
        }

        func entry(_ name: String) throws -> NpzReader.Entry {
            guard let e = entries[name] else {
                throw FixtureError.badLayout("missing key '\(name)'")
            }
            return e
        }

        func assertShape(_ e: NpzReader.Entry, _ expected: [Int], _ label: String) throws {
            guard e.shape == expected else {
                throw FixtureError.badLayout("\(label): shape \(e.shape) != expected \(expected)")
            }
        }

        func f32(_ e: NpzReader.Entry, _ label: String) throws -> [Float] {
            do { return try NpzReader.float32(e) } catch {
                throw FixtureError.badLayout("\(label): \(error)")
            }
        }
        func f64(_ e: NpzReader.Entry, _ label: String) throws -> [Double] {
            do { return try NpzReader.float64(e) } catch {
                throw FixtureError.badLayout("\(label): \(error)")
            }
        }
        func i64(_ e: NpzReader.Entry, _ label: String) throws -> [Int64] {
            do { return try NpzReader.int64(e) } catch {
                throw FixtureError.badLayout("\(label): \(error)")
            }
        }

        // X_train / Y_train
        let xTrainEntry = try entry("X_train")
        guard xTrainEntry.shape.count == 3, xTrainEntry.shape[1] == 8, xTrainEntry.shape[2] == 64 else {
            throw FixtureError.badLayout("X_train: shape \(xTrainEntry.shape) != expected [M, 8, 64]")
        }
        let m = xTrainEntry.shape[0]
        let xTrainRaw = try f32(xTrainEntry, "X_train")

        let yTrainEntry = try entry("Y_train")
        try assertShape(yTrainEntry, [m], "Y_train")
        let yTrainRaw = try i64(yTrainEntry, "Y_train")

        // X_test / Y_test
        let xTestEntry = try entry("X_test")
        try assertShape(xTestEntry, [300, 8, 64], "X_test")
        let xTestRaw = try f32(xTestEntry, "X_test")

        let yTestEntry = try entry("Y_test")
        try assertShape(yTestEntry, [300], "Y_test")
        let yTestRaw = try i64(yTestEntry, "Y_test")

        // TAU / TAU_raw
        let tauEntry = try entry("TAU")
        try assertShape(tauEntry, [129, 8], "TAU")
        let tauRaw64 = try f64(tauEntry, "TAU")

        let tauRawEntry = try entry("TAU_raw")
        try assertShape(tauRawEntry, [129, 8], "TAU_raw")
        let tauRawRaw64 = try f64(tauRawEntry, "TAU_raw")

        // SCAN / CAND
        let scanEntry = try entry("SCAN")
        try assertShape(scanEntry, [8], "SCAN")
        let scanRaw = try i64(scanEntry, "SCAN")

        let candEntry = try entry("CAND")
        try assertShape(candEntry, [129], "CAND")
        let candRaw = try i64(candEntry, "CAND")

        // Scalars: SPEED, dt, FS (f8) and OS (i8)
        let speedEntry = try entry("SPEED")
        try assertShape(speedEntry, [], "SPEED")
        let speedVal = try f64(speedEntry, "SPEED")[0]

        let dtEntry = try entry("dt")
        try assertShape(dtEntry, [], "dt")
        let dtVal = try f64(dtEntry, "dt")[0]

        let fsEntry = try entry("FS")
        try assertShape(fsEntry, [], "FS")
        let fsVal = try f64(fsEntry, "FS")[0]
        guard fsVal == 3000 else {
            throw FixtureError.badLayout("FS: \(fsVal) != 3000")
        }

        let osEntry = try entry("OS")
        try assertShape(osEntry, [], "OS")
        let osVal = try i64(osEntry, "OS")[0]
        guard osVal == 8 else {
            throw FixtureError.badLayout("OS: \(osVal) != 8")
        }

        // Label range checks.
        for y in yTrainRaw {
            guard y >= 0, y < 129 else {
                throw FixtureError.badLayout("Y_train contains out-of-range label \(y)")
            }
        }
        for y in yTestRaw {
            guard y >= 0, y < 129 else {
                throw FixtureError.badLayout("Y_test contains out-of-range label \(y)")
            }
        }

        // M == 129*54, every class has exactly 54 train frames.
        guard m == 129 * 54 else {
            throw FixtureError.badLayout("X_train frame count \(m) != 129*54 (\(129 * 54))")
        }
        var classCounts = [Int](repeating: 0, count: 129)
        for y in yTrainRaw {
            classCounts[Int(y)] += 1
        }
        for c in 0..<129 {
            guard classCounts[c] == 54 else {
                throw FixtureError.badLayout("class \(c) has \(classCounts[c]) train frames, expected 54")
            }
        }

        return CortexFixture(
            path: path,
            sha256: actualSHA,
            stations: 8,
            samples: 64,
            candidates: 129,
            xTrain: xTrainRaw,
            yTrain: yTrainRaw.map { Int($0) },
            xTest: xTestRaw,
            yTest: yTestRaw.map { Int($0) },
            tau: tauRaw64,
            tauRaw: tauRawRaw64,
            scan: scanRaw.map { Int($0) },
            cand: candRaw.map { Int($0) },
            speed: speedVal,
            dt: dtVal,
            os: Int(osVal),
            fs: fsVal
        )
    }
}
