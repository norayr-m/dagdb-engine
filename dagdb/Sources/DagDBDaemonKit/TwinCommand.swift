/// TwinCommand — DSL grammar for the seven twin-spec primitives, reached
/// over the daemon socket (interface phase, 2026-09). One case per grammar line in the plan;
/// `isReadOnly` gates which verbs a `READER <id> …` session may run — the
/// twin registries are daemon-global (§0.13), so every mutating verb is
/// forbidden inside a reader session regardless of which registry it touches.
///
/// Wiring is staged: T8.1 lands the grammar + parser + dispatch skeleton
/// only. The four verb families (STREAM/HEADER/RECORD, RINGS/CLOCK/GEAR,
/// XCONV/BUDGET, ALARM) are implemented in T8.2–T8.5; until then every case
/// falls through to a stub reply. BANK (spec 8, the waveform mouth) lands
/// in T9.
import DagDB

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
    // gate K3 (docs/contracts/KERNELS_GATES_FROZEN.md) — the sealed
    // cross-convolution residual, distinct from XCONV CHECK (the patrol
    // check, unchanged above): this is the court's frozen formula, and it
    // is NOT the contract's finding — XCONV CHECK stays the standing cheap
    // check.
    case xconvSealed(id: String, n: Int, warmup: Int?)

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

    // MARK: VIEW

    case viewLoad(path: String, sha256: String?)
    case viewReflex(id: String, stations: Int)
    case viewRung(id: String, stations: Int)
    case viewCeiling(id: String, stations: Int)
    case viewFeatures(id: String, frame: Int, stations: Int)
    case viewInfo(id: String)
    case viewList
    case viewClose(id: String)

    // MARK: KERNEL (gate K3/K4 — docs/contracts/KERNELS_GATES_FROZEN.md).
    // Per-path kernel pairs, stored BY REFERENCE (path + sha256); τA/τB/
    // σ_source are DECLARED at LOAD (K4: never read from the kernels
    // file), and drive the derived warmup XCONV SEALED uses by default.

    case kernelLoad(path: String, sha256: String?, tauA: Double?, tauB: Double?, sigmaSource: Double?, declaredWarmup: Int?)
    case kernelInfo(id: String)
    case kernelList
    case kernelClose(id: String)

    // MARK: BANK

    case bankOpen(name: String, spec: WaveBank.Spec?, aliased: Bool)
    case bankGenerate(id: String, columns: Int)
    case bankFit(id: String)
    case bankNoise(id: String, seed: Int, count: Int)
    case bankBench(id: String, columns: Int, reps: Int)
    case bankInfo(id: String)
    case bankList
    case bankClose(id: String)

    // MARK: FOLD (gate F4 — docs/contracts/FOLD_API_GATES_FROZEN.md). Pure
    // computation over the daemon's CURRENT lanes (neighbors, edge weights,
    // nodeValue-as-leak, rank); nothing persisted, no WAL, no registry —
    // every FOLD verb is read-only, RUN included.

    case foldRun(maxRank: Int, keepRank: Int, f1: Int, f2: Int, f3: Int, checkpoints: [Int])
    case foldKept
    case foldSource(which: Int)
    case foldTier(level: String, which: Int)
    case foldInfo

    // MARK: HOOK (gate H5 — docs/contracts/HOOK_GATES_FROZEN.md). The
    // attention hook — the sealed allocator court as a daemon-global ticked
    // process, bound to an alarm set + budget layout (SEALED default,
    // `layoutId == nil`) + budget B + lag delta + policy, and optionally a
    // master clock. OPEN mints a hook with resolved defaults (delta 3,
    // policy allocator); STEP/STATE/LEDGER/INFO/LIST/CLOSE mirror ALARM's
    // shape. `delta`/`policy` are optional at the grammar layer (DSLParser+
    // Twin.swift resolves DELTA/POLICY's absence to nil here, the HANDLER
    // resolves nil to the sealed defaults) so a caller can tell "not given"
    // from "given the sealed value explicitly" if it ever matters.

    case hookOpen(alarmId: String, layoutId: String?, budget: Double, delta: Int?, policy: AttentionHook.Policy?, clockId: String?)
    case hookStep(id: String, count: Int)
    case hookState(id: String)
    case hookLedger(id: String, from: Int?, count: Int?)
    case hookInfo(id: String)
    case hookList
    case hookClose(id: String)

    /// Read-only iff the verb's second token is one of
    /// STATE/LIST/INFO/CHECK/REPLAY/VERIFY/RECALL/ALLOCATE/FRAME/COURT/SUCCESSOR/CORRUPT/LEDGER
    /// — plus `FOLD KEPT/SOURCE/TIER/INFO`, and NOT `FOLD RUN` (D5)
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
             .xconvCheck, .xconvSealed,
             .budgetAllocate, .budgetInfo, .budgetList,
             .alarmInfo, .alarmList, .alarmFrame, .alarmCourt, .alarmSuccessor, .alarmCorrupt,
             .bankGenerate, .bankFit, .bankNoise, .bankBench, .bankInfo, .bankList,
             .viewReflex, .viewRung, .viewCeiling, .viewFeatures, .viewInfo, .viewList,
             .kernelInfo, .kernelList,
             .foldKept, .foldSource, .foldTier, .foldInfo,
             .hookState, .hookLedger, .hookInfo, .hookList:
            return true

        case .streamOpen, .streamNext, .streamClose,
             .recordOpen, .recordSlice, .recordClose,
             .ringsOpen, .ringsWrite, .ringsClose,
             .clockOpen, .clockAdvance, .clockClose,
             .gearOpen, .gearClose,
             .budgetOpen, .budgetSealed, .budgetClose,
             .alarmLoad, .alarmClose,
             .bankOpen, .bankClose,
             .viewLoad, .viewClose,
             .kernelLoad, .kernelClose,
             .hookOpen, .hookStep, .hookClose,
             // D5 · `FOLD RUN` assigns daemon-global `lastFold`
             // (DagDBCommandHandler+TwinFold.swift), which every other FOLD
             // verb reads — so a reader session, or a browser through the
             // web bridge, overwrote what the primary saw (audit B finding
             // 18). Nothing is minted and nothing is persisted, but the
             // handler's state moves, and that is what read-only means here.
             // The four look-only FOLD verbs stay read-only above.
             .foldRun:
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
        case let (.xconvSealed(i1, n1, w1), .xconvSealed(i2, n2, w2)):
            return i1 == i2 && n1 == n2 && w1 == w2

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

        case let (.viewLoad(p1, s1), .viewLoad(p2, s2)): return p1 == p2 && s1 == s2
        case let (.viewReflex(i1, s1), .viewReflex(i2, s2)): return i1 == i2 && s1 == s2
        case let (.viewRung(i1, s1), .viewRung(i2, s2)): return i1 == i2 && s1 == s2
        case let (.viewCeiling(i1, s1), .viewCeiling(i2, s2)): return i1 == i2 && s1 == s2
        case let (.viewFeatures(i1, f1, s1), .viewFeatures(i2, f2, s2)): return i1 == i2 && f1 == f2 && s1 == s2
        case let (.viewInfo(i1), .viewInfo(i2)): return i1 == i2
        case (.viewList, .viewList): return true
        case let (.viewClose(i1), .viewClose(i2)): return i1 == i2

        case let (.kernelLoad(p1, s1, ta1, tb1, sg1, dw1), .kernelLoad(p2, s2, ta2, tb2, sg2, dw2)):
            return p1 == p2 && s1 == s2 && ta1 == ta2 && tb1 == tb2 && sg1 == sg2 && dw1 == dw2
        case let (.kernelInfo(i1), .kernelInfo(i2)): return i1 == i2
        case (.kernelList, .kernelList): return true
        case let (.kernelClose(i1), .kernelClose(i2)): return i1 == i2

        case let (.bankOpen(n1, s1, a1), .bankOpen(n2, s2, a2)): return n1 == n2 && s1 == s2 && a1 == a2
        case let (.bankGenerate(i1, m1), .bankGenerate(i2, m2)): return i1 == i2 && m1 == m2
        case let (.bankFit(i1), .bankFit(i2)): return i1 == i2
        case let (.bankNoise(i1, s1, n1), .bankNoise(i2, s2, n2)): return i1 == i2 && s1 == s2 && n1 == n2
        case let (.bankBench(i1, m1, r1), .bankBench(i2, m2, r2)): return i1 == i2 && m1 == m2 && r1 == r2
        case let (.bankInfo(i1), .bankInfo(i2)): return i1 == i2
        case (.bankList, .bankList): return true
        case let (.bankClose(i1), .bankClose(i2)): return i1 == i2

        case let (.foldRun(mx1, kp1, a1, b1, c1, ck1), .foldRun(mx2, kp2, a2, b2, c2, ck2)):
            return mx1 == mx2 && kp1 == kp2 && a1 == a2 && b1 == b2 && c1 == c2 && ck1 == ck2
        case (.foldKept, .foldKept): return true
        case let (.foldSource(w1), .foldSource(w2)): return w1 == w2
        case let (.foldTier(l1, w1), .foldTier(l2, w2)): return l1 == l2 && w1 == w2
        case (.foldInfo, .foldInfo): return true

        case let (.hookOpen(a1, l1, b1, d1, p1, c1), .hookOpen(a2, l2, b2, d2, p2, c2)):
            return a1 == a2 && l1 == l2 && b1 == b2 && d1 == d2 && p1 == p2 && c1 == c2
        case let (.hookStep(i1, n1), .hookStep(i2, n2)): return i1 == i2 && n1 == n2
        case let (.hookState(i1), .hookState(i2)): return i1 == i2
        case let (.hookLedger(i1, f1, c1), .hookLedger(i2, f2, c2)): return i1 == i2 && f1 == f2 && c1 == c2
        case let (.hookInfo(i1), .hookInfo(i2)): return i1 == i2
        case (.hookList, .hookList): return true
        case let (.hookClose(i1), .hookClose(i2)): return i1 == i2

        default:
            return false
        }
    }
}
