import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Follow-up items to per-rank dispatch.
///
/// First: a truth write (SET TRUTH, SET_TRUTH_BULK) does not change a rank,
/// so it must not mark the rank topology dirty: the next TICK rebuilds
/// nothing (`rankTopologyRebuildCount` unchanged) and still equals the colour
/// path. Every write that DOES change a rank still marks it (the next TICK
/// rebuilds once), and every write that changes an edge still drops the DAG
/// verdict — a list of mutating writes, one test each.
///
/// Second: a TICK whose per-rank list allocation fails is refused by name,
/// nothing ticked — never a fatalError.
final class EngineE3FDaemonTests: XCTestCase {

    typealias E1 = EngineE1DaemonTests
    typealias E3 = EngineE3DaemonTests

    private var tmp: String!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "engine-e3f-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmp { try? FileManager.default.removeItem(atPath: d) }
    }

    static let side = 16

    func fixture(seed: UInt64 = 0xE3F0, ternary: Bool = false, wal: DagDBWAL.Appender? = nil) throws -> HandlerFixture {
        let f = try HandlerFixture(side: Self.side, dataRoot: tmp, wal: wal)
        try E1.buildGraph(f.handler.engine, seed: seed, ternary: ternary)
        return f
    }

    /// A TICK on `fa` (the daemon's per-rank path) against `fb`'s engine
    /// ticked through the colour path with its topology forced dirty — a
    /// reference that does not depend on the invalidation under test.
    func tickAgainstReference(_ fa: HandlerFixture, _ fb: HandlerFixture, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let r = fa.handler.handle("TICK 1")
        XCTAssertTrue(r.hasPrefix("OK TICK 1 "), "\(label): \(r)", file: file, line: line)
        let b = fb.handler.engine
        b.markRankTopologyDirty()
        b.tick(tickNumber: UInt32(fb.handler.tickCount)); fb.handler.tickCount += 1
        XCTAssertEqual(fa.handler.engine.lastRankTickDispatchCount, E3.nonEmptyRanks(fa.handler.engine),
                       "\(label): one dispatch per rank", file: file, line: line)
        XCTAssertEqual(fa.handler.engine.readTruthStates(), b.readTruthStates(), "\(label): truth after TICK",
                       file: file, line: line)
    }

    func writeTruthBulk(_ f: HandlerFixture, _ rows: [(UInt32, UInt8)]) {
        f.shm.storeBytes(of: UInt32(rows.count), toByteOffset: 0, as: UInt32.self)
        f.shm.storeBytes(of: shm1Word1(.setTruthBulk), toByteOffset: 4, as: UInt32.self)
        for (i, (node, v)) in rows.enumerated() {
            f.shm.storeBytes(of: node, toByteOffset: 8 + 8 * i, as: UInt32.self)
            f.shm.storeBytes(of: UInt32(v), toByteOffset: 12 + 8 * i, as: UInt32.self)   // value u8, pad 0
        }
    }

    // MARK: - Truth writes rebuild nothing

    func testE3FTruthWritesDoNotRebuildTheRankTopology() throws {
        var cells = 0
        for ternary in [false, true] {
            let fa = try fixture(seed: 0xE3F1 &+ (ternary ? 1 : 0), ternary: ternary)
            let fb = try fixture(seed: 0xE3F1 &+ (ternary ? 1 : 0), ternary: ternary)
            let a = fa.handler.engine
            tickAgainstReference(fa, fb, "warm-up")
            XCTAssertFalse(a.rankTopologyDirty)
            let n = a.nodeCount
            for k in 0..<6 {
                let c0 = a.rankTopologyRebuildCount
                // A truth write that changes the node's byte (registers too).
                let node = (k * 37 + 11) % n
                let v: UInt8 = a.readTruthStates()[node] == 1 ? 0 : 1
                let cmd = "SET \(node) TRUTH \(v)"
                XCTAssertTrue(fa.handler.handle(cmd).hasPrefix("OK SET"), cmd)
                XCTAssertTrue(fb.handler.handle(cmd).hasPrefix("OK SET"), cmd)
                XCTAssertFalse(a.rankTopologyDirty, "ternary=\(ternary) \(cmd): a truth write is not a rank write")
                XCTAssertTrue(fa.handler.dagVerdict.checked, "SET TRUTH keeps the DAG verdict (unchanged)")
                tickAgainstReference(fa, fb, "ternary=\(ternary) after \(cmd)")
                XCTAssertEqual(a.rankTopologyRebuildCount, c0, "ternary=\(ternary) TICK after \(cmd) rebuilt the rank topology")

                let c1 = a.rankTopologyRebuildCount
                let rows: [(UInt32, UInt8)] = (0..<9).map { j in (UInt32((k * 53 + j * 29) % n), UInt8((j + k) % 2)) }
                writeTruthBulk(fa, rows); writeTruthBulk(fb, rows)
                let ra = fa.handler.handle("SET_TRUTH_BULK"), rb = fb.handler.handle("SET_TRUTH_BULK")
                XCTAssertEqual(ra, "OK SET_TRUTH_BULK nodes=9"); XCTAssertEqual(rb, ra)
                XCTAssertFalse(a.rankTopologyDirty, "ternary=\(ternary) SET_TRUTH_BULK: a truth write is not a rank write")
                tickAgainstReference(fa, fb, "ternary=\(ternary) after SET_TRUTH_BULK \(k)")
                XCTAssertEqual(a.rankTopologyRebuildCount, c1, "ternary=\(ternary) TICK after SET_TRUTH_BULK rebuilt the rank topology")
                cells += 2
            }
        }
        print("E3F item 1: \(cells) truth-write -> TICK cells, 0 rebuilds expected")
    }

    // MARK: - Every rank or edge write still invalidates

    /// Shift every rank up by one (rank order kept): the per-rank lists
    /// built before are wrong for every node afterwards.
    static func shiftRanks(_ e: DagDBEngine) {
        let r = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: e.nodeCount)
        for i in 0..<e.nodeCount { r[i] += 1 }
    }

    func source(seed: UInt64) throws -> DagDBEngine {
        let s = Self.side
        let e = try DagDBEngine(grid: try HexGrid(width: s, height: s), state: DagDBState(width: s, height: s), maxRank: 8)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        try E1.buildGraph(e, seed: seed, ternary: false)
        Self.shiftRanks(e)
        return e
    }

    /// Each rank writer: a command that leaves at least one rank different.
    func rankWriters() throws -> [(String, (HandlerFixture) throws -> String)] {
        let s = Self.side, n = s * s
        return [
            ("SET RANK", { _ in "SET \(n - 1) RANK 8" }),   // a top-rank node, raised: order kept
            ("SET_RANKS_BULK", { f in
                let r = f.handler.engine.readRanks()
                for i in 0..<n { f.shm.storeBytes(of: r[i] + 1, toByteOffset: 8 + 8 * i, as: UInt64.self) }
                shm1Header(f.shm, count: n, verb: .setRanksBulk)
                return "SET_RANKS_BULK"
            }),
            ("LOAD", { _ in
                let p = self.tmp + "src.dags"
                if !FileManager.default.fileExists(atPath: p) {
                    let e = try self.source(seed: 0xE3F5)
                    _ = try DagDBSnapshot.save(engine: e, nodeCount: n, gridW: s, gridH: s, tickCount: 3, path: p)
                }
                return "LOAD \(p)"
            }),
            ("IMPORT MORTON", { _ in
                let d = self.tmp + "src-morton"
                if !FileManager.default.fileExists(atPath: d) {
                    _ = try DagDBSnapshot.exportMorton(engine: try self.source(seed: 0xE3F6), nodeCount: n, dir: d)
                }
                return "IMPORT MORTON \(d)"
            }),
            ("LOAD JSON", { _ in
                let p = self.tmp + "src.json"
                if !FileManager.default.fileExists(atPath: p) {
                    _ = try DagDBJSONIO.saveJSON(engine: try self.source(seed: 0xE3F7), nodeCount: n,
                                                 gridW: s, gridH: s, tickCount: 3, path: p)
                }
                return "LOAD JSON \(p)"
            }),
            ("LOAD CSV", { _ in
                let d = self.tmp + "src-csv"
                if !FileManager.default.fileExists(atPath: d) {
                    _ = try DagDBJSONIO.saveCSV(engine: try self.source(seed: 0xE3F8), nodeCount: n, dir: d)
                }
                return "LOAD CSV \(d)"
            }),
            ("BACKUP RESTORE", { _ in
                let d = self.tmp + "src-backup"
                if !FileManager.default.fileExists(atPath: d) {
                    _ = try DagDBBackup.initializeChain(engine: try self.source(seed: 0xE3F9), nodeCount: n,
                                                        gridW: s, gridH: s, tickCount: 3, dir: d)
                }
                return "BACKUP RESTORE \(d)"
            }),
        ]
    }

    func testE3FEveryRankWriteStillRebuildsAtTheNextTick() throws {
        var verbs = 0
        for (name, make) in try rankWriters() {
            let fa = try fixture(), fb = try fixture()
            let a = fa.handler.engine
            tickAgainstReference(fa, fb, "\(name) warm-up")
            XCTAssertFalse(a.rankTopologyDirty)
            let ranksBefore = a.readRanks()
            let c0 = a.rankTopologyRebuildCount
            let cmdA = try make(fa), cmdB = try make(fb)
            let ra = fa.handler.handle(cmdA)
            XCTAssertTrue(ra.hasPrefix("OK"), "\(name): \(ra)")
            XCTAssertTrue(fb.handler.handle(cmdB).hasPrefix("OK"), name)
            XCTAssertNotEqual(a.readRanks(), ranksBefore, "\(name): the write must change a rank (not vacuous)")
            XCTAssertTrue(a.rankTopologyDirty, "\(name) must mark the rank topology dirty")
            XCTAssertFalse(fa.handler.dagVerdict.checked, "\(name) must drop the DAG verdict")
            tickAgainstReference(fa, fb, "after \(name)")
            XCTAssertEqual(a.rankTopologyRebuildCount, c0 + 1, "\(name): the next TICK rebuilds once")
            verbs += 1
        }
        XCTAssertEqual(verbs, 7)
        print("E3F item 1: \(verbs) rank writers, each rebuilt once at the next TICK and equal to the colour path")
    }

    func testE3FEveryEdgeWriteStillDropsTheDagVerdict() throws {
        let n = Self.side * Self.side
        let fa = try fixture(), fb = try fixture()
        let a = fa.handler.engine
        tickAgainstReference(fa, fb, "warm-up")
        let r = a.readRanks()
        // A legal CONNECT: a source strictly above a destination with a free slot.
        let nb = a.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: n * 6)
        var connect = ""
        search: for dst in 0..<n where !a.isRegister(node: UInt32(dst)) && (0..<6).contains(where: { nb[dst * 6 + $0] < 0 }) {
            for src in 0..<n where r[src] > r[dst] && !(0..<6).contains(where: { nb[dst * 6 + $0] == Int32(src) }) {
                connect = "CONNECT FROM \(src) TO \(dst)"; break search
            }
        }
        XCTAssertFalse(connect.isEmpty)
        for cmd in [connect, "CLEAR 40 EDGES"] {
            XCTAssertTrue(fa.handler.dagVerdict.checked)
            XCTAssertTrue(fa.handler.handle(cmd).hasPrefix("OK"), cmd)
            XCTAssertTrue(fb.handler.handle(cmd).hasPrefix("OK"), cmd)
            XCTAssertFalse(fa.handler.dagVerdict.checked, "\(cmd) must drop the DAG verdict")
            let c0 = a.rankTopologyRebuildCount
            tickAgainstReference(fa, fb, "after \(cmd)")
            XCTAssertEqual(a.rankTopologyRebuildCount, c0, "\(cmd): the lists hold ranks only; no rebuild is needed")
        }
        // SET_NEIGHBORS_BULK installing a same-rank edge: the verdict is
        // dropped, so the next TICK finds it and refuses.
        XCTAssertTrue(fa.handler.dagVerdict.checked)
        var v = [Int32](repeating: -1, count: n * 6)
        for i in 0..<(n * 6) { v[i] = nb[i] }
        let same = (1..<n).first { r[$0] == r[0] }!
        v[0 * 6 + 5] = Int32(same)
        for (i, x) in v.enumerated() { fa.shm.storeBytes(of: x, toByteOffset: 8 + 4 * i, as: Int32.self) }
        shm1Header(fa.shm, count: n, verb: .setNeighborsBulk)
        XCTAssertTrue(fa.handler.handle("SET_NEIGHBORS_BULK").hasPrefix("OK SET_NEIGHBORS_BULK"))
        XCTAssertFalse(fa.handler.dagVerdict.checked, "SET_NEIGHBORS_BULK must drop the DAG verdict")
        let t = fa.handler.handle("TICK 1")
        XCTAssertTrue(t.hasPrefix("ERROR invalid_graph: rank-mode TICK refused"), t)
    }

    /// WAL replay: an engine that has ticked (topology clean, lists built)
    /// and then replays a log carrying a rank write is marked dirty.
    func testE3FWalReplayStillMarksTheRankTopologyDirty() throws {
        let s = Self.side, n = s * s
        let walPath = tmp + "live.wal"
        let f = try HandlerFixture(side: s, dataRoot: tmp, wal: try DagDBWAL.Appender(path: walPath, nodeCount: n))
        XCTAssertTrue(f.handler.handle("SET 7 RANK 3").hasPrefix("OK"))
        XCTAssertTrue(f.handler.handle("SET 5 TRUTH 1").hasPrefix("OK"))
        f.handler.walAppender?.barrier()
        let fresh = try HandlerFixture(side: s).handler.engine
        fresh.tick(tickNumber: 0, rankOrderVerified: true)
        XCTAssertFalse(fresh.rankTopologyDirty)
        let c0 = fresh.rankTopologyRebuildCount
        _ = try DagDBStartup.recover(engine: fresh, nodeCount: n, width: s, height: s, dagdbEnv: nil, dataRoot: tmp,
                                     twin: TwinState(), truthRankIndex: TruthRankIndex(), snapshotPath: nil,
                                     walPath: walPath, log: { _ in })
        XCTAssertEqual(fresh.readRanks()[7], 3)
        XCTAssertTrue(fresh.rankTopologyDirty, "WAL replay must mark the rank topology dirty")
        fresh.tick(tickNumber: 1, rankOrderVerified: true)
        XCTAssertEqual(fresh.rankTopologyRebuildCount, c0 + 1)
    }

    // MARK: - An allocation failure refuses the TICK by name

    func testE3FRankListAllocationFailureRefusesTheTickByName() throws {
        let fa = try fixture(seed: 0xE3F2), fb = try fixture(seed: 0xE3F2)
        let a = fa.handler.engine
        XCTAssertEqual(a.allocationBytes().first { $0.name == "rankList" }?.bytes, 0, "no lists before the first per-rank tick")
        a.rankListAllocationFailsForTesting = true
        let before = a.readTruthStates()
        let n = a.nodeCount
        let want = "ERROR resource: rank-mode TICK refused: rank lists: buffer allocation failed "
            + "(\(4 * n) bytes for \(n) nodes); nothing ticked"
        for cmd in ["TICK 1", "TICK 3", "TICK UNTIL_STABLE MAX 5"] {
            let r = fa.handler.handle(cmd)
            XCTAssertEqual(r, want, cmd)
            XCTAssertEqual(fa.handler.tickCount, 0, "\(cmd): tick count unchanged")
            XCTAssertEqual(a.lastRankTickDispatchCount, 0, "\(cmd): nothing dispatched")
            XCTAssertEqual(a.readTruthStates(), before, "\(cmd): truth unchanged")
        }
        // TICK_SYNC and EVAL do not use the lists: unaffected.
        XCTAssertTrue(fa.handler.handle("TICK_SYNC 1").hasPrefix("OK TICK_SYNC 1 "))
        XCTAssertTrue(fb.handler.handle("TICK_SYNC 1").hasPrefix("OK TICK_SYNC 1 "))
        XCTAssertTrue(fa.handler.handle("EVAL").hasPrefix("OK EVAL"))
        XCTAssertTrue(fb.handler.handle("EVAL").hasPrefix("OK EVAL"))
        XCTAssertEqual(a.readTruthStates(), fb.handler.engine.readTruthStates())
        // A library caller that ticks with `rankOrderVerified: true` anyway
        // gets the colour path (exact on any graph), never a crash.
        let segments = E3.nonEmptySegments(a)
        a.tick(tickNumber: 7, rankOrderVerified: true)
        fb.handler.engine.tick(tickNumber: 7)
        XCTAssertEqual(a.lastRankTickDispatchCount, segments, "fallback: the colour path")
        XCTAssertEqual(a.readTruthStates(), fb.handler.engine.readTruthStates())
        // The allocation succeeds again: TICK runs, per rank.
        a.rankListAllocationFailsForTesting = false
        fb.handler.tickCount = fa.handler.tickCount
        tickAgainstReference(fa, fb, "after the allocation recovers")
        XCTAssertEqual(a.allocationBytes().first { $0.name == "rankList" }?.bytes, 4 * n)
    }
}
