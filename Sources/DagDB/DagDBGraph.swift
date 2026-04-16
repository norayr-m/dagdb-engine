/// DagDBGraph — Programmatic graph builder for 6-bounded ranked DAGs.
///
/// Builds a logical graph independent of the hex grid substrate.
/// Nodes are placed on grid cells and connected via the hex neighbor table.
/// Handles:
///   - Node creation with rank and LUT6 assignment
///   - Edge wiring (respects 6-bound)
///   - Virtual node splitting for hub nodes (6-ary fractal fan-in)
///   - Ghost node padding for skip connections
///   - State export to DagDBState for GPU evaluation

import Foundation

public final class DagDBGraph {
    public struct Node {
        public let id: Int
        public var rank: UInt8
        public var lut6: UInt64
        public var truthState: UInt8
        public var nodeType: NodeType
        public var label: String
        public var edges: [Int]  // IDs of nodes this node reads from (max 6)

        public enum NodeType: UInt8 {
            case real = 0
            case virtual = 1   // hub split aggregator
            case ghost = 2     // skip-connection identity pad
        }
    }

    public private(set) var nodes: [Node] = []
    private var labelIndex: [String: Int] = [:]

    public var nodeCount: Int { nodes.count }

    /// Maximum rank across all nodes
    public var maxRank: Int {
        nodes.map { Int($0.rank) }.max() ?? 0
    }

    // MARK: - Node Creation

    /// Add a leaf node (atomic fact, preset truth value).
    @discardableResult
    public func addLeaf(label: String, rank: UInt8, truth: Bool) -> Int {
        let id = nodes.count
        nodes.append(Node(
            id: id, rank: rank,
            lut6: truth ? LUT6Preset.const1 : LUT6Preset.const0,
            truthState: truth ? 1 : 0,
            nodeType: .real,
            label: label,
            edges: []
        ))
        labelIndex[label] = id
        return id
    }

    /// Add a gate node (computes from inputs).
    @discardableResult
    public func addGate(label: String, rank: UInt8, lut6: UInt64) -> Int {
        let id = nodes.count
        nodes.append(Node(
            id: id, rank: rank,
            lut6: lut6,
            truthState: 0,
            nodeType: .real,
            label: label,
            edges: []
        ))
        labelIndex[label] = id
        return id
    }

    /// Add a ghost node (identity pass-through for skip connections).
    @discardableResult
    public func addGhost(label: String, rank: UInt8) -> Int {
        let id = nodes.count
        nodes.append(Node(
            id: id, rank: rank,
            lut6: LUT6Preset.identity,
            truthState: 0,
            nodeType: .ghost,
            label: label,
            edges: []
        ))
        labelIndex[label] = id
        return id
    }

    // MARK: - Edge Wiring

    /// Connect source → target (target reads from source).
    /// Source must have higher rank (closer to leaves) than target.
    public func connect(from source: Int, to target: Int) throws {
        guard source < nodes.count && target < nodes.count else {
            throw GraphError.nodeNotFound
        }
        guard nodes[source].rank > nodes[target].rank else {
            throw GraphError.rankViolation(
                "Source rank \(nodes[source].rank) must be > target rank \(nodes[target].rank)"
            )
        }
        guard nodes[target].edges.count < 6 else {
            throw GraphError.degreeOverflow(
                "Node \(target) (\(nodes[target].label)) already has 6 edges"
            )
        }
        guard !nodes[target].edges.contains(source) else {
            return // already connected
        }
        nodes[target].edges.append(source)
    }

    /// Connect by label.
    public func connect(from sourceLabel: String, to targetLabel: String) throws {
        guard let s = labelIndex[sourceLabel] else {
            throw GraphError.nodeNotFound
        }
        guard let t = labelIndex[targetLabel] else {
            throw GraphError.nodeNotFound
        }
        try connect(from: s, to: t)
    }

    // MARK: - Skip Connection with Ghost Padding

    /// Connect source to target across multiple ranks, padding with ghost nodes.
    /// Returns IDs of any ghost nodes created.
    @discardableResult
    public func connectWithGhosts(from source: Int, to target: Int) throws -> [Int] {
        guard source < nodes.count && target < nodes.count else {
            throw GraphError.nodeNotFound
        }
        let srcRank = Int(nodes[source].rank)
        let tgtRank = Int(nodes[target].rank)
        guard srcRank > tgtRank else {
            throw GraphError.rankViolation("Source rank must be > target rank")
        }

        let gap = srcRank - tgtRank
        if gap == 1 {
            // Direct connection, no ghosts needed
            try connect(from: source, to: target)
            return []
        }

        // Pad with ghost nodes at intermediate ranks
        var ghosts: [Int] = []
        var prev = source
        for r in stride(from: srcRank - 1, to: tgtRank, by: -1) {
            let ghostId = addGhost(
                label: "_ghost_\(source)_\(target)_r\(r)",
                rank: UInt8(r)
            )
            try connect(from: prev, to: ghostId)
            ghosts.append(ghostId)
            prev = ghostId
        }
        try connect(from: prev, to: target)
        return ghosts
    }

    // MARK: - Hub Node Splitting (6-ary Fractal Fan-In)

    /// Split a node that would exceed 6 inputs into a tree of virtual aggregators.
    /// The original node becomes the root, virtual nodes fan in from sources.
    /// Returns IDs of created virtual nodes.
    @discardableResult
    public func splitHub(node target: Int, sources: [Int], aggregateLUT: UInt64 = LUT6Preset.or6) throws -> [Int] {
        guard target < nodes.count else {
            throw GraphError.nodeNotFound
        }
        guard sources.count > 6 else {
            // No split needed, just connect directly
            for s in sources {
                try connect(from: s, to: target)
            }
            return []
        }

        let targetRank = Int(nodes[target].rank)
        var virtuals: [Int] = []

        // Recursive 6-ary fan-in
        func buildTree(inputs: [Int], outputRank: Int) throws -> Int {
            if inputs.count <= 6 {
                // Base case: create one virtual node (or use target if at root level)
                let virt = addGate(
                    label: "_virt_\(target)_\(virtuals.count)",
                    rank: UInt8(outputRank + 1),
                    lut6: aggregateLUT
                )
                nodes[virt].nodeType = .virtual
                for s in inputs {
                    try connect(from: s, to: virt)
                }
                virtuals.append(virt)
                return virt
            }

            // Split into groups of 6
            var groupOutputs: [Int] = []
            for chunkStart in stride(from: 0, to: inputs.count, by: 6) {
                let chunk = Array(inputs[chunkStart..<min(chunkStart + 6, inputs.count)])
                let groupNode = try buildTree(inputs: chunk, outputRank: outputRank + 1)
                groupOutputs.append(groupNode)
            }

            // Recurse on group outputs
            return try buildTree(inputs: groupOutputs, outputRank: outputRank)
        }

        let treeRoot = try buildTree(inputs: sources, outputRank: targetRank)
        try connect(from: treeRoot, to: target)
        return virtuals
    }

    // MARK: - Export to DagDBState

    /// Export graph to a DagDBState suitable for GPU evaluation.
    /// Nodes are mapped to grid cells. Grid must be large enough.
    public func exportState(grid: HexGrid) throws -> DagDBState {
        guard nodeCount <= grid.nodeCount else {
            throw GraphError.gridTooSmall(
                "Graph has \(nodeCount) nodes but grid has \(grid.nodeCount)"
            )
        }

        var state = DagDBState(width: grid.width, height: grid.height)

        // Map graph nodes to grid cells (first N cells in Morton order)
        for node in nodes {
            let idx = node.id  // graph node ID = Morton rank in grid
            state.rank[idx] = node.rank
            state.setLUT6(at: idx, value: node.lut6)
            state.truthState[idx] = node.truthState
            state.nodeType[idx] = node.nodeType.rawValue
        }

        // Wire edges via a custom neighbor override buffer
        // Since logical edges don't follow hex geometry, we override
        // the neighbor table for nodes that have explicit edges
        for node in nodes {
            let idx = node.id
            for (dir, _) in node.edges.enumerated() {
                state.edgeWeights[idx * 6 + dir] = 1.0
            }
        }

        return state
    }

    /// Export a custom neighbor table that reflects logical edges, not hex geometry.
    /// Returns [Int32] of size nodeCount * 6, suitable for Metal buffer.
    public func exportNeighborTable(nodeCount gridNodeCount: Int) -> [Int32] {
        var nb = [Int32](repeating: -1, count: gridNodeCount * 6)
        for node in nodes {
            let idx = node.id
            for (dir, sourceId) in node.edges.enumerated() {
                nb[idx * 6 + dir] = Int32(sourceId)
            }
        }
        return nb
    }

    // MARK: - Lookup

    public func node(labeled label: String) -> Node? {
        guard let id = labelIndex[label] else { return nil }
        return nodes[id]
    }

    public func nodeId(labeled label: String) -> Int? {
        return labelIndex[label]
    }

    // MARK: - Validation

    /// Validate graph structure: all edges respect rank ordering, no node exceeds 6 edges.
    public func validate() -> [String] {
        var errors: [String] = []
        for node in nodes {
            if node.edges.count > 6 {
                errors.append("Node \(node.id) (\(node.label)) has \(node.edges.count) edges (max 6)")
            }
            for src in node.edges {
                if src >= nodes.count {
                    errors.append("Node \(node.id) references non-existent source \(src)")
                } else if nodes[src].rank <= node.rank {
                    errors.append("Edge \(src) → \(node.id): source rank \(nodes[src].rank) must be > target rank \(node.rank)")
                }
            }
        }
        return errors
    }

    /// Print graph summary.
    public func describe() -> String {
        var lines: [String] = []
        lines.append("DagDBGraph: \(nodeCount) nodes, maxRank=\(maxRank)")
        let byRank = Dictionary(grouping: nodes, by: { $0.rank })
        for rank in byRank.keys.sorted() {
            let group = byRank[rank]!
            let types = group.map { "\($0.label)(\($0.nodeType))" }.joined(separator: ", ")
            lines.append("  Rank \(rank): \(group.count) nodes — \(types)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Errors

    public enum GraphError: Error, CustomStringConvertible {
        case nodeNotFound
        case rankViolation(String)
        case degreeOverflow(String)
        case gridTooSmall(String)

        public var description: String {
            switch self {
            case .nodeNotFound: return "Node not found"
            case .rankViolation(let msg): return "Rank violation: \(msg)"
            case .degreeOverflow(let msg): return "Degree overflow: \(msg)"
            case .gridTooSmall(let msg): return "Grid too small: \(msg)"
            }
        }
    }
}
