import XCTest
@testable import DagDB

final class GlobalNodeIDTests: XCTestCase {

    // MARK: - Construction + bounds

    func testConstructAtZero() throws {
        let id = try GlobalNodeID(tileId: 0, localNodeId: 0)
        XCTAssertEqual(id.raw, 0)
        XCTAssertEqual(id.tileId, 0)
        XCTAssertEqual(id.localNodeId, 0)
    }

    func testConstructAtMaxTileMaxLocal() throws {
        let id = try GlobalNodeID(tileId: 0xFF_FFFF, localNodeId: 0xFF_FFFF_FFFF)
        XCTAssertEqual(id.tileId, 0xFF_FFFF)
        XCTAssertEqual(id.localNodeId, 0xFF_FFFF_FFFF)
        XCTAssertEqual(id.raw, 0xFFFF_FFFF_FFFF_FFFF)
    }

    func testTileIdOverflowRejected() {
        XCTAssertThrowsError(try GlobalNodeID(tileId: 1 << 24, localNodeId: 0)) { err in
            guard case GlobalNodeID.DecodingError.tileIdOverflow(let v) = err else {
                XCTFail("expected tileIdOverflow, got \(err)")
                return
            }
            XCTAssertEqual(v, 1 << 24)
        }
    }

    func testLocalIdOverflowRejected() {
        XCTAssertThrowsError(try GlobalNodeID(tileId: 0, localNodeId: 1 << 40)) { err in
            guard case GlobalNodeID.DecodingError.localIdOverflow(let v) = err else {
                XCTFail("expected localIdOverflow, got \(err)")
                return
            }
            XCTAssertEqual(v, 1 << 40)
        }
    }

    func testFieldsDontBleed() throws {
        // Tile-only set: localNodeId must read 0; tileId must read max.
        let id1 = try GlobalNodeID(tileId: 0xFF_FFFF, localNodeId: 0)
        XCTAssertEqual(id1.tileId, 0xFF_FFFF)
        XCTAssertEqual(id1.localNodeId, 0)

        // Local-only set: tileId must read 0; localNodeId must read max.
        let id2 = try GlobalNodeID(tileId: 0, localNodeId: 0xFF_FFFF_FFFF)
        XCTAssertEqual(id2.tileId, 0)
        XCTAssertEqual(id2.localNodeId, 0xFF_FFFF_FFFF)
    }

    // MARK: - Round trip from raw

    func testFromRawRoundTrip() throws {
        let cases: [(tileId: UInt32, localNodeId: UInt64)] = [
            (0, 0),
            (1, 1),
            (12, 5042),
            (0xFF_FFFF, 0xFF_FFFF_FFFF),
            (0xAB_CDEF, 0x12_3456_7890),
        ]
        for c in cases {
            let id = try GlobalNodeID(tileId: c.tileId, localNodeId: c.localNodeId)
            let reconstructed = GlobalNodeID(raw: id.raw)
            XCTAssertEqual(reconstructed.tileId, c.tileId)
            XCTAssertEqual(reconstructed.localNodeId, c.localNodeId)
        }
    }

    // MARK: - toLocal

    func testToLocalSameTile() throws {
        let id = try GlobalNodeID(tileId: 7, localNodeId: 5042)
        let local = try id.toLocal(currentTile: 7)
        XCTAssertEqual(local, 5042)
    }

    func testToLocalDifferentTileThrows() throws {
        let id = try GlobalNodeID(tileId: 7, localNodeId: 5042)
        XCTAssertThrowsError(try id.toLocal(currentTile: 8)) { err in
            guard case GlobalNodeID.DecodingError.tileMismatch(let expected, let found) = err else {
                XCTFail("expected tileMismatch, got \(err)")
                return
            }
            XCTAssertEqual(expected, 8)
            XCTAssertEqual(found, 7)
        }
    }

    func testToLocalInt32OverflowThrows() throws {
        let tooBig = UInt64(Int32.max) + 1
        let id = try GlobalNodeID(tileId: 0, localNodeId: tooBig)
        XCTAssertThrowsError(try id.toLocal(currentTile: 0)) { err in
            guard case GlobalNodeID.DecodingError.localIdTooLargeForInt32(let v) = err else {
                XCTFail("expected localIdTooLargeForInt32, got \(err)")
                return
            }
            XCTAssertEqual(v, tooBig)
        }
    }

    // MARK: - Description

    func testDescriptionShape() throws {
        let id = try GlobalNodeID(tileId: 12, localNodeId: 5042)
        XCTAssertEqual(id.description, "t12:n5042")
    }

    func testDescriptionAtBoundaries() throws {
        let zero = try GlobalNodeID(tileId: 0, localNodeId: 0)
        XCTAssertEqual(zero.description, "t0:n0")

        let max = try GlobalNodeID(tileId: 0xFF_FFFF, localNodeId: 0xFF_FFFF_FFFF)
        XCTAssertEqual(max.description, "t16777215:n1099511627775")
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let original = try GlobalNodeID(tileId: 99, localNodeId: 12345)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GlobalNodeID.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.tileId, 99)
        XCTAssertEqual(decoded.localNodeId, 12345)
    }

    func testJSONIsBareInteger() throws {
        // Codable surface exposes the raw u64 — meta.json keeps GlobalNodeIDs
        // as compact numbers, not nested objects.
        let id = try GlobalNodeID(tileId: 1, localNodeId: 1)
        let data = try JSONEncoder().encode(id)
        let json = String(decoding: data, as: UTF8.self)
        let expected = String((UInt64(1) << 40) | 1)  // raw u64 as text
        XCTAssertEqual(json, expected)
    }

    // MARK: - Hashable / Equatable

    func testEquality() throws {
        let a = try GlobalNodeID(tileId: 5, localNodeId: 99)
        let b = try GlobalNodeID(tileId: 5, localNodeId: 99)
        let c = try GlobalNodeID(tileId: 6, localNodeId: 99)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testHashableUsableInSet() throws {
        let a = try GlobalNodeID(tileId: 5, localNodeId: 99)
        let b = try GlobalNodeID(tileId: 5, localNodeId: 99)
        let c = try GlobalNodeID(tileId: 6, localNodeId: 99)
        let set: Set<GlobalNodeID> = [a, b, c]
        XCTAssertEqual(set.count, 2)
    }
}
