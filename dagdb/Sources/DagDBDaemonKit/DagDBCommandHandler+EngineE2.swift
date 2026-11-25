/// DagDBCommandHandler+EngineE2 — the bulk verbs and the tick loop. Pipelined
/// connections are the socket layer's (`SocketServer`).
///
/// Equivalence first: each bulk verb runs, for every entry, the very checks
/// its single verb runs (`connectBackRefusal`, `setTruthRefusal` — the single
/// verbs call them too), in file order, before anything is written. The first
/// refused entry refuses the whole bulk with the single verb's own words, its
/// entry named, and nothing is written: no state, no WAL byte. An accepted
/// bulk is one WAL record, then the entries applied in file order — the state
/// N single commands leave.

import Foundation
import DagDB

extension DagDBCommandHandler {

    // MARK: - The single verbs' checks, shared

    /// Why `CONNECT BACK FROM src TO dst` is refused against the live state,
    /// in that verb's words, or nil. Reads only the destination's mode and
    /// combinational slots, never the back-edge list, so N entries checked
    /// against one state get the verdicts N commands in a row would.
    func connectBackRefusal(src: Int, dst: Int) -> String? {
        if let e = checkRange("src", src, upTo: nodeCount) { return e }
        if let e = checkRange("dst", dst, upTo: nodeCount) { return e }
        // The one rule set (`DagDBEngine.backEdgeRule`: self-loop,
        // then a ternary destination — a register
        // stays BINARY, before the fan-in rule — then a live combinational
        // slot), on the live lanes, in this verb's words
        // (`backEdgeRuleWords`); every loader runs the same function on its
        // staged lanes. The self-loop is decided before the mode lane is read:
        // reading `modeLane` allocates the ternary lanes on a binary graph, as
        // `validateBackEdge` always did here, and a self-loop never did.
        let s = UInt32(src), d = UInt32(dst)
        let rule: DagDBEngine.BackEdgeRule? = src == dst ? .selfLoop
            : DagDBEngine.backEdgeRule(src: s, dst: d, nodeCount: nodeCount, mode: engine.modeLane,
                                       neighbors: engine.neighborsBuf.contents().bindMemory(to: Int32.self, capacity: nodeCount * 6))
        guard let r = rule else { return nil }
        let w = DagDBEngine.backEdgeRuleWords(r, src: s, dst: d)
        return "ERROR \(w.category): \(w.words)"
    }

    /// A loader's list refused by an entry, in CONNECT BACK's words
    /// after its category: `ERROR schema: <VERB> <list> entry <i>: <words>;
    /// nothing <loaded>` (IMPORT MORTON's form).
    func backEdgeLoadRefusal(_ verb: String, _ r: DagDBEngine.BackEdgeEntryRefusal, nothing: String) -> String {
        "ERROR schema: \(verb) \(r.list) entry \(r.entry): \(r.words); nothing \(nothing)"
    }

    /// CONNECT's words for a combinational input into a register (the rule
    /// SET_NEIGHBORS_BULK shares).
    static func registerFanInWords(dst: Int) -> String {
        "back_edge_violation: node \(dst) is a BACK_EDGE destination (register); use CLEAR \(dst) BACK_EDGES first if you want a combinational input here"
    }

    /// A writer's S4 refusal names the way out
    /// with verbs that exist (`; the way out: CLEAR <dst> EDGES … or CLEAR
    /// <dst> BACK_EDGES …`); other back-edge rules add nothing.
    func slotIntoRegisterWayOut(_ r: DagDBEngine.BackEdgeEntryRefusal) -> String {
        guard case .destinationHasCombinationalInDegree = r.rule else { return "" }
        return "; " + DagDBEngine.slotIntoRegisterWayOut(dst: r.dst)
    }

    /// The daemon's writers (SAVE JSON, SAVE CSV, EXPORT
    /// MORTON, BACKUP INIT, BACKUP APPEND, SAVE TILED) refuse a state holding
    /// S4 — a slot into a register, which every loader refuses — by its list
    /// entry, in CONNECT BACK's words, naming the way out; nothing written.
    /// The library writers stay permissive.
    func slotIntoRegisterWriterRefusal(_ verb: String) -> String? {
        engine.liveSlotIntoRegisterRefusal(list: "back edge").map {
            backEdgeLoadRefusal(verb, $0, nothing: "written") + slotIntoRegisterWayOut($0)
        }
    }

    /// Why `SET node TRUTH value` is refused against the live state, in that
    /// verb's words, or nil. Reads only the node's mode (never its truth), so
    /// earlier entries of a bulk cannot change a later entry's verdict.
    func setTruthRefusal(node: Int, value: UInt8) -> String? {
        if let e = checkRange("node", node, upTo: nodeCount) { return e }
        // A ternary node holds 0..2; binary nodes keep
        // 0..255 for Loom event codes.
        if value >= 3 && TernaryReference.isTernary(engine.modeByte(node)) {
            return ternaryRefusal("SET TRUTH on ternary node \(node) accepts 0..2, not \(value)")
        }
        return nil
    }

    /// A bulk's refusal: the single's line with `<VERB> entry <i>: ` after its
    /// category, closed by `; nothing written`.
    func bulkRefusal(_ verb: String, entry i: Int, _ single: String) -> String {
        guard let r = single.range(of: ": ") else { return single + "; \(verb) entry \(i); nothing written" }
        return String(single[..<r.lowerBound]) + ": \(verb) entry \(i): "
            + String(single[r.upperBound...]) + "; nothing written"
    }

    /// The client's input frame (client_protocol 2): u32 count
    /// and u32 the verb's mark (0x314D4800 | v) at shm offset 0, the rows from
    /// offset 8; the row size (8) is the verb's. Returns the count, or the refusal.
    ///
    /// The count is word0 itself, so a capacity check on an unmarked header
    /// would check a stale number: the mark check stands first, in the place
    /// of the row-size check it replaces.
    func bulkFrame(_ input: InputVerb, rowSize want: Int) -> (count: Int, refusal: String?) {
        let verb = input.name
        let count = Int(shmBase.load(fromByteOffset: 0, as: UInt32.self))
        if let r = shm1FrameRefusal(input, count: count) { return (0, r) }
        // The capacity refusal keeps the shared words and adds the verb and
        // the close every bulk refusal carries.
        if let e = checkShmFits(rows: count, rowSize: want) {
            return (0, e + "; \(verb) count \(count) (row \(want)) does not fit; nothing written")
        }
        return (count, nil)
    }

    // MARK: - CONNECT_BACK_BULK

    func connectBackBulk() -> String {
        let verb = "CONNECT_BACK_BULK"
        let (count, bad) = bulkFrame(.connectBackBulk, rowSize: 8)
        if let bad = bad { return bad }
        // The edges' bytes, the staging pairs and the WAL record (16 B per row), and the lists'
        // copy when they grow, before the staging is built.
        if let e = admitBackEdges(verb, count: count, stagingBytesPerRow: 16) { return e }
        let rows = UnsafeRawPointer(shmBase.advanced(by: 8))
        var pairs: [(src: UInt32, dst: UInt32)] = []
        pairs.reserveCapacity(count)
        for i in 0..<count {
            let s = rows.load(fromByteOffset: 8 * i, as: UInt32.self)
            let d = rows.load(fromByteOffset: 8 * i + 4, as: UInt32.self)
            if let r = connectBackRefusal(src: Int(s), dst: Int(d)) { return bulkRefusal(verb, entry: i, r) }
            pairs.append((s, d))
        }
        if count > 0 {
            if let wal = walAppender {
                do { _ = try wal.connectBackBulk(pairs) }
                catch { return walAppendError(error) }
            }
            for p in pairs {
                // Range-checked above; `registerValidatedBackEdge` checks it again and cannot throw here.
                do { try engine.registerValidatedBackEdge(src: p.src, dst: p.dst) }
                catch { return Reply.errorLine("schema", error) }
            }
        }
        return "OK \(verb) edges=\(count) back_edges=\(engine.backEdgeCount)"
    }

    // MARK: - SET_TRUTH_BULK

    func setTruthBulk() -> String {
        let verb = "SET_TRUTH_BULK"
        let words = "u32 node, u8 value, 3 zero bytes"
        let (count, bad) = bulkFrame(.setTruthBulk, rowSize: 8)
        if let bad = bad { return bad }
        let rows = UnsafeRawPointer(shmBase.advanced(by: 8))
        var entries: [(node: UInt32, value: UInt8)] = []
        entries.reserveCapacity(count)
        for i in 0..<count {
            let node = rows.load(fromByteOffset: 8 * i, as: UInt32.self)
            let value = rows.load(fromByteOffset: 8 * i + 4, as: UInt8.self)
            // A row's pad must be zero: a u32 value written over u8 + pad is
            // refused here, never read as its low byte.
            for b in 5..<8 where rows.load(fromByteOffset: 8 * i + b, as: UInt8.self) != 0 {
                return "ERROR bad_value: \(verb) entry \(i): pad bytes 5..7 must be 0 (row: \(words)); nothing written"
            }
            if let r = setTruthRefusal(node: Int(node), value: value) { return bulkRefusal(verb, entry: i, r) }
            entries.append((node, value))
        }
        if count > 0 {
            if let wal = walAppender {
                do { _ = try wal.setTruthBulk(entries) }
                catch { return walAppendError(error) }
            }
            let p = engine.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: nodeCount)
            for e in entries { p[Int(e.node)] = e.value }       // file order: a repeated node, the last wins
            // What SET TRUTH marks, once (the truth index only;
            // a truth write moves no rank).
            truthRankIndex.markDirty()
        }
        return "OK \(verb) nodes=\(count)"
    }

    // MARK: - Truth-slice readback

    /// The truth bytes of the nodes `lo...hi` (by id), or of every node whose
    /// rank is in `lo...hi` (ascending id), packed into shm from offset 8,
    /// least significant bits first: header u32 node count, u32 bits per
    /// node. One bit per node on a graph with no ternary node whose slice
    /// holds only 0 and 1; two bits otherwise (the byte itself: 0, 1, 2). A
    /// byte of 3 or more (a Loom code) fits neither and is refused by name.
    ///
    /// This is the per-node loop — two passes, one node at
    /// a time, over the id range or the whole rank lane. The verb runs it for
    /// a rank range (lo < hi), for a rank with no rank list, and under the seam
    /// `truthSliceOldLoopForTesting`; the batched path (`truthSlice`,
    /// DagDBCommandHandler+EngineG2.swift) takes the rest. `raw` (BYTES): the
    /// same loop with 8 bits per node — each byte stored whole, none refused.
    func truthSliceE2Loop(byRank: Bool, lo: UInt64, hi: UInt64, raw: Bool, engine e: DagDBEngine, nodeCount n: Int,
                          sessionId: String?) -> String {
        guard lo <= hi else { return "ERROR out_of_range: range \(lo)-\(hi) is empty (lo > hi)" }
        let truth = e.truthStateBuf.contents().bindMemory(to: UInt8.self, capacity: max(n, 1))
        let rank = e.rankBuf.contents().bindMemory(to: UInt64.self, capacity: max(n, 1))
        let idLo: Int, idHi: Int
        if byRank {
            idLo = 0; idHi = n - 1
        } else {
            // The line names the value the caller sent, not a clamp of it.
            if hi >= UInt64(n) { return "ERROR out_of_range: node \(hi) not in 0..<\(n)" }
            idLo = Int(lo); idHi = Int(hi)
        }
        @inline(__always) func inSlice(_ i: Int) -> Bool { !byRank || (rank[i] >= lo && rank[i] <= hi) }
        // Pass 1: count, the first and last id, the widest byte.
        var count = 0, first = -1, last = -1, wide = false
        if idLo <= idHi {
            for i in idLo...idHi where inSlice(i) {
                let v = truth[i]
                if v >= 3 && !raw {
                    return "ERROR bad_value: TRUTH_SLICE node \(i) truth \(v) does not fit 2 bits (0, 1, 2); read it with NODES or GET"
                }
                if v == 2 { wide = true }
                if first < 0 { first = i }
                last = i; count += 1
            }
        }
        let bits = raw ? 8 : ((e.nonBinaryNodeCount == 0 && !wide) ? 1 : 2)
        let bytes = (count * bits + 7) / 8
        if let r = checkShmFits(rows: bytes, rowSize: 1) { return r }
        let h = shmBase.bindMemory(to: UInt32.self, capacity: 2)
        h[0] = UInt32(count); h[1] = UInt32(bits)
        let out = shmBase.advanced(by: 8).bindMemory(to: UInt8.self, capacity: max(bytes, 1))
        if bytes > 0 { memset(out, 0, bytes) }
        // Pass 2: pack.
        var k = 0
        if count > 0 {
            for i in first...last where inSlice(i) {
                let bit = k * bits
                out[bit >> 3] |= truth[i] << UInt8(bit & 7)
                k += 1
            }
        }
        let session = sessionId.map { " session=\($0)" } ?? ""
        return "OK TRUTH_SLICE\(session) nodes=\(count) format=\(bits == 1 ? "bits" : (bits == 2 ? "trits" : "bytes")) bits_per_node=\(bits)"
            + " shm_bytes=\(bytes) first=\(first < 0 ? "-" : String(first)) last=\(last < 0 ? "-" : String(last))"
    }

    // MARK: - TICK UNTIL_STABLE [MAX k]

    /// Rank-mode TICK, one at a time, until a tick changes no truth byte and
    /// no register latch, at most `max` ticks. `ticks=` counts the ticks that
    /// changed something (0 on a graph already stable); `run=` the ticks run,
    /// the last one included (the tick that found the fixed point, or the
    /// MAX-th); `changed=` the truth bytes the last tick changed (registers
    /// included), `latched=` the registers the last tick's latch changed —
    /// counted by the latch from its own writes. The tick total moves by
    /// `run`, as `run` single TICKs would move it.
    ///
    /// The ticks run through the engine's frontier session
    /// (`DagDBEngine.frontierSession`), `untilStableBatchTicks` (k) per
    /// command buffer (`DagDBEngine.sessionTicks`; each batch min(k, MAX −
    /// ticks run)), each tick's two counts read after its batch; the verb
    /// stops at the first tick whose counts are both 0, or at MAX. Ticks a
    /// batch ran after that one ran from a fixed point and changed no byte;
    /// they are not counted in `run` or the tick total.
    /// `nodes_computed=` is the honest count: the node slots
    /// the session's rank dispatches covered.
    ///
    /// (1) The batches of one call ramp up — 1,
    /// 2, 4, 8, then k (16), each min(·, MAX − ticks run) — so a graph
    /// already stable encodes one tick, and ticks encoded ≤ 2·run; the
    /// engine caps a batch at 131,072 dispatches (at least one tick). (2)
    /// Every command buffer's status is checked after its wait; one that did
    /// not complete ends the call with `ERROR gpu:` by name, nothing claimed
    /// (the tick total counts the ticks of the buffers that completed). (3)
    /// The depth guard: on a graph with more than R* non-empty rank levels
    /// the session runs the counting path without the frontier (`DagDBEngine.frontierMaxRankLevels`).
    func tickUntilStable(maxTicks: Int?) -> String {
        let k = maxTicks ?? Self.tickCap
        if let e = checkCap("MAX", k, 1, Self.tickCap) { return e }
        if let e = checkTickHeadroom(k) { return e }
        if let why = rankTickDagRefusal() {
            return "ERROR invalid_graph: rank-mode TICK refused, validation: \(why) "
                + "(VALIDATE names it; TICK_SYNC is defined on this graph)"
        }
        if let e = alloc1dAdmitUntilStable() { return e }
        if let e = rankListRefusal() { return e }
        engine.ensureRankTopology()                                        // count = MAX
        if let e = admitTickWork("TICK UNTIL_STABLE", count: k, levels: engine.nonEmptyRankLevels, latch: .counting) { return e }
        let t0 = CFAbsoluteTimeGetCurrent()
        var run = 0, changing = 0, changed = 0, latched = 0, stable = false
        var evaluated = 0, batches = 0, waits = 0, gpuMs = 0.0, frontierActive = false
        var tOpen = t0, tBody = t0
        let preF = untilStablePreFForTesting
        let batchMax = max(1, untilStableBatchForTesting ?? Self.untilStableBatchTicks)
        let indexBuilds0 = engine.frontierIndexBuildCount
        let kernelsReady0 = engine.frontierPipelinesReady
        var failure: DagDBEngine.CommandBufferFailure? = nil
        var encodedTicks = 0, maxBufferTicks = 0, maxMultiDispatches = 0
        engine.clearGPUFailure()
        // Each tick's counts come from the tick itself — the
        // counting kernel's changed-node count and the latch's own count
        // (`DagDBEngine.LatchChangeCounter`) — with no copy or scan of the
        // truth buffer. `changed` is the same number a byte compare gives:
        // the bytes that differ after the tick from before it.
        do {
            try engine.countingLatchChanges(frontier: !preF) { counter in
                tOpen = CFAbsoluteTimeGetCurrent()
                frontierActive = counter.frontierActive
                if preF {
                    // Test seam: the pre-frontier loop, one tick per command buffer.
                    for _ in 0..<k {
                        counter.lastCount = 0
                        engine.tick(tickNumber: tickCount, rankOrderVerified: true)   // refusal checked above
                        if let f = engine.gpuFailure { failure = f; break }           // nothing claimed
                        tickCount += 1
                        run += 1
                        latched = counter.lastCount
                        changed = counter.lastChanged
                        if changed == 0 && latched == 0 { stable = true; break }
                        changing += 1
                    }
                } else {
                    // Batches of ticks; each tick's counts as above.
                    // The ramp 1, 2, 4, …, k.
                    var ramp = 1
                    while run < k && !stable {
                        let batch = engine.sessionTicks(min(ramp, batchMax, k - run), tickNumber: tickCount)
                        ramp = min(2 * ramp, batchMax)
                        batches += 1
                        if let f = batch.failure ?? engine.gpuFailure { failure = f; break }
                        evaluated += batch.evaluated
                        if batch.ticks.isEmpty { break }
                        for t in batch.ticks {
                            tickCount += 1
                            run += 1
                            latched = t.latched
                            changed = t.changed
                            if changed == 0 && latched == 0 { stable = true; break }
                            changing += 1
                        }
                    }
                }
                waits = counter.gpuWaits
                gpuMs = counter.gpuMs
                encodedTicks = counter.ticksEncoded
                maxBufferTicks = counter.maxBufferTicks
                maxMultiDispatches = counter.maxMultiTickBufferDispatches
                tBody = CFAbsoluteTimeGetCurrent()
            }
        } catch {
            // The counter or the marks could not be
            // allocated; both are refused before the body runs. The session's
            // other refusals (nested, layout changed) cannot arise here: this
            // verb opens one session and its body only ticks.
            return "ERROR resource: TICK UNTIL_STABLE refused: \(Reply.errorWords(error)); nothing ticked"
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        truthRankIndex.markDirty()   // a tick rewrites truth
        lastUntilStableGPUWaits = waits
        lastUntilStableBatches = preF ? run : batches
        let nodesComputed = preF ? engine.rankDispatchNodeCount() * run : evaluated
        lastUntilStableEvaluated = nodesComputed
        lastUntilStableTicksEncoded = encodedTicks
        lastUntilStableMaxBufferTicks = maxBufferTicks
        lastUntilStableMaxMultiTickBufferDispatches = maxMultiDispatches
        lastUntilStableFrontier = frontierActive
        lastUntilStableRankLevels = engine.nonEmptyRankLevels
        if let log = frontierTestLog {                                     // test seam
            let bytes = engine.allocationBytes().filter { $0.name.hasPrefix("frontier.") || $0.name.hasPrefix("latch.") }
            let total = bytes.reduce(0) { $0 + $1.bytes }
            func ms(_ x: Double) -> String { String(format: "%.3f", x) }
            log("until_stable: run=\(run) stable=\(stable) pre_f=\(preF) frontier=\(frontierActive)"
                + " batch_max=\(batchMax) batches=\(lastUntilStableBatches) gpu_waits=\(waits) gpu_ms=\(ms(gpuMs))"
                + " evaluated=\(nodesComputed) elapsed_ms=\(ms(elapsed)) open_ms=\(ms((tOpen - t0) * 1000))"
                + " ticks_ms=\(ms((tBody - tOpen) * 1000))"
                + " index_built=\(engine.frontierIndexBuildCount - indexBuilds0) index_builds=\(engine.frontierIndexBuildCount)"
                + " last_index_build_ms=\(ms(engine.lastFrontierIndexBuildMs))"
                + " kernels_made=\(!kernelsReady0 && engine.frontierPipelinesReady)"
                + " kernel_build_ms=\(ms(engine.frontierPipelineBuildMs))"
                + " ticks_encoded=\(encodedTicks) max_buffer_ticks=\(maxBufferTicks)"
                + " max_multi_buffer_dispatches=\(maxMultiDispatches) levels=\(engine.nonEmptyRankLevels)"
                + " depth_guard=\(engine.frontierMaxRankLevels == Int.max ? "inf" : String(engine.frontierMaxRankLevels))"
                + " guarded=\(engine.lastFrontierDepthGuarded) gpu_failure=\(failure.map { $0.status } ?? "none")"
                + " bytes_total=\(total) nodes=\(nodeCount) "
                + bytes.map { "\($0.name)=\($0.bytes)" }.joined(separator: " "))
        }
        if let f = failure {
            return gpuFailureReply("TICK UNTIL_STABLE", f, tick: run + 1, of: nil)
        }
        let head = stable ? "OK TICK UNTIL_STABLE stable" : "OK TICK UNTIL_STABLE not stable after MAX \(k)"
        return head + " ticks=\(changing) run=\(run) changed=\(changed) latched=\(latched)"
            + " elapsed=\(String(format: "%.2f", elapsed))ms total=\(tickCount)"
            + rankWorkSuffix(nodesComputed: nodesComputed, rankDispatched: true)
    }
}
