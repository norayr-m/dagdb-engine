import XCTest
@testable import DagDB

/// The `.dags` writer keeps a −0.0 in a WGTS lane.
///
/// The `.dags` writer decides whether to write each WGTS lane (edge weights,
/// node values) from what the lane holds. Deciding by VALUE loses −0.0: a
/// node-value lane whose only non-default bit pattern is −0.0 compares equal
/// to its default 0.0 everywhere, so the lane is skipped and the load gives
/// +0.0 back. The writer decides by bit pattern.
///
/// Cells, each saved plain and zlib and loaded into a fresh engine, compared
/// on the whole state (every lane, the back edges and the library) and on the
/// −0.0's own bit pattern:
///   - v8 (a graph with ternary content): an all-zero node-value lane with
///     one −0.0; a default (all 1.0) weight lane with one −0.0; an all-zero
///     weight lane with one −0.0;
///   - v7 (a binary graph — the same WGTS writer): the same three;
///   - a binary graph whose only content is one −0.0 threshold (v8 by the
///     bit-pattern content check).
/// The weight and threshold cells hold on the old writer as well (1.0 has one
/// bit pattern, and the content check already read bits); they are kept so a
/// writer that moved back to values on those lanes fails too.
final class TernaryR4NegativeZeroLaneTests: XCTestCase {

    private var tmp: String!
    private let side = 8
    private static let negZeroBits: UInt32 = 0x8000_0000

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "tern-r4-negzero-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let d = tmp { try? FileManager.default.removeItem(atPath: d) } }

    private func fresh() throws -> DagDBEngine {
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side), maxRank: 8)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        return e
    }

    /// Ternary content: one table (TSUM, k = 2) and node 7 a TTABLE node on it.
    private func addTernaryContent(_ e: DagDBEngine) throws {
        try e.writeTables(first: 0, bytes: try TernaryReference.presetTable(.tsum, k: 2))
        e.modePtr[7] = 1
        e.ttableIdPtr[7] = 0
        e.truthStateBuf.contents().storeBytes(of: 2, toByteOffset: 7, as: UInt8.self)
    }

    private enum Lane: String, CaseIterable { case valueAllZero, weightAllDefault, weightAllZero }

    /// Fills `lane` and puts one −0.0 in it; the other WGTS lanes stay at
    /// their defaults (weights 1.0, values +0.0).
    private func plant(_ lane: Lane, in e: DagDBEngine) -> (buf: MTLBuffer, index: Int) {
        let n = e.nodeCount
        let w = e.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        let v = e.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)
        switch lane {
        case .valueAllZero:
            for i in 0..<n { v[i] = 0.0 }
            v[13] = -0.0
            return (e.nodeValueBuf, 13)
        case .weightAllDefault:
            for k in 0..<(n * 6) { w[k] = 1.0 }
            w[13 * 6 + 4] = -0.0
            return (e.edgeWeightsBuf, 13 * 6 + 4)
        case .weightAllZero:
            for k in 0..<(n * 6) { w[k] = 0.0 }
            w[13 * 6 + 4] = -0.0
            return (e.edgeWeightsBuf, 13 * 6 + 4)
        }
    }

    private func bits(_ b: MTLBuffer, _ i: Int) -> UInt32 {
        b.contents().load(fromByteOffset: i * 4, as: UInt32.self)
    }

    private func roundTrip(_ a: DagDBEngine, _ what: String, version: UInt8,
                           check: (DagDBEngine) -> Void) throws {
        for compressed in [false, true] {
            let path = tmp + "\(what)_\(compressed).dags"
            _ = try DagDBSnapshot.save(engine: a, nodeCount: a.nodeCount, gridW: side, gridH: side,
                                       tickCount: 3, path: path, compressed: compressed)
            let d = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertEqual(d[4], version, "\(what) compressed=\(compressed): file version")
            let b = try fresh()
            let r = try DagDBSnapshot.load(engine: b, nodeCount: b.nodeCount, gridW: side, gridH: side, path: path)
            XCTAssertEqual(r.bytesRead, d.count, "\(what) compressed=\(compressed): every section accounted for")
            let same = TernaryR4PersistenceTests.stateHash(a) == TernaryR4PersistenceTests.stateHash(b)
            XCTAssertTrue(same, "\(what) v\(version) compressed=\(compressed): state differs after the round trip")
            check(b)
            print("R4 -0.0 \(what) v\(version) \(compressed ? "zlib " : "plain") \(same ? "EQUAL" : "DIFFERS")")
        }
    }

    func testNegativeZeroInWGTSLanesRoundTripsBitForBit() throws {
        for withTernary in [true, false] {
            for lane in Lane.allCases {
                let a = try fresh()
                if withTernary { try addTernaryContent(a) }
                let (buf, idx) = plant(lane, in: a)
                XCTAssertNil(a.ternaryStateViolation())
                XCTAssertEqual(bits(buf, idx), Self.negZeroBits)
                try roundTrip(a, lane.rawValue, version: withTernary ? 8 : 7) { b in
                    let lb: MTLBuffer = (lane == .valueAllZero) ? b.nodeValueBuf : b.edgeWeightsBuf
                    XCTAssertEqual(self.bits(lb, idx), Self.negZeroBits,
                                   "\(lane.rawValue): the −0.0 came back as 0x\(String(self.bits(lb, idx), radix: 16))")
                }
            }
        }
    }

    func testNegativeZeroThresholdOnABinaryGraphRoundTrips() throws {
        let a = try fresh()
        a.thrLoPtr[21] = -0.0
        XCTAssertTrue(a.hasTernaryContent(), "a −0.0 threshold is content (bits, not value)")
        XCTAssertNil(a.ternaryStateViolation())
        try roundTrip(a, "thrLo", version: 8) { b in
            XCTAssertEqual(b.thrLoBuf.contents().load(fromByteOffset: 21 * 4, as: UInt32.self), Self.negZeroBits)
        }
    }
}
