/// DagDBEngine+Ternary — the library and the lane checks of the native
/// ternary tick.
///
/// The four lanes are plain MTLBuffers like every other lane; this file
/// holds what is not a plain copy: the table library (dense ids 0 ..< count,
/// grown by doubling), the whole-state check every load and save path runs,
/// and the binary-only predicate the refusals of `tickWithResonance` and
/// `.dagb` use.

import Metal
import Foundation

extension DagDBEngine {

    // MARK: - The library

    /// All defined tables, `tableSize` bytes each, in id order.
    public func libraryBytes() -> [UInt8] {
        let len = ttableCount * TernaryReference.tableSize
        guard len > 0 else { return [] }
        let p = ttableBuf.contents().bindMemory(to: UInt8.self, capacity: len)
        return Array(UnsafeBufferPointer(start: p, count: len))
    }

    /// Table `id`'s bytes, or nil past the library.
    public func tableBytes(_ id: Int) -> [UInt8]? {
        guard id >= 0 && id < ttableCount else { return nil }
        let p = ttableBuf.contents().advanced(by: id * TernaryReference.tableSize)
            .bindMemory(to: UInt8.self, capacity: TernaryReference.tableSize)
        return Array(UnsafeBufferPointer(start: p, count: TernaryReference.tableSize))
    }

    /// Room for `tables` tables, keeping the defined ones.
    func ensureTableCapacity(_ tables: Int) throws {
        guard tables > ttableCapacity else { return }
        var cap = max(ttableCapacity, 1)
        while cap < tables { cap *= 2 }
        cap = max(min(cap, TernaryReference.maxTables), tables)
        #if DEBUG || DAGDB_FAULT_INJECTION
        // Fault-injection seam: the growth finds no buffer.
        if DagDBFaultInjection.fires("TABLE_ALLOC") { throw EngineError.bufferAllocationFailed }
        #endif
        guard let nb = device.makeBuffer(length: cap * TernaryReference.tableSize,
                                         options: .storageModeShared) else {
            throw EngineError.bufferAllocationFailed
        }
        let keep = ttableCount * TernaryReference.tableSize
        if keep > 0 { nb.contents().copyMemory(from: ttableBuf.contents(), byteCount: keep) }
        ttableBuf = nb
        ttableCapacity = cap
    }

    /// Grow the library's room to `tables`
    /// tables BEFORE a verb logs a table record or a loader commits a body,
    /// so the one fallible step of a table write or a library replace (the
    /// buffer's growth) comes before every change. Idempotent; the room is
    /// invisible (no table is defined by it).
    public func reserveTableCapacity(_ tables: Int) throws {
        try ensureTableCapacity(tables)
    }

    /// Why writing `count` tables at `first` would be refused, or nil.
    /// `bytes` is checked for values ≥ 3.
    public func tableWriteRefusal(first: Int, count: Int, bytes: UnsafeBufferPointer<UInt8>) -> String? {
        if count < 1 { return "table count \(count) must be at least 1" }
        if first < 0 || first > ttableCount {
            return "table id \(first) leaves a gap: the library holds \(ttableCount) table(s), ids 0..<\(ttableCount); define id \(ttableCount) next"
        }
        if first + count > TernaryReference.maxTables {
            return "tables \(first)..<\(first + count) exceed the library's \(TernaryReference.maxTables)"
        }
        if bytes.count != count * TernaryReference.tableSize {
            return "\(bytes.count) table bytes for \(count) table(s), expected \(count * TernaryReference.tableSize)"
        }
        for i in 0..<bytes.count where bytes[i] >= 3 {
            return "table \(first + i / TernaryReference.tableSize) byte \(i % TernaryReference.tableSize) is \(bytes[i]); table bytes are 0, 1 or 2"
        }
        return nil
    }

    /// Write `count` tables starting at `first` (overwrite and/or append).
    /// Refused by name, before anything is written, per `tableWriteRefusal`.
    public func writeTables(first: Int, count: Int, bytes: UnsafeBufferPointer<UInt8>) throws {
        if let why = tableWriteRefusal(first: first, count: count, bytes: bytes) {
            throw EngineError.ternary(why)
        }
        try ensureTableCapacity(first + count)
        ttableBuf.contents().advanced(by: first * TernaryReference.tableSize)
            .copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        ttableCount = max(ttableCount, first + count)
    }

    public func writeTables(first: Int, bytes: [UInt8]) throws {
        try bytes.withUnsafeBufferPointer {
            try writeTables(first: first, count: bytes.count / TernaryReference.tableSize, bytes: $0)
        }
    }

    /// Replace the whole library (load paths). Refused by name, before
    /// anything changes, if the bytes are not a whole number of valid tables.
    public func replaceLibrary(_ bytes: [UInt8]) throws {
        if let why = TernaryReference.libraryRefusal(bytes) { throw EngineError.ternary(why) }
        let count = bytes.count / TernaryReference.tableSize
        try ensureTableCapacity(count)
        if count > 0 {
            bytes.withUnsafeBytes { ttableBuf.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }
        ttableCount = count
    }

    // MARK: - Lanes

    // `modePtr` (raw, writable), `modeLane` (read-only), `setNodeMode` and
    // `writeModeLane` live in DagDBEngine.swift beside the lane's private
    // storage and the non-binary count they keep.
    public var ttableIdPtr: UnsafeMutablePointer<UInt16> {
        ttableIdBuf.contents().bindMemory(to: UInt16.self, capacity: max(nodeCount, 1))
    }
    public var thrLoPtr: UnsafeMutablePointer<Float> {
        thrLoBuf.contents().bindMemory(to: Float.self, capacity: max(nodeCount, 1))
    }
    public var thrHiPtr: UnsafeMutablePointer<Float> {
        thrHiBuf.contents().bindMemory(to: Float.self, capacity: max(nodeCount, 1))
    }

    /// Reset the four lanes to BINARY defaults and empty the library (the
    /// state a v1–v7 file, a v1 JSON/CSV file or a fresh engine describes).
    public func resetTernaryLanes() {
        let n = nodeCount
        // Lanes that were never allocated already hold the defaults.
        guard n > 0, ternaryLanesAllocated else { ttableCount = 0; return }
        writeModeLane { memset($0, 0, n) }
        memset(ttableIdBuf.contents(), 0, n * 2)
        memset(thrLoBuf.contents(), 0, n * 4)
        memset(thrHiBuf.contents(), 0, n * 4)
        ttableCount = 0
    }

    /// True when any of the four lanes holds a non-default value (bit
    /// pattern) or the library holds a table — the state a v1–v7 file
    /// cannot describe.
    public func hasTernaryContent() -> Bool {
        if ttableCount > 0 { return true }
        guard let v = ternaryLaneView else { return false }       // unallocated: all defaults
        let n = nodeCount
        let m = v.mode, t = v.ttableId
        let lo = UnsafeRawPointer(v.thrLo).bindMemory(to: UInt32.self, capacity: max(n, 1))
        let hi = UnsafeRawPointer(v.thrHi).bindMemory(to: UInt32.self, capacity: max(n, 1))
        for i in 0..<n where m[i] != 0 || t[i] != 0 || lo[i] != 0 || hi[i] != 0 { return true }
        return false
    }

    /// The first non-binary node, or nil when every node is binary.
    public func firstNonBinaryNode() -> Int? {
        guard let m = ternaryLaneView?.mode else { return nil }
        for i in 0..<nodeCount where m[i] != 0 { return i }
        return nil
    }

    /// Number of non-binary nodes, by a scan of the lane (the independent
    /// count; `nonBinaryNodeCount` is the one the tick reads).
    public func ternaryNodeCount() -> Int {
        guard let m = ternaryLaneView?.mode else { return 0 }
        var c = 0
        for i in 0..<nodeCount where m[i] != 0 { c += 1 }
        return c
    }

    /// The whole live state checked against every rule refused on load
    /// and on write. Nil when valid.
    public func ternaryStateViolation() -> String? {
        let n = nodeCount
        let lib = libraryBytes()
        guard let v = ternaryLaneView else {
            // Unallocated lanes are all BINARY with legal default
            // thresholds, a node the per-node rules always pass — only the
            // library's own rules can refuse.
            var m: UInt8 = 0, t: UInt16 = 0, f1: Float = 0, f2: Float = 0, b: UInt8 = 0
            return lib.withUnsafeBufferPointer { tb in
                TernaryReference.stateViolation(n: 0, mode: &m, ttableId: &t, thrLo: &f1, thrHi: &f2,
                                                truth: &b, isRegister: nil, tables: tb)
            }
        }
        return lib.withUnsafeBufferPointer { tb in
            TernaryReference.stateViolation(
                n: n, mode: v.mode, ttableId: v.ttableId,
                thrLo: v.thrLo, thrHi: v.thrHi,
                truth: UnsafePointer(truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: max(n, 1))),
                isRegister: UnsafePointer(isRegisterBuf.contents().bindMemory(to: UInt8.self, capacity: max(n, 1))),
                tables: tb)
        }
    }
}
