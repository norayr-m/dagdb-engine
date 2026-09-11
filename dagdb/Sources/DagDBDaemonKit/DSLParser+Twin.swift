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
import DagDB

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
        case "BANK":    return parseBank(rawTokens, tokens, input)
        case "VIEW":    return parseView(rawTokens, tokens, input)
        case "KERNEL":  return parseKernel(rawTokens, tokens, input)
        case "FOLD":    return parseFold(rawTokens, tokens, input)
        case "HOOK":    return parseHook(rawTokens, tokens, input)
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
        guard tokens.count >= 2 else { return .unknown(input) }
        switch tokens[1] {
        case "CHECK":
            // XCONV CHECK <nA> <nB> <kA> <kB> <warmup>
            guard rawTokens.count == 7,
                  let nA = Int(rawTokens[2]), let nB = Int(rawTokens[3]),
                  let kA = Int(rawTokens[4]), let kB = Int(rawTokens[5]),
                  let warmup = Int(rawTokens[6]) else { return .unknown(input) }
            return .twin(.xconvCheck(nA: nA, nB: nB, kA: kA, kB: kB, warmup: warmup))
        case "SEALED":
            // XCONV SEALED <id> <n> [<warmup>] — gate K3, the court's
            // frozen residual (distinct from XCONV CHECK, the patrol check
            // above).
            guard rawTokens.count == 4 || rawTokens.count == 5,
                  let n = Int(rawTokens[3]) else { return .unknown(input) }
            var warmup: Int? = nil
            if rawTokens.count == 5 {
                guard let w = Int(rawTokens[4]) else { return .unknown(input) }
                warmup = w
            }
            return .twin(.xconvSealed(id: rawTokens[2], n: n, warmup: warmup))
        default:
            return .unknown(input)
        }
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

    // MARK: - VIEW

    /// docs/contracts/DERIVED_VIEWS_GATES_FROZEN.md, gate V6 — the alarm-set
    /// derived views over the sealed cortex v4 world. Grammar mirrors ALARM's
    /// LOAD/INFO/LIST/CLOSE shape; REFLEX/RUNG/CEILING/FEATURES are new.
    private static func parseView(_ rawTokens: [String], _ tokens: [String], _ input: String) -> DSLCommand {
        guard tokens.count >= 2 else { return .unknown(input) }
        switch tokens[1] {
        case "LOAD":
            // VIEW LOAD <path> [SHA <hex64>]
            guard rawTokens.count == 3 || rawTokens.count == 5 else { return .unknown(input) }
            if rawTokens.count == 5 {
                guard tokens[3] == "SHA" else { return .unknown(input) }
                return .twin(.viewLoad(path: rawTokens[2], sha256: rawTokens[4]))
            }
            return .twin(.viewLoad(path: rawTokens[2], sha256: nil))
        case "REFLEX":
            // VIEW REFLEX <id> <S>
            guard rawTokens.count == 4, let s = Int(rawTokens[3]) else { return .unknown(input) }
            return .twin(.viewReflex(id: rawTokens[2], stations: s))
        case "RUNG":
            // VIEW RUNG <id> <S>
            guard rawTokens.count == 4, let s = Int(rawTokens[3]) else { return .unknown(input) }
            return .twin(.viewRung(id: rawTokens[2], stations: s))
        case "CEILING":
            // VIEW CEILING <id> <S>
            guard rawTokens.count == 4, let s = Int(rawTokens[3]) else { return .unknown(input) }
            return .twin(.viewCeiling(id: rawTokens[2], stations: s))
        case "FEATURES":
            // VIEW FEATURES <id> <frame> <S>
            guard rawTokens.count == 5,
                  let frame = Int(rawTokens[3]),
                  let s = Int(rawTokens[4]) else { return .unknown(input) }
            return .twin(.viewFeatures(id: rawTokens[2], frame: frame, stations: s))
        case "INFO":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.viewInfo(id: rawTokens[2]))
        case "LIST":
            guard rawTokens.count == 2 else { return .unknown(input) }
            return .twin(.viewList)
        case "CLOSE":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.viewClose(id: rawTokens[2]))
        default:
            return .unknown(input)
        }
    }

    // MARK: - KERNEL

    /// docs/contracts/KERNELS_GATES_FROZEN.md, gates K3/K4 — per-path
    /// kernel storage. Grammar mirrors ALARM/VIEW's LOAD/INFO/LIST/CLOSE
    /// shape; LOAD's optional groups are in a FIXED order: `[SHA <hex64>]
    /// [TAU <τA> <τB> SIGMA <σ>] [WARMUP <n>]` — any other order (or a
    /// group appearing twice) is `.unknown`, never reordered/matched.
    private static func parseKernel(_ rawTokens: [String], _ tokens: [String], _ input: String) -> DSLCommand {
        guard tokens.count >= 2 else { return .unknown(input) }
        switch tokens[1] {
        case "LOAD":
            return parseKernelLoad(rawTokens, tokens, input)
        case "INFO":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.kernelInfo(id: rawTokens[2]))
        case "LIST":
            guard rawTokens.count == 2 else { return .unknown(input) }
            return .twin(.kernelList)
        case "CLOSE":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.kernelClose(id: rawTokens[2]))
        default:
            return .unknown(input)
        }
    }

    private static func parseKernelLoad(_ rawTokens: [String], _ tokens: [String], _ input: String) -> DSLCommand {
        // KERNEL LOAD <path> [SHA <hex64>] [TAU <τA> <τB> SIGMA <σ>] [WARMUP <n>]
        guard rawTokens.count >= 3 else { return .unknown(input) }
        let path = rawTokens[2]
        var idx = 3
        var sha256: String? = nil
        var tauA: Double? = nil
        var tauB: Double? = nil
        var sigmaSource: Double? = nil
        var declaredWarmup: Int? = nil

        if idx < tokens.count, tokens[idx] == "SHA" {
            guard idx + 1 < rawTokens.count else { return .unknown(input) }
            sha256 = rawTokens[idx + 1]
            idx += 2
        }
        if idx < tokens.count, tokens[idx] == "TAU" {
            guard idx + 4 < rawTokens.count,
                  let a = Double(rawTokens[idx + 1]),
                  let b = Double(rawTokens[idx + 2]),
                  tokens[idx + 3] == "SIGMA",
                  let s = Double(rawTokens[idx + 4]) else { return .unknown(input) }
            tauA = a; tauB = b; sigmaSource = s
            idx += 5
        }
        if idx < tokens.count, tokens[idx] == "WARMUP" {
            guard idx + 1 < rawTokens.count, let w = Int(rawTokens[idx + 1]) else { return .unknown(input) }
            declaredWarmup = w
            idx += 2
        }
        guard idx == rawTokens.count else { return .unknown(input) }
        return .twin(.kernelLoad(path: path, sha256: sha256, tauA: tauA, tauB: tauB,
                                  sigmaSource: sigmaSource, declaredWarmup: declaredWarmup))
    }

    // MARK: - BANK

    private static func parseBank(_ rawTokens: [String], _ tokens: [String], _ input: String) -> DSLCommand {
        guard tokens.count >= 2 else { return .unknown(input) }
        switch tokens[1] {
        case "OPEN":
            // BANK OPEN <name> [<T> <fs> <f0> <H> <centers> <freqs> <sigmaFrac> [ALIASED]]
            // No numbers ⇒ WaveBank.Spec.referenceNyquistSafe (the repaired
            // bank), not aliased. All seven or none; a trailing ALIASED
            // token (case-sensitive, exactly that word) is only valid with
            // all seven numbers present — ALIASED alone is .unknown.
            guard rawTokens.count == 3 || rawTokens.count == 10 || rawTokens.count == 11 else {
                return .unknown(input)
            }
            let name = rawTokens[2]
            if rawTokens.count == 3 {
                return .twin(.bankOpen(name: name, spec: nil, aliased: false))
            }
            var aliased = false
            if rawTokens.count == 11 {
                guard rawTokens[10] == "ALIASED" else { return .unknown(input) }
                aliased = true
            }
            guard let T = Int(rawTokens[3]),
                  let fs = Double(rawTokens[4]),
                  let f0 = Double(rawTokens[5]),
                  let H = Int(rawTokens[6]),
                  let centers = Int(rawTokens[7]),
                  let freqs = Int(rawTokens[8]),
                  let sigmaFrac = Double(rawTokens[9]) else { return .unknown(input) }
            let spec = WaveBank.Spec(
                samples: T, sampleRate: fs, f0: f0, harmonics: H,
                gaborCenters: centers, gaborFreqs: freqs, gaborSigmaFrac: sigmaFrac
            )
            return .twin(.bankOpen(name: name, spec: spec, aliased: aliased))
        case "GENERATE":
            // BANK GENERATE <id> <M>
            guard rawTokens.count == 4, let m = Int(rawTokens[3]) else { return .unknown(input) }
            return .twin(.bankGenerate(id: rawTokens[2], columns: m))
        case "FIT":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.bankFit(id: rawTokens[2]))
        case "NOISE":
            // BANK NOISE <id> <seed> <n>
            guard rawTokens.count == 5,
                  let seed = Int(rawTokens[3]),
                  let n = Int(rawTokens[4]) else { return .unknown(input) }
            return .twin(.bankNoise(id: rawTokens[2], seed: seed, count: n))
        case "BENCH":
            // BANK BENCH <id> <M> <reps>
            guard rawTokens.count == 5,
                  let m = Int(rawTokens[3]),
                  let reps = Int(rawTokens[4]) else { return .unknown(input) }
            return .twin(.bankBench(id: rawTokens[2], columns: m, reps: reps))
        case "INFO":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.bankInfo(id: rawTokens[2]))
        case "LIST":
            guard rawTokens.count == 2 else { return .unknown(input) }
            return .twin(.bankList)
        case "CLOSE":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.bankClose(id: rawTokens[2]))
        default:
            return .unknown(input)
        }
    }

    // MARK: - FOLD (gate F4)

    private static func parseFold(_ rawTokens: [String], _ tokens: [String], _ input: String) -> DSLCommand {
        guard tokens.count >= 2 else { return .unknown(input) }
        switch tokens[1] {
        case "RUN":
            return parseFoldRun(rawTokens, tokens, input)
        case "KEPT":
            guard rawTokens.count == 2 else { return .unknown(input) }
            return .twin(.foldKept)
        case "SOURCE":
            // FOLD SOURCE <1|2|3>
            guard rawTokens.count == 3, let which = Int(rawTokens[2]), (1...3).contains(which) else {
                return .unknown(input)
            }
            return .twin(.foldSource(which: which))
        case "TIER":
            // FOLD TIER <level|final> <1|2|3> — level read from rawTokens to
            // preserve "final"'s lowercase (it's a tiers-dictionary key, not
            // a verb token).
            guard rawTokens.count == 4, let which = Int(rawTokens[3]), (1...3).contains(which) else {
                return .unknown(input)
            }
            return .twin(.foldTier(level: rawTokens[2], which: which))
        case "INFO":
            guard rawTokens.count == 2 else { return .unknown(input) }
            return .twin(.foldInfo)
        default:
            return .unknown(input)
        }
    }

    private static func parseFoldRun(_ rawTokens: [String], _ tokens: [String], _ input: String) -> DSLCommand {
        // FOLD RUN <maxRank> <keepRank> <f1> <f2> [<f3>] [CHECK <l1,l2,...>]
        guard rawTokens.count >= 6,
              let maxRank = Int(rawTokens[2]),
              let keepRank = Int(rawTokens[3]),
              let f1 = Int(rawTokens[4]),
              let f2 = Int(rawTokens[5]) else { return .unknown(input) }

        var idx = 6
        var f3 = -1
        if idx < rawTokens.count && tokens[idx] != "CHECK" {
            guard let f3v = Int(rawTokens[idx]) else { return .unknown(input) }
            f3 = f3v
            idx += 1
        }

        var checkpoints: [Int] = []
        if idx < rawTokens.count {
            guard tokens[idx] == "CHECK", idx + 1 < rawTokens.count else { return .unknown(input) }
            let parts = rawTokens[idx + 1].split(separator: ",", omittingEmptySubsequences: false)
            guard !parts.isEmpty else { return .unknown(input) }
            let ints = parts.map { Int($0) }
            guard ints.allSatisfy({ $0 != nil }) else { return .unknown(input) }
            checkpoints = ints.map { $0! }
            idx += 2
        }

        guard idx == rawTokens.count else { return .unknown(input) }
        return .twin(.foldRun(maxRank: maxRank, keepRank: keepRank, f1: f1, f2: f2, f3: f3, checkpoints: checkpoints))
    }

    // MARK: - HOOK (gate H5 — docs/contracts/HOOK_GATES_FROZEN.md)

    /// Grammar mirrors ALARM/VIEW/KERNEL's LOAD/INFO/LIST/CLOSE shape;
    /// OPEN's optional groups are in a FIXED order: `[DELTA <d>] [POLICY
    /// allocator|greedy|uniform] [CLOCK <c>]` — any other order (or a group
    /// twice) is `.unknown`, never reordered/matched (mirrors KERNEL LOAD's
    /// `[SHA] [TAU/SIGMA] [WARMUP]`).
    private static func parseHook(_ rawTokens: [String], _ tokens: [String], _ input: String) -> DSLCommand {
        guard tokens.count >= 2 else { return .unknown(input) }
        switch tokens[1] {
        case "OPEN":
            return parseHookOpen(rawTokens, tokens, input)
        case "STEP":
            // HOOK STEP <id> <n>
            guard rawTokens.count == 4, let n = Int(rawTokens[3]) else { return .unknown(input) }
            return .twin(.hookStep(id: rawTokens[2], count: n))
        case "STATE":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.hookState(id: rawTokens[2]))
        case "LEDGER":
            // HOOK LEDGER <id> [<from> <count>]
            guard rawTokens.count == 3 || rawTokens.count == 5 else { return .unknown(input) }
            if rawTokens.count == 5 {
                guard let from = Int(rawTokens[3]), let count = Int(rawTokens[4]) else { return .unknown(input) }
                return .twin(.hookLedger(id: rawTokens[2], from: from, count: count))
            }
            return .twin(.hookLedger(id: rawTokens[2], from: nil, count: nil))
        case "INFO":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.hookInfo(id: rawTokens[2]))
        case "LIST":
            guard rawTokens.count == 2 else { return .unknown(input) }
            return .twin(.hookList)
        case "CLOSE":
            guard rawTokens.count == 3 else { return .unknown(input) }
            return .twin(.hookClose(id: rawTokens[2]))
        default:
            return .unknown(input)
        }
    }

    private static func parseHookOpen(_ rawTokens: [String], _ tokens: [String], _ input: String) -> DSLCommand {
        // HOOK OPEN <alarmId> <layoutId|SEALED> <budget> [DELTA <d>]
        // [POLICY allocator|greedy|uniform] [CLOCK <c>]
        guard rawTokens.count >= 5 else { return .unknown(input) }
        let alarmId = rawTokens[2]
        let layoutId: String? = tokens[3] == "SEALED" ? nil : rawTokens[3]
        guard let budget = Double(rawTokens[4]) else { return .unknown(input) }

        var idx = 5
        var delta: Int? = nil
        var policy: AttentionHook.Policy? = nil
        var clockId: String? = nil

        if idx < tokens.count, tokens[idx] == "DELTA" {
            guard idx + 1 < rawTokens.count, let d = Int(rawTokens[idx + 1]) else { return .unknown(input) }
            delta = d
            idx += 2
        }
        if idx < tokens.count, tokens[idx] == "POLICY" {
            guard idx + 1 < rawTokens.count,
                  let p = AttentionHook.Policy(rawValue: rawTokens[idx + 1]) else { return .unknown(input) }
            policy = p
            idx += 2
        }
        if idx < tokens.count, tokens[idx] == "CLOCK" {
            guard idx + 1 < rawTokens.count else { return .unknown(input) }
            clockId = rawTokens[idx + 1]
            idx += 2
        }
        guard idx == rawTokens.count else { return .unknown(input) }
        return .twin(.hookOpen(alarmId: alarmId, layoutId: layoutId, budget: budget, delta: delta, policy: policy, clockId: clockId))
    }
}
