import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// A containment refusal names no outside path and depends on nothing outside: for a path that leaves the root,
/// the reply is the same bytes whether the outside target exists or not and whether outside folders can be
/// searched or not. Failures inside the root still name their errno. Every fixture lives in the test's own
/// folder: `root` is the data root and its sibling `outside` stands for everything else.
final class EngineFILE1OutsideTests: XCTestCase {
    private var base: String!
    private var root: String!
    private var outside: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment["DAGDB_TEST_SCRATCH"] ?? ""
        let dir = env.isEmpty ? NSTemporaryDirectory() : env
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        base = DaemonFile.canonicalRoot(dir)! + "/ot-\(UUID().uuidString)"
        root = base + "/root"
        outside = base + "/outside"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        guard let b = base else { return }
        for d in (FileManager.default.subpaths(atPath: outside) ?? []) { chmod(outside + "/" + d, 0o755) }
        chmod(outside, 0o755)
        try? FileManager.default.removeItem(atPath: b)
    }

    private let fixed = ": resolves outside DAGDB_DATA_ROOT"

    /// The replies and refusal texts for every probe, in order, under the outside state as it is now.
    private func replies(_ f: HandlerFixture, _ probes: [String]) -> [String] {
        var out: [String] = []
        for p in probes {
            out.append(f.handler.handle("SAVE \(p)"))
            out.append(f.handler.handle("LOAD \(p)"))
            out.append(DaemonFile.withRoot(root) { DaemonFile.containmentRefusal(p).map { "\($0)" } ?? "nil" })
            out.append(DaemonFile.withRoot(root) { () -> String in
                do { return "contained " + (try DaemonFile.forWrite(p)) } catch { return "\(error)" }
            })
        }
        return out
    }

    /// The outside states: the target there, the target gone, its folder not searchable, its folder gone.
    private func eachOutsideState(_ body: (String) throws -> Void) throws {
        let c = outside + "/c"
        try FileManager.default.createDirectory(atPath: c + "/sub", withIntermediateDirectories: true)
        try Data(repeating: 7, count: 64).write(to: URL(fileURLWithPath: c + "/secret.bin"))
        try Data(repeating: 8, count: 64).write(to: URL(fileURLWithPath: c + "/sub/p.dags"))
        try body("present")
        try FileManager.default.removeItem(atPath: c + "/secret.bin")
        try FileManager.default.removeItem(atPath: c + "/sub")
        try body("absent")
        try FileManager.default.createDirectory(atPath: c + "/sub", withIntermediateDirectories: true)
        try Data(repeating: 7, count: 64).write(to: URL(fileURLWithPath: c + "/secret.bin"))
        XCTAssertEqual(chmod(c, 0), 0)
        try body("unsearchable")
        XCTAssertEqual(chmod(c, 0o755), 0)
        try FileManager.default.removeItem(atPath: c)
        try body("folder gone")
    }

    /// An in-root link to an outside file, and an in-root link to an outside folder followed by further
    /// components: through SAVE, LOAD, the pre-check and the writers' resolution, the same bytes in every outside
    /// state, and no outside path in any of them.
    func testAnOutsideRefusalIsTheSameWhateverLiesOutside() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        try FileManager.default.createSymbolicLink(atPath: root + "/lf", withDestinationPath: outside + "/c/secret.bin")
        try FileManager.default.createSymbolicLink(atPath: root + "/lo", withDestinationPath: "../outside/c")
        let probes = [root + "/lf", root + "/lo/sub/p.dags", root + "/lo/sub/new/x.dags", root + "/lo/secret.bin"]
        var first: [String]? = nil
        try eachOutsideState { state in
            let now = replies(f, probes)
            for line in now { XCTAssertFalse(line.contains(outside), "\(state): \(line)") }
            if let a = first {
                for (x, y) in zip(a, now) { XCTAssertEqual(x, y, "\(state)") }
            } else {
                first = now
            }
        }
        // The forms: the pre-check's refusal and the writers' refusal.
        let a = first ?? []
        XCTAssertEqual(a.count, 16)
        XCTAssertEqual(a.first, "ERROR io: path: \"\(root!)/lf\" outside DAGDB_DATA_ROOT")
        XCTAssertEqual(a[2], "EPERM (errno 1) path=\"\(root!)/lf\"" + fixed)
        XCTAssertEqual(a[3], "ELOOP (errno 62) path=\"\(root!)/lf\": a symbolic link in a path the daemon writes (it follows none)")
        XCTAssertEqual(a[6], "EPERM (errno 1) path=\"\(root!)/lo/sub/p.dags\"" + fixed)
        XCTAssertEqual(a[7], "EPERM (errno 1) path=\"\(root!)/lo/sub/p.dags\"" + fixed)
    }

    /// The root's own ancestors lie on the way to the root but outside it: the root's parent and "/" are refused
    /// for a write, a link to ".." is refused by the pre-check and by a read's judgement, and SAVE TILED of the root
    /// itself (whose stage would sit in the parent) is refused with nothing made in the parent, not even for a
    /// moment (the parent's modification time is unchanged).
    func testTheRootsOwnAncestorsAreOutside() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        try FileManager.default.createSymbolicLink(atPath: root + "/up", withDestinationPath: "..")
        try DaemonFile.withRoot(root) {
            for p in [base!, "/"] {
                XCTAssertThrowsError(try DaemonFile.forWrite(p)) { XCTAssertEqual("\($0)", "EPERM (errno 1) path=\"\(p)\"" + fixed) }
            }
            XCTAssertEqual(DaemonFile.containmentRefusal(root + "/up").map { "\($0)" }, "EPERM (errno 1) path=\"\(root!)/up\"" + fixed)
            XCTAssertThrowsError(try DaemonFile.judgedForRead(root + "/up", directory: true)) {
                XCTAssertEqual("\($0)", "EPERM (errno 1) path=\"\(root!)/up\"" + fixed)
            }
        }
        var before = stat(), after = stat()
        XCTAssertEqual(stat(base, &before), 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: base).sorted()
        let r = f.handler.handle("SAVE TILED \(root!) 1")
        XCTAssertEqual(r, "ERROR io: EPERM (errno 1) path=\"\(base!)\"" + fixed)
        XCTAssertEqual(stat(base, &after), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base).sorted(), names)
        XCTAssertEqual(after.st_mtimespec.tv_sec, before.st_mtimespec.tv_sec, "nothing was made in the parent")
        XCTAssertEqual(after.st_mtimespec.tv_nsec, before.st_mtimespec.tv_nsec, "nothing was made in the parent")
    }

    /// Failures inside the root keep their errno: a component that is a file, a link in the middle whose target
    /// is missing, a folder that cannot be searched.
    func testFailuresInsideTheRootStillNameTheirErrno() throws {
        let f = try HandlerFixture(side: 4, dataRoot: root)
        try Data(count: 8).write(to: URL(fileURLWithPath: root + "/file.bin"))
        try FileManager.default.createSymbolicLink(atPath: root + "/dl", withDestinationPath: "gone")
        try FileManager.default.createDirectory(atPath: root + "/locked/in", withIntermediateDirectories: true)
        let notDir = root + "/file.bin/x.dags", dangling = root + "/dl/x.dags", locked = root + "/locked/in/x.dags"
        XCTAssertEqual(DaemonFile.withRoot(root) { DaemonFile.containmentRefusal(notDir).map { "\($0)" } },
                       "ENOTDIR (errno 20) path=\"\(notDir)\": lstat failed")
        XCTAssertEqual(DaemonFile.withRoot(root) { DaemonFile.containmentRefusal(dangling).map { "\($0)" } },
                       "ENOENT (errno 2) path=\"\(root!)/dl\": realpath failed")
        XCTAssertEqual(chmod(root + "/locked", 0), 0)
        defer { chmod(root + "/locked", 0o755) }
        XCTAssertEqual(DaemonFile.withRoot(root) { DaemonFile.containmentRefusal(locked).map { "\($0)" } },
                       "EACCES (errno 13) path=\"\(root!)/locked/in\": lstat failed")
        XCTAssertEqual(f.handler.handle("SAVE \(locked)"), "ERROR io: path: EACCES (errno 13) path=\"\(root!)/locked/in\": lstat failed")
    }
}
