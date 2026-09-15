import XCTest
@testable import DagDB

/// Audit C, scope α — the npz / kernels / cross-convolution / bank / fold /
/// derived-views half. `docs/contracts/SUBSYSTEMS_BOUNDS_GATES_FROZEN.md`,
/// findings 20-44 and test items 79, 80, 83.
///
/// Every failing input is built BY HAND: a hand-assembled `.npy`, a hand-
/// written JSON field, an out-of-range argument, a synthetic fixture. None
/// of it comes out of the writer under test.
///
/// Amateur engineering project, no competitive claims, errors likely.
final class SubsystemsBoundsTwinTests: XCTestCase {

    // MARK: - Scratch

    private func scratchDir(_ label: String) -> String {
        let dir = NSTemporaryDirectory() + "dagdb-audit-c-\(label)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeScratch(_ dir: String) { try? FileManager.default.removeItem(atPath: dir) }

    // MARK: - Hand-built zip / npy

    /// One `.npy` member, assembled byte by byte so the version, the header
    /// dict and the payload are the TEST's, not numpy's.
    private func npyBytes(major: UInt8, minor: UInt8, descr: String, shape: String,
                          fortran: Bool = false, payload: Data) -> Data {
        var out = Data([0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59, major, minor])
        let dict = "{'descr': '\(descr)', 'fortran_order': \(fortran ? "True" : "False"), "
            + "'shape': \(shape), }"
        var header = Data(dict.utf8)
        // Pad to a 16-byte boundary with spaces, terminated by a newline —
        // numpy's own rule; the reader only needs the declared length.
        while (out.count + (major == 1 ? 2 : 4) + header.count + 1) % 16 != 0 { header.append(0x20) }
        header.append(0x0A)
        if major == 1 {
            var len = UInt16(header.count).littleEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        } else {
            var len = UInt32(header.count).littleEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        }
        out.append(header)
        out.append(payload)
        return out
    }

    /// A STORED (method 0) single-member zip, written by hand.
    private func zipBytes(name: String, member: Data,
                          eocdEntryCount: UInt16? = nil,
                          centralCompressedSize: UInt32? = nil,
                          centralLocalOffset: UInt32? = nil,
                          eocdCDSize: UInt32? = nil,
                          eocdCDOffset: UInt32? = nil) -> Data {
        var out = Data()
        func u16(_ v: UInt16, into d: inout Data) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32, into d: inout Data) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let nameBytes = Data(name.utf8)

        let localOffset = UInt32(out.count)
        u32(0x0403_4b50, into: &out)            // local header signature
        u16(20, into: &out)                     // version needed
        u16(0, into: &out)                      // flags
        u16(0, into: &out)                      // method 0 = stored
        u16(0, into: &out); u16(0, into: &out)  // time, date
        u32(0, into: &out)                      // crc32 (unchecked by this reader)
        u32(UInt32(member.count), into: &out)   // compressed size
        u32(UInt32(member.count), into: &out)   // uncompressed size
        u16(UInt16(nameBytes.count), into: &out)
        u16(0, into: &out)                      // extra length
        out.append(nameBytes)
        out.append(member)

        let cdOffset = UInt32(out.count)
        u32(0x0201_4b50, into: &out)            // central header signature
        u16(20, into: &out); u16(20, into: &out)
        u16(0, into: &out)
        u16(0, into: &out)                      // method 0
        u16(0, into: &out); u16(0, into: &out)
        u32(0, into: &out)                      // crc32
        u32(centralCompressedSize ?? UInt32(member.count), into: &out)
        u32(UInt32(member.count), into: &out)
        u16(UInt16(nameBytes.count), into: &out)
        u16(0, into: &out)                      // extra
        u16(0, into: &out)                      // comment
        u16(0, into: &out)                      // disk number
        u16(0, into: &out)                      // internal attrs
        u32(0, into: &out)                      // external attrs
        u32(centralLocalOffset ?? localOffset, into: &out)
        out.append(nameBytes)
        let cdSize = UInt32(out.count) - cdOffset

        u32(0x0605_4b50, into: &out)            // EOCD signature
        u16(0, into: &out); u16(0, into: &out)
        u16(eocdEntryCount ?? 1, into: &out)
        u16(eocdEntryCount ?? 1, into: &out)
        u32(eocdCDSize ?? cdSize, into: &out)
        u32(eocdCDOffset ?? cdOffset, into: &out)
        u16(0, into: &out)                      // comment length
        return out
    }

    private func writeNpz(_ label: String, _ data: Data) -> String {
        let dir = scratchDir(label)
        let path = dir + "/hand.npz"
        try? data.write(to: URL(fileURLWithPath: path))
        return path
    }

    // MARK: - 20 / 83 · npy major and minor versions

    func testF20NpyVersionRefusedByName() throws {
        let payload = Data([0, 0, 0x80, 0x3F, 0, 0, 0, 0x40])   // 1.0f, 2.0f

        // v1, v2 and v3 open.
        for (major, minor) in [(UInt8(1), UInt8(0)), (UInt8(2), UInt8(0)), (UInt8(3), UInt8(0))] {
            let member = npyBytes(major: major, minor: minor, descr: "<f4", shape: "(2,)", payload: payload)
            let path = writeNpz("f20-ok-\(major)", zipBytes(name: "a.npy", member: member))
            defer { removeScratch((path as NSString).deletingLastPathComponent) }
            let entries = try NpzReader.entries(path: path)
            XCTAssertEqual(try NpzReader.float32(entries["a"]!), [1.0, 2.0], "npy v\(major).\(minor)")
        }

        // BEFORE the fix every other major fell into the 4-byte-length
        // branch and was parsed as if it were v2.
        for major in [UInt8(0), UInt8(4), UInt8(255)] {
            let member = npyBytes(major: major, minor: 0, descr: "<f4", shape: "(2,)", payload: payload)
            let path = writeNpz("f20-bad-\(major)", zipBytes(name: "a.npy", member: member))
            defer { removeScratch((path as NSString).deletingLastPathComponent) }
            do {
                _ = try NpzReader.entries(path: path)
                XCTFail("expected badNpyHeader for npy major \(major)")
            } catch NpzReader.NpzError.badNpyHeader(let message) {
                XCTAssertTrue(message.contains("major version \(major)"), message)
            }
        }

        // The minor byte was never read at all.
        let member = npyBytes(major: 1, minor: 7, descr: "<f4", shape: "(2,)", payload: payload)
        let path = writeNpz("f20-minor", zipBytes(name: "a.npy", member: member))
        defer { removeScratch((path as NSString).deletingLastPathComponent) }
        do {
            _ = try NpzReader.entries(path: path)
            XCTFail("expected badNpyHeader for npy minor 7")
        } catch NpzReader.NpzError.badNpyHeader(let message) {
            XCTAssertTrue(message.contains("1.7"), message)
        }
    }

    // MARK: - 21 · shape components: negative, and overflowing

    func testF21ShapeComponentsRefusedByName() throws {
        // A negative component: `elementCount` went negative and the
        // payload-size guard then reported a size error instead of naming
        // the bad shape.
        let negative = npyBytes(major: 1, minor: 0, descr: "<f4", shape: "(-1, 4)", payload: Data())
        let pathA = writeNpz("f21-negative", zipBytes(name: "a.npy", member: negative))
        defer { removeScratch((pathA as NSString).deletingLastPathComponent) }
        do {
            _ = try NpzReader.entries(path: pathA)
            XCTFail("expected badShape for a negative shape component")
        } catch NpzReader.NpzError.badShape(let message) {
            XCTAssertTrue(message.contains("negative shape component"), message)
        }

        // A product that overflows Int: `shape.reduce(1, *)` is a
        // NON-wrapping multiply, so this TRAPPED the process.
        let huge = "(\(1 << 32), \(1 << 32))"
        let overflowing = npyBytes(major: 1, minor: 0, descr: "<f4", shape: huge, payload: Data())
        let pathB = writeNpz("f21-overflow", zipBytes(name: "b.npy", member: overflowing))
        defer { removeScratch((pathB as NSString).deletingLastPathComponent) }
        let entries = try NpzReader.entries(path: pathB)
        do {
            _ = try NpzReader.float32(entries["b"]!)
            XCTFail("expected badShape for an overflowing element count")
        } catch NpzReader.NpzError.badShape(let message) {
            XCTAssertTrue(message.contains("overflows"), message)
        }
    }

    // MARK: - 22 · zip64 placeholders, refused by name

    func testF22Zip64PlaceholdersRefusedByName() throws {
        let member = npyBytes(major: 1, minor: 0, descr: "<f4", shape: "(2,)",
                              payload: Data([0, 0, 0x80, 0x3F, 0, 0, 0, 0x40]))

        // (a) EOCD member count at the placeholder.
        let a = writeNpz("f22-count", zipBytes(name: "a.npy", member: member, eocdEntryCount: 0xFFFF))
        defer { removeScratch((a as NSString).deletingLastPathComponent) }
        do {
            _ = try NpzReader.entries(path: a)
            XCTFail("expected zip64NotSupported for a 0xFFFF member count")
        } catch NpzReader.NpzError.zip64NotSupported(let message) {
            XCTAssertTrue(message.contains("65535"), message)
        }

        // (b) EOCD central-directory offset at the placeholder.
        let b = writeNpz("f22-offset", zipBytes(name: "a.npy", member: member, eocdCDOffset: 0xFFFF_FFFF))
        defer { removeScratch((b as NSString).deletingLastPathComponent) }
        do {
            _ = try NpzReader.entries(path: b)
            XCTFail("expected zip64NotSupported for a 0xFFFFFFFF central-directory offset")
        } catch NpzReader.NpzError.zip64NotSupported(let message) {
            XCTAssertTrue(message.contains("4294967295"), message)
        }

        // (c) a CENTRAL record's compressed size at the placeholder — the
        //     case the file header says np.savez puts in LOCAL headers, and
        //     which the pre-audit reader would have taken at face value.
        let c = writeNpz("f22-central", zipBytes(name: "a.npy", member: member,
                                                 centralCompressedSize: 0xFFFF_FFFF))
        defer { removeScratch((c as NSString).deletingLastPathComponent) }
        do {
            _ = try NpzReader.entries(path: c)
            XCTFail("expected zip64NotSupported for a 0xFFFFFFFF central compressed size")
        } catch NpzReader.NpzError.zip64NotSupported(let message) {
            XCTAssertTrue(message.contains("central directory entry"), message)
        }
    }

    // MARK: - Kernel JSON helper

    private func writeKernelJSON(_ label: String, _ object: [String: Any]) throws -> String {
        let dir = scratchDir(label)
        let path = dir + "/kernels.json"
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private func kernelJSON(window: Any = 2048) -> [String: Any] {
        ["kA": [1.0, 2.0, 3.0], "kB": [0.5, 0.25, 0.125], "fs": 3000.0,
         "window_samples": window, "ear_index_A": 170, "ear_index_B": 236]
    }

    // MARK: - 23 · the sha pin defaults to the sealed constant

    func testF23ShaPinDefaultsToTheSealedConstant() throws {
        let path = try writeKernelJSON("f23", kernelJSON())
        defer { removeScratch((path as NSString).deletingLastPathComponent) }

        // A file that is NOT the sealed one, loaded with no sha argument:
        // pre-audit this read happily; the pin now fires by default.
        do {
            _ = try KernelPair.load(path: path)
            XCTFail("expected shaMismatch — load must default to the sealed pin")
        } catch KernelPair.KernelError.shaMismatch(let expected, let actual) {
            XCTAssertEqual(expected, KernelPair.sealedSHA256)
            XCTAssertNotEqual(actual, KernelPair.sealedSHA256)
        }

        // `nil` is the explicit opt-out: it loads, and warns once.
        let unpinned = try KernelPair.load(path: path, expectedSHA256: nil)
        XCTAssertEqual(unpinned.pair.taps, 3)

        // The sealed default is the fixture's own recorded sha, read off
        // `Tests/Fixtures/w1_kernels.sha256` rather than restated here.
        let shaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/w1_kernels.sha256")
        let recorded = try String(contentsOf: shaURL, encoding: .utf8)
            .split(separator: " ").first.map(String.init)
        XCTAssertEqual(recorded, KernelPair.sealedSHA256)

        // And loading the sealed fixture with no sha argument at all now
        // verifies it.
        let sealedPath = shaURL.deletingLastPathComponent()
            .appendingPathComponent("w1_kernels.json").path
        let sealed = try KernelPair.load(path: sealedPath, tauA: 0.18227148035108542,
                                          tauB: 0.18382585465904366, sigmaSource: 0.02)
        XCTAssertEqual(sealed.sha256, KernelPair.sealedSHA256)
        XCTAssertEqual(sealed.pair.derivedWarmup, 185)

        // S5 (iii): this line used to assert only that
        // `CortexFixture.sealedSHA256` is 64 characters long — the length
        // of a constant, which checks nothing. When the npz fixture is
        // present (it lives outside the repo), its sha256 is measured here
        // by `/usr/bin/shasum`, a hasher that is not the one the loader
        // uses, and compared against the pin the loader defaults to. With
        // the fixture absent there is no independent value to measure, and
        // nothing is asserted — the run is not skipped for it.
        if let npz = ProcessInfo.processInfo.environment["DAGDB_CORTEX_V4_FIXTURE"],
           FileManager.default.fileExists(atPath: npz) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
            proc.arguments = ["-a", "256", npz]
            let pipe = Pipe()
            proc.standardOutput = pipe
            try proc.run()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            proc.waitUntilExit()
            let measured = out.split(separator: " ").first.map(String.init)
            XCTAssertEqual(measured, CortexFixture.sealedSHA256)
            // …and the loader's default pin is that same constant: loading
            // with no sha argument verifies the file.
            let fixture = try CortexFixture.load(path: npz)
            XCTAssertEqual(fixture.sha256, CortexFixture.sealedSHA256)
        } else {
            print("F23: DAGDB_CORTEX_V4_FIXTURE absent — the cortex sha pin has no "
                  + "independent measurement in this run")
        }
    }

    // MARK: - 26 · non-finite / negative tau and sigma

    func testF26NonFiniteOrNegativeMetaRefused() throws {
        let base = KernelPair.Meta(fs: 3000, window: 2048, earA: 0, earB: 1)
        _ = try KernelPair(kA: [1], kB: [1], meta: base)   // the clean pairing still builds

        // Each of these reached `derivedWarmup`, where `Int(inf)` /
        // `Int(nan)` TRAPPED, or produced a negative warmup silently.
        let cases: [(String, KernelPair.Meta)] = [
            ("sigmaSource", KernelPair.Meta(fs: 3000, window: 2048, earA: 0, earB: 1,
                                            tauA: 0.1, tauB: 0.2, sigmaSource: .infinity)),
            ("sigmaSource", KernelPair.Meta(fs: 3000, window: 2048, earA: 0, earB: 1,
                                            tauA: 0.1, tauB: 0.2, sigmaSource: -0.02)),
            ("tauA", KernelPair.Meta(fs: 3000, window: 2048, earA: 0, earB: 1,
                                     tauA: .nan, tauB: 0.2, sigmaSource: 0.02)),
            ("tauB", KernelPair.Meta(fs: 3000, window: 2048, earA: 0, earB: 1,
                                     tauA: 0.1, tauB: .infinity, sigmaSource: 0.02)),
            ("fs", KernelPair.Meta(fs: .nan, window: 2048, earA: 0, earB: 1)),
        ]
        for (field, meta) in cases {
            do {
                _ = try KernelPair(kA: [1], kB: [1], meta: meta)
                XCTFail("expected badLayout naming \(field)")
            } catch KernelPair.KernelError.badLayout(let message) {
                XCTAssertTrue(message.contains(field), message)
            }
        }
    }

    // MARK: - 27 · window_samples must be an integer

    func testF27NonIntegralWindowSamplesRefused() throws {
        for bogus in [2.7 as Any, 1e20 as Any] {
            let path = try writeKernelJSON("f27", kernelJSON(window: bogus))
            defer { removeScratch((path as NSString).deletingLastPathComponent) }
            do {
                _ = try KernelPair.load(path: path, expectedSHA256: nil)
                XCTFail("expected badLayout for window_samples \(bogus)")
            } catch KernelPair.KernelError.badLayout(let message) {
                XCTAssertTrue(message.contains("window_samples"), message)
            }
        }
    }

    // MARK: - 28 · a warmup that leaves no comparison window

    func testF28WarmupWithNoWindowRefused() throws {
        let meta = KernelPair.Meta(fs: 3000, window: 64, earA: 0, earB: 1, declaredWarmup: 64)
        let pair = try KernelPair(kA: [1, 2], kB: [3, 4], meta: meta)

        XCTAssertNotNil(pair.warmupViolation(64))
        XCTAssertNil(pair.warmupViolation(63))
        do {
            _ = try pair.checkedWarmup(override: nil)
            XCTFail("expected badLayout — warmup 64 against window_samples 64")
        } catch KernelPair.KernelError.badLayout(let message) {
            XCTAssertTrue(message.contains("64"), message)
            XCTAssertTrue(message.contains("window_samples"), message)
        }

        // And the load path refuses such a file rather than handing the
        // warmup on to be silently clamped downstream.
        var json = kernelJSON(window: 8)
        json["kA"] = [1.0, 2.0]
        json["kB"] = [3.0, 4.0]
        let path = try writeKernelJSON("f28", json)
        defer { removeScratch((path as NSString).deletingLastPathComponent) }
        do {
            _ = try KernelPair.load(path: path, expectedSHA256: nil, declaredWarmup: 99)
            XCTFail("expected badLayout at load")
        } catch KernelPair.KernelError.badLayout(let message) {
            XCTAssertTrue(message.contains("99"), message)
        }
    }

    // MARK: - 29 · the compared window stops at the record's end

    func testF29ComparedWindowStopsAtTheRecordEnd() {
        // Records of 40 and 48 samples, kernels of 6 and 9 taps: the
        // convolution outputs are 48 and 53 long, so the pre-audit window
        // ran to min(48, 53) = 48 — eight samples past the shorter record.
        var stream = NamedStream(name: "audit-c-29",
                                 stateHi: 0x853c_49e6_748f_ea9b, stateLo: 0xda3e_39cb_94b9_5bdb,
                                 incHi: 0x5851_f42d_4c95_7f2d, incLo: 0x1405_7b7e_f767_814f)
        func unit() -> Float { Float(stream.next64() >> 40) / Float(1 << 24) - 0.5 }
        let a = (0..<40).map { _ in unit() }
        let b = (0..<48).map { _ in unit() }
        let kA = CrossConvolutionCheck.PathKernel(taps: (0..<6).map { _ in unit() })
        let kB = CrossConvolutionCheck.PathKernel(taps: (0..<9).map { _ in unit() })

        let r = CrossConvolutionCheck.check(recordA: a, recordB: b, kernelA: kA, kernelB: kB, warmup: 4)
        XCTAssertNil(r.refusal)
        // min(a.count, b.count) - warmup = 40 - 4, never 48 - 4.
        XCTAssertEqual(r.comparedSamples, 36)
    }

    // MARK: - 30 / 80 · a warmup at or past the window does not pass

    func testItem80WarmupAtOrPastTheWindowDoesNotPass() {
        let a: [Float] = [0.5, -0.25, 0.125]
        let b: [Float] = [0.5, -0.25, 0.125]
        let k = CrossConvolutionCheck.PathKernel(taps: [1])

        // n = min(3, 3) = 3. Pre-audit, `start` clamped to n: the loop body
        // never ran, residual was 0, comparedSamples 0 — and `passes` was
        // true for EVERY tolerance.
        for warmup in [3, 4, 100] {
            let r = CrossConvolutionCheck.check(recordA: a, recordB: b, kernelA: k, kernelB: k,
                                                warmup: warmup)
            XCTAssertEqual(r.comparedSamples, 0)
            XCTAssertNotNil(r.refusal)
            XCTAssertTrue(r.refusal!.contains("\(warmup)"), r.refusal!)
            XCTAssertFalse(r.passes(tolerance: 1e-6))
            XCTAssertFalse(r.passes(tolerance: .greatestFiniteMagnitude))
        }

        // A negative warmup is refused by name too, not clamped to 0.
        let negative = CrossConvolutionCheck.check(recordA: a, recordB: b, kernelA: k, kernelB: k,
                                                   warmup: -1)
        XCTAssertNotNil(negative.refusal)
        XCTAssertFalse(negative.passes(tolerance: 1.0))

        // A check that compared nothing never passes, however it was built.
        XCTAssertFalse(CrossConvolutionCheck.Result(residual: 0, comparedSamples: 0)
                        .passes(tolerance: 1.0))
        XCTAssertTrue(CrossConvolutionCheck.Result(residual: 0, comparedSamples: 1)
                        .passes(tolerance: 1.0))

        // And the ordinary path still passes.
        let ok = CrossConvolutionCheck.check(recordA: a, recordB: b, kernelA: k, kernelB: k, warmup: 1)
        XCTAssertEqual(ok.comparedSamples, 2)
        XCTAssertTrue(ok.passes(tolerance: 1e-6))
    }

    // MARK: - 31 · the Nyquist rule covers the Gabor family too

    func testF31GaborNyquistRuleStated() {
        // Both sealed banks stay clean of the Gabor clause: at the
        // reference rates the top Gabor centre is fs/4 = 750 Hz and its
        // bandwidth about 5.8 Hz, far under Nyquist 1500 Hz.
        XCTAssertNil(WaveBank.gaborAliasingViolation(.reference))
        XCTAssertNil(WaveBank.gaborAliasingViolation(.referenceNyquistSafe))
        XCTAssertNil(WaveBank.aliasingViolation(.referenceNyquistSafe))

        // A very short envelope on a short bank widens each Gabor atom past
        // fs/4 + fs/4 — the half of the bank no Nyquist rule covered.
        let wide = WaveBank.Spec(samples: 64, sampleRate: 3000, f0: 60, harmonics: 4,
                                 gaborCenters: 2, gaborFreqs: 3, gaborSigmaFrac: 0.0005)
        XCTAssertNil(WaveBank.validationError(wide), "the spec itself must still admit a bank")
        guard let message = WaveBank.aliasingViolation(wide) else {
            return XCTFail("expected a Gabor aliasing refusal for \(wide)")
        }
        print("F31 gabor aliasing = \(message)")
        XCTAssertTrue(message.contains("gabor"), message)
        XCTAssertTrue(message.contains("1500"), message)
        XCTAssertTrue(message.contains("ALIASED"), message)

        // The sealed (deliberately aliased) control bank still BUILDS — the
        // refusal is a diagnosis, not a construction gate.
        XCTAssertNoThrow(try WaveBank(spec: .reference))
        XCTAssertNoThrow(try WaveBank(spec: wide))
    }

    // MARK: - 32 · the named harmonic is inside 1...H

    func testF32NamedHarmonicIsInsideTheBank() {
        // H·f0 == fs/2 exactly: the message used to name harmonic H + 1,
        // an atom the bank does not contain.
        let exact = WaveBank.Spec(samples: 4096, sampleRate: 3000, f0: 60, harmonics: 25,
                                  gaborCenters: 8, gaborFreqs: 6, gaborSigmaFrac: 0.02)
        guard let message = WaveBank.aliasingViolation(exact) else {
            return XCTFail("expected a refusal at exactly Nyquist")
        }
        print("F32 exact-Nyquist message = \(message)")
        XCTAssertTrue(message.contains("harmonic 25"), message)
        XCTAssertFalse(message.contains("harmonic 26"), message)

        // The named harmonic is <= H for every spec the gate fires on.
        for h in 24...40 {
            let spec = WaveBank.Spec(samples: 4096, sampleRate: 3000, f0: 60, harmonics: h,
                                     gaborCenters: 8, gaborFreqs: 6, gaborSigmaFrac: 0.02)
            guard let m = WaveBank.aliasingViolation(spec) else { continue }
            guard let named = m.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
                return XCTFail("could not read the named harmonic out of: \(m)")
            }
            XCTAssertGreaterThanOrEqual(named, 1, m)
            XCTAssertLessThanOrEqual(named, h, m)
        }

        // The sealed control bank's own message is unchanged: harmonic 26
        // at 1560 Hz against Nyquist 1500 Hz (H = 32, so 26 <= H).
        let refMsg = WaveBank.aliasingViolation(.reference)!
        XCTAssertTrue(refMsg.contains("harmonic 26"), refMsg)
        XCTAssertTrue(refMsg.contains("1560"), refMsg)
        XCTAssertTrue(refMsg.contains("1500"), refMsg)
    }

    // MARK: - 33 · a declaration that cannot be trusted is not handed back

    func testF33RankDeficientDeclarationRefused() throws {
        // `geomspace(f0, fs/4, 2)` pins its first entry to f0 and its last
        // to fs/4 — so f0 == fs/4 makes the Gabor frequency grid hold the
        // SAME frequency twice, and the bank then carries two bit-identical
        // column pairs. Its smallest singular value is exactly 0 and the
        // condition number sigmaMax/sigmaMin is not finite: pre-audit that
        // came back dressed as a valid Declaration, with no zero guard.
        let degenerate = WaveBank.Spec(samples: 64, sampleRate: 3000, f0: 750, harmonics: 1,
                                       gaborCenters: 1, gaborFreqs: 2, gaborSigmaFrac: 0.2)
        XCTAssertNil(WaveBank.validationError(degenerate))
        XCTAssertNil(WaveBank.aliasingViolation(degenerate))
        let bank = try WaveBank(spec: degenerate)
        XCTAssertEqual(bank.K, 6)

        let decl = bank.declaration()
        // `info` is captured now instead of discarded.
        XCTAssertEqual(decl.lapackInfo, 0)
        // The duplicated columns cost the bank two of its six dimensions.
        XCTAssertEqual(decl.rank, 4)
        XCTAssertLessThan(decl.sigmaMin, decl.sigmaMax * 1e-9)
        print("F33 degenerate bank: rank=\(decl.rank) of \(bank.K) sigmaMin=\(decl.sigmaMin) "
              + "cond=\(decl.conditionNumber)")
        do {
            _ = try bank.declarationChecked()
            XCTFail("expected badSpec from declarationChecked over a rank-deficient bank")
        } catch WaveBank.BankError.badSpec(let message) {
            XCTAssertTrue(message.contains("rank threshold"), message)
            XCTAssertTrue(message.contains("rank 4 of 6"), message)
        }

        // S5 (iii): the zero guard used to be "checked" here by building a
        // `Declaration` literal in the test and asserting its own fields
        // back — an assertion that exercised no code. The guard is now
        // reached through a real declaration whose smallest singular value
        // is not positive, in `testS5NaNColumnDeclarationRefusesByName`
        // below.

        // The sealed CONTROL bank is deliberately rank deficient (146 of
        // 160) and must keep declaring, silently, exactly as before.
        let control = try WaveBank(spec: .reference)
        let controlDecl = control.declaration()
        XCTAssertNil(controlDecl.refusal)
        XCTAssertEqual(controlDecl.rank, 146)

        // A healthy bank still declares, and `declarationChecked` returns it.
        let healthy = try WaveBank(spec: .referenceNyquistSafe)
        let good = try healthy.declarationChecked()
        XCTAssertNil(good.refusal)
        XCTAssertEqual(good.rank, 144)
    }

    // MARK: - S5 (i) · 33's own edge: a NaN column in the declared matrix

    /// The verifier's S1 miss: the repair's `info` capture and zero guard
    /// were present but no test put a matrix in front of `dgesdd_` that it
    /// could not factor. The corrupted column is written into the built
    /// matrix by hand from the test — `atoms` is a `let` and the production
    /// type gains no setter, no initializer and no debug hook for this.
    func testS5NaNColumnDeclarationRefusesByName() throws {
        let spec = WaveBank.Spec(samples: 64, sampleRate: 3000, f0: 60, harmonics: 3,
                                 gaborCenters: 0, gaborFreqs: 0, gaborSigmaFrac: 0.02)

        // The same bank, uncorrupted, declares cleanly — the control.
        let healthy = try WaveBank(spec: spec)
        XCTAssertEqual(healthy.K, 6)
        let before = healthy.declaration()
        XCTAssertNil(before.refusal)
        XCTAssertEqual(before.lapackInfo, 0)
        XCTAssertEqual(before.rank, 6)
        XCTAssertTrue(before.conditionNumber.isFinite)
        print("S5(i) control bank: rank=\(before.rank) of \(healthy.K) "
              + "sigmaMax=\(before.sigmaMax) sigmaMin=\(before.sigmaMin) "
              + "cond=\(before.conditionNumber)")

        let bank = try WaveBank(spec: spec)
        let badColumn = 2
        bank.atoms.withUnsafeBufferPointer { buf in
            let raw = UnsafeMutablePointer(mutating: buf.baseAddress!)
            for t in 0..<bank.T { raw[badColumn * bank.T + t] = Float.nan }
        }
        XCTAssertTrue(bank.atom(badColumn).allSatisfy { $0.isNaN })
        XCTAssertTrue(bank.atom(0).allSatisfy { $0.isFinite })

        let decl = bank.declaration()
        print("S5(i) NaN column \(badColumn): lapackInfo=\(decl.lapackInfo) "
              + "sigmaMax=\(decl.sigmaMax) sigmaMin=\(decl.sigmaMin) rank=\(decl.rank) "
              + "cond=\(decl.conditionNumber) refusal=\(decl.refusal ?? "nil")")
        XCTAssertNotNil(decl.refusal, "a bank with a NaN column must not declare silently")

        if decl.lapackInfo != 0 {
            // LAPACK reported the failure itself — the refusal names it.
            XCTAssertTrue(decl.refusal!.contains("dgesdd_ failed with info=\(decl.lapackInfo)"),
                          decl.refusal!)
        } else {
            // OBSERVED, this platform: Accelerate's `dgesdd_` returns
            // info = 0 and hands back NaN singular values, so the `info != 0`
            // branch is UNEVALUABLE here and the non-finite branch refuses.
            XCTAssertEqual(decl.lapackInfo, 0)
            XCTAssertFalse(decl.sigmaMin > 0)
            XCTAssertFalse(decl.sigmaMax.isFinite)
            XCTAssertFalse(decl.conditionNumber.isFinite)
            XCTAssertEqual(decl.rank, 0)
            XCTAssertTrue(decl.refusal!.contains("smallest singular value"), decl.refusal!)
            XCTAssertTrue(decl.refusal!.contains("not finite"), decl.refusal!)
        }

        // Either way, the refusing door refuses, in the same words.
        do {
            _ = try bank.declarationChecked()
            XCTFail("expected declarationChecked to refuse a bank with a NaN column")
        } catch WaveBank.BankError.badSpec(let message) {
            XCTAssertEqual(message, decl.refusal)
        }
    }

    // MARK: - 34 / 35 · generate's column ceiling and length check

    func testF34And35GenerateRefusalsAreNamed() throws {
        let bank = try WaveBank(spec: WaveBank.Spec(
            samples: 64, sampleRate: 3000, f0: 60, harmonics: 4,
            gaborCenters: 0, gaborFreqs: 0, gaborSigmaFrac: 0.02))
        XCTAssertEqual(bank.K, 8)

        // Above the ceiling: `Int32(M)` TRAPPED past 2^31 and below that
        // `T * M` was an unbounded uninitialized allocation.
        let overCeiling = WaveBank.maxGenerateColumns + 1
        guard let ceilingMsg = bank.generateViolation(coefficients: [], columns: overCeiling) else {
            return XCTFail("expected a ceiling refusal")
        }
        XCTAssertTrue(ceilingMsg.contains("\(overCeiling)"), ceilingMsg)
        XCTAssertTrue(ceilingMsg.contains("\(WaveBank.maxGenerateColumns)"), ceilingMsg)
        XCTAssertEqual(bank.generate(coefficients: [], columns: overCeiling), [])
        do {
            _ = try bank.generateChecked(coefficients: [], columns: overCeiling)
            XCTFail("expected badSpec above the column ceiling")
        } catch WaveBank.BankError.badSpec(let message) {
            XCTAssertTrue(message.contains("ceiling"), message)
        }
        // Int32's own edge, which used to trap.
        XCTAssertEqual(bank.generate(coefficients: [], columns: Int(Int32.max) + 1), [])

        // A length mismatch: silence indistinguishable from an empty request.
        do {
            _ = try bank.generateChecked(coefficients: [Float](repeating: 0, count: bank.K), columns: 2)
            XCTFail("expected badSpec for a coefficient-count mismatch")
        } catch WaveBank.BankError.badSpec(let message) {
            XCTAssertTrue(message.contains("K x M"), message)
        }

        // The ordinary product still works, and at the ceiling exactly the
        // violation is nil.
        let w = try bank.generateChecked(
            coefficients: [Float](repeating: 1, count: bank.K * 3), columns: 3)
        XCTAssertEqual(w.count, 64 * 3)
        XCTAssertNil(bank.generateViolation(
            coefficients: [Float](repeating: 0, count: bank.K), columns: 1))
    }

    // MARK: - LadderFold helpers

    private func controlObject() throws -> (LadderFold.Object, DagDBEngine, HexGrid) {
        let grid = try HexGrid(width: 12, height: 12)
        let engine = try DagDBEngine(grid: grid, state: DagDBState(width: 12, height: 12), maxRank: 64)
        return (LadderFold.Objects.control(engine: engine, grid: grid), engine, grid)
    }

    // MARK: - 36 / 79 · a schedule one rank short of the object

    func testItem79ScheduleOneRankShortRefused() throws {
        let (object, _, _) = try controlObject()

        // The fact the contract asks be PRINTED: both frozen pairings sit
        // exactly at the bound, with zero headroom.
        let headroom = LadderFold.scheduleHeadroom(
            object: object, schedule: LadderFold.Objects.controlSchedule)
        print("F36 control: object max rank \(headroom.objectMaxRank), schedule maxRank "
              + "\(headroom.scheduleMaxRank), headroom \(headroom.headroom)")
        XCTAssertEqual(headroom.objectMaxRank, 6)
        XCTAssertEqual(headroom.scheduleMaxRank, 6)
        XCTAssertEqual(headroom.headroom, 0)

        // One rank short: rank-6 nodes are in neither `ring` nor `keep`, so
        // `active = keep` DROPPED them at the first fold, with their rows
        // and columns of the operator — silently.
        let short = LadderFold.Schedule(maxRank: 5, keepRank: 3, checkpoints: [])
        guard let violation = LadderFold.violation(
            object: object, schedule: short, sources: LadderFold.Objects.controlSources) else {
            return XCTFail("expected a refusal for a schedule one rank short of the object")
        }
        XCTAssertTrue(violation.contains("maxRank 5"), violation)
        XCTAssertTrue(violation.contains("6"), violation)

        let refused = LadderFold.run(object: object, schedule: short,
                                     sources: LadderFold.Objects.controlSources)
        XCTAssertNotNil(refused.refusal)
        XCTAssertTrue(refused.log.isEmpty)
        XCTAssertTrue(refused.keptNodes.isEmpty)
        do {
            _ = try LadderFold.runChecked(object: object, schedule: short,
                                          sources: LadderFold.Objects.controlSources)
            XCTFail("expected FoldError.refused")
        } catch LadderFold.FoldError.refused(let message) {
            XCTAssertTrue(message.contains("drop"), message)
        }
    }

    // MARK: - 36 · eliminated + kept == nodeCount across the whole run

    func testF36EliminatedPlusKeptEqualsNodeCount() throws {
        let (object, _, _) = try controlObject()
        let result = try LadderFold.runChecked(
            object: object, schedule: LadderFold.Objects.controlSchedule,
            sources: LadderFold.Objects.controlSources)
        var eliminated = 0
        for step in result.log {
            eliminated += step.eliminated
            XCTAssertEqual(eliminated + step.kept, object.nodeCount,
                           "after fold \(step.fold) (ring \(step.ring))")
        }
        XCTAssertEqual(eliminated + result.keptCount, object.nodeCount)
    }

    // MARK: - 37 · out-of-range source indices

    func testF37SourceIndexOutOfRangeRefused() throws {
        let (object, _, _) = try controlObject()
        let n = object.nodeCount
        let schedule = LadderFold.Objects.controlSchedule

        // Only `f3` was guarded, and only against negatives.
        let bad: [(String, LadderFold.Sources)] = [
            ("f1", LadderFold.Sources(f1: n, f2: 0)),
            ("f1", LadderFold.Sources(f1: -1, f2: 0)),
            ("f2", LadderFold.Sources(f1: 0, f2: n + 5)),
            ("f3", LadderFold.Sources(f1: 0, f2: 0, f3: n)),
        ]
        for (label, sources) in bad {
            guard let violation = LadderFold.violation(
                object: object, schedule: schedule, sources: sources) else {
                return XCTFail("expected a refusal for \(label) = \(sources)")
            }
            XCTAssertTrue(violation.contains(label), violation)
            XCTAssertTrue(violation.contains("\(n)"), violation)
            XCTAssertNotNil(LadderFold.run(object: object, schedule: schedule, sources: sources).refusal)
        }
        // f3 = -1 is the documented "no third source".
        XCTAssertNil(LadderFold.violation(object: object, schedule: schedule,
                                          sources: LadderFold.Sources(f1: 0, f2: 1, f3: -1)))
    }

    // MARK: - 38 · a singular operator throws instead of aborting

    func testF38SingularOperatorRefused() throws {
        // Two rank-1 nodes with no edges and zero leak: the operator is the
        // zero matrix, so the ring block is singular. The pre-audit
        // `precondition(INFO == 0)` ABORTED the process here.
        let object = LadderFold.Object(
            nodeCount: 2, adjacency: [[], []], rank: [1, 0], leak: 0.0)
        let schedule = LadderFold.Schedule(maxRank: 1, keepRank: 0, checkpoints: [])
        XCTAssertNil(LadderFold.violation(object: object, schedule: schedule,
                                          sources: LadderFold.Sources(f1: 0, f2: 1)))

        let refused = LadderFold.run(object: object, schedule: schedule,
                                     sources: LadderFold.Sources(f1: 0, f2: 1))
        guard let message = refused.refusal else {
            return XCTFail("expected a refusal for a singular fold")
        }
        print("F38 singular refusal = \(message)")
        XCTAssertTrue(message.contains("singular"), message)
        XCTAssertTrue(message.contains("info="), message)
        do {
            _ = try LadderFold.runChecked(object: object, schedule: schedule,
                                          sources: LadderFold.Sources(f1: 0, f2: 1))
            XCTFail("expected FoldError.refused")
        } catch LadderFold.FoldError.refused(let m) {
            XCTAssertTrue(m.contains("singular"), m)
        }
    }

    // MARK: - 39 · a rank the fold cannot represent

    func testF39RankAboveIntMaxRefused() throws {
        let grid = try HexGrid(width: 12, height: 12)
        let engine = try DagDBEngine(grid: grid, state: DagDBState(width: 12, height: 12), maxRank: 64)
        _ = LadderFold.Objects.control(engine: engine, grid: grid)

        // Write a rank the UInt64 lane holds and Int cannot: the pre-audit
        // `Int(rkBack[...])` TRAPPED on it, inside a public initializer.
        let rankPtr = engine.rankBuf.contents().bindMemory(to: UInt64.self, capacity: grid.nodeCount)
        rankPtr[3] = UInt64.max

        let object = LadderFold.Object(engine: engine, grid: grid)
        guard let refusal = object.refusal else {
            return XCTFail("expected the object to carry a refusal for an unrepresentable rank")
        }
        XCTAssertTrue(refusal.contains("\(UInt64.max)"), refusal)
        XCTAssertTrue(refusal.contains("Int.max") || refusal.contains("\(Int.max)"), refusal)

        // And `run` refuses it rather than folding a wrong rank vector.
        do {
            _ = try LadderFold.runChecked(
                object: object, schedule: LadderFold.Objects.controlSchedule,
                sources: LadderFold.Objects.controlSources)
            XCTFail("expected FoldError.refused")
        } catch LadderFold.FoldError.refused(let m) {
            XCTAssertTrue(m.contains("rank"), m)
        }
    }

    // MARK: - 40 · the price table measured against a serialized size

    func testF40PriceTableMeasuredAgainstBytesOnDisk() throws {
        let (object, _, _) = try controlObject()
        let result = try LadderFold.runChecked(
            object: object, schedule: LadderFold.Objects.controlSchedule,
            sources: LadderFold.Objects.controlSources)

        let dir = scratchDir("f40")
        defer { removeScratch(dir) }
        let opPath = dir + "/final_operator.f32"
        try result.serializedFinalOperator().write(to: URL(fileURLWithPath: opPath))
        let opBytes = (try FileManager.default.attributesOfItem(atPath: opPath)[.size] as! NSNumber).intValue
        XCTAssertEqual(opBytes, result.finalBytes,
                       "finalBytes must equal the bytes the final operator actually occupies")

        guard let finalTier = result.tiers["final"] else { return XCTFail("no final tier") }
        let srcPath = dir + "/final_sources.f32"
        try result.serializedTierSources("final")!.write(to: URL(fileURLWithPath: srcPath))
        let srcBytes = (try FileManager.default.attributesOfItem(atPath: srcPath)[.size] as! NSNumber).intValue
        XCTAssertEqual(opBytes + srcBytes, finalTier.bytes,
                       "Tier.bytes must equal the operator plus the three source vectors on disk")
        print("F40 measured: operator \(opBytes) B + sources \(srcBytes) B = tier \(finalTier.bytes) B")
    }

    // MARK: - DerivedViews synthetic fixture

    /// A hand-built cortex fixture: `stations` stations, `candidates`
    /// candidates, deterministic tau rows. Built here so findings 41-44
    /// have an edge to reach without the out-of-repo npz.
    private func syntheticFixture(stations: Int = 4, samples: Int = 64, candidates: Int = 5,
                                  speed: Double = 1500, dt: Double = 1.0 / 24000, os: Int = 8)
        -> CortexFixture {
        var tau = [Double](repeating: 0, count: candidates * stations)
        var tauRaw = [Double](repeating: 0, count: candidates * stations)
        for c in 0..<candidates {
            for s in 0..<stations {
                tau[c * stations + s] = Double(c + 1) * 1e-4 * Double(s) + 1e-5 * Double(s * s)
                tauRaw[c * stations + s] = tau[c * stations + s]
            }
        }
        var x = [Float](repeating: 0, count: 2 * stations * samples)
        for m in 0..<2 {
            for s in 0..<stations {
                let front = 4 + m * 3 + s * 2
                for t in front..<min(front + 8, samples) { x[(m * stations + s) * samples + t] = 1.0 }
            }
        }
        return CortexFixture(
            path: "<synthetic>", sha256: String(repeating: "0", count: 64),
            stations: stations, samples: samples, candidates: candidates,
            xTrain: x, yTrain: [0, 1], xTest: x, yTest: [0, 1],
            tau: tau, tauRaw: tauRaw,
            scan: Array(0..<stations), cand: Array(0..<candidates),
            speed: speed, dt: dt, os: os, fs: 3000)
    }

    // MARK: - 41 · a station count above the fixture's own

    func testF41StationsAboveTheFixtureRefused() {
        let views = DerivedViews(fixture: syntheticFixture())
        let frame = views.fixture.frame(test: 0)
        XCTAssertEqual(views.fixture.stations, 4)

        // 5 > 4: `fixture.tau[c*stride + s]` read SILENTLY into candidate
        // c+1's row for every candidate but the last, then `frame[s]`
        // trapped.
        XCTAssertNotNil(views.stationsViolation(5))
        XCTAssertNotNil(views.stationsViolation(0))
        XCTAssertNil(views.stationsViolation(4))
        XCTAssertThrowsError(try views.checkStations(9))

        XCTAssertNotNil(DerivedViews.arrivals(frame: frame, stations: 9).refusal)
        XCTAssertEqual(DerivedViews.arrivals(frame: frame, stations: 9).raw, [])
        XCTAssertEqual(DerivedViews.features(frame: frame, stations: 9, fs: 3000), [])

        let decision = views.reflex(frame: frame, stations: 9)
        XCTAssertNotNil(decision.refusal)
        XCTAssertEqual(decision.winner, -1)
        XCTAssertNotNil(views.reflexSummary(stations: 9).refusal)
        XCTAssertNotNil(views.centroids(stations: 9).refusal)
        XCTAssertNotNil(views.ceiling(stations: 9).refusal)
        let c = views.centroids(stations: 4)
        XCTAssertNil(c.refusal)
        XCTAssertNotNil(views.rung(stations: 9, centroids: c).refusal)

        // The in-range call still answers.
        XCTAssertNil(views.reflex(frame: frame, stations: 4).refusal)
        XCTAssertEqual(DerivedViews.features(frame: frame, stations: 4, fs: 3000).count, 12)
    }

    // MARK: - 42 · a failed solve is skipped and counted, never scored

    func testF42FailedSolveIsSkippedAndCounted() {
        let views = DerivedViews(fixture: syntheticFixture())
        let frame = views.fixture.frame(test: 0)
        let decision = views.reflex(frame: frame, stations: 4)
        // On a well-posed fixture nothing is skipped — the receipt that
        // this change cannot move a sealed number.
        XCTAssertEqual(decision.skipped, 0)
        XCTAssertNil(decision.refusal)
        XCTAssertEqual(views.reflexSummary(stations: 4).skippedTotal, 0)

        // The counter is carried, not invented: it is the field the
        // contract asks be printed beside the decision.
        print("F42 reflex: winner=\(decision.winner) tied=\(decision.tiedSet.count) "
              + "skipped=\(decision.skipped)")

        // S5 (iii): these three lines used to copy `decision.residuals`
        // into a LOCAL array, write `.infinity` into it, and assert things
        // about the local array — no code under test was exercised. The
        // claim they were reaching for is the selection rule: the minimum
        // and the tied set are taken over the SCORABLE residuals only, so a
        // skipped candidate (residual +infinity) can never win and can never
        // tie. That rule is now re-derived here, independently of the code
        // that applied it, from the residual vector each decision carries —
        // over both test frames and both station counts.
        for m in 0..<views.fixture.yTest.count {
            for S in [2, 4] {
                let d = views.reflex(frame: views.fixture.frame(test: m), stations: S)
                let scorable = d.residuals.enumerated().filter { $0.element.isFinite }
                guard let rMin = scorable.map({ $0.element }).min() else {
                    return XCTFail("frame \(m) S=\(S): every candidate skipped")
                }
                let tol = 1e-9 * max(1.0, rMin)
                let derivedTied = scorable.filter { $0.element <= rMin + tol }.map { $0.offset }
                XCTAssertEqual(d.rMin, rMin, "frame \(m) S=\(S)")
                XCTAssertEqual(d.tiedSet, derivedTied, "frame \(m) S=\(S)")
                XCTAssertEqual(d.winner, derivedTied.first, "frame \(m) S=\(S)")
                // Nothing non-finite is ever inside the tied set, and the
                // skipped tally is the count of non-finite residuals.
                for c in d.tiedSet { XCTAssertTrue(d.residuals[c].isFinite, "frame \(m) S=\(S) c=\(c)") }
                XCTAssertEqual(d.skipped, d.residuals.filter { !$0.isFinite }.count,
                               "frame \(m) S=\(S)")
            }
        }
    }

    // MARK: - 43 · the 16-sample front window, gated as a control

    func testF43FrontWindowConventionAtTheRecordEnd() {
        // A frame whose arrival lands within 16 samples of the end — the
        // case the code zero-fills and numpy's `row[f:f+16]` shortens.
        let samples = 64
        var row = [Float](repeating: 0, count: samples)
        for t in 50..<samples { row[t] = 1.0 }          // front index 50, t >= 48
        let frame: [[Float]] = [row]
        let fs = 3000.0

        let arr = DerivedViews.arrivals(frame: frame, stations: 1)
        XCTAssertEqual(arr.raw, [50.0])
        XCTAssertGreaterThanOrEqual(Int(arr.raw[0]), 48)

        let feat = DerivedViews.features(frame: frame, stations: 1, fs: fs)

        // The CONTROL: numpy's short-window convention, computed here
        // independently of the code under test — `row[f:f+16]` yields the
        // 14 real samples, and its rfft bins are k·fs/14, not k·fs/16.
        let short = Array(row[50..<samples]).map(Double.init)      // 14 samples
        var magSum = 0.0, weighted = 0.0
        let n = short.count
        for k in 0...(n / 2) {
            var re = 0.0, im = 0.0
            for j in 0..<n {
                let theta = 2.0 * Double.pi * Double(k) * Double(j) / Double(n)
                re += short[j] * cos(theta)
                im -= short[j] * sin(theta)
            }
            let mag = (re * re + im * im).squareRoot()
            magSum += mag
            weighted += mag * (Double(k) * fs / Double(n))
        }
        let numpyShortCentroid = magSum < 1e-12 ? 0.0 : weighted / magSum

        // The two conventions DO diverge here — that is the finding. The
        // gate pins which one this engine implements: the declared,
        // zero-filled 16-sample window, with bins k·fs/16.
        print("F43 front at t=50: engine centroid \(feat[1]) Hz, numpy short-window "
              + "centroid \(numpyShortCentroid) Hz")
        XCTAssertNotEqual(feat[1], numpyShortCentroid, accuracy: 0.0)

        // Recomputed the engine's own way, independently of `features`:
        var win = [Double](repeating: 0, count: 16)
        for j in 0..<16 where 50 + j < samples { win[j] = Double(row[50 + j]) }
        var m2 = 0.0, w2 = 0.0
        for k in 0...8 {
            var re = 0.0, im = 0.0
            for j in 0..<16 {
                let theta = 2.0 * Double.pi * Double(k) * Double(j) / 16.0
                re += win[j] * cos(theta)
                im -= win[j] * sin(theta)
            }
            let mag = (re * re + im * im).squareRoot()
            m2 += mag
            w2 += mag * (Double(k) * fs / 16.0)
        }
        XCTAssertEqual(feat[1], m2 < 1e-12 ? 0.0 : w2 / m2, accuracy: 1e-9)

        // A frame whose front leaves both windows inside the record: the
        // two conventions then agree exactly, so the divergence above is
        // the END of the record, not a general disagreement.
        var early = [Float](repeating: 0, count: samples)
        for t in 0..<samples { early[t] = Float(cos(2.0 * Double.pi * 750.0 * Double(t) / fs)) }
        let earlyFeat = DerivedViews.features(frame: [early], stations: 1, fs: fs)
        XCTAssertEqual(earlyFeat[1], 750.0, accuracy: 1e-9)
    }

    // MARK: - 44 · a non-finite k

    func testF44NonFiniteScaleRefused() {
        // speed 0 makes k = 1/(speed·dt·os) infinite: every class size 1
        // and a ceiling of 1.0, silently.
        let zeroSpeed = DerivedViews(fixture: syntheticFixture(speed: 0))
        let refused = zeroSpeed.ceiling(stations: 4)
        guard let message = refused.refusal else {
            return XCTFail("expected a refusal for speed 0")
        }
        print("F44 ceiling refusal = \(message)")
        XCTAssertTrue(message.contains("speed"), message)
        XCTAssertEqual(refused.ceiling, 0)
        XCTAssertEqual(refused.identifiable, 0)

        // dt 0 too.
        XCTAssertNotNil(DerivedViews(fixture: syntheticFixture(dt: 0)).ceiling(stations: 4).refusal)
        // And a NaN dt.
        XCTAssertNotNil(DerivedViews(fixture: syntheticFixture(dt: .nan)).ceiling(stations: 4).refusal)

        // The ordinary fixture still answers.
        let ok = DerivedViews(fixture: syntheticFixture()).ceiling(stations: 4)
        XCTAssertNil(ok.refusal)
        XCTAssertGreaterThan(ok.identifiable, 0)
    }
}
