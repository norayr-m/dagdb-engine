import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// EVAL refuses a graph that fails rank order.
///
/// EVAL ticks in rank mode (the colour path), so on a graph whose edges rank
/// mode cannot order (a same-rank edge, a rank inversion, a self-loop slot)
/// it asks the cached verdict rank-mode TICK asks and refuses in TICK's
/// words, only the verb changed. Each case builds two identical handlers
/// (the valid graph of `EngineE1DaemonTests.buildGraph` with the violations written into its slots, a WAL on
/// each) and sends both the same lines. Every EVAL must reply the refusal,
/// dispatch nothing, and leave the truth bytes, the tick count, the WAL file
/// and the result-row buffer as they were; the twins' replies and truth bytes
/// must be equal.
final class EngineEVAL1DaemonTests: XCTestCase {

    typealias E1 = EngineE1DaemonTests
    typealias E3 = EngineE3DaemonTests
    typealias Rng = EngineE1DaemonTests.Rng

    enum Kind: String { case sameRank, inversion, selfLoop }

    struct Case {
        let side: Int, ternary: Bool, name: String
        let kinds: [(Kind, Int)]
    }

    var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "eval1-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    /// The expected refusal, for violation `why`.
    static func refusal(_ why: String) -> String {
        "ERROR invalid_graph: EVAL refused, validation: \(why) (VALIDATE names it; TICK_SYNC is defined on this graph)"
    }

    /// The valid graph of `EngineE1DaemonTests.buildGraph` at `side`, a WAL under `tmp`, then the violations of
    /// `c` written into the slots (distinct destinations, ranks 0-6: no
    /// register). A same-rank source is taken from the destination's own hex
    /// colour where there is one, so the colour path reads it while it is
    /// written. Returns the fixture and the destinations written.
    func build(_ c: Case, twin: String, seed: UInt64) throws -> (HandlerFixture, [Int]) {
        let n = c.side * c.side
        let wal = try DagDBWAL.Appender(path: "\(tmp!)/\(c.name)-\(twin).wal", nodeCount: n)
        let f = try HandlerFixture(side: c.side, wal: wal)
        let e = f.handler.engine
        try E1.buildGraph(e, seed: seed, ternary: c.ternary)
        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        var colour = [Int](repeating: 0, count: n)
        for (k, group) in e.grid.colorGroups.enumerated() { for m in group { colour[Int(m)] = k } }
        let block = (n + 7) / 8
        var g = Rng(s: seed &* 0x5851_F42D &+ 0xE7A1)
        var used = Set<Int>()
        var dsts: [Int] = []
        func pickDst(minRank: Int) -> Int {
            while true {
                let d = minRank * block + g.below(7 * block - minRank * block)
                if d < n && !e.isRegister(node: UInt32(d)) && used.insert(d).inserted { return d }
            }
        }
        for (kind, count) in c.kinds {
            for _ in 0..<count {
                let slot = g.below(6)
                switch kind {
                case .selfLoop:
                    let d = pickDst(minRank: 0)
                    nb[d * 6 + slot] = Int32(d); dsts.append(d)
                case .sameRank:
                    let d = pickDst(minRank: 0)
                    let r = Int(rank[d]), lo = r * block, hi = min(n, lo + block)
                    let same = (lo..<hi).filter { $0 != d && colour[$0] == colour[d] }
                    let any = (lo..<hi).filter { $0 != d }
                    let pool = same.isEmpty ? any : same
                    nb[d * 6 + slot] = Int32(pool[g.below(pool.count)]); dsts.append(d)
                case .inversion:
                    let d = pickDst(minRank: 1)
                    let s = g.below(Int(rank[d]) * block)
                    XCTAssertLessThan(rank[s], rank[d])
                    nb[d * 6 + slot] = Int32(s); dsts.append(d)
                }
            }
        }
        return (f, dsts)
    }

    static var cases: [Case] {
        var out: [Case] = []
        for side in [8, 16, 32, 64] {
            for ternary in [false, true] {
                let t = ternary ? "t" : "b"
                out.append(Case(side: side, ternary: ternary, name: "same\(side)\(t)", kinds: [(.sameRank, 1)]))
                out.append(Case(side: side, ternary: ternary, name: "inv\(side)\(t)", kinds: [(.inversion, 1)]))
                out.append(Case(side: side, ternary: ternary, name: "self\(side)\(t)", kinds: [(.selfLoop, 1)]))
                out.append(Case(side: side, ternary: ternary, name: "mixed\(side)\(t)",
                                kinds: [(.inversion, 3), (.selfLoop, 3), (.sameRank, 3)]))
                out.append(Case(side: side, ternary: ternary, name: "many\(side)\(t)",
                                kinds: [(.sameRank, side * side / 16), (.inversion, 2), (.selfLoop, 2)]))
            }
        }
        return out
    }

    func walBytes(_ f: HandlerFixture) -> Data? {
        guard let w = f.handler.walAppender else { return nil }
        w.barrier()
        return FileManager.default.contents(atPath: w.path)
    }

    func shmBytes(_ f: HandlerFixture) -> Data { Data(bytes: f.shm, count: f.shmBytes) }

    func testV1_1EvalRefusesARankOrderFailureInTicksWords() throws {
        let lines = ["EVAL", "EVAL WHERE truth=1", "TICK 1", "EVAL", "EVAL RANK 0 TO 3",
                     "TICK UNTIL_STABLE MAX 3", "EVAL"]
        var cases = 0, evals = 0, refused = 0, replyMismatches = 0, truthDiffBytes = 0, repaired = 0
        var kindsSeen = Set<String>()
        for (k, c) in Self.cases.enumerated() {
            let seed = UInt64(0xE7A1_0000) &+ UInt64(k)
            let (fa, dsts) = try build(c, twin: "A", seed: seed)
            let (fb, _) = try build(c, twin: "B", seed: seed)
            let a = fa.handler.engine
            // The object can fail the test: it fails rank order, by the intended kind.
            let why = try XCTUnwrap(DagDBSnapshot.rankOrderViolation(engine: a, nodeCount: a.nodeCount), c.name)
            if c.kinds.count == 1 {
                switch c.kinds[0].0 {
                case .selfLoop: XCTAssertTrue(why.hasSuffix(": self-loop"), "\(c.name): \(why)")
                case .sameRank, .inversion:
                    let num = why.replacingOccurrences(of: ":", with: " ").split(separator: " ").compactMap { UInt64($0) }
                    XCTAssertEqual(num.count, 4, "\(c.name): \(why)")   // node, slot, src rank, dst rank
                    if num.count == 4 {
                        if c.kinds[0].0 == .sameRank { XCTAssertEqual(num[2], num[3], "\(c.name): \(why)") }
                        else { XCTAssertLessThan(num[2], num[3], "\(c.name): \(why)") }
                    }
                }
            }
            kindsSeen.insert(why.hasSuffix("self-loop") ? "self-loop" : "rank")
            // A logged write first, so the WAL holds records; a pattern in the result rows.
            for f in [fa, fb] {
                XCTAssertTrue(f.handler.handle("SET 0 TRUTH 1").hasPrefix("OK"), c.name)
                memset(f.shm, 0xA5, f.shmBytes)
            }
            let truth0 = a.readTruthStates()
            XCTAssertEqual(truth0, fb.handler.engine.readTruthStates(), c.name)
            let wal0 = (walBytes(fa), walBytes(fb)), shm0 = shmBytes(fa)
            XCTAssertNotNil(wal0.0); XCTAssertEqual(wal0.0, wal0.1, c.name)
            XCTAssertGreaterThan(wal0.0?.count ?? 0, 0, "\(c.name): the WAL holds records")
            var tickReply: String?
            for line in lines {
                var replies: [String] = []
                for f in [fa, fb] {
                    let e = f.handler.engine
                    e.lastRankTickDispatchCount = -1                       // a sentinel: any tick overwrites it
                    let r = f.handler.handle(line)
                    replies.append(r)
                    if line.hasPrefix("EVAL") {
                        evals += 1
                        if r == Self.refusal(why) { refused += 1 }
                        // The RANK clause is refused at parse time, before the verdict.
                        XCTAssertEqual(r, line == "EVAL RANK 0 TO 3" ? EngineEVAL2DaemonTests.rankClauseRefusal
                                                                     : Self.refusal(why), "\(c.name) \(line)")
                        XCTAssertEqual(e.lastRankTickDispatchCount, -1, "\(c.name) \(line): nothing dispatched")
                        XCTAssertEqual(f.handler.tickCount, 0, "\(c.name) \(line): the tick count unchanged")
                        XCTAssertEqual(e.readTruthStates(), truth0, "\(c.name) \(line): the truth bytes unchanged")
                        XCTAssertEqual(walBytes(f), f === fa ? wal0.0 : wal0.1, "\(c.name) \(line): the WAL unchanged")
                        XCTAssertEqual(shmBytes(f), shm0, "\(c.name) \(line): no rows written")
                    } else {
                        XCTAssertTrue(r.hasPrefix("ERROR invalid_graph: rank-mode TICK refused, validation: \(why) "),
                                      "\(c.name) \(line): \(r)")
                        if line == "TICK 1" { tickReply = r }
                    }
                }
                if replies[0] != replies[1] { replyMismatches += 1 }
                XCTAssertEqual(replies[0], replies[1], "\(c.name) \(line): the twins' replies")
                let d = zip(a.readTruthStates(), fb.handler.engine.readTruthStates()).filter { $0 != $1 }.count
                truthDiffBytes += d
                XCTAssertEqual(d, 0, "\(c.name) \(line): the twins' truth bytes")
            }
            // TICK's words, only the verb changed.
            if let t = tickReply {
                XCTAssertEqual(Self.refusal(why),
                               t.replacingOccurrences(of: "rank-mode TICK refused", with: "EVAL refused"), c.name)
            }
            // TICK_SYNC is defined on this graph (as the refusal says); EVAL after it still refuses.
            for f in [fa, fb] {
                let r = f.handler.handle("TICK_SYNC 1")
                XCTAssertTrue(r.hasPrefix("OK TICK_SYNC 1 "), "\(c.name): \(r)")
                let t1 = f.handler.engine.readTruthStates(), w1 = walBytes(f)
                f.handler.engine.lastRankTickDispatchCount = -1
                let ev = f.handler.handle("EVAL")
                evals += 1
                if ev == Self.refusal(why) { refused += 1 }
                XCTAssertEqual(ev, Self.refusal(why), "\(c.name): EVAL after TICK_SYNC")
                XCTAssertEqual(f.handler.engine.lastRankTickDispatchCount, -1, c.name)
                XCTAssertEqual(f.handler.tickCount, 1, "\(c.name): EVAL after TICK_SYNC left the count at 1")
                XCTAssertEqual(f.handler.engine.readTruthStates(), t1, c.name)
                XCTAssertEqual(walBytes(f), w1, c.name)
            }
            let d1 = zip(a.readTruthStates(), fb.handler.engine.readTruthStates()).filter { $0 != $1 }.count
            truthDiffBytes += d1
            XCTAssertEqual(d1, 0, "\(c.name): the twins after TICK_SYNC")
            // One violation, repaired by CLEAR (a slot writer drops the verdict): EVAL runs again,
            // through the colour path.
            if c.kinds.count == 1 && c.kinds[0].1 == 1 {
                var rs: [String] = []
                for f in [fa, fb] {
                    XCTAssertTrue(f.handler.handle("CLEAR \(dsts[0]) EDGES").hasPrefix("OK"), c.name)
                    let e = f.handler.engine
                    XCTAssertNil(DagDBSnapshot.rankOrderViolation(engine: e, nodeCount: e.nodeCount), c.name)
                    let r = f.handler.handle("EVAL")
                    rs.append(r)
                    XCTAssertTrue(r.hasPrefix("OK EVAL rows="), "\(c.name) after the repair: \(r)")
                    XCTAssertEqual(e.lastRankTickDispatchCount, E3.nonEmptySegments(e), "\(c.name): the colour path")
                    XCTAssertEqual(f.handler.tickCount, 2, c.name)
                }
                XCTAssertEqual(rs[0], rs[1], c.name)
                XCTAssertEqual(a.readTruthStates(), fb.handler.engine.readTruthStates(), "\(c.name) after the repair")
                repaired += 1
            }
            cases += 1
        }
        XCTAssertEqual(kindsSeen, ["self-loop", "rank"])
        print("EVAL1 V1.1: \(cases) cases (8²-64², binary and ternary; same-rank, inversion, self-loop alone, "
              + "mixed, many), \(evals) EVALs, \(refused) refused in TICK's words; twins: reply mismatches "
              + "\(replyMismatches), truth bytes differing \(truthDiffBytes); repaired and EVAL OK again: \(repaired)")
    }
}
