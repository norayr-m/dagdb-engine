/// DagDBState — Node state arrays for a 6-bounded ranked DAG.
///
/// Forked from SavannaState (lions and zebras) and generalized:
///   entity (Int8)    → truthState (UInt8: 0=false, 1=true, 2=undefined)
///   energy (Int16)   → activation (Int16: for continuous mode)
///   orientation      → rank (UInt8: 0=root, 255=leaf)
///   gauge            → lut6Low/lut6High (UInt32 pair = 64-bit LUT)
///
/// Arrays are indexed by Morton rank (not row-major). See HexGrid.mortonRank.
/// Memory layout per Gemini Deep Think: [8 bits rank MSB | 56 bits Morton Z LSB]

import Foundation

public struct DagDBState {
    public let width: Int
    public let height: Int
    public let nodeCount: Int

    /// Truth state: 0=false, 1=true, 2=undefined (paradox horizon)
    public var truthState: [UInt8]

    /// Node rank: 0 = root decision, higher = leaf-ward.
    /// Widened u8 → u32 on 2026-04-20 (T1); u32 → u64 on 2026-04-21 (T1b,
    /// for the 10^11-nodes-on-laptop target). Max 2^64 - 1.
    public var rank: [UInt64]

    /// LUT6: 64-bit programmable Boolean function per node
    /// Split as (low, high) UInt32 pair for Metal buffer alignment
    public var lut6Low: [UInt32]
    public var lut6High: [UInt32]

    /// Continuous activation (optional, for weighted mode)
    public var activation: [Int16]

    /// Edge weights per direction (6 per node)
    /// weights[node * 6 + dir] = edge weight to neighbor in that direction
    public var edgeWeights: [Float]

    /// Node type marker: 0=real, 1=virtual (hub split), 2=ghost (skip-connection padding)
    public var nodeType: [UInt8]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let n = width * height
        self.nodeCount = n

        self.truthState = [UInt8](repeating: 0, count: n)
        self.rank = [UInt64](repeating: 0, count: n)
        self.lut6Low = [UInt32](repeating: 0, count: n)
        self.lut6High = [UInt32](repeating: 0, count: n)
        self.activation = [Int16](repeating: 0, count: n)
        self.edgeWeights = [Float](repeating: 1.0, count: n * 6)
        self.nodeType = [UInt8](repeating: 0, count: n)
    }

    /// Set a node's LUT6 from a 64-bit value
    public mutating func setLUT6(at index: Int, value: UInt64) {
        lut6Low[index] = UInt32(value & 0xFFFFFFFF)
        lut6High[index] = UInt32((value >> 32) & 0xFFFFFFFF)
    }

    /// Get a node's LUT6 as 64-bit value
    public func getLUT6(at index: Int) -> UInt64 {
        return UInt64(lut6High[index]) << 32 | UInt64(lut6Low[index])
    }

    /// Evaluate LUT6 with 6 input bits (returns 0 or 1)
    public func evaluateLUT6(nodeIndex: Int, inputs: UInt8) -> UInt8 {
        let lut = getLUT6(at: nodeIndex)
        let idx = UInt64(inputs & 0x3F)  // 6 bits max
        return UInt8((lut >> idx) & 1)
    }
}

// MARK: - LUT6 Presets

public enum LUT6Preset {
    /// AND6: output = input0 & input1 & ... & input5
    public static let and6: UInt64 = 0x8000000000000000

    /// OR6: output = input0 | input1 | ... | input5
    public static let or6: UInt64 = 0xFFFFFFFFFFFFFFFE

    /// XOR6 (parity): output = input0 ^ input1 ^ ... ^ input5
    public static let xor6: UInt64 = {
        var lut: UInt64 = 0
        for i: UInt64 in 0..<64 {
            let parity = (i.nonzeroBitCount) & 1
            if parity == 1 { lut |= (UInt64(1) << i) }
        }
        return lut
    }()

    /// MAJORITY6: output = 1 if 4+ inputs are 1
    public static let majority6: UInt64 = {
        var lut: UInt64 = 0
        for i: UInt64 in 0..<64 {
            if i.nonzeroBitCount >= 4 { lut |= (UInt64(1) << i) }
        }
        return lut
    }()

    /// IDENTITY: output = input0 (ghost/pass-through node for skip-connections)
    public static let identity: UInt64 = {
        var lut: UInt64 = 0
        for i: UInt64 in 0..<64 {
            if (i & 1) == 1 { lut |= (UInt64(1) << i) }
        }
        return lut
    }()

    /// VETO: output = 1 iff all inputs 1, any 0 blocks it (same as AND6)
    public static let veto: UInt64 = and6

    /// NOR6: output = 1 iff all inputs 0. Used for "healthy unless any input fires"
    /// semantics — e.g., a cell is alive unless any damage signal is present.
    public static let nor6: UInt64 = 0x0000000000000001

    /// AND3: output = 1 iff inputs 0,1,2 all 1 (inputs 3,4,5 ignored).
    /// Use when a node aggregates 3 real sources and leaves 3 slots unused (-1).
    public static let and3: UInt64 = {
        var lut: UInt64 = 0
        for i: UInt64 in 0..<64 {
            if (i & 0x07) == 0x07 { lut |= (UInt64(1) << i) }
        }
        return lut
    }()

    /// OR3: output = 1 iff any of inputs 0,1,2 are 1.
    public static let or3: UInt64 = {
        var lut: UInt64 = 0
        for i: UInt64 in 0..<64 {
            if (i & 0x07) != 0 { lut |= (UInt64(1) << i) }
        }
        return lut
    }()

    /// MAJ3: output = 1 iff 2+ of inputs 0,1,2 are 1.
    public static let maj3: UInt64 = {
        var lut: UInt64 = 0
        for i: UInt64 in 0..<64 {
            let low = i & 0x07
            if low.nonzeroBitCount >= 2 { lut |= (UInt64(1) << i) }
        }
        return lut
    }()

    /// NAND6: output = 0 iff all inputs 1. Used for "passes unless all-positive".
    public static let nand6: UInt64 = ~and6

    /// CONST0 / CONST1 (foundational premises with fixed truth)
    public static let const0: UInt64 = 0
    public static let const1: UInt64 = 0xFFFFFFFFFFFFFFFF
}
