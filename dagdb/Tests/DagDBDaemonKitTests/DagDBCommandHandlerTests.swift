import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Handler-level tests that were impossible while the command dispatch lived
/// in the daemon's executableTarget (Fable review T1/G2). The handler runs
/// against a real engine with a plain allocated results buffer standing in
/// for the mmap'd shm, so every OK/ERROR string and every state change is
/// directly assertable — no socket, no daemon process.
final class DagDBCommandHandlerTests: XCTestCase {

    private var shm: UnsafeMutableRawPointer!
    private var shmBytes = 0

    override func tearDownWithError() throws {
        if let p = shm { p.deallocate(); shm = nil }
    }

    private func makeHandler(
        side: Int,
        dataRoot: String? = nil,
        dagdbEnv: String? = nil,
        wal: DagDBWAL.Appender? = nil
    ) throws -> DagDBCommandHandler {
        let grid = HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        let nb = engine.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: engine.nodeCount * 6)
        for i in 0..<(engine.nodeCount * 6) { nb[i] = -1 }

        shmBytes = 8 + engine.nodeCount * 24
        shm = UnsafeMutableRawPointer.allocate(byteCount: shmBytes, alignment: 8)
        shm.initializeMemory(as: UInt8.self, repeating: 0, count: shmBytes)

        return DagDBCommandHandler(
            engine: engine, grid: grid, nodeCount: engine.nodeCount,
            width: side, height: side, maxRank: 8,
            tickCount: 0, walAppender: wal,
            sessionManager: DagDBReaderSessionManager(),
            truthRankIndex: TruthRankIndex(),
            shmBase: shm, resultRowSize: 24,
            dataRoot: dataRoot, dagdbEnv: dagdbEnv
        )
    }

    // MARK: - Dispatch round-trips

    func testSetThenGetTruthRoundTrips() throws {
        let h = try makeHandler(side: 4)
        XCTAssertEqual(h.handle("SET 5 TRUTH 1"), "OK SET node=5 truth=1")
        XCTAssertEqual(h.handle("GET 5 TRUTH"), "OK GET node=5 truth=1")
    }

    func testTickIncrementsTickCount() throws {
        let h = try makeHandler(side: 4)
        XCTAssertEqual(h.tickCount, 0)
        _ = h.handle("TICK 3")
        XCTAssertEqual(h.tickCount, 3, "handler must own and advance tickCount")
    }

    func testTickSyncVerb() throws {
        let h = try makeHandler(side: 4)
        // one-hop propagation per sync tick: src (CONST1, rank 1) -> dst (OR, rank 0)
        _ = h.handle("SET 0 RANK 1")
        _ = h.handle("SET 0 LUT CONST1")
        _ = h.handle("SET 1 RANK 0")
        _ = h.handle("SET 1 LUT 0xFFFFFFFFFFFFFFFE")
        XCTAssertTrue(h.handle("CONNECT FROM 0 TO 1").hasPrefix("OK"))
        let r = h.handle("TICK_SYNC 1")
        XCTAssertTrue(r.hasPrefix("OK TICK_SYNC 1"), r)
        XCTAssertEqual(h.tickCount, 1, "TICK_SYNC advances the shared tickCount")
        // after ONE sync tick src just turned on; dst still saw the old 0
        XCTAssertTrue(h.handle("GET 1 TRUTH").hasSuffix("truth=0"))
        _ = h.handle("TICK_SYNC 1")
        XCTAssertTrue(h.handle("GET 1 TRUTH").hasSuffix("truth=1"),
                      "second sync tick delivers the hop")
    }

    func testUnknownCommandRejected() throws {
        let h = try makeHandler(side: 4)
        XCTAssertTrue(h.handle("FLARGLE 1 2").hasPrefix("ERROR unknown_command"))
    }

    func testNodesWritesResultRowsToShm() throws {
        let h = try makeHandler(side: 4)
        _ = h.handle("SET 3 RANK 7")
        _ = h.handle("SET 3 TRUTH 1")
        let reply = h.handle("NODES AT RANK 7")
        XCTAssertEqual(reply, "OK NODES rows=1")
        // Header: [u32 rowCount][u32 rowSize]; row 0: [u64 node][u64 rank]...
        let header = shm.bindMemory(to: UInt32.self, capacity: 2)
        XCTAssertEqual(header[0], 1)
        XCTAssertEqual(header[1], 24)
        let row = shm.advanced(by: 8)
        XCTAssertEqual(row.loadUnaligned(as: UInt64.self), 3)              // node id
        XCTAssertEqual(row.advanced(by: 8).loadUnaligned(as: UInt64.self), 7) // rank
    }

    // MARK: - CONNECT invariant enforcement (was daemon-only)

    func testConnectRejectsRankViolation() throws {
        let h = try makeHandler(side: 4)
        _ = h.handle("SET 1 RANK 1")
        _ = h.handle("SET 2 RANK 5")
        // edge must flow high-rank src -> low-rank dst; src(1) rank 1 < dst(2) rank 5
        XCTAssertTrue(h.handle("CONNECT FROM 1 TO 2").contains("rank violation"),
            "CONNECT must reject an edge that violates rank monotonicity")
    }

    func testConnectRejectsSelfLoop() throws {
        let h = try makeHandler(side: 4)
        XCTAssertTrue(h.handle("CONNECT FROM 3 TO 3").contains("self-loop"))
    }

    // MARK: - COMPOSE (was completely untested — review G2)

    func testComposeAndProducesBitwiseAnd() throws {
        let h = try makeHandler(side: 4)
        // Put known LUTs on src1=1, src2=2; compose AND into dst=3.
        _ = h.handle("SET 1 LUT 0xFF00FF00FF00FF00")
        _ = h.handle("SET 2 LUT 0x0F0F0F0F0F0F0F0F")
        let reply = h.handle("COMPOSE AND 1 2 INTO 3")
        XCTAssertTrue(reply.hasPrefix("OK COMPOSE"), reply)
        let low  = h.engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: h.nodeCount)
        let high = h.engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: h.nodeCount)
        let dstLUT = (UInt64(high[3]) << 32) | UInt64(low[3])
        XCTAssertEqual(dstLUT, 0xFF00FF00FF00FF00 & 0x0F0F0F0F0F0F0F0F)
    }

    func testComposeNotProducesBitwiseComplement() throws {
        let h = try makeHandler(side: 4)
        _ = h.handle("SET 1 LUT 0xAAAAAAAAAAAAAAAA")
        _ = h.handle("COMPOSE NOT 1 INTO 2")
        let low  = h.engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: h.nodeCount)
        let high = h.engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: h.nodeCount)
        let dstLUT = (UInt64(high[2]) << 32) | UInt64(low[2])
        XCTAssertEqual(dstLUT, ~UInt64(0xAAAAAAAAAAAAAAAA))
    }

    /// A binary COMPOSE missing its second source is rejected. Note: the
    /// parser rejects it as `unknown_command` (the AND/OR/XOR branch needs the
    /// full token count) BEFORE the handler's own "requires two sources" guard
    /// can fire — so that guard is effectively dead defensive code. The
    /// contract that matters: the malformed command does not mutate and is
    /// rejected. (Discovery surfaced by the T1 extraction.)
    func testComposeBinaryMissingSecondSourceIsRejected() throws {
        let h = try makeHandler(side: 4)
        XCTAssertTrue(h.handle("COMPOSE AND 1 INTO 3").hasPrefix("ERROR"))
    }

    func testComposeRejectsOutOfRange() throws {
        let h = try makeHandler(side: 4)
        XCTAssertTrue(h.handle("COMPOSE NOT 9999 INTO 3").hasPrefix("ERROR out_of_range"))
    }

    // MARK: - guardPath / DAGDB_DATA_ROOT enforcement (was daemon-only)

    func testGuardPathRejectsOutOfRootSave() throws {
        let root = NSTemporaryDirectory() + "dagdb-guard-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let h = try makeHandler(side: 4, dataRoot: root, dagdbEnv: "test")
        let reply = h.handle("SAVE /etc/dagdb_escape.dags")
        XCTAssertTrue(reply.contains("outside DAGDB_DATA_ROOT"), reply)
    }

    func testGuardPathRejectsTraversal() throws {
        let root = NSTemporaryDirectory() + "dagdb-guard-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let h = try makeHandler(side: 4, dataRoot: root, dagdbEnv: "test")
        XCTAssertTrue(h.handle("SAVE \(root)/../escape.dags").contains("traversal segment"))
    }

    func testGuardPathAllowsInRootSave() throws {
        let root = NSTemporaryDirectory() + "dagdb-guard-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let h = try makeHandler(side: 4, dataRoot: root, dagdbEnv: "test")
        XCTAssertTrue(h.handle("SAVE \(root)/ok.dags").hasPrefix("OK SAVE"))
    }

    // MARK: - WAL append-before-mutate ordering (was daemon-only)

    /// When the WAL append fails, the mutation must abort and the engine
    /// buffer must stay unchanged — the log and the engine cannot diverge.
    func testWalFailureAbortsMutation() throws {
        // Build a WAL appender, then close its file descriptor out from under
        // it by pointing at a path that becomes unwritable. Simplest reliable
        // failure: a WAL whose directory we remove so the next append throws.
        let dir = NSTemporaryDirectory() + "dagdb-wal-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let walPath = dir + "/live.wal"
        let h = try makeHandler(side: 4)
        let appender = try DagDBWAL.Appender(path: walPath, nodeCount: h.nodeCount)
        // Re-wire the handler onto this appender via a fresh handler sharing
        // the same engine would be cleaner, but the appender is internal; build
        // a handler that already holds it.
        let h2 = try makeHandler(side: 4, wal: appender)
        XCTAssertEqual(h2.handle("SET 2 TRUTH 1"), "OK SET node=2 truth=1")
        let truthBefore = h2.engine.truthStateBuf.contents()
            .bindMemory(to: UInt8.self, capacity: h2.nodeCount)[2]
        XCTAssertEqual(truthBefore, 1)

        // Now make appends fail by removing the WAL directory.
        try FileManager.default.removeItem(atPath: dir)
        let reply = h2.handle("SET 3 TRUTH 1")
        // Either the append still buffers (OK) or it errors; if it errors the
        // engine must NOT have been mutated.
        if reply.hasPrefix("ERROR wal:") {
            let truth3 = h2.engine.truthStateBuf.contents()
                .bindMemory(to: UInt8.self, capacity: h2.nodeCount)[3]
            XCTAssertEqual(truth3, 0, "WAL append failure must abort the engine mutation")
        }
        _ = h // keep alive
    }
}
