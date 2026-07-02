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
    public let truthStateBuf: MTLBuffer     // UInt8 per node
    public let rankBuf: MTLBuffer           // UInt64 per node (u8 → u32 T1; u32 → u64 T1b)
    public let lut6LowBuf: MTLBuffer        // UInt32 per node
    public let lut6HighBuf: MTLBuffer       // UInt32 per node
    public let activationBuf: MTLBuffer     // Int16 per node
    public let edgeWeightsBuf: MTLBuffer    // Float per (node * 6 + dir)
    public let nodeTypeBuf: MTLBuffer       // UInt8 per node

    // Graph structure (from HexGrid)
    public let neighborsBuf: MTLBuffer      // Int32 per (node * 6 + dir)
    public let colorGroupBufs: [MTLBuffer]  // 7 color groups
    public let colorGroupSizes: [Int]

    // Compute pipelines
    public let tickPipeline: MTLComputePipelineState       // LUT6 evaluation
    public let rankResetPipeline: MTLComputePipelineState  // clear truth states for new tick

    public let nodeCount: Int
    public let maxRank: Int  // Number of ranks in the DAG

    // BACK_EDGE primitive: typed return-edges latched at tick boundary.
    // The rank kernel skips nodes flagged as registers; those values come
    // from `latchBackEdges()` instead.
    public internal(set) var backEdgeSrcs: [UInt32] = []
    public internal(set) var backEdgeDsts: [UInt32] = []
    public let isRegisterBuf: MTLBuffer        // UInt8 per node, 1 = register

    public init(grid: HexGrid, state: DagDBState, maxRank: Int = 16) throws {
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

        // Allocate state buffers (unified memory on M-series)
        let shared = MTLResourceOptions.storageModeShared
        guard let b1 = device.makeBuffer(bytes: state.truthState, length: nodeCount, options: shared),
              let b2 = device.makeBuffer(bytes: state.rank, length: nodeCount * 8, options: shared),
              let b3 = device.makeBuffer(bytes: state.lut6Low, length: nodeCount * 4, options: shared),
              let b4 = device.makeBuffer(bytes: state.lut6High, length: nodeCount * 4, options: shared),
              let b5 = device.makeBuffer(bytes: state.activation, length: nodeCount * 2, options: shared),
              let b6 = device.makeBuffer(bytes: state.edgeWeights, length: nodeCount * 6 * 4, options: shared),
              let b7 = device.makeBuffer(bytes: state.nodeType, length: nodeCount, options: shared) else {
            throw EngineError.bufferAllocationFailed
        }
        self.truthStateBuf = b1
        self.rankBuf = b2
        self.lut6LowBuf = b3
        self.lut6HighBuf = b4
        self.activationBuf = b5
        self.edgeWeightsBuf = b6
        self.nodeTypeBuf = b7

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

        // Color groups
        var groupBufs = [MTLBuffer]()
        var groupSizes = [Int]()
        for group in grid.colorGroups {
            guard let gb = device.makeBuffer(bytes: group, length: group.count * 4, options: shared) else {
                throw EngineError.bufferAllocationFailed
            }
            groupBufs.append(gb)
            groupSizes.append(group.count)
        }
        self.colorGroupBufs = groupBufs
        self.colorGroupSizes = groupSizes

        // Load Metal library from package bundle
        let library: MTLLibrary
        if let bundleLib = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            library = bundleLib
        } else if let defaultLib = device.makeDefaultLibrary() {
            library = defaultLib
        } else {
            // Fallback: compile from source
            let shaderSource = DagDBEngine.metalShaderSource
            library = try device.makeLibrary(source: shaderSource, options: nil)
        }

        guard let tickFn = library.makeFunction(name: "dagdb_tick_rank") else {
            throw EngineError.functionNotFound("dagdb_tick_rank")
        }
        self.tickPipeline = try device.makeComputePipelineState(function: tickFn)

        guard let resetFn = library.makeFunction(name: "dagdb_reset_rank") else {
            throw EngineError.functionNotFound("dagdb_reset_rank")
        }
        self.rankResetPipeline = try device.makeComputePipelineState(function: resetFn)
    }

    /// Execute one tick: leaves-up rank propagation.
    /// Each rank evaluates in parallel (all nodes in rank N are independent).
    /// Then rank N-1 sees updated values from rank N.
    public func tick(tickNumber: UInt32) {
        guard let cmdBuf = queue.makeCommandBuffer() else { return }

        // Shuffle color order (chromatic wind fix from Gemini Deep Think)
        var colorOrder = Array(0..<HexGrid.colorCount)
        var shuffleSeed = tickNumber &* 2654435761
        for i in stride(from: colorOrder.count - 1, through: 1, by: -1) {
            shuffleSeed = shuffleSeed &* 1103515245 &+ 12345
            let j = Int(shuffleSeed >> 16) % (i + 1)
            colorOrder.swapAt(i, j)
        }

        // Leaves-up: iterate rank from max down to 0
        for rankLevel in stride(from: maxRank - 1, through: 0, by: -1) {
            // Within each rank, process 7 color groups in shuffled order
            for colorIdx in colorOrder {
                guard let enc = cmdBuf.makeComputeCommandEncoder() else { continue }
                enc.setComputePipelineState(tickPipeline)
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

                let tpg = tickPipeline.maxTotalThreadsPerThreadgroup
                enc.dispatchThreadgroups(
                    MTLSize(width: (colorGroupSizes[colorIdx] + tpg - 1) / tpg, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
                enc.endEncoding()
            }
        }

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Latch phase: copy each BACK_EDGE source's truth into its destination.
        // Two-phase semantics handled inside latchBackEdges. Runs after the
        // combinational pass so the latched values reflect this tick's
        // computed sources.
        latchBackEdges()
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

        public var description: String {
            switch self {
            case let .destinationHasCombinationalInDegree(dst, slot, src):
                return "BACK_EDGE dst node \(dst) has a combinational input at slot \(slot) (source node \(src)); registers must have zero combinational fan-in"
            case let .nodeIndexOutOfRange(node, nodeCount):
                return "node index \(node) is out of range for engine with nodeCount=\(nodeCount)"
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
        guard Int(src) < nodeCount else {
            throw BackEdgeError.nodeIndexOutOfRange(node: src, nodeCount: nodeCount)
        }
        guard Int(dst) < nodeCount else {
            throw BackEdgeError.nodeIndexOutOfRange(node: dst, nodeCount: nodeCount)
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
        backEdgeSrcs.append(src)
        backEdgeDsts.append(dst)
        let ptr = isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        ptr[Int(dst)] = 1
    }

    /// Internal: append a BACK_EDGE without validating combinational
    /// fan-in. Used by WAL replay where the original write was already
    /// validated; replay must succeed even if intermediate combinational
    /// state would temporarily violate the rule.
    func addBackEdgeUnchecked(src: UInt32, dst: UInt32) {
        backEdgeSrcs.append(src)
        backEdgeDsts.append(dst)
        let ptr = isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        ptr[Int(dst)] = 1
    }

    /// Remove every BACK_EDGE whose destination is `dst`. The node also
    /// loses its register flag, so the next tick's combinational pass will
    /// evaluate it like an ordinary node again.
    public func clearBackEdges(toNode dst: UInt32) {
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
    public func isRegister(node: UInt32) -> Bool {
        let ptr = isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        return ptr[Int(node)] != 0
    }

    /// Latch phase: snapshot every src truth, then write every dst.
    /// Two-phase write-back handles chained back-edges (one entry's dst is
    /// another entry's src) by latching from pre-tick state. Runs on the
    /// CPU; back-edge counts are small relative to combinational graphs and
    /// the truth buffer is unified-memory shared.
    public func latchBackEdges() {
        let n = backEdgeSrcs.count
        if n == 0 { return }
        let ptr = truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        var snapshot = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            snapshot[i] = ptr[Int(backEdgeSrcs[i])]
        }
        for i in 0..<n {
            ptr[Int(backEdgeDsts[i])] = snapshot[i]
        }
    }

    enum EngineError: Error {
        case noGPU
        case noQueue
        case bufferAllocationFailed
        case libraryNotFound
        case functionNotFound(String)
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
        uint                    gid          [[ thread_position_in_grid ]]
    ) {
        if (gid >= group_size) return;
        uint node = group[gid];
        if (rank[node] != current_rank) return;
        if (is_register[node] != 0) return;

        uint8_t input_bits = 0;
        for (int d = 0; d < 6; d++) {
            int32_t nb = neighbors[node * 6 + d];
            if (nb < 0) continue;
            uint8_t nb_truth = truth_state[nb];
            uint8_t bit = (nb_truth == TRUTH_TRUE) ? 1u : 0u;
            input_bits |= (bit << d);
        }

        truth_state[node] = eval_lut6(lut6_low[node], lut6_high[node], input_bits);
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
    """
}
