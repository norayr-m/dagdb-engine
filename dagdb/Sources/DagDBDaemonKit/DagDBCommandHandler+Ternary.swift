/// DagDBCommandHandler+Ternary — the verbs of the native ternary tick.
///
/// Every mutating verb follows the
/// handler's order: validate (refusal by name, nothing written), log
/// (WAL v3; a log that will not take the record leaves the engine
/// unchanged), apply.

import Foundation
import DagDB

extension DagDBCommandHandler {

    /// The refusal line for a ternary rule.
    func ternaryRefusal(_ why: String) -> String { "ERROR bad_value: ternary: \(why)" }

    static let kindWords: [String: UInt8] = ["BINARY": 0, "TTABLE": 1, "TTHRESH": 2]
    static func kindWord(_ m: UInt8) -> String {
        switch m & TernaryReference.kindMask { case 1: return "TTABLE"; case 2: return "TTHRESH"; default: return "BINARY" }
    }

    /// Why giving node `i` the mode byte `m` is refused, against the live
    /// state, or nil. The rules are
    /// `TernaryReference.modeWriteRefusal`'s (one checker,
    /// shared with WAL replay; the live context picks the reply's words).
    func modeWriteRefusal(_ e: DagDBEngine, node i: Int, mode m: UInt8) -> String? {
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)[i]
        return TernaryReference.modeWriteRefusal(node: i, mode: m, truth: truth,
                                                 isRegister: e.isRegister(node: UInt32(i)),
                                                 ttableId: e.ternaryLaneView?.ttableId[i] ?? 0, tableCount: e.ttableCount,
                                                 context: .live)
    }

    /// Parse 729 characters of '-', '0', '+' into table bytes, or the
    /// refusal's reason.
    static func parseTable(_ s: String) -> (table: [UInt8]?, why: String?) {
        guard s.count == TernaryReference.tableSize else {
            return (nil, "a table is \(TernaryReference.tableSize) characters of - 0 +, got \(s.count)")
        }
        var out = [UInt8](); out.reserveCapacity(TernaryReference.tableSize)
        for (i, c) in s.enumerated() {
            guard let b = TernaryReference.tableByte(ofChar: c) else {
                return (nil, "table character \(i) is \(Reply.quoted(String(c))); use - 0 +")
            }
            out.append(b)
        }
        return (out, nil)
    }

    static func tableString(_ bytes: [UInt8]) -> String {
        String(bytes.map { TernaryReference.char(ofTableByte: $0) })
    }

    /// The ternary fields GRAPH INFO appends.
    func ternaryInfo(_ e: DagDBEngine, nodeCount n: Int) -> String {
        let t = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: max(n, 1))
        var tern = 0, minus = 0, zero = 0, plus = 0
        // Unallocated lanes are all BINARY — nothing to count, nothing to allocate.
        guard let m = e.ternaryLaneView?.mode else { return " ternary_nodes=0 trits=-:0 0:0 +:0" }
        for i in 0..<n where m[i] != 0 {
            tern += 1
            switch TernaryReference.trit(ofByte: t[i]) { case -1: minus += 1; case 1: plus += 1; default: zero += 1 }
        }
        return " ternary_nodes=\(tern) trits=-:\(minus) 0:\(zero) +:\(plus)"
    }

    /// The native ternary verbs. Returns nil for any other command.
    func handleTernary(_ cmd: DSLCommand) -> String? {
        let e = engine
        switch cmd {
        case .setMode(let node, let kind, let noskip):
            if let r = checkRange("node", node, upTo: nodeCount) { return r }
            guard let k = Self.kindWords[kind] else {
                return ternaryRefusal("mode kind \(Reply.quoted(kind)) — use BINARY, TTABLE or TTHRESH")
            }
            let m = k | (noskip ? TernaryReference.noskipBit : 0)
            if let why = modeWriteRefusal(e, node: node, mode: m) { return ternaryRefusal(why) }
            if m != 0, let r = alloc1dAdmit("SET", [alloc1dLanesItem]) { return r }
            if let wal = walAppender {
                do { _ = try wal.setMode(node: UInt32(node), mode: m) }
                catch { return walAppendError(error) }
            }
            e.setNodeMode(node, m)
            return "OK SET node=\(node) mode=\(Self.kindWord(m)) noskip=\(noskip ? 1 : 0)"

        case .setTTableId(let node, let tid):
            if let r = checkRange("node", node, upTo: nodeCount) { return r }
            guard tid >= 0 && tid < e.ttableCount else {
                return ternaryRefusal("ttableId \(tid) is not below the library size \(e.ttableCount)")
            }
            if tid != 0, let r = alloc1dAdmit("SET", [alloc1dLanesItem]) { return r }
            if let wal = walAppender {
                do { _ = try wal.setTTableId(node: UInt32(node), tid: UInt16(tid)) }
                catch { return walAppendError(error) }
            }
            if tid != 0 || e.ternaryLanesAllocated { e.ttableIdPtr[node] = UInt16(tid) }   // 0 is already there
            return "OK SET node=\(node) ttable=\(tid)"

        case .setThresh(let node, let lo, let hi):
            if let r = checkRange("node", node, upTo: nodeCount) { return r }
            if let why = TernaryReference.thresholdRefusal(lo: lo, hi: hi) { return ternaryRefusal(why) }
            if lo.bitPattern != 0 || hi.bitPattern != 0, let r = alloc1dAdmit("SET", [alloc1dLanesItem]) { return r }
            if let wal = walAppender {
                do { _ = try wal.setThresh(node: UInt32(node), lo: lo, hi: hi) }
                catch { return walAppendError(error) }
            }
            if lo.bitPattern != 0 || hi.bitPattern != 0 || e.ternaryLanesAllocated {   // +0.0 is already there
                e.thrLoPtr[node] = lo
                e.thrHiPtr[node] = hi
            }
            return "OK SET node=\(node) thresh=\(lo),\(hi)"

        case .setTrit(let node, let trit):
            if let r = checkRange("node", node, upTo: nodeCount) { return r }
            guard (-1...1).contains(trit) else { return ternaryRefusal("trit \(trit) — use -1, 0 or 1") }
            if let wal = walAppender {
                do { _ = try wal.setTrit(node: UInt32(node), trit: Int8(trit)) }
                catch { return walAppendError(error) }
            }
            e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)[node] =
                TernaryReference.byte(ofTrit: trit)
            truthRankIndex.markDirty()
            return "OK SET node=\(node) trit=\(trit)"

        case .getTrit(let node):
            if let r = checkRange("node", node, upTo: nodeCount) { return r }
            let b = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)[node]
            return "OK GET node=\(node) trit=\(TernaryReference.trit(ofByte: b))"

        case .ttableDefine(let tid, let text):
            let parsed = Self.parseTable(text)
            guard let table = parsed.table else { return ternaryRefusal(parsed.why ?? "bad table") }
            if let why = table.withUnsafeBufferPointer({ e.tableWriteRefusal(first: tid, count: 1, bytes: $0) }) {
                return ternaryRefusal(why)
            }
            if let r = admitTableGrowth("TTABLE DEFINE", engine: e, tables: tid + 1) { return r }
            if let r = reserveTablesBeforeWAL(e, tables: tid + 1) { return r }
            if let wal = walAppender {
                do { _ = try wal.ttableDefine(tid: UInt32(tid), table: table) }
                catch { return walAppendError(error) }
            }
            do { try e.writeTables(first: tid, bytes: table) } catch { return ternaryRefusal(Reply.errorWords(error)) }
            return "OK TTABLE DEFINE tid=\(tid) tables=\(e.ttableCount)"

        case .ttablePreset(let tid, let name, let k):
            guard let p = TernaryReference.Preset(rawValue: name) else {
                return ternaryRefusal("preset \(Reply.quoted(name)) — use " +
                                      TernaryReference.Preset.allCases.map { $0.rawValue }.joined(separator: " "))
            }
            let table: [UInt8]
            do { table = try TernaryReference.presetTable(p, k: k) } catch { return ternaryRefusal(Reply.errorWords(error)) }
            if let why = table.withUnsafeBufferPointer({ e.tableWriteRefusal(first: tid, count: 1, bytes: $0) }) {
                return ternaryRefusal(why)
            }
            if let r = admitTableGrowth("TTABLE PRESET", engine: e, tables: tid + 1) { return r }
            if let r = reserveTablesBeforeWAL(e, tables: tid + 1) { return r }
            if let wal = walAppender {
                do { _ = try wal.ttablePreset(tid: UInt32(tid), preset: p, k: UInt8(k)) }
                catch { return walAppendError(error) }
            }
            do { try e.writeTables(first: tid, bytes: table) } catch { return ternaryRefusal(Reply.errorWords(error)) }
            return "OK TTABLE PRESET tid=\(tid) name=\(p.rawValue) k=\(k) tables=\(e.ttableCount)"

        case .ttableGet(let tid):
            guard let t = e.tableBytes(tid) else {
                return "ERROR out_of_range: tid \(tid) not in 0..<\(e.ttableCount)"
            }
            return "OK TTABLE GET tid=\(tid) table=\(Self.tableString(t))"

        case .setModesBulk:
            if let r = checkShmFits(rows: nodeCount, rowSize: 1) { return r }
            if let r = shm1FrameRefusal(.setModesBulk, count: nodeCount) { return r }
            let src = shmBase.advanced(by: 8).bindMemory(to: UInt8.self, capacity: max(nodeCount, 1))
            // The WHOLE vector is checked before one byte is written.
            var ternary = 0
            for i in 0..<nodeCount {
                if src[i] != 0 { ternary += 1 }
                if src[i] == 0 { continue }
                if let why = modeWriteRefusal(e, node: i, mode: src[i]) { return ternaryRefusal(why) }
            }
            if ternary > 0, let r = alloc1dAdmit("SET_MODES_BULK", [alloc1dLanesItem]) { return r }
            if let wal = walAppender {
                do { _ = try wal.setModesBulk(src, count: nodeCount) }
                catch { return walAppendError(error) }
            }
            e.replaceModeLane(from: src)
            return "OK SET_MODES_BULK nodes=\(nodeCount) ternary=\(ternary)"

        case .setTTableIdsBulk:
            if let r = checkShmFits(rows: nodeCount, rowSize: 2) { return r }
            if let r = shm1FrameRefusal(.setTTableIdsBulk, count: nodeCount) { return r }
            let src = shmBase.advanced(by: 8).bindMemory(to: UInt16.self, capacity: max(nodeCount, 1))
            for i in 0..<nodeCount where Int(src[i]) >= e.ttableCount {
                return ternaryRefusal("node \(i): ttableId \(src[i]) is not below the library size \(e.ttableCount)")
            }
            if !e.ternaryLanesAllocated, (0..<nodeCount).contains(where: { src[$0] != 0 }),
               let r = alloc1dAdmit("SET_TTABLE_IDS_BULK", [alloc1dLanesItem]) { return r }
            if let wal = walAppender {
                do { _ = try wal.setTTableIdsBulk(src, count: nodeCount) }
                catch { return walAppendError(error) }
            }
            if e.ternaryLanesAllocated || (0..<nodeCount).contains(where: { src[$0] != 0 }) {
                memcpy(e.ttableIdBuf.contents(), src, nodeCount * 2)
            }
            return "OK SET_TTABLE_IDS_BULK nodes=\(nodeCount)"

        case .setThreshBulk:
            if let r = checkShmFits(rows: nodeCount, rowSize: 8) { return r }
            if let r = shm1FrameRefusal(.setThreshBulk, count: nodeCount) { return r }   // N (lo, hi) pairs
            let src = shmBase.advanced(by: 8).bindMemory(to: Float.self, capacity: max(2 * nodeCount, 1))
            for i in 0..<nodeCount {
                if let why = TernaryReference.thresholdRefusal(lo: src[2 * i], hi: src[2 * i + 1]) {
                    return ternaryRefusal("node \(i): \(why)")
                }
            }
            if !e.ternaryLanesAllocated, (0..<(2 * nodeCount)).contains(where: { src[$0].bitPattern != 0 }),
               let r = alloc1dAdmit("SET_THRESH_BULK", [alloc1dLanesItem]) { return r }
            if let wal = walAppender {
                do { _ = try wal.setThreshBulk(src, count: nodeCount) }
                catch { return walAppendError(error) }
            }
            if e.ternaryLanesAllocated || (0..<(2 * nodeCount)).contains(where: { src[$0].bitPattern != 0 }) {
                let lo = e.thrLoPtr, hi = e.thrHiPtr
                for i in 0..<nodeCount { lo[i] = src[2 * i]; hi[i] = src[2 * i + 1] }
            }
            return "OK SET_THRESH_BULK nodes=\(nodeCount)"

        case .ttableBulk(let first, let count):
            guard count >= 1 && count <= TernaryReference.maxTables else {
                return ternaryRefusal("table count \(count) not in 1...\(TernaryReference.maxTables)")
            }
            guard let bytes = checkedProduct(count, TernaryReference.tableSize) else {
                return overflowRefusal("TTABLE_BULK", "count=\(count)")
            }
            if let r = checkShmFits(rows: bytes, rowSize: 1) { return r }
            // The two argument checks of
            // `tableWriteRefusal` run here, in its words, before the mark check,
            // so every pre-read refusal answers as before. The library function
            // is unchanged and still runs them for its other callers.
            if first < 0 || first > e.ttableCount {
                return ternaryRefusal("table id \(first) leaves a gap: the library holds \(e.ttableCount) table(s), "
                                      + "ids 0..<\(e.ttableCount); define id \(e.ttableCount) next")
            }
            if first + count > TernaryReference.maxTables {
                return ternaryRefusal("tables \(first)..<\(first + count) exceed the library's \(TernaryReference.maxTables)")
            }
            if let r = shm1FrameRefusal(.ttableBulk, count: count) { return r }   // count tables of 729 bytes
            let src = UnsafeBufferPointer(
                start: shmBase.advanced(by: 8).bindMemory(to: UInt8.self, capacity: bytes), count: bytes)
            if let why = e.tableWriteRefusal(first: first, count: count, bytes: src) { return ternaryRefusal(why) }
            if let r = admitTableGrowth("TTABLE_BULK", engine: e, tables: first + count) { return r }
            if let r = reserveTablesBeforeWAL(e, tables: first + count) { return r }
            if let wal = walAppender {
                do { _ = try wal.ttableBulk(first: UInt32(first), count: UInt32(count), bytes: src) }
                catch { return walAppendError(error) }
            }
            do { try e.writeTables(first: first, count: count, bytes: src) } catch { return ternaryRefusal(Reply.errorWords(error)) }
            return "OK TTABLE_BULK first=\(first) count=\(count) tables=\(e.ttableCount)"

        default:
            return nil
        }
    }

    /// The library's growth, the one fallible step
    /// of a table write, before the table record goes to the WAL. In earlier builds
    /// a buffer that could not be had came after the record: the reply was
    /// ERROR, the table not written, and the log held a record replay applies.
    func reserveTablesBeforeWAL(_ e: DagDBEngine, tables: Int) -> String? {
        do { try e.reserveTableCapacity(tables) } catch { return ternaryRefusal("\(Reply.errorWords(error)); nothing written") }
        return nil
    }

    /// COMPOSE on tables. Nil when the sources
    /// are binary and the destination binary — today's COMPOSE runs then.
    func composeTernary(op: String, src1: Int, src2: Int?, dst: Int) -> String? {
        let e = engine
        let kind = { (i: Int) -> UInt8 in e.modeByte(i) & TernaryReference.kindMask }
        let srcKinds = [kind(src1)] + (src2.map { [kind($0)] } ?? [])
        let anyTable = srcKinds.contains(TernaryReference.kindTTable)
        let anyThresh = srcKinds.contains(TernaryReference.kindTThresh)
        if !anyTable && !anyThresh {
            // Binary sources are refused when aimed at a ternary node.
            if kind(dst) != TernaryReference.kindBinary {
                return ternaryRefusal("binary COMPOSE aimed at ternary node \(dst) (mode \(Self.kindWord(e.modeByte(dst))))")
            }
            return nil
        }
        if anyThresh {
            return ternaryRefusal("COMPOSE on tables needs TTABLE sources; a TTHRESH node has no table")
        }
        if !srcKinds.allSatisfy({ $0 == TernaryReference.kindTTable }) {
            return ternaryRefusal("COMPOSE mixes a TTABLE source with a non-TTABLE one")
        }
        if op == "XOR" { return ternaryRefusal("XOR on tables is not defined (letter 7: AND → min, OR → max, NOT → negation)") }
        if kind(dst) != TernaryReference.kindTTable {
            return ternaryRefusal("COMPOSE on tables needs a TTABLE destination; node \(dst) is \(Self.kindWord(e.modeByte(dst)))")
        }
        guard let a = e.tableBytes(Int(e.ttableIdPtr[src1])) else {
            return ternaryRefusal("node \(src1): ttableId \(e.ttableIdPtr[src1]) is not below the library size \(e.ttableCount)")
        }
        var b: [UInt8]? = nil
        if let s2 = src2 {
            guard let tb = e.tableBytes(Int(e.ttableIdPtr[s2])) else {
                return ternaryRefusal("node \(s2): ttableId \(e.ttableIdPtr[s2]) is not below the library size \(e.ttableCount)")
            }
            b = tb
        }
        guard let out = TernaryReference.composeTables(op: op, a, b) else {
            return op == "NOT" || src2 != nil
                ? ternaryRefusal("unknown compose op \(Reply.quoted(op))")
                : "ERROR dsl_parse: \(op) requires two sources"
        }
        let tid = e.ttableCount
        if let why = out.withUnsafeBufferPointer({ e.tableWriteRefusal(first: tid, count: 1, bytes: $0) }) {
            return ternaryRefusal(why)
        }
        if let r = admitTableGrowth("COMPOSE", engine: e, tables: tid + 1) { return r }
        if let r = reserveTablesBeforeWAL(e, tables: tid + 1) { return r }
        if let wal = walAppender {
            do { _ = try wal.ttableCompose(dst: UInt32(dst), tid: UInt32(tid), table: out) }
            catch { return walAppendError(error) }
        }
        do { try e.writeTables(first: tid, bytes: out) } catch { return ternaryRefusal(Reply.errorWords(error)) }
        e.ttableIdPtr[dst] = UInt16(tid)
        return "OK COMPOSE op=\(op) src1=\(src1) src2=\(src2.map { String($0) } ?? "—") dst=\(dst) ttable=\(tid)"
    }
}
