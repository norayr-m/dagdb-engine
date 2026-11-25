/// HOOK verb family — the attention hook as a daemon-global ticked process.
/// The engine object
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
/// exactly the frames that were actually stepped — never more (WAL
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
            guard let alarmSet = twin.alarms.get(alarmId) else { return "ERROR not_found: \(Reply.quoted(alarmId))" }
            if let layoutId = layoutId {
                guard twin.layouts.get(layoutId) != nil else { return "ERROR not_found: \(Reply.quoted(layoutId))" }
            }
            if let clockId = clockId {
                guard twin.clocks.get(clockId) != nil else { return "ERROR not_found: \(Reply.quoted(clockId))" }
            }
            guard budget.isFinite, budget > 0 else {
                return "ERROR bad_value: budget must be finite and > 0"
            }
            let delta = deltaArg ?? SealedCourt.delta
            guard delta >= 0 else { return "ERROR out_of_range: delta must be >= 0" }
            // The hook's frame count is records + delta. With the
            // WAL on, the log's u32 field refuses delta >= 2^32 first; with it off,
            // nothing did, and the sum trapped inside AttentionHook.init. Checked
            // here before an id is minted (AttentionHook.init throws as well).
            let records = alarmSet.fixture.records.count
            guard checkedSum(records, delta) != nil else {
                return "ERROR out_of_range: HOOK OPEN delta \(delta): frames \(records) + delta overflow Int;"
                    + " nothing written"
            }
            let policy = policyArg ?? .allocator
            // The count cap, then the hook's index of its alarm's records.
            if let e = admitTwinCreate("HOOK OPEN", prefix: "h", bytes: Self.alloc1bHookBytes(records: records),
                                       what: "a hook's index of its alarm's records, 1.1*(260 B per record + 4 KB)") { return e }

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
            guard let entry = twin.hooks.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            if let clockId = entry.params.clockId {
                return "ERROR forbidden: bound to clock \(clockId)"
            }
            let remaining = max(0, entry.hook.frames - entry.hook.t)
            let taken = min(n, remaining)
            // Taken new ledger rows (240 B resident each) and the copy of the L-row ledger.
            if let e = admit("HOOK STEP", bytes: Self.withByteMargin(AdmitCount(240) * AdmitCount(taken) + AdmitCount(104) * AdmitCount(entry.hook.ledger.count)),
                             what: "240 B per frame stepped and 104 B per ledger row copied" + Self.byteMarginWords,
                             work: [AdmitWork(units: "frames", needed: AdmitCount(taken), cap: Self.alloc1aHookFrameCap)]) {
                return e
            }
            let op = TwinOp.hookStep(id: id, count: taken)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return hookErrorLine(error) }
            guard let updated = twin.hooks.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            let r = updated.hook.result
            return twinResponse(
                "HOOK STEP", sessionId: sessionId,
                "id=\(id) t=\(updated.hook.t) stepped=\(taken) done=\(updated.hook.done ? 1 : 0) " +
                "served=\(r.served) misses=\(r.misses) cost=\(r.cost)"
            )

        case .hookState(let id):
            guard let entry = twin.hooks.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            let h = entry.hook
            let r = h.result
            return twinResponse(
                "HOOK STATE", sessionId: sessionId,
                "id=\(id) t=\(h.t) done=\(h.done ? 1 : 0) served=\(r.served) misses=\(r.misses) cost=\(r.cost) " +
                "dummy=\(r.dummy) dominated=\(r.dominated) max_spend_ratio=\(r.maxSpendRatio) " +
                "warmup_cost=\(r.warmupCostExcluded) burst=\(r.burst.served)/\(r.burst.missed)/\(r.burst.total)"
            )

        case .hookLedger(let id, let fromArg, let countArg):
            guard let entry = twin.hooks.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            let ledger = entry.hook.ledger
            let from = fromArg ?? 0
            let count = countArg ?? max(0, ledger.count - from)
            guard from >= 0, count >= 0 else {
                return "ERROR out_of_range: from/count must be >= 0"
            }
            // `from + count` is an unchecked Int addition on two wire
            // values; Int.max plus anything traps before the guard below.
            guard let end = checkedSum(from, count) else {
                return "ERROR out_of_range: range from=\(from) count=\(count) overflows Int;"
                    + " ledger holds \(ledger.count) rows"
            }
            guard from <= ledger.count, end <= ledger.count else {
                return "ERROR out_of_range: range [\(from), \(end)) not in [0, \(ledger.count)]"
            }
            guard let bytes = checkedProduct(count, 40).flatMap({ checkedSum(8, $0) }) else {
                return overflowRefusal("HOOK LEDGER", "count=\(count)")
            }
            guard bytes <= shmCapacityBytes else {
                return "ERROR out_of_range: HOOK LEDGER \(bytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }
            // The row's u32 t, i32 src, i8 tier and i8
            // pocket are converted exactly for EVERY row before any byte is
            // written. src = t - delta is below Int32.min for a delta >= 2^31
            // (the WAL's u32 field allows up to 2^32 - 1), which trapped in
            // `Int32(row.src)` with the header already stored.
            var packed: [HookLedgerPacked] = []
            packed.reserveCapacity(end - from)
            for k in from..<end {
                switch packHookLedgerRow(ledger[k]) {
                case .packed(let p): packed.append(p)
                case .refused(let what, let value, let range):
                    return "ERROR out_of_range: HOOK LEDGER row \(k) \(what) \(value) not in \(range); nothing written"
                }
            }
            writeHookLedgerRows(packed)
            return twinResponse(
                "HOOK LEDGER", sessionId: sessionId,
                "id=\(id) from=\(from) count=\(count) of=\(ledger.count)"
            )

        case .hookInfo(let id):
            guard let entry = twin.hooks.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
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
            guard let entry = twin.hooks.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            // A bound hook's id leaves its clock,
            // as GEAR CLOSE's does, so a clock never holds a dangling id and
            // CLOCK ADVANCE never meets one. The removal is logged as its own
            // record (TWIN_HOOK_SWEEP, log version 6) beside the TWIN_CLOSE, in
            // one append: TWIN_CLOSE keeps its older meaning on replay (the
            // hook alone), which is what lets an older log replay as the old
            // daemon ran it.
            var ops: [TwinOp] = [.close(id: id)]
            if let cid = entry.params.clockId, twin.clocks.get(cid)?.hookIds.contains(id) == true {
                ops.append(.hookSweep(bindings: [TwinHookBinding(clockId: cid, hookId: id)]))
            }
            if let err = appendTwinWALs(ops) { return err }
            do { for op in ops { try twin.apply(op) } } catch { return hookErrorLine(error) }
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

    /// One ledger row with its four narrowed fields already
    /// converted exactly (`packHookLedgerRow`), so the write cannot trap.
    struct HookLedgerPacked {
        let row: AttentionHook.Row
        let t: UInt32
        let src: Int32
        let tier: Int8
        let pocket: Int8
    }

    enum HookLedgerPack {
        case packed(HookLedgerPacked)
        /// The field's name, its value and the range it missed.
        case refused(String, Int, String)
    }

    /// `UInt32(exactly:)`, `Int32(exactly:)`,
    /// `Int8(exactly:)`, in the row's field order; the first field that does
    /// not fit is named.
    func packHookLedgerRow(_ row: AttentionHook.Row) -> HookLedgerPack {
        guard let t = UInt32(exactly: row.t) else { return .refused("t", row.t, "0...\(UInt32.max)") }
        guard let src = Int32(exactly: row.src) else {
            return .refused("src", row.src, "\(Int32.min)...\(Int32.max)")
        }
        let tierValue = row.tierBought ?? -1
        guard let tier = Int8(exactly: tierValue) else {
            return .refused("tier", tierValue, "\(Int8.min)...\(Int8.max)")
        }
        let pocketValue = row.pocket ?? -1
        guard let pocket = Int8(exactly: pocketValue) else {
            return .refused("pocket", pocketValue, "\(Int8.min)...\(Int8.max)")
        }
        return .packed(HookLedgerPacked(row: row, t: t, src: src, tier: tier, pocket: pocket))
    }

    private func writeHookLedgerRows(_ rows: [HookLedgerPacked]) {
        let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
        headerPtr[0] = UInt32(rows.count)
        headerPtr[1] = 40
        for (i, p) in rows.enumerated() {
            let row = p.row
            let base = shmBase.advanced(by: 8 + i * 40)
            base.storeBytes(of: p.t, as: UInt32.self)
            base.advanced(by: 4).storeBytes(of: p.src, as: Int32.self)
            base.advanced(by: 8).storeBytes(of: UInt8(row.judged ? 1 : 0), as: UInt8.self)
            base.advanced(by: 9).storeBytes(of: hookOutcomeByte(row.outcome), as: UInt8.self)
            base.advanced(by: 10).storeBytes(of: p.tier, as: Int8.self)
            base.advanced(by: 11).storeBytes(of: p.pocket, as: Int8.self)
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
    /// `twinStateErrorLine`) since `private` helpers in another extension
    /// file aren't visible here. `HOOK STEP` on a clock-bound hook throws
    /// `.badValue("bound to clock <c>")` — mapped to `ERROR
    /// forbidden:`, not `bad_value`, per the hook grammar's refusal line.
    /// (This handler intercepts the bound-clock case itself before ever
    /// reaching `twin.apply`, so this branch is defense-in-depth against
    /// the library throwing the same message some other way.)
    private func hookErrorLine(_ error: Error) -> String {
        if let e = error as? TwinState.TwinError {
            switch e {
            case .notFound(let s): return "ERROR not_found: \(Reply.quoted(s))"
            case .badId(let s): return "ERROR bad_value: \(Reply.quoted(s))"
            case .badValue(let s):
                if s.hasPrefix("bound to clock") || s.contains("depends on") {
                    return "ERROR forbidden: \(s)"
                }
                return "ERROR bad_value: \(s)"
            case .schema(let s): return "ERROR schema: \(s)"
            case .io(let s): return "ERROR io: \(s)"
            }
        }
        return Reply.errorLine("io", error)
    }

    private func idsSuffixHook(_ ids: [String]) -> String {
        ids.isEmpty ? "" : " " + ids.joined(separator: " ")
    }
}
