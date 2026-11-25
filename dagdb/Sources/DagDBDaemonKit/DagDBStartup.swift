import Foundation
import CryptoKit
import DagDB

/// Startup recovery (roadmap item 4, 2026-09-09).
///
/// Before this, a daemon restart after `SAVE` came up empty: `SAVE` writes a
/// snapshot and then a WAL checkpoint, startup replays only records past the
/// last checkpoint, and nothing loaded the snapshot. Operators had to issue
/// `LOAD` by hand. Found by a socket smoke test on 2026-09-06.
///
/// `recover` does the whole startup sequence in one place so `main.swift`
/// and the tests cannot drift apart:
///
///   1. If `snapshotPath` is set (env `DAGDB_STARTUP_LOAD`) and the file
///      exists, load it into the engine + twin state. A snapshot that
///      cannot be read is a hard error — the daemon must not start empty
///      over a WAL whose checkpoint already assumes that state, or the two
///      would silently diverge. A missing file is fine (first boot).
///   2. If `walPath` is set and the file exists, replay on top the records
///      the snapshot does not hold. Every durable snapshot (`SAVE`, the
///      autosave on shutdown, a loader's rebase) writes a SNAPSHOT_BIND
///      record carrying its file's SHA-256 before its rename,
///      so replay starts after the last bind record carrying the loaded
///      file's digest, whether or not the checkpoint that follows it landed;
///      with no such record (a snapshot or log from an older build), after the
///      last checkpoint. With NO snapshot loaded (no path set, or
///      its file not written yet) the engine is empty and the whole log is
///      replayed: its checkpoints and bind records belong to
///      snapshots this start did not load (a SAVE to another path), so the
///      records before them are not in this base. Snapshot + replayed tail = the state at
///      the moment the daemon last spoke, for everything the WAL carries:
///      TICK writes no record, and the loaders that write none (LOAD, LOAD
///      JSON, LOAD CSV, BACKUP RESTORE) end with a durable snapshot to this
///      path (`DagDBCommandHandler.rebaseAfterLoad`). WAL
///      failures are reported in `replayError`, not thrown, so the caller
///      keeps the pre-existing "continue without WAL" behaviour.
///
/// Opt-in: without `DAGDB_STARTUP_LOAD` no snapshot is loaded, and the whole
/// log is replayed over the empty engine (not only the records after the
/// last checkpoint, which marks some other snapshot).
/// The path must lie under the data root when one is configured — the same
/// rule `SAVE`/`LOAD` enforce on client-supplied paths.
public enum DagDBStartup {
    public struct Result {
        /// Non-nil when a snapshot file was found and loaded.
        public let snapshot: DagDBSnapshot.LoadResult?
        /// Non-nil when a WAL file was found and replayed.
        public let replay: DagDBWAL.ReplayResult?
        /// Set when the WAL existed but could not be replayed (caller decides).
        public let replayError: Error?
        /// The era sidecar as the boot left it
        /// (nil: none, refused, or not writable); the handler seals the mark.
        public var eraSeal: EraSeal? = nil
        /// The replay's running hash at the
        /// valid end, handed to the appender (one hashing pass at boot).
        public var walHash: (length: Int, state: SHA256)? = nil
        /// The log's bytes as the replay read them, handed to the appender (one read at boot).
        public var walFound: DagDBWAL.FoundLog? = nil
        /// Tick counter the handler should start from.
        public var tickCount: UInt32 { snapshot?.fileTicks ?? 0 }
    }

    /// Where the era begins, and whether the
    /// era prefix's hash, for the handler's later seals.
    public struct EraSeal: Equatable {
        public let offset: Int
        /// The era prefix's hash (a seal does not read the log).
        public let eraSha256: String
        public init(offset: Int, eraSha256: String) {
            self.offset = offset; self.eraSha256 = eraSha256
        }
    }

    public enum StartupError: Error, CustomStringConvertible {
        case snapshotPathRejected(path: String, reason: String)
        case snapshotUnreadable(path: String, underlying: String)
        /// DAGDB_WAL outside the data root, not a regular file, or the startup snapshot's path.
        case walPathRejected(path: String, reason: String)
        /// What the boot would rebuild does not fit the memory budget (the line names the bytes,
        /// the budget and the flag with the size to pass).
        case overBudget(String)
        /// The startup snapshot holds what no live verb lets a daemon hold.
        case snapshotRefused(path: String, reason: String)

        public var description: String {
            switch self {
            case .snapshotPathRejected(let p, let r):
                return "startup snapshot path rejected: '\(p)' — \(r)"
            case .snapshotUnreadable(let p, let u):
                return "startup snapshot unreadable: '\(p)' — \(u)"
            case .walPathRejected(let p, let r):
                return "DAGDB_WAL rejected: '\(p)' — \(r); refusing to start"
            case .overBudget(let line):
                return "\(line); refusing to start"
            case .snapshotRefused(let p, let r):
                // The cause, the file, the remedy.
                return "startup snapshot refused: '\(p)' — \(r): the file holds a shape no build writes (corruption);"
                    + " start from a good snapshot or the backup chain (BACKUP RESTORE), or set DAGDB_STARTUP_LOAD to"
                    + " another snapshot; refusing to start"
            }
        }
    }

    /// Same containment rule as `DagDBCommandHandler.guardPath`, returned as
    /// a reason string instead of a DSL error line.
    static func pathViolation(_ p: String, dataRoot: String?) -> String? {
        for seg in p.split(separator: "/", omittingEmptySubsequences: false) {
            if seg == ".." { return "traversal segment '..' rejected" }
        }
        guard let root = dataRoot else { return nil }
        let abs = (p as NSString).standardizingPath
        let absResolved = (abs as NSString).resolvingSymlinksInPath
        let rootResolved = (root as NSString).resolvingSymlinksInPath
        if !absResolved.hasPrefix(rootResolved + "/") && absResolved != rootResolved {
            return "outside DAGDB_DATA_ROOT '\(root)'"
        }
        return nil
    }

    /// The boot's tick line. S is the recovered tick count (the loaded
    /// snapshot's, 0 with none loaded).
    /// - Notes inside the replay window: T is their HIGHEST total (a lower
    ///   later note never hides a higher one), L = T − S: `at least
    ///   <L> ticks were not recovered …`, or the zero line when L = 0.
    /// - No note in the window, the last note before it (it precedes the
    ///   snapshot's bind, so the snapshot holds its ticks, and no tick command
    ///   ran since): the zero line when its total is S.
    /// - Notes are written unsynced, a restart starts a new
    ///   life at S and a command killed before it replied writes no note, so
    ///   the count is a lower bound and the zero line says no lost ticks were
    ///   LOGGED, never a bare "0 ticks lost".
    /// - No note (a v1–v4 log, or a v5 log holding none): `tick history
    ///   unknown`, never "0 lost". The same words, with the reason, when the
    ///   note cannot be set against S: T < S, a note before the window whose
    ///   total is not S (a loader moved the tick count), or a
    ///   total above the daemon's u32 tick counter's range.
    /// - A COUNTER_DROP in the window (the counter moved,
    ///   up or down, within a life by something other than a tick, with no
    ///   successful rebase) makes the notes incomparable with S: unknown,
    ///   with that reason, before anything else.
    public static func tickHistoryLine(_ r: DagDBWAL.ReplayResult, snapshotTicks s: UInt64) -> String {
        if r.counterDropsInWindow > 0 {
            return "WAL: tick history unknown (the tick counter moved within this window without a durable rebase: a load whose rebase failed)"
        }
        let counterMax = UInt64(UInt32.max)
        if let t = r.tickNoteWindowMax {
            guard t <= counterMax else {
                return "WAL: tick history unknown (the highest logged total \(t) is above the tick counter's range, \(counterMax))"
            }
            guard t >= s else {
                return "WAL: tick history unknown (the highest logged total \(t) is below the recovered tick count \(s))"
            }
            if t == s { return noLostTicksLine(t, s) }
            return "WAL: at least \(t - s) ticks were not recovered (highest logged total \(t), recovered tick count \(s)); the recovered truth is the pre-tick state; earlier restarts, a command interrupted before it replied, and a power loss can each hide more"
        }
        guard let note = r.tickNote else { return "WAL: tick history unknown" }
        let t = note.total
        guard t <= counterMax else {
            return "WAL: tick history unknown (the last logged total \(t), before the snapshot's position in the log, is above the tick counter's range, \(counterMax))"
        }
        guard t == s else {
            return "WAL: tick history unknown (the last tick note, total \(t), precedes the snapshot's position in the log and differs from its \(s) ticks)"
        }
        return noLostTicksLine(t, s)
    }

    /// The zero line.
    static func noLostTicksLine(_ t: UInt64, _ s: UInt64) -> String {
        "WAL: no lost ticks logged (highest logged total \(t), recovered tick count \(s); earlier restarts, an interrupted command, or a power loss can hide ticks)"
    }

    /// Startup's load and replay run inside one autorelease
    /// pool, so what they autorelease (a snapshot's twin JSON, the alarm and
    /// kernel files a replayed record re-reads) is released when recovery
    /// returns, not kept for the daemon's life.
    public static func recover(
        engine: DagDBEngine,
        nodeCount: Int,
        width: Int,
        height: Int,
        dagdbEnv: String?,
        dataRoot: String?,
        twin: TwinState,
        truthRankIndex: TruthRankIndex,
        snapshotPath: String?,
        walPath: String?,
        log: (String) -> Void = { print(Reply.line($0)) },   // the daemon log through the formatter
        admission: ((Int, String) -> String?)? = nil,
        boot: DagDBBootAdmission? = nil
    ) throws -> Result {
        // Every file recovery opens (the snapshot, its sidecar, the files its twin section
        // names, the log, the files a replayed record names, the era sidecar) contained in the data root,
        // and the boot's admission bound. `boot` (the daemon's)
        // admits the snapshot load as LOAD, each window of the log, each replayed record at its live verb's charge,
        // and the state at the end; a refusal is `StartupError.overBudget`, and the daemon does not start.
        let r = try DaemonFile.$admission.withValue(boot?.fileAdmission ?? admission) { try DaemonFile.withRoot(dataRoot) {
            try autoreleasepool {
                try recoverInPool(engine: engine, nodeCount: nodeCount, width: width, height: height,
                                  dagdbEnv: dagdbEnv, dataRoot: dataRoot, twin: twin, truthRankIndex: truthRankIndex,
                                  snapshotPath: snapshotPath, walPath: walPath, log: log, boot: boot)
            }
        } }
        // Never started over the budget (the recovery's transients released first).
        if let line = boot?.finalRefusal() { throw StartupError.overBudget(line) }
        return r
    }

    /// DAGDB_WAL's path checked before anything is read: inside the data root (its deepest
    /// existing ancestor resolved; earlier builds never checked the environment's path), not a link, and,
    /// when it exists, a regular file (a FIFO there used to read as "file not found" and the daemon ran without a WAL);
    /// not the startup snapshot's path. Nil, or why it is refused (the daemon does not start).
    public static func walPathRefusal(_ wp: String, snapshotPath: String?) -> String? {
        let c: String
        do { c = try DaemonFile.forWrite(wp) } catch { return Reply.errorWords(error) }
        if let k = DaemonFile.lkind(c), k != "regular file" {
            return "\(DaemonFile.Refusal.notRegular(path: wp, kind: k))"
        }
        if let sp = snapshotPath, let cs = try? DaemonFile.forWrite(sp), cs == c {
            return "it is also DAGDB_STARTUP_LOAD's path (a snapshot written there would replace the log)"
        }
        return nil
    }

    private static func recoverInPool(
        engine: DagDBEngine,
        nodeCount: Int,
        width: Int,
        height: Int,
        dagdbEnv: String?,
        dataRoot: String?,
        twin: TwinState,
        truthRankIndex: TruthRankIndex,
        snapshotPath: String?,
        walPath: String?,
        log: (String) -> Void,
        boot: DagDBBootAdmission?
    ) throws -> Result {
        var snapshot: DagDBSnapshot.LoadResult? = nil
        var loadedOverCap: [String: Int] = [:]
        // The loaded file's digest, asked for only when the WAL
        // holds a bind record (the load computed it when a manifest exists).
        var snapshotDigest: (() -> [UInt8]?)? = nil

        if let wp = walPath, let why = walPathRefusal(wp, snapshotPath: snapshotPath) {
            throw StartupError.walPathRejected(path: wp, reason: why)
        }
        if let sp = snapshotPath {
            if let why = pathViolation(sp, dataRoot: dataRoot) {
                throw StartupError.snapshotPathRejected(path: sp, reason: why)
            }
            // The new-file escape closed for the startup path too (a rebase and the autosave
            // write there): its deepest existing ancestor resolved inside the root.
            if case .outsideRoot? = DaemonFile.containmentRefusal(sp) {
                throw StartupError.snapshotPathRejected(path: sp, reason: "outside DAGDB_DATA_ROOT '\(dataRoot ?? "")'")
            }
            if DaemonFile.lkind(sp) != nil {
                do {
                    // Hashed as it is read, so the bind lookup never reads the file again.
                    let r = try DagDBSnapshot.load(
                        engine: engine, nodeCount: nodeCount,
                        gridW: width, gridH: height, path: sp,
                        daemonEnv: DagDBSnapshot.SnapshotEnv.from(envString: dagdbEnv),
                        twin: twin,
                        keepDanglingHookIds: true,  // the era marker
                        wantDigest: true,
                        admit: DaemonFile.admission.map { AdmissionCharge.loadFamilyFloored($0) },  // as LOAD is
                        capsAsEra: true                                   // the era rule
                    )
                    truthRankIndex.markDirty()
                    engine.markRankTopologyDirty()
                    snapshot = r
                    snapshotDigest = { r.digest }
                    log("  Startup: loaded snapshot \(sp) — nodes=\(r.fileNodeCount) ticks=\(r.fileTicks) twin_open=\(twin.totalOpen) (\(String(format: "%.1f", r.elapsedMs))ms)")
                    // The era's excess the file carries, loaded and named.
                    loadedOverCap = twin.overCap()
                    for (k, n) in loadedOverCap.sorted(by: { $0.key < $1.key }) {
                        log("  WARN: " + TwinState.overCapLine(k, n, replayed: false))
                    }
                } catch DagDBSnapshot.SnapError.admission(let line) {
                    throw StartupError.overBudget(line)
                } catch DagDBSnapshot.SnapError.twinRefused(let why) {
                    throw StartupError.snapshotRefused(path: sp, reason: "v7 twin section refused: \(why)")
                } catch {
                    throw StartupError.snapshotUnreadable(path: sp, underlying: Reply.errorWords(error))
                }
            } else {
                log("  Startup: no snapshot at \(sp) yet — starting empty")
            }
        }

        var replay: DagDBWAL.ReplayResult? = nil
        var replayError: Error? = nil
        var walHash: (length: Int, state: SHA256)? = nil
        // The era sidecar as found (parsed
        // only: the replay hashes the log), and each clock's tick and each
        // hook's frame when the replay reaches the era's first record and the
        // mark's (nil: never reached, so every replayed record precedes it).
        let found: (claim: DagDBHOOK1Era.Claim?, unknown: String?, refused: String?, exists: Bool) =
            walPath.map { DagDBHOOK1Era.read(walPath: $0, dataRoot: dataRoot) } ?? (nil, nil, nil, false)
        var atEra: (ticks: [String: UInt64], frames: [String: Int])? = nil
        var atMark: (ticks: [String: UInt64], frames: [String: Int])? = nil
        let eraOffset: Int? = found.claim?.era
        let markOffset: Int? = found.claim?.mark
        // An empty regular file is a log whose create a crash left without its header (the
        // appender writes it); anything else that exists is replayed, or refuses the start by name.
        var walFound: DagDBWAL.FoundLog? = nil
        if let wp = walPath, DaemonFile.lkind(wp) != nil, ((try? DaemonFile.sizeIfPresent(wp)) ?? nil) != 0 {
            do {
                // No snapshot loaded — the
                // engine is empty, so the whole log is replayed; its
                // checkpoints and bind records mark some other snapshot's
                // contents (a SAVE to another path, a startup path never
                // written), not this base.
                let r = try DagDBWAL.replay(engine: engine, nodeCount: nodeCount, path: wp, twin: twin,
                                            snapshotDigest: snapshotDigest, wholeLog: snapshot == nil,
                                            beforeRecord: { off in
                    if atEra == nil, let e = eraOffset, off >= e {
                        atEra = (twin.clocks.entries.mapValues { $0.clock.tick }, twin.hooks.entries.mapValues { $0.hook.t })
                    }
                    if atMark == nil, let m = markOffset, off >= m {
                        atMark = (twin.clocks.entries.mapValues { $0.clock.tick }, twin.hooks.entries.mapValues { $0.hook.t })
                    }
                }, hashAt: [found.claim?.era, found.claim?.mark].compactMap { $0 },
                   admitRecord: boot.map { b in { b.replayCharge($0) } })
                replay = r
                walFound = r.found
                // A replay that skipped anything is never silent. The
                // count is on the line whether or not it is zero, so an
                // operator reading two boots side by side sees the change;
                // the reason histogram only appears when there is one.
                // A record replayed by the older hook
                // rule changed state, so it is counted under its own word.
                let preHOOK1 = r.preHOOK1Stops.isEmpty ? "" : ", pre_hook1_stop=\(r.preHOOK1Stops.count)"
                log("  WAL: replayed \(r.recordsAfterCheckpoint) records past epoch \(r.checkpointEpoch) (log v\(r.fileVersion), skipped=\(r.recordsSkipped)\(preHOOK1))")
                if !r.preHOOK1Stops.isEmpty {
                    log("  WAL: replayed \(r.preHOOK1Stops.count) CLOCK ADVANCE record(s) by the pre-HOOK1 rule (their clock held a closed hook's id: one tick, then the stop the old daemon made live; not skipped) — \(r.preHOOK1Stops.joined(separator: "; "))")
                }
                if let b = r.boundAtOffset {
                    log("  WAL: the window starts after the snapshot's own bind record (offset \(b), epoch \(r.boundEpoch ?? 0)), not the last checkpoint")
                }
                if snapshot == nil && (r.bindRecords > 0 || r.checkpointEpoch > 0) {
                    log("  WAL: no snapshot loaded — the whole log was replayed over the empty engine; its checkpoints (last epoch \(r.checkpointEpoch)) and \(r.bindRecords) bind record(s) belong to snapshots this start did not load")
                }
                if r.recordsSkipped > 0 {
                    log("  WAL: skipped \(r.recordsSkipped) record(s) — \(r.skipReasons.line)")
                }
                // The refused records by name, in
                // one line beside the counts (printed, not gated).
                if !r.refusals.isEmpty {
                    log("  WAL: refused \(r.refusals.count) record(s) — \(r.refusals.joined(separator: "; "))")
                }
                if let off = r.truncatedAtOffset {
                    log("  WAL: dropped truncated tail at offset \(off)")
                }
                // Records applied as logged that the live verbs refuse, named.
                if !r.warnings.isEmpty {
                    log("  WAL: applied \(r.warnings.count) record(s) as logged that this build refuses live — \(r.warnings.joined(separator: "; "))")
                }
                // The ticks this restart did not recover.
                log("  " + tickHistoryLine(r, snapshotTicks: UInt64(snapshot?.fileTicks ?? 0)))
                if r.recordsAfterCheckpoint > 0 {
                    truthRankIndex.markDirty()
                    engine.markRankTopologyDirty()
                }
            } catch DagDBWAL.WALError.overBudget(let line) {
                throw StartupError.overBudget(line)
            } catch {
                replayError = error
            }
        }
        // The era rule: a log from before the caps can hold more than a live verb allows today.
        // It replayed faithfully above; each excess is named, loudly, and new opens are refused until below.
        for line in twin.replayedOverCapLines(beyond: loadedOverCap) { log("  WARN: " + line) }
        // The era rule for names: an older over-long name the startup load or the replay restored is
        // loaded faithfully and named here; the live verbs refuse new ones.
        if let line = twin.overLongNamesLine("the recovered twin state") { log("  WARN: " + line) }

        // A log from an older build can hold a
        // RECORD OPEN whose header HEADER CHECK refuses (a nan clock-sync
        // floor). It replays faithfully (a valid record of its era), and SAVE,
        // the autosave and every loader's rebase refuse until it is closed;
        // the boot names each one and the way out.
        for id in twin.recordsWithNonFiniteHeaders {
            log("  WARN: replayed RECORD \(id) carries a header HEADER CHECK refuses; SAVE refuses until RECORD CLOSE \(id), then SAVE")
        }
        // The era sidecar. At the
        // first boot on a log (no sidecar) it is written with era = mark = the
        // log's valid length now, so every record replayed above is pre-era; a
        // log that does not exist yet, or holds no record, starts its era at its
        // first byte. A mismatched (checked against the replay's own prefix
        // digests), short or unreadable sidecar is named and the
        // naming is conservative; the boot then re-seals once (era = mark
        // = the length now). A refused path is named and nothing
        // is written. A matching sidecar is not rewritten at boot. The log is not written.
        var era: DagDBHOOK1Era.Era? = nil
        var eraSeal: EraSeal? = nil
        if let wp = walPath, replayError == nil {
            let exists = replay != nil
            let validEnd = exists ? (replay?.truncatedAtOffset ?? replay?.hashedLength ?? 0) : 0
            let endDigest = exists ? (replay?.hashState.map { $0.finalize().map { String(format: "%02x", $0) }.joined() } ?? DagDBHOOK1Era.emptySha256)
                                   : DagDBHOOK1Era.emptySha256
            let noRecords = !exists || validEnd <= DagDBWAL.headerSize
            let sp = DagDBHOOK1Era.sidecarPath(wp)
            var why: String? = found.unknown
            if let c = found.claim {
                if let m = DagDBHOOK1Era.mismatch(c, digests: replay?.prefixDigests ?? [:], validEnd: validEnd, sidecar: sp) {
                    why = m
                } else {
                    era = .known(offset: c.era, mark: c.mark)
                }
            }
            var reseal: Int? = nil
            if found.refused == nil {
                if !found.exists { reseal = validEnd }                               // the first boot on this log
                else if why != nil { reseal = validEnd }
            }
            if let w = why, !(noRecords && found.refused == nil) {
                era = .unknown(why: w)
                log("  WARN: \(w); the R2 naming is conservative (\"may have\" for every hook bound in the startup snapshot), and the boot goes on")
            }
            if let rs = reseal {
                if let e = DagDBHOOK1Era.write(walPath: wp, era: rs, eraSha256: endDigest, mark: rs, markSha256: endDigest,
                                               dataRoot: dataRoot) {
                    era = .unknown(why: "the era sidecar \(sp) could not be written (\(e))")
                    log("  WARN: the era sidecar \(sp) could not be written (\(e)); the R2 naming is conservative, and the boot goes on")
                } else {
                    eraSeal = EraSeal(offset: rs, eraSha256: endDigest)
                    if !found.exists {
                        era = .known(offset: rs, mark: rs)
                        atEra = nil; atMark = nil                                    // every record replayed above is pre-era
                        log("  WAL: HOOK1 era begins at byte \(rs) of this log (\(sp) written once: the length and a hash of that prefix; the log itself is not written)")
                    } else {
                        if noRecords { era = .known(offset: rs, mark: rs) }
                        log("  WAL: the era sidecar \(sp) re-sealed at byte \(rs); later boots name nothing before it as HOOK1's")
                    }
                }
            } else if case .known(let o, let m)? = era, let c = found.claim {
                eraSeal = EraSeal(offset: o, eraSha256: c.eraSha256)
                log("  WAL: HOOK1 era from byte \(o) of this log, sealed to byte \(m) (\(sp) matches)")
            }
            walHash = replay?.hashState.map { (replay!.hashedLength, $0) }
        }
        // The double step is a
        // bug and is not replayed (recovery steps a bound hook once per tick);
        // the boot names, with ids, the hooks whose frames may differ from what
        // an older daemon held live.
        // The boot never says "did". Without a
        // sidecar a first boot on an older build's log and a current log that lost its
        // sidecar look the same, so a certainty claim could be false; every line
        // says "may have" and gives its evidence when there is any ("the
        // restored snapshot lists it N times": only an older build's restore writes
        // that). Ticks in [era, mark) are this build's own and never named; ticks
        // past the mark are named as possibly an older build's or a crash tail.
        if snapshot != nil, replay != nil {
            var known = false
            if case .known? = era { known = true }
            var may: [String] = [], past: [String] = []
            for m in twin.restoredBoundHooks {
                guard let c = twin.clocks.get(m.clockId), let h = twin.hooks.get(m.hookId) else { continue }
                let evidence = m.times >= 2 ? "the restored snapshot lists it \(m.times) times"
                    : m.times == 1 ? "listed once in the startup snapshot" : "bound in the startup snapshot, not on its clock's list"
                if known {
                    let tE = atEra?.ticks[m.clockId] ?? c.clock.tick, fE = atEra?.frames[m.hookId] ?? h.hook.t
                    let tM = atMark?.ticks[m.clockId] ?? c.clock.tick, fM = atMark?.frames[m.hookId] ?? h.hook.t
                    if tE > m.tick {
                        may.append("\(m.hookId) on clock \(m.clockId) (\(evidence); \(tE - m.tick) tick(s) before the era's start replayed, frame \(m.t) -> \(fE) at one step per tick)")
                    }
                    if c.clock.tick > tM {
                        past.append("\(m.hookId) on clock \(m.clockId) (\(evidence); \(c.clock.tick - tM) tick(s) replayed past the mark, frame \(fM) -> \(h.hook.t) at one step per tick)")
                    }
                } else if c.clock.tick > m.tick {
                    may.append("\(m.hookId) on clock \(m.clockId) (\(evidence); \(c.clock.tick - m.tick) tick(s) replayed, frame \(m.t) -> \(h.hook.t) at one step per tick)")
                }
            }
            let v = replay.map { "log v\($0.fileVersion)" } ?? ""
            if !may.isEmpty {
                let why = known
                    ? "ticks before the HOOK1 era of hooks bound in the startup snapshot: a pre-HOOK1 restore listed a bound hook once more than its file did, after a LOAD or a restart, and the log does not record which ran"
                    : "the HOOK1 era is unknown, so every replayed tick of a hook bound in the startup snapshot is counted as possibly pre-HOOK1"
                log("  Twin: recovery single-stepped \(may.count) hook(s) that the pre-HOOK1 daemon may have double-stepped live (\(v); \(why));"
                    + " the double step is a bug and is not replayed, so if it happened, their frames differ from that daemon's live frames: "
                    + may.joined(separator: "; "))
            }
            if !past.isEmpty, case .known(_, let mk)? = era {
                log("  Twin: recovery single-stepped \(past.count) hook(s) over ticks past the era sidecar's high-water mark (byte \(mk)) that the"
                    + " pre-HOOK1 daemon may have double-stepped live (\(v); bytes HOOK1 did not seal: an older build's appends after"
                    + " a rollback, or this build's own tail after a crash, so the line can be a false alarm but never a missed double step);"
                    + " if it happened, their frames differ from that daemon's live frames: " + past.joined(separator: "; "))
            }
        }

        // A recovered state
        // holding a slot into a register (S4: only an older log can
        // replay one) is never a dead end. SAVE, the autosave and the
        // writers refuse it; the boot names every such slot and the way out.
        let s4 = engine.slotsIntoRegisters()
        if !s4.isEmpty {
            var regs: [Int] = []
            for x in s4 where regs.last != x.register { regs.append(x.register) }
            log("  WARN: the recovered state holds \(s4.count) slot(s) into a register (S4), which SAVE, the autosave and the writers refuse: "
                + s4.map { "node \($0.register) slot \($0.slot) (source node \($0.source))" }.joined(separator: ", ")
                + "; the way out, per register (\(regs.map(String.init).joined(separator: ", "))): CLEAR <dst> EDGES (drops its combinational inputs) or CLEAR <dst> BACK_EDGES (unmakes the register)")
        }

        // Partial detector for a misconfigured path: the loaded snapshot is
        // older than the WAL's last checkpoint, so records between the two
        // were skipped. Ticks are the only clock both carry; twin-only
        // activity does not advance them, so this catches some cases, not all.
        if let s = snapshot, let r = replay, UInt64(s.fileTicks) < r.checkpointEpoch {
            if r.boundAtOffset != nil {
                // Bound, so the logged records since the snapshot
                // were replayed; what the log does not carry (TICK) was not.
                log("  WARN: startup snapshot (ticks=\(s.fileTicks)) is older than the WAL's last checkpoint (epoch \(r.checkpointEpoch)); the logged records since it were replayed from its bind record, the ticks since it are not in the WAL — point DAGDB_STARTUP_LOAD at the file the last SAVE wrote")
            } else {
                log("  WARN: startup snapshot (ticks=\(s.fileTicks)) is older than the WAL's last checkpoint (epoch \(r.checkpointEpoch)); records between them were NOT replayed — point DAGDB_STARTUP_LOAD at the file the last SAVE wrote")
            }
        }
        return Result(snapshot: snapshot, replay: replay, replayError: replayError, eraSeal: eraSeal, walHash: walHash,
                      walFound: walFound)
    }
}
