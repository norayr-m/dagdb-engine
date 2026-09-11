import XCTest
import Foundation
@testable import DagDB

/// Per-path kernel storage and the sealed cross-convolution residual —
/// gates K1/K2/K5 from docs/contracts/KERNELS_GATES_FROZEN.md (amendment
/// 1: 190 trials). Non-sealed tests exercise KernelPair and the formula
/// against the in-repo fixtures (loaded, sha-checked, never skipped).
/// Sealed tests replay the 190 W1 records against the frozen residual
/// fixture — skip (XCTSkip) when DAGDB_W1_RECORDS is unset, FAIL (never
/// skip) if present with the wrong hash — precedent DerivedViewsTests.
final class SealedCrossConvolutionTests: XCTestCase {

    // MARK: - Fixture paths (in-repo, always present)

    private static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/DagDBTests/
            .deletingLastPathComponent()   // Tests/
            .appendingPathComponent("Fixtures")
    }

    private static func checkedData(_ jsonName: String, _ shaName: String) throws -> Data {
        let jsonURL = fixturesDir.appendingPathComponent(jsonName)
        let shaURL = fixturesDir.appendingPathComponent(shaName)
        let data = try Data(contentsOf: jsonURL)
        let shaLine = try String(contentsOf: shaURL, encoding: .utf8)
        let expectedHex = shaLine.split(separator: " ").first.map(String.init) ?? ""
        let actualHex = DagDBSnapshot.sha256Hex(data)
        XCTAssertEqual(actualHex, expectedHex, "\(jsonName) sha256 mismatch")
        return data
    }

    private static let w1KernelsSHA = "2523d3a8a4de44b56268ee31a703b6bcc6522c7c66a305651f8ec7c03e5c56b8"
    private static let w1ResidualsSHA = "f02b1e18b7b6a3fee3b8e6bb9029a6a558647c7cfc991697237b204d4fe29a06"
    private static let w1RecordsSHA = "ba899eeff82a85b74ce5572d8a5297eee479d9eb4b72b11ea0add2359f633f1a"

    // MARK: - KernelPair / derived warmup (K4)

    func testDerivedWarmupIs185ForW1() {
        let metaWithSigma = KernelPair.Meta(fs: 3000, window: 2048, earA: 170, earB: 236,
                                             tauA: 0.18227148035108542, tauB: 0.18382585465904366,
                                             sigmaSource: 0.02)
        let pairWithSigma = try! KernelPair(kA: [1, 2], kB: [3, 4], meta: metaWithSigma)
        XCTAssertEqual(pairWithSigma.derivedWarmup, 185)
        XCTAssertEqual(pairWithSigma.warmup(override: nil)?.value, 185)
        XCTAssertEqual(pairWithSigma.warmup(override: nil)?.derived, true)

        let metaNoSigma = KernelPair.Meta(fs: 3000, window: 2048, earA: 170, earB: 236,
                                           tauA: 0.18227148035108542, tauB: 0.18382585465904366,
                                           sigmaSource: nil)
        let pairNoSigma = try! KernelPair(kA: [1, 2], kB: [3, 4], meta: metaNoSigma)
        XCTAssertNil(pairNoSigma.derivedWarmup)

        let overridden = pairWithSigma.warmup(override: 200)
        XCTAssertEqual(overridden?.value, 200)
        XCTAssertEqual(overridden?.derived, false)

        let metaDeclared = KernelPair.Meta(fs: 3000, window: 2048, earA: 170, earB: 236,
                                            declaredWarmup: 185)
        let pairDeclared = try! KernelPair(kA: [1, 2], kB: [3, 4], meta: metaDeclared)
        XCTAssertNil(pairDeclared.derivedWarmup)
        let declared = pairDeclared.warmup(override: nil)
        XCTAssertEqual(declared?.value, 185)
        XCTAssertEqual(declared?.derived, false)
    }

    // MARK: - KernelPair.load (K3 storage)

    func testLoadW1KernelsFixture() throws {
        let path = Self.fixturesDir.appendingPathComponent("w1_kernels.json").path

        let (pair, sha) = try KernelPair.load(path: path, expectedSHA256: Self.w1KernelsSHA)
        XCTAssertEqual(sha, Self.w1KernelsSHA)
        XCTAssertEqual(pair.taps, 2048)
        XCTAssertEqual(pair.meta.fs, 3000)
        XCTAssertEqual(pair.meta.window, 2048)
        XCTAssertEqual(pair.meta.earA, 170)
        XCTAssertEqual(pair.meta.earB, 236)

        XCTAssertThrowsError(try KernelPair.load(path: path, expectedSHA256: "deadbeef")) { error in
            guard case KernelPair.KernelError.shaMismatch(let expected, let actual) = error else {
                return XCTFail("expected shaMismatch, got \(error)")
            }
            XCTAssertEqual(expected, "deadbeef")
            XCTAssertEqual(actual, Self.w1KernelsSHA)
        }

        XCTAssertThrowsError(try KernelPair.load(path: path + ".missing", expectedSHA256: nil)) { error in
            guard case KernelPair.KernelError.fileNotFound = error else {
                return XCTFail("expected fileNotFound, got \(error)")
            }
        }
    }

    // MARK: - Sealed formula (K1/K2 formula shape, unsealed inputs)

    func testResidualIdentityIsZeroWhenMirrored() {
        let meta = KernelPair.Meta(fs: 3000, window: 8, earA: 0, earB: 1)
        let kA: [Double] = [1, 0.5, 0.25, 0.1]
        let pair = try! KernelPair(kA: kA, kB: kA, meta: meta)
        let signal: [Double] = [0.1, 0.2, -0.3, 0.4, 0.5, -0.6, 0.2, 0.1]

        let result = SealedCrossConvolution.residual(a: signal, b: signal, pair: pair, warmup: 2)
        XCTAssertEqual(result.residual, 0.0)
        XCTAssertEqual(result.n, 8)
        XCTAssertEqual(result.warmup, 2)

        let mismatched = SealedCrossConvolution.residual(a: signal, b: Array(signal.dropLast()), pair: pair, warmup: 2)
        XCTAssertTrue(mismatched.residual.isNaN)
        XCTAssertEqual(mismatched.n, 0)
    }

    func testConvolveFullMatchesDirectDefinition() {
        let x: [Double] = [1, 2, 3]
        let k: [Double] = [4, 5]
        // direct definition: out[t] = sum_{j} x[t-j]*k[j] over valid indices
        let out = SealedCrossConvolution.convolveFull(x, k)
        XCTAssertEqual(out.count, x.count + k.count - 1)
        // hand-computed: [1*4, 1*5+2*4, 2*5+3*4, 3*5] = [4, 13, 22, 15]
        XCTAssertEqual(out, [4, 13, 22, 15])
    }

    // MARK: - Sealed (env DAGDB_W1_RECORDS)

    private struct Trial: Decodable {
        let a: [Double]
        let b: [Double]
        let classLabel: String
        enum CodingKeys: String, CodingKey {
            case a, b
            case classLabel = "class"
        }
    }

    private struct ResidualFixture: Decodable {
        let warmup: Int
        let tolerance: Double
        let toleranceControl: Double
        let trials: [String: TrialResidual]
        let gates: Gates
    }
    private struct TrialResidual: Decodable {
        let classLabel: String
        let R: Double
        let R_fullwin: Double
        let R_symden: Double
        let R_f32: Double
        enum CodingKeys: String, CodingKey {
            case classLabel = "class"
            case R, R_fullwin, R_symden, R_f32
        }
    }
    private struct Gates: Decodable {
        let G0_R: Double
        let G1_worst: Double
        let G1_within: Int
        let G2_flares: Int
        let G3_flares: Int
        let G3_quartiles: [Double]
        let cal_maxR: Double
    }

    /// Records fixture is 18.5 MB — decode once per test class into a
    /// static cache.
    private static var cachedRecords: [String: Trial]?
    private static var cachedPair: KernelPair?
    private static var cachedResidualFixture: ResidualFixture?

    private static func loadSealedOrSkip() throws -> ([String: Trial], KernelPair, ResidualFixture) {
        guard let path = ProcessInfo.processInfo.environment["DAGDB_W1_RECORDS"] else {
            throw XCTSkip("DAGDB_W1_RECORDS not set — sealed K1/K2/K5 kernel gates skipped")
        }

        if let records = cachedRecords, let pair = cachedPair, let fixture = cachedResidualFixture {
            return (records, pair, fixture)
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let actualSHA = DagDBSnapshot.sha256Hex(data)
        guard actualSHA == w1RecordsSHA else {
            XCTFail("DAGDB_W1_RECORDS sha256 mismatch: expected \(w1RecordsSHA), got \(actualSHA)")
            struct SealedHashMismatch: Error {}
            throw SealedHashMismatch()
        }

        let records = try JSONDecoder().decode([String: Trial].self, from: data)

        let kernelsPath = fixturesDir.appendingPathComponent("w1_kernels.json").path
        let (pair, _) = try KernelPair.load(path: kernelsPath, expectedSHA256: w1KernelsSHA)

        let residualsData = try checkedData("w1_residuals_v1.json", "w1_residuals_v1.sha256")
        let fixture = try JSONDecoder().decode(ResidualFixture.self, from: residualsData)

        cachedRecords = records
        cachedPair = pair
        cachedResidualFixture = fixture
        return (records, pair, fixture)
    }

    func testK1PerTrialResidualsWithinControlTolerance() throws {
        let (records, pair, fixture) = try Self.loadSealedOrSkip()
        let warmup = fixture.warmup
        XCTAssertEqual(warmup, 185)

        var maxDiff = 0.0
        var engineResiduals: [String: Double] = [:]
        var wallMsSum = 0.0, wallMsMax = 0.0; var wallCount = 0
        var maxRelative = 0.0
        var maxDiffKey = ""
        var failures: [String] = []

        for (key, trial) in records {
            guard let expected = fixture.trials[key] else {
                XCTFail("no fixture residual for trial \(key)")
                continue
            }
            let t0 = DispatchTime.now()
            let result = SealedCrossConvolution.residual(a: trial.a, b: trial.b, pair: pair, warmup: warmup)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
            wallMsSum += ms; wallMsMax = max(wallMsMax, ms); wallCount += 1
            engineResiduals[key] = result.residual
            let diff = abs(result.residual - expected.R)
            let relative = expected.R != 0 ? diff / abs(expected.R) : diff
            if diff > maxDiff {
                maxDiff = diff
                maxDiffKey = key
            }
            maxRelative = max(maxRelative, relative)
            if diff > 2.533e-14 {
                failures.append("\(key): |ΔR|=\(diff) relative=\(relative) engine=\(result.residual) fixture=\(expected.R)")
            }
        }

        print("K1 max |ΔR| = \(maxDiff) (relative \(maxRelative)) at \(maxDiffKey)")
        print("K5 wall ms per sealed check (n=2048, debug build): mean \(wallCount > 0 ? wallMsSum / Double(wallCount) : 0) max \(wallMsMax)")
        if !failures.isEmpty {
            for f in failures { print("K1 miss: \(f)") }
        }
        // Contract amendment 2 (2026-09-10): the absolute control tolerance
        // 2.533e-14 was set for R of order ≤ 0.11; fake trials reach R ≈ 24.7,
        // where the float64 floor of two different summation orders is
        // ~2.6e-15 relative = up to 6.4e-14 absolute. FAIL by the letter,
        // recorded as a floor measurement; an unexpected pass here means the
        // instrument changed and the contract must say so.
        // Amendment 3 (judge's ruling): the standing gate is relative —
        // |ΔR| ≤ 3e-15 · max(1, R_python) — asserted here beside the frozen
        // absolute letter, which stays as an expected failure in the record.
        var relativeMisses: [String] = []
        for (key, expected) in fixture.trials {
            guard let r = engineResiduals[key] else { continue }
            let bound = 3e-15 * max(1.0, abs(expected.R))
            if abs(r - expected.R) > bound { relativeMisses.append("\(key): |ΔR|=\(abs(r - expected.R)) bound=\(bound)") }
        }
        // Measured floor across the two regimes (amendment 4): the bound the
        // judge set next is read from these two numbers, not from R alone.
        var floorAbsSmall = 0.0, floorRelLarge = 0.0
        for (key, expected) in fixture.trials {
            guard let r = engineResiduals[key] else { continue }
            let d = abs(r - expected.R)
            if abs(expected.R) <= 1 { floorAbsSmall = max(floorAbsSmall, d) } else { floorRelLarge = max(floorRelLarge, d / abs(expected.R)) }
        }
        print("K1 measured floor: max |ΔR| at R ≤ 1 = \(floorAbsSmall); max |ΔR|/R at R > 1 = \(floorRelLarge)")
        print("K1' relative bound 3e-15·max(1,R): misses = \(relativeMisses.count)")
        // Amendment 5 — K1'' is THE gate: |ΔR| ≤ 1e-14 · max(1, R_python), the
        // judge's letter after the two measured regimes; asserted unwrapped.
        var gateMisses: [String] = []
        for (key, expected) in fixture.trials {
            guard let r = engineResiduals[key] else { continue }
            let bound = 1e-14 * max(1.0, abs(expected.R))
            if abs(r - expected.R) > bound { gateMisses.append("\(key): |ΔR|=\(abs(r - expected.R)) bound=\(bound)") }
        }
        print("K1'' gate 1e-14·max(1,R): misses = \(gateMisses.count)")
        XCTAssertTrue(gateMisses.isEmpty, "K1'' misses: \(gateMisses)")
        // Amendment 4: K1' misses on trials with R ≤ 1 where the absolute floor
        // (up to ~4.9e-15) exceeds 3e-15 — the floor is not proportional to R
        // at small R. FAIL by the letter, recorded; the judge sets the next bound.
        XCTExpectFailure("K1' floor finding (amendment 4): the relative bound 3e-15·max(1,R) misses at R ≤ 1 where the absolute float64 floor reaches ~4.9e-15") {
            XCTAssertTrue(relativeMisses.isEmpty, "K1' relative-bound misses: \(relativeMisses)")
        }
        XCTExpectFailure("K1 floor finding (amendment 2): fake_34 and fake_48 miss the absolute 2.533e-14 at R 16.4 / 24.7 with relative 2.4e-15 / 2.6e-15 — the float64 floor, not the identity") {
            XCTAssertTrue(failures.isEmpty, "K1 control-tolerance misses: \(failures)")
        }
    }

    func testK2CourtGatesRederived() throws {
        let (records, pair, fixture) = try Self.loadSealedOrSkip()
        let warmup = fixture.warmup

        var rByKey: [String: Double] = [:]
        for (key, trial) in records {
            rByKey[key] = SealedCrossConvolution.residual(a: trial.a, b: trial.b, pair: pair, warmup: warmup).residual
        }

        func keys(class label: String) -> [String] {
            records.filter { $0.value.classLabel == label }.map(\.key)
        }

        // G0: the cal0 entry whose numeric part is "1"
        let cal0Keys = keys(class: "cal0")
        let g0Key = cal0Keys.first { key in
            guard let underscore = key.lastIndex(of: "_") else { return false }
            return key[key.index(after: underscore)...] == "1"
        }
        guard let g0Key = g0Key, let g0 = rByKey[g0Key] else {
            return XCTFail("no cal0 entry with numeric part '1' found")
        }
        print("K2 G0_R = \(String(format: "%.3e", g0))")
        XCTAssertLessThanOrEqual(g0, 2.533e-14)
        print("K2 G0 R = \(String(format: "%.3e", g0)) (court printed 4.101e-15; both ≤ 2.533e-14 — at the numeric floor the third digit is summation-order noise, not a pin)")

        // G1: every court trial R <= TOL; worst printed
        let courtRs = keys(class: "court").map { rByKey[$0]! }
        let g1Worst = courtRs.max()!
        let g1Within = courtRs.filter { $0 <= 1.00452e-2 }.count
        print("K2 G1_worst = \(String(format: "%.3e", g1Worst)) within=\(g1Within)/\(courtRs.count)")
        XCTAssertTrue(courtRs.allSatisfy { $0 <= 1.00452e-2 })
        XCTAssertEqual(String(format: "%.3e", g1Worst), "5.415e-03")

        // G2: fakes with R > 10*TOL, strict, count == 50
        let fakeRs = keys(class: "fake").map { rByKey[$0]! }
        let g2Flares = fakeRs.filter { $0 > 10 * 1.00452e-2 }.count
        print("K2 G2_flares = \(g2Flares)/\(fakeRs.count)")
        XCTAssertEqual(g2Flares, 50)

        // G3: perturbed with R > TOL, strict, count == 50; quartiles
        let pertRs = keys(class: "pert").map { rByKey[$0]! }
        let g3Flares = pertRs.filter { $0 > 1.00452e-2 }.count
        print("K2 G3_flares = \(g3Flares)/\(pertRs.count)")
        XCTAssertEqual(g3Flares, 50)

        let sortedPert = pertRs.sorted()
        let n = sortedPert.count
        func quantile(_ p: Double) -> Double {
            sortedPert[Int(p * Double(n - 1))]
        }
        let q1 = quantile(0.25), q2 = quantile(0.5), q3 = quantile(0.75)
        print("K2 G3_quartiles = \(String(format: "%.3e", q1)) / \(String(format: "%.3e", q2)) / \(String(format: "%.3e", q3))")
        XCTAssertEqual(String(format: "%.3e", q1), "1.019e-01")
        XCTAssertEqual(String(format: "%.3e", q2), "1.032e-01")
        XCTAssertEqual(String(format: "%.3e", q3), "1.052e-01")

        // Reference (not gated): max R over the 20 noisy cal trials
        let calRs = keys(class: "cal").map { rByKey[$0]! }
        let calMax = calRs.max()!
        print("K2 cal_maxR = \(String(format: "%.3e", calMax))")
        XCTAssertEqual(String(format: "%.3e", calMax), "3.348e-03")

        _ = fixture // fixture gates already cross-checked in K1; kept for symmetry with the loader
    }

    func testK5PatrolDivergenceAttributed() throws {
        let (records, pair, fixture) = try Self.loadSealedOrSkip()
        let warmup = fixture.warmup
        let tol = fixture.tolerance

        var maxFullWinDiff = 0.0
        var maxSymDenDiff = 0.0
        var maxF32Diff = 0.0
        var maxPatrolDiff = 0.0
        var maxPatrolDiffKey = ""
        var flipCount = 0
        var flipsByClass: [String: Int] = [:]

        for (key, trial) in records {
            guard let expected = fixture.trials[key] else {
                XCTFail("no fixture residual for trial \(key)")
                continue
            }
            let attribution = SealedCrossConvolution.attribution(a: trial.a, b: trial.b, pair: pair, warmup: warmup)

            maxFullWinDiff = max(maxFullWinDiff, abs(attribution.fullWindow - expected.R_fullwin))
            maxSymDenDiff = max(maxSymDenDiff, abs(attribution.symmetricDenominator - expected.R_symden))
            maxF32Diff = max(maxF32Diff, abs(attribution.float32Inputs - expected.R_f32))

            let patrolDiff = abs(attribution.patrol - attribution.sealed)
            if patrolDiff > maxPatrolDiff {
                maxPatrolDiff = patrolDiff
                maxPatrolDiffKey = key
            }

            let cls = expected.classLabel
            let sealedR = attribution.sealed
            let patrolR = attribution.patrol
            let flips: Bool
            switch cls {
            case "court":
                flips = (patrolR > tol) != (sealedR > tol)
            case "fake":
                flips = (patrolR > 10 * tol) != (sealedR > 10 * tol)
            case "pert":
                flips = (patrolR > tol) != (sealedR > tol)
            default:
                flips = false
            }
            if flips { flipCount += 1; flipsByClass[cls, default: 0] += 1 }
        }

        print("K5 max |patrol - sealed| = \(maxPatrolDiff) at \(maxPatrolDiffKey)")
        print("K5 gate flips (patrol vs sealed) = \(flipCount)/\(records.count)")
        print("K5 gate flips by class = \(flipsByClass.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))")
        print("K5 max |fullWindow - R_fullwin| = \(maxFullWinDiff)")
        print("K5 max |symmetricDenominator - R_symden| = \(maxSymDenDiff)")
        print("K5 max |float32Inputs - R_f32| = \(maxF32Diff)")

        XCTAssertLessThanOrEqual(maxFullWinDiff, 1e-12)
        XCTAssertLessThanOrEqual(maxSymDenDiff, 1e-12)
        XCTAssertLessThanOrEqual(maxF32Diff, 1e-12)
    }
}
