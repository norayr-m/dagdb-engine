import XCTest
@testable import DagDB

final class CrossConvolutionCheckTests: XCTestCase {
    /// Deterministic source + two arbitrary path kernels; ears are the
    /// source pushed through each path, so the identity holds by LTI algebra.
    private func fixture() -> (a: [Float], b: [Float],
                               kA: CrossConvolutionCheck.PathKernel,
                               kB: CrossConvolutionCheck.PathKernel) {
        var stream = NamedStream(name: "w6",
                                 stateHi: 0x853c_49e6_748f_ea9b, stateLo: 0xda3e_39cb_94b9_5bdb,
                                 incHi: 0x5851_f42d_4c95_7f2d, incLo: 0x1405_7b7e_f767_814f)
        func unit() -> Float { Float(stream.next64() >> 40) / Float(1 << 24) - 0.5 }
        let source = (0..<64).map { _ in unit() }
        let kA = CrossConvolutionCheck.PathKernel(taps: (0..<6).map { _ in unit() })
        let kB = CrossConvolutionCheck.PathKernel(taps: (0..<9).map { _ in unit() })
        let a = CrossConvolutionCheck.convolve(source, kA).map { Float($0) }
        let b = CrossConvolutionCheck.convolve(source, kB).map { Float($0) }
        return (a, b, kA, kB)
    }

    private let warmup = 16   // past both kernel supports

    func testTrueSignalPasses() {
        let f = fixture()
        let r = CrossConvolutionCheck.check(recordA: f.a, recordB: f.b,
                                            kernelA: f.kA, kernelB: f.kB, warmup: warmup)
        XCTAssertLessThan(r.residual, 1e-6)   // Float32 storage floor, not zero
        XCTAssertGreaterThan(r.comparedSamples, 32)
    }

    func testForgedRecordingScreams() {
        let f = fixture()
        var noise = NamedStream(name: "forge", stateHi: 1, stateLo: 2, incHi: 3, incLo: 5)
        let fake = (0..<f.b.count).map { _ in Float(noise.next64() >> 40) / Float(1 << 24) - 0.5 }
        let r = CrossConvolutionCheck.check(recordA: f.a, recordB: fake,
                                            kernelA: f.kA, kernelB: f.kB, warmup: warmup)
        XCTAssertGreaterThan(r.residual, 0.5)
    }

    func testTwistedModelFlashes() {
        let f = fixture()
        let twisted = CrossConvolutionCheck.PathKernel(taps: f.kB.taps.map { $0 * 1.2 })
        let r = CrossConvolutionCheck.check(recordA: f.a, recordB: f.b,
                                            kernelA: f.kA, kernelB: twisted, warmup: warmup)
        XCTAssertGreaterThan(r.residual, 0.05)
        XCTAssertLessThan(r.residual, 0.5)    // a flash, not a scream
    }

    func testWarmupExcludedAndSilenceIsZero() {
        let r = CrossConvolutionCheck.check(recordA: [0, 0, 0], recordB: [0, 0, 0],
                                            kernelA: .init(taps: [1]), kernelB: .init(taps: [1]),
                                            warmup: 1)
        XCTAssertEqual(r.residual, 0)
    }
}
