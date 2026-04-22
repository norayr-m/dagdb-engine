/// DagDBDistance — built-in subgraph distance metrics for DagDB.
///
/// All metrics operate on `DagSubgraph` — a node-set carved out of a DagDBEngine.
/// Metrics implemented:
///   - jaccardNodes       : |A∩B| / |A∪B|           (0 = identical, 1 = disjoint)
///   - jaccardEdges       : on induced edges         (edge-level structure)
///   - rankProfileL1      : L1 between rank histograms (DAG-shape signature)
///   - rankProfileL2      : L2 between rank histograms
///   - nodeTypeProfileL1  : L1 between node-type histograms
///   - boundedGED         : bounded graph edit distance (Jaccard symdiff upper bound)
///   - weisfeilerLehman   : WL-1 hash-histogram L1 (neighborhood-aware)
///
/// Each is a [0..1] normalized distance unless stated otherwise.
///
/// Not implemented here: spectral Laplacian L2 (needs eigensolver; can be added
/// as a separate module once Metal LAPACK wrapper exists).

import Foundation

// MARK: - Subgraph type

public struct DagSubgraph: Equatable {
    public let nodeIds: Set<Int>

    public init(_ nodes: Set<Int>) { self.nodeIds = nodes }
    public init<S: Sequence>(_ seq: S) where S.Element == Int { self.nodeIds = Set(seq) }

    /// Subgraph consisting of all nodes in a rank range (inclusive).
    public static func rankRange(
        engine: DagDBEngine, nodeCount: Int, lo: UInt64, hi: UInt64
    ) -> DagSubgraph {
        let rank = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: nodeCount)
        var ids: Set<Int> = []
        ids.reserveCapacity(nodeCount / 4)
        for i in 0..<nodeCount where rank[i] >= lo && rank[i] <= hi {
            ids.insert(i)
        }
        return DagSubgraph(ids)
    }

    /// Subgraph = every node whose rank is non-zero (everything below the roots).
    public static func all(engine: DagDBEngine, nodeCount: Int) -> DagSubgraph {
        return DagSubgraph(Set(0..<nodeCount))
    }
}

// MARK: - Distance metrics

public enum DagDBDistance {

    // --- Node-set Jaccard ---

    public static func jaccardNodes(_ a: DagSubgraph, _ b: DagSubgraph) -> Double {
        let inter = a.nodeIds.intersection(b.nodeIds).count
        let uni = a.nodeIds.union(b.nodeIds).count
        guard uni > 0 else { return 0.0 }
        return 1.0 - Double(inter) / Double(uni)
    }

    // --- Edge-set Jaccard ---

    /// Induced-edge Jaccard: edges are pairs (src, dst) where both ends are in the subgraph.
    public static func jaccardEdges(
        engine: DagDBEngine, nodeCount: Int, _ a: DagSubgraph, _ b: DagSubgraph
    ) -> Double {
        let eA = inducedEdges(engine: engine, nodeCount: nodeCount, sub: a)
        let eB = inducedEdges(engine: engine, nodeCount: nodeCount, sub: b)
        let inter = eA.intersection(eB).count
        let uni = eA.union(eB).count
        guard uni > 0 else { return 0.0 }
        return 1.0 - Double(inter) / Double(uni)
    }

    private static func inducedEdges(
        engine: DagDBEngine, nodeCount: Int, sub: DagSubgraph
    ) -> Set<UInt64> {
        // Encode edge as (UInt64(dst) << 32) | UInt64(src).
        let nb = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)
        var edges: Set<UInt64> = []
        edges.reserveCapacity(sub.nodeIds.count * 3)
        for dst in sub.nodeIds {
            for d in 0..<6 {
                let src = nb[dst * 6 + d]
                if src < 0 { continue }
                let si = Int(src)
                if sub.nodeIds.contains(si) {
                    edges.insert(UInt64(UInt32(dst)) << 32 | UInt64(UInt32(si)))
                }
            }
        }
        return edges
    }

    // --- Rank-profile ---

    /// Histogram of rank → count for nodes in the subgraph. Sparse map: rank
    /// can be up to UInt32.max post-u32-widen (2026-04-20), so a dense 256-slot array
    /// is no longer viable.
    public static func rankProfile(
        engine: DagDBEngine, nodeCount: Int, sub: DagSubgraph
    ) -> [UInt64: Int] {
        let rank = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: nodeCount)
        var hist: [UInt64: Int] = [:]
        for i in sub.nodeIds {
            hist[rank[i], default: 0] += 1
        }
        return hist
    }

    /// L1 distance between two rank histograms, normalized to [0, 1] by total mass.
    public static func rankProfileL1(
        engine: DagDBEngine, nodeCount: Int, _ a: DagSubgraph, _ b: DagSubgraph
    ) -> Double {
        let hA = rankProfile(engine: engine, nodeCount: nodeCount, sub: a)
        let hB = rankProfile(engine: engine, nodeCount: nodeCount, sub: b)
        let keys = Set(hA.keys).union(hB.keys)
        let mass = max(1, a.nodeIds.count + b.nodeIds.count)
        var sum = 0
        for k in keys {
            sum += abs((hA[k] ?? 0) - (hB[k] ?? 0))
        }
        return Double(sum) / Double(mass)
    }

    /// L2 distance between rank histograms, normalized by total mass.
    public static func rankProfileL2(
        engine: DagDBEngine, nodeCount: Int, _ a: DagSubgraph, _ b: DagSubgraph
    ) -> Double {
        let hA = rankProfile(engine: engine, nodeCount: nodeCount, sub: a)
        let hB = rankProfile(engine: engine, nodeCount: nodeCount, sub: b)
        let keys = Set(hA.keys).union(hB.keys)
        let mass = Double(max(1, a.nodeIds.count + b.nodeIds.count))
        var sum = 0.0
        for k in keys {
            let d = Double((hA[k] ?? 0) - (hB[k] ?? 0))
            sum += d * d
        }
        return sqrt(sum) / mass
    }

    // --- Node-type profile ---

    public static func nodeTypeProfileL1(
        engine: DagDBEngine, nodeCount: Int, _ a: DagSubgraph, _ b: DagSubgraph
    ) -> Double {
        let type = engine.nodeTypeBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        var hA = [Int](repeating: 0, count: 256)
        var hB = [Int](repeating: 0, count: 256)
        for i in a.nodeIds { hA[Int(type[i])] += 1 }
        for i in b.nodeIds { hB[Int(type[i])] += 1 }
        let mass = max(1, a.nodeIds.count + b.nodeIds.count)
        var sum = 0
        for i in 0..<256 { sum += abs(hA[i] - hB[i]) }
        return Double(sum) / Double(mass)
    }

    // --- Bounded graph edit distance ---

    /// Cheap upper bound on GED: node-symmetric-difference + induced-edge-symmetric-difference.
    /// Equivalent to editing A into B by adding/removing misaligned nodes and edges,
    /// assuming identity alignment (no relabeling). Useful when the two subgraphs
    /// come from the same engine and their node IDs are comparable.
    public static func boundedGED(
        engine: DagDBEngine, nodeCount: Int, _ a: DagSubgraph, _ b: DagSubgraph
    ) -> Int {
        let nodeSymDiff = a.nodeIds.symmetricDifference(b.nodeIds).count
        let eA = inducedEdges(engine: engine, nodeCount: nodeCount, sub: a)
        let eB = inducedEdges(engine: engine, nodeCount: nodeCount, sub: b)
        let edgeSymDiff = eA.symmetricDifference(eB).count
        return nodeSymDiff + edgeSymDiff
    }

    // --- Weisfeiler-Lehman-1 hash histogram ---

    /// One round of WL relabeling on the induced subgraph:
    /// label(v) = hash(rank[v], sorted inputs' previous-labels).
    /// Returns a sorted sparse histogram: [(label, count)].
    /// L1 between two histograms gives a neighborhood-aware distance.
    public static func weisfeilerLehman1Histogram(
        engine: DagDBEngine, nodeCount: Int, sub: DagSubgraph
    ) -> [UInt64: Int] {
        let rank = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: nodeCount)
        let type = engine.nodeTypeBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        let nb   = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)

        // Round-0 label: (rank, nodeType).
        var label0 = [Int: UInt64](); label0.reserveCapacity(sub.nodeIds.count)
        for i in sub.nodeIds {
            label0[i] = (UInt64(rank[i]) << 8) | UInt64(type[i])
        }

        // Round-1 label: hash(self-label, sorted neighbor labels).
        var hist: [UInt64: Int] = [:]
        for i in sub.nodeIds {
            var neighborLabels: [UInt64] = []
            for d in 0..<6 {
                let src = nb[i * 6 + d]
                if src < 0 { continue }
                let si = Int(src)
                if sub.nodeIds.contains(si), let l = label0[si] {
                    neighborLabels.append(l)
                }
            }
            neighborLabels.sort()
            var h = label0[i]!
            h ^= 0x9e3779b97f4a7c15
            for nl in neighborLabels {
                h = h &* 0x100000001b3 ^ nl  // FNV-1a style mix
            }
            hist[h, default: 0] += 1
        }
        return hist
    }

    /// L1 distance between two WL-1 histograms, normalized by total mass.
    public static func weisfeilerLehmanL1(
        engine: DagDBEngine, nodeCount: Int, _ a: DagSubgraph, _ b: DagSubgraph
    ) -> Double {
        let hA = weisfeilerLehman1Histogram(engine: engine, nodeCount: nodeCount, sub: a)
        let hB = weisfeilerLehman1Histogram(engine: engine, nodeCount: nodeCount, sub: b)
        let keys = Set(hA.keys).union(hB.keys)
        let mass = max(1, a.nodeIds.count + b.nodeIds.count)
        var sum = 0
        for k in keys {
            sum += abs((hA[k] ?? 0) - (hB[k] ?? 0))
        }
        return Double(sum) / Double(mass)
    }

    // MARK: - Spectral L2 (Laplacian eigenvalues)

    /// Build the symmetric adjacency matrix of the subgraph's induced edges,
    /// treating the directed DAG edges as undirected for Laplacian purposes.
    /// Output: dense n×n matrix in row-major [Double], where n = sub.nodeIds.count
    /// and the row/col order is the sorted list of node IDs.
    public static func inducedAdjacency(
        engine: DagDBEngine, nodeCount: Int, sub: DagSubgraph
    ) -> (matrix: [Double], sortedIds: [Int]) {
        let sortedIds = sub.nodeIds.sorted()
        var idx = [Int: Int](minimumCapacity: sortedIds.count)
        for (k, id) in sortedIds.enumerated() { idx[id] = k }

        let n = sortedIds.count
        var A = [Double](repeating: 0.0, count: n * n)
        let nb = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)

        for (r, dst) in sortedIds.enumerated() {
            for d in 0..<6 {
                let src = nb[dst * 6 + d]
                if src < 0 { continue }
                guard let c = idx[Int(src)] else { continue }
                A[r * n + c] = 1.0
                A[c * n + r] = 1.0  // symmetrize
            }
        }
        return (A, sortedIds)
    }

    /// Combinatorial Laplacian L = D − A for the subgraph.
    public static func laplacian(
        engine: DagDBEngine, nodeCount: Int, sub: DagSubgraph
    ) -> [Double] {
        let (A, ids) = inducedAdjacency(engine: engine, nodeCount: nodeCount, sub: sub)
        let n = ids.count
        var L = [Double](repeating: 0.0, count: n * n)
        for r in 0..<n {
            var deg = 0.0
            for c in 0..<n {
                L[r * n + c] = -A[r * n + c]
                deg += A[r * n + c]
            }
            L[r * n + r] = deg
        }
        return L
    }

    /// Eigenvalues of a symmetric n×n matrix via Jacobi rotations. O(n^3), but
    /// self-contained — no Accelerate / LAPACK binding. Fine up to a few hundred
    /// nodes; for larger graphs swap in dsyevd_ later.
    ///
    /// Returns ascending eigenvalues.
    public static func eigenvaluesSymmetric(
        _ matrix: [Double], n: Int,
        maxSweeps: Int = 50, tolerance: Double = 1e-10
    ) -> [Double] {
        guard n > 0 else { return [] }
        if n == 1 { return [matrix[0]] }

        var M = matrix  // in-place
        for _ in 0..<maxSweeps {
            // Sum of absolute off-diagonal entries.
            var off = 0.0
            for p in 0..<(n - 1) {
                for q in (p + 1)..<n {
                    off += abs(M[p * n + q])
                }
            }
            if off < tolerance { break }

            for p in 0..<(n - 1) {
                for q in (p + 1)..<n {
                    let apq = M[p * n + q]
                    if abs(apq) < tolerance { continue }
                    let app = M[p * n + p]
                    let aqq = M[q * n + q]
                    let theta = (aqq - app) / (2.0 * apq)
                    let t: Double
                    if abs(theta) > 1e15 {
                        t = 1.0 / (2.0 * theta)
                    } else {
                        let sign = theta >= 0 ? 1.0 : -1.0
                        t = sign / (abs(theta) + sqrt(theta * theta + 1.0))
                    }
                    let c = 1.0 / sqrt(t * t + 1.0)
                    let s = t * c

                    // Rotate: M' = J^T M J; touches only rows/cols p and q.
                    for i in 0..<n {
                        let ip = M[i * n + p]
                        let iq = M[i * n + q]
                        M[i * n + p] = c * ip - s * iq
                        M[i * n + q] = s * ip + c * iq
                    }
                    for j in 0..<n {
                        let pj = M[p * n + j]
                        let qj = M[q * n + j]
                        M[p * n + j] = c * pj - s * qj
                        M[q * n + j] = s * pj + c * qj
                    }
                }
            }
        }

        var eigs = [Double](repeating: 0.0, count: n)
        for i in 0..<n { eigs[i] = M[i * n + i] }
        eigs.sort()
        return eigs
    }

    /// Spectral L2: L2 distance between sorted Laplacian-eigenvalue vectors of
    /// the two subgraphs. Shorter spectrum is left-padded with zeros (since
    /// a smaller graph has the same number of zero eigenvalues as connected
    /// components + additional zero-padding suffices for alignment).
    public static func spectralL2(
        engine: DagDBEngine, nodeCount: Int, _ a: DagSubgraph, _ b: DagSubgraph
    ) -> Double {
        let LA = laplacian(engine: engine, nodeCount: nodeCount, sub: a)
        let LB = laplacian(engine: engine, nodeCount: nodeCount, sub: b)
        let eigA = eigenvaluesSymmetric(LA, n: a.nodeIds.count)
        let eigB = eigenvaluesSymmetric(LB, n: b.nodeIds.count)

        let m = max(eigA.count, eigB.count)
        // Left-pad with zeros so both vectors are length m.
        var padA = [Double](repeating: 0.0, count: m - eigA.count) + eigA
        var padB = [Double](repeating: 0.0, count: m - eigB.count) + eigB
        _ = padA; _ = padB  // silence unused warning on re-init paths

        var sum = 0.0
        for i in 0..<m {
            let ea = i < (m - eigA.count) ? 0.0 : eigA[i - (m - eigA.count)]
            let eb = i < (m - eigB.count) ? 0.0 : eigB[i - (m - eigB.count)]
            let d = ea - eb
            sum += d * d
        }
        return sqrt(sum)
    }

    // MARK: - One-shot dispatch

    public enum Metric: String {
        case jaccardNodes, jaccardEdges, rankL1, rankL2, typeL1, boundedGED, wlL1, spectralL2
    }

    /// Convenience: compute any named metric. boundedGED returns an Int cast to Double.
    public static func compute(
        engine: DagDBEngine, nodeCount: Int,
        metric: Metric, _ a: DagSubgraph, _ b: DagSubgraph
    ) -> Double {
        switch metric {
        case .jaccardNodes:
            return jaccardNodes(a, b)
        case .jaccardEdges:
            return jaccardEdges(engine: engine, nodeCount: nodeCount, a, b)
        case .rankL1:
            return rankProfileL1(engine: engine, nodeCount: nodeCount, a, b)
        case .rankL2:
            return rankProfileL2(engine: engine, nodeCount: nodeCount, a, b)
        case .typeL1:
            return nodeTypeProfileL1(engine: engine, nodeCount: nodeCount, a, b)
        case .boundedGED:
            return Double(boundedGED(engine: engine, nodeCount: nodeCount, a, b))
        case .wlL1:
            return weisfeilerLehmanL1(engine: engine, nodeCount: nodeCount, a, b)
        case .spectralL2:
            return spectralL2(engine: engine, nodeCount: nodeCount, a, b)
        }
    }
}
