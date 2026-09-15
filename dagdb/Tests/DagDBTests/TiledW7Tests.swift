import XCTest
@testable import DagDB

/// W7 — discrimination (`docs/contracts/TICKING_GATES_FROZEN.md`,
/// AMENDMENT 6, letters 3–6). Every assertion here carries a number
/// derived from `TiledReference` BEFORE the engine runs; none of them is
/// "greater than zero".
///
/// W7a  perturbation, one strip entry at a time, change set == `Δ_e`
/// W7b  deletion (ghosts held at the previous tick) == `stale`, and the
///      ordinary run == `fresh`, with `|D|` against a derived bound
/// W7c  staticity: the per-tick change count equals the reference's
/// W7d  registers hold state: a varying register per tile
final class TiledW7Tests: XCTestCase {

    // MARK: - Scratch

    private func scratchDir(_ label: String) -> String {
        let dir = NSTemporaryDirectory() + "dagdb-w7-\(label)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeScratch(_ dir: String) { try? FileManager.default.removeItem(atPath: dir) }

    private func copyTree(_ src: String, to dst: String) throws {
        try? FileManager.default.removeItem(atPath: dst)
        try FileManager.default.copyItem(atPath: src, toPath: dst)
    }

    /// Deterministic sampler (xorshift, seeded) — never the system RNG.
    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    // MARK: - Object under test

    private struct Subject {
        let object: TiledFixture.Object
        let reference: TiledReference
        let tileOf: [Int]
        let boundaries: [UInt64]
        let tiles: Int
        let root: String
        let name: String
        /// `localOf[engineIndex] = (tile, local)`, from the manifest's own
        /// `engineIndexOf` — the mapping a strip entry is addressed by.
        let localOf: [(tile: UInt32, local: UInt64)]
    }

    private func makeSubject(side: Int, tiles: Int, label: String) throws -> Subject {
        let object = try TiledFixture.generate(side: side)
        let reference = TiledReference(engine: object.engine)
        let boundaries = TiledFixture.boundaries(side: side, tiles: tiles)
        let root = scratchDir(label)
        _ = try TiledGraphFiles.write(object: object, dataRoot: root, name: "g", boundaries: boundaries)
        let manifest = try TiledGraphFiles.readManifest(dataRoot: root, name: "g")
        var localOf = [(tile: UInt32, local: UInt64)](
            repeating: (tile: 0, local: 0), count: object.nodeCount)
        for entry in manifest.tiles {
            for (li, engineIndex) in entry.engineIndexOf.enumerated() {
                localOf[Int(engineIndex)] = (tile: entry.id, local: UInt64(li))
            }
        }
        return Subject(
            object: object, reference: reference,
            tileOf: reference.tileAssignment(boundaries: boundaries),
            boundaries: boundaries, tiles: tiles, root: root, name: "g", localOf: localOf
        )
    }

    // MARK: - Raw strip surgery (the test's own parser/writer)

    /// Overwrites one entry's truth bytes inside a committed `DAHA` strip,
    /// leaving the epoch and every other field alone. v2 layout
    /// (AMENDMENT 8): magic(4) version(4)=2 kind(4) count(4) source(8)
    /// target(8) epoch(8), then count × (local u64 + truth_pre u8 +
    /// truth_post u8 + type u8 + 5 pad). `pre` and `post` move
    /// independently, so a test can force exactly the byte one reader
    /// takes.
    @discardableResult
    private func forceStripEntry(
        path: String, local: UInt64, pre: UInt8? = nil, post: UInt8? = nil
    ) throws -> Bool {
        var d = try Data(contentsOf: URL(fileURLWithPath: path))
        guard d.count >= 40 else { return false }
        XCTAssertEqual(
            UInt32(d[4]) | UInt32(d[5]) << 8 | UInt32(d[6]) << 16 | UInt32(d[7]) << 24,
            TiledGraphFiles.lowerStripFormatVersion, "strip \(path) format version")
        let count = Int(UInt32(d[12]) | UInt32(d[13]) << 8 | UInt32(d[14]) << 16 | UInt32(d[15]) << 24)
        for i in 0..<count {
            let off = 40 + i * 16
            var id: UInt64 = 0
            for b in 0..<8 { id |= UInt64(d[off + b]) << (8 * b) }
            if id == local {
                if let pre { d[off + 8] = pre }
                if let post { d[off + 9] = post }
                try d.write(to: URL(fileURLWithPath: path), options: [.atomic])
                return true
            }
        }
        return false
    }

    private func stripPath(subject: Subject, root: String, tile: UInt32, parity: UInt64) throws -> String {
        let manifest = try TiledGraphFiles.readManifest(dataRoot: root, name: subject.name)
        guard let entry = manifest.tiles.first(where: { $0.id == tile }) else {
            throw NSError(domain: "w7", code: 1)
        }
        let dir = TiledGraphFiles.tileDirectory(dataRoot: root, name: subject.name, entry: entry)
        return "\(dir)/halo_lower.\(parity).bin"
    }


    /// Reads one entry's BOTH truth bytes out of a committed `DAHA` v2
    /// strip — the parser an independent verifier would write from the
    /// format paragraph.
    private func readStripEntry(
        path: String, local: UInt64
    ) throws -> (epoch: UInt64, pre: UInt8, post: UInt8)? {
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        guard d.count >= 40 else { return nil }
        XCTAssertEqual(
            UInt32(d[4]) | UInt32(d[5]) << 8 | UInt32(d[6]) << 16 | UInt32(d[7]) << 24,
            TiledGraphFiles.lowerStripFormatVersion, "strip \(path) format version")
        var epoch: UInt64 = 0
        for b in 0..<8 { epoch |= UInt64(d[32 + b]) << (8 * b) }
        let count = Int(UInt32(d[12]) | UInt32(d[13]) << 8 | UInt32(d[14]) << 16 | UInt32(d[15]) << 24)
        for i in 0..<count {
            let off = 40 + i * 16
            var id: UInt64 = 0
            for b in 0..<8 { id |= UInt64(d[off + b]) << (8 * b) }
            if id == local { return (epoch, d[off + 8], d[off + 9]) }
        }
        return nil
    }

    // MARK: - AMENDMENT 7, finding A: registers read across a tile boundary

    /// Every `(reader, register source)` cross-tile edge in the object.
    private func crossTileRegisterReaders(_ subject: Subject) -> [(reader: Int, source: Int)] {
        subject.reference.crossings(tileOf: subject.tileOf)
            .filter { subject.reference.isRegister[$0.source] }
    }

    /// Gate (a): the objects KEEP their cross-tile readers of registers —
    /// the earlier build deleted them, which made W1 pass on an object that
    /// could not exhibit the defect. Counted and printed per side × tiling;
    /// a side with none is said so, not faked.
    func testFindingACrossTileRegisterReadersExist() throws {
        for side in TiledFixture.sides {
            var perSide = 0
            for tiles in [2, 4, 8] {
                let subject = try makeSubject(side: side, tiles: tiles, label: "fa-count-\(side)-\(tiles)")
                defer { removeScratch(subject.root) }
                let edges = crossTileRegisterReaders(subject)
                let sources = Set(edges.map { $0.source }).count
                perSide += edges.count
                var readerCounts: [Int] = []
                var readerRankGaps: [UInt64] = []
                for r in subject.reference.backEdgeDst.sorted() {
                    let rs = (0..<subject.reference.nodeCount).filter { u in
                        (0..<6).contains { subject.reference.slots[u * 6 + $0] == Int32(r) }
                    }
                    readerCounts.append(rs.count)
                    for u in rs { readerRankGaps.append(subject.reference.rank[r] - subject.reference.rank[u]) }
                }
                print("FINDING-A side=\(side) tiles=\(tiles) "
                    + "cross_tile_register_reader_edges=\(edges.count) distinct_registers_read=\(sources) "
                    + "registers_total=\(subject.reference.backEdgeDst.count) "
                    + "readers_per_register=\(readerCounts) rank_gaps=\(Set(readerRankGaps).sorted())")
            }
            XCTAssertGreaterThanOrEqual(
                perSide, 1,
                "side \(side) has no cross-tile reader of any register in any frozen tiling — "
                + "the object cannot exhibit the latch-timing defect finding A is about")
        }
    }

    /// Gate (b): the defect is reproducible on demand. After a rank world
    /// tick the committed strip must carry each register's PRE-latch byte;
    /// forcing that entry to the POST-latch byte instead must make the next
    /// world tick differ from the reference, on the register's own readers.
    private func runFindingAReproduction(side: Int, tiles: Int, label: String) async throws {
        let subject = try makeSubject(side: side, tiles: tiles, label: label)
        defer { removeScratch(subject.root) }
        let edges = crossTileRegisterReaders(subject)
        try XCTSkipIf(edges.isEmpty, "side \(side) tiles=\(tiles) has no cross-tile register reader")

        let warm = 1
        var refVector = subject.object.engine.readTruthStates()
        do {
            let router = try await TiledGraphRouter(
                dataRoot: subject.root, graphName: subject.name, maxResidentTiles: 1)
            _ = try await router.worldTick(mode: .rank, count: warm)
            for _ in 0..<warm { refVector = subject.reference.tickRank(refVector) }
            let got = try await router.truthArray()
            XCTAssertEqual(TiledReference.differing(got, refVector).count, 0, "finding-A warm-up")
        }
        let pristine = subject.root + "-pristine"
        try copyTree(subject.root, to: pristine)
        defer { removeScratch(pristine) }

        let fresh = subject.reference.tickRankWorld(
            refVector, tileOf: subject.tileOf, policy: .fresh)

        // One register that some lower tile reads.
        let source = edges.map { $0.source }.min()!
        let addr = subject.localOf[source]
        let preLatch = refVector[source]        // what the strip must carry
        let postLatch = fresh[source]           // what the latch leaves behind
        XCTAssertNotEqual(
            preLatch, postLatch,
            "the oscillator must actually move, or the two bytes are the same and nothing is gated")

        // 1. The committed strip carries the PRE-latch byte.
        let work = subject.root + "-strip"
        try copyTree(pristine, to: work)
        defer { removeScratch(work) }
        do {
            let router = try await TiledGraphRouter(
                dataRoot: work, graphName: subject.name, maxResidentTiles: 1)
            _ = try await router.worldTick(mode: .rank, count: 1)
            let epoch = UInt64(warm + 1)
            let path = try stripPath(subject: subject, root: work, tile: addr.tile, parity: epoch % 2)
            guard let got = try readStripEntry(path: path, local: addr.local) else {
                return XCTFail("register \(source) missing from tile \(addr.tile)'s epoch-\(epoch) strip")
            }
            XCTAssertEqual(got.epoch, epoch, "strip epoch")
            // AMENDMENT 8: the entry carries BOTH bytes, and each is the
            // one its own reader wants — `truthPre` for the rank-mode
            // reader at this epoch, `truthPost` for the sync-mode reader
            // of this parity file one world tick later.
            XCTAssertEqual(
                got.pre, preLatch,
                "the strip's truthPre must be register \(source)'s PRE-latch byte "
                + "(pre=\(preLatch) post=\(postLatch))")
            XCTAssertEqual(
                got.post, postLatch,
                "the strip's truthPost must be register \(source)'s POST-latch byte "
                + "(pre=\(preLatch) post=\(postLatch))")
            let after = try await router.truthArray()
            XCTAssertEqual(
                TiledReference.differing(after, fresh).count, 0,
                "the unperturbed round must still equal the reference")
        }

        // 2. AMENDMENT 8, gate (iii): the reproduction re-stated on the
        //    two-byte format — forcing `truthPre` to the POST-latch value
        //    (the byte the pre-two-byte build would have handed a rank-mode
        //    reader) must move this register's readers. The forcing goes
        //    through the router's ghost hook rather than a file edit
        //    because the source tile re-flushes its epoch-k strip earlier
        //    in the SAME round — a pre-round edit of `truthPre` is provably
        //    overwritten before any reader opens the file. The hook
        //    delivers exactly the byte `truthPre` would have carried
        //    (asserted just above against the committed file).
        let broken = subject.root + "-broken"
        try copyTree(pristine, to: broken)
        defer { removeScratch(broken) }
        let router = try await TiledGraphRouter(
            dataRoot: broken, graphName: subject.name, maxResidentTiles: 1)
        let raw = try GlobalNodeID(tileId: addr.tile, localNodeId: addr.local).raw
        await router.setGhostForced([raw: postLatch])
        _ = try await router.worldTick(mode: .rank, count: 1)
        let got = try await router.truthArray()
        let differing = TiledReference.differing(got, fresh)
        let readers = subject.reference.readers(ofSource: source, tileOf: subject.tileOf)
        let maxReaderRank = readers.map { subject.reference.rank[$0] }.max() ?? 0
        let topReaders = readers.filter { subject.reference.rank[$0] == maxReaderRank }
        print("FINDING-A-REPRO side=\(side) tiles=\(tiles) register=\(source) "
            + "pre_latch=\(preLatch) post_latch=\(postLatch) cross_tile_readers=\(readers.count) "
            + "top_rank_readers=\(topReaders.count) "
            + "nodes_differing_from_reference=\(differing.count)")
        XCTAssertGreaterThan(
            differing.count, 0,
            "forcing the post-latch byte must change the world tick — otherwise the fix is untested")
        XCTAssertTrue(
            topReaders.isSubset(of: differing),
            "every reader at the top reader rank must differ — they cannot be cancelled from above")
    }

    func testFindingAReproduction_side16() async throws {
        try await runFindingAReproduction(side: 16, tiles: 4, label: "fa-16")
    }
    func testFindingAReproduction_side44() async throws {
        try await runFindingAReproduction(side: 44, tiles: 4, label: "fa-44")
    }
    func testFindingAReproduction_side128() async throws {
        try await runFindingAReproduction(side: 128, tiles: 8, label: "fa-128")
    }

    // MARK: - W7a · perturbation, one strip entry at a time

    private func runW7a(
        side: Int, tiles: Int, mode: TickMode, sampleSize: Int?, label: String
    ) async throws {
        let subject = try makeSubject(side: side, tiles: tiles, label: label)
        defer { removeScratch(subject.root) }

        // One warm-up world tick, so the perturbation happens over real
        // committed strips at a real epoch (not the tiling-time ones).
        let warm = 1
        var refVector = subject.object.engine.readTruthStates()
        do {
            let router = try await TiledGraphRouter(
                dataRoot: subject.root, graphName: subject.name, maxResidentTiles: 1)
            _ = try await router.worldTick(mode: mode, count: warm)
            for _ in 0..<warm {
                refVector = (mode == .rank)
                    ? subject.reference.tickRank(refVector) : subject.reference.tickSync(refVector)
            }
            let got = try await router.truthArray()
            XCTAssertEqual(
                TiledReference.differing(got, refVector).count, 0,
                "W7a warm-up: tiled vs reference (side=\(side) tiles=\(tiles) mode=\(mode))")
        }
        let pristine = subject.root + "-pristine"
        try copyTree(subject.root, to: pristine)
        defer { removeScratch(pristine) }

        // The unperturbed next tick, from the reference and from the engine.
        let fresh = (mode == .rank)
            ? subject.reference.tickRankWorld(refVector, tileOf: subject.tileOf, policy: .fresh)
            : subject.reference.tickSyncWorld(refVector, tileOf: subject.tileOf, policy: .fresh)
        do {
            let work = subject.root + "-base"
            try copyTree(pristine, to: work)
            defer { removeScratch(work) }
            let router = try await TiledGraphRouter(
                dataRoot: work, graphName: subject.name, maxResidentTiles: 1)
            _ = try await router.worldTick(mode: mode, count: 1)
            let got = try await router.truthArray()
            XCTAssertEqual(
                TiledReference.differing(got, fresh).count, 0,
                "W7a baseline: the unperturbed world tick must equal the reference's `fresh`")
        }

        var entries = subject.reference.stripEntrySources(tileOf: subject.tileOf)
        let totalEntries = entries.count
        if let cap = sampleSize, entries.count > cap {
            var rng = SeededRNG(seed: 7)
            entries = Array(entries.shuffled(using: &rng).prefix(cap)).sorted()
        }

        var deltaSizes: [Int] = []
        var cancelledEntries = 0      // entries where some reader did NOT flip
        var crossedASecondBoundary: [Int: Int] = [:]   // reader tile -> count
        var readerTileHistogram: [Int: Int] = [:]

        for source in entries {
            let readers = subject.reference.readers(ofSource: source, tileOf: subject.tileOf)
            XCTAssertFalse(readers.isEmpty, "strip entry \(source) feeds no reader")
            // What a cross-tile reader actually sees for this source. Rank
            // mode: the source's post-tick value — EXCEPT for a register,
            // whose strip byte is its PRE-latch value (AMENDMENT 7,
            // finding A), i.e. its value from the previous world tick.
            // Sync mode: the previous vector throughout.
            let isRegisterSource = subject.reference.isRegister[source]
            let trueValue: UInt8 = (mode == .rank && !isRegisterSource)
                ? fresh[source] : refVector[source]
            let flipped: UInt8 = (trueValue == 1) ? 0 : 1

            let predicted = (mode == .rank)
                ? subject.reference.tickRankWorld(
                    refVector, tileOf: subject.tileOf, policy: .forced([source: flipped]))
                : subject.reference.tickSyncWorld(
                    refVector, tileOf: subject.tileOf, policy: .forced([source: flipped]))
            let delta = TiledReference.differing(predicted, fresh)

            // Derived before the run.
            //
            // AMENDMENT 6 letter 3 asserts `Δ_e ⊇ readers(e)` "under
            // parity a single input flip cannot cancel". That holds in
            // SYNC mode, where one world tick is one hop and a reader sees
            // exactly one changed input. It is FALSE in RANK mode, which
            // propagates through every rank inside one tick: a reader `u`
            // can have a SECOND input that is itself downstream of the
            // same perturbation, and two flipped inputs cancel under
            // parity. Same reconvergence trap the amendment named for
            // letter 2 and then reproduced in letter 3.
            //
            // What IS a theorem, and is asserted here: every reader at the
            // MAXIMUM reader rank flips. Anything the perturbation can
            // reach lies at a rank <= the maximum reader rank, and a
            // node's inputs are strictly above its own rank, so no
            // top-rank reader can have a second changed input. Hence
            // `|Δ_e| >= 1` always.
            let maxReaderRank = readers.map { subject.reference.rank[$0] }.max() ?? 0
            let topReaders = readers.filter { subject.reference.rank[$0] == maxReaderRank }
            XCTAssertTrue(
                topReaders.isSubset(of: delta),
                "Δ_e must contain every reader at the top reader rank "
                + "(source=\(source) mode=\(mode) rank=\(maxReaderRank))")
            XCTAssertGreaterThanOrEqual(delta.count, 1, "a perturbation that changes nothing")
            if mode == .sync {
                XCTAssertTrue(
                    readers.isSubset(of: delta),
                    "sync mode is one hop: Δ_e must contain every reader (source=\(source))")
            }
            if !readers.isSubset(of: delta) { cancelledEntries += 1 }
            deltaSizes.append(delta.count)

            let minReaderTile = readers.map { subject.tileOf[$0] }.min() ?? 0
            for r in readers { readerTileHistogram[subject.tileOf[r], default: 0] += 1 }
            if delta.contains(where: { subject.tileOf[$0] < minReaderTile }) {
                crossedASecondBoundary[minReaderTile, default: 0] += 1
            }

            // The engine, with that one entry forced to the flipped bit.
            let work = subject.root + "-p"
            try copyTree(pristine, to: work)
            let router = try await TiledGraphRouter(
                dataRoot: work, graphName: subject.name, maxResidentTiles: 1)
            let addr = subject.localOf[source]
            if mode == .sync {
                // Sync reads the committed k − 1 parity strip, which this
                // round does not rewrite: the perturbation is a real edit
                // of a real file.
                let parity = UInt64(warm) % 2
                let path = try stripPath(
                    subject: subject, root: work, tile: addr.tile, parity: parity)
                // Both bytes, so the edited file stays self-consistent;
                // a sync-mode ghost takes `truthPost` (AMENDMENT 8).
                let hit = try forceStripEntry(
                    path: path, local: addr.local, pre: flipped, post: flipped)
                XCTAssertTrue(hit, "entry \(source) not present in tile \(addr.tile)'s parity-\(parity) strip")
            } else {
                // Rank mode re-flushes the epoch-k strip from the source
                // tile earlier in the same round, so a pre-tick file edit
                // is provably overwritten before any reader sees it; the
                // same perturbation is delivered at the reader's input.
                let raw = try GlobalNodeID(tileId: addr.tile, localNodeId: addr.local).raw
                await router.setGhostForced([raw: flipped])
            }
            _ = try await router.worldTick(mode: mode, count: 1)
            let got = try await router.truthArray()
            let observed = TiledReference.differing(got, fresh)
            XCTAssertEqual(
                observed.count, delta.count,
                "W7a side=\(side) tiles=\(tiles) mode=\(mode) entry=\(source): "
                + "|observed Δ|=\(observed.count) vs predicted |Δ_e|=\(delta.count)")
            XCTAssertTrue(
                observed == delta,
                "W7a side=\(side) tiles=\(tiles) mode=\(mode) entry=\(source): "
                + "change set differs from Δ_e in \(observed.symmetricDifference(delta).count) nodes")
            removeScratch(work)
        }

        let sorted = deltaSizes.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        print("W7a side=\(side) tiles=\(tiles) mode=\(mode) K=1 "
            + "strip_entries_total=\(totalEntries) tested=\(entries.count) "
            + "delta_min=\(sorted.first ?? 0) delta_median=\(median) delta_max=\(sorted.last ?? 0) "
            + "entries_with_a_cancelled_reader=\(cancelledEntries) "
            + "crossed_a_second_boundary=\(crossedASecondBoundary.sorted { $0.key < $1.key }.map { "tile\($0.key):\($0.value)" }) "
            + "reader_tiles=\(readerTileHistogram.sorted { $0.key < $1.key }.map { "tile\($0.key):\($0.value)" })")

        if mode == .rank {
            // The clause ghosts exist for: the change crossed a SECOND
            // boundary inside one world tick. Asserted for every reader
            // tile that HAS a tile below it (tile 0 has none, so no entry
            // read there can satisfy it — a fact of the tiling, not a
            // property of the engine).
            for readerTile in readerTileHistogram.keys.sorted() where readerTile >= 1 {
                XCTAssertGreaterThanOrEqual(
                    crossedASecondBoundary[readerTile] ?? 0, 1,
                    "no entry read by tile \(readerTile) propagated below it in one world tick")
            }
        }
    }

    func testW7aPerturbation_side44_rank() async throws {
        try await runW7a(side: 44, tiles: 4, mode: .rank, sampleSize: nil, label: "w7a-44-rank")
    }

    func testW7aPerturbation_side44_sync() async throws {
        try await runW7a(side: 44, tiles: 4, mode: .sync, sampleSize: nil, label: "w7a-44-sync")
    }

    func testW7aPerturbation_side128_rank() async throws {
        try await runW7a(side: 128, tiles: 8, mode: .rank, sampleSize: 64, label: "w7a-128-rank")
    }

    func testW7aPerturbation_side128_sync() async throws {
        try await runW7a(side: 128, tiles: 8, mode: .sync, sampleSize: 64, label: "w7a-128-sync")
    }

    // MARK: - W7b · deletion: the engine with ghosts held at k − 1 == `stale`

    /// Run at TWO points of the trajectory: `warm = 0` (the first world
    /// tick, where the whole object is still moving) and `warm = 2` (the
    /// settled orbit). Both are gated, because the settled orbit is where
    /// a thin object stops carrying information across its boundaries —
    /// at side 16 the entire steady state is a 3-byte oscillation inside
    /// the top tile, so NO crossing source moves and `|D| = 0` there.
    /// That is a property of the object (side 16's rank range is 0…8 and
    /// the union of the 2/4/8 tilings' boundaries is {1…7}, leaving rank 8
    /// as the only level an oscillator may sit at), and it is printed
    /// rather than hidden.
    private func runW7b(side: Int, tiles: Int, warm: Int, label: String) async throws {
        let subject = try makeSubject(side: side, tiles: tiles, label: label)
        defer { removeScratch(subject.root) }

        var refVector = subject.object.engine.readTruthStates()
        if warm > 0 {
            let router = try await TiledGraphRouter(
                dataRoot: subject.root, graphName: subject.name, maxResidentTiles: 1)
            _ = try await router.worldTick(mode: .rank, count: warm)
            for _ in 0..<warm { refVector = subject.reference.tickRank(refVector) }
            let got = try await router.truthArray()
            XCTAssertEqual(TiledReference.differing(got, refVector).count, 0, "W7b warm-up")
        }
        let pristine = subject.root + "-pristine"
        try copyTree(subject.root, to: pristine)
        defer { removeScratch(pristine) }

        let fresh = subject.reference.tickRankWorld(
            refVector, tileOf: subject.tileOf, policy: .fresh)
        let stale = subject.reference.tickRankWorld(
            refVector, tileOf: subject.tileOf, policy: .stale)
        let d = TiledReference.differing(stale, fresh)

        // Derived before the run: the number of CROSSINGS whose source's
        // truth changed this tick.
        let crossings = subject.reference.crossings(tileOf: subject.tileOf)
        let movedCrossings = crossings.filter {
            (fresh[$0.source] == 1) != (refVector[$0.source] == 1)
        }.count
        // The derived number `|D|` is asserted against, node-locally (see
        // `oddInputChangeSet`). AMENDMENT 6 letter 4's own inequality
        // (`|D| >= crossings whose source changed`) counts EDGES against a
        // set of NODES and is false on a correct engine — side 16, tick 1,
        // below — so it is printed, not asserted.
        let derived = subject.reference.oddInputChangeSet(
            prev: refVector, stale: stale, fresh: fresh, tileOf: subject.tileOf, mode: .rank)
        print("W7b side=\(side) tiles=\(tiles) warm=\(warm) tick=\(warm + 1) "
            + "crossings=\(crossings.count) crossings_whose_source_moved=\(movedCrossings) "
            + "|D|=\(d.count) derived_odd_input_set=\(derived.count) "
            + "letter4_bound_holds=\(d.count >= movedCrossings)")
        XCTAssertEqual(
            d.count, derived.count,
            "side=\(side) warm=\(warm): |D| must equal the node-local odd-input derivation")
        XCTAssertTrue(
            d == derived,
            "side=\(side) warm=\(warm): D differs from the derived set in "
            + "\(d.symmetricDifference(derived).count) nodes")
        if warm == 0 {
            XCTAssertGreaterThan(
                movedCrossings, 0,
                "side=\(side): the first world tick must move at least one crossing source")
            XCTAssertGreaterThan(
                d.count, 0,
                "side=\(side): deleting the ghost population must change the result")
        }

        // Engine, ghosts held at the previous world tick == `stale`.
        do {
            let work = subject.root + "-stale"
            try copyTree(pristine, to: work)
            defer { removeScratch(work) }
            let router = try await TiledGraphRouter(
                dataRoot: work, graphName: subject.name, maxResidentTiles: 1)
            await router.setGhostPopulationDisabled(true)
            _ = try await router.worldTick(mode: .rank, count: 1)
            let got = try await router.truthArray()
            XCTAssertEqual(
                TiledReference.differing(got, stale).count, 0,
                "W7b side=\(side): ghost population disabled must equal the reference's `stale`")
        }
        // Engine, ordinary run == `fresh`.
        do {
            let work = subject.root + "-fresh"
            try copyTree(pristine, to: work)
            defer { removeScratch(work) }
            let router = try await TiledGraphRouter(
                dataRoot: work, graphName: subject.name, maxResidentTiles: 1)
            _ = try await router.worldTick(mode: .rank, count: 1)
            let got = try await router.truthArray()
            XCTAssertEqual(
                TiledReference.differing(got, fresh).count, 0,
                "W7b side=\(side): the ordinary run must equal the reference's `fresh`")
        }

        // Sync mode: every input already comes from the previous world
        // tick, so `stale` and `fresh` coincide there — stated, not assumed.
        let syncFresh = subject.reference.tickSyncWorld(
            refVector, tileOf: subject.tileOf, policy: .fresh)
        let syncStale = subject.reference.tickSyncWorld(
            refVector, tileOf: subject.tileOf, policy: .stale)
        XCTAssertEqual(
            TiledReference.differing(syncFresh, syncStale).count, 0,
            "in sync mode `stale` and `fresh` are the same vector by construction")
    }

    func testW7bDeletion_side16() async throws {
        for warm in [0, 2] { try await runW7b(side: 16, tiles: 4, warm: warm, label: "w7b-16-\(warm)") }
    }
    func testW7bDeletion_side44() async throws {
        for warm in [0, 2] { try await runW7b(side: 44, tiles: 4, warm: warm, label: "w7b-44-\(warm)") }
    }
    func testW7bDeletion_side128() async throws {
        for warm in [0, 2] { try await runW7b(side: 128, tiles: 8, warm: warm, label: "w7b-128-\(warm)") }
    }

    // MARK: - W7c · staticity, per tick, gated and printed

    private func runW7c(side: Int, tiles: Int, mode: TickMode, label: String) async throws {
        let subject = try makeSubject(side: side, tiles: tiles, label: label)
        defer { removeScratch(subject.root) }
        let router = try await TiledGraphRouter(
            dataRoot: subject.root, graphName: subject.name, maxResidentTiles: 1)

        var refVector = subject.object.engine.readTruthStates()
        var engineVector = try await router.truthArray()
        XCTAssertEqual(TiledReference.differing(engineVector, refVector).count, 0, "W7c start state")

        var refChanges: [Int] = []
        var engineChanges: [Int] = []
        for k in 1...12 {
            let refBefore = refVector
            refVector = (mode == .rank)
                ? subject.reference.tickRank(refVector) : subject.reference.tickSync(refVector)
            _ = try await router.worldTick(mode: mode, count: 1)
            let engineAfter = try await router.truthArray()
            let refCount = TiledReference.differing(refBefore, refVector).count
            let engineCount = TiledReference.differing(engineVector, engineAfter).count
            refChanges.append(refCount)
            engineChanges.append(engineCount)
            XCTAssertEqual(
                engineCount, refCount,
                "W7c side=\(side) mode=\(mode) tick \(k): engine changed \(engineCount) bytes, "
                + "reference \(refCount)")
            XCTAssertGreaterThan(
                refCount, 0,
                "W7c side=\(side) mode=\(mode) tick \(k): a static tick makes every later equality free")
            engineVector = engineAfter
        }
        print("W7c side=\(side) tiles=\(tiles) mode=\(mode) nodes=\(subject.object.nodeCount) "
            + "changed_per_tick=\(engineChanges) reference=\(refChanges)")
    }

    func testW7cStaticity_side16_rank() async throws { try await runW7c(side: 16, tiles: 4, mode: .rank, label: "w7c-16r") }
    func testW7cStaticity_side16_sync() async throws { try await runW7c(side: 16, tiles: 4, mode: .sync, label: "w7c-16s") }
    func testW7cStaticity_side44_rank() async throws { try await runW7c(side: 44, tiles: 4, mode: .rank, label: "w7c-44r") }
    func testW7cStaticity_side44_sync() async throws { try await runW7c(side: 44, tiles: 4, mode: .sync, label: "w7c-44s") }
    func testW7cStaticity_side128_rank() async throws { try await runW7c(side: 128, tiles: 8, mode: .rank, label: "w7c-128r") }
    func testW7cStaticity_side128_sync() async throws { try await runW7c(side: 128, tiles: 8, mode: .sync, label: "w7c-128s") }

    // MARK: - W7d · registers hold state

    /// For every tile, a register whose value differs between two
    /// consecutive ticks of a 12-tick reference run.
    ///
    /// One structural exception, derived and asserted rather than waved
    /// past. An oscillator needs `rank(R) = r`, `rank(S) = r − 1` (the
    /// snapshot format validates `src rank > dst rank` on every
    /// combinational edge, so `S` cannot read `R` at the same rank) with
    /// `R` and `S` in the SAME tile — and ONE object is tiled 2, 4 and 8
    /// ways, while a back edge that crosses a boundary under ANY of those
    /// tilings is refused at tiling time. So a pair may sit at rank `r`
    /// only if `r` is a boundary of none of them, and a tile can hold a
    /// register only if its span contains such an `r`. At side 16 the
    /// union of the three boundary sets is `{1…7}` out of a rank range of
    /// `0…8`, so the ONLY usable level is 8 and only the top tile of each
    /// tiling carries an oscillator. The test asserts that every
    /// register-less tile is exactly one of those — its span contains no
    /// usable level — rather than letting the hole pass unnamed.
    private func runW7d(side: Int, tiles: Int, mode: TickMode, label: String) throws {
        let subject = try makeSubject(side: side, tiles: tiles, label: label)
        defer { removeScratch(subject.root) }
        let reference = subject.reference

        var vectors: [[UInt8]] = [subject.object.engine.readTruthStates()]
        for _ in 1...12 {
            vectors.append(mode == .rank
                ? reference.tickRank(vectors.last!) : reference.tickSync(vectors.last!))
        }

        var registersByTile: [Int: [Int]] = [:]
        for r in reference.backEdgeDst { registersByTile[subject.tileOf[r], default: []].append(r) }

        var varyingPerTile: [Int: Int] = [:]
        for t in 0..<subject.tiles {
            let regs = registersByTile[t] ?? []
            let varying = regs.filter { r in
                (1..<vectors.count).contains { vectors[$0][r] != vectors[$0 - 1][r] }
            }
            varyingPerTile[t] = varying.count
            if regs.isEmpty {
                let boundaryUnion = Set([2, 4, 8].flatMap { TiledFixture.boundaries(side: side, tiles: $0) })
                let levels = Set((0..<reference.nodeCount)
                    .filter { subject.tileOf[$0] == t }
                    .map { reference.rank[$0] })
                // Usable = a level an oscillator may sit at: `r >= 2`
                // (rank 0 is the single centre node, reserved as the
                // frozen query seed — see `TiledFixture.populate`) and not
                // a boundary of any frozen tiling.
                let usable = levels.filter { $0 >= 2 && !boundaryUnion.contains($0) }
                XCTAssertTrue(
                    usable.isEmpty,
                    "tile \(t) (side=\(side) tiles=\(tiles)) holds no register although its span "
                    + "offers usable rank levels \(usable.sorted()) — an oscillator would have fitted")
            } else {
                XCTAssertGreaterThanOrEqual(
                    varying.count, 1,
                    "tile \(t) (side=\(side) tiles=\(tiles) mode=\(mode)): every register is constant")
            }
        }
        print("W7d side=\(side) tiles=\(tiles) mode=\(mode) registers=\(reference.backEdgeDst.count) "
            + "varying_registers_per_tile=\(varyingPerTile.sorted { $0.key < $1.key }.map { "tile\($0.key):\($0.value)" })")
    }

    func testW7dRegisters_side16() throws {
        for tiles in [2, 4, 8] {
            try runW7d(side: 16, tiles: tiles, mode: .rank, label: "w7d-16-\(tiles)")
            try runW7d(side: 16, tiles: tiles, mode: .sync, label: "w7d-16s-\(tiles)")
        }
    }

    func testW7dRegisters_side44() throws {
        for tiles in [2, 4, 8] {
            try runW7d(side: 44, tiles: tiles, mode: .rank, label: "w7d-44-\(tiles)")
            try runW7d(side: 44, tiles: tiles, mode: .sync, label: "w7d-44s-\(tiles)")
        }
    }

    func testW7dRegisters_side128() throws {
        for tiles in [2, 4, 8] {
            try runW7d(side: 128, tiles: tiles, mode: .rank, label: "w7d-128-\(tiles)")
            try runW7d(side: 128, tiles: tiles, mode: .sync, label: "w7d-128s-\(tiles)")
        }
    }
}
