import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Every file the daemon opens is contained,
/// regular, read once, admitted, and fails loud. In-process tests for what a live daemon cannot show
/// deterministically (a link swapped between the check and the open, the fsync poison through the seam), and
/// the helper's own refusals. The live checks run against the release daemons.
final class EngineFILE1Tests: XCTestCase {
    private var root: String!
    private var outside: String!

    override func setUpWithError() throws {
        let base = DaemonFile.canonicalRoot(NSTemporaryDirectory())! + "/file1-\(UUID().uuidString)"
        root = base + "/root"
        outside = base + "/outside"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("DAGDB_FI_FULLFSYNC_FAIL")
        if let r = root { try? FileManager.default.removeItem(atPath: (r as NSString).deletingLastPathComponent) }
    }

    private func outsideNames() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: outside)) ?? [] }

    // MARK: - The read helper

    func testReaderRefusesAFifoADeviceLinkADirectoryAndALinkOutsideTheRootAtOnce() throws {
        let secret = outside + "/secret.bin"
        try Data(repeating: 7, count: 64).write(to: URL(fileURLWithPath: secret))
        let fifo = root + "/f", dz = root + "/dz", dir = root + "/d", out = root + "/o"
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        try FileManager.default.createSymbolicLink(atPath: dz, withDestinationPath: "/dev/zero")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: out, withDestinationPath: secret)
        try DaemonFile.withRoot(root) {
            let t0 = Date()
            XCTAssertThrowsError(try DaemonFile.read(fifo)) { XCTAssertEqual("\($0)", "EFTYPE (errno 79) path=\"\(fifo)\": a fifo, not a regular file") }
            XCTAssertThrowsError(try DaemonFile.read(dz)) { XCTAssertEqual("\($0)", "EPERM (errno 1) path=\"\(dz)\": resolves outside DAGDB_DATA_ROOT") }
            XCTAssertThrowsError(try DaemonFile.read(dir)) { XCTAssertEqual("\($0)", "EISDIR (errno 21) path=\"\(dir)\": a directory, not a regular file") }
            XCTAssertThrowsError(try DaemonFile.read(out)) {
                XCTAssertEqual("\($0)", "EPERM (errno 1) path=\"\(out)\": resolves outside DAGDB_DATA_ROOT")
            }
            XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0, "every refusal answers at once")
            // Unbound (an unguarded daemon): the regular-file rules still hold; containment does not apply.
            XCTAssertEqual(try DaemonFile.withRoot(nil) { try DaemonFile.read(out) }.count, 64)
        }
    }

    func testReaderAppliesTheSizeRuleAndAdmitsOnTheTargetsTrueSize() throws {
        let big = root + "/big.bin", link = root + "/link.bin"
        try Data(count: 1 << 20).write(to: URL(fileURLWithPath: big))
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: big)
        var asked: [Int] = []
        try DaemonFile.withRoot(root) {
            _ = try DaemonFile.read(link, admit: { asked.append($0); return nil })
            XCTAssertThrowsError(try DaemonFile.read(link, .atMost(1000))) { XCTAssertTrue("\($0)".hasPrefix("EFBIG (errno 27) path=\"\(link)\": 1048576 bytes")) }
            XCTAssertThrowsError(try DaemonFile.read(link, admit: { _ in "ERROR out_of_budget: test" })) {
                XCTAssertEqual("\($0)", "ERROR out_of_budget: test")
            }
            XCTAssertEqual(try DaemonFile.read(link, .prefix(16)).count, 16)
        }
        XCTAssertEqual(asked, [1 << 20], "admitted on the opened file's st_size, never the link's own length")
    }

    func testReaderRefusesAFileChangedWhileItIsRead() throws {
        let p = root + "/c.bin"
        try Data(count: 4096).write(to: URL(fileURLWithPath: p))
        let r = try DaemonFile.Reader(p)
        _ = try r.read(1024)
        let h = FileHandle(forWritingAtPath: p)!
        h.seekToEndOfFile(); h.write(Data(count: 10)); h.closeFile()
        XCTAssertThrowsError(try r.finish(whole: false)) { XCTAssertTrue("\($0)".hasPrefix("ESTALE (errno 70) path=\"\(p)\""), "\($0)") }
        let r2 = try DaemonFile.Reader(p)
        XCTAssertEqual(truncate(p, 100), 0)
        XCTAssertThrowsError(try r2.read(r2.size)) { XCTAssertTrue("\($0)".hasPrefix("EIO (errno 5) path=\"\(p)\": 100 of 4106 bytes read"), "\($0)") }
    }

    // MARK: - Containment for writes

    func testANewFileUnderALinkedDirectoryIsRefusedAndNothingIsCreatedOutside() throws {
        try FileManager.default.createSymbolicLink(atPath: root + "/lnk", withDestinationPath: outside)
        let f = try HandlerFixture(side: 4, dataRoot: root)
        let r = f.handler.handle("SAVE \(root!)/lnk/x.dags")
        XCTAssertEqual(r, "ERROR io: path: \"\(root!)/lnk/x.dags\" outside DAGDB_DATA_ROOT")
        XCTAssertEqual(outsideNames(), [])
        // A linked last component inside the root is refused for a write (no link is followed).
        try Data().write(to: URL(fileURLWithPath: root + "/real.dags"))
        try FileManager.default.createSymbolicLink(atPath: root + "/alias.dags", withDestinationPath: root + "/real.dags")
        let ra = f.handler.handle("SAVE \(root!)/alias.dags")
        XCTAssertTrue(ra.hasPrefix("ERROR io: save: ") && ra.contains("ELOOP (errno 62) path=\"\(root!)/alias.dags\""), ra)
    }

    /// A link swapped into a component AFTER the check: the open of the canonical path uses O_NOFOLLOW_ANY,
    /// so it fails (ELOOP) and no file appears outside; a read is caught by its descriptor's path.
    func testALinkSwappedInAfterTheCheckIsNeverFollowed() throws {
        let dir = root + "/d"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
        try DaemonFile.withRoot(root) {
            let c = try DaemonFile.forWrite(dir + "/new.bin")
            try FileManager.default.removeItem(atPath: dir)
            try FileManager.default.createSymbolicLink(atPath: dir, withDestinationPath: outside)
            XCTAssertThrowsError(try DaemonFile.openForWrite(c, create: true)) { XCTAssertTrue("\($0)".hasPrefix("ELOOP"), "\($0)") }
            XCTAssertNotEqual(DaemonFile.renameNoFollow(root + "/none", c), 0)
            XCTAssertNotEqual(DaemonFile.mkdirNoFollow(dir + "/sub"), 0)
            XCTAssertEqual(outsideNames(), [])
            // Reads follow links, and the opened file's own path is checked.
            try Data(count: 8).write(to: URL(fileURLWithPath: outside + "/x.bin"))
            XCTAssertThrowsError(try DaemonFile.read(dir + "/x.bin")) { XCTAssertTrue("\($0)".hasPrefix("EPERM"), "\($0)") }
        }
    }

    func testDotDotAfterALinkIsRefusedForReadsAndWrites() throws {
        try FileManager.default.createSymbolicLink(atPath: root + "/lnk", withDestinationPath: outside + "/")
        try DaemonFile.withRoot(root) {
            XCTAssertThrowsError(try DaemonFile.forWrite(root + "/lnk/../x")) { XCTAssertTrue("\($0)".hasPrefix("EINVAL"), "\($0)") }
            XCTAssertThrowsError(try DaemonFile.read(root + "/lnk/../x")) { XCTAssertTrue("\($0)".hasPrefix("EINVAL"), "\($0)") }
        }
    }

    // MARK: - Loud

    func testAnUnreadableSidecarRefusesTheLoadUnlessUnverifiedIsAsked() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        XCTAssertTrue(f.handler.handle("SAVE \(root!)/s.dags").hasPrefix("OK SAVE"))
        let side = root + "/s.dags.sha256"
        try FileManager.default.removeItem(atPath: side)
        XCTAssertEqual(mkfifo(side, 0o600), 0)
        let r = f.handler.handle("LOAD \(root!)/s.dags")
        XCTAssertTrue(r.hasPrefix("ERROR io: load: unverified: the .sha256 manifest of \"\(root!)/s.dags\" cannot be read (EFTYPE (errno 79) path=\"\(side)\": a fifo"), r)
        XCTAssertTrue(f.handler.handle("LOAD \(root!)/s.dags UNVERIFIED").hasPrefix("OK LOAD"))
        try FileManager.default.removeItem(atPath: side)
        XCTAssertTrue(f.handler.handle("LOAD \(root!)/s.dags").hasPrefix("OK LOAD"), "absent: the legacy case, loaded unverified")
    }

    func testACutLanesCSVIsRefusedAndNeverResetsTheLanes() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        XCTAssertTrue(f.handler.handle("SET 3 VALUE 0.5").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("SAVE CSV \(root!)/cv").hasPrefix("OK SAVE_CSV"))
        let lanes = root + "/cv/lanes.csv"
        let text = try String(contentsOfFile: lanes, encoding: .utf8)
        let lines = text.split(separator: "\n")
        try (lines.prefix(lines.count / 2).joined(separator: "\n") + "\n").write(toFile: lanes, atomically: true, encoding: .utf8)
        let r = f.handler.handle("LOAD CSV \(root!)/cv")
        XCTAssertTrue(r.hasPrefix("ERROR io: load_csv: invalid JSON: lanes.csv holds"), r)
        try (String(text.dropLast(3))).write(toFile: lanes, atomically: true, encoding: .utf8)
        XCTAssertTrue(f.handler.handle("LOAD CSV \(root!)/cv").contains("does not end in a newline"))
        try FileManager.default.removeItem(atPath: lanes)
        XCTAssertEqual(mkfifo(lanes, 0o600), 0)
        XCTAssertTrue(f.handler.handle("LOAD CSV \(root!)/cv").contains("EFTYPE (errno 79) path=\"\(lanes)\": a fifo"))
    }

    func testAStaleDiffUnderANewBaseIsRefusedByItsParentRecord() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        let bk = root + "/bk"
        XCTAssertTrue(f.handler.handle("BACKUP INIT \(bk)").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("SET 1 TRUTH 1").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("BACKUP APPEND \(bk)").hasPrefix("OK"))
        // The failed-removal case: a new base lands while the old diff stays (its removal failed).
        let keep = try Data(contentsOf: URL(fileURLWithPath: bk + "/00001.diff"))
        let keepSide = try Data(contentsOf: URL(fileURLWithPath: bk + "/00001.diff.sha256"))
        let keepParent = try Data(contentsOf: URL(fileURLWithPath: bk + "/00001.diff.parent"))
        XCTAssertTrue(f.handler.handle("SET 2 TRUTH 1").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("BACKUP INIT \(bk)").hasPrefix("OK"))
        try keep.write(to: URL(fileURLWithPath: bk + "/00001.diff"))
        try keepSide.write(to: URL(fileURLWithPath: bk + "/00001.diff.sha256"))
        try keepParent.write(to: URL(fileURLWithPath: bk + "/00001.diff.parent"))
        let r = f.handler.handle("BACKUP RESTORE \(bk)")
        XCTAssertTrue(r.hasPrefix("ERROR io: backup diff \"00001.diff\" was written over sha256"), r)
        // Without the record (a diff written by an older build): applied, and the count named.
        try FileManager.default.removeItem(atPath: bk + "/00001.diff.parent")
        let unchecked = f.handler.handle("BACKUP RESTORE \(bk)")
        XCTAssertTrue(unchecked.contains(" parent_unchecked=1 "), unchecked)
        XCTAssertTrue(unchecked.contains(" parent_unchecked=1 (diffs written by older builds carry no parent record)"), unchecked)
    }

    // MARK: - The fsync poison (the seam is DEBUG / DAGDB_FAULT_INJECTION only)

    func testAFailedFullSyncPoisonsTheAppenderAndTheLogStaysIntact() throws {
        let walPath = root + "/p.wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 64)
        _ = try wal.setTruth(node: 1, value: 1)
        let before = try Data(contentsOf: URL(fileURLWithPath: walPath))
        setenv("DAGDB_FI_FULLFSYNC_FAIL", "append", 1)
        XCTAssertThrowsError(try wal.setTruth(node: 2, value: 1)) {
            XCTAssertTrue("\($0)".contains("F_FULLFSYNC of \(walPath) failed (EIO)"), "\($0)")
            XCTAssertTrue("\($0)".contains("the record was cut from the log"), "\($0)")
        }
        unsetenv("DAGDB_FI_FULLFSYNC_FAIL")
        XCTAssertThrowsError(try wal.setTruth(node: 3, value: 1)) {
            XCTAssertTrue("\($0)".contains("refuses every write until the daemon restarts"), "\($0)")
        }
        XCTAssertThrowsError(try wal.barrierChecked())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: walPath)), before, "the log is intact")
        // At open, a failed sync of the log found refuses the open.
        setenv("DAGDB_FI_FULLFSYNC_FAIL", "1", 1)
        XCTAssertThrowsError(try DagDBWAL.Appender(path: walPath, nodeCount: 64)) {
            XCTAssertTrue("\($0)".contains("F_FULLFSYNC of the log found at open failed"), "\($0)")
        }
        unsetenv("DAGDB_FI_FULLFSYNC_FAIL")
        XCTAssertNoThrow(try DagDBWAL.Appender(path: walPath, nodeCount: 64))
    }

    // MARK: - The stage sweep

    func testTheStartSweepRemovesOnlyTheDaemonsOwnStaleStagesAndNamesThem() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/cv/.dagdb-stage-99999999-3", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/cv/.dagdb-stage-99999999-3/nodes.csv"))
        try fm.createDirectory(atPath: root + "/w", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/.w.dagdb-stage-99999999-4", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/.gone.dagdb-stage-99999999-5", withIntermediateDirectories: true)
        try Data(DagDBSnapshot.magic + [0, 0]).write(to: URL(fileURLWithPath: root + "/s.dags.tmp"))
        try Data("mine".utf8).write(to: URL(fileURLWithPath: root + "/notes.tmp"))
        try Data("u".utf8).write(to: URL(fileURLWithPath: root + "/.x.json.dagdb-tmp-99999999-1"))
        let old = Date().addingTimeInterval(-3600)
        for p in ["/s.dags.tmp", "/notes.tmp", "/.x.json.dagdb-tmp-99999999-1"] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: root + p)
        }
        let line = DagDBStartup.sweepStages(root: root)
        // A snapshot named *.tmp carries no marker: left in place and named.
        XCTAssertTrue(line.contains("removed 3 stale stage item(s)"), line)
        XCTAssertTrue(line.contains("left in place 1 *.tmp leftover(s)") && line.contains("s.dags.tmp"), line)
        XCTAssertTrue(line.contains("kept 1: .gone.dagdb-stage-99999999-5 (the world gone is absent"), line)
        XCTAssertFalse(fm.fileExists(atPath: root + "/cv/.dagdb-stage-99999999-3"))
        XCTAssertFalse(fm.fileExists(atPath: root + "/.w.dagdb-stage-99999999-4"))
        XCTAssertTrue(fm.fileExists(atPath: root + "/s.dags.tmp"), "no marker: left in place")
        XCTAssertTrue(fm.fileExists(atPath: root + "/notes.tmp"), "not the daemon's: kept")
        XCTAssertTrue(fm.fileExists(atPath: root + "/.gone.dagdb-stage-99999999-5"))
        XCTAssertTrue(DagDBStartup.sweepStages(root: nil).contains("no data root"))
    }

    // MARK: - SAVE to the WAL's own path

    func testSaveToTheWALsOwnPathIsRefused() throws {
        let walPath = root + "/d.wal"
        let wal = try DagDBWAL.Appender(path: walPath, nodeCount: 16)
        let f = try HandlerFixture(side: 4, dataRoot: root, wal: wal)
        let before = try Data(contentsOf: URL(fileURLWithPath: walPath))
        XCTAssertEqual(f.handler.handle("SAVE \(walPath)"),
                       "ERROR io: SAVE: \"\(walPath)\" is the daemon's write-ahead log (DAGDB_WAL) or its era sidecar; refused, nothing written")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: walPath)), before)
    }
}

// MARK: - Hard links and temporaries, at the helper (DaemonFile)

/// At the helper: a file with more than one link, and the temporaries. Scratch as `EngineFILE1A2Tests` (`$DAGDB_TEST_SCRATCH`, else the temporary directory).
final class EngineFILE1A2HelperTests: XCTestCase {
    private var base: String!
    private var root: String!
    private var outside: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment["DAGDB_TEST_SCRATCH"] ?? ""
        let dir = env.isEmpty ? NSTemporaryDirectory() : env
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        base = DaemonFile.canonicalRoot(dir)! + "/a2h-\(UUID().uuidString)"
        root = base + "/root"
        outside = base + "/outside"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let b = base { try? FileManager.default.removeItem(atPath: b) }
    }

    private func linkedText(_ p: String, _ n: Int = 2) -> String {
        "EMLINK (errno 31) path=\"\(p)\": the file has \(n) hard links; the daemon opens only a file with one link (a link from"
            + " outside the data root would let it read or write that file); copy the file to a single-link file"
    }

    /// Every DaemonFile open, reader and writer, refuses an existing regular file with st_nlink > 1 by name:
    /// the read helper's init, forWrite's existing final component, openForWrite and openForUpdate (their fstat
    /// after the open, which also catches a link made between the check and the open), atomicWrite's target.
    func testA2EveryDaemonFileOpenRefusesAFileWithMoreThanOneLinkByName() throws {
        let out = outside + "/o.bin", p = root + "/l.bin"
        try Data(repeating: 9, count: 100).write(to: URL(fileURLWithPath: out))
        XCTAssertEqual(link(out, p), 0)
        try DaemonFile.withRoot(root) {
            XCTAssertThrowsError(try DaemonFile.read(p)) { XCTAssertEqual("\($0)", linkedText(p)) }
            XCTAssertThrowsError(try DaemonFile.Reader(p)) { XCTAssertEqual("\($0)", linkedText(p)) }
            XCTAssertThrowsError(try DaemonFile.digest(p)) { XCTAssertEqual("\($0)", linkedText(p)) }
            XCTAssertThrowsError(try DaemonFile.forWrite(p)) { XCTAssertEqual("\($0)", linkedText(p)) }
            XCTAssertThrowsError(try DaemonFile.openForWrite(p, create: false, append: true)) { XCTAssertEqual("\($0)", linkedText(p)) }
            XCTAssertThrowsError(try DaemonFile.openForWrite(p, create: true, append: true)) { XCTAssertEqual("\($0)", linkedText(p)) }
            XCTAssertThrowsError(try DaemonFile.openForUpdate(p)) { XCTAssertEqual("\($0)", linkedText(p)) }
            XCTAssertThrowsError(try DaemonFile.atomicWrite(Data("x".utf8), to: p)) { XCTAssertEqual("\($0)", linkedText(p)) }
            XCTAssertEqual(DaemonFile.containmentRefusal(p).map { "\($0)" }, linkedText(p))
        }
        // Unbound (an unguarded daemon): the rule holds all the same.
        XCTAssertThrowsError(try DaemonFile.read(p)) { XCTAssertEqual("\($0)", linkedText(p)) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out)), Data(repeating: 9, count: 100), "nothing written")
        // A second link made after forWrite's check: the fstat after the open refuses it.
        let q = root + "/q.bin"
        try Data(count: 10).write(to: URL(fileURLWithPath: q))
        try DaemonFile.withRoot(root) {
            let c = try DaemonFile.forWrite(q)
            XCTAssertEqual(link(q, outside + "/q2.bin"), 0)
            XCTAssertThrowsError(try DaemonFile.openForWrite(c, create: false, append: true)) { XCTAssertEqual("\($0)", linkedText(c)) }
            XCTAssertThrowsError(try DaemonFile.openForUpdate(c)) { XCTAssertEqual("\($0)", linkedText(c)) }
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: q)), Data(count: 10))
        // One link again: opened as before.
        XCTAssertEqual(unlink(out), 0)
        XCTAssertEqual(try DaemonFile.withRoot(root) { try DaemonFile.read(p) }.count, 100)
    }

    /// Every temporary is a NEW file (O_CREAT | O_EXCL) at the name `createTemporary` is given: a stale
    /// single-link file there, held open here, keeps its bytes (the writer never opened it: an earlier truncating open
    /// wrote into it); a hard-linked one is refused by name with the outside file unchanged. The
    /// writers no longer use `<path>.tmp` (their temporaries carry the daemon's marker), so a
    /// stale, hard-linked or directory `<path>.tmp` beside a target is never touched and blocks nothing.
    func testA2TemporariesAreAlwaysNewFilesAndAHardLinkedOneIsRefused() throws {
        let stale = Data("stale bytes".utf8)
        func held(_ p: String) throws -> Int32 {
            try stale.write(to: URL(fileURLWithPath: p))
            return open(p, O_RDONLY)
        }
        func content(_ fd: Int32) -> Data {
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = pread(fd, &buf, buf.count, 0)
            return Data(buf.prefix(max(n, 0)))
        }
        func links(_ p: String) -> nlink_t { var st = stat(); return lstat(p, &st) == 0 ? st.st_nlink : 0 }
        let out = outside + "/secret.bin"
        try Data(repeating: 0x5A, count: 256).write(to: URL(fileURLWithPath: out))
        // createTemporary itself: a stale single-link file at the name is replaced by a new inode; a hard link refused.
        let t = root + "/t.tmpname"
        let fd = try held(t)
        defer { close(fd) }
        try DaemonFile.withRoot(root) { close(try DaemonFile.createTemporary(t)) }
        XCTAssertEqual(content(fd), stale, "the stale temporary's inode was never opened for writing")
        XCTAssertEqual(unlink(t), 0)
        XCTAssertEqual(link(out, t), 0)
        XCTAssertThrowsError(try DaemonFile.withRoot(root) { try DaemonFile.createTemporary(t) }) {
            XCTAssertEqual("\($0)", linkedText(t))
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out)), Data(repeating: 0x5A, count: 256))
        // The tiled writer's atomic write and SAVE (plain and COMPRESSED) beside a stale, a hard-linked and a
        // directory `<path>.tmp`: written, and each `<path>.tmp` exactly as it was.
        let j = root + "/x.json"
        let fdj = try held(j + ".tmp")
        defer { close(fdj) }
        try DaemonFile.withRoot(root) { try TiledGraphFiles.writeFileAtomically(Data("{}".utf8), to: j) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: j)), Data("{}".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: j + ".tmp")), stale, "the legacy name is not the writer's")
        let f = try HandlerFixture(side: 4, dataRoot: root)
        for flag in ["", " COMPRESSED"] {
            let s = root + "/s\(flag.isEmpty ? "p" : "c").dags"
            XCTAssertEqual(link(out, s + ".tmp"), 0)
            let before = links(s + ".tmp")
            let r = f.handler.handle("SAVE \(s)\(flag)")
            XCTAssertTrue(r.hasPrefix("OK SAVE"), r)
            XCTAssertEqual(links(s + ".tmp"), before, "SAVE\(flag): the planted link is not the writer's and is left alone")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out)), Data(repeating: 0x5A, count: 256))
        let d = root + "/sd.dags"
        try FileManager.default.createDirectory(atPath: d + ".tmp", withIntermediateDirectories: false)
        XCTAssertTrue(f.handler.handle("SAVE \(d)").hasPrefix("OK SAVE"), "a directory at the legacy name squats nothing")
    }
}

// MARK: - Hard links into the root, through the daemon (portable: it uses nothing the file-containment checks added, so the same class builds and runs on DagDB main)

/// Through the daemon's
/// own verbs and its WAL appender: a file created OUTSIDE the data root is hard-linked into the root under the
/// name the daemon uses. Every case must be refused by name (the refusal names the remedy) and the outside
/// file's bytes must be unchanged. This class uses nothing the file-containment checks added (no `DaemonFile`),
/// so it builds on main.
///
/// Scratch: `$DAGDB_TEST_SCRATCH` when set, else the temporary directory; the root and the
/// outside directory are siblings under one base, on one volume (a hard link needs that).
final class EngineFILE1A2Tests: XCTestCase {
    private var base: String!
    private var root: String!
    private var outside: String!
    private let remedy = "copy the file to a single-link file"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment["DAGDB_TEST_SCRATCH"] ?? ""
        let dir = env.isEmpty ? NSTemporaryDirectory() : env
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let rp = realpath(dir, nil) else { throw NSError(domain: "a2", code: 1) }
        let canon = String(cString: rp); free(rp)
        base = canon + "/a2-\(UUID().uuidString)"
        root = base + "/root"
        outside = base + "/outside"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let b = base { try? FileManager.default.removeItem(atPath: b) }
    }

    private func bytes(_ p: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: p)) }

    /// An outside file holding `data`, hard-linked into the root at `name`; returns the outside path.
    @discardableResult
    private func plant(_ data: Data, outsideName: String, at name: String) throws -> String {
        let out = outside + "/" + outsideName
        try data.write(to: URL(fileURLWithPath: out))
        XCTAssertEqual(link(out, name), 0, "link \(out) -> \(name): errno \(errno)")
        return out
    }

    private func token(_ line: String, _ key: String) -> String? {
        for t in line.split(separator: " ") where t.hasPrefix("\(key)=") { return String(t.dropFirst(key.count + 1)) }
        return nil
    }

    /// The side-44 fixture `SAVE TILED` to `root/<name>` and `TILED OPEN`ed (K = 4); tile 0's directory.
    private func tiledWorld(_ name: String) throws -> (f: HandlerFixture, id: String, tileDir: String) {
        let f = try HandlerFixture(side: 44, dataRoot: root, maxRank: 64)
        try TiledFixture.populate(engine: f.handler.engine, grid: f.grid, side: 44)
        let dir = root + "/" + name
        let s = f.handler.handle("SAVE TILED \(dir) 5,11,17")
        XCTAssertTrue(s.hasPrefix("OK SAVE TILED"), s)
        let o = f.handler.handle("TILED OPEN \(dir) 4")
        XCTAssertTrue(o.hasPrefix("OK TILED OPEN id="), o)
        let m = try TiledGraphFiles.readManifest(dataRoot: root, name: name)
        return (f, token(o, "id") ?? "none", TiledGraphFiles.tileDirectory(dataRoot: root, name: name, entry: m.tiles[0]))
    }

    // MARK: Hard links: the in-place writers

    /// The DAGDB_WAL append: a valid log outside, hard-linked in as the daemon's log. The appender refuses it
    /// by name (main opens it and appends a record into the outside file).
    func testA2TheWALAppendRefusesAHardLinkedLogAndTheOutsideLogIsUnchanged() throws {
        let out = outside + "/real.wal"
        do { _ = try DagDBWAL.Appender(path: out, nodeCount: 16) }               // a header-only log, closed
        let before = try bytes(out)
        XCTAssertEqual(link(out, root + "/d.wal"), 0)
        var refusal = ""
        do {
            let w = try DagDBWAL.Appender(path: root + "/d.wal", nodeCount: 16)
            do { _ = try w.setTruth(node: 1, value: 1) } catch { refusal = "append: \(error)" }
        } catch { refusal = "\(error)" }
        XCTAssertTrue(refusal.contains(remedy), "refused by name: \(refusal)")
        XCTAssertEqual(try bytes(out), before, "the outside log is unchanged")
    }

    /// A tile's flush.wal append: a clean flush log outside, hard-linked in after TILED OPEN; TILED TICK's
    /// BEGIN append is refused by name (main appends BEGIN and COMMIT into the outside file).
    func testA2ATilesFlushWALAppendRefusesAHardLinkAndTheOutsideFileIsUnchanged() throws {
        let w = try tiledWorld("g")
        let out = try plant(Data("TILE_FLUSH_COMMIT 0 0\n".utf8), outsideName: "flush.wal", at: w.tileDir + "/flush.wal")
        let before = try bytes(out)
        let r = w.f.handler.handle("TILED TICK \(w.id) 1")
        XCTAssertTrue(r.hasPrefix("ERROR") && r.contains(remedy), "refused by name: \(r)")
        XCTAssertEqual(try bytes(out), before, "the outside file is unchanged")
    }

    // MARK: Hard links: the temporaries

    /// SAVE's `<path>.tmp`, plain and COMPRESSED, a hard link to an outside file: the outside file unchanged
    /// (an earlier truncating open emptied it and wrote the snapshot into it; an older createFile made a fresh
    /// file). The temporary carries the daemon's marker, so `<path>.tmp` is not its name: SAVE answers OK and
    /// leaves the planted link alone (an earlier build refused it by name; either keeps the bytes).
    func testA2SavesTemporaryRefusesAHardLinkPlainAndCompressedAndTheOutsideFileIsUnchanged() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        XCTAssertTrue(f.handler.handle("SET 3 TRUTH 1").hasPrefix("OK"))
        for (name, flag) in [("plain", ""), ("compressed", " COMPRESSED")] {
            let target = root + "/\(name).dags"
            let out = try plant(Data(repeating: 0x5A, count: 4096), outsideName: "\(name).secret", at: target + ".tmp")
            let before = try bytes(out)
            let r = f.handler.handle("SAVE \(target)\(flag)")
            XCTAssertTrue(r.hasPrefix("OK SAVE") || r.contains(remedy), "\(name): written beside it, or refused by name: \(r)")
            XCTAssertEqual(try bytes(out), before, "\(name): the outside file is unchanged")
        }
    }

    /// A tile's body.dags.tmp (the flush's SAVE) and meta.json.tmp (the flush's atomic write), each a hard link
    /// to an outside file: the outside file is unchanged (one earlier build truncated both; an older one truncated
    /// meta.json.tmp and made body.dags.tmp fresh). Neither is a writer's name any more, so TILED TICK answers OK
    /// (an earlier build refused by name).
    func testA2ATilesBodyAndMetaTemporariesRefuseAHardLinkAndTheOutsideFileIsUnchanged() throws {
        for (world, tmpName) in [("gb", "body.dags.tmp"), ("gm", "meta.json.tmp")] {
            let w = try tiledWorld(world)
            let out = try plant(Data(repeating: 0x5A, count: 4096), outsideName: "\(world).secret", at: w.tileDir + "/" + tmpName)
            let before = try bytes(out)
            let r = w.f.handler.handle("TILED TICK \(w.id) 1")
            XCTAssertTrue(r.hasPrefix("OK TILED TICK") || r.contains(remedy), "\(tmpName): written beside it, or refused by name: \(r)")
            XCTAssertEqual(try bytes(out), before, "\(tmpName): the outside file is unchanged")
        }
    }

    // MARK: Hard links: the read side and the rename targets

    /// LOAD of a snapshot that is a hard link to an outside file (its sidecar in the root, so main verifies
    /// and loads it): refused by name, nothing loaded.
    func testA2LoadRefusesAHardLinkedSnapshot() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        XCTAssertTrue(f.handler.handle("SET 2 TRUTH 1").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("SAVE \(root!)/a.dags").hasPrefix("OK SAVE"))
        XCTAssertTrue(f.handler.handle("SET 2 TRUTH 0").hasPrefix("OK"))
        XCTAssertEqual(rename(root + "/a.dags", outside + "/a.dags"), 0)
        XCTAssertEqual(link(outside + "/a.dags", root + "/a.dags"), 0)
        let before = try bytes(outside + "/a.dags")
        let r = f.handler.handle("LOAD \(root!)/a.dags")
        XCTAssertTrue(r.hasPrefix("ERROR") && r.contains(remedy), "refused by name: \(r)")
        XCTAssertEqual(f.handler.handle("GET 2 TRUTH"), "OK GET node=2 truth=0", "nothing loaded")
        XCTAssertEqual(try bytes(outside + "/a.dags"), before)
    }

    /// IMPORT MORTON with rank.bin a hard link to an outside copy: refused by name, nothing imported.
    func testA2ImportRefusesAHardLinkedFile() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        XCTAssertTrue(f.handler.handle("SET 2 TRUTH 1").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("EXPORT MORTON \(root!)/m").hasPrefix("OK EXPORT"))
        XCTAssertTrue(f.handler.handle("SET 2 TRUTH 0").hasPrefix("OK"))
        XCTAssertEqual(rename(root + "/m/rank.bin", outside + "/rank.bin"), 0)
        XCTAssertEqual(link(outside + "/rank.bin", root + "/m/rank.bin"), 0)
        let before = try bytes(outside + "/rank.bin")
        let r = f.handler.handle("IMPORT MORTON \(root!)/m")
        XCTAssertTrue(r.hasPrefix("ERROR") && r.contains(remedy), "refused by name: \(r)")
        XCTAssertEqual(f.handler.handle("GET 2 TRUTH"), "OK GET node=2 truth=0", "nothing imported")
        XCTAssertEqual(try bytes(outside + "/rank.bin"), before)
    }

    /// A write target's existing final component (SAVE's) and a staged writer's rename target (EXPORT
    /// MORTON's truth.bin), each a hard link to an outside file: refused by name, the outside file unchanged
    /// (main's rename replaced the name and answered OK).
    func testA2AHardLinkedWriteTargetAndRenameTargetAreRefused() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        let t = root + "/t.dags"
        let out = try plant(Data(repeating: 0x33, count: 512), outsideName: "t.secret", at: t)
        let r = f.handler.handle("SAVE \(t)")
        XCTAssertTrue(r.hasPrefix("ERROR") && r.contains(remedy), "SAVE target: refused by name: \(r)")
        XCTAssertEqual(try bytes(out), Data(repeating: 0x33, count: 512))
        XCTAssertTrue(f.handler.handle("EXPORT MORTON \(root!)/m2").hasPrefix("OK EXPORT"))
        XCTAssertEqual(unlink(root + "/m2/truth.bin"), 0)
        let out2 = try plant(Data(repeating: 0x44, count: 16), outsideName: "truth.secret", at: root + "/m2/truth.bin")
        let e = f.handler.handle("EXPORT MORTON \(root!)/m2")
        XCTAssertTrue(e.hasPrefix("ERROR") && e.contains(remedy), "EXPORT rename target: refused by name: \(e)")
        XCTAssertEqual(try bytes(out2), Data(repeating: 0x44, count: 16))
    }

    // MARK: A load with no manifest says so

    /// A LOAD of a snapshot with no .sha256 says so in its OK reply; with the manifest it does not.
    func testA2ALoadWithNoManifestSaysUnverifiedInItsReply() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        XCTAssertTrue(f.handler.handle("SAVE \(root!)/n.dags").hasPrefix("OK SAVE"))
        let verified = f.handler.handle("LOAD \(root!)/n.dags")
        XCTAssertTrue(verified.hasPrefix("OK LOAD") && !verified.contains("unverified"), verified)
        XCTAssertEqual(unlink(root + "/n.dags.sha256"), 0)
        let r = f.handler.handle("LOAD \(root!)/n.dags")
        XCTAssertTrue(r.hasPrefix("OK LOAD") && Reply.withoutVolatile(r).hasSuffix("unverified: no manifest"), r)
    }
}

// MARK: - Non-regular targets, true-size admission, live files, unverified restores (portable: it uses nothing the file-containment checks added, so the same class builds and runs on DagDB main)

/// Through the daemon's own verbs. Uses nothing the file-containment checks added, so it builds on main. Scratch: `$DAGDB_TEST_SCRATCH` when set, else the
/// temporary directory; short names, so a Unix socket's path fits sun_path.
final class EngineFILE1A3Tests: XCTestCase {
    private var base: String!
    private var root: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment["DAGDB_TEST_SCRATCH"] ?? ""
        let dir = env.isEmpty ? NSTemporaryDirectory() : env
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let rp = realpath(dir, nil) else { throw NSError(domain: "a3", code: 1) }
        let canon = String(cString: rp); free(rp)
        base = canon + "/a3-" + String(UUID().uuidString.prefix(8))
        root = base + "/root"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let b = base { try? FileManager.default.removeItem(atPath: b) }
    }

    private func kind(_ p: String) -> mode_t? {
        var st = stat()
        return lstat(p, &st) == 0 ? st.st_mode & S_IFMT : nil
    }

    /// A Unix-domain socket bound at `p` (the fd stays open for the test's life).
    private func bindSocket(_ p: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(p.utf8)
        // A path sun_path cannot hold fails loudly, by its length; the copy below
        // truncated it silently and bound another name (a 104-byte scratch path hid the cause of a failure).
        let room = MemoryLayout.size(ofValue: addr.sun_path) - 1
        if bytes.count > room {
            XCTFail("bindSocket: the path is \(bytes.count) bytes, above the \(room) a Unix socket's path holds; not bound: \(p)")
            return fd
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() where i < buf.count - 1 { buf[i] = b }
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(r, 0, "bind \(p): errno \(errno)")
        return fd
    }

    private func token(_ line: String, _ key: String) -> String? {
        for t in line.split(separator: " ") where t.hasPrefix("\(key)=") { return String(t.dropFirst(key.count + 1)) }
        return nil
    }

    /// A 1 GiB sparse file at `p` holding `head` first (no disk blocks past it).
    private func sparse(_ p: String, head: Data = Data()) throws {
        try? FileManager.default.removeItem(atPath: p)
        try head.write(to: URL(fileURLWithPath: p))
        XCTAssertEqual(truncate(p, off_t(1) << 30), 0)
    }

    /// A 0.25 GiB budget whose footprint reads 0 (only the file's own bytes can break it).
    private func quarterGiB(_ f: HandlerFixture) {
        f.handler.memoryBudget = DaemonMemoryBudget(budgetBytes: 256 << 20, source: "--mem-budget-gb", footprint: { 0 })
    }

    private func tiled(_ name: String, wal: DagDBWAL.Appender? = nil) throws -> (f: HandlerFixture, dir: String) {
        let f = try HandlerFixture(side: 44, dataRoot: root, wal: wal, maxRank: 64)
        try TiledFixture.populate(engine: f.handler.engine, grid: f.grid, side: 44)
        return (f, root + "/" + name)
    }

    private func tileDir(_ name: String, _ i: Int) throws -> String {
        let m = try TiledGraphFiles.readManifest(dataRoot: root, name: name)
        return TiledGraphFiles.tileDirectory(dataRoot: root, name: name, entry: m.tiles[i])
    }

    // MARK: Non-regular targets

    /// SAVE, SAVE COMPRESSED and SAVE JSON onto a FIFO, a Unix socket and a symbolic link: each refused by name,
    /// the target still what it was (an earlier rename replaced the FIFO and the socket; an older SAVE JSON did too).
    func testA3AWriterRefusesANonRegularTargetAndLeavesItInPlace() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        try Data("real".utf8).write(to: URL(fileURLWithPath: root + "/real.dags"))
        for (verb, suffix) in [("SAVE", ""), ("SAVE", " COMPRESSED"), ("SAVE JSON", "")] {
            let tag = (verb + suffix).replacingOccurrences(of: " ", with: "")
            let fifo = root + "/\(tag).f", sock = root + "/\(tag).s", lnk = root + "/\(tag).l"
            XCTAssertEqual(mkfifo(fifo, 0o600), 0)
            let sfd = bindSocket(sock)
            defer { close(sfd) }
            try FileManager.default.createSymbolicLink(atPath: lnk, withDestinationPath: root + "/real.dags")
            for (p, k) in [(fifo, S_IFIFO), (sock, S_IFSOCK), (lnk, S_IFLNK)] {
                let r = f.handler.handle("\(verb) \(p)\(suffix)")
                XCTAssertTrue(r.hasPrefix("ERROR"), "\(verb)\(suffix) onto \(p): \(r)")
                XCTAssertEqual(kind(p), k, "\(verb)\(suffix): the target \(p) is still what it was (\(r))")
            }
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: root + "/real.dags")), Data("real".utf8))
    }

    // MARK: Admission on the true size (each site: a 1 GiB sparse file under a 0.25 GiB budget is refused out_of_budget)

    func testA3ABackupDiffBodyIsAdmittedOnItsTrueSize() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        let bk = root + "/bk"
        XCTAssertTrue(f.handler.handle("BACKUP INIT \(bk)").hasPrefix("OK BACKUP_INIT"))
        XCTAssertTrue(f.handler.handle("SET 1 TRUTH 1").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("BACKUP APPEND \(bk)").hasPrefix("OK BACKUP_APPEND"))
        let d = bk + "/00001.diff"
        let head = try Data(contentsOf: URL(fileURLWithPath: d)).prefix(16)
        try sparse(d, head: Data(head))
        quarterGiB(f)
        let r = f.handler.handle("BACKUP RESTORE \(bk)")
        XCTAssertTrue(r.contains("out_of_budget") && r.contains("00001.diff"), r)
    }

    func testA3ATilesMetaIsAdmittedOnItsTrueSizeAtEachReadSite() throws {
        // TILED TICK (the ghosted load), TILED SELECT (the query load), TILED OPEN's recovery of a torn tile.
        for (site, name) in [("tick", "gt"), ("select", "gs"), ("open-recovery", "go")] {
            let (f, dir) = try tiled(name)
            XCTAssertTrue(f.handler.handle("SAVE TILED \(dir) 5,11,17").hasPrefix("OK SAVE TILED"), site)
            let t0 = try tileDir(name, 0)
            if site == "open-recovery" {
                try Data("TILE_FLUSH_BEGIN 0 1 rank\n".utf8).write(to: URL(fileURLWithPath: t0 + "/flush.wal"))
            }
            var id = ""
            if site != "open-recovery" {
                let o = f.handler.handle("TILED OPEN \(dir) 4")
                XCTAssertTrue(o.hasPrefix("OK TILED OPEN id="), "\(site): \(o)")
                id = token(o, "id") ?? "none"
            }
            try sparse(t0 + "/meta.json")
            quarterGiB(f)
            let r: String
            switch site {
            case "tick": r = f.handler.handle("TILED TICK \(id) 1")
            case "select": r = f.handler.handle("TILED SELECT \(id) 1 0 100")
            default: r = f.handler.handle("TILED OPEN \(dir) 4")
            }
            XCTAssertTrue(r.contains("out_of_budget") && r.contains("meta.json"), "\(site): \(r)")
        }
    }

    func testA3AHaloStripIsAdmittedOnItsTrueSize() throws {
        let (f, dir) = try tiled("gh")
        XCTAssertTrue(f.handler.handle("SAVE TILED \(dir) 5,11,17").hasPrefix("OK SAVE TILED"))
        // K = 1: one tile resident at a time, so a tick sources its ghosts from the committed strips on disk.
        let o = f.handler.handle("TILED OPEN \(dir) 1")
        let id = token(o, "id") ?? "none"
        // SYNC: tick 2 sources its ghosts from the parity-1 strips tick 1 committed.
        XCTAssertTrue(f.handler.handle("TILED TICK \(id) 1 SYNC").hasPrefix("OK TILED TICK"))
        var planted = 0
        for i in 0..<4 {
            let p = try tileDir("gh", i) + "/halo_lower.1.bin"
            if FileManager.default.fileExists(atPath: p) { try sparse(p); planted += 1 }
        }
        XCTAssertGreaterThan(planted, 0, "the first tick wrote parity-1 strips")
        quarterGiB(f)
        let r = f.handler.handle("TILED TICK \(id) 1 SYNC")
        XCTAssertTrue(r.contains("out_of_budget") && r.contains("halo_lower.1.bin"), r)
    }

    // MARK: Live files (the live WAL inside a multi-file writer's output: refused, and a replay recovers the log)

    private func recovered(_ walPath: String, side: Int, _ label: String) {
        do {
            let g = try HandlerFixture(side: side, dataRoot: root, maxRank: side == 44 ? 64 : 8)
            _ = try DagDBWAL.replay(engine: g.handler.engine, nodeCount: g.handler.nodeCount, path: walPath, wholeLog: true)
            XCTAssertEqual(g.handler.handle("GET 2 TRUTH"), "OK GET node=2 truth=1", "\(label): the logged state recovers")
        } catch {
            XCTFail("\(label): the log does not replay: \(error)")
        }
    }

    func testA3AMultiFileWriterRefusesTheLiveWALAsATargetAndTheLogRecovers() throws {
        let cases: [(label: String, dir: String, wal: String, cmd: String)] = [
            ("EXPORT MORTON", "m", "rank.bin", "EXPORT MORTON \(root!)/m"),
            ("SAVE CSV", "c", "nodes.csv", "SAVE CSV \(root!)/c"),
            ("BACKUP INIT (the base)", "b", "base.dags", "BACKUP INIT \(root!)/b"),
            ("BACKUP INIT (an old diff it removes)", "b2", "00007.diff", "BACKUP INIT \(root!)/b2"),
        ]
        for c in cases {
            try FileManager.default.createDirectory(atPath: root + "/" + c.dir, withIntermediateDirectories: true)
            let walPath = root + "/\(c.dir)/\(c.wal)"
            let f = try HandlerFixture(side: 4, dataRoot: root, wal: try DagDBWAL.Appender(path: walPath, nodeCount: 16))
            XCTAssertTrue(f.handler.handle("SET 2 TRUTH 1").hasPrefix("OK"), c.label)
            let r = f.handler.handle(c.cmd)
            XCTAssertTrue(r.hasPrefix("ERROR") && r.contains("write-ahead log"), "\(c.label): refused by name: \(r)")
            recovered(walPath, side: 4, c.label)
        }
        // SAVE TILED: the log inside the world directory a swap would move aside and remove.
        try FileManager.default.createDirectory(atPath: root + "/w", withIntermediateDirectories: true)
        let walPath = root + "/w/d.wal"
        let (f, dir) = try tiled("w", wal: try DagDBWAL.Appender(path: walPath, nodeCount: 44 * 44))
        XCTAssertTrue(f.handler.handle("SET 2 TRUTH 1").hasPrefix("OK"))
        let r = f.handler.handle("SAVE TILED \(dir) 5,11,17")
        XCTAssertTrue(r.hasPrefix("ERROR") && r.contains("write-ahead log"), "SAVE TILED: refused by name: \(r)")
        recovered(walPath, side: 44, "SAVE TILED")
    }

    // MARK: A restore with no manifest says so

    func testA3ABackupRestoreOfABaseWithNoManifestSaysUnverified() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        let bk = root + "/bk"
        XCTAssertTrue(f.handler.handle("BACKUP INIT \(bk)").hasPrefix("OK BACKUP_INIT"))
        let verified = f.handler.handle("BACKUP RESTORE \(bk)")
        XCTAssertTrue(verified.hasPrefix("OK BACKUP_RESTORE") && !verified.contains("unverified"), verified)
        XCTAssertEqual(unlink(bk + "/base.dags.sha256"), 0)
        let r = f.handler.handle("BACKUP RESTORE \(bk)")
        XCTAssertTrue(r.hasPrefix("OK BACKUP_RESTORE") && Reply.withoutVolatile(r).hasSuffix("; unverified: no manifest"), r)
    }
}

// MARK: - The WAL appender's identity check (`found`: it uses the file-containment API, so it builds only with it)

final class EngineFILE1A3FileTests: XCTestCase {
    private var base: String!
    private var root: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment["DAGDB_TEST_SCRATCH"] ?? ""
        let dir = env.isEmpty ? NSTemporaryDirectory() : env
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        base = DaemonFile.canonicalRoot(dir)! + "/a3f-" + String(UUID().uuidString.prefix(8))
        root = base + "/root"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let b = base { try? FileManager.default.removeItem(atPath: b) }
    }

    /// A log swapped in after the replay read the old one is refused by the appender (its device and
    /// inode are not the replayed file's); an earlier build read the new file and appended to a log it never replayed.
    func testA3TheAppenderRefusesALogSwappedBetweenReplayAndAppend() throws {
        let p = root + "/d.wal", q = root + "/other.wal"
        do { let w = try DagDBWAL.Appender(path: p, nodeCount: 16); _ = try w.setTruth(node: 1, value: 1) }
        let f = try HandlerFixture(side: 4, dataRoot: root)
        let r = try DagDBWAL.replay(engine: f.handler.engine, nodeCount: 16, path: p, wholeLog: true)
        XCTAssertNotNil(r.found)
        do { let w = try DagDBWAL.Appender(path: q, nodeCount: 16); _ = try w.setTruth(node: 3, value: 1) }
        XCTAssertEqual(rename(q, p), 0)
        let before = try Data(contentsOf: URL(fileURLWithPath: p))
        XCTAssertThrowsError(try DagDBWAL.Appender(path: p, nodeCount: 16, found: r.found)) {
            XCTAssertTrue("\($0)".contains("not the file the replay read"), "\($0)")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: p)), before, "nothing appended to the swapped-in log")
    }
}

// MARK: - Rename targets, live files and true-size reads, at the helper (their own API)

final class EngineFILE1A3HelperTests: XCTestCase {
    private var base: String!
    private var root: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment["DAGDB_TEST_SCRATCH"] ?? ""
        let dir = env.isEmpty ? NSTemporaryDirectory() : env
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        base = DaemonFile.canonicalRoot(dir)! + "/a3h-" + String(UUID().uuidString.prefix(8))
        root = base + "/root"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        #if DEBUG || DAGDB_FAULT_INJECTION
        DagDBWAL.replayAfterReadForTesting = nil
        #endif
        if let b = base { try? FileManager.default.removeItem(atPath: b) }
    }

    /// What a rename onto a name would replace: nothing or a regular single-link file passes; a device,
    /// a FIFO, a socket, a symbolic link and a directory are refused by name (a device node cannot be made
    /// without root, so /dev/null stands for it, outside any root).
    func testA3TheRenameTargetCheckRefusesEveryNonRegularKindByName() throws {
        XCTAssertEqual(DaemonFile.renameTargetRefusal("/dev/null").map { "\($0)" }, "EFTYPE (errno 79) path=\"/dev/null\": a character device, not a regular file")
        let fifo = root + "/f", lnk = root + "/l", dir = root + "/d", reg = root + "/r"
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        try FileManager.default.createSymbolicLink(atPath: lnk, withDestinationPath: "/dev/null")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: reg))
        XCTAssertEqual(DaemonFile.renameTargetRefusal(fifo), .notRegular(path: fifo, kind: "fifo"))
        XCTAssertEqual(DaemonFile.renameTargetRefusal(lnk), .link(path: lnk))
        XCTAssertEqual(DaemonFile.renameTargetRefusal(dir), .notRegular(path: dir, kind: "directory"))
        XCTAssertNil(DaemonFile.renameTargetRefusal(reg))
        XCTAssertNil(DaemonFile.renameTargetRefusal(root + "/absent"))
        // The atomic writer asks it: a FIFO at the target is refused and stays a FIFO.
        XCTAssertThrowsError(try DaemonFile.atomicWrite(Data("y".utf8), to: fifo)) { XCTAssertEqual("\($0)", "EFTYPE (errno 79) path=\"\(fifo)\": a fifo, not a regular file") }
        var st = stat()
        XCTAssertEqual(lstat(fifo, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFIFO)
    }

    /// A reserved (live) file is refused by every writer's door, its owner excepted, and a directory
    /// holding one is refused to a writer that would replace the directory.
    func testA3TheDaemonsLiveFilesAreRefusedToEveryWriterButTheirOwner() throws {
        let p = root + "/live.wal", tmp = root + "/x.dags.tmp"
        try Data("live".utf8).write(to: URL(fileURLWithPath: p))
        try Data("t".utf8).write(to: URL(fileURLWithPath: tmp))
        let what = "the daemon's live write-ahead log (DAGDB_WAL)"
        let want = "EBUSY (errno 16) path=\"\(p)\": \(what); no writer of this daemon creates, replaces, truncates or removes it"
        try DaemonFile.$reserved.withValue([p: what, tmp: what]) {
            XCTAssertThrowsError(try DaemonFile.openForWrite(p, create: false, append: true)) { XCTAssertEqual("\($0)", want) }
            XCTAssertThrowsError(try DaemonFile.atomicWrite(Data("x".utf8), to: p)) { XCTAssertEqual("\($0)", want) }
            XCTAssertThrowsError(try DaemonFile.createTemporary(tmp)) { XCTAssertTrue("\($0)".hasPrefix("EBUSY (errno 16) path=\"\(tmp)\""), "\($0)") }
            XCTAssertEqual(DaemonFile.reservedInside(root), .reserved(path: p, what: what))
            XCTAssertNil(DaemonFile.reservedInside(root + "/sub"))
            let fd = try DaemonFile.openForWrite(p, create: false, append: true, own: true)
            close(fd)
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: p)), Data("live".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: tmp)), Data("t".utf8), "a reserved name is never unlinked as a stale temporary")
    }

    /// `readAdmitted` asks the bound admission on the file's true size before a byte is read; unbound, it reads.
    func testA3ReadAdmittedAsksTheBoundAdmissionOnTheTrueSize() throws {
        let p = root + "/big.json"
        FileManager.default.createFile(atPath: p, contents: nil)
        XCTAssertEqual(truncate(p, off_t(1) << 30), 0)
        var asked: [Int] = []
        let refuse: (Int, String) -> String? = { n, what in asked.append(n); return "ERROR out_of_budget: test (\(what))" }
        XCTAssertThrowsError(try DaemonFile.$admission.withValue(refuse) { try DaemonFile.readAdmitted(p) }) {
            XCTAssertEqual("\($0)", "ERROR out_of_budget: test (\"\(p)\": the file's 1073741824 B, read once)")
        }
        XCTAssertEqual(asked, [1 << 30])
        XCTAssertEqual(try DaemonFile.readAdmitted(p, .prefix(8)).count, 8, "unbound: read as before")
    }

    #if DEBUG || DAGDB_FAULT_INJECTION
    /// The replay's identity is the descriptor's: a log swapped in after the replay's read (inside the
    /// replay, through the seam) is still told apart from the one read, and the appender refuses it (by the
    /// path's stat after the read, an earlier build took the new file for the one replayed and appended to it).
    func testA3TheReplaysIdentityIsTheDescriptorsNotThePaths() throws {
        let p = root + "/d.wal", q = root + "/other.wal"
        do { let w = try DagDBWAL.Appender(path: p, nodeCount: 16); _ = try w.setTruth(node: 1, value: 1) }
        do { let w = try DagDBWAL.Appender(path: q, nodeCount: 16); _ = try w.setTruth(node: 3, value: 1) }
        DagDBWAL.replayAfterReadForTesting = { path in _ = rename(q, path) }
        let f = try HandlerFixture(side: 4, dataRoot: root)
        let r = try DagDBWAL.replay(engine: f.handler.engine, nodeCount: 16, path: p, wholeLog: true)
        DagDBWAL.replayAfterReadForTesting = nil
        let before = try Data(contentsOf: URL(fileURLWithPath: p))
        XCTAssertThrowsError(try DagDBWAL.Appender(path: p, nodeCount: 16, found: r.found)) {
            XCTAssertTrue("\($0)".contains("not the file the replay read"), "\($0)")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: p)), before)
    }
    #endif
}

// MARK: - The boot sweep's live set and marker, every temporary marked, distinct paths

final class EngineFILE1A4Tests: XCTestCase {
    private var base: String!
    private var root: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment["DAGDB_TEST_SCRATCH"] ?? ""
        let dir = env.isEmpty ? NSTemporaryDirectory() : env
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        base = DaemonFile.canonicalRoot(dir)! + "/a4-" + String(UUID().uuidString.prefix(8))
        root = base + "/root"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let b = base { try? FileManager.default.removeItem(atPath: b) }
    }

    private func names(_ dir: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() }
    private func aged(_ p: String) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: p)
    }

    /// Every temporary the daemon creates carries its marker, so the sweep can take what a crash left
    /// and nothing else: SAVE's (seen at its tmpWritten step) and the tiled writer's (seen mid-write) are
    /// `.<name>.dagdb-tmp-<pid>-<n>`, never `<name>.tmp`.
    func testA4EveryTemporaryCarriesTheDaemonsMarker() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        var seenSave: [String] = []
        _ = try DaemonFile.withRoot(root) {
            try DagDBSnapshot.save(engine: f.handler.engine, nodeCount: f.handler.nodeCount, gridW: 4, gridH: 4,
                                   tickCount: 0, path: root + "/m.dags",
                                   stepHook: { step in if step == .tmpWritten { seenSave = self.names(self.root) } })
        }
        XCTAssertEqual(seenSave.filter { $0.hasPrefix(".m.dags.dagdb-tmp-\(getpid())-") }.count, 1, "\(seenSave)")
        XCTAssertTrue(seenSave.allSatisfy { !$0.hasSuffix(".tmp") }, "\(seenSave)")
        var seenTiled: [String] = []
        try DaemonFile.withRoot(root) {
            try TiledGraphFiles.writeFileAtomically(Data("{\"a\":1}".utf8), to: root + "/x.json", mid: { seenTiled = self.names(self.root) })
        }
        XCTAssertEqual(seenTiled.filter { $0.hasPrefix(".x.json.dagdb-tmp-\(getpid())-") }.count, 1, "\(seenTiled)")
        XCTAssertTrue(seenTiled.allSatisfy { !$0.hasSuffix(".tmp") }, "\(seenTiled)")
        XCTAssertEqual(names(root).filter { $0.contains(".dagdb-tmp-") }, [], "none left after the writes")
    }

    /// The sweep computes the live set first (each configured file and what it resolves to) and removes
    /// none of it, nor a stage holding one, whatever the name; it removes only marked names of a dead writer;
    /// a generic `*.tmp` an older build's writer would have used is left in place and named.
    func testA4TheSweepKeepsTheLiveSetAndRemovesOnlyMarkedNames() throws {
        let fm = FileManager.default
        let walMeta = root + "/meta.json.tmp", walMarked = root + "/.w.dagdb-tmp-99999999-1"
        let snapTmp = root + "/auto.tmp", linked = root + "/real.dags", alias = root + "/alias.dags"
        let stage = root + "/.dagdb-stage-99999999-2", inStage = stage + "/live.wal"
        let staleMarked = root + "/.x.json.dagdb-tmp-99999999-3", oldMeta = root + "/t/meta.json.tmp"
        try fm.createDirectory(atPath: stage, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/t", withIntermediateDirectories: true)
        for p in [walMeta, walMarked, linked, inStage, staleMarked, oldMeta] { try Data("x".utf8).write(to: URL(fileURLWithPath: p)) }
        try Data(DagDBSnapshot.magic + [0, 0]).write(to: URL(fileURLWithPath: snapTmp))
        try fm.createSymbolicLink(atPath: alias, withDestinationPath: linked)
        for p in [walMeta, walMarked, snapTmp, staleMarked, oldMeta] { try aged(p) }
        // A marked live file under a link: the autosave target named through `alias` resolves to `real.dags`.
        let markedReal = root + "/.r.dagdb-tmp-99999999-4"
        try Data("y".utf8).write(to: URL(fileURLWithPath: markedReal)); try aged(markedReal)
        try fm.createSymbolicLink(atPath: root + "/autosave.dags", withDestinationPath: markedReal)
        let line = DagDBStartup.sweepStages(root: root, live: [walMeta, snapTmp, walMarked, inStage, root + "/autosave.dags"])
        for p in [walMeta, walMarked, snapTmp, inStage, markedReal, oldMeta] {
            XCTAssertTrue(fm.fileExists(atPath: p), "\(p) kept; \(line)")
        }
        XCTAssertFalse(fm.fileExists(atPath: staleMarked), line)
        XCTAssertTrue(line.contains("removed 1 stale stage item(s)") && line.contains(".x.json.dagdb-tmp-99999999-3"), line)
        XCTAssertTrue(line.contains(".dagdb-stage-99999999-2 (it holds a live file of this daemon)"), line)
        XCTAssertTrue(line.contains(".w.dagdb-tmp-99999999-1 (a live file of this daemon)"), line)
        XCTAssertTrue(line.contains("left in place 1 *.tmp leftover(s)") && line.contains("t/meta.json.tmp"), line)
        XCTAssertFalse(line.contains("auto.tmp") || line.contains("left in place 2"), "a live file is not a leftover: \(line)")
    }

    /// The configured files must be pairwise distinct, resolved by canonical path, full realpath, and
    /// device and inode; a collision names both flags; DAGDB_STARTUP_LOAD and DAGDB_AUTOSAVE may share one.
    func testA4TwoFlagsNamingOneFileAreRefusedByBoth() throws {
        let wal = root + "/d.wal", snap = root + "/s.dags", shm = root + "/shm", sock = root + "/d.sock"
        for p in [wal, snap] { try Data("x".utf8).write(to: URL(fileURLWithPath: p)) }
        try FileManager.default.createSymbolicLink(atPath: root + "/l.wal", withDestinationPath: wal)
        XCTAssertEqual(link(snap, root + "/h.dags"), 0)
        func check(_ wal: String?, _ snap: String?, _ auto: String?, _ sock: String, _ shm: String) -> String? {
            DagDBStartup.configuredPathCollision([("DAGDB_WAL", wal), ("DAGDB_WAL's era sidecar", wal.map { $0 + DagDBHOOK1Era.suffix }),
                                                  ("DAGDB_STARTUP_LOAD", snap), ("DAGDB_AUTOSAVE", auto),
                                                  ("--socket", sock), ("--shm-file", shm)],
                                                 allowed: [["DAGDB_STARTUP_LOAD", "DAGDB_AUTOSAVE"]])
        }
        XCTAssertNil(check(wal, snap, snap, sock, shm), "distinct, and the round trip allowed")
        XCTAssertEqual(check(wal, snap, nil, sock, wal), "DAGDB_WAL ('\(wal)') and --shm-file ('\(wal)') name one file; each of the daemon's files must be its own")
        XCTAssertTrue(check(wal, snap, nil, snap, shm)?.hasPrefix("DAGDB_STARTUP_LOAD ('\(snap)') and --socket") == true)
        XCTAssertTrue(check(wal, snap, nil, sock, root + "/l.wal")?.contains("and --shm-file ('\(root!)/l.wal')") == true, "through a link")
        XCTAssertTrue(check(wal, snap, nil, root + "/h.dags", shm)?.hasPrefix("DAGDB_STARTUP_LOAD") == true, "a hard link")
        XCTAssertTrue(check(wal, snap, nil, sock, wal + DagDBHOOK1Era.suffix)?.hasPrefix("DAGDB_WAL's era sidecar") == true)
        XCTAssertTrue(check(wal, wal, nil, sock, shm)?.hasPrefix("DAGDB_WAL ('\(wal)') and DAGDB_STARTUP_LOAD") == true)
    }
}
