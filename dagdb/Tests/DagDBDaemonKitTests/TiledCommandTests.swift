import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Handler-level + DSL-grammar tests for the TILED verb family (gate T5,
/// docs/contracts/TILING_GATES_FROZEN.md). Every numeric expectation
/// (tile/node/crossing counts, BFS/SELECT results) is computed
/// independently against the library (`TiledGraphFiles`, `DagDBBFS`,
/// `TruthRankIndex`) from the SAME fixture engine content, never
/// hardcoded — the fixture generator is deterministic (two calls with the
/// same side reproduce identical buffers, see
/// `TiledGraphFilesTests.testGeneratorIsDeterministic`), so an independent
/// direct call and the handler's DSL-dispatched call must agree exactly.
final class TiledCommandTests: XCTestCase {

    // MARK: - Fixture plumbing

    private func tempDir() -> String {
        let dir = NSTemporaryDirectory() + "tiled_cmd_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A `HandlerFixture` whose engine buffers are the frozen side-44
    /// object, written IN PLACE via `TiledFixture.populate` — the daemon's
    /// own engine, not a `TiledFixture.Object`, matching what `SAVE TILED`
    /// actually splits.
    private func makeFixture(side: Int, dataRoot: String) throws -> HandlerFixture {
        let f = try HandlerFixture(side: side, dataRoot: dataRoot)
        try TiledFixture.populate(engine: f.handler.engine, grid: f.grid, side: side)
        return f
    }

    private struct Built {
        let fixture: HandlerFixture
        let root: String
        let graphDir: String
        let report: TiledGraphFiles.WriteReport
    }

    /// Builds a side-44 fixture, SAVE TILEDs it through the handler's DSL
    /// dispatch (asserting the exact OK line against an independently
    /// computed `WriteReport`), and returns both for further use —
    /// `report.globalOf` is what later tests use to map engine indices to
    /// the global ids `TILED BFS`/`SELECT` take over the socket.
    private func buildSide44(boundaries: [UInt64] = [5, 11, 17]) throws -> Built {
        let root = tempDir()
        let f = try makeFixture(side: 44, dataRoot: root)
        let graphDir = "\(root)/g44"
        let boundaryArg = boundaries.map(String.init).joined(separator: ",")
        let saveReply = f.handler.handle("SAVE TILED \(graphDir) \(boundaryArg)")

        // Independent recomputation against the SAME (unmutated since
        // populate) engine content — not a hardcoded number.
        let report = try TiledGraphFiles.write(
            engine: f.handler.engine, grid: f.grid,
            dataRoot: root, name: "g44check", boundaries: boundaries
        )
        XCTAssertEqual(
            saveReply,
            "OK SAVE TILED dir=\(graphDir) tiles=\(report.tiles) nodes=\(report.nodes) crossings=\(report.crossings)",
            "handler's SAVE TILED summary must match the library's own WriteReport"
        )
        return Built(fixture: f, root: root, graphDir: graphDir, report: report)
    }

    private func readTiledBFSRows(_ shm: UnsafeMutableRawPointer) -> [(UInt64, UInt32)] {
        let header = shm.bindMemory(to: UInt32.self, capacity: 2)
        XCTAssertEqual(header[1], 16, "TILED BFS row size must be 16 bytes")
        let count = Int(header[0])
        let dataPtr = shm.advanced(by: 8)
        var rows: [(UInt64, UInt32)] = []
        rows.reserveCapacity(count)
        for i in 0..<count {
            let rowPtr = dataPtr.advanced(by: i * 16)
            let id = rowPtr.loadUnaligned(as: UInt64.self)
            let depth = rowPtr.advanced(by: 8).loadUnaligned(as: UInt32.self)
            rows.append((id, depth))
        }
        return rows
    }

    private func readU64Vector(_ shm: UnsafeMutableRawPointer) -> [UInt64] {
        let header = shm.bindMemory(to: UInt32.self, capacity: 2)
        XCTAssertEqual(header[1], 8, "u64-vector shm row size must be 8 bytes")
        let count = Int(header[0])
        let dataPtr = shm.advanced(by: 8).bindMemory(to: UInt64.self, capacity: max(1, count))
        return (0..<count).map { dataPtr[$0] }
    }

    private func readInt32Depths(_ shm: UnsafeMutableRawPointer, count: Int) -> [Int32] {
        let ptr = shm.advanced(by: 8).bindMemory(to: Int32.self, capacity: count)
        return (0..<count).map { ptr[$0] }
    }

    // MARK: - SAVE TILED / TILED OPEN

    func testSaveTiledSummaryLine() throws {
        // buildSide44 already asserts the exact OK line; this test exists
        // to pin the tile count explicitly (4 tiles from 3 boundaries) and
        // report the numbers verbatim for the task's own write-up.
        let built = try buildSide44()
        XCTAssertEqual(built.report.tiles, 4)
        XCTAssertEqual(built.report.nodes, 44 * 44)
    }

    func testTiledOpenReturnsFirstRouterId() throws {
        let built = try buildSide44()
        let openReply = built.fixture.handler.handle("TILED OPEN \(built.graphDir) 2")
        XCTAssertEqual(
            openReply,
            "OK TILED OPEN id=x00000001 tiles=\(built.report.tiles) nodes=\(built.report.nodes) resident_max=2"
        )
    }

    func testTiledOpenDefaultK() throws {
        let built = try buildSide44()
        let openReply = built.fixture.handler.handle("TILED OPEN \(built.graphDir)")
        XCTAssertTrue(openReply.contains("resident_max=2"), openReply)
    }

    func testTiledOpenMissingDirIsIOError() throws {
        let root = tempDir()
        let f = try HandlerFixture(side: 16, dataRoot: root)
        let reply = f.handler.handle("TILED OPEN \(root)/does_not_exist 2")
        XCTAssertTrue(reply.hasPrefix("ERROR io:"), reply)
        XCTAssertTrue(reply.contains("manifest"), reply)
    }

    func testTiledOpenRejectsKOutOfRange() throws {
        let built = try buildSide44()
        let tooSmall = built.fixture.handler.handle("TILED OPEN \(built.graphDir) 0")
        XCTAssertTrue(tooSmall.hasPrefix("ERROR out_of_range"), tooSmall)
        let tooBig = built.fixture.handler.handle("TILED OPEN \(built.graphDir) 65")
        XCTAssertTrue(tooBig.hasPrefix("ERROR out_of_range"), tooBig)
    }

    func testSaveTiledUnsortedBoundariesIsBadValue() throws {
        let root = tempDir()
        let f = try makeFixture(side: 16, dataRoot: root)
        let reply = f.handler.handle("SAVE TILED \(root)/g16 11,5")
        XCTAssertTrue(reply.hasPrefix("ERROR bad_value"), reply)
    }

    func testSaveTiledEmptyBoundariesIsBadValue() throws {
        // A single empty-string component (no comma at all is a parse
        // failure ⇒ unknown_command; an explicit empty component after a
        // trailing comma is the bad_value case).
        let root = tempDir()
        let f = try makeFixture(side: 16, dataRoot: root)
        let reply = f.handler.handle("SAVE TILED \(root)/g16 5,")
        XCTAssertTrue(reply.hasPrefix("ERROR"), reply)
    }

    // MARK: - STATUS carries tiled_open, not twin_open

    func testStatusLineCarriesTiledOpenCount() throws {
        let built = try buildSide44()
        let h = built.fixture.handler
        XCTAssertTrue(h.handle("STATUS").contains("tiled_open=0"), h.handle("STATUS"))
        _ = h.handle("TILED OPEN \(built.graphDir) 2")
        XCTAssertTrue(h.handle("STATUS").contains("tiled_open=1"))
        XCTAssertTrue(h.handle("STATUS").contains("twin_open=0"), "twin_open must not count routers")
    }

    // MARK: - TILED BFS vs the daemon's own BFS_DEPTHS

    func testTiledBFSMatchesDaemonBFSDepthsUndirectedAndBackward() throws {
        let built = try buildSide44()
        let h = built.fixture.handler
        XCTAssertTrue(h.handle("TILED OPEN \(built.graphDir) 4").hasPrefix("OK TILED OPEN"))

        let seeds = TiledFixture.seeds(for: try TiledFixture.generate(side: 44))
        for engineSeed in seeds.prefix(2) {
            let globalId = built.report.globalOf[engineSeed]
            for depth in [1, 3, 6] {
                for backward in [false, true] {
                    let suffix = backward ? " BACK" : ""
                    let tiledReply = h.handle("TILED BFS x00000001 \(globalId) \(depth)\(suffix)")
                    XCTAssertTrue(tiledReply.hasPrefix("OK TILED BFS"), tiledReply)
                    let tiledRows = readTiledBFSRows(built.fixture.shm).sorted { $0.0 < $1.0 }

                    let dsuffix = backward ? " BACKWARD" : ""
                    let daemonReply = h.handle("BFS_DEPTHS FROM \(engineSeed)\(dsuffix)")
                    XCTAssertTrue(daemonReply.hasPrefix("OK BFS_DEPTHS"), daemonReply)
                    let daemonDepths = readInt32Depths(built.fixture.shm, count: h.nodeCount)

                    var expected: [(UInt64, UInt32)] = []
                    for i in 0..<h.nodeCount {
                        let d = daemonDepths[i]
                        guard d >= 0, d <= Int32(depth) else { continue }
                        expected.append((built.report.globalOf[i], UInt32(d)))
                    }
                    expected.sort { $0.0 < $1.0 }

                    XCTAssertEqual(
                        tiledRows.map { $0.0 }, expected.map { $0.0 },
                        "seed=\(engineSeed) depth=\(depth) backward=\(backward): global id sets differ"
                    )
                    XCTAssertEqual(
                        tiledRows.map { $0.1 }, expected.map { $0.1 },
                        "seed=\(engineSeed) depth=\(depth) backward=\(backward): depths differ"
                    )
                }
            }
        }
    }

    func testTiledBFSDepthCapExceeded() throws {
        let built = try buildSide44()
        let h = built.fixture.handler
        _ = h.handle("TILED OPEN \(built.graphDir) 4")
        let seed = built.report.globalOf[0]
        let reply = h.handle("TILED BFS x00000001 \(seed) 13")
        XCTAssertTrue(reply.hasPrefix("ERROR io:"), reply)
        XCTAssertTrue(reply.contains("12"), reply)
    }

    func testTiledBFSUnknownRouterIdNotFound() throws {
        let built = try buildSide44()
        let reply = built.fixture.handler.handle("TILED BFS x0badbad0 0 1")
        XCTAssertTrue(reply.hasPrefix("ERROR not_found"), reply)
    }

    // MARK: - TILED SELECT vs the daemon's own truth/rank-range select

    func testTiledSelectMatchesDaemonSelect() throws {
        let built = try buildSide44()
        let h = built.fixture.handler
        _ = h.handle("TILED OPEN \(built.graphDir) 4")

        let triples: [(UInt8, UInt64, UInt64)] = [(0, 0, 21), (1, 3, 15), (2, 11, 21)]
        for (truthVal, lo, hi) in triples {
            let tiledReply = h.handle("TILED SELECT x00000001 \(truthVal) \(lo) \(hi)")
            XCTAssertTrue(tiledReply.hasPrefix("OK TILED SELECT"), tiledReply)
            let tiledIds = readU64Vector(built.fixture.shm).sorted()

            let daemonLocalIds = TruthRankIndex().select(
                truth: truthVal, rankLo: lo, rankHi: hi, engine: h.engine, nodeCount: h.nodeCount
            )
            let expectedGlobalIds = daemonLocalIds.map { built.report.globalOf[$0] }.sorted()

            XCTAssertEqual(tiledIds, expectedGlobalIds, "truth=\(truthVal) lo=\(lo) hi=\(hi)")
            XCTAssertTrue(tiledReply.contains("count=\(expectedGlobalIds.count)"), tiledReply)
        }
    }

    // MARK: - T4: torn tile body refused, recorded in STATUS

    func testTornTileBodyIsRefusedAndRecordedInStatus() throws {
        let built = try buildSide44()
        let h = built.fixture.handler
        _ = h.handle("TILED OPEN \(built.graphDir) 4")

        // Find a seed + depth that the UNTILED engine's own BFS proves
        // crosses into tile 1 (rather than assuming one — boundaries have
        // guaranteed crossings per the gate contract, but the exact depth
        // needed depends on the random draw).
        let seedEngineIndex = TiledFixture.seeds(for: try TiledFixture.generate(side: 44))[0]
        let bfsResult = try DagDBBFS.bfsDepthsUndirected(
            engine: h.engine, nodeCount: h.nodeCount, from: seedEngineIndex)
        var neededDepth: Int32?
        for i in 0..<h.nodeCount {
            let d = bfsResult.depths[i]
            guard d >= 0 else { continue }
            if GlobalNodeID(raw: built.report.globalOf[i]).tileId == 1 {
                if neededDepth == nil || d < neededDepth! { neededDepth = d }
            }
        }
        // Reaching a tile-1 node as a frontier LEAF doesn't need tile 1
        // loaded (its GlobalNodeID comes from tile 0's own crossOutIndex/
        // inEdgeIndex, built at tile-0 load time) — only EXPANDING it (one
        // hop further) does, since that's when the router reads ITS
        // neighbour slots. So ask for one hop past the minimum.
        guard let leafDepth = neededDepth, leafDepth + 1 <= 12 else {
            XCTFail("centre seed never reaches tile 1 within the depth cap — boundary-crossing assumption broken")
            return
        }
        let depth = leafDepth + 1

        // Tear tile 1's body.dags — flip a byte mid-file.
        let manifest = try TiledGraphFiles.readManifest(dataRoot: built.root, name: "g44")
        guard let tile1 = manifest.tiles.first(where: { $0.id == 1 }) else {
            XCTFail("no tile 1 in manifest"); return
        }
        let tile1Dir = TiledGraphFiles.tileDirectory(dataRoot: built.root, name: "g44", entry: tile1)
        let bodyPath = "\(tile1Dir)/body.dags"
        var bytes = try Data(contentsOf: URL(fileURLWithPath: bodyPath))
        XCTAssertFalse(bytes.isEmpty)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: URL(fileURLWithPath: bodyPath))

        let seed = built.report.globalOf[seedEngineIndex]
        let reply = h.handle("TILED BFS x00000001 \(seed) \(depth)")
        XCTAssertTrue(reply.hasPrefix("ERROR io:"), reply)
        XCTAssertTrue(reply.lowercased().contains("sha256") || reply.lowercased().contains("mismatch"), reply)

        let statusReply = h.handle("TILED STATUS x00000001")
        XCTAssertTrue(statusReply.contains("refused=1"), statusReply)
        XCTAssertFalse(statusReply.contains("last=none"), statusReply)
    }

    // MARK: - Reader-session split

    private func openReaderId(_ h: DagDBCommandHandler) throws -> String {
        let openReply = h.handle("OPEN_READER")
        guard let ridRange = openReply.range(of: "id="),
              let spaceRange = openReply.range(of: " ", range: ridRange.upperBound..<openReply.endIndex) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not parse reader id out of: \(openReply)"])
        }
        return String(openReply[ridRange.upperBound..<spaceRange.lowerBound])
    }

    func testReaderSessionAllowsQueriesButForbidsOpenCloseSave() throws {
        let built = try buildSide44()
        let h = built.fixture.handler
        XCTAssertTrue(h.handle("TILED OPEN \(built.graphDir) 2").hasPrefix("OK TILED OPEN"))
        let rid = try openReaderId(h)

        XCTAssertTrue(h.handle("READER \(rid) TILED STATUS x00000001").hasPrefix("OK TILED STATUS"))
        XCTAssertTrue(h.handle("READER \(rid) TILED LIST").hasPrefix("OK TILED LIST"))
        let seed = built.report.globalOf[0]
        XCTAssertTrue(h.handle("READER \(rid) TILED BFS x00000001 \(seed) 1").hasPrefix("OK TILED BFS"))
        XCTAssertTrue(h.handle("READER \(rid) TILED SELECT x00000001 0 0 21").hasPrefix("OK TILED SELECT"))

        XCTAssertTrue(h.handle("READER \(rid) TILED OPEN \(built.graphDir) 2").hasPrefix("ERROR forbidden"))
        XCTAssertTrue(h.handle("READER \(rid) SAVE TILED \(built.graphDir) 5,11,17").hasPrefix("ERROR forbidden"))
        XCTAssertTrue(h.handle("READER \(rid) TILED CLOSE x00000001").hasPrefix("ERROR forbidden"))
    }

    // MARK: - TILED CLOSE / LIST

    func testTiledCloseRemovesFromList() throws {
        let built = try buildSide44()
        let h = built.fixture.handler
        XCTAssertTrue(h.handle("TILED OPEN \(built.graphDir) 2").hasPrefix("OK TILED OPEN"))
        XCTAssertTrue(h.handle("TILED LIST").contains("count=1"))
        let closeReply = h.handle("TILED CLOSE x00000001")
        XCTAssertEqual(closeReply, "OK TILED CLOSE id=x00000001 open=0")
        XCTAssertEqual(h.handle("TILED LIST"), "OK TILED LIST count=0")
    }

    func testTiledCloseUnknownIdNotFound() throws {
        let built = try buildSide44()
        let reply = built.fixture.handler.handle("TILED CLOSE x0badbad0")
        XCTAssertTrue(reply.hasPrefix("ERROR not_found"), reply)
    }

    // MARK: - DSL grammar

    func testParseSaveTiled() {
        guard case .saveTiled(let dir, let boundaries) = DSLParser.parse("SAVE TILED /tmp/g44 5,11,17") else {
            XCTFail("expected .saveTiled"); return
        }
        XCTAssertEqual(dir, "/tmp/g44")
        XCTAssertEqual(boundaries, [5, 11, 17])
    }

    func testParseSaveTiledRequiresBoundaryArgument() {
        guard case .unknown = DSLParser.parse("SAVE TILED /tmp/g44") else {
            XCTFail("expected .unknown"); return
        }
    }

    func testParseSaveTiledRejectsNonNumericBoundary() {
        guard case .unknown = DSLParser.parse("SAVE TILED /tmp/g44 a,b") else {
            XCTFail("expected .unknown"); return
        }
    }

    func testParseTiledOpenDefaultK() {
        guard case .tiledOpen(let dir, let k) = DSLParser.parse("TILED OPEN /tmp/g44") else {
            XCTFail("expected .tiledOpen"); return
        }
        XCTAssertEqual(dir, "/tmp/g44")
        XCTAssertEqual(k, 2)
    }

    func testParseTiledOpenExplicitK() {
        guard case .tiledOpen(_, let k) = DSLParser.parse("TILED OPEN /tmp/g44 8") else {
            XCTFail("expected .tiledOpen"); return
        }
        XCTAssertEqual(k, 8)
    }

    func testParseTiledBFSBackward() {
        guard case .tiledBFS(let id, let gid, let depth, let back) = DSLParser.parse("TILED BFS x00000001 42 3 BACK") else {
            XCTFail("expected .tiledBFS"); return
        }
        XCTAssertEqual(id, "x00000001")
        XCTAssertEqual(gid, 42)
        XCTAssertEqual(depth, 3)
        XCTAssertTrue(back)
    }

    func testParseTiledBFSForwardDefault() {
        guard case .tiledBFS(_, _, _, let back) = DSLParser.parse("TILED BFS x00000001 42 3") else {
            XCTFail("expected .tiledBFS"); return
        }
        XCTAssertFalse(back)
    }

    func testParseTiledSelect() {
        guard case .tiledSelect(let id, let truth, let lo, let hi) = DSLParser.parse("TILED SELECT x00000001 1 5 20") else {
            XCTFail("expected .tiledSelect"); return
        }
        XCTAssertEqual(id, "x00000001")
        XCTAssertEqual(truth, 1)
        XCTAssertEqual(lo, 5)
        XCTAssertEqual(hi, 20)
    }

    func testParseTiledStatusListClose() {
        guard case .tiledStatus(let id) = DSLParser.parse("TILED STATUS x00000001") else {
            XCTFail("expected .tiledStatus"); return
        }
        XCTAssertEqual(id, "x00000001")

        guard case .tiledList = DSLParser.parse("TILED LIST") else {
            XCTFail("expected .tiledList"); return
        }

        guard case .tiledClose(let cid) = DSLParser.parse("TILED CLOSE x00000001") else {
            XCTFail("expected .tiledClose"); return
        }
        XCTAssertEqual(cid, "x00000001")
    }

    func testParseTiledUnknownSubverbIsUnknown() {
        guard case .unknown = DSLParser.parse("TILED FROBNICATE x") else {
            XCTFail("expected .unknown"); return
        }
    }
}
