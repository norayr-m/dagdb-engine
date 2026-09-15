import Foundation
@testable import DagDB

/// TiledReference — Room A of the ticking contract (`AMENDMENT 6, letter
/// 2`): a test-side evaluator of the SAME graph, written from the
/// contract's own paragraph and from the kernel's bit rule, which never
/// calls `DagDBEngine`. Every equality the ticking gates assert is
/// compared against this, so "tiled == untiled" can no longer be true by
/// both sides being wrong in the same way.
///
/// The rule, verbatim from the letter and from `Shaders/dagdb.metal`:
///
/// - a node's six slots are its inputs; an absent slot (`-1`) contributes
///   nothing, and input bit `d` is 1 **iff the source's truth byte is
///   exactly 1** (so `2`, the paradox horizon, reads as 0);
/// - a combinational node's output is `bit(idx)` of its LUT6, `idx` packed
///   from those six bits, low word for `idx < 32`, high word above;
/// - **registers are skipped** by the combinational pass entirely, and
///   after the pass every back edge latches `truth[src]` into `truth[dst]`
///   (two-phase: every source is snapshotted before any destination is
///   written);
/// - **rank mode** evaluates rank levels from the highest down to 0, in
///   place, so a node reads its higher-rank inputs already recomputed this
///   tick; **sync mode** is the same rule evaluated in one hop from the
///   previous tick's vector.
///
/// The sweep starts at the HIGHEST RANK PRESENT, with no engine bound —
/// amendment 6's letter, and (since `main`'s rank-bound correction, merged
/// into this branch) the engine's own behaviour too: `DagDBEngine` now
/// derives `effectiveRankCount = max(maxRank, highestRankPresent + 1)` and
/// dispatches every level that carries a node. The earlier build of this
/// file carried the engine's old bound instead; AMENDMENT 7, finding B
/// rejected that — Room A carries the letter, not the defect.
struct TiledReference {

    let nodeCount: Int
    let rank: [UInt64]
    let slots: [Int32]
    let lutLow: [UInt32]
    let lutHigh: [UInt32]
    let isRegister: [Bool]
    let backEdgeSrc: [Int]
    let backEdgeDst: [Int]

    /// Highest rank actually present in the object.
    let maxRankPresent: UInt64
    /// Nodes grouped by rank, ascending node index within each level.
    private let byRank: [[Int]]

    init(engine: DagDBEngine) {
        let n = engine.nodeCount
        nodeCount = n
        let rp = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let sp = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        let lp = engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let hp = engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let gp = engine.isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        rank = Array(UnsafeBufferPointer(start: rp, count: n))
        slots = Array(UnsafeBufferPointer(start: sp, count: n * 6))
        lutLow = Array(UnsafeBufferPointer(start: lp, count: n))
        lutHigh = Array(UnsafeBufferPointer(start: hp, count: n))
        isRegister = (0..<n).map { gp[$0] != 0 }
        backEdgeSrc = engine.backEdgeSrcs.map { Int($0) }
        backEdgeDst = engine.backEdgeDsts.map { Int($0) }

        let top = rank.max() ?? 0
        maxRankPresent = top
        var buckets = [[Int]](repeating: [], count: Int(top) + 1)
        for i in 0..<n { buckets[Int(rank[i])].append(i) }
        byRank = buckets
    }

    // MARK: - The bit rule

    @inline(__always)
    private func lutBit(_ node: Int, _ idx: Int) -> UInt8 {
        idx < 32
            ? UInt8((lutLow[node] >> UInt32(idx)) & 1)
            : UInt8((lutHigh[node] >> UInt32(idx - 32)) & 1)
    }

    /// `idx` for `node`, each present slot's bit taken from `value(slot)`.
    @inline(__always)
    private func index(_ node: Int, _ value: (Int) -> UInt8) -> Int {
        var idx = 0
        for d in 0..<6 {
            let nb = slots[node * 6 + d]
            if nb < 0 { continue }
            if value(Int(nb)) == 1 { idx |= 1 << d }
        }
        return idx
    }

    /// Two-phase back-edge latch, exactly `DagDBEngine.latchBackEdges`.
    private func latch(_ t: inout [UInt8]) {
        guard !backEdgeSrc.isEmpty else { return }
        var snapshot = [UInt8](repeating: 0, count: backEdgeSrc.count)
        for i in 0..<backEdgeSrc.count { snapshot[i] = t[backEdgeSrc[i]] }
        for i in 0..<backEdgeDst.count { t[backEdgeDst[i]] = snapshot[i] }
    }

    // MARK: - The two modes (untiled)

    /// One rank-mode tick: ranks highest-present → 0, in place,
    /// registers skipped, then every back edge latched.
    func tickRank(_ truth: [UInt8]) -> [UInt8] {
        var t = truth
        let top = Int(maxRankPresent)
        if top >= 0 {
            for r in stride(from: top, through: 0, by: -1) {
                for node in byRank[r] where !isRegister[node] {
                    t[node] = lutBit(node, index(node) { t[$0] })
                }
            }
        }
        latch(&t)
        return t
    }

    /// One sync-mode tick: every node from the PREVIOUS vector, one hop,
    /// registers holding, then the same latch.
    func tickSync(_ truth: [UInt8]) -> [UInt8] {
        var out = truth
        for node in 0..<nodeCount where !isRegister[node] {
            out[node] = lutBit(node, index(node) { truth[$0] })
        }
        latch(&out)
        return out
    }

    /// One untiled tick in `mode` — AMENDMENT 8, gate (i): the mode of a
    /// round is read from disk and may differ between consecutive rounds,
    /// so the reference takes a MODE SEQUENCE, not one mode for a whole
    /// run. `run(from:modes:)` is that sequence applied in order.
    func tick(_ truth: [UInt8], mode: TickMode) -> [UInt8] {
        mode == .rank ? tickRank(truth) : tickSync(truth)
    }

    /// The vector after each round of `modes`, starting from `truth` —
    /// `result[i]` is the world after round `i + 1`.
    func run(from truth: [UInt8], modes: [TickMode]) -> [[UInt8]] {
        var v = truth
        var out: [[UInt8]] = []
        out.reserveCapacity(modes.count)
        for mode in modes {
            v = tick(v, mode: mode)
            out.append(v)
        }
        return out
    }

    // MARK: - Tiled evaluation (W7)

    /// How a CROSS-TILE input is valued during one world tick.
    enum GhostPolicy {
        /// The ordinary run: the source tile has already ticked this world
        /// tick (rank mode, descending tile order) or the previous tick's
        /// vector is the only vector there is (sync mode).
        case fresh
        /// W7b, "ghosts deleted": every cross-tile input holds its value
        /// from the PREVIOUS world tick.
        case stale
        /// W7a: cross-tile readers of these source nodes see the given bit
        /// instead of the true one — the perturbed strip entry.
        case forced([Int: UInt8])
    }

    /// One rank-mode WORLD tick over a tiling. Tiles are rank-contiguous
    /// and ticked highest-first, so a global highest→0 rank sweep visits
    /// nodes in the same order the router does; the only thing the tiling
    /// changes is where a cross-tile input's value comes from. Registers'
    /// fan-out is intra-tile by construction (see `TiledFixture`), so the
    /// per-tile latch and one latch at the end are the same thing.
    func tickRankWorld(_ truth: [UInt8], tileOf: [Int], policy: GhostPolicy) -> [UInt8] {
        let prev = truth
        var t = truth
        let top = Int(maxRankPresent)
        if top >= 0 {
            for r in stride(from: top, through: 0, by: -1) {
                for node in byRank[r] where !isRegister[node] {
                    let myTile = tileOf[node]
                    let idx = index(node) { src in
                        if tileOf[src] == myTile { return t[src] }
                        switch policy {
                        case .fresh: return t[src]
                        case .stale: return prev[src]
                        case .forced(let map): return map[src] ?? t[src]
                        }
                    }
                    t[node] = lutBit(node, idx)
                }
            }
        }
        latch(&t)
        return t
    }

    /// One sync-mode WORLD tick over a tiling. Sync takes every input from
    /// the previous vector, so `.fresh` and `.stale` coincide; only
    /// `.forced` differs, and only for cross-tile readers (an intra-tile
    /// reader never goes through a strip).
    func tickSyncWorld(_ truth: [UInt8], tileOf: [Int], policy: GhostPolicy) -> [UInt8] {
        var out = truth
        for node in 0..<nodeCount where !isRegister[node] {
            let myTile = tileOf[node]
            let idx = index(node) { src in
                if tileOf[src] == myTile { return truth[src] }
                switch policy {
                case .fresh, .stale: return truth[src]
                case .forced(let map): return map[src] ?? truth[src]
                }
            }
            out[node] = lutBit(node, idx)
        }
        latch(&out)
        return out
    }

    // MARK: - Derived sets the gates assert against

    /// Tile of every node under `boundaries`, the same `tileOf(rank:)`
    /// rule `TiledGraphFiles.write` splits by.
    func tileAssignment(boundaries: [UInt64]) -> [Int] {
        (0..<nodeCount).map { node in
            for (i, b) in boundaries.enumerated() where rank[node] < b { return i }
            return boundaries.count
        }
    }

    /// Every cross-tile edge as `(reader node, source node)` — the
    /// crossings the halo strips carry.
    func crossings(tileOf: [Int]) -> [(reader: Int, source: Int)] {
        var result: [(reader: Int, source: Int)] = []
        for node in 0..<nodeCount {
            for d in 0..<6 {
                let nb = slots[node * 6 + d]
                if nb < 0 { continue }
                if tileOf[Int(nb)] != tileOf[node] { result.append((node, Int(nb))) }
            }
        }
        return result
    }

    /// The reader nodes a strip entry feeds: every node in ANOTHER tile
    /// holding `source` in a slot. Under parity these all flip when the
    /// entry flips, so `Δ_e ⊇ readers(e)`.
    func readers(ofSource source: Int, tileOf: [Int]) -> Set<Int> {
        var result = Set<Int>()
        for node in 0..<nodeCount where tileOf[node] != tileOf[source] {
            for d in 0..<6 where slots[node * 6 + d] == Int32(source) {
                result.insert(node)
                break
            }
        }
        return result
    }

    /// Distinct source nodes that appear in some tile's committed lower
    /// strip — one entry per `(source tile, local)` the strips carry.
    func stripEntrySources(tileOf: [Int]) -> [Int] {
        var seen = Set<Int>()
        for c in crossings(tileOf: tileOf) { seen.insert(c.source) }
        return seen.sorted()
    }

    /// The EXACT change set between a `stale` and a `fresh` world tick,
    /// derived node-locally instead of by re-running the evaluator.
    ///
    /// Every combinational node here is parity (or its complement) over
    /// its present slots, so its output flips exactly when an ODD number
    /// of its inputs differ between the two runs. An input's value at the
    /// moment the node is evaluated is: for an intra-tile source, that
    /// source's own post-tick value in the same run (rank mode writes each
    /// node once, higher ranks first); for a cross-tile source, the
    /// source's post-tick value in `fresh` and its PREVIOUS-tick value in
    /// `stale`. A register's post-tick value is its back-edge source's, so
    /// it differs exactly when that source does.
    ///
    /// This is the number W7b asserts `differing(stale, fresh)` against —
    /// a statement about the object's sensitivity, not about the evaluator
    /// agreeing with itself. It replaces AMENDMENT 6 letter 4's
    /// `|D| >= (crossings whose source changed)`, which counts EDGES
    /// against a set of NODES and is false on a correct engine: side 16,
    /// tick 1, 137 crossings moved and |D| = 68, because several crossings
    /// land on one reader and an even number of them cancels under parity.
    func oddInputChangeSet(
        prev: [UInt8], stale: [UInt8], fresh: [UInt8], tileOf: [Int], mode: TickMode
    ) -> Set<Int> {
        var result = Set<Int>()
        for node in 0..<nodeCount where !isRegister[node] {
            var odd = false
            for d in 0..<6 {
                let nb = slots[node * 6 + d]
                if nb < 0 { continue }
                let s = Int(nb)
                // A register holds through the combinational pass, so both
                // runs read the SAME byte for it — the value it had before
                // this tick's latch — whether the edge is intra- or
                // cross-tile (AMENDMENT 7, finding A). It can never be a
                // source of difference.
                if isRegister[s] { continue }
                let inStale: UInt8 = (tileOf[s] == tileOf[node]) ? stale[s] : prev[s]
                if (inStale == 1) != (fresh[s] == 1) { odd.toggle() }
            }
            if odd { result.insert(node) }
        }
        for i in 0..<backEdgeDst.count where result.contains(backEdgeSrc[i]) {
            result.insert(backEdgeDst[i])
        }
        return result
    }

    /// Indices where two vectors differ.
    static func differing(_ a: [UInt8], _ b: [UInt8]) -> Set<Int> {
        var result = Set<Int>()
        for i in 0..<min(a.count, b.count) where a[i] != b[i] { result.insert(i) }
        return result
    }
}
