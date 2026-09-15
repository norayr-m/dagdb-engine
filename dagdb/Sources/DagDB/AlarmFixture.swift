import Foundation

/// Loader for the sealed W2 alarm-stream fixture (`w2_records.json`) —
/// twin spec line 4. The fixture is by-reference: 29 MB, out of repo,
/// read only from `DAGDB_W2_FIXTURE` and SHA-pinned. Numerics only, no
/// judgement — classification and ordering, nothing else.
///
/// File order (interface-phase convention 1): `Dictionary` decoding loses JSON key order, and
/// the sealed court relies on file order. Order is reconstructed from
/// each record's `class` field (block rank quiet < liar < deep < drift)
/// and the numeric suffix on its key, giving a stable 1-based `idx`.
/// `cal0_1` (interface-phase convention 2) is captured as `control`, never as an `AlarmRecord`
/// — with it excluded, `records.count == 200` on the sealed fixture.
public struct AlarmFixture {
    public static let envVar = "DAGDB_W2_FIXTURE"
    public static let sealedSHA256 =
        "be5c431f8ba410c632bbb18b89bce2b93d74dfcbc7f069ea9051f44e37618303"

    public static var envPath: String? {
        ProcessInfo.processInfo.environment[envVar]
    }

    /// The calibration entry (`cal0_1`): a stored trial, no noise, kept
    /// out of the court's 200 judged records.
    public struct ControlEntry: Equatable, Codable {
        public let key: String
        public let rawClass: String
    }

    public let path: String
    public let sha256: String
    public let records: [AlarmRecord]
    public let control: ControlEntry?

    /// Per-class-label counts over `records` (quiet/liar_A/liar_B/liar_C/
    /// deep/drift) — compared against `SealedCourt.classCounts` on the
    /// sealed fixture.
    public var classCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for r in records {
            guard let label = r.classLabel else { continue }
            counts[label, default: 0] += 1
        }
        return counts
    }

    /// Violations of the sealed key-set assertion: the fixture's keys
    /// must be exactly `{quiet,liar,deep,drift}_1..50` plus `cal0_1`.
    /// Empty on the sealed fixture; non-empty on any partial/synthetic one.
    public func sealedStops() -> [String] {
        var expected = Set<String>()
        for base in ["quiet", "liar", "deep", "drift"] {
            for k in 1...50 { expected.insert("\(base)_\(k)") }
        }
        expected.insert("cal0_1")

        var actual = Set(records.map(\.key))
        if let control = control { actual.insert(control.key) }

        var stops: [String] = []
        let missing = expected.subtracting(actual).sorted()
        if !missing.isEmpty {
            stops.append("missing keys: \(missing.joined(separator: ", "))")
        }
        let extra = actual.subtracting(expected).sorted()
        if !extra.isEmpty {
            stops.append("unexpected keys: \(extra.joined(separator: ", "))")
        }
        return stops
    }

    public enum FixtureError: Error, Equatable {
        case fileNotFound(String)
        case shaMismatch(expected: String, actual: String)
        case badEntry(key: String, reason: String)
        case unknownClass(key: String, value: String)
    }

    /// Reason prefix carried by `badEntry` when two entries reconstruct to
    /// the same (class block, suffix) position — the courts' frame key
    /// would otherwise depend on dictionary iteration order (findings 24,
    /// 49). Kept as a `badEntry` reason rather than a new enum case so the
    /// daemon's existing exhaustive `FixtureError` switch is untouched.
    public static let duplicatePositionReason = "duplicate reconstructed position"

    /// Reason prefix carried by `badEntry` when a key's `class` field
    /// disagrees with its own `<block>_<n>` prefix (finding 25).
    public static let classPrefixMismatchReason = "class disagrees with key prefix"

    /// Emitted once per process when a caller opts out of the SHA pin
    /// (finding 23). Package-internal so tests can observe the opt-out.
    static var unpinnedWarningEmitted = false

    private static let blockRank: [String: Int] = ["quiet": 0, "liar": 1, "deep": 2, "drift": 3]

    /// Load and classify the fixture at `path`. SHA-256 is always
    /// computed and returned; `expectedSHA256` DEFAULTS to `sealedSHA256`
    /// and must match or the load throws. Passing nil is an explicit
    /// opt-out that prints `WARN unpinned fixture` once (finding 23).
    /// Waveform arrays (`a`,`b`,`c`, 2048
    /// floats each in the sealed file) are decoded only when
    /// `includeWaveforms` is true — otherwise they are read by
    /// `JSONSerialization` like everything else but never converted, so
    /// the 29 MB file loads in a fraction of a second either way.
    public static func load(path: String, expectedSHA256: String? = sealedSHA256,
                            includeWaveforms: Bool = false) throws -> AlarmFixture {
        guard FileManager.default.fileExists(atPath: path) else {
            throw FixtureError.fileNotFound(path)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let actualSHA = DagDBSnapshot.sha256Hex(data)
        if let expected = expectedSHA256 {
            if expected != actualSHA {
                throw FixtureError.shaMismatch(expected: expected, actual: actualSHA)
            }
        } else if !unpinnedWarningEmitted {
            // Finding 23: the pin now DEFAULTS to `sealedSHA256`; passing
            // nil is an explicit opt-out, said out loud once.
            unpinnedWarningEmitted = true
            FileHandle.standardError.write(Data("WARN unpinned fixture\n".utf8))
        }

        guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError.badEntry(key: "<root>", reason: "not a JSON object")
        }

        struct Positioned {
            let key: String
            let rank: Int
            let suffix: Int
            let entry: [String: Any]
            let rawClass: String
        }

        var control: ControlEntry?
        var positioned: [Positioned] = []

        for (key, rawValue) in top {
            guard let entry = rawValue as? [String: Any] else {
                throw FixtureError.badEntry(key: key, reason: "entry is not an object")
            }
            guard let rawClass = entry["class"] as? String else {
                throw FixtureError.badEntry(key: key, reason: "missing 'class' field")
            }
            guard let underscore = key.lastIndex(of: "_"),
                  let suffix = Int(key[key.index(after: underscore)...]) else {
                throw FixtureError.badEntry(key: key, reason: "key is not '<block>_<n>'")
            }

            // Finding 25: the class field must agree with the key's own
            // block prefix — `quiet_1` carrying class `liar` is refused,
            // not silently re-sorted into the liar block. Checked AFTER
            // the class name itself is recognised, so an unknown class is
            // still reported as `unknownClass`, not as a prefix mismatch.
            let prefix = String(key[key.startIndex..<underscore])
            func requirePrefixAgreement() throws {
                guard prefix == rawClass else {
                    throw FixtureError.badEntry(
                        key: key,
                        reason: "\(Self.classPrefixMismatchReason): declared '\(rawClass)', prefix '\(prefix)'")
                }
            }

            switch rawClass {
            case "cal0":
                try requirePrefixAgreement()
                guard control == nil else {
                    throw FixtureError.badEntry(key: key, reason: "duplicate cal0 control entry")
                }
                control = ControlEntry(key: key, rawClass: rawClass)
            case "quiet", "liar", "deep", "drift":
                try requirePrefixAgreement()
                positioned.append(Positioned(key: key, rank: blockRank[rawClass]!,
                                             suffix: suffix, entry: entry, rawClass: rawClass))
            default:
                throw FixtureError.unknownClass(key: key, value: rawClass)
            }
        }

        // Findings 24 / 49: two entries at the same reconstructed position
        // make `index` — the courts' frame key — depend on dictionary
        // iteration order, and a duplicate index traps the court's
        // `byIndex` build. Refuse the collision by name at the door.
        var positions: [String: [String]] = [:]
        for p in positioned {
            positions["\(p.rawClass)_\(p.suffix)", default: []].append(p.key)
        }
        for (slot, keys) in positions.sorted(by: { $0.key < $1.key }) where keys.count > 1 {
            throw FixtureError.badEntry(
                key: keys.sorted().joined(separator: ", "),
                reason: "\(Self.duplicatePositionReason) '\(slot)'")
        }

        positioned.sort {
            $0.rank != $1.rank ? $0.rank < $1.rank : $0.suffix < $1.suffix
        }

        var records: [AlarmRecord] = []
        records.reserveCapacity(positioned.count)
        for (i, p) in positioned.enumerated() {
            let culprit: CulpritClass
            switch p.rawClass {
            case "quiet": culprit = .quiet
            case "deep": culprit = .deep
            case "drift": culprit = .drift
            case "liar":
                guard let earRaw = p.entry["liar_ear"] as? String, let ear = Ear(rawValue: earRaw) else {
                    throw FixtureError.badEntry(key: p.key, reason: "liar entry missing valid 'liar_ear'")
                }
                culprit = .liar(ear)
            default:
                throw FixtureError.badEntry(key: p.key, reason: "unreachable class '\(p.rawClass)'")
            }

            var waveforms: AlarmRecord.Waveforms?
            if includeWaveforms {
                guard let a = p.entry["a"] as? [Any],
                      let b = p.entry["b"] as? [Any],
                      let c = p.entry["c"] as? [Any] else {
                    throw FixtureError.badEntry(key: p.key, reason: "missing waveform arrays a/b/c")
                }
                func floats(_ raw: [Any]) throws -> [Float] {
                    try raw.map {
                        guard let n = $0 as? NSNumber else {
                            throw FixtureError.badEntry(key: p.key, reason: "waveform sample is not numeric")
                        }
                        return n.floatValue
                    }
                }
                waveforms = AlarmRecord.Waveforms(a: try floats(a), b: try floats(b), c: try floats(c))
            }

            records.append(AlarmRecord(index: i + 1, key: p.key, culprit: culprit, waveforms: waveforms))
        }

        return AlarmFixture(path: path, sha256: actualSHA, records: records, control: control)
    }
}
