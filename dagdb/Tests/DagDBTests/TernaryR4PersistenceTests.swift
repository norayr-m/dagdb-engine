import XCTest
import CryptoKit
@testable import DagDB

/// Persistence (control and interface).
///
/// Round trips bit for bit on every lane and the library: `.dags` v8 plain
/// and zlib, WAL v3 replay, backup diff 3 applied, JSON v2, CSV v2, Morton
/// export/import, reader sessions. Old files load identically: v1–v7, WAL v2,
/// diff 2, JSON v1. Every refusal of the ternary persistence rules is refused
/// by name on load and on write, for every format.
final class TernaryR4PersistenceTests: XCTestCase {

    private var tmp: String!
    private let side = 8

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "tern-r4-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let d = tmp { try? FileManager.default.removeItem(atPath: d) } }

    // MARK: - The object

    private func fresh() throws -> DagDBEngine {
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side), state: DagDBState(width: side, height: side), maxRank: 8)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        return e
    }

    /// A valid mixed graph touching every lane: ranks, LUTs, edges (a DAG),
    /// weights (non-default, −0.0 included), activation, value, a binary
    /// register, all three kinds, NOSKIP, thresholds (−0.0 included), three
    /// tables, Loom bytes on binary nodes.
    private func ternaryEngine() throws -> DagDBEngine {
        let e = try fresh()
        let n = e.nodeCount
        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let low = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high = e.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        let w = e.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        let act = e.activationBuf.contents().bindMemory(to: Int16.self, capacity: n)
        let val = e.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)
        let type = e.nodeTypeBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        try e.writeTables(first: 0, bytes: try TernaryReference.presetTable(.tsum, k: 3)
                          + TernaryReference.presetTable(.tmin, k: 2)
                          + (0..<729).map { UInt8(($0 * 5) % 3) })
        for i in 0..<n {
            rank[i] = UInt64(i % 4)
            low[i] = UInt32(truncatingIfNeeded: i &* 2654435761)
            high[i] = UInt32(truncatingIfNeeded: i &* 40503)
            type[i] = UInt8(i % 3)
            act[i] = Int16(i) - 30
            val[i] = Float(i) * 0.125
            for d in 0..<6 { w[i * 6 + d] = d == 5 ? -0.0 : Float(d + 1) * 0.5 - Float(i % 3) }
            let k = i % 3
            if k == 0 { e.modePtr[i] = 0; truth[i] = UInt8((i * 37) % 256) }
            else { e.modePtr[i] = UInt8(k) | (i % 2 == 0 ? 4 : 0); truth[i] = UInt8(i % 3) }
            e.ttableIdPtr[i] = UInt16(i % 3)
            e.thrLoPtr[i] = i % 5 == 0 ? -0.0 : -Float(i % 4) * 0.5
            e.thrHiPtr[i] = Float(i % 6) * 0.25
        }
        // Edges: each node at rank r reads up to two nodes at rank r + 1.
        for i in 0..<n where rank[i] < 3 {
            var slot = 0
            for j in 0..<n where rank[j] == rank[i] + 1 && (j + i) % 7 == 0 && slot < 2 {
                nb[i * 6 + slot] = Int32(j); slot += 1
            }
        }
        // A binary register (node 3: rank 3, no fan-in) latching node 5. Its
        // truth byte is a trit byte, so the only rule a ternary mode on it
        // breaks is the register rule.
        e.modePtr[3] = 0
        truth[3] = 2
        for d in 0..<6 { nb[3 * 6 + d] = -1 }
        try e.addBackEdge(src: 5, dst: 3)
        e.markRankTopologyDirty()
        XCTAssertNil(e.ternaryStateViolation())
        XCTAssertNil(DagDBSnapshot.validate(engine: e, nodeCount: n))
        return e
    }

    /// SHA-256 over every lane, the back-edge list and the library.
    static func stateHash(_ e: DagDBEngine) -> String {
        let n = e.nodeCount
        var h = SHA256()
        func lane(_ b: MTLBuffer, _ bytes: Int) { h.update(data: Data(bytes: b.contents(), count: bytes)) }
        lane(e.rankBuf, n * 8); lane(e.truthStateBuf, n); lane(e.nodeTypeBuf, n)
        lane(e.lut6LowBuf, n * 4); lane(e.lut6HighBuf, n * 4); lane(e.neighborsBuf, n * 24)
        lane(e.isRegisterBuf, n); lane(e.edgeWeightsBuf, n * 24); lane(e.activationBuf, n * 2)
        lane(e.nodeValueBuf, n * 4); lane(e.nodeModeBuf, n); lane(e.ttableIdBuf, n * 2)
        lane(e.thrLoBuf, n * 4); lane(e.thrHiBuf, n * 4)
        h.update(data: Data(e.libraryBytes()))
        for i in 0..<e.backEdgeCount {
            var s = e.backEdgeSrcs[i], d = e.backEdgeDsts[i]
            h.update(data: Data(bytes: &s, count: 4)); h.update(data: Data(bytes: &d, count: 4))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Every format carries every lane and the library (JSON/CSV from v2), so the destination starts fresh and the
    /// whole-state hash must match.
    private func assertEqualState(_ a: DagDBEngine, _ b: DagDBEngine, _ what: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Self.stateHash(a), Self.stateHash(b), "\(what): state differs after the round trip",
                       file: file, line: line)
    }

    // MARK: - Round trips

    func testRoundTripDagsV8PlainAndZlib() throws {
        let a = try ternaryEngine()
        for compressed in [false, true] {
            let path = tmp + "rt_\(compressed).dags"
            _ = try DagDBSnapshot.save(engine: a, nodeCount: a.nodeCount, gridW: side, gridH: side,
                                       tickCount: 9, path: path, compressed: compressed)
            let d = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertEqual(d[4], 8, "a graph with ternary content is written as v8")
            XCTAssertEqual(d.subdata(in: 28..<32), Data([0xFF, 0xFF, 0xFF, 0xFF]), "bodyBytes@28 is the sentinel")
            // Offsets 8 (nodeCount) and 20 (tickCount) keep their meaning (tile peeks).
            XCTAssertEqual(d.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, UInt32(a.nodeCount))
            XCTAssertEqual(d.subdata(in: 20..<24).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, 9)
            XCTAssertEqual(d.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, compressed ? 1 : 0)
            let bodyLen = d.subdata(in: 32..<40).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            if !compressed { XCTAssertEqual(bodyLen, UInt64(53 * a.nodeCount)) }
            // The TERN section sits after WGTS and carries the three tables.
            let tern = try XCTUnwrap(d.range(of: Data("TERN".utf8), in: (40 + Int(bodyLen))..<d.count)).lowerBound
            let wgts = try XCTUnwrap(d.range(of: Data("WGTS".utf8), in: (40 + Int(bodyLen))..<d.count)).lowerBound
            XCTAssertLessThan(wgts, tern)
            XCTAssertEqual(d[tern + 4], 1, "library-present flag")
            XCTAssertEqual(d.subdata(in: (tern + 5)..<(tern + 9)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, 3)
            XCTAssertEqual([UInt8](d.subdata(in: (tern + 9)..<(tern + 9 + 3 * 729))), a.libraryBytes())
            let b = try fresh()
            let r = try DagDBSnapshot.load(engine: b, nodeCount: b.nodeCount, gridW: side, gridH: side, path: path)
            XCTAssertEqual(r.bytesRead, d.count, "every section accounted for")
            XCTAssertEqual(r.fileTicks, 9)
            assertEqualState(a, b, ".dags v8 compressed=\(compressed)")
        }
    }

    func testRoundTripWALv3Replay() throws {
        let path = tmp + "rt.wal"
        let a = try fresh()
        let n = a.nodeCount
        do {
            let w = try DagDBWAL.Appender(path: path, nodeCount: n)
            // Drive the appender exactly as the handler does, mirroring the
            // writes into `a` so the two can be compared.
            let t0 = try TernaryReference.presetTable(.tcons, k: 4)
            _ = try w.ttableDefine(tid: 0, table: t0); try a.writeTables(first: 0, bytes: t0)
            _ = try w.ttablePreset(tid: 1, preset: .tmax, k: 3)
            try a.writeTables(first: 1, bytes: try TernaryReference.presetTable(.tmax, k: 3))
            let bulk = (0..<(2 * 729)).map { UInt8($0 % 3) }
            _ = try bulk.withUnsafeBufferPointer { try w.ttableBulk(first: 2, count: 2, bytes: $0) }
            try a.writeTables(first: 2, bytes: bulk)
            var ids = (0..<n).map { UInt16($0 % 4) }
            _ = try w.setTTableIdsBulk(&ids, count: n)
            for i in 0..<n { a.ttableIdPtr[i] = ids[i] }
            var thr = (0..<(2 * n)).map { $0 % 2 == 0 ? -Float($0 % 5) : Float($0 % 7) }
            _ = try w.setThreshBulk(&thr, count: n)
            for i in 0..<n { a.thrLoPtr[i] = thr[2 * i]; a.thrHiPtr[i] = thr[2 * i + 1] }
            var modes = (0..<n).map { UInt8([0, 1, 2, 5, 6][$0 % 5]) }
            _ = try w.setModesBulk(&modes, count: n)
            for i in 0..<n { a.modePtr[i] = modes[i] }
            _ = try w.setMode(node: 7, mode: 6); a.modePtr[7] = 6
            _ = try w.setTTableId(node: 8, tid: 3); a.ttableIdPtr[8] = 3
            _ = try w.setThresh(node: 9, lo: -0.0, hi: 0.5); a.thrLoPtr[9] = -0.0; a.thrHiPtr[9] = 0.5
            _ = try w.setTrit(node: 10, trit: -1)
            a.truthStateBuf.contents().storeBytes(of: 0, toByteOffset: 10, as: UInt8.self)
            let composed = (0..<729).map { UInt8(($0 + 1) % 3) }
            _ = try w.ttableCompose(dst: 11, tid: 4, table: composed)
            try a.writeTables(first: 4, bytes: composed); a.ttableIdPtr[11] = 4
        }
        let b = try fresh()
        let r = try DagDBWAL.replay(engine: b, nodeCount: n, path: path)
        XCTAssertEqual(r.fileVersion, DagDBWAL.versionV3)
        XCTAssertEqual(r.recordsSkipped, 0)
        XCTAssertEqual(r.refusals, [])
        assertEqualState(a, b, "WAL v3")
    }

    func testRoundTripBackupDiff3AndMixedChain() throws {
        let dir = tmp + "chain"
        let a = try fresh()
        // Base: binary (written as v7); diff 1: a binary change (format 2);
        // diff 2: ternary content arrives (format 3); diff 3: lanes change again.
        _ = try DagDBBackup.initializeChain(engine: a, nodeCount: a.nodeCount, gridW: side, gridH: side,
                                            tickCount: 0, dir: dir)
        a.truthStateBuf.contents().storeBytes(of: 1, toByteOffset: 2, as: UInt8.self)
        let d1 = try DagDBBackup.appendDiff(engine: a, nodeCount: a.nodeCount, gridW: side, gridH: side, dir: dir)
        XCTAssertEqual(d1.format, 2)
        let t = try ternaryEngine()
        // Copy t's whole state into a by a snapshot round trip, then append.
        let p = tmp + "t.dags"
        _ = try DagDBSnapshot.save(engine: t, nodeCount: t.nodeCount, gridW: side, gridH: side, tickCount: 0, path: p)
        _ = try DagDBSnapshot.load(engine: a, nodeCount: a.nodeCount, gridW: side, gridH: side, path: p)
        let d2 = try DagDBBackup.appendDiff(engine: a, nodeCount: a.nodeCount, gridW: side, gridH: side, dir: dir)
        XCTAssertEqual(d2.format, 3)
        a.modePtr[1] = 2; a.thrHiPtr[1] = 3.5
        try a.writeTables(first: 3, bytes: [UInt8](repeating: 1, count: 729))
        let d3 = try DagDBBackup.appendDiff(engine: a, nodeCount: a.nodeCount, gridW: side, gridH: side, dir: dir)
        XCTAssertEqual(d3.format, 3)
        let b = try fresh()
        let r = try DagDBBackup.restore(engine: b, nodeCount: b.nodeCount, gridW: side, gridH: side, dir: dir)
        XCTAssertEqual(r.diffsReplayed, 3)
        assertEqualState(a, b, "backup diff 3 (mixed chain 2, 3, 3)")
        // COMPACT folds it into a v8 base that restores the same state.
        _ = try DagDBBackup.compact(nodeCount: a.nodeCount, gridW: side, gridH: side, dir: dir)
        let c = try fresh()
        _ = try DagDBBackup.restore(engine: c, nodeCount: c.nodeCount, gridW: side, gridH: side, dir: dir)
        assertEqualState(a, c, "backup after COMPACT")
    }

    func testRoundTripJSONv2() throws {
        let a = try ternaryEngine()
        let path = tmp + "rt.json"
        _ = try DagDBJSONIO.saveJSON(engine: a, nodeCount: a.nodeCount, gridW: side, gridH: side, tickCount: 4, path: path)
        let obj = try JSONSerialization.jsonObject(with: try Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        XCTAssertEqual(obj["version"] as? Int, 2)
        let b = try fresh()
        _ = try DagDBJSONIO.loadJSON(engine: b, nodeCount: b.nodeCount, gridW: side, gridH: side, path: path)
        assertEqualState(a, b, "JSON v2")
    }

    func testRoundTripCSVv2() throws {
        let a = try ternaryEngine()
        let dir = tmp + "rt_csv"
        _ = try DagDBJSONIO.saveCSV(engine: a, nodeCount: a.nodeCount, dir: dir)
        for f in ["nodes.csv", "edges.csv", "lanes.csv", "weights.csv", "back_edges.csv", "ttables.csv"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/" + f), f)
        }
        let b = try fresh()
        _ = try DagDBJSONIO.loadCSV(engine: b, nodeCount: b.nodeCount, dir: dir)
        assertEqualState(a, b, "CSV v2")
    }

    func testRoundTripMorton() throws {
        let a = try ternaryEngine()
        let dir = tmp + "rt_morton"
        _ = try DagDBSnapshot.exportMorton(engine: a, nodeCount: a.nodeCount, dir: dir)
        for f in ["mode.bin", "ttable_id.bin", "thr_lo.bin", "thr_hi.bin", "ttables.bin"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/" + f), f)
        }
        let b = try fresh()
        _ = try DagDBSnapshot.importMorton(engine: b, nodeCount: b.nodeCount, dir: dir)
        assertEqualState(a, b, "Morton")
        // Optional files absent ⇒ BINARY defaults and an empty library.
        for f in ["mode.bin", "ttable_id.bin", "thr_lo.bin", "thr_hi.bin", "ttables.bin"] {
            try FileManager.default.removeItem(atPath: dir + "/" + f)
        }
        // Without the mode lane the Loom bytes on binary nodes are fine and
        // every node is binary.
        _ = try DagDBSnapshot.importMorton(engine: b, nodeCount: b.nodeCount, dir: dir)
        XCTAssertNil(b.firstNonBinaryNode())
        XCTAssertEqual(b.ttableCount, 0)
    }

    func testRoundTripReaderSession() throws {
        let a = try ternaryEngine()
        let mgr = DagDBReaderSessionManager()
        let s = try mgr.open(primary: a, grid: try HexGrid(width: side, height: side),
                             stateTemplate: DagDBState(width: side, height: side), maxRank: 8, tickCount: 0)
        assertEqualState(a, s.snapshotEngine, "reader session")
    }

    // MARK: - Old files load identically

    func testBinaryGraphSavesV7AndLoadsIdentically() throws {
        let a = try fresh()
        a.truthStateBuf.contents().storeBytes(of: 200, toByteOffset: 4, as: UInt8.self)
        let path = tmp + "bin.dags"
        let saved = try DagDBSnapshot.save(engine: a, nodeCount: a.nodeCount, gridW: side, gridH: side,
                                           tickCount: 1, path: path)
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(d[4], 7, "no ternary content ⇒ v7, byte for byte as before")
        XCTAssertEqual(saved.uncompressedBodyBytes, a.nodeCount * 42)
        // Loading the v7 file into an engine holding ternary content resets
        // that content: the file describes a binary graph.
        let b = try ternaryEngine()
        _ = try DagDBSnapshot.load(engine: b, nodeCount: b.nodeCount, gridW: side, gridH: side, path: path)
        assertEqualState(a, b, "v7 load")
    }

    func testWALv2LogStillReplays() throws {
        let path = tmp + "v2.wal"
        var f = Data("DAGW".utf8)
        for v in [UInt32(2), UInt32(side * side), 0] { var x = v; f.append(Data(bytes: &x, count: 4)) }
        func rec(_ op: UInt8, _ payload: Data) -> Data {
            var len = UInt32(payload.count); var d = Data(bytes: &len, count: 4); d.append(op); d.append(payload); return d
        }
        var node: UInt32 = 6; var val: UInt8 = 1
        f.append(rec(0x01, Data(bytes: &node, count: 4) + Data(bytes: &val, count: 1)))
        // A ternary opcode inside a v2 log is not part of v2: unknown there.
        f.append(rec(0x40, Data(bytes: &node, count: 4) + Data([1])))
        try f.write(to: URL(fileURLWithPath: path))
        let e = try fresh()
        let r = try DagDBWAL.replay(engine: e, nodeCount: e.nodeCount, path: path)
        XCTAssertEqual(r.fileVersion, 2)
        XCTAssertEqual(r.recordsApplied, 1)
        XCTAssertEqual(r.skipReasons.unknownOpcode, 1)
        XCTAssertEqual(e.truthStateBuf.contents().load(fromByteOffset: 6, as: UInt8.self), 1)
        // A v2 log is appendable for v2 ops and refuses a ternary op by name.
        let w = try DagDBWAL.Appender(path: path, nodeCount: e.nodeCount)
        XCTAssertEqual(w.fileVersion, 2)
        XCTAssertThrowsError(try w.setMode(node: 1, mode: 1)) {
            XCTAssertTrue("\($0)".contains("needs log version 3"), "\($0)")
        }
    }

    func testJSONv1StillLoads() throws {
        let a = try fresh()
        let path = tmp + "v1.json"
        _ = try DagDBJSONIO.saveJSON(engine: a, nodeCount: a.nodeCount, gridW: side, gridH: side, tickCount: 2, path: path)
        var obj = try JSONSerialization.jsonObject(with: try Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        for k in ["edgeWeightsBits", "activation", "nodeValueBits", "backEdges", "nodeMode", "ttableId",
                  "thrLoBits", "thrHiBits", "ttables"] { obj.removeValue(forKey: k) }
        obj["version"] = 1
        var truth = obj["truth"] as! [Int]; truth[3] = 300           // v1 keeps its truncation
        obj["truth"] = truth
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: path))
        let b = try ternaryEngine()
        _ = try DagDBJSONIO.loadJSON(engine: b, nodeCount: b.nodeCount, gridW: side, gridH: side, path: path, validate: false)
        XCTAssertEqual(b.truthStateBuf.contents().load(fromByteOffset: 3, as: UInt8.self), UInt8(truncatingIfNeeded: 300))
        XCTAssertNil(b.firstNonBinaryNode(), "a v1 file describes a binary graph")
        XCTAssertEqual(b.ttableCount, 0)
        // v2 refuses the same truth instead of truncating it.
        let p2 = tmp + "v2.json"
        _ = try DagDBJSONIO.saveJSON(engine: a, nodeCount: a.nodeCount, gridW: side, gridH: side, tickCount: 2, path: p2)
        var v2 = try JSONSerialization.jsonObject(with: try Data(contentsOf: URL(fileURLWithPath: p2))) as! [String: Any]
        var t2 = v2["truth"] as! [Int]; t2[3] = 300; v2["truth"] = t2
        try JSONSerialization.data(withJSONObject: v2).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try DagDBJSONIO.loadJSON(engine: b, nodeCount: b.nodeCount, gridW: side, gridH: side, path: path)) {
            XCTAssertTrue("\($0)".contains("truth 300 not in 0...255"), "\($0)")
        }
    }

    /// The ternary half of "old files load identically" (TernaryR4OldFilesTests
    /// holds main's half): every old file main wrote, loaded over an engine
    /// that holds ternary content, leaves the four lanes at BINARY defaults and
    /// the library empty — and where the loader replaces every lane (.dags,
    /// Morton, a backup restore) the ten lanes equal main's own load.
    /// Under the slot model v1.json and
    /// csv_v1 keep the live back-edge list, and their slots give the kept
    /// register 3 a combinational input — S4, refused by name; the ternary
    /// content and every lane survive.
    func testOldFilesOverTernaryContentResetIt() throws {
        let scratch = tmp + "old_files"
        let want = try TernaryR4OldFilesTests.stageFixture(into: scratch)
        var checked = 0, hashed = 0, refused = 0
        for w in want where w["kind"] != "wal" {   // a log replays onto a state; it resets nothing
            let name = try XCTUnwrap(w["name"]), kind = try XCTUnwrap(w["kind"])
            let e = try ternaryEngine()
            XCTAssertTrue(e.hasTernaryContent())
            if kind == "json" || kind == "csv" {
                let before = Self.stateHash(e)
                XCTAssertThrowsError(try TernaryR4OldFilesTests.perform(kind: kind, path: scratch + "/" + name, into: e)) { err in
                    guard let r = err as? DagDBEngine.BackEdgeEntryRefusal else {
                        return XCTFail("\(name): expected the kept list's S4 refusal, got \(err)")
                    }
                    XCTAssertEqual(r.list, "kept back edge", name)
                    XCTAssertEqual(r.dst, 3, name)
                    XCTAssertEqual(r.rule, .destinationHasCombinationalInDegree(slot: 2, source: 46), name)
                }
                XCTAssertTrue(e.hasTernaryContent(), "\(name): the refused load reset the ternary content")
                XCTAssertEqual(Self.stateHash(e), before, "\(name): the refused load changed a lane")
                refused += 1; checked += 1
                continue
            }
            let got = try TernaryR4OldFilesTests.perform(kind: kind, path: scratch + "/" + name, into: e)
            XCTAssertFalse(e.hasTernaryContent(), "\(name): ternary content survived an old file's load")
            XCTAssertEqual(e.ttableCount, 0, name)
            XCTAssertNil(e.ternaryStateViolation(), name)
            if ["dags", "morton", "backup"].contains(kind) {
                XCTAssertEqual(got["hash"], w["hash"], "\(name) over ternary content: the ten lanes differ from main's load")
                hashed += 1
            }
            checked += 1
        }
        let wals = want.filter { $0["kind"] == "wal" }.count
        XCTAssertEqual(checked, want.count - wals)
        XCTAssertEqual(refused, want.filter { $0["kind"] == "json" || $0["kind"] == "csv" }.count)
        print("R4 old files over ternary content: \(checked - refused) loads reset the lanes and the library; \(hashed) equal main's ten-lane hash; \(refused) v1 loads (json, csv) refused by name (S4 on the kept list), nothing changed")
    }

    // MARK: - gen_dags.py ("can emit v8 with a ternary option")

    /// Run tools/gen_dags.py with `args`; skip by name when no python3 with
    /// numpy is on PATH (the script's one dependency).
    private func genDags(_ args: [String]) throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/gen_dags.py").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script] + args
        let err = Pipe(), out = Pipe()
        p.standardError = err; p.standardOutput = out
        try p.run(); p.waitUntilExit()
        _ = out.fileHandleForReading.readDataToEndOfFile()
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if p.terminationStatus != 0 && msg.contains("No module named 'numpy'") {
            throw XCTSkip("gen_dags.py needs python3 with numpy on PATH: \(msg)")
        }
        XCTAssertEqual(p.terminationStatus, 0, "gen_dags.py \(args): \(msg)")
    }

    func testGenDagsEmitsV8WithATernaryOption() throws {
        // 40 leaves, fanout 6: 40 → 7 → 2 → 1, so 50 nodes in the 64-node grid.
        let leaves = 40, total = 40 + 7 + 2 + 1
        let v1 = tmp + "gen_v1.dags", v8 = tmp + "gen_v8.dags", t8 = tmp + "gen_tern.dags"
        try genDags(["--grid", "\(side)", "--nodes", "\(leaves)", "--out", v1])
        try genDags(["--grid", "\(side)", "--nodes", "\(leaves)", "--v8", "--out", v8])
        try genDags(["--grid", "\(side)", "--nodes", "\(leaves)", "--ternary", "--out", t8])
        for (path, ver) in [(v1, UInt8(1)), (v8, 8), (t8, 8)] {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path))[4], ver, path)
        }
        // v8 without the option is the v1 graph, lane for lane.
        let a = try fresh(), b = try fresh()
        let ra = try DagDBSnapshot.load(engine: a, nodeCount: a.nodeCount, gridW: side, gridH: side, path: v1)
        let rb = try DagDBSnapshot.load(engine: b, nodeCount: b.nodeCount, gridW: side, gridH: side, path: v8)
        XCTAssertEqual(rb.bytesRead, try Data(contentsOf: URL(fileURLWithPath: v8)).count)
        XCTAssertEqual(ra.bytesRead, try Data(contentsOf: URL(fileURLWithPath: v1)).count)
        assertEqualState(a, b, "gen_dags --v8 vs v1")
        XCTAssertFalse(b.hasTernaryContent())
        // --ternary: every aggregator is TTABLE 0 = TSUM over six slots,
        // holding UNDEFINED; leaves and padding stay binary.
        let t = try fresh()
        let rt = try DagDBSnapshot.load(engine: t, nodeCount: t.nodeCount, gridW: side, gridH: side, path: t8)
        XCTAssertEqual(rt.bytesRead, try Data(contentsOf: URL(fileURLWithPath: t8)).count)
        XCTAssertEqual(t.libraryBytes(), try TernaryReference.presetTable(.tsum, k: 6))
        for i in 0..<t.nodeCount {
            let agg = i >= leaves && i < total
            XCTAssertEqual(t.modePtr[i], agg ? 1 : 0, "node \(i)")
            XCTAssertEqual(t.ttableIdPtr[i], 0)
            if agg { XCTAssertEqual(t.truthStateBuf.contents().load(fromByteOffset: i, as: UInt8.self), 2) }
        }
        // It ticks: the root reads +1 once the trits climb (CONST1 leaves).
        for k in 0..<4 { t.tick(tickNumber: UInt32(k)) }
        let root = total - 1
        XCTAssertEqual(t.truthStateBuf.contents().load(fromByteOffset: root, as: UInt8.self), 1, "TSUM of +1 inputs is +1")
    }

    // MARK: - The u64 body length at the size that needs it

    /// Rewrite the u64 at offset 32 of a v8 file and refresh its sidecar.
    private func setBodyLength(path: String, _ len: UInt64) throws {
        var d = try Data(contentsOf: URL(fileURLWithPath: path))
        var v = len.littleEndian
        d.replaceSubrange(32..<40, with: Data(bytes: &v, count: 8))
        try d.write(to: URL(fileURLWithPath: path))
        try refreshSidecar(path: path, d)
    }

    private func refreshSidecar(path: String, _ d: Data) throws {
        let hex = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        try Data((hex + "\n").utf8).write(to: URL(fileURLWithPath: path + ".sha256"))
    }

    func testU64BodyLength() throws {
        // At 100M nodes the 53-byte body is 53 × 100,000,000 = 5,300,000,000
        // bytes, above the u32 field's 4,294,967,295: the v7 header refuses it
        // by name, the v8 header carries it whole in the u64.
        let n100M = 100_000_000
        let big = DagDBSnapshot.v8BodyBytesPerNode * n100M
        XCTAssertEqual(big, 5_300_000_000)
        XCTAssertGreaterThan(big, Int(UInt32.max))
        XCTAssertThrowsError(try DagDBSnapshot.buildHeader(nodeCount: n100M, gridW: 10_000, gridH: 10_000,
                                                           tickCount: 3, flags: [], bodyBytes: big)) {
            XCTAssertTrue("\($0)".contains("'bodyBytes'"), "\($0)")
        }
        let h = try DagDBSnapshot.buildHeaderV8(nodeCount: n100M, gridW: 10_000, gridH: 10_000,
                                                tickCount: 3, flags: [], bodyLength: big)
        XCTAssertEqual(h.count, 40)
        XCTAssertEqual(h.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, 8)
        XCTAssertEqual(h.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, UInt32(n100M))
        XCTAssertEqual(h.subdata(in: 20..<24).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, 3)
        XCTAssertEqual(h.subdata(in: 28..<32), Data([0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertEqual(h.subdata(in: 32..<40).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }, UInt64(big))

        // The loader reads all 64 bits: a length of 2^32 + the true length
        // (whose low 32 bits ARE the true length) is refused, plain and zlib.
        let a = try ternaryEngine()
        for compressed in [false, true] {
            let path = tmp + "u64_\(compressed).dags"
            _ = try DagDBSnapshot.save(engine: a, nodeCount: a.nodeCount, gridW: side, gridH: side,
                                       tickCount: 0, path: path, compressed: compressed)
            let d = try Data(contentsOf: URL(fileURLWithPath: path))
            let trueLen = d.subdata(in: 32..<40).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            let target = try fresh()
            let before = Self.stateHash(target)
            try setBodyLength(path: path, (UInt64(1) << 32) + trueLen)
            XCTAssertThrowsError(try DagDBSnapshot.load(engine: target, nodeCount: target.nodeCount,
                                                        gridW: side, gridH: side, path: path)) {
                XCTAssertTrue("\($0)".contains("\((UInt64(1) << 32) + trueLen)"), "compressed=\(compressed): \($0)")
            }
            // A zero length is a wrong length in v8, not v1's legacy marker.
            try setBodyLength(path: path, 0)
            XCTAssertThrowsError(try DagDBSnapshot.load(engine: target, nodeCount: target.nodeCount,
                                                        gridW: side, gridH: side, path: path)) {
                XCTAssertTrue("\($0)".contains("body size 0 != expected \(53 * a.nodeCount)"), "compressed=\(compressed): \($0)")
            }
            XCTAssertEqual(Self.stateHash(target), before, "a refused load wrote something")
            // And the true length loads.
            try setBodyLength(path: path, trueLen)
            _ = try DagDBSnapshot.load(engine: target, nodeCount: target.nodeCount, gridW: side, gridH: side, path: path)
            assertEqualState(a, target, "u64 restored, compressed=\(compressed)")
        }
    }

    func testTernSectionFlagsAndCountRefusedOnLoad() throws {
        let a = try ternaryEngine()
        let path = tmp + "tern_flags.dags"
        for (flags, needle) in [(UInt8(0x03), "unknown flag bit(s) 0x02 in the TERN section"),
                                (UInt8(0x81), "unknown flag bit(s) 0x80 in the TERN section"),
                                (UInt8(0x00), "library flag 0 disagrees with table count 3")] {
            _ = try DagDBSnapshot.save(engine: a, nodeCount: a.nodeCount, gridW: side, gridH: side, tickCount: 0, path: path)
            var d = try Data(contentsOf: URL(fileURLWithPath: path))
            let at = try XCTUnwrap(d.range(of: Data("TERN".utf8), in: (40 + 53 * a.nodeCount)..<d.count)).lowerBound
            d[at + 4] = flags
            try d.write(to: URL(fileURLWithPath: path))
            try refreshSidecar(path: path, d)
            let target = try fresh()
            let before = Self.stateHash(target)
            XCTAssertThrowsError(try DagDBSnapshot.load(engine: target, nodeCount: target.nodeCount,
                                                        gridW: side, gridH: side, path: path)) {
                XCTAssertTrue("\($0)".contains(needle), "flags 0x\(String(flags, radix: 16)): \($0)")
            }
            XCTAssertEqual(Self.stateHash(target), before)
        }
    }

    func testDiff2StillApplies() throws {
        // A chain written entirely in format 2 (a binary engine) restores.
        let dir = tmp + "chain2"
        let a = try fresh()
        _ = try DagDBBackup.initializeChain(engine: a, nodeCount: a.nodeCount, gridW: side, gridH: side, tickCount: 0, dir: dir)
        a.truthStateBuf.contents().storeBytes(of: 1, toByteOffset: 9, as: UInt8.self)
        XCTAssertEqual(try DagDBBackup.appendDiff(engine: a, nodeCount: a.nodeCount, gridW: side, gridH: side, dir: dir).format, 2)
        let b = try ternaryEngine()
        _ = try DagDBBackup.restore(engine: b, nodeCount: b.nodeCount, gridW: side, gridH: side, dir: dir)
        assertEqualState(a, b, "format-2 chain")
    }

    // MARK: - Refusals, by name, on write and on load

    /// Each violation as an edit of an engine's live buffers, with the words
    /// its refusal must carry.
    private var violations: [(name: String, needle: String, apply: (DagDBEngine) -> Void)] {
        [
            ("mode bits 3-7", "reserved bits", { $0.modePtr[13] = 0x09 }),
            ("kind 3", "kind 3", { $0.modePtr[13] = 3 }),
            ("ttableId >= library size", "not below the library size", { $0.modePtr[13] = 1; $0.ttableIdPtr[13] = 3 }),
            ("lo > hi", "> hi", { $0.thrLoPtr[13] = 2; $0.thrHiPtr[13] = 1 }),
            ("NaN threshold", "not finite", { $0.thrLoPtr[13] = .nan }),
            ("table byte >= 3", "byte 5 is 3", { $0.ttableBuf.contents().storeBytes(of: 3, toByteOffset: 729 + 5, as: UInt8.self) }),
            ("truth >= 3 on a ternary node", "truth byte 9 on a ternary node", {
                $0.modePtr[13] = 2; $0.truthStateBuf.contents().storeBytes(of: 9, toByteOffset: 13, as: UInt8.self) }),
            ("NOSKIP on a BINARY node", "NOSKIP on a BINARY node", { $0.modePtr[13] = 4 }),
            ("a ternary register", "register", { $0.modePtr[3] = 1 }),
        ]
    }

    func testEveryRefusalOnWriteForEveryFormat() throws {
        var checked = 0
        for v in violations {
            let e = try ternaryEngine()
            v.apply(e)
            func expectRefused(_ what: String, _ body: () throws -> Void) {
                XCTAssertThrowsError(try body(), "\(v.name) on \(what)") { err in
                    XCTAssertTrue("\(err)".contains("ternary"), "\(v.name) on \(what): \(err)")
                    XCTAssertTrue("\(err)".contains(v.needle), "\(v.name) on \(what): \(err)")
                }
                checked += 1
            }
            expectRefused(".dags") { _ = try DagDBSnapshot.save(engine: e, nodeCount: e.nodeCount, gridW: side, gridH: side, tickCount: 0, path: tmp + "w.dags") }
            expectRefused(".dags zlib") { _ = try DagDBSnapshot.save(engine: e, nodeCount: e.nodeCount, gridW: side, gridH: side, tickCount: 0, path: tmp + "wz.dags", compressed: true) }
            expectRefused("Morton") { _ = try DagDBSnapshot.exportMorton(engine: e, nodeCount: e.nodeCount, dir: tmp + "wm") }
            expectRefused("JSON") { _ = try DagDBJSONIO.saveJSON(engine: e, nodeCount: e.nodeCount, gridW: side, gridH: side, tickCount: 0, path: tmp + "w.json") }
            expectRefused("CSV") { _ = try DagDBJSONIO.saveCSV(engine: e, nodeCount: e.nodeCount, dir: tmp + "wc") }
            // A refused write leaves nothing behind (no file, no temp, no directory).
            for p in ["w.dags", "w.dags.tmp", "w.dags.sha256", "wz.dags", "wz.dags.tmp", "wm", "w.json", "w.json.tmp", "wc"] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: tmp + p), "\(v.name): \(p) written")
            }
            // Backup: a chain started from a valid state, appended invalid.
            let dir = tmp + "wb_\(checked)"
            let ok = try ternaryEngine()
            _ = try DagDBBackup.initializeChain(engine: ok, nodeCount: ok.nodeCount, gridW: side, gridH: side, tickCount: 0, dir: dir)
            let chainBefore = try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
            expectRefused("backup diff") { _ = try DagDBBackup.appendDiff(engine: e, nodeCount: e.nodeCount, gridW: side, gridH: side, dir: dir) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir).sorted(), chainBefore, "\(v.name): a refused APPEND wrote a diff")
            expectRefused("backup base") { _ = try DagDBBackup.initializeChain(engine: e, nodeCount: e.nodeCount, gridW: side, gridH: side, tickCount: 0, dir: dir + "_b") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "_b/base.dags"), "\(v.name): a refused base was written")
        }
        // WAL, on write: the appender refuses the values it can see.
        let w = try DagDBWAL.Appender(path: tmp + "w.wal", nodeCount: side * side)
        XCTAssertThrowsError(try w.setMode(node: 1, mode: 0x09)) { XCTAssertTrue("\($0)".contains("reserved bits")) }
        XCTAssertThrowsError(try w.setMode(node: 1, mode: 3)) { XCTAssertTrue("\($0)".contains("kind 3")) }
        XCTAssertThrowsError(try w.setMode(node: 1, mode: 4)) { XCTAssertTrue("\($0)".contains("NOSKIP on a BINARY node")) }
        XCTAssertThrowsError(try w.setThresh(node: 1, lo: 2, hi: 1)) { XCTAssertTrue("\($0)".contains("> hi")) }
        XCTAssertThrowsError(try w.setThresh(node: 1, lo: .nan, hi: 1)) { XCTAssertTrue("\($0)".contains("not finite")) }
        var bad = [UInt8](repeating: 1, count: 729); bad[5] = 3
        XCTAssertThrowsError(try w.ttableDefine(tid: 0, table: bad)) { XCTAssertTrue("\($0)".contains("byte 5 is 3")) }
        XCTAssertThrowsError(try w.setTrit(node: 1, trit: 2)) { XCTAssertTrue("\($0)".contains("trit 2")) }
        // .dagb, on write: a state with any non-binary node.
        var st = DagDBState(width: side, height: side)
        st.nodeMode[13] = 1
        XCTAssertThrowsError(try DagDBDelta.Encoder(path: tmp + "w.dagb", nodeCount: side * side, maxRank: 8, staticState: st)) {
            XCTAssertTrue("\($0)".contains(".dagb refuses a graph with a non-binary node (node 13"), "\($0)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp + "w.dagb"), "nothing written")
        print("R4 refusals on write: \(checked) format × violation cells + WAL appender + .dagb")
    }

    func testEveryRefusalOnLoadForEveryFormat() throws {
        var checked = 0
        for v in violations {
            // A valid source, written; the violation applied to the bytes on
            // disk through the same edit made to a twin engine that is then
            // written by bypassing the write refusal (the file bytes are what
            // matter here).
            let good = try ternaryEngine()
            let bad = try ternaryEngine()
            v.apply(bad)
            func expectRefused(_ what: String, _ body: () throws -> Void) {
                XCTAssertThrowsError(try body(), "\(v.name) on \(what)") { err in
                    XCTAssertTrue("\(err)".contains(v.needle), "\(v.name) on \(what): \(err)")
                }
                checked += 1
            }
            let target = try fresh()
            let before = Self.stateHash(target)

            // .dags v8: patch the saved good file into the bad state's bytes.
            let path = tmp + "l_\(checked).dags"
            _ = try DagDBSnapshot.save(engine: good, nodeCount: good.nodeCount, gridW: side, gridH: side, tickCount: 0, path: path)
            try patchDags(path: path, from: bad)
            expectRefused(".dags v8") { _ = try DagDBSnapshot.load(engine: target, nodeCount: target.nodeCount, gridW: side, gridH: side, path: path) }

            // .dags v8 zlib: the same bad bytes with the body compressed.
            let zpath = tmp + "lz_\(checked).dags"
            try zlibCopy(of: path, to: zpath, nodeCount: bad.nodeCount)
            expectRefused(".dags v8 zlib") { _ = try DagDBSnapshot.load(engine: target, nodeCount: target.nodeCount, gridW: side, gridH: side, path: zpath) }

            // Morton: the good export with the bad lanes' files.
            let md = tmp + "lm_\(checked)"
            _ = try DagDBSnapshot.exportMorton(engine: good, nodeCount: good.nodeCount, dir: md)
            try Data(bytes: bad.nodeModeBuf.contents(), count: bad.nodeCount).write(to: URL(fileURLWithPath: md + "/mode.bin"))
            try Data(bytes: bad.ttableIdBuf.contents(), count: bad.nodeCount * 2).write(to: URL(fileURLWithPath: md + "/ttable_id.bin"))
            try Data(bytes: bad.thrLoBuf.contents(), count: bad.nodeCount * 4).write(to: URL(fileURLWithPath: md + "/thr_lo.bin"))
            try Data(bytes: bad.thrHiBuf.contents(), count: bad.nodeCount * 4).write(to: URL(fileURLWithPath: md + "/thr_hi.bin"))
            try Data(bytes: bad.truthStateBuf.contents(), count: bad.nodeCount).write(to: URL(fileURLWithPath: md + "/truth.bin"))
            try Data(bad.libraryBytes()).write(to: URL(fileURLWithPath: md + "/ttables.bin"))
            expectRefused("Morton") { _ = try DagDBSnapshot.importMorton(engine: target, nodeCount: target.nodeCount, dir: md) }

            // JSON v2: the good file with the bad lanes' values.
            let jp = tmp + "l_\(checked).json"
            _ = try DagDBJSONIO.saveJSON(engine: good, nodeCount: good.nodeCount, gridW: side, gridH: side, tickCount: 0, path: jp)
            var obj = try JSONSerialization.jsonObject(with: try Data(contentsOf: URL(fileURLWithPath: jp))) as! [String: Any]
            let n = bad.nodeCount
            obj["nodeMode"] = (0..<n).map { Int(bad.modePtr[$0]) }
            obj["ttableId"] = (0..<n).map { Int(bad.ttableIdPtr[$0]) }
            obj["thrLoBits"] = (0..<n).map { Int(bad.thrLoPtr[$0].bitPattern) }
            obj["thrHiBits"] = (0..<n).map { Int(bad.thrHiPtr[$0].bitPattern) }
            obj["truth"] = (0..<n).map { Int(bad.truthStateBuf.contents().load(fromByteOffset: $0, as: UInt8.self)) }
            let lib = bad.libraryBytes()
            obj["ttables"] = stride(from: 0, to: lib.count, by: 729).map { o in
                String(lib[o..<(o + 729)].map { $0 >= 3 ? "x" : TernaryReference.char(ofTableByte: $0) }) }
            try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: jp))
            if v.name == "table byte >= 3" {
                // JSON's table text cannot hold a byte ≥ 3; its character is refused by name.
                XCTAssertThrowsError(try DagDBJSONIO.loadJSON(engine: target, nodeCount: n, gridW: side, gridH: side, path: jp)) {
                    XCTAssertTrue("\($0)".contains("holds \"x\""), "\($0)") }
                checked += 1
            } else {
                expectRefused("JSON v2") { _ = try DagDBJSONIO.loadJSON(engine: target, nodeCount: n, gridW: side, gridH: side, path: jp) }
            }

            // CSV v2: the good directory with the bad lanes.csv / truth / tables.
            let cd = tmp + "lc_\(checked)"
            _ = try DagDBJSONIO.saveCSV(engine: good, nodeCount: n, dir: cd)
            var lanes = "id,mode,ttable_id,thr_lo,thr_hi,activation,node_value\n"
            for i in 0..<n {
                lanes += "\(i),\(bad.modePtr[i]),\(bad.ttableIdPtr[i]),\(DagDBJSONIO.floatText(bad.thrLoPtr[i])),\(DagDBJSONIO.floatText(bad.thrHiPtr[i])),0,0.0\n"
            }
            try lanes.write(toFile: cd + "/lanes.csv", atomically: true, encoding: .utf8)
            var nodes = try String(contentsOfFile: cd + "/nodes.csv", encoding: .utf8).split(separator: "\n").map(String.init)
            for i in 0..<n {
                var p = nodes[i + 1].split(separator: ",").map(String.init)
                p[2] = "\(bad.truthStateBuf.contents().load(fromByteOffset: i, as: UInt8.self))"
                nodes[i + 1] = p.joined(separator: ",")
            }
            try (nodes.joined(separator: "\n") + "\n").write(toFile: cd + "/nodes.csv", atomically: true, encoding: .utf8)
            var tt = "tid,table\n"
            for k in 0..<bad.ttableCount {
                tt += "\(k)," + String(lib[(k * 729)..<(k * 729 + 729)].map { $0 >= 3 ? "x" : TernaryReference.char(ofTableByte: $0) }) + "\n"
            }
            try tt.write(toFile: cd + "/ttables.csv", atomically: true, encoding: .utf8)
            if v.name == "table byte >= 3" {
                XCTAssertThrowsError(try DagDBJSONIO.loadCSV(engine: target, nodeCount: n, dir: cd)) {
                    XCTAssertTrue("\($0)".contains("holds \"x\""), "\($0)") }
                checked += 1
            } else {
                expectRefused("CSV v2") { _ = try DagDBJSONIO.loadCSV(engine: target, nodeCount: n, dir: cd) }
            }

            // Backup diff 3: a chain whose diff carries the bad state.
            let bd = tmp + "lb_\(checked)"
            _ = try DagDBBackup.initializeChain(engine: good, nodeCount: n, gridW: side, gridH: side, tickCount: 0, dir: bd)
            try writeDiff3(dir: bd, tip: good, to: bad, seq: 1)
            expectRefused("backup diff 3") { _ = try DagDBBackup.restore(engine: target, nodeCount: n, gridW: side, gridH: side, dir: bd) }

            // WAL v3: one record per violation the log can carry, replayed.
            let wp = tmp + "l_\(checked).wal"
            try writeBadWAL(path: wp, violation: v.name)
            let we = try ternaryEngine()
            let r = try DagDBWAL.replay(engine: we, nodeCount: n, path: wp)
            // The truth case's log first sets the Loom byte (a v1 op, applied).
            XCTAssertEqual(r.recordsApplied, v.name == "truth >= 3 on a ternary node" ? 1 : 0, v.name)
            XCTAssertEqual(r.refusals.count, 1, "\(v.name): \(r.refusals)")
            XCTAssertTrue(r.refusals.first?.contains(v.needle) == true, "\(v.name) WAL: \(r.refusals)")
            checked += 1

            XCTAssertEqual(Self.stateHash(target), before, "\(v.name): a refused load wrote something")
        }
        print("R4 refusals on load: \(checked) format × violation cells")
    }

    // MARK: - File surgery helpers (the bytes a writer would never produce)

    /// Rewrite a saved v8 .dags so its truth, four lanes and library are the
    /// bad engine's, and refresh its sidecar so the manifest is not what
    /// refuses it.
    private func patchDags(path: String, from bad: DagDBEngine) throws {
        var d = try Data(contentsOf: URL(fileURLWithPath: path))
        let n = bad.nodeCount
        XCTAssertEqual(d[4], 8)
        let body = 40
        d.replaceSubrange((body + 8 * n)..<(body + 9 * n), with: Data(bytes: bad.truthStateBuf.contents(), count: n))
        let lanes = body + 42 * n
        d.replaceSubrange(lanes..<(lanes + n), with: Data(bytes: bad.nodeModeBuf.contents(), count: n))
        d.replaceSubrange((lanes + n)..<(lanes + 3 * n), with: Data(bytes: bad.ttableIdBuf.contents(), count: 2 * n))
        d.replaceSubrange((lanes + 3 * n)..<(lanes + 7 * n), with: Data(bytes: bad.thrLoBuf.contents(), count: 4 * n))
        d.replaceSubrange((lanes + 7 * n)..<(lanes + 11 * n), with: Data(bytes: bad.thrHiBuf.contents(), count: 4 * n))
        // The TERN section: find its magic, overwrite the tables in place.
        let magic = Data("TERN".utf8)
        let at = try XCTUnwrap(d.range(of: magic, in: (lanes + 11 * n)..<d.count)).lowerBound
        let lib = bad.libraryBytes()
        d.replaceSubrange((at + 9)..<(at + 9 + lib.count), with: Data(lib))
        try d.write(to: URL(fileURLWithPath: path))
        let hex = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        try Data((hex + "\n").utf8).write(to: URL(fileURLWithPath: path + ".sha256"))
    }

    /// The plain v8 file at `path` with its body zlib-compressed (flags bit 0
    /// set, the u64 holding the compressed length), sidecar refreshed.
    private func zlibCopy(of path: String, to out: String, nodeCount n: Int) throws {
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(d[4], 8)
        XCTAssertEqual(d[24], 0, "source is plain")
        let c = DagDBSnapshot.zlibCompress(d.subdata(in: 40..<(40 + 53 * n)))
        var z = d.subdata(in: 0..<24)
        var flags = UInt32(1).littleEndian; z.append(Data(bytes: &flags, count: 4))
        z.append(d.subdata(in: 28..<32))
        var len = UInt64(c.count).littleEndian; z.append(Data(bytes: &len, count: 8))
        z.append(c)
        z.append(d.subdata(in: (40 + 53 * n)..<d.count))
        try z.write(to: URL(fileURLWithPath: out))
        try refreshSidecar(path: out, z)
    }

    /// A format-3 diff from `tip` to `to`, built by hand (APPEND refuses the
    /// bad state), with its sidecar.
    private func writeDiff3(dir: String, tip: DagDBEngine, to bad: DagDBEngine, seq: Int) throws {
        let n = tip.nodeCount
        func bytes(_ e: DagDBEngine) -> [[UInt8]] {
            [(e.rankBuf, 8 * n), (e.truthStateBuf, n), (e.nodeTypeBuf, n), (e.lut6LowBuf, 4 * n),
             (e.lut6HighBuf, 4 * n), (e.neighborsBuf, 24 * n), (e.isRegisterBuf, n), (e.edgeWeightsBuf, 24 * n),
             (e.activationBuf, 2 * n), (e.nodeValueBuf, 4 * n), (e.nodeModeBuf, n), (e.ttableIdBuf, 2 * n),
             (e.thrLoBuf, 4 * n), (e.thrHiBuf, 4 * n)].map {
                Array(UnsafeBufferPointer(start: $0.0.contents().bindMemory(to: UInt8.self, capacity: $0.1), count: $0.1)) }
        }
        let a = bytes(tip), b = bytes(bad)
        var out = Data(DagDBBackup.diffMagic)
        for v in [UInt32(3), UInt32(n), UInt32(seq)] { var x = v; out.append(Data(bytes: &x, count: 4)) }
        for i in 0..<a.count {
            let x = zip(a[i], b[i]).map { $0 ^ $1 }
            let c = DagDBSnapshot.zlibCompress(Data(x))
            var sz = UInt32(c.count); out.append(Data(bytes: &sz, count: 4)); out.append(c)
        }
        for blob in [backEdges(bad), bad.libraryBytes()] {
            let c = DagDBSnapshot.zlibCompress(Data(blob))
            var raw = UInt32(blob.count), sz = UInt32(c.count)
            out.append(Data(bytes: &raw, count: 4)); out.append(Data(bytes: &sz, count: 4)); out.append(c)
        }
        let path = String(format: "%@/%05d.diff", dir, seq)
        try out.write(to: URL(fileURLWithPath: path))
        let hex = SHA256.hash(data: out).map { String(format: "%02x", $0) }.joined()
        try Data((hex + "\n").utf8).write(to: URL(fileURLWithPath: path + ".sha256"))
    }

    private func backEdges(_ e: DagDBEngine) -> [UInt8] {
        var d = Data(); var c = UInt32(e.backEdgeCount); d.append(Data(bytes: &c, count: 4))
        for i in 0..<e.backEdgeCount {
            var s = e.backEdgeSrcs[i], t = e.backEdgeDsts[i]
            d.append(Data(bytes: &s, count: 4)); d.append(Data(bytes: &t, count: 4))
        }
        return [UInt8](d)
    }

    /// A v3 log holding the one record a violation shows up as.
    private func writeBadWAL(path: String, violation: String) throws {
        var f = Data("DAGW".utf8)
        for v in [UInt32(3), UInt32(side * side), 0] { var x = v; f.append(Data(bytes: &x, count: 4)) }
        func rec(_ op: UInt8, _ payload: Data) {
            var len = UInt32(payload.count); f.append(Data(bytes: &len, count: 4)); f.append(op); f.append(payload)
        }
        func u32(_ v: UInt32) -> Data { var x = v; return Data(bytes: &x, count: 4) }
        func f32(_ v: Float) -> Data { u32(v.bitPattern) }
        switch violation {
        case "mode bits 3-7": rec(0x40, u32(13) + Data([0x09]))
        case "kind 3": rec(0x40, u32(13) + Data([3]))
        case "ttableId >= library size": rec(0x41, u32(13) + Data([3, 0]))
        case "lo > hi": rec(0x42, u32(13) + f32(2) + f32(1))
        case "NaN threshold": rec(0x42, u32(13) + f32(.nan) + f32(1))
        case "table byte >= 3":
            var t = [UInt8](repeating: 1, count: 729); t[5] = 3
            rec(0x44, u32(1) + Data(t))
        case "truth >= 3 on a ternary node":
            // Node 0 is binary with a Loom byte (0 · 37 mod 256 = 0 → use 9 via
            // SET_TRUTH first is a v1 op, applied; the mode record then refuses).
            rec(0x01, u32(0) + Data([9]))
            rec(0x40, u32(0) + Data([2]))
        case "NOSKIP on a BINARY node": rec(0x40, u32(13) + Data([4]))
        case "a ternary register": rec(0x40, u32(3) + Data([1]))
        default: XCTFail("no WAL record for \(violation)")
        }
        try f.write(to: URL(fileURLWithPath: path))
    }
}
