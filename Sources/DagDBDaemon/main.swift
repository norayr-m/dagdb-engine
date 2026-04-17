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

// ── Shared memory for results ──
// Layout: [4 bytes: row count] [4 bytes: row size] [data rows...]
// Each row: [4 bytes: node_id] [1 byte: rank] [1 byte: truth] [1 byte: type] [1 byte: pad]

let resultRowSize = 8  // node_id(4) + rank(1) + truth(1) + type(1) + pad(1)
let maxResultRows = nodeCount
let shmSize = 8 + maxResultRows * resultRowSize  // header + rows

// Use file-based shared memory as fallback (shm_open has Swift availability issues)
let shmPath = "/tmp/dagdb_shm_file"
let shmFd: Int32

// Create backing file
FileManager.default.createFile(atPath: shmPath, contents: nil)
shmFd = open(shmPath, O_RDWR | O_CREAT, 0o666)
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
        var rows: [(Int, UInt8, UInt8, UInt8)] = roots.map { ($0.0, ranks[$0.0], $0.1, UInt8(0)) }
        if let pred = predicate {
            rows = rows.filter { pred.evaluate(truth: $0.2, rank: $0.1, nodeType: $0.3) }
        }
        writeResults(rows)
        return "OK EVAL rows=\(rows.count) tick=\(tickCount)"

    case .nodes(let rank, let predicate):
        let truth = engine.readTruthStates()
        let ranks = engine.readRanks()
        var rows: [(Int, UInt8, UInt8, UInt8)] = []
        for i in 0..<nodeCount {
            if let r = rank, ranks[i] != UInt8(r) { continue }
            if let pred = predicate, !pred.evaluate(truth: truth[i], rank: ranks[i], nodeType: 0) { continue }
            // Skip nodes with rank 0 and truth 0 and no explicit rank (likely unused)
            if rank == nil && ranks[i] == 0 && truth[i] == 0 { continue }
            rows.append((i, ranks[i], truth[i], 0))
        }
        writeResults(rows)
        return "OK NODES rows=\(rows.count)"

    case .traverse(let fromNode, let depth):
        guard fromNode < nodeCount else { return "ERROR node \(fromNode) out of range" }
        var visited: [(Int, UInt8, UInt8, UInt8)] = []
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
        guard node < nodeCount else { return "ERROR node \(node) out of range" }
        engine.truthStateBuf.contents()
            .bindMemory(to: UInt8.self, capacity: nodeCount)[node] = value
        return "OK SET node=\(node) truth=\(value)"

    case .setRank(let node, let value):
        guard node < nodeCount else { return "ERROR node \(node) out of range" }
        engine.rankBuf.contents()
            .bindMemory(to: UInt8.self, capacity: nodeCount)[node] = value
        return "OK SET node=\(node) rank=\(value)"

    case .setLUT(let node, let preset):
        guard node < nodeCount else { return "ERROR node \(node) out of range" }
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
        default: return "ERROR unknown LUT preset: \(preset). Use AND OR XOR MAJ IDENTITY CONST0 CONST1 VETO"
        }
        let low = UInt32(lut & 0xFFFFFFFF)
        let high = UInt32((lut >> 32) & 0xFFFFFFFF)
        engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)[node] = low
        engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)[node] = high
        return "OK SET node=\(node) lut=\(preset)"

    case .clearEdges(let node):
        guard node < nodeCount else { return "ERROR node \(node) out of range" }
        let nbPtr = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)
        for d in 0..<6 { nbPtr[node * 6 + d] = -1 }
        return "OK CLEAR node=\(node) edges"

    case .connect(let src, let dst):
        guard src < nodeCount && dst < nodeCount else { return "ERROR node out of range" }
        if src == dst { return "ERROR self-loop: src == dst (\(src))" }
        let rankPtr = engine.rankBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
        let srcRank = rankPtr[src]
        let dstRank = rankPtr[dst]
        guard srcRank > dstRank else {
            return "ERROR rank violation: src(\(src)) rank=\(srcRank) must be > dst(\(dst)) rank=\(dstRank) — edges flow leaves→roots"
        }
        // Find first empty neighbor slot on dst; reject duplicates
        let nbPtr = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)
        var connected = false
        for d in 0..<6 {
            if nbPtr[dst * 6 + d] == Int32(src) {
                return "ERROR duplicate edge: \(src) → \(dst)"
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
            return "ERROR node \(dst) already has 6 edges (6-bounded)"
        }

    case .graphInfo:
        let ranks = engine.readRanks()
        let truth = engine.readTruthStates()
        var rankCounts: [UInt8: Int] = [:]
        var trueCount = 0
        for i in 0..<nodeCount {
            rankCounts[ranks[i], default: 0] += 1
            if truth[i] == 1 { trueCount += 1 }
        }
        let rankStr = rankCounts.sorted(by: { $0.key < $1.key })
            .map { "r\($0.key)=\($0.value)" }.joined(separator: " ")
        return "OK GRAPH nodes=\(nodeCount) true=\(trueCount) \(rankStr)"

    case .save(let path):
        do {
            let r = try DagDBSnapshot.save(
                engine: engine,
                nodeCount: nodeCount,
                gridW: width,
                gridH: height,
                tickCount: tickCount,
                path: path
            )
            return "OK SAVE bytes=\(r.bytesWritten) elapsed=\(String(format: "%.1f", r.elapsedMs))ms path=\(path)"
        } catch {
            return "ERROR save: \(error)"
        }

    case .load(let path):
        do {
            let r = try DagDBSnapshot.load(
                engine: engine,
                nodeCount: nodeCount,
                path: path
            )
            tickCount = r.fileTicks
            return "OK LOAD bytes=\(r.bytesRead) nodes=\(r.fileNodeCount) ticks=\(r.fileTicks) elapsed=\(String(format: "%.1f", r.elapsedMs))ms"
        } catch {
            return "ERROR load: \(error)"
        }

    case .exportMorton(let dir):
        do {
            let r = try DagDBSnapshot.exportMorton(
                engine: engine,
                nodeCount: nodeCount,
                dir: dir
            )
            return "OK EXPORT bytes=\(r.bytesWritten) elapsed=\(String(format: "%.1f", r.elapsedMs))ms dir=\(dir)"
        } catch {
            return "ERROR export: \(error)"
        }

    case .unknown(let raw):
        return "ERROR unknown command: \(raw)"
    }
}

/// Write result rows to shared memory.
/// Layout: [4: rowCount] [4: rowSize] [rows...]
/// Row: [4: node_id] [1: rank] [1: truth] [1: type] [1: pad]
func writeResults(_ rows: [(Int, UInt8, UInt8, UInt8)]) {
    let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
    headerPtr[0] = UInt32(rows.count)
    headerPtr[1] = UInt32(resultRowSize)

    let dataPtr = shmBase.advanced(by: 8)
    for (i, row) in rows.enumerated() {
        let rowPtr = dataPtr.advanced(by: i * resultRowSize)
        rowPtr.storeBytes(of: UInt32(row.0), as: UInt32.self)
        rowPtr.advanced(by: 4).storeBytes(of: row.1, as: UInt8.self)
        rowPtr.advanced(by: 5).storeBytes(of: row.2, as: UInt8.self)
        rowPtr.advanced(by: 6).storeBytes(of: row.3, as: UInt8.self)
        rowPtr.advanced(by: 7).storeBytes(of: UInt8(0), as: UInt8.self)
    }
}

// ── Socket server ──

let server = SocketServer(path: socketPath)
server.onCommand = { command in
    let response = handleCommand(command)
    print("  [\(tickCount)] \(command) → \(response.prefix(80))")
    return response
}

// Handle SIGINT for clean shutdown
signal(SIGINT) { _ in
    print("\n  Shutting down...")
    exit(0)
}

print("\n  DagDB Daemon ready.")
print("  Test: echo 'STATUS' | nc -U \(socketPath)")
print("══════════════════════════════════════════════════════════\n")

try server.start()
