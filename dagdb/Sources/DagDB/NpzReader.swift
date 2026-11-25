import Foundation

/// Reader for numpy `.npz` archives written with `np.savez` (STORED /
/// uncompressed zip entries, method 0). No third-party code: the zip
/// central directory and the `.npy` header dict are both hand-parsed.
///
/// `np.savez` streams each array through `zipfile.open(..., force_zip64=True)`
/// without knowing its size up front, so LOCAL file headers carry
/// `0xFFFFFFFF` size placeholders and a zip64 extra field — but the
/// CENTRAL directory record for a small archive is written with real
/// sizes and an empty extra field. We trust the central directory for
/// name/method/offset/size and use the local header only to find where
/// the payload starts (30 fixed bytes + its own name/extra field
/// lengths), per the archive layout `np.savez` actually produces.
public enum NpzReader {
    public struct Entry: Equatable {
        public let name: String
        public let shape: [Int]
        public let descr: String
        public let fortranOrder: Bool
        public let data: Data
    }

    public enum NpzError: Error, Equatable, CustomStringConvertible {
        case notZip
        case compressed(String)
        case badNpyHeader(String)
        case missing(String)
        case badDType(String, expected: String)
        case badShape(String)
        case truncated(String)
        /// The EOCD member count is u16 and the
        /// central-directory size/offset and per-entry compressed size /
        /// local-header offset are u32. An archive past 4 GiB or 65 535
        /// members stores `0xFFFF` / `0xFFFFFFFF` in those fields and puts
        /// the real value in a zip64 record this reader does not parse.
        /// Named rather than reported as a generic truncation.
        case zip64NotSupported(String)

        /// The words a reply carries (an entry's name and a header's dtype are file text,
        /// quoted; the other payloads are this reader's own sentences, their names quoted where they are built).
        public var description: String {
            switch self {
            case .notZip: return "npz: not a zip archive"
            case .compressed(let name): return "npz: entry \(Reply.quoted(name)) is compressed (only stored entries are read)"
            case .badNpyHeader(let why): return "npz: bad .npy header: \(why)"
            case .missing(let name): return "npz: missing entry \(Reply.quoted(name))"
            case .badDType(let found, let expected): return "npz: dtype \(Reply.quoted(found)) is not \(expected)"
            case .badShape(let why): return "npz: bad shape: \(why)"
            case .truncated(let why): return "npz: truncated: \(why)"
            case .zip64NotSupported(let why): return "npz: zip64 not supported: \(why)"
            }
        }
    }

    private static let localSig: UInt32 = 0x0403_4b50
    private static let centralSig: UInt32 = 0x0201_4b50
    private static let eocdSig: UInt32 = 0x0605_4b50

    // MARK: - Little-endian scalar reads (absolute offsets into `data`)

    private static func u16(_ data: Data, _ off: Int) throws -> UInt16 {
        guard off >= 0, off + 2 <= data.count else { throw NpzError.truncated("u16 read past end at \(off)") }
        let base = data.startIndex + off
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func u32(_ data: Data, _ off: Int) throws -> UInt32 {
        guard off >= 0, off + 4 <= data.count else { throw NpzError.truncated("u32 read past end at \(off)") }
        let base = data.startIndex + off
        return UInt32(data[base])
             | (UInt32(data[base + 1]) << 8)
             | (UInt32(data[base + 2]) << 16)
             | (UInt32(data[base + 3]) << 24)
    }

    // MARK: - Zip container

    private struct CentralEntry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let localHeaderOffset: Int
    }

    /// Locate the end-of-central-directory record by scanning backward
    /// from the end of the file (the comment field, if any, is at most
    /// 65535 bytes).
    private static func findEOCD(_ data: Data) -> Int? {
        let n = data.count
        guard n >= 22 else { return nil }
        let windowStart = max(0, n - 22 - 65535)
        var i = n - 22
        while i >= windowStart {
            if let v = try? u32(data, i), v == eocdSig {
                return i
            }
            i -= 1
        }
        return nil
    }

    public static func entries(path: String) throws -> [String: Entry] {
        // Through `DaemonFile` (non-blocking, regular, contained, read once).
        let data: Data
        do { data = try DaemonFile.read(path) }
        catch DaemonFile.Refusal.missing { throw NpzError.truncated("file not found: \(Reply.quoted(path))") }
        return try entries(data: data)
    }

    /// The archive's entries from bytes the caller has read once (VIEW LOAD hashes and decodes
    /// the same copy).
    public static func entries(data: Data) throws -> [String: Entry] {
        let data = data.startIndex == 0 ? data : Data(data)
        guard let eocdOff = findEOCD(data) else {
            throw NpzError.notZip
        }

        let rawTotalEntries = try u16(data, eocdOff + 10)
        let rawCdSize = try u32(data, eocdOff + 12)
        let rawCdOffset = try u32(data, eocdOff + 16)
        // Zip64 placeholders in the END-OF-CENTRAL-DIRECTORY
        // record, refused by name (not as a generic truncation).
        if rawTotalEntries == 0xFFFF {
            throw NpzError.zip64NotSupported(
                "end-of-central-directory member count is the zip64 placeholder 65535 "
                + "(an archive with 65535 or more members); zip64 not supported")
        }
        if rawCdSize == 0xFFFF_FFFF || rawCdOffset == 0xFFFF_FFFF {
            throw NpzError.zip64NotSupported(
                "end-of-central-directory size/offset is the zip64 placeholder 4294967295 "
                + "(an archive at or past 4 GiB); zip64 not supported")
        }
        let totalEntries = Int(rawTotalEntries)
        let cdSize = Int(rawCdSize)
        let cdOffset = Int(rawCdOffset)

        guard cdOffset >= 0, cdOffset + cdSize <= data.count else {
            throw NpzError.truncated("central directory out of bounds")
        }

        var centrals: [CentralEntry] = []
        centrals.reserveCapacity(totalEntries)
        var off = cdOffset
        for _ in 0..<totalEntries {
            guard let sig = try? u32(data, off), sig == centralSig else {
                throw NpzError.truncated("central directory signature mismatch at \(off)")
            }
            let method = try u16(data, off + 10)
            let rawCompSize = try u32(data, off + 20)
            let nameLen = Int(try u16(data, off + 28))
            let extraLen = Int(try u16(data, off + 30))
            let commentLen = Int(try u16(data, off + 32))
            let rawLocalOffset = try u32(data, off + 42)
            // A CENTRAL record carrying a zip64 placeholder —
            // the real value lives in an extra field this reader does not
            // parse. Named, never silently taken at face value.
            if rawCompSize == 0xFFFF_FFFF || rawLocalOffset == 0xFFFF_FFFF {
                throw NpzError.zip64NotSupported(
                    "central directory entry at \(off) carries the zip64 placeholder 4294967295 "
                    + "for its compressed size or local-header offset; zip64 not supported")
            }
            let compSize = Int(rawCompSize)
            let localOffset = Int(rawLocalOffset)

            let nameStart = data.startIndex + off + 46
            guard nameStart + nameLen <= data.endIndex else {
                throw NpzError.truncated("central directory name past end")
            }
            guard let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLen)), encoding: .utf8) else {
                throw NpzError.badNpyHeader("non-UTF8 entry name")
            }

            centrals.append(CentralEntry(name: name, method: method, compressedSize: compSize, localHeaderOffset: localOffset))
            off += 46 + nameLen + extraLen + commentLen
        }

        var result: [String: Entry] = [:]
        for c in centrals {
            guard c.method == 0 else {
                throw NpzError.compressed(c.name)
            }
            guard let sig = try? u32(data, c.localHeaderOffset), sig == localSig else {
                throw NpzError.truncated("local header signature mismatch for \(Reply.quoted(c.name))")
            }
            let localNameLen = Int(try u16(data, c.localHeaderOffset + 26))
            let localExtraLen = Int(try u16(data, c.localHeaderOffset + 28))
            let payloadStart = data.startIndex + c.localHeaderOffset + 30 + localNameLen + localExtraLen
            let payloadEnd = payloadStart + c.compressedSize
            guard payloadStart >= data.startIndex, payloadEnd <= data.endIndex else {
                throw NpzError.truncated("payload out of bounds for \(Reply.quoted(c.name))")
            }
            let payload = data.subdata(in: payloadStart..<payloadEnd)

            let key = c.name.hasSuffix(".npy") ? String(c.name.dropLast(4)) : c.name
            let (shape, descr, fortranOrder, npyPayload) = try parseNpy(payload, name: c.name)
            result[key] = Entry(name: key, shape: shape, descr: descr, fortranOrder: fortranOrder, data: npyPayload)
        }
        return result
    }

    // MARK: - .npy header

    private static func parseNpy(_ data: Data, name: String) throws -> (shape: [Int], descr: String, fortranOrder: Bool, payload: Data) {
        guard data.count >= 10 else { throw NpzError.badNpyHeader("\(Reply.quoted(name)): too short for .npy magic") }
        let magic: [UInt8] = [0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59] // \x93NUMPY
        let base = data.startIndex
        for i in 0..<6 {
            guard data[base + i] == magic[i] else {
                throw NpzError.badNpyHeader("\(Reply.quoted(name)): bad magic")
            }
        }
        let major = data[base + 6]
        let minor = data[base + 7]
        // Only .npy 1.0, 2.0 and 3.0 exist. Every other major
        // (0, 4, 255 …) previously fell through to the 4-byte header-length
        // branch and parsed as if it were v2. Both bytes are now read and
        // refused by name, naming the value found.
        guard major == 1 || major == 2 || major == 3 else {
            throw NpzError.badNpyHeader(
                "\(Reply.quoted(name)): .npy major version \(major) not supported (only 1, 2 and 3 exist)")
        }
        guard minor == 0 else {
            throw NpzError.badNpyHeader(
                "\(Reply.quoted(name)): .npy minor version \(major).\(minor) not supported (only x.0 exists)")
        }
        let headerLenFieldSize: Int
        let headerLen: Int
        if major == 1 {
            headerLenFieldSize = 2
            headerLen = Int(try u16(data, 8))
        } else {
            headerLenFieldSize = 4
            headerLen = Int(try u32(data, 8))
        }
        let headerStart = base + 8 + headerLenFieldSize
        let headerEnd = headerStart + headerLen
        guard headerEnd <= data.endIndex else {
            throw NpzError.badNpyHeader("\(Reply.quoted(name)): header length past end")
        }
        let headerData = data.subdata(in: headerStart..<headerEnd)
        // v1/v2 declare latin-1 header dicts, v3 declares utf-8.
        let headerEncoding: String.Encoding = (major >= 3) ? .utf8 : .isoLatin1
        guard let headerStr = String(data: headerData, encoding: headerEncoding) else {
            throw NpzError.badNpyHeader("\(Reply.quoted(name)): header not decodable as \(major >= 3 ? "utf-8" : "latin-1")")
        }

        let descr = try extractQuoted(headerStr, key: "descr", name: name)
        let fortranOrder = try extractBool(headerStr, key: "fortran_order", name: name)
        let shape = try extractShape(headerStr, name: name)

        let payload = data.subdata(in: headerEnd..<data.endIndex)
        return (shape, descr, fortranOrder, payload)
    }

    private static func extractQuoted(_ header: String, key: String, name: String) throws -> String {
        guard let keyRange = header.range(of: "'\(key)'") else {
            throw NpzError.badNpyHeader("\(Reply.quoted(name)): missing '\(key)' in header")
        }
        var rest = header[keyRange.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else {
            throw NpzError.badNpyHeader("\(Reply.quoted(name)): malformed '\(key)' field")
        }
        rest = rest[rest.index(after: colon)...]
        guard let quoteStart = rest.firstIndex(where: { $0 == "'" || $0 == "\"" }) else {
            throw NpzError.badNpyHeader("\(Reply.quoted(name)): '\(key)' value not quoted")
        }
        let quoteChar = rest[quoteStart]
        let afterOpen = rest.index(after: quoteStart)
        guard let quoteEnd = rest[afterOpen...].firstIndex(of: quoteChar) else {
            throw NpzError.badNpyHeader("\(Reply.quoted(name)): '\(key)' unterminated string")
        }
        return String(rest[afterOpen..<quoteEnd])
    }

    private static func extractBool(_ header: String, key: String, name: String) throws -> Bool {
        guard let keyRange = header.range(of: "'\(key)'") else {
            throw NpzError.badNpyHeader("\(Reply.quoted(name)): missing '\(key)' in header")
        }
        var rest = header[keyRange.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else {
            throw NpzError.badNpyHeader("\(Reply.quoted(name)): malformed '\(key)' field")
        }
        rest = rest[rest.index(after: colon)...]
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("True") { return true }
        if trimmed.hasPrefix("False") { return false }
        throw NpzError.badNpyHeader("\(Reply.quoted(name)): '\(key)' not a bool literal")
    }

    private static func extractShape(_ header: String, name: String) throws -> [Int] {
        guard let keyRange = header.range(of: "'shape'") else {
            throw NpzError.badNpyHeader("\(Reply.quoted(name)): missing 'shape' in header")
        }
        let rest = header[keyRange.upperBound...]
        guard let openParen = rest.firstIndex(of: "("),
              let closeParen = rest[openParen...].firstIndex(of: ")") else {
            throw NpzError.badNpyHeader("\(Reply.quoted(name)): malformed 'shape' tuple")
        }
        let inner = rest[rest.index(after: openParen)..<closeParen]
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var shape: [Int] = []
        for p in parts {
            guard let v = Int(p) else {
                throw NpzError.badNpyHeader("\(Reply.quoted(name)): non-integer shape component \(Reply.quoted(String(p)))")
            }
            // A negative component made `elementCount` negative
            // and the payload-size guard then reported a size error instead
            // of naming the bad shape.
            guard v >= 0 else {
                throw NpzError.badShape("\(Reply.quoted(name)): negative shape component \(Reply.quoted(String(p)))")
            }
            shape.append(v)
        }
        return shape
    }

    // MARK: - Typed accessors

    /// `shape.reduce(1, *)` is a non-wrapping multiply — a
    /// crafted shape such as (2^32, 2^32) TRAPPED the process. Every step
    /// is overflow-reporting now, and the product (and the byte count it
    /// implies) is refused by name instead.
    private static func elementCount(_ shape: [Int], name: String) throws -> Int {
        var n = 1
        for d in shape {
            guard d >= 0 else {
                throw NpzError.badShape("\(Reply.quoted(name)): negative shape component \(d)")
            }
            let (product, overflow) = n.multipliedReportingOverflow(by: d)
            guard !overflow else {
                throw NpzError.badShape("\(Reply.quoted(name)): shape \(shape) overflows the element count")
            }
            n = product
        }
        return n
    }

    /// `elementCount * itemSize`, overflow-reported.
    private static func payloadBytes(_ n: Int, _ itemSize: Int, name: String) throws -> Int {
        let (bytes, overflow) = n.multipliedReportingOverflow(by: itemSize)
        guard !overflow else {
            throw NpzError.badShape("\(Reply.quoted(name)): \(n) elements x \(itemSize) bytes overflows the payload size")
        }
        return bytes
    }

    public static func float32(_ e: Entry) throws -> [Float] {
        guard e.descr == "<f4" || e.descr == "=f4" || e.descr == "f4" else {
            throw NpzError.badDType(e.descr, expected: "<f4")
        }
        guard !e.fortranOrder else {
            throw NpzError.badShape("\(Reply.quoted(e.name)): fortran_order not supported")
        }
        let n = try elementCount(e.shape, name: e.name)
        let expectedBytes = try payloadBytes(n, 4, name: e.name)
        guard e.data.count == expectedBytes else {
            throw NpzError.badShape("\(Reply.quoted(e.name)): payload size \(e.data.count) != \(n) * 4")
        }
        var result = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let bits = try u32(e.data, i * 4)
            result[i] = Float(bitPattern: bits)
        }
        return result
    }

    public static func float64(_ e: Entry) throws -> [Double] {
        guard e.descr == "<f8" || e.descr == "=f8" || e.descr == "f8" else {
            throw NpzError.badDType(e.descr, expected: "<f8")
        }
        guard !e.fortranOrder else {
            throw NpzError.badShape("\(Reply.quoted(e.name)): fortran_order not supported")
        }
        let n = try elementCount(e.shape, name: e.name)
        let expectedBytes = try payloadBytes(n, 8, name: e.name)
        guard e.data.count == expectedBytes else {
            throw NpzError.badShape("\(Reply.quoted(e.name)): payload size \(e.data.count) != \(n) * 8")
        }
        var result = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let off = i * 8
            let lo = try u32(e.data, off)
            let hi = try u32(e.data, off + 4)
            let bits = UInt64(lo) | (UInt64(hi) << 32)
            result[i] = Double(bitPattern: bits)
        }
        return result
    }

    public static func int64(_ e: Entry) throws -> [Int64] {
        guard e.descr == "<i8" || e.descr == "=i8" || e.descr == "i8" else {
            throw NpzError.badDType(e.descr, expected: "<i8")
        }
        guard !e.fortranOrder else {
            throw NpzError.badShape("\(Reply.quoted(e.name)): fortran_order not supported")
        }
        let n = try elementCount(e.shape, name: e.name)
        let expectedBytes = try payloadBytes(n, 8, name: e.name)
        guard e.data.count == expectedBytes else {
            throw NpzError.badShape("\(Reply.quoted(e.name)): payload size \(e.data.count) != \(n) * 8")
        }
        var result = [Int64](repeating: 0, count: n)
        for i in 0..<n {
            let off = i * 8
            let lo = try u32(e.data, off)
            let hi = try u32(e.data, off + 4)
            let bits = UInt64(lo) | (UInt64(hi) << 32)
            result[i] = Int64(bitPattern: bits)
        }
        return result
    }
}
