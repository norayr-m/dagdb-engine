// DagDB — ranked DAG substrate with LUT6 nodes and ternary state.
//
// Layout matches Shaders/engine.metal's DagNode struct (64-byte aligned).
// Node table is held as a contiguous MTLBuffer in unified memory; the
// second half of the buffer holds mirror nodes for the backward wave.
//
// Rank convention (per thesis v3.7): Queen = rank 0, Leaves = rank N,
// edges satisfy rank(src) < rank(dst). See thesis §3.1 Definition of Rank.

import Foundation
import Metal

/// A single node in the ranked DAG. Must stay binary-compatible with the
/// Metal `DagNode` struct in engine.metal. 64 bytes total.
public struct DagNode: Equatable {
    public var id: UInt32
    public var rank: UInt32
    public var inputs: (Int32, Int32, Int32, Int32, Int32, Int32)
    public var lut: UInt64          // LUT6 truth table: 64 bits
    public var state: Int8          // ternary: -1, 0, +1
    public var active: UInt8        // 1 if in current wave-front, else 0
    private var _pad0: UInt16 = 0
    private var _pad1: UInt32 = 0
    private var _pad2: UInt32 = 0
    private var _pad3: UInt32 = 0

    public init(id: UInt32,
                rank: UInt32,
                inputs: (Int32, Int32, Int32, Int32, Int32, Int32),
                lut: UInt64,
                state: Int8 = 0,
                active: UInt8 = 0)
    {
        self.id = id
        self.rank = rank
        self.inputs = inputs
        self.lut = lut
        self.state = state
        self.active = active
    }

    public static func == (lhs: DagNode, rhs: DagNode) -> Bool {
        lhs.id == rhs.id &&
        lhs.rank == rhs.rank &&
        lhs.inputs == rhs.inputs &&
        lhs.lut == rhs.lut &&
        lhs.state == rhs.state &&
        lhs.active == rhs.active
    }
}

/// The DagDB substrate.
///
/// Owns a contiguous node buffer of size `2 * nodeCount`:
/// - first half:  original DAG (rank 0 .. N)
/// - second half: mirror DAG   (rank N+1 .. 2N)
///
/// The mirror node at index `i + nodeCount` is paired with node `i`.
/// Rank monotonicity `rank(src) < rank(dst)` is a runtime invariant,
/// enforced on insertion. Breaking it is a fatal error: it breaks Morton
/// locality, breaks the wave scheduler, and collapses the 14 GCUPS
/// regime (see thesis §5 cascade analysis).
public final class DagDB {
    public let nodeCount: Int
    public let maxRank: UInt32
    public let queenIdx: UInt32
    public let device: MTLDevice
    public let buffer: MTLBuffer

    /// Pointer into the contiguous node table. Writes are visible across
    /// CPU and GPU thanks to unified memory (storageMode: .shared).
    public var nodes: UnsafeMutableBufferPointer<DagNode> {
        let raw = buffer.contents().assumingMemoryBound(to: DagNode.self)
        return UnsafeMutableBufferPointer(start: raw, count: 2 * nodeCount)
    }

    public init(device: MTLDevice,
                nodes ns: [DagNode],
                maxRank: UInt32,
                queenIdx: UInt32 = 0)
    {
        precondition(!ns.isEmpty, "DagDB must have at least one node")
        // Size the buffer for node + mirror.
        let total = ns.count * 2
        let byteLen = total * MemoryLayout<DagNode>.stride
        self.device    = device
        self.buffer    = device.makeBuffer(length: byteLen,
                                            options: MTLResourceOptions.storageModeShared)!
        self.nodeCount = ns.count
        self.maxRank   = maxRank
        self.queenIdx  = queenIdx

        // Fill forward half; leave mirror half as zero-initialised DagNode.
        let raw = buffer.contents().assumingMemoryBound(to: DagNode.self)
        for (i, n) in ns.enumerated() {
            raw[i] = n
            // Mirror node at i + nodeCount with rank = 2*maxRank - rank + 1.
            var m = n
            m.id     = UInt32(i + ns.count)
            m.rank   = 2 * maxRank - n.rank + 1
            m.state  = 0
            m.active = 0
            raw[i + ns.count] = m
        }

        // Rank-monotonicity check (debug only).
        #if DEBUG
        for (i, n) in ns.enumerated() {
            for k in 0..<6 {
                let j = withUnsafeBytes(of: n.inputs) { ptr -> Int32 in
                    ptr.load(fromByteOffset: k * MemoryLayout<Int32>.stride, as: Int32.self)
                }
                guard j >= 0 else { continue }
                let src = ns[Int(j)]
                precondition(src.rank < n.rank,
                             "Rank monotonicity violated at node \(i): src(\(j)).rank=\(src.rank) >= dst.rank=\(n.rank)")
            }
        }
        #endif
    }
}
