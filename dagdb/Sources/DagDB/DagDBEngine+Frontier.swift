/// DagDBEngine+Frontier — the frontier session.
///
/// Inside a frontier session (`frontierSession`, a counting session that also
/// carries frontier state) every rank-mode tick the caller declares
/// rank-ordered (`tick(tickNumber:rankOrderVerified: true)`) evaluates only
/// the nodes that can change, and writes the same bytes, and reports the same
/// counts, as the plain per-rank tick inside a counting session:
///
/// - The session's first tick is a whole tick: every rank and the latch
///   dispatched whole (a plain tick), recording what it changed. It pushes
///   nothing into its own half, which no dispatch of it reads;
///   its pushes into the next tick's half are as on every tick.
/// - Every later tick dispatches, per rank (ranks descending, as the plain
///   tick), the rank's worklist: readers through a slot of a node whose byte
///   changed this tick at a higher rank; readers of a register the previous
///   latch changed; NOSKIP nodes that changed in the previous tick (their
///   rule reads their own previous byte); the kernel-evaluated back-edge
///   destinations (register flag cleared), every tick, with their readers.
/// - The latch writes the effective back edges (the latch plan: one per
///   destination, its last in list order) whose source changed since the
///   previous latch's snapshot — changed by this tick's kernel, or by the
///   previous latch when the source is itself a destination — and the
///   evaluated destinations', every tick. One kernel, or two phases when an
///   effective source is a destination, as the plain GPU latch.
/// - A rank whose list holds more than `frontierWholeFraction` of its nodes
///   is dispatched whole (its per-rank list), the latch likewise over every
///   effective back edge. Both forms are exact; the policy moves time only.
///   The default is `.infinity` — no whole-rank fallback after the first
///   tick; the threshold is a test seam.
///
/// Why it is exact. After the whole first tick every node the plain tick
/// evaluates holds its rule's value of its inputs (and, NOSKIP, of its
/// previous byte), and every register holds its effective source's snapshot.
/// A node not on its rank's list has inputs that did not change since its
/// last evaluation and (NOSKIP) a byte that did not change in the previous
/// tick, so the plain tick would write the byte it holds; an effective back
/// edge not listed has a source whose byte equals the previous snapshot and a
/// destination nothing else writes, so the plain latch would write the byte
/// it holds. Nodes and back edges are listed once per tick (a bitmap), so a
/// node is evaluated once per tick, as in the plain tick.
///
/// The precondition, as the counting session's: the session's body only ticks rank mode. A
/// truth, LUT, mode or table write between two ticks of one session is not
/// seen (the daemon's TICK UNTIL_STABLE body only ticks); a topology write
/// through the engine is, and refuses (`CountingSessionRefusal.topologyChanged`),
/// as the counting session refuses a back-edge or register-flag change. A tick
/// of the session that is not rank-ordered runs the plain path and the next
/// frontier tick is whole again.
///
/// The reverse index (`FrontierIndex`) is the CSR of readers: for every
/// source node, the nodes that read it through an in-range slot (slots 0…5,
/// `frontierIndexedSlots`), then the effective back edges it feeds (index
/// with bit 31 set). Built on the CPU in two O(slots + back edges) passes
/// when a frontier session opens and finds none; kept between sessions; the
/// frontier's lists, bitmaps and counters are allocated with it and kept, but
/// their contents are reset when a session opens (the frontier state is never
/// kept: every session starts with a whole tick). Dropped by every topology
/// writer: a change to either back-edge list, a rank write
/// (`markRankTopologyDirty`), and `dropFrontierIndex()`, which the daemon
/// calls for every command that may move a slot or a rank — never by a
/// table, mode, truth, weight or value write.
///
/// Memory (`allocationBytes`, `frontier.*`): CSR offsets 4 B/node, entries
/// 4 B per present slot and per effective back edge, two node lists of
/// 4 B/node, two node bitmaps of 1 bit/node, two latch lists of 4 B and two
/// latch bitmaps of 1 bit per effective back edge, per-rank counters; plus
/// the latch plan (`latch.*`, 8 B per effective back edge).
///
/// `sessionTicks` encodes up to k such ticks into one
/// command buffer — tick j on half `cur ^ (j & 1)`, its two counts into its
/// own 32-byte slot of the session's `batchCounters` — so the CPU waits on
/// the GPU once per batch; TICK UNTIL_STABLE runs on it (k = 16). Nothing a
/// tick needs from the CPU is per tick but the counts and the whole flag
/// (the first tick of a session), which the batch encodes. Kernel-evaluated
/// destinations, the `latchOnGPU = false` seam, and a session without a
/// frontier take one tick per call of `tick`.
///
/// The push is a SIMD group's (`h2_push_group` in the kernels). The readers of
/// every changed node of the group are walked together, one entry per lane per
/// round, so a node with k readers is pushed in about k / 32 rounds instead of
/// k serial steps; each entry is deduplicated by its half's bitmap as before,
/// and a round's new entries take their slots with one atomic add per
/// receiving list. The kernels that push need SIMD groups of 32 and
/// threadgroups of whole SIMD groups (`frontierPipelines` checks; otherwise
/// no frontier, the counting path).
///
/// A batch holds at most
/// `maxDispatchesPerCommandBuffer` dispatches (at least one tick); every
/// tick's command buffer has its status read after the wait
/// (`waitCounted` → `commandBufferCompleted`), and one that did not complete
/// claims nothing; a session on a graph deeper than `frontierMaxRankLevels`
/// non-empty rank levels opens no frontier (`prepareFrontier`: the depth
/// guard) and runs the counting path.

import Metal
import Foundation

extension DagDBEngine {

    /// The slots the reverse index reads: all six. (A test control builds
    /// it from the first five, one line here.)
    static let frontierIndexedSlots = 6

    // MARK: - The index and the frontier's buffers

    final class FrontierIndex {
        let nodeCount: Int
        /// Rank levels the index's per-rank arrays cover (`effectiveRankCount`
        /// when it was built; a rank write drops the index).
        let levels: Int
        /// The latch plan the index's back-edge entries number (nil: no back
        /// edges). Held, so a stale index stays self-consistent.
        let plan: LatchPlan?
        var edges: Int { plan?.count ?? 0 }
        let entries: Int
        let csrOff: MTLBuffer       // UInt32 × (N + 1)
        let csrEnt: MTLBuffer       // UInt32 × entries
        let lists: MTLBuffer        // UInt32 × 2N: two halves, each rank's list at its span offset
        let bits: MTLBuffer         // UInt32 × 2 × words: one bit per node per half
        let latchLists: MTLBuffer   // UInt32 × 2M (one word when there are no back edges)
        let latchBits: MTLBuffer    // UInt32 × 2 × edgeWords (one word when there are none)
        let cnt: MTLBuffer          // UInt32 × (2L + 4), atomic counters
        let rinfo: MTLBuffer        // UInt32 × (3L + 1), the session's span offsets, counts, thresholds
        let meta: MTLBuffer         // UInt32 × (5L + 5), the args kernels' output
        let words: Int
        let edgeWords: Int

        init(nodeCount: Int, levels: Int, plan: LatchPlan?, entries: Int, csrOff: MTLBuffer, csrEnt: MTLBuffer,
             lists: MTLBuffer, bits: MTLBuffer, latchLists: MTLBuffer, latchBits: MTLBuffer,
             cnt: MTLBuffer, rinfo: MTLBuffer, meta: MTLBuffer, words: Int, edgeWords: Int) {
            self.nodeCount = nodeCount; self.levels = levels; self.plan = plan; self.entries = entries
            self.csrOff = csrOff; self.csrEnt = csrEnt; self.lists = lists; self.bits = bits
            self.latchLists = latchLists; self.latchBits = latchBits
            self.cnt = cnt; self.rinfo = rinfo; self.meta = meta; self.words = words; self.edgeWords = edgeWords
        }

        /// The buffers by name (`allocationBytes`).
        var namedBytes: [(name: String, bytes: Int)] {
            [("frontier.csrOffsets", csrOff.length), ("frontier.csrEntries", csrEnt.length),
             ("frontier.lists", lists.length), ("frontier.bits", bits.length),
             ("frontier.latchLists", latchLists.length), ("frontier.latchBits", latchBits.length),
             ("frontier.counters", cnt.length), ("frontier.rankInfo", rinfo.length), ("frontier.meta", meta.length)]
        }
    }

    /// The frontier kernels.
    final class FrontierPipelines {
        let seed, rankArgs, rank, rankBinary, latchArgs, latchDirect, latchSnapshot, latchWrite: MTLComputePipelineState
        init(seed: MTLComputePipelineState, rankArgs: MTLComputePipelineState, rank: MTLComputePipelineState,
             rankBinary: MTLComputePipelineState, latchArgs: MTLComputePipelineState,
             latchDirect: MTLComputePipelineState, latchSnapshot: MTLComputePipelineState,
             latchWrite: MTLComputePipelineState) {
            self.seed = seed; self.rankArgs = rankArgs; self.rank = rank; self.rankBinary = rankBinary
            self.latchArgs = latchArgs; self.latchDirect = latchDirect
            self.latchSnapshot = latchSnapshot; self.latchWrite = latchWrite
        }
    }

    /// One session's frontier: the index it ticks on, which half is this
    /// tick's, whether the next tick must be whole, and the evaluated
    /// destinations with their effective back edges (`seeds`).
    final class FrontierState {
        let index: FrontierIndex
        let pipes: FrontierPipelines
        var cur = 0
        var needsFull = true
        let seeds: MTLBuffer?       // UInt32 pairs (destination, effective back edge)
        let seedCount: Int
        init(index: FrontierIndex, pipes: FrontierPipelines, seeds: MTLBuffer?, seedCount: Int) {
            self.index = index; self.pipes = pipes; self.seeds = seeds; self.seedCount = seedCount
        }

        /// Both halves empty: every bit clear, every count zero.
        func resetState() {
            let ix = index
            memset(ix.bits.contents(), 0, ix.bits.length)
            memset(ix.latchBits.contents(), 0, ix.latchBits.length)
            memset(ix.cnt.contents(), 0, ix.cnt.length)
            cur = 0
        }
    }

    /// The Swift twin of the kernels' `FrontierParams` (eleven 32-bit words).
    struct FrontierParams {
        var rank: UInt32 = 0
        var levels: UInt32 = 0
        var cur: UInt32 = 0
        var full: UInt32 = 0
        var tpg: UInt32 = 1
        var words: UInt32 = 0
        var nodes: UInt32 = 0
        var edges: UInt32 = 0
        var edgeWords: UInt32 = 0
        var count: UInt32 = 0
        /// 1 = a changed node pushes its readers into this tick's
        /// half; 0 on the session's first, whole tick, whose half nothing reads.
        var push: UInt32 = 1
    }

    /// The frontier's buffers by name: 0 bytes each while there is no index;
    /// `frontier.evaluatedSeeds` while a session with evaluated destinations
    /// is open.
    /// The bytes the frontier's state holds now (0 while there is none): the first-use term the
    /// ledger keeps for TICK UNTIL_STABLE.
    public var frontierBytesHeld: Int { frontierAllocationBytes().reduce(0) { $0 + $1.bytes } }

    func frontierAllocationBytes() -> [(name: String, bytes: Int)] {
        let names = ["frontier.csrOffsets", "frontier.csrEntries", "frontier.lists", "frontier.bits",
                     "frontier.latchLists", "frontier.latchBits", "frontier.counters", "frontier.rankInfo",
                     "frontier.meta"]
        var out = frontierIndex?.namedBytes ?? names.map { ($0, 0) }
        out.append(("frontier.evaluatedSeeds", latchChangeCounter?.frontier?.seeds?.length ?? 0))
        return out
    }

    /// Drop the reverse index (the daemon calls this for every
    /// command that may move a slot or a rank; a library caller that writes
    /// `neighborsBuf` directly calls it too). The next frontier session
    /// builds a new one.
    public func dropFrontierIndex() { frontierIndex = nil }

    /// Whether the engine holds a reverse index now. Read by the gates.
    public var hasFrontierIndex: Bool { frontierIndex != nil }

    func frontierPipelines() -> FrontierPipelines? {
        if let p = frontierPipelineCache { return p }
        if frontierPipelinesTried { return nil }
        frontierPipelinesTried = true
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { frontierPipelineBuildMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000 }   // diagnostic
        func make(_ name: String) -> MTLComputePipelineState? {
            guard let fn = library.makeFunction(name: name) else { return nil }
            return try? device.makeComputePipelineState(function: fn)
        }
        guard let seed = make("dagdb_frontier_seed"), let rankArgs = make("dagdb_frontier_rank_args"),
              let rank = make("dagdb_frontier_rank"), let rankBinary = make("dagdb_frontier_rank_binary"),
              let latchArgs = make("dagdb_frontier_latch_args"), let latchDirect = make("dagdb_frontier_latch_direct"),
              let latchSnapshot = make("dagdb_frontier_latch_snapshot"),
              let latchWrite = make("dagdb_frontier_latch_write") else { return nil }
        // The push is a SIMD group's (`h2_push_group`, uniform control flow over 32 lanes), so every
        // kernel that pushes, and the latch's snapshot whose width bounds the latch's threadgroups, must run in
        // SIMD groups of 32 and in threadgroups of whole SIMD groups. Otherwise no frontier: the session runs
        // the counting path (exact).
        for k in [seed, rank, rankBinary, latchDirect, latchSnapshot, latchWrite]
        where k.threadExecutionWidth != 32 || k.maxTotalThreadsPerThreadgroup % 32 != 0 { return nil }
        let p = FrontierPipelines(seed: seed, rankArgs: rankArgs, rank: rank, rankBinary: rankBinary,
                                  latchArgs: latchArgs, latchDirect: latchDirect, latchSnapshot: latchSnapshot,
                                  latchWrite: latchWrite)
        frontierPipelineCache = p
        return p
    }

    /// Two O(slots + back edges) passes over the slots and the plan: count
    /// each source's readers, prefix-sum, fill (readers in ascending id, then
    /// the back edges the source feeds, in plan order). nil, with nothing
    /// kept, if an allocation fails or the counts do not fit 32 bits.
    func buildFrontierIndex(plan: LatchPlan?) -> FrontierIndex? {
        let n = nodeCount
        let m = plan?.count ?? 0
        let levels = effectiveRankCount
        guard n > 0, n < (1 << 31), m < (1 << 31), 6 * n + m < Int(UInt32.max) else { return nil }
        let shared = MTLResourceOptions.storageModeShared
        guard let offBuf = device.makeBuffer(length: (n + 1) * 4, options: shared) else { return nil }
        let off = offBuf.contents().bindMemory(to: UInt32.self, capacity: n + 1)
        memset(off, 0, (n + 1) * 4)
        let nb = UnsafePointer(neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6))
        let slots = Self.frontierIndexedSlots
        let effSrc = plan.map { UnsafePointer($0.effSrc.contents().bindMemory(to: UInt32.self, capacity: max($0.count, 1))) }
        // Pass 1: readers per source, at off[source + 1].
        for u in 0..<n {
            let row = nb + u * 6
            for d in 0..<slots {
                let s = row[d]
                if s >= 0 && Int(s) < n { off[Int(s) + 1] &+= 1 }
            }
        }
        if let es = effSrc { for e in 0..<m { off[Int(es[e]) + 1] &+= 1 } }
        for i in 0..<n { off[i + 1] &+= off[i] }
        let entries = Int(off[n])
        guard let entBuf = device.makeBuffer(length: max(entries, 1) * 4, options: shared),
              let rawCursor = malloc(n * 4) else { return nil }
        defer { free(rawCursor) }
        let cursor = rawCursor.bindMemory(to: UInt32.self, capacity: n)
        memcpy(cursor, off, n * 4)
        let ent = entBuf.contents().bindMemory(to: UInt32.self, capacity: max(entries, 1))
        // Pass 2: fill.
        for u in 0..<n {
            let row = nb + u * 6
            for d in 0..<slots {
                let s = row[d]
                if s >= 0 && Int(s) < n {
                    let k = Int(cursor[Int(s)]); ent[k] = UInt32(u); cursor[Int(s)] = UInt32(k + 1)
                }
            }
        }
        if let es = effSrc {
            for e in 0..<m {
                let s = Int(es[e]); let k = Int(cursor[s]); ent[k] = UInt32(e) | 0x8000_0000; cursor[s] = UInt32(k + 1)
            }
        }
        // The frontier's state buffers, kept with the index.
        let words = (n + 31) / 32
        let edgeWords = max((m + 31) / 32, 1)
        guard let lists = device.makeBuffer(length: 2 * n * 4, options: shared),
              let bits = device.makeBuffer(length: 2 * words * 4, options: shared),
              let latchLists = device.makeBuffer(length: 2 * max(m, 1) * 4, options: shared),
              let latchBits = device.makeBuffer(length: 2 * edgeWords * 4, options: shared),
              let cnt = device.makeBuffer(length: (2 * levels + 4) * 4, options: shared),
              let rinfo = device.makeBuffer(length: (3 * levels + 1) * 4, options: shared),
              let meta = device.makeBuffer(length: (5 * levels + 5) * 4, options: shared) else { return nil }
        frontierIndexBuildCount += 1
        return FrontierIndex(nodeCount: n, levels: levels, plan: plan, entries: entries, csrOff: offBuf,
                             csrEnt: entBuf, lists: lists, bits: bits, latchLists: latchLists, latchBits: latchBits,
                             cnt: cnt, rinfo: rinfo, meta: meta, words: words, edgeWords: edgeWords)
    }

    /// When a frontier session opens: the rank lists, the plan, the index
    /// (built if there is none), the session's per-rank info and the
    /// evaluated destinations' seeds; the state reset. nil when any of it
    /// cannot be had — the session's ticks then run the counting session's
    /// plain path (exact; only not incremental).
    func prepareFrontier(counter c: LatchChangeCounter) -> FrontierState? {
        guard (try? prepareRankLists()) != nil, rankListBuf != nil else { return nil }
        // The depth guard. Past `frontierMaxRankLevels` non-empty
        // rank levels the session runs the counting path (no frontier, no
        // index built): one tick per command buffer, one dispatch per rank.
        lastFrontierDepthGuarded = nonEmptyRankLevels > frontierMaxRankLevels
        if lastFrontierDepthGuarded { return nil }
        guard let pipes = frontierPipelines() else { return nil }
        let plan: LatchPlan?
        if backEdgeSrcs.isEmpty {
            plan = nil
        } else {
            if latchPlan == nil { latchPlan = buildLatchPlan() }
            guard let p = latchPlan else { return nil }
            plan = p
        }
        if frontierIndex == nil {
            let t0 = CFAbsoluteTimeGetCurrent()
            frontierIndex = buildFrontierIndex(plan: plan)
            lastFrontierIndexBuildMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        }
        guard let ix = frontierIndex, ix.levels == effectiveRankCount, rankSpanTable.count == ix.levels else {
            return nil
        }
        // Per rank: span offset, span count, whole threshold; the latch's.
        let L = ix.levels
        let ri = ix.rinfo.contents().bindMemory(to: UInt32.self, capacity: 3 * L + 1)
        func threshold(_ size: Int) -> UInt32 {
            let t = Double(size) * frontierWholeFraction
            return t.isFinite && t < Double(UInt32.max) ? UInt32(t.rounded(.down)) : UInt32.max
        }
        for r in 0..<L {
            ri[r] = UInt32(rankSpanTable[r].offset)
            ri[L + r] = UInt32(rankSpanTable[r].count)
            ri[2 * L + r] = threshold(rankSpanTable[r].count)
        }
        ri[3 * L] = threshold(ix.edges)
        // The evaluated destinations (the counting session's list) and their effective back edges.
        var seeds: MTLBuffer? = nil
        var seedCount = 0
        if !c.evaluatedDsts.isEmpty, let p = ix.plan {
            let want = Set(c.evaluatedDsts)
            var pairs: [UInt32] = []
            let ed = p.effDst.contents().bindMemory(to: UInt32.self, capacity: max(p.count, 1))
            for e in 0..<p.count where want.contains(Int(ed[e])) { pairs += [ed[e], UInt32(e)] }
            seedCount = pairs.count / 2
            guard let b = device.makeBuffer(bytes: pairs, length: max(pairs.count, 2) * 4,
                                            options: .storageModeShared) else { return nil }
            seeds = b
        }
        let f = FrontierState(index: ix, pipes: pipes, seeds: seeds, seedCount: seedCount)
        f.resetState()
        return f
    }

    // MARK: - Encoding (one tick, or a batch of ticks, in one command buffer)

    /// One compute encoder's frontier dispatches: a buffer barrier before
    /// every dispatch but the first, and the counts the diagnostics read.
    struct FrontierEncoding {
        let enc: MTLComputeCommandEncoder
        var first = true
        var dispatches = 0          // every dispatch encoded
        var rankDispatches = 0      // the rank kernels' (one per non-empty rank per tick)
        init(_ enc: MTLComputeCommandEncoder) { self.enc = enc }

        mutating func barrier() {
            if !first { enc.memoryBarrier(scope: .buffers) }
            first = false
        }

        mutating func one(_ pipeline: MTLComputePipelineState, _ p: inout FrontierParams) {
            enc.setComputePipelineState(pipeline)
            enc.setBytes(&p, length: MemoryLayout<FrontierParams>.stride, index: 7)
            enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            dispatches += 1
        }

        mutating func indirect(_ pipeline: MTLComputePipelineState, _ p: inout FrontierParams, meta: MTLBuffer,
                               argsWord: Int, tpg: Int) {
            enc.setComputePipelineState(pipeline)
            enc.setBytes(&p, length: MemoryLayout<FrontierParams>.stride, index: 7)
            enc.dispatchThreadgroups(indirectBuffer: meta, indirectBufferOffset: argsWord * 4,
                                     threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
            dispatches += 1
        }
    }

    /// The buffers every frontier kernel reads (indices 0–6 and 8–17).
    func bindFrontier(_ enc: MTLComputeCommandEncoder, _ ix: FrontierIndex) {
        var nodeCount32 = UInt32(nodeCount)
        enc.setBuffer(truthStateBuf, offset: 0, index: 0)
        enc.setBuffer(rankBuf, offset: 0, index: 1)
        enc.setBuffer(lut6LowBuf, offset: 0, index: 2)
        enc.setBuffer(lut6HighBuf, offset: 0, index: 3)
        enc.setBuffer(neighborsBuf, offset: 0, index: 4)
        enc.setBuffer(isRegisterBuf, offset: 0, index: 5)
        enc.setBytes(&nodeCount32, length: 4, index: 6)
        enc.setBuffer(ix.lists, offset: 0, index: 8)
        enc.setBuffer(ix.bits, offset: 0, index: 9)
        enc.setBuffer(ix.cnt, offset: 0, index: 10)
        enc.setBuffer(ix.rinfo, offset: 0, index: 11)
        enc.setBuffer(ix.meta, offset: 0, index: 12)
        enc.setBuffer(ix.csrOff, offset: 0, index: 13)
        enc.setBuffer(ix.csrEnt, offset: 0, index: 14)
        enc.setBuffer(rankListBuf!, offset: 0, index: 15)
        enc.setBuffer(ix.latchLists, offset: 0, index: 16)
        enc.setBuffer(ix.latchBits, offset: 0, index: 17)
    }

    /// One tick's parameters: `cur` this tick's half, `full` the session's first (whole) tick.
    ///
    /// The whole
    /// tick pushes nothing into its own half (`push` 0): every rank and the
    /// latch take their whole lists there, so no dispatch reads it, and the
    /// session's open (`resetState`) left it empty. Its pushes into the next
    /// half (a changed NOSKIP node; the latch's: the readers of a changed
    /// register and the back edges it feeds) are every tick's, so tick 1's
    /// lists are seeded as before.
    func frontierParams(_ ix: FrontierIndex, cur: Int, full: Bool) -> FrontierParams {
        var p = FrontierParams()
        p.levels = UInt32(ix.levels)
        p.cur = UInt32(cur)
        p.full = full ? 1 : 0
        p.push = full ? 0 : 1
        p.words = UInt32(ix.words)
        p.nodes = UInt32(ix.nodeCount)
        p.edges = UInt32(ix.edges)
        p.edgeWords = UInt32(ix.edgeWords)
        return p
    }

    /// The ranks of one tick, descending as the plain tick: per rank the args
    /// kernel (one thread: whole or listed, the indirect threadgroups), then
    /// the rank's kernel as an indirect dispatch. The kernels' changed-node
    /// count goes to `counter` at `offset`. The caller has bound the ternary
    /// lanes when `general`.
    func encodeFrontierRanks(_ e: inout FrontierEncoding, _ f: FrontierState, _ p: inout FrontierParams,
                             general: Bool, counter: MTLBuffer, offset: Int) {
        let L = f.index.levels
        let evalPipe = general ? f.pipes.rank : f.pipes.rankBinary
        let evalTpg = evalPipe.maxTotalThreadsPerThreadgroup
        e.enc.setBuffer(counter, offset: offset, index: 18)
        for r in stride(from: L - 1, through: 0, by: -1) where rankSpanTable[r].count > 0 {
            p.rank = UInt32(r)
            p.tpg = UInt32(evalTpg)
            e.barrier()
            e.one(f.pipes.rankArgs, &p)
            e.barrier()
            e.indirect(evalPipe, &p, meta: f.index.meta, argsWord: 2 * L + 2 + 3 * r, tpg: evalTpg)
            e.rankDispatches += 1
        }
    }

    /// The latch of one tick: its args kernel, then one kernel, or two phases
    /// when an effective source is a destination (as the plain GPU latch). The latch's count of
    /// changed registers goes to `counter` at `offset`.
    func encodeFrontierLatch(_ e: inout FrontierEncoding, _ f: FrontierState, _ plan: LatchPlan,
                             _ p: inout FrontierParams, counter: MTLBuffer, offset: Int) {
        let L = f.index.levels
        let pipes = f.pipes
        let latchTpg = plan.twoPhase
            ? min(pipes.latchSnapshot.maxTotalThreadsPerThreadgroup, pipes.latchWrite.maxTotalThreadsPerThreadgroup)
            : pipes.latchDirect.maxTotalThreadsPerThreadgroup
        p.tpg = UInt32(latchTpg)
        e.enc.setBuffer(counter, offset: offset, index: 18)
        e.enc.setBuffer(plan.effSrc, offset: 0, index: 26)
        e.enc.setBuffer(plan.effDst, offset: 0, index: 27)
        e.barrier()
        e.one(pipes.latchArgs, &p)
        e.barrier()
        if plan.twoPhase {
            e.enc.setBuffer(plan.scratch!, offset: 0, index: 28)
            e.indirect(pipes.latchSnapshot, &p, meta: f.index.meta, argsWord: 5 * L + 2, tpg: latchTpg)
            e.barrier()
            e.indirect(pipes.latchWrite, &p, meta: f.index.meta, argsWord: 5 * L + 2, tpg: latchTpg)
        } else {
            e.indirect(pipes.latchDirect, &p, meta: f.index.meta, argsWord: 5 * L + 2, tpg: latchTpg)
        }
    }

    /// Wait for a tick's command buffer. Inside a session the wait
    /// is counted, with the buffer's GPU time.
    ///
    /// Then its status — true iff it completed.
    /// Any other status sets `gpuFailure` (`commandBufferCompleted`); the
    /// caller claims nothing of that buffer and returns.
    @discardableResult
    func waitCounted(_ b: MTLCommandBuffer) -> Bool {
        b.waitUntilCompleted()
        if let c = latchChangeCounter {
            c.gpuWaits += 1
            let g = b.gpuEndTime - b.gpuStartTime
            if g > 0 { c.gpuMs += g * 1000 }
        }
        return commandBufferCompleted(b)
    }

    // MARK: - The frontier tick

    /// One tick of a frontier session (the caller has admitted it and found
    /// it rank-ordered). In one command buffer: the evaluated destinations'
    /// seeds, then per rank (descending) the args kernel and the rank's
    /// dispatch, then the latch's args and the latch. A session whose plan
    /// has kernel-evaluated destinations reads their bytes between the kernel
    /// and the latch (the counting session's `afterKernel`), so its latch goes
    /// in a second command buffer, as the plain GPU latch's. No command buffer:
    /// nothing runs, as the plain path.
    ///
    /// With the seam `latchOnGPU = false` (every rank-mode tick
    /// latches on the CPU) the latch is the CPU's (`latchBackEdges`, the
    /// counting latch inside the session) after the ranks' command buffer,
    /// and the frontier's latch bookkeeping is done on the CPU as the latch
    /// kernels do it (`frontierLatchOnCPU`). The daemon never sets the seam.
    func tickFrontier(_ f: FrontierState, counting c: LatchChangeCounter) {
        guard !commandBufferFailsForTesting(), let cmdBuf = makeGPUCommandBuffer(),
              let enc = cmdBuf.makeComputeCommandEncoder() else { return }
        let ix = f.index
        let full = f.needsFull
        if full { f.resetState() }
        c.beginTick(engine: self)
        lastRankTickCounted = true
        let general = chooseTickKernel() == .general
        let L = ix.levels
        let cntP = ix.cnt.contents().bindMemory(to: UInt32.self, capacity: 2 * L + 4)
        cntP[2 * L + 2] = 0
        cntP[2 * L + 3] = 0
        ix.plan?.counter.contents().storeBytes(of: UInt32(0), as: UInt32.self)

        var p = frontierParams(ix, cur: f.cur, full: full)
        var e = FrontierEncoding(enc)
        bindFrontier(enc, ix)

        // The kernel-evaluated destinations: listed every tick.
        if f.seedCount > 0, let seeds = f.seeds {
            e.barrier()
            enc.setComputePipelineState(f.pipes.seed)
            p.count = UInt32(f.seedCount)
            enc.setBytes(&p, length: MemoryLayout<FrontierParams>.stride, index: 7)
            enc.setBuffer(seeds, offset: 0, index: 19)
            let tpg = f.pipes.seed.maxTotalThreadsPerThreadgroup
            enc.dispatchThreadgroups(MTLSize(width: (f.seedCount + tpg - 1) / tpg, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
            e.dispatches += 1
        }
        // The ranks, descending, as the plain tick.
        if general { bindTernaryLanes(enc, firstIndex: 19) }
        encodeFrontierRanks(&e, f, &p, general: general, counter: c.kernelCount, offset: 0)

        // The latch. The CPU reads between the kernel and the latch when the
        // plan has kernel-evaluated destinations, or when the latch is the
        // CPU's (the `latchOnGPU` seam): the ranks' buffer is committed first.
        if let plan = ix.plan, latchOnGPU == false || !c.evaluatedDsts.isEmpty {
            enc.endEncoding()
            cmdBuf.commit()
            c.noteBuffer(ticks: 1, dispatches: e.dispatches)                   // dispatches counted per buffer
            guard waitCounted(cmdBuf) else { f.needsFull = true; return }       // a failed buffer claims nothing
            c.afterKernel(engine: self)
            if latchOnGPU == false {
                frontierLatchOnCPU(f, plan: plan)          // sets lastCount (the counting latch)
                c.finishTick(engine: self)
                finishFrontierTick(f, full: full, ticks: 1, dispatches: e.dispatches,
                                   rankDispatches: e.rankDispatches, latchOnGPU: false)
                return
            }
            guard let b2 = makeGPUCommandBuffer(), let enc2 = b2.makeComputeCommandEncoder() else {
                // No buffer for the latch: the tick did not latch. Finish its
                // counts as the CPU latch's fallback would, and start over.
                latchBackEdges()
                c.finishTick(engine: self)
                f.needsFull = true
                lastTickFrontier = true; lastTickFrontierFull = full
                return
            }
            var e2 = FrontierEncoding(enc2)
            bindFrontier(enc2, ix)
            encodeFrontierLatch(&e2, f, plan, &p, counter: plan.counter, offset: 0)
            enc2.endEncoding()
            b2.commit()
            c.noteBuffer(ticks: 0, dispatches: e2.dispatches)                  // the tick's latch
            guard waitCounted(b2) else { f.needsFull = true; return }          // a failed buffer claims nothing
            c.lastCount = Int(plan.counter.contents().load(as: UInt32.self))
            c.finishTick(engine: self)
            finishFrontierTick(f, full: full, ticks: 1, dispatches: e.dispatches + e2.dispatches,
                               rankDispatches: e.rankDispatches, latchOnGPU: true)
            return
        }
        if let plan = ix.plan { encodeFrontierLatch(&e, f, plan, &p, counter: plan.counter, offset: 0) }
        enc.endEncoding()
        cmdBuf.commit()
        c.noteBuffer(ticks: 1, dispatches: e.dispatches)                       // dispatches counted per buffer
        guard waitCounted(cmdBuf) else { f.needsFull = true; return }           // a failed buffer claims nothing
        c.afterKernel(engine: self)
        c.lastCount = ix.plan.map { Int($0.counter.contents().load(as: UInt32.self)) } ?? 0
        c.finishTick(engine: self)
        finishFrontierTick(f, full: full, ticks: 1, dispatches: e.dispatches, rankDispatches: e.rankDispatches,
                           latchOnGPU: ix.plan != nil)
    }

    /// The diagnostics of the last frontier command buffer (its last tick's
    /// ranks; its evaluated and latched entries summed over its ticks), and
    /// the half and the whole flag moved on by its ticks.
    func finishFrontierTick(_ f: FrontierState, full: Bool, ticks: Int, dispatches: Int, rankDispatches: Int,
                            latchOnGPU gpuLatch: Bool) {
        let ix = f.index
        let L = ix.levels
        let meta = ix.meta.contents().bindMemory(to: UInt32.self, capacity: 5 * L + 5)
        let cntP = ix.cnt.contents().bindMemory(to: UInt32.self, capacity: 2 * L + 4)
        var wholeRanks = 0, listedRanks = 0
        for r in 0..<L where rankSpanTable[r].count > 0 {
            if meta[2 * r] != 0 { wholeRanks += 1 } else if meta[2 * r + 1] > 0 { listedRanks += 1 }
        }
        lastFrontierWholeRanks = wholeRanks
        lastFrontierListedRanks = listedRanks
        lastFrontierEvaluated = Int(cntP[2 * L + 2])
        lastFrontierLatched = Int(cntP[2 * L + 3])
        lastRankTickDispatchCount = rankDispatches
        lastFrontierDispatches = dispatches
        lastFrontierBatchTicks = ticks
        lastLatchOnGPU = gpuLatch
        lastLatchTwoPhase = gpuLatch && (ix.plan?.twoPhase ?? false)
        lastTickFrontier = true
        lastTickFrontierFull = full && ticks == 1
        f.cur ^= ticks & 1
        f.needsFull = false
    }

    /// The seam `latchOnGPU = false` inside a frontier session: the CPU
    /// latch (`latchBackEdges`; inside the session the counting latch, which
    /// sets `lastCount`), then the frontier's latch bookkeeping as the latch
    /// kernels do it — this tick's latch list emptied (the CPU latched every
    /// back edge), and every destination whose byte the latch changed lists
    /// its readers and the back edges it feeds for the next tick. A
    /// destination the kernels would not have listed has an unchanged source,
    /// so the CPU writes it its own byte: the same destinations change.
    func frontierLatchOnCPU(_ f: FrontierState, plan: LatchPlan) {
        let ix = f.index
        let L = ix.levels
        let m = plan.count
        let cnt = ix.cnt.contents().bindMemory(to: UInt32.self, capacity: 2 * L + 4)
        let lbits = ix.latchBits.contents().bindMemory(to: UInt32.self, capacity: 2 * ix.edgeWords)
        memset(lbits + f.cur * ix.edgeWords, 0, ix.edgeWords * 4)
        cnt[2 * L + f.cur] = 0
        cnt[2 * L + 3] = UInt32(m)
        let truth = truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: max(nodeCount, 1))
        let ed = plan.effDst.contents().bindMemory(to: UInt32.self, capacity: max(m, 1))
        var before = [UInt8](repeating: 0, count: m)
        for e in 0..<m { before[e] = truth[Int(ed[e])] }
        latchBackEdges()
        let next = 1 - f.cur
        for e in 0..<m where truth[Int(ed[e])] != before[e] { frontierPushReadersOnCPU(Int(ed[e]), half: next, ix) }
    }

    /// `f2_push_readers` on the CPU (the GPU is idle): every reader of `v`
    /// through a slot into its rank's list, every effective back edge `v`
    /// feeds into the latch list, each once (the half's bitmaps).
    func frontierPushReadersOnCPU(_ v: Int, half h: Int, _ ix: FrontierIndex) {
        let n = ix.nodeCount, L = ix.levels, m = ix.edges
        let off = ix.csrOff.contents().bindMemory(to: UInt32.self, capacity: n + 1)
        let ent = ix.csrEnt.contents().bindMemory(to: UInt32.self, capacity: max(ix.entries, 1))
        let rank = rankBuf.contents().bindMemory(to: UInt64.self, capacity: max(nodeCount, 1))
        let bits = ix.bits.contents().bindMemory(to: UInt32.self, capacity: 2 * ix.words)
        let lists = ix.lists.contents().bindMemory(to: UInt32.self, capacity: 2 * n)
        let cnt = ix.cnt.contents().bindMemory(to: UInt32.self, capacity: 2 * L + 4)
        let rinfo = ix.rinfo.contents().bindMemory(to: UInt32.self, capacity: 3 * L + 1)
        let lbits = ix.latchBits.contents().bindMemory(to: UInt32.self, capacity: 2 * ix.edgeWords)
        let llist = ix.latchLists.contents().bindMemory(to: UInt32.self, capacity: 2 * max(m, 1))
        for k in Int(off[v])..<Int(off[v + 1]) {
            let x = ent[k]
            if x & 0x8000_0000 != 0 {
                let e = Int(x & 0x7FFF_FFFF)
                let w = h * ix.edgeWords + (e >> 5), mask = UInt32(1) << UInt32(e & 31)
                if lbits[w] & mask != 0 { continue }
                lbits[w] |= mask
                let pos = Int(cnt[2 * L + h])
                cnt[2 * L + h] = UInt32(pos + 1)
                llist[h * m + pos] = UInt32(e)
            } else {
                let u = Int(x)
                let r = rank[u]
                if r >= UInt64(L) { continue }
                let w = h * ix.words + (u >> 5), mask = UInt32(1) << UInt32(u & 31)
                if bits[w] & mask != 0 { continue }
                bits[w] |= mask
                let ri = Int(r)
                let pos = Int(cnt[h * L + ri])
                cnt[h * L + ri] = UInt32(pos + 1)
                lists[h * n + Int(rinfo[ri]) + pos] = UInt32(u)
            }
        }
    }

    // MARK: - k ticks per command buffer

    /// One tick's counts inside a session: `changed` the truth bytes it
    /// changed (registers included), `latched` the registers its latch
    /// changed — `lastChanged` and `lastCount` of a tick through
    /// `tick(tickNumber:rankOrderVerified:)`.
    public struct SessionTick: Equatable {
        public let changed: Int
        public let latched: Int
        public init(changed: Int, latched: Int) { self.changed = changed; self.latched = latched }
    }

    /// What `sessionTicks` ran: one entry per tick, in order; `evaluated` the
    /// node slots its rank dispatches covered (every tick it ran); `batched`
    /// whether the ticks shared one command buffer.
    public struct SessionBatch {
        public let ticks: [SessionTick]
        public let evaluated: Int
        public let batched: Bool
        /// The command buffer that did not complete (its ticks are
        /// not in `ticks`; nothing of it is claimed), else nil.
        public var failure: CommandBufferFailure? = nil
    }

    /// Inside an open session (`countingLatchChanges` or `frontierSession`), up to
    /// `want` rank-ordered ticks, as many calls of
    /// `tick(tickNumber:rankOrderVerified: true)` would run them — the same
    /// bytes, and per tick the same `changed` and `latched`.
    ///
    /// In a frontier session the ticks are encoded into ONE command buffer
    /// (the CPU waits on the GPU once), each tick's two counts into its own
    /// slot of `batchCounters`, read after the buffer completes. Each tick
    /// is admitted (the counting session's checks) and consults the command-buffer seam as
    /// `tick` does; a tick refused, or without a command buffer, runs nothing
    /// and reports 0 / 0, and ends the batch there. The caller stops at the
    /// first tick with both counts 0: ticks after it in the same batch ran
    /// from a fixed point, which is absorbing (a tick is a function of the
    /// bytes, and a tick that changed none leaves them as they were), so
    /// they change no byte.
    ///
    /// One tick through `tick(…)` instead (`batched` false) when the session
    /// is a counting session or its frontier could not be had, when the plan
    /// has kernel-evaluated destinations (their counts need the CPU between
    /// the kernel and the latch), with the seam `latchOnGPU = false`, or
    /// when anything the batch needs is not in place (the index dropped, the
    /// rank lists out of date, the counters not allocated).
    public func sessionTicks(_ want: Int, tickNumber: UInt32) -> SessionBatch {
        guard let c = latchChangeCounter, want > 0 else { return SessionBatch(ticks: [], evaluated: 0, batched: false) }
        if let f = c.frontier, latchOnGPU != false, c.evaluatedDsts.isEmpty, f.seedCount == 0, c.refusal == nil,
           frontierIndex === f.index, !rankTopologyDirty, rankListBuf != nil,
           f.index.levels == effectiveRankCount, rankSpanTable.count == f.index.levels,
           let counters = c.batchCounters(ticks: want, device: device) {
            return tickFrontierBatch(f, counting: c, ticks: want, counters: counters)
        }
        lastRankTickCounted = false
        lastFrontierEvaluated = 0
        let failedBefore = gpuFailure
        tick(tickNumber: tickNumber, rankOrderVerified: true)
        if let fail = gpuFailure, failedBefore == nil {                       // a failed buffer claims nothing
            return SessionBatch(ticks: [], evaluated: 0, batched: false, failure: fail)
        }
        // A plain rank-ordered tick evaluates every node of every rank.
        let evaluated = !lastRankTickCounted ? 0 : (lastTickFrontier ? lastFrontierEvaluated : rankDispatchNodeCount())
        return SessionBatch(ticks: [SessionTick(changed: c.lastChanged, latched: c.lastCount)],
                            evaluated: evaluated, batched: false)
    }

    /// `want` frontier ticks in one command buffer (see `sessionTicks`).
    func tickFrontierBatch(_ f: FrontierState, counting c: LatchChangeCounter, ticks asked: Int,
                           counters: MTLBuffer) -> SessionBatch {
        let zero = SessionTick(changed: 0, latched: 0)
        // At most `maxDispatchesPerCommandBuffer`
        // dispatches a buffer, at least one tick. A tick is an args kernel
        // and a rank kernel per non-empty rank, then the latch's args kernel
        // and one kernel (two when two-phase).
        var nonEmptyRanks = 0
        for r in 0..<f.index.levels where rankSpanTable[r].count > 0 { nonEmptyRanks += 1 }
        let perTick = max(1, 2 * nonEmptyRanks + (f.index.plan.map { $0.twoPhase ? 3 : 2 } ?? 0))
        let want = min(asked, max(1, Self.maxDispatchesPerCommandBuffer / perTick))
        // The first tick as `tick`: counts zeroed, admitted, the seam, the buffer.
        c.lastChanged = 0
        c.lastCount = 0
        guard c.admitTick(engine: self) else { return SessionBatch(ticks: [zero], evaluated: 0, batched: true) }
        lastTickFrontier = false
        guard !commandBufferFailsForTesting(), let cmdBuf = makeGPUCommandBuffer(),
              let enc = cmdBuf.makeComputeCommandEncoder() else {
            return SessionBatch(ticks: [zero], evaluated: 0, batched: true)
        }
        let ix = f.index
        let L = ix.levels
        let general = chooseTickKernel() == .general
        let firstFull = f.needsFull
        if firstFull { f.resetState() }
        let cntP = ix.cnt.contents().bindMemory(to: UInt32.self, capacity: 2 * L + 4)
        cntP[2 * L + 2] = 0
        cntP[2 * L + 3] = 0
        memset(counters.contents(), 0, want * 32)
        var e = FrontierEncoding(enc)
        bindFrontier(enc, ix)
        if general { bindTernaryLanes(enc, firstIndex: 19) }
        var encoded = 0, stopped = false, lastRanks = 0
        for j in 0..<want {
            if j > 0 {
                // Tick j as `tick` would meet it: counts zeroed, admitted, the seam.
                c.lastChanged = 0
                c.lastCount = 0
                if !c.admitTick(engine: self) || commandBufferFailsForTesting() { stopped = true; break }
            }
            var p = frontierParams(ix, cur: f.cur ^ (j & 1), full: j == 0 && firstFull)
            let ranksBefore = e.rankDispatches
            encodeFrontierRanks(&e, f, &p, general: general, counter: counters, offset: 32 * j)
            lastRanks = e.rankDispatches - ranksBefore
            if let plan = ix.plan { encodeFrontierLatch(&e, f, plan, &p, counter: counters, offset: 32 * j + 16) }
            encoded += 1
        }
        enc.endEncoding()
        cmdBuf.commit()
        c.noteBuffer(ticks: encoded, dispatches: e.dispatches)                 // dispatches counted per buffer
        guard waitCounted(cmdBuf) else {
            // The buffer did not complete — none of
            // its ticks is claimed; the session ends there.
            f.needsFull = true
            c.lastChanged = 0
            c.lastCount = 0
            return SessionBatch(ticks: [], evaluated: 0, batched: true, failure: gpuFailure)
        }
        let ctr = counters.contents()
        var ticks: [SessionTick] = []
        ticks.reserveCapacity(encoded + 1)
        for j in 0..<encoded {
            let kernel = Int(ctr.load(fromByteOffset: 32 * j, as: UInt32.self))
            let latch = Int(ctr.load(fromByteOffset: 32 * j + 16, as: UInt32.self))
            ticks.append(SessionTick(changed: kernel + latch, latched: latch))
        }
        if stopped { ticks.append(zero) }
        let last = ticks[ticks.count - 1]
        c.lastChanged = last.changed
        c.lastCount = last.latched
        lastRankTickCounted = true
        let evaluated = Int(cntP[2 * L + 2])
        finishFrontierTick(f, full: firstFull, ticks: encoded, dispatches: e.dispatches, rankDispatches: lastRanks,
                           latchOnGPU: ix.plan != nil)
        return SessionBatch(ticks: ticks, evaluated: evaluated, batched: true)
    }

    // MARK: - The session

    /// A counting session (`countingLatchChanges`: the same
    /// counts, the same refusals, the same precondition) whose rank-ordered
    /// ticks run through the frontier. Its first tick is whole. If the index
    /// cannot be had (an allocation failed, the rank lists cannot be
    /// allocated, a kernel is missing) the session runs plain counting ticks
    /// (`frontierActive` false).
    public func frontierSession<R>(_ body: (LatchChangeCounter) throws -> R) throws -> R {
        try countingLatchChanges(frontier: true, body)
    }
}
