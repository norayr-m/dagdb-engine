import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// B3 of the backup rank-width contract: the same fingerprint as the library
/// test, driven entirely over the DSL, plus the reply fields the contract adds
/// (`rank_bytes` on RESTORE, `format` on APPEND and INFO) and the refusal a
/// format-1 chain earns on the wire.
final class BackupRankWidthDaemonTests: XCTestCase {

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-backup-dsl-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    /// The retired format-1 layout, written by hand: old header, rank segment
    /// at 4 bytes per node. The library can no longer produce one.
    private func writeLegacyDiff(dir: String, nodeCount n: Int, seq: Int) throws {
        var out = Data()
        out.append(contentsOf: DagDBBackup.diffMagic)
        for v in [DagDBBackup.diffVersionLegacy, UInt32(n), UInt32(seq)] {
            var x = v
            out.append(Data(bytes: &x, count: 4))
        }
        for size in [n * 4, n, n, n * 4, n * 4, n * 6 * 4] {
            let body = DagDBSnapshot.zlibCompress(Data(count: size))
            var sz = UInt32(body.count)
            out.append(Data(bytes: &sz, count: 4))
            out.append(body)
        }
        try out.write(to: URL(fileURLWithPath: String(format: "\(dir)/%05d.diff", seq)))
    }

    /// Reply lines carry a wall-clock `elapsed=` field. Compare everything
    /// around it exactly.
    private func assertReply(
        _ actual: String, head: String, tail: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let parts = actual.components(separatedBy: " elapsed=")
        guard parts.count == 2, let msEnd = parts[1].range(of: "ms") else {
            XCTFail("reply has no elapsed field: \(actual)", file: file, line: line)
            return
        }
        XCTAssertEqual(parts[0], head, file: file, line: line)
        XCTAssertEqual(
            String(parts[1][msEnd.upperBound...]), tail, file: file, line: line)
    }

    private var legacySentence: String {
        "backup format 1 carries 4 of 8 rank bytes per node and no " +
        "registers, back edges, weights, activation or node values; " +
        "cannot restore ranks for nodes N/2..<N; re-create the backup"
    }

    func testBackupRoundTripOverDSLKeepsEveryRank() throws {
        let f = try HandlerFixture(side: 8)
        let h = f.handler
        let n = h.nodeCount
        XCTAssertEqual(n, 64)
        let dir = tmpDir! + "chain"

        XCTAssertTrue(
            h.handle("BACKUP INIT \(dir)").hasPrefix("OK BACKUP_INIT base_bytes="),
            "INIT reply")

        XCTAssertEqual(h.handle("SET 0 RANK 3"),   "OK SET node=0 rank=3")
        XCTAssertEqual(h.handle("SET 32 RANK 41"), "OK SET node=32 rank=41")
        XCTAssertEqual(h.handle("SET 63 RANK 17"), "OK SET node=63 rank=17")

        let appended = h.handle("BACKUP APPEND \(dir)")
        XCTAssertTrue(appended.hasPrefix("OK BACKUP_APPEND bytes="), appended)
        XCTAssertTrue(
            appended.hasSuffix("/00001.diff format=2"),
            "APPEND reply must end with the diff path then format=2: \(appended)")

        XCTAssertEqual(h.handle("SET 0 RANK 5"),  "OK SET node=0 rank=5")
        XCTAssertEqual(h.handle("SET 32 RANK 6"), "OK SET node=32 rank=6")
        XCTAssertEqual(h.handle("SET 63 RANK 7"), "OK SET node=63 rank=7")

        assertReply(
            h.handle("BACKUP RESTORE \(dir)"),
            head: "OK BACKUP_RESTORE diffs_replayed=1",
            tail: " rank_bytes=\(n * 8) twin=not_covered")

        let rank = h.engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        XCTAssertEqual(rank[0],  3,  "node 0 rank over the wire")
        XCTAssertEqual(rank[32], 41, "node 32 rank over the wire")
        XCTAssertEqual(rank[63], 17, "node 63 rank over the wire")

        let info = h.handle("BACKUP INFO \(dir)")
        XCTAssertTrue(info.hasPrefix("OK BACKUP_INFO base=true base_bytes="), info)
        XCTAssertTrue(
            info.hasSuffix("diffs=1 total_diff_bytes=\(diffBytes(dir)) format=2 twin=not_covered"),
            "INFO reply must end with the diff totals then format=2: \(info)")
    }

    private func diffBytes(_ dir: String) -> Int {
        let fm = FileManager.default
        var total = 0
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".diff") {
            total += (try? fm.attributesOfItem(atPath: dir + "/" + name)[.size] as? Int) ?? 0
        }
        return total
    }

    /// The named refusals reach the wire as their own sentence, not wrapped in
    /// a `backup_restore: …` prefix.
    func testSidecarRefusalReachesTheWire() throws {
        let f = try HandlerFixture(side: 8)
        let h = f.handler
        let dir = tmpDir! + "sidecar"

        XCTAssertTrue(h.handle("BACKUP INIT \(dir)").hasPrefix("OK BACKUP_INIT"))
        XCTAssertEqual(h.handle("SET 32 RANK 41"), "OK SET node=32 rank=41")
        XCTAssertTrue(h.handle("BACKUP APPEND \(dir)").hasPrefix("OK BACKUP_APPEND"))

        try FileManager.default.removeItem(atPath: dir + "/00001.diff.sha256")

        XCTAssertEqual(
            h.handle("BACKUP RESTORE \(dir)"),
            "ERROR io: backup diff 00001.diff has no sha256 sidecar; re-create the backup")
    }

    func testLegacyChainRefusedOverDSLAndNamedByInfo() throws {
        let f = try HandlerFixture(side: 8)
        let h = f.handler
        let dir = tmpDir! + "legacy"

        XCTAssertTrue(h.handle("BACKUP INIT \(dir)").hasPrefix("OK BACKUP_INIT"))
        try writeLegacyDiff(dir: dir, nodeCount: h.nodeCount, seq: 1)

        XCTAssertEqual(
            h.handle("BACKUP RESTORE \(dir)"),
            "ERROR io: \(legacySentence)")
        XCTAssertEqual(
            h.handle("BACKUP APPEND \(dir)"),
            "ERROR io: \(legacySentence)")

        let info = h.handle("BACKUP INFO \(dir)")
        XCTAssertTrue(info.hasPrefix("OK BACKUP_INFO base=true"), info)
        XCTAssertTrue(
            info.hasSuffix("diffs=1 total_diff_bytes=\(diffBytes(dir)) format=1 twin=not_covered caveat=\(legacySentence)"),
            "INFO must name the format and carry the caveat without refusing: \(info)")
    }
}
