/// DagDBReaderSession — snapshot-on-read MVCC for DagDB.
///
/// Shipped 2026-04-20.
///
/// A reader session takes a one-shot copy of all ten persisted engine
/// buffers, plus the back-edge list, at open-time into an independent
/// `DagDBEngine` instance. Subsequent reads against that session see the
/// state as of open-time, immune to writes on the primary engine. Writers
/// are not blocked by readers.
///
/// (It copied SIX buffers until 2026-09-12, so every session saw registers
/// as ordinary combinational nodes and every edge weight at its 1.0
/// default — see C7 in `docs/contracts/CORE_DURABILITY_GATES_FROZEN.md`.)
///
/// This is NOT full MVCC — there are no per-node versions, no write-side
/// version map, no background GC. It's the minimum viable middle step:
/// reader-writer isolation at the cost of one `memcpy` per reader at
/// session open (and 42 B per node of RAM per active reader while open).
///
/// For an access pattern dominated by many concurrent reads against a
/// low-write-rate event log, snapshot-on-read is sufficient. Upgrade
/// path to full MVCC stays open.
///
/// Threading note: the daemon's accept loop is single-threaded today
/// (SocketServer.swift). Sessions give readers a stable point-in-time
/// view even under serial dispatch, and set up the abstraction so that
/// a future threaded daemon can run reader commands in parallel without
/// touching the read-path API.

import Foundation

public final class DagDBReaderSession {
    public let id: String
    public let snapshotEngine: DagDBEngine
    public let nodeCount: Int
    public let gridW: Int
    public let gridH: Int
    public let tickCountAtOpen: UInt32
    public let openedAt: Date

    internal init(
        id: String,
        snapshotEngine: DagDBEngine,
        nodeCount: Int,
        gridW: Int,
        gridH: Int,
        tickCountAtOpen: UInt32
    ) {
        self.id = id
        self.snapshotEngine = snapshotEngine
        self.nodeCount = nodeCount
        self.gridW = gridW
        self.gridH = gridH
        self.tickCountAtOpen = tickCountAtOpen
        self.openedAt = Date()
    }
}

public final class DagDBReaderSessionManager {

    public enum MVCCError: Error, CustomStringConvertible {
        case sessionNotFound(String)
        case snapshotFailed(String)

        public var description: String {
            switch self {
            case .sessionNotFound(let id): return "session not found: \(id)"
            case .snapshotFailed(let s):   return "snapshot: \(s)"
            }
        }
    }

    private var sessions: [String: DagDBReaderSession] = [:]
    private var counter: UInt64 = 0

    public init() {}

    /// Number of currently open reader sessions.
    public var openCount: Int { sessions.count }

    public var openSessions: [DagDBReaderSession] {
        Array(sessions.values)
    }

    /// Open a new reader session. Snapshots the primary engine's six
    /// buffers into a fresh `DagDBEngine` instance. Returns the session id.
    @discardableResult
    public func open(
        primary: DagDBEngine,
        grid: HexGrid,
        stateTemplate: DagDBState,
        maxRank: Int,
        tickCount: UInt32
    ) throws -> DagDBReaderSession {
        let n = primary.nodeCount

        // C7 · the destination is sized by the CALLER's grid, and every
        // memcpy below is `n` elements of the PRIMARY's. A smaller grid was
        // a heap overwrite with no complaint (audit A, finding 42).
        guard grid.nodeCount == n else {
            throw MVCCError.snapshotFailed(
                "grid nodeCount \(grid.nodeCount) does not match the primary's \(n)")
        }

        // Build a fresh engine of the same shape. Uses a zero-init state
        // template; we'll overwrite its buffers from the primary next.
        let snap: DagDBEngine
        do {
            snap = try DagDBEngine(grid: grid, state: stateTemplate, maxRank: maxRank)
        } catch {
            throw MVCCError.snapshotFailed("engine init: \(error)")
        }

        // C7 · ALL TEN persisted lanes, plus the back-edge list. Copying six
        // of them left every reader session seeing registers as ordinary
        // combinational nodes and all weights at their 1.0 default, so a
        // session on a graph with a BACK_EDGE diverged from the primary on
        // the first tick (audit A, finding 41).
        //
        // rank is u64 → n * 8 bytes. (Was n * 4 pre-2026-05-18, which
        // truncated the copy to the lower half of nodes — every reader saw
        // garbage ranks for nodes >= n/2. Regression guard:
        // testRankBufferCopiedForUpperHalfNodes.)
        memcpy(snap.rankBuf.contents(),        primary.rankBuf.contents(),        n * 8)
        memcpy(snap.truthStateBuf.contents(),  primary.truthStateBuf.contents(),  n)
        memcpy(snap.nodeTypeBuf.contents(),    primary.nodeTypeBuf.contents(),    n)
        memcpy(snap.lut6LowBuf.contents(),     primary.lut6LowBuf.contents(),     n * 4)
        memcpy(snap.lut6HighBuf.contents(),    primary.lut6HighBuf.contents(),    n * 4)
        memcpy(snap.neighborsBuf.contents(),   primary.neighborsBuf.contents(),   n * 6 * 4)
        memcpy(snap.edgeWeightsBuf.contents(), primary.edgeWeightsBuf.contents(), n * 6 * 4)
        memcpy(snap.activationBuf.contents(),  primary.activationBuf.contents(),  n * 2)
        memcpy(snap.nodeValueBuf.contents(),   primary.nodeValueBuf.contents(),   n * 4)
        // The register flags come with the back-edge list, through the
        // checked installer, so the session's lists are validated like any
        // other install path.
        for i in 0..<primary.backEdgeSrcs.count {
            do {
                try snap.addBackEdgeUnchecked(src: primary.backEdgeSrcs[i],
                                              dst: primary.backEdgeDsts[i])
            } catch {
                throw MVCCError.snapshotFailed("back edge \(i): \(error)")
            }
        }
        snap.markRankTopologyDirty()

        counter += 1
        // C7 · 64-bit seconds. The old u32 field wrapped in February 2106,
        // and its 32-bit counter half collided whenever two counters agreed
        // mod 2^32 (audit A, finding 43).
        let id = String(format: "r%016llx%016llx",
                        UInt64(Date().timeIntervalSince1970), counter)
        let session = DagDBReaderSession(
            id: id, snapshotEngine: snap,
            nodeCount: n, gridW: grid.width, gridH: grid.height,
            tickCountAtOpen: tickCount
        )
        sessions[id] = session
        return session
    }

    /// Close and release a reader session. Returns true if the session
    /// existed, false if the id was unknown.
    @discardableResult
    public func close(_ id: String) -> Bool {
        guard sessions[id] != nil else { return false }
        sessions.removeValue(forKey: id)
        return true
    }

    /// Look up a session by id. Nil if not found.
    public func get(_ id: String) -> DagDBReaderSession? {
        return sessions[id]
    }

    /// Close every session and release all snapshot engines. Call on shutdown.
    public func closeAll() {
        sessions.removeAll()
    }
}
