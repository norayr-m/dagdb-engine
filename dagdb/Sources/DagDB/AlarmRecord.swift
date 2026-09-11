import Foundation

/// Alarm-stream record — twin spec line 4, the sealed W2 court's frame
/// vocabulary. Three ears (A, B, C), four culprit classes (quiet, liar,
/// deep, drift). No judgement lives here — only the shape sealed by the
/// allocator/successor courts (see `SealedCourt`).
public enum Ear: String, Codable, CaseIterable {
    case A, B, C
}

/// A value row indicates the tier at which a claim's carrier is first
/// held: `L` (liar/drift culprits, carrier at the ear's edge) needs r≥7;
/// `D` (deep culprit) needs r≥4. Quiet culprits carry no row — they never
/// buy anything.
public enum ValueRow: String, Codable {
    case L, D
}

/// The sealed W2 trial classes. `liar` carries the ear it swapped.
public enum CulpritClass: Equatable, Hashable, Codable {
    case quiet
    case liar(Ear)
    case deep
    case drift

    private enum CodingKeys: String, CodingKey { case kind, ear }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "quiet": self = .quiet
        case "deep": self = .deep
        case "drift": self = .drift
        case "liar":
            let ear = try c.decode(Ear.self, forKey: .ear)
            self = .liar(ear)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "unknown CulpritClass kind '\(kind)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .quiet:
            try c.encode("quiet", forKey: .kind)
        case .deep:
            try c.encode("deep", forKey: .kind)
        case .drift:
            try c.encode("drift", forKey: .kind)
        case .liar(let ear):
            try c.encode("liar", forKey: .kind)
            try c.encode(ear, forKey: .ear)
        }
    }
}

/// A single pocket claim in the sealed vocabulary: which pocket, which
/// value row, and whether it is a phantom (corruption-model artifact,
/// never a truth-carrying `AlarmRecord`).
public struct SealedClaim: Equatable, Hashable, Codable {
    public let pocket: Int
    public let row: ValueRow
    public let isPhantom: Bool

    public init(pocket: Int, row: ValueRow, isPhantom: Bool) {
        self.pocket = pocket
        self.row = row
        self.isPhantom = isPhantom
    }
}

/// One replayed W2 record: its file-order index, its JSON key, its
/// culprit class, and (optionally) the three ear waveforms.
public struct AlarmRecord: Equatable, Codable {
    public struct Waveforms: Equatable, Codable {
        public let a: [Float]
        public let b: [Float]
        public let c: [Float]

        public init(a: [Float], b: [Float], c: [Float]) {
            self.a = a
            self.b = b
            self.c = c
        }
    }

    /// 1-based position in the reconstructed file order (see
    /// `AlarmFixture`'s key-order convention).
    public let index: Int
    public let key: String
    public let culprit: CulpritClass
    public let waveforms: Waveforms?

    public init(index: Int, key: String, culprit: CulpritClass, waveforms: Waveforms?) {
        self.index = index
        self.key = key
        self.culprit = culprit
        self.waveforms = waveforms
    }

    /// The ear this record's culprit implicates, if any (liar only).
    public var ear: Ear? {
        if case .liar(let e) = culprit { return e }
        return nil
    }

    /// The class name as it appears in the sealed JSON's "class" field.
    public var rawClass: String {
        switch culprit {
        case .quiet: return "quiet"
        case .liar: return "liar"
        case .deep: return "deep"
        case .drift: return "drift"
        }
    }

    /// The per-ear-split label used by the court's class tallies
    /// ("liar_A"/"liar_B"/"liar_C" split out; "quiet"/"deep"/"drift" as is).
    public var classLabel: String? {
        switch culprit {
        case .quiet: return "quiet"
        case .liar(let ear): return "liar_\(ear.rawValue)"
        case .deep: return "deep"
        case .drift: return "drift"
        }
    }

    /// The sealed pocket this culprit's carrier occupies. Quiet culprits
    /// occupy no pocket — they never buy anything.
    public var pocket: Int? {
        switch culprit {
        case .quiet: return nil
        case .liar(let ear): return SealedCourt.pocket(for: ear)
        case .deep: return SealedCourt.deepPocket
        case .drift: return SealedCourt.driftPocket
        }
    }

    /// The sealed claim this record buys, or nil for quiet (buys nothing).
    public var claim: SealedClaim? {
        switch culprit {
        case .quiet:
            return nil
        case .liar(let ear):
            return SealedClaim(pocket: SealedCourt.pocket(for: ear), row: .L, isPhantom: false)
        case .deep:
            return SealedClaim(pocket: SealedCourt.deepPocket, row: .D, isPhantom: false)
        case .drift:
            return SealedClaim(pocket: SealedCourt.driftPocket, row: .L, isPhantom: false)
        }
    }

    /// True iff this record's carrier sits in the concentration pocket
    /// (pocket 6 — deep, drift, and liar_C all land there).
    public var isBurst: Bool {
        pocket == SealedCourt.concentrationPocket
    }
}
