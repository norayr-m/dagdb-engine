import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// One rule set for back edges on every path.
///
/// `CONNECT BACK` and `CONNECT_BACK_BULK` refuse, per entry, a self-loop, a
/// ternary destination and a destination with a live combinational slot.
/// The loaders installed back edges with a range check only (the ternary
/// register rule was checked as a lane rule, by node): IMPORT MORTON's
/// `back_edges.bin`, LOAD's back-edge section, LOAD JSON's `backEdges`, LOAD
/// CSV's `back_edges.csv`, BACKUP RESTORE's back-edge section. A file the DSL
/// could never have produced was accepted.
///
/// The check: each loader, offered a list whose entry 11 breaks one rule —
/// (i) a self-loop, (ii) a destination with one live slot, (iii) a ternary
/// destination — refuses it by name, `ERROR schema: <VERB> <list> entry 11:
/// <CONNECT BACK's words>; nothing <loaded>`, where CONNECT BACK's words are
/// the reply `CONNECT BACK` of the same pair gives on a fresh daemon holding
/// the same graph; the engine's state (every EXPORT MORTON file, GRAPH INFO,
/// STATUS, the register flags) and the WAL bytes are unchanged. The control
/// (the check removed) imports while `CONNECT BACK` of the same pair refuses.
///
/// Beside it: SAVE refuses what LOAD now refuses; the loaders that keep the
/// live back edges (LOAD JSON v1, LOAD CSV without lanes.csv) refuse slots
/// under a kept register (an earlier build accepted them, a reading, and SAVE
/// refused that state); a WAL import record holding an illegal list (as an
/// older daemon could log it) is refused on replay by the same function; a
/// legal import with `back_edges.bin` equals the import plus
/// CONNECT_BACK_BULK (in-process).
final class EngineE6DaemonTests: XCTestCase {

    static let side = 8
    static let n = 64
    static let maxRank = 16

    private var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "engine-e6-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - The graph

    enum Rule: String, CaseIterable { case selfLoop, fanIn, ternary }

    /// Entry 11 of each case. Node 11 is a top-rank node with no slot; node
    /// 20 has exactly one live slot (from node 4); in the ternary case node 11
    /// is TTHRESH.
    static func offender(_ r: Rule) -> (UInt32, UInt32) {
        switch r {
        case .selfLoop: return (11, 11)
        case .fanIn: return (60, 20)
        case .ternary: return (59, 11)
        }
    }

    /// Fourteen legal back edges: a rank-0 source into each top-rank node but 11.
    static let legal: [(UInt32, UInt32)] = (0..<15).filter { $0 != 11 }.map { (UInt32(48 + $0), UInt32($0)) }

    /// The legal list with the offender at entry 11 (fourteen legal entries around it).
    static func entries(_ r: Rule) -> [(UInt32, UInt32)] {
        var e = legal
        e.insert(offender(r), at: 11)
        return e
    }

    /// The lanes: four rank levels of 16 (0–15 rank 3 … 48–63 rank 0), every
    /// node below the top one slot from 16 ids up (a higher rank), no back edge.
    static func writeLanes(_ e: DagDBEngine, ternary11: Bool) {
        let n = e.nodeCount
        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let low = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high = e.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        for i in 0..<n {
            rank[i] = UInt64(3 - i / 16)
            truth[i] = UInt8(i % 2)
            low[i] = UInt32(truncatingIfNeeded: 0x9E37_79B9 &* UInt32(i + 1))
            high[i] = UInt32(i * 3)
            for d in 0..<6 { nb[i * 6 + d] = -1 }
        }
        for i in 16..<n { nb[i * 6] = Int32(i - 16) }
        if ternary11 { e.setNodeMode(11, 2) }
        e.markRankTopologyDirty()
    }

    /// The back-edge list, in order. An entry into a ternary node goes into
    /// the list without its register flag, so the library writers (whose own
    /// ternary rule reads the flags) write the file as the case needs it.
    static func install(_ e: DagDBEngine, _ list: [(UInt32, UInt32)]) throws {
        e.backEdgeSrcs = []
        e.backEdgeDsts = []
        let reg = e.isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: e.nodeCount)
        for i in 0..<e.nodeCount { reg[i] = 0 }
        for (s, d) in list {
            if TernaryReference.isTernary(e.modeByte(Int(d))) {
                e.backEdgeSrcs.append(s); e.backEdgeDsts.append(d)
            } else {
                try e.addBackEdgeUnchecked(src: s, dst: d)
            }
        }
    }

    func engine() throws -> DagDBEngine {
        try DagDBEngine(grid: try HexGrid(width: Self.side, height: Self.side),
                        state: DagDBState(width: Self.side, height: Self.side), maxRank: Self.maxRank)
    }

    func source(_ r: Rule, list: [(UInt32, UInt32)]) throws -> DagDBEngine {
        let e = try engine()
        Self.writeLanes(e, ternary11: r == .ternary)
        try Self.install(e, list)
        return e
    }

    // MARK: - Daemons

    func fixture(wal: String?) throws -> HandlerFixture {
        let f = try HandlerFixture(side: Self.side, dataRoot: tmp,
                                   wal: try wal.map { try DagDBWAL.Appender(path: $0, nodeCount: Self.n) },
                                   maxRank: Self.maxRank)
        // With the WAL on, every loader is refused
        // unless a startup snapshot path is set (a successful load rebases to it).
        if wal != nil { f.handler.startupSnapshotPath = tmp + "startup_\(UUID().uuidString).dags" }
        return f
    }

    @discardableResult
    func ok(_ f: HandlerFixture, _ line: String, file: StaticString = #filePath, l: UInt = #line) -> String {
        let r = f.handler.handle(line)
        XCTAssertTrue(r.hasPrefix("OK"), "\(line) -> \(r)", file: file, line: l)
        return r
    }

    /// A daemon at state S: the legal graph of the case imported, then two writes.
    func target(_ r: Rule, wal: String) throws -> HandlerFixture {
        let f = try fixture(wal: wal)
        let d = tmp + "S_\(UUID().uuidString)"
        _ = try DagDBSnapshot.exportMorton(engine: try source(r, list: Self.legal), nodeCount: Self.n, dir: d)
        ok(f, "IMPORT MORTON \(d)")
        ok(f, "SET 7 TRUTH 0")
        ok(f, "SET 30 LUT OR")
        return f
    }

    /// CONNECT BACK of the pair on a fresh daemon holding the case's legal graph.
    func connectBackWords(_ r: Rule, _ pair: (UInt32, UInt32)) throws -> String {
        let f = try fixture(wal: nil)
        let d = tmp + "W_\(UUID().uuidString)"
        _ = try DagDBSnapshot.exportMorton(engine: try source(r, list: Self.legal), nodeCount: Self.n, dir: d)
        ok(f, "IMPORT MORTON \(d)")
        return f.handler.handle("CONNECT BACK FROM \(pair.0) TO \(pair.1)")
    }

    /// The single's words after its reply category.
    static func words(_ single: String) -> String {
        guard let c = single.range(of: ": ") else { return single }
        return String(single[c.upperBound...])
    }

    /// Every lane (EXPORT MORTON's files, through the verb), GRAPH INFO,
    /// STATUS, the register flags and the back-edge list, and the WAL bytes.
    func observe(_ f: HandlerFixture, wal: String?) throws -> [String: Data] {
        f.handler.walAppender?.barrier()
        var o: [String: Data] = [:]
        if let w = wal { o["wal"] = try Data(contentsOf: URL(fileURLWithPath: w)) }
        let dir = tmp + "obs_\(UUID().uuidString)"
        let r = f.handler.handle("EXPORT MORTON \(dir)")
        XCTAssertTrue(r.hasPrefix("OK EXPORT"), r)
        if r.hasPrefix("OK EXPORT") {
            for name in try FileManager.default.contentsOfDirectory(atPath: dir) {
                o["export/" + name] = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + name))
            }
        } else {
            o["export"] = Data(r.utf8)      // a state EXPORT refuses (e.g. a ternary register) is observed by its refusal
        }
        try? FileManager.default.removeItem(atPath: dir)
        o["GRAPH INFO"] = Data(f.handler.handle("GRAPH INFO").utf8)
        o["STATUS"] = Data(f.handler.handle("STATUS").utf8)
        let e = f.handler.engine
        o["isRegister"] = Data(bytes: e.isRegisterBuf.contents(), count: Self.n)
        o["backEdges"] = Data("\(e.backEdgeSrcs) \(e.backEdgeDsts)".utf8)
        if let w = wal {
            f.handler.walAppender?.barrier()
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: w)), o["wal"], "observing wrote to the WAL")
        }
        return o
    }

    func diff(_ a: [String: Data], _ b: [String: Data]) -> [String] {
        Set(a.keys).union(b.keys).sorted().filter { a[$0] != b[$0] }
    }

    // MARK: - The loaders

    struct Loader {
        let verb: String
        let list: String
        let nothing: String
        /// Writes the source of the case into `base` and returns the command that loads it.
        let write: (_ t: EngineE6DaemonTests, _ r: Rule, _ list: [(UInt32, UInt32)], _ base: String) throws -> String
    }

    static let loaders: [Loader] = [
        Loader(verb: "IMPORT MORTON", list: "back_edges.bin", nothing: "imported") { t, r, list, base in
            _ = try DagDBSnapshot.exportMorton(engine: try t.source(r, list: list), nodeCount: n, dir: base)
            return "IMPORT MORTON \(base)"
        },
        Loader(verb: "LOAD", list: "back-edge section", nothing: "loaded") { t, r, list, base in
            _ = try DagDBSnapshot.save(engine: try t.source(r, list: list), nodeCount: n, gridW: side, gridH: side,
                                       tickCount: 3, path: base + ".dags")
            return "LOAD \(base).dags"
        },
        Loader(verb: "LOAD JSON", list: "backEdges", nothing: "loaded") { t, r, list, base in
            _ = try DagDBJSONIO.saveJSON(engine: try t.source(r, list: list), nodeCount: n, gridW: side, gridH: side,
                                         tickCount: 3, path: base + ".json")
            return "LOAD JSON \(base).json"
        },
        Loader(verb: "LOAD CSV", list: "back_edges.csv", nothing: "loaded") { t, r, list, base in
            _ = try DagDBJSONIO.saveCSV(engine: try t.source(r, list: list), nodeCount: n, dir: base)
            return "LOAD CSV \(base)"
        },
        // The chain's tip is what RESTORE installs: a legal base, then a diff
        // carrying the case's list.
        Loader(verb: "BACKUP RESTORE", list: "back-edge section", nothing: "restored") { t, r, list, base in
            let e = try t.source(r, list: legal)
            _ = try DagDBBackup.initializeChain(engine: e, nodeCount: n, gridW: side, gridH: side, tickCount: 3, dir: base)
            try install(e, list)
            _ = try DagDBBackup.appendDiff(engine: e, nodeCount: n, gridW: side, gridH: side, dir: base)
            return "BACKUP RESTORE \(base)"
        },
    ]

    // MARK: - Every loader refuses each back-edge rule by name

    func testE61EveryLoaderRefusesEachRuleByNameAndCommitsNothing() throws {
        var cells = 0, byName = 0, unchanged = 0, singleRefuses = 0
        for loader in Self.loaders {
            for r in Rule.allCases {
                cells += 1
                let what = "\(loader.verb) [\(r.rawValue)]"
                let single = try connectBackWords(r, Self.offender(r))
                XCTAssertTrue(single.hasPrefix("ERROR "), "\(what): CONNECT BACK of the pair is refused: \(single)")
                if single.hasPrefix("ERROR ") { singleRefuses += 1 }
                let want = "ERROR schema: \(loader.verb) \(loader.list) entry 11: \(Self.words(single)); nothing \(loader.nothing)"

                let walPath = tmp + "t_\(cells).wal"
                let f = try target(r, wal: walPath)
                let before = try observe(f, wal: walPath)
                let cmd = try loader.write(self, r, Self.entries(r), tmp + "src_\(cells)")
                let reply = f.handler.handle(cmd)
                XCTAssertEqual(reply, want, what)
                if reply == want { byName += 1 }
                let after = try observe(f, wal: walPath)
                let d = diff(before, after)
                XCTAssertEqual(d, [], "\(what): the refused load changed \(d)")
                if d.isEmpty { unchanged += 1 }
            }
        }
        print("E6.1 cells=\(cells) refused_by_name=\(byName) state_and_wal_unchanged=\(unchanged) connect_back_refuses=\(singleRefuses)")
    }

    /// The same list without entry 11 loads on every path (the cases differ
    /// from a legal file in that entry alone).
    func testE61TheLegalListLoadsOnEveryPath() throws {
        var loaded = 0
        for loader in Self.loaders {
            for r in Rule.allCases {
                let f = try target(r, wal: tmp + "legal_\(loaded).wal")
                let reply = f.handler.handle(try loader.write(self, r, Self.legal, tmp + "legal_src_\(loaded)"))
                XCTAssertTrue(reply.hasPrefix("OK"), "\(loader.verb) [\(r.rawValue)] legal list: \(reply)")
                XCTAssertEqual(f.handler.engine.backEdgeCount, Self.legal.count)
                loaded += 1
            }
        }
        print("E6.1 legal lists loaded=\(loaded)")
    }

    /// BACKUP RESTORE with the offender in the chain's BASE: the base is read
    /// without LOAD's graph rules (the tip is checked instead), so (i) and (ii)
    /// are refused by the back-edge rules' words; (iii) is refused first by the base's own
    /// ternary lane rule (a register stays BINARY), by node. Every case
    /// commits nothing.
    func testE61BackupBaseHoldingTheOffender() throws {
        var refused = 0
        for r in Rule.allCases {
            let walPath = tmp + "base_\(r.rawValue).wal"
            let f = try target(r, wal: walPath)
            let before = try observe(f, wal: walPath)
            let dir = tmp + "base_src_\(r.rawValue)"
            _ = try DagDBBackup.initializeChain(engine: try source(r, list: Self.entries(r)), nodeCount: Self.n,
                                               gridW: Self.side, gridH: Self.side, tickCount: 3, dir: dir)
            let reply = f.handler.handle("BACKUP RESTORE \(dir)")
            if r == .ternary {
                XCTAssertTrue(reply.hasPrefix("ERROR") && reply.contains("node 11") && reply.contains("BINARY"), reply)
            } else {
                let single = try connectBackWords(r, Self.offender(r))
                XCTAssertEqual(reply, "ERROR schema: BACKUP RESTORE back-edge section entry 11: \(Self.words(single)); nothing restored")
            }
            if reply.hasPrefix("ERROR") { refused += 1 }
            XCTAssertEqual(diff(before, try observe(f, wal: walPath)), [], "BACKUP RESTORE base [\(r.rawValue)]")
        }
        print("E6.1 backup base cells=3 refused=\(refused)")
    }

    // MARK: - Loaders that keep the live back edges

    /// LOAD JSON v1 and LOAD CSV without lanes.csv replace the slots and keep
    /// the live back-edge list. An earlier build accepted slots that gave a
    /// kept register a combinational input (a reading) and SAVE then refused
    /// the state. Now S4 is refused everywhere — the kept list is checked against the file's
    /// slots, refused by its entry in CONNECT BACK's words (`ERROR schema:
    /// <VERB> kept back edge entry <i>: …; nothing loaded`), the state and the
    /// WAL unchanged, and SAVE of the unchanged state writes. The same file
    /// with that slot empty loads and saves, as before.
    func testE6KeptBackEdgesUnderV1SlotsAreRefusedByName() throws {
        // The v1 sources: node 0 rises to rank 4, and node 3 (a kept
        // register, rank 3) takes a slot from it.
        func v1Source(slot: Bool) throws -> DagDBEngine {
            let e = try engine()
            Self.writeLanes(e, ternary11: false)
            e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: Self.n)[0] = 4
            if slot { e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: Self.n * 6)[3 * 6] = 0 }
            return e
        }
        let wordsFrom: String = try {
            let f = try fixture(wal: nil)
            let d = tmp + "kept_w"
            _ = try DagDBSnapshot.exportMorton(engine: try v1Source(slot: true), nodeCount: Self.n, dir: d)
            ok(f, "IMPORT MORTON \(d)")
            return f.handler.handle("CONNECT BACK FROM 51 TO 3")
        }()
        XCTAssertTrue(wordsFrom.hasPrefix("ERROR schema: BACK_EDGE dst node 3 has a combinational input at slot 0"), wordsFrom)
        var loaded = 0, refused = 0, saved = 0
        for verb in ["LOAD JSON", "LOAD CSV"] {
            for slot in [true, false] {
                let walPath = tmp + "kept_\(verb.count)_\(slot).wal"
                let f = try target(.selfLoop, wal: walPath)          // the legal list: node 3 is entry 3
                let base = tmp + "kept_src_\(verb.count)_\(slot)"
                let cmd: String
                if verb == "LOAD JSON" {
                    _ = try DagDBJSONIO.saveJSON(engine: try v1Source(slot: slot), nodeCount: Self.n,
                                                 gridW: Self.side, gridH: Self.side, tickCount: 3, path: base + ".json")
                    var obj = try XCTUnwrap(try JSONSerialization.jsonObject(
                        with: Data(contentsOf: URL(fileURLWithPath: base + ".json"))) as? [String: Any])
                    for k in ["edgeWeightsBits", "activation", "nodeValueBits", "backEdges", "nodeMode", "ttableId",
                              "thrLoBits", "thrHiBits", "ttables"] { obj[k] = nil }
                    obj["version"] = 1
                    try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: base + ".json"))
                    cmd = "LOAD JSON \(base).json"
                } else {
                    _ = try DagDBJSONIO.saveCSV(engine: try v1Source(slot: slot), nodeCount: Self.n, dir: base)
                    for fn in ["lanes.csv", "weights.csv", "back_edges.csv", "ttables.csv"] {
                        try? FileManager.default.removeItem(atPath: base + "/" + fn)
                    }
                    cmd = "LOAD CSV \(base)"
                }
                let before = try observe(f, wal: walPath)
                let reply = f.handler.handle(cmd)
                XCTAssertEqual(f.handler.engine.backEdgeCount, Self.legal.count, "\(verb): the back edges are kept")
                if slot {
                    XCTAssertEqual(reply, "ERROR schema: \(verb) kept back edge entry 3: \(Self.words(wordsFrom)); nothing loaded")
                    XCTAssertEqual(diff(before, try observe(f, wal: walPath)), [], "\(verb): the refused load changed state or the WAL")
                    if reply.hasPrefix("ERROR schema: \(verb) kept back edge entry 3") { refused += 1 }
                } else {
                    XCTAssertTrue(reply.hasPrefix("OK"), "\(verb) v1, slot \(slot): \(reply)")
                    if reply.hasPrefix("OK") { loaded += 1 }
                }
                let p = base + "_saved.dags"
                let s = f.handler.handle("SAVE \(p)")
                XCTAssertTrue(s.hasPrefix("OK SAVE"), s)
                if s.hasPrefix("OK SAVE") { saved += 1 }
            }
        }
        print("E6/E7 kept back edges: v1 loads giving a kept register a slot refused by name=\(refused) of 2; with the slot empty loaded=\(loaded) of 2; SAVE after each writes=\(saved) of 4")
    }

    // MARK: - SAVE refuses what LOAD refuses

    /// A register given a slot is a state LOAD refuses; SAVE refuses it by
    /// name and writes nothing — no file, no checkpoint. SET_NEIGHBORS_BULK
    /// no longer installs it (refused by name, nothing written), so the state
    /// is reached by a direct in-process write (an older log can replay one),
    /// and SAVE's refusal names the way out.
    func testE6SaveRefusesARegisterWithFanIn() throws {
        let walPath = tmp + "save.wal"
        let f = try target(.selfLoop, wal: walPath)
        ok(f, "SET 0 RANK 4")
        let nb = f.shm.advanced(by: 8).bindMemory(to: Int32.self, capacity: Self.n * 6)
        let live = f.handler.engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: Self.n * 6)
        for i in 0..<(Self.n * 6) { nb[i] = live[i] }
        nb[3 * 6] = 0
        shm1Header(f.shm, count: Self.n, verb: .setNeighborsBulk)
        let beforeBulk = try observe(f, wal: walPath)
        let bulk = f.handler.handle("SET_NEIGHBORS_BULK")
        let connect = f.handler.handle("CONNECT FROM 0 TO 3")
        XCTAssertTrue(connect.hasPrefix("ERROR schema: back_edge_violation"), connect)
        XCTAssertEqual(bulk, "ERROR schema: SET_NEIGHBORS_BULK slot 18 (node 3 dir 0): \(Self.words(connect)); nothing written")
        XCTAssertEqual(diff(beforeBulk, try observe(f, wal: walPath)), [], "the refused bulk changed state or the WAL")
        live[3 * 6] = 0
        let single = f.handler.handle("CONNECT BACK FROM 51 TO 3")
        XCTAssertTrue(single.hasPrefix("ERROR schema: BACK_EDGE dst node 3 has a combinational input at slot 0"), single)
        // Observed lane by lane: EXPORT MORTON refuses this state too (the
        // daemon's writers refuse S4).
        func lanes() throws -> [String: Data] {
            f.handler.walAppender?.barrier()
            let e = f.handler.engine
            return ["wal": try Data(contentsOf: URL(fileURLWithPath: walPath)),
                    "rank": Data(bytes: e.rankBuf.contents(), count: Self.n * 8),
                    "truth": Data(bytes: e.truthStateBuf.contents(), count: Self.n),
                    "lut_low": Data(bytes: e.lut6LowBuf.contents(), count: Self.n * 4),
                    "lut_high": Data(bytes: e.lut6HighBuf.contents(), count: Self.n * 4),
                    "neighbors": Data(bytes: e.neighborsBuf.contents(), count: Self.n * 24),
                    "isRegister": Data(bytes: e.isRegisterBuf.contents(), count: Self.n),
                    "backEdges": Data("\(e.backEdgeSrcs) \(e.backEdgeDsts)".utf8),
                    "GRAPH INFO": Data(f.handler.handle("GRAPH INFO").utf8),
                    "STATUS": Data(f.handler.handle("STATUS").utf8)]
        }
        let before = try lanes()
        let p = tmp + "save.dags"
        let reply = f.handler.handle("SAVE \(p)")
        XCTAssertEqual(reply, "ERROR schema: SAVE back edge entry 3: \(Self.words(single)); nothing written; "
                       + "the way out: CLEAR 3 EDGES (drops the register's combinational inputs) or CLEAR 3 BACK_EDGES (unmakes the register)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: p), "SAVE wrote a file LOAD refuses")
        XCTAssertEqual(diff(before, try lanes()), [], "the refused SAVE changed state or the WAL")
        // The same state with the slot cleared saves, and the file loads.
        ok(f, "CLEAR 3 EDGES")
        ok(f, "SAVE \(p)")
        let g = try fixture(wal: nil)
        ok(g, "LOAD \(p)")
    }

    // MARK: - WAL replay

    /// An import record whose `back_edges.bin` holds a self-loop at entry 11 —
    /// what an older daemon logged when it accepted such a file — is
    /// refused on replay by the same function, named, and nothing applied.
    func testE6ReplayRefusesAnImportRecordHoldingAnIllegalList() throws {
        let dir = tmp + "old_import"
        _ = try DagDBSnapshot.exportMorton(engine: try source(.selfLoop, list: Self.entries(.selfLoop)),
                                           nodeCount: Self.n, dir: dir)
        var files: [DagDBSnapshot.MortonFile] = []
        for name in DagDBSnapshot.mortonImportFileNames where FileManager.default.fileExists(atPath: dir + "/" + name) {
            files.append((name, try Data(contentsOf: URL(fileURLWithPath: dir + "/" + name))))
        }
        let walPath = tmp + "old.wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: Self.n)
        _ = try wal.importMorton(dir: dir, files: files)
        wal.barrier()
        let e = try engine()
        let rankBefore = Data(bytes: e.rankBuf.contents(), count: Self.n * 8)
        let r = try DagDBWAL.replay(engine: e, nodeCount: Self.n, path: walPath)
        XCTAssertEqual(r.refusals.count, 1, "\(r.refusals)")
        XCTAssertTrue(r.refusals.first?.contains("IMPORT MORTON \(dir): back_edges.bin entry 11: self-loop: src == dst (11)") == true,
                      "\(r.refusals)")
        XCTAssertEqual(e.backEdgeCount, 0, "the refused record installed back edges")
        XCTAssertEqual(Data(bytes: e.rankBuf.contents(), count: Self.n * 8), rankBefore, "the refused record wrote lanes")
    }

    // MARK: - IMPORT with back_edges.bin against IMPORT plus CONNECT_BACK_BULK, in-process

    /// IMPORT with back_edges.bin against IMPORT without it + CONNECT_BACK_BULK
    /// of the same list: every lane, GRAPH INFO, STATUS, the register flags
    /// and the back-edge list equal, after the build and after ticks; the
    /// logged import replays to the same lanes.
    func testE62ImportWithBackEdgesEqualsImportPlusConnectBackBulk() throws {
        let src = try source(.selfLoop, list: Self.legal)
        let withBE = tmp + "with_be", without = tmp + "without_be"
        _ = try DagDBSnapshot.exportMorton(engine: src, nodeCount: Self.n, dir: withBE)
        _ = try DagDBSnapshot.exportMorton(engine: src, nodeCount: Self.n, dir: without)
        try FileManager.default.removeItem(atPath: without + "/back_edges.bin")
        let walA = tmp + "a.wal"
        let a = try fixture(wal: walA), b = try fixture(wal: tmp + "b.wal")
        ok(a, "IMPORT MORTON \(withBE)")
        ok(b, "IMPORT MORTON \(without)")
        b.shm.storeBytes(of: UInt32(Self.legal.count), toByteOffset: 0, as: UInt32.self)
        b.shm.storeBytes(of: shm1Word1(.connectBackBulk), toByteOffset: 4, as: UInt32.self)
        for (i, (s, d)) in Self.legal.enumerated() {
            b.shm.storeBytes(of: s, toByteOffset: 8 + 8 * i, as: UInt32.self)
            b.shm.storeBytes(of: d, toByteOffset: 12 + 8 * i, as: UInt32.self)
        }
        ok(b, "CONNECT_BACK_BULK")
        var oa = try observe(a, wal: nil), ob = try observe(b, wal: nil)
        XCTAssertEqual(diff(oa, ob), [], "after the build")
        ok(a, "TICK 5"); ok(b, "TICK 5")
        oa = try observe(a, wal: nil); ob = try observe(b, wal: nil)
        XCTAssertEqual(diff(oa, ob), [], "after five ticks")
        // The logged import replays to the import's lanes.
        a.handler.walAppender?.barrier()
        let e = try engine()
        let r = try DagDBWAL.replay(engine: e, nodeCount: Self.n, path: walA)
        XCTAssertEqual(r.refusals, [])
        XCTAssertEqual(e.backEdgeSrcs, Self.legal.map { $0.0 })
        XCTAssertEqual(e.backEdgeDsts, Self.legal.map { $0.1 })
        let x = tmp + "replayed"
        _ = try DagDBSnapshot.exportMorton(engine: e, nodeCount: Self.n, dir: x)
        for name in ["neighbors.bin", "rank.bin", "back_edges.bin", "is_register.bin", "lut_low.bin", "lut_high.bin"] {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: x + "/" + name)),
                           try Data(contentsOf: URL(fileURLWithPath: withBE + "/" + name)), "replayed \(name)")
        }
    }
}
