import XCTest
@testable import DagDB

/// the interface phasea — state-bearing inits + Codable round-trips for NamedStream,
/// StreamHeader, StreamRecord. Fixtures reused verbatim from
/// NamedStreamTests / StreamHeaderTests / StreamRecordTests.
final class TwinCodableStreamTests: XCTestCase {
    private func referenceStream() -> NamedStream {
        NamedStream(name: "ref",
                    stateHi: 0x853c_49e6_748f_ea9b, stateLo: 0xda3e_39cb_94b9_5bdb,
                    incHi: 0x5851_f42d_4c95_7f2d, incLo: 0x1405_7b7e_f767_814f)
    }

    private func w1Like() -> StreamHeader {
        StreamHeader(signalBandHz: 1500, tauWindowSec: 0.6827, combRateHz: 3000,
                     firstEchoSec: 1.0, recordWindowSec: 0.6827, stepSec: 1.0 / 24000,
                     clockSyncFloorSec: 0)
    }

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

    // MARK: - NamedStream

    func testNamedStreamCodableRoundTripContinuesSequence() throws {
        var s = referenceStream()
        for _ in 0..<6 { _ = s.next64() }

        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(NamedStream.self, from: data)

        XCTAssertEqual(decoded, s)
        XCTAssertEqual(decoded.draws, 6)

        var d = decoded
        XCTAssertEqual(d.next64(), 0x0f7335761d46764a)
        XCTAssertEqual(d.next64(), 0x7be48d99e6014011)
    }

    func testNamedStreamStateBearingInitEqualsAdvancedStream() {
        var advanced = referenceStream()
        for _ in 0..<6 { _ = advanced.next64() }

        let stateBearing = NamedStream(name: "ref",
                                        stateHi: advanced.stateWords.hi, stateLo: advanced.stateWords.lo,
                                        incHi: advanced.incWords.hi, incLo: advanced.incWords.lo,
                                        draws: advanced.draws)

        XCTAssertEqual(stateBearing, advanced)

        var a = advanced
        var b = stateBearing
        XCTAssertEqual(a.next64(), b.next64())
        XCTAssertEqual(a.draws, b.draws)
    }

    // MARK: - StreamHeader

    func testStreamHeaderCodableRoundTrip() throws {
        let h = w1Like()
        let data = try JSONEncoder().encode(h)
        let decoded = try JSONDecoder().decode(StreamHeader.self, from: data)

        XCTAssertEqual(decoded, h)
        XCTAssertTrue(decoded.isAdmissible)
    }

    // MARK: - StreamRecord

    func testStreamRecordCodableRoundTripReplays() throws {
        var r = try StreamRecord(header: header(), generator: gen())
        r.recordSlice(count: 5)
        r.recordSlice(count: 7)
        r.recordSlice(count: 3)

        let data = try JSONEncoder().encode(r)
        var decoded = try JSONDecoder().decode(StreamRecord.self, from: data)

        XCTAssertEqual(decoded, r)
        XCTAssertTrue(decoded.verify().isEmpty)
        XCTAssertEqual(try decoded.replaySlice(1), decoded.slices[1].payload)
        XCTAssertEqual(decoded.generatorState.draws, 15)

        let a = r.recordSlice(count: 2)
        let b = decoded.recordSlice(count: 2)
        XCTAssertEqual(a.payload, b.payload)
    }

    func testStreamRecordDecodeRefusesInadmissibleHeader() throws {
        let r = try StreamRecord(header: header(), generator: gen())
        let data = try JSONEncoder().encode(r)

        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var headerObj = obj["header"] as? [String: Any] else {
            XCTFail("unexpected JSON shape for StreamRecord encoding")
            return
        }
        headerObj["combRateHz"] = 100
        obj["header"] = headerObj
        let badData = try JSONSerialization.data(withJSONObject: obj)

        XCTAssertThrowsError(try JSONDecoder().decode(StreamRecord.self, from: badData)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testStreamRecordStateBearingInitThrowsOnBadHeader() {
        var badHeader = header()
        badHeader.combRateHz = 100
        XCTAssertThrowsError(try StreamRecord(header: badHeader, generator: gen(), slices: []))
    }
}
