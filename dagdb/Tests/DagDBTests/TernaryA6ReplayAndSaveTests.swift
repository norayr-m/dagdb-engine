import XCTest
@testable import DagDB

/// WAL replay refuses non-finite values and checks the logged-state rules.
///
/// Non-finite symmetry, on replay. SET WEIGHT and SET VALUE refuse a
/// non-finite value live, and every load path refuses a non-finite weight
/// by name. Now WAL replay refuses a non-finite weight record
/// (0x04) or value record (0x06) — skipped, counted under out_of_range,
/// named in `ReplayResult.refusals` — in a v2 log and in a v3 log, and the
/// replayed state is saveable. (The write side is gated through the daemon's
/// verbs, in TernaryA6DaemonReplayAndSaveTests.)
///
/// Replay checks every rule that depends only on logged state — the
/// node's mode, which is WAL-logged: SET TRUTH of 3 or more on a ternary
/// node, and CONNECT BACK into a ternary node, are refused on replay as they
/// are live (singly-set and bulk-set modes); the replayed state is saveable.
/// The truth-byte exemption is unchanged: a mode record refused because of the
/// truth byte (the check a tick's unlogged truth can change) is still refused.
final class TernaryA6ReplayAndSaveTests: XCTestCase {

    private var tmp: String!
    private let side = 8

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "tern-a6-\(UUID().uuidString)/"
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

    // MARK: - Crafted logs

    private func u32(_ v: UInt32) -> Data { var x = v; return Data(bytes: &x, count: 4) }
    private func f32bits(_ b: UInt32) -> Data { u32(b) }

    /// A log of the given version holding `records` (opcode, payload).
    private func writeWAL(_ name: String, version: UInt32, _ records: [(UInt8, Data)]) throws -> String {
        var f = Data("DAGW".utf8)
        for v in [version, UInt32(side * side), 0] { f.append(u32(v)) }
        for (op, payload) in records {
            f.append(u32(UInt32(payload.count))); f.append(op); f.append(payload)
        }
        let p = tmp + name
        try f.write(to: URL(fileURLWithPath: p))
        return p
    }

    private func setWeight(_ node: UInt32, _ dir: UInt8, bits: UInt32) -> (UInt8, Data) {
        (0x04, u32(node) + Data([dir]) + f32bits(bits))
    }
    private func setValue(_ node: UInt32, bits: UInt32) -> (UInt8, Data) { (0x06, u32(node) + f32bits(bits)) }
    private func setTruth(_ node: UInt32, _ v: UInt8) -> (UInt8, Data) { (0x01, u32(node) + Data([v])) }
    private func setMode(_ node: UInt32, _ m: UInt8) -> (UInt8, Data) { (0x40, u32(node) + Data([m])) }
    private func connectBack(_ src: UInt32, _ dst: UInt32) -> (UInt8, Data) { (0x10, u32(src) + u32(dst)) }
    private func modesBulk(_ modes: [UInt8]) -> (UInt8, Data) { (0x47, u32(UInt32(modes.count)) + Data(modes)) }

    private func weight(_ e: DagDBEngine, _ node: Int, _ slot: Int) -> Float {
        e.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: e.nodeCount * 6)[node * 6 + slot]
    }
    private func value(_ e: DagDBEngine, _ node: Int) -> Float {
        e.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: e.nodeCount)[node]
    }
    private func truth(_ e: DagDBEngine, _ node: Int) -> UInt8 {
        e.truthStateBuf.contents().load(fromByteOffset: node, as: UInt8.self)
    }

    /// SAVE (plain) then LOAD into a fresh engine: the state is saveable and
    /// comes back equal.
    private func assertSaveable(_ e: DagDBEngine, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(e.ternaryStateViolation(), "\(what): replayed state breaks a ternary rule", file: file, line: line)
        let p = tmp + "saveable_\(UUID().uuidString).dags"
        do {
            _ = try DagDBSnapshot.save(engine: e, nodeCount: e.nodeCount, gridW: side, gridH: side, tickCount: 0, path: p)
            let back = try fresh()
            _ = try DagDBSnapshot.load(engine: back, nodeCount: back.nodeCount, gridW: side, gridH: side, path: p)
            XCTAssertEqual(TernaryR4PersistenceTests.stateHash(back), TernaryR4PersistenceTests.stateHash(e),
                           "\(what): SAVE/LOAD of the replayed state", file: file, line: line)
        } catch {
            XCTFail("\(what): the replayed state is not saveable: \(error)", file: file, line: line)
        }
    }

    // MARK: - Replay refuses non-finite weight and value records

    func testItem2ReplayRefusesNonFiniteWeightAndValueRecords() throws {
        let nonFinite: [(UInt8, Data)] = [
            setWeight(9, 2, bits: 0x7FC0_0000),       // NaN
            setWeight(10, 0, bits: 0x7F80_0000),      // +∞
            setWeight(11, 5, bits: 0xFF80_0000),      // −∞
            setWeight(12, 3, bits: 0x7F80_0001),      // a signalling NaN
            setValue(13, bits: 0x7FC0_0001),          // NaN with a payload
            setValue(14, bits: 0x7F80_0000),          // +∞
            setValue(15, bits: 0xFF80_0000),          // −∞
        ]
        let finite: [(UInt8, Data)] = [setWeight(20, 1, bits: Float(0.5).bitPattern),
                                       setValue(21, bits: Float(2.5).bitPattern)]
        let needles = ["edge weight node=9 slot=2 is nan", "edge weight node=10 slot=0 is inf",
                       "edge weight node=11 slot=5 is -inf", "edge weight node=12 slot=3 is nan",
                       "node value node=13 is nan", "node value node=14 is inf", "node value node=15 is -inf"]
        for version: UInt32 in [2, 3] {
            // The finite records sit between the refused ones, so a refusal
            // that stopped the replay would show.
            let records = Array(nonFinite[0..<4]) + [finite[0]] + Array(nonFinite[4...]) + [finite[1]]
            let p = try writeWAL("nf_v\(version).wal", version: version, records)
            let e = try fresh()
            let r = try DagDBWAL.replay(engine: e, nodeCount: e.nodeCount, path: p)
            let what = "WAL v\(version)"
            print("A6 item2 replay \(what): applied=\(r.recordsApplied) skipped=\(r.recordsSkipped) (\(r.skipReasons.line)) refusals=\(r.refusals)")
            XCTAssertEqual(r.recordsApplied, 2, what)
            XCTAssertEqual(r.recordsSkipped, 7, what)
            XCTAssertEqual(r.skipReasons.outOfRangeIndex, 7, what)
            XCTAssertEqual(r.refusals.count, 7, "\(what): \(r.refusals)")
            for (i, needle) in needles.enumerated() where i < r.refusals.count {
                XCTAssertTrue(r.refusals[i].contains(needle), "\(what): refusal \(i) \(r.refusals[i]) lacks '\(needle)'")
                XCTAssertTrue(r.refusals[i].contains("must be finite"), "\(what): \(r.refusals[i])")
            }
            // Nothing non-finite landed; the finite records did.
            XCTAssertEqual(weight(e, 9, 2), 1.0, what); XCTAssertEqual(weight(e, 10, 0), 1.0, what)
            XCTAssertEqual(weight(e, 11, 5), 1.0, what); XCTAssertEqual(weight(e, 12, 3), 1.0, what)
            XCTAssertEqual(value(e, 13), 0, what); XCTAssertEqual(value(e, 14), 0, what); XCTAssertEqual(value(e, 15), 0, what)
            XCTAssertEqual(weight(e, 20, 1), 0.5, what); XCTAssertEqual(value(e, 21), 2.5, what)
            assertSaveable(e, what)
        }
    }

    // MARK: - Replay checks every rule that depends only on logged state

    func testItem3ReplayRefusesTruthAndBackEdgeRulesOnTernaryNodesAsLive() throws {
        let n = side * side
        var bulk = [UInt8](repeating: 0, count: n)
        bulk[10] = TernaryReference.kindTThresh
        bulk[11] = TernaryReference.kindTThresh | TernaryReference.noskipBit
        let records: [(UInt8, Data)] = [
            setMode(5, TernaryReference.kindTThresh),   // applied
            setTruth(5, 200),                           // refused: truth ≥ 3 on a ternary node
            setTruth(5, 1),                             // applied (0..2 on a ternary node)
            setTruth(9, 200),                           // applied (a binary node keeps Loom bytes)
            setMode(6, TernaryReference.kindTThresh),   // applied
            connectBack(7, 6),                          // refused: CONNECT BACK into a ternary node
            connectBack(7, 8),                          // applied (into a binary node)
            modesBulk(bulk),                            // applied (10 and 11 ternary; 5 and 6 back to BINARY)
            setTruth(10, 3),                            // refused (bulk-set mode)
            connectBack(12, 11),                        // refused (bulk-set mode)
            setTruth(5, 250),                           // applied: 5 is BINARY again
            // The truth-byte exemption, unchanged: the mode record whose check
            // reads the truth byte is still refused on replay.
            setTruth(20, 77),                           // applied (binary)
            setMode(20, TernaryReference.kindTThresh),  // refused: truth byte 77 on a ternary node
        ]
        let p = try writeWAL("item3.wal", version: 3, records)
        let e = try fresh()
        let r = try DagDBWAL.replay(engine: e, nodeCount: n, path: p)
        print("A6 item3 replay: applied=\(r.recordsApplied) skipped=\(r.recordsSkipped) (\(r.skipReasons.line)) refusals=\(r.refusals)")
        XCTAssertEqual(r.recordsApplied, 8)
        XCTAssertEqual(r.recordsSkipped, 5)
        XCTAssertEqual(r.skipReasons.outOfRangeIndex, 5)
        let needles = ["node 5: SET TRUTH 200 on a ternary node", "CONNECT BACK into ternary node 6",
                       "node 10: SET TRUTH 3 on a ternary node", "CONNECT BACK into ternary node 11",
                       "node 20: truth byte 77 on a ternary node"]
        XCTAssertEqual(r.refusals.count, needles.count, "\(r.refusals)")
        for (i, needle) in needles.enumerated() where i < r.refusals.count {
            XCTAssertTrue(r.refusals[i].contains(needle), "refusal \(i): \(r.refusals[i]) lacks '\(needle)'")
        }
        // The replayed state: what the live session would hold.
        XCTAssertEqual(truth(e, 5), 250); XCTAssertEqual(truth(e, 9), 200)
        XCTAssertEqual(truth(e, 10), 0, "the refused SET TRUTH 3 did not land")
        XCTAssertEqual(e.modeLane[10], TernaryReference.kindTThresh)
        XCTAssertEqual(e.modeLane[11], TernaryReference.kindTThresh | TernaryReference.noskipBit)
        XCTAssertEqual(e.modeLane[20], 0, "the refusal of a mode over truth byte 77 stands")
        XCTAssertFalse(e.isRegister(node: 6), "the refused CONNECT BACK did not land")
        XCTAssertFalse(e.isRegister(node: 11), "the refused CONNECT BACK did not land")
        XCTAssertTrue(e.isRegister(node: 8))
        XCTAssertEqual(e.backEdgeCount, 1)
        XCTAssertEqual(e.ternaryNodeCount(), 2)
        assertSaveable(e, "item 3 replay")
    }
}
