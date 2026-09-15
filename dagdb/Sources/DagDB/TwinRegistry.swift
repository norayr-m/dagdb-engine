import Foundation

/// Id format shared by every `TwinRegistry` — a one-letter prefix plus an
/// 8-hex-digit counter value: `"<prefix>%08x"`. Kept as a free enum (not
/// nested in the generic class) so `TwinState.nextId(prefix:)` can peek a
/// registry's next id without depending on that registry's `Entry` type.
enum TwinIdFormat {
    static func format(prefix: Character, _ n: UInt64) -> String {
        String(prefix) + String(format: "%08x", UInt32(truncatingIfNeeded: n))
    }

    /// nil iff `id` is not exactly `prefix` followed by 8 hex digits.
    static func parse(prefix: Character, _ id: String) -> UInt64? {
        guard id.count == 9, id.first == prefix else { return nil }
        let hex = id.dropFirst()
        guard hex.count == 8, hex.allSatisfy(\.isHexDigit), let n = UInt64(hex, radix: 16) else {
            return nil
        }
        return n
    }
}

/// Typed-id registry — the reader-session pattern (dictionary + counter +
/// typed error enum + prefixed ids, see `DagDBReaderSession.swift`)
/// generalized to every twin primitive kind. One registry per kind; ids
/// are `"<prefix>%08x"` of a monotonic counter that never reuses a value —
/// `open(_:id:)` (the restore path) raises the counter to match any id it
/// is given, so a later live `open(_:)` never collides with a restored id.
public final class TwinRegistry<Entry> {
    public let prefix: Character
    public private(set) var counter: UInt64

    private var storage: [String: Entry] = [:]

    public init(prefix: Character, counter: UInt64 = 0) {
        self.prefix = prefix
        self.counter = counter
    }

    public enum RegistryError: Error, Equatable, CustomStringConvertible {
        case notFound(String)
        case duplicateId(String)
        case badId(String)

        public var description: String {
            switch self {
            case .notFound(let id): return "not found: \(id)"
            case .duplicateId(let id): return "duplicate id: \(id)"
            case .badId(let id): return "bad id: \(id)"
            }
        }
    }

    /// Open a fresh entry under a freshly minted id (`"<prefix>%08x"` of
    /// the counter, post-increment).
    ///
    /// Finding 59: the id formats only the low 32 bits of the counter, so
    /// past 2^32 opens a minted id can land on a live entry. That case now
    /// refuses by name — `duplicateId`, exactly as the explicit-id path
    /// does — instead of silently overwriting the entry that holds it.
    @discardableResult
    public func open(_ entry: Entry) throws -> String {
        counter &+= 1
        let id = TwinIdFormat.format(prefix: prefix, counter)
        guard storage[id] == nil else {
            throw RegistryError.duplicateId(id)
        }
        storage[id] = entry
        return id
    }

    /// Open an entry under an EXPLICIT id — the restore/replay path.
    /// Validates the id is `prefix` + 8 hex digits, refuses a duplicate,
    /// and raises the counter to at least the id's numeric value so a
    /// later `open(_:)` never mints a colliding id.
    public func open(_ entry: Entry, id: String) throws {
        guard let n = TwinIdFormat.parse(prefix: prefix, id) else {
            throw RegistryError.badId(id)
        }
        guard storage[id] == nil else {
            throw RegistryError.duplicateId(id)
        }
        storage[id] = entry
        counter = max(counter, n)
    }

    public func get(_ id: String) -> Entry? { storage[id] }

    /// Mutate an existing entry in place. Throws `notFound` if `id` is
    /// not currently open; if `body` throws, the entry is left unchanged.
    public func update(_ id: String, _ body: (inout Entry) throws -> Void) throws {
        guard var entry = storage[id] else { throw RegistryError.notFound(id) }
        try body(&entry)
        storage[id] = entry
    }

    /// Replace an existing entry wholesale. Throws `notFound` if `id` is
    /// not currently open (this is a replace, not an open).
    public func replace(_ id: String, with entry: Entry) throws {
        guard storage[id] != nil else { throw RegistryError.notFound(id) }
        storage[id] = entry
    }

    @discardableResult
    public func close(_ id: String) -> Bool {
        guard storage[id] != nil else { return false }
        storage.removeValue(forKey: id)
        return true
    }

    public var ids: [String] { Array(storage.keys) }
    public var openCount: Int { storage.count }
    public func closeAll() { storage.removeAll() }
    public var entries: [String: Entry] { storage }

    /// Package-internal: used by `TwinState.reset()` to return a registry
    /// to its just-initialized state (empty, counter at 0) — not part of
    /// the public daemon-facing surface.
    func resetCounter(to n: UInt64 = 0) { counter = n }
}

/// One logged/replayed mutation against a `TwinState`. Every case carries
/// the id it acts on — for `open` ops that id is minted by the caller via
/// `TwinState.nextId(prefix:)` before construction, so the same `TwinOp`
/// value is what both the live apply and a WAL/snapshot replay consume.
public enum TwinOp: Equatable {
    case streamOpen(id: String, name: String, stateHi: UInt64, stateLo: UInt64, incHi: UInt64, incLo: UInt64)
    case streamState(id: String, stateHi: UInt64, stateLo: UInt64, draws: UInt64)
    case recordOpen(id: String, name: String, header: StreamHeader, stateHi: UInt64, stateLo: UInt64, incHi: UInt64, incLo: UInt64)
    case recordSlice(id: String, count: UInt32)
    case ringsOpen(id: String, gear: UInt64, rings: UInt32, cells: UInt32)
    case ringsWrite(id: String, values: [Float])
    case clockOpen(id: String)
    case clockAdvance(id: String, count: UInt64, value: Float)
    case gearOpen(id: String, clockId: String, name: String, num: UInt64, den: UInt64)
    case layoutOpen(id: String, cost: [[Double]], minTier: [Int])
    case alarmLoad(id: String, path: String, sha256: String)
    case bankOpen(id: String, name: String, spec: WaveBank.Spec)
    case viewLoad(id: String, path: String, sha256: String)
    case kernelLoad(id: String, path: String, sha256: String, tauA: Double?, tauB: Double?, sigmaSource: Double?, declaredWarmup: Int?)
    case hookOpen(id: String, params: AttentionHook.Params)
    case hookStep(id: String, count: Int)
    case close(id: String)
}
