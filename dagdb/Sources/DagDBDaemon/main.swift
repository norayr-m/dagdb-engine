/// DagDB Daemon — GPU graph engine server.
///
/// Runs the DagDB Metal engine as a standalone daemon process.
/// Listens on Unix domain socket for DSL commands.
/// Shares results via POSIX shared memory (zero-copy on UMA).
///
/// Usage: dagdb-daemon [--grid <size>] [--socket <path>] [--shm <name>]

import Foundation
import DagDB

print("══════════════════════════════════════════════════════════")
print("  DagDB Daemon v0.1 — GPU Graph Engine Server")
print("══════════════════════════════════════════════════════════")

// Parse arguments
var gridSize = 256       // default: 256x256 = 65K nodes
var socketPath = "/tmp/dagdb.sock"
var shmName = "/dagdb_shm"
var maxRank = 16

let args = CommandLine.arguments
for i in 0..<args.count {
    if args[i] == "--grid" && i + 1 < args.count { gridSize = Int(args[i+1]) ?? gridSize }
    if args[i] == "--socket" && i + 1 < args.count { socketPath = args[i+1] }
    if args[i] == "--shm" && i + 1 < args.count { shmName = args[i+1] }
    if args[i] == "--max-rank" && i + 1 < args.count { maxRank = Int(args[i+1]) ?? maxRank }
}

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
        walAppender = try DagDBWAL.Appender(path: p, nodeCount: nodeCount)
        print("  WAL: appending to \(p)")
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
var tickCount: UInt32 = 0

// ── Path guard ──
// DSL clients can supply file paths to SAVE/LOAD/BACKUP/JSON/CSV/MORTON verbs.
// We never allow `..` traversal segments. If DAGDB_DATA_ROOT is set we also
// require the resolved path to live under that root; otherwise we accept any
// path the daemon user can reach (single-user laptop default).
let dataRoot: String? = {
    if let env = ProcessInfo.processInfo.environment["DAGDB_DATA_ROOT"],
       !env.isEmpty {
        return (env as NSString).resolvingSymlinksInPath
    }
    return nil
}()
if let r = dataRoot { print("  Data root: \(r)") }

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

// ── Command handler ──

func handleCommand(_ input: String) -> String {
    let cmd = DSLParser.parse(input)

    switch cmd {
    case .status:
        return "OK STATUS nodes=\(nodeCount) ticks=\(tickCount) gpu=\(engine.device.name) grid=\(width)x\(height) maxRank=\(maxRank)"

    case .tick(let count):
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<count {
            engine.tick(tickNumber: tickCount)
            tickCount += 1
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        return "OK TICK \(count) elapsed=\(String(format: "%.2f", elapsed))ms total=\(tickCount)"

    case .eval(let predicate, _, _):
        engine.tick(tickNumber: tickCount)
        tickCount += 1
        let roots = engine.readRoots()  // [(Int, UInt8)]
        let truth = engine.readTruthStates()
        let ranks = engine.readRanks()
        var rows: [(Int, UInt64, UInt8, UInt8)] = roots.map { ($0.0, ranks[$0.0], $0.1, UInt8(0)) }
        if let pred = predicate {
            rows = rows.filter { pred.evaluate(truth: $0.2, rank: $0.1, nodeType: $0.3) }
        }
        writeResults(rows)
        return "OK EVAL rows=\(rows.count) tick=\(tickCount)"

    case .nodes(let rank, let predicate):
        let truth = engine.readTruthStates()
        let ranks = engine.readRanks()
        var rows: [(Int, UInt64, UInt8, UInt8)] = []
        for i in 0..<nodeCount {
            if let r = rank, ranks[i] != UInt32(r) { continue }
            if let pred = predicate, !pred.evaluate(truth: truth[i], rank: ranks[i], nodeType: 0) { continue }
            // Skip nodes with rank 0 and truth 0 and no explicit rank (likely unused)
            if rank == nil && ranks[i] == 0 && truth[i] == 0 { continue }
            rows.append((i, ranks[i], truth[i], 0))
        }
        writeResults(rows)
        return "OK NODES rows=\(rows.count)"

    case .traverse(let fromNode, let depth):
        guard fromNode < nodeCount else { return "ERROR out_of_range: node \(fromNode) out of range" }
        var visited: [(Int, UInt64, UInt8, UInt8)] = []
        var frontier: Set<Int> = [fromNode]
        let truth = engine.readTruthStates()
        let ranks = engine.readRanks()

        for _ in 0..<depth {
            var nextFrontier: Set<Int> = []
            for node in frontier {
                visited.append((node, ranks[node], truth[node], 0))
                for d in 0..<6 {
                    let nb = grid.neighbors[node * 6 + d]
                    if nb >= 0 && !frontier.contains(Int(nb)) {
                        nextFrontier.insert(Int(nb))
                    }
                }
            }
            frontier = nextFrontier
        }
        writeResults(visited)
        return "OK TRAVERSE rows=\(visited.count) from=\(fromNode) depth=\(depth)"

    case .setTruth(let node, let value):
        guard node < nodeCount else { return "ERROR out_of_range: node \(node) out of range" }
        // Log-first: append to WAL (fsync'd) before touching engine buffer.
        // If WAL fails, abort the mutation so the log and engine stay in sync.
        if let wal = walAppender {
            do { _ = try wal.setTruth(node: UInt32(node), value: value) }
            catch { return "ERROR wal: append: \(error)" }
        }
        engine.truthStateBuf.contents()
            .bindMemory(to: UInt8.self, capacity: nodeCount)[node] = value
        truthRankIndex.markDirty()
        return "OK SET node=\(node) truth=\(value)"

    case .setRank(let node, let value):
        guard node < nodeCount else { return "ERROR out_of_range: node \(node) out of range" }
        if let wal = walAppender {
            do { _ = try wal.setRank(node: UInt32(node), value: value) }
            catch { return "ERROR wal: append: \(error)" }
        }
        engine.rankBuf.contents()
            .bindMemory(to: UInt64.self, capacity: nodeCount)[node] = value
        truthRankIndex.markDirty()
        return "OK SET node=\(node) rank=\(value)"

    case .setLUT(let node, let preset):
        guard node < nodeCount else { return "ERROR out_of_range: node \(node) out of range" }
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
        default: return "ERROR dsl_parse: unknown LUT preset: \(preset). Use AND OR XOR MAJ IDENTITY CONST0 CONST1 VETO NOR NAND AND3 OR3 MAJ3"
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
        guard node < nodeCount else { return "ERROR out_of_range: node \(node) out of range" }
        let nbPtr = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)
        for d in 0..<6 { nbPtr[node * 6 + d] = -1 }
        return "OK CLEAR node=\(node) edges"

    case .connect(let src, let dst):
        guard src < nodeCount && dst < nodeCount else { return "ERROR out_of_range: node out of range" }
        if src == dst { return "ERROR schema: self-loop: src == dst (\(src))" }
        let rankPtr = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: nodeCount)
        let srcRank = rankPtr[src]
        let dstRank = rankPtr[dst]
        guard srcRank > dstRank else {
            return "ERROR schema: rank violation: src(\(src)) rank=\(srcRank) must be > dst(\(dst)) rank=\(dstRank) — edges flow leaves→roots"
        }
        // Find first empty neighbor slot on dst; reject duplicates
        let nbPtr = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)
        var connected = false
        for d in 0..<6 {
            if nbPtr[dst * 6 + d] == Int32(src) {
                return "ERROR schema: duplicate edge: \(src) → \(dst)"
            }
        }
        for d in 0..<6 {
            if nbPtr[dst * 6 + d] < 0 {
                nbPtr[dst * 6 + d] = Int32(src)
                connected = true
                break
            }
        }
        if connected {
            return "OK CONNECT from=\(src) to=\(dst)"
        } else {
            return "ERROR schema: node \(dst) already has 6 edges (6-bounded)"
        }

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
        do {
            let r = try DagDBSnapshot.save(
                engine: engine,
                nodeCount: nodeCount,
                gridW: width,
                gridH: height,
                tickCount: tickCount,
                path: path,
                compressed: compressed
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

    case .load(let path):
        if let err = guardPath(path) { return err }
        do {
            let r = try DagDBSnapshot.load(
                engine: engine,
                nodeCount: nodeCount,
                gridW: width,
                gridH: height,
                path: path
            )
            tickCount = r.fileTicks
            truthRankIndex.markDirty()
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
            return "OK BACKUP_APPEND bytes=\(r.diffBytes) elapsed=\(String(format: "%.1f", r.elapsedMs))ms path=\(r.diffPath)"
        } catch {
            return "ERROR io: backup_append: \(error)"
        }

    case .backupRestore(let dir):
        if let err = guardPath(dir) { return err }
        do {
            let r = try DagDBBackup.restore(
                engine: engine, nodeCount: nodeCount,
                gridW: width, gridH: height, dir: dir
            )
            truthRankIndex.markDirty()
            return "OK BACKUP_RESTORE diffs_replayed=\(r.diffsReplayed) elapsed=\(String(format: "%.1f", r.elapsedMs))ms"
        } catch {
            return "ERROR io: backup_restore: \(error)"
        }

    case .backupCompact(let dir):
        if let err = guardPath(dir) { return err }
        do {
            let r = try DagDBBackup.compact(
                engine: engine, nodeCount: nodeCount,
                gridW: width, gridH: height,
                tickCount: tickCount, dir: dir
            )
            return "OK BACKUP_COMPACT prior_diffs=\(r.priorDiffCount) new_base_bytes=\(r.newBaseBytes) elapsed=\(String(format: "%.1f", r.elapsedMs))ms"
        } catch {
            return "ERROR io: backup_compact: \(error)"
        }

    case .backupInfo(let dir):
        if let err = guardPath(dir) { return err }
        do {
            let r = try DagDBBackup.info(dir: dir)
            return "OK BACKUP_INFO base=\(r.baseExists) base_bytes=\(r.baseSizeBytes) diffs=\(r.diffCount) total_diff_bytes=\(r.totalDiffBytes)"
        } catch {
            return "ERROR io: backup_info: \(error)"
        }

    case .setRanksBulk:
        // Read u64 rank vector of length nodeCount from shm offset 8,
        // commit to rankBuf. Caller's responsibility to ensure the
        // injected ranks preserve the monotonicity invariant for any
        // existing edges — the bulk commit skips per-insert validation
        // for speed. Follow up with VALIDATE if paranoid.
        let src = shmBase.advanced(by: 8).bindMemory(to: UInt64.self, capacity: nodeCount)
        let dst = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: nodeCount)
        for i in 0..<nodeCount { dst[i] = src[i] }
        truthRankIndex.markDirty()
        return "OK SET_RANKS_BULK nodes=\(nodeCount)"

    case .selectByTruthRank(let truthVal, let lo, let hi):
        let matches = truthRankIndex.select(
            truth: truthVal, rankLo: lo, rankHi: hi,
            engine: engine, nodeCount: nodeCount
        )
        // Write node IDs as Int32[] to shm at offset 8 (same layout as BFS_DEPTHS)
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
        do {
            let r = undirected
                ? try DagDBBFS.bfsDepthsUndirected(engine: engine, nodeCount: nodeCount, from: seed)
                : try DagDBBFS.bfsDepthsBackward(engine: engine, nodeCount: nodeCount, from: seed)
            // Write depths[0..<nodeCount] to shared memory as raw Int32[].
            // Layout: [4:nodeCount][4:reserved][Int32 × nodeCount]
            let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
            headerPtr[0] = UInt32(nodeCount)
            headerPtr[1] = 0
            let dataPtr = shmBase.advanced(by: 8).bindMemory(to: Int32.self, capacity: nodeCount)
            r.depths.withUnsafeBufferPointer { buf in
                for i in 0..<nodeCount { dataPtr[i] = buf[i] }
            }
            let dir = undirected ? "undirected" : "backward"
            return "OK BFS_DEPTHS seed=\(seed) dir=\(dir) reached=\(r.reached) max_depth=\(r.maxDepth) elapsed=\(String(format: "%.1f", r.elapsedMs))ms shm_bytes=\(nodeCount * 4)"
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
        guard node >= 0 && node < nodeCount else {
            return "ERROR out_of_range: node \(node) not in [0, \(nodeCount))"
        }
        guard depth >= 0 else {
            return "ERROR dsl_parse: depth must be non-negative, got \(depth)"
        }
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
        guard seed >= 0 && seed < nodeCount else {
            return "ERROR out_of_range: seed \(seed) not in [0, \(nodeCount))"
        }
        guard depth >= 0, k > 0 else {
            return "ERROR dsl_parse: depth must be non-negative and k positive"
        }
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

    case .unknown(let raw):
        return "ERROR unknown_command: \(raw)"
    }
}

// ── Read-only dispatcher for reader sessions ──
//
// Routes a DSL command against a snapshot engine. Rejects any mutation —
// a reader session is point-in-time by construction and cannot alter
// state. Supports the read-only subset of commands useful for hive
// queries (NODES, TRAVERSE, GRAPH INFO, BFS_DEPTHS, DISTANCE, VALIDATE).
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
        for i in 0..<nodeCount {
            if let r = rank, ranks[i] != UInt32(r) { continue }
            if let pred = predicate, !pred.evaluate(truth: truth[i], rank: ranks[i], nodeType: 0) { continue }
            if rank == nil && ranks[i] == 0 && truth[i] == 0 { continue }
            rows.append((i, ranks[i], truth[i], 0))
        }
        writeResults(rows)
        return "OK NODES session=\(sessionId) rows=\(rows.count)"

    case .traverse(let fromNode, let depth):
        guard fromNode < nodeCount else { return "ERROR reader: node \(fromNode) out of range" }
        var visited: [(Int, UInt64, UInt8, UInt8)] = []
        var frontier: Set<Int> = [fromNode]
        let truth = engine.readTruthStates()
        let ranks = engine.readRanks()
        for _ in 0..<depth {
            var nextFrontier: Set<Int> = []
            for node in frontier {
                visited.append((node, ranks[node], truth[node], 0))
                let nb = engine.neighborsBuf.contents()
                    .bindMemory(to: Int32.self, capacity: nodeCount * 6)
                for d in 0..<6 {
                    let src = nb[node * 6 + d]
                    if src >= 0 && !frontier.contains(Int(src)) {
                        nextFrontier.insert(Int(src))
                    }
                }
            }
            frontier = nextFrontier
        }
        writeResults(visited)
        return "OK TRAVERSE session=\(sessionId) rows=\(visited.count) from=\(fromNode) depth=\(depth)"

    case .validateGraph:
        if let violation = DagDBSnapshot.validate(engine: engine, nodeCount: nodeCount) {
            return "FAIL VALIDATE session=\(sessionId) \(violation)"
        } else {
            return "OK VALIDATE session=\(sessionId)"
        }

    case .bfsDepths(let seed, let undirected):
        do {
            let r = undirected
                ? try DagDBBFS.bfsDepthsUndirected(engine: engine, nodeCount: nodeCount, from: seed)
                : try DagDBBFS.bfsDepthsBackward(engine: engine, nodeCount: nodeCount, from: seed)
            let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
            headerPtr[0] = UInt32(nodeCount)
            headerPtr[1] = 0
            let dataPtr = shmBase.advanced(by: 8).bindMemory(to: Int32.self, capacity: nodeCount)
            r.depths.withUnsafeBufferPointer { buf in
                for i in 0..<nodeCount { dataPtr[i] = buf[i] }
            }
            let dir = undirected ? "undirected" : "backward"
            return "OK BFS_DEPTHS session=\(sessionId) seed=\(seed) dir=\(dir) reached=\(r.reached) max_depth=\(r.maxDepth) elapsed=\(String(format: "%.1f", r.elapsedMs))ms shm_bytes=\(nodeCount * 4)"
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

    case .selectByTruthRank(let truthVal, let lo, let hi):
        // Session uses its own local index — rebuild on every call since
        // the session's snapshot buffers are static by construction
        // (snapshot-on-read, primary mutations don't reach here).
        let localIndex = TruthRankIndex()
        let matches = localIndex.select(
            truth: truthVal, rankLo: lo, rankHi: hi,
            engine: engine, nodeCount: nodeCount
        )
        let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
        headerPtr[0] = UInt32(matches.count)
        headerPtr[1] = 0
        let dataPtr = shmBase.advanced(by: 8).bindMemory(to: Int32.self, capacity: max(1, matches.count))
        for (i, nodeId) in matches.enumerated() {
            dataPtr[i] = Int32(nodeId)
        }
        return "OK SELECT session=\(sessionId) truth=\(truthVal) rank=\(lo)-\(hi) matches=\(matches.count) shm_bytes=\(matches.count * 4)"

    case .ancestry(let node, let depth):
        guard node >= 0 && node < nodeCount else {
            return "ERROR out_of_range: node \(node) not in [0, \(nodeCount))"
        }
        do {
            let r = try DagDBBFS.bfsDepthsBackward(
                engine: engine, nodeCount: nodeCount, from: node)
            var pairs: [(Int32, Int32)] = []
            for i in 0..<nodeCount {
                let d = r.depths[i]
                if d >= 0 && d <= Int32(depth) { pairs.append((Int32(i), d)) }
            }
            pairs.sort { $0.1 < $1.1 }
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

    // All writes and nested sessions rejected.
    case .tick, .save, .load, .setTruth, .setRank, .setLUT,
         .clearEdges, .connect, .exportMorton, .importMorton,
         .saveJSON, .loadJSON, .saveCSV, .loadCSV,
         .backupInit, .backupAppend, .backupRestore, .backupCompact, .backupInfo,
         .setRanksBulk, .openReader, .closeReader, .listReaders, .reader,
         .similarDecisions:
        return "ERROR forbidden: command not allowed in reader session (read-only)"

    case .eval:
        // EVAL runs tick() which is a write on the snapshot's buffers.
        // Technically it only mutates the snapshot, not the primary, so
        // it's safe — but semantically a reader shouldn't tick. Reject.
        return "ERROR forbidden: EVAL not allowed in reader session (ticks mutate)"

    case .unknown(let raw):
        return "ERROR unknown_command: reader inner: \(raw)"
    }
}

/// Write result rows to shared memory.
/// Layout: [4: rowCount] [4: rowSize] [rows...]
/// Row (v3): [8: node_id] [8: rank] [1: truth] [1: type] [6: pad] = 24 B
func writeResults(_ rows: [(Int, UInt64, UInt8, UInt8)]) {
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
}

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
    let response = handleCommand(command)
    print("  [\(tickCount)] \(command) → \(response.prefix(80))")
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
    if let path = autoSnapshotPath {
        do {
            let r = try DagDBSnapshot.save(
                engine: engine, nodeCount: nodeCount,
                gridW: width, gridH: height,
                tickCount: tickCount, path: path,
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
