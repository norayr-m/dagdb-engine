import XCTest
@testable import DagDB

final class TiledGraphRouterTests: XCTestCase {

    // MARK: - Scratch dirs (NSTemporaryDirectory, never the repo)

    private func scratchDir(_ label: String) -> String {
        let dir = NSTemporaryDirectory() + "dagdb-tiling-router-\(label)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeScratch(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// A small, fast manifest (side 16, 2 tiles) for tests that only need
    /// SOME valid router (init now reads `manifest.json` — AMENDMENT
    /// 1-era router contract — so every router-constructing test needs a
    /// real graph directory, not a bare `/tmp` path).
    private func smallManifestDir(_ label: String) throws -> (dir: String, name: String) {
        let object = try TiledFixture.generate(side: 16)
        let dir = scratchDir(label)
        let boundaries = TiledFixture.boundaries(side: 16, tiles: 2)
        _ = try TiledGraphFiles.write(object: object, dataRoot: dir, name: "g", boundaries: boundaries)
        return (dir, "g")
    }

    // MARK: - Construction

    func testInitStoresDataRootAndGraphName() async throws {
        let (dir, name) = try smallManifestDir("init-basic")
        defer { removeScratch(dir) }
        let r = try await TiledGraphRouter(dataRoot: dir, graphName: name)
        let s = await r.status()
        XCTAssertEqual(s.dataRoot, dir)
        XCTAssertEqual(s.graphName, name)
        XCTAssertEqual(s.residentTileCount, 0)
        XCTAssertEqual(s.maxResidentTiles, 2)
        XCTAssertEqual(s.totalTickCount, 0)
        XCTAssertEqual(s.loads, 0)
        XCTAssertEqual(s.evicts, 0)
        XCTAssertEqual(s.refused, 0)
        XCTAssertNil(s.lastRefusal)
        XCTAssertEqual(s.maxResidentSeen, 0)
    }

    func testInitWithCustomResidentBudget() async throws {
        let (dir, name) = try smallManifestDir("init-budget")
        defer { removeScratch(dir) }
        let r = try await TiledGraphRouter(dataRoot: dir, graphName: name, maxResidentTiles: 4)
        let s = await r.status()
        XCTAssertEqual(s.maxResidentTiles, 4)
    }

    func testInitThrowsManifestMissing() async throws {
        let dir = scratchDir("init-missing")
        defer { removeScratch(dir) }
        do {
            _ = try await TiledGraphRouter(dataRoot: dir, graphName: "nope")
            XCTFail("expected manifestMissing")
        } catch RouterError.manifestMissing(let path) {
            XCTAssertTrue(path.contains("nope"))
        }
    }

    // MARK: - Tile locality helpers (pure)

    func testTileOfDecodesUpperBits() async throws {
        let (dir, name) = try smallManifestDir("tileof")
        defer { removeScratch(dir) }
        let r = try await TiledGraphRouter(dataRoot: dir, graphName: name)
        let id = try GlobalNodeID(tileId: 12, localNodeId: 5042)
        XCTAssertEqual(r.tileOf(id), 12)
    }

    func testLocalIdOfDecodesLowerBits() async throws {
        let (dir, name) = try smallManifestDir("localidof")
        defer { removeScratch(dir) }
        let r = try await TiledGraphRouter(dataRoot: dir, graphName: name)
        let id = try GlobalNodeID(tileId: 12, localNodeId: 5042)
        XCTAssertEqual(r.localIdOf(id), 5042)
    }

    func testTileLocalityHelpersAtBoundaries() async throws {
        let (dir, name) = try smallManifestDir("boundaries")
        defer { removeScratch(dir) }
        let r = try await TiledGraphRouter(dataRoot: dir, graphName: name)
        let zero = try GlobalNodeID(tileId: 0, localNodeId: 0)
        XCTAssertEqual(r.tileOf(zero), 0)
        XCTAssertEqual(r.localIdOf(zero), 0)

        let max = try GlobalNodeID(tileId: 0xFF_FFFF, localNodeId: 0xFF_FFFF_FFFF)
        XCTAssertEqual(r.tileOf(max), 0xFF_FFFF)
        XCTAssertEqual(r.localIdOf(max), 0xFF_FFFF_FFFF)
    }

    // MARK: - Stubs still throw notImplemented (out of this contract's scope)

    func testRunQueryStubThrows() async throws {
        let (dir, name) = try smallManifestDir("runquery-stub")
        defer { removeScratch(dir) }
        let r = try await TiledGraphRouter(dataRoot: dir, graphName: name)
        do {
            _ = try await r.runQuery("STATUS")
            XCTFail("expected notImplemented")
        } catch RouterError.notImplemented(let what) {
            XCTAssertTrue(what.contains("runQuery"))
        }
    }

    func testSaveAndCloseStubsThrow() async throws {
        let (dir, name) = try smallManifestDir("save-close-stub")
        defer { removeScratch(dir) }
        let r = try await TiledGraphRouter(dataRoot: dir, graphName: name)
        do { try await r.save();  XCTFail("expected notImplemented") }
        catch RouterError.notImplemented { /* expected */ }
        do { try await r.close(); XCTFail("expected notImplemented") }
        catch RouterError.notImplemented { /* expected */ }
    }

    // MARK: - TileMeta + Crossing Codable round-trip

    func testTileMetaCodableRoundTrip() throws {
        let original = TileMeta(
            id: 7,
            rankLo: 100,
            rankHi: 200,
            nodeCount: 1_000_000,
            lastPersistedTickEpoch: 42,
            crossingsOut: [
                Crossing(localNode: 5, remoteNode: try GlobalNodeID(tileId: 8, localNodeId: 99))
            ],
            crossingsIn: []
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TileMeta.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.rankLo, original.rankLo)
        XCTAssertEqual(decoded.rankHi, original.rankHi)
        XCTAssertEqual(decoded.nodeCount, original.nodeCount)
        XCTAssertEqual(decoded.lastPersistedTickEpoch, original.lastPersistedTickEpoch)
        XCTAssertEqual(decoded.crossingsOut.count, 1)
        XCTAssertEqual(decoded.crossingsOut[0].localNode, 5)
        XCTAssertEqual(decoded.crossingsOut[0].remoteNode.tileId, 8)
        XCTAssertEqual(decoded.crossingsOut[0].remoteNode.localNodeId, 99)
    }

    // MARK: - TileBuffer enum

    func testTileBufferCasesAreStable() {
        // Stable case-name set is what other code depends on for
        // selective dirty-flush bookkeeping. Lock the set explicitly.
        let names = Set(TileBuffer.allCases.map { $0.rawValue })
        XCTAssertEqual(names, ["rank", "truth", "nodeType", "lut", "neighbors", "halo"])
    }

    // MARK: - Resident-set bookkeeping (no load yet)

    func testIsResidentReportsFalseInitially() async throws {
        let (dir, name) = try smallManifestDir("isresident")
        defer { removeScratch(dir) }
        let r = try await TiledGraphRouter(dataRoot: dir, graphName: name)
        let resident = await r.isResident(7)
        XCTAssertFalse(resident)
    }

    func testResidentTileIdsEmptyInitially() async throws {
        let (dir, name) = try smallManifestDir("residentids")
        defer { removeScratch(dir) }
        let r = try await TiledGraphRouter(dataRoot: dir, graphName: name)
        let ids = await r.residentTileIds()
        XCTAssertEqual(ids, [])
    }

    // MARK: - T2/T3/T4 shared helpers

    /// Sortable, XCTAssertEqual-able (raw global id, depth) pair — Swift
    /// tuples aren't Equatable, so BFS truth/result comparisons go
    /// through this instead of bare `[(UInt64, Int32)]`.
    private struct DepthPair: Equatable, CustomStringConvertible {
        let raw: UInt64
        let depth: Int32
        var description: String { "(\(raw),\(depth))" }
    }

    private struct WrittenObject {
        let dir: String
        let name: String
        let object: TiledFixture.Object
        let report: TiledGraphFiles.WriteReport
    }

    private func writeTiledObject(side: Int, tiles: Int, label: String) throws -> WrittenObject {
        let object = try TiledFixture.generate(side: side)
        let dir = scratchDir(label)
        let boundaries = TiledFixture.boundaries(side: side, tiles: tiles)
        let report = try TiledGraphFiles.write(object: object, dataRoot: dir, name: "g", boundaries: boundaries)
        return WrittenObject(dir: dir, name: "g", object: object, report: report)
    }

    /// Untiled ground truth for one (seed, depth, direction), as a
    /// sorted `[DepthPair]` of GLOBAL ids — the single engine's own
    /// `bfsDepthsUndirected`/`bfsDepthsBackward` is unbounded (no depth
    /// parameter), so truncate to `depth` here for a fair comparison
    /// against the router's bounded walk (T2's letter).
    private func untiledBFSTruth(
        object: TiledFixture.Object, seedEngineIdx: Int, depth: Int, backward: Bool,
        globalOf: [UInt64]
    ) throws -> [DepthPair] {
        let result = backward
            ? try DagDBBFS.bfsDepthsBackward(engine: object.engine, nodeCount: object.nodeCount, from: seedEngineIdx)
            : try DagDBBFS.bfsDepthsUndirected(engine: object.engine, nodeCount: object.nodeCount, from: seedEngineIdx)
        var pairs: [DepthPair] = []
        for i in 0..<object.nodeCount {
            let d = result.depths[i]
            if d >= 0 && Int(d) <= depth {
                pairs.append(DepthPair(raw: globalOf[i], depth: d))
            }
        }
        return pairs.sorted { $0.raw < $1.raw }
    }

    private func routerBFSPairs(_ pairs: [(GlobalNodeID, UInt32)]) -> [DepthPair] {
        pairs.map { DepthPair(raw: $0.0.raw, depth: Int32($0.1)) }.sorted { $0.raw < $1.raw }
    }

    // MARK: - T2: BFS/ancestry equals untiled, across K and tilings

    /// Shared body. `depth <= 12`, `tilings` from {2,4,8}. For every
    /// tiling: write ONCE, compute untiled truth ONCE per (seed, depth,
    /// direction), then open a router per K in {1,2,4}(+8 on the 8-tile
    /// object as the null) against that SAME on-disk manifest — router
    /// reads never mutate tile files, so reuse across K is safe. Asserts
    /// tiled == untiled for every combo, K=8 evicts==0, and K=1 == K=4
    /// (K-independence).
    private func runT2BFS(side: Int, tilings: [Int], depths: [Int], label: String) async throws {
        for tiles in tilings {
            let w = try writeTiledObject(side: side, tiles: tiles, label: "\(label)-t\(tiles)")
            defer { removeScratch(w.dir) }
            let seeds = TiledFixture.seeds(for: w.object)

            var ks = [1, 2, 4]
            if tiles == 8 { ks.append(8) }

            var perK: [Int: [String: [DepthPair]]] = [:]

            for k in ks {
                let router = try await TiledGraphRouter(dataRoot: w.dir, graphName: w.name, maxResidentTiles: k)
                var results: [String: [DepthPair]] = [:]
                for seedIdx in seeds {
                    let seedGlobal = GlobalNodeID(raw: w.report.globalOf[seedIdx])
                    for depth in depths {
                        for backward in [false, true] {
                            let key = "\(seedIdx)_\(depth)_\(backward)"
                            let got = routerBFSPairs(
                                try await router.runBFS(seed: seedGlobal, depth: UInt32(depth), backward: backward)
                            )
                            let want = try untiledBFSTruth(
                                object: w.object, seedEngineIdx: seedIdx, depth: depth, backward: backward,
                                globalOf: w.report.globalOf
                            )
                            XCTAssertEqual(
                                got, want,
                                "side=\(side) tiles=\(tiles) K=\(k) seed=\(seedIdx) depth=\(depth) backward=\(backward)"
                            )
                            results[key] = got
                        }
                    }
                }
                perK[k] = results
                if k == 8 {
                    let s = await router.status()
                    XCTAssertEqual(s.evicts, 0, "K=8 null on 8 tiles must never evict (side=\(side))")
                }
            }

            if let r1 = perK[1], let r4 = perK[4] {
                for (key, v1) in r1 {
                    XCTAssertEqual(v1, r4[key], "K-independence mismatch side=\(side) tiles=\(tiles) key=\(key)")
                }
            }
        }
    }

    func testT2BFSEqualsUntiledAcrossKAndTilings_Side16() async throws {
        try await runT2BFS(side: 16, tilings: [2, 4, 8], depths: [1, 3, 6], label: "t2bfs16")
    }

    func testT2BFSEqualsUntiledAcrossKAndTilings_Side44() async throws {
        try await runT2BFS(side: 44, tilings: [2, 4, 8], depths: [1, 3, 6], label: "t2bfs44")
    }

    func testT2BFSEqualsUntiledAcrossKAndTilings_Side128() async throws {
        try await runT2BFS(side: 128, tilings: [2, 4, 8], depths: [1, 3, 6, 12], label: "t2bfs128")
    }

    // MARK: - T2: select equals untiled

    func testT2SelectEqualsUntiled() async throws {
        for side in TiledFixture.sides {
            let object = try TiledFixture.generate(side: side)
            let maxRank = object.maxRank
            let third = maxRank / 3
            // 3 (truth, rankLo, rankHi) triples per object; the third
            // spans the full range — 3+ tiles whenever tiling >= 4.
            let triples: [(UInt8, UInt64, UInt64)] = [
                (0, 0, third),
                (1, third, 2 * third),
                (2, 0, maxRank)
            ]
            for tiles in [2, 4, 8] {
                let dir = scratchDir("t2select-\(side)-\(tiles)")
                defer { removeScratch(dir) }
                let boundaries = TiledFixture.boundaries(side: side, tiles: tiles)
                let report = try TiledGraphFiles.write(object: object, dataRoot: dir, name: "g", boundaries: boundaries)

                var ks = [1, 2, 4]
                if tiles == 8 { ks.append(8) }
                for k in ks {
                    let router = try await TiledGraphRouter(dataRoot: dir, graphName: "g", maxResidentTiles: k)
                    for (truthVal, lo, hi) in triples {
                        let got = try await router.runSelect(truth: truthVal, rankLo: lo, rankHi: hi).map { $0.raw }
                        let index = TruthRankIndex()
                        let wantLocals = index.select(
                            truth: truthVal, rankLo: lo, rankHi: hi,
                            engine: object.engine, nodeCount: object.nodeCount
                        )
                        let want = wantLocals.map { report.globalOf[$0] }.sorted()
                        XCTAssertEqual(
                            got, want,
                            "side=\(side) tiles=\(tiles) K=\(k) truth=\(truthVal) range=[\(lo),\(hi)]"
                        )
                    }
                }
            }
        }
    }

    // MARK: - T3: residency

    func testT3Residency() async throws {
        let side = 128
        let object = try TiledFixture.generate(side: side)
        let dir = scratchDir("t3residency")
        defer { removeScratch(dir) }
        let boundaries = TiledFixture.boundaries(side: side, tiles: 8)
        let report = try TiledGraphFiles.write(object: object, dataRoot: dir, name: "g", boundaries: boundaries)
        let manifest = try TiledGraphFiles.readManifest(dataRoot: dir, name: "g")
        let seeds = TiledFixture.seeds(for: object)
        let centreGlobal = GlobalNodeID(raw: report.globalOf[seeds[0]])

        // K=1: depth-6 BFS from the centre across 8 tiles must evict >= 1.
        let router1 = try await TiledGraphRouter(dataRoot: dir, graphName: "g", maxResidentTiles: 1)
        let result1 = try await router1.runBFS(seed: centreGlobal, depth: 6, backward: false)
        let status1 = await router1.status()
        XCTAssertLessThanOrEqual(status1.maxResidentSeen, 1)
        XCTAssertGreaterThanOrEqual(status1.evicts, 1, "K=1 depth-6 BFS across 8 tiles must evict at least once")

        // K=8 on 8 tiles: null case — never evicts, same results as K=1.
        let router8 = try await TiledGraphRouter(dataRoot: dir, graphName: "g", maxResidentTiles: 8)
        let result8 = try await router8.runBFS(seed: centreGlobal, depth: 6, backward: false)
        let status8 = await router8.status()
        XCTAssertEqual(status8.evicts, 0, "K=8 on 8 tiles must never evict")
        XCTAssertLessThanOrEqual(status8.maxResidentSeen, 8)
        XCTAssertEqual(routerBFSPairs(result1), routerBFSPairs(result8), "K=1 vs K=8 results must match")

        // A second query touching only the (K=1) resident tile: no new
        // load. SELECT (not BFS) so the check is by construction, not by
        // hoping the graph's own edges happen to stay intra-tile — a
        // query range strictly inside the resident tile's own exclusive
        // rank span can never overlap an adjacent tile.
        let residentIds = await router1.residentTileIds()
        XCTAssertEqual(residentIds.count, 1, "K=1 must hold exactly one resident tile")
        guard let entry = manifest.tiles.first(where: { $0.id == residentIds[0] }) else {
            return XCTFail("resident tile \(residentIds[0]) missing from manifest")
        }
        let isFirstTile = entry.rankLo == 0
        let isLastTile = entry.rankHi == object.maxRank
        let queryLo = isFirstTile ? entry.rankLo : entry.rankLo + 1
        let queryHi = isLastTile ? entry.rankHi : entry.rankHi - 1
        if queryLo <= queryHi {
            let loadsBefore = await router1.status().loads
            _ = try await router1.runSelect(truth: 0, rankLo: queryLo, rankHi: queryHi)
            let loadsAfter = await router1.status().loads
            XCTAssertEqual(loadsAfter, loadsBefore, "query touching only the resident tile must not load")
        }

        // T3 print (not gated): load ms + bytes per tile at side 128, and
        // the spec §6.6 arithmetic beside them for reference.
        print("T3 side=128 tiles=8: per-tile load ms / bytes (direct TiledGraphFiles.loadTile, not through the router):")
        for entry in manifest.tiles.sorted(by: { $0.id < $1.id }) {
            let t0 = Date()
            _ = try TiledGraphFiles.loadTile(dataRoot: dir, name: "g", manifest: manifest, tileId: entry.id)
            let ms = Date().timeIntervalSince(t0) * 1000.0
            print("  tile \(entry.id): load_ms=\(String(format: "%.3f", ms)) bytes=\(report.bytesPerTile[Int(entry.id)])")
        }
        print("T3 evictions: K=1 depth-6 BFS from centre -> evicts=\(status1.evicts); K=8 -> evicts=\(status8.evicts)")
        print("spec §6.6.1 (10^9-node design-budget tile, for reference — our tiles are 10^3-node scale, not comparable in absolute terms):")
        print("  write 42 GB / 7 GB/s = 6.0 s; read 42 GB / 7 GB/s = 6.0 s; total tile-swap = 12 s (6 s if pre-fetch overlaps the tick)")
    }

    // MARK: - T4: router refusals recorded

    func testT4RouterRefusalsRecorded() async throws {
        // Torn body: corrupt the SEED's own tile so the first load() call
        // inside runBFS trips deterministically (a BFS "reaches" its own
        // seed tile trivially).
        let object = try TiledFixture.generate(side: 16)
        let dir = scratchDir("t4router-hash")
        defer { removeScratch(dir) }
        let boundaries = TiledFixture.boundaries(side: 16, tiles: 4)
        let report = try TiledGraphFiles.write(object: object, dataRoot: dir, name: "g", boundaries: boundaries)
        let seeds = TiledFixture.seeds(for: object)
        let seedGlobal = GlobalNodeID(raw: report.globalOf[seeds[0]])
        let seedTileId = seedGlobal.tileId

        let manifest = try TiledGraphFiles.readManifest(dataRoot: dir, name: "g")
        guard let entry = manifest.tiles.first(where: { $0.id == seedTileId }) else {
            return XCTFail("seed tile \(seedTileId) missing from manifest")
        }
        let bodyPath = "\(TiledGraphFiles.tileDirectory(dataRoot: dir, name: "g", entry: entry))/body.dags"
        var bytes = try Data(contentsOf: URL(fileURLWithPath: bodyPath))
        XCTAssertGreaterThan(bytes.count, 40)
        bytes[40] = bytes[40] ^ 0xFF
        try bytes.write(to: URL(fileURLWithPath: bodyPath))

        let router = try await TiledGraphRouter(dataRoot: dir, graphName: "g", maxResidentTiles: 2)
        do {
            _ = try await router.runBFS(seed: seedGlobal, depth: 1, backward: false)
            XCTFail("expected tileHashMismatch")
        } catch RouterError.tileHashMismatch(let id, _, _) {
            XCTAssertEqual(id, seedTileId)
        }
        let status = await router.status()
        XCTAssertEqual(status.refused, 1)
        XCTAssertTrue(status.lastRefusal?.contains("\(seedTileId)") ?? false, "lastRefusal must name the tile")

        // Epoch mismatch: fresh graph/router, meta.json's epoch flipped.
        let object2 = try TiledFixture.generate(side: 16)
        let dir2 = scratchDir("t4router-epoch")
        defer { removeScratch(dir2) }
        let boundaries2 = TiledFixture.boundaries(side: 16, tiles: 4)
        let report2 = try TiledGraphFiles.write(object: object2, dataRoot: dir2, name: "g", boundaries: boundaries2)
        let seeds2 = TiledFixture.seeds(for: object2)
        let seedGlobal2 = GlobalNodeID(raw: report2.globalOf[seeds2[0]])
        let seedTileId2 = seedGlobal2.tileId

        let manifest2 = try TiledGraphFiles.readManifest(dataRoot: dir2, name: "g")
        guard let entry2 = manifest2.tiles.first(where: { $0.id == seedTileId2 }) else {
            return XCTFail("seed tile \(seedTileId2) missing from manifest")
        }
        let metaPath2 = "\(TiledGraphFiles.tileDirectory(dataRoot: dir2, name: "g", entry: entry2))/meta.json"
        var meta2 = try JSONDecoder().decode(TileMeta.self, from: Data(contentsOf: URL(fileURLWithPath: metaPath2)))
        meta2.lastPersistedTickEpoch = 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(meta2).write(to: URL(fileURLWithPath: metaPath2))

        let router2 = try await TiledGraphRouter(dataRoot: dir2, graphName: "g", maxResidentTiles: 2)
        do {
            _ = try await router2.runBFS(seed: seedGlobal2, depth: 1, backward: false)
            XCTFail("expected tileInconsistent")
        } catch RouterError.tileInconsistent(let id, let metaEpoch, let bodyEpoch) {
            XCTAssertEqual(id, seedTileId2)
            XCTAssertEqual(metaEpoch, 1)
            XCTAssertEqual(bodyEpoch, 0)
        }
        let status2 = await router2.status()
        XCTAssertEqual(status2.refused, 1)
    }
}
