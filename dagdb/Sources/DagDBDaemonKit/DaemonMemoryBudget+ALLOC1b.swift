/// Admission at every
/// creator of a resident object, the committed-bytes ledger, count caps, the reader's back-edge copy,
/// TILED TICK's preflight, and CLOCK ADVANCE's work unit.
///
/// **The ledger.** phys_footprint can under-count live allocations (measured:
/// bound-hook ledgers 12.8x, tiled routers 2.9–4.1x), so admit() also checks the committed bytes:
/// max(footprint, fixed state + ledger) + new ≤ budget. The ledger is the sum, over every object the
/// daemon holds now, of that object's admitted resident bytes. It is recomputed at each admission from
/// the registries themselves, so an object a creator opened adds its bytes, a close, a cascade (a clock's
/// gears and hooks) or a LOAD's replacement removes them, and objects a LOAD or the startup replay
/// restored are counted too, with no bookkeeping that could drift.
///
/// **The bytes.** Each creator's measured factor + 10 % (re-measured for the file
/// loaders after the autorelease fix), as `1.1 × (a·formula + b)`: `a` the largest measured ratio to the code's formula, `b` the
/// absolute overhead the smallest shapes showed. The numbers below name their measurements.
import Foundation
import DagDB

extension DagDBCommandHandler {
    // MARK: - Count caps: from the real clients' largest counts
    /// Each twin kind (the largest real count is 3). One constant, `TwinState.kindCap`, which
    /// LOAD, the startup load and the boot's era lines read too.
    public static let alloc1bTwinKindCap = TwinState.kindCap
    /// Slices on one record (the largest real count is 3), checked after RECORD SLICE's shm check
    /// (`TwinState.slicesPerRecordCap`).
    public static let alloc1bSlicesPerRecordCap = TwinState.slicesPerRecordCap
    /// Open tiled routers (the largest real count is 2 per handler).
    public static let alloc1bTiledRouterCap = 16

    // MARK: - The admitted bytes per object (measured factor + 10 %)
    static let alloc1bMargin = 1.1

    static func bytesCount(_ x: Double) -> AdmitCount {
        let up = x.rounded(.up)
        return up >= 9.2e18 ? .more : AdmitCount(Int(up))
    }

    /// A creator's new bytes, never below two 16 KiB pages: the footprint grows by whole pages, and a small
    /// object can be the one that touches a new page of each of two arrays (measured: single CONNECT BACKs, 9 B
    /// each, took the footprint 9.9 KB past a 12.9 MB budget).
    static let alloc1bMinNewBytes = 32_768.0
    static func newBytes(_ x: Double) -> AdmitCount { bytesCount(max(x, alloc1bMinNewBytes)) }

    /// STREAM OPEN: 131 B with a 1-byte name, 4,309 B with a 3,900-byte one: 410 B + the name.
    static func alloc1bStreamBytes(nameBytes: Int) -> Double { alloc1bMargin * (410 + Double(nameBytes)) }
    /// RECORD OPEN: 288 B (a 5-byte name). A slice: 100.4 B (heap) at count 1, 1.04 × 8·count at 1,000
    /// and 10,000; the generator's draws are the sum of every slice's count.
    static func alloc1bRecordBytes(nameBytes: Int, slices: Int, draws: UInt64) -> Double {
        alloc1bMargin * (300 + Double(nameBytes) + 100 * Double(slices) + 8.32 * Double(draws))
    }
    /// RINGS OPEN g r c: 32·r·c of cells; measured after the first write 1.006–1.414 × 32rc (malloc's size
    /// classes; 1.414 at c = 1,024) and 1,843 B at c = 2. Admitted for the full shape at OPEN: the rings
    /// share one inner array until the first RINGS WRITE copies each.
    static func alloc1bRingsBytes(rings r: Int, cells c: Int) -> Double { alloc1bMargin * (1.414 * 32 * Double(r) * Double(c) + 1024) }
    /// CLOCK OPEN: 75 B.
    static let alloc1bClockBytes = 1.1 * 80.0
    /// GEAR OPEN: 191 B with a 1-byte name, 4,448 B with a 3,900-byte one: 550 B + the name.
    static func alloc1bGearBytes(nameBytes: Int) -> Double { alloc1bMargin * (550 + Double(nameBytes)) }
    /// BUDGET OPEN p t c: 8·p·t costs + 8·c classes (minTier is stored as Int from u32 wire values);
    /// measured 1.005–1.17x; BUDGET SEALED 524 B.
    static func alloc1bLayoutBytes(pockets p: Int, tiers t: Int, classes c: Int) -> Double {
        alloc1bMargin * (1.17 * (8 * Double(p) * Double(t) + 8 * Double(c)) + 600)
    }
    /// ALARM LOAD, resident (measured with one autorelease pool per command): 66–72 B per record (heap).
    static func alloc1bAlarmBytes(records: Int) -> Double { alloc1bMargin * (80 * Double(records) + 8192) }
    /// KERNEL LOAD, resident (measured the same way): 16.02–17.3 B per tap.
    static func alloc1bKernelBytes(taps: Int) -> Double { alloc1bMargin * (16.1 * Double(taps) + 2048) }
    /// VIEW LOAD: fixed by the only shape that loads, 15,007,760 B measured.
    static let alloc1bViewBytes = 1.1 * 15_100_000.0
    /// HOOK OPEN: 107–254 B per record of its alarm (byIndex).
    static func alloc1bHookBytes(records: Int) -> Double { alloc1bMargin * AdmissionCharge.hookIndex(records: records) }
    /// A hook's ledger rows, by the array's allocated capacity (a copied-on-write ledger allocates up to
    /// 2x its rows, and malloc's size classes round it; untouched capacity is counted).
    static func alloc1bHookRowBytes(capacity: Int) -> Double {
        alloc1bMargin * Double(MemoryLayout<AttentionHook.Row>.stride) * Double(capacity)
    }
    /// A bank's resident atoms, 4·T·K.
    static func alloc1bBankBytes(T: Int, K: Int) -> Double { alloc1bMargin * 4 * Double(T) * Double(K) }
    /// Back edges (8 B per edge, not 24), counted by the two lists' allocated capacity (Swift's growth
    /// leaves up to 2x the count allocated): 1.1 * 4 B per slot of each list.
    static func alloc1bBackEdgeListBytes(srcCapacity: Int, dstCapacity: Int) -> Double {
        alloc1bMargin * 4 * Double(srcCapacity + dstCapacity)
    }
    /// The ternary lanes the first CONNECT BACK on a binary graph allocates (it reads the mode lane): 11 B/node.
    static func alloc1bTernaryLaneBytes(nodes n: Int) -> Double { alloc1bMargin * 11 * Double(n) }
    /// A registry dictionary's spare buckets (RECORD OPEN measured up to 1.27x its per-record figure,
    /// the dictionary's load factor): (capacity / 0.75 - count) * (16 B key + the entry's stride).
    static func alloc1bDictSlack<E>(_ d: [String: E]) -> Double {
        alloc1bMargin * max(Double(d.capacity) / 0.75 - Double(d.count), 0) * Double(16 + MemoryLayout<E>.stride)
    }
    /// A tile engine resident in a router: 93.5–128 B per node on the query path, 96–164 B per node on
    /// the tick path above 8,192 nodes, and about 0.7 MB fixed per engine (440 B/node at 2,048 nodes).
    static func alloc1bTileEngineBytes(nodes n: Int) -> Double { alloc1bMargin * (128 * Double(n) + 943_718) }
    /// A router's steady state after a TILED TICK, per global node and per
    /// crossing (its manifest's crossingsIn entries), net of its one ghosted engine. Measured with heap on
    /// worlds of 8 tiles at 0, 1, 2 and 6 cross-tile reads per node: 13.77 B per
    /// node and 65.7 / 75.0 / 95.2 B per crossing; the largest, rounded up, x 1.1.
    static func alloc1bRouterBytes(globalNodes: UInt64, crossings: Int) -> Double {
        alloc1bMargin * (13.8 * Double(globalNodes) + 95.2 * Double(crossings))
    }
    /// TILED TICK's preflight per tile: 379.3 B per node measured (16,380-node tiles), a fixed part for small
    /// tiles (a real and a ghosted engine per load), and the ghosts loadTileWithGhosts adds:
    /// 922.6 / 995.6 / 939.4 B per crossingsIn entry measured (1, 2 and 6 reads per node, net of the GPU pool;
    /// the cost follows the entries, not the distinct sources: 1 to 2 reads doubled it at the same 57,344
    /// sources), 996 rounded up, x 1.1.
    static func alloc1bPreflightTileBytes(nodes n: UInt64, crossingsIn g: Int) -> Double {
        alloc1bMargin * (380 * Double(n) + 996 * Double(g) + 1_468_006)
    }
    /// TILED OPEN's manifest decode, admitted before the decode as
    /// 1.1 * (t * T + b * F). F is the file's bytes and T its count of , : [ { bytes plus 1 (alloc1bTokenScan),
    /// an upper bound on its values and keys. Measured in the daemon, OPEN's peak over the footprint before it
    /// (0.4-50 MB files): b on token-sparse files (64 KiB strings as array values, one
    /// long string decoded as the manifest's format, 64 KiB keys): 1.00 / 2.00-2.16 / 2.22-2.27 per byte, 2.28
    /// rounded up. t = (peak - b*F) / T, worst over: numbers of 1-10 digits (10.1-21.8 B per token), decoded as
    /// the manifest's boundaries (21.1-45.3, no growth phase), empty arrays and objects (22.1), nested and
    /// small-object arrays (25.8, 50.4), the daemon's own 19 worlds and 2 synthesized manifests across the
    /// scanner's switch (17.2-39.3), a dense manifest (42.5), and keys of 4 to 128 characters, including at the
    /// key dictionary's growth step (0.75 * 2^k + 1 keys): 64.0-97.4, the worst at 16 characters (the shortest
    /// key Swift stores on the heap). 97.4 rounded up.
    /// b re-measured over key lengths 16 B to 64 KiB with every size-class edge (2^k - 33,
    /// 2^k - 32, 2^k - 31, 2^k for k = 6-16), 1, 5 and 25 MB files: (peak - 97.4*T) / F
    /// reads at most 2.5087, at 32,735-32,768-character keys (a key's String just past 32 KiB lands in 48 KiB of
    /// pages); a 2 MB file of 32,736-character keys needs 2.5115. 2.52 rounded up.
    /// t is 98.4, the one pair the JSON loaders share (TILED OPEN's 97.4 did not cover the 16-character-key
    /// file on ALARM LOAD, 98.3 needed).
    static let alloc1bDecodePerToken = AdmissionCharge.jsonParsePerToken
    static let alloc1bDecodePerByte = 2.52
    static func alloc1bManifestDecodeBytes(tokens: Int, bytes: Int) -> Double {
        alloc1bMargin * (alloc1bDecodePerToken * Double(tokens) + alloc1bDecodePerByte * Double(bytes))
    }
    /// T over the bytes TILED OPEN read: (their , : [ { bytes) + 1. The bytes counted
    /// are the bytes decoded, one in-memory copy.
    /// The one scanner, `AdmissionCharge.jsonTokens`, which LOAD's twin section reads too.
    static func alloc1bTokenCount(_ data: Data) -> Int { AdmissionCharge.jsonTokens(data) }
    /// TILED OPEN reads manifest.json once. It opens the path without
    /// blocking (a FIFO's open does not wait for a writer), fstats the descriptor, and refuses anything but a
    /// regular file with the earlier reply (Data(contentsOf:) fails on a FIFO, a device or a directory: "tile
    /// manifest not found"). It admits b*F for F = st_size before the read, reads at most st_size bytes once,
    /// then admits the whole decode charge over those bytes before decoding them. The read's copy is
    /// kept in the second check, as it may sit on pages the footprint omits.
    /// Returns the manifest, or the reply that refuses (nothing changed but tiled_refused).
    /// The reader is `DaemonFile.Reader` (the open, fstat and bounded read, generalized, plus
    /// containment by the descriptor and the fstat after the read). ENOENT keeps the earlier reply; a file that is
    /// not regular, outside the root, cut or changed while read is refused by name (earlier builds answered
    /// "tile manifest not found" to all of those).
    func alloc1bReadManifest(path: String) -> (manifest: TiledGraphFiles.Manifest?, reply: String?) {
        let missing = "ERROR io: \(RouterError.manifestMissing(path))"
        let r: DaemonFile.Reader
        do { r = try DaemonFile.Reader(path) }
        catch DaemonFile.Refusal.missing { tiledOpenRefusedCount += 1; return (nil, missing) }
        catch { tiledOpenRefusedCount += 1; return (nil, "ERROR io: TiledGraphRouter: \(Reply.errorWords(error))") }
        let size = r.size
        if memoryBudget != nil,
           let e = admit("TILED OPEN", bytes: Self.newBytes(Self.alloc1bMargin * Self.alloc1bDecodePerByte * Double(size)),
                         what: "the manifest's read, 1.1*\(Self.alloc1bDecodePerByte) B per byte for \(size) B") { return (nil, e) }
        let data: Data
        do { data = try r.read(size); try r.finish(whole: true) }
        catch { tiledOpenRefusedCount += 1; return (nil, "ERROR io: TiledGraphRouter: \(Reply.errorWords(error))") }
        if memoryBudget != nil {
            let tokens = Self.alloc1bTokenCount(data)
            if let e = admit("TILED OPEN", bytes: Self.newBytes(Self.alloc1bManifestDecodeBytes(tokens: tokens, bytes: data.count)),
                             what: "the manifest's decode, 1.1*(\(Self.alloc1bDecodePerToken) B per token +"
                                 + " \(Self.alloc1bDecodePerByte) B per byte) for \(tokens) tokens (its , : [ { bytes + 1)"
                                 + " and \(data.count) B") { return (nil, e) }
        }
        do {
            return (try TiledGraphFiles.decodeManifest(data), nil)
        } catch {
            tiledOpenRefusedCount += 1
            return (nil, "ERROR io: \(Reply.errorWords(error))")
        }
    }
    /// A router keeps its decoded manifest whole, so its resident charge counts
    /// every field: the steady state's 13.8 B per global node and 95.2 B per crossingsIn entry (the steady state after a
    /// TILED TICK), and per crossingsOut entry, per tile, per boundary, per engineIndexOf entry, and each string
    /// (format, name, every bodySHA256) by its bytes. Measured on crafted manifests that open, one field varied
    /// at a time, as live heap + non-malloc dirty 3 s after OPEN: a tile 193.8-243.8
    /// B (its dictionaries' growth step included); a crossingsOut entry up to 48.2 sampled, and at most 51.0 by the
    /// bracket of its array's growth step (85,000 -> 90,000 entries doubles the array); an engineIndexOf entry or a
    /// boundary up to 15.9 sampled, at most 18.2 by its bracket (700,000 -> 800,000); a string 64 B (16 characters,
    /// the shortest on the heap) and at most 1.507 B per byte beyond that (a 32,735-32,768-byte string lands in 48
    /// KiB; 1.07-1.26 elsewhere, 1.01-1.14 for one long name). Each rounded up, x 1.1.
    static let alloc1bResPerCrossingOut = 51.0
    static let alloc1bResPerTile = 244.0
    static let alloc1bResPerBoundary = 18.2
    static let alloc1bResPerIndexEntry = 18.2
    static let alloc1bResPerString = 64.0
    static let alloc1bResPerStringByte = 1.51
    static func alloc1bRouterResident(_ m: TiledGraphFiles.Manifest, k: Int) -> (bytes: Double, what: String) {
        var cin = 0, cout = 0, eio = 0, sbytes = m.format.utf8.count + m.name.utf8.count
        for t in m.tiles {
            cin += t.crossingsIn.count; cout += t.crossingsOut.count; eio += t.engineIndexOf.count
            sbytes += t.bodySHA256.utf8.count
        }
        let strings = m.tiles.count + 2
        let maxTile = m.tiles.map { t in Int(clamping: t.nodeCount) + Set(t.crossingsIn.map { $0.remoteNode.raw }).count }.max() ?? 0
        let engines = 2 * min(k, m.tiles.count)
        let fields = alloc1bRouterBytes(globalNodes: m.globalNodeCount, crossings: cin)
            + alloc1bMargin * (alloc1bResPerCrossingOut * Double(cout) + alloc1bResPerTile * Double(m.tiles.count)
                               + alloc1bResPerBoundary * Double(m.boundaries.count) + alloc1bResPerIndexEntry * Double(eio)
                               + alloc1bResPerString * Double(strings) + alloc1bResPerStringByte * Double(sbytes))
        let bytes = fields + Double(engines) * alloc1bTileEngineBytes(nodes: maxTile)
        let what = "the router's steady state, 1.1*(13.8 B per global node + 95.2 B per crossingsIn entry"
            + " + \(alloc1bResPerCrossingOut) B per crossingsOut entry + \(alloc1bResPerTile) B per tile"
            + " + \(alloc1bResPerBoundary) B per boundary + \(alloc1bResPerIndexEntry) B per engineIndexOf entry"
            + " + \(alloc1bResPerString) B per string + \(alloc1bResPerStringByte) B per string byte) for \(m.globalNodeCount)"
            + " nodes, \(cin) + \(cout) crossings, \(m.tiles.count) tiles, \(m.boundaries.count) boundaries, \(eio) entries"
            + " and \(strings) strings of \(sbytes) B, and \(engines) tile engines of \(maxTile) nodes with ghosts,"
            + " 1.1*(128 B per node + 0.9 MiB) each"
        return (bytes, what)
    }
    /// The ternary table library's buffer: 729 B per table of capacity.
    static func alloc1bLibraryBytes(capacity: Int) -> Double { alloc1bMargin * Double(TernaryReference.tableSize * capacity) }
    /// The capacity ensureTableCapacity grows to for `tables` (its own rule: doubling, at most maxTables).
    static func libraryCapacity(from current: Int, for tables: Int) -> Int {
        guard tables > current else { return current }
        var cap = max(current, 1)
        while cap < tables { cap *= 2 }
        return max(min(cap, TernaryReference.maxTables), tables)
    }

    // MARK: - The ledger

    /// The committed bytes of every object the daemon holds now.
    /// Every sum over a dictionary runs in sorted id order (a Double sum's last bit, and so
    /// the refusal's `ledger N`, would otherwise follow the per-process hash order).
    func committedLedgerBytes() -> Int {
        Self.ledgerBytes(twin: twin, engine: engine, sessions: sessionManager.openSessions,
                         routerBytes: tiledRouters.sorted(by: { $0.key < $1.key }).map { $0.value.admittedBytes },
                         truthIndexHeld: truthRankIndex.holdsLists)
    }

    /// The ledger from its parts, so the boot (no handler yet; no sessions, no routers) sums
    /// the same terms over what the startup load and the replay rebuilt.
    /// `backEdgeSlots` and `libraryCapacity`, when given, stand for the primary engine's list
    /// slots (each list) and library capacity: the state a load is about to leave.
    static func ledgerBytes(twin: TwinState, engine: DagDBEngine, sessions: [DagDBReaderSession], routerBytes: [Int],
                            backEdgeSlots: Int? = nil, libraryCapacity: Int? = nil, truthIndexHeld: Bool = false) -> Int {
        var s = 0.0
        // The engine's first-use state (lanes, rank table, the first ticks' buffers), the latch
        // plan's resident and SELECT's index, while they exist.
        s += alloc1dEngineLedger(engine: engine, truthIndexHeld: truthIndexHeld)
        for (_, x) in twin.streams.entries.sorted(by: { $0.key < $1.key }) { s += Self.alloc1bStreamBytes(nameBytes: x.name.utf8.count) }
        for (_, x) in twin.records.entries.sorted(by: { $0.key < $1.key }) {
            s += Self.alloc1bRecordBytes(nameBytes: x.streamName.utf8.count, slices: x.slices.count, draws: x.generatorState.draws)
        }
        for (_, x) in twin.rings.entries.sorted(by: { $0.key < $1.key }) { s += Self.alloc1bRingsBytes(rings: x.rings, cells: x.cellsPerRing) }
        s += Self.alloc1bClockBytes * Double(twin.clocks.openCount)
        for (_, x) in twin.gears.entries.sorted(by: { $0.key < $1.key }) { s += Self.alloc1bGearBytes(nameBytes: x.gear.name.utf8.count) }
        for (_, x) in twin.layouts.entries.sorted(by: { $0.key < $1.key }) {
            s += Self.alloc1bLayoutBytes(pockets: x.cost.count, tiers: x.cost.first?.count ?? 0, classes: x.minTier.count)
        }
        for (_, x) in twin.alarms.entries.sorted(by: { $0.key < $1.key }) { s += Self.alloc1bAlarmBytes(records: x.fixture.records.count) }
        for (_, x) in twin.banks.entries.sorted(by: { $0.key < $1.key }) { s += Self.alloc1bBankBytes(T: x.bank.T, K: x.bank.K) }
        s += Self.alloc1bViewBytes * Double(twin.views.openCount)
        for (_, x) in twin.kernels.entries.sorted(by: { $0.key < $1.key }) { s += Self.alloc1bKernelBytes(taps: x.pair.taps) }
        for (_, x) in twin.hooks.entries.sorted(by: { $0.key < $1.key }) {
            s += Self.alloc1bHookBytes(records: max(x.hook.frames - x.params.delta, 0))
                + Self.alloc1bHookRowBytes(capacity: x.hook.ledger.capacity)
        }
        s += Self.alloc1bDictSlack(twin.streams.entries) + Self.alloc1bDictSlack(twin.records.entries)
            + Self.alloc1bDictSlack(twin.rings.entries) + Self.alloc1bDictSlack(twin.clocks.entries)
            + Self.alloc1bDictSlack(twin.gears.entries) + Self.alloc1bDictSlack(twin.layouts.entries)
            + Self.alloc1bDictSlack(twin.alarms.entries) + Self.alloc1bDictSlack(twin.banks.entries)
            + Self.alloc1bDictSlack(twin.views.entries) + Self.alloc1bDictSlack(twin.kernels.entries)
            + Self.alloc1bDictSlack(twin.hooks.entries)
        for r in sessions {
            let e = r.snapshotEngine
            s += alloc1dEngineLedger(engine: e, truthIndexHeld: false)   // a session engine's first-use state
            s += Self.alloc1bMargin * Double(77 * r.nodeCount) + 118_000 + Self.alloc1bLibraryBytes(capacity: e.ttableCapacity)
                + Self.alloc1bBackEdgeListBytes(srcCapacity: e.backEdgeSrcs.capacity, dstCapacity: e.backEdgeDsts.capacity)
        }
        s += Self.alloc1bLibraryBytes(capacity: libraryCapacity ?? engine.ttableCapacity)   // the primary's library
        for b in routerBytes { s += Double(b) }
        s += Self.alloc1bBackEdgeListBytes(srcCapacity: backEdgeSlots ?? engine.backEdgeSrcs.capacity,
                                           dstCapacity: backEdgeSlots ?? engine.backEdgeDsts.capacity)
        return s >= 9.2e18 ? Int.max : Int(s.rounded(.up))
    }


    // MARK: - Count-cap refusals

    /// nil when `open` objects of `kind` leave room for one more under `cap`.
    func alloc1bCountRefusal(_ verb: String, open: Int, kind: String, cap: Int) -> String? {
        guard open >= cap else { return nil }
        return "ERROR out_of_budget: \(verb) needs \(open + 1) open \(kind), the \(kind) cap is \(cap); nothing written"
    }

    func alloc1bTwinCap(_ verb: String, prefix: Character) -> String? {
        // Every twin opener passes here
        // before it mints; an id still open is refused before the WAL.
        if let e = hook1MintRefusal(verb, prefix: prefix) { return e }
        let (open, kind): (Int, String)
        switch prefix {
        case "s": (open, kind) = (twin.streams.openCount, "streams")
        case "t": (open, kind) = (twin.records.openCount, "records")
        case "n": (open, kind) = (twin.rings.openCount, "rings")
        case "c": (open, kind) = (twin.clocks.openCount, "clocks")
        case "g": (open, kind) = (twin.gears.openCount, "gears")
        case "b": (open, kind) = (twin.layouts.openCount, "budget layouts")
        case "a": (open, kind) = (twin.alarms.openCount, "alarm sets")
        case "w": (open, kind) = (twin.banks.openCount, "banks")
        case "v": (open, kind) = (twin.views.openCount, "view sets")
        case "k": (open, kind) = (twin.kernels.openCount, "kernel sets")
        case "h": (open, kind) = (twin.hooks.openCount, "hooks")
        default: return nil
        }
        return alloc1bCountRefusal(verb, open: open, kind: kind, cap: Self.alloc1bTwinKindCap)
    }

    /// The count cap, then the bytes, for a twin creator.
    func admitTwinCreate(_ verb: String, prefix: Character, bytes: Double, what: String) -> String? {
        if let e = alloc1bTwinCap(verb, prefix: prefix) { return e }
        return admit(verb, bytes: Self.newBytes(bytes), what: what)
    }

    /// A file loader's size before it is read (nil: the loader's own refusal says why).
    /// The opened file's st_size (fstat; never lstat, which would charge a link its own length).
    static func fileBytes(_ path: String) -> Int? {
        (try? DaemonFile.sizeIfPresent(path)) ?? nil
    }

    // MARK: - The ternary table library

    /// TTABLE_BULK, TTABLE DEFINE, TTABLE PRESET, COMPOSE: a write that grows the library admits the new buffer,
    /// 1.1 * 729 B per table of its new capacity; the old buffer, still held during the copy, is in the ledger.
    func admitTableGrowth(_ verb: String, engine e: DagDBEngine, tables: Int) -> String? {
        guard memoryBudget != nil, tables > e.ttableCapacity else { return nil }
        let cap = Self.libraryCapacity(from: e.ttableCapacity, for: tables)
        return admit(verb, bytes: Self.newBytes(Self.alloc1bLibraryBytes(capacity: cap)),
                     what: "the table library's new buffer, 1.1*729 B per table for a capacity of \(cap)")
    }

    // MARK: - Back edges

    /// CONNECT BACK and CONNECT_BACK_BULK: 1.1*8 B per new edge; the rows' staging; when the two lists must
    /// grow past their capacity, the new buffers at up to twice the edges (1.1*16 B per edge, the old ones
    /// still held); and, on a binary graph, the ternary lanes the first check allocates.
    func admitBackEdges(_ verb: String, count: Int, stagingBytesPerRow: Int) -> String? {
        guard count > 0, memoryBudget != nil else { return nil }
        let m = engine.backEdgeSrcs.count
        let cap = min(engine.backEdgeSrcs.capacity, engine.backEdgeDsts.capacity)
        let grow = m + count > cap ? Self.alloc1bMargin * 16 * Double(m + count) : 0
        let lanes = engine.ternaryLaneView == nil ? Self.alloc1bTernaryLaneBytes(nodes: nodeCount) : 0
        let b = Self.alloc1bMargin * 8 * Double(count) + Self.alloc1bMargin * Double(stagingBytesPerRow) * Double(count) + grow + lanes
        return admit(verb, bytes: Self.newBytes(b),
                     what: "the new back edges, 1.1*8 B each for \(count)" + (stagingBytesPerRow > 0 ? ", their staging, 1.1*\(stagingBytesPerRow) B each" : "")
                         + (grow > 0 ? ", the lists' new buffers as they grow, 1.1*16 B per edge" : "")
                         + (lanes > 0 ? ", and the ternary lanes, 1.1*11 B per node" : ""))
    }

    // MARK: - CLOCK ADVANCE: work and ledger-row bytes

    /// ns per unit, each the slowest measured at the machine's real load (1-minute load average 3.0–4.4)
    /// plus 10 %: the floor per tick, a gear per tick, an active bound hook's step apart from
    /// its copy, a finished bound hook per tick, and one ledger row copied (the copy-on-write of a bound
    /// hook's whole ledger on every step).
    public static let alloc1bClockFloorNs = 87.7
    public static let alloc1bClockGearNs = 70.2
    public static let alloc1bClockHookStepNs = 688.0
    public static let alloc1bClockHookDoneNs = 185.0      // 167.3 x 1.1 = 184.03, rounded up
    public static let alloc1bClockRowNs = 13.78           // 12.522 x 1.1 = 13.774, rounded up
    public static let alloc1bClockWorkCapNs = 60_000_000_000
    /// A bound hook's ledger row, at up to twice the rows (the copy-on-write's capacity), 1.1 * 2 * the stride.
    static let alloc1bClockRowBytes = 1.1 * 2 * Double(MemoryLayout<AttentionHook.Row>.stride)

    /// The bound hooks' s new rows and the copy of the longest ledger, 1.1 * 2 * 104 B per row (the boot's
    /// replay admits a replayed CLOCK ADVANCE by the same bytes).
    static func clockAdvanceRowBytes(twin: TwinState, clockId: String, n: Int) -> Double {
        guard let entry = twin.clocks.get(clockId) else { return 0 }
        var rows = 0.0, longest = 0.0
        for hid in entry.hookIds {
            guard let h = twin.hooks.get(hid) else { continue }
            let s = Double(min(n, max(h.hook.frames - h.hook.t, 0))), L = Double(h.hook.ledger.count)
            rows += s
            if s > 0 { longest = max(longest, L + s) }
        }
        return alloc1bClockRowBytes * (rows + longest)
    }

    /// W = n·floor + n·G·gear + Σ over bound hooks [s·step + (n − s)·done + row·(s·L + s(s−1)/2)] ns, and the
    /// bytes: the s new rows of every bound hook, plus the copy of the longest ledger.
    func admitClockAdvance(clockId: String, n: Int) -> String? {
        guard let entry = twin.clocks.get(clockId) else { return nil }
        let N = Double(n), G = Double(entry.gearIds.count)
        var ns = N * Self.alloc1bClockFloorNs + N * G * Self.alloc1bClockGearNs
        for hid in entry.hookIds {
            guard let h = twin.hooks.get(hid) else { continue }
            let s = Double(min(n, max(h.hook.frames - h.hook.t, 0))), L = Double(h.hook.ledger.count)
            ns += s * Self.alloc1bClockHookStepNs + (N - s) * Self.alloc1bClockHookDoneNs
                + Self.alloc1bClockRowNs * (s * L + s * max(s - 1, 0) / 2)
        }
        let bytes = Self.newBytes(Self.clockAdvanceRowBytes(twin: twin, clockId: clockId, n: n))
        return admit("CLOCK ADVANCE", bytes: bytes,
                     what: "the bound hooks' new ledger rows and the copy of the longest ledger, 1.1*2*104 B per row",
                     work: [AdmitWork(units: "CLOCK ADVANCE work ns (n*87.7 + n*G*70.2 + per bound hook s*688"
                                          + " + (n-s)*185 + 13.78*(s*L + s(s-1)/2))",
                                      needed: Self.nsCount(ns), cap: Self.alloc1bClockWorkCapNs)])
    }
}
