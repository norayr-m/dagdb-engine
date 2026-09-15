/// HexGrid — Morton Z-curve hex grid with 7-coloring.
///
/// Flat-top hex, odd-q offset. Neighbors stored as (N, 6) flat array.
/// Morton ordering: all index spaces (neighbors, colorGroups, colors) use Morton rank.
/// 7-coloring: (col + row + 4*(col&1)) mod 7 — distance-2 safe (Molloy & Salavatipour, 2005).

import Foundation

/// Entity codes matching Python engine
public enum Entity: Int8 {
    case empty = 0
    case grass = 1
    case zebra = 2
    case lion  = 3
    case water = 4
}

public struct HexGrid {
    public let width: Int
    public let height: Int
    public let nodeCount: Int

    /// (N, 6) neighbor indices in Morton-rank space, -1 padded.
    /// neighbors[mortonRank * 6 + dir] = Morton rank of neighbor (or -1).
    public let neighbors: [Int32]

    /// Morton Z-curve code for each row-major node. mortonOrder[rowMajor] = morton code.
    public let mortonOrder: [UInt32]

    /// Inverse: mortonToNode[rank] = row-major node index for rank-th Morton code.
    public let mortonToNode: [Int32]

    /// mortonRank[rowMajor] = Morton rank of that row-major node.
    /// This is the key mapping: (col,row) → row-major → mortonRank → buffer index.
    public let mortonRank: [Int32]

    /// Color groups in Morton-rank space. colorGroups[c] = array of Morton ranks with color c.
    public let colorGroups: [[Int32]]

    /// Color per Morton rank. colors[mortonRank] = 0..6.
    public let colors: [UInt8]

    /// Number of color groups (7 for distance-2 safe hex movement).
    /// Molloy & Salavatipour (2005): distance-2 chromatic number of hex lattice = 7.
    public static let colorCount = 7

    // MARK: - C5 · what this layout can encode, and the refusal outside it

    public enum GridError: Error, CustomStringConvertible {
        case axesOutOfRange(String)
        case invalidMagic
        case unsupportedVersion(UInt32)
        case truncatedSection(name: String, need: Int, have: Int)
        case sectionEntryOutOfRange(section: String, index: Int, value: Int, nodeCount: Int)

        public var description: String {
            switch self {
            case .axesOutOfRange(let s): return s
            case .invalidMagic: return "invalid magic (expected 'DAGG')"
            case .unsupportedVersion(let v): return "unsupported grid file version: \(v)"
            case let .truncatedSection(name, need, have):
                return "grid file truncated in section '\(name)': need \(need) bytes, have \(have)"
            case let .sectionEntryOutOfRange(section, index, value, n):
                return "grid file section '\(section)' entry \(index) = \(value) is out of range for nodeCount \(n)"
            }
        }
    }

    /// The Morton code packs two 16-bit axes (`mortonEncode`):
    ///
    ///   * `q` is the column index, `0 … width - 1`, so a column index must
    ///     fit 16 unsigned bits — `width ≤ 65536`.
    ///   * `cubeR = r - (c - (c & 1)) / 2` is the cube row. It is NEGATIVE
    ///     for any `width ≥ 3` at low rows, and `UInt16(cubeR & 0xFFFF)`
    ///     folds it as two's complement — injective exactly while
    ///     `cubeR ∈ [-32768, 32767]`. Its extremes are `-(width - 1)/2` (row
    ///     0, last column) and `height - 1` (last row, column 0), so the
    ///     encodable range is `(width - 1) / 2 ≤ 32768` and `height ≤ 32768`.
    ///     Outside it two cells share a Morton code, and the layout the file
    ///     is named for is silently gone.
    ///   * The node index space is `Int32` (`neighbors`, `mortonToNode`,
    ///     `mortonRank`, the colour groups), so `width × height ≤ Int32.max`.
    ///
    /// Returns nil when the grid is encodable, or the reason it is not.
    public static func refusalReason(width: Int, height: Int) -> String? {
        guard width >= 1 && height >= 1 else {
            return "grid axes must be positive: width \(width), height \(height)"
        }
        guard width <= 65_536 else {
            return "grid width \(width) exceeds the 16-bit Morton column axis (max 65536)"
        }
        guard height <= 32_768 else {
            return "grid height \(height) exceeds the signed 16-bit Morton cube-row axis (max 32768)"
        }
        guard (width - 1) / 2 <= 32_768 else {
            return "grid width \(width) drives the cube row below the signed 16-bit Morton axis " +
                   "(row 0 of the last column encodes \(-((width - 1) / 2)), min -32768)"
        }
        let (n, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, n <= Int(Int32.max) else {
            return "grid node count \(width) × \(height) exceeds the Int32 node index space (max \(Int32.max))"
        }
        return nil
    }

    /// Named alias for the refusing constructor. `init(width:height:)` itself
    /// throws `GridError.axesOutOfRange` for exactly what `refusalReason`
    /// names, so this is the same door under an older name. There is no
    /// non-throwing construction path that skips the check.
    public static func validated(width: Int, height: Int) throws -> HexGrid {
        try HexGrid(width: width, height: height)
    }

    /// Refusing constructor (C5 / F1). Axes outside the 16-bit Morton
    /// encoding, a node count above `Int32.max`, and an overflowing product
    /// are refused by name as `GridError.axesOutOfRange`, never trapped.
    public init(width: Int, height: Int) throws {
        if let why = HexGrid.refusalReason(width: width, height: height) {
            throw GridError.axesOutOfRange(why)
        }
        self.width = width
        self.height = height
        self.nodeCount = width * height

        let n = nodeCount

        // Even/odd column hex neighbor offsets (dc, dr)
        // Consistent direction ordering across even/odd columns:
        //   Dir 0: NE (-30°)    Dir 3: SW (+150°)   — opposite pair
        //   Dir 1: N  (-90°)    Dir 4: S  (+90°)    — opposite pair
        //   Dir 2: NW (-150°)   Dir 5: SE (+30°)    — opposite pair
        // Three axes at 120° apart. (d+3)%6 = opposite direction.
        let evenOffsets: [(Int, Int)] = [(1,-1),(0,-1),(-1,-1),(-1,0),(0,1),(1,0)]
        let oddOffsets:  [(Int, Int)] = [(1,0), (0,-1),(-1,0), (-1,1),(0,1),(1,1)]

        // --- Pass 1: Build row-major neighbor table and colors ---
        var nbRM = [Int32](repeating: -1, count: n * 6)
        var colRM = [UInt8](repeating: 0, count: n)
        var groupsRM: [[Int32]] = (0..<7).map { _ in [Int32]() }

        for c in 0..<width {
            let offsets = (c & 1 == 1) ? oddOffsets : evenOffsets
            for r in 0..<height {
                let i = r * width + c
                var k = 0
                for (dc, dr) in offsets {
                    let nc = c + dc
                    let nr = r + dr
                    if nc >= 0 && nc < width && nr >= 0 && nr < height {
                        nbRM[i * 6 + k] = Int32(nr * width + nc)
                    }
                    k += 1
                }
                // 7-coloring: (col + row + 4*(col&1)) mod 7
                let color = UInt8((c + r + 4 * (c & 1)) % 7)
                colRM[i] = color
                groupsRM[Int(color)].append(Int32(i))
            }
        }

        // --- Morton Z-curve via cube coordinates ---
        var morton = [UInt32](repeating: 0, count: n)
        for c in 0..<width {
            for r in 0..<height {
                let i = r * width + c
                let q = c
                let cubeR = r - (c - (c & 1)) / 2
                morton[i] = Self.mortonEncode(UInt16(q & 0xFFFF), UInt16(cubeR & 0xFFFF))
            }
        }
        self.mortonOrder = morton

        // Build inverse: sort by Morton code
        var indices = (0..<Int32(n)).map { $0 }
        indices.sort { morton[Int($0)] < morton[Int($1)] }
        self.mortonToNode = indices

        // Build mortonRank: inverse of mortonToNode
        var rank = [Int32](repeating: 0, count: n)
        for m in 0..<n {
            rank[Int(indices[m])] = Int32(m)
        }
        self.mortonRank = rank

        // --- Pass 2: Translate everything to Morton-rank space ---

        // Neighbor table: nbMorton[m * 6 + d] = Morton rank of neighbor
        var nbMorton = [Int32](repeating: -1, count: n * 6)
        for m in 0..<n {
            let i = Int(indices[m])  // row-major node at Morton rank m
            for d in 0..<6 {
                let nbIdx = nbRM[i * 6 + d]
                nbMorton[m * 6 + d] = nbIdx < 0 ? -1 : rank[Int(nbIdx)]
            }
        }
        self.neighbors = nbMorton

        // Color groups: translate row-major indices to Morton ranks
        self.colorGroups = groupsRM.map { group in group.map { rank[Int($0)] } }

        // Colors array: reindex so colors[m] = color of Morton rank m
        var colMorton = [UInt8](repeating: 0, count: n)
        for m in 0..<n {
            colMorton[m] = colRM[Int(indices[m])]
        }
        self.colors = colMorton
    }

    /// Interleave bits of two 16-bit values into a 32-bit Morton code.
    static func mortonEncode(_ x: UInt16, _ y: UInt16) -> UInt32 {
        func spread(_ v: UInt16) -> UInt32 {
            var x = UInt32(v) & 0x0000FFFF
            x = (x | (x << 8)) & 0x00FF00FF
            x = (x | (x << 4)) & 0x0F0F0F0F
            x = (x | (x << 2)) & 0x33333333
            x = (x | (x << 1)) & 0x55555555
            return x
        }
        return spread(x) | (spread(y) << 1)
    }

    /// Degree of a node (count of valid neighbors, 3-6). Takes Morton rank.
    public func degree(of node: Int) -> Int {
        var count = 0
        for d in 0..<6 {
            if neighbors[node * 6 + d] >= 0 { count += 1 }
        }
        return count
    }

    // ── Serialization: save/load grid to skip 30s rebuild ──────

    /// "DAGG" — the grid file's magic. Before C5 the file had none at all,
    /// so any bytes at all were read as a grid (audit A, finding 23).
    public static let fileMagic: [UInt8] = [0x44, 0x41, 0x47, 0x47]
    /// Grid file version. 1 = the section layout below, with a header.
    public static let fileVersion: UInt32 = 1
    /// magic (4) + version u32 + width u32 + height u32.
    public static let fileHeaderSize: Int = 16

    /// Save grid topology to binary file. ~28 bytes per node for 1B grid = ~28 GB.
    /// For smaller grids (1M = 28 MB, 16M = 448 MB) this is fast.
    ///
    /// Layout: header (16 B) then, in order and with no padding —
    /// `neighbors` (n·6 Int32), `mortonOrder` (n UInt32), `mortonToNode`
    /// (n Int32), `mortonRank` (n Int32), `colors` (n UInt8), then seven
    /// colour groups, each a u32 count followed by that many Int32.
    public func save(to path: String) throws {
        var data = Data()
        data.append(contentsOf: HexGrid.fileMagic)
        var v = HexGrid.fileVersion
        data.append(Data(bytes: &v, count: 4))
        var w = UInt32(width), h = UInt32(height)
        data.append(Data(bytes: &w, count: 4))
        data.append(Data(bytes: &h, count: 4))
        // Neighbors: n*6 Int32 values
        neighbors.withUnsafeBytes { data.append(Data($0)) }
        // mortonOrder: n UInt32 values
        mortonOrder.withUnsafeBytes { data.append(Data($0)) }
        // mortonToNode: n Int32 values
        mortonToNode.withUnsafeBytes { data.append(Data($0)) }
        // mortonRank: n Int32 values
        mortonRank.withUnsafeBytes { data.append(Data($0)) }
        // colors: n UInt8 values
        colors.withUnsafeBytes { data.append(Data($0)) }
        // colorGroups: 7 groups, each prefixed by count
        for g in colorGroups {
            var count = UInt32(g.count)
            data.append(Data(bytes: &count, count: 4))
            g.withUnsafeBytes { data.append(Data($0)) }
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Load grid from a binary file, refusing by name anything it cannot
    /// read whole.
    ///
    /// C5 · every section is checked against `n`, and every index a section
    /// carries is checked against `nodeCount` — a colour-group entry flows
    /// straight into `rebuildCompaction`'s `rankPtr[Int(node)]` and into the
    /// GPU, and `mortonToNode` / `mortonRank` are read by every Morton-space
    /// translation. Before C5 only the neighbour section's length was
    /// checked and a short file produced a grid whose arrays were shorter
    /// than the node count it advertised.
    public static func load(from path: String) throws -> HexGrid {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw GridError.truncatedSection(name: "file", need: fileHeaderSize, have: 0)
        }
        guard data.count >= fileHeaderSize else {
            throw GridError.truncatedSection(name: "header",
                                             need: fileHeaderSize, have: data.count)
        }
        guard [UInt8](data[0..<4]) == fileMagic else { throw GridError.invalidMagic }

        var offset = 4
        func readU32() -> UInt32 {
            let v = UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
                  | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
            offset += 4
            return v
        }
        let ver = readU32()
        guard ver == fileVersion else { throw GridError.unsupportedVersion(ver) }
        let wRaw = readU32(), hRaw = readU32()

        // The axes come from the file, so they are validated by the same rule
        // construction uses — before `width * height` is computed at all.
        let width = Int(wRaw), height = Int(hRaw)
        if let why = refusalReason(width: width, height: height) {
            throw GridError.axesOutOfRange("grid file header: \(why)")
        }
        let n = width * height

        func section<T>(_ name: String, _ type: T.Type, count: Int) throws -> [T] {
            let size = count * MemoryLayout<T>.size
            guard offset + size <= data.count else {
                throw GridError.truncatedSection(name: name, need: size,
                                                 have: max(0, data.count - offset))
            }
            let result = data[offset..<offset + size].withUnsafeBytes { ptr in
                Array(ptr.bindMemory(to: T.self))
            }
            offset += size
            return result
        }

        let nb  = try section("neighbors",    Int32.self,  count: n * 6)
        let mo  = try section("mortonOrder",  UInt32.self, count: n)
        let mtn = try section("mortonToNode", Int32.self,  count: n)
        let mr  = try section("mortonRank",   Int32.self,  count: n)
        let col = try section("colors",       UInt8.self,  count: n)

        var cg = [[Int32]]()
        var groupTotal = 0
        for g in 0..<colorCount {
            guard offset + 4 <= data.count else {
                throw GridError.truncatedSection(name: "colorGroup[\(g)] count",
                                                 need: 4, have: max(0, data.count - offset))
            }
            let count = Int(readU32())
            guard count >= 0 && count <= n else {
                throw GridError.sectionEntryOutOfRange(section: "colorGroup[\(g)] count",
                                                       index: g, value: count, nodeCount: n)
            }
            let entries = try section("colorGroup[\(g)]", Int32.self, count: count)
            for (i, e) in entries.enumerated() where e < 0 || Int(e) >= n {
                throw GridError.sectionEntryOutOfRange(section: "colorGroup[\(g)]",
                                                       index: i, value: Int(e), nodeCount: n)
            }
            groupTotal += count
            cg.append(entries)
        }
        guard groupTotal == n else {
            throw GridError.sectionEntryOutOfRange(
                section: "colorGroups total", index: -1, value: groupTotal, nodeCount: n)
        }

        // Index ranges the rest of the engine dereferences without asking again.
        for (i, e) in nb.enumerated() where e >= 0 && Int(e) >= n {
            throw GridError.sectionEntryOutOfRange(section: "neighbors",
                                                   index: i, value: Int(e), nodeCount: n)
        }
        for (i, e) in mtn.enumerated() where e < 0 || Int(e) >= n {
            throw GridError.sectionEntryOutOfRange(section: "mortonToNode",
                                                   index: i, value: Int(e), nodeCount: n)
        }
        for (i, e) in mr.enumerated() where e < 0 || Int(e) >= n {
            throw GridError.sectionEntryOutOfRange(section: "mortonRank",
                                                   index: i, value: Int(e), nodeCount: n)
        }
        for (i, c) in col.enumerated() where Int(c) >= colorCount {
            throw GridError.sectionEntryOutOfRange(section: "colors",
                                                   index: i, value: Int(c), nodeCount: n)
        }

        return HexGrid(width: width, height: height,
                       neighbors: nb, mortonOrder: mo,
                       mortonToNode: mtn, mortonRank: mr,
                       colors: col, colorGroups: cg)
    }

    /// Private init for deserialization.
    private init(width: Int, height: Int,
                 neighbors: [Int32], mortonOrder: [UInt32],
                 mortonToNode: [Int32], mortonRank: [Int32],
                 colors: [UInt8], colorGroups: [[Int32]]) {
        self.width = width
        self.height = height
        self.nodeCount = width * height
        self.neighbors = neighbors
        self.mortonOrder = mortonOrder
        self.mortonToNode = mortonToNode
        self.mortonRank = mortonRank
        self.colors = colors
        self.colorGroups = colorGroups
    }

    /// Verify 7-coloring: no two adjacent nodes share a color. Operates in Morton space.
    public func verifyColoring() -> Bool {
        for i in 0..<nodeCount {
            let myColor = colors[i]
            for d in 0..<6 {
                let nb = neighbors[i * 6 + d]
                if nb >= 0 && colors[Int(nb)] == myColor {
                    return false
                }
            }
        }
        return true
    }
}
