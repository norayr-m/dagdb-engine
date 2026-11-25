import Foundation

/// The daemon's graceful shutdown
/// runs only BETWEEN commands.
///
/// In earlier builds `main.swift` installed the shutdown as a raw `signal()`
/// handler, so the autosave ran on whatever thread the signal interrupted —
/// the socket thread, in the middle of a command: (a) a command half-applied
/// to the engine was snapshotted and bound, and recovery was a mixture of the
/// state before and after it; (b) a signal that landed inside a WAL append
/// ran `barrier()`, which re-entered the appender's serial queue from inside
/// it, and libdispatch trapped (SIGTRAP): no autosave at all.
///
/// The gate: every socket command runs through `run`, under one lock; the
/// signal is taken by a `DispatchSourceSignal` on the gate's own queue (the
/// signal's disposition is set to ignore, so it never interrupts a thread),
/// and its handler calls `shutdown`, which first marks the shutdown (a
/// command that has not taken the lock yet is refused, never run), then
/// waits for the lock — the command in flight completes — and runs the body
/// (the WAL barrier, the autosave, `exit`) with no command running. The body
/// runs on the gate's queue, never on the appender's, so the barrier cannot
/// re-enter it.
public final class DagDBShutdownGate {
    /// The reply to a command offered after the shutdown began.
    public static let refusal = "ERROR shutdown: the daemon is shutting down; the command was not run"

    private let commandLock = NSLock()
    private let flagLock = NSLock()
    private var requested = false
    private var sources: [DispatchSourceSignal] = []
    private let queue = DispatchQueue(label: "dagdb.shutdown")

    public init() {}

    public var isShuttingDown: Bool {
        flagLock.lock(); defer { flagLock.unlock() }
        return requested
    }

    /// Run one command, never during the shutdown. nil when the shutdown has
    /// begun: the command was not run (the caller replies `refusal`).
    public func run(_ command: () -> String) -> String? {
        if isShuttingDown { return nil }
        commandLock.lock()
        defer { commandLock.unlock() }
        // Marked while this command waited for the lock: not run.
        if isShuttingDown { return nil }
        return command()
    }

    /// Mark the shutdown, wait for the command in flight, then run `body`
    /// with no command running. The daemon's body ends in `exit`; the lock is
    /// released only if it returns.
    public func shutdown(_ body: () -> Void) {
        flagLock.lock(); requested = true; flagLock.unlock()
        commandLock.lock()
        defer { commandLock.unlock() }
        body()
    }

    /// Take `signals` through dispatch sources on the gate's queue: each
    /// signal's disposition is set to ignore first (a raw handler or the
    /// default action would act on the interrupted thread), and every
    /// delivery runs `shutdown(body)` there.
    public func installSignalSources(_ signals: [Int32], _ body: @escaping () -> Void) {
        for s in signals {
            signal(s, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: s, queue: queue)
            src.setEventHandler { [weak self] in self?.shutdown(body) }
            src.resume()
            sources.append(src)
        }
    }

    /// Tests only: cancel the sources (the dispositions stay ignored).
    func cancelSignalSourcesForTesting() {
        for s in sources { s.cancel() }
        sources = []
    }
}
