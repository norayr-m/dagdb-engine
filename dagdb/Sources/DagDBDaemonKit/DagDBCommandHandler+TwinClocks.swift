/// RINGS / CLOCK / GEAR verb family — real implementation (interface phase, 2026-09).
///
/// Same WAL-first pattern as `+TwinStreams.swift` (T8.2): validate (shape
/// guards, finiteness, existence) BEFORE minting an id or touching the WAL
/// — a rejected op never advances a registry's counter, so a failed
/// `RINGS OPEN 1 1 1` leaves the next successful open at `n00000001` — then
/// `twin.nextId(prefix:)` → `appendTwinWAL(op)` (abort on failure, registry
/// untouched) → `twin.apply(op)` → `OK …`.
///
/// `CLOCK ADVANCE`'s `n` ticks and `value` are logged as ONE `TwinOp`
/// (§0.15: "CLOCK ADVANCE logs n + value") — replay re-runs the same
/// `count`-tick loop inside `TwinState.apply`, it does not replay tick by
/// tick, so live and replayed gear `fires`/`latchedTick`/`latchedValue`
/// agree exactly.
import Foundation
import DagDB

extension DagDBCommandHandler {
    func handleTwinClocks(_ cmd: TwinCommand, sessionId: String?) -> String {
        switch cmd {

        // MARK: RINGS

        case .ringsOpen(let gear, let ringCount, let cells):
            if let violation = GearedRings.shapeViolation(gear: gear, rings: ringCount, cellsPerRing: cells) {
                return "ERROR bad_value: \(violation)"
            }
            let id = twin.nextId(prefix: "n")
            let op = TwinOp.ringsOpen(id: id, gear: gear, rings: UInt32(ringCount), cells: UInt32(cells))
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinClockErrorLine(error) }
            return twinResponse(
                "RINGS OPEN", sessionId: sessionId,
                "id=\(id) gear=\(gear) rings=\(ringCount) cells=\(cells) capacity=\(ringCount * cells)"
            )

        case .ringsWrite(let id, let values):
            guard twin.rings.get(id) != nil else { return "ERROR not_found: \(id)" }
            guard values.allSatisfy({ $0.isFinite }) else {
                return "ERROR bad_value: values must be finite"
            }
            let op = TwinOp.ringsWrite(id: id, values: values)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinClockErrorLine(error) }
            guard let ring = twin.rings.get(id) else { return "ERROR not_found: \(id)" }
            return twinResponse("RINGS WRITE", sessionId: sessionId, "id=\(id) n=\(values.count) now=\(ring.now)")

        case .ringsRecall(let id, let lag):
            guard let ring = twin.rings.get(id) else { return "ERROR not_found: \(id)" }
            guard lag >= 0 else { return "ERROR out_of_range: lag must be >= 0" }
            guard let rec = ring.recall(lag: UInt64(lag)) else {
                return twinResponse("RINGS RECALL", sessionId: sessionId, "id=\(id) lag=\(lag) value=none")
            }
            return twinResponse(
                "RINGS RECALL", sessionId: sessionId,
                "id=\(id) lag=\(lag) value=\(rec.value) tick=\(rec.tick) ring=\(rec.ring) span=\(rec.spanLength)"
            )

        case .ringsInfo(let id):
            guard let ring = twin.rings.get(id) else { return "ERROR not_found: \(id)" }
            return twinResponse(
                "RINGS INFO", sessionId: sessionId,
                "id=\(id) gear=\(ring.gear) rings=\(ring.rings) cells=\(ring.cellsPerRing) capacity=\(ring.capacity) now=\(ring.now)"
            )

        case .ringsClose(let id):
            guard twin.rings.get(id) != nil else { return "ERROR not_found: \(id)" }
            let op = TwinOp.close(id: id)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinClockErrorLine(error) }
            return twinResponse("RINGS CLOSE", sessionId: sessionId, "id=\(id) open=\(twin.rings.openCount)")

        case .ringsList:
            let ids = twin.rings.ids.sorted()
            return twinResponse("RINGS LIST", sessionId: sessionId, "count=\(ids.count)\(twinIdsSuffix(ids))")

        // MARK: CLOCK

        case .clockOpen:
            let id = twin.nextId(prefix: "c")
            let op = TwinOp.clockOpen(id: id)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinClockErrorLine(error) }
            return twinResponse("CLOCK OPEN", sessionId: sessionId, "id=\(id) tick=0")

        case .clockAdvance(let id, let n, let value):
            guard n >= 0 else { return "ERROR out_of_range: n must be >= 0" }
            guard twin.clocks.get(id) != nil else { return "ERROR not_found: \(id)" }
            let v = value ?? 0
            guard v.isFinite else { return "ERROR bad_value: value must be finite" }
            let op = TwinOp.clockAdvance(id: id, count: UInt64(n), value: v)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinClockErrorLine(error) }
            guard let entry = twin.clocks.get(id) else { return "ERROR not_found: \(id)" }
            return twinResponse(
                "CLOCK ADVANCE", sessionId: sessionId,
                "id=\(id) n=\(n) tick=\(entry.clock.tick) gears=\(entry.gearIds.count)"
            )

        case .clockState(let id):
            guard let entry = twin.clocks.get(id) else { return "ERROR not_found: \(id)" }
            return twinResponse(
                "CLOCK STATE", sessionId: sessionId,
                "id=\(id) tick=\(entry.clock.tick) gears=[\(entry.gearIds.joined(separator: ","))]"
            )

        case .clockClose(let id):
            guard let entry = twin.clocks.get(id) else { return "ERROR not_found: \(id)" }
            let gearsClosed = entry.gearIds.count
            // Hooks bound to this clock cascade-close too (H4) — counted
            // before `.apply` closes them, like `gearsClosed` above.
            let hooksClosed = entry.hookIds.count
            let op = TwinOp.close(id: id)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinClockErrorLine(error) }
            return twinResponse(
                "CLOCK CLOSE", sessionId: sessionId,
                "id=\(id) gears_closed=\(gearsClosed) hooks_closed=\(hooksClosed)"
            )

        case .clockList:
            let ids = twin.clocks.ids.sorted()
            return twinResponse("CLOCK LIST", sessionId: sessionId, "count=\(ids.count)\(twinIdsSuffix(ids))")

        // MARK: GEAR

        case .gearOpen(let clockId, let name, let num, let den):
            guard twin.clocks.get(clockId) != nil else { return "ERROR not_found: \(clockId)" }
            guard let ratio = GearRatio.reduced(num, over: den) else {
                return "ERROR bad_value: gear ratio \(num)/\(den) must have both terms > 0"
            }
            let id = twin.nextId(prefix: "g")
            let op = TwinOp.gearOpen(id: id, clockId: clockId, name: name, num: num, den: den)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinClockErrorLine(error) }
            return twinResponse(
                "GEAR OPEN", sessionId: sessionId,
                "id=\(id) clock=\(clockId) name=\(name) ratio=\(ratio.num)/\(ratio.den)"
            )

        case .gearState(let id):
            guard let entry = twin.gears.get(id) else { return "ERROR not_found: \(id)" }
            let g = entry.gear
            let phase = g.phase
            let latchedTickStr = g.latchedTick.map { String($0) } ?? "none"
            let latchedValueStr = g.latchedValue.map { "\($0)" } ?? "none"
            return twinResponse(
                "GEAR STATE", sessionId: sessionId,
                "id=\(id) name=\(g.name) ratio=\(g.ratio.num)/\(g.ratio.den) fires=\(g.fires) "
                    + "phase=\(phase.num)/\(phase.den) latched_tick=\(latchedTickStr) latched_value=\(latchedValueStr)"
            )

        case .gearClose(let id):
            guard twin.gears.get(id) != nil else { return "ERROR not_found: \(id)" }
            let op = TwinOp.close(id: id)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinClockErrorLine(error) }
            return twinResponse("GEAR CLOSE", sessionId: sessionId, "id=\(id)")

        default:
            // Every case this family handler is dispatched (see handleTwin
            // in DagDBCommandHandler+Twin.swift) is covered above; this
            // branch exists only for switch exhaustiveness.
            return "ERROR unknown_command: twin verb not wired yet"
        }
    }

    // MARK: - Shared formatting helpers (file-scoped mirrors of +TwinStreams.swift's)

    /// `TwinState.TwinError` renders via its own `description`; any other
    /// thrown error (shouldn't happen on this path, but `apply`'s signature
    /// is `throws`, not a typed throw) falls back to `ERROR io:`.
    private func twinClockErrorLine(_ error: Error) -> String {
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

    private func twinIdsSuffix(_ ids: [String]) -> String {
        ids.isEmpty ? "" : " " + ids.joined(separator: " ")
    }
}
