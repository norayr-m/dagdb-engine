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

    public enum NpzError: Error, Equatable {
        case notZip
        case compressed(String)
        case badNpyHeader(String)
        case missing(String)
        case badDType(String, expected: String)
        case badShape(String)
        case truncated(String)
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
        guard FileManager.default.fileExists(atPath: path) else {
            throw NpzError.truncated("file not found: \(path)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let eocdOff = findEOCD(data) else {
            throw NpzError.notZip
        }

        let totalEntries = Int(try u16(data, eocdOff + 10))
        let cdSize = Int(try u32(data, eocdOff + 12))
        let cdOffset = Int(try u32(data, eocdOff + 16))

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
            let compSize = Int(try u32(data, off + 20))
            let nameLen = Int(try u16(data, off + 28))
            let extraLen = Int(try u16(data, off + 30))
            let commentLen = Int(try u16(data, off + 32))
            let localOffset = Int(try u32(data, off + 42))

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
                throw NpzError.truncated("local header signature mismatch for \(c.name)")
            }
            let localNameLen = Int(try u16(data, c.localHeaderOffset + 26))
            let localExtraLen = Int(try u16(data, c.localHeaderOffset + 28))
            let payloadStart = data.startIndex + c.localHeaderOffset + 30 + localNameLen + localExtraLen
            let payloadEnd = payloadStart + c.compressedSize
            guard payloadStart >= data.startIndex, payloadEnd <= data.endIndex else {
                throw NpzError.truncated("payload out of bounds for \(c.name)")
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
        guard data.count >= 10 else { throw NpzError.badNpyHeader("\(name): too short for .npy magic") }
        let magic: [UInt8] = [0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59] // \x93NUMPY
        let base = data.startIndex
        for i in 0..<6 {
            guard data[base + i] == magic[i] else {
                throw NpzError.badNpyHeader("\(name): bad magic")
            }
        }
        let major = data[base + 6]
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
            throw NpzError.badNpyHeader("\(name): header length past end")
        }
        let headerData = data.subdata(in: headerStart..<headerEnd)
        guard let headerStr = String(data: headerData, encoding: .isoLatin1) else {
            throw NpzError.badNpyHeader("\(name): header not decodable")
        }

        let descr = try extractQuoted(headerStr, key: "descr", name: name)
        let fortranOrder = try extractBool(headerStr, key: "fortran_order", name: name)
        let shape = try extractShape(headerStr, name: name)

        let payload = data.subdata(in: headerEnd..<data.endIndex)
        return (shape, descr, fortranOrder, payload)
    }

    private static func extractQuoted(_ header: String, key: String, name: String) throws -> String {
        guard let keyRange = header.range(of: "'\(key)'") else {
            throw NpzError.badNpyHeader("\(name): missing '\(key)' in header")
        }
        var rest = header[keyRange.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else {
            throw NpzError.badNpyHeader("\(name): malformed '\(key)' field")
        }
        rest = rest[rest.index(after: colon)...]
        guard let quoteStart = rest.firstIndex(where: { $0 == "'" || $0 == "\"" }) else {
            throw NpzError.badNpyHeader("\(name): '\(key)' value not quoted")
        }
        let quoteChar = rest[quoteStart]
        let afterOpen = rest.index(after: quoteStart)
        guard let quoteEnd = rest[afterOpen...].firstIndex(of: quoteChar) else {
            throw NpzError.badNpyHeader("\(name): '\(key)' unterminated string")
        }
        return String(rest[afterOpen..<quoteEnd])
    }

    private static func extractBool(_ header: String, key: String, name: String) throws -> Bool {
        guard let keyRange = header.range(of: "'\(key)'") else {
            throw NpzError.badNpyHeader("\(name): missing '\(key)' in header")
        }
        var rest = header[keyRange.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else {
            throw NpzError.badNpyHeader("\(name): malformed '\(key)' field")
        }
        rest = rest[rest.index(after: colon)...]
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("True") { return true }
        if trimmed.hasPrefix("False") { return false }
        throw NpzError.badNpyHeader("\(name): '\(key)' not a bool literal")
    }

    private static func extractShape(_ header: String, name: String) throws -> [Int] {
        guard let keyRange = header.range(of: "'shape'") else {
            throw NpzError.badNpyHeader("\(name): missing 'shape' in header")
        }
        let rest = header[keyRange.upperBound...]
        guard let openParen = rest.firstIndex(of: "("),
              let closeParen = rest[openParen...].firstIndex(of: ")") else {
            throw NpzError.badNpyHeader("\(name): malformed 'shape' tuple")
        }
        let inner = rest[rest.index(after: openParen)..<closeParen]
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var shape: [Int] = []
        for p in parts {
            guard let v = Int(p) else {
                throw NpzError.badNpyHeader("\(name): non-integer shape component '\(p)'")
            }
            shape.append(v)
        }
        return shape
    }

    // MARK: - Typed accessors

    private static func elementCount(_ shape: [Int]) -> Int {
        shape.isEmpty ? 1 : shape.reduce(1, *)
    }

    public static func float32(_ e: Entry) throws -> [Float] {
        guard e.descr == "<f4" || e.descr == "=f4" || e.descr == "f4" else {
            throw NpzError.badDType(e.descr, expected: "<f4")
        }
        guard !e.fortranOrder else {
            throw NpzError.badShape("\(e.name): fortran_order not supported")
        }
        let n = elementCount(e.shape)
        guard e.data.count == n * 4 else {
            throw NpzError.badShape("\(e.name): payload size \(e.data.count) != \(n) * 4")
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
            throw NpzError.badShape("\(e.name): fortran_order not supported")
        }
        let n = elementCount(e.shape)
        guard e.data.count == n * 8 else {
            throw NpzError.badShape("\(e.name): payload size \(e.data.count) != \(n) * 8")
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
            throw NpzError.badShape("\(e.name): fortran_order not supported")
        }
        let n = elementCount(e.shape)
        guard e.data.count == n * 8 else {
            throw NpzError.badShape("\(e.name): payload size \(e.data.count) != \(n) * 8")
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
