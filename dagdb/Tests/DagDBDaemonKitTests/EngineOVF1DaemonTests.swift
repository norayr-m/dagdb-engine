import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// No wire number kills the daemon.
/// Each test sends a site's failing value through the handler, as the wire
/// does, and asserts the named refusal, nothing written (the result shm byte
/// for byte, the open registries). On the build before the fix every one of
/// these lines trapped (the daemon-level red runs were done live); the
/// in-process tests are the green half and the regression guard.
final class EngineOVF1DaemonTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-ovf1-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    private func shmBytes(_ f: HandlerFixture) -> Data { Data(bytes: f.shm, count: f.shmBytes) }

    /// The line is refused with `expected`, and the shm is byte-equal after it.
    private func assertRefused(_ f: HandlerFixture, _ line: String, _ expected: String,
                               file: StaticString = #filePath, line l: UInt = #line) {
        let before = shmBytes(f)
        XCTAssertEqual(f.handler.handle(line), expected, file: file, line: l)
        XCTAssertEqual(shmBytes(f), before, "\(line) wrote shm", file: file, line: l)
    }

    // MARK: - NODES AT RANK r with r < 0

    func testNodesAtNegativeRankIsRefusedBeforeTheLoop() throws {
        let f = try HandlerFixture(side: 4)
        XCTAssertTrue(f.handler.handle("SET 0 TRUTH 1").hasPrefix("OK"))
        for r in ["-1", "-9223372036854775808"] {
            assertRefused(f, "NODES AT RANK \(r)",
                          "ERROR bad_value: NODES AT RANK \(r): a rank is never negative; nothing written")
            assertRefused(f, "NODES AT RANK \(r) WHERE truth=1",
                          "ERROR bad_value: NODES AT RANK \(r): a rank is never negative; nothing written")
        }
        // r >= 0 is answered as before.
        XCTAssertEqual(f.handler.handle("NODES AT RANK 0"), "OK NODES rows=16 omitted=0")
    }

    func testReaderNodesAtNegativeRankIsRefused() throws {
        let f = try HandlerFixture(side: 4)
        let open = f.handler.handle("OPEN_READER")
        guard let id = open.split(separator: " ").first(where: { $0.hasPrefix("id=") })?.dropFirst(3) else {
            return XCTFail(open)
        }
        assertRefused(f, "READER \(id) NODES AT RANK -1",
                      "ERROR bad_value: NODES AT RANK -1: a rank is never negative; nothing written")
        XCTAssertTrue(f.handler.handle("READER \(id) NODES AT RANK 0").hasPrefix("OK NODES session="))
    }

    // MARK: - NODES WHERE rank over a stored rank above Int.max

    func testNodesWhereRankRefusesARankAboveIntMax() throws {
        let f = try HandlerFixture(side: 4)
        // A rank no live writer installs (they keep rank < nodeCount); a crafted
        // log or snapshot could, before replay checked ranks.
        let rk = f.handler.engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: 16)
        rk[5] = UInt64(Int.max) + 1
        f.handler.engine.markRankTopologyDirty()
        let refusal = "ERROR out_of_range: NODES WHERE rank: node 5 rank 9223372036854775808 exceeds Int.max"
            + " 9223372036854775807; nothing written"
        assertRefused(f, "NODES WHERE rank>=0", refusal)
        assertRefused(f, "NODES WHERE rank=0", refusal)
        // A predicate that does not read the rank, and AT RANK (which never matches it), still answer.
        XCTAssertTrue(f.handler.handle("NODES WHERE truth=0").hasPrefix("OK NODES rows="))
        XCTAssertTrue(f.handler.handle("NODES AT RANK 0 WHERE rank=0").hasPrefix("OK NODES rows=15"))
        // Int.max itself fits.
        rk[5] = UInt64(Int.max)
        XCTAssertTrue(f.handler.handle("NODES WHERE rank>=1").hasPrefix("OK NODES rows=1 "))
    }

    // MARK: - BANK OPEN's atom count

    func testBankOpenAtomCountOverflowIsRefusedByName() throws {
        let f = try HandlerFixture(side: 4)
        assertRefused(f, "BANK OPEN x 4096 3000 60 4611686018427387904 0 0 0.02",
                      "ERROR out_of_range: BANK OPEN atomCount 2*4611686018427387904 + 2*0*0 overflows Int"
                        + " (must be <= 4096); nothing written")
        assertRefused(f, "BANK OPEN x 4096 3000 60 1 4294967296 4294967296 0.02",
                      "ERROR out_of_range: BANK OPEN atomCount 2*1 + 2*4294967296*4294967296 overflows Int"
                        + " (must be <= 4096); nothing written")
        XCTAssertEqual(f.handler.twin.banks.openCount, 0)
        // A refusal that is not the overflow keeps its old words.
        XCTAssertEqual(f.handler.handle("BANK OPEN x 64 3000 60 40 1 1 0.02"),
                       "ERROR bad_value: atomCount must be <= samples")
        // The validator itself, and the spec's checked count.
        let huge = WaveBank.Spec(samples: 64, sampleRate: 3000, f0: 60, harmonics: Int.max,
                                 gaborCenters: 0, gaborFreqs: 0, gaborSigmaFrac: 0.02)
        XCTAssertNil(huge.checkedAtomCount)
        XCTAssertEqual(WaveBank.validationError(huge), WaveBank.atomCountOverflow(huge))
        XCTAssertEqual(WaveBank.Spec.referenceNyquistSafe.checkedAtomCount, 144)
    }

    /// The checked count keeps the plain expression's order, `(2·c)·f`: with
    /// gaborFreqs 0 a centre count whose double overflows is still refused, so
    /// no spec that validates can trap in the plain `atomCount` afterwards
    /// (WaveBank.init, buildAtoms, the reply). With the WAL off nothing else
    /// stood between such a spec and those reads (the WAL's u32 field refuses
    /// it first when the WAL is on).
    func testBankOpenAtomCountKeepsTheExpressionsOrder() throws {
        let f = try HandlerFixture(side: 4)     // no WAL
        for (c, fr) in [("4611686018427387904", "0"), ("9223372036854775807", "0")] {
            assertRefused(f, "BANK OPEN x 64 3000 60 2 \(c) \(fr) 0.02",
                          "ERROR out_of_range: BANK OPEN atomCount 2*2 + 2*\(c)*\(fr) overflows Int"
                            + " (must be <= 4096); nothing written")
        }
        XCTAssertEqual(f.handler.twin.banks.openCount, 0)
        // A count that fits, with no Gabor atoms, opens as before.
        XCTAssertTrue(f.handler.handle("BANK OPEN x 64 3000 60 2 4611686018427387903 0 0.02")
            .hasPrefix("OK BANK OPEN id=w00000001 name=\"x\" T=64 K=4 "))
    }

    func testBankOpenRecordThatFailsValidationDecodesToNilAndIsNamed() throws {
        func f64(_ v: Double) -> [UInt8] { withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) } }
        func u32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        var p = Data([0x09, 0x00]); p.append(contentsOf: Array("w00000001".utf8))
        p.append(contentsOf: [0x01, 0x00]); p.append(contentsOf: Array("x".utf8))
        p.append(contentsOf: withUnsafeBytes(of: UInt64(4096).littleEndian) { Array($0) })
        p.append(contentsOf: f64(3000)); p.append(contentsOf: f64(60))
        p.append(contentsOf: u32(.max)); p.append(contentsOf: u32(.max)); p.append(contentsOf: u32(.max))
        p.append(contentsOf: f64(0.02))
        // 2·(2^32−1)·(2^32−1) overflows Int: decode trapped inside the validator.
        XCTAssertNil(TwinWALCodec.decode(opcode: DagDBWAL.Opcode.twinBankOpen.rawValue, payload: p))
        let r = try XCTUnwrap(TwinWALCodec.bankOpenRefusal(payload: p))
        XCTAssertEqual(r.id, "w00000001")
        XCTAssertEqual(r.why, "atomCount 2*4294967295 + 2*4294967295*4294967295 overflows Int (must be <= 4096)")
        // A payload that does not parse is not named (it stays a bad length).
        XCTAssertNil(TwinWALCodec.bankOpenRefusal(payload: p.dropLast()))
    }

    // MARK: - BUDGET OPEN's pocket cap before the table build

    func testBudgetOpenPocketCapRunsBeforeTheTableBuild() throws {
        let f = try HandlerFixture(side: 4)
        for p in ["4611686018427387904", "9223372036854775807", "21"] {
            shm1Header(f.shm, count: 0, verb: .budgetOpen)
            assertRefused(f, "BUDGET OPEN \(p) 0 0",
                          "ERROR out_of_range: BUDGET OPEN pockets \(p) not in 0...20; nothing written")
        }
        XCTAssertEqual(f.handler.twin.layouts.openCount, 0)
        shm1Header(f.shm, count: 0, verb: .budgetOpen)
        XCTAssertTrue(f.handler.handle("BUDGET OPEN 20 0 0").hasPrefix("OK BUDGET OPEN id=b00000001 pockets=20"))
    }

    // MARK: - BANK GENERATE's byte counts

    func testBankGenerateByteCountOverflowIsRefusedByName() throws {
        let f = try HandlerFixture(side: 8)
        XCTAssertTrue(f.handler.handle("BANK OPEN b 64 3000 60 2 1 1 0.02").hasPrefix("OK BANK OPEN id=w00000001"))
        shm1Header(f.shm, count: 0, verb: .bankGenerate)
        assertRefused(f, "BANK GENERATE w00000001 4611686018427387904",
                      "ERROR out_of_range: BANK GENERATE M 4611686018427387904: input bytes 8 + K*M*4 (K=6)"
                        + " overflow Int; nothing written")
        assertRefused(f, "BANK GENERATE w00000001 9223372036854775807",
                      "ERROR out_of_range: BANK GENERATE M 9223372036854775807: input bytes 8 + K*M*4 (K=6)"
                        + " overflow Int; nothing written")
        // In range and too big for the shm: the capacity refusal, as before.
        XCTAssertTrue(f.handler.handle("BANK GENERATE w00000001 1000000")
            .hasPrefix("ERROR out_of_range: BANK GENERATE input 24000008 bytes exceeds shm capacity"))
    }

    // MARK: - TILED BFS's u32 depth

    func testTiledBfsDepthPastU32IsRefusedByName() throws {
        let root = tmpDir!
        let f = try HandlerFixture(side: 8, dataRoot: root, maxRank: 64)
        XCTAssertTrue(f.handler.handle("SAVE TILED \(root)tz 32").hasPrefix("OK SAVE TILED"))
        XCTAssertTrue(f.handler.handle("TILED OPEN \(root)tz").hasPrefix("OK TILED OPEN id=x00000001"))
        for d in ["4294967296", "9223372036854775807"] {
            assertRefused(f, "TILED BFS x00000001 0 \(d)",
                          "ERROR out_of_range: TILED BFS depth \(d) not in 0...4294967295; nothing written")
        }
        // In u32, the router answers (its own maxDepth refusal, or the walk).
        XCTAssertFalse(f.handler.handle("TILED BFS x00000001 0 4294967295").contains("not in 0...4294967295"))
    }

    // MARK: - HOOK OPEN's frame count; HOOK LEDGER's narrowed fields

    @discardableResult
    private func loadMiniAlarm(_ f: HandlerFixture) throws -> String {
        func wave(_ base: Float) -> [Float] { [base, base + 1, base + 2, base + 3] }
        func entry(_ cls: String, _ base: Float, ear: String? = nil) -> [String: Any] {
            var e: [String: Any] = ["class": cls, "a": wave(base), "b": wave(base + 10), "c": wave(base + 20)]
            if let ear = ear { e["liar_ear"] = ear }
            return e
        }
        let obj: [String: Any] = [
            "quiet_1": entry("quiet", 0), "quiet_2": entry("quiet", 100), "liar_1": entry("liar", 200, ear: "B"),
            "deep_1": entry("deep", 300), "drift_1": entry("drift", 400), "cal0_1": entry("cal0", 500),
        ]
        let path = tmpDir + "mini.json"
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: path))
        let reply = f.handler.handle("ALARM LOAD \(path)")
        XCTAssertTrue(reply.hasPrefix("OK ALARM LOAD id=a00000001"), reply)
        return reply
    }

    func testHookOpenFrameCountOverflowIsRefusedBeforeAnIdIsMinted() throws {
        let f = try HandlerFixture(side: 4)     // no WAL: nothing refused the delta before this fix
        try loadMiniAlarm(f)
        let records = try XCTUnwrap(f.handler.twin.alarms.get("a00000001")).fixture.records.count
        assertRefused(f, "HOOK OPEN a00000001 SEALED 100000 DELTA 9223372036854775807",
                      "ERROR out_of_range: HOOK OPEN delta 9223372036854775807: frames \(records) + delta"
                        + " overflow Int; nothing written")
        XCTAssertEqual(f.handler.twin.hooks.openCount, 0)
        // The next id is the first: nothing was minted.
        XCTAssertTrue(f.handler.handle("HOOK OPEN a00000001 SEALED 100000").hasPrefix("OK HOOK OPEN id=h00000001"))
        // The engine object throws instead of trapping (a snapshot's delta reaches it directly).
        let params = AttentionHook.Params(alarmId: "a00000001", layoutId: nil, budget: 1e5, delta: Int.max,
                                          policy: .allocator)
        let recs = try XCTUnwrap(f.handler.twin.alarms.get("a00000001")).fixture.records
        XCTAssertThrowsError(try AttentionHook(params: params, records: recs, layout: SealedCourt.makeLayout())) { e in
            XCTAssertEqual(e as? AttentionHook.FrameCountError, .overflow(records: recs.count, delta: Int.max))
        }
    }

    func testHookLedgerChecksEveryRowBeforeWriting() throws {
        let f = try HandlerFixture(side: 8)
        try loadMiniAlarm(f)
        // delta 3e9 fits the WAL's u32 field; src = t - delta is below Int32.min.
        XCTAssertTrue(f.handler.handle("HOOK OPEN a00000001 SEALED 100000 DELTA 3000000000")
            .hasPrefix("OK HOOK OPEN id=h00000001"))
        XCTAssertTrue(f.handler.handle("HOOK STEP h00000001 2").hasPrefix("OK HOOK STEP id=h00000001 t=2"))
        let refusal = "ERROR out_of_range: HOOK LEDGER row 0 src -2999999999 not in -2147483648...2147483647;"
            + " nothing written"
        assertRefused(f, "HOOK LEDGER h00000001", refusal)
        assertRefused(f, "HOOK LEDGER h00000001 0 2", refusal)
        assertRefused(f, "HOOK LEDGER h00000001 1 1",
                      "ERROR out_of_range: HOOK LEDGER row 1 src -2999999998 not in -2147483648...2147483647;"
                        + " nothing written")
        // An empty range writes the header only, as before.
        XCTAssertEqual(f.handler.handle("HOOK LEDGER h00000001 0 0"), "OK HOOK LEDGER id=h00000001 from=0 count=0 of=2")
    }

    func testHookLedgerPackNamesEachNarrowedField() {
        func row(t: Int, src: Int, tier: Int?, pocket: Int?) -> AttentionHook.Row {
            AttentionHook.Row(t: t, src: src, judged: false, outcome: .none, rawClass: nil, ear: nil,
                              pocket: pocket, tierBought: tier, spend: 0, countsTowardCost: false, cumulativeCost: 0)
        }
        let f = try? HandlerFixture(side: 4)
        guard let h = f?.handler else { return XCTFail("fixture") }
        func refusedField(_ r: AttentionHook.Row) -> String? {
            if case .refused(let what, _, _) = h.packHookLedgerRow(r) { return what }
            return nil
        }
        XCTAssertEqual(refusedField(row(t: Int(UInt32.max) + 1, src: 0, tier: nil, pocket: nil)), "t")
        XCTAssertEqual(refusedField(row(t: 1, src: Int(Int32.min) - 1, tier: nil, pocket: nil)), "src")
        XCTAssertEqual(refusedField(row(t: 1, src: 0, tier: 128, pocket: nil)), "tier")
        XCTAssertEqual(refusedField(row(t: 1, src: 0, tier: 1, pocket: 200)), "pocket")
        XCTAssertNil(refusedField(row(t: Int(UInt32.max), src: Int(Int32.min), tier: 127, pocket: -1)))
    }

    // MARK: - The shm read helpers

    func testShmReadHelpersReportOverflowAsNil() throws {
        let f = try HandlerFixture(side: 4)
        XCTAssertFalse(f.handler.shmReadFits(count: Int.max / 2, elementSize: 4, at: 8))
        XCTAssertFalse(f.handler.shmReadFits(count: 1, elementSize: 4, at: Int.max))
        XCTAssertFalse(f.handler.shmReadFits(count: -1, elementSize: 4, at: 8))
        XCTAssertTrue(f.handler.shmReadFits(count: (f.shmBytes - 8) / 8, elementSize: 8, at: 8))
        XCTAssertNil(f.handler.readFloats(count: Int.max / 2, at: 8))
        XCTAssertNil(f.handler.readDoubles(count: Int.max / 4, at: 8))
        XCTAssertNotNil(f.handler.readFloats(count: 2, at: 8))
    }

    // MARK: - The log-borne half · replay refuses a rank that does not fit Int

    private func walWithRawRecord(_ path: String, nodeCount: Int, opcode: UInt8, payload: Data,
                                  before: (DagDBWAL.Appender) throws -> Void = { _ in }) throws {
        let a = try DagDBWAL.Appender(path: path, nodeCount: nodeCount)
        try before(a)
        var rec = Data()
        rec.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).littleEndian) { Array($0) })
        rec.append(opcode)
        rec.append(payload)
        let h = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        h.seekToEndOfFile()
        h.write(rec)
        h.closeFile()
    }

    func testReplayRefusesASetRankAboveIntMaxByName() throws {
        let path = tmpDir + "ovf1_setrank.wal"
        let a = try DagDBWAL.Appender(path: path, nodeCount: 16)
        _ = try a.setRank(node: 3, value: 60_129_542_149)            // above nodeCount, fits Int: replays
        _ = try a.setRank(node: 4, value: UInt64(Int.max) + 1)       // does not fit Int: refused
        _ = try a.setRank(node: 5, value: UInt64.max)
        let f = try HandlerFixture(side: 4)
        let r = try DagDBWAL.replay(engine: f.handler.engine, nodeCount: 16, path: path)
        XCTAssertEqual(r.recordsApplied, 1)
        XCTAssertEqual(r.refusals.count, 2)
        XCTAssertTrue(r.refusals[0].hasSuffix(
            "node 4: SET_RANK 9223372036854775808 does not fit Int (above 9223372036854775807); not applied"),
            r.refusals[0])
        XCTAssertTrue(r.refusals[1].contains("opcode 0x02: node 5: SET_RANK 18446744073709551615"), r.refusals[1])
        let rk = f.handler.engine.readRanks()
        XCTAssertEqual(rk[3], 60_129_542_149)
        XCTAssertEqual(rk[4], 0)
        XCTAssertEqual(rk[5], 0)
        XCTAssertTrue(f.handler.handle("NODES WHERE rank>=1").hasPrefix("OK NODES rows=1 "))
    }

    func testReplayRefusesASetRanksBulkWithOneRankAboveIntMaxWhole() throws {
        let path = tmpDir + "ovf1_ranksbulk.wal"
        let a = try DagDBWAL.Appender(path: path, nodeCount: 16)
        var ranks = [UInt64](repeating: 1, count: 16)
        ranks[9] = UInt64(Int.max) + 5
        _ = try ranks.withUnsafeBufferPointer { try a.setRanksBulk($0.baseAddress!, count: 16) }
        let f = try HandlerFixture(side: 4)
        let r = try DagDBWAL.replay(engine: f.handler.engine, nodeCount: 16, path: path)
        XCTAssertEqual(r.recordsApplied, 0)
        XCTAssertEqual(r.refusals.count, 1)
        XCTAssertTrue(r.refusals[0].hasSuffix("SET_RANKS_BULK of 16: node 9 rank 9223372036854775812 does not fit Int"
                                              + " (above 9223372036854775807); nothing applied"), r.refusals[0])
        XCTAssertEqual(f.handler.engine.readRanks(), [UInt64](repeating: 0, count: 16), "nothing applied")
    }

    func testReplayRefusesABankOpenRecordThatFailsValidationByName() throws {
        func f64(_ v: Double) -> [UInt8] { withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) } }
        func u32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        var p = Data([0x09, 0x00]); p.append(contentsOf: Array("w00000001".utf8))
        p.append(contentsOf: [0x01, 0x00]); p.append(contentsOf: Array("x".utf8))
        p.append(contentsOf: withUnsafeBytes(of: UInt64(4096).littleEndian) { Array($0) })
        p.append(contentsOf: f64(3000)); p.append(contentsOf: f64(60))
        p.append(contentsOf: u32(.max)); p.append(contentsOf: u32(.max)); p.append(contentsOf: u32(.max))
        p.append(contentsOf: f64(0.02))
        let path = tmpDir + "ovf1_bankopen.wal"
        try walWithRawRecord(path, nodeCount: 16, opcode: DagDBWAL.Opcode.twinBankOpen.rawValue, payload: p)
        let f = try HandlerFixture(side: 4)
        let twin = TwinState()
        let r = try DagDBWAL.replay(engine: f.handler.engine, nodeCount: 16, path: path, twin: twin)
        XCTAssertEqual(r.recordsApplied, 0)
        XCTAssertEqual(r.refusals.count, 1)
        XCTAssertTrue(r.refusals[0].hasSuffix("opcode 0x2c: BANK OPEN w00000001: atomCount 2*4294967295"
                                              + " + 2*4294967295*4294967295 overflows Int (must be <= 4096);"
                                              + " not applied"), r.refusals[0])
        XCTAssertEqual(twin.banks.openCount, 0)
    }
}
