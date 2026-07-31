/// DagDB Daemon — GPU graph engine server.
///
/// Runs the DagDB Metal engine as a standalone daemon process.
/// Listens on Unix domain socket for DSL commands.
/// Shares results via POSIX shared memory (zero-copy on UMA).
///
/// Usage: dagdb-daemon [--grid <size>] [--socket <path>] [--shm <name>]

import Foundation
import DagDB
import DagDBDaemonKit

print("══════════════════════════════════════════════════════════")
print("  DagDB Daemon v0.1 — GPU Graph Engine Server")
print("══════════════════════════════════════════════════════════")

// Parse arguments
var gridSize = 256       // default: 256x256 = 65K nodes
var socketPathExplicit: String? = nil
var shmName = "/dagdb_shm"
var maxRank = 16

let args = CommandLine.arguments
for i in 0..<args.count {
    if args[i] == "--grid" && i + 1 < args.count { gridSize = Int(args[i+1]) ?? gridSize }
    if args[i] == "--socket" && i + 1 < args.count { socketPathExplicit = args[i+1] }
    if args[i] == "--shm" && i + 1 < args.count { shmName = args[i+1] }
    if args[i] == "--max-rank" && i + 1 < args.count { maxRank = Int(args[i+1]) ?? maxRank }
}

// Phase 4 of env-split: socket path derives from DAGDB_ENV when not
// explicit. /tmp/dagdb-<env>.sock for env-bound daemons; legacy
// /tmp/dagdb.sock when neither --socket nor DAGDB_ENV is set.
let socketPath: String = {
    if let explicit = socketPathExplicit { return explicit }
    if let env = ProcessInfo.processInfo.environment["DAGDB_ENV"], !env.isEmpty {
        let allowed: Set<String> = ["dev", "test", "prod"]
        if allowed.contains(env) {
            return "/tmp/dagdb-\(env).sock"
        }
    }
    return "/tmp/dagdb.sock"
}()

let width = gridSize
let height = gridSize
let nodeCount = width * height

print("  Grid: \(width)x\(height) = \(nodeCount) nodes")
print("  Socket: \(socketPath)")
print("  Shared memory: \(shmName)")
print("  Max rank: \(maxRank)")

// ── Initialize engine ──

print("\n  Initializing hex grid...")
let grid = HexGrid(width: width, height: height)
print("  7-coloring: \(grid.colorGroups.map { $0.count })")

var state = DagDBState(width: width, height: height)
print("  State buffers allocated")

print("  Creating Metal engine...")
let engine: DagDBEngine
do {
    engine = try DagDBEngine(grid: grid, state: state, maxRank: maxRank)
} catch {
    print("  FATAL: \(error)")
    exit(1)
}
print("  Engine ready. GPU: \(engine.device.name)")

// Zero the neighbor table so DagDB starts with no DAG edges. HexGrid initializes
// neighbors to the spatial hex adjacency (useful for Savanna-style diffusion);
// DagDB only uses CONNECT to populate edges, so we need a clean slate here.
// Kernel tolerates -1 slots (dagdb.metal:46,76).
do {
    let nbPtr = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)
    for i in 0..<(nodeCount * 6) { nbPtr[i] = -1 }
}

// ── Write-ahead log ──
// Opt-in via DAGDB_WAL env var. When set, every mutation (setTruth/setRank/
// setLUT) is appended to the log and fsync'd before the engine buffer is
// touched. On startup we replay any records already on disk so a crash
// between snapshots is recoverable.
let walPath: String? = {
    if let env = ProcessInfo.processInfo.environment["DAGDB_WAL"], !env.isEmpty {
        return env
    }
    return nil
}()
// fsync policy (G73). DAGDB_WAL_FSYNC=grouped:N:MS opts into group-commit
// (fsync deferred to the earlier of N unsynced records / MS ms / a barrier);
// absent or unparseable = .everyRecord (byte-identical pre-G73 durability).
// prod ALWAYS ignores the var and stays per-record + F_FULLFSYNC — the
// durability guarantee for the prod env is not tunable. Asserted below.
let walFsyncPolicy: DagDBWAL.FsyncPolicy = {
    let isProd = ProcessInfo.processInfo.environment["DAGDB_ENV"] == "prod"
    guard !isProd else { return .everyRecord }
    guard let raw = ProcessInfo.processInfo.environment["DAGDB_WAL_FSYNC"],
          !raw.isEmpty else { return .everyRecord }
    let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
    if parts.count == 3, parts[0] == "grouped",
       let n = Int(parts[1]), let ms = Int(parts[2]), n > 0, ms > 0 {
        return .grouped(n: n, ms: ms)
    }
    print("  WAL: unrecognized DAGDB_WAL_FSYNC='\(raw)' — using everyRecord")
    return .everyRecord
}()
// Invariant: prod is never grouped, regardless of the env var.
assert(ProcessInfo.processInfo.environment["DAGDB_ENV"] != "prod"
       || walFsyncPolicy == .everyRecord,
       "prod WAL fsync policy must be everyRecord")

var walAppender: DagDBWAL.Appender? = nil
if let p = walPath {
    do {
        // Replay any existing log first, before opening appender for new writes.
        if FileManager.default.fileExists(atPath: p) {
            let r = try DagDBWAL.replay(engine: engine, nodeCount: nodeCount, path: p)
            print("  WAL: replayed \(r.recordsAfterCheckpoint) records past epoch \(r.checkpointEpoch)")
            if let off = r.truncatedAtOffset {
                print("  WAL: dropped truncated tail at offset \(off)")
            }
        }
        walAppender = try DagDBWAL.Appender(path: p, nodeCount: nodeCount,
                                            policy: walFsyncPolicy)
        switch walFsyncPolicy {
        case .everyRecord:
            print("  WAL: appending to \(p) (fsync: everyRecord)")
        case .grouped(let n, let ms):
            print("  WAL: appending to \(p) (fsync: grouped n=\(n) ms=\(ms))")
        }
    } catch {
        print("  WAL: init failed: \(error) — continuing without WAL")
    }
}

// ── Shared memory for results ──
// Layout: [4 bytes: row count] [4 bytes: row size] [data rows...]
// Each row (v3, post 2026-04-21 u64 widen):
//   [8 bytes: node_id] [8 bytes: rank] [1 byte: truth] [1 byte: type] [6 bytes: pad]
//   = 24 bytes.

let resultRowSize = 24  // node_id(8) + rank(8) + truth(1) + type(1) + pad(6). v3 post u64 widen.
let maxResultRows = nodeCount
let shmSize = 8 + maxResultRows * resultRowSize  // header + rows

// ── Reader sessions (T7 snapshot-on-read MVCC) ──
// Opened by OPEN_READER, closed by CLOSE_READER. Reads under READER <id>
// route to the snapshot engine; writes stay on primary.
let sessionManager = DagDBReaderSessionManager()

// ── Secondary index (T15) ──
// (truth, rank-range) fast-path. Lazy rebuild on dirty flag; any mutation
// that can change a node's truth or rank marks dirty. Next SELECT rebuilds.
let truthRankIndex = TruthRankIndex()

// Use file-based shared memory as fallback (shm_open has Swift availability issues)
let shmPath = "/tmp/dagdb_shm_file"
let shmFd: Int32

// Create backing file. 0600 — daemon owner only; live graph state is not
// world-readable. Earlier builds used 0666, which exposed the mapping to
// any local user.
FileManager.default.createFile(atPath: shmPath, contents: nil)
shmFd = open(shmPath, O_RDWR | O_CREAT, 0o600)
_ = chmod(shmPath, 0o600)  // defense-in-depth if file pre-existed with looser mode
guard shmFd >= 0 else {
    print("  FATAL: Cannot create shared memory file: \(String(cString: strerror(errno)))")
    exit(1)
}
ftruncate(shmFd, off_t(shmSize))

let shmPtr = mmap(nil, shmSize, PROT_READ | PROT_WRITE, MAP_SHARED, shmFd, 0)
guard shmPtr != MAP_FAILED else {
    print("  FATAL: mmap failed: \(String(cString: strerror(errno)))")
    exit(1)
}
let shmBase = shmPtr!
print("  Shared memory: \(shmSize) bytes at \(shmPath)")

// ── Tick counter ──

// ── Env binding + path guard ──
// DSL clients can supply file paths to SAVE/LOAD/BACKUP/JSON/CSV/MORTON verbs.
// We never allow `..` traversal segments. The dataRoot enforces that paths
// resolve under one of:
//   1. DAGDB_ENV ∈ {dev, test, prod} — derives DATA_ROOT to ~/dag_databases/<env>/
//   2. DAGDB_DATA_ROOT (legacy explicit path)
//   3. neither set — paths unguarded (single-user laptop default; warned)
//
// If both are set, they must agree (derived ENV path == DAGDB_DATA_ROOT after
// symlink resolution); otherwise daemon refuses to start.
//
// Phase 2 of dev/test/prod env split. See docs/dev-test-prod-memo-2026-05-01.md.
//
// Grace-period default per dag's deferred decision: missing DAGDB_ENV warns
// rather than hard-fails, so existing deployments keep working until plist
// updates land everywhere. Tighten to required after the migration window.

let dagdbEnv: String? = {
    guard let v = ProcessInfo.processInfo.environment["DAGDB_ENV"], !v.isEmpty else { return nil }
    return v
}()

let dataRoot: String? = {
    let homeDir = NSHomeDirectory()
    let envValue = ProcessInfo.processInfo.environment["DAGDB_DATA_ROOT"]
    let envPathSet = (envValue?.isEmpty == false)

    // Validate DAGDB_ENV value if present.
    if let envName = dagdbEnv {
        let allowed: Set<String> = ["dev", "test", "prod"]
        guard allowed.contains(envName) else {
            FileHandle.standardError.write(Data(
                "FATAL: DAGDB_ENV='\(envName)' not in {dev, test, prod}\n".utf8
            ))
            exit(2)
        }

        let derived = "\(homeDir)/dag_databases/\(envName)"
        let derivedResolved = (derived as NSString).resolvingSymlinksInPath

        // If both env vars set, they must agree after symlink resolution.
        if envPathSet, let dr = envValue {
            let drResolved = (dr as NSString).resolvingSymlinksInPath
            if drResolved != derivedResolved {
                FileHandle.standardError.write(Data(
                    "FATAL: DAGDB_ENV='\(envName)' implies '\(derivedResolved)' but DAGDB_DATA_ROOT='\(drResolved)' — conflict; remove one or align them\n".utf8
                ))
                exit(2)
            }
        }
        return derivedResolved
    }

    // No DAGDB_ENV. Fall back to legacy DAGDB_DATA_ROOT if set.
    if envPathSet, let dr = envValue {
        return (dr as NSString).resolvingSymlinksInPath
    }

    // Neither set — grace period: warn but run unguarded.
    let warn = "WARN: neither DAGDB_ENV nor DAGDB_DATA_ROOT set — paths unguarded. Set DAGDB_ENV ∈ {dev, test, prod} for env-bound operation.\n"
    FileHandle.standardError.write(Data(warn.utf8))
    return nil
}()

if let env = dagdbEnv { print("  Env: \(env)") }
if let r = dataRoot { print("  Data root: \(r)") }


// ── Command handler ──
// The DSL dispatch lives in DagDBDaemonKit so it can be tested against a real
// engine without a socket or mmap'd shared memory (Fable review T1). This shim
// builds one handler over the live engine + shm and routes each socket line
// through it. The handler owns tickCount and walAppender from here on.
let handler = DagDBCommandHandler(
    engine: engine,
    grid: grid,
    nodeCount: nodeCount,
    width: width,
    height: height,
    maxRank: maxRank,
    tickCount: 0,
    walAppender: walAppender,
    sessionManager: sessionManager,
    truthRankIndex: truthRankIndex,
    shmBase: shmBase,
    resultRowSize: resultRowSize,
    dataRoot: dataRoot,
    dagdbEnv: dagdbEnv
)

// ── Socket server ──
//
// Serialization guarantee: the SocketServer accept loop (SocketServer.swift:64-71)
// is single-threaded and handles one client at a time. Each command runs fully
// through handleCommand() before the next accept. DagDBEngine.tick() calls
// waitUntilCompleted() (DagDBEngine.swift:159) so the GPU finishes before the
// Swift call returns. Therefore TICK, SAVE, LOAD, and VALIDATE cannot interleave
// at the buffer level — no mutex required while this server model holds.

let server = SocketServer(path: socketPath)
server.onCommand = { command in
    let response = handler.handle(command)
    print("  [\(handler.tickCount)] \(command) → \(response.prefix(80))")
    return response
}

// Auto-snapshot path (optional): daemon writes here on graceful termination
// so an external SIGTERM/SIGINT still recovers cleanly.
let autoSnapshotPath: String? = {
    if let env = ProcessInfo.processInfo.environment["DAGDB_AUTOSAVE"], !env.isEmpty {
        return env
    }
    return nil
}()

@Sendable func gracefulShutdown() {
    print("\n  Shutting down...")
    // G73 forced barrier: flush any deferred WAL tail before we exit so a
    // grouped-commit daemon loses nothing on a graceful shutdown.
    handler.walAppender?.barrier()
    if let path = autoSnapshotPath {
        do {
            let r = try DagDBSnapshot.save(
                engine: engine, nodeCount: nodeCount,
                gridW: width, gridH: height,
                tickCount: handler.tickCount, path: path,
                compressed: false
            )
            print("  Auto-snapshot: \(r.bytesWritten) bytes to \(path) (\(String(format: "%.1f", r.elapsedMs))ms)")
        } catch {
            print("  Auto-snapshot failed: \(error)")
        }
    }
    exit(0)
}

signal(SIGINT)  { _ in gracefulShutdown() }
signal(SIGTERM) { _ in gracefulShutdown() }

print("\n  DagDB Daemon ready.")
print("  Test: echo 'STATUS' | nc -U \(socketPath)")
print("══════════════════════════════════════════════════════════\n")

try server.start()
