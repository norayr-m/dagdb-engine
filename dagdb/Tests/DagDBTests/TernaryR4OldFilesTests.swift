import XCTest
import CryptoKit
@testable import DagDB

/// Old files load identically: v1–v7, WAL v2, diff 2, JSON v1 (and CSV v1,
/// and Morton's eleven-file export).
///
/// The files in `Tests/Fixtures/ternary_r4_old_files/` were written by the
/// MAIN build (record mode, run on a `git archive main dagdb` copy with no
/// file of the ternary build in it but this one):
///   - through main's own writers: `.dags` v7 plain and zlib, JSON v1, CSV v1,
///     an eleven-file Morton export, a format-2 backup chain (base and two
///     diffs) and a v2 WAL;
///   - byte by byte, from the layouts in DagDBSnapshot.swift's header (main
///     has no writer for them): `.dags` v1 (bodyBytes 0, the pre-flags form),
///     v2, v3, v3 zlib, v4, v5 zlib, v6 (three lanes) and v6 zlib (two lanes).
/// Main then loaded every one into a fresh engine with its own loader and
/// recorded the SHA-256 of the ten lanes and the back-edge list, plus each
/// loader's own counts (`hashes.json`, pinned by its sidecar; every fixture
/// file's SHA-256 is pinned inside it).
///
/// Check mode loads every file with THIS build's loader into a fresh engine
/// and requires main's hash and counts exactly. TernaryR4PersistenceTests
/// adds the ternary half: the same files loaded over an engine that holds
/// ternary content reset the four lanes and empty the library.
///
/// THE GENERATOR BELOW IS FROZEN WITH THE FIXTURE; a re-record by a later
/// build is not a control. Record mode (main build only): `DAGDB_TERNARY_R4_RECORD=1
/// swift test --filter TernaryR4OldFilesTests`.
final class TernaryR4OldFilesTests: XCTestCase {

    // MARK: - The frozen generator

    static let side = 8
    static let seed: UInt64 = 0x7E12_0004
    static let tickCount: UInt32 = 7

    struct Rng {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Ranks are drawn in 0..<8 and stored wide — r · 2^33 + 5, beyond u32 —
    /// so a load that narrowed a u64 rank would show; a v1 file stores r
    /// (u8) and a v2 file r · 1000 + 300 (u32, beyond u8). The maps are
    /// monotone, so every edge still reads a strictly higher rank.
    static func wideRank(_ r: UInt64) -> UInt64 { (r << 33) + 5 }
    static func baseRank(_ w: UInt64) -> UInt64 { (w - 5) >> 33 }

    /// A fresh engine: every lane at its default and every slot empty.
    static func freshEngine() throws -> DagDBEngine {
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side), maxRank: 16)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        return e
    }

    /// The old graph: ranks 0..<8 (stored wide, above); random LUTs, node types, truth bytes
    /// 0...255 (Loom codes included), activation and node values; weights
    /// with −0.0 and 1.0 among them; slots read nodes of strictly higher rank
    /// (one in four empty, duplicates emptied); one node in eight is a
    /// register with no combinational slot and one back edge from another
    /// node.
    static func makeOldGraph() throws -> DagDBEngine {
        let e = try freshEngine()
        let n = e.nodeCount
        var rng = Rng(s: seed)
        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let type = e.nodeTypeBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let low = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high = e.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        let w = e.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        let act = e.activationBuf.contents().bindMemory(to: Int16.self, capacity: n)
        let val = e.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)
        var isReg = [Bool](repeating: false, count: n)
        for i in 0..<n {
            rank[i] = wideRank(rng.next() % 8)
            low[i] = UInt32(truncatingIfNeeded: rng.next())
            high[i] = UInt32(truncatingIfNeeded: rng.next())
            truth[i] = UInt8(truncatingIfNeeded: rng.next())
            type[i] = UInt8(truncatingIfNeeded: rng.next())
            act[i] = Int16(truncatingIfNeeded: rng.next())
            val[i] = Float(Int(rng.next() % 2001) - 1000) / 8
            isReg[i] = rng.next() % 8 == 0
        }
        for k in 0..<(n * 6) {
            let u = rng.next() % 16
            w[k] = u == 0 ? -0.0 : (u == 1 ? 1.0 : Float(Int(rng.next() % 4001) - 2000) / 16)
        }
        for i in 0..<n where !isReg[i] {
            let higher = (0..<n).filter { rank[$0] > rank[i] }
            var used = Set<Int32>()
            for d in 0..<6 {
                let u = rng.next()
                guard u % 4 != 0, !higher.isEmpty else { continue }
                let s = Int32(higher[Int((u >> 8) % UInt64(higher.count))])
                if used.insert(s).inserted { nb[i * 6 + d] = s }
            }
        }
        for i in 0..<n where isReg[i] {
            let src = (i + 1 + Int(rng.next() % UInt64(n - 1))) % n
            try e.addBackEdge(src: UInt32(src), dst: UInt32(i))
        }
        e.markRankTopologyDirty()
        return e
    }

    /// SHA-256 over the ten lanes and the back-edge list — main's API only.
    static func tenLaneHash(_ e: DagDBEngine) -> String {
        let n = e.nodeCount
        var h = SHA256()
        func lane(_ b: MTLBuffer, _ bytes: Int) { h.update(data: Data(bytes: b.contents(), count: bytes)) }
        lane(e.rankBuf, n * 8); lane(e.truthStateBuf, n); lane(e.nodeTypeBuf, n)
        lane(e.lut6LowBuf, n * 4); lane(e.lut6HighBuf, n * 4); lane(e.neighborsBuf, n * 24)
        lane(e.isRegisterBuf, n); lane(e.edgeWeightsBuf, n * 24); lane(e.activationBuf, n * 2)
        lane(e.nodeValueBuf, n * 4)
        var c = UInt32(e.backEdgeCount); h.update(data: Data(bytes: &c, count: 4))
        for i in 0..<e.backEdgeCount {
            var s = e.backEdgeSrcs[i], d = e.backEdgeDsts[i]
            h.update(data: Data(bytes: &s, count: 4)); h.update(data: Data(bytes: &d, count: 4))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Hand-built .dags v1–v6 (DagDBSnapshot.swift's header layouts)

    static func u32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }

    /// `lanes`: the v6 WGTS flags (bit 0 weights, bit 1 activation, bit 2
    /// node value). `env`: the v5+ ENVS code.
    static func oldDags(_ e: DagDBEngine, version: UInt32, compressed: Bool,
                        lanes: UInt8 = 0, env: UInt8 = 0) -> Data {
        let n = e.nodeCount
        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        var body = Data()
        switch version {
        case 1: for i in 0..<n { body.append(UInt8(baseRank(rank[i]))) }
        case 2: for i in 0..<n { body.append(u32(UInt32(baseRank(rank[i]) * 1000 + 300))) }
        default: body.append(Data(bytes: e.rankBuf.contents(), count: n * 8))
        }
        body.append(Data(bytes: e.truthStateBuf.contents(), count: n))
        body.append(Data(bytes: e.nodeTypeBuf.contents(), count: n))
        body.append(Data(bytes: e.lut6LowBuf.contents(), count: n * 4))
        body.append(Data(bytes: e.lut6HighBuf.contents(), count: n * 4))
        body.append(Data(bytes: e.neighborsBuf.contents(), count: n * 24))
        let onDisk = compressed ? DagDBSnapshot.zlibCompress(body) : body
        var f = Data(DagDBSnapshot.magic)
        f.append(u32(version)); f.append(u32(UInt32(n)))
        f.append(u32(UInt32(side))); f.append(u32(UInt32(side))); f.append(u32(tickCount))
        f.append(u32(compressed ? 1 : 0))
        f.append(u32(version == 1 ? 0 : UInt32(onDisk.count)))
        f.append(onDisk)
        if version >= 4 {
            f.append(u32(UInt32(e.backEdgeCount)))
            for i in 0..<e.backEdgeCount { f.append(u32(e.backEdgeSrcs[i])); f.append(u32(e.backEdgeDsts[i])) }
        }
        if version >= 6 {
            f.append(Data(DagDBSnapshot.laneSectionMagic)); f.append(lanes)
            if lanes & 1 != 0 { f.append(Data(bytes: e.edgeWeightsBuf.contents(), count: n * 24)) }
            if lanes & 2 != 0 { f.append(Data(bytes: e.activationBuf.contents(), count: n * 2)) }
            if lanes & 4 != 0 { f.append(Data(bytes: e.nodeValueBuf.contents(), count: n * 4)) }
        }
        if version >= 5 { f.append(Data(DagDBSnapshot.envTrailerMagic)); f.append(env) }
        return f
    }

    // MARK: - The old files

    static let handBuilt: [(name: String, version: UInt32, compressed: Bool, lanes: UInt8, env: UInt8)] = [
        ("v1.dags", 1, false, 0, 0),
        ("v2.dags", 2, false, 0, 0),
        ("v3.dags", 3, false, 0, 0),
        ("v3z.dags", 3, true, 0, 0),
        ("v4.dags", 4, false, 0, 0),
        ("v5z.dags", 5, true, 0, 1),
        ("v6.dags", 6, false, 7, 0),
        ("v6z.dags", 6, true, 5, 2),
    ]

    /// Write every old file into `dir` with the running build's writers —
    /// RECORD MODE ONLY (on main these are main's writers).
    static func writeOldFiles(dir: String) throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: dir)
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let g = try makeOldGraph()
        let n = g.nodeCount
        for h in handBuilt {
            try oldDags(g, version: h.version, compressed: h.compressed, lanes: h.lanes, env: h.env)
                .write(to: URL(fileURLWithPath: dir + "/" + h.name))
        }
        _ = try DagDBSnapshot.save(engine: g, nodeCount: n, gridW: side, gridH: side,
                                   tickCount: tickCount, path: dir + "/v7.dags")
        _ = try DagDBSnapshot.save(engine: g, nodeCount: n, gridW: side, gridH: side,
                                   tickCount: tickCount, path: dir + "/v7z.dags", compressed: true)
        _ = try DagDBJSONIO.saveJSON(engine: g, nodeCount: n, gridW: side, gridH: side,
                                     tickCount: tickCount, path: dir + "/v1.json")
        _ = try DagDBJSONIO.saveCSV(engine: g, nodeCount: n, dir: dir + "/csv_v1")
        _ = try DagDBSnapshot.exportMorton(engine: g, nodeCount: n, dir: dir + "/morton")

        // A format-2 chain: the base, then two diffs of binary changes.
        let chain = dir + "/chain"
        _ = try DagDBBackup.initializeChain(engine: g, nodeCount: n, gridW: side, gridH: side,
                                            tickCount: tickCount, dir: chain)
        let truth = g.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let w = g.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        let val = g.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)
        let low = g.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        for i in stride(from: 0, to: n, by: 3) { truth[i] = truth[i] &+ 101 }
        w[5] = 0.25; val[9] = -3.5
        _ = try DagDBBackup.appendDiff(engine: g, nodeCount: n, gridW: side, gridH: side, dir: chain)
        for i in stride(from: 1, to: n, by: 5) { low[i] ^= 0xA5A5_5A5A; truth[i] = 200 }
        let freeNode = try XCTUnwrap((0..<n).first { i in
            (0..<6).allSatisfy { g.neighborsBuf.contents().load(fromByteOffset: (i * 6 + $0) * 4, as: Int32.self) < 0 }
                && !g.backEdgeDsts.contains(UInt32(i)) })
        try g.addBackEdge(src: UInt32((freeNode + 1) % n), dst: UInt32(freeNode))
        _ = try DagDBBackup.appendDiff(engine: g, nodeCount: n, gridW: side, gridH: side, dir: chain)

        // A v2 WAL: a session of v1 and v2 opcodes from a fresh engine.
        let wal = dir + "/v2.wal"
        let o = try makeOldGraph()
        do {
            let a = try DagDBWAL.Appender(path: wal, nodeCount: n)
            let ranks = o.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
            _ = try a.setRanksBulk(UnsafePointer(ranks), count: n)
            var luts = (0..<n).map { i -> UInt64 in
                UInt64(o.lut6HighBuf.contents().load(fromByteOffset: i * 4, as: UInt32.self)) << 32
                    | UInt64(o.lut6LowBuf.contents().load(fromByteOffset: i * 4, as: UInt32.self))
            }
            _ = try a.setLutsBulk(&luts, count: n)
            let nbs = o.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
            _ = try a.setNeighborsBulk(UnsafePointer(nbs), count: n)
            for i in 0..<n {
                _ = try a.setTruth(node: UInt32(i), value: o.truthStateBuf.contents().load(fromByteOffset: i, as: UInt8.self))
            }
            for i in 0..<o.backEdgeCount { _ = try a.connectBack(src: o.backEdgeSrcs[i], dst: o.backEdgeDsts[i]) }
            _ = try a.setRank(node: 2, value: wideRank(7))
            _ = try a.setLUT(node: 3, lut: 0x0123_4567_89AB_CDEF)
            _ = try a.setEdgeWeight(node: 4, dir: 2, value: -0.0)
            _ = try a.setActivation(node: 5, value: -1234)
            _ = try a.setNodeValue(node: 6, value: 2.75)
            _ = try a.clearEdges(node: 8)
            _ = try a.connect(dst: 8, slot: 3, src: 2)
            _ = try a.setTruth(node: 9, value: 250)
            if let d = o.backEdgeDsts.first { _ = try a.clearBackEdges(dst: d) }
        }
    }

    /// The loads main recorded: (kind, path under the fixture dir).
    static let loads: [(kind: String, name: String)] =
        handBuilt.map { ("dags", $0.name) } + [
            ("dags", "v7.dags"), ("dags", "v7z.dags"),
            ("wal", "v2.wal"), ("backup", "chain"),
            ("json", "v1.json"), ("csv", "csv_v1"), ("morton", "morton"),
        ]

    /// Perform one load into `e` with the running build's loader; returns the
    /// ten-lane hash and the loader's own counts.
    static func perform(kind: String, path: String, into e: DagDBEngine) throws -> [String: String] {
        let n = e.nodeCount
        var out: [String: String] = [:]
        switch kind {
        case "dags":
            let r = try DagDBSnapshot.load(engine: e, nodeCount: n, gridW: side, gridH: side, path: path)
            out["bytesRead"] = "\(r.bytesRead)"; out["fileTicks"] = "\(r.fileTicks)"
        case "wal":
            let r = try DagDBWAL.replay(engine: e, nodeCount: n, path: path)
            out["recordsApplied"] = "\(r.recordsApplied)"; out["recordsSkipped"] = "\(r.recordsSkipped)"
            out["fileVersion"] = "\(r.fileVersion)"
        case "backup":
            let r = try DagDBBackup.restore(engine: e, nodeCount: n, gridW: side, gridH: side, dir: path)
            out["diffsReplayed"] = "\(r.diffsReplayed)"
        case "json":
            _ = try DagDBJSONIO.loadJSON(engine: e, nodeCount: n, gridW: side, gridH: side, path: path)
        case "csv":
            let r = try DagDBJSONIO.loadCSV(engine: e, nodeCount: n, dir: path)
            out["nodesParsed"] = "\(r.nodesParsed)"; out["edgesParsed"] = "\(r.edgesParsed)"
        case "morton":
            let r = try DagDBSnapshot.importMorton(engine: e, nodeCount: n, dir: path)
            out["bytesRead"] = "\(r.bytesRead)"
        default:
            XCTFail("unknown kind \(kind)")
        }
        out["hash"] = tenLaneHash(e)
        return out
    }

    // MARK: - Fixture paths

    static var fixtureDir: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ternary_r4_old_files").path
    }

    static func allFiles(_ dir: String) throws -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return [] }
        var out: [String] = []
        while let p = en.nextObject() as? String {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir + "/" + p, isDirectory: &isDir), !isDir.boolValue,
               p != "hashes.json", p != "hashes.json.sha256" { out.append(p) }
        }
        return out.sorted()
    }

    /// The fixture, verified (sidecar, then every file's pin) and copied into
    /// `scratch` so no loader touches the source tree. Returns main's record.
    static func stageFixture(into scratch: String) throws -> [[String: String]] {
        let dir = fixtureDir
        let data = try Data(contentsOf: URL(fileURLWithPath: dir + "/hashes.json"))
        let sidecar = try String(contentsOfFile: dir + "/hashes.json.sha256", encoding: .utf8)
        guard sha256Hex(data) == sidecar.split(separator: " ").first.map(String.init) else {
            throw NSError(domain: "R4", code: 1, userInfo: [NSLocalizedDescriptionKey: "hashes.json does not match its sidecar"])
        }
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let files = try XCTUnwrap(obj["files"] as? [String: String])
        let present = try allFiles(dir)
        guard Set(present) == Set(files.keys) else {
            throw NSError(domain: "R4", code: 2, userInfo: [NSLocalizedDescriptionKey: "fixture files \(present) != pinned \(files.keys.sorted())"])
        }
        let fm = FileManager.default
        try? fm.removeItem(atPath: scratch)
        for (p, pin) in files {
            let d = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + p))
            guard sha256Hex(d) == pin else {
                throw NSError(domain: "R4", code: 3, userInfo: [NSLocalizedDescriptionKey: "fixture file \(p) does not match its pin"])
            }
            let dst = scratch + "/" + p
            try fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try d.write(to: URL(fileURLWithPath: dst))
        }
        return try XCTUnwrap(obj["loads"] as? [[String: String]])
    }

    // MARK: - The gate

    func testOldFilesLoadExactlyAsTheMainBuildLoadedThem() throws {
        let scratch = NSTemporaryDirectory() + "tern-r4-old-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        if ProcessInfo.processInfo.environment["DAGDB_TERNARY_R4_RECORD"] == "1" {
            let dir = Self.fixtureDir
            try Self.writeOldFiles(dir: dir)
            var files: [String: String] = [:]
            for p in try Self.allFiles(dir) {
                files[p] = Self.sha256Hex(try Data(contentsOf: URL(fileURLWithPath: dir + "/" + p)))
            }
            // Main loads its own files from a copy, as check mode does.
            for p in files.keys {
                let dst = scratch + "/" + p
                try FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                try FileManager.default.copyItem(atPath: dir + "/" + p, toPath: dst)
            }
            var loads: [[String: String]] = []
            for l in Self.loads {
                var r = try Self.perform(kind: l.kind, path: scratch + "/" + l.name, into: try Self.freshEngine())
                r["kind"] = l.kind; r["name"] = l.name
                loads.append(r)
                print("R4 old-files RECORD \(l.name) \(r)")
            }
            let payload: [String: Any] = [
                "contract": "docs/contracts/TERNARY_GATES_FROZEN.md R4 (old files load identically)",
                "recorded_by": "main build (git archive main dagdb + this test file), ticket T5",
                "generator": "TernaryR4OldFilesTests.makeOldGraph / writeOldFiles (Rng seed 0x7e120004, side 8; ranks r in 0..<8 stored as r·2^33+5, v2 files r·1000+300, v1 files r)",
                "side": Self.side,
                "files": files,
                "loads": loads,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: URL(fileURLWithPath: dir + "/hashes.json"))
            try Data("\(Self.sha256Hex(data))  hashes.json\n".utf8)
                .write(to: URL(fileURLWithPath: dir + "/hashes.json.sha256"))
            print("R4 old-files RECORDED \(dir)")
            return
        }

        let want = try Self.stageFixture(into: scratch)
        XCTAssertEqual(want.count, Self.loads.count)
        XCTAssertEqual(want.map { $0["name"] ?? "" }, Self.loads.map { $0.name })
        var distinct = Set<String>()
        for w in want {
            let name = try XCTUnwrap(w["name"]), kind = try XCTUnwrap(w["kind"])
            var got = try Self.perform(kind: kind, path: scratch + "/" + name, into: try Self.freshEngine())
            got["kind"] = kind; got["name"] = name
            XCTAssertEqual(got, w, "R4 old file \(name): this build's load differs from main's")
            distinct.insert(got["hash"] ?? "")
            print("R4 old-files \(name) \(got == w ? "EQUAL" : "DIFFERS") \(got)")
        }
        // The object can fail the gate: the loads do not all land on one
        // state (rank widths, absent sections and the chain's diffs differ).
        XCTAssertGreaterThan(distinct.count, 3, "old-file loads collapse onto \(distinct.count) states")
    }
}
