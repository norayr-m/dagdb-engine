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
    var walAppender: DagDBWAL.Appender?
    let sessionManager: DagDBReaderSessionManager
    let truthRankIndex: TruthRankIndex
    let shmBase: UnsafeMutableRawPointer
    let resultRowSize: Int
    let dataRoot: String?
    let dagdbEnv: String?

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
        dagdbEnv: String?
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

    // MARK: - Command dispatch

    public func handle(_ input: String) -> String {
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
                if let r = rank, ranks[i] != UInt64(r) { continue }
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
            guard node < nodeCount else { return "ERROR out_of_range: node \(node) out of range" }
            let nbPtr = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)
            for d in 0..<6 { nbPtr[node * 6 + d] = -1 }
            return "OK CLEAR node=\(node) edges"

        case .connect(let src, let dst):
            guard src < nodeCount && dst < nodeCount else { return "ERROR out_of_range: node out of range" }
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

        case .connectBack(let src, let dst):
            guard src < nodeCount && dst < nodeCount else { return "ERROR out_of_range: node out of range" }
            if src == dst { return "ERROR schema: self-loop: src == dst (\(src))" }
            // Validate first (cheap, in-memory) so we don't write a WAL record
            // for a mutation the engine would reject.
            do {
                try engine.addBackEdge(src: UInt32(src), dst: UInt32(dst))
            } catch let err as DagDBEngine.BackEdgeError {
                return "ERROR schema: \(err)"
            } catch {
                return "ERROR schema: \(error)"
            }
            // Log-after-apply is acceptable here: addBackEdge is idempotent on
            // already-registered duplicates, and a WAL append failure now would
            // leave a one-tick window of un-logged state. Append immediately to
            // close that window.
            if let wal = walAppender {
                do { _ = try wal.connectBack(src: UInt32(src), dst: UInt32(dst)) }
                catch { return "ERROR wal: append: \(error)" }
            }
            return "OK CONNECT BACK from=\(src) to=\(dst)"

        case .clearBackEdges(let node):
            guard node < nodeCount else { return "ERROR out_of_range: node \(node) out of range" }
            if let wal = walAppender {
                do { _ = try wal.clearBackEdges(dst: UInt32(node)) }
                catch { return "ERROR wal: append: \(error)" }
            }
            let before = engine.backEdgeCount
            engine.clearBackEdges(toNode: UInt32(node))
            let removed = before - engine.backEdgeCount
            return "OK CLEAR node=\(node) back_edges removed=\(removed)"

        case .getTruth(let node):
            guard node < nodeCount else { return "ERROR out_of_range: node \(node) out of range" }
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
            do {
                let r = try DagDBSnapshot.save(
                    engine: engine,
                    nodeCount: nodeCount,
                    gridW: width,
                    gridH: height,
                    tickCount: tickCount,
                    path: path,
                    compressed: compressed,
                    daemonEnv: DagDBSnapshot.SnapshotEnv.from(envString: dagdbEnv)
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
                    path: path,
                    daemonEnv: DagDBSnapshot.SnapshotEnv.from(envString: dagdbEnv)
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

        case .setLutsBulk:
            // Read u64[nodeCount] LUT vector from shm offset 8 and commit
            // each entry to lut6Low/lut6High (low 32 = bits 0-31, high 32 =
            // bits 32-63). Compiles a million-node microcircuit's LUT vector
            // in one round-trip; pair with SAVE if you need durability.
            let src = shmBase.advanced(by: 8).bindMemory(to: UInt64.self, capacity: nodeCount)
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
            let src = shmBase.advanced(by: 8).bindMemory(to: Int32.self, capacity: count)
            let dst = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: count)
            for i in 0..<count { dst[i] = src[i] }
            return "OK SET_NEIGHBORS_BULK nodes=\(nodeCount) edges_slot=\(count)"

        case .composeLUT(let op, let src1, let src2, let dst):
            // Bitwise composition of LUTs into dst's LUT.
            // Caller is responsible for the assumption that src1, src2, dst
            // share a common input vector — the engine just performs the
            // bitwise op on the 64-bit LUT integers. Mutates only dst's LUT.
            guard src1 >= 0 && src1 < nodeCount else {
                return "ERROR out_of_range: src1 \(src1) out of range"
            }
            guard dst >= 0 && dst < nodeCount else {
                return "ERROR out_of_range: dst \(dst) out of range"
            }
            if let s2 = src2 {
                guard s2 >= 0 && s2 < nodeCount else {
                    return "ERROR out_of_range: src2 \(s2) out of range"
                }
            }
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
            for i in 0..<nodeCount {
                if let r = rank, ranks[i] != UInt64(r) { continue }
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

        case .getTruth(let node):
            guard node < nodeCount else { return "ERROR reader: node \(node) out of range" }
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
             .clearEdges, .connect, .connectBack, .clearBackEdges,
             .exportMorton, .importMorton,
             .saveJSON, .loadJSON, .saveCSV, .loadCSV,
             .backupInit, .backupAppend, .backupRestore, .backupCompact, .backupInfo,
             .setRanksBulk, .setLutsBulk, .setNeighborsBulk,
             .openReader, .closeReader, .listReaders, .reader,
             .similarDecisions, .composeLUT:
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

    // MARK: - Shared-memory result writer

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
}
