import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// EVAL's RANK clause is refused by name, never silently ignored.
///
/// EVAL reports the rank-0 roots (`scope=roots`), so a rank range on its rows
/// is trivial, and the meant scope change is new semantics: the parser
/// refuses every RANK form by name, before anything runs, on valid and invalid
/// graphs alike. Each graph is one of `EngineE1DaemonTests.buildGraph` (8², 16², binary and ternary), valid as
/// built or with one same-rank edge written into a slot (rank-mode TICK and
/// EVAL refuse it), a WAL on each. Every RANK form must reply the
/// refusal and leave the dispatch sentinel, the tick count, the truth bytes,
/// the WAL file and the result-row buffer as they were. A spaced WHERE
/// predicate on the rank field (`WHERE rank = 0`) is not the clause.
final class EngineEVAL2DaemonTests: XCTestCase {

    typealias E1 = EngineE1DaemonTests

    /// The expected refusal: the parser's existing category for an
    /// unsupported clause (`dsl_parse`), the way out named.
    static let rankClauseRefusal =
        "ERROR dsl_parse: EVAL takes no RANK clause: EVAL reports the rank-0 roots (scope=roots), "
        + "and NODES AT RANK <n> [WHERE <field><op><value>] reads other ranks; nothing ran"

    /// Every RANK form: a ≤ b, a > b, a = b; RANK a without TO;
    /// RANK alone; non-numeric bounds; RANK before WHERE and after it.
    static let rankForms = [
        "EVAL RANK 0 TO 3", "EVAL RANK 2 TO 5",                         // a < b
        "EVAL RANK 9 TO 0", "EVAL RANK 3 TO 1",                         // a > b
        "EVAL RANK 0 TO 0", "EVAL RANK 4 TO 4",                         // a = b
        "EVAL RANK 0", "EVAL RANK 7",                                   // without TO
        "EVAL RANK",                                                    // alone
        "EVAL RANK x TO y", "EVAL RANK 0 TO z", "EVAL RANK a", "EVAL RANK TO 3", "EVAL RANK 0 TO",
        "EVAL RANK 1.5 TO 2",                                           // non-numeric bounds
        "EVAL RANK 0 TO 3 WHERE truth=1", "EVAL RANK 2 WHERE truth=0",  // before WHERE
        "EVAL WHERE truth=1 RANK 0 TO 3", "EVAL WHERE rank=0 RANK 0 TO 0",
        "EVAL WHERE truth = 1 RANK 9 TO 0", "EVAL WHERE rank = 0 RANK 1 TO 2",
        "EVAL WHERE RANK 0 TO 3",                                       // after WHERE
        "eval rank 0 to 3", "  EVAL   RANK  0  TO  3  ",                // case and spacing
    ]

    var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "eval2-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    func walBytes(_ f: HandlerFixture) -> Data? {
        guard let w = f.handler.walAppender else { return nil }
        w.barrier()
        return FileManager.default.contents(atPath: w.path)
    }

    func testX1EveryRankFormIsRefusedByNameAndNothingRuns() throws {
        var graphs = 0, sent = 0, refused = 0
        for side in [8, 16] {
            for ternary in [false, true] {
                for invalid in [false, true] {
                    let name = "s\(side)\(ternary ? "t" : "b")\(invalid ? "-bad" : "-ok")"
                    let n = side * side
                    let wal = try DagDBWAL.Appender(path: "\(tmp!)/\(name).wal", nodeCount: n)
                    let f = try HandlerFixture(side: side, wal: wal)
                    let e = f.handler.engine
                    try E1.buildGraph(e, seed: 0xE7A2_0000 &+ UInt64(n) &+ (ternary ? 1 : 0), ternary: ternary)
                    if invalid {
                        // A same-rank edge: node 5 feeds node 3, both at rank 0.
                        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
                        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
                        XCTAssertEqual(rank[3], rank[5], name)
                        nb[3 * 6 + 5] = 5
                    }
                    // The object can fail the test: valid or not, by its own verdict.
                    let why = DagDBSnapshot.rankOrderViolation(engine: e, nodeCount: n)
                    XCTAssertEqual(why != nil, invalid, "\(name): \(why ?? "valid")")
                    // A tick and a logged write first: the tick count, the WAL and the truth are not empty.
                    XCTAssertTrue(f.handler.handle("TICK_SYNC 1").hasPrefix("OK TICK_SYNC 1 "), name)
                    XCTAssertTrue(f.handler.handle("SET 0 TRUTH 1").hasPrefix("OK"), name)
                    memset(f.shm, 0xA5, f.shmBytes)
                    let truth0 = e.readTruthStates(), wal0 = walBytes(f)
                    let shm0 = Data(bytes: f.shm, count: f.shmBytes)
                    XCTAssertGreaterThan(wal0?.count ?? 0, 0, "\(name): the WAL holds records")
                    XCTAssertEqual(f.handler.tickCount, 1, name)
                    for line in Self.rankForms {
                        e.lastRankTickDispatchCount = -1                       // a sentinel: any tick overwrites it
                        let r = f.handler.handle(line)
                        sent += 1
                        if r == Self.rankClauseRefusal { refused += 1 }
                        XCTAssertEqual(r, Self.rankClauseRefusal, "\(name) '\(line)'")
                        XCTAssertEqual(e.lastRankTickDispatchCount, -1, "\(name) '\(line)': nothing dispatched")
                        XCTAssertEqual(f.handler.tickCount, 1, "\(name) '\(line)': the tick count unchanged")
                        XCTAssertEqual(e.readTruthStates(), truth0, "\(name) '\(line)': the truth bytes unchanged")
                        XCTAssertEqual(walBytes(f), wal0, "\(name) '\(line)': no WAL byte")
                        XCTAssertEqual(Data(bytes: f.shm, count: f.shmBytes), shm0, "\(name) '\(line)': no rows written")
                    }
                    // In a reader session too: the parse refuses before the session's own refusal.
                    let open = f.handler.handle("OPEN_READER")
                    let id = try XCTUnwrap(open.split(separator: " ").first { $0.hasPrefix("id=") }?.dropFirst(3), open)
                    XCTAssertEqual(f.handler.handle("READER \(id) EVAL RANK 0 TO 3"), Self.rankClauseRefusal, name)
                    XCTAssertEqual(f.handler.handle("READER \(id) EVAL"),
                                   "ERROR forbidden: EVAL not allowed in reader session (ticks mutate)", name)
                    XCTAssertTrue(f.handler.handle("CLOSE_READER \(id)").hasPrefix("OK"), name)
                    // Not the clause: a spaced WHERE predicate on the rank field. Plain EVAL is unchanged after
                    // the refusals: it runs on the valid graph and gives its rank-order refusal on the invalid one.
                    for line in ["EVAL WHERE rank = 0", "EVAL WHERE rank=0", "EVAL"] {
                        let r = f.handler.handle(line)
                        if let w = why {
                            XCTAssertTrue(r.hasPrefix("ERROR invalid_graph: EVAL refused, validation: \(w) "),
                                          "\(name) '\(line)': \(r)")
                        } else {
                            XCTAssertTrue(r.hasPrefix("OK EVAL rows="), "\(name) '\(line)': \(r)")
                        }
                    }
                    XCTAssertEqual(f.handler.tickCount, invalid ? 1 : 4, name)
                    graphs += 1
                }
            }
        }
        XCTAssertEqual(refused, sent)
        print("EVAL2 X1: \(graphs) graphs (8², 16², binary and ternary, valid and with a same-rank edge), "
              + "\(Self.rankForms.count) RANK forms each, \(sent) sent, \(refused) refused by name with nothing run")
    }
}
