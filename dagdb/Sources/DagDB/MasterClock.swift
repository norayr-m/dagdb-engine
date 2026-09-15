import Foundation

/// One master clock, rational gears — twin spec line 2.
///
/// Every generator and scanner derives from a single tick through a phase
/// accumulator with a RATIONAL gear and a latch. Integer arithmetic only:
/// after N master ticks a gear p/q has fired exactly floor(N·p/q) times —
/// clicks without drift, the class identity of the three clocks (DRT
/// oscillator = machine shove = body carrier) made checkable by
/// construction: the gear graph is printed, no second clock exists.
public struct MasterClock: Equatable, Codable {
    public private(set) var tick: UInt64 = 0
    public init() {}
    /// State-bearing init: restores an exact tick count (snapshot/WAL replay).
    public init(tick: UInt64) { self.tick = tick }
    public mutating func advance() { tick &+= 1 }
}

/// Reduced rational gear — the printed ratio.
public struct GearRatio: Equatable, CustomStringConvertible {
    public let num: UInt64
    public let den: UInt64

    /// S5 (ii): the refusals that used to be `precondition` aborts.
    public enum RatioError: Error, Equatable, CustomStringConvertible {
        case zeroComponent(num: UInt64, den: UInt64)
        case accumulatorUnsafe(num: UInt64, den: UInt64)
        case productOverflows(String)

        public var description: String {
            switch self {
            case .zeroComponent(let n, let d):
                return "gear ratio \(n)/\(d) needs both components > 0"
            case .accumulatorUnsafe(let n, let d):
                return "numerator \(n) can wrap the phase accumulator against denominator \(d)"
            case .productOverflows(let why):
                return why
            }
        }
    }

    /// S5 (ii): the two remaining traps on public paths become thrown
    /// errors. This init used to `precondition` on a zero component and on
    /// an accumulator-unsafe numerator — an abort no caller could catch and
    /// no test could reach. It now refuses by name, and it is the only door
    /// into a `GearRatio`: `reduced` is `try?` over it.
    public init(_ num: UInt64, over den: UInt64) throws {
        guard num > 0, den > 0 else { throw RatioError.zeroComponent(num: num, den: den) }
        guard GearRatio.accumulatorSafe(num: num, den: den) else {
            throw RatioError.accumulatorUnsafe(num: num, den: den)
        }
        var a = num, b = den
        while b != 0 { (a, b) = (b, a % b) }
        self.num = num / a
        self.den = den / a
    }

    /// Finding 67: `PhaseGear.advance` adds `num` to an accumulator whose
    /// invariant is `accumulator < den`, so the largest value ever summed
    /// is `den − 1 + num`. A numerator that makes that exceed UInt64 wraps
    /// the accumulator and silently loses fires — refuse it at the door.
    static func accumulatorSafe(num: UInt64, den: UInt64) -> Bool {
        guard den > 0 else { return false }
        return num <= UInt64.max - (den - 1)
    }

    /// Exact gear composition: (p1/q1) ∘ (p2/q2) = p1·p2 / q1·q2, reduced.
    ///
    /// Finding 66: cross-reduce BEFORE multiplying, so a chain whose
    /// reduced ratio is small never overflows on the unreduced product.
    /// The result is identical to reducing afterwards — gcd is
    /// multiplicative across the two cross pairs.
    public func composed(with other: GearRatio) throws -> GearRatio {
        func gcd(_ x: UInt64, _ y: UInt64) -> UInt64 {
            var a = x, b = y
            while b != 0 { (a, b) = (b, a % b) }
            return a == 0 ? 1 : a
        }
        let g1 = gcd(num, other.den)
        let g2 = gcd(other.num, den)
        let n1 = num / g1, n2 = other.num / g2
        let d1 = den / g2, d2 = other.den / g1
        let (n, nOver) = n1.multipliedReportingOverflow(by: n2)
        let (d, dOver) = d1.multipliedReportingOverflow(by: d2)
        guard !nOver, !dOver else {
            throw RatioError.productOverflows(
                "composed ratio \(num)/\(den) ∘ \(other.num)/\(other.den) does not fit UInt64 even reduced")
        }
        return try GearRatio(n, over: d)
    }

    /// Validating front door: nil iff either component is zero or the
    /// numerator could wrap the phase accumulator, else the reduced ratio
    /// (the daemon's GEAR OPEN must never precondition-trap).
    public static func reduced(_ num: UInt64, over den: UInt64) -> GearRatio? {
        return try? GearRatio(num, over: den)
    }

    public var description: String { "\(num)/\(den)" }
}

extension GearRatio: Codable {
    private enum CodingKeys: String, CodingKey { case num, den }

    /// Decode rejects zero: a corrupted or hand-edited snapshot must never
    /// resurrect a ratio that the validating front door would have refused.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let num = try c.decode(UInt64.self, forKey: .num)
        let den = try c.decode(UInt64.self, forKey: .den)
        guard num > 0, den > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .den, in: c,
                debugDescription: "GearRatio requires num > 0 and den > 0")
        }
        guard GearRatio.accumulatorSafe(num: num, den: den) else {
            throw DecodingError.dataCorruptedError(
                forKey: .num, in: c,
                debugDescription: "GearRatio numerator \(num) can wrap the phase accumulator against denominator \(den)")
        }
        try self.init(num, over: den)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(num, forKey: .num)
        try c.encode(den, forKey: .den)
    }
}

/// Phase accumulator + latch driven by the master tick.
public struct PhaseGear: Equatable, Codable {
    public enum GearError: Error, Equatable, CustomStringConvertible {
        /// Finding 68: the invariant `advance` maintains is
        /// `accumulator < ratio.den`; a restored gear above it fires
        /// `accumulator/den` extra times on its next tick.
        case accumulatorAboveDenominator(accumulator: UInt64, den: UInt64)

        public var description: String {
            switch self {
            case .accumulatorAboveDenominator(let a, let d):
                return "accumulator \(a) must be < denominator \(d)"
            }
        }
    }

    public let name: String
    public let ratio: GearRatio
    public private(set) var accumulator: UInt64 = 0
    public private(set) var fires: UInt64 = 0
    public private(set) var latchedTick: UInt64? = nil
    public private(set) var latchedValue: Float? = nil

    public init(name: String, ratio: GearRatio) {
        self.name = name
        self.ratio = ratio
    }

    /// State-bearing init: restores exact accumulator/fire/latch state
    /// (snapshot/WAL replay), bypassing the tick-by-tick replay entirely.
    public init(name: String, ratio: GearRatio, accumulator: UInt64, fires: UInt64,
                latchedTick: UInt64?, latchedValue: Float?) throws {
        guard accumulator < ratio.den else {
            throw GearError.accumulatorAboveDenominator(accumulator: accumulator, den: ratio.den)
        }
        self.name = name
        self.ratio = ratio
        self.accumulator = accumulator
        self.fires = fires
        self.latchedTick = latchedTick
        self.latchedValue = latchedValue
    }

    /// Advance one master tick carrying the current line value; returns the
    /// number of fires this tick (0 for sub-clocks, >1 for overdriven gears).
    @discardableResult
    public mutating func advance(masterTick: UInt64, value: Float) -> UInt64 {
        accumulator &+= ratio.num
        let fired = accumulator / ratio.den
        if fired > 0 {
            accumulator %= ratio.den
            fires &+= fired
            latchedTick = masterTick
            latchedValue = value
        }
        return fired
    }

    /// Exact phase in [0, 1) as a printed rational — accumulator/den.
    public var phase: (num: UInt64, den: UInt64) { (accumulator, ratio.den) }

    private enum CodingKeys: String, CodingKey {
        case name, ratio, accumulator, fires, latchedTick, latchedValue
    }

    /// Decode enforces the same invariant the state-bearing init does
    /// (finding 68) — a hand-edited or corrupted snapshot must not
    /// resurrect a gear the front door would have refused.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        let ratio = try c.decode(GearRatio.self, forKey: .ratio)
        let accumulator = try c.decodeIfPresent(UInt64.self, forKey: .accumulator) ?? 0
        guard accumulator < ratio.den else {
            throw DecodingError.dataCorruptedError(
                forKey: .accumulator, in: c,
                debugDescription: "accumulator \(accumulator) must be < denominator \(ratio.den)")
        }
        self.name = name
        self.ratio = ratio
        self.accumulator = accumulator
        self.fires = try c.decodeIfPresent(UInt64.self, forKey: .fires) ?? 0
        self.latchedTick = try c.decodeIfPresent(UInt64.self, forKey: .latchedTick)
        self.latchedValue = try c.decodeIfPresent(Float.self, forKey: .latchedValue)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(ratio, forKey: .ratio)
        try c.encode(accumulator, forKey: .accumulator)
        try c.encode(fires, forKey: .fires)
        try c.encodeIfPresent(latchedTick, forKey: .latchedTick)
        try c.encodeIfPresent(latchedValue, forKey: .latchedValue)
    }
}
