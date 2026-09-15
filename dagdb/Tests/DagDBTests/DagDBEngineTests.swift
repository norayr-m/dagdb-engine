import XCTest
@testable import DagDB

/// `DagDBEngine.init` — AMENDMENT 1 item 4
/// (`docs/contracts/TILING_GATES_FROZEN.md`, T-S2 finding): a small
/// `HexGrid(width: n, height: 1)` can leave one of the 7 Morton-colour
/// buckets empty, and `device.makeBuffer(length: 0, ...)` returns `nil`,
/// failing the whole init. The fix allocates at least one element per
/// colour-group buffer while keeping `groupSizes` (and therefore tick
/// dispatch) reporting the true — possibly zero — count.
final class DagDBEngineTests: XCTestCase {

    func testEngineAllocatesForTinyGrids() throws {
        for width in 1...10 {
            let grid = try HexGrid(width: width, height: 1)
            let state = DagDBState(width: width, height: 1)
            let engine = try DagDBEngine(grid: grid, state: state, maxRank: 64)
            XCTAssertEqual(engine.nodeCount, width, "width=\(width)")
            let emptyGroups = engine.colorGroupSizes.filter { $0 == 0 }.count
            print("testEngineAllocatesForTinyGrids: width=\(width) nodeCount=\(engine.nodeCount) emptyColorGroups=\(emptyGroups)")
        }
    }
}
