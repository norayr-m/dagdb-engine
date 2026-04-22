/// DagDBBFS — breadth-first search primitives for DagDB.
///
/// Shipped 2026-04-20 to unblock the 7-protein biology certification
/// (Fold's ingestion pipeline). Two BFS flavours:
///
///   - bfsDepthsUndirected(from:)    — treat every directed edge as
///     bidirectional. Distances are graph-geodesic over the underlying
///     undirected graph. This is what protein contact-graph BFS wants
///     under the dual-node encoding; it also matches BFSLib's semantics.
///
///   - bfsDepthsBackward(from:)      — follow `inputs[]` only. Distances
///     are in the "edges point up the DAG" direction. Cheaper (no fanout
///     build) and useful for queries like "which rank-0 nodes can reach
///     this seed by walking up through inputs".
///
/// Return shape: `[Int32]` of length `nodeCount`. `-1` = unreachable,
/// `0` = seed, positive values = BFS depth.
///
/// Undirected BFS needs a reverse adjacency (fanout) because DagDB
/// stores edges by destination. Fanout is built on the fly in O(N·6)
/// as a one-shot scan of the neighbors buffer; no persistent state.

import Foundation

public enum DagDBBFS {

    public enum BFSError: Error, CustomStringConvertible {
        case seedOutOfRange(Int, nodeCount: Int)

        public var description: String {
            switch self {
            case .seedOutOfRange(let s, let n):
                return "seed \(s) out of range [0, \(n))"
            }
        }
    }

    public struct Result {
        public let depths: [Int32]       // length = nodeCount, -1 = unreachable
        public let reached: Int          // count of nodes with depth ≥ 0
        public let maxDepth: Int32       // largest reached depth, -1 if only seed
        public let elapsedMs: Double
    }

    // MARK: - Undirected BFS (inputs ∪ fanout)

    /// Breadth-first search treating every directed edge as bidirectional.
    /// For DagDB's dual-node encoding of undirected graphs (see ARCHITECTURE §5),
    /// this is the call you want.
    public static func bfsDepthsUndirected(
        engine: DagDBEngine, nodeCount: Int, from seed: Int
    ) throws -> Result {
        guard seed >= 0 && seed < nodeCount else {
            throw BFSError.seedOutOfRange(seed, nodeCount: nodeCount)
        }
        let t0 = Date()

        let nb = engine.neighborsBuf.contents().bindMemory(
            to: Int32.self, capacity: nodeCount * 6)

        // Build fanout: for each src, the list of dsts that name it as an input.
        // One pass over the neighbors buffer. O(N·6).
        var fanoutHead  = [Int32](repeating: -1, count: nodeCount)   // linked-list head per src
        var fanoutNext  = [Int32](repeating: -1, count: nodeCount * 6)
        var fanoutNode  = [Int32](repeating: -1, count: nodeCount * 6)
        var edgeIdx = 0
        for dst in 0..<nodeCount {
            for slot in 0..<6 {
                let src = nb[dst * 6 + slot]
                if src >= 0 && Int(src) < nodeCount {
                    fanoutNode[edgeIdx] = Int32(dst)
                    fanoutNext[edgeIdx] = fanoutHead[Int(src)]
                    fanoutHead[Int(src)] = Int32(edgeIdx)
                    edgeIdx += 1
                }
            }
        }

        var depths  = [Int32](repeating: -1, count: nodeCount)
        depths[seed] = 0
        var reached = 1
        var maxDepth: Int32 = 0

        // Frontier queue via two alternating arrays.
        var current = [Int](); current.reserveCapacity(nodeCount / 4)
        var next    = [Int](); next.reserveCapacity(nodeCount / 4)
        current.append(seed)

        var d: Int32 = 0
        while !current.isEmpty {
            d += 1
            for v in current {
                // Incoming edges (this node's inputs).
                for slot in 0..<6 {
                    let src = nb[v * 6 + slot]
                    if src < 0 { continue }
                    let s = Int(src)
                    if depths[s] == -1 {
                        depths[s] = d
                        reached += 1
                        if d > maxDepth { maxDepth = d }
                        next.append(s)
                    }
                }
                // Outgoing edges (fanout linked list).
                var fIdx = fanoutHead[v]
                while fIdx >= 0 {
                    let w = Int(fanoutNode[Int(fIdx)])
                    if depths[w] == -1 {
                        depths[w] = d
                        reached += 1
                        if d > maxDepth { maxDepth = d }
                        next.append(w)
                    }
                    fIdx = fanoutNext[Int(fIdx)]
                }
            }
            swap(&current, &next)
            next.removeAll(keepingCapacity: true)
        }

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return Result(depths: depths, reached: reached, maxDepth: maxDepth, elapsedMs: elapsed)
    }

    // MARK: - Backward BFS (follow inputs only)

    /// Breadth-first search following the `inputs[]` relation only.
    /// Cheaper — no fanout build. In a normal DagDB the inputs of node v are
    /// its predecessors (rank(src) > rank(dst)), so this BFS walks *up* the
    /// rank order from the seed toward higher-rank ancestors.
    public static func bfsDepthsBackward(
        engine: DagDBEngine, nodeCount: Int, from seed: Int
    ) throws -> Result {
        guard seed >= 0 && seed < nodeCount else {
            throw BFSError.seedOutOfRange(seed, nodeCount: nodeCount)
        }
        let t0 = Date()

        let nb = engine.neighborsBuf.contents().bindMemory(
            to: Int32.self, capacity: nodeCount * 6)

        var depths  = [Int32](repeating: -1, count: nodeCount)
        depths[seed] = 0
        var reached = 1
        var maxDepth: Int32 = 0

        var current = [Int]()
        var next    = [Int]()
        current.append(seed)

        var d: Int32 = 0
        while !current.isEmpty {
            d += 1
            for v in current {
                for slot in 0..<6 {
                    let src = nb[v * 6 + slot]
                    if src < 0 { continue }
                    let s = Int(src)
                    if depths[s] == -1 {
                        depths[s] = d
                        reached += 1
                        if d > maxDepth { maxDepth = d }
                        next.append(s)
                    }
                }
            }
            swap(&current, &next)
            next.removeAll(keepingCapacity: true)
        }

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return Result(depths: depths, reached: reached, maxDepth: maxDepth, elapsedMs: elapsed)
    }

    // MARK: - Note on encodings
    //
    // A dual-node-per-residue encoding (B at rank 1, A at rank 0, with
    // contact edges B→A in both residue-orderings) was initially proposed
    // for undirected contact graphs but does NOT preserve contact-graph
    // geodesics under undirected BFS — see the 2026-04-20 amendment drop.
    //
    // The correct encoding for an undirected contact graph on ≤ 255
    // residues is single-node-per-residue with `rank = maxRank -
    // seqIndex`. Every contact (p, q) with `p < q` is a single edge with
    // src = node_p (higher rank) and dst = node_q (lower rank). Undirected
    // BFS via `bfsDepthsUndirected` then yields contact-graph geodesic
    // distances directly; no post-processing required.
}
