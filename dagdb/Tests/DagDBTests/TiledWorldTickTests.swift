import XCTest
import CryptoKit
@testable import DagDB

/// Ticking gates W1–W4, W6 — `docs/contracts/TICKING_GATES_FROZEN.md`.
/// Style follows `TiledGraphRouterTests.swift` / `TiledGraphFilesTests.swift`.
final class TiledWorldTickTests: XCTestCase {

    // MARK: - Scratch dirs (NSTemporaryDirectory, never the repo)

    private func scratchDir(_ label: String) -> String {
        let dir = NSTemporaryDirectory() + "dagdb-ticking-\(label)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeScratch(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private struct WrittenObject {
        let dir: String
        let name: String
        let report: TiledGraphFiles.WriteReport
    }

    @discardableResult
    private func writeTiledObject(side: Int, tiles: Int, label: String) throws -> WrittenObject {
        let object = try TiledFixture.generate(side: side)
        let dir = scratchDir(label)
        let boundaries = TiledFixture.boundaries(side: side, tiles: tiles)
        let report = try TiledGraphFiles.write(object: object, dataRoot: dir, name: "g", boundaries: boundaries)
        return WrittenObject(dir: dir, name: "g", report: report)
    }

    /// `count` reference ticks (`tick`/`tickSync` per `mode`), tick numbers
    /// `from+1...from+count`, matching `worldTick`'s own numbering.
    private func referenceTick(engine: DagDBEngine, mode: TickMode, from: Int, count: Int) {
        for k in (from + 1)...(from + count) {
            switch mode {
            case .rank: engine.tick(tickNumber: UInt32(k))
            case .sync: engine.tickSync(tickNumber: UInt32(k))
            }
        }
    }

    /// Recursive directory copy (Foundation's `copyItem` already recurses
    /// for directories) — used by the W4 crash-simulation tests to snapshot
    /// a tile directory at a checkpoint epoch.
    private func snapshotDir(_ src: String, _ dst: String) throws {
        try? FileManager.default.removeItem(atPath: dst)
        try FileManager.default.copyItem(atPath: src, toPath: dst)
    }

    private func restoreDir(_ src: String, over dst: String) throws {
        try FileManager.default.removeItem(atPath: dst)
        try FileManager.default.copyItem(atPath: src, toPath: dst)
    }

    // MARK: - AMENDMENT 6, letter 2: the reference evaluator is gated first

    /// `TiledReference` is the authority every later equality is compared
    /// against, so it is gated against the UNTILED engine before it is
    /// used for anything: 12 ticks, exact, every side, both modes. Also
    /// prints the per-tick change count, which is W7c's own line at the
    /// untiled level — the repaired object must never go static.
    private func runReferenceMatchesUntiledEngine(mode: TickMode) throws {
        for side in TiledFixture.sides {
            let object = try TiledFixture.generate(side: side)
            let reference = TiledReference(engine: object.engine)
            var refVector = object.engine.readTruthStates()
            var changes: [Int] = []
            for k in 1...12 {
                let before = refVector
                switch mode {
                case .rank:
                    object.engine.tick(tickNumber: UInt32(k))
                    refVector = reference.tickRank(refVector)
                case .sync:
                    object.engine.tickSync(tickNumber: UInt32(k))
                    refVector = reference.tickSync(refVector)
                }
                let engineVector = object.engine.readTruthStates()
                changes.append(TiledReference.differing(before, refVector).count)
                // Compared as a COUNT + first index, never as two whole
                // arrays: an XCTAssertEqual over 16384 bytes prints both.
                let disagree = TiledReference.differing(refVector, engineVector).sorted()
                var detail = "none"
                if let first = disagree.first {
                    let ranks = Set(disagree.map { reference.rank[$0] }).sorted()
                    detail = "\(disagree.count) of \(refVector.count) bytes differ; "
                        + "ranks involved \(ranks); first node \(first) at rank "
                        + "\(reference.rank[first]) ref=\(refVector[first]) engine=\(engineVector[first])"
                }
                XCTAssertEqual(
                    disagree.count, 0,
                    "reference vs untiled engine, side=\(side) mode=\(mode) tick=\(k): \(detail)"
                )
            }
            print("REFERENCE mode=\(mode) side=\(side) nodes=\(object.nodeCount) "
                + "registers=\(reference.backEdgeDst.count) changes_per_tick=\(changes)")
            XCTAssertFalse(changes.contains(0), "side=\(side) mode=\(mode): a static tick is a free equality")
        }
    }

    func testReferenceMatchesUntiledEngine_rank() throws {
        try runReferenceMatchesUntiledEngine(mode: .rank)
    }

    func testReferenceMatchesUntiledEngine_sync() throws {
        try runReferenceMatchesUntiledEngine(mode: .sync)
    }

    // MARK: - W1 / W2: world ticks equal the untiled engine, bit for bit

    /// Shared body for W1 (mode: .rank) and W2 (mode: .sync). For each
    /// tiling × K: one fresh reference engine (untiled), one fresh tiled
    /// write, and one `TiledReference` (the test-side evaluator that never
    /// calls `DagDBEngine`), all three ticked incrementally through `ns`
    /// (ascending) and compared at every checkpoint — AMENDMENT 6, letter
    /// 2: **tiled == untiled == reference**, bit for bit — plus the
    /// tickCount/meta pair (§7's invariant) on every tile.
    private func runWorldTickEqualsUntiled(
        side: Int, tilings: [Int], ks: [Int], ns: [Int], mode: TickMode, label: String
    ) async throws {
        for tiles in tilings {
            for k in ks {
                let refObject = try TiledFixture.generate(side: side)
                let w = try writeTiledObject(side: side, tiles: tiles, label: "\(label)-t\(tiles)-k\(k)")
                defer { removeScratch(w.dir) }
                let router = try await TiledGraphRouter(dataRoot: w.dir, graphName: w.name, maxResidentTiles: k)

                let reference = TiledReference(engine: refObject.engine)
                var refVector = refObject.engine.readTruthStates()

                // AMENDMENT 7, finding A: this equality is only worth
                // anything if the object CAN exhibit the register
                // latch-timing defect — i.e. if some node reads a register
                // across a tile boundary. Counted here, beside the gate it
                // guards; `TiledW7Tests.testFindingACrossTileRegisterReadersExist`
                // asserts the per-side total and prints the whole table.
                let tileOf = reference.tileAssignment(boundaries: TiledFixture.boundaries(side: side, tiles: tiles))
                let registerCrossings = reference.crossings(tileOf: tileOf)
                    .filter { reference.isRegister[$0.source] }
                if k == ks.first {
                    print("W1W2-REGISTER-CROSSINGS side=\(side) tiles=\(tiles) mode=\(mode) "
                        + "cross_tile_register_reader_edges=\(registerCrossings.count)")
                }

                var prevN = 0
                for targetN in ns {
                    let delta = targetN - prevN
                    referenceTick(engine: refObject.engine, mode: mode, from: prevN, count: delta)
                    for _ in 0..<delta {
                        refVector = (mode == .rank)
                            ? reference.tickRank(refVector) : reference.tickSync(refVector)
                    }
                    let report = try await router.worldTick(mode: mode, count: delta)
                    XCTAssertEqual(report.epoch, UInt64(targetN), "side=\(side) tiles=\(tiles) K=\(k) mode=\(mode) N=\(targetN) epoch")

                    let want = refObject.engine.readTruthStates()
                    let got = try await router.truthArray()
                    XCTAssertEqual(
                        got.count, want.count,
                        "side=\(side) tiles=\(tiles) K=\(k) mode=\(mode) N=\(targetN) truthArray count"
                    )
                    XCTAssertEqual(
                        got, want,
                        "side=\(side) tiles=\(tiles) K=\(k) mode=\(mode) N=\(targetN) truthArray mismatch"
                    )
                    XCTAssertEqual(
                        refVector, want,
                        "side=\(side) tiles=\(tiles) K=\(k) mode=\(mode) N=\(targetN) reference vs untiled engine"
                    )
                    XCTAssertEqual(
                        got, refVector,
                        "side=\(side) tiles=\(tiles) K=\(k) mode=\(mode) N=\(targetN) tiled vs reference"
                    )

                    let epochs = try await router.tileEpochs()
                    XCTAssertEqual(epochs.count, tiles)
                    for (id, pair) in epochs {
                        XCTAssertEqual(pair.metaEpoch, UInt64(targetN), "tile \(id) meta epoch at N=\(targetN)")
                        XCTAssertEqual(pair.bodyEpoch, UInt64(targetN), "tile \(id) body epoch at N=\(targetN)")
                    }

                    prevN = targetN
                }
            }
        }
    }

    // W1 — rank mode, split by side per the task's runtime note.

    func testW1RankModeEqualsUntiled_Side16() async throws {
        try await runWorldTickEqualsUntiled(
            side: 16, tilings: [2, 4, 8], ks: [1, 2], ns: [1, 2, 5, 12], mode: .rank, label: "w1-16"
        )
    }

    func testW1RankModeEqualsUntiled_Side44() async throws {
        try await runWorldTickEqualsUntiled(
            side: 44, tilings: [2, 4, 8], ks: [1, 2], ns: [1, 2, 5, 12], mode: .rank, label: "w1-44"
        )
    }

    func testW1RankModeEqualsUntiled_Side128() async throws {
        try await runWorldTickEqualsUntiled(
            side: 128, tilings: [2, 4, 8], ks: [1, 2], ns: [1, 2, 5, 12], mode: .rank, label: "w1-128"
        )
    }

    // W2 — sync mode, split by side.

    func testW2SyncModeEqualsUntiled_Side16() async throws {
        try await runWorldTickEqualsUntiled(
            side: 16, tilings: [2, 4, 8], ks: [1, 2], ns: [1, 2, 5, 12], mode: .sync, label: "w2-16"
        )
    }

    func testW2SyncModeEqualsUntiled_Side44() async throws {
        try await runWorldTickEqualsUntiled(
            side: 44, tilings: [2, 4, 8], ks: [1, 2], ns: [1, 2, 5, 12], mode: .sync, label: "w2-44"
        )
    }

    func testW2SyncModeEqualsUntiled_Side128() async throws {
        try await runWorldTickEqualsUntiled(
            side: 128, tilings: [2, 4, 8], ks: [1, 2], ns: [1, 2, 5, 12], mode: .sync, label: "w2-128"
        )
    }

    // MARK: - W3: halo epochs, staleness detection + regeneration

    /// Finds one real (reader, source) ghost relationship from a written
    /// manifest — the reader is the first tile with a non-empty
    /// `crossingsOut`, the source is the foreign tile its first crossing
    /// names.
    private func firstGhostRelationship(_ manifest: TiledGraphFiles.Manifest) -> (reader: UInt32, source: UInt32)? {
        for entry in manifest.tiles.sorted(by: { $0.id < $1.id }) {
            if let first = entry.crossingsOut.first {
                return (entry.id, first.remoteNode.tileId)
            }
        }
        return nil
    }

    func testW3EpochsAndStaleStrips() async throws {
        let side = 16, tiles = 4

        // Baseline: every tile's parity-1 strip + meta carries epoch 3
        // after 3 sync-mode world ticks.
        let baseline = try writeTiledObject(side: side, tiles: tiles, label: "w3-baseline")
        defer { removeScratch(baseline.dir) }
        let baselineRouter = try await TiledGraphRouter(dataRoot: baseline.dir, graphName: baseline.name, maxResidentTiles: 2)
        _ = try await baselineRouter.worldTick(mode: .sync, count: 3)
        let manifest = await baselineRouter.manifest
        let epochs = try await baselineRouter.tileEpochs()
        for entry in manifest.tiles {
            XCTAssertEqual(epochs[entry.id]?.metaEpoch, 3, "tile \(entry.id) meta epoch")
            XCTAssertEqual(epochs[entry.id]?.bodyEpoch, 3, "tile \(entry.id) body epoch")
            let (epoch, _) = try TiledGraphFiles.readLowerStrip(
                dataRoot: baseline.dir, name: baseline.name, manifest: manifest, tileId: entry.id, parity: 1
            )
            XCTAssertEqual(epoch, 3, "tile \(entry.id) parity-1 strip epoch")
        }

        guard let rel = firstGhostRelationship(manifest) else {
            return XCTFail("fixture side=\(side) tiles=\(tiles) produced no cross-tile ghost relationship")
        }
        let sourceLocal = manifest.tiles.first(where: { $0.id == rel.reader })!.crossingsOut.first!.remoteNode.localNodeId

        // The staleness/regeneration mechanism itself (`ghostTruth` /
        // `regenerateStaleLowerStrip`) is exercised DIRECTLY here (both
        // are package-internal, not `private`, for exactly this reason)
        // rather than through a whole `worldTick` round: a round always
        // touches every tile, so a whole-round loads/evicts delta
        // conflates the regeneration's own cost with N other tiles'
        // ordinary loads/evicts — the "+2/+2" and "+1/+0" the contract
        // states are the mechanism's isolated cost at the moment it
        // fires, not a round total.

        // K = 1 (no free tick-resident slot): evict the reader, load the
        // source, write its strip, evict the source, reload the reader —
        // loads +2, evicts +2.
        try await runW3Regeneration(rel: rel, sourceLocal: sourceLocal, k: 1, expectLoads: 2, expectEvicts: 2)

        // K = 2 with a free slot: load the source into it, leave both
        // resident — loads +1, evicts +0.
        try await runW3Regeneration(rel: rel, sourceLocal: sourceLocal, k: 2, expectLoads: 1, expectEvicts: 0)

        // Source body itself behind ⇒ refusal, no regeneration.
        try await runW3RefusalWhenSourceBehind(rel: rel, sourceLocal: sourceLocal)
    }

    /// Corrupts the source's write-time epoch-0 strip (`halo_lower.0.bin`
    /// — the one `write` lays down per ruling (e), read by sync mode's
    /// `k == 1` case) to a wrong epoch, pre-loads the reader (mirroring
    /// where in `worldTick`'s loop a ghost lookup happens — right after
    /// the reader itself is loaded), then calls `ghostTruth` for `k = 1`
    /// directly and measures ONLY that call's loads/evicts delta.
    private func runW3Regeneration(
        rel: (reader: UInt32, source: UInt32), sourceLocal: UInt64, k: Int,
        expectLoads: Int, expectEvicts: Int
    ) async throws {
        let side = 16, tiles = 4
        let w = try writeTiledObject(side: side, tiles: tiles, label: "w3-regen-k\(k)")
        defer { removeScratch(w.dir) }
        let router = try await TiledGraphRouter(dataRoot: w.dir, graphName: w.name, maxResidentTiles: k)
        let manifest = await router.manifest

        let dir = TiledGraphFiles.tileDirectory(
            dataRoot: w.dir, name: w.name,
            entry: manifest.tiles.first(where: { $0.id == rel.source })!
        )
        let stripPath = "\(dir)/halo_lower.0.bin"
        var bytes = try Data(contentsOf: URL(fileURLWithPath: stripPath))
        // tick_epoch is the 8 bytes at offset 32 (DAHA layout).
        XCTAssertGreaterThanOrEqual(bytes.count, 40)
        var wrongEpoch: UInt64 = 99
        withUnsafeBytes(of: &wrongEpoch) { raw in
            for i in 0..<8 { bytes[32 + i] = raw[i] }
        }
        try bytes.write(to: URL(fileURLWithPath: stripPath))

        _ = try await router.tickLoad(tileId: rel.reader)

        let statusBefore = await router.status()
        _ = try await router.ghostTruth(
            readerTileId: rel.reader, sourceTile: rel.source, sourceLocal: sourceLocal,
            k: 1, mode: .sync, tickedThisRound: []
        )
        let statusAfter = await router.status()

        XCTAssertEqual(statusAfter.loads - statusBefore.loads, expectLoads, "K=\(k) loads delta")
        XCTAssertEqual(statusAfter.evicts - statusBefore.evicts, expectEvicts, "K=\(k) evicts delta")

        let fixedEpoch = try TiledGraphFiles.readLowerStrip(
            dataRoot: w.dir, name: w.name, manifest: manifest, tileId: rel.source, parity: 0
        ).epoch
        XCTAssertEqual(fixedEpoch, 0, "K=\(k) regenerated strip epoch")
    }

    /// No corruption needed: a freshly-written, never-ticked graph has
    /// only the epoch-0 strip. Asking for `k = 3` (sync mode ⇒ expected
    /// epoch `k − 1 = 2`) finds epoch 0 ≠ 2, triggers regeneration, whose
    /// own guard then compares the source's REAL committed epoch (0,
    /// since it was never ticked) against the expected (2) and refuses
    /// without writing anything — "never from a body that is itself
    /// behind."
    private func runW3RefusalWhenSourceBehind(
        rel: (reader: UInt32, source: UInt32), sourceLocal: UInt64
    ) async throws {
        let side = 16, tiles = 4
        let w = try writeTiledObject(side: side, tiles: tiles, label: "w3-behind")
        defer { removeScratch(w.dir) }
        let router = try await TiledGraphRouter(dataRoot: w.dir, graphName: w.name, maxResidentTiles: 2)
        let manifest = await router.manifest

        _ = try await router.tickLoad(tileId: rel.reader)

        do {
            _ = try await router.ghostTruth(
                readerTileId: rel.reader, sourceTile: rel.source, sourceLocal: sourceLocal,
                k: 3, mode: .sync, tickedThisRound: []
            )
            XCTFail("expected haloStale refusal when the source body is behind")
        } catch RouterError.haloStale(let id, let expected, let found) {
            XCTAssertEqual(id, rel.source)
            XCTAssertEqual(expected, 2)
            XCTAssertEqual(found, 0, "the refused source's own committed epoch")
        }

        let strip = try TiledGraphFiles.readLowerStrip(
            dataRoot: w.dir, name: w.name, manifest: manifest, tileId: rel.source, parity: 0
        )
        XCTAssertEqual(strip.epoch, 0, "refusal must not regenerate the strip")
    }

    // MARK: - W4: crash-mid-flush, both crash points, both modes

    func testW4CrashPointsRecovered() async throws {
        for mode: TickMode in [.rank, .sync] {
            for k in [1, 2] {
                try await runW4Scenario(mode: mode, k: k)
            }
        }
    }

    private func runW4Scenario(mode: TickMode, k: Int) async throws {
        let side = 44, tiles = 4
        let refObject = try TiledFixture.generate(side: side)
        referenceTick(engine: refObject.engine, mode: mode, from: 0, count: 3)
        let refTruth = refObject.engine.readTruthStates()

        let w = try writeTiledObject(side: side, tiles: tiles, label: "w4-\(mode)-k\(k)")
        defer { removeScratch(w.dir) }

        let router1 = try await TiledGraphRouter(dataRoot: w.dir, graphName: w.name, maxResidentTiles: k)
        _ = try await router1.worldTick(mode: mode, count: 2)
        let manifest = await router1.manifest
        let tile2 = manifest.tiles.first(where: { $0.id == 2 }) ?? manifest.tiles[min(2, manifest.tiles.count - 1)]
        let tile2Dir = TiledGraphFiles.tileDirectory(dataRoot: w.dir, name: w.name, entry: tile2)
        let epoch2Snapshot = tile2Dir + "-epoch2-snapshot"
        try snapshotDir(tile2Dir, epoch2Snapshot)
        defer { try? FileManager.default.removeItem(atPath: epoch2Snapshot) }

        _ = try await router1.worldTick(mode: mode, count: 1)  // now at epoch 3, tile2 cleanly flushed

        // Snapshot the WHOLE clean epoch-3 graph now, before case (i)
        // mutates tile2's files below — case (ii) needs its own fresh
        // copy of this clean state, not whatever case (i) leaves behind.
        let cleanGraphSnapshot = w.dir + "-clean-epoch3"
        try snapshotDir(w.dir, cleanGraphSnapshot)
        defer { try? FileManager.default.removeItem(atPath: cleanGraphSnapshot) }

        // --- Case (i): body at k-1, BEGIN k present, no COMMIT. ---
        for name in ["body.dags", "body.dags.sha256", "meta.json"] {
            try? FileManager.default.removeItem(atPath: "\(tile2Dir)/\(name)")
            try FileManager.default.copyItem(atPath: "\(epoch2Snapshot)/\(name)", toPath: "\(tile2Dir)/\(name)")
        }
        try TiledGraphFiles.appendFlushWAL(
            path: "\(tile2Dir)/flush.wal", record: "TILE_FLUSH_BEGIN \(tile2.id) 3 \(mode.walToken)"
        )

        do {
            _ = try TiledGraphFiles.loadTileWithGhosts(
                dataRoot: w.dir, name: w.name, manifest: manifest, tileId: tile2.id
            )
            XCTFail("expected tileFlushIncomplete for case (i)")
        } catch RouterError.tileFlushIncomplete(let id, let epoch, let bodyEpoch) {
            XCTAssertEqual(id, tile2.id)
            XCTAssertEqual(epoch, 3)
            XCTAssertEqual(bodyEpoch, 2)
        }

        // AMENDMENT 3: recovery now happens automatically in a writer-role
        // `init`, reported via `openReport` — `recover(mode:)` is gone.
        let router2 = try await TiledGraphRouter(dataRoot: w.dir, graphName: w.name, maxResidentTiles: k, role: .writer)
        let openReport1 = await router2.openReport
        XCTAssertGreaterThanOrEqual(openReport1.recovered, 1, "mode=\(mode) K=\(k) case (i) recovered count")
        let truthAfterCaseI = try await router2.truthArray()
        XCTAssertEqual(truthAfterCaseI, refTruth, "mode=\(mode) K=\(k) case (i) recovered truth mismatch")

        // AMENDMENT 2 letter 1 / AMENDMENT 3: recovered tile is accepted
        // on BOTH paths — the ticker (just asserted via truthArray above)
        // AND the query path (`loadTile`, over the router's OWN
        // now-current manifest, which recovery refreshed in place).
        let manifestAfterCaseI = await router2.manifest
        for entry in manifestAfterCaseI.tiles {
            XCTAssertNoThrow(
                try TiledGraphFiles.loadTile(dataRoot: w.dir, name: w.name, manifest: manifestAfterCaseI, tileId: entry.id),
                "mode=\(mode) K=\(k) case (i): query path must accept tile \(entry.id) after recovery"
            )
        }

        // --- Case (ii): body at k, BEGIN k present, strip/meta not yet
        //     updated (meta rolled back to k-1, parity-1 strip deleted). ---
        // Fresh copy of the CLEAN epoch-3 snapshot (not case (i)'s
        // already-mutated `w.dir`), then simulate the second crash point.
        let w2dir = scratchDir("w4-\(mode)-k\(k)-caseii")
        try? FileManager.default.removeItem(atPath: w2dir)  // scratchDir pre-creates it; copyItem needs it absent
        try FileManager.default.copyItem(atPath: cleanGraphSnapshot, toPath: w2dir)
        defer { removeScratch(w2dir) }
        let tile2Dir2 = TiledGraphFiles.tileDirectory(dataRoot: w2dir, name: w.name, entry: tile2)
        let parity = 3 % 2
        try? FileManager.default.removeItem(atPath: "\(tile2Dir2)/halo_lower.\(parity).bin")
        let metaPath2 = "\(tile2Dir2)/meta.json"
        var meta2 = try JSONDecoder().decode(TileMeta.self, from: Data(contentsOf: URL(fileURLWithPath: metaPath2)))
        meta2.lastPersistedTickEpoch = 2
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(meta2).write(to: URL(fileURLWithPath: metaPath2))
        try TiledGraphFiles.appendFlushWAL(
            path: "\(tile2Dir2)/flush.wal", record: "TILE_FLUSH_BEGIN \(tile2.id) 3 \(mode.walToken)"
        )

        do {
            _ = try TiledGraphFiles.loadTileWithGhosts(
                dataRoot: w2dir, name: w.name, manifest: manifest, tileId: tile2.id
            )
            XCTFail("expected tileFlushIncomplete for case (ii)")
        } catch RouterError.tileFlushIncomplete(let id, let epoch, let bodyEpoch) {
            XCTAssertEqual(id, tile2.id)
            XCTAssertEqual(epoch, 3)
            XCTAssertEqual(bodyEpoch, 3)
        }

        let router3 = try await TiledGraphRouter(dataRoot: w2dir, graphName: w.name, maxResidentTiles: k, role: .writer)
        let openReport2 = await router3.openReport
        XCTAssertGreaterThanOrEqual(openReport2.recovered, 1, "mode=\(mode) K=\(k) case (ii) recovered count")
        let truthAfterCaseII = try await router3.truthArray()
        XCTAssertEqual(truthAfterCaseII, refTruth, "mode=\(mode) K=\(k) case (ii) recovered truth mismatch")

        let epochs3 = try await router3.tileEpochs()
        XCTAssertEqual(epochs3[tile2.id]?.metaEpoch, 3)
        XCTAssertEqual(epochs3[tile2.id]?.bodyEpoch, 3)

        let manifestAfterCaseII = await router3.manifest
        XCTAssertEqual(manifestAfterCaseII.tiles.first(where: { $0.id == tile2.id })?.tickEpoch, 3,
                        "mode=\(mode) K=\(k) case (ii): manifest entry must be refreshed to epoch 3")
        for entry in manifestAfterCaseII.tiles {
            XCTAssertNoThrow(
                try TiledGraphFiles.loadTile(dataRoot: w2dir, name: w.name, manifest: manifestAfterCaseII, tileId: entry.id),
                "mode=\(mode) K=\(k) case (ii): query path must accept tile \(entry.id) after recovery"
            )
        }
    }

    // MARK: - W6: printed, not gated

    func testW6Printed() async throws {
        let side = 128, tiles = 8, k = 1
        for mode: TickMode in [.rank, .sync] {
            let w = try writeTiledObject(side: side, tiles: tiles, label: "w6-\(mode)")
            defer { removeScratch(w.dir) }
            let router = try await TiledGraphRouter(dataRoot: w.dir, graphName: w.name, maxResidentTiles: k)
            let report = try await router.worldTick(mode: mode, count: 1)
            print("W6 mode=\(mode) side=\(side) tiles=\(tiles) K=\(k): " +
                  "tick_ms_per_tile(max)=\(String(format: "%.3f", report.tickMsPerTile)) " +
                  "flush_ms_per_tile(max)=\(String(format: "%.3f", report.flushMsPerTile)) " +
                  "halo_bytes=\(report.haloBytes) loads=\(report.loads) evicts=\(report.evicts) " +
                  "tiles_ticked=\(report.tilesTicked)")
            print("  spec §6.6.2/6.6.3 (10^9-node design-budget tile, for reference — our tiles are " +
                  "10^2-10^3-node scale, not comparable in absolute terms): " +
                  "naive tick ~2s/10^9, bandwidth-bound ~0.3-2s/10^9; pre-fetch swap ~6-12s/10^9 tile")
        }
    }

    // MARK: - AMENDMENT 1: manifest entry refreshed at every flush

    func testManifestEntryRefreshedAtEveryFlush_rank() async throws {
        try await runManifestEntryRefreshedAtEveryFlush(mode: .rank)
    }

    func testManifestEntryRefreshedAtEveryFlush_sync() async throws {
        try await runManifestEntryRefreshedAtEveryFlush(mode: .sync)
    }

    private func runManifestEntryRefreshedAtEveryFlush(mode: TickMode) async throws {
        let side = 44, tiles = 4
        let refObject = try TiledFixture.generate(side: side)
        referenceTick(engine: refObject.engine, mode: mode, from: 0, count: 3)

        let w = try writeTiledObject(side: side, tiles: tiles, label: "amend1-\(mode)")
        defer { removeScratch(w.dir) }

        let router = try await TiledGraphRouter(dataRoot: w.dir, graphName: w.name, maxResidentTiles: 1)
        let report = try await router.worldTick(mode: mode, count: 3)
        XCTAssertEqual(report.epoch, 3, "mode=\(mode) world tick epoch")

        // Decode manifest.json fresh off disk — the independent, on-disk
        // check (not the router's own in-memory cache of itself).
        let manifest = try TiledGraphFiles.readManifest(dataRoot: w.dir, name: w.name)
        for entry in manifest.tiles {
            XCTAssertEqual(entry.tickEpoch, 3, "mode=\(mode) tile \(entry.id) manifest tickEpoch")

            let dir = TiledGraphFiles.tileDirectory(dataRoot: w.dir, name: w.name, entry: entry)
            let bodyBytes = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/body.dags"))
            let expectedHash = SHA256.hash(data: bodyBytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(entry.bodySHA256, expectedHash, "mode=\(mode) tile \(entry.id) manifest bodySHA256 vs recomputed sha256")

            let sidecarText = try String(contentsOfFile: "\(dir)/body.dags.sha256", encoding: .utf8)
            let sidecarHash = sidecarText.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(entry.bodySHA256, sidecarHash, "mode=\(mode) tile \(entry.id) manifest bodySHA256 vs sidecar")
        }

        // A FRESH router (K = 2): every tile's query-path load succeeds,
        // and one TILED-level SELECT equals the untiled engine after the
        // same 3 ticks.
        let freshRouter = try await TiledGraphRouter(dataRoot: w.dir, graphName: w.name, maxResidentTiles: 2)
        for entry in manifest.tiles {
            XCTAssertNoThrow(
                try TiledGraphFiles.loadTile(dataRoot: w.dir, name: w.name, manifest: manifest, tileId: entry.id),
                "mode=\(mode) tile \(entry.id) query-path load after ticking"
            )
        }

        let refRanks = refObject.engine.readRanks()
        var maxRank: UInt64 = 0
        for r in refRanks { maxRank = max(maxRank, r) }
        for truthVal: UInt8 in [0, 1, 2] {
            let expectedLocals = TruthRankIndex().select(
                truth: truthVal, rankLo: 0, rankHi: maxRank,
                engine: refObject.engine, nodeCount: refObject.engine.nodeCount
            )
            let expectedGlobal = expectedLocals.map { w.report.globalOf[$0] }.sorted()
            let got = try await freshRouter.runSelect(truth: truthVal, rankLo: 0, rankHi: maxRank)
            XCTAssertEqual(
                got.map { $0.raw }.sorted(), expectedGlobal,
                "mode=\(mode) truth=\(truthVal) TILED SELECT vs untiled engine after 3 ticks"
            )
        }
    }

    // MARK: - AMENDMENT 2, letter 1(b): clean-but-disagreeing manifest sha refused

    /// Snapshots every regular file under `dir` (recursive), keyed by
    /// full path — used to prove "nothing else moved" after a refusal.
    private func snapshotAllFiles(under dir: String) throws -> [String: Data] {
        var result: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(atPath: dir) else { return result }
        for case let relPath as String in enumerator {
            let full = "\(dir)/\(relPath)"
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            result[full] = try Data(contentsOf: URL(fileURLWithPath: full))
        }
        return result
    }

    func testCleanTileHashDisagreementRefused() async throws {
        let side = 44, tiles = 4
        let w = try writeTiledObject(side: side, tiles: tiles, label: "amend2-hashmismatch")
        defer { removeScratch(w.dir) }

        let router1 = try await TiledGraphRouter(dataRoot: w.dir, graphName: w.name, maxResidentTiles: 2)
        _ = try await router1.worldTick(mode: .rank, count: 1)

        let manifest = try TiledGraphFiles.readManifest(dataRoot: w.dir, name: w.name)
        let before = try snapshotAllFiles(under: w.dir)

        // Corrupt the HIGHEST-id tile's manifest bodySHA256 — rank order
        // is descending, so this tile is processed FIRST; the whole round
        // then aborts before touching any other tile's files, making
        // "untouched tiles unchanged" hold for every tile but this one.
        // The sidecar stays intact: this is "clean but disagreeing," not
        // a torn flush.
        guard let victim = manifest.tiles.max(by: { $0.id < $1.id }) else {
            XCTFail("no tiles"); return
        }
        var tiles2 = manifest.tiles
        let idx = tiles2.firstIndex(where: { $0.id == victim.id })!
        tiles2[idx] = TiledGraphFiles.TileEntry(
            id: victim.id, rankLo: victim.rankLo, rankHi: victim.rankHi, nodeCount: victim.nodeCount,
            bodySHA256: String(repeating: "0", count: 63) + "1",
            crossingsOut: victim.crossingsOut, crossingsIn: victim.crossingsIn,
            engineIndexOf: victim.engineIndexOf, tickEpoch: victim.tickEpoch
        )
        let corruptedManifest = TiledGraphFiles.Manifest(
            format: manifest.format, version: manifest.version, name: manifest.name,
            boundaries: manifest.boundaries, globalNodeCount: manifest.globalNodeCount, tiles: tiles2
        )
        try TiledGraphFiles.writeManifest(dataRoot: w.dir, name: w.name, manifest: corruptedManifest)

        // A FRESH router re-reads the corrupted manifest — the ticker refuses.
        let router2 = try await TiledGraphRouter(dataRoot: w.dir, graphName: w.name, maxResidentTiles: 2)
        do {
            _ = try await router2.worldTick(mode: .rank, count: 1)
            XCTFail("expected tileHashMismatch")
        } catch RouterError.tileHashMismatch(let id, _, _) {
            XCTAssertEqual(id, victim.id)
        }

        // The query path refuses the same way, naming the same tile.
        do {
            _ = try TiledGraphFiles.loadTile(dataRoot: w.dir, name: w.name, manifest: corruptedManifest, tileId: victim.id)
            XCTFail("expected tileHashMismatch on the query path too")
        } catch RouterError.tileHashMismatch(let id, _, _) {
            XCTAssertEqual(id, victim.id)
        }

        // Untouched tiles' own files (body/strip/meta/flush.wal) are
        // unchanged — the manifest.json edit above is the only deliberate
        // write, and the aborted worldTick touched nothing.
        let after = try snapshotAllFiles(under: w.dir)
        let manifestPath = "\(TiledGraphFiles.graphDirectory(dataRoot: w.dir, name: w.name))/manifest.json"
        for (path, beforeBytes) in before {
            if path == manifestPath { continue }
            XCTAssertEqual(after[path], beforeBytes, "file changed by a refused hash check: \(path)")
        }
    }

    // MARK: - AMENDMENT 3: partial-round completion at open (role-gated)

    private struct Interruption {
        let dir: String
        let name: String
        let restoredTileIds: Set<UInt32>
        let k: UInt64
        let refTruthAtK: [UInt8]
        let refTruthAtKPlus1: [UInt8]
    }

    private enum TestSetupError: Error { case missingTileEntry(UInt32) }

    /// Builds a "between-tiles" interruption on a side-44/tiles-4/K=1
    /// object (boundaries [5, 11, 17]): ticked to world epoch k = 3 in
    /// `mode`, then the tiles LATER in that mode's processing order
    /// rolled back to their epoch (k − 1) files — body, sidecar, both
    /// `halo_lower` parity files, `meta.json`, `flush.wal` (clean,
    /// ending in COMMIT at k − 1) — and their manifest entries
    /// (`bodySHA256`, `tickEpoch`) rolled back to match. Every tile's
    /// `flush.wal` stays clean; only the manifest's per-tile epochs and
    /// the rolled-back tiles' own files differ from the live epoch-3
    /// state.
    private func buildBetweenTilesInterruption(mode: TickMode, label: String) async throws -> Interruption {
        let side = 44, tiles = 4
        let refObject = try TiledFixture.generate(side: side)
        referenceTick(engine: refObject.engine, mode: mode, from: 0, count: 3)
        let refTruthAtK = refObject.engine.readTruthStates()
        referenceTick(engine: refObject.engine, mode: mode, from: 3, count: 1)
        let refTruthAtKPlus1 = refObject.engine.readTruthStates()

        let w = try writeTiledObject(side: side, tiles: tiles, label: "\(label)-\(mode)")
        let router = try await TiledGraphRouter(dataRoot: w.dir, graphName: w.name, maxResidentTiles: 1)
        _ = try await router.worldTick(mode: mode, count: 2)
        let manifest = await router.manifest
        let epoch2Snapshot = w.dir + "-epoch2"
        try snapshotDir(w.dir, epoch2Snapshot)

        _ = try await router.worldTick(mode: mode, count: 1)  // now epoch 3, clean

        let interruptedDir = scratchDir("\(label)-\(mode)-torn")
        try? FileManager.default.removeItem(atPath: interruptedDir)
        try FileManager.default.copyItem(atPath: w.dir, toPath: interruptedDir)

        let descending = manifest.tiles.map { $0.id }.sorted(by: >)
        let ascending = manifest.tiles.map { $0.id }.sorted(by: <)
        let order = (mode == .rank) ? descending : ascending
        let cut = 2
        let restoredIds = Set(order.suffix(cut))

        let epoch2Manifest = try TiledGraphFiles.readManifest(dataRoot: epoch2Snapshot, name: w.name)
        let liveManifest = try TiledGraphFiles.readManifest(dataRoot: interruptedDir, name: w.name)
        var liveTiles = liveManifest.tiles
        for tileId in restoredIds {
            guard let liveEntry = liveTiles.first(where: { $0.id == tileId }),
                  let epoch2Entry = epoch2Manifest.tiles.first(where: { $0.id == tileId }) else {
                throw TestSetupError.missingTileEntry(tileId)
            }
            let liveDir = TiledGraphFiles.tileDirectory(dataRoot: interruptedDir, name: w.name, entry: liveEntry)
            let epoch2Dir = TiledGraphFiles.tileDirectory(dataRoot: epoch2Snapshot, name: w.name, entry: epoch2Entry)
            for name in ["body.dags", "body.dags.sha256", "meta.json", "halo_lower.0.bin", "halo_lower.1.bin", "flush.wal"] {
                let src = "\(epoch2Dir)/\(name)"
                let dst = "\(liveDir)/\(name)"
                try? FileManager.default.removeItem(atPath: dst)
                if FileManager.default.fileExists(atPath: src) {
                    try FileManager.default.copyItem(atPath: src, toPath: dst)
                }
            }
            if let idx = liveTiles.firstIndex(where: { $0.id == tileId }) {
                liveTiles[idx] = epoch2Entry
            }
        }
        let rolledManifest = TiledGraphFiles.Manifest(
            format: liveManifest.format, version: liveManifest.version, name: liveManifest.name,
            boundaries: liveManifest.boundaries, globalNodeCount: liveManifest.globalNodeCount, tiles: liveTiles
        )
        try TiledGraphFiles.writeManifest(dataRoot: interruptedDir, name: w.name, manifest: rolledManifest)

        removeScratch(epoch2Snapshot)
        removeScratch(w.dir)

        return Interruption(
            dir: interruptedDir, name: w.name, restoredTileIds: restoredIds,
            k: 3, refTruthAtK: refTruthAtK, refTruthAtKPlus1: refTruthAtKPlus1
        )
    }

    func testPartialRoundCompletedAtOpen_rank() async throws {
        try await runPartialRoundCompletedAtOpen(mode: .rank)
    }

    func testPartialRoundCompletedAtOpen_sync() async throws {
        try await runPartialRoundCompletedAtOpen(mode: .sync)
    }

    private func runPartialRoundCompletedAtOpen(mode: TickMode) async throws {
        let interruption = try await buildBetweenTilesInterruption(mode: mode, label: "partial")
        defer { removeScratch(interruption.dir) }

        // (1) A reader opened BEFORE the writer's completion refuses a
        //     torn world by name.
        do {
            _ = try await TiledGraphRouter(
                dataRoot: interruption.dir, graphName: interruption.name, maxResidentTiles: 2, role: .reader
            )
            XCTFail("mode=\(mode): expected worldTorn for a reader opening a torn world")
        } catch RouterError.worldTorn(let mn, let mx) {
            XCTAssertEqual(mn, interruption.k - 1, "mode=\(mode) worldTorn min")
            XCTAssertEqual(mx, interruption.k, "mode=\(mode) worldTorn max")
        }

        // (2) A writer completes the partial round at open.
        let writer = try await TiledGraphRouter(
            dataRoot: interruption.dir, graphName: interruption.name, maxResidentTiles: 1, role: .writer
        )
        let openReport = await writer.openReport
        XCTAssertEqual(openReport.recovered, 0, "mode=\(mode) recovered (no dangling BEGIN in this scenario)")
        XCTAssertEqual(openReport.completed, interruption.restoredTileIds.count, "mode=\(mode) completed count")
        let statusAfterOpen = await writer.status()
        XCTAssertEqual(statusAfterOpen.epochMin, interruption.k, "mode=\(mode) epochMin after open")
        XCTAssertEqual(statusAfterOpen.epochMax, interruption.k, "mode=\(mode) epochMax after open")
        let truthAfterOpen = try await writer.truthArray()
        XCTAssertEqual(truthAfterOpen, interruption.refTruthAtK, "mode=\(mode) truth after open, before any tick")

        // (3) A reader opened AFTER the writer's completion opens clean.
        let reader = try await TiledGraphRouter(
            dataRoot: interruption.dir, graphName: interruption.name, maxResidentTiles: 2, role: .reader
        )
        let readerStatus = await reader.status()
        XCTAssertEqual(readerStatus.epochMin, interruption.k, "mode=\(mode) reader epochMin")
        XCTAssertEqual(readerStatus.epochMax, interruption.k, "mode=\(mode) reader epochMax")

        // (4) worldTick(count: 1) on the writer ticks every tile once, to k + 1.
        let report = try await writer.worldTick(mode: mode, count: 1)
        XCTAssertEqual(report.epoch, interruption.k + 1, "mode=\(mode) epoch after one more world tick")
        let manifestNow = await writer.manifest
        XCTAssertEqual(report.tilesTicked, manifestNow.tiles.count, "mode=\(mode) tilesTicked == tileCount")
        let truthAfterTick = try await writer.truthArray()
        XCTAssertEqual(truthAfterTick, interruption.refTruthAtKPlus1, "mode=\(mode) truth after k+1 ticks")
    }

    func testPartialRoundModeMismatchRefused() async throws {
        let interruption = try await buildBetweenTilesInterruption(mode: .rank, label: "modemismatch")
        defer { removeScratch(interruption.dir) }

        let manifest = try TiledGraphFiles.readManifest(dataRoot: interruption.dir, name: interruption.name)
        guard let atMaxEntry = manifest.tiles.first(where: { !interruption.restoredTileIds.contains($0.id) }) else {
            XCTFail("no at-max tile found"); return
        }
        let dir = TiledGraphFiles.tileDirectory(dataRoot: interruption.dir, name: interruption.name, entry: atMaxEntry)
        let walPath = "\(dir)/flush.wal"

        let before = try snapshotAllFiles(under: interruption.dir)

        // Edit that tile's LAST BEGIN record's mode field (third field)
        // to the OTHER mode — the COMMIT (and everything else) stays put.
        var text = try String(contentsOfFile: walPath, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let lastBeginIdx = lines.lastIndex(where: { $0.hasPrefix("TILE_FLUSH_BEGIN") }) else {
            XCTFail("no BEGIN record to edit"); return
        }
        var parts = lines[lastBeginIdx].split(separator: " ").map(String.init)
        XCTAssertEqual(parts.count, 4, "BEGIN record must carry the mode field")
        parts[3] = (parts[3] == "rank") ? "sync" : "rank"
        lines[lastBeginIdx] = parts.joined(separator: " ")
        text = lines.joined(separator: "\n") + "\n"
        try text.write(toFile: walPath, atomically: true, encoding: .utf8)

        do {
            _ = try await TiledGraphRouter(
                dataRoot: interruption.dir, graphName: interruption.name, maxResidentTiles: 1, role: .writer
            )
            XCTFail("expected partialRoundModeMismatch")
        } catch RouterError.partialRoundModeMismatch(let tiles) {
            XCTAssertTrue(tiles.keys.contains(atMaxEntry.id), "mismatch must name the edited tile")
        }

        // Nothing else on disk moved — the refusal happens before any
        // tile is ticked or flushed.
        let after = try snapshotAllFiles(under: interruption.dir)
        for (path, beforeBytes) in before {
            if path == walPath { continue }
            XCTAssertEqual(after[path], beforeBytes, "file changed by a refused writer init: \(path)")
        }
    }
}
