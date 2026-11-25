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
/// Save writes v7 or v8: v8 — the native
/// ternary tick's 53-byte-per-node body behind a u64 length, and a TERN
/// library section, see `versionV8` — when the graph has ternary content (a
/// non-default byte in one of the four lanes, or a table in the library) or
/// its 42-byte-per-node v7 body would not fit the header's u32 field; else
/// v7, byte for byte as before the ternary tick. Load accepts v1..v8; rank widens on read for v1 and
/// v2, and every section introduced after v4 (env trailer, WGTS lanes, TWIN
/// state, TERN library) is absent on older files and simply skipped — never
/// a load failure. A v1–v7 file loads as a binary graph: the four ternary
/// lanes reset to BINARY and the library empties.
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
    /// ENVS trailer (2026-08-22): magic "WGTS" (4) + lane flags u8
    /// (bit0 edgeWeights, bit1 activation, bit2 nodeValue) + the present
    /// lanes, uncompressed, in flag-bit order. A lane is written only when
    /// it differs from its default (weights all 1.0, activation all 0,
    /// nodeValue all 0), so Boolean-mode snapshots pay 5 bytes, not 26N.
    public static let versionV6: UInt32 = 6
    /// v7 = v6 + a TWIN section between the WGTS lane section and the ENVS
    /// trailer (2026-09-06): magic "TWIN" (4) + u32 byteLength (4,
    /// little-endian) + JSON (`JSONEncoder` `.sortedKeys`) of
    /// `TwinState.Snapshot` — the seven twin-spec registries (named
    /// streams, slice records, geared rings, master clocks/gears, budget
    /// layouts, alarm sets by reference). Always uncompressed. Length 0
    /// when `twin` is nil at save time. Loading a v7 file with `twin: nil`
    /// still validates the section's magic/length but does not decode or
    /// apply it. A v1..v6 file carries no TWIN section; loading one resets
    /// the passed `twin` to empty, matching a fresh daemon's twin state.
    public static let versionV7: UInt32 = 7
    /// v8 = the native ternary tick. The header stays 32 bytes with
    /// offsets 8 (nodeCount) and 20 (tickCount) unchanged; `bodyBytes`@28
    /// holds 0xFFFFFFFF and a u64 body length (on-disk bytes) follows the
    /// header. The body is the v3 body followed by mode[N] u8 · ttableId[N]
    /// u16 · thrLo[N] f32 · thrHi[N] f32 = 53 bytes per node (the u32 field
    /// caps at 81,037,118 such nodes; 100M needs the u64). A TERN section
    /// after WGTS carries the table library: "TERN" · u8 flags (bit 0 =
    /// library present; bits 1–7 refused by name) · u32 table count · 729 ×
    /// count bytes. Every ternary rule is checked on load before a single
    /// buffer is written, and on save before a byte is.
    public static let versionV8: UInt32 = 8
    public static let version: UInt32 = versionV8
    /// `bodyBytes`@28 in a v8 header: "the length is the u64 that follows".
    public static let bodyBytesSentinel: UInt32 = 0xFFFF_FFFF
    /// Bytes per node of the v8 body.
    public static let v8BodyBytesPerNode = 53

    /// "TERN" magic for the v8 library section.
    public static let ternSectionMagic: [UInt8] = [0x54, 0x45, 0x52, 0x4e]
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

    /// The slot model: which slot rule a loader asks.
    public enum SlotRule: Sendable {
        /// The persistence rule (`persistenceSlotScan`): a source out of
        /// range is refused; S1–S3 are store shapes. Every loader but TILED OPEN.
        case persistence
        /// The rank-mode rule (`dagEdgeViolation`): a source out of range, S2
        /// and S3 refused; S1 accepted, as rank-mode TICK runs it (the kernel
        /// evaluates a duplicate input twice). TILED OPEN asks it: a tiled
        /// graph is a rank-mode object and accepts exactly what rank TICK
        /// runs.
        case rankModeDAG
    }

    public enum SnapError: Error, CustomStringConvertible, Reply.CarriesLine {
        case invalidMagic
        case unsupportedVersion(UInt32)
        case nodeCountMismatch(file: Int, engine: Int)
        case gridMismatch(fileW: Int, fileH: Int, engineW: Int, engineH: Int)
        case envMismatch(file: SnapshotEnv, daemon: SnapshotEnv)
        case ioFailure(String)
        case validationFailed(String)
        case manifestMismatch(expected: String, actual: String)
        /// A 32-bit header field cannot hold the value the save would put in
        /// it. Refused by name rather than trapped on the `UInt32(...)`
        /// conversion.
        case headerFieldOverflow(field: String, value: Int)
        /// The body could not be compressed into a shape `load` would accept.
        case compressionFailed(String)
        /// The v6 lane flags carry a bit this build does not define. Refusing
        /// here names the lane section; accepting it mis-computes the read
        /// offset and surfaces later as an "ENVS magic mismatch" that blames
        /// the trailer.
        case unknownLaneFlag(UInt8)
        /// The v8 TERN section's flags carry a bit this build does not define.
        case unknownTernFlag(UInt8)
        /// A ternary rule refused on save or load.
        case ternary(String)
        /// The `.sha256` manifest exists but cannot be read; the load is refused, not unverified.
        case unverified(path: String, why: String)
        /// The caller's admission refused the bytes the load would hold (its reply, verbatim).
        case admission(String)
        /// The twin section holds what no live verb lets a daemon hold (a count over its cap, a
        /// ring set's shape); nothing loaded.
        case twinRefused(String)

        public var description: String {
            switch self {
            case .invalidMagic: return "invalid magic (expected 'DAGS')"
            case .unsupportedVersion(let v): return "unsupported version: \(v)"
            case .nodeCountMismatch(let f, let e): return "nodeCount mismatch: file=\(f) engine=\(e)"
            case .gridMismatch(let fw, let fh, let ew, let eh): return "grid mismatch: file=\(fw)x\(fh) engine=\(ew)x\(eh)"
            case .envMismatch(let f, let d): return "env mismatch: file env=\(f.label) but daemon env=\(d.label) — cross-env loads rejected"
            case .ioFailure(let s): return "io: \(s)"
            case .validationFailed(let s): return "validation: \(s)"
            case .manifestMismatch(let e, let a): return "manifest mismatch: sha256 file=\(Reply.quoted(e)) computed=\(a) — snapshot corrupt, refusing load"
            case let .headerFieldOverflow(f, v):
                return "header field '\(f)' = \(v) exceeds the 32-bit field the snapshot format has for it (max \(UInt32.max))"
            case .compressionFailed(let s): return "compression: \(s)"
            case .unknownTernFlag(let b):
                return String(format: "unknown flag bit(s) 0x%02x in the TERN section — this file was written by a newer build", b)
            case .ternary(let why):
                return "ternary: \(why)"
            case let .unverified(p, why):
                return "unverified: the .sha256 manifest of \(Reply.quoted(p)) cannot be read (\(why)); the snapshot is not loaded"
                    + " unverified (LOAD \(Reply.quoted(p)) UNVERIFIED loads it without the check); nothing loaded"
            case .admission(let line):
                return line
            case .twinRefused(let why):
                return "v7 twin section refused: \(why); nothing loaded"
            case .unknownLaneFlag(let b):
                return String(format: "unknown lane flag bit(s) 0x%02x in the WGTS section — this file was written by a newer build with a lane this one does not know", b)
            }
        }

        /// An admission refusal is its own reply line, under no second code.
        public var replyLine: String? {
            if case .admission(let line) = self { return line }
            return nil
        }
    }

    public struct LoadResult {
        public let bytesRead: Int
        public let fileNodeCount: Int
        public let fileTicks: UInt32
        public let elapsedMs: Double
        /// The SHA-256 of the file's bytes when the load computed
        /// it (a manifest was verified), else nil.
        public var digest: [UInt8]? = nil
        /// Why the load was not checked against a manifest, when it was not
        /// (`"no manifest"`; or the unreadable one an UNVERIFIED load set aside); nil for a verified load and
        /// for a caller that did not ask for the check (a tile body, whose hash the router checks).
        public var unverified: String? = nil
    }

    /// The step boundaries of `save` its `stepHook` sees.
    public enum SaveStep: String, Sendable {
        /// The tmp file is written, fsynced and hashed; `path` is untouched.
        case tmpWritten
        /// The replaced file's old `<path>.sha256` is removed
        /// (the directory fsynced, if there was one); the rename not yet done.
        case oldManifestRemoved
        /// The rename is done and the directory fsynced; no manifest yet.
        case renamed
        /// The new manifest is written.
        case manifestWritten
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

        // The register invariant the engine actually evaluates.
        // `DagDBState`'s own doc says VALIDATE enforces "dst has zero
        // combinational fan-in"; this is where it does. A register
        // with a combinational input is a node the rank kernel skips and the
        // latch overwrites — its inputs are evaluated by nobody.
        let reg = engine.isRegisterBuf.contents()
            .bindMemory(to: UInt8.self, capacity: nodeCount)
        for dst in 0..<nodeCount where reg[dst] != 0 {
            for d in 0..<6 {
                let src = nb[dst * 6 + d]
                if src >= 0 {
                    return "register invariant: node \(dst) is a BACK_EDGE " +
                           "destination (register) but has a combinational " +
                           "input at slot \(d) (source node \(src)); registers " +
                           "must have zero combinational fan-in"
                }
            }
        }

        // The back-edge lists are indices into the same buffers the
        // latch phase writes through. Out of range here is a heap write on
        // every tick, so the range is checked as an invariant, not trusted.
        if engine.backEdgeSrcs.count != engine.backEdgeDsts.count {
            return "back-edge lists disagree in length: " +
                   "\(engine.backEdgeSrcs.count) source(s) vs " +
                   "\(engine.backEdgeDsts.count) destination(s)"
        }
        for i in 0..<engine.backEdgeSrcs.count {
            let s = engine.backEdgeSrcs[i]
            let d = engine.backEdgeDsts[i]
            if Int(s) >= nodeCount {
                return "back-edge \(i): source \(s) out of range for nodeCount \(nodeCount)"
            }
            if Int(d) >= nodeCount {
                return "back-edge \(i): destination \(d) out of range for nodeCount \(nodeCount)"
            }
        }

        // And the flag buffer must agree with the list, in both
        // directions: a flag with no back edge is a node the kernel skips
        // forever, and an unflagged destination is a node the kernel and the
        // latch both write.
        var isDst = [Bool](repeating: false, count: nodeCount)
        for d in engine.backEdgeDsts where Int(d) < nodeCount { isDst[Int(d)] = true }
        for i in 0..<nodeCount {
            let flagged = reg[i] != 0
            if flagged && !isDst[i] {
                return "register flag disagreement: node \(i) is flagged as a " +
                       "register but is not the destination of any BACK_EDGE"
            }
            if !flagged && isDst[i] {
                return "register flag disagreement: node \(i) is the destination " +
                       "of a BACK_EDGE but is not flagged as a register"
            }
        }

        // Rank bound.
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
            // The same sentence, then the dispatch's OWN thresholds
            // appended. `maxRank` alone conflates two different states: a
            // rank the dispatch reaches anyway (the stale-bound warning,
            // kept) and a rank no dispatch covers (a node nothing
            // evaluates). `effectiveRankCount` is the real exclusion line —
            // it is what `rebuildCompaction` buckets against — and
            // `rankDispatchNodeCount()` is the coverage as a number rather
            // than as an inference.
            engine.ensureRankTopology()
            let levels = engine.effectiveRankCount
            var uncovered = 0
            var firstUncovered = -1
            var firstUncoveredRank: UInt64 = 0
            for i in 0..<nodeCount where rank[i] >= UInt64(levels) {
                uncovered += 1
                if firstUncovered < 0 { firstUncovered = i; firstUncoveredRank = rank[i] }
            }
            var line = "rank bound: \(overCount) node(s) at or above maxRank " +
                       "\(engine.maxRank) (first node \(firstOver) rank " +
                       "\(firstOverRank), highest rank \(highest))"
            line += "; rank dispatch covers \(engine.rankDispatchNodeCount()) of " +
                    "\(nodeCount) node(s) over \(levels) rank level(s)"
            if uncovered > 0 {
                line += "; \(uncovered) node(s) at rank >= \(levels) are outside " +
                        "every dispatch (first node \(firstUncovered) rank " +
                        "\(firstUncoveredRank))"
            }
            return line
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
    ///
    /// The SHA-256 of the tmp file is taken after its fsync and
    /// before the rename; `beforeRename` (the daemon's WAL bind record) is
    /// called with it there, and a throw from it leaves `path` untouched. A
    /// stale `<path>.sha256` from the file being replaced is removed before
    /// the rename (a kill between the rename and the new manifest then leaves
    /// a manifest-less snapshot, loaded as legacy, instead of a new snapshot
    /// beside the old file's manifest, which LOAD refuses as corrupt); the
    /// manifest is then written from the same digest. `stepHook` is a test
    /// seam called at the step boundaries named by `SaveStep`; a throw from
    /// it stops the save there.
    public static func save(
        engine: DagDBEngine,
        nodeCount: Int,
        gridW: Int,
        gridH: Int,
        tickCount: UInt32,
        path clientPath: String,
        compressed: Bool = false,
        daemonEnv: SnapshotEnv = .unspecified,
        twin: TwinState? = nil,
        beforeRename: ((_ digest: [UInt8]) throws -> Void)? = nil,
        stepHook: ((SaveStep) throws -> Void)? = nil,
        manifestUnwritten: ((_ manifestPath: String, _ error: Error) -> Void)? = nil
    ) throws -> (bytesWritten: Int, uncompressedBodyBytes: Int, elapsedMs: Double) {
        let t0 = Date()

        // Ternary, on write: a state the loader would refuse is never written
        // (a SAVE that returns success can be LOADed).
        if let why = engine.ternaryStateViolation() { throw SnapError.ternary(why) }
        let library = engine.libraryBytes()
        // v8 whenever the graph has ternary content or
        // the v7 body would not fit its u32 field; a graph whose four lanes
        // sit at their defaults with an empty library is written as v7, byte
        // for byte as before (and loads back to exactly those defaults).
        let v7BodyBound = nodeCount * 42 + nodeCount * 42 / 1000 + 1024
        let writeV8 = engine.hasTernaryContent() || v7BodyBound > Int(UInt32.max)

        // The target's canonical path (its deepest existing ancestor resolved, inside the root,
        // the final component not a link); every open and rename below runs on it with no link followed.
        let path: String
        do { path = try DaemonFile.forWrite(clientPath) } catch { throw SnapError.ioFailure("open: \(Reply.errorWords(error))") }
        // The temporary carries the daemon's marker (`.<name>.dagdb-tmp-<pid>-<n>`), the only names the boot
        // sweep removes; it was once `<path>.tmp`.
        let tmpPath = DaemonFile.tmpName(for: path)
        // The target is refused by name before a byte is written when the rename would replace something that
        // is not a regular single-link file (a socket, the daemon's own included, a FIFO, a device, a
        // directory) or one of the daemon's live files, and so is a
        // live file at the old manifest's name, which a replace removes before the rename.
        if let r = DaemonFile.renameTargetRefusal(path) { throw SnapError.ioFailure("target: \(Reply.errorWords(r))") }
        if let r = DaemonFile.reservedRefusal(manifestPathFor(path)) { throw SnapError.ioFailure("target: \(Reply.errorWords(r))") }
        #if DEBUG || DAGDB_FAULT_INJECTION
        // Fault-injection seam: this snapshot's write fails
        // before its tmp file and its bind record (a loader's rebase, say).
        if DagDBFaultInjection.writeFails(path) {
            throw SnapError.ioFailure("open: \(Reply.pathWords(tmpPath)): \(DagDBFaultInjection.InjectedFault(what: "WRITE_FAIL"))")
        }
        #endif
        // Opened without blocking, no link followed, refused unless a regular file (createFile would replace a
        // FIFO or a link at the tmp name and FileHandle follow whatever was there).
        // Always a NEW file (O_EXCL), never a truncating open of what is at the name: a stale single-link tmp
        // is unlinked first, a hard-linked one refused by name (an O_TRUNC open would write the snapshot into
        // whatever inode the name held, an outside file through a hard link included).
        let tmpFd: Int32
        do { tmpFd = try DaemonFile.createTemporary(tmpPath) }
        catch { throw SnapError.ioFailure("open: \(Reply.errorWords(error))") }
        let handle = SnapWriter(fd: tmpFd, path: tmpPath)
        var committed = false
        defer {
            handle.close()
            if !committed {
                DaemonFile.unlinkNoFollow(tmpPath)
            }
        }

        // v8 body: the v3 body — rank(8N) + truth(N) + type(N) + low(4N) +
        // high(4N) + neighbors(24N) = 42N — then mode(N) + ttableId(2N) +
        // thrLo(4N) + thrHi(4N): 53N.
        let uncompressedBodySize = nodeCount * (writeV8 ? v8BodyBytesPerNode : 42)

        // Body source — direct from GPU buffers (UMA shared memory)
        let rankBytes   = engine.rankBuf.contents()
        let truthBytes  = engine.truthStateBuf.contents()
        let typeBytes   = engine.nodeTypeBuf.contents()
        let lowBytes    = engine.lut6LowBuf.contents()
        let highBytes   = engine.lut6HighBuf.contents()
        let nbBytes     = engine.neighborsBuf.contents()
        // Lanes never allocated are written as their zero defaults
        // (only a v8 file whose v7 body would overflow reaches that), without
        // allocating them.
        let lanes       = engine.ternaryLaneView
        let modeBytes   = lanes.map { UnsafeMutableRawPointer(mutating: $0.mode) }      // read-only use
        let tidBytes    = lanes.map { UnsafeMutableRawPointer(mutating: $0.ttableId) }
        let loBytes     = lanes.map { UnsafeMutableRawPointer(mutating: $0.thrLo) }
        let hiBytes     = lanes.map { UnsafeMutableRawPointer(mutating: $0.thrHi) }

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
                memcpy(dst.baseAddress!.advanced(by: off), nbBytes,    nodeCount * 6 * 4);    off += nodeCount * 6 * 4
                guard writeV8, let modeBytes = modeBytes, let tidBytes = tidBytes,
                      let loBytes = loBytes, let hiBytes = hiBytes else { return }   // Data(count:) is zero
                memcpy(dst.baseAddress!.advanced(by: off), modeBytes,  nodeCount);            off += nodeCount
                memcpy(dst.baseAddress!.advanced(by: off), tidBytes,   nodeCount * 2);        off += nodeCount * 2
                memcpy(dst.baseAddress!.advanced(by: off), loBytes,    nodeCount * 4);        off += nodeCount * 4
                memcpy(dst.baseAddress!.advanced(by: off), hiBytes,    nodeCount * 4)
            }
            let compressed = zlibCompress(buf)
            bodyBytes = compressed.count

            // A SAVE that returns success can be LOADed. Two ways the
            // compressed path could write a file `load` would refuse, both
            // silently: an encode that returned nothing (zlib expands
            // incompressible input), and a stream that
            // does not decode back to the exact body size. Check both HERE,
            // while refusing still costs the caller nothing.
            guard uncompressedBodySize == 0 || !compressed.isEmpty else {
                throw SnapError.compressionFailed(
                    "zlib produced an empty body for \(uncompressedBodySize) bytes of input")
            }
            let check = zlibDecompress(compressed, expectedSize: uncompressedBodySize)
            guard check.count == uncompressedBodySize else {
                throw SnapError.compressionFailed(
                    "compressed body decodes to \(check.count) bytes, expected " +
                    "\(uncompressedBodySize) (nodeCount \(nodeCount) × \(writeV8 ? v8BodyBytesPerNode : 42))")
            }

            let header = writeV8
                ? try buildHeaderV8(nodeCount: nodeCount, gridW: gridW, gridH: gridH,
                                    tickCount: tickCount, flags: flags, bodyLength: bodyBytes)
                : try buildHeader(nodeCount: nodeCount, gridW: gridW, gridH: gridH,
                                  tickCount: tickCount, flags: flags, bodyBytes: bodyBytes,
                                  version: versionV7)
            try handle.write(header)
            if !compressed.isEmpty {
                try compressed.withUnsafeBytes { try writeChunked(handle, $0.baseAddress!, $0.count) }
            }
        } else {
            bodyBytes = uncompressedBodySize
            let header = writeV8
                ? try buildHeaderV8(nodeCount: nodeCount, gridW: gridW, gridH: gridH,
                                    tickCount: tickCount, flags: flags, bodyLength: bodyBytes)
                : try buildHeader(nodeCount: nodeCount, gridW: gridW, gridH: gridH,
                                  tickCount: tickCount, flags: flags, bodyBytes: bodyBytes,
                                  version: versionV7)
            try handle.write(header)

            try writeChunked(handle, rankBytes, nodeCount * 8)
            try writeChunked(handle, truthBytes, nodeCount)
            try writeChunked(handle, typeBytes, nodeCount)
            try writeChunked(handle, lowBytes, nodeCount * 4)
            try writeChunked(handle, highBytes, nodeCount * 4)
            try writeChunked(handle, nbBytes, nodeCount * 6 * 4)
            if writeV8 {
                if let modeBytes = modeBytes, let tidBytes = tidBytes, let loBytes = loBytes, let hiBytes = hiBytes {
                    try writeChunked(handle, modeBytes, nodeCount)
                    try writeChunked(handle, tidBytes, nodeCount * 2)
                    try writeChunked(handle, loBytes, nodeCount * 4)
                    try writeChunked(handle, hiBytes, nodeCount * 4)
                } else {
                    try writeZeros(handle, nodeCount * 11)
                }
            }
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
        try handle.write(beSection)

        // v6 WGTS lane section — after the back-edge section, before the
        // ENVS trailer. Non-default lanes only (see versionV6 doc).
        var laneSection = Data()
        laneSection.append(contentsOf: laneSectionMagic)
        let wPtr = engine.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: nodeCount * 6)
        let aPtr = engine.activationBuf.contents().bindMemory(to: Int16.self, capacity: nodeCount)
        let vPtr = engine.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: nodeCount)
        // A lane is present when any element's BIT PATTERN differs from the
        // default's: by value, −0.0 == 0.0, so a node-value lane whose only
        // non-default bits were −0.0 would be skipped and loaded back as +0.0.
        let oneBits = Float(1.0).bitPattern, zeroBits = Float(0.0).bitPattern
        var laneFlags: UInt8 = 0
        for i in 0..<(nodeCount * 6) where wPtr[i].bitPattern != oneBits { laneFlags |= 0x01; break }
        for i in 0..<nodeCount where aPtr[i] != 0 { laneFlags |= 0x02; break }
        for i in 0..<nodeCount where vPtr[i].bitPattern != zeroBits { laneFlags |= 0x04; break }
        laneSection.append(laneFlags)
        try handle.write(laneSection)
        var laneBytes = laneSection.count
        if laneFlags & 0x01 != 0 {
            try writeChunked(handle, wPtr, nodeCount * 6 * 4)
            laneBytes += nodeCount * 6 * 4
        }
        if laneFlags & 0x02 != 0 {
            try writeChunked(handle, aPtr, nodeCount * 2)
            laneBytes += nodeCount * 2
        }
        if laneFlags & 0x04 != 0 {
            try writeChunked(handle, vPtr, nodeCount * 4)
            laneBytes += nodeCount * 4
        }

        // v8 TERN section — the table library, after WGTS.
        var ternBytes = 0
        if writeV8 {
            var ternSection = Data()
            ternSection.append(contentsOf: ternSectionMagic)
            let tableCount = library.count / TernaryReference.tableSize
            ternSection.append(tableCount > 0 ? 0x01 : 0x00)
            appendU32(&ternSection, UInt32(tableCount))
            try handle.write(ternSection)
            if tableCount > 0 { try handle.write(Data(library)) }
            ternBytes = ternSection.count + library.count
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
        try handle.write(twinSection)

        // v5 env-origin trailer — 5 bytes appended at end of file:
        // magic "ENVS" (4) + env code u8 (1).
        var envTrailer = Data()
        envTrailer.append(contentsOf: envTrailerMagic)
        envTrailer.append(daemonEnv.rawValue)
        try handle.write(envTrailer)

        // F_FULLFSYNC: macOS-specific, forces the drive to flush its own cache.
        // Plain fsync only flushes OS buffers, which is insufficient for durability
        // on Apple SSDs (see Apple TN3154 / fcntl(2)).
        let fd = handle.fd
        if fcntl(fd, F_FULLFSYNC) != 0 {
            if fsync(fd) != 0 {
                throw SnapError.ioFailure("fsync tmp: errno=\(errno)")
            }
        }
        handle.close()

        // The digest of the bytes about to become `path` (the tmp file, read
        // back after its fsync), for the bind record and the manifest alike,
        // streamed through the read helper.
        var digestError: Error? = nil                                    // the digest's own error, if any
        let digest: [UInt8]?
        do { digest = try DaemonFile.digest(tmpPath) } catch { digest = nil; digestError = error }
        try stepHook?(.tmpWritten)
        if let bind = beforeRename {
            guard let d = digest else {
                throw SnapError.ioFailure("digest: cannot read back \(Reply.pathWords(tmpPath))")
            }
            try bind(d)
        }
        let dirPath = (path as NSString).deletingLastPathComponent
        // The old file's manifest goes before the rename, so no
        // instant pairs the new snapshot with the old digest.
        let manifestPath = manifestPathFor(path)
        // The old manifest's bytes are held, so a replace or rename that fails
        // puts it back (the removal is ours and the undo one small write);
        // otherwise the failed SAVE would leave the old snapshot loading as
        // "unverified (legacy)".
        var oldManifest: Data? = nil
        var manifestRemoved = false
        if DaemonFile.lkind(manifestPath) != nil {
            // Read once, bounded, as a regular file (a FIFO there is not read, and not put back).
            oldManifest = try? DaemonFile.readIfPresent(manifestPath, .atMost(manifestMaxBytes))
            manifestRemoved = DaemonFile.unlinkNoFollow(manifestPath) == 0
            DaemonFile.syncDirectory(dirPath)
        }
        try stepHook?(.oldManifestRemoved)
        func manifestPutBack(_ why: String) -> SnapError {
            // A manifest that could not be read cannot be put back; its
            // removal is named (the removal stays before the rename, so no
            // instant pairs a new file with the old digest).
            guard let m = oldManifest else {
                guard manifestRemoved else { return SnapError.ioFailure(why) }
                return SnapError.ioFailure("\(why); \(Reply.quoted(manifestPath)) was removed before the rename and could not be read"
                    + " to be put back: \(Reply.quoted(path)) now loads unverified (legacy) until a SAVE writes it a manifest")
            }
            do {
                try DaemonFile.atomicWrite(m, to: manifestPath)
                return SnapError.ioFailure("\(why); \(Reply.quoted(manifestPath)) put back")
            } catch {
                return SnapError.ioFailure("\(why); \(Reply.quoted(manifestPath)) was removed before the rename and could not be put back (\(Reply.errorWords(error)))")
            }
        }

        // Atomic replace: one rename(2), no link followed in either path (not replaceItemAt, then moveItem
        // when the target did not exist). The target is asked again just before it.
        if let r = DaemonFile.renameTargetRefusal(path) { throw manifestPutBack("target: \(Reply.errorWords(r))") }
        let re = DaemonFile.renameNoFollow(tmpPath, path)
        if re != 0 {
            throw manifestPutBack("rename: \(DaemonFile.Refusal.io(path: path, call: "rename", errno: re))")
        }
        committed = true

        // fsync the containing directory so the rename itself is durable.
        DaemonFile.syncDirectory(dirPath)
        try stepHook?(.renamed)

        // SHA-256 manifest, written side-by-side AFTER the snapshot rename.
        // A crash between the rename and this write
        // leaves a manifest-less snapshot, which the loader treats as legacy
        // (warn + accept) — never a refusal of otherwise-good data (that
        // holds for a replaced file too: its old manifest is
        // gone before the rename). The digest is of the bytes read back from
        // disk after the tmp file's fsync (not the in-memory buffers), the
        // bytes the rename made `path`.
        if let d = digest {
            let hex = d.map { String(format: "%02x", $0) }.joined()
            // A manifest that could not be written is told to the
            // caller (SAVE names it in its reply); the snapshot itself is renamed and correct.
            do { try DaemonFile.atomicWrite(Data((hex + "\n").utf8), to: manifestPath) }
            catch { manifestUnwritten?(manifestPath, error) }
        } else if let e = digestError {
            manifestUnwritten?(manifestPath, e)                         // no digest: no manifest written either
        }
        try stepHook?(.manifestWritten)

        let total = headerSize + (writeV8 ? 8 : 0) + bodyBytes + beSection.count + laneBytes + ternBytes
            + twinSection.count + envTrailer.count
        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (total, uncompressedBodySize, elapsed)
    }

    /// Build the 32-byte header, refusing by name any field that does not fit
    /// its 32-bit slot. `internal` so the overflow test can call it without
    /// allocating a 4-billion-node engine.
    static func buildHeader(
        nodeCount: Int, gridW: Int, gridH: Int,
        tickCount: UInt32, flags: Flags, bodyBytes: Int,
        version headerVersion: UInt32 = versionV7
    ) throws -> Data {
        func fit(_ name: String, _ v: Int) throws -> UInt32 {
            guard v >= 0 && v <= Int(UInt32.max) else {
                throw SnapError.headerFieldOverflow(field: name, value: v)
            }
            return UInt32(v)
        }
        let nc = try fit("nodeCount", nodeCount)
        let gw = try fit("gridW", gridW)
        let gh = try fit("gridH", gridH)
        let bb = try fit("bodyBytes", bodyBytes)
        var header = Data(capacity: headerSize)
        header.append(contentsOf: magic)
        appendU32(&header, headerVersion)
        appendU32(&header, nc)
        appendU32(&header, gw)
        appendU32(&header, gh)
        appendU32(&header, tickCount)
        appendU32(&header, flags.rawValue)
        appendU32(&header, bb)
        return header
    }

    /// The v8 header: the same 32 bytes with `bodyBytes`@28 = 0xFFFFFFFF,
    /// then the u64 body length — 40 bytes in all. nodeCount, gridW and
    /// gridH still refuse by name what does not fit their u32 fields.
    static func buildHeaderV8(
        nodeCount: Int, gridW: Int, gridH: Int,
        tickCount: UInt32, flags: Flags, bodyLength: Int
    ) throws -> Data {
        var h = try buildHeader(nodeCount: nodeCount, gridW: gridW, gridH: gridH,
                                tickCount: tickCount, flags: flags, bodyBytes: 0,
                                version: versionV8)
        h.replaceSubrange(28..<32, with: withUnsafeBytes(of: bodyBytesSentinel.littleEndian) { Data($0) })
        var len = UInt64(bodyLength).littleEndian
        h.append(Data(bytes: &len, count: 8))
        return h
    }

    // MARK: - Load

    /// Where LOAD's bytes come from. The file (`DaemonFile.Reader`: one non-blocking open of a
    /// regular, contained file, each read bounded and hashed as it is read), or bytes a caller has already read
    /// once (a tile body, whose hash the router checks on the same copy).
    final class LoadSource {
        let reader: DaemonFile.Reader?
        let data: Data?
        let size: Int
        private(set) var offset = 0
        private var hasher: SHA256? = nil
        var remaining: Int { size - offset }

        init(reader: DaemonFile.Reader) { self.reader = reader; self.data = nil; self.size = reader.size }
        init(data: Data) { self.reader = nil; self.data = data; self.size = data.count }

        func hashFromStart() {
            if let r = reader { r.hashFromStart() } else if hasher == nil { hasher = SHA256() }
        }

        /// The next `n` bytes (n <= remaining): the reader's own new buffer, or a slice (no copy).
        func read(_ n: Int) throws -> Data {
            precondition(n >= 0 && n <= remaining)
            defer { offset += n }
            if let r = reader { return try r.read(n) }
            let lo = data!.startIndex + offset
            let d = data![lo..<(lo + n)]
            hasher?.update(data: d)
            return d
        }

        /// The rest, hashed and not kept; then (a file) the fstat after the read.
        func finish() throws {
            if let r = reader { try r.finish(whole: true); offset = size; return }
            if remaining > 0 { _ = try read(remaining) }
        }

        func digest() -> [UInt8]? { reader.map { $0.digest() } ?? hasher.map { Array($0.finalize()) } }
    }

    /// Restore all engine buffers from a snapshot file. nodeCount must match engine.
    /// - Parameter validate: check the slot rule and the back-edge rules on the
    ///   decoded body before anything is committed (O(N), CPU).
    /// - Parameter slotRule: `.persistence` (the slot model, the
    ///   default) or `.rankModeDAG` (TILED OPEN's tile bodies).
    /// - Parameter keepDanglingHookIds: recovery's
    ///   startup load keeps a clock's id of a hook the file does not hold (an
    ///   older build's HOOK CLOSE), the marker the WAL's older records replay
    ///   against; every other load drops it (`TwinState.restore`).
    /// - Parameter allowUnverified: a `.sha256` sidecar that exists but cannot be read (not a
    ///   regular file, outside the root, too long, holding no digest) refuses the load as unverified unless this
    ///   is set (LOAD … UNVERIFIED); an absent sidecar is the legacy case, loaded unverified with a warning.
    /// - Parameter wantDigest: the file is hashed as it is read even with no sidecar, so the
    ///   caller (startup recovery's bind lookup) never reads it a second time.
    /// - Parameter admit: the caller's admission on the bytes the load holds (the file's true
    ///   size at the open; a compressed body's decoded size after the header), asked before they are read.
    ///
    /// A load that throws has changed nothing (every check runs
    /// before the commit, the twin state is staged).
    ///
    /// The file is opened once, without blocking, as a regular file inside the root, and read
    /// once in file order, each section straight into the buffer it is decoded and committed from (the body
    /// into the staged body, the lanes into staged lanes): no mapping (so no race between the hash and the
    /// decode, and no SIGBUS on a cut file) and no second copy of the file. A file cut or changed while it is
    /// read is refused by name.
    public static func load(
        engine: DagDBEngine,
        nodeCount: Int,
        gridW: Int,
        gridH: Int,
        path: String,
        validate: Bool = true,
        slotRule: SlotRule = .persistence,
        daemonEnv: SnapshotEnv = .unspecified,
        verifyManifest: Bool = true,
        twin: TwinState? = nil,
        keepDanglingHookIds: Bool = false,
        allowUnverified: Bool = false,
        wantDigest: Bool = false,
        admit: ((Int, String) -> String?)? = nil,
        beforeCommit: ((TwinState?, Int, Int) throws -> Void)? = nil,
        capsAsEra: Bool = false
    ) throws -> LoadResult {
        let reader: DaemonFile.Reader
        do {
            reader = try DaemonFile.Reader(path, admit: admit.map { a in { a($0, "the file's \($0) B, read once into its staged sections") } })
        } catch DaemonFile.Refusal.missing {
            throw SnapError.ioFailure("file not found: \(Reply.quoted(path))")
        } catch DaemonFile.Refusal.admission(let line) {
            throw SnapError.admission(line)
        } catch let r as DaemonFile.Refusal {
            throw SnapError.ioFailure("\(Reply.errorWords(r))")
        }
        return try load(engine: engine, nodeCount: nodeCount, gridW: gridW, gridH: gridH, path: path,
                        source: LoadSource(reader: reader), validate: validate, slotRule: slotRule,
                        daemonEnv: daemonEnv, verifyManifest: verifyManifest, twin: twin,
                        keepDanglingHookIds: keepDanglingHookIds, allowUnverified: allowUnverified,
                        wantDigest: wantDigest, admit: admit, beforeCommit: beforeCommit, capsAsEra: capsAsEra)
    }

    /// `load` on bytes the caller has already read once from `path` (a tile body, whose hash
    /// the router checks on this same copy); `path` names the file and its sidecar.
    public static func load(
        engine: DagDBEngine, nodeCount: Int, gridW: Int, gridH: Int, path: String, data: Data,
        validate: Bool = true, slotRule: SlotRule = .persistence, daemonEnv: SnapshotEnv = .unspecified,
        verifyManifest: Bool = true, twin: TwinState? = nil, keepDanglingHookIds: Bool = false
    ) throws -> LoadResult {
        try load(engine: engine, nodeCount: nodeCount, gridW: gridW, gridH: gridH, path: path,
                 source: LoadSource(data: data), validate: validate, slotRule: slotRule, daemonEnv: daemonEnv,
                 verifyManifest: verifyManifest, twin: twin, keepDanglingHookIds: keepDanglingHookIds,
                 allowUnverified: false, wantDigest: false, admit: nil, beforeCommit: nil)
    }

    static func load(
        engine: DagDBEngine, nodeCount: Int, gridW: Int, gridH: Int, path: String, source src: LoadSource,
        validate: Bool, slotRule: SlotRule, daemonEnv: SnapshotEnv, verifyManifest: Bool, twin: TwinState?,
        keepDanglingHookIds: Bool, allowUnverified: Bool, wantDigest: Bool, admit: ((Int, String) -> String?)?,
        beforeCommit: ((TwinState?, Int, Int) throws -> Void)? = nil, capsAsEra: Bool = false
    ) throws -> LoadResult {
        do {
            return try loadParsed(engine: engine, nodeCount: nodeCount, gridW: gridW, gridH: gridH, path: path,
                                  source: src, validate: validate, slotRule: slotRule, daemonEnv: daemonEnv,
                                  verifyManifest: verifyManifest, twin: twin, keepDanglingHookIds: keepDanglingHookIds,
                                  allowUnverified: allowUnverified, wantDigest: wantDigest, admit: admit,
                                  beforeCommit: beforeCommit, capsAsEra: capsAsEra)
        } catch let r as DaemonFile.Refusal {
            // A read cut short, a file changed while read, an I/O error: by name, nothing changed.
            throw SnapError.ioFailure("\(Reply.errorWords(r))")
        }
    }

    private static func loadParsed(
        engine: DagDBEngine, nodeCount: Int, gridW: Int, gridH: Int, path: String, source src: LoadSource,
        validate: Bool, slotRule: SlotRule, daemonEnv: SnapshotEnv, verifyManifest: Bool, twin: TwinState?,
        keepDanglingHookIds: Bool, allowUnverified: Bool, wantDigest: Bool, admit: ((Int, String) -> String?)?,
        beforeCommit: ((TwinState?, Int, Int) throws -> Void)?, capsAsEra: Bool
    ) throws -> LoadResult {
        let t0 = Date()
        guard src.size >= headerSize else {
            throw SnapError.ioFailure("file too short: \(src.size) bytes")
        }

        // The SHA-256 manifest is checked BEFORE any buffer is touched, so a corrupt snapshot is refused
        // loudly and never half-loaded. The sidecar is read once, bounded, as a regular file inside the root.
        // Absent = a legacy snapshot: warn and accept. Present but unreadable (a FIFO, a directory, a link out
        // of the root, too long, no digest in it) = refused as unverified, unless the caller asked for
        // unverified (never loaded unverified silently).
        var expected: String? = nil
        var unverified: String? = nil                                             // why the load is unverified, if it is
        if verifyManifest {
            let manifestPath = manifestPathFor(path)
            do {
                if let mData = try DaemonFile.readIfPresent(manifestPath, .atMost(manifestMaxBytes)) {
                    let text = String(data: mData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let t = text, !t.isEmpty else {
                        throw DaemonFile.Refusal.size(path: manifestPath, have: mData.count,
                                                      rule: "holds no sha256 digest (empty, or not UTF-8)")
                    }
                    expected = t
                } else {
                    unverified = "no manifest"
                    FileHandle.standardError.write(Data(
                        "WARN: snapshot \(path) has no .sha256 manifest — loading unverified (legacy)\n".utf8))
                }
            } catch let r as DaemonFile.Refusal {
                guard allowUnverified else { throw SnapError.unverified(path: path, why: "\(Reply.errorWords(r))") }
                unverified = "the manifest cannot be read (UNVERIFIED asked)"
                FileHandle.standardError.write(Data(
                    "WARN: snapshot \(path): its .sha256 manifest cannot be read (\(Reply.errorWords(r))) — loading unverified (UNVERIFIED asked)\n".utf8))
            }
        }
        if expected != nil || wantDigest { src.hashFromStart() }

        // A structural refusal found while reading waits until the whole file is read and hashed: a file
        // whose bytes do not match its manifest is refused as such first, as when the whole file was hashed
        // before the walk (main's order). With no manifest it is thrown at once.
        func fail(_ e: Error) throws -> Never {
            if expected != nil {
                try src.finish()
                try checkManifest()
            }
            throw e
        }
        func checkManifest() throws {
            guard let exp = expected, let dg = src.digest() else { return }
            let actual = dg.map { String(format: "%02x", $0) }.joined()
            guard actual == exp else { throw SnapError.manifestMismatch(expected: exp, actual: actual) }
        }
        func need(_ n: Int, _ e: @autoclosure () -> Error) throws {
            if n < 0 || src.remaining < n { try fail(e()) }
        }
        func u32(_ d: Data, _ o: Int) -> UInt32 { readU32(d, d.startIndex + o) }

        // Header
        let header = try src.read(headerSize)
        let m = [UInt8](header.prefix(4))
        guard m == magic else { try fail(SnapError.invalidMagic) }
        let ver = u32(header, 4)
        guard ver == versionV1 || ver == versionV2 || ver == versionV3
                || ver == versionV4 || ver == versionV5 || ver == versionV6
                || ver == versionV7 || ver == versionV8 else {
            try fail(SnapError.unsupportedVersion(ver))
        }
        let fileNC    = Int(u32(header, 8))
        let fileGW    = Int(u32(header, 12))
        let fileGH    = Int(u32(header, 16))
        let fileTicks = u32(header, 20)
        let flags     = Flags(rawValue: u32(header, 24))
        // v8: `bodyBytes`@28 is the sentinel and the u64 after the header is
        // the length; the body starts 8 bytes later.
        let isV8 = ver == versionV8
        let bodyStart = isV8 ? headerSize + 8 : headerSize
        let bodyBytes: Int
        if isV8 {
            guard u32(header, 28) == bodyBytesSentinel else {
                try fail(SnapError.ioFailure("v8 header bodyBytes is 0x\(String(u32(header, 28), radix: 16)), expected the 0xffffffff sentinel"))
            }
            try need(8, SnapError.ioFailure("v8 file is missing the u64 body length"))
            let lenData = try src.read(8)
            let len = UInt64(u32(lenData, 0)) | UInt64(u32(lenData, 4)) << 32
            guard len <= UInt64(Int.max) else { try fail(SnapError.ioFailure("v8 body length \(len) does not fit")) }
            bodyBytes = Int(len)
        } else {
            bodyBytes = Int(u32(header, 28))
        }

        guard fileNC == nodeCount else {
            try fail(SnapError.nodeCountMismatch(file: fileNC, engine: nodeCount))
        }
        guard fileGW == gridW && fileGH == gridH else {
            try fail(SnapError.gridMismatch(fileW: fileGW, fileH: fileGH, engineW: gridW, engineH: gridH))
        }

        // Rank width per version: v1 = 1 byte (u8), v2 = 4 (u32),
        // v3/v4/v5/v6/v7 = 8 (u64). v4 added a back-edge trailer; v5 added
        // an env-origin trailer on top of v4; v6 added a WGTS lane section;
        // v7 added a TWIN section.
        let rankBytesPerNode: Int
        switch ver {
        case versionV1: rankBytesPerNode = 1
        case versionV2: rankBytesPerNode = 4
        case versionV3, versionV4, versionV5, versionV6, versionV7, versionV8: rankBytesPerNode = 8
        default:        rankBytesPerNode = 1  // unreachable (guarded above)
        }
        // body = rank + truth(1) + type(1) + lut_low(4) + lut_high(4) + neighbors(24)
        //        (+ v8: mode(1) + ttableId(2) + thrLo(4) + thrHi(4))
        let ternBodyBytesPerNode = isV8 ? v8BodyBytesPerNode - 42 : 0
        let uncompressedBodySize = nodeCount * (34 + rankBytesPerNode + ternBodyBytesPerNode)

        // The body, read straight into the buffer it is checked and committed from — the raw bytes, or the
        // zlib-decoded buffer (its decoded size admitted before it is allocated).
        let bodyData: Data
        if flags.contains(.compressed) {
            // bodyBytes is the compressed size on disk. Guard against a
            // physically truncated file: the header can declare a body the
            // file doesn't actually contain (the crash-during-write artifact).
            try need(bodyBytes, SnapError.ioFailure("file truncated: header declares \(bodyBytes) compressed body bytes, file has \(src.size - bodyStart) after header"))
            if let a = admit, let e = a(uncompressedBodySize, "the decoded body's \(uncompressedBodySize) B") {
                try fail(SnapError.admission(e))
            }
            let compressedSlice = try src.read(bodyBytes)
            bodyData = zlibDecompress(compressedSlice, expectedSize: uncompressedBodySize)
            guard bodyData.count == uncompressedBodySize else {
                try fail(SnapError.ioFailure("decompressed body size \(bodyData.count) != expected \(uncompressedBodySize)"))
            }
        } else {
            // v1 backward compat: files written before the flags/bodyBytes fields existed
            // have bodyBytes = 0 in the header (those bytes were reserved = 0). Fall back
            // to computing from nodeCount. A v8 file postdates that: its u64 is the
            // length, and a 0 there is a wrong length, not the legacy marker.
            let effectiveBody = (bodyBytes == 0 && !isV8) ? uncompressedBodySize : bodyBytes
            guard effectiveBody == uncompressedBodySize else {
                try fail(SnapError.ioFailure("body size \(effectiveBody) != expected \(uncompressedBodySize)"))
            }
            // Same truncation guard as the compressed path.
            try need(effectiveBody, SnapError.ioFailure("file truncated: expected \(effectiveBody) body bytes, file has \(src.size - bodyStart) after header"))
            bodyData = try src.read(effectiveBody)
        }

        // v4+ back-edge section: its count, then the entries (range-checked below, after the body's checks).
        var beRaw = Data()
        var beCount = 0
        let beSectionStart = src.offset
        if ver >= versionV4 {
            try need(4, SnapError.ioFailure("v\(ver) file is missing the back-edge count"))
            beCount = Int(u32(try src.read(4), 0))
            try need(beCount * 8, SnapError.ioFailure("v\(ver) file truncated mid-back-edge-section: " +
                                                      "need \(4 + beCount * 8) bytes, have \(src.size - beSectionStart)"))
            beRaw = try src.read(beCount * 8)
        }

        // v6+ WGTS lane section: magic "WGTS" (4) + lane flags u8 + the present lanes, each into its own
        // staged buffer.
        var wData: Data? = nil, aData: Data? = nil, vData: Data? = nil
        if ver >= versionV6 {
            try need(5, SnapError.ioFailure("v6 file is missing the WGTS lane section"))
            let lh = try src.read(5)
            let laneMagic = [UInt8](lh.prefix(4))
            guard laneMagic == laneSectionMagic else {
                try fail(SnapError.ioFailure("v6 lane-section magic mismatch: got 0x\(laneMagic.map { String(format: "%02x", $0) }.joined()), expected 'WGTS' (0x57475453)"))
            }
            let laneFlags = lh[lh.startIndex + 4]
            // Bits 3–7 are not defined at this version; name the lane bit.
            let unknownLaneBits = laneFlags & ~UInt8(0x07)
            guard unknownLaneBits == 0 else { try fail(SnapError.unknownLaneFlag(unknownLaneBits)) }
            if laneFlags & 0x01 != 0 {
                try need(nodeCount * 6 * 4, SnapError.ioFailure("v6 file truncated mid-edge-weight lane"))
                wData = try src.read(nodeCount * 6 * 4)
            }
            if laneFlags & 0x02 != 0 {
                try need(nodeCount * 2, SnapError.ioFailure("v6 file truncated mid-activation lane"))
                aData = try src.read(nodeCount * 2)
            }
            if laneFlags & 0x04 != 0 {
                try need(nodeCount * 4, SnapError.ioFailure("v6 file truncated mid-node-value lane"))
                vData = try src.read(nodeCount * 4)
            }
        }

        // v8 TERN section — the table library, after WGTS.
        var v8Library: [UInt8] = []
        if isV8 {
            try need(9, SnapError.ioFailure("v8 file is missing the TERN section"))
            let th = try src.read(9)
            let tm = [UInt8](th.prefix(4))
            guard tm == ternSectionMagic else {
                try fail(SnapError.ioFailure("v8 TERN-section magic mismatch: got 0x\(tm.map { String(format: "%02x", $0) }.joined()), expected 'TERN' (0x5445524e)"))
            }
            let tflags = th[th.startIndex + 4]
            if tflags & ~UInt8(0x01) != 0 { try fail(SnapError.unknownTernFlag(tflags & ~UInt8(0x01))) }
            let count = Int(u32(th, 5))
            if (tflags & 0x01 != 0) != (count > 0) {
                try fail(SnapError.ioFailure("v8 TERN section: library flag \(tflags & 1) disagrees with table count \(count)"))
            }
            guard count <= TernaryReference.maxTables else {
                try fail(SnapError.ternary("TERN section holds \(count) tables, more than \(TernaryReference.maxTables)"))
            }
            let len = count * TernaryReference.tableSize
            try need(len, SnapError.ioFailure("v8 file truncated mid-TERN-section"))
            v8Library = [UInt8](try src.read(len))
        }

        // v7 TWIN section — magic "TWIN" (4) + u32 byteLength (4) + JSON payload, decoded after the checks.
        var twinData: Data? = nil
        if ver >= versionV7 {
            try need(8, SnapError.ioFailure("v7 file truncated mid-twin-section"))
            let tw = try src.read(8)
            let twinMagic = [UInt8](tw.prefix(4))
            guard twinMagic == twinSectionMagic else {
                try fail(SnapError.ioFailure("v7 twin-section magic mismatch: got 0x\(twinMagic.map { String(format: "%02x", $0) }.joined()), expected 'TWIN' (0x5457494e)"))
            }
            let twinLen = Int(u32(tw, 4))
            try need(twinLen, SnapError.ioFailure("v7 file truncated mid-twin-section"))
            twinData = try src.read(twinLen)
        }

        // v5+ env-origin trailer — 5 bytes: magic "ENVS" + env code u8.
        var fileEnv = SnapshotEnv.unspecified
        if ver >= versionV5 {
            try need(5, SnapError.ioFailure("v\(ver) file is missing the env-origin trailer (need 5 bytes, have \(src.remaining))"))
            let tr = try src.read(5)
            let trailerMagic = [UInt8](tr.prefix(4))
            guard trailerMagic == envTrailerMagic else {
                try fail(SnapError.ioFailure("v\(ver) env-trailer magic mismatch: got 0x\(trailerMagic.map { String(format: "%02x", $0) }.joined()), expected 'ENVS' (0x454e5653)"))
            }
            fileEnv = SnapshotEnv(rawValue: tr[tr.startIndex + 4]) ?? .unspecified
        }
        let totalRead = src.offset

        // Every byte read (any after the trailer only hashed), the file unchanged since its open, and the
        // manifest: before any check of what the bytes hold.
        try src.finish()
        try checkManifest()

        // Validate decoded bytes BEFORE writing to live buffers.
        if validate {
            if let violation = validateDecodedBody(
                body: bodyData, nodeCount: nodeCount, rankBytesPerNode: rankBytesPerNode, rule: slotRule
            ) {
                throw SnapError.validationFailed(violation)
            }
        }
        if isV8, let why = TernaryReference.libraryRefusal(v8Library) { throw SnapError.ternary(why) }

        // The back-edge section's staging admitted before it is built, on top
        // of the file's bytes now held: the staged src/dst arrays and the lists they are committed into (the
        // section's own bytes are in the file's charge). Measured 8.1 B per edge + 256 KiB, plus the 10 %.
        if let a = admit, beCount > 0,
           let line = a(Int(AdmissionCharge.backEdgeStaging(edges: beCount).rounded(.up)),
                        "the back-edge section's staging, \(AdmissionCharge.backEdgeStagingPerEdge) B per edge + 256 KiB for \(beCount) edges") {
            throw SnapError.admission(line)
        }
        // The back-edge entries, range-checked BEFORE the commit.
        var beSrcs: [UInt32] = [], beDsts: [UInt32] = []
        beSrcs.reserveCapacity(beCount); beDsts.reserveCapacity(beCount)
        for i in 0..<beCount {
            let src = u32(beRaw, i * 8), dst = u32(beRaw, i * 8 + 4)
            // Range-check before the unchecked add: a corrupt/crafted file
            // with src or dst >= nodeCount would write past isRegisterBuf.
            guard Int(src) < nodeCount && Int(dst) < nodeCount else {
                throw SnapError.ioFailure("back-edge entry \(i) out of range: src=\(src) dst=\(dst) nodeCount=\(nodeCount)")
            }
            beSrcs.append(src); beDsts.append(dst)
        }
        beRaw = Data()

        // CONNECT BACK's rules on every entry, against the STAGED
        // body's mode (v8) and neighbour lanes, before anything is committed.
        if validate, !beSrcs.isEmpty {
            let nbOff = (rankBytesPerNode + 2) * nodeCount + 8 * nodeCount
            let refusal: DagDBEngine.BackEdgeEntryRefusal? = bodyData.withUnsafeBytes { raw in
                let nb = UnsafeRawBufferPointer(rebasing: raw[nbOff..<(nbOff + nodeCount * 24)])
                let mode = isV8 ? UnsafeRawBufferPointer(rebasing: raw[(42 * nodeCount)..<(43 * nodeCount)]) : nil
                return DagDBEngine.backEdgeListRefusal(list: "back-edge section", srcs: beSrcs, dsts: beDsts,
                                                       nodeCount: nodeCount, modeBytes: mode, neighborBytes: nb)
            }
            if let r = refusal { throw r }
        }

        if isV8 {
            var dsts: [UInt8]? = nil
            if !beDsts.isEmpty {
                var f = [UInt8](repeating: 0, count: nodeCount)
                for d in beDsts { f[Int(d)] = 1 }
                dsts = f
            }
            if let why = ternaryBodyViolation(body: bodyData, nodeCount: nodeCount,
                                              registers: dsts, library: v8Library) {
                throw SnapError.ternary(why)
            }
        }

        // v6+ · a non-finite edge weight (SET WEIGHT's rule) or node value
        // (SET VALUE's rule) is refused by name before a single buffer is
        // written.
        if let w = wData, let why = w.withUnsafeBytes({ weightRefusal($0.baseAddress!, count: nodeCount * 6) }) {
            throw SnapError.validationFailed(why)
        }
        if let v = vData, let why = v.withUnsafeBytes({ nodeValueRefusal($0.baseAddress!, count: nodeCount) }) {
            throw SnapError.validationFailed(why)
        }

        // Cross-env load rejection: if both daemon and file have a real env
        // (not unspecified) and they differ, reject.
        if daemonEnv != .unspecified && fileEnv != .unspecified && daemonEnv != fileEnv {
            throw SnapError.envMismatch(file: fileEnv, daemon: daemonEnv)
        }

        // The twin state the file carries, restored into a staged TwinState
        // (v1..v6 files and an empty section: a fresh, empty one). Swapped in at the commit.
        var stagedTwin: TwinState? = nil
        if twin != nil {
            let staged = TwinState()
            if let twinData = twinData, !twinData.isEmpty {
                // The decode admitted before it runs, 1.1 x 58.3 B per token of the section,
                // its tokens counted by TILED OPEN's allocation-free pre-scan on the bytes about to be decoded.
                if let a = admit {
                    let tokens = AdmissionCharge.jsonTokens(twinData)
                    if let line = a(Int(AdmissionCharge.twinDecode(tokens: tokens, bytes: twinData.count).rounded(.up)),
                                    "the twin section's decode, \(AdmissionCharge.twinDecodePerToken) B per token +"
                                        + " \(AdmissionCharge.twinDecodePerByte) B per byte for \(tokens) tokens (its , : [ { bytes + 1)"
                                        + " and \(twinData.count) B") {
                        throw SnapError.admission(line)
                    }
                }
                do {
                    // Banks decoded spec-only (`WaveBank.deferAtoms`); their atoms are built in `restore`, admitted.
                    let snap = try WaveBank.$deferAtoms.withValue(true) {
                        try JSONDecoder().decode(TwinState.Snapshot.self, from: twinData)
                    }
                    // What no live verb lets a daemon hold is refused before anything is restored.
                    // The startup load (`capsAsEra`) refuses a shape only; its
                    // over-cap counts are the era's, loaded and named at boot. LOAD refuses both: a LOAD is a new import.
                    if let why = capsAsEra ? TwinState.snapshotShapeRefusal(snap) : TwinState.snapshotRefusal(snap) {
                        throw SnapError.twinRefused(why)
                    }
                    try staged.restore(snap, keepDanglingHookIds: keepDanglingHookIds, admit: admit)
                    // A live LOAD is a new import, so a name over the cap (one no live verb writes, the restored
                    // alarm sets' record keys included) refuses it, as the over-cap counts do; only the startup
                    // load (`capsAsEra`) and replay load an older one and name it.
                    if !capsAsEra, let why = staged.overLongNamesRefusal() { throw SnapError.twinRefused(why) }
                } catch let e as SnapError {
                    throw e
                } catch let r as DaemonFile.Refusal where r.isAdmission {
                    throw SnapError.admission(r.replyLine ?? Reply.errorWords(r))  // a bank or hook rows
                } catch let r as TwinState.RestoreFileRefusal {
                    // A file the twin section names that the daemon may not read (not a regular
                    // file, outside the root, changed while read) refuses the load by name; nothing changed.
                    if let line = r.replyLine { throw SnapError.admission(line) }      // one code
                    throw SnapError.ioFailure("v7 twin section: " + Reply.errorWords(r))
                } catch {
                    throw SnapError.ioFailure("v7 twin section undecodable: \(Reply.errorWords(error))")
                }
            }
            stagedTwin = staged
        }
        twinData = nil

        // The caller's last check, on what the load is about to leave (the staged
        // twin state, the back edges, the library's tables), before anything is committed: LOAD admits its rebase
        // SAVE here, so a budget that cannot take that SAVE refuses the LOAD with nothing changed.
        try beforeCommit?(stagedTwin ?? twin, beSrcs.count, isV8 ? v8Library.count / TernaryReference.tableSize : 0)

        // The library's room, the one fallible
        // step of `replaceLibrary`, before the commit.
        if isV8 {
            try engine.reserveTableCapacity(v8Library.count / TernaryReference.tableSize)
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
                for i in 0..<nodeCount { dstU64[i] = UInt64(base.loadUnaligned(fromByteOffset: off + i * 4, as: UInt32.self)) }
                off += nodeCount * 4
            default:  // v3 / v4 / v5 / v6 / v7
                memcpy(engine.rankBuf.contents(), base.advanced(by: off), nodeCount * 8)
                off += nodeCount * 8
            }
            memcpy(engine.truthStateBuf.contents(), base.advanced(by: off), nodeCount);             off += nodeCount
            memcpy(engine.nodeTypeBuf.contents(),   base.advanced(by: off), nodeCount);             off += nodeCount
            memcpy(engine.lut6LowBuf.contents(),    base.advanced(by: off), nodeCount * 4);         off += nodeCount * 4
            memcpy(engine.lut6HighBuf.contents(),   base.advanced(by: off), nodeCount * 4);         off += nodeCount * 4
            memcpy(engine.neighborsBuf.contents(),  base.advanced(by: off), nodeCount * 6 * 4); off += nodeCount * 6 * 4
            if isV8 {
                // An all-default set of lanes leaves them unallocated.
                engine.installTernaryLanes(mode: base.advanced(by: off),
                                           ttableId: base.advanced(by: off + nodeCount),
                                           thrLo: base.advanced(by: off + nodeCount * 3),
                                           thrHi: base.advanced(by: off + nodeCount * 7))
                off += nodeCount * 11
            }
        }
        // The library (v8), or a binary graph's empty one (v1–v7).
        if isV8 {
            try engine.replaceLibrary(v8Library)
        } else {
            engine.resetTernaryLanes()
        }

        // v4 back-edge section — read and checked above. v1/v2/v3 files have
        // no section; load resets the back-edge list to empty.
        engine.backEdgeSrcs.removeAll(keepingCapacity: false)
        engine.backEdgeDsts.removeAll(keepingCapacity: false)
        // The lists are restored at exactly their count. Appending them one by one grew each to up to 2x
        // (3,145,728 slots for 1,572,864 edges measured), and the budget ledger counts allocated slots, so a
        // restored state's committed bytes would read up to twice its edges'.
        if ver >= versionV4 && !beSrcs.isEmpty {
            engine.backEdgeSrcs.reserveCapacity(beSrcs.count)
            engine.backEdgeDsts.reserveCapacity(beDsts.count)
        }
        let regPtr = engine.isRegisterBuf.contents()
            .bindMemory(to: UInt8.self, capacity: nodeCount)
        for i in 0..<nodeCount { regPtr[i] = 0 }

        // Weight/value lanes: reset to defaults on EVERY load path; present lanes overwrite them below.
        let wDefPtr = engine.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: nodeCount * 6)
        for i in 0..<(nodeCount * 6) { wDefPtr[i] = 1.0 }
        let aDefPtr = engine.activationBuf.contents().bindMemory(to: Int16.self, capacity: nodeCount)
        for i in 0..<nodeCount { aDefPtr[i] = 0 }
        let vDefPtr = engine.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: nodeCount)
        for i in 0..<nodeCount { vDefPtr[i] = 0.0 }

        if ver >= versionV4 {
            for i in 0..<beSrcs.count {
                try engine.addBackEdgeUnchecked(src: beSrcs[i], dst: beDsts[i])
            }
        }

        // v6+ lanes, from their staged buffers.
        wData?.withUnsafeBytes { memcpy(engine.edgeWeightsBuf.contents(), $0.baseAddress!, nodeCount * 6 * 4) }
        aData?.withUnsafeBytes { memcpy(engine.activationBuf.contents(), $0.baseAddress!, nodeCount * 2) }
        vData?.withUnsafeBytes { memcpy(engine.nodeValueBuf.contents(), $0.baseAddress!, nodeCount * 4) }

        // The staged twin state, swapped in.
        if let t = twin, let staged = stagedTwin {
            t.adopt(staged)
        }

        // The rank buffer was overwritten above, so the compacted
        // dispatch lists are stale.
        engine.markRankTopologyDirty()

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return LoadResult(bytesRead: totalRead, fileNodeCount: fileNC, fileTicks: fileTicks, elapsedMs: elapsed,
                          digest: src.digest(), unverified: unverified)
    }

    /// The most bytes a `.sha256` sidecar may hold (64 hex digits and a newline, with room).
    public static let manifestMaxBytes = 4096

    // MARK: - Edge weights and node values on load

    /// The first non-finite edge weight among `count` f32s at `raw` (slot k
    /// = node k / 6, slot k % 6), as a refusal that names it, or nil. The
    /// rule is SET WEIGHT's ("weight must be finite"), applied on every load
    /// and restore path that carries the lane: LOAD, IMPORT MORTON, LOAD
    /// JSON, LOAD CSV, BACKUP RESTORE (the base and every diff applied).
    public static func weightRefusal(_ raw: UnsafeRawPointer, count: Int) -> String? {
        for k in 0..<count {
            let bits = raw.loadUnaligned(fromByteOffset: k * 4, as: UInt32.self)
            if let why = weightRefusal(bits: bits, node: k / 6, slot: k % 6) { return why }
        }
        return nil
    }

    /// One weight's refusal (the text every path uses), or nil when finite.
    public static func weightRefusal(bits: UInt32, node: Int, slot: Int) -> String? {
        let v = Float(bitPattern: bits)
        if v.isFinite { return nil }
        return "edge weight node=\(node) slot=\(slot) is \(v) (bits 0x\(String(bits, radix: 16))); a weight must be finite"
    }

    /// The first non-finite node value among `count` f32s at `raw`, as a
    /// refusal that names it, or nil. SET VALUE's rule ("value must be
    /// finite"), applied on WAL replay, on every write path and on every
    /// load and restore path, as the weight rule is.
    public static func nodeValueRefusal(_ raw: UnsafeRawPointer, count: Int) -> String? {
        for k in 0..<count {
            let bits = raw.loadUnaligned(fromByteOffset: k * 4, as: UInt32.self)
            if let why = nodeValueRefusal(bits: bits, node: k) { return why }
        }
        return nil
    }

    /// One node value's refusal, or nil when finite.
    public static func nodeValueRefusal(bits: UInt32, node: Int) -> String? {
        let v = Float(bitPattern: bits)
        if v.isFinite { return nil }
        return "node value node=\(node) is \(v) (bits 0x\(String(bits, radix: 16))); a value must be finite"
    }

    /// On write: the engine's edge-weight and
    /// node-value lanes hold only finite values, or the first one that does
    /// not is named. The daemon's write verbs — SAVE (plain and COMPRESSED,
    /// and the auto-snapshot), SAVE JSON, SAVE CSV, SAVE TILED, EXPORT
    /// MORTON, BACKUP INIT and BACKUP APPEND — check it before they write
    /// anything, so a write that succeeds can be loaded (every load path
    /// refuses a non-finite weight or value, so a load that succeeds can be
    /// saved). The library writers stay permissive: the tests craft their
    /// non-finite files through them.
    public static func finiteLaneRefusal(engine: DagDBEngine, nodeCount: Int) -> String? {
        weightRefusal(UnsafeRawPointer(engine.edgeWeightsBuf.contents()), count: nodeCount * 6)
            ?? nodeValueRefusal(UnsafeRawPointer(engine.nodeValueBuf.contents()), count: nodeCount)
    }

    /// The WGTS edge-weight and node-value lanes of a v6+ file (after the
    /// back-edge section that follows the body), checked before any buffer
    /// is written: weights and node values alike. A file whose sections do not parse here is left to
    /// the loader's own named errors further on; this walk only refuses a
    /// lane value it can read.
    static func wgtsLaneRefusal(data: Data, afterBody: Int, nodeCount: Int) -> String? {
        var off = afterBody
        guard off >= 0, data.count >= off + 4 else { return nil }
        off += 4 + Int(readU32(data, off)) * 8
        guard data.count >= off + 5, [UInt8](data[off..<off + 4]) == laneSectionMagic else { return nil }
        let laneFlags = data[off + 4]
        off += 5
        // Lane order in the section: weights (bit 0), activation (bit 1),
        // node values (bit 2) — each present only when its bit is set.
        if laneFlags & 0x01 != 0 {
            let size = nodeCount * 6 * 4
            guard data.count >= off + size else { return nil }
            if let why = data.withUnsafeBytes({ raw in
                weightRefusal(raw.baseAddress!.advanced(by: off), count: nodeCount * 6) }) { return why }
            off += size
        }
        if laneFlags & 0x02 != 0 { off += nodeCount * 2 }
        if laneFlags & 0x04 != 0 {
            guard data.count >= off + nodeCount * 4 else { return nil }
            return data.withUnsafeBytes { raw in
                nodeValueRefusal(raw.baseAddress!.advanced(by: off), count: nodeCount)
            }
        }
        return nil
    }

    // MARK: - v8 section walkers (pre-commit)

    /// The back-edge destinations of the section at `at`, as a register flag
    /// per node, or nil when there are none.
    static func backEdgeDestinations(data: Data, at: Int, nodeCount: Int) throws -> [UInt8]? {
        guard data.count >= at + 4 else { throw SnapError.ioFailure("file is missing the back-edge count") }
        let count = Int(readU32(data, at))
        guard data.count >= at + 4 + count * 8 else {
            throw SnapError.ioFailure("file truncated mid-back-edge-section")
        }
        if count == 0 { return nil }
        var flags = [UInt8](repeating: 0, count: nodeCount)
        for i in 0..<count {
            let dst = Int(readU32(data, at + 8 + i * 8))
            if dst < nodeCount { flags[dst] = 1 }
        }
        return flags
    }

    /// Walk the back-edge and WGTS sections that follow the body and read the
    /// v8 TERN section: its flags (unknown bits refused by name), its table
    /// count and its bytes (validated as a library).
    static func readTernLibrary(data: Data, ver: UInt32, afterBody: Int, nodeCount: Int) throws -> [UInt8] {
        var off = afterBody
        guard data.count >= off + 4 else { throw SnapError.ioFailure("v8 file is missing the back-edge count") }
        off += 4 + Int(readU32(data, off)) * 8
        guard data.count >= off + 5 else { throw SnapError.ioFailure("v8 file is missing the WGTS lane section") }
        guard [UInt8](data[off..<off + 4]) == laneSectionMagic else {
            throw SnapError.ioFailure("v8 lane-section magic mismatch")
        }
        let laneFlags = data[off + 4]
        if laneFlags & ~UInt8(0x07) != 0 { throw SnapError.unknownLaneFlag(laneFlags & ~UInt8(0x07)) }
        off += 5
        if laneFlags & 0x01 != 0 { off += nodeCount * 6 * 4 }
        if laneFlags & 0x02 != 0 { off += nodeCount * 2 }
        if laneFlags & 0x04 != 0 { off += nodeCount * 4 }
        guard data.count >= off + 9 else { throw SnapError.ioFailure("v8 file is missing the TERN section") }
        let m = [UInt8](data[off..<off + 4])
        guard m == ternSectionMagic else {
            throw SnapError.ioFailure("v8 TERN-section magic mismatch: got 0x\(m.map { String(format: "%02x", $0) }.joined()), expected 'TERN' (0x5445524e)")
        }
        let tflags = data[off + 4]
        if tflags & ~UInt8(0x01) != 0 { throw SnapError.unknownTernFlag(tflags & ~UInt8(0x01)) }
        let count = Int(readU32(data, off + 5))
        if (tflags & 0x01 != 0) != (count > 0) {
            throw SnapError.ioFailure("v8 TERN section: library flag \(tflags & 1) disagrees with table count \(count)")
        }
        guard count <= TernaryReference.maxTables else {
            throw SnapError.ternary("TERN section holds \(count) tables, more than \(TernaryReference.maxTables)")
        }
        let len = count * TernaryReference.tableSize
        guard data.count >= off + 9 + len else { throw SnapError.ioFailure("v8 file truncated mid-TERN-section") }
        let lib = [UInt8](data[(off + 9)..<(off + 9 + len)])
        if let why = TernaryReference.libraryRefusal(lib) { throw SnapError.ternary(why) }
        return lib
    }

    /// The four v8 body lanes against every rule (with the truth lane, the
    /// register flags and the library).
    static func ternaryBodyViolation(body: Data, nodeCount n: Int, registers: [UInt8]?,
                                     library: [UInt8]) -> String? {
        let truthOff = 8 * n
        let modeOff = 42 * n
        return body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            let b = raw.baseAddress!
            // Copies keep every lane aligned for its type.
            let mode = Array(UnsafeBufferPointer(start: b.advanced(by: modeOff).assumingMemoryBound(to: UInt8.self), count: n))
            var tid = [UInt16](repeating: 0, count: n)
            var lo = [Float](repeating: 0, count: n), hi = lo
            tid.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: b.advanced(by: modeOff + n), count: 2 * n)) }
            lo.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: b.advanced(by: modeOff + 3 * n), count: 4 * n)) }
            hi.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: b.advanced(by: modeOff + 7 * n), count: 4 * n)) }
            let truth = b.advanced(by: truthOff).assumingMemoryBound(to: UInt8.self)
            return library.withUnsafeBufferPointer { lib in
                mode.withUnsafeBufferPointer { m in tid.withUnsafeBufferPointer { t in
                lo.withUnsafeBufferPointer { l in hi.withUnsafeBufferPointer { h in
                    if let r = registers {
                        return r.withUnsafeBufferPointer { rp in
                            TernaryReference.stateViolation(n: n, mode: m.baseAddress!, ttableId: t.baseAddress!,
                                thrLo: l.baseAddress!, thrHi: h.baseAddress!, truth: truth,
                                isRegister: rp.baseAddress!, tables: lib)
                        }
                    }
                    return TernaryReference.stateViolation(n: n, mode: m.baseAddress!, ttableId: t.baseAddress!,
                        thrLo: l.baseAddress!, thrHi: h.baseAddress!, truth: truth,
                        isRegister: nil, tables: lib)
                }}}}
            }
        }
    }

    // MARK: - Morton export (raw per-buffer files for Tier-1 interop)

    /// Write every persisted buffer to its own raw file, no header, no
    /// compression, Morton order.
    ///
    /// Eleven files: the six body lanes — `rank.bin` (u64), `truth.bin`,
    /// `nodeType.bin`, `lut_low.bin`, `lut_high.bin`, `neighbors.bin` —
    /// under their original names, contents and layout, plus
    /// `edge_weights.bin` (f32 × n × 6), `activation.bin` (i16 × n),
    /// `node_value.bin` (f32 × n), `is_register.bin` (u8 × n) and
    /// `back_edges.bin` (u32 count + count × (u32 src + u32 dst)).
    ///
    /// The last five are additions. Six files described a graph the
    /// engine does not have, and the call returned `nodeCount * 42` as
    /// though that were the whole object. The returned
    /// byte count is what was written.
    ///
    /// The ternary lanes add five more (sixteen in all): `mode.bin` (u8 × n),
    /// `ttable_id.bin` (u16 × n), `thr_lo.bin` and `thr_hi.bin` (f32 × n), and
    /// `ttables.bin` (729 bytes per table). The importer takes them as
    /// optional, as it takes the weight lanes.
    public static func exportMorton(
        engine: DagDBEngine,
        nodeCount: Int,
        dir: String
    ) throws -> (bytesWritten: Int, elapsedMs: Double) {
        let t0 = Date()

        // Ternary, on write: a state the importer would refuse is never
        // exported.
        if let why = engine.ternaryStateViolation() { throw SnapError.ternary(why) }

        // The sixteen files are written into a stage inside `dir` and renamed
        // into place after every target name passed its check, so a failure
        // leaves `dir` as it was (written one by one, a failed export would
        // leave a mixed set for IMPORT MORTON to read).
        let set = try StagedFileSet.begin(target: dir)
        var names: [String] = []
        do {
            func faultSeam(_ path: String) throws {
                #if DEBUG || DAGDB_FAULT_INJECTION
                if DagDBFaultInjection.writeFails(path) {
                    throw SnapError.ioFailure("open: \(Reply.quoted(path)): \(DagDBFaultInjection.InjectedFault(what: "WRITE_FAIL"))")
                }
                #endif
            }
            // Each file created in the stage this export made, without blocking, no link followed, a regular
            // file, written by POSIX writes (an I/O error is thrown by name). Created O_EXCL (the stage is new,
            // so nothing can be at the name; anything that is, is refused, never truncated).
            func create(_ path: String) throws -> SnapWriter {
                do { return SnapWriter(fd: try DaemonFile.openForWrite(path, create: true, exclusive: true), path: path) }
                catch { throw SnapError.ioFailure("open: \(Reply.errorWords(error))") }
            }
            func writeRaw(_ name: String, _ ptr: UnsafeMutableRawPointer, _ size: Int) throws {
                let path = set.path(name)
                names.append(name)
                try faultSeam(path)
                let h = try create(path)
                defer { h.close() }
                try writeChunked(h, ptr, size)
            }

            // v3 Morton export: rank is now 8 bytes per node (u64).
            try writeRaw("rank.bin",      engine.rankBuf.contents(),       nodeCount * 8)
            try writeRaw("truth.bin",     engine.truthStateBuf.contents(), nodeCount)
            try writeRaw("nodeType.bin",  engine.nodeTypeBuf.contents(),   nodeCount)
            try writeRaw("lut_low.bin",   engine.lut6LowBuf.contents(),    nodeCount * 4)
            try writeRaw("lut_high.bin",  engine.lut6HighBuf.contents(),   nodeCount * 4)
            try writeRaw("neighbors.bin", engine.neighborsBuf.contents(),  nodeCount * 6 * 4)

            // The other four persisted lanes and the back-edge list. Six
            // files described a graph the engine does not have: the weights,
            // activation and node-value lanes and every register were dropped,
            // and the call returned `nodeCount * 42` as though that were the
            // whole object. The six original files keep
            // their names, contents and layout, so a reader of the old set is
            // unaffected; these five are additions beside them.
            try writeRaw("edge_weights.bin", engine.edgeWeightsBuf.contents(), nodeCount * 6 * 4)
            try writeRaw("activation.bin",   engine.activationBuf.contents(),  nodeCount * 2)
            try writeRaw("node_value.bin",   engine.nodeValueBuf.contents(),   nodeCount * 4)
            try writeRaw("is_register.bin",  engine.isRegisterBuf.contents(),  nodeCount)

            // back_edges.bin: u32 count + count × (u32 src + u32 dst).
            var be = Data()
            appendU32(&be, UInt32(engine.backEdgeCount))
            for i in 0..<engine.backEdgeCount {
                appendU32(&be, engine.backEdgeSrcs[i])
                appendU32(&be, engine.backEdgeDsts[i])
            }
            names.append("back_edges.bin")
            try faultSeam(set.path("back_edges.bin"))
            do { let h = try create(set.path("back_edges.bin")); defer { h.close() }; try h.write(be) }

            // The four ternary lanes and the library, beside the
            // eleven files above; the importer treats them as optional, as it
            // does the weight lanes.
            // Unallocated lanes are exported as their zero defaults.
            func writeLane(_ name: String, _ p: UnsafeRawPointer?, _ size: Int) throws {
                if let p = p { try writeRaw(name, UnsafeMutableRawPointer(mutating: p), size); return }
                let path = set.path(name)
                names.append(name)
                try faultSeam(path)
                let h = try create(path)
                defer { h.close() }
                try writeZeros(h, size)
            }
            let lanes = engine.ternaryLaneView
            try writeLane("mode.bin",      lanes.map { UnsafeRawPointer($0.mode) },     nodeCount)
            try writeLane("ttable_id.bin", lanes.map { UnsafeRawPointer($0.ttableId) }, nodeCount * 2)
            try writeLane("thr_lo.bin",    lanes.map { UnsafeRawPointer($0.thrLo) },    nodeCount * 4)
            try writeLane("thr_hi.bin",    lanes.map { UnsafeRawPointer($0.thrHi) },    nodeCount * 4)
            let library = engine.libraryBytes()
            names.append("ttables.bin")
            try faultSeam(set.path("ttables.bin"))
            do { let h = try create(set.path("ttables.bin")); defer { h.close() }; try h.write(Data(library)) }
            try set.commit(names)
        } catch {
            if let left = set.abort() { throw SnapError.ioFailure("\(Reply.errorWords(error)); and the stage could not be removed: \(left)") }
            throw error
        }
        let library = engine.libraryBytes()
        let be = 4 + 8 * engine.backEdgeCount

        let total = nodeCount * 42                      // the six body lanes
            + nodeCount * 6 * 4 + nodeCount * 2 + nodeCount * 4 + nodeCount
            + be
            + nodeCount * 11 + library.count
        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (total, elapsed)
    }

    /// The files IMPORT MORTON reads, in a fixed order; a file's index here
    /// is its id in the WAL's import record. Never
    /// reordered: append only.
    public static let mortonImportFileNames: [String] = [
        "rank.bin", "truth.bin", "nodeType.bin", "lut_low.bin", "lut_high.bin", "neighbors.bin",
        "edge_weights.bin", "activation.bin", "node_value.bin",
        "mode.bin", "ttable_id.bin", "thr_lo.bin", "thr_hi.bin", "ttables.bin", "back_edges.bin",
    ]

    /// One file an import read: its name and its bytes, exactly as read.
    public typealias MortonFile = (name: String, data: Data)

    /// Inverse of exportMorton. Reads the 6 per-buffer files into staging arrays,
    /// validates, and commits to engine only if valid.
    ///
    /// `files`, when given, supplies each file's bytes by
    /// name instead of the directory (nil = absent) — WAL replay passes the
    /// logged bytes, so a replayed import runs this same code on the same
    /// bytes. `beforeCommit` receives every file read, in order, after every
    /// check passed and before the first buffer is written: the daemon logs
    /// them there, and a throw from it leaves the engine untouched.
    public static func importMorton(
        engine: DagDBEngine,
        nodeCount: Int,
        dir: String,
        validate: Bool = true,
        files provider: ((String) throws -> Data?)? = nil,
        slotModel: ((String?) -> Void)? = nil,
        beforeCommit: (([MortonFile]) throws -> Void)? = nil,
        admit: ((Int, String) -> String?)? = nil
    ) throws -> (bytesRead: Int, elapsedMs: Double) {
        do {
            return try importMortonFiles(engine: engine, nodeCount: nodeCount, dir: dir, validate: validate,
                                         files: provider, slotModel: slotModel, beforeCommit: beforeCommit, admit: admit)
        } catch let r as DaemonFile.Refusal {
            throw SnapError.ioFailure("\(Reply.errorWords(r))")
        }
    }

    private static func importMortonFiles(
        engine: DagDBEngine, nodeCount: Int, dir: String, validate: Bool,
        files provider: ((String) throws -> Data?)?, slotModel: ((String?) -> Void)?,
        beforeCommit: (([MortonFile]) throws -> Void)?, admit: ((Int, String) -> String?)?
    ) throws -> (bytesRead: Int, elapsedMs: Double) {
        let t0 = Date()

        // Every file is opened first — without blocking, a regular file, inside the root (by its
        // open descriptor: a link to a file outside the root is refused, never imported) — and its true size
        // known; the sizes the node count fixes are checked, the sum is admitted, and each file is then read
        // once, straight into its own buffer: the one copy the checks, the WAL record and the commit use (no
        // mapping, so no race and no SIGBUS on a cut file). A file cut or changed while read is refused.
        var readers: [String: DaemonFile.Reader] = [:]
        if provider == nil {
            var total = 0
            for name in mortonImportFileNames {
                do { let r = try DaemonFile.Reader("\(dir)/\(name)"); readers[name] = r; total += r.size }
                catch DaemonFile.Refusal.missing { continue }
            }
            if let a = admit, let e = a(total, "the import's \(readers.count) files, \(total) B, each read once into its own buffer") {
                throw SnapError.admission(e)
            }
        }
        var readFiles: [MortonFile] = []
        func fetch(_ name: String, expectedSize: Int? = nil) throws -> Data? {
            let d: Data
            if let provider = provider {
                guard let p = try provider(name) else { return nil }
                d = p
            } else {
                guard let r = readers[name] else { return nil }
                if let want = expectedSize, r.size != want {
                    throw SnapError.ioFailure("\(name): expected \(want) bytes, got \(r.size)")
                }
                if name == "ttables.bin", r.size > TernaryReference.maxTables * TernaryReference.tableSize {
                    throw SnapError.ternary("ttables.bin: \(r.size) bytes, more than \(TernaryReference.maxTables) tables of \(TernaryReference.tableSize)")
                }
                d = try r.read(r.size)
                try r.finish(whole: true)
                readers[name] = nil
            }
            readFiles.append((name, d))
            return d
        }

        func readStaged(_ name: String, _ expectedSize: Int) throws -> Data {
            let path = "\(dir)/\(name)"
            guard let d = try fetch(name, expectedSize: expectedSize) else {
                throw SnapError.ioFailure("missing: \(Reply.quoted(path))")
            }
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

        // The persistence rule (the slot model); its one pass also
        // finds the first S1–S3 slot, which `slotModel` is told before the
        // commit (the daemon's WAL v4 trigger).
        var firstShape: String? = nil
        if validate {
            let scan = rankData.withUnsafeBytes { (rawRank: UnsafeRawBufferPointer) in
                nbData.withUnsafeBytes { (rawNb: UnsafeRawBufferPointer) in
                    let rank = rawRank.baseAddress!.assumingMemoryBound(to: UInt64.self)
                    let nb   = rawNb.baseAddress!.assumingMemoryBound(to: Int32.self)
                    return persistenceSlotScan(nodeCount: nodeCount, neighbors: nb) { rank[$0] }
                }
            }
            if let v = scan.violation { throw SnapError.validationFailed(v) }
            firstShape = scan.firstShape
        }

        // The four extra lanes and the back-edge list, when the
        // directory carries them. A directory holding only the six original
        // files still imports; the lanes it does not carry come back at
        // their defaults below, exactly as `load` resets them, rather than
        // keeping the destination's previous graph.
        func optional(_ name: String, _ expectedSize: Int) throws -> Data? {
            guard let d = try fetch(name, expectedSize: expectedSize) else { return nil }
            guard d.count == expectedSize else {
                throw SnapError.ioFailure("\(name): expected \(expectedSize) bytes, got \(d.count)")
            }
            return d
        }
        let wData = try optional("edge_weights.bin", nodeCount * 6 * 4)
        // A non-finite weight is refused by name, before
        // anything is committed (SET WEIGHT's rule).
        if let d = wData, let why = d.withUnsafeBytes({ raw in
            raw.baseAddress.flatMap { weightRefusal($0, count: nodeCount * 6) } }) {
            throw SnapError.validationFailed("edge_weights.bin: \(why)")
        }
        let aData = try optional("activation.bin",   nodeCount * 2)
        let vData = try optional("node_value.bin",   nodeCount * 4)
        // A non-finite node value likewise (SET VALUE's rule).
        if let d = vData, let why = d.withUnsafeBytes({ raw in
            raw.baseAddress.flatMap { nodeValueRefusal($0, count: nodeCount) } }) {
            throw SnapError.validationFailed("node_value.bin: \(why)")
        }
        // The ternary lanes: optional, like the weight lanes; absent ⇒ the
        // BINARY defaults and an empty library.
        let mData  = try optional("mode.bin",      nodeCount)
        let tidData = try optional("ttable_id.bin", nodeCount * 2)
        let loData = try optional("thr_lo.bin",    nodeCount * 4)
        let hiData = try optional("thr_hi.bin",    nodeCount * 4)
        var library: [UInt8] = []
        if let lib = try fetch("ttables.bin") {
            library = [UInt8](lib)
            if let why = TernaryReference.libraryRefusal(library) { throw SnapError.ternary("ttables.bin: \(why)") }
        }

        var beSrcs: [UInt32] = []
        var beDsts: [UInt32] = []
        var beBytes = 0
        if let raw = try fetch("back_edges.bin") {
            // No copy (Data(raw) would copy the whole list); indices from its start.
            let d = raw.startIndex == 0 ? raw : Data(raw)
            guard d.count >= 4 else {
                throw SnapError.ioFailure("back_edges.bin: missing the entry count")
            }
            let count = Int(readU32(d, 0))
            guard d.count == 4 + count * 8 else {
                throw SnapError.ioFailure(
                    "back_edges.bin: \(count) entries need \(4 + count * 8) bytes, file has \(d.count)")
            }
            for i in 0..<count {
                let s = readU32(d, 4 + i * 8)
                let t = readU32(d, 8 + i * 8)
                guard Int(s) < nodeCount && Int(t) < nodeCount else {
                    throw SnapError.ioFailure(
                        "back_edges.bin entry \(i) out of range: src=\(s) dst=\(t) nodeCount=\(nodeCount)")
                }
                beSrcs.append(s); beDsts.append(t)
            }
            beBytes = d.count
        }

        // CONNECT BACK's rules on every entry, against the STAGED
        // mode and neighbour lanes (the directory's, never the live engine's,
        // which still holds the previous graph), before anything is committed
        // — and before the ternary lane rule, so a ternary destination is
        // named by its entry, in CONNECT BACK's words. `validate: false` skips
        // them with the DAG rules; the ternary rules below always run.
        if validate, !beSrcs.isEmpty {
            let refusal: DagDBEngine.BackEdgeEntryRefusal? = nbData.withUnsafeBytes { nb in
                func check(_ m: UnsafeRawBufferPointer?) -> DagDBEngine.BackEdgeEntryRefusal? {
                    DagDBEngine.backEdgeListRefusal(list: "back_edges.bin", srcs: beSrcs, dsts: beDsts,
                                                    nodeCount: nodeCount, modeBytes: m, neighborBytes: nb)
                }
                guard let m = mData else { return check(nil) }
                return m.withUnsafeBytes { check($0) }
            }
            if let r = refusal { throw r }
        }

        // Ternary rules on the staged lanes, before anything is committed, read in place from
        // the one buffer each file was read into (a lane the directory lacks reads as its zero default).
        do {
            var reg = [UInt8](repeating: 0, count: nodeCount)
            for d in beDsts { reg[Int(d)] = 1 }
            let zeros = Data(count: max(nodeCount * 4, 1))
            func ptr<T, R>(_ d: Data?, _ t: T.Type, _ body: (UnsafePointer<T>) -> R) -> R {
                (d ?? zeros).withUnsafeBytes { body($0.baseAddress!.assumingMemoryBound(to: T.self)) }
            }
            let why: String? = library.withUnsafeBufferPointer { lib in
                reg.withUnsafeBufferPointer { rp in
                    ptr(mData, UInt8.self) { m in ptr(tidData, UInt16.self) { t in ptr(loData, Float.self) { l in
                        ptr(hiData, Float.self) { h in ptr(truthData, UInt8.self) { tr in
                            TernaryReference.stateViolation(n: nodeCount, mode: m, ttableId: t, thrLo: l, thrHi: h,
                                                            truth: tr, isRegister: rp.baseAddress!, tables: lib)
                        } } } } }
                }
            }
            if let why = why { throw SnapError.ternary(why) }
        }

        // Every check passed; the caller logs the bytes (WAL
        // before mutation) or refuses, before the first buffer is written.
        if validate { slotModel?(firstShape) }
        // The library's room before the WAL record
        // and the commit (its growth was the one step that could fail after).
        try engine.reserveTableCapacity(library.count / TernaryReference.tableSize)
        try beforeCommit?(readFiles)

        // Commit — all validations passed
        rankData.withUnsafeBytes  { memcpy(engine.rankBuf.contents(),       $0.baseAddress!, nodeCount * 8) }
        truthData.withUnsafeBytes { memcpy(engine.truthStateBuf.contents(), $0.baseAddress!, nodeCount) }
        typeData.withUnsafeBytes  { memcpy(engine.nodeTypeBuf.contents(),   $0.baseAddress!, nodeCount) }
        lowData.withUnsafeBytes   { memcpy(engine.lut6LowBuf.contents(),    $0.baseAddress!, nodeCount * 4) }
        highData.withUnsafeBytes  { memcpy(engine.lut6HighBuf.contents(),   $0.baseAddress!, nodeCount * 4) }
        nbData.withUnsafeBytes    { memcpy(engine.neighborsBuf.contents(),  $0.baseAddress!, nodeCount * 6 * 4) }

        // Reset exactly what `load` resets — back edges, register flags and
        // the three lanes — before installing what the directory carried.
        // Without this the previous graph's registers stayed flagged and
        // every node at those indices was skipped by every rank tick.
        engine.backEdgeSrcs.removeAll(keepingCapacity: false)
        engine.backEdgeDsts.removeAll(keepingCapacity: false)
        let regPtr = engine.isRegisterBuf.contents()
            .bindMemory(to: UInt8.self, capacity: nodeCount)
        for i in 0..<nodeCount { regPtr[i] = 0 }
        let wPtr = engine.edgeWeightsBuf.contents()
            .bindMemory(to: Float.self, capacity: nodeCount * 6)
        for i in 0..<(nodeCount * 6) { wPtr[i] = 1.0 }
        let aPtr = engine.activationBuf.contents()
            .bindMemory(to: Int16.self, capacity: nodeCount)
        for i in 0..<nodeCount { aPtr[i] = 0 }
        let vPtr = engine.nodeValueBuf.contents()
            .bindMemory(to: Float.self, capacity: nodeCount)
        for i in 0..<nodeCount { vPtr[i] = 0.0 }

        wData?.withUnsafeBytes { memcpy(engine.edgeWeightsBuf.contents(), $0.baseAddress!, nodeCount * 6 * 4) }
        aData?.withUnsafeBytes { memcpy(engine.activationBuf.contents(),  $0.baseAddress!, nodeCount * 2) }
        vData?.withUnsafeBytes { memcpy(engine.nodeValueBuf.contents(),   $0.baseAddress!, nodeCount * 4) }
        for i in 0..<beSrcs.count {
            try engine.addBackEdgeUnchecked(src: beSrcs[i], dst: beDsts[i])
        }
        // Absent or all-default lanes leave them unallocated.
        func installLanes(_ m: UnsafeRawPointer?, _ t: UnsafeRawPointer?, _ lo: UnsafeRawPointer?, _ hi: UnsafeRawPointer?) {
            engine.installTernaryLanes(mode: m, ttableId: t, thrLo: lo, thrHi: hi)
        }
        func bytes<R>(_ d: Data?, _ body: (UnsafeRawPointer?) -> R) -> R {
            guard let d = d else { return body(nil) }
            return d.withUnsafeBytes { body($0.baseAddress) }
        }
        bytes(mData) { m in bytes(tidData) { t in bytes(loData) { lo in bytes(hiData) { hi in installLanes(m, t, lo, hi) } } } }
        try engine.replaceLibrary(library)
        engine.markRankTopologyDirty()

        let total = nodeCount * 42
            + (wData?.count ?? 0) + (aData?.count ?? 0) + (vData?.count ?? 0)
            + beBytes
            + (mData?.count ?? 0) + (tidData?.count ?? 0) + (loData?.count ?? 0) + (hiData?.count ?? 0)
            + library.count
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
        body: Data, nodeCount: Int, rankBytesPerNode: Int, rule: SlotRule
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

            switch rule {
            case .persistence: return persistenceSlotScan(nodeCount: nodeCount, neighbors: nb).violation
            case .rankModeDAG: return dagEdgeViolation(nodeCount: nodeCount, neighbors: nb, rankAt: rankAt)
            }
        }
    }

    // MARK: - The slot rules (the slot model)

    /// The persistence rule on a slot lane, the ONE function every
    /// loader and writer that checks slots asks — LOAD (and through it
    /// DAGDB_STARTUP_LOAD), IMPORT MORTON (and its WAL replay), LOAD JSON,
    /// LOAD CSV, BACKUP RESTORE's tip, SAVE (and the autosave and the loaders'
    /// rebase). A source at or past `nodeCount` is refused, the first one
    /// named (`node <d> slot <k>: src <s> out of range`); any negative slot is
    /// empty. The store shapes are accepted: S1 a duplicate source in one
    /// node's slots, S2 a slot self-loop, S3 a source whose rank is not
    /// strictly above the destination's. TICK_SYNC is defined on them;
    /// rank-mode TICK refuses S2 and S3 itself (`rankOrderViolation`); S4, a
    /// slot into a register, is the back-edge rule's
    /// (`DagDBEngine.backEdgeRule`). With `rankAt`, the first S1–S3 slot is
    /// named in `firstShape` (IMPORT's WAL v4 trigger); without it, shapes
    /// are not looked for.
    public static func persistenceSlotScan(nodeCount: Int, neighbors nb: UnsafePointer<Int32>,
                                           rankAt: ((Int) -> UInt64)? = nil) -> (violation: String?, firstShape: String?) {
        let limit = Int32(clamping: nodeCount)
        var shape: String? = nil
        for dst in 0..<nodeCount {
            for d in 0..<6 {
                let src = nb[dst * 6 + d]
                if src < 0 { continue }
                if src >= limit { return ("node \(dst) slot \(d): src \(src) out of range", shape) }
                if shape == nil, let rank = rankAt {
                    if Int(src) == dst {
                        shape = "S2: node \(dst) slot \(d): self-loop"
                    } else if rank(Int(src)) <= rank(dst) {
                        shape = "S3: node \(dst) slot \(d): src rank \(rank(Int(src))) is not > dst rank \(rank(dst))"
                    } else if (0..<d).contains(where: { nb[dst * 6 + $0] == src }) {
                        shape = "S1: node \(dst): duplicate source \(src)"
                    }
                }
            }
        }
        return (nil, shape)
    }

    /// The live graph against the persistence rule (SAVE's slot check):
    /// what LOAD would refuse in a file holding this graph's
    /// slots, in LOAD's words, or nil.
    public static func persistenceViolation(engine: DagDBEngine, nodeCount: Int) -> String? {
        let nb = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: max(nodeCount * 6, 1))
        return persistenceSlotScan(nodeCount: nodeCount, neighbors: nb).violation
    }

    /// The rank-mode rule on a neighbour table and a rank lane, first
    /// violation named: a source out of range, a self-loop (S2), a source
    /// whose rank is not strictly above the destination's (S3) — in LOAD's
    /// older words. This was once LOAD's rule, with a fourth clause, a
    /// duplicate source (S1, `node <d>: duplicate edge from <s>`), and LOAD,
    /// IMPORT MORTON and SAVE asked it. Only TILED OPEN's tile bodies ask it
    /// now (`SlotRule.rankModeDAG`: a tiled graph stays a rank-mode object),
    /// without the duplicate clause: tiled accepts exactly what rank-mode TICK runs
    /// (`rankOrderViolation`'s S2 and S3, plus the range a file must keep;
    /// the kernel evaluates a duplicate input twice). Every other loader
    /// asks `persistenceSlotScan`.
    @inline(__always)
    static func dagEdgeViolation(nodeCount: Int, neighbors nb: UnsafePointer<Int32>,
                                 rankAt: (Int) -> UInt64) -> String? {
        for dst in 0..<nodeCount {
            for d in 0..<6 {
                let src = nb[dst * 6 + d]
                if src < 0 { continue }
                if src >= Int32(clamping: nodeCount) {
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
            }
        }
        return nil
    }

    /// The acyclicity half of LOAD's rules, on the live graph (rank-mode
    /// TICK): a self-loop, or a source whose rank is not
    /// strictly above its destination's — the edges rank mode cannot order.
    /// LOAD's words. A source index out of range and a duplicate source are
    /// not this check's business: the kernel bounds-checks every slot and
    /// evaluates a duplicate input twice, and an existing test
    /// (CoreDurabilityDaemonTests, a corrupt neighbour index) requires TICK
    /// to run and report on such a graph.
    public static func rankOrderViolation(engine: DagDBEngine, nodeCount: Int) -> String? {
        let rank = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: max(nodeCount, 1))
        let nb = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: max(nodeCount * 6, 1))
        for dst in 0..<nodeCount {
            for d in 0..<6 {
                let src = nb[dst * 6 + d]
                if src < 0 || src >= Int32(clamping: nodeCount) { continue }
                if Int(src) == dst { return "node \(dst) slot \(d): self-loop" }
                if rank[Int(src)] <= rank[dst] {
                    return "node \(dst) slot \(d): src rank \(rank[Int(src)]) must be > dst rank \(rank[dst])"
                }
            }
        }
        return nil
    }

    /// The live graph against the rank-mode rule (`dagEdgeViolation`): what
    /// TILED OPEN would refuse in a tile body holding this graph, or nil.
    /// SAVE once asked it; it asks `persistenceViolation` now.
    public static func dagViolation(engine: DagDBEngine, nodeCount: Int) -> String? {
        let rank = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: max(nodeCount, 1))
        let nb = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: max(nodeCount * 6, 1))
        return dagEdgeViolation(nodeCount: nodeCount, neighbors: nb) { rank[$0] }
    }

    // MARK: - Compression

    /// Compress a byte array with zlib. Returns a fresh Data, empty only if
    /// the input was empty.
    ///
    /// `compression_encode_buffer` returns 0 when the destination is too
    /// small, and zlib EXPANDS incompressible input — so sizing the
    /// destination at `input.count` (as this once did) turned a random
    /// body into an empty one with no error anywhere.
    /// The destination now starts at zlib's own worst case (the deflate
    /// bound: input + input/1000 + 13, plus the zlib wrapper and a margin)
    /// and doubles if the encoder still says it does not fit.
    static func zlibCompress(_ input: Data) -> Data {
        if input.isEmpty { return Data() }
        var bufSize = max(input.count + input.count / 1000 + 128, 128)
        // Three attempts is already far past the theoretical bound; the loop
        // exists so a future codec change cannot reintroduce a silent zero.
        for _ in 0..<3 {
            var output = [UInt8](repeating: 0, count: bufSize)
            let sz = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                return compression_encode_buffer(
                    &output, bufSize,
                    src.baseAddress!.assumingMemoryBound(to: UInt8.self), input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
            if sz > 0 { return Data(output[0..<sz]) }
            bufSize *= 2
        }
        return Data()
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

    // MARK: - Manifest

    /// Side-by-side SHA-256 manifest path for a snapshot: `<path>.sha256`.
    public static func manifestPathFor(_ path: String) -> String { path + ".sha256" }

    /// Lowercase hex SHA-256 of the given bytes.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The SHA-256 of a file's bytes, or nil when it cannot be read; streamed
    /// through the read helper (non-blocking, regular, contained; no mapping).
    public static func fileDigest(path: String) -> [UInt8]? {
        try? DaemonFile.digest(path)
    }

    // MARK: - Helpers

    /// Write `count` bytes at `ptr` through `handle` in slices of at most
    /// 1 GiB, so no single write(2) is asked to carry more than INT_MAX
    /// bytes (a 100M-node neighbour lane is 2.4 GB).
    static func writeChunked(_ handle: SnapWriter, _ ptr: UnsafeRawPointer, _ count: Int) throws {
        try DaemonFile.writeAll(handle.fd, ptr, count, path: handle.path)
    }

    /// `count` zero bytes, in chunks (for lanes never allocated).
    static func writeZeros(_ handle: SnapWriter, _ count: Int) throws {
        let chunk = Data(count: min(count, 1 << 20))
        var off = 0
        while off < count {
            let n = min(chunk.count, count - off)
            try handle.write(n == chunk.count ? chunk : chunk.prefix(n))
            off += n
        }
    }

    /// A file the snapshot writers fill through POSIX writes on a descriptor `DaemonFile`
    /// opened (an I/O error is thrown by name; FileHandle.write raises an Objective-C exception).
    final class SnapWriter {
        let fd: Int32
        let path: String
        private var closed = false
        init(fd: Int32, path: String) { self.fd = fd; self.path = path }
        func write(_ d: Data) throws { try DaemonFile.writeAll(fd, d, path: path) }
        func close() { if !closed { closed = true; Darwin.close(fd) } }
        deinit { close() }
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

    private static func readU64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(readU32(data, offset)) | UInt64(readU32(data, offset + 4)) << 32
    }
}
