/// DagDBWAL — write-ahead log for DagDB mutations.
///
/// Log-first discipline: every mutation (setTruth / setRank / setLUT) is
/// appended to the log and fsync'd BEFORE being applied to engine buffers.
/// On crash, replay the log on top of the last snapshot to recover committed
/// state exactly.
///
/// Log file format (append-only, little-endian):
///     Header (16 B):  "DAGW" (4) + version u32 + nodeCount u32 + reserved u32
///     Record: length u32 (payload-only) + opcode u8 + payload bytes
///
/// Versions:
///     1 — the opcode set up to 0x11 plus the twin range. SET_RANK payloads
///         of 5 (u8 rank) and 8 (u32 rank) bytes are LEGACY and accepted.
///     2 — adds the combinational-edge and bulk-install opcodes 0x12…0x16,
///         so every mutation the daemon performs is in the log, as this
///         file's header has always claimed. Under version 2 a SET_RANK
///         payload is 12 bytes or the record is torn: 5 and 8 are no longer
///         a legacy shape to fall back on, they are counted as skipped.
///     A version above 2 is refused by name. A version-1 file still replays
///     in full — its opcode set is a subset of version 2's.
///
/// Opcodes and payloads (length = payload byte count, does not include opcode):
///     0x01 SET_TRUTH         u32 node + u8 value                → length = 5
///     0x02 SET_RANK          u32 node + u64 value               → length = 12
///                            (v1 legacy: u32 node + u32 = 8, + u8 = 5)
///     0x03 SET_LUT           u32 node + u64 lut                 → length = 12
///     0x10 CONNECT_BACK      u32 src  + u32 dst                 → length = 8
///     0x11 CLEAR_BACK_EDGES  u32 dst                            → length = 4
///
///     Version 2 — combinational edges and bulk installs:
///     0x12 CONNECT           u32 dst + u8 slot + i32 src        → length = 9
///          One neighbour slot, written by the slot the daemon chose, so a
///          replay reproduces the table regardless of the order records land.
///     0x13 CLEAR_EDGES       u32 node                           → length = 4
///          All six combinational slots of `node` reset to -1.
///     0x14 SET_RANKS_BULK    u32 n + u64 rank[n]                → 4 + 8n
///     0x15 SET_LUTS_BULK     u32 n + u64 lut[n]                 → 4 + 8n
///     0x16 SET_NEIGHBORS_BULK u32 n + i32 nb[n*6]               → 4 + 24n
///          The three bulk installs carry their whole vector: they overwrite
///          the buffer wholesale, so a per-record diff would be larger, not
///          smaller. `n` must equal the log's node count or the record is
///          counted as out-of-range, not applied.
///
///     Twin registry ops (interface phase, 2026-09) — one opcode per `TwinOp` case, payload
///     encoded/decoded by `TwinWALCodec` (strings u16-len + UTF-8; u64/u32
///     little-endian; f64/f32 as bitPattern; arrays u32-count prefixed):
///     0x20 TWIN_STREAM_OPEN    TwinOp.streamOpen
///     0x21 TWIN_STREAM_STATE   TwinOp.streamState
///     0x22 TWIN_RECORD_OPEN    TwinOp.recordOpen
///     0x23 TWIN_RECORD_SLICE   TwinOp.recordSlice
///     0x24 TWIN_RINGS_OPEN     TwinOp.ringsOpen
///     0x25 TWIN_RINGS_WRITE    TwinOp.ringsWrite
///     0x26 TWIN_CLOCK_OPEN     TwinOp.clockOpen
///     0x27 TWIN_CLOCK_ADVANCE  TwinOp.clockAdvance
///     0x28 TWIN_GEAR_OPEN      TwinOp.gearOpen
///     0x29 TWIN_LAYOUT_OPEN    TwinOp.layoutOpen
///     0x2A TWIN_ALARM_LOAD     TwinOp.alarmLoad
///     0x2B TWIN_CLOSE          TwinOp.close
///     0x2C TWIN_BANK_OPEN      TwinOp.bankOpen
///     0x2D TWIN_VIEW_LOAD      TwinOp.viewLoad
///     0x2E TWIN_KERNEL_LOAD    TwinOp.kernelLoad
///     0x2F TWIN_HOOK_OPEN      TwinOp.hookOpen
///     0x30 TWIN_HOOK_STEP      TwinOp.hookStep
///     A twin op with a malformed payload (bad length, bad UTF-8) is
///     skipped on replay, never fatal. `replay(twin:)` with `twin == nil`
///     skips all twin-range opcodes entirely (the record is still walked,
///     just not applied).
///
///     0xF0 CHECKPOINT        u64 epoch                          → length = 8
///
/// A CHECKPOINT marks the boundary at which the engine state was snapshotted
/// to disk. On replay, records before the LAST checkpoint may be discarded;
/// records after must be replayed.
///
/// Each record's length prefix is what lets the replay code detect a
/// truncated tail: if the declared length doesn't fit in the remaining file
/// bytes, the record is dropped (interpreted as a crash mid-append).

import Foundation

public enum DagDBWAL {

    public static let magic: [UInt8] = [0x44, 0x41, 0x47, 0x57]  // "DAGW"
    /// The opcode set before the combinational-edge and bulk-install ops.
    public static let versionV1: UInt32 = 1
    /// Adds 0x12…0x16 and makes the 12-byte SET_RANK payload the only one.
    public static let versionV2: UInt32 = 2
    /// The version a freshly created log is stamped with.
    public static let version: UInt32 = versionV2
    public static let headerSize: Int = 16

    public enum Opcode: UInt8 {
        case setTruth        = 0x01
        case setRank         = 0x02
        case setLUT          = 0x03
        case setEdgeWeight   = 0x04  // u32 node + u8 dir + f32 value = 9 B (E1)
        case setActivation   = 0x05  // u32 node + i16 value = 6 B (E1)
        case setNodeValue    = 0x06  // u32 node + f32 value = 8 B (E1)
        case connectBack     = 0x10
        case clearBackEdges  = 0x11
        // Version 2 — the combinational-edge writes that used to bypass the
        // log entirely (audit A, finding 28).
        case connect          = 0x12  // u32 dst + u8 slot + i32 src = 9 B
        case clearEdges       = 0x13  // u32 node = 4 B
        case setRanksBulk     = 0x14  // u32 n + u64[n]
        case setLutsBulk      = 0x15  // u32 n + u64[n]
        case setNeighborsBulk = 0x16  // u32 n + i32[n*6]
        // Twin registry ops (interface phase, 2026-09) — payload via TwinWALCodec, one per
        // TwinOp case. Kept contiguous so replay can range-match them.
        case twinStreamOpen   = 0x20  // TwinOp.streamOpen
        case twinStreamState  = 0x21  // TwinOp.streamState
        case twinRecordOpen   = 0x22  // TwinOp.recordOpen
        case twinRecordSlice  = 0x23  // TwinOp.recordSlice
        case twinRingsOpen    = 0x24  // TwinOp.ringsOpen
        case twinRingsWrite   = 0x25  // TwinOp.ringsWrite
        case twinClockOpen    = 0x26  // TwinOp.clockOpen
        case twinClockAdvance = 0x27  // TwinOp.clockAdvance
        case twinGearOpen     = 0x28  // TwinOp.gearOpen
        case twinLayoutOpen   = 0x29  // TwinOp.layoutOpen
        case twinAlarmLoad    = 0x2A  // TwinOp.alarmLoad
        case twinClose        = 0x2B  // TwinOp.close
        case twinBankOpen     = 0x2C  // TwinOp.bankOpen
        case twinViewLoad     = 0x2D  // TwinOp.viewLoad
        case twinKernelLoad   = 0x2E  // TwinOp.kernelLoad
        case twinHookOpen     = 0x2F  // TwinOp.hookOpen
        case twinHookStep     = 0x30  // TwinOp.hookStep
        case checkpoint      = 0xF0
    }

    public enum WALError: Error, CustomStringConvertible {
        case ioFailure(String)
        case invalidMagic
        case unsupportedVersion(UInt32)
        case truncated(String)
        /// An opcode introduced at a later version was offered to an older
        /// log. The record is NOT written: a file whose header says v1 must
        /// not carry an op a v1 reader would not understand.
        case opcodeNeedsVersion(opcode: UInt8, needs: UInt32, fileVersion: UInt32)
        /// `truncate` was called while an `Appender` still holds the file
        /// open (audit A, finding 33). See the note on `truncate`.
        case appenderOpen(path: String)

        public var description: String {
            switch self {
            case .ioFailure(let s):           return "io: \(s)"
            case .invalidMagic:               return "invalid magic"
            case .unsupportedVersion(let v):  return "version \(v)"
            case .truncated(let s):           return "truncated: \(s)"
            case let .opcodeNeedsVersion(op, needs, fileVersion):
                return String(format:
                    "opcode 0x%02x needs log version %u, this log is version %u",
                    op, needs, fileVersion)
            case .appenderOpen(let p):
                return "truncate refused: an Appender is still open on \(p) — " +
                       "release the appender first, or its O_APPEND descriptor " +
                       "would keep writing to the unlinked inode"
            }
        }
    }

    /// Why records were not applied. Every replay reports these; a replay
    /// that skipped anything is never silent.
    ///
    /// - `badLength`: the payload length does not match the opcode's shape
    ///   (a torn record, or a legacy width no longer legal at this version).
    ///   A twin op whose payload does not decode is counted here too.
    /// - `outOfRangeIndex`: the record is well-formed but names something
    ///   this engine cannot address — a node index at or past `nodeCount`,
    ///   a direction outside 0…5, a bulk vector of the wrong length, or a
    ///   twin op whose id the registry rejects.
    /// - `unknownOpcode`: an opcode this build does not know. Expected when
    ///   a newer writer's log is replayed by an older reader.
    public struct SkipReasons: Equatable, Sendable {
        public var badLength: Int = 0
        public var outOfRangeIndex: Int = 0
        public var unknownOpcode: Int = 0
        public var total: Int { badLength + outOfRangeIndex + unknownOpcode }
        /// One-line histogram for logs and replies.
        public var line: String {
            "bad_length=\(badLength) out_of_range=\(outOfRangeIndex) unknown_opcode=\(unknownOpcode)"
        }
        public init() {}
    }

    public struct ReplayResult {
        public let recordsApplied: Int
        public let recordsAfterCheckpoint: Int
        public let checkpointEpoch: UInt64
        public let elapsedMs: Double
        public let truncatedAtOffset: Int?
        /// Records inside the replay window that were walked past instead of
        /// applied. Equals `skipReasons.total`.
        public let recordsSkipped: Int
        public let skipReasons: SkipReasons
        /// The log header's version. 1 for a legacy log, 2 for a current one.
        public let fileVersion: UInt32
    }

    // MARK: - Open-appender registry (C1e)

    private static let openLock = NSLock()
    private static var openAppenderPaths: [String: Int] = [:]

    private static func canonical(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private static func registerAppender(_ path: String) {
        let k = canonical(path)
        openLock.lock(); defer { openLock.unlock() }
        openAppenderPaths[k, default: 0] += 1
    }

    private static func unregisterAppender(_ path: String) {
        let k = canonical(path)
        openLock.lock(); defer { openLock.unlock() }
        if let c = openAppenderPaths[k] {
            if c <= 1 { openAppenderPaths.removeValue(forKey: k) }
            else { openAppenderPaths[k] = c - 1 }
        }
    }

    /// Whether some `Appender` in this process currently holds the log open.
    public static func hasOpenAppender(path: String) -> Bool {
        let k = canonical(path)
        openLock.lock(); defer { openLock.unlock() }
        return openAppenderPaths[k] != nil
    }

    // MARK: - Appender

    /// fsync policy for the appender (G73).
    /// - `.everyRecord` (default): fsync with F_FULLFSYNC after every record —
    ///   byte-identical, durability-identical to the pre-G73 behavior. A crash
    ///   loses nothing that `append` returned from.
    /// - `.grouped(n, ms)`: the record's bytes are `write()`-ed to the OS file
    ///   immediately (visible to a reader / to replay) but the durable fsync is
    ///   deferred to the earlier of: n unsynced records accumulated, `ms`
    ///   milliseconds elapsed since the first unsynced record, or an explicit
    ///   `barrier()`. A crash loses at most the unsynced tail — bounded by n
    ///   records (and by the timer). `n <= 0` or `ms <= 0` degrade to
    ///   `.everyRecord` (no unbounded loss).
    public enum FsyncPolicy: Equatable, Sendable {
        case everyRecord
        case grouped(n: Int, ms: Int)
    }

    /// Append-only log writer. Re-opens (or creates) the log.
    ///
    /// A single serial queue owns both appends and the deferred-fsync timer, so
    /// the timer thread and the caller never race on the file descriptor or the
    /// unsynced-record counter (failure surface (a) in the G73 arch plan).
    public final class Appender {
        public let path: String
        public let nodeCount: UInt32
        public let policy: FsyncPolicy
        /// The version stamped in THIS file's header. A fresh log is
        /// `DagDBWAL.version`; an existing one keeps whatever it declared,
        /// and `append` refuses an opcode that version cannot describe.
        public let fileVersion: UInt32
        private var fd: Int32 = -1
        /// Set once the path is in the open-appender registry, so a throw
        /// late in `init` cannot decrement another appender's entry.
        private var registered: Bool = false

        /// C12 · gate seam. When true, every `append` refuses instead of
        /// writing, so a test can observe what a caller does when the log
        /// will not take a record.
        ///
        /// The order a mutation is applied in — append first, then write the
        /// buffer — cannot be gated by killing the process between the two:
        /// there is no way to stop a test there. It CAN be gated by the
        /// other end of the same order: a log that refuses must leave the
        /// engine untouched. That needs an appender whose `append` throws,
        /// and a real one cannot be produced on this machine (the descriptor
        /// is opened `O_WRONLY` at init, so a later `chmod` does not reach
        /// it, and an unwritable path makes `init` itself throw). This flag
        /// is that appender. It is `internal`, defaults to false, and is
        /// never set by any code outside a test.
        internal var refuseAppendsForGate: Bool = false

        /// Serial queue owning all fd writes, fsyncs, and the timer.
        private let queue = DispatchQueue(label: "dagdb.wal.appender")
        /// Deferred-fsync timer, armed on the first unsynced record in a group.
        private var timer: DispatchSourceTimer?
        /// Records written to the OS file but not yet F_FULLFSYNC'd. Only
        /// mutated on `queue`. Exposed for the group-commit bound test: after
        /// every append this is guaranteed `<= n` in `.grouped(n, _)`.
        private var _unsyncedCount: Int = 0
        /// Thread-safe snapshot of the unsynced-record counter.
        public var unsyncedCount: Int { queue.sync { _unsyncedCount } }

        public init(path: String, nodeCount: Int,
                    policy: FsyncPolicy = .everyRecord) throws {
            self.path = path
            self.nodeCount = UInt32(nodeCount)
            // Degrade a nonsensical group config to per-record rather than
            // leaving durability unbounded.
            switch policy {
            case .grouped(let n, let ms) where n <= 0 || ms <= 0:
                self.policy = .everyRecord
            default:
                self.policy = policy
            }

            let fm = FileManager.default
            let exists = fm.fileExists(atPath: path)
            if !exists {
                self.fileVersion = DagDBWAL.version
                fm.createFile(atPath: path, contents: nil)
                // Write header.
                self.fd = open(path, O_WRONLY | O_APPEND)
                guard self.fd >= 0 else {
                    throw WALError.ioFailure("open create: errno=\(errno)")
                }
                var header = Data()
                header.append(contentsOf: magic)
                appendU32(&header, version)
                appendU32(&header, self.nodeCount)
                appendU32(&header, 0)  // reserved
                try header.withUnsafeBytes { buf in
                    let w = write(self.fd, buf.baseAddress, header.count)
                    if w != header.count {
                        throw WALError.ioFailure("write header: \(w)/\(header.count)")
                    }
                }
                _ = fcntl(self.fd, F_FULLFSYNC)
            } else {
                // Validate header matches.
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      data.count >= headerSize else {
                    throw WALError.truncated("header")
                }
                let m = [UInt8](data[0..<4])
                guard m == magic else { throw WALError.invalidMagic }
                let ver = readU32(data, 4)
                // A v1 log is still appendable — its opcodes are a subset.
                // Anything past the version this build writes is refused by
                // name rather than appended to blind.
                guard ver == versionV1 || ver == versionV2 else {
                    throw WALError.unsupportedVersion(ver)
                }
                self.fileVersion = ver
                let fileNC = readU32(data, 8)
                guard fileNC == self.nodeCount else {
                    throw WALError.ioFailure("nodeCount mismatch \(fileNC) vs \(self.nodeCount)")
                }

                self.fd = open(path, O_WRONLY | O_APPEND)
                guard self.fd >= 0 else {
                    throw WALError.ioFailure("open existing: errno=\(errno)")
                }
            }
            DagDBWAL.registerAppender(path)
            self.registered = true
        }

        deinit {
            if registered { DagDBWAL.unregisterAppender(path) }
            // Flush any deferred tail so a normal appender teardown is durable,
            // then tear the timer down and close the fd. Runs on `queue` to
            // keep the fd/timer invariant.
            queue.sync {
                syncNowLocked()
                timer?.cancel()
                timer = nil
                if fd >= 0 { close(fd); fd = -1 }
            }
        }

        /// Force a durable fsync of everything written so far and reset the
        /// group counter. Called at forced barrier points: snapshot start,
        /// daemon shutdown, env switch. Cheap no-op when nothing is unsynced.
        public func barrier() {
            queue.sync { syncNowLocked() }
        }

        /// Append a record, return the number of bytes written (length prefix +
        /// opcode byte + payload). In `.everyRecord` the record is durable on
        /// return; in `.grouped` it is written to the OS file but its fsync may
        /// be deferred (see `FsyncPolicy`).
        @discardableResult
        public func append(opcode: Opcode, payload: Data) throws -> Int {
            if refuseAppendsForGate {
                throw WALError.ioFailure("append refused (gate seam)")
            }
            // A log declares the opcode set a reader may expect. Appending a
            // v2 op to a v1 header would hand that reader a record it counts
            // as unknown — a silent loss of the very mutation this opcode
            // was added to stop losing. Refuse by name instead.
            if fileVersion < DagDBWAL.minimumVersion(for: opcode) {
                throw WALError.opcodeNeedsVersion(
                    opcode: opcode.rawValue,
                    needs: DagDBWAL.minimumVersion(for: opcode),
                    fileVersion: fileVersion)
            }
            var rec = Data()
            appendU32(&rec, UInt32(payload.count))
            rec.append(opcode.rawValue)
            rec.append(payload)
            let total = rec.count

            return try queue.sync {
                try rec.withUnsafeBytes { buf in
                    let w = write(fd, buf.baseAddress, total)
                    if w != total {
                        throw WALError.ioFailure("write record: \(w)/\(total)")
                    }
                }
                switch policy {
                case .everyRecord:
                    _ = fcntl(fd, F_FULLFSYNC)
                    _unsyncedCount = 0
                case .grouped(let n, let ms):
                    _unsyncedCount += 1
                    if _unsyncedCount >= n {
                        syncNowLocked()
                    } else {
                        armTimerLocked(ms: ms)
                    }
                }
                return total
            }
        }

        // MARK: fsync helpers — all callers hold `queue`.

        /// fsync now, reset the counter, disarm the timer. `queue`-confined.
        private func syncNowLocked() {
            if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC) }
            _unsyncedCount = 0
            timer?.cancel()
            timer = nil
        }

        /// Arm the deferred-fsync timer for `ms` if not already armed. The
        /// handler runs on `queue`, so it shares the serial context with
        /// appends — no fd/counter race. `queue`-confined.
        private func armTimerLocked(ms: Int) {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .milliseconds(ms))
            t.setEventHandler { [weak self] in
                guard let self = self else { return }
                self.syncNowLocked()
            }
            timer = t
            t.resume()
        }

        // Convenience one-liners that build the payload.

        @discardableResult
        public func setTruth(node: UInt32, value: UInt8) throws -> Int {
            var d = Data()
            appendU32(&d, node)
            d.append(value)
            return try append(opcode: .setTruth, payload: d)
        }

        @discardableResult
        public func setRank(node: UInt32, value: UInt64) throws -> Int {
            var d = Data()
            appendU32(&d, node)
            appendU64(&d, value)
            return try append(opcode: .setRank, payload: d)
        }

        @discardableResult
        public func setEdgeWeight(node: UInt32, dir: UInt8, value: Float) throws -> Int {
            var d = Data()
            appendU32(&d, node)
            d.append(dir)
            appendU32(&d, value.bitPattern)
            return try append(opcode: .setEdgeWeight, payload: d)
        }

        @discardableResult
        public func setActivation(node: UInt32, value: Int16) throws -> Int {
            var d = Data()
            appendU32(&d, node)
            let u = UInt16(bitPattern: value)
            d.append(UInt8(u & 0xFF))
            d.append(UInt8(u >> 8))
            return try append(opcode: .setActivation, payload: d)
        }

        @discardableResult
        public func setNodeValue(node: UInt32, value: Float) throws -> Int {
            var d = Data()
            appendU32(&d, node)
            appendU32(&d, value.bitPattern)
            return try append(opcode: .setNodeValue, payload: d)
        }

        @discardableResult
        public func setLUT(node: UInt32, lut: UInt64) throws -> Int {
            var d = Data()
            appendU32(&d, node)
            appendU64(&d, lut)
            return try append(opcode: .setLUT, payload: d)
        }

        @discardableResult
        public func checkpoint(epoch: UInt64) throws -> Int {
            var d = Data()
            appendU64(&d, epoch)
            return try append(opcode: .checkpoint, payload: d)
        }

        @discardableResult
        public func connectBack(src: UInt32, dst: UInt32) throws -> Int {
            var d = Data()
            appendU32(&d, src)
            appendU32(&d, dst)
            return try append(opcode: .connectBack, payload: d)
        }

        @discardableResult
        public func clearBackEdges(dst: UInt32) throws -> Int {
            var d = Data()
            appendU32(&d, dst)
            return try append(opcode: .clearBackEdges, payload: d)
        }

        // ── Version 2: combinational edges and bulk installs ──────────────

        /// One combinational edge, by the slot the writer chose. Logging the
        /// slot (rather than re-deriving "first free slot" at replay) keeps
        /// replay independent of the state it starts from.
        @discardableResult
        public func connect(dst: UInt32, slot: UInt8, src: Int32) throws -> Int {
            var d = Data()
            appendU32(&d, dst)
            d.append(slot)
            appendU32(&d, UInt32(bitPattern: src))
            return try append(opcode: .connect, payload: d)
        }

        /// All six combinational slots of `node` reset to -1.
        @discardableResult
        public func clearEdges(node: UInt32) throws -> Int {
            var d = Data()
            appendU32(&d, node)
            return try append(opcode: .clearEdges, payload: d)
        }

        @discardableResult
        public func setRanksBulk(_ ranks: UnsafePointer<UInt64>, count: Int) throws -> Int {
            var d = Data()
            appendU32(&d, UInt32(count))
            d.append(UnsafeBufferPointer(start: ranks, count: count))
            return try append(opcode: .setRanksBulk, payload: d)
        }

        @discardableResult
        public func setLutsBulk(_ luts: UnsafePointer<UInt64>, count: Int) throws -> Int {
            var d = Data()
            appendU32(&d, UInt32(count))
            d.append(UnsafeBufferPointer(start: luts, count: count))
            return try append(opcode: .setLutsBulk, payload: d)
        }

        /// `count` is the NODE count; the vector itself is `count * 6` long.
        @discardableResult
        public func setNeighborsBulk(_ nb: UnsafePointer<Int32>, count: Int) throws -> Int {
            var d = Data()
            appendU32(&d, UInt32(count))
            d.append(UnsafeBufferPointer(start: nb, count: count * 6))
            return try append(opcode: .setNeighborsBulk, payload: d)
        }
    }

    /// The log version an opcode first appeared at.
    static func minimumVersion(for opcode: Opcode) -> UInt32 {
        switch opcode {
        case .connect, .clearEdges, .setRanksBulk, .setLutsBulk, .setNeighborsBulk:
            return versionV2
        default:
            return versionV1
        }
    }

    // MARK: - Replay

    /// Walk the log, apply every record to the engine. Records before the
    /// last CHECKPOINT marker are skipped (they're already in the snapshot).
    /// A truncated tail record is dropped (returns truncatedAtOffset).
    public static func replay(
        engine: DagDBEngine,
        nodeCount: Int,
        path: String,
        twin: TwinState? = nil
    ) throws -> ReplayResult {
        let t0 = Date()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw WALError.ioFailure("file not found: \(path)")
        }
        guard data.count >= headerSize else {
            throw WALError.truncated("shorter than header")
        }
        let m = [UInt8](data[0..<4])
        guard m == magic else { throw WALError.invalidMagic }
        let ver = readU32(data, 4)
        guard ver == versionV1 || ver == versionV2 else {
            throw WALError.unsupportedVersion(ver)
        }
        let fileNC = Int(readU32(data, 8))
        guard fileNC == nodeCount else {
            throw WALError.ioFailure("nodeCount \(fileNC) vs \(nodeCount)")
        }

        // First pass: find the offset of the LAST CHECKPOINT record.
        // A CHECKPOINT payload is exactly 8 bytes. A checkpoint of any other
        // length is a TORN checkpoint: it is not a boundary (treating it as
        // one would push the replay window past the start of the following
        // record and drop it), and the second pass counts it as skipped.
        var lastCheckpointOff: Int? = nil
        var lastCheckpointRecordTotal = 0
        var lastEpoch: UInt64 = 0
        var truncatedAt: Int? = nil
        var off = headerSize
        while off < data.count {
            if off + 5 > data.count {
                truncatedAt = off; break
            }
            let payloadLen = Int(readU32(data, off))
            let recordTotal = 4 + 1 + payloadLen
            if off + recordTotal > data.count {
                truncatedAt = off; break
            }
            let opRaw = data[off + 4]
            if opRaw == Opcode.checkpoint.rawValue && payloadLen == 8 {
                lastCheckpointOff = off
                lastCheckpointRecordTotal = recordTotal
                lastEpoch = readU64(data, off + 5)
            }
            off += recordTotal
        }

        // Second pass: replay records after the last checkpoint (if any).
        // The window starts past the checkpoint record's OWN measured
        // length, never a hardcoded width.
        let startOff = lastCheckpointOff.map { $0 + lastCheckpointRecordTotal } ?? headerSize
        var applied = 0
        var afterCheckpoint = 0
        var skips = SkipReasons()
        off = headerSize
        while off < (truncatedAt ?? data.count) {
            let payloadLen = Int(readU32(data, off))
            let recordTotal = 4 + 1 + payloadLen
            let opRaw = data[off + 4]

            if off >= startOff {
                switch opRaw {
                case Opcode.setTruth.rawValue:
                    guard payloadLen == 5 else { skips.badLength += 1; off += recordTotal; continue }
                    let node = Int(readU32(data, off + 5))
                    let value = data[off + 9]
                    if node >= 0 && node < nodeCount {
                        let p = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
                        p[node] = value
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.setRank.rawValue:
                    // v2 log: the payload is u32 node + u64 rank = 12 bytes,
                    // full stop. A record torn down to 8 or 5 bytes used to be
                    // indistinguishable from a legacy record and was applied as
                    // a real rank write (audit A, finding 30).
                    // v1 log: the legacy widths are genuine — u32 rank = 8,
                    // u8 rank = 5 — and still replay.
                    let node = Int(readU32(data, off + 5))
                    let value: UInt64
                    if payloadLen == 12 {
                        value = readU64(data, off + 9)
                    } else if ver == versionV1 && payloadLen == 8 {
                        value = UInt64(readU32(data, off + 9))
                    } else if ver == versionV1 && payloadLen == 5 {
                        value = UInt64(data[off + 9])
                    } else {
                        skips.badLength += 1; off += recordTotal; continue
                    }
                    if node >= 0 && node < nodeCount {
                        let p = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: nodeCount)
                        p[node] = value
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.setLUT.rawValue:
                    guard payloadLen == 12 else { skips.badLength += 1; off += recordTotal; continue }
                    let node = Int(readU32(data, off + 5))
                    let lut  = readU64(data, off + 9)
                    if node >= 0 && node < nodeCount {
                        let low  = engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
                        let high = engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
                        low[node]  = UInt32(lut & 0xFFFFFFFF)
                        high[node] = UInt32((lut >> 32) & 0xFFFFFFFF)
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.setEdgeWeight.rawValue:
                    // u32 node + u8 dir + f32 value = 9 bytes.
                    guard payloadLen == 9 else { skips.badLength += 1; off += recordTotal; continue }
                    let node = Int(readU32(data, off + 5))
                    let dir = Int(data[off + 9])
                    let bits = readU32(data, off + 10)
                    if node >= 0 && node < nodeCount && dir >= 0 && dir < 6 {
                        let p = engine.edgeWeightsBuf.contents()
                            .bindMemory(to: Float.self, capacity: nodeCount * 6)
                        p[node * 6 + dir] = Float(bitPattern: bits)
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.setActivation.rawValue:
                    // u32 node + i16 value (LE) = 6 bytes.
                    guard payloadLen == 6 else { skips.badLength += 1; off += recordTotal; continue }
                    let node = Int(readU32(data, off + 5))
                    let raw = UInt16(data[off + 9]) | (UInt16(data[off + 10]) << 8)
                    if node >= 0 && node < nodeCount {
                        let p = engine.activationBuf.contents()
                            .bindMemory(to: Int16.self, capacity: nodeCount)
                        p[node] = Int16(bitPattern: raw)
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.setNodeValue.rawValue:
                    // u32 node + f32 value = 8 bytes.
                    guard payloadLen == 8 else { skips.badLength += 1; off += recordTotal; continue }
                    let node = Int(readU32(data, off + 5))
                    let bits = readU32(data, off + 9)
                    if node >= 0 && node < nodeCount {
                        let p = engine.nodeValueBuf.contents()
                            .bindMemory(to: Float.self, capacity: nodeCount)
                        p[node] = Float(bitPattern: bits)
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.connectBack.rawValue:
                    guard payloadLen == 8 else { skips.badLength += 1; off += recordTotal; continue }
                    let src = readU32(data, off + 5)
                    let dst = readU32(data, off + 9)
                    if Int(src) < nodeCount && Int(dst) < nodeCount {
                        // Replay path bypasses validation — the WAL recorded
                        // an event that succeeded at write time. Use the
                        // unchecked form so a transiently combinational
                        // ordering during replay (combinational edge replayed
                        // before the back-edge that validated it away) does
                        // not abort recovery.
                        try engine.addBackEdgeUnchecked(src: src, dst: dst)
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.clearBackEdges.rawValue:
                    guard payloadLen == 4 else { skips.badLength += 1; off += recordTotal; continue }
                    let dst = readU32(data, off + 5)
                    if Int(dst) < nodeCount {
                        try engine.clearBackEdges(toNode: dst)
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.connect.rawValue:
                    // u32 dst + u8 slot + i32 src = 9 bytes.
                    guard payloadLen == 9 else { skips.badLength += 1; off += recordTotal; continue }
                    let dst = Int(readU32(data, off + 5))
                    let slot = Int(data[off + 9])
                    let src = Int32(bitPattern: readU32(data, off + 10))
                    if dst >= 0 && dst < nodeCount && slot >= 0 && slot < 6
                        && src >= -1 && Int(src) < nodeCount {
                        let p = engine.neighborsBuf.contents()
                            .bindMemory(to: Int32.self, capacity: nodeCount * 6)
                        p[dst * 6 + slot] = src
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.clearEdges.rawValue:
                    guard payloadLen == 4 else { skips.badLength += 1; off += recordTotal; continue }
                    let node = Int(readU32(data, off + 5))
                    if node >= 0 && node < nodeCount {
                        let p = engine.neighborsBuf.contents()
                            .bindMemory(to: Int32.self, capacity: nodeCount * 6)
                        for d in 0..<6 { p[node * 6 + d] = -1 }
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.setRanksBulk.rawValue:
                    guard payloadLen >= 4 else { skips.badLength += 1; off += recordTotal; continue }
                    let n = Int(readU32(data, off + 5))
                    guard payloadLen == 4 + n * 8 else {
                        skips.badLength += 1; off += recordTotal; continue
                    }
                    guard n == nodeCount else {
                        skips.outOfRangeIndex += 1; off += recordTotal; continue
                    }
                    let dstPtr = engine.rankBuf.contents()
                        .bindMemory(to: UInt64.self, capacity: nodeCount)
                    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                        memcpy(dstPtr, raw.baseAddress!.advanced(by: off + 9), n * 8)
                    }
                    applied += 1; afterCheckpoint += 1
                case Opcode.setLutsBulk.rawValue:
                    guard payloadLen >= 4 else { skips.badLength += 1; off += recordTotal; continue }
                    let n = Int(readU32(data, off + 5))
                    guard payloadLen == 4 + n * 8 else {
                        skips.badLength += 1; off += recordTotal; continue
                    }
                    guard n == nodeCount else {
                        skips.outOfRangeIndex += 1; off += recordTotal; continue
                    }
                    let low  = engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
                    let high = engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
                    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                        let src = raw.baseAddress!.advanced(by: off + 9)
                        for i in 0..<n {
                            let v = src.advanced(by: i * 8)
                                .loadUnaligned(as: UInt64.self)
                            low[i]  = UInt32(v & 0xFFFF_FFFF)
                            high[i] = UInt32((v >> 32) & 0xFFFF_FFFF)
                        }
                    }
                    applied += 1; afterCheckpoint += 1
                case Opcode.setNeighborsBulk.rawValue:
                    guard payloadLen >= 4 else { skips.badLength += 1; off += recordTotal; continue }
                    let n = Int(readU32(data, off + 5))
                    guard payloadLen == 4 + n * 24 else {
                        skips.badLength += 1; off += recordTotal; continue
                    }
                    guard n == nodeCount else {
                        skips.outOfRangeIndex += 1; off += recordTotal; continue
                    }
                    let dstPtr = engine.neighborsBuf.contents()
                        .bindMemory(to: Int32.self, capacity: nodeCount * 6)
                    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                        memcpy(dstPtr, raw.baseAddress!.advanced(by: off + 9), n * 24)
                    }
                    applied += 1; afterCheckpoint += 1
                case Opcode.twinStreamOpen.rawValue...Opcode.twinHookStep.rawValue:
                    // Twin registry ops (interface phase, 2026-09). `twin == nil` means the
                    // caller isn't restoring twin state at all — walk past
                    // the record without applying or counting it (not a
                    // skip either: nothing was lost, the caller asked for
                    // no twin state). A malformed payload decodes to nil
                    // and counts as a bad length; an `apply` error (a bad
                    // id, an already-open id) counts as out-of-range — the
                    // record names something the registry cannot address.
                    // Neither is fatal: the rest of the log must replay.
                    if let twin = twin {
                        let payloadStart = off + 5
                        let payload = data.subdata(in: payloadStart..<(payloadStart + payloadLen))
                        if let decoded = TwinWALCodec.decode(opcode: opRaw, payload: payload) {
                            do {
                                try twin.apply(decoded)
                                applied += 1; afterCheckpoint += 1
                            } catch {
                                skips.outOfRangeIndex += 1
                            }
                        } else {
                            skips.badLength += 1
                        }
                    }
                case Opcode.checkpoint.rawValue:
                    // A checkpoint of any width but 8 is torn — named here,
                    // and already refused as a boundary in the first pass.
                    if payloadLen != 8 { skips.badLength += 1 }
                default:
                    skips.unknownOpcode += 1
                }
            }
            off += recordTotal
        }

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        return ReplayResult(
            recordsApplied: applied,
            recordsAfterCheckpoint: afterCheckpoint,
            checkpointEpoch: lastEpoch,
            elapsedMs: elapsed,
            truncatedAtOffset: truncatedAt,
            recordsSkipped: skips.total,
            skipReasons: skips,
            fileVersion: ver
        )
    }

    /// Reset the log to just the header (e.g. after a successful snapshot).
    /// Atomic: writes a fresh header to a tmp file, then renames.
    ///
    /// C1e · the decision. `Data.write(options: [.atomic])` renames a fresh
    /// inode over the path, and a live `Appender` holds an `O_APPEND`
    /// descriptor on the OLD inode — it would keep writing to an unlinked
    /// file and every record between the truncate and the appender's
    /// recreation would be lost with no trace (audit A, finding 33).
    ///
    /// Of the two repairs the contract allows — refuse while an appender is
    /// open, or reopen the appender's descriptor atomically — this is the
    /// REFUSAL. `truncate` is a static function with no handle on any
    /// appender: reopening "the appender's descriptor" would mean changing
    /// the signature at every call site to carry one, and it would still
    /// race with an append issued on another thread between the rename and
    /// the reopen. A refusal has no window at all, and the daemon's own
    /// sequence never needs it: a durable snapshot writes a CHECKPOINT into
    /// the live log rather than truncating it.
    public static func truncate(path: String, nodeCount: Int) throws {
        guard !hasOpenAppender(path: path) else {
            throw WALError.appenderOpen(path: path)
        }
        var header = Data()
        header.append(contentsOf: magic)
        appendU32(&header, version)
        appendU32(&header, UInt32(nodeCount))
        appendU32(&header, 0)
        try header.write(to: URL(fileURLWithPath: path), options: [.atomic])
        let fd = open(path, O_RDONLY)
        if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC); close(fd) }
    }

    // MARK: - Byte helpers

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        var v = value
        data.append(Data(bytes: &v, count: 4))
    }

    private static func appendU64(_ data: inout Data, _ value: UInt64) {
        var v = value
        data.append(Data(bytes: &v, count: 8))
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        return UInt32(data[offset])
             | UInt32(data[offset + 1]) << 8
             | UInt32(data[offset + 2]) << 16
             | UInt32(data[offset + 3]) << 24
    }

    private static func readU64(_ data: Data, _ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(data[offset + i]) << (i * 8)
        }
        return v
    }
}
