import Foundation
import CryptoKit

/// DaemonFile — the daemon's one way to open a file.
///
/// **Reads** (`read`, `readIfPresent`, `Reader`), in order: the name judged before any open (resolved by the
/// writers' walk, its last link followed; refused if it leaves the root, so nothing outside is ever opened, a
/// FIFO or a device included; refused if it is not a regular file); the resolved path opened with O_NONBLOCK and
/// O_NOFOLLOW_ANY (a link swapped in after the check fails the open); fstat, and require a regular file;
/// containment again, by F_GETPATH on the OPEN descriptor (the file read, never the name); the site's size rule
/// on st_size; the caller's admission on that true size; one bounded read; fstat again, and refuse a file that
/// changed; the one copy goes back, and the caller hashes and decodes those bytes.
///
/// **Writes** (`forWrite` and the functions after it): the target is resolved name by name (`walk`) down to its
/// deepest existing folder, and the walk stops, refused, where it would leave the root; the final component may
/// not be a symbolic link; every open, rename and directory step then runs on that canonical path with
/// O_NOFOLLOW_ANY / RENAME_NOFOLLOW_ANY, so a
/// link swapped into any component between the check and the call makes the call fail (ELOOP) instead of
/// following it, and no file is ever created outside the root. Writers open without blocking and refuse a
/// target that is not a regular file.
///
/// **The root** is task-local (`root`): the command handler binds its canonical data root around every
/// command, startup recovery around the boot, so every open under them, however deep in the library (a tile
/// load, a twin restore, a replayed ALARM LOAD), is contained without a parameter at each call. Unbound (nil):
/// the daemon is unguarded (no DAGDB_DATA_ROOT), and library callers outside the daemon keep their old
/// semantics; the regular-file, non-blocking and no-follow rules hold either way.
///
/// **One link**: every open, reader and writer, refuses by name an existing
/// regular file with more than one hard link. F_GETPATH answers with one of an inode's names, so an in-root link
/// to a file outside the root passes the descriptor check; the daemon's own files always have one link. And
/// every temporary is a new file (`createTemporary`, O_CREAT | O_EXCL): no writer opens an existing name with
/// O_TRUNC.
///
/// **Refusals** are by name: an errno name and the quoted path, then a gloss (`Refusal.description`); no
/// NSError text. A path outside the root gets one text that names only the path as given.
public enum DaemonFile {

    // MARK: - The root

    /// The canonical (realpath) data root the current command or boot step is contained in; nil = unguarded.
    @TaskLocal public static var root: String? = nil

    /// `r` resolved by realpath (every symlink, /var -> /private/var included); nil for nil. A root that does
    /// not resolve keeps its standardized spelling (every containment check under it then fails closed).
    public static func canonicalRoot(_ r: String?) -> String? {
        guard let r = r, !r.isEmpty else { return nil }
        let std = (r as NSString).standardizingPath
        if let p = realpath(std, nil) { defer { free(p) }; return String(cString: p) }
        return std
    }

    /// `body` with `root` bound (canonicalized).
    public static func withRoot<R>(_ r: String?, _ body: () throws -> R) rethrows -> R {
        try $root.withValue(canonicalRoot(r), operation: body)
    }

    /// The daemon's own live files (canonical path -> what it is): the
    /// write-ahead log, its era sidecar and that sidecar's temporary, the socket, the --shm-file. Task-local:
    /// the command handler binds them around every command. No writer of the daemon creates, replaces,
    /// truncates or removes one (the log's own appender and the era writer open theirs with `own: true`).
    @TaskLocal public static var reserved: [String: String] = [:]

    /// The memory admission of the command (or boot step) in progress,
    /// `(bytes, what) -> refusal line or nil`; task-local, bound by the handler around every command (named by
    /// its verb) and by startup recovery around the boot. `readAdmitted` reads through it.
    @TaskLocal public static var admission: ((Int, String) -> String?)? = nil

    /// A path made canonical without following its last component (realpath of the parent, then the name):
    /// how a reserved file (a socket, a log) is registered.
    public static func canonicalPath(_ p: String) -> String {
        let std = (p as NSString).standardizingPath
        let parent = (std as NSString).deletingLastPathComponent, name = (std as NSString).lastPathComponent
        guard let rp = realpath(parent.isEmpty ? "." : parent, nil) else { return std }
        defer { free(rp) }
        let cp = String(cString: rp)
        return (cp == "/" ? "" : cp) + "/" + name
    }

    /// Compared as bytes, as the file system names them: a String comparison works on characters, and a name that
    /// starts with a combining mark joins the '/' before it into one character, so the root's prefix was not found.
    static func inside(_ real: String, _ root: String) -> Bool {
        real.utf8.elementsEqual(root.utf8) || real.utf8.starts(with: (root.hasSuffix("/") ? root : root + "/").utf8)
    }

    // MARK: - Refusals

    public enum Refusal: Error, CustomStringConvertible, Equatable, Reply.CarriesLine {
        /// ENOENT, and only ENOENT.
        case missing(path: String)
        /// A directory, fifo, character or block device, socket.
        case notRegular(path: String, kind: String)
        /// A symbolic link where the daemon follows none (a write's path).
        case link(path: String)
        /// The file opened, or the path resolved, lies outside the root. The refusal names only the path as
        /// given: where it resolves, and anything found there, stays unsaid.
        case outsideRoot(path: String)
        /// st_size breaks the site's size rule; nothing read.
        case size(path: String, have: Int, rule: String)
        /// The caller's admission reply, verbatim.
        case admission(String)
        case io(path: String, call: String, errno: Int32)
        /// dev/ino/size/mtime/ctime differ after the read.
        case changed(path: String, what: String)
        /// The read came up short of st_size (the file was cut while it was read).
        case cut(path: String, got: Int, want: Int)
        /// A '..' segment in a path the daemon opens.
        case traversal(path: String)
        /// An existing regular file with more than one hard link (another
        /// name of the same inode may lie outside the root, and the descriptor's path names only one of them).
        case linked(path: String, links: Int)
        /// One of the daemon's own live files as a writer's target.
        case reserved(path: String, what: String)

        /// The errno-name refusals in the one error function's words (`Reply.errnoWords`):
        /// the errno name and number plus the quoted path, never a description; every echoed path quoted.
        public var description: String {
            switch self {
            case .missing(let p): return Reply.errnoWords(ENOENT, path: p) + ": no such file"
            case .notRegular(let p, let k):
                return Reply.errnoWords(k == "directory" ? EISDIR : EFTYPE, path: p) + ": a \(k), not a regular file"
            case .link(let p):
                return Reply.errnoWords(ELOOP, path: p) + ": a symbolic link in a path the daemon writes (it follows none)"
            case .outsideRoot(let p): return Reply.errnoWords(EPERM, path: p) + ": resolves outside DAGDB_DATA_ROOT"
            case .size(let p, let have, let rule): return Reply.errnoWords(EFBIG, path: p) + ": \(have) bytes; \(rule)"
            case .admission(let line): return line
            case .io(let p, let call, let e): return Reply.errnoWords(e, path: p) + ": \(call) failed"
            case .changed(let p, let what):
                return Reply.errnoWords(ESTALE, path: p) + ": the file changed while it was read (\(what)); nothing read is used"
            case .cut(let p, let got, let want):
                return Reply.errnoWords(EIO, path: p) + ": \(got) of \(want) bytes read (the file was cut while it was read); nothing read is used"
            case .traversal(let p): return Reply.errnoWords(EINVAL, path: p) + ": a '..' segment"
            case .linked(let p, let n):
                return Reply.errnoWords(EMLINK, path: p) + ": the file has \(n) hard links; the daemon opens only a file with one link (a link from"
                    + " outside the data root would let it read or write that file); copy the file to a single-link file"
            case .reserved(let p, let what):
                return Reply.errnoWords(EBUSY, path: p) + ": \(what); no writer of this daemon creates, replaces, truncates or removes it"
            }
        }

        /// An admission refusal is a whole reply line of its own (`ERROR out_of_budget: …`),
        /// emitted under no second code.
        public var replyLine: String? {
            if case .admission(let line) = self { return line }
            return nil
        }

        /// An admission refusal (a budget said no), as opposed to the file itself.
        public var isAdmission: Bool {
            if case .admission = self { return true }
            return false
        }
    }

    /// The errno's symbolic name (the common ones), or "errno <n>".
    public static func errnoName(_ e: Int32) -> String {
        switch e {
        case EPERM: return "EPERM"; case ENOENT: return "ENOENT"; case EIO: return "EIO"; case ENXIO: return "ENXIO"
        case EBADF: return "EBADF"; case EAGAIN: return "EAGAIN"; case ENOMEM: return "ENOMEM"; case EACCES: return "EACCES"
        case EBUSY: return "EBUSY"; case EEXIST: return "EEXIST"; case EXDEV: return "EXDEV"; case ENOTDIR: return "ENOTDIR"
        case EISDIR: return "EISDIR"; case EINVAL: return "EINVAL"; case ENFILE: return "ENFILE"; case EMFILE: return "EMFILE"
        case ETXTBSY: return "ETXTBSY"; case EFBIG: return "EFBIG"; case ENOSPC: return "ENOSPC"; case EROFS: return "EROFS"
        case ELOOP: return "ELOOP"; case ENAMETOOLONG: return "ENAMETOOLONG"; case ENOTEMPTY: return "ENOTEMPTY"
        case EDQUOT: return "EDQUOT"; case ESTALE: return "ESTALE"; case EFTYPE: return "EFTYPE"; case EINTR: return "EINTR"
        case EOPNOTSUPP: return "EOPNOTSUPP"; case ENOTSUP: return "ENOTSUP"; case EDEADLK: return "EDEADLK"
        case EMLINK: return "EMLINK"
        default: return "errno \(e)"
        }
    }

    static func kind(_ mode: mode_t) -> String {
        switch mode & S_IFMT {
        case S_IFREG: return "regular file"
        case S_IFDIR: return "directory"
        case S_IFIFO: return "fifo"
        case S_IFCHR: return "character device"
        case S_IFBLK: return "block device"
        case S_IFSOCK: return "socket"
        case S_IFLNK: return "symbolic link"
        default: return "file of unknown type"
        }
    }

    /// F_GETPATH of an open descriptor.
    static func pathOf(_ fd: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
        guard fcntl(fd, F_GETPATH, &buf) == 0 else { return nil }
        return String(cString: buf)
    }

    /// The containment check on an open descriptor (no root bound: nil).
    static func outside(_ fd: Int32, _ path: String) -> Refusal? {
        guard let r = root else { return nil }
        guard let real = pathOf(fd) else { return .io(path: path, call: "fcntl(F_GETPATH)", errno: errno) }
        return inside(real, r) ? nil : .outsideRoot(path: path)
    }

    /// `.linked` for a regular file with more than one hard link, else nil.
    static func linkRefusal(_ st: stat, _ path: String) -> Refusal? {
        (st.st_mode & S_IFMT) == S_IFREG && st.st_nlink > 1 ? .linked(path: path, links: Int(st.st_nlink)) : nil
    }

    /// The same by lstat of a path (nil when nothing is there, or it is not a regular file).
    public static func linkRefusal(at path: String) -> Refusal? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return linkRefusal(st, path)
    }

    /// `.reserved` when the canonical path `c` is one of the daemon's live files.
    public static func reservedRefusal(_ c: String) -> Refusal? {
        reserved[c].map { .reserved(path: c, what: $0) }
    }

    /// `.reserved` for the first live file inside the canonical directory `c`
    /// (a writer that replaces or removes the whole directory would take it with it).
    public static func reservedInside(_ c: String) -> Refusal? {
        if let r = reservedRefusal(c) { return r }
        let prefix = c.hasSuffix("/") ? c : c + "/"
        return reserved.keys.sorted().first { $0.hasPrefix(prefix) }.map { .reserved(path: $0, what: reserved[$0]!) }
    }

    /// What a rename onto the canonical path `c` would replace, refused by
    /// name unless it is nothing or a regular file with one link that is not one of the daemon's live files: a
    /// socket (the daemon's own included), a FIFO, a device, a directory or a symbolic link is refused (a
    /// rename check that refused only a directory let SAVE onto the daemon's socket replace it).
    public static func renameTargetRefusal(_ c: String) -> Refusal? {
        if let r = reservedRefusal(c) { return r }
        var st = stat()
        guard lstat(c, &st) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return linkRefusal(st, c)
        case S_IFLNK: return .link(path: c)
        default: return .notRegular(path: c, kind: kind(st.st_mode))
        }
    }

    // MARK: - Reads

    /// The size rule a site applies to st_size before a byte is read.
    public enum Size: Equatable {
        /// The whole file (st_size, read once).
        case any
        /// st_size must be exactly this (else `.size`, nothing read).
        case exactly(Int)
        /// st_size must not exceed this (else `.size`, nothing read).
        case atMost(Int)
        /// The first min(st_size, n) bytes (a header).
        case prefix(Int)
    }

    /// open(2) for reading, read-only and without blocking: the name judged first (`judgedForRead`), then the
    /// path it resolves to opened (`openForRead`). The caller checks the descriptor (type, links, F_GETPATH) after
    /// the open as well.
    static func openJudged(_ path: String, directory: Bool) throws -> Int32 {
        guard let real = try judgedForRead(path, directory: directory) else {
            return try openForRead(path, as: path, directory: directory, judged: false)
        }
        return try openForRead(real, as: path, directory: directory, judged: true)
    }

    /// The judgement of a name a read is about to open, before anything is opened: the path resolved to the end
    /// by the walk the writers use (a last link followed), and refused if the resolution leaves the root (the one
    /// outside text), if a name is missing (ENOENT), if inside it fails (its errno), or if what it finds is not a
    /// regular file (`directory`: not a directory) or has more than one hard link. Returns the resolved path, which
    /// holds no link; nil when no root is bound (the name is then opened as given).
    static func judgedForRead(_ path: String, directory: Bool) throws -> String? {
        guard root != nil else { return nil }
        let abs = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        if abs.utf8.count >= Int(MAXPATHLEN) { throw Refusal.io(path: path, call: "open", errno: ENAMETOOLONG) }
        let w: Walked
        do { w = try walk(components(abs), followLast: true) } catch let s as WalkStop {
            switch s {
            case .outside: throw Refusal.outsideRoot(path: path)
            case let .failed(_, call, e): throw Refusal.io(path: path, call: call, errno: e)
            }
        }
        if !w.missing.isEmpty { throw Refusal.missing(path: path) }
        let type = w.st.st_mode & S_IFMT
        if directory {
            if type != S_IFDIR { throw Refusal.notRegular(path: path, kind: "file that is not a directory") }
        } else {
            if type != S_IFREG { throw Refusal.notRegular(path: path, kind: kind(w.st.st_mode)) }
            if let r = linkRefusal(w.st, path) { throw r }
        }
        return w.real
    }

    /// open(2) of `target` for the read named `path` (refusals name `path`). A judged target is opened with
    /// O_NOFOLLOW_ANY: it held no link when it was judged, so a link in it now was swapped in after the check, and
    /// the open fails (ELOOP) instead of following it.
    static func openForRead(_ target: String, as path: String, directory: Bool, judged: Bool) throws -> Int32 {
        var flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC
        if directory { flags |= O_DIRECTORY }
        if judged { flags |= O_NOFOLLOW_ANY }
        let fd = open(target, flags)
        guard fd >= 0 else {
            let e = errno
            if e == ENOENT { throw Refusal.missing(path: path) }
            if directory && e == ENOTDIR { throw Refusal.notRegular(path: path, kind: "file that is not a directory") }
            throw Refusal.io(path: path, call: "open", errno: e)
        }
        return fd
    }

    /// One file, opened for reading under the rules above (the judgement, open, fstat, containment, the size rule and the admission, at init); then bounded reads at
    /// increasing offsets (pread: no shared offset), each byte optionally fed to a SHA-256 as it is read, and
    /// `finish()`, the fstat after the read.
    public final class Reader {
        public let path: String
        /// st_size at the open: every read is bounded by it.
        public let size: Int
        public private(set) var offset = 0
        public var remaining: Int { size - offset }
        let fd: Int32
        let st0: stat
        var hasher: SHA256? = nil

        /// - Parameter admit: the caller's admission on the true size (nil: admitted), asked before any byte.
        public init(_ path: String, admit: ((Int) -> String?)? = nil) throws {
            self.path = path
            if path.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
                throw Refusal.traversal(path: path)
            }
            let fd = try DaemonFile.openJudged(path, directory: false)
            var st = stat()
            guard fstat(fd, &st) == 0 else { let e = errno; close(fd); throw Refusal.io(path: path, call: "fstat", errno: e) }
            guard (st.st_mode & S_IFMT) == S_IFREG else { close(fd); throw Refusal.notRegular(path: path, kind: DaemonFile.kind(st.st_mode)) }
            if let r = DaemonFile.linkRefusal(st, path) { close(fd); throw r }            // one hard link only
            if let r = DaemonFile.outside(fd, path) { close(fd); throw r }
            self.fd = fd
            self.st0 = st
            self.size = Int(st.st_size)
            if let a = admit, let e = a(size) { close(fd); throw Refusal.admission(e) }
        }

        deinit { close(fd) }

        /// The opened file's identity, from the fstat of the descriptor read.
        public var device: UInt64 { UInt64(st0.st_dev) }
        public var inode: UInt64 { UInt64(st0.st_ino) }

        /// Every byte read from here on (the file's first byte included, when called before any read) goes to a SHA-256.
        public func hashFromStart() { if hasher == nil { hasher = SHA256() } }

        /// Exactly `count` bytes at the current offset into `p` (count <= remaining is the caller's check: the
        /// structure's own refusal names a short file before this is asked).
        public func read(into p: UnsafeMutableRawPointer, count: Int) throws {
            precondition(count >= 0 && count <= remaining)
            var got = 0
            while got < count {
                let n = pread(fd, p + got, min(count - got, 1 << 30), off_t(offset + got))
                if n < 0 { if errno == EINTR { continue }; throw Refusal.io(path: path, call: "read", errno: errno) }
                if n == 0 { throw Refusal.cut(path: path, got: offset + got, want: size) }
                got += n
            }
            if hasher != nil { hasher!.update(bufferPointer: UnsafeRawBufferPointer(start: p, count: count)) }
            offset += count
        }

        /// The next `count` bytes as their own Data.
        public func read(_ count: Int) throws -> Data {
            var d = Data(count: count)
            if count > 0 { try d.withUnsafeMutableBytes { try read(into: $0.baseAddress!, count: count) } }
            return d
        }

        /// `count` bytes at the absolute `at`, bounded by st_size (the caller's check, as
        /// `read`'s), as their own Data; the sequential offset and the hash are untouched. The log's windowed
        /// reads; `finish(whole: false)` after them still checks the file unchanged.
        public func readAt(_ at: Int, _ count: Int) throws -> Data {
            precondition(at >= 0 && count >= 0 && at + count <= size)
            var d = Data(count: count)
            guard count > 0 else { return d }
            try d.withUnsafeMutableBytes { try readAt(at, into: $0.baseAddress!, count) }
            return d
        }

        /// `count` bytes at the absolute `at` straight into `p` (no Data of their own): a replayed
        /// split import's chunks land in the file they belong to.
        public func readAt(_ at: Int, into p: UnsafeMutableRawPointer, _ count: Int) throws {
            precondition(at >= 0 && count >= 0 && at + count <= size)
            guard count > 0 else { return }
            do {
                var got = 0
                while got < count {
                    let n = pread(fd, p + got, min(count - got, 1 << 30), off_t(at + got))
                    if n < 0 { if errno == EINTR { continue }; throw Refusal.io(path: path, call: "read", errno: errno) }
                    if n == 0 { throw Refusal.cut(path: path, got: at + got, want: size) }
                    got += n
                }
            }
        }

        /// The rest of the file, through a bounded scratch buffer, into the hash (bytes not decoded).
        public func drain() throws {
            var scratch = Data(count: min(max(remaining, 1), 8 << 20))
            while remaining > 0 {
                let n = min(remaining, scratch.count)
                try scratch.withUnsafeMutableBytes { try read(into: $0.baseAddress!, count: n) }
            }
        }

        /// The fstat after the read: the same file, unchanged (and every byte read when `whole`).
        public func finish(whole: Bool = true) throws {
            if whole && offset != size { try drain() }
            var st = stat()
            guard fstat(fd, &st) == 0 else { throw Refusal.io(path: path, call: "fstat", errno: errno) }
            var what: [String] = []
            if st.st_dev != st0.st_dev || st.st_ino != st0.st_ino { what.append("inode") }
            if st.st_size != st0.st_size { what.append("size \(st0.st_size) -> \(st.st_size)") }
            if st.st_mtimespec.tv_sec != st0.st_mtimespec.tv_sec || st.st_mtimespec.tv_nsec != st0.st_mtimespec.tv_nsec { what.append("mtime") }
            if st.st_ctimespec.tv_sec != st0.st_ctimespec.tv_sec || st.st_ctimespec.tv_nsec != st0.st_ctimespec.tv_nsec { what.append("ctime") }
            if !what.isEmpty { throw Refusal.changed(path: path, what: what.joined(separator: ", ")) }
        }

        /// The SHA-256 of every byte read (after `hashFromStart()` and `finish()`), or nil.
        public func digest() -> [UInt8]? { hasher.map { Array($0.finalize()) } }
    }

    /// The file's bytes under `rule`, read once (the one copy the caller hashes and decodes).
    public static func read(_ path: String, _ rule: Size = .any, admit: ((Int) -> String?)? = nil) throws -> Data {
        let r = try Reader(path, admit: nil)
        switch rule {
        case .any, .prefix: break
        case .exactly(let n):
            if r.size != n { throw Refusal.size(path: path, have: r.size, rule: "the site reads exactly \(n)") }
        case .atMost(let n):
            if r.size > n { throw Refusal.size(path: path, have: r.size, rule: "the site reads at most \(n)") }
        }
        let want: Int
        if case .prefix(let n) = rule { want = min(r.size, n) } else { want = r.size }
        if let a = admit, let e = a(want) { throw Refusal.admission(e) }
        let d = try r.read(want)
        try r.finish(whole: false)
        return d
    }

    /// `read`, but nil for ENOENT alone: every other failure is a refusal (it replaces the `try?` reads).
    public static func readIfPresent(_ path: String, _ rule: Size = .any, admit: ((Int) -> String?)? = nil) throws -> Data? {
        do { return try read(path, rule, admit: admit) } catch Refusal.missing { return nil }
    }

    /// `read`, admitted on the true size through the bound `admission` (the
    /// command's budget; nil: no budget, read as before).
    public static func readAdmitted(_ path: String, _ rule: Size = .any) throws -> Data {
        try read(path, rule, admit: admission.map { a in { a($0, "\(Reply.quoted(path)): the file's \($0) B, read once") } })
    }

    /// The SHA-256 of a file's bytes, streamed through a bounded buffer (no copy of its size).
    public static func digest(_ path: String) throws -> [UInt8] {
        let r = try Reader(path)
        r.hashFromStart()
        try r.finish(whole: true)
        return r.digest()!
    }

    /// The file's size by fstat of a non-blocking open of a regular, contained file (never lstat: a link is
    /// charged its target's size, not its own); nil for ENOENT.
    public static func sizeIfPresent(_ path: String) throws -> Int? {
        do { return try Reader(path).size } catch Refusal.missing { return nil }
    }

    // MARK: - Writes

    // MARK: - Resolution

    /// The most links one resolution follows (the kernel's own limit, MAXSYMLINKS).
    static let maxLinks = 32

    /// Where a name stands against the root: on the way to it (one of the root's own ancestors), inside it (the
    /// root included), or elsewhere. No root bound: everything is inside.
    enum Place { case above, inside, elsewhere }

    static func place(_ p: String, _ root: String?) -> Place {
        guard let r = root else { return .inside }
        if inside(p, r) { return .inside }
        if p == "/" || r.utf8.starts(with: (p + "/").utf8) { return .above }
        return .elsewhere
    }

    /// Why a walk stopped before the end of its path.
    enum WalkStop: Error {
        /// The resolution left the root. Nothing found beyond that point is reported.
        case outside
        /// A failure inside the root (or on the root's own ancestors); `at`: the index of the path's own
        /// component being resolved (a link's target counts as the link's component).
        case failed(at: Int, call: String, errno: Int32)
    }

    /// Where a walk ended.
    struct Walked {
        /// The canonical path of what was found (no link in it, unless the last component is a link not
        /// followed), or, when `missing` is not empty, of the deepest existing directory.
        var real: String
        /// lstat of `real`.
        var st: stat
        /// The names not found (ENOENT), in order.
        var missing: [String]
        /// When a link's target was being followed as the name went missing: the index of the link's component
        /// (the link cannot be resolved).
        var dangling: Int?
    }

    /// `path` split on its '/' bytes, empty components kept ("/a/b" -> "", "a", "b").
    static func components(_ path: String) -> [String] {
        path.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The first `i + 1` of the components joined: the path as given up to the one being resolved.
    static func spelled(_ comps: [String], through i: Int) -> String {
        let s = comps.prefix(i + 1).joined(separator: "/")
        return s.isEmpty ? "/" : s
    }

    /// The path's components resolved one by one from "/", as the kernel resolves them: each name lstat'ed under
    /// a directory already resolved, a link replaced by its target (read relative to the link's folder). The walk
    /// stops where the resolution leaves the root (`.outside`): a name under one of the root's ancestors that is
    /// not on the way to the root is looked at only to learn whether it is a link (it may lead back in) or another
    /// spelling of a folder on the way (letter case, Unicode form), and nothing below it is looked up, so what lies
    /// outside never shapes the answer. A failure inside the root, or on its ancestors, is `.failed` with its
    /// errno. A name not found ends the walk with the rest in `missing`. What the walk finds must lie inside the
    /// root: one of the root's own ancestors is outside it too. `followLast`: a link as the last component is
    /// followed (a read), else it is returned as found (a write refuses it).
    static func walk(_ comps: [String], followLast: Bool) throws -> Walked {
        let r = root
        var cur = "/"
        // The names still to resolve, last first; `at`: the path's own component each one stands for.
        var stack: [(name: String, at: Int, link: Bool)] = comps.indices.reversed().map { (comps[$0], $0, false) }
        var links = 0
        while let item = stack.popLast() {
            if item.name.isEmpty || item.name == "." { continue }               // `cur` is a directory
            if item.name == ".." {                                                // a link's target only
                cur = (cur as NSString).deletingLastPathComponent
                continue
            }
            let next = cur == "/" ? "/" + item.name : cur + "/" + item.name
            let pl = place(next, r)
            var st = stat()
            if lstat(next, &st) != 0 {
                let e = errno
                if pl == .elsewhere { throw WalkStop.outside }
                if e == ENOENT {
                    return Walked(real: cur, st: stat(), missing: [item.name] + stack.reversed().map { $0.name },
                                  dangling: item.link ? item.at : nil)
                }
                throw WalkStop.failed(at: item.at, call: "lstat", errno: e)
            }
            switch st.st_mode & S_IFMT {
            case S_IFLNK:
                if stack.isEmpty && !followLast {
                    if pl != .inside { throw WalkStop.outside }                   // a write there lands outside
                    return Walked(real: next, st: st, missing: [], dangling: nil)
                }
                links += 1
                var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
                let n = readlink(next, &buf, Int(MAXPATHLEN))
                let e = errno
                if pl == .elsewhere && (links > maxLinks || n < 0) { throw WalkStop.outside }
                if links > maxLinks { throw WalkStop.failed(at: item.at, call: "realpath", errno: ELOOP) }
                if n < 0 { throw WalkStop.failed(at: item.at, call: "readlink", errno: e) }
                let target = String(decoding: buf.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if target.hasPrefix("/") { cur = "/" }
                for name in components(target).reversed() { stack.append((name, item.at, true)) }
            case S_IFDIR:
                if pl == .elsewhere {
                    // Beside the way to the root: only another spelling of a folder on that way leads on.
                    guard let rp = realpath(next, nil) else { throw WalkStop.outside }
                    let canon = String(cString: rp); free(rp)
                    if place(canon, r) == .elsewhere { throw WalkStop.outside }
                    cur = canon
                } else {
                    cur = next
                }
            default:
                if pl == .elsewhere { throw WalkStop.outside }
                if let nx = stack.last { throw WalkStop.failed(at: nx.at, call: "lstat", errno: ENOTDIR) }   // a name under a file
                if pl != .inside { throw WalkStop.outside }
                return Walked(real: next, st: st, missing: [], dangling: nil)
            }
        }
        // The path ends at a folder. One of the root's own ancestors ("/", the root's parent, a link to "..") is on
        // the way to the root but not inside it.
        if place(cur, r) != .inside { throw WalkStop.outside }
        var st = stat()
        if lstat(cur, &st) != 0 { throw WalkStop.failed(at: comps.count - 1, call: "lstat", errno: errno) }
        return Walked(real: cur, st: st, missing: [], dangling: nil)
    }

    /// `path` standardized and made absolute (relative to the working directory), as the writers name it. Only for
    /// a path `forWrite` has measured: standardizingPath keeps the first 1024 UTF-16 units of a longer string.
    static func standardized(_ path: String) -> String {
        let std = (path as NSString).standardizingPath
        return std.hasPrefix("/") ? std : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(std)
    }

    /// The refusal for a walk that stopped: outside the root, the one text (no outside path, nothing found
    /// there); inside, the errno and the path as given up to the component that failed.
    static func refusal(_ stop: WalkStop, path: String, comps: [String]) -> Refusal {
        switch stop {
        case .outside: return .outsideRoot(path: path)
        case let .failed(at, call, e): return .io(path: spelled(comps, through: at), call: call, errno: e)
        }
    }

    // MARK: - Writes

    /// The canonical path for a file the daemon writes, or a directory it writes into: the path resolved name by
    /// name (`walk`) down to its deepest existing folder, the missing tail appended; a '..' segment, and a path
    /// too long, refused; the final component refused when it is a symbolic link, or a regular file with more
    /// than one hard link;
    /// contained in the bound root, which the walk never leaves. Only ENOENT means "not created yet": any other
    /// failure, and a link whose target is missing, refuses by name. Every later call on the result uses
    /// O_NOFOLLOW_ANY, so a link swapped in after this check fails the call (ELOOP); a hard link made after it is
    /// caught by the open's fstat.
    public static func forWrite(_ path: String) throws -> String {
        if path.split(separator: "/", omittingEmptySubsequences: false).contains("..") { throw Refusal.traversal(path: path) }
        // A path too long is refused by name before it is standardized, measured as given (after the working
        // directory when it is relative), as a read measures it: standardizingPath silently keeps the first 1024
        // UTF-16 units of a longer string, and that prefix names another file. Bytes are the system's limit, UTF-16
        // units the cut's; a path under the first is under the second too, and both are counted.
        let given = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        if given.utf8.count >= Int(MAXPATHLEN) || given.utf16.count >= Int(MAXPATHLEN) {
            throw Refusal.io(path: path, call: "lstat", errno: ENAMETOOLONG)
        }
        let std = standardized(path)
        // Standardizing can lengthen a path ('~' becomes the home folder). No call can open a path this long (the
        // kernel refuses it); the walk, which resolves name by name, must not call it contained.
        if std.utf8.count >= Int(MAXPATHLEN) { throw Refusal.io(path: path, call: "lstat", errno: ENAMETOOLONG) }
        let comps = components(std)
        let w: Walked
        do { w = try walk(comps, followLast: false) } catch let s as WalkStop { throw refusal(s, path: path, comps: comps) }
        if w.missing.isEmpty {
            if (w.st.st_mode & S_IFMT) == S_IFLNK { throw Refusal.link(path: path) }
            if let r = linkRefusal(w.st, path) { throw r }                         // one hard link only
        }
        if let at = w.dangling { throw Refusal.io(path: spelled(comps, through: at), call: "realpath", errno: ENOENT) }
        // What exists in its own spelling (letter case, Unicode form), as realpath gives it: the walk keeps the
        // spelling it was given, and the daemon's live files (the log, its sidecar) are known by their own.
        // `w.real` holds no link here, so realpath changes nothing else.
        guard let rp = realpath(w.real, nil) else { throw Refusal.io(path: spelled(comps, through: comps.count - 1 - w.missing.count), call: "realpath", errno: errno) }
        let found = String(cString: rp); free(rp)
        let c = w.missing.isEmpty ? found : ([found == "/" ? "" : found] + w.missing).joined(separator: "/")
        if let r = root, !inside(c, r) { throw Refusal.outsideRoot(path: path) }
        return c
    }

    /// The containment check alone, for a path a verb names (nil: contained, or no root bound). Nothing passes
    /// unless containment was established: a failure to find out is a refusal.
    public static func containmentRefusal(_ path: String) -> Refusal? {
        do { _ = try forWrite(path); return nil } catch let r as Refusal {
            if case .link = r {
                // A verb may name a link (a read follows it): the link followed by the same walk. A link that
                // cannot be resolved (its target missing, a name too long, too many links) is refused.
                let comps = components(standardized(path))
                do {
                    let w = try walk(comps, followLast: true)
                    if let at = w.dangling { return .io(path: spelled(comps, through: at), call: "realpath", errno: ENOENT) }
                    return nil
                } catch let s as WalkStop {
                    return refusal(s, path: path, comps: comps)
                } catch {
                    return .io(path: path, call: "the containment check", errno: EIO)
                }
            }
            return r
        } catch {
            // forWrite throws only refusals; anything else is still not a containment proof.
            return .io(path: path, call: "the containment check", errno: EIO)
        }
    }

    /// open(2) for writing at a canonical path: O_WRONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY, the
    /// flags asked; refused unless the descriptor is a regular file (a FIFO answers ENXIO or is refused by
    /// fstat, a directory EISDIR, any link ELOOP) with one hard link (the fstat after the open, so a
    /// link made after any earlier check is caught before a byte is written); contained by F_GETPATH.
    /// There is no O_TRUNC here; a writer that replaces a file writes a new one
    /// (`createTemporary`, `atomicWrite`) and renames it over the name.
    /// One of the daemon's live files is refused by name before the open, unless the caller
    /// is its owner (`own`: the log's appender, the era writer).
    public static func openForWrite(_ c: String, create: Bool = true,
                                    exclusive: Bool = false, append: Bool = false, mode: mode_t = 0o644,
                                    own: Bool = false) throws -> Int32 {
        if !own, let r = reservedRefusal(c) { throw r }
        var flags = O_WRONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY
        if create { flags |= O_CREAT }
        if exclusive { flags |= O_EXCL }
        if append { flags |= O_APPEND }
        let fd = open(c, flags, mode)
        guard fd >= 0 else {
            let e = errno
            switch e {
            case ENOENT: throw Refusal.missing(path: c)
            case ELOOP: throw Refusal.link(path: c)
            case EISDIR: throw Refusal.notRegular(path: c, kind: "directory")
            case ENXIO: throw Refusal.notRegular(path: c, kind: "fifo")
            default: throw Refusal.io(path: c, call: "open", errno: e)
            }
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else { let e = errno; close(fd); throw Refusal.io(path: c, call: "fstat", errno: e) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { close(fd); throw Refusal.notRegular(path: c, kind: kind(st.st_mode)) }
        if let r = linkRefusal(st, c) { close(fd); throw r }                            // one hard link only
        if let r = outside(fd, c) { close(fd); throw r }
        // A regular file: blocking I/O from here (O_NONBLOCK only kept the open from waiting on a FIFO).
        let fl = fcntl(fd, F_GETFL)
        if fl >= 0 { _ = fcntl(fd, F_SETFL, fl & ~O_NONBLOCK) }
        return fd
    }

    /// An existing file opened read-write in place (a header rewrite), under the same rules.
    public static func openForUpdate(_ c: String) throws -> Int32 {
        let fd = open(c, O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else {
            let e = errno
            if e == ENOENT { throw Refusal.missing(path: c) }
            if e == ELOOP { throw Refusal.link(path: c) }
            if e == EISDIR { throw Refusal.notRegular(path: c, kind: "directory") }
            if e == ENXIO { throw Refusal.notRegular(path: c, kind: "fifo") }
            throw Refusal.io(path: c, call: "open", errno: e)
        }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { close(fd); throw Refusal.notRegular(path: c, kind: kind(st.st_mode)) }
        if let r = linkRefusal(st, c) { close(fd); throw r }                            // one hard link only
        if let r = outside(fd, c) { close(fd); throw r }
        let fl = fcntl(fd, F_GETFL)
        if fl >= 0 { _ = fcntl(fd, F_SETFL, fl & ~O_NONBLOCK) }
        return fd
    }

    /// Every byte of `p[0..<count]` written at the descriptor's offset, in chunks a write(2) can carry.
    public static func writeAll(_ fd: Int32, _ p: UnsafeRawPointer, _ count: Int, path: String) throws {
        var done = 0
        while done < count {
            let n = write(fd, p + done, min(count - done, 1 << 30))
            if n < 0 { if errno == EINTR { continue }; throw Refusal.io(path: path, call: "write", errno: errno) }
            if n == 0 { throw Refusal.io(path: path, call: "write", errno: EIO) }
            done += n
        }
    }

    public static func writeAll(_ fd: Int32, _ d: Data, path: String) throws {
        if d.isEmpty { return }
        try d.withUnsafeBytes { try writeAll(fd, $0.baseAddress!, d.count, path: path) }
    }

    /// A writer's temporary at a canonical path, always a NEW file: O_CREAT |
    /// O_EXCL, no link followed, so no existing inode is ever opened, truncated or written. What is at the name
    /// first: a regular file with one link is unlinked, its name only; a regular file with more than one link is
    /// refused by name (`.linked`); a symbolic link, a directory, a FIFO or any other kind is refused by name; a
    /// name taken again between the unlink and the create is refused (EEXIST). The name is
    /// `tmpName(for:)`'s marked one (SAVE and the tiled writer once used `<path>.tmp`), so what can be at it is
    /// only this daemon's own (a recycled pid's leftover) or a planted file, which O_EXCL refuses by name.
    public static func createTemporary(_ c: String, mode: mode_t = 0o644) throws -> Int32 {
        if let r = reservedRefusal(c) { throw r }                                       // not one of the daemon's live files
        var st = stat()
        if lstat(c, &st) == 0 {
            switch st.st_mode & S_IFMT {
            case S_IFREG:
                if let r = linkRefusal(st, c) { throw r }
                let e = unlinkNoFollow(c)
                if e != 0 && e != ENOENT { throw Refusal.io(path: c, call: "unlink", errno: e) }
            case S_IFLNK: throw Refusal.link(path: c)
            case S_IFDIR: throw Refusal.notRegular(path: c, kind: "directory")
            default: throw Refusal.notRegular(path: c, kind: kind(st.st_mode))
            }
        }
        return try openForWrite(c, create: true, exclusive: true, mode: mode)
    }

    private static var tmpSerial = 0
    private static let tmpLock = NSLock()

    /// The hidden temporary name every writer of the daemon uses beside `c`: `.<name>.dagdb-tmp-<pid>-<n>`, the
    /// marker the stage sweep removes by (every temporary carries it; SAVE and the tiled writer once used
    /// `<path>.tmp`, which the sweep leaves in place).
    public static func tmpName(for c: String) -> String {
        tmpLock.lock(); tmpSerial += 1; let n = tmpSerial; tmpLock.unlock()
        let dir = (c as NSString).deletingLastPathComponent, name = (c as NSString).lastPathComponent
        return dir + "/." + name + ".dagdb-tmp-\(getpid())-\(n)"
    }

    /// The temporaries a writer of `c` left beside it, by the marked name (and the
    /// `<path>.tmp` an older build's writer used); names only, nothing opened.
    public static func leftoverTemporaries(of c: String) -> [String] {
        let dir = (c as NSString).deletingLastPathComponent, name = (c as NSString).lastPathComponent
        var out = (try? listDirectory(dir))?.filter { $0.hasPrefix("." + name + ".dagdb-tmp-") }.map { dir + "/" + $0 } ?? []
        if lkind(c + ".tmp") != nil { out.append(c + ".tmp") }
        return out
    }

    /// `data` to `path` whole or not at all: a hidden temporary beside it (created exclusively, no link
    /// followed), written, F_FULLFSYNC'd when `sync`, renamed over the target (RENAME_NOFOLLOW_ANY), and the
    /// directory synced. A failure removes the temporary and leaves the target as it was.
    public static func atomicWrite(_ data: Data, to path: String, sync: Bool = true) throws {
        let c = try forWrite(path)
        // The target is nothing or a regular single-link file that is not one of the daemon's live files;
        // asked again just before the rename.
        if let r = renameTargetRefusal(c) { throw r }
        let tmp = tmpName(for: c)
        let fd = try openForWrite(tmp, create: true, exclusive: true, mode: 0o644)
        do {
            try writeAll(fd, data, path: tmp)
            if sync { _ = fcntl(fd, F_FULLFSYNC) }
        } catch {
            close(fd); _ = unlinkNoFollow(tmp); throw error
        }
        close(fd)
        if let r = renameTargetRefusal(c) { _ = unlinkNoFollow(tmp); throw r }
        if renamex_np(tmp, c, UInt32(RENAME_NOFOLLOW_ANY)) != 0 {
            let e = errno
            _ = unlinkNoFollow(tmp)
            throw Refusal.io(path: c, call: "rename", errno: e)
        }
        if sync { syncDirectory((c as NSString).deletingLastPathComponent) }
    }

    /// rename(2) of two canonical paths, no link followed in either; 0 or the errno.
    @discardableResult
    public static func renameNoFollow(_ from: String, _ to: String) -> Int32 {
        renamex_np(from, to, UInt32(RENAME_NOFOLLOW_ANY)) == 0 ? 0 : errno
    }

    /// The parent of a canonical path opened as a directory, no link followed (-1 and errno on failure).
    static func openParent(_ c: String) -> Int32 {
        open((c as NSString).deletingLastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
    }

    /// unlink(2) of a canonical path through its parent's descriptor (the entry itself, never a link's
    /// target; no link followed above it); 0 or the errno.
    @discardableResult
    public static func unlinkNoFollow(_ c: String) -> Int32 {
        let dfd = openParent(c)
        guard dfd >= 0 else { return errno }
        defer { close(dfd) }
        return unlinkat(dfd, (c as NSString).lastPathComponent, 0) == 0 ? 0 : errno
    }

    /// rmdir(2) of an empty directory, the same way; 0 or the errno.
    @discardableResult
    public static func rmdirNoFollow(_ c: String) -> Int32 {
        let dfd = openParent(c)
        guard dfd >= 0 else { return errno }
        defer { close(dfd) }
        return unlinkat(dfd, (c as NSString).lastPathComponent, AT_REMOVEDIR) == 0 ? 0 : errno
    }

    /// One directory created at a canonical path (its parent opened with no link followed); 0 or the errno.
    @discardableResult
    public static func mkdirNoFollow(_ c: String, mode: mode_t = 0o755) -> Int32 {
        let dfd = openParent(c)
        guard dfd >= 0 else { return errno }
        defer { close(dfd) }
        return mkdirat(dfd, (c as NSString).lastPathComponent, mode) == 0 ? 0 : errno
    }

    /// `dir` and its missing ancestors created (contained, no link followed); returns the canonical ones
    /// created, shallowest first.
    public static func makeDirectories(_ dir: String) throws -> [String] {
        let c = try forWrite(dir)
        var missing: [String] = []
        var p = c
        var st = stat()
        while p != "/" && lstat(p, &st) != 0 {
            missing.append(p)
            p = (p as NSString).deletingLastPathComponent
        }
        if p != "/" || missing.isEmpty {
            if (st.st_mode & S_IFMT) == S_IFLNK { throw Refusal.link(path: p) }
            if (st.st_mode & S_IFMT) != S_IFDIR {
                throw Refusal.io(path: p, call: "mkdir", errno: ENOTDIR)
            }
        }
        missing.reverse()
        for d in missing {
            let e = mkdirNoFollow(d)
            if e != 0 && e != EEXIST { throw Refusal.io(path: d, call: "mkdir", errno: e) }
        }
        return missing
    }

    /// F_FULLFSYNC of a directory (best effort, as the writers did before: the rename is already done).
    public static func syncDirectory(_ c: String) {
        let fd = open(c, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC); close(fd) }
    }

    /// F_FULLFSYNC of a regular file at a canonical path (best effort).
    public static func syncFile(_ c: String) {
        let fd = open(c, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }
        var st = stat()
        if fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { _ = fcntl(fd, F_FULLFSYNC) }
        close(fd)
    }

    /// lstat's file type at a path ("regular file", "directory", "symbolic link", ...), or nil when absent.
    public static func lkind(_ c: String) -> String? {
        var st = stat()
        guard lstat(c, &st) == 0 else { return nil }
        return kind(st.st_mode)
    }

    /// A directory tree removed through descriptors (openat / unlinkat, never following a link: a link
    /// inside it is removed, not its target). Returns nil, or what could not be removed.
    @discardableResult
    public static func removeTree(_ c: String) -> String? {
        var st = stat()
        guard lstat(c, &st) == 0 else { return nil }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            let e = unlinkNoFollow(c)
            return e == 0 ? nil : "\(c) (unlink \(errnoName(e)))"
        }
        let dfd = open(c, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard dfd >= 0 else { return "\(c) (open \(errnoName(errno)))" }
        var left: [String] = []
        removeContents(dfd, c, &left)
        close(dfd)
        let e = rmdirNoFollow(c)
        if e != 0 { left.append("\(c) (rmdir \(errnoName(e)))") }
        return left.isEmpty ? nil : left.joined(separator: ", ")
    }

    private static func removeContents(_ dfd: Int32, _ c: String, _ left: inout [String]) {
        let dup = dup(dfd)
        guard dup >= 0, let dir = fdopendir(dup) else { left.append("\(c) (fdopendir \(errnoName(errno)))"); return }
        defer { closedir(dir) }
        var names: [String] = []
        while let e = readdir(dir) {
            let name = withUnsafePointer(to: e.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        for name in names {
            var st = stat()
            guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                let sub = openat(dfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if sub >= 0 { removeContents(sub, c + "/" + name, &left); close(sub) }
                if unlinkat(dfd, name, AT_REMOVEDIR) != 0 { left.append("\(c)/\(name) (rmdir \(errnoName(errno)))") }
            } else if unlinkat(dfd, name, 0) != 0 {
                left.append("\(c)/\(name) (unlink \(errnoName(errno)))")
            }
        }
    }

    /// The names in a directory (a listing; nothing in it opened), sorted; a refusal by name when it is not one.
    /// The directory is judged before it is opened (`openJudged`), and its descriptor's path checked after.
    public static func listDirectory(_ path: String) throws -> [String] {
        let fd = try openJudged(path, directory: true)
        if let r = outside(fd, path) { close(fd); throw r }
        guard let dir = fdopendir(fd) else { let e = errno; close(fd); throw Refusal.io(path: path, call: "fdopendir", errno: e) }
        defer { closedir(dir) }
        var names: [String] = []
        while let e = readdir(dir) {
            let name = withUnsafePointer(to: e.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }
}
