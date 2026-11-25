import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// The path pre-check (`DaemonFile.containmentRefusal`, behind every verb's `guardPath`) passes a path only when
/// its containment was positively established. The shapes where resolution fails part-way (an over-long resolved
/// path, an over-long path string, a long path through a self-link that ends outside) are refused by the
/// pre-check itself, by errno, and nothing appears outside the root. A write path over the limit whose first 1024
/// UTF-16 units (all that standardizingPath keeps) name an existing file is refused by name, and that file is kept.
/// The legal shapes still pass.
/// Every fixture lives in the test's own folder: `root` is the data root and its sibling `outside` stands for
/// everything else.
final class EngineFILE1PreCheckTests: XCTestCase {
    private var base: String!
    private var root: String!
    private var outside: String!
    /// One deep component: four of them under the root resolve to more than 1024 bytes.
    private let deep = String(repeating: "a", count: 245)

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment["DAGDB_TEST_SCRATCH"] ?? ""
        let dir = env.isEmpty ? NSTemporaryDirectory() : env
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        base = DaemonFile.canonicalRoot(dir)! + "/pc-\(UUID().uuidString)"
        root = base + "/root"
        outside = base + "/outside"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside + "/c1", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        guard let b = base else { return }
        removeDeepFolder()
        try? FileManager.default.removeItem(atPath: b)
    }

    // MARK: Helpers

    /// Every entry under `outside` (relative path -> type and bytes or link target), and the names in `base`.
    private func outsideState() -> [String: String] {
        var out: [String: String] = ["(base)": ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).sorted().joined(separator: ",")]
        let fm = FileManager.default
        for rel in (fm.subpaths(atPath: outside) ?? []).sorted() {
            let p = outside + "/" + rel
            var st = stat()
            guard lstat(p, &st) == 0 else { out[rel] = "lstat errno \(errno)"; continue }
            switch st.st_mode & S_IFMT {
            case S_IFREG: out[rel] = "file " + ((try? Data(contentsOf: URL(fileURLWithPath: p)))?.base64EncodedString() ?? "?")
            case S_IFLNK: out[rel] = "link " + ((try? fm.destinationOfSymbolicLink(atPath: p)) ?? "?")
            case S_IFDIR: out[rel] = "dir"
            default: out[rel] = "other \(st.st_mode)"
            }
        }
        return out
    }

    /// Outside decoys a followed link would reach: a snapshot and its sidecar (fresh single-link copies of one
    /// the handler saved in the root), and a JSON file.
    private func plantDecoys(_ f: HandlerFixture) throws {
        let src = root + "/fx.dags"
        XCTAssertTrue(f.handler.handle("SAVE \(src)").hasPrefix("OK SAVE"))
        try Data(contentsOf: URL(fileURLWithPath: src)).write(to: URL(fileURLWithPath: outside + "/c1/p.dags"))
        try Data(contentsOf: URL(fileURLWithPath: src + ".sha256")).write(to: URL(fileURLWithPath: outside + "/c1/p.dags.sha256"))
        try Data("{\"outside\": true}\n".utf8).write(to: URL(fileURLWithPath: outside + "/c1/x.json"))
    }

    /// `root/s -> A/A/A/A` (relative), so the folder D = root/A/A/A/A resolves to more than 1024 bytes; inside D,
    /// `f -> ../../../../../outside/c1/p.dags` and `e -> ../../../../../outside/c1` climb out of the root. The
    /// folders are made through descriptors (their absolute path is too long for a path call).
    private func makeDeepFolder() throws {
        var fd = open(root, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        for _ in 0..<4 {
            XCTAssertEqual(mkdirat(fd, deep, 0o755), 0, "mkdirat errno \(errno)")
            let next = openat(fd, deep, O_RDONLY | O_DIRECTORY)
            XCTAssertGreaterThanOrEqual(next, 0)
            close(fd); fd = next
        }
        XCTAssertEqual(symlinkat("../../../../../outside/c1/p.dags", fd, "f"), 0)
        XCTAssertEqual(symlinkat("../../../../../outside/c1", fd, "e"), 0)
        close(fd)
        try FileManager.default.createSymbolicLink(atPath: root + "/s", withDestinationPath: [String](repeating: deep, count: 4).joined(separator: "/"))
        XCTAssertGreaterThan(root.utf8.count + 1 + 4 * (deep.utf8.count + 1), 1024, "D resolves past the system limit")
        let rp = realpath(root + "/s/f", nil), e = errno
        XCTAssertNil(rp, "libc realpath cannot resolve the link")
        XCTAssertEqual(e, ENAMETOOLONG)
    }

    /// The deep folder removed through descriptors (a path call cannot reach it).
    private func removeDeepFolder() {
        guard let r = root else { return }
        var fds: [Int32] = []
        var fd = open(r, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return }
        fds.append(fd)
        for _ in 0..<4 {
            let next = openat(fd, deep, O_RDONLY | O_DIRECTORY)
            guard next >= 0 else { break }
            fds.append(next); fd = next
        }
        if fds.count == 5 { _ = unlinkat(fd, "f", 0); _ = unlinkat(fd, "e", 0) }
        while fds.count > 1 {
            let child = fds.removeLast(); close(child)
            _ = unlinkat(fds.last!, deep, AT_REMOVEDIR)
        }
        close(fds[0])
    }

    private func refusal(_ p: String) -> String? {
        DaemonFile.withRoot(root) { DaemonFile.containmentRefusal(p) }.map { "\($0)" }
    }

    /// A path over the limit whose first 1024 UTF-16 units are `head`, `unit` repeated, '/' and the neighbour's
    /// name, so a cut there names the neighbour; the path's last name extends the neighbour's. The first candidate
    /// whose length fits the unit's is used.
    private func cutPath(_ head: String, _ unit: String, _ candidates: [(neighbour: String, last: String)]) -> (path: String, neighbour: String, kept: String)? {
        for c in candidates {
            let pad = 1024 - head.utf16.count - 1 - c.neighbour.utf16.count
            guard pad > 0, pad % unit.utf16.count == 0 else { continue }
            let padded = head + String(repeating: unit, count: pad / unit.utf16.count)
            return (padded + "/" + c.last, head + "/" + c.neighbour, padded + "/" + c.neighbour)
        }
        return nil
    }

    /// The write is refused by name with ENAMETOOLONG (by forWrite, by the pre-check and through SAVE); the
    /// neighbour the cut would name keeps its bytes and its inode, and nothing new appears in the root.
    private func assertRefusedAndNeighbourKept(_ head: String, _ unit: String, _ candidates: [(neighbour: String, last: String)], _ label: String) throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        guard let c = cutPath(head, unit, candidates) else { return XCTFail("\(label): no candidate fits") }
        let (p, neighbour, kept) = c
        XCTAssertEqual(kept.utf16.count, 1024, label)
        XCTAssertTrue(p.hasPrefix(kept) && p.utf16.count > 1024, label)
        let bytes = Data("the neighbour's own bytes\n".utf8)
        try bytes.write(to: URL(fileURLWithPath: neighbour))
        var st = stat()
        XCTAssertEqual(lstat(neighbour, &st), 0, label)
        let ino = st.st_ino
        let listing = (FileManager.default.subpaths(atPath: root) ?? []).sorted()
        XCTAssertThrowsError(try DaemonFile.withRoot(root) { try DaemonFile.forWrite(p) }, label) {
            XCTAssertEqual($0 as? DaemonFile.Refusal, .io(path: p, call: "lstat", errno: ENAMETOOLONG), label)
        }
        let r = refusal(p)
        XCTAssertTrue(r?.hasPrefix("ENAMETOOLONG (errno 63) path=\"") == true, "\(label): \(r ?? "passed")")
        let reply = f.handler.handle("SAVE \(p)")
        XCTAssertTrue(reply.hasPrefix("ERROR io: path: ENAMETOOLONG (errno 63) path=\""), "\(label): \(reply)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: neighbour)), bytes, "\(label): the neighbour's bytes")
        XCTAssertEqual(lstat(neighbour, &st), 0, label)
        XCTAssertEqual(st.st_ino, ino, "\(label): the neighbour's inode")
        XCTAssertEqual((FileManager.default.subpaths(atPath: root) ?? []).sorted(), listing, "\(label): nothing new in the root")
    }

    // MARK: The shapes the pre-check refuses

    /// A link as the last component, inside a folder whose resolved path is over 1024 bytes: its resolution fails
    /// (ENAMETOOLONG), so the pre-check refuses it, directly and through SAVE and LOAD.
    func testALastComponentLinkThatCannotBeResolvedIsRefusedByThePreCheck() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        try plantDecoys(f)
        try makeDeepFolder()
        let before = outsideState()
        let p = root + "/s/f"
        let r = refusal(p)
        XCTAssertNotNil(r, "a link whose resolution fails is not contained")
        XCTAssertTrue(r?.hasPrefix("ENAMETOOLONG (errno 63) path=\"") == true, r ?? "nil")
        for verb in ["SAVE", "LOAD"] {
            let reply = f.handler.handle("\(verb) \(p)")
            XCTAssertTrue(reply.hasPrefix("ERROR io: path: ENAMETOOLONG (errno 63) path=\""), "\(verb): \(reply)")
        }
        XCTAssertEqual(outsideState(), before, "nothing outside changed")
    }

    /// A path string over the system limit, with no link at all: lstat fails with ENAMETOOLONG, which is not
    /// "missing"; refused by the pre-check, directly and through SAVE and LOAD.
    func testAPathOverTheSystemLimitIsRefusedByThePreCheck() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        try plantDecoys(f)
        let before = outsideState()
        let p = root + "/" + [String](repeating: String(repeating: "b", count: 200), count: 6).joined(separator: "/") + "/x.dags"
        XCTAssertGreaterThan(p.utf8.count, 1024)
        let r = refusal(p)
        XCTAssertNotNil(r)
        XCTAssertTrue(r?.hasPrefix("ENAMETOOLONG (errno 63) path=\"") == true, r ?? "nil")
        for verb in ["SAVE", "LOAD"] {
            let reply = f.handler.handle("\(verb) \(p)")
            XCTAssertTrue(reply.hasPrefix("ERROR io: path: ENAMETOOLONG (errno 63) path=\""), "\(verb): \(reply)")
        }
        XCTAssertEqual(outsideState(), before, "nothing outside changed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root).sorted(), ["fx.dags", "fx.dags.sha256"], "nothing created in the root")
    }

    /// A path over 1024 bytes through `self -> .`, ending in `oo -> ../outside`: refused by the pre-check (it does
    /// not append the unresolved tail and call it contained), directly and through SAVE and LOAD.
    func testALongPathThroughASelfLinkEndingOutsideIsRefusedByThePreCheck() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        try plantDecoys(f)
        try FileManager.default.createSymbolicLink(atPath: root + "/self", withDestinationPath: ".")
        try FileManager.default.createSymbolicLink(atPath: root + "/oo", withDestinationPath: "../outside")
        let n = (1100 - root.utf8.count) / 5 + 1
        let long = root + String(repeating: "/self", count: n)
        let write = long + "/oo/c1/new.dags", read = long + "/oo/c1/p.dags"
        XCTAssertGreaterThan(write.utf8.count, 1024)
        let before = outsideState()
        for p in [write, read] {
            let r = refusal(p)
            XCTAssertNotNil(r)
            XCTAssertTrue(r?.hasPrefix("ENAMETOOLONG (errno 63) path=\"") == true, r ?? "nil")
        }
        let s = f.handler.handle("SAVE \(write)"), l = f.handler.handle("LOAD \(read)")
        XCTAssertTrue(s.hasPrefix("ERROR io: path: ENAMETOOLONG (errno 63) path=\""), s)
        XCTAssertTrue(l.hasPrefix("ERROR io: path: ENAMETOOLONG (errno 63) path=\""), l)
        XCTAssertEqual(outsideState(), before, "nothing outside changed")
    }

    // MARK: A write path over the limit is refused before it is standardized

    /// The root, '/.' repeated, then 'victim.dags.new': the first 1024 UTF-16 units end at 'victim.dags'.
    func testAPathPaddedWithDotsOverTheLimitIsRefusedAndTheNeighbourKept() throws {
        try assertRefusedAndNeighbourKept(root, "/.", [("victim.dags", "victim.dags.new"), ("victim0.dags", "victim0.dags.new")], "'/.'")
    }

    /// The same with '//' as the padding.
    func testAPathPaddedWithDoubleSlashesOverTheLimitIsRefusedAndTheNeighbourKept() throws {
        try assertRefusedAndNeighbourKept(root, "//", [("victim.dags", "victim.dags.new"), ("victim0.dags", "victim0.dags.new")], "'//'")
    }

    /// A folder with non-ASCII letters before the cut (one, one and two UTF-16 units; two, three and four bytes):
    /// the cut is counted in UTF-16 units, not bytes or characters.
    func testAPathWithNonASCIIBeforeTheCutIsRefusedAndTheNeighbourKept() throws {
        let dir = root + "/\u{E9}\u{20AC}\u{1F600}"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
        XCTAssertEqual(dir.utf8.count - root.utf8.count, 10)
        XCTAssertEqual(dir.utf16.count - root.utf16.count, 5)
        try assertRefusedAndNeighbourKept(dir, "/.", [("victim.dags", "victim.dags.new"), ("victim0.dags", "victim0.dags.new")], "non-ASCII")
    }

    /// The cut inside the last name: 'victimfile.dags' cut to 'victim' (or 'victimf'), an existing file.
    func testAPathCutMidNameIsRefusedAndTheNeighbourKept() throws {
        try assertRefusedAndNeighbourKept(root, "/.", [("victim", "victimfile.dags"), ("victimf", "victimfile.dags")], "mid-name")
    }

    // MARK: The legal shapes still pass

    /// A path padded with '/.' to 1023 bytes, one under the system's limit, still saves (it names root/new.dags,
    /// which then loads; a read of the padded name itself would add '.sha256' and pass the limit); at 1024 bytes
    /// the write is refused, as a read is. A relative path is measured after the working directory.
    func testAPathJustUnderTheLimitStillWorks() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        func padded(_ total: Int) -> String {
            let tail = "/new.dags", n = total - root.utf8.count - tail.utf8.count
            return root + (n % 2 == 1 ? "/" : "") + String(repeating: "/.", count: n / 2) + tail
        }
        let under = padded(1023), at = padded(1024)
        XCTAssertEqual(under.utf8.count, 1023)
        XCTAssertEqual(at.utf8.count, 1024)
        let r = refusal(at)
        XCTAssertTrue(r?.hasPrefix("ENAMETOOLONG (errno 63) path=\"") == true, r ?? "passed")
        let s = f.handler.handle("SAVE \(at)")
        XCTAssertTrue(s.hasPrefix("ERROR io: path: ENAMETOOLONG (errno 63) path=\""), s)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/new.dags"))
        XCTAssertNil(refusal(under))
        XCTAssertEqual(try DaemonFile.withRoot(root) { try DaemonFile.forWrite(under) }, root + "/new.dags")
        let saved = f.handler.handle("SAVE \(under)")
        XCTAssertTrue(saved.hasPrefix("OK SAVE"), saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/new.dags"))
        let loaded = f.handler.handle("LOAD \(root!)/new.dags")
        XCTAssertTrue(loaded.hasPrefix("OK LOAD"), loaded)
        let cwd = FileManager.default.currentDirectoryPath
        let rel = "x" + String(repeating: "/.", count: (1024 - cwd.utf8.count) / 2)
        XCTAssertLessThan(rel.utf8.count, 1024)
        XCTAssertGreaterThanOrEqual((cwd + "/" + rel).utf8.count, 1024)
        XCTAssertThrowsError(try DaemonFile.forWrite(rel)) {
            XCTAssertEqual($0 as? DaemonFile.Refusal, .io(path: rel, call: "lstat", errno: ENAMETOOLONG))
        }
    }

    /// A new file in an existing folder of the root.
    func testANewFileInAnInRootFolderStillPasses() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        try FileManager.default.createDirectory(atPath: root + "/d", withIntermediateDirectories: false)
        let p = root + "/d/new.dags"
        XCTAssertNil(refusal(p))
        XCTAssertTrue(f.handler.handle("SAVE \(p)").hasPrefix("OK SAVE"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: p))
        XCTAssertTrue(f.handler.handle("LOAD \(p)").hasPrefix("OK LOAD"))
    }

    /// On a file system that ignores letter case, an existing name spelled in another case resolves to its own
    /// spelling (as realpath gives it), so the daemon's live log named in capitals is still refused, and nothing is
    /// written over it.
    func testAnotherLetterCaseResolvesToTheNamesOwnSpellingAndTheLiveLogStaysRefused() throws {
        try FileManager.default.createDirectory(atPath: root + "/d", withIntermediateDirectories: false)
        try Data(count: 4).write(to: URL(fileURLWithPath: root + "/d/x.bin"))
        var st = stat()
        guard lstat(root + "/D/X.BIN", &st) == 0 else { throw XCTSkip("this file system tells letter case apart") }
        XCTAssertEqual(try DaemonFile.withRoot(root) { try DaemonFile.forWrite(root + "/D/X.BIN") }, root + "/d/x.bin")
        XCTAssertEqual(try DaemonFile.withRoot(root) { try DaemonFile.forWrite(root + "/D/NEW.BIN") }, root + "/d/NEW.BIN")
        let walPath = root + "/d.wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 16)
        let f = try HandlerFixture(side: 4, dataRoot: root, wal: wal)
        let before = try Data(contentsOf: URL(fileURLWithPath: walPath))
        let upper = root + "/D.WAL"
        XCTAssertEqual(f.handler.handle("SAVE \(upper)"),
                       "ERROR io: SAVE: \"\(upper)\" is the daemon's write-ahead log (DAGDB_WAL) or its era sidecar; refused, nothing written")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: walPath)), before)
    }

    /// A name that starts with a combining mark is inside the root (the containment check compares bytes; as
    /// characters, the mark joins the '/' before it and the root's prefix is not found).
    func testANameStartingWithACombiningMarkIsContained() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        let mark = root + "/\u{301}x.dags"
        XCTAssertNil(refusal(mark))
        XCTAssertTrue(f.handler.handle("SAVE \(mark)").hasPrefix("OK SAVE"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mark))
        XCTAssertTrue(f.handler.handle("LOAD \(mark)").hasPrefix("OK LOAD"))
        XCTAssertTrue(DaemonFile.inside(mark, root))
        XCTAssertFalse(DaemonFile.inside(root + "\u{301}/x.dags", root), "a sibling whose name extends the root's is outside")
    }

    /// An in-root link to an in-root file and to an in-root folder (each a last component), and a path through an
    /// in-root linked folder.
    func testInRootLinksToInRootFilesAndFoldersStillPass() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        try FileManager.default.createDirectory(atPath: root + "/d", withIntermediateDirectories: false)
        XCTAssertTrue(f.handler.handle("SAVE \(root!)/d/real.dags").hasPrefix("OK SAVE"))
        XCTAssertTrue(f.handler.handle("EXPORT MORTON \(root!)/m").hasPrefix("OK EXPORT"))
        try FileManager.default.createSymbolicLink(atPath: root + "/alias.dags", withDestinationPath: root + "/d/real.dags")
        try FileManager.default.createSymbolicLink(atPath: root + "/ml", withDestinationPath: "m")
        try FileManager.default.createSymbolicLink(atPath: root + "/ld", withDestinationPath: "d")
        XCTAssertNil(refusal(root + "/alias.dags"))
        XCTAssertNil(refusal(root + "/ml"))
        XCTAssertNil(refusal(root + "/ld/y.dags"))
        XCTAssertTrue(f.handler.handle("LOAD \(root!)/alias.dags").hasPrefix("OK LOAD"))
        XCTAssertTrue(f.handler.handle("IMPORT MORTON \(root!)/ml").hasPrefix("OK IMPORT"))
        XCTAssertTrue(f.handler.handle("SAVE \(root!)/ld/y.dags").hasPrefix("OK SAVE"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/d/y.dags"))
        XCTAssertTrue(f.handler.handle("LOAD \(root!)/ld/y.dags").hasPrefix("OK LOAD"))
    }
}
