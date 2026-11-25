import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// The frame check's own count arithmetic is overflow-reporting. The expected count of BANK
/// GENERATE (K·M), XCONV SEALED (2n) and BUDGET OPEN (p·t + c) that overflows
/// Int is refused by name, not trapped. The pre-existing trap of BANK
/// GENERATE's byte count (+TwinBank :63) fires first on the wire; it belongs to
/// the separate overflow fix, so the check is made here, on the function the new line
/// calls. The refusal: `ERROR out_of_range: <VERB> frame count <expr>
/// overflows Int; nothing written`.
final class EngineSHM1A2CountTests: XCTestCase {

    typealias H = DagDBCommandHandler

    static func overflow(_ verb: String, _ expr: String) -> String {
        "ERROR out_of_range: \(verb) frame count \(expr) overflows Int; nothing written"
    }

    func testA2_3BankGenerateCountThatOverflowsIsRefusedByName() {
        // An M chosen to overflow: K = 6 × 4611686018427387904 = 2^64 + 2^63, past Int.
        let m = 4_611_686_018_427_387_904
        XCTAssertEqual(H.shm1ExpectedCount(.bankGenerate, 6, times: m),
                       .refused(Self.overflow("BANK GENERATE", "6*4611686018427387904")))
        XCTAssertEqual(H.shm1ExpectedCount(.bankGenerate, 2, times: Int.max),
                       .refused(Self.overflow("BANK GENERATE", "2*\(Int.max)")))
        XCTAssertEqual(H.shm1ExpectedCount(.bankGenerate, Int.max, times: Int.max),
                       .refused(Self.overflow("BANK GENERATE", "\(Int.max)*\(Int.max)")))
        // In range, the product itself.
        XCTAssertEqual(H.shm1ExpectedCount(.bankGenerate, 6, times: 1), .count(6))
        XCTAssertEqual(H.shm1ExpectedCount(.bankGenerate, 160, times: 7), .count(1120))
        XCTAssertEqual(H.shm1ExpectedCount(.bankGenerate, 1, times: Int.max), .count(Int.max))
        XCTAssertEqual(H.shm1ExpectedCount(.bankGenerate, 2, times: Int.max / 2), .count(Int.max - 1))
    }

    func testA2_3XconvSealedAndBudgetOpenCountsReportOverflow() {
        XCTAssertEqual(H.shm1ExpectedCount(.xconvSealed, 2, times: Int.max / 2 + 1),
                       .refused(Self.overflow("XCONV SEALED", "2*\(Int.max / 2 + 1)")))
        XCTAssertEqual(H.shm1ExpectedCount(.xconvSealed, 2, times: 128), .count(256))
        // p·t overflows; p·t fits and + c overflows; both fit.
        XCTAssertEqual(H.shm1ExpectedCount(.budgetOpen, 4_000_000_000, times: 4_000_000_000, plus: 0),
                       .refused(Self.overflow("BUDGET OPEN", "4000000000*4000000000+0")))
        XCTAssertEqual(H.shm1ExpectedCount(.budgetOpen, 1, times: Int.max, plus: 1),
                       .refused(Self.overflow("BUDGET OPEN", "1*\(Int.max)+1")))
        XCTAssertEqual(H.shm1ExpectedCount(.budgetOpen, 4, times: 8, plus: 3), .count(35))
        XCTAssertEqual(H.shm1ExpectedCount(.budgetOpen, 1, times: Int.max - 1, plus: 1), .count(Int.max))
    }

    /// The line itself: the handler's frame check of a computed count refuses
    /// before it reads or writes anything, and with a count in range it is the
    /// ordinary frame check.
    func testA2_3TheFrameCheckRefusesTheOverflowBeforeTheFrame() throws {
        let f = try HandlerFixture(side: 4)
        shm1Header(f.shm, count: 6, verb: .bankGenerate)
        let before = Data(bytes: f.shm, count: f.shmBytes)
        XCTAssertEqual(f.handler.shm1FrameRefusal(.bankGenerate, 6, times: 4_611_686_018_427_387_904),
                       Self.overflow("BANK GENERATE", "6*4611686018427387904"))
        XCTAssertEqual(Data(bytes: f.shm, count: f.shmBytes), before)
        XCTAssertNil(f.handler.shm1FrameRefusal(.bankGenerate, 6, times: 1))
        XCTAssertEqual(f.handler.shm1FrameRefusal(.bankGenerate, 6, times: 2),
                       "ERROR bad_value: BANK GENERATE frame count 6, the verb reads 12; nothing written")
    }
}
