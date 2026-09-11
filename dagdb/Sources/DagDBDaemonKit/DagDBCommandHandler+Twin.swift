/// DagDBCommandHandler+Twin — dispatcher for the twin-spec DSL (interface phase, 2026-09).
///
/// The handler's `twin` property holds the real `DagDB.TwinState` (interface phase, 2026-09) —
/// daemon-global, so every connection (primary and reader sessions alike)
/// shares one instance.
///
/// `handleTwin` fans each verb out to its family handler. STREAM/HEADER/
/// RECORD are real as of T8.2; RINGS/CLOCK/GEAR (T8.3), XCONV/BUDGET (T8.4),
/// and ALARM (T8.5) remain stubs until their tasks land.
import Foundation
import DagDB

extension DagDBCommandHandler {

    func handleTwin(_ cmd: TwinCommand, sessionId: String?) -> String {
        switch cmd {
        case .streamOpen, .streamNext, .streamState, .streamClose, .streamList,
             .headerCheck,
             .recordOpen, .recordSlice, .recordReplay, .recordVerify, .recordInfo, .recordClose, .recordList:
            return handleTwinStreams(cmd, sessionId: sessionId)

        case .ringsOpen, .ringsWrite, .ringsRecall, .ringsInfo, .ringsClose, .ringsList,
             .clockOpen, .clockAdvance, .clockState, .clockClose, .clockList,
             .gearOpen, .gearState, .gearClose:
            return handleTwinClocks(cmd, sessionId: sessionId)

        case .xconvCheck,
             .budgetOpen, .budgetSealed, .budgetAllocate, .budgetInfo, .budgetClose, .budgetList:
            return handleTwinBudget(cmd, sessionId: sessionId)

        case .alarmLoad, .alarmInfo, .alarmList, .alarmClose, .alarmFrame, .alarmCourt, .alarmSuccessor, .alarmCorrupt:
            return handleTwinAlarm(cmd, sessionId: sessionId)
        }
    }

    // MARK: - Shared helpers for the family handlers (T8.2+)

    /// Total shm bytes available past the base — the [u32 count][u32 rowSize-or-0]
    /// header plus one `resultRowSize`-wide row per node, mirroring the
    /// allocation every test fixture and the daemon's real shm segment use.
    var shmCapacityBytes: Int { 8 + nodeCount * resultRowSize }

    /// Writes a u64 vector to shm as `[u32 count][u32 8][u64 × count]` —
    /// the layout `STREAM NEXT` and friends use for variable-length results.
    func writeU64Vector(_ v: [UInt64]) {
        let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
        headerPtr[0] = UInt32(v.count)
        headerPtr[1] = 8
        let dataPtr = shmBase.advanced(by: 8).bindMemory(to: UInt64.self, capacity: max(1, v.count))
        for (i, val) in v.enumerated() { dataPtr[i] = val }
    }

    /// Reads `count` little-endian Float32s starting at `byteOffset` into shm.
    /// Returns nil if the read would run past `shmCapacityBytes`.
    func readFloats(count: Int, at byteOffset: Int) -> [Float]? {
        guard count >= 0, byteOffset >= 0, byteOffset + count * 4 <= shmCapacityBytes else { return nil }
        let ptr = shmBase.advanced(by: byteOffset).bindMemory(to: Float.self, capacity: max(1, count))
        return (0..<count).map { ptr[$0] }
    }

    /// Formats a twin verb's OK reply, folding in `session=<id>` when the
    /// call came through a reader session (mirrors the non-twin verbs'
    /// `session=` convention in handleReadOnly).
    func twinResponse(_ verb: String, sessionId: String?, _ kv: String) -> String {
        if let sid = sessionId {
            return "OK \(verb) session=\(sid) \(kv)"
        }
        return "OK \(verb) \(kv)"
    }

    /// Log-first discipline for twin mutations (mirrors `.setWeight`'s
    /// WAL-before-buffer pattern): append the op to the WAL BEFORE calling
    /// `twin.apply`, so a WAL failure aborts the mutation and the log and
    /// twin state stay in sync. Returns nil when there is no appender
    /// (WAL disabled) or the append succeeded; returns the `ERROR wal:`
    /// line to propagate otherwise.
    func appendTwinWAL(_ op: TwinOp) -> String? {
        guard let wal = walAppender else { return nil }
        do {
            _ = try wal.twin(op)
            return nil
        } catch {
            return "ERROR wal: append: \(error)"
        }
    }
}
