import XCTest
@testable import DagDB

/// Reference vectors generated from numpy PCG64 with explicitly set state:
///   state = 0x853c49e6748fea9b_da3e39cb94b95bdb (hi_lo)
///   inc   = 0x5851f42d4c957f2d_14057b7ef767814f
/// via Generator.integers(0, 2^64, dtype=uint64) — one raw draw per value.
final class NamedStreamTests: XCTestCase {
    private func referenceStream() -> NamedStream {
        NamedStream(name: "ref",
                    stateHi: 0x853c_49e6_748f_ea9b, stateLo: 0xda3e_39cb_94b9_5bdb,
                    incHi: 0x5851_f42d_4c95_7f2d, incLo: 0x1405_7b7e_f767_814f)
    }

    func testMatchesNumpyVectors() {
        var s = referenceStream()
        let expected: [UInt64] = [
            0x742924eb84751ccd, 0x20d6bcdf1e644368, 0xfd2027823296dda3,
            0x0ab11e1c7b578eed, 0x39d0a075d046cb33, 0xd3cc3d10a0f5ae56,
        ]
        for (i, e) in expected.enumerated() {
            XCTAssertEqual(s.next64(), e, "draw \(i) diverges from numpy")
        }
        XCTAssertEqual(s.draws, 6)
    }

    func testContinuationMatchesNumpy() {
        var s = referenceStream()
        for _ in 0..<6 { _ = s.next64() }
        XCTAssertEqual(s.next64(), 0x0f7335761d46764a)
        XCTAssertEqual(s.next64(), 0x7be48d99e6014011)
        XCTAssertEqual(s.draws, 8)
    }

    func testSameStateSameSequence() {
        var a = referenceStream()
        var b = referenceStream()
        for _ in 0..<64 { XCTAssertEqual(a.next64(), b.next64()) }
    }
}
