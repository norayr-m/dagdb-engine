import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// The handler-level follow-up items (the nits, and a claim measured). The
/// two items about the daemon surviving a client that closes before accept
/// are driven against real sandbox daemons in `test_engine_e2f_live.py`.
///
/// Red on the code before these fixes: `TICK <garbage>` ran one tick; the
/// TRUTH_SLICE out-of-range line named a clamped value (Int.max), not the one
/// sent; the bulk verbs' shm-too-small refusal named no verb and did not end
/// "; nothing written".
final class EngineE2FDaemonTests: XCTestCase {

    private var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "engine-e2f-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    private func ticks(_ f: HandlerFixture) -> String {
        let s = f.handler.handle("STATUS")
        return s.components(separatedBy: " ").first { $0.hasPrefix("ticks=") } ?? "?"
    }

    // MARK: - Nit 4 · TICK <garbage> is refused as unknown (a tightening)

    func testTickGarbageIsUnknownAndTicksNothing() throws {
        let f = try HandlerFixture(side: 4)
        for line in ["TICK foo", "TICK 1x", "TICK x 3", "TICK UNTIL", "TICK 1.5", "TICK -"] {
            let r = f.handler.handle(line)
            XCTAssertEqual(r, "ERROR unknown_command: \(Reply.quoted(line))", line)
            XCTAssertEqual(ticks(f), "ticks=0", "\(line) ticked")
        }
        // The existing forms, unchanged.
        XCTAssertTrue(f.handler.handle("TICK").hasPrefix("OK TICK 1 "))
        XCTAssertEqual(ticks(f), "ticks=1")
        XCTAssertTrue(f.handler.handle("TICK 3").hasPrefix("OK TICK 3 "))
        XCTAssertEqual(ticks(f), "ticks=4")
        XCTAssertTrue(f.handler.handle("TICK UNTIL_STABLE MAX 5").hasPrefix("OK TICK UNTIL_STABLE stable "))
        XCTAssertTrue(f.handler.handle("TICK -2").hasPrefix("ERROR out_of_range"))
    }

    // MARK: - Nit 2 · the out-of-range line names the value the caller sent

    func testTruthSliceOutOfRangeNamesTheValueSent() throws {
        let f = try HandlerFixture(side: 4)
        XCTAssertEqual(f.handler.handle("TRUTH_SLICE NODES 0-18446744073709551615"),
                       "ERROR out_of_range: node 18446744073709551615 not in 0..<16")
        XCTAssertEqual(f.handler.handle("TRUTH_SLICE NODES 3-9223372036854775808"),
                       "ERROR out_of_range: node 9223372036854775808 not in 0..<16")
        // The small case keeps its words.
        XCTAssertEqual(f.handler.handle("TRUTH_SLICE NODES 0-16"), "ERROR out_of_range: node 16 not in 0..<16")
    }

    // MARK: - Nit 3 · the shm-too-small bulk refusal names its verb, nothing written

    func testBulkShmTooSmallNamesItsVerbAndWritesNothing() throws {
        let walPath = tmp + "cap.wal"
        let f = try HandlerFixture(side: 4, wal: try DagDBWAL.Appender(path: walPath, nodeCount: 16))
        let h = f.shm.bindMemory(to: UInt32.self, capacity: 2)
        let cap = f.shmBytes   // 8 + 16 × 24 = 392
        for verb in ["CONNECT_BACK_BULK", "SET_TRUTH_BULK"] {
            for count in [UInt32(1_000_000), UInt32.max] {
                h[0] = count; h[1] = shm1Word1(.named(verb))
                let needs = Int(count) * 8 + 8
                XCTAssertEqual(f.handler.handle(verb),
                               "ERROR out_of_range: result needs \(needs) bytes, shm holds \(cap);"
                               + " \(verb) count \(count) (row 8) does not fit; nothing written")
            }
        }
        XCTAssertEqual(f.handler.engine.backEdgeCount, 0)
        f.handler.walAppender?.barrier()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: walPath)).count, DagDBWAL.headerSize)
    }

    // MARK: - Bulks need a v3 WAL; v1 and v2 logs refuse them by name

    func testBulksOnVersion1And2LogsRefusedByName() throws {
        for version in [UInt32(1), UInt32(2)] {
            for (verb, op) in [("CONNECT_BACK_BULK", "0x4d"), ("SET_TRUTH_BULK", "0x4e")] {
                let p = tmp + "v\(version)_\(verb).wal"
                var hdr = Data(DagDBWAL.magic)
                for v in [version, UInt32(16), UInt32(0)] { withUnsafeBytes(of: v.littleEndian) { hdr.append(contentsOf: $0) } }
                try hdr.write(to: URL(fileURLWithPath: p))
                let f = try HandlerFixture(side: 4, wal: try DagDBWAL.Appender(path: p, nodeCount: 16))
                let h = f.shm.bindMemory(to: UInt32.self, capacity: 4)
                // One valid entry each: back edge 1 -> 2; node 1 truth 2 (pad zero).
                h[0] = 1; h[1] = shm1Word1(.named(verb)); h[2] = 1; h[3] = 2
                let truthBefore = f.handler.handle("GET 1 TRUTH")
                // The refusal names the way to a log that takes the record.
                XCTAssertEqual(f.handler.handle(verb),
                               "ERROR wal: append: opcode \(op) needs log version 3, this log is version \(version)"
                               + "; nothing written; this log cannot be upgraded in place: first stop every writer (a write between this SAVE and the stop stays in the log moved aside, and is lost); then SAVE a snapshot to a file, stop the daemon, move \(p) aside" + " and start it again with DAGDB_STARTUP_LOAD naming that file (it loads the file and opens a fresh version-3 log;" + " the fresh log takes this record)")
                XCTAssertEqual(f.handler.engine.backEdgeCount, 0)
                XCTAssertEqual(f.handler.handle("GET 1 TRUTH"), truthBefore)
                f.handler.walAppender?.barrier()
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: p)).count, DagDBWAL.headerSize)
            }
        }
    }
}
