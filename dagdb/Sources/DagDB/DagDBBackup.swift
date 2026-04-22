/// DagDBBackup — incremental backup chain for DagDB.
///
/// A chain lives in a single directory:
///     <dir>/base.dags        full snapshot at chain start
///     <dir>/00001.diff       XOR diff from tip-after-base to engine state
///     <dir>/00002.diff       XOR diff from tip-after-00001 to engine state
///     ...
///
/// Each .diff is the XOR of the six engine buffers (rank, truth, nodeType,
/// lut6Low, lut6High, neighbors) against the previous tip, zlib-compressed
/// per buffer. Since most DagDB edits touch a handful of nodes, diffs are
/// tiny — usually far under 1% of the base.
///
/// Typical workflow:
///     DagDBBackup.initializeChain(engine:, ..., dir:)   // snapshot base
///     // ... edit engine ...
///     DagDBBackup.appendDiff(engine:, ..., dir:)         // append diff
///     // ... more edits ...
///     DagDBBackup.appendDiff(engine:, ..., dir:)
///     DagDBBackup.restore(engine: other, ..., dir:)       // replay chain
///     DagDBBackup.compact(engine: tmp, ..., dir:)         // fold diffs into new base
///
/// All writes use the atomic-save + F_FULLFSYNC discipline from DagDBSnapshot.

import Foundation

public enum DagDBBackup {

    public enum BackupError: Error, CustomStringConvertible {
        case noBase(String)
        case invalidDiff(String)
        case shapeMismatch(String)
        case ioFailure(String)

        public var description: String {
            switch self {
            case .noBase(let s):        return "no base: \(s)"
            case .invalidDiff(let s):   return "invalid diff: \(s)"
            case .shapeMismatch(let s): return "shape: \(s)"
            case .ioFailure(let s):     return "io: \(s)"
            }
        }
    }

    public static let diffMagic: [UInt8] = [0x44, 0x41, 0x47, 0x44]  // "DAGD"
    public static let diffVersion: UInt32 = 1
    public static let diffHeaderSize: Int = 16

    public struct ChainInfo {
        public let baseExists: Bool
        public let diffCount: Int
        public let diffPaths: [String]
        public let baseSizeBytes: Int
        public let totalDiffBytes: Int
    }

    // MARK: - Chain inspection

    public static func info(dir: String) throws -> ChainInfo {
        let fm = FileManager.default
        let base = dir + "/base.dags"
        let baseExists = fm.fileExists(atPath: base)
        let baseSize = baseExists
            ? ((try? fm.attributesOfItem(atPath: base)[.size] as? Int) ?? 0)
            : 0

        let contents = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        let diffs = contents
            .filter { $0.hasSuffix(".diff") }
            .sorted()
            .map { dir + "/" + $0 }
        var totalDiffBytes = 0
        for p in diffs {
            totalDiffBytes += (try? fm.attributesOfItem(atPath: p)[.size] as? Int) ?? 0
        }
        return ChainInfo(
            baseExists: baseExists, diffCount: diffs.count,
            diffPaths: diffs, baseSizeBytes: baseSize,
            totalDiffBytes: totalDiffBytes
        )
    }

    // MARK: - Initialize chain

    public static func initializeChain(
        engine: DagDBEngine,
        nodeCount: Int,
        gridW: Int,
        gridH: Int,
        tickCount: UInt32,
        dir: String
    ) throws -> (baseBytes: Int, elapsedMs: Double) {
        let t0 = Date()
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        // Wipe any existing chain in this dir.
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            if name.hasSuffix(".diff") || name == "base.dags" {
                try? fm.removeItem(atPath: dir + "/" + name)
            }
        }

        let saved = try DagDBSnapshot.save(
            engine: engine, nodeCount: nodeCount,
            gridW: gridW, gridH: gridH,
            tickCount: tickCount,
            path: dir + "/base.dags",
            compressed: true
        )
        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (saved.bytesWritten, elapsed)
    }

    // MARK: - Append diff

    public static func appendDiff(
        engine: DagDBEngine,
        nodeCount: Int,
        gridW: Int,
        gridH: Int,
        dir: String
    ) throws -> (diffBytes: Int, diffPath: String, elapsedMs: Double) {
        let t0 = Date()
        let chain = try info(dir: dir)
        guard chain.baseExists else {
            throw BackupError.noBase(dir + "/base.dags")
        }

        // Reconstruct the chain's current tip into CPU arrays.
        let tip = try replayChain(
            dir: dir, nodeCount: nodeCount, gridW: gridW, gridH: gridH)

        // Current engine state — raw bytes copied off the GPU buffers.
        let cur = readEngineBuffers(engine: engine, nodeCount: nodeCount)

        // XOR diffs per buffer. Same-size buffers because topology is fixed.
        let rankDiff  = xor(tip.rank,     cur.rank)
        let truthDiff = xor(tip.truth,    cur.truth)
        let typeDiff  = xor(tip.type,     cur.type)
        let lowDiff   = xor(tip.low,      cur.low)
        let highDiff  = xor(tip.high,     cur.high)
        let nbDiff    = xor(tip.neighbors, cur.neighbors)

        // Pack diff file: header + 6 zlib-compressed segments (each: u32 size + body).
        var out = Data()
        out.append(contentsOf: diffMagic)
        appendU32(&out, diffVersion)
        appendU32(&out, UInt32(nodeCount))
        appendU32(&out, UInt32(chain.diffCount + 1))  // sequence number

        for seg in [rankDiff, truthDiff, typeDiff, lowDiff, highDiff, nbDiff] {
            let compressed = DagDBSnapshot.zlibCompress(Data(seg))
            appendU32(&out, UInt32(compressed.count))
            out.append(compressed)
        }

        let seq = chain.diffCount + 1
        let diffPath = String(format: "\(dir)/%05d.diff", seq)
        try atomicWrite(data: out, path: diffPath)

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (out.count, diffPath, elapsed)
    }

    // MARK: - Restore

    public static func restore(
        engine: DagDBEngine,
        nodeCount: Int,
        gridW: Int,
        gridH: Int,
        dir: String
    ) throws -> (diffsReplayed: Int, elapsedMs: Double) {
        let t0 = Date()
        let tip = try replayChain(
            dir: dir, nodeCount: nodeCount, gridW: gridW, gridH: gridH)

        tip.rank.withUnsafeBytes  { memcpy(engine.rankBuf.contents(),       $0.baseAddress!, nodeCount * 4) }
        tip.truth.withUnsafeBytes { memcpy(engine.truthStateBuf.contents(), $0.baseAddress!, nodeCount) }
        tip.type.withUnsafeBytes  { memcpy(engine.nodeTypeBuf.contents(),   $0.baseAddress!, nodeCount) }
        tip.low.withUnsafeBytes   { memcpy(engine.lut6LowBuf.contents(),    $0.baseAddress!, nodeCount * 4) }
        tip.high.withUnsafeBytes  { memcpy(engine.lut6HighBuf.contents(),   $0.baseAddress!, nodeCount * 4) }
        tip.neighbors.withUnsafeBytes { memcpy(engine.neighborsBuf.contents(), $0.baseAddress!, nodeCount * 6 * 4) }

        let chain = try info(dir: dir)
        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (chain.diffCount, elapsed)
    }

    // MARK: - Compact

    /// Collapse the diff chain into a new base.dags — restore into `engine`,
    /// write a new base from its buffers, delete the old base and all diffs.
    public static func compact(
        engine: DagDBEngine,
        nodeCount: Int,
        gridW: Int,
        gridH: Int,
        tickCount: UInt32,
        dir: String
    ) throws -> (priorDiffCount: Int, newBaseBytes: Int, elapsedMs: Double) {
        let t0 = Date()
        let (priorDiffs, _) = try restore(
            engine: engine, nodeCount: nodeCount,
            gridW: gridW, gridH: gridH, dir: dir)

        let saved = try DagDBSnapshot.save(
            engine: engine, nodeCount: nodeCount,
            gridW: gridW, gridH: gridH,
            tickCount: tickCount,
            path: dir + "/base.dags",
            compressed: true
        )

        // Remove all .diff files (atomic rename of new base already landed).
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            if name.hasSuffix(".diff") {
                try? fm.removeItem(atPath: dir + "/" + name)
            }
        }

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (priorDiffs, saved.bytesWritten, elapsed)
    }

    // MARK: - Internals

    private struct TipArrays {
        var rank:      [UInt8]
        var truth:     [UInt8]
        var type:      [UInt8]
        var low:       [UInt8]  // bytes of [UInt32] — XOR works byte-wise
        var high:      [UInt8]
        var neighbors: [UInt8]  // bytes of [Int32]
    }

    /// Replay base + all diffs into in-memory byte arrays. Does NOT touch any engine.
    private static func replayChain(
        dir: String, nodeCount: Int, gridW: Int, gridH: Int
    ) throws -> TipArrays {
        let base = dir + "/base.dags"
        guard FileManager.default.fileExists(atPath: base) else {
            throw BackupError.noBase(base)
        }

        // Read base via DagDBSnapshot — but we want bytes, not a committed engine.
        // Cheapest: load into a throwaway engine. Shared-memory UMA, no GPU fanfare.
        let grid = HexGrid(width: gridW, height: gridH)
        let state = DagDBState(width: gridW, height: gridH)
        let tmpEng = try DagDBEngine(grid: grid, state: state, maxRank: 32)
        _ = try DagDBSnapshot.load(
            engine: tmpEng, nodeCount: nodeCount,
            gridW: gridW, gridH: gridH, path: base, validate: false
        )

        var tip = readEngineBuffers(engine: tmpEng, nodeCount: nodeCount)

        let chain = try info(dir: dir)
        for p in chain.diffPaths {
            try applyDiff(to: &tip, diffPath: p, nodeCount: nodeCount)
        }
        return tip
    }

    private static func readEngineBuffers(
        engine: DagDBEngine, nodeCount: Int
    ) -> TipArrays {
        let rank  = Data(bytesNoCopy: engine.rankBuf.contents(),       count: nodeCount * 4,     deallocator: .none)
        let truth = Data(bytesNoCopy: engine.truthStateBuf.contents(), count: nodeCount,         deallocator: .none)
        let type  = Data(bytesNoCopy: engine.nodeTypeBuf.contents(),   count: nodeCount,         deallocator: .none)
        let low   = Data(bytesNoCopy: engine.lut6LowBuf.contents(),    count: nodeCount * 4,     deallocator: .none)
        let high  = Data(bytesNoCopy: engine.lut6HighBuf.contents(),   count: nodeCount * 4,     deallocator: .none)
        let nb    = Data(bytesNoCopy: engine.neighborsBuf.contents(),  count: nodeCount * 6 * 4, deallocator: .none)
        return TipArrays(
            rank:      Array(rank),
            truth:     Array(truth),
            type:      Array(type),
            low:       Array(low),
            high:      Array(high),
            neighbors: Array(nb)
        )
    }

    private static func applyDiff(
        to tip: inout TipArrays,
        diffPath: String,
        nodeCount: Int
    ) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: diffPath))
        guard data.count >= diffHeaderSize else {
            throw BackupError.invalidDiff("\(diffPath): too short")
        }
        let m = [UInt8](data[0..<4])
        guard m == diffMagic else {
            throw BackupError.invalidDiff("\(diffPath): magic")
        }
        let ver = readU32(data, 4)
        guard ver == diffVersion else {
            throw BackupError.invalidDiff("\(diffPath): version \(ver)")
        }
        let fileNC = Int(readU32(data, 8))
        guard fileNC == nodeCount else {
            throw BackupError.shapeMismatch("\(diffPath): nodeCount \(fileNC) != \(nodeCount)")
        }
        // u32 sequence at offset 12 is informational; not enforced

        var offset = diffHeaderSize
        let segSizes: [Int] = [
            nodeCount * 4,     // rank (u32 post-u32-widen (2026-04-20))
            nodeCount,         // truth
            nodeCount,         // type
            nodeCount * 4,     // low
            nodeCount * 4,     // high
            nodeCount * 6 * 4, // neighbors
        ]
        func readSeg(expectedSize: Int) throws -> [UInt8] {
            guard offset + 4 <= data.count else {
                throw BackupError.invalidDiff("\(diffPath): truncated segment header")
            }
            let sz = Int(readU32(data, offset))
            offset += 4
            guard offset + sz <= data.count else {
                throw BackupError.invalidDiff("\(diffPath): truncated segment body")
            }
            let compressed = data.subdata(in: offset..<(offset + sz))
            offset += sz
            let decompressed = DagDBSnapshot.zlibDecompress(compressed, expectedSize: expectedSize)
            guard decompressed.count == expectedSize else {
                throw BackupError.invalidDiff("\(diffPath): segment decompress size \(decompressed.count) != \(expectedSize)")
            }
            return [UInt8](decompressed)
        }

        let dRank = try readSeg(expectedSize: segSizes[0])
        let dTruth = try readSeg(expectedSize: segSizes[1])
        let dType = try readSeg(expectedSize: segSizes[2])
        let dLow = try readSeg(expectedSize: segSizes[3])
        let dHigh = try readSeg(expectedSize: segSizes[4])
        let dNb = try readSeg(expectedSize: segSizes[5])

        xorInPlace(&tip.rank,      dRank)
        xorInPlace(&tip.truth,     dTruth)
        xorInPlace(&tip.type,      dType)
        xorInPlace(&tip.low,       dLow)
        xorInPlace(&tip.high,      dHigh)
        xorInPlace(&tip.neighbors, dNb)
    }

    // MARK: - Byte helpers

    private static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        let n = min(a.count, b.count)
        var out = [UInt8](repeating: 0, count: n)
        for i in 0..<n { out[i] = a[i] ^ b[i] }
        return out
    }

    private static func xorInPlace(_ a: inout [UInt8], _ b: [UInt8]) {
        let n = min(a.count, b.count)
        for i in 0..<n { a[i] ^= b[i] }
    }

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

    private static func atomicWrite(data: Data, path: String) throws {
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        let fd = open(path, O_RDONLY)
        if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC); close(fd) }
        let dir = (path as NSString).deletingLastPathComponent
        let dirFd = open(dir, O_RDONLY)
        if dirFd >= 0 { _ = fcntl(dirFd, F_FULLFSYNC); close(dirFd) }
    }
}
