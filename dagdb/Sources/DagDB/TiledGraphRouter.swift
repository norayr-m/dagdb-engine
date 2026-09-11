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
public struct Crossing: Codable, Sendable, Hashable {
    public let localNode: UInt64
    public let remoteNode: GlobalNodeID

    public init(localNode: UInt64, remoteNode: GlobalNodeID) {
        self.localNode = localNode
        self.remoteNode = remoteNode
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

    public var description: String {
        switch self {
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
    public let manifest: TiledGraphFiles.Manifest

    private var residentTiles: [UInt32: ResidentTile] = [:]
    /// Least-recently-used at the front, most-recently-used at the back.
    private var lruOrder: [UInt32] = []
    private var totalTickCount: UInt64 = 0

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
    public init(dataRoot: String, graphName: String, maxResidentTiles: Int = 2) async throws {
        self.dataRoot = dataRoot
        self.graphName = graphName
        self.maxResidentTiles = maxResidentTiles
        do {
            self.manifest = try TiledGraphFiles.readManifest(dataRoot: dataRoot, name: graphName)
        } catch TiledGraphFiles.FilesError.manifestMissing(let path) {
            throw RouterError.manifestMissing(path)
        }
        var cin: [UInt32: [Crossing]] = [:]
        for entry in self.manifest.tiles {
            cin[entry.id] = entry.crossingsIn
        }
        self.crossingsInByTile = cin
    }

    // MARK: public surface

    public func status() -> TiledStatus {
        TiledStatus(
            dataRoot: dataRoot,
            graphName: graphName,
            residentTileCount: residentTiles.count,
            maxResidentTiles: maxResidentTiles,
            totalTickCount: totalTickCount,
            loads: loadCount,
            evicts: evictCount,
            refused: refusals.count,
            lastRefusal: refusals.last.map { "tile \($0.0): \($0.1)" },
            maxResidentSeen: maxResidentSeenCount
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
            maxResidentSeenCount = max(maxResidentSeenCount, residentTiles.count)
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
