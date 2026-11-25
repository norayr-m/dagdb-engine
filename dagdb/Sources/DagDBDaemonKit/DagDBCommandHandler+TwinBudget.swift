/// XCONV / BUDGET verb family.
///
/// XCONV CHECK is read-only: it reads four contiguous f32 vectors out of shm
/// (a, b, kA, kB — the two records and the two path kernels) and runs the
/// sealed cross-convolution identity check (`CrossConvolutionCheck.check`), never touching
/// the twin registries or the WAL.
///
/// BUDGET follows the same WAL-first pattern as STREAM/RECORD
/// (DagDBCommandHandler+TwinStreams.swift): OPEN/SEALED validate → mint an
/// id via `twin.nextId(prefix:)` → `appendTwinWAL` (abort on failure) →
/// `twin.apply` → `OK …`. ALLOCATE/INFO/LIST never mutate — ALLOCATE reads
/// the sealed decision rules straight out of `BudgetLayout.allocate`,
/// validating every claim through `BudgetLayout.claimError` first so a bad
/// pocket/class index or an oversized claimed-pocket set returns
/// `ERROR out_of_range` instead of trapping.
import Foundation
import DagDB

extension DagDBCommandHandler {
    func handleTwinBudget(_ cmd: TwinCommand, sessionId: String?) -> String {
        switch cmd {

        // MARK: XCONV

        case .xconvCheck(let nA, let nB, let kA, let kB, let warmup):
            guard nA >= 0, nB >= 0, kA >= 0, kB >= 0, warmup >= 0 else {
                return "ERROR out_of_range: XCONV CHECK counts must be non-negative"
            }
            // Every one of these offsets is a product/sum of unbounded
            // wire integers. Compute them with overflow-reporting ops so the
            // capacity guard below is reachable.
            guard let totalElements = checkedSum(nA, nB, kA, kB),
                  let payloadBytes = checkedProduct(totalElements, 4),
                  let neededBytes = checkedSum(8, payloadBytes),
                  let aBytes = checkedProduct(nA, 4),
                  let bBytes = checkedProduct(nB, 4),
                  let kABytes = checkedProduct(kA, 4) else {
                return overflowRefusal("XCONV CHECK input",
                                       "nA=\(nA) nB=\(nB) kA=\(kA) kB=\(kB)")
            }
            let aOffset = 8
            let bOffset = aOffset + aBytes
            let kAOffset = bOffset + bBytes
            let kBOffset = kAOffset + kABytes
            guard neededBytes <= shmCapacityBytes else {
                return "ERROR out_of_range: XCONV CHECK input \(neededBytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }
            // Capacity, then the mark, then the read.
            if let r = shm1FrameRefusal(.xconvCheck, count: totalElements) { return r }
            guard let a = readFloats(count: nA, at: aOffset),
                  let b = readFloats(count: nB, at: bOffset),
                  let kATaps = readFloats(count: kA, at: kAOffset),
                  let kBTaps = readFloats(count: kB, at: kBOffset) else {
                return "ERROR out_of_range: XCONV CHECK input \(neededBytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }
            let result = CrossConvolutionCheck.check(
                recordA: a, recordB: b,
                kernelA: CrossConvolutionCheck.PathKernel(taps: kATaps),
                kernelB: CrossConvolutionCheck.PathKernel(taps: kBTaps),
                warmup: warmup
            )
            return twinResponse(
                "XCONV CHECK", sessionId: sessionId,
                "residual=\(result.residual) compared=\(result.comparedSamples)"
            )

        // MARK: BUDGET

        case .budgetOpen(let nPockets, let nTiers, let nClasses):
            guard nPockets >= 0, nTiers >= 0, nClasses >= 0 else {
                return "ERROR out_of_range: BUDGET OPEN dimensions must be non-negative"
            }
            // `nPockets * nTiers * 8` traps on overflow; so does the sum.
            guard let cells = checkedProduct(nPockets, nTiers),
                  let costBytes = checkedProduct(cells, 8),
                  let minTierBytes = checkedProduct(nClasses, 4),
                  let neededBytes = checkedSum(8, costBytes, minTierBytes) else {
                return overflowRefusal("BUDGET OPEN input",
                                       "nPockets=\(nPockets) nTiers=\(nTiers) nClasses=\(nClasses)")
            }
            guard neededBytes <= shmCapacityBytes else {
                return "ERROR out_of_range: BUDGET OPEN input \(neededBytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }
            // The 20-pocket cap, before the frame check and the
            // table build. With nTiers = 0 every byte count above is 8 + 4c for any
            // p, so `cost.reserveCapacity(nPockets)` and the per-pocket loop ran on
            // a wire p (2^62 trapped) before BudgetLayout.validationError's cap.
            guard nPockets <= BudgetLayout.maxClaimedPockets else {
                return "ERROR out_of_range: BUDGET OPEN pockets \(nPockets) not in 0...\(BudgetLayout.maxClaimedPockets);"
                    + " nothing written"
            }
            // Capacity, then the mark (p·t f64 costs,
            // then c u32 minTiers), then the read. The count p·t + c is overflow-reporting,
            // though both terms fit the capacity checked above.
            if let r = shm1FrameRefusal(.budgetOpen, nPockets, times: nTiers, plus: nClasses) { return r }
            // The count cap, then the layout's bytes and its staging (the frame's reads, the
            // per-pocket rows, the Int classes, the WAL record).
            if let e = admitTwinCreate("BUDGET OPEN", prefix: "b",
                                       bytes: Self.alloc1bLayoutBytes(pockets: nPockets, tiers: nTiers, classes: nClasses)
                                           + Self.alloc1bMargin * (24 * Double(cells) + 16 * Double(nClasses)),
                                       what: "a layout, 1.1*(1.17*(8*p*t + 8*c) + 600 B), and its staging, 1.1*(24*p*t + 16*c)") { return e }
            guard let flatCost = readDoubles(count: cells, at: 8),
                  let minTierRaw = readU32s(count: nClasses, at: 8 + costBytes) else {
                return "ERROR out_of_range: BUDGET OPEN input \(neededBytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }
            var cost: [[Double]] = []
            cost.reserveCapacity(nPockets)
            for p in 0..<nPockets {
                cost.append(Array(flatCost[(p * nTiers)..<((p + 1) * nTiers)]))
            }
            let minTier = minTierRaw.map { Int($0) }
            if let violation = BudgetLayout.validationError(cost: cost, minTier: minTier) {
                return "ERROR bad_value: \(violation)"
            }
            let id = twin.nextId(prefix: "b")
            let op = TwinOp.layoutOpen(id: id, cost: cost, minTier: minTier)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinBudgetErrorLine(error) }
            return twinResponse(
                "BUDGET OPEN", sessionId: sessionId,
                "id=\(id) pockets=\(nPockets) tiers=\(nTiers) classes=\(nClasses)"
            )

        case .budgetSealed:
            let layout = SealedCourt.makeLayout()
            // The count cap, then the layout's bytes.
            if let e = admitTwinCreate("BUDGET SEALED", prefix: "b",
                                       bytes: Self.alloc1bLayoutBytes(pockets: layout.cost.count, tiers: layout.cost.first?.count ?? 0,
                                                                      classes: layout.minTier.count),
                                       what: "a layout, 1.1*(1.17*(8*p*t + 8*c) + 600 B)") { return e }
            let id = twin.nextId(prefix: "b")
            let op = TwinOp.layoutOpen(id: id, cost: layout.cost, minTier: layout.minTier)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinBudgetErrorLine(error) }
            return twinResponse(
                "BUDGET SEALED", sessionId: sessionId,
                "id=\(id) pockets=\(layout.cost.count) tiers=\(layout.cost.first?.count ?? 0) classes=\(layout.minTier.count)"
            )

        case .budgetAllocate(let id, let budget, let claimsIn):
            guard budget.isFinite else { return "ERROR bad_value: budget must be finite" }
            guard let layout = twin.layouts.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            var claims: [BudgetLayout.Claim] = []
            claims.reserveCapacity(claimsIn.count)
            for c in claimsIn {
                let claim = BudgetLayout.Claim(pocket: c.pocket, classIndex: c.classIndex)
                if let why = layout.claimError(claim) {
                    return "ERROR out_of_range: \(why)"
                }
                claims.append(claim)
            }
            let result: BudgetLayout.Layout
            do {
                result = try layout.allocate(claims: claims, budget: budget)
            } catch let e as BudgetLayout.LayoutError {
                switch e {
                case .tooManyClaimedPockets(let n):
                    return "ERROR out_of_range: tooManyClaimedPockets(\(n))"
                }
            } catch {
                return Reply.errorLine("io", error)
            }
            let served = result.servedPockets.map(String.init).joined(separator: ",")
            let purchases = result.purchases
                .map { "\($0.pocket):\($0.tier):\($0.cost):\($0.readValue)" }
                .joined(separator: ",")
            return twinResponse(
                "BUDGET ALLOCATE", sessionId: sessionId,
                "id=\(id) value=\(result.readValue) cost=\(result.totalCost) served=\(served) purchases=\(purchases)"
            )

        case .budgetInfo(let id):
            guard let layout = twin.layouts.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            return twinResponse(
                "BUDGET INFO", sessionId: sessionId,
                "id=\(id) pockets=\(layout.cost.count) tiers=\(layout.cost.first?.count ?? 0) classes=\(layout.minTier.count)"
            )

        case .budgetClose(let id):
            guard twin.layouts.get(id) != nil else { return "ERROR not_found: \(Reply.quoted(id))" }
            // The dependency check before the WAL.
            if let e = twin.closeRefusal(id) { return twinBudgetErrorLine(e) }
            let op = TwinOp.close(id: id)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinBudgetErrorLine(error) }
            return twinResponse("BUDGET CLOSE", sessionId: sessionId, "id=\(id) open=\(twin.layouts.openCount)")

        case .budgetList:
            let ids = twin.layouts.ids.sorted()
            let idsSuffix = ids.isEmpty ? "" : " " + ids.joined(separator: " ")
            return twinResponse("BUDGET LIST", sessionId: sessionId, "count=\(ids.count)\(idsSuffix)")

        default:
            // Every case this family handler is dispatched (see handleTwin
            // in DagDBCommandHandler+Twin.swift) is covered above; this
            // branch exists only for switch exhaustiveness.
            return "ERROR unknown_command: twin verb not wired yet"
        }
    }

    // MARK: - shm readers for f64 / u32 (BUDGET OPEN's cost table + minTier
    // vector; XCONV CHECK reuses the shared f32 `readFloats` from +Twin.swift;
    // `readDoubles` itself moved to +Twin.swift 2026-09-10 (XCONV SEALED
    // needs it too) — kept as a shared, non-private helper there now).

    private func readU32s(count: Int, at byteOffset: Int) -> [UInt32]? {
        guard shmReadFits(count: count, elementSize: 4, at: byteOffset) else { return nil }
        let ptr = shmBase.advanced(by: byteOffset).bindMemory(to: UInt32.self, capacity: max(1, count))
        return (0..<count).map { ptr[$0] }
    }

    /// `TwinState.TwinError` renders via its own `description`; any other
    /// thrown error falls back to `ERROR io:`. Duplicated from
    /// +TwinStreams.swift's private `twinErrorLine` — file-scoped `private`
    /// helpers don't cross extension files, so this stays a local copy
    /// rather than widening another file's helper. `BUDGET CLOSE` on a layout
    /// a live hook depends on throws `.badValue("hook <h> depends on
    /// <id>")` — mapped to `ERROR forbidden:`, not `bad_value`,
    /// per the hook grammar's refusal line.
    private func twinBudgetErrorLine(_ error: Error) -> String {
        if let e = error as? TwinState.TwinError {
            switch e {
            case .notFound(let s): return "ERROR not_found: \(Reply.quoted(s))"
            case .badId(let s): return "ERROR bad_value: \(Reply.quoted(s))"
            case .badValue(let s):
                if s.contains("depends on") { return "ERROR forbidden: \(s)" }
                return "ERROR bad_value: \(s)"
            case .schema(let s): return "ERROR schema: \(s)"
            case .io(let s): return "ERROR io: \(s)"
            }
        }
        return Reply.errorLine("io", error)
    }
}
