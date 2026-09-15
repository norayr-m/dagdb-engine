import XCTest
import Foundation
@testable import DagDB

/// Fold API — docs/contracts/FOLD_API_GATES_FROZEN.md (F1–F3, F5). The gates
/// are bit-for-bit, no tolerance: any mismatch here is a finding about
/// arithmetic order, never absorbed by a loosened comparison.
final class LadderFoldTests: XCTestCase {

    // MARK: - Fixture loading (F1, in-repo, sha-checked, never skips)

    private struct ControlFixture: Decodable {
        let kept_nodes: [Int]
        let final_operator: [[Double]]
        let folded_f1: [Double]
    }

    private static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/DagDBTests/
            .deletingLastPathComponent()   // Tests/
            .appendingPathComponent("Fixtures")
    }

    private static func loadControlFixture() throws -> ControlFixture {
        let jsonURL = fixturesDir.appendingPathComponent("e3_control_engine.json")
        let shaURL = fixturesDir.appendingPathComponent("e3_control_engine.sha256")
        let data = try Data(contentsOf: jsonURL)
        let shaLine = try String(contentsOf: shaURL, encoding: .utf8)
        let expectedHex = shaLine.split(separator: " ").first.map(String.init) ?? ""
        let actualHex = DagDBSnapshot.sha256Hex(data)
        guard actualHex == expectedHex else {
            XCTFail("e3_control_engine.json sha256 mismatch: expected \(expectedHex), got \(actualHex)")
            throw NSError(domain: "LadderFoldTests", code: 1)
        }
        return try JSONDecoder().decode(ControlFixture.self, from: data)
    }

    private func makeControlEngine() throws -> (DagDBEngine, HexGrid) {
        let grid = try HexGrid(width: 12, height: 12)
        let state = DagDBState(width: 12, height: 12)
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 64)
        return (engine, grid)
    }

    private func makeCourtEngine() throws -> (DagDBEngine, HexGrid) {
        let grid = try HexGrid(width: 44, height: 44)
        let state = DagDBState(width: 44, height: 44)
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 64)
        return (engine, grid)
    }

    // MARK: - F1: control, in repo, bit-for-bit

    func testF1ControlBitForBit() throws {
        let fixture = try Self.loadControlFixture()
        let (engine, grid) = try makeControlEngine()
        let object = LadderFold.Objects.control(engine: engine, grid: grid)
        let res = LadderFold.run(object: object,
                                  schedule: LadderFold.Objects.controlSchedule,
                                  sources: LadderFold.Objects.controlSources)
        print("F5 control price:\n" + res.priceTable())

        XCTAssertEqual(res.keptNodes, fixture.kept_nodes, "F1 kept_nodes")

        let k = res.keptNodes.count
        XCTAssertEqual(k, fixture.kept_nodes.count, "F1 kept count")
        XCTAssertEqual(fixture.final_operator.count, k)
        for r in 0..<k {
            XCTAssertEqual(fixture.final_operator[r].count, k, "F1 final_operator row \(r) width")
            for c in 0..<k {
                let engineV = res.finalOperator[r * k + c]
                let fixtureV = Float(fixture.final_operator[r][c])
                XCTAssertEqual(engineV.bitPattern, fixtureV.bitPattern,
                                "F1 final_operator[\(r)][\(c)]: engine=\(engineV) fixture=\(fixtureV)")
            }
        }

        XCTAssertEqual(res.foldedF1.count, fixture.folded_f1.count, "F1 folded_f1 count")
        for i in 0..<res.foldedF1.count {
            let engineV = res.foldedF1[i]
            let fixtureV = Float(fixture.folded_f1[i])
            XCTAssertEqual(engineV.bitPattern, fixtureV.bitPattern,
                            "F1 folded_f1[\(i)]: engine=\(engineV) fixture=\(fixtureV)")
        }
    }

    // MARK: - F2: court ladders, out of repo, bit-for-bit

    private static let envVar = "DAGDB_E3_RUNS"
    private static let pinnedSHA: [String: String] = [
        "G1": "85537836096cb620adbaf4660fe5379583f9f4302e063f65c21ce0ffbb763bbb",
        "G2": "da55cc8e7dc3952a055e94123c5c3c6cadafa850717b80d098f1199bf61442df",
    ]

    private struct LadderFixture: Decodable {
        let kept_nodes: [Int]
        let final_operator: [[Double]]
        let folded_f1_final: [Double]
        let folded_f2_final: [Double]
        let tier_answers: [String: TierJSON]
        let tier_bytes: [String: Int]
        let fold_log: [FoldStepJSON]
    }
    private struct TierJSON: Decodable {
        let kept: [Int]
        let f1: [Double]
        let f2: [Double]
        let f3: [Double]?
    }
    private struct FoldStepJSON: Decodable {
        let fold: Int
        let ring: Int
        let eliminated: Int
        let kept: Int
    }

    private func loadLadderFixtureOrSkip(profile: String) throws -> LadderFixture {
        guard let dir = ProcessInfo.processInfo.environment[Self.envVar] else {
            throw XCTSkip("\(Self.envVar) not set — sealed gate skipped")
        }
        let path = dir + "/e3_ladder_\(profile).json"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("\(path) not found — sealed gate skipped")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let actualHex = DagDBSnapshot.sha256Hex(data)
        let expectedHex = Self.pinnedSHA[profile]!
        guard actualHex == expectedHex else {
            XCTFail("e3_ladder_\(profile).json sha256 mismatch: expected \(expectedHex), got \(actualHex)")
            throw NSError(domain: "LadderFoldTests", code: 2)
        }
        return try JSONDecoder().decode(LadderFixture.self, from: data)
    }

    private func checkLadder(profile: String) throws {
        let fixture = try loadLadderFixtureOrSkip(profile: profile)
        let (engine, grid) = try makeCourtEngine()
        let object = LadderFold.Objects.court(profile: profile, engine: engine, grid: grid)
        let res = LadderFold.run(object: object,
                                  schedule: LadderFold.Objects.courtSchedule,
                                  sources: LadderFold.Objects.courtSources)

        XCTAssertEqual(res.keptNodes, fixture.kept_nodes, "\(profile) kept_nodes")

        let k = res.keptNodes.count
        XCTAssertEqual(fixture.final_operator.count, k, "\(profile) final_operator size")
        for r in 0..<k {
            for c in 0..<k {
                let engineV = res.finalOperator[r * k + c]
                let fixtureV = Float(fixture.final_operator[r][c])
                XCTAssertEqual(engineV.bitPattern, fixtureV.bitPattern,
                                "\(profile) final_operator[\(r)][\(c)]: engine=\(engineV) fixture=\(fixtureV)")
            }
        }

        XCTAssertEqual(res.foldedF1.count, fixture.folded_f1_final.count, "\(profile) folded_f1_final count")
        for i in 0..<res.foldedF1.count {
            let engineD = Double(res.foldedF1[i])
            XCTAssertEqual(engineD, fixture.folded_f1_final[i],
                            "\(profile) folded_f1_final[\(i)]")
        }
        XCTAssertEqual(res.foldedF2.count, fixture.folded_f2_final.count, "\(profile) folded_f2_final count")
        for i in 0..<res.foldedF2.count {
            let engineD = Double(res.foldedF2[i])
            XCTAssertEqual(engineD, fixture.folded_f2_final[i],
                            "\(profile) folded_f2_final[\(i)]")
        }

        for key in ["19", "15", "11", "7", "final"] {
            guard let expectedTier = fixture.tier_answers[key], let actualTier = res.tiers[key] else {
                XCTFail("\(profile) missing tier \(key)")
                continue
            }
            XCTAssertEqual(actualTier.kept, expectedTier.kept, "\(profile) tier \(key) kept")
            XCTAssertEqual(actualTier.f1, expectedTier.f1, "\(profile) tier \(key) f1")
            XCTAssertEqual(actualTier.f2, expectedTier.f2, "\(profile) tier \(key) f2")
            XCTAssertEqual(actualTier.f3 ?? [], expectedTier.f3 ?? [], "\(profile) tier \(key) f3")

            let expectedBytes = fixture.tier_bytes[key]!
            XCTAssertEqual(actualTier.bytes, expectedBytes, "\(profile) tier \(key) bytes")
        }

        XCTAssertEqual(res.log.count, fixture.fold_log.count, "\(profile) fold_log count")
        for (i, step) in res.log.enumerated() {
            let e = fixture.fold_log[i]
            XCTAssertEqual(step.fold, e.fold, "\(profile) fold_log[\(i)].fold")
            XCTAssertEqual(step.ring, e.ring, "\(profile) fold_log[\(i)].ring")
            XCTAssertEqual(step.eliminated, e.eliminated, "\(profile) fold_log[\(i)].eliminated")
            XCTAssertEqual(step.kept, e.kept, "\(profile) fold_log[\(i)].kept")
        }

        print("\(profile) ladder: \(res.log.count) folds, \(res.totalWallMs) ms")
        print(res.priceTable()); print("court reference: ~1.6 s/profile (release build, 2026-08-26); this run is a debug build")
    }

    func testF2CourtLaddersBitForBit() throws {
        try checkLadder(profile: "G1")
        try checkLadder(profile: "G2")
    }

    // MARK: - F3: runner JSON shape matches fixture

    func testF3RunnerJSONShapeMatchesFixture() throws {
        let (engine, grid) = try makeControlEngine()
        let object = LadderFold.Objects.control(engine: engine, grid: grid)
        let res = LadderFold.run(object: object,
                                  schedule: LadderFold.Objects.controlSchedule,
                                  sources: LadderFold.Objects.controlSources)
        let full = res.jsonDictionary()
        let outObj: [String: Any] = ["kept_nodes": full["kept_nodes"]!,
                                     "final_operator": full["final_operator"]!,
                                     "folded_f1": full["folded_f1_final"]!]
        let data = try JSONSerialization.data(withJSONObject: outObj, options: [.sortedKeys])
        let actualHex = DagDBSnapshot.sha256Hex(data)
        let expectedHex = "16cad096339e977d9f638b35e6b7a5d3916eac3379a27713ed9f79edb4751314"

        if actualHex != expectedHex {
            let fixtureData = try Data(contentsOf: Self.fixturesDir.appendingPathComponent("e3_control_engine.json"))
            var firstDiff = -1
            let n = min(data.count, fixtureData.count)
            for i in 0..<n where data[i] != fixtureData[i] {
                firstDiff = i
                break
            }
            if firstDiff == -1 && data.count != fixtureData.count { firstDiff = n }
            XCTFail("F3 runner JSON sha256 mismatch: expected \(expectedHex), got \(actualHex); "
                    + "first differing byte offset \(firstDiff) "
                    + "(rebuilt=\(firstDiff >= 0 && firstDiff < data.count ? data[firstDiff] : 0), "
                    + "fixture=\(firstDiff >= 0 && firstDiff < fixtureData.count ? fixtureData[firstDiff] : 0))")
        }
    }

    // MARK: - Object read-back

    func testObjectFromEngineLanesEqualsMovedInit() throws {
        let (engine, grid) = try makeControlEngine()
        let object = LadderFold.Objects.control(engine: engine, grid: grid)

        XCTAssertEqual(object.nodeCount, 144)
        // Row-major node 0 is the corner (c=0, r=0); centre c0 = 6.
        XCTAssertEqual(object.rank[0], 6)
        // The centre node (c=6, r=6), row-major index 6*12+6 = 78, has rank 0.
        XCTAssertEqual(object.rank[6 * 12 + 6], 0)
        // leak is stored into the engine's nodeValue lane as Float32, then
        // read back and widened to Double — compare against that same
        // round-trip, not the Double literal (0.01 is not exactly
        // representable in either width).
        XCTAssertEqual(object.leak, Double(Float(1e-2)))
        for row in object.adjacency {
            for (_, w) in row {
                XCTAssertEqual(w, 1.0)
            }
        }
    }

    // MARK: - Sources default

    func testSourcesDefaultF3IsMinusOne() throws {
        let sources = LadderFold.Sources(f1: 5, f2: 9)
        XCTAssertEqual(sources.f3, -1)
    }
}
