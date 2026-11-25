import Foundation
import CryptoKit
import DagDB


/// The era sidecar.
///
/// At its first boot on a log, this build writes `<wal>.hook1_era` once,
/// durably (a temp file, fsync, rename, the directory fsynced). It holds the
/// log's byte length at that moment and a SHA-256 of that prefix. Records
/// before the offset come from older builds; records at or after it were written by
/// this build. The log itself is not written at startup for it, so a log
/// this build has only booted on stays readable by older builds.
///
/// - The hash covers the prefix with the header's version field (bytes 4–7)
///   blanked: this build raises a log's version in place, on demand (a v6-only
///   record), and that rewrite is not a different log.
/// - The sidecar's path goes through the data-root guard, as the startup
///   snapshot's does; a refused path is named and nothing is written.
/// - A missing sidecar where one cannot be written, a mismatched one (the
///   log was replaced or cut), or a refused path: the boot names it and the
///   hook naming is conservative. The boot is never refused for it.
///
/// Format 2:
/// - The high-water mark: the sidecar also keeps the log length this build
///   last wrote and a hash of that prefix, sealed durably at each durable
///   snapshot and at clean shutdown. Bytes in [era, mark) are this build's own;
///   bytes past the mark that it did not seal are foreign (an older
///   build's appends) or its own unsealed tail after a crash, and their
///   ticks are named "may have" (a false "may", never a missed "did").
/// - A seal of 0 bytes or of the header alone proves nothing and never
///   matches.
/// - After a boot has named a mismatch it re-seals once (era = mark =
///   the log's length then). The boot never says "did", so
///   the old `preEraProven` bit is not written and is ignored when read.
/// - Inode identity is not kept.
public enum DagDBHOOK1Era {

    public static let suffix = ".hook1_era"

    public static func sidecarPath(_ walPath: String) -> String { walPath + suffix }

    struct Sidecar: Codable {
        var format: Int
        /// The era's first byte (format 1: also its only seal).
        var length: Int
        var sha256: String
        /// Format 2: the high-water mark and its prefix hash.
        var mark: Int?
        var markSha256: String?
        /// Format 2 as written by earlier builds (a "proven" bit, now
        /// unused: the boot never says "did"); read and ignored.
        var preEraProven: Bool?
        var note: String
    }

    /// What the sidecar claims, before the replay checks it (no log read).
    public struct Claim: Equatable {
        public let era: Int, eraSha256: String, mark: Int, markSha256: String
    }

    /// What the boot knows about where this build's era begins in this log.
    public enum Era: Equatable {
        /// Records below `offset` come from older builds as the sidecar's first boot
        /// saw them (or are of unknown origin); records in [offset, mark) were written by
        /// this build; records at or past `mark` are foreign or a crash tail.
        case known(offset: Int, mark: Int)
        /// Unknown: every replayed tick is counted as possibly from an older build.
        case unknown(why: String)
    }

    /// The prefix hash: SHA-256 of `data[0..<length]` with bytes 4–7 zeroed.
    static func prefixHash(_ data: Data, length: Int) -> String {
        var p = Data(data.prefix(length))
        if p.count >= 8 { for i in 4..<8 { p[p.startIndex + i] = 0 } }
        return SHA256.hash(data: p).map { String(format: "%02x", $0) }.joined()
    }

    /// The data-root check for the sidecar's path. `DagDBStartup.pathViolation`
    /// (the startup snapshot's, and `guardPath`'s twin) first; then the path is
    /// resolved through its deepest EXISTING ancestor, because NSString's
    /// `resolvingSymlinksInPath` leaves a path whose last component does not
    /// exist yet unresolved, so a new file under a symlinked directory that
    /// points outside the root would pass it.
    static func violation(_ p: String, dataRoot: String?) -> String? {
        if let why = DagDBStartup.pathViolation(p, dataRoot: dataRoot) { return why }
        guard let root = dataRoot else { return nil }
        var head = (p as NSString).standardizingPath
        var tail: [String] = []
        while head != "/" && !FileManager.default.fileExists(atPath: head) {
            tail.insert((head as NSString).lastPathComponent, at: 0)
            head = (head as NSString).deletingLastPathComponent
        }
        guard let hp = realpath(head, nil) else { return "cannot resolve \(head)" }
        let resolved = ([String(cString: hp)] + tail).joined(separator: "/")
        free(hp)
        guard let rp = realpath(root, nil) else { return "cannot resolve the data root \(root)" }
        let rootResolved = String(cString: rp)
        free(rp)
        if !resolved.hasPrefix(rootResolved + "/") && resolved != rootResolved {
            return "outside DAGDB_DATA_ROOT '\(root)'"
        }
        return nil
    }

    /// Before replay: the sidecar as found, parsed only (the log is not
    /// read here; the replay hashes it). nil:
    /// there is none; `.unknown`: refused, unreadable or a short seal.
    public static func read(walPath: String, dataRoot: String?) -> (claim: Claim?, unknown: String?, refused: String?, exists: Bool) {
        let sp = sidecarPath(walPath)
        if let why = violation(sp, dataRoot: dataRoot) {
            return (nil, "the era sidecar \(sp) is refused (\(why)); none is read or written", why, false)
        }
        // Read once through the helper (without blocking, a regular file inside the root,
        // bounded); a refusal is named in the unreadable line (not swallowed by a `try?`).
        let raw: Data
        do {
            guard let d = try DaemonFile.readIfPresent(sp, .atMost(1 << 20)) else { return (nil, nil, nil, false) }
            raw = d
        } catch {
            return (nil, "the era sidecar \(sp) is unreadable (\(Reply.errorWords(error)))", nil, true)
        }
        guard let sc = try? JSONDecoder().decode(Sidecar.self, from: raw), sc.format == 1 || sc.format == 2, sc.length >= 0 else {
            return (nil, "the era sidecar \(sp) is unreadable", nil, true)
        }
        let mark = sc.mark ?? sc.length, markHash = sc.markSha256 ?? sc.sha256
        guard mark >= sc.length else { return (nil, "the era sidecar \(sp) is unreadable (its mark precedes its era)", nil, true) }
        // An empty or header-only seal proves nothing (the empty prefix's
        // hash matches any log; a header's, any log of that grid).
        guard mark > DagDBWAL.headerSize else {
            return (nil, "the era sidecar \(sp) seals only \(mark) bytes, which proves nothing about this log (an empty or header-only seal never matches)", nil, true)
        }
        return (Claim(era: sc.length, eraSha256: sc.sha256, mark: mark, markSha256: markHash),
                nil, nil, true)
    }

    /// After replay: the claim against the prefix digests the replay computed
    /// over the valid log of `validEnd` bytes. Nil: it matches; else why not.
    public static func mismatch(_ c: Claim, digests: [Int: String], validEnd: Int, sidecar sp: String) -> String? {
        guard c.mark <= validEnd else {
            return "the era sidecar \(sp) seals \(c.mark) bytes but the log holds \(validEnd) (a replaced or cut log)"
        }
        guard digests[c.mark] == c.markSha256, digests[c.era] == c.eraSha256 else {
            return "the era sidecar \(sp) does not match this log's first \(c.mark) bytes (a replaced log)"
        }
        return nil
    }

    /// Writes the sidecar (format 2) from hashes already in hand (temp, fsync,
    /// rename, directory fsync; no read of the log). Nil on success, else why not.
    public static func write(walPath: String, era: Int, eraSha256: String, mark: Int, markSha256: String,
                             dataRoot: String?) -> String? {
        // The temporary carries the daemon's marker (it was `<sidecar>.tmp`).
        let sp = sidecarPath(walPath), tmp = DaemonFile.tmpName(for: sp)
        for p in [sp, tmp] {
            if let why = violation(p, dataRoot: dataRoot) { return "\(p) refused (\(why))" }
        }
        guard era <= mark else { return "the era \(era) follows the mark \(mark)" }
        let sc = Sidecar(format: 2, length: era, sha256: eraSha256, mark: mark, markSha256: markSha256, preEraProven: nil,
                         note: "era: records before byte \(era) of this log come from older builds or are of unknown origin"
                             + "; records in [\(era), \(mark)) were written by a build that keeps this sidecar (its last seal); records past"
                             + " \(mark) are foreign or an unsealed tail"
                             + "; each hash covers its prefix with the header's version field (bytes 4-7) blanked")
        guard let body = try? JSONEncoder().encode(sc) else { return "encode failed" }
        // The canonical paths, every call with no link followed in any component.
        let csp: String, ctmp: String
        do { csp = try DaemonFile.forWrite(sp); ctmp = try DaemonFile.forWrite(tmp) } catch { return Reply.errorWords(error) }
        DaemonFile.unlinkNoFollow(ctmp)                               // never follows a link
        let fd: Int32
        do { fd = try DaemonFile.openForWrite(ctmp, create: true, exclusive: true, own: true) } catch { return "open \(tmp): \(Reply.errorWords(error))" }
        let wrote = body.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, body.count) }
        guard wrote == body.count, fsync(fd) == 0 else { close(fd); DaemonFile.unlinkNoFollow(ctmp); return "write \(tmp) failed" }
        close(fd)
        let re = DaemonFile.renameNoFollow(ctmp, csp)
        guard re == 0 else { DaemonFile.unlinkNoFollow(ctmp); return "rename \(tmp): errno \(re)" }
        DaemonFile.syncDirectory((csp as NSString).deletingLastPathComponent)
        return nil
    }

    /// The SHA-256 of the empty prefix (a log that does not exist yet).
    public static let emptySha256 = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()

    /// The log's current byte length (0 when it does not exist).
    public static func logLength(_ walPath: String) -> Int {
        ((try? DaemonFile.sizeIfPresent(walPath)) ?? nil) ?? 0                 // fstat, never lstat
    }
}
