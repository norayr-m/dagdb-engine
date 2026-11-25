// In-process checks — each charge refuses by
// name one byte under it and admits at it (an injected footprint and budget), STATUS never allocates, the name cap and
// its era rule, and a split import replays holding its files once.
//
// Amateur engineering project; no competitive claims; errors likely.
import XCTest
import Foundation
@testable import DagDB
@testable import DagDBDaemonKit

final class EngineALLOC1dTests: XCTestCase {
    private var tmpDir: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment["DAGDB_TEST_SCRATCH"] ?? ""
        tmpDir = (env.isEmpty ? NSTemporaryDirectory() : env + "/") + "dagdb-alloc1d-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    private func budget(_ f: HandlerFixture, bytes: Int, footprint: Int = 0) {
        f.handler.memoryBudget = DaemonMemoryBudget(budgetBytes: bytes, source: "--mem-budget-gb", footprint: { footprint },
                                                    fixedStateBytes: 0)
    }

    /// The bytes a refusal names ("<verb> needs N bytes").
    private func needs(_ reply: String) -> Int? {
        guard let r = reply.range(of: " needs ") else { return nil }
        return Int(reply[r.upperBound...].prefix { $0.isNumber })
    }

    /// One byte under the charge the verb names is refused by name (the committed check), at the charge it runs.
    private func assertExact(_ make: () throws -> HandlerFixture, _ line: String, verb: String, expect: Int? = nil,
                             file: StaticString = #filePath, lineNo: UInt = #line) throws {
        let probe = try make()
        budget(probe, bytes: 1)
        let refused = probe.handler.handle(line)
        XCTAssertTrue(refused.hasPrefix("ERROR out_of_budget: \(verb) needs "), refused, file: file, line: lineNo)
        guard let n = needs(refused) else { return XCTFail("no bytes in \(refused)", file: file, line: lineNo) }
        if let e = expect { XCTAssertEqual(n, e, "the charge the formulas give", file: file, line: lineNo) }
        let under = try make()
        let ledger = under.handler.committedLedgerBytes()
        budget(under, bytes: ledger + n - 1)
        let r1 = under.handler.handle(line)
        XCTAssertTrue(r1.hasPrefix("ERROR out_of_budget: \(verb) needs \(n) bytes"), r1, file: file, line: lineNo)
        XCTAssertTrue(r1.contains("committed"), r1, file: file, line: lineNo)
        let at = try make()
        budget(at, bytes: at.handler.committedLedgerBytes() + n)
        let r2 = at.handler.handle(line)
        XCTAssertTrue(r2.hasPrefix("OK"), "\(line) at its charge: \(r2)", file: file, line: lineNo)
    }

    private func withBackEdges(_ k: Int) throws -> HandlerFixture {
        let f = try HandlerFixture(side: 16)
        for i in 0..<k {
            let r = f.handler.handle("CONNECT BACK FROM \(i % 200) TO \(200 + i % 56)")
            XCTAssertTrue(r.hasPrefix("OK"), r)
        }
        return f
    }

    // MARK: - The Metal pool's reservation

    func testD1TheReservationIsInTheFixedStateAndTheBootRefusesBelowIt() {
        let b = DaemonMemoryBudget.make(nodeCount: 4096, overrideGiB: nil)
        XCTAssertEqual(b.poolReservationBytes, 129_472_922)
        XCTAssertEqual(b.poolReservationBytes, Int((1.1 * 117_702_656.0).rounded(.up)))
        XCTAssertEqual(b.fixedStateBytes, DaemonMemoryBudget.fixedStateBytes(nodeCount: 4096) + 129_472_922)
        XCTAssertNil(b.fixedStateRefusal)
        XCTAssertTrue(b.poolReservationLine.contains("129472922 B"), b.poolReservationLine)
        let fixed = DaemonMemoryBudget.fixedStateBytes(nodeCount: 4096) + 129_472_922
        let under = DaemonMemoryBudget.make(nodeCount: 4096, overrideGiB: Double(fixed - 1) / Double(1 << 30))
        let why = under.fixedStateRefusal ?? ""
        XCTAssertTrue(why.hasPrefix("ERROR out_of_budget: the boot needs at least \(fixed) bytes for the fixed state"), why)
        XCTAssertTrue(why.contains("Metal pool's reservation of 129472922 B") && why.contains("--mem-budget-gb"), why)
        let at = DaemonMemoryBudget.make(nodeCount: 4096, overrideGiB: Double(fixed + 1024) / Double(1 << 30))
        XCTAssertNil(at.fixedStateRefusal)
    }

    func testD1ALargerMeasuredPoolRaisesTheReservationAndPastTheBudgetGPUVerbsAreRefused() throws {
        let b = DaemonMemoryBudget(budgetBytes: 300 << 20, source: "--mem-budget-gb", footprint: { 0 },
                                   fixedStateBytes: 10 << 20, poolReservationBytes: 129_472_922)
        let held = b.raisePoolReservation(measured: 117_702_656, verb: "TICK")
        XCTAssertTrue(held.contains("holds it"), held)
        XCTAssertEqual(b.poolReservationBytes, 129_472_922)
        let raised = b.raisePoolReservation(measured: 200 << 20, verb: "TICK")
        XCTAssertTrue(raised.contains("raised to \(Int((1.1 * Double(200 << 20)).rounded(.up))) B"), raised)
        XCTAssertNil(b.gpuRefusal, "300 MiB still holds 10 MiB + 220 MiB")
        let f = try HandlerFixture(side: 4)
        let small = DaemonMemoryBudget(budgetBytes: 200 << 20, source: "--mem-budget-gb", footprint: { 0 },
                                       fixedStateBytes: 10 << 20, poolReservationBytes: 129_472_922)
        f.handler.memoryBudget = small
        let line = small.raisePoolReservation(measured: 190 << 20, verb: "TICK")
        XCTAssertTrue(line.contains("GPU verbs are refused by name"), line)
        let r = f.handler.handle("TICK 1")
        XCTAssertTrue(r.hasPrefix("ERROR out_of_budget: TICK refused: the Metal pool's raised reservation"), r)
        XCTAssertTrue(f.handler.handle("STATUS").hasPrefix("OK STATUS"), "a CPU verb still runs")
        XCTAssertEqual(f.handler.tickCount, 0, "nothing ticked")
    }

    // MARK: - The tick verbs' charges

    func testD2TickVerbsAreRefusedOneByteUnderTheirChargeAndRunAtIt() throws {
        let syncBytes: Double = 1.0 * 256.0 + 32_768.0 + 1.01 * 40.0
        let syncCharge = Int((1.1 * syncBytes).rounded(.up))
        try assertExact({ try withBackEdges(40) }, "TICK_SYNC 1", verb: "TICK_SYNC", expect: syncCharge)
        try assertExact({ try withBackEdges(40) }, "TICK 1", verb: "TICK")
        try assertExact({ try withBackEdges(40) }, "TICK UNTIL_STABLE MAX 4", verb: "TICK UNTIL_STABLE")
        // The latch plan's resident is in the ledger while the plan lives.
        let f = try withBackEdges(40)
        XCTAssertTrue(f.handler.handle("TICK UNTIL_STABLE MAX 4").hasPrefix("OK"))
        XCTAssertTrue(f.handler.engine.hasLatchPlan)
        let d = f.handler.engine.latchPlanDestinations
        XCTAssertGreaterThan(d, 0)
        let e = f.handler.engine
        var sum: Double = AdmissionCharge.rankTableKept(levels: e.rankTableLevels)
        if e.ternaryLaneBytes > 0 { sum += AdmissionCharge.ternaryLanes(nodes: 256) }   // the first CONNECT BACK's lanes
        sum += AdmissionCharge.firstTickBuffers(nodes: 256)
        if e.frontierBytesHeld > 0 { sum += AdmissionCharge.frontierIndex(bufferBytes: e.frontierBytesHeld) }   // the frontier index's buffers, while held
        sum += AdmissionCharge.latchPlanResident(destinations: d)
        let expected: Double = 1.1 * sum
        XCTAssertEqual(DagDBCommandHandler.alloc1dEngineLedger(engine: e, truthIndexHeld: false), expected, accuracy: 1e-6)
    }

    // MARK: - STATUS and the first-use allocations

    func testD3StatusNeverAllocatesAndReportsWhatABuildWould() throws {
        let f = try HandlerFixture(side: 16)
        let ranks = (0..<256).map { UInt64($0 % 9) }
        f.handler.engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: 256).update(from: ranks, count: 256)
        f.handler.engine.markRankTopologyDirty()
        let before = f.handler.engine.rankTopologyRebuildCount
        let s = f.handler.handle("STATUS")
        XCTAssertEqual(f.handler.engine.rankTopologyRebuildCount, before, "STATUS built nothing")
        XCTAssertEqual(f.handler.engine.rankTableLevels, 0, "no table")
        XCTAssertTrue(s.contains(" ranks=9 rank_max=8 "), s)
        f.handler.engine.ensureRankTopology()
        XCTAssertEqual(f.handler.handle("STATUS"), s, "the same words once the table is built")
    }

    func testD3FirstUseAllocationsAreRefusedUnderTheirChargeAndKeptInTheLedger() throws {
        let laneBytes: Double = 11.0 * 256.0 + 65_536.0
        let lanes = Int((1.1 * laneBytes).rounded(.up))
        let selBytes: Double = 32.2 * 256.0 + 65_536.0
        let bfsBytes: Double = 56.3 * 256.0 + 65_536.0
        try assertExact({ try HandlerFixture(side: 16) }, "SET 5 MODE TTHRESH", verb: "SET", expect: lanes)
        try assertExact({ try HandlerFixture(side: 16) }, "SET 5 THRESH -0.25 0.25", verb: "SET", expect: lanes)
        try assertExact({ try HandlerFixture(side: 16) }, "SELECT TRUTH 0 RANK 0-0", verb: "SELECT",
                        expect: Int((1.1 * selBytes).rounded(.up)))
        try assertExact({ try HandlerFixture(side: 16) }, "BFS_DEPTHS FROM 0", verb: "BFS_DEPTHS",
                        expect: Int((1.1 * bfsBytes).rounded(.up)))
        let f = try HandlerFixture(side: 16)
        let l0 = f.handler.committedLedgerBytes()
        XCTAssertTrue(f.handler.handle("SET 5 MODE TTHRESH").hasPrefix("OK"))
        XCTAssertLessThanOrEqual(abs(f.handler.committedLedgerBytes() - l0 - lanes), 2)
        // Binary writes allocate nothing and are not charged.
        let g = try HandlerFixture(side: 16)
        budget(g, bytes: g.handler.committedLedgerBytes() + 1)
        XCTAssertTrue(g.handler.handle("SET 5 MODE BINARY").hasPrefix("OK"))
        XCTAssertFalse(g.handler.engine.ternaryLanesAllocated)
    }

    // MARK: - BACKUP RESTORE's charge and SAVE's body

    func testD5BackupRestoreIsRefusedUnderItsChargeWithNothingRestored() throws {
        let root = tmpDir + "bk"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let f = try HandlerFixture(side: 16)
        XCTAssertTrue(f.handler.handle("BACKUP INIT \(root)").hasPrefix("OK"), "init")
        XCTAssertTrue(f.handler.handle("SET 5 TRUTH 1").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("BACKUP APPEND \(root)").hasPrefix("OK"), "append")
        XCTAssertTrue(f.handler.handle("SET 7 TRUTH 1").hasPrefix("OK"))
        let base = try FileManager.default.attributesOfItem(atPath: root + "/base.dags")[.size] as! Int
        let diffs = try FileManager.default.contentsOfDirectory(atPath: root).filter { $0.hasSuffix(".diff") }
            .reduce(0) { $0 + (try FileManager.default.attributesOfItem(atPath: root + "/" + $1)[.size] as! Int) }
        let restore = max(AdmissionCharge.backupRestore(nodes: 256, baseBytes: base, diffBytes: diffs, diffs: 1),
                          Double(AdmissionCharge.loadFamilyFloorBytes))
        let charge = Int((1.1 * restore).rounded(.up))
        budget(f, bytes: f.handler.committedLedgerBytes() + charge - 1)
        let r = f.handler.handle("BACKUP RESTORE \(root)")
        XCTAssertTrue(r.hasPrefix("ERROR out_of_budget: BACKUP RESTORE needs \(charge) bytes (the restore's scratch engine"), r)
        XCTAssertEqual(f.handler.engine.readTruthStates()[7], 1, "nothing restored")
        budget(f, bytes: f.handler.committedLedgerBytes() + charge)
        let ok = f.handler.handle("BACKUP RESTORE \(root)")
        XCTAssertTrue(ok.hasPrefix("OK BACKUP_RESTORE"), ok)
        XCTAssertEqual(f.handler.engine.readTruthStates()[7], 0, "restored to the tip")
    }

    func testD6SavesBodyIsInItsChargePlainAndCompressedApart() throws {
        let plain = AdmissionCharge.saveBody(compressed: false, nodes: 1 << 20, v8: false, backEdges: 0, libraryBytes: 0)
        let comp = AdmissionCharge.saveBody(compressed: true, nodes: 1 << 20, v8: false, backEdges: 0, libraryBytes: 0)
        XCTAssertEqual(comp - plain, 126.0 * Double(1 << 20), accuracy: 1e-6)
        XCTAssertEqual(plain, 8_388_608 + 327_680, accuracy: 1e-6, "the digest's 8 MiB window caps the plain body")
        let f = try HandlerFixture(side: 16)
        let path = tmpDir + "s.dags"
        budget(f, bytes: 1)
        let r = f.handler.handle("SAVE \(path) COMPRESSED")
        XCTAssertTrue(r.contains("the compressed body's gather, deflate and check"), r)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "nothing written")
        try assertExact({ try HandlerFixture(side: 16) }, "SAVE \(path)", verb: "SAVE")
    }

    // MARK: - The name cap

    func testD7TheNameCapIsComputedRefusedLiveAndRoundTripsAtItsLength() throws {
        XCTAssertEqual(TwinState.nameCap, 16_384, "the next power of two at or above 4 x 3,900")
        let walPath = tmpDir + "names.wal"
        let longest = String(repeating: "n", count: TwinState.nameCap)
        do {
            let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 16)
            let f = try HandlerFixture(side: 4, wal: wal)
            let over = f.handler.handle("STREAM OPEN " + longest + "x 0x1 0x2 0x3 0x5")
            XCTAssertEqual(over, "ERROR bad_value: STREAM OPEN: the name is 16385 bytes, above the 16384-byte cap on names stored in twin state; nothing written")
            XCTAssertTrue(f.handler.handle("GEAR OPEN c00000001 " + longest + "x 1/2").hasPrefix("ERROR"), "no such clock, or the cap")
            XCTAssertTrue(f.handler.handle("STREAM OPEN " + longest + " 0x1 0x2 0x3 0x5").hasPrefix("OK"))
            XCTAssertEqual(f.handler.twin.streams.openCount, 1)
            wal.barrier()
        }
        let g = try HandlerFixture(side: 4)
        let rr = try DagDBWAL.replay(engine: g.handler.engine, nodeCount: 16, path: walPath, twin: g.handler.twin)
        XCTAssertEqual(rr.refusals, [])
        XCTAssertEqual(g.handler.twin.streams.entries.values.first?.name.utf8.count, TwinState.nameCap, "L round-trips through replay")
        let save = g.handler.handle("SAVE \(tmpDir!)n.dags")
        XCTAssertTrue(save.hasPrefix("OK SAVE"), save)
        let h = try HandlerFixture(side: 4)
        let load = h.handler.handle("LOAD \(tmpDir!)n.dags")
        XCTAssertTrue(load.hasPrefix("OK LOAD"), load)
        XCTAssertEqual(h.handler.twin.streams.entries.values.first?.name.utf8.count, TwinState.nameCap, "L round-trips through SAVE and LOAD")
    }

    /// A live LOAD refuses it by name, nothing loaded; the startup load loads it and names it.
    func testD7AnOlderOverLongNameIsRefusedByLOADAndLoadedAndNamedAtStartup() throws {
        let src = TwinState()
        try src.apply(.streamOpen(id: "s00000001", name: String(repeating: "q", count: 100_000), stateHi: 1, stateLo: 2, incHi: 3, incLo: 5))
        let e = try DagDBEngine(grid: try HexGrid(width: 4, height: 4), state: DagDBState(width: 4, height: 4), maxRank: 8)
        let path = tmpDir + "old.dags"
        _ = try DagDBSnapshot.save(engine: e, nodeCount: 16, gridW: 4, gridH: 4, tickCount: 0, path: path, twin: src)
        let f = try HandlerFixture(side: 4)
        XCTAssertTrue(f.handler.handle("STREAM OPEN kept 0x1 0x2 0x3 0x5").hasPrefix("OK"))
        let r = f.handler.handle("LOAD \(path)")
        XCTAssertEqual(r, "ERROR io: load: v7 twin section refused: it holds 1 name(s) above the 16384-byte cap on names stored in"
                       + " twin state (stream s00000001: its name of 100000 bytes), names no live verb writes; nothing loaded")
        XCTAssertEqual(f.handler.twin.streams.entries.values.map { $0.name }, ["kept"], "nothing loaded")
        XCTAssertEqual(src.overLongNames(), ["stream s00000001: its name of 100000 bytes"])
        let g = try HandlerFixture(side: 4)
        var lines: [String] = []
        _ = try DagDBStartup.recover(engine: g.handler.engine, nodeCount: 16, width: 4, height: 4, dagdbEnv: nil, dataRoot: nil,
                                     twin: g.handler.twin, truthRankIndex: g.handler.truthRankIndex, snapshotPath: path,
                                     walPath: nil, log: { lines.append($0) })
        XCTAssertEqual(g.handler.twin.streams.entries.values.first?.name.utf8.count, 100_000, "the startup load keeps the era's name")
        XCTAssertTrue(lines.contains { $0.contains("WARN: the recovered twin state holds 1 name(s) above the 16384-byte cap") }, "\(lines)")
    }

    // MARK: - Read verbs, reader sessions, the pool's room and its measurement

    /// Every read verb (and the writers that admitted nothing) refused one byte under its charge, OK at it.
    func testA2ReadVerbsAreRefusedOneByteUnderTheirChargeAndRunAtIt() throws {
        let n = 256
        let cases: [(String, String, Double)] = [
            ("GRAPH INFO", "GRAPH INFO", AdmissionCharge.graphInfo(nodes: n, levels: 1)),
            ("NODES AT RANK 0", "NODES", AdmissionCharge.nodesRead(nodes: n, rows: n)),
            ("TRAVERSE FROM 0 DEPTH 3", "TRAVERSE", AdmissionCharge.traverse(nodes: n, visited: 37)),
            ("ANCESTRY FROM 0 DEPTH 4", "ANCESTRY", AdmissionCharge.ancestry(nodes: n)),
            ("SIMILAR_DECISIONS TO 0 DEPTH 2 K 1 AMONG TRUTH 1", "SIMILAR_DECISIONS", AdmissionCharge.similarDecisions(nodes: n)),
            ("DISTANCE wlL1 0-0 0-0", "DISTANCE", AdmissionCharge.distance(metric: "wlL1", nodes: n, members: 2 * n)),
            ("DISTANCE jaccardNodes 3-3 0-0", "DISTANCE", AdmissionCharge.distance(metric: "jaccardNodes", nodes: n, members: n)),
            ("SAVE JSON \(tmpDir!)a.json", "SAVE JSON", AdmissionCharge.saveJSON(nodes: n)),
            ("SAVE CSV \(tmpDir!)csv", "SAVE CSV", AdmissionCharge.saveCSV(nodes: n)),
        ]
        for (line, verb, bytes) in cases {
            try assertExact({ try HandlerFixture(side: 16) }, line, verb: verb, expect: Int((1.1 * bytes).rounded(.up)))
        }
    }

    /// A reader session's verbs take the primary's charges on the session's engine (SELECT rebuilds its index on
    /// every call, so every call is charged).
    func testA2ReaderSessionVerbsAreCharged() throws {
        let f = try HandlerFixture(side: 16)
        let o = f.handler.handle("OPEN_READER")
        let sid = String(o.split(separator: " ").first { $0.hasPrefix("id=") }!.dropFirst(3))
        let ledger = f.handler.committedLedgerBytes()
        for (inner, bytes) in [("SELECT TRUTH 0 RANK 0-0", AdmissionCharge.truthIndexBuild(nodes: 256)),
                               ("BFS_DEPTHS FROM 0", AdmissionCharge.bfsDepths(nodes: 256)),
                               ("NODES AT RANK 0", AdmissionCharge.nodesRead(nodes: 256, rows: 256))] {
            let need = Int((1.1 * bytes).rounded(.up))
            budget(f, bytes: ledger + need - 1)
            let r = f.handler.handle("READER \(sid) \(inner)")
            XCTAssertTrue(r.hasPrefix("ERROR out_of_budget: READER needs \(need) bytes"), r)
            budget(f, bytes: ledger + need)
            XCTAssertTrue(f.handler.handle("READER \(sid) \(inner)").hasPrefix("OK"), inner)
            XCTAssertTrue(f.handler.handle("READER \(sid) \(inner)").hasPrefix("OK"), "\(inner) again: charged again, admitted again")
        }
    }

    /// A GPU verb's footprint side asks for the pool's room when the pool is not resident.
    func testA2AGPUVerbsFootprintCheckHoldsThePoolsRoom() throws {
        let f = try HandlerFixture(side: 16)
        let room = 129_472_922
        f.handler.memoryBudget = DaemonMemoryBudget(budgetBytes: 200_000_000, source: "--mem-budget-gb", footprint: { 80_000_000 },
                                                    fixedStateBytes: 0, poolReservationBytes: room)
        let r = f.handler.handle("TICK_SYNC 1")
        XCTAssertTrue(r.hasPrefix("ERROR out_of_budget: TICK_SYNC needs ") && r.contains("the Metal pool's room, 129472922 B, not resident now"), r)
        f.handler.memoryBudget = DaemonMemoryBudget(budgetBytes: 300_000_000, source: "--mem-budget-gb", footprint: { 80_000_000 },
                                                    fixedStateBytes: 0, poolReservationBytes: room)
        XCTAssertTrue(f.handler.handle("TICK_SYNC 1").hasPrefix("OK"))
        // Right after a GPU command the pool is resident (in the footprint already): no second room.
        f.handler.memoryBudget = DaemonMemoryBudget(budgetBytes: 200_000_000, source: "--mem-budget-gb", footprint: { 80_000_000 },
                                                    fixedStateBytes: 0, poolReservationBytes: room)
        XCTAssertTrue(f.handler.handle("TICK_SYNC 1").hasPrefix("OK"), "the pool resident, its room is in the footprint")
    }

    /// A GPU verb whose label keeps a second word ("SET_LUTS NODES", "EVAL WHERE") or is typed in lower case is
    /// still the command that made the engine's first command buffer, so the pool is measured across it.
    func testA2ThePoolIsMeasuredAtAnEnginesFirstCommandBufferWhateverTheVerbsSpelling() throws {
        XCTAssertTrue(DagDBCommandHandler.isGPUVerb("SET_LUTS RANK 0-0 FILL 0x1"))
        XCTAssertTrue(DagDBCommandHandler.isGPUVerb("tiled tick x00000001 1"))
        XCTAssertFalse(DagDBCommandHandler.isGPUVerb("TILED STATUS x00000001"))
        XCTAssertFalse(DagDBCommandHandler.isGPUVerb("SET_LUTS_BULK"))
        for line in ["SET_LUTS NODES 0-9 FILL 0x5", "EVAL WHERE truth = 1", "tick 1", "TICK UNTIL_STABLE MAX 2"] {
            let f = try HandlerFixture(side: 16)
            budget(f, bytes: 1 << 34)
            XCTAssertTrue(f.handler.handle("STATUS").hasPrefix("OK STATUS"))
            XCTAssertEqual(f.handler.poolMeasurements, 0, "a CPU verb measures nothing")
            let r = f.handler.handle(line)
            XCTAssertTrue(r.hasPrefix("OK"), "\(line): \(r)")
            XCTAssertGreaterThan(f.handler.engine.gpuCommandBuffersMade, 0, "\(line) made the engine's first command buffer")
            XCTAssertEqual(f.handler.poolMeasurements, 1, "\(line): the pool measured across it")
        }
    }

    // MARK: - A split import's closing record and its replay

    func testD8ASplitImportIsWrittenWithAManifestOnlyCloseAndReplaysHoldingItsFilesOnce() throws {
        let src = try HandlerFixture(side: 16)
        let n = 256
        XCTAssertTrue(src.handler.handle("SET 5 TRUTH 1").hasPrefix("OK"))
        let dir = tmpDir + "exp"
        _ = try DagDBSnapshot.exportMorton(engine: src.handler.engine, nodeCount: n, dir: dir)
        var files: [DagDBSnapshot.MortonFile] = []
        for name in DagDBSnapshot.mortonImportFileNames where FileManager.default.fileExists(atPath: dir + "/" + name) {
            files.append((name, try Data(contentsOf: URL(fileURLWithPath: dir + "/" + name))))
        }
        let total = files.reduce(0) { $0 + $1.data.count }
        let saved = DagDBWAL.importChunkBytes
        defer { DagDBWAL.importChunkBytes = saved }
        DagDBWAL.importChunkBytes = 4096
        let walPath = tmpDir + "split.wal"
        let records: Int
        do {
            let wal = try DagDBWAL.Appender(path: walPath, nodeCount: n)
            records = try wal.importMorton(dir: dir, files: files)
            wal.barrier()
        }
        XCTAssertEqual(records, (total + 4095) / 4096 + 1, "every byte in parts, then the manifest alone")
        var asked: [(Int, String)] = []
        let f = try HandlerFixture(side: 16)
        let r = try DaemonFile.$admission.withValue({ b, what in asked.append((b, what)); return nil }) {
            try DagDBWAL.replay(engine: f.handler.engine, nodeCount: n, path: walPath)
        }
        XCTAssertEqual(r.refusals, [])
        XCTAssertEqual(f.handler.engine.readTruthStates()[5], 1, "the import applied")
        XCTAssertFalse(asked.contains { $0.1.contains("staged") }, "no part is staged (copied)")
        let assembly = asked.filter { $0.1.contains("assembled from the log") }
        XCTAssertEqual(assembly.map { $0.0 }, [total], "the files once, at their size: the live verb's charge")
    }
}
