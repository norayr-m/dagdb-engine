/// DagDBCommandHandler — the daemon's DSL command dispatch, extracted from
/// main.swift so it can be tested against a real engine without a socket or
/// mmap'd shared memory. Prod constructs it with the mmap'd
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
    /// Durable snapshots that succeeded (SAVE,
    /// a loader's rebase, the autosave), so `handle` can tell a counter drop
    /// a rebase covered from one it did not (`noteCounterDrop`).
    var durableSnapshotsWritten = 0
    /// Why the sweep after recovery could
    /// not be logged (a version-1 log), or nil.
    var danglingSweepFailure: String? = nil
    /// A loader's failed rebase (the verb and
    /// the base), or nil. See `rebasePendingRefusal`.
    var rebasePending: (verb: String, base: String)? = nil
    /// The era sidecar the boot established
    /// (`DagDBStartup.Result.eraSeal`), whose high-water mark this handler
    /// seals at each durable snapshot and at clean shutdown; nil: no seal.
    public var eraSeal: DagDBStartup.EraSeal? = nil
    /// The snapshot startup recovery loads (`DAGDB_STARTUP_LOAD`),
    /// or nil. With the WAL on, a loader that replaces the engine's state
    /// (LOAD, LOAD JSON, LOAD CSV, BACKUP RESTORE) writes no WAL record, so
    /// after it succeeds the handler takes SAVE's durable snapshot to this
    /// path plus a WAL checkpoint (`rebaseAfterLoad`): recovery then restarts
    /// from the loaded state, not from the snapshot before the load.
    public var startupSnapshotPath: String?
    /// The daemon's own live files the command handler does not see itself
    /// (canonical path -> what): main.swift registers the socket and the --shm-file. The log, its era sidecar and
    /// the sidecar's temporary come from `walAppender`. No writer creates, replaces, truncates or removes one.
    public var daemonFiles: [String: String] = [:]
    let sessionManager: DagDBReaderSessionManager
    let truthRankIndex: TruthRankIndex
    let shmBase: UnsafeMutableRawPointer
    let resultRowSize: Int
    let dataRoot: String?
    let dagdbEnv: String?
    /// Twin-spec DSL state — daemon-global, shared by every
    /// connection (primary path and reader sessions alike). See
    /// DagDBCommandHandler+Twin.swift for the verb dispatcher.
    public let twin: TwinState
    /// Resolved shm capacity in bytes — `shmBytes` if the caller supplied
    /// one (a test fixture sizing its buffer to a control object rather
    /// than to `nodeCount`), else the historical `8 + nodeCount *
    /// resultRowSize` formula. Backs `shmCapacityBytes` in +Twin.swift.
    let configuredShmCapacityBytes: Int
    /// Last FOLD RUN result — daemon-global like every twin
    /// registry, but NOT a twin registry entry: nothing is minted, nothing
    /// is persisted. Not part of snapshots — it is entirely recomputable
    /// from the fabric's neighbor/edge-weight/rank/nodeValue lanes by
    /// running FOLD RUN again.
    public var lastFold: LadderFold.Result?
    /// TILED router registry — daemon-held like `lastFold`, but deliberately NOT a `TwinState`
    /// registry: a router is never persisted, never WAL-logged, and never
    /// part of a snapshot. The tile directory on disk written by `SAVE
    /// TILED` IS the durable state; `TILED OPEN` only rebuilds an
    /// in-memory view of it (reads `manifest.json`, loads nothing yet).
    /// See `DagDBCommandHandler+Tiled.swift`.
    var tiledRouters: [String: TiledRouterEntry] = [:]
    var tiledRouterCounter: UInt32 = 0
    /// `TILED OPEN`s the router refused since the daemon
    /// started (`STATUS tiled_refused=`). A refused open leaves no router,
    /// so no `TILED STATUS` could count it.
    public internal(set) var tiledOpenRefusedCount = 0
    /// Test seam: handed to every router `TILED OPEN` makes,
    /// so a test can fail or stop the open's recovery and completion writes.
    var tiledWriteSeamForTesting: TiledWriteSeam?
    /// The DAG verdict rank-mode TICK checks
    /// (`DagDBSnapshot.rankOrderViolation`), kept between commands that cannot move a
    /// rank or an edge (`keepsDagShape`) and recomputed after any other, so a
    /// run of TICKs pays the O(N) scan once.
    var dagVerdict: (checked: Bool, violation: String?) = (false, nil)
    /// How many times the DAG verdict was computed —
    /// one O(N) rank-order scan each. Read by the tests.
    public internal(set) var dagVerdictCheckCount = 0
    /// Test seam: TRUTH_SLICE runs the older per-node loop instead of the
    /// batched path — two passes over the id range or the whole rank lane, one node at
    /// a time (BYTES: the same loop storing each byte whole). The tests'
    /// reference for the batched path's bytes, and its control. Set by tests, or
    /// by the daemon when started with DAGDB_TRUTH_SLICE_OLD_LOOP_FOR_TESTING=1.
    public var truthSliceOldLoopForTesting = false
    /// Test seam: the path the last TRUTH_SLICE took — "range"
    /// (a NODES range, 8 nodes per step), "rankList" (`RANK r-r` through rank
    /// r's node list, 8 per step), "e2Loop" (the per-node loop: a rank range, a rank
    /// with no list, or the seam above), "" (refused before any read).
    public internal(set) var lastTruthSlicePath = ""

    /// Test seam, kept so older tests compile: it made TICK
    /// UNTIL_STABLE tick through the frontier session. The
    /// frontier session is now the verb's default, so this no longer changes
    /// anything (`untilStablePreFForTesting` selects the old loop).
    public var frontierUntilStableForTesting = false
    /// Test seam: a line per TICK UNTIL_STABLE naming its
    /// session — batches, the CPU's waits on the GPU, the node
    /// slots evaluated, the index and kernel builds, the session's buffers —
    /// in the daemon's log, never the reply. Set by tests, or by the daemon
    /// when started with DAGDB_FRONTIER_FOR_TESTING=1.
    public var frontierTestLog: ((String) -> Void)?
    /// The daemon's memory budget (DaemonMemoryBudget.swift).
    /// The daemon sets it at start; nil (an in-process host) means no memory
    /// budget and no STATUS token. The work caps apply either way.
    public var memoryBudget: DaemonMemoryBudget?
    /// The Metal pool, measured once at the first GPU command (`poolProbeEnd`).
    public internal(set) var poolMeasured = false
    public internal(set) var poolMeasuredBytes: Int? = nil
    /// How many first command buffers' pools were measured; and when this process's queues last
    /// made a command buffer (the pool is taken as resident for a second after).
    public internal(set) var poolMeasurements = 0
    var lastGPUCommandEnd: Double? = nil
    /// Where the daemon's log lines go (main.swift sets it); nil in process.
    public var daemonLog: ((String) -> Void)? = nil
    /// Test seam: TICK UNTIL_STABLE runs the loop from before the frontier
    /// session instead — the counting session, one tick per command buffer,
    /// `nodes_computed=` counting every node per tick. The in-process tests'
    /// reference (with the engine's `latchOnGPU = false`, the CPU counting latch).
    public var untilStablePreFForTesting = false
    /// Test seam: ticks per command buffer (≥ 1) instead of
    /// `untilStableBatchTicks` — the batching control forces 1. Set by tests,
    /// or by the daemon from DAGDB_FRONTIER_BATCH_FOR_TESTING.
    public var untilStableBatchForTesting: Int?
    /// k, the ticks TICK UNTIL_STABLE encodes per command buffer
    /// (each batch: min(k, MAX − ticks run)). Measured with 17 chained indirect
    /// dispatches: 0.195 / 0.0835 / 0.0593 ms per tick for k = 1 / 4 / 16.
    ///
    /// k is the ramp's ceiling — the batches of
    /// one call grow 1, 2, 4, 8, 16, 16, …, each also min(·, MAX − ticks run)
    /// and under the engine's dispatch cap.
    public static let untilStableBatchTicks = 16
    /// What the last TICK UNTIL_STABLE did — the CPU's
    /// waits on the GPU, the command buffers (batches), the node slots its
    /// ticks evaluated (its `nodes_computed=`). Read by the tests.
    public internal(set) var lastUntilStableGPUWaits = 0
    public internal(set) var lastUntilStableBatches = 0
    public internal(set) var lastUntilStableEvaluated = 0
    /// The last TICK UNTIL_STABLE's ticks encoded
    /// into command buffers, the most ticks one buffer held, the most
    /// dispatches a buffer of two or more ticks held; whether its session ran
    /// on the frontier (false past the depth guard, and in the pre-frontier loop); the
    /// non-empty rank levels the guard counted. Read by the tests.
    public internal(set) var lastUntilStableTicksEncoded = 0
    public internal(set) var lastUntilStableMaxBufferTicks = 0
    public internal(set) var lastUntilStableMaxMultiTickBufferDispatches = 0
    public internal(set) var lastUntilStableFrontier = false
    public internal(set) var lastUntilStableRankLevels = 0

    /// The reply of a tick verb whose tick `tick`
    /// (1-based; of `of` asked) found its command buffer not completed: the
    /// status by name, nothing claimed, the tick total (which counts only the
    /// ticks whose buffers completed).
    func gpuFailureReply(_ verb: String, _ f: DagDBEngine.CommandBufferFailure, tick: Int, of n: Int?) -> String {
        "ERROR gpu: \(verb): \(Reply.errorWords(f)) at tick \(tick)\(n.map { " of \($0)" } ?? ""); nothing claimed, "
            + "the truth bytes may hold part of that command buffer's writes; total=\(tickCount)"
    }

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
        shmBytes: Int? = nil,
        startupSnapshotPath: String? = nil
    ) {
        self.engine = engine
        self.grid = grid
        self.nodeCount = nodeCount
        self.width = width
        self.height = height
        self.maxRank = maxRank
        self.tickCount = tickCount
        self.walAppender = walAppender
        self.startupSnapshotPath = startupSnapshotPath
        self.sessionManager = sessionManager
        self.truthRankIndex = truthRankIndex
        self.shmBase = shmBase
        self.resultRowSize = resultRowSize
        self.dataRoot = dataRoot
        self.dagdbEnv = dagdbEnv
        self.twin = twin
        var shmCap = shmBytes ?? (8 + nodeCount * resultRowSize)
        #if DEBUG || DAGDB_FAULT_INJECTION
        // Fault-injection seam: a smaller result file than the daemon maps.
        if let v = DagDBFaultInjection.value("SHM_CAP"), let c = Int(v), c >= 8, c < shmCap { shmCap = c }
        #endif
        self.configuredShmCapacityBytes = shmCap
        self.lastFold = nil
    }

    func guardPath(_ p: String) -> String? {
        // Reject traversal segments before any canonicalization.
        for seg in p.split(separator: "/", omittingEmptySubsequences: false) {
            if seg == ".." { return "ERROR io: path: traversal segment '..' rejected" }
        }
        guard dataRoot != nil else { return nil }
        // The path's deepest EXISTING ancestor resolved by realpath (a name not yet created
        // under a linked directory resolves through the link: without this, `SAVE root/lnk/x.dags` wrote outside
        // the root), a linked last component resolved too; the root resolved the same way. The words are
        // main's. Every open under the verb is then contained again by its own descriptor (`DaemonFile`).
        if !(p as NSString).standardizingPath.hasPrefix("/") { return "ERROR io: path: \(Reply.quoted(p)) outside DAGDB_DATA_ROOT" }
        let check = withContainment { DaemonFile.containmentRefusal(p) }
        switch check {
        case nil: return nil
        case .outsideRoot?: return "ERROR io: path: \(Reply.quoted(p)) outside DAGDB_DATA_ROOT"
        case let r?: return "ERROR io: path: " + Reply.errorWords(r)
        }
    }

    /// Backup replies for a failed call. The refusals the format contract
    /// names — a format-1 chain, a segment of the wrong length, a gap or a
    /// duplicate in the diff sequence, an occupied APPEND slot, a diff that
    /// fails its sidecar — come back as their own sentence, not a wrapped
    /// error string, because the operator's next move is in that sentence.
    /// Everything else keeps the old `verb: error` shape.
    func backupErrorReply(_ error: Error, verb: String) -> String {
        if let be = error as? DagDBBackup.BackupError, be.isNamedRefusal {
            return "ERROR \(Reply.errorWords(be))"
        }
        return Reply.errorLine("io", verb: verb, error)
    }

    // MARK: - Every wire integer bounded on BOTH sides

    /// Caps for the counts that drive loops on the single-threaded accept
    /// loop.
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
    /// guess which side it fell off (the old
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

    // MARK: - Wire arithmetic cannot trap

    /// Sums and products of wire integers, computed with overflow-reporting
    /// operations. Swift TRAPS on `Int` overflow, so a byte count built from
    /// unbounded wire values used to kill the daemon BEFORE the capacity
    /// guard that existed to refuse it could run.
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
    /// NAME rather than trapping on the `+= 1`.
    func checkTickHeadroom(_ count: Int) -> String? {
        let projected = UInt64(tickCount) + UInt64(count)
        guard projected > UInt64(UInt32.max) else { return nil }
        return "ERROR out_of_range: tick total \(tickCount)+\(count) not in 0...\(UInt32.max)"
            + " — tickCount is a 32-bit field in the snapshot header; SAVE and restart to reset it"
    }

    /// Write a snapshot bound to its WAL position, then a WAL checkpoint.
    /// Used by the `SAVE` verb (after `guardPath`), by the daemon's autosave
    /// on graceful shutdown, and by a loader's rebase (`rebaseAfterLoad`)
    /// — the three callers. Twin records such as `RECORD SLICE`,
    /// `RINGS WRITE`, `CLOCK ADVANCE` and the relative G records (`SET_LUTS
    /// … MAP`, a RANK selection, `SET_TRUTH RANK … FILL`) are not idempotent,
    /// so recovery must replay exactly the records the snapshot does not
    /// contain.
    ///
    /// The order, each step a boundary
    /// (`DurableSnapshotStep`): the tmp file written and fsynced and its
    /// digest taken; the WAL's SNAPSHOT_BIND record (that digest) appended
    /// and fsynced; the old manifest removed and the rename; the manifest;
    /// the checkpoint appended, then fsynced. Recovery replays from the last
    /// bind record carrying the loaded snapshot's digest, so a kill between
    /// the rename and the checkpoint no longer replays the records before
    /// the snapshot onto it; before the rename the old snapshot keeps its
    /// own bind record (or checkpoint). A bind record that cannot be
    /// appended refuses the SAVE before the rename (`ERROR wal:`; nothing
    /// renamed). A checkpoint that cannot be appended is named in the reply
    /// (` WARN wal: checkpoint not written (…)`), no longer swallowed: the
    /// snapshot is durable and bound, so recovery is unaffected. With no WAL,
    /// neither record is written, as before.
    /// The first non-finite edge weight or node
    /// value the engine holds, named, or nil. Every write verb checks it
    /// before it writes anything.
    func nonFiniteLaneRefusal() -> String? {
        DagDBSnapshot.finiteLaneRefusal(engine: engine, nodeCount: nodeCount)
    }

    /// The step boundaries of `durableSnapshot`, in order.
    public enum DurableSnapshotStep: String, CaseIterable, Sendable {
        /// The refusals passed; nothing written.
        case beforeWrite
        /// `<path>.tmp` written, fsynced, hashed; `<path>` and the WAL untouched.
        case tmpWritten
        /// The bind record appended and fsynced; `<path>` still the old file.
        case bindAppended
        /// The rename done (the old manifest removed first); no manifest yet.
        case renamed
        /// The manifest written; no checkpoint yet.
        case manifestWritten
        /// The checkpoint written to the log, not yet fsynced.
        case checkpointAppended
        /// The checkpoint fsynced; the reply not yet returned.
        case checkpointSynced
    }

    /// Test seam: asked at every step boundary; `true`
    /// abandons the snapshot there and writes nothing more (the in-process
    /// kill), and the reply is `ERROR test: durable snapshot stopped at
    /// <step>`. nil (always, outside a test): no effect.
    var durableSnapshotStopForTesting: ((DurableSnapshotStep) -> Bool)?
    /// Test seam: the checkpoint append throws this
    /// instead of writing. nil (always, outside a test): no effect.
    var checkpointAppendFailureForTesting: Error?

    private struct DurableSnapshotStopped: Error { let step: DurableSnapshotStep }
    // A wrapper that holds an Error carries the line that error carries.
    private struct SnapshotBindFailed: Error, Reply.CarriesLine { let underlying: Error; var replyLine: String? { Reply.carriedLine(underlying) } }
    private struct SnapshotBindSyncFailed: Error, Reply.CarriesLine { let underlying: Error; var replyLine: String? { Reply.carriedLine(underlying) } }

    /// The admission a file loader asks on the bytes it will hold (the opened file's true
    /// size), 1.1 x those bytes; nil with no memory budget.
    func fileAdmission(_ verb: String) -> ((Int, String) -> String?)? {
        guard memoryBudget != nil else { return nil }
        let a: (Int, String) -> String? = { [unowned self] bytes, what in
            self.admit(verb, bytes: Self.newBytes(Self.alloc1bMargin * Double(bytes)), what: "\(what), 1.1 x the bytes")
        }
        // Every charge of the LOAD family is at least 1.1 x its floor (the empty LOAD's peak).
        return Self.loadFamilyVerbs.contains(verb) ? AdmissionCharge.loadFamilyFloored(a) : a
    }
    /// The verbs whose charges take the LOAD family's floor (`verbLabel`'s words).
    static let loadFamilyVerbs: Set<String> = ["LOAD", "LOAD JSON", "LOAD CSV", "BACKUP RESTORE"]
    func fileAdmission1(_ verb: String) -> ((Int) -> String?)? {
        guard let a = fileAdmission(verb) else { return nil }
        return { a($0, "the file's \($0) B, read once") }
    }

    public func durableSnapshot(path: String, compressed: Bool = false) -> String {
        // Forced barrier: flush any deferred WAL tail so the snapshot
        // is taken over a fully-durable log (a crash mid-snapshot then
        // recovers via WAL replay with no group-commit loss window).
        walAppender?.barrier()
        // A non-finite weight or value is never
        // written — every load path would refuse the file.
        if let why = nonFiniteLaneRefusal() {
            return "ERROR io: save: \(DagDBSnapshot.SnapError.validationFailed(why))"
        }
        // A record replayed from a log older
        // than this build whose header HEADER CHECK refuses (JSON cannot encode a
        // nan) is named, with the way out, before anything is written.
        let poisoned = twin.recordsWithNonFiniteHeaders
        if !poisoned.isEmpty {
            return "ERROR bad_value: save: RECORD \(poisoned.joined(separator: ", ")) carries a header HEADER CHECK refuses"
                + " (replayed from a log older than this build); SAVE refuses until "
                + poisoned.map { "RECORD CLOSE \($0)" }.joined(separator: ", ") + ", then SAVE; nothing written"
        }
        // SAVE refuses what LOAD refuses, in LOAD's words,
        // and writes nothing (no file, no checkpoint). Under the slot
        // model, LOAD's slot rule is the persistence rule — a source out of
        // range refused; S1–S3 (a duplicate source, a slot self-loop, a rank
        // inversion) are store shapes, saved and loaded back.
        if let why = DagDBSnapshot.persistenceViolation(engine: engine, nodeCount: nodeCount) {
            return "ERROR io: save: \(DagDBSnapshot.SnapError.validationFailed(why))"
        }
        // LOAD refuses a back edge CONNECT BACK refuses, so SAVE
        // does: the live list against the live lanes, by entry, in
        // CONNECT BACK's words; without this a SAVE, an autosave or a
        // loader's rebase would write a startup snapshot recovery then
        // refuses. No verb installs S4 (a slot into a
        // register) any more; an older log can replay one, and the
        // refusal names the way out.
        if let r = engine.liveBackEdgeRefusal(list: "back edge") {
            return backEdgeLoadRefusal("SAVE", r, nothing: "written") + slotIntoRegisterWayOut(r)
        }
        // The twin section's encode (the JSONEncoder tree, its bytes and their copy into the
        // section) admitted before anything is written, at 1.1 x (79.0 B per token + 2.95 B per escaped string byte),
        // the tokens and the string bytes counted from the registries
        // (`TwinState.exportTokenBound`, `exportStringBytes`). The body is written from the live buffers.
        // The body's transient (`AdmissionCharge.saveBody`), plain and compressed apart, in the
        // same admission.
        if memoryBudget != nil {
            let tokens = twin.exportTokenBound(), strings = twin.exportStringBytes()
            let body = saveBodyItem(compressed: compressed)
            if let e = admit("SAVE", bytes: Self.newBytes(AdmissionCharge.margin * (AdmissionCharge.twinEncode(tokens: tokens, stringBytes: strings) + body.bytes)),
                             what: "the twin section's encode, 1.1*(\(AdmissionCharge.twinEncodePerToken) B per token +"
                                 + " \(AdmissionCharge.twinEncodePerStringByte) B per escaped string byte) for \(tokens) tokens and"
                                 + " \(strings) string bytes, counted from the registries, and \(body.what)") { return e }
        }
        let stopHook = durableSnapshotStopForTesting
        func stop(_ s: DurableSnapshotStep) -> Bool { stopHook?(s) ?? false }
        func stopped(_ s: DurableSnapshotStep) -> String { "ERROR test: durable snapshot stopped at \(s.rawValue)" }
        if stop(.beforeWrite) { return stopped(.beforeWrite) }
        let wal = walAppender
        let epoch = UInt64(tickCount)
        // Set once the bind record is in the log, so
        // a SAVE that fails after it (the rename) names the record it leaves.
        var bindAppended = false
        // The bind record, after the tmp file's fsync and before
        // the rename; fsynced before the rename.
        let bind: (([UInt8]) throws -> Void)? = wal.map { w in
            { digest in
                do {
                    try w.snapshotBind(epoch: epoch, digest: digest)
                } catch {
                    throw SnapshotBindFailed(underlying: error)
                }
                bindAppended = true
                // The bind record durable before the rename, or the SAVE refuses (a failed sync
                // poisons the log).
                do { try w.barrierChecked() } catch { throw SnapshotBindSyncFailed(underlying: error) }
                if stop(.bindAppended) { throw DurableSnapshotStopped(step: .bindAppended) }
            }
        }
        // A manifest the save could not write is named in the reply.
        var manifestWarn = ""
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
                twin: twin,
                beforeRename: bind,
                stepHook: stopHook == nil ? nil : { step in
                    let s: DurableSnapshotStep
                    switch step {
                    case .tmpWritten: s = .tmpWritten
                    case .oldManifestRemoved: return     // the tiled save's boundary; this save has no step there
                    case .renamed: s = .renamed
                    case .manifestWritten: s = .manifestWritten
                    }
                    if stop(s) { throw DurableSnapshotStopped(step: s) }
                },
                manifestUnwritten: { mp, e in
                    manifestWarn = " WARN manifest: \(Reply.quoted(mp)) was not written (\(Reply.errorWords(e))); a LOAD of this"
                        + " snapshot is unverified (no manifest) until a SAVE writes one"
                }
            )
            // The checkpoint: skips the records the file holds for a reader
            // that has no bind record to go by (an older build). A failure is
            // named in the reply, never swallowed.
            var warn = ""
            if let w = wal {
                do {
                    if let e = checkpointAppendFailureForTesting { throw e }
                    try w.checkpoint(epoch: epoch, sync: false)
                    if stop(.checkpointAppended) { return stopped(.checkpointAppended) }
                    w.barrier()
                    if stop(.checkpointSynced) { return stopped(.checkpointSynced) }
                } catch {
                    warn = " WARN wal: checkpoint not written (\(Reply.errorWords(error))); recovery starts after this snapshot's bind record"
                }
            }
            let ratio = compressed
                ? String(format: " ratio=%.1f%%", Double(r.bytesWritten) * 100.0 / Double(32 + r.uncompressedBodyBytes))
                : ""
            durableSnapshotsWritten += 1
            // The era sidecar's high-water mark,
            // sealed at each durable snapshot (a failure only makes a later
            // boot's naming more conservative, and is named).
            let eraWarn = sealEraMark().map { " WARN era: the sidecar's mark was not sealed (\($0)); a later boot names this build's ticks since its last seal \"may have\"" } ?? ""
            // A durable snapshot to the base makes
            // the live state the durable base again.
            if let held = rebasePending,
               (path as NSString).standardizingPath == (held.base as NSString).standardizingPath { rebasePending = nil }
            return "OK SAVE bytes=\(r.bytesWritten) elapsed=\(String(format: "%.1f", r.elapsedMs))ms\(ratio) path=\(Reply.quoted(path))\(compressed ? " (compressed)" : "")\(manifestWarn)\(warn)\(eraWarn)"
        } catch let s as DurableSnapshotStopped {
            return stopped(s.step)
        } catch let b as SnapshotBindFailed {
            if let l = b.replyLine { return l }
            return "ERROR wal: SAVE refused: the snapshot's WAL bind record could not be appended (\(Reply.errorWords(b.underlying))); nothing renamed, \(Reply.quoted(path)) unchanged"
        } catch let b as SnapshotBindSyncFailed {
            if let l = b.replyLine { return l }
            return "ERROR wal: SAVE refused: the snapshot's WAL bind record (epoch \(epoch)) was appended but its sync failed"
                + " (\(Reply.errorWords(b.underlying))); it stays in the log (recovery passes over a bind record whose digest no snapshot file"
                + " carries); nothing renamed, \(Reply.quoted(path)) unchanged"
        } catch {
            // The bind record is a log
            // write that cannot be taken back, so the reply names it.
            if bindAppended {
                return "ERROR io: save: \(Reply.errorWords(error)); WAL: this snapshot's SNAPSHOT_BIND record (epoch \(epoch)) was appended"
                    + " before the failed rename and stays in the log (recovery passes over a bind record whose digest"
                    + " no snapshot file carries); \(Reply.quoted(path)) unchanged"
            }
            return Reply.errorLine("io", verb: "save", error)
        }
    }

    /// A loader that replaced the engine's
    /// state wholesale and wrote no WAL record (LOAD, LOAD JSON, LOAD CSV,
    /// BACKUP RESTORE) moves recovery's base to the loaded state. Recovery is
    /// the startup snapshot plus the records past the last checkpoint; without
    /// this, a restart rebuilt on the snapshot from before the load, and the
    /// relative records after it (SET_LUTS MAP, a RANK selection, SET_TRUTH
    /// RANK FILL) landed on the wrong base. With the WAL on and a startup
    /// snapshot path set, the loader ends with SAVE's own durable snapshot to
    /// that path and a checkpoint (`durableSnapshot`), and the reply says
    /// `wal_base=<path>`. With the WAL off, or with no startup path (a restart
    /// then replays the log over an empty engine, which never recovered a SAVE
    /// or a TICK either), the reply is unchanged. A snapshot that fails after
    /// the load is named: the state is loaded and the base is not moved.
    /// A loader whose rebase SAVE (`rebaseAfterLoad`, WAL on with a startup
    /// path) its own admission would refuse is refused BEFORE anything is loaded, so a budget refusal never lands in
    /// the rebase-pending hold, which stays for the I/O failures it was built for. The SAVE's charge is SAVE's own
    /// (1.1 x (79.0 B per token + 2.95 B per escaped string byte)) of the twin state the load leaves (`twin`), against the footprint now (it holds what the rebase
    /// will: the old state is still here) and against the committed bytes of the state the load leaves (its twin
    /// registries, `backEdges` at exact capacity, `tables` of library). nil: no rebase follows, no budget, or it fits.
    func rebaseSaveRefusal(_ verb: String, twin staged: TwinState, backEdges: Int, tables: Int) -> String? {
        guard let budget = memoryBudget, walAppender != nil, let base = startupSnapshotPath else { return nil }
        let tokens = staged.exportTokenBound(), strings = staged.exportStringBytes()
        let body = saveBodyItem(compressed: false, backEdges: backEdges, tables: tables)
        let charge = Self.newBytes(AdmissionCharge.margin * (AdmissionCharge.twinEncode(tokens: tokens, stringBytes: strings) + body.bytes))
        let what = "its rebase SAVE to \(Reply.quoted(base)), admitted with the load before anything is loaded: the twin"
            + " section's encode, 1.1*(\(AdmissionCharge.twinEncodePerToken) B per token + \(AdmissionCharge.twinEncodePerStringByte)"
            + " B per escaped string byte) for \(tokens) tokens and \(strings) string bytes of the state it leaves, and \(body.what)"
        let f = budget.footprint()
        if AdmitCount(f) + charge > AdmitCount(budget.budgetBytes) {
            return "ERROR out_of_budget: \(verb) needs \(charge) bytes (\(what)), the budget is \(budget.budgetBytes); nothing written footprint=\(f)"
        }
        let ledger = Self.ledgerBytes(twin: staged, engine: engine, sessions: sessionManager.openSessions,
                                      routerBytes: tiledRouters.sorted(by: { $0.key < $1.key }).map { $0.value.admittedBytes },
                                      backEdgeSlots: backEdges, libraryCapacity: tables)
        let committed = AdmitCount(budget.fixedStateBytes) + AdmitCount(ledger)
        if committed + charge > AdmitCount(budget.budgetBytes) {
            return "ERROR out_of_budget: \(verb) needs \(charge) bytes (\(what)), the budget is \(budget.budgetBytes)"
                + " (committed \(committed) after the load: fixed state \(budget.fixedStateBytes) + ledger \(ledger)); nothing written footprint=\(f)"
        }
        return nil
    }

    func rebaseAfterLoad(_ verb: String, _ reply: String) -> String {
        guard walAppender != nil, let base = startupSnapshotPath else { return reply }
        let saved = durableSnapshot(path: base)
        guard saved.hasPrefix("OK SAVE") else {
            // Hold until the base is written.
            rebasePending = (verb, base)
            return "ERROR wal: \(verb) loaded the state, but its durable snapshot to \(base) failed (\(saved)); "
                + "a restart would recover the state from before \(verb); SAVE \(base) once it can be written"
                + " (until then every write is refused)"
        }
        rebasePending = nil
        // A checkpoint the snapshot could not write is named here
        // too (the base moved: the snapshot is durable and bound).
        let warn = saved.range(of: " WARN wal: ").map { String(saved[$0.lowerBound...]) } ?? ""
        return reply + " wal_base=\(Reply.quoted(base))" + warn                 // quoted like every echo
    }

    // MARK: - Command dispatch

    /// The operation says how much it did.
    ///
    /// `nodes_computed` is the total node-evaluations the command
    /// dispatched: the per-tick node slots times the tick count. It is
    /// printed always. When the rank levels actually dispatched exceed the
    /// configured bound, the reply also carries `ranks=` and `bound=`, so
    /// a graph restored under a smaller bound announces itself on the wire
    /// at the first tick rather than scrolling past in a log. (STATUS
    /// carries the same news without ticking; VALIDATE names the nodes.)
    func rankWorkSuffix(nodesComputed: Int, rankDispatched: Bool) -> String {
        // Read without building the rank table (TICK_SYNC never dispatches by it).
        let shape = engine.rankShapeWithoutBuilding()
        var s = " nodes_computed=\(nodesComputed)"
        if shape.levels > maxRank {
            // Rank mode reports the levels it dispatched. Sync mode does not
            // dispatch by rank at all, so `ranks=` would imply a bounded
            // dispatch that did not happen; it reports the same news as a
            // fact about the GRAPH instead, in STATUS's vocabulary.
            s += rankDispatched
                ? " ranks=\(shape.levels) bound=\(maxRank)"
                : " rank_max=\(shape.highest) bound=\(maxRank)"
        }
        return s
    }

    /// Commands that cannot change a rank or a
    /// combinational edge, so the cached DAG verdict survives them. Every
    /// command not named here (any writer, any loader, anything new) drops it.
    static func keepsDagShape(_ cmd: DSLCommand) -> Bool {
        switch cmd {
        case .status, .tick, .tickSync, .eval, .nodes, .traverse, .setTruth, .setWeight, .setValue,
             .setLUT, .connectBack, .clearBackEdges, .getTruth, .graphInfo, .save, .exportMorton,
             .validateGraph, .saveJSON, .saveCSV, .setLutsBulk, .selectByTruthRank, .composeLUT,
             .setMode, .setTTableId, .setThresh, .setTrit, .getTrit, .ttableDefine, .ttablePreset,
             .ttableGet, .setModesBulk, .setTTableIdsBulk, .setThreshBulk, .ttableBulk,
             .connectBackBulk, .setTruthBulk, .truthSlice, .tickUntilStable,
             .setLuts,                                                         // a LUT write
             .setTruthFill,                                                    // a truth write
             .dslParse:                                                        // runs nothing
            return true
        default:
            return false
        }
    }

    /// Why rank-mode TICK must not run on this graph — an
    /// edge rank mode cannot order (a self-loop, or a source not strictly
    /// above its destination in rank: the DAG property), in LOAD's words — or
    /// nil. (`DagDBSnapshot.rankOrderViolation` says why range and duplicate
    /// slots are left to the kernel.)
    func rankTickDagRefusal() -> String? {
        if !dagVerdict.checked {
            dagVerdict = (true, DagDBSnapshot.rankOrderViolation(engine: engine, nodeCount: nodeCount))
            dagVerdictCheckCount += 1
        }
        return dagVerdict.violation
    }

    /// The per-rank lists a rank-ordered TICK dispatches
    /// from could not be allocated — the TICK is refused by name, nothing
    /// ticked, instead of a fatalError. nil when they are ready.
    func rankListRefusal() -> String? {
        do { try engine.prepareRankLists(); return nil }
        catch { return "ERROR resource: rank-mode TICK refused: \(Reply.errorWords(error)); nothing ticked" }
    }

    /// Commands that cannot move a slot, a rank, a
    /// back edge, a register flag or the node count, so the engine's
    /// frontier index (the reverse index of slots and back edges) survives
    /// them: every command `keepsDagShape` keeps — its back-edge writers
    /// included, because a change to the back-edge lists drops the index in
    /// the engine itself (`backEdgeListsChanged`) — and the verbs that only
    /// read the primary engine or touch other state (BFS and the other graph
    /// reads, reader sessions, backup chains but RESTORE, tiled routers, twin
    /// registries). Every other command — the slot and rank writers, every
    /// loader, anything new — drops it.
    static func keepsFrontierIndex(_ cmd: DSLCommand) -> Bool {
        if keepsDagShape(cmd) { return true }
        switch cmd {
        case .bfsDepths, .ancestry, .distance, .similarDecisions,
             .openReader, .closeReader, .listReaders, .reader,
             .backupInit, .backupAppend, .backupCompact, .backupInfo,
             .saveTiled, .tiledOpen, .tiledBFS, .tiledSelect, .tiledStatus, .tiledList, .tiledClose,
             .tiledTick, .tiledGetTruth, .twin, .unknown:
            return true
        default:
            return false
        }
    }

    /// One autorelease pool per command. Objects Foundation and
    /// Metal autorelease while a command runs (JSONSerialization's trees, a
    /// tick's compute encoder, a reader session's command buffers, NSString
    /// bridges) are released when the command returns. Without it no pool
    /// would ever be drained in the daemon, so each would be kept for the process's life.
    public func handle(_ input: String) -> String {
        // A command holding a control character (tab aside) is refused by name before
        // parsing; nothing runs and nothing changes. (The socket server refuses it on the raw bytes first.)
        if let refusal = Reply.inputRefusal(input) { return refusal }
        // Every file the command opens, however deep, is contained in this handler's data root,
        // and the reads that had only a size bound are admitted against this command's budget.
        let label = Self.verbLabel(input)
        let probe = poolProbeBegin(input)
        let buffers0 = DagDBEngine.processCommandBuffers
        let reply = DaemonFile.$admission.withValue(fileAdmission(label)) {
            withContainment { autoreleasepool { handleInPool(input) } }
        }
        if DagDBEngine.processCommandBuffers != buffers0 { lastGPUCommandEnd = CFAbsoluteTimeGetCurrent() }
        if let p = probe { poolProbeEnd(p, verb: label) }
        // The one formatter, applied once here (in-process callers get it too) and
        // asserted again by the socket writer: the volatile tail, the escapes, the cap.
        return Reply.line(reply)
    }

    /// `body` with the handler's canonical data root bound (`DaemonFile.root`), so every
    /// open under it, a tile load or a twin restore included, is contained; nil root: unguarded.
    /// The daemon's live files (`reservedFiles`) are bound too, and no writer under it touches them.
    public func withContainment<R>(_ body: () throws -> R) rethrows -> R {
        try DaemonFile.$reserved.withValue(reservedFiles) { try DaemonFile.withRoot(dataRoot, body) }
    }

    /// The live files no writer may target (canonical path -> what it is).
    public var reservedFiles: [String: String] {
        var m = daemonFiles
        if let w = walAppender {
            m[w.openPath] = "the daemon's live write-ahead log (DAGDB_WAL)"
            m[w.openPath + DagDBHOOK1Era.suffix] = "the live write-ahead log's era sidecar"
            m[w.openPath + DagDBHOOK1Era.suffix + ".tmp"] = "the live write-ahead log's era sidecar temporary"
        }
        return m
    }

    /// The verb an admission refusal names: the first word, and the second when it is a word too (TILED TICK,
    /// BACKUP RESTORE, SAVE CSV), never a path.
    static func verbLabel(_ input: String) -> String {
        let t = input.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard let first = t.first else { return "?" }
        if t.count > 1, t[1].allSatisfy({ $0.isUppercase || $0 == "_" }) { return "\(first) \(t[1])" }
        return String(first)
    }

    /// A write target that is the daemon's own write-ahead log or its era sidecar, refused by
    /// name (without this, SAVE to DAGDB_WAL's path would replace the log with a snapshot).
    public func walTargetRefusal(_ verb: String, _ path: String) -> String? {
        guard let w = walAppender, let target = try? DaemonFile.forWrite(path) else { return nil }
        let wal = w.openPath
        if target == wal || target == wal + DagDBHOOK1Era.suffix || target == wal + DagDBHOOK1Era.suffix + ".tmp" {
            return "ERROR io: \(verb): \(Reply.quoted(path)) is the daemon's write-ahead log (DAGDB_WAL) or its era sidecar; refused, nothing written"
        }
        return nil
    }

    private func handleInPool(_ input: String) -> String {
        let cmd = DSLParser.parse(input)
        // After a failed rebase, before any change.
        if let e = rebasePendingRefusal(cmd) { return e }
        if let e = gpuVerbRefusal(cmd) { return e }
        if let e = unadmittedVerbRefusal(cmd, input) { return e }
        if !Self.keepsDagShape(cmd) { dagVerdict.checked = false }
        if !Self.keepsFrontierIndex(cmd) { engine.dropFrontierIndex() }

        // A tick-family command that ran leaves one TICK_NOTE;
        // any other command that moved the counter (up or
        // down) with no successful durable rebase leaves one COUNTER_DROP.
        let before = tickCount, snapshotsBefore = durableSnapshotsWritten
        switch cmd {
        case .tick, .tickSync, .eval, .tickUntilStable:
            return noteTicks(dispatch(cmd, input), before: before)
        default:
            return noteCounterDrop(dispatch(cmd, input), before: before, snapshotsBefore: snapshotsBefore)
        }
    }

    private func dispatch(_ cmd: DSLCommand, _ input: String) -> String {
        switch cmd {
        case .status:
            // `ranks=` and `rank_max=` sit beside the configured bound so a
            // health check can compare two printed numbers and catch a stale
            // bound WITHOUT ticking. Every field STATUS
            // printed before is still printed, in the same relative order.
            // STATUS never allocates. The two numbers are read from the rank lane with one pass and no
            // allocation; the rank table is built (and admitted) only by the verbs that dispatch by it.
            let shape = engine.rankShapeWithoutBuilding()
            return "OK STATUS nodes=\(nodeCount) ticks=\(tickCount) gpu=\(engine.device.name) grid=\(width)x\(height) maxRank=\(maxRank) ranks=\(shape.levels) rank_max=\(shape.highest) twin_open=\(twin.totalOpen) tiled_open=\(tiledRouters.count) tiled_refused=\(tiledOpenRefusedCount)"
                + " client_protocol=\(Self.clientProtocol)" + memBudgetStatusToken
                + (rebasePending.map { " rebase_pending=\($0.base)" } ?? "")

        case .tick(let count):
            if let e = checkCap("count", count, 0, Self.tickCap) { return e }
            if let e = checkTickHeadroom(count) { return e }
            // Rank mode is defined on a DAG only; on a graph
            // LOAD would refuse it ran silently. TICK_SYNC is unaffected.
            if let why = rankTickDagRefusal() {
                return "ERROR invalid_graph: rank-mode TICK refused, validation: \(why) "
                    + "(VALIDATE names it; TICK_SYNC is defined on this graph)"
            }
            if let e = alloc1dAdmitRankTick("TICK", rankLists: true) { return e }
            if let e = rankListRefusal() { return e }
            engine.ensureRankTopology()                                    // L, the non-empty levels
            if let e = admitTickWork("TICK", count: count, levels: engine.nonEmptyRankLevels, latch: .rank) { return e }
            let t0 = CFAbsoluteTimeGetCurrent()
            engine.clearGPUFailure()
            for i in 0..<count {
                // The refusal above found no edge rank mode cannot
                // order, so the per-rank contiguous dispatch is exact here.
                engine.tick(tickNumber: tickCount, rankOrderVerified: true)
                if let f = engine.gpuFailure {
                    truthRankIndex.markDirty()
                    return gpuFailureReply("TICK", f, tick: i + 1, of: count)
                }
                tickCount += 1
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            // A tick rewrites truth, so the (truth, rank)
            // index is stale — SELECT after TICK must see the post-tick truth.
            truthRankIndex.markDirty()
            return "OK TICK \(count) elapsed=\(String(format: "%.2f", elapsed))ms total=\(tickCount)"
                + rankWorkSuffix(nodesComputed: engine.rankDispatchNodeCount() * count, rankDispatched: true)

        case .tickSync(let count):
            if let e = checkCap("count", count, 0, Self.tickCap) { return e }
            if let e = checkTickHeadroom(count) { return e }
            if let e = admitTickWork("TICK_SYNC", count: count, levels: 1, latch: .sync) { return e }   // one dispatch per tick
            if let e = alloc1dAdmitTickSync() { return e }
            let t0 = CFAbsoluteTimeGetCurrent()
            engine.clearGPUFailure()
            for i in 0..<count {
                engine.tickSync(tickNumber: tickCount)
                if let f = engine.gpuFailure {
                    truthRankIndex.markDirty()
                    return gpuFailureReply("TICK_SYNC", f, tick: i + 1, of: count)
                }
                tickCount += 1
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            truthRankIndex.markDirty()   // a tick rewrote truth
            return "OK TICK_SYNC \(count) elapsed=\(String(format: "%.2f", elapsed))ms total=\(tickCount)"
                + rankWorkSuffix(nodesComputed: nodeCount * count, rankDispatched: false)

        case .eval(let predicate):
            if let e = checkTickHeadroom(1) { return e }
            // EVAL ticks in rank mode (the colour path), and on
            // an edge rank mode cannot order the colour path reads a node
            // while it is written: two identical daemons could end apart. So
            // EVAL asks the cached verdict rank-mode TICK asks
            // and refuses in TICK's words, only the verb changed: no
            // tick, no rows, no tick count, no truth change. On a graph that
            // passes, EVAL is unchanged (the colour-segment dispatch below).
            if let why = rankTickDagRefusal() {
                return "ERROR invalid_graph: EVAL refused, validation: \(why) "
                    + "(VALIDATE names it; TICK_SYNC is defined on this graph)"
            }
            // The rows are the rank-0 roots (fewer
            // with a predicate), so the result file must hold every root before
            // the tick; the refusal used to come after the tick, the count and
            // the TICK_NOTE. Unreachable in the daemon (the file holds 8 + 24N).
            let rankPtr = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: max(nodeCount, 1))
            var rootCount = 0
            for i in 0..<nodeCount where rankPtr[i] == 0 { rootCount += 1 }
            if let e = checkShmFits(rows: rootCount, rowSize: resultRowSize) {
                return e + " (EVAL's rows are its \(rootCount) rank-0 roots); nothing ran"
            }
            if let e = alloc1dAdmitRankTick("EVAL", rankLists: false,                // and its reads
                                            extra: (AdmissionCharge.evalRead(nodes: nodeCount), "its roots, lanes and rows, 48.1 B per node + 64 KiB")) { return e }
            engine.clearGPUFailure()
            engine.tick(tickNumber: tickCount)
            if let f = engine.gpuFailure {                                 // no rows
                truthRankIndex.markDirty()
                return gpuFailureReply("EVAL", f, tick: 1, of: nil)
            }
            tickCount += 1
            truthRankIndex.markDirty()   // a tick rewrote truth
            let roots = engine.readRoots()  // [(Int, UInt8)]
            let truth = engine.readTruthStates()
            let ranks = engine.readRanks()
            var rows: [(Int, UInt64, UInt8, UInt8)] = roots.map { ($0.0, ranks[$0.0], $0.1, UInt8(0)) }
            if let pred = predicate {
                rows = rows.filter { pred.evaluate(truth: $0.2, rank: $0.1, nodeType: $0.3) }
            }
            if let e = writeResults(rows) { return e }
            // The reply says what it omitted. EVAL ticks the whole
            // graph but reports only rank-0 roots (`engine.readRoots`), and
            // it dispatched by rank exactly as TICK did — so it carries
            // TICK's `nodes_computed`/`ranks=`/`bound=` disclosure too.
            return "OK EVAL rows=\(rows.count) tick=\(tickCount) scope=roots"
                + rankWorkSuffix(nodesComputed: engine.rankDispatchNodeCount(), rankDispatched: true)

        case .nodes(let rank, let predicate):
            if let r = rank, let e = nodesNegativeRankRefusal(r) { return e }
            let truth = engine.readTruthStates()
            let ranks = engine.readRanks()
            var rows: [(Int, UInt64, UInt8, UInt8)] = []
            var omitted = 0
            for i in 0..<nodeCount {
                if let r = rank, ranks[i] != UInt64(r) { continue }
                if let pred = predicate {
                    if let e = nodesRankPredicateRefusal(pred, node: i, rank: ranks[i]) { return e }
                    if !pred.evaluate(truth: truth[i], rank: ranks[i], nodeType: 0) { continue }
                }
                // Skip nodes with rank 0 and truth 0 and no explicit rank (likely unused)
                if rank == nil && ranks[i] == 0 && truth[i] == 0 { omitted += 1; continue }
                rows.append((i, ranks[i], truth[i], 0))
            }
            if let e = writeResults(rows) { return e }
            // `omitted=` is the count this default filter dropped —
            // rank-0, truth-0 nodes. The filter is disclosed, not changed.
            return "OK NODES rows=\(rows.count) omitted=\(omitted)"

        case .traverse(let fromNode, let depth):
            if let e = checkRange("node", fromNode, upTo: nodeCount) { return e }
            // Depth drove the frontier loop unbounded. No path in a DAG
            // on N nodes is longer than N-1 hops, so `nodeCount` IS the true
            // extent of a useful depth.
            if let e = checkRange("depth", depth, upTo: nodeCount) { return e }
            var visited: [(Int, UInt64, UInt8, UInt8)] = []
            // A GLOBAL visited set. Without it a node reachable at
            // several depths was appended once per level, so `rows.count`
            // was Σ|frontier_d| — unbounded in `depth` and unrelated to the
            // shm mapping's `nodeCount` rows. With it
            // the row count is bounded by `nodeCount` by construction, and
            // `writeResults` checks the bytes anyway.
            var seen: Set<Int> = []
            var frontier: Set<Int> = [fromNode]
            let truth = engine.readTruthStates()
            let ranks = engine.readRanks()

            for _ in 0..<depth {
                var nextFrontier: Set<Int> = []
                for node in frontier.sorted() {      // a sorted frontier (rows in a fixed order)
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
            // The checks live in `setTruthRefusal` (SET_TRUTH_BULK runs the same ones).
            if let e = setTruthRefusal(node: node, value: value) { return e }
            // Log-first: append to WAL (fsync'd) before touching engine buffer.
            // If WAL fails, abort the mutation so the log and engine stay in sync.
            if let wal = walAppender {
                do { _ = try wal.setTruth(node: UInt32(node), value: value) }
                catch { return walAppendError(error) }
            }
            engine.truthStateBuf.contents()
                .bindMemory(to: UInt8.self, capacity: nodeCount)[node] = value
            truthRankIndex.markDirty()
            // No `markRankTopologyDirty()` — a truth write moves
            // no rank, and the dispatch lists hold ids by rank only; marking
            // it cost an O(N) rebuild before the next TICK.
            return "OK SET node=\(node) truth=\(value)"

        case .setWeight(let node, let dir, let value):
            if let e = checkRange("node", node, upTo: nodeCount) { return e }
            guard dir >= 0 && dir < 6 else { return "ERROR out_of_range: dir \(dir) not in 0..5" }
            guard value.isFinite else { return "ERROR bad_value: weight must be finite" }
            if let wal = walAppender {
                do { _ = try wal.setEdgeWeight(node: UInt32(node), dir: UInt8(dir), value: value) }
                catch { return walAppendError(error) }
            }
            engine.edgeWeightsBuf.contents()
                .bindMemory(to: Float.self, capacity: nodeCount * 6)[node * 6 + dir] = value
            return "OK SET node=\(node) weight[\(dir)]=\(value)"

        case .setValue(let node, let value):
            if let e = checkRange("node", node, upTo: nodeCount) { return e }
            guard value.isFinite else { return "ERROR bad_value: value must be finite" }
            if let wal = walAppender {
                do { _ = try wal.setNodeValue(node: UInt32(node), value: value) }
                catch { return walAppendError(error) }
            }
            engine.nodeValueBuf.contents()
                .bindMemory(to: Float.self, capacity: nodeCount)[node] = value
            return "OK SET node=\(node) value=\(value)"

        case .setRank(let node, let value):
            if let e = checkRange("node", node, upTo: nodeCount) { return e }
            // A rank of N or more is refused: no valid DAG on N nodes holds
            // one, and a typo there would turn the rank loop into a denial
            // of service. A rank in [maxRank, nodeCount) is ACCEPTED and
            // computed — the bound is a sizing hint, not a limit.
            guard value < UInt64(nodeCount) else {
                return "ERROR out_of_range: rank \(value) not in 0..<\(nodeCount)"
            }
            if let wal = walAppender {
                do { _ = try wal.setRank(node: UInt32(node), value: value) }
                catch { return walAppendError(error) }
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
                    return "ERROR dsl_parse: unknown LUT preset: \(Reply.quoted(preset)). Use a named preset (AND OR XOR MAJ IDENTITY CONST0 CONST1 VETO NOR NAND AND3 OR3 MAJ3) or a 64-bit hex literal like 0xAAAAAAAAAAAAAAAA"
                }
            }
            if let wal = walAppender {
                do { _ = try wal.setLUT(node: UInt32(node), lut: lut) }
                catch { return walAppendError(error) }
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
            // Log-first: this writes neighborsBuf, and until the v2
            // opcode existed it did so with no record at all.
            if let wal = walAppender {
                do { _ = try wal.clearEdges(node: UInt32(node)) }
                catch { return walAppendError(error) }
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
                return "ERROR schema: " + Self.registerFanInWords(dst: dst)
            }
            let rankPtr = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: nodeCount)
            let srcRank = rankPtr[src]
            let dstRank = rankPtr[dst]
            guard srcRank > dstRank else {
                return "ERROR schema: rank violation: src(\(src)) rank=\(srcRank) must be > dst(\(dst)) rank=\(dstRank) — edges flow leaves→roots"
            }
            // Find first empty neighbor slot on dst; reject duplicates.
            // The slot is resolved BEFORE the log append so the record
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
                catch { return walAppendError(error) }
            }
            nbPtr[dst * 6 + slot] = Int32(src)
            return "OK CONNECT from=\(src) to=\(dst)"

        case .connectBack(let src, let dst):
            // Validate, then log, then apply — the order the WAL file
            // header promises for EVERY mutation. Validation touches nothing,
            // so a refused edge writes no record; the append comes next, so a
            // log that will not take the record leaves the engine unchanged;
            // the buffer is written last. The checks live in
            // `connectBackRefusal` (CONNECT_BACK_BULK runs
            // the same ones).
            //
            // (This used to apply first and append afterwards, excused by a
            // comment claiming `addBackEdge` is idempotent on duplicates. It
            // is not — it appends a second entry — and the excuse is
            // withdrawn.)
            // Admitted before the rule check, which reads the mode lane and so allocates the
            // ternary lanes on a binary graph; only for an edge the check would read for (in range, no self-loop).
            if src != dst, checkRange("src", src, upTo: nodeCount) == nil, checkRange("dst", dst, upTo: nodeCount) == nil,
               let e = admitBackEdges("CONNECT BACK", count: 1, stagingBytesPerRow: 0) { return e }
            if let e = connectBackRefusal(src: src, dst: dst) { return e }
            if let wal = walAppender {
                do { _ = try wal.connectBack(src: UInt32(src), dst: UInt32(dst)) }
                catch { return walAppendError(error) }
            }
            do {
                try engine.registerValidatedBackEdge(src: UInt32(src), dst: UInt32(dst))
            } catch {
                return Reply.errorLine("schema", error)
            }
            return "OK CONNECT BACK from=\(src) to=\(dst)"

        case .clearBackEdges(let node):
            if let e = checkRange("node", node, upTo: nodeCount) { return e }
            if let wal = walAppender {
                do { _ = try wal.clearBackEdges(dst: UInt32(node)) }
                catch { return walAppendError(error) }
            }
            let before = engine.backEdgeCount
            // The engine call refuses an out-of-range node by name.
            // The guard above already covers it; the catch is what the new
            // signature requires, not a second policy.
            do { try engine.clearBackEdges(toNode: UInt32(node)) }
            catch { return Reply.errorLine("out_of_range", error) }
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
            return "OK GRAPH nodes=\(nodeCount) true=\(trueCount) \(rankStr)" + ternaryInfo(engine, nodeCount: nodeCount)

        case .save(let path, let compressed):
            if let err = guardPath(path) { return err }
            if let e = walTargetRefusal("SAVE", path) { return e }
            return durableSnapshot(path: path, compressed: compressed)

        case .load(let path, let unverified):
            if let err = guardPath(path) { return err }
            if let e = loaderModeRefusal("LOAD") { return e }
            do {
                // Admitted on the bytes it holds (the file's true size; a compressed body's
                // decoded size), read once; an unreadable sidecar refuses unless UNVERIFIED was asked.
                let r = try DagDBSnapshot.load(
                    engine: engine,
                    nodeCount: nodeCount,
                    gridW: width,
                    gridH: height,
                    path: path,
                    daemonEnv: DagDBSnapshot.SnapshotEnv.from(envString: dagdbEnv),
                    twin: twin,
                    allowUnverified: unverified,
                    admit: fileAdmission("LOAD"),
                    // The rebase SAVE admitted with the load, before the commit.
                    beforeCommit: { [unowned self] staged, backEdges, tables in
                        if let s = staged, let e = self.rebaseSaveRefusal("LOAD", twin: s, backEdges: backEdges, tables: tables) {
                            throw DagDBSnapshot.SnapError.admission(e)
                        }
                    }
                )
                tickCount = r.fileTicks
                truthRankIndex.markDirty()
                engine.markRankTopologyDirty()
                // A live LOAD refuses an over-long name (DagDBSnapshot.load), so its
                // reply never names one.
                let reply = "OK LOAD bytes=\(r.bytesRead) nodes=\(r.fileNodeCount) ticks=\(r.fileTicks) elapsed=\(String(format: "%.1f", r.elapsedMs))ms"
                // A load not checked against a manifest says so in its OK
                // reply, last ("; unverified: no manifest"), never only in the daemon's log.
                let rebased = rebaseAfterLoad("LOAD", reply)
                if let why = r.unverified, rebased.hasPrefix("OK") { return rebased + "; unverified: \(why)" }
                return rebased
            } catch let r as DagDBEngine.BackEdgeEntryRefusal {
                return backEdgeLoadRefusal("LOAD", r, nothing: "loaded")
            } catch DagDBSnapshot.SnapError.admission(let line) {
                return line
            } catch {
                // A refused LOAD changes nothing
                // since every check moved before the commit; the two caches
                // are marked stale anyway, as a defense (a rebuild is unseen).
                truthRankIndex.markDirty()
                engine.markRankTopologyDirty()
                return Reply.errorLine("io", verb: "load", error)
            }

        case .exportMorton(let dir):
            if let err = guardPath(dir) { return err }
            if let why = nonFiniteLaneRefusal() {
                return "ERROR io: export: \(DagDBSnapshot.SnapError.validationFailed(why))"
            }
            if let r = slotIntoRegisterWriterRefusal("EXPORT MORTON") { return r }
            do {
                let r = try DagDBSnapshot.exportMorton(
                    engine: engine,
                    nodeCount: nodeCount,
                    dir: dir
                )
                return "OK EXPORT bytes=\(r.bytesWritten) elapsed=\(String(format: "%.1f", r.elapsedMs))ms dir=\(Reply.quoted(dir))"
            } catch {
                return Reply.errorLine("io", verb: "export", error)
            }

        case .importMorton(let dir):
            if let err = guardPath(dir) { return err }
            do {
                // The import's bytes go to the WAL after
                // every check and before the commit; a log that will not take
                // them leaves the engine unchanged.
                // The import's own persistence pass says
                // whether its slots hold S1–S3; a v3 log goes to v4 in place
                // before the import's record(s) when they do.
                let wal = walAppender
                var slotModel = false
                let r = try DagDBSnapshot.importMorton(
                    engine: engine,
                    nodeCount: nodeCount,
                    dir: dir,
                    slotModel: { slotModel = $0 != nil },
                    beforeCommit: { files in
                        guard let wal = wal else { return }
                        do { try wal.importMorton(dir: dir, files: files, slotModel: slotModel) }
                        catch { throw ImportWALFailure(underlying: error) }
                    },
                    admit: fileAdmission("IMPORT MORTON")
                )
                truthRankIndex.markDirty()
                engine.markRankTopologyDirty()
                return "OK IMPORT bytes=\(r.bytesRead) elapsed=\(String(format: "%.1f", r.elapsedMs))ms dir=\(Reply.quoted(dir))"
            } catch let f as ImportWALFailure {
                if let l = f.replyLine { return l }
                return walAppendError(f.underlying)
            } catch let r as DagDBEngine.BackEdgeEntryRefusal {
                return backEdgeLoadRefusal("IMPORT MORTON", r, nothing: "imported")
            } catch DagDBSnapshot.SnapError.admission(let line) {
                return line
            } catch {
                return Reply.errorLine("io", verb: "import", error)
            }

        case .validateGraph:
            if let e = alloc1dAdmit("VALIDATE", [alloc1dRankTableItem,          // it may build the rank table
                                                 (AdmissionCharge.validateRead(nodes: nodeCount), "the register check, 1 B per node + 256 KiB")]) { return e }
            if let violation = DagDBSnapshot.validate(engine: engine, nodeCount: nodeCount) {
                return "FAIL VALIDATE \(violation)"
            } else {
                return "OK VALIDATE — all edges satisfy rank ordering, bounds, no self-loops, no duplicates"
            }

        case .saveJSON(let path):
            if let err = guardPath(path) { return err }
            if let e = walTargetRefusal("SAVE JSON", path) { return e }
            if let why = nonFiniteLaneRefusal() {
                return "ERROR io: save_json: \(DagDBJSONIO.JSONError.outOfRange(why))"
            }
            if let r = slotIntoRegisterWriterRefusal("SAVE JSON") { return r }
            do {
                let r = try DagDBJSONIO.saveJSON(
                    engine: engine, nodeCount: nodeCount,
                    gridW: width, gridH: height,
                    tickCount: tickCount, path: path
                )
                return "OK SAVE_JSON bytes=\(r.bytesWritten) elapsed=\(String(format: "%.1f", r.elapsedMs))ms path=\(Reply.quoted(path))"
            } catch {
                return Reply.errorLine("io", verb: "save_json", error)
            }

        case .loadJSON(let path):
            if let err = guardPath(path) { return err }
            if let e = loaderModeRefusal("LOAD JSON") { return e }
            if let e = nanRecordLoaderRefusal("LOAD JSON") { return e }
            // Its rebase SAVE admitted before the load (the twin state it leaves is
            // this one; the engine's back edges and tables as they are now).
            if let e = rebaseSaveRefusal("LOAD JSON", twin: twin, backEdges: engine.backEdgeCount, tables: engine.ttableCount) { return e }
            do {
                let r = try DagDBJSONIO.loadJSON(
                    engine: engine, nodeCount: nodeCount,
                    gridW: width, gridH: height, path: path,
                    // The one JSON pair (a flat 1.1 x the file was broken by up to 13.1x), floored as the family.
                    admit: fileAdmission("LOAD JSON").map { a in { fb in a(Int(AdmissionCharge.jsonRead(fileBytes: fb).rounded(.up)),
                                                                          "the file's read, 2.52 B per byte for \(fb) B") } },
                    admitParse: fileAdmission("LOAD JSON").map { a in { d in
                        let t = AdmissionCharge.jsonTokens(d)
                        return a(Int(AdmissionCharge.jsonParse(tokens: t, fileBytes: d.count).rounded(.up)),
                                 "the parse, 98.4 B per token + 2.52 B per byte for \(t) tokens (its , : [ { bytes + 1) and \(d.count) B")
                    } }
                )
                tickCount = r.fileTicks
                truthRankIndex.markDirty()
                engine.markRankTopologyDirty()
                let reply = "OK LOAD_JSON bytes=\(r.bytesRead) nodes=\(r.fileNodeCount) ticks=\(r.fileTicks) elapsed=\(String(format: "%.1f", r.elapsedMs))ms"
                return rebaseAfterLoad("LOAD JSON", reply)
            } catch let r as DagDBEngine.BackEdgeEntryRefusal {
                return backEdgeLoadRefusal("LOAD JSON", r, nothing: "loaded")
            } catch DagDBJSONIO.JSONError.admission(let line) {
                return line
            } catch {
                return Reply.errorLine("io", verb: "load_json", error)
            }

        case .saveCSV(let dir):
            if let err = guardPath(dir) { return err }
            if let why = nonFiniteLaneRefusal() {
                return "ERROR io: save_csv: \(DagDBJSONIO.JSONError.outOfRange(why))"
            }
            if let r = slotIntoRegisterWriterRefusal("SAVE CSV") { return r }
            do {
                let r = try DagDBJSONIO.saveCSV(
                    engine: engine, nodeCount: nodeCount, dir: dir
                )
                return "OK SAVE_CSV nodes_bytes=\(r.nodesBytes) edges_bytes=\(r.edgesBytes) elapsed=\(String(format: "%.1f", r.elapsedMs))ms dir=\(Reply.quoted(dir))"
            } catch {
                return Reply.errorLine("io", verb: "save_csv", error)
            }

        case .loadCSV(let dir):
            if let err = guardPath(dir) { return err }
            if let e = loaderModeRefusal("LOAD CSV") { return e }
            if let e = nanRecordLoaderRefusal("LOAD CSV") { return e }
            // Its rebase SAVE admitted before the load (the twin state it leaves is
            // this one; the engine's back edges and tables as they are now).
            if let e = rebaseSaveRefusal("LOAD CSV", twin: twin, backEdges: engine.backEdgeCount, tables: engine.ttableCount) { return e }
            do {
                let r = try DagDBJSONIO.loadCSV(
                    engine: engine, nodeCount: nodeCount, dir: dir,
                    admit: fileAdmission1("LOAD CSV")
                )
                truthRankIndex.markDirty()
                engine.markRankTopologyDirty()
                let reply = "OK LOAD_CSV nodes=\(r.nodesParsed) edges=\(r.edgesParsed) elapsed=\(String(format: "%.1f", r.elapsedMs))ms"
                return rebaseAfterLoad("LOAD CSV", reply)
            } catch let r as DagDBEngine.BackEdgeEntryRefusal {
                return backEdgeLoadRefusal("LOAD CSV", r, nothing: "loaded")
            } catch DagDBJSONIO.JSONError.admission(let line) {
                return line
            } catch {
                return Reply.errorLine("io", verb: "load_csv", error)
            }

        case .backupInit(let dir):
            if let err = guardPath(dir) { return err }
            // Checked before INIT clears the directory's old chain.
            if let why = nonFiniteLaneRefusal() {
                return "ERROR io: backup_init: \(DagDBSnapshot.SnapError.validationFailed(why))"
            }
            if let r = slotIntoRegisterWriterRefusal("BACKUP INIT") { return r }
            do {
                let r = try DagDBBackup.initializeChain(
                    engine: engine, nodeCount: nodeCount,
                    gridW: width, gridH: height,
                    tickCount: tickCount, dir: dir
                )
                return "OK BACKUP_INIT base_bytes=\(r.baseBytes) elapsed=\(String(format: "%.1f", r.elapsedMs))ms dir=\(Reply.quoted(dir))"
            } catch {
                return Reply.errorLine("io", verb: "backup_init", error)
            }

        case .backupAppend(let dir):
            if let err = guardPath(dir) { return err }
            if let why = nonFiniteLaneRefusal() {
                return backupErrorReply(DagDBBackup.BackupError.invalidDiff(why), verb: "backup_append")
            }
            if let r = slotIntoRegisterWriterRefusal("BACKUP APPEND") { return r }
            do {
                let r = try DagDBBackup.appendDiff(
                    engine: engine, nodeCount: nodeCount,
                    gridW: width, gridH: height, dir: dir
                )
                return "OK BACKUP_APPEND bytes=\(r.diffBytes) elapsed=\(String(format: "%.1f", r.elapsedMs))ms path=\(Reply.quoted(r.diffPath)) format=\(r.format)"
            } catch {
                return backupErrorReply(error, verb: "backup_append")
            }

        case .backupRestore(let dir):
            if let err = guardPath(dir) { return err }
            if let e = loaderModeRefusal("BACKUP RESTORE") { return e }
            if let e = nanRecordLoaderRefusal("BACKUP RESTORE") { return e }
            // Its rebase SAVE admitted before the load (the twin state it leaves is
            // this one; the engine's back edges and tables as they are now).
            if let e = rebaseSaveRefusal("BACKUP RESTORE", twin: twin, backEdges: engine.backEdgeCount, tables: engine.ttableCount) { return e }
            if let e = backupRestoreRefusal(dir) { return e }
            do {
                let r = try DagDBBackup.restore(
                    engine: engine, nodeCount: nodeCount,
                    gridW: width, gridH: height, dir: dir
                )
                truthRankIndex.markDirty()
                engine.markRankTopologyDirty()
                // Diffs written by older builds carry no parent record; they are applied and counted.
                let unchecked = r.parentUnchecked > 0
                    ? " parent_unchecked=\(r.parentUnchecked) (diffs written by older builds carry no parent record)" : ""
                let reply = "OK BACKUP_RESTORE diffs_replayed=\(r.diffsReplayed) elapsed=\(String(format: "%.1f", r.elapsedMs))ms rank_bytes=\(r.rankBytes) twin=not_covered\(unchecked)"
                // A base with no manifest says so in the OK reply, as LOAD does.
                let rebased = rebaseAfterLoad("BACKUP RESTORE", reply)
                if let why = r.unverified, rebased.hasPrefix("OK") { return rebased + "; unverified: \(why)" }
                return rebased
            } catch let r as DagDBEngine.BackEdgeEntryRefusal {
                return backEdgeLoadRefusal("BACKUP RESTORE", r, nothing: "restored")
            } catch {
                return backupErrorReply(error, verb: "backup_restore")
            }

        case .backupCompact(let dir):
            if let err = guardPath(dir) { return err }
            do {
                // The new base comes from the chain's own replayed tip, at the
                // chain's own tick count — never from this live engine, which
                // COMPACT does not read and does not change.
                // COMPACT refuses exactly
                // what RESTORE refuses (its rules, order and words; nothing
                // written), not only a slot into a register by the list alone.
                let r = try DagDBBackup.compact(
                    nodeCount: nodeCount,
                    gridW: width, gridH: height, dir: dir,
                    refuseWhatRestoreRefuses: true
                )
                return "OK BACKUP_COMPACT prior_diffs=\(r.priorDiffCount) new_base_bytes=\(r.newBaseBytes) elapsed=\(String(format: "%.1f", r.elapsedMs))ms"
            } catch let r as DagDBEngine.BackEdgeEntryRefusal {         // RESTORE's words
                return backEdgeLoadRefusal("BACKUP COMPACT", r, nothing: "written")
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
            // The one check it does not skip is the range:
            // the WHOLE vector is checked before a single rank is written,
            // so a bad entry leaves every rank exactly as it was, and the
            // refusal names the first offending node. Ranks in
            // [maxRank, nodeCount) pass — they are computed, not refused.
            if let e = checkShmFits(rows: nodeCount, rowSize: 8) { return e }
            if let e = shm1FrameRefusal(.setRanksBulk, count: nodeCount) { return e }
            let src = shmBase.advanced(by: 8).bindMemory(to: UInt64.self, capacity: nodeCount)
            for i in 0..<nodeCount where src[i] >= UInt64(nodeCount) {
                return "ERROR out_of_range: node \(i) rank \(src[i]) not in 0..<\(nodeCount)"
            }
            if let wal = walAppender {
                do { _ = try wal.setRanksBulk(src, count: nodeCount) }
                catch { return walAppendError(error) }
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
            if let e = shm1FrameRefusal(.setLutsBulk, count: nodeCount) { return e }
            let src = shmBase.advanced(by: 8).bindMemory(to: UInt64.self, capacity: nodeCount)
            if let wal = walAppender {
                do { _ = try wal.setLutsBulk(src, count: nodeCount) }
                catch { return walAppendError(error) }
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
            // and memcpy to neighborsBuf. Under the slot model, S1–S3
            // (a duplicate source, a slot self-loop, a rank inversion) are
            // store shapes and are installed — the rank order is not checked
            // (rank-mode TICK refuses S2/S3 itself; VALIDATE names them); S4,
            // a slot into a register, is refused as CONNECT refuses it.
            let count = nodeCount * 6
            // The READ side of this verb must consult the mapping's
            // real size — `configuredShmCapacityBytes` may be smaller than
            // the default `8 + nodeCount * 24`.
            if let e = checkShmFits(rows: count, rowSize: 4) { return e }
            // The frame counts nodes (6 × i32 each), not the 6N slots of `count`.
            if let e = shm1FrameRefusal(.setNeighborsBulk, count: nodeCount) { return e }
            let src = shmBase.advanced(by: 8).bindMemory(to: Int32.self, capacity: count)
            // Range-check the WHOLE vector before writing one word, as
            // SET_RANKS_BULK already did: a bad slot leaves every neighbour
            // exactly as it was, and the refusal names the first offender.
            // -1 is the empty-slot sentinel the Metal kernel tolerates.
            for i in 0..<count where src[i] < -1 || src[i] >= Int32(clamping: nodeCount) {
                return "ERROR out_of_range: slot \(i) (node \(i / 6) dir \(i % 6))"
                    + " neighbour \(src[i]) not in -1..<\(nodeCount)"
            }
            // S4 — a live slot into a
            // register (a BACK_EDGE destination, the flag CONNECT reads) —
            // refused by its first slot, in CONNECT's words; nothing written,
            // no record. Registers come only from CONNECT BACK and the
            // loaders, which keep them free of slots, so the vector cannot
            // give one a combinational input either.
            let reg = engine.isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
            for node in 0..<nodeCount where reg[node] != 0 {
                for k in 0..<6 where src[node * 6 + k] >= 0 {
                    return "ERROR schema: SET_NEIGHBORS_BULK slot \(node * 6 + k) (node \(node) dir \(k)): "
                        + Self.registerFanInWords(dst: node) + "; nothing written"
                }
            }
            // Log-first: the vector is validated above, so a refused
            // install writes no record; the append precedes the memcpy, so a
            // log that will not take the record leaves neighborsBuf unchanged.
            if let wal = walAppender {
                do { _ = try wal.setNeighborsBulk(src, count: nodeCount) }
                catch { return walAppendError(error) }
            }
            let dst = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: count)
            for i in 0..<count { dst[i] = src[i] }
            // Say what the install did not check: the
            // register rule is checked; the rank order is not.
            return "OK SET_NEIGHBORS_BULK nodes=\(nodeCount) edges_slot=\(count)"
                + " rank_order=unchecked recheck=VALIDATE"

        case .composeLUT(let op, let src1, let src2, let dst):
            // Bitwise composition of LUTs into dst's LUT.
            // Caller is responsible for the assumption that src1, src2, dst
            // share a common input vector — the engine just performs the
            // bitwise op on the 64-bit LUT integers. Mutates only dst's LUT.
            if let e = checkRange("src1", src1, upTo: nodeCount) { return e }
            if let e = checkRange("dst", dst, upTo: nodeCount) { return e }
            if let s2 = src2, let e = checkRange("src2", s2, upTo: nodeCount) { return e }
            // TTABLE sources compose
            // their tables pointwise; binary COMPOSE aimed at a ternary node
            // and XOR on tables are refused by name.
            if let r = composeTernary(op: op, src1: src1, src2: src2, dst: dst) { return r }
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
                return "ERROR dsl_parse: unknown compose op \(Reply.quoted(op)) — try AND, OR, XOR, NOT"
            }
            // WAL the equivalent SET_LUT before the engine mutation.
            if let wal = walAppender {
                let lut = (UInt64(resultHigh) << 32) | UInt64(resultLow)
                do { _ = try wal.setLUT(node: UInt32(dst), lut: lut) }
                catch { return walAppendError(error) }
            }
            lowPtr[dst]  = resultLow
            highPtr[dst] = resultHigh
            // truthRankIndex doesn't depend on LUT, no dirty flag flip needed.
            let dstLut64 = (UInt64(resultHigh) << 32) | UInt64(resultLow)
            let src2Display = src2.map { String($0) } ?? "—"
            return "OK COMPOSE op=\(op) src1=\(src1) src2=\(src2Display) dst=\(dst) lut=0x\(String(dstLut64, radix: 16, uppercase: true))"

        case .selectByTruthRank(let truthVal, let lo, let hi):
            if let e = alloc1dAdmitSelect() { return e }
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
            if let e = alloc1dAdmitBFSDepths() { return e }
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
                return Reply.errorLine("bfs", verb: "depths", error)
            }

        case .distance(let metric, let loA, let hiA, let loB, let hiB):
            guard let m = DagDBDistance.Metric(rawValue: metric) else {
                return "ERROR dsl_parse: unknown metric \(Reply.quoted(metric)) — try jaccardNodes, jaccardEdges, rankL1, rankL2, typeL1, boundedGED, wlL1, spectralL2"
            }
            let subA = DagSubgraph.rankRange(engine: engine, nodeCount: nodeCount, lo: loA, hi: hiA)
            let subB = DagSubgraph.rankRange(engine: engine, nodeCount: nodeCount, lo: loB, hi: hiB)
            if m == .spectralL2, let e = admitSpectral(engine: engine, nodeCount: nodeCount, subA, subB) { return e }
            let v = DagDBDistance.compute(
                engine: engine, nodeCount: nodeCount, metric: m, subA, subB)
            return "OK DISTANCE \(metric) \(loA)-\(hiA) vs \(loB)-\(hiB) value=\(v) |A|=\(subA.nodeIds.count) |B|=\(subB.nodeIds.count)"

        case .openReader:
            if let e = admitOpenReader() { return e }
            do {
                let tmplState = DagDBState(width: width, height: height)
                let session = try sessionManager.open(
                    primary: engine, grid: grid, stateTemplate: tmplState,
                    maxRank: maxRank, tickCount: tickCount
                )
                return "OK OPEN_READER id=\(session.id) tick=\(session.tickCountAtOpen) open_sessions=\(sessionManager.openCount)"
            } catch {
                return Reply.errorLine("io", verb: "open_reader", error)
            }

        case .closeReader(let id):
            let ok = sessionManager.close(id)
            return ok
                ? "OK CLOSE_READER id=\(id) open_sessions=\(sessionManager.openCount)"
                : "ERROR not_found: close_reader session \(Reply.quoted(id)) not found"

        case .listReaders:
            let sessions = sessionManager.openSessions
            if sessions.isEmpty {
                return "OK LIST_READERS open_sessions=0"
            }
            let ids = sessions.map { "\($0.id)@tick=\($0.tickCountAtOpen)" }.joined(separator: " ")
            return "OK LIST_READERS open_sessions=\(sessions.count) \(ids)"

        case .reader(let id, let inner):
            guard let session = sessionManager.get(id) else {
                return "ERROR not_found: reader session \(Reply.quoted(id)) not found"
            }
            // A session's verbs take the primary's charges, on the session's engine.
            if let e = readerVerbRefusal(inner, session: session.snapshotEngine, nodeCount: session.nodeCount) { return e }
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
                return Reply.errorLine("bfs", error)
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
                return Reply.errorLine("bfs", error)
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

        case .setMode, .setTTableId, .setThresh, .setTrit, .getTrit,
             .ttableDefine, .ttablePreset, .ttableGet,
             .setModesBulk, .setTTableIdsBulk, .setThreshBulk, .ttableBulk:
            return handleTernary(cmd) ?? "ERROR unknown_command: \(Reply.quoted(input))"

        // The bulk verbs (DagDBCommandHandler+EngineE2.swift).
        case .connectBackBulk:
            return connectBackBulk()
        case .setTruthBulk:
            return setTruthBulk()
        case .truthSlice(let byRank, let lo, let hi, let bytes):      // DagDBCommandHandler+EngineG2.swift
            return truthSlice(byRank: byRank, lo: lo, hi: hi, bytes: bytes, engine: engine, nodeCount: nodeCount,
                              sessionId: nil)
        case .tickUntilStable(let max):
            return tickUntilStable(maxTicks: max)

        // LUT writes (DagDBCommandHandler+EngineG.swift).
        case .setLuts(let sel, let op):
            // A rank selection rebuilds a stale rank table once the lists exist; the pool's room is checked too.
            if let e = alloc1dAdmit("SET_LUTS", [engine.rankListsBuilt ? alloc1dRankTableItem : nil], gpu: true) { return e }
            return setLuts(sel, op)
        // Truth fills (DagDBCommandHandler+EngineG.swift).
        case .setTruthFill(let sel, let v):
            return setTruthFill(sel, v)

        case .twin(let t):
            return handleTwin(t, sessionId: nil)

        case .saveTiled, .tiledOpen, .tiledBFS, .tiledSelect, .tiledStatus, .tiledList, .tiledClose,
             .tiledTick, .tiledGetTruth:
            return handleTiled(cmd, sessionId: nil)

        case .dslParse(let words):
            // The parser refused the line by name; nothing runs.
            return "ERROR dsl_parse: \(words)"

        case .unknown(let raw):
            return "ERROR unknown_command: \(Reply.quoted(raw))"
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
            return "OK GRAPH session=\(sessionId) nodes=\(nodeCount) true=\(trueCount) \(rankStr)" + ternaryInfo(engine, nodeCount: nodeCount)

        case .nodes(let rank, let predicate):
            if let r = rank, let e = nodesNegativeRankRefusal(r) { return e }
            let truth = engine.readTruthStates()
            let ranks = engine.readRanks()
            var rows: [(Int, UInt64, UInt8, UInt8)] = []
            var omitted = 0
            for i in 0..<nodeCount {
                if let r = rank, ranks[i] != UInt64(r) { continue }
                if let pred = predicate {
                    if let e = nodesRankPredicateRefusal(pred, node: i, rank: ranks[i]) { return e }
                    if !pred.evaluate(truth: truth[i], rank: ranks[i], nodeType: 0) { continue }
                }
                if rank == nil && ranks[i] == 0 && truth[i] == 0 { omitted += 1; continue }
                rows.append((i, ranks[i], truth[i], 0))
            }
            if let e = writeResults(rows, engine: engine) { return e }
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
                for node in frontier.sorted() {      // a sorted frontier (rows in a fixed order)
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
            if let e = writeResults(visited, engine: engine) { return e }
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
                return Reply.errorLine("bfs", verb: "reader_depths", error)
            }

        case .distance(let metric, let loA, let hiA, let loB, let hiB):
            guard let m = DagDBDistance.Metric(rawValue: metric) else {
                return "ERROR dsl_parse: reader_distance unknown metric \(Reply.quoted(metric))"
            }
            let subA = DagSubgraph.rankRange(engine: engine, nodeCount: nodeCount, lo: loA, hi: hiA)
            let subB = DagSubgraph.rankRange(engine: engine, nodeCount: nodeCount, lo: loB, hi: hiB)
            if m == .spectralL2, let e = admitSpectral(engine: engine, nodeCount: nodeCount, subA, subB) { return e }
            let v = DagDBDistance.compute(
                engine: engine, nodeCount: nodeCount, metric: m, subA, subB)
            return "OK DISTANCE session=\(sessionId) \(metric) \(loA)-\(hiA) vs \(loB)-\(hiB) value=\(v) |A|=\(subA.nodeIds.count) |B|=\(subB.nodeIds.count)"

        case .status:
            // The protocol is the daemon's, and a
            // client may open only a reader, so the reader's STATUS carries it too.
            return "OK STATUS session=\(sessionId) nodes=\(nodeCount) grid=\(gridW)x\(gridH)"
                + " client_protocol=\(Self.clientProtocol)" + memBudgetStatusToken

        case .getTruth(let node):
            if let e = checkRange("node", node, upTo: nodeCount) { return e }
            let truth = engine.truthStateBuf.contents()
                .bindMemory(to: UInt8.self, capacity: nodeCount)[node]
            return "OK GET session=\(sessionId) node=\(node) truth=\(truth)"

        case .getTrit(let node):
            if let e = checkRange("node", node, upTo: nodeCount) { return e }
            let b = engine.truthStateBuf.contents()
                .bindMemory(to: UInt8.self, capacity: nodeCount)[node]
            return "OK GET session=\(sessionId) node=\(node) trit=\(TernaryReference.trit(ofByte: b))"

        case .ttableGet(let tid):
            guard let t = engine.tableBytes(tid) else {
                return "ERROR out_of_range: tid \(tid) not in 0..<\(engine.ttableCount)"
            }
            return "OK TTABLE GET session=\(sessionId) tid=\(tid) table=\(Self.tableString(t))"

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
                return Reply.errorLine("bfs", verb: "reader", error)
            }

        case .truthSlice(let byRank, let lo, let hi, let bytes):   // a read (BYTES too)
            return truthSlice(byRank: byRank, lo: lo, hi: hi, bytes: bytes, engine: engine, nodeCount: nodeCount,
                              sessionId: sessionId)

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
             .saveTiled, .tiledOpen, .tiledClose, .tiledTick,
             // Every mutating ternary form is forbidden here.
             .setMode, .setTTableId, .setThresh, .setTrit,
             .ttableDefine, .ttablePreset,
             .setModesBulk, .setTTableIdsBulk, .setThreshBulk, .ttableBulk,
             // the bulk writers and the tick loop.
             .connectBackBulk, .setTruthBulk, .tickUntilStable,
             // a LUT write; a truth write.
             .setLuts, .setTruthFill:
            return "ERROR forbidden: command not allowed in reader session (read-only)"

        case .eval:
            // EVAL runs tick() which is a write on the snapshot's buffers.
            // Technically it only mutates the snapshot, not the primary, so
            // it's safe — but semantically a reader shouldn't tick. Reject.
            return "ERROR forbidden: EVAL not allowed in reader session (ticks mutate)"

        case .twin(let t):
            // FOLD RUN's own refusal, because the state it moves is not
            // a twin registry: it assigns the handler's `lastFold`, which
            // FOLD KEPT/SOURCE/TIER/INFO read. Those
            // four stay open to a reader; RUN does not.
            if case .foldRun = t {
                return "ERROR forbidden: FOLD RUN assigns the daemon-global last-fold result"
                    + " that FOLD KEPT/SOURCE/TIER/INFO read; not allowed in reader session"
            }
            // Twin registries are daemon-global — a reader session
            // may only run the read-only twin verbs, dispatched against the
            // same handler-owned twin state as the primary path.
            guard t.isReadOnly else {
                return "ERROR forbidden: twin verb mutates daemon-global twin state; not allowed in reader session"
            }
            return handleTwin(t, sessionId: sessionId)

        case .dslParse(let words):
            // The parse refuses before the session's own refusals.
            return "ERROR dsl_parse: \(words)"

        case .unknown(let raw):
            return "ERROR unknown_command: reader inner: \(Reply.quoted(raw))"
        }
    }

    // MARK: - Shared-memory result writer

    /// Every shared-memory WRITE checks capacity, as the read side
    /// (`readFloats`/`readDoubles`/`readU32s`) always did. Returns nil when
    /// the rows fit, else the refusal line — nothing is written in that
    /// case, so the previous result in shm stays intact and readable.
    @discardableResult
    func writeResults(_ rows: [(Int, UInt64, UInt8, UInt8)], engine rowEngine: DagDBEngine? = nil) -> String? {
        if let e = checkShmFits(rows: rows.count, rowSize: resultRowSize) { return e }
        // The node's mode byte rides in pad byte 18 (the
        // row stays 24 bytes), read from the engine the rows came from — a
        // reader session's snapshot, or the primary.
        let modes = (rowEngine ?? engine).ternaryLaneView?.mode   // nil: every node BINARY
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
            rowPtr.advanced(by: 18).storeBytes(of: modes?[row.0] ?? 0, as: UInt8.self)
            // 5 bytes pad at offsets 19..23, zeroed on every row write. Every
            // writer shares this buffer (TRUTH_SLICE's bytes, the
            // vectors, a client's input frame), so an unwritten pad showed the
            // previous writer's bytes. Only rows written here are touched: a
            // refusal above writes nothing.
            rowPtr.advanced(by: 19).storeBytes(of: UInt32(0), as: UInt32.self)
            rowPtr.advanced(by: 23).storeBytes(of: UInt8(0), as: UInt8.self)
        }
        return nil
    }

    /// The one capacity refusal every shm writer shares. The
    /// arithmetic is overflow-reporting so a row count off the wire cannot
    /// trap on the way to the guard that exists to catch it.
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

/// A WAL append that failed inside IMPORT MORTON's
/// pre-commit hook, told apart from the import's own refusals.
/// It carries the line its underlying error carries.
struct ImportWALFailure: Error, Reply.CarriesLine { let underlying: Error; var replyLine: String? { Reply.carriedLine(underlying) } }
