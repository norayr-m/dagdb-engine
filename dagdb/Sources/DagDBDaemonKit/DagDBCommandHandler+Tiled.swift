/// TILED verb family — gate T5, docs/contracts/TILING_GATES_FROZEN.md.
/// Cross-tile query routers (`TiledGraphRouter`) over tile directories
/// written by `TiledGraphFiles.write` (`SAVE TILED`). Deliberately NOT a
/// twin registry — `TiledGraphRouter`'s own header comment says why: a
/// router is never persisted, never WAL-logged, never part of a snapshot;
/// a tile directory on disk IS the durable state, and `TILED OPEN` only
/// rebuilds an in-memory view of it. That's why `tiledRouters` lives on
/// the handler (mirrors `lastFold`'s "handler-held, not a registry"
/// precedent — DagDBCommandHandler+TwinFold.swift), not in `TwinState`.
///
/// `TiledGraphRouter` is a Swift actor; `DagDBCommandHandler.handle` is a
/// plain synchronous function invoked serially per connection (main.swift's
/// socket loop — no `await` context reaches here). `runTiledSync` bridges
/// the two: it starts a `Task` to run one actor call, blocks the calling
/// thread on a `DispatchSemaphore` until that call finishes, and rethrows
/// whatever it threw. This does not change the daemon's serialization
/// discipline (one command in flight at a time) — it only gives the
/// synchronous dispatcher a way to make one actor call and wait for it;
/// the semaphore is never contended because `handle` itself is never
/// re-entered while a prior call is still blocked on it.
import Foundation
import DagDB

/// One open TILED router plus the handler-side bookkeeping `TILED
/// LIST`/`STATUS` need. `dir`/`tiles`/`nodes`/`k` are captured once at
/// `TILED OPEN` time (all backed by `let`s on `TiledGraphRouter` too, but
/// mirrored here so the cheap, frequently-read fields never need a
/// blocking round-trip through the actor via `runTiledSync`).
struct TiledRouterEntry {
    let router: TiledGraphRouter
    let dir: String
    let tiles: Int
    let nodes: UInt64
    let k: Int
}

extension DagDBCommandHandler {

    /// Blocking bridge from synchronous dispatch into one `async throws`
    /// call against a `TiledGraphRouter` actor. See the file header for
    /// why this is safe: `handle` never re-enters while a call made
    /// through this helper is still in flight.
    func runTiledSync<T>(_ body: @escaping () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var outcome: Result<T, Error>!
        Task {
            do { outcome = .success(try await body()) }
            catch { outcome = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try outcome.get()
    }

    /// `<dataRoot>/<name>` split for `TiledGraphFiles`/`TiledGraphRouter`,
    /// which take the two separately — `SAVE TILED <dir> ...` and `TILED
    /// OPEN <dir> ...` take one combined directory argument.
    private func splitTiledDir(_ dir: String) -> (dataRoot: String, name: String) {
        let ns = dir as NSString
        return (ns.deletingLastPathComponent, ns.lastPathComponent)
    }

    /// Formats a TILED verb's OK reply, folding in `session=<id>` when the
    /// call came through a reader session — mirrors `twinResponse` in
    /// DagDBCommandHandler+Twin.swift.
    private func tiledResponse(_ verb: String, sessionId: String?, _ kv: String) -> String {
        if let sid = sessionId {
            return "OK \(verb) session=\(sid) \(kv)"
        }
        return "OK \(verb) \(kv)"
    }

    /// Writes cross-tile BFS/ancestry rows to shm: `[u32 count][u32 16]`
    /// header, then 16-byte rows (u64 global id, u32 depth, 4 pad) — gate
    /// T5's `TILED BFS` shape, distinct from `writeU64Vector`'s 8-byte rows.
    private func writeTiledBFSRows(_ rows: [(GlobalNodeID, UInt32)]) {
        let headerPtr = shmBase.bindMemory(to: UInt32.self, capacity: 2)
        headerPtr[0] = UInt32(rows.count)
        headerPtr[1] = 16
        let dataPtr = shmBase.advanced(by: 8)
        for (i, row) in rows.enumerated() {
            let rowPtr = dataPtr.advanced(by: i * 16)
            rowPtr.storeBytes(of: row.0.raw, as: UInt64.self)
            rowPtr.advanced(by: 8).storeBytes(of: row.1, as: UInt32.self)
            rowPtr.advanced(by: 12).storeBytes(of: UInt32(0), as: UInt32.self)
        }
    }

    func handleTiled(_ cmd: DSLCommand, sessionId: String?) -> String {
        switch cmd {

        case .saveTiled(let dir, let boundaries):
            if let err = guardPath(dir) { return err }
            guard !boundaries.isEmpty else {
                return "ERROR bad_value: SAVE TILED needs at least one boundary"
            }
            guard boundaries == boundaries.sorted() && Set(boundaries).count == boundaries.count else {
                return "ERROR bad_value: boundaries must be strictly ascending, got \(boundaries)"
            }
            let (dataRoot, name) = splitTiledDir(dir)
            guard !name.isEmpty else {
                return "ERROR bad_value: '\(dir)' has no graph-name path component"
            }
            do {
                let report = try TiledGraphFiles.write(
                    engine: engine, grid: grid, dataRoot: dataRoot, name: name, boundaries: boundaries
                )
                return tiledResponse(
                    "SAVE TILED", sessionId: sessionId,
                    "dir=\(dir) tiles=\(report.tiles) nodes=\(report.nodes) crossings=\(report.crossings)"
                )
            } catch {
                return "ERROR io: \(error)"
            }

        case .tiledOpen(let dir, let k):
            if let err = guardPath(dir) { return err }
            guard k >= 1 && k <= 64 else {
                return "ERROR out_of_range: K \(k) not in 1...64"
            }
            let (dataRoot, name) = splitTiledDir(dir)
            do {
                let (router, tiles, nodes) = try runTiledSync {
                    () async throws -> (TiledGraphRouter, Int, UInt64) in
                    let r = try await TiledGraphRouter(dataRoot: dataRoot, graphName: name, maxResidentTiles: k)
                    let m = await r.manifest
                    return (r, m.tiles.count, m.globalNodeCount)
                }
                tiledRouterCounter += 1
                let id = String(format: "x%08x", tiledRouterCounter)
                tiledRouters[id] = TiledRouterEntry(router: router, dir: dir, tiles: tiles, nodes: nodes, k: k)
                return tiledResponse(
                    "TILED OPEN", sessionId: sessionId,
                    "id=\(id) tiles=\(tiles) nodes=\(nodes) resident_max=\(k)"
                )
            } catch let err as RouterError {
                return "ERROR io: \(err)"
            } catch {
                return "ERROR io: \(error)"
            }

        case .tiledBFS(let id, let globalIdRaw, let depth, let backward):
            guard let entry = tiledRouters[id] else {
                return "ERROR not_found: tiled router \(id) not found"
            }
            guard depth >= 0 else {
                return "ERROR bad_value: depth must be non-negative, got \(depth)"
            }
            let router = entry.router
            let seed = GlobalNodeID(raw: globalIdRaw)
            do {
                let (rows, status) = try runTiledSync {
                    () async throws -> ([(GlobalNodeID, UInt32)], TiledStatus) in
                    let r = try await router.runBFS(seed: seed, depth: UInt32(depth), backward: backward)
                    let s = await router.status()
                    return (r, s)
                }
                let sorted = rows.sorted { $0.0.raw < $1.0.raw }
                writeTiledBFSRows(sorted)
                return tiledResponse(
                    "TILED BFS", sessionId: sessionId,
                    "id=\(id) seed=\(globalIdRaw) depth=\(depth) back=\(backward ? 1 : 0) "
                        + "count=\(sorted.count) loads=\(status.loads) evicts=\(status.evicts)"
                )
            } catch let err as RouterError {
                return "ERROR io: \(err)"
            } catch {
                return "ERROR io: \(error)"
            }

        case .tiledSelect(let id, let truth, let lo, let hi):
            guard let entry = tiledRouters[id] else {
                return "ERROR not_found: tiled router \(id) not found"
            }
            guard lo <= hi else {
                return "ERROR bad_value: lo \(lo) must be <= hi \(hi)"
            }
            let router = entry.router
            do {
                let ids = try runTiledSync {
                    try await router.runSelect(truth: truth, rankLo: lo, rankHi: hi)
                }
                writeU64Vector(ids.map { $0.raw })
                return tiledResponse(
                    "TILED SELECT", sessionId: sessionId,
                    "id=\(id) truth=\(truth) lo=\(lo) hi=\(hi) count=\(ids.count)"
                )
            } catch let err as RouterError {
                return "ERROR io: \(err)"
            } catch {
                return "ERROR io: \(error)"
            }

        case .tiledStatus(let id):
            guard let entry = tiledRouters[id] else {
                return "ERROR not_found: tiled router \(id) not found"
            }
            let router = entry.router
            guard let s = try? runTiledSync({ await router.status() }) else {
                return "ERROR io: status failed"
            }
            let lastStr = s.lastRefusal ?? "none"
            return tiledResponse(
                "TILED STATUS", sessionId: sessionId,
                "id=\(id) resident=\(s.residentTileCount)/\(s.maxResidentTiles) "
                    + "loads=\(s.loads) evicts=\(s.evicts) refused=\(s.refused) last=\(lastStr)"
            )

        case .tiledList:
            guard !tiledRouters.isEmpty else {
                return tiledResponse("TILED LIST", sessionId: sessionId, "count=0")
            }
            let parts = tiledRouters.keys.sorted().map { key -> String in
                let e = tiledRouters[key]!
                return "\(key)@dir=\(e.dir) tiles=\(e.tiles) nodes=\(e.nodes) resident_max=\(e.k)"
            }
            return tiledResponse(
                "TILED LIST", sessionId: sessionId,
                "count=\(tiledRouters.count) " + parts.joined(separator: " ")
            )

        case .tiledClose(let id):
            guard tiledRouters[id] != nil else {
                return "ERROR not_found: tiled router \(id) not found"
            }
            tiledRouters.removeValue(forKey: id)
            return tiledResponse("TILED CLOSE", sessionId: sessionId, "id=\(id) open=\(tiledRouters.count)")

        default:
            // Every case this family handler is dispatched (see `handle`'s
            // and `handleReadOnly`'s TILED cases) is covered above; this
            // branch exists only for switch exhaustiveness.
            return "ERROR unknown_command: tiled verb not wired yet"
        }
    }
}
