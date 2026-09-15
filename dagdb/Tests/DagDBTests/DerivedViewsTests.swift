import XCTest
@testable import DagDB

/// Alarm-set derived views — gates from `docs/contracts/DERIVED_VIEWS_GATES_FROZEN.md`.
/// Synthetic tests exercise the pure math without the sealed fixture; sealed
/// tests replay `cortex_v4_world.npz` against the frozen pins — skip
/// (XCTSkip) when `DAGDB_CORTEX_V4_FIXTURE` is unset, FAIL (never skip) if
/// present with the wrong hash — precedent `CortexFixtureTests.swift`.
final class DerivedViewsTests: XCTestCase {

    // MARK: - Synthetic (no fixture)

    func testArrivalsFrontIndex() {
        var row0 = [Float](repeating: 0, count: 64)
        for t in 10..<64 { row0[t] = 1.0 }
        var row1 = [Float](repeating: 0, count: 64)
        for t in 30..<64 { row1[t] = 1.0 }
        let frame: [[Float]] = [row0, row1]

        let arr = DerivedViews.arrivals(frame: frame, stations: 2)
        XCTAssertEqual(arr.raw, [10.0, 30.0])
        XCTAssertEqual(arr.zeroed, [0.0, 20.0])
    }

    func testFeaturesCentroidOfPureTone() {
        // Front is at t = 0 (cos(0) = 1 = the global max magnitude, so the
        // very first sample already exceeds 0.25 * max). win1 is then
        // exactly cos(2*pi*750*t/3000), t = 0..<16 — a pure tone sitting
        // exactly on rfftfreq(16, 1/3000) bin 4 (4 * 3000/16 = 750 Hz).
        var row = [Float](repeating: 0, count: 64)
        for t in 0..<64 {
            row[t] = Float(cos(2.0 * Double.pi * 750.0 * Double(t) / 3000.0))
        }
        let frame: [[Float]] = [row]

        let feat = DerivedViews.features(frame: frame, stations: 1, fs: 3000.0)
        XCTAssertEqual(feat.count, 3)
        XCTAssertEqual(feat[1], 750.0, accuracy: 1e-9)
    }

    func testFeaturesZeroPaddingAtRecordEnd() {
        // Front at t = 60: win1 = x[60..<76] has 4 real samples (60-63,
        // value 1.0) then 12 zero-padded; win2 = x[76..<92] is entirely
        // out of the 64-sample record, so all zero.
        var row = [Float](repeating: 0, count: 64)
        for t in 60..<64 { row[t] = 1.0 }
        let frame: [[Float]] = [row]

        let eps = 1e-12
        let feat = DerivedViews.features(frame: frame, stations: 1, fs: 3000.0, eps: eps)
        let sumWin1Sq = 4.0 * 1.0 * 1.0
        let expectedIV = log(0.0 + eps) - log(sumWin1Sq + eps)
        XCTAssertEqual(feat[2], expectedIV, accuracy: 1e-12)
    }

    func testNumpyMedianEvenCount() {
        XCTAssertEqual(DerivedViews.numpyMedian([1, 2, 3, 4]), 2.5)
    }

    // MARK: - Sealed fixture (skipped without DAGDB_CORTEX_V4_FIXTURE)

    private static let stationSubsets = [2, 4, 6, 8]

    private static let v1Hits = [3, 11, 15, 18]
    private static let v2OracleHits = [233, 72, 76, 65]
    private static let v3TieMin = [52, 1, 1, 1]
    private static let v3TieMedian = [77.0, 5.0, 4.0, 2.0]
    private static let v3TieMax = [129, 129, 129, 23]
    private static let v3FramesWithTie = [300, 253, 242, 231]

    private static let v4Hits = [38, 28, 29, 39]

    private static let v5Ceiling = ["0.069767", "0.147287", "0.209302", "0.271318"]
    private static let v5ExactTwinPairs = [2495, 1015, 711, 467]
    private static let v5Identifiable = [9, 19, 27, 35]

    private func loadSealedOrSkip() throws -> CortexFixture {
        guard let path = CortexFixture.envPath else {
            throw XCTSkip("DAGDB_CORTEX_V4_FIXTURE not set — sealed derived-views gates skipped")
        }
        return try CortexFixture.load(path: path, expectedSHA256: CortexFixture.sealedSHA256)
    }

    func testV1V2V3ReflexSummary() throws {
        let fixture = try loadSealedOrSkip()
        let views = DerivedViews(fixture: fixture)

        for (i, S) in DerivedViewsTests.stationSubsets.enumerated() {
            let summary = views.reflexSummary(stations: S)
            print("S=\(S) reflex=\(summary.hits) oracle=\(summary.oracleHits) "
                + "tie=\(summary.tieMin)/\(summary.tieMedian)/\(summary.tieMax) "
                + "frames_with_tie=\(summary.framesWithTie) near_edge=\(summary.nearEdgeTotal) "
                + "wall_ms=\(summary.wallMs)")

            XCTAssertEqual(summary.hits, DerivedViewsTests.v1Hits[i], "V1 hits at S=\(S)")
            XCTAssertEqual(summary.oracleHits, DerivedViewsTests.v2OracleHits[i], "V2 oracleHits at S=\(S)")
            XCTAssertEqual(summary.tieMin, DerivedViewsTests.v3TieMin[i], "V3 tieMin at S=\(S)")
            XCTAssertEqual(summary.tieMedian, DerivedViewsTests.v3TieMedian[i], "V3 tieMedian at S=\(S)")
            XCTAssertEqual(summary.tieMax, DerivedViewsTests.v3TieMax[i], "V3 tieMax at S=\(S)")
            XCTAssertEqual(summary.framesWithTie, DerivedViewsTests.v3FramesWithTie[i], "V3 framesWithTie at S=\(S)")

            // Audit C finding 42's receipt on the SEALED fixture: a failed
            // least-squares fit is now skipped and counted instead of being
            // scored from a fabricated (alpha, beta) = (0, 0). Nothing is
            // skipped here, which is why none of the literals above can
            // have moved because of it.
            XCTAssertEqual(summary.skippedTotal, 0, "V1-V3 skipped candidates at S=\(S)")
            XCTAssertNil(summary.refusal, "V1-V3 refusal at S=\(S)")
        }
    }

    func testV4Rung() throws {
        let fixture = try loadSealedOrSkip()
        let views = DerivedViews(fixture: fixture)

        for (i, S) in DerivedViewsTests.stationSubsets.enumerated() {
            let centroids = views.centroids(stations: S)
            print("S=\(S) centroids wall_ms=\(centroids.wallMs)")
            let rung = views.rung(stations: S, centroids: centroids)
            print("S=\(S) rung hits=\(rung.hits) minMargin=\(rung.minMargin) wall_ms=\(rung.wallMs)")

            XCTAssertEqual(rung.hits, DerivedViewsTests.v4Hits[i], "V4 hits at S=\(S)")
            XCTAssertNil(centroids.refusal, "V4 centroids refusal at S=\(S)")
            XCTAssertNil(rung.refusal, "V4 rung refusal at S=\(S)")
        }

        // Finding 41: the same call one station past the fixture's own
        // count is refused by name rather than reading into the next
        // candidate's row.
        XCTAssertNotNil(views.reflexSummary(stations: fixture.stations + 1).refusal)
    }

    func testV5Ceiling() throws {
        let fixture = try loadSealedOrSkip()
        let views = DerivedViews(fixture: fixture)

        for (i, S) in DerivedViewsTests.stationSubsets.enumerated() {
            let ceiling = views.ceiling(stations: S)
            let ceilingStr = String(format: "%.6f", ceiling.ceiling)
            print("S=\(S) ceiling=\(ceilingStr) identifiable=\(ceiling.identifiable) "
                + "unique=\(ceiling.unique) groups=\(ceiling.groups) "
                + "exact_twin_pairs=\(ceiling.exactTwinPairs)")

            XCTAssertEqual(ceilingStr, DerivedViewsTests.v5Ceiling[i], "V5 ceiling at S=\(S)")
            XCTAssertEqual(ceiling.exactTwinPairs, DerivedViewsTests.v5ExactTwinPairs[i], "V5 exactTwinPairs at S=\(S)")
            XCTAssertEqual(ceiling.identifiable, DerivedViewsTests.v5Identifiable[i], "V5 identifiable at S=\(S)")
        }
    }
}
