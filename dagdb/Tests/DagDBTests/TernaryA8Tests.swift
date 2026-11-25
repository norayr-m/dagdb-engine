import XCTest
import CryptoKit
@testable import DagDB

/// Ternary lane lengths, backup diff segments and declared sizes, each refused
/// by name.
/// The back-edge refusal of a ternary destination is not in this file:
/// `validateBackEdge` and `addBackEdge` refuse a ternary destination by name,
/// tested by `TernaryA9Tests`; TernaryT2LanesTests now builds its ternary
/// register through `registerValidatedBackEdge`.
///
/// The engine checks each ternary lane's length separately and names
/// the lane and its actual length (thrLo one short → "thrLo" and its length).
/// Every backup diff segment is read by name: a diff truncated inside
/// any segment's size field or body names that segment (thrHi and the library
/// among them).
/// A declared library size above 65,536 × 729 = 47,775,744 bytes is
/// refused by name before the segment is read or anything is allocated, and a
/// declared segment size above what the segment can hold is refused by name
/// inside the reader (the back-edge section's declared size included).
///
/// Every check reads the error's text, so this file compiles against the code
/// before the fix (the red run) and after it (the green run).
final class TernaryA8Tests: XCTestCase {

    private var tmp: String!
    private let side = 8
    private var n: Int { side * side }

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "tern-a8-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let d = tmp { try? FileManager.default.removeItem(atPath: d) } }

    private func fresh() throws -> DagDBEngine {
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side), maxRank: 8)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        return e
    }

    // MARK: - Each lane's length, named

    func testItem2EachTernaryLaneLengthIsCheckedAndNamed() throws {
        let grid = try HexGrid(width: side, height: side)
        // Control: every lane full length constructs.
        XCTAssertNoThrow(try DagDBEngine(grid: grid, state: DagDBState(width: side, height: side), maxRank: 8))
        var cells = 0, named = 0
        for lane in ["nodeMode", "ttableId", "thrLo", "thrHi"] {
            for len in [n - 1, n + 1, 0] {
                var st = DagDBState(width: side, height: side)
                switch lane {
                case "nodeMode": st.nodeMode = [UInt8](repeating: 0, count: len)
                case "ttableId": st.ttableId = [UInt16](repeating: 0, count: len)
                case "thrLo": st.thrLo = [Float](repeating: 0, count: len)
                default: st.thrHi = [Float](repeating: 0, count: len)
                }
                cells += 1
                do {
                    _ = try DagDBEngine(grid: grid, state: st, maxRank: 8)
                    XCTFail("\(lane) at \(len) elements was accepted")
                } catch {
                    let s = "\(error)"
                    let ok = s.contains("lane \(lane) has \(len) element")
                    if ok { named += 1 }
                    XCTAssertTrue(ok, "\(lane) at \(len): \(s)")
                }
            }
        }
        print("A8 item2: \(named)/\(cells) lane-length refusals name the lane and its length")
    }

    // MARK: - Backup diff segments, by name and bounded

    /// A valid ternary graph: three tables, every kind, NOSKIP, thresholds,
    /// a binary register.
    private func ternaryEngine(tables: [UInt8]? = nil) throws -> DagDBEngine {
        let e = try fresh()
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        var library = tables ?? []
        if tables == nil {
            library = try TernaryReference.presetTable(.tsum, k: 3) + TernaryReference.presetTable(.tmin, k: 2)
                + (0..<729).map { UInt8(($0 * 5) % 3) }
        }
        try e.writeTables(first: 0, bytes: library)
        for i in 0..<n {
            rank[i] = UInt64(i % 4)
            let k = i % 3
            if k == 0 { truth[i] = UInt8((i * 37) % 256) }
            else { e.setNodeMode(i, UInt8(k) | (i % 2 == 0 ? 4 : 0)); truth[i] = UInt8(i % 3) }
            e.ttableIdPtr[i] = UInt16(i % 3)
            e.thrLoPtr[i] = -Float(i % 4) * 0.5
            e.thrHiPtr[i] = Float(i % 6) * 0.25
        }
        e.setNodeMode(3, 0); truth[3] = 2
        try e.addBackEdge(src: 5, dst: 3)
        try e.addBackEdge(src: 7, dst: 3)
        XCTAssertNil(e.ternaryStateViolation())
        return e
    }

    /// The chain: a binary base, then one format-3 diff to the ternary engine.
    private func chain(_ name: String, tables: [UInt8]? = nil) throws -> (dir: String, src: DagDBEngine) {
        let dir = tmp + name
        let base = try fresh()
        _ = try DagDBBackup.initializeChain(engine: base, nodeCount: n, gridW: side, gridH: side, tickCount: 0, dir: dir)
        let src = try ternaryEngine(tables: tables)
        let r = try DagDBBackup.appendDiff(engine: src, nodeCount: n, gridW: side, gridH: side, dir: dir)
        XCTAssertEqual(r.format, DagDBBackup.diffVersionTernary)
        return (dir, src)
    }

    private struct Seg { let name: String; let rawField: Int?; let sizeField: Int; let body: Int; let bodyLen: Int }

    /// Walk a format-3 diff as the writer lays it out (DagDBBackup.appendDiff).
    private func layout(_ d: Data) -> [Seg] {
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }
        var out: [Seg] = []
        var off = DagDBBackup.diffHeaderSize
        for name in Array(DagDBBackup.segmentNames.prefix(10)) + DagDBBackup.ternarySegmentNames {
            let sz = u32(off)
            out.append(Seg(name: name, rawField: nil, sizeField: off, body: off + 4, bodyLen: sz))
            off += 4 + sz
        }
        for name in [DagDBBackup.segmentNames[10], DagDBBackup.librarySegmentName] {
            let raw = off
            let sz = u32(off + 4)
            out.append(Seg(name: name, rawField: raw, sizeField: off + 4, body: off + 8, bodyLen: sz))
            off += 8 + sz
        }
        XCTAssertEqual(off, d.count, "the walk covers the whole diff")
        return out
    }

    /// A copy of the chain whose diff is `bytes`, with a sidecar that matches
    /// them (so the manifest is not what refuses the cell); RESTORE's error
    /// text, or nil when it restored.
    private func restoreCrafted(_ c: (dir: String, src: DagDBEngine), _ bytes: Data, _ cell: String) throws -> String? {
        let dir = tmp + "cell-\(cell)"
        try FileManager.default.copyItem(atPath: c.dir, toPath: dir)
        let p = dir + "/00001.diff"
        try bytes.write(to: URL(fileURLWithPath: p))
        try Data((DagDBSnapshot.sha256Hex(bytes) + "\n").utf8).write(to: URL(fileURLWithPath: p + ".sha256"))
        let target = try fresh()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        do {
            _ = try DagDBBackup.restore(engine: target, nodeCount: n, gridW: side, gridH: side, dir: dir)
            return nil
        } catch { return "\(error)" }
    }

    private func put32(_ d: inout Data, _ off: Int, _ v: UInt32) {
        for k in 0..<4 { d[off + k] = UInt8((v >> (8 * UInt32(k))) & 0xFF) }
    }

    func testItem4TruncatedSegmentsAreReportedByName() throws {
        let c = try chain("trunc")
        let diff = try Data(contentsOf: URL(fileURLWithPath: c.dir + "/00001.diff"))
        let segs = layout(diff)
        XCTAssertEqual(segs.count, 16)
        // Control: the honest diff restores.
        XCTAssertNil(try restoreCrafted(c, diff, "honest"))
        var cells = 0, named = 0
        for s in segs {
            XCTAssertGreaterThanOrEqual(s.bodyLen, 2, s.name)
            for (what, cut) in [("size field", s.sizeField + 2), ("body", s.body + s.bodyLen / 2)] {
                cells += 1
                let err = try restoreCrafted(c, diff.subdata(in: 0..<cut), "\(s.name)-\(what.prefix(4))")
                let ok = err.map { $0.contains("truncated") && $0.contains("segment \(s.name)") } ?? false
                if ok { named += 1 }
                XCTAssertTrue(ok, "\(s.name) cut in its \(what): \(err ?? "restored")")
            }
        }
        // The raw-size fields before the back edges and the library were
        // already refused by their own names; kept as controls.
        for (s, word) in [(segs[14], "back-edge size"), (segs[15], "library size")] {
            let err = try restoreCrafted(c, diff.subdata(in: 0..<(s.rawField! + 2)), "\(s.name)-raw")
            XCTAssertTrue(err?.contains("truncated \(word)") == true, "\(s.name) raw size: \(err ?? "restored")")
        }
        print("A8 item4: \(named)/\(cells) truncated-segment cells name their segment (16 segments × size field, body; thrHi and ttables among them)")
    }

    func testItem7DeclaredSizesAreBoundedBeforeAnythingIsRead() throws {
        let c = try chain("bound")
        let diff = try Data(contentsOf: URL(fileURLWithPath: c.dir + "/00001.diff"))
        let segs = layout(diff)
        let lib = segs[15], be = segs[14]
        let cap = 65_536 * 729
        XCTAssertEqual(cap, 47_775_744)
        var cells = 0, ok = 0
        func cell(_ name: String, _ bytes: Data, _ check: (String) -> Bool) throws {
            cells += 1
            let err = try restoreCrafted(c, bytes, name)
            let good = err.map(check) ?? false
            if good { ok += 1 }
            XCTAssertTrue(good, "\(name): \(err ?? "restored")")
            print("A8 item7 \(name): \(err ?? "restored")")
        }
        // The gate: libRaw = 0xFFFFFFFF, refused by the new bound, by name.
        var d = diff; put32(&d, lib.rawField!, 0xFFFF_FFFF)
        try cell("libRaw=0xFFFFFFFF", d) {
            $0.contains("segment ttables declares 4294967295 bytes") && $0.contains("\(cap)")
                && !$0.contains("expected 4294967295") && !$0.contains("whole number") && !$0.contains("more than 65536")
        }
        // Before readSeg: the same file ends right after the declared size —
        // no size field, no body. The bound refuses it before either is read.
        try cell("libRaw=0xFFFFFFFF, nothing after it", d.subdata(in: 0..<(lib.rawField! + 4))) {
            $0.contains("segment ttables declares 4294967295 bytes") && $0.contains("\(cap)") && !$0.contains("truncated")
        }
        // One above the cap, refused by the cap.
        d = diff; put32(&d, lib.rawField!, UInt32(cap + 1))
        try cell("libRaw=cap+1", d) { $0.contains("segment ttables declares \(cap + 1) bytes") && $0.contains("\(cap)") }
        // At the cap: not the cap's refusal. Its few compressed bytes cannot
        // decode to 47,775,744 bytes, so the reader's own bound refuses it.
        d = diff; put32(&d, lib.rawField!, UInt32(cap))
        try cell("libRaw=cap", d) {
            $0.contains("segment ttables declares \(cap) bytes") && $0.contains("compressed bytes")
                && !$0.contains("65536 tables")
        }
        // The back-edge section's declared size, bounded inside the reader.
        d = diff; put32(&d, be.rawField!, 0xFFFF_FFFF)
        try cell("beRaw=0xFFFFFFFF", d) {
            $0.contains("segment backEdges declares 4294967295 bytes") && $0.contains("compressed bytes")
                && !$0.contains("expected 4294967295")
        }
        print("A8 item7: \(ok)/\(cells) declared-size cells refused by the new bounds, by name")
    }

    /// The most compressible legitimate library — 65,536 tables, every byte
    /// UNDEFINED — restores bit for bit through the bounds: the reader's
    /// bound never refuses what APPEND writes.
    func testItem7TheLargestMostCompressibleLibraryStillRestores() throws {
        let full = [UInt8](repeating: 2, count: 65_536 * 729)
        let c = try chain("fullLib", tables: full)
        let diff = try Data(contentsOf: URL(fileURLWithPath: c.dir + "/00001.diff"))
        let lib = layout(diff)[15]
        print("A8 item7 full library: \(full.count) bytes compressed to \(lib.bodyLen) (ratio \(full.count / max(lib.bodyLen, 1)):1; deflate's limit is 1032:1)")
        XCTAssertLessThanOrEqual(full.count, lib.bodyLen * 1032)
        let target = try fresh()
        _ = try DagDBBackup.restore(engine: target, nodeCount: n, gridW: side, gridH: side, dir: c.dir)
        XCTAssertEqual(target.ttableCount, 65_536)
        XCTAssertEqual(target.libraryBytes(), c.src.libraryBytes())
        XCTAssertEqual(Data(bytes: target.modeLane, count: n), Data(bytes: c.src.modeLane, count: n))
        XCTAssertEqual(target.backEdgeSrcs, c.src.backEdgeSrcs)
        XCTAssertEqual(target.backEdgeDsts, c.src.backEdgeDsts)
    }
}
