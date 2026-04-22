import XCTest
@testable import DagDB

final class DagDBJSONIOTests: XCTestCase {

    private func makeEngine(side: Int) throws -> (DagDBEngine, Int, Int) {
        let grid = HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        return (engine, side, side)
    }

    /// Same 8-node seed as the snapshot tests — lets round-trip results be compared.
    private func seed(_ engine: DagDBEngine) {
        let n = engine.nodeCount
        let rank  = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let truth = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let low   = engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high  = engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let nb    = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)

        for i in 0..<n {
            rank[i] = 0; truth[i] = 0; low[i] = 0; high[i] = 0
            for d in 0..<6 { nb[i * 6 + d] = -1 }
        }
        for i in 1...6 {
            rank[i] = 2; truth[i] = 1
            let lut = LUT6Preset.const1
            low[i]  = UInt32(lut & 0xFFFFFFFF)
            high[i] = UInt32((lut >> 32) & 0xFFFFFFFF)
        }
        rank[7] = 1
        let maj = LUT6Preset.majority6
        low[7]  = UInt32(maj & 0xFFFFFFFF)
        high[7] = UInt32((maj >> 32) & 0xFFFFFFFF)
        for d in 0..<6 { nb[7 * 6 + d] = Int32(1 + d) }
        rank[8] = 0
        let idg = LUT6Preset.identity
        low[8]  = UInt32(idg & 0xFFFFFFFF)
        high[8] = UInt32((idg >> 32) & 0xFFFFFFFF)
        nb[8 * 6 + 0] = 7
    }

    // MARK: - JSON

    func testJSONRoundTrip() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        seed(eng1)

        let path = NSTemporaryDirectory() + "dagdb_rt.json"
        _ = try? FileManager.default.removeItem(atPath: path)

        let saved = try DagDBJSONIO.saveJSON(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 42, path: path
        )
        XCTAssertGreaterThan(saved.bytesWritten, 0)

        let (eng2, _, _) = try makeEngine(side: 8)
        let loaded = try DagDBJSONIO.loadJSON(
            engine: eng2, nodeCount: eng2.nodeCount,
            gridW: gw, gridH: gh, path: path
        )
        XCTAssertEqual(loaded.fileNodeCount, eng1.nodeCount)
        XCTAssertEqual(loaded.fileTicks, 42)

        XCTAssertTrue(buffersEqual(eng1.rankBuf,       eng2.rankBuf,       eng1.nodeCount * 4), "rank")
        XCTAssertTrue(buffersEqual(eng1.truthStateBuf, eng2.truthStateBuf, eng1.nodeCount),     "truth")
        XCTAssertTrue(buffersEqual(eng1.lut6LowBuf,    eng2.lut6LowBuf,    eng1.nodeCount * 4), "low")
        XCTAssertTrue(buffersEqual(eng1.lut6HighBuf,   eng2.lut6HighBuf,   eng1.nodeCount * 4), "high")
        XCTAssertTrue(buffersEqual(eng1.neighborsBuf,  eng2.neighborsBuf,  eng1.nodeCount * 24),"neighbors")
    }

    func testJSONRejectsGridMismatch() throws {
        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)

        let path = NSTemporaryDirectory() + "dagdb_grid.json"
        _ = try? FileManager.default.removeItem(atPath: path)
        _ = try DagDBJSONIO.saveJSON(
            engine: eng, nodeCount: eng.nodeCount,
            gridW: gw, gridH: gh, tickCount: 0, path: path
        )

        XCTAssertThrowsError(
            try DagDBJSONIO.loadJSON(engine: eng, nodeCount: eng.nodeCount,
                                     gridW: 16, gridH: 16, path: path)
        ) { err in
            guard case DagDBJSONIO.JSONError.shapeMismatch = err else {
                XCTFail("expected shapeMismatch, got \(err)"); return
            }
        }
    }

    func testJSONRejectsBadRankEdge() throws {
        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)

        let path = NSTemporaryDirectory() + "dagdb_badrank.json"
        _ = try DagDBJSONIO.saveJSON(
            engine: eng, nodeCount: eng.nodeCount,
            gridW: gw, gridH: gh, tickCount: 0, path: path
        )

        // Tamper: rewrite neighbors so a same-rank edge exists.
        var obj = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        var nb = obj["neighbors"] as! [[Int]]
        nb[2][1] = 1  // leaf 2 (rank 2) points at leaf 1 (rank 2)
        obj["neighbors"] = nb
        let tampered = try JSONSerialization.data(withJSONObject: obj)
        try tampered.write(to: URL(fileURLWithPath: path))

        let (eng2, _, _) = try makeEngine(side: 8)
        XCTAssertThrowsError(
            try DagDBJSONIO.loadJSON(engine: eng2, nodeCount: eng2.nodeCount,
                                     gridW: gw, gridH: gh, path: path)
        ) { err in
            guard case DagDBJSONIO.JSONError.invalidFormat(let msg) = err,
                  msg.contains("rank") else {
                XCTFail("expected rank-violation, got \(err)"); return
            }
        }
    }

    // MARK: - CSV

    func testCSVRoundTrip() throws {
        let (eng1, _, _) = try makeEngine(side: 8)
        seed(eng1)

        let dir = NSTemporaryDirectory() + "dagdb_csv_rt"
        _ = try? FileManager.default.removeItem(atPath: dir)

        let saved = try DagDBJSONIO.saveCSV(
            engine: eng1, nodeCount: eng1.nodeCount, dir: dir
        )
        XCTAssertGreaterThan(saved.nodesBytes, 0)
        XCTAssertGreaterThan(saved.edgesBytes, 0)

        let (eng2, _, _) = try makeEngine(side: 8)
        let loaded = try DagDBJSONIO.loadCSV(
            engine: eng2, nodeCount: eng2.nodeCount, dir: dir
        )
        XCTAssertEqual(loaded.nodesParsed, eng1.nodeCount)
        XCTAssertEqual(loaded.edgesParsed, 7)  // 6 leaves → aggregator + 1 aggregator → root

        XCTAssertTrue(buffersEqual(eng1.rankBuf,       eng2.rankBuf,       eng1.nodeCount * 8))
        XCTAssertTrue(buffersEqual(eng1.truthStateBuf, eng2.truthStateBuf, eng1.nodeCount))
        XCTAssertTrue(buffersEqual(eng1.lut6LowBuf,    eng2.lut6LowBuf,    eng1.nodeCount * 4))
        XCTAssertTrue(buffersEqual(eng1.lut6HighBuf,   eng2.lut6HighBuf,   eng1.nodeCount * 4))
        XCTAssertTrue(buffersEqual(eng1.neighborsBuf,  eng2.neighborsBuf,  eng1.nodeCount * 24))
    }

    func testCSVEdgesOnlyListsPresentEdges() throws {
        let (eng, _, _) = try makeEngine(side: 8)
        seed(eng)

        let dir = NSTemporaryDirectory() + "dagdb_csv_edges"
        _ = try? FileManager.default.removeItem(atPath: dir)

        _ = try DagDBJSONIO.saveCSV(
            engine: eng, nodeCount: eng.nodeCount, dir: dir
        )

        let edgesCSV = try String(contentsOfFile: dir + "/edges.csv", encoding: .utf8)
        // Header + 7 edges = 8 lines (no trailing blank)
        let lines = edgesCSV.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 8)
        XCTAssertEqual(lines[0], "dst,slot,src")
    }

    // MARK: - Helpers

    private func buffersEqual(_ a: MTLBuffer, _ b: MTLBuffer, _ bytes: Int) -> Bool {
        return memcmp(a.contents(), b.contents(), bytes) == 0
    }
}
