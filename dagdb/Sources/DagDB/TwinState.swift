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
        /// Hooks bound to this clock (`AttentionHook.Params.clockId ==`
        /// this clock's id) — `.clockAdvance` steps each one once per tick,
        /// AFTER the gears; `.close` on this clock cascades to them too.
        public var hookIds: [String]
        public init(clock: MasterClock, gearIds: [String], hookIds: [String] = []) {
            self.clock = clock
            self.gearIds = gearIds
            self.hookIds = hookIds
        }

        private enum CodingKeys: String, CodingKey { case clock, gearIds, hookIds }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clock = try c.decode(MasterClock.self, forKey: .clock)
            gearIds = try c.decode([String].self, forKey: .gearIds)
            hookIds = try c.decodeIfPresent([String].self, forKey: .hookIds) ?? []
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

    /// Spec 8's waveform mouth, named and registered like every other twin
    /// primitive — the bank itself rebuilds from `spec` on decode (see
    /// `WaveBank`'s own Codable), so persisting `BankEntry` costs only the
    /// spec's few scalars, never the atom matrix.
    public struct BankEntry: Equatable, Codable {
        public let name: String
        public let bank: WaveBank
        public init(name: String, bank: WaveBank) {
            self.name = name
            self.bank = bank
        }
    }

    /// Derived-view sets over the sealed cortex v4 world persist BY
    /// REFERENCE (spec line 4, second view family, mirrors `AlarmRef`):
    /// path + sha256, never the fixture's bytes. This is the Codable half
    /// that lands in a `Snapshot`.
    public struct ViewRef: Equatable, Codable {
        public let path: String
        public let sha256: String
        public init(path: String, sha256: String) {
            self.path = path
            self.sha256 = sha256
        }
    }

    /// The live half: the reference plus the `DerivedViews` it resolved
    /// to. Not Codable — `DerivedViews`/`CortexFixture` are not persisted,
    /// only re-loaded from `ref` on restore.
    public struct ViewSet {
        public let ref: ViewRef
        public let views: DerivedViews
        public init(ref: ViewRef, views: DerivedViews) {
            self.ref = ref
            self.views = views
        }
    }

    public let streams = TwinRegistry<NamedStream>(prefix: "s")
    public let records = TwinRegistry<StreamRecord>(prefix: "t")
    public let rings = TwinRegistry<GearedRings>(prefix: "n")
    public let clocks = TwinRegistry<ClockEntry>(prefix: "c")
    public let gears = TwinRegistry<GearEntry>(prefix: "g")
    public let layouts = TwinRegistry<BudgetLayout>(prefix: "b")
    public let alarms = TwinRegistry<AlarmSet>(prefix: "a")
    public let banks = TwinRegistry<BankEntry>(prefix: "w")
    public let views = TwinRegistry<ViewSet>(prefix: "v")

    /// Per-path kernel pairs persist BY REFERENCE (docs/contracts/
    /// KERNELS_GATES_FROZEN.md, gate K3), mirroring `ViewRef`/`ViewSet`:
    /// path + sha256, never the taps' bytes — plus τA/τB/σ_source/
    /// declaredWarmup, DECLARED at load time (K4: never read from the
    /// kernels file itself), so restore re-derives the same warmup.
    public struct KernelRef: Equatable, Codable {
        public let path: String
        public let sha256: String
        public let tauA: Double?
        public let tauB: Double?
        public let sigmaSource: Double?
        public let declaredWarmup: Int?
        public init(path: String, sha256: String, tauA: Double? = nil, tauB: Double? = nil,
                    sigmaSource: Double? = nil, declaredWarmup: Int? = nil) {
            self.path = path
            self.sha256 = sha256
            self.tauA = tauA
            self.tauB = tauB
            self.sigmaSource = sigmaSource
            self.declaredWarmup = declaredWarmup
        }
    }

    /// The live half: the reference plus the `KernelPair` it resolved to.
    /// Not Codable — `KernelPair` itself is not persisted, only re-loaded
    /// from `ref` on restore.
    public struct KernelSet {
        public let ref: KernelRef
        public let pair: KernelPair
        public init(ref: KernelRef, pair: KernelPair) {
            self.ref = ref
            self.pair = pair
        }
    }

    public let kernels = TwinRegistry<KernelSet>(prefix: "k")

    /// One open attention hook (`AttentionHook.swift`, twin spec line 6):
    /// its fixed params plus the live, incrementally-stepped hook. Not
    /// Codable — only `params` and the frame counter `hook.t` persist (see
    /// `HookRef`); the ledger is DERIVED, never stored, and is rebuilt by
    /// re-stepping on restore.
    public struct HookEntry: Equatable {
        public let params: AttentionHook.Params
        public var hook: AttentionHook
        public init(params: AttentionHook.Params, hook: AttentionHook) {
            self.params = params
            self.hook = hook
        }
    }

    public let hooks = TwinRegistry<HookEntry>(prefix: "h")

    public init() {}

    /// Replay ceiling on the two ops whose WAL count commands unbounded
    /// work (`.recordSlice` draws, `.clockAdvance` ticks) — the same
    /// 10 000 the daemon's own tick verbs accept (finding 63).
    public static let replayCap = 10_000

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
        case "w": n = banks.counter &+ 1
        case "v": n = views.counter &+ 1
        case "k": n = kernels.counter &+ 1
        case "h": n = hooks.counter &+ 1
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
        alarmLoader: (String, String) throws -> AlarmFixture = { try AlarmFixture.load(path: $0, expectedSHA256: $1) },
        viewLoader: (String, String) throws -> CortexFixture = { try CortexFixture.load(path: $0, expectedSHA256: $1) },
        kernelLoader: (KernelRef) throws -> KernelPair = { ref in
            try KernelPair.load(path: ref.path, expectedSHA256: ref.sha256, tauA: ref.tauA, tauB: ref.tauB,
                                 sigmaSource: ref.sigmaSource, declaredWarmup: ref.declaredWarmup).pair
        }
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
            // Finding 63: the count comes straight off the WAL and commands
            // the work, which `TwinWALCodec.maxPayloadBytes` does not bound.
            // The replay cap is the same 10 000 the daemon's tick verbs use.
            guard count <= UInt32(Self.replayCap) else {
                throw TwinError.badValue("count \(count) not in 0...\(Self.replayCap)")
            }
            do {
                try records.update(id) { r in
                    try r.recordSlice(count: Int(count))
                }
            } catch let e as StreamRecord.RecordError {
                throw TwinError.badValue("\(e)")
            } catch { throw mapError(error, in: records) }

        case .ringsOpen(let id, let gear, let ringCount, let cells):
            if let violation = GearedRings.shapeViolation(gear: gear, rings: Int(ringCount), cellsPerRing: Int(cells)) {
                throw TwinError.badValue(violation)
            }
            let entry = try GearedRings(gear: gear, rings: Int(ringCount), cellsPerRing: Int(cells))
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
            // Finding 63: same declared ceiling, same wording — one 20-byte
            // record must never command 2^64 ticks on replay.
            guard count <= UInt64(Self.replayCap) else {
                throw TwinError.badValue("n \(count) not in 0...\(Self.replayCap)")
            }
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
                // Hooks step AFTER the gears (H4: "applied after the gears").
                for hid in entry.hookIds {
                    do {
                        try hooks.update(hid) { h in
                            _ = h.hook.step()
                        }
                    } catch { throw mapError(error, in: hooks) }
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

        case .bankOpen(let id, let name, let spec):
            if let err = WaveBank.validationError(spec) {
                throw TwinError.badValue(err)
            }
            let bank: WaveBank
            do {
                bank = try WaveBank(spec: spec)
            } catch {
                throw TwinError.badValue("\(error)")
            }
            let entry = BankEntry(name: name, bank: bank)
            do { try banks.open(entry, id: id) } catch { throw mapError(error, in: banks) }

        case .viewLoad(let id, let path, let sha256):
            let fixture: CortexFixture
            do {
                fixture = try viewLoader(path, sha256)
            } catch {
                throw TwinError.io("\(error)")
            }
            let entry = ViewSet(ref: ViewRef(path: path, sha256: sha256), views: DerivedViews(fixture: fixture))
            do { try views.open(entry, id: id) } catch { throw mapError(error, in: views) }

        case .kernelLoad(let id, let path, let sha256, let tauA, let tauB, let sigmaSource, let declaredWarmup):
            let ref = KernelRef(path: path, sha256: sha256, tauA: tauA, tauB: tauB,
                                 sigmaSource: sigmaSource, declaredWarmup: declaredWarmup)
            let pair: KernelPair
            do {
                pair = try kernelLoader(ref)
            } catch {
                throw TwinError.io("\(error)")
            }
            let entry = KernelSet(ref: ref, pair: pair)
            do { try kernels.open(entry, id: id) } catch { throw mapError(error, in: kernels) }

        case .hookOpen(let id, let params):
            guard let alarmSet = alarms.get(params.alarmId) else { throw TwinError.notFound(params.alarmId) }
            let hookLayout: BudgetLayout
            if let layoutId = params.layoutId {
                guard let l = layouts.get(layoutId) else { throw TwinError.notFound(layoutId) }
                hookLayout = l
            } else {
                hookLayout = SealedCourt.makeLayout()
            }
            if let clockId = params.clockId {
                guard clocks.get(clockId) != nil else { throw TwinError.notFound(clockId) }
            }
            let hook: AttentionHook
            do {
                hook = try AttentionHook(params: params, records: alarmSet.fixture.records, layout: hookLayout)
            } catch { throw TwinError.badValue("\(error)") }
            let entry = HookEntry(params: params, hook: hook)
            do { try hooks.open(entry, id: id) } catch { throw mapError(error, in: hooks) }
            if let clockId = params.clockId {
                do {
                    try clocks.update(clockId) { c in c.hookIds.append(id) }
                } catch { throw mapError(error, in: clocks) }
            }

        case .hookStep(let id, let count):
            guard let entry = hooks.get(id) else { throw TwinError.notFound(id) }
            if let clockId = entry.params.clockId {
                throw TwinError.badValue("bound to clock \(clockId)")
            }
            do {
                try hooks.update(id) { e in
                    _ = e.hook.step(count)
                }
            } catch { throw mapError(error, in: hooks) }

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
                for hid in entry.hookIds { hooks.close(hid) }
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
                guard layouts.get(id) != nil else { throw TwinError.notFound(id) }
                if let dep = hooks.entries.first(where: { $0.value.params.layoutId == id }) {
                    throw TwinError.badValue("hook \(dep.key) depends on \(id)")
                }
                guard layouts.close(id) else { throw TwinError.notFound(id) }
            case "a":
                guard alarms.get(id) != nil else { throw TwinError.notFound(id) }
                if let dep = hooks.entries.first(where: { $0.value.params.alarmId == id }) {
                    throw TwinError.badValue("hook \(dep.key) depends on \(id)")
                }
                guard alarms.close(id) else { throw TwinError.notFound(id) }
            case "w":
                guard banks.close(id) else { throw TwinError.notFound(id) }
            case "v":
                guard views.close(id) else { throw TwinError.notFound(id) }
            case "k":
                guard kernels.close(id) else { throw TwinError.notFound(id) }
            case "h":
                guard hooks.close(id) else { throw TwinError.notFound(id) }
            default:
                throw TwinError.badId(id)
            }
        }
    }

    /// Total entries open across all nine registries.
    public var totalOpen: Int {
        streams.openCount + records.openCount + rings.openCount + clocks.openCount
            + gears.openCount + layouts.openCount + alarms.openCount + banks.openCount
            + views.openCount + kernels.openCount + hooks.openCount
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
        banks.closeAll(); banks.resetCounter()
        views.closeAll(); views.resetCounter()
        kernels.closeAll(); kernels.resetCounter()
        hooks.closeAll(); hooks.resetCounter()
    }

    /// Codable persistence unit — snapshot v7's TWIN section (T7) and the
    /// WAL replay target (T6) both read/write this shape. Alarms persist
    /// by reference (`AlarmRef`), never as bytes.
    /// A hook's persisted shape — parameters plus the frame counter. The
    /// ledger is DERIVED, never stored: `restore` rebuilds it by re-opening
    /// the hook against its already-restored alarm/layout/clock and
    /// re-stepping `t` times.
    public struct HookRef: Equatable, Codable {
        public let params: AttentionHook.Params
        public let t: Int
        public init(params: AttentionHook.Params, t: Int) {
            self.params = params
            self.t = t
        }
    }

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
        public var banks: [String: BankEntry]
        public var views: [String: ViewRef]
        public var kernels: [String: KernelRef]
        public var hooks: [String: HookRef]

        public init(formatVersion: Int = 1, counters: [String: UInt64],
                    streams: [String: NamedStream], records: [String: StreamRecord],
                    rings: [String: GearedRings], clocks: [String: ClockEntry],
                    gears: [String: GearEntry], layouts: [String: BudgetLayout],
                    alarms: [String: AlarmRef], banks: [String: BankEntry] = [:],
                    views: [String: ViewRef] = [:], kernels: [String: KernelRef] = [:],
                    hooks: [String: HookRef] = [:]) {
            self.formatVersion = formatVersion
            self.counters = counters
            self.streams = streams
            self.records = records
            self.rings = rings
            self.clocks = clocks
            self.gears = gears
            self.layouts = layouts
            self.alarms = alarms
            self.banks = banks
            self.views = views
            self.kernels = kernels
            self.hooks = hooks
        }

        private enum CodingKeys: String, CodingKey {
            case formatVersion, counters, streams, records, rings, clocks, gears, layouts, alarms, banks, views, kernels, hooks
        }

        /// The only `formatVersion` this decoder understands.
        public static let acceptedFormatVersion = 1

        /// Custom decode so a Snapshot JSON written before `banks`/`views`/
        /// `kernels`/`hooks` existed (no such key at all) still decodes
        /// cleanly, with an empty registry — every other field stays a
        /// plain required decode. `formatVersion` itself is compared, not
        /// merely read (finding 60).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try c.decode(Int.self, forKey: .formatVersion)
            // Finding 60: the field was decoded and never compared, so a
            // future version that reshapes banks/views/kernels/hooks would
            // restore those registries EMPTY and report success.
            guard formatVersion == Self.acceptedFormatVersion else {
                throw DecodingError.dataCorruptedError(
                    forKey: .formatVersion, in: c,
                    debugDescription: "twin snapshot formatVersion \(formatVersion) is not the accepted \(Self.acceptedFormatVersion)")
            }
            counters = try c.decode([String: UInt64].self, forKey: .counters)
            streams = try c.decode([String: NamedStream].self, forKey: .streams)
            records = try c.decode([String: StreamRecord].self, forKey: .records)
            rings = try c.decode([String: GearedRings].self, forKey: .rings)
            clocks = try c.decode([String: ClockEntry].self, forKey: .clocks)
            gears = try c.decode([String: GearEntry].self, forKey: .gears)
            layouts = try c.decode([String: BudgetLayout].self, forKey: .layouts)
            alarms = try c.decode([String: AlarmRef].self, forKey: .alarms)
            banks = try c.decodeIfPresent([String: BankEntry].self, forKey: .banks) ?? [:]
            views = try c.decodeIfPresent([String: ViewRef].self, forKey: .views) ?? [:]
            kernels = try c.decodeIfPresent([String: KernelRef].self, forKey: .kernels) ?? [:]
            hooks = try c.decodeIfPresent([String: HookRef].self, forKey: .hooks) ?? [:]
        }
    }

    private static let counterKeys: [Character] = ["s", "t", "n", "c", "g", "b", "a", "w", "v", "k", "h"]

    public func export() -> Snapshot {
        Snapshot(
            counters: [
                "s": streams.counter, "t": records.counter, "n": rings.counter,
                "c": clocks.counter, "g": gears.counter, "b": layouts.counter, "a": alarms.counter,
                "w": banks.counter, "v": views.counter, "k": kernels.counter, "h": hooks.counter,
            ],
            streams: streams.entries,
            records: records.entries,
            rings: rings.entries,
            clocks: clocks.entries,
            gears: gears.entries,
            layouts: layouts.entries,
            alarms: Dictionary(uniqueKeysWithValues: alarms.entries.map { ($0.key, $0.value.ref) }),
            banks: banks.entries,
            views: Dictionary(uniqueKeysWithValues: views.entries.map { ($0.key, $0.value.ref) }),
            kernels: Dictionary(uniqueKeysWithValues: kernels.entries.map { ($0.key, $0.value.ref) }),
            hooks: Dictionary(uniqueKeysWithValues: hooks.entries.map { ($0.key, HookRef(params: $0.value.params, t: $0.value.hook.t)) })
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
        viewLoader: (String, String) throws -> CortexFixture = { try CortexFixture.load(path: $0, expectedSHA256: $1) },
        kernelLoader: (KernelRef) throws -> KernelPair = { ref in
            try KernelPair.load(path: ref.path, expectedSHA256: ref.sha256, tauA: ref.tauA, tauB: ref.tauB,
                                 sigmaSource: ref.sigmaSource, declaredWarmup: ref.declaredWarmup).pair
        },
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
        for (id, w) in snap.banks {
            do { try banks.open(w, id: id) } catch { throw mapError(error, in: banks) }
        }
        for (id, ref) in snap.alarms {
            do {
                let fixture = try alarmLoader(ref.path, ref.sha256)
                try alarms.open(AlarmSet(ref: ref, fixture: fixture), id: id)
            } catch {
                warn("twin: dropping alarm set \(id) (\(ref.path)): \(error)")
            }
        }
        for (id, ref) in snap.views {
            do {
                let fixture = try viewLoader(ref.path, ref.sha256)
                try views.open(ViewSet(ref: ref, views: DerivedViews(fixture: fixture)), id: id)
            } catch {
                warn("twin: dropping view set \(id) (\(ref.path)): \(error)")
            }
        }
        for (id, ref) in snap.kernels {
            do {
                let pair = try kernelLoader(ref)
                try kernels.open(KernelSet(ref: ref, pair: pair), id: id)
            } catch {
                warn("twin: dropping kernel set \(id) (\(ref.path)): \(error)")
            }
        }

        // Hooks last: rebuild against already-restored alarms, layouts,
        // and clocks (in that order — alarms/layouts above, clocks
        // earlier still), re-stepping `t` times to rebuild the ledger
        // (never stored). Trusted like streams/records/etc (no external
        // file of its own) — a bad reference here is real corruption, so
        // it throws rather than warn-and-drop.
        for (id, ref) in snap.hooks.sorted(by: { $0.key < $1.key }) {
            guard let alarmSet = alarms.get(ref.params.alarmId) else {
                // Finding 61: the alarm this hook is bound to was the one
                // documented non-fatal case — dropped with a warning. A
                // hook standing on a dropped alarm is dropped the same
                // way, so the declared drop-one policy is what happens
                // instead of a whole-restore refusal. A hook naming an
                // alarm that was never IN the snapshot is real corruption
                // and still throws.
                if snap.alarms[ref.params.alarmId] != nil {
                    warn("twin: dropping hook \(id) — its alarm set \(ref.params.alarmId) was dropped")
                    continue
                }
                throw TwinError.notFound(ref.params.alarmId)
            }
            let hookLayout: BudgetLayout
            if let layoutId = ref.params.layoutId {
                guard let l = layouts.get(layoutId) else { throw TwinError.notFound(layoutId) }
                hookLayout = l
            } else {
                hookLayout = SealedCourt.makeLayout()
            }
            if let clockId = ref.params.clockId {
                guard clocks.get(clockId) != nil else { throw TwinError.notFound(clockId) }
            }
            var hook: AttentionHook
            do {
                hook = try AttentionHook(params: ref.params, records: alarmSet.fixture.records, layout: hookLayout)
            } catch { throw TwinError.badValue("\(error)") }
            hook.step(ref.t)
            // Finding 62: `step(_:)` is bounded by the hook's own frame
            // count, so a snapshot whose `t` exceeds it used to restore
            // silently at a DIFFERENT frame than it recorded.
            guard hook.t == ref.t else {
                throw TwinError.badValue(
                    "hook \(id) recorded frame \(ref.t) but its \(hook.frames)-frame ledger stops at \(hook.t)")
            }
            let entry = HookEntry(params: ref.params, hook: hook)
            do { try hooks.open(entry, id: id) } catch { throw mapError(error, in: hooks) }
            if let clockId = ref.params.clockId {
                do {
                    try clocks.update(clockId) { c in c.hookIds.append(id) }
                } catch { throw mapError(error, in: clocks) }
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
            case "w": if n > banks.counter { banks.resetCounter(to: n) }
            case "v": if n > views.counter { views.resetCounter(to: n) }
            case "k": if n > kernels.counter { kernels.resetCounter(to: n) }
            case "h": if n > hooks.counter { hooks.resetCounter(to: n) }
            default: break
            }
        }
    }
}
