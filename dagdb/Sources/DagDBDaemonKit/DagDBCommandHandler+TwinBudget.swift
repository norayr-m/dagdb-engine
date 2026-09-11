/// XCONV / BUDGET verb family — real implementation (interface phase, 2026-09).
///
/// XCONV CHECK is read-only: it reads four contiguous f32 vectors out of shm
/// (a, b, kA, kB — the two records and the two path kernels) and runs the
/// sealed W1 identity check (`CrossConvolutionCheck.check`), never touching
/// the twin registries or the WAL.
///
/// BUDGET follows the same WAL-first pattern as STREAM/RECORD
/// (DagDBCommandHandler+TwinStreams.swift): OPEN/SEALED validate → mint an
/// id via `twin.nextId(prefix:)` → `appendTwinWAL` (abort on failure) →
/// `twin.apply` → `OK …`. ALLOCATE/INFO/LIST never mutate — ALLOCATE reads
/// the sealed decision letters straight out of `BudgetLayout.allocate`,
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
            let aOffset = 8
            let bOffset = aOffset + nA * 4
            let kAOffset = bOffset + nB * 4
            let kBOffset = kAOffset + kA * 4
            let neededBytes = 8 + (nA + nB + kA + kB) * 4
            guard neededBytes <= shmCapacityBytes,
                  let a = readFloats(count: nA, at: aOffset),
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
            let costBytes = nPockets * nTiers * 8
            let minTierBytes = nClasses * 4
            let neededBytes = 8 + costBytes + minTierBytes
            guard neededBytes <= shmCapacityBytes,
                  let flatCost = readDoubles(count: nPockets * nTiers, at: 8),
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
            guard let layout = twin.layouts.get(id) else { return "ERROR not_found: \(id)" }
            var claims: [BudgetLayout.Claim] = []
            claims.reserveCapacity(claimsIn.count)
            for c in claimsIn {
                let claim = BudgetLayout.Claim(pocket: c.pocket, classIndex: c.classIndex)
                if let err = layout.claimError(claim) {
                    return "ERROR out_of_range: \(err)"
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
                return "ERROR io: \(error)"
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
            guard let layout = twin.layouts.get(id) else { return "ERROR not_found: \(id)" }
            return twinResponse(
                "BUDGET INFO", sessionId: sessionId,
                "id=\(id) pockets=\(layout.cost.count) tiers=\(layout.cost.first?.count ?? 0) classes=\(layout.minTier.count)"
            )

        case .budgetClose(let id):
            guard twin.layouts.get(id) != nil else { return "ERROR not_found: \(id)" }
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
    // vector; XCONV CHECK reuses the shared f32 `readFloats` from +Twin.swift).

    private func readDoubles(count: Int, at byteOffset: Int) -> [Double]? {
        guard count >= 0, byteOffset >= 0, byteOffset + count * 8 <= shmCapacityBytes else { return nil }
        let ptr = shmBase.advanced(by: byteOffset).bindMemory(to: Double.self, capacity: max(1, count))
        return (0..<count).map { ptr[$0] }
    }

    private func readU32s(count: Int, at byteOffset: Int) -> [UInt32]? {
        guard count >= 0, byteOffset >= 0, byteOffset + count * 4 <= shmCapacityBytes else { return nil }
        let ptr = shmBase.advanced(by: byteOffset).bindMemory(to: UInt32.self, capacity: max(1, count))
        return (0..<count).map { ptr[$0] }
    }

    /// `TwinState.TwinError` renders via its own `description`; any other
    /// thrown error falls back to `ERROR io:`. Duplicated from
    /// +TwinStreams.swift's private `twinErrorLine` — file-scoped `private`
    /// helpers don't cross extension files, and T8.2/T8.4 are parallel-safe
    /// disjoint-file tasks (plan §ordering), so this stays a local copy
    /// rather than widening another task's file.
    private func twinBudgetErrorLine(_ error: Error) -> String {
        if let e = error as? TwinState.TwinError {
            switch e {
            case .notFound(let s): return "ERROR not_found: \(s)"
            case .badId(let s): return "ERROR bad_value: \(s)"
            case .badValue(let s): return "ERROR bad_value: \(s)"
            case .schema(let s): return "ERROR schema: \(s)"
            case .io(let s): return "ERROR io: \(s)"
            }
        }
        return "ERROR io: \(error)"
    }
}
