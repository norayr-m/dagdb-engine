import Foundation
import DagDB

/// Stale stage directories and
/// temporaries the daemon's own writers leave after a crash, swept at start, by name pattern, under the data
/// root only, and named at boot. Without the sweep they stayed (a crash inside SAVE CSV, EXPORT
/// MORTON or SAVE TILED left its hidden stage; a crash inside SAVE left `<path>.tmp`).
extension DagDBStartup {
    /// The first pair of configured files that name one file, by their flags, or
    /// nil. Each path is resolved by its canonical path (the parent's realpath, the name), by its full realpath
    /// when it exists, and by its device and inode when it exists (a hard link names the same file); a pair in
    /// `allowed` (unordered) may share a file. Asked before any startup write.
    public static func configuredPathCollision(_ entries: [(label: String, path: String?)],
                                               allowed: [Set<String>] = []) -> String? {
        func keys(_ p: String) -> Set<String> {
            var k: Set<String> = ["path:" + DaemonFile.canonicalPath(p)]
            let std = (p as NSString).standardizingPath
            if let rp = realpath(std, nil) { k.insert("path:" + String(cString: rp)); free(rp) }
            var st = stat()
            if stat(std, &st) == 0 { k.insert("inode:\(st.st_dev):\(st.st_ino)") }
            return k
        }
        let present = entries.compactMap { e in e.path.flatMap { $0.isEmpty ? nil : (e.label, $0, keys($0)) } }
        for i in present.indices {
            for j in present.indices where j > i {
                let (la, pa, ka) = present[i], (lb, pb, kb) = present[j]
                if allowed.contains([la, lb]) { continue }
                if !ka.isDisjoint(with: kb) {
                    return "\(la) ('\(pa)') and \(lb) ('\(pb)') name one file; each of the daemon's files must be its own"
                }
            }
        }
        return nil
    }

    /// What the sweep takes (each the name a writer of this daemon gives, never anything else):
    /// - a directory `.dagdb-stage-<pid>-<n>` (SAVE CSV's and EXPORT MORTON's stage, inside the target);
    /// - a directory `.<world>.dagdb-stage-<pid>-<n>` and its `.old` (SAVE TILED's stage and the previous
    ///   world moved aside), only when `<world>` itself is there: when it is not (a crash between SAVE
    ///   TILED's two renames), they are kept and named, since one of them is the only copy;
    /// - a file `.<name>.dagdb-tmp-<pid>-<n>` (every temporary the daemon creates).
    /// Kept and named: anything whose writer pid is alive (another daemon on this root).
    ///
    /// (a) `live` first: the daemon's configured files (the WAL, its era
    /// sidecar, the startup snapshot, the autosave target, the socket, the --shm-file), each by its canonical
    /// path and by what it resolves to; nothing in that set, and no stage holding one, is ever removed, whatever
    /// its name. (b) Only names carrying the daemon's own marker (`.dagdb-stage-` / `.dagdb-tmp-`) are removed:
    /// a generic `<name>.tmp` an older build left (a snapshot, a tile's `meta.json.tmp`, `manifest.json.tmp`,
    /// `halo_lower.<k>.bin.tmp`, an era sidecar's `*.hook1_era.tmp`), which an earlier sweep removed by pattern
    /// (a WAL named meta.json.tmp went with it), is left in place and named as a leftover. Links are never
    /// followed and never descended into. The walk stops at `limit` entries and says so.
    public static func sweepStages(root: String?, live: [String] = [], now: Date = Date(), limit: Int = 1_000_000) -> String {
        guard let root = DaemonFile.canonicalRoot(root) else {
            return "Stage sweep: no data root (DAGDB_DATA_ROOT unset), nothing swept"
        }
        var removed: [String] = [], kept: [String] = [], failed: [String] = [], leftovers: [String] = []
        var visited = 0
        // (a) the live set: each configured file by its canonical path and by its full resolution.
        var liveSet = Set<String>()
        for p in live where !p.isEmpty {
            liveSet.insert(DaemonFile.canonicalPath(p))
            if let rp = realpath((p as NSString).standardizingPath, nil) { liveSet.insert(String(cString: rp)); free(rp) }
        }
        func isLive(_ p: String) -> Bool { liveSet.contains(p) }
        func holdsLive(_ dir: String) -> Bool { liveSet.contains { $0.hasPrefix(dir + "/") } }
        var truncated = false

        func pidAlive(_ name: String) -> Int32? {
            // ...stage-<pid>-<n>[.old] / ...tmp-<pid>-<n>
            var parts = name.split(separator: "-")
            if parts.last.map({ $0.hasSuffix(".old") }) == true { parts[parts.count - 1] = parts.last!.dropLast(4) }
            guard parts.count >= 2, let pid = Int32(parts[parts.count - 2]), Int(parts[parts.count - 1]) != nil else { return nil }
            if pid == getpid() { return nil }
            return kill(pid, 0) == 0 || errno == EPERM ? pid : nil
        }
        func isStageName(_ n: String) -> Bool {
            guard let r = n.range(of: ".dagdb-stage-") else { return false }
            var tail = String(n[r.upperBound...])
            if tail.hasSuffix(".old") { tail.removeLast(4) }
            let p = tail.split(separator: "-")
            return p.count == 2 && Int(p[0]) != nil && Int(p[1]) != nil
        }
        func worldOf(_ n: String) -> String? {
            // ".<world>.dagdb-stage-..." -> "<world>"; nil for the in-target stage
            guard n.hasPrefix("."), let r = n.range(of: ".dagdb-stage-"), r.lowerBound > n.index(after: n.startIndex) else { return nil }
            return String(n[n.index(after: n.startIndex)..<r.lowerBound])
        }
        func isTmpName(_ n: String) -> Bool {
            guard n.hasPrefix("."), let r = n.range(of: ".dagdb-tmp-") else { return false }
            let p = n[r.upperBound...].split(separator: "-")
            return p.count == 2 && Int(p[0]) != nil && Int(p[1]) != nil
        }
        func isOwnTmp(_ path: String, _ n: String) -> Bool {
            guard n.hasSuffix(".tmp") else { return false }
            if n == "meta.json.tmp" || n == "manifest.json.tmp" || n.hasSuffix(DagDBHOOK1Era.suffix + ".tmp") { return true }
            if n.hasPrefix("halo_lower."), n.hasSuffix(".bin.tmp") { return true }
            guard let head = try? DaemonFile.read(path, .prefix(4)) else { return false }
            return [UInt8](head) == DagDBSnapshot.magic
        }
        func rel(_ p: String) -> String { p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : p }

        func walk(_ dir: String, depth: Int) {
            guard depth < 64, !truncated else { return }
            guard let names = try? DaemonFile.listDirectory(dir) else { return }
            for n in names {
                visited += 1
                if visited > limit { truncated = true; return }
                let p = dir + "/" + n
                var st = stat()
                guard lstat(p, &st) == 0 else { continue }
                let type = st.st_mode & S_IFMT
                if type == S_IFLNK { continue }
                if isLive(p) {
                    if isStageName(n) || isTmpName(n) { kept.append("\(rel(p)) (a live file of this daemon)") }
                    continue
                }
                if type == S_IFDIR {
                    if isStageName(n) {
                        if holdsLive(p) { kept.append("\(rel(p)) (it holds a live file of this daemon)"); continue }
                        if let pid = pidAlive(n) { kept.append("\(rel(p)) (its writer, pid \(pid), is alive)"); continue }
                        if let w = worldOf(n), DaemonFile.lkind(dir + "/" + w) == nil {
                            kept.append("\(rel(p)) (the world \(w) is absent: a crash between SAVE TILED's renames; one of its copies is the only one, move it into place)")
                            continue
                        }
                        if let left = DaemonFile.removeTree(p) { failed.append(left) } else { removed.append(rel(p)) }
                        continue
                    }
                    walk(p, depth: depth + 1)
                    continue
                }
                guard type == S_IFREG else { continue }
                if isTmpName(n) {
                    if let pid = pidAlive(n) { kept.append("\(rel(p)) (its writer, pid \(pid), is alive)"); continue }
                } else {
                    // (b) no marker: never removed; a name an older build's writers used is named as a leftover.
                    if isOwnTmp(p, n) { leftovers.append(rel(p)) }
                    continue
                }
                let e = DaemonFile.unlinkNoFollow(p)
                if e == 0 { removed.append(rel(p)) } else { failed.append("\(rel(p)) (unlink \(DaemonFile.errnoName(e)))") }
            }
        }
        DaemonFile.withRoot(root) { walk(root, depth: 0) }

        func list(_ xs: [String]) -> String {
            xs.prefix(8).joined(separator: ", ") + (xs.count > 8 ? ", and \(xs.count - 8) more" : "")
        }
        var line = "Stage sweep under \(root): "
        if removed.isEmpty && kept.isEmpty && failed.isEmpty && leftovers.isEmpty {
            line += "nothing stale (\(visited) entries looked at)"
        } else {
            line += "removed \(removed.count) stale stage item(s) a crashed writer left" + (removed.isEmpty ? "" : " (\(list(removed)))")
            if !kept.isEmpty { line += "; kept \(kept.count): \(list(kept))" }
            if !failed.isEmpty { line += "; could not remove \(failed.count): \(list(failed))" }
            if !leftovers.isEmpty {
                line += "; left in place \(leftovers.count) *.tmp leftover(s) without the daemon's marker (an older build's"
                    + " temporaries, or not the daemon's; remove by hand when stale): \(list(leftovers))"
            }
        }
        if truncated { line += "; the walk stopped at \(limit) entries (the rest not looked at)" }
        return line
    }
}
