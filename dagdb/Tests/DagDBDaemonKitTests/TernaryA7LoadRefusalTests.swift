import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Load and restore paths refuse non-finite values.
///
/// Every load and restore path refuses a non-finite node value or
/// edge weight by name — node, slot where relevant, value and bits — before
/// any buffer is written, so a state that LOADs can also SAVE. The paths, as
/// the daemon runs them: LOAD of a `.dags` file (v7 and v8, plain and zlib),
/// LOAD JSON, LOAD CSV, IMPORT MORTON, BACKUP RESTORE (a poisoned base, a
/// poisoned first diff, a poisoned second diff after a finite first one) and
/// DAGDB_STARTUP_LOAD (`DagDBStartup.recover`). Each path × each lane × five
/// bit patterns (two quiet NaNs, a signalling NaN, +∞, −∞) is one refusal
/// cell; the target's whole state is unchanged after each. The poisoned files
/// are crafted through the library writers, which stay permissive. Finite controls (the least subnormal, −0.0, the
/// largest finite float) load bit for bit through every path.
///
/// BACKUP COMPACT on a chain whose folded state holds a non-finite
/// value or weight (in the base, the first diff or the second) is refused by
/// name, writes nothing and deletes nothing, and the chain still restores to
/// the same refusal. With the finite controls it compacts and restores equal.
final class TernaryA7LoadRefusalTests: XCTestCase {

    private var tmpDir: String!
    private let side = 8
    private var gridSide: Int { side }

    /// The node and slot every cell poisons: the value lane at node 37, the
    /// weight lane at node 21 slot 4.
    private let valueNode = 37
    private let weightNode = 21, weightSlot = 4

    private let poisons: [(name: String, bits: UInt32)] = [
        ("quiet NaN", 0x7FC0_0000),
        ("negative quiet NaN with payload", 0xFFC1_2345),
        ("signalling NaN", 0x7F80_0001),
        ("+inf", 0x7F80_0000),
        ("-inf", 0xFF80_0000),
    ]
    private let controls: [(name: String, bits: UInt32)] = [
        ("least subnormal", 0x0000_0001),
        ("-0.0", 0x8000_0000),
        ("largest finite", 0x7F7F_FFFF),
    ]

    enum Lane: String, CaseIterable { case value, weight }

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "tern-a7-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(atPath: d) }
    }

    // MARK: - Engines

    private func fresh() throws -> DagDBEngine {
        let e = try DagDBEngine(grid: try HexGrid(width: side, height: side),
                                state: DagDBState(width: side, height: side), maxRank: 8)
        let nb = e.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: e.nodeCount * 6)
        for i in 0..<(e.nodeCount * 6) { nb[i] = -1 }
        return e
    }

    /// A valid source with finite, non-default weight and value lanes;
    /// `ternary` adds a table and a TTABLE node, so SAVE writes v8 and a
    /// backup diff is format 3.
    private func source(ternary: Bool) throws -> DagDBEngine {
        let e = try fresh()
        let n = e.nodeCount
        let w = e.edgeWeightsBuf.contents().bindMemory(to: Float.self, capacity: n * 6)
        for k in 0..<(n * 6) { w[k] = Float(k % 7) * 0.25 - 0.5 }
        let v = e.nodeValueBuf.contents().bindMemory(to: Float.self, capacity: n)
        for i in 0..<n { v[i] = Float(i % 5) * 1.5 - 2 }
        for i in 0..<n { e.truthStateBuf.contents().storeBytes(of: UInt8(i % 2), toByteOffset: i, as: UInt8.self) }
        if ternary { try makeTernary(e) }
        XCTAssertNil(e.ternaryStateViolation())
        return e
    }

    private func makeTernary(_ e: DagDBEngine) throws {
        try e.writeTables(first: 0, bytes: try TernaryReference.presetTable(.tsum, k: 2))
        e.truthStateBuf.contents().storeBytes(of: 2, toByteOffset: 7, as: UInt8.self)
        e.setNodeMode(7, 1)
    }

    private func poke(_ e: DagDBEngine, _ lane: Lane, _ bits: UInt32) {
        switch lane {
        case .value:
            e.nodeValueBuf.contents().storeBytes(of: bits, toByteOffset: valueNode * 4, as: UInt32.self)
        case .weight:
            e.edgeWeightsBuf.contents().storeBytes(of: bits, toByteOffset: (weightNode * 6 + weightSlot) * 4, as: UInt32.self)
        }
    }

    private func peek(_ e: DagDBEngine, _ lane: Lane) -> UInt32 {
        switch lane {
        case .value:
            return e.nodeValueBuf.contents().load(fromByteOffset: valueNode * 4, as: UInt32.self)
        case .weight:
            return e.edgeWeightsBuf.contents().load(fromByteOffset: (weightNode * 6 + weightSlot) * 4, as: UInt32.self)
        }
    }

    /// The refusal text for the poisoned lane: node, slot where relevant,
    /// value and bits, and the rule.
    private func needle(_ lane: Lane, _ bits: UInt32) -> String {
        switch lane {
        case .value: return DagDBSnapshot.nodeValueRefusal(bits: bits, node: valueNode)!
        case .weight: return DagDBSnapshot.weightRefusal(bits: bits, node: weightNode, slot: weightSlot)!
        }
    }

    /// A target holding a state of its own, so a half-load would show.
    private func target() throws -> HandlerFixture {
        let f = try HandlerFixture(side: side, maxRank: 8)
        let e = f.handler.engine
        for i in 0..<e.nodeCount { e.truthStateBuf.contents().storeBytes(of: UInt8((i + 1) % 2), toByteOffset: i, as: UInt8.self) }
        e.edgeWeightsBuf.contents().storeBytes(of: Float(3.5), toByteOffset: 0, as: Float.self)
        e.nodeValueBuf.contents().storeBytes(of: Float(-7.25), toByteOffset: 4, as: Float.self)
        return f
    }

    // MARK: - The paths

    /// One load path: `craft` writes the file(s) for a source in which `poison`
    /// is applied at the right moment, through the library writers; the
    /// returned verb loads them into a daemon. `diff` names the backup diff
    /// the refusal must name, when the path is a diff.
    private struct Path {
        let name: String
        let diff: String?
        let craft: (_ out: String, _ poison: (DagDBEngine) -> Void) throws -> (verb: String, source: DagDBEngine)
    }

    private var paths: [Path] {
        let s = side
        func dags(_ name: String, ternary: Bool, compressed: Bool) -> Path {
            Path(name: name, diff: nil) { out, poison in
                let e = try self.source(ternary: ternary)
                poison(e)
                let p = out + ".dags"
                _ = try DagDBSnapshot.save(engine: e, nodeCount: e.nodeCount, gridW: s, gridH: s,
                                           tickCount: 3, path: p, compressed: compressed)
                let ver = try Data(contentsOf: URL(fileURLWithPath: p))[4]
                XCTAssertEqual(ver, ternary ? 8 : 7, name)
                return ("LOAD \(p)", e)
            }
        }
        return [
            dags("LOAD .dags v7 plain", ternary: false, compressed: false),
            dags("LOAD .dags v7 zlib", ternary: false, compressed: true),
            dags("LOAD .dags v8 plain", ternary: true, compressed: false),
            dags("LOAD .dags v8 zlib", ternary: true, compressed: true),
            Path(name: "LOAD JSON v2", diff: nil) { out, poison in
                let e = try self.source(ternary: true)
                poison(e)
                let p = out + ".json"
                _ = try DagDBJSONIO.saveJSON(engine: e, nodeCount: e.nodeCount, gridW: s, gridH: s, tickCount: 3, path: p)
                return ("LOAD JSON \(p)", e)
            },
            Path(name: "LOAD CSV v2", diff: nil) { out, poison in
                let e = try self.source(ternary: true)
                poison(e)
                _ = try DagDBJSONIO.saveCSV(engine: e, nodeCount: e.nodeCount, dir: out)
                return ("LOAD CSV \(out)", e)
            },
            Path(name: "IMPORT MORTON", diff: nil) { out, poison in
                let e = try self.source(ternary: true)
                poison(e)
                _ = try DagDBSnapshot.exportMorton(engine: e, nodeCount: e.nodeCount, dir: out)
                return ("IMPORT MORTON \(out)", e)
            },
            Path(name: "BACKUP RESTORE base", diff: nil) { out, poison in
                let e = try self.source(ternary: false)
                poison(e)
                _ = try DagDBBackup.initializeChain(engine: e, nodeCount: e.nodeCount, gridW: s, gridH: s,
                                                    tickCount: 3, dir: out)
                return ("BACKUP RESTORE \(out)", e)
            },
            Path(name: "BACKUP RESTORE diff 1", diff: "00001.diff") { out, poison in
                let e = try self.source(ternary: false)
                _ = try DagDBBackup.initializeChain(engine: e, nodeCount: e.nodeCount, gridW: s, gridH: s,
                                                    tickCount: 3, dir: out)
                poison(e)
                let r = try DagDBBackup.appendDiff(engine: e, nodeCount: e.nodeCount, gridW: s, gridH: s, dir: out)
                XCTAssertEqual(r.format, 2, "diff 1 is format 2")
                return ("BACKUP RESTORE \(out)", e)
            },
            Path(name: "BACKUP RESTORE diff 2", diff: "00002.diff") { out, poison in
                let e = try self.source(ternary: false)
                _ = try DagDBBackup.initializeChain(engine: e, nodeCount: e.nodeCount, gridW: s, gridH: s,
                                                    tickCount: 3, dir: out)
                // A finite first diff, then the poison in a format-3 second one.
                e.truthStateBuf.contents().storeBytes(of: 1, toByteOffset: 2, as: UInt8.self)
                e.nodeValueBuf.contents().storeBytes(of: Float(9.25), toByteOffset: 5 * 4, as: Float.self)
                let r1 = try DagDBBackup.appendDiff(engine: e, nodeCount: e.nodeCount, gridW: s, gridH: s, dir: out)
                XCTAssertEqual(r1.format, 2, "diff 1 is format 2")
                try self.makeTernary(e)
                poison(e)
                let r2 = try DagDBBackup.appendDiff(engine: e, nodeCount: e.nodeCount, gridW: s, gridH: s, dir: out)
                XCTAssertEqual(r2.format, 3, "diff 2 is format 3")
                return ("BACKUP RESTORE \(out)", e)
            },
            Path(name: "DAGDB_STARTUP_LOAD", diff: nil) { out, poison in
                let e = try self.source(ternary: true)
                poison(e)
                let p = out + ".dags"
                _ = try DagDBSnapshot.save(engine: e, nodeCount: e.nodeCount, gridW: s, gridH: s,
                                           tickCount: 3, path: p, compressed: true)
                return ("STARTUP \(p)", e)
            },
        ]
    }

    /// Run a crafted verb against a target. "STARTUP <path>" runs the
    /// daemon's startup sequence (`DagDBStartup.recover`) over the target's
    /// engine with DAGDB_STARTUP_LOAD = path; everything else is a DSL line.
    private func run(_ verb: String, on f: HandlerFixture) -> String {
        if verb.hasPrefix("STARTUP ") {
            let p = String(verb.dropFirst("STARTUP ".count))
            do {
                let r = try DagDBStartup.recover(
                    engine: f.handler.engine, nodeCount: side * side, width: side, height: side,
                    dagdbEnv: nil, dataRoot: nil, twin: TwinState(), truthRankIndex: TruthRankIndex(),
                    snapshotPath: p, walPath: nil, log: { _ in })
                return "OK STARTUP ticks=\(r.tickCount)"
            } catch {
                return "ERROR startup: \(error)"
            }
        }
        return f.handler.handle(verb)
    }

    // MARK: - Refusals

    func testItem1EveryLoadPathRefusesANonFiniteValueOrWeightByName() throws {
        var cells = 0, refused = 0
        var redByPath: [String: Int] = [:]
        for (pi, path) in paths.enumerated() {
            for lane in Lane.allCases {
                for (qi, q) in poisons.enumerated() {
                    let out = tmpDir + "p\(pi)_\(lane.rawValue)_\(qi)"
                    let crafted = try path.craft(out) { self.poke($0, lane, q.bits) }
                    XCTAssertEqual(peek(crafted.source, lane), q.bits, "the source holds the poison")
                    let f = try target()
                    let before = TernaryR5DaemonTests.stateHash(f.handler.engine)
                    let reply = run(crafted.verb, on: f)
                    let n = needle(lane, q.bits)
                    var byName = reply.hasPrefix("ERROR") && reply.contains(n)
                    if let d = path.diff { byName = byName && reply.contains(d) }
                    let unchanged = TernaryR5DaemonTests.stateHash(f.handler.engine) == before
                    XCTAssertTrue(byName, "\(path.name) × \(lane) \(q.name): not refused by name — \(reply)")
                    XCTAssertTrue(unchanged, "\(path.name) × \(lane) \(q.name): the target changed — \(reply)")
                    if byName && unchanged { refused += 1 } else { redByPath[path.name, default: 0] += 1 }
                    print("A7 item1 \(path.name) × \(lane) \(q.name) (bits 0x\(String(q.bits, radix: 16))): \(byName ? "refused" : "ACCEPTED") target_unchanged=\(unchanged) — \(reply)")
                    cells += 1
                }
            }
        }
        XCTAssertEqual(cells, paths.count * 2 * poisons.count)
        print("A7 item1 refusal cells: \(refused)/\(cells) refused by name with the target unchanged; not refused per path: \(redByPath.sorted { $0.key < $1.key })")
    }

    // MARK: - Finite controls

    func testItem1FiniteControlsLoadBitForBitThroughEveryPath() throws {
        var cells = 0, equal = 0
        for (pi, path) in paths.enumerated() {
            for lane in Lane.allCases {
                for (ci, c) in controls.enumerated() {
                    let out = tmpDir + "c\(pi)_\(lane.rawValue)_\(ci)"
                    let crafted = try path.craft(out) { self.poke($0, lane, c.bits) }
                    let f = try target()
                    let reply = run(crafted.verb, on: f)
                    XCTAssertTrue(reply.hasPrefix("OK"), "\(path.name) × \(lane) \(c.name): \(reply)")
                    let bits = peek(f.handler.engine, lane)
                    let same = TernaryR5DaemonTests.stateHash(f.handler.engine) == TernaryR5DaemonTests.stateHash(crafted.source)
                    XCTAssertEqual(bits, c.bits, "\(path.name) × \(lane) \(c.name): bits")
                    XCTAssertTrue(same, "\(path.name) × \(lane) \(c.name): state differs from the source")
                    if reply.hasPrefix("OK") && bits == c.bits && same { equal += 1 }
                    print("A7 item1 control \(path.name) × \(lane) \(c.name): loaded bits 0x\(String(bits, radix: 16)) state_equal=\(same) — \(reply)")
                    cells += 1
                }
            }
        }
        XCTAssertEqual(cells, paths.count * 2 * controls.count)
        print("A7 item1 finite controls: \(equal)/\(cells) loaded bit for bit, state equal to the source")
    }

    // MARK: - BACKUP COMPACT

    /// Every file in `dir` by name, with its bytes — a rewrite or a deletion
    /// shows.
    private func fingerprint(_ dir: String) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir) {
            out[name] = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + name))
        }
        return out
    }

    /// The text after "ERROR io: <verb>: " (or the whole reply).
    private func tail(_ reply: String, _ verb: String) -> String {
        let p = "ERROR io: \(verb): "
        return reply.hasPrefix(p) ? String(reply.dropFirst(p.count)) : reply
    }

    func testItem2CompactRefusesAPoisonedChainWritesAndDeletesNothing() throws {
        let chains = paths.filter { $0.name.hasPrefix("BACKUP RESTORE") }
        XCTAssertEqual(chains.count, 3)
        var cells = 0, held = 0
        for (pi, path) in chains.enumerated() {
            for lane in Lane.allCases {
                for (qi, q) in poisons.enumerated() {
                    let dir = tmpDir + "k\(pi)_\(lane.rawValue)_\(qi)"
                    _ = try path.craft(dir) { self.poke($0, lane, q.bits) }
                    let f = try target()
                    let live = TernaryR5DaemonTests.stateHash(f.handler.engine)
                    let n = needle(lane, q.bits)
                    let restoreBefore = f.handler.handle("BACKUP RESTORE \(dir)")
                    let files = try fingerprint(dir)
                    let reply = f.handler.handle("BACKUP COMPACT \(dir)")
                    var byName = reply.hasPrefix("ERROR") && reply.contains(n)
                    if let d = path.diff { byName = byName && reply.contains(d) }
                    let after = try fingerprint(dir)
                    let untouched = after == files
                    let restoreAfter = f.handler.handle("BACKUP RESTORE \(dir)")
                    let sameRefusal = restoreAfter.hasPrefix("ERROR") && restoreAfter.contains(n)
                        && restoreAfter == restoreBefore
                        && tail(restoreAfter, "backup_restore") == tail(reply, "backup_compact")
                    let liveUnchanged = TernaryR5DaemonTests.stateHash(f.handler.engine) == live
                    XCTAssertTrue(byName, "COMPACT \(path.name) × \(lane) \(q.name): not refused by name — \(reply)")
                    XCTAssertTrue(untouched, "COMPACT \(path.name) × \(lane) \(q.name): the chain changed \(files.keys.sorted()) → \(after.keys.sorted())")
                    XCTAssertTrue(sameRefusal, "COMPACT \(path.name) × \(lane) \(q.name): restore before '\(restoreBefore)', compact '\(reply)', restore after '\(restoreAfter)'")
                    XCTAssertTrue(liveUnchanged, "COMPACT \(path.name) × \(lane) \(q.name): the live engine changed")
                    // Diff application generally: APPEND replays the
                    // chain to find its tip, so a poisoned chain refuses the
                    // append — from a fresh daemon whose own lanes are finite,
                    // on a second copy of the chain nothing else has touched —
                    // by the same name, and no diff is written.
                    let dirA = dir + "_append"
                    _ = try path.craft(dirA) { self.poke($0, lane, q.bits) }
                    let filesA = try fingerprint(dirA)
                    let g = try target()
                    let append = g.handler.handle("BACKUP APPEND \(dirA)")
                    var appendByName = append.hasPrefix("ERROR") && append.contains(n)
                    if let d = path.diff { appendByName = appendByName && append.contains(d) }
                    let afterAppend = try fingerprint(dirA)
                    XCTAssertTrue(appendByName, "APPEND onto \(path.name) × \(lane) \(q.name): \(append)")
                    XCTAssertEqual(afterAppend, filesA, "APPEND onto \(path.name) × \(lane) \(q.name): the chain changed")
                    if byName && untouched && sameRefusal && liveUnchanged && appendByName && afterAppend == filesA { held += 1 }
                    print("A7 item2 COMPACT \(path.name) × \(lane) \(q.name): \(byName ? "refused" : "COMPACTED") chain_unchanged=\(untouched) same_refusal_after=\(sameRefusal) — \(reply) | restore after: \(restoreAfter) | append (fresh daemon, second copy): \(append) chain_unchanged_after_append=\(afterAppend == filesA)")
                    cells += 1
                }
            }
        }
        XCTAssertEqual(cells, 3 * 2 * poisons.count)
        print("A7 item2 COMPACT refusal cells: \(held)/\(cells) refused by name, chain unchanged byte for byte, restore after = the same refusal, APPEND onto the chain refused by name with nothing written")

        // Control: the same chains with the finite controls compact, and the
        // compacted chain restores bit for bit to the source.
        var controlCells = 0, controlOK = 0
        for (pi, path) in chains.enumerated() {
            for lane in Lane.allCases {
                for (ci, c) in controls.enumerated() {
                    let dir = tmpDir + "kc\(pi)_\(lane.rawValue)_\(ci)"
                    let crafted = try path.craft(dir) { self.poke($0, lane, c.bits) }
                    let f = try target()
                    let reply = f.handler.handle("BACKUP COMPACT \(dir)")
                    let left = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".diff") }
                    let restore = f.handler.handle("BACKUP RESTORE \(dir)")
                    let bits = peek(f.handler.engine, lane)
                    let same = TernaryR5DaemonTests.stateHash(f.handler.engine) == TernaryR5DaemonTests.stateHash(crafted.source)
                    XCTAssertTrue(reply.hasPrefix("OK BACKUP_COMPACT"), "COMPACT control \(path.name) × \(lane) \(c.name): \(reply)")
                    XCTAssertTrue(left.isEmpty, "COMPACT control \(path.name): diffs left \(left)")
                    XCTAssertTrue(restore.hasPrefix("OK BACKUP_RESTORE diffs_replayed=0"), "COMPACT control \(path.name): \(restore)")
                    XCTAssertEqual(bits, c.bits)
                    XCTAssertTrue(same, "COMPACT control \(path.name) × \(lane) \(c.name): state differs")
                    if reply.hasPrefix("OK") && left.isEmpty && bits == c.bits && same { controlOK += 1 }
                    controlCells += 1
                }
            }
        }
        XCTAssertEqual(controlCells, 3 * 2 * controls.count)
        print("A7 item2 COMPACT finite controls: \(controlOK)/\(controlCells) compacted and restored bit for bit")
    }
}
