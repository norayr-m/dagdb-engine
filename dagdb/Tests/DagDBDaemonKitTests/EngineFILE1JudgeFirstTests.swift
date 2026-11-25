import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Reads judge first, then open: the name is resolved and its containment checked before anything is opened, so
/// nothing outside the root is ever opened (a FIFO included); the resolved path is then opened with no link
/// followed, so a link swapped in after the check fails the open; links that stay inside the root still read.
/// Every fixture lives in the test's own folder: `root` is the data root and its sibling `outside` stands for
/// everything else.
final class EngineFILE1JudgeFirstTests: XCTestCase {
    private var base: String!
    private var root: String!
    private var outside: String!
    private let fixed = ": resolves outside DAGDB_DATA_ROOT"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment["DAGDB_TEST_SCRATCH"] ?? ""
        let dir = env.isEmpty ? NSTemporaryDirectory() : env
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        base = DaemonFile.canonicalRoot(dir)! + "/jf-\(UUID().uuidString)"
        root = base + "/root"
        outside = base + "/outside"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        guard let b = base else { return }
        for d in (FileManager.default.subpaths(atPath: outside) ?? []) { chmod(outside + "/" + d, 0o755) }
        try? FileManager.default.removeItem(atPath: b)
    }

    /// A read through an in-root link to an outside FIFO is refused at once with the outside text, and the FIFO is
    /// never opened: a writer blocked in open(O_WRONLY) on it would return the moment any reader opened it, and it
    /// is still blocked after the refusal (until the test itself opens the FIFO to release it).
    func testAReadThroughALinkToAnOutsideFIFONeverOpensIt() throws {
        let fifo = outside + "/pipe", link = root + "/lp"
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: fifo)
        let opened = DispatchSemaphore(value: 0)
        let writer = Thread {
            let fd = open(fifo, O_WRONLY)              // blocks until a reader opens the FIFO
            if fd >= 0 { close(fd) }
            opened.signal()
        }
        writer.start()
        Thread.sleep(forTimeInterval: 0.3)             // the writer is now blocked in open
        let t0 = Date()
        try DaemonFile.withRoot(root) {
            XCTAssertThrowsError(try DaemonFile.read(link)) { XCTAssertEqual("\($0)", "EPERM (errno 1) path=\"\(link)\"" + fixed) }
            XCTAssertThrowsError(try DaemonFile.Reader(link)) { XCTAssertEqual("\($0)", "EPERM (errno 1) path=\"\(link)\"" + fixed) }
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0, "refused at once")
        XCTAssertEqual(opened.wait(timeout: .now() + 0.5), .timedOut, "the FIFO was opened by the read")
        // Release the writer.
        let rfd = open(fifo, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(rfd, 0)
        XCTAssertEqual(opened.wait(timeout: .now() + 5), .success)
        close(rfd)
    }

    /// A component of the judged path swapped for a link to the outside between the judgement and the open: the
    /// open of the resolved path follows no link, so it fails (ELOOP) and the outside file is never opened.
    func testALinkSwappedInAfterTheJudgementFailsTheOpen() throws {
        try FileManager.default.createDirectory(atPath: root + "/d", withIntermediateDirectories: false)
        try Data(repeating: 1, count: 16).write(to: URL(fileURLWithPath: root + "/d/x.bin"))
        try Data(repeating: 2, count: 16).write(to: URL(fileURLWithPath: outside + "/x.bin"))
        let name = root + "/d/x.bin"
        try DaemonFile.withRoot(root) {
            let real = try DaemonFile.judgedForRead(name, directory: false)
            XCTAssertEqual(real, name)
            XCTAssertEqual(rename(root + "/d", root + "/d.old"), 0)
            try FileManager.default.createSymbolicLink(atPath: root + "/d", withDestinationPath: outside)
            XCTAssertThrowsError(try DaemonFile.openForRead(real!, as: name, directory: false, judged: true)) {
                XCTAssertEqual("\($0)", "ELOOP (errno 62) path=\"\(name)\": open failed")
            }
            // A fresh read judges the swapped name and refuses it as outside, before any open.
            XCTAssertThrowsError(try DaemonFile.read(name)) { XCTAssertEqual("\($0)", "EPERM (errno 1) path=\"\(name)\"" + fixed) }
        }
    }

    /// The same bytes whatever lies outside: a read through an in-root link to an outside file (there, gone, in a
    /// folder that cannot be searched), and a LOAD whose sidecar is such a link (there or gone: never "absent").
    func testAnOutsideReadIsRefusedTheSameWhateverLiesOutside() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        let c = outside + "/c"
        try FileManager.default.createDirectory(atPath: c, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/d", withIntermediateDirectories: false)
        XCTAssertTrue(f.handler.handle("SAVE \(root!)/d/p.dags").hasPrefix("OK SAVE"))
        try FileManager.default.moveItem(atPath: root + "/d/p.dags.sha256", toPath: c + "/side")
        try FileManager.default.createSymbolicLink(atPath: root + "/d/p.dags.sha256", withDestinationPath: c + "/side")
        try FileManager.default.createSymbolicLink(atPath: root + "/lf", withDestinationPath: c + "/secret.bin")
        try Data(repeating: 7, count: 64).write(to: URL(fileURLWithPath: c + "/secret.bin"))
        func now() -> [String] {
            let r = DaemonFile.withRoot(root) { () -> String in
                do { return "read \(try DaemonFile.read(root + "/lf").count)" } catch { return "\(error)" }
            }
            return [r, f.handler.handle("LOAD \(root!)/d/p.dags")]
        }
        let present = now()
        try FileManager.default.removeItem(atPath: c + "/secret.bin")
        let side = try Data(contentsOf: URL(fileURLWithPath: c + "/side"))
        try FileManager.default.removeItem(atPath: c + "/side")
        let absent = now()
        try Data(repeating: 7, count: 64).write(to: URL(fileURLWithPath: c + "/secret.bin"))
        try side.write(to: URL(fileURLWithPath: c + "/side"))
        XCTAssertEqual(chmod(c, 0), 0)
        let unsearchable = now()
        XCTAssertEqual(chmod(c, 0o755), 0)
        XCTAssertEqual(present[0], "EPERM (errno 1) path=\"\(root!)/lf\"" + fixed)
        XCTAssertTrue(present[1].hasPrefix("ERROR io: load: "), present[1])
        XCTAssertTrue(present[1].contains("EPERM (errno 1) path=\"\(root!)/d/p.dags.sha256\"" + fixed), present[1])
        XCTAssertEqual(absent, present)
        XCTAssertEqual(unsearchable, present)
        for line in present + absent + unsearchable { XCTAssertFalse(line.contains(outside), line) }
    }

    /// In-root links still read: a chain of links, a relative target through '..', an absolute target through a
    /// self-link, a linked folder in the middle, and a directory listing through a linked folder.
    func testInRootLinksStillRead() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/d/sub", withIntermediateDirectories: true)
        try Data(repeating: 5, count: 32).write(to: URL(fileURLWithPath: root + "/d/real.bin"))
        try fm.createSymbolicLink(atPath: root + "/b", withDestinationPath: "d/real.bin")
        try fm.createSymbolicLink(atPath: root + "/a", withDestinationPath: "b")
        try fm.createSymbolicLink(atPath: root + "/d/sub/up", withDestinationPath: "../real.bin")
        try fm.createSymbolicLink(atPath: root + "/self", withDestinationPath: ".")
        try fm.createSymbolicLink(atPath: root + "/abs", withDestinationPath: root + "/self/d/real.bin")
        try fm.createSymbolicLink(atPath: root + "/ld", withDestinationPath: "d")
        try DaemonFile.withRoot(root) {
            for p in ["/a", "/d/sub/up", "/abs", "/ld/real.bin", "/self/self/ld/sub/up"] {
                XCTAssertEqual(try DaemonFile.read(root + p), Data(repeating: 5, count: 32), p)
            }
            XCTAssertEqual(try DaemonFile.listDirectory(root + "/ld"), ["real.bin", "sub"])
        }
        let f = try HandlerFixture(side: 4, dataRoot: root)
        XCTAssertTrue(f.handler.handle("SAVE \(root!)/d/s.dags").hasPrefix("OK SAVE"))
        try fm.createSymbolicLink(atPath: root + "/sl", withDestinationPath: "ld/s.dags")
        XCTAssertTrue(f.handler.handle("LOAD \(root!)/sl").hasPrefix("OK LOAD"))
    }
}
