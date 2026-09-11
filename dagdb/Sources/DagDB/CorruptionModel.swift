import Foundation

/// Corruption model — twin spec line 4's successor pre-gate. Three knobs
/// (εm liar-swap, εs drift-softening, εn noise) act on the READ of an
/// alarm, before the decision map; the true world and the miss-court are
/// untouched (served = the bought tier holds the TRUE culprit in the true
/// pocket — coincidental rescue counts). Probabilities are weights of
/// exact enumeration, never a die roll (corruption-model specification of 2026-08-26, quoted
/// verbatim in `market/build_pregate_successor.py`'s
/// `CORRUPTION_MODEL_VERBATIM`); this type is a bit-for-bit mirror of
/// that script's `true_branches` / `phantom_subsets` / `enumerate_outcomes`.
public struct CorruptionModel: Equatable, Codable {
    public let epsM: Double
    public let epsS: Double
    public let epsN: Double

    public enum CorruptionError: Error, Equatable {
        case knobOutOfRange(String, Double)
    }

    public init(epsM: Double, epsS: Double, epsN: Double) throws {
        for (name, v) in [("epsM", epsM), ("epsS", epsS), ("epsN", epsN)] {
            guard v.isFinite, v >= 0.0, v <= 1.0 else {
                throw CorruptionError.knobOutOfRange(name, v)
            }
        }
        self.epsM = epsM
        self.epsS = epsS
        self.epsN = epsN
    }

    /// One branch of a culprit's TRUE-claim read: how it shows up (or
    /// doesn't) in the frame for decision-making. Not filtered by weight
    /// — a home branch at εm=1 keeps its zero-weight entry here; callers
    /// (`enumerateOutcomes`) skip zero weight, exactly as the Python hand
    /// does in `enumerate_outcomes` (not in `true_branches`).
    public struct Branch: Equatable {
        public let weight: Double
        public let claim: SealedClaim?
        public init(weight: Double, claim: SealedClaim?) {
            self.weight = weight
            self.claim = claim
        }
    }

    /// One of the 16 phantom masks (pocket q ∈ {3,4,5,6} independently
    /// spawns a phantom liar-of-q claim with probability εn/4).
    public struct PhantomSubset: Equatable {
        public let weight: Double
        public let pockets: [Int]
        public init(weight: Double, pockets: [Int]) {
            self.weight = weight
            self.pockets = pockets
        }
    }

    /// One enumerated outcome: a true-branch paired with a phantom mask.
    /// `claims` lists phantoms first (ascending pocket), then the branch's
    /// own (possibly swapped/unread) read claim, if any.
    public struct Outcome: Equatable {
        public let weight: Double
        public let claims: [SealedClaim]
        public init(weight: Double, claims: [SealedClaim]) {
            self.weight = weight
            self.claims = claims
        }

        /// pocket -> value rows of every claim landing there, in claim
        /// order (phantoms, then the read claim) — exactly the shape
        /// `allocatorDecide`/`greedyDecide` consume.
        public var pocketClaims: [Int: [ValueRow]] {
            var d: [Int: [ValueRow]] = [:]
            for c in claims {
                d[c.pocket, default: []].append(c.row)
            }
            return d
        }
    }

    private static let otherEars: [Ear: (Ear, Ear)] = [
        .A: (.B, .C),
        .B: (.A, .C),
        .C: (.A, .B),
    ]

    /// The culprit's true-claim read branches (mirrors `true_branches`).
    /// quiet: [(1, nil)]. deep: [(1, (6,D))], untouched by every knob.
    /// liar(ear): [(1-εm, home), (εm/2, other1), (εm/2, other2)] in the
    /// frozen `OTHER_EARS` order (A→[B,C], B→[A,C], C→[A,B]). drift:
    /// [(1-εs, (6,L)), (εs, nil)] — softened means unread, no substitute.
    public func trueBranches(for culprit: CulpritClass) -> [Branch] {
        switch culprit {
        case .quiet:
            return [Branch(weight: 1.0, claim: nil)]
        case .deep:
            return [Branch(weight: 1.0, claim: SealedClaim(pocket: SealedCourt.deepPocket, row: .D, isPhantom: false))]
        case .liar(let ear):
            let home = SealedCourt.pocket(for: ear)
            let (o1, o2) = Self.otherEars[ear]!
            return [
                Branch(weight: 1.0 - epsM, claim: SealedClaim(pocket: home, row: .L, isPhantom: false)),
                Branch(weight: epsM / 2.0, claim: SealedClaim(pocket: SealedCourt.pocket(for: o1), row: .L, isPhantom: false)),
                Branch(weight: epsM / 2.0, claim: SealedClaim(pocket: SealedCourt.pocket(for: o2), row: .L, isPhantom: false)),
            ]
        case .drift:
            return [
                Branch(weight: 1.0 - epsS, claim: SealedClaim(pocket: SealedCourt.driftPocket, row: .L, isPhantom: false)),
                Branch(weight: epsS, claim: nil),
            ]
        }
    }

    /// The 16 phantom masks, mask 0..15, mirroring `phantom_subsets`:
    /// bit i of the mask selects `SealedCourt.pockets[i]`; weight is the
    /// product over the four bits of (q if set else 1-q), q = εn/4.
    public func phantomSubsets() -> [PhantomSubset] {
        let q = epsN / 4.0
        var out: [PhantomSubset] = []
        out.reserveCapacity(16)
        for mask in 0..<16 {
            var subset: [Int] = []
            var w = 1.0
            for i in 0..<4 {
                let bitSet = (mask & (1 << i)) != 0
                if bitSet { subset.append(SealedCourt.pockets[i]) }
                w *= bitSet ? q : (1.0 - q)
            }
            out.append(PhantomSubset(weight: w, pockets: subset))
        }
        return out
    }

    /// Full enumeration for one culprit class: outer `trueBranches`, inner
    /// `phantomSubsets`, weight = w_true * w_phantom, zero-weight outcomes
    /// skipped (mirrors `enumerate_outcomes`). Loop order is preserved
    /// (harmless on the sealed dyadic five, per contract amendment 1 §10).
    public func enumerateOutcomes(for culprit: CulpritClass) -> [Outcome] {
        var out: [Outcome] = []
        for branch in trueBranches(for: culprit) {
            if branch.weight == 0.0 { continue }
            for ph in phantomSubsets() {
                let w = branch.weight * ph.weight
                if w == 0.0 { continue }
                var claims: [SealedClaim] = ph.pockets.map { SealedClaim(pocket: $0, row: .L, isPhantom: true) }
                if let c = branch.claim {
                    claims.append(c)
                }
                out.append(Outcome(weight: w, claims: claims))
            }
        }
        return out
    }

    /// The GROUND-TRUTH pocket/row of a culprit's own carrier — fixed by
    /// class/ear, never varies with how the alarm is read (mirrors
    /// `true_pocket_row_fixed`). This is what miss-scoring checks
    /// against; it is not the per-branch read pocket above.
    public static func truePocketRow(for culprit: CulpritClass) -> SealedClaim? {
        switch culprit {
        case .quiet:
            return nil
        case .deep:
            return SealedClaim(pocket: SealedCourt.deepPocket, row: .D, isPhantom: false)
        case .liar(let ear):
            return SealedClaim(pocket: SealedCourt.pocket(for: ear), row: .L, isPhantom: false)
        case .drift:
            return SealedClaim(pocket: SealedCourt.driftPocket, row: .L, isPhantom: false)
        }
    }
}
