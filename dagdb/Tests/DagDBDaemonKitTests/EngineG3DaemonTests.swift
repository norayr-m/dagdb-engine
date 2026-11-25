import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// `SET_TRUTH NODES|RANK <lo>-<hi> FILL <v>` — the zero tick folded.
///
/// The verb: the truth byte of every node in the selection := v (registers
/// included; a state write outside any session, as SET TRUTH is); v ≥ 3 refused
/// by name when the graph has a ternary node ("use SET_TRUTH_BULK"); the
/// (truth, rank) index dirtied; the DAG verdict, the frontier index and the
/// latch plan kept; one WAL record of ≤ 32 bytes; reader sessions refuse it.
///
/// Equivalence ("equal after the first tick"). Two handlers from
/// one build, after the same closing3: A runs the zero phase (its three LUT
/// lines and `TICK 1`), B the FILL; then both run the flood's three lines,
/// `TICK UNTIL_STABLE`, the extract phase and `TICK 1`, `TRUTH_SLICE`. Equal:
/// the UNTIL_STABLE replies' `ticks`, `run`, `changed`, `latched`, `stable`,
/// and `total` offset by the one tick A ran; every byte of the SAVE files after
/// the flood and after the extract but the header's tick count (offset 20,
/// A's = B's + 1); the 16 EXPORT MORTON files; the slices (bits and BYTES);
/// and, on the binary circuit, O after extract EXACT against this file's own
/// cavity reference (outside voxels the box face does not reach through
/// outside voxels). The voxel morphology layout A at 8³, 16³, 32³, 64³ (binary and ternary),
/// each field with a planted 1-voxel cavity; before the zero step both handlers
/// get `SET <V0+c> TRUTH 1` on the planted voxel c. The flood case: a register
/// chain flooded, then zeroed by FILL against by a zero tick, re-seeded mid
/// chain (the registers below the seed are its cavity).
///
/// The control that must fail (G3_CONTROL in the environment; unset runs
/// the real check): `short` — B's FILL covers every voxel (register) but the planted one
/// (two FILLs around it); `skip` — B runs no FILL. Either way the flood enters
/// the cavity: the cavity count differs and O is not EXACT.
///
/// Also: the verb against this file's reference on random graphs (`EngineE1DaemonTests.buildGraph`, binary
/// and ternary; NODES ranges, a rank through its per-rank list — made current after a
/// SET RANK —, rank ranges over the rank lane, refusals); the grammar; the
/// allow-list (verdict, frontier index, plan, rank topology kept; the (truth,
/// rank) index dirtied); the WAL (record size by the log's delta, replay of
/// IMPORT MORTON + verbs, a refused record skipped by name, a version-2 log).
///
/// On the code before this verb the file does not compile: no `.setTruthFill`
/// command, no `lastSetTruthFillPath` seam, no WAL `setTruthFill`.
final class EngineG3DaemonTests: XCTestCase {

    typealias Rng = EngineE1DaemonTests.Rng
    typealias H = EngineG1DaemonTests.H
    typealias VoxelA = EngineG1DaemonTests.VoxelA
    typealias Sel = DagDBEngine.LutSelection

    /// The control (see the header): "", "short" or "skip".
    static let control = ProcessInfo.processInfo.environment["G3_CONTROL"] ?? ""

    private var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "engine-g3-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - The reference (this file's own)

    /// The selection's ids, ascending: ids lo…hi, or every node whose rank is in lo…hi.
    static func selection(_ sel: Sel, ranks: [UInt64]) -> [Int] {
        switch sel {
        case let .nodes(lo, hi): return lo > hi ? [] : Array(Int(lo)...Int(hi))
        case let .rank(lo, hi): return lo > hi ? [] : ranks.indices.filter { ranks[$0] >= lo && ranks[$0] <= hi }
        }
    }

    static func line(_ sel: Sel, _ v: UInt8, style: Int = 0) -> String {
        var s = "SET_TRUTH"
        switch sel {
        case let .nodes(lo, hi): s += " NODES \(lo)-\(hi)"
        case let .rank(lo, hi): s += " RANK \(lo)-\(hi)"
        }
        s += " FILL \(v)"
        return style % 3 == 1 ? s.lowercased() : s
    }

    /// The verb's refusal: the selection first, then the value.
    static func expectedRefusal(_ sel: Sel, _ v: UInt8, n: Int, nonBinary: Int) -> String? {
        switch sel {
        case let .nodes(lo, hi), let .rank(lo, hi):
            if lo > hi { return "ERROR out_of_range: range \(lo)-\(hi) is empty (lo > hi)" }
        }
        if case let .nodes(_, hi) = sel, hi >= UInt64(n) { return "ERROR out_of_range: node \(hi) not in 0..<\(n)" }
        if v >= 3 && nonBinary > 0 {
            return "ERROR bad_value: ternary: SET_TRUTH FILL \(v): the graph has \(nonBinary) ternary node(s), which hold "
                + "0..2; write a value of 3 or more per node with SET_TRUTH_BULK; nothing written"
        }
        return nil
    }

    /// The flood's cavity: outside voxels that no outside voxel on the box
    /// face reaches through face-adjacent outside voxels (the circuit's flood:
    /// the border seeds every face voxel, O = V | A on outside voxels only).
    static func cavity(_ lay: VoxelA, field: [Bool]) -> [Bool] {
        let n = lay.n, N = lay.N
        var reached = [Bool](repeating: false, count: N)
        var queue: [Int] = []
        for v in 0..<N where !field[v] {
            let z = v / (n * n), y = (v / n) % n, x = v % n
            if x == 0 || x == n - 1 || y == 0 || y == n - 1 || z == 0 || z == n - 1 { reached[v] = true; queue.append(v) }
        }
        var i = 0
        while i < queue.count {
            let v = queue[i]; i += 1
            let z = v / (n * n), y = (v / n) % n, x = v % n
            var nb: [Int] = []
            if x > 0 { nb.append(v - 1) }; if x < n - 1 { nb.append(v + 1) }
            if y > 0 { nb.append(v - n) }; if y < n - 1 { nb.append(v + n) }
            if z > 0 { nb.append(v - n * n) }; if z < n - 1 { nb.append(v + n * n) }
            for w in nb where !field[w] && !reached[w] { reached[w] = true; queue.append(w) }
        }
        return (0..<N).map { !field[$0] && !reached[$0] }
    }

    /// Plants a sealed 1-voxel cavity in the shell (radius ≈ 0.55 of the half
    /// side, on +x): the voxel outside, its six face neighbours inside. Returns it.
    static func plantCavity(_ lay: VoxelA, _ field: inout [Bool]) -> Int {
        let n = lay.n, m = n / 2
        let x = m + Int((Double(n - 1) / 2 * 0.55).rounded()), y = m, z = m
        let p = z * n * n + y * n + x
        field[p] = false
        for (dx, dy, dz) in [(-1, 0, 0), (1, 0, 0), (0, -1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1)] {
            field[(z + dz) * n * n + (y + dy) * n + (x + dx)] = true
        }
        return p
    }

    // MARK: - Helpers

    static func field(_ reply: String, _ key: String) -> String? {
        reply.split(separator: " ").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    /// A reply without `elapsed=` and `total=`, and the total.
    static func split(_ r: String) -> (String, Int) {
        let w = r.split(separator: " ")
        let rest = w.filter { !$0.hasPrefix("elapsed=") && !$0.hasPrefix("total=") && !$0.hasPrefix("nodes_computed=") }
        return (rest.joined(separator: " "), Int(field(r, "total") ?? "-1") ?? -1)
    }

    /// One voxel phase as the three SET_LUTS lines.
    func phase(_ lay: VoxelA, _ ph: String, _ h: H, _ label: String) {
        for (k, (sel, op)) in lay.verbs(ph).enumerated() {
            let r = h.cmd(EngineG1DaemonTests.line(sel, op, style: k))
            XCTAssertTrue(r.hasPrefix("OK SET_LUTS"), "\(label) \(ph) verb \(k): \(r)")
        }
    }

    /// SAVE on both: every byte equal but the header's tick count (offset 20),
    /// which is A's = B's + 1. Returns the bytes that differ elsewhere.
    func savesEqual(_ a: H, _ b: H, _ label: String) throws -> Int {
        let pa = tmp + "a.dags", pb = tmp + "b.dags"
        XCTAssertTrue(a.cmd("SAVE \(pa)").hasPrefix("OK SAVE"), label)
        XCTAssertTrue(b.cmd("SAVE \(pb)").hasPrefix("OK SAVE"), label)
        let da = try Data(contentsOf: URL(fileURLWithPath: pa)), db = try Data(contentsOf: URL(fileURLWithPath: pb))
        try FileManager.default.removeItem(atPath: pa); try FileManager.default.removeItem(atPath: pb)
        XCTAssertEqual(da.count, db.count, "\(label): SAVE sizes")
        guard da.count == db.count, da.count >= 32 else { return max(da.count, db.count) }
        var diff = 0
        for i in 0..<da.count where !(20..<24).contains(i) && da[i] != db[i] { diff += 1 }
        let ta = da.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) }
        let tb = db.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) }
        XCTAssertEqual(ta, tb &+ 1, "\(label): the SAVE header's tick count, A = B + 1")
        XCTAssertEqual(diff, 0, "\(label): SAVE bytes but the tick count")
        return diff
    }

    func exportsEqual(_ a: H, _ b: H, _ label: String) throws -> Int {
        let da = tmp + "xa", db = tmp + "xb"
        XCTAssertTrue(a.cmd("EXPORT MORTON \(da)").hasPrefix("OK EXPORT"), label)
        XCTAssertTrue(b.cmd("EXPORT MORTON \(db)").hasPrefix("OK EXPORT"), label)
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: da).sorted()
        XCTAssertEqual(names, try fm.contentsOfDirectory(atPath: db).sorted(), label)
        XCTAssertEqual(names.count, 16, "\(label): the 16 export files")
        var unequal = 0
        for f in names {
            let x = try Data(contentsOf: URL(fileURLWithPath: "\(da)/\(f)"))
            let y = try Data(contentsOf: URL(fileURLWithPath: "\(db)/\(f)"))
            if x != y { unequal += 1; XCTFail("\(label): \(f) differs") }
        }
        try fm.removeItem(atPath: da); try fm.removeItem(atPath: db)
        return unequal
    }

    /// The slice in shm after `line` on h: the reply and the bytes.
    func slice(_ h: H, _ line: String, bytes count: Int) -> (String, [UInt8]) {
        let r = h.cmd(line)
        let p = h.shm.advanced(by: 8).bindMemory(to: UInt8.self, capacity: count)
        return (r, Array(UnsafeBufferPointer(start: p, count: count)))
    }

    /// B's zero step: the FILL, or the control.
    func zeroByFill(_ h: H, lo: Int, count: Int, planted p: Int, _ label: String) {
        switch Self.control {
        case "skip":
            break
        case "short":
            if p > 0 { XCTAssertTrue(h.cmd("SET_TRUTH NODES \(lo)-\(lo + p - 1) FILL 0").hasPrefix("OK SET_TRUTH"), label) }
            if p < count - 1 { XCTAssertTrue(h.cmd("SET_TRUTH NODES \(lo + p + 1)-\(lo + count - 1) FILL 0").hasPrefix("OK SET_TRUTH"), label) }
        default:
            XCTAssertEqual(h.cmd("SET_TRUTH NODES \(lo)-\(lo + count - 1) FILL 0"), "OK SET_TRUTH nodes=\(count) truth=0", label)
            XCTAssertEqual(h.e.lastSetTruthFillPath, .range, label)
        }
    }

    // MARK: - The voxel morphology layout A in-process

    struct Tally {
        var cells = 0, untilStable = 0, replyMismatches = 0, saveChecks = 0, saveMismatches = 0
        var exportChecks = 0, exportMismatches = 0, sliceChecks = 0, sliceMismatches = 0
        var exact = 0, exactChecks = 0, plantedInCavity = 0
        var lines: [String] = []
        var line: String {
            "cells \(cells), UNTIL_STABLE pairs \(untilStable) (reply mismatches \(replyMismatches)), SAVE checks \(saveChecks) "
                + "(unequal \(saveMismatches)), export checks \(exportChecks) (unequal \(exportMismatches)), slice checks "
                + "\(sliceChecks) (unequal \(sliceMismatches)), EXACT \(exact)/\(exactChecks), planted voxel in the "
                + "reference cavity \(plantedInCavity)"
        }
    }

    func voxelCell(n: Int, ternary: Bool, _ t: inout Tally) throws {
        let lay = VoxelA(n: n)
        var fld = lay.field(seed: 0x63_0000 &+ UInt64(n))
        let p = Self.plantCavity(lay, &fld)
        let ref = Self.cavity(lay, field: fld)
        XCTAssertTrue(ref[p], "n=\(n): the planted voxel is a cavity")
        if ref[p] { t.plantedInCavity += 1 }
        let a = H(try lay.makeEngine(field: fld, ternary: ternary), side: lay.side, maxRank: lay.maxRank)
        let b = H(try lay.makeEngine(field: fld, ternary: ternary), side: lay.side, maxRank: lay.maxRank)
        XCTAssertEqual(a.e.nonBinaryNodeCount > 0, ternary)
        let label = "voxel layout A n=\(n) ternary=\(ternary) control=\(Self.control.isEmpty ? "none" : Self.control)"
        let N = lay.N, V0 = lay.V0, O0 = lay.O0
        // The same ops on both, up to closing3 (the morphology driver's order; surface seeded by the import).
        var ops: [(String, String)] = [("surface", "TICK 1")]
        for k in 1...3 { ops += [("seed", "TICK 1"), ("dilate", "TICK \(k)"), ("erode", "TICK \(k)")] }
        for (ph, tick) in ops {
            phase(lay, ph, a, label); phase(lay, ph, b, label)
            let ra = a.cmd(tick), rb = b.cmd(tick)
            XCTAssertTrue(ra.hasPrefix("OK TICK"), "\(label) \(ph): \(ra)")
            XCTAssertEqual(EngineG1DaemonTests.strip(ra), EngineG1DaemonTests.strip(rb), "\(label) \(ph)")
        }
        XCTAssertEqual(EngineG1DaemonTests.truthDiff(a.e, b.e), 0, "\(label): equal after closing3")
        // The planted voxel set on both, then the zero step: A the zero phase and TICK 1, B the FILL.
        for h in [a, b] { XCTAssertEqual(h.cmd("SET \(V0 + p) TRUTH 1"), "OK SET node=\(V0 + p) truth=1") }
        phase(lay, "zero", a, label)
        XCTAssertTrue(a.cmd("TICK 1").hasPrefix("OK TICK 1"))
        zeroByFill(b, lo: V0, count: N, planted: p, label)
        // The flood.
        phase(lay, "flood", a, label); phase(lay, "flood", b, label)
        let ua = a.cmd("TICK UNTIL_STABLE"), ub = b.cmd("TICK UNTIL_STABLE")
        t.untilStable += 1
        XCTAssertTrue(ua.hasPrefix("OK TICK UNTIL_STABLE stable "), "\(label): \(ua)")
        let (sa, ta) = Self.split(ua), (sb, tb) = Self.split(ub)
        if sa != sb || ta != tb + 1 { t.replyMismatches += 1 }
        XCTAssertEqual(sa, sb, "\(label): UNTIL_STABLE (ticks, run, changed, latched, stable)")
        XCTAssertEqual(ta, tb + 1, "\(label): total offset by A's zero tick")
        t.lines.append("n=\(n) ternary=\(ternary): A '\(ua)' | B '\(ub)'")
        t.saveChecks += 1; t.saveMismatches += try savesEqual(a, b, "\(label) after the flood") == 0 ? 0 : 1
        t.exportChecks += 1; t.exportMismatches += try exportsEqual(a, b, "\(label) after the flood") == 0 ? 0 : 1
        // Extract, then the slices.
        phase(lay, "extract", a, label); phase(lay, "extract", b, label)
        let xa = Self.split(a.cmd("TICK 1")), xb = Self.split(b.cmd("TICK 1"))
        XCTAssertEqual(xa.0, xb.0, "\(label): the extract tick"); XCTAssertEqual(xa.1, xb.1 + 1, label)
        for (form, count) in [("BYTES", N), ("", (N + 7) / 8)] {
            let line = "TRUTH_SLICE NODES \(O0)-\(O0 + N - 1)" + (form.isEmpty ? "" : " " + form)
            let (rA, bA) = slice(a, line, bytes: count), (rB, bB) = slice(b, line, bytes: count)
            t.sliceChecks += 1
            if rA != rB || bA != bB { t.sliceMismatches += 1 }
            XCTAssertEqual(rA, rB, "\(label): \(line)"); XCTAssertEqual(bA, bB, "\(label): \(line) bytes")
            if form == "BYTES" && !ternary {
                t.exactChecks += 2
                let oa = bA.map { $0 == 1 }, ob = bB.map { $0 == 1 }
                if oa == ref { t.exact += 1 }
                if ob == ref { t.exact += 1 }
                XCTAssertEqual(oa, ref, "\(label): A's O EXACT against the cavity reference")
                XCTAssertEqual(ob, ref, "\(label): B's O EXACT against the cavity reference")
                t.lines.append("n=\(n): cavity reference \(ref.filter { $0 }.count), A \(oa.filter { $0 }.count), B \(ob.filter { $0 }.count)")
            }
        }
        t.saveChecks += 1; t.saveMismatches += try savesEqual(a, b, "\(label) after the extract") == 0 ? 0 : 1
        t.cells += 1
    }

    /// Equivalence, the voxel layout A at 8³ and 16³ (binary and ternary).
    func testG3_1VoxelLayoutASmall() throws {
        var t = Tally()
        for n in [8, 16] { for ternary in [false, true] { try voxelCell(n: n, ternary: ternary, &t) } }
        print("G3.1 (i) voxel layout A 8³/16³ control=\(Self.control.isEmpty ? "none" : Self.control): " + t.line)
        for l in t.lines { print("  " + l) }
        XCTAssertEqual(t.cells, 4)
    }

    /// Equivalence, the voxel layout A at 32³ and 64³ (binary and ternary).
    func testG3_1VoxelLayoutALarge() throws {
        var t = Tally()
        for n in [32, 64] { for ternary in [false, true] { try voxelCell(n: n, ternary: ternary, &t) } }
        print("G3.1 (i) voxel layout A 32³/64³ control=\(Self.control.isEmpty ? "none" : Self.control): " + t.line)
        for l in t.lines { print("  " + l) }
        XCTAssertEqual(t.cells, 4)
    }

    // MARK: - Equivalence: the flood case of `EngineE2DaemonTests`

    /// The register chain of `EngineE2DaemonTests.floodChain`: registers R_i (rank 1) at ids 0..<m, C_i =
    /// OR(R_{i-1}, R_i) at 100+i, a back edge C_i → R_i.
    func floodChain(_ f: HandlerFixture, m: Int) {
        let h = f.handler
        for i in 0..<m {
            XCTAssertTrue(h.handle("SET \(i) RANK 1").hasPrefix("OK"))
            XCTAssertTrue(h.handle("SET \(100 + i) LUT OR").hasPrefix("OK"))
            if i > 0 { XCTAssertTrue(h.handle("CONNECT FROM \(i - 1) TO \(100 + i)").hasPrefix("OK")) }
            XCTAssertTrue(h.handle("CONNECT FROM \(i) TO \(100 + i)").hasPrefix("OK"))
            XCTAssertTrue(h.handle("CONNECT BACK FROM \(100 + i) TO \(i)").hasPrefix("OK"))
        }
    }

    /// The chain flooded from R_0 (every register 1), then zeroed — A by a
    /// zero tick (C := 0, TICK 1, C's LUT restored), B by the FILL over the
    /// registers —, then re-seeded at R_12: R_0…R_11 are the cavity the
    /// flood must not enter, R_12…R_29 flood.
    func testG3_1E2FloodCaseFillAgainstAZeroTick() throws {
        let side = 16, m = 30, seed = 12, planted = 5
        let fa = try HandlerFixture(side: side), fb = try HandlerFixture(side: side)
        let a = fa.handler, b = fb.handler
        floodChain(fa, m: m); floodChain(fb, m: m)
        for h in [a, b] {
            XCTAssertTrue(h.handle("SET 0 TRUTH 1").hasPrefix("OK"))
            XCTAssertTrue(h.handle("TICK UNTIL_STABLE").hasPrefix("OK TICK UNTIL_STABLE stable"))
            XCTAssertEqual(Array(h.engine.readTruthStates()[0..<m]), [UInt8](repeating: 1, count: m), "flooded")
        }
        let orLut = H.laneOf(a.engine)[100]
        XCTAssertEqual(a.handle("SET_LUTS NODES 100-\(100 + m - 1) FILL 0"), "OK SET_LUTS nodes=\(m) written=\(m)")
        XCTAssertTrue(a.handle("TICK 1").hasPrefix("OK TICK 1"))
        XCTAssertEqual(a.handle("SET_LUTS NODES 100-\(100 + m - 1) FILL \(String(orLut, radix: 16))"), "OK SET_LUTS nodes=\(m) written=\(m)")
        switch Self.control {
        case "skip": break
        case "short":
            XCTAssertTrue(b.handle("SET_TRUTH NODES 0-\(planted - 1) FILL 0").hasPrefix("OK SET_TRUTH"))
            XCTAssertTrue(b.handle("SET_TRUTH NODES \(planted + 1)-\(m - 1) FILL 0").hasPrefix("OK SET_TRUTH"))
        default:
            XCTAssertEqual(b.handle("SET_TRUTH NODES 0-\(m - 1) FILL 0"), "OK SET_TRUTH nodes=\(m) truth=0")
        }
        for h in [a, b] { XCTAssertTrue(h.handle("SET \(seed) TRUTH 1").hasPrefix("OK")) }
        let ua = a.handle("TICK UNTIL_STABLE"), ub = b.handle("TICK UNTIL_STABLE")
        print("G3.1 E2's flood case control=\(Self.control.isEmpty ? "none" : Self.control): A '\(ua)' | B '\(ub)'")
        let (sa, ta) = Self.split(ua), (sb, tb) = Self.split(ub)
        XCTAssertEqual(sa, sb, "UNTIL_STABLE (ticks, run, changed, latched, stable)")
        XCTAssertEqual(ta, tb + 1, "total offset by A's zero tick")
        XCTAssertEqual(Self.field(ua, "ticks"), "\(m - 1 - seed)")
        let want = (0..<m).map { UInt8($0 >= seed ? 1 : 0) }
        XCTAssertEqual(Array(a.engine.readTruthStates()[0..<m]), want, "A: the cavity R_0…R_\(seed - 1) stays 0")
        XCTAssertEqual(Array(b.engine.readTruthStates()[0..<m]), want, "B: the cavity R_0…R_\(seed - 1) stays 0")
        XCTAssertEqual(a.engine.readTruthStates(), b.engine.readTruthStates(), "every truth byte")
        XCTAssertEqual(H.laneOf(a.engine), H.laneOf(b.engine), "the LUT lanes")
        let pa = tmp + "ca.dags", pb = tmp + "cb.dags"
        XCTAssertTrue(a.handle("SAVE \(pa)").hasPrefix("OK SAVE")); XCTAssertTrue(b.handle("SAVE \(pb)").hasPrefix("OK SAVE"))
        var da = try Data(contentsOf: URL(fileURLWithPath: pa)), db = try Data(contentsOf: URL(fileURLWithPath: pb))
        let tka = da.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) }
        let tkb = db.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) }
        XCTAssertEqual(tka, tkb &+ 1, "the SAVE header's tick count")
        da.replaceSubrange(20..<24, with: Data(count: 4)); db.replaceSubrange(20..<24, with: Data(count: 4))
        XCTAssertEqual(da, db, "SAVE bytes but the tick count")
    }

    // MARK: - The verb against the reference

    struct FuzzTally {
        var verbs = 0, refused = 0, range = 0, list = 0, lane = 0, nodesWritten = 0, registersWritten = 0
        var ternaryNodesWritten = 0, laneMismatches = 0, replyMismatches = 0, otherLaneChanges = 0, rankWrites = 0
        var line: String {
            "verbs \(verbs) (refused \(refused); id range \(range), rank list \(list), rank lane \(lane)), nodes written "
                + "\(nodesWritten) (registers \(registersWritten), ternary nodes \(ternaryNodesWritten)), rank writes "
                + "\(rankWrites); truth-lane mismatches \(laneMismatches), reply mismatches \(replyMismatches), other "
                + "lanes changed \(otherLaneChanges)"
        }
    }

    func testG3_VerbAgainstTheReferenceOnRandomGraphs() throws {
        var t = FuzzTally()
        for seed in 0..<60 {
            let side = [8, 40, 64][seed % 3], ternary = seed % 4 == 1
            let f = try HandlerFixture(side: side)
            let h = f.handler, e = h.engine, n = e.nodeCount
            try EngineE1DaemonTests.buildGraph(e, seed: 0x6300 &+ UInt64(seed), ternary: ternary)
            e.markRankTopologyDirty()
            let registers = Set(e.backEdgeDsts.map { Int($0) })
            var rng = Rng(s: 0x63_1000 &+ UInt64(seed))
            if seed % 3 != 2 { XCTAssertTrue(h.handle("TICK 1").hasPrefix("OK TICK 1")) }     // the lists built
            let nonBinary = e.nonBinaryNodeCount
            XCTAssertEqual(nonBinary > 0, ternary)
            for step in 0..<30 {
                var ranks = e.readRanks()
                if rng.below(8) == 0 {
                    let node = rng.below(n), r = UInt64(rng.below(9))
                    XCTAssertEqual(h.handle("SET \(node) RANK \(r)"), "OK SET node=\(node) rank=\(r)")
                    t.rankWrites += 1
                    ranks = e.readRanks()
                }
                let sel: Sel
                switch rng.below(9) {
                case 0: sel = .nodes(0, UInt64(n - 1))
                case 1: let i = UInt64(rng.below(n)); sel = .nodes(i, i)
                case 2: sel = .nodes(UInt64(rng.below(n)), UInt64(n - 1))
                case 3: let lo = rng.below(n); sel = .nodes(UInt64(lo), UInt64(min(n - 1, lo + rng.below(80))))
                case 4: sel = rng.below(2) == 0 ? .nodes(UInt64(5 + rng.below(n - 5)), UInt64(rng.below(5))) : .nodes(UInt64(rng.below(n)), UInt64(n + rng.below(3)))
                case 5, 6: let r = UInt64(rng.below(9)); sel = .rank(r, r)
                case 7: let lo = UInt64(rng.below(8)); sel = .rank(lo, lo + UInt64(rng.below(4)))
                default: sel = rng.below(2) == 0 ? .rank(40, 90) : .rank(5, 2)
                }
                let v: UInt8 = rng.below(4) == 0 ? UInt8(3 + rng.below(253)) : UInt8(rng.below(3))
                let before = e.readTruthStates(), lutsBefore = H.laneOf(e)
                let line = Self.line(sel, v, style: step)
                let r = h.handle(line)
                t.verbs += 1
                if let want = Self.expectedRefusal(sel, v, n: n, nonBinary: nonBinary) {
                    t.refused += 1
                    if r != want { t.replyMismatches += 1 }
                    XCTAssertEqual(r, want, "seed \(seed) \(line)")
                    XCTAssertEqual(e.readTruthStates(), before, "seed \(seed) \(line): nothing written")
                    continue
                }
                var lane = before
                let ids = Self.selection(sel, ranks: ranks)
                for i in ids { lane[i] = v }
                if r != "OK SET_TRUTH nodes=\(ids.count) truth=\(v)" { t.replyMismatches += 1 }
                XCTAssertEqual(r, "OK SET_TRUTH nodes=\(ids.count) truth=\(v)", "seed \(seed) \(line)")
                if e.readTruthStates() != lane { t.laneMismatches += 1 }
                XCTAssertEqual(e.readTruthStates(), lane, "seed \(seed) \(line): the truth lane against the reference")
                if H.laneOf(e) != lutsBefore || e.readRanks() != ranks { t.otherLaneChanges += 1 }
                XCTAssertEqual(H.laneOf(e), lutsBefore, "seed \(seed) \(line): the LUT lane untouched")
                XCTAssertEqual(e.readRanks(), ranks, "seed \(seed) \(line): the ranks untouched")
                t.nodesWritten += ids.count
                t.registersWritten += ids.filter { registers.contains($0) }.count
                t.ternaryNodesWritten += ids.filter { TernaryReference.isTernary(e.modeByte($0)) }.count
                switch (sel, e.lastSetTruthFillPath) {
                case (.nodes, .range?): t.range += 1
                case (.rank(let lo, let hi), .rankList?):
                    XCTAssertEqual(lo, hi); t.list += 1
                case (.rank(let lo, let hi), .rankLane?):
                    XCTAssertTrue(lo < hi || seed % 3 == 2 || ids.isEmpty, "seed \(seed) \(line): a single rank with lists takes its list")
                    t.lane += 1
                default:
                    XCTFail("seed \(seed) \(line): path \(String(describing: e.lastSetTruthFillPath))")
                }
                if rng.below(6) == 0 {
                    // A rank write may have broken the DAG: the tick is then refused by name.
                    let r = h.handle("TICK UNTIL_STABLE MAX 3")
                    XCTAssertTrue(r.hasPrefix("OK TICK UNTIL_STABLE") || r.hasPrefix("ERROR invalid_graph"), r)
                }
            }
        }
        print("G3 the verb against the reference, 60 seeds: " + t.line)
        XCTAssertGreaterThan(t.list, 0); XCTAssertGreaterThan(t.lane, 0); XCTAssertGreaterThan(t.range, 0)
        XCTAssertGreaterThan(t.registersWritten, 0); XCTAssertGreaterThan(t.ternaryNodesWritten, 0)
    }

    /// A rank's list made current: FILL through rank 2's list, SET RANK moves
    /// node 2 out and node 4 in, FILL rank 2 again writes the new members.
    func testG3_RankListStaleness() throws {
        let f = try HandlerFixture(side: 16)
        let h = f.handler, e = h.engine
        for i in 0..<10 { XCTAssertTrue(h.handle("SET \(i) RANK \(i % 3)").hasPrefix("OK")) }
        XCTAssertTrue(h.handle("TICK 1").hasPrefix("OK TICK 1"))         // an edgeless graph: the lists built
        let k2 = e.readRanks().filter { $0 == 2 }.count
        XCTAssertEqual(h.handle("SET_TRUTH RANK 2-2 FILL 7"), "OK SET_TRUTH nodes=\(k2) truth=7")
        XCTAssertEqual(e.lastSetTruthFillPath, .rankList)
        XCTAssertEqual(h.handle("SET 2 RANK 3"), "OK SET node=2 rank=3")
        XCTAssertEqual(h.handle("SET 4 RANK 2"), "OK SET node=4 rank=2")
        XCTAssertEqual(h.handle("SET 2 TRUTH 0"), "OK SET node=2 truth=0")
        XCTAssertEqual(h.handle("SET_TRUTH RANK 2-2 FILL 9"), "OK SET_TRUTH nodes=\(k2) truth=9")
        XCTAssertEqual(e.lastSetTruthFillPath, .rankList)
        let tr = e.readTruthStates()
        XCTAssertEqual(tr[2], 0, "node 2 left rank 2")
        XCTAssertEqual(tr[4], 9, "node 4 joined rank 2")
    }

    // MARK: - Grammar, refusals, reader sessions

    func testG3_GrammarRefusalsAndReaderSessions() throws {
        guard case let .setTruthFill(s1, v1) = DSLParser.parse("SET_TRUTH NODES 3-9 FILL 0") else { return XCTFail() }
        XCTAssertEqual(s1, .nodes(3, 9)); XCTAssertEqual(v1, 0)
        guard case let .setTruthFill(s2, v2) = DSLParser.parse("set_truth rank 2-2 fill 255") else { return XCTFail() }
        XCTAssertEqual(s2, .rank(2, 2)); XCTAssertEqual(v2, 255)
        for bad in ["SET_TRUTH", "SET_TRUTH NODES 3-9", "SET_TRUTH NODES 3-9 FILL", "SET_TRUTH NODES 3-9 FILL 256",
                    "SET_TRUTH NODES 3-9 FILL -1", "SET_TRUTH NODES 3-9 FILL 0x1", "SET_TRUTH NODES 3 FILL 1",
                    "SET_TRUTH EDGES 3-9 FILL 1", "SET_TRUTH NODES 3-9 FILL 1 2", "SET_TRUTH NODES 3-9 MAP 1=2",
                    "SET_TRUTH NODES -1-9 FILL 1", "SET_TRUTH NODES 3-9 BYTES"] {
            guard case .unknown = DSLParser.parse(bad) else { XCTFail(bad); continue }
        }
        let f = try HandlerFixture(side: 8)
        let h = f.handler
        XCTAssertEqual(h.handle("SET_TRUTH NODES 9-3 FILL 1"), "ERROR out_of_range: range 9-3 is empty (lo > hi)")
        XCTAssertEqual(h.handle("SET_TRUTH NODES 3-64 FILL 1"), "ERROR out_of_range: node 64 not in 0..<64")
        XCTAssertEqual(h.handle("SET_TRUTH RANK 9-3 FILL 1"), "ERROR out_of_range: range 9-3 is empty (lo > hi)")
        XCTAssertEqual(h.handle("SET_TRUTH RANK 40-90 FILL 1"), "OK SET_TRUTH nodes=0 truth=1")
        XCTAssertEqual(h.handle("SET_TRUTH NODES 0-63 FILL 200"), "OK SET_TRUTH nodes=64 truth=200", "a binary graph keeps 0..255")
        XCTAssertEqual(h.handle("SET 5 TRUTH 0"), "OK SET node=5 truth=0")
        XCTAssertEqual(h.handle("SET 5 MODE TTHRESH"), "OK SET node=5 mode=TTHRESH noskip=0")   // a ternary node with no library
        XCTAssertEqual(h.handle("SET_TRUTH NODES 6-9 FILL 3"),
                       "ERROR bad_value: ternary: SET_TRUTH FILL 3: the graph has 1 ternary node(s), which hold 0..2; "
                        + "write a value of 3 or more per node with SET_TRUTH_BULK; nothing written")
        XCTAssertEqual(h.engine.readTruthStates()[6], 200, "nothing written")
        XCTAssertEqual(h.handle("SET_TRUTH NODES 0-63 FILL 2"), "OK SET_TRUTH nodes=64 truth=2", "0..2 on every mode")
        XCTAssertEqual(h.engine.readTruthStates(), [UInt8](repeating: 2, count: 64))
        let rd = h.handle("OPEN_READER")
        let id = rd.split(separator: " ").first { $0.hasPrefix("id=") }!.dropFirst(3)
        XCTAssertEqual(h.handle("READER \(id) SET_TRUTH NODES 0-3 FILL 1"), "ERROR forbidden: command not allowed in reader session (read-only)")
        XCTAssertEqual(h.engine.readTruthStates()[0], 2)
    }

    // MARK: - The allow-list

    /// After SET_TRUTH FILL (every form, a refusal included): the DAG verdict
    /// kept, the frontier index, the latch plan and the rank topology kept, the
    /// (truth, rank) index dirtied; the next TICK and UNTIL_STABLE re-verify
    /// and rebuild nothing.
    func testG3_AllowListKeepsTheVerdictTheIndexAndThePlan() throws {
        let side = 16
        let f = try HandlerFixture(side: side, maxRank: 8)
        let h = f.handler, e = h.engine
        try EngineE1DaemonTests.buildGraph(e, seed: 0x633, ternary: false)
        e.markRankTopologyDirty()
        XCTAssertTrue(h.handle("TICK UNTIL_STABLE MAX 20").hasPrefix("OK TICK UNTIL_STABLE"))
        XCTAssertTrue(h.handle("TICK 2").hasPrefix("OK TICK 2"))
        let v0 = h.dagVerdictCheckCount, ix0 = e.frontierIndexBuildCount, pl0 = e.latchPlanBuildCount
        let rt0 = e.rankTopologyRebuildCount
        XCTAssertEqual(v0, 1); XCTAssertEqual(ix0, 1); XCTAssertEqual(pl0, 1)
        for verb in ["SET_TRUTH NODES 0-255 FILL 0", "SET_TRUTH RANK 3-3 FILL 1", "SET_TRUTH RANK 0-7 FILL 0",
                     "SET_TRUTH NODES 9-3 FILL 1", "SET_TRUTH RANK 7-7 FILL 1"] {
            XCTAssertTrue(h.handle("SELECT TRUTH 1 RANK 0-7").hasPrefix("OK SELECT"))
            XCTAssertFalse(h.truthRankIndex.isDirty)
            let r = h.handle(verb)
            let refused = verb.contains("9-3")
            XCTAssertTrue(r.hasPrefix(refused ? "ERROR" : "OK SET_TRUTH"), "\(verb): \(r)")
            XCTAssertTrue(h.dagVerdict.checked, "\(verb) keeps the DAG verdict")
            XCTAssertTrue(e.hasFrontierIndex, "\(verb) keeps the frontier index")
            XCTAssertFalse(e.rankTopologyDirty, "\(verb) is not a rank write")
            XCTAssertEqual(h.truthRankIndex.isDirty, !refused, "\(verb): a truth write dirties the (truth, rank) index")
            XCTAssertTrue(h.handle("TICK 1").hasPrefix("OK TICK 1"))
            XCTAssertTrue(h.handle("TICK UNTIL_STABLE MAX 5").hasPrefix("OK TICK UNTIL_STABLE"))
        }
        print("G3 allow-list: verdict checks \(v0) -> \(h.dagVerdictCheckCount), index builds \(ix0) -> \(e.frontierIndexBuildCount), "
              + "plan builds \(pl0) -> \(e.latchPlanBuildCount), rank-topology rebuilds \(rt0) -> \(e.rankTopologyRebuildCount)")
        XCTAssertEqual(h.dagVerdictCheckCount, v0, "no rank-order re-verification after SET_TRUTH FILL")
        XCTAssertEqual(e.frontierIndexBuildCount, ix0, "the frontier index not rebuilt")
        XCTAssertEqual(e.latchPlanBuildCount, pl0, "F1's plan kept")
        XCTAssertEqual(e.rankTopologyRebuildCount, rt0, "the rank lists not rebuilt")
    }

    // MARK: - The WAL

    /// The record by the log's size delta: ≤ 32 bytes for every form.
    func testG3_WALRecordSize() throws {
        let p = tmp + "sizes.wal"
        let w = try DagDBWAL.Appender(path: p, nodeCount: 64)
        let f = try HandlerFixture(side: 8, wal: w)
        var size = try Data(contentsOf: URL(fileURLWithPath: p)).count
        var out: [String] = []
        for line in ["SET_TRUTH NODES 0-63 FILL 0", "SET_TRUTH RANK 0-0 FILL 1", "SET_TRUTH RANK 0-9 FILL 255"] {
            XCTAssertTrue(f.handler.handle(line).hasPrefix("OK SET_TRUTH"), line)
            w.barrier()
            let s = try Data(contentsOf: URL(fileURLWithPath: p)).count
            XCTAssertLessThanOrEqual(s - size, 32, line)
            out.append("\(line): \(s - size) B")
            size = s
        }
        XCTAssertEqual(f.handler.handle("SET_TRUTH NODES 9-3 FILL 1"), "ERROR out_of_range: range 9-3 is empty (lo > hi)")
        w.barrier()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: p)).count, size, "a refused verb logs nothing")
        print("G3 WAL record bytes: " + out.joined(separator: "; "))
    }

    /// IMPORT MORTON (the ternary graph of `EngineE1DaemonTests.buildGraph`) + 20 verbs (SET RANK and SET TRUTH
    /// among them) on a daemon with a WAL; a fresh engine replays the log
    /// alone: the truth lane equals the live one.
    func testG3_WALReplayImportAndVerbs() throws {
        let side = 16, n = side * side
        let src = try DagDBEngine(grid: try HexGrid(width: side, height: side), state: DagDBState(width: side, height: side), maxRank: 8)
        try EngineE1DaemonTests.buildGraph(src, seed: 0x634, ternary: true)
        let dir = tmp + "imp"
        _ = try DagDBSnapshot.exportMorton(engine: src, nodeCount: n, dir: dir)
        let p = tmp + "replay.wal"
        let w = try DagDBWAL.Appender(path: p, nodeCount: n)
        let f = try HandlerFixture(side: side, wal: w, maxRank: 8)
        let h = f.handler
        XCTAssertTrue(h.handle("IMPORT MORTON \(dir)").hasPrefix("OK IMPORT"))   // no TICK: a tick is not logged
        let t0 = h.engine.readTruthStates()
        var rng = Rng(s: 0x6344)
        var applied = 1                                                  // the import
        var lines: [String] = []
        for i in 0..<20 {
            let line: String
            switch i % 5 {
            case 0: line = "SET \(rng.below(n)) RANK \(rng.below(8))"
            case 1: line = "SET_TRUTH RANK \(i % 8)-\(i % 8) FILL \(rng.below(3))"
            case 2: let lo = rng.below(n); line = "SET_TRUTH NODES \(lo)-\(min(n - 1, lo + rng.below(40))) FILL \(rng.below(3))"
            case 3: line = "SET_TRUTH RANK 2-5 FILL \(rng.below(3))"
            default: line = "SET \(rng.below(n)) TRUTH \(rng.below(2))"
            }
            XCTAssertTrue(h.handle(line).hasPrefix("OK"), line)
            lines.append(line); applied += 1
        }
        XCTAssertNotEqual(h.engine.readTruthStates(), t0)
        w.barrier()
        let fresh = try DagDBEngine(grid: try HexGrid(width: side, height: side), state: DagDBState(width: side, height: side), maxRank: 8)
        let r = try DagDBWAL.replay(engine: fresh, nodeCount: n, path: p)
        print("G3 WAL replay: applied=\(r.recordsApplied) skipped=\(r.recordsSkipped) refusals=\(r.refusals); verbs \(lines.count)")
        XCTAssertEqual(r.recordsApplied, applied)
        XCTAssertEqual(r.recordsSkipped, 0)
        XCTAssertEqual(fresh.readTruthStates(), h.engine.readTruthStates(), "replayed against live")
        XCTAssertEqual(fresh.readRanks(), h.engine.readRanks())
    }

    /// Records the replayed graph refuses — a NODES selection past the lane, a
    /// value ≥ 3 once the graph has a ternary node — are skipped, counted
    /// under out_of_range and named; the records around them apply. A
    /// version-2 log refuses the verb by name, nothing written.
    func testG3_WALRefusedRecordsSkippedByNameAndV2LogRefuses() throws {
        let p = tmp + "oor.wal"
        let w = try DagDBWAL.Appender(path: p, nodeCount: 64)
        try w.setTruthFill(.nodes(0, 3), 9)
        try w.setTruthFill(.nodes(10, 64), 1)
        try w.setMode(node: 20, mode: 2)                       // TTHRESH: no library needed
        try w.setTruthFill(.nodes(4, 7), 5)
        try w.setTruthFill(.rank(0, 0), 2)
        w.barrier()
        let e = try DagDBEngine(grid: try HexGrid(width: 8, height: 8), state: DagDBState(width: 8, height: 8), maxRank: 8)
        let r = try DagDBWAL.replay(engine: e, nodeCount: 64, path: p)
        print("G3 WAL refused records: applied=\(r.recordsApplied) skipped=\(r.skipReasons.line) refusals=\(r.refusals)")
        XCTAssertEqual(r.recordsApplied, 3)
        XCTAssertEqual(r.skipReasons.outOfRangeIndex, 2)
        XCTAssertEqual(r.refusals.count, 2)
        XCTAssertTrue(r.refusals[0].contains("SET_TRUTH NODES 10-64 FILL 1: node 64 not in 0..<64; not applied"), r.refusals[0])
        XCTAssertTrue(r.refusals[1].contains("SET_TRUTH NODES 4-7 FILL 5: the graph has 1 ternary node(s)"), r.refusals[1])
        let tr = e.readTruthStates()
        XCTAssertEqual(tr, [UInt8](repeating: 2, count: 64), "rank 0 is every node: FILL 2 last")
        // A version-2 log.
        let p2 = tmp + "v2.wal"
        var hdr = Data(DagDBWAL.magic)
        for v in [UInt32(2), UInt32(16), UInt32(0)] { withUnsafeBytes(of: v.littleEndian) { hdr.append(contentsOf: $0) } }
        try hdr.write(to: URL(fileURLWithPath: p2))
        let f = try HandlerFixture(side: 4, wal: try DagDBWAL.Appender(path: p2, nodeCount: 16))
        // The refusal names the way to a log that takes the record.
        XCTAssertEqual(f.handler.handle("SET_TRUTH NODES 0-3 FILL 1"), "ERROR wal: append: opcode 0x50 needs log version 3, this log is version 2"
                       + "; nothing written; this log cannot be upgraded in place: first stop every writer (a write between this SAVE and the stop stays in the log moved aside, and is lost); then SAVE a snapshot to a file, stop the daemon, move \(p2) aside" + " and start it again with DAGDB_STARTUP_LOAD naming that file (it loads the file and opens a fresh version-3 log;" + " the fresh log takes this record)")
        XCTAssertEqual(f.handler.engine.readTruthStates()[0], 0)
    }
}
