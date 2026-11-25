/// DagDBJSONIO — JSON and CSV import/export for DagDB.
///
/// JSON format (dagdb-json v1):
///     { "format": "dagdb-json", "version": 1,
///       "meta": { "nodeCount": N, "gridW": W, "gridH": H, "tickCount": T },
///       "rank":      [u8...],            // length N
///       "truth":     [u8...],            // length N
///       "nodeType":  [u8...],            // length N
///       "lut6Low":   [u32...],           // length N
///       "lut6High":  [u32...],           // length N
///       "neighbors": [[i32 × 6], ...] }  // length N, each row 6 ints
///
/// JSON v2 carries every lane: v1's keys plus
///       "edgeWeightsBits": [u32 × N·6], "activation": [i16...],
///       "nodeValueBits": [u32...], "backEdges": [[src, dst], ...],
///       "nodeMode": [u8...], "ttableId": [u16...],
///       "thrLoBits": [u32...], "thrHiBits": [u32...],
///       "ttables": ["<729 chars of - 0 +>", ...]
/// f32 lanes travel as their bit patterns (JSONSerialization reads "-0"
/// back as integer 0). v2 refuses an out-of-range value instead of
/// truncating it; v1 still loads as before, as a binary graph (the four
/// ternary lanes reset to BINARY, the library emptied).
///
/// CSV format: two files in a directory —
///     nodes.csv: id,rank,truth,nodeType,lut6_low,lut6_high
///     edges.csv: dst,slot,src                           (slot ∈ 0..5)
/// CSV v2: nodes.csv and edges.csv keep
/// v1's exact layout, and four files join them — lanes.csv
/// (id,mode,ttable_id,thr_lo,thr_hi,activation,node_value; its presence
/// marks v2), weights.csv (node,slot,weight for every non-1.0 slot),
/// back_edges.csv (src,dst) and ttables.csv (tid,table). Floats are Swift's
/// shortest round-trip text; a NaN as `bits:0x…`. A directory without
/// lanes.csv is v1 and loads as a binary graph.
///
/// Both paths share the atomic-save discipline from DagDBSnapshot:
/// write-tmp → F_FULLFSYNC → replaceItemAt → dir fsync. See that file
/// for rationale (ACID A + D on macOS APFS).

import Foundation
import Metal

public enum DagDBJSONIO {

    public enum JSONError: Error, CustomStringConvertible, Reply.CarriesLine {
        case invalidFormat(String)
        case unsupportedVersion(UInt32)
        case shapeMismatch(String)
        case ioFailure(String)
        /// A v2 value outside its lane's range — refused, never truncated.
        case outOfRange(String)
        /// A ternary rule, refused by name.
        case ternary(String)
        /// The caller's admission refused the read (its reply, verbatim).
        case admission(String)

        public var description: String {
            switch self {
            case .admission(let line):      return line
            case .outOfRange(let s):        return "out of range: \(s)"
            case .ternary(let s):           return "ternary: \(s)"
            case .invalidFormat(let s):     return "invalid JSON: \(s)"
            case .unsupportedVersion(let v): return "unsupported version: \(v)"
            case .shapeMismatch(let s):     return "shape: \(s)"
            case .ioFailure(let s):         return "io: \(s)"
            }
        }

        /// An admission refusal is its own reply line, under no second code.
        public var replyLine: String? {
            if case .admission(let line) = self { return line }
            return nil
        }
    }

    public static let formatTag = "dagdb-json"
    public static let versionV1: UInt32 = 1
    /// Every lane, the ternary lanes and the library.
    public static let version: UInt32 = 2

    // MARK: - JSON save

    public static func saveJSON(
        engine: DagDBEngine,
        nodeCount: Int,
        gridW: Int,
        gridH: Int,
        tickCount: UInt32,
        path: String
    ) throws -> (bytesWritten: Int, elapsedMs: Double) {
        let t0 = Date()
        if let why = engine.ternaryStateViolation() { throw JSONError.ternary(why) }

        let rank = Array(UnsafeBufferPointer(
            start: engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: nodeCount),
            count: nodeCount))
        let truth = Array(UnsafeBufferPointer(
            start: engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount),
            count: nodeCount))
        let type = Array(UnsafeBufferPointer(
            start: engine.nodeTypeBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount),
            count: nodeCount))
        let low = Array(UnsafeBufferPointer(
            start: engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount),
            count: nodeCount))
        let high = Array(UnsafeBufferPointer(
            start: engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount),
            count: nodeCount))
        let nbFlat = Array(UnsafeBufferPointer(
            start: engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6),
            count: nodeCount * 6))
        var neighbors: [[Int32]] = []
        neighbors.reserveCapacity(nodeCount)
        for i in 0..<nodeCount {
            neighbors.append(Array(nbFlat[(i * 6)..<(i * 6 + 6)]))
        }

        func lane<T>(_ b: MTLBuffer, _ t: T.Type, _ c: Int) -> [T] {
            Array(UnsafeBufferPointer(start: b.contents().bindMemory(to: T.self, capacity: max(c, 1)), count: c))
        }
        let weightsBits = lane(engine.edgeWeightsBuf, UInt32.self, nodeCount * 6)
        let activation = lane(engine.activationBuf, Int16.self, nodeCount)
        let valueBits = lane(engine.nodeValueBuf, UInt32.self, nodeCount)
        // Lanes never allocated read as their zero defaults.
        let lanes = engine.ternaryLaneView
        let modes = lanes.map { Array(UnsafeBufferPointer(start: $0.mode, count: nodeCount)) }
            ?? [UInt8](repeating: 0, count: nodeCount)
        let tids = lanes.map { Array(UnsafeBufferPointer(start: $0.ttableId, count: nodeCount)) }
            ?? [UInt16](repeating: 0, count: nodeCount)
        let loBits = lanes.map { v in (0..<nodeCount).map { v.thrLo[$0].bitPattern } }
            ?? [UInt32](repeating: 0, count: nodeCount)
        let hiBits = lanes.map { v in (0..<nodeCount).map { v.thrHi[$0].bitPattern } }
            ?? [UInt32](repeating: 0, count: nodeCount)
        let backEdges = (0..<engine.backEdgeCount).map { [engine.backEdgeSrcs[$0], engine.backEdgeDsts[$0]] }
        let lib = engine.libraryBytes()
        let tables = stride(from: 0, to: lib.count, by: TernaryReference.tableSize).map { o in
            String(lib[o..<(o + TernaryReference.tableSize)].map { TernaryReference.char(ofTableByte: $0) })
        }

        let payload: [String: Any] = [
            "format": formatTag,
            "version": version,
            "edgeWeightsBits": weightsBits,
            "activation": activation,
            "nodeValueBits": valueBits,
            "backEdges": backEdges,
            "nodeMode": modes,
            "ttableId": tids,
            "thrLoBits": loBits,
            "thrHiBits": hiBits,
            "ttables": tables,
            "meta": [
                "nodeCount": nodeCount,
                "gridW": gridW,
                "gridH": gridH,
                "tickCount": tickCount
            ],
            "rank":      rank,
            "truth":     truth,
            "nodeType":  type,
            "lut6Low":   low,
            "lut6High":  high,
            "neighbors": neighbors
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try atomicWrite(data: data, path: path)

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (data.count, elapsed)
    }

    // MARK: - JSON load

    public struct JSONLoadResult {
        public let bytesRead: Int
        public let fileNodeCount: Int
        public let fileTicks: UInt32
        public let elapsedMs: Double
    }

    public static func loadJSON(
        engine: DagDBEngine,
        nodeCount: Int,
        gridW: Int,
        gridH: Int,
        path: String,
        validate: Bool = true,
        admit: ((Int) -> String?)? = nil,
        admitParse: ((Data) -> String?)? = nil
    ) throws -> JSONLoadResult {
        let t0 = Date()

        // Read once through the helper (non-blocking, a regular file inside the root, admitted on its true
        // size, unchanged while read); no mapping. The parse tree's own cost is admitted separately, below.
        let data = try readFile(path, admit: admit.map { a in { a($0) } }, missing: "file not found: \(Reply.quoted(path))")
        // The parse is admitted on the bytes read (their , : [ { count), before JSONSerialization.
        if let a = admitParse, let line = a(data) { throw JSONError.admission(line) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JSONError.invalidFormat("not a JSON object")
        }

        guard let fmt = obj["format"] as? String, fmt == formatTag else {
            throw JSONError.invalidFormat("format tag missing or wrong")
        }
        var fileVersion = versionV1
        if let v = obj["version"] as? UInt32 ?? (obj["version"] as? Int).map(UInt32.init) {
            guard v == versionV1 || v == version else { throw JSONError.unsupportedVersion(v) }
            fileVersion = v
        }
        let isV2 = fileVersion == version

        guard let meta = obj["meta"] as? [String: Any],
              let fileNC = meta["nodeCount"] as? Int,
              let fileGW = meta["gridW"] as? Int,
              let fileGH = meta["gridH"] as? Int else {
            throw JSONError.invalidFormat("meta missing required fields")
        }
        let fileTicks = (meta["tickCount"] as? Int).map(UInt32.init) ?? 0

        guard fileNC == nodeCount else {
            throw JSONError.shapeMismatch("nodeCount file=\(fileNC) engine=\(nodeCount)")
        }
        guard fileGW == gridW && fileGH == gridH else {
            throw JSONError.shapeMismatch("grid file=\(fileGW)x\(fileGH) engine=\(gridW)x\(gridH)")
        }

        guard let rankA  = obj["rank"]      as? [Int], rankA.count  == nodeCount,
              let truthA = obj["truth"]     as? [Int], truthA.count == nodeCount,
              let typeA  = obj["nodeType"]  as? [Int], typeA.count  == nodeCount,
              let lowA   = obj["lut6Low"]   as? [Int], lowA.count   == nodeCount,
              let highA  = obj["lut6High"]  as? [Int], highA.count  == nodeCount,
              let nbA    = obj["neighbors"] as? [[Int]], nbA.count  == nodeCount
        else {
            throw JSONError.shapeMismatch("one of rank/truth/nodeType/lut6Low/lut6High/neighbors bad length or type")
        }

        // v2 refuses an out-of-range value instead of truncating it. v1 keeps
        // its truncation, identically.
        if isV2 {
            for (i, t) in truthA.enumerated() where t < 0 || t > 255 {
                throw JSONError.outOfRange("node \(i): truth \(t) not in 0...255")
            }
            for (i, r) in rankA.enumerated() where r < 0 {
                throw JSONError.outOfRange("node \(i): rank \(r) is negative")
            }
            for (i, t) in typeA.enumerated() where t < 0 || t > 255 {
                throw JSONError.outOfRange("node \(i): nodeType \(t) not in 0...255")
            }
            for (name, arr) in [("lut6Low", lowA), ("lut6High", highA)] {
                for (i, v) in arr.enumerated() where v < 0 || v > Int(UInt32.max) {
                    throw JSONError.outOfRange("node \(i): \(name) \(v) not in 0...\(UInt32.max)")
                }
            }
        }
        var ternary: TernaryJSON? = nil
        if isV2 { ternary = try readTernaryJSON(obj, nodeCount: nodeCount) }

        // Stage into CPU arrays before committing to GPU buffers.
        // UInt32 bit-patterns can exceed Int32.max, so use truncatingIfNeeded.
        let rank  = rankA.map  { UInt64(truncatingIfNeeded: $0) }
        let truth = truthA.map { UInt8(truncatingIfNeeded: $0) }
        let type  = typeA.map  { UInt8(truncatingIfNeeded: $0) }
        let low   = lowA.map   { UInt32(truncatingIfNeeded: $0) }
        let high  = highA.map  { UInt32(truncatingIfNeeded: $0) }
        var nbFlat = [Int32](); nbFlat.reserveCapacity(nodeCount * 6)
        for row in nbA {
            guard row.count == 6 else {
                throw JSONError.shapeMismatch("neighbors row length != 6")
            }
            for v in row { nbFlat.append(Int32(truncatingIfNeeded: v)) }
        }

        // Pre-commit slot validation: the persistence rule, the one function
        // every loader asks — a source out of range refused, in LOAD's words;
        // the other slot shapes are legal to store.
        if validate, let v = nbFlat.withUnsafeBufferPointer({
            DagDBSnapshot.persistenceSlotScan(nodeCount: nodeCount, neighbors: $0.baseAddress!).violation
        }) {
            throw JSONError.invalidFormat(v)
        }

        // A non-finite edge weight or node value, then the ternary rules, on
        // the staged v2 lanes, before anything is committed.
        if let t = ternary, let why = t.weightRefusal() ?? t.valueRefusal() { throw JSONError.outOfRange(why) }
        // CONNECT BACK's rules on v2's own back-edge list, against the staged
        // lanes, before the ternary rule. A v1 file carries no list and keeps
        // the live one; that kept list is checked against the file's slots
        // for a slot into a register,
        // in CONNECT BACK's words, so a v1 load never makes a state SAVE
        // refuses (`ERROR schema: LOAD JSON kept back edge entry <i>: …`).
        if validate, let t = ternary,
           let r = backEdgeRefusal(t, list: "backEdges", neighbors: nbFlat, nodeCount: nodeCount) {
            throw r
        }
        if validate, ternary == nil, let r = keptListRefusal(engine, neighbors: nbFlat, nodeCount: nodeCount) {
            throw r
        }
        if let t = ternary, let why = t.violation(truth: truth, nodeCount: nodeCount) {
            throw JSONError.ternary(why)
        }

        // The library's room is reserved before the commit.
        if let t = ternary { try engine.reserveTableCapacity(t.tables.count / TernaryReference.tableSize) }

        // Commit to GPU buffers (rank is u64 → 8 bytes per node)
        rank.withUnsafeBufferPointer  { memcpy(engine.rankBuf.contents(),       $0.baseAddress!, nodeCount * 8) }
        truth.withUnsafeBufferPointer { memcpy(engine.truthStateBuf.contents(), $0.baseAddress!, nodeCount) }
        type.withUnsafeBufferPointer  { memcpy(engine.nodeTypeBuf.contents(),   $0.baseAddress!, nodeCount) }
        low.withUnsafeBufferPointer   { memcpy(engine.lut6LowBuf.contents(),    $0.baseAddress!, nodeCount * 4) }
        high.withUnsafeBufferPointer  { memcpy(engine.lut6HighBuf.contents(),   $0.baseAddress!, nodeCount * 4) }
        nbFlat.withUnsafeBufferPointer { memcpy(engine.neighborsBuf.contents(), $0.baseAddress!, nodeCount * 6 * 4) }
        if let t = ternary {
            try t.commit(to: engine, nodeCount: nodeCount)
        } else {
            engine.resetTernaryLanes()
        }

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return JSONLoadResult(bytesRead: data.count, fileNodeCount: fileNC,
                              fileTicks: fileTicks, elapsedMs: elapsed)
    }

    /// The live back-edge list a v1 load keeps, against the file's staged
    /// slots: only the slot-into-a-register rule (`slotIntoRegisterRefusal`).
    static func keptListRefusal(_ engine: DagDBEngine, neighbors: [Int32],
                                nodeCount: Int) -> DagDBEngine.BackEdgeEntryRefusal? {
        if engine.backEdgeSrcs.isEmpty { return nil }
        return neighbors.withUnsafeBufferPointer { nb in
            DagDBEngine.slotIntoRegisterRefusal(list: "kept back edge", srcs: engine.backEdgeSrcs,
                                                dsts: engine.backEdgeDsts, nodeCount: nodeCount,
                                                neighbors: nb.baseAddress!)
        }
    }

    /// A v2 file's own back-edge list against CONNECT BACK's
    /// rules on the file's staged mode and neighbour lanes.
    static func backEdgeRefusal(_ t: TernaryJSON, list: String,
                                neighbors: [Int32], nodeCount: Int) -> DagDBEngine.BackEdgeEntryRefusal? {
        neighbors.withUnsafeBufferPointer { nb in
            t.mode.withUnsafeBufferPointer { m in
                DagDBEngine.backEdgeListRefusal(list: list, srcs: t.backEdges.map { $0.0 }, dsts: t.backEdges.map { $0.1 },
                                                nodeCount: nodeCount, mode: m.baseAddress, neighbors: nb.baseAddress!)
            }
        }
    }

    // MARK: - v2 lanes (shared by JSON and CSV)

    /// The lanes a v2 file adds, staged, checked, committed together.
    struct TernaryJSON {
        var weights: [Float], activation: [Int16], value: [Float]
        var backEdges: [(UInt32, UInt32)]
        var mode: [UInt8], ttableId: [UInt16], thrLo: [Float], thrHi: [Float]
        var tables: [UInt8]

        /// SET WEIGHT's rule on the staged weight lane.
        func weightRefusal() -> String? {
            weights.withUnsafeBytes { raw in
                raw.baseAddress.flatMap { DagDBSnapshot.weightRefusal($0, count: weights.count) }
            }
        }

        /// SET VALUE's rule on the staged node-value lane.
        func valueRefusal() -> String? {
            value.withUnsafeBytes { raw in
                raw.baseAddress.flatMap { DagDBSnapshot.nodeValueRefusal($0, count: value.count) }
            }
        }

        func violation(truth: [UInt8], nodeCount n: Int) -> String? {
            if let why = TernaryReference.libraryRefusal(tables) { return why }
            var reg = [UInt8](repeating: 0, count: n)
            for (s, d) in backEdges {
                guard Int(s) < n && Int(d) < n else { return "back edge \(s)→\(d) out of range for \(n) nodes" }
                reg[Int(d)] = 1
            }
            return tables.withUnsafeBufferPointer { lib in
                TernaryReference.stateViolation(n: n, mode: mode, ttableId: ttableId, thrLo: thrLo, thrHi: thrHi,
                                                truth: truth, isRegister: reg, tables: lib)
            }
        }

        func commit(to engine: DagDBEngine, nodeCount n: Int) throws {
            weights.withUnsafeBytes { memcpy(engine.edgeWeightsBuf.contents(), $0.baseAddress!, n * 24) }
            activation.withUnsafeBytes { memcpy(engine.activationBuf.contents(), $0.baseAddress!, n * 2) }
            value.withUnsafeBytes { memcpy(engine.nodeValueBuf.contents(), $0.baseAddress!, n * 4) }
            // An all-default set of lanes leaves them unallocated.
            engine.installTernaryLanes(mode: mode, ttableId: ttableId, thrLo: thrLo, thrHi: thrHi)
            try engine.replaceLibrary(tables)
            // Back edges through the engine's own installer, after a reset,
            // so the latch list and the register flags agree.
            engine.backEdgeSrcs.removeAll(keepingCapacity: false)
            engine.backEdgeDsts.removeAll(keepingCapacity: false)
            memset(engine.isRegisterBuf.contents(), 0, n)
            for (s, d) in backEdges { try engine.addBackEdgeUnchecked(src: s, dst: d) }
        }
    }

    static func readTernaryJSON(_ obj: [String: Any], nodeCount n: Int) throws -> TernaryJSON {
        func ints(_ key: String, _ count: Int, _ range: ClosedRange<Int>) throws -> [Int] {
            guard let a = obj[key] as? [Int], a.count == count else {
                throw JSONError.shapeMismatch("\(key): missing, wrong type or not \(count) long")
            }
            for (i, v) in a.enumerated() where !range.contains(v) {
                throw JSONError.outOfRange("\(key)[\(i)] = \(v) not in \(range.lowerBound)...\(range.upperBound)")
            }
            return a
        }
        let u32 = 0...Int(UInt32.max)
        let w = try ints("edgeWeightsBits", n * 6, u32).map { Float(bitPattern: UInt32($0)) }
        let act = try ints("activation", n, Int(Int16.min)...Int(Int16.max)).map { Int16($0) }
        let val = try ints("nodeValueBits", n, u32).map { Float(bitPattern: UInt32($0)) }
        let mode = try ints("nodeMode", n, 0...255).map { UInt8($0) }
        let tid = try ints("ttableId", n, 0...Int(UInt16.max)).map { UInt16($0) }
        let lo = try ints("thrLoBits", n, u32).map { Float(bitPattern: UInt32($0)) }
        let hi = try ints("thrHiBits", n, u32).map { Float(bitPattern: UInt32($0)) }
        guard let beA = obj["backEdges"] as? [[Int]] else {
            throw JSONError.shapeMismatch("backEdges: missing or not a list of [src, dst]")
        }
        var be: [(UInt32, UInt32)] = []
        for (i, pair) in beA.enumerated() {
            guard pair.count == 2, (0..<n).contains(pair[0]), (0..<n).contains(pair[1]) else {
                throw JSONError.outOfRange("backEdges[\(i)] = \(pair) is not a pair of nodes in 0..<\(n)")
            }
            be.append((UInt32(pair[0]), UInt32(pair[1])))
        }
        guard let tA = obj["ttables"] as? [String] else {
            throw JSONError.shapeMismatch("ttables: missing or not a list of strings")
        }
        var tables: [UInt8] = []
        for (k, t) in tA.enumerated() {
            guard t.count == TernaryReference.tableSize else {
                throw JSONError.shapeMismatch("ttables[\(k)] is \(t.count) characters, not \(TernaryReference.tableSize)")
            }
            for c in t {
                guard let b = TernaryReference.tableByte(ofChar: c) else {
                    throw JSONError.ternary("ttables[\(k)] holds \(Reply.quoted(String(c))); tables are - 0 +")
                }
                tables.append(b)
            }
        }
        return TernaryJSON(weights: w, activation: act, value: val, backEdges: be, mode: mode,
                           ttableId: tid, thrLo: lo, thrHi: hi, tables: tables)
    }

    /// Shortest round-trip text for an f32; a NaN as its bit pattern.
    static func floatText(_ f: Float) -> String {
        f.isNaN ? "bits:0x" + String(f.bitPattern, radix: 16) : "\(f)"
    }
    static func parseFloat<S: StringProtocol>(_ s: S) -> Float? {
        if s.hasPrefix("bits:0x"), let b = UInt32(s.dropFirst(7), radix: 16) { return Float(bitPattern: b) }
        return Float(String(s))
    }

    // MARK: - CSV save (v2: every lane)

    /// v1's two files keep their exact layout; v2 adds four beside them:
    /// lanes.csv is the version marker.
    static let csvLanesHeader = "id,mode,ttable_id,thr_lo,thr_hi,activation,node_value"
    static let csvWeightsHeader = "node,slot,weight"

    public static func saveCSV(
        engine: DagDBEngine,
        nodeCount: Int,
        dir: String
    ) throws -> (nodesBytes: Int, edgesBytes: Int, elapsedMs: Double) {
        let t0 = Date()
        if let why = engine.ternaryStateViolation() { throw JSONError.ternary(why) }

        let rank = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: nodeCount)
        let truth = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        let type = engine.nodeTypeBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        let low = engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
        let high = engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
        let nb = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)
        let w = engine.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: nodeCount * 6)
        let act = engine.activationBuf.contents().bindMemory(to: Int16.self, capacity: nodeCount)
        let val = engine.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: nodeCount)
        // Lanes never allocated read as their zero defaults.
        let lanes = engine.ternaryLaneView
        let zeroMode: UInt8 = 0, zeroTid: UInt16 = 0, zeroF: Float = 0

        var nodesCSV = "id,rank,truth,nodeType,lut6_low,lut6_high\n"
        nodesCSV.reserveCapacity(nodeCount * 40)
        for i in 0..<nodeCount {
            nodesCSV += "\(i),\(rank[i]),\(truth[i]),\(type[i]),\(low[i]),\(high[i])\n"
        }

        var edgesCSV = "dst,slot,src\n"
        edgesCSV.reserveCapacity(nodeCount * 16)
        for dst in 0..<nodeCount {
            for d in 0..<6 {
                let src = nb[dst * 6 + d]
                if src < 0 { continue }
                edgesCSV += "\(dst),\(d),\(src)\n"
            }
        }

        // v2 · the lanes v1 does not carry.
        var lanesCSV = csvLanesHeader + "\n"
        lanesCSV.reserveCapacity(nodeCount * 24)
        for i in 0..<nodeCount {
            let m = lanes?.mode[i] ?? zeroMode, t = lanes?.ttableId[i] ?? zeroTid
            let l = lanes?.thrLo[i] ?? zeroF, h = lanes?.thrHi[i] ?? zeroF
            lanesCSV += "\(i),\(m),\(t),\(floatText(l)),\(floatText(h)),\(act[i]),\(floatText(val[i]))\n"
        }
        // Every slot whose weight is not the 1.0 default (bit pattern).
        var weightsCSV = csvWeightsHeader + "\n"
        let one = Float(1).bitPattern
        for i in 0..<(nodeCount * 6) where w[i].bitPattern != one {
            weightsCSV += "\(i / 6),\(i % 6),\(floatText(w[i]))\n"
        }
        var beCSV = "src,dst\n"
        for i in 0..<engine.backEdgeCount { beCSV += "\(engine.backEdgeSrcs[i]),\(engine.backEdgeDsts[i])\n" }
        let lib = engine.libraryBytes()
        var ttCSV = "tid,table\n"
        for k in 0..<engine.ttableCount {
            let o = k * TernaryReference.tableSize
            ttCSV += "\(k)," + String(lib[o..<(o + TernaryReference.tableSize)].map { TernaryReference.char(ofTableByte: $0) }) + "\n"
        }

        let nodesData = nodesCSV.data(using: .utf8)!
        let edgesData = edgesCSV.data(using: .utf8)!
        // The six files are written into a stage inside `dir` and renamed
        // into place after every target name passed its check, so a failure
        // leaves `dir` as it was (written one by one, a failure part-way
        // would leave a mixed set).
        let set = try StagedFileSet.begin(target: dir)
        do {
            try atomicWrite(data: nodesData, path: set.path("nodes.csv"))
            try atomicWrite(data: edgesData, path: set.path("edges.csv"))
            try atomicWrite(data: weightsCSV.data(using: .utf8)!, path: set.path("weights.csv"))
            try atomicWrite(data: beCSV.data(using: .utf8)!, path: set.path("back_edges.csv"))
            try atomicWrite(data: ttCSV.data(using: .utf8)!, path: set.path("ttables.csv"))
            try atomicWrite(data: lanesCSV.data(using: .utf8)!, path: set.path("lanes.csv"))
            // lanes.csv last: it is the v2 marker, so a directory is never v2
            // before its other v2 files are in place.
            try set.commit(["nodes.csv", "edges.csv", "weights.csv", "back_edges.csv", "ttables.csv", "lanes.csv"])
        } catch {
            if let left = set.abort() { throw JSONError.outOfRange("\(Reply.errorWords(error)); and the stage could not be removed: \(left)") }
            throw error
        }

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (nodesData.count, edgesData.count, elapsed)
    }

    // MARK: - CSV load (v1: two files; v2: lanes.csv and its three companions too)

    public struct CSVLoadResult {
        public let nodesParsed: Int
        public let edgesParsed: Int
        public let elapsedMs: Double
    }

    public static func loadCSV(
        engine: DagDBEngine,
        nodeCount: Int,
        dir: String,
        validate: Bool = true,
        admit: ((Int) -> String?)? = nil
    ) throws -> CSVLoadResult {
        let t0 = Date()

        // Each file read once through the helper (non-blocking, a regular file inside the root, admitted on
        // its true size, its bytes and their text: 2 x), and decoded as UTF-8 or refused by name. A failure
        // to read one of the four companions is never taken as "absent".
        guard let nodesRaw = try readText(dir + "/nodes.csv", admit: admit) else {
            throw JSONError.ioFailure("missing nodes.csv")
        }
        guard let edgesRaw = try readText(dir + "/edges.csv", admit: admit) else {
            throw JSONError.ioFailure("missing edges.csv")
        }

        var rank  = [UInt64](repeating: 0, count: nodeCount)
        var truth = [UInt8](repeating: 0, count: nodeCount)
        var type  = [UInt8](repeating: 0, count: nodeCount)
        var low   = [UInt32](repeating: 0, count: nodeCount)
        var high  = [UInt32](repeating: 0, count: nodeCount)
        var nb    = [Int32](repeating: -1, count: nodeCount * 6)

        var nodesCount = 0
        for (lineNo, rawLine) in nodesRaw.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            if lineNo == 0 { continue }  // header
            let parts = rawLine.split(separator: ",")
            guard parts.count == 6,
                  let id = Int(parts[0]),
                  let r  = UInt64(parts[1]),
                  let t  = UInt8(parts[2]),
                  let nt = UInt8(parts[3]),
                  let lo = UInt32(parts[4]),
                  let hi = UInt32(parts[5])
            else {
                throw JSONError.invalidFormat("nodes.csv line \(lineNo + 1): bad row")
            }
            guard id >= 0 && id < nodeCount else {
                throw JSONError.shapeMismatch("nodes.csv id \(id) out of range")
            }
            rank[id] = r; truth[id] = t; type[id] = nt; low[id] = lo; high[id] = hi
            nodesCount += 1
        }

        var edgesCount = 0
        for (lineNo, rawLine) in edgesRaw.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            if lineNo == 0 { continue }
            let parts = rawLine.split(separator: ",")
            guard parts.count == 3,
                  let dst  = Int(parts[0]),
                  let slot = Int(parts[1]),
                  let src  = Int32(parts[2])
            else {
                throw JSONError.invalidFormat("edges.csv line \(lineNo + 1): bad row")
            }
            guard dst >= 0 && dst < nodeCount, slot >= 0 && slot < 6 else {
                throw JSONError.shapeMismatch("edges.csv dst=\(dst) slot=\(slot) out of range")
            }
            nb[dst * 6 + slot] = src
            edgesCount += 1
        }

        // The persistence rule, LOAD's words.
        if validate, let v = nb.withUnsafeBufferPointer({
            DagDBSnapshot.persistenceSlotScan(nodeCount: nodeCount, neighbors: $0.baseAddress!).violation
        }) {
            throw JSONError.invalidFormat(v)
        }

        // v2 · lanes.csv present ⇒ the four companion files describe every
        // other lane; checked against every ternary rule before any commit.
        var ternary: TernaryJSON? = nil
        if let lanesRaw = try readText(dir + "/lanes.csv", admit: admit, companion: true) {
            ternary = try readCSVLanes(dir: dir, lanesRaw: lanesRaw, nodeCount: nodeCount, admit: admit)
            if let why = ternary!.weightRefusal() ?? ternary!.valueRefusal() { throw JSONError.outOfRange(why) }
        }
        // CONNECT BACK's rules on back_edges.csv's list (v2, with lanes.csv),
        // on the staged lanes, before the ternary rule. Without lanes.csv the
        // live list is kept and checked against the file's slots for a slot
        // into a register, as LOAD JSON v1.
        if validate, let t = ternary,
           let r = backEdgeRefusal(t, list: "back_edges.csv", neighbors: nb, nodeCount: nodeCount) {
            throw r
        }
        if validate, ternary == nil, let r = keptListRefusal(engine, neighbors: nb, nodeCount: nodeCount) {
            throw r
        }
        if let t = ternary {
            if let why = t.violation(truth: truth, nodeCount: nodeCount) { throw JSONError.ternary(why) }
            // The library's room is reserved before the commit.
            try engine.reserveTableCapacity(t.tables.count / TernaryReference.tableSize)
        }

        rank.withUnsafeBufferPointer  { memcpy(engine.rankBuf.contents(),       $0.baseAddress!, nodeCount * 8) }
        truth.withUnsafeBufferPointer { memcpy(engine.truthStateBuf.contents(), $0.baseAddress!, nodeCount) }
        type.withUnsafeBufferPointer  { memcpy(engine.nodeTypeBuf.contents(),   $0.baseAddress!, nodeCount) }
        low.withUnsafeBufferPointer   { memcpy(engine.lut6LowBuf.contents(),    $0.baseAddress!, nodeCount * 4) }
        high.withUnsafeBufferPointer  { memcpy(engine.lut6HighBuf.contents(),   $0.baseAddress!, nodeCount * 4) }
        nb.withUnsafeBufferPointer    { memcpy(engine.neighborsBuf.contents(),  $0.baseAddress!, nodeCount * 6 * 4) }
        if let t = ternary {
            try t.commit(to: engine, nodeCount: nodeCount)
        } else {
            engine.resetTernaryLanes()
        }

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return CSVLoadResult(nodesParsed: nodesCount, edgesParsed: edgesCount, elapsedMs: elapsed)
    }

    /// A file's bytes through the helper; `missing` for ENOENT (nil when not given); every other
    /// refusal by name.
    static func readFile(_ path: String, admit: ((Int) -> String?)?, missing: String?) throws -> Data {
        do { return try DaemonFile.read(path, admit: admit) }
        catch DaemonFile.Refusal.missing where missing != nil { throw JSONError.ioFailure(missing!) }
        catch DaemonFile.Refusal.admission(let line) { throw JSONError.admission(line) }
        catch let r as DaemonFile.Refusal { throw JSONError.ioFailure("\(Reply.errorWords(r))") }
    }

    /// A CSV file's text, nil only when it is absent. Admitted at 2 x its size (its bytes and
    /// the decoded text); refused by name when it is not UTF-8. A `companion` (lanes.csv and the three v2
    /// files SAVE CSV writes beside it, every row newline-terminated) must end in a newline: a file cut
    /// mid-row is refused, never parsed as far as it goes.
    static func readText(_ path: String, admit: ((Int) -> String?)?, companion: Bool = false) throws -> String? {
        let d: Data
        do {
            guard let x = try DaemonFile.readIfPresent(path, admit: admit.map { a in { a(2 * $0) } }) else { return nil }
            d = x
        } catch DaemonFile.Refusal.admission(let line) { throw JSONError.admission(line) }
        catch let r as DaemonFile.Refusal { throw JSONError.ioFailure("\(Reply.errorWords(r))") }
        guard let text = String(data: d, encoding: .utf8) else {
            throw JSONError.invalidFormat("\((path as NSString).lastPathComponent) is not UTF-8 text (\(d.count) bytes); nothing loaded")
        }
        if companion, !text.isEmpty, !text.hasSuffix("\n") {
            throw JSONError.invalidFormat("\((path as NSString).lastPathComponent) does not end in a newline: the file is cut mid-row (\(d.count) bytes); nothing loaded")
        }
        return text
    }

    static func readCSVLanes(dir: String, lanesRaw: String, nodeCount n: Int,
                             admit: ((Int) -> String?)? = nil) throws -> TernaryJSON {
        var w = [Float](repeating: 1, count: n * 6)
        var act = [Int16](repeating: 0, count: n)
        var val = [Float](repeating: 0, count: n)
        var mode = [UInt8](repeating: 0, count: n)
        var tid = [UInt16](repeating: 0, count: n)
        var lo = [Float](repeating: 0, count: n), hi = lo
        // lanes.csv carries every node exactly once (SAVE CSV writes one row per node): a file
        // holding fewer rows (cut at a row boundary) or a node twice is refused, never loaded with the missing
        // nodes reset to their defaults.
        var seen = [Bool](repeating: false, count: n)
        var rows = 0
        for (lineNo, line) in lanesRaw.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where lineNo > 0 {
            let p = line.split(separator: ",", omittingEmptySubsequences: false)
            guard p.count == 7, let id = Int(p[0]), id >= 0, id < n,
                  let m = UInt8(p[1]), let k = UInt16(p[2]),
                  let l = parseFloat(p[3]), let h = parseFloat(p[4]),
                  let a = Int16(p[5]), let v = parseFloat(p[6]) else {
                throw JSONError.invalidFormat("lanes.csv line \(lineNo + 1): bad row")
            }
            guard !seen[id] else {
                throw JSONError.invalidFormat("lanes.csv line \(lineNo + 1): node \(id) appears twice; nothing loaded")
            }
            seen[id] = true; rows += 1
            mode[id] = m; tid[id] = k; lo[id] = l; hi[id] = h; act[id] = a; val[id] = v
        }
        guard rows == n else {
            let first = seen.firstIndex(of: false) ?? 0
            throw JSONError.invalidFormat("lanes.csv holds \(rows) node rows for \(n) nodes (node \(first) is missing):"
                + " a cut or partial file; nothing loaded")
        }
        if let raw = try readText(dir + "/weights.csv", admit: admit, companion: true) {
            for (lineNo, line) in raw.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where lineNo > 0 {
                let p = line.split(separator: ",", omittingEmptySubsequences: false)
                guard p.count == 3, let node = Int(p[0]), node >= 0, node < n,
                      let slot = Int(p[1]), slot >= 0, slot < 6, let wt = parseFloat(p[2]) else {
                    throw JSONError.invalidFormat("weights.csv line \(lineNo + 1): bad row")
                }
                w[node * 6 + slot] = wt
            }
        }
        var backEdges: [(UInt32, UInt32)] = []
        if let raw = try readText(dir + "/back_edges.csv", admit: admit, companion: true) {
            for (lineNo, line) in raw.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where lineNo > 0 {
                let p = line.split(separator: ",")
                guard p.count == 2, let a = UInt32(p[0]), let b = UInt32(p[1]), Int(a) < n, Int(b) < n else {
                    throw JSONError.invalidFormat("back_edges.csv line \(lineNo + 1): bad row")
                }
                backEdges.append((a, b))
            }
        }
        var tables: [UInt8] = []
        if let raw = try readText(dir + "/ttables.csv", admit: admit, companion: true) {
            for (lineNo, line) in raw.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where lineNo > 0 {
                let p = line.split(separator: ",")
                guard p.count == 2, let k = Int(p[0]), k == lineNo - 1,
                      p[1].count == TernaryReference.tableSize else {
                    throw JSONError.invalidFormat("ttables.csv line \(lineNo + 1): bad row (tables are dense, in id order, \(TernaryReference.tableSize) characters of - 0 +)")
                }
                for c in p[1] {
                    guard let b = TernaryReference.tableByte(ofChar: c) else {
                        throw JSONError.ternary("ttables.csv table \(k) holds \(Reply.quoted(String(c))); tables are - 0 +")
                    }
                    tables.append(b)
                }
            }
        }
        return TernaryJSON(weights: w, activation: act, value: val, backEdges: backEdges, mode: mode,
                           ttableId: tid, thrLo: lo, thrHi: hi, tables: tables)
    }

    // MARK: - Atomic write (shared with DagDBSnapshot's discipline)

    private static func atomicWrite(data: Data, path: String) throws {
        #if DEBUG || DAGDB_FAULT_INJECTION
        if DagDBFaultInjection.writeFails(path) {   // fault-injection seam: the staging keeps the target whole
            throw JSONError.outOfRange("write \(Reply.quoted(path)): \(DagDBFaultInjection.InjectedFault(what: "WRITE_FAIL"))")
        }
        #endif
        // A hidden temporary beside the target (created exclusively, no link followed), F_FULLFSYNC'd,
        // renamed over it with no link followed, the directory synced (NSData's .atomic is not used: its
        // temporary and rename follow a linked directory).
        do { try DaemonFile.atomicWrite(data, to: path) }
        catch let r as DaemonFile.Refusal { throw JSONError.ioFailure("\(Reply.errorWords(r))") }
    }
}
