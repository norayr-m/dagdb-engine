import Foundation

/// The W1 court's residual, exactly as gate_w1.py computes it. Distinct from
/// `CrossConvolutionCheck.check` (the patrol check): window [warmup, n) on
/// both numerator and denominator, one-sided denominator max|kB⋆a| + 1e-300,
/// float64 end to end. See docs/contracts/KERNELS_GATES_FROZEN.md.
public enum SealedCrossConvolution {
    public struct Result: Equatable {
        public let residual: Double
        public let n: Int
        public let warmup: Int
    }

    /// Full-length direct convolution (length = x.count + k.count − 1);
    /// out[i+j] += x[i]·k[j], i ascending outer, j ascending inner. This
    /// summation order (vs numpy's direct/FFT choice) is the instrument
    /// floor K1's bound measures.
    public static func convolveFull(_ x: [Double], _ k: [Double]) -> [Double] {
        let n = x.count, m = k.count
        guard n > 0, m > 0 else { return [] }
        var out = [Double](repeating: 0, count: n + m - 1)
        for i in 0..<n {
            let xi = x[i]
            if xi == 0 { continue }
            for j in 0..<m {
                out[i + j] += xi * k[j]
            }
        }
        return out
    }

    /// The sealed formula: yAB = (kB ⋆ a)[:n], yBA = (kA ⋆ b)[:n], window
    /// [warmup, n) on numerator AND denominator, denominator one-sided
    /// (max|yAB|) + 1e-300. `n = a.count`; requires `b.count == n` and
    /// `0 ≤ warmup < n`, else `Result(residual: .nan, n: 0, warmup:)` — no
    /// trap.
    public static func residual(a: [Double], b: [Double], pair: KernelPair, warmup: Int) -> Result {
        let n = a.count
        guard b.count == n, warmup >= 0, warmup < n else {
            return Result(residual: .nan, n: 0, warmup: warmup)
        }
        let yAB = Array(convolveFull(a, pair.kB).prefix(n))
        let yBA = Array(convolveFull(b, pair.kA).prefix(n))
        var num = 0.0
        var den = 0.0
        for t in warmup..<n {
            num = max(num, abs(yAB[t] - yBA[t]))
            den = max(den, abs(yAB[t]))
        }
        let r = num / (den + 1e-300)
        return Result(residual: r, n: n, warmup: warmup)
    }

    /// K5: the sealed residual beside the patrol check's, and the three
    /// formula differences that separate them, printed separately so the
    /// divergence is attributable, not only counted.
    public struct Attribution: Equatable {
        public let sealed: Double
        public let fullWindow: Double
        public let symmetricDenominator: Double
        public let float32Inputs: Double
        public let patrol: Double
    }

    public static func attribution(a: [Double], b: [Double], pair: KernelPair, warmup: Int) -> Attribution {
        let n = a.count
        let m = pair.taps
        let kA = pair.kA
        let kB = pair.kB

        var sealed = Double.nan
        var fullWindow = Double.nan
        var symmetricDenominator = Double.nan
        var float32Inputs = Double.nan

        if b.count == n, n > 0, warmup >= 0 {
            let yABFull = convolveFull(a, kB)
            let yBAFull = convolveFull(b, kA)

            // sealed + symmetricDenominator share the truncated-to-n window
            if warmup < n {
                var num = 0.0, denAB = 0.0, denBA = 0.0
                for t in warmup..<n {
                    let d = abs(yABFull[t] - yBAFull[t])
                    num = max(num, d)
                    denAB = max(denAB, abs(yABFull[t]))
                    denBA = max(denBA, abs(yBAFull[t]))
                }
                sealed = num / (denAB + 1e-300)
                symmetricDenominator = num / (max(denAB, denBA) + 1e-300)
            }

            // fullWindow: untruncated convolutions, window [warmup, n+m-1),
            // one-sided denominator (sealed formula otherwise)
            let fullLength = n + m - 1
            if warmup < fullLength {
                var num = 0.0, den = 0.0
                for t in warmup..<fullLength {
                    num = max(num, abs(yABFull[t] - yBAFull[t]))
                    den = max(den, abs(yABFull[t]))
                }
                fullWindow = num / (den + 1e-300)
            }

            // float32Inputs: a, b, kA, kB rounded through Float then back
            // to Double, then the sealed formula.
            if warmup < n {
                let a32 = a.map { Double(Float($0)) }
                let b32 = b.map { Double(Float($0)) }
                let kA32 = kA.map { Double(Float($0)) }
                let kB32 = kB.map { Double(Float($0)) }
                let yAB32 = Array(convolveFull(a32, kB32).prefix(n))
                let yBA32 = Array(convolveFull(b32, kA32).prefix(n))
                var num = 0.0, den = 0.0
                for t in warmup..<n {
                    num = max(num, abs(yAB32[t] - yBA32[t]))
                    den = max(den, abs(yAB32[t]))
                }
                float32Inputs = num / (den + 1e-300)
            }
        }

        let patrolResult = CrossConvolutionCheck.check(
            recordA: a.map(Float.init), recordB: b.map(Float.init),
            kernelA: CrossConvolutionCheck.PathKernel(taps: kA.map(Float.init)),
            kernelB: CrossConvolutionCheck.PathKernel(taps: kB.map(Float.init)),
            warmup: warmup
        )

        return Attribution(sealed: sealed, fullWindow: fullWindow,
                            symmetricDenominator: symmetricDenominator,
                            float32Inputs: float32Inputs, patrol: patrolResult.residual)
    }
}
