/// The daemon's memory budget and the per-command admission.
///
/// The budget is a property of the PROCESS. It reads the process's own
/// physical footprint from the OS (`proc_pid_rusage`, RUSAGE_INFO_V4,
/// `ri_phys_footprint`): the number that counts everything the daemon holds,
/// also what nobody accounted for, and that never under-counts (freed large
/// blocks malloc keeps are counted until reused; `start_sandbox.sh` launches
/// with `MallocLargeCache=0` so they go back between commands). The daemon
/// (`DagDBDaemon/main.swift`) always configures one; a handler built without
/// one (an in-process host that does not own its process) has no memory
/// budget, prints no `mem_budget_gb=`, and still applies every work cap.
///
/// Default: min(max(8 GiB, 2 × fixed state), 32 GiB), with the
/// fixed state from a measured fit, 191.0 B/node + 2.55 MB.
/// `--mem-budget-gb G` (GiB) overrides it.
import Foundation
import Darwin
import DagDB

public final class DaemonMemoryBudget {
    public static let gib = 1 << 30
    /// The fixed state at start, 191.0 B/node + 2.55 MB.
    public static let fixedBytesPerNode = 191.0
    public static let fixedBytesConstant = 2_550_000.0
    public static let floorBytes = 8 * gib
    public static let ceilingBytes = 32 * gib

    /// The fixed-state formula, in bytes (rounded up).
    public static func fixedStateBytes(nodeCount: Int) -> Int {
        Int((fixedBytesPerNode * Double(max(nodeCount, 0)) + fixedBytesConstant).rounded(.up))
    }

    /// min(max(8 GiB, 2 × fixed state), 32 GiB).
    public static func defaultBudgetBytes(nodeCount: Int) -> Int {
        min(max(floorBytes, 2 * fixedStateBytes(nodeCount: nodeCount)), ceilingBytes)
    }

    public let budgetBytes: Int
    /// "default" or "--mem-budget-gb".
    public let source: String
    /// The fixed state the committed-bytes check adds the ledger to. `make`
    /// sets it from the fixed-state formula for the daemon's node count; a budget built by hand (an
    /// in-process host, a test) carries 0 unless told.
    /// The node formula's part, without the Metal pool's reservation.
    public let nodeFixedStateBytes: Int
    /// The Metal pool's reservation, part of the fixed state, admitted once at boot:
    /// 1.1 x the pool measured on this machine (`AdmissionCharge.metalPoolReservationBytes`), raised when the daemon's
    /// first GPU command measures a larger one. 0 on a budget built by hand unless told.
    public private(set) var poolReservationBytes: Int
    /// The fixed state the committed-bytes check adds the ledger to: the node formula plus the pool's reservation.
    public var fixedStateBytes: Int { nodeFixedStateBytes + poolReservationBytes }
    /// The footprint reader; the process's own phys_footprint unless a test injects one.
    public var footprint: () -> Int

    public init(budgetBytes: Int, source: String, footprint: (() -> Int)? = nil, fixedStateBytes: Int = 0,
                poolReservationBytes: Int = 0) {
        self.budgetBytes = budgetBytes
        self.source = source
        self.nodeFixedStateBytes = fixedStateBytes
        self.poolReservationBytes = poolReservationBytes
        self.footprint = footprint ?? DaemonMemoryBudget.physFootprint
    }

    /// The default budget for `nodeCount`, or `overrideGiB` GiB when given
    /// (finite and > 0; the caller refuses anything else before calling).
    /// With the Metal pool's reservation in the fixed state (the default budget's formula is unchanged).
    public static func make(nodeCount: Int, overrideGiB: Double?) -> DaemonMemoryBudget {
        let fixed = fixedStateBytes(nodeCount: nodeCount)
        let pool = AdmissionCharge.metalPoolReservationBytes
        if let g = overrideGiB {
            return DaemonMemoryBudget(budgetBytes: Int((g * Double(gib)).rounded(.down)), source: "--mem-budget-gb",
                                      fixedStateBytes: fixed, poolReservationBytes: pool)
        }
        return DaemonMemoryBudget(budgetBytes: defaultBudgetBytes(nodeCount: nodeCount), source: "default", fixedStateBytes: fixed,
                                  poolReservationBytes: pool)
    }

    /// The smallest --mem-budget-gb, in GiB rounded up at the third decimal, whose budget holds `total`.
    public static func gibToPass(_ total: Int) -> String {
        let g = (Double(total) / Double(gib) * 1000).rounded(.up) / 1000
        return String(format: "%.3f", max(g, 0.001))
    }

    /// The boot line that states the reservation.
    public var poolReservationLine: String {
        "Metal pool reservation: \(poolReservationBytes) B (1.1 x the \(AdmissionCharge.metalPoolMeasuredBytes) B pool measured on"
            + " the M5 Max this was built on), admitted once in the fixed state: \(fixedStateBytes) B = \(nodeFixedStateBytes) B"
            + " (191.0 B/node + 2.55 MB) + the reservation"
    }

    /// The start refused by name when the budget cannot hold the fixed state with the reservation.
    public var fixedStateRefusal: String? {
        guard fixedStateBytes > budgetBytes else { return nil }
        let pass = Self.gibToPass(fixedStateBytes)
        return "ERROR out_of_budget: the boot needs at least \(fixedStateBytes) bytes for the fixed state: \(nodeFixedStateBytes) B"
            + " (191.0 B/node + 2.55 MB) and the Metal pool's reservation of \(poolReservationBytes) B (1.1 x the pool measured on"
            + " this machine); the memory budget is \(budgetBytes) B (\(gibText) GiB); start the daemon with --mem-budget-gb \(pass)"
            + " or larger (DAGDB_SANDBOX_MEM_BUDGET_GB=\(pass) for scripts/start_sandbox.sh)"
    }

    /// When the budget cannot hold a raised reservation, every later GPU verb is refused with this.
    public private(set) var gpuRefusal: String? = nil

    /// The pool `measured` at the first GPU command (`verb`): above the reservation it raises it to
    /// 1.1 x the measurement; past the budget, GPU verbs are refused from here on. Returns the log line.
    public func raisePoolReservation(measured: Int, verb: String) -> String {
        guard measured > poolReservationBytes else {
            return "POOL1: the Metal pool measured \(measured) B at the first GPU command (\(verb)); the reservation of"
                + " \(poolReservationBytes) B holds it"
        }
        let old = poolReservationBytes
        poolReservationBytes = Int((AdmissionCharge.margin * Double(measured)).rounded(.up))
        var line = "POOL1: the Metal pool measured \(measured) B at the first GPU command (\(verb)), above the reservation of"
            + " \(old) B; the reservation is raised to \(poolReservationBytes) B (1.1 x the measurement), fixed state \(fixedStateBytes) B"
        if fixedStateBytes > budgetBytes {
            let pass = Self.gibToPass(fixedStateBytes)
            gpuRefusal = "the Metal pool's raised reservation (\(poolReservationBytes) B, 1.1 x the \(measured) B measured at the first"
                + " GPU command) takes the fixed state to \(fixedStateBytes) B, above the memory budget of \(budgetBytes) B; restart the"
                + " daemon with --mem-budget-gb \(pass) or larger"
            line += "; the budget of \(budgetBytes) B cannot hold it, so GPU verbs are refused by name from here on"
        }
        return line
    }

    /// The budget in GiB as STATUS and the log print it: three decimals.
    public var gibText: String { String(format: "%.3f", Double(budgetBytes) / Double(DaemonMemoryBudget.gib)) }

    /// The process's physical footprint now, in bytes (0 if the OS will not say).
    public static func physFootprint() -> Int {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return r == 0 ? Int(clamping: info.ri_phys_footprint) : 0
    }
}

/// A count that may exceed Int (a product of wire numbers).
/// Saturating: once a step overflows the value is "more than Int.max", which
/// exceeds every cap and every budget, and prints as such.
public struct AdmitCount: Comparable, CustomStringConvertible {
    public let value: Int
    public let overflow: Bool
    public init(_ v: Int) { value = max(v, 0); overflow = false }
    init(value: Int, overflow: Bool) { self.value = value; self.overflow = overflow }
    public static let more = AdmitCount(value: Int.max, overflow: true)
    public func divided(by d: Int) -> AdmitCount { overflow ? .more : AdmitCount(value / d) }
    public static func * (a: AdmitCount, b: AdmitCount) -> AdmitCount {
        if (!a.overflow && a.value == 0) || (!b.overflow && b.value == 0) { return AdmitCount(0) }
        if a.overflow || b.overflow { return .more }
        let (p, o) = a.value.multipliedReportingOverflow(by: b.value)
        return o ? .more : AdmitCount(p)
    }
    public static func + (a: AdmitCount, b: AdmitCount) -> AdmitCount {
        if a.overflow || b.overflow { return .more }
        let (s, o) = a.value.addingReportingOverflow(b.value)
        return o ? .more : AdmitCount(s)
    }
    public static func < (a: AdmitCount, b: AdmitCount) -> Bool {
        if a.overflow != b.overflow { return b.overflow }
        return a.value < b.value
    }
    public static func == (a: AdmitCount, b: AdmitCount) -> Bool { a.overflow == b.overflow && a.value == b.value }
    public var description: String { overflow ? "more than \(Int.max)" : "\(value)" }
}

extension DagDBCommandHandler {
    // MARK: - Work caps: 60 s at the slowest rate measured under the launch
    // configuration (MallocLargeCache=0) on the M5, plus 10 % for run-to-run noise.
    // The unit of each figure is named in its refusal.
    // The slowest over sequential, page-crossing strided and random access. The claim: a command is admitted only if its work, at the slowest rate
    // measured on sequential, strided and random access, fits in 60 s. Memory is a hard bound; time is a
    // bound on the patterns measured.

    /// DISTANCE spectralL2, per side, in ns: the cheap branch 8.0·n² (7.2 ns measured beside a -j 4 compile;
    /// 2.29–4.75 elsewhere: a first-touch, page-fault-bound path that spreads 3x between runs; memory binds it
    /// first, ≤ 22 s even at 8.0 ns under a 32 GiB budget); Jacobi's worst case 1.11·50·n²(n−1) (1.009 ns measured).
    public static let alloc1aSpectralCheapNs = 8.0
    public static let alloc1aSpectralJacobiNs = 1.11
    public static let alloc1aSpectralWorkCapNs = 60_000_000_000
    /// FOLD RUN's projection: 2.89 ns per filter step measured beside a -j 4 compile (2.65 at N = 1M, 2.25–2.33
    /// at smaller N) → 3.18.
    public static let alloc1aFoldFilterStepCap = 18_867_000_000                // 60 s / 3.18 ns
    /// FOLD RUN's library work in ns (the fill over m² accepted): a·N² for the dense
    /// operator; per fold a·m² + b·ka²·kb + c·kb³; per tier a·k² + 3·c·k³. Measured 9.7 ns, 2.3 ps; b 0.55–1.01 ns
    /// sequential, **1.645 ns strided** (ABA read at a ka·8-byte stride once it outgrows the caches,
    /// ka = 2,100, kb = 10,000: 168 MB) → 1.81.
    public static let alloc1aFoldFillNs = 10.7
    public static let alloc1aFoldSchurNs = 1.81
    public static let alloc1aFoldSolveNs = 0.00253
    public static let alloc1aFoldWorkCapNs = 60_000_000_000
    /// FOLD RUN's peak, from the allocations live at it, plus a 2·N² margin:
    /// without CHECK 4m² + 16kb² + 24kb·ka + 20ka² ≤ 24·N²; with CHECK a tier adds the Double lift and
    /// solveSym's copy (16ka²) beside AAA, newOp and the new op: 16kb² + 24kb·ka + 36ka² ≤ 36·N².
    public static let alloc1aFoldPeakPerN2 = 26
    public static let alloc1aFoldPeakPerN2Check = 38
    /// `LadderFold.Object` (mo, ro, rankOut, the adjacency rows), 168·N.
    public static let alloc1aFoldObjectPerNode = 168
    /// BANK OPEN / INFO: 39.0 ps per T·K² measured → 42.9.
    public static let alloc1aBankSVDCap = 1_398_000_000_000                    // 60 s / 42.9 ps
    /// BANK BENCH: every rep's output is a fresh mapping: 0.091 ns per output byte measured → 0.100;
    /// 0.672 ps per flop → 0.74; the K·M coefficients at NOISE's draw rate. Both figures, recomputed,
    /// and their sum with the draws in ns. At the machine's
    /// real load (1-minute load average 3.0–4.4) the K = 256 row read 1.011 of its admitted time, so both
    /// rise by 1.011 × 1.1: 0.111 ns per output byte, 0.823 ps per flop.
    /// Every rate rounds up at its last stated digit: 0.11121 -> 0.112.
    public static let alloc1aBenchOutputByteCap = 535_714_000_000              // 60 s / 0.112 ns
    public static let alloc1aBenchFlopCap = 72_904_000_000_000                 // 60 s / 0.823 ps
    public static let alloc1aBenchOutputNs = 0.112
    public static let alloc1aBenchFlopNs = 0.000823
    public static let alloc1aBenchWorkCapNs = 60_000_000_000
    /// BANK NOISE: 1.64 ns per draw measured → 1.805; a fit (NOISE and FIT) 39.6 ps per T·K² → 43.5.
    public static let alloc1aNoiseDrawNs = 1.805
    public static let alloc1aNoiseDrawCap = 33_240_000_000                     // 60 s / 1.805 ns
    public static let alloc1aNoiseFitCap = 1_379_000_000_000                   // 60 s / 43.5 ps
    /// HOOK STEP: 36.97 ns per frame measured (a ratio run beside the test suite; 23.6–28.75 elsewhere) → 40.7.
    public static let alloc1aHookFrameCap = 1_474_000_000                      // 60 s / 40.7 ns
    /// The tick verbs, in dispatch-equivalents of 2.84 µs (2.58 µs per rank level measured, the slowest;
    /// 2.20–2.26 elsewhere); the per-tick floor 153.6 µs → 169 µs = 60 units; 0.0842 ns per node → 0.0926,
    /// 30,669 nodes per unit. The latch (random edges): on the CPU 2.13 ns per edge (0.98
    /// sequential) → 2.34, 1,213 edges per unit; on the GPU 0.288 ns per edge (6.5 ps sequential) → 0.317,
    /// 8,958 edges per unit.
    /// At the machine's real load (1-minute load average 3.0–4.4) the
    /// 4,096-level TICK and the counting UNTIL_STABLE read up to 1.031 of their admitted time and the CPU
    /// latch over 2M random edges up to 1.157, so the unit becomes 2.84 × 1.031 × 1.1 = 3.221 µs (every term
    /// counted in it, the floor's 60 and the 30,669 nodes, rises with it), and the CPU latch 1,081 edges.
    public static let alloc1aTickDispatchCap = 18_628_000                      // 60 s / 3.221 µs
    public static let alloc1aTickFloorUnits = 60
    public static let alloc1aTickNodesPerUnit = 30_669
    public static let alloc1aLatchCPUEdgesPerUnit = 1_080   // 1213 * 1.031 / 1.157 = 1,080.9, rounded toward the slower rate
    public static let alloc1aLatchGPUEdgesPerUnit = 8_958
    public static let alloc1aReaderSessionCap = 64
    /// Every exact byte formula (spectral, BANK OPEN / INFO / BENCH / NOISE / FIT,
    /// HOOK STEP) is admitted at formula × 1.05 + 64 MiB, for the O(n) and O(T) arrays and LAPACK workspace.
    static func withByteMargin(_ b: AdmitCount) -> AdmitCount {
        b.overflow ? .more : (b * AdmitCount(105) + AdmitCount(99)).divided(by: 100) + AdmitCount(64 << 20)
    }
    static let byteMarginWords = ", x 1.05 + 64 MiB"

    /// ns as an admitted count (rounded up; past Int.max, "more than").
    static func nsCount(_ ns: Double) -> AdmitCount {
        let up = ns.rounded(.up)
        return up >= 9.2e18 ? .more : AdmitCount(Int(up))
    }

    /// One work figure of an admission: what it counts, how much, its cap.
    struct AdmitWork {
        let units: String
        let needed: AdmitCount
        let cap: Int
    }

    /// Called by each heavy verb after its argument checks
    /// and before its first large allocation or loop. nil admits; otherwise the
    /// refusal line. Bytes first (only with a budget), then each work figure.
    func admit(_ verb: String, bytes: AdmitCount? = nil, what: String = "", work: [AdmitWork] = []) -> String? {
        if let b = bytes, let budget = memoryBudget {
            let f = budget.footprint()
            if AdmitCount(f) + b > AdmitCount(budget.budgetBytes) {
                // The measured footprint is the volatile tail's `footprint=` (Reply.volatileKeys).
                return "ERROR out_of_budget: \(verb) needs \(b) bytes (\(what)), the budget is \(budget.budgetBytes)"
                    + "; nothing written footprint=\(f)"
            }
            // max(footprint, fixed state + ledger) + new <= budget. The text
            // above is unchanged; this one is the committed bytes refusing where the footprint did not.
            let ledger = committedLedgerBytes()
            let committed = AdmitCount(budget.fixedStateBytes) + AdmitCount(ledger)
            if committed + b > AdmitCount(budget.budgetBytes) {
                return "ERROR out_of_budget: \(verb) needs \(b) bytes (\(what)), the budget is \(budget.budgetBytes)"
                    + " (committed \(committed): fixed state \(budget.fixedStateBytes)"
                    + " + ledger \(ledger)); nothing written footprint=\(f)"
            }
        }
        for w in work where w.needed > AdmitCount(w.cap) {
            return "ERROR out_of_budget: \(verb) needs \(w.needed) \(w.units), the per-command work cap is \(w.cap);"
                + " nothing written"
        }
        return nil
    }

    /// The latch paths a tick verb takes.
    enum TickLatch { case sync, rank, counting }

    /// TICK, TICK_SYNC and TICK UNTIL_STABLE (count = MAX): count × (L + 56) +
    /// ⌈count·N/28,700⌉ dispatch-equivalents, L the dispatches one
    /// tick makes (the non-empty rank levels; 1 for TICK_SYNC), plus the
    /// back-edge latch for M = the back-edge list's length:
    /// - TICK_SYNC latches on the CPU every tick: ⌈count·M/1,213⌉;
    /// - rank-mode TICK latches on the CPU every tick while M < gpuLatchMinBackEdges,
    ///   else on the GPU (⌈count·M/8,958⌉) after one CPU latch and the plan's build (⌈M/1,213⌉);
    /// - TICK UNTIL_STABLE's counting session latches on the GPU: the plan's build plus ⌈count·M/8,958⌉.
    func admitTickWork(_ verb: String, count: Int, levels: Int, latch: TickLatch) -> String? {
        let perTick = AdmitCount(max(levels, 1)) + AdmitCount(Self.alloc1aTickFloorUnits)
        let c = AdmitCount(count)
        func ceilDiv(_ x: AdmitCount, _ d: Int) -> AdmitCount { x.overflow ? .more : AdmitCount((x.value + d - 1) / d) }
        let nodeUnits = ceilDiv(c * AdmitCount(nodeCount), Self.alloc1aTickNodesPerUnit)
        let M = engine.backEdgeSrcs.count
        let m = AdmitCount(M)
        var latchUnits = AdmitCount(0)
        if M > 0 {
            switch latch {
            case .sync:
                latchUnits = ceilDiv(c * m, Self.alloc1aLatchCPUEdgesPerUnit)
            case .rank where M < DagDBEngine.gpuLatchMinBackEdges:
                latchUnits = ceilDiv(c * m, Self.alloc1aLatchCPUEdgesPerUnit)
            case .rank, .counting:
                latchUnits = ceilDiv(m, Self.alloc1aLatchCPUEdgesPerUnit) + ceilDiv(c * m, Self.alloc1aLatchGPUEdgesPerUnit)
            }
        }
        let needed = c * perTick + nodeUnits + latchUnits
        return admit(verb, work: [AdmitWork(units: "dispatch-equivalents", needed: needed, cap: Self.alloc1aTickDispatchCap)])
    }

    /// The ` mem_budget_gb=<G>` STATUS token: only when the
    /// budget was set explicitly (`--mem-budget-gb`); "" for the default, which
    /// start_sandbox.sh prints and the default formula gives, and without a budget.
    var memBudgetStatusToken: String {
        guard let b = memoryBudget, b.source == "--mem-budget-gb" else { return "" }
        return " mem_budget_gb=\(b.gibText)"
    }
}

extension DagDBCommandHandler {
    /// DISTANCE spectralL2: 8*(|A|^2+|B|^2+max^2) bytes, the
    /// adjacency, the two Laplacians and Jacobi's copy at their peak; and the
    /// work on each side's actual path:
    /// - the cheap branch: `eigenvaluesSymmetric` breaks before its first
    ///   sweep when the off-diagonal sum is below 1e-10 (DagDBDistance.swift,
    ///   `if off < tolerance { break }`). The Laplacian's off-diagonal entries
    ///   are 0 or -1, so that is exactly a side with no induced edge between two
    ///   distinct members (`spectralSideHasInducedEdge`); n <= 1 returns before
    ///   the loop. Work: the matrix build, n^2.
    /// - otherwise Jacobi, the original worst case: 50 sweeps of n(n-1)/2
    ///   rotations of 2n pair updates, 50*n^2*(n-1); for
    ///   n <= 16,384 the smaller of that and the per-component unit
    ///   (`spectralSideNs`).
    func admitSpectral(engine: DagDBEngine, nodeCount: Int, _ subA: DagSubgraph, _ subB: DagSubgraph) -> String? {
        let a = subA.nodeIds.count, b = subB.nodeIds.count
        let A = AdmitCount(a), B = AdmitCount(b), M = AdmitCount(max(a, b))
        let bytes = AdmitCount(8) * (A * A + B * B + M * M)
        let work = Self.spectralSideNs(engine: engine, nodeCount: nodeCount, sub: subA)
            + Self.spectralSideNs(engine: engine, nodeCount: nodeCount, sub: subB)
        return admit("DISTANCE", bytes: Self.withByteMargin(bytes),
                     what: "spectralL2's n*n Double matrices, 8*(|A|^2+|B|^2+max^2) for |A|=\(a) |B|=\(b)" + Self.byteMarginWords,
                     work: [AdmitWork(units: "spectralL2 work ns (per side: 8.0*n^2 without an induced edge; with one,"
                                          + " 1.11*50*n^2*(n-1) worst-case Jacobi, or for n <= 16384 the smaller of that"
                                          + " and 8.0*n^2 + 50*(1.273*n(n-1)/2 + 18.26*n*S), S = sum over the induced"
                                          + " components of |C|(|C|-1)/2)",
                                      needed: Self.nsCount(work),
                                      cap: Self.alloc1aSpectralWorkCapNs)])
    }

    // MARK: - Jacobi's work per component.
    // The Laplacian of the induced subgraph is block-diagonal by connected component; a rotation (p, q) inside a
    // component leaves every entry outside it exactly zero (c*0 - s*0), and pairs across components are exactly
    // zero, so skipped. Each sweep scans all n(n-1)/2 pairs twice (DagDBDistance.swift, the off-diagonal sum and the
    // rotation loop); each rotation updates two full rows and two full columns, 2n pairs. Rates measured under
    // MallocLargeCache=0, each the slowest + 10 %: alpha 1.273 ns per pair per sweep, net of the build;
    // beta 18.26 ns per rotation-row (power-of-two n, column stride on cache sets, n = 16,384); the build 8.0 ns/n^2
    // (the cheap branch's rate). Above n = 16,384 beta is unmeasured, so the original worst case alone applies.
    public static let spec1BuildNs = 8.0
    public static let spec1AlphaNs = 1.273
    public static let spec1BetaNs = 18.26
    public static let spec1MaxMeasuredN = 16_384

    /// One side's admitted work in ns: the cheap branch 8.0*n^2 without an induced edge; with one, the general
    /// worst case 1.11*50*n^2*(n-1), and for n <= 16,384 the smaller of that and
    /// G' = 8.0*n^2 + 50*(1.273*n(n-1)/2 + 18.26*n*S), S = sum over the induced components of |C|(|C|-1)/2.
    /// A single component spanning the side gives G' > the general worst case, so it is admitted at that worst case.
    static func spectralSideNs(engine: DagDBEngine, nodeCount: Int, sub: DagSubgraph) -> Double {
        let count = sub.nodeIds.count
        let n = Double(count)
        guard spectralSideHasInducedEdge(engine: engine, nodeCount: nodeCount, sub: sub) else {
            return alloc1aSpectralCheapNs * n * n
        }
        let frozen = alloc1aSpectralJacobiNs * 50 * n * n * max(n - 1, 0)
        guard count <= spec1MaxMeasuredN else { return frozen }
        let s = Double(spectralComponentPairs(engine: engine, nodeCount: nodeCount, sub: sub))
        let g = spec1BuildNs * n * n + 50 * (spec1AlphaNs * n * (n - 1) / 2 + spec1BetaNs * n * s)
        return min(frozen, g)
    }

    /// S = sum over the connected components C of the induced subgraph of |C|(|C|-1)/2, the components being
    /// exactly the off-diagonal pattern of `DagDBDistance.laplacian`: a member's input slot naming another member
    /// (a slot naming the node itself is on the diagonal). Union-find over a member-index map: O(6n) work and
    /// O(n) memory, never an array over all N nodes.
    static func spectralComponentPairs(engine: DagDBEngine, nodeCount: Int, sub: DagSubgraph) -> Int {
        let n = sub.nodeIds.count
        guard n > 1 else { return 0 }
        var index = [Int: Int](minimumCapacity: n)
        for (k, id) in sub.nodeIds.enumerated() { index[id] = k }
        var parent = Array(0..<n)
        var size = [Int](repeating: 1, count: n)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        let nb = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)
        for (dst, i) in index {
            for d in 0..<6 {
                let src = Int(nb[dst * 6 + d])
                guard src >= 0, src != dst, let j = index[src] else { continue }
                var x = find(i), y = find(j)
                if x == y { continue }
                if size[x] < size[y] { swap(&x, &y) }
                parent[y] = x
                size[x] += size[y]
            }
        }
        var s = 0
        for r in 0..<n where parent[r] == r { s += size[r] * (size[r] - 1) / 2 }
        return s
    }

    /// True when some member's input slot names another member: exactly the
    /// pairs `DagDBDistance.inducedAdjacency` writes off the diagonal (a slot
    /// naming the node itself lands on the diagonal, which the Laplacian
    /// overwrites with the degree). O(6n), no allocation.
    static func spectralSideHasInducedEdge(engine: DagDBEngine, nodeCount: Int, sub: DagSubgraph) -> Bool {
        guard sub.nodeIds.count > 1 else { return false }
        let nb = engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6)
        for dst in sub.nodeIds {
            for d in 0..<6 {
                let src = Int(nb[dst * 6 + d])
                if src >= 0 && src != dst && sub.nodeIds.contains(src) { return true }
            }
        }
        return false
    }

    /// OPEN_READER: the session count cap, then (77 + 59)*N +
    /// 118 KB, a session's resident buffers plus its transient state template.
    /// Plus the back-edge list the session copies, at up to twice its
    /// edges as it grows, 1.1*16*M, and the table library, 729 B per table; the words name them only
    /// when they are not zero.
    func admitOpenReader() -> String? {
        let open = sessionManager.openCount
        if open >= Self.alloc1aReaderSessionCap {
            return "ERROR out_of_budget: OPEN_READER needs \(open + 1) open sessions, the session cap is"
                + " \(Self.alloc1aReaderSessionCap); nothing written"
        }
        let m = engine.backEdgeSrcs.count
        // The session's library buffer at the capacity its copy grows to, 1.1 * 729 B per table.
        let lib = engine.ttableCount > 0
            ? Int(Self.alloc1bLibraryBytes(capacity: Self.libraryCapacity(from: 1, for: engine.ttableCount)).rounded(.up)) : 0
        let extra = (m > 0 ? " + 1.1*16*M for M=\(m) back edges" : "") + (lib > 0 ? " + \(lib) B of table library" : "")
        return admit("OPEN_READER", bytes: AdmitCount(77 + 59) * AdmitCount(nodeCount) + AdmitCount(118_000)
                        + (AdmitCount(176) * AdmitCount(m) + AdmitCount(9)).divided(by: 10) + AdmitCount(lib),
                     what: "a session's buffers and its state template, (77 + 59)*N + 118 KB" + extra)
    }
}
