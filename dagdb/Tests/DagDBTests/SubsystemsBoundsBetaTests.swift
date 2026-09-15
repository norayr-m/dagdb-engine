import XCTest
@testable import DagDB

/// Audit C, scope β — one edge gate per finding (45–73) plus test items
/// 77 and 84. Criterion: `docs/contracts/SUBSYSTEMS_BOUNDS_GATES_FROZEN.md`.
/// Every failing input here is BUILT BY HAND — a corrupted snapshot field,
/// a hand-written WAL payload, an out-of-range argument — never something
/// the writer under test produced.
///
/// Amateur engineering project, no competitive claims, errors likely.
final class SubsystemsBoundsBetaTests: XCTestCase {

    // MARK: - synthetic alarm records (the 29 MB sealed fixture is by-reference)

    /// Records in the sealed block order (quiet, liar A/B/C, deep, drift),
    /// 1-based index, no waveforms. `AllocatorCourt.run` reads only
    /// culprit / pocket / index, so at the sealed per-class counts
    /// (50/17/17/16/50/50) this reproduces the sealed gate-1 arm numbers
    /// exactly without the file.
    static func syntheticRecords(quiet: Int, liarA: Int, liarB: Int, liarC: Int,
                                 deep: Int, drift: Int) -> [AlarmRecord] {
        var out: [AlarmRecord] = []
        func push(_ culprit: CulpritClass, _ key: String) {
            out.append(AlarmRecord(index: out.count + 1, key: key, culprit: culprit, waveforms: nil))
        }
        for i in 0..<quiet { push(.quiet, "quiet_\(i + 1)") }
        var l = 0
        for _ in 0..<liarA { l += 1; push(.liar(.A), "liar_\(l)") }
        for _ in 0..<liarB { l += 1; push(.liar(.B), "liar_\(l)") }
        for _ in 0..<liarC { l += 1; push(.liar(.C), "liar_\(l)") }
        for i in 0..<deep { push(.deep, "deep_\(i + 1)") }
        for i in 0..<drift { push(.drift, "drift_\(i + 1)") }
        return out
    }

    static func sealedShape200() -> [AlarmRecord] {
        syntheticRecords(quiet: 50, liarA: 17, liarB: 17, liarC: 16, deep: 50, drift: 50)
    }

    static func shape150() -> [AlarmRecord] {
        syntheticRecords(quiet: 40, liarA: 13, liarB: 13, liarC: 12, deep: 36, drift: 36)
    }

    static func shape250() -> [AlarmRecord] {
        syntheticRecords(quiet: 60, liarA: 25, liarB: 25, liarC: 25, deep: 60, drift: 55)
    }

    private static func hook(_ policy: AttentionHook.Policy, _ records: [AlarmRecord],
                             budget: Double, delta: Int = SealedCourt.delta) throws -> AttentionHook {
        var h = try AttentionHook(
            params: AttentionHook.Params(alarmId: "a00000001", layoutId: nil, budget: budget,
                                         delta: delta, policy: policy),
            records: records, layout: SealedCourt.makeLayout())
        h.step(h.frames)
        return h
    }

    private static func arm(for policy: AttentionHook.Policy) -> AllocatorCourt.Arm {
        AllocatorCourt.Arm(rawValue: policy.rawValue)!
    }

    // MARK: - 45 · the judged frame count is the fixture's, not the literal 200

    /// The contract's control gate: hook and court agree bit for bit over a
    /// 150-record synthetic fixture, at every point of the sealed grid.
    func test45HookAndCourtAgreeOn150Records() throws {
        let records = Self.shape150()
        XCTAssertEqual(records.count, 150)
        for g in SealedCourt.budgetGrid {
            let court = AllocatorCourt.run(records: records, budget: g.budget)
            for policy in AttentionHook.Policy.allCases {
                let h = try Self.hook(policy, records, budget: g.budget)
                XCTAssertEqual(h.result, court[Self.arm(for: policy)]!,
                               "B=\(g.budget) policy \(policy): hook and court must judge the same 150 frames")
            }
        }
    }

    /// The edge the literal 200 actually reached: a fixture LONGER than
    /// 200 had its tail dropped by the court while the hook judged all of
    /// it. Both must now judge every record.
    func test45HookAndCourtAgreeOn250Records() throws {
        let records = Self.shape250()
        XCTAssertEqual(records.count, 250)
        let budget = SealedCourt.budgetGrid[2].budget
        let court = AllocatorCourt.run(records: records, budget: budget)
        for policy in AttentionHook.Policy.allCases {
            let h = try Self.hook(policy, records, budget: budget)
            XCTAssertEqual(h.result, court[Self.arm(for: policy)]!,
                           "policy \(policy): the court must not drop the tail past record 200")
        }
        // Every one of the 190 non-quiet trials is judged exactly once.
        let nonQuiet = Set(records.compactMap { $0.claim != nil ? $0.index : nil })
        XCTAssertEqual(nonQuiet.count, 190)
        XCTAssertEqual(Set(court[.allocator]!.servedTrialIds), nonQuiet)
        XCTAssertEqual(court[.allocator]!.served + court[.allocator]!.misses, 190)
    }

    /// A fixture SHORTER than the delta leaves no judged frame at all —
    /// the loop bound must not invert.
    func test45EmptyAndTinyFixturesDoNotInvertTheFrameLoop() throws {
        let empty = AllocatorCourt.run(records: [], budget: 1000, delta: 0)
        XCTAssertEqual(empty[.allocator]!.served + empty[.allocator]!.misses, 0)
        let one = AllocatorCourt.run(records: Self.syntheticRecords(
            quiet: 0, liarA: 0, liarB: 0, liarC: 0, deep: 1, drift: 0), budget: 1e9)
        XCTAssertEqual(one[.allocator]!.served, 1)
    }

    /// S3 receipt. The sealed 200-record gate-1 table, recomputed from a
    /// synthetic fixture of the sealed shape. Every literal below was
    /// captured from a run BEFORE finding 45's repair; if the repair moved
    /// any of them, that is a finding and it stops the merge.
    func test45SealedShape200TableUnmoved() throws {
        struct Row { let served: Int, misses: Int, cost: Double, burstTotal: Int }
        // point -> arm -> (served, misses, cost, burst.total)
        let expected: [[String: Row]] = [
            ["allocator": Row(served: 150, misses: 0, cost: 819218.0, burstTotal: 116),
             "greedy": Row(served: 150, misses: 0, cost: 1095218.0, burstTotal: 116),
             "oracle": Row(served: 150, misses: 0, cost: 819218.0, burstTotal: 116),
             "uniform": Row(served: 50, misses: 100, cost: 94400.0, burstTotal: 116)],
            ["allocator": Row(served: 133, misses: 17, cost: 561872.0, burstTotal: 116),
             "greedy": Row(served: 133, misses: 17, cost: 903696.0, burstTotal: 116),
             "oracle": Row(served: 133, misses: 17, cost: 561872.0, burstTotal: 116),
             "uniform": Row(served: 50, misses: 100, cost: 94400.0, burstTotal: 116)],
            ["allocator": Row(served: 133, misses: 17, cost: 561872.0, burstTotal: 116),
             "greedy": Row(served: 133, misses: 17, cost: 903696.0, burstTotal: 116),
             "oracle": Row(served: 133, misses: 17, cost: 561872.0, burstTotal: 116),
             "uniform": Row(served: 50, misses: 100, cost: 94400.0, burstTotal: 116)],
            ["allocator": Row(served: 116, misses: 34, cost: 375688.0, burstTotal: 116),
             "greedy": Row(served: 116, misses: 34, cost: 764058.0, burstTotal: 116),
             "oracle": Row(served: 116, misses: 34, cost: 375688.0, burstTotal: 116),
             "uniform": Row(served: 50, misses: 100, cost: 94400.0, burstTotal: 116)],
            ["allocator": Row(served: 50, misses: 100, cost: 4900.0, burstTotal: 116),
             "greedy": Row(served: 50, misses: 100, cost: 229274.0, burstTotal: 116),
             "oracle": Row(served: 50, misses: 100, cost: 4900.0, burstTotal: 116),
             "uniform": Row(served: 50, misses: 100, cost: 94400.0, burstTotal: 116)],
        ]
        let records = Self.sealedShape200()
        let grid = AllocatorCourt.runGrid(records: records)
        XCTAssertEqual(grid.count, 5)
        for gi in 0..<5 {
            for arm in AllocatorCourt.Arm.allCases {
                let a = grid[gi].arms[arm]!
                let e = expected[gi][arm.rawValue]!
                XCTAssertEqual(a.served, e.served, "point \(gi) \(arm) served")
                XCTAssertEqual(a.misses, e.misses, "point \(gi) \(arm) misses")
                XCTAssertEqual(a.cost, e.cost, "point \(gi) \(arm) cost")
                XCTAssertEqual(a.burst.total, e.burstTotal, "point \(gi) \(arm) burst.total")
                XCTAssertEqual(a.servedTrialIds.count, 150, "point \(gi) \(arm) servedTrialIds")
                XCTAssertEqual(a.warmupCostExcluded, arm == .uniform ? 1416.0 : 0.0,
                               "point \(gi) \(arm) warmupCostExcluded")
            }
            XCTAssertEqual(grid[gi].arms[.allocator]!, grid[gi].arms[.oracle]!,
                           "point \(gi): allocator == oracle")
        }
    }

    /// …and the hook agrees with that unmoved table, frame by frame.
    func test45HookAndCourtAgreeOnTheSealedShape() throws {
        let records = Self.sealedShape200()
        for g in SealedCourt.budgetGrid {
            let court = AllocatorCourt.run(records: records, budget: g.budget)
            for policy in AttentionHook.Policy.allCases {
                let h = try Self.hook(policy, records, budget: g.budget)
                XCTAssertEqual(h.result, court[Self.arm(for: policy)]!, "B=\(g.budget) policy \(policy)")
            }
        }
    }

    // MARK: - 46 · warmup/tail frame counts come from delta

    func test46WarmupAndTailFramesFollowDelta() throws {
        let records = Self.shape150()
        for delta in [0, 1, 3, 5, 12] {
            // S5 (iii): these two fields used to be compared to the `delta`
            // the same call was handed — true the moment the field is
            // derived from the parameter, whatever the frame loop does.
            // The hook writes one ledger row per frame, so both quantities
            // are measured here by WALKING that ledger, and the court's
            // declared numbers are matched against that walk.
            let h = try Self.hook(.allocator, records, budget: SealedCourt.budgetGrid[0].budget, delta: delta)
            let judgedFrames = h.ledger.filter { $0.judged }.map { $0.t }
            guard let firstJudged = judgedFrames.min(), let lastJudged = judgedFrames.max(),
                  let lastFrame = h.ledger.map({ $0.t }).max() else {
                return XCTFail("no judged frame at delta \(delta)")
            }
            // The frames that run before the first judged one; and the
            // frames the loop appends beyond the fixture's own length —
            // the ledger runs to `lastFrame`, of which `judgedFrames.count`
            // carry a record. (On this loop the appended frames sit at the
            // FRONT, as warm-up: the last frame is judged, so the two
            // walks agree by measurement rather than by construction.)
            let walkedWarmup = firstJudged - 1
            let walkedTail = lastFrame - judgedFrames.count
            XCTAssertEqual(lastJudged, lastFrame, "the last frame is judged, delta \(delta)")
            XCTAssertEqual(judgedFrames.count, records.count, "judged frames at delta \(delta)")
            XCTAssertEqual(h.ledger.count, lastFrame, "ledger length at delta \(delta)")

            let arms = AllocatorCourt.run(records: records, budget: SealedCourt.budgetGrid[0].budget, delta: delta)
            for (arm, a) in arms {
                XCTAssertEqual(a.warmupFramesExcluded, walkedWarmup, "arm \(arm) at delta \(delta)")
                XCTAssertEqual(a.tailFramesAppended, walkedTail, "arm \(arm) at delta \(delta)")
            }
            XCTAssertEqual(h.result.warmupFramesExcluded, walkedWarmup, "hook at delta \(delta)")
            XCTAssertEqual(h.frames, judgedFrames.count + walkedTail,
                           "hook frame count at delta \(delta)")
            print("F46 delta=\(delta): walked warmup=\(walkedWarmup) tail=\(walkedTail) "
                  + "judged=\(judgedFrames.count) frames=\(h.frames)")
        }
        // The sealed delta still reports 3 — the sealed literal is unmoved.
        let sealedArms = AllocatorCourt.run(records: Self.sealedShape200(),
                                            budget: SealedCourt.budgetGrid[0].budget)
        XCTAssertEqual(sealedArms[.allocator]!.warmupFramesExcluded, 3)
        XCTAssertEqual(sealedArms[.allocator]!.tailFramesAppended, 3)
    }

    // MARK: - 47 · a pocket outside 3…6 is refused by name

    func test47CheapestTierRefusesPocketOutsideSealedRange() {
        for bad in [-1, 0, 2, 7, 9, Int.max] {
            XCTAssertThrowsError(try AllocatorCourt.cheapestValue1Tier(row: .L, pocket: bad, budget: 1e9)) { e in
                XCTAssertEqual(e as? SealedCourt.CourtError, .pocketOutOfRange(bad))
            }
        }
        // Every sealed pocket still answers.
        for p in SealedCourt.pockets {
            XCTAssertNoThrow(try AllocatorCourt.cheapestValue1Tier(row: .L, pocket: p, budget: 1e9))
        }
    }

    func test47DeepestTierRefusesPocketOutsideSealedRange() {
        for bad in [-1, 2, 7, 1_000] {
            XCTAssertThrowsError(try AllocatorCourt.deepestAffordableTier(pocket: bad, budget: 1e9)) { e in
                XCTAssertEqual(e as? SealedCourt.CourtError, .pocketOutOfRange(bad))
            }
        }
        for p in SealedCourt.pockets {
            XCTAssertNoThrow(try AllocatorCourt.deepestAffordableTier(pocket: p, budget: 1e9))
        }
    }

    func test47SuccessorCourtRefusesPocketOutsideSealedRange() {
        XCTAssertThrowsError(try SuccessorCourt.greedyDecide(pocketClaims: [7: [.L]], budget: 1e9)) { e in
            XCTAssertEqual(e as? SealedCourt.CourtError, .pocketOutOfRange(7))
        }
        XCTAssertThrowsError(try SuccessorCourt.allocatorDecide(pocketClaims: [9: [.L]], budget: 1e9)) { e in
            XCTAssertEqual(e as? SealedCourt.CourtError, .pocketOutOfRange(9))
        }
        XCTAssertNoThrow(try SuccessorCourt.greedyDecide(pocketClaims: [6: [.L]], budget: 1e9))
        XCTAssertNoThrow(try SuccessorCourt.allocatorDecide(pocketClaims: [3: [.L], 6: [.D]], budget: 1e9))
    }

    // MARK: - 48 · per-class tallies sum to served + misses

    func test48PerClassAndPerEarTalliesAreConserved() throws {
        for records in [Self.sealedShape200(), Self.shape250()] {
            for g in SealedCourt.budgetGrid {
                let arms = AllocatorCourt.run(records: records, budget: g.budget)
                for (arm, a) in arms {
                    let classTotal = a.perClass.values.reduce(0) { $0 + $1.served + $1.missed }
                    XCTAssertEqual(classTotal, a.served + a.misses, "arm \(arm) perClass conservation")
                    let earTotal = a.perEar.values.reduce(0) { $0 + $1.served + $1.missed }
                    let earTrials = records.filter { $0.ear != nil && $0.claim != nil }.count
                    XCTAssertEqual(earTotal, earTrials, "arm \(arm) perEar conservation")
                }
            }
        }
    }

    /// The same conservation on the incremental side.
    func test48HookPerClassTalliesAreConserved() throws {
        let records = Self.sealedShape200()
        for policy in AttentionHook.Policy.allCases {
            let h = try Self.hook(policy, records, budget: SealedCourt.budgetGrid[3].budget)
            let classTotal = h.result.perClass.values.reduce(0) { $0 + $1.served + $1.missed }
            XCTAssertEqual(classTotal, h.result.served + h.result.misses, "hook \(policy)")
        }
    }

    // MARK: - 49 · a duplicate record index

    func test49HookRefusesDuplicateRecordIndex() {
        let dup = [
            AlarmRecord(index: 1, key: "deep_1", culprit: .deep, waveforms: nil),
            AlarmRecord(index: 1, key: "drift_1", culprit: .drift, waveforms: nil),
        ]
        XCTAssertEqual(AllocatorCourt.duplicateRecordIndex(in: dup), 1)
        XCTAssertThrowsError(try AttentionHook(
            params: AttentionHook.Params(alarmId: "a", layoutId: nil, budget: 1e9, policy: .allocator),
            records: dup, layout: SealedCourt.makeLayout())) { e in
            XCTAssertEqual(e as? SealedCourt.CourtError, .duplicateRecordIndex(1))
        }
        // …and the court no longer traps on the same array: the duplicate
        // index resolves keep-first, so the lagged arms judge the one
        // record that index reaches and the oracle (which walks the array,
        // not the index) judges both.
        let arms = AllocatorCourt.run(records: dup, budget: 1e9)
        XCTAssertEqual(arms[.oracle]!.served + arms[.oracle]!.misses, 2)
        XCTAssertEqual(arms[.allocator]!.served + arms[.allocator]!.misses, 1)
        XCTAssertNil(AllocatorCourt.duplicateRecordIndex(in: Self.sealedShape200()))
    }

    /// The ruling's own site for 49: the fixture loader refuses a
    /// duplicate reconstructed (class, suffix) position, so a loaded
    /// fixture can never carry a duplicate index in the first place.
    func test49FixtureLoadRefusesDuplicatePosition() throws {
        // `quiet_1` declaring class "liar" used to be re-sorted into the
        // liar block and collide with `liar_1`; it is now refused one step
        // earlier, on the class/prefix disagreement, which is what this
        // drives. The loader's OWN uniqueness refusal is driven by
        // `test49FixtureLoadRefusesTwoKeysAtTheSamePosition` below (post-
        // merge follow-up F8) — it was ungated until then, and the claim
        // that stood here, that a genuine position collision is something
        // JSON cannot express, was wrong: `quiet_1` and `quiet_01` are two
        // distinct JSON keys at one reconstructed position.
        let path = try writeFixture([
            "quiet_1": ["class": "liar", "liar_ear": "A"],
            "liar_1": ["class": "liar", "liar_ear": "B"],
            "cal0_1": ["class": "cal0"],
        ])
        XCTAssertThrowsError(try AlarmFixture.load(path: path, expectedSHA256: nil)) { e in
            guard case AlarmFixture.FixtureError.badEntry(let key, let reason)? = e as? AlarmFixture.FixtureError else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertEqual(key, "quiet_1")
            XCTAssertTrue(reason.contains(AlarmFixture.classPrefixMismatchReason), reason)
        }
    }

    /// F8 · finding 24's own refusal at the loader, which no test reached:
    /// two distinct JSON keys that reconstruct to ONE position. The suffix
    /// is parsed with `Int(...)`, so `quiet_1` and `quiet_01` both land on
    /// `quiet_1` while each passes the class/prefix check — exactly the
    /// silent non-determinism in `index` (the courts' frame key) that the
    /// finding names.
    func test49FixtureLoadRefusesTwoKeysAtTheSamePosition() throws {
        let path = try writeFixture([
            "quiet_1": ["class": "quiet"],
            "quiet_01": ["class": "quiet"],
            "cal0_1": ["class": "cal0"],
        ])
        XCTAssertThrowsError(try AlarmFixture.load(path: path, expectedSHA256: nil)) { e in
            guard case AlarmFixture.FixtureError.badEntry(let key, let reason)? = e as? AlarmFixture.FixtureError else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertEqual(key, "quiet_01, quiet_1", "the refusal names both colliding keys")
            XCTAssertTrue(reason.contains(AlarmFixture.duplicatePositionReason), reason)
            XCTAssertTrue(reason.contains("quiet_1"), reason)
        }
    }

    /// Finding 25's edge, which the ruling bundles with 49: a key whose
    /// `class` disagrees with its own prefix.
    func test49FixtureLoadRefusesClassPrefixMismatch() throws {
        let path = try writeFixture([
            "quiet_1": ["class": "deep"],
            "cal0_1": ["class": "cal0"],
        ])
        XCTAssertThrowsError(try AlarmFixture.load(path: path, expectedSHA256: nil)) { e in
            guard case AlarmFixture.FixtureError.badEntry(let key, let reason)? = e as? AlarmFixture.FixtureError else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertEqual(key, "quiet_1")
            XCTAssertTrue(reason.contains(AlarmFixture.classPrefixMismatchReason), reason)
        }
        // A well-formed mini fixture still loads.
        let ok = try writeFixture([
            "quiet_1": ["class": "quiet"],
            "liar_1": ["class": "liar", "liar_ear": "B"],
            "cal0_1": ["class": "cal0"],
        ])
        let f = try AlarmFixture.load(path: ok, expectedSHA256: nil)
        XCTAssertEqual(f.records.map(\.index), [1, 2])
    }

    /// Finding 23's half in this file: the pin DEFAULTS to the sealed
    /// constant, so a fixture that is not the sealed one is refused by a
    /// caller that says nothing about hashes.
    func test49FixtureLoadDefaultsToTheSealedPin() throws {
        let path = try writeFixture(["quiet_1": ["class": "quiet"]])
        XCTAssertThrowsError(try AlarmFixture.load(path: path)) { e in
            guard case AlarmFixture.FixtureError.shaMismatch(let expected, let actual)? =
                    e as? AlarmFixture.FixtureError else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertEqual(expected, AlarmFixture.sealedSHA256)
            XCTAssertNotEqual(actual, expected)
        }
    }

    private func writeFixture(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj)
        let path = NSTemporaryDirectory() + "beta-\(UUID().uuidString).json"
        try data.write(to: URL(fileURLWithPath: path))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    // MARK: - 50 / 77 · claimed-pocket ceilings

    func test50SuccessorRefusesTooManyClaimedPockets() {
        var claims: [Int: [ValueRow]] = [:]
        for p in 3..<(3 + BudgetLayout.maxClaimedPockets + 1) { claims[p] = [.L] }
        XCTAssertEqual(claims.count, BudgetLayout.maxClaimedPockets + 1)
        XCTAssertThrowsError(try SuccessorCourt.allocatorDecide(pocketClaims: claims, budget: 1e9)) { e in
            XCTAssertEqual(e as? SealedCourt.CourtError,
                           .tooManyClaimedPockets(BudgetLayout.maxClaimedPockets + 1))
        }
        // The count ceiling is checked before the pocket vocabulary, so a
        // legal-sized but out-of-vocabulary set still names the pocket.
        XCTAssertThrowsError(try SuccessorCourt.allocatorDecide(
            pocketClaims: [3: [.L], 99: [.L]], budget: 1e9)) { e in
            XCTAssertEqual(e as? SealedCourt.CourtError, .pocketOutOfRange(99))
        }
    }

    func test77BudgetLayoutRefusesTwentyOnePockets() throws {
        let cost = [[Double]](repeating: [1.0, 2.0], count: BudgetLayout.maxClaimedPockets + 5)
        let layout = BudgetLayout(cost: cost, minTier: [0, 1])
        let claims = (0..<(BudgetLayout.maxClaimedPockets + 1)).map {
            BudgetLayout.Claim(pocket: $0, classIndex: 0)
        }
        XCTAssertEqual(claims.count, 21)
        XCTAssertThrowsError(try layout.allocate(claims: claims, budget: 1e9)) { e in
            guard case BudgetLayout.LayoutError.tooManyClaimedPockets(let n)? =
                    e as? BudgetLayout.LayoutError else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertEqual(n, 21)
        }
        // Exactly at the ceiling it still lays out.
        let atCap = (0..<BudgetLayout.maxClaimedPockets).map { BudgetLayout.Claim(pocket: $0, classIndex: 0) }
        XCTAssertNoThrow(try layout.allocate(claims: atCap, budget: 0))
        // …and the OPEN-time validator names the same ceiling.
        let tooWide = [[Double]](repeating: [1.0], count: BudgetLayout.maxClaimedPockets + 1)
        let why = BudgetLayout.validationError(cost: tooWide, minTier: [0])
        XCTAssertNotNil(why)
        XCTAssertTrue(why!.contains("maxClaimedPockets"), why!)
    }

    // MARK: - 51 · a classSpecs label absent from counts

    func test51MissingClassCountIsNamedNotSilentlyZero() throws {
        let model = try CorruptionModel(epsM: 0.0, epsS: 0.5, epsN: 0.0)
        let budget = SealedCourt.budgetGrid[0].budget
        var partial = SealedCourt.classCounts
        partial.removeValue(forKey: "drift")

        // The validating front door refuses by name.
        XCTAssertThrowsError(try SuccessorCourt.validate(counts: partial)) { e in
            XCTAssertEqual(e as? SealedCourt.CourtError, .missingClassCount("drift"))
        }
        XCTAssertNoThrow(try SuccessorCourt.validate(counts: SealedCourt.classCounts))

        // …and `frameTotals`, whose signature a non-court caller pins,
        // counts and names the same fact instead of folding it into zero.
        let full = SuccessorCourt.frameTotals(model: model, budget: budget)
        let missing = SuccessorCourt.frameTotals(counts: partial, model: model, budget: budget)
        XCTAssertEqual(full.missingClassCounts, [])
        XCTAssertEqual(missing.missingClassCounts, ["drift"])
        XCTAssertEqual(full.missesAlloc, 25.0, accuracy: 1e-12)
        XCTAssertEqual(missing.missesAlloc, 0.0, accuracy: 1e-12)
        XCTAssertTrue(SuccessorCourt.requiredCountLabels.contains("quiet"))
    }

    // MARK: - 52 · allocate calls claimError first

    func test52AllocateRefusesOutOfRangeClaims() {
        let layout = SealedCourt.makeLayout()
        XCTAssertThrowsError(try layout.allocate(
            claims: [BudgetLayout.Claim(pocket: 99, classIndex: 0)], budget: 1e9)) { e in
            guard case BudgetLayout.ClaimError.badClaim(let why)? = e as? BudgetLayout.ClaimError else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertTrue(why.contains("pocket 99"), why)
        }
        XCTAssertThrowsError(try layout.allocate(
            claims: [BudgetLayout.Claim(pocket: 0, classIndex: 7)], budget: 1e9)) { e in
            guard case BudgetLayout.ClaimError.badClaim(let why)? = e as? BudgetLayout.ClaimError else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertTrue(why.contains("classIndex 7"), why)
        }
        XCTAssertThrowsError(try layout.allocate(
            claims: [BudgetLayout.Claim(pocket: -1, classIndex: 0)], budget: 1e9))
        // A legal claim still lays out.
        XCTAssertNoThrow(try layout.allocate(
            claims: [BudgetLayout.Claim(pocket: 0, classIndex: 1)], budget: 1e9))
    }

    // MARK: - 53 · the phantom mask count derives from the pocket list

    func test53PhantomMaskCountDerivesFromSealedPockets() throws {
        let model = try CorruptionModel(epsM: 0, epsS: 0, epsN: 0.5)
        let subsets = model.phantomSubsets()
        // S5 (iii): `subsets.count == 1 << SealedCourt.pockets.count` was a
        // restatement of the enumeration the code performs. The power set
        // is now built here, from the sealed pocket list, and compared to
        // the masks the model returned — every subset present, exactly
        // once, and no subset the pocket list does not generate.
        var powerSet: [[Int]] = []
        for mask in 0..<(1 << SealedCourt.pockets.count) {
            powerSet.append(SealedCourt.pockets.enumerated()
                .filter { mask & (1 << $0.offset) != 0 }
                .map { $0.element })
        }
        XCTAssertEqual(powerSet.count, 16, "the sealed pocket list is four long")
        XCTAssertEqual(subsets.map { $0.pockets }.sorted { "\($0)" < "\($1)" },
                       powerSet.sorted { "\($0)" < "\($1)" })
        XCTAssertEqual(subsets.count, powerSet.count)
        XCTAssertEqual(Set(subsets.map { "\($0.pockets)" }).count, subsets.count,
                       "each phantom mask appears exactly once")
        for s in subsets {
            XCTAssertTrue(Set(s.pockets).isSubset(of: Set(SealedCourt.pockets)))
        }
        // Every pocket in the list gets a phantom in exactly half the masks.
        for p in SealedCourt.pockets {
            XCTAssertEqual(subsets.filter { $0.pockets.contains(p) }.count, subsets.count / 2,
                           "pocket \(p) must be represented")
        }
        XCTAssertEqual(subsets.reduce(0.0) { $0 + $1.weight }, 1.0, accuracy: 1e-12)
    }

    // MARK: - 54 · a count prefix bounded by the payload that carries it

    func test54CountPrefixIsBoundedBeforeAnyAllocation() {
        // The bound itself, driven directly: 4 bytes left cannot carry
        // 4 294 967 295 four-byte elements.
        XCTAssertNil(TwinWALCodec.boundedCount(UInt32.max, elementSize: 4, remaining: 4))
        XCTAssertNil(TwinWALCodec.boundedCount(3, elementSize: 4, remaining: 8))
        XCTAssertEqual(TwinWALCodec.boundedCount(2, elementSize: 4, remaining: 8), 2)
        XCTAssertEqual(TwinWALCodec.boundedCount(0, elementSize: 4, remaining: 0), 0)

        // …and through the decoder, on a hand-built 8-byte record.
        var payload = Data([0x02, 0x00])
        payload.append(contentsOf: Array("n1".utf8))
        payload.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(payload.count, 8)
        XCTAssertNil(TwinWALCodec.decode(opcode: DagDBWAL.Opcode.twinRingsWrite.rawValue, payload: payload))

        var layoutPayload = Data([0x02, 0x00])
        layoutPayload.append(contentsOf: Array("b1".utf8))
        layoutPayload.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertNil(TwinWALCodec.decode(opcode: DagDBWAL.Opcode.twinLayoutOpen.rawValue, payload: layoutPayload))

        // An honest ringsWrite of two floats still decodes.
        let honest = try! TwinWALCodec.encode(.ringsWrite(id: "n00000001", values: [1.5, -2.5]))
        guard case .ringsWrite(_, let values)? =
                TwinWALCodec.decode(opcode: honest.opcode.rawValue, payload: honest.payload) else {
            return XCTFail("an honest ringsWrite must still decode")
        }
        XCTAssertEqual(values, [1.5, -2.5])
    }

    // MARK: - 55 · a string too long for the u16 length field

    func test55OverlongStringRefusesToEncode() {
        let long = String(repeating: "x", count: Int(UInt16.max) + 1)
        XCTAssertThrowsError(try TwinWALCodec.encode(.close(id: long))) { e in
            guard case TwinWALCodec.CodecError.stringTooLong(_, let bytes)? =
                    e as? TwinWALCodec.CodecError else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertEqual(bytes, Int(UInt16.max) + 1)
        }
        // A path field is the real-world carrier named by the finding.
        XCTAssertThrowsError(try TwinWALCodec.encode(
            .alarmLoad(id: "a00000001", path: long, sha256: "deadbeef")))
        // Exactly at the field's width it still encodes and round-trips.
        let atCap = String(repeating: "y", count: Int(UInt16.max))
        let (opcode, payload) = try! TwinWALCodec.encode(.close(id: atCap))
        guard case .close(let id)? = TwinWALCodec.decode(opcode: opcode.rawValue, payload: payload) else {
            return XCTFail("a string at the field's width must round-trip")
        }
        XCTAssertEqual(id.count, Int(UInt16.max))
    }

    // MARK: - 56 · delta / count outside 0..<2^32

    func test56DeltaAndCountOutsideThirtyTwoBitsRefuseToEncode() {
        for bad in [-1, -5, Int(UInt32.max) + 1] {
            let params = AttentionHook.Params(alarmId: "a00000001", layoutId: nil, budget: 1.0,
                                              delta: bad, policy: .allocator)
            XCTAssertThrowsError(try TwinWALCodec.encode(.hookOpen(id: "h00000001", params: params))) { e in
                guard case TwinWALCodec.CodecError.valueOutOfRange(let field, let v)? =
                        e as? TwinWALCodec.CodecError else {
                    return XCTFail("wrong error: \(e)")
                }
                XCTAssertEqual(field, "hookOpen.delta")
                XCTAssertEqual(v, bad)
            }
            XCTAssertThrowsError(try TwinWALCodec.encode(.hookStep(id: "h00000001", count: bad))) { e in
                XCTAssertEqual((e as? TwinWALCodec.CodecError).map { "\($0)" }?.contains("hookStep.count"), true)
            }
        }
        // On the decode side the slot is a u32, so every decoded value is
        // inside the window by construction — the round-trip proves it.
        for good in [0, 3, Int(UInt32.max)] {
            let params = AttentionHook.Params(alarmId: "a00000001", layoutId: nil, budget: 1.0,
                                              delta: good, policy: .greedy)
            let (opcode, payload) = try! TwinWALCodec.encode(.hookOpen(id: "h00000001", params: params))
            guard case .hookOpen(_, let back)? =
                    TwinWALCodec.decode(opcode: opcode.rawValue, payload: payload) else {
                return XCTFail("delta \(good) must round-trip")
            }
            XCTAssertEqual(back.delta, good)
            XCTAssertTrue(back.delta >= 0 && back.delta < TwinWALCodec.u32Limit)
        }
    }

    // MARK: - S5 (iv) · 56's decode end, over a record no encoder wrote

    /// The letter's TwinWAL ruling says `delta`/`count` outside `0..<2^32`
    /// "refuse at both ends". The encode end refuses by name (test 56). The
    /// decode end reads a fixed four-byte slot, so no byte string can ever
    /// present a value outside that window — which is exactly why the
    /// verifier found no gate here: there is nothing for the decoder to
    /// refuse. What the letter DOES bind at this end is that the window is
    /// the same window: a hand-written record with the slot's top bit set
    /// must come back as the positive value those bytes spell, not as a
    /// negative one, not truncated, and it must re-encode to the very bytes
    /// it was read from. Every record below is written byte by byte here;
    /// none of them came out of `TwinWALCodec.encode`.
    func testS5HandWrittenU32SlotDecodesInsideTheWindow() throws {
        func str(_ v: String) -> [UInt8] {
            let u = Array(v.utf8)
            return [UInt8(u.count & 0xFF), UInt8((u.count >> 8) & 0xFF)] + u
        }
        func f64(_ v: Double) -> [UInt8] { withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) } }

        // The window, spelled out here rather than read off the codec.
        let windowEnd = 1 << 32
        XCTAssertEqual(TwinWALCodec.u32Limit, windowEnd)

        // delta = 0x80000000 = 2^31: the top bit set, which is where a
        // signed read would hand back a negative frame count.
        for (bytes, expected) in [([0x00, 0x00, 0x00, 0x80] as [UInt8], 1 << 31),
                                  ([0xFF, 0xFF, 0xFF, 0xFF], (1 << 32) - 1)] {
            var payload = Data(str("h00000001"))
            payload.append(contentsOf: str("a00000001"))
            payload.append(0)                       // layoutId: absent
            payload.append(contentsOf: f64(1.0))    // budget
            payload.append(contentsOf: bytes)       // delta, raw
            payload.append(0)                       // policy: allocator
            payload.append(0)                       // clockId: absent
            guard case .hookOpen(let id, let params)? =
                    TwinWALCodec.decode(opcode: DagDBWAL.Opcode.twinHookOpen.rawValue,
                                        payload: payload) else {
                return XCTFail("hand-written hookOpen with delta bytes \(bytes) must decode")
            }
            XCTAssertEqual(id, "h00000001")
            XCTAssertEqual(params.delta, expected)
            XCTAssertGreaterThanOrEqual(params.delta, 0)
            XCTAssertLessThan(params.delta, windowEnd)
            // Both ends, one window: what came off the wire is a value the
            // encoder still accepts, and it writes back the same bytes.
            let (opcode, again) = try TwinWALCodec.encode(.hookOpen(id: id, params: params))
            XCTAssertEqual(opcode, .twinHookOpen)
            XCTAssertEqual(again, payload)
            // One past the window has no four-byte spelling at all — the
            // encode end is where that is refused.
            let over = AttentionHook.Params(alarmId: params.alarmId, layoutId: nil,
                                            budget: params.budget, delta: windowEnd,
                                            policy: params.policy)
            XCTAssertThrowsError(try TwinWALCodec.encode(.hookOpen(id: id, params: over)))
        }

        // hookStep's count, same slot, and the work it commands: a count of
        // 4 294 967 295 read off a 15-byte record must not wrap, and must
        // not run 2^32 frames — the hook stops at its own last frame.
        var stepPayload = Data(str("h00000001"))
        stepPayload.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(stepPayload.count, 15)
        guard case .hookStep(_, let count)? =
                TwinWALCodec.decode(opcode: DagDBWAL.Opcode.twinHookStep.rawValue,
                                    payload: stepPayload) else {
            return XCTFail("hand-written hookStep must decode")
        }
        XCTAssertEqual(count, (1 << 32) - 1)
        XCTAssertGreaterThanOrEqual(count, 0)
        XCTAssertLessThan(count, windowEnd)

        let records = Self.shape150()
        var h = try AttentionHook(
            params: AttentionHook.Params(alarmId: "a00000001", layoutId: nil, budget: 1e5,
                                         delta: 3, policy: .allocator),
            records: records, layout: SealedCourt.makeLayout())
        let stepped = h.step(count)
        XCTAssertEqual(stepped, records.count + 3)
        XCTAssertEqual(h.ledger.count, records.count + 3)
        XCTAssertTrue(h.done)
        XCTAssertEqual(h.step(count), 0)
        print("S5(iv) hand-written count=\(count) stepped=\(stepped) frames=\(h.frames)")
    }

    // MARK: - 57 · a bankOpen payload whose samples exceed Int.max

    func test57BankOpenHugeSamplesDecodesToNil() {
        func f64(_ v: Double) -> [UInt8] { withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) } }
        func payload(samplesLE: [UInt8]) -> Data {
            var p = Data([0x02, 0x00]); p.append(contentsOf: Array("w1".utf8))
            p.append(contentsOf: [0x02, 0x00]); p.append(contentsOf: Array("nm".utf8))
            p.append(contentsOf: samplesLE)
            p.append(contentsOf: f64(48000))
            p.append(contentsOf: f64(100))
            p.append(contentsOf: [1, 0, 0, 0])
            p.append(contentsOf: [1, 0, 0, 0])
            p.append(contentsOf: [1, 0, 0, 0])
            p.append(contentsOf: f64(0.1))
            return p
        }
        // samples = 2^63
        XCTAssertNil(TwinWALCodec.decode(opcode: DagDBWAL.Opcode.twinBankOpen.rawValue,
                                          payload: payload(samplesLE: [0, 0, 0, 0, 0, 0, 0, 0x80])))
        // samples = 2^64 - 1
        XCTAssertNil(TwinWALCodec.decode(opcode: DagDBWAL.Opcode.twinBankOpen.rawValue,
                                          payload: payload(samplesLE: [UInt8](repeating: 0xFF, count: 8))))
    }

    // MARK: - 58 · encode validates the spec before converting widths

    func test58BankOpenEncodeRefusesAnInvalidSpec() {
        let negative = WaveBank.Spec(samples: -1, sampleRate: 48000, f0: 100, harmonics: 1,
                                      gaborCenters: 1, gaborFreqs: 1, gaborSigmaFrac: 0.1)
        XCTAssertThrowsError(try TwinWALCodec.encode(.bankOpen(id: "w00000001", name: "n", spec: negative))) { e in
            XCTAssertNotNil(e as? TwinWALCodec.CodecError, "\(e)")
        }
        let negativeHarmonics = WaveBank.Spec(samples: 64, sampleRate: 48000, f0: 100, harmonics: -3,
                                               gaborCenters: 1, gaborFreqs: 1, gaborSigmaFrac: 0.1)
        XCTAssertThrowsError(try TwinWALCodec.encode(
            .bankOpen(id: "w00000001", name: "n", spec: negativeHarmonics)))
    }

    // MARK: - 59 · a minted id that would collide

    func test59MintedIdCollisionRefusesInsteadOfOverwriting() throws {
        let reg = TwinRegistry<Int>(prefix: "t")
        let first = try reg.open(1)
        XCTAssertEqual(first, "t00000001")
        // The id formats only the low 32 bits: wind the counter one whole
        // turn so the next mint lands back on "t00000001".
        reg.resetCounter(to: UInt64(UInt32.max) + 1)
        XCTAssertThrowsError(try reg.open(2)) { e in
            XCTAssertEqual(e as? TwinRegistry<Int>.RegistryError, .duplicateId("t00000001"))
        }
        XCTAssertEqual(reg.openCount, 1, "the live entry must survive")
        XCTAssertEqual(reg.get(first), 1, "and must still hold its own value")
        // The next mint past the collision is free again.
        XCTAssertEqual(try reg.open(3), "t00000002")
    }

    // MARK: - 60 / 84 · a snapshot stamped with another formatVersion

    func test60And84SnapshotFormatVersionIsRefusedByName() throws {
        func snapshotData(_ version: Int) throws -> Data {
            let snap = TwinState.Snapshot(
                formatVersion: version, counters: ["s": 0], streams: [:], records: [:],
                rings: [:], clocks: [:], gears: [:], layouts: [:], alarms: [:])
            return try JSONEncoder().encode(snap)
        }
        for bad in [0, 2, 7, -1] {
            XCTAssertThrowsError(try JSONDecoder().decode(TwinState.Snapshot.self,
                                                          from: try snapshotData(bad))) { e in
                XCTAssertTrue("\(e)".contains("formatVersion"), "\(e)")
            }
        }
        let ok = try JSONDecoder().decode(TwinState.Snapshot.self, from: try snapshotData(1))
        XCTAssertEqual(ok.formatVersion, TwinState.Snapshot.acceptedFormatVersion)

        // A version-2 snapshot must not reach `restore` at all.
        var raw = try JSONSerialization.jsonObject(with: try snapshotData(1)) as! [String: Any]
        raw["formatVersion"] = 2
        let hacked = try JSONSerialization.data(withJSONObject: raw)
        XCTAssertThrowsError(try JSONDecoder().decode(TwinState.Snapshot.self, from: hacked))
    }

    // MARK: - 61 · the declared drop-one policy

    func test61HookBoundToADroppedAlarmIsDroppedToo() throws {
        let twin = TwinState()
        let params = AttentionHook.Params(alarmId: "a00000001", layoutId: nil, budget: 1.0, policy: .allocator)
        let snap = TwinState.Snapshot(
            counters: ["a": 1, "h": 1], streams: [:], records: [:], rings: [:], clocks: [:],
            gears: [:], layouts: [:],
            alarms: ["a00000001": TwinState.AlarmRef(path: "/nonexistent/w2_records.json", sha256: "deadbeef")],
            hooks: ["h00000001": TwinState.HookRef(params: params, t: 0)])

        var warnings: [String] = []
        XCTAssertNoThrow(try twin.restore(snap, warn: { warnings.append($0) }))
        XCTAssertEqual(twin.alarms.openCount, 0, "the alarm set is dropped")
        XCTAssertEqual(twin.hooks.openCount, 0, "so is the hook standing on it")
        XCTAssertEqual(warnings.count, 2, "one warning for the alarm, one for the hook it carried")
        XCTAssertTrue(warnings.contains { $0.contains("a00000001") })
        XCTAssertTrue(warnings.contains { $0.contains("h00000001") })
        // Counters still come back, so a later mint cannot collide.
        XCTAssertEqual(twin.alarms.counter, 1)
        XCTAssertEqual(twin.hooks.counter, 1)
    }

    /// A hook naming an alarm that was never IN the snapshot is real
    /// corruption, not the documented drop case — it still refuses.
    func test61HookNamingAnAbsentAlarmStillRefuses() {
        let twin = TwinState()
        let params = AttentionHook.Params(alarmId: "a00000009", layoutId: nil, budget: 1.0, policy: .allocator)
        let snap = TwinState.Snapshot(
            counters: ["h": 1], streams: [:], records: [:], rings: [:], clocks: [:],
            gears: [:], layouts: [:], alarms: [:],
            hooks: ["h00000001": TwinState.HookRef(params: params, t: 0)])
        XCTAssertThrowsError(try twin.restore(snap, warn: { _ in })) { e in
            XCTAssertEqual(e as? TwinState.TwinError, .notFound("a00000009"))
        }
    }

    // MARK: - 62 · restore lands on the recorded frame or refuses

    func test62RestoreRefusesAFrameTheLedgerCannotReach() throws {
        let records = Self.shape150()
        let params = AttentionHook.Params(alarmId: "a00000001", layoutId: nil, budget: 1.0, policy: .allocator)
        let loader: (String, String) throws -> AlarmFixture = { p, s in
            AlarmFixture(path: p, sha256: s, records: records, control: nil)
        }
        func snapshot(t: Int) -> TwinState.Snapshot {
            TwinState.Snapshot(
                counters: ["a": 1, "h": 1], streams: [:], records: [:], rings: [:], clocks: [:],
                gears: [:], layouts: [:],
                alarms: ["a00000001": TwinState.AlarmRef(path: "/synthetic", sha256: "x")],
                hooks: ["h00000001": TwinState.HookRef(params: params, t: t)])
        }
        // 153 = records.count + delta is the last frame the ledger holds.
        let twin = TwinState()
        XCTAssertNoThrow(try twin.restore(snapshot(t: 153), alarmLoader: loader))
        XCTAssertEqual(twin.hooks.get("h00000001")!.hook.t, 153)

        let beyond = TwinState()
        XCTAssertThrowsError(try beyond.restore(snapshot(t: 10_000), alarmLoader: loader)) { e in
            guard case TwinState.TwinError.badValue(let why)? = e as? TwinState.TwinError else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertTrue(why.contains("10000"), why)
            XCTAssertTrue(why.contains("153"), why)
        }
    }

    // MARK: - 63 · replay caps equal the daemon's

    func test63RecordSliceReplayCapIsTenThousand() throws {
        let header = Self.admissibleHeader()
        func twinWithRecord() throws -> TwinState {
            let t = TwinState()
            try t.apply(.recordOpen(id: "t00000001", name: "s", header: header,
                                     stateHi: 1, stateLo: 2, incHi: 3, incLo: 5))
            return t
        }
        XCTAssertEqual(TwinState.replayCap, 10_000)
        XCTAssertEqual(StreamRecord.maxSliceCount, 10_000)

        let over = try twinWithRecord()
        XCTAssertThrowsError(try over.apply(.recordSlice(id: "t00000001", count: 10_001))) { e in
            guard case TwinState.TwinError.badValue(let why)? = e as? TwinState.TwinError else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertTrue(why.contains("10000"), why)
        }
        XCTAssertEqual(over.records.get("t00000001")!.slices.count, 0, "nothing was drawn")

        let at = try twinWithRecord()
        XCTAssertNoThrow(try at.apply(.recordSlice(id: "t00000001", count: 10_000)))
        XCTAssertEqual(at.records.get("t00000001")!.slices[0].count, 10_000)
    }

    func test63ClockAdvanceReplayCapIsTenThousand() throws {
        let over = TwinState()
        try over.apply(.clockOpen(id: "c00000001"))
        XCTAssertThrowsError(try over.apply(.clockAdvance(id: "c00000001", count: 10_001, value: 0))) { e in
            guard case TwinState.TwinError.badValue(let why)? = e as? TwinState.TwinError else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertTrue(why.contains("10000"), why)
        }
        XCTAssertEqual(over.clocks.get("c00000001")!.clock.tick, 0, "not one tick was run")
        // 2^64 - 1 off a 20-byte record is the case the finding names.
        XCTAssertThrowsError(try over.apply(.clockAdvance(id: "c00000001", count: .max, value: 0)))

        let at = TwinState()
        try at.apply(.clockOpen(id: "c00000001"))
        XCTAssertNoThrow(try at.apply(.clockAdvance(id: "c00000001", count: 10_000, value: 0)))
        XCTAssertEqual(at.clocks.get("c00000001")!.clock.tick, 10_000)
    }

    /// Finding 70's own door: the record primitive refuses the same
    /// counts, plus a negative one.
    func test70SliceCountOutOfRangeRefusesByName() throws {
        var r = try StreamRecord(header: Self.admissibleHeader(),
                                  generator: NamedStream(name: "s", stateHi: 1, stateLo: 2, incHi: 3, incLo: 5))
        for bad in [-1, -10_000, Int.min, StreamRecord.maxSliceCount + 1] {
            XCTAssertThrowsError(try r.recordSlice(count: bad)) { e in
                XCTAssertEqual(e as? StreamRecord.RecordError, .sliceCountOutOfRange(bad))
            }
        }
        XCTAssertEqual(r.slices.count, 0)
        XCTAssertNoThrow(try r.recordSlice(count: 0))
        XCTAssertNoThrow(try r.recordSlice(count: StreamRecord.maxSliceCount))
        XCTAssertEqual(r.slices.map(\.count), [0, StreamRecord.maxSliceCount])
    }

    static func admissibleHeader(floor: Double = 0) -> StreamHeader {
        StreamHeader(signalBandHz: 100, tauWindowSec: 1, combRateHz: 1000,
                     firstEchoSec: 10, recordWindowSec: 1, stepSec: 0.001,
                     clockSyncFloorSec: floor)
    }

    // MARK: - 64 / 65 · ring shapes

    func test64WrappingGearIsRefusedByShapeViolation() throws {
        // 2^33 cubed overflows UInt64, so the coarsest span wraps to 0 and
        // `now / span` divides by zero.
        let why = GearedRings.shapeViolation(gear: 1 << 33, rings: 3, cellsPerRing: 4)
        XCTAssertNotNil(why)
        XCTAssertTrue(why!.contains("overflows"), why!)
        // One ring needs no span at all, so any gear is fine there.
        XCTAssertNil(GearedRings.shapeViolation(gear: 1 << 33, rings: 1, cellsPerRing: 4))
        // The sealed shape is untouched.
        XCTAssertNil(GearedRings.shapeViolation(gear: 6, rings: 6, cellsPerRing: 32))

        // The throwing state-bearing door refuses it…
        let cells = [[GearedRings.Cell]](
            repeating: [GearedRings.Cell](
                repeating: GearedRings.Cell(value: 0, tick: 0, span: 0, occupied: false), count: 4),
            count: 3)
        XCTAssertThrowsError(try GearedRings(gear: 1 << 33, rings: 3, cellsPerRing: 4, now: 0, cells: cells)) { e in
            guard case GearedRings.RingsError.badShape(let s)? = e as? GearedRings.RingsError else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertTrue(s.contains("overflows"), s)
        }
        // …and so does the daemon-facing replay path.
        let twin = TwinState()
        XCTAssertThrowsError(try twin.apply(
            .ringsOpen(id: "n00000001", gear: 1 << 33, rings: 3, cells: 4))) { e in
            guard case TwinState.TwinError.badValue(let s)? = e as? TwinState.TwinError else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertTrue(s.contains("overflows"), s)
        }
    }

    func test65ShapeViolationIsTheOnlyDoorForRingShapes() throws {
        // Every bound the validator states, stated once.
        XCTAssertNotNil(GearedRings.shapeViolation(gear: 1, rings: 6, cellsPerRing: 32))
        XCTAssertNotNil(GearedRings.shapeViolation(gear: 2, rings: 17, cellsPerRing: 4096))
        XCTAssertNotNil(GearedRings.shapeViolation(gear: 2, rings: 1_000_000, cellsPerRing: 4096))
        XCTAssertNotNil(GearedRings.shapeViolation(gear: 2, rings: 6, cellsPerRing: 4097))
        XCTAssertNil(GearedRings.shapeViolation(gear: 2, rings: 16, cellsPerRing: 4096))
        // S5 (ii): the memberwise init THROWS on exactly this validator
        // now — it used to `precondition`, an abort no test could reach, so
        // the gate had to be carried by the trap-free doors beside it. Each
        // out-of-range shape is driven through the memberwise door itself
        // and the refusal is read back and matched against the validator's
        // own message.
        for bad in [(gear: UInt64(1), rings: 6, cells: 32),
                    (gear: UInt64(2), rings: 17, cells: 4096),
                    (gear: UInt64(2), rings: 1_000_000, cells: 4096),
                    (gear: UInt64(2), rings: 6, cells: 4097),
                    (gear: UInt64(2), rings: 6, cells: 1),
                    (gear: UInt64(1) << 33, rings: 3, cells: 4)] {
            let expected = GearedRings.shapeViolation(gear: bad.gear, rings: bad.rings,
                                                      cellsPerRing: bad.cells)
            XCTAssertNotNil(expected, "\(bad)")
            XCTAssertThrowsError(try GearedRings(gear: bad.gear, rings: bad.rings,
                                                 cellsPerRing: bad.cells)) { e in
                guard case GearedRings.RingsError.badShape(let s)? = e as? GearedRings.RingsError else {
                    return XCTFail("wrong error for \(bad): \(e)")
                }
                XCTAssertEqual(s, expected)
            }
        }
        let twin = TwinState()
        XCTAssertThrowsError(try twin.apply(.ringsOpen(id: "n00000001", gear: 2, rings: 1_000_000, cells: 4096)))
        XCTAssertEqual(twin.rings.openCount, 0)
        // …and the sealed shape still builds.
        let sealed = try GearedRings()
        XCTAssertEqual(sealed.capacity, 192)
    }

    // MARK: - S5 (ii) · the gear ratio's own traps, now thrown

    func testS5GearRatioRefusesOutOfRangeInsteadOfTrapping() throws {
        // Zero components: `precondition(num > 0 && den > 0)` before.
        for (n, d) in [(UInt64(0), UInt64(5)), (3, 0), (0, 0)] {
            XCTAssertThrowsError(try GearRatio(n, over: d)) { e in
                XCTAssertEqual(e as? GearRatio.RatioError, .zeroComponent(num: n, den: d))
            }
            XCTAssertNil(GearRatio.reduced(n, over: d))
        }
        // A numerator that can wrap the phase accumulator: the same bound
        // `accumulatorSafe` states, now reachable through the front door.
        for (n, d) in [(UInt64.max, UInt64(2)), (UInt64.max - 1, 4)] {
            XCTAssertFalse(GearRatio.accumulatorSafe(num: n, den: d))
            XCTAssertThrowsError(try GearRatio(n, over: d)) { e in
                XCTAssertEqual(e as? GearRatio.RatioError, .accumulatorUnsafe(num: n, den: d))
            }
        }
        // The composition overflow: 2^62/3 ∘ 2^62/5 cross-reduces to
        // nothing, so the numerator product is 2^124 and does not fit.
        let a = try GearRatio(1 << 62, over: 3)
        let b = try GearRatio(1 << 62, over: 5)
        XCTAssertThrowsError(try a.composed(with: b)) { e in
            guard case GearRatio.RatioError.productOverflows(let why)? = e as? GearRatio.RatioError else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertTrue(why.contains("does not fit UInt64"), why)
        }
        // And the denominators overflow the same way when the numerators
        // cancel: 3/2^62 ∘ 5/2^62.
        XCTAssertThrowsError(try GearRatio(3, over: 1 << 62)
            .composed(with: try GearRatio(5, over: 1 << 62)))
        // Everything legal still passes through both doors unchanged.
        XCTAssertEqual(try GearRatio(4, over: 6), try GearRatio(2, over: 3))
        XCTAssertEqual(try a.composed(with: try GearRatio(3, over: 1 << 62)), try GearRatio(1, over: 1))
    }

    // MARK: - 66 / 67 / 68 · gears

    func test66ComposedReducesBeforeMultiplying() throws {
        // 3/2^32 ∘ 2^32/5: the unreduced numerator product is 3·2^32 and
        // the unreduced denominator product is 5·2^32 — but cross-reducing
        // first cancels 2^32 against 2^32 and the answer is 3/5. The old
        // hand multiplied first, which is where a chain whose REDUCED
        // ratio is small still overflowed.
        XCTAssertEqual(try GearRatio(3, over: 1 << 32).composed(with: try GearRatio(1 << 32, over: 5)),
                       try GearRatio(3, over: 5))
        // 2^40/7 ∘ 7/2^40 = 1/1, where both unreduced products are 7·2^40.
        XCTAssertEqual(try GearRatio(1 << 40, over: 7).composed(with: try GearRatio(7, over: 1 << 40)),
                       try GearRatio(1, over: 1))
        // A product that genuinely does not fit even reduced still fits
        // when the cross-reduce cancels it: 2^62/3 ∘ 3/2^62 is 1/1.
        XCTAssertEqual(try GearRatio(1 << 62, over: 3).composed(with: try GearRatio(3, over: 1 << 62)),
                       try GearRatio(1, over: 1))
        // The sealed ladder still composes to the printed ratio.
        XCTAssertEqual(try GearRatio(1, over: 6).composed(with: try GearRatio(1, over: 6)), try GearRatio(1, over: 36))
    }

    func test67NumeratorThatWouldWrapTheAccumulatorIsRefused() throws {
        XCTAssertNil(GearRatio.reduced(UInt64.max, over: 2))
        XCTAssertNil(GearRatio.reduced(UInt64.max - 1, over: 4))
        XCTAssertNotNil(GearRatio.reduced(UInt64.max, over: 1))
        XCTAssertNotNil(GearRatio.reduced(3, over: 7))
        // A snapshot carrying such a ratio is refused at decode.
        let json = #"{"num":18446744073709551615,"den":2}"#
        XCTAssertThrowsError(try JSONDecoder().decode(GearRatio.self, from: Data(json.utf8)))
        // Whatever survives the door cannot wrap: the fire count is exact
        // on every tick, not just the first.
        let ratio = GearRatio.reduced(UInt64.max / 4, over: 3)!
        var g = PhaseGear(name: "wide", ratio: ratio)
        var fires: UInt64 = 0
        for t in 1...6 { fires &+= g.advance(masterTick: UInt64(t), value: 0) }
        XCTAssertEqual(fires, (ratio.num &* 6) / ratio.den)
        XCTAssertTrue(g.accumulator < ratio.den)
    }

    func test68RestoredGearAboveItsInvariantIsRefused() throws {
        let ratio = try GearRatio(1, over: 7)
        XCTAssertThrowsError(try PhaseGear(name: "g", ratio: ratio, accumulator: 100, fires: 0,
                                            latchedTick: nil, latchedValue: nil)) { e in
            XCTAssertEqual(e as? PhaseGear.GearError,
                           .accumulatorAboveDenominator(accumulator: 100, den: 7))
        }
        XCTAssertNoThrow(try PhaseGear(name: "g", ratio: ratio, accumulator: 6, fires: 4,
                                        latchedTick: 9, latchedValue: 1.5))
        // Decode enforces the same invariant.
        let bad = #"{"name":"g","ratio":{"num":1,"den":7},"accumulator":100,"fires":0}"#
        XCTAssertThrowsError(try JSONDecoder().decode(PhaseGear.self, from: Data(bad.utf8))) { e in
            XCTAssertTrue("\(e)".contains("accumulator"), "\(e)")
        }
        // A legal gear still round-trips through Codable unchanged.
        var g = PhaseGear(name: "g", ratio: try GearRatio(3, over: 7))
        for t in 1...5 { g.advance(masterTick: UInt64(t), value: Float(t)) }
        let back = try JSONDecoder().decode(PhaseGear.self, from: try JSONEncoder().encode(g))
        XCTAssertEqual(back, g)
    }

    // MARK: - 69 · draws that disagree with the slices

    func test69RecordRefusesDrawsThatDisagreeWithItsSlices() throws {
        let header = Self.admissibleHeader()
        let slices = [StreamRecord.Slice(index: 0, entryStateHi: 1, entryStateLo: 2, entryDraws: 0,
                                          count: 12, payload: [UInt64](repeating: 0, count: 12))]
        // draws = 99, slices account for 12
        let wrong = NamedStream(name: "s", stateHi: 1, stateLo: 2, incHi: 3, incLo: 5, draws: 99)
        XCTAssertThrowsError(try StreamRecord(header: header, generator: wrong, slices: slices)) { e in
            guard case StreamRecord.RecordError.sliceAccounting(let why)? =
                    e as? StreamRecord.RecordError else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertTrue(why.contains("99"), why)
        }
        // A payload shorter than the count it declares is the same lie.
        let short = [StreamRecord.Slice(index: 0, entryStateHi: 1, entryStateLo: 2, entryDraws: 0,
                                         count: 12, payload: [1, 2, 3])]
        let ok = NamedStream(name: "s", stateHi: 1, stateLo: 2, incHi: 3, incLo: 5, draws: 12)
        XCTAssertThrowsError(try StreamRecord(header: header, generator: ok, slices: short))
        // An honest record built by the writer round-trips through Codable.
        var live = try StreamRecord(header: header,
                                     generator: NamedStream(name: "s", stateHi: 1, stateLo: 2, incHi: 3, incLo: 5))
        try live.recordSlice(count: 5)
        try live.recordSlice(count: 7)
        let encoded = try JSONEncoder().encode(live)
        XCTAssertEqual(try JSONDecoder().decode(StreamRecord.self, from: encoded), live)
        // …and a hand-corrupted one does not.
        var raw = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var gen = raw["generator"] as! [String: Any]
        gen["draws"] = 99
        raw["generator"] = gen
        let corrupted = try JSONSerialization.data(withJSONObject: raw)
        XCTAssertThrowsError(try JSONDecoder().decode(StreamRecord.self, from: corrupted)) { e in
            XCTAssertTrue("\(e)".contains("slice accounting"), "\(e)")
        }
    }

    // MARK: - 71 · the seventh t-zero quantity is compared

    func test71ClockSyncFloorIsComparedNotMerelyDeclared() throws {
        // A single-clock stream declares 0 — the sealed regime, untouched.
        XCTAssertTrue(Self.admissibleHeader(floor: 0).isAdmissible)
        XCTAssertEqual(Self.admissibleHeader(floor: 0).clockSyncViolations(), [])
        // A floor finer than the integrator step is legal.
        XCTAssertTrue(Self.admissibleHeader(floor: 0.0005).isAdmissible)
        // A floor coarser than the step is not.
        let coarse = Self.admissibleHeader(floor: 0.01)
        XCTAssertFalse(coarse.isAdmissible)
        XCTAssertEqual(coarse.clockSyncViolations(), [.floorAboveStep(floor: 0.01, step: 0.001)])
        // A floor reaching the record window is not.
        let huge = Self.admissibleHeader(floor: 1e9)
        XCTAssertEqual(huge.clockSyncViolations().count, 2)
        // And a record refuses to be born on either.
        let gen = NamedStream(name: "s", stateHi: 1, stateLo: 2, incHi: 3, incLo: 5)
        XCTAssertThrowsError(try StreamRecord(header: coarse, generator: gen)) { e in
            guard case StreamRecord.RecordError.inadmissibleClockSyncFloor(let v)? =
                    e as? StreamRecord.RecordError else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertEqual(v.count, 1)
        }
        let twin = TwinState()
        XCTAssertThrowsError(try twin.apply(.recordOpen(id: "t00000001", name: "s", header: coarse,
                                                         stateHi: 1, stateLo: 2, incHi: 3, incLo: 5)))
        // The negative floor is still the old, separate refusal.
        XCTAssertEqual(Self.admissibleHeader(floor: -1).violations(),
                       [.nonPositiveQuantity("clockSyncFloorSec")])
    }

    // MARK: - 72 / 73 · the rank-bound fixture

    private func makeEngine(side: Int) throws -> DagDBEngine {
        try DagDBEngine(grid: HexGrid(width: side, height: side),
                        state: DagDBState(width: side, height: side), maxRank: 32)
    }

    func test72InstallRefusesAnEngineThatStillHoldsBackEdges() throws {
        guard let engine = try? makeEngine(side: RankBoundFixture.side) else {
            throw XCTSkip("no Metal device")
        }
        try engine.addBackEdgeUnchecked(src: 0, dst: 1)
        XCTAssertEqual(engine.backEdgeCount, 1)
        XCTAssertThrowsError(try RankBoundFixture.install(into: engine)) { e in
            XCTAssertEqual(e as? RankBoundFixture.FixtureError, .engineHasBackEdges(1))
        }
        try engine.clearBackEdges(toNode: 1)
        XCTAssertEqual(engine.backEdgeCount, 0)
        XCTAssertNoThrow(try RankBoundFixture.install(into: engine))
        // The register flag the back edge left behind is cleared too, so
        // the object really is the purely combinational DAG it claims.
        let regs = engine.isRegisterBuf.contents()
            .bindMemory(to: UInt8.self, capacity: engine.nodeCount)
        for i in 0..<engine.nodeCount {
            XCTAssertEqual(regs[i], 0, "node \(i) must not be a register")
        }
    }

    func test73InstallThrowsOnASizeMismatch() throws {
        guard let engine = try? makeEngine(side: 8) else { throw XCTSkip("no Metal device") }
        XCTAssertThrowsError(try RankBoundFixture.install(into: engine)) { e in
            guard case RankBoundFixture.FixtureError.sizeMismatch(let expected, let actual)? =
                    e as? RankBoundFixture.FixtureError else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertEqual(expected, RankBoundFixture.nodeCount)
            XCTAssertEqual(actual, 64)
        }
    }
}
