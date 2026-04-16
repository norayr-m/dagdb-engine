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
    public let rankBuf: MTLBuffer           // UInt8 per node
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
              let b2 = device.makeBuffer(bytes: state.rank, length: nodeCount, options: shared),
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
                var currentRank = UInt8(rankLevel)
                enc.setBytes(&currentRank, length: 1, index: 7)

                let tpg = tickPipeline.maxTotalThreadsPerThreadgroup
                enc.dispatchThreadgroups(
                    MTLSize(width: (colorGroupSizes[colorIdx] + tpg - 1) / tpg, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
                enc.endEncoding()
            }
        }

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
    }

    /// Read current truth states back to CPU
    public func readTruthStates() -> [UInt8] {
        let ptr = truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        return Array(UnsafeBufferPointer(start: ptr, count: nodeCount))
    }

    /// Read the root node(s) — nodes with rank 0
    public func readRoots() -> [(nodeIndex: Int, truthState: UInt8)] {
        let truth = readTruthStates()
        let rankPtr = rankBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        var roots = [(Int, UInt8)]()
        for i in 0..<nodeCount where rankPtr[i] == 0 {
            roots.append((i, truth[i]))
        }
        return roots
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
        device const uint8_t*   rank         [[ buffer(1) ]],
        device const uint32_t*  lut6_low     [[ buffer(2) ]],
        device const uint32_t*  lut6_high    [[ buffer(3) ]],
        device const int32_t*   neighbors    [[ buffer(4) ]],
        device const uint32_t*  group        [[ buffer(5) ]],
        constant uint32_t&      group_size   [[ buffer(6) ]],
        constant uint8_t&       current_rank [[ buffer(7) ]],
        uint                    gid          [[ thread_position_in_grid ]]
    ) {
        if (gid >= group_size) return;
        uint node = group[gid];
        if (rank[node] != current_rank) return;

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
        device const uint8_t*   rank         [[ buffer(1) ]],
        constant uint8_t&       current_rank [[ buffer(2) ]],
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
        device const uint8_t*   rank         [[ buffer(1) ]],
        device const float*     edge_weights [[ buffer(2) ]],
        device const int32_t*   neighbors    [[ buffer(3) ]],
        device const uint32_t*  group        [[ buffer(4) ]],
        constant uint32_t&      group_size   [[ buffer(5) ]],
        constant uint8_t&       current_rank [[ buffer(6) ]],
        constant float&         threshold    [[ buffer(7) ]],
        uint                    gid          [[ thread_position_in_grid ]]
    ) {
        if (gid >= group_size) return;
        uint node = group[gid];
        if (rank[node] != current_rank) return;
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
