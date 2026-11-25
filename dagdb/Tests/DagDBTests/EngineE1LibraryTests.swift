import XCTest
import CryptoKit
@testable import DagDB

/// Three checks at the library level: the IMPORT MORTON WAL record, the
/// direct writers' non-finite refusal, and ternary lanes on demand.
///
/// The IMPORT MORTON record in the WAL itself: written by the
/// appender, replayed into a fresh engine; split across records when it is
/// larger than one record may carry (the chunk size shrunk here so a small
/// graph exercises the split); a torn import (parts without their final
/// record) is not applied and is named.
/// The engine's direct writers refuse a non-finite value or weight
/// by name and write nothing: {NaN, +inf, -inf, a finite control} x
/// {value, weight} x {set, bulk} = 16 cells.
/// Ternary lanes on demand, by the engine's own allocation
/// accounting, at 10M nodes.
final class EngineE1LibraryTests: XCTestCase {

    private var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "engine-e1-lib-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        DagDBWAL.importChunkBytes = DagDBWAL.defaultImportChunkBytes
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    private func fresh(_ side: Int) throws -> DagDBEngine {
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side), maxRank: 8)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        return e
    }

    /// Every persisted lane, the back-edge list and the library, as one hash.
    private func stateHash(_ e: DagDBEngine) -> String {
        let n = e.nodeCount
        var h = SHA256()
        func lane(_ p: UnsafeRawPointer, _ c: Int) { h.update(bufferPointer: UnsafeRawBufferPointer(start: p, count: c)) }
        lane(e.rankBuf.contents(), n * 8); lane(e.truthStateBuf.contents(), n)
        lane(e.nodeTypeBuf.contents(), n); lane(e.lut6LowBuf.contents(), n * 4)
        lane(e.lut6HighBuf.contents(), n * 4); lane(e.neighborsBuf.contents(), n * 24)
        lane(e.edgeWeightsBuf.contents(), n * 24); lane(e.activationBuf.contents(), n * 2)
        lane(e.nodeValueBuf.contents(), n * 4); lane(e.isRegisterBuf.contents(), n)
        var mode = [UInt8](repeating: 0, count: n), tid = [UInt16](repeating: 0, count: n)
        var lo = [UInt32](repeating: 0, count: n), hi = lo
        for i in 0..<n { mode[i] = e.modeByte(i) }
        if e.ternaryLanesAllocated {
            for i in 0..<n {
                tid[i] = e.ttableIdPtr[i]; lo[i] = e.thrLoPtr[i].bitPattern; hi[i] = e.thrHiPtr[i].bitPattern
            }
        }
        mode.withUnsafeBytes { h.update(bufferPointer: $0) }; tid.withUnsafeBytes { h.update(bufferPointer: $0) }
        lo.withUnsafeBytes { h.update(bufferPointer: $0) }; hi.withUnsafeBytes { h.update(bufferPointer: $0) }
        for i in 0..<e.backEdgeCount {
            var s = e.backEdgeSrcs[i], d = e.backEdgeDsts[i]
            withUnsafeBytes(of: &s) { h.update(bufferPointer: $0) }; withUnsafeBytes(of: &d) { h.update(bufferPointer: $0) }
        }
        e.libraryBytes().withUnsafeBytes { h.update(bufferPointer: $0) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A ternary source graph through raw writes, exported.
    private func exportedSource(side: Int, into dir: String) throws -> DagDBEngine {
        let src = try fresh(side)
        let n = src.nodeCount
        let rank = src.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let nb = src.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        let truth = src.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let val = src.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)
        for i in 0..<n {
            rank[i] = UInt64(n - 1 - i) / 16
            if i >= 21 { nb[i * 6] = Int32(i - 16 - (i % 5)) }   // a strictly higher rank
            truth[i] = UInt8(i % 2); val[i] = Float(i) / 7
        }
        try src.writeTables(first: 0, bytes: [UInt8](repeating: 1, count: TernaryReference.tableSize))
        for i in stride(from: 1, to: n, by: 9) where nb[i * 6] >= 0 {
            src.setNodeMode(i, 1); src.ttableIdPtr[i] = 0; truth[i] = 2
        }
        try src.addBackEdge(src: UInt32(n - 1), dst: 0)
        XCTAssertNil(src.ternaryStateViolation())
        _ = try DagDBSnapshot.exportMorton(engine: src, nodeCount: n, dir: dir)
        return src
    }

    // MARK: - The IMPORT MORTON record itself

    func testItem1ImportRecordReplaysWholeAndSplit() throws {
        let side = 16, n = side * side
        var lines: [String] = []
        // The whole import in one record (default chunk), then split three ways.
        for chunk in [DagDBWAL.defaultImportChunkBytes, 4096, 1000, 77] {
            DagDBWAL.importChunkBytes = chunk
            let dir = tmp + "src-\(chunk)"
            let src = try exportedSource(side: side, into: dir)
            let live = try fresh(side)
            let path = tmp + "imp-\(chunk).wal"
            var records = 0
            do {
                let w = try DagDBWAL.Appender(path: path, nodeCount: n)
                _ = try DagDBSnapshot.importMorton(engine: live, nodeCount: n, dir: dir, beforeCommit: { files in
                    records = try w.importMorton(dir: dir, files: files)
                })
            }
            try FileManager.default.removeItem(atPath: dir)
            let b = try fresh(side)
            let r = try DagDBWAL.replay(engine: b, nodeCount: n, path: path)
            XCTAssertEqual(r.refusals, [], "chunk \(chunk)")
            XCTAssertEqual(r.recordsSkipped, 0, "chunk \(chunk)")
            XCTAssertEqual(r.recordsApplied, records, "chunk \(chunk)")
            XCTAssertEqual(stateHash(b), stateHash(live), "chunk \(chunk)")
            XCTAssertEqual(stateHash(b), stateHash(src), "chunk \(chunk)")
            if chunk == DagDBWAL.defaultImportChunkBytes { XCTAssertEqual(records, 1, "one import, one record") }
            else { XCTAssertGreaterThan(records, 1, "chunk \(chunk) splits") }
            lines.append("chunk=\(chunk) records=\(records) equal=\(stateHash(b) == stateHash(live))")
        }
        print("E1.1 WAL record: " + lines.joined(separator: "; "))
    }

    func testItem1TornImportIsNotAppliedAndIsNamed() throws {
        let side = 16, n = side * side
        DagDBWAL.importChunkBytes = 1000
        let dir = tmp + "src"
        _ = try exportedSource(side: side, into: dir)
        let path = tmp + "torn.wal"
        do {
            let w = try DagDBWAL.Appender(path: path, nodeCount: n)
            _ = try w.setTruth(node: 3, value: 1)
            _ = try DagDBSnapshot.importMorton(engine: try fresh(side), nodeCount: n, dir: dir, beforeCommit: { files in
                _ = try w.importMorton(dir: dir, files: files)
            })
        }
        // Cut the log inside the import's final record: its parts are whole, the final record is torn.
        var data = try Data(contentsOf: URL(fileURLWithPath: path))
        data = data.prefix(data.count - 10)
        try data.write(to: URL(fileURLWithPath: path))
        let b = try fresh(side)
        let before = stateHash(try fresh(side))
        let r = try DagDBWAL.replay(engine: b, nodeCount: n, path: path)
        XCTAssertNotNil(r.truncatedAtOffset)
        XCTAssertEqual(r.refusals.count, 1, "\(r.refusals)")
        XCTAssertTrue(r.refusals.first?.contains("torn import") ?? false, "\(r.refusals)")
        // Only the SET TRUTH before the import is applied.
        let truth = b.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        XCTAssertEqual(truth[3], 1)
        truth[3] = 0
        XCTAssertEqual(stateHash(b), before, "a torn import changes nothing")
        print("E1.1 torn import: \(r.refusals)")
    }

    // MARK: - The engine's direct writers refuse non-finite values

    func testItem4DirectWritersRefuseNonFinite16Cells() throws {
        let side = 8
        let e = try fresh(side)
        let n = e.nodeCount
        let values: [(String, Float)] = [("NaN", .nan), ("+inf", .infinity), ("-inf", -.infinity), ("finite", 1.25)]
        func lanes() -> (w: [UInt32], v: [UInt32]) {
            let w = e.edgeWeightsBuf.contents().bindMemory(to: UInt32.self, capacity: n * 6)
            let v = e.nodeValueBuf.contents().bindMemory(to: UInt32.self, capacity: n)
            return (Array(UnsafeBufferPointer(start: w, count: n * 6)), Array(UnsafeBufferPointer(start: v, count: n)))
        }
        var cells = 0, ok = 0
        for (label, x) in values {
            for lane in ["value", "weight"] {
                for how in ["set", "bulk"] {
                    cells += 1
                    let before = lanes()
                    var err: Error?
                    do {
                        switch (lane, how) {
                        case ("value", "set"): try e.setNodeValue(5, x)
                        case ("weight", "set"): try e.setEdgeWeight(5, dir: 2, x)
                        case ("value", "bulk"):
                            var v = before.v.map { Float(bitPattern: $0) }; v[5] = x; v[6] = 0.5
                            try e.setNodeValues(v)
                        default:
                            var w = before.w.map { Float(bitPattern: $0) }; w[5 * 6 + 2] = x; w[0] = 0.5
                            try e.setEdgeWeights(w)
                        }
                    } catch { err = error }
                    let after = lanes()
                    let cell = "\(label) \(lane) \(how)"
                    if x.isFinite {
                        XCTAssertNil(err, cell)
                        let got = lane == "value" ? Float(bitPattern: after.v[5]) : Float(bitPattern: after.w[5 * 6 + 2])
                        XCTAssertEqual(got, x, cell)
                        if err == nil && got == x { ok += 1 }
                    } else {
                        let s = err.map { "\($0)" } ?? "accepted"
                        let named = lane == "value"
                            ? s.contains("node value node=5 is \(x)") && s.contains("a value must be finite")
                            : s.contains("edge weight node=5 slot=2 is \(x)") && s.contains("a weight must be finite")
                        XCTAssertTrue(named, "\(cell): \(s)")
                        XCTAssertEqual(after.w, before.w, "\(cell): the weight lane moved")
                        XCTAssertEqual(after.v, before.v, "\(cell): the value lane moved")
                        if named && after.w == before.w && after.v == before.v { ok += 1 }
                    }
                    print("E1.4 \(cell) -> \(err.map { "\($0)" } ?? "OK")")
                }
            }
        }
        print("E1.4 direct writers: \(ok)/\(cells) cells as the letter says")
        XCTAssertEqual(cells, 16)
    }

    func testItem4BulkWritersRefuseAShortLane() throws {
        let e = try fresh(8)
        XCTAssertThrowsError(try e.setNodeValues([1, 2, 3]))
        XCTAssertThrowsError(try e.setEdgeWeights([1, 2, 3]))
    }

    // MARK: - Ternary lanes on demand

    /// At 10M nodes (3163 x 3163 = 10,004,569): the engine's own accounting
    /// says 0 ternary-lane bytes on a binary graph, and 11 bytes per node —
    /// the four lanes' size on main (mode 1 + ttableId 2 + thrLo 4 + thrHi 4)
    /// — once the first ternary node exists. TTABLE and TTHRESH both.
    func testItem5TernaryLanesOnDemandAt10M() throws {
        for kind in [UInt8(1), UInt8(2)] {
            let side = 3163, n = side * side
            let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                    state: DagDBState(width: side, height: side), maxRank: 8)
            XCTAssertEqual(e.ternaryLaneBytes, 0, "a fresh binary engine")
            XCTAssertFalse(e.allocationBytes().contains { $0.name.hasPrefix("ternary.") && $0.bytes != 0 })
            // Binary work touches no lane: a tick both ways, the state check, the content check.
            e.tick(tickNumber: 0); e.tickSync(tickNumber: 1)
            XCTAssertNil(e.ternaryStateViolation()); XCTAssertFalse(e.hasTernaryContent())
            XCTAssertEqual(e.ternaryNodeCount(), 0); XCTAssertEqual(e.modeByte(n - 1), 0)
            XCTAssertEqual(e.ternaryLaneBytes, 0, "binary work allocates no lane")
            let total0 = e.allocationBytes().reduce(0) { $0 + $1.bytes }
            // The first ternary node.
            if kind == 1 { try e.writeTables(first: 0, bytes: [UInt8](repeating: 2, count: TernaryReference.tableSize)) }
            XCTAssertEqual(e.ternaryLaneBytes, 0, "a library alone is not a ternary node")
            e.setNodeMode(17, kind)
            if kind == 2 { e.thrLoPtr[17] = -0.5; e.thrHiPtr[17] = 0.5 }
            XCTAssertEqual(e.ternaryLaneBytes, 11 * n, "kind \(kind)")
            let lanes = Dictionary(uniqueKeysWithValues: e.allocationBytes().map { ($0.name, $0.bytes) })
            XCTAssertEqual(lanes["ternary.mode"], n); XCTAssertEqual(lanes["ternary.ttableId"], 2 * n)
            XCTAssertEqual(lanes["ternary.thrLo"], 4 * n); XCTAssertEqual(lanes["ternary.thrHi"], 4 * n)
            let total1 = e.allocationBytes().reduce(0) { $0 + $1.bytes }
            XCTAssertEqual(total1 - total0, 11 * n)
            XCTAssertEqual(e.ternaryNodeCount(), 1); XCTAssertEqual(e.modeByte(17), kind)
            print("E1.5 n=\(n) kind=\(kind): ternary lane bytes 0 before the first ternary node, \(e.ternaryLaneBytes) after (= 11 x n = \(11 * n)); engine accounting \(total0) -> \(total1) bytes")
        }
    }
}
