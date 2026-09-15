import XCTest
@testable import DagDB

/// AMENDMENT 8 — the strip's register byte is two bytes, gates (i) and
/// (ii) (`docs/contracts/TICKING_GATES_FROZEN.md`).
///
/// (i) **Mode sequences.** One file, `halo_lower.<parity>.bin`, serves two
///     readers: a rank-mode reader at round `k` wants a register's
///     PRE-latch value at `k`; a sync-mode reader at round `k + 1` reads
///     the same parity file wanting the vector at `k`, the POST-latch
///     value. With one truth byte per entry, a rank round followed by a
///     sync round read a byte that was wrong for one of them. With two,
///     each takes its own. Gated over 12 rounds of `rank, sync, rank,
///     sync, …` and `sync, rank, rank, sync, …`, three-way (tiled ==
///     untiled == reference), every side, `K ∈ {1, 2}`, each round's mode
///     read back off its `TILE_FLUSH_BEGIN` record.
///
/// (ii) **Recovery case (ii) then a rank-mode partial-round completion.**
///      A strip rebuilt from a committed body at `k` yields `truthPost`
///      directly; `truthPre` for a register is that same source's
///      `truthPost` in the previous-parity strip. AMENDMENT 7 wrote the
///      post-latch byte there and called the gap out of reach for a
///      rank-mode reader — it is not: a tile below, completed at round `k`
///      from the regenerated strip, reads exactly it.
final class TiledModeSequenceTests: XCTestCase {

    // MARK: - Scratch

    private func scratchDir(_ label: String) -> String {
        let dir = NSTemporaryDirectory() + "dagdb-a8-\(label)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeScratch(_ dir: String) { try? FileManager.default.removeItem(atPath: dir) }

    private func snapshotDir(_ src: String, _ dst: String) throws {
        try? FileManager.default.removeItem(atPath: dst)
        try FileManager.default.copyItem(atPath: src, toPath: dst)
    }

    private struct WrittenObject {
        let dir: String
        let name: String
    }

    private func writeTiledObject(side: Int, tiles: Int, label: String) throws -> WrittenObject {
        let object = try TiledFixture.generate(side: side)
        let dir = scratchDir(label)
        let boundaries = TiledFixture.boundaries(side: side, tiles: tiles)
        _ = try TiledGraphFiles.write(object: object, dataRoot: dir, name: "g", boundaries: boundaries)
        return WrittenObject(dir: dir, name: "g")
    }

    // MARK: - (i) Mode sequences

    /// `rank, sync` repeated — the minimal alternation, every boundary a
    /// mode change.
    private static func sequenceA(rounds: Int) -> [TickMode] {
        (0..<rounds).map { $0 % 2 == 0 ? TickMode.rank : TickMode.sync }
    }

    /// `sync, rank, rank, sync` repeated — two rank rounds back to back
    /// inside it, so a sync round follows a rank round that followed a
    /// rank round (the case a single-byte strip gets wrong twice over).
    private static func sequenceB(rounds: Int) -> [TickMode] {
        let period: [TickMode] = [.sync, .rank, .rank, .sync]
        return (0..<rounds).map { period[$0 % period.count] }
    }

    private func runModeSequence(
        side: Int, tiles: Int, ks: [Int], modes: [TickMode], label: String
    ) async throws {
        for k in ks {
            let refObject = try TiledFixture.generate(side: side)
            let reference = TiledReference(engine: refObject.engine)
            var refVector = refObject.engine.readTruthStates()

            let w = try writeTiledObject(side: side, tiles: tiles, label: "\(label)-k\(k)")
            defer { removeScratch(w.dir) }
            let router = try await TiledGraphRouter(
                dataRoot: w.dir, graphName: w.name, maxResidentTiles: k)

            var changes: [Int] = []
            var modesReadBack: [String] = []

            for (i, mode) in modes.enumerated() {
                let epoch = UInt64(i + 1)
                let before = refVector

                switch mode {
                case .rank: refObject.engine.tick(tickNumber: UInt32(epoch))
                case .sync: refObject.engine.tickSync(tickNumber: UInt32(epoch))
                }
                refVector = reference.tick(refVector, mode: mode)

                let report = try await router.worldTick(mode: mode, count: 1)
                XCTAssertEqual(
                    report.epoch, epoch,
                    "side=\(side) tiles=\(tiles) K=\(k) round=\(epoch) epoch")

                let want = refObject.engine.readTruthStates()
                let got = try await router.truthArray()
                XCTAssertEqual(
                    TiledReference.differing(refVector, want).count, 0,
                    "side=\(side) tiles=\(tiles) K=\(k) round=\(epoch) mode=\(mode): "
                    + "reference vs untiled engine")
                XCTAssertEqual(
                    TiledReference.differing(got, want).count, 0,
                    "side=\(side) tiles=\(tiles) K=\(k) round=\(epoch) mode=\(mode): "
                    + "tiled vs untiled engine")
                XCTAssertEqual(
                    TiledReference.differing(got, refVector).count, 0,
                    "side=\(side) tiles=\(tiles) K=\(k) round=\(epoch) mode=\(mode): "
                    + "tiled vs reference")

                changes.append(TiledReference.differing(before, refVector).count)

                // The round's mode as the WAL records it — every tile's own
                // `TILE_FLUSH_BEGIN <tile> <epoch> <rank|sync>` at this
                // epoch, read back off disk, not from the caller's argument.
                let manifestNow = await router.manifest
                var tokens = Set<String>()
                for entry in manifestNow.tiles {
                    let dir = TiledGraphFiles.tileDirectory(
                        dataRoot: w.dir, name: w.name, entry: entry)
                    guard let token = TiledGraphFiles.lastCommittedBeginMode(dir: dir, epoch: epoch) else {
                        XCTFail("tile \(entry.id) has no BEGIN record at epoch \(epoch)")
                        continue
                    }
                    tokens.insert(token)
                    XCTAssertEqual(
                        token, mode.walToken,
                        "side=\(side) tiles=\(tiles) K=\(k) round=\(epoch) tile \(entry.id) "
                        + "BEGIN mode field")
                }
                XCTAssertEqual(tokens.count, 1, "one mode per round, round \(epoch)")
                modesReadBack.append(tokens.first ?? "?")

                // Every tile flushed at this epoch, meta and body agreeing.
                let epochs = try await router.tileEpochs()
                for (id, pair) in epochs {
                    XCTAssertEqual(pair.metaEpoch, epoch, "tile \(id) meta epoch at round \(epoch)")
                    XCTAssertEqual(pair.bodyEpoch, epoch, "tile \(id) body epoch at round \(epoch)")
                }
            }

            XCTAssertFalse(
                changes.contains(0),
                "side=\(side) tiles=\(tiles) K=\(k): a static round is a free equality")
            print("A8-MODE-SEQ side=\(side) tiles=\(tiles) K=\(k) "
                + "modes=\(modesReadBack.joined(separator: ",")) "
                + "changes_per_round=\(changes)")
        }
    }

    func testModeSequenceAlternating_side16() async throws {
        try await runModeSequence(
            side: 16, tiles: 4, ks: [1, 2], modes: Self.sequenceA(rounds: 12), label: "seqA-16")
    }

    func testModeSequenceAlternating_side44() async throws {
        try await runModeSequence(
            side: 44, tiles: 4, ks: [1, 2], modes: Self.sequenceA(rounds: 12), label: "seqA-44")
    }

    func testModeSequenceAlternating_side128() async throws {
        try await runModeSequence(
            side: 128, tiles: 8, ks: [1, 2], modes: Self.sequenceA(rounds: 12), label: "seqA-128")
    }

    func testModeSequenceSyncRankRankSync_side16() async throws {
        try await runModeSequence(
            side: 16, tiles: 4, ks: [1, 2], modes: Self.sequenceB(rounds: 12), label: "seqB-16")
    }

    func testModeSequenceSyncRankRankSync_side44() async throws {
        try await runModeSequence(
            side: 44, tiles: 4, ks: [1, 2], modes: Self.sequenceB(rounds: 12), label: "seqB-44")
    }

    func testModeSequenceSyncRankRankSync_side128() async throws {
        try await runModeSequence(
            side: 128, tiles: 8, ks: [1, 2], modes: Self.sequenceB(rounds: 12), label: "seqB-128")
    }

    // MARK: - (ii) case (ii) recovery, then a rank-mode partial round

    private struct RegisterCrossing {
        let tiles: Int
        let register: Int              // engine index of the register node
        let sourceTile: UInt32         // the tile that OWNS it
        let readersBelow: [Int]        // engine indices, all in LOWER tiles
    }

    /// The register whose strip entry a lower tile reads, chosen from the
    /// object rather than invented: the cross-tile `(reader, source)` edges
    /// whose source is a register and whose reader sits in a lower tile,
    /// grouped by register, the one with the most distinct readers below
    /// winning (ties by lowest engine index). Tilings are tried in the
    /// order given; the first that has one is used and named.
    private func findRegisterCrossing(side: Int, tilings: [Int]) -> RegisterCrossing? {
        guard let object = try? TiledFixture.generate(side: side) else { return nil }
        let reference = TiledReference(engine: object.engine)
        for tiles in tilings {
            let tileOf = reference.tileAssignment(
                boundaries: TiledFixture.boundaries(side: side, tiles: tiles))
            var below: [Int: Set<Int>] = [:]
            for c in reference.crossings(tileOf: tileOf)
            where reference.isRegister[c.source] && tileOf[c.reader] < tileOf[c.source] {
                below[c.source, default: []].insert(c.reader)
            }
            guard !below.isEmpty else {
                print("A8-CASE-II-SCAN side=\(side) tiles=\(tiles): no register is read from a lower tile")
                continue
            }
            let best = below.max { a, b in
                a.value.count != b.value.count ? a.value.count < b.value.count : a.key > b.key
            }!
            return RegisterCrossing(
                tiles: tiles, register: best.key, sourceTile: UInt32(tileOf[best.key]),
                readersBelow: best.value.sorted())
        }
        return nil
    }

    func testCaseIIRecoveryThenRankCompletionAcrossARegister() async throws {
        let side = 44
        guard let pick = findRegisterCrossing(side: side, tilings: [4, 8, 2]) else {
            return XCTFail("side \(side) has no register read from a lower tile in any frozen tiling")
        }
        print("A8-CASE-II side=\(side) tiles=\(pick.tiles) register=\(pick.register) "
            + "owning_tile=\(pick.sourceTile) readers_below=\(pick.readersBelow.count) "
            + "reader_nodes=\(pick.readersBelow)")

        for k in [1, 2] {
            try await runCaseIIThenCompletion(side: side, pick: pick, maxResident: k)
        }
    }

    private func runCaseIIThenCompletion(
        side: Int, pick: RegisterCrossing, maxResident: Int
    ) async throws {
        let tiles = pick.tiles
        let mode = TickMode.rank
        let kEpoch: UInt64 = 3

        // The reference trajectory: untiled engine and Room A, three rank
        // rounds, with the vector at k − 1 kept as well (that is the
        // register's PRE-latch value at k, which the regenerated strip
        // must carry).
        let refObject = try TiledFixture.generate(side: side)
        let reference = TiledReference(engine: refObject.engine)
        var refVector = refObject.engine.readTruthStates()
        var refAtKMinus1: [UInt8] = refVector
        for round in 1...Int(kEpoch) {
            refObject.engine.tick(tickNumber: UInt32(round))
            refVector = reference.tickRank(refVector)
            if round == Int(kEpoch) - 1 { refAtKMinus1 = refVector }
        }
        let refAtK = refObject.engine.readTruthStates()
        XCTAssertEqual(
            TiledReference.differing(refAtK, refVector).count, 0,
            "case (ii) setup: reference vs untiled engine at k=\(kEpoch)")

        // A live graph ticked to k, with a snapshot of the clean k − 1
        // state to roll the tiles below the crash point back to.
        let w = try writeTiledObject(side: side, tiles: tiles, label: "caseii-k\(maxResident)")
        defer { removeScratch(w.dir) }
        let router0 = try await TiledGraphRouter(
            dataRoot: w.dir, graphName: w.name, maxResidentTiles: maxResident)
        _ = try await router0.worldTick(mode: mode, count: Int(kEpoch) - 1)
        let priorSnapshot = w.dir + "-k\(kEpoch - 1)"
        try snapshotDir(w.dir, priorSnapshot)
        defer { removeScratch(priorSnapshot) }
        _ = try await router0.worldTick(mode: mode, count: 1)
        let cleanAtK = try await router0.truthArray()
        XCTAssertEqual(
            TiledReference.differing(cleanAtK, refAtK).count, 0,
            "case (ii) setup: the clean tiled world at k must already equal the reference")

        let torn = scratchDir("caseii-torn-k\(maxResident)")
        try snapshotDir(w.dir, torn)
        defer { removeScratch(torn) }

        let liveManifest = try TiledGraphFiles.readManifest(dataRoot: torn, name: w.name)
        let priorManifest = try TiledGraphFiles.readManifest(dataRoot: priorSnapshot, name: w.name)
        guard let crashEntry = liveManifest.tiles.first(where: { $0.id == pick.sourceTile }) else {
            return XCTFail("tile \(pick.sourceTile) missing from the manifest")
        }
        let crashDir = TiledGraphFiles.tileDirectory(dataRoot: torn, name: w.name, entry: crashEntry)

        // --- Crash point (ii) on the register's OWN tile: the body was
        //     renamed at k, the strip / meta / manifest entry never
        //     rewritten, no COMMIT. ---
        try? FileManager.default.removeItem(atPath: "\(crashDir)/halo_lower.\(kEpoch % 2).bin")
        let metaPath = "\(crashDir)/meta.json"
        var meta = try JSONDecoder().decode(
            TileMeta.self, from: Data(contentsOf: URL(fileURLWithPath: metaPath)))
        meta.lastPersistedTickEpoch = kEpoch - 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(meta).write(to: URL(fileURLWithPath: metaPath))
        try TiledGraphFiles.appendFlushWAL(
            path: "\(crashDir)/flush.wal",
            record: "TILE_FLUSH_BEGIN \(crashEntry.id) \(kEpoch) \(mode.walToken)")

        // --- And the between-tiles tear: every tile BELOW the crash point
        //     (the rest of the rank-mode descending order) back at k − 1,
        //     clean WALs, manifest entries rolled with them. ---
        var rolledTiles = liveManifest.tiles
        var restoredIds: [UInt32] = []
        for entry in liveManifest.tiles where entry.id < pick.sourceTile {
            guard let priorEntry = priorManifest.tiles.first(where: { $0.id == entry.id }) else {
                return XCTFail("tile \(entry.id) missing from the k−1 manifest")
            }
            let liveDir = TiledGraphFiles.tileDirectory(dataRoot: torn, name: w.name, entry: entry)
            let priorDir = TiledGraphFiles.tileDirectory(
                dataRoot: priorSnapshot, name: w.name, entry: priorEntry)
            for file in ["body.dags", "body.dags.sha256", "meta.json",
                         "halo_lower.0.bin", "halo_lower.1.bin", "flush.wal"] {
                try? FileManager.default.removeItem(atPath: "\(liveDir)/\(file)")
                if FileManager.default.fileExists(atPath: "\(priorDir)/\(file)") {
                    try FileManager.default.copyItem(
                        atPath: "\(priorDir)/\(file)", toPath: "\(liveDir)/\(file)")
                }
            }
            if let idx = rolledTiles.firstIndex(where: { $0.id == entry.id }) {
                rolledTiles[idx] = priorEntry
            }
            restoredIds.append(entry.id)
        }
        // The crashed tile's own manifest entry never got rewritten either
        // (it is written after the meta, before the COMMIT).
        if let idx = rolledTiles.firstIndex(where: { $0.id == pick.sourceTile }),
           let priorEntry = priorManifest.tiles.first(where: { $0.id == pick.sourceTile }) {
            rolledTiles[idx] = priorEntry
        }
        try TiledGraphFiles.writeManifest(
            dataRoot: torn, name: w.name,
            manifest: TiledGraphFiles.Manifest(
                format: liveManifest.format, version: liveManifest.version, name: liveManifest.name,
                boundaries: liveManifest.boundaries, globalNodeCount: liveManifest.globalNodeCount,
                tiles: rolledTiles))

        XCTAssertFalse(
            restoredIds.isEmpty,
            "the register's tile \(pick.sourceTile) has no tile below it — nothing to complete")

        // --- Writer open: recover the crashed tile (case ii), regenerate
        //     BOTH bytes, complete the round for the tiles below. ---
        let writer = try await TiledGraphRouter(
            dataRoot: torn, graphName: w.name, maxResidentTiles: maxResident, role: .writer)
        let openReport = await writer.openReport
        XCTAssertEqual(openReport.recovered, 1, "K=\(maxResident) recovered (the crashed tile)")
        XCTAssertEqual(
            openReport.completed, restoredIds.count,
            "K=\(maxResident) completed (the tiles below it)")

        let status = await writer.status()
        XCTAssertEqual(status.epochMin, kEpoch, "K=\(maxResident) epochMin after open")
        XCTAssertEqual(status.epochMax, kEpoch, "K=\(maxResident) epochMax after open")

        // The regenerated strip carries BOTH bytes, each reconstructed:
        // `truthPost` from the committed body at k, `truthPre` from the
        // same source's `truthPost` in the previous-parity strip.
        let manifestAfter = await writer.manifest
        var localOf = [(tile: UInt32, local: UInt64)](
            repeating: (0, 0), count: Int(manifestAfter.globalNodeCount))
        for entry in manifestAfter.tiles {
            for (li, engineIndex) in entry.engineIndexOf.enumerated() {
                localOf[Int(engineIndex)] = (entry.id, UInt64(li))
            }
        }
        let addr = localOf[pick.register]
        XCTAssertEqual(addr.tile, pick.sourceTile, "the register's owning tile")
        let (stripEpoch, stripValues) = try TiledGraphFiles.readLowerStrip(
            dataRoot: torn, name: w.name, manifest: manifestAfter,
            tileId: addr.tile, parity: kEpoch % 2)
        XCTAssertEqual(stripEpoch, kEpoch, "regenerated strip epoch")
        guard let entryBytes = stripValues[addr.local] else {
            return XCTFail("register \(pick.register) missing from the regenerated strip")
        }
        XCTAssertNotEqual(
            entryBytes.pre, entryBytes.post,
            "the oscillator must move between k−1 and k, or the two bytes are the same "
            + "and this gate proves nothing")
        XCTAssertEqual(
            entryBytes.pre, refAtKMinus1[pick.register],
            "K=\(maxResident) regenerated truthPre == the register's value at k−1")
        XCTAssertEqual(
            entryBytes.post, refAtK[pick.register],
            "K=\(maxResident) regenerated truthPost == the register's value at k")

        // The completed world equals the reference at k, bit for bit —
        // and every reader of that register, named one by one.
        let got = try await writer.truthArray()
        let differing = TiledReference.differing(got, refAtK)
        XCTAssertEqual(
            differing.count, 0,
            "K=\(maxResident) recovered+completed world vs reference at k=\(kEpoch): "
            + "\(differing.count) of \(refAtK.count) bytes differ")
        for reader in pick.readersBelow {
            XCTAssertEqual(
                got[reader], refAtK[reader],
                "K=\(maxResident) reader \(reader) of register \(pick.register) "
                + "(tile \(localOf[reader].tile), below tile \(pick.sourceTile))")
        }

        print("A8-CASE-II-RESULT K=\(maxResident) tiles=\(tiles) crashed_tile=\(pick.sourceTile) "
            + "completed=\(openReport.completed) register=\(pick.register) "
            + "truth_pre=\(entryBytes.pre) truth_post=\(entryBytes.post) "
            + "readers_below=\(pick.readersBelow.count) bytes_differing_from_reference=\(differing.count)")
    }
}
