import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Daemon-level tests for the FOLD verb family (gate F4,
/// docs/contracts/FOLD_API_GATES_FROZEN.md) —
/// DagDBCommandHandler+TwinFold.swift. Every daemon-computed value is
/// checked bit-for-bit against a directly-computed `LadderFold.run(...)`
/// call over a freshly built control object (mirrors Tests/DagDBTests/
/// LadderFoldTests.swift's own comparison style, just over the socket-DSL
/// surface instead of the library call directly).
final class TwinFoldCommandTests: XCTestCase {

    // MARK: - Expected values (library call, side 12 control object)

    /// 49x49 Float32 operator, 49 kept nodes: side 12, f1=f2=78 (node
    /// 6*12+6), schedule maxRank=6 keepRank=3 — exactly the control fixture
    /// F1/F4 use.
    private func expectedControlResult(checkpoints: [Int] = []) throws -> LadderFold.Result {
        let grid = HexGrid(width: 12, height: 12)
        let state = DagDBState(width: 12, height: 12)
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 64)
        let object = LadderFold.Objects.control(engine: engine, grid: grid)
        let schedule = LadderFold.Schedule(maxRank: 6, keepRank: 3, checkpoints: checkpoints)
        return LadderFold.run(object: object, schedule: schedule, sources: LadderFold.Objects.controlSources)
    }

    // MARK: - Fixture: control lanes written into the daemon's own engine

    /// side 12 ⇒ 144 nodes; the control's 49x49 Float32 output is 9,604
    /// bytes, which doesn't fit the fixture's default sizing (8 + 144*24 =
    /// 3,464 bytes) — pass `shmBytes` explicitly to size the buffer to the
    /// FOLD RUN output instead of to `nodeCount`.
    private static let controlShmBytes = 8 + 49 * 49 * 4

    private func makeControlFixture(shmBytes: Int? = nil) throws -> HandlerFixture {
        let f = try HandlerFixture(side: 12, shmBytes: shmBytes ?? Self.controlShmBytes)
        // HandlerFixture wipes neighborsBuf to -1 (a blank-slate default for
        // daemon-kit tests that build graphs up from nothing) — restore the
        // engine's real hex-grid adjacency (what any freshly booted daemon
        // actually has, straight from DagDBEngine.init's `grid.neighbors`)
        // before seeding the control ranks/leak/weights, since G1's `build`
        // reads the existing neighbor lane rather than writing one.
        let nb = f.handler.engine.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: f.grid.neighbors.count)
        for i in 0..<f.grid.neighbors.count { nb[i] = f.grid.neighbors[i] }
        // Writes ranks/leak/weights into f.handler.engine's lanes; FOLD RUN
        // will read the very same lanes back via LadderFold.Object(engine:grid:).
        _ = LadderFold.Objects.control(engine: f.handler.engine, grid: f.grid)
        return f
    }

    // MARK: - shm readers (mirroring TwinBankCommandTests)

    private func readFloatVectorOut(_ f: HandlerFixture) -> [Float] {
        let headerPtr = f.shm.bindMemory(to: UInt32.self, capacity: 2)
        let count = Int(headerPtr[0])
        let dataPtr = f.shm.advanced(by: 8).bindMemory(to: Float.self, capacity: max(1, count))
        return (0..<count).map { dataPtr[$0] }
    }

    private func readU64VectorOut(_ f: HandlerFixture) -> [UInt64] {
        let headerPtr = f.shm.bindMemory(to: UInt32.self, capacity: 2)
        let count = Int(headerPtr[0])
        let dataPtr = f.shm.advanced(by: 8).bindMemory(to: UInt64.self, capacity: max(1, count))
        return (0..<count).map { dataPtr[$0] }
    }

    private func readDoubleVectorOut(_ f: HandlerFixture) -> [Double] {
        let headerPtr = f.shm.bindMemory(to: UInt32.self, capacity: 2)
        let count = Int(headerPtr[0])
        let dataPtr = f.shm.advanced(by: 8).bindMemory(to: Double.self, capacity: max(1, count))
        return (0..<count).map { dataPtr[$0] }
    }

    private func parseField(_ reply: String, _ key: String) -> String? {
        guard let r = reply.range(of: "\(key)=") else { return nil }
        let rest = reply[r.upperBound...]
        let end = rest.firstIndex(of: " ") ?? rest.endIndex
        return String(rest[rest.startIndex..<end])
    }

    // MARK: - FOLD RUN

    func testFoldRunControlBitForBit() throws {
        let f = try makeControlFixture()
        let expected = try expectedControlResult()

        let reply = f.handler.handle("FOLD RUN 6 3 78 78")
        XCTAssertTrue(reply.hasPrefix("OK FOLD RUN kept=49 folds=3 bytes=9604 wall_ms="), reply)

        let shmOp = readFloatVectorOut(f)
        XCTAssertEqual(shmOp.count, 49 * 49)
        for i in 0..<shmOp.count {
            XCTAssertEqual(shmOp[i].bitPattern, expected.finalOperator[i].bitPattern, "final_operator[\(i)]")
        }
    }

    // MARK: - FOLD KEPT

    func testFoldKeptMatchesLibraryKeptNodes() throws {
        let f = try makeControlFixture()
        let expected = try expectedControlResult()
        _ = f.handler.handle("FOLD RUN 6 3 78 78")

        let reply = f.handler.handle("FOLD KEPT")
        XCTAssertTrue(reply.hasPrefix("OK FOLD KEPT kept=49"), reply)

        let ids = readU64VectorOut(f)
        XCTAssertEqual(ids.count, 49)
        XCTAssertEqual(ids, expected.keptNodes.map { UInt64($0) })
    }

    // MARK: - FOLD SOURCE

    func testFoldSource1MatchesFoldedF1() throws {
        let f = try makeControlFixture()
        let expected = try expectedControlResult()
        _ = f.handler.handle("FOLD RUN 6 3 78 78")

        let reply = f.handler.handle("FOLD SOURCE 1")
        XCTAssertTrue(reply.hasPrefix("OK FOLD SOURCE which=1 kept=49"), reply)

        let out = readFloatVectorOut(f)
        XCTAssertEqual(out.count, 49)
        for i in 0..<out.count {
            XCTAssertEqual(out[i].bitPattern, expected.foldedF1[i].bitPattern, "foldedF1[\(i)]")
        }
    }

    func testFoldSource3WithNoF3IsZeroVector() throws {
        let f = try makeControlFixture()
        _ = f.handler.handle("FOLD RUN 6 3 78 78")

        let reply = f.handler.handle("FOLD SOURCE 3")
        XCTAssertTrue(reply.hasPrefix("OK FOLD SOURCE which=3 kept=49"), reply)

        let out = readFloatVectorOut(f)
        XCTAssertEqual(out.count, 49)
        XCTAssertEqual(out, [Float](repeating: 0, count: 49))
    }

    // MARK: - FOLD TIER

    func testFoldTierFinal1MatchesLibraryTierF1() throws {
        let f = try makeControlFixture()
        let expected = try expectedControlResult()
        _ = f.handler.handle("FOLD RUN 6 3 78 78")

        let reply = f.handler.handle("FOLD TIER final 1")
        XCTAssertTrue(reply.hasPrefix("OK FOLD TIER level=final which=1 count=49"), reply)

        let out = readDoubleVectorOut(f)
        XCTAssertEqual(out, expected.tiers["final"]!.f1)
    }

    func testFoldTierUnknownLevelIsNotFound() throws {
        let f = try makeControlFixture()
        _ = f.handler.handle("FOLD RUN 6 3 78 78")

        let reply = f.handler.handle("FOLD TIER 5 1")
        XCTAssertTrue(reply.hasPrefix("ERROR not_found"), reply)
    }

    func testFoldRunWithCheckpointsExposesThemInInfoAndTier() throws {
        let f = try makeControlFixture()
        let expected = try expectedControlResult(checkpoints: [5, 4])

        let runReply = f.handler.handle("FOLD RUN 6 3 78 78 CHECK 5,4")
        XCTAssertTrue(runReply.hasPrefix("OK FOLD RUN kept=49 folds=3 bytes=9604 wall_ms="), runReply)

        let infoReply = f.handler.handle("FOLD INFO")
        XCTAssertEqual(parseField(infoReply, "tiers"), "5,4,final", infoReply)

        let tierReply = f.handler.handle("FOLD TIER 5 1")
        let expectedCount = expected.tiers["5"]!.kept.count
        XCTAssertTrue(tierReply.hasPrefix("OK FOLD TIER level=5 which=1 count=\(expectedCount)"), tierReply)

        let out = readDoubleVectorOut(f)
        XCTAssertEqual(out, expected.tiers["5"]!.f1)
    }

    func testFoldTierWhich3WithNoF3IsNotFound() throws {
        let f = try makeControlFixture()
        _ = f.handler.handle("FOLD RUN 6 3 78 78")

        let reply = f.handler.handle("FOLD TIER final 3")
        XCTAssertTrue(reply.hasPrefix("ERROR not_found"), reply)
    }

    // MARK: - FOLD INFO

    func testFoldInfoBeforeRunIsNotFound() throws {
        let f = try HandlerFixture(side: 12)
        let reply = f.handler.handle("FOLD INFO")
        XCTAssertTrue(reply.hasPrefix("ERROR not_found"), reply)
    }

    func testFoldKeptSourceTierBeforeRunAreNotFound() throws {
        let f = try HandlerFixture(side: 12)
        XCTAssertTrue(f.handler.handle("FOLD KEPT").hasPrefix("ERROR not_found"))
        XCTAssertTrue(f.handler.handle("FOLD SOURCE 1").hasPrefix("ERROR not_found"))
        XCTAssertTrue(f.handler.handle("FOLD TIER final 1").hasPrefix("ERROR not_found"))
    }

    func testFoldInfoAfterPlainRunReportsFinalOnly() throws {
        let f = try makeControlFixture()
        _ = f.handler.handle("FOLD RUN 6 3 78 78")
        let reply = f.handler.handle("FOLD INFO")
        XCTAssertTrue(
            reply.hasPrefix("OK FOLD INFO kept=49 folds=3 tiers=final bytes=9604 wall_ms="),
            reply
        )
    }

    // MARK: - Guards: bad ranks/nodes ⇒ out_of_range

    func testFoldRunRejectsNegativeKeepRank() throws {
        let f = try makeControlFixture()
        XCTAssertTrue(f.handler.handle("FOLD RUN 6 -1 78 78").hasPrefix("ERROR out_of_range"))
    }

    func testFoldRunRejectsMaxRankNotGreaterThanKeepRank() throws {
        let f = try makeControlFixture()
        XCTAssertTrue(f.handler.handle("FOLD RUN 3 3 78 78").hasPrefix("ERROR out_of_range"))
    }

    func testFoldRunRejectsNodeOutOfRange() throws {
        let f = try makeControlFixture()
        XCTAssertTrue(f.handler.handle("FOLD RUN 6 3 999 78").hasPrefix("ERROR out_of_range"))
        XCTAssertTrue(f.handler.handle("FOLD RUN 6 3 78 999").hasPrefix("ERROR out_of_range"))
        XCTAssertTrue(f.handler.handle("FOLD RUN 6 3 78 78 999").hasPrefix("ERROR out_of_range"))
    }

    func testFoldRunRejectsCheckpointOutsideOpenInterval() throws {
        let f = try makeControlFixture()
        // keepRank=3, maxRank=6 — valid checkpoints are strictly in (3, 6): 4, 5.
        XCTAssertTrue(f.handler.handle("FOLD RUN 6 3 78 78 CHECK 3,4").hasPrefix("ERROR out_of_range"))
        XCTAssertTrue(f.handler.handle("FOLD RUN 6 3 78 78 CHECK 6,4").hasPrefix("ERROR out_of_range"))
    }

    // MARK: - Guard: too-small shm ⇒ out_of_range BEFORE any computation

    func testFoldRunTooSmallShmRejectsBeforeComputing() throws {
        let f = try HandlerFixture(side: 12, shmBytes: 64)
        _ = LadderFold.Objects.control(engine: f.handler.engine, grid: f.grid)

        let reply = f.handler.handle("FOLD RUN 6 3 78 78")
        XCTAssertTrue(reply.hasPrefix("ERROR out_of_range"), reply)

        // No result was ever committed — every dependent verb still reports
        // "no fold result yet", proving RUN's own LadderFold.run never ran.
        XCTAssertTrue(f.handler.handle("FOLD INFO").hasPrefix("ERROR not_found"))
    }

    // MARK: - READER session

    private func openReaderId(_ f: HandlerFixture) throws -> String {
        let openReply = f.handler.handle("OPEN_READER")
        guard let ridRange = openReply.range(of: "id="),
              let spaceRange = openReply.range(of: " ", range: ridRange.upperBound..<openReply.endIndex) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not parse reader id out of: \(openReply)"])
        }
        return String(openReply[ridRange.upperBound..<spaceRange.lowerBound])
    }

    func testReaderSessionMayRunFoldRunAndFoldKept() throws {
        let f = try makeControlFixture()
        let rid = try openReaderId(f)

        let runReply = f.handler.handle("READER \(rid) FOLD RUN 6 3 78 78")
        XCTAssertTrue(runReply.hasPrefix("OK FOLD RUN session=\(rid)"), runReply)

        let keptReply = f.handler.handle("READER \(rid) FOLD KEPT")
        XCTAssertTrue(keptReply.hasPrefix("OK FOLD KEPT session=\(rid)"), keptReply)
    }
}
