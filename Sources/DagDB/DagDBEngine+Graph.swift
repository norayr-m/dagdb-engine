/// DagDBEngine+Graph — Convenience initializer from DagDBGraph.
///
/// Builds engine directly from a logical graph, creating a custom
/// neighbor table that reflects logical edges instead of hex geometry.

import Metal
import Foundation

extension DagDBEngine {

    /// Initialize engine from a logical graph.
    /// Creates a grid large enough to hold all nodes, exports state and
    /// custom neighbor table from the graph.
    public convenience init(graph: DagDBGraph, maxRank: Int? = nil) throws {
        // Find minimum grid size (square, power of 2 for good Morton behavior)
        let n = graph.nodeCount
        let side = max(4, Int(ceil(sqrt(Double(n)))))
        // Round up to next even number for hex grid symmetry
        let gridSide = side + (side % 2)

        let grid = HexGrid(width: gridSide, height: gridSide)
        let state = try graph.exportState(grid: grid)
        let rank = maxRank ?? (graph.maxRank + 1)

        try self.init(grid: grid, state: state, maxRank: rank)

        // Override neighbor buffer with logical edges from graph
        let logicalNeighbors = graph.exportNeighborTable(nodeCount: grid.nodeCount)
        let ptr = neighborsBuf.contents().bindMemory(to: Int32.self, capacity: grid.nodeCount * 6)
        for i in 0..<min(logicalNeighbors.count, grid.nodeCount * 6) {
            ptr[i] = logicalNeighbors[i]
        }
    }

    /// Execute one tick with micro-time resonance within each rank.
    /// Each rank iterates until convergence or MAX_MICRO_TICKS.
    /// Returns: (microTicksPerRank: [Int], converged: [Bool])
    @discardableResult
    public func tickWithResonance(tickNumber: UInt32, maxMicroTicks: Int = 100) -> (microTicks: [Int], converged: [Bool]) {
        var microTicksPerRank: [Int] = []
        var convergedPerRank: [Bool] = []

        // Shuffle color order (Murmur3-derived, deterministic)
        var colorOrder = Array(0..<HexGrid.colorCount)
        var shuffleSeed = tickNumber &* 2654435761
        for i in stride(from: colorOrder.count - 1, through: 1, by: -1) {
            shuffleSeed = shuffleSeed &* 1103515245 &+ 12345
            let j = Int(shuffleSeed >> 16) % (i + 1)
            colorOrder.swapAt(i, j)
        }

        // Leaves-up: iterate rank from max down to 0
        for rankLevel in stride(from: maxRank - 1, through: 0, by: -1) {
            // Snapshot truth states before this rank's micro-time
            let prevSnapshot = readTruthStates()

            var microTick = 0
            var rankConverged = false

            for _ in 0..<maxMicroTicks {
                guard let cmdBuf = queue.makeCommandBuffer() else { break }

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

                cmdBuf.commit()
                cmdBuf.waitUntilCompleted()
                microTick += 1

                // Check convergence: has anything at this rank changed?
                let currentStates = readTruthStates()
                let rankPtr = rankBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
                var changed = false
                for i in 0..<nodeCount where rankPtr[i] == UInt8(rankLevel) {
                    if currentStates[i] != prevSnapshot[i] {
                        changed = true
                        break
                    }
                }

                if !changed && microTick > 1 {
                    rankConverged = true
                    break
                }
            }

            // If not converged after max micro-ticks: set to UNDEFINED (paradox horizon)
            if !rankConverged && microTick >= maxMicroTicks {
                let ptr = truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
                let rankPtr = rankBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
                for i in 0..<nodeCount where rankPtr[i] == UInt8(rankLevel) {
                    if ptr[i] != prevSnapshot[i] {
                        ptr[i] = 2  // TRUTH_UNDEFINED
                    }
                }
            }

            microTicksPerRank.append(microTick)
            convergedPerRank.append(rankConverged)
        }

        return (microTicksPerRank, convergedPerRank)
    }

    /// Write a complete truth state snapshot (for save/restore).
    public func writeTruthStates(_ states: [UInt8]) {
        let ptr = truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        for i in 0..<min(states.count, nodeCount) {
            ptr[i] = states[i]
        }
    }

    /// Read rank buffer back to CPU.
    public func readRanks() -> [UInt8] {
        let ptr = rankBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        return Array(UnsafeBufferPointer(start: ptr, count: nodeCount))
    }

    /// Read LUT6 values back.
    public func readLUT6() -> [(low: UInt32, high: UInt32)] {
        let lowPtr = lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
        let highPtr = lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
        return (0..<nodeCount).map { (lowPtr[$0], highPtr[$0]) }
    }
}
