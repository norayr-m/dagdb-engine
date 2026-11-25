import XCTest
import CryptoKit
@testable import DagDB
@testable import DagDBDaemonKit

/// BACKUP COMPACT refuses exactly what BACKUP RESTORE refuses, and RESTORE's
/// two isRegister-segment refusals get committed tests.
///
/// Crafted cells of the slot model, in-process: five worlds
/// (sides 16, 16, 32, 32, 64; binary, ternary, binary, ternary, binary), a
/// chain of one diff each (BACKUP INIT, SET <n> TRUTH 1, BACKUP APPEND),
/// and in its isRegister segment the byte of one non-register node flipped
/// (a node with a live slot; a slot-free node, ternary in the ternary
/// worlds), the segment's length and the sidecar fixed: ten cells. RESTORE
/// refuses each by its tip check's words (a slot's range, a register flag
/// against the list); COMPACT refuses it by the same words under
/// its own verb, every chain file byte-identical; RESTORE afterwards gives
/// the same refusal; the live state never changes.
///
/// Also RESTORE's two tip-check refusals and COMPACT's same refusals, each by
/// its exact reply: a register flag no list entry carries (on a slot-free
/// node and on a node with a live slot), and a slot whose source is out of
/// range (at the node count and five past it). The untouched chain restores
/// and compacts.
///
/// The file uses only verbs and library calls that exist before COMPACT
/// gained these refusals, so it runs on the older code (the red run) and on
/// the new (the green run).
extension EngineE7DaemonTests {

    // MARK: - Crafting

    /// The ten fixed XOR segments' sizes, in file order (rank, truth, type,
    /// lut6Low, lut6High, neighbours, isRegister, edgeWeights, activation,
    /// nodeValue).
    static func e7fSegmentSizes(_ n: Int) -> [Int] { [8 * n, n, n, 4 * n, 4 * n, 24 * n, n, 24 * n, 2 * n, 4 * n] }

    /// A copy of the chain `src` at `dst` whose 00001.diff has fixed segment
    /// `seg` decoded, edited and re-encoded, its u32 length and the diff's
    /// sha256 sidecar fixed.
    func e7fCraft(_ src: String, _ dst: String, n: Int, seg: Int, _ edit: (inout [UInt8]) -> Void) throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: dst)
        try fm.copyItem(atPath: src, toPath: dst)
        let path = dst + "/00001.diff"
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        func u32(_ o: Int) -> Int { Int(raw[o..<(o + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) }
        var off = 16
        var segs: [(Int, Int)] = []
        for _ in 0..<10 { let ln = u32(off); segs.append((off, ln)); off += 4 + ln }
        let (o, ln) = segs[seg]
        let size = Self.e7fSegmentSizes(n)[seg]
        var x = [UInt8](DagDBSnapshot.zlibDecompress(raw.subdata(in: (o + 4)..<(o + 4 + ln)), expectedSize: size))
        XCTAssertEqual(x.count, size, "segment \(seg) decodes to its size")
        edit(&x)
        let comp = DagDBSnapshot.zlibCompress(Data(x))
        var out = raw.subdata(in: 0..<o)
        var len = UInt32(comp.count).littleEndian
        out.append(Data(bytes: &len, count: 4))
        out.append(comp)
        out.append(raw.subdata(in: (o + 4 + ln)..<raw.count))
        try out.write(to: URL(fileURLWithPath: path))
        let hex = SHA256.hash(data: out).map { String(format: "%02x", $0) }.joined()
        try Data((hex + "\n").utf8).write(to: URL(fileURLWithPath: path + ".sha256"))
    }

    /// The edit making the tip's slot `k` of node `d` hold `v`, given what the
    /// base holds there (`prev`): the segment is tip XOR previous.
    static func e7fSetSlot(_ x: inout [UInt8], d: Int, k: Int, prev: Int32, to v: Int32) {
        let cur = x[((d * 6 + k) * 4)..<((d * 6 + k) * 4 + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        var w = (cur ^ UInt32(bitPattern: prev) ^ UInt32(bitPattern: v)).littleEndian
        withUnsafeBytes(of: &w) { b in for i in 0..<4 { x[(d * 6 + k) * 4 + i] = b[i] } }
    }

    static func e7fFlagWords(_ node: Int) -> String {
        "register flags: node \(node) is flagged a register but no back edge in the chain's list ends at it (a register nobody latches)"
    }

    /// RESTORE's reply and COMPACT's (the same words under COMPACT's verb;
    /// RESTORE's `nothing restored` is COMPACT's `nothing written`).
    static func e7fReplies(_ words: String) -> (restore: String, compact: String) {
        ("ERROR io: backup_restore: invalid diff: \(words); nothing restored",
         "ERROR io: backup_compact: invalid diff: \(words); nothing written")
    }

    /// One crafted chain against both verbs: RESTORE refused by `want.restore`
    /// with the live state unchanged; COMPACT refused by `want.compact` with
    /// every chain file byte-identical and the live state unchanged; RESTORE
    /// again gives the first refusal. Returns whether every check held.
    @discardableResult
    func e7fBothRefuse(_ f: HandlerFixture, _ dir: String, want: (restore: String, compact: String),
                       label: String) throws -> Bool {
        let live = try observe(f)
        let restore = f.handler.handle("BACKUP RESTORE \(dir)")
        let liveR = try observe(f)
        let before = files(dir)
        let compact = f.handler.handle("BACKUP COMPACT \(dir)")
        let after = files(dir)
        let liveC = try observe(f)
        let again = f.handler.handle("BACKUP RESTORE \(dir)")
        let liveA = try observe(f)
        XCTAssertEqual(restore, want.restore, "\(label): RESTORE")
        XCTAssertEqual(diff(live, liveR), [], "\(label): RESTORE changed the live state")
        XCTAssertEqual(compact, want.compact, "\(label): COMPACT")
        XCTAssertEqual(after.keys.sorted(), before.keys.sorted(), "\(label): COMPACT changed the chain's file list")
        XCTAssertTrue(after == before, "\(label): COMPACT changed a chain file")
        XCTAssertEqual(diff(live, liveC), [], "\(label): COMPACT changed the live state")
        XCTAssertEqual(again, restore, "\(label): RESTORE after COMPACT")
        XCTAssertEqual(diff(live, liveA), [], "\(label): RESTORE after COMPACT changed the live state")
        let held = restore == want.restore && compact == want.compact && after == before
            && again == restore && diff(live, liveR).isEmpty && diff(live, liveC).isEmpty && diff(live, liveA).isEmpty
        print("E7F \(label): \(held ? "held" : "FAILED") — restore '\(restore)' | compact '\(compact)' | chain_byte_identical=\(after == before) | restore_after '\(again)'")
        return held
    }

    /// A node of `gr` that is not a register, binary, with a live slot.
    static func e7fSlottedNode(_ gr: Graph) -> Int {
        let tern = Set(gr.modes.map(\.0))
        return (0..<gr.n).first { i in !gr.isReg[i] && !tern.contains(i) && (0..<6).contains { gr.nb[i * 6 + $0] >= 0 } }!
    }

    /// A node of `gr` that is not a register, with every slot empty; ternary
    /// when `ternary` and the graph has one.
    static func e7fSlotFreeNode(_ gr: Graph, ternary: Bool) -> Int {
        let tern = Set(gr.modes.map(\.0))
        let free = (0..<gr.n).filter { i in !gr.isReg[i] && (0..<6).allSatisfy { gr.nb[i * 6 + $0] < 0 } }
        if ternary, let t = free.first(where: { tern.contains($0) }) { return t }
        return free.first { !tern.contains($0) }!
    }

    /// The chain the cells copy: INIT, one truth write, APPEND.
    func e7fChain(_ f: HandlerFixture, _ dir: String, touch: Int) {
        ok(f, "BACKUP INIT \(dir)")
        ok(f, "SET \(touch) TRUTH 1")
        ok(f, "BACKUP APPEND \(dir)")
    }

    // MARK: - The crafted flag cells, refused by RESTORE and COMPACT

    func testE7F1VerifierFlagCellsRefusedByRestoreAndCompact() throws {
        let worlds: [(Int, Bool, Set<Shape>)] = [(16, false, []), (16, true, []), (32, false, [.s1, .s2, .s3]),
                                                 (32, true, [.s1, .s2, .s3]), (64, false, [])]
        var cells = 0, held = 0
        for (w, (side, ternary, shapes)) in worlds.enumerated() {
            let gr = Self.slotGraph(side: side, seed: 0xE7F1_0000 + UInt64(w), shapes: shapes, ternary: ternary)
            let f = try daemon(gr)
            let slotted = Self.e7fSlottedNode(gr), free = Self.e7fSlotFreeNode(gr, ternary: ternary)
            let ch = tmp + "e7f1_\(w)_ch"
            e7fChain(f, ch, touch: slotted)
            for (cell, node) in [("flag_on_slotted", slotted), ("flag_on_slotfree", free)] {
                let c = tmp + "e7f1_\(w)_\(cell)"
                try e7fCraft(ch, c, n: gr.n, seg: 6) { $0[node] ^= 1 }
                let ternaryNode = gr.modes.contains { $0.0 == node }
                if try e7fBothRefuse(f, c, want: Self.e7fReplies(Self.e7fFlagWords(node)),
                                     label: "E7F.1 \(gr.name) \(cell) node \(node)\(ternaryNode ? " (ternary)" : "")") {
                    held += 1
                }
                cells += 1
            }
            // The untouched chain restores and compacts.
            XCTAssertTrue(f.handler.handle("BACKUP RESTORE \(ch)").hasPrefix("OK BACKUP_RESTORE diffs_replayed=1"))
            XCTAssertTrue(f.handler.handle("BACKUP COMPACT \(ch)").hasPrefix("OK BACKUP_COMPACT prior_diffs=1"))
            XCTAssertTrue(f.handler.handle("BACKUP RESTORE \(ch)").hasPrefix("OK BACKUP_RESTORE diffs_replayed=0"))
        }
        XCTAssertEqual(cells, 10)
        XCTAssertEqual(held, 10)
        print("E7F.1 cells=\(cells) refused_by_both_with_restore_words_and_chain_byte_identical=\(held)")
    }

    // MARK: - RESTORE's two tip-check refusals, each by its exact reply

    func testE7F2RestoreAndCompactRefuseARegisterFlagNoListEntryCarries() throws {
        let gr = Self.slotGraph(side: 8, seed: 0xE7F2_0001, shapes: [], ternary: false)
        let f = try daemon(gr)
        let slotted = Self.e7fSlottedNode(gr), free = Self.e7fSlotFreeNode(gr, ternary: false)
        let ch = tmp + "e7f2_flag_ch"
        e7fChain(f, ch, touch: slotted)
        var held = 0
        for (cell, node) in [("slot-free node", free), ("node with a live slot", slotted)] {
            let c = tmp + "e7f2_flag_\(node)"
            try e7fCraft(ch, c, n: gr.n, seg: 6) { $0[node] ^= 1 }
            if try e7fBothRefuse(f, c, want: Self.e7fReplies(Self.e7fFlagWords(node)),
                                 label: "E7F.2 register flag, no list entry, on a \(cell) (\(node))") { held += 1 }
        }
        XCTAssertEqual(held, 2)
        XCTAssertTrue(f.handler.handle("BACKUP RESTORE \(ch)").hasPrefix("OK BACKUP_RESTORE diffs_replayed=1"))
        XCTAssertTrue(f.handler.handle("BACKUP COMPACT \(ch)").hasPrefix("OK BACKUP_COMPACT prior_diffs=1"))
    }

    func testE7F2RestoreAndCompactRefuseAnOutOfRangeSlot() throws {
        let gr = Self.slotGraph(side: 8, seed: 0xE7F2_0002, shapes: [], ternary: false)
        let n = gr.n
        let f = try daemon(gr)
        let slotted = Self.e7fSlottedNode(gr), free = Self.e7fSlotFreeNode(gr, ternary: false)
        let ch = tmp + "e7f2_range_ch"
        e7fChain(f, ch, touch: slotted)
        var held = 0
        for (d, k, src) in [(free, 0, Int32(n)), (slotted, 5, Int32(n + 5))] {
            let c = tmp + "e7f2_range_\(d)_\(src)"
            try e7fCraft(ch, c, n: n, seg: 5) { Self.e7fSetSlot(&$0, d: d, k: k, prev: gr.nb[d * 6 + k], to: src) }
            let words = "validation: node \(d) slot \(k): src \(src) out of range"
            if try e7fBothRefuse(f, c, want: Self.e7fReplies(words),
                                 label: "E7F.2 slot out of range: node \(d) slot \(k) src \(src)") { held += 1 }
        }
        XCTAssertEqual(held, 2)
        // The boundary, in range: a slot whose source is the last node restores and compacts.
        let c = tmp + "e7f2_range_last"
        try e7fCraft(ch, c, n: n, seg: 5) { Self.e7fSetSlot(&$0, d: free, k: 0, prev: gr.nb[free * 6], to: Int32(n - 1)) }
        XCTAssertTrue(f.handler.handle("BACKUP RESTORE \(c)").hasPrefix("OK BACKUP_RESTORE diffs_replayed=1"))
        XCTAssertTrue(f.handler.handle("BACKUP COMPACT \(c)").hasPrefix("OK BACKUP_COMPACT prior_diffs=1"))
        XCTAssertTrue(f.handler.handle("BACKUP RESTORE \(ch)").hasPrefix("OK BACKUP_RESTORE diffs_replayed=1"))
    }
}
