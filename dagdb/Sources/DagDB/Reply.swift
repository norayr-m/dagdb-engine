/// Reply — one command in, one honest line out, the same on every daemon.
///
/// The wire is newline-framed: one command line in, one reply line out. A reply writer that escapes nothing
/// lets a client put any `splitlines` break except `\n` into an argument and get it back inside a reply (a
/// forged reply line), lets file contents and Foundation's multi-line error text put real `\n` into replies, and
/// lets NSError text (heap addresses, dictionary order) make identical daemons answer differently.
///
/// This file holds the whole policy, so every reply site, the socket writer and the daemon log share it:
/// - `inputRefusal`: a command line holding a control character (other than tab) is refused BY NAME before
///   parsing; the refusal names the character class and its byte offset and never echoes the bytes.
/// - `line`: the one output formatter. It moves the declared volatile fields to the tail, escapes `\` and
///   every control and line-break character, and caps the length (the truncation named).
/// - `quoted`: every echo of client or file text, so an echo reads as data, never as key=value or a new line.
/// - `errorWords` / `errorLine`: the one error function; stable words, never a description.
///
/// Amateur engineering project; no competitive claims; errors likely.

import Foundation

public enum Reply {

    // MARK: - Input

    /// The refusal for a command line holding a control character (any C0 control but tab, DEL, a C1 control
    /// U+0080–U+009F, U+2028, U+2029), or nil. `bytes` is the line as received (UTF-8), before any trim.
    /// The reply names the character's class and code point and its byte offset; it never echoes the bytes.
    public static func inputRefusal<C: Collection>(_ bytes: C) -> String? where C.Element == UInt8 {
        var i = 0
        var prev2: UInt8 = 0, prev1: UInt8 = 0
        for b in bytes {
            // C0 (tab allowed) and DEL: single bytes in UTF-8.
            if (b < 0x20 && b != 0x09) || b == 0x7F {
                return refusal(scalar: UInt32(b), at: i)
            }
            // C1: C2 80 ... C2 9F.
            if prev1 == 0xC2 && b >= 0x80 && b <= 0x9F {
                return refusal(scalar: UInt32(b), at: i - 1)
            }
            // U+2028 / U+2029: E2 80 A8 / E2 80 A9.
            if prev2 == 0xE2 && prev1 == 0x80 && (b == 0xA8 || b == 0xA9) {
                return refusal(scalar: b == 0xA8 ? 0x2028 : 0x2029, at: i - 2)
            }
            prev2 = prev1; prev1 = b
            i += 1
        }
        return nil
    }

    /// The same check on a command already decoded (an in-process caller of the handler).
    public static func inputRefusal(_ s: String) -> String? { inputRefusal(Array(s.utf8)) }

    static let c0Names = ["NUL", "SOH", "STX", "ETX", "EOT", "ENQ", "ACK", "BEL", "BS", "HT", "LF", "VT", "FF", "CR",
                          "SO", "SI", "DLE", "DC1", "DC2", "DC3", "DC4", "NAK", "SYN", "ETB", "CAN", "EM", "SUB", "ESC",
                          "FS", "GS", "RS", "US"]

    /// The class and name of a refused scalar: "a C0 control (U+000D CR)".
    public static func controlName(_ v: UInt32) -> String {
        let cp = String(format: "U+%04X", v)
        switch v {
        case 0x00: return "a NUL (\(cp))"
        case 0x01..<0x20: return "a C0 control (\(cp) \(c0Names[Int(v)]))"
        case 0x7F: return "a DEL (\(cp))"
        case 0x85: return "a C1 control (\(cp) NEL)"
        case 0x80...0x9F: return "a C1 control (\(cp))"
        case 0x2028: return "a line separator (\(cp))"
        case 0x2029: return "a paragraph separator (\(cp))"
        default: return "a control character (\(cp))"
        }
    }

    static func refusal(scalar v: UInt32, at offset: Int) -> String {
        "ERROR control_character: the command holds \(controlName(v)) at byte \(offset); a command line may hold no"
            + " control character but tab (C0, DEL, C1, U+2028, U+2029); refused before parsing, nothing changed"
    }

    // MARK: - Output

    /// The reply cap, in bytes of the formatted line's deterministic part. The
    /// volatile tail (at most the six declared fields) is not counted and follows the marker, so a cut reply's text
    /// is the same on every daemon; a longer deterministic part is cut at a boundary that splits no escape and no
    /// doubled quote, an open quoted echo is closed, and `truncationMarker` names the bytes over the cap.
    public static let maxBytes = 1 << 20

    /// The marker a cut reply carries: `" [truncated: <n> bytes over the reply cap of <cap>]"`, where n is how many
    /// bytes the deterministic part was over the cap (not the bytes cut).
    public static func truncationMarker(over n: Int) -> String {
        " [truncated: \(n) bytes over the reply cap of \(maxBytes)]"
    }

    /// The declared volatile set: the timing fields and the current footprint, the only fields a
    /// two-daemon comparison masks. `line` moves every `key=value` token whose key is one of these (outside a
    /// quoted span) to the reply's tail, after the deterministic fields, in the order they appeared.
    public static let volatileKeys: [String] = ["elapsed", "elapsed_ms", "wall_ms", "best_ms", "samples_per_s", "footprint"]

    /// The one output formatter: the volatile tail, the escapes, the cap. Applied once in
    /// `DagDBCommandHandler.handle`, asserted again in `SocketServer.writeLine` (by `isLine`), and applied to
    /// every daemon log line.
    public static func line(_ s: String) -> String {
        cap(escape(volatileLast(s)))
    }

    /// The formatter without the volatile reorder (escapes and the cap only), for
    /// text that must read exactly as it was sent: the daemon log's record of a command.
    public static func literal(_ s: String) -> String {
        cap(escape(s), splitTail: false)
    }

    /// True when `s` is already one formatted line: no control, line-break or format character, its deterministic
    /// part within the cap. (A formatted line holds `\\` and `\n` as two characters each, never the raw bytes.)
    public static func isLine(_ s: String) -> Bool {
        for u in s.unicodeScalars where needsEscape(u) { return false }
        return splitVolatileTail(s).head.utf8.count <= maxBytes
    }

    /// C0, DEL, C1, U+2028, U+2029, and every format character (Unicode
    /// category Cf: the bidi controls, zero-width characters, the BOM, tag characters), against a reply or a log
    /// line a terminal would show reordered.
    static func needsEscape(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        if v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F) || v == 0x2028 || v == 0x2029 { return true }
        return v >= 0xAD && u.properties.generalCategory == .format
    }

    static let hexBytes: [UInt8] = Array("0123456789abcdef".utf8)

    static func hex(_ v: UInt32, _ width: Int) -> String {
        var b = [UInt8]()
        appendHex(&b, v, width)
        return String(decoding: b, as: UTF8.self)
    }

    static func appendHex(_ out: inout [UInt8], _ v: UInt32, _ width: Int) {
        for k in stride(from: width - 1, through: 0, by: -1) { out.append(hexBytes[Int((v >> (4 * UInt32(k))) & 0xF)]) }
    }

    /// `\` -> `\\`; `\n` `\r` `\t` by name; every other C0 control and DEL -> `\xNN`; C1, U+2028, U+2029 and every
    /// format character (Cf) -> `\uNNNN` (`\UNNNNNNNN` above U+FFFF). Pure ASCII without `\` or a control returns
    /// at once; otherwise one pass into a byte buffer (a reply can be long: GRAPH INFO's rank histogram, a twin LIST).
    public static func escape(_ s: String) -> String {
        var needs = false
        for b in s.utf8 where b == 0x5C || b < 0x20 || b >= 0x7F { needs = true; break }
        if !needs { return s }
        var out = [UInt8]()
        out.reserveCapacity(s.utf8.count + 16)
        for u in s.unicodeScalars {
            let v = u.value
            switch v {
            case 0x5C: out += [0x5C, 0x5C]
            case 0x0A: out += [0x5C, 0x6E]
            case 0x0D: out += [0x5C, 0x72]
            case 0x09: out += [0x5C, 0x74]
            case 0x00..<0x20, 0x7F: out += [0x5C, 0x78]; appendHex(&out, v, 2)
            case 0x20..<0x7F: out.append(UInt8(v))
            default:
                if needsEscape(u) {
                    if v <= 0xFFFF { out += [0x5C, 0x75]; appendHex(&out, v, 4) } else { out += [0x5C, 0x55]; appendHex(&out, v, 8) }
                } else {
                    UTF8.encode(u) { out.append($0) }
                }
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The cap on an escaped line: the deterministic part (the line less its volatile tail, when
    /// `splitTail`) is kept whole up to the cap; past it, it is cut at a boundary that splits no escape (`\\` `\n`
    /// `\xNN` `\uNNNN` `\UNNNNNNNN`) and no doubled quote (`""`), a quoted echo left open is closed, the marker names
    /// the bytes over the cap, and the volatile tail follows.
    static func cap(_ s: String, splitTail: Bool = true) -> String {
        let parts = splitTail ? splitVolatileTail(s) : (head: Substring(s), tail: Substring(""))
        let n = parts.head.utf8.count
        if n <= maxBytes { return s }
        let src = Array(parts.head.utf8)
        let marker = truncationMarker(over: n - maxBytes)
        let budget = maxBytes - marker.utf8.count - 1                 // 1: the quote that closes an open echo
        var cut = 0
        var inQuote = false
        while cut < src.count {
            let b = src[cut]
            var len: Int
            var toggles = false
            if b == 0x5C, cut + 1 < src.count {
                switch src[cut + 1] { case 0x78: len = 4; case 0x75: len = 6; case 0x55: len = 10; default: len = 2 }
            } else if b == 0x22 {
                if inQuote, cut + 1 < src.count, src[cut + 1] == 0x22 { len = 2 } else { len = 1; toggles = true }
            } else if b < 0x80 { len = 1 } else if b >= 0xF0 { len = 4 } else if b >= 0xE0 { len = 3 } else { len = 2 }
            len = min(len, src.count - cut)
            if cut + len > budget { break }
            if toggles { inQuote.toggle() }
            cut += len
        }
        var kept = String(decoding: src[0..<cut], as: UTF8.self)
        if inQuote { kept += "\"" }
        return kept + marker + (parts.tail.isEmpty ? "" : " " + parts.tail)
    }

    /// A line split into its deterministic head and its volatile tail: the trailing `key=value` tokens whose key is
    /// one of `volatileKeys`, whose value is a number (digits, `.`, `e`, `+`, `-`, an optional `ms`), and which lie
    /// outside every quoted span. (A token inside an echo is never taken for the tail.)
    public static func splitVolatileTail(_ s: String) -> (head: Substring, tail: Substring) {
        var head = Substring(s)
        var tailStart = s.endIndex
        while let sp = head.lastIndex(of: " ") {
            let tok = head[head.index(after: sp)...]
            guard let eq = tok.firstIndex(of: "="), volatileKeys.contains(String(tok[tok.startIndex..<eq])) else { break }
            var value = tok[tok.index(after: eq)...]
            if value.hasSuffix("ms") { value = value.dropLast(2) }
            guard !value.isEmpty, value.allSatisfy({ "0123456789.e+-".contains($0) }) else { break }
            let before = head[head.startIndex..<sp]
            guard before.reduce(0, { $0 + ($1 == "\"" ? 1 : 0) }) % 2 == 0 else { break }   // inside a quoted span
            tailStart = sp
            head = before
        }
        let tail = tailStart < s.endIndex ? s[s.index(after: tailStart)...] : Substring("")
        return (head, tail)
    }

    /// A formatted line without its volatile tail: what a two-daemon comparison compares, and what a reader that
    /// ignores timing reads.
    public static func withoutVolatile(_ s: String) -> String {
        String(splitVolatileTail(s).head)
    }

    /// Every volatile `key=value` token (outside a quoted span) moved to the tail, in the order it appeared.
    public static func volatileLast(_ s: String) -> String {
        guard volatileKeys.contains(where: { s.contains($0 + "=") }) else { return s }
        var kept: [String] = []
        var moved: [Substring] = []
        var inQuote = false
        var tokenStart = s.startIndex
        var i = s.startIndex
        func flush(_ end: String.Index) {
            let t = s[tokenStart..<end]
            if !t.isEmpty, !t.hasPrefix("\""), let eq = t.firstIndex(of: "="),
               volatileKeys.contains(String(t[t.startIndex..<eq])) {
                // The value ends at a sentence's punctuation (`elapsed=0.3ms; unverified: …`): the punctuation stays
                // where it was, on the token before; only `key=value` moves.
                let cut = t[eq...].firstIndex(where: { $0 == ";" || $0 == "," || $0 == ")" }) ?? t.endIndex
                moved.append(t[t.startIndex..<cut])
                let rest = String(t[cut...])
                if !rest.isEmpty { if kept.isEmpty { kept.append(rest) } else { kept[kept.count - 1] += rest } }
            } else {
                kept.append(String(t))
            }
        }
        while i < s.endIndex {
            let c = s[i]
            if c == "\"" { inQuote.toggle() }          // a doubled quote toggles twice: still inside
            if c == " " && !inQuote {
                flush(i)
                tokenStart = s.index(after: i)
            }
            i = s.index(after: i)
        }
        flush(s.endIndex)
        if moved.isEmpty { return s }
        return (kept + moved.map(String.init)).joined(separator: " ")
    }

    /// An echo of client or file text: wrapped in double quotes, an embedded `"` doubled (`""`). The one
    /// formatter (`line`) escapes everything else exactly once, so an echo is always one quoted datum: it never
    /// ends a line and never reads as key=value. Reading it back: inside the quotes `""` is `"`, and the escapes
    /// `\\` `\n` `\r` `\t` `\xNN` `\uNNNN` undo `line`.
    public static func quoted<S: StringProtocol>(_ s: S) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Errors

    /// An error that renders its own reply words (custom errors whose payloads need quoting or errno words).
    public protocol Words: Error {
        var replyWords: String { get }
    }

    /// An error that carries a whole reply line of its own (an admission refusal: `ERROR out_of_budget: …`);
    /// `errorLine` emits that line alone, never under a second code.
    public protocol CarriesLine: Error {
        var replyLine: String? { get }
    }

    /// The one error function. The words of `e` for a failed `verb` (prefixed `verb: ` when given):
    /// - every NSError, whatever its domain: `<domain> code <n>`, plus the errno
    ///   words when a POSIX underlying error exists, plus the path; a POSIX-domain error is its errno words; a JSON
    ///   parse error `json: invalid at byte N`. Never a description, localizedDescription or userInfo;
    /// - a DecodingError: `json: <kind> at <quoted coding path>` (a JSON syntax error under it: the byte);
    /// - a Swift error type: its own words (`Words`, else the description the type itself declares), with every
    ///   echoed text quoted where it is built; a type with no description: its case and payloads by reflection,
    ///   every String payload quoted; a struct or class: its type's name.
    public static func errorWords(_ e: Error, verb: String = "") -> String {
        let w = words(e)
        return verb.isEmpty ? w : verb + ": " + w
    }

    /// The reply line for a failed `verb` under the reply code `code` — one code: an error that carries its own
    /// line (an admission refusal) is that line.
    public static func errorLine(_ code: String, verb: String = "", _ e: Error) -> String {
        if let l = carriedLine(e) { return l }
        return "ERROR \(code): " + errorWords(e, verb: verb)
    }

    /// The whole reply line `e` carries, if any.
    public static func carriedLine(_ e: Error) -> String? {
        (e as? CarriesLine)?.replyLine
    }

    static func words(_ e: Error) -> String {
        if let w = e as? Words { return w.replyWords }
        if let d = e as? DecodingError { return decodingWords(d) }
        // Every NSError (an NSError object of any domain: Metal's, a framework's, a custom one), and Foundation's
        // bridged error types (CocoaError, POSIXError, URLError, …), before the description branch: an NSError's
        // description carries its localizedDescription, its userInfo in hash order and heap addresses.
        if isNSError(e) { return foundationWords(e as NSError) }
        if let c = e as? CustomStringConvertible { return c.description }        // a Swift type's own description
        return reflectedWords(e)
    }

    /// True for an NSError object (any domain, any subclass) or one of Foundation's bridged error types; false for
    /// a Swift error type of this code base (whose bridge to NSError is never consulted for words).
    static func isNSError(_ e: Error) -> Bool {
        if Swift.type(of: e) is NSError.Type { return true }
        let d = (e as NSError).domain
        return d == NSCocoaErrorDomain || d == NSPOSIXErrorDomain || d == NSOSStatusErrorDomain
            || d == NSURLErrorDomain || d == NSMachErrorDomain
    }

    /// The words of an error type with no description of its own: its case name and its payloads, every String
    /// payload quoted, a nested error in its own words, a number as itself; a struct or class: its type name.
    static func reflectedWords(_ e: Any) -> String {
        let m = Mirror(reflecting: e)
        guard m.displayStyle == .enum else { return String(describing: type(of: e)) }
        guard let child = m.children.first, let label = child.label else {
            return String(describing: e)                                // a case without a payload: its name
        }
        let pm = Mirror(reflecting: child.value)
        let items: [(String?, Any)] = pm.displayStyle == .tuple
            ? pm.children.map { ($0.label, $0.value) } : [(nil, child.value)]
        let parts = items.map { (l, v) -> String in
            let name = (l == nil || l!.hasPrefix(".")) ? "" : l! + ": "
            return name + payloadWords(v)
        }
        return label + "(" + parts.joined(separator: ", ") + ")"
    }

    static func payloadWords(_ v: Any) -> String {
        switch v {
        case let s as String: return quoted(s)
        case let s as Substring: return quoted(s)
        case let x as Error: return words(x)
        case is Int, is Int8, is Int16, is Int32, is Int64, is UInt, is UInt8, is UInt16, is UInt32, is UInt64,
             is Double, is Float, is Bool:
            return String(describing: v)
        default: return quoted(String(describing: v))
        }
    }

    /// `ENAME (errno N)` for an errno.
    public static func errnoWords(_ e: Int32) -> String {
        "\(DaemonFile.errnoName(e)) (errno \(e))"
    }

    /// `ENAME (errno N) path="<p>"`.
    public static func errnoWords(_ e: Int32, path: String) -> String {
        errnoWords(e) + " path=" + pathWords(path)
    }

    /// A path for a reply, quoted. A daemon temporary or stage directory (`.<name>.dagdb-tmp-<pid>-<n>`,
    /// `.<name>.dagdb-stage-<pid>-<n>`: the name carries the process id) is named by the file it stands in for,
    /// followed by "(its temporary)", so identical daemons word the same failure identically.
    public static func pathWords(_ p: String) -> String {
        var what: [String] = []
        let parts = p.split(separator: "/", omittingEmptySubsequences: false).map { part -> String in
            for (marker, word) in [(".dagdb-tmp-", "its temporary"), (".dagdb-stage-", "its stage directory")] {
                if part.hasPrefix("."), let r = part.range(of: marker), r.lowerBound > part.index(after: part.startIndex) {
                    what.append(word)
                    return String(part[part.index(after: part.startIndex)..<r.lowerBound])
                }
            }
            return String(part)
        }
        return quoted(parts.joined(separator: "/")) + (what.isEmpty ? "" : " (" + what.joined(separator: ", ") + ")")
    }

    /// An NSError's words from its domain, code, POSIX underlying error and path only.
    static func foundationWords(_ ns: NSError) -> String {
        if ns.domain == NSCocoaErrorDomain && ns.code == 3840 {           // JSONSerialization
            if let at = ns.userInfo["NSJSONSerializationErrorIndex"] as? Int { return "json: invalid at byte \(at)" }
            return "json: invalid"
        }
        let path: String? = (ns.userInfo[NSFilePathErrorKey] as? String)
            ?? (ns.userInfo[NSURLErrorKey] as? URL).map { $0.path }
        let pathText = path.map { " path=" + pathWords($0) } ?? ""
        if ns.domain == NSPOSIXErrorDomain { return errnoWords(Int32(truncatingIfNeeded: ns.code)) + pathText }
        var w = "\(ns.domain) code \(ns.code)"
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain {
            w += " " + errnoWords(Int32(truncatingIfNeeded: u.code))
        }
        return w + pathText
    }

    static func codingPath(_ path: [CodingKey]) -> String {
        quoted(path.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: "."))
    }

    static func decodingWords(_ d: DecodingError) -> String {
        switch d {
        case .dataCorrupted(let c):
            if let u = c.underlyingError, (u as NSError).domain == NSCocoaErrorDomain, (u as NSError).code == 3840 {
                return foundationWords(u as NSError)
            }
            return "json: dataCorrupted at \(codingPath(c.codingPath))"
        case .typeMismatch(_, let c): return "json: typeMismatch at \(codingPath(c.codingPath))"
        case .valueNotFound(_, let c): return "json: valueNotFound at \(codingPath(c.codingPath))"
        case .keyNotFound(let k, let c): return "json: keyNotFound at \(codingPath(c.codingPath + [k]))"
        @unknown default: return "json: undecodable"
        }
    }
}
