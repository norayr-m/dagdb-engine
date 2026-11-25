/// In process: the count caps, the committed-bytes ledger's refusal, the reader's back-edge copy, the
/// back-edge bytes, and CLOCK ADVANCE's work unit, the table library, TILED OPEN's decode charge by tokens
/// and its manifest read and resident fields, each refused by name with its numbers and nothing written.
/// The wire checks (red on main, with controls) and the ratio table run on sandbox daemons.
import XCTest
import Foundation
@testable import DagDB
@testable import DagDBDaemonKit

final class EngineALLOC1bTests: XCTestCase {

    func budget(_ f: HandlerFixture, bytes: Int, footprint: Int, fixed: Int = 0) {
        f.handler.memoryBudget = DaemonMemoryBudget(budgetBytes: bytes, source: "--mem-budget-gb", footprint: { footprint },
                                                    fixedStateBytes: fixed)
    }

    // MARK: - Count caps

    func testTwinKindCaps() throws {
        let f = try HandlerFixture(side: 4)
        for _ in 0..<1024 { XCTAssertTrue(f.handler.handle("STREAM OPEN s 0x1 0x2 0x3 0x5").hasPrefix("OK STREAM OPEN")) }
        XCTAssertEqual(f.handler.handle("STREAM OPEN s 0x1 0x2 0x3 0x5"),
                       "ERROR out_of_budget: STREAM OPEN needs 1025 open streams, the streams cap is 1024; nothing written")
        XCTAssertEqual(f.handler.twin.streams.openCount, 1024)
        for _ in 0..<1024 { XCTAssertTrue(f.handler.handle("CLOCK OPEN").hasPrefix("OK CLOCK OPEN")) }
        XCTAssertEqual(f.handler.handle("CLOCK OPEN"),
                       "ERROR out_of_budget: CLOCK OPEN needs 1025 open clocks, the clocks cap is 1024; nothing written")
        for _ in 0..<1024 { XCTAssertTrue(f.handler.handle("RINGS OPEN").hasPrefix("OK RINGS OPEN")) }
        XCTAssertEqual(f.handler.handle("RINGS OPEN"),
                       "ERROR out_of_budget: RINGS OPEN needs 1025 open rings, the rings cap is 1024; nothing written")
        for _ in 0..<1024 { XCTAssertTrue(f.handler.handle("BUDGET SEALED").hasPrefix("OK BUDGET SEALED")) }
        XCTAssertEqual(f.handler.handle("BUDGET SEALED"),
                       "ERROR out_of_budget: BUDGET SEALED needs 1025 open budget layouts, the budget layouts cap is 1024; nothing written")
        // A close gives the slot back.
        XCTAssertTrue(f.handler.handle("RINGS CLOSE n00000001").hasPrefix("OK RINGS CLOSE"))
        XCTAssertTrue(f.handler.handle("RINGS OPEN").hasPrefix("OK RINGS OPEN id=n00000401"))
        // Every kind has its cap; a fresh handler is under every one.
        let g = try HandlerFixture(side: 4)
        for p: Character in ["s", "t", "n", "c", "g", "b", "a", "w", "v", "k", "h"] {
            XCTAssertNil(g.handler.alloc1bTwinCap("OPEN", prefix: p))
        }
        XCTAssertEqual(DagDBCommandHandler.alloc1bTwinKindCap, 1024)
        XCTAssertEqual(DagDBCommandHandler.alloc1bTiledRouterCap, 16)
    }

    func testSlicesPerRecordCap() throws {
        let f = try HandlerFixture(side: 4)
        let rec = "RECORD OPEN court 1500 0.6827 3000 1.0 0.6827 0.00001 0 0x853c49e6748fea9b 0xda3e39cb94b95bdb 0x5851f42d4c957f2d 0x14057b7ef767814f"
        XCTAssertTrue(f.handler.handle(rec).hasPrefix("OK RECORD OPEN id=t00000001"))
        for _ in 0..<4096 { XCTAssertTrue(f.handler.handle("RECORD SLICE t00000001 1").hasPrefix("OK RECORD SLICE")) }
        XCTAssertEqual(f.handler.handle("RECORD SLICE t00000001 1"),
                       "ERROR out_of_budget: RECORD SLICE needs 4097 slices on t00000001, the per-record slice cap is 4096; nothing written")
        XCTAssertTrue(f.handler.handle("RECORD INFO t00000001").contains(" slices=4096 "))
    }

    // MARK: - The committed-bytes ledger

    func testLedgerRefusesWhereTheFootprintDoesNot() throws {
        let f = try HandlerFixture(side: 4)
        // The footprint reads 0 throughout (as an untouched ring set would); each 16 x 4,096 ring set is
        // admitted at 1.1 * (1.414 * 32 * 16 * 4096 + 1024) = 3,263,036.62 -> 3,263,037 bytes.
        budget(f, bytes: 10_000_000, footprint: 0)
        for _ in 0..<3 { XCTAssertTrue(f.handler.handle("RINGS OPEN 2 16 4096").hasPrefix("OK RINGS OPEN")) }
        // The ledger: the three ring sets, 3 * 3,263,036.62 B, plus the registry dictionary's spare buckets.
        let refusal = f.handler.handle("RINGS OPEN 2 16 4096")
        let head = "ERROR out_of_budget: RINGS OPEN needs 3263037 bytes (a ring set, 1.1*(1.414*32*r*c + 1 KB)), the budget is"
            + " 10000000 (committed "
        XCTAssertTrue(refusal.hasPrefix(head) && refusal.hasSuffix("); nothing written footprint=0"), refusal)
        let committed = Int(refusal.dropFirst(head.count).prefix { $0.isNumber }) ?? 0
        XCTAssertGreaterThanOrEqual(committed, 9_789_110)
        XCTAssertTrue(refusal.contains(": fixed state 0 + ledger \(committed)); nothing written"), refusal)
        XCTAssertEqual(f.handler.twin.rings.openCount, 3)
        // A close gives its bytes back.
        XCTAssertTrue(f.handler.handle("RINGS CLOSE n00000001").hasPrefix("OK RINGS CLOSE"))
        XCTAssertTrue(f.handler.handle("RINGS OPEN 2 16 4096").hasPrefix("OK RINGS OPEN"))
        // The fixed state counts: 5,000,000 + 3,263,037 fits once, not twice.
        let g = try HandlerFixture(side: 4)
        budget(g, bytes: 10_000_000, footprint: 0, fixed: 5_000_000)
        XCTAssertTrue(g.handler.handle("RINGS OPEN 2 16 4096").hasPrefix("OK RINGS OPEN"))
        XCTAssertTrue(g.handler.handle("RINGS OPEN 2 16 4096").hasPrefix("ERROR out_of_budget: RINGS OPEN needs 3263037 bytes"))
        // The daemon's own budget carries the fixed-state formula.
        // And the Metal pool's reservation beside it.
        XCTAssertEqual(DaemonMemoryBudget.make(nodeCount: 65_536, overrideGiB: nil).nodeFixedStateBytes,
                       DaemonMemoryBudget.fixedStateBytes(nodeCount: 65_536))
        XCTAssertEqual(DaemonMemoryBudget.make(nodeCount: 65_536, overrideGiB: nil).fixedStateBytes,
                       DaemonMemoryBudget.fixedStateBytes(nodeCount: 65_536) + AdmissionCharge.metalPoolReservationBytes)
    }

    // MARK: - The reader's back-edge copy and the back edges' bytes

    func testReaderAdmitsItsBackEdgeCopy() throws {
        let f = try HandlerFixture(side: 4)
        for (s, d) in [(1, 2), (3, 4), (5, 6)] {
            XCTAssertTrue(f.handler.handle("CONNECT BACK FROM \(s) TO \(d)").hasPrefix("OK CONNECT BACK"))
        }
        budget(f, bytes: 100_000, footprint: 0)
        // (77 + 59) * 16 + 118,000 + ceil(1.1 * 16 * 3) = 120,229 bytes.
        XCTAssertEqual(f.handler.handle("OPEN_READER"),
                       "ERROR out_of_budget: OPEN_READER needs 120229 bytes (a session's buffers and its state template,"
                       + " (77 + 59)*N + 118 KB + 1.1*16*M for M=3 back edges), the budget is 100000; nothing written footprint=0")
        XCTAssertEqual(f.handler.sessionManager.openCount, 0)
    }

    func testBackEdgeBytes() throws {
        let f = try HandlerFixture(side: 4)
        // The first edge on a binary graph: 1.1 * 8, the lists' first buffers 1.1 * 16, the ternary lanes
        // 1.1 * 11 * 16: 220 B, admitted at the floor of two 16 KiB pages, 32,768 bytes.
        budget(f, bytes: 40_000, footprint: 8_000)
        XCTAssertEqual(f.handler.handle("CONNECT BACK FROM 1 TO 2"),
                       "ERROR out_of_budget: CONNECT BACK needs 32768 bytes (the new back edges, 1.1*8 B each for 1, the lists'"
                       + " new buffers as they grow, 1.1*16 B per edge, and the ternary lanes, 1.1*11 B per node), the budget is"
                       + " 40000; nothing written footprint=8000")
        XCTAssertNil(f.handler.engine.ternaryLaneView)   // admitted before the rule check that allocates them
        XCTAssertEqual(f.handler.engine.backEdgeSrcs.count, 0)
        budget(f, bytes: 40_000, footprint: 0)
        XCTAssertTrue(f.handler.handle("CONNECT BACK FROM 1 TO 2").hasPrefix("OK CONNECT BACK"))
        XCTAssertGreaterThanOrEqual(f.handler.committedLedgerBytes(), 9)
    }

    // MARK: - CLOCK ADVANCE (Amendments 1 and 3)

    func testClockAdvanceWorkUnit() throws {
        let dir = NSTemporaryDirectory() + "alloc1b_clock_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try writeSyntheticAlarmFixture(in: dir)
        let f = try HandlerFixture(side: 4)
        XCTAssertTrue(f.handler.handle("ALARM LOAD \(path)").hasPrefix("OK ALARM LOAD id=a00000001"))
        XCTAssertTrue(f.handler.handle("CLOCK OPEN").hasPrefix("OK CLOCK OPEN id=c00000001"))
        // 100 hooks bound to the clock, none done for 10^9 frames, empty ledgers: per hook
        // 10000*688 + 13.78*(10000*9999/2) ns; with the floor 10000*87.7: 69,581,987,000 ns > 60 s.
        for _ in 0..<100 {
            XCTAssertTrue(f.handler.handle("HOOK OPEN a00000001 SEALED 100000 DELTA 1000000000 CLOCK c00000001").hasPrefix("OK HOOK OPEN"))
        }
        XCTAssertEqual(f.handler.handle("CLOCK ADVANCE c00000001 10000"),
                       "ERROR out_of_budget: CLOCK ADVANCE needs 69581987000 CLOCK ADVANCE work ns (n*87.7 + n*G*70.2 + per bound"
                       + " hook s*688 + (n-s)*185 + 13.78*(s*L + s(s-1)/2)), the per-command work cap is 60000000000; nothing written")
        XCTAssertTrue(f.handler.handle("CLOCK STATE c00000001").contains(" tick=0 "))
        // Fewer ticks pass, and the bound hooks' rows enter the ledger by their arrays' capacity, 1.1 * stride each.
        let before = f.handler.committedLedgerBytes()
        XCTAssertTrue(f.handler.handle("CLOCK ADVANCE c00000001 10").hasPrefix("OK CLOCK ADVANCE"))
        let stride = Double(MemoryLayout<AttentionHook.Row>.stride)
        let capacity = f.handler.twin.hooks.entries.values.reduce(0) { $0 + $1.hook.ledger.capacity }
        XCTAssertGreaterThanOrEqual(capacity, 1000)
        XCTAssertEqual(Double(f.handler.committedLedgerBytes() - before), 1.1 * stride * Double(capacity), accuracy: 2)
    }

    // MARK: - The ternary table library

    func testTableLibraryGrowthIsAdmitted() throws {
        let f = try HandlerFixture(side: 8)    // 64 nodes: a 1,544 B shm holds two 729 B tables
        XCTAssertEqual(f.handler.engine.ttableCapacity, 1)
        // Two tables outgrow the one-table buffer: a capacity of 2, 1.1 * 729 * 2 = 1,603.8 B, at the two-page floor.
        let n = 2, bytes = n * TernaryReference.tableSize
        shm1Header(f.shm, count: n, verb: .ttableBulk)
        f.shm.advanced(by: 8).initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        budget(f, bytes: 30_000, footprint: 0)
        XCTAssertEqual(f.handler.handle("TTABLE_BULK 0 2"),
                       "ERROR out_of_budget: TTABLE_BULK needs 32768 bytes (the table library's new buffer, 1.1*729 B per table"
                       + " for a capacity of 2), the budget is 30000; nothing written footprint=0")
        XCTAssertEqual(f.handler.engine.ttableCount, 0)
        XCTAssertEqual(f.handler.engine.ttableCapacity, 1)
        budget(f, bytes: 40_000, footprint: 0)
        shm1Header(f.shm, count: n, verb: .ttableBulk)
        XCTAssertTrue(f.handler.handle("TTABLE_BULK 0 2").hasPrefix("OK TTABLE_BULK first=0 count=2 tables=2"))
        // The ledger counts the library's capacity.
        let before = f.handler.committedLedgerBytes()
        XCTAssertGreaterThanOrEqual(Double(before), 1.1 * 729 * 2)
        XCTAssertEqual(DagDBCommandHandler.libraryCapacity(from: 2, for: 3), 4)
        XCTAssertEqual(DagDBCommandHandler.libraryCapacity(from: 1, for: 65_536), 65_536)
    }

    // MARK: - TILED OPEN's manifest (Amendments 6 and 8)

    func testManifestDecodeIsChargedByTokens() throws {
        let root = NSTemporaryDirectory() + "alloc1b_a6_\(UUID().uuidString)"
        let dir = root + "/world"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        // , : [ { : 2 + 2 + 1 + 2 = 7 bytes, plus 1; 18 bytes.
        let text = #"{"a":[1,2],"b":{}}"#
        try text.write(toFile: dir + "/manifest.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(DagDBCommandHandler.alloc1bTokenCount(Data(text.utf8)), 8)
        let f = try HandlerFixture(side: 4)
        // The read is admitted first, 1.1 * 2.52 * 18 = 49.9 B, at the two-page floor.
        budget(f, bytes: 30_000, footprint: 0)
        XCTAssertEqual(f.handler.handle("TILED OPEN \(dir) 1"),
                       "ERROR out_of_budget: TILED OPEN needs 32768 bytes (the manifest's read, 1.1*2.52 B per byte for 18 B),"
                       + " the budget is 30000; nothing written footprint=0")
        XCTAssertEqual(f.handler.tiledOpenRefusedCount, 0)
        // Within the budget the one decode runs and refuses the file by name, as the router's own read did.
        budget(f, bytes: 40_000, footprint: 0)
        XCTAssertTrue(f.handler.handle("TILED OPEN \(dir) 1").hasPrefix("ERROR io: TiledGraphFiles: manifest decode failed"))
        XCTAssertEqual(f.handler.tiledOpenRefusedCount, 1)
        XCTAssertEqual(f.handler.tiledRouters.count, 0)
    }

    /// A FIFO, a link to /dev/zero and a directory at the manifest's path are refused at once
    /// (by name), and nothing but tiled_refused changes.
    func testManifestNotARegularFileIsRefusedAsMainDoes() throws {
        let root = NSTemporaryDirectory() + "alloc1b_a8_\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let f = try HandlerFixture(side: 4)
        budget(f, bytes: 1 << 30, footprint: 0)
        for (i, kind) in ["fifo", "devzero", "dir"].enumerated() {
            let dir = root + "/w\(i)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = dir + "/manifest.json"
            switch kind {
            case "fifo": XCTAssertEqual(mkfifo(path, 0o600), 0)
            case "devzero": try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "/dev/zero")
            default: try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            // Refused by name, an errno name and the quoted path, in place of the older "not found"
            // (the refusal names what the file is).
            let named = ["fifo": "EFTYPE (errno 79) path=\"\(path)\": a fifo, not a regular file",
                         "devzero": "EFTYPE (errno 79) path=\"\(path)\": a character device, not a regular file",
                         "dir": "EISDIR (errno 21) path=\"\(path)\": a directory, not a regular file"][kind]!
            XCTAssertEqual(f.handler.handle("TILED OPEN \(dir) 1"),
                           "ERROR io: TiledGraphRouter: \(named)", kind)
            XCTAssertEqual(f.handler.tiledOpenRefusedCount, i + 1)
        }
        XCTAssertEqual(f.handler.tiledRouters.count, 0)
    }

    /// The resident charge counts every field the router keeps, refused by name with them.
    func testRouterResidentCountsEveryField() throws {
        let root = NSTemporaryDirectory() + "alloc1b_a8r_\(UUID().uuidString)"
        let dir = root + "/w"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try (#"{"boundaries":[1,2],"format":"dagdb-tiled-manifest","globalNodeCount":4,"name":"w","tiles":[{"bodySHA256":"","#
             + #""crossingsIn":[],"crossingsOut":[],"engineIndexOf":[0,1,2,3],"id":0,"nodeCount":4,"rankHi":1,"rankLo":0,"#
             + #""tickEpoch":0}],"version":1}"#).write(toFile: dir + "/manifest.json", atomically: true, encoding: .utf8)
        let f = try HandlerFixture(side: 4)
        // 1.1*(13.8*4) + 1.1*(244*1 + 18.2*2 + 18.2*4 + 64*3 + 1.51*21) + 2*1.1*(128*4 + 943,718) = 2,078,001.3 B.
        budget(f, bytes: 1_000_000, footprint: 0)
        XCTAssertEqual(f.handler.handle("TILED OPEN \(dir) 1"),
                       "ERROR out_of_budget: TILED OPEN needs 2078002 bytes (the router's steady state, 1.1*(13.8 B per global"
                       + " node + 95.2 B per crossingsIn entry + 51.0 B per crossingsOut entry + 244.0 B per tile + 18.2 B per"
                       + " boundary + 18.2 B per engineIndexOf entry + 64.0 B per string + 1.51 B per string byte) for 4 nodes,"
                       + " 0 + 0 crossings, 1 tiles, 2 boundaries, 4 entries and 3 strings of 21 B, and 2 tile engines of 4"
                       + " nodes with ghosts, 1.1*(128 B per node + 0.9 MiB) each), the budget is 1000000;"
                       + " nothing written footprint=0")
        XCTAssertEqual(f.handler.tiledRouters.count, 0)
    }

    /// The synthetic five-record alarm fixture (EngineALLOC1aTests' helper, copied).
    func writeSyntheticAlarmFixture(in dir: String) throws -> String {
        func wave(_ base: Float) -> [Float] { [base, base + 1, base + 2, base + 3] }
        func entry(_ cls: String, _ base: Float, ear: String? = nil) -> [String: Any] {
            var e: [String: Any] = ["class": cls, "a": wave(base), "b": wave(base + 10), "c": wave(base + 20)]
            if let ear = ear { e["liar_ear"] = ear }
            return e
        }
        let obj: [String: Any] = [
            "quiet_1": entry("quiet", 0), "quiet_2": entry("quiet", 100), "liar_1": entry("liar", 200, ear: "B"),
            "deep_1": entry("deep", 300), "drift_1": entry("drift", 400), "cal0_1": entry("cal0", 500),
        ]
        let path = dir + "mini.json"
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: path))
        return path
    }
}
