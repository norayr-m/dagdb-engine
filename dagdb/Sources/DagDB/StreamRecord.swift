import Foundation

/// Deterministic stream record — twin spec line 3 (deterministic replay).
///
/// A record binds an admissible time-domain header (t-zero law) to a named
/// generator and stores, per slice, the generator state AT ENTRY plus the
/// draw span. Any slice then replays bit-for-bit in isolation: reseed from
/// the boundary words, draw the span, compare. Courts depend on exactly
/// this property; the record refuses inadmissible headers at birth.
public struct StreamRecord: Equatable, Codable {
    public struct Slice: Equatable, Codable {
        public let index: Int
        public let entryStateHi: UInt64
        public let entryStateLo: UInt64
        public let entryDraws: UInt64
        public let count: Int
        public let payload: [UInt64]

        public init(index: Int, entryStateHi: UInt64, entryStateLo: UInt64, entryDraws: UInt64,
                    count: Int, payload: [UInt64]) {
            self.index = index
            self.entryStateHi = entryStateHi
            self.entryStateLo = entryStateLo
            self.entryDraws = entryDraws
            self.count = count
            self.payload = payload
        }
    }

    public enum RecordError: Error, Equatable, CustomStringConvertible {
        case inadmissibleHeader([StreamHeader.Violation])
        case sliceOutOfRange(Int)
        /// Finding 70: `recordSlice` loops `0..<count` and reserves
        /// `count` words on a public, unbounded `Int`.
        case sliceCountOutOfRange(Int)
        /// Finding 69: the generator's draw counter must account for
        /// exactly the slices the record carries.
        case sliceAccounting(String)
        /// Finding 71: quantity 7 of the t-zero law, compared at last.
        case inadmissibleClockSyncFloor([StreamHeader.ClockSyncViolation])

        public var description: String {
            switch self {
            case .inadmissibleHeader(let v): return "inadmissible header: \(v)"
            case .sliceOutOfRange(let i): return "slice index \(i) out of range"
            case .sliceCountOutOfRange(let n):
                return "slice count \(n) must be in [0, \(StreamRecord.maxSliceCount)]"
            case .sliceAccounting(let why): return "slice accounting: \(why)"
            case .inadmissibleClockSyncFloor(let v):
                return "inadmissible clock sync floor: \(v.map(\.description).joined(separator: "; "))"
            }
        }
    }

    /// Ceiling on one slice's draw count — the same 10 000 the daemon's
    /// tick/advance verbs and the twin replay caps use (finding 70, and
    /// the replay half of finding 63).
    public static let maxSliceCount = 10_000

    /// Finding 69: the slices and the generator must tell one story —
    /// every slice's `count` matches its payload, entry draw counters
    /// chain, and the last slice's end is exactly the generator's own
    /// `draws`. Returns a human-readable reason, or nil when they agree.
    public static func sliceAccountingViolation(slices: [Slice], generator: NamedStream) -> String? {
        guard !slices.isEmpty else { return nil }
        var expectedDraws = slices[0].entryDraws
        for (i, s) in slices.enumerated() {
            guard s.index == i else {
                return "slice \(i) carries index \(s.index)"
            }
            guard s.count >= 0, s.count <= maxSliceCount else {
                return "slice \(i) count \(s.count) out of range"
            }
            guard s.payload.count == s.count else {
                return "slice \(i) declares count \(s.count) but carries \(s.payload.count) words"
            }
            guard s.entryDraws == expectedDraws else {
                return "slice \(i) enters at draw \(s.entryDraws), expected \(expectedDraws)"
            }
            expectedDraws = s.entryDraws &+ UInt64(s.count)
        }
        guard generator.draws == expectedDraws else {
            return "generator has drawn \(generator.draws), slices account for \(expectedDraws)"
        }
        return nil
    }

    public let header: StreamHeader
    public let streamName: String
    public let incHi: UInt64
    public let incLo: UInt64
    public private(set) var slices: [Slice] = []

    private var generator: NamedStream

    /// Current generator state — provenance for a live record (twin spec:
    /// daemon restart in O(1) without replaying every slice).
    public var generatorState: NamedStream { generator }

    private enum CodingKeys: String, CodingKey {
        case header, streamName, incHi, incLo, slices, generator
    }

    /// Birth refuses an inadmissible header — the engine does not carry
    /// undeclared or self-contradictory streams (spec line 7).
    public init(header: StreamHeader, generator: NamedStream) throws {
        let v = header.violations()
        guard v.isEmpty else { throw RecordError.inadmissibleHeader(v) }
        let f = header.clockSyncViolations()
        guard f.isEmpty else { throw RecordError.inadmissibleClockSyncFloor(f) }
        self.header = header
        self.streamName = generator.name
        self.incHi = generator.incWords.hi
        self.incLo = generator.incWords.lo
        self.generator = generator
    }

    /// State-bearing init — restores a record with its slices already drawn;
    /// `generator` carries the draws matching the sum of `slices` counts.
    public init(header: StreamHeader, generator: NamedStream, slices: [Slice]) throws {
        let v = header.violations()
        guard v.isEmpty else { throw RecordError.inadmissibleHeader(v) }
        let f = header.clockSyncViolations()
        guard f.isEmpty else { throw RecordError.inadmissibleClockSyncFloor(f) }
        if let why = Self.sliceAccountingViolation(slices: slices, generator: generator) {
            throw RecordError.sliceAccounting(why)
        }
        self.header = header
        self.streamName = generator.name
        self.incHi = generator.incWords.hi
        self.incLo = generator.incWords.lo
        self.generator = generator
        self.slices = slices
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let header = try c.decode(StreamHeader.self, forKey: .header)
        let v = header.violations()
        guard v.isEmpty else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "inadmissible header: \(v)"))
        }
        let f = header.clockSyncViolations()
        guard f.isEmpty else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "inadmissible clock sync floor: \(f)"))
        }
        self.header = header
        self.streamName = try c.decode(String.self, forKey: .streamName)
        self.incHi = try c.decode(UInt64.self, forKey: .incHi)
        self.incLo = try c.decode(UInt64.self, forKey: .incLo)
        let slices = try c.decode([Slice].self, forKey: .slices)
        let generator = try c.decode(NamedStream.self, forKey: .generator)
        if let why = Self.sliceAccountingViolation(slices: slices, generator: generator) {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "slice accounting: \(why)"))
        }
        self.slices = slices
        self.generator = generator
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(header, forKey: .header)
        try c.encode(streamName, forKey: .streamName)
        try c.encode(incHi, forKey: .incHi)
        try c.encode(incLo, forKey: .incLo)
        try c.encode(slices, forKey: .slices)
        try c.encode(generator, forKey: .generator)
    }

    /// Draw `count` values as the next slice, capturing the entry boundary.
    /// Finding 70: a negative count (which traps on `0..<count`) or one
    /// above `maxSliceCount` (an unbounded allocation) refuses by name.
    @discardableResult
    public mutating func recordSlice(count: Int) throws -> Slice {
        guard count >= 0, count <= Self.maxSliceCount else {
            throw RecordError.sliceCountOutOfRange(count)
        }
        let entry = generator.stateWords
        let entryDraws = generator.draws
        var payload: [UInt64] = []
        payload.reserveCapacity(count)
        for _ in 0..<count { payload.append(generator.next64()) }
        let s = Slice(index: slices.count, entryStateHi: entry.hi, entryStateLo: entry.lo,
                      entryDraws: entryDraws, count: count, payload: payload)
        slices.append(s)
        return s
    }

    /// Replay one slice from its boundary words alone. Returns the
    /// regenerated payload; equality with the stored payload is the
    /// bit-for-bit replay guarantee, and the draw counter must land on
    /// entryDraws + count when re-based at the boundary.
    public func replaySlice(_ index: Int) throws -> [UInt64] {
        guard slices.indices.contains(index) else { throw RecordError.sliceOutOfRange(index) }
        let s = slices[index]
        var g = NamedStream(name: streamName, stateHi: s.entryStateHi, stateLo: s.entryStateLo,
                            incHi: incHi, incLo: incLo)
        var out: [UInt64] = []
        out.reserveCapacity(s.count)
        for _ in 0..<s.count { out.append(g.next64()) }
        return out
    }

    /// Verify every slice replays exactly. Returns the indices that fail
    /// (empty == the record is bit-for-bit reproducible end to end).
    public func verify() -> [Int] {
        var bad: [Int] = []
        for s in slices {
            if let out = try? replaySlice(s.index), out == s.payload { continue }
            bad.append(s.index)
        }
        return bad
    }
}
