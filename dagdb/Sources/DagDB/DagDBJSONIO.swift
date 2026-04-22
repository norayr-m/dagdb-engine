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
/// CSV format: two files in a directory —
///     nodes.csv: id,rank,truth,nodeType,lut6_low,lut6_high
///     edges.csv: dst,slot,src                           (slot ∈ 0..5)
///
/// Both paths share the atomic-save discipline from DagDBSnapshot:
/// write-tmp → F_FULLFSYNC → replaceItemAt → dir fsync. See that file
/// for rationale (ACID A + D on macOS APFS).

import Foundation

public enum DagDBJSONIO {

    public enum JSONError: Error, CustomStringConvertible {
        case invalidFormat(String)
        case unsupportedVersion(UInt32)
        case shapeMismatch(String)
        case ioFailure(String)

        public var description: String {
            switch self {
            case .invalidFormat(let s):     return "invalid JSON: \(s)"
            case .unsupportedVersion(let v): return "unsupported version: \(v)"
            case .shapeMismatch(let s):     return "shape: \(s)"
            case .ioFailure(let s):         return "io: \(s)"
            }
        }
    }

    public static let formatTag = "dagdb-json"
    public static let version: UInt32 = 1

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

        let payload: [String: Any] = [
            "format": formatTag,
            "version": version,
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
        validate: Bool = true
    ) throws -> JSONLoadResult {
        let t0 = Date()

        guard FileManager.default.fileExists(atPath: path) else {
            throw JSONError.ioFailure("file not found: \(path)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JSONError.invalidFormat("not a JSON object")
        }

        guard let fmt = obj["format"] as? String, fmt == formatTag else {
            throw JSONError.invalidFormat("format tag missing or wrong")
        }
        if let v = obj["version"] as? UInt32 ?? (obj["version"] as? Int).map(UInt32.init),
           v != version {
            throw JSONError.unsupportedVersion(v)
        }

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

        // Pre-commit DAG-invariant validation (same rules as DagDBSnapshot).
        if validate {
            for dst in 0..<nodeCount {
                var seen = Set<Int32>()
                for d in 0..<6 {
                    let src = nbFlat[dst * 6 + d]
                    if src < 0 { continue }
                    if src >= Int32(nodeCount) {
                        throw JSONError.invalidFormat("node \(dst) slot \(d): src \(src) out of range")
                    }
                    if Int(src) == dst {
                        throw JSONError.invalidFormat("node \(dst) slot \(d): self-loop")
                    }
                    if rank[Int(src)] <= rank[dst] {
                        throw JSONError.invalidFormat("node \(dst): src rank \(rank[Int(src)]) must be > dst rank \(rank[dst])")
                    }
                    if seen.contains(src) {
                        throw JSONError.invalidFormat("node \(dst): duplicate edge from \(src)")
                    }
                    seen.insert(src)
                }
            }
        }

        // Commit to GPU buffers (rank is u64 → 8 bytes per node)
        rank.withUnsafeBufferPointer  { memcpy(engine.rankBuf.contents(),       $0.baseAddress!, nodeCount * 8) }
        truth.withUnsafeBufferPointer { memcpy(engine.truthStateBuf.contents(), $0.baseAddress!, nodeCount) }
        type.withUnsafeBufferPointer  { memcpy(engine.nodeTypeBuf.contents(),   $0.baseAddress!, nodeCount) }
        low.withUnsafeBufferPointer   { memcpy(engine.lut6LowBuf.contents(),    $0.baseAddress!, nodeCount * 4) }
        high.withUnsafeBufferPointer  { memcpy(engine.lut6HighBuf.contents(),   $0.baseAddress!, nodeCount * 4) }
        nbFlat.withUnsafeBufferPointer { memcpy(engine.neighborsBuf.contents(), $0.baseAddress!, nodeCount * 6 * 4) }

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return JSONLoadResult(bytesRead: data.count, fileNodeCount: fileNC,
                              fileTicks: fileTicks, elapsedMs: elapsed)
    }

    // MARK: - CSV save (two-file)

    public static func saveCSV(
        engine: DagDBEngine,
        nodeCount: Int,
        dir: String
    ) throws -> (nodesBytes: Int, edgesBytes: Int, elapsedMs: Double) {
        let t0 = Date()

        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        let rank = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: nodeCount)
        let truth = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        let type = engine.nodeTypeBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        let low = engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
        let high = engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
        let nb = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)

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

        let nodesData = nodesCSV.data(using: .utf8)!
        let edgesData = edgesCSV.data(using: .utf8)!
        try atomicWrite(data: nodesData, path: dir + "/nodes.csv")
        try atomicWrite(data: edgesData, path: dir + "/edges.csv")

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (nodesData.count, edgesData.count, elapsed)
    }

    // MARK: - CSV load (two-file)

    public struct CSVLoadResult {
        public let nodesParsed: Int
        public let edgesParsed: Int
        public let elapsedMs: Double
    }

    public static func loadCSV(
        engine: DagDBEngine,
        nodeCount: Int,
        dir: String,
        validate: Bool = true
    ) throws -> CSVLoadResult {
        let t0 = Date()

        guard let nodesRaw = try? String(contentsOfFile: dir + "/nodes.csv", encoding: .utf8) else {
            throw JSONError.ioFailure("missing nodes.csv")
        }
        guard let edgesRaw = try? String(contentsOfFile: dir + "/edges.csv", encoding: .utf8) else {
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

        if validate {
            for dst in 0..<nodeCount {
                var seen = Set<Int32>()
                for d in 0..<6 {
                    let src = nb[dst * 6 + d]
                    if src < 0 { continue }
                    if src >= Int32(nodeCount) {
                        throw JSONError.invalidFormat("node \(dst): src \(src) out of range")
                    }
                    if Int(src) == dst {
                        throw JSONError.invalidFormat("node \(dst): self-loop")
                    }
                    if rank[Int(src)] <= rank[dst] {
                        throw JSONError.invalidFormat("node \(dst): src rank \(rank[Int(src)]) must be > dst rank \(rank[dst])")
                    }
                    if seen.contains(src) {
                        throw JSONError.invalidFormat("node \(dst): duplicate edge")
                    }
                    seen.insert(src)
                }
            }
        }

        rank.withUnsafeBufferPointer  { memcpy(engine.rankBuf.contents(),       $0.baseAddress!, nodeCount * 8) }
        truth.withUnsafeBufferPointer { memcpy(engine.truthStateBuf.contents(), $0.baseAddress!, nodeCount) }
        type.withUnsafeBufferPointer  { memcpy(engine.nodeTypeBuf.contents(),   $0.baseAddress!, nodeCount) }
        low.withUnsafeBufferPointer   { memcpy(engine.lut6LowBuf.contents(),    $0.baseAddress!, nodeCount * 4) }
        high.withUnsafeBufferPointer  { memcpy(engine.lut6HighBuf.contents(),   $0.baseAddress!, nodeCount * 4) }
        nb.withUnsafeBufferPointer    { memcpy(engine.neighborsBuf.contents(),  $0.baseAddress!, nodeCount * 6 * 4) }

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return CSVLoadResult(nodesParsed: nodesCount, edgesParsed: edgesCount, elapsedMs: elapsed)
    }

    // MARK: - Atomic write (shared with DagDBSnapshot's discipline)

    private static func atomicWrite(data: Data, path: String) throws {
        // NSData .atomic does temp + rename to the target path itself. We then
        // F_FULLFSYNC both the file and the containing directory for Apple SSD
        // durability (matches DagDBSnapshot's discipline).
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])

        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            _ = fcntl(fd, F_FULLFSYNC)
            close(fd)
        }
        let dir = (path as NSString).deletingLastPathComponent
        let dirFd = open(dir, O_RDONLY)
        if dirFd >= 0 {
            _ = fcntl(dirFd, F_FULLFSYNC)
            close(dirFd)
        }
    }
}
