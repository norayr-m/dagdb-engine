/// DagDBReaderSession — snapshot-on-read MVCC for DagDB.
///
/// Shipped 2026-04-20.
///
/// A reader session takes a one-shot copy of the six engine buffers at
/// open-time into an independent `DagDBEngine` instance. Subsequent reads
/// against that session see the state as of open-time, immune to writes
/// on the primary engine. Writers are not blocked by readers.
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

        // Build a fresh engine of the same shape. Uses a zero-init state
        // template; we'll overwrite its buffers from the primary next.
        let snap: DagDBEngine
        do {
            snap = try DagDBEngine(grid: grid, state: stateTemplate, maxRank: maxRank)
        } catch {
            throw MVCCError.snapshotFailed("engine init: \(error)")
        }

        // Zero out the snapshot's neighbors (the DagDBEngine init seeds
        // hex-adjacency neighbors; the primary may have overwritten them
        // with CONNECT-derived DAG edges).
        let nbDst = snap.neighborsBuf.contents()
        let nbLen = n * 6 * 4
        _ = nbDst  // silence unused on zero path
        // memcpy the six buffers from primary → snapshot. UMA memory, fast.
        memcpy(snap.rankBuf.contents(),       primary.rankBuf.contents(),       n * 4)
        memcpy(snap.truthStateBuf.contents(), primary.truthStateBuf.contents(), n)
        memcpy(snap.nodeTypeBuf.contents(),   primary.nodeTypeBuf.contents(),   n)
        memcpy(snap.lut6LowBuf.contents(),    primary.lut6LowBuf.contents(),    n * 4)
        memcpy(snap.lut6HighBuf.contents(),   primary.lut6HighBuf.contents(),   n * 4)
        memcpy(snap.neighborsBuf.contents(),  primary.neighborsBuf.contents(),  nbLen)

        counter += 1
        let id = String(format: "r%08x%08x", UInt32(Date().timeIntervalSince1970), UInt32(counter & 0xFFFFFFFF))
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
