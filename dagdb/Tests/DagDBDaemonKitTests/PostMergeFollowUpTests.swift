import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// The wire side of `docs/contracts/POST_MERGE_FOLLOWUP_2026-09-12.md` —
/// the edits each of the five branches deferred because they crossed a file
/// another branch owned, gated here on merged main.
final class PostMergeFollowUpTests: XCTestCase {

    // MARK: - F2 · BFS_DEPTHS prints the disclosure the library result carries

    /// C6 decided the walk EXCLUDES back edges and says so. The library
    /// result has said so since the core branch; the daemon reply did not.
    func testBfsDepthsRepliesCarryTheBackEdgeDisclosure() throws {
        let f = try HandlerFixture(side: 4)          // 16 nodes, all -1 slots
        // One back edge, so the count is not the trivial zero.
        XCTAssertTrue(f.handler.handle("SET 5 RANK 1").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("SET 7 RANK 2").hasPrefix("OK"))
        let cb = f.handler.handle("CONNECT BACK FROM 7 TO 5")
        XCTAssertTrue(cb.hasPrefix("OK"), cb)
        XCTAssertEqual(f.handler.engine.backEdgeCount, 1)

        let r = f.handler.handle("BFS_DEPTHS FROM 5")
        XCTAssertTrue(r.hasPrefix("OK BFS_DEPTHS"), r)
        XCTAssertTrue(r.contains(" back_edges=excluded"), r)
        XCTAssertTrue(r.contains(" back_edge_count=1"), r)

        let b = f.handler.handle("BFS_DEPTHS FROM 5 BACKWARD")
        XCTAssertTrue(b.hasPrefix("OK BFS_DEPTHS"), b)
        XCTAssertTrue(b.contains(" back_edges=excluded"), b)
        XCTAssertTrue(b.contains(" back_edge_count=1"), b)

        // The same reply through a reader session.
        let open = f.handler.handle("OPEN_READER")
        XCTAssertTrue(open.hasPrefix("OK OPEN_READER"), open)
        guard let sid = open.split(separator: " ").first(where: { $0.hasPrefix("id=") })
            .map({ String($0.dropFirst("id=".count)) }) else {
            return XCTFail("no session id in: \(open)")
        }
        let rr = f.handler.handle("READER \(sid) BFS_DEPTHS FROM 5")
        XCTAssertTrue(rr.hasPrefix("OK BFS_DEPTHS"), rr)
        XCTAssertTrue(rr.contains(" back_edges=excluded"), rr)
        XCTAssertTrue(rr.contains(" back_edge_count=1"), rr)
    }

    // MARK: - F3 · ALARM SUCCESSOR validates its counts first (beta 51)

    /// The mini fixture holds quiet/liar_B/deep/drift and no `liar_A` or
    /// `liar_C` — labels `SuccessorCourt.classSpecs` declares. Before this
    /// letter the handler called `frameTotals` straight through, which
    /// folded the absent classes into zero and answered `OK`.
    func testAlarmSuccessorRefusesAFixtureMissingAClassCount() throws {
        let dir = NSTemporaryDirectory() + "dagdb-f3-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try Self.writeMiniFixture(in: dir)

        let f = try HandlerFixture(side: 10, dataRoot: dir)
        XCTAssertTrue(f.handler.handle("ALARM LOAD \(path)").hasPrefix("OK ALARM LOAD"), "load")

        // The fixture really is short of two declared labels.
        let set = f.handler.twin.alarms.get("a00000001")!
        XCTAssertNil(set.fixture.classCounts["liar_A"])
        XCTAssertNil(set.fixture.classCounts["liar_C"])

        let reply = f.handler.handle("ALARM SUCCESSOR a00000001 100 0.25 0 0")
        XCTAssertEqual(reply, "ERROR out_of_range: missing class count liar_A", reply)

        // The refusal names the FIRST missing label in declaration order,
        // and the handler is still alive after it.
        XCTAssertTrue(f.handler.handle("STATUS").hasPrefix("OK STATUS"))
    }

    /// ...and a complete counts table answers OK with the disclosure.
    func testAlarmSuccessorDisclosesZeroMissingWhenTheCountsAreComplete() throws {
        let dir = NSTemporaryDirectory() + "dagdb-f3b-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try Self.writeMiniFixture(in: dir, allClasses: true)

        let f = try HandlerFixture(side: 10, dataRoot: dir)
        XCTAssertTrue(f.handler.handle("ALARM LOAD \(path)").hasPrefix("OK ALARM LOAD"), "load")
        let reply = f.handler.handle("ALARM SUCCESSOR a00000001 100 0.25 0 0")
        XCTAssertTrue(reply.hasPrefix("OK ALARM SUCCESSOR"), reply)
        XCTAssertTrue(reply.contains(" missing_class_counts=0"), reply)
    }

    /// The mini alarm fixture, as `TwinAlarmCommandTests` writes it.
    /// `allClasses` adds the liar ears A and C the short one omits.
    static func writeMiniFixture(in dir: String, named name: String = "mini.json",
                                 allClasses: Bool = false) throws -> String {
        func wave(_ base: Float) -> [Float] { [base, base + 1, base + 2, base + 3] }
        func entry(_ cls: String, _ base: Float, ear: String? = nil) -> [String: Any] {
            var e: [String: Any] = [
                "class": cls,
                "a": wave(base), "b": wave(base + 10), "c": wave(base + 20),
            ]
            if let ear = ear { e["liar_ear"] = ear }
            return e
        }
        var obj: [String: Any] = [
            "quiet_1": entry("quiet", 0),
            "quiet_2": entry("quiet", 100),
            "liar_1": entry("liar", 200, ear: "B"),
            "deep_1": entry("deep", 300),
            "drift_1": entry("drift", 400),
            "cal0_1": entry("cal0", 500),
        ]
        if allClasses {
            obj["liar_2"] = entry("liar", 600, ear: "A")
            obj["liar_3"] = entry("liar", 700, ear: "C")
        }
        let data = try JSONSerialization.data(withJSONObject: obj)
        let path = dir + name
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    // MARK: - F4 · HEADER CHECK and RECORD OPEN agree on the clock-sync floor

    /// The seventh t-zero quantity. `StreamRecord`'s birth refuses a declared
    /// floor coarser than the step or reaching the record window; before this
    /// letter `HEADER CHECK` looked only at `violations()` and answered
    /// `admissible=1` for a header `RECORD OPEN` would then refuse.
    ///
    /// `100 1 1000 10 1 0.001 <floor>` is the admissible header of beta's
    /// finding 71 with the floor left free.
    func testHeaderCheckRefusesTheClockSyncFloorsRecordOpenRefuses() throws {
        let f = try HandlerFixture(side: 4)

        // 1 · a floor coarser than the 0.001 s step.
        let coarse = "100 1 1000 10 1 0.001 0.01"
        let hc = f.handler.handle("HEADER CHECK \(coarse)")
        XCTAssertTrue(hc.hasPrefix("FAIL HEADER CHECK violations=1"), hc)
        XCTAssertTrue(hc.contains("floorAboveStep"), hc)
        let ro = f.handler.handle("RECORD OPEN r1 \(coarse) 1 2 3 5")
        XCTAssertTrue(ro.hasPrefix("ERROR"), ro)
        XCTAssertTrue(ro.contains("clock sync floor"), ro)

        // 2 · a floor that also reaches the record window — both violations.
        let huge = "100 1 1000 10 1 0.001 1000000000.0"
        let hc2 = f.handler.handle("HEADER CHECK \(huge)")
        XCTAssertTrue(hc2.hasPrefix("FAIL HEADER CHECK violations=2"), hc2)
        XCTAssertTrue(hc2.contains("floorAboveStep"), hc2)
        XCTAssertTrue(hc2.contains("floorOutlivesRecord"), hc2)
        let ro2 = f.handler.handle("RECORD OPEN r2 \(huge) 1 2 3 5")
        XCTAssertTrue(ro2.hasPrefix("ERROR"), ro2)

        // 3 · the sealed single-clock regime (floor 0) and a legal fine floor
        //     are still admissible through both verbs.
        for floor in ["0", "0.0005"] {
            let ok = "100 1 1000 10 1 0.001 \(floor)"
            let a = f.handler.handle("HEADER CHECK \(ok)")
            XCTAssertTrue(a.hasPrefix("OK HEADER CHECK"), a)
            XCTAssertTrue(a.contains("admissible=1"), a)
            let b = f.handler.handle("RECORD OPEN ok\(floor) \(ok) 1 2 3 5")
            XCTAssertTrue(b.hasPrefix("OK RECORD OPEN"), b)
        }

        // 4 · a body violation and a clock-sync violation count together.
        let both = "100 1 1 10 1 0.001 0.01"   // combBelowNyquist + floorAboveStep
        let hc3 = f.handler.handle("HEADER CHECK \(both)")
        XCTAssertTrue(hc3.hasPrefix("FAIL HEADER CHECK violations=2"), hc3)
        XCTAssertTrue(hc3.contains("combBelowNyquist"), hc3)
        XCTAssertTrue(hc3.contains("floorAboveStep"), hc3)
    }

    // MARK: - F5 · every daemon verb goes through alpha's throwing door

    /// FOLD RUN · finding 36. A node whose rank sits above the requested
    /// `maxRank` would be dropped at the first fold with its row and column
    /// of the operator. `LadderFold.run` reports that as a `refusal` field
    /// plus a stderr line and hands back an empty result, which the handler
    /// printed as `OK FOLD RUN kept=0`. Through `runChecked` it is an
    /// `ERROR` on the wire.
    func testFoldRunRefusesAnObjectAboveItsSchedule() throws {
        // The frozen control object (side 12, ranks 0...6), as
        // `TwinFoldCommandTests` builds it.
        let f = try HandlerFixture(side: 12, shmBytes: 9_604 + 8)
        let nb = f.handler.engine.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: f.grid.neighbors.count)
        for i in 0..<f.grid.neighbors.count { nb[i] = f.grid.neighbors[i] }
        _ = LadderFold.Objects.control(engine: f.handler.engine, grid: f.grid)

        // It folds under its own schedule.
        let ok = f.handler.handle("FOLD RUN 6 3 78 78")
        XCTAssertTrue(ok.hasPrefix("OK FOLD RUN kept=49 folds=3 bytes=9604 wall_ms="), ok)

        // Now one node sits above the schedule. `LadderFold.run` reports
        // that as a `refusal` field plus a stderr line and hands back an
        // empty result, which the handler printed as `OK FOLD RUN kept=0`.
        let rk = f.handler.engine.rankBuf.contents()
            .bindMemory(to: UInt64.self, capacity: f.handler.engine.nodeCount)
        let victim = Int(f.grid.mortonRank[5])
        let original = rk[victim]
        rk[victim] = 9
        f.handler.engine.markRankTopologyDirty()

        let reply = f.handler.handle("FOLD RUN 6 3 78 78")
        XCTAssertTrue(reply.hasPrefix("ERROR bad_value: FOLD RUN refused:"), reply)
        XCTAssertTrue(reply.contains("maxRank 6"), reply)
        XCTAssertTrue(reply.contains("highest rank 9"), reply)
        XCTAssertTrue(reply.contains("1 node(s) sit above the schedule"), reply)
        XCTAssertTrue(f.handler.handle("STATUS").hasPrefix("OK STATUS"))

        // The refused fold left no empty result behind: FOLD KEPT still
        // reads the good one.
        XCTAssertTrue(f.handler.handle("FOLD KEPT").hasPrefix("OK FOLD KEPT kept=49"))

        // Put the rank back and the same command folds again.
        rk[victim] = original
        f.handler.engine.markRankTopologyDirty()
        XCTAssertTrue(f.handler.handle("FOLD RUN 6 3 78 78").hasPrefix("OK FOLD RUN kept=49"))
    }

    /// BANK GENERATE · finding 35. A column count above the bank's own
    /// ceiling produced an empty vector — indistinguishable from an empty
    /// request — under an `OK` line. `generateChecked` names it.
    func testBankGenerateRefusesAColumnCountAboveTheCeiling() throws {
        // A two-sample, two-atom bank, and a mapping wide enough that the
        // capacity guards are not what refuses: 8 + 2 x 100001 x 4 bytes.
        let f = try HandlerFixture(side: 4, shmBytes: 900_000)
        let open = f.handler.handle("BANK OPEN tiny 2 1000 10 1 0 0 0.02")
        XCTAssertTrue(open.hasPrefix("OK BANK OPEN"), open)

        let over = WaveBank.maxGenerateColumns + 1        // 100_001
        let reply = f.handler.handle("BANK GENERATE w00000001 \(over)")
        XCTAssertTrue(reply.hasPrefix("ERROR"), reply)
        XCTAssertTrue(reply.contains("\(over)"), reply)
        XCTAssertTrue(reply.contains("\(WaveBank.maxGenerateColumns)"), reply)
        XCTAssertTrue(f.handler.handle("STATUS").hasPrefix("OK STATUS"))

        // One column still generates.
        XCTAssertTrue(f.handler.handle("BANK GENERATE w00000001 1").hasPrefix("OK BANK GENERATE"))
    }

    /// BANK OPEN / BANK INFO · finding 33. `declarationChecked` is the door;
    /// its extra clause (a smallest singular value at or below the rank
    /// threshold) is DISCLOSED rather than refused, because the sealed
    /// 160-atom control bank is deliberately rank deficient (146 of 160) and
    /// its printed `rank=146` is a frozen gate of its own.
    func testBankDeclarationIsCheckedAndTheRankDeficiencyDisclosed() throws {
        let f = try HandlerFixture(side: 64)
        // The repaired default bank: full rank, nothing disclosed.
        let open = f.handler.handle("BANK OPEN mouth")
        XCTAssertTrue(open.hasPrefix("OK BANK OPEN id=w00000001 name=mouth T=4096 K=144"), open)
        XCTAssertTrue(open.contains(" rank=144 "), open)
        XCTAssertTrue(open.contains(" rank_deficient=0"), open)
        XCTAssertTrue(f.handler.handle("BANK INFO w00000001").contains(" rank_deficient=0"))

        // The sealed control bank: still OK, still rank=146, now disclosed.
        let f2 = try HandlerFixture(side: 64)
        let ctl = f2.handler.handle("BANK OPEN mouth 4096 3000 60 32 8 6 0.02 ALIASED")
        XCTAssertTrue(ctl.hasPrefix("OK BANK OPEN id=w00000001 name=mouth T=4096 K=160"), ctl)
        XCTAssertTrue(ctl.contains(" rank=146 "), ctl)
        XCTAssertTrue(ctl.contains(" rank_deficient=1"), ctl)
        XCTAssertTrue(f2.handler.handle("BANK INFO w00000001").contains(" rank_deficient=1"))
        // And the library door really does refuse it, which is why the
        // handler cannot simply pass the throw through.
        XCTAssertThrowsError(try WaveBank(spec: .reference).declarationChecked())
    }

    /// KERNEL LOAD · finding 28. Named here for completeness, and honest
    /// about where the refusal comes from: alpha's `KernelPair.load` ALREADY
    /// calls `checkedWarmup` and throws, so this verb refused a declared
    /// warmup at or above the kernels file's own `window_samples` before F5
    /// as well, as `ERROR io: bad layout: …`. F5's change here is ordering,
    /// not a new refusal — the daemon resolves the warmup through the
    /// throwing door BEFORE the id is minted and before the op reaches the
    /// WAL, so no path that reaches this handler can install a kernel whose
    /// warmup leaves no comparison window. The handler's own refusal wording
    /// (`ERROR bad_value: KERNEL LOAD refused: …`) is therefore unreachable
    /// today and is defence in depth; `XCONV SEALED` below is the override
    /// path that F5 actually closes.
    func testKernelLoadRefusesADeclaredWarmupThatLeavesNoWindow() throws {
        let f = try HandlerFixture(side: 64, dataRoot: Self.kernelsDir)
        let reply = f.handler.handle("KERNEL LOAD \(Self.kernelsPath) WARMUP 2048")
        XCTAssertEqual(reply,
            "ERROR io: bad layout: warmup 2048 leaves no comparison window "
            + "against window_samples 2048 (taps 2048)", reply)
        // Refused before the id is minted: nothing was installed.
        XCTAssertNil(f.handler.twin.kernels.get("k00000001"))
        XCTAssertTrue(f.handler.handle("STATUS").hasPrefix("OK STATUS"))

        // A warmup inside the window still loads.
        let ok = f.handler.handle("KERNEL LOAD \(Self.kernelsPath) WARMUP 185")
        XCTAssertTrue(ok.hasPrefix("OK KERNEL LOAD"), ok)
        XCTAssertTrue(ok.contains("warmup=185 derived=0"), ok)
    }

    /// XCONV SEALED · the same door on the override path.
    func testXconvSealedRefusesAWarmupOverrideThatLeavesNoWindow() throws {
        let f = try HandlerFixture(side: 64, dataRoot: Self.kernelsDir)
        XCTAssertTrue(f.handler.handle("KERNEL LOAD \(Self.kernelsPath)").hasPrefix("OK KERNEL LOAD"))
        let reply = f.handler.handle("XCONV SEALED k00000001 4096 2048")
        XCTAssertTrue(reply.hasPrefix("ERROR"), reply)
        XCTAssertTrue(reply.contains("window_samples 2048"), reply)
        XCTAssertTrue(f.handler.handle("STATUS").hasPrefix("OK STATUS"))
    }

    /// VIEW · finding 41. Fixture-gated: the sealed cortex npz lives outside
    /// the repo, so this skips when `DAGDB_CORTEX_V4_FIXTURE` is unset.
    func testViewVerbsRefuseStationsThroughCheckStations() throws {
        guard let path = CortexFixture.envPath else {
            throw XCTSkip("DAGDB_CORTEX_V4_FIXTURE not set — sealed gate skipped")
        }
        let root = (path as NSString).deletingLastPathComponent
        let f = try HandlerFixture(side: 10, dataRoot: root)
        XCTAssertTrue(f.handler.handle("VIEW LOAD \(path) SHA \(CortexFixture.sealedSHA256)")
            .hasPrefix("OK VIEW LOAD"))
        for verb in ["VIEW REFLEX v00000001 9", "VIEW RUNG v00000001 9",
                     "VIEW CEILING v00000001 9", "VIEW FEATURES v00000001 0 9"] {
            let reply = f.handler.handle(verb)
            XCTAssertTrue(reply.hasPrefix("ERROR out_of_range"), reply)
            XCTAssertTrue(reply.contains("station count 8"), "\(verb): \(reply)")
        }
    }

    /// The in-repo kernels fixture, as `TwinKernelCommandTests` locates it.
    static var kernelsDir: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures").path
    }
    static var kernelsPath: String { kernelsDir + "/w1_kernels.json" }

    // MARK: - F6 · the daemon verifier's live scenario, on merged main

    /// D6's closing gate, re-driven here. `SET_NEIGHBORS_BULK` installs the
    /// exact edge `CONNECT` refuses by name — a combinational input into a
    /// BACK_EDGE destination (a register) — and its reply points the caller
    /// at `VALIDATE`. On the daemon branch alone `VALIDATE` had no register
    /// check (that clause is the core branch's C3) and answered `OK`, so the
    /// reply directed the caller at a re-check that could not fire. The core
    /// merge is what closes it; this is the gate that says so.
    func testBulkInstalledRegisterFanInIsCaughtByValidate() throws {
        let f = try HandlerFixture(side: 4)               // 16 nodes
        let n = f.handler.nodeCount

        XCTAssertTrue(f.handler.handle("SET 5 RANK 1").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("SET 7 RANK 2").hasPrefix("OK"))

        // Node 5 becomes a register.
        XCTAssertTrue(f.handler.handle("CONNECT BACK FROM 3 TO 5").hasPrefix("OK CONNECT BACK"))

        // CONNECT refuses a combinational input into it, by name.
        let refused = f.handler.handle("CONNECT FROM 7 TO 5")
        XCTAssertTrue(refused.hasPrefix("ERROR schema: back_edge_violation"), refused)
        XCTAssertTrue(refused.contains("node 5 is a BACK_EDGE destination"), refused)

        // Before the bypass the graph is clean.
        XCTAssertTrue(f.handler.handle("VALIDATE").hasPrefix("OK VALIDATE"))

        // The bypass: slot 5*6+0 := 7 through the bulk installer.
        let slots = n * 6
        let src = f.shm.advanced(by: 8).bindMemory(to: Int32.self, capacity: slots)
        let live = f.handler.engine.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: slots)
        for i in 0..<slots { src[i] = live[i] }
        src[5 * 6 + 0] = 7

        let bulk = f.handler.handle("SET_NEIGHBORS_BULK")
        XCTAssertTrue(bulk.hasPrefix("OK SET_NEIGHBORS_BULK nodes=\(n)"), bulk)
        XCTAssertTrue(bulk.contains("validation=skipped"), bulk)
        XCTAssertTrue(bulk.contains("skipped=back_edge_register_fanin"), bulk)
        XCTAssertTrue(bulk.contains("recheck=VALIDATE"), bulk)

        // The edge really is installed.
        XCTAssertEqual(live[5 * 6 + 0], 7)

        // And the re-check the reply names actually fires.
        let v = f.handler.handle("VALIDATE")
        XCTAssertTrue(v.hasPrefix("FAIL VALIDATE"), "on merged main VALIDATE must catch the bypass: \(v)")
        XCTAssertTrue(v.contains("5"), v)
        XCTAssertTrue(v.lowercased().contains("register"), v)
        XCTAssertTrue(f.handler.handle("STATUS").hasPrefix("OK STATUS"))
    }
}
