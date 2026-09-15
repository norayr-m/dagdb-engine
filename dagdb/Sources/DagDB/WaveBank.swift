import Foundation
import Dispatch
import Accelerate

/// WaveBank — spec 8, the waveform mouth as a matrix product: a frozen bank
/// Φ of T×K atoms; generating M waveforms is one matrix product W = Φ·C.
///
/// Mirrors the numpy reference (`dagdb/scripts/mouth_reference.py`, frozen in
/// `docs/contracts/SPEC8_MOUTH_GATES_FROZEN.md`) bit-for-bit up to the
/// instrument floors written there: harmonic cos/sin columns, then Gabor
/// atoms (Gaussian envelope × cos/sin) on a center/frequency grid, built in
/// Double and cast to Float32, each column then unit-normalized with a
/// Float32-accumulated norm (numpy's float32 `np.linalg.norm`).
///
/// Storage is column-major (`atoms[k*T + t]`) — read as a row-major K×T
/// matrix this is exactly Φ^T, which lets `generate` hand the buffer to
/// `cblas_sgemm` with a transpose flag instead of copying it.
public struct WaveBank: Equatable, Codable {
    public struct Spec: Equatable, Codable {
        public let samples: Int
        public let sampleRate: Double
        public let f0: Double
        public let harmonics: Int
        public let gaborCenters: Int
        public let gaborFreqs: Int
        public let gaborSigmaFrac: Double

        public init(samples: Int, sampleRate: Double, f0: Double, harmonics: Int,
                    gaborCenters: Int, gaborFreqs: Int, gaborSigmaFrac: Double) {
            self.samples = samples
            self.sampleRate = sampleRate
            self.f0 = f0
            self.harmonics = harmonics
            self.gaborCenters = gaborCenters
            self.gaborFreqs = gaborFreqs
            self.gaborSigmaFrac = gaborSigmaFrac
        }

        public static let reference = Spec(samples: 4096, sampleRate: 3000, f0: 60,
                                            harmonics: 32, gaborCenters: 8, gaborFreqs: 6,
                                            gaborSigmaFrac: 0.02)

        /// SPEC8_MOUTH_GATES_FROZEN.md AMENDMENT 2: the repaired bank at the
        /// reference rates. `.reference`'s H = 32 puts harmonics 26..32 above
        /// Nyquist (fs/2 = 1500 Hz at fs = 3000), where they alias exactly
        /// onto harmonics 24..18 — fourteen of its 160 atoms are dependent.
        /// H = 24 keeps every harmonic strictly below Nyquist: K = 144,
        /// float64 rank 144, condition number 2.666 (twin lane's numbers,
        /// G8(b)). This is the object the daemon opens by default going
        /// forward; `.reference` (K = 160) stays the sealed CONTROL object
        /// for G1–G5.
        public static let referenceNyquistSafe = Spec(samples: 4096, sampleRate: 3000, f0: 60,
                                                        harmonics: 24, gaborCenters: 8, gaborFreqs: 6,
                                                        gaborSigmaFrac: 0.02)

        public var atomCount: Int { 2 * harmonics + 2 * gaborCenters * gaborFreqs }
    }

    /// nil iff the spec admits a bank: samples in [2, 1<<20], sampleRate/f0/
    /// gaborSigmaFrac positive finite, harmonics >= 1, gaborCenters/gaborFreqs
    /// >= 0, and 1 <= atomCount <= min(4096, samples).
    public static func validationError(_ s: Spec) -> String? {
        if s.samples < 2 { return "samples must be >= 2" }
        if s.samples > (1 << 20) { return "samples must be <= 1<<20" }
        if !(s.sampleRate > 0) || !s.sampleRate.isFinite { return "sampleRate must be positive and finite" }
        if !(s.f0 > 0) || !s.f0.isFinite { return "f0 must be positive and finite" }
        if s.harmonics < 1 { return "harmonics must be >= 1" }
        if s.gaborCenters < 0 { return "gaborCenters must be >= 0" }
        if s.gaborFreqs < 0 { return "gaborFreqs must be >= 0" }
        if !(s.gaborSigmaFrac > 0) || !s.gaborSigmaFrac.isFinite { return "gaborSigmaFrac must be positive and finite" }
        let atomCount = s.atomCount
        if atomCount < 1 { return "atomCount must be >= 1" }
        if atomCount > 4096 { return "atomCount must be <= 4096" }
        if atomCount > s.samples { return "atomCount must be <= samples" }
        return nil
    }

    public enum BankError: Error, Equatable {
        case badSpec(String)
    }

    /// nil iff the spec's top harmonic (H·f0) stays strictly below Nyquist
    /// (fs/2), with a 1e-9 Hz tolerance against float noise; otherwise a
    /// message naming the FIRST harmonic k that would alias — the smallest
    /// k with k·f0 strictly above fs/2 — and its frequency. This is a
    /// distinct, stricter check from `validationError` (deliberately: the
    /// twin lane's diagnosis is about harmonics folding back onto each
    /// other, not about the spec admitting a bank at all), and
    /// `validationError` must never absorb it — the 160-atom control
    /// fixture (`.reference`, which does alias) must stay buildable by the
    /// library; only the daemon's OPEN verb refuses it without `ALIASED`.
    public static func aliasingViolation(_ s: Spec) -> String? {
        let nyquist = s.sampleRate / 2.0
        let topFreq = Double(s.harmonics) * s.f0
        if topFreq >= nyquist - 1e-9 {
            // First k with k·f0 > nyquist: content exactly at Nyquist does
            // not alias (the boundary is real and representable), only
            // content strictly above it folds back — hence
            // floor(nyquist/f0) + 1, not a direct reuse of the (looser, <=)
            // spec-level threshold above. The +1e-9 nudge guards the
            // exact-multiple case (nyquist/f0 landing on an integer)
            // against a float division that comes in a hair under that
            // integer.
            //
            // Audit C finding 32: that +1 could name `H + 1`, an atom the
            // bank does not contain (exactly the case H·f0 == fs/2). The
            // named harmonic is clamped into 1…H, so the message always
            // points at a column that exists.
            let raw = Int(floor(nyquist / s.f0 + 1e-9)) + 1
            let k = Swift.min(Swift.max(raw, 1), s.harmonics)
            let freq = Double(k) * s.f0
            return "harmonic \(k) at \(WaveBank.formatHz(freq)) Hz reaches Nyquist "
                + "\(WaveBank.formatHz(nyquist)) Hz (fs \(WaveBank.formatHz(s.sampleRate))); the top "
                + "harmonic must stay below fs/2 — write ALIASED to allow"
        }
        return gaborAliasingViolation(s)
    }

    /// Audit C finding 31 (contract ruling: "the bank's Nyquist rule covers
    /// every atom family"). The bank's other half is
    /// `2 · gaborCenters · gaborFreqs` Gabor columns on the frequency grid
    /// `geomspace(f0, fs/4, gaborFreqs)` — no Nyquist rule covered them.
    ///
    /// A Gabor atom is not a line: it is a Gaussian envelope of time width
    /// σ_t = gaborSigmaFrac · T / fs seconds, whose spectrum is a Gaussian
    /// of width σ_f = 1/(2π σ_t) Hz about its centre frequency. The ruling's
    /// rule — "the highest Gabor centre plus its bandwidth against fs/2" —
    /// is therefore `max(grid) + σ_f >= fs/2`, refused with the same
    /// `ALIASED` opt-out the harmonic rule offers.
    ///
    /// The grid's top is `fs/4` by construction, so this fires only for a
    /// bandwidth wider than fs/4 — a very short envelope (a small
    /// `gaborSigmaFrac` on a short bank). Both sealed fixtures stay clean
    /// of it: at the reference rates σ_f is about 5.8 Hz against an
    /// fs/4 = 750 Hz grid top.
    public static func gaborAliasingViolation(_ s: Spec) -> String? {
        guard s.gaborCenters > 0, s.gaborFreqs > 0 else { return nil }
        let nyquist = s.sampleRate / 2.0
        let sigmaT = s.gaborSigmaFrac * Double(s.samples) / s.sampleRate
        guard sigmaT > 0, sigmaT.isFinite else {
            return "gabor envelope width \(sigmaT) s is not a usable time constant"
        }
        let sigmaF = 1.0 / (2.0 * Double.pi * sigmaT)
        // `geomspace(f0, fs/4, gf)`'s top entry is fs/4 exactly for gf > 1,
        // and f0 for gf == 1 (the one-point grid the builder emits).
        let topCenter = s.gaborFreqs == 1 ? s.f0 : s.sampleRate / 4.0
        let reach = topCenter + sigmaF
        guard reach >= nyquist - 1e-9 else { return nil }
        return "gabor atom at \(WaveBank.formatHz(topCenter)) Hz with bandwidth "
            + "\(WaveBank.formatHz(sigmaF)) Hz reaches \(WaveBank.formatHz(reach)) Hz, at or past "
            + "Nyquist \(WaveBank.formatHz(nyquist)) Hz (fs \(WaveBank.formatHz(s.sampleRate))); every "
            + "atom family must stay below fs/2 — write ALIASED to allow"
    }

    /// Formats a value that is, in every call site here, mathematically a
    /// whole number (a rate/frequency derived from integer-ish spec
    /// literals) without a trailing ".0" — matching the frozen contract's
    /// example message text.
    private static func formatHz(_ v: Double) -> String {
        if v.isFinite, v == v.rounded(), abs(v) < 1e15 {
            return String(Int64(v))
        }
        return String(v)
    }

    public let spec: Spec
    public var T: Int { spec.samples }
    public let K: Int

    /// Column-major T×K: `atoms[k*T + t]`. Each column unit-norm.
    public let atoms: [Float]

    public init(spec: Spec) throws {
        if let err = WaveBank.validationError(spec) {
            throw BankError.badSpec(err)
        }
        self.spec = spec
        self.K = spec.atomCount
        self.atoms = WaveBank.buildAtoms(spec: spec)
    }

    // MARK: - Codable (spec only; atoms are rebuilt on decode)

    private enum CodingKeys: String, CodingKey { case spec }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSpec = try container.decode(Spec.self, forKey: .spec)
        if let err = WaveBank.validationError(decodedSpec) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: err))
        }
        self.spec = decodedSpec
        self.K = decodedSpec.atomCount
        self.atoms = WaveBank.buildAtoms(spec: decodedSpec)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(spec, forKey: .spec)
    }

    // MARK: - Atom construction (mirrors mouth_reference.py build_bank)

    private static func linspace(_ start: Double, _ stop: Double, _ num: Int) -> [Double] {
        guard num > 0 else { return [] }
        if num == 1 { return [start] }
        let step = (stop - start) / Double(num - 1)
        var result = (0..<num).map { start + step * Double($0) }
        result[num - 1] = stop
        return result
    }

    private static func geomspace(_ start: Double, _ stop: Double, _ num: Int) -> [Double] {
        guard num > 0 else { return [] }
        if num == 1 { return [start] }
        let logStart = log(start)
        let logStop = log(stop)
        let step = (logStop - logStart) / Double(num - 1)
        var result = (0..<num).map { exp(logStart + step * Double($0)) }
        result[0] = start
        result[num - 1] = stop
        return result
    }

    private static func buildAtoms(spec: Spec) -> [Float] {
        let T = spec.samples
        let fs = spec.sampleRate
        let f0 = spec.f0
        let H = spec.harmonics
        let gc = spec.gaborCenters
        let gf = spec.gaborFreqs
        let K = spec.atomCount

        var t = [Double](repeating: 0, count: T)
        for i in 0..<T { t[i] = Double(i) / fs }

        var atoms = [Float](repeating: 0, count: T * K)
        var col = 0

        // Cast to Float32, THEN normalize by a Float32-accumulated norm —
        // matches numpy's float32 `np.linalg.norm` on the cast bank.
        func storeColumn(_ values: [Double]) {
            let base = col * T
            var sumSq: Float = 0
            for i in 0..<T {
                let v = Float(values[i])
                atoms[base + i] = v
                sumSq += v * v
            }
            let norm = sumSq.squareRoot()
            if norm > 0 {
                for i in 0..<T { atoms[base + i] /= norm }
            }
            col += 1
        }

        // Harmonic cos/sin columns, k = 1...H.
        for k in 1...H {
            let kf = Double(k) * f0
            var cosCol = [Double](repeating: 0, count: T)
            var sinCol = [Double](repeating: 0, count: T)
            for i in 0..<T {
                let w = 2 * Double.pi * kf * t[i]
                cosCol[i] = cos(w)
                sinCol[i] = sin(w)
            }
            storeColumn(cosCol)
            storeColumn(sinCol)
        }

        // Gabor atoms: Gaussian envelope on a center/frequency grid.
        if gc > 0 && gf > 0 {
            let sigma = spec.gaborSigmaFrac * Double(T) / fs
            let centers = WaveBank.linspace(0.1, 0.9, gc).map { $0 * Double(T) / fs }
            let freqs = WaveBank.geomspace(f0, fs / 4, gf)
            for tc in centers {
                var env = [Double](repeating: 0, count: T)
                for i in 0..<T {
                    let z = (t[i] - tc) / sigma
                    env[i] = exp(-0.5 * z * z)
                }
                for f in freqs {
                    var cosCol = [Double](repeating: 0, count: T)
                    var sinCol = [Double](repeating: 0, count: T)
                    for i in 0..<T {
                        let w = 2 * Double.pi * f * (t[i] - tc)
                        cosCol[i] = env[i] * cos(w)
                        sinCol[i] = env[i] * sin(w)
                    }
                    storeColumn(cosCol)
                    storeColumn(sinCol)
                }
            }
        }

        return atoms
    }

    // MARK: - Accessors

    public func atom(_ k: Int) -> ArraySlice<Float> {
        let base = k * T
        return atoms[base..<(base + T)]
    }

    /// Double-accumulated column norm — an independent check on the
    /// Float32-accumulated normalization baked into `atoms`.
    public func columnNorm(_ k: Int) -> Double {
        let base = k * T
        var sumSq = 0.0
        for i in 0..<T {
            let v = Double(atoms[base + i])
            sumSq += v * v
        }
        return sumSq.squareRoot()
    }

    // MARK: - Generation (W = Φ·C via cblas_sgemm, no atoms copy)

    /// C is row-major K×M (`C[k*M+m]`); returns W row-major T×M (`W[t*M+m]`).
    /// `atoms` (column-major Φ, T×K) is, read as row-major, exactly Φ^T
    /// (K×T) — so the sgemm call transposes it in place via a flag rather
    /// than copying into a new layout.
    /// Audit C finding 34: `generate` had no ceiling on M — `T * M` sized
    /// an uninitialized allocation and `Int32(M)` TRAPPED above 2^31, while
    /// `bench` had clamped M at 100 000 all along. That clamp is the
    /// declared ceiling; the public entry point refuses past it by name
    /// rather than allocating.
    public static let maxGenerateColumns = 100_000

    /// nil iff `(coefficients, M)` is a bank product this bank can make:
    /// M in `1...maxGenerateColumns` and exactly `K * M` coefficients
    /// (findings 34 and 35).
    public func generateViolation(coefficients: [Float], columns M: Int) -> String? {
        if M < 1 { return "columns \(M) must be >= 1" }
        if M > WaveBank.maxGenerateColumns {
            return "columns \(M) exceeds the ceiling \(WaveBank.maxGenerateColumns) "
                + "(the product would be \(T) x \(M) floats)"
        }
        if coefficients.count != K * M {
            return "coefficient count \(coefficients.count) != K x M (\(K) x \(M) = \(K * M))"
        }
        return nil
    }

    /// Finding 35's refusing door: a length or column-count mismatch is a
    /// thrown, named error instead of an empty array indistinguishable from
    /// an empty request.
    public func generateChecked(coefficients: [Float], columns M: Int) throws -> [Float] {
        if let violation = generateViolation(coefficients: coefficients, columns: M) {
            throw BankError.badSpec(violation)
        }
        return generate(coefficients: coefficients, columns: M)
    }

    public func generate(coefficients: [Float], columns M: Int) -> [Float] {
        // Findings 34/35: the empty return is kept for the callers that
        // already read it that way, but it is no longer SILENT — the value
        // and the true extent go to stderr as a named ERROR line.
        if let violation = generateViolation(coefficients: coefficients, columns: M) {
            FileHandle.standardError.write(Data("ERROR wave_bank generate: \(violation)\n".utf8))
            return []
        }
        guard M >= 1, coefficients.count == K * M else { return [] }
        // Uninitialized on purpose: sgemm with beta = 0 writes every entry,
        // and a zero-fill pass over a 164 MB output (M = 10000) would cost
        // as much as the product itself and misreport the throughput.
        var W = [Float](unsafeUninitializedCapacity: T * M) { _, count in count = T * M }
        cblas_sgemm(CblasRowMajor, CblasTrans, CblasNoTrans,
                    Int32(T), Int32(M), Int32(K),
                    1.0,
                    atoms, Int32(T),
                    coefficients, Int32(M),
                    0.0,
                    &W, Int32(M))
        return W
    }

    // MARK: - Least squares fit (dgels_ on a Double copy of atoms)

    public struct Fit: Equatable {
        public let residual: Double
        public let targetNorm: Double
        public let coefficients: [Float]

        public init(residual: Double, targetNorm: Double, coefficients: [Float]) {
            self.residual = residual
            self.targetNorm = targetNorm
            self.coefficients = coefficients
        }
    }

    /// Least squares c* = argmin ‖target − Φc‖ via LAPACK `dgelsd_` (SVD,
    /// divide-and-conquer) on a Double copy of `atoms`.
    ///
    /// `dgelsd_` rather than a plain QR solve (`dgels_`): Φ, once its
    /// columns are cast to Float32 and normalized, is not full column rank
    /// in any numerically stable sense — its condition number is of order
    /// 1e17 (checked independently against the numpy bank's own SVD; its
    /// effective rank is ~146 of 160, not 160). A QR-based solve has no way
    /// to see that and returns a "successful" (INFO=0) solution with
    /// coefficients of order 1e15 along the near-null directions — verified
    /// as a property of Φ itself, not a call-site bug, by reproducing the
    /// identical blow-up outside this engine via `scipy.linalg.lstsq` with
    /// both `gelsd` (unconstrained) and `gelsy`. numpy's own reference
    /// (`lstsq(..., rcond=None)`) is SVD-based and truncates singular
    /// values below `eps(float32) * max(T,K)` — matching that RCOND here
    /// reproduces its coefficients and residual to ~1e-8.
    ///
    /// dgelsd_ destroys its A argument, so the copy used to solve is
    /// separate from the one used afterward to compute the residual.
    /// residual = ‖target − Φc*‖₂ / ‖target‖₂, both norms in Double; 0 when
    /// the target is silent.
    public func fit(_ target: [Float]) -> Fit? {
        guard target.count == T else { return nil }

        var targetNormSq = 0.0
        for v in target {
            let d = Double(v)
            targetNormSq += d * d
        }
        let targetNorm = targetNormSq.squareRoot()

        if targetNorm == 0 {
            return Fit(residual: 0, targetNorm: 0, coefficients: [Float](repeating: 0, count: K))
        }

        let atomsD = atoms.map(Double.init)   // unmodified copy, kept for the residual
        var A = atomsD                        // dgelsd_ destroys its A argument
        var b = [Double](repeating: 0, count: T)   // length max(T,K) == T
        for i in 0..<T { b[i] = Double(target[i]) }

        var m = __CLPK_integer(T)
        var n = __CLPK_integer(K)
        var nrhs = __CLPK_integer(1)
        var lda = __CLPK_integer(T)
        var ldb = __CLPK_integer(T)
        var singularValues = [Double](repeating: 0, count: K)
        // eps(float32) * max(T,K) — the same RCOND numpy's lstsq(rcond=None)
        // applies for a float32 bank.
        var rcond = Double(Float.ulpOfOne) * Double(max(T, K))
        var rank: __CLPK_integer = 0
        var info: __CLPK_integer = 0

        var workQuery = [Double](repeating: 0, count: 1)
        var lworkQuery = __CLPK_integer(-1)
        var iworkQuery = [__CLPK_integer](repeating: 0, count: 1)
        dgelsd_(&m, &n, &nrhs, &A, &lda, &b, &ldb, &singularValues, &rcond, &rank,
                &workQuery, &lworkQuery, &iworkQuery, &info)
        guard info == 0 else { return nil }

        let optimalLwork = max(Int(workQuery[0]), 1)
        let liwork = max(Int(iworkQuery[0]), 1)
        var work = [Double](repeating: 0, count: optimalLwork)
        var iwork = [__CLPK_integer](repeating: 0, count: liwork)
        var lwork = __CLPK_integer(optimalLwork)
        dgelsd_(&m, &n, &nrhs, &A, &lda, &b, &ldb, &singularValues, &rcond, &rank,
                &work, &lwork, &iwork, &info)
        guard info == 0 else { return nil }

        var coefficients = [Float](repeating: 0, count: K)
        for k in 0..<K { coefficients[k] = Float(b[k]) }

        // Independent residual: Φc* recomputed in Double from the
        // unmodified atoms copy (not the QR-factored, destroyed A).
        var approx = [Double](repeating: 0, count: T)
        let mm = Int32(T), kk = Int32(K), lda2 = Int32(T)
        cblas_dgemv(CblasColMajor, CblasNoTrans, mm, kk, 1.0, atomsD, lda2, b, 1, 0.0, &approx, 1)

        var diffSq = 0.0
        for i in 0..<T {
            let d = Double(target[i]) - approx[i]
            diffSq += d * d
        }
        let residual = diffSq.squareRoot() / targetNorm
        return Fit(residual: residual, targetNorm: targetNorm, coefficients: coefficients)
    }

    // MARK: - Declaration (G8 — rank and condition number at bank creation)

    public struct Declaration: Equatable {
        public let rank: Int
        public let conditionNumber: Double
        public let sigmaMax: Double
        public let sigmaMin: Double
        /// Appended fields, audit C finding 33: the LAPACK `info` the two
        /// `dgesdd_` calls returned (0 = success), and a message naming the
        /// failure when this declaration is not a trustworthy one (a LAPACK
        /// failure, or a zero smallest singular value making the condition
        /// number non-finite). `nil` on the ordinary path.
        public let lapackInfo: Int
        public let refusal: String?

        public init(rank: Int, conditionNumber: Double, sigmaMax: Double, sigmaMin: Double,
                    lapackInfo: Int = 0, refusal: String? = nil) {
            self.rank = rank
            self.conditionNumber = conditionNumber
            self.sigmaMax = sigmaMax
            self.sigmaMin = sigmaMin
            self.lapackInfo = lapackInfo
            self.refusal = refusal
        }
    }

    /// Singular values of the Double copy of `atoms` via LAPACK `dgesdd_`
    /// (JOBZ "N", singular values only — same workspace-query call style as
    /// `dgelsd_` in `fit`). rank = count of σ_i > σ_max·1e-9 (the twin
    /// lane's rule, SPEC8_MOUTH_GATES_FROZEN.md AMENDMENT 2); condition
    /// number = σ_max/σ_min over ALL K singular values — σ_min is the
    /// smallest one, even if it prints as numerically zero, because that is
    /// what the twin lane's own diagnostic prints. Computed fresh on every
    /// call (no caching): ~10 ms at 4096×160.
    public func declaration() -> Declaration {
        var A = atoms.map(Double.init)   // dgesdd_ destroys A; local copy only
        var jobz: Int8 = 0x4E            // 'N' — singular values only, no U/VT
        var m = __CLPK_integer(T)
        var n = __CLPK_integer(K)
        var lda = __CLPK_integer(T)
        var s = [Double](repeating: 0, count: K)
        var u = [Double](repeating: 0, count: 1)
        var ldu = __CLPK_integer(1)
        var vt = [Double](repeating: 0, count: 1)
        var ldvt = __CLPK_integer(1)
        var iwork = [__CLPK_integer](repeating: 0, count: 8 * K)
        var info: __CLPK_integer = 0

        var workQuery = [Double](repeating: 0, count: 1)
        var lworkQuery = __CLPK_integer(-1)
        dgesdd_(&jobz, &m, &n, &A, &lda, &s, &u, &ldu, &vt, &ldvt, &workQuery, &lworkQuery, &iwork, &info)

        let optimalLwork = max(Int(workQuery[0]), 1)
        var work = [Double](repeating: 0, count: optimalLwork)
        var lwork = __CLPK_integer(optimalLwork)
        dgesdd_(&jobz, &m, &n, &A, &lda, &s, &u, &ldu, &vt, &ldvt, &work, &lwork, &iwork, &info)

        // s is LAPACK-sorted descending: σ_1 ≥ σ_2 ≥ ... ≥ σ_K.
        let sigmaMax = s.first ?? 0
        let sigmaMin = s.last ?? 0
        let threshold = sigmaMax * 1e-9
        let rank = s.reduce(0) { $0 + ($1 > threshold ? 1 : 0) }
        // Audit C finding 33: `info` from BOTH dgesdd_ calls was discarded
        // (`fit` guards its own), and σ_max/σ_min had no zero guard — a
        // LAPACK failure or a rank-deficient bank returned rank 0 and a
        // NaN/inf condition number dressed as a valid Declaration. The
        // failure is now NAMED on stderr and carried in the Declaration
        // itself (`lapackInfo`, `refusal`), and `declarationChecked()`
        // refuses to hand one back at all.
        let conditionNumber = sigmaMin > 0 ? sigmaMax / sigmaMin : Double.infinity
        var refusal: String? = nil
        if info != 0 {
            refusal = "dgesdd_ failed with info=\(info) over a \(T)x\(K) bank"
        } else if !(sigmaMin > 0) {
            refusal = "smallest singular value is \(sigmaMin): the bank is rank deficient "
                + "(rank \(rank) of \(K)) and its condition number is not finite"
        }
        if let refusal = refusal {
            FileHandle.standardError.write(Data("ERROR wave_bank declaration: \(refusal)\n".utf8))
        }
        return Declaration(rank: rank, conditionNumber: conditionNumber,
                            sigmaMax: sigmaMax, sigmaMin: sigmaMin,
                            lapackInfo: Int(info), refusal: refusal)
    }

    /// Finding 33's refusing door: a declaration whose CONDITION NUMBER is
    /// a usable statement, or a named refusal. That is stricter than
    /// `declaration()`'s own `refusal`, which fires only on a LAPACK
    /// failure or a literally zero / non-finite smallest singular value:
    /// LAPACK returns its own floor (a value near 1e-17) rather than an
    /// exact zero for a bank with duplicated columns, and sigmaMax/sigmaMin
    /// is then a finite number that means nothing. The threshold is the one
    /// `rank` already uses — sigmaMax·1e-9, the twin lane's rule.
    ///
    /// `declaration()` itself keeps its shape and stays silent about mere
    /// rank deficiency, because the sealed 160-atom CONTROL bank is
    /// deliberately rank deficient (146 of 160) and its printed numbers are
    /// a gate of their own.
    public func declarationChecked() throws -> Declaration {
        let d = declaration()
        if let refusal = d.refusal {
            throw BankError.badSpec(refusal)
        }
        guard d.sigmaMin > d.sigmaMax * 1e-9 else {
            throw BankError.badSpec(
                "smallest singular value \(d.sigmaMin) is at or below the rank threshold "
                + "\(d.sigmaMax * 1e-9) (rank \(d.rank) of \(K)); the condition number "
                + "\(d.conditionNumber) is not a usable statement about this bank")
        }
        return d
    }

    // MARK: - Reference probe

    /// sign(sin(2π·137·t/fs))·exp(−3t/T), t = 0..T−1, computed in Double
    /// then cast to Float; sign(0) = 0 as numpy.
    public static func referenceProbe(spec: Spec) -> [Float] {
        let T = spec.samples
        let fs = spec.sampleRate
        var result = [Float](repeating: 0, count: T)
        for i in 0..<T {
            let n = Double(i)
            let s = sin(2.0 * Double.pi * 137.0 * n / fs)
            let sgn: Double = s > 0 ? 1.0 : (s < 0 ? -1.0 : 0.0)
            let env = exp(-n / Double(T) * 3.0)
            result[i] = Float(sgn * env)
        }
        return result
    }

    // MARK: - Gaussian noise (Box–Muller over the PCG stream)

    /// u1, u2 drawn from `stream.next64() >> 11` scaled to [0,1); z0, z1
    /// produced per Box–Muller pair, consumed in order.
    public static func gaussianNoise(count: Int, stream: inout NamedStream) -> [Float] {
        guard count > 0 else { return [] }
        var result = [Float](repeating: 0, count: count)
        var i = 0
        while i < count {
            let u1 = Double(stream.next64() >> 11) / 9007199254740992.0
            let u2 = Double(stream.next64() >> 11) / 9007199254740992.0
            let r = (-2.0 * log(1.0 - u1)).squareRoot()
            let theta = 2.0 * Double.pi * u2
            result[i] = Float(r * cos(theta))
            i += 1
            if i < count {
                result[i] = Float(r * sin(theta))
                i += 1
            }
        }
        return result
    }

    // MARK: - Out-of-bank noise law (G3)

    public struct NoiseLaw: Equatable {
        public let expected: Double
        public let residuals: [Double]

        public init(expected: Double, residuals: [Double]) {
            self.expected = expected
            self.residuals = residuals
        }

        public var mean: Double { residuals.isEmpty ? 0 : residuals.reduce(0, +) / Double(residuals.count) }
        public var min: Double { residuals.min() ?? 0 }
        public var max: Double { residuals.max() ?? 0 }
    }

    /// Seed i (0..<n): copy the stream, advance it by 2*T*i draws, draw T
    /// Gaussians, fit. Independent-ish substreams spaced apart in one PCG
    /// sequence, per the frozen gate contract (G3).
    public func noiseLaw(seeds n: Int, stream: NamedStream) -> NoiseLaw {
        var residuals: [Double] = []
        residuals.reserveCapacity(n)
        for i in 0..<n {
            var s = stream
            let advanceCount = 2 * T * i
            for _ in 0..<advanceCount { _ = s.next64() }
            let noise = WaveBank.gaussianNoise(count: T, stream: &s)
            let residual = fit(noise)?.residual ?? Double.nan
            residuals.append(residual)
        }
        let expected = WaveBank.expectedNoiseResidual(T: T, K: K)
        return NoiseLaw(expected: expected, residuals: residuals)
    }

    /// Expected out-of-bank residual for i.i.d. white noise projected onto a
    /// fixed K-dimensional subspace of ℝ^T: sqrt(1 − K/T).
    public static func expectedNoiseResidual(T: Int, K: Int) -> Double {
        (1.0 - Double(K) / Double(T)).squareRoot()
    }

    // MARK: - Throughput (G6, printed, not gated)

    public struct Bench: Equatable {
        public let columns: Int
        public let reps: Int
        public let bestSeconds: Double
        public let samplesPerSecond: Double

        public init(columns: Int, reps: Int, bestSeconds: Double, samplesPerSecond: Double) {
            self.columns = columns
            self.reps = reps
            self.bestSeconds = bestSeconds
            self.samplesPerSecond = samplesPerSecond
        }
    }

    public func bench(columns M: Int, reps: Int) -> Bench {
        let clampedM = Swift.min(Swift.max(M, 1), 100_000)
        let clampedReps = Swift.min(Swift.max(reps, 1), 20)

        var stream = NamedStream(name: "bench",
                                  stateHi: 0x853c_49e6_748f_ea9b, stateLo: 0xda3e_39cb_94b9_5bdb,
                                  incHi: 0x5851_f42d_4c95_7f2d, incLo: 0x1405_7b7e_f767_814f)
        let coefficients = WaveBank.gaussianNoise(count: K * clampedM, stream: &stream)

        // Warm-up: a contiguous prefix of `coefficients` sized to min(M,16)
        // columns — content is irrelevant, only the shape exercises the
        // sgemm path once before timing.
        let warmCols = Swift.min(clampedM, 16)
        let warmCoefficients = Array(coefficients.prefix(K * warmCols))
        _ = generate(coefficients: warmCoefficients, columns: warmCols)

        var best = Double.greatestFiniteMagnitude
        for _ in 0..<clampedReps {
            let start = DispatchTime.now()
            _ = generate(coefficients: coefficients, columns: clampedM)
            let end = DispatchTime.now()
            let seconds = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
            best = Swift.min(best, seconds)
        }
        let samplesPerSecond = Double(T * clampedM) / best
        return Bench(columns: clampedM, reps: clampedReps, bestSeconds: best, samplesPerSecond: samplesPerSecond)
    }
}
