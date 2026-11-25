import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// `TRUTH_SLICE NODES|RANK <lo>-<hi>` packed over the selection only, 8 nodes
/// per step (a NODES range; `RANK r-r` through rank r's per-rank list), and `TRUTH_SLICE … BYTES`, the raw lane.
///
/// Equivalence. Every call runs twice on one handler, the shm region
/// prefilled with the same pattern before each: once through the older loop
/// (the seam `truthSliceOldLoopForTesting`: the per-node loop's two passes, kept),
/// once through the range path. The two replies and the two shm regions (the header,
/// the slice, and the untouched bytes after it; on a refusal the whole
/// region, untouched) must be equal, and the range path's call must equal this file's
/// own reference (`reference`, computed from the engine's truth and rank
/// lanes by the verb's definition; never the engine's code). Cases:
///   - the earlier test cases: the graphs of `EngineE1DaemonTests` at sides
///     16 (binary), 24 and 32 (ternary) after `TICK 2`: every rank, every rank
///     range, the whole lane, a sub-range; the refusal cell;
///   - an independent check's slice cases, ported: 256 nodes, random ranks
///     0…5 and truth 0/1, every rank range in 0…6, 40 random id ranges, the
///     boundary lines, a 2 on a binary node, a Loom code (node 30, truth 9),
///     a ternary node, reader sessions (the snapshot, the width);
///   - random lanes with trits and with Loom bytes at random positions, on
///     random rank shapes (blocks, few, many, interleaved, sparse), ternary
///     modes in some, the lists absent, present, and left stale by a rank
///     write;
///   - NODES ranges of length 0…70 at every alignment (lo mod 8 = 0…7, tails
///     of 1…7 nodes), ranges ending on the last id, and the same selections
///     as one rank through its list (contiguous ids; every other id);
///   - the random mixed graphs (ranks whose ids are not contiguous: the list's gather);
///   - `lo < hi` on ranks (the older loop, kept).
/// `BYTES` against the same reference (every byte verbatim, Loom codes
/// included, never refused by content) and against NODES' truth column.
///
/// The controls (each one line, run in the worktree, restored): (1) the
/// pack's bit order reversed — every slice with a 1 in a non-palindromic
/// byte mismatches; (2) the first-offender search returning the last
/// offender, or the offender of the previous 8-node word — the refusal names
/// the wrong node on a lane with two Loom bytes.
///
/// On the code before this path the file does not compile (no
/// `truthSliceOldLoopForTesting`, no `lastTruthSlicePath`); `BYTES` is an
/// unknown command there.
final class EngineG2DaemonTests: XCTestCase {

    typealias Rng = EngineE1DaemonTests.Rng
    typealias H = EngineG1DaemonTests.H

    // MARK: - The reference (this file's own; never the engine's code)

    struct Lanes {
        let truth: [UInt8]
        let ranks: [UInt64]
        let nonBinary: Bool
    }

    static func lanes(_ e: DagDBEngine) -> Lanes {
        let n = e.nodeCount
        let t = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: max(n, 1))
        return Lanes(truth: Array(UnsafeBufferPointer(start: t, count: n)), ranks: e.readRanks(),
                     nonBinary: e.nonBinaryNodeCount > 0)
    }

    struct Spec: CustomStringConvertible {
        let byRank: Bool
        let lo: UInt64
        let hi: UInt64
        let bytes: Bool
        var description: String { "TRUTH_SLICE \(byRank ? "RANK" : "NODES") \(lo)-\(hi)\(bytes ? " BYTES" : "")" }
        func with(bytes b: Bool) -> Spec { Spec(byRank: byRank, lo: lo, hi: hi, bytes: b) }
    }

    /// The documented TRUTH_SLICE reply (dsl.md) for bits and trits, and for
    /// BYTES: the reply, and the shm bytes from offset 0 (nil: a refusal,
    /// nothing written).
    static func reference(_ L: Lanes, _ s: Spec, session: String?) -> (reply: String, payload: [UInt8]?) {
        let n = L.truth.count
        if s.lo > s.hi { return ("ERROR out_of_range: range \(s.lo)-\(s.hi) is empty (lo > hi)", nil) }
        if !s.byRank && s.hi >= UInt64(n) { return ("ERROR out_of_range: node \(s.hi) not in 0..<\(n)", nil) }
        let ids: [Int] = s.byRank ? (0..<n).filter { L.ranks[$0] >= s.lo && L.ranks[$0] <= s.hi }
                                  : Array(Int(s.lo)...Int(s.hi))
        if !s.bytes, let i = ids.first(where: { L.truth[$0] >= 3 }) {
            return ("ERROR bad_value: TRUTH_SLICE node \(i) truth \(L.truth[i]) does not fit 2 bits (0, 1, 2); "
                    + "read it with NODES or GET", nil)
        }
        let bits = s.bytes ? 8 : ((!L.nonBinary && !ids.contains { L.truth[$0] == 2 }) ? 1 : 2)
        let nb = (ids.count * bits + 7) / 8
        var p = [UInt8](repeating: 0, count: 8 + nb)
        for k in 0..<4 {
            p[k] = UInt8((UInt32(ids.count) >> (8 * UInt32(k))) & 0xFF)
            p[4 + k] = UInt8((UInt32(bits) >> (8 * UInt32(k))) & 0xFF)
        }
        for (j, i) in ids.enumerated() {
            let bit = j * bits
            p[8 + bit / 8] |= L.truth[i] << UInt8(bit % 8)
        }
        let fmt = bits == 1 ? "bits" : (bits == 2 ? "trits" : "bytes")
        let sess = session.map { " session=\($0)" } ?? ""
        let reply = "OK TRUTH_SLICE\(sess) nodes=\(ids.count) format=\(fmt) bits_per_node=\(bits) shm_bytes=\(nb) "
            + "first=\(ids.first.map { String($0) } ?? "-") last=\(ids.last.map { String($0) } ?? "-")"
        return (reply, p)
    }

    static func strip(_ r: String) -> String { EngineG1DaemonTests.strip(r) }

    static func pattern(_ k: Int) -> UInt8 { UInt8(truncatingIfNeeded: k &* 131 &+ 0x5A) }

    // MARK: - One call, two ways

    struct Tally {
        var calls = 0, ok = 0, refused = 0, bits = 0, trits = 0, bytes = 0, withOne = 0
        var pathRange = 0, pathList = 0, pathE2 = 0, pathNone = 0, sessionCalls = 0
        var oldNewMismatch = 0, refMismatch = 0
        var failures: [String] = []
        var line: String {
            "calls \(calls) (OK \(ok): bits \(bits), trits \(trits), bytes \(bytes); refused \(refused); slices "
                + "holding a 1 \(withOne); reader-session calls \(sessionCalls)); G2 paths: id range \(pathRange), "
                + "rank list \(pathList), E2 loop \(pathE2), refused before dispatch \(pathNone); old/new mismatches "
                + "\(oldNewMismatch), reference mismatches \(refMismatch)"
        }
        mutating func add(_ o: Tally) {
            calls += o.calls; ok += o.ok; refused += o.refused; bits += o.bits; trits += o.trits; bytes += o.bytes
            withOne += o.withOne; pathRange += o.pathRange; pathList += o.pathList; pathE2 += o.pathE2
            pathNone += o.pathNone; sessionCalls += o.sessionCalls; oldNewMismatch += o.oldNewMismatch
            refMismatch += o.refMismatch; failures += o.failures.prefix(max(0, 12 - failures.count))
        }
    }

    /// `spec` through the per-node loop and through the range path, each on the same
    /// prefilled shm region; both against each other and the range path against the
    /// reference built from `L` (the lanes the handler reads: the live
    /// engine's, or a reader session's snapshot).
    func slice(_ h: H, _ s: Spec, _ L: Lanes, session: String? = nil, _ t: inout Tally, _ label: String) {
        let region = 8 + h.n + 64
        let shm = h.shm.assumingMemoryBound(to: UInt8.self)
        let line = (session.map { "READER \($0) " } ?? "") + s.description
        func fill() { for k in 0..<region { shm[k] = Self.pattern(k) } }
        func grab() -> [UInt8] { Array(UnsafeBufferPointer(start: shm, count: region)) }
        fill()
        h.handler.truthSliceOldLoopForTesting = true
        let r0 = Self.strip(h.cmd(line)), s0 = grab()
        fill()
        h.handler.truthSliceOldLoopForTesting = false
        let r1 = Self.strip(h.cmd(line)), s1 = grab()
        let path = h.handler.lastTruthSlicePath
        let ref = Self.reference(L, s, session: session)
        var want = (0..<region).map { Self.pattern($0) }
        if let p = ref.payload { for (k, b) in p.enumerated() { want[k] = b } }
        t.calls += 1
        if session != nil { t.sessionCalls += 1 }
        switch path {
        case "range": t.pathRange += 1
        case "rankList": t.pathList += 1
        case "e2Loop": t.pathE2 += 1
        default: t.pathNone += 1
        }
        if r1.hasPrefix("OK") {
            t.ok += 1
            if r1.contains("format=bits") { t.bits += 1 } else if r1.contains("format=trits") { t.trits += 1 } else { t.bytes += 1 }
            if !s.bytes, let p = ref.payload, p.dropFirst(8).contains(where: { $0 != 0 }) { t.withOne += 1 }
        } else {
            t.refused += 1
        }
        if r0 != r1 || s0 != s1 {
            t.oldNewMismatch += 1
            if t.failures.count < 12 {
                let d = (0..<region).first { s0[$0] != s1[$0] }.map { "first shm byte differing \($0)" } ?? "shm equal"
                t.failures.append("\(label): '\(line)' E2 loop '\(r0)' / G2 '\(r1)' (\(d), G2 path \(path))")
            }
        }
        if r1 != ref.reply || s1 != want {
            t.refMismatch += 1
            if t.failures.count < 12 {
                let d = (0..<region).first { s1[$0] != want[$0] }.map { "first shm byte differing \($0)" } ?? "shm equal"
                t.failures.append("\(label): '\(line)' G2 '\(r1)' / reference '\(ref.reply)' (\(d), G2 path \(path))")
            }
        }
    }

    /// Both forms of a spec: bits/trits and BYTES.
    func both(_ h: H, _ s: Spec, _ L: Lanes, session: String? = nil, _ t: inout Tally, _ label: String) {
        slice(h, s.with(bytes: false), L, session: session, &t, label)
        slice(h, s.with(bytes: true), L, session: session, &t, label)
    }

    func assertClean(_ t: Tally, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let msg = "\(label): \(t.line)\n" + t.failures.joined(separator: "\n")
        print("G2.1 \(label): \(t.line)")
        for f in t.failures { print("  FAIL \(f)") }
        XCTAssertGreaterThan(t.calls, 0, msg, file: file, line: line)
        XCTAssertEqual(t.oldNewMismatch, 0, msg, file: file, line: line)
        XCTAssertEqual(t.refMismatch, 0, msg, file: file, line: line)
    }

    // MARK: - Graphs

    /// A fresh handler over an empty side × side graph (no slots), as HandlerFixture builds it.
    func freshH(side: Int, maxRank: Int = 16) throws -> H {
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side), maxRank: maxRank)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        return H(e, side: side, maxRank: maxRank)
    }

    static func writeTruth(_ e: DagDBEngine, _ v: [UInt8]) {
        let p = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: e.nodeCount)
        for i in 0..<v.count { p[i] = v[i] }
    }

    static func writeRanks(_ h: H, _ r: [UInt64]) {
        h.put(r, count: r.count, verb: .setRanksBulk)
        XCTAssertTrue(h.cmd("SET_RANKS_BULK").hasPrefix("OK"))
    }

    // MARK: - The earlier test cases

    func e2Cell(side: Int, seed: UInt64, ternary: Bool, _ t: inout Tally) throws {
        let n = side * side
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side), maxRank: 8)
        try EngineE1DaemonTests.buildGraph(e, seed: seed, ternary: ternary)
        let h = H(e, side: side, maxRank: 8)
        let label = "E2 side \(side) ternary \(ternary)"
        // Before any tick: no per-rank lists (RANK r-r takes the per-node loop); then TICK 2 builds them.
        for pass in 0..<2 {
            if pass == 1 { XCTAssertTrue(h.cmd("TICK 2").hasPrefix("OK TICK")) }
            let L = Self.lanes(e)
            let present = Set(L.ranks).sorted()
            for r in present { both(h, Spec(byRank: true, lo: r, hi: r, bytes: false), L, &t, label) }
            for a in present { for b in present where b > a { both(h, Spec(byRank: true, lo: a, hi: b, bytes: false), L, &t, label) } }
            both(h, Spec(byRank: false, lo: 0, hi: UInt64(n - 1), bytes: false), L, &t, label)
            both(h, Spec(byRank: false, lo: 37, hi: UInt64(n / 2), bytes: false), L, &t, label)
            both(h, Spec(byRank: true, lo: 5, hi: 9, bytes: false), L, &t, label)
            both(h, Spec(byRank: true, lo: UInt64(n + 3), hi: UInt64(n + 3), bytes: false), L, &t, label)
        }
    }

    func testG2_1E2GateCases() throws {
        var t = Tally()
        try e2Cell(side: 16, seed: 0xE41, ternary: false, &t)
        try e2Cell(side: 24, seed: 0xE42, ternary: true, &t)
        try e2Cell(side: 32, seed: 0xE43, ternary: true, &t)
        // The earlier refusal cell (side 4), without and with the per-rank lists.
        let h = try freshH(side: 4, maxRank: 8)
        XCTAssertTrue(h.cmd("SET 5 TRUTH 200").hasPrefix("OK"))
        for pass in 0..<2 {
            if pass == 1 { try h.e.prepareRankLists() }
            var L = Self.lanes(h.e)
            for s in [Spec(byRank: false, lo: 0, hi: 15, bytes: false), Spec(byRank: false, lo: 0, hi: 16, bytes: false),
                      Spec(byRank: false, lo: 9, hi: 3, bytes: false), Spec(byRank: false, lo: 0, hi: 4, bytes: false),
                      Spec(byRank: true, lo: 0, hi: 0, bytes: false), Spec(byRank: true, lo: 5, hi: 9, bytes: false)] {
                both(h, s, L, &t, "E2 refusal cell")
            }
            XCTAssertTrue(h.cmd("SET 2 TRUTH 2").hasPrefix("OK"))
            L = Self.lanes(h.e)
            both(h, Spec(byRank: false, lo: 0, hi: 4, bytes: false), L, &t, "E2 refusal cell")
            both(h, Spec(byRank: true, lo: 0, hi: 0, bytes: false), L, &t, "E2 refusal cell")
            XCTAssertTrue(h.cmd("SET 2 TRUTH 0").hasPrefix("OK"))
        }
        assertClean(t, "E2's gate cases")
        XCTAssertGreaterThan(t.pathList, 0)
        XCTAssertGreaterThan(t.pathRange, 0)
        XCTAssertGreaterThan(t.pathE2, 0)
        XCTAssertGreaterThan(t.trits, 0)
        XCTAssertGreaterThan(t.bits, 0)
    }

    // MARK: - An independent check's slice cases (ported)

    func testG2_1VerifierT4SliceCases() throws {
        let N = 256
        let h = try freshH(side: 16, maxRank: 8)
        var g = Rng(s: 0x74_5115)
        for i in 0..<N {
            XCTAssertTrue(h.cmd("SET \(i) RANK \(g.below(6))").hasPrefix("OK"))
            XCTAssertTrue(h.cmd("SET \(i) TRUTH \(g.below(2))").hasPrefix("OK"))
        }
        var t = Tally()
        func full(_ label: String, session: String? = nil, lanes: Lanes? = nil) {
            let L = lanes ?? Self.lanes(h.e)
            both(h, Spec(byRank: false, lo: 0, hi: UInt64(N - 1), bytes: false), L, session: session, &t, label)
            for lo in 0..<7 { for hi in lo..<7 { both(h, Spec(byRank: true, lo: UInt64(lo), hi: UInt64(hi), bytes: false), L, session: session, &t, label) } }
            for _ in 0..<40 {
                let lo = g.below(N), hi = lo + g.below(N - lo)
                both(h, Spec(byRank: false, lo: UInt64(lo), hi: UInt64(hi), bytes: false), L, session: session, &t, label)
            }
        }
        func boundaries(_ label: String) {
            let L = Self.lanes(h.e)
            let specs: [Spec] = [
                Spec(byRank: false, lo: 0, hi: 0, bytes: false), Spec(byRank: false, lo: 255, hi: 255, bytes: false),
                Spec(byRank: false, lo: 256, hi: 256, bytes: false), Spec(byRank: false, lo: 0, hi: 256, bytes: false),
                Spec(byRank: false, lo: 5, hi: 4, bytes: false), Spec(byRank: true, lo: 7, hi: 7, bytes: false),
                Spec(byRank: true, lo: 6, hi: 100, bytes: false), Spec(byRank: true, lo: 0, hi: UInt64.max, bytes: false),
                Spec(byRank: false, lo: UInt64.max, hi: UInt64.max, bytes: false),
                Spec(byRank: true, lo: UInt64.max, hi: UInt64.max, bytes: false)]
            for s in specs { both(h, s, L, &t, label) }
            // The lines that do not parse: both paths give the same unknown_command, BYTES or not.
            for l in ["TRUTH_SLICE RANK 3", "TRUTH_SLICE NODES a-b", "TRUTH_SLICE NODES 3-", "TRUTH_SLICE NODES -3",
                      "TRUTH_SLICE RANK 3 BYTES", "TRUTH_SLICE NODES 3- BYTES"] {
                h.handler.truthSliceOldLoopForTesting = true
                let a = h.cmd(l)
                h.handler.truthSliceOldLoopForTesting = false
                let b = h.cmd(l)
                XCTAssertEqual(a, "ERROR unknown_command: \(Reply.quoted(l))")
                XCTAssertEqual(b, "ERROR unknown_command: \(Reply.quoted(l))")
            }
        }
        for pass in 0..<2 {
            let tag = pass == 0 ? "no lists" : "lists"
            if pass == 1 { try h.e.prepareRankLists() }
            full("t4 binary 0/1, \(tag)")
            boundaries("t4 boundaries, \(tag)")
            XCTAssertTrue(h.cmd("SET 17 TRUTH 2").hasPrefix("OK"))
            full("t4 binary with a 2, \(tag)")
            both(h, Spec(byRank: false, lo: 0, hi: 16, bytes: false), Self.lanes(h.e), &t, "t4 excluding the 2, \(tag)")
            XCTAssertTrue(h.cmd("SET 17 TRUTH 0").hasPrefix("OK"))
            XCTAssertTrue(h.cmd("SET 30 TRUTH 9").hasPrefix("OK"))
            let r30 = h.e.readRanks()[30]
            let L = Self.lanes(h.e)
            for s in [Spec(byRank: false, lo: 0, hi: 255, bytes: false), Spec(byRank: false, lo: 31, hi: 255, bytes: false),
                      Spec(byRank: true, lo: 0, hi: 7, bytes: false), Spec(byRank: true, lo: r30, hi: r30, bytes: false),
                      Spec(byRank: false, lo: 24, hi: 40, bytes: false)] {
                both(h, s, L, &t, "t4 Loom 9 at node 30, \(tag)")
            }
            full("t4 Loom 9 at node 30, \(tag)")
            XCTAssertTrue(h.cmd("SET 30 TRUTH 1").hasPrefix("OK"))
        }
        // A ternary node anywhere: trits.
        for c in ["TTABLE PRESET 0 TMIN 2", "SET 250 TTABLE 0", "SET 250 MODE TTABLE", "SET 250 TRUTH 1"] {
            XCTAssertTrue(h.cmd(c).hasPrefix("OK"), c)
        }
        full("t4 ternary node present")
        both(h, Spec(byRank: false, lo: 0, hi: 10, bytes: false), Self.lanes(h.e), &t, "t4 ternary graph, binary slice")
        // Reader sessions: the snapshot, not later writes; the width as live.
        func open() -> (String, Lanes) {
            let r = h.cmd("OPEN_READER")
            XCTAssertTrue(r.hasPrefix("OK OPEN_READER id="), r)
            let id = String(r.split(separator: " ")[2].dropFirst(3))
            return (id, Self.lanes(h.e))
        }
        let (rid, snap) = open()
        let t0 = h.e.readTruthStates()[0]
        XCTAssertTrue(h.cmd("SET 0 TRUTH \(1 - t0)").hasPrefix("OK"))
        full("t4 reader session (snapshot)", session: rid, lanes: snap)
        XCTAssertTrue(h.cmd("SET 250 MODE BINARY").hasPrefix("OK"))
        both(h, Spec(byRank: false, lo: 0, hi: 10, bytes: false), Self.lanes(h.e), &t, "t4 250 back to BINARY, live")
        let (rid2, snap2) = open()
        both(h, Spec(byRank: false, lo: 0, hi: 10, bytes: false), snap2, session: rid2, &t, "t4 reader after 250 BINARY")
        XCTAssertTrue(h.cmd("SET 250 MODE TTABLE").hasPrefix("OK"))
        let (rid3, snap3) = open()
        both(h, Spec(byRank: false, lo: 0, hi: 10, bytes: false), Self.lanes(h.e), &t, "t4 ternary again, live")
        both(h, Spec(byRank: false, lo: 0, hi: 10, bytes: false), snap3, session: rid3, &t, "t4 reader, ternary graph")
        XCTAssertTrue(h.cmd("SET 31 TRUTH 77").hasPrefix("OK"))
        let (rid4, snap4) = open()
        full("t4 reader, a Loom byte at 31", session: rid4, lanes: snap4)
        assertClean(t, "the verifier's t4_slice cases")
        XCTAssertGreaterThan(t.pathList, 0)
        XCTAssertGreaterThan(t.sessionCalls, 0)
    }

    // MARK: - Random lanes: trits, Loom bytes at random positions, rank shapes, stale lists

    func testG2_1RandomLanes() throws {
        var total = Tally()
        var lanesRun = 0, staleWrites = 0, seedsWithLists = 0, ternarySeeds = 0
        for seed in 0..<90 {
            var g = Rng(s: 0x6200_0000 &+ UInt64(seed) &* 0x9E37)
            let side = [8, 40, 64][seed % 3]
            let n = side * side
            let h = try freshH(side: side, maxRank: 16)
            var t = Tally()
            // Rank shapes.
            let shape = g.below(5)
            var ranks = [UInt64](repeating: 0, count: n)
            let block = max(1, n / (2 + g.below(12)))
            for i in 0..<n {
                switch shape {
                case 0: ranks[i] = UInt64(i / block)                                      // contiguous blocks
                case 1: ranks[i] = UInt64(g.below(3))                                     // few, interleaved
                case 2: ranks[i] = UInt64(g.below(14))                                    // many, interleaved
                case 3: ranks[i] = UInt64(i % (2 + g.below(5)))                           // a stride
                default: ranks[i] = g.below(10) < 8 ? UInt64(g.below(3)) : UInt64(g.below(n))   // sparse, wide
                }
            }
            Self.writeRanks(h, ranks)
            let tern = g.below(10) < 4
            var ternaryNodes = Set<Int>()
            if tern {
                ternarySeeds += 1
                XCTAssertTrue(h.cmd("TTABLE PRESET 0 TMIN 2").hasPrefix("OK"))
                var modes = [UInt8](repeating: 0, count: n)
                for i in 0..<n where g.below(10) < 2 { modes[i] = [1, 2][g.below(2)]; ternaryNodes.insert(i) }
                Self.writeTruth(h.e, [UInt8](repeating: 0, count: n))
                h.put(modes, count: modes.count, verb: .setModesBulk); XCTAssertTrue(h.cmd("SET_MODES_BULK").hasPrefix("OK"))
            }
            let lists = g.below(10) < 7
            if lists { try h.e.prepareRankLists(); seedsWithLists += 1 }
            for lane in 0..<5 {
                lanesRun += 1
                let kind = (lane + seed) % 5
                var truth = (0..<n).map { _ in UInt8(g.below(2)) }
                switch kind {
                case 1: for i in 0..<n where g.below(4) == 0 { truth[i] = 2 }
                case 2: for i in 0..<n where g.below(100) == 0 && !ternaryNodes.contains(i) { truth[i] = UInt8(3 + g.below(253)) }
                case 3:                                                                       // two Loom bytes
                    let a = g.below(n), b = min(n - 1, a + 1 + g.below([3, 9, 40, n][g.below(4)]))
                    for x in [a, b] where !ternaryNodes.contains(x) { truth[x] = UInt8(3 + g.below(253)) }
                case 4: truth[g.below(n)] = 2
                default: break
                }
                Self.writeTruth(h.e, truth)
                if lists && g.below(10) < 4 {                                                  // leave the lists stale
                    for _ in 0..<(1 + g.below(4)) {
                        let i = g.below(n), r = g.below(min(n, 16))
                        XCTAssertTrue(h.cmd("SET \(i) RANK \(r)").hasPrefix("OK"))
                        staleWrites += 1
                    }
                    XCTAssertTrue(h.e.rankTopologyDirty)
                }
                let L = Self.lanes(h.e)
                let present = Array(Set(L.ranks)).sorted()
                for _ in 0..<36 {
                    var s: Spec
                    switch g.below(12) {
                    case 0: s = Spec(byRank: false, lo: 0, hi: UInt64(n - 1), bytes: false)
                    case 1: let lo = g.below(n); s = Spec(byRank: false, lo: UInt64(lo), hi: UInt64(n - 1), bytes: false)
                    case 2: let i = g.below(n); s = Spec(byRank: false, lo: UInt64(i), hi: UInt64(i), bytes: false)
                    case 3, 4: let lo = g.below(n); s = Spec(byRank: false, lo: UInt64(lo), hi: UInt64(min(n - 1, lo + g.below(71))), bytes: false)
                    case 5, 6, 7: let r = present[g.below(present.count)]; s = Spec(byRank: true, lo: r, hi: r, bytes: false)
                    case 8: let a = present[g.below(present.count)], b = present[g.below(present.count)]
                        s = Spec(byRank: true, lo: min(a, b), hi: max(a, b), bytes: false)
                    case 9: let r = UInt64([n + g.below(100), g.below(20)][g.below(2)]); s = Spec(byRank: true, lo: r, hi: r, bytes: false)
                    case 10: s = g.below(2) == 0 ? Spec(byRank: false, lo: UInt64(g.below(n)), hi: UInt64(n + g.below(4)), bytes: false)
                                                 : Spec(byRank: g.below(2) == 0, lo: 9, hi: 3, bytes: false)
                    default: let lo = g.below(n), hi = g.below(n); s = Spec(byRank: false, lo: UInt64(min(lo, hi)), hi: UInt64(max(lo, hi)), bytes: false)
                    }
                    both(h, s, L, &t, "random seed \(seed) side \(side) shape \(shape) lane kind \(kind) lists \(lists)")
                }
            }
            total.add(t)
        }
        print("G2.1 random lanes: seeds 90 (sides 8/40/64), lanes \(lanesRun), seeds with lists \(seedsWithLists), "
              + "ternary seeds \(ternarySeeds), rank writes leaving the lists stale \(staleWrites)")
        assertClean(total, "random lanes")
        XCTAssertGreaterThan(total.pathList, 0)
        XCTAssertGreaterThan(total.refused, 0)
        XCTAssertGreaterThan(total.trits, 0)
        XCTAssertGreaterThan(staleWrites, 0)
    }

    // MARK: - Ranges of length 0…70 at every alignment; the same selections as one rank

    func testG2_1RangesOfEveryLengthAndAlignment() throws {
        let side = 16, n = side * side
        let h = try freshH(side: side, maxRank: 8)
        try h.e.prepareRankLists()
        var t = Tally()
        var g = Rng(s: 0x6270)
        for kind in 0..<3 {
            var truth = (0..<n).map { _ in UInt8(g.below(2)) }
            if kind == 1 { for i in 0..<n where g.below(3) == 0 { truth[i] = 2 } }
            if kind == 2 { for x in [37, 44, 45, 120, 121, 200, 255] { truth[x] = UInt8(3 + g.below(253)) } }   // two Loom bytes and more
            Self.writeTruth(h.e, truth)
            let label = ["bits", "trits", "Loom bytes"][kind]
            Self.writeRanks(h, [UInt64](repeating: 0, count: n))
            var L = Self.lanes(h.e)
            for lo in 0..<16 {
                both(h, Spec(byRank: false, lo: UInt64(lo + 1), hi: UInt64(lo), bytes: false), L, &t, "length 0, \(label)")
                for len in 1...70 {
                    both(h, Spec(byRank: false, lo: UInt64(lo), hi: UInt64(lo + len - 1), bytes: false), L, &t, "NODES, \(label)")
                }
            }
            for len in 1...70 {
                both(h, Spec(byRank: false, lo: UInt64(n - len), hi: UInt64(n - 1), bytes: false), L, &t, "NODES ending on the last id, \(label)")
            }
            // The same selections as rank 1 through its list: contiguous ids, then every other id.
            for stride in [1, 2] {
                for lo in 0..<16 {
                    for len in stride == 1 ? Array(1...70) : [1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 64, 70] {
                        var r = [UInt64](repeating: 0, count: n)
                        for j in 0..<len where lo + stride * j < n { r[lo + stride * j] = 1 }
                        Self.writeRanks(h, r)
                        L = Self.lanes(h.e)
                        both(h, Spec(byRank: true, lo: 1, hi: 1, bytes: false), L, &t, "RANK 1 stride \(stride), \(label)")
                    }
                }
                for len in 1...70 {
                    var r = [UInt64](repeating: 0, count: n)
                    for j in 0..<len { let x = n - 1 - stride * j; if x >= 0 { r[x] = 1 } }
                    Self.writeRanks(h, r)
                    L = Self.lanes(h.e)
                    both(h, Spec(byRank: true, lo: 1, hi: 1, bytes: false), L, &t, "RANK 1 ending on the last id stride \(stride), \(label)")
                }
            }
        }
        assertClean(t, "ranges of length 0…70 at every alignment")
        XCTAssertGreaterThan(t.pathList, 0)
        XCTAssertGreaterThan(t.pathRange, 0)
    }

    // MARK: - The random mixed graphs: ranks whose ids are not contiguous

    func testG2_1R3NonContiguousRanks() throws {
        var t = Tally()
        var nonContiguousRanks = 0
        for (side, seeds) in [(64, 4), (128, 2)] {
            for s in 0..<seeds {
                let seed = UInt64(0x7E13_6200) &+ UInt64(side) << 8 &+ UInt64(s)
                let gr = EngineF2DaemonTests.r3Mixed(side: side, seed: seed)
                let e = try EngineF2DaemonTests.r3Engine(gr, side: side, seed: seed)
                let h = H(e, side: side, maxRank: EngineF2DaemonTests.r3RankLevels)
                try e.prepareRankLists()
                let n = side * side
                var g = Rng(s: seed ^ 0x62)
                for variant in 0..<3 {
                    if variant == 1 {                     // every byte 0…2 (the graph is ternary: trits)
                        Self.writeTruth(e, gr.truth.map { $0 % 3 })
                    } else if variant == 2 {              // and three Loom bytes on binary nodes
                        var v = gr.truth.map { $0 % 3 }
                        let bin = (0..<n).filter { gr.mode[$0] == 0 }
                        for _ in 0..<3 { v[bin[g.below(bin.count)]] = UInt8(3 + g.below(253)) }
                        Self.writeTruth(e, v)
                    }
                    let L = Self.lanes(e)
                    let label = "R3 side \(side) seed \(s) variant \(variant)"
                    for r in 0..<UInt64(EngineF2DaemonTests.r3RankLevels) {
                        let ids = (0..<n).filter { L.ranks[$0] == r }
                        if let a = ids.first, let b = ids.last, b - a + 1 != ids.count { nonContiguousRanks += 1 }
                        both(h, Spec(byRank: true, lo: r, hi: r, bytes: false), L, &t, label)
                    }
                    for _ in 0..<12 {
                        let a = UInt64(g.below(16)), b = UInt64(g.below(16))
                        both(h, Spec(byRank: true, lo: min(a, b), hi: max(a, b), bytes: false), L, &t, label)
                        let lo = g.below(n), hi = min(n - 1, lo + g.below(300))
                        both(h, Spec(byRank: false, lo: UInt64(lo), hi: UInt64(hi), bytes: false), L, &t, label)
                    }
                }
            }
        }
        print("G2.1 R3: ranks whose ids are not contiguous \(nonContiguousRanks)")
        assertClean(t, "R3's graphs")
        XCTAssertGreaterThan(nonContiguousRanks, 0)
        XCTAssertGreaterThan(t.pathList, 0)
        XCTAssertGreaterThan(t.trits, 0)
    }

    // MARK: - Two Loom bytes: the first offender, by name (the controls' case)

    func testG2_1TwoLoomBytesNameTheFirstOffender() throws {
        let side = 16, n = side * side
        let h = try freshH(side: side, maxRank: 8)
        try h.e.prepareRankLists()
        var t = Tally()
        var named: [String] = []
        for (a, b) in [(40, 43), (46, 49), (40, 200), (3, 4), (8, 15), (0, 255), (63, 64), (250, 251)] {
            var truth = [UInt8](repeating: 1, count: n)
            truth[a] = 200; truth[b] = 77
            Self.writeTruth(h.e, truth)
            for stride in [1, 2] {
                Self.writeRanks(h, (0..<n).map { stride == 1 ? 0 : UInt64($0 % 2) })
                let L = Self.lanes(h.e)
                var specs = [Spec(byRank: false, lo: 0, hi: UInt64(n - 1), bytes: false),
                             Spec(byRank: false, lo: UInt64(max(0, a - 5)), hi: UInt64(n - 1), bytes: false),
                             Spec(byRank: false, lo: UInt64(a), hi: UInt64(b), bytes: false)]
                if stride == 1 { specs.append(Spec(byRank: true, lo: 0, hi: 0, bytes: false)) }
                else { specs.append(Spec(byRank: true, lo: UInt64(a % 2), hi: UInt64(a % 2), bytes: false)) }
                for s in specs {
                    slice(h, s, L, &t, "two Loom bytes at \(a), \(b), rank stride \(stride)")
                    let r = h.cmd(s.description)
                    if r.hasPrefix("ERROR bad_value") { named.append(r) }
                    XCTAssertTrue(r.hasPrefix("ERROR bad_value: TRUTH_SLICE node \(a) truth 200 "), "\(s): \(r)")
                    slice(h, s.with(bytes: true), L, &t, "two Loom bytes at \(a), \(b) (BYTES), rank stride \(stride)")
                }
            }
        }
        print("G2.1 two Loom bytes: \(named.count) refusals, every one naming the first")
        assertClean(t, "two Loom bytes")
    }

    // MARK: - BYTES against NODES' truth column, Loom codes included

    /// NODES AT RANK r's rows: (id, truth), in row order.
    func nodesAtRank(_ h: H, _ r: UInt64) -> [(Int, UInt8)] {
        let reply = h.cmd("NODES AT RANK \(r)")
        XCTAssertTrue(reply.hasPrefix("OK NODES"), reply)
        let count = Int(h.shm.bindMemory(to: UInt32.self, capacity: 2)[0])
        return (0..<count).map { i in
            let row = h.shm.advanced(by: 8 + i * 24)
            return (Int(row.load(as: UInt64.self)), row.load(fromByteOffset: 16, as: UInt8.self))
        }
    }

    func bytesPayload(_ h: H, _ line: String) -> (String, [UInt8]) {
        let r = h.cmd(line)
        let k = Int(h.shm.bindMemory(to: UInt32.self, capacity: 2)[0])
        guard r.hasPrefix("OK"), k <= h.n else { return (r, []) }
        return (r, Array(UnsafeBufferPointer(start: h.shm.advanced(by: 8).assumingMemoryBound(to: UInt8.self), count: k)))
    }

    func testG2_1BytesEqualNodesTruthColumn() throws {
        var cells = 0, ranksChecked = 0, loomBytes = 0, mismatches = 0
        func cell(_ h: H, _ label: String) {
            cells += 1
            let n = h.n
            let ranks = h.e.readRanks()
            var column = [UInt8](repeating: 0, count: n), seen = 0
            for r in Set(ranks).sorted() {
                let rows = nodesAtRank(h, r)
                for (id, v) in rows { column[id] = v; seen += 1; if v >= 3 { loomBytes += 1 } }
                let (reply, got) = bytesPayload(h, "TRUTH_SLICE RANK \(r)-\(r) BYTES")
                XCTAssertTrue(reply.hasPrefix("OK TRUTH_SLICE nodes=\(rows.count) format=bytes bits_per_node=8 shm_bytes=\(rows.count) "), reply)
                XCTAssertEqual(h.shm.bindMemory(to: UInt32.self, capacity: 2)[1], 8)
                if got != rows.map({ $0.1 }) { mismatches += 1 }
                XCTAssertEqual(got, rows.map { $0.1 }, "\(label) rank \(r): \(reply)")
                ranksChecked += 1
            }
            XCTAssertEqual(seen, n, "\(label): NODES AT RANK covers every node")
            let (whole, got) = bytesPayload(h, "TRUTH_SLICE NODES 0-\(n - 1) BYTES")
            if got != column { mismatches += 1 }
            XCTAssertEqual(got, column, "\(label): \(whole)")
            let (_, sub) = bytesPayload(h, "TRUTH_SLICE NODES 37-\(n / 2) BYTES")
            XCTAssertEqual(sub, Array(column[37...(n / 2)]), label)
        }
        for (side, seed, tern) in [(16, UInt64(0xE41), false), (24, 0xE42, true), (32, 0xE43, true)] {
            let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                    state: DagDBState(width: side, height: side), maxRank: 8)
            try EngineE1DaemonTests.buildGraph(e, seed: seed, ternary: tern)
            let h = H(e, side: side, maxRank: 8)
            XCTAssertTrue(h.cmd("TICK 2").hasPrefix("OK TICK"))
            XCTAssertTrue(h.cmd("SET 7 TRUTH 201").hasPrefix("OK") || tern)
            cell(h, "E1 side \(side)")
        }
        let gr = EngineF2DaemonTests.r3Mixed(side: 64, seed: 0x7E13_62B0)
        let e = try EngineF2DaemonTests.r3Engine(gr, side: 64, seed: 0x7E13_62B0)
        let h = H(e, side: 64, maxRank: EngineF2DaemonTests.r3RankLevels)
        try e.prepareRankLists()
        cell(h, "R3 side 64 (Loom-rich)")
        print("G2.1 BYTES == NODES' truth column: cells \(cells), ranks \(ranksChecked), Loom bytes carried \(loomBytes), mismatches \(mismatches)")
        XCTAssertGreaterThan(loomBytes, 0)
        XCTAssertEqual(mismatches, 0)
    }

    // MARK: - Grammar, sessions, the allow-list

    func testG2_1GrammarSessionsAndAllowList() throws {
        let h = try freshH(side: 4, maxRank: 8)
        XCTAssertTrue(h.cmd("SET 5 TRUTH 200").hasPrefix("OK"))
        XCTAssertEqual(h.cmd("TRUTH_SLICE NODES 0-15 BYTES"),
                       "OK TRUTH_SLICE nodes=16 format=bytes bits_per_node=8 shm_bytes=16 first=0 last=15")
        XCTAssertEqual(h.cmd("truth_slice nodes 4-6 bytes"),
                       "OK TRUTH_SLICE nodes=3 format=bytes bits_per_node=8 shm_bytes=3 first=4 last=6")
        XCTAssertEqual(Array(UnsafeBufferPointer(start: h.shm.advanced(by: 8).assumingMemoryBound(to: UInt8.self), count: 3)), [0, 200, 0])
        XCTAssertEqual(h.cmd("TRUTH_SLICE RANK 0-0 BYTES"),
                       "OK TRUTH_SLICE nodes=16 format=bytes bits_per_node=8 shm_bytes=16 first=0 last=15")
        XCTAssertEqual(h.cmd("TRUTH_SLICE RANK 5-9 BYTES"),
                       "OK TRUTH_SLICE nodes=0 format=bytes bits_per_node=8 shm_bytes=0 first=- last=-")
        XCTAssertEqual(h.cmd("TRUTH_SLICE NODES 0-16 BYTES"), "ERROR out_of_range: node 16 not in 0..<16")
        XCTAssertEqual(h.cmd("TRUTH_SLICE NODES 9-3 BYTES"), "ERROR out_of_range: range 9-3 is empty (lo > hi)")
        XCTAssertEqual(h.cmd("TRUTH_SLICE RANK 9-3 BYTES"), "ERROR out_of_range: range 9-3 is empty (lo > hi)")
        for l in ["TRUTH_SLICE NODES 0-3 BYTES BYTES", "TRUTH_SLICE NODES 0-3 BITS", "TRUTH_SLICE RANK 0-3 TRITS",
                  "TRUTH_SLICE BYTES 0-3", "TRUTH_SLICE NODES BYTES 0-3", "TRUTH_SLICE NODES 0-3 BYTE"] {
            XCTAssertEqual(h.cmd(l), "ERROR unknown_command: \(Reply.quoted(l))")
        }
        // Reader sessions take BYTES too.
        let open = h.cmd("OPEN_READER")
        let id = String(open.split(separator: " ")[2].dropFirst(3))
        XCTAssertTrue(h.cmd("SET 6 TRUTH 1").hasPrefix("OK"))
        XCTAssertEqual(h.cmd("READER \(id) TRUTH_SLICE NODES 4-6 BYTES"),
                       "OK TRUTH_SLICE session=\(id) nodes=3 format=bytes bits_per_node=8 shm_bytes=3 first=4 last=6")
        XCTAssertEqual(Array(UnsafeBufferPointer(start: h.shm.advanced(by: 8).assumingMemoryBound(to: UInt8.self), count: 3)), [0, 200, 0])
        // The allow-list: a slice, either form, keeps the DAG verdict (no rank-order re-check on the next TICK).
        XCTAssertTrue(h.cmd("SET 5 TRUTH 0").hasPrefix("OK"))
        XCTAssertTrue(h.cmd("TICK 1").hasPrefix("OK TICK"))
        let checks = h.handler.dagVerdictCheckCount
        for l in ["TRUTH_SLICE NODES 0-15", "TRUTH_SLICE RANK 0-0", "TRUTH_SLICE NODES 0-15 BYTES", "TRUTH_SLICE RANK 0-0 BYTES"] {
            XCTAssertTrue(h.cmd(l).hasPrefix("OK TRUTH_SLICE"), l)
            XCTAssertTrue(h.cmd("TICK 1").hasPrefix("OK TICK"))
        }
        XCTAssertEqual(h.handler.dagVerdictCheckCount, checks)
        // The path seam: after a TICK the lists exist and RANK r-r walks rank r's list.
        XCTAssertTrue(h.cmd("TRUTH_SLICE RANK 0-0").hasPrefix("OK"))
        XCTAssertEqual(h.handler.lastTruthSlicePath, "rankList")
        XCTAssertTrue(h.cmd("TRUTH_SLICE NODES 0-0").hasPrefix("OK"))
        XCTAssertEqual(h.handler.lastTruthSlicePath, "range")
        XCTAssertTrue(h.cmd("TRUTH_SLICE RANK 0-1").hasPrefix("OK"))
        XCTAssertEqual(h.handler.lastTruthSlicePath, "e2Loop")
        // A rank write leaves the lists stale; the next RANK r-r sees the new member.
        XCTAssertTrue(h.cmd("SET 3 RANK 1").hasPrefix("OK"))
        XCTAssertEqual(h.cmd("TRUTH_SLICE RANK 1-1 BYTES"),
                       "OK TRUTH_SLICE nodes=1 format=bytes bits_per_node=8 shm_bytes=1 first=3 last=3")
        XCTAssertEqual(h.handler.lastTruthSlicePath, "rankList")
        XCTAssertEqual(h.cmd("TRUTH_SLICE RANK 0-0 BYTES"),
                       "OK TRUTH_SLICE nodes=15 format=bytes bits_per_node=8 shm_bytes=15 first=0 last=15")
    }
}
