import Foundation

/// Deterministic named random stream — PCG64 (XSL-RR 128/64), bit-compatible
/// with numpy's PCG64 when seeded from an explicitly printed state.
///
/// Twin spec line 3 (deterministic replay): courts pin fixtures to named
/// streams with a pinned draw order. The bridge to the python fixture side is
/// explicit state, not seed hashing: the fixture prints its generator state
/// (state/inc as four 64-bit words), the engine ingests them, and both sides
/// then produce the identical draw sequence. Draws are counted so a replay
/// can assert its position in the stream.
///
/// 128-bit state is carried as (hi, lo) UInt64 pairs — the package floor is
/// macOS 14, below the stdlib UInt128.
public struct NamedStream: Equatable, Codable {
    public let name: String
    public private(set) var draws: UInt64 = 0

    private var stateHi: UInt64
    private var stateLo: UInt64
    private let incHi: UInt64
    private let incLo: UInt64

    private enum CodingKeys: String, CodingKey {
        case name, stateHi, stateLo, incHi, incLo, draws
    }

    private static let multHi: UInt64 = 0x2360_ED05_1FC6_5DA4
    private static let multLo: UInt64 = 0x4385_DF64_9FCC_F645

    /// Seed from an explicitly printed numpy PCG64 state.
    /// `inc` must be the internal (odd) increment exactly as printed.
    public init(name: String, stateHi: UInt64, stateLo: UInt64, incHi: UInt64, incLo: UInt64) {
        self.name = name
        self.stateHi = stateHi
        self.stateLo = stateLo
        self.incHi = incHi
        self.incLo = incLo
    }

    /// State-bearing init — restores a stream mid-sequence (twin spec: daemon
    /// restart in O(1)). `draws` is trusted as printed, not recomputed.
    public init(name: String, stateHi: UInt64, stateLo: UInt64, incHi: UInt64, incLo: UInt64, draws: UInt64) {
        self.name = name
        self.stateHi = stateHi
        self.stateLo = stateLo
        self.incHi = incHi
        self.incLo = incLo
        self.draws = draws
    }

    /// Current internal state words — provenance for slice boundaries:
    /// a stream reseeded from these words continues the sequence exactly.
    public var stateWords: (hi: UInt64, lo: UInt64) { (stateHi, stateLo) }

    /// Increment words (constant for the stream's lifetime).
    public var incWords: (hi: UInt64, lo: UInt64) { (incHi, incLo) }

    /// One 64-bit draw. PCG64 reference order for the 128-bit variant:
    /// step first, then output the new state (XSL-RR).
    public mutating func next64() -> UInt64 {
        // state = state * mult + inc  (mod 2^128)
        let (crossHi, prodLo) = stateLo.multipliedFullWidth(by: Self.multLo)
        let prodHi = crossHi &+ stateLo &* Self.multHi &+ stateHi &* Self.multLo
        let sumLo = prodLo &+ incLo
        let carry: UInt64 = sumLo < prodLo ? 1 : 0
        stateLo = sumLo
        stateHi = prodHi &+ incHi &+ carry
        draws &+= 1

        let xored = stateHi ^ stateLo
        let rot = (stateHi >> 58) & 63          // top 6 bits of the 128-bit state
        return (xored >> rot) | (xored << ((64 &- rot) & 63))
    }
}
