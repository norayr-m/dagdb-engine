/// STREAM / HEADER / RECORD verb family.
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
            if let e = nameCapRefusal("STREAM OPEN", name) { return e }
            // The count cap, then the stream's bytes.
            if let e = admitTwinCreate("STREAM OPEN", prefix: "s", bytes: Self.alloc1bStreamBytes(nameBytes: name.utf8.count),
                                       what: "a stream, 1.1*(410 B + the name)") { return e }
            let id = twin.nextId(prefix: "s")
            let op = TwinOp.streamOpen(id: id, name: name, stateHi: stateHi, stateLo: stateLo, incHi: incHi, incLo: incLo)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinErrorLine(error) }
            return twinResponse("STREAM OPEN", sessionId: sessionId, "id=\(id) name=\(Reply.quoted(name)) draws=0")

        case .streamNext(let id, let n):
            // The bound is the shm mapping's real capacity, not the
            // hardcoded `nodeCount * 3` restatement of it. For a default
            // handler the two are the same number (8 + n·24 bytes holds
            // 3n u64s); for a `shmBytes:`-built one they are not, and the
            // old bound stayed wide while the buffer shrank.
            guard n >= 1 && n <= maxU64VectorCount else {
                return "ERROR out_of_range: n \(n) not in 1...\(maxU64VectorCount)"
                    + " — shm holds \(shmCapacityBytes) bytes"
            }
            guard var stream = twin.streams.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            var values: [UInt64] = []
            values.reserveCapacity(n)
            for _ in 0..<n { values.append(stream.next64()) }
            let post = stream.stateWords
            let op = TwinOp.streamState(id: id, stateHi: post.hi, stateLo: post.lo, draws: stream.draws)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinErrorLine(error) }
            if let e = writeU64Vector(values) { return e }
            return twinResponse(
                "STREAM NEXT", sessionId: sessionId,
                "id=\(id) n=\(n) draws=\(stream.draws) state=\(hexWord(post.hi)):\(hexWord(post.lo)) shm_bytes=\(8 * n)"
            )

        case .streamState(let id):
            guard let stream = twin.streams.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            let s = stream.stateWords
            return twinResponse(
                "STREAM STATE", sessionId: sessionId,
                "id=\(id) name=\(Reply.quoted(stream.name)) draws=\(stream.draws) state=\(hexWord(s.hi)):\(hexWord(s.lo))"
            )

        case .streamClose(let id):
            guard twin.streams.get(id) != nil else { return "ERROR not_found: \(Reply.quoted(id))" }
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
            // The seventh quantity is judged here too, so this
            // verb and `RECORD OPEN` answer the same header the same way:
            // `StreamRecord`'s birth refuses a declared clock-sync floor
            // coarser than the step or reaching the record window, and this
            // check used to answer `admissible=1` for exactly those headers.
            let tags = header.violations().map(violationTag)
                + header.clockSyncViolations().map(clockSyncTag)
            guard tags.isEmpty else {
                let sidStr = sessionId.map { " session=\($0)" } ?? ""
                return "FAIL HEADER CHECK\(sidStr) violations=\(tags.count) \(tags.joined(separator: ";"))"
            }
            return twinResponse("HEADER CHECK", sessionId: sessionId, "admissible=1")

        // MARK: RECORD

        case .recordOpen(let name, let band, let tau, let comb, let echo, let record, let step, let floor,
                          let stateHi, let stateLo, let incHi, let incLo):
            if let e = nameCapRefusal("RECORD OPEN", name) { return e }
            let header = StreamHeader(
                signalBandHz: band, tauWindowSec: tau, combRateHz: comb,
                firstEchoSec: echo, recordWindowSec: record, stepSec: step, clockSyncFloorSec: floor
            )
            let violations = header.violations()
            guard violations.isEmpty else {
                let desc = violations.map(violationTag).joined(separator: ";")
                return "ERROR schema: inadmissible header: \(desc)"
            }
            // The seventh quantity too, before the
            // WAL. `StreamRecord`'s birth refuses a clock-sync floor coarser
            // than the step or reaching the record window, and the handler
            // asked only the six rules, so that refusal came after the
            // TWIN_RECORD_OPEN record. Same words as before.
            let floorViolations = header.clockSyncViolations()
            guard floorViolations.isEmpty else {
                return "ERROR schema: \(StreamRecord.RecordError.inadmissibleClockSyncFloor(floorViolations))"
            }
            // HEADER CHECK's finite rule too,
            // before the WAL. A nan the six rules and the floor rule pass
            // (every comparison with nan is false) answered OK, and every
            // SAVE and every loader's rebase then refused (JSON cannot encode
            // nan) until RECORD CLOSE, across restarts. HEADER CHECK's words.
            guard band.isFinite, tau.isFinite, comb.isFinite, echo.isFinite,
                  record.isFinite, step.isFinite, floor.isFinite else {
                return "ERROR bad_value: header fields must be finite; nothing written"
            }
            // The count cap, then the record's bytes.
            if let e = admitTwinCreate("RECORD OPEN", prefix: "t",
                                       bytes: Self.alloc1bRecordBytes(nameBytes: name.utf8.count, slices: 0, draws: 0),
                                       what: "a record, 1.1*(300 B + the name)") { return e }
            let id = twin.nextId(prefix: "t")
            let op = TwinOp.recordOpen(id: id, name: name, header: header, stateHi: stateHi, stateLo: stateLo, incHi: incHi, incLo: incLo)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinErrorLine(error) }
            return twinResponse("RECORD OPEN", sessionId: sessionId, "id=\(id) name=\(Reply.quoted(name)) slices=0")

        case .recordSlice(let id, let count):
            guard count >= 1 && count <= maxU64VectorCount else {
                return "ERROR out_of_range: count \(count) not in 1...\(maxU64VectorCount)"
                    + " — shm holds \(shmCapacityBytes) bytes"
            }
            guard twin.records.get(id) != nil else { return "ERROR not_found: \(Reply.quoted(id))" }
            // The record's count is a u32; only the shm size held
            // `UInt32(count)` (a count past u32 needs a shm above 32 GiB).
            guard let count32 = UInt32(exactly: count) else {
                return "ERROR out_of_range: RECORD SLICE count \(count) not in 1...\(UInt32.max); nothing written"
            }
            // The per-record slice cap (after the shm check), then the slice's bytes and the
            // copy of the record's slices array its append makes.
            if let rec0 = twin.records.get(id) {
                let have = rec0.slices.count
                if have >= Self.alloc1bSlicesPerRecordCap {
                    return "ERROR out_of_budget: RECORD SLICE needs \(have + 1) slices on \(id), the per-record slice cap is"
                        + " \(Self.alloc1bSlicesPerRecordCap); nothing written"
                }
                if let e = admit("RECORD SLICE", bytes: Self.newBytes(Self.alloc1bMargin * (100 + 8.32 * Double(count) + 48 * Double(have))),
                                 what: "a slice, 1.1*(100 B + 1.04*8*count), and the copy of the record's slices array, 1.1*48 B per slice") {
                    return e
                }
            }
            // The replay ceiling before the
            // WAL, in apply's words, at apply's place in the order (it came
            // after the record before, so the record stayed in the log).
            if let e = TwinState.recordSliceRefusal(count: count) { return twinErrorLine(e) }
            let op = TwinOp.recordSlice(id: id, count: count32)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinErrorLine(error) }
            guard let rec = twin.records.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            return twinResponse(
                "RECORD SLICE", sessionId: sessionId,
                "id=\(id) index=\(rec.slices.count - 1) count=\(count) slices=\(rec.slices.count)"
            )

        case .recordReplay(let id, let index):
            guard let rec = twin.records.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            guard rec.slices.indices.contains(index) else {
                return "ERROR out_of_range: index \(index) not in [0, \(rec.slices.count))"
            }
            do {
                let payload = try rec.replaySlice(index)
                if let e = writeU64Vector(payload) { return e }
                let match = payload == rec.slices[index].payload ? 1 : 0
                return twinResponse(
                    "RECORD REPLAY", sessionId: sessionId,
                    "id=\(id) index=\(index) count=\(payload.count) match=\(match) shm_bytes=\(8 * payload.count)"
                )
            } catch {
                return twinErrorLine(error)
            }

        case .recordVerify(let id):
            guard let rec = twin.records.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            let failing = rec.verify()
            let idxStr = failing.isEmpty ? "" : " failing_indices=" + failing.map(String.init).joined(separator: ",")
            return twinResponse("RECORD VERIFY", sessionId: sessionId, "id=\(id) failing=\(failing.count)\(idxStr)")

        case .recordInfo(let id):
            guard let rec = twin.records.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            return twinResponse(
                "RECORD INFO", sessionId: sessionId,
                "id=\(id) name=\(Reply.quoted(rec.streamName)) slices=\(rec.slices.count) draws=\(rec.generatorState.draws)"
            )

        case .recordClose(let id):
            guard twin.records.get(id) != nil else { return "ERROR not_found: \(Reply.quoted(id))" }
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
            case .notFound(let s): return "ERROR not_found: \(Reply.quoted(s))"
            case .badId(let s): return "ERROR bad_value: \(Reply.quoted(s))"
            case .badValue(let s): return "ERROR bad_value: \(s)"
            case .schema(let s): return "ERROR schema: \(s)"
            case .io(let s): return "ERROR io: \(s)"
            }
        }
        return Reply.errorLine("io", error)
    }

    private func hexWord(_ v: UInt64) -> String {
        String(format: "0x%016llx", v)
    }

    private func idsSuffix(_ ids: [String]) -> String {
        ids.isEmpty ? "" : " " + ids.joined(separator: " ")
    }

    /// The clock-sync half of the header's judgement, tagged in the
    /// same style as `violationTag` so one `FAIL HEADER CHECK` line carries
    /// both kinds.
    private func clockSyncTag(_ v: StreamHeader.ClockSyncViolation) -> String {
        switch v {
        case let .floorAboveStep(floor, step): return "floorAboveStep(\(floor),\(step))"
        case let .floorOutlivesRecord(floor, window): return "floorOutlivesRecord(\(floor),\(window))"
        }
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
