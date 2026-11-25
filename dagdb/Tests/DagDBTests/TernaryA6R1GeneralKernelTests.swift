import XCTest
@testable import DagDB

/// The binary control also through the general kernel.
///
/// The binary control's engines (`TernaryR1BinaryControlTests`) are
/// binary-only, so their ticks run the binary-only fast kernels, and that
/// control no longer reads the general kernels'
/// BINARY branch at all. Here the same 18 cells — its frozen generator, its
/// three cases, rank and sync, N ∈ {1, 5, 20}, against main's recorded
/// hashes in its fixture — run with the test hook `binaryFastPathEnabled =
/// false`, so every tick takes `dagdb_tick_rank` / `dagdb_tick_sync` (the
/// engine's `lastTickKernel` is asserted `.general` on every tick, and the
/// graph is asserted binary-only, so without the hook the fast path would
/// run). Through the bundle's library (the gate's 18 cells) and through the
/// forced inline source (18 more).
final class TernaryA6R1GeneralKernelTests: XCTestCase {

    typealias R1 = TernaryR1BinaryControlTests

    static func makeEngine(_ g: R1.Graph, library: DagDBEngine.ShaderLibrary) throws -> DagDBEngine {
        let e = try DagDBEngine(grid: g.grid, state: g.state, maxRank: R1.rankLevels, shaderLibrary: library)
        let p = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { p[i] = g.neighbors[i] }
        for be in g.backEdges { try e.addBackEdge(src: be.src, dst: be.dst) }
        return e
    }

    func testR1HashesReproduceThroughTheGeneralKernel() throws {
        let fixtureURL = R1.fixturesDir.appendingPathComponent(R1.fixtureName)
        let sidecarURL = R1.fixturesDir.appendingPathComponent(R1.fixtureName + ".sha256")
        let data = try Data(contentsOf: fixtureURL)
        let sidecar = try String(contentsOf: sidecarURL, encoding: .utf8)
        XCTAssertEqual(R1.sha256Hex(data), sidecar.split(separator: " ").first.map(String.init) ?? "",
                       "R1 fixture does not match its sidecar")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let graphs = try XCTUnwrap(obj["graphs"] as? [[String: Any]])
        XCTAssertEqual(graphs.count, R1.cases.count)

        var equal: [String: Int] = [:], cells: [String: Int] = [:]
        var wrongKernel = 0
        for (i, c) in R1.cases.enumerated() {
            XCTAssertEqual(graphs[i]["side"] as? Int, c.side)
            let want = try XCTUnwrap(graphs[i]["hashes"] as? [String: [String: String]])
            let g = try R1.makeGraph(side: c.side, seed: c.seed)
            for (lname, lib) in [("bundle", DagDBEngine.ShaderLibrary.automatic), ("inline", .inlineSource)] {
                for mode in ["rank", "sync"] {
                    let e = try Self.makeEngine(g, library: lib)
                    XCTAssertEqual(e.usedInlineShader, lname == "inline")
                    XCTAssertEqual(e.nonBinaryNodeCount, 0, "R1's graph is binary-only")
                    e.binaryFastPathEnabled = false
                    for t in 0..<R1.checkpoints.last! {
                        if mode == "rank" { e.tick(tickNumber: UInt32(t)) } else { e.tickSync(tickNumber: UInt32(t)) }
                        if e.lastTickKernel != .general { wrongKernel += 1 }
                        guard R1.checkpoints.contains(t + 1) else { continue }
                        let got = R1.hashTruth(e)
                        let w = want[mode]?["\(t + 1)"]
                        XCTAssertNotNil(w)
                        XCTAssertEqual(got, w, "R1 general \(lname) side \(c.side) mode \(mode) N=\(t + 1)")
                        cells[lname, default: 0] += 1
                        if got == w { equal[lname, default: 0] += 1 }
                        print("A6 R1 general \(lname) side=\(c.side) mode=\(mode) N=\(t + 1) \(got == w ? "EQUAL" : "DIFFERS")")
                    }
                }
            }
        }
        XCTAssertEqual(wrongKernel, 0, "a tick ran the fast kernel with the hook off")
        XCTAssertEqual(cells["bundle"], 18); XCTAssertEqual(cells["inline"], 18)
        print("A6 R1 general kernel: bundle \(equal["bundle"] ?? 0)/\(cells["bundle"] ?? 0) EQUAL, inline \(equal["inline"] ?? 0)/\(cells["inline"] ?? 0) EQUAL, fast-kernel ticks with the hook off: \(wrongKernel)")
    }
}
