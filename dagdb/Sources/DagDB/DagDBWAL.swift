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
/// Opcodes and payloads (length = payload byte count, does not include opcode):
///     0x01 SET_TRUTH         u32 node + u8 value                → length = 5
///     0x02 SET_RANK          u32 node + u8 value                → length = 5
///     0x03 SET_LUT           u32 node + u64 lut                 → length = 12
///     0x10 CONNECT_BACK      u32 src  + u32 dst                 → length = 8
///     0x11 CLEAR_BACK_EDGES  u32 dst                            → length = 4
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
    public static let version: UInt32 = 1
    public static let headerSize: Int = 16

    public enum Opcode: UInt8 {
        case setTruth        = 0x01
        case setRank         = 0x02
        case setLUT          = 0x03
        case connectBack     = 0x10
        case clearBackEdges  = 0x11
        case checkpoint      = 0xF0
    }

    public enum WALError: Error, CustomStringConvertible {
        case ioFailure(String)
        case invalidMagic
        case unsupportedVersion(UInt32)
        case truncated(String)

        public var description: String {
            switch self {
            case .ioFailure(let s):           return "io: \(s)"
            case .invalidMagic:               return "invalid magic"
            case .unsupportedVersion(let v):  return "version \(v)"
            case .truncated(let s):           return "truncated: \(s)"
            }
        }
    }

    public struct ReplayResult {
        public let recordsApplied: Int
        public let recordsAfterCheckpoint: Int
        public let checkpointEpoch: UInt64
        public let elapsedMs: Double
        public let truncatedAtOffset: Int?
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
        private var fd: Int32 = -1

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
                guard ver == version else { throw WALError.unsupportedVersion(ver) }
                let fileNC = readU32(data, 8)
                guard fileNC == self.nodeCount else {
                    throw WALError.ioFailure("nodeCount mismatch \(fileNC) vs \(self.nodeCount)")
                }

                self.fd = open(path, O_WRONLY | O_APPEND)
                guard self.fd >= 0 else {
                    throw WALError.ioFailure("open existing: errno=\(errno)")
                }
            }
        }

        deinit {
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
    }

    // MARK: - Replay

    /// Walk the log, apply every record to the engine. Records before the
    /// last CHECKPOINT marker are skipped (they're already in the snapshot).
    /// A truncated tail record is dropped (returns truncatedAtOffset).
    public static func replay(
        engine: DagDBEngine,
        nodeCount: Int,
        path: String
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
        guard ver == version else { throw WALError.unsupportedVersion(ver) }
        let fileNC = Int(readU32(data, 8))
        guard fileNC == nodeCount else {
            throw WALError.ioFailure("nodeCount \(fileNC) vs \(nodeCount)")
        }

        // First pass: find the offset of the LAST CHECKPOINT record.
        // Returns (lastCheckpointOff, checkpointEpoch, truncatedOff?)
        var lastCheckpointOff: Int? = nil
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
            if opRaw == Opcode.checkpoint.rawValue {
                lastCheckpointOff = off
                if payloadLen == 8 {
                    lastEpoch = readU64(data, off + 5)
                }
            }
            off += recordTotal
        }

        // Second pass: replay records after the last checkpoint (if any).
        // If no checkpoint, replay all records from the header.
        let startOff = lastCheckpointOff.map { $0 + 4 + 1 + 8 } ?? headerSize
        var applied = 0
        var afterCheckpoint = 0
        off = headerSize
        while off < (truncatedAt ?? data.count) {
            let payloadLen = Int(readU32(data, off))
            let recordTotal = 4 + 1 + payloadLen
            let opRaw = data[off + 4]

            if off >= startOff {
                switch opRaw {
                case Opcode.setTruth.rawValue:
                    guard payloadLen == 5 else { off += recordTotal; continue }
                    let node = Int(readU32(data, off + 5))
                    let value = data[off + 9]
                    if node >= 0 && node < nodeCount {
                        let p = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
                        p[node] = value
                        applied += 1; afterCheckpoint += 1
                    }
                case Opcode.setRank.rawValue:
                    // v3 payload (2026-04-21): u32 node + u64 rank = 12 bytes.
                    // v2 payload (post-T1):     u32 node + u32 rank =  8 bytes.
                    // v1 payload (pre-T1):      u32 node + u8  rank =  5 bytes. Accept all.
                    let node = Int(readU32(data, off + 5))
                    let value: UInt64
                    if payloadLen == 12 {
                        value = readU64(data, off + 9)
                    } else if payloadLen == 8 {
                        value = UInt64(readU32(data, off + 9))
                    } else if payloadLen == 5 {
                        value = UInt64(data[off + 9])
                    } else {
                        off += recordTotal; continue
                    }
                    if node >= 0 && node < nodeCount {
                        let p = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: nodeCount)
                        p[node] = value
                        applied += 1; afterCheckpoint += 1
                    }
                case Opcode.setLUT.rawValue:
                    guard payloadLen == 12 else { off += recordTotal; continue }
                    let node = Int(readU32(data, off + 5))
                    let lut  = readU64(data, off + 9)
                    if node >= 0 && node < nodeCount {
                        let low  = engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
                        let high = engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
                        low[node]  = UInt32(lut & 0xFFFFFFFF)
                        high[node] = UInt32((lut >> 32) & 0xFFFFFFFF)
                        applied += 1; afterCheckpoint += 1
                    }
                case Opcode.connectBack.rawValue:
                    guard payloadLen == 8 else { off += recordTotal; continue }
                    let src = readU32(data, off + 5)
                    let dst = readU32(data, off + 9)
                    if Int(src) < nodeCount && Int(dst) < nodeCount {
                        // Replay path bypasses validation — the WAL recorded
                        // an event that succeeded at write time. Use the
                        // unchecked form so a transiently combinational
                        // ordering during replay (combinational edge replayed
                        // before the back-edge that validated it away) does
                        // not abort recovery.
                        engine.addBackEdgeUnchecked(src: src, dst: dst)
                        applied += 1; afterCheckpoint += 1
                    }
                case Opcode.clearBackEdges.rawValue:
                    guard payloadLen == 4 else { off += recordTotal; continue }
                    let dst = readU32(data, off + 5)
                    if Int(dst) < nodeCount {
                        engine.clearBackEdges(toNode: dst)
                        applied += 1; afterCheckpoint += 1
                    }
                case Opcode.checkpoint.rawValue:
                    break  // no-op at replay
                default:
                    break  // unknown opcode — skip
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
            truncatedAtOffset: truncatedAt
        )
    }

    /// Reset the log to just the header (e.g. after a successful snapshot).
    /// Atomic: writes a fresh header to a tmp file, then renames.
    public static func truncate(path: String, nodeCount: Int) throws {
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
