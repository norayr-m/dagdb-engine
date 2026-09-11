import XCTest
@testable import DagDB

/// E1 — weight-lane persistence (snapshot v6 + WAL weight opcodes).
///
/// The engine has carried `edgeWeights: [Float]` and `activation: [Int16]`
/// since birth, and the GPU has a weighted tick kernel — but neither lane
/// survives a save/load (snapshot v1–v5 body carries neither), and the WAL
/// has no weight opcode. These tests freeze the missing halves:
///   - snapshot v6: WGTS section (edge weights + activation + node values),
///     written only for non-default lanes, defaults restored on load;
///   - WAL opcodes: setEdgeWeight / setActivation / setNodeValue with the
///     same bounds discipline as the existing opcodes;
///   - a new Float node-value lane (`nodeValue`) end-to-end, for solver
///     state (activation is Int16 and stays what it was).
final class DagDBWeightLaneTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-wlane-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    private func makeEngine(side: Int) throws -> DagDBEngine {
        let grid = HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        return try DagDBEngine(grid: grid, state: state, maxRank: 8)
    }

    // MARK: - lanes exist

    func testStateHasNodeValueLane() {
        let s = DagDBState(width: 4, height: 4)
        XCTAssertEqual(s.nodeValue.count, 16)
        XCTAssertTrue(s.nodeValue.allSatisfy { $0 == 0.0 })
    }

    func testEngineHasNodeValueBuffer() throws {
        let eng = try makeEngine(side: 4)
        let p = eng.nodeValueBuf.contents()
            .bindMemory(to: Float.self, capacity: eng.nodeCount)
        for i in 0..<eng.nodeCount { XCTAssertEqual(p[i], 0.0) }
    }

    // MARK: - snapshot v6

    func testSnapshotVersionIsSix() {
        XCTAssertEqual(DagDBSnapshot.version, 7)
    }

    func testSnapshotV6RoundtripWeightLanes() throws {
        let eng = try makeEngine(side: 8)
        let n = eng.nodeCount

        let w = eng.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        let a = eng.activationBuf.contents().bindMemory(to: Int16.self, capacity: n)
        let v = eng.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)
        for i in 0..<n {
            for d in 0..<6 { w[i * 6 + d] = Float(i % 7) + Float(d) * 0.125 }
            a[i] = Int16(truncatingIfNeeded: i * 3 - 40)
            v[i] = Float(i) * 0.5 - 3.0
        }

        let path = tmpDir! + "wlane_v6.snap"
        _ = try DagDBSnapshot.save(engine: eng, nodeCount: n,
                                   gridW: 8, gridH: 8,
                                   tickCount: 5, path: path)

        // Scramble all three lanes in memory, then load — must restore.
        for i in 0..<n {
            for d in 0..<6 { w[i * 6 + d] = -99 }
            a[i] = -7
            v[i] = 123.0
        }
        _ = try DagDBSnapshot.load(engine: eng, nodeCount: n,
                                   gridW: 8, gridH: 8, path: path,
                                   validate: false)
        for i in 0..<n {
            for d in 0..<6 {
                XCTAssertEqual(w[i * 6 + d], Float(i % 7) + Float(d) * 0.125,
                               "edge weight (\(i),\(d)) not restored")
            }
            XCTAssertEqual(a[i], Int16(truncatingIfNeeded: i * 3 - 40),
                           "activation \(i) not restored")
            XCTAssertEqual(v[i], Float(i) * 0.5 - 3.0,
                           "node value \(i) not restored")
        }
    }

    func testSnapshotDefaultLanesLoadAsDefaults() throws {
        let eng = try makeEngine(side: 8)
        let n = eng.nodeCount

        // Save with all-default lanes (weights 1.0, activation 0, value 0).
        let path = tmpDir! + "wlane_default.snap"
        _ = try DagDBSnapshot.save(engine: eng, nodeCount: n,
                                   gridW: 8, gridH: 8,
                                   tickCount: 0, path: path)

        // Mutate lanes in memory; load must restore DEFAULTS (not keep stale).
        let w = eng.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        let a = eng.activationBuf.contents().bindMemory(to: Int16.self, capacity: n)
        let v = eng.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)
        for i in 0..<n {
            for d in 0..<6 { w[i * 6 + d] = 2.5 }
            a[i] = 11
            v[i] = 4.0
        }
        _ = try DagDBSnapshot.load(engine: eng, nodeCount: n,
                                   gridW: 8, gridH: 8, path: path,
                                   validate: false)
        for i in 0..<n {
            for d in 0..<6 { XCTAssertEqual(w[i * 6 + d], 1.0) }
            XCTAssertEqual(a[i], 0)
            XCTAssertEqual(v[i], 0.0)
        }

        // A default-lane snapshot must not pay the full lane cost on disk:
        // section = "WGTS" + flags byte only.
        let defaultSize = (try FileManager.default
            .attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        for i in 0..<n { v[i] = Float(i) }  // one non-default lane
        let path2 = tmpDir! + "wlane_nondefault.snap"
        _ = try DagDBSnapshot.save(engine: eng, nodeCount: n,
                                   gridW: 8, gridH: 8,
                                   tickCount: 0, path: path2)
        let lanedSize = (try FileManager.default
            .attributesOfItem(atPath: path2)[.size] as? Int) ?? 0
        XCTAssertEqual(lanedSize - defaultSize, n * 4,
                       "non-default nodeValue lane should add exactly 4N bytes")
    }

    func testSnapshotCompressedRoundtripWithWeights() throws {
        let eng = try makeEngine(side: 8)
        let n = eng.nodeCount
        let w = eng.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        w[13 * 6 + 2] = 0.75

        let path = tmpDir! + "wlane_z.snap"
        _ = try DagDBSnapshot.save(engine: eng, nodeCount: n,
                                   gridW: 8, gridH: 8,
                                   tickCount: 1, path: path, compressed: true)
        w[13 * 6 + 2] = 1.0
        _ = try DagDBSnapshot.load(engine: eng, nodeCount: n,
                                   gridW: 8, gridH: 8, path: path,
                                   validate: false)
        XCTAssertEqual(w[13 * 6 + 2], 0.75)
    }

    // MARK: - WAL opcodes

    func testWALWeightOpcodesReplay() throws {
        let path = tmpDir! + "wlane.log"
        let eng = try makeEngine(side: 8)
        let n = eng.nodeCount

        let appender = try DagDBWAL.Appender(path: path, nodeCount: n)
        _ = try appender.setEdgeWeight(node: 9, dir: 4, value: 0.25)
        _ = try appender.setActivation(node: 10, value: -321)
        _ = try appender.setNodeValue(node: 11, value: 6.5)
        // Out-of-range records: written, but replay must skip them.
        _ = try appender.setEdgeWeight(node: UInt32(n + 5), dir: 0, value: 9.0)
        _ = try appender.setEdgeWeight(node: 2, dir: 6, value: 9.0)
        _ = try appender.setNodeValue(node: UInt32(n), value: 9.0)

        let fresh = try makeEngine(side: 8)
        let result = try DagDBWAL.replay(engine: fresh, nodeCount: n, path: path)
        XCTAssertEqual(result.recordsApplied, 3, "only in-range records apply")

        let w = fresh.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        let a = fresh.activationBuf.contents().bindMemory(to: Int16.self, capacity: n)
        let v = fresh.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)
        XCTAssertEqual(w[9 * 6 + 4], 0.25)
        XCTAssertEqual(a[10], -321)
        XCTAssertEqual(v[11], 6.5)
        XCTAssertEqual(w[2 * 6 + 0], 1.0, "dir=6 record must not land anywhere")
    }
}
