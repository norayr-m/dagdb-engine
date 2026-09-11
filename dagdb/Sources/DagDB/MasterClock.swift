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

    public init(_ num: UInt64, over den: UInt64) {
        precondition(num > 0 && den > 0)
        var a = num, b = den
        while b != 0 { (a, b) = (b, a % b) }
        self.num = num / a
        self.den = den / a
    }

    /// Exact gear composition: (p1/q1) ∘ (p2/q2) = p1·p2 / q1·q2, reduced.
    public func composed(with other: GearRatio) -> GearRatio {
        GearRatio(num * other.num, over: den * other.den)
    }

    /// Validating front door: nil iff either component is zero, else the
    /// reduced ratio (the daemon's GEAR OPEN must never precondition-trap).
    public static func reduced(_ num: UInt64, over den: UInt64) -> GearRatio? {
        guard num > 0, den > 0 else { return nil }
        return GearRatio(num, over: den)
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
        self.init(num, over: den)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(num, forKey: .num)
        try c.encode(den, forKey: .den)
    }
}

/// Phase accumulator + latch driven by the master tick.
public struct PhaseGear: Equatable, Codable {
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
                latchedTick: UInt64?, latchedValue: Float?) {
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
}
