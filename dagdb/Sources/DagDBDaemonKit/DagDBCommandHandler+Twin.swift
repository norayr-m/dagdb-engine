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

        case .kernelLoad, .xconvSealed, .kernelInfo, .kernelList, .kernelClose:
            return handleTwinKernel(cmd, sessionId: sessionId)

        case .alarmLoad, .alarmInfo, .alarmList, .alarmClose, .alarmFrame, .alarmCourt, .alarmSuccessor, .alarmCorrupt:
            return handleTwinAlarm(cmd, sessionId: sessionId)

        case .bankOpen, .bankGenerate, .bankFit, .bankNoise, .bankBench, .bankInfo, .bankList, .bankClose:
            return handleTwinBank(cmd, sessionId: sessionId)

        case .viewLoad, .viewReflex, .viewRung, .viewCeiling, .viewFeatures, .viewInfo, .viewList, .viewClose:
            return handleTwinView(cmd, sessionId: sessionId)

        case .foldRun, .foldKept, .foldSource, .foldTier, .foldInfo:
            return handleTwinFold(cmd, sessionId: sessionId)

        case .hookOpen, .hookStep, .hookState, .hookLedger, .hookInfo, .hookList, .hookClose:
            return handleTwinHook(cmd, sessionId: sessionId)
        }
    }

    // MARK: - Shared helpers for the family handlers (T8.2+)

    /// Total shm bytes available past the base — historically `8 +
    /// nodeCount * resultRowSize` (the [u32 count][u32 rowSize-or-0] header
    /// plus one `resultRowSize`-wide row per node), but a fixture may now
    /// size its buffer independently of `nodeCount` (`HandlerFixture`'s
    /// `shmBytes:` — FOLD RUN's control object needs a side-12 engine with
    /// a side-49-shaped output). Backed by `configuredShmCapacityBytes`,
    /// resolved once at handler init.
    var shmCapacityBytes: Int { configuredShmCapacityBytes }

    /// How many u64s the `[u32 count][u32 8][u64 × count]` layout can hold
    /// in THIS handler's mapping — the true extent behind `STREAM NEXT`'s
    /// `n` and `RECORD SLICE`'s `count` (gate D2, audit B finding 20).
    var maxU64VectorCount: Int { max(0, (shmCapacityBytes - 8) / 8) }

    /// Writes a u64 vector to shm as `[u32 count][u32 8][u64 × count]` —
    /// the layout `STREAM NEXT` and friends use for variable-length results.
    /// D2 · capacity-checked, like the read side always was. Returns nil
    /// when the vector fits, else the refusal line — nothing is written.
    @discardableResult
    func writeU64Vector(_ v: [UInt64]) -> String? {
        if let e = checkShmFits(rows: v.count, rowSize: 8) { return e }
        let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
        headerPtr[0] = UInt32(v.count)
        headerPtr[1] = 8
        let dataPtr = shmBase.advanced(by: 8).bindMemory(to: UInt64.self, capacity: max(1, v.count))
        for (i, val) in v.enumerated() { dataPtr[i] = val }
        return nil
    }

    /// Writes a Float32 vector to shm as `[u32 count][u32 4][f32 × count]` —
    /// the layout `BANK GENERATE`/`BANK FIT` and friends use for
    /// variable-length float results.
    @discardableResult
    func writeFloatVector(_ v: [Float]) -> String? {
        if let e = checkShmFits(rows: v.count, rowSize: 4) { return e }
        let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
        headerPtr[0] = UInt32(v.count)
        headerPtr[1] = 4
        let dataPtr = shmBase.advanced(by: 8).bindMemory(to: Float.self, capacity: max(1, v.count))
        for (i, val) in v.enumerated() { dataPtr[i] = val }
        return nil
    }

    /// Writes a Float64 vector to shm as `[u32 count][u32 8][f64 × count]` —
    /// the layout `FOLD TIER` uses for its Double tier answers (the ladder
    /// solves in Float64; only the fabric-stored operator/sources are
    /// Float32).
    @discardableResult
    func writeDoubleVector(_ v: [Double]) -> String? {
        if let e = checkShmFits(rows: v.count, rowSize: 8) { return e }
        let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
        headerPtr[0] = UInt32(v.count)
        headerPtr[1] = 8
        let dataPtr = shmBase.advanced(by: 8).bindMemory(to: Double.self, capacity: max(1, v.count))
        for (i, val) in v.enumerated() { dataPtr[i] = val }
        return nil
    }

    /// Reads `count` little-endian Float32s starting at `byteOffset` into shm.
    /// Returns nil if the read would run past `shmCapacityBytes`.
    func readFloats(count: Int, at byteOffset: Int) -> [Float]? {
        guard count >= 0, byteOffset >= 0, byteOffset + count * 4 <= shmCapacityBytes else { return nil }
        let ptr = shmBase.advanced(by: byteOffset).bindMemory(to: Float.self, capacity: max(1, count))
        return (0..<count).map { ptr[$0] }
    }

    /// Reads `count` little-endian Float64s starting at `byteOffset` into
    /// shm — `XCONV SEALED`'s a/b record inputs (rowSize 8). Returns nil if
    /// the read would run past `shmCapacityBytes`.
    func readDoubles(count: Int, at byteOffset: Int) -> [Double]? {
        guard count >= 0, byteOffset >= 0, byteOffset + count * 8 <= shmCapacityBytes else { return nil }
        let ptr = shmBase.advanced(by: byteOffset).bindMemory(to: Double.self, capacity: max(1, count))
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
