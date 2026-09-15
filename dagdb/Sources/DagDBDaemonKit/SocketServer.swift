/// SocketServer — Unix Domain Socket listener for DagDB daemon.
///
/// Listens on /tmp/dagdb.sock for DSL commands from Postgres backends.
/// Single-threaded accept loop with per-command dispatch.
/// Commands are newline-delimited text. Responses are newline-delimited.
///
/// Lives in DagDBDaemonKit rather than the daemon executable so the FRAMING
/// contract (gate D4, docs/contracts/DAEMON_BOUNDS_GATES_FROZEN.md) can be
/// driven over a real AF_UNIX socket from the test suite. `main.swift` is
/// unchanged: it already imports DagDBDaemonKit and constructs this the
/// same way.

import Foundation

public final class SocketServer {
    /// The frame. A command is at most this many bytes, followed by a
    /// newline; a line that reaches the cap without one is REFUSED, never
    /// parsed as a complete command (audit B finding 1: the prefix used to
    /// be trimmed and dispatched, so `RINGS WRITE` with a long float list
    /// or `SAVE <long path>` was answered `OK` over a truncated value).
    public static let maxCommandBytes = 4095
    /// The one refusal wording; both Python clients print it verbatim
    /// rather than send a line the daemon would have to truncate.
    public static let tooLongRefusal = "ERROR too_long: command exceeds \(SocketServer.maxCommandBytes) bytes"

    public let path: String
    var serverFd: Int32 = -1
    var running = false
    public var onCommand: ((String) -> String)?

    public init(path: String = "/tmp/dagdb.sock") {
        self.path = path
    }

    /// Start listening. Blocks the calling thread.
    public func start() throws {
        // Remove stale socket
        unlink(path)

        // Create socket
        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            throw SocketError.createFailed(errno: errno)
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // Copy path bytes into sun_path tuple
        var sunPath = addr.sun_path
        withUnsafeMutableBytes(of: &sunPath) { buf in
            let pathBytes = path.utf8CString
            let count = min(pathBytes.count, buf.count)
            for i in 0..<count {
                buf[i] = UInt8(bitPattern: pathBytes[i])
            }
        }
        addr.sun_path = sunPath

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverFd)
            throw SocketError.bindFailed(errno: errno)
        }

        // Tighten perms — 0600. AF_UNIX connect() checks this on macOS/Linux,
        // so hostile local users cannot connect even if they can stat the path.
        _ = chmod(path, 0o600)

        // Listen
        guard listen(serverFd, 16) == 0 else {
            close(serverFd)
            throw SocketError.listenFailed(errno: errno)
        }

        running = true
        print("  Socket listening on \(path)")

        // Accept loop
        while running {
            let clientFd = accept(serverFd, nil, nil)
            guard clientFd >= 0 else {
                if !running { break }  // clean shutdown
                continue
            }
            handleClient(clientFd)
        }
    }

    /// Handle one client connection. Read command, dispatch, respond, close.
    ///
    /// D4 · FRAMING. The old body did ONE `read()` of at most 4,095 bytes,
    /// trimmed whatever came back, and parsed it as a complete command. Two
    /// ways that lied: a DSL line longer than the frame (`RINGS WRITE`
    /// takes an arbitrary float list, `SAVE` an arbitrary path) was
    /// silently truncated and the PREFIX was executed; and AF_UNIX may
    /// return a short read even well under the cap, so a perfectly legal
    /// command could be cut at an arbitrary byte. Now: read until the
    /// newline, refuse at the cap by name, and never parse a line that
    /// reached the cap without one.
    private func handleClient(_ clientFd: Int32) {
        defer { close(clientFd) }

        // A client that hangs up while we are replying must not kill the
        // daemon with SIGPIPE — the write below reports EPIPE instead.
        var one: Int32 = 1
        _ = setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var line = [UInt8]()
        line.reserveCapacity(256)
        var chunk = [UInt8](repeating: 0, count: 1024)
        var overLong = false

        readLoop: while true {
            let n = read(clientFd, &chunk, chunk.count)
            if n <= 0 { break }                       // EOF or error
            for i in 0..<n {
                let byte = chunk[i]
                if byte == 0x0A { break readLoop }    // the frame's terminator
                if line.count == Self.maxCommandBytes {
                    // The cap, reached without a newline. The command is
                    // refused, never parsed, and the read stops HERE — the
                    // tail is NOT drained (post-merge follow-up F7; the
                    // comment that used to claim it was is withdrawn).
                    // Three reasons not to drain it:
                    //   * this is one command per connection — the `defer`
                    //     above closes the descriptor as soon as the refusal
                    //     is written, so a drained tail would be discarded by
                    //     the close anyway;
                    //   * the tail is unbounded and this is the single
                    //     threaded accept loop: draining would let one client
                    //     hold the loop for as long as it cared to keep
                    //     writing — the wedge gate D8 narrows;
                    //   * `SO_NOSIGPIPE` is set above, so a client still
                    //     writing when the reply lands takes EPIPE on its own
                    //     write and can still read the refusal. The daemon
                    //     does not die, which is what the drain was for.
                    overLong = true
                    break readLoop
                }
                line.append(byte)
            }
        }

        let response: String
        if overLong {
            response = Self.tooLongRefusal
        } else {
            let command = String(decoding: line, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A client that closed without sending a newline and without
            // reaching the cap sent nothing this server can act on.
            guard !command.isEmpty else { return }
            response = onCommand?(command) ?? "ERROR unknown command"
        }

        // Write response
        let responseBytes = (response + "\n").utf8
        _ = responseBytes.withContiguousStorageIfAvailable { ptr in
            write(clientFd, ptr.baseAddress, ptr.count)
        }
    }

    public func stop() {
        running = false
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
        unlink(path)
    }

    deinit {
        stop()
    }

    public enum SocketError: Error, CustomStringConvertible {
        case createFailed(errno: Int32)
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)

        public var description: String {
            switch self {
            case .createFailed(let e): return "socket() failed: \(String(cString: strerror(e)))"
            case .bindFailed(let e): return "bind() failed: \(String(cString: strerror(e)))"
            case .listenFailed(let e): return "listen() failed: \(String(cString: strerror(e)))"
            }
        }
    }
}
