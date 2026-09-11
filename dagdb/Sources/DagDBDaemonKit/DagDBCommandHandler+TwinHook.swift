/// HOOK verb family — the attention hook as a daemon-global ticked process
/// (gate H5, docs/contracts/HOOK_GATES_FROZEN.md). The engine object
/// (`AttentionHook`, `Sources/DagDB/AttentionHook.swift`) and its daemon-
/// global registry/WAL/snapshot wiring (`TwinState.hooks`, `TwinOp.hookOpen`
/// /`.hookStep`, `TwinState.HookRef`) already exist — this file is only the
/// socket-facing verb family, mirroring ALARM's guardPath-free, mint-then-
/// apply shape (DagDBCommandHandler+TwinAlarm.swift): validate (existence
/// of the alarm/layout/clock ids, budget finiteness, delta range) BEFORE
/// minting an id, WAL-first, then `twin.apply`.
///
/// `HOOK OPEN`'s `layoutId|SEALED` token resolves to `nil` (the sealed
/// default layout, `SealedCourt.makeLayout()`) at the PARSER (DSLParser+
/// Twin.swift); this handler only needs to look an explicit id up.
/// `delta`/`policy` arrive here as optionals from the grammar's absent-group
/// case — resolved to the sealed defaults (Δ=3, allocator) right here,
/// never upstream, so the reply always prints the resolved value.
///
/// `HOOK STEP`'s `taken` count (`min(n, frames - t)`, clamped at 0 once
/// already done) is computed BEFORE the WAL op is built, so replay logs
/// exactly the frames that were actually stepped — never more (H3: WAL
/// replay must reproduce the same `t`).
///
/// `HOOK LEDGER`'s shm row is 40 bytes: u32 t | i32 src | u8 judged | u8
/// outcome | i8 tier | i8 pocket | 4 pad (aligns the two f64 fields that
/// follow to an 8-byte boundary — row stride 40 and the 8-byte header keep
/// every row's absolute shm offset 8-aligned) | f64 spend | f64
/// cumulativeCost | u8 countsTowardCost | 7 pad bytes = 40.
import Foundation
import DagDB

extension DagDBCommandHandler {
    func handleTwinHook(_ cmd: TwinCommand, sessionId: String?) -> String {
        switch cmd {

        case .hookOpen(let alarmId, let layoutId, let budget, let deltaArg, let policyArg, let clockId):
            guard twin.alarms.get(alarmId) != nil else { return "ERROR not_found: \(alarmId)" }
            if let layoutId = layoutId {
                guard twin.layouts.get(layoutId) != nil else { return "ERROR not_found: \(layoutId)" }
            }
            if let clockId = clockId {
                guard twin.clocks.get(clockId) != nil else { return "ERROR not_found: \(clockId)" }
            }
            guard budget.isFinite, budget > 0 else {
                return "ERROR bad_value: budget must be finite and > 0"
            }
            let delta = deltaArg ?? SealedCourt.delta
            guard delta >= 0 else { return "ERROR out_of_range: delta must be >= 0" }
            let policy = policyArg ?? .allocator

            let params = AttentionHook.Params(
                alarmId: alarmId, layoutId: layoutId, budget: budget,
                delta: delta, policy: policy, clockId: clockId
            )
            let id = twin.nextId(prefix: "h")
            let op = TwinOp.hookOpen(id: id, params: params)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return hookErrorLine(error) }
            guard let entry = twin.hooks.get(id) else { return "ERROR io: hook open did not register" }
            return twinResponse(
                "HOOK OPEN", sessionId: sessionId,
                "id=\(id) alarm=\(alarmId) layout=\(layoutId ?? "SEALED") B=\(budget) delta=\(delta) " +
                "policy=\(policy.rawValue) clock=\(clockId ?? "none") frames=\(entry.hook.frames)"
            )

        case .hookStep(let id, let n):
            guard n >= 1 else { return "ERROR out_of_range: n must be >= 1" }
            guard let entry = twin.hooks.get(id) else { return "ERROR not_found: \(id)" }
            if let clockId = entry.params.clockId {
                return "ERROR forbidden: bound to clock \(clockId)"
            }
            let remaining = max(0, entry.hook.frames - entry.hook.t)
            let taken = min(n, remaining)
            let op = TwinOp.hookStep(id: id, count: taken)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return hookErrorLine(error) }
            guard let updated = twin.hooks.get(id) else { return "ERROR not_found: \(id)" }
            let r = updated.hook.result
            return twinResponse(
                "HOOK STEP", sessionId: sessionId,
                "id=\(id) t=\(updated.hook.t) stepped=\(taken) done=\(updated.hook.done ? 1 : 0) " +
                "served=\(r.served) misses=\(r.misses) cost=\(r.cost)"
            )

        case .hookState(let id):
            guard let entry = twin.hooks.get(id) else { return "ERROR not_found: \(id)" }
            let h = entry.hook
            let r = h.result
            return twinResponse(
                "HOOK STATE", sessionId: sessionId,
                "id=\(id) t=\(h.t) done=\(h.done ? 1 : 0) served=\(r.served) misses=\(r.misses) cost=\(r.cost) " +
                "dummy=\(r.dummy) dominated=\(r.dominated) max_spend_ratio=\(r.maxSpendRatio) " +
                "warmup_cost=\(r.warmupCostExcluded) burst=\(r.burst.served)/\(r.burst.missed)/\(r.burst.total)"
            )

        case .hookLedger(let id, let fromArg, let countArg):
            guard let entry = twin.hooks.get(id) else { return "ERROR not_found: \(id)" }
            let ledger = entry.hook.ledger
            let from = fromArg ?? 0
            let count = countArg ?? max(0, ledger.count - from)
            guard from >= 0, count >= 0 else {
                return "ERROR out_of_range: from/count must be >= 0"
            }
            let end = from + count
            guard from <= ledger.count, end <= ledger.count else {
                return "ERROR out_of_range: range [\(from), \(end)) not in [0, \(ledger.count)]"
            }
            let bytes = 8 + count * 40
            guard bytes <= shmCapacityBytes else {
                return "ERROR out_of_range: HOOK LEDGER \(bytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }
            writeHookLedgerRows(Array(ledger[from..<end]))
            return twinResponse(
                "HOOK LEDGER", sessionId: sessionId,
                "id=\(id) from=\(from) count=\(count) of=\(ledger.count)"
            )

        case .hookInfo(let id):
            guard let entry = twin.hooks.get(id) else { return "ERROR not_found: \(id)" }
            let p = entry.params
            return twinResponse(
                "HOOK INFO", sessionId: sessionId,
                "id=\(id) alarm=\(p.alarmId) layout=\(p.layoutId ?? "SEALED") B=\(p.budget) delta=\(p.delta) " +
                "policy=\(p.policy.rawValue) clock=\(p.clockId ?? "none") frames=\(entry.hook.frames) " +
                "t=\(entry.hook.t) done=\(entry.hook.done ? 1 : 0)"
            )

        case .hookList:
            let ids = twin.hooks.ids.sorted()
            return twinResponse("HOOK LIST", sessionId: sessionId, "count=\(ids.count)\(idsSuffixHook(ids))")

        case .hookClose(let id):
            guard twin.hooks.get(id) != nil else { return "ERROR not_found: \(id)" }
            let op = TwinOp.close(id: id)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return hookErrorLine(error) }
            return twinResponse("HOOK CLOSE", sessionId: sessionId, "id=\(id)")

        default:
            // Every case this family handler is dispatched (see handleTwin
            // in DagDBCommandHandler+Twin.swift) is covered above; this
            // branch exists only for switch exhaustiveness.
            return "ERROR unknown_command: twin verb not wired yet"
        }
    }

    // MARK: - shm row layout: [u32 count][u32 rowSize=40] + rows
    //   row = u32 t | i32 src | u8 judged | u8 outcome | i8 tier | i8 pocket
    //         | 4 pad | f64 spend | f64 cumulativeCost | u8 countsTowardCost
    //         | 7 pad = 40

    private func writeHookLedgerRows(_ rows: [AttentionHook.Row]) {
        let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
        headerPtr[0] = UInt32(rows.count)
        headerPtr[1] = 40
        for (i, row) in rows.enumerated() {
            let base = shmBase.advanced(by: 8 + i * 40)
            base.storeBytes(of: UInt32(row.t), as: UInt32.self)
            base.advanced(by: 4).storeBytes(of: Int32(row.src), as: Int32.self)
            base.advanced(by: 8).storeBytes(of: UInt8(row.judged ? 1 : 0), as: UInt8.self)
            base.advanced(by: 9).storeBytes(of: hookOutcomeByte(row.outcome), as: UInt8.self)
            base.advanced(by: 10).storeBytes(of: Int8(row.tierBought ?? -1), as: Int8.self)
            base.advanced(by: 11).storeBytes(of: Int8(row.pocket ?? -1), as: Int8.self)
            base.advanced(by: 12).storeBytes(of: UInt32(0), as: UInt32.self)             // align pad (12-15)
            base.advanced(by: 16).storeBytes(of: row.spend, as: Double.self)             // 16-23
            base.advanced(by: 24).storeBytes(of: row.cumulativeCost, as: Double.self)     // 24-31
            base.advanced(by: 32).storeBytes(of: UInt8(row.countsTowardCost ? 1 : 0), as: UInt8.self)
            base.advanced(by: 33).storeBytes(of: UInt32(0), as: UInt32.self)              // trailing pad (33-36)
            base.advanced(by: 37).storeBytes(of: UInt16(0), as: UInt16.self)              // trailing pad (37-38)
            base.advanced(by: 39).storeBytes(of: UInt8(0), as: UInt8.self)                // trailing pad (39)
        }
    }

    private func hookOutcomeByte(_ o: AttentionHook.Outcome) -> UInt8 {
        switch o {
        case .none: return 0
        case .hit: return 1
        case .miss: return 2
        }
    }

    // MARK: - Error formatting

    /// `TwinState.TwinError` renders via its own `description`; kept as a
    /// file-local twin (see DagDBCommandHandler+TwinAlarm.swift's
    /// `twinStateErrorLine`) since `private` helpers in a sibling extension
    /// file aren't visible here. `HOOK STEP` on a clock-bound hook throws
    /// `.badValue("bound to clock <c>")` (gate H4) — mapped to `ERROR
    /// forbidden:`, not `bad_value`, per the hook grammar's refusal line.
    /// (This handler intercepts the bound-clock case itself before ever
    /// reaching `twin.apply`, so this branch is defense-in-depth against
    /// the library throwing the same message some other way.)
    private func hookErrorLine(_ error: Error) -> String {
        if let e = error as? TwinState.TwinError {
            switch e {
            case .notFound(let s): return "ERROR not_found: \(s)"
            case .badId(let s): return "ERROR bad_value: \(s)"
            case .badValue(let s):
                if s.hasPrefix("bound to clock") || s.contains("depends on") {
                    return "ERROR forbidden: \(s)"
                }
                return "ERROR bad_value: \(s)"
            case .schema(let s): return "ERROR schema: \(s)"
            case .io(let s): return "ERROR io: \(s)"
            }
        }
        return "ERROR io: \(error)"
    }

    private func idsSuffixHook(_ ids: [String]) -> String {
        ids.isEmpty ? "" : " " + ids.joined(separator: " ")
    }
}
