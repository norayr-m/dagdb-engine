import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Tiling (control), the daemon's own path.
///
/// TernaryR6TilingTests splits a `TiledFixture.Object` through the library.
/// This file splits the DAEMON'S live engine through `SAVE TILED`
/// (`TiledGraphFiles.write(engine:grid:…, tickCount:)`, a separate entry
/// point that stamps the daemon's tick count everywhere), opens it with
/// `TILED OPEN`, and ticks it with `TILED TICK` beside the daemon's own
/// `TICK` / `TICK_SYNC` — three-way against TiledReference's ternary
/// evaluator, every node after every tick, and every node again through
/// `TILED GET … TRUTH`. Grid: {rank, sync} × saved tick count {0, 3} ×
/// K {1, 2}, side 44 × 4 tiles (the tiling fixture's object and boundaries),
/// six world ticks each. The object is the ternary mixed object
/// (`TiledReference.mixTernary`).
///
/// Also a note on rows: the tiled verbs write no 24-byte node row.
/// The mode byte rides in pad byte 18 of the 24-byte node row; a
/// `TILED BFS` writes 16-byte rows and a `TILED SELECT` 8-byte rows, and
/// neither touches a byte past its own rows (the result file is filled with
/// a marker first and read back).
final class TernaryR6DaemonTiledTests: XCTestCase {

    static let side = 44
    static let tiles = 4
    static let worldTicks = 6

    func testSaveTiledThenTiledTickEqualsDaemonTick() async throws {
        var cells = 0
        for mode in [TickMode.rank, .sync] {
            for saved in [0, 3] {
                for k in [1, 2] {
                    try await cell(mode: mode, saved: saved, k: k)
                    cells += 1
                }
            }
        }
        XCTAssertEqual(cells, 2 * 2 * 2)
    }

    private func field(_ line: String, _ key: String) -> Int? {
        for token in line.split(separator: " ") where token.hasPrefix("\(key)=") {
            return Int(token.dropFirst(key.count + 1))
        }
        return nil
    }

    private func cell(mode: TickMode, saved: Int, k: Int) async throws {
        let side = Self.side
        let root = NSTemporaryDirectory() + "dagdb-tern-r6d-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let f = try HandlerFixture(side: side, dataRoot: root, maxRank: 64)
        let h = f.handler
        try TiledFixture.populate(engine: h.engine, grid: f.grid, side: side)
        try TiledReference.mixTernary(engine: h.engine, side: side)
        let tag0 = "mode=\(mode) saved=\(saved) K=\(k)"

        let verb = mode == .rank ? "TICK" : "TICK_SYNC"
        let ref = TiledReference(engine: h.engine)
        let lanes = TiledReference.TernaryLanes(engine: h.engine)
        var refVector = h.engine.readTruthStates()
        func refTick() {
            refVector = mode == .rank ? ref.tickRank(refVector, ternary: lanes)
                                      : ref.tickSync(refVector, ternary: lanes)
        }
        for i in 0..<saved {
            let r = h.handle("\(verb) 1")
            XCTAssertEqual(field(r, "total"), i + 1, "\(tag0) \(r)")
            refTick()
        }
        XCTAssertEqual(h.engine.readTruthStates(), refVector, "\(tag0) daemon vs reference before SAVE TILED")

        let boundaries = TiledFixture.boundaries(side: side, tiles: Self.tiles)
        let dir = "\(root)/g"
        let save = h.handle("SAVE TILED \(dir) \(boundaries.map(String.init).joined(separator: ","))")
        XCTAssertTrue(save.hasPrefix("OK SAVE TILED dir=\"\(dir)\" tiles=\(Self.tiles) nodes=\(side * side) "), "\(tag0) \(save)")
        let open = h.handle("TILED OPEN \(dir) \(k)")
        XCTAssertTrue(open.hasPrefix("OK TILED OPEN id=x00000001 tiles=\(Self.tiles) nodes=\(side * side) resident_max=\(k)"), "\(tag0) \(open)")
        let id = "x00000001"
        guard let router = h.tiledRouters[id]?.router else { XCTFail("\(tag0) no router"); return }

        // Global ids in tile order, for TILED GET over every node.
        let manifest = try TiledGraphFiles.readManifest(dataRoot: root, name: "g")
        var globals: [(raw: UInt64, engineIndex: Int)] = []
        for entry in manifest.tiles.sorted(by: { $0.id < $1.id }) {
            for (local, engineIndex) in entry.engineIndexOf.enumerated() {
                let gid = try GlobalNodeID(tileId: entry.id, localNodeId: UInt64(local))
                globals.append((gid.raw, Int(engineIndex)))
            }
        }
        XCTAssertEqual(globals.count, side * side)

        var getCompares = 0
        for t in 1...Self.worldTicks {
            let d = h.handle("\(verb) 1")
            XCTAssertEqual(field(d, "total"), saved + t, "\(tag0) \(d)")
            let tt = h.handle("TILED TICK \(id) 1\(mode == .sync ? " SYNC" : "")")
            XCTAssertTrue(tt.hasPrefix("OK TILED TICK id=\(id) ticks=\(saved + t) tiles_ticked=\(Self.tiles) "), "\(tag0) \(tt)")
            refTick()
            let want = h.engine.readTruthStates()
            let got = try await router.truthArray()
            let tag = "\(tag0) N=\(saved + t)"
            XCTAssertEqual(want, refVector, "\(tag) daemon vs reference: \(TiledReference.differing(want, refVector).count) bytes")
            XCTAssertEqual(got, want, "\(tag) TILED vs daemon: \(TiledReference.differing(got, want).count) bytes")
        }
        let final = h.engine.readTruthStates()
        var getDiffering = 0
        for g in globals {
            let reply = h.handle("TILED GET \(id) \(g.raw) TRUTH")
            if reply != "OK TILED GET id=\(id) node=\(g.raw) truth=\(final[g.engineIndex])" { getDiffering += 1 }
            getCompares += 1
        }
        XCTAssertEqual(getDiffering, 0, "\(tag0): TILED GET differs from the daemon on \(getDiffering) nodes")
        XCTAssertEqual(getCompares, side * side)
        XCTAssertTrue(h.handle("TILED STATUS \(id)").contains("epoch=\(saved + Self.worldTicks)/\(saved + Self.worldTicks)"))

        // Rows: TILED BFS 16 bytes, TILED SELECT 8 bytes; nothing past them.
        let marker: UInt8 = 0xAB
        func fillMarker() { f.shm.initializeMemory(as: UInt8.self, repeating: marker, count: f.shmBytes) }
        func untouchedPast(_ used: Int) -> Bool {
            let p = f.shm.bindMemory(to: UInt8.self, capacity: f.shmBytes)
            for i in used..<f.shmBytes where p[i] != marker { return false }
            return true
        }
        let centre = Int(f.grid.mortonRank[(side / 2) * side + side / 2])
        guard let seed = globals.first(where: { $0.engineIndex == centre }) else { XCTFail("no centre"); return }
        fillMarker()
        let bfs = h.handle("TILED BFS \(id) \(seed.raw) 3")
        XCTAssertTrue(bfs.hasPrefix("OK TILED BFS"), bfs)
        let header = f.shm.bindMemory(to: UInt32.self, capacity: 2)
        let bfsCount = Int(header[0])
        XCTAssertEqual(header[1], 16, "\(tag0) TILED BFS row size")
        XCTAssertEqual(field(bfs, "count"), bfsCount)
        XCTAssertGreaterThan(bfsCount, 1)
        XCTAssertTrue(untouchedPast(8 + bfsCount * 16), "\(tag0) TILED BFS wrote past its 16-byte rows")

        // TILED SELECT of UNDEFINED (byte 2) over every rank: the daemon's
        // own truth names the expected set.
        fillMarker()
        // The fixture's highest rank: Chebyshev distance from (side/2, side/2).
        let topRank = max(side / 2, side - 1 - side / 2)
        let sel = h.handle("TILED SELECT \(id) 2 0 \(topRank)")
        XCTAssertTrue(sel.hasPrefix("OK TILED SELECT"), sel)
        let selCount = Int(header[0])
        XCTAssertEqual(header[1], 8, "\(tag0) TILED SELECT row size")
        let rows = f.shm.advanced(by: 8).bindMemory(to: UInt64.self, capacity: max(selCount, 1))
        let selected = Set((0..<selCount).map { rows[$0] })
        let expected = Set(globals.filter { final[$0.engineIndex] == 2 }.map { $0.raw })
        XCTAssertEqual(selected, expected, "\(tag0) TILED SELECT truth=2")
        XCTAssertGreaterThan(expected.count, 0, "\(tag0): no node at UNDEFINED to select")
        XCTAssertTrue(untouchedPast(8 + selCount * 8), "\(tag0) TILED SELECT wrote past its 8-byte rows")
        print("R6 daemon \(tag0) ticks=\(saved)+\(Self.worldTicks) nodes=\(side * side) tiled_get=\(getCompares) bfs_rows=\(bfsCount)x16 select_undefined=\(selCount)x8")
    }
}
