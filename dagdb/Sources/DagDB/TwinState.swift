import Foundation

/// Daemon-global home for the seven twin-spec primitives (interface-phase convention 13: these
/// registries are shared across every connection — there is no per-session
/// twin state). Every mutation goes through `apply(_:)`, so the WAL (T6)
/// and snapshot (T7) layers can log/replay one `TwinOp` stream instead of
/// re-deriving state from the daemon's own call sites.
public final class TwinState {
    /// A clock plus the ids of the gears it drives — `.clockAdvance`
    /// fires every attached gear each tick; `.close` on a clock cascades
    /// to close its gears too.
    public struct ClockEntry: Equatable, Codable {
        public var clock: MasterClock
        public var gearIds: [String]
        public init(clock: MasterClock, gearIds: [String]) {
            self.clock = clock
            self.gearIds = gearIds
        }
    }

    public struct GearEntry: Equatable, Codable {
        public let clockId: String
        public var gear: PhaseGear
        public init(clockId: String, gear: PhaseGear) {
            self.clockId = clockId
            self.gear = gear
        }
    }

    /// Alarm sets persist BY REFERENCE (interface-phase convention 15): path + sha256, never
    /// the fixture's bytes. This is the Codable half that lands in a
    /// `Snapshot`.
    public struct AlarmRef: Equatable, Codable {
        public let path: String
        public let sha256: String
        public init(path: String, sha256: String) {
            self.path = path
            self.sha256 = sha256
        }
    }

    /// The live half: the reference plus the fixture it resolved to.
    /// Not Codable — `AlarmFixture` itself is not persisted, only re-loaded
    /// from `ref` on restore.
    public struct AlarmSet {
        public let ref: AlarmRef
        public let fixture: AlarmFixture
        public init(ref: AlarmRef, fixture: AlarmFixture) {
            self.ref = ref
            self.fixture = fixture
        }
    }

    public let streams = TwinRegistry<NamedStream>(prefix: "s")
    public let records = TwinRegistry<StreamRecord>(prefix: "t")
    public let rings = TwinRegistry<GearedRings>(prefix: "n")
    public let clocks = TwinRegistry<ClockEntry>(prefix: "c")
    public let gears = TwinRegistry<GearEntry>(prefix: "g")
    public let layouts = TwinRegistry<BudgetLayout>(prefix: "b")
    public let alarms = TwinRegistry<AlarmSet>(prefix: "a")

    public init() {}

    public enum TwinError: Error, Equatable, CustomStringConvertible {
        case notFound(String)
        case badId(String)
        case badValue(String)
        case schema(String)
        case io(String)

        public var description: String {
            switch self {
            case .notFound(let s): return "not found: \(s)"
            case .badId(let s): return "bad id: \(s)"
            case .badValue(let s): return "bad value: \(s)"
            case .schema(let s): return "schema: \(s)"
            case .io(let s): return "io: \(s)"
            }
        }
    }

    /// Peek the id a live `open` against the named registry would mint
    /// next, WITHOUT consuming it — callers build the `TwinOp` with this
    /// id and then `apply` it, which is what actually raises the counter.
    public func nextId(prefix: Character) -> String {
        let n: UInt64
        switch prefix {
        case "s": n = streams.counter &+ 1
        case "t": n = records.counter &+ 1
        case "n": n = rings.counter &+ 1
        case "c": n = clocks.counter &+ 1
        case "g": n = gears.counter &+ 1
        case "b": n = layouts.counter &+ 1
        case "a": n = alarms.counter &+ 1
        default: n = 0
        }
        return TwinIdFormat.format(prefix: prefix, n)
    }

    /// Map a registry's `RegistryError` (nested per `Entry` instantiation)
    /// onto the single `TwinError` currency this class speaks.
    private func mapError<Entry>(_ error: Error, in registry: TwinRegistry<Entry>) -> TwinError {
        guard let e = error as? TwinRegistry<Entry>.RegistryError else {
            return .io("\(error)")
        }
        switch e {
        case .notFound(let s): return .notFound(s)
        case .duplicateId(let s): return .badId("duplicate id: \(s)")
        case .badId(let s): return .badId(s)
        }
    }

    /// Apply one twin op. `alarmLoader` is injectable so tests (and WAL
    /// replay) can point `.alarmLoad` at a synthetic fixture instead of
    /// the real `AlarmFixture.load`.
    public func apply(
        _ op: TwinOp,
        alarmLoader: (String, String) throws -> AlarmFixture = { try AlarmFixture.load(path: $0, expectedSHA256: $1) }
    ) throws {
        switch op {
        case .streamOpen(let id, let name, let stateHi, let stateLo, let incHi, let incLo):
            let entry = NamedStream(name: name, stateHi: stateHi, stateLo: stateLo, incHi: incHi, incLo: incLo)
            do { try streams.open(entry, id: id) } catch { throw mapError(error, in: streams) }

        case .streamState(let id, let stateHi, let stateLo, let draws):
            do {
                try streams.update(id) { s in
                    s = NamedStream(name: s.name, stateHi: stateHi, stateLo: stateLo,
                                     incHi: s.incWords.hi, incLo: s.incWords.lo, draws: draws)
                }
            } catch { throw mapError(error, in: streams) }

        case .recordOpen(let id, let name, let header, let stateHi, let stateLo, let incHi, let incLo):
            let gen = NamedStream(name: name, stateHi: stateHi, stateLo: stateLo, incHi: incHi, incLo: incLo)
            let entry: StreamRecord
            do {
                entry = try StreamRecord(header: header, generator: gen)
            } catch let e as StreamRecord.RecordError {
                throw TwinError.schema("\(e)")
            }
            do { try records.open(entry, id: id) } catch { throw mapError(error, in: records) }

        case .recordSlice(let id, let count):
            do {
                try records.update(id) { r in
                    r.recordSlice(count: Int(count))
                }
            } catch { throw mapError(error, in: records) }

        case .ringsOpen(let id, let gear, let ringCount, let cells):
            if let violation = GearedRings.shapeViolation(gear: gear, rings: Int(ringCount), cellsPerRing: Int(cells)) {
                throw TwinError.badValue(violation)
            }
            let entry = GearedRings(gear: gear, rings: Int(ringCount), cellsPerRing: Int(cells))
            do { try rings.open(entry, id: id) } catch { throw mapError(error, in: rings) }

        case .ringsWrite(let id, let values):
            do {
                try rings.update(id) { r in
                    for v in values { r.write(v) }
                }
            } catch { throw mapError(error, in: rings) }

        case .clockOpen(let id):
            let entry = ClockEntry(clock: MasterClock(), gearIds: [])
            do { try clocks.open(entry, id: id) } catch { throw mapError(error, in: clocks) }

        case .clockAdvance(let id, let count, let value):
            guard clocks.get(id) != nil else { throw TwinError.notFound(id) }
            for _ in 0..<count {
                var tick: UInt64 = 0
                do {
                    try clocks.update(id) { entry in
                        entry.clock.advance()
                        tick = entry.clock.tick
                    }
                } catch { throw mapError(error, in: clocks) }
                guard let entry = clocks.get(id) else { throw TwinError.notFound(id) }
                for gid in entry.gearIds {
                    do {
                        try gears.update(gid) { g in
                            g.gear.advance(masterTick: tick, value: value)
                        }
                    } catch { throw mapError(error, in: gears) }
                }
            }

        case .gearOpen(let id, let clockId, let name, let num, let den):
            guard var clockEntry = clocks.get(clockId) else { throw TwinError.notFound(clockId) }
            guard let ratio = GearRatio.reduced(num, over: den) else {
                throw TwinError.badValue("gear ratio \(num)/\(den) must have both terms > 0")
            }
            let gearEntry = GearEntry(clockId: clockId, gear: PhaseGear(name: name, ratio: ratio))
            do { try gears.open(gearEntry, id: id) } catch { throw mapError(error, in: gears) }
            clockEntry.gearIds.append(id)
            do { try clocks.replace(clockId, with: clockEntry) } catch { throw mapError(error, in: clocks) }

        case .layoutOpen(let id, let cost, let minTier):
            if let violation = BudgetLayout.validationError(cost: cost, minTier: minTier) {
                throw TwinError.badValue(violation)
            }
            let entry = BudgetLayout(cost: cost, minTier: minTier)
            do { try layouts.open(entry, id: id) } catch { throw mapError(error, in: layouts) }

        case .alarmLoad(let id, let path, let sha256):
            let fixture: AlarmFixture
            do {
                fixture = try alarmLoader(path, sha256)
            } catch {
                throw TwinError.io("\(error)")
            }
            let entry = AlarmSet(ref: AlarmRef(path: path, sha256: sha256), fixture: fixture)
            do { try alarms.open(entry, id: id) } catch { throw mapError(error, in: alarms) }

        case .close(let id):
            guard let letter = id.first else { throw TwinError.badId(id) }
            switch letter {
            case "s":
                guard streams.close(id) else { throw TwinError.notFound(id) }
            case "t":
                guard records.close(id) else { throw TwinError.notFound(id) }
            case "n":
                guard rings.close(id) else { throw TwinError.notFound(id) }
            case "c":
                guard let entry = clocks.get(id) else { throw TwinError.notFound(id) }
                for gid in entry.gearIds { gears.close(gid) }
                clocks.close(id)
            case "g":
                guard let gearEntry = gears.get(id) else { throw TwinError.notFound(id) }
                // Prune the gear from its clock so a later CLOCK ADVANCE never
                // trips on a stale id (found by the T8.3 hand, 2026-09-06).
                try? clocks.update(gearEntry.clockId) { clock in
                    clock.gearIds.removeAll { $0 == id }
                }
                gears.close(id)
            case "b":
                guard layouts.close(id) else { throw TwinError.notFound(id) }
            case "a":
                guard alarms.close(id) else { throw TwinError.notFound(id) }
            default:
                throw TwinError.badId(id)
            }
        }
    }

    /// Total entries open across all seven registries.
    public var totalOpen: Int {
        streams.openCount + records.openCount + rings.openCount + clocks.openCount
            + gears.openCount + layouts.openCount + alarms.openCount
    }

    /// Close everything and return every registry's counter to 0 — the
    /// v≤6 snapshot-load behavior (interface phase, 2026-09): an old-format snapshot carries
    /// no twin section, so the twin state starts fresh.
    public func reset() {
        streams.closeAll(); streams.resetCounter()
        records.closeAll(); records.resetCounter()
        rings.closeAll(); rings.resetCounter()
        clocks.closeAll(); clocks.resetCounter()
        gears.closeAll(); gears.resetCounter()
        layouts.closeAll(); layouts.resetCounter()
        alarms.closeAll(); alarms.resetCounter()
    }

    /// Codable persistence unit — snapshot v7's TWIN section (T7) and the
    /// WAL replay target (T6) both read/write this shape. Alarms persist
    /// by reference (`AlarmRef`), never as bytes.
    public struct Snapshot: Equatable, Codable {
        public var formatVersion = 1
        public var counters: [String: UInt64]
        public var streams: [String: NamedStream]
        public var records: [String: StreamRecord]
        public var rings: [String: GearedRings]
        public var clocks: [String: ClockEntry]
        public var gears: [String: GearEntry]
        public var layouts: [String: BudgetLayout]
        public var alarms: [String: AlarmRef]

        public init(formatVersion: Int = 1, counters: [String: UInt64],
                    streams: [String: NamedStream], records: [String: StreamRecord],
                    rings: [String: GearedRings], clocks: [String: ClockEntry],
                    gears: [String: GearEntry], layouts: [String: BudgetLayout],
                    alarms: [String: AlarmRef]) {
            self.formatVersion = formatVersion
            self.counters = counters
            self.streams = streams
            self.records = records
            self.rings = rings
            self.clocks = clocks
            self.gears = gears
            self.layouts = layouts
            self.alarms = alarms
        }
    }

    private static let counterKeys: [Character] = ["s", "t", "n", "c", "g", "b", "a"]

    public func export() -> Snapshot {
        Snapshot(
            counters: [
                "s": streams.counter, "t": records.counter, "n": rings.counter,
                "c": clocks.counter, "g": gears.counter, "b": layouts.counter, "a": alarms.counter,
            ],
            streams: streams.entries,
            records: records.entries,
            rings: rings.entries,
            clocks: clocks.entries,
            gears: gears.entries,
            layouts: layouts.entries,
            alarms: Dictionary(uniqueKeysWithValues: alarms.entries.map { ($0.key, $0.value.ref) })
        )
    }

    /// Rebuild every registry from an exported `Snapshot`. Every entry
    /// kind except alarms is trusted (it came out of a prior `export()`)
    /// and re-opened directly under its original id; a bad id/duplicate
    /// still throws rather than silently dropping (interface-phase convention 15 carves out
    /// only the alarm-file-missing case as non-fatal).
    ///
    /// An alarm whose file is missing or whose hash no longer matches
    /// drops that one entry (never the whole restore) and calls `warn`
    /// exactly once with a human-readable reason.
    public func restore(
        _ snap: Snapshot,
        alarmLoader: (String, String) throws -> AlarmFixture = { try AlarmFixture.load(path: $0, expectedSHA256: $1) },
        warn: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) throws {
        reset()

        for (id, s) in snap.streams {
            do { try streams.open(s, id: id) } catch { throw mapError(error, in: streams) }
        }
        for (id, r) in snap.records {
            do { try records.open(r, id: id) } catch { throw mapError(error, in: records) }
        }
        for (id, n) in snap.rings {
            do { try rings.open(n, id: id) } catch { throw mapError(error, in: rings) }
        }
        for (id, c) in snap.clocks {
            do { try clocks.open(c, id: id) } catch { throw mapError(error, in: clocks) }
        }
        for (id, g) in snap.gears {
            do { try gears.open(g, id: id) } catch { throw mapError(error, in: gears) }
        }
        for (id, l) in snap.layouts {
            do { try layouts.open(l, id: id) } catch { throw mapError(error, in: layouts) }
        }
        for (id, ref) in snap.alarms {
            do {
                let fixture = try alarmLoader(ref.path, ref.sha256)
                try alarms.open(AlarmSet(ref: ref, fixture: fixture), id: id)
            } catch {
                warn("twin: dropping alarm set \(id) (\(ref.path)): \(error)")
            }
        }

        // Restore counters explicitly: a registry entry that was closed
        // before export leaves no surviving id to derive the counter
        // from, so the exported counter value is authoritative even when
        // it exceeds every id actually reopened above.
        for letter in Self.counterKeys {
            guard let n = snap.counters[String(letter)] else { continue }
            switch letter {
            case "s": if n > streams.counter { streams.resetCounter(to: n) }
            case "t": if n > records.counter { records.resetCounter(to: n) }
            case "n": if n > rings.counter { rings.resetCounter(to: n) }
            case "c": if n > clocks.counter { clocks.resetCounter(to: n) }
            case "g": if n > gears.counter { gears.resetCounter(to: n) }
            case "b": if n > layouts.counter { layouts.resetCounter(to: n) }
            case "a": if n > alarms.counter { alarms.resetCounter(to: n) }
            default: break
            }
        }
    }
}
