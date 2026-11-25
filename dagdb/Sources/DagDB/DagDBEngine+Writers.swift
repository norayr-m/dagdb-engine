/// DagDBEngine+Writers — the engine's direct writers of node values and edge
/// weights.
///
/// SET VALUE and SET WEIGHT refuse a non-finite number at the DSL; every load
/// and restore path refuses one in a file. These
/// writers give library callers the same rule: a NaN or an infinity is refused
/// by name — the loaders' own words — and nothing is written. A bulk write
/// checks its whole lane before it writes one element. The raw buffers
/// (`nodeValueBuf`, `edgeWeightsBuf`) stay public and unchecked; these are the
/// checked way in.

import Foundation

extension DagDBEngine {

    /// One node's value. Refused by name when not finite; nothing written.
    public func setNodeValue(_ node: Int, _ value: Float) throws {
        precondition(node >= 0 && node < nodeCount, "node \(node) not in 0..<\(nodeCount)")
        if let why = DagDBSnapshot.nodeValueRefusal(bits: value.bitPattern, node: node) {
            throw EngineError.nonFinite(why)
        }
        nodeValueBuf.contents().bindMemory(to: Float.self, capacity: nodeCount)[node] = value
    }

    /// One edge weight (`dir` 0..<6). Refused by name when not finite.
    public func setEdgeWeight(_ node: Int, dir: Int, _ value: Float) throws {
        precondition(node >= 0 && node < nodeCount, "node \(node) not in 0..<\(nodeCount)")
        precondition(dir >= 0 && dir < 6, "dir \(dir) not in 0..<6")
        if let why = DagDBSnapshot.weightRefusal(bits: value.bitPattern, node: node, slot: dir) {
            throw EngineError.nonFinite(why)
        }
        edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: nodeCount * 6)[node * 6 + dir] = value
    }

    /// The whole node-value lane (`nodeCount` values). The first non-finite
    /// value is named and nothing is written; a short vector is refused.
    public func setNodeValues(_ values: [Float]) throws {
        guard values.count == nodeCount else {
            throw EngineError.shortBuffer(what: "setNodeValues", given: values.count, nodeCount: nodeCount)
        }
        try values.withUnsafeBytes { raw in
            if let why = DagDBSnapshot.nodeValueRefusal(raw.baseAddress!, count: nodeCount) {
                throw EngineError.nonFinite(why)
            }
            memcpy(nodeValueBuf.contents(), raw.baseAddress!, nodeCount * 4)
        }
    }

    /// The whole edge-weight lane (`nodeCount * 6` weights, slot k = node
    /// k / 6, direction k % 6). Same rule as `setNodeValues`.
    public func setEdgeWeights(_ weights: [Float]) throws {
        guard weights.count == nodeCount * 6 else {
            throw EngineError.shortBuffer(what: "setEdgeWeights", given: weights.count, nodeCount: nodeCount)
        }
        try weights.withUnsafeBytes { raw in
            if let why = DagDBSnapshot.weightRefusal(raw.baseAddress!, count: nodeCount * 6) {
                throw EngineError.nonFinite(why)
            }
            memcpy(edgeWeightsBuf.contents(), raw.baseAddress!, nodeCount * 24)
        }
    }
}
