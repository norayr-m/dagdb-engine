import XCTest
import Darwin
@testable import DagDBDaemonKit

/// The daemon's graceful shutdown runs only between commands.
/// `DagDBShutdownGate` (new with this rule, so this file does not compile
/// before it) is the gate main.swift routes every socket command and
/// the SIGTERM/SIGINT autosave through. A live check sends SIGTERM to a
/// running daemon mid-command; this file pins the gate's own two rules in-process:
/// a shutdown requested while a command runs waits for that command, and a
/// command that has not started when the shutdown is requested is refused,
/// never run. The signal is taken by a DispatchSource on the gate's queue,
/// never on the interrupted thread.
final class EngineDUR3ShutdownGateTests: XCTestCase {

    /// The shutdown body runs after the command in flight returns, and a
    /// command offered after the request is refused without running.
    func testShutdownWaitsForTheCommandInFlightAndRefusesTheNext() {
        let gate = DagDBShutdownGate()
        let inside = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var events: [String] = []
        func note(_ s: String) { lock.lock(); events.append(s); lock.unlock() }
        let done = expectation(description: "command returned")
        DispatchQueue.global().async {
            let r = gate.run {
                note("command start")
                inside.signal()
                usleep(200_000)
                note("command end")
                return "OK"
            }
            XCTAssertEqual(r, "OK")
            done.fulfill()
        }
        inside.wait()
        let shut = expectation(description: "shutdown body ran")
        DispatchQueue.global().async {
            gate.shutdown { note("shutdown body"); shut.fulfill() }
        }
        wait(for: [done, shut], timeout: 5)
        XCTAssertEqual(events, ["command start", "command end", "shutdown body"])
        var ran = false
        XCTAssertNil(gate.run { ran = true; return "OK" })
        XCTAssertFalse(ran, "a command after the shutdown request must not run")
        XCTAssertTrue(gate.isShuttingDown)
        XCTAssertTrue(DagDBShutdownGate.refusal.hasPrefix("ERROR shutdown:"))
    }

    /// A signal taken by the gate's DispatchSource: the body runs on the
    /// gate's queue, after the command that was running when the signal
    /// arrived returned (a raw handler would run it at once, inside it). SIGUSR1 stands in for
    /// SIGTERM (the test process must not be asked to terminate).
    func testSignalSourceRunsTheBodyBetweenCommands() {
        let gate = DagDBShutdownGate()
        let lock = NSLock()
        var events: [String] = []
        func note(_ s: String) { lock.lock(); events.append(s); lock.unlock() }
        let shut = expectation(description: "signal body ran")
        gate.installSignalSources([SIGUSR1]) {
            note("shutdown body")
            shut.fulfill()
        }
        defer { gate.cancelSignalSourcesForTesting(); signal(SIGUSR1, SIG_DFL) }
        let inside = DispatchSemaphore(value: 0)
        let done = expectation(description: "command returned")
        DispatchQueue.global().async {
            _ = gate.run {
                note("command start")
                inside.signal()
                usleep(200_000)
                note("command end")
                return "OK"
            }
            done.fulfill()
        }
        inside.wait()
        kill(getpid(), SIGUSR1)
        wait(for: [done, shut], timeout: 5)
        XCTAssertEqual(events, ["command start", "command end", "shutdown body"])
    }
}
