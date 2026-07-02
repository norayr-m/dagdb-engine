/// DSLParser — Graph-native query language for DagDB.
///
/// Commands:
///   STATUS                              → daemon info
///   TICK <n>                            → run n ticks
///   EVAL [WHERE <predicate>] [RANK <from> TO <to>]  → evaluate and return roots
///   NODES [AT RANK <n>] [WHERE <predicate>]         → list nodes
///   TRAVERSE FROM <node> DEPTH <n>      → walk n ranks from node
///   SET <node> TRUTH <0|1|2>            → set truth state
///   GRAPH INFO                          → graph statistics

import Foundation
import DagDB

public enum DSLCommand {
    case status
    case tick(count: Int)
    case eval(predicate: Predicate?, rankFrom: Int?, rankTo: Int?)
    case nodes(rank: Int?, predicate: Predicate?)
    case traverse(fromNode: Int, depth: Int)
    case setTruth(node: Int, value: UInt8)
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
    case load(path: String)
    case exportMorton(dir: String)
    case importMorton(dir: String)
    case validateGraph
    case saveJSON(path: String)
    case loadJSON(path: String)
    case saveCSV(dir: String)
    case loadCSV(dir: String)
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
            guard rawTokens.count >= 2 else { return .unknown(input) }
            if rawTokens.count >= 3 && tokens[1] == "JSON" {
                return .saveJSON(path: rawTokens[2])
            }
            if rawTokens.count >= 3 && tokens[1] == "CSV" {
                return .saveCSV(dir: rawTokens[2])
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
            let count = tokens.count > 1 ? Int(tokens[1]) ?? 1 : 1
            return .tick(count: count)

        case "EVAL":
            var predicate: Predicate? = nil
            var rankFrom: Int? = nil
            var rankTo: Int? = nil

            if let whereIdx = tokens.firstIndex(of: "WHERE") {
                predicate = parsePredicate(tokens, after: whereIdx)
            }
            if let rankIdx = tokens.firstIndex(of: "RANK"),
               rankIdx + 1 < tokens.count {
                rankFrom = Int(tokens[rankIdx + 1])
                if let toIdx = tokens.firstIndex(of: "TO"),
                   toIdx + 1 < tokens.count {
                    rankTo = Int(tokens[toIdx + 1])
                }
            }
            return .eval(predicate: predicate, rankFrom: rankFrom, rankTo: rankTo)

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
            guard tokens.count >= 3, let node = Int(tokens[1]),
                  tokens[2] == "TRUTH" else {
                return .unknown(input)
            }
            return .getTruth(node: node)

        default:
            return .unknown(input)
        }
    }

    /// Parse "field=value" or "field = value" after WHERE
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
