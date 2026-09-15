import XCTest
@testable import DagDB

/// C9 · `exportNeighborTable` refuses a node with more than six edges by
/// name — `docs/contracts/CORE_DURABILITY_GATES_FROZEN.md`.
final class CoreDurabilityGraphExportTests: XCTestCase {

    /// `connect` guards the six-slot bound and `validate` reports it, but the
    /// exporter — the path the engine's convenience init actually uses, and
    /// which never calls `validate` — wrote `nb[idx * 6 + dir]` for every
    /// entry and spilled into the next node's slots (audit A, finding 44).
    func testExportNeighborTableRefusesASeventhEdge() throws {
        let g = DagDBGraph()
        for k in 0..<8 {
            _ = g.addLeaf(label: "src\(k)", rank: 2, truth: false)
        }
        let dst = g.addLeaf(label: "dst", rank: 0, truth: false)
        g.setEdgesUnchecked(node: dst, edges: Array(0..<7))

        XCTAssertThrowsError(try g.exportNeighborTable(nodeCount: 16)) { err in
            let s = "\(err)"
            XCTAssertTrue(s.contains("\(dst)"), s)
            XCTAssertTrue(s.contains("7"), s)
        }
        // The state exporter writes per-edge too, and refuses the same shape.
        XCTAssertThrowsError(try g.exportState(grid: HexGrid(width: 4, height: 4)))
    }

    func testSixEdgesStillExport() throws {
        let g = DagDBGraph()
        for k in 0..<6 { _ = g.addLeaf(label: "s\(k)", rank: 2, truth: false) }
        let dst = g.addLeaf(label: "dst", rank: 0, truth: false)
        for k in 0..<6 { try g.connect(from: k, to: dst) }
        let nb = try g.exportNeighborTable(nodeCount: 16)
        XCTAssertEqual(nb.count, 16 * 6)
        XCTAssertEqual(Array(nb[dst * 6 ..< dst * 6 + 6]).map { Int($0) }, Array(0..<6))
        // And the neighbouring node's slots are untouched.
        XCTAssertEqual(Array(nb[(dst + 1) * 6 ..< (dst + 1) * 6 + 6]),
                       [Int32](repeating: -1, count: 6))
    }
}
