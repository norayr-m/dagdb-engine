/// DSLParser — Graph-native query language for DagDB.
///
/// Commands:
///   STATUS                              → daemon info
///   TICK <n>                            → run n ticks
///   EVAL [WHERE <predicate>]                       → evaluate and return roots
///                                                    (a RANK clause is refused)
///   NODES [AT RANK <n>] [WHERE <predicate>]         → list nodes
///   TRAVERSE FROM <node> DEPTH <n>      → walk n ranks from node
///   SET <node> TRUTH <0|1|2>            → set truth state
///   GRAPH INFO                          → graph statistics

import Foundation
import DagDB

public enum DSLCommand {
    case status
    case tick(count: Int)
    case tickSync(count: Int)
    case eval(predicate: Predicate?)
    case nodes(rank: Int?, predicate: Predicate?)
    case traverse(fromNode: Int, depth: Int)
    case setTruth(node: Int, value: UInt8)
    case setWeight(node: Int, dir: Int, value: Float)   // SET <node> WEIGHT <dir> <f>
    case setValue(node: Int, value: Float)              // SET <node> VALUE <f>
    case setRank(node: Int, value: UInt64)
    case setLUT(node: Int, preset: String)
    case connect(from: Int, to: Int)
    case clearEdges(node: Int)
    /// CONNECT BACK FROM <src> TO <dst> — register a typed BACK_EDGE that
    /// latches `truth[src]` into `truth[dst]` at every tick boundary.
    /// Destination must have zero combinational fan-in.
    case connectBack(from: Int, to: Int)
    /// CLEAR <node> BACK_EDGES — remove every BACK_EDGE whose destination
    /// is `node`. Mirror of CLEAR <node> EDGES (which clears combinational).
    case clearBackEdges(node: Int)
    /// GET <node> TRUTH — return a single node's current truth value as
    /// plain text. Cheap socket-only readback for clients that don't
    /// have access to the shared-memory result rows.
    case getTruth(node: Int)
    case graphInfo
    case save(path: String, compressed: Bool)
    case load(path: String, unverified: Bool = false)
    case exportMorton(dir: String)
    case importMorton(dir: String)
    case validateGraph
    case saveJSON(path: String)
    case loadJSON(path: String)
    case saveCSV(dir: String)
    case loadCSV(dir: String)
    /// SAVE TILED <dir> <b1,b2,...>. `boundaries` is the raw
    /// comma-separated list as parsed (numeric, but not yet checked for
    /// ascending order — that's a semantic check the handler makes, same
    /// split as every other bad-number case in this grammar). Splits the
    /// DAEMON'S OWN live engine into tile directories under `dir`; NOT a
    /// twin registry verb (see `TiledGraphRouter`'s own header comment) —
    /// parsed at the top level, not through `parseTwin`.
    case saveTiled(dir: String, boundaries: [UInt64])
    /// TILED OPEN <dir> [<K>] — opens a `TiledGraphRouter` over `dir`'s
    /// manifest, K resident tiles (default 2, checked 1...64 by the
    /// handler).
    case tiledOpen(dir: String, k: Int)
    /// TILED BFS <id> <globalId> <depth> [BACK] — cross-tile BFS/ancestry
    /// through an open router. `globalId` is the raw packed `GlobalNodeID`
    /// (decimal u64, matching `TiledGraphFiles.WriteReport.globalOf`'s
    /// wire form). `backward` mirrors ANCESTRY/BFS_DEPTHS's own BACK/
    /// BACKWARD convention.
    case tiledBFS(id: String, globalId: UInt64, depth: Int, backward: Bool)
    /// TILED SELECT <id> <truth> <lo> <hi> — cross-tile truth/rank-range
    /// select through an open router.
    case tiledSelect(id: String, truth: UInt8, rankLo: UInt64, rankHi: UInt64)
    /// TILED STATUS <id> — one router's residency/load/evict/refusal counters.
    case tiledStatus(id: String)
    /// TILED LIST — every open router, id + dir + tile count.
    case tiledList
    /// TILED CLOSE <id> — drop a router (not persisted; nothing to flush —
    /// see `TiledGraphRouter`'s header comment on why `save`/`close` on the
    /// router itself stay stubs).
    case tiledClose(id: String)
    /// TILED TICK <id> [<n>] [SYNC]. Advances the
    /// world `n` ticks (default 1, checked 1...10000 by the handler) in
    /// rank mode, or sync mode if `SYNC` trails. Mutating (flushes every
    /// tile to disk) — forbidden in a reader session.
    case tiledTick(id: String, n: Int, sync: Bool)
    /// TILED GET <id> <globalId> TRUTH — one node's current truth byte
    /// through an open router. Read-only.
    case tiledGetTruth(id: String, globalId: UInt64)
    case backupInit(dir: String)
    case backupAppend(dir: String)
    case backupRestore(dir: String)
    case backupCompact(dir: String)
    case backupInfo(dir: String)
    case distance(metric: String, loA: UInt64, hiA: UInt64, loB: UInt64, hiB: UInt64)
    case bfsDepths(seed: Int, undirected: Bool)
    case setRanksBulk
    /// SET_LUTS_BULK — caller writes a `u64[nodeCount]` LUT vector to shm
    /// offset 8. Daemon splits each u64 into low/high u32 and commits to
    /// lut6Low/lut6High in one memcpy. Bypasses per-node WAL; pair with
    /// SAVE if durability matters.
    case setLutsBulk
    /// SET_NEIGHBORS_BULK — caller writes an `Int32[nodeCount * 6]`
    /// neighbour vector to shm offset 8. Daemon memcpys to neighborsBuf.
    /// Bypasses rank-monotonicity validation (matches SET_RANKS_BULK);
    /// run VALIDATE after if paranoid.
    case setNeighborsBulk
    /// CONNECT_BACK_BULK. A client frame in shm: u32 count, u32 the verb's mark (0x314D4808) at offset 0, then count ×
    /// (u32 src, u32 dst) at offset 8. Equal to `count` CONNECT BACKs, all or nothing.
    case connectBackBulk
    /// SET_TRUTH_BULK. A client frame in shm:
    /// u32 count, u32 the verb's mark (0x314D4809), then count × (u32 node, u8 value,
    /// three zero bytes). Equal to `count` SET TRUTHs, all or nothing.
    case setTruthBulk
    /// TRUTH_SLICE NODES <lo>-<hi> | TRUTH_SLICE RANK <lo>-<hi>. The truth bytes of the nodes in the id range (or with a rank
    /// in the rank range, ascending id), packed into shm: 1 bit per node on a
    /// binary-only graph whose slice holds only 0/1, else 2 bits.
    /// `… BYTES` (`bytes`) — every truth byte verbatim, 8 bits per
    /// node, nothing refused by its value.
    case truthSlice(byRank: Bool, lo: UInt64, hi: UInt64, bytes: Bool)
    /// TICK UNTIL_STABLE [MAX k]. Rank-mode ticks until a
    /// tick changes no truth byte and no register latch, at most k ticks
    /// (default and ceiling: the TICK cap).
    case tickUntilStable(max: Int?)
    /// SET_LUTS NODES|RANK <lo>-<hi> FILL <hex64> |
    /// SET_LUTS NODES|RANK <lo>-<hi> MAP [MASK <hex64>] <from>=<to> ….
    /// FILL writes the value to every node of the selection; MAP writes
    /// `to` to every node whose LUT ANDed with the mask (default all ones)
    /// equals `from`, simultaneously (1…16 pairs; the handler refuses the
    /// rest by name). Hex with or without 0x. DagDBEngine+SetLuts.swift.
    case setLuts(DagDBEngine.LutSelection, DagDBEngine.LutOp)
    /// SET_TRUTH NODES|RANK <lo>-<hi> FILL <v>. The truth byte of
    /// every node in the selection := v (decimal 0…255, as SET TRUTH; the
    /// handler refuses v ≥ 3 by name on a graph with a ternary node).
    /// DagDBEngine+SetTruthFill.swift.
    case setTruthFill(DagDBEngine.LutSelection, UInt8)
    case openReader
    case closeReader(id: String)
    case listReaders
    /// SELECT truth <k> rank <lo>-<hi> — secondary-index fast path.
    case selectByTruthRank(truth: UInt8, rankLo: UInt64, rankHi: UInt64)
    /// ANCESTRY FROM <node> DEPTH <d> — reverse BFS, bounded depth.
    case ancestry(node: Int, depth: Int)
    /// SIMILAR_DECISIONS TO <node> DEPTH <d> K <k> [AMONG TRUTH <t>] —
    /// WL-1 histogram L1 distance over per-candidate local subgraphs.
    case similarDecisions(node: Int, depth: Int, k: Int, truthFilter: UInt8?)
    /// Envelope that dispatches `inner` against the given reader session's
    /// snapshot engine instead of the primary. Only read-only commands are
    /// valid inside this envelope — writes on a session are rejected.
    indirect case reader(id: String, inner: DSLCommand)
    /// COMPOSE <op> <src1> <src2> INTO <dst> — bitwise composition of the
    /// LUTs at src1 and src2 (or src1 alone for unary NOT) into dst.
    /// Op is one of: AND, OR, XOR, NOT.  For binary ops, src2 is required.
    /// Caller is responsible for the assumption that src1, src2, dst share
    /// a common input vector — the engine just performs the bitwise op
    /// on the 64-bit LUT integers.  Result composes the truth tables.
    case composeLUT(op: String, src1: Int, src2: Int?, dst: Int)
    // ── The native ternary tick ──
    /// SET <id> MODE BINARY|TTABLE|TTHRESH [NOSKIP]. `kind` is the raw
    /// (upper-cased) word; the handler refuses an unknown one by name.
    case setMode(node: Int, kind: String, noskip: Bool)
    /// SET <id> TTABLE <tid>
    case setTTableId(node: Int, tid: Int)
    /// SET <id> THRESH <lo> <hi>
    case setThresh(node: Int, lo: Float, hi: Float)
    /// SET <id> TRIT -1|0|1
    case setTrit(node: Int, trit: Int)
    /// GET <id> TRIT → `OK GET node= trit=`
    case getTrit(node: Int)
    /// TTABLE DEFINE <tid> <729 chars of - 0 +>
    case ttableDefine(tid: Int, table: String)
    /// TTABLE PRESET <tid> <name> <k>
    case ttablePreset(tid: Int, name: String, k: Int)
    /// TTABLE GET <tid>
    case ttableGet(tid: Int)
    /// SET_MODES_BULK — u8[N] at shm offset 8.
    case setModesBulk
    /// SET_TTABLE_IDS_BULK — u16[N] at shm offset 8.
    case setTTableIdsBulk
    /// SET_THRESH_BULK — f32[2N] (lo, hi pairs) at shm offset 8.
    case setThreshBulk
    /// TTABLE_BULK <first> <count> — u8[729·count] at shm offset 8.
    case ttableBulk(first: Int, count: Int)
    /// Twin-spec DSL: one of the ten verb families (STREAM, HEADER, RECORD,
    /// RINGS, CLOCK, GEAR, XCONV, BUDGET, ALARM, VIEW) parsed by DSLParser+Twin.
    /// See TwinCommand for the full grammar.
    case twin(TwinCommand)
    /// A line the parser refuses by name, in the grammar's
    /// category for an unsupported clause. The handler replies
    /// `ERROR dsl_parse: <words>` and runs nothing (no tick, no rows, no
    /// WAL byte; the cached verdicts are kept).
    case dslParse(String)
    case unknown(String)
}

public struct Predicate {
    let field: String    // "truth", "rank", "type"
    let op: Op           // =, !=, <, >, <=, >=
    let value: Int

    enum Op: String {
        case eq = "="
        case neq = "!="
        case lt = "<"
        case gt = ">"
        case lte = "<="
        case gte = ">="
    }

    public func evaluate(truth: UInt8, rank: UInt64, nodeType: UInt8) -> Bool {
        let fieldValue: Int
        switch field {
        case "truth", "state": fieldValue = Int(truth)
        case "rank": fieldValue = Int(rank)
        case "type": fieldValue = Int(nodeType)
        default: return false
        }
        switch op {
        case .eq:  return fieldValue == value
        case .neq: return fieldValue != value
        case .lt:  return fieldValue < value
        case .gt:  return fieldValue > value
        case .lte: return fieldValue <= value
        case .gte: return fieldValue >= value
        }
    }
}

public enum DSLParser {

    public static func parse(_ input: String) -> DSLCommand {
        // Preserve original casing for path arguments; uppercase only for verb matching.
        let rawTokens = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        let tokens = rawTokens.map { $0.uppercased() }

        guard let first = tokens.first else { return .unknown(input) }

        switch first {
        case "OPEN_READER":
            // OPEN_READER  — create a snapshot-on-read session, return its id
            return .openReader

        case "CLOSE_READER":
            // CLOSE_READER <id>
            guard rawTokens.count >= 2 else { return .unknown(input) }
            return .closeReader(id: rawTokens[1])

        case "LIST_READERS":
            return .listReaders

        case "READER":
            // READER <id> <inner command ...>  — dispatch inner against session.
            guard rawTokens.count >= 3 else { return .unknown(input) }
            let id = rawTokens[1]
            let innerRaw = rawTokens[2...].joined(separator: " ")
            let inner = parse(innerRaw)
            return .reader(id: id, inner: inner)

        case "SAVE":
            // SAVE <path> [COMPRESSED]        — binary snapshot
            // SAVE JSON <path>                — JSON
            // SAVE CSV <dir>                  — two-file CSV
            // SAVE TILED <dir> <b1,b2,...>    — tile split
            guard rawTokens.count >= 2 else { return .unknown(input) }
            if rawTokens.count >= 3 && tokens[1] == "JSON" {
                return .saveJSON(path: rawTokens[2])
            }
            if rawTokens.count >= 3 && tokens[1] == "CSV" {
                return .saveCSV(dir: rawTokens[2])
            }
            if tokens[1] == "TILED" {
                guard rawTokens.count >= 4 else { return .unknown(input) }
                var boundaries: [UInt64] = []
                for part in rawTokens[3].split(separator: ",", omittingEmptySubsequences: false) {
                    guard let v = UInt64(part) else { return .unknown(input) }
                    boundaries.append(v)
                }
                return .saveTiled(dir: rawTokens[2], boundaries: boundaries)
            }
            let compressed = rawTokens.count >= 3 && tokens[2] == "COMPRESSED"
            return .save(path: rawTokens[1], compressed: compressed)

        case "LOAD":
            // LOAD <path>           — binary snapshot
            // LOAD JSON <path>      — JSON
            // LOAD CSV <dir>        — two-file CSV
            guard rawTokens.count >= 2 else { return .unknown(input) }
            if rawTokens.count >= 3 && tokens[1] == "JSON" {
                return .loadJSON(path: rawTokens[2])
            }
            if rawTokens.count >= 3 && tokens[1] == "CSV" {
                return .loadCSV(dir: rawTokens[2])
            }
            // `LOAD <path> UNVERIFIED` loads a snapshot whose .sha256 manifest exists but cannot be
            // read (an explicit flag); without it such a load is refused as unverified.
            if rawTokens.count == 3 && tokens[2] == "UNVERIFIED" {
                return .load(path: rawTokens[1], unverified: true)
            }
            return .load(path: rawTokens[1])

        case "BACKUP":
            // BACKUP <INIT|APPEND|RESTORE|COMPACT|INFO> <dir>
            guard rawTokens.count >= 3 else { return .unknown(input) }
            let dir = rawTokens[2]
            switch tokens[1] {
            case "INIT":    return .backupInit(dir: dir)
            case "APPEND":  return .backupAppend(dir: dir)
            case "RESTORE": return .backupRestore(dir: dir)
            case "COMPACT": return .backupCompact(dir: dir)
            case "INFO":    return .backupInfo(dir: dir)
            default:        return .unknown(input)
            }

        case "DISTANCE":
            // DISTANCE <metric> <loA>-<hiA> <loB>-<hiB>
            // metric ∈ jaccardNodes | jaccardEdges | rankL1 | rankL2 | typeL1 | boundedGED | wlL1 | spectralL2
            guard rawTokens.count >= 4 else { return .unknown(input) }
            let metric = rawTokens[1]
            let rangeA = rawTokens[2].split(separator: "-")
            let rangeB = rawTokens[3].split(separator: "-")
            guard rangeA.count == 2, rangeB.count == 2,
                  let loA = UInt64(rangeA[0]), let hiA = UInt64(rangeA[1]),
                  let loB = UInt64(rangeB[0]), let hiB = UInt64(rangeB[1]) else {
                return .unknown(input)
            }
            return .distance(metric: metric, loA: loA, hiA: hiA, loB: loB, hiB: hiB)

        case "ANCESTRY":
            // ANCESTRY FROM <node> DEPTH <d>
            guard let fromIdx = tokens.firstIndex(of: "FROM"),
                  fromIdx + 1 < tokens.count,
                  let node = Int(tokens[fromIdx + 1]),
                  let depthIdx = tokens.firstIndex(of: "DEPTH"),
                  depthIdx + 1 < tokens.count,
                  let depth = Int(tokens[depthIdx + 1]) else {
                return .unknown(input)
            }
            return .ancestry(node: node, depth: depth)

        case "SIMILAR_DECISIONS":
            // SIMILAR_DECISIONS TO <node> DEPTH <d> K <k> [AMONG TRUTH <t>]
            guard let toIdx = tokens.firstIndex(of: "TO"),
                  toIdx + 1 < tokens.count,
                  let node = Int(tokens[toIdx + 1]),
                  let depthIdx = tokens.firstIndex(of: "DEPTH"),
                  depthIdx + 1 < tokens.count,
                  let depth = Int(tokens[depthIdx + 1]),
                  let kIdx = tokens.firstIndex(of: "K"),
                  kIdx + 1 < tokens.count,
                  let k = Int(tokens[kIdx + 1]) else {
                return .unknown(input)
            }
            var truthFilter: UInt8? = nil
            if let amongIdx = tokens.firstIndex(of: "AMONG"),
               amongIdx + 2 < tokens.count,
               tokens[amongIdx + 1] == "TRUTH",
               let t = UInt8(tokens[amongIdx + 2]) {
                truthFilter = t
            }
            return .similarDecisions(node: node, depth: depth, k: k, truthFilter: truthFilter)

        case "SELECT":
            // SELECT truth <k> rank <lo>-<hi>
            //   → secondary-index lookup; matching node IDs via shm (Int32 array).
            guard tokens.count >= 5,
                  tokens[1] == "TRUTH",
                  let truthVal = UInt8(tokens[2]),
                  tokens[3] == "RANK" else {
                return .unknown(input)
            }
            let range = rawTokens[4].split(separator: "-")
            guard range.count == 2,
                  let lo = UInt64(range[0]),
                  let hi = UInt64(range[1]) else {
                return .unknown(input)
            }
            return .selectByTruthRank(truth: truthVal, rankLo: lo, rankHi: hi)

        case "TILED":
            // TILED OPEN <dir> [<K>]
            // TILED BFS <id> <globalId> <depth> [BACK]
            // TILED SELECT <id> <truth> <lo> <hi>
            // TILED STATUS <id>
            // TILED LIST
            // TILED CLOSE <id>
            // TILED TICK <id> [<n>] [SYNC]
            // TILED GET <id> <globalId> TRUTH
            // NOT a twin verb (routers aren't a twin registry:
            // `TiledGraphRouter`'s own header comment), so this is parsed
            // at the top level, not routed through `parseTwin`.
            guard rawTokens.count >= 2 else { return .unknown(input) }
            switch tokens[1] {
            case "OPEN":
                guard rawTokens.count >= 3 else { return .unknown(input) }
                var k = 2
                if rawTokens.count >= 4 {
                    guard let kv = Int(rawTokens[3]) else { return .unknown(input) }
                    k = kv
                }
                return .tiledOpen(dir: rawTokens[2], k: k)
            case "BFS":
                guard rawTokens.count >= 5,
                      let globalId = UInt64(rawTokens[3]),
                      let depth = Int(rawTokens[4]) else {
                    return .unknown(input)
                }
                let backward = tokens.count >= 6 && tokens[5] == "BACK"
                return .tiledBFS(id: rawTokens[2], globalId: globalId, depth: depth, backward: backward)
            case "SELECT":
                guard rawTokens.count >= 6,
                      let truthVal = UInt8(rawTokens[3]),
                      let lo = UInt64(rawTokens[4]),
                      let hi = UInt64(rawTokens[5]) else {
                    return .unknown(input)
                }
                return .tiledSelect(id: rawTokens[2], truth: truthVal, rankLo: lo, rankHi: hi)
            case "STATUS":
                guard rawTokens.count >= 3 else { return .unknown(input) }
                return .tiledStatus(id: rawTokens[2])
            case "LIST":
                return .tiledList
            case "CLOSE":
                guard rawTokens.count >= 3 else { return .unknown(input) }
                return .tiledClose(id: rawTokens[2])
            case "TICK":
                // TILED TICK <id> [<n>] [SYNC] — n defaults to 1; SYNC, if
                // present, always trails any explicit n. Anything past
                // that shape (extra tokens, a non-numeric n) is `.unknown`.
                guard rawTokens.count >= 3 else { return .unknown(input) }
                var n = 1
                var sync = false
                var idx = 3
                if idx < rawTokens.count && tokens[idx] != "SYNC" {
                    guard let nv = Int(rawTokens[idx]) else { return .unknown(input) }
                    n = nv
                    idx += 1
                }
                if idx < rawTokens.count && tokens[idx] == "SYNC" {
                    sync = true
                    idx += 1
                }
                guard idx == rawTokens.count else { return .unknown(input) }
                return .tiledTick(id: rawTokens[2], n: n, sync: sync)
            case "GET":
                // TILED GET <id> <globalId> TRUTH — trailing token MUST be
                // TRUTH (the only readback this verb offers today).
                guard rawTokens.count == 5,
                      let globalId = UInt64(rawTokens[3]),
                      tokens[4] == "TRUTH" else {
                    return .unknown(input)
                }
                return .tiledGetTruth(id: rawTokens[2], globalId: globalId)
            default:
                return .unknown(input)
            }

        case "SET_RANKS_BULK":
            // SET_RANKS_BULK  — caller has already written u64 rank vector
            // of length nodeCount to shm offset 8. Daemon reads and commits.
            return .setRanksBulk

        case "SET_LUTS_BULK":
            // SET_LUTS_BULK — u64[nodeCount] LUT vector at shm offset 8.
            return .setLutsBulk

        case "SET_NEIGHBORS_BULK":
            // SET_NEIGHBORS_BULK — Int32[nodeCount*6] vector at shm offset 8.
            return .setNeighborsBulk

        case "CONNECT_BACK_BULK":
            guard tokens.count == 1 else { return .unknown(input) }
            return .connectBackBulk

        case "SET_TRUTH_BULK":
            guard tokens.count == 1 else { return .unknown(input) }
            return .setTruthBulk

        case "TRUTH_SLICE":
            // TRUTH_SLICE NODES <lo>-<hi> [BYTES] | TRUTH_SLICE RANK <lo>-<hi> [BYTES]
            guard tokens.count == 3 || (tokens.count == 4 && tokens[3] == "BYTES"),
                  tokens[1] == "NODES" || tokens[1] == "RANK" else { return .unknown(input) }
            let range = tokens[2].split(separator: "-", omittingEmptySubsequences: false)
            guard range.count == 2, let lo = UInt64(range[0]), let hi = UInt64(range[1]) else {
                return .unknown(input)
            }
            return .truthSlice(byRank: tokens[1] == "RANK", lo: lo, hi: hi, bytes: tokens.count == 4)

        case "SET_LUTS":
            // SET_LUTS NODES|RANK <lo>-<hi> FILL <hex64>
            // SET_LUTS NODES|RANK <lo>-<hi> MAP [MASK <hex64>] <from>=<to> …
            return parseSetLuts(tokens) ?? .unknown(input)

        case "SET_TRUTH":
            // SET_TRUTH NODES|RANK <lo>-<hi> FILL <v>   (v decimal 0…255, as SET TRUTH)
            guard tokens.count == 5, tokens[1] == "NODES" || tokens[1] == "RANK", tokens[3] == "FILL",
                  let v = UInt8(tokens[4]) else { return .unknown(input) }
            let range = tokens[2].split(separator: "-", omittingEmptySubsequences: false)
            guard range.count == 2, let lo = UInt64(range[0]), let hi = UInt64(range[1]) else { return .unknown(input) }
            return .setTruthFill(tokens[1] == "RANK" ? .rank(lo, hi) : .nodes(lo, hi), v)

        case "SET_MODES_BULK":
            guard tokens.count == 1 else { return .unknown(input) }
            return .setModesBulk

        case "SET_TTABLE_IDS_BULK":
            guard tokens.count == 1 else { return .unknown(input) }
            return .setTTableIdsBulk

        case "SET_THRESH_BULK":
            guard tokens.count == 1 else { return .unknown(input) }
            return .setThreshBulk

        case "TTABLE_BULK":
            // TTABLE_BULK <first> <count> — u8[729·count] at shm offset 8.
            guard tokens.count == 3, let first = Int(tokens[1]), let count = Int(tokens[2]) else {
                return .unknown(input)
            }
            return .ttableBulk(first: first, count: count)

        case "TTABLE":
            // TTABLE DEFINE <tid> <729 chars of - 0 +>
            // TTABLE PRESET <tid> <name> <k>
            // TTABLE GET <tid>
            guard tokens.count >= 3, let tid = Int(tokens[2]) else { return .unknown(input) }
            switch tokens[1] {
            case "DEFINE":
                guard tokens.count == 4 else { return .unknown(input) }
                return .ttableDefine(tid: tid, table: rawTokens[3])
            case "PRESET":
                guard tokens.count == 5, let k = Int(tokens[4]) else { return .unknown(input) }
                return .ttablePreset(tid: tid, name: tokens[3], k: k)
            case "GET":
                guard tokens.count == 3 else { return .unknown(input) }
                return .ttableGet(tid: tid)
            default:
                return .unknown(input)
            }

        case "BFS_DEPTHS":
            // BFS_DEPTHS FROM <seed>                  — undirected (default)
            // BFS_DEPTHS FROM <seed> BACKWARD         — inputs-only
            guard let fromIdx = tokens.firstIndex(of: "FROM"),
                  fromIdx + 1 < tokens.count,
                  let seed = Int(tokens[fromIdx + 1]) else {
                return .unknown(input)
            }
            let undirected = !tokens.contains("BACKWARD")
            return .bfsDepths(seed: seed, undirected: undirected)

        case "COMPOSE":
            // COMPOSE NOT <src> INTO <dst>
            // COMPOSE <AND|OR|XOR> <src1> <src2> INTO <dst>
            // Bitwise composition of LUTs at the source(s) into the destination.
            guard rawTokens.count >= 2 else { return .unknown(input) }
            let op = tokens[1]
            guard let intoIdx = tokens.firstIndex(of: "INTO"),
                  intoIdx + 1 < tokens.count,
                  let dst = Int(tokens[intoIdx + 1]) else {
                return .unknown(input)
            }
            switch op {
            case "NOT":
                // COMPOSE NOT <src> INTO <dst>
                guard tokens.count >= 5,
                      let src1 = Int(tokens[2]) else { return .unknown(input) }
                return .composeLUT(op: "NOT", src1: src1, src2: nil, dst: dst)
            case "AND", "OR", "XOR":
                // COMPOSE <op> <src1> <src2> INTO <dst>
                guard tokens.count >= 6,
                      let src1 = Int(tokens[2]),
                      let src2 = Int(tokens[3]) else { return .unknown(input) }
                return .composeLUT(op: op, src1: src1, src2: src2, dst: dst)
            default:
                return .unknown(input)
            }

        case "EXPORT":
            // EXPORT MORTON <dir>
            guard rawTokens.count >= 3, tokens[1] == "MORTON" else { return .unknown(input) }
            return .exportMorton(dir: rawTokens[2])

        case "IMPORT":
            // IMPORT MORTON <dir>
            guard rawTokens.count >= 3, tokens[1] == "MORTON" else { return .unknown(input) }
            return .importMorton(dir: rawTokens[2])

        case "VALIDATE":
            return .validateGraph

        case "STATUS":
            return .status

        case "TICK":
            // TICK UNTIL_STABLE [MAX k].
            if tokens.count > 1 && tokens[1] == "UNTIL_STABLE" {
                if tokens.count == 2 { return .tickUntilStable(max: nil) }
                guard tokens.count == 4, tokens[2] == "MAX", let k = Int(tokens[3]) else { return .unknown(input) }
                return .tickUntilStable(max: k)
            }
            // `TICK <garbage>` is unknown,
            // not one tick. `TICK` and `TICK <integer>` are unchanged.
            if tokens.count > 1 {
                guard let count = Int(tokens[1]) else { return .unknown(input) }
                return .tick(count: count)
            }
            return .tick(count: 1)

        case "TICK_SYNC":
            // Double-buffered synchronous mode: every node reads the
            // previous tick's values (CA semantics, one hop per tick).
            let count = tokens.count > 1 ? Int(tokens[1]) ?? 1 : 1
            return .tickSync(count: count)

        case "EVAL":
            let whereIdx = tokens.firstIndex(of: "WHERE")
            let predicate = whereIdx.flatMap { parsePredicate(tokens, after: $0) }
            // The RANK clause used to be parsed and then ignored. EVAL's rows are the
            // rank-0 roots, so a rank range on them is trivial and the meant
            // scope change is new semantics: every RANK form is refused here,
            // before anything runs. The one RANK token that is not the clause
            // is a spaced predicate's own field (`WHERE rank = 0`).
            let fieldIdx = predicate?.field == "rank" ? whereIdx.map { $0 + 1 } : nil
            if tokens.indices.contains(where: { tokens[$0] == "RANK" && $0 != fieldIdx }) {
                return .dslParse(Self.evalRankClauseRefusal)
            }
            return .eval(predicate: predicate)

        case "NODES":
            var rank: Int? = nil
            var predicate: Predicate? = nil

            if let atIdx = tokens.firstIndex(of: "AT"),
               atIdx + 2 < tokens.count,
               tokens[atIdx + 1] == "RANK" {
                rank = Int(tokens[atIdx + 2])
            }
            if let whereIdx = tokens.firstIndex(of: "WHERE") {
                predicate = parsePredicate(tokens, after: whereIdx)
            }
            return .nodes(rank: rank, predicate: predicate)

        case "TRAVERSE":
            guard let fromIdx = tokens.firstIndex(of: "FROM"),
                  fromIdx + 1 < tokens.count,
                  let node = Int(tokens[fromIdx + 1]),
                  let depthIdx = tokens.firstIndex(of: "DEPTH"),
                  depthIdx + 1 < tokens.count,
                  let depth = Int(tokens[depthIdx + 1]) else {
                return .unknown(input)
            }
            return .traverse(fromNode: node, depth: depth)

        case "SET":
            guard tokens.count >= 4, let node = Int(tokens[1]) else {
                return .unknown(input)
            }
            switch tokens[2] {
            case "TRUTH":
                guard let val = UInt8(tokens[3]) else { return .unknown(input) }
                return .setTruth(node: node, value: val)
            case "RANK":
                guard let val = UInt64(tokens[3]) else { return .unknown(input) }
                return .setRank(node: node, value: val)
            case "LUT":
                return .setLUT(node: node, preset: tokens[3])
            case "WEIGHT":
                // SET <node> WEIGHT <dir 0..5> <float>
                guard tokens.count >= 5, let dir = Int(tokens[3]),
                      let val = Float(tokens[4]) else { return .unknown(input) }
                return .setWeight(node: node, dir: dir, value: val)
            case "VALUE":
                guard let val = Float(tokens[3]) else { return .unknown(input) }
                return .setValue(node: node, value: val)
            case "MODE":
                // SET <id> MODE BINARY|TTABLE|TTHRESH [NOSKIP]
                if tokens.count == 4 { return .setMode(node: node, kind: tokens[3], noskip: false) }
                if tokens.count == 5 && tokens[4] == "NOSKIP" {
                    return .setMode(node: node, kind: tokens[3], noskip: true)
                }
                return .unknown(input)
            case "TTABLE":
                guard tokens.count == 4, let tid = Int(tokens[3]) else { return .unknown(input) }
                return .setTTableId(node: node, tid: tid)
            case "THRESH":
                guard tokens.count == 5, let lo = Float(rawTokens[3]), let hi = Float(rawTokens[4]) else {
                    return .unknown(input)
                }
                return .setThresh(node: node, lo: lo, hi: hi)
            case "TRIT":
                guard tokens.count == 4, let t = Int(tokens[3]) else { return .unknown(input) }
                return .setTrit(node: node, trit: t)
            default:
                return .unknown(input)
            }

        case "CLEAR":
            // CLEAR <node> EDGES        — clear combinational edges into node
            // CLEAR <node> BACK_EDGES   — clear BACK_EDGEs into node
            guard tokens.count >= 3, let node = Int(tokens[1]) else {
                return .unknown(input)
            }
            switch tokens[2] {
            case "EDGES":      return .clearEdges(node: node)
            case "BACK_EDGES": return .clearBackEdges(node: node)
            default:           return .unknown(input)
            }

        case "CONNECT":
            // CONNECT FROM <src> TO <dst>            — combinational edge
            // CONNECT BACK FROM <src> TO <dst>       — typed BACK_EDGE
            let isBack = tokens.count >= 2 && tokens[1] == "BACK"
            guard let fromIdx = tokens.firstIndex(of: "FROM"),
                  fromIdx + 1 < tokens.count,
                  let src = Int(tokens[fromIdx + 1]),
                  let toIdx = tokens.firstIndex(of: "TO"),
                  toIdx + 1 < tokens.count,
                  let dst = Int(tokens[toIdx + 1]) else {
                return .unknown(input)
            }
            return isBack ? .connectBack(from: src, to: dst)
                          : .connect(from: src, to: dst)

        case "GRAPH":
            if tokens.count > 1 && tokens[1] == "INFO" {
                return .graphInfo
            }
            return .unknown(input)

        case "GET":
            // GET <node> TRUTH
            // GET <node> TRIT     — a ternary node's trit
            guard tokens.count >= 3, let node = Int(tokens[1]) else {
                return .unknown(input)
            }
            if tokens[2] == "TRIT" && tokens.count == 3 { return .getTrit(node: node) }
            guard tokens[2] == "TRUTH" else { return .unknown(input) }
            return .getTruth(node: node)

        case "STREAM", "HEADER", "RECORD", "RINGS", "CLOCK", "GEAR", "XCONV", "BUDGET", "ALARM", "BANK", "VIEW", "KERNEL", "FOLD", "HOOK":
            // Twin-spec DSL — see DSLParser+Twin.swift for the grammar.
            // FOLD, KERNEL and HOOK joined this route on 2026-09-10.
            return parseTwin(rawTokens: rawTokens, tokens: tokens, input: input)

        default:
            return .unknown(input)
        }
    }

    /// A 64-bit hex word, with or without 0x, 1…16 digits.
    static func hex64<S: StringProtocol>(_ s: S) -> UInt64? {
        var t = Substring(s)
        if t.hasPrefix("0X") || t.hasPrefix("0x") { t = t.dropFirst(2) }
        guard (1...16).contains(t.count), t.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return UInt64(t, radix: 16)
    }

    /// `SET_LUTS`'s grammar (upper-cased tokens). nil: malformed
    /// (an unknown command). MAP's pair count and keys are the handler's to
    /// refuse by name, so `MAP` with no pair parses.
    static func parseSetLuts(_ tokens: [String]) -> DSLCommand? {
        guard tokens.count >= 4, tokens[1] == "NODES" || tokens[1] == "RANK" else { return nil }
        let range = tokens[2].split(separator: "-", omittingEmptySubsequences: false)
        guard range.count == 2, let lo = UInt64(range[0]), let hi = UInt64(range[1]) else { return nil }
        let sel: DagDBEngine.LutSelection = tokens[1] == "RANK" ? .rank(lo, hi) : .nodes(lo, hi)
        switch tokens[3] {
        case "FILL":
            guard tokens.count == 5, let v = hex64(tokens[4]) else { return nil }
            return .setLuts(sel, .fill(v))
        case "MAP":
            var i = 4
            var mask = UInt64.max
            if i < tokens.count && tokens[i] == "MASK" {
                guard i + 1 < tokens.count, let m = hex64(tokens[i + 1]) else { return nil }
                mask = m
                i += 2
            }
            var pairs: [DagDBEngine.LutPair] = []
            while i < tokens.count {
                let kv = tokens[i].split(separator: "=", omittingEmptySubsequences: false)
                guard kv.count == 2, let f = hex64(kv[0]), let t = hex64(kv[1]) else { return nil }
                pairs.append(DagDBEngine.LutPair(from: f, to: t))
                i += 1
            }
            return .setLuts(sel, .map(mask: mask, pairs: pairs))
        default:
            return nil
        }
    }

    /// Parse "field=value" or "field = value" after WHERE
    /// The refusal of EVAL's RANK clause, the way out named.
    static let evalRankClauseRefusal =
        "EVAL takes no RANK clause: EVAL reports the rank-0 roots (scope=roots), "
        + "and NODES AT RANK <n> [WHERE <field><op><value>] reads other ranks; nothing ran"

    private static func parsePredicate(_ tokens: [String], after whereIdx: Int) -> Predicate? {
        let remaining = tokens[(whereIdx + 1)...].joined(separator: " ")

        // Try "field=value" (no spaces)
        for op in ["!=", "<=", ">=", "=", "<", ">"] {
            if let range = remaining.range(of: op) {
                let field = String(remaining[remaining.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces).lowercased()
                let valStr = String(remaining[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces).first ?? ""
                if let value = Int(valStr), let parsedOp = Predicate.Op(rawValue: op) {
                    return Predicate(field: field, op: parsedOp, value: value)
                }
            }
        }
        return nil
    }
}
