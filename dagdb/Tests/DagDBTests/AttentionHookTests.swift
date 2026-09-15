import XCTest
@testable import DagDB

/// `docs/contracts/HOOK_GATES_FROZEN.md` — the attention hook as a ticked
/// process (twin spec line 6). Mechanics run on a synthetic 5-record mini
/// fixture; H1/H2/H6 replay the sealed 200-record fixture and skip
/// (XCTSkip) when `DAGDB_W2_FIXTURE` is unset — precedent `AlarmFixtureTests
/// .loadSealedOrSkip` / `SealedGateTests.loadSealedOrSkip`. A present-but-
/// wrong hash FAILS (the load throws `shaMismatch`), never skips.
final class AttentionHookTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-hook-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - Synthetic mini fixture (5 records: quiet, liar B, liar A,
    // deep, drift, plus cal0 — block-rank order places both liars right
    // after the quiet record, ahead of deep/drift).

    private func writeMiniHookFixture(named name: String = "hook_mini.json") throws -> (path: String, sha256: String) {
        func wave(_ base: Float) -> [Float] { [base, base + 1, base + 2, base + 3] }
        func entry(_ cls: String, _ base: Float, ear: String? = nil) -> [String: Any] {
            var e: [String: Any] = [
                "class": cls,
                "a": wave(base), "b": wave(base + 10), "c": wave(base + 20),
            ]
            if let ear = ear { e["liar_ear"] = ear }
            return e
        }
        let obj: [String: Any] = [
            "quiet_1": entry("quiet", 0),
            "liar_1": entry("liar", 100, ear: "B"),
            "liar_2": entry("liar", 200, ear: "A"),
            "deep_1": entry("deep", 300),
            "drift_1": entry("drift", 400),
            "cal0_1": entry("cal0", 500),
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        let path = tmpDir + name
        try data.write(to: URL(fileURLWithPath: path))
        return (path, DagDBSnapshot.sha256Hex(data))
    }

    private func loadMiniRecords() throws -> [AlarmRecord] {
        let (path, _) = try writeMiniHookFixture()
        let fixture = try AlarmFixture.load(path: path, expectedSHA256: nil)
        XCTAssertEqual(fixture.records.count, 5, "sanity: the mini fixture is 5 judged records")
        return fixture.records
    }

    private func courtArm(for policy: AttentionHook.Policy) -> AllocatorCourt.Arm {
        AllocatorCourt.Arm(rawValue: policy.rawValue)!
    }

    // MARK: - Mechanics: frames / done

    func testFramesAndDone() throws {
        let records = try loadMiniRecords()
        let layout = SealedCourt.makeLayout()
        var hook = try AttentionHook(
            params: .init(alarmId: "a00000001", layoutId: nil, budget: 100_000, delta: 3, policy: .allocator),
            records: records, layout: layout)

        XCTAssertEqual(hook.frames, 8, "5 records + delta 3")
        XCTAssertFalse(hook.done)

        let stepped = hook.step(100)
        XCTAssertEqual(stepped, 8, "step(100) stops at frames, not 100")
        XCTAssertTrue(hook.done)
        XCTAssertEqual(hook.ledger.count, 8)

        XCTAssertEqual(hook.step(100), 0, "a step past the last frame is a no-op")
        XCTAssertNil(hook.step(), "step() itself returns nil once done")
        XCTAssertEqual(hook.ledger.count, 8, "no extra rows past done")
    }

    // MARK: - Mechanics: warm-up rows and the quiet source's row

    func testWarmupRowsAndQuietNone() throws {
        let records = try loadMiniRecords()
        let layout = SealedCourt.makeLayout()
        let budget = 100_000.0

        // Uniform: 3 warm-up rows, spend 472 excluded from cost.
        var uniformHook = try AttentionHook(
            params: .init(alarmId: "a00000001", layoutId: nil, budget: budget, delta: 3, policy: .uniform),
            records: records, layout: layout)
        for i in 1...3 {
            let row = uniformHook.step()!
            XCTAssertEqual(row.t, i)
            XCTAssertFalse(row.judged, "t=\(i) is warm-up (src = \(i - 3) is out of 1...5)")
            XCTAssertEqual(row.outcome, .none)
            XCTAssertEqual(row.spend, 472)
            XCTAssertFalse(row.countsTowardCost)
        }
        XCTAssertEqual(uniformHook.result.warmupCostExcluded, 1416, "3 * 472")
        XCTAssertEqual(uniformHook.result.cost, 0, "warm-up spend never touches cost")

        // t=4: src=1, the quiet source. Uniform still pays and books cost,
        // but the outcome is none (no hit/miss).
        let quietUniformRow = uniformHook.step()!
        XCTAssertTrue(quietUniformRow.judged)
        XCTAssertEqual(quietUniformRow.src, 1)
        XCTAssertEqual(quietUniformRow.outcome, .none)
        XCTAssertEqual(quietUniformRow.rawClass, "quiet")
        XCTAssertEqual(quietUniformRow.spend, 472)
        XCTAssertTrue(quietUniformRow.countsTowardCost)
        XCTAssertEqual(uniformHook.result.cost, 472)

        // Allocator: 3 warm-up rows, spend 0.
        var allocHook = try AttentionHook(
            params: .init(alarmId: "a00000001", layoutId: nil, budget: budget, delta: 3, policy: .allocator),
            records: records, layout: layout)
        for _ in 1...3 {
            let row = allocHook.step()!
            XCTAssertFalse(row.judged)
            XCTAssertEqual(row.outcome, .none)
            XCTAssertEqual(row.spend, 0)
            XCTAssertFalse(row.countsTowardCost)
        }
        XCTAssertEqual(allocHook.result.cost, 0)
        XCTAssertEqual(allocHook.result.warmupCostExcluded, 0, "warmupCostExcluded is a uniform-only counter")

        // t=4: the quiet source buys nothing for allocator either.
        let quietAllocRow = allocHook.step()!
        XCTAssertTrue(quietAllocRow.judged)
        XCTAssertEqual(quietAllocRow.outcome, .none)
        XCTAssertEqual(quietAllocRow.spend, 0)
        XCTAssertFalse(quietAllocRow.countsTowardCost)
        XCTAssertNil(quietAllocRow.tierBought)
        XCTAssertEqual(allocHook.result.cost, 0)

        // Greedy behaves the same as allocator on a quiet source.
        var greedyHook = try AttentionHook(
            params: .init(alarmId: "a00000001", layoutId: nil, budget: budget, delta: 3, policy: .greedy),
            records: records, layout: layout)
        _ = greedyHook.step(3)
        let quietGreedyRow = greedyHook.step()!
        XCTAssertEqual(quietGreedyRow.outcome, .none)
        XCTAssertEqual(quietGreedyRow.spend, 0)
        XCTAssertFalse(quietGreedyRow.countsTowardCost)
    }

    // MARK: - Mechanics: ledger identities, all three policies

    func testLedgerIdentities() throws {
        let records = try loadMiniRecords()
        let layout = SealedCourt.makeLayout()
        let budget = 100_000.0

        for policy in AttentionHook.Policy.allCases {
            var hook = try AttentionHook(
                params: .init(alarmId: "a00000001", layoutId: nil, budget: budget, delta: 3, policy: policy),
                records: records, layout: layout)
            hook.step(hook.frames)
            XCTAssertTrue(hook.done)

            let sumSpend = hook.ledger.filter(\.countsTowardCost).reduce(0.0) { $0 + $1.spend }
            XCTAssertEqual(sumSpend, hook.result.cost, "policy \(policy): sum(spend | countsTowardCost) == cost")

            let hits = hook.ledger.filter { $0.outcome == .hit }.count
            XCTAssertEqual(hits, hook.result.served, "policy \(policy): count(hit) == served")

            let misses = hook.ledger.filter { $0.outcome == .miss }.count
            XCTAssertEqual(misses, hook.result.misses, "policy \(policy): count(miss) == misses")

            // `servedTrialIds` (the court's own naming) is every JUDGED
            // NON-QUIET source in order — hit or miss alike (`recordOutcome`
            // and uniform's own booking both append it unconditionally); a
            // `none` row (quiet, or warm-up) never appears in it.
            let judgedNonQuietOrder = hook.ledger.filter { $0.outcome != .none }.map(\.src)
            XCTAssertEqual(judgedNonQuietOrder, hook.result.servedTrialIds,
                           "policy \(policy): judged-non-quiet row order == servedTrialIds")
        }
    }

    // MARK: - Mechanics: equals the court on the mini fixture, two budgets

    func testEqualsCourtOnMiniFixture() throws {
        let records = try loadMiniRecords()
        let layout = SealedCourt.makeLayout()

        for budget in [16164.352484758914, 3128.126645687496] {
            let expected = AllocatorCourt.run(records: records, budget: budget)
            for policy in AttentionHook.Policy.allCases {
                var hook = try AttentionHook(
                    params: .init(alarmId: "a00000001", layoutId: nil, budget: budget, delta: SealedCourt.delta, policy: policy),
                    records: records, layout: layout)
                hook.step(hook.frames)
                XCTAssertEqual(hook.result, expected[courtArm(for: policy)]!,
                               "policy \(policy) budget \(budget)")
            }
        }
    }

    // MARK: - Sealed: H1 — ledger equals the court at every grid point

    private func loadSealedOrSkip() throws -> AlarmFixture {
        guard let path = AlarmFixture.envPath else {
            throw XCTSkip("DAGDB_W2_FIXTURE not set — sealed gate skipped")
        }
        return try AlarmFixture.load(path: path, expectedSHA256: AlarmFixture.sealedSHA256)
    }

    func testH1LedgerEqualsCourtAtEveryGridPoint() throws {
        let fixture = try loadSealedOrSkip()
        let layout = SealedCourt.makeLayout()

        for point in SealedCourt.budgetGrid {
            let expected = AllocatorCourt.run(records: fixture.records, budget: point.budget)
            for policy in AttentionHook.Policy.allCases {
                var hook = try AttentionHook(
                    params: .init(alarmId: "a00000001", layoutId: nil, budget: point.budget,
                                  delta: SealedCourt.delta, policy: policy),
                    records: fixture.records, layout: layout)
                let stepped = hook.step(200 + SealedCourt.delta)
                XCTAssertEqual(stepped, 200 + SealedCourt.delta)
                XCTAssertTrue(hook.done)
                XCTAssertEqual(hook.result, expected[courtArm(for: policy)]!,
                               "budget \(point.budget) policy \(policy)")
            }
        }
    }

    // MARK: - Sealed: H2 — per-frame identities over the full 203 rows

    func testH2IdentitiesOver203Rows() throws {
        let fixture = try loadSealedOrSkip()
        let layout = SealedCourt.makeLayout()
        let budget = SealedCourt.budgetGrid[0].budget  // richest point

        for policy: AttentionHook.Policy in [.allocator, .uniform] {
            var hook = try AttentionHook(
                params: .init(alarmId: "a00000001", layoutId: nil, budget: budget,
                              delta: SealedCourt.delta, policy: policy),
                records: fixture.records, layout: layout)
            hook.step(hook.frames)

            XCTAssertEqual(hook.ledger.count, 203)
            XCTAssertTrue(hook.ledger[0..<3].allSatisfy { !$0.judged }, "t=1..3 are warm-up")
            XCTAssertTrue(hook.ledger[3...].allSatisfy(\.judged), "t=4..203 are all judged (200 records, delta 3)")

            let sumSpend = hook.ledger.filter(\.countsTowardCost).reduce(0.0) { $0 + $1.spend }
            XCTAssertEqual(sumSpend, hook.result.cost, "policy \(policy)")

            let hits = hook.ledger.filter { $0.outcome == .hit }.count
            XCTAssertEqual(hits, hook.result.served, "policy \(policy)")

            let misses = hook.ledger.filter { $0.outcome == .miss }.count
            XCTAssertEqual(misses, hook.result.misses, "policy \(policy)")

            let judgedNonQuietOrder = hook.ledger.filter { $0.outcome != .none }.map(\.src)
            XCTAssertEqual(judgedNonQuietOrder, hook.result.servedTrialIds, "policy \(policy)")
        }

        // H5's printed line for the richest point, asserted as data here.
        var allocHook = try AttentionHook(
            params: .init(alarmId: "a00000001", layoutId: nil, budget: budget,
                          delta: SealedCourt.delta, policy: .allocator),
            records: fixture.records, layout: layout)
        allocHook.step(allocHook.frames)
        XCTAssertEqual(allocHook.result.served, 150)
        XCTAssertEqual(allocHook.result.misses, 0)
        XCTAssertEqual(allocHook.result.cost, 819218.0)

        var uniformHook = try AttentionHook(
            params: .init(alarmId: "a00000001", layoutId: nil, budget: budget,
                          delta: SealedCourt.delta, policy: .uniform),
            records: fixture.records, layout: layout)
        uniformHook.step(uniformHook.frames)
        XCTAssertEqual(uniformHook.result.served, 50)
        XCTAssertEqual(uniformHook.result.misses, 100)
        XCTAssertEqual(uniformHook.result.cost, 94400.0)
    }

    // MARK: - Sealed: H6 — printed, not gated

    func testH6PrintedSpendProfile() throws {
        let fixture = try loadSealedOrSkip()
        let layout = SealedCourt.makeLayout()
        let budget = SealedCourt.budgetGrid[0].budget  // richest point

        var hook = try AttentionHook(
            params: .init(alarmId: "a00000001", layoutId: nil, budget: budget,
                          delta: SealedCourt.delta, policy: .allocator),
            records: fixture.records, layout: layout)

        let t0 = Date()
        for _ in 0..<203 { hook.step() }
        let elapsedUs = Date().timeIntervalSince(t0) * 1_000_000.0
        let meanUsPerStep = elapsedUs / 203.0
        print("H6: allocator policy, sealed layout, richest point — mean \(meanUsPerStep) µs/step over 203 steps")

        for t in [50, 100, 150, 203] {
            let row = hook.ledger[t - 1]
            XCTAssertEqual(row.t, t)
            print("H6: cumulative cost at t=\(t): \(row.cumulativeCost)")
        }
    }
}
