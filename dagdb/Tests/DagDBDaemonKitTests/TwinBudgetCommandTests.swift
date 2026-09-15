import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// the interface phase — daemon-level tests for the real XCONV/BUDGET verbs
/// (DagDBCommandHandler+TwinBudget.swift). The XCONV fixture is rebuilt
/// in-test from CrossConvolutionCheckTests' reference NamedStream seed
/// (draw order: 64 source samples, then 6 kA taps, then 9 kB taps) so a[69]
/// and b[72] land in shm exactly where the DSL grammar expects them. The
/// BUDGET fixtures reuse BudgetLayoutTests.layoutEngine()'s literal table
/// and the sealed court's numbers (SealedCourt.makeLayout(), budgetGrid).
final class TwinBudgetCommandTests: XCTestCase {

    // MARK: - XCONV fixture (verbatim draw order from CrossConvolutionCheckTests)

    private func unit(_ stream: inout NamedStream) -> Float {
        Float(stream.next64() >> 40) / Float(1 << 24) - 0.5
    }

    private func xconvFixture() -> (a: [Float], b: [Float], kA: [Float], kB: [Float]) {
        var stream = NamedStream(
            name: "w6",
            stateHi: 0x853c_49e6_748f_ea9b, stateLo: 0xda3e_39cb_94b9_5bdb,
            incHi: 0x5851_f42d_4c95_7f2d, incLo: 0x1405_7b7e_f767_814f
        )
        let source = (0..<64).map { _ in unit(&stream) }
        let kA = (0..<6).map { _ in unit(&stream) }
        let kB = (0..<9).map { _ in unit(&stream) }
        let a = CrossConvolutionCheck.convolve(source, .init(taps: kA)).map { Float($0) }
        let b = CrossConvolutionCheck.convolve(source, .init(taps: kB)).map { Float($0) }
        return (a, b, kA, kB)
    }

    // MARK: - shm pokes (direct memory writes, mirroring the daemon's own layout)

    private func writeFloats(_ v: [Float], at byteOffset: Int, into f: HandlerFixture) {
        let ptr = f.shm.advanced(by: byteOffset).bindMemory(to: Float.self, capacity: max(1, v.count))
        for (i, x) in v.enumerated() { ptr[i] = x }
    }

    private func writeDoubles(_ v: [Double], at byteOffset: Int, into f: HandlerFixture) {
        let ptr = f.shm.advanced(by: byteOffset).bindMemory(to: Double.self, capacity: max(1, v.count))
        for (i, x) in v.enumerated() { ptr[i] = x }
    }

    private func writeU32s(_ v: [UInt32], at byteOffset: Int, into f: HandlerFixture) {
        let ptr = f.shm.advanced(by: byteOffset).bindMemory(to: UInt32.self, capacity: max(1, v.count))
        for (i, x) in v.enumerated() { ptr[i] = x }
    }

    /// Writes a, b, kA, kB contiguous from shm offset 8 — the layout
    /// `XCONV CHECK <nA> <nB> <kA> <kB> <warmup>` reads.
    private func writeXConvInputs(a: [Float], b: [Float], kA: [Float], kB: [Float], into f: HandlerFixture) -> (aOff: Int, bOff: Int, kAOff: Int, kBOff: Int) {
        let aOff = 8
        let bOff = aOff + a.count * 4
        let kAOff = bOff + b.count * 4
        let kBOff = kAOff + kA.count * 4
        writeFloats(a, at: aOff, into: f)
        writeFloats(b, at: bOff, into: f)
        writeFloats(kA, at: kAOff, into: f)
        writeFloats(kB, at: kBOff, into: f)
        return (aOff, bOff, kAOff, kBOff)
    }

    /// Writes a BudgetLayout's cost table (row-major f64) then minTier
    /// (u32) contiguous from shm offset 8 — the layout `BUDGET OPEN`
    /// reads.
    private func writeBudgetOpenInputs(cost: [[Double]], minTier: [Int], into f: HandlerFixture) {
        let flat = cost.flatMap { $0 }
        writeDoubles(flat, at: 8, into: f)
        let minTierBytesOffset = 8 + flat.count * 8
        writeU32s(minTier.map { UInt32($0) }, at: minTierBytesOffset, into: f)
    }

    /// Same literal table as BudgetLayoutTests.layoutEngine(): only the
    /// two load-bearing tiers (r4, r7) carry sealed numbers, the rest are
    /// monotone fillers.
    private func layoutEngine() -> BudgetLayout {
        func row(r4: Double, r7: Double) -> [Double] {
            [r4 / 2, r4, r4 * 2, r4 * 4, r7, r7 * 2, r7 * 3, r7 * 4]
        }
        return BudgetLayout(cost: [
            row(r4: 162, r7: 15138),
            row(r4: 50, r7: 12168),
            row(r4: 162, r7: 10952),
            row(r4: 98, r7: 5618),
        ], minTier: [4, 1, 4])
    }

    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "dagdb-twinbudget-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    private func parseField(_ reply: String, _ key: String) -> String? {
        guard let r = reply.range(of: "\(key)=") else { return nil }
        let rest = reply[r.upperBound...]
        let end = rest.firstIndex(of: " ") ?? rest.endIndex
        return String(rest[rest.startIndex..<end])
    }

    private func openReaderId(_ f: HandlerFixture) throws -> String {
        let openReply = f.handler.handle("OPEN_READER")
        guard let ridRange = openReply.range(of: "id="),
              let spaceRange = openReply.range(of: " ", range: ridRange.upperBound..<openReply.endIndex) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not parse reader id out of: \(openReply)"])
        }
        return String(openReply[ridRange.upperBound..<spaceRange.lowerBound])
    }

    // MARK: - XCONV CHECK

    func testXConvCheckTrueSignalResidualBelowThreshold() throws {
        let f = try HandlerFixture(side: 6)
        let fx = xconvFixture()
        _ = writeXConvInputs(a: fx.a, b: fx.b, kA: fx.kA, kB: fx.kB, into: f)
        XCTAssertEqual(fx.a.count, 69)
        XCTAssertEqual(fx.b.count, 72)

        let reply = f.handler.handle("XCONV CHECK 69 72 6 9 16")
        XCTAssertTrue(reply.hasPrefix("OK XCONV CHECK"), reply)
        guard let residualStr = parseField(reply, "residual"), let residual = Double(residualStr) else {
            return XCTFail("could not parse residual out of: \(reply)")
        }
        XCTAssertLessThan(residual, 1e-6)
    }

    func testXConvCheckForgedBResidualAboveThreshold() throws {
        let f = try HandlerFixture(side: 6)
        let fx = xconvFixture()
        var noise = NamedStream(name: "forge", stateHi: 1, stateLo: 2, incHi: 3, incLo: 5)
        let forgedB = (0..<fx.b.count).map { _ in unit(&noise) }
        _ = writeXConvInputs(a: fx.a, b: forgedB, kA: fx.kA, kB: fx.kB, into: f)

        let reply = f.handler.handle("XCONV CHECK 69 72 6 9 16")
        XCTAssertTrue(reply.hasPrefix("OK XCONV CHECK"), reply)
        guard let residualStr = parseField(reply, "residual"), let residual = Double(residualStr) else {
            return XCTFail("could not parse residual out of: \(reply)")
        }
        XCTAssertGreaterThan(residual, 0.5)
    }

    func testXConvCheckOversizedIsOutOfRange() throws {
        let f = try HandlerFixture(side: 6)
        let reply = f.handler.handle("XCONV CHECK 1000 72 6 9 16")
        XCTAssertTrue(reply.hasPrefix("ERROR out_of_range"), reply)
    }

    // MARK: - BUDGET SEALED / ALLOCATE (sealed court)

    func testBudgetSealedReturnsFourPocketsEightTiersTwoClasses() throws {
        let f = try HandlerFixture(side: 6)
        XCTAssertEqual(f.handler.handle("BUDGET SEALED"), "OK BUDGET SEALED id=b00000001 pockets=4 tiers=8 classes=2")
    }

    func testBudgetAllocateSealedLegalMiss() throws {
        let f = try HandlerFixture(side: 6)
        _ = f.handler.handle("BUDGET SEALED")
        let reply = f.handler.handle("BUDGET ALLOCATE b00000001 16164.352484758914 0:0 3:0")
        XCTAssertTrue(reply.hasPrefix("OK BUDGET ALLOCATE"), reply)
        XCTAssertEqual(parseField(reply, "served"), "3", reply)
        XCTAssertEqual(parseField(reply, "cost"), "5618.0", reply)
        XCTAssertEqual(parseField(reply, "value"), "1", reply)
    }

    // MARK: - BUDGET OPEN (custom table via shm)

    func testBudgetOpenLayoutEngineAllocateColocationRescue() throws {
        let f = try HandlerFixture(side: 6)
        let e = layoutEngine()
        writeBudgetOpenInputs(cost: e.cost, minTier: e.minTier, into: f)
        let openReply = f.handler.handle("BUDGET OPEN 4 8 3")
        XCTAssertEqual(openReply, "OK BUDGET OPEN id=b00000001 pockets=4 tiers=8 classes=3")

        let reply = f.handler.handle("BUDGET ALLOCATE b00000001 16164 0:0 0:0 3:0")
        XCTAssertTrue(reply.hasPrefix("OK BUDGET ALLOCATE"), reply)
        XCTAssertEqual(parseField(reply, "served"), "0", reply)
        XCTAssertEqual(parseField(reply, "value"), "2", reply)
    }

    func testBudgetAllocateClassIndexOutOfRange() throws {
        let f = try HandlerFixture(side: 6)
        let e = layoutEngine()
        writeBudgetOpenInputs(cost: e.cost, minTier: e.minTier, into: f)
        _ = f.handler.handle("BUDGET OPEN 4 8 3")

        let reply = f.handler.handle("BUDGET ALLOCATE b00000001 16164 0:3")
        XCTAssertTrue(reply.hasPrefix("ERROR out_of_range"), reply)
    }

    /// `BudgetLayout.validationError` (the front door `BUDGET OPEN` calls)
    /// caps a REGISTERED layout at `maxClaimedPockets` (20) pockets total —
    /// so the DSL can never OPEN a 21-pocket layout in the first place, the
    /// exact size that would let `allocate()`'s own claimed-pockets guard
    /// fire. That guard is still real code this handler must map correctly
    /// (a layout restored from an older snapshot/WAL predating the OPEN-time
    /// cap could still carry more pockets), so this test registers an
    /// oversized layout directly through `TwinRegistry.open` — the same
    /// entry point WAL/snapshot restore uses — bypassing `BUDGET OPEN`'s
    /// validating front door, then drives it through `BUDGET ALLOCATE` to
    /// confirm `LayoutError.tooManyClaimedPockets` becomes `ERROR out_of_range`.
    func testBudgetAllocateTooManyClaimedPocketsOutOfRange() throws {
        let f = try HandlerFixture(side: 6)
        let nPockets = 25
        let layout = BudgetLayout(cost: [[Double]](repeating: [1.0], count: nPockets), minTier: [0])
        let id = try f.handler.twin.layouts.open(layout)

        let claims = (0..<21).map { "\($0):0" }.joined(separator: " ")
        let reply = f.handler.handle("BUDGET ALLOCATE \(id) 1000 \(claims)")
        XCTAssertTrue(reply.hasPrefix("ERROR out_of_range"), reply)
        XCTAssertTrue(reply.contains("tooManyClaimedPockets"), reply)
    }

    func testBudgetOpenNaNCostIsBadValue() throws {
        let f = try HandlerFixture(side: 6)
        writeBudgetOpenInputs(cost: [[Double.nan]], minTier: [0], into: f)
        let reply = f.handler.handle("BUDGET OPEN 1 1 1")
        XCTAssertTrue(reply.hasPrefix("ERROR bad_value"), reply)
    }

    // MARK: - WAL replay restores the layout

    func testBudgetWalReplayRestoresLayoutInfoEqual() throws {
        let walPath = tmpDir + "twin.wal"
        let appender = try DagDBWAL.Appender(path: walPath, nodeCount: 36)
        let f = try HandlerFixture(side: 6, wal: appender)

        XCTAssertEqual(f.handler.handle("BUDGET SEALED"), "OK BUDGET SEALED id=b00000001 pockets=4 tiers=8 classes=2")
        let beforeInfo = f.handler.handle("BUDGET INFO b00000001")

        let fresh = TwinState()
        let grid = try HexGrid(width: 6, height: 6)
        let state = DagDBState(width: 6, height: 6)
        let freshEngine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
        _ = try DagDBWAL.replay(engine: freshEngine, nodeCount: freshEngine.nodeCount, path: walPath, twin: fresh)

        XCTAssertEqual(fresh.layouts.get("b00000001"), f.handler.twin.layouts.get("b00000001"))

        let f2 = try HandlerFixture(side: 6, twin: fresh)
        let afterInfo = f2.handler.handle("BUDGET INFO b00000001")
        XCTAssertEqual(beforeInfo, afterInfo)
    }

    // MARK: - READER: allows ALLOCATE/XCONV CHECK, forbids OPEN

    func testReaderAllowsAllocateAndCheckForbidsOpen() throws {
        let f = try HandlerFixture(side: 6)
        _ = f.handler.handle("BUDGET SEALED")
        let rid = try openReaderId(f)

        let allocateReply = f.handler.handle("READER \(rid) BUDGET ALLOCATE b00000001 16164.352484758914 0:0 3:0")
        XCTAssertTrue(allocateReply.hasPrefix("OK BUDGET ALLOCATE session=\(rid)"), allocateReply)

        writeFloats([0, 0, 0], at: 8, into: f)
        writeFloats([0, 0, 0], at: 20, into: f)
        writeFloats([1], at: 32, into: f)
        writeFloats([1], at: 36, into: f)
        let checkReply = f.handler.handle("READER \(rid) XCONV CHECK 3 3 1 1 1")
        XCTAssertTrue(checkReply.hasPrefix("OK XCONV CHECK session=\(rid)"), checkReply)

        let openReply = f.handler.handle("READER \(rid) BUDGET OPEN 1 1 1")
        XCTAssertTrue(openReply.hasPrefix("ERROR forbidden"), openReply)
    }
}
