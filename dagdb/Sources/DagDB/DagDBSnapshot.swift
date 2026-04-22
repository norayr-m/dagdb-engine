/// DagDBSnapshot — Full-state binary serialization for DagDB.
///
/// Dumps every GPU buffer in Morton order. Optional zlib compression
/// of the body. Validated before memcpy so bad files can't corrupt live state.
///
/// Format (32-byte header):
///     magic       [4]  = "DAGS"
///     version     u32  (1 = u8 rank, 2 = u32 rank, 3 = u64 rank)
///     nodeCount   u32
///     gridW       u32
///     gridH       u32
///     tickCount   u32
///     flags       u32  (bit 0 = body is zlib-compressed)
///     bodyBytes   u32  (size of the body on disk — used when compressed)
///
/// Body — size depends on version. Layout at each version:
///
///   v1 (35·N bytes): rank[N] UInt8 · truth[N] UInt8 · nodeType[N] UInt8 ·
///                    lut6Low[N·4] · lut6High[N·4] · neighbors[N·24]
///   v2 (38·N bytes): rank[N·4] UInt32 · truth · type · luts · neighbors
///   v3 (42·N bytes): rank[N·8] UInt64 · truth · type · luts · neighbors
///
/// Save always writes v3. Load accepts v1, v2, v3 and widens rank on read.
///
/// N = 10M at v3 → 420 MB raw. With zlib the body typically drops to
/// 20-30 % because the neighbors table is mostly -1 padding.

import Foundation
import Metal
import Compression

public enum DagDBSnapshot {

    public static let magic: [UInt8] = [0x44, 0x41, 0x47, 0x53]  // "DAGS"
    /// v1 = u8 rank (pre-u32-widen). v2 = u32 rank (2026-04-20). v3 = u64
    /// rank (2026-04-21, for the 10^11 laptop target). Load accepts v1, v2,
    /// v3; save always writes v3.
    public static let versionV1: UInt32 = 1
    public static let versionV2: UInt32 = 2
    public static let versionV3: UInt32 = 3
    public static let version: UInt32 = versionV3
    public static let headerSize: Int = 32

    public struct Flags: OptionSet {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let compressed = Flags(rawValue: 1 << 0)
    }

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
        let rank = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: nodeCount)
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
    /// - Parameter compressed: zlib-compress the body. Typically ~25% of raw size.
    ///
    /// Durability: writes to `path.tmp`, flushes with F_FULLFSYNC, then renames
    /// atomically over `path`. A kill -9 at any point leaves either the pre-save
    /// state (if rename didn't happen) or the complete new state — never a
    /// truncated file. The parent directory is fsync'd so the rename survives a
    /// power-loss.
    public static func save(
        engine: DagDBEngine,
        nodeCount: Int,
        gridW: Int,
        gridH: Int,
        tickCount: UInt32,
        path: String,
        compressed: Bool = false
    ) throws -> (bytesWritten: Int, uncompressedBodyBytes: Int, elapsedMs: Double) {
        let t0 = Date()

        let tmpPath = path + ".tmp"
        FileManager.default.createFile(atPath: tmpPath, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: tmpPath) else {
            throw SnapError.ioFailure("open: \(tmpPath)")
        }
        var committed = false
        defer {
            try? handle.close()
            if !committed {
                try? FileManager.default.removeItem(atPath: tmpPath)
            }
        }

        // v3 body: rank(8N) + truth(N) + type(N) + low(4N) + high(4N) + neighbors(24N) = 42N
        let uncompressedBodySize = nodeCount * 42

        // Body source — direct from GPU buffers (UMA shared memory)
        let rankBytes   = engine.rankBuf.contents()
        let truthBytes  = engine.truthStateBuf.contents()
        let typeBytes   = engine.nodeTypeBuf.contents()
        let lowBytes    = engine.lut6LowBuf.contents()
        let highBytes   = engine.lut6HighBuf.contents()
        let nbBytes     = engine.neighborsBuf.contents()

        // When compressing, gather body into a contiguous buffer first.
        // When not, stream directly to disk from UMA (fastest path).
        var flags = Flags()
        var bodyBytes: Int

        if compressed {
            flags.insert(.compressed)
            // Gather uncompressed body
            var buf = Data(count: uncompressedBodySize)
            buf.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                var off = 0
                memcpy(dst.baseAddress!.advanced(by: off), rankBytes,  nodeCount * 8);        off += nodeCount * 8
                memcpy(dst.baseAddress!.advanced(by: off), truthBytes, nodeCount);            off += nodeCount
                memcpy(dst.baseAddress!.advanced(by: off), typeBytes,  nodeCount);            off += nodeCount
                memcpy(dst.baseAddress!.advanced(by: off), lowBytes,   nodeCount * 4);        off += nodeCount * 4
                memcpy(dst.baseAddress!.advanced(by: off), highBytes,  nodeCount * 4);        off += nodeCount * 4
                memcpy(dst.baseAddress!.advanced(by: off), nbBytes,    nodeCount * 6 * 4)
            }
            let compressed = zlibCompress(buf)
            bodyBytes = compressed.count

            var header = buildHeader(nodeCount: nodeCount, gridW: gridW, gridH: gridH,
                                     tickCount: tickCount, flags: flags, bodyBytes: bodyBytes)
            handle.write(header)
            handle.write(compressed)
            _ = header // keep explicit for clarity
        } else {
            bodyBytes = uncompressedBodySize
            let header = buildHeader(nodeCount: nodeCount, gridW: gridW, gridH: gridH,
                                     tickCount: tickCount, flags: flags, bodyBytes: bodyBytes)
            handle.write(header)

            handle.write(Data(bytesNoCopy: rankBytes,  count: nodeCount * 8,      deallocator: .none))
            handle.write(Data(bytesNoCopy: truthBytes, count: nodeCount,          deallocator: .none))
            handle.write(Data(bytesNoCopy: typeBytes,  count: nodeCount,          deallocator: .none))
            handle.write(Data(bytesNoCopy: lowBytes,   count: nodeCount * 4,      deallocator: .none))
            handle.write(Data(bytesNoCopy: highBytes,  count: nodeCount * 4,      deallocator: .none))
            handle.write(Data(bytesNoCopy: nbBytes,    count: nodeCount * 6 * 4,  deallocator: .none))
        }

        // F_FULLFSYNC: macOS-specific, forces the drive to flush its own cache.
        // Plain fsync only flushes OS buffers, which is insufficient for durability
        // on Apple SSDs (see Apple TN3154 / fcntl(2)).
        let fd = handle.fileDescriptor
        if fcntl(fd, F_FULLFSYNC) != 0 {
            if fsync(fd) != 0 {
                throw SnapError.ioFailure("fsync tmp: errno=\(errno)")
            }
        }
        try? handle.close()

        // Atomic replace.
        do {
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: path),
                withItemAt: URL(fileURLWithPath: tmpPath)
            )
        } catch {
            // Destination may not exist yet — fall back to rename.
            if (try? FileManager.default.attributesOfItem(atPath: path)) != nil {
                throw SnapError.ioFailure("replace: \(error)")
            }
            do {
                try FileManager.default.moveItem(atPath: tmpPath, toPath: path)
            } catch {
                throw SnapError.ioFailure("rename: \(error)")
            }
        }
        committed = true

        // fsync the containing directory so the rename itself is durable.
        let dirPath = (path as NSString).deletingLastPathComponent
        let dirFd = open(dirPath, O_RDONLY)
        if dirFd >= 0 {
            _ = fcntl(dirFd, F_FULLFSYNC)
            close(dirFd)
        }

        let total = headerSize + bodyBytes
        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (total, uncompressedBodySize, elapsed)
    }

    private static func buildHeader(
        nodeCount: Int, gridW: Int, gridH: Int,
        tickCount: UInt32, flags: Flags, bodyBytes: Int
    ) -> Data {
        var header = Data(capacity: headerSize)
        header.append(contentsOf: magic)
        appendU32(&header, version)
        appendU32(&header, UInt32(nodeCount))
        appendU32(&header, UInt32(gridW))
        appendU32(&header, UInt32(gridH))
        appendU32(&header, tickCount)
        appendU32(&header, flags.rawValue)
        appendU32(&header, UInt32(bodyBytes))
        return header
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
        guard ver == versionV1 || ver == versionV2 || ver == versionV3 else {
            throw SnapError.unsupportedVersion(ver)
        }
        let fileNC    = Int(readU32(data, 8))
        let fileGW    = Int(readU32(data, 12))
        let fileGH    = Int(readU32(data, 16))
        let fileTicks = readU32(data, 20)
        let flags     = Flags(rawValue: readU32(data, 24))
        let bodyBytes = Int(readU32(data, 28))

        guard fileNC == nodeCount else {
            throw SnapError.nodeCountMismatch(file: fileNC, engine: nodeCount)
        }
        guard fileGW == gridW && fileGH == gridH else {
            throw SnapError.gridMismatch(fileW: fileGW, fileH: fileGH, engineW: gridW, engineH: gridH)
        }

        // Rank width per version: v1 = 1 byte (u8), v2 = 4 (u32), v3 = 8 (u64).
        let rankBytesPerNode: Int
        switch ver {
        case versionV1: rankBytesPerNode = 1
        case versionV2: rankBytesPerNode = 4
        case versionV3: rankBytesPerNode = 8
        default:        rankBytesPerNode = 1  // unreachable (guarded above)
        }
        // body = rank + truth(1) + type(1) + lut_low(4) + lut_high(4) + neighbors(24)
        let uncompressedBodySize = nodeCount * (34 + rankBytesPerNode)

        // Resolve the body bytes — either the raw slice or the zlib-decoded buffer.
        let bodyData: Data
        if flags.contains(.compressed) {
            // bodyBytes is the compressed size on disk. Slice and decompress.
            let compressedSlice = data.subdata(in: headerSize..<(headerSize + bodyBytes))
            bodyData = zlibDecompress(compressedSlice, expectedSize: uncompressedBodySize)
            guard bodyData.count == uncompressedBodySize else {
                throw SnapError.ioFailure("decompressed body size \(bodyData.count) != expected \(uncompressedBodySize)")
            }
        } else {
            // v1 backward compat: files written before the flags/bodyBytes fields existed
            // have bodyBytes = 0 in the header (those bytes were reserved = 0). Fall back
            // to computing from nodeCount.
            let effectiveBody = bodyBytes == 0 ? uncompressedBodySize : bodyBytes
            guard effectiveBody == uncompressedBodySize else {
                throw SnapError.ioFailure("body size \(effectiveBody) != expected \(uncompressedBodySize)")
            }
            bodyData = data.subdata(in: headerSize..<(headerSize + effectiveBody))
        }

        // Validate decoded bytes BEFORE writing to live buffers.
        // The body here has the same layout as an uncompressed body.
        if validate {
            if let violation = validateDecodedBody(
                body: bodyData, nodeCount: nodeCount, rankBytesPerNode: rankBytesPerNode
            ) {
                throw SnapError.validationFailed(violation)
            }
        }

        // Commit into GPU buffers (rank widens to u64 on every load path)
        bodyData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!
            var off = 0
            let dstU64 = engine.rankBuf.contents().assumingMemoryBound(to: UInt64.self)
            switch ver {
            case versionV1:
                let srcU8 = base.advanced(by: off).assumingMemoryBound(to: UInt8.self)
                for i in 0..<nodeCount { dstU64[i] = UInt64(srcU8[i]) }
                off += nodeCount
            case versionV2:
                let srcU32 = base.advanced(by: off).assumingMemoryBound(to: UInt32.self)
                for i in 0..<nodeCount { dstU64[i] = UInt64(srcU32[i]) }
                off += nodeCount * 4
            default:  // v3
                memcpy(engine.rankBuf.contents(), base.advanced(by: off), nodeCount * 8)
                off += nodeCount * 8
            }
            memcpy(engine.truthStateBuf.contents(), base.advanced(by: off), nodeCount);             off += nodeCount
            memcpy(engine.nodeTypeBuf.contents(),   base.advanced(by: off), nodeCount);             off += nodeCount
            memcpy(engine.lut6LowBuf.contents(),    base.advanced(by: off), nodeCount * 4);         off += nodeCount * 4
            memcpy(engine.lut6HighBuf.contents(),   base.advanced(by: off), nodeCount * 4);         off += nodeCount * 4
            memcpy(engine.neighborsBuf.contents(),  base.advanced(by: off), nodeCount * 6 * 4)
        }

        let totalRead = headerSize + (flags.contains(.compressed) ? bodyBytes : uncompressedBodySize)
        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return LoadResult(bytesRead: totalRead, fileNodeCount: fileNC, fileTicks: fileTicks, elapsedMs: elapsed)
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

        // v3 Morton export: rank is now 8 bytes per node (u64).
        try writeRaw("rank.bin",      engine.rankBuf.contents(),       nodeCount * 8)
        try writeRaw("truth.bin",     engine.truthStateBuf.contents(), nodeCount)
        try writeRaw("nodeType.bin",  engine.nodeTypeBuf.contents(),   nodeCount)
        try writeRaw("lut_low.bin",   engine.lut6LowBuf.contents(),    nodeCount * 4)
        try writeRaw("lut_high.bin",  engine.lut6HighBuf.contents(),   nodeCount * 4)
        try writeRaw("neighbors.bin", engine.neighborsBuf.contents(),  nodeCount * 6 * 4)

        let total = nodeCount * 42
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

        let rankData = try readStaged("rank.bin",      nodeCount * 8)
        let truthData = try readStaged("truth.bin",    nodeCount)
        let typeData = try readStaged("nodeType.bin",  nodeCount)
        let lowData  = try readStaged("lut_low.bin",   nodeCount * 4)
        let highData = try readStaged("lut_high.bin",  nodeCount * 4)
        let nbData   = try readStaged("neighbors.bin", nodeCount * 6 * 4)

        if validate {
            let violation = rankData.withUnsafeBytes { (rawRank: UnsafeRawBufferPointer) -> String? in
                nbData.withUnsafeBytes { (rawNb: UnsafeRawBufferPointer) -> String? in
                    let rank = rawRank.baseAddress!.assumingMemoryBound(to: UInt64.self)
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
        rankData.withUnsafeBytes  { memcpy(engine.rankBuf.contents(),       $0.baseAddress!, nodeCount * 8) }
        truthData.withUnsafeBytes { memcpy(engine.truthStateBuf.contents(), $0.baseAddress!, nodeCount) }
        typeData.withUnsafeBytes  { memcpy(engine.nodeTypeBuf.contents(),   $0.baseAddress!, nodeCount) }
        lowData.withUnsafeBytes   { memcpy(engine.lut6LowBuf.contents(),    $0.baseAddress!, nodeCount * 4) }
        highData.withUnsafeBytes  { memcpy(engine.lut6HighBuf.contents(),   $0.baseAddress!, nodeCount * 4) }
        nbData.withUnsafeBytes    { memcpy(engine.neighborsBuf.contents(),  $0.baseAddress!, nodeCount * 6 * 4) }

        let total = nodeCount * 42
        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (total, elapsed)
    }

    // MARK: - Byte-level validator (checks decoded body bytes before committing)

    /// Check DAG invariants by scanning the body bytes directly.
    /// v1 body: rank(N)  + truth(N) + type(N) + lut_low(4N) + lut_high(4N) + neighbors(24N).
    /// v2 body: rank(4N) + truth(N) + type(N) + lut_low(4N) + lut_high(4N) + neighbors(24N).
    /// v3 body: rank(8N) + truth(N) + type(N) + lut_low(4N) + lut_high(4N) + neighbors(24N).
    /// `rankBytesPerNode` is 1 / 4 / 8 for v1 / v2 / v3.
    private static func validateDecodedBody(
        body: Data, nodeCount: Int, rankBytesPerNode: Int
    ) -> String? {
        let rankOff = 0
        let nbOff   = (rankBytesPerNode + 2) * nodeCount + 8 * nodeCount

        return body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            let base = raw.baseAddress!
            let nb   = base.advanced(by: nbOff).assumingMemoryBound(to: Int32.self)

            // Rank read, widened to u64 regardless of on-disk width.
            func rankAt(_ i: Int) -> UInt64 {
                switch rankBytesPerNode {
                case 8:
                    return base.advanced(by: rankOff + i * 8)
                        .assumingMemoryBound(to: UInt64.self).pointee
                case 4:
                    return UInt64(base.advanced(by: rankOff + i * 4)
                        .assumingMemoryBound(to: UInt32.self).pointee)
                default:  // 1
                    return UInt64(base.advanced(by: rankOff + i)
                        .assumingMemoryBound(to: UInt8.self).pointee)
                }
            }

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
                    let srcRank = rankAt(Int(src))
                    let dstRank = rankAt(dst)
                    if srcRank <= dstRank {
                        return "node \(dst) slot \(d): src rank \(srcRank) must be > dst rank \(dstRank)"
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

    // MARK: - Compression

    /// Compress a byte array with zlib. Returns a fresh Data.
    static func zlibCompress(_ input: Data) -> Data {
        let bufSize = max(input.count, 64)
        var output = [UInt8](repeating: 0, count: bufSize)
        let sz = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            return compression_encode_buffer(
                &output, bufSize,
                src.baseAddress!.assumingMemoryBound(to: UInt8.self), input.count,
                nil, COMPRESSION_ZLIB
            )
        }
        return Data(output[0..<sz])
    }

    /// Decompress a zlib-compressed byte array of known uncompressed size.
    static func zlibDecompress(_ input: Data, expectedSize: Int) -> Data {
        var output = [UInt8](repeating: 0, count: expectedSize)
        let sz = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            return compression_decode_buffer(
                &output, expectedSize,
                src.baseAddress!.assumingMemoryBound(to: UInt8.self), input.count,
                nil, COMPRESSION_ZLIB
            )
        }
        return Data(output[0..<sz])
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
