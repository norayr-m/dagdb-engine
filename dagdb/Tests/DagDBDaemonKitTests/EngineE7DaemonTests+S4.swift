import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// S4 refused everywhere, and an older S4 state is never a dead end.
///
/// S4, a slot into a register, is refused everywhere: by SET_NEIGHBORS_BULK
/// (in CONNECT's slot-centric words), by LOAD JSON v1 and LOAD CSV v1 against
/// the live list they keep, by the back-edge loaders (regression), by CONNECT
/// (unchanged), and by the daemon's writers of a state holding it. Each refusal is computed from the single verb's
/// words; the state hash and the WAL bytes are unchanged; nothing is written.
///
/// A recovered older S4 state is never a dead end: a crafted log holding
/// what an older daemon logged (SET_NEIGHBORS_BULK giving registers slots)
/// replays as logged and recovery prints a WARN line naming
/// every S4 node (register, slot, source); SAVE refuses and names both ways
/// out (`CLEAR <dst> EDGES`, `CLEAR <dst> BACK_EDGES`); after either verb,
/// followed register by register, SAVE succeeds and LOAD gives the same state.
extension EngineE7DaemonTests {

    static func words(_ single: String) -> String {
        guard let c = single.range(of: ": ") else { return single }
        return String(single[c.upperBound...])
    }

    func files(_ dir: String) -> [String: Data] {
        var out: [String: Data] = [:]
        guard let en = FileManager.default.enumerator(atPath: dir) else { return out }
        while let p = en.nextObject() as? String {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir + "/" + p, isDirectory: &isDir), !isDir.boolValue {
                out[p] = try? Data(contentsOf: URL(fileURLWithPath: dir + "/" + p))
            }
        }
        return out
    }

    /// CONNECT BACK of the pair on a daemon holding `nb` and no register: its words.
    func connectBackWords(side: Int, nb: [Int32], src: UInt32, dst: UInt32) throws -> String {
        let f = try fixture(side: side)
        putNeighbors(f, nb)
        ok(f, "SET_NEIGHBORS_BULK")
        let r = f.handler.handle("CONNECT BACK FROM \(src) TO \(dst)")
        XCTAssertTrue(r.hasPrefix("ERROR schema: BACK_EDGE dst node \(dst) has a combinational input"), r)
        return Self.words(r)
    }

    func testE72SlotIntoARegisterIsRefusedEverywhere() throws {
        let gr = Self.slotGraph(side: 8, seed: 0xE7_2000, shapes: [.s1, .s2, .s3], ternary: false)
        let n = gr.n
        let (r0src, r0) = gr.regs[0]
        let (_, r1) = gr.regs[1]
        let src = (0..<n).first { !gr.isReg[$0] && $0 != Int(r0) && $0 != Int(r1) }!
        var cells = 0, byName = 0, unchanged = 0, nothingWritten = 0
        func tally(_ what: String, _ reply: String, _ want: String, exact: Bool = true,
                   same: Bool, wrote: Bool, file: StaticString = #filePath, line: UInt = #line) {
            cells += 1
            let named = exact ? reply == want : reply.hasPrefix(want)
            XCTAssertTrue(named, "\(what): got \(reply)\n want \(want)", file: file, line: line)
            XCTAssertTrue(same, "\(what): the state hash or the WAL changed", file: file, line: line)
            XCTAssertFalse(wrote, "\(what): something was written", file: file, line: line)
            if named { byName += 1 }
            if same { unchanged += 1 }
            if !wrote { nothingWritten += 1 }
            print("E7.2 \(what) -> \(reply)")
        }

        // (a) SET_NEIGHBORS_BULK: (i) register slot 0, (ii) slot 5, (iii) one of two registers.
        for (r, k) in [(r0, 0), (r0, 5), (r1, 2)] {
            let wal = tmp + "a_\(r)_\(k).wal"
            let d = try daemon(gr, wal: wal)
            let before = try observe(d), walBefore = try walBytes(d, wal)
            var nb = gr.nb
            nb[Int(r) * 6 + k] = Int32(src)
            putNeighbors(d, nb)
            let reply = d.handler.handle("SET_NEIGHBORS_BULK")
            let connect = try daemon(gr).handler.handle("CONNECT FROM \(src) TO \(r)")
            XCTAssertTrue(connect.hasPrefix("ERROR schema: back_edge_violation"), connect)
            let i = Int(r) * 6 + k
            let want = "ERROR schema: SET_NEIGHBORS_BULK slot \(i) (node \(r) dir \(k)): \(Self.words(connect)); nothing written"
            let after = try observe(d), walAfter = try walBytes(d, wal)
            let same = diff(before, after) == [] && walAfter == walBefore
            tally("SET_NEIGHBORS_BULK register \(r) slot \(k)", reply, want, same: same, wrote: false)
        }

        // (b) LOAD JSON v1 / LOAD CSV v1 over the live registers: the kept list's entry 0 (register r0) gains
        // slot 0. On a legal graph (no S1–S3), so a build before the slot model shows its acceptance, not its DAG rule.
        let lg = Self.slotGraph(side: 8, seed: 0xE7_2001, shapes: [], ternary: false)
        let (l0src, l0) = lg.regs[0]
        let lsrc = (0..<n).first { !lg.isReg[$0] && $0 != Int(l0) }!
        var fileNb = lg.nb
        fileNb[Int(l0) * 6] = Int32(lsrc)
        var plain = lg
        plain.regs = []; plain.isReg = [Bool](repeating: false, count: n); plain.nb = fileNb
        let keptWords = try connectBackWords(side: lg.side, nb: fileNb, src: l0src, dst: l0)
        for verb in ["LOAD JSON", "LOAD CSV"] {
            let wal = tmp + "b_\(verb.count).wal"
            let d = try daemon(lg, wal: wal, startup: tmp + "b_\(verb.count)_startup.dags")   // with the WAL on, a loader needs a startup path
            let before = try observe(d), walBefore = try walBytes(d, wal)
            let w = try daemon(plain)
            let base = tmp + "v1_\(verb.count)"
            let cmd: String
            if verb == "LOAD JSON" {
                ok(w, "SAVE JSON \(base).json")
                var obj = try XCTUnwrap(try JSONSerialization.jsonObject(
                    with: Data(contentsOf: URL(fileURLWithPath: base + ".json"))) as? [String: Any])
                for k in ["edgeWeightsBits", "activation", "nodeValueBits", "backEdges", "nodeMode", "ttableId",
                          "thrLoBits", "thrHiBits", "ttables"] { obj[k] = nil }
                obj["version"] = 1
                try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: base + ".json"))
                cmd = "LOAD JSON \(base).json"
            } else {
                try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
                ok(w, "SAVE CSV \(base)")
                for fn in ["lanes.csv", "weights.csv", "back_edges.csv", "ttables.csv"] {
                    try? FileManager.default.removeItem(atPath: base + "/" + fn)
                }
                cmd = "LOAD CSV \(base)"
            }
            let reply = d.handler.handle(cmd)
            let want = "ERROR schema: \(verb) kept back edge entry 0: \(keptWords); nothing loaded"
            let after = try observe(d), walAfter = try walBytes(d, wal)
            let same = diff(before, after) == [] && walAfter == walBefore
            tally("\(verb) v1 kept list", reply, want, same: same, wrote: false)
        }

        // (c) The back-edge cells of `EngineE6DaemonTests` again: S4 in the file's own list, written by the library writers (the legal graph).
        let s4 = try daemon(lg)
        s4.handler.engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)[Int(l0) * 6] = Int32(lsrc)
        let legalSrc = try daemon(lg)
        let e = s4.handler.engine
        let loaders: [(String, String, String, (String) throws -> String)] = [
            ("IMPORT MORTON", "back_edges.bin", "imported", { b in
                _ = try DagDBSnapshot.exportMorton(engine: e, nodeCount: n, dir: b); return "IMPORT MORTON \(b)" }),
            ("LOAD", "back-edge section", "loaded", { b in
                _ = try DagDBSnapshot.save(engine: e, nodeCount: n, gridW: lg.side, gridH: lg.side, tickCount: 0, path: b + ".dags")
                return "LOAD \(b).dags" }),
            ("LOAD JSON", "backEdges", "loaded", { b in
                _ = try DagDBJSONIO.saveJSON(engine: e, nodeCount: n, gridW: lg.side, gridH: lg.side, tickCount: 0, path: b + ".json")
                return "LOAD JSON \(b).json" }),
            ("LOAD CSV", "back_edges.csv", "loaded", { b in
                try FileManager.default.createDirectory(atPath: b, withIntermediateDirectories: true)
                _ = try DagDBJSONIO.saveCSV(engine: e, nodeCount: n, dir: b); return "LOAD CSV \(b)" }),
            ("BACKUP RESTORE", "back-edge section", "restored", { b in
                _ = try DagDBBackup.initializeChain(engine: legalSrc.handler.engine, nodeCount: n, gridW: lg.side,
                                                   gridH: lg.side, tickCount: 0, dir: b)
                _ = try DagDBBackup.appendDiff(engine: e, nodeCount: n, gridW: lg.side, gridH: lg.side, dir: b)
                return "BACKUP RESTORE \(b)" }),
        ]
        for (verb, list, nothing, write) in loaders {
            let wal = tmp + "c_\(verb.count).wal"
            let d = try daemon(lg, wal: wal, startup: tmp + "c_\(verb.count)_startup.dags")   // with the WAL on, a loader needs a startup path
            let before = try observe(d), walBefore = try walBytes(d, wal)
            let reply = d.handler.handle(try write(tmp + "c_src_\(verb.count)"))
            let want = "ERROR schema: \(verb) \(list) entry 0: \(keptWords); nothing \(nothing)"
            let after = try observe(d), walAfter = try walBytes(d, wal)
            let same = diff(before, after) == [] && walAfter == walBefore
            tally("\(verb) (E6, the file's own list)", reply, want, same: same, wrote: false)
        }

        // (d) CONNECT into a register (unchanged).
        do {
            let wal = tmp + "d.wal"
            let d = try daemon(gr, wal: wal)
            let before = try observe(d), walBefore = try walBytes(d, wal)
            let reply = d.handler.handle("CONNECT FROM \(src) TO \(r0)")
            let after = try observe(d), walAfter = try walBytes(d, wal)
            let same = diff(before, after) == [] && walAfter == walBefore
            tally("CONNECT into register \(r0)", reply, "ERROR schema: back_edge_violation: node \(r0) is a BACK_EDGE destination (register)",
                  exact: false, same: same, wrote: false)
        }

        // (e) The daemon's writers of an S4 state injected in-process.
        let wal = tmp + "e.wal"
        let d = try daemon(gr, wal: wal)
        let chain = tmp + "e_chain"
        ok(d, "BACKUP INIT \(chain)")
        d.handler.engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)[Int(r0) * 6] = Int32(src)
        let single = d.handler.handle("CONNECT BACK FROM \(r0src) TO \(r0)")
        XCTAssertTrue(single.hasPrefix("ERROR schema: BACK_EDGE dst node \(r0) has a combinational input at slot 0"), single)
        let chainBefore = files(chain)
        try FileManager.default.createDirectory(atPath: tmp + "e_csv", withIntermediateDirectories: true)
        func wrote(_ p: String) -> Bool {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir) { return isDir.boolValue ? !files(p).isEmpty : true }
            return FileManager.default.fileExists(atPath: p + ".tmp") || FileManager.default.fileExists(atPath: p + ".sha256")
        }
        let writers: [(String, String, String)] = [
            ("SAVE", "SAVE \(tmp!)e_save.dags", tmp + "e_save.dags"),
            ("SAVE", "SAVE \(tmp!)e_savez.dags COMPRESSED", tmp + "e_savez.dags"),
            ("SAVE JSON", "SAVE JSON \(tmp!)e_save.json", tmp + "e_save.json"),
            ("SAVE CSV", "SAVE CSV \(tmp!)e_csv", tmp + "e_csv"),
            ("EXPORT MORTON", "EXPORT MORTON \(tmp!)e_export", tmp + "e_export"),
            ("BACKUP INIT", "BACKUP INIT \(tmp!)e_chain2", tmp + "e_chain2"),
            ("BACKUP APPEND", "BACKUP APPEND \(chain)", ""),
            ("SAVE TILED", "SAVE TILED \(tmp!)e_tiled/g 32", tmp + "e_tiled/g"),
        ]
        for (verb, cmd, out) in writers {
            let before = try observe(d), walBefore = try walBytes(d, wal)
            let reply = d.handler.handle(cmd)
            let want = "ERROR schema: \(verb) back edge entry 0: \(Self.words(single)); nothing written"
            let wayOut = reply.contains("CLEAR \(r0) EDGES") && reply.contains("CLEAR \(r0) BACK_EDGES")
            XCTAssertTrue(wayOut, "\(cmd): the refusal names the way out: \(reply)")
            let after = try observe(d), walAfter = try walBytes(d, wal)
            let same = diff(before, after) == [] && walAfter == walBefore
            let w = out.isEmpty ? files(chain) != chainBefore : wrote(out)
            tally(cmd.components(separatedBy: " \(tmp!)").first ?? cmd, reply, want, exact: false,
                  same: same && wayOut, wrote: w)
        }
        // BACKUP COMPACT of a chain whose tip holds S4 (the library wrote it).
        do {
            let c = tmp + "e_compact"
            _ = try DagDBBackup.initializeChain(engine: legalSrc.handler.engine, nodeCount: n, gridW: lg.side,
                                               gridH: lg.side, tickCount: 0, dir: c)
            _ = try DagDBBackup.appendDiff(engine: e, nodeCount: n, gridW: lg.side, gridH: lg.side, dir: c)
            let g = try daemon(lg)
            let cBefore = files(c)
            let reply = g.handler.handle("BACKUP COMPACT \(c)")
            let want = "ERROR schema: BACKUP COMPACT back-edge section entry 0: \(keptWords); nothing written"
            tally("BACKUP COMPACT (S4 in the chain's tip)", reply, want, exact: false, same: true, wrote: files(c) != cBefore)
        }
        print("E7.2 cells=\(cells) refused_by_name=\(byName) state_and_wal_unchanged=\(unchanged) nothing_written=\(nothingWritten)")
    }

    // MARK: - A recovered older S4 state is never a dead end

    func testE76ARecoveredPreE7SlotIntoARegisterIsNeverADeadEnd() throws {
        let side = 8, n = 64
        let s4: [(Int, Int, Int)] = [(3, 0, 20), (3, 4, 21), (9, 2, 30)]
        var warned = 0, saveNamesBoth = 0, saved = 0, loadedEqual = 0
        for verb in ["EDGES", "BACK_EDGES"] {
            // What a daemon before the slot model logged: two registers by CONNECT BACK, then
            // SET_NEIGHBORS_BULK giving them slots (it accepted S4 and said so).
            let wal = tmp + "pre_e7_\(verb).wal"
            do {
                let w = try DagDBWAL.Appender(path: wal, nodeCount: n)
                let rank = (0..<n).map { UInt64(3 - $0 / 16) }
                _ = try rank.withUnsafeBufferPointer { try w.setRanksBulk($0.baseAddress!, count: n) }
                _ = try w.connectBack(src: 50, dst: 3)
                _ = try w.connectBack(src: 51, dst: 9)
                var nb = [Int32](repeating: -1, count: n * 6)
                for i in 16..<n { nb[i * 6] = Int32(i - 16) }
                for (r, k, s) in s4 { nb[r * 6 + k] = Int32(s) }
                nb[40 * 6 + 3] = 40                                  // an S2 slot (not a register)
                _ = try nb.withUnsafeBufferPointer { try w.setNeighborsBulk($0.baseAddress!, count: n) }
                _ = try w.setTruth(node: 7, value: 1)
                w.barrier()
            }
            let (f, lines) = try recover(side: side, snapshot: nil, wal: wal)
            print("E7.6 [\(verb)] recovery: " + lines.joined(separator: " | "))
            let live = f.handler.engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
            XCTAssertTrue(s4.allSatisfy { live[$0.0 * 6 + $0.1] == Int32($0.2) }, "the pre-E7 record replays as logged (R4)")
            let warn = lines.filter { $0.contains("WARN") }
            XCTAssertTrue(lines.contains { $0.contains("; applied as logged (a record from an older build; this build refuses it live)") },
                          "[\(verb)] \(lines)")
            let named = s4.allSatisfy { (r, k, s) in warn.contains { $0.contains("node \(r) slot \(k) (source node \(s))") } }
            XCTAssertTrue(named, "[\(verb)] a WARN line names every S4 node: \(warn)")
            if named { warned += 1 }

            let p = tmp + "e76_\(verb).dags"
            var save = f.handler.handle("SAVE \(p)")
            print("E7.6 [\(verb)] SAVE -> \(save)")
            let both = save.hasPrefix("ERROR") && save.contains("CLEAR 3 EDGES") && save.contains("CLEAR 3 BACK_EDGES")
            XCTAssertTrue(both, "[\(verb)] SAVE refuses and names both verbs: \(save)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: p))
            if both { saveNamesBoth += 1 }
            // The refusal's own way out, register by register.
            var followed: [String] = []
            for _ in 0..<4 where !save.hasPrefix("OK SAVE") {
                guard let r = save.range(of: "CLEAR "),
                      let reg = Int(save[r.upperBound...].prefix { $0.isNumber }) else { break }
                let cmd = "CLEAR \(reg) \(verb)"
                ok(f, cmd); followed.append(cmd)
                save = f.handler.handle("SAVE \(p)")
            }
            print("E7.6 [\(verb)] followed \(followed) -> \(save)")
            XCTAssertTrue(save.hasPrefix("OK SAVE"), "[\(verb)] after \(followed): \(save)")
            guard save.hasPrefix("OK SAVE") else { continue }
            saved += 1
            let g = try fixture(side: side)
            ok(g, "LOAD \(p)")
            let d = diff(try observe(g), try observe(f))
            XCTAssertEqual(d, [], "[\(verb)] LOAD gives the same state")
            if d.isEmpty { loadedEqual += 1 }
        }
        print("E7.6 cells=2 warn_names_every_s4_node=\(warned) save_names_both_verbs=\(saveNamesBoth) saved_after_the_verb=\(saved) load_equal=\(loadedEqual)")
    }
}
