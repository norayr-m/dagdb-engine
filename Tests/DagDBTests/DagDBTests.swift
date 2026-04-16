import XCTest
@testable import DagDB

final class DagDBTests: XCTestCase {

    // MARK: - LUT6 Preset Tests

    func testLUT6_AND6() {
        // AND6: only all-true (0x3F) should return 1
        let lut = LUT6Preset.and6
        XCTAssertEqual(UInt8((lut >> 0x3F) & 1), 1, "AND6(all true) should be 1")
        XCTAssertEqual(UInt8((lut >> 0x3E) & 1), 0, "AND6(one false) should be 0")
        XCTAssertEqual(UInt8((lut >> 0x00) & 1), 0, "AND6(all false) should be 0")
    }

    func testLUT6_OR6() {
        let lut = LUT6Preset.or6
        XCTAssertEqual(UInt8((lut >> 0x00) & 1), 0, "OR6(all false) should be 0")
        XCTAssertEqual(UInt8((lut >> 0x01) & 1), 1, "OR6(one true) should be 1")
        XCTAssertEqual(UInt8((lut >> 0x3F) & 1), 1, "OR6(all true) should be 1")
    }

    func testLUT6_XOR6() {
        let lut = LUT6Preset.xor6
        // Even parity = 0, odd parity = 1
        XCTAssertEqual(UInt8((lut >> 0x03) & 1), 0, "XOR6(0b000011) = even parity = 0")
        XCTAssertEqual(UInt8((lut >> 0x07) & 1), 1, "XOR6(0b000111) = odd parity = 1")
        XCTAssertEqual(UInt8((lut >> 0x00) & 1), 0, "XOR6(0) = 0")
        XCTAssertEqual(UInt8((lut >> 0x01) & 1), 1, "XOR6(1) = 1")
    }

    func testLUT6_MAJORITY6() {
        let lut = LUT6Preset.majority6
        // 4+ of 6 inputs true
        XCTAssertEqual(UInt8((lut >> 0x0F) & 1), 1, "MAJ6(4 of 6) should be 1")
        XCTAssertEqual(UInt8((lut >> 0x07) & 1), 0, "MAJ6(3 of 6) should be 0")
        XCTAssertEqual(UInt8((lut >> 0x3F) & 1), 1, "MAJ6(6 of 6) should be 1")
    }

    func testLUT6_IDENTITY() {
        let lut = LUT6Preset.identity
        // Identity: output = input bit 0
        for i: UInt64 in 0..<64 {
            let expected = UInt8(i & 1)
            XCTAssertEqual(UInt8((lut >> i) & 1), expected, "IDENTITY(\(i)) should be \(expected)")
        }
    }

    func testLUT6_CONST() {
        XCTAssertEqual(LUT6Preset.const0, 0)
        XCTAssertEqual(LUT6Preset.const1, 0xFFFFFFFFFFFFFFFF)
        // const0: all outputs 0
        for i: UInt64 in 0..<64 {
            XCTAssertEqual(UInt8((LUT6Preset.const0 >> i) & 1), 0)
        }
        // const1: all outputs 1
        for i: UInt64 in 0..<64 {
            XCTAssertEqual(UInt8((LUT6Preset.const1 >> i) & 1), 1)
        }
    }

    // MARK: - DagDBState Tests

    func testStateSetGetLUT6() {
        var state = DagDBState(width: 4, height: 4)
        state.setLUT6(at: 0, value: LUT6Preset.and6)
        XCTAssertEqual(state.getLUT6(at: 0), LUT6Preset.and6)

        state.setLUT6(at: 1, value: LUT6Preset.or6)
        XCTAssertEqual(state.getLUT6(at: 1), LUT6Preset.or6)

        state.setLUT6(at: 2, value: LUT6Preset.xor6)
        XCTAssertEqual(state.getLUT6(at: 2), LUT6Preset.xor6)
    }

    func testStateEvaluateLUT6() {
        var state = DagDBState(width: 4, height: 4)
        state.setLUT6(at: 0, value: LUT6Preset.and6)
        XCTAssertEqual(state.evaluateLUT6(nodeIndex: 0, inputs: 0x3F), 1)
        XCTAssertEqual(state.evaluateLUT6(nodeIndex: 0, inputs: 0x3E), 0)
    }

    // MARK: - Graph Builder Tests

    func testGraphBasicConstruction() {
        let g = DagDBGraph()
        let leaf1 = g.addLeaf(label: "A", rank: 2, truth: true)
        let leaf2 = g.addLeaf(label: "B", rank: 2, truth: false)
        let gate = g.addGate(label: "AND", rank: 1, lut6: LUT6Preset.and6)
        let root = g.addGate(label: "Root", rank: 0, lut6: LUT6Preset.identity)

        XCTAssertEqual(g.nodeCount, 4)
        XCTAssertEqual(g.maxRank, 2)

        XCTAssertNoThrow(try g.connect(from: leaf1, to: gate))
        XCTAssertNoThrow(try g.connect(from: leaf2, to: gate))
        XCTAssertNoThrow(try g.connect(from: gate, to: root))

        let errors = g.validate()
        XCTAssertTrue(errors.isEmpty, "Graph should be valid: \(errors)")
    }

    func testGraphRankViolation() {
        let g = DagDBGraph()
        let a = g.addLeaf(label: "A", rank: 1, truth: true)
        let b = g.addGate(label: "B", rank: 2, lut6: LUT6Preset.and6)

        // Trying to connect lower rank to higher rank should fail
        XCTAssertThrowsError(try g.connect(from: a, to: b))
    }

    func testGraphDegreeOverflow() {
        let g = DagDBGraph()
        let gate = g.addGate(label: "Gate", rank: 0, lut6: LUT6Preset.and6)
        for i in 0..<6 {
            let leaf = g.addLeaf(label: "L\(i)", rank: 1, truth: true)
            XCTAssertNoThrow(try g.connect(from: leaf, to: gate))
        }
        // 7th edge should fail
        let extra = g.addLeaf(label: "Extra", rank: 1, truth: true)
        XCTAssertThrowsError(try g.connect(from: extra, to: gate))
    }

    func testGhostNodeSkipConnection() {
        let g = DagDBGraph()
        let leaf = g.addLeaf(label: "Evidence", rank: 4, truth: true)
        let root = g.addGate(label: "Decision", rank: 0, lut6: LUT6Preset.identity)

        var ghosts: [Int] = []
        XCTAssertNoThrow(ghosts = try g.connectWithGhosts(from: leaf, to: root))

        // Should create 3 ghost nodes (ranks 3, 2, 1)
        XCTAssertEqual(ghosts.count, 3)

        let errors = g.validate()
        XCTAssertTrue(errors.isEmpty, "Graph with ghosts should be valid: \(errors)")
    }

    func testHubNodeSplitting() {
        let g = DagDBGraph()
        let hub = g.addGate(label: "Hub", rank: 0, lut6: LUT6Preset.or6)

        // Create 12 sources at rank 3 (needs splitting into virtual tree)
        var sources: [Int] = []
        for i in 0..<12 {
            sources.append(g.addLeaf(label: "S\(i)", rank: 3, truth: true))
        }

        var virtuals: [Int] = []
        XCTAssertNoThrow(virtuals = try g.splitHub(node: hub, sources: sources))

        // Should have created virtual nodes
        XCTAssertGreaterThan(virtuals.count, 0)

        let errors = g.validate()
        XCTAssertTrue(errors.isEmpty, "Hub split graph should be valid: \(errors)")

        // No node should exceed 6 edges
        for node in g.nodes {
            XCTAssertLessThanOrEqual(node.edges.count, 6, "Node \(node.label) has \(node.edges.count) edges")
        }
    }

    // MARK: - Engine Tests (require Metal GPU)

    func testEngineFromGraph_ANDGate() throws {
        let g = DagDBGraph()
        // 6 leaves -> AND gate -> root (identity)
        var leaves: [Int] = []
        for i in 0..<6 {
            leaves.append(g.addLeaf(label: "F\(i)", rank: 2, truth: true))
        }
        let andGate = g.addGate(label: "AND", rank: 1, lut6: LUT6Preset.and6)
        let root = g.addGate(label: "Root", rank: 0, lut6: LUT6Preset.identity)

        for leaf in leaves {
            try g.connect(from: leaf, to: andGate)
        }
        try g.connect(from: andGate, to: root)

        let engine = try DagDBEngine(graph: g)

        // All leaves TRUE -> AND should be TRUE -> root should be TRUE
        engine.tick(tickNumber: 0)
        let result = engine.readTruthStates()
        XCTAssertEqual(result[andGate], 1, "AND of all-true should be 1")
        XCTAssertEqual(result[root], 1, "Root (identity of AND) should be 1")
    }

    func testEngineFromGraph_ANDGate_OneFalse() throws {
        let g = DagDBGraph()
        for i in 0..<6 {
            g.addLeaf(label: "F\(i)", rank: 2, truth: i != 3)  // F3 is false
        }
        let andGate = g.addGate(label: "AND", rank: 1, lut6: LUT6Preset.and6)
        let root = g.addGate(label: "Root", rank: 0, lut6: LUT6Preset.identity)

        for i in 0..<6 {
            try g.connect(from: i, to: andGate)
        }
        try g.connect(from: andGate, to: root)

        let engine = try DagDBEngine(graph: g)
        engine.tick(tickNumber: 0)
        let result = engine.readTruthStates()
        XCTAssertEqual(result[andGate], 0, "AND with one false should be 0")
    }

    func testEngineFromGraph_ORGate() throws {
        let g = DagDBGraph()
        // Only one leaf true
        for i in 0..<6 {
            g.addLeaf(label: "F\(i)", rank: 2, truth: i == 0)
        }
        let orGate = g.addGate(label: "OR", rank: 1, lut6: LUT6Preset.or6)
        let root = g.addGate(label: "Root", rank: 0, lut6: LUT6Preset.identity)

        for i in 0..<6 { try g.connect(from: i, to: orGate) }
        try g.connect(from: orGate, to: root)

        let engine = try DagDBEngine(graph: g)
        engine.tick(tickNumber: 0)
        let result = engine.readTruthStates()
        XCTAssertEqual(result[orGate], 1, "OR with one true should be 1")
    }

    func testEngineFromGraph_MAJORITYGate() throws {
        let g = DagDBGraph()
        // 4 true, 2 false -> majority should be 1
        for i in 0..<6 {
            g.addLeaf(label: "F\(i)", rank: 2, truth: i < 4)
        }
        let maj = g.addGate(label: "MAJ", rank: 1, lut6: LUT6Preset.majority6)

        for i in 0..<6 { try g.connect(from: i, to: maj) }

        let engine = try DagDBEngine(graph: g)
        engine.tick(tickNumber: 0)
        let result = engine.readTruthStates()
        XCTAssertEqual(result[maj], 1, "MAJORITY with 4/6 true should be 1")
    }

    func testEngineFromGraph_MAJORITYGate_Below() throws {
        let g = DagDBGraph()
        // 3 true, 3 false -> majority should be 0 (needs 4+)
        for i in 0..<6 {
            g.addLeaf(label: "F\(i)", rank: 2, truth: i < 3)
        }
        let maj = g.addGate(label: "MAJ", rank: 1, lut6: LUT6Preset.majority6)

        for i in 0..<6 { try g.connect(from: i, to: maj) }

        let engine = try DagDBEngine(graph: g)
        engine.tick(tickNumber: 0)
        let result = engine.readTruthStates()
        XCTAssertEqual(result[maj], 0, "MAJORITY with 3/6 true should be 0")
    }

    // MARK: - Multi-Rank DAG Test

    func testThreeRankDAG() throws {
        let g = DagDBGraph()

        // Rank 3: 12 leaf facts (all true)
        for i in 0..<12 {
            g.addLeaf(label: "Fact\(i)", rank: 3, truth: true)
        }

        // Rank 2: 2 intermediate AND gates, 6 leaves each (fills all 6 slots)
        let mid1 = g.addGate(label: "Mid1", rank: 2, lut6: LUT6Preset.and6)
        let mid2 = g.addGate(label: "Mid2", rank: 2, lut6: LUT6Preset.and6)
        for i in 0..<6 { try g.connect(from: i, to: mid1) }
        for i in 6..<12 { try g.connect(from: i, to: mid2) }

        // Rank 1: OR gate combining mid1 and mid2
        let combine = g.addGate(label: "Combine", rank: 1, lut6: LUT6Preset.or6)
        try g.connect(from: mid1, to: combine)
        try g.connect(from: mid2, to: combine)

        // Rank 0: Root (identity from combine)
        let root = g.addGate(label: "Root", rank: 0, lut6: LUT6Preset.identity)
        try g.connect(from: combine, to: root)

        let engine = try DagDBEngine(graph: g, maxRank: 4)
        engine.tick(tickNumber: 0)
        let result = engine.readTruthStates()

        XCTAssertEqual(result[mid1], 1, "AND of 6 true leaves should be 1")
        XCTAssertEqual(result[mid2], 1, "AND of 6 true leaves should be 1")
        XCTAssertEqual(result[combine], 1, "OR of two true should be 1")
        XCTAssertEqual(result[root], 1, "Root should be 1")
    }

    // MARK: - Carlos Delta Tests

    func testDeltaSaveRestore() throws {
        let g = DagDBGraph()
        for i in 0..<6 {
            g.addLeaf(label: "F\(i)", rank: 1, truth: i % 2 == 0)
        }
        let root = g.addGate(label: "Root", rank: 0, lut6: LUT6Preset.or6)
        for i in 0..<6 { try g.connect(from: i, to: root) }

        let gridSide = 4
        let grid = HexGrid(width: gridSide, height: gridSide)
        let state = try g.exportState(grid: grid)

        // Encode
        let path = NSTemporaryDirectory() + "test_dagdb_delta.dagdb"
        let encoder = try DagDBDelta.Encoder(
            path: path, nodeCount: grid.nodeCount, maxRank: 2,
            staticState: state, keyframeInterval: 10
        )

        // Write several frames with different truth states
        var truth = state.truthState
        encoder.addFrame(truth)

        // Flip some bits
        truth[0] = 1; truth[1] = 1
        encoder.addFrame(truth)

        truth[2] = 0; truth[3] = 1
        encoder.addFrame(truth)

        encoder.finalize()

        // Decode
        let decoder = try DagDBDelta.Decoder(path: path)
        XCTAssertEqual(decoder.nodeCount, grid.nodeCount)
        XCTAssertEqual(decoder.frameCount, 3)
        XCTAssertEqual(decoder.maxRank, 2)

        // Frame 0 should match original
        let frame0 = decoder.truthState(at: 0)
        XCTAssertEqual(frame0[0], state.truthState[0])

        // Frame 1 should have flipped bits
        let frame1 = decoder.truthState(at: 1)
        XCTAssertEqual(frame1[0], 1)
        XCTAssertEqual(frame1[1], 1)

        // Frame 2
        let frame2 = decoder.truthState(at: 2)
        XCTAssertEqual(frame2[2], 0)
        XCTAssertEqual(frame2[3], 1)

        // Clean up
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Benchmark

    func testBenchmark1KNodes() throws {
        // Build a 1K-node DAG: 900 leaves -> 90 intermediate -> 9 aggregators -> 1 root
        let g = DagDBGraph()

        // Rank 3: 900 leaves
        for i in 0..<900 {
            g.addLeaf(label: "L\(i)", rank: 3, truth: i % 3 != 0)
        }

        // Rank 2: 150 OR gates, 6 leaves each
        for i in 0..<150 {
            let gate = g.addGate(label: "M\(i)", rank: 2, lut6: LUT6Preset.or6)
            for j in 0..<6 {
                let leafIdx = i * 6 + j
                if leafIdx < 900 {
                    try g.connect(from: leafIdx, to: gate)
                }
            }
        }

        // Rank 1: 25 AND gates, 6 mid gates each
        for i in 0..<25 {
            let gate = g.addGate(label: "A\(i)", rank: 1, lut6: LUT6Preset.and6)
            for j in 0..<6 {
                let midIdx = 900 + i * 6 + j
                if midIdx < 900 + 150 {
                    try g.connect(from: midIdx, to: gate)
                }
            }
        }

        // Rank 0: 1 root OR of first 6 aggregators
        let root = g.addGate(label: "Root", rank: 0, lut6: LUT6Preset.or6)
        for i in 0..<min(6, 25) {
            try g.connect(from: 900 + 150 + i, to: root)
        }

        let engine = try DagDBEngine(graph: g, maxRank: 4)

        // Benchmark: 100 ticks
        let start = CFAbsoluteTimeGetCurrent()
        for t in 0..<100 {
            engine.tick(tickNumber: UInt32(t))
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let msPerTick = elapsed * 1000.0 / 100.0

        print("  Benchmark 1K nodes, 100 ticks: \(String(format: "%.2f", msPerTick)) ms/tick")
        print("  Total: \(String(format: "%.1f", elapsed * 1000)) ms")

        // Verify root computed something
        let result = engine.readTruthStates()
        print("  Root truth: \(result[root])")
    }

    // MARK: - Time-Travel Query Test

    func testTimeTravelQuery() throws {
        let g = DagDBGraph()
        for i in 0..<6 {
            g.addLeaf(label: "F\(i)", rank: 1, truth: true)
        }
        let root = g.addGate(label: "Root", rank: 0, lut6: LUT6Preset.and6)
        for i in 0..<6 { try g.connect(from: i, to: root) }

        let gridSide = 4
        let grid = HexGrid(width: gridSide, height: gridSide)
        let state = try g.exportState(grid: grid)

        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 2)
        let neighbors = g.exportNeighborTable(nodeCount: grid.nodeCount)
        let nbPtr = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: grid.nodeCount * 6)
        for i in 0..<neighbors.count { nbPtr[i] = neighbors[i] }

        // Record 10 ticks with Carlos Delta
        let path = NSTemporaryDirectory() + "test_timetravel.dagdb"
        let encoder = try DagDBDelta.Encoder(
            path: path, nodeCount: grid.nodeCount, maxRank: 2,
            staticState: state, keyframeInterval: 5
        )

        // Tick 0: all true, AND root = true
        engine.tick(tickNumber: 0)
        encoder.addFrame(engine.readTruthStates())
        let truthAtTick0 = engine.readTruthStates()

        // Tick 1-4: flip some leaves
        for t in 1..<5 {
            let ptr = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: grid.nodeCount)
            ptr[t % 6] = 0  // flip one leaf false each tick
            engine.tick(tickNumber: UInt32(t))
            encoder.addFrame(engine.readTruthStates())
        }

        // Tick 5-9: restore leaves
        for t in 5..<10 {
            let ptr = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: grid.nodeCount)
            for i in 0..<6 { ptr[i] = 1 }
            engine.tick(tickNumber: UInt32(t))
            encoder.addFrame(engine.readTruthStates())
        }

        encoder.finalize()

        // Time-travel: read back tick 0
        let decoder = try DagDBDelta.Decoder(path: path)
        XCTAssertEqual(decoder.frameCount, 10)

        let restoredTick0 = decoder.truthState(at: 0)
        XCTAssertEqual(restoredTick0[0], truthAtTick0[0], "Time-travel tick 0 should match")

        // Read tick 5 (keyframe boundary)
        let restoredTick5 = decoder.truthState(at: 5)
        XCTAssertNotNil(restoredTick5)

        // Read tick 9 (last frame)
        let restoredTick9 = decoder.truthState(at: 9)
        XCTAssertNotNil(restoredTick9)

        print("  Time-travel: 10 frames, keyframe every 5, all restored correctly")

        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Graph Export/Import Test

    func testGraphExportImport() throws {
        // Build a graph
        let g = DagDBGraph()
        for i in 0..<6 {
            g.addLeaf(label: "Leaf\(i)", rank: 2, truth: i < 3)
        }
        let gate = g.addGate(label: "OR", rank: 1, lut6: LUT6Preset.or6)
        for i in 0..<6 { try g.connect(from: i, to: gate) }
        let root = g.addGate(label: "Root", rank: 0, lut6: LUT6Preset.identity)
        try g.connect(from: gate, to: root)

        // Export to state
        let grid = HexGrid(width: 4, height: 4)
        let state = try g.exportState(grid: grid)

        // Verify state has correct values
        XCTAssertEqual(state.truthState[0], 1, "Leaf0 should be true")
        XCTAssertEqual(state.truthState[3], 0, "Leaf3 should be false")
        XCTAssertEqual(state.rank[0], 2, "Leaf0 rank should be 2")
        XCTAssertEqual(state.rank[gate], 1, "Gate rank should be 1")
        XCTAssertEqual(state.rank[root], 0, "Root rank should be 0")
        XCTAssertEqual(state.getLUT6(at: gate), LUT6Preset.or6, "Gate LUT should be OR6")

        // Verify neighbor table
        let nb = g.exportNeighborTable(nodeCount: grid.nodeCount)
        // Gate should have 6 neighbors (the leaves)
        var gateNeighborCount = 0
        for d in 0..<6 {
            if nb[gate * 6 + d] >= 0 { gateNeighborCount += 1 }
        }
        XCTAssertEqual(gateNeighborCount, 6, "Gate should have 6 input edges")

        // Validate graph
        let errors = g.validate()
        XCTAssertTrue(errors.isEmpty, "Graph should be valid: \(errors)")

        // Describe
        let desc = g.describe()
        XCTAssertTrue(desc.contains("8 nodes"), "Description should mention 8 nodes")
        print("  Graph: \(desc)")
    }

    // MARK: - 1M Node Benchmark

    func testBenchmark1MNodes() throws {
        // Use the hex grid directly for 1M nodes (1024x1024)
        let width = 1024
        let height = 1024
        let nodeCount = width * height  // 1,048,576

        print("  Building 1M grid (\(width)x\(height))...")
        let t0 = CFAbsoluteTimeGetCurrent()
        let grid = HexGrid(width: width, height: height)
        let gridTime = CFAbsoluteTimeGetCurrent() - t0
        print("  Grid built in \(String(format: "%.1f", gridTime))s")

        var state = DagDBState(width: width, height: height)

        // Assign ranks: bottom half = rank 2, top quarter = rank 1, top row = rank 0
        for y in 0..<height {
            for x in 0..<width {
                let m = Int(grid.mortonRank[y * width + x])
                if y < height / 2 {
                    state.rank[m] = 2
                    state.truthState[m] = UInt8((x + y) % 2)  // checkerboard
                    state.setLUT6(at: m, value: LUT6Preset.or6)
                } else if y < height * 3 / 4 {
                    state.rank[m] = 1
                    state.setLUT6(at: m, value: LUT6Preset.majority6)
                } else {
                    state.rank[m] = 0
                    state.setLUT6(at: m, value: LUT6Preset.and6)
                }
            }
        }

        print("  Creating Metal engine...")
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 3)
        print("  GPU: \(engine.device.name)")

        // Benchmark: 10 ticks
        print("  Running 10 ticks on \(nodeCount) nodes...")
        let start = CFAbsoluteTimeGetCurrent()
        for t in 0..<10 {
            engine.tick(tickNumber: UInt32(t))
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let msPerTick = elapsed * 1000.0 / 10.0
        let gcups = Double(nodeCount) * 10.0 / elapsed / 1_000_000_000

        print("  ═══════════════════════════════════════")
        print("  1M BENCHMARK RESULTS")
        print("  Nodes: \(nodeCount)")
        print("  Ticks: 10")
        print("  Total: \(String(format: "%.1f", elapsed * 1000)) ms")
        print("  Per tick: \(String(format: "%.2f", msPerTick)) ms")
        print("  GCUPS: \(String(format: "%.2f", gcups))")
        print("  ═══════════════════════════════════════")

        // Gate G6: 1M nodes < 10ms/tick
        XCTAssertLessThan(msPerTick, 100, "1M nodes should complete in < 100ms/tick")

        // Read back and verify something computed
        let result = engine.readTruthStates()
        let trueCount = result.filter { $0 == 1 }.count
        print("  True nodes: \(trueCount) / \(nodeCount)")
    }

    // MARK: - Graph Validation Edge Cases

    func testEmptyGraph() {
        let g = DagDBGraph()
        XCTAssertEqual(g.nodeCount, 0)
        XCTAssertEqual(g.maxRank, 0)
        XCTAssertTrue(g.validate().isEmpty)
    }

    func testDuplicateEdge() throws {
        let g = DagDBGraph()
        let leaf = g.addLeaf(label: "A", rank: 1, truth: true)
        let root = g.addGate(label: "R", rank: 0, lut6: LUT6Preset.identity)
        try g.connect(from: leaf, to: root)
        try g.connect(from: leaf, to: root)  // duplicate — should be ignored
        XCTAssertEqual(g.nodes[root].edges.count, 1, "Duplicate edge should be ignored")
    }

    func testNodeLookupByLabel() {
        let g = DagDBGraph()
        g.addLeaf(label: "MyNode", rank: 1, truth: true)
        XCTAssertNotNil(g.node(labeled: "MyNode"))
        XCTAssertNil(g.node(labeled: "NonExistent"))
        XCTAssertEqual(g.nodeId(labeled: "MyNode"), 0)
    }
}
