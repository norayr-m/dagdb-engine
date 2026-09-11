/// DSLParser+Twin — grammar for the nine twin verb families (interface phase, 2026-09).
/// Routed from DSLParser.parse when the first uppercased token is one of
/// STREAM HEADER RECORD RINGS CLOCK GEAR XCONV BUDGET ALARM.
///
/// Conventions (plan §0 / T8.1 grammar block):
///  - ids/names/paths are read from `rawTokens` (case preserved).
///  - verbs are matched against `tokens` (uppercased).
///  - integers are u64 decimal or `0x`-prefixed hex.
///  - a gear/GEAR ratio is one token "num/den".
///  - a BUDGET ALLOCATE claim is one token "pocket:class".
///  - any arity/parse failure returns `.unknown(input)`, never a partially
///    built TwinCommand.
import Foundation

extension DSLParser {

    static func parseTwin(rawTokens: [String], tokens: [String], input: String) -> DSLCommand {
        guard tokens.count >= 1 else { return .unknown(input) }

        switch tokens[0] {
        case "STREAM":  return parseStream(rawTokens, tokens, input)
        case "HEADER":  return parseHeader(rawTokens, tokens, input)
        case "RECORD":  return parseRecord(rawTokens, tokens, input)
        case "RINGS":   return parseRings(rawTokens, tokens, input)
        case "CLOCK":   return parseClock(rawTokens, tokens, input)
        case "GEAR":    return parseGear(rawTokens, tokens, input)
        case "XCONV":   return parseXConv(rawTokens, tokens, input)
        case "BUDGET":  return parseBudget(rawTokens, tokens, input)
        case "ALARM":   return parseAlarm(rawTokens, tokens, input)
        default:        return .unknown(input)
        }
    }

    // MARK: - Numeric helpers

    /// u64 decimal or 0x/0X-prefixed hex.
    static func parseTwinU64(_ s: String) -> UInt64? {
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            return UInt64(s.dropFirst(2), radix: 16)
        }
        return UInt64(s)
    }

    /// "num/den" → (num, den), both u64 decimal or hex.
    static func parseRatio(_ s: String) -> (num: UInt64, den: UInt64)? {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let num = parseTwinU64(String(parts[0])),
              let den = parseTwinU64(String(parts[1])) else { return nil }
        return (num, den)
    }

    /// "pocket:class" → (pocket, classIndex), both plain Int.
    static func parseClaim(_ s: String) -> (pocket: Int, classIndex: Int)? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let pocket = Int(parts[0]),
              let classIndex = Int(parts[1]) else { return nil }
        return (pocket, classIndex)
    }

    // MARK: - STREAM

    private static func parseStream(_ rawTokens: [String], _ tokens: [String], _ input: String) -> DSLCommand {
        guard tokens.count >= 2 else { return .unknown(input) }
        switch tokens[1] {
        case "OPEN":
            // STREAM OPEN <name> <stateHi> <stateLo> <incHi> <incLo>
            guard rawTokens.count == 7,
                  let stateHi = parseTwinU64(rawTokens[3]),
                  let stateLo = parseTwinU64(rawTokens[4]),
                  let incHi = parseTwinU64(rawTokens[5]),
                  let incLo = parseTwinU64(rawTokens[6]) else { return .unknown(input) }
            return .twin(.streamOpen(name: rawTokens[2], stateHi: stateHi, stateLo: stateLo, incHi: incHi, incLo: incLo))
        case "NEXT":
            // STREAM NEXT <id> <n>
            guard rawTokens.count == 4, let n = Int(rawTokens[3]) else { return .unknown(input) }
            return .twin(.streamNext(id: rawTokens[2], n: n))
        case "STATE":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.streamState(id: rawTokens[2]))
        case "CLOSE":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.streamClose(id: rawTokens[2]))
        case "LIST":
            guard rawTokens.count == 2 else { return .unknown(input) }
            return .twin(.streamList)
        default:
            return .unknown(input)
        }
    }

    // MARK: - HEADER

    private static func parseHeader(_ rawTokens: [String], _ tokens: [String], _ input: String) -> DSLCommand {
        // HEADER CHECK <band> <tau> <comb> <echo> <record> <step> <floor>
        guard tokens.count >= 2, tokens[1] == "CHECK", rawTokens.count == 9 else { return .unknown(input) }
        let nums = rawTokens[2..<9].map { Double($0) }
        guard nums.allSatisfy({ $0 != nil }) else { return .unknown(input) }
        let v = nums.map { $0! }
        return .twin(.headerCheck(band: v[0], tau: v[1], comb: v[2], echo: v[3], record: v[4], step: v[5], floor: v[6]))
    }

    // MARK: - RECORD

    private static func parseRecord(_ rawTokens: [String], _ tokens: [String], _ input: String) -> DSLCommand {
        guard tokens.count >= 2 else { return .unknown(input) }
        switch tokens[1] {
        case "OPEN":
            // RECORD OPEN <name> <band> <tau> <comb> <echo> <record> <step> <floor> <stateHi> <stateLo> <incHi> <incLo>
            guard rawTokens.count == 14 else { return .unknown(input) }
            let headerNums = rawTokens[3..<10].map { Double($0) }
            guard headerNums.allSatisfy({ $0 != nil }) else { return .unknown(input) }
            let h = headerNums.map { $0! }
            guard let stateHi = parseTwinU64(rawTokens[10]),
                  let stateLo = parseTwinU64(rawTokens[11]),
                  let incHi = parseTwinU64(rawTokens[12]),
                  let incLo = parseTwinU64(rawTokens[13]) else { return .unknown(input) }
            return .twin(.recordOpen(
                name: rawTokens[2],
                band: h[0], tau: h[1], comb: h[2], echo: h[3], record: h[4], step: h[5], floor: h[6],
                stateHi: stateHi, stateLo: stateLo, incHi: incHi, incLo: incLo
            ))
        case "SLICE":
            guard rawTokens.count == 4, let count = Int(rawTokens[3]) else { return .unknown(input) }
            return .twin(.recordSlice(id: rawTokens[2], count: count))
        case "REPLAY":
            guard rawTokens.count == 4, let idx = Int(rawTokens[3]) else { return .unknown(input) }
            return .twin(.recordReplay(id: rawTokens[2], index: idx))
        case "VERIFY":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.recordVerify(id: rawTokens[2]))
        case "INFO":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.recordInfo(id: rawTokens[2]))
        case "CLOSE":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.recordClose(id: rawTokens[2]))
        case "LIST":
            guard rawTokens.count == 2 else { return .unknown(input) }
            return .twin(.recordList)
        default:
            return .unknown(input)
        }
    }

    // MARK: - RINGS

    private static func parseRings(_ rawTokens: [String], _ tokens: [String], _ input: String) -> DSLCommand {
        guard tokens.count >= 2 else { return .unknown(input) }
        switch tokens[1] {
        case "OPEN":
            // RINGS OPEN [<gear> <rings> <cells>]  (default 6 6 32)
            if rawTokens.count == 2 {
                return .twin(.ringsOpen(gear: 6, rings: 6, cells: 32))
            }
            guard rawTokens.count == 5,
                  let gear = parseTwinU64(rawTokens[2]),
                  let rings = Int(rawTokens[3]),
                  let cells = Int(rawTokens[4]) else { return .unknown(input) }
            return .twin(.ringsOpen(gear: gear, rings: rings, cells: cells))
        case "WRITE":
            // RINGS WRITE <id> <v1> [<v2> ...]  (at least one value required)
            guard rawTokens.count >= 4 else { return .unknown(input) }
            let values = rawTokens[3...].map { Float($0) }
            guard values.allSatisfy({ $0 != nil }) else { return .unknown(input) }
            return .twin(.ringsWrite(id: rawTokens[2], values: values.map { $0! }))
        case "RECALL":
            guard rawTokens.count == 4, let lag = Int(rawTokens[3]) else { return .unknown(input) }
            return .twin(.ringsRecall(id: rawTokens[2], lag: lag))
        case "INFO":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.ringsInfo(id: rawTokens[2]))
        case "CLOSE":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.ringsClose(id: rawTokens[2]))
        case "LIST":
            guard rawTokens.count == 2 else { return .unknown(input) }
            return .twin(.ringsList)
        default:
            return .unknown(input)
        }
    }

    // MARK: - CLOCK

    private static func parseClock(_ rawTokens: [String], _ tokens: [String], _ input: String) -> DSLCommand {
        guard tokens.count >= 2 else { return .unknown(input) }
        switch tokens[1] {
        case "OPEN":
            guard rawTokens.count == 2 else { return .unknown(input) }
            return .twin(.clockOpen)
        case "ADVANCE":
            // CLOCK ADVANCE <id> [<n>] [VALUE <f>]
            guard rawTokens.count >= 3 else { return .unknown(input) }
            let id = rawTokens[2]
            var n = 1
            var value: Float? = nil
            var idx = 3
            if idx < rawTokens.count && tokens[idx] != "VALUE" {
                guard let nVal = Int(rawTokens[idx]) else { return .unknown(input) }
                n = nVal
                idx += 1
            }
            if idx < rawTokens.count {
                guard tokens[idx] == "VALUE",
                      idx + 1 < rawTokens.count,
                      let f = Float(rawTokens[idx + 1]) else { return .unknown(input) }
                value = f
                idx += 2
            }
            guard idx == rawTokens.count else { return .unknown(input) }
            return .twin(.clockAdvance(id: id, n: n, value: value))
        case "STATE":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.clockState(id: rawTokens[2]))
        case "CLOSE":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.clockClose(id: rawTokens[2]))
        case "LIST":
            guard rawTokens.count == 2 else { return .unknown(input) }
            return .twin(.clockList)
        default:
            return .unknown(input)
        }
    }

    // MARK: - GEAR

    private static func parseGear(_ rawTokens: [String], _ tokens: [String], _ input: String) -> DSLCommand {
        guard tokens.count >= 2 else { return .unknown(input) }
        switch tokens[1] {
        case "OPEN":
            // GEAR OPEN <clockId> <name> <num>/<den>
            guard rawTokens.count == 5, let ratio = parseRatio(rawTokens[4]) else { return .unknown(input) }
            return .twin(.gearOpen(clockId: rawTokens[2], name: rawTokens[3], num: ratio.num, den: ratio.den))
        case "STATE":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.gearState(id: rawTokens[2]))
        case "CLOSE":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.gearClose(id: rawTokens[2]))
        default:
            return .unknown(input)
        }
    }

    // MARK: - XCONV

    private static func parseXConv(_ rawTokens: [String], _ tokens: [String], _ input: String) -> DSLCommand {
        // XCONV CHECK <nA> <nB> <kA> <kB> <warmup>
        guard tokens.count >= 2, tokens[1] == "CHECK", rawTokens.count == 7,
              let nA = Int(rawTokens[2]), let nB = Int(rawTokens[3]),
              let kA = Int(rawTokens[4]), let kB = Int(rawTokens[5]),
              let warmup = Int(rawTokens[6]) else { return .unknown(input) }
        return .twin(.xconvCheck(nA: nA, nB: nB, kA: kA, kB: kB, warmup: warmup))
    }

    // MARK: - BUDGET

    private static func parseBudget(_ rawTokens: [String], _ tokens: [String], _ input: String) -> DSLCommand {
        guard tokens.count >= 2 else { return .unknown(input) }
        switch tokens[1] {
        case "OPEN":
            // BUDGET OPEN <nPockets> <nTiers> <nClasses>
            guard rawTokens.count == 5,
                  let pockets = Int(rawTokens[2]),
                  let tiers = Int(rawTokens[3]),
                  let classes = Int(rawTokens[4]) else { return .unknown(input) }
            return .twin(.budgetOpen(nPockets: pockets, nTiers: tiers, nClasses: classes))
        case "SEALED":
            guard rawTokens.count == 2 else { return .unknown(input) }
            return .twin(.budgetSealed)
        case "ALLOCATE":
            // BUDGET ALLOCATE <id> <budget> <pocket>:<class> ...
            guard rawTokens.count >= 5, let budget = Double(rawTokens[3]) else { return .unknown(input) }
            let claimTokens = rawTokens[4...]
            let claims = claimTokens.map { parseClaim($0) }
            guard claims.allSatisfy({ $0 != nil }) else { return .unknown(input) }
            return .twin(.budgetAllocate(id: rawTokens[2], budget: budget, claims: claims.map { $0! }))
        case "INFO":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.budgetInfo(id: rawTokens[2]))
        case "CLOSE":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.budgetClose(id: rawTokens[2]))
        case "LIST":
            guard rawTokens.count == 2 else { return .unknown(input) }
            return .twin(.budgetList)
        default:
            return .unknown(input)
        }
    }

    // MARK: - ALARM

    private static func parseAlarm(_ rawTokens: [String], _ tokens: [String], _ input: String) -> DSLCommand {
        guard tokens.count >= 2 else { return .unknown(input) }
        switch tokens[1] {
        case "LOAD":
            // ALARM LOAD <path> [SHA <hex64>]
            guard rawTokens.count == 3 || rawTokens.count == 5 else { return .unknown(input) }
            if rawTokens.count == 5 {
                guard tokens[3] == "SHA" else { return .unknown(input) }
                return .twin(.alarmLoad(path: rawTokens[2], sha256: rawTokens[4]))
            }
            return .twin(.alarmLoad(path: rawTokens[2], sha256: nil))
        case "INFO":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.alarmInfo(id: rawTokens[2]))
        case "LIST":
            guard rawTokens.count == 2 else { return .unknown(input) }
            return .twin(.alarmList)
        case "CLOSE":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.alarmClose(id: rawTokens[2]))
        case "FRAME":
            guard rawTokens.count == 4, let idx = Int(rawTokens[3]) else { return .unknown(input) }
            return .twin(.alarmFrame(id: rawTokens[2], idx: idx))
        case "COURT":
            guard rawTokens.count == 4, let budget = Double(rawTokens[3]) else { return .unknown(input) }
            return .twin(.alarmCourt(id: rawTokens[2], budget: budget))
        case "SUCCESSOR":
            guard rawTokens.count == 7,
                  let budget = Double(rawTokens[3]),
                  let epsM = Double(rawTokens[4]),
                  let epsS = Double(rawTokens[5]),
                  let epsN = Double(rawTokens[6]) else { return .unknown(input) }
            return .twin(.alarmSuccessor(id: rawTokens[2], budget: budget, epsM: epsM, epsS: epsS, epsN: epsN))
        case "CORRUPT":
            guard rawTokens.count == 7,
                  let idx = Int(rawTokens[3]),
                  let epsM = Double(rawTokens[4]),
                  let epsS = Double(rawTokens[5]),
                  let epsN = Double(rawTokens[6]) else { return .unknown(input) }
            return .twin(.alarmCorrupt(id: rawTokens[2], idx: idx, epsM: epsM, epsS: epsS, epsN: epsN))
        default:
            return .unknown(input)
        }
    }
}
