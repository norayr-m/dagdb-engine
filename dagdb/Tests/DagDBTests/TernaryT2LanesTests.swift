import XCTest
@testable import DagDB

/// Ternary state and engine lanes.
/// The four lanes and the library travel from `DagDBState` into the engine's
/// buffers, read back, refuse what the ternary lane rules refuse,
/// and are copied whole into reader sessions (ten lanes → fourteen, plus the
/// library).
final class TernaryT2LanesTests: XCTestCase {

    private func state(side: Int) -> DagDBState {
        var st = DagDBState(width: side, height: side)
        let n = st.nodeCount
        for i in 0..<n {
            st.nodeMode[i] = [0, 1, 2, 5, 6][i % 5]
            st.ttableId[i] = UInt16(i % 3)
            st.thrLo[i] = Float(i % 7) * -0.5
            st.thrHi[i] = Float(i % 5) * 0.25
            st.truthState[i] = UInt8(i % 3)
        }
        st.ttables = (0..<(3 * 729)).map { UInt8($0 % 3) }
        return st
    }

    func testLanesUploadAndReadBack() throws {
        let side = 8
        let st = state(side: side)
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side), state: st)
        let n = e.nodeCount
        for i in 0..<n {
            XCTAssertEqual(e.modePtr[i], st.nodeMode[i])
            XCTAssertEqual(e.ttableIdPtr[i], st.ttableId[i])
            XCTAssertEqual(e.thrLoPtr[i].bitPattern, st.thrLo[i].bitPattern)
            XCTAssertEqual(e.thrHiPtr[i].bitPattern, st.thrHi[i].bitPattern)
        }
        XCTAssertEqual(e.ttableCount, 3)
        XCTAssertEqual(e.libraryBytes(), st.ttables)
        XCTAssertEqual(e.tableBytes(1), Array(st.ttables[729..<1458]))
        XCTAssertNil(e.tableBytes(3))
        XCTAssertEqual(e.ternaryNodeCount(), (0..<n).filter { st.nodeMode[$0] != 0 }.count)
        XCTAssertEqual(e.firstNonBinaryNode(), 1)
        XCTAssertNil(e.ternaryStateViolation())
    }

    func testDefaultsAreBinaryAndEmpty() throws {
        let e = try DagDBEngine(grid: try HexGrid(width: 4, height: 4), state: DagDBState(width: 4, height: 4))
        XCTAssertEqual(e.ttableCount, 0)
        XCTAssertEqual(e.libraryBytes(), [])
        XCTAssertNil(e.firstNonBinaryNode())
        XCTAssertNil(e.ternaryStateViolation())
    }

    func testLibraryWritesAreDenseAndRefusedByName() throws {
        let e = try DagDBEngine(grid: try HexGrid(width: 4, height: 4), state: DagDBState(width: 4, height: 4))
        let t = [UInt8](repeating: 1, count: 729)
        // A gap is refused; appending at the end is not.
        XCTAssertThrowsError(try e.writeTables(first: 1, bytes: t)) {
            XCTAssertTrue("\($0)".contains("leaves a gap"), "\($0)")
        }
        try e.writeTables(first: 0, bytes: t)
        XCTAssertEqual(e.ttableCount, 1)
        // Growth past the initial capacity keeps every table (doubling).
        for k in 1..<40 { try e.writeTables(first: k, bytes: [UInt8](repeating: UInt8(k % 3), count: 729)) }
        XCTAssertEqual(e.ttableCount, 40)
        for k in 1..<40 { XCTAssertEqual(e.tableBytes(k), [UInt8](repeating: UInt8(k % 3), count: 729)) }
        XCTAssertEqual(e.tableBytes(0), t)
        // Overwrite in place.
        try e.writeTables(first: 0, bytes: [UInt8](repeating: 0, count: 729))
        XCTAssertEqual(e.tableBytes(0), [UInt8](repeating: 0, count: 729))
        XCTAssertEqual(e.ttableCount, 40)
        // A table byte ≥ 3 is refused, nothing written.
        var bad = t; bad[100] = 3
        XCTAssertThrowsError(try e.writeTables(first: 40, bytes: bad)) {
            XCTAssertTrue("\($0)".contains("byte 100 is 3"), "\($0)")
        }
        XCTAssertEqual(e.ttableCount, 40)
        // Past 65,536 tables is refused.
        let probe = [UInt8](repeating: 2, count: 729)
        probe.withUnsafeBufferPointer { b in
            XCTAssertNotNil(e.tableWriteRefusal(first: 40, count: TernaryReference.maxTables - 39, bytes: b))
        }
        // replaceLibrary refuses a ragged library by name.
        XCTAssertThrowsError(try e.replaceLibrary([1, 2]))
        try e.replaceLibrary([])
        XCTAssertEqual(e.ttableCount, 0)
    }

    func testEngineInitRefusesABadLibrary() throws {
        var st = DagDBState(width: 4, height: 4)
        st.ttables = [UInt8](repeating: 2, count: 728)
        XCTAssertThrowsError(try DagDBEngine(grid: try HexGrid(width: 4, height: 4), state: st))
        st.ttables = [UInt8](repeating: 7, count: 729)
        XCTAssertThrowsError(try DagDBEngine(grid: try HexGrid(width: 4, height: 4), state: st))
    }

    func testStateViolationNamesEveryRule() throws {
        let side = 4
        func engine(_ edit: (inout DagDBState) -> Void) throws -> DagDBEngine {
            var st = DagDBState(width: side, height: side)
            st.ttables = [UInt8](repeating: 2, count: 729)
            edit(&st)
            return try DagDBEngine(grid: try HexGrid(width: side, height: side), state: st)
        }
        let cases: [(String, (inout DagDBState) -> Void)] = [
            ("reserved bits", { $0.nodeMode[3] = 0x08 }),
            ("kind 3", { $0.nodeMode[3] = 3 }),
            ("NOSKIP on a BINARY node", { $0.nodeMode[3] = 4 }),
            ("not below the library size", { $0.nodeMode[3] = 1; $0.ttableId[3] = 1 }),
            ("> hi", { $0.thrLo[3] = 2; $0.thrHi[3] = 1 }),
            ("not finite", { $0.thrLo[3] = .nan }),
            ("not finite", { $0.thrHi[3] = .infinity }),
            ("truth byte 7 on a ternary node", { $0.nodeMode[3] = 2; $0.truthState[3] = 7 }),
        ]
        for (needle, edit) in cases {
            let e = try engine(edit)
            let v = e.ternaryStateViolation()
            XCTAssertNotNil(v, needle)
            XCTAssertTrue(v?.contains(needle) == true, "\(needle): \(v ?? "nil")")
            XCTAssertTrue(v?.contains("node 3") == true, "\(v ?? "nil")")
        }
        // A ternary register.
        let e = try engine { $0.nodeMode[5] = 1 }
        XCTAssertNil(e.ternaryStateViolation())
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for d in 0..<6 { nb[5 * 6 + d] = -1 }   // a register has no combinational input
        try e.registerValidatedBackEdge(src: 2, dst: 5)
        XCTAssertTrue(e.ternaryStateViolation()?.contains("register") == true)
    }

    func testReaderSessionCopiesFourteenLanesAndTheLibrary() throws {
        let side = 8
        let grid = try HexGrid(width: side, height: side)
        let st = state(side: side)
        let primary = try DagDBEngine(grid: grid, state: st)
        let mgr = DagDBReaderSessionManager()
        let session = try mgr.open(primary: primary, grid: grid,
                                   stateTemplate: DagDBState(width: side, height: side),
                                   maxRank: 16, tickCount: 0)
        let snap = session.snapshotEngine
        let n = primary.nodeCount
        for i in 0..<n {
            XCTAssertEqual(snap.modePtr[i], primary.modePtr[i])
            XCTAssertEqual(snap.ttableIdPtr[i], primary.ttableIdPtr[i])
            XCTAssertEqual(snap.thrLoPtr[i].bitPattern, primary.thrLoPtr[i].bitPattern)
            XCTAssertEqual(snap.thrHiPtr[i].bitPattern, primary.thrHiPtr[i].bitPattern)
        }
        XCTAssertEqual(snap.libraryBytes(), primary.libraryBytes())
        // Isolation: a later write to the primary does not reach the session.
        primary.modePtr[0] = 2
        try primary.writeTables(first: 3, bytes: [UInt8](repeating: 0, count: 729))
        XCTAssertEqual(snap.modePtr[0], st.nodeMode[0])
        XCTAssertEqual(snap.ttableCount, 3)
    }
}
