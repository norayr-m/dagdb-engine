/// TiledGraphRouter — supervises tile-resident DagDB engines, routes queries.
///
/// Step 4 of `docs/tiled-streaming.md` build order. Live tile load / evict
/// + cross-tile BFS / ancestry / select. Pre-fetch and persistence
/// (`save`/`close`) remain out of scope (steps 5–7) — those two stay
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
///   halo-staleness machinery is out of scope here);
///   `ResidentTile.upperHalo`/`lowerHalo` are empty
///   placeholders kept only so the field exists for a future ticking pass.
/// - `tileId` is `UInt32` here (matching `GlobalNodeID.tileId`). The
///   spec's `UInt64` was loose — a 24-bit value comfortably fits u32.
///
/// Cross-tile edge resolution (a node's slots hold its HIGHER-rank
/// sources): a resident tile's per-node
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
/// `foreignRank` (ghost nodes carry "rank = the foreign node's rank"):
/// the rank (in the original untiled engine's rank space) of `remoteNode`.
/// Written at tile-write time (`TiledGraphFiles.write`'s pass 1, which
/// already has both endpoints' ranks on hand) so a ghost's rank can be
/// read straight off `crossingsOut` at load time without touching the
/// foreign tile's own files. Defaulted to 0 so existing call sites /
/// decoders of `Crossing` values written before tiled ticking keep compiling; every
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
    /// (the ghost construction order).
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
/// (ping-pong, one hop per world tick). See `worldTick` for how each mode
/// sources ghost inputs.
public enum TickMode: Sendable, Equatable {
    case rank
    case sync

    /// The third field of a `TILE_FLUSH_BEGIN` WAL record.
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

/// A `TiledGraphRouter`'s role at open — a mixed-epoch ("torn") world must
/// never answer a query.
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

/// What a writer-role `init` did before returning — `recovered`: tiles whose `flush.wal` ended in
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
/// tile-flush the call performed ("tick ms per tile").
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
    /// Cumulative disk loads (cache misses only — a resident-tile hit
    /// never increments this).
    public let loads: Int
    /// Cumulative evictions.
    public let evicts: Int
    /// Cumulative refused loads (hash mismatch / epoch mismatch). Every
    /// refused tile load is counted, whatever the error's
    /// type (a tile body the load's own validation refuses, the rank-mode
    /// slot rule among them), on every path: a round's pre-flight, the
    /// ticking path and the query path.
    public let refused: Int
    /// Description of the most recent refusal, if any.
    public let lastRefusal: String?
    /// The largest resident-tile count observed at any point so far
    /// (never exceeds `maxResidentTiles` — asserted by `testT3Residency`).
    public let maxResidentSeen: Int
    /// The router holds no global
    /// tick counter — its epoch is the (min, max) over every tile's own
    /// `TileEntry.tickEpoch`. Equal (quiet state) for a reader (which
    /// refuses to open torn) and for a writer (which completes any
    /// partial round at open, and every `worldTick` leaves them equal
    /// again).
    public let epochMin: UInt64
    public let epochMax: UInt64
}

/// A tile's tick whose command buffer ended with a status other than
/// `completed` (the tile engine's `gpuFailure`). The router claims nothing of that tick: the
/// tile is not flushed (its files stay byte-identical), its epoch does not
/// move, and its engine is dropped from the tick-resident set (the buffer
/// may have written part of its truth), so its next tick reloads it from
/// those unchanged files. Tiles already flushed at `epoch` earlier in the
/// same pass stay flushed: the partial round a crash between tiles leaves,
/// which a writer `TILED OPEN` completes.
public struct TileGPUFailure: Sendable, Equatable, CustomStringConvertible {
    public let tile: UInt32
    /// The epoch the tile was ticking to.
    public let epoch: UInt64
    public let failure: DagDBEngine.CommandBufferFailure
    /// The world tick of the `worldTick` call that failed (1-based) and the
    /// call's count; nil at open (recovery, a partial round's completion).
    public internal(set) var tick: Int?
    public internal(set) var of: Int?
    /// Tiles whose committed epoch is `epoch` when the failure is raised.
    public let tilesAtEpoch: Int
    public let tileCount: Int
    /// The world's committed epochs, (min, max), after the failure.
    public let epochMin: UInt64
    public let epochMax: UInt64

    public var description: String {
        let at = tick.map { t in "tick \(t)\(of.map { " of \($0)" } ?? ""), " } ?? ""
        let torn = epochMin < epochMax ? " (torn: a writer TILED OPEN completes the round)" : ""
        return "\(Reply.errorWords(failure)) at \(at)tile \(tile) epoch \(epoch); nothing claimed: tile \(tile) not flushed "
            + "(its files unchanged), its engine dropped; tiles at epoch \(epoch): \(tilesAtEpoch) of "
            + "\(tileCount); epoch=\(epochMin)/\(epochMax)\(torn); total=\(epochMin)"
    }
}

// MARK: - The write seam and a failed write step

/// Test seam: the
/// instants of a tiled verb's writes. `…Mid`: inside a step, half its record
/// or its temp file written; `…Done`: the step complete. The body save's own
/// boundaries: `bodyTmpDone` (`body.dags.tmp` written and fsynced),
/// `bodyOldSidecarRemoved` (the old `body.dags.sha256` removed, the rename
/// not done), `bodyRenamed`, `bodySidecarDone` (the new sidecar written).
/// `sidecarRewrite…`: recovery case (ii) writing a sidecar a crash left out;
/// `regenerate…`: a source tile's strip regenerated during a reader's turn.
public enum TiledWritePoint: String, Sendable, CaseIterable {
    case beginMid, beginDone
    case bodyTmpDone, bodyOldSidecarRemoved, bodyRenamed, bodySidecarDone
    case sidecarRewriteMid, sidecarRewriteDone
    case stripMid, stripDone
    case metaMid, metaDone
    case manifestMid, manifestDone
    case commitMid, commitDone
    case regenerateMid, regenerateDone
}

/// The pass of a verb a write belongs to.
public enum TiledWritePass: String, Sendable {
    /// A `worldTick` round (`TILED TICK`).
    case round
    /// A writer open's recovery of a dangling `TILE_FLUSH_BEGIN`.
    case recovery
    /// A writer open's completion of a partial round.
    case completion
}

/// What the write seam is told: the instant, the tile written,
/// the epoch it is written at, the pass.
public struct TiledWriteEvent: Sendable, Equatable {
    public let point: TiledWritePoint
    public let tile: UInt32
    public let epoch: UInt64
    public let pass: TiledWritePass
}

/// Test seam, called at every `TiledWritePoint`: a throw is
/// the step's I/O error (inside a step) or the process stopping there (at a
/// boundary). Production passes nil.
public typealias TiledWriteSeam = @Sendable (TiledWriteEvent) throws -> Void

/// A write step of a tiled verb failed (an I/O error, or the
/// seam). Nothing after the step was written; `left` says what the tile's
/// files hold and what the next writer `TILED OPEN` does with them, so the
/// world a fresh open leaves is every tile at its pre- or post-round files.
public struct TileWriteFailure: Sendable, Equatable, CustomStringConvertible {
    /// The tile written (for a strip regeneration, the source tile).
    public let tile: UInt32
    public let epoch: UInt64
    public let pass: TiledWritePass
    /// The step, by the file it writes: `flush.wal BEGIN`, `body.dags.tmp`,
    /// `body.dags rename`, `body.dags.sha256`, `halo_lower.<p>.bin`,
    /// `meta.json`, `manifest.json`, `flush.wal COMMIT`.
    public let step: String
    /// The failed step's error, in the one error function's words.
    public let errorWords: String
    /// The whole reply line the failed step's error carried, else nil.
    public var carriedLine: String? = nil
    public let left: String
    /// The tile's `flush.wal` ends in its BEGIN (a writer open recovers it).
    public let pending: Bool
    /// The tile's `flush.wal` ends in a torn record (a failed append whose
    /// cut back failed too): this router refuses `TILED TICK`; a writer open
    /// cuts the record and recovers per the records before it.
    public let walTorn: Bool
    /// The `worldTick` call's world tick (1-based) and count; nil at open.
    public internal(set) var tick: Int?
    public internal(set) var of: Int?
    public let tilesAtEpoch: Int
    public let tileCount: Int
    public let epochMin: UInt64
    public let epochMax: UInt64

    public var description: String {
        let at = tick.map { t in " at tick \(t)\(of.map { " of \($0)" } ?? "")" } ?? ""
        let what: String
        switch pass {
        case .round: what = ""
        case .recovery: what = "recovery of "
        case .completion: what = "completion of "
        }
        let torn = epochMin < epochMax ? " (torn: a writer TILED OPEN recovers and completes the round)" : ""
        return "\(what)tile \(tile) epoch \(epoch)\(at): the write step '\(step)' failed (\(errorWords)); nothing after it "
            + "written; \(left); tiles at epoch \(epoch): \(tilesAtEpoch) of \(tileCount); "
            + "epoch=\(epochMin)/\(epochMax)\(torn)"
    }

    /// The reply when the step's error carried its own line: that line first, under its own code, then what
    /// the router did (the same context as `description`).
    public var carriedReply: String? {
        guard let line = carriedLine else { return nil }
        let at = tick.map { t in " at tick \(t)\(of.map { " of \($0)" } ?? "")" } ?? ""
        let torn = epochMin < epochMax ? " (torn: a writer TILED OPEN recovers and completes the round)" : ""
        return "\(line); tile \(tile) epoch \(epoch)\(at): the write step '\(step)' did not run; nothing after it written; "
            + "\(left); tiles at epoch \(epoch): \(tilesAtEpoch) of \(tileCount); epoch=\(epochMin)/\(epochMax)\(torn)"
    }
}

/// Errors raised by the router. Stable category names for DSL-error parity.
/// An error other than a write step or a GPU
/// failure that escaped one tile's tick and flush inside `worldTick`. The
/// tiles flushed before it stay flushed (the partial round a writer TILED
/// OPEN completes), so the reply names them: the call's world
/// tick, the tile, the tiles at the epoch, the world's epochs and the total.
public struct TileTickStop: Sendable, Equatable, CustomStringConvertible {
    public let underlying: String
    /// The whole reply line the stopping error carried (an admission refusal:
    /// `ERROR out_of_budget: …`), else nil. `underlying` then is that line, and the stop is replied under its code.
    public var carriedLine: String? = nil
    public let tile: UInt32
    public let epoch: UInt64
    public let tick: Int
    public let of: Int
    public let tilesAtEpoch: Int
    public let tileCount: Int
    public let epochMin: UInt64
    public let epochMax: UInt64
    public let loads: Int
    public let evicts: Int

    public var description: String {
        let torn = epochMin < epochMax ? " (torn: a writer TILED OPEN completes the round)" : ""
        return "\(underlying) at tick \(tick) of \(of), tile \(tile) epoch \(epoch); tile \(tile) not flushed; "
            + "tiles at epoch \(epoch): \(tilesAtEpoch) of \(tileCount); epoch=\(epochMin)/\(epochMax)\(torn); "
            + "this call's loads=\(loads) evicts=\(evicts); total=\(epochMin)"
    }
}

public enum RouterError: Error, CustomStringConvertible, Sendable, Reply.CarriesLine {
    case notImplemented(String)
    /// See `TileTickStop`.
    case tickStoppedAfterFlush(TileTickStop)
    /// A write step failed; see `TileWriteFailure`. The daemon
    /// replies `ERROR io: TILED TICK: …` or `ERROR io: TILED OPEN: …`.
    case tileWriteFailed(TileWriteFailure)
    /// A ghost reference (`meta.json`'s `crossingsOut` of tile
    /// `reader`, at `local`) that no round could serve: its source tile is not
    /// in the manifest, or the source's strip does not carry the source local
    /// (it is not among the source's `crossingsIn`). Refused before any tile
    /// is written, not at the reader's own turn (where, in rank mode at
    /// K >= 2, an in-range local would be served from the resident buffer
    /// instead).
    case ghostReferenceInvalid(UInt32, local: UInt64, sourceTile: UInt32, sourceLocal: UInt64, detail: String)
    /// A strip a round or a recovery reads cannot be read
    /// (missing, malformed). `detail` is the read's own error, without the
    /// object addresses an `NSError` prints. Refused before any tile is
    /// written, not as a raw read error at the reader's turn.
    case haloUnreadable(UInt32, file: String, detail: String)
    /// See `TileGPUFailure`. The daemon
    /// replies `ERROR gpu:` with it.
    case tileGPUFailure(TileGPUFailure)
    case tileNotResident(UInt32)
    case crossTileBoundsExceeded(UInt32)
    case manifestMissing(String)
    /// A tile's `body.dags` sha256 differs from the manifest's recorded
    /// hash — present-but-changed, refused, never loaded silently.
    case tileHashMismatch(UInt32, expected: String, actual: String)
    /// `meta.json.last_persisted_tick_epoch` disagrees with the body's
    /// own `tickCount` (`DagDBSnapshot.LoadResult.fileTicks`) — the flush
    /// crashed mid-way; refused, never loaded silently.
    case tileInconsistent(UInt32, metaEpoch: UInt64, bodyEpoch: UInt64)
    /// §6.1's depth cap: BFS/ancestry beyond depth 12 is the wrong
    /// primitive (use rank-range SELECT instead) — refused, not silently
    /// truncated.
    case depthCapExceeded(UInt32)
    /// A source tile's lower strip (the parity file a
    /// reader tile's ghosts are staged from) carries an epoch other than
    /// the one this world tick expects. The world-tick loop attempts
    /// regeneration from the source's COMMITTED body before surfacing
    /// this — see `TiledGraphRouter.regenerateStaleLowerStrip` — so this
    /// case reaching a caller means regeneration itself refused (the
    /// source's own committed body is behind the expected epoch too).
    case haloStale(UInt32, expected: UInt64, found: UInt64)
    /// `<tile>/flush.wal` ends in a `TILE_FLUSH_BEGIN`
    /// with no matching `TILE_FLUSH_COMMIT` — the flush that was writing
    /// `epoch` crashed mid-way. `bodyEpoch` is what `body.dags` itself
    /// currently reports (`k − 1` = crash before the atomic rename, `k` =
    /// crash after it but before the strip/meta/commit). A writer-role
    /// `init` recovers this automatically; a reader-role `init` never
    /// sees it directly (a dangling BEGIN always implies a torn world,
    /// caught first as `worldTorn`).
    case tileFlushIncomplete(UInt32, epoch: UInt64, bodyEpoch: UInt64)
    /// The router's tiles disagree
    /// on epoch (a between-tiles crash, or a reader opened before a
    /// writer completed the round) — a mixed-epoch world must never
    /// answer a query. Readers refuse to open over this; writers refuse
    /// `worldTick` over it (defensive — a writer's own `init` always
    /// closes the gap first).
    case worldTorn(min: UInt64, max: UInt64)
    /// Completing a partial round
    /// needs the mode the round now at the target epoch was run in —
    /// read from the last committed `TILE_FLUSH_BEGIN` of every tile
    /// already at that epoch. Two different modes among those tiles is
    /// not a legitimate partial round (a single-router world can't have
    /// two rounds of different modes both land at the same max epoch) —
    /// it means the directory was touched by hand. `tiles` maps each
    /// disagreeing tile id to the mode token its own record carries.
    case partialRoundModeMismatch([UInt32: String])
    /// Three counts, one truth: `manifest.json`'s entry node count,
    /// `meta.json`'s and `body.dags`'s own header field must agree. They
    /// are three independent file-derived numbers: the engine is sized from
    /// the manifest's (an `Int(UInt64)` that TRAPS above `Int.max`, and
    /// below it an arbitrarily large Metal allocation), while
    /// `ResidentTile.nodeCount` and every buffer bound from it come from
    /// meta.json's. `body` is nil when the refusal fired
    /// before the body header was read.
    case tileNodeCountInconsistent(UInt32, manifest: UInt64, meta: UInt64, body: UInt64?,
                                   detail: String)
    /// A manifest entry whose `engineIndexOf` is short,
    /// or names an index at or past `globalNodeCount` — `truthArray()`
    /// indexes a `globalNodeCount`-sized array with it, and the memberwise
    /// init defaults the field to `[]`, so a hand-built entry would trap at
    /// local 0. Validated at router init, before any tile is touched.
    case engineIndexInvalid(UInt32, detail: String)
    /// `maxResidentTiles` below 1 — both load paths evict exactly one tile
    /// before inserting one, so at K <= 0 the resident set would grow past
    /// K instead of holding to it.
    case residencyBudgetInvalid(Int)
    /// A negative count for `worldTick(mode:count:)`, whose `0..<count`
    /// loop would TRAP on it.
    case tickCountNegative(Int)
    /// `body.dags`'s tick field is 32 bits wide, and both the tick call and
    /// the save would truncate a UInt64 epoch into it silently. Past 2^32
    /// the body-vs-meta equality check would then refuse every subsequent
    /// load of the whole world. Refused at flush instead. Widening that
    /// header field is left for a later format change.
    case tileEpochUnrepresentable(UInt32, epoch: UInt64, limit: UInt64)
    /// `<tile>/flush.wal`'s last record is
    /// neither a well-formed COMMIT nor a well-formed BEGIN — a torn
    /// append, an unknown verb, or a BEGIN at epoch 0. Never read as
    /// "clean".
    case tileFlushMalformed(UInt32, detail: String)
    /// `<tile>/flush.wal` is present but cannot be read. Read as clean
    /// (`try?`), a dangling BEGIN would go unseen and the tile be re-ticked
    /// under a second BEGIN. Refused by name before anything is written.
    case tileFlushUnreadable(UInt32, detail: String)

    /// A router error whose inner error carried a whole reply line (an admission
    /// refusal) is replied under that line's code alone, with the router's context after it; nil otherwise. A detail
    /// that is itself a reply line (it begins `ERROR `) was a carried line kept whole where it was built.
    public var replyLine: String? {
        switch self {
        case .tickStoppedAfterFlush(let t): return t.carriedLine == nil ? nil : t.description
        case .tileWriteFailed(let f): return f.carriedReply
        case .haloUnreadable(let t, let file, let detail) where detail.hasPrefix("ERROR "):
            return "\(detail); TiledGraphRouter: tile \(t)'s \(file) was not read; refusing"
        case .tileFlushUnreadable(let t, let detail) where detail.hasPrefix("ERROR "):
            return "\(detail); TiledGraphRouter: tile \(t) flush.wal was not read; refused, nothing written"
        default: return nil
        }
    }

    public var description: String {
        switch self {
        case .tickStoppedAfterFlush(let t):
            return "\(t)"
        case .tileWriteFailed(let f):
            return "TiledGraphRouter: \(f)"
        case .haloUnreadable(let t, let file, let detail):
            return "TiledGraphRouter: tile \(t)'s \(file) cannot be read (\(detail)); refusing"
        case .ghostReferenceInvalid(let r, let local, let s, let sl, let detail):
            return "TiledGraphRouter: tile \(r) local \(local)'s crossing names tile \(s) local \(sl): \(detail); "
                + "refused before any tile is written"
        case .tileGPUFailure(let g):
            return "TiledGraphRouter: tile \(g.tile)'s tick: \(g)"
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
        case .tileFlushUnreadable(let id, let detail):
            return "TiledGraphRouter: tile \(id) flush.wal cannot be read (\(detail)); refused, nothing written"
        case .notImplemented(let what):
            return "TiledGraphRouter: \(what) not yet implemented (scaffold)"
        case .tileNotResident(let id):
            return "TiledGraphRouter: tile \(id) not resident; load it first"
        case .crossTileBoundsExceeded(let id):
            return "TiledGraphRouter: tile \(id) outside tile-id space"
        case .manifestMissing(let path):
            return "TiledGraphRouter: tile manifest not found at \(Reply.quoted(path))"
        case .tileHashMismatch(let id, let expected, let actual):
            return "TiledGraphRouter: tile \(id) body.dags sha256 mismatch — expected \(Reply.quoted(expected)) got \(actual); refusing load"
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
            let desc = tiles.sorted { $0.key < $1.key }.map { "tile \($0.key)=\(Reply.quoted($0.value))" }.joined(separator: ", ")
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
    /// No router-global tick counter
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
    /// Tiles whose `flush.wal` this router left ending in a
    /// torn record (an append that failed and could not be cut back).
    private var tornWALTiles: Set<UInt32> = []
    /// Tiles whose `flush.wal` ended
    /// in a torn last record (no newline: a kill inside its append) at a
    /// writer `init`. The record never started its step: the plan reads the
    /// wal without it, and the open cuts it before its first other write.
    private var tornTails: [UInt32: TiledGraphFiles.TornTail] = [:]

    /// `tile id -> (local id -> PRE-latch truth)`
    /// for the registers of every tile ticked so far in the CURRENT
    /// rank-mode round. The strip a tile flushes carries these bytes, but a
    /// reader at K >= 2 can find its source still resident and read the
    /// live buffer instead — which holds the POST-latch value. Both paths
    /// must answer the same thing, so the resident fast path consults this
    /// map first. Cleared at the start of every round.
    private var roundRegisterPreLatch: [UInt32: [UInt64: UInt8]] = [:]

    /// TEST-ONLY — never a
    /// production path. With this set, rank mode sources its ghosts the
    /// way sync mode does: from the source tile's COMMITTED strip at epoch
    /// `k − 1`, never from the value the source computed earlier in this
    /// same world tick. That is exactly "ghosts deleted" in rank mode
    /// ("the reader tile evaluates with its
    /// ghost inputs held at their values from the PREVIOUS world tick"),
    /// so a run with it on must equal the reference's `stale` vector and a
    /// run with it off must equal `fresh`. Default `false`.
    private(set) var ghostPopulationDisabled = false

    /// TEST-ONLY — a map from a source node's
    /// `GlobalNodeID.raw` to the truth byte every reader tile must see for
    /// it, applied after the ordinary strip/resident read. This is the
    /// perturbation "one committed strip entry forced to the flipped bit"
    /// delivered at the point the reader consumes it. In SYNC mode the
    /// equivalent edit can be (and in a test is) made on the committed file
    /// itself, because sync reads the `k − 1` parity strip, which the
    /// round does not rewrite; in RANK mode the source tile re-flushes its
    /// own epoch-`k` strip earlier in the same round, so a pre-tick file
    /// edit is provably overwritten before any reader sees it. Empty by
    /// default.
    private(set) var ghostForced: [UInt64: UInt8] = [:]

    func setGhostPopulationDisabled(_ disabled: Bool) { ghostPopulationDisabled = disabled }
    func setGhostForced(_ forced: [UInt64: UInt8]) { ghostForced = forced }

    /// Test seam (`TiledWriteSeam`): nil in production. Set
    /// at `init` (an open's recovery and completion see it) or here.
    private var writeSeam: TiledWriteSeam?

    func setWriteSeamForTesting(_ seam: TiledWriteSeam?) { writeSeam = seam }

    /// For each tile, the list of (foreign tile, foreign local) →
    /// this tile's local node it points at — built once at init from
    /// every tile's own `crossingsIn` entry in the manifest (which
    /// `TiledGraphFiles.write` already assembled from every OTHER tile's
    /// `crossingsOut` in a single pass — see that file's "Pass 1" comment).
    private let crossingsInByTile: [UInt32: [Crossing]]

    // Load, eviction and refusal bookkeeping
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
    /// The role decides what
    /// happens next: a **writer** (the default, and the daemon's `TILED
    /// OPEN`) recovers any dangling `TILE_FLUSH_BEGIN` first, then
    /// completes a partial round if the tiles still disagree on epoch, so
    /// its world is never torn when it starts answering queries or
    /// ticking. A **reader** never recovers or ticks — it refuses to open
    /// at all over a torn world (`RouterError.worldTorn`).
    ///
    /// Before a writer's recovery writes anything, the open is
    /// pre-flighted whole (`preflightOpen`): every refusal recovery and
    /// completion could raise after an earlier write is raised first. A
    /// write step that fails throws `RouterError.tileWriteFailed`, naming the
    /// step; nothing after it is written, and the next writer open recovers.
    /// `writeSeam` is a test seam; production passes nil.
    ///
    /// `manifest`, when given, is this graph's
    /// manifest as the caller just read it with `TiledGraphFiles.readManifest`
    /// (the daemon's TILED OPEN decodes it once, admits the router's bytes from
    /// it, and builds the router on it); nil reads it here, as before.
    public init(
        dataRoot: String, graphName: String, maxResidentTiles: Int = 2, role: RouterRole = .writer,
        writeSeam: TiledWriteSeam? = nil, manifest preread: TiledGraphFiles.Manifest? = nil
    ) async throws {
        // Both load paths evict exactly one tile
        // before inserting one, so at K <= 0 the resident set grows past K
        // rather than holding to it. Refused at the door.
        guard maxResidentTiles >= 1 else {
            throw RouterError.residencyBudgetInvalid(maxResidentTiles)
        }
        self.dataRoot = dataRoot
        self.graphName = graphName
        self.maxResidentTiles = maxResidentTiles
        self.role = role
        self.writeSeam = writeSeam
        var manifest: TiledGraphFiles.Manifest
        if let preread {
            manifest = preread
        } else {
            do {
                manifest = try TiledGraphFiles.readManifest(dataRoot: dataRoot, name: graphName)
            } catch TiledGraphFiles.FilesError.manifestMissing(let path) {
                throw RouterError.manifestMissing(path)
            }
        }
        self.manifest = manifest

        // `truthArray()` sizes its result
        // `globalNodeCount` and indexes it by `entry.engineIndexOf[li]`,
        // both straight out of manifest.json — and the memberwise init
        // defaults `engineIndexOf` to `[]`, so a hand-built entry would trap
        // at local 0. Validated once, here,
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

        // A torn `flush.wal` (a half-written final record, an unknown verb,
        // a three-field BEGIN predating the mode field, or a BEGIN at epoch
        // 0) is never read as CLEAN. The router refuses to open over it by
        // name — but for a writer, a half-written final record, below.
        //
        // A writer reads a torn LAST record (no
        // newline: a kill inside the append) as never begun — the records
        // before it decide, and the open cuts it once its plan has passed
        // (`cutTornTails`); every other torn form is refused as before, and
        // a reader still refuses a torn last record. An unreadable wal is
        // refused by name, never read as clean.
        var pending: [UInt32: (epoch: UInt64, mode: TickMode)] = [:]
        var tails: [UInt32: TiledGraphFiles.TornTail] = [:]
        for entry in manifest.tiles {
            let dir = TiledGraphFiles.tileDirectory(dataRoot: dataRoot, name: graphName, entry: entry)
            let read = role == .writer ? TiledGraphFiles.flushStateForWriter(dir: dir)
                : (state: TiledGraphFiles.flushState(dir: dir), cut: nil)
            switch read.state {
            case .clean: break
            case .pending(let epoch, let mode): pending[entry.id] = (epoch, mode)
            case .torn(let detail):
                throw RouterError.tileFlushMalformed(entry.id, detail: detail)
            case .unreadable(let detail):
                throw RouterError.tileFlushUnreadable(entry.id, detail: detail)
            }
            if let cut = read.cut { tails[entry.id] = cut }
        }
        self.pendingRecoveryTiles = pending
        self.tornTails = tails

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
            try preflightOpen()     // a refused load writes nothing first
            try cutTornTails()      // the open's first write
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
            // `residentTiles` is the QUERY path's set; the ticker holds its
            // own (`tickResident`) against the same budget, so both are
            // reported (a router mid-tick would otherwise report zero residency).
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

    /// Persist all dirty tiles to disk. Stub — out of scope (routers are
    /// not persisted; a directory on disk is the state).
    public func save() async throws {
        throw RouterError.notImplemented("save")
    }

    /// Drain readers, flush dirty tiles, release engines. Stub — out of
    /// scope for the same reason as `save`.
    public func close() async throws {
        throw RouterError.notImplemented("close")
    }

    /// Route an arbitrary DSL command to the right tile. Out of scope —
    /// only the three typed verbs below exist (`runBFS`, `runAncestry`,
    /// `runSelect`); no verb-dispatch table.
    public func runQuery(_ dsl: String) async throws -> String {
        throw RouterError.notImplemented("runQuery: \(dsl.prefix(40))…")
    }

    /// Cross-tile BFS, level-synchronous across tiles. `backward:
    /// false` is UNDIRECTED — matches `DagDBBFS.bfsDepthsUndirected`
    /// exactly: it walks both a node's own neighbour slots (its sources)
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

    /// Truth-by-rank-range select. Every tile whose rank span could
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

    // MARK: - Ticking

    /// Every tile's `(metaEpoch, bodyEpoch)` read fresh off disk — the
    /// tiled-ticking tests' per-world-tick invariant check, and a general
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
    /// included — they are inputs, not state.
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
    /// order). Defensively refuses `RouterError.worldTorn`
    /// if the tiles don't already agree on epoch (a
    /// writer's own `init` always closes that gap first, and every
    /// `worldTick` call leaves them agreeing again — this should never
    /// actually fire in ordinary use).
    ///
    /// Before the first round
    /// advances any tile, every tile the call ticks passes the load that
    /// would refuse it (`preflightTileLoads`), so a refused load leaves every
    /// tile, every epoch and the directory byte-identical, and is counted in
    /// `status()`.
    ///
    /// Then the round is planned against the files
    /// (`preflightRound`): every refusal a later tile's turn could raise
    /// (a ghost reference no round can serve, a strip that cannot be read or
    /// regenerated, a `crossingsIn` past a tile's count, an epoch past the
    /// body's field at a later world tick) is raised before the first write.
    /// A write step that fails throws `RouterError.tileWriteFailed` naming
    /// it; the router then ticks no more until a writer open recovers.
    public func worldTick(mode: TickMode, count: Int) async throws -> WorldTickReport {
        // `for _ in 0..<count` TRAPS on a negative count, on a public
        // entry point taking an Int.
        guard count >= 0 else { throw RouterError.tickCountNegative(count) }
        // A flush of this router that failed after its BEGIN
        // is a dangling BEGIN on disk; only a writer open recovers it.
        //
        // These refusals — after a
        // failed write step, and the defensive torn-world one — are counted
        // in `status()` like every other (the tile: the torn or pending one;
        // for a torn world the lowest tile below the max epoch).
        if let t = tornWALTiles.min() {
            let e = RouterError.tileFlushMalformed(
                t, detail: "this router's append to it failed and could not be cut back; it ends in a torn record")
            recordRefusal(t, e)
            throw e
        }
        if let t = pendingRecoveryTiles.keys.min(), let p = pendingRecoveryTiles[t] {
            let body = (try? TiledGraphFiles.peekTileEpochs(
                dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: t).bodyEpoch) ?? 0
            let e = RouterError.tileFlushIncomplete(t, epoch: p.epoch, bodyEpoch: body)
            recordRefusal(t, e)
            throw e
        }
        let mn = tileEpoch.values.min() ?? 0
        let mx = tileEpoch.values.max() ?? 0
        guard mn == mx else {
            let e = RouterError.worldTorn(min: mn, max: mx)
            recordRefusal(tileEpoch.filter { $0.value < mx }.keys.min() ?? 0, e)
            throw e
        }

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

        if count > 0 {
            let tiles = try preflightTileLoads(order)     // every load passes before any write
            try preflightRound(order: order, mode: mode, count: count, tiles: tiles)   // the round planned before any write
        }

        for i in 0..<count {
            let k = lastEpoch + 1
            var tickedThisRound: Set<UInt32> = []
            roundRegisterPreLatch.removeAll(keepingCapacity: true)

            for t in order {
                let (hb, fms, tms): (Int, Double, Double)
                do {
                    #if DEBUG || DAGDB_FAULT_INJECTION
                    // Fault-injection seam: the k-th tile flush of this call throws.
                    if let v = DagDBFaultInjection.value("TILED_TICK_ERROR"), Int(v) == flushes + 1 {
                        throw RouterError.notImplemented("injected fault (DAGDB_FI_TILED_TICK_ERROR) at tile \(t)")
                    }
                    #endif
                    (hb, fms, tms) = try tickAndFlushOneTile(
                        tileId: t, k: k, mode: mode, tickedThisRound: &tickedThisRound
                    )
                } catch RouterError.tileGPUFailure(let failed) {
                    // The reply names the call's world tick.
                    var g = failed
                    g.tick = i + 1
                    g.of = count
                    throw RouterError.tileGPUFailure(g)
                } catch RouterError.tileWriteFailed(let failed) {
                    // The same, for a failed write step.
                    var f = failed
                    f.tick = i + 1
                    f.of = count
                    throw RouterError.tileWriteFailed(f)
                } catch {
                    // Any other error, wrapped with what this call already
                    // flushed.
                    let mn = tileEpoch.values.min() ?? 0
                    let mx = tileEpoch.values.max() ?? 0
                    throw RouterError.tickStoppedAfterFlush(TileTickStop(
                        underlying: Reply.carriedLine(error) ?? Reply.errorWords(error), carriedLine: Reply.carriedLine(error),
                        tile: t, epoch: k, tick: i + 1, of: count,
                        tilesAtEpoch: tileEpoch.values.filter { $0 == k }.count, tileCount: manifest.tiles.count,
                        epochMin: mn, epochMax: mx,
                        loads: loadCount - loadsStart, evicts: evictCount - evictsStart))
                }
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
        tileId t: UInt32, k: UInt64, mode: TickMode, tickedThisRound: inout Set<UInt32>,
        pass: TiledWritePass = .round
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
                k: k, mode: mode, tickedThisRound: tickedThisRound, pass: pass
            )
        }

        // A register's PRE-latch
        // byte, read before the tick, is what a rank-mode reader in a lower
        // tile must see in this round's strip. The kernel never writes a
        // register, so "before the tick" and "before the latch" are the
        // same bytes. Recorded in BOTH modes now: the strip carries both
        // bytes, so whichever mode wrote the file, a sync-mode reader one
        // world tick later still finds the post-latch vector it wants.
        let preLatch = registerPreLatchBytes(tile: tile)
        roundRegisterPreLatch[t] = preLatch

        // The same 32-bit ceiling applies to the tick number
        // the kernel is given — refused before the truncation, not after.
        guard k <= UInt64(UInt32.max) else {
            throw RouterError.tileEpochUnrepresentable(t, epoch: k, limit: UInt64(UInt32.max))
        }
        let t0 = Date()
        try tickTileChecked(tile, k: k, mode: mode)     // a failed status flushes nothing
        let tickMs = Date().timeIntervalSince(t0) * 1000.0
        tickedThisRound.insert(t)

        do {
            let (flushMs, haloBytes) = try flushTile(
                tile: tile, epoch: k, mode: mode, registerPreLatch: preLatch, pass: pass)
            return (haloBytes, flushMs, tickMs)
        } catch {
            // The tile's engine is ahead of its files; it is dropped (its
            // next load reads the files), as a tile whose command buffer
            // failed is dropped. A dangling BEGIN keeps the router from
            // ticking until a writer open recovers it.
            dropTickResident(t)
            roundRegisterPreLatch[t] = nil
            if case RouterError.tileWriteFailed(let f) = error {
                if f.pending { pendingRecoveryTiles[t] = (k, mode) }
                if f.walTorn { tornWALTiles.insert(t) }
            }
            throw error
        }
    }

    /// `tileId` out of the tick-resident set (not an eviction).
    private func dropTickResident(_ tileId: UInt32) {
        tickResident[tileId] = nil
        tickLru.removeAll { $0 == tileId }
    }

    /// Every tile of `tileIds` not in
    /// the tick-resident set is loaded exactly as its round will load it
    /// (`TiledGraphFiles.loadTileWithGhosts`, the same function, the same
    /// files) and the result discarded; the first refusal is counted and
    /// thrown before anything is written. Tiles open lazily, and the load
    /// holds every tile body to the rank-mode rule in either tick mode
    /// (`SlotRule.rankModeDAG`: a tiled graph stays a rank-mode object), so
    /// without this check a round over tiles an older build wrote with S2 or
    /// S3 would be refused only at the bad tile's own turn, after the tiles
    /// before it had flushed: a torn directory.
    ///
    /// Why this is whole: within a call nothing writes a tile's body, meta,
    /// wal or manifest entry before that tile's own flush, so the round's
    /// load of a non-resident tile reads exactly what this check read. A
    /// resident tile's engine passed the same load when it became resident;
    /// if it is evicted before its turn, its reload reads either those files
    /// or this router's own flush of them. Later rounds of the same call
    /// read only this router's flushes. Not covered (a refusal there still
    /// stops the round mid-way, as before): a command buffer that does not
    /// complete, an I/O error while writing, and files changed by
    /// another writer under an open router.
    ///
    /// The checked tiles are not resident and not counted in `loads`; the
    /// check holds one tile beyond the K resident while it runs.
    ///
    /// Returns what the plan needs of every tile of `tileIds`
    /// (a resident one from its engine, the rest from the checked load).
    @discardableResult
    private func preflightTileLoads(_ tileIds: [UInt32], ignorePendingFlush: Bool = false) throws -> [UInt32: PlanTile] {
        var out: [UInt32: PlanTile] = [:]
        for t in tileIds {
            if let r = tickResident[t] {
                out[t] = PlanTile(engine: r.engine, realNodeCount: r.realNodeCount,
                                  ghostSources: r.ghostSources, crossingsOut: r.meta.crossingsOut)
                continue
            }
            do {
                let l = try TiledGraphFiles.loadTileWithGhosts(
                    dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: t,
                    ignorePendingFlush: ignorePendingFlush, tornTailSetAside: tornTails[t] != nil)
                out[t] = PlanTile(engine: l.engine, realNodeCount: l.realNodeCount,
                                  ghostSources: l.ghostSources, crossingsOut: l.meta.crossingsOut)
            } catch {
                recordRefusal(t, error)
                throw error
            }
        }
        return out
    }

    /// A writer open's recovery and round completion load and
    /// tick tiles; every tile they will load passes the load first, so a
    /// refused load leaves the directory byte-identical (otherwise a
    /// completion that reached a refused tile second would already have
    /// flushed the first). Recovery's tiles load as recovery loads them (a dangling
    /// BEGIN ignored); completion's are the tiles below the epoch the world
    /// stands at once recovery has committed every dangling flush.
    ///
    /// Then recovery and completion are planned whole against
    /// the files (`planRecovery`, `planCompletion`), so every refusal they
    /// could raise after an earlier write (a body at neither epoch, a stale
    /// strip, an epoch past the body's field, a `crossingsIn` past a tile's
    /// count, completion's mode, a ghost reference) is raised first.
    private func preflightOpen() throws {
        var tiles = try preflightTileLoads(pendingRecoveryTiles.keys.sorted(), ignorePendingFlush: true)
        var after = tileEpoch
        for (t, p) in pendingRecoveryTiles { after[t] = p.epoch }
        let mx = after.values.max() ?? 0
        tiles.merge(try preflightTileLoads(manifest.tiles.map { $0.id }.sorted().filter {
            pendingRecoveryTiles[$0] == nil && (after[$0] ?? 0) < mx
        })) { a, _ in a }

        var plan = WritePlan(committed: tileEpoch, carried: carriedLocals())
        for t in pendingRecoveryTiles.keys.sorted() {
            guard let p = pendingRecoveryTiles[t] else { continue }
            do { try planRecovery(t, epoch: p.epoch, mode: p.mode, plan: &plan, tiles: &tiles) } catch {
                recordRefusal(t, error)
                throw error
            }
        }
        try planCompletion(plan: &plan, tiles: &tiles)
    }

    // MARK: - The plan (refusals before writes)

    /// What the plan needs of a tile: its ghost sources (the round's own
    /// order), its crossings (for the refusal's words) and the locals that
    /// are registers (a regenerated strip's pre-latch bytes come from them).
    private struct PlanTile {
        let ghostSources: [(tile: UInt32, local: UInt64)]
        let crossingsOut: [Crossing]
        let registers: Set<UInt64>

        init(engine: DagDBEngine, realNodeCount: Int, ghostSources: [(tile: UInt32, local: UInt64)],
             crossingsOut: [Crossing]) {
            self.ghostSources = ghostSources
            self.crossingsOut = crossingsOut
            self.registers = Set(engine.backEdgeDsts.filter { Int($0) < realNodeCount }.map { UInt64($0) })
        }
    }

    /// The strip and epoch state a verb's own writes will leave, ahead of the
    /// verb: every tile's committed epoch, and every strip the verb reads,
    /// from its file until the verb's own write replaces it. A strip a flush
    /// or a regeneration writes at epoch e carries exactly the tile's
    /// `crossingsIn` locals (`writeLowerStrip`).
    private struct WritePlan {
        enum Strip {
            case read(epoch: UInt64, locals: Set<UInt64>)
            case unreadable(Error)
        }
        var committed: [UInt32: UInt64]
        /// tile id -> the distinct locals its strip carries (manifest `crossingsIn`).
        let carried: [UInt32: Set<UInt64>]
        /// `tile << 1 | parity` -> the strip there.
        var strips: [UInt64: Strip] = [:]
    }

    /// A strip read's own error, named (`RouterError.haloUnreadable`).
    private static func stripUnreadable(_ tile: UInt32, parity: UInt64, _ error: Error) -> RouterError {
        // The one error function (errno words for a Foundation error; never localizedDescription).
        let detail = Reply.carriedLine(error) ?? Reply.errorWords(error)       // a carried line kept whole
        return .haloUnreadable(tile, file: "halo_lower.\(parity).bin", detail: detail)
    }

    private func carriedLocals() -> [UInt32: Set<UInt64>] {
        var out: [UInt32: Set<UInt64>] = [:]
        for e in manifest.tiles { out[e.id] = Set(e.crossingsIn.map { $0.localNode }) }
        return out
    }

    /// The strip of `tile` at `parity` as the verb will find it.
    private func planStrip(_ tile: UInt32, parity: UInt64, _ plan: inout WritePlan) -> WritePlan.Strip {
        let key = UInt64(tile) << 1 | parity
        if let s = plan.strips[key] { return s }
        let s: WritePlan.Strip
        do {
            let (epoch, values) = try TiledGraphFiles.readLowerStrip(
                dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: tile, parity: parity)
            s = .read(epoch: epoch, locals: Set(values.keys))
        } catch {
            s = .unreadable(error)
        }
        plan.strips[key] = s
        return s
    }

    /// `writeLowerStrip`'s own refusal (a `crossingsIn`
    /// local at or past the tile's count), then the strip it writes.
    private func planStripWrite(_ tile: UInt32, epoch: UInt64, _ plan: inout WritePlan) throws {
        let carried = plan.carried[tile] ?? []
        if let entry = manifest.tiles.first(where: { $0.id == tile }),
           let bad = carried.sorted().first(where: { $0 >= entry.nodeCount }) {
            throw TiledGraphFiles.FilesError.crossingLocalOutOfRange(
                tile: tile, local: bad, nodeCount: Int(clamping: entry.nodeCount))
        }
        plan.strips[UInt64(tile) << 1 | epoch % 2] = .read(epoch: epoch, locals: carried)
    }

    /// A tile's flush at `epoch`: the epoch fits the body's field, its strip
    /// is written, its committed epoch moves.
    private func planFlush(_ tile: UInt32, epoch: UInt64, _ plan: inout WritePlan) throws {
        guard epoch <= UInt64(UInt32.max) else {
            throw RouterError.tileEpochUnrepresentable(tile, epoch: epoch, limit: UInt64(UInt32.max))
        }
        try planStripWrite(tile, epoch: epoch, &plan)
        plan.committed[tile] = epoch
    }

    /// A ghost reference no round can serve: its source tile absent from the
    /// manifest or its local not carried by the source's strip
    /// (`ghostReferenceInvalid`), or its local at or past the source's count
    /// (`crossTileBoundsExceeded`).
    private func planGhostReference(reader r: UInt32, _ g: (tile: UInt32, local: UInt64), tiles: [UInt32: PlanTile],
                                    _ plan: WritePlan) throws {
        func invalid(_ detail: String) -> RouterError {
            let readerLocal = tiles[r]?.crossingsOut.first {
                $0.remoteNode.tileId == g.tile && $0.remoteNode.localNodeId == g.local
            }?.localNode ?? 0
            return .ghostReferenceInvalid(r, local: readerLocal, sourceTile: g.tile, sourceLocal: g.local, detail: detail)
        }
        guard let carried = plan.carried[g.tile],
              let source = manifest.tiles.first(where: { $0.id == g.tile }) else {
            throw invalid("the manifest holds no tile \(g.tile)")
        }
        // `crossTileBoundsExceeded`, by its own name (a local at or past
        // the source tile's count), raised here instead of at the reader's turn.
        guard g.local < source.nodeCount else { throw RouterError.crossTileBoundsExceeded(g.tile) }
        guard carried.contains(g.local) else {
            throw invalid("tile \(g.tile)'s strip does not carry it (it is not among tile \(g.tile)'s crossingsIn)")
        }
    }

    /// `registerPreLatchFromPreviousStrip`'s refusals: a register's
    /// pre-latch byte at `epoch` comes from the tile's strip at `epoch − 1`.
    private func planPreviousStrip(_ tile: UInt32, epoch: UInt64, _ plan: inout WritePlan,
                                   _ tiles: [UInt32: PlanTile]) throws {
        guard epoch > 0, let pt = tiles[tile] else { return }
        let regs = pt.registers.intersection(plan.carried[tile] ?? [])
        guard !regs.isEmpty else { return }
        switch planStrip(tile, parity: (epoch - 1) % 2, &plan) {
        case .unreadable:
            throw RouterError.haloStale(tile, expected: epoch - 1, found: 0)
        case .read(let e, let locals):
            guard e == epoch - 1, regs.isSubset(of: locals) else {
                throw RouterError.haloStale(tile, expected: epoch - 1, found: e)
            }
        }
    }

    /// `regenerateStaleLowerStrip` as the plan sees it: it loads the
    /// source, refuses a source whose committed body is not at `epoch`, takes
    /// its registers' bytes from the previous strip, and writes the strip.
    private func planRegenerate(_ s: UInt32, epoch: UInt64, plan: inout WritePlan,
                                tiles: inout [UInt32: PlanTile]) throws {
        if tiles[s] == nil {
            tiles.merge(try preflightTileLoads([s])) { a, _ in a }
        }
        let committed = plan.committed[s] ?? 0
        guard committed == epoch else { throw RouterError.haloStale(s, expected: epoch, found: committed) }
        try planPreviousStrip(s, epoch: epoch, &plan, tiles)
        try planStripWrite(s, epoch: epoch, &plan)
    }

    /// One ghost read of tile `r` at world tick `k`, as `ghostTruth` makes
    /// it, against the plan. A source tile ticked earlier in this pass is
    /// read from its pre-latch byte, its resident buffer or the strip it just
    /// wrote: each carries every local `planGhostReference` lets through.
    private func planGhost(reader r: UInt32, _ g: (tile: UInt32, local: UInt64), k: UInt64, mode: TickMode,
                           ticked: Set<UInt32>, plan: inout WritePlan, tiles: inout [UInt32: PlanTile]) throws {
        if ghostForced[try GlobalNodeID(tileId: g.tile, localNodeId: g.local).raw] != nil { return }
        try planGhostReference(reader: r, g, tiles: tiles, plan)
        if mode == .rank, ticked.contains(g.tile), tiles[g.tile]?.registers.contains(g.local) ?? false { return }
        let effective: TickMode = ghostPopulationDisabled ? .sync : mode
        if effective == .rank, ticked.contains(g.tile) { return }
        let expected: UInt64 = effective == .rank ? k : (k == 1 ? 0 : k - 1)
        switch planStrip(g.tile, parity: expected % 2, &plan) {
        case .unreadable(let e):
            throw Self.stripUnreadable(g.tile, parity: expected % 2, e)
        case .read(let e, let locals) where e == expected && locals.contains(g.local):
            return
        case .read:
            try planRegenerate(g.tile, epoch: expected, plan: &plan, tiles: &tiles)
        }
    }

    /// `worldTick`'s call planned before its first write. The
    /// call's last world tick fits the body's 32-bit field. Then its
    /// first world tick, tile by tile in the round's order: every ghost read
    /// and every strip write. Later world ticks of the same
    /// call read only strips this router wrote at the epoch they expect (rank:
    /// the source's strip of this round; sync: the source's strip of the
    /// round before), each carrying the source's `crossingsIn` locals, so the
    /// first world tick stands for all of them. Every refusal is counted
    /// against the tile at whose turn the round would have raised it.
    private func preflightRound(order: [UInt32], mode: TickMode, count: Int,
                                tiles initial: [UInt32: PlanTile]) throws {
        let mx = tileEpoch.values.max() ?? 0
        let (last, overflow) = mx.addingReportingOverflow(UInt64(count))
        if overflow || last > UInt64(UInt32.max), let first = order.first {
            let k = mx == UInt64.max ? mx : max(mx + 1, UInt64(UInt32.max) + 1)
            let e = RouterError.tileEpochUnrepresentable(first, epoch: k, limit: UInt64(UInt32.max))
            recordRefusal(first, e)
            throw e
        }
        var plan = WritePlan(committed: tileEpoch, carried: carriedLocals())
        var tiles = initial
        var ticked: Set<UInt32> = []
        let k = mx + 1
        for r in order {
            do {
                for g in tiles[r]?.ghostSources ?? [] {
                    try planGhost(reader: r, g, k: k, mode: mode, ticked: ticked, plan: &plan, tiles: &tiles)
                }
                try planFlush(r, epoch: k, &plan)
            } catch {
                recordRefusal(r, error)
                throw error
            }
            ticked.insert(r)
        }
    }

    /// Recovery of tile `t`'s dangling BEGIN at `epoch`, as
    /// `recoverDanglingFlushes` runs it, against the plan.
    private func planRecovery(_ t: UInt32, epoch k: UInt64, mode: TickMode, plan: inout WritePlan,
                              tiles: inout [UInt32: PlanTile]) throws {
        let (_, bodyEpoch) = try TiledGraphFiles.peekTileEpochs(
            dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: t)
        guard k >= 1 else {
            throw RouterError.tileFlushMalformed(
                t, detail: "flush.wal's dangling BEGIN records epoch 0; every flush writes an "
                    + "epoch >= 1, and recovery's own epoch - 1 has no value at 0")
        }
        if bodyEpoch == k - 1 {
            // Case (i): the re-tick reads every ghost from its source's strip.
            let expected: UInt64 = mode == .rank ? k : k - 1
            for g in tiles[t]?.ghostSources ?? [] {
                try planGhostReference(reader: t, g, tiles: tiles, plan)
                switch planStrip(g.tile, parity: expected % 2, &plan) {
                case .unreadable(let e):
                    throw Self.stripUnreadable(g.tile, parity: expected % 2, e)
                case .read(let e, let locals):
                    guard e == expected, locals.contains(g.local) else {
                        throw RouterError.haloStale(g.tile, expected: expected, found: e)
                    }
                }
            }
            try planFlush(t, epoch: k, &plan)
        } else if bodyEpoch == k {
            // Case (ii): the strip, meta, manifest entry and COMMIT from the body.
            try planPreviousStrip(t, epoch: k, &plan, tiles)
            try planStripWrite(t, epoch: k, &plan)
            plan.committed[t] = k
        } else {
            throw RouterError.tileInconsistent(t, metaEpoch: k, bodyEpoch: bodyEpoch)
        }
    }

    /// The partial round's completion, as `completePartialRoundIfTorn` runs
    /// it after recovery, against the plan: the mode at the max epoch (the
    /// tiles there; recovery appends no BEGIN), then every tile below it in
    /// that mode's order, its ghost reads and its strip write.
    private func planCompletion(plan: inout WritePlan, tiles: inout [UInt32: PlanTile]) throws {
        let mn = plan.committed.values.min() ?? 0
        let mx = plan.committed.values.max() ?? 0
        guard mn < mx else { return }
        var modesAtMax: [UInt32: String] = [:]
        for (t, ep) in plan.committed where ep == mx {
            guard let dir = try? tileDir(t), let token = try committedMode(t, dir: dir, epoch: mx) else { continue }
            modesAtMax[t] = token
        }
        let distinct = Set(modesAtMax.values)
        guard distinct.count <= 1 else { throw RouterError.partialRoundModeMismatch(modesAtMax) }
        guard let token = distinct.first, let mode = TickMode(walToken: token) else {
            throw RouterError.worldTorn(min: mn, max: mx)
        }
        let ids = manifest.tiles.map { $0.id }
        let order = mode == .rank ? ids.sorted(by: >) : ids.sorted(by: <)
        var ticked: Set<UInt32> = []
        for t in order where (plan.committed[t] ?? 0) < mx {
            do {
                for g in tiles[t]?.ghostSources ?? [] {
                    try planGhost(reader: t, g, k: mx, mode: mode, ticked: ticked, plan: &plan, tiles: &tiles)
                }
                try planFlush(t, epoch: mx, &plan)
            } catch {
                recordRefusal(t, error)
                throw error
            }
            ticked.insert(t)
        }
    }

    /// A refused tile load, counted in `status()` whatever the
    /// error's type. Counting only `RouterError`s would let a body the
    /// load's own validation refused (`DagDBSnapshot.SnapError`) leave
    /// `refused=0 last=none`. A tile id the manifest does not hold is not a
    /// refused tile (the daemon answers it as an out-of-range node).
    private func recordRefusal(_ tileId: UInt32, _ error: Error) {
        if let fe = error as? TiledGraphFiles.FilesError, case .tileEntryMissing = fe { return }
        refusals.append((tileId, Reply.errorWords(error)))
    }

    /// One tile's tick at epoch `k` in
    /// `mode`, then its command buffer's status, read off the tile engine's
    /// `gpuFailure`, which is cleared before the tick. Any
    /// status but completed claims nothing of the tick: the engine is
    /// dropped from the tick-resident set, the caller flushes nothing, and
    /// `RouterError.tileGPUFailure` is thrown. Every tile tick goes through
    /// here: `tickAndFlushOneTile` (a `worldTick` round, and a partial
    /// round's completion at open) and recovery case (i).
    private func tickTileChecked(_ tile: TickResidentTile, k: UInt64, mode: TickMode) throws {
        tile.engine.clearGPUFailure()
        switch mode {
        case .rank: tile.engine.tick(tickNumber: UInt32(truncatingIfNeeded: k))
        case .sync: tile.engine.tickSync(tickNumber: UInt32(truncatingIfNeeded: k))
        }
        guard let failure = tile.engine.gpuFailure else { return }
        if tickResident[tile.id] === tile {
            tickResident[tile.id] = nil
            tickLru.removeAll { $0 == tile.id }
        }
        roundRegisterPreLatch[tile.id] = nil
        let epochs = Array(tileEpoch.values)
        throw RouterError.tileGPUFailure(TileGPUFailure(
            tile: tile.id, epoch: k, failure: failure, tick: nil, of: nil,
            tilesAtEpoch: epochs.filter { $0 == k }.count, tileCount: epochs.count,
            epochMin: epochs.min() ?? 0, epochMax: epochs.max() ?? 0))
    }

    /// `local id -> truth byte` for every register in `tile`, read off the
    /// engine as it stands. Called before the tick, so the bytes are the
    /// registers' pre-latch values (`truthPre` in the strip, in both modes).
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
    /// must carry — the regeneration half of the two-byte strip.
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
        // An over-budget strip is refused by its admission's name, never read
        // as a stale one.
        var read: (epoch: UInt64, values: [UInt64: (pre: UInt8, post: UInt8, type: UInt8)])? = nil
        do {
            read = try TiledGraphFiles.readLowerStrip(
                dataRoot: dataRoot, name: graphName, manifest: manifest,
                tileId: tileId, parity: previous % 2
            )
        } catch DaemonFile.Refusal.admission(let line) {
            throw DaemonFile.Refusal.admission(line)
        } catch {
            read = nil
        }
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
    /// `init` only (`recover` is not public; a reader
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

            // `beginEpoch - 1` on UInt64 would underflow for a
            // hand-written `TILE_FLUSH_BEGIN … 0 …`. `flushState`
            // classifies a BEGIN at epoch 0 as TORN rather than pending, so
            // it cannot reach here; this is the belt that makes the
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
                    // The interrupted tick's own byte — rank
                    // took `truthPre` from the `k` strip, sync `truthPost`
                    // from the `k − 1` one.
                    ptr[n + g] = (mode == .rank) ? v.pre : v.post
                }
                let preLatch = registerPreLatchBytes(tile: tile)
                // A failed status flushes nothing; the dangling
                // BEGIN stays, so the next writer open recovers it again.
                try tickTileChecked(tile, k: k, mode: mode)
                // Under the dangling BEGIN (no second one).
                _ = try flushTile(tile: tile, epoch: k, mode: mode, registerPreLatch: preLatch,
                                  pass: .recovery, beginLogged: true)
                // Recovery re-establishes this tile in the tick-resident
                // set so a following worldTick sees the recovered state
                // without a redundant reload.
                if tickResident.count >= maxResidentTiles { evictTickLRU() }
                tickResident[tileId] = tile
                touchTick(tileId)
            } else if bodyEpoch == beginEpoch {
                // Case (ii): body already correct — regenerate strip + meta + manifest, commit.
                //
                // BOTH truth bytes are reconstructed.
                // `truthPost` comes straight off the committed body at k;
                // `truthPre` is the same for every combinational entry and,
                // for a register, its own `truthPost` in the
                // previous-parity strip (its value at k − 1 is its
                // pre-latch value at k). Writing the post-latch byte for
                // registers here would not be out of reach for a rank-mode
                // reader — a rank-mode partial-round completion at k reads
                // exactly this regenerated strip.
                let loaded = try TiledGraphFiles.loadTileWithGhosts(
                    dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: tileId,
                    ignorePendingFlush: true
                )
                let k = beginEpoch
                let preLatch = try registerPreLatchFromPreviousStrip(
                    tileId: tileId, engine: loaded.engine,
                    realNodeCount: loaded.realNodeCount, epoch: k
                )
                let dir = try tileDir(tileId)
                // Every step whole or not at all, a failed one
                // named (the dangling BEGIN stays: the next open does this
                // again); first the body's sidecar, which a crash between the
                // rename and its write left out (the flush's own check never
                // ran), so the tile commits as a never-failed one does.
                var step = FlushStep.bodySidecar
                do {
                    // The body's hash streamed through the read helper (no copy of its size).
                    let bodyHash = try DaemonFile.digest("\(dir)/body.dags").map { String(format: "%02x", $0) }.joined()
                    if (try? Self.checkSidecar(dir: dir, digest: bodyHash)) == nil {
                        try TiledGraphFiles.writeFileAtomically(
                            Data((bodyHash + "\n").utf8), to: "\(dir)/body.dags.sha256",
                            mid: seamMid(.sidecarRewriteMid, tileId, k, .recovery))
                        try seamAt(.sidecarRewriteDone, tileId, k, .recovery)
                    }
                    step = .strip
                    _ = try TiledGraphFiles.writeLowerStrip(
                        dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: tileId,
                        engine: loaded.engine, realNodeCount: loaded.realNodeCount, epoch: k,
                        preLatchOverrides: preLatch, mid: seamMid(.stripMid, tileId, k, .recovery)
                    )
                    try seamAt(.stripDone, tileId, k, .recovery)
                    step = .meta
                    var meta = loaded.meta
                    meta.lastPersistedTickEpoch = k
                    try TiledGraphFiles.writeMeta(
                        dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: tileId, meta: meta,
                        mid: seamMid(.metaMid, tileId, k, .recovery)
                    )
                    try seamAt(.metaDone, tileId, k, .recovery)
                    step = .manifest
                    try refreshManifestEntry(tileId: tileId, bodySHA256: bodyHash, tickEpoch: k,
                                             mid: seamMid(.manifestMid, tileId, k, .recovery))
                    try seamAt(.manifestDone, tileId, k, .recovery)
                    step = .commit
                    try TiledGraphFiles.appendFlushWAL(
                        path: "\(dir)/flush.wal", record: "TILE_FLUSH_COMMIT \(tileId) \(k)",
                        mid: seamMid(.commitMid, tileId, k, .recovery)
                    )
                    try seamAt(.commitDone, tileId, k, .recovery)
                } catch {
                    throw writeFailure(tile: tileId, epoch: k, pass: .recovery, step: step, error: error)
                }
            } else {
                throw RouterError.tileInconsistent(tileId, metaEpoch: beginEpoch, bodyEpoch: bodyEpoch)
            }

            pendingRecoveryTiles.removeValue(forKey: tileId)
            count += 1
        }

        return count
    }

    /// Completes a partial round left by a between-tiles interruption
    /// (every `flush.wal` clean, entries mixed): ticks only the tiles below
    /// the max epoch, in the round's own mode's order, AT the max epoch,
    /// with that round's own inputs (rank: sources' strips at max; sync:
    /// sources' strips at max − 1), refusing `haloStale` otherwise. The
    /// round's mode comes from the tiles already AT max — their own last
    /// committed `TILE_FLUSH_BEGIN` record (never a caller-supplied
    /// mode); disagreement among them refuses
    /// `partialRoundModeMismatch` with nothing rewritten. A no-op
    /// (returns 0) when every tile already agrees. Returns the count
    /// ticked (`OpenReport.completed`).
    private func completePartialRoundIfTorn() throws -> Int {
        let mn = tileEpoch.values.min() ?? 0
        let mx = tileEpoch.values.max() ?? 0
        guard mn < mx else { return 0 }

        var modesAtMax: [UInt32: String] = [:]
        for (tileId, ep) in tileEpoch where ep == mx {
            guard let dir = try? tileDir(tileId), let token = try committedMode(tileId, dir: dir, epoch: mx) else { continue }
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
            _ = try tickAndFlushOneTile(tileId: t, k: mx, mode: mode, tickedThisRound: &tickedThisRound,
                                        pass: .completion)
            completed += 1
        }
        return completed
    }

    /// Tile `t`'s last committed BEGIN
    /// mode at `epoch`; a wal that cannot be read refused by name (never
    /// read as "no record").
    private func committedMode(_ t: UInt32, dir: String, epoch: UInt64) throws -> String? {
        do {
            return try TiledGraphFiles.committedBeginMode(dir: dir, epoch: epoch)
        } catch {
            throw RouterError.tileFlushUnreadable(t, detail: Reply.carriedLine(error) ?? Reply.errorWords(error))
        }
    }

    /// Every torn last wal record a
    /// writer `init` set aside, cut (ascending tile id), after the open's
    /// plan has passed and before recovery's first write. The record's append
    /// never returned, so its step never started: the cut leaves the wal its
    /// whole records, the state the plan read. A cut that fails is a failed
    /// write step, named (`flush.wal cut`); the file is unchanged.
    private func cutTornTails() throws {
        for t in tornTails.keys.sorted() {
            guard let cut = tornTails[t] else { continue }
            do {
                try TiledGraphFiles.cutTornTail(dir: try tileDir(t), keep: cut.keep)
            } catch {
                throw writeFailure(tile: t, epoch: tileEpoch[t] ?? 0, pass: .recovery, step: .cut, error: error)
            }
            tornTails[t] = nil
        }
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
    /// the regeneration tests' "loads +N, evicts +N" assertions read off the
    /// same place the residency tests' do.
    /// Package-internal (not `private`) so tiled-ticking tests can drive the
    /// regeneration choreography directly, isolated from a whole `worldTick`
    /// round's other per-tile loads/evicts (a test pins its exact cost —
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
        // This path's loads count in `loadCount`, and its REFUSALS and
        // `maxResidentSeen` are recorded too, so `status()` reports the
        // ticker as fully as the query path.
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
        } catch {
            recordRefusal(tileId, error)    // every refused load, not only RouterError
            throw error
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
        k: UInt64, mode: TickMode, tickedThisRound: Set<UInt32>, pass: TiledWritePass = .round
    ) throws -> UInt8 {
        // A register is never written by the
        // combinational pass, so the byte its readers must see at world
        // tick k is the one it held BEFORE this tick's latch — which is
        // also its value at the end of tick k − 1. In rank mode that is
        // what the strip carries and what the live buffer must be
        // overridden with; it is also already "the previous world tick's
        // value", so the test-only ghost-population switch leaves it alone (a
        // register carries no fresh information across a boundary to
        // delete). Checked before everything else, and against `mode`
        // rather than the switch's effective mode, so all three paths —
        // resident buffer, committed strip, ghosts-disabled — agree.
        if mode == .rank, tickedThisRound.contains(sourceTile),
           let preLatch = roundRegisterPreLatch[sourceTile]?[sourceLocal] {
            return preLatch
        }

        // The test-only switch makes rank mode source its ghosts the way
        // sync mode does — the previous world tick's committed values.
        let effectiveMode: TickMode = ghostPopulationDisabled ? .sync : mode

        if effectiveMode == .rank, let resident = tickResident[sourceTile], tickedThisRound.contains(sourceTile) {
            // `sourceLocal` is a 40-bit local id out of `meta.crossingsOut`;
            // this fast path bounds it, as `truth(of:)` does. Unchecked, an
            // out-of-range crossing would read past the end of the source
            // tile's buffer and feed the result to a ghost.
            guard sourceLocal < UInt64(resident.realNodeCount) else {
                throw RouterError.crossTileBoundsExceeded(sourceTile)
            }
            let ptr = resident.engine.truthStateBuf.contents().bindMemory(
                to: UInt8.self, capacity: resident.realNodeCount + resident.ghostCount)
            return ptr[Int(sourceLocal)]
        }

        // Which of the strip's two truth bytes is this
        // reader's. A rank-mode ghost takes `truthPre` from the source's
        // strip at k (the value before that round's latch, which is what
        // the untiled engine shows a reader of a register); a sync-mode
        // ghost takes `truthPost` from the parity k − 1 strip (the previous
        // world tick's vector). One file, two readers, no contradiction —
        // and a round whose mode differs from the round before it reads
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
                readerTileId: readerTileId, sourceTileId: sourceTile, expectedEpoch: expectedEpoch, pass: pass
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

    /// The regeneration choreography. `K = 1` (no free tick-resident
    /// slot): evict the reader, load the source, write its strip, evict
    /// the source, reload the reader — loads +2, evicts +2. `K ≥ 2` with
    /// a free slot: load the source into it and leave both resident —
    /// loads +1, evicts +0. Refuses (never writes a strip) if the
    /// source's own committed body is itself behind `expectedEpoch`.
    ///
    /// The strip's write is whole or not at all
    /// (`writeFileAtomically`); a failure throws `RouterError.tileWriteFailed`
    /// naming it (the source's strip unchanged, the reader not ticked).
    func regenerateStaleLowerStrip(
        readerTileId: UInt32, sourceTileId: UInt32, expectedEpoch: UInt64, pass: TiledWritePass = .round
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
        // Both bytes, same rule as recovery case (ii) —
        // `truthPost` off the committed body at `expectedEpoch`,
        // `truthPre` for a register out of the previous-parity strip.
        let preLatch = try registerPreLatchFromPreviousStrip(
            tileId: sourceTileId, engine: source.engine,
            realNodeCount: source.realNodeCount, epoch: expectedEpoch
        )
        do {
            _ = try TiledGraphFiles.writeLowerStrip(
                dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: sourceTileId,
                engine: source.engine, realNodeCount: source.realNodeCount, epoch: expectedEpoch,
                preLatchOverrides: preLatch, mid: seamMid(.regenerateMid, sourceTileId, expectedEpoch, pass)
            )
            try seamAt(.regenerateDone, sourceTileId, expectedEpoch, pass)
        } catch {
            throw writeFailure(tile: sourceTileId, epoch: expectedEpoch, pass: pass, step: .regenerate,
                               error: error, reader: readerTileId)
        }

        if evictedReader {
            tickResident[sourceTileId] = nil
            tickLru.removeAll { $0 == sourceTileId }
            evictCount += 1
            _ = try tickLoad(tileId: readerTileId)
        }
    }

    /// Per-tile flush, in this exact order: BEGIN
    /// (the WAL record carrying the mode), body
    /// (atomic snapshot, real nodes only via a real-size scratch copy of
    /// the ghosted engine), strip, meta, manifest entry (`bodySHA256` +
    /// `tickEpoch`, one authority for both the query path and the
    /// ticker), COMMIT. Returns the elapsed ms and the strip's byte
    /// count (`haloBytes`).
    ///
    /// Every step is
    /// whole or not at all — the wal records are appended whole or cut back
    /// (`appendFlushWAL`), the body is a tmp file renamed over the old one
    /// (`DagDBSnapshot.save`), the strip, meta and manifest go through a temp
    /// file and a rename (`writeFileAtomically`) — and the body's sidecar is
    /// checked after the save, which swallows a failed sidecar write: a tile
    /// never commits without it. A step that fails throws
    /// `RouterError.tileWriteFailed` naming it, with nothing after it
    /// written: after a failure before the rename the next writer open
    /// re-ticks the tile (recovery case (i)); after it, it completes the
    /// flush from the body (case (ii)). `beginLogged`: recovery case (i)
    /// re-flushes under the dangling BEGIN it recovers, so the tile's wal
    /// ends `BEGIN k, COMMIT k` as a never-failed tile's does (no second
    /// BEGIN is appended). `pass` labels the seam's events.
    private func flushTile(
        tile: TickResidentTile, epoch: UInt64, mode: TickMode,
        registerPreLatch: [UInt64: UInt8] = [:], pass: TiledWritePass = .round, beginLogged: Bool = false
    ) throws -> (ms: Double, haloBytes: Int) {
        // The epoch is UInt64 in the manifest, in meta.json and in
        // flush.wal, but `body.dags`'s tick field is 32 bits —
        // `UInt32(truncatingIfNeeded:)` would wrap it silently at both the
        // tick call and the save, and past 2^32 the body-vs-meta equality
        // check would then refuse every subsequent load of the whole world.
        // Refused here, BEFORE the BEGIN record is appended, so a refused
        // flush leaves the wal untouched. Widening that header field is left
        // for a later format change.
        guard epoch <= UInt64(UInt32.max) else {
            throw RouterError.tileEpochUnrepresentable(
                tile.id, epoch: epoch, limit: UInt64(UInt32.max))
        }
        let t0 = Date()
        let t = tile.id
        let dir = try tileDir(t)
        let walPath = "\(dir)/flush.wal"
        var step = FlushStep.begin
        var haloBytes = 0
        do {
            if !beginLogged {
                try TiledGraphFiles.appendFlushWAL(
                    path: walPath, record: "TILE_FLUSH_BEGIN \(t) \(epoch) \(mode.walToken)",
                    mid: seamMid(.beginMid, t, epoch, pass))
                try seamAt(.beginDone, t, epoch, pass)
            }

            step = .bodyTmp
            let scratch = try TiledGraphFiles.scratchRealEngine(from: tile.engine, realNodeCount: tile.realNodeCount)
            let seam = writeSeam
            let event = { (p: TiledWritePoint) in TiledWriteEvent(point: p, tile: t, epoch: epoch, pass: pass) }
            _ = try DagDBSnapshot.save(
                engine: scratch, nodeCount: tile.realNodeCount, gridW: tile.realNodeCount, gridH: 1,
                tickCount: UInt32(truncatingIfNeeded: epoch), path: "\(dir)/body.dags",
                stepHook: { s in
                    switch s {
                    case .tmpWritten:
                        try seam?(event(.bodyTmpDone))
                        step = .bodyRename
                    case .oldManifestRemoved:
                        try seam?(event(.bodyOldSidecarRemoved))
                    case .renamed:
                        step = .bodySidecar
                        try seam?(event(.bodyRenamed))
                    case .manifestWritten:
                        try seam?(event(.bodySidecarDone))
                    }
                }
            )
            step = .bodySidecar
            // The body just written, hashed back through the read helper (streamed).
            let bodyHash = try DaemonFile.digest("\(dir)/body.dags").map { String(format: "%02x", $0) }.joined()
            try Self.checkSidecar(dir: dir, digest: bodyHash)

            step = .strip
            haloBytes = try TiledGraphFiles.writeLowerStrip(
                dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: t,
                engine: tile.engine, realNodeCount: tile.realNodeCount, epoch: epoch,
                preLatchOverrides: registerPreLatch, mid: seamMid(.stripMid, t, epoch, pass)
            )
            try seamAt(.stripDone, t, epoch, pass)

            step = .meta
            var meta = tile.meta
            meta.lastPersistedTickEpoch = epoch
            try TiledGraphFiles.writeMeta(
                dataRoot: dataRoot, name: graphName, manifest: manifest, tileId: t, meta: meta,
                mid: seamMid(.metaMid, t, epoch, pass)
            )
            tile.meta = meta
            try seamAt(.metaDone, t, epoch, pass)

            step = .manifest
            try refreshManifestEntry(tileId: t, bodySHA256: bodyHash, tickEpoch: epoch,
                                     mid: seamMid(.manifestMid, t, epoch, pass))
            try seamAt(.manifestDone, t, epoch, pass)

            step = .commit
            try TiledGraphFiles.appendFlushWAL(path: walPath, record: "TILE_FLUSH_COMMIT \(t) \(epoch)",
                                               mid: seamMid(.commitMid, t, epoch, pass))
            try seamAt(.commitDone, t, epoch, pass)
        } catch {
            throw writeFailure(tile: t, epoch: epoch, pass: pass, step: step, error: error)
        }
        return (Date().timeIntervalSince(t0) * 1000.0, haloBytes)
    }

    // MARK: - Write steps, the seam, a failed step

    /// The write steps of a tile's flush, of recovery case (ii), and of a
    /// strip regeneration.
    private enum FlushStep {
        case begin, bodyTmp, bodyRename, bodySidecar, strip, meta, manifest, commit, regenerate
        /// A writer open's cut of a torn last wal record.
        case cut
    }

    private func seamAt(_ p: TiledWritePoint, _ tile: UInt32, _ epoch: UInt64, _ pass: TiledWritePass) throws {
        try writeSeam?(TiledWriteEvent(point: p, tile: tile, epoch: epoch, pass: pass))
    }

    /// The `mid` closure a write helper runs with half its bytes written;
    /// nil without a seam (production).
    private func seamMid(_ p: TiledWritePoint, _ tile: UInt32, _ epoch: UInt64,
                         _ pass: TiledWritePass) -> (() throws -> Void)? {
        guard let seam = writeSeam else { return nil }
        let ev = TiledWriteEvent(point: p, tile: tile, epoch: epoch, pass: pass)
        return { try seam(ev) }
    }

    /// `DagDBSnapshot.save` writes the body's sidecar with
    /// `try?` (a failure is swallowed), and a tile committed without it
    /// is not the tile a never-failed flush leaves. Checked after the save,
    /// before anything else of the flush is written.
    static func checkSidecar(dir: String, digest: String) throws {
        let path = "\(dir)/body.dags.sha256"
        // Read once, bounded, as a regular file inside the root (absent: nil; any
        // other refusal thrown by name, never read as absent).
        let found = try DaemonFile.readIfPresent(path, .atMost(DagDBSnapshot.manifestMaxBytes))
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard found == digest else {
            throw TiledGraphFiles.WriteError.sidecar(path: path, found: found)
        }
    }

    /// The failed step as `RouterError.tileWriteFailed`: its name, the error,
    /// what the tile's files hold now and what a writer open does with them.
    /// `reader`: the tile whose ghost staging regenerated `tile`'s strip.
    private func writeFailure(tile t: UInt32, epoch k: UInt64, pass: TiledWritePass, step: FlushStep,
                              error: Error, reader: UInt32? = nil) -> Error {
        if case RouterError.tileWriteFailed = error { return error }
        var torn = false
        if case TiledGraphFiles.WriteError.walTorn = error { torn = true }
        let tornText = "tile \(t)'s flush.wal ends in a torn record: TILED TICK refuses the tile; a writer TILED "
            + "OPEN cuts the record (its append never started its step) and recovers per the records before it"
        let caseI = "tile \(t)'s body at epoch \(k == 0 ? 0 : k - 1) and its flush.wal ends in BEGIN \(k): "
            + "a writer TILED OPEN re-ticks it (recovery case (i))"
        let caseII = "tile \(t)'s body at epoch \(k) and its flush.wal ends in BEGIN \(k): "
            + "a writer TILED OPEN completes its flush (recovery case (ii))"
        let name: String, left: String, pending: Bool
        switch step {
        case .begin:
            name = "flush.wal BEGIN"; pending = false
            left = torn ? tornText : "tile \(t)'s flush.wal cut back, its files unchanged at epoch \(k == 0 ? 0 : k - 1)"
        case .bodyTmp:
            name = "body.dags.tmp"; pending = true; left = caseI
        case .bodyRename:
            name = "body.dags rename"; pending = true; left = caseI
        case .bodySidecar:
            name = "body.dags.sha256"; pending = true; left = caseII
        case .strip:
            name = "halo_lower.\(k % 2).bin"; pending = true; left = caseII
        case .meta:
            name = "meta.json"; pending = true; left = caseII
        case .manifest:
            name = "manifest.json"; pending = true; left = caseII
        case .commit:
            name = "flush.wal COMMIT"; pending = true; left = torn ? tornText : caseII
        case .cut:
            name = "flush.wal cut"; pending = false
            left = "tile \(t)'s flush.wal unchanged, still ending in its torn record (the next writer TILED OPEN "
                + "cuts it); nothing else written"
        case .regenerate:
            name = "halo_lower.\(k % 2).bin"; pending = false
            left = "tile \(t)'s strip unchanged: its regeneration for tile \(reader.map(String.init) ?? "?")'s "
                + "ghosts failed, tile \(reader.map(String.init) ?? "?") not ticked"
        }
        let epochs = Array(tileEpoch.values)
        return RouterError.tileWriteFailed(TileWriteFailure(
            tile: t, epoch: k, pass: pass, step: name, errorWords: Reply.errorWords(error), carriedLine: Reply.carriedLine(error),
            left: left, pending: pending && !torn,
            walTorn: torn,
            tick: nil, of: nil, tilesAtEpoch: epochs.filter { $0 == k }.count, tileCount: epochs.count,
            epochMin: epochs.min() ?? 0, epochMax: epochs.max() ?? 0))
    }

    /// Rewrites tile `tileId`'s manifest entry (`bodySHA256`,
    /// `tickEpoch`) atomically (`TiledGraphFiles.writeManifest` — temp
    /// file in the same directory, then rename) and updates the router's
    /// own cached `manifest`/`tileEpoch` in lockstep — cache the decoded
    /// manifest, update the entry in
    /// memory before writing, never re-decode per tile.
    private func refreshManifestEntry(tileId: UInt32, bodySHA256: String, tickEpoch: UInt64,
                                      mid: (() throws -> Void)? = nil) throws {
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
        try TiledGraphFiles.writeManifest(dataRoot: dataRoot, name: graphName, manifest: newManifest, mid: mid)
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
    /// recorded and rethrown — never loaded silently.
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
        } catch {
            recordRefusal(tileId, error)    // every refused load, not only RouterError
            throw error
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
