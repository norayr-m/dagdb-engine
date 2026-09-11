import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Shared handler construction for daemon-kit test files that need a real
/// DagDBCommandHandler without a socket or mmap'd shm (interface phase, 2026-09). Mirrors
/// DagDBCommandHandlerTests.makeHandler exactly — same engine setup, same
/// shm sizing — so tests across files see identical fixtures. Introduced so
/// the twin verb test files (T8.1–T8.5) don't each reimplement this.
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
    init(
        side: Int,
        dataRoot: String? = nil,
        dagdbEnv: String? = nil,
        wal: DagDBWAL.Appender? = nil,
        twin: TwinState = TwinState(),
        shmBytes: Int? = nil
    ) throws {
        let grid = HexGrid(width: side, height: side)
        let state = DagDBState(width: side, height: side)
        let engine = try DagDBEngine(grid: grid, state: state, maxRank: 8)
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
            width: side, height: side, maxRank: 8,
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
