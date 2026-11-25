import XCTest
import CryptoKit
@testable import DagDB

/// Binary unchanged (control).
///
/// Before any engine change the main build recorded SHA-256
/// hashes of the truth array after N ∈ {1, 5, 20} ticks, rank and sync mode,
/// on seeded random BINARY graphs of 4,096, 65,536 and 1,048,576 nodes —
/// random LUTs, ranks, registers and back edges, truth bytes drawn from
/// 0...255 so Loom codes are included. The fixture is
/// `Tests/Fixtures/ternary_r1_binary_hashes.json` with its `.sha256` sidecar.
/// After the build the same hashes must reproduce exactly.
///
/// THE GENERATOR BELOW IS FROZEN WITH THE FIXTURE. Changing one draw changes
/// every hash; a change here is a re-record, and a re-record after the first
/// engine change is not a control.
///
/// Record mode: `DAGDB_TERNARY_R1_RECORD=1 swift test --filter
/// TernaryR1BinaryControlTests` writes the fixture and its sidecar (before any
/// engine change only).
final class TernaryR1BinaryControlTests: XCTestCase {

    // MARK: - The frozen generator

    /// SplitMix64 — the one PRNG of this generator.
    struct SplitMix64 {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// One frozen case: the grid side (size = side²), its seed.
    /// Sides: 64² = 4,096; 256² = 65,536; 1024² = 1,048,576 (three
    /// sizes). Seeds are this fixture's own definitional constants.
    static let cases: [(side: Int, seed: UInt64)] = [
        (64,   0x7E12_0001),
        (256,  0x7E12_0002),
        (1024, 0x7E12_0003),
    ]
    /// The engine's default rank bound (`DagDBEngine.init(maxRank: 16)`);
    /// ranks are drawn in 0..<rankLevels.
    static let rankLevels = 16
    /// One node in `registerOneIn` is a register (draw % registerOneIn == 0).
    static let registerOneIn: UInt64 = 64
    /// One slot in `absentOneIn` is empty (draw % absentOneIn == 0).
    static let absentOneIn: UInt64 = 4
    /// The fixed tick counts, and how far each run goes.
    static let checkpoints = [1, 5, 20]

    struct Graph {
        let grid: HexGrid
        let state: DagDBState
        let neighbors: [Int32]
        let backEdges: [(src: UInt32, dst: UInt32)]
    }

    /// Build the frozen binary graph for one case. Every slot reads a node of
    /// STRICTLY higher rank (or is empty), so no (rank, colour) segment reads
    /// itself and the rank tick is deterministic; registers have no
    /// combinational slot and exactly one back edge from a random node.
    static func makeGraph(side: Int, seed: UInt64) throws -> Graph {
        let grid = try HexGrid(width: side, height: side)
        var state = DagDBState(width: side, height: side)
        let n = grid.nodeCount
        var rng = SplitMix64(s: seed)

        var isReg = [Bool](repeating: false, count: n)
        for i in 0..<n {
            state.rank[i] = rng.next() % UInt64(rankLevels)
            state.lut6Low[i] = UInt32(truncatingIfNeeded: rng.next())
            state.lut6High[i] = UInt32(truncatingIfNeeded: rng.next())
            state.truthState[i] = UInt8(truncatingIfNeeded: rng.next())  // 0...255
            isReg[i] = rng.next() % registerOneIn == 0
        }

        // Nodes ordered by rank (stable by id) and the start of each rank.
        var byRank = [[Int32]](repeating: [], count: rankLevels)
        for i in 0..<n { byRank[Int(state.rank[i])].append(Int32(i)) }
        var sorted = [Int32](); sorted.reserveCapacity(n)
        var start = [Int](repeating: 0, count: rankLevels + 1)
        for r in 0..<rankLevels {
            start[r] = sorted.count
            sorted.append(contentsOf: byRank[r])
        }
        start[rankLevels] = sorted.count

        var nb = [Int32](repeating: -1, count: n * 6)
        for i in 0..<n where !isReg[i] {
            let lo = start[Int(state.rank[i]) + 1]
            let count = n - lo
            for d in 0..<6 {
                let u = rng.next()
                if u % absentOneIn == 0 || count == 0 { continue }
                nb[i * 6 + d] = sorted[lo + Int((u >> 8) % UInt64(count))]
            }
        }

        var backEdges: [(src: UInt32, dst: UInt32)] = []
        for i in 0..<n where isReg[i] {
            backEdges.append((UInt32(rng.next() % UInt64(n)), UInt32(i)))
        }
        return Graph(grid: grid, state: state, neighbors: nb, backEdges: backEdges)
    }

    static func makeEngine(_ g: Graph) throws -> DagDBEngine {
        let e = try DagDBEngine(grid: g.grid, state: g.state, maxRank: rankLevels)
        let p = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { p[i] = g.neighbors[i] }
        for be in g.backEdges { try e.addBackEdge(src: be.src, dst: be.dst) }
        return e
    }

    static func hashTruth(_ e: DagDBEngine) -> String {
        let t = e.readTruthStates()
        return SHA256.hash(data: Data(t)).map { String(format: "%02x", $0) }.joined()
    }

    /// Hashes for one case: mode → "N" → hex. Tick numbers are 0, 1, 2, …
    /// — the daemon's `tickCount` sequence from a fresh start.
    static func computeHashes(side: Int, seed: UInt64) throws -> [String: [String: String]] {
        let g = try makeGraph(side: side, seed: seed)
        var out: [String: [String: String]] = [:]
        for mode in ["rank", "sync"] {
            let e = try makeEngine(g)
            var row: [String: String] = [:]
            for t in 0..<(checkpoints.last!) {
                if mode == "rank" { e.tick(tickNumber: UInt32(t)) }
                else { e.tickSync(tickNumber: UInt32(t)) }
                if checkpoints.contains(t + 1) { row["\(t + 1)"] = hashTruth(e) }
            }
            out[mode] = row
        }
        return out
    }

    // MARK: - Fixture paths

    static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }
    static let fixtureName = "ternary_r1_binary_hashes.json"

    static func sha256Hex(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The gate

    func testR1BinaryTruthHashesReproduceTheMainBuild() throws {
        let fixtureURL = Self.fixturesDir.appendingPathComponent(Self.fixtureName)
        let sidecarURL = Self.fixturesDir.appendingPathComponent(Self.fixtureName + ".sha256")

        if ProcessInfo.processInfo.environment["DAGDB_TERNARY_R1_RECORD"] == "1" {
            var graphs: [[String: Any]] = []
            for c in Self.cases {
                let h = try Self.computeHashes(side: c.side, seed: c.seed)
                graphs.append([
                    "side": c.side, "nodes": c.side * c.side,
                    "seed": String(format: "0x%llx", c.seed),
                    "hashes": h,
                ])
            }
            let payload: [String: Any] = [
                "contract": "docs/contracts/TERNARY_GATES_FROZEN.md R1",
                "recorded_by": "main build, ticket T0, before any engine change",
                "generator": "TernaryR1BinaryControlTests.makeGraph (SplitMix64; ranks 0..<16; " +
                             "LUT low/high, truth 0...255, register 1-in-64 per node; " +
                             "6 slots, empty 1-in-4, else a node of strictly higher rank; " +
                             "one back edge per register from a random node)",
                "tick_numbers": "0, 1, 2, ... (fresh daemon tickCount)",
                "graphs": graphs,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload,
                                                  options: [.sortedKeys, .prettyPrinted])
            try data.write(to: fixtureURL)
            try Data("\(Self.sha256Hex(data))  \(Self.fixtureName)\n".utf8).write(to: sidecarURL)
            print("R1 RECORDED \(fixtureURL.path)")
            return
        }

        let data = try Data(contentsOf: fixtureURL)
        let sidecar = try String(contentsOf: sidecarURL, encoding: .utf8)
        let pinned = sidecar.split(separator: " ").first.map(String.init) ?? ""
        XCTAssertEqual(Self.sha256Hex(data), pinned, "R1 fixture does not match its sidecar")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let graphs = try XCTUnwrap(obj["graphs"] as? [[String: Any]])
        XCTAssertEqual(graphs.count, Self.cases.count)

        for (i, c) in Self.cases.enumerated() {
            let want = try XCTUnwrap(graphs[i]["hashes"] as? [String: [String: String]])
            XCTAssertEqual(graphs[i]["side"] as? Int, c.side)
            let got = try Self.computeHashes(side: c.side, seed: c.seed)
            for mode in ["rank", "sync"] {
                for n in Self.checkpoints {
                    let w = want[mode]?["\(n)"]
                    let g = got[mode]?["\(n)"]
                    XCTAssertNotNil(w)
                    XCTAssertEqual(g, w, "R1 side \(c.side) mode \(mode) N=\(n)")
                    print("R1 side=\(c.side) mode=\(mode) N=\(n) \(g == w ? "EQUAL" : "DIFFERS")")
                }
            }
        }
    }
}
