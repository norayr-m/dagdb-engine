import XCTest
import Metal
@testable import DagDB
@testable import DagDBDaemonKit

/// C1 control gate + C12(i) — `docs/contracts/CORE_DURABILITY_GATES_FROZEN.md`.
///
/// A graph is built through EVERY mutating verb the DSL parser has, with the
/// WAL on; the daemon is discarded without SAVE; the log alone is replayed
/// into a fresh engine. The replayed buffers are then compared against
/// **values this test set** — literals and a seeded formula written down
/// here — and never against a live engine the same code produced. Comparing
/// two engines would let one bug cancel another: the writer and the replayer
/// share the buffer layout, the opcode table and the apply path.
final class CoreDurabilityC1Tests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-c1-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - the expectation, written down rather than read back

    /// Every persisted lane, as the test says it should be after replay.
    /// Built by this file, mutated by this file alongside each command.
    private struct Expected {
        var truth: [UInt8]
        var rank: [UInt64]
        var lut: [UInt64]              // joined; split on comparison
        var neighbors: [Int32]
        var edgeWeights: [Float]
        var nodeValue: [Float]
        var isRegister: [UInt8]
        var backEdgeSrcs: [UInt32]
        var backEdgeDsts: [UInt32]
        /// No DSL verb writes these two, so the WAL carries no record for
        /// them and a log-only replay must leave them at a fresh engine's
        /// defaults. The source engine sets them NON-default through the
        /// library below, so this comparison can actually fail: if replay
        /// ever grew a path that carried them, these would come back set.
        var nodeType: [UInt8]
        var activation: [Int16]

        init(n: Int) {
            truth = [UInt8](repeating: 0, count: n)
            rank = [UInt64](repeating: 0, count: n)
            lut = [UInt64](repeating: 0, count: n)
            neighbors = [Int32](repeating: -1, count: n * 6)
            edgeWeights = [Float](repeating: 1.0, count: n * 6)
            nodeValue = [Float](repeating: 0.0, count: n)
            isRegister = [UInt8](repeating: 0, count: n)
            backEdgeSrcs = []
            backEdgeDsts = []
            nodeType = [UInt8](repeating: 0, count: n)
            activation = [Int16](repeating: 0, count: n)
        }
    }

    /// The seeded formula the bulk LUT install uses. Written here, sent to
    /// the daemon from here, and expected back from here.
    private func seededLUT(_ i: Int) -> UInt64 {
        0x0F0F_0F0F_0F0F_0F0F &+ UInt64(i) &* 0x0001_0001_0001_0001
    }

    private func read<T>(_ b: MTLBuffer, _ t: T.Type, _ count: Int) -> [T] {
        let p = b.contents().bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: p, count: count))
    }

    /// Compare one lane against the expectation, naming the lane and the
    /// first disagreeing slot.
    private func check<T: Equatable>(_ name: String, _ actual: [T], _ expected: [T],
                                     _ note: String = "") -> String? {
        if actual.count != expected.count {
            return "\(name): count \(actual.count) vs expected \(expected.count)"
        }
        var bad = 0
        var first = -1
        for i in 0..<actual.count where actual[i] != expected[i] {
            bad += 1
            if first < 0 { first = i }
        }
        guard bad > 0 else { return nil }
        return "\(name): \(bad) slot(s) differ, first at \(first) " +
               "(replayed \(actual[first]) vs expected \(expected[first]))\(note)"
    }

    // MARK: - the control

    func testEveryMutatingVerbSurvivesReplayFromTheLogAlone() throws {
        let side = 8
        let n = side * side
        let walPath = tmpDir! + "c1_control.log"

        var exp = Expected(n: n)
        var commandsIssued = 0
        /// One entry per distinct mutating form the parser accepts, so the
        /// count printed below is coverage and not just a tally of lines.
        var formsCovered = Set<String>()

        do {
            let appender = try DagDBWAL.Appender(path: walPath, nodeCount: n)
            let f = try HandlerFixture(side: side, wal: appender, maxRank: 8)

            /// Issue a command, require OK, and record the form it exercised.
            func issue(_ form: String, _ line: String) {
                let reply = f.handler.handle(line)
                XCTAssertTrue(reply.hasPrefix("OK"), "\(line) -> \(reply)")
                commandsIssued += 1
                formsCovered.insert(form)
            }

            // ── the two lanes no verb can write, set through the library ──
            // so their expectation (a fresh engine's defaults) is a real
            // comparison rather than zero-versus-zero.
            let srcType = f.handler.engine.nodeTypeBuf.contents()
                .bindMemory(to: UInt8.self, capacity: n)
            let srcAct = f.handler.engine.activationBuf.contents()
                .bindMemory(to: Int16.self, capacity: n)
            for i in 0..<n {
                srcType[i] = UInt8(1 + i % 2)          // 1 or 2, never the default 0
                srcAct[i] = Int16(-1 - (i % 100))      // never the default 0
            }

            // ── bulk installs ───────────────────────────────────────────
            let nbSrc = f.shm.advanced(by: 8).bindMemory(to: Int32.self, capacity: n * 6)
            for i in 0..<(n * 6) { nbSrc[i] = -1 }
            issue("SET_NEIGHBORS_BULK", "SET_NEIGHBORS_BULK")
            // expectation: already all -1

            let rkSrc = f.shm.advanced(by: 8).bindMemory(to: UInt64.self, capacity: n)
            for i in 0..<n { rkSrc[i] = UInt64(i % 8) }
            issue("SET_RANKS_BULK", "SET_RANKS_BULK")
            for i in 0..<n { exp.rank[i] = UInt64(i % 8) }

            let ltSrc = f.shm.advanced(by: 8).bindMemory(to: UInt64.self, capacity: n)
            for i in 0..<n { ltSrc[i] = seededLUT(i) }
            issue("SET_LUTS_BULK", "SET_LUTS_BULK")
            for i in 0..<n { exp.lut[i] = seededLUT(i) }

            // ── per-record verbs ────────────────────────────────────────
            issue("SET RANK", "SET 3 RANK 5");            exp.rank[3] = 5
            issue("SET TRUTH", "SET 3 TRUTH 1");          exp.truth[3] = 1
            issue("SET LUT", "SET 4 LUT OR");             exp.lut[4] = LUT6Preset.or6
            issue("SET WEIGHT", "SET 5 WEIGHT 2 0.25");   exp.edgeWeights[5 * 6 + 2] = 0.25
            issue("SET VALUE", "SET 6 VALUE 1.5");        exp.nodeValue[6] = 1.5

            // ── combinational edges ─────────────────────────────────────
            // rank[15] = 7 > rank[8] = 0; rank[31] = 7 > rank[9] = 1.
            issue("CONNECT", "CONNECT FROM 15 TO 8");     exp.neighbors[8 * 6 + 0] = 15
            issue("CONNECT", "CONNECT FROM 23 TO 8");     exp.neighbors[8 * 6 + 1] = 23
            issue("CONNECT", "CONNECT FROM 31 TO 9");     exp.neighbors[9 * 6 + 0] = 31
            issue("CLEAR EDGES", "CLEAR 9 EDGES")
            for d in 0..<6 { exp.neighbors[9 * 6 + d] = -1 }
            issue("CONNECT", "CONNECT FROM 39 TO 9");     exp.neighbors[9 * 6 + 0] = 39

            // ── back edges, including the clear the old control missed ──
            issue("CONNECT BACK", "CONNECT BACK FROM 11 TO 12")
            exp.backEdgeSrcs.append(11); exp.backEdgeDsts.append(12)
            exp.isRegister[12] = 1
            issue("CONNECT BACK", "CONNECT BACK FROM 13 TO 14")
            exp.backEdgeSrcs.append(13); exp.backEdgeDsts.append(14)
            exp.isRegister[14] = 1
            issue("CLEAR BACK_EDGES", "CLEAR 14 BACK_EDGES")
            exp.backEdgeSrcs.removeAll { $0 == 13 }
            exp.backEdgeDsts.removeAll { $0 == 14 }
            exp.isRegister[14] = 0

            // ── COMPOSE, the other form the old control missed ──────────
            // Each form WALs the resulting SET_LUT for its destination.
            issue("COMPOSE NOT", "COMPOSE NOT 20 INTO 21")
            exp.lut[21] = ~exp.lut[20]
            issue("COMPOSE AND", "COMPOSE AND 20 22 INTO 23")
            exp.lut[23] = exp.lut[20] & exp.lut[22]
            issue("COMPOSE OR", "COMPOSE OR 24 25 INTO 26")
            exp.lut[26] = exp.lut[24] | exp.lut[25]
            issue("COMPOSE XOR", "COMPOSE XOR 27 28 INTO 29")
            exp.lut[29] = exp.lut[27] ^ exp.lut[28]

            appender.barrier()

            // Every mutating form the parser accepts must be represented.
            let parserMutatingForms: Set<String> = [
                "SET TRUTH", "SET RANK", "SET LUT", "SET WEIGHT", "SET VALUE",
                "CLEAR EDGES", "CLEAR BACK_EDGES", "CONNECT", "CONNECT BACK",
                "SET_RANKS_BULK", "SET_LUTS_BULK", "SET_NEIGHBORS_BULK",
                "COMPOSE NOT", "COMPOSE AND", "COMPOSE OR", "COMPOSE XOR",
            ]
            XCTAssertEqual(formsCovered, parserMutatingForms,
                           "missed: \(parserMutatingForms.subtracting(formsCovered)); " +
                           "unexpected: \(formsCovered.subtracting(parserMutatingForms))")
            print("C1CONTROL commands_issued=\(commandsIssued) " +
                  "mutating_forms_covered=\(formsCovered.count)/\(parserMutatingForms.count)")
        }

        // Daemon discarded without SAVE — the log is all there is.
        let grid = try HexGrid(width: side, height: side)
        let fresh = try DagDBEngine(grid: grid, state: DagDBState(width: side, height: side),
                                    maxRank: 8)
        let r = try DagDBWAL.replay(engine: fresh, nodeCount: n, path: walPath)

        // ── compare against the values written down above ───────────────
        let lutLow = read(fresh.lut6LowBuf, UInt32.self, n)
        let lutHigh = read(fresh.lut6HighBuf, UInt32.self, n)
        let joinedLUT = (0..<n).map { UInt64(lutHigh[$0]) << 32 | UInt64(lutLow[$0]) }

        var diffs: [String] = []
        for d in [
            check("truth", read(fresh.truthStateBuf, UInt8.self, n), exp.truth),
            check("rank", read(fresh.rankBuf, UInt64.self, n), exp.rank),
            check("lut", joinedLUT, exp.lut),
            check("neighbors", read(fresh.neighborsBuf, Int32.self, n * 6), exp.neighbors),
            check("edgeWeights", read(fresh.edgeWeightsBuf, Float.self, n * 6), exp.edgeWeights),
            check("nodeValue", read(fresh.nodeValueBuf, Float.self, n), exp.nodeValue),
            check("isRegister", read(fresh.isRegisterBuf, UInt8.self, n), exp.isRegister),
            check("backEdgeSrcs", fresh.backEdgeSrcs, exp.backEdgeSrcs),
            check("backEdgeDsts", fresh.backEdgeDsts, exp.backEdgeDsts),
            check("nodeType", read(fresh.nodeTypeBuf, UInt8.self, n), exp.nodeType,
                  " — no DSL verb writes nodeType, so the WAL carries no record " +
                  "for it and a log-only replay must leave it at the fresh " +
                  "engine's default; the source engine held 1/2 here"),
            check("activation", read(fresh.activationBuf, Int16.self, n), exp.activation,
                  " — no DSL verb writes activation, so the WAL carries no " +
                  "record for it and a log-only replay must leave it at the " +
                  "fresh engine's default; the source engine held negatives here"),
        ] { if let d = d { diffs.append(d) } }

        XCTAssertTrue(diffs.isEmpty,
                      "replay from the WAL alone did not reproduce the values this " +
                      "test set:\n" + diffs.joined(separator: "\n") +
                      "\n(records applied: \(r.recordsApplied), skipped: \(r.recordsSkipped))")
        XCTAssertEqual(r.recordsSkipped, 0)
    }
}
