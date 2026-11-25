/// DagDBEngine — Metal compute engine for 6-bounded ranked DAG evaluation.
///
/// Forked from MetalEngine (Savanna). Core pipeline preserved:
///   - HexGrid neighbor table (6-bounded by construction)
///   - Morton Z-curve memory layout
///   - 7-coloring for lock-free intra-rank parallelism
///   - Carlos Delta Transport for persistence
///
/// Differences from Savanna:
///   - No scent diffusion (no fluid dynamics)
///   - No entity evolution (birth/death/energy)
///   - Tick kernel = LUT6 evaluation + rank-ordered execution
///   - Leaves-up execution schedule

import Metal
import Foundation

public final class DagDBEngine {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let grid: HexGrid

    // State buffers
    public private(set) var truthStateBuf: MTLBuffer   // UInt8 per node
    private var truthStateBackBuf: MTLBuffer!           // TICK_SYNC ping-pong
    public let syncPipeline: MTLComputePipelineState    // dagdb_tick_sync
    public let rankBuf: MTLBuffer           // UInt64 per node (widened u8 → u32, then u32 → u64)
    public let lut6LowBuf: MTLBuffer        // UInt32 per node
    public let lut6HighBuf: MTLBuffer       // UInt32 per node
    public let activationBuf: MTLBuffer     // Int16 per node
    public let edgeWeightsBuf: MTLBuffer    // Float per (node * 6 + dir)
    public let nodeValueBuf: MTLBuffer      // Float per node (solver state)
    public let nodeTypeBuf: MTLBuffer       // UInt8 per node

    // ── Ternary lanes ──
    /// The four lanes, allocated on demand: nil until the
    /// graph needs them — the first write to a lane that is not a no-op on a
    /// binary graph, a general-kernel dispatch, or a raw-buffer request — then
    /// all four at once, zero-filled, at their full sizes (mode 1 + ttableId 2
    /// + thrLo 4 + thrHi 4 = 11 bytes per node), and kept for the engine's
    /// life. While they are nil every node reads as BINARY with zero table id
    /// and thresholds, which is exactly what the zero-filled lanes hold, so no
    /// reader can tell the two apart. `ternaryLaneBytes` is the accounting.
    private var laneMode: MTLBuffer?
    private var laneTid: MTLBuffer?
    private var laneLo: MTLBuffer?
    private var laneHi: MTLBuffer?
    /// The mode lane (UInt8 per node: kind | NOSKIP). Private, so that every
    /// write the engine's own code makes goes through `setNodeMode` or
    /// `writeModeLane`, which keep `nonBinaryCount` exact.
    /// Reading it allocates the lanes; see `modeByte` for a read that does not.
    private var modeLaneBuf: MTLBuffer { materializeTernaryLanes(); return laneMode! }
    /// UInt16 per node. Allocates the lanes — readers that must
    /// not allocate use `ternaryLaneView`.
    public var ttableIdBuf: MTLBuffer { materializeTernaryLanes(); return laneTid! }
    /// Float per node. Allocates the lanes, as `ttableIdBuf`.
    public var thrLoBuf: MTLBuffer { materializeTernaryLanes(); return laneLo! }
    /// Float per node. Allocates the lanes, as `ttableIdBuf`.
    public var thrHiBuf: MTLBuffer { materializeTernaryLanes(); return laneHi! }
    /// The table library, `TernaryReference.tableSize` bytes per table, room
    /// for `ttableCapacity` tables; the first `ttableCount` are defined.
    /// Reallocated (doubling) when the library outgrows it, so a tick reads
    /// this property, never a cached buffer.
    public internal(set) var ttableBuf: MTLBuffer
    public internal(set) var ttableCount: Int = 0
    /// Readable by the daemon's committed-bytes ledger.
    public internal(set) var ttableCapacity: Int = 1

    /// Which Metal library this engine compiled its kernels from: the
    /// package bundle's (`false`) or the inline `metalShaderSource`
    /// (`true`). The forced-inline test asserts the two paths it compares
    /// are really two.
    public let usedInlineShader: Bool

    /// Where the kernels come from. `.automatic` is today's order (bundle,
    /// default library, inline source as the last resort); `.inlineSource`
    /// forces the inline string (tested against the bundle).
    public enum ShaderLibrary: Sendable { case automatic, inlineSource }

    // Graph structure (from HexGrid)
    public let neighborsBuf: MTLBuffer      // Int32 per (node * 6 + dir)
    public let colorGroupBufs: [MTLBuffer]  // 7 color groups
    public let colorGroupSizes: [Int]

    // Compute pipelines
    public let tickPipeline: MTLComputePipelineState       // LUT6 evaluation
    public let rankResetPipeline: MTLComputePipelineState  // clear truth states for new tick

    // ── Binary-only fast path ──
    //
    // While the graph has no non-binary node, `tick`, `tickLegacy` and
    // `tickSync` dispatch the binary kernels with their original bindings: no
    // mode-lane read, none of the seven ternary bindings. On a binary-only
    // graph every node takes the BINARY branch of the general kernels, so
    // both give the same bytes (tests check it).

    /// Main's rank kernel (`dagdb_tick_rank_binary`), buffer(0…9).
    public let tickBinaryPipeline: MTLComputePipelineState
    /// The binary sync kernel with the out-of-range slot bound (`dagdb_tick_sync_binary`), buffer(0…6).
    public let syncBinaryPipeline: MTLComputePipelineState

    /// The counting twins of the two rank kernels
    /// (`dagdb_tick_rank_counting`, `dagdb_tick_rank_binary_counting`), the
    /// same bindings plus buffer(17), an atomic changed-node counter.
    /// Dispatched only inside `countingLatchChanges` (TICK UNTIL_STABLE).
    public let tickCountingPipeline: MTLComputePipelineState
    public let tickBinaryCountingPipeline: MTLComputePipelineState

    /// The latch kernels (`dagdb_latch_direct`, and the two
    /// phases `dagdb_latch_snapshot` / `dagdb_latch_write`). See `LatchPlan`.
    public let latchDirectPipeline: MTLComputePipelineState
    public let latchSnapshotPipeline: MTLComputePipelineState
    public let latchWritePipeline: MTLComputePipelineState

    /// `SET_LUTS … FILL | MAP` by selection (`dagdb_set_luts`;
    /// DagDBEngine+SetLuts.swift), made here with the tick's pipelines.
    public let setLutsPipeline: MTLComputePipelineState
    /// The kernel's two counts (nodes in the selection, nodes
    /// written), 8 bytes, made at the first GPU SET_LUTS.
    var setLutsCounterBuf: MTLBuffer?
    /// Whether the last `setLuts` wrote on the GPU (false: the
    /// CPU twin — by the seam below, or no command buffer — or an empty
    /// dispatch), and which dispatch it took. Read by the tests.
    public internal(set) var lastSetLutsOnGPU = false
    public internal(set) var lastSetLutsPath: SetLutsPath?
    /// Test seam: a `setLuts` whose dispatch covers at least this
    /// many nodes runs on the CPU twin (0: every one). nil: off. The daemon
    /// sets it from DAGDB_SET_LUTS_CPU_FOR_TESTING (a test control).
    public var setLutsCPUForTesting: Int?
    /// The dispatch the last `setTruthFill` took (the id range, a
    /// rank's per-rank list, the rank lane). Read by the tests.
    public internal(set) var lastSetTruthFillPath: SetLutsPath?

    /// Which kernel a tick dispatched.
    public enum TickKernel: Sendable, Equatable {
        /// `dagdb_tick_rank_binary` / `dagdb_tick_sync_binary`: no mode lane.
        case binaryOnly
        /// `dagdb_tick_rank` / `dagdb_tick_sync`: the kind branch and the ternary lanes.
        case general
    }

    /// The kernel the last `tick`, `tickLegacy` or `tickSync` dispatched
    /// (nil before the first). The fast-path test reads it.
    public private(set) var lastTickKernel: TickKernel?

    /// Test switch: false makes every tick take the general kernel, so a test
    /// can compare the two kernels on the same binary-only graph.
    var binaryFastPathEnabled = true

    /// Number of nodes whose mode byte is not 0, kept exact by every write
    /// the engine makes to the lane (`setNodeMode`: O(1); `writeModeLane`:
    /// a recount after the write, O(N) like the write itself).
    private var nonBinaryCount = 0

    /// Set once the raw lane has been handed out (`nodeModeBuf`, `modePtr`):
    /// writes through it are invisible to the engine, so from then on every
    /// read of the count — every tick included — recounts the lane. Sticky,
    /// so a pointer kept across a tick cannot leave the count stale.
    private var modeLaneHandedOut = false

    public let nodeCount: Int
    public let maxRank: Int  // Number of ranks in the DAG

    // BACK_EDGE primitive: typed return-edges latched at tick boundary.
    // The rank kernel skips nodes flagged as registers; those values come
    // from `latchBackEdges()` instead.
    //
    // Every change to either list (append, clear, assign, a
    // load's removeAll) drops the GPU latch's plan, which is derived from
    // the two lists alone; the next GPU latch builds it again. It also drops
    // the frontier's reverse index, which holds that plan, and
    // advances the lists' generation, so the next plain TICK knows
    // it is the first after an edit (`gpuLatchPlan`).
    public internal(set) var backEdgeSrcs: [UInt32] = [] { didSet { backEdgeListsChanged() } }
    public internal(set) var backEdgeDsts: [UInt32] = [] { didSet { backEdgeListsChanged() } }

    /// Every write to either back-edge list (CONNECT BACK, CONNECT_BACK_BULK,
    /// CLEAR … BACK_EDGES, every loader and replay, through
    /// `addBackEdgeUnchecked`, `clearBackEdges` or an assignment).
    private func backEdgeListsChanged() {
        latchPlan = nil                     // the GPU latch's plan
        frontierIndex = nil                 // the index's latch entries are the plan's
        backEdgeListGeneration &+= 1        // an edit, for the plain TICK's deferral
    }
    public let isRegisterBuf: MTLBuffer        // UInt8 per node, 1 = register

    // ── Per-(rank,color) compacted dispatch (perf recovery, 2026-07-07) ──
    // Flat buffer of node ids laid out as concatenated (rank,color)
    // segments + a CPU offset table. Kills the early-out thread waste of
    // launching whole color groups (at 16 ranks ~15/16 of threads were
    // rank-mismatch exits). Rebuilt lazily when rank topology changes.
    private var compactedListBuf: MTLBuffer!
    private var segmentTable: [(offset: Int, count: Int)] = []
    public private(set) var rankTopologyDirty = true

    // ── Per-rank contiguous dispatch ──
    // One list per rank, every node of the rank in ascending id order,
    // laid end to end in `rankListBuf`; `rankSpanTable[r]` is rank r's
    // (offset, count). A tick that dispatches one span per rank
    // (`tick(tickNumber:rankOrderVerified: true)`) launches one dispatch
    // per rank instead of up to seven, over the same nodes, and its
    // threads walk the rank in id order (the colour segments interleave
    // seven ways across it). Measured on a voxel latch workload at 128³:
    // merging the colour segments without the id order gained little; the
    // id order is the larger half. The buffer
    // (4 bytes per node) is allocated on the first per-rank tick, so an
    // engine that never takes the path holds none of it, and is rebuilt
    // with the colour lists whenever the rank topology changes.
    var rankListBuf: MTLBuffer?                         // read by the frontier tick too
    var rankSpanTable: [(offset: Int, count: Int)] = []  // read by the frontier tick too

    /// Compute dispatches the last rank-mode tick encoded (both paths). Read
    /// by the per-rank dispatch tests; not used by the engine.
    public internal(set) var lastRankTickDispatchCount = 0

    /// How many times the rank topology was rebuilt (the colour
    /// segments, and the per-rank lists when allocated) — one O(N) pass
    /// each. Read by the tests; not used by the engine.
    public private(set) var rankTopologyRebuildCount = 0

    /// Whether the last rank-mode tick dispatched the counting
    /// twins (only inside `countingLatchChanges`). Read by the tests.
    public internal(set) var lastRankTickCounted = false

    /// A test seam — the counting session's 4-byte counter
    /// "fails" to allocate. Read by the tests only.
    var changeCounterAllocationFailsForTesting = false

    /// A test seam — `tick(tickNumber:rankOrderVerified:)`
    /// gets no command buffer once this many more ticks have had one (0: the
    /// next tick fails; each tick that gets one counts down). nil: off. Read
    /// by the tests only. `setLuts` consults it too, once per
    /// verb that would run on the GPU (no command buffer: the CPU twin).
    var tickCommandBufferFailsAfterForTesting: Int?

    /// A test seam — the counting session's per-node
    /// marks (one byte per node) "fail" to allocate. Read by the tests only.
    var changeMarksAllocationFailsForTesting = false

    /// The seam above, consulted once per tick.
    func commandBufferFailsForTesting() -> Bool {
        guard let k = tickCommandBufferFailsAfterForTesting else { return false }
        if k <= 0 { return true }
        tickCommandBufferFailsAfterForTesting = k - 1
        return false
    }

    // ── Rank bound correction (2026-09-10) ──
    // `maxRank` is the CONFIGURED bound: the initial table size, what STATUS
    // has always printed, and what the fold schedules mean by the word. It is
    // an allocation hint, not a property of the graph — a snapshot written
    // under a large bound and restored under a small one carries ranks above
    // it, and those nodes used to be dropped from the buckets and skipped by
    // the rank loop while `tickSync` computed them. The dispatch now covers
    // every rank actually present:
    //
    //     effectiveRankCount = max(maxRank, highestRankPresent + 1)
    //
    // Nothing in Metal is sized by either number — the segment table and the
    // rank loop are CPU-side — so the cost is a longer loop over mostly-empty
    // segments and nothing else.

    /// Rank levels the rank-mode dispatch actually covers. Equal to
    /// `maxRank` whenever the graph fits inside the configured bound.
    /// Refreshed by `rebuildCompaction()`.
    public private(set) var effectiveRankCount: Int

    /// Highest rank value present in `rankBuf` at the last compaction.
    /// Refreshed by `rebuildCompaction()`.
    public private(set) var highestRankPresent: Int

    /// The rank levels below `effectiveRankCount` that hold at
    /// least one node, at the last compaction (`rebuildCompaction()`). The
    /// frontier's depth guard (`frontierMaxRankLevels`) counts these.
    public private(set) var nonEmptyRankLevels = 0

    /// Call after any write to rankBuf (SET RANK, bulk install, LOAD).
    /// The next tick rebuilds the compacted dispatch lists. The lists hold
    /// node ids by rank (and colour) only: a truth, LUT, weight or edge
    /// write leaves them correct and need not call this.
    ///
    /// A rank write also drops the frontier's reverse index (its
    /// per-rank arrays follow the rank lists).
    public func markRankTopologyDirty() {
        rankTopologyDirty = true
        frontierIndex = nil
    }

    /// Rebuild the compacted dispatch lists if the rank topology changed,
    /// so `effectiveRankCount` / `highestRankPresent` / the segment table
    /// are current. Cheap (one O(N) pass) and idempotent; callers that
    /// only want to REPORT the rank shape (STATUS) use this instead of
    /// ticking.
    public func ensureRankTopology() {
        if rankTopologyDirty { rebuildCompaction() }
    }

    // MARK: - Memory accounting for the daemon's budget

    /// Command buffers made on the engine's queue; the daemon measures the Metal pool across its first.
    public private(set) var gpuCommandBuffersMade = 0
    func makeGPUCommandBuffer() -> MTLCommandBuffer? {
        if gpuCommandBuffersMade == 0 { Self.enginesWithCommandBuffers += 1 }   // each engine's queue brings its own pool
        Self.processCommandBuffers += 1
        gpuCommandBuffersMade += 1
        return queue.makeCommandBuffer()
    }
    /// TICK_SYNC has run once (its first-use state is held for the engine's life).
    public private(set) var tickSyncHasRun = false
    /// The compacted dispatch list's bytes (allocated at start; first touched by the rank table's first build).
    public var compactedListBytes: Int { compactedListBuf.length }
    /// The rank lists exist (the first rank-ordered TICK built them).
    public var rankListsBuilt: Bool { rankListBuf != nil }
    /// The levels the rank table holds now (0 before its first build); the ledger's kept term.
    public var rankTableLevels: Int { segmentTable.count / HexGrid.colorCount }
    /// The latch plan's effective back edges (its destinations, one each), 0 without a plan.
    public var latchPlanDestinations: Int { latchPlan?.count ?? 0 }
    public var hasLatchPlan: Bool { latchPlan != nil }

    /// The rank shape STATUS reports (the highest rank present below N, and the levels a rebuild would make),
    /// read with one pass over the rank lane and NO allocation: the table itself is built (and admitted) only by
    /// the verbs that dispatch by it. Clean topology: the values the last build stored.
    public func rankShapeWithoutBuilding() -> (highest: Int, levels: Int) {
        guard rankTopologyDirty else { return (highestRankPresent, effectiveRankCount) }
        let rankPtr = rankBuf.contents().bindMemory(to: UInt64.self, capacity: max(nodeCount, 1))
        var highest = 0
        for i in 0..<nodeCount {
            let r = rankPtr[i]
            if r > UInt64(highest) && r < UInt64(nodeCount) { highest = Int(r) }
        }
        return (highest, max(maxRank, min(highest + 1, max(nodeCount, 1))))
    }
    /// The bytes the frontier's index will hold if built now, by its buffers'
    /// lengths (`buildFrontierIndex`): the CSR over every valid slot and plan edge, two node lists, two bit sets, the latch
    /// lists and bits, and the per-level counters. One pass over the slots, no allocation.
    public func frontierIndexBytesBound() -> Int {
        let n = nodeCount
        let nb = neighborsBuf.contents().bindMemory(to: Int32.self, capacity: max(n * 6, 1))
        var slots = 0
        for i in 0..<(n * 6) { let s = nb[i]; if s >= 0 && Int(s) < n { slots += 1 } }
        let m = latchPlan?.count ?? backEdgeSrcs.count
        let l = rankShapeWithoutBuilding().levels
        let words = (n + 31) / 32, edgeWords = max((m + 31) / 32, 1)
        return (n + 1) * 4 + max(slots + m, 1) * 4 + 2 * n * 4 + 2 * words * 4 + 2 * max(m, 1) * 4 + 2 * edgeWords * 4
            + (2 * l + 4) * 4 + (3 * l + 1) * 4 + (5 * l + 5) * 4
    }
    /// The count of nodes whose rank lies in lo...hi (one pass, no allocation).
    public func nodesInRankRange(_ lo: UInt64, _ hi: UInt64) -> Int {
        let r = rankBuf.contents().bindMemory(to: UInt64.self, capacity: max(nodeCount, 1))
        var c = 0
        for i in 0..<nodeCount where r[i] >= lo && r[i] <= hi { c += 1 }
        return c
    }
    /// Engines of this process that have made a command buffer (each brings its own queue's pool).
    public private(set) static var enginesWithCommandBuffers = 0
    /// Command buffers made by every engine of this process.
    public private(set) static var processCommandBuffers = 0

    /// The levels the next rank-table build will make, or nil when the table is current (nothing to build).
    public func pendingRankTableLevels() -> Int? {
        rankTopologyDirty ? rankShapeWithoutBuilding().levels : nil
    }

    /// How many node slots one rank-mode tick dispatches with the current
    /// rank topology — the sum of every (rank, colour) segment. Equals
    /// `nodeCount` when every node's rank is covered.
    public func rankDispatchNodeCount() -> Int {
        ensureRankTopology()
        return segmentTable.reduce(0) { $0 + $1.count }
    }

    private func rebuildCompaction() {
        let rankPtr = rankBuf.contents().bindMemory(to: UInt64.self,
                                                    capacity: nodeCount)
        // Highest rank actually present, so the buckets and the segment
        // table cover the whole graph and not just the configured bound.
        // Clamped at `nodeCount`: no valid DAG on N nodes holds a rank of
        // N or more (the door at SET_RANK and at the bulk commit refuses
        // those), and a corrupt buffer carrying, say, UInt64.max must not
        // turn the table allocation into a denial of service. Anything
        // above the clamp is left out of the dispatch and named by
        // VALIDATE instead.
        var highest = 0
        for i in 0..<nodeCount {
            let r = rankPtr[i]
            if r > UInt64(highest) && r < UInt64(nodeCount) { highest = Int(r) }
        }
        highestRankPresent = highest
        let levels = max(maxRank, min(highest + 1, max(nodeCount, 1)))
        effectiveRankCount = levels

        // bucket[color][rank] = node ids (single O(N) pass)
        var buckets = Array(repeating: Array(repeating: [UInt32](),
                                             count: levels),
                            count: HexGrid.colorCount)
        for (color, group) in grid.colorGroups.enumerated() {
            for node in group {
                let r = rankPtr[Int(node)]
                if r < UInt64(levels) {
                    buckets[color][Int(r)].append(UInt32(node))
                }
            }
        }
        var flat = [UInt32](); flat.reserveCapacity(nodeCount)
        segmentTable = Array(repeating: (0, 0),
                             count: levels * HexGrid.colorCount)
        for rank in 0..<levels {
            for color in 0..<HexGrid.colorCount {
                let ids = buckets[color][rank]
                segmentTable[rank * HexGrid.colorCount + color] =
                    (flat.count, ids.count)
                flat.append(contentsOf: ids)
            }
        }
        if rankListBuf != nil { _ = rebuildRankLists(levels: levels) }   // already allocated: cannot fail
        // The rank levels that hold a node —
        // the unit both the per-rank tick and the frontier dispatch by (an
        // empty rank is never dispatched). The depth guard counts these.
        var nonEmpty = 0
        for rank in 0..<levels {
            for color in 0..<HexGrid.colorCount where segmentTable[rank * HexGrid.colorCount + color].count > 0 {
                nonEmpty += 1
                break
            }
        }
        nonEmptyRankLevels = nonEmpty
        rankTopologyRebuildCount += 1
        if !flat.isEmpty {
            compactedListBuf.contents().copyMemory(
                from: flat, byteCount: flat.count * 4)
        }
        rankTopologyDirty = false
    }

    /// Rank r's nodes, ascending, at `rankSpanTable[r]` of
    /// `rankListBuf` (allocated here on first use). A counting sort: one
    /// pass to count, one to place — O(N), ids ascending by construction.
    /// The same nodes as the colour segments: every node whose rank is
    /// below `levels`. False, with nothing changed, when the buffer is not
    /// allocated yet and its allocation fails (never a fatalError).
    private func rebuildRankLists(levels: Int) -> Bool {
        if rankListBuf == nil {
            guard !rankListAllocationFailsForTesting,
                  let b = device.makeBuffer(length: max(nodeCount, 1) * 4,
                                            options: .storageModeShared) else {
                return false
            }
            rankListBuf = b
        }
        let rankPtr = rankBuf.contents().bindMemory(to: UInt64.self, capacity: max(nodeCount, 1))
        var count = [Int](repeating: 0, count: levels)
        for i in 0..<nodeCount where rankPtr[i] < UInt64(levels) { count[Int(rankPtr[i])] += 1 }
        rankSpanTable = Array(repeating: (0, 0), count: levels)
        var next = [Int](repeating: 0, count: levels)
        var offset = 0
        for r in 0..<levels {
            rankSpanTable[r] = (offset, count[r]); next[r] = offset; offset += count[r]
        }
        let out = rankListBuf!.contents().bindMemory(to: UInt32.self, capacity: max(nodeCount, 1))
        for i in 0..<nodeCount where rankPtr[i] < UInt64(levels) {
            let r = Int(rankPtr[i])
            out[next[r]] = UInt32(i); next[r] += 1
        }
        return true
    }

    /// Test seam: makes the rank lists' first
    /// allocation fail, as `makeBuffer` returning nil would.
    var rankListAllocationFailsForTesting = false

    /// Why the per-rank lists cannot be had, in the refusal's words.
    public struct RankListUnavailable: Error, CustomStringConvertible {
        public let bytes: Int
        public let nodes: Int
        public var description: String {
            "rank lists: buffer allocation failed (\(bytes) bytes for \(nodes) nodes)"
        }
    }

    /// Make the per-rank path ready (the rank topology
    /// current, the lists allocated and built) or say why it cannot be.
    /// The daemon calls this before a rank-ordered TICK and refuses the
    /// TICK by name on a throw, ticking nothing.
    public func prepareRankLists() throws {
        if rankTopologyDirty { rebuildCompaction() }
        if rankListBuf == nil && !rebuildRankLists(levels: effectiveRankCount) {
            throw RankListUnavailable(bytes: 4 * max(nodeCount, 1), nodes: nodeCount)
        }
    }

    /// Rank r's per-rank list — every node whose rank is r, ascending
    /// id, each once — made current first: lists a rank write has left stale
    /// since the last tick are rebuilt here, as SET_LUTS rebuilds them (the
    /// O(N) rebuild the next tick would pay; that tick then pays none). nil
    /// when the lists were never built (no rank-ordered TICK yet: the caller
    /// scans the rank lane), or r is past the span table (only a node whose
    /// rank is nodeCount or more, which the lists leave out, can hold such a
    /// rank: the caller's scan sees it). Valid until the next rank write.
    public func currentRankList(_ r: UInt64) -> UnsafeBufferPointer<UInt32>? {
        guard rankListBuf != nil else { return nil }
        ensureRankTopology()
        guard let b = rankListBuf, r < UInt64(rankSpanTable.count) else { return nil }
        let s = rankSpanTable[Int(r)]
        let p = b.contents().bindMemory(to: UInt32.self, capacity: max(nodeCount, 1))
        return UnsafeBufferPointer(start: p.advanced(by: s.offset), count: s.count)
    }

    public init(grid: HexGrid, state: DagDBState, maxRank: Int = 16,
                shaderLibrary: ShaderLibrary = .automatic) throws {
        // Every buffer below is allocated `grid.nodeCount` elements long
        // from the CALLER's arrays. A state smaller than the grid would make
        // those `makeBuffer(bytes:length:)` calls read past the caller's
        // storage — silently, and before any of this object existed.
        guard state.nodeCount == grid.nodeCount else {
            throw EngineError.stateGridMismatch(stateNodeCount: state.nodeCount,
                                                gridNodeCount: grid.nodeCount)
        }
        // The ternary lanes and the library come from the caller's state too,
        // with the same length rule as every other lane. Each lane is checked
        // on its own and the refusal names it with its actual length (one
        // check over all four would report nodeMode's length whichever lane
        // was short).
        for (lane, count) in [("nodeMode", state.nodeMode.count), ("ttableId", state.ttableId.count),
                              ("thrLo", state.thrLo.count), ("thrHi", state.thrHi.count)]
        where count != grid.nodeCount {
            throw EngineError.laneLength(lane: lane, length: count, gridNodeCount: grid.nodeCount)
        }
        if let why = TernaryReference.libraryRefusal(state.ttables) {
            throw EngineError.ternary(why)
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw EngineError.noGPU
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw EngineError.noQueue
        }
        self.queue = queue
        self.grid = grid
        self.nodeCount = grid.nodeCount
        self.maxRank = maxRank
        // Provisional until the first compaction: the configured bound.
        self.effectiveRankCount = maxRank
        self.highestRankPresent = 0

        // Allocate state buffers (unified memory on M-series)
        let shared = MTLResourceOptions.storageModeShared
        guard let b1 = device.makeBuffer(bytes: state.truthState, length: nodeCount, options: shared),
              let b2 = device.makeBuffer(bytes: state.rank, length: nodeCount * 8, options: shared),
              let b3 = device.makeBuffer(bytes: state.lut6Low, length: nodeCount * 4, options: shared),
              let b4 = device.makeBuffer(bytes: state.lut6High, length: nodeCount * 4, options: shared),
              let b5 = device.makeBuffer(bytes: state.activation, length: nodeCount * 2, options: shared),
              let b6 = device.makeBuffer(bytes: state.edgeWeights, length: nodeCount * 6 * 4, options: shared),
              let b7 = device.makeBuffer(bytes: state.nodeType, length: nodeCount, options: shared),
              let b8 = device.makeBuffer(bytes: state.nodeValue, length: nodeCount * 4, options: shared) else {
            throw EngineError.bufferAllocationFailed
        }
        self.truthStateBuf = b1
        self.rankBuf = b2
        self.lut6LowBuf = b3
        self.lut6HighBuf = b4
        self.activationBuf = b5
        self.edgeWeightsBuf = b6
        self.nodeTypeBuf = b7
        self.nodeValueBuf = b8

        // Ternary lanes and the library. The library
        // buffer always holds at least one table's room, so an empty library
        // never asks Metal for a zero-length buffer.
        let tableCount = state.ttables.count / TernaryReference.tableSize
        let tableCap = max(tableCount, 1)
        guard let m5 = device.makeBuffer(length: tableCap * TernaryReference.tableSize, options: shared) else {
            throw EngineError.bufferAllocationFailed
        }
        if tableCount > 0 {
            state.ttables.withUnsafeBytes { m5.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }
        // The four lanes only when the state carries a non-default
        // byte in one of them (bit patterns, so a −0.0 threshold counts).
        let stateHasLanes = state.nodeMode.contains { $0 != 0 } || state.ttableId.contains { $0 != 0 }
            || state.thrLo.contains { $0.bitPattern != 0 } || state.thrHi.contains { $0.bitPattern != 0 }
        if stateHasLanes {
            guard let m1 = device.makeBuffer(bytes: state.nodeMode, length: nodeCount, options: shared),
                  let m2 = device.makeBuffer(bytes: state.ttableId, length: nodeCount * 2, options: shared),
                  let m3 = device.makeBuffer(bytes: state.thrLo, length: nodeCount * 4, options: shared),
                  let m4 = device.makeBuffer(bytes: state.thrHi, length: nodeCount * 4, options: shared) else {
                throw EngineError.bufferAllocationFailed
            }
            self.laneMode = m1; self.laneTid = m2; self.laneLo = m3; self.laneHi = m4
        }
        self.nonBinaryCount = state.nodeMode.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
        self.ttableBuf = m5
        self.ttableCount = tableCount
        self.ttableCapacity = tableCap

        // Allocate is_register flag buffer (one byte per node, default 0).
        // Populated by addBackEdge / clearBackEdges; reused across ticks.
        guard let regBuf = device.makeBuffer(length: nodeCount, options: shared) else {
            throw EngineError.bufferAllocationFailed
        }
        self.isRegisterBuf = regBuf
        let regPtr = regBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        for i in 0..<nodeCount { regPtr[i] = 0 }

        // Neighbors from HexGrid (already Morton-ordered)
        guard let nb = device.makeBuffer(bytes: grid.neighbors, length: grid.neighbors.count * 4, options: shared) else {
            throw EngineError.bufferAllocationFailed
        }
        self.neighborsBuf = nb

        // Color groups. A small grid (see `TiledGraphFiles`'s
        // `minEngineNodeCount` comment: `HexGrid(width: n, height: 1)`
        // needs n >= 11 before every colour residue is populated) can have
        // an EMPTY colour bucket — `device.makeBuffer(length: 0, ...)`
        // returns nil, failing the whole init. Allocate at least one
        // element (`max(1, group.count)`) so a zero-length request never
        // reaches Metal; `groupSizes` still records the TRUE count (0),
        // so dispatch (`seg.count == 0` skip in `tick`) is unaffected.
        // The `bytes:`-initializer path is used only when the group is
        // non-empty — an empty Swift array's storage isn't a safe source
        // for a `length:`-sized copy beyond its own (zero) extent.
        var groupBufs = [MTLBuffer]()
        var groupSizes = [Int]()
        for group in grid.colorGroups {
            let gb: MTLBuffer?
            if group.isEmpty {
                gb = device.makeBuffer(length: 4, options: shared)
            } else {
                gb = device.makeBuffer(bytes: group, length: group.count * 4, options: shared)
            }
            guard let gbuf = gb else {
                throw EngineError.bufferAllocationFailed
            }
            groupBufs.append(gbuf)
            groupSizes.append(group.count)
        }
        self.colorGroupBufs = groupBufs
        self.colorGroupSizes = groupSizes

        // Compacted dispatch flat buffer (per-(rank,color) node lists);
        // built lazily on first tick (rankTopologyDirty starts true).
        guard let clb = device.makeBuffer(length: max(nodeCount, 1) * 4,
                                          options: shared) else {
            throw EngineError.bufferAllocationFailed
        }
        self.compactedListBuf = clb

        guard let backBuf = device.makeBuffer(length: max(nodeCount, 1),
                                              options: shared) else {
            throw EngineError.bufferAllocationFailed
        }
        self.truthStateBackBuf = backBuf

        // Load Metal library from package bundle
        let library: MTLLibrary
        var inline = false
        if shaderLibrary == .inlineSource {
            // The forced-inline path: the string below, compiled here.
            library = try device.makeLibrary(source: DagDBEngine.metalShaderSource, options: nil)
            inline = true
        } else if let bundleLib = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            library = bundleLib
        } else if let defaultLib = device.makeDefaultLibrary() {
            library = defaultLib
        } else {
            // Fallback: compile from source
            let shaderSource = DagDBEngine.metalShaderSource
            library = try device.makeLibrary(source: shaderSource, options: nil)
            inline = true
        }
        self.usedInlineShader = inline
        self.library = library                           // the frontier kernels are made from it on first use

        guard let tickFn = library.makeFunction(name: "dagdb_tick_rank") else {
            throw EngineError.functionNotFound("dagdb_tick_rank")
        }
        self.tickPipeline = try device.makeComputePipelineState(function: tickFn)

        guard let resetFn = library.makeFunction(name: "dagdb_reset_rank") else {
            throw EngineError.functionNotFound("dagdb_reset_rank")
        }
        self.rankResetPipeline = try device.makeComputePipelineState(function: resetFn)

        guard let syncFn = library.makeFunction(name: "dagdb_tick_sync") else {
            throw EngineError.functionNotFound("dagdb_tick_sync")
        }
        self.syncPipeline = try device.makeComputePipelineState(function: syncFn)

        // The binary-only kernels, from the same library.
        guard let tickBinFn = library.makeFunction(name: "dagdb_tick_rank_binary") else {
            throw EngineError.functionNotFound("dagdb_tick_rank_binary")
        }
        self.tickBinaryPipeline = try device.makeComputePipelineState(function: tickBinFn)
        guard let syncBinFn = library.makeFunction(name: "dagdb_tick_sync_binary") else {
            throw EngineError.functionNotFound("dagdb_tick_sync_binary")
        }
        self.syncBinaryPipeline = try device.makeComputePipelineState(function: syncBinFn)

        // The counting twins, from the same library.
        guard let tickCntFn = library.makeFunction(name: "dagdb_tick_rank_counting") else {
            throw EngineError.functionNotFound("dagdb_tick_rank_counting")
        }
        self.tickCountingPipeline = try device.makeComputePipelineState(function: tickCntFn)
        guard let tickBinCntFn = library.makeFunction(name: "dagdb_tick_rank_binary_counting") else {
            throw EngineError.functionNotFound("dagdb_tick_rank_binary_counting")
        }
        self.tickBinaryCountingPipeline = try device.makeComputePipelineState(function: tickBinCntFn)

        // The latch kernels, from the same library.
        guard let latchDirectFn = library.makeFunction(name: "dagdb_latch_direct") else {
            throw EngineError.functionNotFound("dagdb_latch_direct")
        }
        self.latchDirectPipeline = try device.makeComputePipelineState(function: latchDirectFn)
        guard let latchSnapFn = library.makeFunction(name: "dagdb_latch_snapshot") else {
            throw EngineError.functionNotFound("dagdb_latch_snapshot")
        }
        self.latchSnapshotPipeline = try device.makeComputePipelineState(function: latchSnapFn)
        guard let latchWriteFn = library.makeFunction(name: "dagdb_latch_write") else {
            throw EngineError.functionNotFound("dagdb_latch_write")
        }
        self.latchWritePipeline = try device.makeComputePipelineState(function: latchWriteFn)

        // SET_LUTS by selection, from the same library.
        guard let setLutsFn = library.makeFunction(name: "dagdb_set_luts") else {
            throw EngineError.functionNotFound("dagdb_set_luts")
        }
        self.setLutsPipeline = try device.makeComputePipelineState(function: setLutsFn)
    }

    // MARK: - Ternary lanes on demand

    /// True once the four lanes exist.
    public var ternaryLanesAllocated: Bool { laneMode != nil }

    /// The bytes the four ternary lanes hold now, by the buffers' own lengths:
    /// 0 while they are not allocated, 11 per node after.
    public var ternaryLaneBytes: Int {
        [laneMode, laneTid, laneLo, laneHi].reduce(0) { $0 + ($1?.length ?? 0) }
    }

    /// Allocate the four lanes, zero-filled, if they are not yet. Called by
    /// every path that writes a lane or hands one out.
    public func materializeTernaryLanes() {
        guard laneMode == nil else { return }
        let n = nodeCount
        let shared = MTLResourceOptions.storageModeShared
        guard let m1 = device.makeBuffer(length: n, options: shared),
              let m2 = device.makeBuffer(length: n * 2, options: shared),
              let m3 = device.makeBuffer(length: n * 4, options: shared),
              let m4 = device.makeBuffer(length: n * 4, options: shared) else {
            fatalError("ternary lanes: buffer allocation failed (\(11 * n) bytes for \(n) nodes)")
        }
        memset(m1.contents(), 0, n); memset(m2.contents(), 0, n * 2)
        memset(m3.contents(), 0, n * 4); memset(m4.contents(), 0, n * 4)
        laneMode = m1; laneTid = m2; laneLo = m3; laneHi = m4
    }

    /// One node's mode byte; 0 (BINARY) while the lanes are not allocated.
    /// Never allocates.
    @inline(__always) public func modeByte(_ node: Int) -> UInt8 {
        guard let b = laneMode else { return 0 }
        return b.contents().load(fromByteOffset: node, as: UInt8.self)
    }

    /// The four lanes, read-only, or nil while they are not allocated (every
    /// node BINARY, table id 0, thresholds +0.0). Never allocates.
    public struct TernaryLaneView {
        public let mode: UnsafePointer<UInt8>
        public let ttableId: UnsafePointer<UInt16>
        public let thrLo: UnsafePointer<Float>
        public let thrHi: UnsafePointer<Float>
    }
    public var ternaryLaneView: TernaryLaneView? {
        guard let m = laneMode, let t = laneTid, let lo = laneLo, let hi = laneHi else { return nil }
        let n = max(nodeCount, 1)
        return TernaryLaneView(mode: UnsafePointer(m.contents().bindMemory(to: UInt8.self, capacity: n)),
                               ttableId: UnsafePointer(t.contents().bindMemory(to: UInt16.self, capacity: n)),
                               thrLo: UnsafePointer(lo.contents().bindMemory(to: Float.self, capacity: n)),
                               thrHi: UnsafePointer(hi.contents().bindMemory(to: Float.self, capacity: n)))
    }

    /// Install whole lanes (load, import, restore paths): each pointer holds
    /// that lane's `nodeCount` elements, nil meaning the lane's default. When
    /// every byte given is the default and the lanes are not allocated, they
    /// stay unallocated; otherwise they are allocated and written. The mode
    /// count is recounted either way.
    public func installTernaryLanes(mode: UnsafeRawPointer?, ttableId: UnsafeRawPointer?,
                                    thrLo: UnsafeRawPointer?, thrHi: UnsafeRawPointer?) {
        let n = nodeCount
        func allZero(_ p: UnsafeRawPointer?, _ bytes: Int) -> Bool {
            guard let p = p else { return true }
            let words = bytes / 8
            for i in 0..<words where p.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self) != 0 { return false }
            for i in (words * 8)..<bytes where p.load(fromByteOffset: i, as: UInt8.self) != 0 { return false }
            return true
        }
        if laneMode == nil && allZero(mode, n) && allZero(ttableId, n * 2)
            && allZero(thrLo, n * 4) && allZero(thrHi, n * 4) {
            nonBinaryCount = 0
            return
        }
        materializeTernaryLanes()
        writeModeLane { if let m = mode { memcpy($0, m, n) } else { memset($0, 0, n) } }
        if let t = ttableId { memcpy(laneTid!.contents(), t, n * 2) } else { memset(laneTid!.contents(), 0, n * 2) }
        if let lo = thrLo { memcpy(laneLo!.contents(), lo, n * 4) } else { memset(laneLo!.contents(), 0, n * 4) }
        if let hi = thrHi { memcpy(laneHi!.contents(), hi, n * 4) } else { memset(laneHi!.contents(), 0, n * 4) }
    }

    /// The engine's own allocation accounting: every buffer it
    /// holds, by name, with its length in bytes. The four ternary lanes are
    /// listed as `ternary.*` with 0 while they are not allocated.
    public func allocationBytes() -> [(name: String, bytes: Int)] {
        var out: [(name: String, bytes: Int)] = [
            ("truthState", truthStateBuf.length), ("truthStateBack", truthStateBackBuf.length),
            ("rank", rankBuf.length), ("lut6Low", lut6LowBuf.length), ("lut6High", lut6HighBuf.length),
            ("activation", activationBuf.length), ("edgeWeights", edgeWeightsBuf.length),
            ("nodeValue", nodeValueBuf.length), ("nodeType", nodeTypeBuf.length),
            ("neighbors", neighborsBuf.length), ("isRegister", isRegisterBuf.length),
            ("compactedList", compactedListBuf.length),
            ("rankList", rankListBuf?.length ?? 0),   // 0 until the first per-rank tick
            ("colorGroups", colorGroupBufs.reduce(0) { $0 + $1.length }),
            ("ttableLibrary", ttableBuf.length),
        ]
        out.append(("ternary.mode", laneMode?.length ?? 0))
        out.append(("ternary.ttableId", laneTid?.length ?? 0))
        out.append(("ternary.thrLo", laneLo?.length ?? 0))
        out.append(("ternary.thrHi", laneHi?.length ?? 0))
        // The GPU latch's plan, 0 while there is none (no GPU
        // latch since the back-edge lists last changed).
        out.append(("latch.effSrc", latchPlan?.effSrc.length ?? 0))
        out.append(("latch.effDst", latchPlan?.effDst.length ?? 0))
        out.append(("latch.scratch", latchPlan?.scratch?.length ?? 0))
        out.append(("latch.counter", latchPlan?.counter.length ?? 0))
        // The frontier's reverse index and state, 0 while there is
        // none (no frontier session since the topology last changed).
        out.append(contentsOf: frontierAllocationBytes())
        // A batch's per-tick counters, held only while a session is open.
        out.append(("session.batchCounters", latchChangeCounter?.batchCountersBuf?.length ?? 0))
        return out
    }

    // MARK: - The mode lane and its count

    /// The mode lane's buffer. Handing it out hands out writes the engine
    /// cannot see, so the count switches to recounting (see
    /// `modeLaneHandedOut`). The engine's own paths use `modeLane`,
    /// `setNodeMode` and `writeModeLane` instead.
    public var nodeModeBuf: MTLBuffer {
        modeLaneHandedOut = true
        return modeLaneBuf
    }

    /// The mode lane, writable. Same rule as `nodeModeBuf`.
    public var modePtr: UnsafeMutablePointer<UInt8> {
        modeLaneHandedOut = true
        return modeLaneBuf.contents().bindMemory(to: UInt8.self, capacity: max(nodeCount, 1))
    }

    /// The mode lane, read-only: leaves the count as it is.
    public var modeLane: UnsafePointer<UInt8> {
        UnsafePointer(modeLaneBuf.contents().bindMemory(to: UInt8.self, capacity: max(nodeCount, 1)))
    }

    /// One node's mode byte. The count follows in O(1). The caller has
    /// already range-checked `node` and refused a bad byte.
    public func setNodeMode(_ node: Int, _ mode: UInt8) {
        precondition(node >= 0 && node < nodeCount, "node \(node) not in 0..<\(nodeCount)")
        if mode == 0 && laneMode == nil { return }     // BINARY on a lane that is all BINARY
        let p = modeLaneBuf.contents().bindMemory(to: UInt8.self, capacity: max(nodeCount, 1))
        let old = p[node]
        p[node] = mode
        if (old != 0) != (mode != 0) { nonBinaryCount += mode != 0 ? 1 : -1 }
    }

    /// Write the lane through `body` — bulk installs, loads, replays, reader
    /// and tile copies — then recount it. The pointer is for `body` only.
    @discardableResult
    public func writeModeLane<R>(_ body: (UnsafeMutablePointer<UInt8>) throws -> R) rethrows -> R {
        defer { nonBinaryCount = countNonBinaryNodes() }
        return try body(modeLaneBuf.contents().bindMemory(to: UInt8.self, capacity: max(nodeCount, 1)))
    }

    /// Replace the whole lane with `nodeCount` bytes from `src`, then recount.
    public func replaceModeLane(from src: UnsafeRawPointer) {
        if laneMode == nil {
            var any = false
            for i in 0..<nodeCount where src.load(fromByteOffset: i, as: UInt8.self) != 0 { any = true; break }
            if !any { nonBinaryCount = 0; return }        // all BINARY: nothing to allocate
        }
        writeModeLane { memcpy($0, src, nodeCount) }
    }

    /// The exact number of non-binary nodes now. O(1) unless the raw lane
    /// was handed out, in which case it is recounted.
    public var nonBinaryNodeCount: Int {
        if modeLaneHandedOut { nonBinaryCount = countNonBinaryNodes() }
        return nonBinaryCount
    }

    /// True while the count is kept by the writes alone — no raw access to
    /// the lane was ever handed out, so no tick has to recount it.
    public var nonBinaryCountTracked: Bool { !modeLaneHandedOut }

    /// A scan of the lane: nodes whose mode byte is not 0.
    func countNonBinaryNodes() -> Int {
        let n = nodeCount
        guard n > 0, let lane = laneMode else { return 0 }
        let p = lane.contents().bindMemory(to: UInt8.self, capacity: n)
        var c = 0
        for i in 0..<n where p[i] != 0 { c += 1 }
        return c
    }

    /// The kernel a tick dispatches now: binary-only iff no node is non-binary.
    func chooseTickKernel() -> TickKernel {
        let k: TickKernel = binaryFastPathEnabled && nonBinaryNodeCount == 0 ? .binaryOnly : .general
        lastTickKernel = k
        return k
    }

    /// Execute one tick: leaves-up rank propagation.
    /// Each rank evaluates in parallel (all nodes in rank N are independent).
    /// Then rank N-1 sees updated values from rank N.
    ///
    /// Dispatches one (rank, colour) segment at a time, in a colour order
    /// shuffled by `tickNumber` — the order that matters on a graph where
    /// a node reads another node of its own rank.
    public func tick(tickNumber: UInt32) {
        tick(tickNumber: tickNumber, rankOrderVerified: false)
    }

    /// Rank-mode tick with per-rank contiguous dispatch.
    ///
    /// `rankOrderVerified: true` is the caller's statement that every
    /// in-range neighbour slot of every node names a source of STRICTLY
    /// higher rank (no self-loop): `DagDBSnapshot.rankOrderViolation` is
    /// nil for the graph as it stands — the daemon's TICK checks exactly
    /// that before it ticks. On such a graph no node
    /// reads a node of its own rank, so the colour segments of one rank
    /// write disjoint nodes and read only finished higher ranks: their
    /// order, and whether they are one dispatch or seven, cannot change a
    /// byte. The tick then dispatches each rank's contiguous list (every
    /// node of the rank, ascending id) once, ranks descending, the same
    /// kernel, the same bindings, the same barriers between ranks.
    /// `false` is `tick(tickNumber:)`, unchanged.
    ///
    /// Passing `true` for a graph that has a same-rank edge is a caller
    /// error: the tick then races where the colour path would not.
    ///
    /// If the lists cannot be allocated the tick takes
    /// the colour path, exact on any graph; the daemon asks
    /// `prepareRankLists()` first and refuses instead.
    ///
    /// Inside a counting session: both counts are zeroed before
    /// anything else, so a tick that runs nothing (no command buffer, no
    /// encoder) reports changed 0 and latched 0, as a byte compare would;
    /// and a tick whose session's back-edge layout changed is refused —
    /// nothing ticked — see `LatchChangeCounter`.
    public func tick(tickNumber: UInt32, rankOrderVerified requested: Bool) {
        // Inside `countingLatchChanges` the counting twins run and
        // the tick reports its changed-byte count; otherwise nothing differs.
        let counting = latchChangeCounter
        if let c = counting {
            c.lastChanged = 0                           // a tick that runs nothing reports 0
            c.lastCount = 0
            if !c.admitTick(engine: self) { return }    // the session's layout check
        }
        if rankTopologyDirty { rebuildCompaction() }
        var rankOrderVerified = requested
        if rankOrderVerified && rankListBuf == nil && !rebuildRankLists(levels: effectiveRankCount) {
            rankOrderVerified = false
        }
        // Inside a frontier session a rank-ordered tick runs
        // through the frontier (DagDBEngine+Frontier.swift). Any other tick
        // of the session runs below, and the next frontier tick starts over
        // with a whole tick.
        lastTickFrontier = false
        if let c = counting, let f = c.frontier {
            if rankOrderVerified { tickFrontier(f, counting: c); return }
            f.needsFull = true
        }
        guard !commandBufferFailsForTesting(), let cmdBuf = makeGPUCommandBuffer() else { return }
        counting?.beginTick(engine: self)
        lastRankTickCounted = counting != nil

        // Shuffle color order (chromatic wind fix from Gemini Deep Think)
        var colorOrder = Array(0..<HexGrid.colorCount)
        var shuffleSeed = tickNumber &* 2654435761
        for i in stride(from: colorOrder.count - 1, through: 1, by: -1) {
            shuffleSeed = shuffleSeed &* 1103515245 &+ 12345
            let j = Int(shuffleSeed >> 16) % (i + 1)
            colorOrder.swapAt(i, j)
        }

        // Leaves-up: iterate rank from max down to 0, dispatching only the
        // compacted (rank,color) segments — exact thread counts, no
        // rank-mismatch early-out waste. ONE encoder for the whole tick:
        // memoryBarrier(scope: .buffers) between dispatches replaces the
        // per-(rank,color) encoder create/end cycle (up to 112 of them),
        // which measured slower than legacy on deep rank spreads.
        guard let enc = cmdBuf.makeComputeCommandEncoder() else { return }
        // A binary-only graph dispatches the binary kernel with its original
        // bindings; any non-binary node, the general kernel.
        let general = chooseTickKernel() == .general
        let pipeline: MTLComputePipelineState
        if counting != nil {
            pipeline = general ? tickCountingPipeline : tickBinaryCountingPipeline
        } else {
            pipeline = general ? tickPipeline : tickBinaryPipeline
        }
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(truthStateBuf, offset: 0, index: 0)
        enc.setBuffer(rankBuf, offset: 0, index: 1)
        enc.setBuffer(lut6LowBuf, offset: 0, index: 2)
        enc.setBuffer(lut6HighBuf, offset: 0, index: 3)
        enc.setBuffer(neighborsBuf, offset: 0, index: 4)
        enc.setBuffer(isRegisterBuf, offset: 0, index: 8)
        var kernelNodeCount = UInt32(nodeCount)
        enc.setBytes(&kernelNodeCount, length: 4, index: 9)
        if general { bindTernaryLanes(enc, firstIndex: 10) }
        if let c = counting { enc.setBuffer(c.kernelCount, offset: 0, index: 17) }
        let tpg = pipeline.maxTotalThreadsPerThreadgroup
        var first = true
        var dispatches = 0
        func dispatch(_ seg: (offset: Int, count: Int), rank rankLevel: Int, list: MTLBuffer) {
            if seg.count == 0 { return }
            if !first { enc.memoryBarrier(scope: .buffers) }
            first = false
            enc.setBuffer(list, offset: seg.offset * 4, index: 5)
            var groupSize = UInt32(seg.count)
            enc.setBytes(&groupSize, length: 4, index: 6)
            var currentRank = UInt64(rankLevel)
            enc.setBytes(&currentRank, length: 8, index: 7)
            enc.dispatchThreadgroups(
                MTLSize(width: (seg.count + tpg - 1) / tpg, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
            dispatches += 1
        }
        for rankLevel in stride(from: effectiveRankCount - 1, through: 0, by: -1) {
            if rankOrderVerified {
                // The rank's own list, one dispatch.
                dispatch(rankSpanTable[rankLevel], rank: rankLevel, list: rankListBuf!)
            } else {
                for colorIdx in colorOrder {
                    dispatch(segmentTable[rankLevel * HexGrid.colorCount + colorIdx], rank: rankLevel,
                             list: compactedListBuf)
                }
            }
        }
        // The latch on the GPU — in this command buffer, after the
        // rank dispatches — when `gpuLatchPlan` says so; otherwise the CPU
        // latch below. A counting session whose plan has kernel-evaluated
        // destinations reads their bytes between the kernel and the latch
        // (`afterKernel`), so its GPU latch goes in a second command buffer.
        let plan = gpuLatchPlan(daemonTick: requested, counting: counting != nil)
        // A plain daemon TICK remembers the lists it ran on; the
        // next one that finds them changed is the first after an edit.
        if requested && counting == nil { plainTickBackEdgeGeneration = backEdgeListGeneration }
        let latchInThisBuffer = plan != nil && (counting?.evaluatedDsts.isEmpty ?? true)
        if latchInThisBuffer, let p = plan { encodeLatch(enc, p, afterDispatches: dispatches > 0) }
        enc.endEncoding()
        lastRankTickDispatchCount = dispatches

        cmdBuf.commit()
        counting?.noteBuffer(ticks: 1, dispatches: dispatches
                             + (latchInThisBuffer ? ((plan?.twoPhase ?? false) ? 2 : 1) : 0))   // dispatches counted per buffer
        // Counted inside a session. A buffer that did not complete claims
        // nothing — no counts, no latch.
        guard waitCounted(cmdBuf) else { lastLatchOnGPU = false; return }
        counting?.afterKernel(engine: self)

        // Latch phase: copy each BACK_EDGE source's truth into its destination.
        // Two-phase semantics handled inside latchBackEdges (and by the plan
        // on the GPU). Runs after the combinational pass so the latched values
        // reflect this tick's computed sources.
        var latchedOnGPU = latchInThisBuffer
        if !latchInThisBuffer, let p = plan,
           let latchBuf = makeGPUCommandBuffer(), let latchEnc = latchBuf.makeComputeCommandEncoder() {
            encodeLatch(latchEnc, p, afterDispatches: false)
            latchEnc.endEncoding()
            latchBuf.commit()
            counting?.noteBuffer(ticks: 0, dispatches: p.twoPhase ? 2 : 1)   // the tick's latch
            guard waitCounted(latchBuf) else { lastLatchOnGPU = false; return }   // counted wait; a failed buffer claims nothing
            latchedOnGPU = true
        }
        if latchedOnGPU, let p = plan {
            // The latch's own count: destinations whose byte it changed, each once.
            counting?.lastCount = Int(p.counter.contents().load(as: UInt32.self))
            lastLatchTwoPhase = p.twoPhase
        } else {
            latchBackEdges()
            lastLatchTwoPhase = false
        }
        lastLatchOnGPU = latchedOnGPU
        counting?.finishTick(engine: self)
    }

    /// The pre-compaction dispatch path: launches whole color groups and
    /// lets the kernel's rank check early-out mismatched threads. Kept
    /// (test-only) as the independent ground truth for the compacted
    /// path's bit-for-bit equivalence tests, and as the honest "before"
    /// in the benchmark. Do not use in production paths.
    public func tickLegacy(tickNumber: UInt32) {
        // Dispatches whole colour groups, so it needs no compacted lists —
        // but it does need `effectiveRankCount`, which the compaction is
        // what computes. One O(N) pass, only when the topology changed.
        ensureRankTopology()
        guard let cmdBuf = makeGPUCommandBuffer() else { return }
        var colorOrder = Array(0..<HexGrid.colorCount)
        var shuffleSeed = tickNumber &* 2654435761
        for i in stride(from: colorOrder.count - 1, through: 1, by: -1) {
            shuffleSeed = shuffleSeed &* 1103515245 &+ 12345
            let j = Int(shuffleSeed >> 16) % (i + 1)
            colorOrder.swapAt(i, j)
        }
        let general = chooseTickKernel() == .general     // the binary-only kernel unless a node is not binary
        let pipeline = general ? tickPipeline : tickBinaryPipeline
        for rankLevel in stride(from: effectiveRankCount - 1, through: 0, by: -1) {
            for colorIdx in colorOrder {
                guard let enc = cmdBuf.makeComputeCommandEncoder() else { continue }
                enc.setComputePipelineState(pipeline)
                enc.setBuffer(truthStateBuf, offset: 0, index: 0)
                enc.setBuffer(rankBuf, offset: 0, index: 1)
                enc.setBuffer(lut6LowBuf, offset: 0, index: 2)
                enc.setBuffer(lut6HighBuf, offset: 0, index: 3)
                enc.setBuffer(neighborsBuf, offset: 0, index: 4)
                enc.setBuffer(colorGroupBufs[colorIdx], offset: 0, index: 5)
                var groupSize = UInt32(colorGroupSizes[colorIdx])
                enc.setBytes(&groupSize, length: 4, index: 6)
                var currentRank = UInt64(rankLevel)
                enc.setBytes(&currentRank, length: 8, index: 7)
                enc.setBuffer(isRegisterBuf, offset: 0, index: 8)
                var kernelNodeCount = UInt32(nodeCount)
                enc.setBytes(&kernelNodeCount, length: 4, index: 9)
                if general { bindTernaryLanes(enc, firstIndex: 10) }
                let tpg = pipeline.maxTotalThreadsPerThreadgroup
                enc.dispatchThreadgroups(
                    MTLSize(width: (colorGroupSizes[colorIdx] + tpg - 1) / tpg,
                            height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
                enc.endEncoding()
            }
        }
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        latchBackEdges()
    }

    /// TICK_SYNC — double-buffered synchronous mode (opt-in).
    ///
    /// Every node reads the PREVIOUS tick's truth buffer and writes the
    /// next one: cellular-automaton semantics, one dispatch for the whole
    /// graph, no rank/color ordering. Correct for wide-shallow synchronous
    /// workloads; NOT equivalent to rank mode on multi-rank combinational
    /// graphs (rank mode propagates through all ranks within one tick —
    /// sync mode advances one hop per tick). Registers hold their value in
    /// the kernel and are then latched by the same latch phase as rank
    /// mode, so BACK_EDGE semantics are identical across modes.
    public func tickSync(tickNumber: UInt32) {
        tickSyncHasRun = true                               // its first-use state, in the ledger
        guard let cmdBuf = makeGPUCommandBuffer(),
              let enc = cmdBuf.makeComputeCommandEncoder() else { return }
        let general = chooseTickKernel() == .general     // the binary-only kernel unless a node is not binary
        let pipeline = general ? syncPipeline : syncBinaryPipeline
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(truthStateBuf, offset: 0, index: 0)
        enc.setBuffer(truthStateBackBuf, offset: 0, index: 1)
        enc.setBuffer(lut6LowBuf, offset: 0, index: 2)
        enc.setBuffer(lut6HighBuf, offset: 0, index: 3)
        enc.setBuffer(neighborsBuf, offset: 0, index: 4)
        enc.setBuffer(isRegisterBuf, offset: 0, index: 5)
        var count = UInt32(nodeCount)
        enc.setBytes(&count, length: 4, index: 6)
        if general { bindTernaryLanes(enc, firstIndex: 7) }
        let tpg = pipeline.maxTotalThreadsPerThreadgroup
        enc.dispatchThreadgroups(
            MTLSize(width: (nodeCount + tpg - 1) / tpg, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        // A buffer that did not complete claims
        // nothing — no swap (the back buffer's writes stay unseen), no latch.
        guard commandBufferCompleted(cmdBuf) else { return }
        // Ping-pong swap: the freshly written buffer becomes current.
        // All external access goes through the property (audited).
        swap(&truthStateBuf, &truthStateBackBuf)
        latchBackEdges()
    }

    /// Bind the ternary lanes, the library, its size and the edge-weight
    /// lane at `firstIndex ... firstIndex + 6` — buffer(10…16) for the rank
    /// kernel, buffer(7…13) for the sync kernel. Every dispatch
    /// of a general kernel binds them: it reads the mode byte of every node
    /// it evaluates. The binary-only kernels take none of them.
    func bindTernaryLanes(_ enc: MTLComputeCommandEncoder, firstIndex i: Int) {
        enc.setBuffer(modeLaneBuf, offset: 0, index: i)
        enc.setBuffer(ttableIdBuf, offset: 0, index: i + 1)
        enc.setBuffer(thrLoBuf, offset: 0, index: i + 2)
        enc.setBuffer(thrHiBuf, offset: 0, index: i + 3)
        enc.setBuffer(ttableBuf, offset: 0, index: i + 4)
        var count = UInt32(ttableCount)
        enc.setBytes(&count, length: 4, index: i + 5)
        enc.setBuffer(edgeWeightsBuf, offset: 0, index: i + 6)
    }

    /// Read current truth states back to CPU
    public func readTruthStates() -> [UInt8] {
        let ptr = truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        return Array(UnsafeBufferPointer(start: ptr, count: nodeCount))
    }

    /// Read the root node(s) — nodes with rank 0
    public func readRoots() -> [(nodeIndex: Int, truthState: UInt8)] {
        let truth = readTruthStates()
        let rankPtr = rankBuf.contents().bindMemory(to: UInt64.self, capacity: nodeCount)
        var roots = [(Int, UInt8)]()
        for i in 0..<nodeCount where rankPtr[i] == 0 {
            roots.append((i, truth[i]))
        }
        return roots
    }

    // MARK: - BACK_EDGE primitive

    /// Errors raised by BACK_EDGE mutations that would violate the
    /// register-pattern invariant.
    public enum BackEdgeError: Error, CustomStringConvertible {
        /// Adding a BACK_EDGE whose destination has any combinational input.
        case destinationHasCombinationalInDegree(dst: UInt32, slot: Int, src: Int32)
        /// Source or destination is out of range for this engine's node table.
        case nodeIndexOutOfRange(node: UInt32, nodeCount: Int)
        /// The destination is a ternary node (a register stays BINARY; the
        /// engine's checked API refuses it, not only the daemon's CONNECT
        /// BACK).
        case destinationIsTernary(dst: UInt32, mode: UInt8)

        public var description: String {
            switch self {
            case let .destinationHasCombinationalInDegree(dst, slot, src):
                return "BACK_EDGE dst node \(dst) has a combinational input at slot \(slot) (source node \(src)); registers must have zero combinational fan-in"
            case let .nodeIndexOutOfRange(node, nodeCount):
                return "node index \(node) is out of range for engine with nodeCount=\(nodeCount)"
            case let .destinationIsTernary(dst, mode):
                return String(format: "BACK_EDGE dst node %u is a ternary node (mode 0x%02x); a register (BACK_EDGE destination) stays BINARY", dst, mode)
            }
        }
    }

    /// Number of registered BACK_EDGEs.
    public var backEdgeCount: Int { backEdgeSrcs.count }

    /// Number of combinational input slots currently in use on `node` —
    /// i.e. how many entries of `neighbors[node*6+0..5]` are not `-1`.
    public func combinationalFanIn(node: UInt32) -> Int {
        let n = Int(node)
        precondition(n < nodeCount, "node index \(n) >= nodeCount \(nodeCount)")
        let ptr = neighborsBuf.contents().bindMemory(to: Int32.self,
                                                     capacity: nodeCount * 6)
        var count = 0
        for k in 0..<6 where ptr[n * 6 + k] >= 0 { count += 1 }
        return count
    }

    /// Register a BACK_EDGE: at every tick boundary, `truth[src]` is latched
    /// into `truth[dst]`. The destination is flagged as a register so the
    /// rank kernel skips it during combinational evaluation.
    ///
    /// Validates the register invariant: `dst` must have zero combinational
    /// fan-in. Throws `BackEdgeError.destinationHasCombinationalInDegree`
    /// if the rule is violated. Use `clearEdges(node:)` (combinational)
    /// before turning a node into a register.
    public func addBackEdge(src: UInt32, dst: UInt32) throws {
        try validateBackEdge(src: src, dst: dst)
        try addBackEdgeUnchecked(src: src, dst: dst)
    }

    /// The apply half of `addBackEdge`, for a caller that has already
    /// called `validateBackEdge` and logged the record. Still range-checks
    /// the indices (the one check `addBackEdgeUnchecked` never skipped); it
    /// does NOT re-check combinational fan-in, which the validate step owns.
    public func registerValidatedBackEdge(src: UInt32, dst: UInt32) throws {
        try addBackEdgeUnchecked(src: src, dst: dst)
    }

    /// The check half of `addBackEdge`, with no mutation of any kind.
    ///
    /// Split out so a caller can VALIDATE, then LOG, then APPLY — the order
    /// the WAL file header promises for every mutation. `CONNECT BACK` used
    /// to apply first and append afterwards, with a comment excusing it; a
    /// crash in that window left a registered back edge nowhere in the log,
    /// and a WAL append that failed left the edge registered anyway. Nothing
    /// here writes, so a refused edge produces no record and no state.
    public func validateBackEdge(src: UInt32, dst: UInt32) throws {
        guard Int(src) < nodeCount else {
            throw BackEdgeError.nodeIndexOutOfRange(node: src, nodeCount: nodeCount)
        }
        guard Int(dst) < nodeCount else {
            throw BackEdgeError.nodeIndexOutOfRange(node: dst, nodeCount: nodeCount)
        }
        // A register stays BINARY, checked here so every caller of the
        // checked API gets it. Before the fan-in rule: the
        // daemon's CONNECT BACK always named this rule first for a ternary
        // node that also has fan-in.
        let dstMode = modeLane[Int(dst)]
        if TernaryReference.isTernary(dstMode) {
            throw BackEdgeError.destinationIsTernary(dst: dst, mode: dstMode)
        }
        let neighborsPtr = neighborsBuf.contents().bindMemory(to: Int32.self,
                                                              capacity: nodeCount * 6)
        for k in 0..<6 {
            let nb = neighborsPtr[Int(dst) * 6 + k]
            if nb >= 0 {
                throw BackEdgeError.destinationHasCombinationalInDegree(
                    dst: dst, slot: k, src: nb)
            }
        }
    }

    /// Internal: append a BACK_EDGE without validating combinational
    /// fan-in. Used by WAL replay where the original write was already
    /// validated; replay must succeed even if intermediate combinational
    /// state would temporarily violate the rule.
    ///
    /// "Unchecked" was only ever meant to skip the FAN-IN rule. The
    /// index range is checked here, once, at the single point every install
    /// path goes through — which is what lets `latchBackEdges` trust the
    /// lists on every tick instead of re-checking them.
    func addBackEdgeUnchecked(src: UInt32, dst: UInt32) throws {
        guard Int(src) < nodeCount else {
            throw BackEdgeError.nodeIndexOutOfRange(node: src, nodeCount: nodeCount)
        }
        guard Int(dst) < nodeCount else {
            throw BackEdgeError.nodeIndexOutOfRange(node: dst, nodeCount: nodeCount)
        }
        backEdgeSrcs.append(src)
        backEdgeDsts.append(dst)
        let ptr = isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        ptr[Int(dst)] = 1
    }

    /// Remove every BACK_EDGE whose destination is `dst`. The node also
    /// loses its register flag, so the next tick's combinational pass will
    /// evaluate it like an ordinary node again.
    public func clearBackEdges(toNode dst: UInt32) throws {
        guard Int(dst) < nodeCount else {
            throw BackEdgeError.nodeIndexOutOfRange(node: dst, nodeCount: nodeCount)
        }
        var keepSrcs: [UInt32] = []
        var keepDsts: [UInt32] = []
        keepSrcs.reserveCapacity(backEdgeSrcs.count)
        keepDsts.reserveCapacity(backEdgeDsts.count)
        for i in 0..<backEdgeSrcs.count where backEdgeDsts[i] != dst {
            keepSrcs.append(backEdgeSrcs[i])
            keepDsts.append(backEdgeDsts[i])
        }
        backEdgeSrcs = keepSrcs
        backEdgeDsts = keepDsts
        let ptr = isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        ptr[Int(dst)] = 0
    }

    /// Whether `node` is currently a back-edge destination (register).
    ///
    /// A node outside the table is not a register, and asking whether it
    /// is must not read past the flag buffer. The refusal is the answer
    /// `false` rather than a throw: every caller in the tree asks this inside
    /// a non-throwing predicate, and "no" is the honest answer for a node
    /// this engine does not have.
    public func isRegister(node: UInt32) -> Bool {
        guard Int(node) < nodeCount else { return false }
        let ptr = isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        return ptr[Int(node)] != 0
    }

    /// Latch phase: snapshot every src truth, then write every dst.
    /// Two-phase write-back handles chained back-edges (one entry's dst is
    /// another entry's src) by latching from pre-tick state. Runs on the
    /// CPU; the truth buffer is unified-memory shared. The
    /// rank-mode tick latches on the GPU instead when `gpuLatchPlan` says so
    /// (`LatchPlan`); this latch, and inside a counting session the
    /// counting latch, stay the reference the GPU latch is tested against.
    public func latchBackEdges() {
        let n = backEdgeSrcs.count
        if n == 0 { latchChangeCounter.map { $0.lastCount = 0 }; return }
        let ptr = truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        // When a caller asked for it, the latch counts
        // the registers whose byte it changed — from its own writes: the
        // byte each destination held before the latch, against what it
        // holds after, each destination once (two back edges into one
        // register are one register). Same two phases, same writes, its
        // buffers reused across ticks.
        if let counter = latchChangeCounter {
            counter.lastCount = counter.countingLatch(ptr: ptr, srcs: backEdgeSrcs, dsts: backEdgeDsts)
            return
        }
        var snapshot = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            snapshot[i] = ptr[Int(backEdgeSrcs[i])]
        }
        for i in 0..<n {
            ptr[Int(backEdgeDsts[i])] = snapshot[i]
        }
    }

    // MARK: - The back-edge latch on the GPU

    /// The latch as kernels, the same bytes as `latchBackEdges`
    /// (and inside a counting session the same count as the counting latch).
    ///
    /// The plain latch snapshots every source, then writes every destination
    /// in list order, so the LAST back edge into a destination wins. The plan
    /// keeps one effective back edge per distinct destination — that last
    /// one — in the list order of those edges, built on the CPU (one O(back
    /// edges) pass over a per-node mark) the first time a GPU latch needs it
    /// after the lists changed — in plain TICK, the second
    /// consecutive TICK after an edit (`gpuLatchPlan`) — and kept until they
    /// change again (both lists' `didSet` drops it). Each destination is then written by one thread
    /// once, so writes never conflict, and the latch's count — destinations
    /// whose byte it changed, each once — is one atomic add per SIMD group.
    ///
    /// When no effective source is a destination, no thread reads a byte
    /// another writes, and one kernel does `dst := truth[src]`
    /// (`dagdb_latch_direct`). Otherwise two dispatches reproduce the plain
    /// latch's two phases: snapshot every effective source into `scratch`,
    /// then write (`dagdb_latch_snapshot`, `dagdb_latch_write`). Sources that
    /// are not effective (an earlier back edge into a destination fed again
    /// later) are never read, as their snapshot is never written.
    ///
    /// Memory: 8 bytes per effective back edge, plus 1 when two-phase, plus
    /// the 4-byte counter (`allocationBytes`: `latch.*`).
    final class LatchPlan {
        let count: Int
        let effSrc: MTLBuffer      // UInt32 per effective back edge
        let effDst: MTLBuffer      // UInt32 per effective back edge
        let twoPhase: Bool
        let scratch: MTLBuffer?    // UInt8 per effective back edge, two-phase only
        let counter: MTLBuffer     // atomic_uint: the destinations the latch changed

        init(count: Int, effSrc: MTLBuffer, effDst: MTLBuffer, twoPhase: Bool, scratch: MTLBuffer?,
             counter: MTLBuffer) {
            self.count = count; self.effSrc = effSrc; self.effDst = effDst
            self.twoPhase = twoPhase; self.scratch = scratch; self.counter = counter
        }
    }

    /// The plan for the current back-edge lists, nil until a GPU latch needs
    /// it (and after every change to the lists).
    var latchPlan: LatchPlan?

    /// Test seam: nil = the policy (`gpuLatchPlan`), true = every
    /// rank-mode tick latches on the GPU, false = every one on the CPU. A
    /// test ticks twins with true and false. Not used by the daemon.
    var latchOnGPU: Bool?

    /// Whether the last rank-mode tick (`tick(tickNumber:…)`)
    /// latched on the GPU, and whether in two phases. Read by the tests.
    public internal(set) var lastLatchOnGPU = false
    public internal(set) var lastLatchTwoPhase = false

    /// How many latch plans were built — one O(back edges) pass
    /// each. Read by the tests.
    public private(set) var latchPlanBuildCount = 0

    /// The wall time of the last plan build, in ms (diagnostic).
    public private(set) var lastLatchPlanBuildMs = 0.0

    /// Advanced by every change to either back-edge
    /// list (`backEdgeListsChanged`, the same `didSet` that drops the plan).
    private(set) var backEdgeListGeneration: UInt64 = 0

    /// The generation the last plain daemon TICK (a rank-mode
    /// tick asked for with `rankOrderVerified: true`, outside a counting
    /// session) ran on; nil before the engine's first. A plain TICK that finds
    /// it different from the lists' generation is the first plain TICK after
    /// a back-edge edit.
    private var plainTickBackEdgeGeneration: UInt64?

    /// Plain daemon TICKs that took the CPU latch because they
    /// were the first after a back-edge edit, where building on first need
    /// would have built the plan (diagnostic).
    public private(set) var latchPlanDeferredTicks = 0

    /// A plain daemon TICK latches on the GPU from this many back
    /// edges on (the CPU latch measured at 0.56 of the plain tick at 128³,
    /// 2,097,152 back edges).
    public static let gpuLatchMinBackEdges = 65_536

    // MARK: The frontier session's stored state (DagDBEngine+Frontier.swift)

    /// The reverse index (readers of every node through a slot, and the
    /// effective back edges each node feeds) with the frontier's lists,
    /// bitmaps and counters. Built when a frontier session opens and finds
    /// none; kept between sessions; dropped by every topology writer: a
    /// change to either back-edge list (`backEdgeListsChanged`), a rank write
    /// (`markRankTopologyDirty`), and `dropFrontierIndex()` (the daemon calls
    /// it for every command that may move a slot). Never by a table, mode,
    /// truth, weight or value write.
    var frontierIndex: FrontierIndex?

    /// How many reverse indexes were built — one O(slots + back
    /// edges) pass each. Read by the tests.
    public internal(set) var frontierIndexBuildCount = 0
    /// The wall time of the last index build, in ms (diagnostic).
    public internal(set) var lastFrontierIndexBuildMs = 0.0

    /// The frontier kernels, made from `library` at the first
    /// frontier session (nil until then; nil and unavailable if one is missing).
    var frontierPipelineCache: FrontierPipelines?
    var frontierPipelinesTried = false
    let library: MTLLibrary
    /// The wall time it took to make the frontier kernels (ms;
    /// 0 until the first frontier session made them). Diagnostic.
    public internal(set) var frontierPipelineBuildMs = 0.0
    /// Whether the frontier kernels have been made. Diagnostic.
    public var frontierPipelinesReady: Bool { frontierPipelineCache != nil }

    /// A rank (the latch) is dispatched whole when its list
    /// holds more than this fraction of the rank's nodes (of the effective
    /// back edges); read when a frontier session opens.
    ///
    /// The whole-rank fallback is removed from the policy — the default is
    /// `.infinity`, so after a session's first tick (whole by construction)
    /// every rank and the latch are dispatched from their lists. On a dense
    /// object (1024², 42 % of nodes changing per tick) the session without
    /// it ran at 0.987 of UNTIL_STABLE without the frontier, so the fallback
    /// bought nothing. The threshold stays as a test seam only: committed tests
    /// set 0 (whole whenever anything is listed) and 0.25 and assert what
    /// each does; the daemon's DAGDB_FRONTIER_TAU_FOR_TESTING sets it too.
    public var frontierWholeFraction: Double = .infinity

    /// The depth guard. A frontier
    /// session opens its frontier only on a graph with at most this many
    /// non-empty rank levels (`nonEmptyRankLevels`); a deeper graph's session
    /// runs the counting path, one tick per command buffer (exact; the
    /// frontier's two dispatches per rank lose to the plain tick's one there).
    /// The default is `frontierDepthGuardDefault`, chosen from the
    /// measured crossover. A test seam: `Int.max` turns the
    /// guard off (a test control); the daemon's
    /// DAGDB_FRONTIER_MAX_LEVELS_FOR_TESTING sets it.
    public var frontierMaxRankLevels: Int = DagDBEngine.frontierDepthGuardDefault
    /// The depth guard's default (bounded to [16, 63]). Measured on a deep,
    /// dense test object at 9,216 nodes, TICK UNTIL_STABLE MAX 32, the
    /// frontier (guard off) against the counting loop without the frontier,
    /// the median over five interleaved runs of each run's median
    /// per-round ratio: 0.737 at 12 levels, 0.864 at 16, 0.924 at 24, 1.004
    /// at 32, 1.218 at 48, 1.339 at 64. 24: the deepest measured level
    /// at which the frontier still won; at 32 the two tie, so 32 levels
    /// already take the counting path.
    public static let frontierDepthGuardDefault = 24
    /// Whether the last frontier session found the graph deeper
    /// than `frontierMaxRankLevels` and ran the counting path. Diagnostic.
    public internal(set) var lastFrontierDepthGuarded = false

    /// The most dispatches one command buffer of
    /// batched frontier ticks may hold. A batch holds ⌊cap / (dispatches per
    /// tick)⌋ ticks, at least one.
    public static let maxDispatchesPerCommandBuffer = 131_072

    /// A tick's command buffer that ended with a
    /// status other than `completed` after its wait — its writes are not
    /// claimed. Set by the tick paths (`tick`, `tickSync`, the frontier's
    /// per-tick and batched ticks) and kept until `clearGPUFailure()`; the
    /// daemon clears it before every tick verb and replies `ERROR gpu:` when
    /// a tick sets it.
    public struct CommandBufferFailure: Error, Equatable, CustomStringConvertible {
        /// The status by name: notEnqueued, enqueued, committed, scheduled, error.
        public let status: String
        /// The command buffer's error, if it carried one.
        public let error: String?
        public var description: String {
            "command buffer status \(status) (\(error ?? "no error object"))"
        }
    }
    public internal(set) var gpuFailure: CommandBufferFailure?
    public func clearGPUFailure() { gpuFailure = nil }

    /// Test seam: the fault injection. nil: off.
    /// k: the next k command buffers checked after their wait read their own
    /// status; the one after reads `.error` (with no error object) and the
    /// seam turns itself off. Read by the tests only.
    var commandBufferStatusFailsAfterForTesting: Int?

    static func statusName(_ s: MTLCommandBufferStatus) -> String {
        switch s {
        case .notEnqueued: return "notEnqueued"
        case .enqueued: return "enqueued"
        case .committed: return "committed"
        case .scheduled: return "scheduled"
        case .completed: return "completed"
        case .error: return "error"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }

    /// After a tick's `waitUntilCompleted`, whether its command
    /// buffer completed. Any other status records `gpuFailure` and returns
    /// false: the caller claims nothing of that buffer (no latch after it, no
    /// counts, no swap) and returns.
    func commandBufferCompleted(_ b: MTLCommandBuffer) -> Bool {
        var status = b.status
        // The error's stable words (domain and code), never its localized description.
        var err = b.error.map { Reply.errorWords($0) }
        if let k = commandBufferStatusFailsAfterForTesting {
            if k <= 0 {
                commandBufferStatusFailsAfterForTesting = nil
                status = .error; err = nil
            } else {
                commandBufferStatusFailsAfterForTesting = k - 1
            }
        }
        if status == .completed { return true }
        gpuFailure = CommandBufferFailure(status: Self.statusName(status), error: err)
        return false
    }

    /// All the dispatches the last frontier command buffer encoded
    /// (args kernels, rank kernels, latch; every tick of a batch).
    /// `lastRankTickDispatchCount` counts, for a frontier tick, the rank
    /// kernels of the last tick only — one per non-empty rank, as the
    /// per-rank path. Diagnostics.
    public internal(set) var lastFrontierDispatches = 0
    /// The ticks the last frontier command buffer ran (1 for a
    /// tick through `tick(tickNumber:rankOrderVerified:)`, up to the batch
    /// size through `sessionTicks`). Diagnostic.
    public internal(set) var lastFrontierBatchTicks = 0

    /// What the last rank-mode tick did inside a frontier session.
    /// `lastTickFrontier`: it ran through the frontier (false: the plain
    /// path, or no session). `lastTickFrontierFull`: it was a session's first
    /// (whole) tick. `lastFrontierEvaluated` / `lastFrontierLatched`: the rank
    /// entries / effective back edges it dispatched. `lastFrontierWholeRanks`:
    /// the ranks it dispatched whole; `lastFrontierListedRanks`: the ranks it
    /// dispatched from a non-empty list. Read by the tests.
    public internal(set) var lastTickFrontier = false
    public internal(set) var lastTickFrontierFull = false
    public internal(set) var lastFrontierEvaluated = 0
    public internal(set) var lastFrontierLatched = 0
    public internal(set) var lastFrontierWholeRanks = 0
    public internal(set) var lastFrontierListedRanks = 0

    /// The policy: the GPU latch inside a counting session (TICK
    /// UNTIL_STABLE), and for a daemon TICK (`rankOrderVerified: true`
    /// requested) with at least `gpuLatchMinBackEdges` back edges; never
    /// with no back edges. Everything else — the library and EVAL tick
    /// (`tick(tickNumber:)`), `tickLegacy`, `tickSync`, a small graph's TICK —
    /// keeps the CPU latch. nil (the CPU latch) also when the plan cannot be
    /// built: an allocation failed, or an index is outside the node table.
    ///
    /// In a plain daemon TICK the first TICK after a
    /// back-edge edit takes the CPU latch — the reference, at the plain CPU cost — and
    /// builds nothing; the plan is built at the second consecutive plain TICK
    /// with no back-edge edit between, so a workload that alternates an edit
    /// with a TICK never pays for a plan it would use once. "An edit" is a
    /// change to either list between two plain TICKs (the generation the last
    /// plain TICK ran on differs from the lists'); the engine's first plain
    /// TICK has none before it and builds. A counting session
    /// (TICK UNTIL_STABLE, whose ticks come in a run) and the seam
    /// `latchOnGPU = true` build on first need. The plan is still
    /// dropped on every back-edge change (`backEdgeListsChanged`).
    private func gpuLatchPlan(daemonTick: Bool, counting: Bool) -> LatchPlan? {
        let n = backEdgeSrcs.count
        guard n > 0 else { return nil }
        guard latchOnGPU ?? (counting || (daemonTick && n >= Self.gpuLatchMinBackEdges)) else { return nil }
        if latchPlan == nil {
            if latchOnGPU == nil, !counting, let seen = plainTickBackEdgeGeneration, seen != backEdgeListGeneration {
                latchPlanDeferredTicks += 1     // the first plain TICK after an edit
                return nil
            }
            latchPlan = buildLatchPlan()
        }
        return latchPlan
    }

    /// ONE backwards pass over the two lists, plain
    /// arrays only. A destination's first sighting walking backwards is its
    /// LAST back edge in list order — the one whose write the plain latch
    /// keeps. A flag byte per node: bit 0 "is a destination", bit 1 "is an
    /// effective source"; an effective edge whose destination already carries
    /// bit 1, or whose source carries bit 0 (read after the destination's own
    /// bit is set, so a self-loop counts), makes the plan two-phase. Every
    /// step is branch-free but the range check: the kept edge is always
    /// written at the next free slot from the back of a scratch array, and
    /// that slot is taken only when the edge is kept, so the effective edges
    /// come out in list order. They are then copied into the plan's buffers
    /// (`makeBuffer(bytes:)`, a copy of the kept edges, not a pass over the
    /// lists). An earlier build made the same plan in three passes (range check, a
    /// backwards mark walk, a forward fill), with a branch per edge that the
    /// CPU mispredicts on random lists: 8.5 ms against 3.2 ms for this pass at
    /// 1,048,576 nodes and 2,000,000 random back edges. The plan is the same,
    /// buffer for buffer (test `testF1FPlanBuildEqualsTheReference`).
    ///
    /// nil, with nothing kept, if an index is outside the table or an
    /// allocation fails — the tick then latches on the CPU, exactly as before.
    func buildLatchPlan() -> LatchPlan? {
        let t0 = CFAbsoluteTimeGetCurrent()
        let n = backEdgeSrcs.count
        guard n > 0, n == backEdgeDsts.count, nodeCount > 0 else { return nil }
        let nodes = nodeCount
        guard let rawFlags = calloc(nodes, 1) else { return nil }
        defer { free(rawFlags) }
        guard let rawOut = malloc(n * 8) else { return nil }
        defer { free(rawOut) }
        let flags = rawFlags.bindMemory(to: UInt8.self, capacity: nodes)
        let outSrc = rawOut.bindMemory(to: UInt32.self, capacity: 2 * n)
        let outDst = outSrc + n
        let (inRange, first, twoPhase): (Bool, Int, Bool) = backEdgeSrcs.withUnsafeBufferPointer { sp in
            backEdgeDsts.withUnsafeBufferPointer { dp in
                guard let sb = sp.baseAddress, let db = dp.baseAddress else { return (false, n, false) }
                var j = n                   // the kept edges fill [j, n); j > i throughout, so j - 1 >= 0
                var two: UInt8 = 0
                var i = n
                while i > 0 {
                    i -= 1
                    let sv = sb[i], dv = db[i]
                    let s = Int(sv), d = Int(dv)
                    if s >= nodes || d >= nodes { return (false, n, false) }
                    let fd = flags[d]
                    let kept = (fd & 1) ^ 1                 // 1 at d's last edge, 0 at every earlier one
                    flags[d] = fd | 1
                    let fs = flags[s]
                    two |= kept & ((fd >> 1) | fs)          // d is an effective source, or s a destination
                    flags[s] = fs | (kept << 1)
                    outSrc[j - 1] = sv; outDst[j - 1] = dv
                    j -= Int(kept)
                }
                return (true, j, two & 1 != 0)
            }
        }
        let m = n - first
        guard inRange, m > 0 else { return nil }
        let shared = MTLResourceOptions.storageModeShared
        guard let bs = device.makeBuffer(bytes: outSrc + first, length: m * 4, options: shared),
              let bd = device.makeBuffer(bytes: outDst + first, length: m * 4, options: shared),
              let bc = device.makeBuffer(length: 4, options: shared) else { return nil }
        var scratch: MTLBuffer?
        if twoPhase {
            guard let b = device.makeBuffer(length: m, options: shared) else { return nil }
            scratch = b
        }
        latchPlanBuildCount += 1
        lastLatchPlanBuildMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        return LatchPlan(count: m, effSrc: bs, effDst: bd, twoPhase: twoPhase, scratch: scratch, counter: bc)
    }

    /// Encode the plan's latch into `enc`: after the rank dispatches (a
    /// buffer barrier first, as between ranks) or alone. Zeroes the counter.
    private func encodeLatch(_ enc: MTLComputeCommandEncoder, _ p: LatchPlan, afterDispatches: Bool) {
        p.counter.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        if afterDispatches { enc.memoryBarrier(scope: .buffers) }
        var count = UInt32(p.count)
        enc.setBuffer(truthStateBuf, offset: 0, index: 0)
        func dispatch(_ pipeline: MTLComputePipelineState) {
            enc.setComputePipelineState(pipeline)
            let tpg = pipeline.maxTotalThreadsPerThreadgroup
            enc.dispatchThreadgroups(MTLSize(width: (p.count + tpg - 1) / tpg, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
        }
        if p.twoPhase {
            enc.setBuffer(p.effSrc, offset: 0, index: 1)
            enc.setBuffer(p.scratch!, offset: 0, index: 2)
            enc.setBytes(&count, length: 4, index: 3)
            dispatch(latchSnapshotPipeline)
            enc.memoryBarrier(scope: .buffers)
            enc.setBuffer(p.effDst, offset: 0, index: 1)
            enc.setBuffer(p.counter, offset: 0, index: 4)
            dispatch(latchWritePipeline)
        } else {
            // One entry per thread: `stride` is the number of threads that
            // take entries (thread j takes j, j + stride, …).
            var stride = UInt32(p.count)
            enc.setBuffer(p.effSrc, offset: 0, index: 1)
            enc.setBuffer(p.effDst, offset: 0, index: 2)
            enc.setBytes(&count, length: 4, index: 3)
            enc.setBuffer(p.counter, offset: 0, index: 4)
            enc.setBytes(&stride, length: 4, index: 5)
            dispatch(latchDirectPipeline)
        }
    }

    /// The counts a counting tick reports, switched on
    /// for the length of `body` (TICK UNTIL_STABLE). Off, the latch is
    /// today's two loops and the tick dispatches today's kernels.
    ///
    /// - `lastCount`: the registers the last latch changed, counted by the
    ///   latch from its own writes, each destination once.
    /// - `lastChanged`: the truth bytes the last `tick(…)` changed, the
    ///   byte after the tick against the byte before it, registers included —
    ///   with no copy or scan of the truth buffer. It is the counting kernel's
    ///   count (nodes whose new byte differs from their old one) plus the
    ///   latch's, corrected on the back-edge destinations the kernel also
    ///   evaluates (destinations not flagged as registers): for those few the
    ///   byte before the tick and the byte before the latch are kept.
    ///
    /// Both counts are zeroed at the start of every tick of the session, so a
    /// tick that runs nothing reports 0 and 0.
    ///
    /// The plan (which destinations the kernel also evaluates; whether any
    /// two back edges share a destination) is taken when the session opens
    /// and holds only while the back-edge layout does: the body may tick, and
    /// must not add, clear or move back edges or write register flags.
    /// That is enforced by name (`CountingSessionRefusal`):
    /// - each tick first checks, in O(1), that the destination list is the
    ///   count and the storage the plan was taken from (every edit through
    ///   the engine copies the list first, since the plan holds it); new
    ///   storage is compared by the layout checksum (every destination and
    ///   its register flag, by position) and adopted if equal. A change
    ///   refuses that tick and every later one in the session, nothing
    ///   ticked;
    /// - when the session closes, the checksum is taken again, which also
    ///   sees a raw write to the register flags (a per-tick check of those
    ///   would be the O(back edges) scan the counting kernels avoid). Either way the session
    ///   throws instead of returning.
    /// `marks` is one byte per node, from `calloc`, held only while counting
    /// (a failed allocation is a refusal, not a trap).
    public final class LatchChangeCounter {
        let marks: UnsafeMutablePointer<UInt8>
        public var lastCount = 0
        /// The truth bytes the last counting tick changed.
        public internal(set) var lastChanged = 0
        /// The counting kernel's atomic counter (4 bytes).
        let kernelCount: MTLBuffer
        /// Back-edge count the plan was taken for.
        let planEdges: Int
        /// No two back edges share a destination: the latch counts in its
        /// write loop.
        let distinctDsts: Bool
        /// Distinct back-edge destinations the kernel also evaluates (not
        /// flagged as registers), with their bytes before the tick and
        /// before the latch.
        let evaluatedDsts: [Int]
        var preTick: [UInt8]
        var preLatch: [UInt8]
        var kernelChanged = 0
        // Reused by the latch (no per-tick allocation).
        var latchSnap: [UInt8] = []
        var latchBefore: [UInt8] = []
        /// The destination list the plan was taken from
        /// (held, so an edit through the engine copies it) and the layout
        /// checksum at open; the session's ticks so far; its refusal.
        var planDsts: [UInt32]
        let planChecksum: UInt64
        let nodeCount: Int
        var ticksSeen = 0
        public private(set) var refusal: CountingSessionRefusal?
        /// The frontier state while this is a frontier session
        /// (`frontierSession`); nil in a counting session, and in a frontier
        /// session whose index could not be had (then every tick is the
        /// counting session's plain tick — exact, only not incremental).
        var frontier: FrontierState?
        /// Whether this session was opened as a frontier session.
        public internal(set) var frontierRequested = false
        /// Whether its ticks run through the frontier (its index
        /// was had). Read by the tests.
        public var frontierActive: Bool { frontier != nil }
        /// The times the CPU waited on the GPU during
        /// this session (`waitUntilCompleted` on a tick's command buffer),
        /// and those buffers' GPU time (ms, from their timestamps).
        public internal(set) var gpuWaits = 0
        public internal(set) var gpuMs = 0.0
        /// The ticks this session encoded into
        /// command buffers (a batch's every tick, past the fixed point
        /// included), the most ticks one buffer held, and the most dispatches
        /// a buffer of two or more ticks held (0: none).
        public internal(set) var ticksEncoded = 0
        public internal(set) var maxBufferTicks = 0
        public internal(set) var maxMultiTickBufferDispatches = 0
        func noteBuffer(ticks: Int, dispatches: Int) {
            ticksEncoded += ticks
            maxBufferTicks = max(maxBufferTicks, ticks)
            if ticks >= 2 { maxMultiTickBufferDispatches = max(maxMultiTickBufferDispatches, dispatches) }
        }
        /// A batch's per-tick counters (`DagDBEngine.sessionTicks`),
        /// two atomic words per tick in a 32-byte slot (the rank kernels'
        /// changed nodes at +0, the latch's changed registers at +16).
        /// Allocated at the session's first batch, held while it is open.
        var batchCountersBuf: MTLBuffer?
        func batchCounters(ticks: Int, device: MTLDevice) -> MTLBuffer? {
            let need = max(ticks, 1) * 32
            if let b = batchCountersBuf, b.length >= need { return b }
            batchCountersBuf = device.makeBuffer(length: need, options: .storageModeShared)
            return batchCountersBuf
        }

        init(nodeCount: Int, kernelCount: MTLBuffer, marks: UnsafeMutablePointer<UInt8>,
             dsts: [UInt32], isRegister: UnsafePointer<UInt8>) {
            self.marks = marks
            self.kernelCount = kernelCount
            self.nodeCount = nodeCount
            planEdges = dsts.count
            planDsts = dsts
            var distinct = true
            var evaluated: [Int] = []
            var sum: UInt64 = 0
            let mark = marks
            dsts.withUnsafeBufferPointer { dp in
                for i in 0..<dp.count {
                    let d = Int(dp[i])
                    sum &+= Self.layoutTerm(i, dp[i], d < nodeCount ? UInt64(isRegister[d]) : 0x1FF)
                    if mark[d] != 0 { distinct = false; continue }
                    mark[d] = 1
                    if isRegister[d] == 0 { evaluated.append(d) }
                }
                for i in 0..<dp.count { mark[Int(dp[i])] = 0 }
            }
            planChecksum = sum
            distinctDsts = distinct
            evaluatedDsts = evaluated
            preTick = [UInt8](repeating: 0, count: evaluated.count)
            preLatch = [UInt8](repeating: 0, count: evaluated.count)
        }

        deinit { free(marks) }

        /// One back edge's term of the layout checksum —
        /// its destination and that destination's register flag (0x1FF for a
        /// destination past the table), weighted by its position, so a moved,
        /// swapped, added, dropped or re-flagged destination moves the sum.
        /// The terms are independent: one pass, no serial chain.
        @inline(__always)
        static func layoutTerm(_ i: Int, _ d: UInt32, _ flag: UInt64) -> UInt64 {
            (((UInt64(d) &<< 9) | flag) &+ 1) &* ((UInt64(i) &* 0x9E37_79B9_7F4A_7C15) | 1)
        }

        static func layoutChecksum(_ dsts: [UInt32], engine: DagDBEngine) -> UInt64 {
            let n = engine.nodeCount
            let reg = engine.isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: max(n, 1))
            var sum: UInt64 = 0
            dsts.withUnsafeBufferPointer { dp in
                for i in 0..<dp.count {
                    let d = Int(dp[i])
                    sum &+= layoutTerm(i, dp[i], d < n ? UInt64(reg[d]) : 0x1FF)
                }
            }
            return sum
        }

        static func sameStorage(_ a: [UInt32], _ b: [UInt32]) -> Bool {
            a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress } }
        }

        /// At the start of every tick of the session:
        /// whether the plan still describes the back-edge layout. O(1) while
        /// the engine holds the list the plan holds.
        func admitTick(engine: DagDBEngine) -> Bool {
            ticksSeen += 1
            if refusal != nil { return false }
            let now = engine.backEdgeDsts
            if now.count == planEdges {
                if Self.sameStorage(now, planDsts) { return admitFrontier(engine: engine) }
                if Self.layoutChecksum(now, engine: engine) == planChecksum {
                    planDsts = now   // the same layout in new storage: adopted
                    return admitFrontier(engine: engine)
                }
            }
            refusal = .layoutChanged(edgesAtOpen: planEdges, edgesNow: now.count, refusedTick: ticksSeen)
            return false
        }

        /// A frontier session's reverse index is the
        /// engine's for the whole session. Every topology writer through the
        /// engine drops it (a back-edge list, a rank write,
        /// `dropFrontierIndex`); the tick that sees it gone, and every later
        /// one, is refused, nothing ticked, as a layout change is refused.
        func admitFrontier(engine: DagDBEngine) -> Bool {
            if let f = frontier, engine.frontierIndex !== f.index {
                refusal = .topologyChanged(refusedTick: ticksSeen)
                return false
            }
            return true
        }

        /// When the body returns: the session's refusal,
        /// or the checksum taken again (it sees raw register-flag writes too).
        func closingRefusal(engine: DagDBEngine) -> CountingSessionRefusal? {
            if let r = refusal { return r }
            let now = engine.backEdgeDsts
            if now.count == planEdges && Self.layoutChecksum(now, engine: engine) == planChecksum {
                if let f = frontier, engine.frontierIndex !== f.index { return .topologyChanged(refusedTick: nil) }   // the frontier's index was dropped
                return nil
            }
            return .layoutChanged(edgesAtOpen: planEdges, edgesNow: now.count, refusedTick: nil)
        }

        /// Before the dispatch: zero the kernel's counter; keep the evaluated
        /// destinations' bytes.
        func beginTick(engine: DagDBEngine) {
            kernelCount.contents().storeBytes(of: UInt32(0), as: UInt32.self)
            kernelChanged = 0
            lastChanged = 0
            let ptr = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: max(engine.nodeCount, 1))
            for (j, d) in evaluatedDsts.enumerated() { preTick[j] = ptr[d] }
        }

        /// After the dispatch, before the latch.
        func afterKernel(engine: DagDBEngine) {
            kernelChanged = Int(kernelCount.contents().load(as: UInt32.self))
            let ptr = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: max(engine.nodeCount, 1))
            for (j, d) in evaluatedDsts.enumerated() { preLatch[j] = ptr[d] }
        }

        /// After the latch: every byte the tick changed, counted once.
        /// A node outside the back-edge destinations changed iff the kernel
        /// counted it; a register destination iff the latch counted it; an
        /// evaluated destination iff its byte now differs from before the
        /// tick — so its kernel count and latch count are replaced by that.
        func finishTick(engine: DagDBEngine) {
            let ptr = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: max(engine.nodeCount, 1))
            var c = kernelChanged + lastCount
            for (j, d) in evaluatedDsts.enumerated() {
                let now = ptr[d]
                if preLatch[j] != preTick[j] { c -= 1 }   // the kernel counted it
                if now != preLatch[j] { c -= 1 }          // the latch counted it
                if now != preTick[j] { c += 1 }           // the tick changed it
            }
            lastChanged = c
        }

        /// The latch, counting: snapshot every source, then write every
        /// destination (the plain latch's two phases and writes), returning
        /// the destinations whose byte the writes changed, each once.
        func countingLatch(ptr: UnsafeMutablePointer<UInt8>, srcs: [UInt32], dsts: [UInt32]) -> Int {
            let n = dsts.count
            if latchSnap.count < n { latchSnap = [UInt8](repeating: 0, count: n) }
            var changed = 0
            let mark = marks
            srcs.withUnsafeBufferPointer { sp in
                dsts.withUnsafeBufferPointer { dp in
                    latchSnap.withUnsafeMutableBufferPointer { snap in
                        for i in 0..<n { snap[i] = ptr[Int(sp[i])] }
                        if distinctDsts && n == planEdges {
                            // One write per destination: its byte before the
                            // write is its byte before the latch.
                            for i in 0..<n {
                                let d = Int(dp[i]), v = snap[i]
                                if ptr[d] != v { changed += 1 }
                                ptr[d] = v
                            }
                            return
                        }
                        if latchBefore.count < n { latchBefore = [UInt8](repeating: 0, count: n) }
                        latchBefore.withUnsafeMutableBufferPointer { before in
                            for i in 0..<n { before[i] = ptr[Int(dp[i])] }
                            for i in 0..<n { ptr[Int(dp[i])] = snap[i] }
                            for i in 0..<n {
                                let d = Int(dp[i])
                                if mark[d] == 0 { mark[d] = 1; if ptr[d] != before[i] { changed += 1 } }
                            }
                            for i in 0..<n { mark[Int(dp[i])] = 0 }
                        }
                    }
                }
            }
            return changed
        }
    }
    var latchChangeCounter: LatchChangeCounter?

    /// The counting session could not get its 4-byte counter.
    public struct ChangeCounterUnavailable: Error, CustomStringConvertible {
        public var description: String { "change counter: buffer allocation failed (4 bytes)" }
    }

    /// The counting session could not get its marks
    /// (one byte per node).
    public struct ChangeMarksUnavailable: Error, CustomStringConvertible {
        public let bytes: Int
        public var description: String { "change marks: buffer allocation failed (\(bytes) bytes)" }
    }

    /// The counting session's precondition, refused by
    /// name — a session opened inside another's body, or a back-edge layout
    /// that changed after the session took its plan.
    public enum CountingSessionRefusal: Error, Equatable, CustomStringConvertible {
        case nested
        /// `refusedTick`: the session's tick (1-based) that saw the change and
        /// ran nothing, as every later one; nil when it was found at close.
        case layoutChanged(edgesAtOpen: Int, edgesNow: Int, refusedTick: Int?)
        /// Inside a frontier session a topology
        /// writer (a slot, a rank) dropped the session's reverse index.
        case topologyChanged(refusedTick: Int?)

        public var description: String {
            switch self {
            case .nested:
                return "counting session refused: a counting session is already open (sessions do not nest); nothing ran"
            case let .layoutChanged(open, now, tick):
                let head = "counting session refused: the back-edge layout changed inside the session "
                    + "(back edges \(open) → \(now); the count, the destinations or their register flags differ "
                    + "from the session's plan)"
                if let t = tick { return head + "; tick \(t) of the session and every later one ticked nothing" }
                return head + ", found when the session closed; its ticks after the change ran on a stale plan "
                    + "and their counts are refused"
            case let .topologyChanged(tick):
                let head = "frontier session refused: the graph's topology changed inside the session "
                    + "(a slot, rank or back-edge writer dropped the session's reverse index)"
                if let t = tick { return head + "; tick \(t) of the session and every later one ticked nothing" }
                return head + ", found when the session closed"
            }
        }
    }

    /// Run `body` with the counts on (TICK UNTIL_STABLE). Throws, with
    /// nothing run: `CountingSessionRefusal.nested` inside another session's
    /// body; `ChangeCounterUnavailable` if the kernel's counter cannot be
    /// allocated; `ChangeMarksUnavailable` if the marks cannot. Throws
    /// `CountingSessionRefusal.layoutChanged` instead of returning if the
    /// body changed the back-edge layout (see `LatchChangeCounter`).
    ///
    /// `frontier: true` opens a frontier session instead (see
    /// `frontierSession`): the same counts, the same refusals, the ticks
    /// through the frontier.
    public func countingLatchChanges<R>(frontier: Bool = false,
                                        _ body: (LatchChangeCounter) throws -> R) throws -> R {
        // One session at a time — the plan, the counts and
        // the kernel's counter are the session's.
        if latchChangeCounter != nil { throw CountingSessionRefusal.nested }
        guard !changeCounterAllocationFailsForTesting,
              let buf = device.makeBuffer(length: 4, options: .storageModeShared) else {
            throw ChangeCounterUnavailable()
        }
        // The marks come from calloc (zeroed pages,
        // touched only at the destinations), so a failed allocation is a
        // refusal by name, not a trap.
        let markBytes = max(nodeCount, 1)
        guard !changeMarksAllocationFailsForTesting, let raw = calloc(markBytes, 1) else {
            throw ChangeMarksUnavailable(bytes: nodeCount)
        }
        let reg = UnsafePointer(isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: markBytes))
        let c = LatchChangeCounter(nodeCount: nodeCount, kernelCount: buf,
                                   marks: raw.bindMemory(to: UInt8.self, capacity: markBytes),
                                   dsts: backEdgeDsts, isRegister: reg)
        latchChangeCounter = c
        defer { latchChangeCounter = nil }
        if frontier {                                   // a frontier session
            c.frontierRequested = true
            c.frontier = prepareFrontier(counter: c)
        }
        defer { c.frontier = nil }
        let result = try body(c)
        if let r = c.closingRefusal(engine: self) { throw r }
        return result
    }

    public enum EngineError: Error, CustomStringConvertible {
        case noGPU
        case noQueue
        case bufferAllocationFailed
        case libraryNotFound
        case functionNotFound(String)
        /// The state's arrays are not the grid's length.
        case stateGridMismatch(stateNodeCount: Int, gridNodeCount: Int)
        /// A whole-buffer write was handed fewer elements than the buffer holds.
        case shortBuffer(what: String, given: Int, nodeCount: Int)
        /// A ternary refusal, named.
        case ternary(String)
        /// One of the state's ternary lanes is not the grid's length:
        /// the lane, by name, and its length.
        case laneLength(lane: String, length: Int, gridNodeCount: Int)
        /// A non-finite node value or edge weight offered to one of the
        /// engine's direct writers, named in the loaders' words.
        case nonFinite(String)

        public var description: String {
            switch self {
            case .noGPU: return "no Metal device"
            case .noQueue: return "no Metal command queue"
            case .bufferAllocationFailed: return "buffer allocation failed"
            case .libraryNotFound: return "Metal library not found"
            case .functionNotFound(let f): return "Metal function not found: \(f)"
            case let .stateGridMismatch(s, g):
                return "state nodeCount \(s) does not match grid nodeCount \(g)"
            case .ternary(let why):
                return "ternary: \(why)"
            case let .laneLength(lane, length, g):
                return "state lane \(lane) has \(length) element(s); the grid has \(g) nodes"
            case .nonFinite(let why):
                return "non-finite: \(why)"
            case let .shortBuffer(what, given, n):
                return "\(what): \(given) value(s) for a \(n)-node graph — a " +
                       "complete snapshot is required, a short one would leave " +
                       "the tail at its previous values"
            }
        }
    }

    // Inline shader source as fallback when bundle loading fails
    static let metalShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant uint8_t TRUTH_FALSE     = 0;
    constant uint8_t TRUTH_TRUE      = 1;
    constant uint8_t TRUTH_UNDEFINED = 2;

    inline uint8_t eval_lut6(uint32_t lut_low, uint32_t lut_high, uint8_t input_bits) {
        uint idx = uint(input_bits) & 0x3F;
        if (idx < 32) {
            return uint8_t((lut_low >> idx) & 1u);
        } else {
            return uint8_t((lut_high >> (idx - 32)) & 1u);
        }
    }

    // ── Ternary ──
    // The mode lane: bits 0–1 the kind (0 BINARY, 1 TTABLE, 2 TTHRESH), bit 2
    // NOSKIP. A BINARY node takes today's path, untouched, below.
    constant uint8_t KIND_MASK   = 3;
    constant uint8_t KIND_TTABLE = 1;
    constant uint8_t NOSKIP_BIT  = 4;
    constant uint     TABLE_SIZE  = 729;

    // The trit view of any byte — 0 → −1, 1 → +1, 2 and ≥ 3 → 0.
    inline int trit_of(uint8_t b) { return b == 0 ? -1 : (b == 1 ? 1 : 0); }
    // A ternary node stores −1 as 0, 0 as 2, +1 as 1.
    inline uint8_t byte_of(int t) { return t < 0 ? uint8_t(0) : (t > 0 ? uint8_t(1) : uint8_t(2)); }

    // One ternary node's output byte. `src` is the truth array its pass reads
    // (rank mode: the live array; sync mode: truth_in); `prev` its own previous
    // byte (rank: before this evaluation; sync: truth_in). An absent slot
    // (nb < 0 or nb ≥ node_count) reads 0 (TTABLE) / is skipped (TTHRESH).
    inline uint8_t eval_ternary(
        device const uint8_t*   src,
        uint                    node,
        uint8_t                 mode,
        uint8_t                 prev,
        device const int32_t*   neighbors,
        uint                    node_count,
        device const uint16_t*  ttable_id,
        device const uint8_t*   ttables,
        uint                    ttable_count,
        device const float*     thr_lo,
        device const float*     thr_hi,
        device const float*     edge_weights
    ) {
        int computed;
        if ((mode & KIND_MASK) == KIND_TTABLE) {
            // TTABLE: index = Σ 3^d · (t_d + 1).
            uint idx = 0;
            uint p = 1;
            for (int d = 0; d < 6; d++) {
                int32_t nb = neighbors[node * 6 + d];
                int t = 0;
                if (nb >= 0 && uint(nb) < node_count) t = trit_of(src[nb]);
                idx += p * uint(t + 1);
                p *= 3;
            }
            uint tid = uint(ttable_id[node]);
            // tid ≥ the library size is refused on every write and load path;
            // the guard keeps the read inside the buffer if it ever happens.
            computed = tid < ttable_count ? trit_of(ttables[tid * TABLE_SIZE + idx]) : 0;
        } else {
            // TTHRESH: s = Σ w_d · t_d over present slots,
            // slot order 0…5, in float; +1 if s > hi, −1 if s < lo, else 0.
            float s = 0.0f;
            for (int d = 0; d < 6; d++) {
                int32_t nb = neighbors[node * 6 + d];
                if (nb < 0 || uint(nb) >= node_count) continue;
                s = s + edge_weights[node * 6 + d] * float(trit_of(src[nb]));
            }
            computed = s > thr_hi[node] ? 1 : (s < thr_lo[node] ? -1 : 0);
        }
        // NOSKIP: no direct −1 → +1; everything passes through 0.
        if ((mode & NOSKIP_BIT) != 0) {
            int p = trit_of(prev);
            if (p != 0 && computed == -p) computed = 0;
        }
        return byte_of(computed);
    }

    kernel void dagdb_tick_rank(
        device uint8_t*         truth_state  [[ buffer(0) ]],
        device const uint64_t*  rank         [[ buffer(1) ]],
        device const uint32_t*  lut6_low     [[ buffer(2) ]],
        device const uint32_t*  lut6_high    [[ buffer(3) ]],
        device const int32_t*   neighbors    [[ buffer(4) ]],
        device const uint32_t*  group        [[ buffer(5) ]],
        constant uint32_t&      group_size   [[ buffer(6) ]],
        constant uint64_t&      current_rank [[ buffer(7) ]],
        device const uint8_t*   is_register  [[ buffer(8) ]],
        constant uint32_t&      node_count   [[ buffer(9) ]],
        device const uint8_t*   node_mode    [[ buffer(10) ]],
        device const uint16_t*  ttable_id    [[ buffer(11) ]],
        device const float*     thr_lo       [[ buffer(12) ]],
        device const float*     thr_hi       [[ buffer(13) ]],
        device const uint8_t*   ttables      [[ buffer(14) ]],
        constant uint32_t&      ttable_count [[ buffer(15) ]],
        device const float*     edge_weights [[ buffer(16) ]],
        uint                    gid          [[ thread_position_in_grid ]]
    ) {
        if (gid >= group_size) return;
        uint node = group[gid];
        if (node >= node_count) return;
        if (rank[node] != current_rank) return;
        if (is_register[node] != 0) return;

        // Ternary kinds branch here; a BINARY node falls through to
        // today's LUT6 path below, unchanged.
        uint8_t mode = node_mode[node];
        if ((mode & KIND_MASK) != 0) {
            truth_state[node] = eval_ternary(truth_state, node, mode, truth_state[node],
                                             neighbors, node_count, ttable_id, ttables,
                                             ttable_count, thr_lo, thr_hi, edge_weights);
            return;
        }

        uint8_t input_bits = 0;
        for (int d = 0; d < 6; d++) {
            int32_t nb = neighbors[node * 6 + d];
            if (nb < 0 || uint(nb) >= node_count) continue;
            uint8_t nb_truth = truth_state[nb];
            uint8_t bit = (nb_truth == TRUTH_TRUE) ? 1u : 0u;
            input_bits |= (bit << d);
        }

        truth_state[node] = eval_lut6(lut6_low[node], lut6_high[node], input_bits);
    }

    // Binary-only fast path: the binary rank kernel with its original bindings, buffer(0…9).
    kernel void dagdb_tick_rank_binary(
        device uint8_t*         truth_state  [[ buffer(0) ]],
        device const uint64_t*  rank         [[ buffer(1) ]],
        device const uint32_t*  lut6_low     [[ buffer(2) ]],
        device const uint32_t*  lut6_high    [[ buffer(3) ]],
        device const int32_t*   neighbors    [[ buffer(4) ]],
        device const uint32_t*  group        [[ buffer(5) ]],
        constant uint32_t&      group_size   [[ buffer(6) ]],
        constant uint64_t&      current_rank [[ buffer(7) ]],
        device const uint8_t*   is_register  [[ buffer(8) ]],
        constant uint32_t&      node_count   [[ buffer(9) ]],
        uint                    gid          [[ thread_position_in_grid ]]
    ) {
        if (gid >= group_size) return;
        uint node = group[gid];
        if (node >= node_count) return;
        if (rank[node] != current_rank) return;
        if (is_register[node] != 0) return;

        uint8_t input_bits = 0;
        for (int d = 0; d < 6; d++) {
            int32_t nb = neighbors[node * 6 + d];
            if (nb < 0 || uint(nb) >= node_count) continue;
            uint8_t nb_truth = truth_state[nb];
            uint8_t bit = (nb_truth == TRUTH_TRUE) ? 1u : 0u;
            input_bits |= (bit << d);
        }
        truth_state[node] = eval_lut6(lut6_low[node], lut6_high[node], input_bits);
    }

    // ── The counting twins of the two rank kernels ──
    // Dispatched instead of dagdb_tick_rank / dagdb_tick_rank_binary only while
    // a caller counts changes (TICK UNTIL_STABLE); every other tick dispatches
    // the two kernels above, untouched. Same bindings plus buffer(17): one
    // atomic counter, the number of nodes whose byte this pass changed (the new
    // byte differs from the byte the node held when its thread read it). A node
    // is written by one thread once per tick, so that is the pre-tick byte.
    // Same guards, same reads, same byte written as the kernel it twins; the
    // guards are nested instead of early returns so every thread reaches the
    // SIMD-group sum, and one thread per SIMD group adds the group's count.
    kernel void dagdb_tick_rank_counting(
        device uint8_t*         truth_state  [[ buffer(0) ]],
        device const uint64_t*  rank         [[ buffer(1) ]],
        device const uint32_t*  lut6_low     [[ buffer(2) ]],
        device const uint32_t*  lut6_high    [[ buffer(3) ]],
        device const int32_t*   neighbors    [[ buffer(4) ]],
        device const uint32_t*  group        [[ buffer(5) ]],
        constant uint32_t&      group_size   [[ buffer(6) ]],
        constant uint64_t&      current_rank [[ buffer(7) ]],
        device const uint8_t*   is_register  [[ buffer(8) ]],
        constant uint32_t&      node_count   [[ buffer(9) ]],
        device const uint8_t*   node_mode    [[ buffer(10) ]],
        device const uint16_t*  ttable_id    [[ buffer(11) ]],
        device const float*     thr_lo       [[ buffer(12) ]],
        device const float*     thr_hi       [[ buffer(13) ]],
        device const uint8_t*   ttables      [[ buffer(14) ]],
        constant uint32_t&      ttable_count [[ buffer(15) ]],
        device const float*     edge_weights [[ buffer(16) ]],
        device atomic_uint*     changed      [[ buffer(17) ]],
        uint                    gid          [[ thread_position_in_grid ]]
    ) {
        uint did_change = 0;
        if (gid < group_size) {
            uint node = group[gid];
            if (node < node_count && rank[node] == current_rank && is_register[node] == 0) {
                uint8_t old = truth_state[node];
                uint8_t result;
                uint8_t mode = node_mode[node];
                if ((mode & KIND_MASK) != 0) {
                    result = eval_ternary(truth_state, node, mode, old,
                                          neighbors, node_count, ttable_id, ttables,
                                          ttable_count, thr_lo, thr_hi, edge_weights);
                } else {
                    uint8_t input_bits = 0;
                    for (int d = 0; d < 6; d++) {
                        int32_t nb = neighbors[node * 6 + d];
                        if (nb < 0 || uint(nb) >= node_count) continue;
                        uint8_t bit = (truth_state[nb] == TRUTH_TRUE) ? 1u : 0u;
                        input_bits |= (bit << d);
                    }
                    result = eval_lut6(lut6_low[node], lut6_high[node], input_bits);
                }
                truth_state[node] = result;
                did_change = (result != old) ? 1u : 0u;
            }
        }
        uint group_changed = simd_sum(did_change);
        if (simd_is_first() && group_changed != 0) {
            atomic_fetch_add_explicit(changed, group_changed, memory_order_relaxed);
        }
    }

    kernel void dagdb_tick_rank_binary_counting(
        device uint8_t*         truth_state  [[ buffer(0) ]],
        device const uint64_t*  rank         [[ buffer(1) ]],
        device const uint32_t*  lut6_low     [[ buffer(2) ]],
        device const uint32_t*  lut6_high    [[ buffer(3) ]],
        device const int32_t*   neighbors    [[ buffer(4) ]],
        device const uint32_t*  group        [[ buffer(5) ]],
        constant uint32_t&      group_size   [[ buffer(6) ]],
        constant uint64_t&      current_rank [[ buffer(7) ]],
        device const uint8_t*   is_register  [[ buffer(8) ]],
        constant uint32_t&      node_count   [[ buffer(9) ]],
        device atomic_uint*     changed      [[ buffer(17) ]],
        uint                    gid          [[ thread_position_in_grid ]]
    ) {
        uint did_change = 0;
        if (gid < group_size) {
            uint node = group[gid];
            if (node < node_count && rank[node] == current_rank && is_register[node] == 0) {
                uint8_t old = truth_state[node];
                uint8_t input_bits = 0;
                for (int d = 0; d < 6; d++) {
                    int32_t nb = neighbors[node * 6 + d];
                    if (nb < 0 || uint(nb) >= node_count) continue;
                    uint8_t bit = (truth_state[nb] == TRUTH_TRUE) ? 1u : 0u;
                    input_bits |= (bit << d);
                }
                uint8_t result = eval_lut6(lut6_low[node], lut6_high[node], input_bits);
                truth_state[node] = result;
                did_change = (result != old) ? 1u : 0u;
            }
        }
        uint group_changed = simd_sum(did_change);
        if (simd_is_first() && group_changed != 0) {
            atomic_fetch_add_explicit(changed, group_changed, memory_order_relaxed);
        }
    }

    // ── The back-edge latch on the GPU ──
    // The plain latch (DagDBEngine.latchBackEdges) snapshots every back edge's
    // source, then writes every destination, the last back edge into a
    // destination winning. These kernels run over the EFFECTIVE back edges, one
    // per distinct destination (its last back edge, in list order), built on the
    // CPU when the back-edge list changes (DagDBEngine.LatchPlan). Each
    // destination is written by one thread once, so no two writes conflict, and
    // `changed` counts the destinations whose byte the latch changed, each once
    // (the counting latch's count), one add per SIMD group. When no effective
    // source is a destination, no thread reads a byte another writes and one
    // kernel does it (dagdb_latch_direct); otherwise the snapshot and the writes
    // are two dispatches, the plain latch's two phases.
    //
    // dagdb_latch_direct: thread j < stride takes entries j, j + stride, … (the
    // engine dispatches one entry per thread: stride = count).
    kernel void dagdb_latch_direct(
        device uint8_t*         truth_state [[ buffer(0) ]],
        device const uint32_t*  eff_src     [[ buffer(1) ]],
        device const uint32_t*  eff_dst     [[ buffer(2) ]],
        constant uint32_t&      count       [[ buffer(3) ]],
        device atomic_uint*     changed     [[ buffer(4) ]],
        constant uint32_t&      stride      [[ buffer(5) ]],
        uint                    gid         [[ thread_position_in_grid ]]
    ) {
        uint did_change = 0;
        if (gid < stride) {
            for (uint j = gid; j < count; j += stride) {
                uint8_t v = truth_state[eff_src[j]];
                uint d = eff_dst[j];
                uint8_t old = truth_state[d];
                truth_state[d] = v;
                did_change += (v != old) ? 1u : 0u;
            }
        }
        uint group_changed = simd_sum(did_change);
        if (simd_is_first() && group_changed != 0) {
            atomic_fetch_add_explicit(changed, group_changed, memory_order_relaxed);
        }
    }

    // Two phases, first: every effective source's byte, before any write.
    kernel void dagdb_latch_snapshot(
        device const uint8_t*   truth_state [[ buffer(0) ]],
        device const uint32_t*  eff_src     [[ buffer(1) ]],
        device uint8_t*         scratch     [[ buffer(2) ]],
        constant uint32_t&      count       [[ buffer(3) ]],
        uint                    gid         [[ thread_position_in_grid ]]
    ) {
        if (gid >= count) return;
        scratch[gid] = truth_state[eff_src[gid]];
    }

    // Two phases, second: every destination from the snapshot.
    kernel void dagdb_latch_write(
        device uint8_t*         truth_state [[ buffer(0) ]],
        device const uint32_t*  eff_dst     [[ buffer(1) ]],
        device const uint8_t*   scratch     [[ buffer(2) ]],
        constant uint32_t&      count       [[ buffer(3) ]],
        device atomic_uint*     changed     [[ buffer(4) ]],
        uint                    gid         [[ thread_position_in_grid ]]
    ) {
        uint did_change = 0;
        if (gid < count) {
            uint d = eff_dst[gid];
            uint8_t v = scratch[gid];
            uint8_t old = truth_state[d];
            truth_state[d] = v;
            did_change = (v != old) ? 1u : 0u;
        }
        uint group_changed = simd_sum(did_change);
        if (simd_is_first() && group_changed != 0) {
            atomic_fetch_add_explicit(changed, group_changed, memory_order_relaxed);
        }
    }

    // ── SET_LUTS … FILL | MAP by selection (DagDBEngine+SetLuts.swift) ──
    // One thread per node of the dispatch: the id range (P[0] = 0: node P[3] +
    // gid), a rank's per-rank list (1: list[gid], the buffer bound at the rank's span),
    // or the rank lane (2: node gid, selected when P[4] <= rank <= P[5]). FILL
    // (P[1] = 0) writes P[6]; MAP (1) reads the node's LUT once, ANDs it with the
    // mask P[7] and writes the value P[25 + j] of the one key P[9 + j] (j < P[8])
    // it equals — the value before the verb, so no pair's `to` is ever matched
    // again (no chaining). Every node is written by one thread. counts[0] gets the
    // nodes in the selection, counts[1] the nodes written, one add per SIMD group.
    kernel void dagdb_set_luts(
        device uint32_t*        lut6_low    [[ buffer(0) ]],
        device uint32_t*        lut6_high   [[ buffer(1) ]],
        device const uint64_t*  rank        [[ buffer(2) ]],
        device const uint32_t*  list        [[ buffer(3) ]],
        constant uint64_t*      P           [[ buffer(4) ]],
        device atomic_uint*     counts      [[ buffer(5) ]],
        uint                    gid         [[ thread_position_in_grid ]]
    ) {
        uint sel = 0, wrote = 0;
        if (gid < uint(P[2])) {
            uint mode = uint(P[0]);
            uint i = gid;
            if (mode == 0u) { i = uint(P[3]) + gid; sel = 1u; }
            else if (mode == 1u) { i = list[gid]; sel = 1u; }
            else { uint64_t r = rank[gid]; sel = (r >= P[4] && r <= P[5]) ? 1u : 0u; }
            if (sel != 0u) {
                uint64_t old = (uint64_t(lut6_high[i]) << 32) | uint64_t(lut6_low[i]);
                uint64_t v = old;
                if (P[1] == 0) {
                    v = P[6]; wrote = 1u;
                } else {
                    uint64_t key = old & P[7];
                    uint np = uint(P[8]);
                    for (uint j = 0; j < np; ++j) {
                        if (key == P[9 + j]) { v = P[25 + j]; wrote = 1u; break; }
                    }
                }
                if (wrote != 0u) {
                    lut6_low[i] = uint32_t(v);
                    lut6_high[i] = uint32_t(v >> 32);
                }
            }
        }
        uint s = simd_sum(sel), w = simd_sum(wrote);
        if (simd_is_first()) {
            if (s != 0u) atomic_fetch_add_explicit(&counts[0], s, memory_order_relaxed);
            if (w != 0u) atomic_fetch_add_explicit(&counts[1], w, memory_order_relaxed);
        }
    }

    // ── The frontier session ──
    // Inside a frontier session (DagDBEngine.frontierSession, TICK UNTIL_STABLE)
    // a rank-mode tick evaluates only the nodes that can change. The first tick
    // of a session dispatches every rank and the latch whole (a plain tick that
    // also records what it changed); every later tick dispatches, per rank, the
    // nodes on that rank's worklist: readers (through a slot) of a node whose
    // byte changed this tick at a higher rank, readers of a register the
    // previous latch changed, NOSKIP nodes that changed in the previous tick, and
    // the kernel-evaluated back-edge destinations (every tick). The latch writes
    // only the effective back edges whose source changed since the previous
    // latch's snapshot (and the evaluated destinations', every tick). A rank or
    // a latch whose list holds more than its threshold is dispatched whole (the
    // per-rank list, or every effective back edge). Every dispatched node is
    // evaluated exactly as the counting kernels evaluate it (same guards, same
    // reads, same byte), and its change is counted the same way.
    //
    // The push. A node whose byte changed appends each reader (the reverse
    // index: CSR offsets per source, entries = reader node ids, or effective
    // back-edge indices with bit 31 set) to that reader's rank list, once: a
    // bit per node (per back edge) in this tick's bitmap, set by atomic OR; the
    // thread that sets it takes a slot by an atomic add on the rank's count.
    // Each rank's list lives at its per-rank span offset (a rank holds at most its
    // span count of distinct nodes). Lists, bitmaps and counts come in two
    // halves: `cur` is this tick's, 1 - cur the next tick's (NOSKIP self-dirty,
    // readers of registers the latch changed, back edges fed by them). Every
    // listed node is dispatched in this tick and clears its own bit; the args
    // kernel zeroes a rank's count as it reads it — so at the end of a tick this
    // tick's half is empty and becomes the next tick's next half.
    //
    // The session's
    // first tick is whole (every args kernel takes the per-rank list), so nothing
    // reads its half: there (p.push = 0) the rank and seed kernels push
    // nothing into it. The pushes into the next half — a changed NOSKIP node,
    // the readers of a register the latch changed and the back edges it feeds
    // — are made on every tick, the first included, so tick 1's lists are
    // what they were. The first tick's half stays as the session's open left
    // it: every bit clear, every count zero.
    //
    // rinfo (per session, read-only), L = rank levels: [r] span offset,
    //   [L + r] span count, [2L + r] whole threshold (whole iff listed > it),
    //   [3L] the latch's whole threshold.
    // cnt (atomic): [h·L + r] rank r's list length in half h; [2L + h] the
    //   latch list's length in half h; [2L + 2] rank entries dispatched this
    //   tick; [2L + 3] latch entries dispatched this tick.
    // meta (written by the args kernels): [2r] whole, [2r + 1] entries for rank
    //   r; [2L] / [2L + 1] the latch's; [2L + 2 + 3r …] rank r's indirect
    //   threadgroups; [5L + 2 …] the latch's.
    struct FrontierParams {
        uint rank;        // the rank this dispatch is for
        uint levels;      // rank levels the tick covers; ranks >= levels are never evaluated
        uint cur;         // this tick's half (0 or 1)
        uint full;        // 1 on the session's first tick: every rank and the latch whole
        uint tpg;         // threads per threadgroup of the dispatch an args kernel writes
        uint words;       // node bitmap words per half
        uint nodes;       // node list entries per half (the node count)
        uint edges;       // effective back edges (latch list entries per half)
        uint edge_words;  // latch bitmap words per half
        uint count;       // seed kernel: evaluated destinations
        uint push;        // 1 = a changed node pushes its readers into this tick's half;
                          //   0 on the session's first, whole tick, whose half nothing reads
    };

    inline void f2_push_node(uint u, uint hf, constant FrontierParams& p,
                             device const uint64_t* rank, device atomic_uint* bits,
                             device atomic_uint* cnt, device const uint* rinfo, device uint* lists) {
        uint64_t r = rank[u];
        if (r >= uint64_t(p.levels)) return;      // outside every rank list: never evaluated
        uint mask = 1u << (u & 31u);
        uint old = atomic_fetch_or_explicit(&bits[hf * p.words + (u >> 5)], mask, memory_order_relaxed);
        if ((old & mask) != 0) return;            // already listed
        uint ri = uint(r);
        uint pos = atomic_fetch_add_explicit(&cnt[hf * p.levels + ri], 1u, memory_order_relaxed);
        lists[hf * p.nodes + rinfo[ri] + pos] = u;
    }

    inline void f2_push_edge(uint e, uint hf, constant FrontierParams& p,
                             device atomic_uint* latch_bits, device atomic_uint* cnt, device uint* latch_list) {
        uint mask = 1u << (e & 31u);
        uint old = atomic_fetch_or_explicit(&latch_bits[hf * p.edge_words + (e >> 5)], mask, memory_order_relaxed);
        if ((old & mask) != 0) return;
        uint pos = atomic_fetch_add_explicit(&cnt[2u * p.levels + hf], 1u, memory_order_relaxed);
        latch_list[hf * p.edges + pos] = e;
    }

    // Every reader of `v` through a slot, and every effective back edge `v` feeds.
    inline void f2_push_readers(uint v, uint hf, constant FrontierParams& p,
                                device const uint64_t* rank, device atomic_uint* bits,
                                device atomic_uint* cnt, device const uint* rinfo, device uint* lists,
                                device const uint* csr_off, device const uint* csr_ent,
                                device atomic_uint* latch_bits, device uint* latch_list) {
        uint a = csr_off[v], b = csr_off[v + 1];
        for (uint k = a; k < b; k++) {
            uint x = csr_ent[k];
            if ((x & 0x80000000u) != 0) {
                f2_push_edge(x & 0x7FFFFFFFu, hf, p, latch_bits, cnt, latch_list);
            } else {
                f2_push_node(x, hf, p, rank, bits, cnt, rinfo, lists);
            }
        }
    }

    // The push of one
    // SIMD group, together. Lane i brings the CSR range [a_i, a_i + k_i) of the
    // node whose readers it pushes (k_i = 0: none). The group's T = sum of k_i
    // entries are walked 32 at a time, entry t by lane t mod 32 (its owner found
    // by a binary search over the lanes' inclusive prefix sums), so a node's k
    // readers are pushed by k lanes at once, not by one lane in k serial steps.
    // Each entry is deduplicated by its half's bitmap exactly as f2_push_node and
    // f2_push_edge do (one atomic OR); the entries new in a round then take
    // their list slots with ONE atomic add per receiving list (rank r's, or the
    // latch list's), each lane its slot by a prefix sum over the lanes with the
    // same list. Every lane of the SIMD group calls it (uniform control flow:
    // the frontier's threadgroups are whole SIMD groups of 32, checked when the
    // pipelines are made).
    constant uint H2_NONE = 0xFFFFFFFFu;
    inline void h2_push_group(uint a, uint k, uint hf, ushort lane, constant FrontierParams& p,
                              device const uint64_t* rank, device atomic_uint* bits,
                              device atomic_uint* cnt, device const uint* rinfo, device uint* lists,
                              device const uint* csr_ent, device atomic_uint* latch_bits, device uint* latch_list) {
        uint incl = simd_prefix_inclusive_sum(k);
        uint total = simd_sum(k);
        uint excl = incl - k;
        for (uint t0 = 0u; t0 < total; t0 += 32u) {
            uint t = t0 + uint(lane);
            // The owner of entry t: the number of lanes whose inclusive sum is <= t (< 32 when t < total).
            uint j = 0u;
            for (uint s = 16u; s > 0u; s >>= 1u) {
                uint c = simd_shuffle(incl, ushort(j + s - 1u));
                j = (c <= t) ? j + s : j;
            }
            uint aj = simd_shuffle(a, ushort(j));
            uint ej = simd_shuffle(excl, ushort(j));
            uint tgt = H2_NONE, val = 0u;
            if (t < total) {
                uint x = csr_ent[aj + (t - ej)];
                if ((x & 0x80000000u) != 0u) {
                    uint e = x & 0x7FFFFFFFu;
                    uint mask = 1u << (e & 31u);
                    uint old = atomic_fetch_or_explicit(&latch_bits[hf * p.edge_words + (e >> 5)], mask,
                                                        memory_order_relaxed);
                    if ((old & mask) == 0u) { tgt = p.levels; val = e; }
                } else if (rank[x] < uint64_t(p.levels)) {      // outside every rank list: never evaluated
                    uint mask = 1u << (x & 31u);
                    uint old = atomic_fetch_or_explicit(&bits[hf * p.words + (x >> 5)], mask, memory_order_relaxed);
                    if ((old & mask) == 0u) { tgt = uint(rank[x]); val = x; }
                }
            }
            // This round's new entries take their slots: one atomic add per receiving list.
            for (;;) {
                uint T = simd_min(tgt);
                if (T == H2_NONE) break;
                bool mine = tgt == T;
                uint before = simd_prefix_exclusive_sum(mine ? 1u : 0u);
                uint m = simd_sum(mine ? 1u : 0u);
                uint base = 0u;
                if (mine && before == 0u) {
                    device atomic_uint* c = T == p.levels ? &cnt[2u * p.levels + hf] : &cnt[hf * p.levels + T];
                    base = atomic_fetch_add_explicit(c, m, memory_order_relaxed);
                }
                base = simd_sum(base);                          // the first lane's; every other lane adds 0
                if (mine) {
                    uint pos = base + before;
                    if (T == p.levels) latch_list[hf * p.edges + pos] = val;
                    else lists[hf * p.nodes + rinfo[T] + pos] = val;
                    tgt = H2_NONE;
                }
            }
        }
    }

    // Clear one entry's bit in this tick's bitmap. A listed entry's bit is set;
    // in a whole dispatch only the entries that were listed have theirs set.
    inline void f2_clear_bit(uint i, uint whole, device atomic_uint* w) {
        uint mask = 1u << (i & 31u);
        if (whole == 0 || (atomic_load_explicit(w, memory_order_relaxed) & mask) != 0) {
            atomic_fetch_and_explicit(w, ~mask, memory_order_relaxed);
        }
    }

    // The kernel-evaluated back-edge destinations (register flag cleared), every
    // tick: each is listed for its rank, its readers and the back edges it feeds
    // are listed, and its own effective back edge is listed for the latch.
    // `seeds`: (destination, its effective back edge) pairs.
    kernel void dagdb_frontier_seed(
        device const uint64_t*  rank        [[ buffer(1) ]],
        constant FrontierParams& p          [[ buffer(7) ]],
        device uint*            lists       [[ buffer(8) ]],
        device atomic_uint*     bits        [[ buffer(9) ]],
        device atomic_uint*     cnt         [[ buffer(10) ]],
        device const uint*      rinfo       [[ buffer(11) ]],
        device const uint*      csr_off     [[ buffer(13) ]],
        device const uint*      csr_ent     [[ buffer(14) ]],
        device uint*            latch_list  [[ buffer(16) ]],
        device atomic_uint*     latch_bits  [[ buffer(17) ]],
        device const uint*      seeds       [[ buffer(19) ]],
        uint                    gid         [[ thread_position_in_grid ]],
        ushort                  lane        [[ thread_index_in_simdgroup ]]      // for the SIMD-group push
    ) {
        if (p.push == 0u) return;   // the whole first tick reads no list (uniform: every lane returns)
        uint pa = 0u, pk = 0u;      // the readers this lane brings to the group's push
        if (gid < p.count) {
            uint d = seeds[2u * gid], e = seeds[2u * gid + 1u];
            f2_push_node(d, p.cur, p, rank, bits, cnt, rinfo, lists);
            pa = csr_off[d]; pk = csr_off[d + 1u] - pa;
            f2_push_edge(e, p.cur, p, latch_bits, cnt, latch_list);
        }
        h2_push_group(pa, pk, p.cur, lane, p, rank, bits, cnt, rinfo, lists, csr_ent, latch_bits, latch_list);
    }

    // One thread, before rank p.rank's dispatch: that rank's list is final (only
    // higher ranks push into it). Whole or listed, the entry count, the indirect
    // threadgroups; the count is zeroed for the half's next use.
    kernel void dagdb_frontier_rank_args(
        constant FrontierParams& p          [[ buffer(7) ]],
        device atomic_uint*     cnt         [[ buffer(10) ]],
        device const uint*      rinfo       [[ buffer(11) ]],
        device uint*            meta        [[ buffer(12) ]],
        uint                    gid         [[ thread_position_in_grid ]]
    ) {
        if (gid != 0) return;
        uint L = p.levels, r = p.rank;
        device atomic_uint* c = &cnt[p.cur * L + r];
        uint n = atomic_load_explicit(c, memory_order_relaxed);
        atomic_store_explicit(c, 0u, memory_order_relaxed);
        uint whole = (p.full != 0 || n > rinfo[2u * L + r]) ? 1u : 0u;
        uint m = whole != 0 ? rinfo[L + r] : n;
        meta[2u * r] = whole;
        meta[2u * r + 1u] = m;
        uint a = 2u * L + 2u + 3u * r;
        meta[a] = (m + p.tpg - 1u) / p.tpg;
        meta[a + 1u] = 1u;
        meta[a + 2u] = 1u;
        atomic_fetch_add_explicit(&cnt[2u * L + 2u], m, memory_order_relaxed);
    }

    // The same for the latch, after the last rank.
    kernel void dagdb_frontier_latch_args(
        constant FrontierParams& p          [[ buffer(7) ]],
        device atomic_uint*     cnt         [[ buffer(10) ]],
        device const uint*      rinfo       [[ buffer(11) ]],
        device uint*            meta        [[ buffer(12) ]],
        uint                    gid         [[ thread_position_in_grid ]]
    ) {
        if (gid != 0) return;
        uint L = p.levels;
        device atomic_uint* c = &cnt[2u * L + p.cur];
        uint n = atomic_load_explicit(c, memory_order_relaxed);
        atomic_store_explicit(c, 0u, memory_order_relaxed);
        uint whole = (p.full != 0 || n > rinfo[3u * L]) ? 1u : 0u;
        uint m = whole != 0 ? p.edges : n;
        meta[2u * L] = whole;
        meta[2u * L + 1u] = m;
        uint a = 5u * L + 2u;
        meta[a] = (m + p.tpg - 1u) / p.tpg;
        meta[a + 1u] = 1u;
        meta[a + 2u] = 1u;
        atomic_fetch_add_explicit(&cnt[2u * L + 3u], m, memory_order_relaxed);
    }

    // Rank p.rank, the general kernel: the counting kernel's evaluation over the
    // rank's list (or its per-rank list, whole), pushing the readers of every node
    // whose byte changed, and a NOSKIP node that changed into the next tick.
    kernel void dagdb_frontier_rank(
        device uint8_t*         truth_state  [[ buffer(0) ]],
        device const uint64_t*  rank         [[ buffer(1) ]],
        device const uint32_t*  lut6_low     [[ buffer(2) ]],
        device const uint32_t*  lut6_high    [[ buffer(3) ]],
        device const int32_t*   neighbors    [[ buffer(4) ]],
        device const uint8_t*   is_register  [[ buffer(5) ]],
        constant uint32_t&      node_count   [[ buffer(6) ]],
        constant FrontierParams& p           [[ buffer(7) ]],
        device uint*            lists        [[ buffer(8) ]],
        device atomic_uint*     bits         [[ buffer(9) ]],
        device atomic_uint*     cnt          [[ buffer(10) ]],
        device const uint*      rinfo        [[ buffer(11) ]],
        device const uint*      meta         [[ buffer(12) ]],
        device const uint*      csr_off      [[ buffer(13) ]],
        device const uint*      csr_ent      [[ buffer(14) ]],
        device const uint*      rank_list    [[ buffer(15) ]],
        device uint*            latch_list   [[ buffer(16) ]],
        device atomic_uint*     latch_bits   [[ buffer(17) ]],
        device atomic_uint*     changed      [[ buffer(18) ]],
        device const uint8_t*   node_mode    [[ buffer(19) ]],
        device const uint16_t*  ttable_id    [[ buffer(20) ]],
        device const float*     thr_lo       [[ buffer(21) ]],
        device const float*     thr_hi       [[ buffer(22) ]],
        device const uint8_t*   ttables      [[ buffer(23) ]],
        constant uint32_t&      ttable_count [[ buffer(24) ]],
        device const float*     edge_weights [[ buffer(25) ]],
        uint                    gid          [[ thread_position_in_grid ]],
        ushort                  lane         [[ thread_index_in_simdgroup ]]     // for the SIMD-group push
    ) {
        uint r = p.rank;
        uint whole = meta[2u * r], n = meta[2u * r + 1u];
        uint did_change = 0;
        uint pa = 0u, pk = 0u;      // the CSR range of readers this lane brings to the group's push
        if (gid < n) {
            uint off = rinfo[r];
            uint node = whole != 0 ? rank_list[off + gid] : lists[p.cur * p.nodes + off + gid];
            f2_clear_bit(node, whole, &bits[p.cur * p.words + (node >> 5)]);
            if (node < node_count && rank[node] == uint64_t(r) && is_register[node] == 0) {
                uint8_t old = truth_state[node];
                uint8_t result;
                uint8_t mode = node_mode[node];
                if ((mode & KIND_MASK) != 0) {
                    result = eval_ternary(truth_state, node, mode, old,
                                          neighbors, node_count, ttable_id, ttables,
                                          ttable_count, thr_lo, thr_hi, edge_weights);
                } else {
                    uint8_t input_bits = 0;
                    for (int d = 0; d < 6; d++) {
                        int32_t nb = neighbors[node * 6 + d];
                        if (nb < 0 || uint(nb) >= node_count) continue;
                        uint8_t bit = (truth_state[nb] == TRUTH_TRUE) ? 1u : 0u;
                        input_bits |= (bit << d);
                    }
                    result = eval_lut6(lut6_low[node], lut6_high[node], input_bits);
                }
                truth_state[node] = result;
                if (result != old) {
                    did_change = 1u;
                    // Not on the session's first, whole tick (p.push = 0), whose half nothing reads.
                    // Its readers are pushed by the SIMD group together, below.
                    if (p.push != 0u) { pa = csr_off[node]; pk = csr_off[node + 1u] - pa; }
                    // NOSKIP reads its own previous byte: it changed, so its next evaluation may differ.
                    if ((mode & NOSKIP_BIT) != 0) {
                        f2_push_node(node, 1u - p.cur, p, rank, bits, cnt, rinfo, lists);
                    }
                }
            }
        }
        h2_push_group(pa, pk, p.cur, lane, p, rank, bits, cnt, rinfo, lists, csr_ent, latch_bits, latch_list);   // the SIMD group's push
        uint group_changed = simd_sum(did_change);
        if (simd_is_first() && group_changed != 0) {
            atomic_fetch_add_explicit(changed, group_changed, memory_order_relaxed);
        }
    }

    // Rank p.rank, the binary-only kernel (no mode lane, no NOSKIP).
    kernel void dagdb_frontier_rank_binary(
        device uint8_t*         truth_state  [[ buffer(0) ]],
        device const uint64_t*  rank         [[ buffer(1) ]],
        device const uint32_t*  lut6_low     [[ buffer(2) ]],
        device const uint32_t*  lut6_high    [[ buffer(3) ]],
        device const int32_t*   neighbors    [[ buffer(4) ]],
        device const uint8_t*   is_register  [[ buffer(5) ]],
        constant uint32_t&      node_count   [[ buffer(6) ]],
        constant FrontierParams& p           [[ buffer(7) ]],
        device uint*            lists        [[ buffer(8) ]],
        device atomic_uint*     bits         [[ buffer(9) ]],
        device atomic_uint*     cnt          [[ buffer(10) ]],
        device const uint*      rinfo        [[ buffer(11) ]],
        device const uint*      meta         [[ buffer(12) ]],
        device const uint*      csr_off      [[ buffer(13) ]],
        device const uint*      csr_ent      [[ buffer(14) ]],
        device const uint*      rank_list    [[ buffer(15) ]],
        device uint*            latch_list   [[ buffer(16) ]],
        device atomic_uint*     latch_bits   [[ buffer(17) ]],
        device atomic_uint*     changed      [[ buffer(18) ]],
        uint                    gid          [[ thread_position_in_grid ]],
        ushort                  lane         [[ thread_index_in_simdgroup ]]     // for the SIMD-group push
    ) {
        uint r = p.rank;
        uint whole = meta[2u * r], n = meta[2u * r + 1u];
        uint did_change = 0;
        uint pa = 0u, pk = 0u;      // the CSR range of readers this lane brings to the group's push
        if (gid < n) {
            uint off = rinfo[r];
            uint node = whole != 0 ? rank_list[off + gid] : lists[p.cur * p.nodes + off + gid];
            f2_clear_bit(node, whole, &bits[p.cur * p.words + (node >> 5)]);
            if (node < node_count && rank[node] == uint64_t(r) && is_register[node] == 0) {
                uint8_t old = truth_state[node];
                uint8_t input_bits = 0;
                for (int d = 0; d < 6; d++) {
                    int32_t nb = neighbors[node * 6 + d];
                    if (nb < 0 || uint(nb) >= node_count) continue;
                    uint8_t bit = (truth_state[nb] == TRUTH_TRUE) ? 1u : 0u;
                    input_bits |= (bit << d);
                }
                uint8_t result = eval_lut6(lut6_low[node], lut6_high[node], input_bits);
                truth_state[node] = result;
                if (result != old) {
                    did_change = 1u;
                    // Not on the session's first, whole tick (p.push = 0), whose half nothing reads.
                    // Its readers are pushed by the SIMD group together, below.
                    if (p.push != 0u) { pa = csr_off[node]; pk = csr_off[node + 1u] - pa; }
                }
            }
        }
        h2_push_group(pa, pk, p.cur, lane, p, rank, bits, cnt, rinfo, lists, csr_ent, latch_bits, latch_list);   // the SIMD group's push
        uint group_changed = simd_sum(did_change);
        if (simd_is_first() && group_changed != 0) {
            atomic_fetch_add_explicit(changed, group_changed, memory_order_relaxed);
        }
    }

    // The latch over the listed effective back edges (all of them, whole), one
    // kernel when no effective source is a destination. A destination whose
    // byte changed lists its readers for the next tick.
    kernel void dagdb_frontier_latch_direct(
        device uint8_t*         truth_state  [[ buffer(0) ]],
        device const uint64_t*  rank         [[ buffer(1) ]],
        constant FrontierParams& p           [[ buffer(7) ]],
        device uint*            lists        [[ buffer(8) ]],
        device atomic_uint*     bits         [[ buffer(9) ]],
        device atomic_uint*     cnt          [[ buffer(10) ]],
        device const uint*      rinfo        [[ buffer(11) ]],
        device const uint*      meta         [[ buffer(12) ]],
        device const uint*      csr_off      [[ buffer(13) ]],
        device const uint*      csr_ent      [[ buffer(14) ]],
        device uint*            latch_list   [[ buffer(16) ]],
        device atomic_uint*     latch_bits   [[ buffer(17) ]],
        device atomic_uint*     changed      [[ buffer(18) ]],
        device const uint32_t*  eff_src      [[ buffer(26) ]],
        device const uint32_t*  eff_dst      [[ buffer(27) ]],
        uint                    gid          [[ thread_position_in_grid ]],
        ushort                  lane         [[ thread_index_in_simdgroup ]]     // for the SIMD-group push
    ) {
        uint L = p.levels;
        uint whole = meta[2u * L], n = meta[2u * L + 1u];
        uint did_change = 0;
        uint pa = 0u, pk = 0u;      // the CSR range of readers this lane brings to the group's push
        if (gid < n) {
            uint e = whole != 0 ? gid : latch_list[p.cur * p.edges + gid];
            f2_clear_bit(e, whole, &latch_bits[p.cur * p.edge_words + (e >> 5)]);
            uint8_t v = truth_state[eff_src[e]];
            uint d = eff_dst[e];
            uint8_t old = truth_state[d];
            truth_state[d] = v;
            if (v != old) {
                did_change = 1u;
                pa = csr_off[d]; pk = csr_off[d + 1u] - pa;   // pushed by the SIMD group, below
            }
        }
        h2_push_group(pa, pk, 1u - p.cur, lane, p, rank, bits, cnt, rinfo, lists, csr_ent, latch_bits, latch_list);   // the SIMD group's push
        uint group_changed = simd_sum(did_change);
        if (simd_is_first() && group_changed != 0) {
            atomic_fetch_add_explicit(changed, group_changed, memory_order_relaxed);
        }
    }

    // Two phases, first: every listed effective source's byte, before any write.
    kernel void dagdb_frontier_latch_snapshot(
        device const uint8_t*   truth_state  [[ buffer(0) ]],
        constant FrontierParams& p           [[ buffer(7) ]],
        device const uint*      meta         [[ buffer(12) ]],
        device const uint*      latch_list   [[ buffer(16) ]],
        device const uint32_t*  eff_src      [[ buffer(26) ]],
        device uint8_t*         scratch      [[ buffer(28) ]],
        uint                    gid          [[ thread_position_in_grid ]]
    ) {
        uint L = p.levels;
        uint whole = meta[2u * L], n = meta[2u * L + 1u];
        if (gid >= n) return;
        uint e = whole != 0 ? gid : latch_list[p.cur * p.edges + gid];
        scratch[gid] = truth_state[eff_src[e]];
    }

    // Two phases, second: every listed destination from the snapshot; a changed
    // destination lists its readers and the back edges it feeds for the next tick.
    kernel void dagdb_frontier_latch_write(
        device uint8_t*         truth_state  [[ buffer(0) ]],
        device const uint64_t*  rank         [[ buffer(1) ]],
        constant FrontierParams& p           [[ buffer(7) ]],
        device uint*            lists        [[ buffer(8) ]],
        device atomic_uint*     bits         [[ buffer(9) ]],
        device atomic_uint*     cnt          [[ buffer(10) ]],
        device const uint*      rinfo        [[ buffer(11) ]],
        device const uint*      meta         [[ buffer(12) ]],
        device const uint*      csr_off      [[ buffer(13) ]],
        device const uint*      csr_ent      [[ buffer(14) ]],
        device uint*            latch_list   [[ buffer(16) ]],
        device atomic_uint*     latch_bits   [[ buffer(17) ]],
        device atomic_uint*     changed      [[ buffer(18) ]],
        device const uint32_t*  eff_dst      [[ buffer(27) ]],
        device const uint8_t*   scratch      [[ buffer(28) ]],
        uint                    gid          [[ thread_position_in_grid ]],
        ushort                  lane         [[ thread_index_in_simdgroup ]]     // for the SIMD-group push
    ) {
        uint L = p.levels;
        uint whole = meta[2u * L], n = meta[2u * L + 1u];
        uint did_change = 0;
        uint pa = 0u, pk = 0u;      // the CSR range of readers this lane brings to the group's push
        if (gid < n) {
            uint e = whole != 0 ? gid : latch_list[p.cur * p.edges + gid];
            f2_clear_bit(e, whole, &latch_bits[p.cur * p.edge_words + (e >> 5)]);
            uint d = eff_dst[e];
            uint8_t v = scratch[gid];
            uint8_t old = truth_state[d];
            truth_state[d] = v;
            if (v != old) {
                did_change = 1u;
                pa = csr_off[d]; pk = csr_off[d + 1u] - pa;   // pushed by the SIMD group, below
            }
        }
        h2_push_group(pa, pk, 1u - p.cur, lane, p, rank, bits, cnt, rinfo, lists, csr_ent, latch_bits, latch_list);   // the SIMD group's push
        uint group_changed = simd_sum(did_change);
        if (simd_is_first() && group_changed != 0) {
            atomic_fetch_add_explicit(changed, group_changed, memory_order_relaxed);
        }
    }

    kernel void dagdb_reset_rank(
        device uint8_t*         truth_state  [[ buffer(0) ]],
        device const uint64_t*  rank         [[ buffer(1) ]],
        constant uint64_t&      current_rank [[ buffer(2) ]],
        constant uint32_t&      node_count   [[ buffer(3) ]],
        uint                    gid          [[ thread_position_in_grid ]]
    ) {
        if (gid >= node_count) return;
        if (rank[gid] == current_rank) {
            truth_state[gid] = TRUTH_FALSE;
        }
    }

    kernel void dagdb_tick_weighted(
        device uint8_t*         truth_state  [[ buffer(0) ]],
        device const uint64_t*  rank         [[ buffer(1) ]],
        device const float*     edge_weights [[ buffer(2) ]],
        device const int32_t*   neighbors    [[ buffer(3) ]],
        device const uint32_t*  group        [[ buffer(4) ]],
        constant uint32_t&      group_size   [[ buffer(5) ]],
        constant uint64_t&      current_rank [[ buffer(6) ]],
        constant float&         threshold    [[ buffer(7) ]],
        device const uint8_t*   is_register  [[ buffer(8) ]],
        uint                    gid          [[ thread_position_in_grid ]]
    ) {
        if (gid >= group_size) return;
        uint node = group[gid];
        if (rank[node] != current_rank) return;
        if (is_register[node] != 0) return;
        float sum = 0.0;
        for (int d = 0; d < 6; d++) {
            int32_t nb = neighbors[node * 6 + d];
            if (nb < 0) continue;
            float w = edge_weights[node * 6 + d];
            float val = (truth_state[nb] == 1) ? 1.0 : (truth_state[nb] == 2) ? 0.5 : 0.0;
            sum += val * w;
        }
        truth_state[node] = (sum >= threshold) ? 1 : 0;
    }

    kernel void dagdb_tick_sync(
        device const uint8_t*   truth_in     [[ buffer(0) ]],
        device uint8_t*         truth_out    [[ buffer(1) ]],
        device const uint32_t*  lut6_low     [[ buffer(2) ]],
        device const uint32_t*  lut6_high    [[ buffer(3) ]],
        device const int32_t*   neighbors    [[ buffer(4) ]],
        device const uint8_t*   is_register  [[ buffer(5) ]],
        constant uint32_t&      node_count   [[ buffer(6) ]],
        device const uint8_t*   node_mode    [[ buffer(7) ]],
        device const uint16_t*  ttable_id    [[ buffer(8) ]],
        device const float*     thr_lo       [[ buffer(9) ]],
        device const float*     thr_hi       [[ buffer(10) ]],
        device const uint8_t*   ttables      [[ buffer(11) ]],
        constant uint32_t&      ttable_count [[ buffer(12) ]],
        device const float*     edge_weights [[ buffer(13) ]],
        uint                    gid          [[ thread_position_in_grid ]]
    ) {
        if (gid >= node_count) return;
        // Registers hold: their next value comes from the latch phase,
        // exactly as in rank mode.
        if (is_register[gid] != 0) { truth_out[gid] = truth_in[gid]; return; }
        uint8_t mode = node_mode[gid];
        if ((mode & KIND_MASK) != 0) {
            truth_out[gid] = eval_ternary(truth_in, gid, mode, truth_in[gid],
                                          neighbors, node_count, ttable_id, ttables,
                                          ttable_count, thr_lo, thr_hi, edge_weights);
            return;
        }
        uint8_t input_bits = 0;
        for (int d = 0; d < 6; d++) {
            int32_t nb = neighbors[gid * 6 + d];
            if (nb < 0 || uint(nb) >= node_count) continue;
            uint8_t bit = (truth_in[nb] == TRUTH_TRUE) ? 1u : 0u;
            input_bits |= (bit << d);
        }
        truth_out[gid] = eval_lut6(lut6_low[gid], lut6_high[gid], input_bits);
    }

    // Binary-only fast path, sync mode: the binary sync kernel with its original
    // bindings, buffer(0…6), with the general kernel's `nb ≥ node_count` bound.
    kernel void dagdb_tick_sync_binary(
        device const uint8_t*   truth_in     [[ buffer(0) ]],
        device uint8_t*         truth_out    [[ buffer(1) ]],
        device const uint32_t*  lut6_low     [[ buffer(2) ]],
        device const uint32_t*  lut6_high    [[ buffer(3) ]],
        device const int32_t*   neighbors    [[ buffer(4) ]],
        device const uint8_t*   is_register  [[ buffer(5) ]],
        constant uint32_t&      node_count   [[ buffer(6) ]],
        uint                    gid          [[ thread_position_in_grid ]]
    ) {
        if (gid >= node_count) return;
        if (is_register[gid] != 0) { truth_out[gid] = truth_in[gid]; return; }
        uint8_t input_bits = 0;
        for (int d = 0; d < 6; d++) {
            int32_t nb = neighbors[gid * 6 + d];
            if (nb < 0 || uint(nb) >= node_count) continue;
            uint8_t bit = (truth_in[nb] == TRUTH_TRUE) ? 1u : 0u;
            input_bits |= (bit << d);
        }
        truth_out[gid] = eval_lut6(lut6_low[gid], lut6_high[gid], input_bits);
    }
    """
}
