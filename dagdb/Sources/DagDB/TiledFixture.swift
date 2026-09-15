/// TiledFixture — the frozen synthetic objects for the tiling gate contract
/// (`docs/contracts/TILING_GATES_FROZEN.md`, "Frozen objects" paragraph).
///
/// Three DAGs, one generator, seeded from the engine's reference `NamedStream`
/// PCG. Ranks by Chebyshev distance from the centre (as `LadderFold.Objects`
/// writes ranks); truth random ternary; LUT6 tables parity (or complemented
/// parity) over each node's present slots, plus one period-2 register
/// oscillator per usable rank-level pair (AMENDMENT 6, letter 1 — the
/// repaired object: the pre-amendment fixture left every table at the
/// constructed zero, which made the world a fixed point after one tick and
/// every equality gate vacuous); edges
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

    /// Audit C findings 18 and 19.
    public enum FixtureError: Error, Equatable, CustomStringConvertible {
        /// `populate` was handed a grid and an engine of different sizes —
        /// it binds `engine.neighborsBuf` at `grid.nodeCount * 6` and would
        /// have written past the end of the smaller one.
        case sizeMismatch(gridNodes: Int, engineNodes: Int, side: Int)
        public var description: String {
            switch self {
            case .sizeMismatch(let g, let e, let side):
                return "TiledFixture.populate: grid holds \(g) nodes (side \(side)) but the engine "
                    + "holds \(e) — the two must match or the write runs past the engine's buffers"
            }
        }
    }

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
    /// 4. **LUTs** — see steps 6/7 below: written AFTER the edge draws,
    ///    from their own stream, so steps 2/3/5's streams are unchanged.
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
    /// 6. **LUT6 tables** (AMENDMENT 6, letter 1) —
    ///    `NamedStream("tiling-luts-<side>")`, one `next64() & 1` per node
    ///    in Morton order choosing parity (0) or complemented parity (1);
    ///    `bit(idx) = (popcount(idx & presentMask) + choice) & 1`.
    /// 7. **Registers** — one `R ← S`, `S = ¬R` oscillator per rank level
    ///    `r >= 1` that is not a tile boundary of any frozen tiling
    ///    (2/4/8), so no back edge ever crosses a tile boundary. Every
    ///    other slot pointing at `R` is cleared, keeping register fan-out
    ///    intra-tile (see the inline comment for why W1 needs that).
    ///
    /// This is the frozen generator — the draw order above must not change.
    public static func generate(side: Int) throws -> Object {
        let grid = try HexGrid(width: side, height: side)
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
        // Audit C finding 18: the doc made the engine/grid pairing "the
        // caller's responsibility" and nothing checked it, on a PUBLIC
        // function that binds every Metal buffer at the GRID's size. A
        // grid larger than the engine wrote out of bounds, silently.
        guard n == engine.nodeCount else {
            throw FixtureError.sizeMismatch(gridNodes: n, engineNodes: engine.nodeCount, side: side)
        }

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

        // 4. LUTs — written in step 6 below (after the edge draws, from
        // their own stream, so the truth/rank/edge streams are unchanged).

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

        // ── 6/7. The repaired object (TICKING_GATES_FROZEN.md AMENDMENT 6,
        // letter 1). Appended AFTER the frozen truth/rank/edge draws, so
        // those three streams are bit-identical to the pre-amendment
        // generator.

        // 6. LUT6 tables — one draw per node, Morton order, `next64() & 1`
        //    selecting parity (0) or complemented parity (1). The word
        //    itself is `bit(idx) = (popcount(idx & presentMask) + choice)
        //    & 1`, `presentMask` = the node's non-empty slots. Every node
        //    is therefore fully sensitive on every present input, which is
        //    what makes the perturbation gates (W7a) non-vacuous.
        var lutStream = NamedStream(
            name: "tiling-luts-\(side)",
            stateHi: referenceSeed.stateHi, stateLo: referenceSeed.stateLo,
            incHi: referenceSeed.incHi, incLo: referenceSeed.incLo
        )
        var choice = [Int](repeating: 0, count: n)
        for m in 0..<n { choice[m] = Int(lutStream.next64() & 1) }

        let lowPtr = engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let highPtr = engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)

        func presentMask(_ m: Int) -> Int {
            var mask = 0
            for d in 0..<6 where nbPtr[m * 6 + d] >= 0 { mask |= 1 << d }
            return mask
        }
        func writeParityLUT(_ m: Int) {
            let mask = presentMask(m)
            let c = choice[m]
            var low: UInt32 = 0, high: UInt32 = 0
            for idx in 0..<64 {
                guard ((idx & mask).nonzeroBitCount + c) & 1 == 1 else { continue }
                if idx < 32 { low |= UInt32(1) << UInt32(idx) }
                else { high |= UInt32(1) << UInt32(idx - 32) }
            }
            lowPtr[m] = low
            highPtr[m] = high
        }
        for m in 0..<n { writeParityLUT(m) }

        // 7. Registers — one period-2 oscillator per usable rank-level pair.
        //
        //    `R` (rank r, all slots cleared, `isRegister`) ← back edge ←
        //    `S` (rank r − 1, single present slot pointing at `R`,
        //    complemented single-input parity) ⇒ `R_{k+1} = ¬R_k`.
        //
        //    `r` is skipped when it is a tile boundary of ANY frozen
        //    tiling (2/4/8), because a pair straddling a boundary would be
        //    a cross-tile back edge, which `TiledGraphFiles.write` refuses.
        //
        //    `r` starts at 2, not 1. Rank 0 holds exactly ONE node — the
        //    grid centre — and that node is the first of the tiling
        //    contract's frozen T2/T3 query seeds. Using it as an `S` would
        //    clear its slots down to a single edge into its own register
        //    and cut the seed's reachable set to two nodes, making the
        //    cross-tile BFS/ancestry/residency gates trivially true. The
        //    cost is that a tile whose whole span is {0, 1} carries no
        //    register (side 44's 8-tiling, tile 0); W7d asserts that
        //    exception rather than passing over it.
        //
        //    A register KEEPS its cross-tile readers. An earlier build
        //    cleared every slot that pointed at an `R`, because the tiled
        //    ticker latches at the end of each tile's own tick and flushes,
        //    so a reader in a LOWER tile read the POST-latch value from the
        //    strip while the untiled engine (one latch after the whole
        //    graph) shows it the PRE-latch value — and W1 broke on a
        //    correct engine. AMENDMENT 7, finding A rejected that: removing
        //    the readers makes the gate pass on an object that cannot
        //    exhibit the defect. The defect is fixed where it lives — the
        //    rank-mode flush writes a register's PRE-latch byte into the
        //    lower strip (`TiledGraphRouter.tickAndFlushOneTile`) — and the
        //    object keeps the readers that prove it.
        let frozenTilings = [2, 4, 8].map { boundaries(side: side, tiles: $0) }
        let boundarySet = Set(frozenTilings.flatMap { $0 })
        var byRank: [UInt64: [Int]] = [:]
        for m in 0..<n { byRank[rankPtr[m], default: []].append(m) }

        //    WHICH node at level `r` becomes the register is this
        //    generator's choice, not the frozen draw's, and the choice
        //    decides whether the object can exhibit the latch-timing defect
        //    at all. Almost every drawn edge spans exactly one rank (the
        //    direct-hex-neighbour branch, 7 draws in 8), and `r` is never a
        //    tile boundary, so a register picked blindly is read only from
        //    rank `r − 1`, always inside its own tile: zero cross-tile
        //    readers on all three sides — the defect hides again, for a
        //    different reason. So `R` is chosen as the node at rank `r`
        //    whose ALREADY-DRAWN incoming edges cross the most of the three
        //    frozen tilings' boundaries (ties by lowest Morton index). No
        //    edge is invented; the selection only prefers a node the draw
        //    already wired across a boundary.
        var readersOf = [[Int]](repeating: [], count: n)
        for u in 0..<n {
            for d in 0..<6 {
                let target = nbPtr[u * 6 + d]
                if target >= 0 { readersOf[Int(target)].append(u) }
            }
        }
        func tileOfRank(_ rank: UInt64, _ bs: [UInt64]) -> Int {
            for (i, b) in bs.enumerated() where rank < b { return i }
            return bs.count
        }
        func crossingScore(_ candidate: Int) -> Int {
            var score = 0
            for bs in frozenTilings {
                let tileOfCandidate = tileOfRank(rankPtr[candidate], bs)
                if readersOf[candidate].contains(where: {
                    tileOfRank(rankPtr[$0], bs) != tileOfCandidate
                }) { score += 1 }
            }
            return score
        }

        var usedForRegisters = Set<Int>()
        let topRank = maxRankForSide(side)
        if topRank >= 2 {
            for r in 2...topRank where !boundarySet.contains(r) {
                guard let rNodes = byRank[r], let sNodes = byRank[r - 1] else { continue }
                let candidates = rNodes.filter { !usedForRegisters.contains($0) }
                guard let reg = candidates.max(by: { a, b in
                    let sa = crossingScore(a), sb = crossingScore(b)
                    return sa != sb ? sa < sb : a > b
                }) else { continue }
                guard let src = sNodes.first(where: { !usedForRegisters.contains($0) && $0 != reg })
                else { continue }
                usedForRegisters.insert(reg)
                usedForRegisters.insert(src)

                var touched = Set<Int>()
                for d in 0..<6 { nbPtr[reg * 6 + d] = -1 }
                for d in 0..<6 { nbPtr[src * 6 + d] = -1 }
                nbPtr[src * 6 + 0] = Int32(reg)
                // `S = ¬R` is the letter; the drawn choice is overridden
                // to 1 (complemented parity) for these nodes only.
                choice[src] = 1
                touched.insert(reg)
                touched.insert(src)
                for m in touched { writeParityLUT(m) }

                try engine.addBackEdge(src: UInt32(src), dst: UInt32(reg))
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
        // Audit C finding 19: `% 0` on a zero-node object TRAPPED, and the
        // centre lookup below would have indexed an empty Morton table
        // first. Refused by name (a named ERROR line carrying the value and
        // the true extent, per the contract's general letter) and reported
        // as an empty seed list — `seeds` is called without `try` from
        // outside this file set, so the refusal cannot be a throw here.
        let centreRowMajor = (side / 2) * side + (side / 2)
        guard object.nodeCount > 0, centreRowMajor < object.grid.mortonRank.count else {
            FileHandle.standardError.write(Data((
                "ERROR tiled_fixture seeds: object of side \(side) holds \(object.nodeCount) nodes "
                + "and \(object.grid.mortonRank.count) Morton entries; the centre seed and the four "
                + "modulo draws need at least 1 of each\n").utf8))
            return []
        }
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
