import Foundation
import DagDB

/// Startup recovery (roadmap item 4, 2026-09-09).
///
/// Before this, a daemon restart after `SAVE` came up empty: `SAVE` writes a
/// snapshot and then a WAL checkpoint, startup replays only records past the
/// last checkpoint, and nothing loaded the snapshot. Operators had to issue
/// `LOAD` by hand. Found by the socket smoke on 2026-09-06.
///
/// `recover` does the whole startup sequence in one place so `main.swift`
/// and the tests cannot drift apart:
///
///   1. If `snapshotPath` is set (env `DAGDB_STARTUP_LOAD`) and the file
///      exists, load it into the engine + twin state. A snapshot that
///      cannot be read is a hard error — the daemon must not start empty
///      over a WAL whose checkpoint already assumes that state, or the two
///      would silently diverge. A missing file is fine (first boot).
///   2. If `walPath` is set and the file exists, replay records past the
///      last checkpoint on top. Because every durable snapshot (`SAVE` and
///      the autosave on shutdown) appends a checkpoint right after itself,
///      snapshot + replayed tail = the state at the moment the daemon last
///      spoke. WAL failures are reported in `replayError`, not thrown, so
///      the caller keeps the pre-existing "continue without WAL" behaviour.
///
/// Opt-in: without `DAGDB_STARTUP_LOAD` the daemon behaves exactly as before.
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
        /// Tick counter the handler should start from.
        public var tickCount: UInt32 { snapshot?.fileTicks ?? 0 }
    }

    public enum StartupError: Error, CustomStringConvertible {
        case snapshotPathRejected(path: String, reason: String)
        case snapshotUnreadable(path: String, underlying: String)

        public var description: String {
            switch self {
            case .snapshotPathRejected(let p, let r):
                return "startup snapshot path rejected: '\(p)' — \(r)"
            case .snapshotUnreadable(let p, let u):
                return "startup snapshot unreadable: '\(p)' — \(u)"
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
        log: (String) -> Void = { print($0) }
    ) throws -> Result {
        var snapshot: DagDBSnapshot.LoadResult? = nil

        if let sp = snapshotPath {
            if let why = pathViolation(sp, dataRoot: dataRoot) {
                throw StartupError.snapshotPathRejected(path: sp, reason: why)
            }
            if FileManager.default.fileExists(atPath: sp) {
                do {
                    let r = try DagDBSnapshot.load(
                        engine: engine, nodeCount: nodeCount,
                        gridW: width, gridH: height, path: sp,
                        daemonEnv: DagDBSnapshot.SnapshotEnv.from(envString: dagdbEnv),
                        twin: twin
                    )
                    truthRankIndex.markDirty()
                    engine.markRankTopologyDirty()
                    snapshot = r
                    log("  Startup: loaded snapshot \(sp) — nodes=\(r.fileNodeCount) ticks=\(r.fileTicks) twin_open=\(twin.totalOpen) (\(String(format: "%.1f", r.elapsedMs))ms)")
                } catch {
                    throw StartupError.snapshotUnreadable(path: sp, underlying: "\(error)")
                }
            } else {
                log("  Startup: no snapshot at \(sp) yet — starting empty")
            }
        }

        var replay: DagDBWAL.ReplayResult? = nil
        var replayError: Error? = nil
        if let wp = walPath, FileManager.default.fileExists(atPath: wp) {
            do {
                let r = try DagDBWAL.replay(engine: engine, nodeCount: nodeCount, path: wp, twin: twin)
                replay = r
                // C1b · a replay that skipped anything is never silent. The
                // count is on the line whether or not it is zero, so an
                // operator reading two boots side by side sees the change;
                // the reason histogram only appears when there is one.
                log("  WAL: replayed \(r.recordsAfterCheckpoint) records past epoch \(r.checkpointEpoch) (log v\(r.fileVersion), skipped=\(r.recordsSkipped))")
                if r.recordsSkipped > 0 {
                    log("  WAL: skipped \(r.recordsSkipped) record(s) — \(r.skipReasons.line)")
                }
                if let off = r.truncatedAtOffset {
                    log("  WAL: dropped truncated tail at offset \(off)")
                }
                if r.recordsAfterCheckpoint > 0 {
                    truthRankIndex.markDirty()
                    engine.markRankTopologyDirty()
                }
            } catch {
                replayError = error
            }
        }

        // Partial detector for a misconfigured path: the loaded snapshot is
        // older than the WAL's last checkpoint, so records between the two
        // were skipped. Ticks are the only clock both carry; twin-only
        // activity does not advance them, so this catches some cases, not all.
        if let s = snapshot, let r = replay, UInt64(s.fileTicks) < r.checkpointEpoch {
            log("  WARN: startup snapshot (ticks=\(s.fileTicks)) is older than the WAL's last checkpoint (epoch \(r.checkpointEpoch)); records between them were NOT replayed — point DAGDB_STARTUP_LOAD at the file the last SAVE wrote")
        }
        return Result(snapshot: snapshot, replay: replay, replayError: replayError)
    }
}
