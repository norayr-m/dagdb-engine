import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// One mode-write checker for live writes and replay.
///
/// One mode-write checker, `TernaryReference.modeWriteRefusal`, whose context
/// (`.live` or `.replay`) selects only the words of a refusal, never the
/// verdict: replay applies every rule live applies. The
/// command handler (SET MODE, SET_MODES_BULK) and WAL replay (SET_MODE,
/// SET_MODES_BULK records) both call it.
///
/// The case table: every mode-write rule — the mode byte (reserved bits 3–7,
/// kind 3, NOSKIP on BINARY), a ternary kind on a truth byte ≥ 3, on a
/// register, TTABLE on an id not below the library size — with its boundaries, the
/// order in which a node breaking several rules is named, and legal writes.
/// Each case is set up through the daemon's own verbs (what a live session can
/// reach), then the mode write goes three ways:
///   handler  the live verb (SET MODE where the DSL can say the byte, and
///            SET_MODES_BULK always), on that session;
///   replay   that session's WAL with the mode record appended by hand (single
///            SET_MODE and bulk SET_MODES_BULK), replayed into a fresh engine;
///   checker  the function itself, in both contexts, on the session's state.
/// Verdicts must be identical on all three paths and in both contexts, and
/// equal to the one written down here from the ternary rules. The words: the
/// handler's reply is `ERROR bad_value: ternary: ` + the live words, replay's
/// refusal ends with the replay words, and both are the texts each path gave
/// before the checker existed (written down below, and pinned by other
/// tests).
final class TernaryA9DaemonTests: XCTestCase {

    private var root: String!
    private let side = 8
    private var n: Int { side * side }
    private let node = 10

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "tern-a9d-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = root { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - The table

    enum Rule: String { case modeByte, truth, register, ttable }

    struct Case {
        let label: String
        let setup: [String]
        let mode: UInt8
        let rule: Rule?          // written down from the ternary rules
        /// For a mode-byte refusal: a phrase of the mode-byte refusal it must carry.
        var phrase: String? = nil
    }

    private static let lib = ["TTABLE PRESET 0 TMIN 2"]
    private static let cases: [Case] = [
        // The mode byte: refused whatever the node holds.
        Case(label: "reserved bit 3", setup: [], mode: 0x08, rule: .modeByte, phrase: "reserved bits 3-7"),
        Case(label: "reserved bit 7", setup: [], mode: 0x80, rule: .modeByte, phrase: "reserved bits 3-7"),
        Case(label: "reserved bits on TTABLE", setup: lib, mode: 0xF9, rule: .modeByte, phrase: "reserved bits 3-7"),
        Case(label: "kind 3", setup: [], mode: 0x03, rule: .modeByte, phrase: "kind 3, which is not a kind"),
        Case(label: "kind 3 + NOSKIP", setup: [], mode: 0x07, rule: .modeByte, phrase: "kind 3, which is not a kind"),
        Case(label: "NOSKIP on BINARY", setup: [], mode: 0x04, rule: .modeByte, phrase: "NOSKIP on a BINARY node"),
        // The truth byte (a ternary kind needs 0, 1 or 2).
        Case(label: "truth 200, TTABLE", setup: lib + ["SET 10 TRUTH 200"], mode: 1, rule: .truth),
        Case(label: "truth 200, TTHRESH NOSKIP", setup: ["SET 10 TRUTH 200"], mode: 6, rule: .truth),
        Case(label: "truth 3, TTHRESH (boundary)", setup: ["SET 10 TRUTH 3"], mode: 2, rule: .truth),
        Case(label: "truth 2, TTHRESH (boundary)", setup: ["SET 10 TRUTH 2"], mode: 2, rule: nil),
        Case(label: "truth 200, BINARY", setup: ["SET 10 TRUTH 200"], mode: 0, rule: nil),
        // The register (a BACK_EDGE destination stays BINARY).
        Case(label: "register, TTHRESH", setup: lib + ["CONNECT BACK FROM 3 TO 10"], mode: 2, rule: .register),
        Case(label: "register, TTABLE NOSKIP", setup: lib + ["CONNECT BACK FROM 3 TO 10"], mode: 5, rule: .register),
        Case(label: "register, BINARY", setup: ["CONNECT BACK FROM 3 TO 10"], mode: 0, rule: nil),
        // The table id (TTABLE names a defined table; the library is dense, so
        // the one reachable miss is id 0 against an empty library).
        Case(label: "empty library, TTABLE", setup: [], mode: 1, rule: .ttable),
        Case(label: "empty library, TTABLE NOSKIP", setup: [], mode: 5, rule: .ttable),
        Case(label: "empty library, TTHRESH", setup: [], mode: 2, rule: nil),
        Case(label: "id 1 of 2, TTABLE", setup: lib + ["TTABLE PRESET 1 TMAX 2", "SET 10 TTABLE 1"], mode: 1, rule: nil),
        // Several rules broken at once: the first in the order is named.
        Case(label: "truth + register + empty library, TTABLE",
             setup: ["SET 10 TRUTH 200", "CONNECT BACK FROM 3 TO 10"], mode: 1, rule: .truth),
        Case(label: "register + empty library, TTABLE", setup: ["CONNECT BACK FROM 3 TO 10"], mode: 1, rule: .register),
        Case(label: "kind 3 + reserved bit on a node breaking every other rule",
             setup: ["SET 10 TRUTH 200", "CONNECT BACK FROM 3 TO 10"], mode: 0x0B, rule: .modeByte,
             phrase: "reserved bits 3-7"),
        // Legal writes on a clean node.
        Case(label: "clean, BINARY", setup: [], mode: 0, rule: nil),
        Case(label: "clean, TTABLE", setup: lib, mode: 1, rule: nil),
        Case(label: "clean, TTHRESH", setup: [], mode: 2, rule: nil),
        Case(label: "clean, TTABLE NOSKIP", setup: lib, mode: 5, rule: nil),
        Case(label: "clean, TTHRESH NOSKIP", setup: [], mode: 6, rule: nil),
    ]

    /// The words each path gave before the checker existed — the handler's
    /// `modeWriteRefusal` and replay's `modeCheck` — written down.
    private func liveWords(_ rule: Rule, truth: UInt8, tid: UInt16, size: Int) -> String? {
        switch rule {
        case .modeByte: return nil
        case .truth: return "node \(node) holds truth byte \(truth); a ternary node holds 0, 1 or 2 — SET \(node) TRUTH first"
        case .register: return "node \(node) is a register (BACK_EDGE destination); registers stay BINARY"
        case .ttable: return "node \(node): ttableId \(tid) is not below the library size \(size) — SET \(node) TTABLE <tid> first"
        }
    }
    private func replayWords(_ rule: Rule, truth: UInt8, tid: UInt16, size: Int) -> String? {
        switch rule {
        case .modeByte: return nil
        case .truth: return "node \(node): truth byte \(truth) on a ternary node"
        case .register: return "node \(node): a register must be BINARY"
        case .ttable: return "node \(node): ttableId \(tid) is not below the library size \(size)"
        }
    }

    private func ruleOf(_ r: TernaryReference.ModeWriteRule?) -> Rule? {
        switch r {
        case .none: return nil
        case .modeByte?: return .modeByte
        case .truthByte?: return .truth
        case .register?: return .register
        case .ttableId?: return .ttable
        }
    }

    /// The DSL words for a mode byte, when the DSL can say it.
    private func dsl(_ m: UInt8) -> String? {
        guard m & ~UInt8(0x07) == 0, m & 3 != 3 else { return nil }
        let kind = ["BINARY", "TTABLE", "TTHRESH"][Int(m & 3)]
        return "SET \(node) MODE \(kind)" + (m & 4 != 0 ? " NOSKIP" : "")
    }

    // MARK: - The three paths

    private func u32(_ v: UInt32) -> Data { var x = v; return Data(bytes: &x, count: 4) }

    private func freshEngine() throws -> DagDBEngine {
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side), maxRank: 8)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        return e
    }

    struct Live {
        let reply: String
        let modeAfter: UInt8
        let walGrew: Bool
        let log: Data           // the session's WAL after the setup, before the mode write
        let truth: UInt8, isRegister: Bool, tid: UInt16, size: Int
    }

    /// A daemon session: the case's setup through the verbs, then the mode
    /// write (single SET MODE or SET_MODES_BULK).
    private func live(_ c: Case, bulk: Bool, tag: String) throws -> Live {
        let walPath = root + "\(tag).wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: n)
        let f = try HandlerFixture(side: side, wal: wal, maxRank: 8)
        let h = f.handler
        for line in c.setup {
            let r = h.handle(line)
            XCTAssertTrue(r.hasPrefix("OK"), "\(c.label): setup \(line) -> \(r)")
        }
        h.walAppender?.barrier()
        let log = try Data(contentsOf: URL(fileURLWithPath: walPath))
        let e = h.engine
        let truth = e.truthStateBuf.contents().load(fromByteOffset: node, as: UInt8.self)
        let isReg = e.isRegister(node: UInt32(node))
        let tid = e.ttableIdPtr[node], size = e.ttableCount
        let reply: String
        if bulk {
            let v = f.shm.advanced(by: 8).bindMemory(to: UInt8.self, capacity: n)
            for i in 0..<n { v[i] = 0 }
            v[node] = c.mode
            shm1Header(f.shm, count: n, verb: .setModesBulk)
            reply = h.handle("SET_MODES_BULK")
        } else {
            reply = h.handle(try XCTUnwrap(dsl(c.mode)))
        }
        h.walAppender?.barrier()
        let after = try Data(contentsOf: URL(fileURLWithPath: walPath))
        return Live(reply: reply, modeAfter: e.modeLane[node], walGrew: after.count > log.count, log: log,
                    truth: truth, isRegister: isReg, tid: tid, size: size)
    }

    /// The session's log plus the mode record, by hand, replayed into a fresh engine.
    private func replay(_ log: Data, mode m: UInt8, bulk: Bool, tag: String) throws -> (DagDBWAL.ReplayResult, UInt8) {
        var f = log
        let payload: Data
        let op: UInt8
        if bulk {
            var v = [UInt8](repeating: 0, count: n); v[node] = m
            op = 0x47; payload = u32(UInt32(n)) + Data(v)
        } else {
            op = 0x40; payload = u32(UInt32(node)) + Data([m])
        }
        f.append(u32(UInt32(payload.count))); f.append(op); f.append(payload)
        let p = root + "\(tag)_replay.wal"
        try f.write(to: URL(fileURLWithPath: p))
        let e = try freshEngine()
        let r = try DagDBWAL.replay(engine: e, nodeCount: n, path: p)
        return (r, e.modeLane[node])
    }

    func testItem2OneCheckerSameVerdictOnEveryPathInEveryContext() throws {
        var verdicts = 0, agree = 0, liveWordCells = 0, replayWordCells = 0
        for (ci, c) in Self.cases.enumerated() {
            for bulk in [false, true] where bulk || dsl(c.mode) != nil {
                let form = bulk ? "SET_MODES_BULK" : "SET MODE"
                let what = "\(c.label) [\(form), mode 0x\(String(c.mode, radix: 16))]"
                let tag = "c\(ci)_\(bulk ? "bulk" : "one")"
                let l = try live(c, bulk: bulk, tag: tag)

                // The checker, both contexts, on the session's state.
                let rule = TernaryReference.modeWriteViolation(mode: c.mode, truth: l.truth, isRegister: l.isRegister,
                                                               ttableId: l.tid, tableCount: l.size)
                let wLive = TernaryReference.modeWriteRefusal(node: node, mode: c.mode, truth: l.truth,
                                                              isRegister: l.isRegister, ttableId: l.tid,
                                                              tableCount: l.size, context: .live)
                let wReplay = TernaryReference.modeWriteRefusal(node: node, mode: c.mode, truth: l.truth,
                                                                isRegister: l.isRegister, ttableId: l.tid,
                                                                tableCount: l.size, context: .replay)
                let (r, modeReplayed) = try replay(l.log, mode: c.mode, bulk: bulk, tag: tag)

                let handlerRefused = !l.reply.hasPrefix("OK")
                let replayRefused = !r.refusals.isEmpty
                let expected = c.rule != nil
                let paths: [(String, Bool)] = [("handler", handlerRefused), ("replay", replayRefused),
                                               ("checker live", wLive != nil), ("checker replay", wReplay != nil),
                                               ("checker rule", rule != nil)]
                for (path, refused) in paths {
                    verdicts += 1
                    if refused == expected { agree += 1 }
                    XCTAssertEqual(refused, expected, "\(what): \(path) \(refused ? "refused" : "accepted")")
                }
                XCTAssertEqual(ruleOf(rule), c.rule, "\(what): the checker names \(String(describing: rule))")

                if let want = c.rule {
                    // Handler: nothing written, the reply is the live words.
                    XCTAssertEqual(l.modeAfter, 0, "\(what): a refused live write changed the mode lane")
                    XCTAssertFalse(l.walGrew, "\(what): a refused live write reached the WAL")
                    XCTAssertEqual(l.reply, "ERROR bad_value: ternary: " + (wLive ?? "—"), what)
                    // Replay: skipped, counted, named with the replay words.
                    XCTAssertEqual(modeReplayed, 0, "\(what): a refused record changed the replayed mode lane")
                    XCTAssertEqual(r.refusals.count, 1, "\(what): \(r.refusals)")
                    XCTAssertEqual(r.skipReasons.outOfRangeIndex, 1, what)
                    XCTAssertTrue(r.refusals.first?.hasSuffix(": " + (wReplay ?? "—")) == true,
                                  "\(what): replay said \(r.refusals) — checker .replay \(wReplay ?? "nil")")
                    XCTAssertTrue(r.refusals.first?.contains(String(format: "opcode 0x%02x", bulk ? 0x47 : 0x40)) == true)
                    // The words, as each path gave them before the checker.
                    if want == .modeByte {
                        let phrase = try XCTUnwrap(c.phrase)
                        XCTAssertEqual(wLive, wReplay, "\(what): a mode-byte refusal reads the same in both contexts")
                        XCTAssertTrue(wLive?.hasPrefix("node \(node): mode 0x") == true && wLive?.contains(phrase) == true,
                                      "\(what): \(wLive ?? "nil")")
                    } else {
                        XCTAssertEqual(wLive, liveWords(want, truth: l.truth, tid: l.tid, size: l.size), what)
                        XCTAssertEqual(wReplay, replayWords(want, truth: l.truth, tid: l.tid, size: l.size), what)
                        XCTAssertNotEqual(wLive, wReplay, "\(what): the context changes the words")
                    }
                    liveWordCells += 1; replayWordCells += 1
                } else {
                    XCTAssertEqual(l.modeAfter, c.mode, "\(what): a legal live write did not land")
                    XCTAssertTrue(l.walGrew, "\(what): a legal live write was not logged")
                    XCTAssertTrue(l.reply.hasPrefix(bulk ? "OK SET_MODES_BULK nodes=\(n) ternary=\(c.mode == 0 ? 0 : 1)"
                                                         : "OK SET node=\(node) mode="), "\(what): \(l.reply)")
                    XCTAssertEqual(modeReplayed, c.mode, "\(what): a legal record did not replay")
                    XCTAssertEqual(r.recordsSkipped, 0, "\(what): \(r.refusals)")
                }
            }
        }
        print("A9 item2: \(Self.cases.count) cases, \(verdicts / 5) mode writes; handler, replay, checker (.live, .replay, rule) " +
              "agree with the written-down verdict on \(agree)/\(verdicts); words: live \(liveWordCells), replay \(replayWordCells) refusals as before")
    }
}
