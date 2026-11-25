import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Two defects found by an independent check:
///
/// 1. A replayed SET_NEIGHBORS_BULK record (0x16) passes the live verb's range
///    rule before one word of it is applied: every slot is -1 or a node id in
///    0..<nodeCount, refused by name through replay's `refuse` otherwise. Before
///    it, replay copied the vector unchecked, and a later FOLD RUN read past
///    LadderFold's array and trapped.
/// 2. A float-to-Int conversion on a wire number never traps: BANK OPEN's
///    Nyquist rule converted `floor(fs/2 / f0 + 1e-9)` (degenerate fs and f0
///    made it 1e291 or inf), and KERNEL LOAD's reply converted a whole fs
///    outside Int (1e300). The first is refused by name, the second prints
///    the Double.
///
/// Every test drives only verbs and functions the build before the fix
/// already had, so the same file is the red run there (the FOLD RUN, BANK
/// OPEN and KERNEL LOAD lines trap the test process).
final class EngineOVF1A2DaemonTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-ovf1a2-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    private func shmBytes(_ f: HandlerFixture) -> Data { Data(bytes: f.shm, count: f.shmBytes) }

    private func assertRefused(_ f: HandlerFixture, _ line: String, _ expected: String,
                               file: StaticString = #filePath, line l: UInt = #line) {
        let before = shmBytes(f)
        XCTAssertEqual(f.handler.handle(line), expected, file: file, line: l)
        XCTAssertEqual(shmBytes(f), before, "\(line) wrote shm", file: file, line: l)
    }

    private func neighbours(_ f: HandlerFixture) -> [Int32] {
        let n = f.handler.nodeCount
        let p = f.handler.engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        return Array(UnsafeBufferPointer(start: p, count: n * 6))
    }

    private func writeNeighborsLog(_ path: String, nodeCount n: Int, _ vectors: [[Int32]]) throws {
        let a = try DagDBWAL.Appender(path: path, nodeCount: n)
        for v in vectors {
            _ = try v.withUnsafeBufferPointer { try a.setNeighborsBulk($0.baseAddress!, count: n) }
        }
        a.barrier()
    }

    // MARK: - 1 · the reproducer: refused at replay, and FOLD RUN answers

    /// A minimal log: the header and one
    /// SET_NEIGHBORS_BULK record of 4096 nodes whose slot 0 holds 4096, then
    /// `FOLD RUN 12 3 0 1` (its probe), through the daemon's own recovery.
    func testReplayRefusesTheVerifiersNeighbourRecordAndFoldRunAnswers() throws {
        let side = 64, n = side * side
        var nb = [Int32](repeating: -1, count: n * 6)
        nb[0] = Int32(n)
        let wal = tmpDir + "x_new_fold.wal"
        try writeNeighborsLog(wal, nodeCount: n, [nb])

        let f = try HandlerFixture(side: side, dataRoot: tmpDir, maxRank: 16)
        var lines: [String] = []
        let r = try DagDBStartup.recover(
            engine: f.handler.engine, nodeCount: n, width: side, height: side,
            dagdbEnv: nil, dataRoot: tmpDir, twin: f.handler.twin, truthRankIndex: f.handler.truthRankIndex,
            snapshotPath: nil, walPath: wal, log: { lines.append($0) })
        XCTAssertNil(r.replayError)
        print("OVF1A2 recovery: " + lines.joined(separator: " | "))
        let words = "opcode 0x16: SET_NEIGHBORS_BULK of 4096: slot 0 (node 0 dir 0) neighbour 4096"
            + " not in -1..<4096; nothing applied"
        XCTAssertTrue(lines.contains { $0.contains("WAL: refused 1 record(s)") && $0.hasSuffix(words) },
                      "the record is refused at replay by name: \(lines)")
        XCTAssertEqual(neighbours(f), [Int32](repeating: -1, count: n * 6), "nothing applied")

        let fold = f.handler.handle("FOLD RUN 12 3 0 1")
        print("OVF1A2 FOLD RUN 12 3 0 1 -> \(fold)")
        XCTAssertTrue(fold.hasPrefix("OK FOLD RUN") || fold.hasPrefix("ERROR"), fold)
        XCTAssertTrue(f.handler.handle("STATUS").hasPrefix("OK STATUS"))
    }

    // MARK: - 1 · every out-of-range slot, whole or nothing; legal vectors replay

    func testReplayRefusesEveryOutOfRangeNeighbourWholeAndAppliesLegalVectors() throws {
        let side = 8, n = side * side
        // A legal vector holding both ends of the range: -1 and n - 1.
        var legal = [Int32](repeating: -1, count: n * 6)
        for i in 1..<n { legal[i * 6] = Int32(i - 1) }
        legal[5] = Int32(n - 1)
        let cases: [(slot: Int, value: Int32)] = [
            (0, Int32(n)), (1, Int32(n + 1)), (6, Int32.max), (7, -2), (n * 6 - 1, Int32.min), (12, Int32(n)),
        ]
        var refused = 0
        for c in cases {
            var bad = legal
            bad[c.slot] = c.value
            let wal = tmpDir + "nb_\(c.slot)_\(c.value).wal"
            try writeNeighborsLog(wal, nodeCount: n, [legal, bad])
            let f = try HandlerFixture(side: side)
            let r = try DagDBWAL.replay(engine: f.handler.engine, nodeCount: n, path: wal)
            let words = "SET_NEIGHBORS_BULK of \(n): slot \(c.slot) (node \(c.slot / 6) dir \(c.slot % 6))"
                + " neighbour \(c.value) not in -1..<\(n); nothing applied"
            XCTAssertEqual(r.recordsApplied, 1, "slot \(c.slot) = \(c.value): the legal record applies")
            XCTAssertEqual(r.refusals.count, 1, "slot \(c.slot) = \(c.value): \(r.refusals)")
            XCTAssertTrue(r.refusals.first?.contains("opcode 0x16: " + words) ?? false, "\(r.refusals)")
            XCTAssertEqual(r.skipReasons.outOfRangeIndex, 1, "counted with the refusals")
            XCTAssertEqual(neighbours(f), legal, "slot \(c.slot) = \(c.value): nothing of the refused record applied")
            if r.refusals.count == 1 && neighbours(f) == legal { refused += 1 }
        }
        print("OVF1A2 neighbour cases=\(cases.count) refused_whole=\(refused)")
    }

    // MARK: - 2 · BANK OPEN: degenerate or huge fs and f0

    func testBankOpenDegenerateOrHugeRatesAreRefusedByName() throws {
        let f = try HandlerFixture(side: 4)
        // The Nyquist rule's harmonic index floor(fs/2 / f0 + 1e-9): a tiny fs
        // enters the rule through its 1e-9 Hz tolerance, and a tiny f0 makes
        // the index about 1e291, about 1e23, or inf. It trapped in `Int(...)`.
        assertRefused(f, "BANK OPEN x 4096 2e-9 1e-300 60 0 0 0.02",
                      "ERROR out_of_range: BANK OPEN Nyquist harmonic index floor(fs/2 / f0) = 1.0000000000000001e+291 for fs 2e-09 Hz,"
                        + " f0 1e-300 Hz does not fit Int; nothing written")
        assertRefused(f, "BANK OPEN x 4096 1e-300 5e-324 1 0 0 0.02",
                      "ERROR out_of_range: BANK OPEN Nyquist harmonic index floor(fs/2 / f0) = 1.0120112665365531e+23"
                        + " for fs 1e-300 Hz, f0 5e-324 Hz does not fit Int; nothing written")
        assertRefused(f, "BANK OPEN x 4096 1e-9 5e-324 1 0 0 0.02",
                      "ERROR out_of_range: BANK OPEN Nyquist harmonic index floor(fs/2 / f0) = inf for fs 1e-09 Hz,"
                        + " f0 5e-324 Hz does not fit Int; nothing written")
        // Huge rates reach the rule with a small index: its own refusal, as before.
        assertRefused(f, "BANK OPEN x 4096 1e308 1e308 2 0 0 0.02",
                      "ERROR bad_value: harmonic 1 at 1e+308 Hz reaches Nyquist 5e+307 Hz (fs 1e+308); the top harmonic"
                        + " must stay below fs/2 — write ALIASED to allow")
        // Non-finite, zero and negative rates: the validator's refusals, as before.
        assertRefused(f, "BANK OPEN x 4096 inf 60 24 8 6 0.02", "ERROR bad_value: sampleRate must be positive and finite")
        assertRefused(f, "BANK OPEN x 4096 nan 60 24 8 6 0.02", "ERROR bad_value: sampleRate must be positive and finite")
        assertRefused(f, "BANK OPEN x 4096 -1e308 60 24 8 6 0.02", "ERROR bad_value: sampleRate must be positive and finite")
        assertRefused(f, "BANK OPEN x 4096 3000 inf 24 8 6 0.02", "ERROR bad_value: f0 must be positive and finite")
        assertRefused(f, "BANK OPEN x 4096 3000 0 24 8 6 0.02", "ERROR bad_value: f0 must be positive and finite")
        assertRefused(f, "BANK OPEN x 4096 3000 -5e-324 24 8 6 0.02", "ERROR bad_value: f0 must be positive and finite")
        XCTAssertEqual(f.handler.twin.banks.openCount, 0, "nothing opened")
        // The reference rates open as before.
        XCTAssertTrue(f.handler.handle("BANK OPEN y").hasPrefix("OK BANK OPEN id=w00000001 name=\"y\" T=4096 K=144 "))
    }

    // MARK: - 2 · KERNEL LOAD: a whole fs outside Int

    func testKernelLoadOfAWholeFsOutsideIntAnswers() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/w1_kernels.json")
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: src)) as? [String: Any])
        obj["fs"] = 1e300                           // finite (KernelPair accepts it) and whole, outside Int
        let path = tmpDir + "kernels_fs1e300.json"
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: path))
        let f = try HandlerFixture(side: 64, dataRoot: tmpDir)
        let load = f.handler.handle("KERNEL LOAD \(path)")
        print("OVF1A2 KERNEL LOAD fs=1e300 -> \(load)")
        XCTAssertTrue(load.hasPrefix("OK KERNEL LOAD id=k00000001 taps=2048 fs=1e+300 window=2048 ears=170/236 "
                                     + "warmup=none derived=0 sha256="), load)
        let info = f.handler.handle("KERNEL INFO k00000001")
        XCTAssertTrue(info.hasPrefix("OK KERNEL INFO") && info.contains(" fs=1e+300 "), info)
    }
}
