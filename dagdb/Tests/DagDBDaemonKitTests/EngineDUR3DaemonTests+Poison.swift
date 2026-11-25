import XCTest
import Darwin
@testable import DagDB
@testable import DagDBDaemonKit

/// The last rule for a torn append, through its one seam
/// (`Appender.cutBackFailsForTesting`, the cut-back's `ftruncate` failing):
/// when a failed write's bytes cannot be cut back off the log, the appender
/// refuses every later append, so no record is ever written after the torn
/// bytes; they stay the log's tail, which replay drops and the next open cuts.
extension EngineDUR3DaemonTests {

    func testDUR32AFailedCutBackStopsEveryLaterAppend() throws {
        var cells = 0
        for ternary in [false, true] {
            let label = ternary ? "ternary" : "binary"
            let (f, t) = try base(ternary: ternary, seed: 0xD3B0 + (ternary ? 1 : 0))
            mix(f, t, 1)
            let before = try observe(f, t)
            let wal = try XCTUnwrap(f.handler.walAppender)
            let s0 = Self.size(walPath)
            wal.cutBackFailsForTesting = true
            signal(SIGXFSZ, SIG_IGN)
            var lim = rlimit()
            getrlimit(RLIMIT_FSIZE, &lim)
            let saved = lim
            lim.rlim_cur = rlim_t(s0 + 3)
            setrlimit(RLIMIT_FSIZE, &lim)
            let reply = f.handler.handle("SET 7 TRUTH 1")
            var restore = saved
            setrlimit(RLIMIT_FSIZE, &restore)
            wal.cutBackFailsForTesting = false
            XCTAssertTrue(reply.hasPrefix("ERROR wal: append:") && reply.contains("could not be cut back"), "\(label): \(reply)")
            XCTAssertEqual(Self.size(walPath), s0 + 3, "\(label): the torn bytes stay the tail")
            // Every later append refuses; nothing lands after the torn bytes.
            let next = f.handler.handle("SET 8 TRUTH 1")
            XCTAssertTrue(next.hasPrefix("ERROR wal: append:") && next.contains("no record is appended after it"), "\(label): \(next)")
            let rot = f.handler.handle("SET_LUTS NODES 0-\(Self.n - 1) MAP 0x0=0x1 0x1=0x2 0x2=0x3 0x3=0x0")
            XCTAssertTrue(rot.hasPrefix("ERROR wal:"), "\(label): \(rot)")
            XCTAssertEqual(Self.size(walPath), s0 + 3, "\(label): nothing appended after the torn bytes")
            XCTAssertEqual(mismatch(before, try observe(f, t)), [], "\(label): refused commands changed the state")
            f.handler.walAppender = nil
            // The restart: replay drops the torn tail, the open cuts it.
            let (g, r1, _) = try restart(snapshot: snapPath, attach: true)
            XCTAssertEqual(r1.replay?.truncatedAtOffset, s0, label)
            let cut = try XCTUnwrap(g.handler.walAppender?.tornTailCut, label)
            XCTAssertEqual(cut.offset, s0, label)
            XCTAssertEqual(cut.bytes, 3, label)
            XCTAssertEqual(mismatch(before, try observe(g, t)), [], "\(label): first restart != before")
            mix(g, t, 2)
            let live = try observe(g, t)
            let (h, r2, lines) = try restart(snapshot: snapPath, attach: false)
            XCTAssertEqual(mismatch(live, try observe(h, t)), [], "\(label): second restart != live; \(lines)")
            XCTAssertTrue(Self.clean(r2), "\(label): \(r2.replay?.skipReasons.line ?? "-")")
            print("DUR3.2 failed cut-back \(label): reply=\(reply.prefix(200)) next=\(next.prefix(120)) "
                  + "open cut=\(cut.bytes) B at \(cut.offset) (\(cut.why))")
            cells += 1
        }
        XCTAssertEqual(cells, 2)
    }
}
