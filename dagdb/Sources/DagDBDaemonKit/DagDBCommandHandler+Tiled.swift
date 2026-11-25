/// TILED verb family.
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
    /// The resident bytes TILED OPEN admitted (the router's steady state per
    /// global node and per crossing, and 2·min(K, tiles) engines of the largest tile with its ghosts),
    /// carried in the committed-bytes ledger until TILED CLOSE.
    var admittedBytes: Int = 0
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
    /// header, then 16-byte rows (u64 global id, u32 depth, 4 pad) — the
    /// `TILED BFS` shape, distinct from `writeU64Vector`'s 8-byte rows.
    /// Capacity-checked. The router's world size is
    /// `manifest.globalNodeCount`, entirely independent of the `nodeCount`
    /// that sized this daemon's mapping, so the fit is
    /// never implied — it has to be checked. Returns nil when the rows fit.
    @discardableResult
    private func writeTiledBFSRows(_ rows: [(GlobalNodeID, UInt32)]) -> String? {
        if let e = checkShmFits(rows: rows.count, rowSize: 16) { return e }
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
        return nil
    }

    /// A tiled read that answers ERROR after it
    /// loaded or evicted tiles names the move (the router's loads/evicts are
    /// not refusal counters; residency is cache, nothing durable). Empty when
    /// nothing moved, or the status cannot be read.
    func tiledCacheMoved(_ router: TiledGraphRouter, since s0: TiledStatus?) -> String {
        guard let s0 = s0, let s1 = try? runTiledSync({ await router.status() }) else { return "" }
        guard s1.loads != s0.loads || s1.evicts != s0.evicts || s1.residentTileCount != s0.residentTileCount else { return "" }
        return "; the tile cache moved before the refusal: loads \(s0.loads)->\(s1.loads) evicts \(s0.evicts)->\(s1.evicts)"
            + " resident \(s0.residentTileCount)->\(s1.residentTileCount) (cache only; nothing durable written)"
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
                return "ERROR bad_value: \(Reply.quoted(dir)) has no graph-name path component"
            }
            // Each tile body is a snapshot that
            // TILED OPEN loads through LOAD, which refuses a non-finite
            // weight — so a non-finite lane is never written.
            if let why = nonFiniteLaneRefusal() {
                return "ERROR io: save_tiled: \(DagDBSnapshot.SnapError.validationFailed(why))"
            }
            // S4 refused as every writer refuses it; then a
            // tiled graph stays a rank-mode object: TILED OPEN
            // accepts exactly what rank TICK runs (S1 yes, S2/S3 no), so SAVE
            // TILED refuses S2 and S3 by name (rank-mode TICK's words) and
            // writes nothing — it never writes what TILED OPEN refuses.
            if let r = slotIntoRegisterWriterRefusal("SAVE TILED") { return r }
            if let why = DagDBSnapshot.rankOrderViolation(engine: engine, nodeCount: nodeCount) {
                return "ERROR invalid_graph: SAVE TILED refused, validation: \(why) "
                    + "(a tiled graph is a rank-mode object: TILED OPEN refuses this edge); nothing written"
            }
            do {
                let report = try TiledGraphFiles.write(
                    engine: engine, grid: grid, dataRoot: dataRoot, name: name, boundaries: boundaries,
                    tickCount: tickCount
                )
                // The world landed whole; an old copy whose
                // removal failed is named (the save stands).
                let left = report.oldWorldLeft.map { " WARN: the previous world, moved aside, could not be removed: \($0)" } ?? ""
                return tiledResponse(
                    "SAVE TILED", sessionId: sessionId,
                    "dir=\(Reply.quoted(dir)) tiles=\(report.tiles) nodes=\(report.nodes) crossings=\(report.crossings)"
                ) + left
            } catch TiledGraphFiles.FilesError.crossTileBackEdge(let src, let dst) {
                // A back edge whose src/dst fall in
                // different tiles under these boundaries — refused before
                // any directory is written (the library-level check in
                // `TiledGraphFiles.write` already ran before touching disk).
                return "ERROR bad_value: back edge crosses a tile boundary (\(src)→\(dst))"
            } catch {
                return Reply.errorLine("io", error)
            }

        case .tiledOpen(let dir, let k):
            if let err = guardPath(dir) { return err }
            guard k >= 1 && k <= 64 else {
                return "ERROR out_of_range: K \(k) not in 1...64"
            }
            let (dataRoot, name) = splitTiledDir(dir)
            // The router cap first. Then the manifest's read and decode, admitted from its size and its
            // , : [ { bytes, and the one decode, here. Then the router's steady state after a TILED TICK, from the
            // decoded crossings, admitted before the router is built (a writer open can recover and write):
            // per global node and per crossing, and 2*min(K, tiles) engines of the largest tile with its
            // distinct ghost sources (loadTileWithGhosts). The router is built on the decoded manifest, so the
            // file is decoded once. A manifest that does not read is refused as the router refused it.
            if let e = alloc1bCountRefusal("TILED OPEN", open: tiledRouters.count, kind: "tiled routers",
                                           cap: Self.alloc1bTiledRouterCap) { return e }
            // The file is opened once, as a regular file, read once and decoded from that copy.
            let opened = alloc1bReadManifest(path: TiledGraphFiles.manifestPath(dataRoot: dataRoot, name: name))
            guard let m = opened.manifest else { return opened.reply ?? "ERROR io: TILED OPEN" }
            // Every field the router keeps.
            let resident = Self.alloc1bRouterResident(m, k: k)
            if let e = admit("TILED OPEN", bytes: Self.newBytes(resident.bytes), what: resident.what) { return e }
            let routerBytes = Int(resident.bytes.rounded(.up))
            let seam = tiledWriteSeamForTesting
            do {
                // Writer role (the default): TILED OPEN
                // recovers any dangling flush and completes a partial
                // round before returning, so the daemon never hands out a
                // router over a torn world.
                let (router, tiles, nodes, recovered, completed) = try runTiledSync {
                    () async throws -> (TiledGraphRouter, Int, UInt64, Int, Int) in
                    let r = try await TiledGraphRouter(dataRoot: dataRoot, graphName: name, maxResidentTiles: k,
                                                       writeSeam: seam, manifest: m)
                    let m = await r.manifest
                    let report = await r.openReport
                    return (r, m.tiles.count, m.globalNodeCount, report.recovered, report.completed)
                }
                tiledRouterCounter += 1
                let id = String(format: "x%08x", tiledRouterCounter)
                tiledRouters[id] = TiledRouterEntry(router: router, dir: dir, tiles: tiles, nodes: nodes, k: k,
                                                    admittedBytes: routerBytes)
                return tiledResponse(
                    "TILED OPEN", sessionId: sessionId,
                    "id=\(id) tiles=\(tiles) nodes=\(nodes) resident_max=\(k) recovered=\(recovered) completed=\(completed)"
                )
            } catch RouterError.tileGPUFailure(let g) {
                // A recovery or completion tick whose
                // command buffer did not complete; that tile is not flushed,
                // no router is opened, the next TILED OPEN tries again.
                tiledOpenRefusedCount += 1      // counted in STATUS
                return "ERROR gpu: TILED OPEN: \(g)"
            } catch RouterError.tileWriteFailed(let f) {
                // A recovery or completion write step failed,
                // named; nothing after it written, no router opened, the
                // next TILED OPEN recovers again.
                tiledOpenRefusedCount += 1
                return f.carriedReply ?? "ERROR io: TILED OPEN: " + f.description   // a carried line under its own code
            } catch let err as RouterError {
                tiledOpenRefusedCount += 1
                return Reply.errorLine("io", err)
            } catch {
                tiledOpenRefusedCount += 1
                return Reply.errorLine("io", error)
            }

        case .tiledBFS(let id, let globalIdRaw, let depth, let backward):
            guard let entry = tiledRouters[id] else {
                return "ERROR not_found: tiled router \(Reply.quoted(id)) not found"
            }
            guard depth >= 0 else {
                return "ERROR bad_value: depth must be non-negative, got \(depth)"
            }
            // The router takes a u32 depth; `UInt32(depth)`
            // trapped at 2^32 and above, before the router's own maxDepth.
            guard let depth32 = UInt32(exactly: depth) else {
                return "ERROR out_of_range: TILED BFS depth \(depth) not in 0...\(UInt32.max); nothing written"
            }
            let router = entry.router
            let seed = GlobalNodeID(raw: globalIdRaw)
            let before = try? runTiledSync({ await router.status() })
            do {
                let (rows, status) = try runTiledSync {
                    () async throws -> ([(GlobalNodeID, UInt32)], TiledStatus) in
                    let r = try await router.runBFS(seed: seed, depth: depth32, backward: backward)
                    let s = await router.status()
                    return (r, s)
                }
                let sorted = rows.sorted { $0.0.raw < $1.0.raw }
                if let e = writeTiledBFSRows(sorted) { return e + tiledCacheMoved(router, since: before) }
                return tiledResponse(
                    "TILED BFS", sessionId: sessionId,
                    "id=\(id) seed=\(globalIdRaw) depth=\(depth) back=\(backward ? 1 : 0) "
                        + "count=\(sorted.count) loads=\(status.loads) evicts=\(status.evicts)"
                )
            } catch let err as RouterError {
                return Reply.errorLine("io", err) + tiledCacheMoved(router, since: before)
            } catch {
                return Reply.errorLine("io", error) + tiledCacheMoved(router, since: before)
            }

        case .tiledSelect(let id, let truth, let lo, let hi):
            guard let entry = tiledRouters[id] else {
                return "ERROR not_found: tiled router \(Reply.quoted(id)) not found"
            }
            guard lo <= hi else {
                return "ERROR bad_value: lo \(lo) must be <= hi \(hi)"
            }
            let router = entry.router
            let before = try? runTiledSync({ await router.status() })
            do {
                let ids = try runTiledSync {
                    try await router.runSelect(truth: truth, rankLo: lo, rankHi: hi)
                }
                if let e = writeU64Vector(ids.map { $0.raw }) { return e + tiledCacheMoved(router, since: before) }
                return tiledResponse(
                    "TILED SELECT", sessionId: sessionId,
                    "id=\(id) truth=\(truth) lo=\(lo) hi=\(hi) count=\(ids.count)"
                )
            } catch let err as RouterError {
                return Reply.errorLine("io", err) + tiledCacheMoved(router, since: before)
            } catch {
                return Reply.errorLine("io", error) + tiledCacheMoved(router, since: before)
            }

        case .tiledStatus(let id):
            guard let entry = tiledRouters[id] else {
                return "ERROR not_found: tiled router \(Reply.quoted(id)) not found"
            }
            let router = entry.router
            guard let s = try? runTiledSync({ await router.status() }) else {
                return "ERROR io: status failed"
            }
            let lastStr = s.lastRefusal.map { Reply.quoted($0) } ?? "none"     // stored file text, quoted
            return tiledResponse(
                "TILED STATUS", sessionId: sessionId,
                "id=\(id) resident=\(s.residentTileCount)/\(s.maxResidentTiles) "
                    + "loads=\(s.loads) evicts=\(s.evicts) refused=\(s.refused) last=\(lastStr) "
                    + "epoch=\(s.epochMin)/\(s.epochMax)"
            )

        case .tiledList:
            guard !tiledRouters.isEmpty else {
                return tiledResponse("TILED LIST", sessionId: sessionId, "count=0")
            }
            let parts = tiledRouters.keys.sorted().map { key -> String in
                let e = tiledRouters[key]!
                return "\(key)@dir=\(Reply.quoted(e.dir)) tiles=\(e.tiles) nodes=\(e.nodes) resident_max=\(e.k)"
            }
            return tiledResponse(
                "TILED LIST", sessionId: sessionId,
                "count=\(tiledRouters.count) " + parts.joined(separator: " ")
            )

        case .tiledClose(let id):
            guard tiledRouters[id] != nil else {
                return "ERROR not_found: tiled router \(Reply.quoted(id)) not found"
            }
            tiledRouters.removeValue(forKey: id)
            return tiledResponse("TILED CLOSE", sessionId: sessionId, "id=\(id) open=\(tiledRouters.count)")

        case .tiledTick(let id, let n, let sync):
            guard let entry = tiledRouters[id] else {
                return "ERROR not_found: tiled router \(Reply.quoted(id)) not found"
            }
            guard n >= 1 && n <= 10_000 else {
                return "ERROR out_of_range: n \(n) not in 1...10000"
            }
            if let e = alloc1dAdmit("TILED TICK", [], gpu: true) { return e }   // the pool's room
            let router = entry.router
            // The preflight holds every tile's ghosted load at once, whatever
            // K is: 1.1*(380 B per node + 1.4 MiB) per tile.
            if memoryBudget != nil, let m = try? runTiledSync({ await router.manifest }) {
                let pre = m.tiles.reduce(0.0) { $0 + Self.alloc1bPreflightTileBytes(nodes: $1.nodeCount, crossingsIn: $1.crossingsIn.count) }
                if let e = admit("TILED TICK", bytes: Self.newBytes(pre),
                                 what: "the preflight's \(m.tiles.count) tiles held at once, 1.1*(380 B per node + 996 B per"
                                     + " crossingsIn entry + 1.4 MiB) each") {
                    return e
                }
            }
            let mode: TickMode = sync ? .sync : .rank
            do {
                let report = try runTiledSync {
                    try await router.worldTick(mode: mode, count: n)
                }
                return tiledResponse(
                    "TILED TICK", sessionId: sessionId,
                    "id=\(id) ticks=\(report.epoch) tiles_ticked=\(report.tilesTicked) "
                        + "loads=\(report.loads) evicts=\(report.evicts) flushes=\(report.flushes) "
                        + "halo_bytes=\(report.haloBytes)"
                )
            } catch RouterError.tileGPUFailure(let g) {
                // A tile's command buffer did not
                // complete; that tile is not flushed and nothing is claimed.
                return "ERROR gpu: TILED TICK: \(g)"
            } catch RouterError.tileWriteFailed(let f) {
                // A write step failed, named; nothing after it
                // written; what a writer TILED OPEN will do is in the reply.
                return f.carriedReply ?? "ERROR io: TILED TICK: " + f.description   // a carried line under its own code
            } catch let err as RouterError {
                return Reply.errorLine("io", err)
            } catch {
                return Reply.errorLine("io", error)
            }

        case .tiledGetTruth(let id, let globalIdRaw):
            guard let entry = tiledRouters[id] else {
                return "ERROR not_found: tiled router \(Reply.quoted(id)) not found"
            }
            let router = entry.router
            let g = GlobalNodeID(raw: globalIdRaw)
            let before = try? runTiledSync({ await router.status() })
            do {
                let t = try runTiledSync { try await router.truth(of: g) }
                return tiledResponse(
                    "TILED GET", sessionId: sessionId, "id=\(id) node=\(globalIdRaw) truth=\(t)"
                )
            } catch RouterError.crossTileBoundsExceeded(_) {
                return "ERROR out_of_range: node \(globalIdRaw) not in 0..<\(entry.nodes)" + tiledCacheMoved(router, since: before)
            } catch TiledGraphFiles.FilesError.tileEntryMissing(_) {
                // The id names a tile the manifest does not hold: the node is out of range.
                return "ERROR out_of_range: node \(globalIdRaw) not in 0..<\(entry.nodes)" + tiledCacheMoved(router, since: before)
            } catch let fe as TiledGraphFiles.FilesError {
                // Every other files error (a corrupt meta.json, a manifest that cannot be
                // decoded) is the tile's own refusal, named; earlier builds answered out_of_range for node 0.
                return Reply.errorLine("io", verb: "TILED GET", fe) + tiledCacheMoved(router, since: before)
            } catch let err as RouterError {
                return Reply.errorLine("io", err) + tiledCacheMoved(router, since: before)
            } catch {
                return Reply.errorLine("io", error) + tiledCacheMoved(router, since: before)
            }

        default:
            // Every case this family handler is dispatched (see `handle`'s
            // and `handleReadOnly`'s TILED cases) is covered above; this
            // branch exists only for switch exhaustiveness.
            return "ERROR unknown_command: tiled verb not wired yet"
        }
    }
}
