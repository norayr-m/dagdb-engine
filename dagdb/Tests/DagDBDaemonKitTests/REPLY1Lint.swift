import Foundation

/// The source lint. An error's own text never reaches a reply or
/// the log except through `Reply.errorWords`. The lint refuses, in every daemon source (DagDB, DagDBDaemonKit and
/// DagDBDaemon's main.swift):
/// - an interpolation of an Error-typed value, whatever its name: `\(e)`, `\(error )`, `\(error.self)`,
///   `\((error as NSError).description)`;
/// - `String(describing:)` of one, and `.description`, `.debugDescription`, `.userInfo` or `.localizedDescription`
///   on one;
/// - `.localizedDescription`, `.userInfo` and `String(reflecting:)` on anything.
/// "Error-typed" is read from the source: a `catch` binding (`catch {` binds `error`), a declaration or parameter
/// whose type is `Error`, `NSError`, a Foundation error type or an error type this code base declares, an
/// `as`/`as?`/`as!` cast to one, and a value returned by a function declared to return one; each within its
/// lexical scope. Comments are skipped and string literals are lexed (escapes, multi-line and raw literals, nested
/// interpolations), so a literal's text is never taken for code or a comment.
/// One file is exempt, by name: `Sources/DagDB/Reply.swift`, the one error function, the only place that reads a
/// type's own description (for Swift types that declare one) and an NSError's domain, code and userInfo keys.
///
/// Amateur engineering project; no competitive claims; errors likely.
enum REPLY1Lint {
    static let exempt: Set<String> = ["DagDB/Reply.swift"]
    static let foundationErrorTypes: Set<String> = ["Error", "NSError", "CocoaError", "POSIXError", "DecodingError",
                                                    "EncodingError", "URLError", "MachError"]

    /// The source with comments blanked and string-literal text blanked (newlines kept, quote characters and
    /// `\(` … `)` interpolations kept as code), the same length in characters.
    static func codeView(_ text: String) -> [Character] {
        let src = Array(text)
        var out = src
        enum Mode { case code(interp: Bool, depth: Int), string(multi: Bool, hashes: Int) }
        var stack: [Mode] = [.code(interp: false, depth: 0)]
        var i = 0
        func blank(_ k: Int) { if out[k] != "\n" { out[k] = " " } }
        func at(_ k: Int, _ s: String) -> Bool {
            let c = Array(s)
            guard k + c.count <= src.count else { return false }
            for j in 0..<c.count where src[k + j] != c[j] { return false }
            return true
        }
        while i < src.count {
            switch stack[stack.count - 1] {
            case .code(let interp, let depth):
                if at(i, "//") {
                    while i < src.count && src[i] != "\n" { blank(i); i += 1 }
                    continue
                }
                if at(i, "/*") {
                    var nest = 0
                    while i < src.count {
                        if at(i, "/*") { nest += 1; blank(i); blank(i + 1); i += 2; continue }
                        if at(i, "*/") { nest -= 1; blank(i); blank(i + 1); i += 2; if nest == 0 { break }; continue }
                        blank(i); i += 1
                    }
                    continue
                }
                // A string literal, raw (#…#) or not, single- or multi-line.
                var h = 0
                while i + h < src.count && src[i + h] == "#" { h += 1 }
                if i + h < src.count && src[i + h] == "\"" {
                    let multi = at(i + h, "\"\"\"")
                    i += h + (multi ? 3 : 1)
                    stack.append(.string(multi: multi, hashes: h))
                    continue
                }
                if interp {
                    if src[i] == "(" { stack[stack.count - 1] = .code(interp: true, depth: depth + 1) }
                    if src[i] == ")" {
                        if depth == 0 { stack.removeLast(); i += 1; continue }       // the interpolation ends
                        stack[stack.count - 1] = .code(interp: true, depth: depth - 1)
                    }
                }
                i += 1
            case .string(let multi, let hashes):
                let hashStr = String(repeating: "#", count: hashes)
                if at(i, "\\" + hashStr) {
                    let k = i + 1 + hashes
                    if k < src.count && src[k] == "(" {                            // an interpolation: code
                        i = k + 1
                        stack.append(.code(interp: true, depth: 0))
                        continue
                    }
                    for j in i..<min(k + 1, src.count) { blank(j) }                // an escape: \\ \" \n \u{…}
                    var e = k + 1
                    if k < src.count && src[k] == "u" && e < src.count && src[e] == "{" {
                        while e < src.count && src[e] != "}" { blank(e); e += 1 }
                        if e < src.count { blank(e); e += 1 }
                    }
                    i = e
                    continue
                }
                let close = (multi ? "\"\"\"" : "\"") + hashStr
                if at(i, close) { stack.removeLast(); i += close.count; continue }
                if !multi && src[i] == "\n" { stack.removeLast(); i += 1; continue }   // unterminated: recover
                blank(i)
                i += 1
            }
        }
        return out
    }

    static func ns(_ s: String) -> NSString { s as NSString }

    static func matches(_ pattern: String, _ s: String) -> [NSTextCheckingResult] {
        (try! NSRegularExpression(pattern: pattern)).matches(in: s, range: NSRange(location: 0, length: ns(s).length))
    }

    /// The error types the sources declare (`enum|struct|class|actor X…: …Error…`), plus Foundation's.
    static func errorTypes(_ codes: [String]) -> Set<String> {
        var t = foundationErrorTypes
        for c in codes {
            for m in matches(#"\b(?:enum|struct|class|actor)\s+(\w+)\s*(?:<[^>{]*>)?\s*:\s*([^{]*)\{"#, c) {
                let inherits = ns(c).substring(with: m.range(at: 2))
                if !matches(#"\bError\b"#, inherits).isEmpty { t.insert(ns(c).substring(with: m.range(at: 1))) }
            }
        }
        return t
    }

    /// Functions declared to return an error type (or an optional one).
    static func errorFunctions(_ codes: [String], _ types: Set<String>) -> Set<String> {
        var f: Set<String> = []
        for c in codes {
            for m in matches(#"\bfunc\s+(\w+)\s*(?:<[^>{]*>)?\s*\([^{]*?\)\s*(?:async\s*)?(?:re)?(?:throws\s*)?->\s*([\w.]+)\??\s*\{"#, c) {
                let ret = ns(c).substring(with: m.range(at: 2)).split(separator: ".").last.map(String.init) ?? ""
                if types.contains(ret) { f.insert(ns(c).substring(with: m.range(at: 1))) }
            }
        }
        return f
    }

    struct Binding { let name: String; let from: Int; let to: Int }

    /// The end of the brace block that opens at or after `p` (the matching `}`), or of the block holding `p`.
    static func blockAfter(_ c: [Character], _ p: Int) -> Int {
        var k = p
        while k < c.count && c[k] != "{" { k += 1 }
        var d = 0
        while k < c.count {
            if c[k] == "{" { d += 1 }
            if c[k] == "}" { d -= 1; if d == 0 { return k } }
            k += 1
        }
        return c.count
    }

    static func blockHolding(_ c: [Character], _ p: Int) -> Int {
        var d = 0
        var k = p
        while k < c.count {
            if c[k] == "{" { d += 1 }
            if c[k] == "}" { if d == 0 { return k }; d -= 1 }
            k += 1
        }
        return c.count
    }

    /// The Error-typed names of one file, each with its lexical scope (character offsets in the code view).
    static func bindings(_ c: [Character], _ code: String, _ types: Set<String>, _ funcs: Set<String>) -> [Binding] {
        var b: [Binding] = []
        let typeAlt = types.sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let qualified = #"(?:\w+\.)*(?:"# + typeAlt + #")"#
        // catch {  → error, in the catch block
        for m in matches(#"\bcatch\s*\{"#, code) { b.append(Binding(name: "error", from: m.range.location, to: blockAfter(c, m.range.location))) }
        // catch let x / catch var x [as T] [where …] {  → x, in the catch block
        for m in matches(#"\bcatch\s+(?:let|var)\s+(\w+)"#, code) {
            b.append(Binding(name: ns(code).substring(with: m.range(at: 1)), from: m.range.location, to: blockAfter(c, m.range.location)))
        }
        // if/guard/while let x = … as? T, case let x as T, let x = … as T
        for m in matches(#"\b(if|guard|while|case)?\s*(?:let|var)\s+(\w+)\s*=?\s*[^\n{=]*?\bas[?!]?\s+"# + qualified + #"\b"#, code) {
            let kw = m.range(at: 1).location == NSNotFound ? "" : ns(code).substring(with: m.range(at: 1))
            let name = ns(code).substring(with: m.range(at: 2))
            let end = (kw == "if" || kw == "while") ? blockAfter(c, m.range.location) : blockHolding(c, m.range.location)
            b.append(Binding(name: name, from: m.range.location, to: end))
        }
        // case let x as T (switch)
        for m in matches(#"\bcase\s+let\s+(\w+)\s+as\s+"# + qualified + #"\b"#, code) {
            b.append(Binding(name: ns(code).substring(with: m.range(at: 1)), from: m.range.location, to: blockHolding(c, m.range.location)))
        }
        // declarations and parameters: x: T, x: any T, x: T?  (a parameter's scope: the function's body)
        for m in matches(#"(\w+)\s*:\s*(?:any\s+)?"# + qualified + #"\s*[?!]?\s*(?=[,)=\n{])"#, code) {
            let name = ns(code).substring(with: m.range(at: 1))
            if name == "case" || name == "default" { continue }
            // a parameter list: up to the body's closing brace; a local declaration: to the end of its block
            var k = m.range.location, parens = 0
            while k > 0 && c[k] != "\n" { if c[k] == ")" { parens -= 1 }; if c[k] == "(" { parens += 1 }; k -= 1 }
            let end = parens > 0 ? blockAfter(c, m.range.location) : blockHolding(c, m.range.location)
            b.append(Binding(name: name, from: m.range.location, to: end))
        }
        // let x = f(…) / Type.f(…) where f is declared to return an error type
        if !funcs.isEmpty {
            let falt = funcs.sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            for m in matches(#"\b(if|guard|while)?\s*(?:let|var)\s+(\w+)\s*=\s*(?:try[?!]?\s+)?(?:[\w.]+\.)?(?:"# + falt + #")\s*\("#, code) {
                let kw = m.range(at: 1).location == NSNotFound ? "" : ns(code).substring(with: m.range(at: 1))
                let name = ns(code).substring(with: m.range(at: 2))
                let end = (kw == "if" || kw == "while") ? blockAfter(c, m.range.location) : blockHolding(c, m.range.location)
                b.append(Binding(name: name, from: m.range.location, to: end))
            }
        }
        return b
    }

    struct Hit: Equatable, CustomStringConvertible {
        let file: String, line: Int, what: String
        var description: String { "\(file):\(line): \(what)" }
    }

    /// The lint over one file's text, given the code base's error types and error-returning functions.
    static func lint(_ text: String, file: String, types: Set<String>, funcs: Set<String>) -> [Hit] {
        let c = codeView(text)
        let code = String(c)
        var hits: [Hit] = []
        let starts: [Int] = { var s = [0]; for (k, ch) in c.enumerated() where ch == "\n" { s.append(k + 1) }; return s }()
        func line(_ off: Int) -> Int {
            var lo = 0, hi = starts.count - 1
            while lo < hi { let mid = (lo + hi + 1) / 2; if starts[mid] <= off { lo = mid } else { hi = mid - 1 } }
            return lo + 1
        }
        // Character offsets: NSString (UTF-16) offsets differ from Character offsets on non-ASCII text; map them.
        let utf16ToChar: [Int] = {
            var m = [Int](); m.reserveCapacity(code.utf16.count + 1)
            for (k, ch) in c.enumerated() { for _ in 0..<String(ch).utf16.count { m.append(k) } }
            m.append(c.count)
            return m
        }()
        func add(_ r: NSRange, _ what: String) {
            let off = utf16ToChar[min(r.location, utf16ToChar.count - 1)]
            let h = Hit(file: file, line: line(off), what: what)
            if !hits.contains(h) { hits.append(h) }
        }
        for m in matches(#"\.\s*localizedDescription\b"#, code) { add(m.range, ".localizedDescription") }
        for m in matches(#"\.\s*userInfo\b"#, code) { add(m.range, ".userInfo") }
        for m in matches(#"\bString\s*\(\s*reflecting\s*:"#, code) { add(m.range, "String(reflecting:)") }
        for bnd in bindings(c, code, types, funcs) {
            let n = NSRegularExpression.escapedPattern(for: bnd.name)
            // The interpolated expression is the error itself (`\(e)`, `\(e )`, `\(e as …)`), or its text (`.self`,
            // `.description`, `.debugDescription`, `.userInfo`, `.localizedDescription`); a field of it (`\(r.detail)`,
            // the error type's own words) is not the error.
            let pats = [(#"\\\(\s*\(*\s*"# + n + #"\s*(?:\)|\.\s*(?:self|description|debugDescription|userInfo|localizedDescription)\b|as[?!]?\s)"#,
                         "an interpolation of the error \(bnd.name)"),
                        (#"\bString\s*\(\s*describing\s*:\s*\(*\s*"# + n + #"\b"#, "String(describing:) of the error \(bnd.name)"),
                        (#"(?<![\w.])"# + n + #"\s*\.\s*(?:description|debugDescription|userInfo|localizedDescription)\b"#, ".description of the error \(bnd.name)"),
                        (#"\(\s*"# + n + #"\s+as[?!]?\s+NSError\s*\)\s*\.\s*(?:description|debugDescription|userInfo)\b"#, "NSError text of the error \(bnd.name)")]
            for (p, what) in pats {
                for m in matches(p, code) {
                    let off = utf16ToChar[min(m.range.location, utf16ToChar.count - 1)]
                    if off >= bnd.from && off <= bnd.to { add(m.range, what) }
                }
            }
        }
        return hits.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
    }

    /// Every daemon source: DagDB, DagDBDaemonKit, DagDBDaemon (main.swift), at any depth; `extra` adds files.
    static func sources(_ sourcesDir: String) -> [(rel: String, text: String)] {
        var out: [(String, String)] = []
        for dir in ["DagDB", "DagDBDaemonKit", "DagDBDaemon"] {
            let d = sourcesDir + "/" + dir
            let all = (FileManager.default.enumerator(atPath: d)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".swift") }
            for f in all.sorted() {
                if let t = try? String(contentsOfFile: d + "/" + f, encoding: .utf8) { out.append((dir + "/" + f, t)) }
            }
        }
        return out
    }

    /// The lint over a set of files (the error types and functions are read from all of them).
    static func lint(files: [(rel: String, text: String)]) -> [Hit] {
        let views = files.map { String(codeView($0.text)) }
        let types = errorTypes(views)
        let funcs = errorFunctions(views, types)
        var hits: [Hit] = []
        for f in files where !exempt.contains(f.rel) { hits += lint(f.text, file: f.rel, types: types, funcs: funcs) }
        return hits
    }
}
