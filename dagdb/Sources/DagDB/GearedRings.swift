import Foundation

/// Geared recording rings — twin spec line 1's memory half: the sealed
/// six-ring odometer (M2: signed recall across six orders of lag in 192
/// numbers, 100% with signs) as an engine recording primitive.
///
/// Ring j advances every gear^j ticks; each cell holds the SIGNED extremum
/// of its span and the exact tick it happened. A naive equal-budget tail
/// dies past its capacity and a uniform pyramid drowns the shallow end —
/// only the gearing holds both ends. Consolidation in its pure form:
/// samples discarded, structure kept.
public struct GearedRings: Equatable, Codable {
    public struct Cell: Equatable, Codable {
        public var value: Float      // signed extremum of the span
        public var tick: UInt64      // exact tick of that extremum
        public var span: UInt64      // span index (detects staleness)
        public var occupied: Bool
        public init(value: Float, tick: UInt64, span: UInt64, occupied: Bool) {
            self.value = value
            self.tick = tick
            self.span = span
            self.occupied = occupied
        }
        static let empty = Cell(value: 0, tick: 0, span: 0, occupied: false)
    }

    public let gear: UInt64
    public let rings: Int
    public let cellsPerRing: Int
    public private(set) var now: UInt64 = 0
    private var cells: [[Cell]]

    /// The sealed shape is gear 6, 6 rings, 32 cells (192 numbers).
    /// Finding 65: the ordinary init routes through `shapeViolation` — the
    /// same front door the daemon's RINGS OPEN uses — so it can no longer
    /// accept a shape the validator refuses. Callers that must not trap
    /// (the daemon, WAL replay, snapshot restore) ask `shapeViolation`
    /// first or use the throwing state-bearing init below.
    /// S5 (ii): the `precondition` here was the last trap on this public
    /// path — an abort no caller could catch. It throws `badShape` now,
    /// with the validator's own wording, so the memberwise door and the
    /// state-bearing door below refuse the same shapes the same way.
    public init(gear: UInt64 = 6, rings: Int = 6, cellsPerRing: Int = 32) throws {
        if let violation = Self.shapeViolation(gear: gear, rings: rings, cellsPerRing: cellsPerRing) {
            throw RingsError.badShape(violation)
        }
        self.gear = gear
        self.rings = rings
        self.cellsPerRing = cellsPerRing
        self.cells = Array(repeating: Array(repeating: .empty, count: cellsPerRing), count: rings)
    }

    public enum RingsError: Error, Equatable {
        case badShape(String)
        case cellsMismatch(expectedRings: Int, expectedCells: Int)
    }

    /// Validating front door for a shape triple, for callers (the daemon's
    /// RINGS OPEN) that must never precondition-trap on bad input.
    /// nil iff gear ≥ 2, 1 ≤ rings ≤ 16, 2 ≤ cellsPerRing ≤ 4096, AND the
    /// coarsest span `gear^(rings−1)` fits UInt64.
    public static func shapeViolation(gear: UInt64, rings: Int, cellsPerRing: Int) -> String? {
        guard gear >= 2 else { return "gear \(gear) must be >= 2" }
        guard rings >= 1 && rings <= 16 else { return "rings \(rings) must be in [1, 16]" }
        guard cellsPerRing >= 2 && cellsPerRing <= 4096 else {
            return "cellsPerRing \(cellsPerRing) must be in [2, 4096]"
        }
        // Finding 64: `spanLength` accumulates a WRAPPING multiply; a gear
        // whose gear^(rings-1) overflows wraps the coarsest span to 0 and
        // `now / span` then divides by zero. Bound the gear here, where
        // every trap-free caller already looks.
        var span: UInt64 = 1
        for _ in 0..<(rings - 1) {
            let (product, overflow) = span.multipliedReportingOverflow(by: gear)
            if overflow {
                return "gear \(gear) raised to rings-1 (\(rings - 1)) overflows UInt64"
            }
            span = product
        }
        return nil
    }

    /// State-bearing init: restores an exact ring state (e.g. from a
    /// snapshot or WAL replay). Throws rather than preconditions on a bad
    /// shape or a `cells` array that does not match `rings`/`cellsPerRing`.
    public init(gear: UInt64, rings: Int, cellsPerRing: Int, now: UInt64, cells: [[Cell]]) throws {
        if let violation = Self.shapeViolation(gear: gear, rings: rings, cellsPerRing: cellsPerRing) {
            throw RingsError.badShape(violation)
        }
        guard cells.count == rings, cells.allSatisfy({ $0.count == cellsPerRing }) else {
            throw RingsError.cellsMismatch(expectedRings: rings, expectedCells: cellsPerRing)
        }
        self.gear = gear
        self.rings = rings
        self.cellsPerRing = cellsPerRing
        self.now = now
        self.cells = cells
    }

    /// Read-only snapshot of the full cell grid — the restore/persist path.
    public var cellsSnapshot: [[Cell]] { cells }

    private func spanLength(_ j: Int) -> UInt64 {
        var s: UInt64 = 1
        for _ in 0..<j { s &*= gear }
        return s
    }

    /// Record one sample at the current tick, then advance the clock.
    public mutating func write(_ value: Float) {
        for j in 0..<rings {
            let span = now / spanLength(j)
            let idx = Int(span % UInt64(cellsPerRing))
            var c = cells[j][idx]
            if !c.occupied || c.span != span {
                c = Cell(value: value, tick: now, span: span, occupied: true)
            } else if abs(value) > abs(c.value) {
                c.value = value
                c.tick = now
            }
            cells[j][idx] = c
        }
        now &+= 1
    }

    public struct Recall: Equatable, Codable {
        public let value: Float      // signed extremum of the covering span
        public let tick: UInt64      // exact tick of that extremum
        public let ring: Int         // resolution used (0 = finest)
        public let spanLength: UInt64
        public init(value: Float, tick: UInt64, ring: Int, spanLength: UInt64) {
            self.value = value
            self.tick = tick
            self.ring = ring
            self.spanLength = spanLength
        }
    }

    /// Recall the recorded extremum covering `lag` ticks ago, at the finest
    /// ring where that tick is still resident. Nil if beyond all horizons.
    public func recall(lag: UInt64) -> Recall? {
        guard lag >= 1, lag <= now else { return nil }
        let target = now - lag
        for j in 0..<rings {
            let sl = spanLength(j)
            let targetSpan = target / sl
            let currentSpan = (now == 0 ? 0 : (now - 1) / sl)
            // resident iff the cell for targetSpan has not been re-used
            guard currentSpan - targetSpan < UInt64(cellsPerRing) else { continue }
            let idx = Int(targetSpan % UInt64(cellsPerRing))
            let c = cells[j][idx]
            guard c.occupied, c.span == targetSpan else { continue }
            return Recall(value: c.value, tick: c.tick, ring: j, spanLength: sl)
        }
        return nil
    }

    /// Total numbers held (the sealed shape: 6 × 32 = 192 cells).
    public var capacity: Int { rings * cellsPerRing }
}
