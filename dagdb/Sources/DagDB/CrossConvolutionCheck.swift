import Foundation

/// Cross-convolution self-test — twin spec line 6, the sealed W1 identity.
///
/// For two ears A and B with per-path kernels from a common source, any true
/// source-born signal obeys kB ⋆ a == kA ⋆ b: one recording pushed through
/// the OTHER ear's path must equal the mirror. No inversions anywhere, so
/// noise is never amplified. A forged recording screams; a corrupted path
/// model flashes. The court sealed the mechanism (150/150); this is the
/// standing cheap check as an engine primitive.
///
/// Storage is Float32 (the engine's lane width); accumulation is Double —
/// the honesty split the ladder courts already priced.
public struct CrossConvolutionCheck {
    /// Per-path FIR kernel with its declared warmup (samples to discard
    /// before comparison — from the pair's τ difference and kernel supports).
    public struct PathKernel: Equatable, Codable {
        public let taps: [Float]
        public init(taps: [Float]) { self.taps = taps }
    }

    public struct Result: Equatable, Codable {
        /// Normalized residual: max |lhs − rhs| over the compared window,
        /// divided by the max |reference| on that window (0 if both silent).
        public let residual: Double
        public let comparedSamples: Int
        /// Audit C finding 30 (contract ruling, cross-convolution): a
        /// `warmup` at or past the record is REFUSED BY NAME, not clamped.
        /// Non-nil iff `check` refused; the residual is then `.infinity`
        /// and `comparedSamples` is 0. An appended field — decoding a
        /// record written before it yields `nil`.
        public let refusal: String?
        public init(residual: Double, comparedSamples: Int, refusal: String? = nil) {
            self.residual = residual
            self.comparedSamples = comparedSamples
            self.refusal = refusal
        }
        /// Finding 30: a check that compared NOTHING does not pass, for any
        /// tolerance — previously `residual == 0 <= tolerance` returned
        /// true after an empty window.
        public func passes(tolerance: Double) -> Bool {
            guard refusal == nil, comparedSamples > 0 else { return false }
            return residual <= tolerance
        }
    }

    /// Full-length direct convolution (length = signal + taps − 1).
    public static func convolve(_ signal: [Float], _ kernel: PathKernel) -> [Double] {
        let n = signal.count, m = kernel.taps.count
        guard n > 0, m > 0 else { return [] }
        var out = [Double](repeating: 0, count: n + m - 1)
        for i in 0..<n {
            let s = Double(signal[i])
            if s == 0 { continue }
            for j in 0..<m {
                out[i + j] += s * Double(kernel.taps[j])
            }
        }
        return out
    }

    /// The identity check: kB ⋆ a versus kA ⋆ b, compared after `warmup`
    /// samples and over the overlap of both RECORDS.
    ///
    /// Audit C finding 29 (contract ruling, cross-convolution): the
    /// compared window stops at the record's end — `min(a.count, b.count)`
    /// — never `min(lhs.count, rhs.count)`, which ran `taps − 1` samples
    /// into the convolution tail, past any sample either recording
    /// actually contains. (The window is additionally clipped to the
    /// convolution outputs' own length, which only binds when a kernel is
    /// empty and `convolve` returns nothing.)
    ///
    /// Finding 30: `warmup` at or past that window is refused by name in
    /// the returned `Result` — never clamped into an empty comparison that
    /// reported residual 0 and passed every tolerance.
    public static func check(recordA a: [Float], recordB b: [Float],
                             kernelA: PathKernel, kernelB: PathKernel,
                             warmup: Int) -> Result {
        let lhs = convolve(a, kernelB)   // other ear's path applied to A
        let rhs = convolve(b, kernelA)
        let recordEnd = min(a.count, b.count)
        let n = min(recordEnd, min(lhs.count, rhs.count))
        guard warmup >= 0 else {
            return Result(residual: .infinity, comparedSamples: 0,
                          refusal: "warmup \(warmup) must be >= 0")
        }
        guard warmup < n else {
            return Result(residual: .infinity, comparedSamples: 0,
                          refusal: "warmup \(warmup) leaves no comparison window: the records "
                              + "overlap over \(n) sample(s) (recordA \(a.count), recordB \(b.count), "
                              + "kernelA \(kernelA.taps.count) taps, kernelB \(kernelB.taps.count) taps)")
        }
        let start = warmup
        var maxDiff = 0.0
        var maxRef = 0.0
        for i in start..<n {
            maxDiff = max(maxDiff, abs(lhs[i] - rhs[i]))
            maxRef = max(maxRef, max(abs(lhs[i]), abs(rhs[i])))
        }
        let r = maxRef > 0 ? maxDiff / maxRef : 0
        return Result(residual: r, comparedSamples: max(0, n - start))
    }
}
