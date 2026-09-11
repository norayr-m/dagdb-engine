/// RankBoundFixture — the deep-rank object used by the RANK BOUND gates.
///
/// A purely combinational DAG whose ranks run 0…21 inclusive, every level
/// non-empty, with one edge that crosses the rank-8 boundary without
/// landing on it. Built to be installed into an engine whose configured
/// `maxRank` may be smaller than the ranks the object actually holds —
/// the state a snapshot written under a large bound produces when it is
/// restored under a small one.
///
/// Slot convention (engine-wide): a node's six neighbour slots hold its
/// HIGHER-rank INPUTS, i.e. `rank(src) > rank(dst)`; `-1` is an empty slot
/// and `-2` is the cross-tile sentinel. This object uses only real indices
/// and `-1`.
///
/// Lives in the library (not a test target) because two test targets —
/// the engine gates and the daemon-wire gates — must install the same
/// object. It follows the existing fixture idiom (`TiledFixture`,
/// `CortexFixture`, `AlarmFixture`). It computes nothing: the expected
/// fixed point is re-derived in each test from these tables, never by
/// calling a tick.
public enum RankBoundFixture {

    /// Square hex side. 9 × 9 = 81 nodes — enough for 22 levels of 3 plus
    /// 15 spare nodes, and square so the daemon fixture (`side:`) can host it.
    public static let side = 9

    /// Rank levels 0…21 inclusive.
    public static let levelCount = 22

    /// Nodes per level.
    public static let nodesPerLevel = 3

    /// Nodes belonging to the ranked DAG: `levelCount * nodesPerLevel`.
    public static let dagNodeCount = levelCount * nodesPerLevel  // 66

    /// Total nodes in the host grid.
    public static let nodeCount = side * side                     // 81

    /// The highest rank the object holds.
    public static let highestRank = levelCount - 1                // 21

    /// The skip edge that crosses rank 8: node 9 (rank 3) takes node 36
    /// (rank 12) as its slot-3 input.
    public static let skipEdgeDst = 9
    public static let skipEdgeSrc = 36
    public static let skipEdgeSlot = 3

    /// The one node forced to CONST1 so that a single rank-mode tick from
    /// an all-false start is guaranteed to change a node at rank ≥ 8.
    public static let const1Node = 63                             // rank 21

    /// The object's tables, in engine buffer-index space.
    public struct Tables {
        public let rank: [UInt64]
        public let neighbors: [Int32]   // nodeCount * 6
        public let lut: [UInt64]        // nodeCount
    }

    /// Deterministic 64-bit stream (splitmix64) so the LUT tables are the
    /// same on every machine and every run.
    private static func splitmix64(_ state: inout UInt64) -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Build the tables. No engine required.
    public static func tables() -> Tables {
        let n = nodeCount
        var rank = [UInt64](repeating: 0, count: n)
        var nb = [Int32](repeating: -1, count: n * 6)
        var lut = [UInt64](repeating: 0, count: n)

        // Level L holds nodes 3L, 3L+1, 3L+2 and carries rank L.
        for i in 0..<dagNodeCount { rank[i] = UInt64(i / nodesPerLevel) }
        // Spare nodes sit at rank 0 with no inputs and a CONST0 table.
        for i in dagNodeCount..<n { rank[i] = 0; lut[i] = 0 }

        // Each node at level L takes the three level-(L+1) nodes as inputs
        // (slots 0,1,2) — rank(src) = L+1 > L = rank(dst). Level 21 has no
        // inputs at all: those are the sources.
        for level in 0..<(levelCount - 1) {
            for k in 0..<nodesPerLevel {
                let dst = level * nodesPerLevel + k
                for j in 0..<nodesPerLevel {
                    nb[dst * 6 + j] = Int32((level + 1) * nodesPerLevel + j)
                }
            }
        }
        // The crossing edge: rank 12 → rank 3, over the rank-8 boundary.
        nb[skipEdgeDst * 6 + skipEdgeSlot] = Int32(skipEdgeSrc)

        var seed: UInt64 = 0x0DAD_B00D_0000_0001
        for i in 0..<dagNodeCount { lut[i] = splitmix64(&seed) }
        // Guarantee at least one TRUE source at rank ≥ 8 from an all-false
        // start, so "a single rank-mode tick changes a node at rank ≥ 8"
        // is a property of the object rather than of the random draw.
        lut[const1Node] = UInt64.max

        return Tables(rank: rank, neighbors: nb, lut: lut)
    }

    /// Write the tables into a live engine's buffers and mark the rank
    /// topology dirty. The engine's grid must be `side × side`.
    @discardableResult
    public static func install(into engine: DagDBEngine) -> Tables {
        let t = tables()
        let n = engine.nodeCount
        precondition(n == nodeCount, "RankBoundFixture needs a \(side)x\(side) grid")

        let rankPtr = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let nbPtr = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        let lowPtr = engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let highPtr = engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let truthPtr = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)

        for i in 0..<n {
            rankPtr[i] = t.rank[i]
            lowPtr[i] = UInt32(t.lut[i] & 0xFFFF_FFFF)
            highPtr[i] = UInt32((t.lut[i] >> 32) & 0xFFFF_FFFF)
            truthPtr[i] = 0
        }
        for i in 0..<(n * 6) { nbPtr[i] = t.neighbors[i] }

        engine.markRankTopologyDirty()
        return t
    }

    /// Reset every node's truth to FALSE — the shared start vector.
    public static func resetTruth(_ engine: DagDBEngine) {
        let p = engine.truthStateBuf.contents()
            .bindMemory(to: UInt8.self, capacity: engine.nodeCount)
        for i in 0..<engine.nodeCount { p[i] = 0 }
    }
}
