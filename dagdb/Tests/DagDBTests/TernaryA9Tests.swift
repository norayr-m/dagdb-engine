import XCTest
@testable import DagDB

/// The checked BACK_EDGE API refuses a ternary destination.
///
/// The engine's checked BACK_EDGE API refuses a ternary destination by name
/// ("a register stays BINARY"), not only the daemon's
/// CONNECT BACK. Nine cells: `validateBackEdge` and `addBackEdge` onto a
/// destination of each ternary mode byte (1, 2, 5, 6) — eight — and
/// `addBackEdge` onto a ternary node that also has combinational fan-in,
/// which must name the register rule (the rule CONNECT BACK always named
/// first for such a node). A refused call leaves no back edge and no register
/// flag. Controls, green before and after: a binary destination is taken; a
/// binary destination with fan-in keeps the fan-in refusal word for word; the
/// unchecked path (`registerValidatedBackEdge`, which WAL replay's and the
/// handler's apply step stand on) still installs whatever it is given.
///
/// Every check reads the error's text, so this file compiles against the code
/// before the fix (the red run) and after it (the green run).
final class TernaryA9Tests: XCTestCase {

    private let side = 8
    private var n: Int { side * side }

    private func fresh() throws -> DagDBEngine {
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side), maxRank: 8)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        return e
    }

    /// The refusal names the destination, the ternary rule and its remedy word.
    private func namesTernaryRule(_ error: Error?, dst: Int) -> Bool {
        guard let error = error else { return false }
        let s = "\(error)"
        return s.contains("dst node \(dst) is a ternary node") && s.contains("stays BINARY")
    }

    func testItem3CheckedBackEdgeAPIRefusesATernaryDestination() throws {
        var cells = 0, refused = 0
        for mode: UInt8 in [1, 2, 5, 6] {
            for api in ["validateBackEdge", "addBackEdge"] {
                let e = try fresh()
                e.setNodeMode(10, mode)
                cells += 1
                var caught: Error? = nil
                do {
                    if api == "validateBackEdge" { try e.validateBackEdge(src: 3, dst: 10) }
                    else { try e.addBackEdge(src: 3, dst: 10) }
                } catch { caught = error }
                let ok = namesTernaryRule(caught, dst: 10)
                if ok { refused += 1 }
                XCTAssertTrue(ok, "\(api) onto mode \(mode): \(caught.map { "\($0)" } ?? "accepted")")
                XCTAssertEqual(e.backEdgeCount, 0, "\(api) onto mode \(mode) left a back edge")
                XCTAssertFalse(e.isRegister(node: 10), "\(api) onto mode \(mode) left a register flag")
            }
        }
        // A ternary node that also has fan-in: the register rule is named, not the fan-in rule.
        do {
            let e = try fresh()
            e.setNodeMode(11, TernaryReference.kindTThresh)
            e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)[11 * 6 + 0] = 20
            cells += 1
            var caught: Error? = nil
            do { try e.addBackEdge(src: 3, dst: 11) } catch { caught = error }
            let ok = namesTernaryRule(caught, dst: 11)
            if ok { refused += 1 }
            XCTAssertTrue(ok, "addBackEdge onto a ternary node with fan-in: \(caught.map { "\($0)" } ?? "accepted")")
            XCTAssertEqual(e.backEdgeCount, 0)
            XCTAssertFalse(e.isRegister(node: 11))
        }
        print("A8 item3 (A9 item3) engine: \(refused)/\(cells) checked BACK_EDGE calls onto a ternary destination refused by name")

        // Controls.
        let e = try fresh()
        try e.addBackEdge(src: 3, dst: 12)                       // a binary destination is taken
        XCTAssertTrue(e.isRegister(node: 12))
        XCTAssertEqual(e.backEdgeCount, 1)
        e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)[13 * 6 + 2] = 21
        XCTAssertThrowsError(try e.addBackEdge(src: 3, dst: 13)) { err in   // binary with fan-in: unchanged words
            XCTAssertEqual("\(err)", "BACK_EDGE dst node 13 has a combinational input at slot 2 (source node 21); registers must have zero combinational fan-in")
        }
        e.setNodeMode(14, TernaryReference.kindTTable)
        try e.registerValidatedBackEdge(src: 3, dst: 14)        // the unchecked path is unchanged
        XCTAssertTrue(e.isRegister(node: 14))
        XCTAssertEqual(e.backEdgeCount, 2)
        XCTAssertTrue(e.ternaryStateViolation()?.contains("register") == true,
                      "the state check still names a ternary register installed through the unchecked path")
    }
}
