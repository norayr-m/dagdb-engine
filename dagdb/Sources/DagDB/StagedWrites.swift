import Foundation

/// A multi-file writer stages its files and renames them into place, so its
/// visible outputs appear all at once or not at all. Written file after file
/// into the target, a failure part-way (a full disk, a name taken by a
/// directory) would answer ERROR over a mixed old/new set.
///
/// `StagedFileSet` (SAVE CSV, EXPORT MORTON): the files are written into a
/// hidden directory inside the target, every target name is checked, then
/// each file is renamed over its name. A refusal before the first rename
/// leaves the target as it was (the stage, and any directory this writer
/// created, are removed). Only the rename loop can still fail part-way, and
/// that residual is named: `StagedWriteError.partial` lists the files replaced.
struct StagedFileSet {
    let target: String
    let stage: String
    /// Directories this writer created (the target and missing ancestors),
    /// shallowest first; removed on abort when they are still empty.
    let created: [String]

    private static var serial = 0
    private static let lock = NSLock()

    /// The target resolved to its canonical path inside the root (the deepest existing
    /// ancestor by realpath, no link as its last component), and every directory, file and rename below made
    /// on it with no link followed.
    static func begin(target: String) throws -> StagedFileSet {
        let target = try DaemonFile.forWrite(target)
        let created = try createMissingDirectories(target)
        lock.lock(); serial += 1; let n = serial; lock.unlock()
        let stage = target + "/" + stagePrefix + "\(getpid())-\(n)"
        let e = DaemonFile.mkdirNoFollow(stage)
        if e != 0 {
            removeEmptyDirectories(created)
            throw DaemonFile.Refusal.io(path: stage, call: "mkdir", errno: e)
        }
        return StagedFileSet(target: target, stage: stage, created: created)
    }

    /// The stage directory's name prefix (the start-up sweep's pattern).
    static let stagePrefix = ".dagdb-stage-"

    func path(_ name: String) -> String { stage + "/" + name }

    /// Every target name checked, then the renames, in `names` order (a
    /// writer's version marker goes last). Throws `.refused` with nothing
    /// replaced, or `.partial` naming what was.
    func commit(_ names: [String]) throws {
        for name in names {
            if let why = StagedWriteError.blocker(target + "/" + name) {
                throw StagedWriteError.refused(why)
            }
        }
        var replaced: [String] = []
        for name in names {
            let e = DaemonFile.renameNoFollow(path(name), target + "/" + name)
            if e != 0 {
                let why = "rename \(Reply.pathWords(path(name))) -> \(Reply.quoted(target + "/" + name)): \(Reply.errnoWords(e))"
                if replaced.isEmpty { throw StagedWriteError.refused(why) }
                throw StagedWriteError.partial(replaced: replaced, failed: name, why: why)
            }
            replaced.append(name)
        }
        DaemonFile.syncDirectory(target)
        DaemonFile.rmdirNoFollow(stage)
    }

    /// The stage removed (with what it holds) and the directories this writer
    /// created, when empty. Returns what could not be removed, or nil.
    @discardableResult
    func abort() -> String? {
        var left: [String] = []
        if let l = DaemonFile.removeTree(stage) { left.append(l) }
        left += StagedFileSet.removeEmptyDirectories(created)
        return left.isEmpty ? nil : left.joined(separator: ", ")
    }

    /// Create `dir` and its missing ancestors; returns the ones created,
    /// shallowest first. Contained, canonical, no link followed (`DaemonFile.makeDirectories`).
    static func createMissingDirectories(_ dir: String) throws -> [String] {
        try DaemonFile.makeDirectories(dir)
    }

    /// rmdir each, deepest first; returns the ones still there that are empty
    /// and could not be removed (a non-empty one holds files a commit landed).
    @discardableResult
    static func removeEmptyDirectories(_ dirs: [String]) -> [String] {
        var left: [String] = []
        for d in dirs.reversed() {
            let e = DaemonFile.rmdirNoFollow(d)
            if e != 0, e != ENOTEMPTY, e != ENOENT, e != EEXIST {
                left.append("\(d) (rmdir errno=\(e))")
            }
        }
        return left
    }
}

/// SAVE TILED's world directory is written whole into a
/// sibling stage and swapped in: renamed into place when the world is new;
/// over an existing world, the old directory is renamed aside, the stage
/// renamed into place (on failure the old one is renamed back), then the old
/// one removed. A refusal before the swap leaves the world as it was.
struct StagedDirectorySwap {
    let final: String
    let stage: String
    let created: [String]

    private static var serial = 0
    private static let lock = NSLock()

    static func begin(final: String) throws -> StagedDirectorySwap {
        let final = try DaemonFile.forWrite(final)                     // canonical, contained
        // A swap moves the old world aside and removes it, with whatever is in
        // it; a live file of the daemon inside (its WAL, say) is refused by name before anything is written.
        if let r = DaemonFile.reservedInside(final) { throw StagedWriteError.refused("\(Reply.errorWords(r))") }
        let parent = (final as NSString).deletingLastPathComponent
        let name = (final as NSString).lastPathComponent
        let created = try StagedFileSet.createMissingDirectories(parent)
        lock.lock(); serial += 1; let n = serial; lock.unlock()
        let stage = parent + "/.\(name)" + StagedFileSet.stagePrefix + "\(getpid())-\(n)"
        let e = DaemonFile.mkdirNoFollow(stage)
        if e != 0 {
            StagedFileSet.removeEmptyDirectories(created)
            throw DaemonFile.Refusal.io(path: stage, call: "mkdir", errno: e)
        }
        return StagedDirectorySwap(final: final, stage: stage, created: created)
    }

    /// Returns nil, or the name of an old copy that could not be removed
    /// after the new world landed (the OK reply names it).
    func commit() throws -> String? {
        let kind = DaemonFile.lkind(final)
        let exists = kind != nil
        if exists && kind != "directory" {
            throw StagedWriteError.refused("\(final) is a \(kind!), not a world directory")
        }
        if !exists {
            let e = DaemonFile.renameNoFollow(stage, final)
            guard e == 0 else {
                throw StagedWriteError.refused("rename \(Reply.pathWords(stage)) -> \(Reply.quoted(final)): \(Reply.errnoWords(e))")
            }
            fsyncDir((final as NSString).deletingLastPathComponent)
            return nil
        }
        let old = stage + ".old"
        let e0 = DaemonFile.renameNoFollow(final, old)
        guard e0 == 0 else {
            throw StagedWriteError.refused("rename \(Reply.quoted(final)) -> \(Reply.quoted(old)): \(Reply.errnoWords(e0))")
        }
        let e1 = DaemonFile.renameNoFollow(stage, final)
        guard e1 == 0 else {
            let e = e1
            let why = "rename \(Reply.pathWords(stage)) -> \(Reply.quoted(final)): \(Reply.errnoWords(e))"
            let e2 = DaemonFile.renameNoFollow(old, final)
            if e2 == 0 {
                throw StagedWriteError.refused(why)
            }
            throw StagedWriteError.partial(
                replaced: [], failed: (final as NSString).lastPathComponent,
                why: "\(why); the old world was moved to \(old) and could not be moved back (errno=\(e2)): \(final) is absent")
        }
        fsyncDir((final as NSString).deletingLastPathComponent)
        if let left = DaemonFile.removeTree(old) { return left }
        return nil
    }

    @discardableResult
    func abort() -> String? {
        var left: [String] = []
        if let l = DaemonFile.removeTree(stage) { left.append(l) }
        left += StagedFileSet.removeEmptyDirectories(created)
        return left.isEmpty ? nil : left.joined(separator: ", ")
    }

    private func fsyncDir(_ d: String) { DaemonFile.syncDirectory(d) }
}

public enum StagedWriteError: Error, CustomStringConvertible {
    /// Nothing in the target was replaced.
    case refused(String)
    /// The rename loop failed after `replaced` landed (class (c): named).
    case partial(replaced: [String], failed: String, why: String)

    public var description: String {
        switch self {
        case .refused(let why):
            return "\(why); nothing replaced"
        case .partial(let replaced, let failed, let why):
            return "\(why); \(replaced.count) file(s) already replaced (\(replaced.joined(separator: ", "))), "
                + "\(failed) and the rest not: the directory holds a mixed set"
        }
    }

    /// A name a rename cannot replace: a directory, or an immutable or
    /// append-only file; or a regular file with more than one hard link,
    /// refused by name. nil when the name is free or a replaceable file.
    /// Also a name that is one of the daemon's live files (the WAL, its era
    /// sidecar, the socket, the --shm-file), or anything but a regular file (a socket, a FIFO, a device,
    /// a symbolic link), refused by name.
    static func blocker(_ path: String) -> String? {
        if let r = DaemonFile.reservedRefusal(path) { return "\(Reply.errorWords(r))" }
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        if (st.st_mode & S_IFMT) == S_IFDIR { return "\(path) is a directory" }
        if let r = DaemonFile.linkRefusal(st, path) { return "\(Reply.errorWords(r))" }
        if (st.st_mode & S_IFMT) == S_IFLNK { return "\(DaemonFile.Refusal.link(path: path))" }
        if (st.st_mode & S_IFMT) != S_IFREG {
            return "\(DaemonFile.Refusal.notRegular(path: path, kind: DaemonFile.kind(st.st_mode)))"
        }
        let flags = UInt32(st.st_flags)
        let stuck = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)
        if flags & stuck != 0 { return "\(path) is immutable or append-only (flags 0x\(String(flags, radix: 16)))" }
        return nil
    }
}
