import Foundation

/// TwinWALCodec — binary wire format for `TwinOp`, the payload carried by
/// WAL opcodes 0x20–0x2C (twin registry ops, the interface phase).
///
/// Format (little-endian throughout, no padding):
///   - String:  u16 length + UTF-8 bytes.
///   - u32/u64: little-endian, unsigned.
///   - f32/f64: IEEE-754 `bitPattern`, little-endian.
///   - Array:   u32 count prefix, then each element in order (a nested
///     array — `cost[pocket][tier]` — nests a count-prefixed row inside a
///     count-prefixed table).
///
/// `decode` returns `nil` on ANY length mismatch or invalid-UTF-8 string —
/// including a trailing byte the encoding for that opcode doesn't account
/// for. WAL replay treats a `nil` decode as "skip this record," never a
/// fatal error (interface-phase convention 15 / T6).
public enum TwinWALCodec {
    /// Payload size ceiling — guards against a corrupt length prefix
    /// driving an unbounded allocation during decode.
    public static let maxPayloadBytes = 1 << 20

    // MARK: - encode

    public static func encode(_ op: TwinOp) -> (opcode: DagDBWAL.Opcode, payload: Data) {
        var d = Data()
        let opcode: DagDBWAL.Opcode

        switch op {
        case .streamOpen(let id, let name, let stateHi, let stateLo, let incHi, let incLo):
            opcode = .twinStreamOpen
            writeString(id, &d)
            writeString(name, &d)
            writeU64(stateHi, &d); writeU64(stateLo, &d)
            writeU64(incHi, &d); writeU64(incLo, &d)

        case .streamState(let id, let stateHi, let stateLo, let draws):
            opcode = .twinStreamState
            writeString(id, &d)
            writeU64(stateHi, &d); writeU64(stateLo, &d); writeU64(draws, &d)

        case .recordOpen(let id, let name, let header, let stateHi, let stateLo, let incHi, let incLo):
            opcode = .twinRecordOpen
            writeString(id, &d)
            writeString(name, &d)
            writeF64(header.signalBandHz, &d)
            writeF64(header.tauWindowSec, &d)
            writeF64(header.combRateHz, &d)
            writeF64(header.firstEchoSec, &d)
            writeF64(header.recordWindowSec, &d)
            writeF64(header.stepSec, &d)
            writeF64(header.clockSyncFloorSec, &d)
            writeU64(stateHi, &d); writeU64(stateLo, &d)
            writeU64(incHi, &d); writeU64(incLo, &d)

        case .recordSlice(let id, let count):
            opcode = .twinRecordSlice
            writeString(id, &d)
            writeU32(count, &d)

        case .ringsOpen(let id, let gear, let rings, let cells):
            opcode = .twinRingsOpen
            writeString(id, &d)
            writeU64(gear, &d)
            writeU32(rings, &d)
            writeU32(cells, &d)

        case .ringsWrite(let id, let values):
            opcode = .twinRingsWrite
            writeString(id, &d)
            writeU32(UInt32(values.count), &d)
            for v in values { writeF32(v, &d) }

        case .clockOpen(let id):
            opcode = .twinClockOpen
            writeString(id, &d)

        case .clockAdvance(let id, let count, let value):
            opcode = .twinClockAdvance
            writeString(id, &d)
            writeU64(count, &d)
            writeF32(value, &d)

        case .gearOpen(let id, let clockId, let name, let num, let den):
            opcode = .twinGearOpen
            writeString(id, &d)
            writeString(clockId, &d)
            writeString(name, &d)
            writeU64(num, &d)
            writeU64(den, &d)

        case .layoutOpen(let id, let cost, let minTier):
            opcode = .twinLayoutOpen
            writeString(id, &d)
            writeU32(UInt32(cost.count), &d)
            for row in cost {
                writeU32(UInt32(row.count), &d)
                for c in row { writeF64(c, &d) }
            }
            writeU32(UInt32(minTier.count), &d)
            for t in minTier { writeI32(Int32(truncatingIfNeeded: t), &d) }

        case .alarmLoad(let id, let path, let sha256):
            opcode = .twinAlarmLoad
            writeString(id, &d)
            writeString(path, &d)
            writeString(sha256, &d)

        case .bankOpen(let id, let name, let spec):
            opcode = .twinBankOpen
            writeString(id, &d)
            writeString(name, &d)
            writeU64(UInt64(spec.samples), &d)
            writeF64(spec.sampleRate, &d)
            writeF64(spec.f0, &d)
            writeU32(UInt32(spec.harmonics), &d)
            writeU32(UInt32(spec.gaborCenters), &d)
            writeU32(UInt32(spec.gaborFreqs), &d)
            writeF64(spec.gaborSigmaFrac, &d)

        case .viewLoad(let id, let path, let sha256):
            opcode = .twinViewLoad
            writeString(id, &d)
            writeString(path, &d)
            writeString(sha256, &d)

        case .kernelLoad(let id, let path, let sha256, let tauA, let tauB, let sigmaSource, let declaredWarmup):
            opcode = .twinKernelLoad
            writeString(id, &d)
            writeString(path, &d)
            writeString(sha256, &d)
            writeOptionalF64(tauA, &d)
            writeOptionalF64(tauB, &d)
            writeOptionalF64(sigmaSource, &d)
            writeOptionalU32(declaredWarmup, &d)

        case .hookOpen(let id, let params):
            opcode = .twinHookOpen
            writeString(id, &d)
            writeString(params.alarmId, &d)
            writeOptionalString(params.layoutId, &d)
            writeF64(params.budget, &d)
            writeU32(UInt32(truncatingIfNeeded: params.delta), &d)
            d.append(policyByte(params.policy))
            writeOptionalString(params.clockId, &d)

        case .hookStep(let id, let count):
            opcode = .twinHookStep
            writeString(id, &d)
            writeU32(UInt32(truncatingIfNeeded: count), &d)

        case .close(let id):
            opcode = .twinClose
            writeString(id, &d)
        }

        return (opcode, d)
    }

    // MARK: - decode

    public static func decode(opcode: UInt8, payload: Data) -> TwinOp? {
        guard payload.count <= maxPayloadBytes else { return nil }
        guard let op = DagDBWAL.Opcode(rawValue: opcode) else { return nil }

        let bytes = [UInt8](payload)
        var off = 0

        func readString() -> String? {
            guard off + 2 <= bytes.count else { return nil }
            let len = Int(bytes[off]) | (Int(bytes[off + 1]) << 8)
            off += 2
            guard len >= 0, off + len <= bytes.count else { return nil }
            let sub = bytes[off..<(off + len)]
            off += len
            return String(bytes: sub, encoding: .utf8)
        }
        func readU32() -> UInt32? {
            guard off + 4 <= bytes.count else { return nil }
            let v = UInt32(bytes[off])
                | (UInt32(bytes[off + 1]) << 8)
                | (UInt32(bytes[off + 2]) << 16)
                | (UInt32(bytes[off + 3]) << 24)
            off += 4
            return v
        }
        func readU64() -> UInt64? {
            guard off + 8 <= bytes.count else { return nil }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[off + i]) << (i * 8) }
            off += 8
            return v
        }
        func readF32() -> Float? {
            guard let bits = readU32() else { return nil }
            return Float(bitPattern: bits)
        }
        func readF64() -> Double? {
            guard let bits = readU64() else { return nil }
            return Double(bitPattern: bits)
        }
        func readI32() -> Int32? {
            guard let u = readU32() else { return nil }
            return Int32(bitPattern: u)
        }
        // Presence byte (0/1) followed by the value when present — used by
        // .kernelLoad's four optionals (tauA, tauB, sigmaSource,
        // declaredWarmup). Outer Optional is decode failure (bad flag byte
        // or truncated payload); inner Optional is the field's own nil.
        func readOptionalF64() -> Double?? {
            guard off < bytes.count else { return nil }
            let flag = bytes[off]; off += 1
            switch flag {
            case 0: return Optional<Double>.none
            case 1:
                guard let v = readF64() else { return nil }
                return Optional<Double>.some(v)
            default: return nil
            }
        }
        func readOptionalU32AsInt() -> Int?? {
            guard off < bytes.count else { return nil }
            let flag = bytes[off]; off += 1
            switch flag {
            case 0: return Optional<Int>.none
            case 1:
                guard let v = readU32() else { return nil }
                return Optional<Int>.some(Int(v))
            default: return nil
            }
        }
        // Presence byte (0/1) then a length-prefixed string when present —
        // `.hookOpen`'s `layoutId`/`clockId`.
        func readOptionalString() -> String?? {
            guard off < bytes.count else { return nil }
            let flag = bytes[off]; off += 1
            switch flag {
            case 0: return Optional<String>.none
            case 1:
                guard let s = readString() else { return nil }
                return Optional<String>.some(s)
            default: return nil
            }
        }

        let decoded: TwinOp?
        switch op {
        case .twinStreamOpen:
            guard let id = readString(), let name = readString(),
                  let stateHi = readU64(), let stateLo = readU64(),
                  let incHi = readU64(), let incLo = readU64()
            else { return nil }
            decoded = .streamOpen(id: id, name: name, stateHi: stateHi, stateLo: stateLo,
                                   incHi: incHi, incLo: incLo)

        case .twinStreamState:
            guard let id = readString(), let stateHi = readU64(), let stateLo = readU64(),
                  let draws = readU64()
            else { return nil }
            decoded = .streamState(id: id, stateHi: stateHi, stateLo: stateLo, draws: draws)

        case .twinRecordOpen:
            guard let id = readString(), let name = readString(),
                  let band = readF64(), let tau = readF64(), let comb = readF64(),
                  let echo = readF64(), let record = readF64(), let step = readF64(),
                  let floor = readF64(),
                  let stateHi = readU64(), let stateLo = readU64(),
                  let incHi = readU64(), let incLo = readU64()
            else { return nil }
            let header = StreamHeader(signalBandHz: band, tauWindowSec: tau, combRateHz: comb,
                                       firstEchoSec: echo, recordWindowSec: record, stepSec: step,
                                       clockSyncFloorSec: floor)
            decoded = .recordOpen(id: id, name: name, header: header, stateHi: stateHi,
                                   stateLo: stateLo, incHi: incHi, incLo: incLo)

        case .twinRecordSlice:
            guard let id = readString(), let count = readU32() else { return nil }
            decoded = .recordSlice(id: id, count: count)

        case .twinRingsOpen:
            guard let id = readString(), let gear = readU64(),
                  let rings = readU32(), let cells = readU32()
            else { return nil }
            decoded = .ringsOpen(id: id, gear: gear, rings: rings, cells: cells)

        case .twinRingsWrite:
            guard let id = readString(), let n = readU32() else { return nil }
            var values: [Float] = []
            values.reserveCapacity(Int(n))
            for _ in 0..<n {
                guard let v = readF32() else { return nil }
                values.append(v)
            }
            decoded = .ringsWrite(id: id, values: values)

        case .twinClockOpen:
            guard let id = readString() else { return nil }
            decoded = .clockOpen(id: id)

        case .twinClockAdvance:
            guard let id = readString(), let count = readU64(), let value = readF32()
            else { return nil }
            decoded = .clockAdvance(id: id, count: count, value: value)

        case .twinGearOpen:
            guard let id = readString(), let clockId = readString(), let name = readString(),
                  let num = readU64(), let den = readU64()
            else { return nil }
            decoded = .gearOpen(id: id, clockId: clockId, name: name, num: num, den: den)

        case .twinLayoutOpen:
            guard let id = readString(), let rowCount = readU32() else { return nil }
            var cost: [[Double]] = []
            cost.reserveCapacity(Int(rowCount))
            for _ in 0..<rowCount {
                guard let colCount = readU32() else { return nil }
                var row: [Double] = []
                row.reserveCapacity(Int(colCount))
                for _ in 0..<colCount {
                    guard let c = readF64() else { return nil }
                    row.append(c)
                }
                cost.append(row)
            }
            guard let tierCount = readU32() else { return nil }
            var minTier: [Int] = []
            minTier.reserveCapacity(Int(tierCount))
            for _ in 0..<tierCount {
                guard let t = readI32() else { return nil }
                minTier.append(Int(t))
            }
            decoded = .layoutOpen(id: id, cost: cost, minTier: minTier)

        case .twinAlarmLoad:
            guard let id = readString(), let path = readString(), let sha256 = readString()
            else { return nil }
            decoded = .alarmLoad(id: id, path: path, sha256: sha256)

        case .twinClose:
            guard let id = readString() else { return nil }
            decoded = .close(id: id)

        case .twinHookOpen:
            guard let id = readString(), let alarmId = readString(),
                  let layoutIdOpt = readOptionalString(),
                  let budget = readF64(), let delta = readU32(),
                  off < bytes.count
            else { return nil }
            let policyRaw = bytes[off]; off += 1
            guard let policy = TwinWALCodec.policy(fromByte: policyRaw) else { return nil }
            guard let clockIdOpt = readOptionalString() else { return nil }
            let params = AttentionHook.Params(alarmId: alarmId, layoutId: layoutIdOpt, budget: budget,
                                               delta: Int(delta), policy: policy, clockId: clockIdOpt)
            decoded = .hookOpen(id: id, params: params)

        case .twinHookStep:
            guard let id = readString(), let count = readU32() else { return nil }
            decoded = .hookStep(id: id, count: Int(count))

        case .twinBankOpen:
            guard let id = readString(), let name = readString(),
                  let samples = readU64(),
                  let sampleRate = readF64(), let f0 = readF64(),
                  let harmonics = readU32(), let gaborCenters = readU32(), let gaborFreqs = readU32(),
                  let gaborSigmaFrac = readF64()
            else { return nil }
            let spec = WaveBank.Spec(samples: Int(samples), sampleRate: sampleRate, f0: f0,
                                      harmonics: Int(harmonics), gaborCenters: Int(gaborCenters),
                                      gaborFreqs: Int(gaborFreqs), gaborSigmaFrac: gaborSigmaFrac)
            decoded = .bankOpen(id: id, name: name, spec: spec)

        case .twinViewLoad:
            guard let id = readString(), let path = readString(), let sha256 = readString()
            else { return nil }
            decoded = .viewLoad(id: id, path: path, sha256: sha256)

        case .twinKernelLoad:
            guard let id = readString(), let path = readString(), let sha256 = readString(),
                  let tauAOpt = readOptionalF64(), let tauBOpt = readOptionalF64(),
                  let sigmaOpt = readOptionalF64(), let warmupOpt = readOptionalU32AsInt()
            else { return nil }
            decoded = .kernelLoad(id: id, path: path, sha256: sha256, tauA: tauAOpt, tauB: tauBOpt,
                                   sigmaSource: sigmaOpt, declaredWarmup: warmupOpt)

        default:
            return nil
        }

        // Every encoding above accounts for the whole payload — a byte
        // left over (or a length prefix that overshoots) is a malformed
        // record, not a forward-compatible extra field.
        guard off == bytes.count else { return nil }
        return decoded
    }

    // MARK: - byte helpers (private, little-endian)

    private static func writeU16(_ v: UInt16, _ d: inout Data) {
        d.append(UInt8(v & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
    }

    private static func writeU32(_ v: UInt32, _ d: inout Data) {
        for i in 0..<4 { d.append(UInt8((v >> (i * 8)) & 0xFF)) }
    }

    private static func writeI32(_ v: Int32, _ d: inout Data) {
        writeU32(UInt32(bitPattern: v), &d)
    }

    private static func writeU64(_ v: UInt64, _ d: inout Data) {
        for i in 0..<8 { d.append(UInt8((v >> (i * 8)) & 0xFF)) }
    }

    private static func writeF32(_ v: Float, _ d: inout Data) {
        writeU32(v.bitPattern, &d)
    }

    private static func writeF64(_ v: Double, _ d: inout Data) {
        writeU64(v.bitPattern, &d)
    }

    private static func writeString(_ s: String, _ d: inout Data) {
        let utf8 = Array(s.utf8)
        writeU16(UInt16(truncatingIfNeeded: utf8.count), &d)
        d.append(contentsOf: utf8)
    }

    /// Presence byte (0/1) then the value when present — `.kernelLoad`'s
    /// four optionals (tauA, tauB, sigmaSource, declaredWarmup).
    private static func writeOptionalF64(_ v: Double?, _ d: inout Data) {
        if let v = v {
            d.append(1)
            writeF64(v, &d)
        } else {
            d.append(0)
        }
    }

    private static func writeOptionalU32(_ v: Int?, _ d: inout Data) {
        if let v = v {
            d.append(1)
            writeU32(UInt32(truncatingIfNeeded: v), &d)
        } else {
            d.append(0)
        }
    }

    /// Presence byte (0/1) then a length-prefixed string when present —
    /// `.hookOpen`'s `layoutId`/`clockId`.
    private static func writeOptionalString(_ v: String?, _ d: inout Data) {
        if let v = v {
            d.append(1)
            writeString(v, &d)
        } else {
            d.append(0)
        }
    }

    /// `.hookOpen`'s policy byte: 0 allocator, 1 greedy, 2 uniform (per
    /// `docs/contracts/HOOK_GATES_FROZEN.md`'s codec letter — NOT the
    /// `Policy.rawValue` string).
    private static func policyByte(_ p: AttentionHook.Policy) -> UInt8 {
        switch p {
        case .allocator: return 0
        case .greedy: return 1
        case .uniform: return 2
        }
    }

    private static func policy(fromByte b: UInt8) -> AttentionHook.Policy? {
        switch b {
        case 0: return .allocator
        case 1: return .greedy
        case 2: return .uniform
        default: return nil
        }
    }
}

/// `Appender.twin(_:)` — encode a `TwinOp` via `TwinWALCodec` and append it
/// as one WAL record, same contract as the base opcode convenience methods
/// (`setTruth`, `connectBack`, …).
extension DagDBWAL.Appender {
    @discardableResult
    public func twin(_ op: TwinOp) throws -> Int {
        let (opcode, payload) = TwinWALCodec.encode(op)
        return try append(opcode: opcode, payload: payload)
    }
}
