/// DagDBSnapshot — Full-state binary serialization for DagDB.
///
/// Dumps every GPU buffer in Morton order. Optional zlib compression
/// of the body. Validated before memcpy so bad files can't corrupt live state.
///
/// Format (32-byte header):
///     magic       [4]  = "DAGS"
///     version     u32  (1 = u8 rank, 2 = u32 rank, 3 = u64 rank,
///                       4 = v3 + back-edge section after the body)
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
///   v4 = v3 body + a back-edge section appended after `bodyBytes`:
///         u32 backEdgeCount
///         backEdgeCount × (u32 src + u32 dst) = 8 B per entry
///        The back-edge section is always uncompressed; the `flags`
///        compressed bit refers only to the v3 body.
///
/// Save always writes the newest version (v7). Load accepts v1..v7; rank
/// widens on read for v1 and v2, and every section introduced after v4
/// (env trailer, WGTS lanes, TWIN state) is absent on older files and
/// simply skipped — never a load failure.
///
/// N = 10M at v3 → 420 MB raw. With zlib the body typically drops to
/// 20-30 % because the neighbors table is mostly -1 padding.

import Foundation
import Metal
import Compression
import CryptoKit

public enum DagDBSnapshot {

    public static let magic: [UInt8] = [0x44, 0x41, 0x47, 0x53]  // "DAGS"
    /// v1 = u8 rank (pre-u32-widen). v2 = u32 rank (2026-04-20). v3 = u64
    /// rank (2026-04-21, for the 10^11 laptop target). v4 = v3 body + a
    /// back-edge section appended after the body (2026-04-29, for the
    /// BACK_EDGE primitive). Load accepts v1..v4; save always writes v4.
    public static let versionV1: UInt32 = 1
    public static let versionV2: UInt32 = 2
    public static let versionV3: UInt32 = 3
    public static let versionV4: UInt32 = 4
    /// v5 = v4 body + back-edge section + env-origin trailer at end of file.
    /// Trailer = magic "ENVS" (4 bytes) + env code u8. Phase 3 of dev/test/prod
    /// env-split, 2026-05-02. LOAD verifies the env code matches the daemon's
    /// env if both are set; cross-env loads rejected with envMismatch.
    public static let versionV5: UInt32 = 5
    /// v6 = v5 + a WGTS lane section between the back-edge section and the
    /// ENVS trailer (E1, 2026-08-22): magic "WGTS" (4) + lane flags u8
    /// (bit0 edgeWeights, bit1 activation, bit2 nodeValue) + the present
    /// lanes, uncompressed, in flag-bit order. A lane is written only when
    /// it differs from its default (weights all 1.0, activation all 0,
    /// nodeValue all 0), so Boolean-mode snapshots pay 5 bytes, not 26N.
    public static let versionV6: UInt32 = 6
    /// v7 = v6 + a TWIN section between the WGTS lane section and the ENVS
    /// trailer (interface phase, 2026-09): magic "TWIN" (4) + u32 byteLength (4,
    /// little-endian) + JSON (`JSONEncoder` `.sortedKeys`) of
    /// `TwinState.Snapshot` — the seven twin-spec registries (named
    /// streams, slice records, geared rings, master clocks/gears, budget
    /// layouts, alarm sets by reference). Always uncompressed. Length 0
    /// when `twin` is nil at save time. Loading a v7 file with `twin: nil`
    /// still validates the section's magic/length but does not decode or
    /// apply it. A v1..v6 file carries no TWIN section; loading one resets
    /// the passed `twin` to empty, matching a fresh daemon's twin state.
    public static let versionV7: UInt32 = 7
    public static let version: UInt32 = versionV7
    public static let headerSize: Int = 32

    /// "ENVS" magic for the v5 env-origin trailer.
    public static let envTrailerMagic: [UInt8] = [0x45, 0x4e, 0x56, 0x53]

    /// "WGTS" magic for the v6 lane section.
    public static let laneSectionMagic: [UInt8] = [0x57, 0x47, 0x54, 0x53]

    /// "TWIN" magic for the v7 twin-state section.
    public static let twinSectionMagic: [UInt8] = [0x54, 0x57, 0x49, 0x4e]

    /// Env-origin stamp embedded in v5 snapshots. `unspecified` means the
    /// daemon writing/reading didn't have DAGDB_ENV set (legacy / unguarded).
    public enum SnapshotEnv: UInt8, Sendable {
        case unspecified = 0
        case dev = 1
        case test = 2
        case prod = 3

        public var label: String {
            switch self {
            case .unspecified: return "unspecified"
            case .dev: return "dev"
            case .test: return "test"
            case .prod: return "prod"
            }
        }

        /// Map a DAGDB_ENV string to a SnapshotEnv code. Returns
        /// `unspecified` for nil / empty / unrecognised values.
        public static func from(envString: String?) -> SnapshotEnv {
            guard let s = envString?.lowercased() else { return .unspecified }
            switch s {
            case "dev": return .dev
            case "test": return .test
            case "prod": return .prod
            default: return .unspecified
            }
        }
    }

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
        case envMismatch(file: SnapshotEnv, daemon: SnapshotEnv)
        case ioFailure(String)
        case validationFailed(String)
        case manifestMismatch(expected: String, actual: String)

        public var description: String {
            switch self {
            case .invalidMagic: return "invalid magic (expected 'DAGS')"
            case .unsupportedVersion(let v): return "unsupported version: \(v)"
            case .nodeCountMismatch(let f, let e): return "nodeCount mismatch: file=\(f) engine=\(e)"
            case .gridMismatch(let fw, let fh, let ew, let eh): return "grid mismatch: file=\(fw)x\(fh) engine=\(ew)x\(eh)"
            case .envMismatch(let f, let d): return "env mismatch: file env=\(f.label) but daemon env=\(d.label) — cross-env loads rejected"
            case .ioFailure(let s): return "io: \(s)"
            case .validationFailed(let s): return "validation: \(s)"
            case .manifestMismatch(let e, let a): return "manifest mismatch: sha256 file=\(e) computed=\(a) — snapshot corrupt, refusing load"
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

        // Rank bound (R4, docs/contracts/RANK_BOUND_GATES_FROZEN.md).
        // A snapshot written under a large `maxRank` and restored under a
        // small one carries ranks at or above the running bound. The rank
        // dispatch now covers them (`DagDBEngine.effectiveRankCount`), so
        // this is not a refusal — the load path still accepts the file —
        // but the state has to be catchable WITHOUT ticking, so VALIDATE
        // names it: how many nodes, the first of them, and how far the
        // ranks actually run. Reported last, so a genuine edge violation
        // still surfaces first.
        var overCount = 0
        var firstOver = -1
        var firstOverRank: UInt64 = 0
        var highest: UInt64 = 0
        for i in 0..<nodeCount {
            let r = rank[i]
            if r > highest { highest = r }
            if r >= UInt64(engine.maxRank) {
                overCount += 1
                if firstOver < 0 { firstOver = i; firstOverRank = r }
            }
        }
        if overCount > 0 {
            return "rank bound: \(overCount) node(s) at or above maxRank " +
                   "\(engine.maxRank) (first node \(firstOver) rank " +
                   "\(firstOverRank), highest rank \(highest))"
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
        compressed: Bool = false,
        daemonEnv: SnapshotEnv = .unspecified,
        twin: TwinState? = nil
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

        // v4 back-edge section — appended after the body, always
        // uncompressed (the count is small relative to the body).
        var beSection = Data()
        let beCount = UInt32(engine.backEdgeCount)
        appendU32(&beSection, beCount)
        for i in 0..<engine.backEdgeCount {
            appendU32(&beSection, engine.backEdgeSrcs[i])
            appendU32(&beSection, engine.backEdgeDsts[i])
        }
        handle.write(beSection)

        // v6 WGTS lane section — after the back-edge section, before the
        // ENVS trailer. Non-default lanes only (see versionV6 doc).
        var laneSection = Data()
        laneSection.append(contentsOf: laneSectionMagic)
        let wPtr = engine.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: nodeCount * 6)
        let aPtr = engine.activationBuf.contents().bindMemory(to: Int16.self, capacity: nodeCount)
        let vPtr = engine.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: nodeCount)
        var laneFlags: UInt8 = 0
        for i in 0..<(nodeCount * 6) where wPtr[i] != 1.0 { laneFlags |= 0x01; break }
        for i in 0..<nodeCount where aPtr[i] != 0 { laneFlags |= 0x02; break }
        for i in 0..<nodeCount where vPtr[i] != 0.0 { laneFlags |= 0x04; break }
        laneSection.append(laneFlags)
        handle.write(laneSection)
        var laneBytes = laneSection.count
        if laneFlags & 0x01 != 0 {
            handle.write(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: wPtr),
                              count: nodeCount * 6 * 4, deallocator: .none))
            laneBytes += nodeCount * 6 * 4
        }
        if laneFlags & 0x02 != 0 {
            handle.write(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: aPtr),
                              count: nodeCount * 2, deallocator: .none))
            laneBytes += nodeCount * 2
        }
        if laneFlags & 0x04 != 0 {
            handle.write(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: vPtr),
                              count: nodeCount * 4, deallocator: .none))
            laneBytes += nodeCount * 4
        }

        // v7 TWIN section — between the WGTS lane section and the ENVS
        // trailer. magic "TWIN" (4) + u32 byteLength (4) + JSON
        // (`.sortedKeys`) of `TwinState.Snapshot`. Length 0 when `twin`
        // is nil — most daemon runs never open a twin registry.
        var twinSection = Data()
        twinSection.append(contentsOf: twinSectionMagic)
        var twinJSON = Data()
        if let twin = twin {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            twinJSON = try encoder.encode(twin.export())
        }
        appendU32(&twinSection, UInt32(twinJSON.count))
        twinSection.append(twinJSON)
        handle.write(twinSection)

        // v5 env-origin trailer — 5 bytes appended at end of file:
        // magic "ENVS" (4) + env code u8 (1).
        var envTrailer = Data()
        envTrailer.append(contentsOf: envTrailerMagic)
        envTrailer.append(daemonEnv.rawValue)
        handle.write(envTrailer)

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

        // G73: SHA-256 manifest, written side-by-side AFTER the snapshot rename
        // (frozen ARCH decision). A crash between the rename and this write
        // leaves a manifest-less snapshot, which the loader treats as legacy
        // (warn + accept) — never a refusal of otherwise-good data. Hashing the
        // final on-disk bytes (not the in-memory buffers) makes the manifest a
        // true check of what landed on the platter.
        if let finalBytes = try? Data(contentsOf: URL(fileURLWithPath: path),
                                      options: [.mappedIfSafe]) {
            let hex = sha256Hex(finalBytes)
            let manifestPath = manifestPathFor(path)
            try? Data((hex + "\n").utf8).write(
                to: URL(fileURLWithPath: manifestPath), options: [.atomic])
            let mfd = open(manifestPath, O_RDONLY)
            if mfd >= 0 { _ = fcntl(mfd, F_FULLFSYNC); close(mfd) }
            let dfd = open(dirPath, O_RDONLY)
            if dfd >= 0 { _ = fcntl(dfd, F_FULLFSYNC); close(dfd) }
        }

        let total = headerSize + bodyBytes + beSection.count + laneBytes + twinSection.count + envTrailer.count
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
        validate: Bool = true,
        daemonEnv: SnapshotEnv = .unspecified,
        verifyManifest: Bool = true,
        twin: TwinState? = nil
    ) throws -> LoadResult {
        let t0 = Date()

        guard FileManager.default.fileExists(atPath: path) else {
            throw SnapError.ioFailure("file not found: \(path)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        guard data.count >= headerSize else {
            throw SnapError.ioFailure("file too short: \(data.count) bytes")
        }

        // G73: verify the SHA-256 manifest BEFORE any buffer is touched, so a
        // corrupt snapshot is refused loudly and never half-loaded. Missing
        // manifest = legacy snapshot: warn and accept. Bad manifest = refuse.
        if verifyManifest {
            let manifestPath = manifestPathFor(path)
            if let mData = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
               let expected = String(data: mData, encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !expected.isEmpty {
                let actual = sha256Hex(data)
                guard actual == expected else {
                    throw SnapError.manifestMismatch(expected: expected, actual: actual)
                }
            } else {
                FileHandle.standardError.write(Data(
                    "WARN: snapshot \(path) has no .sha256 manifest — loading unverified (legacy)\n".utf8))
            }
        }

        // Header
        let m = [UInt8](data[0..<4])
        guard m == magic else { throw SnapError.invalidMagic }
        let ver = readU32(data, 4)
        guard ver == versionV1 || ver == versionV2 || ver == versionV3
                || ver == versionV4 || ver == versionV5 || ver == versionV6
                || ver == versionV7 else {
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

        // Rank width per version: v1 = 1 byte (u8), v2 = 4 (u32),
        // v3/v4/v5/v6/v7 = 8 (u64). v4 added a back-edge trailer; v5 added
        // an env-origin trailer on top of v4; v6 added a WGTS lane section;
        // v7 added a TWIN section.
        let rankBytesPerNode: Int
        switch ver {
        case versionV1: rankBytesPerNode = 1
        case versionV2: rankBytesPerNode = 4
        case versionV3, versionV4, versionV5, versionV6, versionV7: rankBytesPerNode = 8
        default:        rankBytesPerNode = 1  // unreachable (guarded above)
        }
        // body = rank + truth(1) + type(1) + lut_low(4) + lut_high(4) + neighbors(24)
        let uncompressedBodySize = nodeCount * (34 + rankBytesPerNode)

        // Resolve the body bytes — either the raw slice or the zlib-decoded buffer.
        let bodyData: Data
        if flags.contains(.compressed) {
            // bodyBytes is the compressed size on disk. Guard the slice against
            // a physically truncated file: the header can declare a body the
            // file doesn't actually contain (the crash-during-write artifact).
            // subdata on an out-of-range slice would trap and kill the daemon —
            // throw instead.
            guard data.count >= headerSize + bodyBytes else {
                throw SnapError.ioFailure("file truncated: header declares \(bodyBytes) compressed body bytes, file has \(data.count - headerSize) after header")
            }
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
            // Same truncation guard as the compressed path: don't trap on a
            // short file whose header claims a full body.
            guard data.count >= headerSize + effectiveBody else {
                throw SnapError.ioFailure("file truncated: expected \(effectiveBody) body bytes, file has \(data.count - headerSize) after header")
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
            default:  // v3 / v4 / v5 / v6 / v7
                memcpy(engine.rankBuf.contents(), base.advanced(by: off), nodeCount * 8)
                off += nodeCount * 8
            }
            memcpy(engine.truthStateBuf.contents(), base.advanced(by: off), nodeCount);             off += nodeCount
            memcpy(engine.nodeTypeBuf.contents(),   base.advanced(by: off), nodeCount);             off += nodeCount
            memcpy(engine.lut6LowBuf.contents(),    base.advanced(by: off), nodeCount * 4);         off += nodeCount * 4
            memcpy(engine.lut6HighBuf.contents(),   base.advanced(by: off), nodeCount * 4);         off += nodeCount * 4
            memcpy(engine.neighborsBuf.contents(),  base.advanced(by: off), nodeCount * 6 * 4)
        }

        // v4 back-edge section — read after the body. v1/v2/v3 files have
        // no section; load resets the back-edge list to empty.
        engine.backEdgeSrcs.removeAll(keepingCapacity: false)
        engine.backEdgeDsts.removeAll(keepingCapacity: false)
        let regPtr = engine.isRegisterBuf.contents()
            .bindMemory(to: UInt8.self, capacity: nodeCount)
        for i in 0..<nodeCount { regPtr[i] = 0 }

        var totalRead = headerSize + (flags.contains(.compressed) ? bodyBytes : uncompressedBodySize)

        // Weight/value lanes: reset to defaults on EVERY load path, so a
        // pre-v6 snapshot (or a v6 file with absent lanes) never leaves
        // stale lane state from the running session (E1). v6 files with
        // present lanes overwrite these defaults below.
        let wDefPtr = engine.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: nodeCount * 6)
        for i in 0..<(nodeCount * 6) { wDefPtr[i] = 1.0 }
        let aDefPtr = engine.activationBuf.contents().bindMemory(to: Int16.self, capacity: nodeCount)
        for i in 0..<nodeCount { aDefPtr[i] = 0 }
        let vDefPtr = engine.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: nodeCount)
        for i in 0..<nodeCount { vDefPtr[i] = 0.0 }

        if ver >= versionV4 {
            let beSectionStart = totalRead
            guard data.count >= beSectionStart + 4 else {
                throw SnapError.ioFailure("v\(ver) file is missing the back-edge count")
            }
            let beCount = Int(readU32(data, beSectionStart))
            let beSectionSize = 4 + beCount * 8
            guard data.count >= beSectionStart + beSectionSize else {
                throw SnapError.ioFailure("v\(ver) file truncated mid-back-edge-section: " +
                                          "need \(beSectionSize) bytes, have \(data.count - beSectionStart)")
            }
            for i in 0..<beCount {
                let entryOff = beSectionStart + 4 + i * 8
                let src = readU32(data, entryOff)
                let dst = readU32(data, entryOff + 4)
                // Range-check before the unchecked add: a corrupt/crafted file
                // with src or dst >= nodeCount would write past isRegisterBuf
                // (heap corruption). The WAL replay path bounds-checks the same
                // op; the snapshot path must too. Reset any partial state first
                // so a thrown error leaves no half-loaded back-edge list.
                guard Int(src) < nodeCount && Int(dst) < nodeCount else {
                    engine.backEdgeSrcs.removeAll(keepingCapacity: false)
                    engine.backEdgeDsts.removeAll(keepingCapacity: false)
                    let rp = engine.isRegisterBuf.contents()
                        .bindMemory(to: UInt8.self, capacity: nodeCount)
                    for j in 0..<nodeCount { rp[j] = 0 }
                    throw SnapError.ioFailure("back-edge entry \(i) out of range: src=\(src) dst=\(dst) nodeCount=\(nodeCount)")
                }
                engine.addBackEdgeUnchecked(src: src, dst: dst)
            }
            totalRead += beSectionSize
        }

        // v6+ WGTS lane section — between the back-edge section and the
        // TWIN section. magic "WGTS" (4) + lane flags u8 + present lanes.
        if ver >= versionV6 {
            let laneStart = totalRead
            guard data.count >= laneStart + 5 else {
                throw SnapError.ioFailure("v6 file is missing the WGTS lane section")
            }
            let laneMagic = [UInt8](data[laneStart..<laneStart + 4])
            guard laneMagic == laneSectionMagic else {
                throw SnapError.ioFailure("v6 lane-section magic mismatch: got 0x\(laneMagic.map { String(format: "%02x", $0) }.joined()), expected 'WGTS' (0x57475453)")
            }
            let laneFlags = data[laneStart + 4]
            var off6 = laneStart + 5
            if laneFlags & 0x01 != 0 {
                let sz = nodeCount * 6 * 4
                guard data.count >= off6 + sz else {
                    throw SnapError.ioFailure("v6 file truncated mid-edge-weight lane")
                }
                data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    memcpy(engine.edgeWeightsBuf.contents(), raw.baseAddress!.advanced(by: off6), sz)
                }
                off6 += sz
            }
            if laneFlags & 0x02 != 0 {
                let sz = nodeCount * 2
                guard data.count >= off6 + sz else {
                    throw SnapError.ioFailure("v6 file truncated mid-activation lane")
                }
                data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    memcpy(engine.activationBuf.contents(), raw.baseAddress!.advanced(by: off6), sz)
                }
                off6 += sz
            }
            if laneFlags & 0x04 != 0 {
                let sz = nodeCount * 4
                guard data.count >= off6 + sz else {
                    throw SnapError.ioFailure("v6 file truncated mid-node-value lane")
                }
                data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    memcpy(engine.nodeValueBuf.contents(), raw.baseAddress!.advanced(by: off6), sz)
                }
                off6 += sz
            }
            totalRead = off6
        }

        // v7 TWIN section — between the WGTS lane section and the ENVS
        // trailer. magic "TWIN" (4) + u32 byteLength (4) + JSON payload.
        // v1..v6 files carry no section at all: the passed `twin` (if any)
        // is simply reset to empty, matching a fresh daemon.
        if ver >= versionV7 {
            let twinStart = totalRead
            guard data.count >= twinStart + 8 else {
                throw SnapError.ioFailure("v7 file truncated mid-twin-section")
            }
            let twinMagic = [UInt8](data[twinStart..<twinStart + 4])
            guard twinMagic == twinSectionMagic else {
                throw SnapError.ioFailure("v7 twin-section magic mismatch: got 0x\(twinMagic.map { String(format: "%02x", $0) }.joined()), expected 'TWIN' (0x5457494e)")
            }
            let twinLen = Int(readU32(data, twinStart + 4))
            guard data.count >= twinStart + 8 + twinLen else {
                throw SnapError.ioFailure("v7 file truncated mid-twin-section")
            }
            if let twin = twin {
                if twinLen == 0 {
                    twin.reset()
                } else {
                    let twinData = data.subdata(in: (twinStart + 8)..<(twinStart + 8 + twinLen))
                    do {
                        let snap = try JSONDecoder().decode(TwinState.Snapshot.self, from: twinData)
                        try twin.restore(snap)
                    } catch {
                        throw SnapError.ioFailure("v7 twin section undecodable: \(error)")
                    }
                }
            }
            totalRead = twinStart + 8 + twinLen
        } else {
            twin?.reset()
        }

        // v5+ env-origin trailer — 5 bytes at end of file: magic "ENVS" + env code u8.
        // Present in v5, v6, and v7 files. Cross-env loads rejected.
        if ver >= versionV5 {
            let trailerStart = totalRead
            guard data.count >= trailerStart + 5 else {
                throw SnapError.ioFailure("v\(ver) file is missing the env-origin trailer (need 5 bytes, have \(data.count - trailerStart))")
            }
            let trailerMagic = [UInt8](data[trailerStart..<trailerStart + 4])
            guard trailerMagic == envTrailerMagic else {
                throw SnapError.ioFailure("v\(ver) env-trailer magic mismatch: got 0x\(trailerMagic.map { String(format: "%02x", $0) }.joined()), expected 'ENVS' (0x454e5653)")
            }
            let envCode = data[trailerStart + 4]
            let fileEnv = SnapshotEnv(rawValue: envCode) ?? .unspecified
            // Cross-env load rejection: if both daemon and file have a real
            // env (not unspecified) and they differ, reject. unspecified-on-
            // either-side passes through (legacy / unguarded daemons keep working).
            if daemonEnv != .unspecified && fileEnv != .unspecified && daemonEnv != fileEnv {
                throw SnapError.envMismatch(file: fileEnv, daemon: daemonEnv)
            }
            totalRead += 5
        }

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

    // MARK: - Manifest (G73)

    /// Side-by-side SHA-256 manifest path for a snapshot: `<path>.sha256`.
    public static func manifestPathFor(_ path: String) -> String { path + ".sha256" }

    /// Lowercase hex SHA-256 of the given bytes.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
