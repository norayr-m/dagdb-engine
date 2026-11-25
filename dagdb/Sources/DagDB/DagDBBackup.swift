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
///   · A non-finite edge weight or node value is refused by name — in the
///     base (by the snapshot loader) and in the state every diff leaves
///     (naming the diff) — before RESTORE writes the caller's engine and
///     before COMPACT writes or deletes a file.
///
/// FORMAT 3: format 2's ten XOR segments, then the four ternary lanes as XOR segments
///     mode (N)          ttableId (2·N)     thrLo (4·N)        thrHi (4·N)
/// then the back-edge section (as format 2), then the table library carried
/// WHOLE like the back edges (u32 raw size + u32 compressed size + body;
/// 729 bytes per table). APPEND writes format 3 exactly when the diff has a
/// ternary part — a lane that changed since the tip, or a library that
/// differs — and format 2 otherwise: a format-2 diff leaves the lanes and
/// the library as the tip holds them, which is then the exact answer. Both
/// formats apply, in any mix, in sequence order.
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
import CryptoKit

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
        /// A segment declares more bytes than it can hold: refused before the
        /// segment is read or anything allocated.
        case segmentBound(seq: Int, segment: String, declared: Int, max: Int, why: String)
        /// A diff's parent record names other bytes than the chain before it ends in (a diff from an earlier
        /// chain under a new base: a stale diff).
        case parentMismatch(name: String, parent: String, expected: String, what: String)
        /// A chain file the daemon may not read (not a regular file, outside the root, changed).
        case file(String)

        public var description: String {
            switch self {
            case .noBase(let s):        return "no base: \(Reply.quoted(s))"
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
                return "io: backup chain has two diffs with sequence \(seq): \(Reply.quoted(first)) and \(Reply.quoted(second))"
            case .diffExists(let name):
                return "io: backup diff \(Reply.quoted(name)) already exists; refusing to overwrite"
            case .checksumMismatch(let name):
                return "io: backup diff \(Reply.quoted(name)) does not match its sha256 sidecar; the file is corrupt or truncated"
            case .checksumMissing(let name):
                return "io: backup diff \(Reply.quoted(name)) has no sha256 sidecar; re-create the backup"
            case let .backEdgeSection(seq, actual, expected, count):
                return "io: backup diff \(seq) back-edge section is \(actual) bytes, expected \(expected) for \(count) pairs"
            case let .segmentBound(seq, segment, declared, max, why):
                return "io: backup diff \(seq) segment \(segment) declares \(declared) bytes, more than the \(max) it can hold (\(why))"
            case let .parentMismatch(name, parent, expected, what):
                return "io: backup diff \(Reply.quoted(name)) was written over sha256 \(Reply.quoted(parent)), but \(what) is sha256 \(expected):"
                    + " a diff from another chain (an old diff a BACKUP INIT could not remove?); refusing the chain; nothing restored"
            case .file(let why):
                // An admission refusal keeps its own code (out_of_budget).
                return why.hasPrefix("ERROR ") ? String(why.dropFirst(6)) : "io: \(why)"
            }
        }

        /// Refusals named on the wire: the reply is this sentence,
        /// not a `verb: error` wrapper, because the operator's next move is in
        /// the sentence itself.
        public var isNamedRefusal: Bool {
            switch self {
            case .legacyFormat, .segmentLength, .sequenceGap, .sequenceDuplicate,
                 .diffExists, .checksumMismatch, .checksumMissing, .backEdgeSection,
                 .segmentBound, .parentMismatch, .file:
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
    /// Format 3: format 2 plus the four ternary lanes and the library. See
    /// the file header for when APPEND writes which.
    public static let diffVersionTernary: UInt32 = 3
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
    /// Format 3's additions, in file order: four XOR segments after the ten,
    /// then the library after the back edges.
    public static let ternarySegmentNames = ["mode", "ttableId", "thrLo", "thrHi"]
    public static let librarySegmentName = "ttables"
    /// The most bytes a library segment can hold: 65,536 tables × 729
    /// = 47,775,744.
    public static let maxLibraryBytes = TernaryReference.maxTables * TernaryReference.tableSize
    /// Deflate decodes at most 1,032 bytes per compressed byte: a match is at
    /// most 258 bytes and costs at least two bits (a length code and a
    /// distance code of one bit each, RFC 1951 3.2.7), so 8 bits give at most
    /// 4 × 258. A segment whose size the file declares (the back edges, the
    /// library) is refused when it declares more than its compressed bytes
    /// can decode to — before the decode buffer is allocated.
    public static let deflateMaxRatio = 1032

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
        /// st_size of the open file (never lstat).
        let size: Int
    }

    /// A chain file refused by the read helper, as a named refusal.
    static func fileRefusal(_ r: DaemonFile.Refusal) -> BackupError { .file("\(Reply.errorWords(r))") }

    /// Every `.diff` in `dir`, header-scanned, in filename order. A short or foreign header is described
    /// (seq -1), never refused here: `BACKUP INFO` is read-only and has to be able to describe a broken chain.
    /// Each entry is opened through the read helper (without blocking, a regular file inside the
    /// root) and its first 16 bytes read; an entry that is not one (a FIFO would hang INFO and RESTORE) is
    /// refused by name, and so is a listing outside the root.
    static func scanDiffs(dir: String) throws -> [DiffEntry] {
        let all: [String]
        do { all = try DaemonFile.listDirectory(dir) }
        catch DaemonFile.Refusal.missing { all = [] }
        catch let r as DaemonFile.Refusal { throw fileRefusal(r) }
        let names = all.filter { $0.hasSuffix(".diff") }.sorted()
        return try names.map { name in
            let path = dir + "/" + name
            var seq = -1
            var version: UInt32 = 0
            let r: DaemonFile.Reader
            do { r = try DaemonFile.Reader(path) } catch let f as DaemonFile.Refusal { throw fileRefusal(f) }
            if r.size >= diffHeaderSize {
                let head: Data
                do { head = try r.read(diffHeaderSize) } catch let f as DaemonFile.Refusal { throw fileRefusal(f) }
                if [UInt8](head[0..<4]) == diffMagic {
                    version = readU32(head, 4)
                    seq = Int(readU32(head, 12))
                }
            }
            return DiffEntry(path: path, name: name, seq: seq, version: version, size: r.size)
        }
    }

    /// The chain's diffs in the order they must be applied — sequence order,
    /// read from each header. Refuses an unreadable header, a retired format,
    /// a duplicate sequence number and a gap, each by name.
    static func orderedDiffs(dir: String) throws -> [DiffEntry] {
        let scanned = try scanDiffs(dir: dir)
        for e in scanned {
            guard e.seq >= 0 else {
                throw BackupError.invalidDiff("\(Reply.quoted(e.name)): header unreadable")
            }
            if e.version == diffVersionLegacy { throw BackupError.legacyFormat }
            guard e.version == diffVersion || e.version == diffVersionTernary else {
                throw BackupError.invalidDiff("\(Reply.quoted(e.name)): version \(e.version)")
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
        let base = dir + "/base.dags"
        // The base's size by fstat of a regular, contained file (a FIFO or a link out of the root is refused
        // by name; lstat would give a link's own length).
        let baseSize: Int?
        do { baseSize = try DaemonFile.sizeIfPresent(base) } catch let r as DaemonFile.Refusal { throw fileRefusal(r) }
        let baseExists = baseSize != nil

        // Sequence order where the headers allow it, filename order otherwise —
        // INFO describes broken chains, it does not refuse them.
        let scanned = try scanDiffs(dir: dir)
        let ordered = scanned.allSatisfy { $0.seq >= 0 }
            ? scanned.sorted { $0.seq < $1.seq }
            : scanned

        var totalDiffBytes = 0
        for e in ordered {
            totalDiffBytes += e.size
        }

        // Format version lives in the first diff's header; a chain with no
        // diffs has nothing to read, so it reports what this build writes.
        let formatVersion = ordered.first.map { $0.version } ?? diffVersion

        return ChainInfo(
            baseExists: baseExists, diffCount: ordered.count,
            diffPaths: ordered.map { $0.path }, baseSizeBytes: baseSize ?? 0,
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
        // The new base lands FIRST (the snapshot's own tmp file and rename;
        // its manifest after it), and the old chain's diffs are removed only
        // after it has, each removal checked. Wiping the old chain first would
        // let a base save that failed (a tmp that could not be opened, a full
        // disk, the ternary refusal) answer ERROR over a destroyed chain, with
        // base.dags.sha256 left beside no base. A directory this verb created
        // is removed again when the save fails.
        let created = try StagedFileSet.createMissingDirectories(dir)
        // Every file this verb replaces or removes, checked against the
        // daemon's live files before anything is written (the base itself is SAVE's own check).
        if let r = chainRemovalRefusal(dir: dir) {
            StagedFileSet.removeEmptyDirectories(created)
            throw fileRefusal(r)
        }

        // twin: nil — twin state is not part of a backup, and the base says so
        // by carrying an empty v7 TWIN section.
        let saved: (bytesWritten: Int, uncompressedBodyBytes: Int, elapsedMs: Double)
        do {
            saved = try DagDBSnapshot.save(
                engine: engine, nodeCount: nodeCount,
                gridW: gridW, gridH: gridH,
                tickCount: tickCount,
                path: dir + "/base.dags",
                compressed: true,
                twin: nil
            )
        } catch {
            StagedFileSet.removeEmptyDirectories(created)
            throw error
        }

        // The old chain's diffs and their sidecars, now the new base is in place.
        if let left = removeDiffs(dir: dir) {
            throw BackupError.ioFailure("the new base \(Reply.quoted(dir + "/base.dags")) landed, but \(left); "
                + "RESTORE would apply what is left onto the new base: remove those files, or run BACKUP INIT again")
        }
        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (saved.bytesWritten, elapsed)
    }

    /// The first of the daemon's live files among the names `removeDiffs`
    /// removes (`*.diff`, `*.diff.sha256`, `*.diff.parent`) in `dir`, or nil.
    static func chainRemovalRefusal(dir: String) -> DaemonFile.Refusal? {
        guard !DaemonFile.reserved.isEmpty else { return nil }
        let c = (try? DaemonFile.forWrite(dir)) ?? dir
        for name in (try? DaemonFile.listDirectory(c)) ?? []
        where name.hasSuffix(".diff") || name.hasSuffix(".diff.sha256") || name.hasSuffix(".diff.parent") {
            if let r = DaemonFile.reservedRefusal(c + "/" + name) { return r }
        }
        return nil
    }

    /// Every `.diff` (in sequence order, lowest first, so a
    /// failure part-way leaves a gap that RESTORE refuses by name) and every
    /// `.diff.sha256` in `dir` removed; nil, or what could not be removed.
    /// Removals go through the parent's descriptor, no link followed (a link named *.diff is
    /// removed, never its target); the `.diff.parent` records too.
    static func removeDiffs(dir: String) -> String? {
        let dir = (try? DaemonFile.forWrite(dir)) ?? dir
        if let r = chainRemovalRefusal(dir: dir) { return "\(Reply.errorWords(r))" }
        let diffs: [DiffEntry]
        do {
            diffs = try scanDiffs(dir: dir).sorted { ($0.seq, $0.name) < ($1.seq, $1.name) }
        } catch {
            return "the old chain could not be listed (\(Reply.errorWords(error)))"
        }
        var failed: [String] = []
        for d in diffs {
            let e = DaemonFile.unlinkNoFollow(d.path)
            if e != 0 && e != ENOENT { failed.append("\(d.name) (unlink \(DaemonFile.errnoName(e)))") }
        }
        for name in (try? DaemonFile.listDirectory(dir)) ?? [] where name.hasSuffix(".diff.sha256") || name.hasSuffix(".diff.parent") {
            let e = DaemonFile.unlinkNoFollow(dir + "/" + name)
            if e != 0 && e != ENOENT { failed.append("\(name) (unlink \(DaemonFile.errnoName(e)))") }
        }
        if failed.isEmpty { return nil }
        return "\(failed.count) old chain file(s) could not be removed: " + failed.joined(separator: ", ")
    }

    // MARK: - Append diff

    public static func appendDiff(
        engine: DagDBEngine,
        nodeCount: Int,
        gridW: Int,
        gridH: Int,
        dir: String
    ) throws -> (diffBytes: Int, diffPath: String, elapsedMs: Double, format: UInt32) {
        let t0 = Date()
        let dir = try canonicalDir(dir)
        guard DaemonFile.lkind(dir + "/base.dags") != nil else {
            throw BackupError.noBase(dir + "/base.dags")
        }
        // Ternary, on write: a state a restore would refuse is never
        // appended.
        if let why = engine.ternaryStateViolation() {
            throw BackupError.invalidDiff("ternary: \(why)")
        }

        // The sequence comes from the chain's headers, and the next number must
        // be free on disk — a renamed diff sitting on the next slot must never
        // be overwritten.
        let existing = try orderedDiffs(dir: dir)
        let seq = existing.count + 1
        let diffName = String(format: "%05d.diff", seq)
        let diffPath = dir + "/" + diffName
        guard DaemonFile.lkind(diffPath) == nil else {
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
        // Format 3 exactly when there is a ternary part (file header).
        var ternDiffs: [[UInt8]] = []
        let tipTern = tip.ternaryBuffers, curTern = cur.ternaryBuffers
        for i in 0..<tipTern.count {
            ternDiffs.append(try xor(tipTern[i], curTern[i], seq: seq, segment: ternarySegmentNames[i]))
        }
        let ternary = ternDiffs.contains { $0.contains { $0 != 0 } } || tip.ttables != cur.ttables
        let format = ternary ? diffVersionTernary : diffVersion

        // Pack diff file: header + 10 zlib-compressed XOR segments (each: u32
        // compressed size + body) + the absolute back-edge section (u32 raw
        // size + u32 compressed size + body).
        var out = Data()
        out.append(contentsOf: diffMagic)
        appendU32(&out, format)
        appendU32(&out, UInt32(nodeCount))
        appendU32(&out, UInt32(seq))

        for segment in fixedDiffs + (ternary ? ternDiffs : []) {
            let compressed = DagDBSnapshot.zlibCompress(Data(segment))
            appendU32(&out, UInt32(compressed.count))
            out.append(compressed)
        }

        let beCompressed = DagDBSnapshot.zlibCompress(Data(cur.backEdges))
        appendU32(&out, UInt32(cur.backEdges.count))
        appendU32(&out, UInt32(beCompressed.count))
        out.append(beCompressed)

        if ternary {
            let libCompressed = DagDBSnapshot.zlibCompress(Data(cur.ttables))
            appendU32(&out, UInt32(cur.ttables.count))
            appendU32(&out, UInt32(libCompressed.count))
            out.append(libCompressed)
        }

        try atomicWrite(data: out, path: diffPath)
        do {
            // The diff's parent record (the sha256 of the bytes it was diffed against: the base,
            // or the diff before it), before its sidecar, so a diff never stands valid without one.
            try atomicWrite(data: Data((hexOf(replayed.tipDigest) + "\n").utf8), path: diffPath + ".parent")
            try writeManifest(for: diffPath)
        } catch {
            // The diff just written is this verb's own and nothing references
            // it yet, so it is removed (local rollback). Left with no sidecar,
            // BACKUP INFO would count it, and RESTORE and every later APPEND
            // would refuse the chain.
            _ = DaemonFile.unlinkNoFollow(diffPath + ".parent")
            let e = DaemonFile.unlinkNoFollow(diffPath)
            if e != 0 {
                throw BackupError.ioFailure("\(Reply.errorWords(error)); and \(Reply.quoted(diffName)), written before its sidecar failed, could not be removed"
                    + " (unlink \(DaemonFile.errnoName(e))): RESTORE and APPEND refuse the chain until it is")
            }
            throw error
        }

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (out.count, diffPath, elapsed, format)
    }

    // MARK: - Restore

    /// What a restore of `dir` will read, by size, before anything is read: the base's bytes, the
    /// diffs' bytes, their count and the largest diff by name (nil when the chain cannot be listed: the restore itself
    /// then refuses by name).
    public static func restoreInputBytes(dir: String) -> (base: Int, diffs: Int, count: Int, largest: (name: String, size: Int)?)? {
        guard let d = try? canonicalDir(dir), let entries = try? scanDiffs(dir: d) else { return nil }
        let base = ((try? DaemonFile.sizeIfPresent(d + "/base.dags")) ?? nil) ?? 0
        let big = entries.max { $0.size < $1.size || ($0.size == $1.size && $0.name > $1.name) }
        return (base, entries.reduce(0) { $0 + $1.size }, entries.count, big.map { ($0.name, $0.size) })
    }

    public static func restore(
        engine: DagDBEngine,
        nodeCount: Int,
        gridW: Int,
        gridH: Int,
        dir: String
    ) throws -> (diffsReplayed: Int, rankBytes: Int, elapsedMs: Double, parentUnchecked: Int, unverified: String?) {
        let t0 = Date()
        let dir = try canonicalDir(dir)
        let replayed = try replayChain(
            dir: dir, nodeCount: nodeCount, gridW: gridW, gridH: gridH)
        // Every rule against the replayed tip before a single buffer of the
        // caller's engine is written (`tipRefusal`; COMPACT asks the same).
        try tipRefusal(replayed.tip, nodeCount: nodeCount, nothing: "restored")
        // The library's room is reserved before the commit.
        try engine.reserveTableCapacity(replayed.tip.ttables.count / TernaryReference.tableSize)
        try applyTip(replayed.tip, to: engine, nodeCount: nodeCount)

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (replayed.diffsApplied, nodeCount * 8, elapsed, replayed.parentUnchecked, replayed.unverified)
    }

    // MARK: - Compact

    /// Collapse the diff chain into a new base.dags. The new base is written
    /// from the CHAIN's own replayed tip — every lane plus the back edges, at
    /// the chain's own tick count — never from a live engine, so a compaction
    /// cannot inherit anything the chain does not hold. A chain whose folded
    /// state holds a non-finite edge weight or node value (in the base or
    /// brought in by any diff) is refused by name by the replay, before
    /// anything is written or deleted, so RESTORE still gives the same
    /// refusal afterwards.
    /// - Parameter refuseWhatRestoreRefuses: the daemon's
    ///   COMPACT asks the replayed tip RESTORE's own rules (`tipRefusal`: the
    ///   back-edge list's range and CONNECT BACK's rules, S4 among them; the
    ///   slots against the persistence rule; the register flags against the
    ///   list; the ternary rules), in RESTORE's order and words, `nothing
    ///   written` for RESTORE's `nothing restored`, before anything is written
    ///   or deleted. So COMPACT refuses exactly the chains RESTORE refuses,
    ///   and compacting never makes a refused chain restorable. The library
    ///   default asks the ternary rules only and writes what the chain holds.
    public static func compact(
        nodeCount: Int,
        gridW: Int,
        gridH: Int,
        dir: String,
        refuseWhatRestoreRefuses: Bool = false
    ) throws -> (priorDiffCount: Int, newBaseBytes: Int, elapsedMs: Double) {
        let t0 = Date()
        let dir = try canonicalDir(dir)
        if let r = chainRemovalRefusal(dir: dir) { throw fileRefusal(r) }            // none of the daemon's live files
        let replayed = try replayChain(
            dir: dir, nodeCount: nodeCount, gridW: gridW, gridH: gridH)
        if refuseWhatRestoreRefuses {
            try tipRefusal(replayed.tip, nodeCount: nodeCount, nothing: "written")
        } else if let why = replayed.tip.ternaryViolation(nodeCount: nodeCount) {
            throw BackupError.invalidDiff("ternary: \(why)")
        }

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
        // landed through the atomic rename). Each
        // removal checked; one that fails is named, never an OK over a chain
        // of the new base and stale diffs.
        if let left = removeDiffs(dir: dir) {
            throw BackupError.ioFailure("the compacted base \(Reply.quoted(dir + "/base.dags")) landed, but \(left); "
                + "RESTORE would apply what is left onto the new base: remove those files")
        }

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return (replayed.diffsApplied, saved.bytesWritten, elapsed)
    }

    // MARK: - Internals

    /// RESTORE's rules against a replayed tip, in order, the first broken
    /// one thrown by name; asked by RESTORE (`nothing: "restored"`) and by
    /// the daemon's COMPACT (`nothing: "written"`), so the two
    /// refuse the same chains in the same words.
    private static func tipRefusal(_ tip: TipArrays, nodeCount: Int, nothing: String) throws {
        // The tip's back-edge list, range-checked (the words
        // `restoreBackEdges` gives, now before the commit: it used to throw
        // with the tip's lanes already written) and then against CONNECT
        // BACK's rules on the tip's own mode and neighbour lanes — before the
        // ternary rule, which reads the register FLAG lane and so missed an
        // entry whose flag the chain does not carry.
        let (beSrcs, beDsts) = try backEdgePairs(blob: tip.backEdges, nodeCount: nodeCount)
        if let r = tip.mode.withUnsafeBytes({ m in
            tip.neighbors.withUnsafeBytes { nb in
                DagDBEngine.backEdgeListRefusal(list: "back-edge section", srcs: beSrcs, dsts: beDsts,
                                                nodeCount: nodeCount, modeBytes: m, neighborBytes: nb)
            }
        }) {
            throw r
        }
        // The tip's slots
        // against the persistence rule every other loader asks (a source out
        // of range refused, LOAD's words; S1–S3 accepted, as RESTORE always
        // did), and the register FLAG lane against the list: a flag the list
        // does not carry is a register nobody latches (and, holding a slot, an
        // S4 by flag), refused by name. A list destination whose flag the
        // chain does not carry is re-marked by `applyTip`, as before.
        let tipNb = tipNeighbors(tip, nodeCount: nodeCount)
        if let v = tipNb.withUnsafeBufferPointer({
            DagDBSnapshot.persistenceSlotScan(nodeCount: nodeCount, neighbors: $0.baseAddress!).violation
        }) {
            throw BackupError.invalidDiff("validation: \(v); nothing \(nothing)")
        }
        var listed = [Bool](repeating: false, count: nodeCount)
        for d in beDsts { listed[Int(d)] = true }
        for i in 0..<min(nodeCount, tip.isRegister.count) where tip.isRegister[i] != 0 && !listed[i] {
            throw BackupError.invalidDiff("register flags: node \(i) is flagged a register but no back edge in the chain's list ends at it (a register nobody latches); nothing \(nothing)")
        }

        // Ternary, on load: the replayed tip is checked against every
        // rule before a single buffer of the caller's engine is written.
        if let why = tip.ternaryViolation(nodeCount: nodeCount) {
            throw BackupError.invalidDiff("ternary: \(why)")
        }
    }

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
        // Format 3 — the ternary lanes (XOR-diffed) and the library (whole).
        var mode:       [UInt8]
        var ttableId:   [UInt8]  // bytes of [UInt16]
        var thrLo:      [UInt8]  // bytes of [Float]
        var thrHi:      [UInt8]  // bytes of [Float]
        var ttables:    [UInt8]

        /// The ten XOR-diffed buffers, in file order.
        var fixedBuffers: [[UInt8]] {
            [rank, truth, type, low, high, neighbors,
             isRegister, weights, activation, values]
        }
        /// Format 3's four XOR-diffed lanes, in file order.
        var ternaryBuffers: [[UInt8]] { [mode, ttableId, thrLo, thrHi] }

        /// The first non-finite edge weight or node value this tip holds, by
        /// name (node, slot, value and bits), or nil — SET WEIGHT's and SET
        /// VALUE's rules.
        func finiteLaneRefusal() -> String? {
            weights.withUnsafeBytes { raw in
                raw.baseAddress.flatMap { DagDBSnapshot.weightRefusal($0, count: weights.count / 4) }
            } ?? values.withUnsafeBytes { raw in
                raw.baseAddress.flatMap { DagDBSnapshot.nodeValueRefusal($0, count: values.count / 4) }
            }
        }

        /// Every ternary rule against this tip, or nil.
        func ternaryViolation(nodeCount n: Int) -> String? {
            var tid = [UInt16](repeating: 0, count: n)
            var lo = [Float](repeating: 0, count: n), hi = lo
            tid.withUnsafeMutableBytes { $0.copyBytes(from: ttableId) }
            lo.withUnsafeMutableBytes { $0.copyBytes(from: thrLo) }
            hi.withUnsafeMutableBytes { $0.copyBytes(from: thrHi) }
            return ttables.withUnsafeBufferPointer { lib in
                TernaryReference.stateViolation(n: n, mode: mode, ttableId: tid, thrLo: lo, thrHi: hi,
                                                truth: truth, isRegister: isRegister, tables: lib)
            }
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

    /// The tip's slot lane as Int32 (its bytes, read unaligned; `nodeCount`
    /// × 6 entries, any the lane lacks empty).
    private static func tipNeighbors(_ tip: TipArrays, nodeCount: Int) -> [Int32] {
        var out = [Int32](repeating: -1, count: nodeCount * 6)
        let count = min(nodeCount * 6, tip.neighbors.count / 4)
        tip.neighbors.withUnsafeBytes { raw in
            for i in 0..<count { out[i] = raw.loadUnaligned(fromByteOffset: i * 4, as: Int32.self) }
        }
        return out
    }

    /// Replay base + all diffs into in-memory byte arrays. Does NOT touch any
    /// engine the caller owns — the scratch engine it returns exists only to
    /// hold the base it loaded.
    private static func replayChain(
        dir: String, nodeCount: Int, gridW: Int, gridH: Int
    ) throws -> (tip: TipArrays, scratch: DagDBEngine, tickCount: UInt32, diffsApplied: Int,
                 tipDigest: [UInt8], parentUnchecked: Int, unverified: String?) {
        let base = dir + "/base.dags"
        guard DaemonFile.lkind(base) != nil else {
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
            gridW: gridW, gridH: gridH, path: base, validate: false,
            wantDigest: true                                           // the first diff's parent
        )

        var tip = readEngineBuffers(engine: scratch, nodeCount: nodeCount)

        // Each diff is checked against its parent record before it is applied: the sha256 of the bytes it was
        // diffed against (the base for the first, the diff before it for the rest). A mismatch is a diff from
        // another chain and refuses the chain by name (without the check, an old diff a failed BACKUP INIT
        // left would be applied to the new base, silently). A diff written by an older build has no record:
        // it is applied and counted (`parentUnchecked`), and the reply names the count.
        var parent = loaded.digest ?? []
        var parentWhat = "base.dags"
        var unchecked = 0
        let ordered = try orderedDiffs(dir: dir)
        for entry in ordered {
            let rec: Data?
            do { rec = try DaemonFile.readIfPresent(entry.path + ".parent", .atMost(4096)) }
            catch let r as DaemonFile.Refusal { throw fileRefusal(r) }
            if let rec = rec {
                let found = String(data: rec, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard found == hexOf(parent) else {
                    throw BackupError.parentMismatch(name: entry.name, parent: found, expected: hexOf(parent), what: parentWhat)
                }
            } else {
                unchecked += 1
            }
            parent = try applyDiff(to: &tip, entry: entry, nodeCount: nodeCount)
            parentWhat = entry.name
        }
        return (tip, scratch, loaded.fileTicks, ordered.count, parent, unchecked, loaded.unverified)   // the base's unverified flag too
    }

    static func hexOf(_ d: [UInt8]) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// A chain directory's canonical path inside the root (every file under it is then read by
    /// the helper and written with no link followed).
    static func canonicalDir(_ dir: String) throws -> String {
        do { return try DaemonFile.forWrite(dir) } catch let r as DaemonFile.Refusal { throw fileRefusal(r) }
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
        // An all-default set of lanes leaves them unallocated.
        tip.mode.withUnsafeBytes { m in tip.ttableId.withUnsafeBytes { t in
            tip.thrLo.withUnsafeBytes { lo in tip.thrHi.withUnsafeBytes { hi in
                engine.installTernaryLanes(mode: m.baseAddress!, ttableId: t.baseAddress!,
                                           thrLo: lo.baseAddress!, thrHi: hi.baseAddress!)
            } } } }
        try engine.replaceLibrary(tip.ttables)

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
        // Lanes never allocated read as their zero defaults.
        let lanes = engine.ternaryLaneView
        func laneData(_ p: UnsafeRawPointer?, _ bytes: Int) -> Data {
            guard let p = p else { return Data(count: bytes) }
            return Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: p), count: bytes, deallocator: .none)
        }
        let md    = laneData(lanes.map { UnsafeRawPointer($0.mode) },     nodeCount)
        let tid   = laneData(lanes.map { UnsafeRawPointer($0.ttableId) }, nodeCount * 2)
        let lo    = laneData(lanes.map { UnsafeRawPointer($0.thrLo) },    nodeCount * 4)
        let hi    = laneData(lanes.map { UnsafeRawPointer($0.thrHi) },    nodeCount * 4)
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
            backEdges:  backEdgeBlob(engine: engine),
            mode:       Array(md),
            ttableId:   Array(tid),
            thrLo:      Array(lo),
            thrHi:      Array(hi),
            ttables:    engine.libraryBytes()
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

    /// A serialized back-edge section as its pairs, with `restoreBackEdges`'s
    /// size and range refusals (RESTORE reads it so before the commit).
    private static func backEdgePairs(blob: [UInt8], nodeCount: Int) throws -> ([UInt32], [UInt32]) {
        let data = Data(blob)
        guard data.count >= 4 else {
            throw BackupError.invalidDiff("back-edge section shorter than its count")
        }
        let count = Int(readU32(data, 0))
        guard data.count == 4 + count * 8 else {
            throw BackupError.invalidDiff(
                "back-edge section is \(data.count) bytes, expected \(4 + count * 8) for \(count) pairs")
        }
        var srcs: [UInt32] = [], dsts: [UInt32] = []
        srcs.reserveCapacity(count); dsts.reserveCapacity(count)
        for i in 0..<count {
            let src = readU32(data, 4 + i * 8), dst = readU32(data, 8 + i * 8)
            guard Int(src) < nodeCount, Int(dst) < nodeCount else {
                throw BackupError.invalidDiff(
                    "back-edge entry \(i) out of range: src=\(src) dst=\(dst) nodeCount=\(nodeCount)")
            }
            srcs.append(src); dsts.append(dst)
        }
        return (srcs, dsts)
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

    /// Returns the sha256 of the diff's bytes (the next diff's parent).
    @discardableResult
    private static func applyDiff(
        to tip: inout TipArrays,
        entry: DiffEntry,
        nodeCount: Int
    ) throws -> [UInt8] {
        // Read once (a regular file inside the root, unchanged while read); the sidecar check and the decode
        // both use this copy (the checksum is not taken on a second read).
        let data: Data
        // Admitted on its true size (the command's budget) before it is read.
        do { data = try DaemonFile.readAdmitted(entry.path) } catch let r as DaemonFile.Refusal { throw fileRefusal(r) }
        let digest = Array(SHA256.hash(data: data))
        guard data.count >= diffHeaderSize else {
            throw BackupError.invalidDiff("\(Reply.quoted(entry.name)): too short")
        }
        let m = [UInt8](data[0..<4])
        guard m == diffMagic else {
            throw BackupError.invalidDiff("\(Reply.quoted(entry.name)): magic")
        }
        let ver = readU32(data, 4)
        if ver == diffVersionLegacy { throw BackupError.legacyFormat }
        guard ver == diffVersion || ver == diffVersionTernary else {
            throw BackupError.invalidDiff("\(Reply.quoted(entry.name)): version \(ver)")
        }
        let isTernary = ver == diffVersionTernary

        // Integrity before decode: the sidecar says whether these are the bytes
        // that were written, exactly as the base's manifest does.
        try verifyManifest(for: entry, digest: digest)

        let fileNC = Int(readU32(data, 8))
        guard fileNC == nodeCount else {
            throw BackupError.shapeMismatch("\(Reply.quoted(entry.name)): nodeCount \(fileNC) != \(nodeCount)")
        }
        let seq = Int(readU32(data, 12))

        var offset = diffHeaderSize
        let segSizes = fixedSegmentSizes(nodeCount: nodeCount)
        // Every segment is read by its
        // name (a refusal names the segment it is about), and its size is
        // bounded before anything is allocated: never above `maxSize`, the
        // most that segment can legitimately hold — a lane's width × the
        // header's node count (checked equal to the engine's above), the
        // library's 65,536 × 729 bytes, the back edges' u32 pair count — and,
        // when the file itself declares the size (`declared`), never above
        // what the segment's compressed bytes can decode to.
        func readSeg(_ name: String, expectedSize: Int, maxSize: Int, why: String,
                     declared: Bool = false) throws -> [UInt8] {
            guard expectedSize <= maxSize else {
                throw BackupError.segmentBound(seq: seq, segment: name, declared: expectedSize,
                                               max: maxSize, why: why)
            }
            guard offset + 4 <= data.count else {
                throw BackupError.invalidDiff("\(Reply.quoted(entry.name)): truncated segment header (segment \(name))")
            }
            let sz = Int(readU32(data, offset))
            offset += 4
            guard offset + sz <= data.count else {
                throw BackupError.invalidDiff("\(Reply.quoted(entry.name)): truncated segment body (segment \(name))")
            }
            if declared {
                let (ceiling, overflow) = sz.multipliedReportingOverflow(by: deflateMaxRatio)
                if !overflow && expectedSize > ceiling {
                    throw BackupError.segmentBound(
                        seq: seq, segment: name, declared: expectedSize, max: ceiling,
                        why: "its \(sz) compressed bytes decode to at most \(deflateMaxRatio) bytes each")
                }
            }
            let compressed = data.subdata(in: offset..<(offset + sz))
            offset += sz
            let decompressed = DagDBSnapshot.zlibDecompress(compressed, expectedSize: expectedSize)
            guard decompressed.count == expectedSize else {
                throw BackupError.segmentLength(
                    seq: seq, segment: name,
                    actual: decompressed.count, expected: expectedSize)
            }
            return [UInt8](decompressed)
        }

        var fixed: [[UInt8]] = []
        fixed.reserveCapacity(segSizes.count)
        for (i, size) in segSizes.enumerated() {
            fixed.append(try readSeg(segmentNames[i], expectedSize: size, maxSize: size,
                                     why: "\(size / max(nodeCount, 1)) bytes per node × \(nodeCount) nodes"))
        }
        // Format 3: the four ternary lanes follow the ten.
        var tern: [[UInt8]] = []
        if isTernary {
            let widths = [1, 2, 4, 4]
            for (i, w) in widths.enumerated() {
                tern.append(try readSeg(ternarySegmentNames[i], expectedSize: nodeCount * w,
                                        maxSize: nodeCount * w, why: "\(w) bytes per node × \(nodeCount) nodes"))
            }
        }

        // Back-edge section: absolute, not XOR — u32 raw size, then the usual
        // compressed segment.
        guard offset + 4 <= data.count else {
            throw BackupError.invalidDiff("\(Reply.quoted(entry.name)): truncated back-edge size")
        }
        let beRaw = Int(readU32(data, offset))
        offset += 4
        // Node count does not bound the back edges (the engine takes several
        // per register); the u32 pair count does, and the decode bound below
        // it is what keeps a declared size from allocating.
        let beBlob = try readSeg(segmentNames[10], expectedSize: beRaw, maxSize: 4 + 8 * Int(UInt32.max),
                                 why: "a u32 pair count of 8-byte pairs", declared: true)

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

        // Format 3: the ternary lanes XOR, the library whole (absolute, like
        // the back edges). A format-2 diff leaves both as the tip holds them.
        if isTernary {
            guard offset + 4 <= data.count else {
                throw BackupError.invalidDiff("\(Reply.quoted(entry.name)): truncated library size")
            }
            let libRaw = Int(readU32(data, offset))
            offset += 4
            // The declared library size is refused above 65,536 × 729 bytes,
            // by name, before the segment is read.
            let libWhy = "\(TernaryReference.maxTables) tables × \(TernaryReference.tableSize) bytes"
            guard libRaw <= maxLibraryBytes else {
                throw BackupError.segmentBound(seq: seq, segment: librarySegmentName, declared: libRaw,
                                               max: maxLibraryBytes, why: libWhy)
            }
            let lib = try readSeg(librarySegmentName, expectedSize: libRaw, maxSize: maxLibraryBytes,
                                  why: libWhy, declared: true)
            if let why = TernaryReference.libraryRefusal(lib) {
                throw BackupError.invalidDiff("\(Reply.quoted(entry.name)): ternary: \(why)")
            }
            try xorInPlace(&tip.mode,     tern[0], seq: seq, segment: ternarySegmentNames[0])
            try xorInPlace(&tip.ttableId, tern[1], seq: seq, segment: ternarySegmentNames[1])
            try xorInPlace(&tip.thrLo,    tern[2], seq: seq, segment: ternarySegmentNames[2])
            try xorInPlace(&tip.thrHi,    tern[3], seq: seq, segment: ternarySegmentNames[3])
            tip.ttables = lib
        }

        // The state this diff leaves holds only
        // finite weights and values. The base was checked when it loaded and
        // every earlier diff here, so a refusal names the diff that brought
        // the value in. Nothing outside these CPU arrays has been written —
        // RESTORE commits only a whole checked tip, COMPACT writes and
        // deletes nothing, APPEND writes no diff.
        if let why = tip.finiteLaneRefusal() {
            throw BackupError.invalidDiff("\(Reply.quoted(entry.name)): \(why)")
        }
        return digest
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

    /// Through the helper (a hidden temporary, no link followed, synced, renamed, the
    /// directory synced).
    private static func atomicWrite(data: Data, path: String) throws {
        do { try DaemonFile.atomicWrite(data, to: path) } catch let r as DaemonFile.Refusal { throw fileRefusal(r) }
    }

    /// Write `<path>.sha256` over the bytes that actually landed, the way the
    /// snapshot's manifest is written. Streamed back through the read helper.
    private static func writeManifest(for path: String) throws {
        let digest: [UInt8]
        do { digest = try DaemonFile.digest(path) } catch {
            throw BackupError.ioFailure("re-read for sidecar: \(Reply.quoted(path)) (\(Reply.errorWords(error)))")
        }
        let manifestPath = DagDBSnapshot.manifestPathFor(path)
        try atomicWrite(data: Data((hexOf(digest) + "\n").utf8), path: manifestPath)
    }

    /// Verify a diff against its sidecar. Unlike the base — where a missing
    /// manifest means a pre-manifest file and is accepted with a warning —
    /// every format-2 diff is written with one, so a missing sidecar is a
    /// refusal, not a legacy case. The sidecar is read once, bounded, as a regular file inside
    /// the root (one that is not is refused by name); `digest` is the diff's own copy's (the bytes decoded).
    private static func verifyManifest(for entry: DiffEntry, digest: [UInt8]) throws {
        let manifestPath = DagDBSnapshot.manifestPathFor(entry.path)
        let mData: Data?
        do { mData = try DaemonFile.readIfPresent(manifestPath, .atMost(DagDBSnapshot.manifestMaxBytes)) }
        catch let r as DaemonFile.Refusal { throw fileRefusal(r) }
        guard let m = mData,
              let expected = String(data: m, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty else {
            throw BackupError.checksumMissing(entry.name)
        }
        guard hexOf(digest) == expected else {
            throw BackupError.checksumMismatch(entry.name)
        }
    }
}
