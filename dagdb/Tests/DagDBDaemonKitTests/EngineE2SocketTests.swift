import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Pipelined connections, over a REAL AF_UNIX socket. Two daemons' accept loops
/// (`SocketServer`, as `main.swift` starts it) run in-process over two
/// handlers built identically. A 1,000-command mixed script goes to one as
/// one command per connection, to the other on ONE connection after the
/// `PIPELINE` line; the second stream's replies, after the `OK PIPELINE`
/// acknowledgement, are byte-identical and in order to the concatenation of
/// the first's. The script avoids the verbs whose reply carries a wall-clock
/// time (TICK, SAVE, LOAD, IMPORT, EXPORT, BFS_DEPTHS, ANCESTRY …): their bytes differ run to run on
/// any transport.
final class EngineE2SocketTests: XCTestCase {

    final class Daemon {
        let fixture: HandlerFixture
        let server: SocketServer
        let path: String
        init(side: Int) throws {
            path = NSTemporaryDirectory() + "e2-\(UInt32.random(in: 0..<0xFFFF_FFFF)).sock"
            fixture = try HandlerFixture(side: side)
            let h = fixture.handler
            server = SocketServer(path: path)
            server.onCommand = { h.handle($0) }
            let s = server
            DispatchQueue.global().async { try? s.start() }
            for _ in 0..<300 where !FileManager.default.fileExists(atPath: path) { usleep(10_000) }
        }
        deinit { server.stop() }
    }

    static func connect(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        var sunPath = addr.sun_path
        withUnsafeMutableBytes(of: &sunPath) { buf in
            let bytes = path.utf8CString
            for i in 0..<min(bytes.count, buf.count) { buf[i] = UInt8(bitPattern: bytes[i]) }
        }
        addr.sun_path = sunPath
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return fd
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            off += n
        }
    }

    static func readToEOF(_ fd: Int32) -> [UInt8] {
        var out = [UInt8](), buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    /// One command per connection (the house clients' shape: write the line,
    /// half-close, read to EOF). The raw reply bytes.
    static func single(_ path: String, _ line: String) -> [UInt8] {
        let fd = connect(path)
        defer { close(fd) }
        writeAll(fd, Array((line + "\n").utf8))
        shutdown(fd, SHUT_WR)
        return readToEOF(fd)
    }

    /// Every line on ONE connection: a writer thread sends while this thread
    /// reads (a client that wrote everything before reading would deadlock
    /// against full socket buffers on any pipelined protocol), then half-closes.
    static func pipelined(_ path: String, _ lines: [String], chunk: Int = 7) -> [UInt8] {
        let fd = connect(path)
        defer { close(fd) }
        let payload = Array(lines.map { $0 + "\n" }.joined().utf8)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            // Odd-sized pieces, so lines straddle reads on the server side.
            var off = 0
            while off < payload.count {
                let end = min(payload.count, off + chunk * 97)
                writeAll(fd, Array(payload[off..<end]))
                off = end
            }
            shutdown(fd, SHUT_WR)
            done.signal()
        }
        let out = readToEOF(fd)
        done.wait()
        return out
    }

    /// The 1,000-command mixed script: writes, reads, refusals and unknown
    /// lines, deterministic, over a side-16 graph (256 nodes).
    static func script(count: Int = 1000) -> [String] {
        var g = EngineE1DaemonTests.Rng(s: 0xE23)
        var out: [String] = []
        for i in 0..<16 { out.append("SET \(i) RANK \(4 + i % 4)") }
        while out.count < count {
            let a = g.below(256), b = g.below(256)
            switch g.below(22) {
            case 0: out.append("SET \(a) TRUTH \(g.below(2))")
            case 1: out.append("SET \(a) RANK \(g.below(8))")
            case 2: out.append("SET \(a) LUT \(["AND", "OR", "XOR", "MAJ", "NOR", "0xF0F0"][g.below(6)])")
            case 3: out.append("CONNECT FROM \(a) TO \(b)")
            case 4: out.append("CONNECT BACK FROM \(a) TO \(b)")
            case 5: out.append("GET \(a) TRUTH")
            case 6: out.append("GET \(a) TRIT")
            case 7: out.append("GRAPH INFO")
            case 8: out.append("STATUS")
            case 9: out.append("NODES AT RANK \(g.below(8))")
            case 10: out.append("TRAVERSE FROM \(a) DEPTH \(1 + g.below(3))")
            case 11: out.append("SELECT TRUTH 1 RANK 0-7")
            case 12: out.append("VALIDATE")
            case 13: out.append("CLEAR \(a) EDGES")
            case 14: out.append("CLEAR \(a) BACK_EDGES")
            case 15: out.append("SET \(a + 300) TRUTH 1")                    // out of range
            case 16: out.append("FROBNICATE \(a)")                          // unknown
            case 17: out.append("TRUTH_SLICE NODES 0-255")
            case 18: out.append("SET \(a) WEIGHT \(g.below(6)) \(Float(g.below(100)) / 10)")
            case 19: out.append("SET \(a) VALUE \(Float(g.below(200)) / 100 - 1)")
            case 20: out.append("CONNECT_BACK_BULK")                          // shm as the last reader left it
            default: out.append("COMPOSE AND \(a) \(b) INTO \(g.below(256))")
            }
        }
        return out
    }

    func testE2_3PipelinedRepliesAreByteIdenticalAndInOrder() throws {
        let lines = Self.script()
        XCTAssertEqual(lines.count, 1000)
        let one = try Daemon(side: 16), many = try Daemon(side: 16)

        var expected = [UInt8]()
        var perLine: [[UInt8]] = []
        for l in lines {
            let r = Self.single(one.path, l)
            perLine.append(r)
            expected += r
        }
        let got = Self.pipelined(many.path, ["PIPELINE"] + lines)
        let ack = Array("OK PIPELINE\n".utf8)
        let head = Array(got.prefix(ack.count))
        let body = Array(got.dropFirst(ack.count))
        // Where the streams first differ, by line, for the failure message.
        var firstDiff = "none"
        if body != expected {
            let gotLines = String(decoding: body, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            for (i, r) in perLine.enumerated() {
                let want = String(decoding: r, as: UTF8.self).trimmingCharacters(in: .newlines)
                let have = i < gotLines.count ? String(gotLines[i]) : "<missing>"
                if want != have { firstDiff = "line \(i) '\(lines[i])': want '\(want)' got '\(have)'"; break }
            }
        }
        let kinds = Set(lines.map { $0.split(separator: " ").first.map(String.init) ?? "" })
        let oks = perLine.filter { $0.starts(with: Array("OK".utf8)) }.count
        print("E2.3 pipelined: \(lines.count) commands, \(kinds.count) verbs, \(oks) OK / \(lines.count - oks) refusals; "
              + "single-connection bytes=\(expected.count) pipelined bytes=\(body.count) ack='\(String(decoding: head, as: UTF8.self).trimmingCharacters(in: .newlines))' "
              + "identical=\(body == expected) first_diff=\(firstDiff)")
        XCTAssertEqual(head, ack)
        XCTAssertEqual(body, expected, firstDiff)
        // The two daemons end in the same state.
        XCTAssertEqual(one.fixture.handler.engine.readTruthStates(), many.fixture.handler.engine.readTruthStates())
        XCTAssertEqual(one.fixture.handler.engine.readRanks(), many.fixture.handler.engine.readRanks())
    }

    /// Without the PIPELINE line the server keeps its old shape exactly: one
    /// command per connection, the rest of the bytes unread — so a client that
    /// never half-closes (`echo X | nc -U`) still gets its EOF.
    func testE2_3WithoutPipelineOneCommandPerConnectionStays() throws {
        let d = try Daemon(side: 4)
        let fd = Self.connect(d.path)
        defer { close(fd) }
        Self.writeAll(fd, Array("STATUS\nGET 1 TRUTH\n".utf8))
        // No half-close: the server must close on its own after one reply.
        let out = String(decoding: Self.readToEOF(fd), as: UTF8.self)
        XCTAssertTrue(out.hasPrefix("OK STATUS nodes=16"), out)
        XCTAssertEqual(out.filter { $0 == "\n" }.count, 1, out)
    }

    /// In a pipeline an over-long line is refused by name and the connection
    /// closes (the frame cannot be resynchronised without reading the tail);
    /// the replies before it stand, the accept loop keeps serving.
    func testE2_3PipelineOverLongLineRefusesAndCloses() throws {
        let d = try Daemon(side: 4)
        let long = "RINGS WRITE n1 " + Array(repeating: "1.0", count: 1300).joined(separator: " ")
        let out = String(decoding: Self.pipelined(d.path, ["PIPELINE", "GET 1 TRUTH", long, "GET 2 TRUTH"]), as: UTF8.self)
        XCTAssertEqual(out, "OK PIPELINE\nOK GET node=1 truth=0\nERROR too_long: command exceeds 4095 bytes\n")
        XCTAssertTrue(String(decoding: Self.single(d.path, "STATUS"), as: UTF8.self).hasPrefix("OK STATUS"))
    }

    /// A pipelining client that stops reading and hangs up must not kill or
    /// wedge the daemon (SO_NOSIGPIPE; the write's EPIPE ends the connection).
    func testE2_3PipelineClientHangsUpMidStream() throws {
        let d = try Daemon(side: 16)
        let fd = Self.connect(d.path)
        let lines = ["PIPELINE"] + Array(repeating: "GRAPH INFO", count: 3000)
        Self.writeAll(fd, Array(lines.map { $0 + "\n" }.joined().utf8.prefix(2_000)))
        close(fd)
        usleep(200_000)
        XCTAssertTrue(String(decoding: Self.single(d.path, "STATUS"), as: UTF8.self).hasPrefix("OK STATUS"))
    }
}
