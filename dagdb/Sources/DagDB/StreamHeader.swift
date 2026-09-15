import Foundation

/// Time-domain stream header — twin spec line 7 (the t-zero law).
///
/// Every stream declares seven quantities BEFORE use; the engine refuses
/// undeclared or inconsistent streams. The three probe deaths that bought
/// this law: an impulse wider than the sphere's window reads as a constant;
/// an early echo dirties the frame; a comb sparser than the signal aliases.
public struct StreamHeader: Equatable, Codable {
    /// 1 · signal band, Hz (highest frequency content).
    public var signalBandHz: Double
    /// 2 · τ-window of the recording surface, seconds.
    public var tauWindowSec: Double
    /// 3 · comb / sampling rate along the surface, Hz (Nyquist gate).
    public var combRateHz: Double
    /// 4 · time to first echo, seconds (frame must close before it).
    public var firstEchoSec: Double
    /// 5 · record window, seconds.
    public var recordWindowSec: Double
    /// 6 · integrator step, seconds (dispersion honesty).
    public var stepSec: Double
    /// 7 · clock sync floor, seconds (0 for a single-clock stream — the only
    ///     sealed regime so far; multi-clock floors must be declared, and a
    ///     declared floor is compared against `stepSec` and
    ///     `recordWindowSec` by `violations()`).
    public var clockSyncFloorSec: Double

    public init(signalBandHz: Double, tauWindowSec: Double, combRateHz: Double,
                firstEchoSec: Double, recordWindowSec: Double, stepSec: Double,
                clockSyncFloorSec: Double) {
        self.signalBandHz = signalBandHz
        self.tauWindowSec = tauWindowSec
        self.combRateHz = combRateHz
        self.firstEchoSec = firstEchoSec
        self.recordWindowSec = recordWindowSec
        self.stepSec = stepSec
        self.clockSyncFloorSec = clockSyncFloorSec
    }

    public enum Violation: Equatable, CustomStringConvertible {
        case nonPositiveQuantity(String)
        case signalWiderThanWindow      // 1/band > τ-window: sphere sees a constant
        case combBelowNyquist           // comb < 2 × band
        case recordOutlivesEcho         // record window ≥ first echo
        case stepAboveNyquist           // step > 1/(2 × band)

        public var description: String {
            switch self {
            case .nonPositiveQuantity(let q): return "non-positive declared quantity: \(q)"
            case .signalWiderThanWindow: return "signal period exceeds tau window (reads as constant)"
            case .combBelowNyquist: return "comb rate below 2x signal band (aliasing)"
            case .recordOutlivesEcho: return "record window reaches the first echo (dirty frame)"
            case .stepAboveNyquist: return "integrator step above Nyquist step for the band"
            }
        }
    }

    /// The t-zero arithmetic, applied in declaration order. Empty == admissible.
    public func violations() -> [Violation] {
        var v: [Violation] = []
        let positives: [(String, Double)] = [
            ("signalBandHz", signalBandHz), ("tauWindowSec", tauWindowSec),
            ("combRateHz", combRateHz), ("firstEchoSec", firstEchoSec),
            ("recordWindowSec", recordWindowSec), ("stepSec", stepSec),
        ]
        for (name, x) in positives where !(x > 0) { v.append(.nonPositiveQuantity(name)) }
        if clockSyncFloorSec < 0 { v.append(.nonPositiveQuantity("clockSyncFloorSec")) }
        guard v.isEmpty else { return v }
        if 1.0 / signalBandHz > tauWindowSec { v.append(.signalWiderThanWindow) }
        if combRateHz < 2.0 * signalBandHz { v.append(.combBelowNyquist) }
        if recordWindowSec >= firstEchoSec { v.append(.recordOutlivesEcho) }
        if stepSec > 1.0 / (2.0 * signalBandHz) { v.append(.stepAboveNyquist) }
        return v
    }

    /// Finding 71: quantity 7 is COMPARED, not merely declared. A
    /// single-clock stream declares 0 and both rules pass trivially — the
    /// sealed regime is untouched. A declared multi-clock floor must be no
    /// coarser than the integrator step (otherwise the step's precision is
    /// a fiction) and must sit strictly inside the record window.
    ///
    /// Kept as its own type, outside `Violation`, so existing exhaustive
    /// switches over that enum stay exhaustive; `isAdmissible` and
    /// `StreamRecord`'s three doors consult both lists.
    public enum ClockSyncViolation: Equatable, CustomStringConvertible {
        case floorAboveStep(floor: Double, step: Double)
        case floorOutlivesRecord(floor: Double, window: Double)

        public var description: String {
            switch self {
            case .floorAboveStep(let f, let s):
                return "clock sync floor \(f) s is coarser than the integrator step \(s) s"
            case .floorOutlivesRecord(let f, let w):
                return "clock sync floor \(f) s reaches the record window \(w) s"
            }
        }
    }

    /// The quantity-7 arithmetic. Empty for every single-clock stream
    /// (floor 0) and for any declared floor finer than the step and
    /// shorter than the window.
    public func clockSyncViolations() -> [ClockSyncViolation] {
        guard clockSyncFloorSec > 0 else { return [] }
        var v: [ClockSyncViolation] = []
        if clockSyncFloorSec > stepSec {
            v.append(.floorAboveStep(floor: clockSyncFloorSec, step: stepSec))
        }
        if clockSyncFloorSec >= recordWindowSec {
            v.append(.floorOutlivesRecord(floor: clockSyncFloorSec, window: recordWindowSec))
        }
        return v
    }

    public var isAdmissible: Bool { violations().isEmpty && clockSyncViolations().isEmpty }
}
