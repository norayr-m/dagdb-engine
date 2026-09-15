import XCTest
@testable import DagDB

final class StreamRecordTests: XCTestCase {
    private func gen() -> NamedStream {
        NamedStream(name: "court",
                    stateHi: 0x853c_49e6_748f_ea9b, stateLo: 0xda3e_39cb_94b9_5bdb,
                    incHi: 0x5851_f42d_4c95_7f2d, incLo: 0x1405_7b7e_f767_814f)
    }
    private func header() -> StreamHeader {
        StreamHeader(signalBandHz: 1500, tauWindowSec: 0.6827, combRateHz: 3000,
                     firstEchoSec: 1.0, recordWindowSec: 0.6827, stepSec: 1.0 / 24000,
                     clockSyncFloorSec: 0)
    }

    func testInadmissibleHeaderRefusedAtBirth() {
        var h = header()
        h.combRateHz = 100
        XCTAssertThrowsError(try StreamRecord(header: h, generator: gen()))
    }

    func testMiddleSliceReplaysAloneBitForBit() throws {
        var r = try StreamRecord(header: header(), generator: gen())
        try r.recordSlice(count: 5)
        let middle = try r.recordSlice(count: 7)
        try r.recordSlice(count: 3)
        let replayed = try r.replaySlice(1)
        XCTAssertEqual(replayed, middle.payload)
        XCTAssertEqual(middle.entryDraws, 5)
        XCTAssertTrue(r.verify().isEmpty)
    }

    func testSlicesAreContinuous() throws {
        // Slicing must not perturb the stream: concatenated slices equal
        // one unsliced run of the same generator.
        var r = try StreamRecord(header: header(), generator: gen())
        try r.recordSlice(count: 4)
        try r.recordSlice(count: 4)
        var g = gen()
        let whole = (0..<8).map { _ in g.next64() }
        XCTAssertEqual(r.slices.flatMap(\.payload), whole)
    }

    func testShiftedStreamDivergesAndRangeIsGuarded() throws {
        var r = try StreamRecord(header: header(), generator: gen())
        try r.recordSlice(count: 6)
        var shifted = gen(); _ = shifted.next64()
        var r2 = try StreamRecord(header: header(), generator: shifted)
        try r2.recordSlice(count: 6)
        XCTAssertNotEqual(r2.slices[0].payload, r.slices[0].payload)
        XCTAssertTrue(r2.verify().isEmpty) // honest record still verifies
        XCTAssertThrowsError(try r.replaySlice(9))
    }
}
