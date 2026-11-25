/// The budget is a hard bound, with no exceptions left.
///
/// - The Metal pool is a fixed reservation in the fixed state (`DaemonMemoryBudget.poolReservationBytes`),
///   admitted once at boot; the first GPU command measures the pool, and a larger one raises the reservation (or, when
///   the budget cannot hold it, every later GPU verb is refused by name).
/// - The tick verbs' transients (the CPU latch, the latch plan's build, the counting session) are admitted at the
///   verb before they allocate, and the plan's resident is in the committed-bytes ledger.
/// - First-use allocations (the ternary lanes, the rank table, SELECT's index, BFS_DEPTHS, what the first TICK,
///   TICK_SYNC and TICK UNTIL_STABLE leave) are admitted at first use and kept in the ledger; STATUS never allocates.
/// - BACKUP RESTORE and SAVE's body are admitted at their measured factors (`AdmissionCharge`).
/// - Names stored in twin state are capped at `TwinState.nameCap` bytes on the live verbs.
///
/// Every charge is AdmissionCharge's measured factor x 1.1, never below two pages (`newBytes`).
///
/// Amateur engineering project; no competitive claims; errors likely.
import Foundation
import DagDB

extension DagDBCommandHandler {
    /// One item of an admission: the bytes before the margin and their words.
    typealias Alloc1dItem = (bytes: Double, what: String)

    /// Admit the items together (their sum x 1.1, at least two pages), or the refusal. nil also with no budget or no item.
    /// A GPU verb (`gpu`) also asks the footprint side for the Metal pool's room when
    /// the pool is not resident now (none of this process's queues made a command buffer in the last second: it drains
    /// 1.0-1.5 s after the last), even with no item of its own, so unledgered resident memory cannot take the pool's room.
    func alloc1dAdmit(_ verb: String, _ items: [Alloc1dItem?], gpu: Bool = false) -> String? {
        let xs = items.compactMap { $0 }
        guard let budget = memoryBudget else { return nil }
        if gpu {
            let resident = lastGPUCommandEnd.map { CFAbsoluteTimeGetCurrent() - $0 < 1.0 } ?? false
            let room = resident ? 0 : budget.poolReservationBytes
            let own = Int((AdmissionCharge.margin * xs.reduce(0.0) { $0 + $1.bytes }).rounded(.up))
            let f = budget.footprint()
            if room > 0, f + room + own > budget.budgetBytes {
                return "ERROR out_of_budget: \(verb) needs \(room + own) bytes (the Metal pool's room, \(room) B, not resident now"
                    + (own > 0 ? ", and its own \(own) B" : "") + "), the budget is \(budget.budgetBytes); nothing written footprint=\(f)"
            }
        }
        guard !xs.isEmpty else { return nil }
        let sum = xs.reduce(0.0) { $0 + $1.bytes }
        return admit(verb, bytes: Self.newBytes(AdmissionCharge.margin * sum),
                     what: xs.map { $0.what }.joined(separator: " + ") + ", 1.1 x the bytes")
    }

    // MARK: - First-use items

    /// The ternary lanes' first allocation, when they are not allocated yet.
    var alloc1dLanesItem: Alloc1dItem? {
        guard engine.ternaryLaneView == nil else { return nil }
        return (AdmissionCharge.ternaryLanes(nodes: nodeCount), "the ternary lanes' first allocation, 11 B per node + 64 KiB for \(nodeCount) nodes")
    }
    /// The rank table's build, when the rank topology changed since it was last built.
    var alloc1dRankTableItem: Alloc1dItem? {
        guard let l = engine.pendingRankTableLevels() else { return nil }
        return (AdmissionCharge.rankTableBuild(nodes: nodeCount, levels: l),
                "the rank table's build, 12.1 B per node + 208.6 B per level + 128 KiB for \(nodeCount) nodes and \(l) levels")
    }
    /// What the first rank-ordered TICK leaves (the rank lists and their Metal state).
    var alloc1dFirstTickItem: Alloc1dItem? {
        engine.rankListsBuilt ? nil
            : (AdmissionCharge.firstTickBuffers(nodes: nodeCount), "the first rank-ordered tick's rank lists, 4.7 B per node + 665 KiB")
    }
    /// The back edges' CPU latch (its snapshot, one byte per edge), when there are back edges.
    var alloc1dCPULatchItem: Alloc1dItem? {
        let m = engine.backEdgeSrcs.count
        return m == 0 ? nil : (AdmissionCharge.cpuLatch(backEdges: m), "the CPU latch's snapshot, 1.01 B per back edge for \(m)")
    }
    /// The GPU latch plan's build and its resident, when a tick may build it (no plan, and the latch can run on the GPU).
    func alloc1dPlanItems(counting: Bool) -> [Alloc1dItem?] {
        let m = engine.backEdgeSrcs.count
        guard m > 0, !engine.hasLatchPlan, counting || m >= DagDBEngine.gpuLatchMinBackEdges else { return [] }
        let d = min(m, nodeCount)
        return [(AdmissionCharge.latchPlanBuild(backEdges: m, nodes: nodeCount), "the latch plan's build, 8 B per back edge + 1 B per node for \(m)"),
                (AdmissionCharge.latchPlanResident(destinations: d), "the latch plan's resident, 21.9 B per destination for up to \(d)")]
    }

    // MARK: - Tick transients and first-use items per verb

    /// Rank-mode TICK (and EVAL, which ticks in rank mode): the rank table, the first tick's lists (rank-ordered TICK
    /// only), the CPU latch, the latch plan.
    func alloc1dAdmitRankTick(_ verb: String, rankLists: Bool, extra: Alloc1dItem? = nil) -> String? {
        alloc1dAdmit(verb, [alloc1dRankTableItem, rankLists ? alloc1dFirstTickItem : nil, alloc1dCPULatchItem, extra]
                     + alloc1dPlanItems(counting: false), gpu: true)
    }
    /// TICK_SYNC: its first-use state, and the CPU latch every tick.
    func alloc1dAdmitTickSync() -> String? {
        alloc1dAdmit("TICK_SYNC", [engine.tickSyncHasRun ? nil
                                    : (AdmissionCharge.firstTickSyncBuffers(nodes: nodeCount), "the first TICK_SYNC's state, 1.0 B per node + 32 KiB"),
                                   alloc1dCPULatchItem], gpu: true)
    }
    /// TICK UNTIL_STABLE: the rank table, the first tick's lists, the frontier's state, the counting session, the plan.
    func alloc1dAdmitUntilStable() -> String? {
        let m = engine.backEdgeSrcs.count, d = min(m, nodeCount)
        return alloc1dAdmit("TICK UNTIL_STABLE", [
            alloc1dRankTableItem, alloc1dFirstTickItem,
            engine.frontierBytesHeld > 0 ? nil
                : { let b = engine.frontierIndexBytesBound()   // the index by its real size
                    return (AdmissionCharge.frontierIndex(bufferBytes: b), "the frontier's index, 1.01 x its \(b) B of buffers + 128 KiB") }(),
            (AdmissionCharge.countingSession(nodes: nodeCount, destinations: d),
             "the counting session, 1 B per node + 11.4 B per destination for up to \(d)"),
        ] + alloc1dPlanItems(counting: true), gpu: true)
    }
    /// SELECT TRUTH ... RANK: the index's (re)build, when it is stale.
    func alloc1dAdmitSelect() -> String? {
        guard truthRankIndex.isDirty else { return nil }
        return alloc1dAdmit("SELECT", [(AdmissionCharge.truthIndexBuild(nodes: nodeCount), "the (truth, rank) index's build, 32.2 B per node + 64 KiB")])
    }
    /// BFS_DEPTHS: its depth array and frontiers.
    func alloc1dAdmitBFSDepths() -> String? {
        alloc1dAdmit("BFS_DEPTHS", [(AdmissionCharge.bfsDepths(nodes: nodeCount), "the depths and frontiers, 56.3 B per node + 64 KiB")])
    }

    // MARK: - Ledger terms (the engine's first-use state and the latch plan, held while they exist)

    /// The committed bytes of the engine's first-use state and of SELECT's index, 1.1 x each.
    static func alloc1dEngineLedger(engine e: DagDBEngine, truthIndexHeld: Bool) -> Double {
        let n = e.nodeCount
        var s = 0.0
        if e.ternaryLaneBytes > 0 { s += AdmissionCharge.ternaryLanes(nodes: n) }
        s += AdmissionCharge.rankTableKept(levels: e.rankTableLevels)
        if e.rankListsBuilt { s += AdmissionCharge.firstTickBuffers(nodes: n) }
        if e.tickSyncHasRun { s += AdmissionCharge.firstTickSyncBuffers(nodes: n) }
        if e.frontierBytesHeld > 0 { s += AdmissionCharge.frontierIndex(bufferBytes: e.frontierBytesHeld) }   // its real size
        s += AdmissionCharge.latchPlanResident(destinations: e.latchPlanDestinations)
        if truthIndexHeld { s += AdmissionCharge.truthIndexKept(nodes: n) }
        return AdmissionCharge.margin * s
    }

    // MARK: - The Metal pool, measured at the first GPU command

    /// The verbs whose engines make command buffers (the primary's and the tile engines'): TICK (and TICK UNTIL_STABLE),
    /// TICK_SYNC, EVAL, SET_LUTS, TILED TICK.
    static let gpuVerbWords: Set<String> = ["TICK", "TICK_SYNC", "EVAL", "SET_LUTS"]

    /// Whether the command is one of those verbs, read from its first two tokens upper-cased as the parser reads them
    /// (not from `verbLabel`, which keeps a second upper-case word and the input's case: "SET_LUTS NODES", "EVAL WHERE",
    /// "tick" were all missed by an exact label match).
    static func isGPUVerb(_ input: String) -> Bool {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }.prefix(2).map { $0.uppercased() }
        guard let first = t.first else { return false }
        return gpuVerbWords.contains(first) || (first == "TILED" && t.count > 1 && t[1] == "TICK")
    }

    /// Before a command: what the pool's measurement needs. Asked for every GPU verb,
    /// not once: each engine's first command buffer (the primary's, a tile engine's) brings its own queue's pool.
    func poolProbeBegin(_ input: String) -> (footprint: Int, ledger: Int, buffers: Int, tableLevels: Int)? {
        guard let b = memoryBudget, Self.isGPUVerb(input) else { return nil }
        return (b.footprint(), committedLedgerBytes(), DagDBEngine.enginesWithCommandBuffers, engine.rankTableLevels)
    }

    /// After it: when it made the engine's first command buffer, the pool is the footprint's rise net of what the
    /// command admitted into the ledger (its first-use state) and, when it built the rank table for the first time, of
    /// the compacted dispatch list's first touch (a buffer of 4 B per node allocated at start, whose pages enter the
    /// footprint only when the table first fills them); a pool above the reservation raises it (logged).
    func poolProbeEnd(_ p: (footprint: Int, ledger: Int, buffers: Int, tableLevels: Int), verb: String) {
        guard let b = memoryBudget, DagDBEngine.enginesWithCommandBuffers > p.buffers else { return }
        poolMeasured = true
        poolMeasurements += 1
        let firstTouch = (p.tableLevels == 0 && engine.rankTableLevels > 0) ? engine.compactedListBytes : 0
        let measured = max(0, b.footprint() - p.footprint - max(0, committedLedgerBytes() - p.ledger) - firstTouch)
        poolMeasuredBytes = measured
        let fresh = DagDBEngine.enginesWithCommandBuffers - p.buffers
        let line = b.raisePoolReservation(measured: measured, verb: fresh > 1 ? "\(verb), \(fresh) engines' first command buffers" : verb)
        daemonLog?(line)
    }

    /// A GPU verb refused by name once a raised reservation no longer fits the budget.
    func gpuVerbRefusal(_ cmd: DSLCommand) -> String? {
        guard let why = memoryBudget?.gpuRefusal else { return nil }
        switch cmd {
        case .tick, .tickSync, .eval, .tickUntilStable, .setLuts, .tiledTick:
            return "ERROR out_of_budget: \(Self.verbLabel(cmdWord(cmd))) refused: \(why); nothing written"
        default:
            return nil
        }
    }
    private func cmdWord(_ cmd: DSLCommand) -> String {
        switch cmd {
        case .tick: return "TICK"
        case .tickSync: return "TICK_SYNC"
        case .eval: return "EVAL"
        case .tickUntilStable: return "TICK UNTIL_STABLE"
        case .setLuts: return "SET_LUTS"
        case .tiledTick: return "TILED TICK"
        default: return "?"
        }
    }

    // MARK: - Every verb that allocates and admitted nothing

    /// The item a read verb (or a writer that admitted nothing) asks before it runs, on `e` (the primary or a reader
    /// session's snapshot engine). nil for a verb with its own admission, or one that allocates nothing measurable.
    func unadmittedVerbItem(_ cmd: DSLCommand, engine e: DagDBEngine, nodeCount n: Int) -> Alloc1dItem? {
        switch cmd {
        case .graphInfo:
            let l = min(n, e.rankShapeWithoutBuilding().highest + 1)
            return (AdmissionCharge.graphInfo(nodes: n, levels: l), "the lanes read and a count per distinct rank, 9.1 B per node + 55.5 B per rank for up to \(l)")
        case .nodes(let rank, _):
            let rows = rank.map { $0 < 0 ? 0 : e.nodesInRankRange(UInt64($0), UInt64($0)) } ?? n
            return (AdmissionCharge.nodesRead(nodes: n, rows: rows), "the lanes read and the rows, 9.1 B per node + 32.1 B per row for up to \(rows)")
        case .traverse(_, let depth):
            let d = Double(max(depth, 0)), bound = 3 * d * (d + 1) + 1
            let v = bound >= Double(n) ? n : Int(bound)
            return (AdmissionCharge.traverse(nodes: n, visited: v), "the lanes read and the visited set, 9.1 B per node + 42.5 B per node visited for up to \(v)")
        case .ancestry:
            return (AdmissionCharge.ancestry(nodes: n), "the backward BFS and its pairs, 16.1 B per node")
        case .similarDecisions:
            return (AdmissionCharge.similarDecisions(nodes: n), "the BFS, sets, histograms and candidates, 69.0 B per node")
        case .distance(let metric, let loA, let hiA, let loB, let hiB) where metric != "spectralL2":
            let m = e.nodesInRankRange(loA, hiA) + e.nodesInRankRange(loB, hiB)
            return (AdmissionCharge.distance(metric: metric, nodes: n, members: m),
                    "the two subgraphs, 11 B per node + \(AdmissionCharge.distancePerMember(metric)) B per member for \(m)")
        case .saveJSON:
            return (AdmissionCharge.saveJSON(nodes: n), "the JSON document, 493 B per node")
        case .saveCSV:
            return (AdmissionCharge.saveCSV(nodes: n), "the CSV text, 87.1 B per node")
        case .backupInit:
            let v8 = e.hasTernaryContent() || n * 42 + n * 42 / 1000 + 1024 > Int(UInt32.max)
            return (AdmissionCharge.saveBody(compressed: true, nodes: n, v8: v8, backEdges: e.backEdgeCount,
                                             libraryBytes: e.ttableCount * TernaryReference.tableSize),
                    "the base, a compressed snapshot's body, 3*\(v8 ? 53 : 42) B per node + its write")
        case .backupAppend:
            return (AdmissionCharge.backupAppend(nodes: n), "the diff's tip, segments and deflate, 419 B per node")
        case .backupCompact:
            return (AdmissionCharge.backupCompact(nodes: n), "the chain's replay and the new base, 329 B per node")
        case .saveTiled:
            return (AdmissionCharge.saveTiled(nodes: n), "the tiles' split and write, 110 B per node + 10.5 MB")
        default:
            return nil
        }
    }

    /// The verb a read verb's refusal names.
    static func readVerbWord(_ cmd: DSLCommand) -> String {
        switch cmd {
        case .graphInfo: return "GRAPH INFO"
        case .nodes: return "NODES"
        case .traverse: return "TRAVERSE"
        case .ancestry: return "ANCESTRY"
        case .similarDecisions: return "SIMILAR_DECISIONS"
        case .distance: return "DISTANCE"
        case .saveJSON: return "SAVE JSON"
        case .saveCSV: return "SAVE CSV"
        case .backupInit: return "BACKUP INIT"
        case .backupAppend: return "BACKUP APPEND"
        case .backupCompact: return "BACKUP COMPACT"
        case .saveTiled: return "SAVE TILED"
        default: return "?"
        }
    }

    /// On the primary: a verb's charge before it runs (EVAL and VALIDATE add theirs to their own admissions).
    func unadmittedVerbRefusal(_ cmd: DSLCommand, _ input: String) -> String? {
        guard memoryBudget != nil, let item = unadmittedVerbItem(cmd, engine: engine, nodeCount: nodeCount) else { return nil }
        return alloc1dAdmit(Self.readVerbWord(cmd), [item])
    }

    /// In a reader session: the same charges as on the primary, on the session's engine: its rank table (VALIDATE),
    /// BFS_DEPTHS, SELECT (which rebuilds its index on every call), and the read verbs above.
    func readerVerbRefusal(_ cmd: DSLCommand, session e: DagDBEngine, nodeCount n: Int) -> String? {
        guard memoryBudget != nil else { return nil }
        var items: [Alloc1dItem?] = []
        switch cmd {
        case .bfsDepths:
            items.append((AdmissionCharge.bfsDepths(nodes: n), "the depths and frontiers, 56.3 B per node + 64 KiB"))
        case .selectByTruthRank:
            items.append((AdmissionCharge.truthIndexBuild(nodes: n), "the session's (truth, rank) index, built on each call, 32.2 B per node + 64 KiB"))
        case .validateGraph:
            if let l = e.pendingRankTableLevels() {
                items.append((AdmissionCharge.rankTableBuild(nodes: n, levels: l), "the session's rank table, 12.1 B per node + 208.6 B per level + 128 KiB for \(l) levels"))
            }
            items.append((AdmissionCharge.validateRead(nodes: n), "the register check, 1 B per node + 256 KiB"))
        default:
            items.append(unadmittedVerbItem(cmd, engine: e, nodeCount: n))
        }
        return alloc1dAdmit("READER", items)
    }

    // MARK: - JSON loader parse

    /// ALARM and KERNEL LOAD's parse, 1.1*(98.4 B per token + 2.52 B per byte), on the bytes read.
    func jsonParseAdmission(_ verb: String, _ d: Data) -> String? {
        guard memoryBudget != nil else { return nil }
        let t = AdmissionCharge.jsonTokens(d)
        return admit(verb, bytes: Self.newBytes(AdmissionCharge.margin * AdmissionCharge.jsonParse(tokens: t, fileBytes: d.count)),
                     what: "the parse, 1.1*(98.4 B per token + 2.52 B per byte) for \(t) tokens (its , : [ { bytes + 1) and \(d.count) B")
    }

    // MARK: - SAVE body and BACKUP RESTORE

    /// SAVE's body transient for the engine as it is (or as a load leaves it: `backEdges`, `tables`).
    func saveBodyItem(compressed: Bool, backEdges: Int? = nil, tables: Int? = nil) -> Alloc1dItem {
        let v8 = engine.hasTernaryContent() || nodeCount * 42 + nodeCount * 42 / 1000 + 1024 > Int(UInt32.max)
        let m = backEdges ?? engine.backEdgeCount, lib = (tables ?? engine.ttableCount) * TernaryReference.tableSize
        let b = AdmissionCharge.saveBody(compressed: compressed, nodes: nodeCount, v8: v8, backEdges: m, libraryBytes: lib)
        let form = compressed ? "the compressed body's gather, deflate and check, 3*\(v8 ? 53 : 42) B per node, and " : ""
        return (b, "the body's write, \(form)the digest's read of at most 8 MiB, 16 B per back edge for \(m) and 320 KiB")
    }

    /// BACKUP RESTORE's scratch engine, tip, base and diffs (`AdmissionCharge.backupRestore`), with its rebase SAVE
    /// when one follows (WAL on, a startup path), admitted together before anything is read.
    func backupRestoreRefusal(_ dir: String) -> String? {
        guard memoryBudget != nil, let inputs = withContainment({ DagDBBackup.restoreInputBytes(dir: dir) }) else { return nil }
        // The LOAD family's floor applies to its charge as to every read inside it.
        let restore = max(AdmissionCharge.backupRestore(nodes: nodeCount, baseBytes: inputs.base, diffBytes: inputs.diffs, diffs: inputs.count),
                          Double(AdmissionCharge.loadFamilyFloorBytes))
        var items: [Alloc1dItem?] = [(restore,
                                      "the restore's scratch engine and tip, 222 B per node, the base's \(inputs.base) B at 3.46 B per byte"
                                          + (inputs.count > 0 ? ", and its \(inputs.count) diffs' \(inputs.diffs) B (the largest \(Reply.quoted(inputs.largest?.name ?? "?")),"
                                             + " \(inputs.largest?.size ?? 0) B), 64 B per node + 2.33 B per byte" : ""))]
        if walAppender != nil, startupSnapshotPath != nil {
            let tokens = twin.exportTokenBound(), strings = twin.exportStringBytes()
            items.append((AdmissionCharge.twinEncode(tokens: tokens, stringBytes: strings), "its rebase SAVE's twin encode for \(tokens) tokens and \(strings) string bytes"))
            items.append(saveBodyItem(compressed: false))
        }
        return alloc1dAdmit("BACKUP RESTORE", items)
    }

    // MARK: - The name cap on the live verbs

    /// A client-given name over `TwinState.nameCap` bytes, refused by name before anything is written.
    func nameCapRefusal(_ verb: String, _ name: String, what: String = "name") -> String? {
        let n = name.utf8.count
        guard n > TwinState.nameCap else { return nil }
        return "ERROR bad_value: \(verb): the \(what) is \(n) bytes, above the \(TwinState.nameCap)-byte cap on names stored in"
            + " twin state; nothing written"
    }
}
