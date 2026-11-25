import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// The memory budget's formula, the STATUS token, and the refusal texts at
/// every admission site, in process. The red cases on a sandbox daemon and the
/// corpus run over the wire.
final class EngineALLOC1aTests: XCTestCase {
    let gib = 1 << 30

    // MARK: - The default formula, from the fixed state (191.0 B/node + 2.55 MB)

    func testA1_3DefaultBudgetFormula() {
        // Three node counts, plus one past the 32 GiB clamp.
        XCTAssertEqual(DaemonMemoryBudget.fixedStateBytes(nodeCount: 65_536), 15_067_376)
        XCTAssertEqual(DaemonMemoryBudget.defaultBudgetBytes(nodeCount: 65_536), 8 * gib)
        XCTAssertEqual(DaemonMemoryBudget.fixedStateBytes(nodeCount: 2_097_152), 403_106_032)
        XCTAssertEqual(DaemonMemoryBudget.defaultBudgetBytes(nodeCount: 2_097_152), 8 * gib)
        XCTAssertEqual(DaemonMemoryBudget.fixedStateBytes(nodeCount: 57_046_881), 10_898_504_271)
        XCTAssertEqual(DaemonMemoryBudget.defaultBudgetBytes(nodeCount: 57_046_881), 21_797_008_542)
        XCTAssertEqual(DaemonMemoryBudget.make(nodeCount: 57_046_881, overrideGiB: nil).gibText, "20.300")
        XCTAssertEqual(DaemonMemoryBudget.defaultBudgetBytes(nodeCount: 100_000_000), 32 * gib)
        // --mem-budget-gb overrides, in GiB.
        let b = DaemonMemoryBudget.make(nodeCount: 57_046_881, overrideGiB: 2.5)
        XCTAssertEqual(b.budgetBytes, 2_684_354_560)
        XCTAssertEqual(b.source, "--mem-budget-gb")
        XCTAssertEqual(b.gibText, "2.500")
        // The process's own footprint is readable (the daemon's input to admission).
        XCTAssertGreaterThan(DaemonMemoryBudget.physFootprint(), 0)
    }

    func testAdmitCountSaturates() {
        let big = AdmitCount(Int.max)
        XCTAssertTrue((big * AdmitCount(2)).overflow)
        XCTAssertEqual((big * AdmitCount(2)).description, "more than \(Int.max)")
        XCTAssertFalse((AdmitCount.more * AdmitCount(0)).overflow)
        XCTAssertEqual((AdmitCount.more * AdmitCount(0)).value, 0)
        XCTAssertTrue(AdmitCount(5) < AdmitCount.more)
        XCTAssertTrue((AdmitCount(Int.max) + AdmitCount(1)).overflow)
    }

    // MARK: - STATUS carries the budget when it is set explicitly, its prefix byte-equal

    func testA1_3StatusToken() throws {
        let f = try HandlerFixture(side: 4)
        let before = f.handler.handle("STATUS")
        let rid = try openReader(f)
        let rBefore = f.handler.handle("READER \(rid) STATUS")
        // The default budget: no token (start_sandbox.sh prints it; the default formula gives it).
        f.handler.memoryBudget = DaemonMemoryBudget(budgetBytes: 8 * gib, source: "default", footprint: { 0 })
        XCTAssertEqual(f.handler.handle("STATUS"), before)
        XCTAssertEqual(f.handler.handle("READER \(rid) STATUS"), rBefore)
        // --mem-budget-gb: the token, after client_protocol.
        f.handler.memoryBudget = DaemonMemoryBudget(budgetBytes: 8 * gib, source: "--mem-budget-gb", footprint: { 0 })
        let after = f.handler.handle("STATUS")
        XCTAssertEqual(after, before + " mem_budget_gb=8.000")
        XCTAssertTrue(after.hasSuffix(" client_protocol=2 mem_budget_gb=8.000"), after)
        XCTAssertEqual(f.handler.handle("READER \(rid) STATUS"), rBefore + " mem_budget_gb=8.000")
    }

    // MARK: - The refusal texts, one site at a time, and nothing written

    func budget(_ f: HandlerFixture, bytes: Int, footprint: Int) {
        f.handler.memoryBudget = DaemonMemoryBudget(budgetBytes: bytes, source: "--mem-budget-gb", footprint: { footprint })
    }

    func testSpectralBytesAndWork() throws {
        let f = try HandlerFixture(side: 4)
        budget(f, bytes: 1000, footprint: 100)
        // 16 nodes, all rank 0: 8 * (256 + 256 + 256) = 6,144 bytes, x 1.05 + 64 MiB = 67,115,316.
        XCTAssertEqual(f.handler.handle("DISTANCE spectralL2 0-0 0-0"),
                       "ERROR out_of_budget: DISTANCE needs 67115316 bytes (spectralL2's n*n Double matrices,"
                       + " 8*(|A|^2+|B|^2+max^2) for |A|=16 |B|=16, x 1.05 + 64 MiB), the budget is 1000; nothing written footprint=100")
        // The other metrics are charged too (their subgraphs, per node and
        // per member), so at 1,000 bytes jaccardNodes is refused by name as well.
        XCTAssertTrue(f.handler.handle("DISTANCE jaccardNodes 0-0 0-0").hasPrefix("ERROR out_of_budget: DISTANCE needs"))
        f.handler.memoryBudget = nil
        XCTAssertTrue(f.handler.handle("DISTANCE spectralL2 0-0 0-0").hasPrefix("OK DISTANCE spectralL2"))
        // The work follows the path. A side-34 fixture holds 1,156 nodes and no
        // edge: the cheap branch (no sweep), 1156^2 work units, admitted.
        let g = try HandlerFixture(side: 34)
        XCTAssertTrue(g.handler.handle("DISTANCE spectralL2 0-0 5-5").hasPrefix("OK DISTANCE spectralL2 0-0 vs 5-5 value=0.0 |A|=1156"))
        // One induced edge (1 -> 0, both in 0-1): Jacobi. Charged at the worst case, 1.11 * 50 *
        // 1156^2 * 1155 ns > 60 s, it was refused; it is now admitted at its
        // per-component unit, G' = 8.0*n^2 + 50*(1.273*n(n-1)/2 + 18.26*n*1) ns, about 54 ms, and answers.
        XCTAssertTrue(g.handler.handle("SET 1 RANK 1").hasPrefix("OK"))
        XCTAssertTrue(g.handler.handle("CONNECT FROM 1 TO 0").hasPrefix("OK"))
        XCTAssertTrue(g.handler.handle("DISTANCE spectralL2 0-1 5-5").hasPrefix("OK DISTANCE spectralL2 0-1 vs 5-5 value="))
        // Rank 0 alone leaves node 1 out: the edge is not induced, the cheap branch again.
        XCTAssertTrue(g.handler.handle("DISTANCE spectralL2 0-0 5-5").hasPrefix("OK DISTANCE spectralL2 0-0 vs 5-5 value=0.0 |A|=1155"))
        let s0 = DagSubgraph.rankRange(engine: g.handler.engine, nodeCount: 1156, lo: 0, hi: 1)
        XCTAssertTrue(DagDBCommandHandler.spectralSideHasInducedEdge(engine: g.handler.engine, nodeCount: 1156, sub: s0))
        let s1 = DagSubgraph.rankRange(engine: g.handler.engine, nodeCount: 1156, lo: 0, hi: 0)
        XCTAssertFalse(DagDBCommandHandler.spectralSideHasInducedEdge(engine: g.handler.engine, nodeCount: 1156, sub: s1))
    }

    func testFoldLoopAndDense() throws {
        let f = try HandlerFixture(side: 4)
        XCTAssertEqual(f.handler.handle("FOLD RUN 1000000000000 0 0 0"),
                       "ERROR out_of_budget: FOLD RUN needs 16000000000000 filter steps ((maxRank - keepRank) x N),"
                       + " the per-command work cap is 18867000000; nothing written")
        XCTAssertEqual(f.handler.handle("FOLD RUN 9223372036854775807 0 0 0"),
                       "ERROR out_of_budget: FOLD RUN needs more than 9223372036854775807 filter steps"
                       + " ((maxRank - keepRank) x N), the per-command work cap is 18867000000; nothing written")
        // The dense operator: 26 * 16^2 + 168 * 16 = 9,344 bytes against a 4,096-byte
        // budget (the projection's (8 + 168) * 16 = 2,816 passes); with CHECK, 38 * 16^2 + 2,688 = 12,416.
        budget(f, bytes: 4096, footprint: 0)
        for i in 0..<16 { XCTAssertTrue(f.handler.handle("SET \(i) RANK 1").hasPrefix("OK")) }
        XCTAssertEqual(f.handler.handle("FOLD RUN 1 0 0 0"),
                       "ERROR out_of_budget: FOLD RUN needs 9344 bytes (the dense operator and a fold's blocks,"
                       + " 26*N^2 + 168*N), the budget is 4096; nothing written footprint=0")
        XCTAssertTrue(f.handler.handle("SET 15 RANK 2").hasPrefix("OK"))
        budget(f, bytes: 12000, footprint: 0)
        XCTAssertTrue(f.handler.handle("FOLD RUN 2 0 0 0").hasPrefix("ERROR bad_value: FOLD RUN refused"))   // 9,344 admitted; singular
        XCTAssertEqual(f.handler.handle("FOLD RUN 2 0 0 0 CHECK 1"),
                       "ERROR out_of_budget: FOLD RUN needs 12416 bytes (the dense operator, a fold's blocks and a"
                       + " CHECK tier, 38*N^2 + 168*N), the budget is 12000; nothing written footprint=0")
        // The projection's own admission now carries the object: (8 + 168) * 16 = 2,816 against 2,000.
        budget(f, bytes: 2000, footprint: 0)
        XCTAssertEqual(f.handler.handle("FOLD RUN 1 0 0 0"),
                       "ERROR out_of_budget: FOLD RUN needs 2816 bytes (the projection's active list and"
                       + " LadderFold.Object, (8 + 168)*N), the budget is 2000; nothing written footprint=0")
        XCTAssertTrue(f.handler.handle("SET 15 RANK 1").hasPrefix("OK"))
        // A run the library refuses at its own argument check (a rank above maxRank) allocates
        // nothing and is not charged: its own refusal comes back, not the budget's.
        budget(f, bytes: 4096, footprint: 0)   // the projection's 2,816 passes; the dense 9,344 would not
        XCTAssertTrue(f.handler.handle("SET 3 RANK 5").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("FOLD RUN 2 0 0 0").hasPrefix("ERROR bad_value: FOLD RUN refused: schedule.maxRank 2"))
        XCTAssertNil(f.handler.lastFold)
    }

    func testFoldSchurSum() throws {
        let f = try HandlerFixture(side: 4)
        // ranks: 4 nodes at 2, 12 at 1, keepRank 0: ring 2 (kb 4, ka 12) then ring 1 (kb 12, ka 0).
        let rank = Array(repeating: 2, count: 4) + Array(repeating: 1, count: 12)
        // The fold's work: a*N^2 + fold 1 (m 16, kb 4, ka 12) + fold 2 (m 12, kb 12, ka 0) + the final tier (k 0).
        let a = 10.7, b = 1.81, c = 0.00253
        let want = a * 256 + (a * 256 + b * 144 * 4 + c * 64) + (a * 144 + c * 1728)
        XCTAssertEqual(f.handler.foldWorkNs(rank: rank, maxRank: 2, keepRank: 0, checkpoints: []),
                       AdmitCount(Int(want.rounded(.up))))
        // A CHECK at 1 adds the tier after fold 1: a*12^2 + 3*c*12^3.
        let wantCheck = want + a * 144 + 3 * c * 1728
        XCTAssertEqual(f.handler.foldWorkNs(rank: rank, maxRank: 2, keepRank: 0, checkpoints: [1]),
                       AdmitCount(Int(wantCheck.rounded(.up))))
        // An empty ring stops the walk (the library refuses there): only the dense operator.
        XCTAssertEqual(f.handler.foldWorkNs(rank: rank, maxRank: 3, keepRank: 0, checkpoints: []),
                       AdmitCount(Int((a * 256).rounded(.up))))
    }

    func testBankSites() throws {
        let f = try HandlerFixture(side: 4)
        // BANK OPEN: 12 * T * K bytes before any id, WAL record or registry entry.
        budget(f, bytes: 1_000_000, footprint: 0)
        XCTAssertEqual(f.handler.handle("BANK OPEN x 65536 3000 1 2 0 0 0.02"),
                       "ERROR out_of_budget: BANK OPEN needs 70411879 bytes (the T*K atoms and the declaration's Double"
                       + " copy, 12*T*K, x 1.05 + 64 MiB), the budget is 1000000; nothing written footprint=0")
        XCTAssertEqual(f.handler.handle("BANK LIST"), "OK BANK LIST count=0")
        // The SVD cap: T = 2^20, K = 1,200 is 1.51e12 T*K^2 > 1.48e12.
        f.handler.memoryBudget = nil
        XCTAssertEqual(f.handler.handle("BANK OPEN x 1048576 3000 1 600 0 0 0.02"),
                       "ERROR out_of_budget: BANK OPEN needs 1509949440000 SVD units (T*K^2), the per-command work"
                       + " cap is 1398000000000; nothing written")
        XCTAssertEqual(f.handler.handle("BANK LIST"), "OK BANK LIST count=0")
        // A small bank, then BENCH / NOISE / INFO against a tiny budget.
        XCTAssertTrue(f.handler.handle("BANK OPEN s 64 1000 10 3 0 0 0.02").hasPrefix("OK BANK OPEN id=w00000001"))
        budget(f, bytes: 100, footprint: 0)
        XCTAssertEqual(f.handler.handle("BANK INFO w00000001"),
                       "ERROR out_of_budget: BANK INFO needs 67112090 bytes (the declaration's Double copy of the resident"
                       + " atoms, 8*T*K, x 1.05 + 64 MiB), the budget is 100; nothing written footprint=0")
        // BANK FIT is admitted like one NOISE fit, 16*T*K = 6,144 bytes.
        let x = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        defer { x.deallocate() }
        for i in 0..<64 { x[i] = Float(i % 7) - 3 }
        shm1Header(f.shm, count: 64, verb: .bankFit)
        f.shm.advanced(by: 8).copyMemory(from: x, byteCount: 64 * 4)
        XCTAssertEqual(f.handler.handle("BANK FIT w00000001"),
                       "ERROR out_of_budget: BANK FIT needs 67115316 bytes (one fit's two T*K Double copies, x 1.05 + 64 MiB),"
                       + " the budget is 100; nothing written footprint=0")
        XCTAssertEqual(f.handler.handle("BANK BENCH w00000001 10 2"),
                       "ERROR out_of_budget: BANK BENCH needs 67111804 bytes (one rep's 4*T*M output and the 4*K*M"
                       + " coefficients, x 1.05 + 64 MiB), the budget is 100; nothing written footprint=0")
        XCTAssertEqual(f.handler.handle("BANK NOISE w00000001 0 2"),
                       "ERROR out_of_budget: BANK NOISE needs 67115316 bytes (one fit's two T*K Double copies, x 1.05 + 64 MiB),"
                       + " the budget is 100; nothing written footprint=0")
        f.handler.memoryBudget = nil
        XCTAssertTrue(f.handler.handle("BANK BENCH w00000001 10 2").hasPrefix("OK BANK BENCH"))
        XCTAssertTrue(f.handler.handle("BANK NOISE w00000001 0 2").hasPrefix("OK BANK NOISE"))
        XCTAssertTrue(f.handler.handle("BANK INFO w00000001").hasPrefix("OK BANK INFO"))
        shm1Header(f.shm, count: 64, verb: .bankFit)
        f.shm.advanced(by: 8).copyMemory(from: x, byteCount: 64 * 4)
        XCTAssertTrue(f.handler.handle("BANK FIT w00000001").hasPrefix("OK BANK FIT"))
        // The fit's work: T = 2^20, K = 1,100 is 1.269e12, under the 1.379e12 cap; K = 1,200 is 1.510e12, over.
        XCTAssertNil(f.handler.admitBankFit(T: 1 << 20, K: 1100))
        XCTAssertEqual(f.handler.admitBankFit(T: 1 << 20, K: 1200),
                       "ERROR out_of_budget: BANK FIT needs 1509949440000 fit units (n*T*K^2), the per-command work"
                       + " cap is 1379000000000; nothing written")
    }

    func testHookStepBytes() throws {
        let dir = NSTemporaryDirectory() + "alloc1a_hook_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try writeSyntheticAlarmFixture(in: dir)
        let f = try HandlerFixture(side: 4)
        XCTAssertTrue(f.handler.handle("ALARM LOAD \(path)").hasPrefix("OK ALARM LOAD id=a00000001"))
        XCTAssertTrue(f.handler.handle("HOOK OPEN a00000001 SEALED 100000 DELTA 1000").hasPrefix("OK HOOK OPEN id=h00000001"))
        budget(f, bytes: 10_000, footprint: 0)
        XCTAssertEqual(f.handler.handle("HOOK STEP h00000001 100"),
                       "ERROR out_of_budget: HOOK STEP needs 67134064 bytes (240 B per frame stepped and 104 B per ledger"
                       + " row copied, x 1.05 + 64 MiB), the budget is 10000; nothing written footprint=0")
        XCTAssertTrue(f.handler.handle("HOOK STATE h00000001").hasPrefix("OK HOOK STATE id=h00000001 t=0 "))
        f.handler.memoryBudget = nil
        XCTAssertTrue(f.handler.handle("HOOK STEP h00000001 100").hasPrefix("OK HOOK STEP id=h00000001 t=100 stepped=100"))
    }

    func testTickWork() throws {
        let f = try HandlerFixture(side: 4)
        // 16 nodes, 8 levels' table but every node at rank 0: L = 1, per tick 1 + 56 + 1 (16 nodes round up).
        XCTAssertTrue(f.handler.handle("TICK 2000").hasPrefix("OK TICK 2000"))
        // Every node at its own rank: L = 16, per tick 16 + 56 plus ceil(count * 16 / 28700).
        let g = try HandlerFixture(side: 64, maxRank: 8)
        let n = 4096
        let ranks = UnsafeMutablePointer<UInt64>.allocate(capacity: n)
        defer { ranks.deallocate() }
        for i in 0..<n { ranks[i] = UInt64(i) }
        shm1Header(g.shm, count: n, verb: .setRanksBulk)
        g.shm.advanced(by: 8).copyMemory(from: ranks, byteCount: n * 8)
        XCTAssertTrue(g.handler.handle("SET_RANKS_BULK").hasPrefix("OK SET_RANKS_BULK"))
        // 6000 * (4096 + 60) + ceil(6000 * 4096 / 30669) = 24,936,000 + 802 > 1.8628e7
        // (the cap follows the unit re-measured at load, 3.221 us).
        XCTAssertEqual(g.handler.handle("TICK 6000"),
                       "ERROR out_of_budget: TICK needs 24936802 dispatch-equivalents, the per-command work cap is"
                       + " 18628000; nothing written")
        XCTAssertTrue(g.handler.handle("STATUS").contains(" ticks=0 "))
        XCTAssertEqual(g.handler.handle("TICK UNTIL_STABLE"),
                       "ERROR out_of_budget: TICK UNTIL_STABLE needs 41561336 dispatch-equivalents, the per-command"
                       + " work cap is 18628000; nothing written")
        XCTAssertTrue(g.handler.handle("TICK UNTIL_STABLE MAX 5").hasPrefix("OK TICK UNTIL_STABLE"))
        // TICK_SYNC: one dispatch per tick, so 10000 * 57 + 1428 = 571,428.
        XCTAssertTrue(g.handler.handle("TICK_SYNC 100").hasPrefix("OK TICK_SYNC 100"))
        XCTAssertEqual(g.handler.admitTickWork("TICK_SYNC", count: 10_000, levels: 1, latch: .sync), nil)
        // The latch. One back edge on 4,096 nodes: TICK_SYNC 10000 adds ⌈10000/2531⌉ = 4.
        let h = try HandlerFixture(side: 64, maxRank: 8)
        XCTAssertTrue(h.handler.handle("SET 1 LUT NOR").hasPrefix("OK"))
        XCTAssertTrue(h.handler.handle("CONNECT BACK FROM 1 TO 2").hasPrefix("OK"))
        XCTAssertEqual(h.handler.engine.backEdgeSrcs.count, 1)
        XCTAssertNil(h.handler.admitTickWork("TICK_SYNC", count: 10_000, levels: 1, latch: .sync))
        // Rank-mode TICK below gpuLatchMinBackEdges latches on the CPU each tick: the same 4,096 levels as g,
        // 6000 * 4156 + ⌈6000 * 4096 / 30669⌉ + ⌈6000 * 1 / 1081⌉ = 24,936,808, six more than g's
        // (the CPU latch re-measured at load, 1,081 edges per unit).
        shm1Header(h.shm, count: n, verb: .setRanksBulk)
        h.shm.advanced(by: 8).copyMemory(from: ranks, byteCount: n * 8)
        XCTAssertTrue(h.handler.handle("SET_RANKS_BULK").hasPrefix("OK SET_RANKS_BULK"))
        XCTAssertEqual(h.handler.handle("TICK 6000"),
                       "ERROR out_of_budget: TICK needs 24936808 dispatch-equivalents, the per-command work cap is"
                       + " 18628000; nothing written")
    }

    func testOpenReaderCapAndBytes() throws {
        let f = try HandlerFixture(side: 4)
        budget(f, bytes: 100_000, footprint: 0)
        // (77 + 59) * 16 + 118,000 = 120,176 bytes.
        XCTAssertEqual(f.handler.handle("OPEN_READER"),
                       "ERROR out_of_budget: OPEN_READER needs 120176 bytes (a session's buffers and its state template,"
                       + " (77 + 59)*N + 118 KB), the budget is 100000; nothing written footprint=0")
        XCTAssertEqual(f.handler.sessionManager.openCount, 0)
        f.handler.memoryBudget = nil
        for _ in 0..<64 { XCTAssertTrue(f.handler.handle("OPEN_READER").hasPrefix("OK OPEN_READER")) }
        XCTAssertEqual(f.handler.handle("OPEN_READER"),
                       "ERROR out_of_budget: OPEN_READER needs 65 open sessions, the session cap is 64; nothing written")
        XCTAssertEqual(f.handler.sessionManager.openCount, 64)
    }

    // MARK: - helpers

    func openReader(_ f: HandlerFixture) throws -> String {
        let r = f.handler.handle("OPEN_READER")
        guard let range = r.range(of: "id="), let end = r[range.upperBound...].firstIndex(of: " ") else {
            throw NSError(domain: "alloc1a", code: 1, userInfo: [NSLocalizedDescriptionKey: r])
        }
        return String(r[range.upperBound..<end])
    }

    /// The synthetic five-record alarm fixture, as TwinHookCommandTests writes it.
    func writeSyntheticAlarmFixture(in dir: String) throws -> String {
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
        let path = dir + "mini.json"
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: path))
        return path
    }
}
