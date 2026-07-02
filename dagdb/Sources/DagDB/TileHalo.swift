/// TileHalo — Halo Protocol for tiled DagDB graphs.
///
/// Each tile's perimeter is saved to disk after a tick. Adjacent tiles
/// load these halos as read-only ghost zones so boundary nodes can
/// reference neighbors across tile edges.
///
/// File format (binary):
///
///   magic       :  4 bytes  ASCII "DAHA"
///   version     :  4 bytes  little-endian u32, currently 1
///   strip_count :  4 bytes  little-endian u32
///   for each strip:
///     edge          : 4 bytes  u32 raw value of HaloEdge
///     width         : 4 bytes  u32
///     depth         : 4 bytes  u32 (3)
///     tick_epoch    : 8 bytes  u64
///     rank          : width × depth × 8 bytes
///     truth         : width × depth × 1 byte
///     nodeType      : width × depth × 1 byte
///     lut6Low       : width × depth × 4 bytes
///     lut6High      : width × depth × 4 bytes
///     neighbors     : width × depth × 6 × 4 bytes (Int32 slots)
///     isRegister    : width × depth × 1 byte
///
/// This file ports the Savanna NSEW spatial-halo pattern to carry DagDB's
/// node fields (rank, truth, nodeType, lut6, neighbors, isRegister).
/// The NSEW enum is the spatial-tile semantic; rank-tile halos
/// (TiledGraphRouter, future) will introduce their own RankHalo enum
/// (`upper` / `lower`) but reuse this same file-format pattern.
///
/// Step 1 of `docs/tiled-streaming.md` build order. See companion memo
/// `docs/tiled-streaming-memo-2026-04-29.md` for context.

import Foundation

/// Which edge of a spatial tile a halo strip belongs to.
public enum HaloEdge: Int, CaseIterable {
    case north = 0, east = 1, south = 2, west = 3

    /// The opposite edge — what the neighbor tile calls this strip.
    public var opposite: HaloEdge {
        switch self {
        case .north: return .south
        case .south: return .north
        case .east:  return .west
        case .west:  return .east
        }
    }

    /// Tile offset (dtx, dty) to reach the neighbor tile for this edge.
    public var tileOffset: (Int, Int) {
        switch self {
        case .north: return (0, -1)
        case .south: return (0, 1)
        case .east:  return (1, 0)
        case .west:  return (-1, 0)
        }
    }
}

/// A strip of DagDB nodes along one edge of a tile (3 cells deep).
///
/// Field set mirrors the per-node hot footprint defined in the spec:
/// rank, truth, nodeType, lut6Low, lut6High, neighbors, isRegister.
/// Cross-tile references in `neighbors` use the in-tile Int32 sentinel
/// `-2` to mark "neighbor lives in another tile" (resolved by the router
/// via meta.json crossings tables); `-1` continues to mean "empty slot."
public struct DagHaloStrip {
    public let edge: HaloEdge
    public let width: Int
    public let depth: Int
    public var tickEpoch: UInt64
    public var rank: [UInt64]
    public var truth: [UInt8]
    public var nodeType: [UInt8]
    public var lut6Low: [UInt32]
    public var lut6High: [UInt32]
    public var neighbors: [Int32]   // 6 slots per cell, row-major
    public var isRegister: [UInt8]

    public var cellCount: Int { width * depth }

    public init(edge: HaloEdge, width: Int, depth: Int = 3, tickEpoch: UInt64 = 0) {
        self.edge = edge
        self.width = width
        self.depth = depth
        self.tickEpoch = tickEpoch
        let n = width * depth
        self.rank = [UInt64](repeating: 0, count: n)
        self.truth = [UInt8](repeating: 0, count: n)
        self.nodeType = [UInt8](repeating: 0, count: n)
        self.lut6Low = [UInt32](repeating: 0, count: n)
        self.lut6High = [UInt32](repeating: 0, count: n)
        self.neighbors = [Int32](repeating: -1, count: n * 6)
        self.isRegister = [UInt8](repeating: 0, count: n)
    }
}

public enum TileHalo {

    /// File format magic bytes — "DAHA" little-endian.
    public static let magic: UInt32 = 0x4148_4144  // 'D','A','H','A'

    /// File format version. Bump when the on-disk layout changes.
    public static let version: UInt32 = 1

    /// Standard halo depth (cells).
    public static let defaultDepth = 3

    // MARK: - File paths

    public static func haloPath(dir: String, tx: Int, ty: Int) -> String {
        "\(dir)/tile_\(tx)_\(ty)_halo.bin"
    }

    public static func tileStatePath(dir: String, tx: Int, ty: Int) -> String {
        "\(dir)/tile_\(tx)_\(ty).bin"
    }

    // MARK: - Errors

    public enum HaloError: Error, CustomStringConvertible {
        case badMagic(UInt32)
        case badVersion(UInt32)
        case truncated(String)
        case badEdge(UInt32)

        public var description: String {
            switch self {
            case .badMagic(let m):    return "TileHalo: bad magic 0x\(String(m, radix: 16))"
            case .badVersion(let v):  return "TileHalo: unsupported version \(v)"
            case .truncated(let msg): return "TileHalo: truncated — \(msg)"
            case .badEdge(let v):     return "TileHalo: invalid edge \(v)"
            }
        }
    }

    // MARK: - Extract perimeter from a tile's flat row-major buffers

    /// Pull a 3-cell-deep strip from `edge` of a tile whose state is in
    /// row-major order. Caller passes the per-field arrays (sized
    /// `tileW × tileH` each, with `neighbors` sized `tileW × tileH × 6`).
    public static func extractPerimeter(
        rank: [UInt64], truth: [UInt8], nodeType: [UInt8],
        lut6Low: [UInt32], lut6High: [UInt32],
        neighbors: [Int32], isRegister: [UInt8],
        tileW: Int, tileH: Int, edge: HaloEdge,
        tickEpoch: UInt64, depth: Int = TileHalo.defaultDepth
    ) -> DagHaloStrip {
        let stripWidth: Int
        switch edge {
        case .north, .south: stripWidth = tileW
        case .east, .west:   stripWidth = tileH
        }
        var strip = DagHaloStrip(edge: edge, width: stripWidth, depth: depth, tickEpoch: tickEpoch)

        for row in 0..<depth {
            for col in 0..<stripWidth {
                let si: Int
                let ti: Int
                switch edge {
                case .north:
                    si = row * stripWidth + col
                    ti = row * tileW + col
                case .south:
                    si = row * stripWidth + col
                    ti = (tileH - depth + row) * tileW + col
                case .west:
                    si = row * stripWidth + col
                    ti = col * tileW + row
                case .east:
                    si = row * stripWidth + col
                    ti = col * tileW + (tileW - depth + row)
                }
                strip.rank[si] = rank[ti]
                strip.truth[si] = truth[ti]
                strip.nodeType[si] = nodeType[ti]
                strip.lut6Low[si] = lut6Low[ti]
                strip.lut6High[si] = lut6High[ti]
                strip.isRegister[si] = isRegister[ti]
                for k in 0..<6 {
                    strip.neighbors[si * 6 + k] = neighbors[ti * 6 + k]
                }
            }
        }
        return strip
    }

    // MARK: - Disk I/O

    /// Serialize all of a tile's halo strips to one file.
    public static func writeHalos(_ strips: [DagHaloStrip], to path: String) throws {
        var data = Data()

        var magic = TileHalo.magic
        var version = TileHalo.version
        var stripCount = UInt32(strips.count)
        data.append(Data(bytes: &magic, count: 4))
        data.append(Data(bytes: &version, count: 4))
        data.append(Data(bytes: &stripCount, count: 4))

        for s in strips {
            var edge = UInt32(s.edge.rawValue)
            var w = UInt32(s.width)
            var d = UInt32(s.depth)
            var epoch = s.tickEpoch
            data.append(Data(bytes: &edge, count: 4))
            data.append(Data(bytes: &w, count: 4))
            data.append(Data(bytes: &d, count: 4))
            data.append(Data(bytes: &epoch, count: 8))
            s.rank.withUnsafeBytes       { data.append(Data($0)) }
            s.truth.withUnsafeBytes      { data.append(Data($0)) }
            s.nodeType.withUnsafeBytes   { data.append(Data($0)) }
            s.lut6Low.withUnsafeBytes    { data.append(Data($0)) }
            s.lut6High.withUnsafeBytes   { data.append(Data($0)) }
            s.neighbors.withUnsafeBytes  { data.append(Data($0)) }
            s.isRegister.withUnsafeBytes { data.append(Data($0)) }
        }

        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Deserialize halo strips from a tile's file. Returns `nil` if the
    /// file is missing (caller treats as tick-zero / world-edge case).
    /// Throws on present-but-malformed files.
    public static func readHalos(from path: String) throws -> [DagHaloStrip]? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return nil }

        var offset = 0

        func read<T>(_ type: T.Type, count: Int, ctx: String) throws -> [T] {
            let size = count * MemoryLayout<T>.size
            guard offset + size <= data.count else { throw HaloError.truncated(ctx) }
            let result = data[offset..<offset+size].withUnsafeBytes {
                Array($0.bindMemory(to: T.self))
            }
            offset += size
            return result
        }
        func readScalar<T>(_ type: T.Type, ctx: String) throws -> T {
            try read(type, count: 1, ctx: ctx)[0]
        }

        let magic: UInt32 = try readScalar(UInt32.self, ctx: "magic")
        guard magic == TileHalo.magic else { throw HaloError.badMagic(magic) }
        let version: UInt32 = try readScalar(UInt32.self, ctx: "version")
        guard version == TileHalo.version else { throw HaloError.badVersion(version) }

        let stripCount: UInt32 = try readScalar(UInt32.self, ctx: "strip_count")

        var strips = [DagHaloStrip]()
        strips.reserveCapacity(Int(stripCount))

        for _ in 0..<stripCount {
            let edgeVal: UInt32 = try readScalar(UInt32.self, ctx: "edge")
            guard let edge = HaloEdge(rawValue: Int(edgeVal)) else { throw HaloError.badEdge(edgeVal) }
            let w: UInt32 = try readScalar(UInt32.self, ctx: "width")
            let d: UInt32 = try readScalar(UInt32.self, ctx: "depth")
            let epoch: UInt64 = try readScalar(UInt64.self, ctx: "tick_epoch")
            let n = Int(w) * Int(d)

            var strip = DagHaloStrip(edge: edge, width: Int(w), depth: Int(d), tickEpoch: epoch)
            strip.rank       = try read(UInt64.self, count: n,     ctx: "rank")
            strip.truth      = try read(UInt8.self,  count: n,     ctx: "truth")
            strip.nodeType   = try read(UInt8.self,  count: n,     ctx: "nodeType")
            strip.lut6Low    = try read(UInt32.self, count: n,     ctx: "lut6Low")
            strip.lut6High   = try read(UInt32.self, count: n,     ctx: "lut6High")
            strip.neighbors  = try read(Int32.self,  count: n * 6, ctx: "neighbors")
            strip.isRegister = try read(UInt8.self,  count: n,     ctx: "isRegister")

            strips.append(strip)
        }
        return strips
    }

    // MARK: - Load adjacent halos

    /// Load halos from up to 4 adjacent tiles for spatial-tile mode.
    /// Missing tiles (world boundary, tick 0) get empty strips back.
    public static func loadAdjacentHalos(
        dir: String, tx: Int, ty: Int,
        nTilesX: Int, nTilesY: Int,
        tileW: Int, tileH: Int
    ) throws -> [HaloEdge: DagHaloStrip] {
        var result = [HaloEdge: DagHaloStrip]()
        for edge in HaloEdge.allCases {
            let (dtx, dty) = edge.tileOffset
            let ntx = tx + dtx
            let nty = ty + dty
            let stripWidth = (edge == .north || edge == .south) ? tileW : tileH

            if ntx < 0 || ntx >= nTilesX || nty < 0 || nty >= nTilesY {
                result[edge] = DagHaloStrip(edge: edge, width: stripWidth)
                continue
            }
            let path = haloPath(dir: dir, tx: ntx, ty: nty)
            if let strips = try readHalos(from: path),
               let strip = strips.first(where: { $0.edge == edge.opposite }) {
                result[edge] = strip
            } else {
                result[edge] = DagHaloStrip(edge: edge, width: stripWidth)
            }
        }
        return result
    }
}
