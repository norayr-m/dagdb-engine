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
    /// `maxRank: 64` — matches `TiledFixture.generate`'s own engine and
    /// `TiledGraphFiles.tileLocalEngine`'s tile-local engines (both
    /// hardcode 64); the daemon's default fixture size (8) is too small
    /// for a side-44 object's Chebyshev-derived ranks (up to 22) and
    /// would silently truncate rank-mode `TICK` (bounded by `maxRank`,
    /// unlike `TICK_SYNC` which dispatches over all nodes regardless).
    private func makeFixture(side: Int, dataRoot: String) throws -> HandlerFixture {
        let f = try HandlerFixture(side: side, dataRoot: dataRoot, maxRank: 64)
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
            "OK TILED OPEN id=x00000001 tiles=\(built.report.tiles) nodes=\(built.report.nodes) "
                + "resident_max=2 recovered=0 completed=0"
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
        XCTAssertTrue(h.handle("READER \(rid) TILED GET x00000001 \(seed) TRUTH").hasPrefix("OK TILED GET"))

        XCTAssertTrue(h.handle("READER \(rid) TILED OPEN \(built.graphDir) 2").hasPrefix("ERROR forbidden"))
        XCTAssertTrue(h.handle("READER \(rid) SAVE TILED \(built.graphDir) 5,11,17").hasPrefix("ERROR forbidden"))
        XCTAssertTrue(h.handle("READER \(rid) TILED CLOSE x00000001").hasPrefix("ERROR forbidden"))
        XCTAssertTrue(h.handle("READER \(rid) TILED TICK x00000001 1").hasPrefix("ERROR forbidden"))
    }

    /// D5/D9 · the check above could not fail on finding 19: it asserted
    /// only WHICH verbs return `OK` versus `ERROR forbidden`, never what a
    /// reader's query does to the router. `tickLoad`/`load` mutate
    /// `tickResident`/`tickLru` and increment `loadCount`/`evictCount` —
    /// the very counters `TILED STATUS` reports. The ruling: tile residency
    /// is a CACHE, not graph state, so the TILED queries stay reader-allowed
    /// and the counters are DOCUMENTED as router-wide. This test pins that
    /// documented behaviour, with the expectation derived from the primary's
    /// own STATUS rather than from the reader's reply.
    func testReaderTiledQueryMovesTheRouterWideCounters() throws {
        let built = try buildSide44()
        let h = built.fixture.handler
        XCTAssertTrue(h.handle("TILED OPEN \(built.graphDir) 1").hasPrefix("OK TILED OPEN"))
        let rid = try openReaderId(h)

        func loadsFromPrimaryStatus() -> Int {
            let s = h.handle("TILED STATUS x00000001")
            guard let r = s.range(of: "loads="),
                  let space = s.range(of: " ", range: r.upperBound..<s.endIndex),
                  let v = Int(s[r.upperBound..<space.lowerBound]) else {
                XCTFail("no loads= in \(s)"); return -1
            }
            return v
        }

        let before = loadsFromPrimaryStatus()
        // Walk every tile from a reader session, with room for one resident.
        for seedIndex in [0, built.report.globalOf.count - 1] {
            let seed = built.report.globalOf[seedIndex]
            XCTAssertTrue(h.handle("READER \(rid) TILED BFS x00000001 \(seed) 2").hasPrefix("OK TILED BFS"))
        }
        let after = loadsFromPrimaryStatus()

        XCTAssertGreaterThan(after, before,
            "TILED STATUS's loads=/evicts= are router-wide counters that ANY session's query moves — "
            + "if this ever stops being true the docs in docs/wiki/dsl.md are wrong")
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

    // MARK: - TILED TICK / TILED GET grammar (ticking gates W5)

    func testParseTiledTickDefaults() {
        guard case .tiledTick(let id, let n, let sync) = DSLParser.parse("TILED TICK x00000001") else {
            XCTFail("expected .tiledTick"); return
        }
        XCTAssertEqual(id, "x00000001")
        XCTAssertEqual(n, 1)
        XCTAssertFalse(sync)
    }

    func testParseTiledTickExplicitN() {
        guard case .tiledTick(_, let n, let sync) = DSLParser.parse("TILED TICK x00000001 7") else {
            XCTFail("expected .tiledTick"); return
        }
        XCTAssertEqual(n, 7)
        XCTAssertFalse(sync)
    }

    func testParseTiledTickSyncOnly() {
        guard case .tiledTick(_, let n, let sync) = DSLParser.parse("TILED TICK x00000001 SYNC") else {
            XCTFail("expected .tiledTick"); return
        }
        XCTAssertEqual(n, 1)
        XCTAssertTrue(sync)
    }

    func testParseTiledTickNAndSync() {
        guard case .tiledTick(_, let n, let sync) = DSLParser.parse("TILED TICK x00000001 7 SYNC") else {
            XCTFail("expected .tiledTick"); return
        }
        XCTAssertEqual(n, 7)
        XCTAssertTrue(sync)
    }

    func testParseTiledTickMissingIdIsUnknown() {
        guard case .unknown = DSLParser.parse("TILED TICK") else {
            XCTFail("expected .unknown"); return
        }
    }

    func testParseTiledTickTrailingGarbageIsUnknown() {
        guard case .unknown = DSLParser.parse("TILED TICK x00000001 7 SYNC EXTRA") else {
            XCTFail("expected .unknown"); return
        }
    }

    func testTiledTickHandlerRejectsNOutOfRange() throws {
        let built = try buildSide44()
        let h = built.fixture.handler
        XCTAssertTrue(h.handle("TILED OPEN \(built.graphDir) 1").hasPrefix("OK TILED OPEN"))
        let reply = h.handle("TILED TICK x00000001 0")
        XCTAssertTrue(reply.hasPrefix("ERROR out_of_range"), reply)
        XCTAssertTrue(reply.contains("0"), reply)
    }

    func testParseTiledGet() {
        guard case .tiledGetTruth(let id, let g) = DSLParser.parse("TILED GET x00000001 42 TRUTH") else {
            XCTFail("expected .tiledGetTruth"); return
        }
        XCTAssertEqual(id, "x00000001")
        XCTAssertEqual(g, 42)
    }

    func testParseTiledGetMissingTruthIsUnknown() {
        guard case .unknown = DSLParser.parse("TILED GET x00000001 42") else {
            XCTFail("expected .unknown"); return
        }
    }

    func testParseTiledGetWrongTrailingTokenIsUnknown() {
        guard case .unknown = DSLParser.parse("TILED GET x00000001 42 RANK") else {
            XCTFail("expected .unknown"); return
        }
    }

    // MARK: - W5: daemon ticks vs TILED ticks

    /// Small fixed-seed RNG (seed 1) for the 64-node sample the W5 gate
    /// asks for — deterministic across runs, not the system RNG.
    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    private static func parseIntField(_ line: String, key: String) throws -> Int {
        for token in line.split(separator: " ") {
            if token.hasPrefix("\(key)=") {
                if let v = Int(token.dropFirst(key.count + 1)) { return v }
            }
        }
        throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "no \(key)= field in: \(line)"])
    }

    func testW5FiveDaemonTicksEqualFiveTiledTicksRank() async throws {
        try await runW5FiveTicksEqual(daemonTickVerb: "TICK", tiledSyncSuffix: "")
    }

    func testW5FiveDaemonTicksEqualFiveTiledTicksSync() async throws {
        try await runW5FiveTicksEqual(daemonTickVerb: "TICK_SYNC", tiledSyncSuffix: " SYNC")
    }

    /// `SAVE TILED` at daemon tickCount 0, `TILED OPEN`, then 5 daemon
    /// ticks vs 5 `TILED TICK`s from the same start: every tick number
    /// agrees, the router's `truthArray()` equals the daemon engine's own
    /// truth buffer over ALL nodes, 64 seeded `TILED GET … TRUTH` lines
    /// agree too, and `TILED STATUS` shows `epoch=5/5`. Then one `TILED
    /// TICK <id> 3` vs 3 more daemon ticks — epoch 8, totals equal.
    private func runW5FiveTicksEqual(daemonTickVerb: String, tiledSyncSuffix: String) async throws {
        let built = try buildSide44()
        let h = built.fixture.handler
        XCTAssertTrue(h.handle("TILED OPEN \(built.graphDir) 1").hasPrefix("OK TILED OPEN"))
        let routerId = "x00000001"

        for i in 1...5 {
            let daemonReply = h.handle("\(daemonTickVerb) 1")
            XCTAssertTrue(daemonReply.hasPrefix("OK \(daemonTickVerb) 1"), daemonReply)
            let daemonTotal = try Self.parseIntField(daemonReply, key: "total")
            XCTAssertEqual(daemonTotal, i, "daemon tick \(i)")

            let tiledReply = h.handle("TILED TICK \(routerId) 1\(tiledSyncSuffix)")
            XCTAssertTrue(tiledReply.hasPrefix("OK TILED TICK"), tiledReply)
            let tiledTicks = try Self.parseIntField(tiledReply, key: "ticks")
            XCTAssertEqual(tiledTicks, i, "tiled tick \(i)")
            XCTAssertEqual(tiledTicks, daemonTotal, "tick \(i): daemon total and tiled ticks must agree")
        }

        guard let entry = h.tiledRouters[routerId] else {
            XCTFail("router not found"); return
        }
        let routerTruth = try await entry.router.truthArray()
        let daemonTruth = h.engine.readTruthStates()
        // `truthArray()` returns in the ORIGINAL (pre-tiling) engine's own
        // index order (via `engineIndexOf`) — the same order `SAVE TILED`
        // split FROM, i.e. the daemon's own live engine — so no `globalOf`
        // indirection is needed for this comparison.
        XCTAssertEqual(routerTruth, daemonTruth, "router truthArray must equal the daemon engine's truth after 5 ticks")

        var rng = SeededRNG(seed: 1)
        let sampleIndices = Array(0..<h.nodeCount).shuffled(using: &rng).prefix(64)
        for i in sampleIndices {
            let g = built.report.globalOf[i]
            let reply = h.handle("TILED GET \(routerId) \(g) TRUTH")
            XCTAssertEqual(reply, "OK TILED GET id=\(routerId) node=\(g) truth=\(daemonTruth[i])")
        }

        let statusReply = h.handle("TILED STATUS \(routerId)")
        XCTAssertTrue(statusReply.contains("epoch=5/5"), statusReply)

        var daemonTotalAfter8 = 0
        for _ in 1...3 {
            let r = h.handle("\(daemonTickVerb) 1")
            daemonTotalAfter8 = try Self.parseIntField(r, key: "total")
        }
        XCTAssertEqual(daemonTotalAfter8, 8, "3 more daemon ticks")

        let tiledReply2 = h.handle("TILED TICK \(routerId) 3\(tiledSyncSuffix)")
        let tiledTicksAfter8 = try Self.parseIntField(tiledReply2, key: "ticks")
        XCTAssertEqual(tiledTicksAfter8, 8, "one TILED TICK of 3")
        XCTAssertEqual(tiledTicksAfter8, daemonTotalAfter8, "epoch 8: daemon and tiled totals must agree")
    }

    func testW5TickFromSavedTickCountNonZero() async throws {
        let root = tempDir()
        let f = try makeFixture(side: 44, dataRoot: root)
        let h = f.handler
        for _ in 1...4 { _ = h.handle("TICK 1") }
        XCTAssertEqual(h.tickCount, 4)

        let graphDir = "\(root)/g44nz"
        let saveReply = h.handle("SAVE TILED \(graphDir) 5,11,17")
        XCTAssertTrue(saveReply.hasPrefix("OK SAVE TILED"), saveReply)

        XCTAssertTrue(h.handle("TILED OPEN \(graphDir) 1").hasPrefix("OK TILED OPEN"))
        let routerId = "x00000001"

        for expected in [5, 6] {
            let daemonReply = h.handle("TICK 1")
            let daemonTotal = try Self.parseIntField(daemonReply, key: "total")
            XCTAssertEqual(daemonTotal, expected, "daemon tick reaching \(expected)")

            let tiledReply = h.handle("TILED TICK \(routerId) 1")
            let tiledTicks = try Self.parseIntField(tiledReply, key: "ticks")
            XCTAssertEqual(tiledTicks, expected, "tiled tick reaching \(expected)")
        }

        guard let entry = h.tiledRouters[routerId] else {
            XCTFail("router not found"); return
        }
        let routerTruth = try await entry.router.truthArray()
        XCTAssertEqual(routerTruth, h.engine.readTruthStates())
    }

    // MARK: - AMENDMENT 4, letter 1: SAVE TILED writes ONE EPOCH everywhere

    /// The four places the contract names, parsed in this test's own code
    /// (raw bytes for the body header and the strips, `Codable` only for
    /// the two JSON files) rather than through the writer that produced
    /// them.
    private struct TileEpochs {
        let manifest: UInt64
        let meta: UInt64
        let body: UInt64
        let strip0: (epoch: UInt64, values: [UInt64: StripValue])
        let strip1: (epoch: UInt64, values: [UInt64: StripValue])
    }

    private func u32LE(_ d: Data, _ off: Int) -> UInt64 {
        UInt64(d[off]) | UInt64(d[off + 1]) << 8 | UInt64(d[off + 2]) << 16 | UInt64(d[off + 3]) << 24
    }

    private func u64LE(_ d: Data, _ off: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(d[off + i]) << (8 * i) }
        return v
    }

    /// One parity-strip entry's two truth bytes (AMENDMENT 8).
    private struct StripValue: Equatable { let pre: UInt8; let post: UInt8 }

    /// `DAHA` v2 parity strip: magic(4) version(4)=2 kind(4) count(4)
    /// source(8) target(8) epoch(8), then count × (local u64 + truth_pre
    /// u8 + truth_post u8 + type u8 + 5 pad). Parsed here in this test's
    /// own code, from the format paragraph, not through the writer that
    /// produced it.
    private func parseStrip(_ path: String) throws -> (epoch: UInt64, values: [UInt64: StripValue]) {
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertGreaterThanOrEqual(d.count, 40, "strip \(path) truncated")
        XCTAssertEqual(Array(d[0..<4]), [0x44, 0x41, 0x48, 0x41], "strip \(path) magic")
        XCTAssertEqual(u32LE(d, 4), 2, "strip \(path) format version")
        let count = Int(u32LE(d, 12))
        var values: [UInt64: StripValue] = [:]
        for i in 0..<count {
            let off = 40 + i * 16
            values[u64LE(d, off)] = StripValue(pre: d[off + 8], post: d[off + 9])
        }
        return (u64LE(d, 32), values)
    }

    private func parseTileEpochs(root: String, name: String) throws -> [UInt32: TileEpochs] {
        let manifest = try TiledGraphFiles.readManifest(dataRoot: root, name: name)
        var result: [UInt32: TileEpochs] = [:]
        for entry in manifest.tiles {
            let dir = TiledGraphFiles.tileDirectory(dataRoot: root, name: name, entry: entry)
            let metaData = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/meta.json"))
            let meta = try JSONDecoder().decode(TileMeta.self, from: metaData)
            let bodyData = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/body.dags"))
            result[entry.id] = TileEpochs(
                manifest: entry.tickEpoch,
                meta: meta.lastPersistedTickEpoch,
                body: u32LE(bodyData, 20),
                strip0: try parseStrip("\(dir)/halo_lower.0.bin"),
                strip1: try parseStrip("\(dir)/halo_lower.1.bin")
            )
        }
        return result
    }

    /// After `SAVE TILED` at a non-zero tick count, the manifest entry,
    /// `meta.json`, the `body.dags` header and BOTH parity strips carry
    /// ONE epoch: parity `k mod 2` at `k`, the other parity at `k − 1`
    /// with the SAME truth values (at rest the two differ only in their
    /// recorded epoch). This is the state the blind verifier found
    /// self-inconsistent — manifest 4, everything else 0 — which made
    /// sync's first world tick look for a `k − 1` strip that was never
    /// written.
    func testW5SaveTiledWritesOneEpochEverywhere() throws {
        for savedCount in [0, 4] {
            let root = tempDir()
            let f = try makeFixture(side: 44, dataRoot: root)
            let h = f.handler
            for _ in 0..<savedCount { _ = h.handle("TICK 1") }
            XCTAssertEqual(h.tickCount, UInt32(savedCount))

            let graphDir = "\(root)/g44epoch\(savedCount)"
            XCTAssertTrue(h.handle("SAVE TILED \(graphDir) 5,11,17").hasPrefix("OK SAVE TILED"))

            let k = UInt64(savedCount)
            let prior: UInt64 = k == 0 ? 0 : k - 1
            let epochs = try parseTileEpochs(root: root, name: "g44epoch\(savedCount)")
            XCTAssertEqual(epochs.count, 4)
            for (id, e) in epochs.sorted(by: { $0.key < $1.key }) {
                XCTAssertEqual(e.manifest, k, "tile \(id) manifest entry tickEpoch (saved \(k))")
                XCTAssertEqual(e.meta, k, "tile \(id) meta.json lastPersistedTickEpoch (saved \(k))")
                XCTAssertEqual(e.body, k, "tile \(id) body.dags header tickCount (saved \(k))")
                let current = k % 2 == 0 ? e.strip0 : e.strip1
                let other = k % 2 == 0 ? e.strip1 : e.strip0
                XCTAssertEqual(current.epoch, k, "tile \(id) parity-\(k % 2) strip epoch (saved \(k))")
                XCTAssertEqual(other.epoch, prior, "tile \(id) parity-\(1 - k % 2) strip epoch (saved \(k))")
                XCTAssertEqual(
                    current.values, other.values,
                    "tile \(id): at rest both parity strips carry the same truths (saved \(k))"
                )
                // AMENDMENT 8: at rest there is no round and so no latch to
                // be before or after — both truth bytes of every entry in
                // both parity strips carry the saved truth.
                for (local, v) in current.values.sorted(by: { $0.key < $1.key }) {
                    XCTAssertEqual(
                        v.pre, v.post,
                        "tile \(id) local \(local): SAVE TILED writes truthPre == truthPost (saved \(k))"
                    )
                }
            }

            // And the clause the FAIL was about: the first SYNC world tick
            // off this directory succeeds.
            XCTAssertTrue(h.handle("TILED OPEN \(graphDir) 1").hasPrefix("OK TILED OPEN"))
            let reply = h.handle("TILED TICK x0000000\(savedCount == 0 ? 1 : 1) 1 SYNC")
            XCTAssertTrue(reply.hasPrefix("OK TILED TICK"), "first SYNC tick from saved \(k): \(reply)")
            XCTAssertEqual(try Self.parseIntField(reply, key: "ticks"), savedCount + 1)
            _ = h.handle("TILED CLOSE x00000001")
        }
    }

    // MARK: - AMENDMENT 4, letter 2: the (mode × saved count × path) grid

    /// Eight cells, none by implication: {rank, sync} × {saved 0, saved 4}
    /// × {library `worldTick`, daemon `TILED TICK`}. Every cell's truth
    /// array is compared against `TiledReference` — the evaluator that
    /// never calls the engine — after the SAME number of ticks. The
    /// (sync, saved 4, daemon) cell is the one the blind verifier found
    /// broken and had no test.
    private func runSavedCountGridCell(
        mode: TickMode, savedCount: Int, viaDaemon: Bool
    ) async throws {
        let ticksAfterSave = 3
        let root = tempDir()
        let f = try makeFixture(side: 44, dataRoot: root)
        let h = f.handler
        let reference = TiledReference(engine: h.engine)
        var refVector = h.engine.readTruthStates()

        let daemonVerb = (mode == .rank) ? "TICK" : "TICK_SYNC"
        for _ in 0..<savedCount {
            _ = h.handle("\(daemonVerb) 1")
            refVector = (mode == .rank) ? reference.tickRank(refVector) : reference.tickSync(refVector)
        }
        XCTAssertEqual(
            h.engine.readTruthStates(), refVector,
            "daemon engine vs reference before save (mode=\(mode) saved=\(savedCount))"
        )

        let label = "g44grid\(mode == .rank ? "rank" : "sync")\(savedCount)\(viaDaemon ? "d" : "l")"
        let cell = "mode=\(mode) saved=\(savedCount) via=\(viaDaemon ? "daemon" : "library")"

        if viaDaemon {
            let graphDir = "\(root)/\(label)"
            XCTAssertTrue(h.handle("SAVE TILED \(graphDir) 5,11,17").hasPrefix("OK SAVE TILED"))
            XCTAssertTrue(h.handle("TILED OPEN \(graphDir) 1").hasPrefix("OK TILED OPEN"))
            let routerId = "x00000001"
            let suffix = (mode == .rank) ? "" : " SYNC"
            for i in 1...ticksAfterSave {
                let reply = h.handle("TILED TICK \(routerId) 1\(suffix)")
                XCTAssertTrue(reply.hasPrefix("OK TILED TICK"), "\(cell) tick \(i): \(reply)")
                XCTAssertEqual(
                    try Self.parseIntField(reply, key: "ticks"), savedCount + i,
                    "\(cell) tick number"
                )
                refVector = (mode == .rank) ? reference.tickRank(refVector) : reference.tickSync(refVector)
            }
            guard let entry = h.tiledRouters[routerId] else { return XCTFail("\(cell): router not found") }
            let got = try await entry.router.truthArray()
            XCTAssertEqual(
                TiledReference.differing(got, refVector).count, 0,
                "\(cell): router truth vs reference after \(savedCount + ticksAfterSave) ticks"
            )
        } else {
            _ = try TiledGraphFiles.write(
                engine: h.engine, grid: f.grid, dataRoot: root, name: label,
                boundaries: [5, 11, 17], tickCount: UInt32(savedCount)
            )
            let router = try await TiledGraphRouter(
                dataRoot: root, graphName: label, maxResidentTiles: 1
            )
            for i in 1...ticksAfterSave {
                let report = try await router.worldTick(mode: mode, count: 1)
                XCTAssertEqual(report.epoch, UInt64(savedCount + i), "\(cell) epoch")
                refVector = (mode == .rank) ? reference.tickRank(refVector) : reference.tickSync(refVector)
            }
            let got = try await router.truthArray()
            XCTAssertEqual(
                TiledReference.differing(got, refVector).count, 0,
                "\(cell): router truth vs reference after \(savedCount + ticksAfterSave) ticks"
            )
        }
    }

    func testW5GridRankSaved0Library() async throws {
        try await runSavedCountGridCell(mode: .rank, savedCount: 0, viaDaemon: false)
    }
    func testW5GridRankSaved4Library() async throws {
        try await runSavedCountGridCell(mode: .rank, savedCount: 4, viaDaemon: false)
    }
    func testW5GridSyncSaved0Library() async throws {
        try await runSavedCountGridCell(mode: .sync, savedCount: 0, viaDaemon: false)
    }
    func testW5GridSyncSaved4Library() async throws {
        try await runSavedCountGridCell(mode: .sync, savedCount: 4, viaDaemon: false)
    }
    func testW5GridRankSaved0Daemon() async throws {
        try await runSavedCountGridCell(mode: .rank, savedCount: 0, viaDaemon: true)
    }
    func testW5GridRankSaved4Daemon() async throws {
        try await runSavedCountGridCell(mode: .rank, savedCount: 4, viaDaemon: true)
    }
    func testW5GridSyncSaved0Daemon() async throws {
        try await runSavedCountGridCell(mode: .sync, savedCount: 0, viaDaemon: true)
    }
    /// The cell the verifier found broken: `TILED TICK … SYNC` off a graph
    /// `SAVE TILED` wrote from a non-zero daemon tick count.
    func testW5GridSyncSaved4Daemon() async throws {
        try await runSavedCountGridCell(mode: .sync, savedCount: 4, viaDaemon: true)
    }

    // MARK: - W5: SAVE TILED refuses a cross-tile BACK_EDGE

    func testW5SaveTiledRefusesCrossTileBackEdge() throws {
        let root = tempDir()
        let f = try makeFixture(side: 16, dataRoot: root)
        let h = f.handler

        let boundaries = TiledFixture.boundaries(side: 16, tiles: 2)
        XCTAssertEqual(boundaries.count, 1, "expected one interior boundary for tiles=2")
        let boundary = boundaries[0]

        let ranks = h.engine.readRanks()
        guard let dstCandidate = (0..<h.nodeCount).first(where: { ranks[$0] < boundary }),
              let srcCandidate = (0..<h.nodeCount).first(where: { ranks[$0] >= boundary }) else {
            XCTFail("could not find nodes on both sides of the boundary"); return
        }

        // Clear dst's own combinational inputs (zero fan-in — the
        // register invariant) then register a CROSS-tile back edge.
        XCTAssertTrue(h.handle("CLEAR \(dstCandidate) EDGES").hasPrefix("OK CLEAR"))
        let connectReply = h.handle("CONNECT BACK FROM \(srcCandidate) TO \(dstCandidate)")
        XCTAssertTrue(connectReply.hasPrefix("OK CONNECT BACK"), connectReply)

        let graphDir = "\(root)/g16backedge"
        let saveReply = h.handle("SAVE TILED \(graphDir) \(boundary)")
        XCTAssertEqual(saveReply, "ERROR bad_value: back edge crosses a tile boundary (\(srcCandidate)→\(dstCandidate))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: graphDir), "no graph directory must exist after refusal")

        // CLEAR the back edge, register one whose src and dst SHARE a
        // tile (same dst, a different src on dst's own side) — SAVE
        // TILED must now succeed.
        XCTAssertTrue(h.handle("CLEAR \(dstCandidate) BACK_EDGES").hasPrefix("OK CLEAR"))
        guard let srcSameTile = (0..<h.nodeCount).first(where: { ranks[$0] < boundary && $0 != dstCandidate }) else {
            XCTFail("could not find an intra-tile src"); return
        }
        XCTAssertTrue(h.handle("CONNECT BACK FROM \(srcSameTile) TO \(dstCandidate)").hasPrefix("OK CONNECT BACK"))

        let saveReply2 = h.handle("SAVE TILED \(graphDir) \(boundary)")
        XCTAssertTrue(saveReply2.hasPrefix("OK SAVE TILED"), saveReply2)
    }

    // MARK: - AMENDMENT 3 (D): TILED OPEN completes a partial round

    func testW5TiledOpenCompletesPartialRound() async throws {
        let built = try buildSide44()
        let h = built.fixture.handler
        XCTAssertTrue(h.handle("TILED OPEN \(built.graphDir) 1").hasPrefix("OK TILED OPEN"))
        let firstRouterId = "x00000001"

        for _ in 1...2 {
            _ = h.handle("TICK 1")
            _ = h.handle("TILED TICK \(firstRouterId) 1")
        }
        // Snapshot the DATA ROOT (not the graph dir itself), so
        // `readManifest(dataRoot: epoch2Snapshot, name: "g44")` finds
        // `epoch2Snapshot/g44/manifest.json` — the same `dataRoot`/`name`
        // split `TiledGraphFiles` uses everywhere else.
        let epoch2Snapshot = built.root + "-epoch2"
        try? FileManager.default.removeItem(atPath: epoch2Snapshot)
        try FileManager.default.copyItem(atPath: built.root, toPath: epoch2Snapshot)
        defer { try? FileManager.default.removeItem(atPath: epoch2Snapshot) }

        _ = h.handle("TICK 1")
        let tiledTickReply = h.handle("TILED TICK \(firstRouterId) 1")
        XCTAssertTrue(tiledTickReply.contains("ticks=3"), tiledTickReply)
        XCTAssertEqual(h.tickCount, 3)

        XCTAssertTrue(h.handle("TILED CLOSE \(firstRouterId)").hasPrefix("OK TILED CLOSE"))

        // Forge the between-tiles tear directly on disk: roll the two
        // LOWEST-id tiles (rank mode's descending order processes the
        // HIGHEST ids first, so these are "later in the order") back to
        // their epoch-2 files and manifest entries. Every flush.wal stays
        // clean.
        let manifest = try TiledGraphFiles.readManifest(dataRoot: built.root, name: "g44")
        let epoch2Manifest = try TiledGraphFiles.readManifest(dataRoot: epoch2Snapshot, name: "g44")
        let descending = manifest.tiles.map { $0.id }.sorted(by: >)
        let restoredIds = Set(descending.suffix(2))
        var liveTiles = manifest.tiles
        for tileId in restoredIds {
            guard let liveEntry = liveTiles.first(where: { $0.id == tileId }),
                  let epoch2Entry = epoch2Manifest.tiles.first(where: { $0.id == tileId }) else {
                XCTFail("missing tile \(tileId)"); return
            }
            let liveDir = TiledGraphFiles.tileDirectory(dataRoot: built.root, name: "g44", entry: liveEntry)
            let epoch2Dir = TiledGraphFiles.tileDirectory(dataRoot: epoch2Snapshot, name: "g44", entry: epoch2Entry)
            for name in ["body.dags", "body.dags.sha256", "meta.json", "halo_lower.0.bin", "halo_lower.1.bin", "flush.wal"] {
                let src = "\(epoch2Dir)/\(name)"
                let dst = "\(liveDir)/\(name)"
                try? FileManager.default.removeItem(atPath: dst)
                if FileManager.default.fileExists(atPath: src) {
                    try FileManager.default.copyItem(atPath: src, toPath: dst)
                }
            }
            if let idx = liveTiles.firstIndex(where: { $0.id == tileId }) {
                liveTiles[idx] = epoch2Entry
            }
        }
        let tornManifest = TiledGraphFiles.Manifest(
            format: manifest.format, version: manifest.version, name: manifest.name,
            boundaries: manifest.boundaries, globalNodeCount: manifest.globalNodeCount, tiles: liveTiles
        )
        try TiledGraphFiles.writeManifest(dataRoot: built.root, name: "g44", manifest: tornManifest)

        // TILED OPEN on the torn directory — writer role (the daemon's
        // only role), recovers (nothing dangling) and completes the
        // partial round before returning.
        let openReply = h.handle("TILED OPEN \(built.graphDir) 1")
        XCTAssertTrue(openReply.hasPrefix("OK TILED OPEN"), openReply)
        XCTAssertTrue(openReply.contains("recovered=0"), openReply)
        XCTAssertTrue(openReply.contains("completed=\(restoredIds.count)"), openReply)
        let secondRouterId = "x00000002"

        let statusReply = h.handle("TILED STATUS \(secondRouterId)")
        XCTAssertTrue(statusReply.contains("epoch=3/3"), statusReply)

        var rng = SeededRNG(seed: 1)
        let daemonTruth = h.engine.readTruthStates()
        let sampleIndices = Array(0..<h.nodeCount).shuffled(using: &rng).prefix(64)
        for i in sampleIndices {
            let g = built.report.globalOf[i]
            let reply = h.handle("TILED GET \(secondRouterId) \(g) TRUTH")
            XCTAssertEqual(reply, "OK TILED GET id=\(secondRouterId) node=\(g) truth=\(daemonTruth[i])")
        }
    }

    // MARK: - D2 · the tiled writers check the daemon's own shm

    /// Audit finding 9 — the router's world size is `manifest.globalNodeCount`,
    /// entirely independent of the `nodeCount` that sized the mapping. Only
    /// ~1.5x nodeCount BFS rows (16 B each) and ~3x nodeCount select ids
    /// (8 B each) fit, and neither writer checked.
    func testTiledWritersRefuseWhenTheResultDoesNotFitTheMapping() throws {
        let root = tempDir()
        let big = try makeFixture(side: 44, dataRoot: root)
        let graphDir = "\(root)/g44"
        XCTAssertTrue(big.handler.handle("SAVE TILED \(graphDir) 5,11,17").hasPrefix("OK SAVE TILED"))

        // A daemon whose mapping holds 64 bytes, over a 1,936-node world.
        let small = try HandlerFixture(side: 44, dataRoot: root, shmBytes: 64, maxRank: 64)
        XCTAssertTrue(small.handler.handle("TILED OPEN \(graphDir) 2").hasPrefix("OK TILED OPEN"))

        let bfs = small.handler.handle("TILED BFS x00000001 0 8")
        XCTAssertTrue(bfs.hasPrefix("ERROR out_of_range"), bfs)
        XCTAssertTrue(bfs.contains("64"), bfs)

        let select = small.handler.handle("TILED SELECT x00000001 0 0 63")
        XCTAssertTrue(select.hasPrefix("ERROR out_of_range"), select)
        XCTAssertTrue(select.contains("64"), select)

        XCTAssertEqual(small.shm.bindMemory(to: UInt32.self, capacity: 2)[0], 0,
                       "rows were written despite the refusal")
    }

}
