/// TiledFixture — the frozen synthetic objects for the tiling gate contract
/// (`docs/contracts/TILING_GATES_FROZEN.md`, "Frozen objects" paragraph).
///
/// Three DAGs, one generator, seeded from the engine's reference `NamedStream`
/// PCG. Ranks by Chebyshev distance from the centre (as `LadderFold.Objects`
/// writes ranks); truth random ternary; LUTs left at their constructed
/// default (zero — `DagDBState.init` zero-fills `lut6Low`/`lut6High`); edges
/// drawn per node, per slot: each node's slots hold HIGHER-rank sources
/// (the engine's own inputs convention, `rank(src) > rank(dst)` — AMENDMENT
/// 1, item 1) so every tiling by rank range has real cross-tile crossings.
///
/// The objects are regenerated on demand, never stored on disk (contract
/// "Frozen objects" paragraph, last sentence). Two calls with the same
/// `side` reproduce identical engine buffers — see
/// `TiledGraphFilesTests.testGeneratorIsDeterministic`.
import Foundation

public enum TiledFixture {

    public struct Object {
        public let side: Int
        public let engine: DagDBEngine
        public let grid: HexGrid
        public var nodeCount: Int { engine.nodeCount }
        public let maxRank: UInt64
    }

    public static let sides = [16, 44, 128]

    /// The engine's reference PCG64 seed (numpy-printed state/inc words),
    /// literal in `TwinCodableStreamTests` and in the tiling gate contract's
    /// T2 seed paragraph.
    public static let referenceSeed = (
        stateHi: UInt64(0x853c_49e6_748f_ea9b),
        stateLo: UInt64(0xda3e_39cb_94b9_5bdb),
        incHi: UInt64(0x5851_f42d_4c95_7f2d),
        incLo: UInt64(0x1405_7b7e_f767_814f)
    )

    /// Max Chebyshev-distance-from-centre rank for a `side × side` grid,
    /// centre `(side/2, side/2)`. Pure function of `side` — used by both
    /// `generate(side:)` (to size `Object.maxRank`) and `boundaries(side:
    /// tiles:)` (which needs it without paying for a full generation).
    private static func maxRankForSide(_ side: Int) -> UInt64 {
        let c0 = side / 2
        return UInt64(max(c0, side - 1 - c0))
    }

    /// Frozen generator. Draw order (contract "Frozen objects" paragraph):
    ///
    /// 1. **Neighbours wiped to −1** (HexGrid's own hex adjacency, which
    ///    `DagDBEngine.init` seeds `neighborsBuf` with, is discarded — this
    ///    fixture writes its own 6-bounded edge set).
    /// 2. **Ranks** — no random draw. For row-major `(c, r)`, `rank = max(|c
    ///    − c0|, |r − c0|)`, `c0 = side/2`, written into `rankBuf` at the
    ///    Morton index of `(c, r)` — the same write pattern as
    ///    `LadderFold.Objects.build`.
    /// 3. **Truth** — `NamedStream(name: "tiling-truth-<side>", referenceSeed)`,
    ///    one `next64()` per node, Morton index `0..<N` ascending order,
    ///    `truth[m] = UInt8(draw % 3)`.
    /// 4. **LUTs** — left untouched (constructed default: zero).
    /// 5. **Edges** — `NamedStream(name: "tiling-edges-<side>", referenceSeed)`.
    ///    For `u` in row-major order `0..<N`, for each of 6 slots in order:
    ///    draw `d = next64()`. `d % 8 == 0` → candidate list = nodes within
    ///    hex distance ≤ 3 of `u` (BFS 3 hops over the grid's neighbour
    ///    table, precomputed once per node) with `rank > rank(u)`; else →
    ///    candidate list = `u`'s direct hex neighbours with `rank > rank(u)`.
    ///    (AMENDMENT 1, item 1, `docs/contracts/TILING_GATES_FROZEN.md`: the
    ///    engine's convention is that a node's slots hold its INPUTS — the
    ///    HIGHER-rank sources, `rank(src) > rank(dst)` — the opposite of
    ///    this generator's original text. Corrected here; draw order and
    ///    skip rules unchanged.)
    ///    Both lists are sorted ascending by row-major index (BFS/neighbour
    ///    construction already yields that order). Empty list ⇒ slot stays
    ///    −1, **no further draw**. Non-empty ⇒ draw `next64() % count` to
    ///    pick the target; if the target's Morton index already occupies an
    ///    earlier slot of `u`, the slot stays −1 (no retry draw). Otherwise
    ///    the target's Morton index is written into
    ///    `neighborsBuf[uMorton * 6 + slot]`.
    ///
    /// This is the frozen generator — the draw order above must not change.
    public static func generate(side: Int) throws -> Object {
        let grid = HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 64)
        try populate(engine: engine, grid: grid, side: side)
        return Object(side: side, engine: engine, grid: grid, maxRank: maxRankForSide(side))
    }

    /// The frozen generator's steps 1-5, extracted so a caller who already
    /// has an engine + grid of the right side (e.g. a daemon test fixture
    /// built via `HandlerFixture`) can populate it in place, instead of
    /// going through `generate(side:)`'s own engine construction. `generate`
    /// itself is now a thin wrapper: build a fresh engine, call this, wrap
    /// the result in `Object`. `engine.nodeCount` and `grid.nodeCount` must
    /// equal `side * side` — the caller's responsibility (mirrors
    /// `generate`'s own grid/engine pairing).
    public static func populate(engine: DagDBEngine, grid: HexGrid, side: Int) throws {
        let n = grid.nodeCount

        // 1. Wipe neighbours to -1.
        let nbPtr = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        for i in 0..<(n * 6) { nbPtr[i] = -1 }

        // 2. Ranks: Chebyshev distance from centre, row-major -> Morton index.
        let c0 = side / 2
        let rankPtr = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        for i in 0..<n {
            let c = i % side, r = i / side
            rankPtr[Int(grid.mortonRank[i])] = UInt64(max(abs(c - c0), abs(r - c0)))
        }

        // 3. Truth: one draw per Morton index, ascending order.
        var truthStream = NamedStream(
            name: "tiling-truth-\(side)",
            stateHi: referenceSeed.stateHi, stateLo: referenceSeed.stateLo,
            incHi: referenceSeed.incHi, incLo: referenceSeed.incLo
        )
        let truthPtr = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        for m in 0..<n {
            truthPtr[m] = UInt8(truthStream.next64() % 3)
        }

        // 4. LUTs — left as constructed (DagDBState default: zero). Nothing to do.

        // 5. Edges. Precompute, once per node: direct hex neighbours
        // (row-major, ascending) and the hex-distance-<=3 ring (row-major,
        // ascending), both via the grid's own neighbour table.
        var rowMajorNeighbors = [[Int]](repeating: [], count: n)
        for i in 0..<n {
            let m = Int(grid.mortonRank[i])
            var nbrs: [Int] = []
            for d in 0..<6 {
                let nm = grid.neighbors[m * 6 + d]
                if nm >= 0 { nbrs.append(Int(grid.mortonToNode[Int(nm)])) }
            }
            nbrs.sort()
            rowMajorNeighbors[i] = nbrs
        }
        var ring3 = [[Int]](repeating: [], count: n)
        for i in 0..<n {
            var visited: Set<Int> = [i]
            var frontier = [i]
            var collected = Set<Int>()
            for _ in 0..<3 {
                var next: [Int] = []
                for u in frontier {
                    for v in rowMajorNeighbors[u] where !visited.contains(v) {
                        visited.insert(v)
                        collected.insert(v)
                        next.append(v)
                    }
                }
                if next.isEmpty { break }
                frontier = next
            }
            ring3[i] = collected.sorted()
        }

        var edgeStream = NamedStream(
            name: "tiling-edges-\(side)",
            stateHi: referenceSeed.stateHi, stateLo: referenceSeed.stateLo,
            incHi: referenceSeed.incHi, incLo: referenceSeed.incLo
        )

        func rankOf(_ rowMajor: Int) -> UInt64 { rankPtr[Int(grid.mortonRank[rowMajor])] }

        for u in 0..<n {
            let uMorton = Int(grid.mortonRank[u])
            let uRank = rankOf(u)
            var usedMorton = Set<Int32>()
            for slot in 0..<6 {
                let d = edgeStream.next64()
                let candidates: [Int]
                if d % 8 == 0 {
                    candidates = ring3[u].filter { rankOf($0) > uRank }
                } else {
                    candidates = rowMajorNeighbors[u].filter { rankOf($0) > uRank }
                }
                if candidates.isEmpty { continue }
                let idx = Int(edgeStream.next64() % UInt64(candidates.count))
                let targetRowMajor = candidates[idx]
                let targetMorton = Int32(grid.mortonRank[targetRowMajor])
                if usedMorton.contains(targetMorton) { continue }
                nbPtr[uMorton * 6 + slot] = targetMorton
                usedMorton.insert(targetMorton)
            }
        }
    }

    /// Rank boundaries splitting `[0, maxRank]` into `tiles` equal spans:
    /// `b_k = k · (maxRank+1) / tiles` for `k = 1..<tiles` (integer
    /// division; the last tile takes the remainder). Returns the `tiles -
    /// 1` interior boundaries — the shape `TiledGraphFiles.write(boundaries:)`
    /// expects (tile count = `boundaries.count + 1`).
    public static func boundaries(side: Int, tiles: Int) -> [UInt64] {
        let span = maxRankForSide(side) + 1
        guard tiles > 1 else { return [] }
        return (1..<tiles).map { k in UInt64(k) * span / UInt64(tiles) }
    }

    /// `[centre engine index] + (draw_k mod N, k = 1...4)` from a fresh
    /// `NamedStream(name: "tiling", referenceSeed)` — the five seeds T2
    /// regenerates for cross-tile BFS/ancestry verification. "Engine index"
    /// is the Morton index (arrays are indexed by Morton rank throughout
    /// this codebase — see `DagDBState`'s header comment).
    public static func seeds(for object: Object) -> [Int] {
        let side = object.side
        let c0 = side / 2
        let centreRowMajor = c0 * side + c0
        let centreEngineIndex = Int(object.grid.mortonRank[centreRowMajor])

        var stream = NamedStream(
            name: "tiling",
            stateHi: referenceSeed.stateHi, stateLo: referenceSeed.stateLo,
            incHi: referenceSeed.incHi, incLo: referenceSeed.incLo
        )
        var result = [centreEngineIndex]
        let n = UInt64(object.nodeCount)
        for _ in 1...4 {
            result.append(Int(stream.next64() % n))
        }
        return result
    }
}
