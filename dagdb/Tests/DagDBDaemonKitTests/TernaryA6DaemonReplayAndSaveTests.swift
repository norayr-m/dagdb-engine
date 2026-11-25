import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Non-finite symmetry and replay "as live", through the daemon's verbs and
/// its startup replay.
///
/// "As live": a live session refuses SET TRUTH ≥ 3 on a ternary node
/// and CONNECT BACK into one, so neither reaches the WAL; the same two
/// records appended to that session's log by hand (what a log the daemon
/// never wrote would hold) are refused by `DagDBStartup.recover` — skipped,
/// counted, named — and the recovered daemon's SAVE succeeds and equals the
/// live session's state.
///
/// On the wire: an engine forced to hold a non-finite weight or value
/// answers SAVE, SAVE … COMPRESSED, SAVE JSON and EXPORT MORTON — and SAVE CSV, SAVE TILED, BACKUP INIT and BACKUP
/// APPEND, which write the same lanes — with an error that names the node (and slot) and
/// the rule, and writes nothing (an older chain BACKUP INIT would clear is
/// left byte for byte); with the lanes finite again every verb writes and its
/// output loads back equal. A crafted log's non-finite SET WEIGHT / SET VALUE
/// records are refused at startup.
final class TernaryA6DaemonReplayAndSaveTests: XCTestCase {

    private var fixture: HandlerFixture!
    private var tmpDir: String!
    private var walPath: String!
    private let side = 8

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "tern-a6d-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        walPath = tmpDir + "a6.wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: side * side)
        fixture = try HandlerFixture(side: side, wal: wal, maxRank: 8)
    }

    override func tearDownWithError() throws {
        fixture = nil
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    @discardableResult
    private func send(_ line: String, _ prefix: String, file: StaticString = #filePath, line ln: UInt = #line) -> String {
        let r = fixture.handler.handle(line)
        XCTAssertTrue(r.hasPrefix(prefix), "\(line) -> \(r)", file: file, line: ln)
        return r
    }

    private func u32(_ v: UInt32) -> Data { var x = v; return Data(bytes: &x, count: 4) }
    private func appendRecords(_ records: [(UInt8, Data)]) throws {
        fixture.handler.walAppender?.barrier()
        let h = try XCTUnwrap(FileHandle(forWritingAtPath: walPath))
        h.seekToEndOfFile()
        for (op, payload) in records {
            h.write(u32(UInt32(payload.count))); h.write(Data([op])); h.write(payload)
        }
        try h.close()
    }

    private func freshEngine() throws -> DagDBEngine {
        let n = side * side
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side), maxRank: 8)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        for i in 0..<(n * 6) { nb[i] = -1 }
        return e
    }

    private func recover(into e: DagDBEngine) throws -> DagDBWAL.ReplayResult {
        var lines: [String] = []
        let r = try DagDBStartup.recover(
            engine: e, nodeCount: side * side, width: side, height: side, dagdbEnv: nil, dataRoot: nil,
            twin: TwinState(), truthRankIndex: TruthRankIndex(), snapshotPath: nil, walPath: walPath,
            log: { lines.append($0) })
        XCTAssertNil(r.replayError)
        for l in lines { print("A6 daemon startup:\(l)") }
        return try XCTUnwrap(r.replay)
    }

    func testItem3LiveRefusalsAreReplayRefusalsAndTheStateIsSaveable() throws {
        send("SET 5 MODE TTHRESH", "OK SET node=5 mode=TTHRESH")
        send("SET 6 MODE TTHRESH NOSKIP", "OK SET node=6 mode=TTHRESH noskip=1")
        send("SET 5 TRUTH 1", "OK SET node=5 truth=1")
        send("SET 9 TRUTH 200", "OK SET node=9 truth=200")
        send("CONNECT BACK FROM 7 TO 8", "OK CONNECT BACK")
        // Live: refused, so never logged.
        let liveTruth = send("SET 5 TRUTH 200", "ERROR bad_value: ternary: SET TRUTH on ternary node 5")
        let liveBack = send("CONNECT BACK FROM 7 TO 6", "ERROR bad_value: ternary: CONNECT BACK into ternary node 6")
        let live = TernaryR5DaemonTests.stateHash(fixture.handler.engine)

        // The same two writes as records at the log's tail.
        try appendRecords([(0x01, u32(5) + Data([200])), (0x10, u32(7) + u32(6))])
        let e = try freshEngine()
        let r = try recover(into: e)
        print("A6 item3 daemon: live '\(liveTruth)' / '\(liveBack)'; replay applied=\(r.recordsApplied) skipped=\(r.recordsSkipped) (\(r.skipReasons.line)) refusals=\(r.refusals)")
        XCTAssertEqual(r.recordsSkipped, 2)
        XCTAssertEqual(r.skipReasons.outOfRangeIndex, 2)
        XCTAssertEqual(r.refusals.count, 2, "\(r.refusals)")
        XCTAssertTrue(r.refusals.first?.contains("opcode 0x01: node 5: SET TRUTH 200 on a ternary node") == true, "\(r.refusals)")
        XCTAssertTrue(r.refusals.last?.contains("opcode 0x10: node 6: CONNECT BACK into ternary node 6") == true, "\(r.refusals)")
        XCTAssertEqual(TernaryR5DaemonTests.stateHash(e), live, "the replayed state equals the live session's")

        // The recovered daemon saves, and the file loads back equal.
        let h2 = try HandlerFixture(side: side, maxRank: 8)
        let n = side * side
        let save = tmpDir + "a6_item3.dags"
        _ = try DagDBSnapshot.save(engine: e, nodeCount: n, gridW: side, gridH: side, tickCount: 0, path: save)
        let reply = h2.handler.handle("LOAD \(save)")
        XCTAssertTrue(reply.hasPrefix("OK LOAD"), reply)
        XCTAssertEqual(TernaryR5DaemonTests.stateHash(h2.handler.engine), live)
        let resave = h2.handler.handle("SAVE \(tmpDir!)a6_item3_again.dags")
        XCTAssertTrue(resave.hasPrefix("OK SAVE"), resave)
    }

    /// Every daemon verb that writes the engine's lanes: SAVE, SAVE …
    /// COMPRESSED, SAVE JSON and EXPORT MORTON (the four named first), and SAVE CSV, BACKUP INIT and BACKUP APPEND, which write the
    /// same lanes. `out` is the target under the cell's own prefix.
    private let writeVerbs: [(name: String, line: (String) -> String, load: (String) -> String)] = [
        ("SAVE", { "SAVE \($0).dags" }, { "LOAD \($0).dags" }),
        ("SAVE COMPRESSED", { "SAVE \($0).dags COMPRESSED" }, { "LOAD \($0).dags" }),
        ("SAVE JSON", { "SAVE JSON \($0).json" }, { "LOAD JSON \($0).json" }),
        ("EXPORT MORTON", { "EXPORT MORTON \($0)" }, { "IMPORT MORTON \($0)" }),
        ("SAVE CSV", { "SAVE CSV \($0)" }, { "LOAD CSV \($0)" }),
        ("BACKUP INIT", { "BACKUP INIT \($0)" }, { "BACKUP RESTORE \($0)" }),
    ]

    /// Every file in `dir` by name, with its bytes — a rewrite under the same
    /// name shows.
    private func fingerprint(_ dir: String) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir) {
            out[name] = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + name))
        }
        return out
    }

    func testItem2WriteVerbsRefuseANonFiniteLaneByNameAndWriteNothing() throws {
        send("TTABLE PRESET 0 TSUM 2", "OK TTABLE PRESET")
        send("SET 7 MODE TTABLE", "OK SET node=7 mode=TTABLE")
        send("SET 9 WEIGHT 2 0.5", "OK SET node=9 weight[2]=0.5")
        send("SET 12 VALUE 1.5", "OK SET node=12 value=1.5")
        send("SET 9 WEIGHT 2 nan", "ERROR bad_value: weight must be finite")
        send("SET 12 VALUE inf", "ERROR bad_value: value must be finite")
        let e = fixture.handler.engine
        let w = e.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: e.nodeCount * 6)
        let v = e.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: e.nodeCount)
        // A chain whose tip is the finite state, for BACKUP APPEND.
        let chain = tmpDir + "chain"
        send("BACKUP INIT \(chain)", "OK BACKUP_INIT")
        let chainBefore = try fingerprint(chain)
        // An older chain BACKUP INIT would clear if it ran.
        let oldChain = tmpDir + "oldchain"
        send("BACKUP INIT \(oldChain)", "OK BACKUP_INIT")
        var cells = 0, refused = 0
        for (what, needle, force, undo) in [
            ("NaN weight", "edge weight node=9 slot=2 is nan", { w[9 * 6 + 2] = .nan }, { w[9 * 6 + 2] = 0.5 }),
            ("+inf weight", "edge weight node=40 slot=5 is inf", { w[40 * 6 + 5] = .infinity }, { w[40 * 6 + 5] = 1 }),
            ("NaN value", "node value node=12 is nan", { v[12] = .nan }, { v[12] = 1.5 }),
            ("-inf value", "node value node=63 is -inf", { v[63] = -.infinity }, { v[63] = 0 }),
        ] as [(String, String, () -> Void, () -> Void)] {
            force()
            for verb in writeVerbs {
                let prefix = "\(cells)_"
                let line = verb.name == "BACKUP INIT" ? "BACKUP INIT \(oldChain)" : verb.line(tmpDir + prefix + "out")
                let before = try fingerprint(oldChain)
                let reply = fixture.handler.handle(line)
                let byName = reply.hasPrefix("ERROR") && reply.contains(needle) && reply.contains("must be finite")
                XCTAssertTrue(byName, "\(verb.name) × \(what): \(reply)")
                let written = (try FileManager.default.contentsOfDirectory(atPath: tmpDir)).filter { $0.hasPrefix(prefix) }
                let after = try fingerprint(oldChain)
                let nothing = written.isEmpty && after == before
                XCTAssertTrue(nothing, "\(verb.name) × \(what): wrote \(written), old chain \(before.keys.sorted()) → \(after.keys.sorted()) (contents equal: \(after == before))")
                if byName && nothing { refused += 1 }
                print("A6 item2 daemon \(verb.name) × \(what): nothing_written=\(nothing) — \(reply)")
                cells += 1
            }
            // SAVE TILED writes each tile's body through the snapshot writer,
            // and TILED OPEN loads it through LOAD, which refuses a
            // non-finite weight: the same symmetry.
            let tiled = tmpDir + "\(cells)_tiled/g"
            let tReply = fixture.handler.handle("SAVE TILED \(tiled) 32")
            let tByName = tReply.hasPrefix("ERROR") && tReply.contains(needle) && tReply.contains("must be finite")
            let tWritten = FileManager.default.fileExists(atPath: tmpDir + "\(cells)_tiled")
            XCTAssertTrue(tByName, "SAVE TILED × \(what): \(tReply)")
            XCTAssertFalse(tWritten, "SAVE TILED × \(what): wrote the tile directory")
            if tByName && !tWritten { refused += 1 }
            print("A6 item2 daemon SAVE TILED × \(what): nothing_written=\(!tWritten) — \(tReply)")
            cells += 1
            let reply = fixture.handler.handle("BACKUP APPEND \(chain)")
            let after = try fingerprint(chain)
            let byName = reply.hasPrefix("ERROR") && reply.contains(needle) && reply.contains("must be finite")
            XCTAssertTrue(byName, "BACKUP APPEND × \(what): \(reply)")
            XCTAssertEqual(after, chainBefore, "BACKUP APPEND × \(what): the chain changed")
            if byName && after == chainBefore { refused += 1 }
            print("A6 item2 daemon BACKUP APPEND × \(what): chain_unchanged=\(after == chainBefore) — \(reply)")
            cells += 1
            undo()
        }
        XCTAssertEqual(cells, 4 * (writeVerbs.count + 2))
        XCTAssertEqual(refused, cells)
        // Control: the finite state writes on every verb, and each output
        // loads back into a fresh daemon equal to the live state.
        let live = TernaryR5DaemonTests.stateHash(e)
        for verb in writeVerbs {
            let out = tmpDir + "ok_" + verb.name.replacingOccurrences(of: " ", with: "_")
            send(verb.line(out), "OK")
            let other = try HandlerFixture(side: side, maxRank: 8)
            let r = other.handler.handle(verb.load(out))
            XCTAssertTrue(r.hasPrefix("OK"), "\(verb.name) control load: \(r)")
            XCTAssertEqual(TernaryR5DaemonTests.stateHash(other.handler.engine), live, "\(verb.name) control")
        }
        send("SAVE TILED \(tmpDir!)ok_tiled/g 32", "OK SAVE TILED")
        send("BACKUP APPEND \(chain)", "OK BACKUP_APPEND")
        let other = try HandlerFixture(side: side, maxRank: 8)
        XCTAssertTrue(other.handler.handle("BACKUP RESTORE \(chain)").hasPrefix("OK"))
        XCTAssertEqual(TernaryR5DaemonTests.stateHash(other.handler.engine), live, "BACKUP APPEND control")
        print("A6 item2 daemon write verbs: \(refused)/\(cells) refused by name with nothing written; finite controls written and loaded back equal")
    }

    func testItem2StartupRefusesNonFiniteWeightAndValueRecords() throws {
        send("SET 9 WEIGHT 2 0.5", "OK SET node=9 weight[2]=0.5")
        send("SET 12 VALUE 1.5", "OK SET node=12 value=1.5")
        let live = TernaryR5DaemonTests.stateHash(fixture.handler.engine)
        try appendRecords([(0x04, u32(9) + Data([2]) + u32(Float.nan.bitPattern)),
                           (0x06, u32(12) + u32(Float.infinity.bitPattern))])
        let e = try freshEngine()
        let r = try recover(into: e)
        print("A6 item2 daemon startup: applied=\(r.recordsApplied) skipped=\(r.recordsSkipped) (\(r.skipReasons.line)) refusals=\(r.refusals)")
        XCTAssertEqual(r.recordsApplied, 2)
        XCTAssertEqual(r.recordsSkipped, 2)
        XCTAssertEqual(r.refusals.count, 2, "\(r.refusals)")
        XCTAssertTrue(r.refusals.first?.contains("opcode 0x04: edge weight node=9 slot=2 is nan") == true, "\(r.refusals)")
        XCTAssertTrue(r.refusals.last?.contains("opcode 0x06: node value node=12 is inf") == true, "\(r.refusals)")
        XCTAssertEqual(TernaryR5DaemonTests.stateHash(e), live)
    }
}
