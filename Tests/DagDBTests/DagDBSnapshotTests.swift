import XCTest
@testable import DagDB

final class DagDBSnapshotTests: XCTestCase {

    /// Build a tiny engine and return it along with its grid dims.
    private func makeEngine(side: Int) throws -> (DagDBEngine, Int, Int) {
        let grid = HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        return (engine, side, side)
    }

    /// Seed the engine with a small, DAG-valid graph: 6 leaves (rank 2) → 1 aggregator (rank 1) → 1 root (rank 0).
    /// Leaf IDs 1..6, aggregator ID 7, root ID 8.
    private func seed(_ engine: DagDBEngine) {
        let n = engine.nodeCount
        let rank  = engine.rankBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let truth = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let low   = engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high  = engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let nb    = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)

        // Clear
        for i in 0..<n {
            rank[i] = 0; truth[i] = 0; low[i] = 0; high[i] = 0
            for d in 0..<6 { nb[i * 6 + d] = -1 }
        }

        // Leaves 1..6
        for i in 1...6 {
            rank[i] = 2
            truth[i] = 1
            let lut = LUT6Preset.const1
            low[i]  = UInt32(lut & 0xFFFFFFFF)
            high[i] = UInt32((lut >> 32) & 0xFFFFFFFF)
        }

        // Aggregator 7 — MAJ of leaves
        rank[7] = 1
        let maj = LUT6Preset.majority6
        low[7]  = UInt32(maj & 0xFFFFFFFF)
        high[7] = UInt32((maj >> 32) & 0xFFFFFFFF)
        for d in 0..<6 { nb[7 * 6 + d] = Int32(1 + d) }

        // Root 8 — ID of aggregator
        rank[8] = 0
        let idg = LUT6Preset.identity
        low[8]  = UInt32(idg & 0xFFFFFFFF)
        high[8] = UInt32((idg >> 32) & 0xFFFFFFFF)
        nb[8 * 6 + 0] = 7
    }

    func testSnapshotRoundTrip() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        seed(eng1)

        let path = NSTemporaryDirectory() + "dagdb_serde_test.dags"
        _ = try? FileManager.default.removeItem(atPath: path)

        let saved = try DagDBSnapshot.save(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 42, path: path
        )
        XCTAssertEqual(saved.bytesWritten, 32 + eng1.nodeCount * 35)

        // Fresh engine — all zeros initially
        let (eng2, _, _) = try makeEngine(side: 8)

        let loaded = try DagDBSnapshot.load(
            engine: eng2, nodeCount: eng2.nodeCount,
            gridW: gw, gridH: gh, path: path
        )
        XCTAssertEqual(loaded.fileNodeCount, eng1.nodeCount)
        XCTAssertEqual(loaded.fileTicks, 42)

        // Compare every buffer byte-for-byte
        XCTAssertTrue(buffersEqual(eng1.rankBuf,         eng2.rankBuf,         eng1.nodeCount),     "rank")
        XCTAssertTrue(buffersEqual(eng1.truthStateBuf,   eng2.truthStateBuf,   eng1.nodeCount),     "truth")
        XCTAssertTrue(buffersEqual(eng1.nodeTypeBuf,     eng2.nodeTypeBuf,     eng1.nodeCount),     "type")
        XCTAssertTrue(buffersEqual(eng1.lut6LowBuf,      eng2.lut6LowBuf,      eng1.nodeCount * 4), "lut_low")
        XCTAssertTrue(buffersEqual(eng1.lut6HighBuf,     eng2.lut6HighBuf,     eng1.nodeCount * 4), "lut_high")
        XCTAssertTrue(buffersEqual(eng1.neighborsBuf,    eng2.neighborsBuf,    eng1.nodeCount * 24),"neighbors")
    }

    func testSnapshotRejectsWrongMagic() throws {
        let (eng, gw, gh) = try makeEngine(side: 8)
        let path = NSTemporaryDirectory() + "dagdb_badmagic.dags"

        try Data(repeating: 0xAA, count: 4096).write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(
            try DagDBSnapshot.load(engine: eng, nodeCount: eng.nodeCount,
                                   gridW: gw, gridH: gh, path: path)
        ) { err in
            guard case DagDBSnapshot.SnapError.invalidMagic = err else {
                XCTFail("expected invalidMagic, got \(err)"); return
            }
        }
    }

    func testSnapshotRejectsGridMismatch() throws {
        let (eng1, _, _) = try makeEngine(side: 8)
        seed(eng1)

        let path = NSTemporaryDirectory() + "dagdb_gridmismatch.dags"
        _ = try? FileManager.default.removeItem(atPath: path)
        _ = try DagDBSnapshot.save(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: 8, gridH: 8, tickCount: 0, path: path
        )

        // Engine claims wrong grid dimensions
        XCTAssertThrowsError(
            try DagDBSnapshot.load(engine: eng1, nodeCount: eng1.nodeCount,
                                   gridW: 16, gridH: 16, path: path)
        ) { err in
            guard case DagDBSnapshot.SnapError.gridMismatch = err else {
                XCTFail("expected gridMismatch, got \(err)"); return
            }
        }
    }

    func testValidatorCatchesRankViolation() throws {
        let (eng, _, _) = try makeEngine(side: 8)
        seed(eng)

        // First: clean graph should validate
        XCTAssertNil(DagDBSnapshot.validate(engine: eng, nodeCount: eng.nodeCount))

        // Inject a rank-violating edge: leaf 1 (rank 2) → leaf 2 (rank 2)
        let nb = eng.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: eng.nodeCount * 6)
        nb[2 * 6 + 1] = 1

        let violation = DagDBSnapshot.validate(engine: eng, nodeCount: eng.nodeCount)
        XCTAssertNotNil(violation)
        XCTAssertTrue(violation!.contains("rank"))
    }

    func testValidatorCatchesSelfLoop() throws {
        let (eng, _, _) = try makeEngine(side: 8)
        seed(eng)

        let nb = eng.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: eng.nodeCount * 6)
        nb[7 * 6 + 5] = 7  // self-loop

        let violation = DagDBSnapshot.validate(engine: eng, nodeCount: eng.nodeCount)
        XCTAssertNotNil(violation)
        XCTAssertTrue(violation!.contains("self-loop"))
    }

    func testValidatorCatchesDuplicate() throws {
        let (eng, _, _) = try makeEngine(side: 8)
        seed(eng)

        // Aggregator 7 has slots pointing at leaves 1..6. Duplicate leaf 1 into slot 5.
        let nb = eng.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: eng.nodeCount * 6)
        nb[7 * 6 + 5] = 1

        let violation = DagDBSnapshot.validate(engine: eng, nodeCount: eng.nodeCount)
        XCTAssertNotNil(violation)
        XCTAssertTrue(violation!.contains("duplicate"))
    }

    // MARK: - Helpers

    private func buffersEqual(_ a: MTLBuffer, _ b: MTLBuffer, _ bytes: Int) -> Bool {
        return memcmp(a.contents(), b.contents(), bytes) == 0
    }
}
