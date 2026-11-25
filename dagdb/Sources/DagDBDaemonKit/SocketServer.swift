/// SocketServer — Unix Domain Socket listener for DagDB daemon.
///
/// Listens on /tmp/dagdb.sock for DSL commands from Postgres backends.
/// Single-threaded accept loop with per-command dispatch.
/// Commands are newline-delimited text. Responses are newline-delimited.
/// One command per connection, unless the first line is `PIPELINE`:
/// then every following line, answered in order.
///
/// Lives in DagDBDaemonKit rather than the daemon executable so the framing
/// rules can be driven over a real AF_UNIX socket from the test suite. `main.swift` is
/// unchanged: it already imports DagDBDaemonKit and constructs this the
/// same way.

import Foundation
import DagDB

public final class SocketServer {
    /// The frame. A command is at most this many bytes, followed by a
    /// newline; a line that reaches the cap without one is REFUSED, never
    /// parsed as a complete command (the prefix used to
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
    /// The line being answered, exactly as received (decoded, before the trim),
    /// for the daemon log's record of the command.
    public private(set) var currentLine = ""

    public init(path: String = "/tmp/dagdb.sock") {
        self.path = path
    }

    /// Start listening. Blocks the calling thread.
    public func start() throws {
        // SIGPIPE is ignored process-wide. A
        // write to a peer that is gone must report EPIPE to the writer, never
        // kill the daemon — whether or not `SO_NOSIGPIPE` could be set on the
        // socket (it cannot on one whose peer closed before accept). The
        // daemon's `main.swift` ignores it at start too; doing it here as well
        // covers every embedding of this server.
        Self.ignoreSIGPIPE()

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
        print(Reply.line("  Socket listening on \(path)"))

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

    /// The line that turns a connection into a pipeline.
    /// Sent as the FIRST line, it is acknowledged with `pipelineAck`; every
    /// line after it is a command, answered in order on the same connection
    /// until the client half-closes (or closes). Without it a connection is
    /// one command, exactly as before — so a client that never half-closes
    /// (`echo X | nc -U`) still gets its EOF after its one reply.
    public static let pipelineLine = "PIPELINE"
    public static let pipelineAck = "OK PIPELINE"

    /// Handle one client connection. Read command, dispatch, respond, close —
    /// or, after `PIPELINE`, every command in turn.
    ///
    /// Framing. The old body did ONE `read()` of at most 4,095 bytes,
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
        // daemon. Two layers: SIGPIPE is ignored
        // process-wide (`start()`), so a write to a gone peer returns EPIPE;
        // and `SO_NOSIGPIPE` is set per socket. The setsockopt FAILS (EINVAL)
        // on a socket whose peer closed before this loop accepted it — a
        // client queued behind a busy connection that gave up. In earlier builds the
        // failure was ignored and the reply's write killed the daemon with
        // SIGPIPE (exit 141). Now a failed setsockopt drops the connection,
        // logged, before anything is read or run: there is no one to answer.
        var one: Int32 = 1
        if setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            let e = errno
            Self.logDrop("setsockopt(SO_NOSIGPIPE) failed: \(String(cString: strerror(e))) (errno \(e); the client closed before accept)")
            return
        }

        var reader = LineReader(fd: clientFd)
        var pipelined = false
        while true {
            let line: [UInt8]
            switch reader.next() {
            case .eof:
                return
            case .overLong:
                // The cap, reached without a newline. The command is refused,
                // never parsed, and the read stops HERE — the tail is NOT
                // drained (the comment that used to
                // claim it was is withdrawn). Three reasons not to drain it:
                //   * the connection closes as soon as the refusal is written
                //     (the `defer` above) — in a pipeline too: the frame
                //     cannot be resynchronised without reading the tail — so
                //     a drained tail would be discarded by the close anyway;
                //   * the tail is unbounded and this is the single threaded
                //     accept loop: draining would let one client hold the
                //     loop for as long as it cared to keep writing — the
                //     wedge that the per-command work caps narrow for
                //     SIMILAR_DECISIONS, CLOCK ADVANCE and BANK NOISE;
                //   * the daemon does not die on the client's side of this:
                //     SIGPIPE is ignored process-wide and `SO_NOSIGPIPE` is
                //     set above (a socket where it cannot be set is dropped
                //     before this point), so a write to a gone client is an
                //     EPIPE that ends the connection, which is what the drain
                //     was for. A client still writing when the reply lands
                //     takes EPIPE on its own write and can still read the
                //     refusal.
                _ = writeLine(clientFd, Self.tooLongRefusal)
                return
            case .line(let l):
                line = l
            }
            // A line holding a control character (tab aside: C0, DEL, C1, U+2028, U+2029)
            // is refused by name on its raw bytes, before the trim and before any parse; the refusal names the
            // class and the byte offset and never echoes the bytes. In a pipeline it answers that line alone.
            if let refusal = Reply.inputRefusal(line) {
                Self.logInput(refusal)
                guard writeLine(clientFd, refusal) else { return }
                if pipelined { continue }
                return
            }
            currentLine = String(decoding: line, as: UTF8.self)
            let command = currentLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pipelined {
                // A client that closed without sending a newline and without
                // reaching the cap sent nothing this server can act on.
                // (`next()` returns a final unterminated fragment as a line,
                // as the old loop parsed it.)
                guard !command.isEmpty else { return }
                if command == Self.pipelineLine && reader.lineNumber == 1 {
                    pipelined = true
                    guard writeLine(clientFd, Self.pipelineAck) else { return }
                    continue
                }
                _ = writeLine(clientFd, onCommand?(command) ?? "ERROR unknown command")
                return            // one command per connection
            }
            // Pipelined: an empty line is no command (as on its own
            // connection, where it is answered with nothing).
            if command.isEmpty { continue }
            guard writeLine(clientFd, onCommand?(command) ?? "ERROR unknown command") else { return }
        }
    }

    /// Write one reply line whole (a short write is continued). False when
    /// the write fails — EPIPE (the client is gone; SIGPIPE is ignored and
    /// `SO_NOSIGPIPE` set, so it is a return value, never a signal) or any
    /// other error: the connection is dropped, logged, and the loop goes on.
    private func writeLine(_ fd: Int32, _ response: String) -> Bool {
        // Asserted here — a reply that did not come through `Reply.line` (an embedder's
        // own `onCommand`) is formatted now, and the bypass is logged; the wire carries one line either way.
        var out = response
        if !Reply.isLine(out) {
            out = Reply.line(out)
            print(Reply.line("  reply formatted by the socket writer: it did not come through Reply.line (the connection goes on)"))
        }
        let bytes = Array((out + "\n").utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 {
                let e = errno
                Self.logDrop(n < 0 ? "write failed: \(String(cString: strerror(e))) (errno \(e))"
                                   : "write returned 0")
                return false
            }
            off += n
        }
        return true
    }

    /// SIGPIPE ignored for the whole process. Idempotent.
    public static func ignoreSIGPIPE() {
        signal(SIGPIPE, SIG_IGN)
    }

    /// A connection given up on — never fatal, always logged (one line in
    /// the daemon's log, beside the command lines).
    static func logDrop(_ why: String) {
        print(Reply.line("  connection dropped: \(why)"))
    }

    /// An input refusal in the daemon's log (the refusal names the character, never the bytes).
    static func logInput(_ refusal: String) {
        print(Reply.line("  [-] (a command refused before parsing) → \(refusal)"))
    }

    /// Newline framing over a socket: each `next()` is one line (without its
    /// newline), the cap refusal, or EOF. Bytes after a newline stay buffered
    /// for the next line — a pipeline's commands may share a read.
    struct LineReader {
        let fd: Int32
        private var buf = [UInt8](repeating: 0, count: 1024)
        private var have = 0, at = 0
        private var eof = false
        private(set) var lineNumber = 0

        init(fd: Int32) { self.fd = fd }

        enum Item { case line([UInt8]), overLong, eof }

        mutating func next() -> Item {
            var line = [UInt8]()
            while true {
                if at == have {
                    if eof { break }
                    let n = read(fd, &buf, buf.count)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { eof = true; break }   // EOF or error
                    have = n; at = 0
                }
                while at < have {
                    let byte = buf[at]
                    at += 1
                    if byte == 0x0A { lineNumber += 1; return .line(line) }   // the frame's terminator
                    if line.count == SocketServer.maxCommandBytes { return .overLong }
                    line.append(byte)
                }
            }
            // EOF: an unterminated fragment is handed back as the old loop
            // parsed it (and the caller ends the connection after it).
            if line.isEmpty { return .eof }
            lineNumber += 1
            return .line(line)
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
