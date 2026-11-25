/// The one logged sweep after recovery.
///
/// A HOOK CLOSE in older builds left the closed hook's id on its clock. Recovery
/// keeps such ids (from the startup snapshot, and from the older TWIN_CLOSE
/// records the WAL replays) because they are the era marker: a CLOCK ADVANCE
/// replayed against one is an older record and replays as the old daemon
/// ran it. Once recovery is done they mark nothing more, and a live clock must
/// never hold one, so the daemon removes every one of them with ONE logged
/// TWIN_HOOK_SWEEP record (the log goes to version 6 on demand) and says so at
/// boot, zero included. A restart after it replays that record, so the next
/// boot sweeps 0.
import Foundation
import DagDB

extension DagDBCommandHandler {
    /// Run once, after recovery and after the WAL appender is open, before the
    /// first command. Returns the boot line.
    public func sweepDanglingHookIdsAfterRecovery() -> String {
        #if DEBUG || DAGDB_FAULT_INJECTION
        // Test seam: the recovered state exactly as replay left it.
        if DagDBFaultInjection.fires("SKIP_HOOK_SWEEP") {
            return "Twin: the sweep was skipped (DAGDB_FI_SKIP_HOOK_SWEEP, a gate seam); dangling hook ids: \(twin.danglingHookBindings().count)"
        }
        #endif
        let found = twin.danglingHookBindings()
        let head = "Twin: swept \(found.count) dangling hook ids left by pre-HOOK1 logs"
        guard !found.isEmpty else { return "Twin: swept 0 dangling hook ids left by pre-HOOK1 logs (0 removed)" }
        let names = found.map { "\($0.clockId):\($0.hookId)" }.joined(separator: ", ")
        let op = TwinOp.hookSweep(bindings: found)
        guard let wal = walAppender else {
            // Nothing records an unlogged
            // sweep, so the ids come back with the startup snapshot at the next
            // boot; a SAVE to it writes the state without them.
            do { try twin.apply(op) } catch {
                return "Twin: the sweep of \(found.count) dangling hook ids (\(names)) did not apply (\(Reply.errorWords(error)))"
            }
            let save = startupSnapshotPath.map { "a SAVE \($0)" } ?? "a SAVE to the startup snapshot"
            return "\(head) (\(found.count) removed: \(names)); not logged (the WAL is off), so every boot sweeps them again"
                + " until \(save) writes the state without them"
        }
        do {
            _ = try wal.twins([op])
        } catch {
            // A version-1 log cannot take the record (and an append can fail).
            // The way out is named.
            danglingSweepFailure = Reply.errorWords(error)
            return "Twin: swept 0 dangling hook ids left by pre-HOOK1 logs (0 removed): \(found.count) found (\(names)),"
                + " and their sweep record was not written (\(Reply.errorWords(error))); they stay, and CLOCK ADVANCE refuses those clocks by"
                + " name, until the log is replaced: \(logReplaceSteps(then: "its recovery sweeps them with one logged record"))"
        }
        do {
            try twin.apply(op)
        } catch {
            return "Twin: the sweep of \(found.count) dangling hook ids (\(names)) was logged but did not apply (\(Reply.errorWords(error)))"
        }
        return "\(head) (\(found.count) removed, one TWIN_HOOK_SWEEP record: \(names))"
    }

    /// The operator steps that put a log
    /// which cannot be upgraded in place (version 1 for TWIN_HOOK_SWEEP and
    /// the notes; version 1 or 2 for the version-2 and -3 opcodes) behind
    /// this daemon: SAVE to the startup path, stop, move the log aside,
    /// restart. The daemon then loads that snapshot and opens a fresh log,
    /// stamped version 3, which upgrades itself on demand to whatever a record
    /// needs. (SAVE and LOAD through the wire do not do it: a rebase writes a
    /// snapshot and a checkpoint into the same log, whose header keeps its
    /// version.)
    func logReplaceSteps(then: String) -> String {
        let log = walAppender?.path ?? "the log (DAGDB_WAL)"
        // A write between the SAVE and the
        // stop lands in the log that is then moved aside, so it is lost.
        let quiet = "first stop every writer (a write between this SAVE and the stop stays in the log moved aside, and is lost); then "
        if let s = startupSnapshotPath {
            return quiet + "SAVE \(s), stop the daemon, move \(log) aside and start it again (it loads \(s) and opens a fresh"
                + " version-3 log; \(then))"
        }
        return quiet + "SAVE a snapshot to a file, stop the daemon, move \(log) aside and start it again with DAGDB_STARTUP_LOAD"
            + " naming that file (it loads the file and opens a fresh version-3 log; \(then))"
    }

    // MARK: - After a failed rebase, writes are refused

    /// While a loader's durable snapshot to the base has failed, the live
    /// state is not the durable base: a record appended now would replay on
    /// the pre-load base after a restart (the hazard `rebaseAfterLoad`
    /// exists for). Every command that appends to the WAL or changes the
    /// engine or twin state is refused, by name, before any change. Allowed:
    /// reads; `SAVE <base>` (it makes the loaded state durable and clears the
    /// hold); the four loaders (a successful rebase clears it; `LOAD <base>`
    /// returns to the durable state); the exporters (SAVE JSON / SAVE CSV /
    /// EXPORT MORTON / BACKUP INIT / APPEND / COMPACT / SAVE TILED write files,
    /// no record); the tiled routers (their own files); reader sessions.
    /// Exhaustive over `DSLCommand`, so a new verb must be placed.
    func rebasePendingRefusal(_ cmd: DSLCommand) -> String? {
        guard let held = rebasePending else { return nil }
        let refused: Bool
        switch cmd {
        case .save(let path, _):
            refused = (path as NSString).standardizingPath != (held.base as NSString).standardizingPath
        case .load, .loadJSON, .loadCSV, .backupRestore,
             .saveJSON, .saveCSV, .exportMorton, .backupInit, .backupAppend, .backupCompact, .backupInfo,
             .saveTiled, .tiledOpen, .tiledBFS, .tiledSelect, .tiledStatus, .tiledList, .tiledClose, .tiledTick,
             .tiledGetTruth, .openReader, .closeReader, .listReaders, .reader,
             .status, .nodes, .traverse, .getTruth, .graphInfo, .validateGraph, .distance, .bfsDepths, .truthSlice,
             .selectByTruthRank, .ancestry, .similarDecisions, .getTrit, .ttableGet, .dslParse, .unknown:
            refused = false
        case .twin(let t):
            refused = !t.isReadOnly || { if case .foldRun = t { return true }; return false }()
        case .tick, .tickSync, .eval, .tickUntilStable, .setTruth, .setWeight, .setValue, .setRank, .setLUT,
             .connect, .clearEdges, .connectBack, .clearBackEdges, .importMorton, .setRanksBulk, .setLutsBulk,
             .setNeighborsBulk, .connectBackBulk, .setTruthBulk, .setLuts, .setTruthFill, .composeLUT, .setMode,
             .setTTableId, .setThresh, .setTrit, .ttableDefine, .ttablePreset, .setModesBulk, .setTTableIdsBulk,
             .setThreshBulk, .ttableBulk:
            refused = true
        }
        guard refused else { return nil }
        return "ERROR wal: refused: \(held.verb)'s durable snapshot to \(held.base) failed, so the live state is not the"
            + " durable base and a write now would replay on the pre-load base after a restart; SAVE \(held.base) makes"
            + " the loaded state durable, or LOAD \(held.base) returns to the durable state; nothing changed"
    }

    // MARK: - The WAL on and no startup snapshot

    /// With the WAL on and no startup snapshot path, a loader never rebases:
    /// a restart replays the whole log over an empty engine, and every
    /// relative record after the load lands on the wrong base. Every loader
    /// (the four that replace the state without a WAL record: LOAD, LOAD
    /// JSON, LOAD CSV, BACKUP RESTORE) is refused before any change.
    func loaderModeRefusal(_ verb: String) -> String? {
        guard walAppender != nil, startupSnapshotPath == nil else { return nil }
        return "ERROR wal: \(verb) refused: the WAL is on and no startup snapshot is set, so a restart replays the log"
            + " over an empty engine and every record after this load would replay on the wrong base; set"
            + " DAGDB_STARTUP_LOAD and restart the daemon, and \(verb) then makes its load durable; nothing loaded"
    }

    /// The shutdown
    /// autosave is not a command, so the hold's guard never saw it. While the
    /// hold is on it does not run: an autosave to the base would make the
    /// loaded state durable (the failed load's reply promised the pre-load
    /// state), and one to another path would append a bind record and a
    /// checkpoint during the hold. The shutdown line names the skip.
    public func autosaveAtShutdown(path: String) -> String {
        withContainment { autosaveInRoot(path: path) }
    }

    private func autosaveInRoot(path: String) -> String {
        if let held = rebasePending {
            return "autosave skipped: the live state is not the durable base (rebase pending to \(held.base)); the loaded"
                + " state is not kept; SAVE \(held.base) before stopping to keep it"
        }
        return durableSnapshot(path: path)
    }

    /// Check before change. A loader that
    /// keeps the twin state (LOAD JSON, LOAD CSV, BACKUP RESTORE: their files
    /// carry no twin section) and is made durable by a rebase would meet the
    /// rebase's known refusal, a record whose header HEADER CHECK refuses,
    /// only after the load, and the hold would then refuse RECORD
    /// CLOSE too (a trap with no way out). It is refused before anything is loaded,
    /// naming RECORD CLOSE. LOAD replaces the twin state with its file's (whose
    /// JSON cannot hold a nan), so its rebase never meets this refusal.
    func nanRecordLoaderRefusal(_ verb: String) -> String? {
        guard walAppender != nil, startupSnapshotPath != nil else { return nil }
        let ids = twin.recordsWithNonFiniteHeaders
        guard !ids.isEmpty else { return nil }
        return "ERROR bad_value: \(verb) refused: RECORD \(ids.joined(separator: ", ")) carries a header HEADER CHECK refuses"
            + " (replayed from a log older than this build), so this load's durable snapshot would refuse and leave the"
            + " loaded state not durable; " + ids.map { "RECORD CLOSE \($0)" }.joined(separator: ", ")
            + ", then \(verb); nothing loaded"
    }

    /// Seal the era sidecar's
    /// high-water mark at the log's DURABLE length, from a copy of the
    /// appender's running hash (no read of the log, no buffer of its size; the
    /// hash never passes the last fsync, so a crash cannot seal bytes the log
    /// did not keep). Nil on success or when there is nothing to seal.
    @discardableResult
    public func sealEraMark() -> String? {
        guard let s = eraSeal, let w = walAppender else { return nil }
        let d = w.durableDigest()
        return DagDBHOOK1Era.write(walPath: w.path, era: s.offset, eraSha256: s.eraSha256, mark: d.length, markSha256: d.sha256,
                                   dataRoot: dataRoot)
    }

    /// The shutdown's line for that seal (nil when there is no sidecar to seal).
    /// Everything written is made durable first, so the mark covers the log.
    public func sealEraMarkAtShutdown() -> String? {
        withContainment { sealEraMarkAtShutdownInRoot() }
    }

    private func sealEraMarkAtShutdownInRoot() -> String? {
        guard eraSeal != nil, let w = walAppender else { return nil }
        w.barrier()
        if let why = sealEraMark() { return "WAL: the era sidecar's mark was not sealed at shutdown (\(why)); the next boot names this build's ticks since its last seal \"may have\"" }
        return "WAL: the era sidecar sealed at byte \(w.durableDigest().length) (\(DagDBHOOK1Era.sidecarPath(w.path)))"
    }

    /// The boot warning of that mode, once at startup (nil in any other).
    public func walWithoutStartupWarning() -> String? {
        guard walAppender != nil, startupSnapshotPath == nil else { return nil }
        return "WARN: the WAL is on and no startup snapshot is set (DAGDB_STARTUP_LOAD): a restart replays the log over an"
            + " empty engine, so it never recovers a SAVE or a TICK, and LOAD, LOAD JSON, LOAD CSV and BACKUP RESTORE are refused"
    }

    /// A WAL append's ERROR line, every site.
    /// A refusal caused by the log's version (`opcodeNeedsVersion`, thrown
    /// before anything is written) names the way to a log that takes it.
    func walAppendError(_ error: Error) -> String {
        if let e = error as? DagDBWAL.WALError, case .opcodeNeedsVersion = e {
            return "ERROR wal: append: \(Reply.errorWords(error)); nothing written; this log cannot be upgraded in place: "
                + logReplaceSteps(then: "the fresh log takes this record")
        }
        return Reply.errorLine("wal", verb: "append", error)
    }

    /// An opener whose next id is still open
    /// (its 32-bit id space wrapped) is refused before the WAL, in the words
    /// the registry's `duplicateId` used after it.
    func hook1MintRefusal(_ verb: String, prefix: Character) -> String? {
        guard let id = twin.mintCollision(prefix: prefix) else { return nil }
        return "ERROR bad_value: duplicate id: \(id); \(verb) would mint an id that is still open (the id counter"
            + " wrapped past 2^32); nothing written"
    }
}
