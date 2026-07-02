/// TiledGraphRouter — supervises tile-resident DagDB engines, routes queries.
///
/// Step 4 of `docs/tiled-streaming.md` build order. **Scaffold only**:
/// types, public signatures, minimum-viable initializer + helpers, and
/// stubs for routing primitives that will land in subsequent steps.
///
/// Live tile load / evict / pre-fetch logic is intentionally deferred:
/// those touch NVMe streaming + halo bookkeeping + the multi-engine
/// memory budget, which are their own engineering passes (steps 5–7).
/// The scaffold establishes the public surface so DSL + MCP + future
/// caller code can compile against it.
///
/// Where this scaffold diverges from the spec wording in §6.5:
///
/// - The spec uses raw `UInt64` for global node IDs. This codebase has
///   a `GlobalNodeID` value type (24-tile + 40-local u64 packing) that
///   already enforces the encoding invariants. The router takes and
///   returns `GlobalNodeID` on the public surface; the spec's free
///   `UInt64` form is recoverable as `globalId.raw`.
/// - The spec uses `HaloStrip` (the Savanna-fields name); we use
///   `DagHaloStrip` (DagDB-fields, after step 1's port).
/// - `tileId` is `UInt32` here (matching `GlobalNodeID.tileId`). The
///   spec's `UInt64` was loose — a 24-bit value comfortably fits u32.

import Foundation

// MARK: - Public types

/// Per-tile metadata stored in `meta.json`. Subset for the scaffold;
/// extend as load/save lands.
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
/// plus its halos and bookkeeping. Class because it owns a class-typed
/// `DagDBEngine` (which holds GPU buffers and isn't trivially copyable),
/// and because we mutate dirty-buffer state under actor isolation.
public final class ResidentTile {
    public let id: UInt32
    public let engine: DagDBEngine
    public let meta: TileMeta
    public let upperHalo: DagHaloStrip
    public var lowerHalo: DagHaloStrip
    public var dirtyBuffers: Set<TileBuffer>
    public var lastTickEpoch: UInt64

    public init(
        id: UInt32,
        engine: DagDBEngine,
        meta: TileMeta,
        upperHalo: DagHaloStrip,
        lowerHalo: DagHaloStrip,
        dirtyBuffers: Set<TileBuffer> = [],
        lastTickEpoch: UInt64 = 0
    ) {
        self.id = id
        self.engine = engine
        self.meta = meta
        self.upperHalo = upperHalo
        self.lowerHalo = lowerHalo
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
}

/// Errors raised by the router. Stable category names for DSL-error parity.
public enum RouterError: Error, CustomStringConvertible, Sendable {
    case notImplemented(String)
    case tileNotResident(UInt32)
    case crossTileBoundsExceeded(UInt32)
    case manifestMissing(String)

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
        }
    }
}

// MARK: - Router

public actor TiledGraphRouter {

    // MARK: stored state

    public let dataRoot: String
    public let graphName: String
    public let maxResidentTiles: Int

    private var residentTiles: [UInt32: ResidentTile] = [:]
    private var totalTickCount: UInt64 = 0

    // MARK: init

    /// Construct a router rooted at `<dataRoot>/<graphName>/`.
    /// Does NOT load any tiles yet — initialisation is split so callers
    /// can inspect status and choose which tile to load first.
    /// (Step 5 will add `loadInitialTile` / `discoverManifest` helpers.)
    public init(dataRoot: String, graphName: String, maxResidentTiles: Int = 2) async throws {
        self.dataRoot = dataRoot
        self.graphName = graphName
        self.maxResidentTiles = maxResidentTiles
    }

    // MARK: public surface (stubs where they'll grow)

    public func status() -> TiledStatus {
        TiledStatus(
            dataRoot: dataRoot,
            graphName: graphName,
            residentTileCount: residentTiles.count,
            maxResidentTiles: maxResidentTiles,
            totalTickCount: totalTickCount
        )
    }

    /// Persist all dirty tiles to disk. Stub for now — step 5 adds the
    /// per-tile flush + meta.json update + halo write.
    public func save() async throws {
        throw RouterError.notImplemented("save")
    }

    /// Drain readers, flush dirty tiles, release engines. Stub for now.
    public func close() async throws {
        throw RouterError.notImplemented("close")
    }

    /// Route an arbitrary DSL command to the right tile. The scaffold
    /// rejects everything; subsequent steps add a verb-by-verb dispatch
    /// table covering rank-localizable commands (single-tile) vs
    /// cross-tile commands (BFS, ancestry, distance metrics).
    public func runQuery(_ dsl: String) async throws -> String {
        throw RouterError.notImplemented("runQuery: \(dsl.prefix(40))…")
    }

    /// BFS with cross-tile continuation queue. Step 6 lands the queue
    /// + per-tile expansion; this stub returns notImplemented.
    public func runBFS(seed: GlobalNodeID, depth: UInt32, backward: Bool = false) async throws -> [(GlobalNodeID, UInt32)] {
        throw RouterError.notImplemented("runBFS")
    }

    /// Reverse BFS bounded by depth. Step 6 stub.
    public func runAncestry(node: GlobalNodeID, depth: UInt32) async throws -> [(GlobalNodeID, UInt32)] {
        throw RouterError.notImplemented("runAncestry")
    }

    /// Truth-by-rank-range select. Decomposable across tiles in
    /// principle (each tile contributes its own intersect with the
    /// requested rank window). Step 5+ stub.
    public func runSelect(truth: UInt8, rankLo: UInt64, rankHi: UInt64) async throws -> [GlobalNodeID] {
        throw RouterError.notImplemented("runSelect")
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

    // MARK: resident-set management (test seam, not yet wired)

    /// Test-seam to install a pre-built tile into the resident set.
    /// Step 5 adds the disk-backed `load(tileId:)` that does I/O; until
    /// then, tests can build a `ResidentTile` by hand and admit it here.
    /// Marked `internal` so it's reachable from `@testable import`.
    internal func admitResidentTile(_ tile: ResidentTile) throws {
        if residentTiles.count >= maxResidentTiles {
            throw RouterError.crossTileBoundsExceeded(tile.id)
        }
        residentTiles[tile.id] = tile
    }

    /// Test-seam — remove a tile without flushing. Real eviction will
    /// flush dirty buffers first. Reachable from `@testable import`.
    internal func dropResidentTile(_ tileId: UInt32) {
        residentTiles[tileId] = nil
    }
}
