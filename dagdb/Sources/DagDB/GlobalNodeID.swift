/// GlobalNodeID — u64 cross-tile node addressing for tiled DagDB graphs.
///
/// Single-engine DagDB uses Int32 node IDs internal to one tile. Once
/// the graph spans multiple tiles (tile streaming, see
/// `docs/tiled-streaming.md`), nodes need to be addressable across
/// tile boundaries. GlobalNodeID is the wire format for that.
///
/// Encoding (most-significant first):
///
///   bits 63..40   tileId        24 bits  →  up to 16,777,216 tiles
///   bits 39..0    localNodeId   40 bits  →  up to ~1.1 trillion nodes per tile
///
///   total                       64 bits  →  ~1.8 × 10¹⁹ unique IDs
///
/// 16 M tiles × 1 T local IDs is well above the 10¹¹-node target the
/// tile-streaming spec aims at; the headroom is intentional so the
/// encoding doesn't have to change again.
///
/// Within a tile, the engine continues to use `Int32` neighbor slots —
/// the spec keeps single-tile capacity ≤ ~10⁹ which fits the i32 range
/// comfortably (and avoids the ~40 % UMA hit a u64-neighbor buffer
/// would impose). GlobalNodeID is the *router-and-serialization*
/// surface, not the in-tile evaluation surface.

import Foundation

public struct GlobalNodeID: Hashable, Equatable, Sendable {

    /// The full 64-bit packed identifier.
    public let raw: UInt64

    public init(raw: UInt64) {
        self.raw = raw
    }

    public enum DecodingError: Error, CustomStringConvertible {
        case tileIdOverflow(UInt32)
        case localIdOverflow(UInt64)
        case tileMismatch(expected: UInt32, found: UInt32)
        case localIdTooLargeForInt32(UInt64)

        public var description: String {
            switch self {
            case .tileIdOverflow(let v):
                return "GlobalNodeID: tileId \(v) exceeds 24-bit max (16,777,215)"
            case .localIdOverflow(let v):
                return "GlobalNodeID: localNodeId \(v) exceeds 40-bit max"
            case .tileMismatch(let expected, let found):
                return "GlobalNodeID: cross-tile reference (current tile=\(expected), id is in tile=\(found))"
            case .localIdTooLargeForInt32(let v):
                return "GlobalNodeID: localNodeId \(v) exceeds Int32.max — this tile is too large for legacy i32 lookup"
            }
        }
    }

    public init(tileId: UInt32, localNodeId: UInt64) throws {
        guard tileId < (1 << 24) else { throw DecodingError.tileIdOverflow(tileId) }
        guard localNodeId < (UInt64(1) << 40) else { throw DecodingError.localIdOverflow(localNodeId) }
        self.raw = (UInt64(tileId) << 40) | localNodeId
    }

    /// Convenience for 0-tile graphs (single-tile, pre-router).
    public init(localNodeId: UInt64) throws {
        try self.init(tileId: 0, localNodeId: localNodeId)
    }

    /// Bits 63..40, masked to 24 bits.
    public var tileId: UInt32 {
        UInt32(truncatingIfNeeded: (raw >> 40) & 0xFF_FFFF)
    }

    /// Bits 39..0, masked to 40 bits.
    public var localNodeId: UInt64 {
        raw & 0xFF_FFFF_FFFF
    }

    /// Lower the global ID to the engine-internal `Int32` form, but
    /// only when the caller already knows we're inside `currentTile`.
    /// Throws if the ID belongs to a different tile or doesn't fit i32.
    public func toLocal(currentTile: UInt32) throws -> Int32 {
        guard tileId == currentTile else {
            throw DecodingError.tileMismatch(expected: currentTile, found: tileId)
        }
        guard localNodeId <= UInt64(Int32.max) else {
            throw DecodingError.localIdTooLargeForInt32(localNodeId)
        }
        return Int32(localNodeId)
    }
}

// MARK: - Codable

extension GlobalNodeID: Codable {

    /// Encodes as the bare 64-bit integer in JSON / binary contexts.
    /// JSON readers see a single number; bincode/Plist see a UInt64.
    /// For human-readable JSON dumps, use `description` via a wrapper
    /// type instead — kept narrow here so meta.json and binary halo
    /// records share one representation.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.raw = try container.decode(UInt64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

// MARK: - Display

extension GlobalNodeID: CustomStringConvertible {
    public var description: String {
        "t\(tileId):n\(localNodeId)"
    }
}
