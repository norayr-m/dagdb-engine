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

enum DSLCommand {
    case status
    case tick(count: Int)
    case eval(predicate: Predicate?, rankFrom: Int?, rankTo: Int?)
    case nodes(rank: Int?, predicate: Predicate?)
    case traverse(fromNode: Int, depth: Int)
    case setTruth(node: Int, value: UInt8)
    case graphInfo
    case unknown(String)
}

struct Predicate {
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

    func evaluate(truth: UInt8, rank: UInt8, nodeType: UInt8) -> Bool {
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

struct DSLParser {

    static func parse(_ input: String) -> DSLCommand {
        let tokens = input.uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        guard let first = tokens.first else { return .unknown(input) }

        switch first {
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
            guard tokens.count >= 4,
                  let node = Int(tokens[1]),
                  tokens[2] == "TRUTH",
                  let val = UInt8(tokens[3]) else {
                return .unknown(input)
            }
            return .setTruth(node: node, value: val)

        case "GRAPH":
            if tokens.count > 1 && tokens[1] == "INFO" {
                return .graphInfo
            }
            return .unknown(input)

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
