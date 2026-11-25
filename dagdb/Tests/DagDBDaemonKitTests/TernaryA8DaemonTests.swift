import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// The engine's register rule, through the daemon.
///
/// The register rule moved from the command handler into the engine's
/// `validateBackEdge`. This file holds the daemon to what it did before the
/// move: CONNECT BACK into a ternary node gives the same full reply (the text
/// below is the handler's own line before the move, word for word), whether
/// or not the node also has fan-in; nothing reaches the WAL; the self-loop,
/// range and fan-in refusals keep their words and their order; a binary
/// register is still taken and logged.
final class TernaryA8DaemonTests: XCTestCase {

    private var fixture: HandlerFixture!
    private var tmpDir: String!
    private var walPath: String!
    private let side = 8

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "tern-a8d-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        walPath = tmpDir + "a8.wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: side * side)
        fixture = try HandlerFixture(side: side, wal: wal, maxRank: 8)
    }

    override func tearDownWithError() throws {
        fixture = nil
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    private func walBytes() -> Int {
        fixture.handler.walAppender?.barrier()
        return (try? FileManager.default.attributesOfItem(atPath: walPath)[.size] as? Int) ?? -1
    }

    func testItem3ConnectBackRepliesAndOrderAreUnchanged() throws {
        let h = fixture.handler
        func expect(_ line: String, _ want: String, file: StaticString = #filePath, line ln: UInt = #line) {
            XCTAssertEqual(h.handle(line), want, line, file: file, line: ln)
        }
        expect("SET 10 MODE TTHRESH", "OK SET node=10 mode=TTHRESH noskip=0")
        expect("SET 11 MODE TTHRESH NOSKIP", "OK SET node=11 mode=TTHRESH noskip=1")
        XCTAssertTrue(h.handle("SET 20 RANK 1").hasPrefix("OK"))           // edges flow from a higher rank
        expect("CONNECT FROM 20 TO 11", "OK CONNECT from=20 to=11")          // 11: ternary and fan-in
        expect("CONNECT FROM 20 TO 12", "OK CONNECT from=20 to=12")          // 12: binary with fan-in

        var cells = 0
        let before = walBytes()
        // The reply the handler gave before the move, word for word.
        for d in [10, 11] {
            expect("CONNECT BACK FROM 3 TO \(d)",
                   "ERROR bad_value: ternary: CONNECT BACK into ternary node \(d); a register (BACK_EDGE destination) stays BINARY — SET \(d) MODE BINARY first")
            cells += 1
        }
        XCTAssertEqual(walBytes(), before, "a refused CONNECT BACK writes no record")
        XCTAssertFalse(h.engine.isRegister(node: 10))
        XCTAssertFalse(h.engine.isRegister(node: 11))
        XCTAssertEqual(h.engine.backEdgeCount, 0)
        // The checks the handler runs before the engine's keep their words and order.
        expect("CONNECT BACK FROM 10 TO 10", "ERROR schema: self-loop: src == dst (10)"); cells += 1
        XCTAssertTrue(h.handle("CONNECT BACK FROM 3 TO 64").hasPrefix("ERROR out_of_range:")); cells += 1
        // A binary destination with fan-in: still the fan-in refusal.
        expect("CONNECT BACK FROM 3 TO 12",
               "ERROR schema: BACK_EDGE dst node 12 has a combinational input at slot 0 (source node 20); registers must have zero combinational fan-in")
        cells += 1
        XCTAssertEqual(walBytes(), before)
        // A binary register is taken and logged; giving it a ternary kind is refused.
        expect("CONNECT BACK FROM 3 TO 16", "OK CONNECT BACK from=3 to=16")
        XCTAssertGreaterThan(walBytes(), before)
        XCTAssertTrue(h.engine.isRegister(node: 16))
        XCTAssertTrue(h.handle("SET 16 MODE TTABLE").hasPrefix("ERROR bad_value: ternary: node 16 is a register"))
        cells += 1
        print("A8 item3 daemon: \(cells) CONNECT BACK cells answer as before the move; refusals write no WAL record")
    }
}
