/// SocketServer — Unix Domain Socket listener for DagDB daemon.
///
/// Listens on /tmp/dagdb.sock for DSL commands from Postgres backends.
/// Single-threaded accept loop with per-command dispatch.
/// Commands are newline-delimited text. Responses are newline-delimited.

import Foundation

final class SocketServer {
    let path: String
    var serverFd: Int32 = -1
    var running = false
    var onCommand: ((String) -> String)?

    init(path: String = "/tmp/dagdb.sock") {
        self.path = path
    }

    /// Start listening. Blocks the calling thread.
    func start() throws {
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
    private func handleClient(_ clientFd: Int32) {
        defer { close(clientFd) }

        // Read command (up to 4KB, newline-terminated)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(clientFd, &buffer, buffer.count - 1)
        guard n > 0 else { return }

        let command = String(bytes: buffer[0..<n], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !command.isEmpty else { return }

        // Dispatch
        let response = onCommand?(command) ?? "ERROR unknown command"

        // Write response
        let responseBytes = (response + "\n").utf8
        _ = responseBytes.withContiguousStorageIfAvailable { ptr in
            write(clientFd, ptr.baseAddress, ptr.count)
        }
    }

    func stop() {
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

    enum SocketError: Error, CustomStringConvertible {
        case createFailed(errno: Int32)
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)

        var description: String {
            switch self {
            case .createFailed(let e): return "socket() failed: \(String(cString: strerror(e)))"
            case .bindFailed(let e): return "bind() failed: \(String(cString: strerror(e)))"
            case .listenFailed(let e): return "listen() failed: \(String(cString: strerror(e)))"
            }
        }
    }
}
