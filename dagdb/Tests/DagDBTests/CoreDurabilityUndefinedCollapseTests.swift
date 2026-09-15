import XCTest
@testable import DagDB

/// C12(ii) · audit finding 20 — the UNDEFINED collapse, TESTED.
///
/// `eval_lut6` returns one bit, so a node holding `TRUTH_UNDEFINED` (2) is
/// written back as FALSE (0) by the next tick, in rank mode and in sync mode
/// alike. The core-durability contract rules tri-valued evaluation out of
/// scope and calls the collapse "the kernel's semantics, DOCUMENTED". The
/// audit's own gate asks for "preservation or a documented, TESTED collapse"
/// — the documentation existed and nothing checked it. This checks it, so
/// the doc is verified rather than trusted, and the day someone makes the
/// kernel tri-valued this test is what tells them the doc must change too.
final class CoreDurabilityUndefinedCollapseTests: XCTestCase {

    /// Every node CONST0, no edges, nothing a tick could pull in — so the
    /// only thing that can move node 9 is the collapse itself.
    private func makeEngine(side: Int) throws -> DagDBEngine {
        let e = try DagDBEngine(grid: HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side),
                                maxRank: 4)
        let n = e.nodeCount
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        for i in 0..<(n * 6) { nb[i] = -1 }
        let low = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high = e.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        for i in 0..<n {
            low[i] = UInt32(LUT6Preset.const0 & 0xFFFF_FFFF)
            high[i] = UInt32((LUT6Preset.const0 >> 32) & 0xFFFF_FFFF)
        }
        e.markRankTopologyDirty()
        return e
    }

    private let victim = 9

    func testUndefinedCollapsesToFalseInRankMode() throws {
        let e = try makeEngine(side: 8)
        let truth = e.truthStateBuf.contents()
            .bindMemory(to: UInt8.self, capacity: e.nodeCount)
        truth[victim] = 2
        XCTAssertEqual(e.readTruthStates()[victim], 2, "the fixture really set UNDEFINED")
        XCTAssertFalse(e.isRegister(node: UInt32(victim)),
                       "a register would HOLD its value — that is a different rule")

        e.tick(tickNumber: 0)

        XCTAssertEqual(e.readTruthStates()[victim], 0,
                       "rank mode: UNDEFINED (2) collapses to FALSE (0) at the " +
                       "next tick — the kernel writes one LUT bit, documented " +
                       "beside eval_lut6 in Shaders/dagdb.metal")
    }

    func testUndefinedCollapsesToFalseInSyncMode() throws {
        let e = try makeEngine(side: 8)
        let truth = e.truthStateBuf.contents()
            .bindMemory(to: UInt8.self, capacity: e.nodeCount)
        truth[victim] = 2
        XCTAssertEqual(e.readTruthStates()[victim], 2)

        e.tickSync(tickNumber: 0)

        XCTAssertEqual(e.readTruthStates()[victim], 0,
                       "sync mode collapses it too — the two modes agree, which " +
                       "is why the doc says 'in both rank and sync mode'")
    }

    /// The other half of the documented rule: an UNDEFINED INPUT reads as 0
    /// for the LUT index, so it is not merely erased, it is treated as false
    /// by whoever consumes it.
    func testUndefinedReadsAsFalseForAConsumersLUTIndex() throws {
        let e = try makeEngine(side: 8)
        let n = e.nodeCount
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: n)
        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: n)
        let low = e.lut6LowBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let high = e.lut6HighBuf.contents().bindMemory(to: UInt32.self, capacity: n)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)

        // consumer reads producer on slot 0, and is IDENTITY on that bit.
        let producer = 20, consumer = 21
        rank[producer] = 1
        rank[consumer] = 0
        nb[consumer * 6 + 0] = Int32(producer)
        low[consumer] = UInt32(LUT6Preset.identity & 0xFFFF_FFFF)
        high[consumer] = UInt32((LUT6Preset.identity >> 32) & 0xFFFF_FFFF)
        // Keep the producer UNDEFINED across the tick by holding it as a
        // register: registers are skipped by the combinational pass.
        try e.addBackEdge(src: UInt32(producer), dst: UInt32(producer))
        truth[producer] = 2
        truth[consumer] = 1
        e.markRankTopologyDirty()

        e.tick(tickNumber: 0)

        XCTAssertEqual(e.readTruthStates()[producer], 2,
                       "the register held its UNDEFINED across the tick")
        XCTAssertEqual(e.readTruthStates()[consumer], 0,
                       "an UNDEFINED input contributes bit 0, so IDENTITY on it " +
                       "is false — 'treat UNDEFINED as 0 for LUT input'")
    }
}
