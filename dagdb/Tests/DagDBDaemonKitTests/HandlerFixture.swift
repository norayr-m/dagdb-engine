import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Shared handler construction for daemon-kit test files that need a real
/// DagDBCommandHandler without a socket or mmap'd shm. Mirrors
/// DagDBCommandHandlerTests.makeHandler exactly — same engine setup, same
/// shm sizing — so tests across files see identical fixtures. Introduced so
/// the twin verb test files don't each reimplement this.
final class HandlerFixture {
    let handler: DagDBCommandHandler
    let shm: UnsafeMutableRawPointer
    let shmBytes: Int
    /// The engine's grid, exposed for tests that build a `LadderFold.Object`
    /// (or a court/control object) directly against this fixture's engine —
    /// e.g. `LadderFold.Objects.control(engine: f.handler.engine, grid: f.grid)`.
    let grid: HexGrid

    /// `shmBytes`: override the shm buffer's size (and the handler's
    /// `shmCapacityBytes`) instead of the default `8 + nodeCount * 24` —
    /// needed by FOLD RUN tests, whose control object requires a side-12
    /// engine (144 nodes) but whose 49x49 Float32 output (9,604 bytes) does
    /// not fit that engine's default-sized buffer (3,464 bytes). Passing
    /// `nil` (the default) keeps every existing fixture's sizing unchanged.
    /// `maxRank`: the engine's allocated rank-bucket COUNT (the dispatch
    /// table's sizing, NOT a bound check — `DagDBEngine.tick`'s rank-mode
    /// loop iterates `0..<maxRank`, silently skipping any node whose
    /// actual rank falls outside that range). Defaults to 8 (every
    /// existing fixture's side needs no more), but a side whose
    /// Chebyshev-derived max rank exceeds 8 (`TiledFixture`'s
    /// `maxRankForSide`, e.g. side 44 → 22) MUST pass a larger value here
    /// for rank-mode ticking (`TICK`) to reach every node — `TICK_SYNC`
    /// is unaffected (it dispatches over all `nodeCount` nodes regardless
    /// of `maxRank`), which is why this only bites rank-mode ticking
    /// tests specifically.
    init(
        side: Int,
        dataRoot: String? = nil,
        dagdbEnv: String? = nil,
        wal: DagDBWAL.Appender? = nil,
        twin: TwinState = TwinState(),
        shmBytes: Int? = nil,
        maxRank: Int = 8
    ) throws {
        let grid = try HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: maxRank)
        let nb = engine.neighborsBuf.contents()
            .bindMemory(to: Int32.self, capacity: engine.nodeCount * 6)
        for i in 0..<(engine.nodeCount * 6) { nb[i] = -1 }

        let bytes = shmBytes ?? (8 + engine.nodeCount * 24)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        buf.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        self.shm = buf
        self.shmBytes = bytes
        self.grid = grid

        self.handler = DagDBCommandHandler(
            engine: engine, grid: grid, nodeCount: engine.nodeCount,
            width: side, height: side, maxRank: maxRank,
            tickCount: 0, walAppender: wal,
            sessionManager: DagDBReaderSessionManager(),
            truthRankIndex: TruthRankIndex(),
            shmBase: buf, resultRowSize: 24,
            dataRoot: dataRoot, dagdbEnv: dagdbEnv,
            twin: twin,
            shmBytes: shmBytes
        )
    }

    deinit {
        shm.deallocate()
    }
}

/// The 14 input verbs' codes, in the protocol's order. A frame for verb v carries word1 = 0x314D4800 | v. The codes
/// are the protocol's, written here and not read from DaemonKit.
enum SHM1Verb: UInt32, CaseIterable {
    case setRanksBulk = 1
    case setLutsBulk = 2
    case setNeighborsBulk = 3
    case setModesBulk = 4
    case setTTableIdsBulk = 5
    case setThreshBulk = 6
    case ttableBulk = 7
    case connectBackBulk = 8
    case setTruthBulk = 9
    case xconvCheck = 10
    case xconvSealed = 11
    case budgetOpen = 12
    case bankGenerate = 13
    case bankFit = 14

    /// The verb as its refusals name it.
    var name: String {
        ["SET_RANKS_BULK", "SET_LUTS_BULK", "SET_NEIGHBORS_BULK", "SET_MODES_BULK", "SET_TTABLE_IDS_BULK",
         "SET_THRESH_BULK", "TTABLE_BULK", "CONNECT_BACK_BULK", "SET_TRUTH_BULK", "XCONV CHECK", "XCONV SEALED",
         "BUDGET OPEN", "BANK GENERATE", "BANK FIT"][Int(rawValue) - 1]
    }

    /// The verb of that name (a helper that takes the verb's name as it sends it).
    static func named(_ name: String) -> SHM1Verb {
        guard let v = allCases.first(where: { $0.name == name }) else { preconditionFailure("SHM1: \(name) is not an input verb") }
        return v
    }
}

/// Word1 of a frame for `verb`, the literal
/// 0x314D4800 | v (the bytes 0x48 'H', 0x4D 'M', 0x31 '1' above the code).
func shm1Word1(_ verb: SHM1Verb) -> UInt32 { 0x314D_4800 | verb.rawValue }

/// An input frame's header for `verb`, `[u32 count][u32
/// 0x314D4800 | v]` at bytes 0..7 of `base`; the payload goes at offset 8.
func shm1Header(_ base: UnsafeMutableRawPointer, count: Int, verb: SHM1Verb) {
    base.storeBytes(of: UInt32(count), toByteOffset: 0, as: UInt32.self)
    base.storeBytes(of: shm1Word1(verb), toByteOffset: 4, as: UInt32.self)
}
