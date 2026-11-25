import XCTest
import Metal
@testable import DagDB
@testable import DagDBDaemonKit

/// The mutating-verb control list, carried forward with the ternary verbs.
///
/// The original control (CoreDurabilityC1Tests) is untouched.
/// This file is its continuation: a graph is built through EVERY mutating
/// form the parser accepts — the old sixteen plus every ternary form — with
/// the WAL on; the daemon is discarded without SAVE; the log alone is
/// replayed into a fresh engine; every lane is compared against values THIS
/// test wrote down, never against a live engine.
final class TernaryC1ControlTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-tc1-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    private struct Expected {
        var truth: [UInt8], rank: [UInt64], lut: [UInt64], neighbors: [Int32]
        var edgeWeights: [Float], nodeValue: [Float], isRegister: [UInt8]
        var backEdgeSrcs: [UInt32] = [], backEdgeDsts: [UInt32] = []
        var mode: [UInt8], ttableId: [UInt16], thrLo: [Float], thrHi: [Float]
        var tables: [UInt8] = []
        init(n: Int) {
            truth = [UInt8](repeating: 0, count: n); rank = [UInt64](repeating: 0, count: n)
            lut = [UInt64](repeating: 0, count: n); neighbors = [Int32](repeating: -1, count: n * 6)
            edgeWeights = [Float](repeating: 1, count: n * 6); nodeValue = [Float](repeating: 0, count: n)
            isRegister = [UInt8](repeating: 0, count: n)
            mode = [UInt8](repeating: 0, count: n); ttableId = [UInt16](repeating: 0, count: n)
            thrLo = [Float](repeating: 0, count: n); thrHi = [Float](repeating: 0, count: n)
        }
    }

    private func read<T>(_ b: MTLBuffer, _ t: T.Type, _ count: Int) -> [T] {
        Array(UnsafeBufferPointer(start: b.contents().bindMemory(to: T.self, capacity: count), count: count))
    }

    private func check<T: Equatable>(_ name: String, _ a: [T], _ e: [T]) -> String? {
        if a.count != e.count { return "\(name): count \(a.count) vs \(e.count)" }
        var bad = 0, first = -1
        for i in 0..<a.count where a[i] != e[i] { bad += 1; if first < 0 { first = i } }
        return bad == 0 ? nil : "\(name): \(bad) slot(s) differ, first at \(first) (\(a[first]) vs \(e[first]))"
    }

    /// A table written down here: byte i = (i · a + b) mod 3.
    private func table(_ a: Int, _ b: Int) -> [UInt8] { (0..<729).map { UInt8(($0 * a + b) % 3) } }
    private func text(_ t: [UInt8]) -> String { String(t.map { TernaryReference.char(ofTableByte: $0) }) }
    private func trit(_ b: UInt8) -> Int { b == 0 ? -1 : (b == 1 ? 1 : 0) }
    private func byte(_ t: Int) -> UInt8 { t < 0 ? 0 : (t > 0 ? 1 : 2) }

    func testEveryMutatingFormIncludingTernarySurvivesReplayFromTheLogAlone() throws {
        let side = 8, n = side * side
        let walPath = tmpDir! + "tc1.log"
        var exp = Expected(n: n)
        var forms = Set<String>()
        var issued = 0

        do {
            let appender = try DagDBWAL.Appender(path: walPath, nodeCount: n)
            let f = try HandlerFixture(side: side, wal: appender, maxRank: 8)
            func issue(_ form: String, _ line: String) {
                let r = f.handler.handle(line)
                XCTAssertTrue(r.hasPrefix("OK"), "\(line) -> \(r)")
                issued += 1; forms.insert(form)
            }
            let shm8 = f.shm.advanced(by: 8)

            // ── the old sixteen ──
            let nb = shm8.bindMemory(to: Int32.self, capacity: n * 6)
            for i in 0..<(n * 6) { nb[i] = -1 }
            shm1Header(f.shm, count: n, verb: .setNeighborsBulk)
            issue("SET_NEIGHBORS_BULK", "SET_NEIGHBORS_BULK")
            let rk = shm8.bindMemory(to: UInt64.self, capacity: n)
            for i in 0..<n { rk[i] = UInt64(i % 8) }
            shm1Header(f.shm, count: n, verb: .setRanksBulk)
            issue("SET_RANKS_BULK", "SET_RANKS_BULK")
            for i in 0..<n { exp.rank[i] = UInt64(i % 8) }
            let lt = shm8.bindMemory(to: UInt64.self, capacity: n)
            for i in 0..<n { lt[i] = 0x0F0F_0F0F_0F0F_0F0F &+ UInt64(i) &* 0x0001_0001_0001_0001 }
            shm1Header(f.shm, count: n, verb: .setLutsBulk)
            issue("SET_LUTS_BULK", "SET_LUTS_BULK")
            for i in 0..<n { exp.lut[i] = 0x0F0F_0F0F_0F0F_0F0F &+ UInt64(i) &* 0x0001_0001_0001_0001 }
            issue("SET RANK", "SET 3 RANK 5"); exp.rank[3] = 5
            issue("SET TRUTH", "SET 3 TRUTH 1"); exp.truth[3] = 1
            issue("SET LUT", "SET 4 LUT OR"); exp.lut[4] = LUT6Preset.or6
            issue("SET WEIGHT", "SET 5 WEIGHT 2 0.25"); exp.edgeWeights[5 * 6 + 2] = 0.25
            issue("SET VALUE", "SET 6 VALUE 1.5"); exp.nodeValue[6] = 1.5
            issue("CONNECT", "CONNECT FROM 15 TO 8"); exp.neighbors[8 * 6] = 15
            issue("CONNECT", "CONNECT FROM 23 TO 8"); exp.neighbors[8 * 6 + 1] = 23
            issue("CLEAR EDGES", "CLEAR 8 EDGES"); for d in 0..<6 { exp.neighbors[8 * 6 + d] = -1 }
            issue("CONNECT", "CONNECT FROM 39 TO 9"); exp.neighbors[9 * 6] = 39
            issue("CONNECT BACK", "CONNECT BACK FROM 11 TO 12")
            exp.backEdgeSrcs.append(11); exp.backEdgeDsts.append(12); exp.isRegister[12] = 1
            issue("CONNECT BACK", "CONNECT BACK FROM 13 TO 14")
            issue("CLEAR BACK_EDGES", "CLEAR 14 BACK_EDGES")
            issue("COMPOSE NOT", "COMPOSE NOT 20 INTO 21"); exp.lut[21] = ~exp.lut[20]
            issue("COMPOSE AND", "COMPOSE AND 20 22 INTO 23"); exp.lut[23] = exp.lut[20] & exp.lut[22]
            issue("COMPOSE OR", "COMPOSE OR 24 25 INTO 26"); exp.lut[26] = exp.lut[24] | exp.lut[25]
            issue("COMPOSE XOR", "COMPOSE XOR 27 28 INTO 29"); exp.lut[29] = exp.lut[27] ^ exp.lut[28]

            // ── the ternary forms ──
            let t0 = table(1, 0), t1 = table(5, 2)
            issue("TTABLE DEFINE", "TTABLE DEFINE 0 \(text(t0))"); exp.tables += t0
            issue("TTABLE DEFINE", "TTABLE DEFINE 1 \(text(t1))"); exp.tables += t1
            // TSUM over k = 2 (written down here): sign of t0 + t1.
            let tsum2: [UInt8] = (0..<729).map { i in
                let a = i % 3 - 1, b = (i / 3) % 3 - 1
                return self.byte(a + b > 0 ? 1 : (a + b < 0 ? -1 : 0))
            }
            issue("TTABLE PRESET", "TTABLE PRESET 2 TSUM 2"); exp.tables += tsum2
            let bulk = table(7, 1) + table(2, 2)
            shm8.copyMemory(from: bulk, byteCount: bulk.count)
            shm1Header(f.shm, count: 2, verb: .ttableBulk)
            issue("TTABLE_BULK", "TTABLE_BULK 3 2"); exp.tables += bulk

            issue("SET TTABLE", "SET 40 TTABLE 1"); exp.ttableId[40] = 1
            issue("SET MODE", "SET 40 MODE TTABLE NOSKIP"); exp.mode[40] = 1 | 4
            issue("SET TTABLE", "SET 41 TTABLE 2"); exp.ttableId[41] = 2
            issue("SET MODE", "SET 41 MODE TTABLE"); exp.mode[41] = 1
            issue("SET TTABLE", "SET 42 TTABLE 3"); exp.ttableId[42] = 3
            issue("SET MODE", "SET 42 MODE TTABLE"); exp.mode[42] = 1
            issue("SET THRESH", "SET 43 THRESH -0.75 2.5"); exp.thrLo[43] = -0.75; exp.thrHi[43] = 2.5
            issue("SET MODE", "SET 43 MODE TTHRESH"); exp.mode[43] = 2
            issue("SET TRIT", "SET 43 TRIT -1"); exp.truth[43] = 0
            issue("SET TRIT", "SET 44 TRIT 0"); exp.truth[44] = 2

            // COMPOSE on tables: each appends one table and points dst at it.
            func pointwise(_ f: (Int, Int) -> Int, _ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
                (0..<729).map { self.byte(f(self.trit(a[$0]), self.trit(b[$0]))) }
            }
            issue("COMPOSE AND (tables)", "COMPOSE AND 40 41 INTO 42")
            exp.tables += pointwise(min, t1, tsum2); exp.ttableId[42] = 5
            issue("COMPOSE OR (tables)", "COMPOSE OR 40 41 INTO 42")
            exp.tables += pointwise(max, t1, tsum2); exp.ttableId[42] = 6
            issue("COMPOSE NOT (tables)", "COMPOSE NOT 40 INTO 42")
            exp.tables += t1.map { self.byte(-self.trit($0)) }; exp.ttableId[42] = 7

            // Bulk lanes.
            let ids = shm8.bindMemory(to: UInt16.self, capacity: n)
            for i in 0..<n { ids[i] = UInt16((i * 3) % 8) }
            shm1Header(f.shm, count: n, verb: .setTTableIdsBulk)
            issue("SET_TTABLE_IDS_BULK", "SET_TTABLE_IDS_BULK")
            for i in 0..<n { exp.ttableId[i] = UInt16((i * 3) % 8) }
            let thr = shm8.bindMemory(to: Float.self, capacity: 2 * n)
            for i in 0..<n { thr[2 * i] = -Float(i % 5) * 0.5; thr[2 * i + 1] = Float(i % 3) * 0.25 }
            shm1Header(f.shm, count: n, verb: .setThreshBulk)
            issue("SET_THRESH_BULK", "SET_THRESH_BULK")
            for i in 0..<n { exp.thrLo[i] = -Float(i % 5) * 0.5; exp.thrHi[i] = Float(i % 3) * 0.25 }
            // Modes: nodes ≥ 45 alternate TTABLE / TTHRESH with NOSKIP on
            // every third; the earlier nodes keep what the singles set.
            let md = shm8.bindMemory(to: UInt8.self, capacity: n)
            for i in 0..<n { md[i] = exp.mode[i] }
            for i in 45..<n { md[i] = UInt8(1 + i % 2) | (i % 3 == 0 ? 4 : 0) }
            shm1Header(f.shm, count: n, verb: .setModesBulk)
            issue("SET_MODES_BULK", "SET_MODES_BULK")
            for i in 0..<n { exp.mode[i] = md[i] }

            appender.barrier()
            let parserMutatingForms: Set<String> = [
                "SET TRUTH", "SET RANK", "SET LUT", "SET WEIGHT", "SET VALUE",
                "CLEAR EDGES", "CLEAR BACK_EDGES", "CONNECT", "CONNECT BACK",
                "SET_RANKS_BULK", "SET_LUTS_BULK", "SET_NEIGHBORS_BULK",
                "COMPOSE NOT", "COMPOSE AND", "COMPOSE OR", "COMPOSE XOR",
                // ternary
                "SET MODE", "SET TTABLE", "SET THRESH", "SET TRIT",
                "TTABLE DEFINE", "TTABLE PRESET",
                "COMPOSE AND (tables)", "COMPOSE OR (tables)", "COMPOSE NOT (tables)",
                "SET_MODES_BULK", "SET_TTABLE_IDS_BULK", "SET_THRESH_BULK", "TTABLE_BULK",
            ]
            XCTAssertEqual(forms, parserMutatingForms,
                           "missed: \(parserMutatingForms.subtracting(forms)); unexpected: \(forms.subtracting(parserMutatingForms))")
            print("TERNARY C1 commands_issued=\(issued) mutating_forms_covered=\(forms.count)/\(parserMutatingForms.count)")
        }

        let grid = try HexGrid(width: side, height: side)
        let fresh = try DagDBEngine(grid: grid, state: DagDBState(width: side, height: side), maxRank: 8)
        let r = try DagDBWAL.replay(engine: fresh, nodeCount: n, path: walPath)
        let low = read(fresh.lut6LowBuf, UInt32.self, n), high = read(fresh.lut6HighBuf, UInt32.self, n)
        let lut = (0..<n).map { UInt64(high[$0]) << 32 | UInt64(low[$0]) }
        let diffs = [
            check("truth", read(fresh.truthStateBuf, UInt8.self, n), exp.truth),
            check("rank", read(fresh.rankBuf, UInt64.self, n), exp.rank),
            check("lut", lut, exp.lut),
            check("neighbors", read(fresh.neighborsBuf, Int32.self, n * 6), exp.neighbors),
            check("edgeWeights", read(fresh.edgeWeightsBuf, Float.self, n * 6), exp.edgeWeights),
            check("nodeValue", read(fresh.nodeValueBuf, Float.self, n), exp.nodeValue),
            check("isRegister", read(fresh.isRegisterBuf, UInt8.self, n), exp.isRegister),
            check("backEdgeSrcs", fresh.backEdgeSrcs, exp.backEdgeSrcs),
            check("backEdgeDsts", fresh.backEdgeDsts, exp.backEdgeDsts),
            check("mode", read(fresh.nodeModeBuf, UInt8.self, n), exp.mode),
            check("ttableId", read(fresh.ttableIdBuf, UInt16.self, n), exp.ttableId),
            check("thrLo", read(fresh.thrLoBuf, Float.self, n).map { $0.bitPattern }, exp.thrLo.map { $0.bitPattern }),
            check("thrHi", read(fresh.thrHiBuf, Float.self, n).map { $0.bitPattern }, exp.thrHi.map { $0.bitPattern }),
            check("library", fresh.libraryBytes(), exp.tables),
        ].compactMap { $0 }
        XCTAssertTrue(diffs.isEmpty, "replay from the WAL alone:\n" + diffs.joined(separator: "\n"))
        XCTAssertEqual(r.recordsSkipped, 0)
        XCTAssertEqual(r.refusals, [])
    }
}
