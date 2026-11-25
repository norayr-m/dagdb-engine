import Foundation

/// The charges a live verb admits and a
/// restore, a replay or a SAVE admits for the same object, one formula each, so the two sides cannot drift. Each
/// returns the bytes BEFORE the 10 % margin: the admission closures multiply (the handler's `fileAdmission`, the
/// boot's admission), exactly as they do for a file's own bytes.
///
/// Amateur engineering project; no competitive claims; errors likely.
public enum AdmissionCharge {
    /// The margin every charge is admitted at (measured factor + 10 %).
    public static let margin = 1.1

    /// ALARM LOAD: 8.6 B per file byte + 300 KB, the file read and parsed (measured).
    public static func alarmLoad(fileBytes f: Int) -> Double { 8.6 * Double(f) + 300_000 }
    /// VIEW LOAD: 4.0 B per file byte + 1 MiB, the file read and decoded.
    public static func viewLoad(fileBytes f: Int) -> Double { 4.0 * Double(f) + 1_048_576 }
    /// KERNEL LOAD: 4.2 B per file byte + 64 KiB, the file read and parsed.
    public static func kernelLoad(fileBytes f: Int) -> Double { 4.2 * Double(f) + 65_536 }

    /// A bank's atoms, 4*T*K (BANK OPEN's resident, the budget ledger's term).
    public static func bankAtoms(T: Int, K: Int) -> Double { 4 * Double(T) * Double(K) }
    /// HOOK OPEN: a hook's index of its alarm's records, 260 B per record + 4 KB (107-254 B measured).
    /// A restored hook is charged its whole live charge: LOAD and replay rebuild this index too, from the restored
    /// alarm set, before the rows are re-stepped.
    public static func hookIndex(records: Int) -> Double { 260 * Double(max(records, 0)) + 4096 }
    /// A hook's re-stepped ledger rows, 2 x the row's stride each (the copy-on-write capacity CLOCK
    /// ADVANCE admits: 2 x 104 B).
    public static func hookRows(_ rows: Int) -> Double {
        2 * Double(MemoryLayout<AttentionHook.Row>.stride) * Double(max(rows, 0))
    }

    /// LOAD's and the startup load's back-edge staging beyond the file's bytes (the staged
    /// src/dst arrays and the lists they are committed into): measured 8.0 B per edge + 0.27 MB as the fit, every row
    /// at or under 8.1 B per edge + 256 KiB (393,216-3,145,728 edges, LOAD and the startup load); the margin's 1.1 is
    /// the caller's.
    public static let backEdgeStagingPerEdge = 8.1
    public static func backEdgeStaging(edges: Int) -> Double { backEdgeStagingPerEdge * Double(max(edges, 0)) + 262_144 }

    /// The LOAD family's floor (LOAD, LOAD JSON, LOAD CSV, BACKUP RESTORE, the startup load): every
    /// charge a load admits is at least this, before the margin, so at least 1.1 x it. The worst empty-twin LOAD peak
    /// measured, whatever the file: 311,296 to 409,600 B over 18 runs at grid 64 (it moves with the allocator's state
    /// from run to run; 409,600 B once, 393,216 B twice, in the last five): a floor for the load's own fixed
    /// transient, which 1.1 x a tiny file sits under, as the budget's two-page floor is for other charges.
    public static let loadFamilyFloorBytes = 409_600
    /// The family's admission over `a` (bytes before the margin, what): each charge raised to the floor, named when it is.
    public static func loadFamilyFloored(_ a: @escaping (Int, String) -> String?) -> (Int, String) -> String? {
        { bytes, what in
            bytes >= loadFamilyFloorBytes ? a(bytes, what)
                : a(loadFamilyFloorBytes, "\(what), floored at the LOAD family's \(loadFamilyFloorBytes) B")
        }
    }

    /// LOAD's twin-section decode, 58.3 B per token: the largest LOAD peak per token measured (the streams row;
    /// 32.4-58.3 over every kind measured).
    public static let twinDecodePerToken = 58.3
    /// SAVE's twin-section encode, first measured at 68.7 B per token (the largest SAVE peak per token, layouts of
    /// random f64s; 48.7-68.7 over every kind measured), the JSONEncoder tree, the encoded bytes and their copy.
    /// Re-measured over every token class, 24-character doubles included, the worst taken: the
    /// SAVE peak net of an empty-twin SAVE, less e x S, over T reads 78.93 B per token on 16 layouts of 20 x 600
    /// 24-character doubles (49.3-63.5 on random doubles, rings, records, streams, gears), so 79.0.
    public static let twinEncodePerToken = 79.0
    /// SAVE's bytes per escaped string byte (S, `TwinState.exportStringBytes`): 2.80-2.91 measured on 1,024
    /// stream names of 4,000 '/' (escaped to 8,000), of 'a', of '"\\', 512 of 2,000 'é', and 1,023 gear names of
    /// 4,000 '/'; 2.95 rounded up.
    public static let twinEncodePerStringByte = 2.95
    /// SAVE's twin-section charge before the margin, t_s x T + e x S.
    public static func twinEncode(tokens t: Int, stringBytes s: Int) -> Double {
        twinEncodePerToken * Double(t) + twinEncodePerStringByte * Double(s)
    }
    /// LOAD's bytes per twin-section byte (F): (LOAD peak - the file - 58.3 x T) / F reads at most 1.2524, on
    /// 1,000 stream names of 64 KiB (a crafted file; 1.0745 at 100 x 256 KiB, 1.00-1.06 on 4,000-byte
    /// and escaped names, 0.73-0.78 on daemon-written '/' names), so 1.26; with it every token class reads under
    /// the 58.3 B per token kept (at most 50.8).
    public static let twinDecodePerByte = 1.26
    /// LOAD's twin-section decode before the margin, t_l x T + b x F (TILED OPEN's form).
    public static func twinDecode(tokens t: Int, bytes f: Int) -> Double {
        twinDecodePerToken * Double(t) + twinDecodePerByte * Double(f)
    }

    // MARK: - The last unadmitted allocations

    /// The Metal pool, a fixed reservation in the fixed state. 1.1 x 117,702,656 B, the largest pool measured
    /// on this machine (M5 Max; vmmap "Owned physical footprint (unmapped) (graphics)"): 112.23-112.25 MiB at every grid
    /// from 64 to 2048, on every GPU verb, under a second daemon's GPU load (re-measured at 112.234-112.250 MiB
    /// over 19 flat rows). A daemon whose first GPU
    /// command measures a larger pool raises it (`DaemonMemoryBudget.raisePoolReservation`).
    public static let metalPoolMeasuredBytes = 117_702_656
    public static let metalPoolReservationBytes = 129_472_922

    /// The JSON loaders' one token charge (ALARM LOAD, KERNEL LOAD, LOAD JSON, and the restore's and replay's re-reads
    /// of the first two), in TILED OPEN's manifest form: b x F before the read, the whole t x T + b x F before the
    /// parse, on the bytes read. t = 98.4 B per token, b = 2.52 B per byte: the fit over every file measured (t 98.33
    /// needed at b 2.52, the 16-character-key file on ALARM LOAD), re-measured 98.22 on this build, so kept.
    public static let jsonParsePerToken = 98.4
    public static let jsonParsePerByte = 2.52
    public static func jsonRead(fileBytes f: Int) -> Double { jsonParsePerByte * Double(max(f, 0)) }
    public static func jsonParse(tokens t: Int, fileBytes f: Int) -> Double {
        jsonParsePerToken * Double(max(t, 0)) + jsonParsePerByte * Double(max(f, 0))
    }

    /// The tick verbs' transients and the latch plan's resident (measured, then re-measured on this build).
    /// The CPU latch's snapshot, 1.005 B per back edge measured (M bytes and a page) -> 1.01;
    /// the GPU latch plan's build, calloc(N) + malloc(8M) (0.993 of 8M + N measured); the counting session (TICK
    /// UNTIL_STABLE), N + 11.31 B per distinct destination measured (11.2 first) -> 11.4; the plan's resident, 20.27-21.84
    /// B per distinct destination net of the no-edge control (20.25-21.51 first) -> 21.9, charged at min(M, N) before the
    /// build and at the plan's own destination count in the ledger.
    public static let cpuLatchPerEdge = 1.01
    public static func cpuLatch(backEdges m: Int) -> Double { cpuLatchPerEdge * Double(max(m, 0)) }
    public static func latchPlanBuild(backEdges m: Int, nodes n: Int) -> Double { 8 * Double(max(m, 0)) + Double(max(n, 0)) }
    public static let latchPlanResidentPerDestination = 21.9
    public static func latchPlanResident(destinations d: Int) -> Double { latchPlanResidentPerDestination * Double(max(d, 0)) }
    public static let countingSessionPerDestination = 11.4
    public static func countingSession(nodes n: Int, destinations d: Int) -> Double {
        Double(max(n, 0)) + countingSessionPerDestination * Double(max(d, 0))
    }

    /// First-use allocations (measured, then re-measured on this build), each the largest per-node reading plus the
    /// fixed part the small grids show:
    /// - the ternary lanes: 11.00-11.02 B per node (11.25 at 65,536 nodes: four buffers, each up to a 16 KiB page);
    /// - the rank table (STATUS's `rebuildCompaction`, built now only by the verbs that need it): peak 12.05 B per node
    ///   at 16 levels, 220.64 B per node at N levels, 92 B per node at 4,096 nodes and 1,024 levels: 12.1 N + 208.6 L +
    ///   128 KiB covers every row; kept 112.30-112.42 B per level (malloc) -> 112.5;
    /// - SELECT's TruthRankIndex: peak 32.05-32.16 B per node (36 at 4,096 nodes), kept 16.04-16.13 -> 16.2;
    /// - BFS_DEPTHS: 56.06-56.20 B per node (68 at 4,096 nodes);
    /// - what the first TICK, TICK_SYNC and TICK UNTIL_STABLE leave: 4.15-4.63 B per node + about 0.62 MB (the rank lists
    ///   and their Metal state), 0.98-1.0 B per node, 10.3-12.4 B per node (14.3 at 65,536 nodes, the frontier's state).
    public static func ternaryLanes(nodes n: Int) -> Double { 11 * Double(max(n, 0)) + 65_536 }
    public static func rankTableBuild(nodes n: Int, levels l: Int) -> Double { 12.1 * Double(max(n, 0)) + 208.6 * Double(max(l, 0)) + 131_072 }
    public static func rankTableKept(levels l: Int) -> Double { 112.5 * Double(max(l, 0)) }
    public static func truthIndexBuild(nodes n: Int) -> Double { 32.2 * Double(max(n, 0)) + 65_536 }
    public static func truthIndexKept(nodes n: Int) -> Double { 16.2 * Double(max(n, 0)) }
    public static func bfsDepths(nodes n: Int) -> Double { 56.3 * Double(max(n, 0)) + 65_536 }
    public static func firstTickBuffers(nodes n: Int) -> Double { 4.7 * Double(max(n, 0)) + 680_960 }
    public static func firstTickSyncBuffers(nodes n: Int) -> Double { 1.0 * Double(max(n, 0)) + 32_768 }
    public static func firstUntilStableBuffers(nodes n: Int) -> Double { 12.4 * Double(max(n, 0)) + 131_072 }

    /// BACKUP RESTORE (measured at grids 256-1024, a default and a heavy base of
    /// 3N back edges and ternary lanes, 0, 1 and 3 diffs, each on a process whose lifetime maximum rose): the scratch
    /// engine and the replayed tip, 200.8-221.9 B per node -> 222; the base read into it, 3.453 B per base byte (the
    /// heavy base, net of 222 B per node) -> 3.46; a chain with diffs decodes one diff at a time into whole segments,
    /// 63.3 B per node more and 2.322 B per diff byte (the heavy diff, net) -> 64 and 2.33, charged on the sum of the
    /// diffs (the peak did not grow from 1 diff to 3).
    public static func backupRestore(nodes n: Int, baseBytes b: Int, diffBytes d: Int, diffs k: Int) -> Double {
        let N = Double(max(n, 0))
        return 222 * N + 3.46 * Double(max(b, 0)) + (k > 0 ? 64 * N + 2.33 * Double(max(d, 0)) : 0)
    }

    /// SAVE's body (measured at grids 64-2048, plain and compressed, with 3N back edges and with
    /// ternary lanes). Plain: the body streams from the buffers; the digest re-reads the file in at most 8 MiB, and the
    /// back-edge section is built in memory (9.9 B per edge measured at 196,608 edges; 16 charged, the section's growth),
    /// over a fixed 254-278 KB -> 320 KiB. Compressed: the gathered body, its deflate and the check's inflate, 126.27 B
    /// per node for a v7 body (3 x 42) and 159.33 for a v8 one (3 x 53), on top of the plain terms.
    public static func saveBody(compressed: Bool, nodes n: Int, v8: Bool, backEdges m: Int, libraryBytes lib: Int) -> Double {
        let N = Double(max(n, 0)), M = Double(max(m, 0))
        let file = (Double(v8 ? 53 : 42) + 34) * N + 8 * M + Double(max(lib, 0)) + 1_048_576
        let plain = min(file, 8_388_608) + 16 * M + 327_680
        return plain + (compressed ? 3 * Double(v8 ? 53 : 42) * N : 0)
    }

    // MARK: - The read verbs and the writers that once admitted nothing

    /// Each the measured peak (grids 256, 1024, 2048, a fresh daemon per row, the
    /// shape that maximizes it) per node and per row, member or level, rounded up, plus 64 KiB for the small grids' pages.
    /// GRAPH INFO: the rank and truth lanes read (9.0 B/node, all ranks 0) and a count per distinct rank and its words
    /// (64.34-64.50 B/node with N distinct ranks): 9.1 N + 55.5 L, L the distinct ranks' bound (levels).
    public static func graphInfo(nodes n: Int, levels l: Int) -> Double { 9.1 * Double(max(n, 0)) + 55.5 * Double(max(l, 0)) + 65_536 }
    /// NODES [AT RANK r]: the two lanes read and 32.1 B per row (40.12-41.05 B/node with every node a row).
    public static func nodesRead(nodes n: Int, rows r: Int) -> Double { 9.1 * Double(max(n, 0)) + 32.1 * Double(max(r, 0)) + 65_536 }
    /// TRAVERSE: the two lanes and 42.5 B per node visited (50.88-51.55 B/node with every node visited); visited is at
    /// most min(N, 3d(d+1) + 1) on the hex grid at depth d.
    public static func traverse(nodes n: Int, visited v: Int) -> Double { 9.1 * Double(max(n, 0)) + 42.5 * Double(max(v, 0)) + 65_536 }
    /// ANCESTRY: the backward BFS and its pairs (16.02-16.08 B/node with every node an ancestor).
    public static func ancestry(nodes n: Int) -> Double { 16.1 * Double(max(n, 0)) + 65_536 }
    /// SIMILAR_DECISIONS: the query's BFS, sets and histogram, the candidates, one candidate's BFS at a time
    /// (68.82-68.92 B/node, every node an ancestor of the query and of each candidate).
    public static func similarDecisions(nodes n: Int) -> Double { 69.0 * Double(max(n, 0)) + 65_536 }
    /// DISTANCE (every metric but spectralL2, which is admitted elsewhere): the two subgraphs' sets (reserved at N/4 each,
    /// 11 B/node by the code) and per member: 20.35 (jaccardNodes, jaccardEdges, rankL1, rankL2, typeL1), 24.40
    /// (boundedGED), 32.42 (wlL1) measured with |A| = |B| = N.
    public static func distancePerMember(_ metric: String) -> Double {
        switch metric { case "wlL1": return 32.5; case "boundedGED": return 24.5; default: return 20.4 }
    }
    public static func distance(metric: String, nodes n: Int, members m: Int) -> Double {
        11 * Double(max(n, 0)) + distancePerMember(metric) * Double(max(m, 0)) + 65_536
    }
    /// VALIDATE's register check, a [Bool] of N (masked in every measurement: the boot's own peak is higher), by the code.
    public static func validateRead(nodes n: Int) -> Double { Double(max(n, 0)) + 262_144 }
    /// EVAL's reads after its tick: roots, the two lanes, the rows (48.03-48.09 B/node, every node a root).
    public static func evalRead(nodes n: Int) -> Double { 48.1 * Double(max(n, 0)) + 65_536 }
    /// SAVE JSON (490.6-492.5 B/node), SAVE CSV (84.1-87.0), BACKUP APPEND (413.4-418.8), BACKUP COMPACT (324.1-328.4);
    /// BACKUP INIT is a compressed snapshot (126.1-127.0 B/node), charged as SAVE COMPRESSED's body (`saveBody`).
    public static func saveJSON(nodes n: Int) -> Double { 493.0 * Double(max(n, 0)) + 65_536 }
    public static func saveCSV(nodes n: Int) -> Double { 87.1 * Double(max(n, 0)) + 65_536 }
    public static func backupAppend(nodes n: Int) -> Double { 419.0 * Double(max(n, 0)) + 65_536 }
    public static func backupCompact(nodes n: Int) -> Double { 329.0 * Double(max(n, 0)) + 65_536 }
    /// SAVE TILED: 106.6-109.2 B/node at grids 1024 and 2048 (on the way to its own refusal: the world's node count does
    /// not fit the Morton columns there), 17.17 MB at grid 256 (written): 110 N + 10.5 MB.
    public static func saveTiled(nodes n: Int) -> Double { 110.0 * Double(max(n, 0)) + 10_500_000 }

    /// The frontier's index by its real size (its buffers' lengths, `DagDBEngine.frontierIndexBytesBound`) instead
    /// of the flat 12.4 B/node of the first-use charge: with six inputs on most nodes it holds about 33 B/node (frontier
    /// blocks: 173.95 MB resident at grid 2048 with the rank lists). 1.01 x the buffers + 128 KiB (12.36 B/node measured against
    /// 12.25 by the buffers with no edges).
    public static func frontierIndex(bufferBytes b: Int) -> Double { 1.01 * Double(max(b, 0)) + 131_072 }

    /// The JSON token count, its , : [ { bytes plus 1: an upper bound on its values and keys (a separator inside a
    /// string only raises it), counted with no allocation. The pre-scan TILED OPEN admits its manifest by;
    /// a snapshot's twin section is counted with it too.
    public static func jsonTokens(_ data: Data) -> Int {
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Int in
            var c = 0
            for x in p { c &+= (x == 0x2C || x == 0x3A || x == 0x5B || x == 0x7B) ? 1 : 0 }
            return c + 1
        }
    }
}
