import XCTest
@testable import DagDB

/// the interface phase — AlarmRecord / SealedCourt, no fixture needed. Numbers copied
/// verbatim from the sealed literals (plan §"Sealed literals").
final class AlarmRecordTests: XCTestCase {

    // MARK: - Index mapping

    func testPocketIndexAndTierIndex() {
        XCTAssertEqual(SealedCourt.pocketIndex(3), 0)
        XCTAssertEqual(SealedCourt.pocketIndex(6), 3)
        XCTAssertEqual(SealedCourt.tierIndex(7), 4)
        XCTAssertEqual(SealedCourt.tierIndex(3), 0)
        XCTAssertEqual(SealedCourt.sealedPocket(0), 3)
        XCTAssertEqual(SealedCourt.sealedTier(4), 7)
    }

    func testMakeLayoutMatchesSealedTariffAndMinTier() {
        let layout = SealedCourt.makeLayout()
        // pocket index 3 == sealed pocket 6, tier index 4 == sealed tier 7.
        XCTAssertEqual(layout.cost[3][4], 5618)
        XCTAssertEqual(layout.minTier, [4, 1])
    }

    func testTariffIsTwiceMSquaredForAllThirtyTwoCells() {
        for (pocket, row) in SealedCourt.tariffM {
            for (tier, m) in row {
                XCTAssertEqual(SealedCourt.tariff[pocket]![tier]!, Double(2 * m * m),
                               "pocket \(pocket) tier \(tier)")
            }
        }
        XCTAssertEqual(SealedCourt.tariffM.count, 4)
        for row in SealedCourt.tariffM.values {
            XCTAssertEqual(row.count, 8)
        }
    }

    // MARK: - AlarmRecord derived properties

    func testLiarBRecord() {
        let r = AlarmRecord(index: 1, key: "liar_1", culprit: .liar(.B), waveforms: nil)
        XCTAssertEqual(r.ear, .B)
        XCTAssertEqual(r.pocket, 5)
        XCTAssertEqual(r.classLabel, "liar_B")
        XCTAssertFalse(r.isBurst)
        XCTAssertEqual(r.claim, SealedClaim(pocket: 5, row: .L, isPhantom: false))
    }

    func testDriftRecord() {
        let r = AlarmRecord(index: 151, key: "drift_1", culprit: .drift, waveforms: nil)
        XCTAssertNil(r.ear)
        XCTAssertEqual(r.pocket, 6)
        XCTAssertEqual(r.classLabel, "drift")
        XCTAssertTrue(r.isBurst)
        XCTAssertEqual(r.claim, SealedClaim(pocket: 6, row: .L, isPhantom: false))
    }

    func testDeepRecordBurstsAndNeedsRowD() {
        let r = AlarmRecord(index: 101, key: "deep_1", culprit: .deep, waveforms: nil)
        XCTAssertNil(r.ear)
        XCTAssertEqual(r.pocket, 6)
        XCTAssertTrue(r.isBurst)
        XCTAssertEqual(r.claim, SealedClaim(pocket: 6, row: .D, isPhantom: false))
    }

    func testQuietRecordBuysNothing() {
        let r = AlarmRecord(index: 1, key: "quiet_1", culprit: .quiet, waveforms: nil)
        XCTAssertNil(r.pocket)
        XCTAssertNil(r.claim)
        XCTAssertFalse(r.isBurst)
        XCTAssertEqual(r.classLabel, "quiet")
    }

    func testLiarAAndCPocketsAndBurst() {
        let a = AlarmRecord(index: 51, key: "liar_1", culprit: .liar(.A), waveforms: nil)
        XCTAssertEqual(a.pocket, 3)
        XCTAssertFalse(a.isBurst)

        let c = AlarmRecord(index: 52, key: "liar_2", culprit: .liar(.C), waveforms: nil)
        XCTAssertEqual(c.pocket, 6)
        XCTAssertTrue(c.isBurst)
        XCTAssertEqual(c.classLabel, "liar_C")
    }

    // MARK: - CulpritClass Codable round trip

    func testCulpritClassCodableRoundTrip() throws {
        let cases: [CulpritClass] = [.quiet, .liar(.A), .liar(.B), .liar(.C), .deep, .drift]
        for c in cases {
            let data = try JSONEncoder().encode(c)
            let decoded = try JSONDecoder().decode(CulpritClass.self, from: data)
            XCTAssertEqual(decoded, c)
        }
    }

    func testCulpritClassDecodeRejectsUnknownKind() {
        let json = "{\"kind\":\"bogus\"}".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(CulpritClass.self, from: json))
    }

    // MARK: - Sealed class counts

    func testSealedClassCountsSumTo200() {
        let total = SealedCourt.classCounts.values.reduce(0, +)
        XCTAssertEqual(total, 200)
        XCTAssertEqual(SealedCourt.classCounts["quiet"], 50)
        XCTAssertEqual(SealedCourt.classCounts["liar_A"], 17)
        XCTAssertEqual(SealedCourt.classCounts["liar_B"], 17)
        XCTAssertEqual(SealedCourt.classCounts["liar_C"], 16)
        XCTAssertEqual(SealedCourt.classCounts["deep"], 50)
        XCTAssertEqual(SealedCourt.classCounts["drift"], 50)
    }

    // MARK: - SealedCourt.claim conversion

    func testSealedCourtClaimConvertsToBudgetLayoutClaim() {
        let claim = SealedClaim(pocket: 6, row: .D, isPhantom: false)
        let converted = SealedCourt.claim(claim)
        XCTAssertEqual(converted, BudgetLayout.Claim(pocket: 3, classIndex: 1))
    }
}
