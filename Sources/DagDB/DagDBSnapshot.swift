/// DagDBSnapshot — Full-state binary serialization for DagDB.
///
/// Dumps every GPU buffer in Morton order to a single file. On load,
/// reads bytes directly back into the mmap'd shared-memory buffers.
/// No compression, no deltas — this is the Tier-1 bulk path.
///
/// Format ("DAGS" v1):
///   Header (32 bytes):
///     magic       [4]  = "DAGS"
///     version     u32  = 1
///     nodeCount   u32
///     gridW       u32
///     gridH       u32
///     tickCount   u32
///     reserved    u32  = 0
///     reserved2   u32  = 0
///   Body:
///     rank        [N]      UInt8
///     truth       [N]      UInt8
///     nodeType    [N]      UInt8
///     lut6Low     [N * 4]  UInt32
///     lut6High    [N * 4]  UInt32
///     neighbors   [N * 24] Int32 × 6
///
///   Total: 33·N + 32 bytes.
///   N = 10M → 330 MB. One fwrite / one fread. Zero parse cost.

import Foundation
import Metal

public enum DagDBSnapshot {

    public static let magic: [UInt8] = [0x44, 0x41, 0x47, 0x53]  // "DAGS"
    public static let version: UInt32 = 1
    public static let headerSize: Int = 32

    public enum SnapError: Error, CustomStringConvertible {
        case invalidMagic
        case unsupportedVersion(UInt32)
        case nodeCountMismatch(file: Int, engine: Int)
        case gridMismatch(fileW: Int, fileH: Int, engineW: Int, engineH: Int)
        case ioFailure(String)
        case validationFailed(String)

        public var description: String {
            switch self {
            case .invalidMagic: return "invalid magic (expected 'DAGS')"
            case .unsupportedVersion(let v): return "unsupported version: \(v)"
            case .nodeCountMismatch(let f, let e): return "nodeCount mismatch: file=\(f) engine=\(e)"
            case .gridMismatch(let fw, let fh, let ew, let eh): return "grid mismatch: file=\(fw)x\(fh) engine=\(ew)x\(eh)"
            case .ioFailure(let s): return "io: \(s)"
            case .validationFailed(let s): return "validation: \(s)"
            }
        }
    }

    public struct LoadResult {
        public let bytesRead: Int
        public let fileNodeCount: Int
        public let fileTicks: UInt32
        public let elapsedMs: Double
    }

    // MARK: - Validator (run on buffers currently in engine)

    /// Verify the DAG invariants on the engine's live buffers.
    /// Returns nil if valid, or an error describing the first violation.
    public static func validate(engine: DagDBEngine, nodeCount: Int) -> String? {
        let rank = engine.rankBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        let nb   = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)

        for dst in 0..<nodeCount {
            var seen = Set<Int32>()
            for d in 0..<6 {
                let src = nb[dst * 6 + d]
                if src < 0 { continue }
                if src >= Int32(nodeCount) {
                    return "node \(dst) slot \(d): src \(src) out of range"
                }
                if Int(src) == dst {
                    return "node \(dst) slot \(d): self-loop"
                }
                if rank[Int(src)] <= rank[dst] {
                    return "node \(dst) slot \(d): src rank \(rank[Int(src)]) must be > dst rank \(rank[dst])"
                }
                if seen.contains(src) {
                    return "node \(dst): duplicate edge from \(src)"
                }
                seen.insert(src)
            }
        }
        return nil
    }

    // MARK: - Save

    /// Dump all engine buffers to a single binary file.
    public static func save(
        engine: DagDBEngine,
        nodeCount: Int,
        gridW: Int,
        gridH: Int,
        tickCount: UInt32,
        path: String
    ) throws -> (bytesWritten: Int, elapsedMs: Double) {
        let t0 = Date()

        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw SnapError.ioFailure("open: \(path)")
        }
        defer { try? handle.close() }

        // Header
        var header = Data(capacity: headerSize)
        header.append(contentsOf: magic)
        appendU32(&header, version)
        appendU32(&header, UInt32(nodeCount))
        appendU32(&header, UInt32(gridW))
        appendU32(&header, UInt32(gridH))
        appendU32(&header, tickCount)
        appendU32(&header, 0)
        appendU32(&header, 0)
        handle.write(header)

        // Body — direct from GPU buffers (UMA shared memory)
        let rankBytes   = engine.rankBuf.contents()
        let truthBytes  = engine.truthStateBuf.contents()
        let typeBytes   = engine.nodeTypeBuf.contents()
        let lowBytes    = engine.lut6LowBuf.contents()
        let highBytes   = engine.lut6HighBuf.contents()
        let nbBytes     = engine.neighborsBuf.contents()

        handle.write(Data(bytesNoCopy: rankBytes,  count: nodeCount,          deallocator: .none))
        handle.write(Data(bytesNoCopy: truthBytes, count: nodeCount,          deallocator: .none))
        handle.write(Data(bytesNoCopy: typeBytes,  count: nodeCount,          deallocator: .none))
        handle.write(Data(bytesNoCopy: lowBytes,   count: nodeCount * 4,      deallocator: .none))
        handle.write(Data(bytesNoCopy: highBytes,  count: nodeCount * 4,      deallocator: .none))
        handle.write(Data(bytesNoCopy: nbBytes,    count: nodeCount * 6 * 4,  deallocator: .none))

        // Body = rank(N) + truth(N) + type(N) + lut_low(4N) + lut_high(4N) + neighbors(24N) = 35N
        let total = headerSize + nodeCount * 35
        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (total, elapsed)
    }

    // MARK: - Load

    /// Restore all engine buffers from a snapshot file. nodeCount must match engine.
    /// - Parameter validate: run DAG-invariant check after memcpy (O(N), CPU).
    public static func load(
        engine: DagDBEngine,
        nodeCount: Int,
        gridW: Int,
        gridH: Int,
        path: String,
        validate: Bool = true
    ) throws -> LoadResult {
        let t0 = Date()

        guard FileManager.default.fileExists(atPath: path) else {
            throw SnapError.ioFailure("file not found: \(path)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        guard data.count >= headerSize else {
            throw SnapError.ioFailure("file too short: \(data.count) bytes")
        }

        // Header
        let m = [UInt8](data[0..<4])
        guard m == magic else { throw SnapError.invalidMagic }
        let ver = readU32(data, 4)
        guard ver == version else { throw SnapError.unsupportedVersion(ver) }
        let fileNC    = Int(readU32(data, 8))
        let fileGW    = Int(readU32(data, 12))
        let fileGH    = Int(readU32(data, 16))
        let fileTicks = readU32(data, 20)

        guard fileNC == nodeCount else {
            throw SnapError.nodeCountMismatch(file: fileNC, engine: nodeCount)
        }
        guard fileGW == gridW && fileGH == gridH else {
            throw SnapError.gridMismatch(fileW: fileGW, fileH: fileGH, engineW: gridW, engineH: gridH)
        }

        // Validate the file bytes BEFORE writing to live buffers.
        // This way a malformed snapshot cannot corrupt a running graph.
        if validate {
            if let violation = validateBytes(data: data, nodeCount: nodeCount) {
                throw SnapError.validationFailed(violation)
            }
        }

        // Body copy into GPU buffers
        var off = headerSize
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!

            memcpy(engine.rankBuf.contents(),       base.advanced(by: off), nodeCount);             off += nodeCount
            memcpy(engine.truthStateBuf.contents(), base.advanced(by: off), nodeCount);             off += nodeCount
            memcpy(engine.nodeTypeBuf.contents(),   base.advanced(by: off), nodeCount);             off += nodeCount
            memcpy(engine.lut6LowBuf.contents(),    base.advanced(by: off), nodeCount * 4);         off += nodeCount * 4
            memcpy(engine.lut6HighBuf.contents(),   base.advanced(by: off), nodeCount * 4);         off += nodeCount * 4
            memcpy(engine.neighborsBuf.contents(),  base.advanced(by: off), nodeCount * 6 * 4);     off += nodeCount * 6 * 4
        }

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return LoadResult(bytesRead: off, fileNodeCount: fileNC, fileTicks: fileTicks, elapsedMs: elapsed)
    }

    // MARK: - Morton export (raw per-buffer files for Tier-1 interop)

    public static func exportMorton(
        engine: DagDBEngine,
        nodeCount: Int,
        dir: String
    ) throws -> (bytesWritten: Int, elapsedMs: Double) {
        let t0 = Date()

        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        func writeRaw(_ name: String, _ ptr: UnsafeMutableRawPointer, _ size: Int) throws {
            let path = "\(dir)/\(name)"
            FileManager.default.createFile(atPath: path, contents: nil)
            guard let h = FileHandle(forWritingAtPath: path) else {
                throw SnapError.ioFailure("open: \(path)")
            }
            defer { try? h.close() }
            h.write(Data(bytesNoCopy: ptr, count: size, deallocator: .none))
        }

        try writeRaw("rank.bin",      engine.rankBuf.contents(),       nodeCount)
        try writeRaw("truth.bin",     engine.truthStateBuf.contents(), nodeCount)
        try writeRaw("nodeType.bin",  engine.nodeTypeBuf.contents(),   nodeCount)
        try writeRaw("lut_low.bin",   engine.lut6LowBuf.contents(),    nodeCount * 4)
        try writeRaw("lut_high.bin",  engine.lut6HighBuf.contents(),   nodeCount * 4)
        try writeRaw("neighbors.bin", engine.neighborsBuf.contents(),  nodeCount * 6 * 4)

        let total = nodeCount * 35
        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (total, elapsed)
    }

    /// Inverse of exportMorton. Reads the 6 per-buffer files into staging arrays,
    /// validates, and commits to engine only if valid.
    public static func importMorton(
        engine: DagDBEngine,
        nodeCount: Int,
        dir: String,
        validate: Bool = true
    ) throws -> (bytesRead: Int, elapsedMs: Double) {
        let t0 = Date()

        func readStaged(_ name: String, _ expectedSize: Int) throws -> Data {
            let path = "\(dir)/\(name)"
            guard FileManager.default.fileExists(atPath: path) else {
                throw SnapError.ioFailure("missing: \(path)")
            }
            let d = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
            guard d.count == expectedSize else {
                throw SnapError.ioFailure("\(name): expected \(expectedSize) bytes, got \(d.count)")
            }
            return d
        }

        let rankData = try readStaged("rank.bin",      nodeCount)
        let truthData = try readStaged("truth.bin",    nodeCount)
        let typeData = try readStaged("nodeType.bin",  nodeCount)
        let lowData  = try readStaged("lut_low.bin",   nodeCount * 4)
        let highData = try readStaged("lut_high.bin",  nodeCount * 4)
        let nbData   = try readStaged("neighbors.bin", nodeCount * 6 * 4)

        if validate {
            let violation = rankData.withUnsafeBytes { (rawRank: UnsafeRawBufferPointer) -> String? in
                nbData.withUnsafeBytes { (rawNb: UnsafeRawBufferPointer) -> String? in
                    let rank = rawRank.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let nb   = rawNb.baseAddress!.assumingMemoryBound(to: Int32.self)
                    for dst in 0..<nodeCount {
                        var slotSrcs = [Int32]()
                        slotSrcs.reserveCapacity(6)
                        for d in 0..<6 {
                            let src = nb[dst * 6 + d]
                            if src < 0 { continue }
                            if src >= Int32(nodeCount) { return "node \(dst) slot \(d): src \(src) out of range" }
                            if Int(src) == dst         { return "node \(dst) slot \(d): self-loop" }
                            if rank[Int(src)] <= rank[dst] {
                                return "node \(dst) slot \(d): src rank \(rank[Int(src)]) must be > dst rank \(rank[dst])"
                            }
                            if slotSrcs.contains(src)  { return "node \(dst): duplicate edge from \(src)" }
                            slotSrcs.append(src)
                        }
                    }
                    return nil
                }
            }
            if let v = violation { throw SnapError.validationFailed(v) }
        }

        // Commit — all validations passed
        rankData.withUnsafeBytes  { memcpy(engine.rankBuf.contents(),       $0.baseAddress!, nodeCount) }
        truthData.withUnsafeBytes { memcpy(engine.truthStateBuf.contents(), $0.baseAddress!, nodeCount) }
        typeData.withUnsafeBytes  { memcpy(engine.nodeTypeBuf.contents(),   $0.baseAddress!, nodeCount) }
        lowData.withUnsafeBytes   { memcpy(engine.lut6LowBuf.contents(),    $0.baseAddress!, nodeCount * 4) }
        highData.withUnsafeBytes  { memcpy(engine.lut6HighBuf.contents(),   $0.baseAddress!, nodeCount * 4) }
        nbData.withUnsafeBytes    { memcpy(engine.neighborsBuf.contents(),  $0.baseAddress!, nodeCount * 6 * 4) }

        let total = nodeCount * 35
        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (total, elapsed)
    }

    // MARK: - Byte-level validator (checks a file's bytes before loading)

    /// Check DAG invariants by scanning the body bytes directly.
    /// Rank layout: offset 32..32+N. Neighbors layout: offset 32 + 3N + 8N = 32 + 11N, length 24N.
    private static func validateBytes(data: Data, nodeCount: Int) -> String? {
        let rankOff = headerSize
        let nbOff   = headerSize + 3 * nodeCount + 8 * nodeCount  // rank + truth + type + 2*lut

        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            let base = raw.baseAddress!
            let rank = base.advanced(by: rankOff).assumingMemoryBound(to: UInt8.self)
            let nb   = base.advanced(by: nbOff  ).assumingMemoryBound(to: Int32.self)

            for dst in 0..<nodeCount {
                var slotSrcs = [Int32]()
                slotSrcs.reserveCapacity(6)
                for d in 0..<6 {
                    let src = nb[dst * 6 + d]
                    if src < 0 { continue }
                    if src >= Int32(nodeCount) {
                        return "node \(dst) slot \(d): src \(src) out of range"
                    }
                    if Int(src) == dst {
                        return "node \(dst) slot \(d): self-loop"
                    }
                    if rank[Int(src)] <= rank[dst] {
                        return "node \(dst) slot \(d): src rank \(rank[Int(src)]) must be > dst rank \(rank[dst])"
                    }
                    if slotSrcs.contains(src) {
                        return "node \(dst): duplicate edge from \(src)"
                    }
                    slotSrcs.append(src)
                }
            }
            return nil
        }
    }

    // MARK: - Helpers

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        var v = value
        data.append(Data(bytes: &v, count: 4))
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        return UInt32(data[offset])
             | UInt32(data[offset + 1]) << 8
             | UInt32(data[offset + 2]) << 16
             | UInt32(data[offset + 3]) << 24
    }
}
