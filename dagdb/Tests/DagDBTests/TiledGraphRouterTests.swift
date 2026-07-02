import XCTest
@testable import DagDB

final class TiledGraphRouterTests: XCTestCase {

    // MARK: - Construction

    func testInitStoresDataRootAndGraphName() async throws {
        let r = try await TiledGraphRouter(dataRoot: "/tmp/dagdb-test", graphName: "demo")
        let s = await r.status()
        XCTAssertEqual(s.dataRoot, "/tmp/dagdb-test")
        XCTAssertEqual(s.graphName, "demo")
        XCTAssertEqual(s.residentTileCount, 0)
        XCTAssertEqual(s.maxResidentTiles, 2)
        XCTAssertEqual(s.totalTickCount, 0)
    }

    func testInitWithCustomResidentBudget() async throws {
        let r = try await TiledGraphRouter(
            dataRoot: "/tmp/dagdb-test", graphName: "demo", maxResidentTiles: 4
        )
        let s = await r.status()
        XCTAssertEqual(s.maxResidentTiles, 4)
    }

    // MARK: - Tile locality helpers (pure)

    func testTileOfDecodesUpperBits() async throws {
        let r = try await TiledGraphRouter(dataRoot: "/tmp", graphName: "x")
        let id = try GlobalNodeID(tileId: 12, localNodeId: 5042)
        XCTAssertEqual(r.tileOf(id), 12)
    }

    func testLocalIdOfDecodesLowerBits() async throws {
        let r = try await TiledGraphRouter(dataRoot: "/tmp", graphName: "x")
        let id = try GlobalNodeID(tileId: 12, localNodeId: 5042)
        XCTAssertEqual(r.localIdOf(id), 5042)
    }

    func testTileLocalityHelpersAtBoundaries() async throws {
        let r = try await TiledGraphRouter(dataRoot: "/tmp", graphName: "x")
        let zero = try GlobalNodeID(tileId: 0, localNodeId: 0)
        XCTAssertEqual(r.tileOf(zero), 0)
        XCTAssertEqual(r.localIdOf(zero), 0)

        let max = try GlobalNodeID(tileId: 0xFF_FFFF, localNodeId: 0xFF_FFFF_FFFF)
        XCTAssertEqual(r.tileOf(max), 0xFF_FFFF)
        XCTAssertEqual(r.localIdOf(max), 0xFF_FFFF_FFFF)
    }

    // MARK: - Stubs throw notImplemented (caller-facing contract)

    func testRunQueryStubThrows() async throws {
        let r = try await TiledGraphRouter(dataRoot: "/tmp", graphName: "x")
        do {
            _ = try await r.runQuery("STATUS")
            XCTFail("expected notImplemented")
        } catch RouterError.notImplemented(let what) {
            XCTAssertTrue(what.contains("runQuery"))
        }
    }

    func testRunBFSStubThrows() async throws {
        let r = try await TiledGraphRouter(dataRoot: "/tmp", graphName: "x")
        let seed = try GlobalNodeID(tileId: 0, localNodeId: 1)
        do {
            _ = try await r.runBFS(seed: seed, depth: 3)
            XCTFail("expected notImplemented")
        } catch RouterError.notImplemented {
            // expected
        }
    }

    func testSaveAndCloseStubsThrow() async throws {
        let r = try await TiledGraphRouter(dataRoot: "/tmp", graphName: "x")
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

    // MARK: - Resident-set bookkeeping (no engine, just the dict)

    func testIsResidentReportsFalseInitially() async throws {
        let r = try await TiledGraphRouter(dataRoot: "/tmp", graphName: "x")
        let resident = await r.isResident(7)
        XCTAssertFalse(resident)
    }

    func testResidentTileIdsEmptyInitially() async throws {
        let r = try await TiledGraphRouter(dataRoot: "/tmp", graphName: "x")
        let ids = await r.residentTileIds()
        XCTAssertEqual(ids, [])
    }
}
