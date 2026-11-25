import XCTest
@testable import DagDB

/// Load paths refuse a non-finite weight.
///
/// SET WEIGHT refuses a non-finite weight ("weight must be finite"); the load
/// paths took one from a file. Each path now refuses it by name, before any
/// buffer is written: one cell per path — LOAD (`.dags`, a v7 plain file and
/// a v8 zlib file), IMPORT MORTON, LOAD JSON (v2) — plus LOAD CSV (v2), which
/// shares JSON's staged-lane check. Every cell: the refusal names the node,
/// the slot and the rule, and the target engine's state is unchanged.
final class TernaryA4NonFiniteWeightLoadTests: XCTestCase {

    private var tmp: String!
    private let side = 8
    private let needle = "a weight must be finite"

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "tern-a4-weights-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let d = tmp { try? FileManager.default.removeItem(atPath: d) } }

    private func fresh() throws -> DagDBEngine {
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side), maxRank: 8)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        return e
    }

    /// A valid source whose only flaw is one non-finite weight at (node, slot);
    /// `ternary` adds a table and a TTABLE node so SAVE writes v8.
    private func source(weight: Float, node: Int, slot: Int, ternary: Bool = false) throws -> DagDBEngine {
        let e = try fresh()
        let n = e.nodeCount
        let w = e.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        for k in 0..<(n * 6) { w[k] = Float(k % 7) * 0.25 - 0.5 }
        w[node * 6 + slot] = weight
        if ternary {
            try e.writeTables(first: 0, bytes: try TernaryReference.presetTable(.tsum, k: 2))
            e.modePtr[7] = 1
            e.truthStateBuf.contents().storeBytes(of: 2, toByteOffset: 7, as: UInt8.self)
        }
        XCTAssertNil(e.ternaryStateViolation())
        return e
    }

    /// A target holding a state of its own, so a half-load would show.
    private func target() throws -> DagDBEngine {
        let e = try fresh()
        for i in 0..<e.nodeCount { e.truthStateBuf.contents().storeBytes(of: UInt8(i % 2), toByteOffset: i, as: UInt8.self) }
        let w = e.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: e.nodeCount * 6)
        w[0] = 3.5
        return e
    }

    private func expectRefused(_ what: String, node: Int, slot: Int, _ load: (DagDBEngine) throws -> Void) throws {
        let t = try target()
        let before = TernaryR4PersistenceTests.stateHash(t)
        var said = "(no error)"
        XCTAssertThrowsError(try load(t), "\(what): a non-finite weight was accepted") { err in
            said = "\(err)"
            XCTAssertTrue(said.contains(needle), "\(what): \(said)")
            XCTAssertTrue(said.contains("node=\(node) slot=\(slot)"), "\(what): \(said)")
        }
        let same = TernaryR4PersistenceTests.stateHash(t) == before
        XCTAssertTrue(same, "\(what): a refused load wrote something")
        print("A4 non-finite weight \(what): \(said == "(no error)" ? "ACCEPTED" : "refused") target_unchanged=\(same) — \(said)")
    }

    func testLoadDagsRefusesANonFiniteWeight() throws {
        let a = try source(weight: .nan, node: 13, slot: 4)
        let p = tmp + "w.dags"
        _ = try DagDBSnapshot.save(engine: a, nodeCount: a.nodeCount, gridW: side, gridH: side, tickCount: 1, path: p)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: p))[4], 7)
        try expectRefused("LOAD .dags v7 plain (nan)", node: 13, slot: 4) { t in
            _ = try DagDBSnapshot.load(engine: t, nodeCount: t.nodeCount, gridW: side, gridH: side, path: p)
        }
        let b = try source(weight: .infinity, node: 20, slot: 0, ternary: true)
        let pz = tmp + "wz.dags"
        _ = try DagDBSnapshot.save(engine: b, nodeCount: b.nodeCount, gridW: side, gridH: side, tickCount: 1,
                                   path: pz, compressed: true)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: pz))[4], 8)
        try expectRefused("LOAD .dags v8 zlib (+inf)", node: 20, slot: 0) { t in
            _ = try DagDBSnapshot.load(engine: t, nodeCount: t.nodeCount, gridW: side, gridH: side, path: pz)
        }
    }

    func testImportMortonRefusesANonFiniteWeight() throws {
        let a = try source(weight: -.infinity, node: 2, slot: 5)
        let d = tmp + "morton"
        _ = try DagDBSnapshot.exportMorton(engine: a, nodeCount: a.nodeCount, dir: d)
        try expectRefused("IMPORT MORTON (-inf)", node: 2, slot: 5) { t in
            _ = try DagDBSnapshot.importMorton(engine: t, nodeCount: t.nodeCount, dir: d)
        }
    }

    func testLoadJSONRefusesANonFiniteWeight() throws {
        let a = try source(weight: Float(bitPattern: 0x7FC0_0001), node: 40, slot: 3)
        let p = tmp + "w.json"
        _ = try DagDBJSONIO.saveJSON(engine: a, nodeCount: a.nodeCount, gridW: side, gridH: side, tickCount: 1, path: p)
        try expectRefused("LOAD JSON v2 (nan, payload 1)", node: 40, slot: 3) { t in
            _ = try DagDBJSONIO.loadJSON(engine: t, nodeCount: t.nodeCount, gridW: side, gridH: side, path: p)
        }
    }

    func testLoadCSVRefusesANonFiniteWeight() throws {
        let a = try source(weight: .infinity, node: 33, slot: 1)
        let d = tmp + "csv"
        _ = try DagDBJSONIO.saveCSV(engine: a, nodeCount: a.nodeCount, dir: d)
        try expectRefused("LOAD CSV v2 (+inf)", node: 33, slot: 1) { t in
            _ = try DagDBJSONIO.loadCSV(engine: t, nodeCount: t.nodeCount, dir: d)
        }
    }
}
