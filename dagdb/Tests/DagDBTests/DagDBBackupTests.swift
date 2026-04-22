import XCTest
@testable import DagDB

final class DagDBBackupTests: XCTestCase {

    private func makeEngine(side: Int) throws -> (DagDBEngine, Int, Int) {
        let grid = HexGrid(width: side, height: side)
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
        return buffersEqual(a.rankBuf,       b.rankBuf,       n * 4)
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
        let dir = NSTemporaryDirectory() + "dagdb_backup_init"
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
        let dir = NSTemporaryDirectory() + "dagdb_backup_one"
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
        let dir = NSTemporaryDirectory() + "dagdb_backup_many"
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
        let dir = NSTemporaryDirectory() + "dagdb_backup_size"
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
        let dir = NSTemporaryDirectory() + "dagdb_backup_compact"
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
        let (tmp, _, _) = try makeEngine(side: 8)
        let c = try DagDBBackup.compact(
            engine: tmp, nodeCount: tmp.nodeCount,
            gridW: gw, gridH: gh, tickCount: 99, dir: dir
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

    func testAppendWithoutBaseFails() throws {
        let dir = NSTemporaryDirectory() + "dagdb_backup_nobase"
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
