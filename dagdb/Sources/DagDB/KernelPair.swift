import Foundation

/// A per-path kernel pair (root→A, root→B) with the metadata declared at
/// load time — twin spec line 6, second half. See
/// docs/contracts/KERNELS_GATES_FROZEN.md. Storage is by reference (path +
/// sha); this type is the in-memory pair once loaded, plus the derived-
/// warmup rule from K4.
public struct KernelPair: Equatable, Codable {
    public struct Meta: Equatable, Codable {
        public let fs: Double
        public let window: Int
        public let earA: Int
        public let earB: Int
        public let tauA: Double?
        public let tauB: Double?
        public let sigmaSource: Double?
        public let declaredWarmup: Int?

        public init(fs: Double, window: Int, earA: Int, earB: Int,
                    tauA: Double? = nil, tauB: Double? = nil,
                    sigmaSource: Double? = nil, declaredWarmup: Int? = nil) {
            self.fs = fs
            self.window = window
            self.earA = earA
            self.earB = earB
            self.tauA = tauA
            self.tauB = tauB
            self.sigmaSource = sigmaSource
            self.declaredWarmup = declaredWarmup
        }
    }

    public let kA: [Double]
    public let kB: [Double]
    public let meta: Meta

    /// The sealed W1 kernels file's own sha256 — the same constant
    /// `Tests/Fixtures/w1_kernels.sha256` carries. Audit C finding 23
    /// (ruling: "the sha pin defaults to the sealed constant"): `load`
    /// defaults `expectedSHA256` to this, so a caller who says nothing
    /// gets the pin the type's doc promises rather than an unverified read.
    public static let sealedSHA256 =
        "2523d3a8a4de44b56268ee31a703b6bcc6522c7c66a305651f8ec7c03e5c56b8"

    private static var warnedUnpinned = false

    public enum KernelError: Error, Equatable {
        case badKernel(String)
        case fileNotFound(String)
        case shaMismatch(expected: String, actual: String)
        case badLayout(String)
    }

    public init(kA: [Double], kB: [Double], meta: Meta) throws {
        guard !kA.isEmpty, !kB.isEmpty else {
            throw KernelError.badKernel("kernel arrays must be non-empty")
        }
        guard kA.count == kB.count else {
            throw KernelError.badKernel("kA.count (\(kA.count)) != kB.count (\(kB.count))")
        }
        guard kA.allSatisfy({ $0.isFinite }), kB.allSatisfy({ $0.isFinite }) else {
            throw KernelError.badKernel("kernel taps must all be finite")
        }
        // Audit C finding 26: `Meta.init` checks nothing, so a non-finite
        // tau/sigma/fs reached `derivedWarmup`, where `Int(inf)` /
        // `Int(nan)` TRAPPED, and a negative sigma produced a negative
        // warmup silently. Every declared Double is refused by name here —
        // `KernelPair.init` is the one throwing door every path (including
        // `load`) goes through.
        guard meta.fs.isFinite else {
            throw KernelError.badLayout("fs \(meta.fs) must be finite")
        }
        if let tauA = meta.tauA, !tauA.isFinite {
            throw KernelError.badLayout("tauA \(tauA) must be finite")
        }
        if let tauB = meta.tauB, !tauB.isFinite {
            throw KernelError.badLayout("tauB \(tauB) must be finite")
        }
        if let sigma = meta.sigmaSource {
            guard sigma.isFinite else {
                throw KernelError.badLayout("sigmaSource \(sigma) must be finite")
            }
            guard sigma >= 0 else {
                throw KernelError.badLayout("sigmaSource \(sigma) must be >= 0")
            }
        }
        guard meta.window >= 0 else {
            throw KernelError.badLayout("window_samples \(meta.window) must be >= 0")
        }
        if let declared = meta.declaredWarmup, declared < 0 {
            throw KernelError.badLayout("declared warmup \(declared) must be >= 0")
        }
        self.kA = kA
        self.kB = kB
        self.meta = meta
    }

    public var taps: Int { kA.count }

    /// K4: warmup = ceil((|τ_A − τ_B| + 3·σ_source)·fs), only when τ_A, τ_B,
    /// σ_source are all present and fs > 0. For W1: 185.
    public var derivedWarmup: Int? {
        guard let tauA = meta.tauA, let tauB = meta.tauB,
              let sigmaSource = meta.sigmaSource, meta.fs > 0 else {
            return nil
        }
        let value = (abs(tauA - tauB) + 3.0 * sigmaSource) * meta.fs
        // Finding 26: `KernelPair.init` already refuses non-finite inputs;
        // this belt keeps the `Int(...)` conversion itself total for any
        // product that still lands outside Int (a huge but finite fs).
        let rounded = value.rounded(.up)
        guard let exact = Int(exactly: rounded.isFinite ? rounded : Double.nan) else { return nil }
        return exact
    }

    /// Audit C finding 28: a resolved warmup was never compared against
    /// anything — the mismatch only surfaced as a silent clamp downstream
    /// in `CrossConvolutionCheck`. `nil` iff `value` leaves a non-empty
    /// comparison window against the declared `window_samples`; otherwise
    /// a message naming the warmup, the window and the taps.
    public func warmupViolation(_ value: Int) -> String? {
        if value < 0 {
            return "warmup \(value) must be >= 0"
        }
        if value >= meta.window {
            return "warmup \(value) leaves no comparison window against "
                + "window_samples \(meta.window) (taps \(taps))"
        }
        return nil
    }

    /// `warmup(override:)`, but refusing by name (finding 28) instead of
    /// handing back a warmup that cannot leave a non-empty window.
    public func checkedWarmup(override: Int?) throws -> (value: Int, derived: Bool)? {
        guard let resolved = warmup(override: override) else { return nil }
        if let violation = warmupViolation(resolved.value) {
            throw KernelError.badLayout(violation)
        }
        return resolved
    }

    /// Resolution order: explicit override > derived (from τ/σ) > declared
    /// (from the load line) > nil ("no derived warmup" per K4).
    public func warmup(override: Int?) -> (value: Int, derived: Bool)? {
        if let override = override {
            return (override, false)
        }
        if let derived = derivedWarmup {
            return (derived, true)
        }
        if let declared = meta.declaredWarmup {
            return (declared, false)
        }
        return nil
    }

    /// Loads a kernel pair from a JSON file shaped like the sealed
    /// `w1_kernels.json` (kA, kB arrays of Double of equal length ≥ 1; fs
    /// Double; window_samples Int; ear_index_A/ear_index_B Int; other keys
    /// ignored). SHA-256 is always computed over the whole file and
    /// returned; when `expectedSHA256` is given it must match or the load
    /// throws `shaMismatch`. τ/σ/declaredWarmup are declared by the caller
    /// (K4: not read from the kernels file).
    public static func load(path: String, expectedSHA256: String? = sealedSHA256,
                             tauA: Double? = nil, tauB: Double? = nil,
                             sigmaSource: Double? = nil,
                             declaredWarmup: Int? = nil) throws -> (pair: KernelPair, sha256: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            throw KernelError.fileNotFound(path)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let actualSHA = DagDBSnapshot.sha256Hex(data)
        if let expected = expectedSHA256 {
            if expected != actualSHA {
                throw KernelError.shaMismatch(expected: expected, actual: actualSHA)
            }
        } else if !warnedUnpinned {
            warnedUnpinned = true
            FileHandle.standardError.write(Data((
                "WARN unpinned fixture: KernelPair.load called with expectedSHA256 = nil; "
                + "the sha256 pin is the kernels file's only integrity check\n").utf8))
        }

        guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KernelError.badLayout("root is not a JSON object")
        }

        func doubleArray(_ key: String) throws -> [Double] {
            guard let raw = top[key] as? [Any] else {
                throw KernelError.badLayout("missing or malformed array '\(key)'")
            }
            return try raw.map {
                guard let n = $0 as? NSNumber else {
                    throw KernelError.badLayout("non-numeric entry in '\(key)'")
                }
                return n.doubleValue
            }
        }
        func doubleField(_ key: String) throws -> Double {
            guard let n = top[key] as? NSNumber else {
                throw KernelError.badLayout("missing or malformed field '\(key)'")
            }
            return n.doubleValue
        }
        /// Finding 27: `NSNumber.intValue` silently truncated any JSON
        /// number — `2.7` became 2 and `1e20` became garbage. The value
        /// must be integral and representable as an Int, named otherwise.
        func intField(_ key: String) throws -> Int {
            guard let n = top[key] as? NSNumber else {
                throw KernelError.badLayout("missing or malformed field '\(key)'")
            }
            let d = n.doubleValue
            guard d.isFinite else {
                throw KernelError.badLayout("field '\(key)' is \(d), not an integer")
            }
            guard d == d.rounded() else {
                throw KernelError.badLayout("field '\(key)' is \(d), not an integer")
            }
            guard let exact = Int(exactly: d) else {
                throw KernelError.badLayout("field '\(key)' is \(d), outside the Int range")
            }
            return exact
        }

        let kA = try doubleArray("kA")
        let kB = try doubleArray("kB")
        let fs = try doubleField("fs")
        let window = try intField("window_samples")
        let earA = try intField("ear_index_A")
        let earB = try intField("ear_index_B")

        let meta = Meta(fs: fs, window: window, earA: earA, earB: earB,
                         tauA: tauA, tauB: tauB, sigmaSource: sigmaSource,
                         declaredWarmup: declaredWarmup)
        do {
            let pair = try KernelPair(kA: kA, kB: kB, meta: meta)
            // Finding 28: a declared/derived warmup that cannot leave a
            // non-empty comparison window is refused HERE, at the load, not
            // clamped silently by the check that later applies it.
            _ = try pair.checkedWarmup(override: nil)
            return (pair, actualSHA)
        } catch let e as KernelError {
            throw e
        }
    }
}
