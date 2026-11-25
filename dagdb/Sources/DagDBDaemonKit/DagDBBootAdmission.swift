/// The boot's admission.
///
/// The startup snapshot load and the WAL replay rebuild state before any command runs. Earlier builds' boot
/// admitted one thing, 1.1 x the WHOLE log, and nothing it rebuilt: a replay booted at 1.45x a
/// 0.05 GiB budget, a startup load peaked at 7.4x, and a daemon whose state fit its budget refused to start over
/// log bytes that all lay behind its snapshot. Now every step is admitted as the live verb admits it, against the
/// same check (`admit()`: max(footprint, fixed state + ledger) + new <= budget):
/// - the snapshot load as LOAD (the file's bytes, the twin section's decode, the files it names at their live
///   verbs' charges, banks and hook rows);
/// - each window of the log replay reads (the log is never read whole), each import part it stages;
/// - each replayed record at its live verb's charge (`replayCharge`);
/// - and the state at the end (`finalRefusal`): the daemon never starts over its budget.
/// A refusal stops the boot by name: the bytes needed, the budget, and the flag with the size to pass.
///
/// The ledger is recomputed lazily: between exact sums the admitted charges are added (each charge is at least
/// what it adds to the ledger, and a close only lowers it), so a long log is not re-summed record by record; the
/// exact sum is taken again whenever the running figure would refuse.
///
/// Amateur engineering project; no competitive claims; errors likely.
import Foundation
import DagDB

public final class DagDBBootAdmission {
    public let budget: DaemonMemoryBudget
    let engine: DagDBEngine
    let twin: TwinState
    private var ledger: Int? = nil
    private var pending = 0.0
    /// The admissions asked and the exact ledger sums taken (for the tests' record).
    public private(set) var asked = 0
    public private(set) var exactSums = 0

    public init(budget: DaemonMemoryBudget, engine: DagDBEngine, twin: TwinState) {
        self.budget = budget; self.engine = engine; self.twin = twin
    }

    func exactLedger() -> Int {
        exactSums += 1
        return DagDBCommandHandler.ledgerBytes(twin: twin, engine: engine, sessions: [], routerBytes: [])
    }

    /// The smallest --mem-budget-gb, in GiB rounded up at the third decimal, whose budget holds `total` bytes.
    static func gibToPass(_ total: Int) -> String {
        let g = (Double(total) / Double(DaemonMemoryBudget.gib) * 1000).rounded(.up) / 1000
        return String(format: "%.3f", max(g, 0.001))
    }

    /// The refusal line (the needed bytes, the budget, the remedy with its size;
    /// a step's size is a floor, never named as if it were sufficient for the whole boot).
    func refusalLine(need: Int, what: String, footprint f: Int, committed: Int?) -> String {
        let held = max(f, committed ?? 0)
        let pass = Self.gibToPass(held + need)
        let commit = committed.map { "; committed \($0) B: fixed state \(budget.fixedStateBytes) + ledger \($0 - budget.fixedStateBytes)" } ?? ""
        return "ERROR out_of_budget: the boot needs at least \(held + need) bytes (this step; later steps may need more):"
            + " \(need) bytes for \(what), over the \(held) held (current footprint \(f) B\(commit)); the memory budget is"
            + " \(budget.budgetBytes) B (\(budget.gibText) GiB); start the daemon with --mem-budget-gb \(pass) or larger"
            + " (DAGDB_SANDBOX_MEM_BUDGET_GB=\(pass) for scripts/start_sandbox.sh)"
    }

    /// Admit `bytes` (already carrying its margin; at least two pages), or the refusal.
    public func admit(_ bytes: Int, _ what: String) -> String? {
        asked += 1
        let need = max(bytes, Int(DagDBCommandHandler.alloc1bMinNewBytes))
        let f = budget.footprint()
        if f + need > budget.budgetBytes { return refusalLine(need: need, what: what, footprint: f, committed: nil) }
        let fixed = budget.fixedStateBytes
        if ledger == nil || Double(fixed) + Double(ledger!) + pending + Double(need) > Double(budget.budgetBytes) {
            ledger = exactLedger(); pending = 0
        }
        let committed = fixed + ledger!
        if Double(committed) + pending + Double(need) > Double(budget.budgetBytes) {
            return refusalLine(need: need, what: what, footprint: f, committed: committed + Int(pending.rounded(.up)))
        }
        pending += Double(need)
        return nil
    }

    /// `DaemonFile.admission`'s form: bytes before the margin, admitted at 1.1 x (the file loaders, the snapshot's
    /// sections, the replay's windows).
    public var fileAdmission: (Int, String) -> String? {
        { [unowned self] b, what in self.admit(Int((AdmissionCharge.margin * Double(b)).rounded(.up)), "\(what), 1.1 x the bytes") }
    }

    /// A replayed record's live charge (`DagDBWAL.ReplayCharge`), or nil when it builds nothing to admit here (the
    /// files and banks a twin record rebuilds are admitted by `TwinState.apply` through `fileAdmission`).
    public func replayCharge(_ c: DagDBWAL.ReplayCharge) -> String? {
        switch c {
        case .twin(let op):
            guard let (b, what) = Self.twinCharge(op, twin: twin) else { return nil }
            return admit(Int(b.rounded(.up)), "replayed \(TwinWALCodec.recordWord(op)): \(what)")
        case .backEdges(let k):
            // CONNECT BACK's charge (admitBackEdges, staging aside): 1.1*8 B per new edge, the lists' new buffers
            // when they must grow (1.1*16 B per edge), and the ternary lanes on a binary graph's first one.
            let m = engine.backEdgeSrcs.count
            let cap = min(engine.backEdgeSrcs.capacity, engine.backEdgeDsts.capacity)
            let grow = m + k > cap ? DagDBCommandHandler.alloc1bMargin * 16 * Double(m + k) : 0
            let lanes = engine.ternaryLaneView == nil ? DagDBCommandHandler.alloc1bTernaryLaneBytes(nodes: engine.nodeCount) : 0
            guard grow > 0 || lanes > 0 else { return nil }                // within capacity: nothing new is allocated
            return admit(Int((DagDBCommandHandler.alloc1bMargin * 8 * Double(k) + grow + lanes).rounded(.up)),
                         "replayed back edges, 1.1*8 B each for \(k)" + (grow > 0 ? ", the lists' new buffers, 1.1*16 B per edge" : "")
                             + (lanes > 0 ? ", the ternary lanes, 1.1*11 B per node" : ""))
        case .tables(let t):
            guard t > engine.ttableCapacity else { return nil }
            let cap = DagDBCommandHandler.libraryCapacity(from: engine.ttableCapacity, for: t)
            return admit(Int(DagDBCommandHandler.alloc1bLibraryBytes(capacity: cap).rounded(.up)),
                         "the replayed table library's new buffer, 1.1*729 B per table for a capacity of \(cap)")
        }
    }

    /// The live verb's admitted bytes for a twin record (after the margin) and their words; nil for a record whose
    /// verb admits nothing of its own here (TWIN_CLOSE, the sweep, STREAM_STATE) or whose files or atoms
    /// `TwinState.apply` admits (ALARM, VIEW, KERNEL LOAD, BANK OPEN).
    static func twinCharge(_ op: TwinOp, twin: TwinState) -> (Double, String)? {
        typealias H = DagDBCommandHandler
        switch op {
        case .streamOpen(_, let name, _, _, _, _):
            return (H.alloc1bStreamBytes(nameBytes: name.utf8.count), "STREAM OPEN's charge, 1.1*(410 B + the name)")
        case .recordOpen(_, let name, _, _, _, _, _):
            return (H.alloc1bRecordBytes(nameBytes: name.utf8.count, slices: 0, draws: 0), "RECORD OPEN's charge, 1.1*(300 B + the name)")
        case .recordSlice(let id, let count):
            let have = Double(twin.records.get(id)?.slices.count ?? 0)
            return (H.alloc1bMargin * (100 + 8.32 * Double(count) + 48 * have),
                    "RECORD SLICE's charge, 1.1*(100 B + 1.04*8*count + 48 B per slice held)")
        case .ringsOpen(_, _, let r, let c):
            return (H.alloc1bRingsBytes(rings: Int(r), cells: Int(c)), "RINGS OPEN's charge, 1.1*(1.414*32*r*c + 1 KB)")
        case .ringsWrite(let id, _):
            guard let ring = twin.rings.get(id) else { return nil }
            return (H.alloc1bMargin * 1.414 * 32 * Double(ring.rings) * Double(ring.cellsPerRing),
                    "RINGS WRITE's charge, the copy of the cells, 1.1*1.414*32*r*c")
        case .clockOpen:
            return (H.alloc1bClockBytes, "CLOCK OPEN's charge, 1.1*80 B")
        case .clockAdvance(let id, let n, _):
            let b = H.clockAdvanceRowBytes(twin: twin, clockId: id, n: Int(min(n, UInt64(TwinState.replayCap))))
            return b > 0 ? (b, "CLOCK ADVANCE's charge, the bound hooks' new rows and the longest ledger's copy, 1.1*2*104 B per row") : nil
        case .gearOpen(_, let clockId, let name, _, _):
            let onClock = Double(twin.clocks.get(clockId)?.gearIds.count ?? 0)
            return (H.alloc1bGearBytes(nameBytes: name.utf8.count) + H.alloc1bMargin * 16 * onClock,
                    "GEAR OPEN's charge, 1.1*(550 B + the name) and the gear list's copy, 1.1*16 B per gear")
        case .layoutOpen(_, let cost, let minTier):
            let p = cost.count, t = cost.first?.count ?? 0, c = minTier.count
            return (H.alloc1bLayoutBytes(pockets: p, tiers: t, classes: c) + H.alloc1bMargin * (24 * Double(p * t) + 16 * Double(c)),
                    "BUDGET OPEN's charge, a layout 1.1*(1.17*(8*p*t + 8*c) + 600 B) and its staging 1.1*(24*p*t + 16*c)")
        case .hookOpen(_, let params):
            guard let a = twin.alarms.get(params.alarmId) else { return nil }
            return (H.alloc1bHookBytes(records: a.fixture.records.count), "HOOK OPEN's charge, 1.1*(260 B per record + 4 KB)")
        case .hookStep(let id, let count):
            guard let h = twin.hooks.get(id) else { return nil }
            let taken = min(count, max(0, h.hook.frames - h.hook.t))
            let b = H.withByteMargin(AdmitCount(240) * AdmitCount(taken) + AdmitCount(104) * AdmitCount(h.hook.ledger.count))
            return (Double(b.value), "HOOK STEP's charge, 240 B per frame stepped and 104 B per ledger row copied" + H.byteMarginWords)
        case .alarmLoad, .viewLoad, .kernelLoad, .bankOpen, .streamState, .close, .hookSweep:
            return nil
        }
    }

    /// The state the boot rebuilt, against the budget: nil when it fits, else the refusal (the daemon does not
    /// start). Called after the replay, with the recovery's transients released.
    public func finalRefusal() -> String? {
        let f = budget.footprint()
        let committed = budget.fixedStateBytes + exactLedger()
        let held = max(f, committed)
        guard held > budget.budgetBytes else { return nil }
        let pass = Self.gibToPass(held)
        return "ERROR out_of_budget: the boot needs at least \(held) bytes (this step, the state it rebuilt: footprint \(f) B;"
            + " committed \(committed) B: fixed state \(budget.fixedStateBytes) + ledger \(committed - budget.fixedStateBytes)),"
            + " above the memory budget of \(budget.budgetBytes) B (\(budget.gibText) GiB); start the daemon with"
            + " --mem-budget-gb \(pass) or larger (DAGDB_SANDBOX_MEM_BUDGET_GB=\(pass) for scripts/start_sandbox.sh)"
    }
}
