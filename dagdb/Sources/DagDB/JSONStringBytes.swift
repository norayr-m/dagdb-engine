import Foundation

/// The escaped string bytes a `JSONEncoder` would write for a value, counted by running
/// the value's own `encode(to:)` into an encoder that writes nothing: every key a keyed container is given (a coding
/// key or a dictionary's key, as JSONEncoder writes it with the default key strategy) and every string value, each as
/// `TwinState.escapedJSONLength` counts it (quotes included). A field the encoder writes is counted because the
/// encoder walked it, never because a hand-kept list named it. Numbers, booleans and nulls carry no string bytes.
/// JSONEncoder's own special cases are followed: `Data` is written as base64 text, `URL` as its absolute string, `Date`
/// (deferred to Date: a number) and `Decimal` as numbers. The walk allocates no output: only the strings it is handed
/// (and the containers' boxes the Encoder protocol makes, freed as it goes); its coding path stays empty.
///
/// Amateur engineering project; no competitive claims; errors likely.
public enum JSONStringBytes {
    /// The escaped string bytes (keys and string values, quotes included) of `value` as `JSONEncoder` writes it.
    public static func count<T: Encodable>(_ value: T) throws -> Int {
        let sink = Sink()
        try encodeValue(value, sink, [])
        return sink.n
    }

    final class Sink { var n = 0 }

    @inline(__always)
    static func noStrings<T>(_: T.Type) -> Bool {
        T.self == Double.self || T.self == Float.self || T.self == Int.self || T.self == UInt64.self
            || T.self == UInt32.self || T.self == Int64.self || T.self == Int32.self || T.self == UInt8.self
            || T.self == UInt16.self || T.self == Int16.self || T.self == Int8.self || T.self == UInt.self
            || T.self == Bool.self
    }

    static func encodeValue<T: Encodable>(_ v: T, _ sink: Sink, _ path: [CodingKey]) throws {
        // Type identity first (no dynamic cast on the hot path: a ring set's every cell comes through here).
        if noStrings(T.self) || T.self == Date.self || T.self == Decimal.self { return }
        if T.self == String.self { sink.n += TwinState.escapedJSONLength(v as! String); return }
        if T.self == Data.self { sink.n += TwinState.escapedJSONLength((v as! Data).base64EncodedString()); return }
        if T.self == URL.self { sink.n += TwinState.escapedJSONLength((v as! URL).absoluteString); return }
        try v.encode(to: Counter(sink: sink, codingPath: path))
    }

    struct Counter: Encoder {
        let sink: Sink
        var codingPath: [CodingKey]
        var userInfo: [CodingUserInfoKey: Any] { [:] }
        func container<K: CodingKey>(keyedBy type: K.Type) -> KeyedEncodingContainer<K> {
            KeyedEncodingContainer(Keyed<K>(sink: sink, codingPath: codingPath))
        }
        func unkeyedContainer() -> UnkeyedEncodingContainer { Unkeyed(sink: sink, codingPath: codingPath) }
        func singleValueContainer() -> SingleValueEncodingContainer { Single(sink: sink, codingPath: codingPath) }
    }

    struct Keyed<K: CodingKey>: KeyedEncodingContainerProtocol {
        let sink: Sink
        var codingPath: [CodingKey]
        @inline(__always) func key(_ k: K) { sink.n += TwinState.escapedJSONLength(k.stringValue) }
        mutating func encodeNil(forKey k: K) throws { key(k) }
        mutating func encode(_ v: Bool, forKey k: K) throws { key(k) }
        mutating func encode(_ v: String, forKey k: K) throws { key(k); sink.n += TwinState.escapedJSONLength(v) }
        mutating func encode(_ v: Double, forKey k: K) throws { key(k) }
        mutating func encode(_ v: Float, forKey k: K) throws { key(k) }
        mutating func encode(_ v: Int, forKey k: K) throws { key(k) }
        mutating func encode(_ v: Int8, forKey k: K) throws { key(k) }
        mutating func encode(_ v: Int16, forKey k: K) throws { key(k) }
        mutating func encode(_ v: Int32, forKey k: K) throws { key(k) }
        mutating func encode(_ v: Int64, forKey k: K) throws { key(k) }
        mutating func encode(_ v: UInt, forKey k: K) throws { key(k) }
        mutating func encode(_ v: UInt8, forKey k: K) throws { key(k) }
        mutating func encode(_ v: UInt16, forKey k: K) throws { key(k) }
        mutating func encode(_ v: UInt32, forKey k: K) throws { key(k) }
        mutating func encode(_ v: UInt64, forKey k: K) throws { key(k) }
        mutating func encode<T: Encodable>(_ v: T, forKey k: K) throws {
            key(k); try JSONStringBytes.encodeValue(v, sink, codingPath)
        }
        mutating func nestedContainer<N: CodingKey>(keyedBy: N.Type, forKey k: K) -> KeyedEncodingContainer<N> {
            key(k); return KeyedEncodingContainer(Keyed<N>(sink: sink, codingPath: codingPath))
        }
        mutating func nestedUnkeyedContainer(forKey k: K) -> UnkeyedEncodingContainer {
            key(k); return Unkeyed(sink: sink, codingPath: codingPath)
        }
        mutating func superEncoder() -> Encoder {
            sink.n += TwinState.escapedJSONLength("super"); return Counter(sink: sink, codingPath: codingPath)
        }
        mutating func superEncoder(forKey k: K) -> Encoder { key(k); return Counter(sink: sink, codingPath: codingPath) }
    }

    struct Unkeyed: UnkeyedEncodingContainer {
        let sink: Sink
        var codingPath: [CodingKey]
        var count = 0
        init(sink: Sink, codingPath: [CodingKey]) { self.sink = sink; self.codingPath = codingPath }
        mutating func encodeNil() throws { count += 1 }
        mutating func encode(_ v: Bool) throws { count += 1 }
        mutating func encode(_ v: String) throws { count += 1; sink.n += TwinState.escapedJSONLength(v) }
        mutating func encode(_ v: Double) throws { count += 1 }
        mutating func encode(_ v: Float) throws { count += 1 }
        mutating func encode(_ v: Int) throws { count += 1 }
        mutating func encode(_ v: Int8) throws { count += 1 }
        mutating func encode(_ v: Int16) throws { count += 1 }
        mutating func encode(_ v: Int32) throws { count += 1 }
        mutating func encode(_ v: Int64) throws { count += 1 }
        mutating func encode(_ v: UInt) throws { count += 1 }
        mutating func encode(_ v: UInt8) throws { count += 1 }
        mutating func encode(_ v: UInt16) throws { count += 1 }
        mutating func encode(_ v: UInt32) throws { count += 1 }
        mutating func encode(_ v: UInt64) throws { count += 1 }
        mutating func encode<T: Encodable>(_ v: T) throws { count += 1; try JSONStringBytes.encodeValue(v, sink, codingPath) }
        mutating func nestedContainer<N: CodingKey>(keyedBy: N.Type) -> KeyedEncodingContainer<N> {
            count += 1; return KeyedEncodingContainer(Keyed<N>(sink: sink, codingPath: codingPath))
        }
        mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer { count += 1; return Unkeyed(sink: sink, codingPath: codingPath) }
        mutating func superEncoder() -> Encoder { count += 1; return Counter(sink: sink, codingPath: codingPath) }
    }

    struct Single: SingleValueEncodingContainer {
        let sink: Sink
        var codingPath: [CodingKey]
        mutating func encodeNil() throws {}
        mutating func encode(_ v: Bool) throws {}
        mutating func encode(_ v: String) throws { sink.n += TwinState.escapedJSONLength(v) }
        mutating func encode(_ v: Double) throws {}
        mutating func encode(_ v: Float) throws {}
        mutating func encode(_ v: Int) throws {}
        mutating func encode(_ v: Int8) throws {}
        mutating func encode(_ v: Int16) throws {}
        mutating func encode(_ v: Int32) throws {}
        mutating func encode(_ v: Int64) throws {}
        mutating func encode(_ v: UInt) throws {}
        mutating func encode(_ v: UInt8) throws {}
        mutating func encode(_ v: UInt16) throws {}
        mutating func encode(_ v: UInt32) throws {}
        mutating func encode(_ v: UInt64) throws {}
        mutating func encode<T: Encodable>(_ v: T) throws { try JSONStringBytes.encodeValue(v, sink, codingPath) }
    }
}
