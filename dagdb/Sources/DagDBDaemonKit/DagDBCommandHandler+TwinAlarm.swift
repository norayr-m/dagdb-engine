/// ALARM verb family — real implementation (interface phase, 2026-09).
///
/// `ALARM LOAD` follows the plan's guardPath-first, validate-before-mint
/// pattern: `guardPath` rejects traversal/outside-dataRoot paths before any
/// file I/O; the fixture is then loaded ONCE (any `AlarmFixture.FixtureError`
/// — file missing, SHA mismatch, malformed entry — becomes `ERROR io:`,
/// per contract amendment 1 §15: a present-but-wrong-hash file is never
/// silently accepted). The `TwinOp.alarmLoad` logged to the WAL and applied
/// to `twin` always carries the fixture's OWN computed sha256 (not the
/// caller's optional `SHA` argument) — that is the by-reference pin later
/// restore/replay verifies against (interface-phase convention 15). Because the fixture is
/// already in hand, the custom `alarmLoader` closure passed to `twin.apply`
/// just returns it directly rather than re-reading the file.
///
/// `ALARM FRAME`/`ALARM CORRUPT`/`ALARM COURT`/`ALARM SUCCESSOR` are pure
/// reads over the alarm set's records via `AllocatorCourt`/`SuccessorCourt`/
/// `CorruptionModel` — no WAL, no mutation.
import Foundation
import DagDB

extension DagDBCommandHandler {
    func handleTwinAlarm(_ cmd: TwinCommand, sessionId: String?) -> String {
        switch cmd {

        case .alarmLoad(let path, let sha256Arg):
            if let err = guardPath(path) { return err }
            let fixture: AlarmFixture
            do {
                fixture = try AlarmFixture.load(path: path, expectedSHA256: sha256Arg)
            } catch {
                return alarmLoadErrorLine(error)
            }
            let id = twin.nextId(prefix: "a")
            let op = TwinOp.alarmLoad(id: id, path: path, sha256: fixture.sha256)
            if let err = appendTwinWAL(op) { return err }
            do {
                try twin.apply(op, alarmLoader: { _, _ in fixture })
            } catch { return twinStateErrorLine(error) }

            let counts = fixture.classCounts
            let quiet = counts["quiet"] ?? 0
            let deep = counts["deep"] ?? 0
            let drift = counts["drift"] ?? 0
            let earA = counts["liar_A"] ?? 0
            let earB = counts["liar_B"] ?? 0
            let earC = counts["liar_C"] ?? 0
            let liar = earA + earB + earC
            let control = fixture.control != nil ? 1 : 0
            return twinResponse(
                "ALARM LOAD", sessionId: sessionId,
                "id=\(id) records=\(fixture.records.count) control=\(control) sha256=\(fixture.sha256) " +
                "quiet=\(quiet) liar=\(liar) deep=\(deep) drift=\(drift) ears=A\(earA)/B\(earB)/C\(earC)"
            )

        case .alarmInfo(let id):
            guard let set = twin.alarms.get(id) else { return "ERROR not_found: \(id)" }
            return twinResponse(
                "ALARM INFO", sessionId: sessionId,
                "id=\(id) path=\(set.ref.path) records=\(set.fixture.records.count) sha256=\(set.ref.sha256)"
            )

        case .alarmList:
            let ids = twin.alarms.ids.sorted()
            return twinResponse("ALARM LIST", sessionId: sessionId, "count=\(ids.count)\(idsSuffixAlarm(ids))")

        case .alarmClose(let id):
            guard twin.alarms.get(id) != nil else { return "ERROR not_found: \(id)" }
            let op = TwinOp.close(id: id)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinStateErrorLine(error) }
            return twinResponse("ALARM CLOSE", sessionId: sessionId, "id=\(id)")

        case .alarmFrame(let id, let idx):
            guard let set = twin.alarms.get(id) else { return "ERROR not_found: \(id)" }
            let records = set.fixture.records
            guard idx >= 1 && idx <= records.count else {
                return "ERROR out_of_range: idx \(idx) not in [1, \(records.count)]"
            }
            let r = records[idx - 1]
            let ear = r.ear?.rawValue ?? "-"
            let label = r.classLabel ?? "-"
            let pocket = r.pocket.map(String.init) ?? "-"
            let burst = r.isBurst ? 1 : 0
            return twinResponse(
                "ALARM FRAME", sessionId: sessionId,
                "id=\(id) idx=\(idx) key=\(r.key) class=\(r.rawClass) ear=\(ear) label=\(label) pocket=\(pocket) burst=\(burst)"
            )

        case .alarmCourt(let id, let budget):
            guard let set = twin.alarms.get(id) else { return "ERROR not_found: \(id)" }
            guard budget.isFinite else { return "ERROR bad_value: budget must be finite" }
            let arms = AllocatorCourt.run(records: set.fixture.records, budget: budget)
            guard let result = arms[.allocator] else { return "ERROR io: allocator arm missing" }
            return twinResponse(
                "ALARM COURT", sessionId: sessionId,
                "id=\(id) B=\(budget) misses=\(result.misses) served=\(result.served) cost=\(result.cost) " +
                "dummy=\(result.dummy) dominated=\(result.dominated) " +
                "burst=\(result.burst.served)/\(result.burst.missed)/\(result.burst.total)"
            )

        case .alarmSuccessor(let id, let budget, let epsM, let epsS, let epsN):
            guard let set = twin.alarms.get(id) else { return "ERROR not_found: \(id)" }
            guard budget.isFinite else { return "ERROR bad_value: budget must be finite" }
            let model: CorruptionModel
            do {
                model = try CorruptionModel(epsM: epsM, epsS: epsS, epsN: epsN)
            } catch {
                return corruptionErrorLine(error)
            }
            let totals = SuccessorCourt.frameTotals(counts: set.fixture.classCounts, model: model, budget: budget)
            return twinResponse(
                "ALARM SUCCESSOR", sessionId: sessionId,
                "id=\(id) B=\(budget) misses_alloc=\(totals.missesAlloc) misses_greedy=\(totals.missesGreedy) " +
                "cost_alloc=\(totals.costAlloc) cost_greedy=\(totals.costGreedy) weight_dev=\(totals.maxWeightDev)"
            )

        case .alarmCorrupt(let id, let idx, let epsM, let epsS, let epsN):
            guard let set = twin.alarms.get(id) else { return "ERROR not_found: \(id)" }
            let records = set.fixture.records
            guard idx >= 1 && idx <= records.count else {
                return "ERROR out_of_range: idx \(idx) not in [1, \(records.count)]"
            }
            let model: CorruptionModel
            do {
                model = try CorruptionModel(epsM: epsM, epsS: epsS, epsN: epsN)
            } catch {
                return corruptionErrorLine(error)
            }
            let record = records[idx - 1]
            let outcomes = model.enumerateOutcomes(for: record.culprit)
            writeCorruptionOutcomes(outcomes)
            let weightSum = outcomes.reduce(0.0) { $0 + $1.weight }
            return twinResponse(
                "ALARM CORRUPT", sessionId: sessionId,
                "id=\(id) idx=\(idx) outcomes=\(outcomes.count) weight_sum=\(weightSum) shm_bytes=\(40 * outcomes.count)"
            )

        default:
            // Every case this family handler is dispatched (see handleTwin
            // in DagDBCommandHandler+Twin.swift) is covered above; this
            // branch exists only for switch exhaustiveness.
            return "ERROR unknown_command: twin verb not wired yet"
        }
    }

    // MARK: - shm row layout: [u32 count][u32 rowSize=40] + rows
    //   row = f64 weight | u32 nClaims | u32 0 |
    //         5×(u8 pocket, u8 row(0=L,1=D), u8 phantom, u8 0) | 4 pad

    private func writeCorruptionOutcomes(_ outcomes: [CorruptionModel.Outcome]) {
        let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
        headerPtr[0] = UInt32(outcomes.count)
        headerPtr[1] = 40
        for (i, outcome) in outcomes.enumerated() {
            let rowBase = shmBase.advanced(by: 8 + i * 40)
            rowBase.storeBytes(of: outcome.weight, as: Double.self)
            rowBase.advanced(by: 8).storeBytes(of: UInt32(outcome.claims.count), as: UInt32.self)
            rowBase.advanced(by: 12).storeBytes(of: UInt32(0), as: UInt32.self)
            for slot in 0..<5 {
                let slotBase = rowBase.advanced(by: 16 + slot * 4)
                if slot < outcome.claims.count {
                    let c = outcome.claims[slot]
                    slotBase.storeBytes(of: UInt8(c.pocket), as: UInt8.self)
                    slotBase.advanced(by: 1).storeBytes(of: UInt8(c.row == .L ? 0 : 1), as: UInt8.self)
                    slotBase.advanced(by: 2).storeBytes(of: UInt8(c.isPhantom ? 1 : 0), as: UInt8.self)
                    slotBase.advanced(by: 3).storeBytes(of: UInt8(0), as: UInt8.self)
                } else {
                    slotBase.storeBytes(of: UInt32(0), as: UInt32.self)
                }
            }
            rowBase.advanced(by: 36).storeBytes(of: UInt32(0), as: UInt32.self)
        }
    }

    // MARK: - Error formatting

    /// `AlarmFixture.FixtureError` (file missing, sha mismatch, malformed
    /// entry, unknown class) always maps to `ERROR io:` — every alarm-load
    /// failure is an I/O-layer finding, never silently accepted (contract
    /// amendment 1 §15). The sha-mismatch line always contains the literal
    /// phrase "sha256 mismatch".
    private func alarmLoadErrorLine(_ error: Error) -> String {
        if let e = error as? AlarmFixture.FixtureError {
            switch e {
            case .fileNotFound(let p):
                return "ERROR io: file not found: \(p)"
            case .shaMismatch(let expected, let actual):
                return "ERROR io: sha256 mismatch: expected \(expected) actual \(actual)"
            case .badEntry(let key, let reason):
                return "ERROR io: bad entry '\(key)': \(reason)"
            case .unknownClass(let key, let value):
                return "ERROR io: unknown class '\(value)' at '\(key)'"
            }
        }
        return "ERROR io: \(error)"
    }

    private func corruptionErrorLine(_ error: Error) -> String {
        if let e = error as? CorruptionModel.CorruptionError {
            switch e {
            case .knobOutOfRange(let name, let v):
                return "ERROR bad_value: \(name)=\(v) must be finite and in [0, 1]"
            }
        }
        return "ERROR bad_value: \(error)"
    }

    /// `TwinState.TwinError` renders via its own `description`; kept as a
    /// file-local twin (see DagDBCommandHandler+TwinStreams.swift's
    /// `twinErrorLine`) since `private` helpers in a sibling extension file
    /// aren't visible here.
    private func twinStateErrorLine(_ error: Error) -> String {
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

    private func idsSuffixAlarm(_ ids: [String]) -> String {
        ids.isEmpty ? "" : " " + ids.joined(separator: " ")
    }
}
