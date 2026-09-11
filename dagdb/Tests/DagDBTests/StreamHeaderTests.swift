import XCTest
@testable import DagDB

final class StreamHeaderTests: XCTestCase {
    /// W1's sealed regime, translated: 3 kHz comb, 1.5 kHz band, 2048-sample
    /// window at 3 kHz (~0.6827 s), echo held beyond the record, dt = 1/24000.
    private func w1Like() -> StreamHeader {
        StreamHeader(signalBandHz: 1500, tauWindowSec: 0.6827, combRateHz: 3000,
                     firstEchoSec: 1.0, recordWindowSec: 0.6827, stepSec: 1.0 / 24000,
                     clockSyncFloorSec: 0)
    }

    func testSealedRegimeIsAdmissible() {
        XCTAssertTrue(w1Like().isAdmissible)
    }

    func testEachProbeDeathIsRefused() {
        var slowSignal = w1Like()
        slowSignal.signalBandHz = 1.0 // period 1 s > window
        XCTAssertTrue(slowSignal.violations().contains(.signalWiderThanWindow))

        var sparseComb = w1Like()
        sparseComb.combRateHz = 2000 // < 2 x 1500
        XCTAssertTrue(sparseComb.violations().contains(.combBelowNyquist))

        var earlyEcho = w1Like()
        earlyEcho.firstEchoSec = 0.5 // record 0.6827 reaches it
        XCTAssertTrue(earlyEcho.violations().contains(.recordOutlivesEcho))

        var coarseStep = w1Like()
        coarseStep.stepSec = 1.0 / 2000 // > 1/(2*1500)
        XCTAssertTrue(coarseStep.violations().contains(.stepAboveNyquist))
    }

    func testNonPositiveQuantitiesRefusedFirst() {
        var h = w1Like()
        h.tauWindowSec = 0
        let v = h.violations()
        XCTAssertEqual(v, [.nonPositiveQuantity("tauWindowSec")])
    }

    func testNegativeClockFloorRefusedButZeroAllowed() {
        var h = w1Like()
        h.clockSyncFloorSec = -1
        XCTAssertFalse(h.isAdmissible)
        h.clockSyncFloorSec = 0
        XCTAssertTrue(h.isAdmissible)
    }
}
