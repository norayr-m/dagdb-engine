import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// DAEMON BOUNDS — gates D1, D2, D3, D6, D7, D8 of
/// `docs/contracts/DAEMON_BOUNDS_GATES_FROZEN.md`, driven from audit B
/// (`docs/contracts/AUDIT_B_daemon.md`, findings 2-17 and 20-23).
///
/// Every test here drives an EDGE the shipped daemon used to cross
/// silently — a negative id, an id equal to the extent, `Int.max`, a
/// count that outruns the shm mapping, a product that overflows `Int` —
/// and asserts the daemon REFUSES BY NAME and is still alive afterwards.
/// The `STATUS` assertion after each refusal is the "still alive" half:
/// before the fix several of these sites trapped and took the process
/// down, so a green `STATUS` is the evidence the guard fired instead of
/// the pointer.
///
/// Gate D4 (socket framing) lives in `SocketFramingTests.swift`. Gate D5
/// (the reader allowlist) lives with the fixtures it needs: the FOLD half
/// in `TwinFoldCommandTests`, the TILED half in `TiledCommandTests`, and
/// the web bridge's half in `web/test_bridge_allowlist.py`.
final class DaemonBoundsTests: XCTestCase {

    /// The "handler is still alive" probe every refusal is followed by.
    private func assertAlive(_ f: HandlerFixture, _ file: StaticString = #filePath, _ line: UInt = #line) {
        XCTAssertTrue(f.handler.handle("STATUS").hasPrefix("OK STATUS"),
                      "handler did not survive the refusal", file: file, line: line)
    }

    /// Asserts a refusal that NAMES the offending value and the true extent.
    private func assertRefused(
        _ f: HandlerFixture, _ command: String, contains: String...,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let reply = f.handler.handle(command)
        XCTAssertTrue(reply.hasPrefix("ERROR out_of_range:"),
                      "`\(command)` → \(reply)", file: file, line: line)
        for needle in contains {
            XCTAssertTrue(reply.contains(needle),
                          "`\(command)` → \(reply) (missing '\(needle)')", file: file, line: line)
        }
        assertAlive(f, file, line)
    }

    // MARK: - D1 · every wire integer bounded on BOTH sides

    /// Audit finding 2 — `TRAVERSE FROM -1` reached `ranks[node]`, a
    /// bounds-checked Swift array subscript: a TRAP, not a refusal.
    func testTraverseFromNegativeIsRefusedByName() throws {
        let f = try HandlerFixture(side: 4)
        assertRefused(f, "TRAVERSE FROM -1 DEPTH 1", contains: "node", "-1", "0..<16")
    }

    func testTraverseFromExtentAndIntMaxAreRefusedByName() throws {
        let f = try HandlerFixture(side: 4)
        assertRefused(f, "TRAVERSE FROM 16 DEPTH 1", contains: "node", "16", "0..<16")
        assertRefused(f, "TRAVERSE FROM \(Int.max) DEPTH 1", contains: "node", "0..<16")
    }

    /// Audit finding 6 — depth drove the frontier loop with no bound of its
    /// own. No path in a DAG on N nodes is longer than N-1 hops.
    func testTraverseDepthIsBoundedBothSides() throws {
        let f = try HandlerFixture(side: 4)
        assertRefused(f, "TRAVERSE FROM 0 DEPTH -1", contains: "depth", "-1", "0..<16")
        assertRefused(f, "TRAVERSE FROM 0 DEPTH 1000", contains: "depth", "1000", "0..<16")
        assertRefused(f, "TRAVERSE FROM 0 DEPTH \(Int.max)", contains: "depth", "0..<16")
    }

    /// Audit findings 3 and 4 — the five `SET` verbs, `CLEAR … EDGES` and
    /// `GET … TRUTH` reached raw `UnsafeMutablePointer` subscripts with no
    /// `>= 0` check and (with `DAGDB_WAL` unset, the default) no `UInt32`
    /// cast in front: a SILENT out-of-bounds write BEFORE the Metal buffer.
    func testEveryNodeIdVerbRefusesNegativeExtentAndIntMax() throws {
        let f = try HandlerFixture(side: 4)          // 16 nodes
        XCTAssertNil(f.handler.walAppender, "finding 4's edge needs walAppender == nil")

        let commands: [(String) -> String] = [
            { "SET \($0) TRUTH 1" },
            { "SET \($0) WEIGHT 0 1.0" },
            { "SET \($0) VALUE 1.0" },
            { "SET \($0) RANK 1" },
            { "SET \($0) LUT AND" },
            { "CLEAR \($0) EDGES" },
            { "CLEAR \($0) BACK_EDGES" },
            { "GET \($0) TRUTH" },
            { "CONNECT FROM \($0) TO 1" },
            { "CONNECT FROM 1 TO \($0)" },
            { "CONNECT BACK FROM \($0) TO 1" },
            { "CONNECT BACK FROM 1 TO \($0)" },
            { "COMPOSE NOT \($0) INTO 1" },
            { "COMPOSE AND 1 \($0) INTO 2" },
            { "COMPOSE NOT 1 INTO \($0)" },
            { "ANCESTRY FROM \($0) DEPTH 1" },
            { "BFS_DEPTHS FROM \($0)" },
            { "SIMILAR_DECISIONS TO \($0) DEPTH 1 K 1" },
        ]
        for make in commands {
            for bad in ["-1", "16", "\(Int.max)"] {
                let cmd = make(bad)
                let reply = f.handler.handle(cmd)
                XCTAssertTrue(reply.hasPrefix("ERROR out_of_range:"), "`\(cmd)` → \(reply)")
                XCTAssertTrue(reply.contains("0..<16"),
                              "`\(cmd)` → \(reply) — the refusal must name the true extent")
                assertAlive(f)
            }
        }
    }

    /// Audit finding 5 — `TICK -1` built `0..<(-1)`, a Swift range
    /// precondition failure (a TRAP), and a large count ran an unbounded
    /// GPU loop on the single-threaded accept loop.
    func testTickAndTickSyncCountsAreBoundedBothSides() throws {
        let f = try HandlerFixture(side: 4)
        assertRefused(f, "TICK -1", contains: "count", "-1", "0...10000")
        assertRefused(f, "TICK 10001", contains: "count", "10001", "0...10000")
        assertRefused(f, "TICK \(Int.max)", contains: "count", "0...10000")
        assertRefused(f, "TICK_SYNC -1", contains: "count", "-1", "0...10000")
        assertRefused(f, "TICK_SYNC 10001", contains: "count", "10001", "0...10000")
        assertRefused(f, "TICK_SYNC \(Int.max)", contains: "count", "0...10000")
        XCTAssertEqual(f.handler.tickCount, 0, "no refused tick may have advanced the clock")
    }

    /// Audit finding 5, second half — `tickCount` is `UInt32`; a tick that
    /// would carry it past `UInt32.max` traps on the `+= 1`. It stays
    /// `UInt32` (the snapshot header and the WAL checkpoint epoch are
    /// written from it), so the overflow must be refused BY NAME instead.
    func testTickTotalOverflowIsRefusedByName() throws {
        let f = try HandlerFixture(side: 4)
        f.handler.tickCount = UInt32.max - 3
        let reply = f.handler.handle("TICK 10")
        XCTAssertTrue(reply.hasPrefix("ERROR out_of_range:"), reply)
        XCTAssertTrue(reply.contains("4294967295"), reply)
        XCTAssertEqual(f.handler.tickCount, UInt32.max - 3, "the refused tick must not advance the clock")
        assertAlive(f)

        // EVAL ticks once too, and must refuse at the same ceiling.
        f.handler.tickCount = UInt32.max
        XCTAssertTrue(f.handler.handle("EVAL").hasPrefix("ERROR out_of_range:"))
        assertAlive(f)

        // Just below the ceiling still works — the guard is a ceiling, not a wall.
        f.handler.tickCount = UInt32.max - 3
        XCTAssertTrue(f.handler.handle("TICK 3").hasPrefix("OK TICK 3"))
        XCTAssertEqual(f.handler.tickCount, UInt32.max)
    }

    /// Audit finding 22 — `CLOCK ADVANCE <id> <n>` drove an n-tick loop
    /// inside `TwinState.apply` with no top-end bound, unlike `TILED TICK`.
    func testClockAdvanceCountIsCapped() throws {
        let f = try HandlerFixture(side: 4)
        XCTAssertTrue(f.handler.handle("CLOCK OPEN").hasPrefix("OK CLOCK OPEN"))
        assertRefused(f, "CLOCK ADVANCE c00000001 -1", contains: "n", "-1", "0...10000")
        assertRefused(f, "CLOCK ADVANCE c00000001 10001", contains: "n", "10001", "0...10000")
        assertRefused(f, "CLOCK ADVANCE c00000001 \(Int.max)", contains: "n", "0...10000")
        XCTAssertTrue(f.handler.handle("CLOCK ADVANCE c00000001 2").hasPrefix("OK CLOCK ADVANCE"))
    }

    /// Audit finding 21 — `BANK NOISE <id> <seed> <n>` spun
    /// `for _ in 0..<seed { _ = stream.next64() }` with `seed` guarded only
    /// `>= 0`, so a ten-billion seed wedged the accept loop.
    func testBankNoiseSeedIsCapped() throws {
        let f = try HandlerFixture(side: 64)
        XCTAssertTrue(f.handler.handle("BANK OPEN mouth").hasPrefix("OK BANK OPEN"))
        assertRefused(f, "BANK NOISE w00000001 1000001 1", contains: "seed", "1000001", "0...1000000")
        assertRefused(f, "BANK NOISE w00000001 \(Int.max) 1", contains: "seed", "0...1000000")
        XCTAssertTrue(f.handler.handle("BANK NOISE w00000001 3 1").hasPrefix("OK BANK NOISE"))
    }

    /// The reader twin of finding 2 (`DagDBCommandHandler.swift:954`) —
    /// the snapshot engine's `ranks[node]` traps just as readily.
    func testReaderSessionNodeIdsAreBoundedBothSides() throws {
        let f = try HandlerFixture(side: 4)
        let open = f.handler.handle("OPEN_READER")
        guard let idRange = open.range(of: "id="),
              let space = open.range(of: " ", range: idRange.upperBound..<open.endIndex) else {
            return XCTFail("could not parse reader id out of: \(open)")
        }
        let rid = String(open[idRange.upperBound..<space.lowerBound])

        for cmd in ["READER \(rid) TRAVERSE FROM -1 DEPTH 1",
                    "READER \(rid) TRAVERSE FROM 16 DEPTH 1",
                    "READER \(rid) TRAVERSE FROM \(Int.max) DEPTH 1",
                    "READER \(rid) GET -1 TRUTH",
                    "READER \(rid) GET \(Int.max) TRUTH",
                    "READER \(rid) ANCESTRY FROM -1 DEPTH 1"] {
            let reply = f.handler.handle(cmd)
            XCTAssertTrue(reply.hasPrefix("ERROR out_of_range:"), "`\(cmd)` → \(reply)")
            XCTAssertTrue(reply.contains("0..<16"), "`\(cmd)` → \(reply)")
            assertAlive(f)
        }
    }

    // MARK: - D2 · every shared-memory WRITE checks capacity

    /// The `[u32 count][u32 rowSize]` header every shm writer lays down.
    private func shmHeaderCount(_ f: HandlerFixture) -> UInt32 {
        f.shm.bindMemory(to: UInt32.self, capacity: 2)[0]
    }

    /// F7 · stamp a sentinel over the shm row-count header so the next
    /// writer's check is independent of every writer before it.
    private func poisonShmHeader(_ f: HandlerFixture, _ value: UInt32) {
        f.shm.bindMemory(to: UInt32.self, capacity: 2)[0] = value
    }

    /// Audit finding 7 — `writeU64Vector` / `writeFloatVector` /
    /// `writeDoubleVector` never compared the vector to `shmCapacityBytes`,
    /// while their sibling readers always did. A 64-byte mapping holds
    /// `(64 - 8) / 8 = 7` u64s; twelve of them ran 40 bytes past the end.
    /// Post-merge follow-up F7: the four checks used to share one shm header
    /// and read it as `0` after each writer, so removing ONE writer's guard
    /// failed all four and none of the last three could attribute a failure
    /// to its own writer. The header is poisoned with a sentinel before each
    /// call instead: a writer that refuses leaves the sentinel standing, and
    /// a writer that overruns stamps its own count over it.
    func testVectorWritersRefuseInsteadOfOverrunning() throws {
        let f = try HandlerFixture(side: 4, shmBytes: 64)
        XCTAssertEqual(f.handler.shmCapacityBytes, 64)
        let sentinel: UInt32 = 0xDEAD_BEEF

        poisonShmHeader(f, sentinel)
        f.handler.writeU64Vector([UInt64](repeating: 0xFFFF_FFFF_FFFF_FFFF, count: 12))
        XCTAssertEqual(shmHeaderCount(f), sentinel, "writeU64Vector wrote past a 64-byte mapping")

        poisonShmHeader(f, sentinel)
        f.handler.writeFloatVector([Float](repeating: 1.0, count: 40))
        XCTAssertEqual(shmHeaderCount(f), sentinel, "writeFloatVector wrote past a 64-byte mapping")

        poisonShmHeader(f, sentinel)
        f.handler.writeDoubleVector([Double](repeating: 1.0, count: 12))
        XCTAssertEqual(shmHeaderCount(f), sentinel, "writeDoubleVector wrote past a 64-byte mapping")

        poisonShmHeader(f, sentinel)
        f.handler.writeResults((0..<12).map { ($0, UInt64(0), UInt8(0), UInt8(0)) })
        XCTAssertEqual(shmHeaderCount(f), sentinel, "writeResults wrote past a 64-byte mapping")
    }

    /// Audit finding 20 — `STREAM NEXT`'s and `RECORD SLICE`'s bound was a
    /// hardcoded `nodeCount * 3`, a restatement of the DEFAULT mapping's
    /// size. A `shmBytes:`-built handler shrinks the buffer and the bound
    /// stayed wide. The refusal must name the capacity, not the restatement.
    func testStreamNextAndRecordSliceBoundAgainstRealCapacity() throws {
        let f = try HandlerFixture(side: 4, shmBytes: 64)   // holds 7 u64s; nodeCount*3 = 48
        _ = f.handler.handle(
            "STREAM OPEN ref 0x853c49e6748fea9b 0xda3e39cb94b95bdb 0x5851f42d4c957f2d 0x14057b7ef767814f")
        let reply = f.handler.handle("STREAM NEXT s00000001 8")
        XCTAssertTrue(reply.hasPrefix("ERROR out_of_range:"), reply)
        XCTAssertTrue(reply.contains("64"), "the refusal must name the real capacity: \(reply)")
        XCTAssertEqual(shmHeaderCount(f), 0)
        XCTAssertTrue(f.handler.handle("STREAM NEXT s00000001 7").hasPrefix("OK STREAM NEXT"))

        _ = f.handler.handle(
            "RECORD OPEN court 1500 0.6827 3000 1.0 0.6827 0.00001 0 1 2 3 4")
        let sliceReply = f.handler.handle("RECORD SLICE t00000002 8")
        XCTAssertTrue(sliceReply.hasPrefix("ERROR out_of_range:"), sliceReply)
        XCTAssertTrue(sliceReply.contains("64"), sliceReply)
    }

    /// Audit finding 8 — a record minted under a roomy daemon and restored
    /// into a smaller one carries a payload this daemon's `nodeCount` never
    /// bounded. Two handlers, one shared `TwinState`, is exactly that shape.
    func testRecordReplayBoundsTheRestoredSliceAgainstCapacity() throws {
        let shared = TwinState()
        let big = try HandlerFixture(side: 8, twin: shared)          // 64 nodes, 1544 bytes
        _ = big.handler.handle("RECORD OPEN court 1500 0.6827 3000 1.0 0.6827 0.00001 0 1 2 3 4")
        XCTAssertTrue(big.handler.handle("RECORD SLICE t00000001 100").hasPrefix("OK RECORD SLICE"))

        let small = try HandlerFixture(side: 8, twin: shared, shmBytes: 64)
        let reply = small.handler.handle("RECORD REPLAY t00000001 0")
        XCTAssertTrue(reply.hasPrefix("ERROR out_of_range:"), reply)
        XCTAssertTrue(reply.contains("64"), reply)
        XCTAssertEqual(shmHeaderCount(small), 0)
    }

    /// Audit finding 6 — `TRAVERSE` appended one row per node PER DEPTH
    /// LEVEL with no global visited set, so the row count was Σ|frontier_d|
    /// and the mapping holds exactly `nodeCount` rows. The row count must be
    /// comparable to `(shmCapacityBytes - 8) / resultRowSize`, computed here
    /// from the fixture's own buffer, never from the handler's expression.
    func testTraverseRowCountStaysInsideTheMapping() throws {
        let f = try HandlerFixture(side: 8)      // 64 nodes
        // A connected chain 63 -> 62 -> ... -> 0, so the frontier really walks.
        for n in 1..<64 {
            _ = f.handler.handle("SET \(n) RANK \(n)")
        }
        for n in 1..<64 {
            XCTAssertTrue(f.handler.handle("CONNECT FROM \(n) TO \(n - 1)").hasPrefix("OK CONNECT"),
                          "fixture edge \(n)")
        }
        let capacityRows = (f.shmBytes - 8) / 24
        let reply = f.handler.handle("TRAVERSE FROM 0 DEPTH 63")
        XCTAssertTrue(reply.hasPrefix("OK TRAVERSE"), reply)
        guard let r = reply.range(of: "rows="),
              let space = reply.range(of: " ", range: r.upperBound..<reply.endIndex),
              let rows = Int(reply[r.upperBound..<space.lowerBound]) else {
            return XCTFail("no rows= in \(reply)")
        }
        XCTAssertLessThanOrEqual(rows, capacityRows,
                                 "TRAVERSE wrote \(rows) rows into a \(capacityRows)-row mapping")
        XCTAssertLessThanOrEqual(rows, f.handler.nodeCount)
    }

    // MARK: - D3 · wire arithmetic cannot trap

    /// Audit finding 23 — `nPockets * nTiers * 8` and
    /// `(nA + nB + kA + kB) * 4` are computed from unbounded signed `Int`s
    /// straight off the wire, and Swift TRAPS on `Int` overflow, so the
    /// capacity guard behind them never got to fire.
    func testBudgetOpenOverflowIsRefusedNotTrapped() throws {
        let f = try HandlerFixture(side: 4)
        let reply = f.handler.handle("BUDGET OPEN 4000000000 4000000000 0")
        XCTAssertTrue(reply.hasPrefix("ERROR out_of_range:"), reply)
        assertAlive(f)
    }

    func testXConvCheckOverflowIsRefusedNotTrapped() throws {
        let f = try HandlerFixture(side: 4)
        let huge = 2_305_843_009_213_693_951      // 2^61 - 1; ×4 overflows Int64
        for cmd in ["XCONV CHECK \(huge) 1 1 1 0",
                    "XCONV CHECK 1 \(huge) 1 1 0",
                    "XCONV CHECK 1 1 \(huge) 1 0",
                    "XCONV CHECK 1 1 1 \(huge) 0"] {
            let reply = f.handler.handle(cmd)
            XCTAssertTrue(reply.hasPrefix("ERROR out_of_range:"), "`\(cmd)` → \(reply)")
            assertAlive(f)
        }
    }

    // MARK: - D6 · the bulk installers refuse what they cannot validate

    /// Audit finding 12 — `SET_NEIGHBORS_BULK` read `nodeCount * 6 * 4`
    /// bytes at offset 8 without ever consulting the mapping's real size.
    func testSetNeighborsBulkRefusesWhenTheVectorDoesNotFit() throws {
        let f = try HandlerFixture(side: 4, shmBytes: 64)   // needs 8 + 16*6*4 = 392
        let reply = f.handler.handle("SET_NEIGHBORS_BULK")
        XCTAssertTrue(reply.hasPrefix("ERROR out_of_range:"), reply)
        XCTAssertTrue(reply.contains("64"), reply)
        assertAlive(f)
    }

    /// Audit finding 13 — no element was range-checked at all, so any
    /// `Int32` outside `[-1, nodeCount)` landed in `neighborsBuf` and was
    /// indexed by the Metal kernel. `SET_RANKS_BULK` already checked the
    /// whole vector before writing one word; this must too.
    func testSetNeighborsBulkRangeChecksTheWholeVectorBeforeWriting() throws {
        let f = try HandlerFixture(side: 4)
        let count = f.handler.nodeCount * 6
        let src = f.shm.advanced(by: 8).bindMemory(to: Int32.self, capacity: count)
        for i in 0..<count { src[i] = -1 }
        src[13] = Int32(f.handler.nodeCount + 1)        // node 2, dir 1
        src[40] = -2                                     // node 6, dir 4

        let reply = f.handler.handle("SET_NEIGHBORS_BULK")
        XCTAssertTrue(reply.hasPrefix("ERROR out_of_range:"), reply)
        XCTAssertTrue(reply.contains("13"), "the refusal must name the FIRST offending slot: \(reply)")
        XCTAssertTrue(reply.contains("17"), "and the offending value: \(reply)")
        XCTAssertTrue(reply.contains("-1..<16"), "and the true extent: \(reply)")

        // Nothing was written: every neighbour slot still holds the fixture's -1.
        let nb = f.handler.engine.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: count)
        for i in 0..<count {
            XCTAssertEqual(nb[i], -1, "slot \(i) was written despite the refusal")
        }
        assertAlive(f)
    }

    /// Audit finding 15 — the reply never said the rank-monotonicity
    /// invariant was skipped, so a caller could not know to re-check.
    func testBulkInstallersDiscloseTheInvariantTheySkipped() throws {
        let f = try HandlerFixture(side: 4)
        let ranks = f.shm.advanced(by: 8).bindMemory(to: UInt64.self, capacity: f.handler.nodeCount)
        for i in 0..<f.handler.nodeCount { ranks[i] = 0 }
        let reply = f.handler.handle("SET_RANKS_BULK")
        XCTAssertTrue(reply.hasPrefix("OK SET_RANKS_BULK nodes=16"), reply)
        XCTAssertTrue(reply.contains("validation=skipped"), reply)
        XCTAssertTrue(reply.contains("VALIDATE"), reply)
    }

    // MARK: - D7 · replies say what they omitted

    /// Audit finding 16 — `EVAL` ticks the whole graph but reports only
    /// rank-0 roots, and printed neither the scope nor the rank-bound
    /// suffix `TICK` prints through `rankWorkSuffix`.
    func testEvalDisclosesRootsScopeAndTheRankBound() throws {
        let f = try HandlerFixture(side: 8, maxRank: 4)   // 64 nodes, bound 4
        for n in 0..<8 { _ = f.handler.handle("SET \(n) RANK \(n)") }
        let reply = f.handler.handle("EVAL")
        XCTAssertTrue(reply.hasPrefix("OK EVAL rows="), reply)
        XCTAssertTrue(reply.contains("scope=roots"), reply)
        XCTAssertTrue(reply.contains("nodes_computed="), reply)
        // The graph's rank count (8) exceeds the configured bound (4), so the
        // same `ranks=/bound=` news TICK carries must appear here.
        let tickReply = f.handler.handle("TICK 1")
        XCTAssertTrue(tickReply.contains("bound=4"), tickReply)
        XCTAssertTrue(reply.contains("bound=4"), reply)
    }

    /// Audit finding 17 — `NODES` silently drops every rank-0, truth-0 node
    /// when no rank filter is given, and printed only `rows=`.
    func testNodesDisclosesWhatItsDefaultFilterDropped() throws {
        let f = try HandlerFixture(side: 4)              // 16 nodes, all rank 0 truth 0
        _ = f.handler.handle("SET 3 TRUTH 1")
        let reply = f.handler.handle("NODES")
        XCTAssertEqual(reply, "OK NODES rows=1 omitted=15", reply)
    }

    // MARK: - D8 · unbounded work refuses

    /// Audit finding 26 — `SIMILAR_DECISIONS` runs one backward BFS per
    /// candidate over all `nodeCount` candidates, with no work bound
    /// independent of `k`, on the single-threaded accept loop — and it sits
    /// on the web bridge's read-only allowlist.
    func testSimilarDecisionsRefusesAboveItsStatedCandidateCap() throws {
        // The cap is written out as a literal on purpose (the D9 lesson):
        // an expectation derived from the handler's own constant compares
        // the bound to itself and can never detect drift.
        let f = try HandlerFixture(side: 72)   // 5184 nodes > the 4096 cap
        XCTAssertGreaterThan(f.handler.nodeCount, 4096)
        let reply = f.handler.handle("SIMILAR_DECISIONS TO 0 DEPTH 1 K 3")
        XCTAssertTrue(reply.hasPrefix("ERROR out_of_range:"), reply)
        XCTAssertTrue(reply.contains("4096"), reply)
        assertAlive(f)
    }

    // MARK: - D9 · a TRAVERSE test exists

    /// There was no `TRAVERSE` test at all before this gate — the verb that
    /// trapped on a negative seed and overran the mapping on a deep walk was
    /// covered by nothing. This is the round-trip half; the bounds half is
    /// above.
    func testTraverseWalksTheFrontierAndReportsEachNodeOnce() throws {
        let f = try HandlerFixture(side: 4)
        // 3 -> 2 -> 1 -> 0, plus 3 -> 1 so node 1 is reachable at two depths.
        for n in 1..<4 { _ = f.handler.handle("SET \(n) RANK \(n)") }
        XCTAssertTrue(f.handler.handle("CONNECT FROM 1 TO 0").hasPrefix("OK CONNECT"))
        XCTAssertTrue(f.handler.handle("CONNECT FROM 2 TO 1").hasPrefix("OK CONNECT"))
        XCTAssertTrue(f.handler.handle("CONNECT FROM 3 TO 2").hasPrefix("OK CONNECT"))

        XCTAssertEqual(f.handler.handle("TRAVERSE FROM 0 DEPTH 0"),
                       "OK TRAVERSE rows=0 from=0 depth=0")
        XCTAssertEqual(f.handler.handle("TRAVERSE FROM 0 DEPTH 1"),
                       "OK TRAVERSE rows=1 from=0 depth=1")
        // Grid neighbours, not DAG edges, drive TRAVERSE's frontier; whatever
        // it reaches, no node may appear twice and no walk may outrun the map.
        let deep = f.handler.handle("TRAVERSE FROM 0 DEPTH 15")
        XCTAssertTrue(deep.hasPrefix("OK TRAVERSE"), deep)
        let rows = Int(shmHeaderCount(f))
        XCTAssertLessThanOrEqual(rows, f.handler.nodeCount)
        var ids = Set<UInt64>()
        for i in 0..<rows {
            let id = f.shm.advanced(by: 8 + i * 24).load(as: UInt64.self)
            XCTAssertTrue(ids.insert(id).inserted, "node \(id) appears twice in one TRAVERSE")
        }
    }
}
