import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// One command in, one honest line out, the same on every daemon. In-process checks: the source lint, the formatter, the input refusal, the one error function,
/// and the handler's own replies. The live checks run against release daemons.
///
/// Amateur engineering project; no competitive claims; errors likely.
final class EngineREPLY1Tests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = DaemonFile.canonicalRoot(NSTemporaryDirectory())! + "/reply1-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let r = root { try? FileManager.default.removeItem(atPath: r) }
    }

    // MARK: - The source lint (REPLY1Lint.swift)

    static var sourcesDir: String {
        // <repo>/dagdb/Tests/DagDBDaemonKitTests/EngineREPLY1Tests.swift -> <repo>/dagdb/Sources
        let here = URL(fileURLWithPath: #filePath)
        return here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources").path
    }

    func testR16SourceLintRefusesErrorTextInsideReplyLiterals() throws {
        let files = REPLY1Lint.sources(Self.sourcesDir)
        XCTAssertTrue(files.contains { $0.rel == "DagDBDaemon/main.swift" }, "main.swift is read")
        XCTAssertTrue(files.contains { $0.rel == "DagDB/Reply.swift" } && files.contains { $0.rel == "DagDBDaemonKit/SocketServer.swift" })
        XCTAssertGreaterThan(files.count, 80, "every daemon source, at any depth")
        let hits = REPLY1Lint.lint(files: files)
        XCTAssertEqual(hits.map(\.description), [], "an error's own text in a reply or a log line:\n"
                       + hits.map(\.description).joined(separator: "\n"))
    }

    /// A planted source file (an independent check's, copied verbatim): eleven forms, one per
    /// line marked P01–P11. The check: every one is caught.
    static let verifierPlant = #"""
// verifier plant: never compiled (the test binary is prebuilt); the R1.6 lint reads source text at test time.
import Foundation
enum ZZVerifierPlant {
    static func p01(_ error: Error) -> String { return "ERROR io: load: \(error)" }                 // P01 the literal form
    static func p02(_ e: Error) -> String { return "ERROR io: load: \(e)" }                         // P02 another name
    static func p03(_ error: Error) -> String { return "ERROR io: load: \(error )" }                // P03 a space inside
    static func p04(_ e: Error) -> String { return "ERROR io: " + String(describing: e) }           // P04 describing another name
    static func p05(_ error: Error) -> String { return "ERROR io: \((error as NSError).description)" } // P05 NSError description
    static func p06(_ error: Error) -> String { return "ERROR io: \(error.self)" }                  // P06 .self
    static func p07(_ error: NSError) -> String { return "ERROR io: \(error.userInfo)" }            // P07 userInfo
    static func p08(_ error: Error) -> String { return "ERROR io: \\" + "// \(error)" }             // P08 an escaped backslash before a //
    static func p09(_ error: Error) -> String {
        return """
        * \(error)
        """                                                                                         // P09 a multi-line literal line starting with *
    }
    static func p10(_ x: Error) -> String { return "ERROR io: \(String(reflecting: x))" }          // P10 reflecting
    static func p11(_ error: Error) -> String { return "ERROR io: \(error.localizedDescription)" }  // P11 localizedDescription (refused anywhere)
}
"""#

    func testR16LintCatchesEachPatternItRefuses() {
        let liveTypes = REPLY1Lint.errorTypes(REPLY1Lint.sources(Self.sourcesDir).map { String(REPLY1Lint.codeView($0.text)) })
        let hits = REPLY1Lint.lint(Self.verifierPlant, file: "ZZVerifierPlant.swift", types: liveTypes, funcs: [])
        let lines = Self.verifierPlant.components(separatedBy: "\n")
        var caught: [String] = []
        for (k, l) in lines.enumerated() {
            guard let r = l.range(of: "// P[0-9][0-9]", options: .regularExpression) else { continue }
            let tag = String(l[r].dropFirst(3))
            // P09's form sits on the line after its `return """` (the literal's line starting with `*`)
            let form = tag == "P09" ? k : k + 1
            if hits.contains(where: { $0.line == form || (tag == "P09" && $0.line == k) }) { caught.append(tag) }
        }
        XCTAssertEqual(caught.count, 11, "caught: \(caught); hits: \(hits)")
        // Not code: the same forms in a comment, and an error passed to the one error function.
        let clean = """
            // return "ERROR io: \\(error)"   a comment is not code
            /* String(describing: error) */
            func f(_ error: Error) -> String { return "ERROR io: " + Reply.errorWords(error) + "\\(Reply.errorWords(error))" }
            func g(_ s: String) -> String { return "x\\(s)" }
            """
        XCTAssertEqual(REPLY1Lint.lint(clean, file: "clean.swift", types: liveTypes, funcs: []), [])
    }

    // MARK: - The formatter

    /// Reads one formatted line back: unescapes `\\` `\n` `\r` `\t` `\xNN` `\uNNNN`.
    static func unescape(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var it = Array(s.unicodeScalars)[...]
        while let c = it.popFirst() {
            guard c == "\\", let n = it.popFirst() else { out.append(c); continue }
            switch n {
            case "\\": out.append("\\")
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "x", "u":
                let k = n == "x" ? 2 : 4
                let hex = String(String.UnicodeScalarView(it.prefix(k)))
                it = it.dropFirst(k)
                out.append(Unicode.Scalar(UInt32(hex, radix: 16)!)!)
            default: out.append(n)
            }
        }
        return String(out)
    }

    func testLineEscapesBackslashAndEveryControlAndLineBreakAndReadsBack() {
        var all = "a\\b"
        for v in Array(0x00..<0x20) + [0x7F] + Array(0x80...0x9F) + [0x2028, 0x2029] {
            all.unicodeScalars.append(Unicode.Scalar(UInt32(v))!)
        }
        all += " é 日本 😀 \"q\""
        let line = Reply.line(all)
        XCTAssertTrue(Reply.isLine(line))
        XCTAssertEqual(line.split(separator: "\n", omittingEmptySubsequences: false).count, 1)
        XCTAssertEqual(line.components(separatedBy: .newlines).count, 1, "no splitlines break survives")
        for u in line.unicodeScalars {
            XCTAssertFalse(u.value < 0x20 || u.value == 0x7F || (0x80...0x9F).contains(u.value) || u.value == 0x2028
                           || u.value == 0x2029, "raw U+\(String(u.value, radix: 16)) in the formatted line")
        }
        XCTAssertTrue(line.hasPrefix("a\\\\b\\x00\\x01"), line)
        XCTAssertTrue(line.contains("\\n") && line.contains("\\r") && line.contains("\\t") && line.contains("\\x0b")
                      && line.contains("\\x7f") && line.contains("\\u0085") && line.contains("\\u2028"), line)
        XCTAssertTrue(line.hasSuffix(" é 日本 😀 \"q\""), "printable non-ASCII and quotes are left as they are")
        XCTAssertEqual(Self.unescape(line), all, "the escapes read back to the original text")
        XCTAssertEqual(Reply.line("OK STATUS nodes=4096"), "OK STATUS nodes=4096", "a plain line is unchanged")
    }

    func testLineCapsTheReplyAndNamesTheTruncation() {
        let long = "OK X " + String(repeating: "\u{0b}", count: Reply.maxBytes)       // escapes to 4x the cap
        let n = 5 + 4 * Reply.maxBytes
        let line = Reply.line(long)
        XCTAssertLessThanOrEqual(line.utf8.count, Reply.maxBytes)
        XCTAssertTrue(Reply.isLine(line))
        // The marker counts the bytes OVER the cap (n - cap), not the bytes cut.
        XCTAssertTrue(line.hasSuffix(" [truncated: \(n - Reply.maxBytes) bytes over the reply cap of \(Reply.maxBytes)]"), String(line.suffix(80)))
        // The cut never splits an escape: what precedes the marker is whole `\x0b` escapes.
        let kept = line[line.startIndex..<line.range(of: " [truncated: ")!.lowerBound]
        XCTAssertTrue(kept.hasPrefix("OK X \\x0b"))
        XCTAssertEqual((kept.count - 5) % 4, 0, "whole escapes only")
        let exact = String(repeating: "a", count: Reply.maxBytes)
        XCTAssertEqual(Reply.line(exact), exact, "a reply at the cap is not cut")
        XCTAssertTrue(Reply.line(exact + "a").hasSuffix(" [truncated: 1 bytes over the reply cap of \(Reply.maxBytes)]"))
    }

    /// A cut inside a quoted echo closes the quote before the marker, and never splits a doubled quote.
    func testTheCapClosesAQuotedEchoItCuts() {
        let datum = String(repeating: "a\"", count: Reply.maxBytes)                    // "" pairs all the way
        let line = Reply.line("ERROR io: unknown class " + Reply.quoted(datum) + " at \"q\"")
        XCTAssertLessThanOrEqual(line.utf8.count, Reply.maxBytes)
        let m = line.range(of: " [truncated: ")!
        let kept = line[line.startIndex..<m.lowerBound]
        XCTAssertTrue(kept.hasSuffix("\""), String(kept.suffix(20)))
        // A quote-aware reader: after `class `, one datum (`""` inside), closed before the marker.
        let body = kept.dropFirst("ERROR io: unknown class ".count)
        XCTAssertTrue(body.hasPrefix("\"") && body.hasSuffix("\""))
        let inner = body.dropFirst().dropLast()
        XCTAssertFalse(inner.replacingOccurrences(of: "\"\"", with: "").contains("\""), "no lone quote inside: the datum is whole")
    }

    /// The volatile tail is not counted and follows the marker, so a cut reply's text is the same whatever
    /// its timing.
    func testTheCapLeavesTheVolatileTailOutsideTheCut() {
        let big = "OK GRAPH " + String(repeating: "r1=1 ", count: Reply.maxBytes / 4)
        let a = Reply.line(big + "elapsed=1.0ms"), b = Reply.line(big + "elapsed=12345.67ms")
        XCTAssertEqual(Reply.withoutVolatile(a), Reply.withoutVolatile(b))
        XCTAssertTrue(a.hasSuffix(" bytes over the reply cap of \(Reply.maxBytes)] elapsed=1.0ms"), String(a.suffix(80)))
        XCTAssertTrue(Reply.isLine(b))
    }

    /// A format character (Cf: bidi controls, zero-width, BOM, tags) is escaped in a reply; input with one stays allowed.
    func testFormatCharactersAreEscapedInRepliesAndAllowedInInput() {
        XCTAssertEqual(Reply.line("ERROR unknown_command: \"FOO \u{202E}OK GET node=0 truth=1\""),
                       "ERROR unknown_command: \"FOO \\u202eOK GET node=0 truth=1\"")
        XCTAssertEqual(Reply.escape("a\u{200B}b\u{FEFF}c\u{2066}d\u{AD}e"), "a\\u200bb\\ufeffc\\u2066d\\u00ade")
        XCTAssertEqual(Reply.escape("t\u{E0041}"), "t\\U000e0041")
        XCTAssertFalse(Reply.isLine("x\u{202E}y"))
        XCTAssertEqual(Reply.escape("é 日本 😀 ب"), "é 日本 😀 ب", "printable non-ASCII untouched")
        XCTAssertNil(Reply.inputRefusal("STREAM OPEN a\u{202E}b 1 2 3 5"), "input with a format character stays allowed")
    }

    func testVolatileFieldsMoveToTheTailOnlyOutsideQuotedSpans() {
        XCTAssertEqual(Reply.line("OK TICK 1 elapsed=1.20ms total=1 nodes_computed=4096"),
                       "OK TICK 1 total=1 nodes_computed=4096 elapsed=1.20ms")
        XCTAssertEqual(Reply.line("ERROR out_of_budget: X needs 9 bytes; nothing written footprint=123"),
                       "ERROR out_of_budget: X needs 9 bytes; nothing written footprint=123")
        XCTAssertEqual(Reply.line("OK BANK BENCH id=w1 best_ms=2.0 M=3 samples_per_s=9 reps=1"),
                       "OK BANK BENCH id=w1 M=3 reps=1 best_ms=2.0 samples_per_s=9")
        // An echo that spells a volatile key stays where it is: it is data.
        XCTAssertEqual(Reply.line("OK STREAM OPEN id=s1 name=\(Reply.quoted("x elapsed=9ms")) draws=0 elapsed=1ms"),
                       "OK STREAM OPEN id=s1 name=\"x elapsed=9ms\" draws=0 elapsed=1ms")
        // A value followed by a sentence's punctuation: the punctuation stays, the key=value moves.
        XCTAssertEqual(Reply.line("OK LOAD bytes=1 ticks=0 elapsed=0.3ms; unverified: no manifest"),
                       "OK LOAD bytes=1 ticks=0; unverified: no manifest elapsed=0.3ms")
        XCTAssertEqual(Reply.withoutVolatile("OK LOAD bytes=1 ticks=0; unverified: no manifest elapsed=0.3ms"),
                       "OK LOAD bytes=1 ticks=0; unverified: no manifest")
        XCTAssertEqual(Reply.volatileKeys, ["elapsed", "elapsed_ms", "wall_ms", "best_ms", "samples_per_s", "footprint"])
    }

    func testQuotedEchoesReadAsOneDatum() {
        let nasty = "a\" truth=1 \"b\nOK GET node=0 truth=1"
        let line = Reply.line("ERROR not_found: \(Reply.quoted(nasty))")
        XCTAssertTrue(Reply.isLine(line))
        XCTAssertEqual(line, "ERROR not_found: \"a\"\" truth=1 \"\"b\\nOK GET node=0 truth=1\"")
        // A quote-aware reader: after the code, one datum; `""` inside is `"`; then the escapes undone.
        let body = line.dropFirst("ERROR not_found: ".count)
        XCTAssertTrue(body.hasPrefix("\"") && body.hasSuffix("\""))
        let inner = String(body.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
        XCTAssertEqual(Self.unescape(inner), nasty)
    }

    // MARK: - The input refusal

    func testInputRefusalNamesTheClassAndOffsetAndNeverEchoesTheBytes() {
        var cases: [(UInt32, String)] = []
        for v in UInt32(0)..<0x20 where v != 0x09 { cases.append((v, v == 0 ? "a NUL" : "a C0 control")) }
        cases.append((0x7F, "a DEL"))
        for v in UInt32(0x80)...0x9F { cases.append((v, "a C1 control")) }
        cases.append((0x2028, "a line separator"))
        cases.append((0x2029, "a paragraph separator"))
        for (v, cls) in cases {
            var cmd = "STREAM OPEN n"
            cmd.unicodeScalars.append(Unicode.Scalar(v)!)
            cmd += "x 1 2 3 5"
            guard let r = Reply.inputRefusal(cmd) else { XCTFail("U+\(String(v, radix: 16)) not refused"); continue }
            XCTAssertTrue(r.hasPrefix("ERROR control_character: the command holds \(cls) (U+"), r)
            XCTAssertTrue(r.contains(String(format: "U+%04X", v)) && r.contains(" at byte 13;"), r)
            XCTAssertTrue(Reply.isLine(r), "the refusal is one plain line")
            XCTAssertFalse(r.unicodeScalars.contains(Unicode.Scalar(v)!), "the byte is never echoed")
        }
        XCTAssertNil(Reply.inputRefusal("STREAM OPEN né日本😀\tx 1 2 3 5"), "printable non-ASCII and tab stay allowed")
        // Raw bytes: the offset is the byte's own, an invalid sequence before it included.
        XCTAssertEqual(Reply.inputRefusal([0x41, 0xFF, 0xFE, 0x0D]).map { $0.contains(" at byte 3;") }, true)
    }

    func testHandlerRefusesAControlCharacterBeforeParsingAndChangesNothing() throws {
        let f = try HandlerFixture(side: 8)
        XCTAssertEqual(f.handler.handle("GET 0 TRUTH"), "OK GET node=0 truth=0")
        for cmd in ["SET 0 TRUTH 1\r", "SET 0 TRUTH\u{0b}1", "STREAM OPEN n\u{2028}OK 1 2 3 5", "SET 0 TRUTH 1\u{0}",
                    "FOO\rOK GET node=0 truth=1", "SET 0 TRUTH 1\n", "\u{85}SET 0 TRUTH 1"] {
            let r = f.handler.handle(cmd)
            XCTAssertTrue(r.hasPrefix("ERROR control_character: "), r)
            XCTAssertTrue(r.hasSuffix("refused before parsing, nothing changed"), r)
        }
        XCTAssertEqual(f.handler.handle("GET 0 TRUTH"), "OK GET node=0 truth=0", "no forged line reached a verb")
        XCTAssertTrue(f.handler.handle("STATUS").contains(" twin_open=0 "), "no stream opened")
    }

    /// The in-process half of the live check: its templates (every verb with a string argument), each with every one of
    /// the ten splitlines characters and NUL inside its argument. LF is here because on the wire it is the frame's
    /// terminator and cannot sit inside an argument at all; in-process it can, and it is refused like the rest.
    static let r12Templates: [String] = [
        "{s}",
        "STA{s}TUS",
        "SET 0 LUT {s}",
        "SET 0 MODE {s}",
        "TTABLE PRESET 0 {s} 2",
        "TTABLE DEFINE 0 {s}",
        "COMPOSE {s} 1 2 INTO 3",
        "DISTANCE {s} 0-1 0-1",
        "SAVE $R/{s}.dags",
        "SAVE $R/{s}.dags COMPRESSED",
        "LOAD $R/{s}.dags",
        "LOAD $R/{s}.dags UNVERIFIED",
        "EXPORT MORTON $R/{s}",
        "IMPORT MORTON $R/{s}",
        "SAVE JSON $R/{s}.json",
        "LOAD JSON $R/{s}.json",
        "SAVE CSV $R/{s}",
        "LOAD CSV $R/{s}",
        "SAVE TILED $R/{s} 2048",
        "TILED OPEN $R/{s} 2",
        "TILED BFS {s} 0 2",
        "TILED SELECT {s} 1 0 4",
        "TILED STATUS {s}",
        "TILED CLOSE {s}",
        "TILED TICK {s} 1",
        "TILED GET {s} 0 TRUTH",
        "BACKUP INIT $R/{s}",
        "BACKUP APPEND $R/{s}",
        "BACKUP RESTORE $R/{s}",
        "BACKUP COMPACT $R/{s}",
        "BACKUP INFO $R/{s}",
        "CLOSE_READER {s}",
        "READER {s} STATUS",
        "STREAM OPEN {s} 1 2 3 5",
        "STREAM NEXT {s} 1",
        "STREAM STATE {s}",
        "STREAM CLOSE {s}",
        "RECORD SLICE {s} 1",
        "RECORD REPLAY {s} 0",
        "RECORD VERIFY {s}",
        "RECORD INFO {s}",
        "RECORD CLOSE {s}",
        "RINGS WRITE {s} 1.0",
        "RINGS RECALL {s} 0",
        "RINGS INFO {s}",
        "RINGS CLOSE {s}",
        "CLOCK ADVANCE {s} 1",
        "CLOCK STATE {s}",
        "CLOCK CLOSE {s}",
        "GEAR OPEN {s} g 1/2",
        "GEAR OPEN c00000001 {s} 1/2",
        "GEAR STATE {s}",
        "GEAR CLOSE {s}",
        "XCONV SEALED {s} 1",
        "BUDGET ALLOCATE {s} 1.0 0:0",
        "BUDGET INFO {s}",
        "BUDGET CLOSE {s}",
        "ALARM LOAD $R/{s}.json",
        "ALARM INFO {s}",
        "ALARM CLOSE {s}",
        "ALARM FRAME {s} 0",
        "ALARM COURT {s} 1.0",
        "ALARM SUCCESSOR {s} 1.0 0 0 0",
        "ALARM CORRUPT {s} 0 0 0 0",
        "VIEW LOAD $R/{s}.npz",
        "VIEW REFLEX {s} 1",
        "VIEW RUNG {s} 1",
        "VIEW CEILING {s} 1",
        "VIEW FEATURES {s} 0 1",
        "VIEW INFO {s}",
        "VIEW CLOSE {s}",
        "KERNEL LOAD $R/{s}.json",
        "KERNEL INFO {s}",
        "KERNEL CLOSE {s}",
        "BANK OPEN {s}",
        "BANK GENERATE {s} 1",
        "BANK FIT {s}",
        "BANK NOISE {s} 1 1",
        "BANK BENCH {s} 1 1",
        "BANK INFO {s}",
        "BANK CLOSE {s}",
        "FOLD TIER {s} 0",
        "HOOK OPEN {s} b00000001 1.0",
        "HOOK OPEN a00000001 {s} 1.0",
        "HOOK STEP {s} 1",
        "HOOK STATE {s}",
        "HOOK LEDGER {s}",
        "HOOK INFO {s}",
        "HOOK CLOSE {s}"
    ]

    func testR12EveryVerbWithEveryBreakAndNULInsideAnArgumentIsRefusedByNameAndChangesNothing() throws {
        let f = try HandlerFixture(side: 8, dataRoot: root)
        for s in ["SET 0 TRUTH 1", "SET 1 RANK 1", "CONNECT FROM 1 TO 0", "STREAM OPEN base 1 2 3 5"] {
            XCTAssertTrue(f.handler.handle(s).hasPrefix("OK"), s)
        }
        func state() -> [String] {
            [f.handler.handle("STATUS"), f.handler.handle("GRAPH INFO"), f.handler.handle("STREAM STATE s00000001"),
             f.handler.handle("GET 0 TRUTH"), f.handler.handle("STREAM LIST"),
             ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted().joined(separator: ",")]
        }
        let before = state()
        let chars: [Character] = ["\n", "\r", "\u{0b}", "\u{0c}", "\u{1c}", "\u{1d}", "\u{1e}", "\u{85}", "\u{2028}", "\u{2029}", "\u{0}"]
        var cases = 0
        for t in Self.r12Templates {
            for ch in chars {
                let cmd = t.replacingOccurrences(of: "$R", with: root).replacingOccurrences(of: "{s}", with: "a\(ch)b")
                let off = cmd.utf8.count - cmd.drop(while: { $0 != ch }).utf8.count
                let r = f.handler.handle(cmd)
                cases += 1
                XCTAssertTrue(r.hasPrefix("ERROR control_character: ") && r.contains(" at byte \(off);"), "\(cmd.debugDescription): \(r)")
                XCTAssertTrue(Reply.isLine(r))
                XCTAssertFalse(r.contains(ch), "the character is never echoed")
            }
        }
        XCTAssertEqual(cases, Self.r12Templates.count * 11)
        XCTAssertEqual(state(), before, "nothing changed: state, the stream, the root's files")
    }

    // MARK: - The one error function

    static let printable = try! NSRegularExpression(pattern: "^[\\x20-\\x7e]*$")
    static let pointer = try! NSRegularExpression(pattern: "0x[0-9a-fA-F]{6,}")
    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    func testErrorWordsForAFoundationErrorAreItsErrnoAndPathNeverItsDescription() {
        let nested = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [
            NSFilePathErrorKey: "/r/no\ndir/x.json",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                                          userInfo: [NSLocalizedDescriptionKey: "No such file or directory"]),
            "NSUserStringVariant": ["Folder", "Other"],
            NSDebugDescriptionErrorKey: "a debug description at 0x600000123456",
        ])
        let w = Reply.errorWords(nested, verb: "save_json")
        XCTAssertEqual(w, "save_json: NSCocoaErrorDomain code 513 ENOENT (errno 2) path=\"/r/no\ndir/x.json\"")
        let line = Reply.line("ERROR io: " + w)
        XCTAssertTrue(Self.matches(Self.printable, line), line)
        XCTAssertFalse(Self.matches(Self.pointer, line), line)
        XCTAssertEqual(Reply.errorWords(NSError(domain: NSPOSIXErrorDomain, code: Int(EISDIR))), "EISDIR (errno 21)")
        XCTAssertEqual(Reply.errorWords(NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                                                userInfo: [NSURLErrorKey: URL(fileURLWithPath: "/r/a b")])),
                       "NSCocoaErrorDomain code 256 path=\"/r/a b\"")
        // Every NSError, whatever its domain, is its domain and code (an independent check's custom-domain case: two
        // userInfo keys, an underlying error with a heap address; Metal's command-buffer domain).
        let custom = NSError(domain: "com.example.Custom", code: 42,
                             userInfo: ["alpha": "one", "beta": "two\nlines", NSUnderlyingErrorKey: NSError(domain: "Inner", code: 7)])
        XCTAssertEqual(Reply.errorWords(custom), "com.example.Custom code 42")
        let mtl = NSError(domain: "MTLCommandBufferErrorDomain", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Execution of the command buffer was aborted due to an error during execution.",
            NSUnderlyingErrorKey: NSError(domain: "IOGPUCommandQueueErrorDomain", code: 3)])
        XCTAssertEqual(Reply.errorWords(mtl), "MTLCommandBufferErrorDomain code 2")
        XCTAssertEqual(DagDBEngine.CommandBufferFailure(status: "error", error: Reply.errorWords(mtl)).description,
                       "command buffer status error (MTLCommandBufferErrorDomain code 2)")
        XCTAssertEqual(Reply.errorWords(NSError(domain: "X", code: 5, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))])),
                       "X code 5 EIO (errno 5)")
        XCTAssertEqual(Reply.errorWords(NSError(domain: NSCocoaErrorDomain, code: 3840,
                                                userInfo: ["NSJSONSerializationErrorIndex": 7, NSDebugDescriptionErrorKey: "x"])),
                       "json: invalid at byte 7")
    }

    func testErrorWordsForRealFoundationAndDecodingErrorsAreStableAndOneLine() throws {
        var errors: [Error] = []
        do { _ = try Data(contentsOf: URL(fileURLWithPath: root + "/missing")) } catch { errors.append(error) }
        do { try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/nodir/x.json"), options: .atomic) } catch { errors.append(error) }
        do { _ = try JSONSerialization.jsonObject(with: Data("x".utf8)) } catch { errors.append(error) }
        do { _ = try JSONSerialization.jsonObject(with: Data("\u{0b}{}".utf8)) } catch { errors.append(error) }
        struct M: Decodable { let format: String }
        do { _ = try JSONDecoder().decode(M.self, from: Data("{\"format\": 5}".utf8)) } catch { errors.append(error) }
        do { _ = try JSONDecoder().decode(M.self, from: Data("{}".utf8)) } catch { errors.append(error) }
        do { _ = try JSONDecoder().decode(M.self, from: Data([0, 0, 0])) } catch { errors.append(error) }
        try Data("f".utf8).write(to: URL(fileURLWithPath: root + "/afile"))
        do { try FileManager.default.createDirectory(atPath: root + "/afile/sub", withIntermediateDirectories: true) } catch { errors.append(error) }
        XCTAssertEqual(errors.count, 8)
        let words = errors.map { Reply.errorWords($0, verb: "v") }
        for (e, w) in zip(errors, words) {
            let line = Reply.line("ERROR io: " + w)
            XCTAssertTrue(Self.matches(Self.printable, line), "\(type(of: e)): \(line)")
            XCTAssertFalse(Self.matches(Self.pointer, line), line)
            XCTAssertFalse(line.contains("UserInfo") || line.contains("Domain=") || line.contains("description"), line)
            XCTAssertEqual(Reply.errorWords(e, verb: "v"), w, "the same error, the same words")
        }
        XCTAssertTrue(words[0].hasPrefix("v: NSCocoaErrorDomain code 260 ENOENT (errno 2) path=\""), words[0])
        XCTAssertTrue(words[1].contains(" ENOENT (errno 2) path=\""), words[1])
        XCTAssertEqual(words[2], "v: json: invalid at byte 0")
        XCTAssertEqual(words[3], "v: json: invalid at byte 0")
        XCTAssertEqual(words[4], "v: json: typeMismatch at \"format\"")
        XCTAssertEqual(words[5], "v: json: keyNotFound at \"format\"")
        XCTAssertTrue(words[6].hasPrefix("v: json: invalid"), words[6])
        XCTAssertTrue(words[7].hasPrefix("v: NSCocoaErrorDomain code "), words[7])
    }

    func testCustomErrorsKeepTheirWordsWithEveryStringPayloadQuoted() {
        // A description-less enum: its case and payloads, every String quoted (an embedded quote doubled).
        XCTAssertEqual(Reply.errorWords(AlarmFixture.FixtureError.badEntry(key: "q\"1\nx", reason: "r")),
                       "badEntry(key: \"q\"\"1\nx\", reason: \"r\")")
        XCTAssertEqual(Reply.errorWords(AlarmFixture.FixtureError.fileNotFound("/r/a")), "fileNotFound(\"/r/a\")")
        XCTAssertEqual(Reply.errorWords(NpzReader.NpzError.missing("X\ntrain")), "npz: missing entry \"X\ntrain\"")
        // The file helper's refusals, folded in: errno name and number, the path quoted.
        XCTAssertEqual(Reply.errorWords(DaemonFile.Refusal.missing(path: "/r/a b")), "ENOENT (errno 2) path=\"/r/a b\": no such file")
        XCTAssertEqual(Reply.errorWords(DaemonFile.Refusal.notRegular(path: "/r/d", kind: "directory")),
                       "EISDIR (errno 21) path=\"/r/d\": a directory, not a regular file")
        XCTAssertEqual(Reply.errorWords(DaemonFile.Refusal.io(path: "/r/x", call: "open", errno: EACCES)),
                       "EACCES (errno 13) path=\"/r/x\": open failed")
        // A daemon temporary is named by the file it stands in for (its name carries the pid).
        XCTAssertEqual(Reply.errorWords(DaemonFile.Refusal.missing(path: "/r/nodir/.x.json.dagdb-tmp-55211-5")),
                       "ENOENT (errno 2) path=\"/r/nodir/x.json\" (its temporary): no such file")
        XCTAssertEqual(Reply.pathWords("/r/.g.dagdb-stage-9-2/meta.json"), "\"/r/g/meta.json\" (its stage directory)")
        // Twin errors: an id is quoted.
        XCTAssertEqual(Reply.errorWords(TwinState.TwinError.notFound("s1 truth=1")), "not found: \"s1 truth=1\"")
    }

    func testErrorLineEmitsOneCodeForAnErrorThatCarriesItsOwnLine() {
        let admission = "ERROR out_of_budget: TILED BFS needs 9 bytes, the budget is 1; nothing written footprint=5"
        XCTAssertEqual(Reply.errorLine("io", DaemonFile.Refusal.admission(admission)), admission)
        XCTAssertEqual(Reply.errorLine("io", verb: "load", DagDBSnapshot.SnapError.admission(admission)), admission)
        XCTAssertEqual(Reply.errorLine("io", verb: "load_json", DagDBJSONIO.JSONError.admission(admission)), admission)
        XCTAssertEqual(Reply.errorLine("io", verb: "load", DaemonFile.Refusal.missing(path: "/r/x")),
                       "ERROR io: load: ENOENT (errno 2) path=\"/r/x\": no such file")
    }

    // MARK: - The handler's replies

    func testEveryClientEchoIsQuoted() throws {
        let f = try HandlerFixture(side: 8)
        XCTAssertEqual(f.handler.handle("FOO truth=1"), "ERROR unknown_command: \"FOO truth=1\"")
        XCTAssertEqual(f.handler.handle("STREAM STATE truth=1"), "ERROR not_found: \"truth=1\"")
        XCTAssertEqual(f.handler.handle("CLOSE_READER r1"), "ERROR not_found: close_reader session \"r1\" not found")
        XCTAssertEqual(f.handler.handle("TILED STATUS x=1"), "ERROR not_found: tiled router \"x=1\" not found")
        let open = f.handler.handle("STREAM OPEN a\"b=1 1 2 3 5")
        XCTAssertEqual(open, "OK STREAM OPEN id=s00000001 name=\"a\"\"b=1\" draws=0")
        XCTAssertTrue(f.handler.handle("STREAM STATE s00000001").hasPrefix("OK STREAM STATE id=s00000001 name=\"a\"\"b=1\" draws=0 "))
    }

    /// The formatter's choke point: `handle` itself returns the formatted line (in-process callers get it too), not only
    /// the socket writer: file text with a raw LF comes back escaped on one line, and the volatile field is the tail.
    func testTheHandlerFormatsEveryReplyAtTheChokePoint() throws {
        let f = try HandlerFixture(side: 8, dataRoot: root)
        let tick = f.handler.handle("TICK 1")
        XCTAssertTrue(tick.hasPrefix("OK TICK 1 total=1 ") && Reply.withoutVolatile(tick) != tick, tick)
        let dir = root + "/t_fmtnl"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let manifest = "{\"format\": \"x\\nOK TILED OPEN id=x00000001\", \"version\": 1, \"name\": \"g\", \"boundaries\": [],"
            + " \"globalNodeCount\": 0, \"tiles\": []}"
        try Data(manifest.utf8).write(to: URL(fileURLWithPath: dir + "/manifest.json"))
        let r = f.handler.handle("TILED OPEN \(dir) 1")
        XCTAssertTrue(Reply.isLine(r), r)
        XCTAssertEqual(r, "ERROR io: TiledGraphFiles: manifest format \"x\\nOK TILED OPEN id=x00000001\" is not 'dagdb-tiled-manifest'")
    }

    func testReaderIdsComeFromTheCounterAndListInOrder() throws {
        let f = try HandlerFixture(side: 8)
        let ids = (1...5).map { _ -> String in
            let r = f.handler.handle("OPEN_READER")
            return String(r.split(separator: " ")[2].dropFirst(3))
        }
        XCTAssertEqual(ids, (1...5).map { String(format: "r%016llx%016llx", 0, $0) })
        let list = f.handler.handle("LIST_READERS")
        XCTAssertEqual(list, "OK LIST_READERS open_sessions=5 " + ids.map { "\($0)@tick=0" }.joined(separator: " "))
    }

    func testAnUnwrittenManifestIsNamedInSavesReply() throws {
        let f = try HandlerFixture(side: 8, dataRoot: root)
        let path = root + "/s.dags"
        // The sidecar's temporary is the second marked name SAVE takes after this one (the snapshot's is the first);
        // an object planted there makes the sidecar's exclusive open fail.
        let probe = DaemonFile.tmpName(for: root + "/probe")
        let n = Int(probe.split(separator: "-").last!)!
        let sidecarTmp = root + "/.s.dags.sha256.dagdb-tmp-\(getpid())-\(n + 2)"
        try FileManager.default.createDirectory(atPath: sidecarTmp, withIntermediateDirectories: false)
        let r = f.handler.handle("SAVE \(path)")
        XCTAssertTrue(r.hasPrefix("OK SAVE bytes="), r)
        XCTAssertTrue(r.contains(" WARN manifest: \"\(path).sha256\" was not written (EEXIST (errno 17) path=\"\(path).sha256\" (its temporary): "), r)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".sha256"), "no manifest on disk, and the reply says so")
        // Without the plant: no warning, and the manifest is there.
        try FileManager.default.removeItem(atPath: sidecarTmp)
        let r2 = f.handler.handle("SAVE \(path)")
        XCTAssertFalse(r2.contains("WARN manifest"), r2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".sha256"))
    }
}
