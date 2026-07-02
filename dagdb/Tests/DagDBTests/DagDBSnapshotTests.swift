import XCTest
@testable import DagDB

final class DagDBSnapshotTests: XCTestCase {

    /// Per-test unique temp dir (Fable review T4 — fixed /tmp names race
    /// when princes run swift test concurrently in the shared dagdb dir).
    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-snap-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    /// Build a tiny engine and return it along with its grid dims.
    private func makeEngine(side: Int) throws -> (DagDBEngine, Int, Int) {
        let grid = HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        return (engine, side, side)
    }

    /// Seed the engine with a small, DAG-valid graph: 6 leaves (rank 2) → 1 aggregator (rank 1) → 1 root (rank 0).
    /// Leaf IDs 1..6, aggregator ID 7, root ID 8.
    private func seed(_ engine: DagDBEngine) {
        let n = engine.nodeCount
        let rank  = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let truth = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let low   = engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high  = engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let nb    = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)

        // Clear
        for i in 0..<n {
            rank[i] = 0; truth[i] = 0; low[i] = 0; high[i] = 0
            for d in 0..<6 { nb[i * 6 + d] = -1 }
        }

        // Leaves 1..6
        for i in 1...6 {
            rank[i] = 2
            truth[i] = 1
            let lut = LUT6Preset.const1
            low[i]  = UInt32(lut & 0xFFFFFFFF)
            high[i] = UInt32((lut >> 32) & 0xFFFFFFFF)
        }

        // Aggregator 7 — MAJ of leaves
        rank[7] = 1
        let maj = LUT6Preset.majority6
        low[7]  = UInt32(maj & 0xFFFFFFFF)
        high[7] = UInt32((maj >> 32) & 0xFFFFFFFF)
        for d in 0..<6 { nb[7 * 6 + d] = Int32(1 + d) }

        // Root 8 — ID of aggregator
        rank[8] = 0
        let idg = LUT6Preset.identity
        low[8]  = UInt32(idg & 0xFFFFFFFF)
        high[8] = UInt32((idg >> 32) & 0xFFFFFFFF)
        nb[8 * 6 + 0] = 7
    }

    func testSnapshotRoundTrip() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        seed(eng1)

        let path = tmpDir! + "dagdb_serde_test.dags"
        _ = try? FileManager.default.removeItem(atPath: path)

        let saved = try DagDBSnapshot.save(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 42, path: path
        )
        // v4 back-edge trailer: 4 B count (0 here) + 8 B per back-edge.
        // v5 env trailer: 4 B "ENVS" magic + 1 B env code = 5 B.
        XCTAssertEqual(saved.bytesWritten, 32 + eng1.nodeCount * 42 + 4 + 5)
        XCTAssertEqual(saved.uncompressedBodyBytes, eng1.nodeCount * 42)

        // Fresh engine — all zeros initially
        let (eng2, _, _) = try makeEngine(side: 8)

        let loaded = try DagDBSnapshot.load(
            engine: eng2, nodeCount: eng2.nodeCount,
            gridW: gw, gridH: gh, path: path
        )
        XCTAssertEqual(loaded.fileNodeCount, eng1.nodeCount)
        XCTAssertEqual(loaded.fileTicks, 42)

        // Compare every buffer byte-for-byte
        XCTAssertTrue(buffersEqual(eng1.rankBuf,         eng2.rankBuf,         eng1.nodeCount * 8), "rank")
        XCTAssertTrue(buffersEqual(eng1.truthStateBuf,   eng2.truthStateBuf,   eng1.nodeCount),     "truth")
        XCTAssertTrue(buffersEqual(eng1.nodeTypeBuf,     eng2.nodeTypeBuf,     eng1.nodeCount),     "type")
        XCTAssertTrue(buffersEqual(eng1.lut6LowBuf,      eng2.lut6LowBuf,      eng1.nodeCount * 4), "lut_low")
        XCTAssertTrue(buffersEqual(eng1.lut6HighBuf,     eng2.lut6HighBuf,     eng1.nodeCount * 4), "lut_high")
        XCTAssertTrue(buffersEqual(eng1.neighborsBuf,    eng2.neighborsBuf,    eng1.nodeCount * 24),"neighbors")
    }

    /// Acceptance test for u64 rank widening (T1b, 2026-04-21).
    /// Queen's criterion: rank values impossible on u8 (300) and u32
    /// (4 294 967 300) must both survive a SAVE/LOAD round-trip.
    func testU64RankRoundTrip() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        let n = eng1.nodeCount

        // Clear the hex-neighbor adjacency so rank-monotonicity can't fire
        // on arbitrary high ranks. We only care about the rank field's
        // type width here, not edge structure.
        let nb = eng1.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        for i in 0..<(n * 6) { nb[i] = -1 }

        // Put a u8-impossible rank on node 0 and a u32-impossible rank on node 1.
        let rank = eng1.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        rank[0] = 300
        rank[1] = 4_294_967_300  // one past UInt32.max

        let path = tmpDir! + "dagdb_u64_rank.dags"
        _ = try? FileManager.default.removeItem(atPath: path)

        _ = try DagDBSnapshot.save(
            engine: eng1, nodeCount: n,
            gridW: gw, gridH: gh, tickCount: 0, path: path
        )

        let (eng2, _, _) = try makeEngine(side: 8)
        _ = try DagDBSnapshot.load(
            engine: eng2, nodeCount: eng2.nodeCount,
            gridW: gw, gridH: gh, path: path
        )

        let rank2 = eng2.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        XCTAssertEqual(rank2[0], 300, "rank=300 must round-trip (u8-impossible)")
        XCTAssertEqual(rank2[1], 4_294_967_300, "rank=4_294_967_300 must round-trip (u32-impossible)")
    }

    func testCompressedRoundTrip() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        seed(eng1)

        let path = tmpDir! + "dagdb_compressed.dags"
        _ = try? FileManager.default.removeItem(atPath: path)

        let saved = try DagDBSnapshot.save(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 7,
            path: path, compressed: true
        )
        // Compressed body should be smaller than raw body (lots of zero padding).
        XCTAssertLessThan(saved.bytesWritten, 32 + saved.uncompressedBodyBytes,
                          "compressed snapshot should shrink vs raw")

        let (eng2, _, _) = try makeEngine(side: 8)
        let loaded = try DagDBSnapshot.load(
            engine: eng2, nodeCount: eng2.nodeCount,
            gridW: gw, gridH: gh, path: path
        )
        XCTAssertEqual(loaded.fileTicks, 7)

        XCTAssertTrue(buffersEqual(eng1.rankBuf,         eng2.rankBuf,         eng1.nodeCount * 8), "rank")
        XCTAssertTrue(buffersEqual(eng1.truthStateBuf,   eng2.truthStateBuf,   eng1.nodeCount),     "truth")
        XCTAssertTrue(buffersEqual(eng1.lut6LowBuf,      eng2.lut6LowBuf,      eng1.nodeCount * 4), "lut_low")
        XCTAssertTrue(buffersEqual(eng1.lut6HighBuf,     eng2.lut6HighBuf,     eng1.nodeCount * 4), "lut_high")
        XCTAssertTrue(buffersEqual(eng1.neighborsBuf,    eng2.neighborsBuf,    eng1.nodeCount * 24),"neighbors")
    }

    func testSnapshotRejectsWrongMagic() throws {
        let (eng, gw, gh) = try makeEngine(side: 8)
        let path = tmpDir! + "dagdb_badmagic.dags"

        try Data(repeating: 0xAA, count: 4096).write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(
            try DagDBSnapshot.load(engine: eng, nodeCount: eng.nodeCount,
                                   gridW: gw, gridH: gh, path: path)
        ) { err in
            guard case DagDBSnapshot.SnapError.invalidMagic = err else {
                XCTFail("expected invalidMagic, got \(err)"); return
            }
        }
    }

    func testSnapshotRejectsGridMismatch() throws {
        let (eng1, _, _) = try makeEngine(side: 8)
        seed(eng1)

        let path = tmpDir! + "dagdb_gridmismatch.dags"
        _ = try? FileManager.default.removeItem(atPath: path)
        _ = try DagDBSnapshot.save(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: 8, gridH: 8, tickCount: 0, path: path
        )

        // Engine claims wrong grid dimensions
        XCTAssertThrowsError(
            try DagDBSnapshot.load(engine: eng1, nodeCount: eng1.nodeCount,
                                   gridW: 16, gridH: 16, path: path)
        ) { err in
            guard case DagDBSnapshot.SnapError.gridMismatch = err else {
                XCTFail("expected gridMismatch, got \(err)"); return
            }
        }
    }

    func testValidatorCatchesRankViolation() throws {
        let (eng, _, _) = try makeEngine(side: 8)
        seed(eng)

        // First: clean graph should validate
        XCTAssertNil(DagDBSnapshot.validate(engine: eng, nodeCount: eng.nodeCount))

        // Inject a rank-violating edge: leaf 1 (rank 2) → leaf 2 (rank 2)
        let nb = eng.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: eng.nodeCount * 6)
        nb[2 * 6 + 1] = 1

        let violation = DagDBSnapshot.validate(engine: eng, nodeCount: eng.nodeCount)
        XCTAssertNotNil(violation)
        XCTAssertTrue(violation!.contains("rank"))
    }

    func testValidatorCatchesSelfLoop() throws {
        let (eng, _, _) = try makeEngine(side: 8)
        seed(eng)

        let nb = eng.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: eng.nodeCount * 6)
        nb[7 * 6 + 5] = 7  // self-loop

        let violation = DagDBSnapshot.validate(engine: eng, nodeCount: eng.nodeCount)
        XCTAssertNotNil(violation)
        XCTAssertTrue(violation!.contains("self-loop"))
    }

    func testValidatorCatchesDuplicate() throws {
        let (eng, _, _) = try makeEngine(side: 8)
        seed(eng)

        // Aggregator 7 has slots pointing at leaves 1..6. Duplicate leaf 1 into slot 5.
        let nb = eng.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: eng.nodeCount * 6)
        nb[7 * 6 + 5] = 1

        let violation = DagDBSnapshot.validate(engine: eng, nodeCount: eng.nodeCount)
        XCTAssertNotNil(violation)
        XCTAssertTrue(violation!.contains("duplicate"))
    }

    // MARK: - Durability (atomic-save)

    /// A dangling .tmp file (simulating a crashed mid-write) must not corrupt
    /// or replace the real snapshot. Load must still succeed on the real file.
    func testDanglingTmpDoesNotCorrupt() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        seed(eng1)

        let path = tmpDir! + "dagdb_atomic.dags"
        _ = try? FileManager.default.removeItem(atPath: path)
        _ = try? FileManager.default.removeItem(atPath: path + ".tmp")

        _ = try DagDBSnapshot.save(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 1, path: path
        )

        // Plant a dangling garbage .tmp — simulates a kill-9 during a later save.
        try Data(repeating: 0xFF, count: 128).write(to: URL(fileURLWithPath: path + ".tmp"))

        // Load must succeed — it reads `path`, not `path.tmp`.
        let (eng2, _, _) = try makeEngine(side: 8)
        let loaded = try DagDBSnapshot.load(
            engine: eng2, nodeCount: eng2.nodeCount,
            gridW: gw, gridH: gh, path: path
        )
        XCTAssertEqual(loaded.fileTicks, 1)
        XCTAssertTrue(buffersEqual(eng1.rankBuf, eng2.rankBuf, eng1.nodeCount * 8))  // rank is u64
    }

    /// After a successful save, no .tmp residue should remain — the rename
    /// step consumed it.
    func testSuccessfulSaveLeavesNoTmp() throws {
        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)

        let path = tmpDir! + "dagdb_notmp.dags"
        _ = try? FileManager.default.removeItem(atPath: path)
        _ = try? FileManager.default.removeItem(atPath: path + ".tmp")

        _ = try DagDBSnapshot.save(
            engine: eng, nodeCount: eng.nodeCount,
            gridW: gw, gridH: gh, tickCount: 2, path: path
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "target written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".tmp"), "tmp cleaned up")
    }

    /// Overwriting an existing snapshot must be atomic — at no point does the
    /// target file appear in a truncated state. Verified by reading the
    /// existing target before-and-after; both reads must succeed.
    func testOverwriteIsAtomic() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        seed(eng1)

        let path = tmpDir! + "dagdb_overwrite.dags"
        _ = try? FileManager.default.removeItem(atPath: path)
        _ = try? FileManager.default.removeItem(atPath: path + ".tmp")

        // Initial save
        _ = try DagDBSnapshot.save(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 10, path: path
        )
        let firstSize = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0

        // Overwrite with different tick count — same-size file
        _ = try DagDBSnapshot.save(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 20, path: path
        )
        let secondSize = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0

        XCTAssertEqual(firstSize, secondSize)

        // Load and confirm we see the NEW tick count — the rename completed.
        let (eng2, _, _) = try makeEngine(side: 8)
        let loaded = try DagDBSnapshot.load(
            engine: eng2, nodeCount: eng2.nodeCount,
            gridW: gw, gridH: gh, path: path
        )
        XCTAssertEqual(loaded.fileTicks, 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".tmp"))
    }

    // MARK: - Helpers

    private func buffersEqual(_ a: MTLBuffer, _ b: MTLBuffer, _ bytes: Int) -> Bool {
        return memcmp(a.contents(), b.contents(), bytes) == 0
    }

    // MARK: - v4 BACK_EDGE round trip

    func testSnapshotRoundTripWithBackEdges() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        seed(eng1)
        // Register two BACK_EDGEs into nodes that have no combinational
        // fan-in.  In `seed`, only certain nodes are connected; nodes 50
        // and 60 are unused, so they are valid register dsts.
        try eng1.addBackEdge(src: 11, dst: 50)
        try eng1.addBackEdge(src: 13, dst: 60)
        XCTAssertEqual(eng1.backEdgeCount, 2)

        let path = tmpDir! + "dagdb_serde_back_edge.dags"
        _ = try? FileManager.default.removeItem(atPath: path)

        let saved = try DagDBSnapshot.save(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 7, path: path
        )
        // Header (32) + body (42N) + back-edge count (4) + 2 entries (16) + v5 env trailer (5).
        XCTAssertEqual(saved.bytesWritten, 32 + eng1.nodeCount * 42 + 4 + 16 + 5)

        let (eng2, _, _) = try makeEngine(side: 8)
        XCTAssertEqual(eng2.backEdgeCount, 0)
        _ = try DagDBSnapshot.load(
            engine: eng2, nodeCount: eng2.nodeCount,
            gridW: gw, gridH: gh, path: path
        )
        XCTAssertEqual(eng2.backEdgeCount, 2, "back-edges round-trip via v4")
        XCTAssertEqual(eng2.backEdgeSrcs, [11, 13])
        XCTAssertEqual(eng2.backEdgeDsts, [50, 60])
        XCTAssertTrue(eng2.isRegister(node: 50))
        XCTAssertTrue(eng2.isRegister(node: 60))
        XCTAssertFalse(eng2.isRegister(node: 11))
    }

    func testSnapshotLoadV4OverwritesPriorBackEdges() throws {
        // Loading a v4 snapshot must reset the back-edge list to whatever
        // the file specifies — even if the live engine had different
        // back-edges before. Specifically, an empty v4 trailer must clear
        // any in-memory back-edges.
        let (eng1, gw, gh) = try makeEngine(side: 8)
        seed(eng1)

        let path = tmpDir! + "dagdb_serde_back_edge_clear.dags"
        _ = try? FileManager.default.removeItem(atPath: path)

        // Save with NO back-edges.
        _ = try DagDBSnapshot.save(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 0, path: path
        )

        // Now build a fresh engine, register some back-edges, then load.
        // `seed` clears neighbors so nodes 50 and 60 have no combinational
        // fan-in, satisfying the back-edge precondition.
        let (eng2, _, _) = try makeEngine(side: 8)
        seed(eng2)
        try eng2.addBackEdge(src: 5, dst: 50)
        try eng2.addBackEdge(src: 6, dst: 60)
        XCTAssertEqual(eng2.backEdgeCount, 2)

        _ = try DagDBSnapshot.load(
            engine: eng2, nodeCount: eng2.nodeCount,
            gridW: gw, gridH: gh, path: path
        )
        XCTAssertEqual(eng2.backEdgeCount, 0, "v4 load with empty trailer clears live list")
        XCTAssertFalse(eng2.isRegister(node: 50))
        XCTAssertFalse(eng2.isRegister(node: 60))
    }

    // MARK: - Malformed snapshot hardening (Fable review H1/H2)

    /// A v4/v5 back-edge trailer whose dst is out of range must be rejected,
    /// not written past the isRegisterBuf. Crafted/corrupt .dags files must
    /// not corrupt heap memory. Regression guard for finding H1.
    func testCorruptBackEdgeDstIsRejected() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        seed(eng1)
        try eng1.addBackEdge(src: 11, dst: 50)  // one valid back-edge

        let dir = tmpDir! + "dagdb-h1-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/be.dags"
        _ = try DagDBSnapshot.save(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 0, path: path
        )

        // Corrupt entry 0's dst to nodeCount + 5. Section layout:
        // header(32) + body(42N) + count(4) + entry0[src(4) dst(4)] + ...
        let n = eng1.nodeCount
        let dstOffset = 32 + n * 42 + 4 + 4
        var data = try Data(contentsOf: URL(fileURLWithPath: path))
        let badDst = UInt32(n + 5)
        data[dstOffset]     = UInt8(badDst & 0xFF)
        data[dstOffset + 1] = UInt8((badDst >> 8) & 0xFF)
        data[dstOffset + 2] = UInt8((badDst >> 16) & 0xFF)
        data[dstOffset + 3] = UInt8((badDst >> 24) & 0xFF)
        try data.write(to: URL(fileURLWithPath: path))

        let (eng2, _, _) = try makeEngine(side: 8)
        XCTAssertThrowsError(
            try DagDBSnapshot.load(
                engine: eng2, nodeCount: eng2.nodeCount,
                gridW: gw, gridH: gh, path: path
            ),
            "loading a back-edge trailer with an out-of-range dst must throw"
        ) { err in
            guard case DagDBSnapshot.SnapError.ioFailure = err else {
                XCTFail("expected ioFailure, got \(err)"); return
            }
        }
        // No partial state: the bad back-edge must not have registered.
        XCTAssertEqual(eng2.backEdgeCount, 0)
    }

    /// A snapshot whose header is valid but whose body is physically
    /// truncated must throw, not trap on an out-of-range subdata slice.
    /// Dying on a half-written file is the wrong failure mode for a
    /// crash-recovery database. Regression guard for finding H2.
    func testTruncatedBodyThrowsNotCrash() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        seed(eng1)

        let dir = tmpDir! + "dagdb-h2-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/trunc.dags"
        _ = try DagDBSnapshot.save(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 0, path: path
        )

        // Chop the file to header + half the body. Header still declares the
        // full body size, so the size guard passes but the bytes are absent.
        let n = eng1.nodeCount
        let fullBody = n * 42
        let truncatedLength = 32 + fullBody / 2
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        try data.prefix(truncatedLength).write(to: URL(fileURLWithPath: path))

        let (eng2, _, _) = try makeEngine(side: 8)
        XCTAssertThrowsError(
            try DagDBSnapshot.load(
                engine: eng2, nodeCount: eng2.nodeCount,
                gridW: gw, gridH: gh, path: path
            ),
            "loading a truncated body must throw, not trap"
        ) { err in
            guard case DagDBSnapshot.SnapError.ioFailure = err else {
                XCTFail("expected ioFailure, got \(err)"); return
            }
        }
    }

    // MARK: - v5 env-origin trailer (Phase 3 of dev/test/prod env split)

    func testV5EnvStampRoundTripUnspecified() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        seed(eng1)
        let path = tmpDir! + "dagdb_v5_unspec.dags"
        _ = try? FileManager.default.removeItem(atPath: path)
        // Save with default (unspecified) env.
        _ = try DagDBSnapshot.save(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 1, path: path
        )
        // Load with default (unspecified) env — passes (legacy compat).
        let (eng2, _, _) = try makeEngine(side: 8)
        _ = try DagDBSnapshot.load(
            engine: eng2, nodeCount: eng2.nodeCount,
            gridW: gw, gridH: gh, path: path
        )
        XCTAssertTrue(buffersEqual(eng1.rankBuf, eng2.rankBuf, eng1.nodeCount * 8))
    }

    func testV5EnvStampRoundTripProd() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        seed(eng1)
        let path = tmpDir! + "dagdb_v5_prod.dags"
        _ = try? FileManager.default.removeItem(atPath: path)
        _ = try DagDBSnapshot.save(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 1, path: path,
            daemonEnv: .prod
        )
        // Load with same env — passes.
        let (eng2, _, _) = try makeEngine(side: 8)
        _ = try DagDBSnapshot.load(
            engine: eng2, nodeCount: eng2.nodeCount,
            gridW: gw, gridH: gh, path: path,
            daemonEnv: .prod
        )
        XCTAssertTrue(buffersEqual(eng1.truthStateBuf, eng2.truthStateBuf, eng1.nodeCount))
    }

    func testV5CrossEnvLoadRejected() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        seed(eng1)
        let path = tmpDir! + "dagdb_v5_cross.dags"
        _ = try? FileManager.default.removeItem(atPath: path)
        _ = try DagDBSnapshot.save(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 1, path: path,
            daemonEnv: .prod
        )
        // Load with a different env — must throw envMismatch.
        let (eng2, _, _) = try makeEngine(side: 8)
        XCTAssertThrowsError(try DagDBSnapshot.load(
            engine: eng2, nodeCount: eng2.nodeCount,
            gridW: gw, gridH: gh, path: path,
            daemonEnv: .test
        )) { err in
            guard case DagDBSnapshot.SnapError.envMismatch(let f, let d) = err else {
                XCTFail("expected envMismatch, got \(err)")
                return
            }
            XCTAssertEqual(f, .prod)
            XCTAssertEqual(d, .test)
        }
    }

    func testV5UnspecifiedEnvBypassesCheck() throws {
        let (eng1, gw, gh) = try makeEngine(side: 8)
        seed(eng1)
        let path = tmpDir! + "dagdb_v5_bypass.dags"
        _ = try? FileManager.default.removeItem(atPath: path)
        // Save with prod env.
        _ = try DagDBSnapshot.save(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 1, path: path,
            daemonEnv: .prod
        )
        // Load with unspecified env — must pass (legacy daemon compat).
        let (eng2, _, _) = try makeEngine(side: 8)
        _ = try DagDBSnapshot.load(
            engine: eng2, nodeCount: eng2.nodeCount,
            gridW: gw, gridH: gh, path: path,
            daemonEnv: .unspecified
        )
        XCTAssertTrue(buffersEqual(eng1.rankBuf, eng2.rankBuf, eng1.nodeCount * 8))
    }

    func testSnapshotEnvFromString() {
        XCTAssertEqual(DagDBSnapshot.SnapshotEnv.from(envString: "dev"), .dev)
        XCTAssertEqual(DagDBSnapshot.SnapshotEnv.from(envString: "test"), .test)
        XCTAssertEqual(DagDBSnapshot.SnapshotEnv.from(envString: "prod"), .prod)
        XCTAssertEqual(DagDBSnapshot.SnapshotEnv.from(envString: "PROD"), .prod)  // case-insensitive
        XCTAssertEqual(DagDBSnapshot.SnapshotEnv.from(envString: nil), .unspecified)
        XCTAssertEqual(DagDBSnapshot.SnapshotEnv.from(envString: ""), .unspecified)
        XCTAssertEqual(DagDBSnapshot.SnapshotEnv.from(envString: "garbage"), .unspecified)
    }
}
