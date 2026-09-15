/// DagDBCommandHandler — the daemon's DSL command dispatch, extracted from
/// main.swift so it can be tested against a real engine without a socket or
/// mmap'd shared memory (Fable review T1). Prod constructs it with the mmap'd
/// shm base pointer; tests pass a plain allocated buffer as `shmBase` and read
/// results back from it directly.
///
/// The handler owns the mutable daemon state (tickCount, walAppender) and the
/// engine/index/session references. The socket server (main.swift) is now a
/// thin shim that builds one handler and routes each line through `handle`.

import Foundation
import DagDB

public final class DagDBCommandHandler {
    public let engine: DagDBEngine
    let grid: HexGrid
    let nodeCount: Int
    let width: Int
    let height: Int
    let maxRank: Int
    public var tickCount: UInt32
    public var walAppender: DagDBWAL.Appender?
    let sessionManager: DagDBReaderSessionManager
    let truthRankIndex: TruthRankIndex
    let shmBase: UnsafeMutableRawPointer
    let resultRowSize: Int
    let dataRoot: String?
    let dagdbEnv: String?
    /// Twin-spec DSL state (interface phase, 2026-09) — daemon-global, shared by every
    /// connection (primary path and reader sessions alike). See
    /// DagDBCommandHandler+Twin.swift for the verb dispatcher.
    public let twin: TwinState
    /// Resolved shm capacity in bytes — `shmBytes` if the caller supplied
    /// one (a test fixture sizing its buffer to a control object rather
    /// than to `nodeCount`), else the historical `8 + nodeCount *
    /// resultRowSize` formula. Backs `shmCapacityBytes` in +Twin.swift.
    let configuredShmCapacityBytes: Int
    /// Last FOLD RUN result (gate F4) — daemon-global like every twin
    /// registry, but NOT a twin registry entry: nothing is minted, nothing
    /// is persisted. Not part of snapshots — it is entirely recomputable
    /// from the fabric's neighbor/edge-weight/rank/nodeValue lanes by
    /// running FOLD RUN again.
    public var lastFold: LadderFold.Result?
    /// TILED router registry (gate T5, docs/contracts/TILING_GATES_FROZEN.md)
    /// — daemon-held like `lastFold`, but deliberately NOT a `TwinState`
    /// registry: a router is never persisted, never WAL-logged, and never
    /// part of a snapshot. The tile directory on disk written by `SAVE
    /// TILED` IS the durable state; `TILED OPEN` only rebuilds an
    /// in-memory view of it (reads `manifest.json`, loads nothing yet).
    /// See `DagDBCommandHandler+Tiled.swift`.
    var tiledRouters: [String: TiledRouterEntry] = [:]
    var tiledRouterCounter: UInt32 = 0

    public init(
        engine: DagDBEngine,
        grid: HexGrid,
        nodeCount: Int,
        width: Int,
        height: Int,
        maxRank: Int,
        tickCount: UInt32,
        walAppender: DagDBWAL.Appender?,
        sessionManager: DagDBReaderSessionManager,
        truthRankIndex: TruthRankIndex,
        shmBase: UnsafeMutableRawPointer,
        resultRowSize: Int = 24,
        dataRoot: String?,
        dagdbEnv: String?,
        twin: TwinState = TwinState(),
        shmBytes: Int? = nil
    ) {
        self.engine = engine
        self.grid = grid
        self.nodeCount = nodeCount
        self.width = width
        self.height = height
        self.maxRank = maxRank
        self.tickCount = tickCount
        self.walAppender = walAppender
        self.sessionManager = sessionManager
        self.truthRankIndex = truthRankIndex
        self.shmBase = shmBase
        self.resultRowSize = resultRowSize
        self.dataRoot = dataRoot
        self.dagdbEnv = dagdbEnv
        self.twin = twin
        self.configuredShmCapacityBytes = shmBytes ?? (8 + nodeCount * resultRowSize)
        self.lastFold = nil
    }

    func guardPath(_ p: String) -> String? {
        // Reject traversal segments before any canonicalization.
        for seg in p.split(separator: "/", omittingEmptySubsequences: false) {
            if seg == ".." { return "ERROR io: path: traversal segment '..' rejected" }
        }
        guard let root = dataRoot else { return nil }
        let abs = (p as NSString).standardizingPath
        let absResolved = (abs as NSString).resolvingSymlinksInPath
        let rootResolved = (root as NSString).resolvingSymlinksInPath
        if !absResolved.hasPrefix(rootResolved + "/") && absResolved != rootResolved {
            return "ERROR io: path: '\(p)' outside DAGDB_DATA_ROOT"
        }
        return nil
    }

    /// Backup replies for a failed call. The refusals the format contract
    /// names — a format-1 chain, a segment of the wrong length, a gap or a
    /// duplicate in the diff sequence, an occupied APPEND slot, a diff that
    /// fails its sidecar — come back as their own sentence, not a wrapped
    /// error string, because the operator's next move is in that sentence.
    /// Everything else keeps the old `verb: error` shape.
    func backupErrorReply(_ error: Error, verb: String) -> String {
        if let be = error as? DagDBBackup.BackupError, be.isNamedRefusal {
            return "ERROR \(be)"
        }
        return "ERROR io: \(verb): \(error)"
    }

    // MARK: - D1 · every wire integer bounded on BOTH sides

    /// Caps for the counts that drive loops on the single-threaded accept
    /// loop (gates D1 and D8, `docs/contracts/DAEMON_BOUNDS_GATES_FROZEN.md`).
    /// `TILED TICK` already carried `1...10000`; `TICK`, `TICK_SYNC` and
    /// `CLOCK ADVANCE` now carry the same ceiling, and the two remaining
    /// unbounded loops (`BANK NOISE`'s seed skip, `SIMILAR_DECISIONS`'s
    /// candidate pool) carry one of their own. A cap is a REFUSAL, not a
    /// clip: the daemon never silently does less than it was asked.
    public static let tickCap = 10_000
    public static let clockAdvanceCap = 10_000
    public static let bankNoiseSeedCap = 1_000_000
    public static let similarDecisionsCandidateCap = 4_096

    /// The one refusal wording for a wire integer that missed its half-open
    /// range. Names the value AND the true extent, so a client never has to
    /// guess which side it fell off (audit B findings 2-4: the old
    /// `node <v> out of range` named neither bound, and the domain it was
    /// checked against was `Int.min ..< nodeCount`).
    func rangeRefusal(_ name: String, _ v: Int, upTo hi: Int) -> String {
        "ERROR out_of_range: \(name) \(v) not in 0..<\(hi)"
    }

    /// Both sides, before any pointer touch. Returns nil when `v` is in
    /// `0..<hi`, else the refusal line to return to the wire.
    func checkRange(_ name: String, _ v: Int, upTo hi: Int) -> String? {
        (v >= 0 && v < hi) ? nil : rangeRefusal(name, v, upTo: hi)
    }

    /// Closed-range cap refusal, in `TILED TICK`'s existing vocabulary.
    func checkCap(_ name: String, _ v: Int, _ lo: Int, _ hi: Int) -> String? {
        (v >= lo && v <= hi) ? nil : "ERROR out_of_range: \(name) \(v) not in \(lo)...\(hi)"
    }

    // MARK: - D3 · wire arithmetic cannot trap

    /// Sums and products of wire integers, computed with overflow-reporting
    /// operations. Swift TRAPS on `Int` overflow, so a byte count built from
    /// unbounded wire values used to kill the daemon BEFORE the capacity
    /// guard that existed to refuse it could run (audit B finding 23).
    /// Returns the value, or nil when it does not fit `Int`.
    func checkedProduct(_ factors: Int...) -> Int? {
        var acc = 1
        for f in factors {
            let (v, over) = acc.multipliedReportingOverflow(by: f)
            if over { return nil }
            acc = v
        }
        return acc
    }

    func checkedSum(_ terms: Int...) -> Int? {
        var acc = 0
        for t in terms {
            let (v, over) = acc.addingReportingOverflow(t)
            if over { return nil }
            acc = v
        }
        return acc
    }

    /// The refusal an overflowed byte count prints. It names the operands
    /// rather than a nonsense product.
    func overflowRefusal(_ what: String, _ operands: String) -> String {
        "ERROR out_of_range: \(what) byte count overflows Int for \(operands);"
            + " shm holds \(shmCapacityBytes)"
    }

    /// `tickCount` stays `UInt32` — it is written into the snapshot header
    /// (`DagDBSnapshot.save(tickCount:)`) and into the WAL checkpoint epoch,
    /// so widening it is an on-disk format change, not a daemon change. The
    /// price of keeping the width is that the overflow must be refused BY
    /// NAME rather than trapping on the `+= 1` (audit B finding 5).
    func checkTickHeadroom(_ count: Int) -> String? {
        let projected = UInt64(tickCount) + UInt64(count)
        guard projected > UInt64(UInt32.max) else { return nil }
        return "ERROR out_of_range: tick total \(tickCount)+\(count) not in 0...\(UInt32.max)"
            + " — tickCount is a 32-bit field in the snapshot header; SAVE and restart to reset it"
    }

    /// Write a snapshot and then a WAL checkpoint, in that order. Used by
    /// the `SAVE` verb (after `guardPath`) and by the daemon's autosave on
    /// graceful shutdown. The checkpoint must follow every durable snapshot:
    /// startup recovery (`DagDBStartup.recover`) loads the snapshot and then
    /// replays only records past the last checkpoint, and twin records such
    /// as `RECORD SLICE`, `RINGS WRITE`, `CLOCK ADVANCE` are not idempotent —
    /// a snapshot without its checkpoint would replay them twice.
    public func durableSnapshot(path: String, compressed: Bool = false) -> String {
        // G73 forced barrier: flush any deferred WAL tail so the snapshot
        // is taken over a fully-durable log (a crash mid-snapshot then
        // recovers via WAL replay with no group-commit loss window).
        walAppender?.barrier()
        do {
            let r = try DagDBSnapshot.save(
                engine: engine,
                nodeCount: nodeCount,
                gridW: width,
                gridH: height,
                tickCount: tickCount,
                path: path,
                compressed: compressed,
                daemonEnv: DagDBSnapshot.SnapshotEnv.from(envString: dagdbEnv),
                twin: twin
            )
            // After a durable snapshot, mark the WAL with a checkpoint so
            // subsequent replays skip records already captured in the file.
            if let wal = walAppender {
                _ = try? wal.checkpoint(epoch: UInt64(tickCount))
            }
            let ratio = compressed
                ? String(format: " ratio=%.1f%%", Double(r.bytesWritten) * 100.0 / Double(32 + r.uncompressedBodyBytes))
                : ""
            return "OK SAVE bytes=\(r.bytesWritten) elapsed=\(String(format: "%.1f", r.elapsedMs))ms\(ratio) path=\(path)\(compressed ? " (compressed)" : "")"
        } catch {
            return "ERROR io: save: \(error)"
        }
    }

    // MARK: - Command dispatch

    /// R2 — the operation says how much it did
    /// (docs/contracts/RANK_BOUND_GATES_FROZEN.md, AMENDMENT 1).
    ///
    /// `nodes_computed` is the total node-evaluations the command
    /// dispatched: the per-tick node slots times the tick count. It is
    /// printed always. When the rank levels actually dispatched exceed the
    /// configured bound, the reply also carries `ranks=` and `bound=`, so
    /// a graph restored under a smaller bound announces itself on the wire
    /// at the first tick rather than scrolling past in a log. (STATUS
    /// carries the same news without ticking; VALIDATE names the nodes.)
    private func rankWorkSuffix(nodesComputed: Int, rankDispatched: Bool) -> String {
        engine.ensureRankTopology()
        var s = " nodes_computed=\(nodesComputed)"
        if engine.effectiveRankCount > maxRank {
            // Rank mode reports the levels it dispatched. Sync mode does not
            // dispatch by rank at all, so `ranks=` would imply a bounded
            // dispatch that did not happen; it reports the same news as a
            // fact about the GRAPH instead, in STATUS's vocabulary.
            s += rankDispatched
                ? " ranks=\(engine.effectiveRankCount) bound=\(maxRank)"
                : " rank_max=\(engine.highestRankPresent) bound=\(maxRank)"
        }
        return s
    }

    public func handle(_ input: String) -> String {
        let cmd = DSLParser.parse(input)

        switch cmd {
        case .status:
            // `ranks=` and `rank_max=` sit beside the configured bound so a
            // health check can compare two printed numbers and catch a stale
            // bound WITHOUT ticking (R4 + AMENDMENT 2). Every field STATUS
            // printed before is still printed, in the same relative order.
            engine.ensureRankTopology()
            return "OK STATUS nodes=\(nodeCount) ticks=\(tickCount) gpu=\(engine.device.name) grid=\(width)x\(height) maxRank=\(maxRank) ranks=\(engine.effectiveRankCount) rank_max=\(engine.highestRankPresent) twin_open=\(twin.totalOpen) tiled_open=\(tiledRouters.count)"

        case .tick(let count):
            if let e = checkCap("count", count, 0, Self.tickCap) { return e }
            if let e = checkTickHeadroom(count) { return e }
            let t0 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<count {
                engine.tick(tickNumber: tickCount)
                tickCount += 1
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            return "OK TICK \(count) elapsed=\(String(format: "%.2f", elapsed))ms total=\(tickCount)"
                + rankWorkSuffix(nodesComputed: engine.rankDispatchNodeCount() * count, rankDispatched: true)

        case .tickSync(let count):
            if let e = checkCap("count", count, 0, Self.tickCap) { return e }
            if let e = checkTickHeadroom(count) { return e }
            let t0 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<count {
                engine.tickSync(tickNumber: tickCount)
                tickCount += 1
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            return "OK TICK_SYNC \(count) elapsed=\(String(format: "%.2f", elapsed))ms total=\(tickCount)"
                + rankWorkSuffix(nodesComputed: nodeCount * count, rankDispatched: false)

        case .eval(let predicate, _, _):
            if let e = checkTickHeadroom(1) { return e }
            engine.tick(tickNumber: tickCount)
            tickCount += 1
            let roots = engine.readRoots()  // [(Int, UInt8)]
            let truth = engine.readTruthStates()
            let ranks = engine.readRanks()
            var rows: [(Int, UInt64, UInt8, UInt8)] = roots.map { ($0.0, ranks[$0.0], $0.1, UInt8(0)) }
            if let pred = predicate {
                rows = rows.filter { pred.evaluate(truth: $0.2, rank: $0.1, nodeType: $0.3) }
            }
            if let e = writeResults(rows) { return e }
            // D7 · the reply says what it omitted. EVAL ticks the whole
            // graph but reports only rank-0 roots (`engine.readRoots`), and
            // it dispatched by rank exactly as TICK did — so it carries
            // TICK's `nodes_computed`/`ranks=`/`bound=` disclosure too.
            return "OK EVAL rows=\(rows.count) tick=\(tickCount) scope=roots"
                + rankWorkSuffix(nodesComputed: engine.rankDispatchNodeCount(), rankDispatched: true)

        case .nodes(let rank, let predicate):
            let truth = engine.readTruthStates()
            let ranks = engine.readRanks()
            var rows: [(Int, UInt64, UInt8, UInt8)] = []
            var omitted = 0
            for i in 0..<nodeCount {
                if let r = rank, ranks[i] != UInt64(r) { continue }
                if let pred = predicate, !pred.evaluate(truth: truth[i], rank: ranks[i], nodeType: 0) { continue }
                // Skip nodes with rank 0 and truth 0 and no explicit rank (likely unused)
                if rank == nil && ranks[i] == 0 && truth[i] == 0 { omitted += 1; continue }
                rows.append((i, ranks[i], truth[i], 0))
            }
            if let e = writeResults(rows) { return e }
            // D7 · `omitted=` is the count this default filter dropped —
            // rank-0, truth-0 nodes. The filter is disclosed, not changed.
            return "OK NODES rows=\(rows.count) omitted=\(omitted)"

        case .traverse(let fromNode, let depth):
            if let e = checkRange("node", fromNode, upTo: nodeCount) { return e }
            // D1 · depth drove the frontier loop unbounded. No path in a DAG
            // on N nodes is longer than N-1 hops, so `nodeCount` IS the true
            // extent of a useful depth.
            if let e = checkRange("depth", depth, upTo: nodeCount) { return e }
            var visited: [(Int, UInt64, UInt8, UInt8)] = []
            // D2 · a GLOBAL visited set. Without it a node reachable at
            // several depths was appended once per level, so `rows.count`
            // was Σ|frontier_d| — unbounded in `depth` and unrelated to the
            // shm mapping's `nodeCount` rows (audit B finding 6). With it
            // the row count is bounded by `nodeCount` by construction, and
            // `writeResults` checks the bytes anyway.
            var seen: Set<Int> = []
            var frontier: Set<Int> = [fromNode]
            let truth = engine.readTruthStates()
            let ranks = engine.readRanks()

            for _ in 0..<depth {
                var nextFrontier: Set<Int> = []
                for node in frontier {
                    if seen.insert(node).inserted {
                        visited.append((node, ranks[node], truth[node], 0))
                    }
                    for d in 0..<6 {
                        let nb = grid.neighbors[node * 6 + d]
                        if nb >= 0 && !seen.contains(Int(nb)) {
                            nextFrontier.insert(Int(nb))
                        }
                    }
                }
                frontier = nextFrontier
            }
            if let e = writeResults(visited) { return e }
            return "OK TRAVERSE rows=\(visited.count) from=\(fromNode) depth=\(depth)"

        case .setTruth(let node, let value):
            if let e = checkRange("node", node, upTo: nodeCount) { return e }
            // Log-first: append to WAL (fsync'd) before touching engine buffer.
            // If WAL fails, abort the mutation so the log and engine stay in sync.
            if let wal = walAppender {
                do { _ = try wal.setTruth(node: UInt32(node), value: value) }
                catch { return "ERROR wal: append: \(error)" }
            }
            engine.truthStateBuf.contents()
                .bindMemory(to: UInt8.self, capacity: nodeCount)[node] = value
            truthRankIndex.markDirty()
            engine.markRankTopologyDirty()
            return "OK SET node=\(node) truth=\(value)"

        case .setWeight(let node, let dir, let value):
            if let e = checkRange("node", node, upTo: nodeCount) { return e }
            guard dir >= 0 && dir < 6 else { return "ERROR out_of_range: dir \(dir) not in 0..5" }
            guard value.isFinite else { return "ERROR bad_value: weight must be finite" }
            if let wal = walAppender {
                do { _ = try wal.setEdgeWeight(node: UInt32(node), dir: UInt8(dir), value: value) }
                catch { return "ERROR wal: append: \(error)" }
            }
            engine.edgeWeightsBuf.contents()
                .bindMemory(to: Float.self, capacity: nodeCount * 6)[node * 6 + dir] = value
            return "OK SET node=\(node) weight[\(dir)]=\(value)"

        case .setValue(let node, let value):
            if let e = checkRange("node", node, upTo: nodeCount) { return e }
            guard value.isFinite else { return "ERROR bad_value: value must be finite" }
            if let wal = walAppender {
                do { _ = try wal.setNodeValue(node: UInt32(node), value: value) }
                catch { return "ERROR wal: append: \(error)" }
            }
            engine.nodeValueBuf.contents()
                .bindMemory(to: Float.self, capacity: nodeCount)[node] = value
            return "OK SET node=\(node) value=\(value)"

        case .setRank(let node, let value):
            if let e = checkRange("node", node, upTo: nodeCount) { return e }
            // R3 · the door. No valid DAG on N nodes holds a rank of N or
            // more, and a typo there would turn the rank loop into a denial
            // of service. A rank in [maxRank, nodeCount) is ACCEPTED and
            // computed — the bound is a sizing hint, not a limit.
            guard value < UInt64(nodeCount) else {
                return "ERROR out_of_range: rank \(value) not in 0..<\(nodeCount)"
            }
            if let wal = walAppender {
                do { _ = try wal.setRank(node: UInt32(node), value: value) }
                catch { return "ERROR wal: append: \(error)" }
            }
            engine.rankBuf.contents()
                .bindMemory(to: UInt64.self, capacity: nodeCount)[node] = value
            truthRankIndex.markDirty()
            engine.markRankTopologyDirty()
            return "OK SET node=\(node) rank=\(value)"

        case .setLUT(let node, let preset):
            if let e = checkRange("node", node, upTo: nodeCount) { return e }
            let lut: UInt64
            switch preset {
            case "AND", "AND6": lut = LUT6Preset.and6
            case "OR", "OR6": lut = LUT6Preset.or6
            case "XOR", "XOR6": lut = LUT6Preset.xor6
            case "MAJ", "MAJORITY", "MAJ6": lut = LUT6Preset.majority6
            case "IDENTITY", "ID": lut = LUT6Preset.identity
            case "CONST0", "FALSE": lut = LUT6Preset.const0
            case "CONST1", "TRUE": lut = LUT6Preset.const1
            case "VETO": lut = LUT6Preset.veto
            case "NOR", "NOR6": lut = LUT6Preset.nor6
            case "NAND", "NAND6": lut = LUT6Preset.nand6
            case "AND3": lut = LUT6Preset.and3
            case "OR3":  lut = LUT6Preset.or3
            case "MAJ3": lut = LUT6Preset.maj3
            default:
                // Accept a raw 64-bit hex literal (with or without `0x`/`0X`
                // prefix) for arbitrary truth-tables that have no preset name.
                // Required for the AC-3 keep nodes whose fan-in (1, 3, 4, 6)
                // doesn't match any AND_N preset.
                let hex = preset.hasPrefix("0X") ? String(preset.dropFirst(2)) : preset
                if let v = UInt64(hex, radix: 16) {
                    lut = v
                } else {
                    return "ERROR dsl_parse: unknown LUT preset: \(preset). Use a named preset (AND OR XOR MAJ IDENTITY CONST0 CONST1 VETO NOR NAND AND3 OR3 MAJ3) or a 64-bit hex literal like 0xAAAAAAAAAAAAAAAA"
                }
            }
            if let wal = walAppender {
                do { _ = try wal.setLUT(node: UInt32(node), lut: lut) }
                catch { return "ERROR wal: append: \(error)" }
            }
            let low = UInt32(lut & 0xFFFFFFFF)
            let high = UInt32((lut >> 32) & 0xFFFFFFFF)
            engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)[node] = low
            engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)[node] = high
            return "OK SET node=\(node) lut=\(preset)"

        case .clearEdges(let node):
            // D-bounds · both sides of the range, named refusal, before any
            // pointer touch. Subsumes the incoming side's one-sided guard.
            if let e = checkRange("node", node, upTo: nodeCount) { return e }
            // Log-first (C1a): this writes neighborsBuf, and until the v2
            // opcode existed it did so with no record at all.
            if let wal = walAppender {
                do { _ = try wal.clearEdges(node: UInt32(node)) }
                catch { return "ERROR wal: append: \(error)" }
            }
            let nbPtr = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)
            for d in 0..<6 { nbPtr[node * 6 + d] = -1 }
            return "OK CLEAR node=\(node) edges"

        case .connect(let src, let dst):
            if let e = checkRange("src", src, upTo: nodeCount) { return e }
            if let e = checkRange("dst", dst, upTo: nodeCount) { return e }
            if src == dst { return "ERROR schema: self-loop: src == dst (\(src))" }
            // BACK_EDGE invariant: a register (back-edge dst) must not gain
            // combinational fan-in. Reject the connect to keep the latch
            // semantics safe.
            if engine.isRegister(node: UInt32(dst)) {
                return "ERROR schema: back_edge_violation: node \(dst) is a BACK_EDGE destination (register); use CLEAR \(dst) BACK_EDGES first if you want a combinational input here"
            }
            let rankPtr = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: nodeCount)
            let srcRank = rankPtr[src]
            let dstRank = rankPtr[dst]
            guard srcRank > dstRank else {
                return "ERROR schema: rank violation: src(\(src)) rank=\(srcRank) must be > dst(\(dst)) rank=\(dstRank) — edges flow leaves→roots"
            }
            // Find first empty neighbor slot on dst; reject duplicates.
            // The slot is resolved BEFORE the log append (C1a) so the record
            // names the slot it will occupy: replay then reproduces the table
            // without re-deriving "first free slot" from a different state.
            let nbPtr = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)
            for d in 0..<6 {
                if nbPtr[dst * 6 + d] == Int32(src) {
                    return "ERROR schema: duplicate edge: \(src) → \(dst)"
                }
            }
            var slot = -1
            for d in 0..<6 where nbPtr[dst * 6 + d] < 0 { slot = d; break }
            guard slot >= 0 else {
                return "ERROR schema: node \(dst) already has 6 edges (6-bounded)"
            }
            if let wal = walAppender {
                do { _ = try wal.connect(dst: UInt32(dst), slot: UInt8(slot), src: Int32(src)) }
                catch { return "ERROR wal: append: \(error)" }
            }
            nbPtr[dst * 6 + slot] = Int32(src)
            return "OK CONNECT from=\(src) to=\(dst)"

        case .connectBack(let src, let dst):
            if let e = checkRange("src", src, upTo: nodeCount) { return e }
            if let e = checkRange("dst", dst, upTo: nodeCount) { return e }
            if src == dst { return "ERROR schema: self-loop: src == dst (\(src))" }
            // C12 · validate, then log, then apply — the order the WAL file
            // header promises for EVERY mutation. Validation touches nothing,
            // so a refused edge writes no record; the append comes next, so a
            // log that will not take the record leaves the engine unchanged;
            // the buffer is written last.
            //
            // (This used to apply first and append afterwards, excused by a
            // comment claiming `addBackEdge` is idempotent on duplicates. It
            // is not — it appends a second entry — and the excuse is
            // withdrawn.)
            do {
                try engine.validateBackEdge(src: UInt32(src), dst: UInt32(dst))
            } catch let err as DagDBEngine.BackEdgeError {
                return "ERROR schema: \(err)"
            } catch {
                return "ERROR schema: \(error)"
            }
            if let wal = walAppender {
                do { _ = try wal.connectBack(src: UInt32(src), dst: UInt32(dst)) }
                catch { return "ERROR wal: append: \(error)" }
            }
            do {
                try engine.registerValidatedBackEdge(src: UInt32(src), dst: UInt32(dst))
            } catch {
                return "ERROR schema: \(error)"
            }
            return "OK CONNECT BACK from=\(src) to=\(dst)"

        case .clearBackEdges(let node):
            if let e = checkRange("node", node, upTo: nodeCount) { return e }
            if let wal = walAppender {
                do { _ = try wal.clearBackEdges(dst: UInt32(node)) }
                catch { return "ERROR wal: append: \(error)" }
            }
            let before = engine.backEdgeCount
            // C4 made the engine call refuse an out-of-range node by name.
            // The guard above already covers it; the catch is what the new
            // signature requires, not a second policy.
            do { try engine.clearBackEdges(toNode: UInt32(node)) }
            catch { return "ERROR out_of_range: \(error)" }
            let removed = before - engine.backEdgeCount
            return "OK CLEAR node=\(node) back_edges removed=\(removed)"

        case .getTruth(let node):
            if let e = checkRange("node", node, upTo: nodeCount) { return e }
            let truth = engine.truthStateBuf.contents()
                .bindMemory(to: UInt8.self, capacity: nodeCount)[node]
            return "OK GET node=\(node) truth=\(truth)"

        case .graphInfo:
            let ranks = engine.readRanks()
            let truth = engine.readTruthStates()
            var rankCounts: [UInt64: Int] = [:]
            var trueCount = 0
            for i in 0..<nodeCount {
                rankCounts[ranks[i], default: 0] += 1
                if truth[i] == 1 { trueCount += 1 }
            }
            let rankStr = rankCounts.sorted(by: { $0.key < $1.key })
                .map { "r\($0.key)=\($0.value)" }.joined(separator: " ")
            return "OK GRAPH nodes=\(nodeCount) true=\(trueCount) \(rankStr)"

        case .save(let path, let compressed):
            if let err = guardPath(path) { return err }
            return durableSnapshot(path: path, compressed: compressed)

        case .load(let path):
            if let err = guardPath(path) { return err }
            do {
                let r = try DagDBSnapshot.load(
                    engine: engine,
                    nodeCount: nodeCount,
                    gridW: width,
                    gridH: height,
                    path: path,
                    daemonEnv: DagDBSnapshot.SnapshotEnv.from(envString: dagdbEnv),
                    twin: twin
                )
                tickCount = r.fileTicks
                truthRankIndex.markDirty()
                engine.markRankTopologyDirty()
                return "OK LOAD bytes=\(r.bytesRead) nodes=\(r.fileNodeCount) ticks=\(r.fileTicks) elapsed=\(String(format: "%.1f", r.elapsedMs))ms"
            } catch {
                return "ERROR io: load: \(error)"
            }

        case .exportMorton(let dir):
            if let err = guardPath(dir) { return err }
            do {
                let r = try DagDBSnapshot.exportMorton(
                    engine: engine,
                    nodeCount: nodeCount,
                    dir: dir
                )
                return "OK EXPORT bytes=\(r.bytesWritten) elapsed=\(String(format: "%.1f", r.elapsedMs))ms dir=\(dir)"
            } catch {
                return "ERROR io: export: \(error)"
            }

        case .importMorton(let dir):
            if let err = guardPath(dir) { return err }
            do {
                let r = try DagDBSnapshot.importMorton(
                    engine: engine,
                    nodeCount: nodeCount,
                    dir: dir
                )
                truthRankIndex.markDirty()
                engine.markRankTopologyDirty()
                return "OK IMPORT bytes=\(r.bytesRead) elapsed=\(String(format: "%.1f", r.elapsedMs))ms dir=\(dir)"
            } catch {
                return "ERROR io: import: \(error)"
            }

        case .validateGraph:
            if let violation = DagDBSnapshot.validate(engine: engine, nodeCount: nodeCount) {
                return "FAIL VALIDATE \(violation)"
            } else {
                return "OK VALIDATE — all edges satisfy rank ordering, bounds, no self-loops, no duplicates"
            }

        case .saveJSON(let path):
            if let err = guardPath(path) { return err }
            do {
                let r = try DagDBJSONIO.saveJSON(
                    engine: engine, nodeCount: nodeCount,
                    gridW: width, gridH: height,
                    tickCount: tickCount, path: path
                )
                return "OK SAVE_JSON bytes=\(r.bytesWritten) elapsed=\(String(format: "%.1f", r.elapsedMs))ms path=\(path)"
            } catch {
                return "ERROR io: save_json: \(error)"
            }

        case .loadJSON(let path):
            if let err = guardPath(path) { return err }
            do {
                let r = try DagDBJSONIO.loadJSON(
                    engine: engine, nodeCount: nodeCount,
                    gridW: width, gridH: height, path: path
                )
                tickCount = r.fileTicks
                truthRankIndex.markDirty()
                engine.markRankTopologyDirty()
                return "OK LOAD_JSON bytes=\(r.bytesRead) nodes=\(r.fileNodeCount) ticks=\(r.fileTicks) elapsed=\(String(format: "%.1f", r.elapsedMs))ms"
            } catch {
                return "ERROR io: load_json: \(error)"
            }

        case .saveCSV(let dir):
            if let err = guardPath(dir) { return err }
            do {
                let r = try DagDBJSONIO.saveCSV(
                    engine: engine, nodeCount: nodeCount, dir: dir
                )
                return "OK SAVE_CSV nodes_bytes=\(r.nodesBytes) edges_bytes=\(r.edgesBytes) elapsed=\(String(format: "%.1f", r.elapsedMs))ms dir=\(dir)"
            } catch {
                return "ERROR io: save_csv: \(error)"
            }

        case .loadCSV(let dir):
            if let err = guardPath(dir) { return err }
            do {
                let r = try DagDBJSONIO.loadCSV(
                    engine: engine, nodeCount: nodeCount, dir: dir
                )
                truthRankIndex.markDirty()
                engine.markRankTopologyDirty()
                return "OK LOAD_CSV nodes=\(r.nodesParsed) edges=\(r.edgesParsed) elapsed=\(String(format: "%.1f", r.elapsedMs))ms"
            } catch {
                return "ERROR io: load_csv: \(error)"
            }

        case .backupInit(let dir):
            if let err = guardPath(dir) { return err }
            do {
                let r = try DagDBBackup.initializeChain(
                    engine: engine, nodeCount: nodeCount,
                    gridW: width, gridH: height,
                    tickCount: tickCount, dir: dir
                )
                return "OK BACKUP_INIT base_bytes=\(r.baseBytes) elapsed=\(String(format: "%.1f", r.elapsedMs))ms dir=\(dir)"
            } catch {
                return "ERROR io: backup_init: \(error)"
            }

        case .backupAppend(let dir):
            if let err = guardPath(dir) { return err }
            do {
                let r = try DagDBBackup.appendDiff(
                    engine: engine, nodeCount: nodeCount,
                    gridW: width, gridH: height, dir: dir
                )
                return "OK BACKUP_APPEND bytes=\(r.diffBytes) elapsed=\(String(format: "%.1f", r.elapsedMs))ms path=\(r.diffPath) format=\(DagDBBackup.diffVersion)"
            } catch {
                return backupErrorReply(error, verb: "backup_append")
            }

        case .backupRestore(let dir):
            if let err = guardPath(dir) { return err }
            do {
                let r = try DagDBBackup.restore(
                    engine: engine, nodeCount: nodeCount,
                    gridW: width, gridH: height, dir: dir
                )
                truthRankIndex.markDirty()
                engine.markRankTopologyDirty()
                return "OK BACKUP_RESTORE diffs_replayed=\(r.diffsReplayed) elapsed=\(String(format: "%.1f", r.elapsedMs))ms rank_bytes=\(r.rankBytes) twin=not_covered"
            } catch {
                return backupErrorReply(error, verb: "backup_restore")
            }

        case .backupCompact(let dir):
            if let err = guardPath(dir) { return err }
            do {
                // The new base comes from the chain's own replayed tip, at the
                // chain's own tick count — never from this live engine, which
                // COMPACT does not read and does not change.
                let r = try DagDBBackup.compact(
                    nodeCount: nodeCount,
                    gridW: width, gridH: height, dir: dir
                )
                return "OK BACKUP_COMPACT prior_diffs=\(r.priorDiffCount) new_base_bytes=\(r.newBaseBytes) elapsed=\(String(format: "%.1f", r.elapsedMs))ms"
            } catch {
                return backupErrorReply(error, verb: "backup_compact")
            }

        case .backupInfo(let dir):
            if let err = guardPath(dir) { return err }
            do {
                let r = try DagDBBackup.info(dir: dir)
                // INFO is read-only: a format-1 chain is named, never refused.
                let caveat = r.isLegacyFormat
                    ? " caveat=\(DagDBBackup.legacyFormatMessage)"
                    : ""
                return "OK BACKUP_INFO base=\(r.baseExists) base_bytes=\(r.baseSizeBytes) diffs=\(r.diffCount) total_diff_bytes=\(r.totalDiffBytes) format=\(r.formatVersion) twin=not_covered\(caveat)"
            } catch {
                return backupErrorReply(error, verb: "backup_info")
            }

        case .setRanksBulk:
            // Read u64 rank vector of length nodeCount from shm offset 8,
            // commit to rankBuf. Caller's responsibility to ensure the
            // injected ranks preserve the monotonicity invariant for any
            // existing edges — the bulk commit skips per-insert validation
            // for speed. Follow up with VALIDATE if paranoid.
            //
            // R3 · the door. The one thing it no longer skips is the range:
            // the WHOLE vector is checked before a single rank is written,
            // so a bad entry leaves every rank exactly as it was, and the
            // refusal names the first offending node. Ranks in
            // [maxRank, nodeCount) pass — they are computed, not refused.
            if let e = checkShmFits(rows: nodeCount, rowSize: 8) { return e }
            let src = shmBase.advanced(by: 8).bindMemory(to: UInt64.self, capacity: nodeCount)
            for i in 0..<nodeCount where src[i] >= UInt64(nodeCount) {
                return "ERROR out_of_range: node \(i) rank \(src[i]) not in 0..<\(nodeCount)"
            }
            if let wal = walAppender {
                do { _ = try wal.setRanksBulk(src, count: nodeCount) }
                catch { return "ERROR wal: append: \(error)" }
            }
            let dst = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: nodeCount)
            for i in 0..<nodeCount { dst[i] = src[i] }
            truthRankIndex.markDirty()
            engine.markRankTopologyDirty()
            return "OK SET_RANKS_BULK nodes=\(nodeCount)"
                + " validation=skipped skipped=rank_monotonicity recheck=VALIDATE"

        case .setLutsBulk:
            // Read u64[nodeCount] LUT vector from shm offset 8 and commit
            // each entry to lut6Low/lut6High (low 32 = bits 0-31, high 32 =
            // bits 32-63). Compiles a million-node microcircuit's LUT vector
            // in one round-trip; pair with SAVE if you need durability.
            if let e = checkShmFits(rows: nodeCount, rowSize: 8) { return e }
            let src = shmBase.advanced(by: 8).bindMemory(to: UInt64.self, capacity: nodeCount)
            if let wal = walAppender {
                do { _ = try wal.setLutsBulk(src, count: nodeCount) }
                catch { return "ERROR wal: append: \(error)" }
            }
            let low = engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
            let high = engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
            for i in 0..<nodeCount {
                let v = src[i]
                low[i] = UInt32(v & 0xFFFF_FFFF)
                high[i] = UInt32((v >> 32) & 0xFFFF_FFFF)
            }
            return "OK SET_LUTS_BULK nodes=\(nodeCount)"

        case .setNeighborsBulk:
            // Read Int32[nodeCount * 6] neighbour vector from shm offset 8
            // and memcpy to neighborsBuf. Bypasses rank-monotonicity check;
            // run VALIDATE after if you do not trust the writer.
            let count = nodeCount * 6
            // D6 · the READ side of this verb never consulted the mapping's
            // real size — `configuredShmCapacityBytes` may be smaller than
            // the default `8 + nodeCount * 24` (audit B finding 12).
            if let e = checkShmFits(rows: count, rowSize: 4) { return e }
            let src = shmBase.advanced(by: 8).bindMemory(to: Int32.self, capacity: count)
            // D6 · range-check the WHOLE vector before writing one word, as
            // SET_RANKS_BULK already did: a bad slot leaves every neighbour
            // exactly as it was, and the refusal names the first offender.
            // -1 is the empty-slot sentinel the Metal kernel tolerates.
            for i in 0..<count where src[i] < -1 || src[i] >= Int32(clamping: nodeCount) {
                return "ERROR out_of_range: slot \(i) (node \(i / 6) dir \(i % 6))"
                    + " neighbour \(src[i]) not in -1..<\(nodeCount)"
            }
            // Log-first (C1): the vector is validated above, so a refused
            // install writes no record; the append precedes the memcpy, so a
            // log that will not take the record leaves neighborsBuf unchanged.
            if let wal = walAppender {
                do { _ = try wal.setNeighborsBulk(src, count: nodeCount) }
                catch { return "ERROR wal: append: \(error)" }
            }
            let dst = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: count)
            for i in 0..<count { dst[i] = src[i] }
            // D6 · the verb bypasses the BACK_EDGE/register invariant that
            // CONNECT enforces; say so rather than let a caller assume the
            // install validated what CONNECT validates.
            return "OK SET_NEIGHBORS_BULK nodes=\(nodeCount) edges_slot=\(count)"
                + " validation=skipped skipped=back_edge_register_fanin recheck=VALIDATE"

        case .composeLUT(let op, let src1, let src2, let dst):
            // Bitwise composition of LUTs into dst's LUT.
            // Caller is responsible for the assumption that src1, src2, dst
            // share a common input vector — the engine just performs the
            // bitwise op on the 64-bit LUT integers. Mutates only dst's LUT.
            if let e = checkRange("src1", src1, upTo: nodeCount) { return e }
            if let e = checkRange("dst", dst, upTo: nodeCount) { return e }
            if let s2 = src2, let e = checkRange("src2", s2, upTo: nodeCount) { return e }
            let lowPtr  = engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
            let highPtr = engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
            let aLow  = lowPtr[src1]
            let aHigh = highPtr[src1]
            let resultLow: UInt32
            let resultHigh: UInt32
            switch op {
            case "NOT":
                resultLow  = ~aLow
                resultHigh = ~aHigh
            case "AND":
                guard let s2 = src2 else { return "ERROR dsl_parse: AND requires two sources" }
                resultLow  = aLow  & lowPtr[s2]
                resultHigh = aHigh & highPtr[s2]
            case "OR":
                guard let s2 = src2 else { return "ERROR dsl_parse: OR requires two sources" }
                resultLow  = aLow  | lowPtr[s2]
                resultHigh = aHigh | highPtr[s2]
            case "XOR":
                guard let s2 = src2 else { return "ERROR dsl_parse: XOR requires two sources" }
                resultLow  = aLow  ^ lowPtr[s2]
                resultHigh = aHigh ^ highPtr[s2]
            default:
                return "ERROR dsl_parse: unknown compose op '\(op)' — try AND, OR, XOR, NOT"
            }
            // WAL the equivalent SET_LUT before the engine mutation.
            if let wal = walAppender {
                let lut = (UInt64(resultHigh) << 32) | UInt64(resultLow)
                do { _ = try wal.setLUT(node: UInt32(dst), lut: lut) }
                catch { return "ERROR wal: append: \(error)" }
            }
            lowPtr[dst]  = resultLow
            highPtr[dst] = resultHigh
            // truthRankIndex doesn't depend on LUT, no dirty flag flip needed.
            let dstLut64 = (UInt64(resultHigh) << 32) | UInt64(resultLow)
            let src2Display = src2.map { String($0) } ?? "—"
            return "OK COMPOSE op=\(op) src1=\(src1) src2=\(src2Display) dst=\(dst) lut=0x\(String(dstLut64, radix: 16, uppercase: true))"

        case .selectByTruthRank(let truthVal, let lo, let hi):
            let matches = truthRankIndex.select(
                truth: truthVal, rankLo: lo, rankHi: hi,
                engine: engine, nodeCount: nodeCount
            )
            // Write node IDs as Int32[] to shm at offset 8 (same layout as BFS_DEPTHS)
            if let e = checkShmFits(rows: matches.count, rowSize: 4) { return e }
            let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
            headerPtr[0] = UInt32(matches.count)
            headerPtr[1] = 0
            let dataPtr = shmBase.advanced(by: 8).bindMemory(to: Int32.self, capacity: max(1, matches.count))
            for (i, nodeId) in matches.enumerated() {
                dataPtr[i] = Int32(nodeId)
            }
            let bucketInfo = truthRankIndex.bucketSizes[truthVal] ?? 0
            return "OK SELECT truth=\(truthVal) rank=\(lo)-\(hi) matches=\(matches.count) bucket_size=\(bucketInfo) shm_bytes=\(matches.count * 4)"

        case .bfsDepths(let seed, let undirected):
            if let e = checkRange("node", seed, upTo: nodeCount) { return e }
            do {
                let r = undirected
                    ? try DagDBBFS.bfsDepthsUndirected(engine: engine, nodeCount: nodeCount, from: seed)
                    : try DagDBBFS.bfsDepthsBackward(engine: engine, nodeCount: nodeCount, from: seed)
                // Write depths[0..<nodeCount] to shared memory as raw Int32[].
                // Layout: [4:nodeCount][4:reserved][Int32 × nodeCount]
                if let e = checkShmFits(rows: nodeCount, rowSize: 4) { return e }
                let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
                headerPtr[0] = UInt32(nodeCount)
                headerPtr[1] = 0
                let dataPtr = shmBase.advanced(by: 8).bindMemory(to: Int32.self, capacity: nodeCount)
                r.depths.withUnsafeBufferPointer { buf in
                    for i in 0..<nodeCount { dataPtr[i] = buf[i] }
                }
                let dir = undirected ? "undirected" : "backward"
                return "OK BFS_DEPTHS seed=\(seed) dir=\(dir) reached=\(r.reached) max_depth=\(r.maxDepth) elapsed=\(String(format: "%.1f", r.elapsedMs))ms shm_bytes=\(nodeCount * 4) \(r.disclosure) back_edge_count=\(r.backEdgeCount)"
            } catch {
                return "ERROR bfs: depths: \(error)"
            }

        case .distance(let metric, let loA, let hiA, let loB, let hiB):
            guard let m = DagDBDistance.Metric(rawValue: metric) else {
                return "ERROR dsl_parse: unknown metric '\(metric)' — try jaccardNodes, jaccardEdges, rankL1, rankL2, typeL1, boundedGED, wlL1, spectralL2"
            }
            let subA = DagSubgraph.rankRange(engine: engine, nodeCount: nodeCount, lo: loA, hi: hiA)
            let subB = DagSubgraph.rankRange(engine: engine, nodeCount: nodeCount, lo: loB, hi: hiB)
            let v = DagDBDistance.compute(
                engine: engine, nodeCount: nodeCount, metric: m, subA, subB)
            return "OK DISTANCE \(metric) \(loA)-\(hiA) vs \(loB)-\(hiB) value=\(v) |A|=\(subA.nodeIds.count) |B|=\(subB.nodeIds.count)"

        case .openReader:
            do {
                let tmplState = DagDBState(width: width, height: height)
                let session = try sessionManager.open(
                    primary: engine, grid: grid, stateTemplate: tmplState,
                    maxRank: maxRank, tickCount: tickCount
                )
                return "OK OPEN_READER id=\(session.id) tick=\(session.tickCountAtOpen) open_sessions=\(sessionManager.openCount)"
            } catch {
                return "ERROR io: open_reader: \(error)"
            }

        case .closeReader(let id):
            let ok = sessionManager.close(id)
            return ok
                ? "OK CLOSE_READER id=\(id) open_sessions=\(sessionManager.openCount)"
                : "ERROR not_found: close_reader session \(id) not found"

        case .listReaders:
            let sessions = sessionManager.openSessions
            if sessions.isEmpty {
                return "OK LIST_READERS open_sessions=0"
            }
            let ids = sessions.map { "\($0.id)@tick=\($0.tickCountAtOpen)" }.joined(separator: " ")
            return "OK LIST_READERS open_sessions=\(sessions.count) \(ids)"

        case .reader(let id, let inner):
            guard let session = sessionManager.get(id) else {
                return "ERROR not_found: reader session \(id) not found"
            }
            return handleReadOnly(inner, engine: session.snapshotEngine,
                                  nodeCount: session.nodeCount,
                                  gridW: session.gridW, gridH: session.gridH,
                                  sessionId: session.id)

        case .ancestry(let node, let depth):
            if let e = checkRange("node", node, upTo: nodeCount) { return e }
            if let e = checkRange("depth", depth, upTo: nodeCount) { return e }
            do {
                let r = try DagDBBFS.bfsDepthsBackward(
                    engine: engine, nodeCount: nodeCount, from: node)
                // Collect (nodeId, depth) for d in [0, depthCap].
                var pairs: [(Int32, Int32)] = []
                for i in 0..<nodeCount {
                    let d = r.depths[i]
                    if d >= 0 && d <= Int32(depth) {
                        pairs.append((Int32(i), d))
                    }
                }
                pairs.sort { $0.1 < $1.1 }
                if let e = checkShmFits(rows: pairs.count, rowSize: 8) { return e }

                let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
                headerPtr[0] = UInt32(pairs.count)
                headerPtr[1] = 0
                let dataPtr = shmBase.advanced(by: 8)
                for (i, (n, d)) in pairs.enumerated() {
                    dataPtr.advanced(by: i * 8).storeBytes(of: n, as: Int32.self)
                    dataPtr.advanced(by: i * 8 + 4).storeBytes(of: d, as: Int32.self)
                }
                return "OK ANCESTRY from=\(node) depth=\(depth) count=\(pairs.count) elapsed=\(String(format: "%.1f", r.elapsedMs))ms shm_bytes=\(pairs.count * 8)"
            } catch {
                return "ERROR bfs: \(error)"
            }

        case .similarDecisions(let seed, let depth, let k, let truthFilter):
            if let e = checkRange("node", seed, upTo: nodeCount) { return e }
            if let e = checkRange("depth", depth, upTo: nodeCount) { return e }
            if let e = checkCap("k", k, 1, nodeCount) { return e }
            let t0 = Date()

            // 1. Query subgraph — seed + ancestors up to depth.
            let queryR: DagDBBFS.Result
            do {
                queryR = try DagDBBFS.bfsDepthsBackward(
                    engine: engine, nodeCount: nodeCount, from: seed)
            } catch {
                return "ERROR bfs: \(error)"
            }
            var querySet: Set<Int> = [seed]
            for i in 0..<nodeCount {
                let d = queryR.depths[i]
                if d > 0 && d <= Int32(depth) { querySet.insert(i) }
            }
            let querySub = DagSubgraph(querySet)
            let queryHist = DagDBDistance.weisfeilerLehman1Histogram(
                engine: engine, nodeCount: nodeCount, sub: querySub)

            // 2. Candidate pool — all nodes with matching truth (if given), minus seed.
            let truthPtr = engine.truthStateBuf.contents().bindMemory(
                to: UInt8.self, capacity: nodeCount)
            var candidates: [Int] = []
            for i in 0..<nodeCount where i != seed {
                if let t = truthFilter, truthPtr[i] != t { continue }
                candidates.append(i)
            }
            guard candidates.count <= Self.similarDecisionsCandidateCap else {
                return "ERROR out_of_range: SIMILAR_DECISIONS candidate pool \(candidates.count)"
                    + " not in 0...\(Self.similarDecisionsCandidateCap)"
                    + " — one backward BFS runs per candidate on the single-threaded accept loop;"
                    + " narrow the pool with AMONG TRUTH <t>"
            }

            // 3. Score each candidate by WL-1 L1 distance on its local subgraph.
            struct Scored { let node: Int32; let distance: Float }
            var scores: [Scored] = []
            scores.reserveCapacity(candidates.count)
            for c in candidates {
                guard let candR = try? DagDBBFS.bfsDepthsBackward(
                        engine: engine, nodeCount: nodeCount, from: c) else {
                    continue
                }
                var candSet: Set<Int> = [c]
                for i in 0..<nodeCount {
                    let d = candR.depths[i]
                    if d > 0 && d <= Int32(depth) { candSet.insert(i) }
                }
                let candHist = DagDBDistance.weisfeilerLehman1Histogram(
                    engine: engine, nodeCount: nodeCount, sub: DagSubgraph(candSet))
                let keys = Set(queryHist.keys).union(candHist.keys)
                let mass = Double(max(1, querySet.count + candSet.count))
                var sum = 0
                for key in keys {
                    sum += abs((queryHist[key] ?? 0) - (candHist[key] ?? 0))
                }
                scores.append(Scored(node: Int32(c), distance: Float(Double(sum) / mass)))
            }

            scores.sort { $0.distance < $1.distance }
            let topK = Array(scores.prefix(k))

            // 4. Serialize results: [4:count][4:reserved][(u32 node, f32 dist) × N]
            if let e = checkShmFits(rows: topK.count, rowSize: 8) { return e }
            let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
            headerPtr[0] = UInt32(topK.count)
            headerPtr[1] = 0
            let dataPtr = shmBase.advanced(by: 8)
            for (i, s) in topK.enumerated() {
                dataPtr.advanced(by: i * 8).storeBytes(of: s.node, as: Int32.self)
                dataPtr.advanced(by: i * 8 + 4).storeBytes(of: s.distance, as: Float.self)
            }
            let elapsed = Date().timeIntervalSince(t0) * 1000.0
            let filterDesc = truthFilter.map { "truth=\($0)" } ?? "all"
            return "OK SIMILAR_DECISIONS to=\(seed) depth=\(depth) k=\(k) filter=\(filterDesc) candidates=\(candidates.count) returned=\(topK.count) elapsed=\(String(format: "%.1f", elapsed))ms shm_bytes=\(topK.count * 8)"

        case .twin(let t):
            return handleTwin(t, sessionId: nil)

        case .saveTiled, .tiledOpen, .tiledBFS, .tiledSelect, .tiledStatus, .tiledList, .tiledClose,
             .tiledTick, .tiledGetTruth:
            return handleTiled(cmd, sessionId: nil)

        case .unknown(let raw):
            return "ERROR unknown_command: \(raw)"
        }
    }

    // MARK: - Read-only dispatcher (reader sessions)

    func handleReadOnly(
        _ cmd: DSLCommand,
        engine: DagDBEngine,
        nodeCount: Int,
        gridW: Int, gridH: Int,
        sessionId: String
    ) -> String {
        switch cmd {
        case .graphInfo:
            let ranks = engine.readRanks()
            let truth = engine.readTruthStates()
            var rankCounts: [UInt64: Int] = [:]
            var trueCount = 0
            for i in 0..<nodeCount {
                rankCounts[ranks[i], default: 0] += 1
                if truth[i] == 1 { trueCount += 1 }
            }
            let rankStr = rankCounts.sorted(by: { $0.key < $1.key })
                .map { "r\($0.key)=\($0.value)" }.joined(separator: " ")
            return "OK GRAPH session=\(sessionId) nodes=\(nodeCount) true=\(trueCount) \(rankStr)"

        case .nodes(let rank, let predicate):
            let truth = engine.readTruthStates()
            let ranks = engine.readRanks()
            var rows: [(Int, UInt64, UInt8, UInt8)] = []
            var omitted = 0
            for i in 0..<nodeCount {
                if let r = rank, ranks[i] != UInt64(r) { continue }
                if let pred = predicate, !pred.evaluate(truth: truth[i], rank: ranks[i], nodeType: 0) { continue }
                if rank == nil && ranks[i] == 0 && truth[i] == 0 { omitted += 1; continue }
                rows.append((i, ranks[i], truth[i], 0))
            }
            if let e = writeResults(rows) { return e }
            return "OK NODES session=\(sessionId) rows=\(rows.count) omitted=\(omitted)"

        case .traverse(let fromNode, let depth):
            if let e = checkRange("node", fromNode, upTo: nodeCount) { return e }
            if let e = checkRange("depth", depth, upTo: nodeCount) { return e }
            var visited: [(Int, UInt64, UInt8, UInt8)] = []
            var seen: Set<Int> = []
            var frontier: Set<Int> = [fromNode]
            let truth = engine.readTruthStates()
            let ranks = engine.readRanks()
            for _ in 0..<depth {
                var nextFrontier: Set<Int> = []
                for node in frontier {
                    if seen.insert(node).inserted {
                        visited.append((node, ranks[node], truth[node], 0))
                    }
                    let nb = engine.neighborsBuf.contents()
                        .bindMemory(to: Int32.self, capacity: nodeCount * 6)
                    for d in 0..<6 {
                        let src = nb[node * 6 + d]
                        if src >= 0 && !seen.contains(Int(src)) {
                            nextFrontier.insert(Int(src))
                        }
                    }
                }
                frontier = nextFrontier
            }
            if let e = writeResults(visited) { return e }
            return "OK TRAVERSE session=\(sessionId) rows=\(visited.count) from=\(fromNode) depth=\(depth)"

        case .validateGraph:
            if let violation = DagDBSnapshot.validate(engine: engine, nodeCount: nodeCount) {
                return "FAIL VALIDATE session=\(sessionId) \(violation)"
            } else {
                return "OK VALIDATE session=\(sessionId)"
            }

        case .bfsDepths(let seed, let undirected):
            if let e = checkRange("node", seed, upTo: nodeCount) { return e }
            do {
                let r = undirected
                    ? try DagDBBFS.bfsDepthsUndirected(engine: engine, nodeCount: nodeCount, from: seed)
                    : try DagDBBFS.bfsDepthsBackward(engine: engine, nodeCount: nodeCount, from: seed)
                if let e = checkShmFits(rows: nodeCount, rowSize: 4) { return e }
                let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
                headerPtr[0] = UInt32(nodeCount)
                headerPtr[1] = 0
                let dataPtr = shmBase.advanced(by: 8).bindMemory(to: Int32.self, capacity: nodeCount)
                r.depths.withUnsafeBufferPointer { buf in
                    for i in 0..<nodeCount { dataPtr[i] = buf[i] }
                }
                let dir = undirected ? "undirected" : "backward"
                return "OK BFS_DEPTHS session=\(sessionId) seed=\(seed) dir=\(dir) reached=\(r.reached) max_depth=\(r.maxDepth) elapsed=\(String(format: "%.1f", r.elapsedMs))ms shm_bytes=\(nodeCount * 4) \(r.disclosure) back_edge_count=\(r.backEdgeCount)"
            } catch {
                return "ERROR bfs: reader_depths: \(error)"
            }

        case .distance(let metric, let loA, let hiA, let loB, let hiB):
            guard let m = DagDBDistance.Metric(rawValue: metric) else {
                return "ERROR dsl_parse: reader_distance unknown metric '\(metric)'"
            }
            let subA = DagSubgraph.rankRange(engine: engine, nodeCount: nodeCount, lo: loA, hi: hiA)
            let subB = DagSubgraph.rankRange(engine: engine, nodeCount: nodeCount, lo: loB, hi: hiB)
            let v = DagDBDistance.compute(
                engine: engine, nodeCount: nodeCount, metric: m, subA, subB)
            return "OK DISTANCE session=\(sessionId) \(metric) \(loA)-\(hiA) vs \(loB)-\(hiB) value=\(v) |A|=\(subA.nodeIds.count) |B|=\(subB.nodeIds.count)"

        case .status:
            return "OK STATUS session=\(sessionId) nodes=\(nodeCount) grid=\(gridW)x\(gridH)"

        case .getTruth(let node):
            if let e = checkRange("node", node, upTo: nodeCount) { return e }
            let truth = engine.truthStateBuf.contents()
                .bindMemory(to: UInt8.self, capacity: nodeCount)[node]
            return "OK GET session=\(sessionId) node=\(node) truth=\(truth)"

        case .selectByTruthRank(let truthVal, let lo, let hi):
            // Session uses its own local index — rebuild on every call since
            // the session's snapshot buffers are static by construction
            // (snapshot-on-read, primary mutations don't reach here).
            let localIndex = TruthRankIndex()
            let matches = localIndex.select(
                truth: truthVal, rankLo: lo, rankHi: hi,
                engine: engine, nodeCount: nodeCount
            )
            if let e = checkShmFits(rows: matches.count, rowSize: 4) { return e }
            let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
            headerPtr[0] = UInt32(matches.count)
            headerPtr[1] = 0
            let dataPtr = shmBase.advanced(by: 8).bindMemory(to: Int32.self, capacity: max(1, matches.count))
            for (i, nodeId) in matches.enumerated() {
                dataPtr[i] = Int32(nodeId)
            }
            return "OK SELECT session=\(sessionId) truth=\(truthVal) rank=\(lo)-\(hi) matches=\(matches.count) shm_bytes=\(matches.count * 4)"

        case .ancestry(let node, let depth):
            if let e = checkRange("node", node, upTo: nodeCount) { return e }
            if let e = checkRange("depth", depth, upTo: nodeCount) { return e }
            do {
                let r = try DagDBBFS.bfsDepthsBackward(
                    engine: engine, nodeCount: nodeCount, from: node)
                var pairs: [(Int32, Int32)] = []
                for i in 0..<nodeCount {
                    let d = r.depths[i]
                    if d >= 0 && d <= Int32(depth) { pairs.append((Int32(i), d)) }
                }
                pairs.sort { $0.1 < $1.1 }
                if let e = checkShmFits(rows: pairs.count, rowSize: 8) { return e }
                let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
                headerPtr[0] = UInt32(pairs.count)
                headerPtr[1] = 0
                let dataPtr = shmBase.advanced(by: 8)
                for (i, (n, d)) in pairs.enumerated() {
                    dataPtr.advanced(by: i * 8).storeBytes(of: n, as: Int32.self)
                    dataPtr.advanced(by: i * 8 + 4).storeBytes(of: d, as: Int32.self)
                }
                return "OK ANCESTRY session=\(sessionId) from=\(node) depth=\(depth) count=\(pairs.count)"
            } catch {
                return "ERROR bfs: reader: \(error)"
            }

        case .tiledBFS, .tiledSelect, .tiledStatus, .tiledList, .tiledGetTruth:
            // Routers are daemon-global like twin registries (see
            // `tiledRouters`'s doc comment) — a reader session may run the
            // read-only TILED verbs against the same handler-owned routers
            // the primary path uses (TILED GET included — a truth readback,
            // no different from TILED BFS/SELECT). OPEN/CLOSE/SAVE/TICK
            // stay forbidden below (mutate the registry / the filesystem).
            return handleTiled(cmd, sessionId: sessionId)

        // All writes and nested sessions rejected.
        case .tick, .tickSync, .save, .load, .setTruth, .setRank, .setLUT,
             .setWeight, .setValue,
             .clearEdges, .connect, .connectBack, .clearBackEdges,
             .exportMorton, .importMorton,
             .saveJSON, .loadJSON, .saveCSV, .loadCSV,
             .backupInit, .backupAppend, .backupRestore, .backupCompact, .backupInfo,
             .setRanksBulk, .setLutsBulk, .setNeighborsBulk,
             .openReader, .closeReader, .listReaders, .reader,
             .similarDecisions, .composeLUT,
             .saveTiled, .tiledOpen, .tiledClose, .tiledTick:
            return "ERROR forbidden: command not allowed in reader session (read-only)"

        case .eval:
            // EVAL runs tick() which is a write on the snapshot's buffers.
            // Technically it only mutates the snapshot, not the primary, so
            // it's safe — but semantically a reader shouldn't tick. Reject.
            return "ERROR forbidden: EVAL not allowed in reader session (ticks mutate)"

        case .twin(let t):
            // D5 · FOLD RUN's own refusal, because the state it moves is not
            // a twin registry: it assigns the handler's `lastFold`, which
            // FOLD KEPT/SOURCE/TIER/INFO read (audit B finding 18). Those
            // four stay open to a reader; RUN does not.
            if case .foldRun = t {
                return "ERROR forbidden: FOLD RUN assigns the daemon-global last-fold result"
                    + " that FOLD KEPT/SOURCE/TIER/INFO read; not allowed in reader session"
            }
            // Twin registries are daemon-global (§0.13) — a reader session
            // may only run the read-only twin verbs, dispatched against the
            // same handler-owned twin state as the primary path.
            guard t.isReadOnly else {
                return "ERROR forbidden: twin verb mutates daemon-global twin state; not allowed in reader session"
            }
            return handleTwin(t, sessionId: sessionId)

        case .unknown(let raw):
            return "ERROR unknown_command: reader inner: \(raw)"
        }
    }

    // MARK: - Shared-memory result writer

    /// D2 · every shared-memory WRITE checks capacity, as the read side
    /// (`readFloats`/`readDoubles`/`readU32s`) always did. Returns nil when
    /// the rows fit, else the refusal line — nothing is written in that
    /// case, so the previous result in shm stays intact and readable.
    @discardableResult
    func writeResults(_ rows: [(Int, UInt64, UInt8, UInt8)]) -> String? {
        if let e = checkShmFits(rows: rows.count, rowSize: resultRowSize) { return e }
        let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
        headerPtr[0] = UInt32(rows.count)
        headerPtr[1] = UInt32(resultRowSize)

        let dataPtr = shmBase.advanced(by: 8)
        for (i, row) in rows.enumerated() {
            let rowPtr = dataPtr.advanced(by: i * resultRowSize)
            rowPtr.storeBytes(of: UInt64(row.0), as: UInt64.self)
            rowPtr.advanced(by: 8).storeBytes(of: row.1, as: UInt64.self)
            rowPtr.advanced(by: 16).storeBytes(of: row.2, as: UInt8.self)
            rowPtr.advanced(by: 17).storeBytes(of: row.3, as: UInt8.self)
            // 6 bytes pad at offsets 18..23 — zeroed once at shm init
        }
        return nil
    }

    /// The one capacity refusal every shm writer shares (gate D2). The
    /// arithmetic is overflow-reporting so a row count off the wire cannot
    /// trap on the way to the guard that exists to catch it (gate D3).
    func checkShmFits(rows: Int, rowSize: Int) -> String? {
        let (product, mulOverflow) = rows.multipliedReportingOverflow(by: rowSize)
        if mulOverflow {
            return "ERROR out_of_range: result needs \(rows) x \(rowSize) bytes (overflows Int),"
                + " shm holds \(shmCapacityBytes)"
        }
        let (needed, addOverflow) = product.addingReportingOverflow(8)
        if addOverflow || needed > shmCapacityBytes {
            return "ERROR out_of_range: result needs \(addOverflow ? product : needed) bytes,"
                + " shm holds \(shmCapacityBytes)"
        }
        return nil
    }
}
