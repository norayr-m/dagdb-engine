/// DagDBBackup — incremental backup chain for DagDB.
///
/// A chain lives in a single directory:
///     <dir>/base.dags        full snapshot at chain start
///     <dir>/base.dags.sha256 its manifest
///     <dir>/00001.diff       XOR diff from tip-after-base to engine state
///     <dir>/00001.diff.sha256
///     <dir>/00002.diff       XOR diff from tip-after-00001 to engine state
///     ...
///
/// Each .diff is the XOR of the engine's per-node buffers against the previous
/// tip, zlib-compressed per buffer. Since most DagDB edits touch a handful of
/// nodes, diffs are tiny — usually far under 1% of the base.
///
/// WHAT A DIFF COVERS (format 2, 2026-09-12) — the same state the snapshot
/// carries, minus the twin registries:
///     rank (8·N)        truth (N)          nodeType (N)
///     lut6Low (4·N)     lut6High (4·N)     neighbors (24·N)
///     isRegister (N)    edgeWeights (24·N) activation (2·N)
///     nodeValue (4·N)   back edges (u32 count + 8 B per entry)
/// The ten fixed-width buffers are XOR-diffed byte-wise against the tip. The
/// back-edge section is variable-length, so each diff carries it WHOLE and
/// un-XORed (absolute, not a delta) — it is a handful of bytes on any graph
/// where the diff size matters. On restore the back edges go back through the
/// engine's own add path, so the latch list and the isRegister flags stay
/// consistent with each other, exactly as the snapshot loader does it.
///
/// WHAT A DIFF DOES NOT COVER: twin state (streams, rings, clocks, banks,
/// alarms, folds, views). A restore leaves any open twin objects as they are;
/// `BACKUP INFO` and `BACKUP RESTORE` both say `twin=not_covered`, and the
/// bases written by INIT and COMPACT carry an empty v7 TWIN section. Carrying
/// the twin registries needs the path/sha rules the snapshot has for
/// by-reference entries, which is not a byte-XOR.
///
/// ORDER, IDENTITY, INTEGRITY:
///   · Diffs apply in the order of the sequence number in their own header,
///     never in filename order ("100000.diff" sorts before "99999.diff").
///     A gap or a duplicate in the sequence is refused by name.
///   · APPEND writes the next sequence number and refuses to overwrite an
///     existing file.
///   · Every diff carries a `.sha256` sidecar, verified before anything in it
///     is decoded — exactly as the base's manifest is.
///   · A segment whose length disagrees with the buffer it patches is refused
///     by name. Nothing is clamped to the shorter of the two; that clamp is
///     what let the 4-bytes-per-node rank defect live through a u64 widening.
///   · The back-edge section's byte length must equal `4 + 8 × pairCount`
///     exactly. Its own declared size is not a check — it is what is being
///     checked; a length nobody derives is a length nobody checks.
///
/// FORMAT 1 (retired) carried six buffers and sized the rank segment at 4
/// bytes per node: the complete ranks of nodes 0..<N/2, none of the ranks of
/// nodes N/2..<N, and no registers, back edges, weights, activation or node
/// values at all. Those bytes were never written, so a format-1 chain cannot
/// be migrated — it is refused by name on RESTORE and APPEND, and named as a
/// caveat by INFO.
///
/// Typical workflow:
///     DagDBBackup.initializeChain(engine:, ..., dir:)   // snapshot base
///     // ... edit engine ...
///     DagDBBackup.appendDiff(engine:, ..., dir:)         // append diff
///     // ... more edits ...
///     DagDBBackup.appendDiff(engine:, ..., dir:)
///     DagDBBackup.restore(engine: other, ..., dir:)      // replay chain
///     DagDBBackup.compact(nodeCount:, ..., dir:)         // fold diffs into new base
///
/// All writes use the atomic-save + F_FULLFSYNC discipline from DagDBSnapshot.

import Foundation

public enum DagDBBackup {

    public enum BackupError: Error, CustomStringConvertible {
        case noBase(String)
        case invalidDiff(String)
        case shapeMismatch(String)
        case ioFailure(String)
        /// A chain written by the 4-bytes-per-node rank layout (`diffVersion` 1).
        /// Nothing in such a chain can reconstruct the upper half of the rank
        /// buffer — the bytes were never written — so RESTORE and APPEND refuse
        /// it by name instead of silently keeping half the ranks.
        case legacyFormat
        /// A segment's length disagrees with the buffer it patches.
        case segmentLength(seq: Int, segment: String, actual: Int, expected: Int)
        /// The chain's sequence numbers skip one.
        case sequenceGap(missing: Int)
        /// Two diffs claim the same sequence number.
        case sequenceDuplicate(seq: Int, first: String, second: String)
        /// APPEND's target file is already on disk.
        case diffExists(String)
        /// A diff does not match its sidecar, or has none.
        case checksumMismatch(String)
        case checksumMissing(String)
        /// The back-edge section's byte length disagrees with the pair count
        /// written inside it.
        case backEdgeSection(seq: Int, actual: Int, expected: Int, count: Int)

        public var description: String {
            switch self {
            case .noBase(let s):        return "no base: \(s)"
            case .invalidDiff(let s):   return "invalid diff: \(s)"
            case .shapeMismatch(let s): return "shape: \(s)"
            case .ioFailure(let s):     return "io: \(s)"
            case .legacyFormat:
                return "io: " + DagDBBackup.legacyFormatMessage
            case let .segmentLength(seq, segment, actual, expected):
                return "io: backup diff \(seq) segment \(segment) is \(actual) bytes, expected \(expected)"
            case .sequenceGap(let missing):
                return "io: backup chain is missing diff sequence \(missing); the chain is incomplete"
            case let .sequenceDuplicate(seq, first, second):
                return "io: backup chain has two diffs with sequence \(seq): \(first) and \(second)"
            case .diffExists(let name):
                return "io: backup diff \(name) already exists; refusing to overwrite"
            case .checksumMismatch(let name):
                return "io: backup diff \(name) does not match its sha256 sidecar; the file is corrupt or truncated"
            case .checksumMissing(let name):
                return "io: backup diff \(name) has no sha256 sidecar; re-create the backup"
            case let .backEdgeSection(seq, actual, expected, count):
                return "io: backup diff \(seq) back-edge section is \(actual) bytes, expected \(expected) for \(count) pairs"
            }
        }

        /// Refusals the contract names on the wire: the reply is this sentence,
        /// not a `verb: error` wrapper, because the operator's next move is in
        /// the sentence itself.
        public var isNamedRefusal: Bool {
            switch self {
            case .legacyFormat, .segmentLength, .sequenceGap, .sequenceDuplicate,
                 .diffExists, .checksumMismatch, .checksumMissing, .backEdgeSection:
                return true
            case .noBase, .invalidDiff, .shapeMismatch, .ioFailure:
                return false
            }
        }
    }

    public static let diffMagic: [UInt8] = [0x44, 0x41, 0x47, 0x44]  // "DAGD"
    /// Format 2 (2026-09-12): the rank segment is `nodeCount * 8` bytes — the
    /// width the engine has actually used since the u64 rank widening — and the
    /// diff covers every buffer the snapshot covers. Format 1 carried four rank
    /// bytes per node and six buffers, and is refused.
    public static let diffVersion: UInt32 = 2
    /// The 4-bytes-per-node, six-buffer layout. Readable as a version number
    /// only — no chain written in it can be restored or extended.
    public static let diffVersionLegacy: UInt32 = 1
    public static let diffHeaderSize: Int = 16

    /// The single sentence every format-1 refusal and every INFO caveat uses.
    public static let legacyFormatMessage =
        "backup format 1 carries 4 of 8 rank bytes per node and no registers, " +
        "back edges, weights, activation or node values; " +
        "cannot restore ranks for nodes N/2..<N; re-create the backup"

    /// Segment names, in file order. Used by the length refusals.
    public static let segmentNames = [
        "rank", "truth", "nodeType", "lut6Low", "lut6High", "neighbors",
        "isRegister", "edgeWeights", "activation", "nodeValue", "backEdges",
    ]

    public struct ChainInfo {
        public let baseExists: Bool
        public let diffCount: Int
        /// Diff paths in sequence-number order (the order a restore applies).
        public let diffPaths: [String]
        public let baseSizeBytes: Int
        public let totalDiffBytes: Int
        /// Format version read from the first diff's header. A chain with no
        /// diffs reports the version this build writes.
        public let formatVersion: UInt32
        /// True when the chain's diffs carry the retired 4-byte rank layout.
        public var isLegacyFormat: Bool { formatVersion == DagDBBackup.diffVersionLegacy }
    }

    // MARK: - Chain inspection

    /// One diff file as the chain sees it: the sequence number and format
    /// version out of its own header, not out of its filename.
    struct DiffEntry {
        let path: String
        let name: String
        let seq: Int          // -1 when the header could not be read
        let version: UInt32
    }

    /// Every `.diff` in `dir`, header-scanned, in filename order. Never throws:
    /// `BACKUP INFO` is read-only and has to be able to describe a broken chain.
    static func scanDiffs(dir: String) -> [DiffEntry] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".diff") }
            .sorted()
        return names.map { name in
            let path = dir + "/" + name
            var seq = -1
            var version: UInt32 = 0
            if let handle = FileHandle(forReadingAtPath: path) {
                defer { try? handle.close() }
                if let head = try? handle.read(upToCount: diffHeaderSize),
                   head.count >= diffHeaderSize,
                   [UInt8](head[0..<4]) == diffMagic {
                    version = readU32(head, 4)
                    seq = Int(readU32(head, 12))
                }
            }
            return DiffEntry(path: path, name: name, seq: seq, version: version)
        }
    }

    /// The chain's diffs in the order they must be applied — sequence order,
    /// read from each header. Refuses an unreadable header, a retired format,
    /// a duplicate sequence number and a gap, each by name.
    static func orderedDiffs(dir: String) throws -> [DiffEntry] {
        let scanned = scanDiffs(dir: dir)
        for e in scanned {
            guard e.seq >= 0 else {
                throw BackupError.invalidDiff("\(e.name): header unreadable")
            }
            if e.version == diffVersionLegacy { throw BackupError.legacyFormat }
            guard e.version == diffVersion else {
                throw BackupError.invalidDiff("\(e.name): version \(e.version)")
            }
        }
        let ordered = scanned.sorted { $0.seq < $1.seq }
        for (i, e) in ordered.enumerated() {
            if i > 0, ordered[i - 1].seq == e.seq {
                throw BackupError.sequenceDuplicate(
                    seq: e.seq, first: ordered[i - 1].name, second: e.name)
            }
            if e.seq != i + 1 {
                throw BackupError.sequenceGap(missing: i + 1)
            }
        }
        return ordered
    }

    public static func info(dir: String) throws -> ChainInfo {
        let fm = FileManager.default
        let base = dir + "/base.dags"
        let baseExists = fm.fileExists(atPath: base)
        let baseSize = baseExists
            ? ((try? fm.attributesOfItem(atPath: base)[.size] as? Int) ?? 0)
            : 0

        // Sequence order where the headers allow it, filename order otherwise —
        // INFO describes broken chains, it does not refuse them.
        let scanned = scanDiffs(dir: dir)
        let ordered = scanned.allSatisfy { $0.seq >= 0 }
            ? scanned.sorted { $0.seq < $1.seq }
            : scanned

        var totalDiffBytes = 0
        for e in ordered {
            totalDiffBytes += (try? fm.attributesOfItem(atPath: e.path)[.size] as? Int) ?? 0
        }

        // Format version lives in the first diff's header; a chain with no
        // diffs has nothing to read, so it reports what this build writes.
        let formatVersion = ordered.first.map { $0.version } ?? diffVersion

        return ChainInfo(
            baseExists: baseExists, diffCount: ordered.count,
            diffPaths: ordered.map { $0.path }, baseSizeBytes: baseSize,
            totalDiffBytes: totalDiffBytes,
            formatVersion: formatVersion
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

        // Wipe any existing chain in this dir — diffs and their sidecars.
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            if name.hasSuffix(".diff") || name.hasSuffix(".diff.sha256") || name == "base.dags" {
                try? fm.removeItem(atPath: dir + "/" + name)
            }
        }

        // twin: nil — twin state is not part of a backup, and the base says so
        // by carrying an empty v7 TWIN section.
        let saved = try DagDBSnapshot.save(
            engine: engine, nodeCount: nodeCount,
            gridW: gridW, gridH: gridH,
            tickCount: tickCount,
            path: dir + "/base.dags",
            compressed: true,
            twin: nil
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
        guard FileManager.default.fileExists(atPath: dir + "/base.dags") else {
            throw BackupError.noBase(dir + "/base.dags")
        }

        // The sequence comes from the chain's headers, and the next number must
        // be free on disk — a renamed diff sitting on the next slot must never
        // be overwritten.
        let existing = try orderedDiffs(dir: dir)
        let seq = existing.count + 1
        let diffName = String(format: "%05d.diff", seq)
        let diffPath = dir + "/" + diffName
        guard !FileManager.default.fileExists(atPath: diffPath) else {
            throw BackupError.diffExists(diffName)
        }

        // Reconstruct the chain's current tip into CPU arrays.
        let replayed = try replayChain(
            dir: dir, nodeCount: nodeCount, gridW: gridW, gridH: gridH)
        let tip = replayed.tip

        // Current engine state — raw bytes copied off the GPU buffers.
        let cur = readEngineBuffers(engine: engine, nodeCount: nodeCount)

        // XOR diffs per fixed-width buffer. Lengths must agree exactly; a
        // disagreement is a refusal, never a clamp.
        let tipFixed = tip.fixedBuffers
        let curFixed = cur.fixedBuffers
        var fixedDiffs: [[UInt8]] = []
        fixedDiffs.reserveCapacity(tipFixed.count)
        for i in 0..<tipFixed.count {
            fixedDiffs.append(
                try xor(tipFixed[i], curFixed[i], seq: seq, segment: segmentNames[i]))
        }

        // Pack diff file: header + 10 zlib-compressed XOR segments (each: u32
        // compressed size + body) + the absolute back-edge section (u32 raw
        // size + u32 compressed size + body).
        var out = Data()
        out.append(contentsOf: diffMagic)
        appendU32(&out, diffVersion)
        appendU32(&out, UInt32(nodeCount))
        appendU32(&out, UInt32(seq))

        for segment in fixedDiffs {
            let compressed = DagDBSnapshot.zlibCompress(Data(segment))
            appendU32(&out, UInt32(compressed.count))
            out.append(compressed)
        }

        let beCompressed = DagDBSnapshot.zlibCompress(Data(cur.backEdges))
        appendU32(&out, UInt32(cur.backEdges.count))
        appendU32(&out, UInt32(beCompressed.count))
        out.append(beCompressed)

        try atomicWrite(data: out, path: diffPath)
        try writeManifest(for: diffPath)

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
    ) throws -> (diffsReplayed: Int, rankBytes: Int, elapsedMs: Double) {
        let t0 = Date()
        let replayed = try replayChain(
            dir: dir, nodeCount: nodeCount, gridW: gridW, gridH: gridH)

        try applyTip(replayed.tip, to: engine, nodeCount: nodeCount)

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (replayed.diffsApplied, nodeCount * 8, elapsed)
    }

    // MARK: - Compact

    /// Collapse the diff chain into a new base.dags. The new base is written
    /// from the CHAIN's own replayed tip — every lane plus the back edges, at
    /// the chain's own tick count — never from a live engine, so a compaction
    /// cannot inherit anything the chain does not hold.
    public static func compact(
        nodeCount: Int,
        gridW: Int,
        gridH: Int,
        dir: String
    ) throws -> (priorDiffCount: Int, newBaseBytes: Int, elapsedMs: Double) {
        let t0 = Date()
        let replayed = try replayChain(
            dir: dir, nodeCount: nodeCount, gridW: gridW, gridH: gridH)

        // The scratch engine already holds the base; put the tip into it and
        // save that. Nothing the caller owns is read or written.
        try applyTip(replayed.tip, to: replayed.scratch, nodeCount: nodeCount)

        let saved = try DagDBSnapshot.save(
            engine: replayed.scratch, nodeCount: nodeCount,
            gridW: gridW, gridH: gridH,
            tickCount: replayed.tickCount,
            path: dir + "/base.dags",
            compressed: true,
            twin: nil
        )

        // Remove all .diff files and their sidecars (the new base already
        // landed through the atomic rename).
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            if name.hasSuffix(".diff") || name.hasSuffix(".diff.sha256") {
                try? fm.removeItem(atPath: dir + "/" + name)
            }
        }

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (replayed.diffsApplied, saved.bytesWritten, elapsed)
    }

    // MARK: - Internals

    private struct TipArrays {
        var rank:       [UInt8]
        var truth:      [UInt8]
        var type:       [UInt8]
        var low:        [UInt8]  // bytes of [UInt32] — XOR works byte-wise
        var high:       [UInt8]
        var neighbors:  [UInt8]  // bytes of [Int32]
        var isRegister: [UInt8]
        var weights:    [UInt8]  // bytes of [Float]
        var activation: [UInt8]  // bytes of [Int16]
        var values:     [UInt8]  // bytes of [Float]
        /// u32 count + count × (u32 src, u32 dst). Variable length, so it is
        /// carried absolute per diff rather than XOR-diffed.
        var backEdges:  [UInt8]

        /// The ten XOR-diffed buffers, in file order.
        var fixedBuffers: [[UInt8]] {
            [rank, truth, type, low, high, neighbors,
             isRegister, weights, activation, values]
        }
    }

    /// The fixed-width, XOR-diffed segment sizes, in file order.
    private static func fixedSegmentSizes(nodeCount: Int) -> [Int] {
        return [
            nodeCount * 8,     // rank (u64 — engine width since 2026-04-21)
            nodeCount,         // truth
            nodeCount,         // nodeType
            nodeCount * 4,     // lut6Low
            nodeCount * 4,     // lut6High
            nodeCount * 6 * 4, // neighbors
            nodeCount,         // isRegister
            nodeCount * 6 * 4, // edgeWeights (Float)
            nodeCount * 2,     // activation (Int16)
            nodeCount * 4,     // nodeValue (Float)
        ]
    }

    /// Replay base + all diffs into in-memory byte arrays. Does NOT touch any
    /// engine the caller owns — the scratch engine it returns exists only to
    /// hold the base it loaded.
    private static func replayChain(
        dir: String, nodeCount: Int, gridW: Int, gridH: Int
    ) throws -> (tip: TipArrays, scratch: DagDBEngine, tickCount: UInt32, diffsApplied: Int) {
        let base = dir + "/base.dags"
        guard FileManager.default.fileExists(atPath: base) else {
            throw BackupError.noBase(base)
        }

        // Read base via DagDBSnapshot — but we want bytes, not a committed
        // engine. Cheapest: load into a throwaway engine. Shared-memory UMA,
        // no GPU fanfare.
        let grid = try HexGrid(width: gridW, height: gridH)
        let state = DagDBState(width: gridW, height: gridH)
        let scratch = try DagDBEngine(grid: grid, state: state, maxRank: 32)
        let loaded = try DagDBSnapshot.load(
            engine: scratch, nodeCount: nodeCount,
            gridW: gridW, gridH: gridH, path: base, validate: false
        )

        var tip = readEngineBuffers(engine: scratch, nodeCount: nodeCount)

        let ordered = try orderedDiffs(dir: dir)
        for entry in ordered {
            try applyDiff(to: &tip, entry: entry, nodeCount: nodeCount)
        }
        return (tip, scratch, loaded.fileTicks, ordered.count)
    }

    /// Commit a replayed tip into an engine's buffers.
    private static func applyTip(
        _ tip: TipArrays, to engine: DagDBEngine, nodeCount: Int
    ) throws {
        tip.rank.withUnsafeBytes  { memcpy(engine.rankBuf.contents(),       $0.baseAddress!, nodeCount * 8) }
        tip.truth.withUnsafeBytes { memcpy(engine.truthStateBuf.contents(), $0.baseAddress!, nodeCount) }
        tip.type.withUnsafeBytes  { memcpy(engine.nodeTypeBuf.contents(),   $0.baseAddress!, nodeCount) }
        tip.low.withUnsafeBytes   { memcpy(engine.lut6LowBuf.contents(),    $0.baseAddress!, nodeCount * 4) }
        tip.high.withUnsafeBytes  { memcpy(engine.lut6HighBuf.contents(),   $0.baseAddress!, nodeCount * 4) }
        tip.neighbors.withUnsafeBytes  { memcpy(engine.neighborsBuf.contents(),   $0.baseAddress!, nodeCount * 6 * 4) }
        tip.isRegister.withUnsafeBytes { memcpy(engine.isRegisterBuf.contents(),  $0.baseAddress!, nodeCount) }
        tip.weights.withUnsafeBytes    { memcpy(engine.edgeWeightsBuf.contents(), $0.baseAddress!, nodeCount * 6 * 4) }
        tip.activation.withUnsafeBytes { memcpy(engine.activationBuf.contents(),  $0.baseAddress!, nodeCount * 2) }
        tip.values.withUnsafeBytes     { memcpy(engine.nodeValueBuf.contents(),   $0.baseAddress!, nodeCount * 4) }

        // Back edges go back through the engine's own add path, as the
        // snapshot loader does: the latch list and the isRegister flags have
        // to agree. The flags restored above already match the list being
        // rebuilt here (same source engine), so re-marking is idempotent.
        engine.backEdgeSrcs.removeAll(keepingCapacity: false)
        engine.backEdgeDsts.removeAll(keepingCapacity: false)
        try restoreBackEdges(engine: engine, blob: tip.backEdges, nodeCount: nodeCount)

        // Ranks (and with them the rank/colour segment table) just changed.
        engine.markRankTopologyDirty()
    }

    private static func readEngineBuffers(
        engine: DagDBEngine, nodeCount: Int
    ) -> TipArrays {
        let rank  = Data(bytesNoCopy: engine.rankBuf.contents(),        count: nodeCount * 8,     deallocator: .none)
        let truth = Data(bytesNoCopy: engine.truthStateBuf.contents(),  count: nodeCount,         deallocator: .none)
        let type  = Data(bytesNoCopy: engine.nodeTypeBuf.contents(),    count: nodeCount,         deallocator: .none)
        let low   = Data(bytesNoCopy: engine.lut6LowBuf.contents(),     count: nodeCount * 4,     deallocator: .none)
        let high  = Data(bytesNoCopy: engine.lut6HighBuf.contents(),    count: nodeCount * 4,     deallocator: .none)
        let nb    = Data(bytesNoCopy: engine.neighborsBuf.contents(),   count: nodeCount * 6 * 4, deallocator: .none)
        let reg   = Data(bytesNoCopy: engine.isRegisterBuf.contents(),  count: nodeCount,         deallocator: .none)
        let wgt   = Data(bytesNoCopy: engine.edgeWeightsBuf.contents(), count: nodeCount * 6 * 4, deallocator: .none)
        let act   = Data(bytesNoCopy: engine.activationBuf.contents(),  count: nodeCount * 2,     deallocator: .none)
        let val   = Data(bytesNoCopy: engine.nodeValueBuf.contents(),   count: nodeCount * 4,     deallocator: .none)
        return TipArrays(
            rank:       Array(rank),
            truth:      Array(truth),
            type:       Array(type),
            low:        Array(low),
            high:       Array(high),
            neighbors:  Array(nb),
            isRegister: Array(reg),
            weights:    Array(wgt),
            activation: Array(act),
            values:     Array(val),
            backEdges:  backEdgeBlob(engine: engine)
        )
    }

    /// Serialize the engine's back-edge list the way the snapshot's v4
    /// section does: u32 count, then u32 src / u32 dst per entry.
    private static func backEdgeBlob(engine: DagDBEngine) -> [UInt8] {
        var out = Data()
        appendU32(&out, UInt32(engine.backEdgeCount))
        for i in 0..<engine.backEdgeCount {
            appendU32(&out, engine.backEdgeSrcs[i])
            appendU32(&out, engine.backEdgeDsts[i])
        }
        return [UInt8](out)
    }

    /// Rebuild the engine's back-edge list from a serialized section. Mirrors
    /// the snapshot loader's range check: a corrupt entry past `nodeCount`
    /// would write past `isRegisterBuf`.
    private static func restoreBackEdges(
        engine: DagDBEngine, blob: [UInt8], nodeCount: Int
    ) throws {
        let data = Data(blob)
        guard data.count >= 4 else {
            throw BackupError.invalidDiff("back-edge section shorter than its count")
        }
        let count = Int(readU32(data, 0))
        guard data.count == 4 + count * 8 else {
            throw BackupError.invalidDiff(
                "back-edge section is \(data.count) bytes, expected \(4 + count * 8) for \(count) pairs")
        }
        for i in 0..<count {
            let off = 4 + i * 8
            let src = readU32(data, off)
            let dst = readU32(data, off + 4)
            guard Int(src) < nodeCount, Int(dst) < nodeCount else {
                engine.backEdgeSrcs.removeAll(keepingCapacity: false)
                engine.backEdgeDsts.removeAll(keepingCapacity: false)
                let rp = engine.isRegisterBuf.contents()
                    .bindMemory(to: UInt8.self, capacity: nodeCount)
                for j in 0..<nodeCount { rp[j] = 0 }
                throw BackupError.invalidDiff(
                    "back-edge entry \(i) out of range: src=\(src) dst=\(dst) nodeCount=\(nodeCount)")
            }
            try engine.addBackEdgeUnchecked(src: src, dst: dst)
        }
    }

    private static func applyDiff(
        to tip: inout TipArrays,
        entry: DiffEntry,
        nodeCount: Int
    ) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: entry.path))
        guard data.count >= diffHeaderSize else {
            throw BackupError.invalidDiff("\(entry.name): too short")
        }
        let m = [UInt8](data[0..<4])
        guard m == diffMagic else {
            throw BackupError.invalidDiff("\(entry.name): magic")
        }
        let ver = readU32(data, 4)
        if ver == diffVersionLegacy { throw BackupError.legacyFormat }
        guard ver == diffVersion else {
            throw BackupError.invalidDiff("\(entry.name): version \(ver)")
        }

        // Integrity before decode: the sidecar says whether these are the bytes
        // that were written, exactly as the base's manifest does.
        try verifyManifest(for: entry)

        let fileNC = Int(readU32(data, 8))
        guard fileNC == nodeCount else {
            throw BackupError.shapeMismatch("\(entry.name): nodeCount \(fileNC) != \(nodeCount)")
        }
        let seq = Int(readU32(data, 12))

        var offset = diffHeaderSize
        let segSizes = fixedSegmentSizes(nodeCount: nodeCount)
        func readSeg(index: Int, expectedSize: Int) throws -> [UInt8] {
            guard offset + 4 <= data.count else {
                throw BackupError.invalidDiff("\(entry.name): truncated segment header")
            }
            let sz = Int(readU32(data, offset))
            offset += 4
            guard offset + sz <= data.count else {
                throw BackupError.invalidDiff("\(entry.name): truncated segment body")
            }
            let compressed = data.subdata(in: offset..<(offset + sz))
            offset += sz
            let decompressed = DagDBSnapshot.zlibDecompress(compressed, expectedSize: expectedSize)
            guard decompressed.count == expectedSize else {
                throw BackupError.segmentLength(
                    seq: seq, segment: segmentNames[index],
                    actual: decompressed.count, expected: expectedSize)
            }
            return [UInt8](decompressed)
        }

        var fixed: [[UInt8]] = []
        fixed.reserveCapacity(segSizes.count)
        for (i, size) in segSizes.enumerated() {
            fixed.append(try readSeg(index: i, expectedSize: size))
        }

        // Back-edge section: absolute, not XOR — u32 raw size, then the usual
        // compressed segment.
        guard offset + 4 <= data.count else {
            throw BackupError.invalidDiff("\(entry.name): truncated back-edge size")
        }
        let beRaw = Int(readU32(data, offset))
        offset += 4
        let beBlob = try readSeg(index: 10, expectedSize: beRaw)

        // The section's own declared size is not a check — it is the thing
        // being checked. Its length has to equal what its pair count claims,
        // or a padded blob rides in behind an honest count.
        guard beBlob.count >= 4 else {
            throw BackupError.backEdgeSection(
                seq: seq, actual: beBlob.count, expected: 4, count: 0)
        }
        let bePairs = Int(readU32(Data(beBlob), 0))
        let beExpected = 4 + bePairs * 8
        guard beBlob.count == beExpected else {
            throw BackupError.backEdgeSection(
                seq: seq, actual: beBlob.count, expected: beExpected, count: bePairs)
        }

        try xorInPlace(&tip.rank,       fixed[0], seq: seq, segment: segmentNames[0])
        try xorInPlace(&tip.truth,      fixed[1], seq: seq, segment: segmentNames[1])
        try xorInPlace(&tip.type,       fixed[2], seq: seq, segment: segmentNames[2])
        try xorInPlace(&tip.low,        fixed[3], seq: seq, segment: segmentNames[3])
        try xorInPlace(&tip.high,       fixed[4], seq: seq, segment: segmentNames[4])
        try xorInPlace(&tip.neighbors,  fixed[5], seq: seq, segment: segmentNames[5])
        try xorInPlace(&tip.isRegister, fixed[6], seq: seq, segment: segmentNames[6])
        try xorInPlace(&tip.weights,    fixed[7], seq: seq, segment: segmentNames[7])
        try xorInPlace(&tip.activation, fixed[8], seq: seq, segment: segmentNames[8])
        try xorInPlace(&tip.values,     fixed[9], seq: seq, segment: segmentNames[9])
        tip.backEdges = beBlob
    }

    // MARK: - Byte helpers

    /// XOR two equal-length buffers. A length disagreement is refused by name:
    /// clamping to the shorter of the two is exactly what let a 4-byte rank
    /// segment survive an 8-byte rank buffer.
    private static func xor(
        _ a: [UInt8], _ b: [UInt8], seq: Int, segment: String
    ) throws -> [UInt8] {
        guard a.count == b.count else {
            throw BackupError.segmentLength(
                seq: seq, segment: segment, actual: b.count, expected: a.count)
        }
        var out = [UInt8](repeating: 0, count: a.count)
        for i in 0..<a.count { out[i] = a[i] ^ b[i] }
        return out
    }

    private static func xorInPlace(
        _ a: inout [UInt8], _ b: [UInt8], seq: Int, segment: String
    ) throws {
        guard a.count == b.count else {
            throw BackupError.segmentLength(
                seq: seq, segment: segment, actual: b.count, expected: a.count)
        }
        for i in 0..<a.count { a[i] ^= b[i] }
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

    // MARK: - Durability

    private static func atomicWrite(data: Data, path: String) throws {
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        let fd = open(path, O_RDONLY)
        if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC); close(fd) }
        let dir = (path as NSString).deletingLastPathComponent
        let dirFd = open(dir, O_RDONLY)
        if dirFd >= 0 { _ = fcntl(dirFd, F_FULLFSYNC); close(dirFd) }
    }

    /// Write `<path>.sha256` over the bytes that actually landed, the way the
    /// snapshot's manifest is written.
    private static func writeManifest(for path: String) throws {
        guard let finalBytes = try? Data(contentsOf: URL(fileURLWithPath: path),
                                         options: [.mappedIfSafe]) else {
            throw BackupError.ioFailure("re-read for sidecar: \(path)")
        }
        let hex = DagDBSnapshot.sha256Hex(finalBytes)
        let manifestPath = DagDBSnapshot.manifestPathFor(path)
        try Data((hex + "\n").utf8).write(
            to: URL(fileURLWithPath: manifestPath), options: [.atomic])
        let mfd = open(manifestPath, O_RDONLY)
        if mfd >= 0 { _ = fcntl(mfd, F_FULLFSYNC); close(mfd) }
        let dirFd = open((path as NSString).deletingLastPathComponent, O_RDONLY)
        if dirFd >= 0 { _ = fcntl(dirFd, F_FULLFSYNC); close(dirFd) }
    }

    /// Verify a diff against its sidecar. Unlike the base — where a missing
    /// manifest means a pre-manifest file and is accepted with a warning —
    /// every format-2 diff is written with one, so a missing sidecar is a
    /// refusal, not a legacy case.
    private static func verifyManifest(for entry: DiffEntry) throws {
        let manifestPath = DagDBSnapshot.manifestPathFor(entry.path)
        guard let mData = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
              let expected = String(data: mData, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty else {
            throw BackupError.checksumMissing(entry.name)
        }
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: entry.path),
                                    options: [.mappedIfSafe]) else {
            throw BackupError.ioFailure("read for sidecar check: \(entry.path)")
        }
        guard DagDBSnapshot.sha256Hex(bytes) == expected else {
            throw BackupError.checksumMismatch(entry.name)
        }
    }
}
