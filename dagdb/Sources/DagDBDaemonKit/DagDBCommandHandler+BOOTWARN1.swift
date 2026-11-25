import Foundation
import DagDB

/// The WAL records inputs, not ticks, so a restart after unsaved ticks comes back
/// at the pre-tick truth. Each tick-family command that ran (TICK, TICK_SYNC,
/// TICK UNTIL_STABLE, EVAL) leaves one advisory TICK_NOTE carrying the tick
/// total it left, and the boot sets the last note against the loaded
/// snapshot's tick count (`DagDBStartup.tickHistoryLine`).
extension DagDBCommandHandler {

    /// The note after a tick command: written when the command ran (an `OK`
    /// reply, or a tick total that moved before an error such as a GPU
    /// failure); a refusal that ticked nothing writes none. Never changes the
    /// reply, except to name a note that could not be written. A version-1
    /// log takes no note (`DagDBWAL.Appender.tickNote`); its boot says the
    /// tick history is unknown.
    func noteTicks(_ reply: String, before: UInt32) -> String {
        guard let w = walAppender, w.fileVersion >= DagDBWAL.versionV2 else { return reply }
        guard reply.hasPrefix("OK") || tickCount != before else { return reply }
        do {
            try w.tickNote(total: UInt64(tickCount))
            // A note behind an ERROR (a GPU
            // failure after some ticks ran) is a change, so it is named.
            if reply.hasPrefix("ERROR") { return reply + "; WAL: one TICK_NOTE (13 B) logged, the tick total \(tickCount)" }
            return reply
        } catch {
            return reply + " WARN wal: tick note not written (\(Reply.errorWords(error))); a restart may report fewer lost ticks than were run"
        }
    }

    /// A command other than a tick moved the counter, up or
    /// down, and no durable snapshot succeeded in it (a LOAD or LOAD JSON
    /// whose rebase failed, or a loader with no startup snapshot to rebase
    /// to): one COUNTER_DROP (0x53, the counter after the change), so the
    /// boot reports the tick history unknown instead of setting later notes
    /// against the snapshot. A v1 log takes none (as with notes).
    func noteCounterDrop(_ reply: String, before: UInt32, snapshotsBefore: Int) -> String {
        guard tickCount != before, durableSnapshotsWritten == snapshotsBefore,
              let w = walAppender, w.fileVersion >= DagDBWAL.versionV2 else { return reply }
        do {
            try w.counterDrop(total: UInt64(tickCount))
            // Behind an ERROR (a
            // loader whose rebase failed) the note is a change, so it is named.
            if reply.hasPrefix("ERROR") {
                return reply + "; WAL: one COUNTER_DROP note (13 B) logged, because the tick counter moved to \(tickCount)"
                    + " without a durable rebase; the boot after a restart names it"
            }
            return reply
        } catch {
            return reply + " WARN wal: counter drop marker not written (\(Reply.errorWords(error))); a restart may report a false count"
        }
    }
}
