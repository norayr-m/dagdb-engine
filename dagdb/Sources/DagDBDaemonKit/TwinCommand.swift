/// TwinCommand — DSL grammar for the seven twin-spec primitives, reached
/// over the daemon socket (interface phase, 2026-09). One case per grammar line in the plan;
/// `isReadOnly` gates which verbs a `READER <id> …` session may run — the
/// twin registries are daemon-global (§0.13), so every mutating verb is
/// forbidden inside a reader session regardless of which registry it touches.
///
/// Wiring is staged: T8.1 lands the grammar + parser + dispatch skeleton
/// only. The four verb families (STREAM/HEADER/RECORD, RINGS/CLOCK/GEAR,
/// XCONV/BUDGET, ALARM) are implemented in T8.2–T8.5; until then every case
/// falls through to a stub reply.
public enum TwinCommand: Equatable {

    // MARK: STREAM

    case streamOpen(name: String, stateHi: UInt64, stateLo: UInt64, incHi: UInt64, incLo: UInt64)
    case streamNext(id: String, n: Int)
    case streamState(id: String)
    case streamClose(id: String)
    case streamList

    // MARK: HEADER

    case headerCheck(band: Double, tau: Double, comb: Double, echo: Double, record: Double, step: Double, floor: Double)

    // MARK: RECORD

    case recordOpen(
        name: String,
        band: Double, tau: Double, comb: Double, echo: Double, record: Double, step: Double, floor: Double,
        stateHi: UInt64, stateLo: UInt64, incHi: UInt64, incLo: UInt64
    )
    case recordSlice(id: String, count: Int)
    case recordReplay(id: String, index: Int)
    case recordVerify(id: String)
    case recordInfo(id: String)
    case recordClose(id: String)
    case recordList

    // MARK: RINGS

    case ringsOpen(gear: UInt64, rings: Int, cells: Int)
    case ringsWrite(id: String, values: [Float])
    case ringsRecall(id: String, lag: Int)
    case ringsInfo(id: String)
    case ringsClose(id: String)
    case ringsList

    // MARK: CLOCK

    case clockOpen
    case clockAdvance(id: String, n: Int, value: Float?)
    case clockState(id: String)
    case clockClose(id: String)
    case clockList

    // MARK: GEAR

    case gearOpen(clockId: String, name: String, num: UInt64, den: UInt64)
    case gearState(id: String)
    case gearClose(id: String)

    // MARK: XCONV

    case xconvCheck(nA: Int, nB: Int, kA: Int, kB: Int, warmup: Int)

    // MARK: BUDGET

    case budgetOpen(nPockets: Int, nTiers: Int, nClasses: Int)
    case budgetSealed
    case budgetAllocate(id: String, budget: Double, claims: [(pocket: Int, classIndex: Int)])
    case budgetInfo(id: String)
    case budgetClose(id: String)
    case budgetList

    // MARK: ALARM

    case alarmLoad(path: String, sha256: String?)
    case alarmInfo(id: String)
    case alarmList
    case alarmClose(id: String)
    case alarmFrame(id: String, idx: Int)
    case alarmCourt(id: String, budget: Double)
    case alarmSuccessor(id: String, budget: Double, epsM: Double, epsS: Double, epsN: Double)
    case alarmCorrupt(id: String, idx: Int, epsM: Double, epsS: Double, epsN: Double)

    /// Read-only iff the verb's second token is one of
    /// STATE/LIST/INFO/CHECK/REPLAY/VERIFY/RECALL/ALLOCATE/FRAME/COURT/SUCCESSOR/CORRUPT
    /// (§0.13 — twin registries are daemon-global; a reader session may only
    /// look, never mutate).
    public var isReadOnly: Bool {
        switch self {
        case .streamState, .streamList,
             .headerCheck,
             .recordReplay, .recordVerify, .recordInfo, .recordList,
             .ringsRecall, .ringsInfo, .ringsList,
             .clockState, .clockList,
             .gearState,
             .xconvCheck,
             .budgetAllocate, .budgetInfo, .budgetList,
             .alarmInfo, .alarmList, .alarmFrame, .alarmCourt, .alarmSuccessor, .alarmCorrupt:
            return true

        case .streamOpen, .streamNext, .streamClose,
             .recordOpen, .recordSlice, .recordClose,
             .ringsOpen, .ringsWrite, .ringsClose,
             .clockOpen, .clockAdvance, .clockClose,
             .gearOpen, .gearClose,
             .budgetOpen, .budgetSealed, .budgetClose,
             .alarmLoad, .alarmClose:
            return false
        }
    }

    /// Equatable can't be auto-synthesized across the [(pocket: Int, classIndex: Int)]
    /// tuple array in `budgetAllocate`, so it's written out explicitly.
    public static func == (lhs: TwinCommand, rhs: TwinCommand) -> Bool {
        switch (lhs, rhs) {
        case let (.streamOpen(n1, sh1, sl1, ih1, il1), .streamOpen(n2, sh2, sl2, ih2, il2)):
            return n1 == n2 && sh1 == sh2 && sl1 == sl2 && ih1 == ih2 && il1 == il2
        case let (.streamNext(i1, n1), .streamNext(i2, n2)):
            return i1 == i2 && n1 == n2
        case let (.streamState(i1), .streamState(i2)): return i1 == i2
        case let (.streamClose(i1), .streamClose(i2)): return i1 == i2
        case (.streamList, .streamList): return true

        case let (.headerCheck(b1, t1, c1, e1, r1, s1, f1), .headerCheck(b2, t2, c2, e2, r2, s2, f2)):
            return b1 == b2 && t1 == t2 && c1 == c2 && e1 == e2 && r1 == r2 && s1 == s2 && f1 == f2

        case let (.recordOpen(n1, b1, t1, c1, e1, r1, s1, f1, sh1, sl1, ih1, il1),
                   .recordOpen(n2, b2, t2, c2, e2, r2, s2, f2, sh2, sl2, ih2, il2)):
            return n1 == n2 && b1 == b2 && t1 == t2 && c1 == c2 && e1 == e2 && r1 == r2
                && s1 == s2 && f1 == f2 && sh1 == sh2 && sl1 == sl2 && ih1 == ih2 && il1 == il2
        case let (.recordSlice(i1, c1), .recordSlice(i2, c2)): return i1 == i2 && c1 == c2
        case let (.recordReplay(i1, x1), .recordReplay(i2, x2)): return i1 == i2 && x1 == x2
        case let (.recordVerify(i1), .recordVerify(i2)): return i1 == i2
        case let (.recordInfo(i1), .recordInfo(i2)): return i1 == i2
        case let (.recordClose(i1), .recordClose(i2)): return i1 == i2
        case (.recordList, .recordList): return true

        case let (.ringsOpen(g1, r1, c1), .ringsOpen(g2, r2, c2)): return g1 == g2 && r1 == r2 && c1 == c2
        case let (.ringsWrite(i1, v1), .ringsWrite(i2, v2)): return i1 == i2 && v1 == v2
        case let (.ringsRecall(i1, l1), .ringsRecall(i2, l2)): return i1 == i2 && l1 == l2
        case let (.ringsInfo(i1), .ringsInfo(i2)): return i1 == i2
        case let (.ringsClose(i1), .ringsClose(i2)): return i1 == i2
        case (.ringsList, .ringsList): return true

        case (.clockOpen, .clockOpen): return true
        case let (.clockAdvance(i1, n1, v1), .clockAdvance(i2, n2, v2)):
            return i1 == i2 && n1 == n2 && v1 == v2
        case let (.clockState(i1), .clockState(i2)): return i1 == i2
        case let (.clockClose(i1), .clockClose(i2)): return i1 == i2
        case (.clockList, .clockList): return true

        case let (.gearOpen(c1, n1, num1, d1), .gearOpen(c2, n2, num2, d2)):
            return c1 == c2 && n1 == n2 && num1 == num2 && d1 == d2
        case let (.gearState(i1), .gearState(i2)): return i1 == i2
        case let (.gearClose(i1), .gearClose(i2)): return i1 == i2

        case let (.xconvCheck(a1, b1, ka1, kb1, w1), .xconvCheck(a2, b2, ka2, kb2, w2)):
            return a1 == a2 && b1 == b2 && ka1 == ka2 && kb1 == kb2 && w1 == w2

        case let (.budgetOpen(p1, t1, c1), .budgetOpen(p2, t2, c2)): return p1 == p2 && t1 == t2 && c1 == c2
        case (.budgetSealed, .budgetSealed): return true
        case let (.budgetAllocate(i1, b1, cl1), .budgetAllocate(i2, b2, cl2)):
            guard i1 == i2, b1 == b2, cl1.count == cl2.count else { return false }
            for (a, b) in zip(cl1, cl2) where a.pocket != b.pocket || a.classIndex != b.classIndex { return false }
            return true
        case let (.budgetInfo(i1), .budgetInfo(i2)): return i1 == i2
        case let (.budgetClose(i1), .budgetClose(i2)): return i1 == i2
        case (.budgetList, .budgetList): return true

        case let (.alarmLoad(p1, s1), .alarmLoad(p2, s2)): return p1 == p2 && s1 == s2
        case let (.alarmInfo(i1), .alarmInfo(i2)): return i1 == i2
        case (.alarmList, .alarmList): return true
        case let (.alarmClose(i1), .alarmClose(i2)): return i1 == i2
        case let (.alarmFrame(i1, x1), .alarmFrame(i2, x2)): return i1 == i2 && x1 == x2
        case let (.alarmCourt(i1, b1), .alarmCourt(i2, b2)): return i1 == i2 && b1 == b2
        case let (.alarmSuccessor(i1, b1, m1, s1, n1), .alarmSuccessor(i2, b2, m2, s2, n2)):
            return i1 == i2 && b1 == b2 && m1 == m2 && s1 == s2 && n1 == n2
        case let (.alarmCorrupt(i1, x1, m1, s1, n1), .alarmCorrupt(i2, x2, m2, s2, n2)):
            return i1 == i2 && x1 == x2 && m1 == m2 && s1 == s2 && n1 == n2

        default:
            return false
        }
    }
}
