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
        return Int(value.rounded(.up))
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
    public static func load(path: String, expectedSHA256: String?,
                             tauA: Double? = nil, tauB: Double? = nil,
                             sigmaSource: Double? = nil,
                             declaredWarmup: Int? = nil) throws -> (pair: KernelPair, sha256: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            throw KernelError.fileNotFound(path)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let actualSHA = DagDBSnapshot.sha256Hex(data)
        if let expected = expectedSHA256, expected != actualSHA {
            throw KernelError.shaMismatch(expected: expected, actual: actualSHA)
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
        func intField(_ key: String) throws -> Int {
            guard let n = top[key] as? NSNumber else {
                throw KernelError.badLayout("missing or malformed field '\(key)'")
            }
            return n.intValue
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
            return (pair, actualSHA)
        } catch let e as KernelError {
            throw e
        }
    }
}
