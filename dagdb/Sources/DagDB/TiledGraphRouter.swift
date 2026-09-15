/// TiledGraphRouter — supervises tile-resident DagDB engines, routes queries.
///
/// Step 4 of `docs/tiled-streaming.md` build order, filled per
/// `docs/contracts/TILING_GATES_FROZEN.md` gates T2/T3/T4's router parts.
/// Live tile load / evict + cross-tile BFS / ancestry / select. Pre-fetch,
/// ticking across tiles, and persistence (`save`/`close`) remain out of
/// scope (steps 5–7; the contract's "Not promised" list) — those two stay
/// `notImplemented` stubs.
///
/// Where this diverges from the spec wording in §6.5:
///
/// - The spec uses raw `UInt64` for global node IDs. This codebase has
///   a `GlobalNodeID` value type (24-tile + 40-local u64 packing) that
///   already enforces the encoding invariants. The router takes and
///   returns `GlobalNodeID` on the public surface; the spec's free
///   `UInt64` form is recoverable as `globalId.raw`.
/// - The spec uses `HaloStrip` (the Savanna-fields name); we use
///   `DagHaloStrip` (DagDB-fields, after step 1's port). The router
///   doesn't populate real halo strip *contents* (§7.2's tick-time
///   halo-staleness machinery is out of this contract's scope — see
///   "Not promised"); `ResidentTile.upperHalo`/`lowerHalo` are empty
///   placeholders kept only so the field exists for a future ticking pass.
/// - `tileId` is `UInt32` here (matching `GlobalNodeID.tileId`). The
///   spec's `UInt64` was loose — a 24-bit value comfortably fits u32.
///
/// Cross-tile edge resolution (AMENDMENT 1 item 1's direction: a node's
/// slots hold its HIGHER-rank sources): a resident tile's per-node
/// expansion needs two things beyond its own `body.dags` neighbour slots
/// (which cover intra-tile sources directly, `-2` marking a cross-tile
/// one):
///
///   - `crossOutIndex[localId]` — the foreign sources this local node's
///     `-2` slots resolve to (from `meta.crossingsOut`, grouped by
///     `localNode`; slot identity isn't needed, only the resulting
///     neighbour set).
///   - `inEdgeIndex[localId]` — who references this local node as THEIR
///     source (fan-out): built once at load time by scanning the tile's
///     own neighbour buffer (intra-tile) plus `meta.crossingsIn` /
///     `crossingsInByTile` (cross-tile). Needed for undirected BFS (a
///     lower tile reaching "up" through a higher tile's exposed
///     `crossingsIn`, and vice versa) and NOT needed for backward-only
///     ancestry (which follows sources only).
import Foundation

// MARK: - Public types

/// Per-tile metadata stored in `meta.json`.
public struct TileMeta: Codable, Sendable {
    public let id: UInt32
    public let rankLo: UInt64
    public let rankHi: UInt64
    public let nodeCount: UInt64
    public var lastPersistedTickEpoch: UInt64
    public var crossingsOut: [Crossing]
    public var crossingsIn: [Crossing]

    public init(
        id: UInt32,
        rankLo: UInt64,
        rankHi: UInt64,
        nodeCount: UInt64,
        lastPersistedTickEpoch: UInt64 = 0,
        crossingsOut: [Crossing] = [],
        crossingsIn: [Crossing] = []
    ) {
        self.id = id
        self.rankLo = rankLo
        self.rankHi = rankHi
        self.nodeCount = nodeCount
        self.lastPersistedTickEpoch = lastPersistedTickEpoch
        self.crossingsOut = crossingsOut
        self.crossingsIn = crossingsIn
    }
}

/// One cross-tile edge: this tile's local node references a node in
/// another tile (encoded as a GlobalNodeID).
///
/// `foreignRank` (ticking gates, `docs/contracts/TICKING_GATES_FROZEN.md`
/// mechanism letter — ghost nodes carry "rank = the foreign node's rank"):
/// the rank (in the original untiled engine's rank space) of `remoteNode`.
/// Written at tile-write time (`TiledGraphFiles.write`'s pass 1, which
/// already has both endpoints' ranks on hand) so a ghost's rank can be
/// read straight off `crossingsOut` at load time without touching the
/// foreign tile's own files. Defaulted to 0 so existing call sites /
/// decoders of pre-ticking-gate `Crossing` values keep compiling; every
/// `Crossing` this codebase itself writes now carries the real value.
public struct Crossing: Codable, Sendable, Hashable {
    public let localNode: UInt64
    public let remoteNode: GlobalNodeID
    public let foreignRank: UInt64

    public init(localNode: UInt64, remoteNode: GlobalNodeID, foreignRank: UInt64 = 0) {
        self.localNode = localNode
        self.remoteNode = remoteNode
        self.foreignRank = foreignRank
    }
}

/// Buffer-name enum used for selective dirty-flush during tile eviction.
/// Each name corresponds to a per-node Metal buffer the engine maintains.
public enum TileBuffer: String, Sendable, Hashable, CaseIterable {
    case rank
    case truth
    case nodeType
    case lut
    case neighbors
    case halo
}

/// One resident tile: full DagDB engine instance bound to a rank range,
/// plus its halos and bookkeeping, plus the two lookup indexes cross-tile
/// query expansion needs (see the file header comment).
public final class ResidentTile {
    public let id: UInt32
    public let engine: DagDBEngine
    public let meta: TileMeta
    /// True node count (may be less than `engine.nodeCount` only for the
    /// degenerate empty-tile case, where the engine is padded to 1 — see
    /// `TiledGraphFiles.tileLocalEngine`). Always the count to iterate.
    public let nodeCount: Int
    public let upperHalo: DagHaloStrip
    public var lowerHalo: DagHaloStrip
    public var dirtyBuffers: Set<TileBuffer>
    public var lastTickEpoch: UInt64
    let inEdgeIndex: [UInt64: [GlobalNodeID]]
    let crossOutIndex: [UInt64: [GlobalNodeID]]

    public init(
        id: UInt32,
        engine: DagDBEngine,
        meta: TileMeta,
        nodeCount: Int,
        upperHalo: DagHaloStrip,
        lowerHalo: DagHaloStrip,
        inEdgeIndex: [UInt64: [GlobalNodeID]] = [:],
        crossOutIndex: [UInt64: [GlobalNodeID]] = [:],
        dirtyBuffers: Set<TileBuffer> = [],
        lastTickEpoch: UInt64 = 0
    ) {
        self.id = id
        self.engine = engine
        self.meta = meta
        self.nodeCount = nodeCount
        self.upperHalo = upperHalo
        self.lowerHalo = lowerHalo
        self.inEdgeIndex = inEdgeIndex
        self.crossOutIndex = crossOutIndex
        self.dirtyBuffers = dirtyBuffers
        self.lastTickEpoch = lastTickEpoch
    }
}

/// One resident tile for the TICKING path (`TiledGraphRouter.worldTick`),
/// parallel to (and independent of) `ResidentTile` — the query path
/// (`runBFS`/`runAncestry`/`runSelect`) keeps its own `-2`-sentinel /
/// `crossOutIndex` resolution untouched, so this type exists rather than
/// growing `ResidentTile` itself: a ghosted engine rewrites `-2` slots to
/// point at real (in-buffer) ghost node indices, which would silently
/// break `sourcesOf`'s "non-negative slot ⇒ intra-tile local id"
/// classification if the two paths shared one engine instance. See
/// `TiledGraphFiles.loadTileWithGhosts`'s doc comment for the ghost
/// construction itself.
///
/// `engine` is sized `realNodeCount + ghostCount`: nodes
/// `0..<realNodeCount` are this tile's own (copied from its `body.dags`,
/// `-2` slots rewritten to ghost indices); nodes
/// `realNodeCount..<realNodeCount+ghostCount` are the ghost registers,
/// one per distinct foreign source in `meta.crossingsOut`, in the same
/// order as `ghostSources`.
final class TickResidentTile {
    let id: UInt32
    let engine: DagDBEngine
    var meta: TileMeta
    let realNodeCount: Int
    let ghostCount: Int
    /// Ghost `g`'s foreign source, `(tile, local)` — index `g` corresponds
    /// to engine node `realNodeCount + g`. Ascending `(tile, local)` order
    /// (the contract's letter for ghost construction).
    let ghostSources: [(tile: UInt32, local: UInt64)]

    init(
        id: UInt32, engine: DagDBEngine, meta: TileMeta,
        realNodeCount: Int, ghostCount: Int,
        ghostSources: [(tile: UInt32, local: UInt64)]
    ) {
        self.id = id
        self.engine = engine
        self.meta = meta
        self.realNodeCount = realNodeCount
        self.ghostCount = ghostCount
        self.ghostSources = ghostSources
    }
}

/// Rank vs sync world-tick propagation — `DagDBEngine.tick` (leaves-up,
/// ranks max→0 within one world tick) vs `DagDBEngine.tickSync`
/// (ping-pong, one hop per world tick). See the contract's mechanism
/// letter for how each mode sources ghost inputs.
public enum TickMode: Sendable, Equatable {
    case rank
    case sync

    /// The third field of a `TILE_FLUSH_BEGIN` WAL record (ticking gates
    /// AMENDMENT 2, letter 4).
    var walToken: String {
        switch self {
        case .rank: return "rank"
        case .sync: return "sync"
        }
    }

    init?(walToken: String) {
        switch walToken {
        case "rank": self = .rank
        case "sync": self = .sync
        default: return nil
        }
    }
}

/// A `TiledGraphRouter`'s role at open (ticking gates AMENDMENT 3, letter
/// 1) — a mixed-epoch ("torn") world must never answer a query.
/// **Writer** (the daemon's `TILED OPEN`, and the default): recovers any
/// dangling flush, then completes a partial round if the tiles disagree
/// on epoch, then returns — a writer's world is never torn when it
/// answers. **Reader**: refuses a torn world by name
/// (`RouterError.worldTorn`) rather than recovering or ticking — readers
/// answer queries only, never mutate the directory.
public enum RouterRole: Sendable, Equatable {
    case writer
    case reader
}

/// What a writer-role `init` did before returning (ticking gates
/// AMENDMENT 3, letter 1) — `recovered`: tiles whose `flush.wal` ended in
/// an unmatched `TILE_FLUSH_BEGIN`, fixed (case i re-ticked, case ii
/// regenerated). `completed`: tiles ticked, at the round's own epoch and
/// inputs, to catch up a partial round left by a between-tiles
/// interruption (every `flush.wal` clean, entries mixed). Always
/// `(0, 0)` for a reader (readers never recover or tick) and for a writer
/// opening a never-torn directory.
public struct OpenReport: Sendable, Equatable {
    public let recovered: Int
    public let completed: Int
}

/// `TiledGraphRouter.worldTick`'s report — aggregated across every tile
/// touched and every world tick in the call (`count` may be > 1).
/// `tickMsPerTile`/`flushMsPerTile` are the MAX over every tile-tick /
/// tile-flush the call performed (W6's letter: "tick ms per tile").
public struct WorldTickReport: Sendable {
    public let epoch: UInt64
    public let tilesTicked: Int
    public let loads: Int
    public let evicts: Int
    public let flushes: Int
    public let haloBytes: Int
    public let tickMsPerTile: Double
    public let flushMsPerTile: Double
}

/// Public status snapshot for the router.
public struct TiledStatus: Sendable, Codable {
    public let dataRoot: String
    public let graphName: String
    public let residentTileCount: Int
    public let maxResidentTiles: Int
    public let totalTickCount: UInt64
    /// T3: cumulative disk loads (cache misses only — a resident-tile hit
    /// never increments this).
    public let loads: Int
    /// T3: cumulative evictions.
    public let evicts: Int
    /// T4: cumulative refused loads (hash mismatch / epoch mismatch).
    public let refused: Int
    /// T4: description of the most recent refusal, if any.
    public let lastRefusal: String?
    /// T3: the largest resident-tile count observed at any point so far
    /// (never exceeds `maxResidentTiles` — asserted by `testT3Residency`).
    public let maxResidentSeen: Int
    /// Ticking gates AMENDMENT 2, letter 2: the router holds no global
    /// tick counter — its epoch is the (min, max) over every tile's own
    /// `TileEntry.tickEpoch`. Equal (quiet state) for a reader (which
    /// refuses to open torn) and for a writer (which completes any
    /// partial round at open, and every `worldTick` leaves them equal
    /// again).
    public let epochMin: UInt64
    public let epochMax: UInt64
}

/// Errors raised by the router. Stable category names for DSL-error parity.
public enum RouterError: Error, CustomStringConvertible, Sendable {
    case notImplemented(String)
    case tileNotResident(UInt32)
    case crossTileBoundsExceeded(UInt32)
    case manifestMissing(String)
    /// T4: a tile's `body.dags` sha256 differs from the manifest's recorded
    /// hash — present-but-changed, refused, never loaded silently.
    case tileHashMismatch(UInt32, expected: String, actual: String)
    /// T4: `meta.json.last_persisted_tick_epoch` disagrees with the body's
    /// own `tickCount` (`DagDBSnapshot.LoadResult.fileTicks`) — the flush
    /// crashed mid-way; refused, never loaded silently.
    case tileInconsistent(UInt32, metaEpoch: UInt64, bodyEpoch: UInt64)
    /// §6.1's depth cap: BFS/ancestry beyond depth 12 is the wrong
    /// primitive (use rank-range SELECT instead) — refused, not silently
    /// truncated.
    case depthCapExceeded(UInt32)
    /// Ticking gates W3: a source tile's lower strip (the parity file a
    /// reader tile's ghosts are staged from) carries an epoch other than
    /// the one this world tick expects. The world-tick loop attempts
    /// regeneration from the source's COMMITTED body before surfacing
    /// this — see `TiledGraphRouter.regenerateStaleLowerStrip` — so this
    /// case reaching a caller means regeneration itself refused (the
    /// source's own committed body is behind the expected epoch too).
    case haloStale(UInt32, expected: UInt64, found: UInt64)
    /// Ticking gates W4: `<tile>/flush.wal` ends in a `TILE_FLUSH_BEGIN`
    /// with no matching `TILE_FLUSH_COMMIT` — the flush that was writing
    /// `epoch` crashed mid-way. `bodyEpoch` is what `body.dags` itself
    /// currently reports (`k − 1` = crash before the atomic rename, `k` =
    /// crash after it but before the strip/meta/commit). A writer-role
    /// `init` recovers this automatically; a reader-role `init` never
    /// sees it directly (a dangling BEGIN always implies a torn world,
    /// caught first as `worldTorn`).
    case tileFlushIncomplete(UInt32, epoch: UInt64, bodyEpoch: UInt64)
    /// Ticking gates AMENDMENT 3, letter 1: the router's tiles disagree
    /// on epoch (a between-tiles crash, or a reader opened before a
    /// writer completed the round) — a mixed-epoch world must never
    /// answer a query. Readers refuse to open over this; writers refuse
    /// `worldTick` over it (defensive — a writer's own `init` always
    /// closes the gap first).
    case worldTorn(min: UInt64, max: UInt64)
    /// Ticking gates AMENDMENT 3, letter 2: completing a partial round
    /// needs the mode the round now at the target epoch was run in —
    /// read from the last committed `TILE_FLUSH_BEGIN` of every tile
    /// already at that epoch. Two different modes among those tiles is
    /// not a legitimate partial round (a single-router world can't have
    /// two rounds of different modes both land at the same max epoch) —
    /// it means the directory was touched by hand. `tiles` maps each
    /// disagreeing tile id to the mode token its own record carries.
    case partialRoundModeMismatch([UInt32: String])
    /// Audit C findings 4, 5 and 12 (contract ruling "Tile files: three
    /// counts, one truth"): `manifest.json`'s entry node count,
    /// `meta.json`'s and `body.dags`'s own header field must agree. They
    /// were three independent file-derived numbers, none compared: the
    /// engine was sized from the manifest's (an `Int(UInt64)` that TRAPPED
    /// above `Int.max`, and below it an arbitrarily large Metal
    /// allocation), while `ResidentTile.nodeCount` and every buffer bound
    /// from it came from meta.json's. `body` is nil when the refusal fired
    /// before the body header was read.
    case tileNodeCountInconsistent(UInt32, manifest: UInt64, meta: UInt64, body: UInt64?,
                                   detail: String)
    /// Audit C finding 12: a manifest entry whose `engineIndexOf` is short,
    /// or names an index at or past `globalNodeCount` — `truthArray()`
    /// indexed a `globalNodeCount`-sized array with it, and the memberwise
    /// init defaults the field to `[]`, so a hand-built entry trapped at
    /// local 0. Validated at router init, before any tile is touched.
    case engineIndexInvalid(UInt32, detail: String)
    /// Audit C finding 15: `maxResidentTiles` was an unguarded `Int` —
    /// both load paths evict exactly one tile before inserting one, so at
    /// K <= 0 the resident set grew past K instead of holding to it.
    case residencyBudgetInvalid(Int)
    /// Audit C finding 17: `worldTick(mode:count:)` looped `0..<count` on
    /// an unguarded public `Int` and TRAPPED on a negative count.
    case tickCountNegative(Int)
    /// Audit C finding 9 (contract ruling "Epochs"): `body.dags`'s tick
    /// field is 32 bits wide, and both the tick call and the save
    /// truncated a UInt64 epoch into it silently. Past 2^32 the body-vs-
    /// meta equality check would then refuse every subsequent load of the
    /// whole world. Refused at flush instead. Widening that header field
    /// is recorded as a core-format letter for a later window.
    case tileEpochUnrepresentable(UInt32, epoch: UInt64, limit: UInt64)
    /// Audit C findings 10 and 11: `<tile>/flush.wal`'s last record is
    /// neither a well-formed COMMIT nor a well-formed BEGIN — a torn
    /// append, an unknown verb, or a BEGIN at epoch 0. It used to read as
    /// "clean" and the tile loaded.
    case tileFlushMalformed(UInt32, detail: String)

    public var description: String {
        switch self {
        case .tileNodeCountInconsistent(let id, let m, let mt, let b, let detail):
            let bodyText = b.map { "\($0)" } ?? "unread"
            return "TiledGraphRouter: tile \(id) node count is inconsistent — manifest \(m), "
                + "meta \(mt), body \(bodyText): \(detail)"
        case .engineIndexInvalid(let id, let detail):
            return "TiledGraphRouter: tile \(id)'s engineIndexOf is unusable: \(detail)"
        case .residencyBudgetInvalid(let k):
            return "TiledGraphRouter: maxResidentTiles \(k) must be >= 1"
        case .tickCountNegative(let c):
            return "TiledGraphRouter: worldTick count \(c) must be >= 0"
        case .tileEpochUnrepresentable(let id, let epoch, let limit):
            return "TiledGraphRouter: tile \(id) epoch \(epoch) does not fit body.dags's 32-bit "
                + "tick field (limit \(limit))"
        case .tileFlushMalformed(let id, let detail):
            return "TiledGraphRouter: tile \(id) flush.wal is malformed: \(detail)"
        case .notImplemented(let what):
            return "TiledGraphRouter: \(what) not yet implemented (scaffold)"
        case .tileNotResident(let id):
            return "TiledGraphRouter: tile \(id) not resident; load it first"
        case .crossTileBoundsExceeded(let id):
            return "TiledGraphRouter: tile \(id) outside tile-id space"
        case .manifestMissing(let path):
            return "TiledGraphRouter: tile manifest not found at '\(path)'"
        case .tileHashMismatch(let id, let expected, let actual):
            return "TiledGraphRouter: tile \(id) body.dags sha256 mismatch — expected \(expected) got \(actual); refusing load"
        case .tileInconsistent(let id, let metaEpoch, let bodyEpoch):
            return "TiledGraphRouter: tile \(id) epoch mismatch — meta.json says \(metaEpoch), body says \(bodyEpoch); refusing load"
        case .depthCapExceeded(let d):
            return "TiledGraphRouter: depth \(d) exceeds the cap of 12 — use rank-range SELECT instead"
        case .haloStale(let id, let expected, let found):
            return "TiledGraphRouter: tile \(id) lower strip stale — expected epoch \(expected), found \(found); refusing"
        case .tileFlushIncomplete(let id, let epoch, let bodyEpoch):
            return "TiledGraphRouter: tile \(id) flush incomplete at epoch \(epoch) (body at \(bodyEpoch)) — writer init recovers this"
        case .worldTorn(let mn, let mx):
            return "TiledGraphRouter: world torn — tiles span epochs \(mn)..\(mx); a reader refuses, a writer must recover/complete first"
        case .partialRoundModeMismatch(let tiles):
            let desc = tiles.sorted { $0.key < $1.key }.map { "tile \($0.key)=\($0.value)" }.joined(separator: ", ")
            return "TiledGraphRouter: partial-round mode mismatch among tiles at max epoch: \(desc)"
        }
    }
}

// MARK: - Router

public actor TiledGraphRouter {

    /// Cross-tile BFS/ancestry depth cap (§6.1: "cap `maxDepth` at 12").
    public static let maxDepth: UInt32 = 12

    // MARK: stored state

    public let dataRoot: String
    public let graphName: String
    public let maxResidentTiles: Int
    public let role: RouterRole
    public private(set) var manifest: TiledGraphFiles.Manifest
    /// What `init` did — see `OpenReport`'s doc comment. Set once, at the
    /// end of construction (`private(set)` rather than `let` only
    /// because it must start as a placeholder before the writer-role
    /// recovery/completion passes run — those are isolated methods that
    /// need every stored property definitely assigned first).
    public private(set) var openReport: OpenReport

    private var residentTiles: [UInt32: ResidentTile] = [:]
    /// Least-recently-used at the front, most-recently-used at the back.
    private var lruOrder: [UInt32] = []
    private var totalTickCount: UInt64 = 0

    // MARK: ticking-path resident set (independent of the query path above)

    private var tickResident: [UInt32: TickResidentTile] = [:]
    private var tickLru: [UInt32] = []
    /// Ticking gates AMENDMENT 2, letter 2: no router-global tick counter
    /// — each tile's own last-flushed epoch (`TileEntry.tickEpoch`,
    /// refreshed atomically by every flush), cached here at `init` and
    /// updated in lockstep with the manifest thereafter. The router's own
    /// notion of "the world's epoch" is the (min, max) over this map —
    /// see `status()`.
    private var tileEpoch: [UInt32: UInt64]
    /// Tiles whose `flush.wal` ended in an unmatched `TILE_FLUSH_BEGIN`
    /// at `init` time — `(epoch, mode)` is the interrupted flush's target
    /// epoch and the mode it was running in (the WAL record's third
    /// field). Consumed and cleared by a writer's `init`-time recovery
    /// pass; a reader never touches this (a dangling BEGIN always shows
    /// up as a torn (min, max) too, refused before recovery would matter).
    private var pendingRecoveryTiles: [UInt32: (epoch: UInt64, mode: TickMode)] = [:]

    /// AMENDMENT 7, finding A: `tile id -> (local id -> PRE-latch truth)`
    /// for the registers of every tile ticked so far in the CURRENT
    /// rank-mode round. The strip a tile flushes carries these bytes, but a
    /// reader at K >= 2 can find its source still resident and read the
    /// live buffer instead — which holds the POST-latch value. Both paths
    /// must answer the same thing, so the resident fast path consults this
    /// map first. Cleared at the start of every round.
    private var roundRegisterPreLatch: [UInt32: [UInt64: UInt8]] = [:]

    /// TEST-ONLY (ticking gates W7b, AMENDMENT 6 letter 4) — never a
    /// production path. With this set, rank mode sources its ghosts the
    /// way sync mode does: from the source tile's COMMITTED strip at epoch
    /// `k − 1`, never from the value the source computed earlier in this
    /// same world tick. That is exactly the contract's definition of
    /// "ghosts deleted" in rank mode ("the reader tile evaluates with its
    /// ghost inputs held at their values from the PREVIOUS world tick"),
    /// so a run with it on must equal the reference's `stale` vector and a
    /// run with it off must equal `fresh`. Default `false`.
    private(set) var ghostPopulationDisabled = false

    /// TEST-ONLY (ticking gates W7a) — a map from a source node's
    /// `GlobalNodeID.raw` to the truth byte every reader tile must see for
    /// it, applied after the ordinary strip/resident read. This is the
    /// perturbation "one committed strip entry forced to the flipped bit"
    /// delivered at the point the reader consumes it. In SYNC mode the
    /// equivalent edit can be (and in W7a is) made on the committed file
    /// itself, because sync reads the `k − 1` parity strip, which the
    /// round does not rewrite; in RANK mode the source tile re-flushes its
    /// own epoch-`k` strip earlier in the same round, so a pre-tick file
    /// edit is provably overwritten before any reader sees it. Empty by
    /// default.
    private(set) var ghostForced: [UInt64: UInt8] = [:]

    func setGhostPopulationDisabled(_ disabled: Bool) { ghostPopulationDisabled = disabled }
    func setGhostForced(_ forced: [UInt64: UInt8]) { ghostForced = forced }

    /// For each tile, the list of (foreign tile, foreign local) →
    /// this tile's local node it points at — built once at init from
    /// every tile's own `crossingsIn` entry in the manifest (which
    /// `TiledGraphFiles.write` already assembled from every OTHER tile's
    /// `crossingsOut` in a single pass — see that file's "Pass 1" comment).
    private let crossingsInByTile: [UInt32: [Crossing]]

    // T3/T4 bookkeeping
    private var loadCount = 0
    private var evictCount = 0
    private var refusals: [(UInt32, String)] = []
    private var maxResidentSeenCount = 0

    // MARK: init

    /// Construct a router rooted at `<dataRoot>/<graphName>/`, reading its
    /// `manifest.json` up front (`RouterError.manifestMissing` if absent —
    /// a directory on disk IS the router's state; there's nothing to
    /// route without it). Does NOT load any tiles yet.
    ///
    /// Ticking gates AMENDMENT 3, letter 1 — the role decides what
    /// happens next: a **writer** (the default, and the daemon's `TILED
    /// OPEN`) recovers any dangling `TILE_FLUSH_BEGIN` first, then
    /// completes a partial round if the tiles still disagree on epoch, so
    /// its world is never torn when it starts answering queries or
    /// ticking. A **reader** never recovers or ticks — it refuses to open
    /// at all over a torn world (`RouterError.worldTorn`).
    public init(
        dataRoot: String, graphName: String, maxResidentTiles: Int = 2, role: RouterRole = .writer
    ) async throws {
        // Audit C finding 15: both load paths evict exactly one tile
        // before inserting one, so at K <= 0 the resident set grows past K
        // rather than holding to it. Refused at the door.
        guard maxResidentTiles >= 1 else {
            throw RouterError.residencyBudgetInvalid(maxResidentTiles)
        }
        self.dataRoot = dataRoot
        self.graphName = graphName
        self.maxResidentTiles = maxResidentTiles
        self.role = role
        var manifest: TiledGraphFiles.Manifest
        do {
            manifest = try TiledGraphFiles.readManifest(dataRoot: dataRoot, name: graphName)
        } catch TiledGraphFiles.FilesError.manifestMissing(let path) {
            throw RouterError.manifestMissing(path)
        }
        self.manifest = manifest

        // Audit C finding 12: `truthArray()` sizes its result
        // `globalNodeCount` and indexes it by `entry.engineIndexOf[li]`,
        // both straight out of manifest.json and neither bound-checked —
        // and the memberwise init defaults `engineIndexOf` to `[]`, so a
        // hand-built entry trapped at local 0. Validated once, here,
        // before any tile is touched.
        for entry in manifest.tiles {
            guard UInt64(entry.engineIndexOf.count) == entry.nodeCount else {
                throw RouterError.engineIndexInvalid(
                    entry.id,
                    detail: "it holds \(entry.engineIndexOf.count) entr(ies) for a tile of "
                        + "\(entry.nodeCount) node(s)")
            }
            if let bad = entry.engineIndexOf.first(where: { $0 >= manifest.globalNodeCount }) {
                throw RouterError.engineIndexInvalid(
                    entry.id,
                    detail: "it names untiled engine index \(bad), at or past the graph's own "
                        + "globalNodeCount \(manifest.globalNodeCount)")
            }
        }

        var cin: [UInt32: [Crossing]] = [:]
        for entry in manifest.tiles {
            cin[entry.id] = entry.crossingsIn
        }
        self.crossingsInByTile = cin

        var epochs: [UInt32: UInt64] = [:]
        for entry in manifest.tiles { epochs[entry.id] = entry.tickEpoch }
        self.tileEpoch = epochs

        // Audit C finding 11: a torn `flush.wal` (a half-written final
        // record, an unknown verb, a three-field BEGIN predating the mode
        // field, or a BEGIN at epoch 0) used to read as CLEAN here and the
        // tile loaded. It is not recoverable — the epoch the interrupted
        // flush was writing is exactly what the torn record failed to
        // record — so the router refuses to open over it by name.
        var pending: [UInt32: (epoch: UInt64, mode: TickMode)] = [:]
        for entry in manifest.tiles {
            let dir = TiledGraphFiles.tileDirectory(dataRoot: dataRoot, name: graphName, entry: entry)
            switch TiledGraphFiles.flushState(dir: dir) {
            case .clean: break
            case .pending(let epoch, let mode): pending[entry.id] = (epoch, mode)
            case .torn(let detail):
                throw RouterError.tileFlushMalformed(entry.id, detail: detail)
            }
        }
        self.pendingRecoveryTiles = pending

        // Placeholder so every stored property is definitely assigned
        // before the writer branch calls its own isolated methods below
        // (Swift requires that before `self` may be used that way, even
        // from within its own `init`); overwritten with the real counts
        // immediately after.
        self.openReport = OpenReport(recovered: 0, completed: 0)

        switch role {
        case .reader:
            let mn = epochs.values.min() ?? 0
            let mx = epochs.values.max() ?? 0
            guard mn == mx else { throw RouterError.worldTorn(min: mn, max: mx) }

        case .writer:
            let recovered = try recoverDanglingFlushes()
            let completed = try completePartialRoundIfTorn()
            self.openReport = OpenReport(recovered: recovered, completed: completed)
        }
    }

    // MARK: public surface

    public func status() -> TiledStatus {
        TiledStatus(
            dataRoot: dataRoot,
            graphName: graphName,
            // Audit C finding 16: `residentTiles` is the QUERY path's set;
            // the ticker holds its own (`tickResident`) against the same
            // budget, and a router mid-tick used to report zero residency.
            residentTileCount: residentTiles.count + tickResident.count,
            maxResidentTiles: maxResidentTiles,
            totalTickCount: totalTickCount,
            loads: loadCount,
            evicts: evictCount,
            refused: refusals.count,
            lastRefusal: refusals.last.map { "tile \($0.0): \($0.1)" },
            maxResidentSeen: maxResidentSeenCount,
            epochMin: tileEpoch.values.min() ?? 0,
            epochMax: tileEpoch.values.max() ?? 0
        )
    }

    /// Persist all dirty tiles to disk. Stub — out of this contract's
    /// scope (routers are not persisted; a directory on disk is the
    /// state — see T5's ruling).
    public func save() async throws {
        throw RouterError.notImplemented("save")
    }

    /// Drain readers, flush dirty tiles, release engines. Stub — out of
    /// scope for the same reason as `save`.
    public func close() async throws {
        throw RouterError.notImplemented("close")
    }

    /// Route an arbitrary DSL command to the right tile. Out of scope —
    /// the gate contract only requires the three typed verbs below
    /// (`runBFS`, `runAncestry`, `runSelect`); no verb-dispatch table.
    public func runQuery(_ dsl: String) async throws -> String {
        throw RouterError.notImplemented("runQuery: \(dsl.prefix(40))…")
    }

    /// Cross-tile BFS, level-synchronous across tiles (T2). `backward:
    /// false` is UNDIRECTED — matches `DagDBBFS.bfsDepthsUndirected`'s
    /// letter: it walks both a node's own neighbour slots (its sources)
    /// AND its fan-out (nodes that reference it), and it INCLUDES the
    /// seed at depth 0 (mirroring that function's return shape, which
    /// seeds `depths[seed] = 0` and never excludes it). `backward: true`
    /// follows sources only, matching `bfsDepthsBackward`.
    public func runBFS(
        seed: GlobalNodeID, depth: UInt32, backward: Bool = false
    ) async throws -> [(GlobalNodeID, UInt32)] {
        guard depth <= Self.maxDepth else { throw RouterError.depthCapExceeded(depth) }

        var visited: [UInt64: UInt32] = [seed.raw: 0]
        var frontier: [GlobalNodeID] = [seed]
        var d: UInt32 = 0

        while d < depth && !frontier.isEmpty {
            var byTile: [UInt32: [UInt64]] = [:]
            for g in frontier { byTile[g.tileId, default: []].append(g.localNodeId) }

            var nextFrontier: [GlobalNodeID] = []
            for tileId in byTile.keys.sorted() {
                let tile = try load(tileId: tileId)
                for localId in byTile[tileId] ?? [] {
                    let neighbors = try backward
                        ? sourcesOf(tile: tile, localId: localId)
                        : undirectedNeighborsOf(tile: tile, localId: localId)
                    for n in neighbors where visited[n.raw] == nil {
                        visited[n.raw] = d + 1
                        nextFrontier.append(n)
                    }
                }
            }
            frontier = nextFrontier
            d += 1
        }

        return visited.map { (GlobalNodeID(raw: $0.key), $0.value) }
    }

    /// Reverse BFS bounded by depth — `runBFS(backward: true)` semantics,
    /// matching `DagDBBFS.bfsDepthsBackward`.
    public func runAncestry(node: GlobalNodeID, depth: UInt32) async throws -> [(GlobalNodeID, UInt32)] {
        try await runBFS(seed: node, depth: depth, backward: true)
    }

    /// Truth-by-rank-range select (T2c). Every tile whose rank span could
    /// overlap `[rankLo, rankHi]` is loaded and queried; the per-tile
    /// overlap test is a loose (superset-safe) check against the
    /// manifest's own half-open-ish `rankLo`/`rankHi` bookkeeping (see
    /// `TiledGraphFiles.write`'s `rankHiOf` comment: exclusive except on
    /// the last tile) — over-inclusion only costs a load that returns no
    /// rows; under-inclusion would be a correctness bug, so the check
    /// never narrows past what the true per-node ranks could satisfy.
    public func runSelect(truth: UInt8, rankLo: UInt64, rankHi: UInt64) async throws -> [GlobalNodeID] {
        guard rankLo <= rankHi else { return [] }
        var result: [GlobalNodeID] = []
        for entry in manifest.tiles.sorted(by: { $0.id < $1.id }) {
            guard rankLo <= entry.rankHi && entry.rankLo <= rankHi else { continue }
            let tile = try load(tileId: entry.id)
            let index = TruthRankIndex()
            let locals = index.select(
                truth: truth, rankLo: rankLo, rankHi: rankHi,
                engine: tile.engine, nodeCount: tile.nodeCount
            )
            for l in locals {
                result.append(try GlobalNodeID(tileId: entry.id, localNodeId: UInt64(l)))
            }
        }
        return result.sorted { $0.raw < $1.raw }
    }

    // MARK: - Ticking (TICKING_GATES_FROZEN.md)

    /// Every tile's `(metaEpoch, bodyEpoch)` read fresh off disk — the
    /// W1/W2 tests' per-world-tick invariant check, and a general
    /// diagnostic. Does not touch tick residency.
    public func tileEpochs() throws -> [UInt32: (metaEpoch: UInt64, bodyEpoch: UInt64)] {
        var result: [UInt32: (metaEpoch: UInt64, bodyEpoch: UInt64)] = [:]
        for entry in manifest.tiles {
            result[entry.id] = try TiledGraphFiles.peekTileEpochs(
                dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: entry.id
            )
        }
        return result
    }

    /// Every REAL node's current truth, in the untiled engine's own index
    /// order (via each tile's `engineIndexOf`). Ghost nodes are never
    /// included — they are inputs, not state (the contract's W1 letter).
    public func truthArray() async throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: Int(manifest.globalNodeCount))
        for entry in manifest.tiles.sorted(by: { $0.id < $1.id }) {
            let tile = try tickLoad(tileId: entry.id)
            let ptr = tile.engine.truthStateBuf.contents().bindMemory(
                to: UInt8.self, capacity: tile.realNodeCount + tile.ghostCount)
            for li in 0..<tile.realNodeCount {
                result[Int(entry.engineIndexOf[li])] = ptr[li]
            }
        }
        return result
    }

    /// One node's current truth.
    public func truth(of id: GlobalNodeID) async throws -> UInt8 {
        let tile = try tickLoad(tileId: id.tileId)
        guard id.localNodeId < UInt64(tile.realNodeCount) else {
            throw RouterError.crossTileBoundsExceeded(id.tileId)
        }
        let ptr = tile.engine.truthStateBuf.contents().bindMemory(
            to: UInt8.self, capacity: tile.realNodeCount + tile.ghostCount)
        return ptr[Int(id.localNodeId)]
    }

    /// Advance the world `count` ticks in `mode`. Every tile is ticked
    /// and flushed every world tick (rank mode: tile ids DESCENDING —
    /// highest rank range first, so a tile's cross-tile sources, always a
    /// higher-numbered tile per the rank-ascending tile-numbering
    /// invariant, have already been ticked this same world tick; sync
    /// mode: ascending, order doesn't matter — every ghost comes from the
    /// PREVIOUS world tick's committed strip regardless of processing
    /// order). See the contract's mechanism letter for the ghost-sourcing
    /// rule this implements. Defensively refuses `RouterError.worldTorn`
    /// if the tiles don't already agree on epoch (AMENDMENT 3: a
    /// writer's own `init` always closes that gap first, and every
    /// `worldTick` call leaves them agreeing again — this should never
    /// actually fire in ordinary use).
    public func worldTick(mode: TickMode, count: Int) async throws -> WorldTickReport {
        // Audit C finding 17: `for _ in 0..<count` TRAPPED on a negative
        // count, on a public entry point taking an unguarded Int.
        guard count >= 0 else { throw RouterError.tickCountNegative(count) }
        let mn = tileEpoch.values.min() ?? 0
        let mx = tileEpoch.values.max() ?? 0
        guard mn == mx else { throw RouterError.worldTorn(min: mn, max: mx) }

        var tilesTicked = 0
        var flushes = 0
        var haloBytes = 0
        var maxTickMs = 0.0
        var maxFlushMs = 0.0
        let loadsStart = loadCount
        let evictsStart = evictCount
        var lastEpoch = mx

        let descending = manifest.tiles.map { $0.id }.sorted(by: >)
        let ascending = manifest.tiles.map { $0.id }.sorted(by: <)
        let order = (mode == .rank) ? descending : ascending

        for _ in 0..<count {
            let k = lastEpoch + 1
            var tickedThisRound: Set<UInt32> = []
            roundRegisterPreLatch.removeAll(keepingCapacity: true)

            for t in order {
                let (hb, fms, tms) = try tickAndFlushOneTile(
                    tileId: t, k: k, mode: mode, tickedThisRound: &tickedThisRound
                )
                haloBytes += hb
                maxFlushMs = max(maxFlushMs, fms)
                maxTickMs = max(maxTickMs, tms)
                tilesTicked += 1
                flushes += 1
            }

            lastEpoch = k
        }

        return WorldTickReport(
            epoch: lastEpoch, tilesTicked: tilesTicked,
            loads: loadCount - loadsStart, evicts: evictCount - evictsStart,
            flushes: flushes, haloBytes: haloBytes,
            tickMsPerTile: maxTickMs, flushMsPerTile: maxFlushMs
        )
    }

    /// One tile's ghost-source, tick, and flush at world epoch `k` —
    /// shared by `worldTick`'s ordinary full-round loop and
    /// `completePartialRoundIfTorn`'s catch-up loop (the SAME mechanism,
    /// just a different set of tiles and a different starting point).
    private func tickAndFlushOneTile(
        tileId t: UInt32, k: UInt64, mode: TickMode, tickedThisRound: inout Set<UInt32>
    ) throws -> (haloBytes: Int, flushMs: Double, tickMs: Double) {
        let tile = try tickLoad(tileId: t)

        let n = tile.realNodeCount
        let ptr = tile.engine.truthStateBuf.contents().bindMemory(
            to: UInt8.self, capacity: n + tile.ghostCount)
        for (g, src) in tile.ghostSources.enumerated() {
            let raw = try GlobalNodeID(tileId: src.tile, localNodeId: src.local).raw
            if let forced = ghostForced[raw] {
                ptr[n + g] = forced
                continue
            }
            ptr[n + g] = try ghostTruth(
                readerTileId: t, sourceTile: src.tile, sourceLocal: src.local,
                k: k, mode: mode, tickedThisRound: tickedThisRound
            )
        }

        // AMENDMENT 7, finding A + AMENDMENT 8: a register's PRE-latch
        // byte, read before the tick, is what a rank-mode reader in a lower
        // tile must see in this round's strip. The kernel never writes a
        // register, so "before the tick" and "before the latch" are the
        // same bytes. Recorded in BOTH modes now: the strip carries both
        // bytes, so whichever mode wrote the file, a sync-mode reader one
        // world tick later still finds the post-latch vector it wants.
        let preLatch = registerPreLatchBytes(tile: tile)
        roundRegisterPreLatch[t] = preLatch

        // Finding 9: the same 32-bit ceiling applies to the tick number
        // the kernel is given — refused before the truncation, not after.
        guard k <= UInt64(UInt32.max) else {
            throw RouterError.tileEpochUnrepresentable(t, epoch: k, limit: UInt64(UInt32.max))
        }
        let t0 = Date()
        switch mode {
        case .rank: tile.engine.tick(tickNumber: UInt32(truncatingIfNeeded: k))
        case .sync: tile.engine.tickSync(tickNumber: UInt32(truncatingIfNeeded: k))
        }
        let tickMs = Date().timeIntervalSince(t0) * 1000.0
        tickedThisRound.insert(t)

        let (flushMs, haloBytes) = try flushTile(
            tile: tile, epoch: k, mode: mode, registerPreLatch: preLatch)
        return (haloBytes, flushMs, tickMs)
    }

    /// `local id -> truth byte` for every register in `tile`, read off the
    /// engine as it stands. Called before the tick, so the bytes are the
    /// registers' pre-latch values (AMENDMENT 7, finding A; AMENDMENT 8
    /// makes them `truthPre` in the strip, in both modes).
    private func registerPreLatchBytes(tile: TickResidentTile) -> [UInt64: UInt8] {
        guard !tile.engine.backEdgeDsts.isEmpty else { return [:] }
        let ptr = tile.engine.truthStateBuf.contents().bindMemory(
            to: UInt8.self, capacity: tile.realNodeCount + tile.ghostCount)
        var result: [UInt64: UInt8] = [:]
        for dst in tile.engine.backEdgeDsts where Int(dst) < tile.realNodeCount {
            result[UInt64(dst)] = ptr[Int(dst)]
        }
        return result
    }

    /// `local id -> truthPre` for every REGISTER local that a rebuilt strip
    /// must carry — AMENDMENT 8, the regeneration half of the letter.
    ///
    /// The two repair paths (recovery case (ii), and `regenerateStale-
    /// LowerStrip`) rebuild a strip at epoch `k` from a COMMITTED BODY at
    /// `k`. That body yields `truthPost` for every entry directly, and
    /// `truthPre` for every combinational entry too (the two are equal by
    /// construction). A register's `truthPre` at `k` is the value it held
    /// before that round's latch — its value at the END of `k − 1`, which a
    /// body at `k` no longer holds. It is exactly that same source's
    /// `truthPost` in the PREVIOUS-parity strip, which the ping-pong keeps
    /// alive. At `k == 0` there was no earlier round and both bytes are the
    /// saved truth, so nothing is overridden. If a register entry needs the
    /// previous strip and it is missing or itself behind, this refuses by
    /// name rather than writing a byte it cannot justify.
    private func registerPreLatchFromPreviousStrip(
        tileId: UInt32, engine: DagDBEngine, realNodeCount: Int, epoch: UInt64
    ) throws -> [UInt64: UInt8] {
        guard epoch > 0, !engine.backEdgeDsts.isEmpty else { return [:] }
        guard let entry = manifest.tiles.first(where: { $0.id == tileId }) else {
            throw RouterError.manifestMissing("tile \(tileId)")
        }
        let stripLocals = Set(entry.crossingsIn.map { $0.localNode })
        let registerLocals = engine.backEdgeDsts
            .filter { Int($0) < realNodeCount && stripLocals.contains(UInt64($0)) }
            .map { UInt64($0) }
        guard !registerLocals.isEmpty else { return [:] }

        let previous = epoch - 1
        let read = try? TiledGraphFiles.readLowerStrip(
            dataRoot: dataRoot, name: graphName, manifest: manifest,
            tileId: tileId, parity: previous % 2
        )
        guard let read, read.epoch == previous else {
            throw RouterError.haloStale(tileId, expected: previous, found: read?.epoch ?? 0)
        }
        var result: [UInt64: UInt8] = [:]
        for local in registerLocals {
            guard let v = read.values[local] else {
                throw RouterError.haloStale(tileId, expected: previous, found: read.epoch)
            }
            result[local] = v.post
        }
        return result
    }

    /// Fix every tile recorded in `pendingRecoveryTiles` — writer-role
    /// `init` only (AMENDMENT 3: `recover` is no longer public; a reader
    /// never calls this). Case (i) — body behind the interrupted flush's
    /// epoch (crash before the atomic rename) — re-ticks with the SAME
    /// ghost inputs the interrupted tick used (mode read off the WAL
    /// record itself, not a caller-supplied parameter), then completes
    /// the flush (manifest entry included, one authority). Case (ii) —
    /// body already at the interrupted epoch (crash after the rename,
    /// before strip/meta/commit) — regenerates the strip, meta and
    /// manifest entry from the committed body and commits; no re-tick.
    /// Returns the count fixed (`OpenReport.recovered`).
    private func recoverDanglingFlushes() throws -> Int {
        var count = 0

        for tileId in pendingRecoveryTiles.keys.sorted() {
            guard let pending = pendingRecoveryTiles[tileId] else { continue }
            let beginEpoch = pending.epoch
            let mode = pending.mode
            let (_, bodyEpoch) = try TiledGraphFiles.peekTileEpochs(
                dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: tileId
            )

            // Finding 10: `beginEpoch - 1` on UInt64 underflowed for a
            // hand-written `TILE_FLUSH_BEGIN … 0 …`. `flushState` now
            // classifies a BEGIN at epoch 0 as TORN rather than pending, so
            // it can no longer reach here; this is the belt that makes the
            // subtraction total whatever a future caller populates
            // `pendingRecoveryTiles` with.
            guard beginEpoch >= 1 else {
                throw RouterError.tileFlushMalformed(
                    tileId,
                    detail: "flush.wal's dangling BEGIN records epoch 0; every flush writes an "
                        + "epoch >= 1, and recovery's own epoch - 1 has no value at 0")
            }
            if bodyEpoch == beginEpoch - 1 {
                // Case (i): re-tick with the interrupted tick's own ghost inputs.
                let loaded = try TiledGraphFiles.loadTileWithGhosts(
                    dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: tileId,
                    ignorePendingFlush: true
                )
                let tile = TickResidentTile(
                    id: tileId, engine: loaded.engine, meta: loaded.meta,
                    realNodeCount: loaded.realNodeCount, ghostCount: loaded.ghostCount,
                    ghostSources: loaded.ghostSources
                )
                let k = beginEpoch
                let n = tile.realNodeCount
                let ptr = tile.engine.truthStateBuf.contents().bindMemory(
                    to: UInt8.self, capacity: n + tile.ghostCount)
                for (g, src) in tile.ghostSources.enumerated() {
                    let expected: UInt64 = (mode == .rank) ? k : k - 1
                    let (epoch, values) = try TiledGraphFiles.readLowerStrip(
                        dataRoot: dataRoot, name: graphName, manifest: manifest,
                        tileId: src.tile, parity: expected % 2
                    )
                    guard epoch == expected, let v = values[src.local] else {
                        throw RouterError.haloStale(src.tile, expected: expected, found: epoch)
                    }
                    // AMENDMENT 8: the interrupted tick's own byte — rank
                    // took `truthPre` from the `k` strip, sync `truthPost`
                    // from the `k − 1` one.
                    ptr[n + g] = (mode == .rank) ? v.pre : v.post
                }
                let preLatch = registerPreLatchBytes(tile: tile)
                switch mode {
                case .rank: tile.engine.tick(tickNumber: UInt32(truncatingIfNeeded: k))
                case .sync: tile.engine.tickSync(tickNumber: UInt32(truncatingIfNeeded: k))
                }
                _ = try flushTile(tile: tile, epoch: k, mode: mode, registerPreLatch: preLatch)
                // Recovery re-establishes this tile in the tick-resident
                // set so a following worldTick sees the recovered state
                // without a redundant reload.
                if tickResident.count >= maxResidentTiles { evictTickLRU() }
                tickResident[tileId] = tile
                touchTick(tileId)
            } else if bodyEpoch == beginEpoch {
                // Case (ii): body already correct — regenerate strip + meta + manifest, commit.
                //
                // AMENDMENT 8: BOTH truth bytes are reconstructed.
                // `truthPost` comes straight off the committed body at k;
                // `truthPre` is the same for every combinational entry and,
                // for a register, its own `truthPost` in the
                // previous-parity strip (its value at k − 1 is its
                // pre-latch value at k). AMENDMENT 7 left this path writing
                // the post-latch byte for registers and called the gap
                // out-of-reach for a rank-mode reader; it is not — a
                // rank-mode partial-round completion at k reads exactly
                // this regenerated strip.
                let loaded = try TiledGraphFiles.loadTileWithGhosts(
                    dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: tileId,
                    ignorePendingFlush: true
                )
                let k = beginEpoch
                let preLatch = try registerPreLatchFromPreviousStrip(
                    tileId: tileId, engine: loaded.engine,
                    realNodeCount: loaded.realNodeCount, epoch: k
                )
                _ = try TiledGraphFiles.writeLowerStrip(
                    dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: tileId,
                    engine: loaded.engine, realNodeCount: loaded.realNodeCount, epoch: k,
                    preLatchOverrides: preLatch
                )
                var meta = loaded.meta
                meta.lastPersistedTickEpoch = k
                try TiledGraphFiles.writeMeta(
                    dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: tileId, meta: meta
                )
                let dir = try tileDir(tileId)
                let bodyData = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/body.dags"))
                let bodyHash = DagDBSnapshot.sha256Hex(bodyData)
                try refreshManifestEntry(tileId: tileId, bodySHA256: bodyHash, tickEpoch: k)
                try TiledGraphFiles.appendFlushWAL(
                    path: "\(dir)/flush.wal",
                    record: "TILE_FLUSH_COMMIT \(tileId) \(k)"
                )
            } else {
                throw RouterError.tileInconsistent(tileId, metaEpoch: beginEpoch, bodyEpoch: bodyEpoch)
            }

            pendingRecoveryTiles.removeValue(forKey: tileId)
            count += 1
        }

        return count
    }

    /// Completes a partial round left by a between-tiles interruption
    /// (every `flush.wal` clean, entries mixed — AMENDMENT 2's
    /// consequence, refined by AMENDMENT 3): ticks only the tiles below
    /// the max epoch, in the round's own mode's order, AT the max epoch,
    /// with that round's own inputs (rank: sources' strips at max; sync:
    /// sources' strips at max − 1), refusing `haloStale` otherwise. The
    /// round's mode comes from the tiles already AT max — their own last
    /// committed `TILE_FLUSH_BEGIN` record (never a caller-supplied
    /// mode, AMENDMENT 3 letter 2); disagreement among them refuses
    /// `partialRoundModeMismatch` with nothing rewritten. A no-op
    /// (returns 0) when every tile already agrees. Returns the count
    /// ticked (`OpenReport.completed`).
    private func completePartialRoundIfTorn() throws -> Int {
        let mn = tileEpoch.values.min() ?? 0
        let mx = tileEpoch.values.max() ?? 0
        guard mn < mx else { return 0 }

        var modesAtMax: [UInt32: String] = [:]
        for (tileId, ep) in tileEpoch where ep == mx {
            guard let dir = try? tileDir(tileId),
                  let token = TiledGraphFiles.lastCommittedBeginMode(dir: dir, epoch: mx) else { continue }
            modesAtMax[tileId] = token
        }
        let distinctModes = Set(modesAtMax.values)
        guard distinctModes.count <= 1 else {
            throw RouterError.partialRoundModeMismatch(modesAtMax)
        }
        guard let token = distinctModes.first, let mode = TickMode(walToken: token) else {
            throw RouterError.worldTorn(min: mn, max: mx)
        }

        let descending = manifest.tiles.map { $0.id }.sorted(by: >)
        let ascending = manifest.tiles.map { $0.id }.sorted(by: <)
        let order = (mode == .rank) ? descending : ascending

        var tickedThisRound: Set<UInt32> = []
        roundRegisterPreLatch.removeAll(keepingCapacity: true)
        var completed = 0
        for t in order where (tileEpoch[t] ?? 0) < mx {
            _ = try tickAndFlushOneTile(tileId: t, k: mx, mode: mode, tickedThisRound: &tickedThisRound)
            completed += 1
        }
        return completed
    }

    // MARK: ticking internals

    private func tileDir(_ tileId: UInt32) throws -> String {
        guard let entry = manifest.tiles.first(where: { $0.id == tileId }) else {
            throw RouterError.manifestMissing("tile \(tileId)")
        }
        return TiledGraphFiles.tileDirectory(dataRoot: dataRoot, name: graphName, entry: entry)
    }

    /// Load a tile for ticking (ghosted engine), LRU-managed against the
    /// SAME `maxResidentTiles` budget as the query path, but tracked in
    /// its own resident set (`tickResident`/`tickLru`) — see
    /// `TickResidentTile`'s doc comment for why the two paths don't share
    /// one engine instance. Loads/evicts increment the shared
    /// `loadCount`/`evictCount` counters `status()` already exposes, so
    /// W3's "loads +N, evicts +N" assertions read off the same place T3's
    /// do.
    /// Package-internal (not `private`) so ticking-gate tests can drive the
    /// regeneration choreography directly, isolated from a whole `worldTick`
    /// round's other per-tile loads/evicts (see W3's "costs exactly" letter —
    /// a whole-round measurement conflates this cost with every other tile's
    /// ordinary load/evict, since every tile is touched every round).
    func tickLoad(tileId: UInt32) throws -> TickResidentTile {
        if let existing = tickResident[tileId] {
            touchTick(tileId)
            return existing
        }
        if tickResident.count >= maxResidentTiles {
            evictTickLRU()
        }
        // Audit C finding 16: this path's loads incremented `loadCount`
        // but its REFUSALS were never recorded and `maxResidentSeen` was
        // never touched, so `status()` under-reported the ticker exactly
        // where T3/T4's assertions read.
        do {
            let loaded = try TiledGraphFiles.loadTileWithGhosts(
                dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: tileId
            )
            let resident = TickResidentTile(
                id: tileId, engine: loaded.engine, meta: loaded.meta,
                realNodeCount: loaded.realNodeCount, ghostCount: loaded.ghostCount,
                ghostSources: loaded.ghostSources
            )
            tickResident[tileId] = resident
            touchTick(tileId)
            loadCount += 1
            maxResidentSeenCount = max(maxResidentSeenCount, residentTiles.count + tickResident.count)
            return resident
        } catch let err as RouterError {
            refusals.append((tileId, "\(err)"))
            throw err
        }
    }

    private func touchTick(_ tileId: UInt32) {
        tickLru.removeAll { $0 == tileId }
        tickLru.append(tileId)
    }

    private func evictTickLRU() {
        guard !tickLru.isEmpty else { return }
        let victim = tickLru.removeFirst()
        tickResident[victim] = nil
        evictCount += 1
    }

    /// One ghost's truth at world tick `k`. Rank mode: the source's
    /// CURRENT truth if it's resident and already ticked this world tick
    /// (always true in an uncorrupted run — descending order guarantees a
    /// higher-numbered source tile is processed before any lower tile
    /// that ghosts it — but a source can also have been evicted since it
    /// ticked, in which case its just-written epoch-`k` strip carries the
    /// same value); otherwise its committed `halo_lower.<k mod 2>.bin`.
    /// Sync mode: always the source's `halo_lower.<(k-1) mod 2>.bin`
    /// (epoch `k − 1`, or the epoch-0 strip `write` also lays down for
    /// `k == 1`) — sync mode never reads a live buffer, since tiles
    /// process in arbitrary order and sync semantics need the PREVIOUS
    /// world tick's value regardless of processing order.
    func ghostTruth(
        readerTileId: UInt32, sourceTile: UInt32, sourceLocal: UInt64,
        k: UInt64, mode: TickMode, tickedThisRound: Set<UInt32>
    ) throws -> UInt8 {
        // AMENDMENT 7, finding A. A register is never written by the
        // combinational pass, so the byte its readers must see at world
        // tick k is the one it held BEFORE this tick's latch — which is
        // also its value at the end of tick k − 1. In rank mode that is
        // what the strip carries and what the live buffer must be
        // overridden with; it is also already "the previous world tick's
        // value", so W7b's ghost-population switch leaves it alone (a
        // register carries no fresh information across a boundary to
        // delete). Checked before everything else, and against `mode`
        // rather than the switch's effective mode, so all three paths —
        // resident buffer, committed strip, ghosts-disabled — agree.
        if mode == .rank, tickedThisRound.contains(sourceTile),
           let preLatch = roundRegisterPreLatch[sourceTile]?[sourceLocal] {
            return preLatch
        }

        // W7b's test-only switch makes rank mode source its ghosts the way
        // sync mode does — the previous world tick's committed values.
        let effectiveMode: TickMode = ghostPopulationDisabled ? .sync : mode

        if effectiveMode == .rank, let resident = tickResident[sourceTile], tickedThisRound.contains(sourceTile) {
            // Audit C finding 8: `sourceLocal` is a 40-bit local id out of
            // `meta.crossingsOut` and this fast path indexed the Metal
            // buffer with it unchecked — unlike `truth(of:)`, which bounds
            // it. An out-of-range crossing read past the end of the source
            // tile's buffer and fed the result to a ghost.
            guard sourceLocal < UInt64(resident.realNodeCount) else {
                throw RouterError.crossTileBoundsExceeded(sourceTile)
            }
            let ptr = resident.engine.truthStateBuf.contents().bindMemory(
                to: UInt8.self, capacity: resident.realNodeCount + resident.ghostCount)
            return ptr[Int(sourceLocal)]
        }

        // AMENDMENT 8 — which of the strip's two truth bytes is this
        // reader's. A rank-mode ghost takes `truthPre` from the source's
        // strip at k (the value before that round's latch, which is what
        // the untiled engine shows a reader of a register); a sync-mode
        // ghost takes `truthPost` from the parity k − 1 strip (the previous
        // world tick's vector). One file, two readers, no contradiction —
        // and a round whose mode differs from the round before it now reads
        // a byte that is right for it.
        let expectedEpoch: UInt64 = (effectiveMode == .rank) ? k : (k == 1 ? 0 : k - 1)
        func select(_ v: (pre: UInt8, post: UInt8, type: UInt8)) -> UInt8 {
            effectiveMode == .rank ? v.pre : v.post
        }
        do {
            let (epoch, values) = try TiledGraphFiles.readLowerStrip(
                dataRoot: dataRoot, name: graphName, manifest: manifest,
                tileId: sourceTile, parity: expectedEpoch % 2
            )
            guard epoch == expectedEpoch, let v = values[sourceLocal] else {
                throw RouterError.haloStale(sourceTile, expected: expectedEpoch, found: epoch)
            }
            return select(v)
        } catch let err as RouterError {
            guard case .haloStale = err else { throw err }
            try regenerateStaleLowerStrip(
                readerTileId: readerTileId, sourceTileId: sourceTile, expectedEpoch: expectedEpoch
            )
            let (epoch2, values2) = try TiledGraphFiles.readLowerStrip(
                dataRoot: dataRoot, name: graphName, manifest: manifest,
                tileId: sourceTile, parity: expectedEpoch % 2
            )
            guard epoch2 == expectedEpoch, let v2 = values2[sourceLocal] else {
                throw RouterError.haloStale(sourceTile, expected: expectedEpoch, found: epoch2)
            }
            return select(v2)
        }
    }

    /// W3's regeneration choreography. `K = 1` (no free tick-resident
    /// slot): evict the reader, load the source, write its strip, evict
    /// the source, reload the reader — loads +2, evicts +2. `K ≥ 2` with
    /// a free slot: load the source into it and leave both resident —
    /// loads +1, evicts +0. Refuses (never writes a strip) if the
    /// source's own committed body is itself behind `expectedEpoch`.
    func regenerateStaleLowerStrip(
        readerTileId: UInt32, sourceTileId: UInt32, expectedEpoch: UInt64
    ) throws {
        let hadFreeSlot = tickResident.count < maxResidentTiles
        var evictedReader = false
        if !hadFreeSlot {
            if tickResident[readerTileId] != nil {
                tickResident[readerTileId] = nil
                tickLru.removeAll { $0 == readerTileId }
                evictCount += 1
                evictedReader = true
            } else {
                evictTickLRU()
            }
        }

        let source = try tickLoad(tileId: sourceTileId)
        guard source.meta.lastPersistedTickEpoch == expectedEpoch else {
            throw RouterError.haloStale(sourceTileId, expected: expectedEpoch, found: source.meta.lastPersistedTickEpoch)
        }
        // AMENDMENT 8: both bytes, same rule as recovery case (ii) —
        // `truthPost` off the committed body at `expectedEpoch`,
        // `truthPre` for a register out of the previous-parity strip.
        let preLatch = try registerPreLatchFromPreviousStrip(
            tileId: sourceTileId, engine: source.engine,
            realNodeCount: source.realNodeCount, epoch: expectedEpoch
        )
        _ = try TiledGraphFiles.writeLowerStrip(
            dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: sourceTileId,
            engine: source.engine, realNodeCount: source.realNodeCount, epoch: expectedEpoch,
            preLatchOverrides: preLatch
        )

        if evictedReader {
            tickResident[sourceTileId] = nil
            tickLru.removeAll { $0 == sourceTileId }
            evictCount += 1
            _ = try tickLoad(tileId: readerTileId)
        }
    }

    /// Per-tile flush — ticking gates AMENDMENT 1's exact order: BEGIN
    /// (WAL record now carrying the mode, AMENDMENT 2 letter 4), body
    /// (atomic snapshot, real nodes only via a real-size scratch copy of
    /// the ghosted engine), strip, meta, manifest entry (`bodySHA256` +
    /// `tickEpoch`, one authority for both the query path and the
    /// ticker), COMMIT. Returns the elapsed ms (W6) and the strip's byte
    /// count (W6's `haloBytes`).
    private func flushTile(
        tile: TickResidentTile, epoch: UInt64, mode: TickMode,
        registerPreLatch: [UInt64: UInt8] = [:]
    ) throws -> (ms: Double, haloBytes: Int) {
        // Audit C finding 9 (contract ruling "Epochs"): the epoch is UInt64
        // in the manifest, in meta.json and in flush.wal, but `body.dags`'s
        // tick field is 32 bits — `UInt32(truncatingIfNeeded:)` wrapped it
        // silently at both the tick call and the save, and past 2^32 the
        // body-vs-meta equality check would then refuse every subsequent
        // load of the whole world. Refused here, BEFORE the BEGIN record is
        // appended, so a refused flush leaves the wal untouched. Widening
        // that header field is a core-format letter for a later window.
        guard epoch <= UInt64(UInt32.max) else {
            throw RouterError.tileEpochUnrepresentable(
                tile.id, epoch: epoch, limit: UInt64(UInt32.max))
        }
        let t0 = Date()
        let dir = try tileDir(tile.id)
        let walPath = "\(dir)/flush.wal"

        try TiledGraphFiles.appendFlushWAL(
            path: walPath, record: "TILE_FLUSH_BEGIN \(tile.id) \(epoch) \(mode.walToken)"
        )

        let scratch = try TiledGraphFiles.scratchRealEngine(from: tile.engine, realNodeCount: tile.realNodeCount)
        _ = try DagDBSnapshot.save(
            engine: scratch, nodeCount: tile.realNodeCount, gridW: tile.realNodeCount, gridH: 1,
            tickCount: UInt32(truncatingIfNeeded: epoch), path: "\(dir)/body.dags"
        )

        let haloBytes = try TiledGraphFiles.writeLowerStrip(
            dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: tile.id,
            engine: tile.engine, realNodeCount: tile.realNodeCount, epoch: epoch,
            preLatchOverrides: registerPreLatch
        )

        var meta = tile.meta
        meta.lastPersistedTickEpoch = epoch
        try TiledGraphFiles.writeMeta(
            dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: tile.id, meta: meta
        )
        tile.meta = meta

        let bodyData = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/body.dags"))
        let bodyHash = DagDBSnapshot.sha256Hex(bodyData)
        try refreshManifestEntry(tileId: tile.id, bodySHA256: bodyHash, tickEpoch: epoch)

        try TiledGraphFiles.appendFlushWAL(path: walPath, record: "TILE_FLUSH_COMMIT \(tile.id) \(epoch)")
        return (Date().timeIntervalSince(t0) * 1000.0, haloBytes)
    }

    /// Rewrites tile `tileId`'s manifest entry (`bodySHA256`,
    /// `tickEpoch`) atomically (`TiledGraphFiles.writeManifest` — temp
    /// file in the same directory, then rename) and updates the router's
    /// own cached `manifest`/`tileEpoch` in lockstep — ticking gates
    /// AMENDMENT 1: cache the decoded manifest, update the entry in
    /// memory before writing, never re-decode per tile.
    private func refreshManifestEntry(tileId: UInt32, bodySHA256: String, tickEpoch: UInt64) throws {
        guard let idx = manifest.tiles.firstIndex(where: { $0.id == tileId }) else {
            throw RouterError.manifestMissing("tile \(tileId)")
        }
        var tiles = manifest.tiles
        let old = tiles[idx]
        tiles[idx] = TiledGraphFiles.TileEntry(
            id: old.id, rankLo: old.rankLo, rankHi: old.rankHi, nodeCount: old.nodeCount,
            bodySHA256: bodySHA256, crossingsOut: old.crossingsOut, crossingsIn: old.crossingsIn,
            engineIndexOf: old.engineIndexOf, tickEpoch: tickEpoch
        )
        let newManifest = TiledGraphFiles.Manifest(
            format: manifest.format, version: manifest.version, name: manifest.name,
            boundaries: manifest.boundaries, globalNodeCount: manifest.globalNodeCount, tiles: tiles
        )
        try TiledGraphFiles.writeManifest(dataRoot: dataRoot, name: graphName, manifest: newManifest)
        manifest = newManifest
        tileEpoch[tileId] = tickEpoch
    }

    // MARK: tile-locality helpers (computed, no I/O)

    /// Pure decode — `globalId.tileId`. Provided as a method for symmetry
    /// with the spec; callers can use the property directly.
    public nonisolated func tileOf(_ globalId: GlobalNodeID) -> UInt32 {
        globalId.tileId
    }

    /// Pure decode — `globalId.localNodeId`.
    public nonisolated func localIdOf(_ globalId: GlobalNodeID) -> UInt64 {
        globalId.localNodeId
    }

    /// Whether the given tile is in the resident set right now.
    public func isResident(_ tileId: UInt32) -> Bool {
        residentTiles[tileId] != nil
    }

    /// IDs of all currently-resident tiles, in insertion order.
    public func residentTileIds() -> [UInt32] {
        Array(residentTiles.keys).sorted()
    }

    // MARK: resident-set management

    /// Load a tile, touching LRU on a hit and evicting the
    /// least-recently-used tile when the resident set is already at
    /// `maxResidentTiles`. Refusals (hash mismatch, epoch mismatch) are
    /// recorded and rethrown — never loaded silently (T4).
    private func load(tileId: UInt32) throws -> ResidentTile {
        if let existing = residentTiles[tileId] {
            touch(tileId)
            return existing
        }
        if residentTiles.count >= maxResidentTiles {
            evictLRU()
        }
        do {
            let loaded = try TiledGraphFiles.loadTile(
                dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: tileId
            )
            let nodeCount = Int(loaded.meta.nodeCount)
            let inEdgeIndex = try Self.buildInEdgeIndex(
                tileId: tileId, engine: loaded.engine, nodeCount: nodeCount,
                crossingsIn: crossingsInByTile[tileId] ?? []
            )
            let crossOutIndex = Dictionary(
                grouping: loaded.meta.crossingsOut, by: { $0.localNode }
            ).mapValues { $0.map { $0.remoteNode } }

            let resident = ResidentTile(
                id: tileId, engine: loaded.engine, meta: loaded.meta, nodeCount: nodeCount,
                upperHalo: DagHaloStrip(edge: .north, width: 0),
                lowerHalo: DagHaloStrip(edge: .north, width: 0),
                inEdgeIndex: inEdgeIndex, crossOutIndex: crossOutIndex
            )
            residentTiles[tileId] = resident
            touch(tileId)
            loadCount += 1
            maxResidentSeenCount = max(maxResidentSeenCount, residentTiles.count + tickResident.count)
            return resident
        } catch let err as RouterError {
            refusals.append((tileId, "\(err)"))
            throw err
        }
    }

    private func touch(_ tileId: UInt32) {
        lruOrder.removeAll { $0 == tileId }
        lruOrder.append(tileId)
    }

    private func evictLRU() {
        guard !lruOrder.isEmpty else { return }
        let victim = lruOrder.removeFirst()
        residentTiles[victim] = nil
        evictCount += 1
    }

    /// local node id → GlobalNodeIDs of nodes (this tile or foreign) that
    /// reference it as one of THEIR higher-rank sources — the fan-out /
    /// "in-edges" index. Built once per load: one O(nodeCount·6) scan of
    /// the tile's own neighbour buffer for intra-tile fan-out, plus the
    /// tile's `crossingsIn` for cross-tile fan-out.
    private static func buildInEdgeIndex(
        tileId: UInt32, engine: DagDBEngine, nodeCount: Int, crossingsIn: [Crossing]
    ) throws -> [UInt64: [GlobalNodeID]] {
        var index: [UInt64: [GlobalNodeID]] = [:]
        if nodeCount > 0 {
            let nb = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)
            for u in 0..<nodeCount {
                for slot in 0..<6 {
                    let v = nb[u * 6 + slot]
                    guard v >= 0 else { continue }
                    let referencer = try GlobalNodeID(tileId: tileId, localNodeId: UInt64(u))
                    index[UInt64(v), default: []].append(referencer)
                }
            }
        }
        for c in crossingsIn {
            index[c.localNode, default: []].append(c.remoteNode)
        }
        return index
    }

    /// A local node's sources: its own neighbour slots (intra-tile,
    /// direct) plus `crossOutIndex` (the `-2` slots' cross-tile
    /// resolution). This is the "own neighbour slots" leg of undirected
    /// expansion, and the whole of backward (ancestry) expansion.
    private func sourcesOf(tile: ResidentTile, localId: UInt64) throws -> [GlobalNodeID] {
        var result: [GlobalNodeID] = []
        guard localId < UInt64(tile.nodeCount) else { return result }
        let nb = tile.engine.neighborsBuf.contents().bindMemory(
            to: Int32.self, capacity: tile.nodeCount * 6)
        let base = Int(localId) * 6
        for slot in 0..<6 {
            let t = nb[base + slot]
            guard t >= 0 else { continue }
            result.append(try GlobalNodeID(tileId: tile.id, localNodeId: UInt64(t)))
        }
        if let cross = tile.crossOutIndex[localId] {
            result.append(contentsOf: cross)
        }
        return result
    }

    /// A local node's full undirected neighbour set: sources (see
    /// `sourcesOf`) PLUS fan-out (`inEdgeIndex` — own tile and
    /// cross-tile referencers).
    private func undirectedNeighborsOf(tile: ResidentTile, localId: UInt64) throws -> [GlobalNodeID] {
        var result = try sourcesOf(tile: tile, localId: localId)
        if let ins = tile.inEdgeIndex[localId] {
            result.append(contentsOf: ins)
        }
        return result
    }
}
