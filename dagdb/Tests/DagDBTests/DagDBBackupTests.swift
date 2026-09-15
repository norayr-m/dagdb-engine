import XCTest
@testable import DagDB

final class DagDBBackupTests: XCTestCase {

    /// Per-test unique temp dir (Fable review T4 — fixed /tmp names race
    /// when several checkouts run swift test concurrently in one shared dir).
    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-backup-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    private func makeEngine(side: Int) throws -> (DagDBEngine, Int, Int) {
        let grid = try HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        return (engine, side, side)
    }

    private func seed(_ engine: DagDBEngine) {
        let n = engine.nodeCount
        let rank  = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let truth = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let low   = engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high  = engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let nb    = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        for i in 0..<n {
            rank[i] = 0; truth[i] = 0; low[i] = 0; high[i] = 0
            for d in 0..<6 { nb[i * 6 + d] = -1 }
        }
        for i in 1...6 {
            rank[i] = 2; truth[i] = 1
            let lut = LUT6Preset.const1
            low[i]  = UInt32(lut & 0xFFFFFFFF)
            high[i] = UInt32((lut >> 32) & 0xFFFFFFFF)
        }
        rank[7] = 1
        let maj = LUT6Preset.majority6
        low[7]  = UInt32(maj & 0xFFFFFFFF)
        high[7] = UInt32((maj >> 32) & 0xFFFFFFFF)
        for d in 0..<6 { nb[7 * 6 + d] = Int32(1 + d) }
        rank[8] = 0
        let idg = LUT6Preset.identity
        low[8]  = UInt32(idg & 0xFFFFFFFF)
        high[8] = UInt32((idg >> 32) & 0xFFFFFFFF)
        nb[8 * 6 + 0] = 7
    }

    /// Flip one truth bit on node `idx`.
    private func flipTruth(_ engine: DagDBEngine, _ idx: Int) {
        let truth = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: engine.nodeCount)
        truth[idx] ^= 1
    }

    private func buffersEqual(_ a: MTLBuffer, _ b: MTLBuffer, _ bytes: Int) -> Bool {
        return memcmp(a.contents(), b.contents(), bytes) == 0
    }

    private func buffersEqual(_ a: DagDBEngine, _ b: DagDBEngine) -> Bool {
        let n = a.nodeCount
        return buffersEqual(a.rankBuf,       b.rankBuf,       n * 8)  // rank is u64
            && buffersEqual(a.truthStateBuf, b.truthStateBuf, n)
            && buffersEqual(a.nodeTypeBuf,   b.nodeTypeBuf,   n)
            && buffersEqual(a.lut6LowBuf,    b.lut6LowBuf,    n * 4)
            && buffersEqual(a.lut6HighBuf,   b.lut6HighBuf,   n * 4)
            && buffersEqual(a.neighborsBuf,  b.neighborsBuf,  n * 6 * 4)
    }

    private func wipeDir(_ dir: String) {
        _ = try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - Chain lifecycle

    func testInitializeThenRestoreRecoversBaseState() throws {
        let dir = tmpDir! + "dagdb_backup_init"
        wipeDir(dir)

        let (eng1, gw, gh) = try makeEngine(side: 8)
        seed(eng1)

        _ = try DagDBBackup.initializeChain(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 5, dir: dir
        )

        // Fresh engine, restore from chain — should match original.
        let (eng2, _, _) = try makeEngine(side: 8)
        let r = try DagDBBackup.restore(
            engine: eng2, nodeCount: eng2.nodeCount,
            gridW: gw, gridH: gh, dir: dir
        )
        XCTAssertEqual(r.diffsReplayed, 0)
        XCTAssertTrue(buffersEqual(eng1, eng2))
    }

    func testSingleDiffRoundTrip() throws {
        let dir = tmpDir! + "dagdb_backup_one"
        wipeDir(dir)

        let (eng1, gw, gh) = try makeEngine(side: 8)
        seed(eng1)

        _ = try DagDBBackup.initializeChain(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 0, dir: dir
        )

        // Mutate — flip one truth bit.
        flipTruth(eng1, 7)

        // Append diff capturing the mutation.
        let d = try DagDBBackup.appendDiff(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, dir: dir
        )
        XCTAssertTrue(d.diffPath.hasSuffix("00001.diff"))
        XCTAssertGreaterThan(d.diffBytes, 0)

        // Restore into a fresh engine — should match the mutated state.
        let (eng2, _, _) = try makeEngine(side: 8)
        let r = try DagDBBackup.restore(
            engine: eng2, nodeCount: eng2.nodeCount,
            gridW: gw, gridH: gh, dir: dir
        )
        XCTAssertEqual(r.diffsReplayed, 1)
        XCTAssertTrue(buffersEqual(eng1, eng2))
    }

    func testManyDiffsRoundTrip() throws {
        let dir = tmpDir! + "dagdb_backup_many"
        wipeDir(dir)

        let (eng1, gw, gh) = try makeEngine(side: 8)
        seed(eng1)

        _ = try DagDBBackup.initializeChain(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 0, dir: dir
        )

        // Ten mutations, one diff each.
        for k in 0..<10 {
            flipTruth(eng1, (k % 5) + 1)
            _ = try DagDBBackup.appendDiff(
                engine: eng1, nodeCount: eng1.nodeCount,
                gridW: gw, gridH: gh, dir: dir
            )
        }

        let chain = try DagDBBackup.info(dir: dir)
        XCTAssertEqual(chain.diffCount, 10)

        let (eng2, _, _) = try makeEngine(side: 8)
        _ = try DagDBBackup.restore(
            engine: eng2, nodeCount: eng2.nodeCount,
            gridW: gw, gridH: gh, dir: dir
        )
        XCTAssertTrue(buffersEqual(eng1, eng2))
    }

    func testDiffsAreSmall() throws {
        // A single truth-bit flip should produce a tiny diff. Compare against
        // the raw (uncompressed) engine state size, not the already-compressed
        // base — both compress well on sparse data, so the ratio of diff to
        // compressed base isn't meaningful.
        let dir = tmpDir! + "dagdb_backup_size"
        wipeDir(dir)

        let (eng, gw, gh) = try makeEngine(side: 16)  // 256-node grid
        seed(eng)

        _ = try DagDBBackup.initializeChain(
            engine: eng, nodeCount: eng.nodeCount,
            gridW: gw, gridH: gh, tickCount: 0, dir: dir
        )

        flipTruth(eng, 4)
        let diff = try DagDBBackup.appendDiff(
            engine: eng, nodeCount: eng.nodeCount,
            gridW: gw, gridH: gh, dir: dir
        )

        let rawStateBytes = 38 * eng.nodeCount  // v2 body: ~10 KB for 256 nodes
        let ratio = Double(diff.diffBytes) / Double(rawStateBytes)
        // One-bit flip should compress to well under 5% of raw state.
        XCTAssertLessThan(ratio, 0.05, "diff \(diff.diffBytes) vs raw \(rawStateBytes)")
    }

    func testCompactCollapsesChain() throws {
        let dir = tmpDir! + "dagdb_backup_compact"
        wipeDir(dir)

        let (eng1, gw, gh) = try makeEngine(side: 8)
        seed(eng1)

        _ = try DagDBBackup.initializeChain(
            engine: eng1, nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, tickCount: 0, dir: dir
        )
        for k in 0..<5 {
            flipTruth(eng1, k + 1)
            _ = try DagDBBackup.appendDiff(
                engine: eng1, nodeCount: eng1.nodeCount,
                gridW: gw, gridH: gh, dir: dir
            )
        }

        // Compact: replay into a throwaway engine, save new base, drop diffs.
        let c = try DagDBBackup.compact(
            nodeCount: eng1.nodeCount,
            gridW: gw, gridH: gh, dir: dir
        )
        XCTAssertEqual(c.priorDiffCount, 5)

        let after = try DagDBBackup.info(dir: dir)
        XCTAssertTrue(after.baseExists)
        XCTAssertEqual(after.diffCount, 0)

        // Restore from the compacted chain — still matches the mutated state.
        let (eng2, _, _) = try makeEngine(side: 8)
        _ = try DagDBBackup.restore(
            engine: eng2, nodeCount: eng2.nodeCount,
            gridW: gw, gridH: gh, dir: dir
        )
        XCTAssertTrue(buffersEqual(eng1, eng2))
    }

    // MARK: - B1 · rank width fingerprint (BACKUP_RANK_WIDTH_GATES_FROZEN)

    /// A restore must reproduce the ranks it was asked to keep, node for node,
    /// across the WHOLE buffer — not just the nodes whose ranks happen to sit
    /// in the first `4·N` bytes of an `8·N`-byte buffer.
    ///
    /// Three probes: node 0 (first covered byte), node N/2 (first uncovered
    /// byte), node N-1 (last). Before the width fix this passes on node 0 and
    /// fails on the other two — that asymmetry is the defect's fingerprint.
    func testRankRestoresAcrossWholeBuffer() throws {
        let dir = tmpDir! + "dagdb_backup_rankwidth"
        wipeDir(dir)

        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)
        let n = eng.nodeCount
        XCTAssertEqual(n, 64, "fixture grid is side 8 / N = 64")

        let probes = [0, n / 2, n - 1]
        let kept: [UInt64] = [3, 41, 17]       // distinct, non-zero, < nodeCount
        let overwritten: [UInt64] = [5, 6, 7]  // distinct, non-zero, < nodeCount

        _ = try DagDBBackup.initializeChain(
            engine: eng, nodeCount: n,
            gridW: gw, gridH: gh, tickCount: 0, dir: dir
        )

        let rank = eng.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        for (i, node) in probes.enumerated() { rank[node] = kept[i] }

        _ = try DagDBBackup.appendDiff(
            engine: eng, nodeCount: n, gridW: gw, gridH: gh, dir: dir
        )

        // Every other buffer as it stood at APPEND time — must come back exact.
        let truthAt = Data(bytes: eng.truthStateBuf.contents(), count: n)
        let typeAt  = Data(bytes: eng.nodeTypeBuf.contents(),   count: n)
        let lowAt   = Data(bytes: eng.lut6LowBuf.contents(),    count: n * 4)
        let highAt  = Data(bytes: eng.lut6HighBuf.contents(),   count: n * 4)
        let nbAt    = Data(bytes: eng.neighborsBuf.contents(),  count: n * 6 * 4)

        for (i, node) in probes.enumerated() { rank[node] = overwritten[i] }

        _ = try DagDBBackup.restore(
            engine: eng, nodeCount: n, gridW: gw, gridH: gh, dir: dir
        )

        for (i, node) in probes.enumerated() {
            XCTAssertEqual(
                rank[node], kept[i],
                "node \(node) rank after restore: byte offset \(node * 8) of an \(n * 8)-byte buffer"
            )
        }

        XCTAssertEqual(truthAt, Data(bytes: eng.truthStateBuf.contents(), count: n), "truth")
        XCTAssertEqual(typeAt,  Data(bytes: eng.nodeTypeBuf.contents(),   count: n), "nodeType")
        XCTAssertEqual(lowAt,   Data(bytes: eng.lut6LowBuf.contents(),    count: n * 4), "lut6Low")
        XCTAssertEqual(highAt,  Data(bytes: eng.lut6HighBuf.contents(),   count: n * 4), "lut6High")
        XCTAssertEqual(nbAt,    Data(bytes: eng.neighborsBuf.contents(),  count: n * 6 * 4), "neighbors")
    }

    // MARK: - B5 · coverage equals the snapshot's (AMENDMENT 1)

    /// Everything the engine holds per node, as bytes, for comparison.
    private struct EngineImage: Equatable {
        var rank, truth, type, low, high, neighbors: Data
        var isRegister, weights, activation, values: Data
        var backEdgeSrcs: [UInt32]
        var backEdgeDsts: [UInt32]

        init(_ e: DagDBEngine) {
            let n = e.nodeCount
            rank       = Data(bytes: e.rankBuf.contents(),        count: n * 8)
            truth      = Data(bytes: e.truthStateBuf.contents(),  count: n)
            type       = Data(bytes: e.nodeTypeBuf.contents(),    count: n)
            low        = Data(bytes: e.lut6LowBuf.contents(),     count: n * 4)
            high       = Data(bytes: e.lut6HighBuf.contents(),    count: n * 4)
            neighbors  = Data(bytes: e.neighborsBuf.contents(),   count: n * 6 * 4)
            isRegister = Data(bytes: e.isRegisterBuf.contents(),  count: n)
            weights    = Data(bytes: e.edgeWeightsBuf.contents(), count: n * 6 * 4)
            activation = Data(bytes: e.activationBuf.contents(),  count: n * 2)
            values     = Data(bytes: e.nodeValueBuf.contents(),   count: n * 4)
            backEdgeSrcs = e.backEdgeSrcs
            backEdgeDsts = e.backEdgeDsts
        }
    }

    private func assertImagesEqual(
        _ a: EngineImage, _ b: EngineImage, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.rank,       b.rank,       "\(what): rank",        file: file, line: line)
        XCTAssertEqual(a.truth,      b.truth,      "\(what): truth",       file: file, line: line)
        XCTAssertEqual(a.type,       b.type,       "\(what): nodeType",    file: file, line: line)
        XCTAssertEqual(a.low,        b.low,        "\(what): lut6Low",     file: file, line: line)
        XCTAssertEqual(a.high,       b.high,       "\(what): lut6High",    file: file, line: line)
        XCTAssertEqual(a.neighbors,  b.neighbors,  "\(what): neighbors",   file: file, line: line)
        XCTAssertEqual(a.isRegister, b.isRegister, "\(what): isRegister",  file: file, line: line)
        XCTAssertEqual(a.weights,    b.weights,    "\(what): edgeWeights", file: file, line: line)
        XCTAssertEqual(a.activation, b.activation, "\(what): activation",  file: file, line: line)
        XCTAssertEqual(a.values,     b.values,     "\(what): nodeValue",   file: file, line: line)
        XCTAssertEqual(a.backEdgeSrcs, b.backEdgeSrcs, "\(what): back-edge srcs", file: file, line: line)
        XCTAssertEqual(a.backEdgeDsts, b.backEdgeDsts, "\(what): back-edge dsts", file: file, line: line)
    }

    /// The state B5 puts on a seeded engine. Applied to two engines that never
    /// touch each other, so the "un-restored" side of the tick comparison is
    /// built from the same VALUES, not copied from the buffers under test.
    ///
    /// The two registers sit in the UPPER half of the buffer (nodes 50, 51):
    /// the half a 4-bytes-per-node rank segment never reached, and the half a
    /// six-buffer diff never carried at all.
    private func applyCoverageState(_ e: DagDBEngine) throws {
        let n = e.nodeCount
        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let wgt = e.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        let act = e.activationBuf.contents().bindMemory(to: Int16.self, capacity: n)
        let val = e.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)

        // Two registers driven by back edges. Nodes 50 and 51 have no
        // combinational fan-in, which addBackEdge requires.
        try e.addBackEdge(src: 7, dst: 50)
        try e.addBackEdge(src: 1, dst: 51)
        // Three edges off the default weight, one of them in the upper half.
        wgt[7 * 6 + 0] = 0.25
        wgt[7 * 6 + 1] = 2.5
        wgt[33 * 6 + 0] = -1.5
        // Two nodes with non-zero activation and node value, one of each half.
        act[3] = 7;   val[3] = 1.5
        act[40] = -3; val[40] = -2.25
        // …and the six, so this gate does not depend on B1's.
        rank[63] = 5
        truth[2] ^= 1
    }

    /// A `.diff` must carry every buffer the snapshot carries: not just the
    /// six it was written for, but registers, back edges, edge weights,
    /// activation and node values too. Before the coverage fix this fails on
    /// every buffer outside the six — a restored graph came back with no
    /// registers (so the tick computes something else) and default lanes.
    func testDiffCoversEverySnapshotBuffer() throws {
        let dir = tmpDir! + "dagdb_backup_coverage"
        wipeDir(dir)

        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)
        let n = eng.nodeCount

        _ = try DagDBBackup.initializeChain(
            engine: eng, nodeCount: n, gridW: gw, gridH: gh,
            tickCount: 0, dir: dir
        )

        // --- mutate everything -----------------------------------------
        try applyCoverageState(eng)

        _ = try DagDBBackup.appendDiff(
            engine: eng, nodeCount: n, gridW: gw, gridH: gh, dir: dir
        )

        let atAppend = EngineImage(eng)

        // The un-restored engine: built independently from the same values,
        // never a copy of the buffers this gate is testing, and it never
        // touches disk.
        let (reference, _, _) = try makeEngine(side: 8)
        seed(reference)
        try applyCoverageState(reference)
        assertImagesEqual(EngineImage(reference), atAppend, "independent twin")

        // --- overwrite everything --------------------------------------
        let rank = eng.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let truth = eng.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let wgt = eng.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        let act = eng.activationBuf.contents().bindMemory(to: Int16.self, capacity: n)
        let val = eng.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)
        try eng.clearBackEdges(toNode: 50)
        try eng.clearBackEdges(toNode: 51)
        try eng.addBackEdge(src: 2, dst: 52)
        wgt[7 * 6 + 0] = 9.0
        wgt[7 * 6 + 1] = -4.0
        wgt[33 * 6 + 0] = 0.125
        act[3] = -11;  val[3] = 42.0
        act[40] = 5;   val[40] = -0.5
        rank[63] = 1
        truth[2] ^= 1

        _ = try DagDBBackup.restore(
            engine: eng, nodeCount: n, gridW: gw, gridH: gh, dir: dir
        )

        assertImagesEqual(EngineImage(eng), atAppend, "after restore")
        XCTAssertTrue(eng.isRegister(node: 50), "node 50 is a register again")
        XCTAssertTrue(eng.isRegister(node: 51), "node 51 is a register again")
        XCTAssertFalse(eng.isRegister(node: 52), "node 52 was never in the backup")

        // --- the restored state must COMPUTE the same, not merely store --
        eng.tick(tickNumber: 1)
        reference.tick(tickNumber: 1)
        assertImagesEqual(EngineImage(eng), EngineImage(reference), "after one rank-mode tick")
    }

    // MARK: - B2 · format version (BACKUP_RANK_WIDTH_GATES_FROZEN)

    /// Write a chain in the retired format-1 layout by hand: the old header
    /// (version 1) and a rank segment of `4·N` bytes. Nothing in the library
    /// can produce this any more — that is the point, the bytes for the upper
    /// half of the rank buffer were never written.
    private func writeLegacyDiff(dir: String, nodeCount n: Int, seq: Int) throws {
        var out = Data()
        out.append(contentsOf: DagDBBackup.diffMagic)
        for v in [DagDBBackup.diffVersionLegacy, UInt32(n), UInt32(seq)] {
            var x = v
            out.append(Data(bytes: &x, count: 4))
        }
        // Six all-zero XOR segments; rank at the old 4-bytes-per-node width.
        let segSizes = [n * 4, n, n, n * 4, n * 4, n * 6 * 4]
        for size in segSizes {
            let body = DagDBSnapshot.zlibCompress(Data(count: size))
            var sz = UInt32(body.count)
            out.append(Data(bytes: &sz, count: 4))
            out.append(body)
        }
        let path = String(format: "\(dir)/%05d.diff", seq)
        try out.write(to: URL(fileURLWithPath: path))
    }

    func testInfoReportsFormatVersionTwoForFreshChain() throws {
        let dir = tmpDir! + "dagdb_backup_fmt2"
        wipeDir(dir)

        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)
        _ = try DagDBBackup.initializeChain(
            engine: eng, nodeCount: eng.nodeCount,
            gridW: gw, gridH: gh, tickCount: 0, dir: dir
        )
        flipTruth(eng, 3)
        _ = try DagDBBackup.appendDiff(
            engine: eng, nodeCount: eng.nodeCount,
            gridW: gw, gridH: gh, dir: dir
        )

        let chain = try DagDBBackup.info(dir: dir)
        XCTAssertEqual(chain.formatVersion, 2)
        XCTAssertFalse(chain.isLegacyFormat)
    }

    func testLegacyFormatChainRefusedOnRestoreByName() throws {
        let dir = tmpDir! + "dagdb_backup_legacy_restore"
        wipeDir(dir)

        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)
        _ = try DagDBBackup.initializeChain(
            engine: eng, nodeCount: eng.nodeCount,
            gridW: gw, gridH: gh, tickCount: 0, dir: dir
        )
        try writeLegacyDiff(dir: dir, nodeCount: eng.nodeCount, seq: 1)

        XCTAssertThrowsError(
            try DagDBBackup.restore(
                engine: eng, nodeCount: eng.nodeCount,
                gridW: gw, gridH: gh, dir: dir
            )
        ) { err in
            guard case DagDBBackup.BackupError.legacyFormat = err else {
                XCTFail("expected legacyFormat, got \(err)"); return
            }
            XCTAssertEqual(
                "\(err)",
                "io: backup format 1 carries 4 of 8 rank bytes per node and no " +
                "registers, back edges, weights, activation or node values; " +
                "cannot restore ranks for nodes N/2..<N; re-create the backup"
            )
        }
    }

    func testLegacyFormatChainRefusedOnAppend() throws {
        let dir = tmpDir! + "dagdb_backup_legacy_append"
        wipeDir(dir)

        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)
        _ = try DagDBBackup.initializeChain(
            engine: eng, nodeCount: eng.nodeCount,
            gridW: gw, gridH: gh, tickCount: 0, dir: dir
        )
        try writeLegacyDiff(dir: dir, nodeCount: eng.nodeCount, seq: 1)

        XCTAssertThrowsError(
            try DagDBBackup.appendDiff(
                engine: eng, nodeCount: eng.nodeCount,
                gridW: gw, gridH: gh, dir: dir
            )
        ) { err in
            guard case DagDBBackup.BackupError.legacyFormat = err else {
                XCTFail("expected legacyFormat, got \(err)"); return
            }
        }
    }

    func testInfoNamesLegacyFormatWithoutRefusing() throws {
        let dir = tmpDir! + "dagdb_backup_legacy_info"
        wipeDir(dir)

        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)
        _ = try DagDBBackup.initializeChain(
            engine: eng, nodeCount: eng.nodeCount,
            gridW: gw, gridH: gh, tickCount: 0, dir: dir
        )
        try writeLegacyDiff(dir: dir, nodeCount: eng.nodeCount, seq: 1)

        let chain = try DagDBBackup.info(dir: dir)   // read-only: must not throw
        XCTAssertEqual(chain.formatVersion, 1)
        XCTAssertTrue(chain.isLegacyFormat)
        XCTAssertEqual(chain.diffCount, 1)
        XCTAssertEqual(
            DagDBBackup.legacyFormatMessage,
            "backup format 1 carries 4 of 8 rank bytes per node and no " +
            "registers, back edges, weights, activation or node values; " +
            "cannot restore ranks for nodes N/2..<N; re-create the backup"
        )
    }

    // MARK: - B6–B9 · order, identity, integrity (AMENDMENT 2)

    /// Compare an error's own sentence, so these gates compile against any
    /// build — the one that refuses and the one that does not.
    private func assertRefuses(
        _ what: String, _ expected: String,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail("\(what): expected a refusal, got none — wanted '\(expected)'",
                    file: file, line: line)
        } catch {
            XCTAssertEqual("\(error)", expected, what, file: file, line: line)
        }
    }

    private func writeSidecar(_ path: String) throws {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        try Data((DagDBSnapshot.sha256Hex(bytes) + "\n").utf8)
            .write(to: URL(fileURLWithPath: DagDBSnapshot.manifestPathFor(path)))
    }

    private func renameDiff(dir: String, from: String, to: String) throws {
        let fm = FileManager.default
        try fm.moveItem(atPath: dir + "/" + from, toPath: dir + "/" + to)
        try? fm.moveItem(atPath: dir + "/" + from + ".sha256",
                         toPath: dir + "/" + to + ".sha256")
    }

    /// A no-op diff written by hand at the build's own format version, with the
    /// rank segment's raw size under the caller's control so a gate can shorten
    /// it on purpose. Every segment is zeros, so a full-width one changes
    /// nothing when applied.
    private func writeHandMadeDiff(
        dir: String, nodeCount n: Int, seq: Int, rankBytes: Int,
        backEdges: Data = Data(count: 4)
    ) throws {
        var out = Data()
        out.append(contentsOf: DagDBBackup.diffMagic)
        for v in [DagDBBackup.diffVersion, UInt32(n), UInt32(seq)] {
            var x = v
            out.append(Data(bytes: &x, count: 4))
        }
        let sizes = [rankBytes, n, n, n * 4, n * 4, n * 6 * 4,
                     n, n * 6 * 4, n * 2, n * 4]
        for size in sizes {
            let body = DagDBSnapshot.zlibCompress(Data(count: size))
            var sz = UInt32(body.count)
            out.append(Data(bytes: &sz, count: 4))
            out.append(body)
        }
        // Back-edge section: u32 raw size, then the compressed body. An empty
        // list is a bare u32 zero; the caller can hand over any blob.
        let beRaw = backEdges
        let beBody = DagDBSnapshot.zlibCompress(beRaw)
        for v in [UInt32(beRaw.count), UInt32(beBody.count)] {
            var x = v
            out.append(Data(bytes: &x, count: 4))
        }
        out.append(beBody)

        let path = String(format: "\(dir)/%05d.diff", seq)
        try out.write(to: URL(fileURLWithPath: path))
        try writeSidecar(path)
    }

    /// Build a chain of `count` diffs, each flipping one truth bit.
    @discardableResult
    private func chainOfDiffs(
        _ count: Int, dir: String, engine: DagDBEngine, gw: Int, gh: Int
    ) throws -> DagDBEngine {
        _ = try DagDBBackup.initializeChain(
            engine: engine, nodeCount: engine.nodeCount,
            gridW: gw, gridH: gh, tickCount: 0, dir: dir
        )
        for k in 0..<count {
            flipTruth(engine, k + 1)
            _ = try DagDBBackup.appendDiff(
                engine: engine, nodeCount: engine.nodeCount,
                gridW: gw, gridH: gh, dir: dir
            )
        }
        return engine
    }

    // B6 — a length disagreement is refused, never clamped to the shorter side.
    func testShortSegmentIsRefusedNotClamped() throws {
        let dir = tmpDir! + "dagdb_backup_shortseg"
        wipeDir(dir)

        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)
        let n = eng.nodeCount
        _ = try DagDBBackup.initializeChain(
            engine: eng, nodeCount: n, gridW: gw, gridH: gh, tickCount: 0, dir: dir
        )
        // Rank segment at four bytes per node over an eight-byte buffer — the
        // exact disagreement the old min() clamp swallowed.
        try writeHandMadeDiff(dir: dir, nodeCount: n, seq: 1, rankBytes: n * 4)

        assertRefuses(
            "short rank segment",
            "io: backup diff 1 segment rank is \(n * 4) bytes, expected \(n * 8)"
        ) {
            _ = try DagDBBackup.restore(
                engine: eng, nodeCount: n, gridW: gw, gridH: gh, dir: dir)
        }
    }

    // B7 — diffs apply in sequence-number order, not filename order.
    func testDiffsApplyInSequenceOrderNotFilenameOrder() throws {
        let dir = tmpDir! + "dagdb_backup_order"
        wipeDir(dir)

        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)
        let n = eng.nodeCount
        _ = try DagDBBackup.initializeChain(
            engine: eng, nodeCount: n, gridW: gw, gridH: gh, tickCount: 0, dir: dir
        )

        // Diff 1: node 20 is the register. Diff 2: node 21 is, instead. The
        // back-edge list is the order-sensitive part of a diff — the XOR
        // segments commute, this does not.
        try eng.addBackEdge(src: 7, dst: 20)
        _ = try DagDBBackup.appendDiff(
            engine: eng, nodeCount: n, gridW: gw, gridH: gh, dir: dir)
        try eng.clearBackEdges(toNode: 20)
        try eng.addBackEdge(src: 1, dst: 21)
        _ = try DagDBBackup.appendDiff(
            engine: eng, nodeCount: n, gridW: gw, gridH: gh, dir: dir)

        // Rename so that filename order is the REVERSE of sequence order.
        XCTAssertTrue("100000.diff" < "99999.diff", "the sort that bites")
        try renameDiff(dir: dir, from: "00001.diff", to: "99999.diff")
        try renameDiff(dir: dir, from: "00002.diff", to: "100000.diff")

        let (fresh, _, _) = try makeEngine(side: 8)
        _ = try DagDBBackup.restore(
            engine: fresh, nodeCount: n, gridW: gw, gridH: gh, dir: dir)

        XCTAssertEqual(fresh.backEdgeSrcs, [1], "the last diff's back edge wins")
        XCTAssertEqual(fresh.backEdgeDsts, [21], "the last diff's back edge wins")
        XCTAssertTrue(fresh.isRegister(node: 21))
        XCTAssertFalse(fresh.isRegister(node: 20))
    }

    // B7 — a gap in the sequence is refused by name.
    func testSequenceGapIsRefused() throws {
        let dir = tmpDir! + "dagdb_backup_gap"
        wipeDir(dir)

        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)
        try chainOfDiffs(3, dir: dir, engine: eng, gw: gw, gh: gh)

        let fm = FileManager.default
        try fm.removeItem(atPath: dir + "/00002.diff")
        try? fm.removeItem(atPath: dir + "/00002.diff.sha256")

        assertRefuses(
            "missing middle diff",
            "io: backup chain is missing diff sequence 2; the chain is incomplete"
        ) {
            _ = try DagDBBackup.restore(
                engine: eng, nodeCount: eng.nodeCount,
                gridW: gw, gridH: gh, dir: dir)
        }
    }

    // B7 — a duplicated sequence number is refused by name.
    func testDuplicateSequenceIsRefused() throws {
        let dir = tmpDir! + "dagdb_backup_dup"
        wipeDir(dir)

        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)
        try chainOfDiffs(2, dir: dir, engine: eng, gw: gw, gh: gh)

        // A copy of diff 2 under a third name: same sequence number inside.
        let fm = FileManager.default
        try fm.copyItem(atPath: dir + "/00002.diff", toPath: dir + "/00003.diff")
        try? fm.copyItem(atPath: dir + "/00002.diff.sha256",
                         toPath: dir + "/00003.diff.sha256")

        do {
            _ = try DagDBBackup.restore(
                engine: eng, nodeCount: eng.nodeCount,
                gridW: gw, gridH: gh, dir: dir)
            XCTFail("duplicate sequence: expected a refusal, got none")
        } catch {
            let text = "\(error)"
            XCTAssertTrue(
                text.hasPrefix("io: backup chain has two diffs with sequence 2: "),
                "duplicate sequence refusal: \(text)")
            XCTAssertTrue(text.contains("00002.diff"), text)
            XCTAssertTrue(text.contains("00003.diff"), text)
        }
    }

    // B7 — APPEND never writes over a file that is already there.
    func testAppendRefusesToOverwriteExistingDiff() throws {
        let dir = tmpDir! + "dagdb_backup_overwrite"
        wipeDir(dir)

        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)
        try chainOfDiffs(2, dir: dir, engine: eng, gw: gw, gh: gh)

        // Shift both diffs up one filename slot. The sequence numbers inside
        // are still 1 and 2, so the chain is valid and the next APPEND wants
        // 00003.diff — which is now occupied by sequence 2.
        try renameDiff(dir: dir, from: "00002.diff", to: "00003.diff")
        try renameDiff(dir: dir, from: "00001.diff", to: "00002.diff")

        assertRefuses(
            "occupied append slot",
            "io: backup diff 00003.diff already exists; refusing to overwrite"
        ) {
            _ = try DagDBBackup.appendDiff(
                engine: eng, nodeCount: eng.nodeCount,
                gridW: gw, gridH: gh, dir: dir)
        }
    }

    // B8 — the sidecar is checked before anything is decoded.
    func testCorruptDiffRefusedAtItsSidecar() throws {
        let dir = tmpDir! + "dagdb_backup_sha"
        wipeDir(dir)

        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)
        try chainOfDiffs(1, dir: dir, engine: eng, gw: gw, gh: gh)

        let path = dir + "/00001.diff"
        var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(bytes.count, DagDBBackup.diffHeaderSize + 4)
        bytes[bytes.count - 1] ^= 0xFF          // one flipped byte, body side
        try bytes.write(to: URL(fileURLWithPath: path))

        assertRefuses(
            "corrupt diff",
            "io: backup diff 00001.diff does not match its sha256 sidecar; the file is corrupt or truncated"
        ) {
            _ = try DagDBBackup.restore(
                engine: eng, nodeCount: eng.nodeCount,
                gridW: gw, gridH: gh, dir: dir)
        }
    }

    func testDiffWithoutSidecarRefused() throws {
        let dir = tmpDir! + "dagdb_backup_nosha"
        wipeDir(dir)

        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)
        try chainOfDiffs(1, dir: dir, engine: eng, gw: gw, gh: gh)
        try FileManager.default.removeItem(atPath: dir + "/00001.diff.sha256")

        assertRefuses(
            "sidecar-less diff",
            "io: backup diff 00001.diff has no sha256 sidecar; re-create the backup"
        ) {
            _ = try DagDBBackup.restore(
                engine: eng, nodeCount: eng.nodeCount,
                gridW: gw, gridH: gh, dir: dir)
        }
    }

    // B11 — the back-edge section's length must equal what its own pair count
    // claims. The eleventh segment was the only one whose length was checked
    // against the file's own prefix instead of against a size derived from the
    // object, and the guard was `>=`: the blind verifier padded a blob from 12
    // bytes to 20 with the pair count left at 1, rewrote the sidecar, and the
    // restore took it without a word.
    func testPaddedBackEdgeSectionIsRefused() throws {
        let dir = tmpDir! + "dagdb_backup_bepad"
        wipeDir(dir)

        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)
        let n = eng.nodeCount
        _ = try DagDBBackup.initializeChain(
            engine: eng, nodeCount: n, gridW: gw, gridH: gh, tickCount: 0, dir: dir
        )

        // One pair (7 → 50) is 4 + 8 = 12 bytes. Pad to 20, leave the count 1.
        var blob = Data()
        for v: UInt32 in [1, 7, 50] {
            var x = v
            blob.append(Data(bytes: &x, count: 4))
        }
        blob.append(Data(count: 8))
        XCTAssertEqual(blob.count, 20)

        try writeHandMadeDiff(
            dir: dir, nodeCount: n, seq: 1, rankBytes: n * 8, backEdges: blob)

        assertRefuses(
            "padded back-edge section",
            "io: backup diff 1 back-edge section is 20 bytes, expected 12 for 1 pairs"
        ) {
            _ = try DagDBBackup.restore(
                engine: eng, nodeCount: n, gridW: gw, gridH: gh, dir: dir)
        }
    }

    /// The honest blob of the same pair is accepted — the refusal is about the
    /// padding, not about hand-built sections.
    func testExactBackEdgeSectionIsAccepted() throws {
        let dir = tmpDir! + "dagdb_backup_beexact"
        wipeDir(dir)

        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)
        let n = eng.nodeCount
        _ = try DagDBBackup.initializeChain(
            engine: eng, nodeCount: n, gridW: gw, gridH: gh, tickCount: 0, dir: dir
        )

        var blob = Data()
        for v: UInt32 in [1, 7, 50] {
            var x = v
            blob.append(Data(bytes: &x, count: 4))
        }
        XCTAssertEqual(blob.count, 12)

        try writeHandMadeDiff(
            dir: dir, nodeCount: n, seq: 1, rankBytes: n * 8, backEdges: blob)

        _ = try DagDBBackup.restore(
            engine: eng, nodeCount: n, gridW: gw, gridH: gh, dir: dir)
        XCTAssertEqual(eng.backEdgeSrcs, [7])
        XCTAssertEqual(eng.backEdgeDsts, [50])
        XCTAssertTrue(eng.isRegister(node: 50))
    }

    // B9 — COMPACT writes its base from the chain, not from a live engine.
    func testCompactWritesTheChainsTipNotTheEnginesState() throws {
        let dir = tmpDir! + "dagdb_backup_compact_source"
        wipeDir(dir)

        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)
        let n = eng.nodeCount

        // The chain's own tick count — not whatever a caller happens to hold.
        _ = try DagDBBackup.initializeChain(
            engine: eng, nodeCount: n, gridW: gw, gridH: gh, tickCount: 7, dir: dir
        )

        let rank = eng.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let wgt = eng.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        rank[63] = 5
        wgt[7 * 6 + 0] = 0.25
        try eng.addBackEdge(src: 7, dst: 20)
        _ = try DagDBBackup.appendDiff(
            engine: eng, nodeCount: n, gridW: gw, gridH: gh, dir: dir)

        let atAppend = EngineImage(eng)

        // Now move the LIVE engine past the chain. None of this was appended.
        rank[63] = 9
        wgt[7 * 6 + 0] = -4.0
        try eng.clearBackEdges(toNode: 20)

        let c = try DagDBBackup.compact(
            nodeCount: n,
            gridW: gw, gridH: gh, dir: dir
        )
        XCTAssertEqual(c.priorDiffCount, 1)

        let after = try DagDBBackup.info(dir: dir)
        XCTAssertTrue(after.baseExists)
        XCTAssertEqual(after.diffCount, 0)

        // The compacted base must hold the chain's tip and the chain's ticks.
        let (fresh, _, _) = try makeEngine(side: 8)
        let loaded = try DagDBSnapshot.load(
            engine: fresh, nodeCount: n, gridW: gw, gridH: gh,
            path: dir + "/base.dags", validate: false
        )
        XCTAssertEqual(loaded.fileTicks, 7, "compaction keeps the chain's tick count")

        _ = try DagDBBackup.restore(
            engine: fresh, nodeCount: n, gridW: gw, gridH: gh, dir: dir)
        assertImagesEqual(EngineImage(fresh), atAppend, "compacted base")
    }

    func testAppendWithoutBaseFails() throws {
        let dir = tmpDir! + "dagdb_backup_nobase"
        wipeDir(dir)
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        let (eng, gw, gh) = try makeEngine(side: 8)
        seed(eng)

        XCTAssertThrowsError(
            try DagDBBackup.appendDiff(
                engine: eng, nodeCount: eng.nodeCount,
                gridW: gw, gridH: gh, dir: dir
            )
        ) { err in
            guard case DagDBBackup.BackupError.noBase = err else {
                XCTFail("expected noBase, got \(err)"); return
            }
        }
    }
}
