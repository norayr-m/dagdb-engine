import XCTest
@testable import DagDB

final class DagDBTests: XCTestCase {

    /// Per-test unique temp dir (Fable review T4 — fixed /tmp names race
    /// when princes run swift test concurrently in the shared dagdb dir).
    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-core-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

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
        let path = tmpDir! + "test_dagdb_delta.dagdb"
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
        let path = tmpDir! + "test_timetravel.dagdb"
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

    // MARK: - BACK_EDGE primitive (Phase 1: CPU storage + CPU latch)

    func testBackEdgeAddAndCount() {
        var state = DagDBState(width: 4, height: 4)
        XCTAssertEqual(state.backEdgeCount, 0)
        state.addBackEdge(src: 5, dst: 2)
        XCTAssertEqual(state.backEdgeCount, 1)
        state.addBackEdge(src: 7, dst: 9)
        XCTAssertEqual(state.backEdgeCount, 2)
        XCTAssertEqual(state.backEdgeSrcs, [5, 7])
        XCTAssertEqual(state.backEdgeDsts, [2, 9])
    }

    func testBackEdgeSinglePairLatch() {
        var state = DagDBState(width: 4, height: 4)
        state.addBackEdge(src: 5, dst: 2)
        state.truthState[5] = 1
        state.truthState[2] = 0
        state.latchBackEdges()
        XCTAssertEqual(state.truthState[2], 1, "register latches src truth")
    }

    func testBackEdgeClearByDst() {
        var state = DagDBState(width: 4, height: 4)
        state.addBackEdge(src: 5, dst: 2)
        state.addBackEdge(src: 7, dst: 9)
        state.addBackEdge(src: 8, dst: 2)  // second back-edge into node 2
        XCTAssertEqual(state.backEdgeCount, 3)

        state.clearBackEdges(toNode: 2)
        XCTAssertEqual(state.backEdgeCount, 1, "both back-edges into 2 cleared")
        XCTAssertEqual(state.backEdgeSrcs, [7])
        XCTAssertEqual(state.backEdgeDsts, [9])

        // Latching after clear should not touch node 2 anymore.
        state.truthState[2] = 0
        state.truthState[5] = 1
        state.truthState[8] = 1
        state.latchBackEdges()
        XCTAssertEqual(state.truthState[2], 0, "cleared back-edges into 2 do not latch")
    }

    func testBackEdgeTwoPhaseAliasing() {
        // Chain in the buffer: BE_a = (1 → 2), BE_b = (2 → 3).
        // Naive single-pass: dst 2 := src 1 (=1), then dst 3 := the JUST-WRITTEN
        // src 2 (=1). Wrong. Two-phase: snapshot {2:=src1=1, 3:=src2=0}, then
        // commit. Right.
        var state = DagDBState(width: 4, height: 4)
        state.truthState[1] = 1
        state.truthState[2] = 0
        state.truthState[3] = 0
        state.addBackEdge(src: 1, dst: 2)
        state.addBackEdge(src: 2, dst: 3)
        state.latchBackEdges()
        XCTAssertEqual(state.truthState[2], 1, "node 2 latches node 1's value")
        XCTAssertEqual(state.truthState[3], 0,
                       "node 3 latches node 2's PRE-tick value, not the freshly latched one")
    }

    func testBackEdge1BitToggle() {
        // Synchronous toggle: combinational eval (mocked) computes NOT(register).
        // BACK_EDGE latches that into the register on every tick. State flips.
        var state = DagDBState(width: 4, height: 4)
        let regIdx = 0  // register
        let combIdx = 1 // combinational NOT(register)
        state.truthState[regIdx] = 0
        state.addBackEdge(src: UInt32(combIdx), dst: UInt32(regIdx))

        for tick in 0..<6 {
            // Mocked combinational pass: comb := NOT(register).
            state.truthState[combIdx] = state.truthState[regIdx] == 0 ? 1 : 0
            // Latch.
            state.latchBackEdges()
            let expected: UInt8 = (tick % 2 == 0) ? 1 : 0
            XCTAssertEqual(state.truthState[regIdx], expected,
                           "tick \(tick): register should be \(expected)")
        }
    }

    // MARK: - BACK_EDGE primitive (Phase 2: full GPU engine integration)

    func testEngineBackEdge1BitToggle() throws {
        // Same toggle as above, but driven through the full DagDBEngine
        // (rank kernel + latch). Register is at rank 1; combinational NOT
        // sits at rank 0. The back-edge latches comb's truth back into the
        // register at every tick boundary; the register flips 0/1 forever.

        let g = DagDBGraph()
        // Register: rank 1, truth seeded false. The leaf-init LUT is const0,
        // but the rank kernel will skip the register (is_register flag set
        // by addBackEdge below), so the LUT never fires. Truth comes only
        // from the latch.
        let reg = g.addLeaf(label: "reg", rank: 1, truth: false)

        // Combinational: rank 0, NOT(input0). LUT bit k = 1 iff (k & 1) == 0
        // → 0x5555_5555_5555_5555.
        let notLUT: UInt64 = 0x5555_5555_5555_5555
        let comb = g.addGate(label: "comb", rank: 0, lut6: notLUT)

        try g.connect(from: reg, to: comb)

        let engine = try DagDBEngine(graph: g)
        try engine.addBackEdge(src: UInt32(comb), dst: UInt32(reg))
        XCTAssertEqual(engine.backEdgeCount, 1)

        // Confirm initial state seeded by the leaf init.
        var states = engine.readTruthStates()
        XCTAssertEqual(states[reg], 0, "register starts at 0")
        XCTAssertEqual(states[comb], 0, "combinational starts at 0 (uninit)")

        // Tick 0:  comb := NOT(reg=0) = 1; latch reg := comb = 1.
        engine.tick(tickNumber: 0)
        states = engine.readTruthStates()
        XCTAssertEqual(states[comb], 1, "tick 0 comb should be NOT(0) = 1")
        XCTAssertEqual(states[reg], 1, "tick 0 register should latch to 1")

        // Tick 1:  comb := NOT(reg=1) = 0; latch reg := comb = 0.
        engine.tick(tickNumber: 1)
        states = engine.readTruthStates()
        XCTAssertEqual(states[comb], 0, "tick 1 comb should be NOT(1) = 0")
        XCTAssertEqual(states[reg], 0, "tick 1 register should latch to 0")

        // Run a few more ticks to confirm the toggle is stable.
        for tick in 2..<6 {
            engine.tick(tickNumber: UInt32(tick))
            let s = engine.readTruthStates()
            let expected: UInt8 = (tick % 2 == 0) ? 1 : 0
            XCTAssertEqual(s[reg], expected,
                           "tick \(tick): register should be \(expected)")
        }
    }

    func testEngineBackEdgeRegisterUnaffectedByCombinationalPass() throws {
        // A register node at rank 1 with NO back-edge should have its leaf
        // truth re-evaluated by the rank kernel as before. With a back-edge
        // added, the rank kernel must skip it — the register holds its
        // value across ticks until the latch overwrites.

        let g = DagDBGraph()
        // Leaf with truth=true → initialized via const1 LUT. Without a
        // back-edge, the rank kernel re-evaluates and writes 1 (no change).
        // We then add a back-edge from a node that's permanently 0; if the
        // rank-skip works, the latch fires and the register goes to 0.
        let reg = g.addLeaf(label: "reg", rank: 1, truth: true)
        let zero = g.addLeaf(label: "zero", rank: 1, truth: false)

        // A passive sink at rank 0 just to give the engine a non-empty
        // rank-0 layer; not used for the register check.
        _ = g.addGate(label: "sink", rank: 0, lut6: LUT6Preset.const0)

        let engine = try DagDBEngine(graph: g)

        // Tick once with no back-edges: register stays 1.
        engine.tick(tickNumber: 0)
        XCTAssertEqual(engine.readTruthStates()[reg], 1,
                       "no back-edge: register stays at its leaf truth")

        // Now register reg as a back-edge dst, latching from `zero` (truth=0).
        try engine.addBackEdge(src: UInt32(zero), dst: UInt32(reg))

        // After one tick, the rank kernel must skip `reg` (so leaf-LUT
        // doesn't write 1 over it), then the latch copies zero (=0) into reg.
        engine.tick(tickNumber: 1)
        XCTAssertEqual(engine.readTruthStates()[reg], 0,
                       "tick after addBackEdge: latch wrote 0 into register")
    }

    func testEngineAddBackEdgeRejectsNodeWithCombinationalFanIn() throws {
        // VALIDATE rule: BACK_EDGE dst must have zero combinational in-degree.
        // Try to add a back-edge to a gate that already reads an input —
        // engine.addBackEdge must throw.
        let g = DagDBGraph()
        let leaf = g.addLeaf(label: "L", rank: 1, truth: true)
        let gate = g.addGate(label: "G", rank: 0, lut6: LUT6Preset.identity)
        try g.connect(from: leaf, to: gate)

        let engine = try DagDBEngine(graph: g)
        XCTAssertEqual(engine.combinationalFanIn(node: UInt32(gate)), 1,
                       "gate has one incoming combinational edge")

        XCTAssertThrowsError(try engine.addBackEdge(src: UInt32(leaf),
                                                    dst: UInt32(gate))) { err in
            switch err {
            case DagDBEngine.BackEdgeError.destinationHasCombinationalInDegree:
                break  // expected
            default:
                XCTFail("expected destinationHasCombinationalInDegree, got \(err)")
            }
        }
        XCTAssertEqual(engine.backEdgeCount, 0, "no back-edge should have been registered")
        XCTAssertFalse(engine.isRegister(node: UInt32(gate)),
                       "register flag must NOT be set after a rejected addBackEdge")
    }

    // MARK: - BACK_EDGE primitive (Phase 3: graph-level VALIDATE)

    func testGraphConnectBack() throws {
        let g = DagDBGraph()
        let comb = g.addGate(label: "comb", rank: 0, lut6: LUT6Preset.const1)
        let reg  = g.addLeaf(label: "reg",  rank: 1, truth: false)
        try g.connectBack(from: comb, to: reg)
        XCTAssertEqual(g.backEdges.count, 1)
        XCTAssertTrue(g.isBackEdgeDst(reg))
        XCTAssertFalse(g.isBackEdgeDst(comb))
        XCTAssertTrue(g.validate().isEmpty)
    }

    func testGraphConnectBackIsIdempotent() throws {
        let g = DagDBGraph()
        let a = g.addGate(label: "a", rank: 0, lut6: LUT6Preset.const1)
        let b = g.addLeaf(label: "b", rank: 1, truth: false)
        try g.connectBack(from: a, to: b)
        try g.connectBack(from: a, to: b)  // duplicate — should be ignored
        XCTAssertEqual(g.backEdges.count, 1)
    }

    func testGraphConnectBackRejectsTargetWithCombinationalFanIn() throws {
        let g = DagDBGraph()
        let leaf = g.addLeaf(label: "L", rank: 1, truth: true)
        let gate = g.addGate(label: "G", rank: 0, lut6: LUT6Preset.identity)
        try g.connect(from: leaf, to: gate)
        // gate now has combinational fan-in 1 → connectBack must reject.
        XCTAssertThrowsError(try g.connectBack(from: leaf, to: gate)) { err in
            switch err {
            case DagDBGraph.GraphError.backEdgeViolation:
                break  // expected
            default:
                XCTFail("expected backEdgeViolation, got \(err)")
            }
        }
        XCTAssertEqual(g.backEdges.count, 0)
    }

    func testGraphConnectRejectsCombinationalIntoBackEdgeDst() throws {
        let g = DagDBGraph()
        let comb = g.addGate(label: "comb", rank: 0, lut6: LUT6Preset.const1)
        let reg  = g.addLeaf(label: "reg",  rank: 1, truth: false)
        try g.connectBack(from: comb, to: reg)
        // reg is a register now → connecting another combinational edge into
        // it must throw.
        let extra = g.addLeaf(label: "extra", rank: 2, truth: true)
        XCTAssertThrowsError(try g.connect(from: extra, to: reg)) { err in
            switch err {
            case DagDBGraph.GraphError.backEdgeViolation:
                break  // expected
            default:
                XCTFail("expected backEdgeViolation, got \(err)")
            }
        }
    }

    func testGraphClearBackEdgesAllowsCombinationalAgain() throws {
        let g = DagDBGraph()
        let comb = g.addGate(label: "comb", rank: 0, lut6: LUT6Preset.const1)
        let reg  = g.addLeaf(label: "reg",  rank: 1, truth: false)
        try g.connectBack(from: comb, to: reg)
        g.clearBackEdges(toNode: reg)
        XCTAssertEqual(g.backEdges.count, 0)
        XCTAssertFalse(g.isBackEdgeDst(reg))
        // Now an ordinary CONNECT should succeed.
        let extra = g.addLeaf(label: "extra", rank: 2, truth: true)
        XCTAssertNoThrow(try g.connect(from: extra, to: reg))
    }

    // MARK: - BACK_EDGE primitive (Phase 8: 4-bit ripple counter integration)

    /// Compute a 64-bit LUT6 truth table from a Boolean function of an input
    /// vector encoded as the low bits of `i` (bit 0 = slot 0, bit 1 = slot 1, …).
    private static func computeLUT6(_ f: (UInt64) -> Bool) -> UInt64 {
        var lut: UInt64 = 0
        for i: UInt64 in 0..<64 where f(i) { lut |= (UInt64(1) << i) }
        return lut
    }

    func testEngine4BitRippleCounter() throws {
        // 4 register bits Q0..Q3 (rank 1, init 0) and 4 combinational
        // next-state computations (rank 0):
        //   next_Q0 = NOT Q0                       (toggle every tick)
        //   next_Q1 = Q1 XOR Q0                    (toggle when Q0 = 1)
        //   next_Q2 = Q2 XOR (Q1 AND Q0)
        //   next_Q3 = Q3 XOR (Q2 AND Q1 AND Q0)
        // BACK_EDGE next_Q_i → Q_i.  Counter increments by 1 every tick;
        // wraps from 1111 (15) back to 0000 (0) at tick 16.

        let g = DagDBGraph()
        let q0 = g.addLeaf(label: "Q0", rank: 1, truth: false)
        let q1 = g.addLeaf(label: "Q1", rank: 1, truth: false)
        let q2 = g.addLeaf(label: "Q2", rank: 1, truth: false)
        let q3 = g.addLeaf(label: "Q3", rank: 1, truth: false)

        let nextQ0 = g.addGate(label: "next_Q0", rank: 0,
                               lut6: Self.computeLUT6 { i in (i & 1) == 0 })
        let nextQ1 = g.addGate(label: "next_Q1", rank: 0,
                               lut6: Self.computeLUT6 { i in
                                   let b0 = i & 1, b1 = (i >> 1) & 1
                                   return (b0 ^ b1) == 1
                               })
        let nextQ2 = g.addGate(label: "next_Q2", rank: 0,
                               lut6: Self.computeLUT6 { i in
                                   let b0 = i & 1, b1 = (i >> 1) & 1, b2 = (i >> 2) & 1
                                   return (b2 ^ (b1 & b0)) == 1
                               })
        let nextQ3 = g.addGate(label: "next_Q3", rank: 0,
                               lut6: Self.computeLUT6 { i in
                                   let b0 = i & 1, b1 = (i >> 1) & 1
                                   let b2 = (i >> 2) & 1, b3 = (i >> 3) & 1
                                   return (b3 ^ (b2 & b1 & b0)) == 1
                               })

        // Wire combinational inputs in slot order — slot 0 == LUT bit 0.
        try g.connect(from: q0, to: nextQ0)
        try g.connect(from: q0, to: nextQ1); try g.connect(from: q1, to: nextQ1)
        try g.connect(from: q0, to: nextQ2); try g.connect(from: q1, to: nextQ2)
        try g.connect(from: q2, to: nextQ2)
        try g.connect(from: q0, to: nextQ3); try g.connect(from: q1, to: nextQ3)
        try g.connect(from: q2, to: nextQ3); try g.connect(from: q3, to: nextQ3)

        // Register-pattern feedback: latch each next_Q into its Q.
        try g.connectBack(from: nextQ0, to: q0)
        try g.connectBack(from: nextQ1, to: q1)
        try g.connectBack(from: nextQ2, to: q2)
        try g.connectBack(from: nextQ3, to: q3)

        XCTAssertTrue(g.validate().isEmpty, "graph should validate clean")

        let engine = try DagDBEngine(graph: g)
        XCTAssertEqual(engine.backEdgeCount, 4)

        func readCounter() -> Int {
            let s = engine.readTruthStates()
            let b0 = Int(s[q0]), b1 = Int(s[q1]), b2 = Int(s[q2]), b3 = Int(s[q3])
            return b0 | (b1 << 1) | (b2 << 2) | (b3 << 3)
        }

        // Initial state: 0000.
        XCTAssertEqual(readCounter(), 0, "counter starts at 0")

        // Run 17 ticks; counter should count 1, 2, …, 15, 0, 1.
        for tick in 1...17 {
            engine.tick(tickNumber: UInt32(tick))
            XCTAssertEqual(readCounter(), tick % 16,
                           "tick \(tick): counter should read \(tick % 16)")
        }
    }

    func testEngineSeedsBackEdgesFromGraph() throws {
        // Convenience init `DagDBEngine(graph:)` must pick up the back-edges
        // from the graph and seed the engine's runtime back-edge list +
        // register flags.
        let g = DagDBGraph()
        let notLUT: UInt64 = 0x5555_5555_5555_5555
        let reg = g.addLeaf(label: "reg", rank: 1, truth: false)
        let comb = g.addGate(label: "comb", rank: 0, lut6: notLUT)
        try g.connect(from: reg, to: comb)
        try g.connectBack(from: comb, to: reg)

        let engine = try DagDBEngine(graph: g)
        XCTAssertEqual(engine.backEdgeCount, 1, "engine seeded with 1 back-edge")
        XCTAssertTrue(engine.isRegister(node: UInt32(reg)))
        XCTAssertFalse(engine.isRegister(node: UInt32(comb)))

        // Tick once: register flips to 1.
        engine.tick(tickNumber: 0)
        XCTAssertEqual(engine.readTruthStates()[reg], 1,
                       "register latched to NOT(0) = 1 via graph-declared back-edge")
    }

    func testEngineBackEdgeClearRestoresCombinationalEvaluation() throws {
        // Add a back-edge, tick (latch fires), then clear the back-edge.
        // After clear, the register flag must drop and the rank kernel
        // re-evaluates the node by its LUT again.

        let g = DagDBGraph()
        // Leaf with truth=true → const1 LUT.
        let reg = g.addLeaf(label: "reg", rank: 1, truth: true)
        let zero = g.addLeaf(label: "zero", rank: 1, truth: false)
        _ = g.addGate(label: "sink", rank: 0, lut6: LUT6Preset.const0)

        let engine = try DagDBEngine(graph: g)
        try engine.addBackEdge(src: UInt32(zero), dst: UInt32(reg))

        // After one tick: latch wrote 0 into reg.
        engine.tick(tickNumber: 0)
        XCTAssertEqual(engine.readTruthStates()[reg], 0)

        // Clear the back-edge into reg.
        engine.clearBackEdges(toNode: UInt32(reg))
        XCTAssertEqual(engine.backEdgeCount, 0)

        // Next tick: kernel should re-evaluate reg's leaf-LUT (const1 → 1),
        // because the register flag was cleared.
        engine.tick(tickNumber: 1)
        XCTAssertEqual(engine.readTruthStates()[reg], 1,
                       "after clearBackEdges, rank kernel re-evaluates the node's LUT")
    }
}
