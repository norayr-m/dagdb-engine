import XCTest
import Foundation
@testable import DagDB

/// P4 spec 8 — waveform mouth: bridges the engine's WaveBank against the
/// numpy reference fixture per docs/contracts/SPEC8_MOUTH_GATES_FROZEN.md
/// (G1–G5), plus shape-guard and Codable coverage, plus the printed-only
/// throughput measurement (G6).
final class WaveBankTests: XCTestCase {

    // MARK: - Fixture loading

    private struct PhiSample: Decodable { let t: Int; let k: Int; let v: Double }
    private struct WSample: Decodable { let t: Int; let m: Int; let v: Double }
    private struct SpecJSON: Decodable {
        let samples: Int, harmonics: Int, gaborCenters: Int, gaborFreqs: Int
        let sampleRate: Double, f0: Double, gaborSigmaFrac: Double
    }
    private struct Fixture: Decodable {
        let spec: SpecJSON
        let K: Int
        let phiSamples: [PhiSample]
        let cRef: [Float]
        let wSamples: [WSample]
        let wFrobenius: Double
        let probeResidual: Double
        let probeCoefficients: [Float]
        let noiseResidualMean: Double
        let noiseResidualMin: Double
        let noiseResidualMax: Double
        let numpySamplesPerSecond: Double?   // moved to the timing sidecar 2026-09-10; absent in the hashed fixture
    }

    private static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/DagDBTests/
            .deletingLastPathComponent()   // Tests/
            .appendingPathComponent("Fixtures")
    }

    /// Loads the fixture after checking its SHA-256 against the sidecar
    /// `.sha256` file — a mismatch fails the test, it never skips.
    private static func loadFixture() throws -> Fixture {
        let jsonURL = fixturesDir.appendingPathComponent("mouth_reference_v1.json")
        let shaURL = fixturesDir.appendingPathComponent("mouth_reference_v1.sha256")
        let data = try Data(contentsOf: jsonURL)
        let shaLine = try String(contentsOf: shaURL, encoding: .utf8)
        let expectedHex = shaLine.split(separator: " ").first.map(String.init) ?? ""
        let actualHex = DagDBSnapshot.sha256Hex(data)
        guard actualHex == expectedHex else {
            throw NSError(domain: "WaveBankTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "fixture sha256 mismatch: expected \(expectedHex), got \(actualHex)"
            ])
        }
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    private func referenceStream() -> NamedStream {
        NamedStream(name: "ref",
                    stateHi: 0x853c_49e6_748f_ea9b, stateLo: 0xda3e_39cb_94b9_5bdb,
                    incHi: 0x5851_f42d_4c95_7f2d, incLo: 0x1405_7b7e_f767_814f)
    }

    // MARK: - Shape

    func testReferenceSpecHas160Atoms() throws {
        let bank = try WaveBank(spec: .reference)
        XCTAssertEqual(bank.K, 160)
        XCTAssertEqual(bank.atoms.count, 4096 * 160)
    }

    // MARK: - G1: Phi bridge

    func testG1PhiBridge() throws {
        let fixture = try Self.loadFixture()
        let bank = try WaveBank(spec: .reference)

        var maxDiff = 0.0
        for s in fixture.phiSamples {
            let engineV = Double(bank.atoms[s.k * bank.T + s.t])
            maxDiff = max(maxDiff, abs(engineV - s.v))
        }
        print("G1 phi bridge: max diff = \(maxDiff)")
        XCTAssertLessThanOrEqual(maxDiff, 2e-6)

        for k in 0..<bank.K {
            XCTAssertEqual(bank.columnNorm(k), 1.0, accuracy: 1e-5, "column \(k) norm")
        }
    }

    // MARK: - G2: W bridge

    func testG2WBridge() throws {
        let fixture = try Self.loadFixture()
        let bank = try WaveBank(spec: .reference)

        let W = bank.generate(coefficients: fixture.cRef, columns: 8)
        XCTAssertEqual(W.count, bank.T * 8)

        var maxDiff = 0.0
        var maxRefAbs = 0.0
        for s in fixture.wSamples {
            let engineV = Double(W[s.t * 8 + s.m])
            maxDiff = max(maxDiff, abs(engineV - s.v))
            maxRefAbs = max(maxRefAbs, abs(s.v))
        }

        var frobSq = 0.0
        for v in W { frobSq += Double(v) * Double(v) }
        let frob = frobSq.squareRoot()
        let frobDiff = abs(frob - fixture.wFrobenius)

        print("G2 W bridge: max diff = \(maxDiff) (tolerance \(1e-4 * maxRefAbs)), frobenius diff = \(frobDiff)")
        XCTAssertLessThanOrEqual(maxDiff, 1e-4 * maxRefAbs)
        XCTAssertLessThanOrEqual(frobDiff, 1e-5 * fixture.wFrobenius)
    }

    // MARK: - G3: out-of-bank noise law

    func testG3NoiseLaw() throws {
        let fixture = try Self.loadFixture()
        let bank = try WaveBank(spec: .reference)

        // The frozen contract's printed literal (0.9802920) is a hand
        // rounding of √(1 − 160/4096); the textbook value is
        // 0.9802741963348827 (checked independently in Python: 0.980292^2 =
        // 0.96097..., not 0.9609375 = 1 − 160/4096). expectedNoiseResidual
        // keeps the exact textbook formula rather than the doc's literal;
        // the gap (~1.8e-5) is far inside G3's own tolerances (0.035 / 0.008
        // below), so it never affects G3 pass/fail — only this self-check's
        // accuracy is loosened to admit the doc's own rounding.
        let expected = WaveBank.expectedNoiseResidual(T: bank.T, K: bank.K)
        XCTAssertEqual(expected, 0.9802741963348827, accuracy: 1e-9)  // computed, amendment 1

        let law = bank.noiseLaw(seeds: 20, stream: referenceStream())
        for r in law.residuals {
            XCTAssertLessThanOrEqual(abs(r - expected), 0.035)
        }
        XCTAssertLessThanOrEqual(abs(law.mean - expected), 0.008)

        print("noise law: expected=\(expected) engine mean=\(law.mean) min=\(law.min) max=\(law.max) numpy mean=\(fixture.noiseResidualMean)")
    }

    // MARK: - G4: probe bridge

    func testG4ProbeBridge() throws {
        let fixture = try Self.loadFixture()
        let bank = try WaveBank(spec: .reference)

        let probe = WaveBank.referenceProbe(spec: .reference)
        guard let fit = bank.fit(probe) else {
            XCTFail("fit returned nil for the reference probe")
            return
        }

        print("probe residual engine=\(fit.residual) numpy=\(fixture.probeResidual)")
        XCTAssertLessThanOrEqual(abs(fit.residual - fixture.probeResidual), 1e-3)

        let maxRefC = fixture.probeCoefficients.reduce(0.0) { max($0, Double(abs($1))) }
        var maxCDiff = 0.0
        for k in 0..<bank.K {
            maxCDiff = max(maxCDiff, Double(abs(fit.coefficients[k] - fixture.probeCoefficients[k])))
        }
        XCTAssertLessThanOrEqual(maxCDiff, 1e-2 * maxRefC)
    }

    // MARK: - G5: in-bank sanity

    func testG5InBank() throws {
        let bank = try WaveBank(spec: .reference)
        var stream = referenceStream()
        let c0 = WaveBank.gaussianNoise(count: bank.K, stream: &stream)
        let x = bank.generate(coefficients: c0, columns: 1)
        guard let fit = bank.fit(x) else {
            XCTFail("fit returned nil for an in-bank signal")
            return
        }
        XCTAssertLessThanOrEqual(fit.residual, 1e-5)
    }

    // MARK: - Validation

    func testValidationErrors() throws {
        XCTAssertNil(WaveBank.validationError(.reference))

        let zeroHarmonics = WaveBank.Spec(samples: 4096, sampleRate: 3000, f0: 60, harmonics: 0,
                                           gaborCenters: 8, gaborFreqs: 6, gaborSigmaFrac: 0.02)
        XCTAssertNotNil(WaveBank.validationError(zeroHarmonics))

        let zeroSampleRate = WaveBank.Spec(samples: 4096, sampleRate: 0, f0: 60, harmonics: 32,
                                            gaborCenters: 8, gaborFreqs: 6, gaborSigmaFrac: 0.02)
        XCTAssertNotNil(WaveBank.validationError(zeroSampleRate))

        let zeroSigmaFrac = WaveBank.Spec(samples: 4096, sampleRate: 3000, f0: 60, harmonics: 32,
                                           gaborCenters: 8, gaborFreqs: 6, gaborSigmaFrac: 0)
        XCTAssertNotNil(WaveBank.validationError(zeroSigmaFrac))

        let oneSample = WaveBank.Spec(samples: 1, sampleRate: 3000, f0: 60, harmonics: 32,
                                       gaborCenters: 8, gaborFreqs: 6, gaborSigmaFrac: 0.02)
        XCTAssertNotNil(WaveBank.validationError(oneSample))

        let atomsExceedSamples = WaveBank.Spec(samples: 100, sampleRate: 3000, f0: 60, harmonics: 60,
                                                gaborCenters: 8, gaborFreqs: 6, gaborSigmaFrac: 0.02)
        XCTAssertNotNil(WaveBank.validationError(atomsExceedSamples))

        XCTAssertThrowsError(try WaveBank(spec: zeroHarmonics)) { error in
            guard case WaveBank.BankError.badSpec = error else {
                XCTFail("expected badSpec, got \(error)")
                return
            }
        }
    }

    // MARK: - Codable

    func testCodableRoundTripBySpec() throws {
        let small = WaveBank.Spec(samples: 64, sampleRate: 300, f0: 10, harmonics: 2,
                                   gaborCenters: 1, gaborFreqs: 1, gaborSigmaFrac: 0.05)
        let bank = try WaveBank(spec: small)

        let data = try JSONEncoder().encode(bank)
        let decoded = try JSONDecoder().decode(WaveBank.self, from: data)

        XCTAssertEqual(decoded, bank)
        XCTAssertEqual(decoded.atoms, bank.atoms)
    }

    // MARK: - Shape guards

    func testGenerateShapeGuards() throws {
        let bank = try WaveBank(spec: .reference)

        XCTAssertEqual(bank.generate(coefficients: [Float](repeating: 0, count: bank.K), columns: 2), [])
        XCTAssertEqual(bank.generate(coefficients: [Float](repeating: 0, count: bank.K * 3), columns: 0), [])

        XCTAssertNil(bank.fit([Float](repeating: 0, count: bank.T - 1)))

        let zeroFit = bank.fit([Float](repeating: 0, count: bank.T))
        XCTAssertEqual(zeroFit?.residual, 0)
    }

    // MARK: - G6: throughput (printed, not gated)

    func testBenchPrintsThroughput() throws {
        let bank = try WaveBank(spec: .reference)
        let bench = bank.bench(columns: 10000, reps: 3)
        XCTAssertGreaterThan(bench.samplesPerSecond, 0)
        print("bench: T=\(bank.T) K=\(bank.K) M=\(bench.columns) best_ms=\(bench.bestSeconds * 1000) samples_per_s=\(bench.samplesPerSecond) (numpy reference 2.23e9)")
    }

    // MARK: - G8: declaration and the Nyquist line (AMENDMENT 2)

    func testG8ControlBankRank146() throws {
        let bank = try WaveBank(spec: .reference)
        let decl = bank.declaration()
        print("control bank: K=\(bank.K) rank=\(decl.rank) cond=\(decl.conditionNumber)")
        XCTAssertEqual(decl.rank, 146)
    }

    func testG8RepairedBankRank144Cond() throws {
        let bank = try WaveBank(spec: .referenceNyquistSafe)
        XCTAssertEqual(bank.K, 144)
        let decl = bank.declaration()
        print("repaired bank: K=\(bank.K) rank=\(decl.rank) cond=\(decl.conditionNumber)")
        XCTAssertEqual(decl.rank, 144)
        XCTAssertEqual(decl.conditionNumber, 2.666, accuracy: 0.01)
    }

    func testAliasingViolationNamesNyquist() throws {
        guard let refMsg = WaveBank.aliasingViolation(.reference) else {
            XCTFail("expected the reference spec (H=32) to violate the Nyquist line")
            return
        }
        print("aliasing(reference) = \(refMsg)")
        XCTAssertTrue(refMsg.contains("1560"), refMsg)
        XCTAssertTrue(refMsg.contains("1500"), refMsg)

        XCTAssertNil(WaveBank.aliasingViolation(.referenceNyquistSafe))

        let exactNyquist = WaveBank.Spec(samples: 4096, sampleRate: 3000, f0: 60, harmonics: 25,
                                          gaborCenters: 8, gaborFreqs: 6, gaborSigmaFrac: 0.02)
        XCTAssertNotNil(WaveBank.aliasingViolation(exactNyquist))
    }

    func testRepairedBankPrintedNumbers() throws {
        let bank = try WaveBank(spec: .referenceNyquistSafe)

        let probe = WaveBank.referenceProbe(spec: .referenceNyquistSafe)
        guard let fit = bank.fit(probe) else {
            XCTFail("fit returned nil for the reference probe on the repaired bank")
            return
        }
        XCTAssertTrue(fit.residual.isFinite)
        print("repaired probe residual = \(fit.residual)")

        // AMENDMENT 2 (f)'s literal 0.982321 is, like AMENDMENT 1's r0
        // (0.9802920 vs the textbook 0.9802741963348827), a hand-rounding
        // by the author: sqrt(1 - 144/4096) = 0.982264602843857 exactly
        // (checked independently in Python), a ~5.6e-5 gap from the
        // doc's literal — same pattern, larger this time. The formula is
        // the gate, not the literal (per AMENDMENT 1's own resolution);
        // this line is printed, not gated (G8(f)), so the looser accuracy
        // only admits the doc's own rounding — it never affects G8 pass/fail.
        let expected = WaveBank.expectedNoiseResidual(T: 4096, K: 144)
        XCTAssertEqual(expected, 0.982321, accuracy: 1e-4)
        let law = bank.noiseLaw(seeds: 20, stream: referenceStream())
        XCTAssertTrue(law.mean.isFinite)
        print("repaired noise law: expected=\(expected) mean=\(law.mean) min=\(law.min) max=\(law.max)")

        let bench = bank.bench(columns: 10000, reps: 3)
        XCTAssertTrue(bench.samplesPerSecond.isFinite)
        print("repaired bench: K=\(bank.K) M=\(bench.columns) samples_per_s=\(bench.samplesPerSecond)")
    }
}
