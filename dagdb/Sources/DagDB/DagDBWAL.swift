/// DagDBWAL — write-ahead log for DagDB mutations.
///
/// Log-first discipline: every mutating input (setTruth / setRank / setLUT
/// and the rest of the opcode set) is appended to the log and fsync'd
/// BEFORE being applied to engine buffers. On crash, replay the log on top
/// of the last snapshot to recover the INPUTS exactly. Computed state is
/// not logged: TICK, TICK_SYNC, EVAL and TICK UNTIL_STABLE write no record,
/// so tick-computed truth (latched registers included) and the tick counter
/// come back only as far as the last durable snapshot (see
/// docs/wiki/dsl.md, "Ticks are not durable without SAVE"). However,
/// each tick command leaves one advisory TICK_NOTE (0x52, the tick total
/// after it), so a restart can say how many ticks it did not recover.
///
/// Log file format (append-only, little-endian):
///     Header (16 B):  "DAGW" (4) + version u32 + nodeCount u32 + reserved u32
///     Record: length u32 (payload-only) + opcode u8 + payload bytes
///
/// Versions:
///     1 — the opcode set up to 0x11 plus the twin range. SET_RANK payloads
///         of 5 (u8 rank) and 8 (u32 rank) bytes are LEGACY and accepted.
///     2 — adds the combinational-edge and bulk-install opcodes 0x12…0x16,
///         so every mutating input verb the daemon performs is in the log
///         (ticks are computation, not inputs, and are not logged). Under version 2 a SET_RANK
///         payload is 12 bytes or the record is torn: 5 and 8 are no longer
///         a legacy shape to fall back on, they are counted as skipped.
///     3 — adds the ternary opcodes 0x40…0x4A (one opcode per new verb,
///         single and bulk). A version-2 or version-1 file still replays in
///         full; a version-2 log is still appendable for the ops it can
///         describe and refuses a ternary op by name.
///     4 — the slot model: a version-3 log in which an IMPORT_PART /
///         IMPORT_MORTON record may install S1–S3 slots (a duplicate source,
///         a slot self-loop, a rank inversion), which a build before the slot model
///         refuses on replay and then applies every later record over the
///         pre-import graph (a mixture). No other record changes meaning and
///         no record layout changes. Content-gated: a fresh log is still
///         stamped 3; the first import whose slots hold S1–S3 rewrites the
///         header's version field from 3 to 4 in place (4 bytes at offset 4,
///         fsynced) before its record(s). An older build refuses a v4 log by
///         name and applies none of it; a log that never took such an import
///         stays v3, readable by both. A v1 or v2 log never reaches this
///         (IMPORT needs version 3).
///     5 — tick notes:
///         a version-4 log that may carry TICK_NOTE records (0x52). No other
///         record changes meaning. On demand: the first TICK_NOTE rewrites
///         the header's version field to 5 in place (as for version 4, fsynced,
///         before the record); a log with no tick command keeps its version.
///         A version-2, -3 or -4 log is upgraded; a version-1 log is not (its
///         legacy SET_RANK widths are read only under version 1) and takes
///         no note. An older build refuses a v5 log by name.
///     6 — hook sweeps: a version-5 log that may carry TWIN_HOOK_SWEEP records (0x31).
///         No other record changes meaning. On demand, as v5: the first sweep
///         record (a bound hook's HOOK CLOSE, or the one sweep after a recovery
///         that found ids an older log or snapshot left) rewrites the
///         header's version field to 6 in place, fsynced, before the record; a
///         log that never takes one keeps its version. A version-2 to -5 log
///         is upgraded; a version-1 log is not (the same reason as for version 5), and the
///         verb that needs the record refuses by name. An older build refuses
///         a v6 log by name (`unsupportedVersion(6)`).
///     A version above 6 is refused by name.
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
///     Twin registry ops — one opcode per `TwinOp` case, payload
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
///     0x31 TWIN_HOOK_SWEEP     TwinOp.hookSweep (version 6)
///     A twin op with a malformed payload (bad length, bad UTF-8) is
///     skipped on replay, never fatal. `replay(twin:)` with `twin == nil`
///     skips all twin-range opcodes entirely (the record is still walked,
///     just not applied).
///
///     Version 3 — the native ternary tick:
///     0x40 SET_MODE          u32 node + u8 mode                 → length = 5
///     0x41 SET_TTABLE_ID     u32 node + u16 tid                 → length = 6
///     0x42 SET_THRESH        u32 node + f32 lo + f32 hi         → length = 12
///     0x43 SET_TRIT          u32 node + i8 trit                 → length = 5
///     0x44 TTABLE_DEFINE     u32 tid + u8[729]                  → length = 733
///     0x45 TTABLE_PRESET     u32 tid + u8 preset code + u8 k    → length = 6
///     0x46 TTABLE_COMPOSE    u32 dst + u32 tid + u8[729]        → length = 737
///          The ternary COMPOSE: the resulting table appended at `tid` and
///          `dst`'s table id set to it, in one record.
///     0x47 SET_MODES_BULK    u32 n + u8[n]                      → 4 + n
///     0x48 SET_TTABLE_IDS_BULK u32 n + u16[n]                   → 4 + 2n
///     0x49 SET_THRESH_BULK   u32 n + f32[2n] (lo, hi pairs)     → 4 + 8n
///     0x4A TTABLE_BULK       u32 first + u32 count + u8[729·count] → 8 + 729·count
///     A ternary record whose values are refused
///     is skipped, counted under out_of_range, and named in
///     `ReplayResult.refusals`. So are a
///     non-finite SET_WEIGHT (0x04) or SET_VALUE (0x06), a SET_TRUTH (0x01)
///     of 3 or more on a ternary node, and a CONNECT_BACK (0x10) into a
///     ternary node — live rules that read only the record and logged state
///     (the node's mode). A rule that reads tick-computed truth (SET MODE on
///     a node whose truth byte is ≥ 3) also refuses on replay, and may refuse
///     a write that was legal live.
///
///     IMPORT MORTON, logged (version 3 logs; a reader
///     that predates these opcodes counts them as unknown, never silently):
///     0x4B IMPORT_PART       u32 k + k × (u8 fileId + u64 offset + u32 len + u8[len])
///     0x4C IMPORT_MORTON     u16 dirLen + u8[dirLen] dir + u8 m + m × (u8 fileId + u64 size)
///                            + u32 k + k × (u8 fileId + u64 offset + u32 len + u8[len])
///          The bytes of every file the import read (fileId = index in
///          `DagDBSnapshot.mortonImportFileNames`), as read, so the log alone
///          carries the import: the directory may be gone at replay. An
///          import that fits one record (`importChunkBytes`, 2 GiB by
///          default) is one IMPORT_MORTON record; a larger one puts its first
///          chunks in IMPORT_PART records and its manifest (the m files and
///          their sizes) and last chunks in the closing IMPORT_MORTON. Replay
///          stages the parts and runs the import — the daemon's own code, its
///          every check — at the closing record; parts with no closing record
///          (a torn import) are not applied and are named in `refusals`.
///
///     The bulk verbs, one record per bulk (version 3
///     logs; a reader that predates them counts them as unknown):
///     0x4D CONNECT_BACK_BULK u32 k + k × (u32 src + u32 dst)    → 4 + 8k
///     0x4E SET_TRUTH_BULK    u32 k + k × (u32 node + u8 value)  → 4 + 5k
///          The entries in file order, as the daemon accepted them: every
///          entry passed the single verb's checks before the record was
///          written. Replay applies the record whole or not at all: an entry
///          its single record would refuse on replay (an index out of range,
///          a ternary register destination, SET TRUTH ≥ 3 on a ternary node)
///          refuses the record, named in `refusals`, nothing applied.
///
///     SET_LUTS by selection, one record per verb (version 3
///     logs; a reader that predates it counts it as unknown):
///     0x4F SET_LUTS          u8 selector (0 NODES, 1 RANK) + u64 lo + u64 hi
///                            + u8 op: 0 FILL + u64 value               → 26
///                                     1 MAP + u64 mask + u8 p + p × (u64 from + u64 to) → 27 + 16p
///          A record is 31 bytes for FILL and 32 + 16p for a MAP of p pairs
///          (u32 length + opcode + payload). Replay checks the verb's own rule
///          (`DagDBEngine.setLutsRefusal`) against the replayed node count —
///          a refused record (a NODES selection past the lane, a bad pair) is
///          skipped, counted under out_of_range and named — and runs the
///          engine's own function on the CPU twin, every rank selection over
///          the rank lane (replay's rank writes do not mark the per-rank lists
///          stale): the same bytes.
///
///     SET_TRUTH … FILL by selection, one record per verb
///     (version 3 logs; a reader that predates it counts it as unknown):
///     0x50 SET_TRUTH_FILL    u8 selector (0 NODES, 1 RANK) + u64 lo + u64 hi
///                            + u8 value                                → 18
///          A record is 23 bytes (u32 length + opcode + payload). Replay checks
///          the verb's own rule (`DagDBEngine.setTruthFillRefusal`) against the
///          replayed node count and the replayed graph's ternary nodes — a
///          refused record (a NODES selection past the lane; a value ≥ 3 once
///          the graph holds a ternary node) is skipped, counted under
///          out_of_range and named — and runs the engine's own function, every
///          rank selection over the rank lane: the same bytes.
///
///     0x51 SNAPSHOT_BIND     u64 epoch (the tick count) + u8[32] the
///                            SHA-256 of the snapshot file      → length = 40
///          A durable snapshot (SAVE, the
///          autosave, a loader's rebase) appends and fsyncs this record AFTER
///          its tmp file is written and fsynced and BEFORE the rename that
///          makes the file the snapshot; the digest is of the file's bytes.
///          So the record's position is the WAL position the snapshot
///          contains: every record before it is in the file, none after it
///          is (the daemon runs one command at a time). Recovery hands
///          `replay` the digest of the snapshot it loaded; the LAST bind
///          record carrying that digest starts the replay window, whatever
///          checkpoints exist — a snapshot whose checkpoint never landed (a
///          kill between the rename and the checkpoint's fsync, or a failed
///          checkpoint append) is still replayed from its own position, and
///          a snapshot older than a later checkpoint gets the records since
///          it. No bind record with that digest (a log or snapshot from
///          before bind records existed, a snapshot written without a WAL, another log):
///          the last-checkpoint rule below, unchanged. Replay applies
///          nothing for the record. Allowed at every log version: it is a
///          marker, not a mutation, so a reader that predates it loses
///          nothing by counting it as unknown.
///
///     0x52 TICK_NOTE         u64 the daemon's tick total        → length = 8
///          Version 5 logs. Appended once after each
///          tick-family command that ran (TICK, TICK_SYNC, TICK UNTIL_STABLE,
///          EVAL), carrying the tick total it left. Advisory: replay applies
///          nothing for it and changes no state; it only remembers the
///          highest total among the window's notes and the last note before
///          it, which recovery sets against the loaded
///          snapshot's tick count (`ReplayResult.tickNoteWindowMax`,
///          `tickNote`). In a log below version 5
///          the opcode is counted unknown, as before. Written UNSYNCED:
///          it reaches the disk with the next synced
///          append, a SAVE or a checkpoint (`barrier`). A kill -9 loses none
///          (the kernel holds the write); a power loss can lose the latest.
///
///     0x53 COUNTER_DROP      u64 the tick counter after the drop → length = 8
///          Version 5 logs. Advisory, unsynced
///          like TICK_NOTE, never applied: written when the daemon's tick
///          counter changes within a life, up or down, by
///          anything but a tick and without a successful durable rebase (a
///          LOAD or LOAD JSON whose rebase failed, or a loader with no
///          startup snapshot to rebase to). The window's notes then no
///          longer measure ticks against the recovered count, so recovery
///          reports the tick history unknown (`ReplayResult.counterDropsInWindow`).
///
///     0xF0 CHECKPOINT        u64 epoch                          → length = 8
///
/// A CHECKPOINT marks the boundary at which the engine state was snapshotted
/// to disk. On replay, records before the LAST checkpoint may be discarded;
/// records after must be replayed. The checkpoint is the
/// fallback for a snapshot with no bind record (above); with one, it is an
/// optimisation older readers rely on.
///
/// Each record's length prefix is what lets the replay code detect a
/// truncated tail: if the declared length doesn't fit in the remaining file
/// bytes, the record is dropped (interpreted as a crash mid-append).
/// Such bytes are only ever the TAIL. The
/// appender keeps the log ending at a record boundary: a write that fails
/// part-way cuts the log back to the record's start (an import's records
/// back to its first), a failed cut refuses every later append, and opening
/// a log cuts a tail a crash left (`Appender.tornTailCut`, `wholeEnd`).
/// In older builds the next record was appended inside the torn one's declared
/// length and replay walked the rest misaligned.

import Foundation
import CryptoKit

public enum DagDBWAL {

    public static let magic: [UInt8] = [0x44, 0x41, 0x47, 0x57]  // "DAGW"
    /// The opcode set before the combinational-edge and bulk-install ops.
    public static let versionV1: UInt32 = 1
    /// Adds 0x12…0x16 and makes the 12-byte SET_RANK payload the only one.
    public static let versionV2: UInt32 = 2
    /// Adds the ternary opcodes 0x40…0x4A.
    public static let versionV3: UInt32 = 3
    /// A v3 log whose import records may install S1–S3.
    /// Never stamped on a fresh log; an existing v3 log is upgraded in place
    /// by the first import that needs it (`Appender.importMorton`).
    public static let versionV4: UInt32 = 4
    /// A v4 log that may carry TICK_NOTE records. Never
    /// stamped on a fresh log; the first note upgrades a v2–v4 log in place
    /// (`Appender.tickNote`).
    public static let versionV5: UInt32 = 5
    /// A v5 log that may carry TWIN_HOOK_SWEEP records. Never
    /// stamped on a fresh log; the first sweep record upgrades a v2–v5 log in
    /// place (`Appender.twins`).
    public static let versionV6: UInt32 = 6
    /// The version a freshly created log is stamped with.
    public static let version: UInt32 = versionV3
    /// Every version this build reads and appends to.
    static func isReadable(_ v: UInt32) -> Bool { v >= versionV1 && v <= versionV6 }
    public static let headerSize: Int = 16
    /// The most one write(2) is asked to carry: 1 GiB, under INT_MAX.
    static let maxWriteChunk = 1 << 30
    /// The most file bytes one import record carries.
    public static let defaultImportChunkBytes = 1 << 31
    /// Settable for tests, so a small graph exercises the split.
    static var importChunkBytes = defaultImportChunkBytes

    public enum Opcode: UInt8 {
        case setTruth        = 0x01
        case setRank         = 0x02
        case setLUT          = 0x03
        case setEdgeWeight   = 0x04  // u32 node + u8 dir + f32 value = 9 B
        case setActivation   = 0x05  // u32 node + i16 value = 6 B
        case setNodeValue    = 0x06  // u32 node + f32 value = 8 B
        case connectBack     = 0x10
        case clearBackEdges  = 0x11
        // Version 2 — the combinational-edge writes that used to bypass the
        // log entirely.
        case connect          = 0x12  // u32 dst + u8 slot + i32 src = 9 B
        case clearEdges       = 0x13  // u32 node = 4 B
        case setRanksBulk     = 0x14  // u32 n + u64[n]
        case setLutsBulk      = 0x15  // u32 n + u64[n]
        case setNeighborsBulk = 0x16  // u32 n + i32[n*6]
        // Twin registry ops — payload via TwinWALCodec, one per
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
        case twinHookSweep    = 0x31  // TwinOp.hookSweep (version 6)
        // Version 3 — the native ternary tick.
        case setMode          = 0x40  // u32 node + u8 mode = 5 B
        case setTTableId      = 0x41  // u32 node + u16 tid = 6 B
        case setThresh        = 0x42  // u32 node + f32 lo + f32 hi = 12 B
        case setTrit          = 0x43  // u32 node + i8 trit = 5 B
        case ttableDefine     = 0x44  // u32 tid + u8[729]
        case ttablePreset     = 0x45  // u32 tid + u8 code + u8 k
        case ttableCompose    = 0x46  // u32 dst + u32 tid + u8[729]
        case setModesBulk     = 0x47  // u32 n + u8[n]
        case setTTableIdsBulk = 0x48  // u32 n + u16[n]
        case setThreshBulk    = 0x49  // u32 n + f32[2n]
        case ttableBulk       = 0x4A  // u32 first + u32 count + u8[729·count]
        // IMPORT MORTON's bytes (see the header comment).
        case importPart       = 0x4B
        case importMorton     = 0x4C
        // The bulk verbs: one record per bulk.
        case connectBackBulk  = 0x4D  // u32 k + k × (u32 src + u32 dst)
        case setTruthBulk     = 0x4E  // u32 k + k × (u32 node + u8 value)
        // SET_LUTS by selection, one record per verb.
        case setLuts          = 0x4F  // selector, lo, hi, op, value | mask + pairs
        // SET_TRUTH … FILL by selection, one record per verb.
        case setTruthFill     = 0x50  // u8 selector + u64 lo + u64 hi + u8 value
        // The snapshot's own WAL position (see the header comment).
        case snapshotBind     = 0x51  // u64 epoch + u8[32] SHA-256 of the snapshot file
        // Advisory, version 5 (see the header comment).
        case tickNote         = 0x52  // u64 tick total
        case counterDrop      = 0x53  // u64 tick counter after an in-life drop
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
        /// open. See the note on `truncate`.
        case appenderOpen(path: String)
        /// A ternary value the ternary rules refuse, offered to an appender.
        case refused(String)
        /// A record this log's replay would refuse or drop (over a decode-side limit, or a shape
        /// its decoder does not read), refused by name before a byte is written.
        case recordRefused(String)
        /// The caller's admission refused what replay was about to read or build (its
        /// reply line, verbatim); the replay stops there.
        case overBudget(String)

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
            case .refused(let why):
                return "ternary: \(why)"
            case .recordRefused(let why):
                return "\(why); refused before a byte was written, nothing changed"
            case .overBudget(let line):
                return line
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
        /// The log header's version. 1 for a legacy log, 2 for a v2 log, 3 for
        /// a current one.
        public let fileVersion: UInt32
        /// Ternary records refused by value, named. Each
        /// one is also counted under `skipReasons.outOfRangeIndex`.
        public let refusals: [String]
        /// The offset of the SNAPSHOT_BIND record that started
        /// the replay window (the last one carrying the loaded snapshot's
        /// digest), or nil when the window came from the last checkpoint.
        /// `recordsAfterCheckpoint` then counts the records applied after it.
        public let boundAtOffset: Int?
        /// That record's epoch (the tick count it was written at), or nil.
        public let boundEpoch: UInt64?
        /// Well-formed SNAPSHOT_BIND records anywhere in the log.
        public let bindRecords: Int
        /// Records applied as logged that a current daemon
        /// would refuse live, named — an older SET_NEIGHBORS_BULK record
        /// that gave a register a slot (S4). Not skips, not refusals.
        public var warnings: [String] = []
        /// The last well-formed TICK_NOTE in the log (its
        /// offset and the tick total it carries), or nil: a log below
        /// version 5, or a v5 log holding none.
        public var tickNote: (offset: Int, total: UInt64)? = nil
        /// The HIGHEST total among the
        /// well-formed notes inside the replay window, or nil when the window
        /// holds none. A lower later note (a `TICK 0` after a restart) never
        /// hides a higher one.
        public var tickNoteWindowMax: UInt64? = nil
        /// Well-formed COUNTER_DROP records
        /// inside the replay window.
        public var counterDropsInWindow: Int = 0
        /// The first offset the replay window covered (the
        /// header's end for a whole-log replay).
        public var windowStart: Int = DagDBWAL.headerSize
        /// When the caller asked
        /// (`hashAt`), the version-blanked SHA-256 of the log's first `o`
        /// bytes for each asked offset `o` within the valid log, and the
        /// running hash's state at the valid end (`hashedLength`), computed
        /// from the bytes replay already holds: no second read of the log.
        public var prefixDigests: [Int: String] = [:]
        public var hashState: SHA256? = nil
        public var hashedLength: Int = 0
        /// The CLOCK ADVANCE records replayed
        /// by the older rule, named (offset, clock, the id it stopped at).
        /// Each changed state, so each is counted in `recordsApplied` and here,
        /// never under `skipReasons`.
        public var preHOOK1Stops: [String] = []
        /// What the replay found of the log, for the appender (its facts, not its bytes).
        public var found: FoundLog? = nil
    }

    // MARK: - Open-appender registry

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

    /// fsync policy for the appender.
    /// - `.everyRecord` (default): fsync with F_FULLFSYNC after every record —
    ///   byte-identical, durability-identical to the appender before group
    ///   commit existed. A crash
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
    /// unsynced-record counter.
    public final class Appender {
        public let path: String
        public let nodeCount: UInt32
        public let policy: FsyncPolicy
        /// The version stamped in THIS file's header. A fresh log is
        /// `DagDBWAL.version`; an existing one keeps whatever it declared,
        /// and `append` refuses an opcode that version cannot describe.
        /// A v3 log becomes v4 in place when an import installing
        /// S1–S3 is appended (`importMorton`).
        public private(set) var fileVersion: UInt32
        private var fd: Int32 = -1
        /// Set once the path is in the open-appender registry, so a throw
        /// late in `init` cannot decrement another appender's entry.
        private var registered: Bool = false

        /// Test seam. When true, every `append` refuses instead of
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

        /// What opening the log cut from its end — a record a
        /// crash left unfinished there (its declared length runs past the
        /// file's end), or an import's IMPORT_PART records without their
        /// closing IMPORT_MORTON — or nil when the log ended at a record
        /// boundary. Replay never applied those bytes (it drops a cut record
        /// and refuses unclosed parts), so cutting them changes no recovered
        /// state; left in place, the next record would land inside them.
        public private(set) var tornTailCut: (offset: Int, bytes: Int, why: String)? = nil

        /// Set when a failed append's bytes could not be cut
        /// back off the log. Every later append refuses with it, so no record
        /// is ever written after a torn one. `queue`-confined.
        private var poisoned: String? = nil

        /// Test seam: the cut-back after a failed write fails
        /// (as if `ftruncate` had), so the poisoned path can be gated. Never
        /// set outside a test.
        internal var cutBackFailsForTesting: Bool = false

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

        /// A running SHA-256 over the log's
        /// bytes (the header's version field fed as zeros: the version is rewritten in
        /// place), advanced only through the offset the last fsync made
        /// durable (`hashedLength`). Records written but not yet synced wait in
        /// `pendingRecords` (their own Data, no copy) and are fed at the sync;
        /// a cut-back drops them. A seal finalizes a COPY of the state: no read
        /// of the log, no buffer of its size. `queue`-confined.
        private var runHash = SHA256()
        private var hashedLength = 0
        private var pendingRecords: [(start: Int, pieces: [Data])] = []

        /// The log's canonical path (inside the root, no link in it); every open of it uses
        /// O_NOFOLLOW_ANY. `path` keeps the caller's spelling (the registry and the messages).
        public let openPath: String

        /// `found` — the log's bytes as startup recovery's replay read them (one read at boot,
        /// shared; used when the file is still that file: same device, inode and size), else it is read here,
        /// once, through the read helper. At open the log found is F_FULLFSYNC'd, and a failure refuses the
        /// open (the daemon then refuses to start): the appender cannot know what of it is durable.
        public init(path: String, nodeCount: Int,
                    policy: FsyncPolicy = .everyRecord,
                    prefixHash: (length: Int, state: SHA256)? = nil,
                    found: FoundLog? = nil) throws {
            self.path = path
            do { self.openPath = try DaemonFile.forWrite(path) }
            catch { throw WALError.ioFailure("open: \(Reply.errorWords(error))") }
            self.nodeCount = UInt32(nodeCount)
            // Degrade a nonsensical group config to per-record rather than
            // leaving durability unbounded.
            switch policy {
            case .grouped(let n, let ms) where n <= 0 || ms <= 0:
                self.policy = .everyRecord
            default:
                self.policy = policy
            }

            // Opened without blocking, no link followed, a regular file (a FIFO, a directory or
            // a link at DAGDB_WAL is refused by name; an earlier createFile and open followed or replaced it).
            var st = stat()
            let exists = lstat(openPath, &st) == 0
            if !exists || ((st.st_mode & S_IFMT) == S_IFREG && st.st_size == 0) {
                // A new log, or one a crash left with no header (its create and its header write are two
                // steps): the header is written.
                self.fileVersion = DagDBWAL.version
                do { self.fd = try DaemonFile.openForWrite(openPath, create: true, append: true, mode: 0o644, own: true) }
                catch { throw WALError.ioFailure("open create: \(Reply.errorWords(error))") }
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
                // A header whose sync fails refuses the open (the daemon does not start).
                guard Self.fullSync(self.fd, atOpen: true) else {
                    let e = errno
                    close(self.fd); self.fd = -1
                    throw WALError.ioFailure("F_FULLFSYNC of the new log's header failed (errno \(e)); refusing to append to a log whose durability is unknown")
                }
                Self.feedBlanked(&runHash, header, at: 0)
                hashedLength = header.count
            } else {
                // The descriptor first (a regular file, no link followed), then what the log holds:
                // the replay's facts when it is this same file, else a scan through the read helper.
                do { self.fd = try DaemonFile.openForWrite(openPath, create: false, append: true, own: true) }
                catch { throw WALError.ioFailure("open existing: \(Reply.errorWords(error))") }
                var fst = stat()
                _ = fstat(self.fd, &fst)
                // The log opened must be the file the replay read (its device and
                // inode, from the fstat of the descriptor the replay read): a log swapped in between is refused,
                // never appended to unreplayed (an earlier build read the new file and went on).
                if let f = found, f.device != UInt64(fst.st_dev) || f.inode != UInt64(fst.st_ino) {
                    close(self.fd); self.fd = -1
                    throw WALError.ioFailure("open existing: '\(openPath)' is not the file the replay read (device \(f.device)"
                        + " inode \(f.inode) replayed, device \(fst.st_dev) inode \(fst.st_ino) opened): the log was replaced"
                        + " between the replay and the append; refusing to append to a log this start did not replay")
                }
                // The log's facts, never its bytes: the replay's scan when this is the file it
                // read (same device, inode and size), else one streaming scan here, through a bounded buffer
                // (an earlier build held the whole log: the replay's copy, or a read of its own).
                let info: (size: Int, version: UInt32, nodeCount: UInt32, end: Int, why: String)
                if let f = found, f.device == UInt64(fst.st_dev), f.inode == UInt64(fst.st_ino), f.size == Int(fst.st_size) {
                    info = (f.size, f.version, f.nodeCount, f.wholeEnd, f.wholeWhy)
                } else {
                    do {
                        let r = try DaemonFile.Reader(openPath)
                        let sc = try DagDBWAL.scanLog(r, hashAt: nil, chunk: DagDBWAL.replayWindowBytes)
                        try r.finish(whole: false)
                        info = (sc.size, sc.version, sc.nodeCount, sc.wholeEnd, sc.wholeWhy)
                    } catch let e as WALError {
                        close(self.fd); self.fd = -1
                        if case .truncated = e { throw WALError.truncated("header") }
                        throw e
                    } catch {
                        close(self.fd); self.fd = -1; throw WALError.ioFailure("read: \(Reply.errorWords(error))")
                    }
                }
                // A v1 log is still appendable — its opcodes are a subset.
                // Anything past the version this build writes is refused by
                // name rather than appended to blind.
                self.fileVersion = info.version
                guard info.nodeCount == self.nodeCount else {
                    close(self.fd); self.fd = -1
                    throw WALError.ioFailure("nodeCount mismatch \(info.nodeCount) vs \(self.nodeCount)")
                }
                // The log must end at a record boundary before
                // the first append (see `wholeEnd`).
                let end = info.end
                if end < info.size {
                    guard ftruncate(self.fd, off_t(end)) == 0 else {
                        let e = errno
                        close(self.fd); self.fd = -1
                        throw WALError.ioFailure("the log ends in \(info.size - end) byte(s) replay does not apply (\(info.why)) and they could not be cut (ftruncate errno=\(e)); refusing to append after them")
                    }
                    self.tornTailCut = (end, info.size - end, info.why)
                }
                // The log as found, made durable before anything is counted as
                // durable or appended; a failure refuses the open (an earlier reopened appender counted
                // the whole file durable whether or not its sync held).
                guard Self.fullSync(self.fd, atOpen: true) else {
                    let e = errno
                    close(self.fd); self.fd = -1
                    throw WALError.ioFailure("F_FULLFSYNC of the log found at open failed (errno \(e)); the daemon cannot know which of its bytes are durable: refusing to append to it")
                }
                // The running hash over the
                // log as opened; recovery's replay hands its state over (one
                // pass at boot), else it is computed here by one streaming read of the log's first `end` bytes.
                if let ph = prefixHash, ph.length == end {
                    runHash = ph.state
                } else {
                    do {
                        let r = try DaemonFile.Reader(openPath)
                        var at = 0
                        while at < min(end, r.size) {
                            let n = min(DagDBWAL.replayWindowBytes, min(end, r.size) - at)
                            Self.feedBlanked(&runHash, try r.readAt(at, n), at: at)
                            at += n
                        }
                        try r.finish(whole: false)
                    } catch {
                        close(self.fd); self.fd = -1; throw WALError.ioFailure("read: \(Reply.errorWords(error))")
                    }
                }
                hashedLength = end
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

        /// Feed `bytes`, which sit at file
        /// offset `at`, with the header's version field (offsets 4–7) as zeros.
        static func feedBlanked(_ h: inout SHA256, _ bytes: Data, at: Int) {
            bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var i = 0
                while i < raw.count {
                    let off = at + i
                    if off >= 4 && off < 8 {
                        let n = min(8 - off, raw.count - i)
                        h.update(data: Data(count: n)); i += n
                    } else {
                        let n = off < 4 ? min(4 - off, raw.count - i) : raw.count - i
                        h.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[i..<(i + n)])); i += n
                    }
                }
            }
        }

        /// The records written since the last sync are durable now: fed to the
        /// running hash. `queue`-confined.
        private func markDurableLocked() {
            for r in pendingRecords {
                if r.start != hashedLength { rehashFromFileLocked(through: r.start) }   // never expected: a gap
                var at = r.start
                for p in r.pieces { Self.feedBlanked(&runHash, p, at: at); at += p.count }
                hashedLength = at
            }
            pendingRecords = []
        }

        /// The log's durable length and the version-blanked SHA-256 of that
        /// prefix, from a copy of the running state.
        public func durableDigest() -> (length: Int, sha256: String) {
            queue.sync {
                (hashedLength, runHash.finalize().map { String(format: "%02x", $0) }.joined())
            }
        }

        /// The old way, kept for the gate's control: the whole log read and
        /// hashed at its current length (O(log) time and memory).
        public func wholeLogDigestForControl() -> (length: Int, sha256: String) {
            queue.sync {
                syncNowLocked()
                let d = (try? DaemonFile.read(openPath)) ?? Data()
                var h = SHA256()
                Self.feedBlanked(&h, d, at: 0)
                return (d.count, h.finalize().map { String(format: "%02x", $0) }.joined())
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
            try append(opcode: opcode, payload: payload, sync: true)
        }

        /// The typed appenders below write through here. A record whose SHAPE replay
        /// would not apply (`recordShapeRefusal`: its length against the opcode's layout, a bulk's count against
        /// this log's node count, a SET_LUTS payload the decoder does not read) is refused by name before a byte
        /// is written. `append(opcode:payload:)` itself stays the raw writer (a test crafts torn records with it);
        /// it refuses only what the u32 length field cannot carry.
        @discardableResult
        func typed(_ opcode: Opcode, _ payload: Data, sync: Bool = true) throws -> Int {
            if let why = DagDBWAL.recordShapeRefusal(opcode: opcode, payload: payload, nodeCount: Int(nodeCount)) {
                throw WALError.recordRefused(String(format: "opcode 0x%02x: ", opcode.rawValue) + why)
            }
            return try append(opcode: opcode, payload: payload, sync: sync)
        }

        /// `sync: false`: the record is written to the OS file
        /// and counted unsynced, in every policy; the caller makes it durable
        /// with `barrier()`. Used by the durable snapshot's bind record and
        /// checkpoint, so each step boundary (written / fsynced) exists.
        @discardableResult
        public func append(opcode: Opcode, payload: Data, sync: Bool) throws -> Int {
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
            // The u32 length field replay reads; above it `UInt32(_:)` would trap.
            guard payload.count <= Int(UInt32.max) else {
                throw WALError.recordRefused(String(format: "opcode 0x%02x: ", opcode.rawValue)
                    + "the record's payload is \(payload.count) bytes, above the \(UInt32.max) its u32 length field holds")
            }
            var rec = Data()
            appendU32(&rec, UInt32(payload.count))
            rec.append(opcode.rawValue)
            rec.append(payload)
            let total = rec.count

            return try queue.sync {
                try writeRecordLocked([rec], total: total)
                if !sync {
                    _unsyncedCount += 1
                    return total
                }
                switch policy {
                case .everyRecord:
                    let synced = Self.fullSync(fd)
                    _unsyncedCount = 0
                    if synced { markDurableLocked() }
                    else { throw poisonAfterFailedSyncLocked(cutBackTo: pendingRecords.last?.start) }
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

        /// One record whose payload is `pieces` concatenated, written piece by
        /// piece (no copy of the payload): the import records
        /// carry whole lanes. Same version check and fsync policy as `append`.
        @discardableResult
        public func append(opcode: Opcode, pieces: [Data]) throws -> Int {
            if refuseAppendsForGate {
                throw WALError.ioFailure("append refused (gate seam)")
            }
            if fileVersion < DagDBWAL.minimumVersion(for: opcode) {
                throw WALError.opcodeNeedsVersion(
                    opcode: opcode.rawValue,
                    needs: DagDBWAL.minimumVersion(for: opcode),
                    fileVersion: fileVersion)
            }
            let payloadLen = pieces.reduce(0) { $0 + $1.count }
            guard payloadLen <= Int(UInt32.max) else {
                throw WALError.ioFailure("record payload \(payloadLen) bytes exceeds the u32 length field")
            }
            var head = Data()
            appendU32(&head, UInt32(payloadLen))
            head.append(opcode.rawValue)
            let all = [head] + pieces
            let total = head.count + payloadLen
            return try queue.sync {
                try writeRecordLocked(all, total: total)
                switch policy {
                case .everyRecord:
                    let synced = Self.fullSync(fd)
                    _unsyncedCount = 0
                    if synced { markDurableLocked() }
                    else { throw poisonAfterFailedSyncLocked(cutBackTo: pendingRecords.last?.start) }
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

        /// IMPORT MORTON, logged: every file the import
        /// read, its bytes as read. Returns the number of records written (1
        /// unless the files exceed `importChunkBytes`). Call it after the
        /// import's checks and before its commit.
        ///
        /// `slotModel` says whether the import's slots hold
        /// S1–S3 (the daemon passes what its persistence pass found; nil =
        /// look at `rank.bin` and `neighbors.bin` here). When they do and the
        /// log is v3, the header's version is rewritten to 4 and fsynced
        /// BEFORE the first record; a header that cannot be written refuses
        /// the import (nothing appended). A crash between the two leaves a v4
        /// log holding only v3 records: this build replays it, an older build
        /// refuses it by version.
        @discardableResult
        public func importMorton(dir: String, files: [DagDBSnapshot.MortonFile], slotModel: Bool? = nil) throws -> Int {
            var upgradedFrom: UInt32? = nil
            if fileVersion == DagDBWAL.versionV3,
               slotModel ?? (DagDBWAL.slotModelShape(files: files, nodeCount: Int(nodeCount)) != nil) {
                try upgradeHeader(to: DagDBWAL.versionV4)
                upgradedFrom = DagDBWAL.versionV3
            }
            // An import whose records do not land
            // puts the header's version back, so the refusal changed no byte.
            return try puttingHeaderBack(upgradedFrom) {
                try importMortonRecords(dir: dir, files: files)
            }
        }

        private func importMortonRecords(dir: String, files: [DagDBSnapshot.MortonFile]) throws -> Int {
            let names = DagDBSnapshot.mortonImportFileNames
            var manifest = Data()
            let dirBytes = Data(dir.utf8)
            guard dirBytes.count <= Int(UInt16.max) else {
                throw WALError.ioFailure("import directory path is \(dirBytes.count) bytes, more than \(UInt16.max)")
            }
            appendU16(&manifest, UInt16(dirBytes.count))
            manifest.append(dirBytes)
            // The manifest's u8 file count, as replay reads it.
            guard files.count <= Int(UInt8.max) else {
                throw WALError.recordRefused("IMPORT_MORTON: \(files.count) files, above the \(UInt8.max) its u8 count holds")
            }
            manifest.append(UInt8(files.count))
            var ids: [UInt8] = []
            for f in files {
                guard let id = names.firstIndex(of: f.name) else {
                    throw WALError.ioFailure("import file \(f.name) has no WAL id")
                }
                ids.append(UInt8(id))
                manifest.append(UInt8(id))
                appendU64(&manifest, UInt64(f.data.count))
            }
            var budget = max(1, DagDBWAL.importChunkBytes)
            #if DEBUG || DAGDB_FAULT_INJECTION
            if let v = DagDBFaultInjection.value("IMPORT_CHUNK_BYTES"), let n = Int(v), n >= 1 { budget = n }   // test seam
            #endif
            var records = 0
            var pieces: [Data] = []
            var entries: UInt32 = 0
            var room = budget
            func flush(final: Bool) throws {
                var count = Data(); appendU32(&count, entries)
                let body = [count] + pieces
                _ = try append(opcode: final ? .importMorton : .importPart, pieces: final ? [manifest] + body : body)
                records += 1
                pieces = []; entries = 0; room = budget
            }
            // The import's records are one unit. A failure after
            // some of its IMPORT_PART records were written cuts the log back
            // to the first of them (the failed record itself is cut by
            // `writeRecordLocked`): parts left behind would be staged into
            // the next import on replay. The daemon runs one command at a
            // time, so nothing else is appended between the group's records.
            let groupStart = queue.sync { lseek(fd, 0, SEEK_END) }
            do {
                // An import that needs more than one record writes every file byte in IMPORT_PART records
                // and closes with the manifest alone, so replay holds no record's window beside the assembled files.
                let split = files.reduce(0) { $0 + $1.data.count } > budget
                for (k, f) in files.enumerated() {
                    var off = 0
                    while off < f.data.count {
                        if room == 0 { try flush(final: false) }
                        let len = min(room, f.data.count - off)
                        var head = Data()
                        head.append(ids[k]); appendU64(&head, UInt64(off)); appendU32(&head, UInt32(len))
                        pieces.append(head)
                        let lo = f.data.startIndex + off
                        pieces.append(f.data[lo..<(lo + len)])
                        entries += 1; room -= len; off += len
                    }
                }
                if split && !pieces.isEmpty { try flush(final: false) }
                try flush(final: true)
            } catch {
                guard records > 0, groupStart >= 0 else { throw error }
                throw queue.sync { cutBackLocked(to: groupStart, written: records, unit: "import record(s)", error) }
            }
            return records
        }

        /// The header's version field rewritten in place
        /// (4 bytes at offset 4, through a descriptor of its own: the
        /// appender's is O_APPEND) and fsynced, on the appender's queue. A
        /// failure is named and leaves `fileVersion` as it was.
        /// `body` appends after the header was
        /// upgraded from `from` (nil: no upgrade). When it throws, the header's
        /// version is rewritten to `from` before the error is passed on, so a
        /// failed append leaves every WAL byte as it was; a put-back that fails
        /// is named in the error (the header stays at the new version, which
        /// this build reads; an older build then refuses the log by version).
        func puttingHeaderBack<T>(_ from: UInt32?, _ body: () throws -> T) throws -> T {
            do { return try body() } catch {
                guard let f = from else { throw error }
                let to = fileVersion
                let base: String
                if case WALError.ioFailure(let m)? = error as? WALError { base = m } else { base = Reply.errorWords(error) }
                let back: String? = queue.sync {
                    guard let hfd = try? DaemonFile.openForWrite(openPath, create: false, own: true) else { return "open errno=\(errno)" }
                    defer { close(hfd) }
                    var le = f.littleEndian
                    let w = pwrite(hfd, &le, 4, 4)
                    guard w == 4 else { return "pwrite \(w)/4 errno=\(errno)" }
                    guard fcntl(hfd, F_FULLFSYNC) == 0 || fsync(hfd) == 0 else { return "fsync errno=\(errno)" }
                    fileVersion = f
                    return nil
                }
                if let why = back {
                    throw WALError.ioFailure("\(base); the header's version \(f) -> \(to) rewrite stays (putting it back failed: \(why))")
                }
                throw WALError.ioFailure("\(base); the header's version put back to \(f)")
            }
        }

        /// Twin ops appended as ONE write — a bound hook's
        /// TWIN_CLOSE and its TWIN_HOOK_SWEEP, or the recovery sweep alone —
        /// whole or not at all (`writeRecordLocked` cuts a failed write back to
        /// the first record's start). An op whose opcode needs version 6
        /// upgrades a v2–v5 log first (as for tick notes, fsynced, before the
        /// records); the header goes back when the records do not land. A v1
        /// log refuses it by name (`opcodeNeedsVersion`), nothing written.
        @discardableResult
        public func twins(_ ops: [TwinOp]) throws -> Int {
            if refuseAppendsForGate {
                throw WALError.ioFailure("append refused (gate seam)")
            }
            let encoded = try ops.map { try TwinWALCodec.encode($0) }
            // A record the log's own replay would refuse (over the decoder's cap, or bytes it
            // cannot decode) is refused by name here, before the header's upgrade and before any byte is written.
            for (op, e) in zip(ops, encoded) {
                if let why = TwinWALCodec.appendRefusal(op, opcode: e.opcode, payload: e.payload) {
                    throw WALError.recordRefused(why)
                }
            }
            let needs = encoded.map { DagDBWAL.minimumVersion(for: $0.opcode) }.max() ?? DagDBWAL.versionV1
            var upgradedFrom: UInt32? = nil
            if fileVersion < needs {
                guard needs == DagDBWAL.versionV6, fileVersion >= DagDBWAL.versionV2 else {
                    let op = encoded.first(where: { DagDBWAL.minimumVersion(for: $0.opcode) > fileVersion })!.opcode
                    throw WALError.opcodeNeedsVersion(opcode: op.rawValue, needs: DagDBWAL.minimumVersion(for: op),
                                                      fileVersion: fileVersion)
                }
                let from = fileVersion
                try upgradeHeader(to: DagDBWAL.versionV6)
                upgradedFrom = from
            }
            var pieces: [Data] = []
            var total = 0
            for e in encoded {
                var rec = Data()
                appendU32(&rec, UInt32(e.payload.count))
                rec.append(e.opcode.rawValue)
                rec.append(e.payload)
                total += rec.count
                pieces.append(rec)
            }
            return try puttingHeaderBack(upgradedFrom) {
                try queue.sync {
                    try writeRecordLocked(pieces, total: total)
                    switch policy {
                    case .everyRecord:
                        let synced = Self.fullSync(fd)
                        _unsyncedCount = 0
                        if synced { markDurableLocked() }
                        else { throw poisonAfterFailedSyncLocked(cutBackTo: pendingRecords.last?.start) }
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
        }

        func upgradeHeader(to v: UInt32) throws {
            try queue.sync {
                if let p = poisoned { throw WALError.ioFailure(p) }
                let from = fileVersion
                let hfd: Int32
                do { hfd = try DaemonFile.openForWrite(openPath, create: false, own: true) } catch {
                    throw WALError.ioFailure("header: version \(from) -> \(v) not written (open: \(Reply.errorWords(error))); nothing appended")
                }
                defer { close(hfd) }
                var le = v.littleEndian
                let w = pwrite(hfd, &le, 4, 4)
                guard w == 4 else {
                    throw WALError.ioFailure("header: version \(from) -> \(v) not written (pwrite \(w)/4 errno=\(errno)); nothing appended")
                }
                guard fcntl(hfd, F_FULLFSYNC) == 0 || fsync(hfd) == 0 else {
                    throw WALError.ioFailure("header: version \(from) -> \(v) not synced (errno=\(errno)); nothing appended")
                }
                fileVersion = v
            }
        }

        // MARK: the record writer — all callers hold `queue`.

        /// One record (its pieces, in order) at the end of the
        /// log, whole or not at all. The invariant: the log ends at a record
        /// boundary whenever an append starts (the open cuts a torn tail;
        /// see `wholeEnd`). A write that fails after k bytes (k ≥ 0) cuts
        /// the log back to the record's start before the error is thrown,
        /// so the next record starts at a boundary; if that cut fails, the
        /// appender refuses every later append (`poisoned`), so no record
        /// ever follows a torn one — the torn bytes stay the log's tail,
        /// which replay drops and the next open cuts. A crash after k bytes
        /// leaves them as the tail: the same two rules. Hence every record
        /// in the log starts at a boundary, and the only bytes that are not a
        /// whole record are ever at the end. `queue`-confined.
        private func writeRecordLocked(_ pieces: [Data], total: Int) throws {
            if let p = poisoned { throw WALError.ioFailure(p) }
            let start = lseek(fd, 0, SEEK_END)
            guard start >= 0 else {
                throw WALError.ioFailure("write record: the log's end could not be read (lseek errno=\(errno)); nothing written")
            }
            var written = 0
            do {
                #if DEBUG || DAGDB_FAULT_INJECTION
                // Test seam: the record of this opcode fails as a full disk would.
                if let hex = DagDBFaultInjection.value("WAL_FAIL_OPCODE"), let want = UInt8(hex, radix: 16),
                   let first = pieces.first, first.count >= 5, first[first.startIndex + 4] == want {
                    throw WALError.ioFailure("write record: 0/\(total) errno=28 (\(DagDBFaultInjection.InjectedFault(what: "WAL_FAIL_OPCODE")))")
                }
                #endif
                for piece in pieces {
                    try piece.withUnsafeBytes { buf in
                        // One write(2) cannot carry more than INT_MAX bytes: a
                        // 100M-node SET_NEIGHBORS_BULK record is 2.4 GB, and the
                        // single call returned -1 (found by the ternary build's
                        // 100M-node scale run on main's binary). Written in chunks; a short
                        // write continues where it stopped.
                        var done = 0
                        while done < buf.count {
                            let n = min(buf.count - done, DagDBWAL.maxWriteChunk)
                            let w = write(fd, buf.baseAddress!.advanced(by: done), n)
                            if w <= 0 {
                                throw WALError.ioFailure("write record: \(written + done + max(w, 0))/\(total) errno=\(errno)")
                            }
                            done += w
                        }
                    }
                    written += piece.count
                }
            } catch {
                throw cutBackLocked(to: start, written: -1, unit: "record", error)
            }
            pendingRecords.append((Int(start), pieces))
        }

        /// Cut the log back to `start` after a failed append (the record, or
        /// an import's records); fsynced. Returns the error to throw: the
        /// original one, saying the bytes were cut, or — the cut failed —
        /// the poisoned refusal. `queue`-confined.
        private func cutBackLocked(to start: off_t, written: Int, unit: String, _ error: Error) -> Error {
            let base: String
            if case WALError.ioFailure(let m)? = error as? WALError { base = m } else { base = Reply.errorWords(error) }
            let what = written > 0 ? "\(written) \(unit)" : "the partial \(unit)"
            if !cutBackFailsForTesting && ftruncate(fd, start) == 0 {
                let synced = Self.fullSync(fd)
                if !synced && poisoned == nil {                                  // the fsync poison
                    poisoned = Self.poisonText(errno, path: path, offset: Int(start))
                }
                // The cut records leave the running
                // hash; a cut into bytes already hashed (an import's earlier,
                // synced parts) recomputes it from the file, streamed. 7.5: the
                // records before the cut join the hash only if the sync succeeded.
                pendingRecords.removeAll { $0.start >= Int(start) }
                if synced { markDurableLocked() }
                if Int(start) < hashedLength { rehashFromFileLocked(through: Int(start)) }
                return WALError.ioFailure("\(base); \(what) cut from the log (it ends at offset \(start) again)")
            }
            let e = cutBackFailsForTesting ? EIO : errno
            let why = "the log ends in \(what) that could not be cut back to offset \(start) (ftruncate errno=\(e)); no record is appended after it — restart the daemon (its open cuts the tail)"
            poisoned = why
            return WALError.ioFailure("\(base); \(why)")
        }

        // MARK: fsync helpers — all callers hold `queue`.

        /// The running hash recomputed over the
        /// file's first `n` bytes, read in 8 MiB chunks (a failure path only).
        private func rehashFromFileLocked(through n: Int) {
            var h = SHA256()
            let rfd = open(openPath, O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC)
            var at = 0
            if rfd >= 0 {
                defer { close(rfd) }
                var buf = Data(count: 8 << 20)
                while at < n {
                    let want = min(buf.count, n - at)
                    let got = buf.withUnsafeMutableBytes { pread(rfd, $0.baseAddress, want, off_t(at)) }
                    if got <= 0 { break }
                    Self.feedBlanked(&h, buf.prefix(got), at: at)
                    at += got
                }
            }
            runHash = h
            hashedLength = at
        }

        /// F_FULLFSYNC on the log, and whether it
        /// returned success. The running hash advances only on success; after a
        /// failure it stays at the last durable offset, so a seal never covers
        /// bytes the sync did not keep. (After a failed sync the appender refuses
        /// every write until the daemon restarts: `poisonText`.) Fault seam
        /// `DAGDB_FI_FULLFSYNC_FAIL`: the sync is not made and reports failure.
        /// `atOpen` marks the open's sync of the log it found; the seam's value `append` fails
        /// every sync but that one (so a test can start a daemon and fail its appends), any other value all.
        static func fullSync(_ fd: Int32, atOpen: Bool = false) -> Bool {
            #if DEBUG || DAGDB_FAULT_INJECTION
            if let v = DagDBFaultInjection.value("FULLFSYNC_FAIL"), !(atOpen && v == "append") { errno = EIO; return false }
            #endif
            return fcntl(fd, F_FULLFSYNC) == 0
        }

        /// The fsync poison: the refusal every append gives after a failed F_FULLFSYNC.
        static func poisonText(_ e: Int32, path: String, offset: Int) -> String {
            "F_FULLFSYNC of \(path) failed (\(DaemonFile.errnoName(e))) at offset \(offset): what the OS holds for the log may"
                + " not be durable (a failed fsync can drop dirty pages); the log refuses every write until the daemon"
                + " restarts (its open re-syncs the log, or refuses to start)"
        }

        /// An everyRecord append's sync failed. The record is cut back off the log (it was not
        /// made durable, and the caller applies nothing), the appender is poisoned (every later append, header
        /// rewrite and barrier refuses), and the error says so. `queue`-confined.
        private func poisonAfterFailedSyncLocked(cutBackTo start: Int?) -> Error {
            let e = errno
            var cut = ""
            if let st = start {
                pendingRecords.removeAll { $0.start >= st }
                if ftruncate(fd, off_t(st)) == 0 { cut = "; the record was cut from the log (it ends at offset \(st) again)" }
                else { cut = "; the record could not be cut back (ftruncate \(DaemonFile.errnoName(errno))): the log's tail is a record nothing applied, which the next open's replay applies" }
            }
            let why = Self.poisonText(e, path: path, offset: start ?? -1)
            poisoned = why
            return WALError.ioFailure("\(why)\(cut); nothing applied")
        }

        /// Whether the appender refuses writes (a failed sync, a cut-back that failed), and why.
        public var poisonReason: String? { queue.sync { poisoned } }

        /// fsync now, reset the counter, disarm the timer. `queue`-confined. A failed sync
        /// poisons the appender (grouped records already answered OK stay in the log).
        private func syncNowLocked() {
            let synced = fd >= 0 && Self.fullSync(fd)
            _unsyncedCount = 0
            if synced { markDurableLocked() }
            else if fd >= 0 && poisoned == nil { poisoned = Self.poisonText(errno, path: path, offset: Int(lseek(fd, 0, SEEK_END))) }
            timer?.cancel()
            timer = nil
        }

        /// `barrier()`, and throw when the log is poisoned (its sync failed now or before): a
        /// caller that needs its records durable before a step (SAVE's bind record before the rename) refuses.
        public func barrierChecked() throws {
            try queue.sync {
                syncNowLocked()
                if let p = poisoned { throw WALError.ioFailure(p) }
            }
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
            return try typed(.setTruth, d)
        }

        @discardableResult
        public func setRank(node: UInt32, value: UInt64) throws -> Int {
            var d = Data()
            appendU32(&d, node)
            appendU64(&d, value)
            return try typed(.setRank, d)
        }

        @discardableResult
        public func setEdgeWeight(node: UInt32, dir: UInt8, value: Float) throws -> Int {
            var d = Data()
            appendU32(&d, node)
            d.append(dir)
            appendU32(&d, value.bitPattern)
            return try typed(.setEdgeWeight, d)
        }

        @discardableResult
        public func setActivation(node: UInt32, value: Int16) throws -> Int {
            var d = Data()
            appendU32(&d, node)
            let u = UInt16(bitPattern: value)
            d.append(UInt8(u & 0xFF))
            d.append(UInt8(u >> 8))
            return try typed(.setActivation, d)
        }

        @discardableResult
        public func setNodeValue(node: UInt32, value: Float) throws -> Int {
            var d = Data()
            appendU32(&d, node)
            appendU32(&d, value.bitPattern)
            return try typed(.setNodeValue, d)
        }

        @discardableResult
        public func setLUT(node: UInt32, lut: UInt64) throws -> Int {
            var d = Data()
            appendU32(&d, node)
            appendU64(&d, lut)
            return try typed(.setLUT, d)
        }

        @discardableResult
        public func checkpoint(epoch: UInt64, sync: Bool = true) throws -> Int {
            var d = Data()
            appendU64(&d, epoch)
            return try typed(.checkpoint, d, sync: sync)
        }

        /// The snapshot bind record (0x51), written unsynced;
        /// the caller fsyncs it with `barrier()` before the snapshot's rename.
        @discardableResult
        public func snapshotBind(epoch: UInt64, digest: [UInt8], sync: Bool = false) throws -> Int {
            guard digest.count == 32 else {
                throw WALError.ioFailure("snapshot bind digest is \(digest.count) bytes, not 32")
            }
            var d = Data()
            appendU64(&d, epoch)
            d.append(contentsOf: digest)
            return try typed(.snapshotBind, d, sync: sync)
        }

        /// The advisory TICK_NOTE (0x52), the daemon's tick
        /// total after a tick command. A v2–v4 log is first upgraded to v5 in
        /// place (`upgradeHeader`, fsynced before the record); a
        /// header that cannot be written writes no note. A v1 log refuses it
        /// (`opcodeNeedsVersion`): its legacy SET_RANK widths are read only
        /// under version 1, so its header is never rewritten.
        ///
        /// The record is written unsynced (`sync: false`, no
        /// fsync and no group timer): it rides the next synced append or
        /// `barrier()` (SAVE, the checkpoint, shutdown). It is counted in
        /// `unsyncedCount` until then, outside `.grouped`'s n bound.
        @discardableResult
        public func tickNote(total: UInt64) throws -> Int {
            var from: UInt32? = nil
            if fileVersion >= DagDBWAL.versionV2 && fileVersion < DagDBWAL.versionV5 {
                from = fileVersion
                try upgradeHeader(to: DagDBWAL.versionV5)
            }
            var d = Data()
            appendU64(&d, total)
            return try puttingHeaderBack(from) { try typed(.tickNote, d, sync: false) }
        }

        /// The advisory COUNTER_DROP (0x53),
        /// the tick counter after an in-life drop with no successful rebase.
        /// Upgraded and written exactly as `tickNote` (v2–v4 → v5 first; v1
        /// refuses; unsynced).
        @discardableResult
        public func counterDrop(total: UInt64) throws -> Int {
            var from: UInt32? = nil
            if fileVersion >= DagDBWAL.versionV2 && fileVersion < DagDBWAL.versionV5 {
                from = fileVersion
                try upgradeHeader(to: DagDBWAL.versionV5)
            }
            var d = Data()
            appendU64(&d, total)
            return try puttingHeaderBack(from) { try typed(.counterDrop, d, sync: false) }
        }

        @discardableResult
        public func connectBack(src: UInt32, dst: UInt32) throws -> Int {
            var d = Data()
            appendU32(&d, src)
            appendU32(&d, dst)
            return try typed(.connectBack, d)
        }

        /// The whole bulk in one record, entries in order.
        @discardableResult
        public func connectBackBulk(_ pairs: [(src: UInt32, dst: UInt32)]) throws -> Int {
            var d = Data(); d.reserveCapacity(4 + 8 * pairs.count)
            appendU32(&d, UInt32(pairs.count))
            for p in pairs { appendU32(&d, p.src); appendU32(&d, p.dst) }
            return try typed(.connectBackBulk, d)
        }

        /// The whole bulk in one record, entries in order.
        @discardableResult
        public func setTruthBulk(_ entries: [(node: UInt32, value: UInt8)]) throws -> Int {
            var d = Data(); d.reserveCapacity(4 + 5 * entries.count)
            appendU32(&d, UInt32(entries.count))
            for e in entries { appendU32(&d, e.node); d.append(e.value) }
            return try typed(.setTruthBulk, d)
        }

        /// One SET_LUTS verb (its selector, op and pairs as given;
        /// the daemon logs only verbs its rule accepted).
        @discardableResult
        public func setLuts(_ sel: DagDBEngine.LutSelection, _ op: DagDBEngine.LutOp) throws -> Int {
            return try typed(.setLuts, DagDBWAL.encodeSetLuts(sel, op))
        }

        /// One SET_TRUTH … FILL verb (the daemon logs only verbs its
        /// rule accepted): u8 selector + u64 lo + u64 hi + u8 value.
        @discardableResult
        public func setTruthFill(_ sel: DagDBEngine.LutSelection, _ v: UInt8) throws -> Int {
            var d = Data(); d.reserveCapacity(18)
            switch sel {
            case let .nodes(lo, hi): d.append(0); appendU64(&d, lo); appendU64(&d, hi)
            case let .rank(lo, hi): d.append(1); appendU64(&d, lo); appendU64(&d, hi)
            }
            d.append(v)
            return try typed(.setTruthFill, d)
        }

        @discardableResult
        public func clearBackEdges(dst: UInt32) throws -> Int {
            var d = Data()
            appendU32(&d, dst)
            return try typed(.clearBackEdges, d)
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
            return try typed(.connect, d)
        }

        /// All six combinational slots of `node` reset to -1.
        @discardableResult
        public func clearEdges(node: UInt32) throws -> Int {
            var d = Data()
            appendU32(&d, node)
            return try typed(.clearEdges, d)
        }

        @discardableResult
        public func setRanksBulk(_ ranks: UnsafePointer<UInt64>, count: Int) throws -> Int {
            var d = Data()
            appendU32(&d, UInt32(count))
            d.append(UnsafeBufferPointer(start: ranks, count: count))
            return try typed(.setRanksBulk, d)
        }

        @discardableResult
        public func setLutsBulk(_ luts: UnsafePointer<UInt64>, count: Int) throws -> Int {
            var d = Data()
            appendU32(&d, UInt32(count))
            d.append(UnsafeBufferPointer(start: luts, count: count))
            return try typed(.setLutsBulk, d)
        }

        /// `count` is the NODE count; the vector itself is `count * 6` long.
        @discardableResult
        public func setNeighborsBulk(_ nb: UnsafePointer<Int32>, count: Int) throws -> Int {
            var d = Data()
            appendU32(&d, UInt32(count))
            d.append(UnsafeBufferPointer(start: nb, count: count * 6))
            return try typed(.setNeighborsBulk, d)
        }

        // ── Version 3: the native ternary tick ───────────────────────────
        // Each writer refuses, by name, a value the ternary rules refuse — the
        // log never carries a record replay would have to skip.

        @discardableResult
        public func setMode(node: UInt32, mode: UInt8) throws -> Int {
            if let why = TernaryReference.modeRefusal(mode) { throw WALError.refused(why) }
            var d = Data(); appendU32(&d, node); d.append(mode)
            return try typed(.setMode, d)
        }

        @discardableResult
        public func setTTableId(node: UInt32, tid: UInt16) throws -> Int {
            var d = Data(); appendU32(&d, node); appendU16(&d, tid)
            return try typed(.setTTableId, d)
        }

        @discardableResult
        public func setThresh(node: UInt32, lo: Float, hi: Float) throws -> Int {
            if let why = TernaryReference.thresholdRefusal(lo: lo, hi: hi) { throw WALError.refused(why) }
            var d = Data(); appendU32(&d, node); appendU32(&d, lo.bitPattern); appendU32(&d, hi.bitPattern)
            return try typed(.setThresh, d)
        }

        @discardableResult
        public func setTrit(node: UInt32, trit: Int8) throws -> Int {
            guard (-1...1).contains(trit) else { throw WALError.refused("trit \(trit) not in -1...1") }
            var d = Data(); appendU32(&d, node); d.append(UInt8(bitPattern: trit))
            return try typed(.setTrit, d)
        }

        @discardableResult
        public func ttableDefine(tid: UInt32, table: [UInt8]) throws -> Int {
            if let why = TernaryReference.libraryRefusal(table), table.count == TernaryReference.tableSize {
                throw WALError.refused(why)
            }
            guard table.count == TernaryReference.tableSize else {
                throw WALError.refused("a table is \(TernaryReference.tableSize) bytes, not \(table.count)")
            }
            var d = Data(); appendU32(&d, tid); d.append(contentsOf: table)
            return try typed(.ttableDefine, d)
        }

        @discardableResult
        public func ttablePreset(tid: UInt32, preset: TernaryReference.Preset, k: UInt8) throws -> Int {
            guard preset.arities.contains(Int(k)) else {
                throw WALError.refused("preset \(preset.rawValue) is not defined for k = \(k)")
            }
            var d = Data(); appendU32(&d, tid); d.append(preset.code); d.append(k)
            return try typed(.ttablePreset, d)
        }

        @discardableResult
        public func ttableCompose(dst: UInt32, tid: UInt32, table: [UInt8]) throws -> Int {
            guard table.count == TernaryReference.tableSize else {
                throw WALError.refused("a table is \(TernaryReference.tableSize) bytes, not \(table.count)")
            }
            if let why = TernaryReference.libraryRefusal(table) { throw WALError.refused(why) }
            var d = Data(); appendU32(&d, dst); appendU32(&d, tid); d.append(contentsOf: table)
            return try typed(.ttableCompose, d)
        }

        @discardableResult
        public func setModesBulk(_ modes: UnsafePointer<UInt8>, count: Int) throws -> Int {
            for i in 0..<count {
                if let why = TernaryReference.modeRefusal(modes[i]) { throw WALError.refused("node \(i): \(why)") }
            }
            var d = Data(); appendU32(&d, UInt32(count))
            d.append(UnsafeBufferPointer(start: modes, count: count))
            return try typed(.setModesBulk, d)
        }

        @discardableResult
        public func setTTableIdsBulk(_ ids: UnsafePointer<UInt16>, count: Int) throws -> Int {
            var d = Data(); appendU32(&d, UInt32(count))
            d.append(UnsafeBufferPointer(start: ids, count: count))
            return try typed(.setTTableIdsBulk, d)
        }

        /// `count` is the NODE count; the vector holds `2 * count` floats.
        @discardableResult
        public func setThreshBulk(_ pairs: UnsafePointer<Float>, count: Int) throws -> Int {
            for i in 0..<count {
                if let why = TernaryReference.thresholdRefusal(lo: pairs[2 * i], hi: pairs[2 * i + 1]) {
                    throw WALError.refused("node \(i): \(why)")
                }
            }
            var d = Data(); appendU32(&d, UInt32(count))
            d.append(UnsafeBufferPointer(start: pairs, count: 2 * count))
            return try typed(.setThreshBulk, d)
        }

        @discardableResult
        public func ttableBulk(first: UInt32, count: UInt32, bytes: UnsafeBufferPointer<UInt8>) throws -> Int {
            guard bytes.count == Int(count) * TernaryReference.tableSize else {
                throw WALError.refused("\(bytes.count) table bytes for \(count) table(s)")
            }
            for i in 0..<bytes.count where bytes[i] >= 3 {
                throw WALError.refused("table \(Int(first) + i / TernaryReference.tableSize) byte \(i % TernaryReference.tableSize) is \(bytes[i])")
            }
            var d = Data(); appendU32(&d, first); appendU32(&d, count)
            d.append(bytes)
            return try typed(.ttableBulk, d)
        }
    }

    /// The first S1–S3 slot an import's files install
    /// (`DagDBSnapshot.persistenceSlotScan` on its `rank.bin` and
    /// `neighbors.bin`), or nil — also nil when either file is missing or
    /// misshapen (the import refuses those itself).
    static func slotModelShape(files: [DagDBSnapshot.MortonFile], nodeCount n: Int) -> String? {
        guard n > 0, let r = files.first(where: { $0.name == "rank.bin" })?.data, r.count == n * 8,
              let b = files.first(where: { $0.name == "neighbors.bin" })?.data, b.count == n * 24 else { return nil }
        var rank = [UInt64](repeating: 0, count: n), nb = [Int32](repeating: -1, count: n * 6)
        rank.withUnsafeMutableBytes { _ = r.copyBytes(to: $0) }
        nb.withUnsafeMutableBytes { _ = b.copyBytes(to: $0) }
        return nb.withUnsafeBufferPointer { p in
            DagDBSnapshot.persistenceSlotScan(nodeCount: n, neighbors: p.baseAddress!) { rank[$0] }.firstShape
        }
    }

    /// Why replay would not apply a record of `opcode` with this payload for its SHAPE
    /// alone, or nil. It mirrors replay's per-opcode guards that read only the record (counted there under
    /// bad_length or out_of_range): the payload's length against the opcode's layout, a bulk's count against the
    /// log's node count, a SET_LUTS payload `decodeSetLuts` does not read, SET_TRUTH FILL's selector byte. Every
    /// typed append asks it before a byte is written (`Appender.typed`). The rules that read the engine's state
    /// (an index past the node count, the ternary rules, a table id past the library) are each verb's own checks,
    /// made before its append; the twin range has `TwinWALCodec.appendRefusal`; the
    /// import records are built here, under their own checks (the u16 directory, the u8 count, the u32 lengths).
    static func recordShapeRefusal(opcode: Opcode, payload: Data, nodeCount n: Int) -> String? {
        let len = payload.count
        let T = TernaryReference.tableSize
        func u32(_ o: Int) -> Int { Int(readU32(payload, payload.startIndex + o)) }
        func exactly(_ want: Int) -> String? {
            len == want ? nil : "the payload is \(len) bytes; replay reads exactly \(want)"
        }
        /// A u32 count at `at`, then `per` bytes per entry after `head` bytes; the count equal to the log's node
        /// count when `nodes`.
        func counted(head: Int, at: Int = 0, per: Int, nodes: Bool) -> String? {
            guard len >= head else { return "the payload is \(len) bytes, shorter than its \(head)-byte head" }
            let c = u32(at)
            guard len == head + per * c else {
                return "the payload is \(len) bytes; replay reads \(head) + \(per) x \(c) = \(head + per * c)"
            }
            if nodes && c != n { return "its count is \(c); replay applies only a count equal to the log's \(n) nodes" }
            return nil
        }
        switch opcode {
        case .setTruth, .setMode, .setTrit: return exactly(5)
        case .setRank, .setLUT, .setThresh: return exactly(12)
        case .setEdgeWeight, .connect: return exactly(9)
        case .setActivation, .setTTableId, .ttablePreset: return exactly(6)
        case .setNodeValue, .connectBack, .checkpoint, .tickNote, .counterDrop: return exactly(8)
        case .clearBackEdges, .clearEdges: return exactly(4)
        case .snapshotBind: return exactly(40)
        case .ttableDefine: return exactly(4 + T)
        case .ttableCompose: return exactly(8 + T)
        case .setRanksBulk, .setLutsBulk: return counted(head: 4, per: 8, nodes: true)
        case .setNeighborsBulk: return counted(head: 4, per: 24, nodes: true)
        case .setModesBulk: return counted(head: 4, per: 1, nodes: true)
        case .setTTableIdsBulk: return counted(head: 4, per: 2, nodes: true)
        case .setThreshBulk: return counted(head: 4, per: 8, nodes: true)
        case .ttableBulk: return counted(head: 8, at: 4, per: T, nodes: false)
        case .connectBackBulk: return counted(head: 4, per: 8, nodes: false)
        case .setTruthBulk: return counted(head: 4, per: 5, nodes: false)
        case .setLuts:
            return decodeSetLuts(payload, payload.startIndex, len) == nil
                ? "a SET_LUTS payload of \(len) bytes replay cannot decode (a MAP holds at most 255 pairs in its u8 count)" : nil
        case .setTruthFill:
            if let e = exactly(18) { return e }
            return payload[payload.startIndex] <= 1 ? nil : "selector byte \(payload[payload.startIndex]) is not 0 (NODES) or 1 (RANK)"
        case .importPart, .importMorton,
             .twinStreamOpen, .twinStreamState, .twinRecordOpen, .twinRecordSlice, .twinRingsOpen, .twinRingsWrite,
             .twinClockOpen, .twinClockAdvance, .twinGearOpen, .twinLayoutOpen, .twinAlarmLoad, .twinClose,
             .twinBankOpen, .twinViewLoad, .twinKernelLoad, .twinHookOpen, .twinHookStep, .twinHookSweep:
            return nil   // their own writers (above) check them
        }
    }

    /// The log version an opcode first appeared at.
    static func minimumVersion(for opcode: Opcode) -> UInt32 {
        switch opcode {
        case .connect, .clearEdges, .setRanksBulk, .setLutsBulk, .setNeighborsBulk:
            return versionV2
        case .setMode, .setTTableId, .setThresh, .setTrit, .ttableDefine, .ttablePreset,
             .ttableCompose, .setModesBulk, .setTTableIdsBulk, .setThreshBulk, .ttableBulk,
             .importPart, .importMorton, .connectBackBulk, .setTruthBulk, .setLuts, .setTruthFill:
            return versionV3
        case .tickNote, .counterDrop:
            return versionV5
        case .twinHookSweep:
            return versionV6
        default:
            // .snapshotBind is here on purpose: a marker, not a
            // mutation, so every log version may carry it (see 0x51 above).
            return versionV1
        }
    }

    // MARK: - The log's whole end

    /// The offset after which the log holds only bytes replay does not
    /// apply, and why (empty when that is the file's end). Two kinds, both at
    /// the tail only (see `Appender.writeRecordLocked`): a record whose
    /// declared length runs past the end of the file (a write cut short by a
    /// crash; replay drops it, `truncatedAtOffset`), and, before it, a run
    /// of IMPORT_PART records with no closing IMPORT_MORTON (an import cut
    /// between its records; replay refuses them as a torn import). The
    /// record rule is replay's own first pass.
    static func wholeEnd(_ data: Data, version: UInt32) -> (end: Int, why: String) {
        var off = headerSize
        var openImport: Int? = nil
        var cut = false
        while off < data.count {
            if off + 5 > data.count { cut = true; break }
            let total = 5 + Int(readU32(data, off))
            if off + total > data.count { cut = true; break }
            if version >= versionV3 && data[off + 4] == Opcode.importPart.rawValue {
                if openImport == nil { openImport = off }
            } else {
                openImport = nil
            }
            off += total
        }
        let cutWhy = "a record cut short (its declared length runs past the end of the file)"
        if let o = openImport {
            return (o, "IMPORT_PART record(s) without their closing IMPORT_MORTON (an import cut between its records)"
                       + (cut ? ", then " + cutWhy : ""))
        }
        return (off, cut ? cutWhy : "")
    }

    // MARK: - Replay

    /// Walk the log, apply every record to the engine. Records before the
    /// last CHECKPOINT marker are skipped (they're already in the snapshot).
    /// A truncated tail record is dropped (returns truncatedAtOffset).
    ///
    /// `snapshotDigest` gives the SHA-256 of the snapshot the
    /// caller loaded (asked only when the log holds a SNAPSHOT_BIND record).
    /// When a bind record carries it, the window starts after the LAST such
    /// record instead (see the 0x51 comment above).
    ///
    /// `wholeLog` replays from the header, ignoring every
    /// checkpoint and bind record — for a caller that loaded NO snapshot
    /// (an empty engine): those markers say where SOME snapshot's contents
    /// end, and that snapshot is not the base being replayed onto.
    /// `checkpointEpoch` still reports the last checkpoint's epoch.
    ///
    /// `beforeRecord`, when given, is called
    /// with each record's byte offset before that record is looked at (the
    /// era sidecar's offset is crossed there); it changes nothing.
    /// What a replayed record is about to build, for the caller's admission (the boot's): its
    /// live verb's charge is the caller's to compute. A refusal stops the replay (`WALError.overBudget`), so the
    /// daemon refuses to start by name instead of starting over its budget.
    public enum ReplayCharge {
        /// A twin record (its decoded op), before it is applied.
        case twin(TwinOp)
        /// `count` new back edges (CONNECT_BACK, CONNECT_BACK_BULK), before they are added.
        case backEdges(count: Int)
        /// The table library grown to hold `tables` tables (a TTABLE record), before the write.
        case tables(Int)
    }

    /// The most log bytes replay reads into one window (a record larger than this is read
    /// whole, alone). The boot admits each window it reads; the whole log is never held.
    public static let replayWindowBytes = 1 << 20

    /// The log read in bounded windows through the daemon's file reader (positional reads on the one
    /// descriptor, bounded by its st_size), each window admitted before it is read and the previous one released
    /// first. Indices are file offsets; `local` maps one into `buf`.
    final class LogWindow {
        let reader: DaemonFile.Reader
        let limit: Int
        let chunk: Int
        let admit: ((Int) -> String?)?
        private(set) var base = 0
        private(set) var buf = Data()

        init(reader: DaemonFile.Reader, limit: Int, chunk: Int, admit: ((Int) -> String?)?) {
            self.reader = reader; self.limit = limit; self.chunk = chunk; self.admit = admit
        }

        /// The bytes [lo, hi) resident (hi <= limit is the caller's check).
        func load(_ lo: Int, _ hi: Int) throws {
            if lo >= base && hi <= base + buf.count { return }
            let want = max(hi, min(lo + chunk, limit)) - lo
            buf = Data()
            if let a = admit, let line = a(want) { throw WALError.overBudget(line) }
            buf = try reader.readAt(lo, want)
            base = lo
        }
        @inline(__always) func local(_ i: Int) -> Int { i - base }
        @inline(__always) subscript(_ i: Int) -> UInt8 { buf[i - base] }
        func u32(_ i: Int) -> UInt32 { DagDBWAL.readU32(buf, i - base) }
        func u64(_ i: Int) -> UInt64 { DagDBWAL.readU64(buf, i - base) }
        func sub(_ lo: Int, _ hi: Int) -> Data { buf.subdata(in: (lo - base)..<(hi - base)) }
    }

    /// One streaming walk of the log through a bounded buffer: the facts replay's first pass
    /// took from the whole log in memory (the last checkpoint, every bind record, the last tick note, a cut tail),
    /// the log's whole end (`wholeEnd`'s rule, for the appender), and, when asked, the version-blanked SHA-256 at
    /// the asked offsets and at the valid end, fed only through bytes that belong to whole records.
    struct LogScan {
        var version: UInt32 = 0
        var nodeCount: UInt32 = 0
        var size = 0
        var lastCheckpoint: (off: Int, total: Int, epoch: UInt64)? = nil
        var binds: [(off: Int, total: Int, epoch: UInt64, digest: [UInt8])] = []
        var lastTickNote: (offset: Int, total: UInt64)? = nil
        var truncatedAt: Int? = nil
        var wholeEnd = headerSize
        var wholeWhy = ""
        var digests: [Int: String] = [:]
        var hashState: SHA256? = nil
        var validEnd: Int { truncatedAt ?? size }
    }

    /// The scan, over `r` (opened by the caller, nothing read yet), in chunks of `chunk` bytes. Throws the header
    /// refusals replay and the appender name: shorter than the header, a bad magic, a version this build cannot
    /// read (`readableHeader`), in that order.
    static func scanLog(_ r: DaemonFile.Reader, hashAt: [Int]?, chunk: Int) throws -> LogScan {
        var sc = LogScan()
        sc.size = r.size
        guard r.size >= headerSize else { throw WALError.truncated("shorter than header") }
        let head = try r.readAt(0, headerSize)
        guard [UInt8](head[0..<4]) == magic else { throw WALError.invalidMagic }
        sc.version = readU32(head, 4)
        guard isReadable(sc.version) else { throw WALError.unsupportedVersion(sc.version) }
        sc.nodeCount = readU32(head, 8)
        let ver = sc.version, size = r.size
        let asked = Array(Set(hashAt ?? []).filter { $0 >= 0 }).sorted()
        var ai = 0
        var h = SHA256()
        var hashed = 0
        var hashLimit = headerSize
        /// Feed `buf` (at file offset `bufBase`) from `hashed` to `x`, taking a digest at each asked offset crossed.
        func feed(_ buf: Data, _ bufBase: Int, to x: Int) {
            guard hashAt != nil else { return }
            while ai < asked.count && asked[ai] <= hashed {
                if asked[ai] == hashed { sc.digests[hashed] = h.finalize().map { String(format: "%02x", $0) }.joined() }
                ai += 1
            }
            while hashed < x {
                let stop = ai < asked.count ? min(asked[ai], x) : x
                let lo = buf.startIndex + (hashed - bufBase), hi = buf.startIndex + (stop - bufBase)
                Appender.feedBlanked(&h, buf.subdata(in: lo..<hi), at: hashed)
                hashed = stop
                while ai < asked.count && asked[ai] <= hashed {
                    if asked[ai] == hashed { sc.digests[hashed] = h.finalize().map { String(format: "%02x", $0) }.joined() }
                    ai += 1
                }
            }
        }
        var pos = 0
        var off = headerSize
        var openImport: Int? = nil
        var done = false
        var carry = Data(), carryBase = 0
        while pos < size {
            let n = min(chunk, size - pos)
            let c = try r.readAt(pos, n)
            let buf: Data, base: Int
            if carry.isEmpty { buf = c; base = pos } else { buf = carry + c; base = carryBase }
            carry = Data()
            let end = base + buf.count
            while !done && off < end {
                let avail = end - off
                if avail < 5 {
                    if pos + n >= size { sc.truncatedAt = off; done = true } else { carry = buf.subdata(in: (off - base)..<buf.count); carryBase = off }
                    break
                }
                let len = Int(readU32(buf, off - base))
                let total = 5 + len
                if off + total > size { sc.truncatedAt = off; done = true; break }
                let op = buf[off - base + 4]
                let small = (op == Opcode.checkpoint.rawValue && len == 8) || (op == Opcode.snapshotBind.rawValue && len == 40)
                    || (ver >= versionV5 && op == Opcode.tickNote.rawValue && len == 8)
                if small && avail < total { carry = buf.subdata(in: (off - base)..<buf.count); carryBase = off; break }
                if op == Opcode.checkpoint.rawValue && len == 8 {
                    sc.lastCheckpoint = (off, total, readU64(buf, off - base + 5))
                }
                if op == Opcode.snapshotBind.rawValue && len == 40 {
                    let d = [UInt8](buf.subdata(in: (off - base + 13)..<(off - base + 45)))
                    sc.binds.append((off, total, readU64(buf, off - base + 5), d))
                }
                if ver >= versionV5 && op == Opcode.tickNote.rawValue && len == 8 {
                    sc.lastTickNote = (off, readU64(buf, off - base + 5))
                }
                // `wholeEnd`'s rule: a run of IMPORT_PART records with no closing record at the tail.
                if ver >= versionV3 && op == Opcode.importPart.rawValue {
                    if openImport == nil { openImport = off }
                } else {
                    openImport = nil
                }
                hashLimit = off + total
                off += total
            }
            feed(buf, base, to: min(hashLimit, end))
            pos += n
        }
        if !done && off < size { sc.truncatedAt = off }
        let cutWhy = "a record cut short (its declared length runs past the end of the file)"
        if let o = openImport {
            sc.wholeEnd = o
            sc.wholeWhy = "IMPORT_PART record(s) without their closing IMPORT_MORTON (an import cut between its records)"
                + (sc.truncatedAt != nil ? ", then " + cutWhy : "")
        } else {
            sc.wholeEnd = sc.validEnd
            sc.wholeWhy = sc.truncatedAt != nil ? cutWhy : ""
        }
        if hashAt != nil { sc.hashState = h }
        return sc
    }

    public static func replay(
        engine: DagDBEngine,
        nodeCount: Int,
        path: String,
        twin: TwinState? = nil,
        snapshotDigest: (() -> [UInt8]?)? = nil,
        wholeLog: Bool = false,
        beforeRecord: ((Int) -> Void)? = nil,
        hashAt: [Int]? = nil,
        admitRecord: ((ReplayCharge) -> String?)? = nil
    ) throws -> ReplayResult {
        let t0 = Date()
        // One open through the helper: without blocking (a FIFO at DAGDB_WAL), a regular file
        // inside the root, unchanged while read (the fstat after the last read); a refusal is named (in older builds
        // any failure read as "file not found", and the daemon then ran without a WAL). The log's identity is the
        // fstat of the descriptor read.
        // The log is read in bounded windows, twice (the scan, then the records), never whole:
        // the boot admits each window it reads (`DaemonFile.admission`), not the log's size (an older build's whole
        // read), and the appender gets the scan's facts (`found`), not the bytes, so nothing holds the log after it.
        let r: DaemonFile.Reader
        do { r = try DaemonFile.Reader(path) }
        catch DaemonFile.Refusal.missing { throw WALError.ioFailure("file not found: \(Reply.quoted(path))") }
        catch { throw WALError.ioFailure(Reply.errorWords(error)) }
        func io<T>(_ body: () throws -> T) throws -> T {
            do { return try body() }
            catch let e as WALError { throw e }
            catch DaemonFile.Refusal.admission(let line) { throw WALError.overBudget(line) }
            catch { throw WALError.ioFailure(Reply.errorWords(error)) }
        }
        let windowAdmit: ((Int) -> String?)? = DaemonFile.admission.map { a in
            { a($0, "the log \(Reply.quoted(path))'s read window, \($0) B (the log is read in windows, never whole)") }
        }
        if let a = windowAdmit, let line = a(min(r.size, replayWindowBytes)) { throw WALError.overBudget(line) }
        let sc = try io { try scanLog(r, hashAt: hashAt, chunk: replayWindowBytes) }
        let ident: (UInt64, UInt64) = (r.device, r.inode)
        let ver = sc.version
        let fileNC = Int(sc.nodeCount)
        guard fileNC == nodeCount else {
            throw WALError.ioFailure("nodeCount \(fileNC) vs \(nodeCount)")
        }
        let truncatedAt = sc.truncatedAt
        let lastEpoch = sc.lastCheckpoint?.epoch ?? 0
        let lastTickNote = sc.lastTickNote
        var windowTickNoteMax: UInt64? = nil
        var windowCounterDrops = 0
        // The snapshot's own position, when the log has it.
        var bound: (off: Int, total: Int, epoch: UInt64)? = nil
        if !wholeLog, !sc.binds.isEmpty, let want = snapshotDigest?(), want.count == 32 {
            bound = sc.binds.last { $0.digest == want }.map { ($0.off, $0.total, $0.epoch) }
        }

        // Second pass: replay records after the last checkpoint (if any).
        // The window starts past the checkpoint record's OWN measured
        // length, never a hardcoded width.
        let startOff = wholeLog ? headerSize
            : (bound.map { $0.off + $0.total }
               ?? sc.lastCheckpoint.map { $0.off + $0.total } ?? headerSize)
        var applied = 0
        var afterCheckpoint = 0
        var skips = SkipReasons()
        var refusals: [String] = []
        var warnings: [String] = []
        var preHOOK1Stops: [String] = []
        let validEnd = sc.validEnd
        let win = LogWindow(reader: r, limit: validEnd, chunk: replayWindowBytes, admit: windowAdmit)
        var off = headerSize
        // A record refused by value: skipped, counted under out_of_range, named.
        func refuse(_ why: String) {
            skips.outOfRangeIndex += 1
            refusals.append(String(format: "offset %d opcode 0x%02x: ", off, win[off + 4]) + why)
        }
        /// The caller's admission of what the record is about to build.
        func charge(_ c: ReplayCharge) throws {
            if let a = admitRecord, let line = a(c) { throw WALError.overBudget(line) }
        }
        // An import's chunks, staged until its closing record, copied out of
        // the window (which moves on), each part's bytes admitted as they are staged.
        /// A split import's part chunks as log ranges (nothing copied); the closing record reads each
        /// chunk straight into the file it belongs to.
        var importPartRanges: [(id: Int, offset: Int, range: Range<Int>)] = []
        var importParts = 0
        var importFirstOffset = 0
        /// The chunk entries at `q` as file ranges (no copy); nil when malformed.
        func parseChunkRanges(_ q0: Int, _ end: Int) -> [(id: Int, offset: Int, range: Range<Int>)]? {
            var q = q0
            guard q + 4 <= end else { return nil }
            let k = Int(win.u32(q)); q += 4
            var out: [(id: Int, offset: Int, range: Range<Int>)] = []
            for _ in 0..<k {
                guard q + 13 <= end else { return nil }
                let o64 = win.u64(q + 1)
                guard o64 <= UInt64(sc.size) else { return nil }
                let id = Int(win[q]); let o = Int(o64); let len = Int(win.u32(q + 9))
                q += 13
                guard q + len <= end else { return nil }
                out.append((id, o, q..<(q + len))); q += len
            }
            return q == end ? out : nil
        }
        /// Parse `k` chunk entries at `q` (inside the loaded record); nil when the payload is malformed.
        func parseChunks(_ q0: Int, _ end: Int) -> [(id: Int, offset: Int, bytes: Data)]? {
            var q = q0
            guard q + 4 <= end else { return nil }
            let k = Int(win.u32(q)); q += 4
            var out: [(id: Int, offset: Int, bytes: Data)] = []
            for _ in 0..<k {
                guard q + 13 <= end else { return nil }
                // An offset no log of this size can carry is a
                // malformed payload, not a trap (Int(UInt64) traps past Int.max:
                // a misaligned log crashed replay here in older builds).
                let o64 = win.u64(q + 1)
                guard o64 <= UInt64(sc.size) else { return nil }
                let id = Int(win[q]); let o = Int(o64); let len = Int(win.u32(q + 9))
                q += 13
                guard q + len <= end else { return nil }
                out.append((id, o, win.sub(q, q + len))); q += len
            }
            return q == end ? out : nil
        }
        while off < validEnd {
            beforeRecord?(off)
            try io { try win.load(off, off + 5) }
            let payloadLen = Int(win.u32(off))
            let recordTotal = 4 + 1 + payloadLen
            let opRaw = win[off + 4]

            if off >= startOff {
                try io { try win.load(off, off + recordTotal) }
                switch opRaw {
                case Opcode.setTruth.rawValue:
                    guard payloadLen == 5 else { skips.badLength += 1; off += recordTotal; continue }
                    let node = Int(win.u32(off + 5))
                    let value = win[off + 9]
                    if node >= 0 && node < nodeCount {
                        // SET TRUTH's live rule
                        // reads only the node's mode, which the log carries,
                        // so replay applies it as live.
                        if value >= 3 && TernaryReference.isTernary(engine.modeByte(node)) {
                            refuse("node \(node): SET TRUTH \(value) on a ternary node (a ternary node holds 0, 1 or 2)")
                            off += recordTotal; continue
                        }
                        let p = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
                        p[node] = value
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.setRank.rawValue:
                    // v2 log: the payload is u32 node + u64 rank = 12 bytes,
                    // full stop. A record torn down to 8 or 5 bytes used to be
                    // indistinguishable from a legacy record and was applied as
                    // a real rank write.
                    // v1 log: the legacy widths are genuine — u32 rank = 8,
                    // u8 rank = 5 — and still replay.
                    guard payloadLen >= 4 else { skips.badLength += 1; off += recordTotal; continue }
                    let node = Int(win.u32(off + 5))
                    let value: UInt64
                    if payloadLen == 12 {
                        value = win.u64(off + 9)
                    } else if ver == versionV1 && payloadLen == 8 {
                        value = UInt64(win.u32(off + 9))
                    } else if ver == versionV1 && payloadLen == 5 {
                        value = UInt64(win[off + 9])
                    } else {
                        skips.badLength += 1; off += recordTotal; continue
                    }
                    if node >= 0 && node < nodeCount {
                        // A logged rank that does
                        // not fit Int is refused by name. Ranks from nodeCount to
                        // Int.max replay as logged (a stored shape the engine
                        // tolerates: the old-file fixture's v2.wal); above Int.max, a later
                        // `WHERE rank` read trapped in `Int(rank)`.
                        if value > UInt64(Int.max) {
                            refuse("node \(node): SET_RANK \(value) does not fit Int (above \(Int.max)); not applied")
                            off += recordTotal; continue
                        }
                        let p = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: nodeCount)
                        p[node] = value
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.setLUT.rawValue:
                    guard payloadLen == 12 else { skips.badLength += 1; off += recordTotal; continue }
                    let node = Int(win.u32(off + 5))
                    let lut  = win.u64(off + 9)
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
                    let node = Int(win.u32(off + 5))
                    let dir = Int(win[off + 9])
                    let bits = win.u32(off + 10)
                    if node >= 0 && node < nodeCount && dir >= 0 && dir < 6 {
                        // SET WEIGHT's rule, a
                        // value-only check, holds on replay as live.
                        if let why = DagDBSnapshot.weightRefusal(bits: bits, node: node, slot: dir) {
                            refuse(why); off += recordTotal; continue
                        }
                        let p = engine.edgeWeightsBuf.contents()
                            .bindMemory(to: Float.self, capacity: nodeCount * 6)
                        p[node * 6 + dir] = Float(bitPattern: bits)
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.setActivation.rawValue:
                    // u32 node + i16 value (LE) = 6 bytes.
                    guard payloadLen == 6 else { skips.badLength += 1; off += recordTotal; continue }
                    let node = Int(win.u32(off + 5))
                    let raw = UInt16(win[off + 9]) | (UInt16(win[off + 10]) << 8)
                    if node >= 0 && node < nodeCount {
                        let p = engine.activationBuf.contents()
                            .bindMemory(to: Int16.self, capacity: nodeCount)
                        p[node] = Int16(bitPattern: raw)
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.setNodeValue.rawValue:
                    // u32 node + f32 value = 8 bytes.
                    guard payloadLen == 8 else { skips.badLength += 1; off += recordTotal; continue }
                    let node = Int(win.u32(off + 5))
                    let bits = win.u32(off + 9)
                    if node >= 0 && node < nodeCount {
                        // SET VALUE's rule, a
                        // value-only check, holds on replay as live.
                        if let why = DagDBSnapshot.nodeValueRefusal(bits: bits, node: node) {
                            refuse(why); off += recordTotal; continue
                        }
                        let p = engine.nodeValueBuf.contents()
                            .bindMemory(to: Float.self, capacity: nodeCount)
                        p[node] = Float(bitPattern: bits)
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.connectBack.rawValue:
                    guard payloadLen == 8 else { skips.badLength += 1; off += recordTotal; continue }
                    let src = win.u32(off + 5)
                    let dst = win.u32(off + 9)
                    if Int(src) < nodeCount && Int(dst) < nodeCount {
                        // The register rule
                        // (a register stays binary) reads only the destination's
                        // mode, which the log carries, so replay applies it
                        // as live.
                        if TernaryReference.isTernary(engine.modeByte(Int(dst))) {
                            refuse("node \(dst): CONNECT BACK into ternary node \(dst) from node \(src); a register (BACK_EDGE destination) stays BINARY")
                            off += recordTotal; continue
                        }
                        // Replay path bypasses validation — the WAL recorded
                        // an event that succeeded at write time. Use the
                        // unchecked form so a transiently combinational
                        // ordering during replay (combinational edge replayed
                        // before the back-edge that validated it away) does
                        // not abort recovery.
                        try charge(.backEdges(count: 1))
                        try engine.addBackEdgeUnchecked(src: src, dst: dst)
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.clearBackEdges.rawValue:
                    guard payloadLen == 4 else { skips.badLength += 1; off += recordTotal; continue }
                    let dst = win.u32(off + 5)
                    if Int(dst) < nodeCount {
                        try engine.clearBackEdges(toNode: dst)
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.connect.rawValue:
                    // u32 dst + u8 slot + i32 src = 9 bytes.
                    guard payloadLen == 9 else { skips.badLength += 1; off += recordTotal; continue }
                    let dst = Int(win.u32(off + 5))
                    let slot = Int(win[off + 9])
                    let src = Int32(bitPattern: win.u32(off + 10))
                    if dst >= 0 && dst < nodeCount && slot >= 0 && slot < 6
                        && src >= -1 && Int(src) < nodeCount {
                        let p = engine.neighborsBuf.contents()
                            .bindMemory(to: Int32.self, capacity: nodeCount * 6)
                        p[dst * 6 + slot] = src
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.clearEdges.rawValue:
                    guard payloadLen == 4 else { skips.badLength += 1; off += recordTotal; continue }
                    let node = Int(win.u32(off + 5))
                    if node >= 0 && node < nodeCount {
                        let p = engine.neighborsBuf.contents()
                            .bindMemory(to: Int32.self, capacity: nodeCount * 6)
                        for d in 0..<6 { p[node * 6 + d] = -1 }
                        applied += 1; afterCheckpoint += 1
                    } else { skips.outOfRangeIndex += 1 }
                case Opcode.setRanksBulk.rawValue:
                    guard payloadLen >= 4 else { skips.badLength += 1; off += recordTotal; continue }
                    let n = Int(win.u32(off + 5))
                    guard payloadLen == 4 + n * 8 else {
                        skips.badLength += 1; off += recordTotal; continue
                    }
                    guard n == nodeCount else {
                        skips.outOfRangeIndex += 1; off += recordTotal; continue
                    }
                    // The whole vector is checked
                    // first; one rank that does not fit Int refuses the record,
                    // nothing applied (SET_RANK's rule above, for the bulk form).
                    // Through the one pure check.
                    if let why = bulkValueRefusal(opcode: opRaw, data: win.buf, payloadStart: win.local(off + 5), nodeCount: nodeCount) {
                        refuse(why)
                        off += recordTotal; continue
                    }
                    let dstPtr = engine.rankBuf.contents()
                        .bindMemory(to: UInt64.self, capacity: nodeCount)
                    win.buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                        memcpy(dstPtr, raw.baseAddress!.advanced(by: win.local(off + 9)), n * 8)
                    }
                    applied += 1; afterCheckpoint += 1
                case Opcode.setLutsBulk.rawValue:
                    guard payloadLen >= 4 else { skips.badLength += 1; off += recordTotal; continue }
                    let n = Int(win.u32(off + 5))
                    guard payloadLen == 4 + n * 8 else {
                        skips.badLength += 1; off += recordTotal; continue
                    }
                    guard n == nodeCount else {
                        skips.outOfRangeIndex += 1; off += recordTotal; continue
                    }
                    let low  = engine.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
                    let high = engine.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: nodeCount)
                    win.buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                        let src = raw.baseAddress!.advanced(by: win.local(off + 9))
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
                    let n = Int(win.u32(off + 5))
                    guard payloadLen == 4 + n * 24 else {
                        skips.badLength += 1; off += recordTotal; continue
                    }
                    guard n == nodeCount else {
                        skips.outOfRangeIndex += 1; off += recordTotal; continue
                    }
                    // The live verb's range rule,
                    // over the whole vector before one word is applied. Replay
                    // copied the vector unchecked, so a logged neighbour id at
                    // or past nodeCount was installed and a later FOLD RUN read
                    // past its array and trapped.
                    if let why = bulkValueRefusal(opcode: opRaw, data: win.buf, payloadStart: win.local(off + 5), nodeCount: nodeCount) {
                        refuse(why)
                        off += recordTotal; continue
                    }
                    let dstPtr = engine.neighborsBuf.contents()
                        .bindMemory(to: Int32.self, capacity: nodeCount * 6)
                    win.buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                        memcpy(dstPtr, raw.baseAddress!.advanced(by: win.local(off + 9)), n * 24)
                    }
                    applied += 1; afterCheckpoint += 1
                    // A record from before the slot model may give a
                    // register a slot (S4), which the slot model refuses live. Applied as
                    // logged — recovery equals what that daemon held — and
                    // named; SAVE refuses the state until CLEAR <dst> EDGES or
                    // CLEAR <dst> BACK_EDGES.
                    let s4 = engine.slotsIntoRegisters()
                    if !s4.isEmpty {
                        let shown = s4.prefix(16).map { "node \($0.register) slot \($0.slot) (source node \($0.source))" }
                        warnings.append(String(format: "offset %d opcode 0x%02x: ", off, opRaw)
                            + "SET_NEIGHBORS_BULK gives \(s4.count) slot(s) into a register: " + shown.joined(separator: ", ")
                            + (s4.count > shown.count ? ", …" : "")
                            + "; applied as logged (a record from an older build; this build refuses it live)")
                    }
                case Opcode.twinStreamOpen.rawValue...Opcode.twinHookSweep.rawValue:
                    // Twin registry ops. `twin == nil` means the
                    // caller isn't restoring twin state at all — walk past
                    // the record without applying or counting it (not a
                    // skip either: nothing was lost, the caller asked for
                    // no twin state). A malformed payload decodes to nil
                    // and counts as a bad length; an `apply` error (a bad
                    // id, an already-open id) counts as out-of-range — the
                    // record names something the registry cannot address.
                    // Neither is fatal: the rest of the log must replay.
                    // The sweep record exists from version 6; a log
                    // below it cannot carry one (counted unknown, as v5's notes).
                    if opRaw == Opcode.twinHookSweep.rawValue && ver < versionV6 { skips.unknownOpcode += 1; break }
                    if let twin = twin {
                        let payload = win.sub(off + 5, off + 5 + payloadLen)
                        if let decoded = TwinWALCodec.decode(opcode: opRaw, payload: payload) {
                            // A record that
                            // changed state is counted under its own word, never
                            // as skipped. `apply` refuses before any change, so a
                            // refused twin record is a skip, named with its reason
                            // (it used to be an unnamed out_of_range). A CLOCK
                            // ADVANCE on a clock holding a closed hook's id came
                            // from an older log: replayed as that daemon ran it
                            // live, and named.
                            // The record's live charge first (the caller's), and the
                            // files and banks it rebuilds through the boot's admission; a refusal stops the
                            // replay (the start is refused), never skips the record.
                            try charge(.twin(decoded))
                            do {
                                switch try twin.applyReplayed(decoded, admit: DaemonFile.admission) {
                                case .applied:
                                    applied += 1; afterCheckpoint += 1
                                case .preHOOK1Stop(let clockId, let at):
                                    applied += 1; afterCheckpoint += 1
                                    var n: UInt64 = 0
                                    if case .clockAdvance(_, let c, _) = decoded { n = c }
                                    preHOOK1Stops.append(String(format: "offset %d: ", off)
                                        + "CLOCK ADVANCE \(clockId) \(n) stopped at \(at) after tick 1, as the pre-HOOK1 daemon ran it")
                                }
                            } catch let x as DaemonFile.Refusal where x.isAdmission {
                                throw WALError.overBudget(x.replyLine ?? Reply.errorWords(x))
                            } catch {
                                refuse("\(TwinWALCodec.recordWord(decoded)): \(Reply.errorWords(error)); not applied")
                            }
                        } else if opRaw == Opcode.twinBankOpen.rawValue,
                                  let r = TwinWALCodec.bankOpenRefusal(payload: payload) {
                            // A bank-open
                            // record that parses but fails the spec's validation
                            // (decode still answers nil for it) is refused by name.
                            refuse("BANK OPEN \(r.id): \(r.why); not applied")
                        } else {
                            skips.badLength += 1
                        }
                    }
                case Opcode.setMode.rawValue ... Opcode.ttableBulk.rawValue:
                    // Version 3, the ternary ops. A log whose header predates
                    // them cannot carry them; one that does is unknown here.
                    guard ver >= versionV3 else { skips.unknownOpcode += 1; break }
                    // A table write that grows the library, admitted first.
                    if let t = tablesAfter(opcode: opRaw, payloadLen: payloadLen, at: off + 5, win), t > engine.ttableCapacity {
                        try charge(.tables(t))
                    }
                    switch applyTernary(engine: engine, nodeCount: nodeCount, opcode: opRaw,
                                        data: win.buf, payloadStart: win.local(off + 5), payloadLen: payloadLen) {
                    case .applied: applied += 1; afterCheckpoint += 1
                    case .badLength: skips.badLength += 1
                    case .outOfRange: skips.outOfRangeIndex += 1
                    case .refused(let why):
                        skips.outOfRangeIndex += 1
                        refusals.append(String(format: "offset %d opcode 0x%02x: ", off, opRaw) + why)
                    }
                case Opcode.importPart.rawValue:
                    guard ver >= versionV3 else { skips.unknownOpcode += 1; break }
                    // The part's chunks are remembered as ranges of the log, not copied (an earlier build copied
                    // and held each part until the closing record, about 2.2x the files at replay against the live 1.1x).
                    guard let ranges = parseChunkRanges(off + 5, off + 5 + payloadLen) else { skips.badLength += 1; break }
                    if importParts == 0 { importFirstOffset = off }
                    importPartRanges += ranges; importParts += 1
                case Opcode.importMorton.rawValue:
                    guard ver >= versionV3 else { skips.unknownOpcode += 1; break }
                    let parts = importParts
                    defer { importPartRanges = []; importParts = 0 }
                    // The manifest: the directory, then each file read and its size.
                    let end = off + 5 + payloadLen
                    var q = off + 5
                    guard q + 2 <= end else { skips.badLength += 1 + parts; break }
                    let dirLen = Int(UInt16(win[q]) | UInt16(win[q + 1]) << 8); q += 2
                    guard q + dirLen + 1 <= end else { skips.badLength += 1 + parts; break }
                    let dir = String(decoding: win.sub(q, q + dirLen), as: UTF8.self); q += dirLen
                    let m = Int(win[q]); q += 1
                    guard q + 9 * m <= end else { skips.badLength += 1 + parts; break }
                    var sizes: [Int: Int] = [:]
                    // A file larger than the log that carries it is a
                    // malformed manifest (refused below), never an allocation or a trap.
                    var sizeTooLarge = false
                    for j in 0..<m {
                        let v = win.u64(q + 9 * j + 1)
                        if v > UInt64(sc.size) { sizeTooLarge = true } else { sizes[Int(win[q + 9 * j])] = Int(v) }
                    }
                    guard !sizeTooLarge else { skips.badLength += 1 + parts; break }
                    q += 9 * m
                    // An import whose record holds every file whole (no parts, each
                    // file one chunk at offset 0) replays on the record's own bytes, with no copy: the window that
                    // holds the record was admitted at 1.1 x its bytes, which is IMPORT MORTON's live charge (1.1 x
                    // its files), and nothing more is held (an earlier assembly copied the files, about 2.2 x).
                    // A file of 0 bytes has no chunk (the appender writes none for it, and EXPORT MORTON writes an
                    // empty ttables.bin), so "whole" is: every chunk one whole listed file, each file at most once,
                    // every listed file of more than 0 bytes has its chunk; the 0-byte files are empty, as the
                    // assembly below makes them.
                    if parts == 0, let ranges = parseChunkRanges(q, end) {
                        let names = DagDBSnapshot.mortonImportFileNames
                        let chunked = Set(ranges.map { $0.id })
                        let whole = chunked.count == ranges.count && ranges.allSatisfy { c in
                            c.id < names.count && c.offset == 0 && sizes[c.id] == c.range.count
                        } && sizes.allSatisfy { id, size in id < names.count && (size == 0 || chunked.contains(id)) }
                        if whole {
                            do {
                                try win.buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                                    var files: [String: Data] = [:]
                                    for (id, size) in sizes where size == 0 && !chunked.contains(id) { files[names[id]] = Data() }
                                    for c in ranges {
                                        let p = UnsafeMutableRawPointer(mutating: raw.baseAddress!.advanced(by: win.local(c.range.lowerBound)))
                                        files[names[c.id]] = Data(bytesNoCopy: p, count: c.range.count, deallocator: .none)
                                    }
                                    _ = try DagDBSnapshot.importMorton(engine: engine, nodeCount: nodeCount, dir: dir,
                                                                       files: { files[$0] })
                                }
                                applied += 1; afterCheckpoint += 1
                            } catch {
                                refuse("IMPORT MORTON \(dir): \(Reply.errorWords(error))")
                            }
                            break
                        }
                    }
                    guard let last = parseChunkRanges(q, end) else { skips.badLength += 1 + parts; break }
                    // The files assembled from their chunks (an import with parts, or a file in more
                    // than one chunk), admitted at the live verb's charge (IMPORT MORTON admits 1.1 x its files' bytes).
                    // And that is all replay holds for them: each file is allocated once at its size
                    // and every chunk, a part's or the closing record's, is read from the log straight into it (no
                    // staged copy; the closing record of a split import carries only the manifest).
                    if let a = DaemonFile.admission,
                       let line = a(sizes.values.reduce(0, +), "the replayed import's \(sizes.count) files, assembled from the log") {
                        throw WALError.overBudget(line)
                    }
                    // Assemble each file from its chunks; every byte exactly once.
                    let names = DagDBSnapshot.mortonImportFileNames
                    var files: [String: Data] = [:]
                    var bad: String? = nil
                    let all = importPartRanges + last
                    for (id, size) in sizes.sorted(by: { $0.key < $1.key }) {
                        guard id < names.count else { bad = "file id \(id) is not an import file"; break }
                        let cs = all.filter { $0.id == id }.sorted { $0.offset < $1.offset }
                        var buf = Data(count: size)
                        var at = 0
                        for c in cs {
                            guard c.offset == at, at + c.range.count <= size else { bad = "\(names[id]): chunks do not tile its \(size) bytes"; break }
                            do {
                                try buf.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) in
                                    try win.reader.readAt(c.range.lowerBound, into: b.baseAddress!.advanced(by: at), c.range.count)
                                }
                            } catch {
                                bad = "\(names[id]): its chunk at log offset \(c.range.lowerBound) could not be read (\(Reply.errorWords(error)))"; break
                            }
                            at += c.range.count
                        }
                        if bad == nil && at != size { bad = "\(names[id]): \(at) of \(size) bytes logged" }
                        if bad != nil { break }
                        files[names[id]] = buf
                    }
                    if bad == nil, all.contains(where: { sizes[$0.id] == nil }) {
                        bad = "a chunk names a file the manifest does not list"
                    }
                    if let why = bad {
                        refuse("IMPORT MORTON \(dir): \(why)"); skips.outOfRangeIndex += parts; break
                    }
                    do {
                        _ = try DagDBSnapshot.importMorton(engine: engine, nodeCount: nodeCount, dir: dir,
                                                           files: { files[$0] })
                        applied += 1 + parts; afterCheckpoint += 1 + parts
                    } catch {
                        refuse("IMPORT MORTON \(dir): \(Reply.errorWords(error))"); skips.outOfRangeIndex += parts
                    }
                case Opcode.connectBackBulk.rawValue:
                    // Whole or nothing, by the single record's replay rules.
                    guard ver >= versionV3 else { skips.unknownOpcode += 1; break }
                    guard payloadLen >= 4 else { skips.badLength += 1; break }
                    let k = Int(win.u32(off + 5))
                    guard payloadLen == 4 + 8 * k else { skips.badLength += 1; break }
                    var why: String? = nil
                    for j in 0..<k {
                        let src = win.u32(off + 9 + 8 * j), dst = win.u32(off + 13 + 8 * j)
                        if Int(src) >= nodeCount || Int(dst) >= nodeCount {
                            why = "entry \(j): src \(src) dst \(dst) not in 0..<\(nodeCount)"; break
                        }
                        if TernaryReference.isTernary(engine.modeByte(Int(dst))) {
                            why = "entry \(j): CONNECT BACK into ternary node \(dst) from node \(src); a register (BACK_EDGE destination) stays BINARY"; break
                        }
                    }
                    if let why = why { refuse("CONNECT_BACK_BULK of \(k): \(why); nothing applied"); break }
                    try charge(.backEdges(count: k))
                    for j in 0..<k {
                        try engine.addBackEdgeUnchecked(src: win.u32(off + 9 + 8 * j),
                                                        dst: win.u32(off + 13 + 8 * j))
                    }
                    applied += 1; afterCheckpoint += 1
                case Opcode.setTruthBulk.rawValue:
                    // Whole or nothing, by the single record's replay rules.
                    guard ver >= versionV3 else { skips.unknownOpcode += 1; break }
                    guard payloadLen >= 4 else { skips.badLength += 1; break }
                    let k = Int(win.u32(off + 5))
                    guard payloadLen == 4 + 5 * k else { skips.badLength += 1; break }
                    var why: String? = nil
                    for j in 0..<k {
                        let node = Int(win.u32(off + 9 + 5 * j)), value = win[off + 13 + 5 * j]
                        if node >= nodeCount { why = "entry \(j): node \(node) not in 0..<\(nodeCount)"; break }
                        if value >= 3 && TernaryReference.isTernary(engine.modeByte(node)) {
                            why = "entry \(j): node \(node): SET TRUTH \(value) on a ternary node (a ternary node holds 0, 1 or 2)"; break
                        }
                    }
                    if let why = why { refuse("SET_TRUTH_BULK of \(k): \(why); nothing applied"); break }
                    let p = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
                    for j in 0..<k { p[Int(win.u32(off + 9 + 5 * j))] = win[off + 13 + 5 * j] }
                    applied += 1; afterCheckpoint += 1
                case Opcode.setLuts.rawValue:
                    // The verb's own rule against the replayed node
                    // count, then the engine's own function (the CPU twin, the
                    // rank lane for a rank selection).
                    guard ver >= versionV3 else { skips.unknownOpcode += 1; break }
                    guard let dec = decodeSetLuts(win.buf, win.local(off + 5), payloadLen) else { skips.badLength += 1; break }
                    let (sel, op) = dec
                    if let r = DagDBEngine.setLutsRefusal(sel, op, nodeCount: nodeCount) {
                        refuse("SET_LUTS \(sel): \(r.detail); not applied"); break
                    }
                    do { try engine.setLuts(sel, op, useRankLists: false, allowGPU: false) }
                    catch { refuse("SET_LUTS \(sel): \(Reply.errorWords(error)); not applied"); break }
                    applied += 1; afterCheckpoint += 1
                case Opcode.setTruthFill.rawValue:
                    // The verb's own rule against the replayed node
                    // count and ternary nodes, then the engine's own function
                    // (the rank lane for a rank selection).
                    guard ver >= versionV3 else { skips.unknownOpcode += 1; break }
                    guard payloadLen == 18, win[off + 5] <= 1 else { skips.badLength += 1; break }
                    let lo = win.u64(off + 6), hi = win.u64(off + 14), v = win[off + 22]
                    let sel: DagDBEngine.LutSelection = win[off + 5] == 0 ? .nodes(lo, hi) : .rank(lo, hi)
                    if let r = DagDBEngine.setTruthFillRefusal(sel, v, nodeCount: nodeCount,
                                                               nonBinaryNodes: engine.nonBinaryNodeCount) {
                        refuse("SET_TRUTH \(sel) FILL \(v): \(r.detail); not applied"); break
                    }
                    do { try engine.setTruthFill(sel, v, useRankLists: false) }
                    catch { refuse("SET_TRUTH \(sel) FILL \(v): \(Reply.errorWords(error)); not applied"); break }
                    applied += 1; afterCheckpoint += 1
                case Opcode.checkpoint.rawValue:
                    // A checkpoint of any width but 8 is torn — named here,
                    // and already refused as a boundary in the first pass.
                    if payloadLen != 8 { skips.badLength += 1 }
                case Opcode.snapshotBind.rawValue:
                    // A marker; nothing to apply. Torn: named.
                    if payloadLen != 40 { skips.badLength += 1 }
                case Opcode.tickNote.rawValue:
                    // Advisory; nothing to apply. Below v5
                    // it is unknown, as before; torn: named.
                    guard ver >= versionV5 else { skips.unknownOpcode += 1; break }
                    guard payloadLen == 8 else { skips.badLength += 1; break }
                    let total = win.u64(off + 5)
                    windowTickNoteMax = max(windowTickNoteMax ?? total, total)   // the highest note in the window
                case Opcode.counterDrop.rawValue:
                    // Advisory; nothing to apply. Below v5 unknown.
                    guard ver >= versionV5 else { skips.unknownOpcode += 1; break }
                    guard payloadLen == 8 else { skips.badLength += 1; break }
                    windowCounterDrops += 1
                default:
                    skips.unknownOpcode += 1
                }
            }
            off += recordTotal
        }
        // Parts whose closing record never arrived (the
        // log ends inside an import, e.g. a crash mid-append) — never applied.
        if importParts > 0 {
            skips.outOfRangeIndex += importParts
            refusals.append(String(format: "offset %d opcode 0x%02x: ", importFirstOffset, Opcode.importPart.rawValue)
                + "torn import: \(importParts) IMPORT_PART record(s) without their IMPORT_MORTON record; not applied")
        }
        importPartRanges = []
        // The file unchanged since its open, across both passes (the fstat after the last read).
        try io { try r.finish(whole: false) }
        #if DEBUG || DAGDB_FAULT_INJECTION
        replayAfterReadForTesting?(path)   // test seam: after the read (both passes), before the identity is used
        #endif

        let elapsed = Date().timeIntervalSince(t0) * 1000.0
        var result = ReplayResult(
            recordsApplied: applied,
            recordsAfterCheckpoint: afterCheckpoint,
            checkpointEpoch: lastEpoch,
            elapsedMs: elapsed,
            truncatedAtOffset: truncatedAt,
            recordsSkipped: skips.total,
            skipReasons: skips,
            fileVersion: ver,
            refusals: refusals,
            boundAtOffset: bound?.off,
            boundEpoch: bound?.epoch,
            bindRecords: sc.binds.count,
            warnings: warnings,
            tickNote: lastTickNote,
            tickNoteWindowMax: windowTickNoteMax,
            counterDropsInWindow: windowCounterDrops,
            windowStart: startOff,
            preHOOK1Stops: preHOOK1Stops
        )
        // The prefix hashes, from the scan's one pass (no copy of the log).
        result.prefixDigests = sc.digests
        result.hashState = sc.hashState
        result.hashedLength = sc.hashState == nil ? 0 : validEnd
        result.found = FoundLog(device: ident.0, inode: ident.1, size: sc.size, version: ver, nodeCount: sc.nodeCount,
                                wholeEnd: sc.wholeEnd, wholeWhy: sc.wholeWhy)
        return result
    }

    /// The library size a TTABLE record leaves (its first id + its count), or nil for a
    /// ternary record that writes no table or a payload too short to read (replay counts it as a bad length).
    static func tablesAfter(opcode: UInt8, payloadLen len: Int, at p: Int, _ win: LogWindow) -> Int? {
        switch opcode {
        case Opcode.ttableDefine.rawValue, Opcode.ttablePreset.rawValue:
            return len >= 4 ? Int(win.u32(p)) + 1 : nil
        case Opcode.ttableCompose.rawValue:
            return len >= 8 ? Int(win.u32(p + 4)) + 1 : nil
        case Opcode.ttableBulk.rawValue:
            return len >= 8 ? Int(win.u32(p)) + Int(win.u32(p + 4)) : nil
        default:
            return nil
        }
    }

    /// The SET_LUTS record's payload.
    static func encodeSetLuts(_ sel: DagDBEngine.LutSelection, _ op: DagDBEngine.LutOp) -> Data {
        var d = Data()
        switch sel {
        case let .nodes(lo, hi): d.append(0); appendU64(&d, lo); appendU64(&d, hi)
        case let .rank(lo, hi): d.append(1); appendU64(&d, lo); appendU64(&d, hi)
        }
        switch op {
        case .fill(let v):
            d.append(0); appendU64(&d, v)
        case let .map(mask, pairs):
            d.append(1); appendU64(&d, mask); d.append(UInt8(truncatingIfNeeded: pairs.count))
            for p in pairs { appendU64(&d, p.from); appendU64(&d, p.to) }
        }
        return d
    }

    /// The SET_LUTS record's payload at `p` (`len` bytes), or nil
    /// when its shape is not one the encoder writes (a bad length).
    static func decodeSetLuts(_ data: Data, _ p: Int, _ len: Int) -> (DagDBEngine.LutSelection, DagDBEngine.LutOp)? {
        guard len >= 18 else { return nil }
        let kind = data[p], lo = readU64(data, p + 1), hi = readU64(data, p + 9)
        guard kind <= 1 else { return nil }
        let sel: DagDBEngine.LutSelection = kind == 0 ? .nodes(lo, hi) : .rank(lo, hi)
        switch data[p + 17] {
        case 0:
            guard len == 26 else { return nil }
            return (sel, .fill(readU64(data, p + 18)))
        case 1:
            guard len >= 27 else { return nil }
            let mask = readU64(data, p + 18), k = Int(data[p + 26])
            guard len == 27 + 16 * k else { return nil }
            let pairs = (0..<k).map { DagDBEngine.LutPair(from: readU64(data, p + 27 + 16 * $0),
                                                         to: readU64(data, p + 35 + 16 * $0)) }
            return (sel, .map(mask: mask, pairs: pairs))
        default:
            return nil
        }
    }

    /// The value rules a replayed bulk record of
    /// `opcode` must pass before any byte of it is applied, for the rules
    /// that read only the record's own bytes and the node count. Pure: it
    /// reads `data` and nothing else, so it can be run over a committed
    /// fixture before replay itself uses it. `p` is the payload's start; the
    /// caller has already checked the payload's length and that its node
    /// count `n` (the u32 at `p`) equals `nodeCount`. Returns the refusal's
    /// words (counted and named through replay's `refuse`), or nil.
    ///
/// - 0x14 SET_RANKS_BULK: a rank that does not fit Int (ranks from
///   nodeCount to Int.max replay as logged).
    /// - 0x16 SET_NEIGHBORS_BULK: every one of the 6n slots is -1 (the empty
    ///   slot) or a node id in 0..<nodeCount, the live verb's range rule
    ///   in its words; a slot past it was copied in and a later FOLD RUN read
    ///   `ro[Int(jm)]` out of bounds. S4 (a slot into a register) is not
    ///   here: replay applies it as logged and names it in `warnings`.
    /// - Every other opcode: nil (the ternary bulks' rules read the engine's
    ///   state and run in `applyTernary`; 0x4D, 0x4E, 0x4F and 0x50 run theirs
    ///   inline; a LUT has no value rule).
    public static func bulkValueRefusal(opcode: UInt8, data: Data, payloadStart p: Int, nodeCount: Int) -> String? {
        switch opcode {
        case Opcode.setRanksBulk.rawValue:
            let n = Int(readU32(data, p))
            if let i = (0..<n).first(where: { readU64(data, p + 4 + 8 * $0) > UInt64(Int.max) }) {
                return "SET_RANKS_BULK of \(n): node \(i) rank \(readU64(data, p + 4 + 8 * i)) does not fit Int"
                    + " (above \(Int.max)); nothing applied"
            }
            return nil
        case Opcode.setNeighborsBulk.rawValue:
            let n = Int(readU32(data, p))
            let at = p + 4 - data.startIndex
            let bad: (slot: Int, value: Int32)? = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let base = raw.baseAddress!.advanced(by: at)
                for i in 0..<(n * 6) {
                    let v = base.loadUnaligned(fromByteOffset: 4 * i, as: Int32.self)
                    if v < -1 || Int(v) >= nodeCount { return (i, v) }
                }
                return nil
            }
            guard let b = bad else { return nil }
            return "SET_NEIGHBORS_BULK of \(n): slot \(b.slot) (node \(b.slot / 6) dir \(b.slot % 6))"
                + " neighbour \(b.value) not in -1..<\(nodeCount); nothing applied"
        default:
            return nil
        }
    }

    enum TernaryApply { case applied, badLength, outOfRange, refused(String) }

    /// One v3 record against the engine: shape, range, then the ternary rules'
    /// values against the state the record lands on (the live order of the
    /// log reproduces the state each record was validated against).
    static func applyTernary(engine: DagDBEngine, nodeCount n: Int, opcode: UInt8,
                             data: Data, payloadStart p: Int, payloadLen len: Int) -> TernaryApply {
        let T = TernaryReference.tableSize
        func u32(_ o: Int) -> UInt32 { readU32(data, p + o) }
        func u16(_ o: Int) -> UInt16 { UInt16(data[p + o]) | UInt16(data[p + o + 1]) << 8 }
        func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }
        let truth = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: max(n, 1))
        let reg = engine.isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: max(n, 1))
        // The ternary lanes are allocated on demand: reads never allocate them (unallocated = all BINARY,
        // table id 0); a write does, through the engine's own accessors.
        func modeOf(_ i: Int) -> UInt8 { engine.modeByte(i) }
        func tidOf(_ i: Int) -> UInt16 { engine.ternaryLaneView?.ttableId[i] ?? 0 }
        // The mode-write rules are the handler's, through the one checker
        // so replay applies every rule live applies, the
        // truth-byte rule included; the
        // replay context picks only the words `refusals` carries.
        func modeCheck(_ i: Int, _ m: UInt8) -> String? {
            TernaryReference.modeWriteRefusal(node: i, mode: m, truth: truth[i], isRegister: reg[i] != 0,
                                              ttableId: tidOf(i), tableCount: engine.ttableCount, context: .replay)
        }
        switch opcode {
        case Opcode.setMode.rawValue:
            guard len == 5 else { return .badLength }
            let i = Int(u32(0)); guard i < n else { return .outOfRange }
            let m = data[p + 4]
            if let why = modeCheck(i, m) { return .refused(why) }
            engine.setNodeMode(i, m)
        case Opcode.setTTableId.rawValue:
            guard len == 6 else { return .badLength }
            let i = Int(u32(0)); guard i < n else { return .outOfRange }
            let v = u16(4)
            guard Int(v) < engine.ttableCount else {
                return .refused("node \(i): ttableId \(v) is not below the library size \(engine.ttableCount)")
            }
            engine.ttableIdPtr[i] = v
        case Opcode.setThresh.rawValue:
            guard len == 12 else { return .badLength }
            let i = Int(u32(0)); guard i < n else { return .outOfRange }
            let lo = f32(4), hi = f32(8)
            if let why = TernaryReference.thresholdRefusal(lo: lo, hi: hi) { return .refused("node \(i): \(why)") }
            engine.thrLoPtr[i] = lo; engine.thrHiPtr[i] = hi
        case Opcode.setTrit.rawValue:
            guard len == 5 else { return .badLength }
            let i = Int(u32(0)); guard i < n else { return .outOfRange }
            let t = Int8(bitPattern: data[p + 4])
            guard (-1...1).contains(t) else { return .refused("node \(i): trit \(t) not in -1...1") }
            truth[i] = TernaryReference.byte(ofTrit: Int(t))
        case Opcode.ttableDefine.rawValue:
            guard len == 4 + T else { return .badLength }
            let id = Int(u32(0))
            let bytes = [UInt8](data[(p + 4)..<(p + 4 + T)])
            do { try engine.writeTables(first: id, bytes: bytes) } catch { return .refused(Reply.errorWords(error)) }
        case Opcode.ttablePreset.rawValue:
            guard len == 6 else { return .badLength }
            let id = Int(u32(0))
            guard let preset = TernaryReference.Preset.from(code: data[p + 4]) else {
                return .refused("unknown preset code \(data[p + 4])")
            }
            do {
                let table = try TernaryReference.presetTable(preset, k: Int(data[p + 5]))
                try engine.writeTables(first: id, bytes: table)
            } catch { return .refused(Reply.errorWords(error)) }
        case Opcode.ttableCompose.rawValue:
            guard len == 8 + T else { return .badLength }
            let dst = Int(u32(0)); guard dst < n else { return .outOfRange }
            let id = Int(u32(4))
            guard modeOf(dst) & TernaryReference.kindMask == TernaryReference.kindTTable else {
                return .refused("node \(dst): COMPOSE on tables needs a TTABLE destination")
            }
            let bytes = [UInt8](data[(p + 8)..<(p + 8 + T)])
            do { try engine.writeTables(first: id, bytes: bytes) } catch { return .refused(Reply.errorWords(error)) }
            engine.ttableIdPtr[dst] = UInt16(id)
        case Opcode.setModesBulk.rawValue:
            guard len >= 4 else { return .badLength }
            let c = Int(u32(0)); guard len == 4 + c else { return .badLength }
            guard c == n else { return .outOfRange }
            for i in 0..<n { if let why = modeCheck(i, data[p + 4 + i]) { return .refused(why) } }
            data.withUnsafeBytes { engine.replaceModeLane(from: $0.baseAddress!.advanced(by: p + 4)) }
        case Opcode.setTTableIdsBulk.rawValue:
            guard len >= 4 else { return .badLength }
            let c = Int(u32(0)); guard len == 4 + 2 * c else { return .badLength }
            guard c == n else { return .outOfRange }
            for i in 0..<n where Int(u16(4 + 2 * i)) >= engine.ttableCount {
                return .refused("node \(i): ttableId \(u16(4 + 2 * i)) is not below the library size \(engine.ttableCount)")
            }
            data.withUnsafeBytes { memcpy(engine.ttableIdBuf.contents(), $0.baseAddress!.advanced(by: p + 4), 2 * n) }
        case Opcode.setThreshBulk.rawValue:
            guard len >= 4 else { return .badLength }
            let c = Int(u32(0)); guard len == 4 + 8 * c else { return .badLength }
            guard c == n else { return .outOfRange }
            for i in 0..<n {
                if let why = TernaryReference.thresholdRefusal(lo: f32(4 + 8 * i), hi: f32(8 + 8 * i)) {
                    return .refused("node \(i): \(why)")
                }
            }
            for i in 0..<n { engine.thrLoPtr[i] = f32(4 + 8 * i); engine.thrHiPtr[i] = f32(8 + 8 * i) }
        case Opcode.ttableBulk.rawValue:
            guard len >= 8 else { return .badLength }
            let first = Int(u32(0)), count = Int(u32(4))
            guard len == 8 + T * count else { return .badLength }
            do {
                try data.withUnsafeBytes { raw in
                    let b = UnsafeBufferPointer(start: raw.baseAddress!.advanced(by: p + 8)
                                                    .assumingMemoryBound(to: UInt8.self), count: T * count)
                    try engine.writeTables(first: first, count: count, bytes: b)
                }
            } catch { return .refused(Reply.errorWords(error)) }
        default:
            return .outOfRange
        }
        return .applied
    }

    /// Reset the log to just the header (e.g. after a successful snapshot).
    /// Atomic: writes a fresh header to a tmp file, then renames.
    ///
    /// Why `truncate` refuses while an appender is open. `Data.write(options: [.atomic])` renames a fresh
    /// inode over the path, and a live `Appender` holds an `O_APPEND`
    /// descriptor on the OLD inode — it would keep writing to an unlinked
    /// file and every record between the truncate and the appender's
    /// recreation would be lost with no trace.
    ///
    /// Of the two possible repairs — refuse while an appender is
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
        do { try DaemonFile.atomicWrite(header, to: path) }
        catch { throw WALError.ioFailure(Reply.errorWords(error)) }
    }

    #if DEBUG || DAGDB_FAULT_INJECTION
    /// A test seam (never in a release): runs after the replay's read, before
    /// it takes the log's identity, so a test can swap the file there.
    public static var replayAfterReadForTesting: ((String) -> Void)? = nil
    #endif

    /// What startup's replay found of the log, handed to the appender (one read at boot):
    /// the scan's facts, not the bytes (an older build handed the whole log over, and the boot's result kept it
    /// for the daemon's life): the file's identity and size, its header, and where its whole records end.
    public struct FoundLog {
        public let device: UInt64
        public let inode: UInt64
        public let size: Int
        public let version: UInt32
        public let nodeCount: UInt32
        /// `wholeEnd`'s answer for the bytes found: the offset after which only bytes replay does not apply lie.
        public let wholeEnd: Int
        public let wholeWhy: String
        public init(device: UInt64, inode: UInt64, size: Int, version: UInt32, nodeCount: UInt32, wholeEnd: Int, wholeWhy: String) {
            self.device = device; self.inode = inode; self.size = size; self.version = version; self.nodeCount = nodeCount
            self.wholeEnd = wholeEnd; self.wholeWhy = wholeWhy
        }
    }

    // MARK: - Byte helpers

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        var v = value
        data.append(Data(bytes: &v, count: 4))
    }

    private static func appendU16(_ data: inout Data, _ value: UInt16) {
        var v = value
        data.append(Data(bytes: &v, count: 2))
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
