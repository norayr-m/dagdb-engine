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

    public enum SnapError: Error {
        case invalidMagic
        case unsupportedVersion(UInt32)
        case nodeCountMismatch(file: Int, engine: Int)
        case ioFailure(String)
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
    public static func load(
        engine: DagDBEngine,
        nodeCount: Int,
        path: String
    ) throws -> (bytesRead: Int, fileNodeCount: Int, fileTicks: UInt32, elapsedMs: Double) {
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
        // skip gridW (12), gridH (16)
        let fileTicks = readU32(data, 20)

        guard fileNC == nodeCount else {
            throw SnapError.nodeCountMismatch(file: fileNC, engine: nodeCount)
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
        return (off, fileNC, fileTicks, elapsed)
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
