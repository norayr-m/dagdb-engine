/// STREAM / HEADER / RECORD verb family — real implementation (interface phase, 2026-09).
///
/// Mutating verbs follow the WAL-first pattern established by `.setWeight`
/// (DagDBCommandHandler.swift): validate → mint an id via
/// `twin.nextId(prefix:)` when opening → `appendTwinWAL` (abort on failure,
/// leaving the registry untouched) → `twin.apply` → shm (if any) → `OK …`.
/// `STREAM NEXT` follows the plan's copy/draw/log-post-state/replace shape:
/// the draw happens on a local copy of the generator so the WAL logs the
/// POST-draw state (`.streamState`) — O(1) replay never re-draws the n
/// values, it just restores the boundary the daemon already reached.
import Foundation
import DagDB

extension DagDBCommandHandler {
    func handleTwinStreams(_ cmd: TwinCommand, sessionId: String?) -> String {
        switch cmd {

        // MARK: STREAM

        case .streamOpen(let name, let stateHi, let stateLo, let incHi, let incLo):
            let id = twin.nextId(prefix: "s")
            let op = TwinOp.streamOpen(id: id, name: name, stateHi: stateHi, stateLo: stateLo, incHi: incHi, incLo: incLo)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinErrorLine(error) }
            return twinResponse("STREAM OPEN", sessionId: sessionId, "id=\(id) name=\(name) draws=0")

        case .streamNext(let id, let n):
            guard n >= 1 && n <= nodeCount * 3 else {
                return "ERROR out_of_range: n must be in [1, \(nodeCount * 3)]"
            }
            guard var stream = twin.streams.get(id) else { return "ERROR not_found: \(id)" }
            var values: [UInt64] = []
            values.reserveCapacity(n)
            for _ in 0..<n { values.append(stream.next64()) }
            let post = stream.stateWords
            let op = TwinOp.streamState(id: id, stateHi: post.hi, stateLo: post.lo, draws: stream.draws)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinErrorLine(error) }
            writeU64Vector(values)
            return twinResponse(
                "STREAM NEXT", sessionId: sessionId,
                "id=\(id) n=\(n) draws=\(stream.draws) state=\(hexWord(post.hi)):\(hexWord(post.lo)) shm_bytes=\(8 * n)"
            )

        case .streamState(let id):
            guard let stream = twin.streams.get(id) else { return "ERROR not_found: \(id)" }
            let s = stream.stateWords
            return twinResponse(
                "STREAM STATE", sessionId: sessionId,
                "id=\(id) name=\(stream.name) draws=\(stream.draws) state=\(hexWord(s.hi)):\(hexWord(s.lo))"
            )

        case .streamClose(let id):
            guard twin.streams.get(id) != nil else { return "ERROR not_found: \(id)" }
            let op = TwinOp.close(id: id)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinErrorLine(error) }
            return twinResponse("STREAM CLOSE", sessionId: sessionId, "id=\(id)")

        case .streamList:
            let ids = twin.streams.ids.sorted()
            return twinResponse("STREAM LIST", sessionId: sessionId, "count=\(ids.count)\(idsSuffix(ids))")

        // MARK: HEADER

        case .headerCheck(let band, let tau, let comb, let echo, let record, let step, let floor):
            guard band.isFinite, tau.isFinite, comb.isFinite, echo.isFinite,
                  record.isFinite, step.isFinite, floor.isFinite else {
                return "ERROR bad_value: header fields must be finite"
            }
            let header = StreamHeader(
                signalBandHz: band, tauWindowSec: tau, combRateHz: comb,
                firstEchoSec: echo, recordWindowSec: record, stepSec: step, clockSyncFloorSec: floor
            )
            let violations = header.violations()
            guard violations.isEmpty else {
                let sidStr = sessionId.map { " session=\($0)" } ?? ""
                let desc = violations.map(violationTag).joined(separator: ";")
                return "FAIL HEADER CHECK\(sidStr) violations=\(violations.count) \(desc)"
            }
            return twinResponse("HEADER CHECK", sessionId: sessionId, "admissible=1")

        // MARK: RECORD

        case .recordOpen(let name, let band, let tau, let comb, let echo, let record, let step, let floor,
                          let stateHi, let stateLo, let incHi, let incLo):
            let header = StreamHeader(
                signalBandHz: band, tauWindowSec: tau, combRateHz: comb,
                firstEchoSec: echo, recordWindowSec: record, stepSec: step, clockSyncFloorSec: floor
            )
            let violations = header.violations()
            guard violations.isEmpty else {
                let desc = violations.map(violationTag).joined(separator: ";")
                return "ERROR schema: inadmissible header: \(desc)"
            }
            let id = twin.nextId(prefix: "t")
            let op = TwinOp.recordOpen(id: id, name: name, header: header, stateHi: stateHi, stateLo: stateLo, incHi: incHi, incLo: incLo)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinErrorLine(error) }
            return twinResponse("RECORD OPEN", sessionId: sessionId, "id=\(id) name=\(name) slices=0")

        case .recordSlice(let id, let count):
            guard count >= 1 && count <= nodeCount * 3 else {
                return "ERROR out_of_range: count must be in [1, \(nodeCount * 3)]"
            }
            guard twin.records.get(id) != nil else { return "ERROR not_found: \(id)" }
            let op = TwinOp.recordSlice(id: id, count: UInt32(count))
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinErrorLine(error) }
            guard let rec = twin.records.get(id) else { return "ERROR not_found: \(id)" }
            return twinResponse(
                "RECORD SLICE", sessionId: sessionId,
                "id=\(id) index=\(rec.slices.count - 1) count=\(count) slices=\(rec.slices.count)"
            )

        case .recordReplay(let id, let index):
            guard let rec = twin.records.get(id) else { return "ERROR not_found: \(id)" }
            guard rec.slices.indices.contains(index) else {
                return "ERROR out_of_range: index \(index) not in [0, \(rec.slices.count))"
            }
            do {
                let payload = try rec.replaySlice(index)
                writeU64Vector(payload)
                let match = payload == rec.slices[index].payload ? 1 : 0
                return twinResponse(
                    "RECORD REPLAY", sessionId: sessionId,
                    "id=\(id) index=\(index) count=\(payload.count) match=\(match) shm_bytes=\(8 * payload.count)"
                )
            } catch {
                return twinErrorLine(error)
            }

        case .recordVerify(let id):
            guard let rec = twin.records.get(id) else { return "ERROR not_found: \(id)" }
            let failing = rec.verify()
            let idxStr = failing.isEmpty ? "" : " failing_indices=" + failing.map(String.init).joined(separator: ",")
            return twinResponse("RECORD VERIFY", sessionId: sessionId, "id=\(id) failing=\(failing.count)\(idxStr)")

        case .recordInfo(let id):
            guard let rec = twin.records.get(id) else { return "ERROR not_found: \(id)" }
            return twinResponse(
                "RECORD INFO", sessionId: sessionId,
                "id=\(id) name=\(rec.streamName) slices=\(rec.slices.count) draws=\(rec.generatorState.draws)"
            )

        case .recordClose(let id):
            guard twin.records.get(id) != nil else { return "ERROR not_found: \(id)" }
            let op = TwinOp.close(id: id)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinErrorLine(error) }
            return twinResponse("RECORD CLOSE", sessionId: sessionId, "id=\(id)")

        case .recordList:
            let ids = twin.records.ids.sorted()
            return twinResponse("RECORD LIST", sessionId: sessionId, "count=\(ids.count)\(idsSuffix(ids))")

        default:
            // Every case this family handler is dispatched (see handleTwin
            // in DagDBCommandHandler+Twin.swift) is covered above; this
            // branch exists only for switch exhaustiveness.
            return "ERROR unknown_command: twin verb not wired yet"
        }
    }

    // MARK: - Shared formatting helpers

    /// `TwinState.TwinError` renders via its own `description`; any other
    /// thrown error (shouldn't happen on this path, but `apply`'s signature
    /// is `throws`, not a typed throw) falls back to `ERROR io:`.
    private func twinErrorLine(_ error: Error) -> String {
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

    private func hexWord(_ v: UInt64) -> String {
        String(format: "0x%016llx", v)
    }

    private func idsSuffix(_ ids: [String]) -> String {
        ids.isEmpty ? "" : " " + ids.joined(separator: " ")
    }

    private func violationTag(_ v: StreamHeader.Violation) -> String {
        switch v {
        case .nonPositiveQuantity(let q): return "nonPositiveQuantity(\(q))"
        case .signalWiderThanWindow: return "signalWiderThanWindow"
        case .combBelowNyquist: return "combBelowNyquist"
        case .recordOutlivesEcho: return "recordOutlivesEcho"
        case .stepAboveNyquist: return "stepAboveNyquist"
        }
    }
}
