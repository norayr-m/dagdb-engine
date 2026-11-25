import Foundation

/// Daemon-global home for the seven twin-spec primitives (interface-phase convention 13: these
/// registries are shared across every connection — there is no per-session
/// twin state). Every mutation goes through `apply(_:)`, so the WAL
/// and snapshot layers can log/replay one `TwinOp` stream instead of
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

    /// The waveform mouth, named and registered like every other twin
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
    /// REFERENCE (the second family of derived views; mirrors `AlarmRef`):
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

    /// Per-path kernel pairs persist BY REFERENCE, mirroring `ViewRef`/`ViewSet`:
    /// path + sha256, never the taps' bytes — plus τA/τB/σ_source/
    /// declaredWarmup, DECLARED at load time (never read from the
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

    /// One open attention hook (`AttentionHook.swift`):
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
    /// 10 000 the daemon's own tick verbs accept.
    public static let replayCap = 10_000

    // MARK: - The live caps, one constant each (DaemonKit's budget names read these)

    /// Open objects of each twin kind (the largest count seen in real use is 3).
    public static let kindCap = 1_024
    /// The cap on every client-given name stored in twin state (twin ids, stream, record, gear and
    /// bank names, alarm record keys, and the ids a hook or a gear names), L bytes of UTF-8. L is COMPUTED, not chosen:
    /// the longest name the test corpus, the clients, every test and every launcher use is 3,900 bytes (a test's
    /// record name), and L is the next power of two at or above 4 x that, 16,384. The live verbs
    /// refuse a longer name by name; LOAD, the startup load and replay load an older over-long name faithfully and name
    /// it (`overLongNames`), the era rule.
    public static let nameCap = 16_384

    /// Every stored name over `nameCap`, described (kind, id, length), in id order; empty when none.
    public func overLongNames(cap: Int = TwinState.nameCap) -> [String] {
        var out: [String] = []
        func check(_ kind: String, _ id: String, _ what: String, _ s: String) {
            let n = s.utf8.count
            if n > cap { out.append("\(kind) \(id.utf8.count > 64 ? String(id.prefix(32)) + "..." : id): \(what) of \(n) bytes") }
        }
        func ids<E>(_ kind: String, _ d: [String: E]) { for id in d.keys.sorted() { check(kind, id, "its id", id) } }
        ids("stream", streams.entries); ids("record", records.entries); ids("ring set", rings.entries)
        ids("clock", clocks.entries); ids("gear", gears.entries); ids("layout", layouts.entries)
        ids("alarm set", alarms.entries); ids("bank", banks.entries); ids("view set", views.entries)
        ids("kernel set", kernels.entries); ids("hook", hooks.entries)
        for (id, x) in streams.entries.sorted(by: { $0.key < $1.key }) { check("stream", id, "its name", x.name) }
        for (id, x) in records.entries.sorted(by: { $0.key < $1.key }) { check("record", id, "its name", x.streamName) }
        for (id, x) in gears.entries.sorted(by: { $0.key < $1.key }) { check("gear", id, "its name", x.gear.name); check("gear", id, "its clock id", x.clockId) }
        for (id, x) in clocks.entries.sorted(by: { $0.key < $1.key }) {
            for g in x.gearIds { check("clock", id, "a gear id", g) }
            for h in x.hookIds { check("clock", id, "a hook id", h) }
        }
        for (id, x) in banks.entries.sorted(by: { $0.key < $1.key }) { check("bank", id, "its name", x.name) }
        for (id, x) in alarms.entries.sorted(by: { $0.key < $1.key }) {
            for r in x.fixture.records { check("alarm set", id, "record key \(r.index)", r.key) }
        }
        for (id, x) in hooks.entries.sorted(by: { $0.key < $1.key }) {
            check("hook", id, "its alarm id", x.params.alarmId)
            if let l = x.params.layoutId { check("hook", id, "its layout id", l) }
            if let c = x.params.clockId { check("hook", id, "its clock id", c) }
        }
        return out
    }

    /// Why a live LOAD refuses this state's names (nil when none is over the cap).
    public func overLongNamesRefusal() -> String? {
        let xs = overLongNames()
        guard let first = xs.first else { return nil }
        return "it holds \(xs.count) name(s) above the \(TwinState.nameCap)-byte cap on names stored in twin state (\(first)"
            + (xs.count > 1 ? "; and \(xs.count - 1) more" : "") + "), names no live verb writes"
    }

    /// The era line the boot prints for over-long names (nil when none).
    public func overLongNamesLine(_ where_: String) -> String? {
        let xs = overLongNames()
        guard !xs.isEmpty else { return nil }
        let shown = xs.prefix(4).joined(separator: "; ") + (xs.count > 4 ? "; and \(xs.count - 4) more" : "")
        return "\(where_) holds \(xs.count) name(s) above the \(TwinState.nameCap)-byte cap (state an older build held; loaded"
            + " faithfully): \(shown); new names over the cap are refused"
    }
    /// Slices on one record, checked by RECORD SLICE after its shm check.
    public static let slicesPerRecordCap = 4_096

    // MARK: - SAVE's tokens, from the registries

    /// Per-object JSON tokens (, : [ { bytes; the scanner's T less its 1) of `export()`'s encoding, each at or above
    /// what the encoder writes for that object, separators of its dictionary entry included (EngineALLOC1cTests
    /// checks every one against the encoder's output). Measured variable parts: a ring cell 9, a slice
    /// draw 1 and a slice 14 (+ 41 per record), a layout value 1 (+ 27 per layout), a stream 14, a gear with its
    /// clock 23. A later check measured a clock with three gears at 80 (so 22 per gear), a bank at 22, and the
    /// four by-reference kinds at 43.2 together; each constant is rounded up past its reading.
    public enum ExportTokens {
        public static let section = 60          // the empty section (the 13 keys, the 11 counters)
        public static let stream = 14
        public static let record = 42           // + perSlice per slice + 1 per draw
        public static let perSlice = 15
        public static let ringSet = 40          // + perCell per cell (r*c)
        public static let perCell = 9
        public static let clock = 14            // + 1 per gear id and per hook id on it
        public static let gear = 24
        public static let layout = 28           // + 1 per cost value, per row and per class
        public static let alarmRef = 8
        public static let viewRef = 8
        public static let kernelRef = 16
        public static let bank = 24
        public static let hook = 20
    }

    /// An upper bound on the tokens of the twin section SAVE would encode, from the registries alone, before
    /// anything is encoded (SAVE admits 1.1 x (79.0 B per token of it + 2.95 B per escaped string byte)). Names
    /// and paths count no tokens of their
    /// own: a separator inside a string raises the scanner's count but builds no value.
    public func exportTokenBound() -> Int {
        typealias K = ExportTokens
        var t = K.section + 1
        t += K.stream * streams.openCount
        for (_, r) in records.entries {
            t += K.record + K.perSlice * r.slices.count + r.slices.reduce(0) { $0 + $1.payload.count }
        }
        for (_, n) in rings.entries { t += K.ringSet + K.perCell * n.rings * n.cellsPerRing }
        for (_, c) in clocks.entries { t += K.clock + c.gearIds.count + c.hookIds.count }
        t += K.gear * gears.openCount
        for (_, l) in layouts.entries {
            t += K.layout + l.cost.reduce(0) { $0 + $1.count + 1 } + l.minTier.count
        }
        t += K.alarmRef * alarms.openCount + K.viewRef * views.openCount + K.kernelRef * kernels.openCount
        t += K.bank * banks.openCount + K.hook * hooks.openCount
        return t
    }

    /// S, the escaped string bytes SAVE's twin section carries, quotes included:
    /// every key (coding keys and dictionary keys) and every string value `export()`'s encoding writes, counted by
    /// running that encoding into a writer that keeps nothing (`JSONStringBytes`), so a field the encoder writes is
    /// counted by enumeration, never by a hand-kept list (a record's name is written twice, as `streamName` and as
    /// its generator's `name`; a hand-kept list counted it once). JSONEncoder writes `"`, `\` and `/` as two
    /// bytes, the five named controls as two, any other control as six (\u00XX), every other UTF-8 byte as itself.
    /// The walk allocates no output; `export()` copies no registry (its dictionaries share storage).
    public func exportStringBytes() -> Int {
        // The twin types' encode(to:) never throws into a writer that keeps nothing; if one did, SAVE's own encode
        // would fail the same way, after an admission of the tokens alone.
        (try? JSONStringBytes.count(export())) ?? 0
    }

    /// One string as JSONEncoder writes it, quotes included.
    public static func escapedJSONLength(_ x: String) -> Int {
        var n = 2
        for b in x.utf8 {
            switch b {
            case 0x22, 0x5C, 0x2F, 0x08, 0x0C, 0x0A, 0x0D, 0x09: n += 2
            case 0x00...0x1F: n += 6
            default: n += 1
            }
        }
        return n
    }

    // MARK: - The default loaders and builder, each admitted at its live verb's charge

    /// ALARM LOAD's file read through `admit` at its live charge: the JSON loaders' one pair, 2.52 B per byte
    /// before the read, 98.4 B per token + 2.52 B per byte before the parse (it was 8.6*file + 300 KB).
    static func alarmFileLoader(_ admit: ((Int, String) -> String?)?, what: String) -> (String, String) throws -> AlarmFixture {
        { path, sha in
            try AlarmFixture.load(path: path, expectedSHA256: sha, admit: admit.map { a in { fb in
                a(Int(AdmissionCharge.jsonRead(fileBytes: fb).rounded(.up)),
                  "\(what): \(Reply.quoted(path)) read at ALARM LOAD's charge, 2.52 B per byte for \(fb) B")
            } }, admitParse: admit.map { a in { d in
                let t = AdmissionCharge.jsonTokens(d)
                return a(Int(AdmissionCharge.jsonParse(tokens: t, fileBytes: d.count).rounded(.up)),
                         "\(what): \(Reply.quoted(path)) parsed at ALARM LOAD's charge, 98.4 B per token + 2.52 B per byte for \(t) tokens and \(d.count) B")
            } })
        }
    }
    /// VIEW LOAD's file read through `admit` (4.0 B per file byte + 1 MiB).
    static func viewFileLoader(_ admit: ((Int, String) -> String?)?, what: String) -> (String, String) throws -> CortexFixture {
        { path, sha in
            try CortexFixture.load(path: path, expectedSHA256: sha, admit: admit.map { a in { fb in
                a(Int(AdmissionCharge.viewLoad(fileBytes: fb).rounded(.up)),
                  "\(what): \(Reply.quoted(path)) read and decoded at VIEW LOAD's charge, 4.0*file + 1 MiB for \(fb) B")
            } })
        }
    }
    /// KERNEL LOAD's file read through `admit` at its live charge (the JSON loaders' pair, as ALARM LOAD's).
    static func kernelFileLoader(_ admit: ((Int, String) -> String?)?, what: String) -> (KernelRef) throws -> KernelPair {
        { ref in
            try KernelPair.load(path: ref.path, expectedSHA256: ref.sha256, tauA: ref.tauA, tauB: ref.tauB,
                                sigmaSource: ref.sigmaSource, declaredWarmup: ref.declaredWarmup, admit: admit.map { a in { fb in
                a(Int(AdmissionCharge.jsonRead(fileBytes: fb).rounded(.up)),
                  "\(what): \(Reply.quoted(ref.path)) read at KERNEL LOAD's charge, 2.52 B per byte for \(fb) B")
            } }, admitParse: admit.map { a in { d in
                let t = AdmissionCharge.jsonTokens(d)
                return a(Int(AdmissionCharge.jsonParse(tokens: t, fileBytes: d.count).rounded(.up)),
                         "\(what): \(Reply.quoted(ref.path)) parsed at KERNEL LOAD's charge, 98.4 B per token + 2.52 B per byte for \(t) tokens and \(d.count) B")
            } }).pair
        }
    }
    /// A bank's atoms built through `admit` (4*T*K), the spec validated first (no admission for a refused spec).
    static func bankAtomsBuilder(_ admit: ((Int, String) -> String?)?, what: String) -> (WaveBank.Spec) throws -> WaveBank {
        { spec in
            if let a = admit, WaveBank.validationError(spec) == nil,
               let line = a(Int(AdmissionCharge.bankAtoms(T: spec.samples, K: spec.atomCount).rounded(.up)),
                            "\(what)'s atoms, 4*T*K for T=\(spec.samples) K=\(spec.atomCount)") {
                throw DaemonFile.Refusal.admission(line)
            }
            return try WaveBank(spec: spec)
        }
    }

    /// Each kind's registry size, in the words the live count-cap refusal uses.
    static func kindCounts(streams: Int, records: Int, rings: Int, clocks: Int, gears: Int, layouts: Int, alarms: Int,
                           banks: Int, views: Int, kernels: Int, hooks: Int) -> [(kind: String, count: Int)] {
        [("streams", streams), ("records", records), ("rings", rings), ("clocks", clocks), ("gears", gears),
         ("budget layouts", layouts), ("alarm sets", alarms), ("banks", banks), ("view sets", views),
         ("kernel sets", kernels), ("hooks", hooks)]
    }

    /// Why LOAD (and the startup load) refuses this twin section, or nil: what no live verb lets
    /// a daemon hold. More than `kindCap` objects of a kind, more than `slicesPerRecordCap` slices on a record, or
    /// a ring set RINGS OPEN would refuse (`GearedRings.stateViolation`: the shape, or a cells array that does not
    /// match its fields). Asked on the decoded section before anything is restored, so a refusal changes nothing.
    public static func snapshotRefusal(_ s: Snapshot) -> String? {
        snapshotCountRefusal(s) ?? snapshotShapeRefusal(s)
    }

    /// The shape half alone, which the startup load applies (a ring set no build
    /// writes is corruption); over-cap COUNTS there are the era's, loaded and named (`overCap`).
    public static func snapshotShapeRefusal(_ s: Snapshot) -> String? {
        for (id, n) in s.rings.sorted(by: { $0.key < $1.key }) {
            if let v = n.stateViolation { return "ring set \(id): \(v), a shape RINGS OPEN refuses" }
        }
        return nil
    }

    /// The count half: more objects of a kind, or slices on a record, than a live verb lets a daemon hold.
    public static func snapshotCountRefusal(_ s: Snapshot) -> String? {
        for k in kindCounts(streams: s.streams.count, records: s.records.count, rings: s.rings.count, clocks: s.clocks.count,
                            gears: s.gears.count, layouts: s.layouts.count, alarms: s.alarms.count, banks: s.banks.count,
                            views: s.views.count, kernels: s.kernels.count, hooks: s.hooks.count) where k.count > kindCap {
            return "it holds \(k.count) \(k.kind), above the \(k.kind) cap of \(kindCap) a live open allows"
        }
        for (id, r) in s.records.sorted(by: { $0.key < $1.key }) where r.slices.count > slicesPerRecordCap {
            return "record \(id) holds \(r.slices.count) slices, above the cap of \(slicesPerRecordCap) RECORD SLICE allows"
        }
        return nil
    }

    /// What the state holds over a live cap, keyed by kind ("rings") or record
    /// ("RECORD t00000001"), for the boot's lines: the startup load's (`the startup snapshot holds …`) and replay's.
    public func overCap() -> [String: Int] {
        var out: [String: Int] = [:]
        for k in Self.kindCounts(streams: streams.openCount, records: records.openCount, rings: rings.openCount,
                                 clocks: clocks.openCount, gears: gears.openCount, layouts: layouts.openCount,
                                 alarms: alarms.openCount, banks: banks.openCount, views: views.openCount,
                                 kernels: kernels.openCount, hooks: hooks.openCount) where k.count > Self.kindCap {
            out[k.kind] = k.count
        }
        for (id, r) in records.entries where r.slices.count > Self.slicesPerRecordCap { out["RECORD " + id] = r.slices.count }
        return out
    }

    /// One `overCap` entry as a boot line, `lead` saying where the excess came from.
    public static func overCapLine(_ key: String, _ n: Int, replayed: Bool) -> String {
        if key.hasPrefix("RECORD ") {
            let id = String(key.dropFirst(7))
            return (replayed ? "replayed RECORD \(id) holds" : "the startup snapshot's RECORD \(id) holds")
                + " \(n) slices, above the cap \(grouped(slicesPerRecordCap)); RECORD SLICE \(id) is refused"
        }
        return (replayed ? "replayed \(key) count \(n) exceeds" : "the startup snapshot holds \(key) count \(n), above")
            + " the cap \(grouped(kindCap))" + (replayed ? "" : " (state an older build held, carried by SAVE)")
            + "; new opens are refused until below"
    }

    /// `n` with a comma every three digits (the boot line's "1,024").
    static func grouped(_ n: Int) -> String {
        var d = Array(String(n)), out: [Character] = []
        while d.count > 3 { out = [","] + Array(d.suffix(3)) + out; d.removeLast(3) }
        return String(d + out)
    }

    /// The era rule: a log written by a build without these caps may hold more than a live verb
    /// allows today. Replay recovers what that daemon held, faithfully; the boot names each excess with these lines.
    public func replayedOverCapLines(beyond loaded: [String: Int] = [:]) -> [String] {
        overCap().sorted { $0.key < $1.key }.filter { $0.value > (loaded[$0.key] ?? 0) }
            .map { Self.overCapLine($0.key, $0.value, replayed: true) }
    }

    /// A restore refused because a file the snapshot's twin section names may not be read.
    public struct RestoreFileRefusal: Error, CustomStringConvertible, Reply.CarriesLine {
        public let what: String
        public let refusal: DaemonFile.Refusal
        public var description: String { "\(what) names a file the daemon may not read: \(Reply.errorWords(refusal)); nothing loaded" }
        /// An admission refusal of that file is the reply, under its own code.
        public var replyLine: String? { refusal.replyLine.map { "\($0); \(what) names that file; nothing loaded" } }
    }

    public enum TwinError: Error, Equatable, CustomStringConvertible {
        case notFound(String)
        case badId(String)
        case badValue(String)
        case schema(String)
        case io(String)

        public var description: String {
            switch self {
            case .notFound(let s): return "not found: \(Reply.quoted(s))"
            case .badId(let s): return "bad id: \(Reply.quoted(s))"
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
            return .io(Reply.errorWords(error))
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
        alarmLoader: ((String, String) throws -> AlarmFixture)? = nil,
        viewLoader: ((String, String) throws -> CortexFixture)? = nil,
        kernelLoader: ((KernelRef) throws -> KernelPair)? = nil,
        /// The daemon builds and checks the bank
        /// before it logs BANK OPEN, and hands the built bank in here.
        bankBuilder: ((WaveBank.Spec) throws -> WaveBank)? = nil,
        /// The caller's admission (bytes before the margin, what), asked by the DEFAULT
        /// loaders on the opened file's size at the live verb's charge and by the default bank builder for its
        /// atoms. nil: nothing admitted (a caller with no budget). A refusal is thrown as itself
        /// (`DaemonFile.Refusal.admission`), never folded into a twin error, so replay can refuse the start.
        admit: ((Int, String) -> String?)? = nil
    ) throws {
        let alarmLoader = alarmLoader ?? Self.alarmFileLoader(admit, what: "ALARM LOAD")
        let viewLoader = viewLoader ?? Self.viewFileLoader(admit, what: "VIEW LOAD")
        let kernelLoader = kernelLoader ?? Self.kernelFileLoader(admit, what: "KERNEL LOAD")
        let bankBuilder = bankBuilder ?? Self.bankAtomsBuilder(admit, what: "BANK OPEN")
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
                throw TwinError.schema(Reply.errorWords(e))
            }
            do { try records.open(entry, id: id) } catch { throw mapError(error, in: records) }

        case .recordSlice(let id, let count):
            // The count comes straight off the WAL and commands
            // the work, which `TwinWALCodec.maxPayloadBytes` does not bound.
            // The replay cap is the same 10 000 the daemon's tick verbs use.
            if let e = Self.recordSliceRefusal(count: Int(count)) { throw e }
            do {
                try records.update(id) { r in
                    try r.recordSlice(count: Int(count))
                }
            } catch let e as StreamRecord.RecordError {
                throw TwinError.badValue(Reply.errorWords(e))
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
            // Same declared ceiling, same wording — one 20-byte
            // record must never command 2^64 ticks on replay.
            guard count <= UInt64(Self.replayCap) else {
                throw TwinError.badValue("n \(count) not in 0...\(Self.replayCap)")
            }
            guard clocks.get(id) != nil else { throw TwinError.notFound(id) }
            // A gear or hook id on the clock that names no open entry is
            // refused before the first tick, by name (met inside tick 1, it
            // would be found after the clock and the gears ahead of it had
            // moved); a live clock never holds one (HOOK CLOSE sweeps its id),
            // and replay's rule for older logs is `applyReplayed`.
            if count > 0, let d = danglingIds(onClock: id).first { throw TwinError.notFound(d) }
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
                // Hooks step AFTER the gears.
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
            } catch let r as DaemonFile.Refusal where r.isAdmission {
                throw r                                                    // the admission's own refusal
            } catch {
                throw TwinError.io(Reply.errorWords(error))
            }
            let entry = AlarmSet(ref: AlarmRef(path: path, sha256: sha256), fixture: fixture)
            do { try alarms.open(entry, id: id) } catch { throw mapError(error, in: alarms) }

        case .bankOpen(let id, let name, let spec):
            if let err = WaveBank.validationError(spec) {
                throw TwinError.badValue(err)
            }
            let bank: WaveBank
            do {
                bank = try bankBuilder(spec)
            } catch let r as DaemonFile.Refusal where r.isAdmission {
                throw r                                                    // the admission's own refusal
            } catch {
                throw TwinError.badValue(Reply.errorWords(error))
            }
            let entry = BankEntry(name: name, bank: bank)
            do { try banks.open(entry, id: id) } catch { throw mapError(error, in: banks) }

        case .viewLoad(let id, let path, let sha256):
            let fixture: CortexFixture
            do {
                fixture = try viewLoader(path, sha256)
            } catch let r as DaemonFile.Refusal where r.isAdmission {
                throw r                                                    // the admission's own refusal
            } catch {
                throw TwinError.io(Reply.errorWords(error))
            }
            let entry = ViewSet(ref: ViewRef(path: path, sha256: sha256), views: DerivedViews(fixture: fixture))
            do { try views.open(entry, id: id) } catch { throw mapError(error, in: views) }

        case .kernelLoad(let id, let path, let sha256, let tauA, let tauB, let sigmaSource, let declaredWarmup):
            let ref = KernelRef(path: path, sha256: sha256, tauA: tauA, tauB: tauB,
                                 sigmaSource: sigmaSource, declaredWarmup: declaredWarmup)
            let pair: KernelPair
            do {
                pair = try kernelLoader(ref)
            } catch let r as DaemonFile.Refusal where r.isAdmission {
                throw r                                                    // the admission's own refusal
            } catch {
                throw TwinError.io(Reply.errorWords(error))
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
            } catch { throw TwinError.badValue(Reply.errorWords(error)) }
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
                // trips on a stale id (found 2026-09-06).
                try? clocks.update(gearEntry.clockId) { clock in
                    clock.gearIds.removeAll { $0 == id }
                }
                gears.close(id)
            case "b":
                guard layouts.get(id) != nil else { throw TwinError.notFound(id) }
                if let e = closeRefusal(id) { throw e }
                guard layouts.close(id) else { throw TwinError.notFound(id) }
            case "a":
                guard alarms.get(id) != nil else { throw TwinError.notFound(id) }
                if let e = closeRefusal(id) { throw e }
                guard alarms.close(id) else { throw TwinError.notFound(id) }
            case "w":
                guard banks.close(id) else { throw TwinError.notFound(id) }
            case "v":
                guard views.close(id) else { throw TwinError.notFound(id) }
            case "k":
                guard kernels.close(id) else { throw TwinError.notFound(id) }
            case "h":
                // TWIN_CLOSE of a hook keeps its older meaning, the hook
                // alone: a log written by an older build replays as that
                // daemon ran it, its bound id left on the clock (the era
                // marker). The daemon's HOOK CLOSE of a
                // bound hook logs TWIN_HOOK_SWEEP beside this record, so the
                // id leaves the clock in the log as it does live.
                guard hooks.close(id) else { throw TwinError.notFound(id) }
            default:
                throw TwinError.badId(id)
            }

        case .hookSweep(let bindings):
            if let why = hookSweepRefusal(bindings) { throw TwinError.badValue(why) }
            for b in bindings {
                do {
                    try clocks.update(b.clockId) { c in c.hookIds.removeAll { $0 == b.hookId } }
                } catch { throw mapError(error, in: clocks) }
            }
        }
    }

    // MARK: - Dangling ids, the sweep, the replay rule for older logs

    /// `.recordSlice`'s count refusal (the replay ceiling;
    /// `StreamRecord.maxSliceCount` is the same 10 000), as a pure check the
    /// daemon asks before it logs RECORD SLICE. Inside `apply` alone, after
    /// the WAL append, a count above 10 000 that the result file holds would
    /// leave a TWIN_RECORD_SLICE record.
    public static func recordSliceRefusal(count: Int) -> TwinError? {
        guard count >= 0, count <= replayCap else {
            return .badValue("count \(count) not in 0...\(replayCap)")
        }
        return nil
    }

    /// The id the next open of `prefix` would mint, when it is still open.
    /// An id formats the low 32 bits of a counter that never reuses a value,
    /// so past 2^32 opens of one kind it can land on a live entry, and the
    /// registry's `duplicateId` would come from `apply`, after the record was
    /// logged. nil when the id is free.
    public func mintCollision(prefix: Character) -> String? {
        let id = nextId(prefix: prefix)
        let taken: Bool
        switch prefix {
        case "s": taken = streams.get(id) != nil
        case "t": taken = records.get(id) != nil
        case "n": taken = rings.get(id) != nil
        case "c": taken = clocks.get(id) != nil
        case "g": taken = gears.get(id) != nil
        case "b": taken = layouts.get(id) != nil
        case "a": taken = alarms.get(id) != nil
        case "w": taken = banks.get(id) != nil
        case "v": taken = views.get(id) != nil
        case "k": taken = kernels.get(id) != nil
        case "h": taken = hooks.get(id) != nil
        default: taken = false
        }
        return taken ? id : nil
    }

    /// The dependency refusal `.close` of a layout or an alarm set throws, as a
    /// pure check the daemon asks BEFORE it logs the close (behind the WAL
    /// append, a refused close would leave a TWIN_CLOSE record). nil when the
    /// close may go ahead (or the id is not a
    /// layout or alarm set: `.close` names those cases itself).
    public func closeRefusal(_ id: String) -> TwinError? {
        switch id.first {
        case "b":
            if let dep = hooks.entries.first(where: { $0.value.params.layoutId == id }) {
                return .badValue("hook \(dep.key) depends on \(id)")
            }
        case "a":
            if let dep = hooks.entries.first(where: { $0.value.params.alarmId == id }) {
                return .badValue("hook \(dep.key) depends on \(id)")
            }
        default: break
        }
        return nil
    }

    /// The gear and hook ids on clock `id`'s lists that name no open entry,
    /// gears first, each list in its own order. Empty for a clock this build wrote.
    public func danglingIds(onClock id: String) -> [String] {
        guard let e = clocks.get(id) else { return [] }
        return e.gearIds.filter { gears.get($0) == nil } + e.hookIds.filter { hooks.get($0) == nil }
    }

    /// Every hook id a clock holds for a hook that is not open: the ids a
    /// HOOK CLOSE of an older build left (live, in a log, or in a snapshot). Sorted by
    /// clock id, then list order; one entry per (clock, id).
    public func danglingHookBindings() -> [TwinHookBinding] {
        var out: [TwinHookBinding] = []
        for cid in clocks.ids.sorted() {
            guard let e = clocks.get(cid) else { continue }
            var seen = Set<String>()
            for hid in e.hookIds where hooks.get(hid) == nil && !seen.contains(hid) {
                seen.insert(hid)
                out.append(TwinHookBinding(clockId: cid, hookId: hid))
            }
        }
        return out
    }

    /// Why `.hookSweep(bindings)` would refuse, or nil: an empty list, a
    /// pair named twice, a clock not open, a clock that does not hold the
    /// id, or a hook that is open (the sweep removes dangling ids only).
    public func hookSweepRefusal(_ bindings: [TwinHookBinding]) -> String? {
        guard !bindings.isEmpty else { return "hook sweep names no hook id" }
        var seen = Set<TwinHookBinding>()
        for b in bindings {
            guard seen.insert(b).inserted else { return "hook sweep names \(b.hookId) on \(b.clockId) twice" }
            guard let c = clocks.get(b.clockId) else { return "hook sweep: clock \(b.clockId) is not open" }
            guard c.hookIds.contains(b.hookId) else {
                return "hook sweep: clock \(b.clockId) does not hold hook id \(b.hookId)"
            }
            guard hooks.get(b.hookId) == nil else { return "hook sweep: hook \(b.hookId) is open" }
        }
        return nil
    }

    /// What replaying one record did.
    public enum ReplayOutcome: Equatable {
        /// Applied with today's meaning.
        case applied
        /// A CLOCK ADVANCE whose clock held an id naming no open entry: such a
        /// record can only come from a log an older build wrote (the dangling
        /// id is the era marker), and it is replayed as the old daemon ran it
        /// live: one tick, the clock and the gears ahead of the id moved, the
        /// hooks ahead of it stepped, then the stop. `stoppedAt` is the id.
        case preHOOK1Stop(clockId: String, stoppedAt: String)
    }

    /// Replay's apply: `apply`, except for an older build's CLOCK ADVANCE
    /// (`ReplayOutcome.preHOOK1Stop`). Throws exactly when `apply` would, and
    /// then nothing changed.
    public func applyReplayed(
        _ op: TwinOp,
        alarmLoader: ((String, String) throws -> AlarmFixture)? = nil,
        viewLoader: ((String, String) throws -> CortexFixture)? = nil,
        kernelLoader: ((KernelRef) throws -> KernelPair)? = nil,
        admit: ((Int, String) -> String?)? = nil                          // the admission (see `apply`)
    ) throws -> ReplayOutcome {
        if case .clockAdvance(let id, let count, let value) = op, count >= 1, count <= UInt64(Self.replayCap),
           clocks.get(id) != nil, let stop = danglingIds(onClock: id).first {
            // The older builds' loop, tick 1 only: it threw at the first id that
            // named no open entry, after everything ahead of it had moved.
            var tick: UInt64 = 0
            do {
                try clocks.update(id) { entry in
                    entry.clock.advance()
                    tick = entry.clock.tick
                }
            } catch { throw mapError(error, in: clocks) }
            guard let entry = clocks.get(id) else { throw TwinError.notFound(id) }
            for gid in entry.gearIds {
                guard gears.get(gid) != nil else { return .preHOOK1Stop(clockId: id, stoppedAt: gid) }
                do {
                    try gears.update(gid) { g in g.gear.advance(masterTick: tick, value: value) }
                } catch { throw mapError(error, in: gears) }
            }
            for hid in entry.hookIds {
                guard hooks.get(hid) != nil else { return .preHOOK1Stop(clockId: id, stoppedAt: hid) }
                do {
                    try hooks.update(hid) { h in _ = h.hook.step() }
                } catch { throw mapError(error, in: hooks) }
            }
            return .preHOOK1Stop(clockId: id, stoppedAt: stop)   // unreachable: `stop` is on one of the lists
        }
        try apply(op, alarmLoader: alarmLoader, viewLoader: viewLoader, kernelLoader: kernelLoader, admit: admit)
        return .applied
    }

    /// Total entries open across all nine registries.
    public var totalOpen: Int {
        streams.openCount + records.openCount + rings.openCount + clocks.openCount
            + gears.openCount + layouts.openCount + alarms.openCount + banks.openCount
            + views.openCount + kernels.openCount + hooks.openCount
    }

    /// Close everything and return every registry's counter to 0 — the
    /// v≤6 snapshot-load behavior: an old-format snapshot carries
    /// no twin section, so the twin state starts fresh.
    /// The open records whose header HEADER CHECK refuses (only a log written
    /// before RECORD OPEN's finite rule replays one), sorted.
    public var recordsWithNonFiniteHeaders: [String] {
        records.entries.filter { !$0.value.header.isFinite }.map(\.key).sorted()
    }

    /// Every bound, open hook the restored file holds, with the times the
    /// file's clock lists it. An older build's restore kept the persisted list
    /// and appended every bound hook again: after a LOAD that daemon stepped a
    /// hook the file lists k times k steps per tick (the list proves it), and
    /// after its own startup restore of a file listing it once, twice (the log
    /// cannot say whether that restart happened). This restore lists it once
    /// (bugs are not replayed); recovery names the hooks its replay advanced over
    /// ticks before the era's start (`DagDBStartup`). `tick` and `t` are the clock's tick
    /// and the hook's frame as restored.
    public struct RestoredBoundHook: Equatable {
        public let clockId: String
        public let hookId: String
        public let times: Int
        public let tick: UInt64
        public let t: Int
    }

    /// Set by the last `restore` (and carried by `adopt`); empty after `reset`.
    public internal(set) var restoredBoundHooks: [RestoredBoundHook] = []

    public func reset() {
        restoredBoundHooks = []
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

    /// Every registry takes `staged`'s entries and
    /// counter. LOAD decodes and restores the snapshot's twin section into a
    /// fresh `TwinState` before anything is copied into the engine, and swaps
    /// it in here at the commit, which cannot fail.
    public func adopt(_ staged: TwinState) {
        streams.adopt(staged.streams); records.adopt(staged.records); rings.adopt(staged.rings)
        clocks.adopt(staged.clocks); gears.adopt(staged.gears); layouts.adopt(staged.layouts)
        alarms.adopt(staged.alarms); banks.adopt(staged.banks); views.adopt(staged.views)
        kernels.adopt(staged.kernels); hooks.adopt(staged.hooks)
        restoredBoundHooks = staged.restoredBoundHooks   // the bound hooks as restored
    }

    /// Codable persistence unit — snapshot v7's TWIN section and the
    /// WAL replay target both read/write this shape. Alarms persist
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
        /// merely read.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try c.decode(Int.self, forKey: .formatVersion)
            // Decoded and never compared, the field would let a future
            // version that reshapes banks/views/kernels/hooks restore those
            // registries EMPTY and report success.
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
        keepDanglingHookIds: Bool = false,
        alarmLoader: ((String, String) throws -> AlarmFixture)? = nil,
        viewLoader: ((String, String) throws -> CortexFixture)? = nil,
        kernelLoader: ((KernelRef) throws -> KernelPair)? = nil,
        warn: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
        /// The load's admission (bytes before the margin, what). The default loaders
        /// re-read each named file through it at its LIVE verb's charge (ALARM, VIEW, KERNEL LOAD), on the opened
        /// file's size; a bank's 4*T*K atoms and a hook's re-stepped rows (2 x 104 B each) are admitted before they
        /// are built. nil: nothing admitted. A refusal is a `RestoreFileRefusal` (a file) or the refusal itself.
        admit: ((Int, String) -> String?)? = nil
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
        // A bank LOAD decoded spec-only (`WaveBank.deferAtoms`) has its 4*T*K atoms built
        // here, each admitted first; a bank decoded with its atoms (any other caller) is opened as it came.
        for (id, w) in snap.banks.sorted(by: { $0.key < $1.key }) {
            var entry = w
            if w.bank.atomsDeferred {
                let built: WaveBank
                do { built = try Self.bankAtomsBuilder(admit, what: "bank \(id)")(w.bank.spec) }
                catch let r as DaemonFile.Refusal where r.isAdmission { throw r }
                catch { throw TwinError.badValue("bank \(id): \(Reply.errorWords(error))") }
                entry = BankEntry(name: w.name, bank: built)
            }
            do { try banks.open(entry, id: id) } catch { throw mapError(error, in: banks) }
        }
        // A file the section names that the daemon may not read (not a regular file, outside
        // the data root, changed while read, refused by admission) refuses the restore by name, and the
        // caller's load with it; nothing is dropped silently for those. An absent file or a pin mismatch keeps
        // the older rule (the set is dropped, with a warning).
        // The default loaders re-read each file at its live verb's charge (`admit`), in id
        // order, so the first file a budget refuses is the same on every daemon.
        for (id, ref) in snap.alarms.sorted(by: { $0.key < $1.key }) {
            do {
                let fixture = try (alarmLoader ?? Self.alarmFileLoader(admit, what: "alarm set \(id)"))(ref.path, ref.sha256)
                try alarms.open(AlarmSet(ref: ref, fixture: fixture), id: id)
            } catch let r as DaemonFile.Refusal {
                throw RestoreFileRefusal(what: "alarm set \(id)", refusal: r)
            } catch {
                warn("twin: dropping alarm set \(id) (\(ref.path)): \(Reply.errorWords(error))")
            }
        }
        for (id, ref) in snap.views.sorted(by: { $0.key < $1.key }) {
            do {
                let fixture = try (viewLoader ?? Self.viewFileLoader(admit, what: "view set \(id)"))(ref.path, ref.sha256)
                try views.open(ViewSet(ref: ref, views: DerivedViews(fixture: fixture)), id: id)
            } catch let r as DaemonFile.Refusal {
                throw RestoreFileRefusal(what: "view set \(id)", refusal: r)
            } catch {
                warn("twin: dropping view set \(id) (\(ref.path)): \(Reply.errorWords(error))")
            }
        }
        for (id, ref) in snap.kernels.sorted(by: { $0.key < $1.key }) {
            do {
                let pair = try (kernelLoader ?? Self.kernelFileLoader(admit, what: "kernel set \(id)"))(ref)
                try kernels.open(KernelSet(ref: ref, pair: pair), id: id)
            } catch let r as DaemonFile.Refusal {
                throw RestoreFileRefusal(what: "kernel set \(id)", refusal: r)
            } catch {
                warn("twin: dropping kernel set \(id) (\(ref.path)): \(Reply.errorWords(error))")
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
                // The alarm this hook is bound to was the one
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
            // The hook at its live charge, admitted before it is built: HOOK OPEN's index of its
            // alarm's records (260 B per record + 4 KB) and the re-stepped ledger's rows, 2 x 104 B each (CLOCK
            // ADVANCE's charge for a bound hook's rows); the rows are bounded by the hook's frames (records + delta).
            let records = alarmSet.fixture.records.count
            let rows = min(max(ref.t, 0), records + max(ref.params.delta, 0))
            if let a = admit,
               let line = a(Int((AdmissionCharge.hookIndex(records: records) + AdmissionCharge.hookRows(rows)).rounded(.up)),
                            "hook \(id) rebuilt at its live charge, 260 B per record of its alarm + 4 KB, and its ledger re-stepped,"
                                + " 2*\(MemoryLayout<AttentionHook.Row>.stride) B per row for \(rows) rows") {
                throw DaemonFile.Refusal.admission(line)
            }
            var hook: AttentionHook
            do {
                hook = try AttentionHook(params: ref.params, records: alarmSet.fixture.records, layout: hookLayout)
            } catch { throw TwinError.badValue(Reply.errorWords(error)) }
            hook.step(ref.t)
            // `step(_:)` is bounded by the hook's own frame
            // count, so a snapshot whose `t` exceeds it used to restore
            // silently at a DIFFERENT frame than it recorded.
            guard hook.t == ref.t else {
                throw TwinError.badValue(
                    "hook \(id) recorded frame \(ref.t) but its \(hook.frames)-frame ledger stops at \(hook.t)")
            }
            let entry = HookEntry(params: ref.params, hook: hook)
            do { try hooks.open(entry, id: id) } catch { throw mapError(error, in: hooks) }
        }

        // Each clock's hook list is rebuilt, so every open hook bound to it is
        // on it exactly once. Keeping the persisted list and appending every
        // bound hook's id again would make a bound hook step twice per tick
        // after a LOAD or a startup load (three times after two). An id the
        // file's own clock list holds for a hook the file does not hold (an
        // older build's HOOK CLOSE) is kept only when `keepDanglingHookIds`
        // (recovery: the era marker the WAL's older records replay against,
        // swept after recovery by one logged
        // record); a LOAD drops it. A hook this restore dropped (its alarm
        // file) leaves its clock too.
        var bound: [RestoredBoundHook] = []
        for (cid, c) in snap.clocks {
            var out: [String] = []
            var seen = Set<String>()
            // Every bound, open hook of this
            // clock, with the times the file lists it.
            var listed: [String: Int] = [:]
            for hid in c.hookIds { listed[hid, default: 0] += 1 }
            for (hid, h) in hooks.entries.sorted(by: { $0.key < $1.key }) where h.params.clockId == cid {
                bound.append(RestoredBoundHook(clockId: cid, hookId: hid, times: listed[hid] ?? 0, tick: c.clock.tick, t: h.hook.t))
            }
            for hid in c.hookIds where !seen.contains(hid) {
                if let h = hooks.get(hid) {
                    guard h.params.clockId == cid else { continue }
                } else if !(keepDanglingHookIds && snap.hooks[hid] == nil) {
                    continue
                }
                seen.insert(hid)
                out.append(hid)
            }
            for (hid, h) in hooks.entries.sorted(by: { $0.key < $1.key })
            where h.params.clockId == cid && !seen.contains(hid) {
                seen.insert(hid)
                out.append(hid)
            }
            do {
                try clocks.update(cid) { e in e.hookIds = out }
            } catch { throw mapError(error, in: clocks) }
        }
        restoredBoundHooks = bound.sorted { ($0.clockId, $0.hookId) < ($1.clockId, $1.hookId) }

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
