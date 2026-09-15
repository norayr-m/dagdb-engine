import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// D4 · FRAMING — gate D4 of `docs/contracts/DAEMON_BOUNDS_GATES_FROZEN.md`,
/// audit B finding 1. Driven over a REAL AF_UNIX socket, not against the
/// handler: the defect is in the socket layer, and the socket smoke the
/// ticking contract also owes has never existed until now.
///
/// The server's accept loop is the daemon's own (`SocketServer`, started
/// exactly as `main.swift` starts it) running in-process on a temp socket
/// path, with the same `onCommand` shim over a real `DagDBCommandHandler`.
final class SocketFramingTests: XCTestCase {

    private var server: SocketServer!
    private var fixture: HandlerFixture!
    private var socketPath: String!

    override func setUpWithError() throws {
        // Keep the path short — sun_path is 104 bytes on Darwin.
        socketPath = NSTemporaryDirectory() + "dgb-\(UInt32.random(in: 0..<0xFFFF_FFFF)).sock"
        fixture = try HandlerFixture(side: 4)
        let handler = fixture.handler
        server = SocketServer(path: socketPath)
        server.onCommand = { handler.handle($0) }

        let started = expectation(description: "socket listening")
        let s = server!
        DispatchQueue.global().async {
            started.fulfill()
            try? s.start()
        }
        wait(for: [started], timeout: 5)
        // start() binds before it blocks in accept(); poll for the node.
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: socketPath) {
            usleep(10_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "socket never appeared")
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        fixture = nil
    }

    /// One command, one connection — the daemon's contract. Returns the
    /// reply line with its trailing newline stripped.
    @discardableResult
    private func send(_ payload: [UInt8]) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0, "socket(): \(String(cString: strerror(errno)))")
        defer { close(fd) }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        var sunPath = addr.sun_path
        withUnsafeMutableBytes(of: &sunPath) { buf in
            let bytes = socketPath.utf8CString
            for i in 0..<min(bytes.count, buf.count) { buf[i] = UInt8(bitPattern: bytes[i]) }
        }
        addr.sun_path = sunPath
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(rc, 0, "connect(): \(String(cString: strerror(errno)))")

        // Write in 1 KiB chunks so the server really does see short reads.
        var off = 0
        while off < payload.count {
            let n = payload[off...].prefix(1024).withUnsafeBufferPointer {
                write(fd, $0.baseAddress, $0.count)
            }
            if n <= 0 { break }
            off += n
        }
        shutdown(fd, SHUT_WR)

        var out = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return String(decoding: out, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func line(_ s: String) -> [UInt8] { Array((s + "\n").utf8) }

    // MARK: - the gate

    func testSocketRoundTripsAShortCommand() throws {
        XCTAssertTrue(try send(line("STATUS")).hasPrefix("OK STATUS nodes=16"))
    }

    /// Audit finding 1's own gate: a 5,000-byte `RINGS WRITE` line. The
    /// shipped daemon read 4,095 bytes, trimmed, and parsed the PREFIX as a
    /// complete command — answering `OK` over a truncated float list.
    func testOversizedCommandIsRefusedNotTruncated() throws {
        let floats = Array(repeating: "1.0", count: 1300).joined(separator: " ")
        let cmd = "RINGS WRITE n00000001 \(floats)"
        XCTAssertGreaterThan(cmd.utf8.count, 5_000, "the gate needs a 5,000-byte line")

        let reply = try send(line(cmd))
        XCTAssertEqual(reply, "ERROR too_long: command exceeds 4095 bytes", reply)
        XCTAssertFalse(reply.hasPrefix("OK"), "a truncated prefix must never be parsed")
    }

    /// The cap is a cap on the COMMAND, not on the frame including its
    /// newline: exactly 4,095 bytes plus a newline is still a command.
    func testCommandOfExactlyTheCapIsStillParsed() throws {
        // STATUS plus a comment-free pad of spaces is still just STATUS to
        // the tokenizer, and lands exactly on the cap.
        // 4095 written out, not read off `SocketServer.maxCommandBytes` —
        // the D9 lesson: an expectation taken from the code under test
        // compares the bound to itself.
        let pad = String(repeating: " ", count: 4095 - "STATUS".utf8.count)
        let cmd = "STATUS" + pad
        XCTAssertEqual(cmd.utf8.count, 4095)
        XCTAssertTrue(try send(line(cmd)).hasPrefix("OK STATUS"))

        let overByOne = cmd + " "
        XCTAssertEqual(overByOne.utf8.count, 4096)
        XCTAssertEqual(try send(line(overByOne)), "ERROR too_long: command exceeds 4095 bytes")
    }

    /// Post-merge follow-up F7. The over-long tail is NOT drained: the read
    /// stops at the cap, the refusal is written, and the descriptor closes.
    /// This server serves ONE command per connection (`handleClient` closes
    /// on return), so "a second command on the same connection" is not a
    /// shape it has — what a refused over-long command must not do is wedge
    /// or kill the single-threaded accept loop, leaving the NEXT connection
    /// unserved. That is what this drives: the refusal, then an ordinary
    /// command on a fresh connection, then a second refusal, then another
    /// ordinary command.
    func testTheAcceptLoopKeepsServingAfterARefusedOverLongCommand() throws {
        let floats = Array(repeating: "1.0", count: 1300).joined(separator: " ")
        let overLong = "RINGS WRITE n00000001 \(floats)"
        XCTAssertGreaterThan(overLong.utf8.count, 5_000)

        XCTAssertEqual(try send(line(overLong)), "ERROR too_long: command exceeds 4095 bytes")
        XCTAssertTrue(try send(line("STATUS")).hasPrefix("OK STATUS nodes=16"))
        XCTAssertEqual(try send(line(overLong)), "ERROR too_long: command exceeds 4095 bytes")
        let after = try send(line("TRAVERSE FROM 0 DEPTH 2"))
        XCTAssertTrue(after.hasPrefix("OK TRAVERSE"), after)
    }

    /// A short read must be completed by reading again until the newline —
    /// AF_UNIX may split a write even well under the cap. The client above
    /// writes in 1 KiB chunks with no delay; this one adds a stall in the
    /// middle so the first `read()` can only return a fragment.
    func testShortReadIsCompletedRatherThanParsedAsAWholeCommand() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        var sunPath = addr.sun_path
        withUnsafeMutableBytes(of: &sunPath) { buf in
            let bytes = socketPath.utf8CString
            for i in 0..<min(bytes.count, buf.count) { buf[i] = UInt8(bitPattern: bytes[i]) }
        }
        addr.sun_path = sunPath
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        // "TRAVERSE FROM 0 DEPT" … stall … "H 2\n". A parse of the first
        // fragment alone is `ERROR unknown_command`, so an OK reply is proof
        // the server waited for the newline.
        let head = Array("TRAVERSE FROM 0 DEPT".utf8)
        _ = head.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        usleep(150_000)
        let tail = Array("H 2\n".utf8)
        _ = tail.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        shutdown(fd, SHUT_WR)

        var out = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        let reply = String(decoding: out, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(reply.hasPrefix("OK TRAVERSE"),
                      "a short read was parsed as a whole command: \(reply)")
    }
}
