/// DagDB Daemon — GPU graph engine server.
///
/// Runs the DagDB Metal engine as a standalone daemon process.
/// Listens on Unix domain socket for DSL commands.
/// Shares results via POSIX shared memory (zero-copy on UMA).
///
/// Usage: dagdb-daemon --shm-file <path> [--grid <size>] [--socket <path>] [--max-rank <n>] [--mem-budget-gb <GiB>]
/// (--shm-file is required, --shm is refused, an unknown flag or an unparsable number is refused,
/// and so is a number outside its range.)
///
/// The numeric flags' accepted ranges (checked before anything is allocated):
///   --grid n           1 <= n <= 32768. The grid is n x n; HexGrid.refusalReason bounds it (the height axis is the
///                      signed 16-bit Morton cube row, at most 32768, and n^2 must fit the Int32 node index space).
///                      The bound the daemon checks is computed from refusalReason itself, not written as a literal.
///   --max-rank n       1 <= n <= max(16, n_grid^2). The configured rank bound sizes the per-rank tables; no node
///                      of an N-node graph holds a rank of N or more (SET RANK refuses it), so a bound above N
///                      names levels no node can occupy. 16 (the default) is accepted on every grid.
///   --mem-budget-gb G  finite, with the budget floor(G x 2^30) bytes at least 1 and below 2^63: G >= 2^-30
///                      (about 9.31e-10) and G < 2^33 (8,589,934,592).
/// Without these checks an out-of-range number crashed the daemon (exit 251).

import Foundation
import DagDB
import DagDBDaemonKit

// A write to a client that is gone returns
// EPIPE and drops that connection; it never kills the daemon.
// Ignored at daemon start, before anything else runs.
SocketServer.ignoreSIGPIPE()

// Line-buffer stdout: under launchd or a redirect, Foundation's print() is
// fully buffered and a hard kill loses the startup lines (2026-09-09).
setlinebuf(stdout)

// Every line this daemon logs goes through the one reply formatter (escaped, capped), so no
// command, path or file text can forge a log line. A message's leading newlines are kept as blank lines. (Module
// scope: it shadows Swift.print for every print in this file, the startup log closure included.)
func print(_ s: String) {
    var t = Substring(s)
    while t.hasPrefix("\n") { Swift.print(""); t = t.dropFirst() }
    Swift.print(Reply.line(String(t)))
}

print("══════════════════════════════════════════════════════════")
print("  DagDB Daemon v0.1 — GPU Graph Engine Server")
print("══════════════════════════════════════════════════════════")

// Parse arguments, strictly. --shm-file is required (no default, not even under the
// root); --shm is refused by name; an unknown flag, a flag without its value, or a number
// that does not parse is refused with the usage line, never defaulted (earlier builds ignored or defaulted
// every one of them, and a daemon without --shm-file wrote its result rows to /tmp/dagdb_shm_file).
var gridSize = 256       // default: 256x256 = 65K nodes
var socketPathExplicit: String? = nil
var maxRank = 16
// Result-row file shared with readers (--shm-file, required), e.g. beside the data root, so query results
// never land in /tmp.
var shmFileExplicit: String? = nil
// --mem-budget-gb G (GiB) overrides the default budget.
var memBudgetGiB: Double? = nil

let daemonUsage = "usage: dagdb-daemon --shm-file <path> [--grid <n>] [--socket <path>] [--max-rank <n>] [--mem-budget-gb <GiB>]"
func refuseFlags(_ why: String) -> Never {
    let line = "FATAL: \(why)\n\(daemonUsage)\n"
    FileHandle.standardError.write(Data(line.utf8))
    print("  FATAL: \(why)")
    print("  \(daemonUsage)")
    exit(2)
}
do {
    let args = CommandLine.arguments
    var i = 1
    func value(_ flag: String) -> String {
        guard i + 1 < args.count else { refuseFlags("\(flag) needs a value") }
        i += 1
        return args[i]
    }
    func positiveInt(_ flag: String) -> Int {
        let v = value(flag)
        guard let n = Int(v), n > 0 else { refuseFlags("\(flag) needs a positive integer, got '\(v)'") }
        return n
    }
    // The largest square grid HexGrid accepts, found by bisection over its own
    // refusal (every bound in refusalReason grows with n), so the range stated is the grid's own.
    let maxGrid: Int = {
        var lo = 1, hi = 1 << 17                     // refusalReason accepts 1 x 1 and refuses 2^17 x 2^17
        while hi - lo > 1 {
            let m = (lo + hi) / 2
            if HexGrid.refusalReason(width: m, height: m) == nil { lo = m } else { hi = m }
        }
        return lo
    }()
    while i < args.count {
        let a = args[i]
        switch a {
        case "--grid":
            let n = positiveInt(a)
            if let why = HexGrid.refusalReason(width: n, height: n) {
                refuseFlags("--grid \(n) is out of range: 1 to \(maxGrid) (\(why))")
            }
            gridSize = n
        case "--max-rank": maxRank = positiveInt(a)
        case "--socket": socketPathExplicit = value(a)
        case "--shm-file":
            let v = value(a)
            guard !v.isEmpty else { refuseFlags("--shm-file needs a path") }
            shmFileExplicit = v
        case "--mem-budget-gb":
            let v = value(a)
            guard let g = Double(v), g.isFinite, g > 0 else {
                refuseFlags("--mem-budget-gb needs a positive finite number of GiB, got '\(v)'")
            }
            // The budget in bytes, floor(G x 2^30), must be an Int of at least one byte
            // (Int(exactly:) is nil from 2^63 up; without this check, 1e300 trapped converting it).
            guard let b = Int(exactly: (g * Double(DaemonMemoryBudget.gib)).rounded(.down)), b >= 1 else {
                refuseFlags("--mem-budget-gb \(v) is out of range: the budget floor(G x 2^30) bytes must be at least 1"
                            + " and below 2^63 (2^-30 <= G < 2^33 GiB)")
            }
            memBudgetGiB = g
        case "--shm":
            refuseFlags("--shm is refused: the daemon shares its result rows through a file; pass --shm-file <path>")
        default:
            refuseFlags("unknown argument '\(a)'")
        }
        i += 1
    }
    if shmFileExplicit == nil { refuseFlags("--shm-file <path> is required (the result-row file; there is no default)") }
    // --max-rank against the grid it sizes tables for (--grid is in range here, so n^2 fits).
    let rankBound = max(16, gridSize * gridSize)
    if maxRank > rankBound {
        refuseFlags("--max-rank \(maxRank) is out of range: 1 to \(rankBound) (max(16, the node count \(gridSize)x\(gridSize)):"
                    + " no node of an N-node graph holds a rank of N or more)")
    }
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
print("  Max rank: \(maxRank)")
// The memory budget in effect; start_sandbox.sh prints this line.
let memoryBudget = DaemonMemoryBudget.make(nodeCount: nodeCount, overrideGiB: memBudgetGiB)
print("  Memory budget: \(memoryBudget.gibText) GiB (\(memoryBudget.source)\(memoryBudget.source == "default" ? ": min(max(8 GiB, 2 x fixed state), 32 GiB), fixed state 191.0 B/node + 2.55 MB" : ""))"
      + " MallocLargeCache=\(ProcessInfo.processInfo.environment["MallocLargeCache"] ?? "unset")")
// The Metal pool is a fixed reservation in the fixed state, stated here, admitted once: a budget
// that cannot hold the fixed state with it refuses the start by name, before the engine is made.
print("  " + memoryBudget.poolReservationLine)
if let why = memoryBudget.fixedStateRefusal {
    print("  FATAL: \(why); refusing to start")
    exit(2)
}
// The QoS the daemon runs at is the condition its time
// bounds hold under, so it is stated where the daemon starts; start_sandbox.sh prints this line,
// and the machine load the rates were measured at.
let daemonQoS: String = {
    let q = qos_class_self()
    if q == QOS_CLASS_USER_INTERACTIVE { return "user-interactive" }
    if q == QOS_CLASS_USER_INITIATED { return "user-initiated" }
    if q == QOS_CLASS_DEFAULT { return "default" }
    if q == QOS_CLASS_UTILITY { return "utility" }
    if q == QOS_CLASS_BACKGROUND { return "background" }
    return "unspecified"
}()
print("  QoS: \(daemonQoS) (the time bounds were measured at user-interactive QoS, a daemon started from a shell,"
      + " at 1-minute load average 3.0-4.4; background QoS measured about 2x slower; other classes unmeasured)")

// ── Initialize engine ──

print("\n  Initializing hex grid...")
let grid = try HexGrid(width: width, height: height)
print("  7-coloring: \(grid.colorGroups.map { $0.count })")

var state = DagDBState(width: width, height: height)
print("  State buffers allocated")

print("  Creating Metal engine...")
let engine: DagDBEngine
do {
    engine = try DagDBEngine(grid: grid, state: state, maxRank: maxRank)
} catch {
    print("  FATAL: \(Reply.errorWords(error))")
    exit(1)
}
print("  Engine ready. GPU: \(engine.device.name)")
// The engine allocates its ternary lanes on demand; the
// staging copy of them in `state` (11 bytes per node, all BINARY defaults)
// is never read again, so it is released here rather than held for the
// daemon's life.
state.nodeMode = []; state.ttableId = []; state.thrLo = []; state.thrHi = []

// Zero the neighbor table so DagDB starts with no DAG edges. HexGrid initializes
// neighbors to the spatial hex adjacency (useful for Savanna-style diffusion);
// DagDB only uses CONNECT to populate edges, so we need a clean slate here.
// Kernel tolerates -1 slots (dagdb.metal:46,76).
do {
    let nbPtr = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)
    for i in 0..<(nodeCount * 6) { nbPtr[i] = -1 }
}

// ── Twin-spec DSL state ──
// Daemon-global — every connection shares this one instance. Built before
// WAL replay so `.streamOpen`..`.close` records (opcodes 0x20-0x2B) have
// somewhere to land.
let twinState = TwinState()

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
// fsync policy. DAGDB_WAL_FSYNC=grouped:N:MS opts into group-commit
// (fsync deferred to the earlier of N unsynced records / MS ms / a barrier);
// absent or unparseable = .everyRecord (byte-identical to per-record durability).
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

// ── Shared memory for results ──
// Layout: [4 bytes: row count] [4 bytes: row size] [data rows...]
// Each row (v3, post 2026-04-21 u64 widen):
//   [8 bytes: node_id] [8 bytes: rank] [1 byte: truth] [1 byte: type] [1 byte: mode] [5 bytes: pad]
//   = 24 bytes. Byte 18 is the node's mode byte (native ternary tick;
//   it was pad, always 0, before).

let resultRowSize = 24  // node_id(8) + rank(8) + truth(1) + type(1) + mode(1) + pad(5). v3 post u64 widen.
let maxResultRows = nodeCount
let shmSize = 8 + maxResultRows * resultRowSize  // header + rows

// ── Reader sessions (snapshot-on-read MVCC) ──
// Opened by OPEN_READER, closed by CLOSE_READER. Reads under READER <id>
// route to the snapshot engine; writes stay on primary.
let sessionManager = DagDBReaderSessionManager()

// ── Secondary index ──
// (truth, rank-range) fast-path. Lazy rebuild on dirty flag; any mutation
// that can change a node's truth or rank marks dirty. Next SELECT rebuilds.
let truthRankIndex = TruthRankIndex()

// The result-row file (--shm-file, required).
let shmPath = shmFileExplicit!

// Opt-in startup snapshot (DAGDB_STARTUP_LOAD, roadmap item 4) and auto-snapshot path (DAGDB_AUTOSAVE: the daemon
// writes here on graceful termination so an external SIGTERM/SIGINT still recovers cleanly).
let startupSnapshotPath: String? = {
    if let env = ProcessInfo.processInfo.environment["DAGDB_STARTUP_LOAD"], !env.isEmpty {
        return env
    }
    return nil
}()
let autoSnapshotPath: String? = {
    if let env = ProcessInfo.processInfo.environment["DAGDB_AUTOSAVE"], !env.isEmpty {
        return env
    }
    return nil
}()

// The files the daemon itself keeps live, named by their flags.
let daemonConfiguredFiles: [(label: String, path: String?)] = [
    ("DAGDB_WAL", walPath),
    ("DAGDB_WAL's era sidecar", walPath.map { $0 + DagDBHOOK1Era.suffix }),
    ("DAGDB_STARTUP_LOAD", startupSnapshotPath),
    ("DAGDB_AUTOSAVE", autoSnapshotPath),
    ("--socket", socketPath),
    ("--shm-file", shmPath),
]
// Before any write at startup (the result-row file is the first), the configured
// paths, resolved, are pairwise distinct; two flags naming one file refuse the start, named (without this the
// daemon's own startup writes destroyed the WAL or the startup snapshot a --shm-file or --socket named). The one
// pair allowed to name one file is DAGDB_STARTUP_LOAD and DAGDB_AUTOSAVE: the documented round trip, the autosave
// writing the snapshot the next start loads.
if let why = DagDBStartup.configuredPathCollision(daemonConfiguredFiles, allowed: [["DAGDB_STARTUP_LOAD", "DAGDB_AUTOSAVE"]]) {
    print("  FATAL: \(why); refusing to start (nothing written)")
    exit(2)
}
// The literal below is also the build marker scripts/start_sandbox.sh looks for before launch:
// a binary without it predates --shm-file and would write its result rows to /tmp.
print("  Result-row file (--shm-file): \(shmPath)")
let shmFd: Int32

// Create backing file. 0600 — daemon owner only; live graph state is not
// world-readable. Earlier builds used 0666, which exposed the mapping to
// any local user.
// A link or anything but a regular file at the path is refused by name (otherwise
// createFile would replace what was there and open would follow a link swapped in after it). A regular file or no
// file: replaced by a new empty one (createFile, as before: a reader's old mapping keeps the old inode), then
// opened without blocking, no link followed, and checked regular again.
if let k = DaemonFile.lkind(shmPath), k != "regular file" {
    print("  FATAL: --shm-file: \(DaemonFile.Refusal.notRegular(path: shmPath, kind: k)); refusing to start")
    exit(2)
}
// A regular file with more than one hard link is refused by name (another of
// its names may lie outside the data root); checked again on the opened descriptor below, before any write.
if let r = DaemonFile.linkRefusal(at: shmPath) {
    print("  FATAL: --shm-file: \(Reply.errorWords(r)); refusing to start")
    exit(2)
}
FileManager.default.createFile(atPath: shmPath, contents: nil)
shmFd = open(shmPath, O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
guard shmFd >= 0 else {
    print("  FATAL: Cannot create shared memory file: \(DaemonFile.errnoName(errno)) '\(shmPath)' (\(String(cString: strerror(errno))))")
    exit(1)
}
do {
    var st = stat()
    guard fstat(shmFd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
        print("  FATAL: --shm-file: '\(shmPath)' is not a regular file; refusing to start")
        exit(2)
    }
    if st.st_nlink > 1 {
        print("  FATAL: --shm-file: \(DaemonFile.Refusal.linked(path: shmPath, links: Int(st.st_nlink))); refusing to start")
        exit(2)
    }
    let fl = fcntl(shmFd, F_GETFL)
    if fl >= 0 { _ = fcntl(shmFd, F_SETFL, fl & ~O_NONBLOCK) }
}
_ = fchmod(shmFd, 0o600)  // defense-in-depth if file pre-existed with looser mode
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
// Grace-period default per a deferred decision: missing DAGDB_ENV warns
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

// The stale stage directories and temporaries a crashed writer of this daemon left,
// swept under the data root before anything else touches it, and named.
// The live set first (every configured file and what it resolves to), never removed.
print("  " + DagDBStartup.sweepStages(root: dataRoot, live: daemonConfiguredFiles.compactMap { $0.path }))


// ── Startup recovery + write-ahead log appender ──
// Opt-in snapshot load (DAGDB_STARTUP_LOAD, roadmap item 4, 2026-09-09)
// BEFORE WAL replay, then the appender for new writes. The order and the
// reasons live in DagDBStartup.recover; main.swift and the tests share it.
// A configured-but-unreadable snapshot is fatal: starting empty over a WAL
// whose checkpoint assumes that state would silently diverge.
// (DAGDB_STARTUP_LOAD is read above, with the other configured paths.)
// The boot is admitted on what it holds and rebuilds, not only on its reads' true size: the snapshot load
// as LOAD, each window of the log (never the whole log), each replayed record at its live verb's charge, and the state at the end. A refusal names the bytes, the budget and the
// flag with the size to pass, and the daemon does not start (DagDBBootAdmission).
let bootAdmission = DagDBBootAdmission(budget: memoryBudget, engine: engine, twin: twinState)
let startup: DagDBStartup.Result
do {
    startup = try DagDBStartup.recover(
        engine: engine, nodeCount: nodeCount, width: width, height: height,
        dagdbEnv: dagdbEnv, dataRoot: dataRoot,
        twin: twinState, truthRankIndex: truthRankIndex,
        snapshotPath: startupSnapshotPath, walPath: walPath,
        boot: bootAdmission
    )
} catch {
    print("  FATAL: \(Reply.errorWords(error))")
    exit(2)
}

var walAppender: DagDBWAL.Appender? = nil
if let p = walPath {
    if let e = startup.replayError, "\(e)".contains("ERROR out_of_budget") {
        // A log over the memory budget refuses the start by name.
        print("  FATAL: WAL: \(p): \(e); refusing to start")
        exit(2)
    } else if let e = startup.replayError {
        // A log this build cannot use (a version refused by name, a FIFO, a cut header,
        // another grid's log) refuses the start; otherwise the daemon would run on WITHOUT a WAL, silently losing
        // every write's durability.
        print("  FATAL: WAL: \(p) cannot be replayed: \(e); refusing to start without the log DAGDB_WAL names"
              + " (move it aside to start a new log, or start the build that wrote it)")
        exit(2)
    } else {
        do {
            walAppender = try DaemonFile.withRoot(dataRoot) {
                try DagDBWAL.Appender(path: p, nodeCount: nodeCount,
                                      policy: walFsyncPolicy,
                                      prefixHash: startup.walHash,      // one hashing pass
                                      found: startup.walFound)          // the replay's one read
            }
            // A record a crash left unfinished at the log's end
            // (replay dropped it) is cut before the first append.
            if let cut = walAppender?.tornTailCut {
                print("  WAL: cut \(cut.bytes) byte(s) at offset \(cut.offset): \(cut.why) — replay did not apply them; the next record starts at a record boundary")
            }
            switch walFsyncPolicy {
            case .everyRecord:
                print("  WAL: appending to \(p) (fsync: everyRecord)")
            case .grouped(let n, let ms):
                print("  WAL: appending to \(p) (fsync: grouped n=\(n) ms=\(ms))")
            }
        } catch {
            // Refused by name, never "continuing without WAL".
            print("  FATAL: WAL: init failed: \(Reply.errorWords(error)); refusing to start without the log DAGDB_WAL names")
            exit(2)
        }
    }
}

// ── Command handler ──
// The DSL dispatch lives in DagDBDaemonKit so it can be tested against a real
// engine without a socket or mmap'd shared memory. This shim
// builds one handler over the live engine + shm and routes each socket line
// through it. The handler owns tickCount and walAppender from here on.
let handler = DagDBCommandHandler(
    engine: engine,
    grid: grid,
    nodeCount: nodeCount,
    width: width,
    height: height,
    maxRank: maxRank,
    tickCount: startup.tickCount,
    walAppender: walAppender,
    sessionManager: sessionManager,
    truthRankIndex: truthRankIndex,
    shmBase: shmBase,
    resultRowSize: resultRowSize,
    dataRoot: dataRoot,
    dagdbEnv: dagdbEnv,
    twin: twinState,
    startupSnapshotPath: startupSnapshotPath   // a loader moves recovery's base here
)
handler.eraSeal = startup.eraSeal   // the mark this handler seals
// The socket and the result-row file join the WAL and its era sidecar as files no
// writer creates, replaces, truncates or removes (without this, SAVE onto the socket replaced it: the daemon went deaf).
handler.daemonFiles = [DaemonFile.canonicalPath(socketPath): "the daemon's socket",
                       DaemonFile.canonicalPath(shmPath): "the daemon's result-row file (--shm-file)"]
// The hook ids an older log or snapshot left on
// a clock, removed by one logged record after recovery; the count, 0 included.
print("  " + handler.sweepDanglingHookIdsAfterRecovery())
// The mode in which loaders are refused, named once.
if let w = handler.walWithoutStartupWarning() { print("  " + w) }

// Test seams, every one off unless its variable is set (TICK
// UNTIL_STABLE ticks through the frontier session, batched, by default):
// DAGDB_FRONTIER_FOR_TESTING=1 — a line per TICK UNTIL_STABLE in this log
//   naming its session (batches, the CPU's waits on the GPU, evaluated node
//   slots, the index and kernel builds, the session's buffers);
// DAGDB_FRONTIER_BATCH_FOR_TESTING=<k> — k ticks per command buffer instead
//   of 16 (the batching control uses 1);
// DAGDB_FRONTIER_TAU_FOR_TESTING=<x>|inf — a whole-rank threshold τ (the
//   default is inf: no whole-rank fallback; an earlier default was 0.25).
// DAGDB_FRONTIER_MAX_LEVELS_FOR_TESTING=<n>|inf — the depth
//   guard's R* (non-empty rank levels up to which TICK UNTIL_STABLE runs on
//   the frontier); inf turns the guard off (the depth guard's control).
handler.memoryBudget = memoryBudget
handler.daemonLog = { print("  " + $0) }                                // the pool's measurement
let envSeams = ProcessInfo.processInfo.environment
if envSeams["DAGDB_FRONTIER_FOR_TESTING"] == "1" {
    handler.frontierTestLog = { print("  " + $0) }
    print("  test seam on: TICK UNTIL_STABLE logs its session")
}
if let s = envSeams["DAGDB_FRONTIER_BATCH_FOR_TESTING"], let k = Int(s), k >= 1 {
    handler.untilStableBatchForTesting = k
    print("  test seam on: TICK UNTIL_STABLE batches \(k) ticks per command buffer")
}
if let s = envSeams["DAGDB_FRONTIER_TAU_FOR_TESTING"], let tau = s == "inf" ? Double.infinity : Double(s), tau >= 0 {
    engine.frontierWholeFraction = tau
    print("  test seam on: frontier whole-rank threshold tau=\(tau)")
}
if let s = envSeams["DAGDB_FRONTIER_MAX_LEVELS_FOR_TESTING"], let n = s == "inf" ? Int.max : Int(s), n >= 0 {
    engine.frontierMaxRankLevels = n
    print("  test seam on: frontier depth guard R*=\(s)")
}
// DAGDB_SET_LUTS_CPU_FOR_TESTING=<n> — a SET_LUTS whose dispatch
//   covers at least n nodes runs on the CPU twin (a test control: large
//   dispatches on the CPU twin, small ones on the GPU).
if let s = envSeams["DAGDB_SET_LUTS_CPU_FOR_TESTING"], let n = Int(s), n >= 0 {
    engine.setLutsCPUForTesting = n
    print("  test seam on: SET_LUTS on the CPU twin from \(n) nodes")
}
// DAGDB_TRUTH_SLICE_OLD_LOOP_FOR_TESTING=1 — every TRUTH_SLICE runs
//   the older per-node loop (two passes, one node at a time, over the id range or the whole
//   rank lane; the batched path's control).
if envSeams["DAGDB_TRUTH_SLICE_OLD_LOOP_FOR_TESTING"] == "1" {
    handler.truthSliceOldLoopForTesting = true
    print("  test seam on: TRUTH_SLICE runs the older per-node loop")
}

// ── Socket server ──
//
// Serialization guarantee: the SocketServer accept loop (DagDBDaemonKit/SocketServer.swift)
// is single-threaded and handles one client at a time. Each command runs fully
// through handleCommand() before the next accept. DagDBEngine.tick() calls
// waitUntilCompleted() (DagDBEngine.swift:159) so the GPU finishes before the
// Swift call returns. Therefore TICK, SAVE, LOAD, and VALIDATE cannot interleave
// at the buffer level — no mutex required while this server model holds.

// Every command runs through the shutdown
// gate, so the graceful shutdown below runs only between commands.
let shutdownGate = DagDBShutdownGate()

let server = SocketServer(path: socketPath)
// The dispatch runs inside one autorelease pool per command (as
// handle(_:) does), so nothing the gate or the log line autoreleases outlives it.
server.onCommand = { command in
    autoreleasepool { () -> String in
        guard let response = shutdownGate.run({ handler.handle(command) }) else {
            Swift.print("  [\(handler.tickCount)] " + Reply.literal(Reply.quoted(server.currentLine)) + " → " + DagDBShutdownGate.refusal)
            return DagDBShutdownGate.refusal
        }
        // The command exactly as received, quoted and escaped, with no
        // volatile reorder (so a typed " → " stays inside the quotes and the record is what the client sent); then
        // the reply, already one formatted line.
        Swift.print("  [\(handler.tickCount)] " + Reply.literal(Reply.quoted(server.currentLine)) + " → " + String(response.prefix(80)))
        return response
    }
}

// (DAGDB_AUTOSAVE, the auto-snapshot path, is read above with the other configured paths.)
// The autosave path is a write target like any other: inside the data root (its deepest existing
// ancestor resolved) and not the log, or the daemon does not start.
if let a = autoSnapshotPath {
    if let r = DaemonFile.withRoot(dataRoot, { DaemonFile.containmentRefusal(a) }) {
        print("  FATAL: DAGDB_AUTOSAVE: \(r); refusing to start"); exit(2)
    }
    if let e = handler.withContainment({ handler.walTargetRefusal("DAGDB_AUTOSAVE", a) }) {
        print("  FATAL: \(e); refusing to start"); exit(2)
    }
}

/// Runs on the shutdown gate's queue with no command in flight.
@Sendable func gracefulShutdown() {
    print("\n  Shutting down...")
    // Forced barrier: flush any deferred WAL tail before we exit so a
    // grouped-commit daemon loses nothing on a graceful shutdown.
    handler.walAppender?.barrier()
    if let path = autoSnapshotPath {
        // Snapshot + WAL checkpoint, same as SAVE — the checkpoint is what
        // keeps startup recovery from replaying the tail a second time.
        // Not while a failed rebase's hold is on.
        print("  Auto-snapshot: \(handler.autosaveAtShutdown(path: path))")
    }
    // The era sidecar's high-water mark, sealed at clean shutdown.
    if let line = handler.sealEraMarkAtShutdown() { print("  " + line) }
    exit(0)
}

// SIGINT and SIGTERM are taken by
// dispatch sources on the gate's queue, never by a raw handler on the
// interrupted thread. In earlier builds a raw `signal()` handler ran the autosave
// inside whatever command the signal interrupted: a half-applied command was
// snapshotted and bound (recovery a mixture), and a signal inside a WAL
// append re-entered the appender's queue from `barrier()` (a libdispatch
// trap, no autosave). Now the command in flight completes, a command not yet
// started is refused (`ERROR shutdown: …`), then the barrier, the autosave
// and the exit run.
shutdownGate.installSignalSources([SIGINT, SIGTERM]) { gracefulShutdown() }

print("\n  DagDB Daemon ready.")
print("  Test: echo 'STATUS' | nc -U \(socketPath)")
print("══════════════════════════════════════════════════════════\n")

try server.start()
