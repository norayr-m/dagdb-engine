#!/usr/bin/env python3
"""DagDB MCP Server — expose the graph engine as MCP tools for LLMs.

Any LLM connected via MCP can query, evaluate, and manipulate the graph.

Tools:
  dagdb_status            — daemon status
  dagdb_tick              — run N ticks
  dagdb_query             — send any DSL command
  dagdb_nodes             — list nodes at a rank
  dagdb_traverse          — walk the graph from a node
  dagdb_set               — set truth/rank/LUT on a node
  dagdb_connect           — wire a combinational edge
  dagdb_clear_edges       — clear combinational edges into a node
  dagdb_connect_back      — register a typed BACK_EDGE (synchronous-circuit register)
  dagdb_clear_back_edges  — remove BACK_EDGEs into a node
  dagdb_graph             — graph info
  dagdb_hex               — ASCII hex table view
  dagdb_show              — full ASCII visualization

  Twin (the interface phase — twin-spec primitives, daemon-global registries):
  dagdb_stream_open/next/state/close       — named PCG stream generator
  dagdb_header_check                       — comb-record admissibility check
  dagdb_record_open/slice/replay/verify    — replayable draw-slice ledger
  dagdb_rings_open/write/recall            — geared ring-buffer recall
  dagdb_clock_open/advance/state           — master tick clock
  dagdb_gear_open/state                    — phase gear driven by a clock
  dagdb_xconv_check                        — cross-convolution residual check
  dagdb_budget_sealed/open/allocate        — sealed/custom budget-layout allocator
  dagdb_alarm_load/frame/court/successor/corrupt — alarm-stream fixture + courts
  dagdb_bank_open/generate/fit/noise/bench/info    — spec 8 waveform mouth (frozen bank, W = bank × coefficients)
  dagdb_view_load/reflex/rung/ceiling/features/info — alarm-set derived views over the sealed cortex v4 world
  dagdb_kernel_load/info + dagdb_xconv_sealed      — per-path kernel storage + the court's sealed cross-convolution residual (gates K3/K4)
  dagdb_hook_open/step/state/ledger/info   — attention hook: the sealed allocator court as a ticked process (gate H5)
  dagdb_twin_list/dagdb_twin_close         — cross-registry list/close by id prefix
  dagdb_fold_run/kept/source/tier/info     — gate F4 tier-ladder fold over the CURRENT fabric lanes (no registry, nothing persisted)

  Tiled (steps one and two, gate T5 + ticking across tiles — NOT a twin registry):
  dagdb_save_tiled                            — split the daemon's CURRENT graph into tile files by rank range
  dagdb_tiled_open/bfs/select/status/close    — cross-tile router: load-on-demand tiles, BFS/ancestry/select across them
  dagdb_tiled_tick/get_truth                  — advance the world across tiles (durable, per-tile flush) / read one node's truth

Usage: python3 mcp_server.py
Requires: pip install mcp
Daemon must be running: ./dagdb start --data sample_db/
"""

import re
import socket
import json
import sys
import os

# Check for mcp package. Do NOT auto-install — installing packages as an
# import side effect (especially with --break-system-packages) is a
# supply-chain footgun and mutates system Python. Print instructions and exit.
try:
    from mcp.server.fastmcp import FastMCP
except ImportError:
    sys.stderr.write(
        "DagDB MCP server requires the 'mcp' package.\n"
        "Install it yourself in the environment you run this from:\n"
        "    pip install 'mcp[cli]'\n"
    )
    sys.exit(1)

DAEMON_SOCK = os.environ.get("DAGDB_SOCK", "/tmp/dagdb.sock")

# Gate D4, audit B findings 1 and 27. The daemon frames a command at
# MAX_COMMAND_BYTES plus a newline; a line that reaches the cap without a
# newline is refused, never parsed. Before that fix the daemon answered OK
# over the truncated prefix, so this client could not tell a complete
# command from a truncated one. It refuses here, in the daemon's wording.
MAX_COMMAND_BYTES = 4095
TOO_LONG = f"ERROR too_long: command exceeds {MAX_COMMAND_BYTES} bytes"

def query_daemon(cmd: str) -> str:
    """Send a command to the daemon and return the response."""
    # Reject control characters (Fable review S3, defense-in-depth). The
    # daemon contract is one command per connection; an embedded newline in a
    # path argument could smuggle a second command line. Legitimate commands
    # and paths never contain control chars.
    if any(ord(c) < 0x20 and c not in "\t" for c in cmd.strip()):
        return "ERROR: command contains control characters"
    if len(cmd.strip().encode()) > MAX_COMMAND_BYTES:
        return TOO_LONG
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(10)
        s.connect(DAEMON_SOCK)
        s.sendall((cmd.strip() + "\n").encode())
        s.shutdown(socket.SHUT_WR)
        response = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            response += chunk
        s.close()
        return response.decode().strip()
    except Exception as e:
        return f"ERROR: {e}"

# Twin registries (interface phase, 2026-09). Ids are minted by the daemon as "<letter>%08x"
# from a per-registry counter (§0.14): s stream, t record, n rings, c
# clock, g gear, b budget layout, a alarm set, w wave bank (spec 8, the interface phase),
# v derived-view set (spec line 4 second view family), k kernel pair
# (spec line 6 second half, gates K3/K4), h attention hook (gate H5,
# docs/contracts/HOOK_GATES_FROZEN.md). Wrappers below validate any id
# argument against this shape client-side, before touching the socket — a
# malformed id can never be a legitimate reply from any registry, so there
# is nothing to gain by round-tripping it to the daemon.
_TWIN_ID_RE = re.compile(r"^[stncgbawvkh][0-9a-f]{8}$")
_TWIN_PREFIX_VERB = {
    "s": "STREAM", "t": "RECORD", "n": "RINGS", "c": "CLOCK",
    "g": "GEAR", "b": "BUDGET", "a": "ALARM", "w": "BANK", "v": "VIEW",
    "k": "KERNEL", "h": "HOOK",
}

def _bad_twin_id(id: str):
    """Return an "ERROR bad_id: ..." string if `id` doesn't match the twin
    id shape, else None. No daemon round-trip on mismatch."""
    if not _TWIN_ID_RE.match(id or ""):
        return f"ERROR bad_id: {id!r} does not match ^[stncgbawvkh][0-9a-f]{{8}}$"
    return None

# Create MCP server
mcp = FastMCP("dagdb", instructions="""
DagDB is a 6-bounded ranked DAG database running on Apple Silicon GPU.
Use these tools to query and manipulate the graph.
The daemon must be running (./dagdb start --data sample_db/).
Nodes have: id, rank (0=root, higher=leaves), truth (0/1/2), LUT6 gate type.
Edges connect lower-rank nodes to higher-rank nodes (max 6 per node).
""")

@mcp.tool()
def dagdb_status() -> str:
    """Get daemon status: node count, tick count, GPU info, grid size."""
    return query_daemon("STATUS")

@mcp.tool()
def dagdb_tick(count: int = 1) -> str:
    """Run N evaluation ticks. Each tick propagates truth states leaves-up through the ranked DAG."""
    return query_daemon(f"TICK {count}")

@mcp.tool()
def dagdb_query(command: str) -> str:
    """Send any DSL command to the daemon. Full verb surface:

    Lifecycle/inspect: STATUS | TICK <n> | GRAPH INFO | VALIDATE
    Read: NODES [AT RANK <n>] [WHERE <field><op><val>] | GET <node> TRUTH |
          EVAL [WHERE ...] [RANK <lo> TO <hi>] | TRAVERSE FROM <n> DEPTH <d> |
          BFS_DEPTHS FROM <seed> [BACKWARD] | ANCESTRY FROM <n> DEPTH <d> |
          SIMILAR_DECISIONS TO <n> DEPTH <d> K <k> [AMONG TRUTH <t>] |
          SELECT truth <k> rank <lo>-<hi> | DISTANCE <metric> <loA>-<hiA> <loB>-<hiB>
    Mutate: SET <n> TRUTH <0|1|2> | SET <n> RANK <u64> | SET <n> LUT <PRESET> |
            CONNECT FROM <src> TO <dst> | CONNECT BACK FROM <src> TO <dst> |
            CLEAR <n> EDGES | CLEAR <n> BACK_EDGES |
            COMPOSE <NOT|AND|OR|XOR> <src1> [<src2>] INTO <dst>
    Bulk install (vector at shm offset 8): SET_RANKS_BULK (u64[N]) |
            SET_LUTS_BULK (u64[N]) | SET_NEIGHBORS_BULK (int32[N*6])
    Persistence: SAVE <path> [COMPRESSED] | LOAD <path> |
            SAVE JSON <path> | LOAD JSON <path> | SAVE CSV <dir> | LOAD CSV <dir> |
            EXPORT MORTON <dir> | IMPORT MORTON <dir> |
            BACKUP INIT|APPEND|RESTORE|COMPACT|INFO <dir>
    MVCC: OPEN_READER | READER <id> <inner read-only cmd> | CLOSE_READER <id> | LIST_READERS

    Twin (twin-spec primitives, the interface phase; ids are "<letter>%08x" from a
        per-registry counter; registries are daemon-global (§0.13) — a
        READER session may run only the verbs marked * below, everything
        else replies "ERROR forbidden:"):
        STREAM OPEN <name> <stateHi> <stateLo> <incHi> <incLo> |
        STREAM NEXT <id> <n> | STREAM STATE <id> * | STREAM CLOSE <id> | STREAM LIST *
        HEADER CHECK <band> <tau> <comb> <echo> <record> <step> <floor> *
        RECORD OPEN <name> <7 header numbers> <stateHi> <stateLo> <incHi> <incLo> |
        RECORD SLICE <id> <count> | RECORD REPLAY <id> <index> * |
        RECORD VERIFY <id> * | RECORD INFO <id> * | RECORD CLOSE <id> | RECORD LIST *
        RINGS OPEN [<gear> <rings> <cells>] |
        RINGS WRITE <id> <v1> [<v2> ...] | RINGS RECALL <id> <lag> * |
        RINGS INFO <id> * | RINGS CLOSE <id> | RINGS LIST *
        CLOCK OPEN | CLOCK ADVANCE <id> [<n>] [VALUE <f>] | CLOCK STATE <id> * |
        CLOCK CLOSE <id> (cascades to its gears) | CLOCK LIST *
        GEAR OPEN <clockId> <name> <num>/<den> | GEAR STATE <id> * | GEAR CLOSE <id>
        XCONV CHECK <nA> <nB> <kA> <kB> <warmup> * (shm in: f32 a,b,kA,kB at offset 8)
        BUDGET OPEN <nPockets> <nTiers> <nClasses> (shm in: f64 cost row-major +
            u32 minTier at offset 8) |
        BUDGET SEALED | BUDGET ALLOCATE <id> <budget> <pocket>:<class> ... * |
        BUDGET INFO <id> * | BUDGET CLOSE <id> | BUDGET LIST *
        ALARM LOAD <path> [SHA <hex64>] | ALARM INFO <id> * | ALARM LIST * |
        ALARM CLOSE <id> | ALARM FRAME <id> <idx> * | ALARM COURT <id> <budget> * |
        ALARM SUCCESSOR <id> <budget> <epsM> <epsS> <epsN> * |
        ALARM CORRUPT <id> <idx> <epsM> <epsS> <epsN> * (shm out: [u32 count][u32 40]
            header + 40-byte rows: f64 weight | u32 nClaims | u32 reserved0 |
            5x(u8 pocket, u8 row, u8 phantom, u8 pad) | 4 pad)
        BANK OPEN <name> [<T> <fs> <f0> <H> <centers> <freqs> <sigmaFrac> [ALIASED]] (no
            numbers ⇒ WaveBank.Spec.referenceNyquistSafe, the repaired bank; all seven
            or none; a spec whose top harmonic reaches/exceeds Nyquist (fs/2) is
            refused with ERROR bad_value unless ALIASED is appended) |
        BANK GENERATE <id> <M> * (shm in: f32 C[K*M] row-major at offset 8; shm out:
            [u32 T*M][u32 4] header + f32 W[T*M] row-major) |
        BANK FIT <id> * (shm in: f32 x[T] at offset 8; shm out: [u32 K][u32 4]
            header + f32 coefficients[K]) |
        BANK NOISE <id> <seed> <n> * | BANK BENCH <id> <M> <reps> * |
        BANK INFO <id> * | BANK CLOSE <id> | BANK LIST *
        VIEW LOAD <path> [SHA <hex64>] | VIEW REFLEX <id> <S> * |
        VIEW RUNG <id> <S> * | VIEW CEILING <id> <S> * |
        VIEW FEATURES <id> <frame> <S> * (shm out: [u32 count=3*S][u32 4]
            header + f32 standardized features) |
        VIEW INFO <id> * | VIEW LIST * | VIEW CLOSE <id>

    Tiled (steps one AND two — gate T5, docs/contracts/TILING_GATES_FROZEN.md,
        and ticking across tiles, docs/contracts/TICKING_GATES_FROZEN.md —
        NOT a twin registry: a router is never persisted, never WAL-logged,
        never part of a snapshot; the tile directory on disk written by
        SAVE TILED IS the durable state, and TILED OPEN only rebuilds an
        in-memory view of it (recovering any dangling flush and completing
        a partial round first, so it never hands out a router over a torn
        world). Ids are "x%08x" from a handler-local counter — a different
        shape from the twin registries' letter prefixes, and not listed by
        dagdb_twin_list/closed by dagdb_twin_close):
        SAVE TILED <dir> <b1,b2,...> (rank boundaries, ascending, no spaces;
            splits the daemon's CURRENT engine; refused with "ERROR
            bad_value: back edge crosses a tile boundary (<src>→<dst>)" if
            any BACK_EDGE would cross the given boundaries) |
        TILED OPEN <dir> [<K>] (K resident tiles, default 2, 1...64; reply
            gains "recovered=<n> completed=<m>" — dangling-flush recoveries
            and partial-round catch-up ticks the open performed) |
        TILED BFS <id> <globalId> <depth> [BACK] * (depth 0...12; shm out:
            [u32 count][u32 16] header + rows u64 globalId, u32 depth, 4
            pad) |
        TILED SELECT <id> <truth> <lo> <hi> * (shm out: [u32 count][u32 8]
            header + u64 ids, sorted) |
        TILED STATUS <id> * (resident/loads/evicts/refused/last, plus
            "epoch=<min>/<max>" — the (min, max) world epoch over every
            tile; equal except mid-recovery) |
        TILED LIST * | TILED CLOSE <id> |
        TILED TICK <id> [<n>] [SYNC] (advance the world <n> ticks, default
            1, checked 1...10000; rank mode unless SYNC trails; every tile
            flushed durably with BEGIN/COMMIT each round) |
        TILED GET <id> <globalId> TRUTH * (one node's current truth byte,
            decimal)
        Router errors reply "ERROR io: <detail>" (a torn tile body's
        sha256 mismatch included); an unknown id is "ERROR not_found";
        a malformed number is "ERROR out_of_range" or "ERROR bad_value".
        Reader sessions may run BFS/SELECT/STATUS/LIST/GET (*); OPEN/
        CLOSE/SAVE TILED/TICK are forbidden there (TICK mutates — it
        flushes every tile to disk). Remaining, not yet built: the
        pre-fetch thread (optional — changes no result if added), the
        cold tier, the 10^11 run.

    Fold (gate F4, docs/contracts/FOLD_API_GATES_FROZEN.md — a pure
        computation over the daemon's CURRENT fabric lanes: neighbors, edge
        weights, nodeValue-as-leak, rank; nothing persisted, no WAL, no
        registry, no id — every verb below is read-only, RUN included (*
        would mark all five; omitted since there's nothing else in the
        family to contrast against)):
        FOLD RUN <maxRank> <keepRank> <f1> <f2> [<f3>] [CHECK <l1,l2,...>]
            (shm out: [u32 k*k][u32 4] header + f32 finalOperator[k*k]
            row-major) | FOLD KEPT (shm out: [u32 k][u32 8] header + u64
            keptIds[k]) | FOLD SOURCE <1|2|3> (shm out: [u32 k][u32 4]
            header + f32 foldedSource[k]; 3 with no f3 given to RUN is a
            vector of zeros) | FOLD TIER <level|final> <1|2|3> (shm out:
            [u32 m][u32 8] header + f64 tierAnswer[m]; unknown level or
            which=3 with no f3 is "ERROR not_found") | FOLD INFO (no shm
            output). Any FOLD verb before the first FOLD RUN is "ERROR
            not_found: no fold result yet".

    Twin id prefixes (per-registry counter, format "<letter>%08x"):
        s stream · t record · n rings · c clock · g gear · b budget layout ·
        a alarm set · w wave bank · v derived-view set

    LUT presets: AND OR XOR MAJ IDENTITY CONST0 CONST1 VETO NOR NAND AND3 OR3 MAJ3.
    Distance metrics: jaccardNodes jaccardEdges rankL1 rankL2 typeL1 boundedGED wlL1 spectralL2."""
    return query_daemon(command)

@mcp.tool()
def dagdb_nodes(rank: int = 0) -> str:
    """List all nodes at a specific rank. Rank 0 = root, higher = leaves."""
    return query_daemon(f"NODES AT RANK {rank}")

@mcp.tool()
def dagdb_traverse(node: int, depth: int = 2) -> str:
    """Walk the graph from a starting node to a given depth. Returns visited
    nodes with their truth states — each node once, however many depths it is
    reachable at. `node` and `depth` are both bounded by nodeCount; outside
    that the daemon answers "ERROR out_of_range: <name> <v> not in 0..<N"."""
    return query_daemon(f"TRAVERSE FROM {node} DEPTH {depth}")

@mcp.tool()
def dagdb_set_truth(node: int, value: int) -> str:
    """Set the truth state of a node. 0=FALSE, 1=TRUE, 2=UNDEFINED."""
    return query_daemon(f"SET {node} TRUTH {value}")

@mcp.tool()
def dagdb_set_rank(node: int, rank: int) -> str:
    """Set the rank of a node. 0=root, higher=closer to leaves."""
    return query_daemon(f"SET {node} RANK {rank}")

@mcp.tool()
def dagdb_set_lut(node: int, gate: str) -> str:
    """Set the LUT6 gate type of a node. Options: AND, OR, MAJ, XOR, ID, CONST0, CONST1, VETO."""
    return query_daemon(f"SET {node} LUT {gate.upper()}")

@mcp.tool()
def dagdb_compose_lut(op: str, src1: int, dst: int, src2: int = -1) -> str:
    """Bitwise compose the LUT(s) at src1 (and src2 for binary ops) into dst's LUT.

    Op is one of: AND, OR, XOR (binary — require src2 ≥ 0), NOT (unary — src2 ignored).
    Caller is responsible for the assumption that src1, src2, dst share a common
    input vector — the engine just performs the bitwise op on the 64-bit LUT integers.

    Useful for: graph-simplification at insert time (collapse a fused subtree's
    function into a single node's LUT before tick), offline composition of policies
    (e.g. veto = the node fires only when all of {a, b, c} agree), and any case
    where you'd otherwise have to evaluate a tree of intermediate nodes per tick.
    """
    op_u = op.upper()
    if op_u == "NOT":
        return query_daemon(f"COMPOSE NOT {src1} INTO {dst}")
    return query_daemon(f"COMPOSE {op_u} {src1} {src2} INTO {dst}")

@mcp.tool()
def dagdb_connect(source: int, target: int) -> str:
    """Wire an edge from source to target. Target reads from source. Max 6 edges per node. Clear edges first if needed."""
    return query_daemon(f"CONNECT FROM {source} TO {target}")

@mcp.tool()
def dagdb_clear_edges(node: int) -> str:
    """Clear all 6 edge slots on a node. Use before CONNECT to rewire."""
    return query_daemon(f"CLEAR {node} EDGES")

@mcp.tool()
def dagdb_connect_back(source: int, target: int) -> str:
    """Register a typed BACK_EDGE from source to target. The source's truth value is
    latched into the target at every tick boundary (after the combinational pass).
    Target must have zero combinational fan-in — it becomes a register node, skipped
    by the rank kernel and updated only by the latch. Used for synchronous-circuit
    patterns: AC-3 arc consistency, Hopfield recall, Boolean cellular automata,
    iterative SAT, anything that needs feedback across ticks."""
    return query_daemon(f"CONNECT BACK FROM {source} TO {target}")

@mcp.tool()
def dagdb_clear_back_edges(node: int) -> str:
    """Remove every BACK_EDGE whose destination is `node`. The node loses its
    register flag and combinational logic on it resumes evaluating its LUT6
    on the next tick. Mirror of `dagdb_clear_edges` but for back-edges."""
    return query_daemon(f"CLEAR {node} BACK_EDGES")

@mcp.tool()
def dagdb_graph_info() -> str:
    """Get graph statistics: node count, true count, nodes per rank."""
    return query_daemon("GRAPH INFO")

@mcp.tool()
def dagdb_eval() -> str:
    """Evaluate the graph (tick + return root nodes).

    Returns: "OK EVAL rows=<k> tick=<t> scope=roots nodes_computed=<n>"
    plus "ranks=<r> bound=<M>" when the graph reaches past the configured
    rank bound. EVAL ticks the WHOLE graph and reports only rank-0 roots —
    scope=roots is that disclosure."""
    return query_daemon("EVAL")

@mcp.tool()
def dagdb_save(path: str, compressed: bool = False) -> str:
    """Snapshot the full graph state (rank, truth, LUT6, edges) to a binary .dags file.
    Uses direct GPU-buffer write; fast at scale (~10 GB/s on Apple Silicon).

    Args:
        path: output file path.
        compressed: zlib-compress the body. Typically cuts the file to ~25% of raw size.
    """
    suffix = " COMPRESSED" if compressed else ""
    return query_daemon(f"SAVE {path}{suffix}")

@mcp.tool()
def dagdb_load(path: str) -> str:
    """Restore a previously saved .dags snapshot. Validates DAG invariants after memcpy.
    Errors if grid or node count mismatches the running daemon."""
    return query_daemon(f"LOAD {path}")

@mcp.tool()
def dagdb_export_morton(dir: str) -> str:
    """Export 6 Morton-ordered raw buffer files (rank, truth, nodeType, lut_low, lut_high, neighbors)
    into the given directory for bulk interop with external tools."""
    return query_daemon(f"EXPORT MORTON {dir}")

@mcp.tool()
def dagdb_import_morton(dir: str) -> str:
    """Inverse of export — read 6 per-buffer files from the directory back into the engine."""
    return query_daemon(f"IMPORT MORTON {dir}")

@mcp.tool()
def dagdb_validate() -> str:
    """Verify DAG invariants on the live graph: rank ordering, bounds, no self-loops, no duplicates.
    Returns 'OK VALIDATE' on success or 'FAIL VALIDATE <first violation>' on failure."""
    return query_daemon("VALIDATE")

@mcp.tool()
def dagdb_save_json(path: str) -> str:
    """Save engine state as JSON (dagdb-json v1 schema). Mirrors the six engine
    buffers directly — binary-vs-JSON round-trips match byte-for-byte."""
    return query_daemon(f"SAVE JSON {path}")

@mcp.tool()
def dagdb_load_json(path: str) -> str:
    """Load engine state from a dagdb-json file. Validates DAG invariants before
    committing to live buffers."""
    return query_daemon(f"LOAD JSON {path}")

@mcp.tool()
def dagdb_save_csv(dir: str) -> str:
    """Save engine state as two CSV files (nodes.csv + edges.csv) in the given
    directory. edges.csv only lists present edges — diff-friendly."""
    return query_daemon(f"SAVE CSV {dir}")

@mcp.tool()
def dagdb_load_csv(dir: str) -> str:
    """Load engine state from nodes.csv + edges.csv in the given directory.
    Validates DAG invariants before committing."""
    return query_daemon(f"LOAD CSV {dir}")

@mcp.tool()
def dagdb_backup_init(dir: str) -> str:
    """Start a new backup chain in the given directory — writes base.dags.
    Wipes any existing chain in that directory first."""
    return query_daemon(f"BACKUP INIT {dir}")

@mcp.tool()
def dagdb_backup_append(dir: str) -> str:
    """Append an incremental XOR-diff (NNNNN.diff) against the chain's current
    tip. Single-bit mutations produce diffs far smaller than the base."""
    return query_daemon(f"BACKUP APPEND {dir}")

@mcp.tool()
def dagdb_backup_restore(dir: str) -> str:
    """Replay base.dags + all diffs from the backup chain into the live engine."""
    return query_daemon(f"BACKUP RESTORE {dir}")

@mcp.tool()
def dagdb_backup_compact(dir: str) -> str:
    """Fold all diffs into a new base snapshot, remove the old diffs. Keeps
    restored state identical."""
    return query_daemon(f"BACKUP COMPACT {dir}")

@mcp.tool()
def dagdb_backup_info(dir: str) -> str:
    """Inspect a backup chain: base presence + size, diff count, total diff bytes."""
    return query_daemon(f"BACKUP INFO {dir}")

@mcp.tool()
def dagdb_distance(metric: str, rank_range_a: str, rank_range_b: str) -> str:
    """Compute a subgraph distance between two rank-range subgraphs.
    metric: one of jaccardNodes | jaccardEdges | rankL1 | rankL2 | typeL1 | boundedGED | wlL1 | spectralL2
    rank_range_a / rank_range_b: "<lo>-<hi>" inclusive, e.g. "0-2"
    Example: dagdb_distance("spectralL2", "0-1", "2-2") — roots+aggregator vs leaves."""
    return query_daemon(f"DISTANCE {metric} {rank_range_a} {rank_range_b}")

@mcp.tool()
def dagdb_ancestry(node: int, depth: int) -> str:
    """Walk the ancestry of a node — reverse BFS bounded by depth.

    Returns node IDs + depths via shared memory. Layout after an
    8-byte header: `(Int32 node, Int32 depth) × count`. Seed appears
    at depth=0; ancestors at depth > 0 up to the bound.

    Under the adapter's causal-parent convention (prev_by_agent,
    parent_response, dialogue_prev_turn, meeting_parent, cites_drop,
    triggered_by_external), this gives the full provenance subgraph
    of a decision or event in one call.

    Works on primary or reader sessions: for session use,
    dagdb_reader_query(session_id, f\"ANCESTRY FROM {node} DEPTH {d}\")."""
    return query_daemon(f"ANCESTRY FROM {node} DEPTH {depth}")

@mcp.tool()
def dagdb_similar_decisions(node: int, depth: int, k: int, among_truth: int = -1) -> str:
    """Find the K nodes whose local ancestral subgraph is most similar
    to the given node's, by Weisfeiler-Lehman-1 histogram L1 distance.

    Args:
        node: the query node id.
        depth: BFS depth cap for the local subgraph (1–3 is typical).
        k: how many results to return.
        among_truth: if >= 0, only compare against nodes with this
                     truth code. Caps work dramatically (e.g., compare
                     a dialogue_turn only to other dialogue_turns).

    Returns: shared-memory layout `(Int32 node, Float32 distance) × k`.

    Cost: O(C × 6^depth) where C is candidate count. Tractable for
    C ≈ 10k. Restrict via among_truth for bigger hives."""
    suffix = f" AMONG TRUTH {among_truth}" if among_truth >= 0 else ""
    return query_daemon(f"SIMILAR_DECISIONS TO {node} DEPTH {depth} K {k}{suffix}")

@mcp.tool()
def dagdb_hive_query(
    truth: int = -1,
    rank_lo: int = -1,
    rank_hi: int = -1,
    limit: int = 100,
) -> str:
    """Agent-friendly hive-node filter. Delegates to the secondary
    index (SELECT truth k rank lo-hi) when `truth` is given with a
    rank range, otherwise falls back to a full-range scan.

    Args:
        truth: event-type code to match, or -1 for any.
        rank_lo / rank_hi: inclusive rank bounds, or -1 for unbounded.
        limit: soft cap on returned count (index naturally orders by
               rank; caller truncates).

    This is the agent's ergonomic front-door. Sidecar-aware filters
    (agent, ts, event_type name) are client-side on the returned
    node IDs — fetch sidecars from whatever backing store the Loom
    plugin is ingesting (typically a JSONL event log) and filter
    there."""
    if truth < 0:
        return "ERROR hive_query: truth must be given (0-255); use dagdb_nodes for unfiltered listing"
    lo = max(0, rank_lo)
    # Rank is u64 engine-wide. The "unbounded" sentinel must be 2^64-1, not
    # the u32 max — a u32 cap silently excludes any node with rank > 2^32-1.
    hi = rank_hi if rank_hi >= 0 else (2**64 - 1)
    return query_daemon(f"SELECT truth {truth} rank {lo}-{hi}")

@mcp.tool()
def dagdb_select_by_truth_rank(truth: int, rank_lo: int, rank_hi: int) -> str:
    """Fast secondary-index lookup. Returns matching node IDs via shared
    memory as an Int32 array at offset 8, length `matches`.

    Typical hive-query shape:
        dagdb_select_by_truth_rank(truth=2, rank_lo=N-100, rank_hi=N)
        → all dialogue_turn events in the last 100 inserts.

    The index is lazy — rebuilds only on the first SELECT after any
    mutation that could change a node's truth or rank (SET_TRUTH,
    SET_RANK, SET_RANKS_BULK, LOAD, LOAD_JSON, LOAD_CSV, IMPORT,
    BACKUP_RESTORE). Rebuild is O(N log N); lookup is O(log N + matches).

    Reader sessions (OPEN_READER / READER envelope) use their own local
    index rebuilt per call since the snapshot buffers are static.

    Python client reads /tmp/dagdb_shm_file, skips 8 header bytes, maps
    Int32[matches] for the node IDs."""
    return query_daemon(f"SELECT truth {truth} rank {rank_lo}-{rank_hi}")

@mcp.tool()
def dagdb_open_reader() -> str:
    """Open a snapshot-on-read MVCC session. The daemon memcpys the six
    engine buffers into an independent DagDBEngine at call time; subsequent
    queries against this session id see that frozen point-in-time view
    regardless of writes on the primary.

    Returns: "OK OPEN_READER id=<hex> tick=<n> open_sessions=<k>"

    Use the returned id with dagdb_reader_query. Close with
    dagdb_close_reader when done — sessions hold ~38 bytes per node of
    memory each."""
    return query_daemon("OPEN_READER")

@mcp.tool()
def dagdb_close_reader(session_id: str) -> str:
    """Close a reader session. Releases the snapshot engine."""
    return query_daemon(f"CLOSE_READER {session_id}")

@mcp.tool()
def dagdb_list_readers() -> str:
    """List currently-open reader sessions with their ids and open-tick."""
    return query_daemon("LIST_READERS")

@mcp.tool()
def dagdb_reader_query(session_id: str, command: str) -> str:
    """Run a read-only DSL command against a reader session's snapshot engine.

    Allowed inner commands: GRAPH INFO, NODES, TRAVERSE, BFS_DEPTHS,
    DISTANCE, VALIDATE, STATUS, and the read-only twin verbs STREAM
    STATE/LIST, HEADER CHECK, RECORD REPLAY/VERIFY/INFO/LIST, RINGS
    RECALL/INFO/LIST, CLOCK STATE/LIST, GEAR STATE, XCONV CHECK, BUDGET
    ALLOCATE/INFO/LIST, ALARM INFO/LIST/FRAME/COURT/SUCCESSOR/CORRUPT.
    Writes are rejected — including every twin verb that opens, mutates,
    or closes a registry (twin registries are daemon-global, §0.13).

    Example:
        dagdb_reader_query("r5f4e1234", "BFS_DEPTHS FROM 42")
        dagdb_reader_query("r5f4e1234", "DISTANCE spectralL2 0-2 3-5")
    """
    return query_daemon(f"READER {session_id} {command}")

@mcp.tool()
def dagdb_set_ranks_bulk() -> str:
    """Commit a precomputed u64 rank vector from shared memory into the
    engine's rank buffer in one round-trip.

    Rank is u64 engine-wide (since 2026-04-21). The shm vector MUST be
    numpy uint64 — a uint32 array is half the width the daemon reads and
    corrupts the ranks.

    Caller workflow (Python):
        1. Compute ranks via a rankPolicy (see dagdb/plugins/biology/).
        2. Write the resulting numpy uint64 array (length nodeCount) to
           /tmp/dagdb_shm_file starting at byte offset 8.
        3. Call this tool. Daemon reads the vector and memcpys into
           rankBuf. No per-insert validation — run dagdb_validate
           afterwards if you need invariant checking.

    Much faster than per-node SET <id> RANK <r> for bulk ingestion:
    one DSL round-trip instead of N."""
    return query_daemon("SET_RANKS_BULK")

@mcp.tool()
def dagdb_set_luts_bulk() -> str:
    """Commit a precomputed u64 LUT vector from shared memory into the
    engine's lut6Low/lut6High buffers in one round-trip.

    Caller workflow (Python):
        1. Build a numpy uint64 array (length nodeCount) of 64-bit LUT
           truth tables — one per node's Boolean function.
        2. Write it to /tmp/dagdb_shm_file starting at byte offset 8.
        3. Call this tool. The daemon splits each u64 into low/high u32
           and commits. No WAL — pair with dagdb_save for durability.

    The fast path for compiling microcircuits (see the
    microcircuit-compilation wiki page): three bulk verbs
    (ranks + luts + neighbors) install a million-node graph in three
    shm writes instead of millions of single SET/CONNECT calls."""
    return query_daemon("SET_LUTS_BULK")

@mcp.tool()
def dagdb_set_neighbors_bulk() -> str:
    """Commit a precomputed neighbour table from shared memory into the
    engine's neighbors buffer in one round-trip.

    Caller workflow (Python):
        1. Build a numpy int32 array of length nodeCount * 6 — six input
           slots per node, row-major. -1 marks an empty slot.
        2. Write it to /tmp/dagdb_shm_file starting at byte offset 8.
        3. Call this tool. The daemon memcpys into neighborsBuf.

    Every element must be -1 or a valid node id: the WHOLE vector is
    range-checked before a single word is written, so a bad slot leaves the
    table exactly as it was and the refusal names the first offender. The
    read is size-checked against the mapping first.

    Still bypasses the BACK_EDGE/register invariant CONNECT enforces — the
    reply says so ("validation=skipped skipped=back_edge_register_fanin
    recheck=VALIDATE"); run dagdb_validate afterwards."""
    return query_daemon("SET_NEIGHBORS_BULK")

@mcp.tool()
def dagdb_bfs_depths(seed: int, backward: bool = False) -> str:
    """Compute per-node BFS depth from a seed node. Depths written as a raw
    Int32 array of length nodeCount to shared memory, offset 8 (after a
    [u32 nodeCount][u32 reserved] header).

    Default is undirected BFS — every directed edge treated as bidirectional.
    Set backward=True to follow only inputs[] (the DAG's rank-increasing
    direction).

    The Python client reads the shm file at /tmp/dagdb_shm_file and maps
    it as numpy.int32[nodeCount] starting at byte 8. -1 = unreachable, 0
    = seed, positive = BFS depth.

    For protein contact graphs under the single-node-per-residue encoding
    (one DagDB node per residue, rank = maxRank - seqIndex, one edge per
    contact), this yields contact-graph geodesic distances directly — no
    post-processing."""
    suffix = " BACKWARD" if backward else ""
    return query_daemon(f"BFS_DEPTHS FROM {seed}{suffix}")

# --------------------------------------------------------------------
# Twin primitives (interface phase, 2026-09). See dagdb_query's "Twin:" block for the full
# grammar and the id-prefix map. Every wrapper below is one query_daemon
# call; id arguments are validated client-side first (see _bad_twin_id).
# --------------------------------------------------------------------

@mcp.tool()
def dagdb_stream_open(name: str, state_hi: int, state_lo: int, inc_hi: int, inc_lo: int) -> str:
    """Open a new named PCG-style stream generator in the daemon-global
    stream registry (prefix 's'). state_hi/state_lo form the 128-bit PCG
    state, inc_hi/inc_lo the 128-bit increment — decimal or 0x-hex u64s
    (pass Python ints; 0x literals work directly).

    Returns: "OK STREAM OPEN id=s%08x name=<name> draws=0"."""
    return query_daemon(f"STREAM OPEN {name} {state_hi} {state_lo} {inc_hi} {inc_lo}")

@mcp.tool()
def dagdb_stream_next(id: str, n: int) -> str:
    """Draw the next n u64 words from a stream. Mutates the stream's state
    (not a read-only verb) and WAL-logs the post-draw state so replay is
    O(1) — it restores the boundary already reached, it does not redraw.

    shm layout: [u32 n][u32 8] header at offset 0, then uint64[n] at
    offset 8. Read with numpy.frombuffer(..., dtype=np.uint64, count=n)
    after skipping the 8-byte header (see docs/wiki/mcp.md's read_shm
    template).

    Returns: "OK STREAM NEXT id=<id> n=<n> draws=<total> state=0x..:0x.. shm_bytes=8n"."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"STREAM NEXT {id} {n}")

@mcp.tool()
def dagdb_stream_state(id: str) -> str:
    """Read-only: report a stream's name, cumulative draw count, and
    128-bit state without drawing.

    Returns: "OK STREAM STATE id=<id> name=<name> draws=<n> state=0x..:0x..".
    """
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"STREAM STATE {id}")

@mcp.tool()
def dagdb_stream_close(id: str) -> str:
    """Close a stream and release its registry slot.

    Returns: "OK STREAM CLOSE id=<id>"."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"STREAM CLOSE {id}")

@mcp.tool()
def dagdb_header_check(band: float, tau: float, comb: float, echo: float,
                        record: float, step: float, floor: float) -> str:
    """Read-only admissibility check for a StreamHeader (signal band Hz,
    tau window sec, comb rate Hz, first-echo sec, record-window sec, step
    sec, clock-sync floor sec) against the same constraints RECORD OPEN
    enforces — check before spending a RECORD OPEN call. All seven
    arguments must be finite or the daemon replies "ERROR bad_value".

    Returns: "OK HEADER CHECK admissible=1" or
             "FAIL HEADER CHECK violations=<k> <tag>;<tag>;..." (tags are
             nonPositiveQuantity(<q>), signalWiderThanWindow,
             combBelowNyquist, recordOutlivesEcho, stepAboveNyquist)."""
    return query_daemon(f"HEADER CHECK {band} {tau} {comb} {echo} {record} {step} {floor}")

@mcp.tool()
def dagdb_record_open(name: str, band: float, tau: float, comb: float, echo: float,
                       record: float, step: float, floor: float,
                       state_hi: int, state_lo: int, inc_hi: int, inc_lo: int) -> str:
    """Open a replayable draw-slice ledger (record registry, prefix 't'):
    a StreamHeader (the seven fields above, same admissibility rule as
    dagdb_header_check) plus a generator NamedStream (state_hi/state_lo/
    inc_hi/inc_lo, same 128-bit PCG fields as dagdb_stream_open). An
    inadmissible header is rejected before any state is created.

    Returns: "OK RECORD OPEN id=t%08x name=<name> slices=0" or
             "ERROR schema: inadmissible header: <tag>;<tag>;..."."""
    return query_daemon(
        f"RECORD OPEN {name} {band} {tau} {comb} {echo} {record} {step} {floor} "
        f"{state_hi} {state_lo} {inc_hi} {inc_lo}"
    )

@mcp.tool()
def dagdb_record_slice(id: str, count: int) -> str:
    """Draw `count` more words from the record's generator and append them
    as a new slice. Mutates the record; the WAL logs only `count` (the
    slice is O(1) to replay by redrawing from the logged generator
    boundary, not stored verbatim). No shm — the reply line is the full
    result.

    Returns: "OK RECORD SLICE id=<id> index=<slice index> count=<count> slices=<total>"."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"RECORD SLICE {id} {count}")

@mcp.tool()
def dagdb_record_replay(id: str, index: int) -> str:
    """Read-only: replay slice `index` of a record by redrawing from its
    logged generator boundary, and compare against the stored payload.

    shm layout: [u32 count][u32 8] header at offset 0, then uint64[count]
    at offset 8 — the replayed payload, same numpy template as
    dagdb_stream_next.

    Returns: "OK RECORD REPLAY id=<id> index=<index> count=<n> match=1
    shm_bytes=8n" (match is 1 iff the replay equals the stored slice)."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"RECORD REPLAY {id} {index}")

@mcp.tool()
def dagdb_record_verify(id: str) -> str:
    """Read-only: replay every slice in a record and report any that
    don't reproduce their stored payload bit-for-bit.

    Returns: "OK RECORD VERIFY id=<id> failing=0" or
             "OK RECORD VERIFY id=<id> failing=<k> failing_indices=i,j,...".
    """
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"RECORD VERIFY {id}")

@mcp.tool()
def dagdb_rings_open(gear: int = 6, rings: int = 6, cells: int = 32) -> str:
    """Open a geared ring buffer (rings registry, prefix 'n'): `rings`
    concentric rings of `cells` cells each, advanced one cell per `gear`
    ticks. Defaults (6, 6, 32) match the daemon's own default when no
    arguments are given.

    Returns: "OK RINGS OPEN id=n%08x gear=<g> rings=<r> cells=<c> capacity=<r*c>"."""
    return query_daemon(f"RINGS OPEN {gear} {rings} {cells}")

@mcp.tool()
def dagdb_rings_write(id: str, values: list) -> str:
    """Write consecutive Float32 values into a ring buffer, one write per
    tick, oldest cell recycled as the ring wraps. Chunks `values` at 400
    per DSL line (the socket contract caps input at 4 KB per command) and
    returns only the reply from the last chunk — the intermediate replies
    are all "OK RINGS WRITE ..." with an updated `now`; only the final
    state matters to the caller.

    Returns: the last chunk's "OK RINGS WRITE id=<id> now=<tick> ..." reply,
    or "ERROR bad_value: values must be non-empty" if `values` is empty."""
    err = _bad_twin_id(id)
    if err:
        return err
    if not values:
        return "ERROR bad_value: values must be non-empty"
    last = ""
    for i in range(0, len(values), 400):
        chunk = values[i:i + 400]
        vs = " ".join(repr(float(v)) for v in chunk)
        last = query_daemon(f"RINGS WRITE {id} {vs}")
    return last

@mcp.tool()
def dagdb_rings_recall(id: str, lag: int) -> str:
    """Read-only: recall the value written `lag` ticks ago from a ring
    buffer (0 = the most recent write).

    Returns: "OK RINGS RECALL id=<id> value=<f> tick=<t> ring=<r> span=<s>"
    or "OK RINGS RECALL id=<id> value=none" if that lag was never written
    (cell not yet occupied)."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"RINGS RECALL {id} {lag}")

@mcp.tool()
def dagdb_clock_open() -> str:
    """Open a new master tick clock (clock registry, prefix 'c') at tick 0.
    Gears (dagdb_gear_open) attach to a clock and advance in phase with it.

    Returns: "OK CLOCK OPEN id=c%08x tick=0"."""
    return query_daemon("CLOCK OPEN")

@mcp.tool()
def dagdb_clock_advance(id: str, n: int = 1, value: float = None) -> str:
    """Advance a clock by n ticks (default 1). On each tick, every gear
    attached to this clock is advanced in step (masterTick, and `value` if
    given — gears with a latch record the tick/value where their phase
    accumulator fires).

    Returns: "OK CLOCK ADVANCE id=<id> tick=<new tick>"."""
    err = _bad_twin_id(id)
    if err:
        return err
    suffix = f" VALUE {value}" if value is not None else ""
    return query_daemon(f"CLOCK ADVANCE {id} {n}{suffix}")

@mcp.tool()
def dagdb_clock_state(id: str) -> str:
    """Read-only: report a clock's current tick.

    Returns: "OK CLOCK STATE id=<id> tick=<t>"."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"CLOCK STATE {id}")

@mcp.tool()
def dagdb_gear_open(clock_id: str, name: str, num: int, den: int) -> str:
    """Attach a phase gear (gear registry, prefix 'g') to clock `clock_id`
    with reduced ratio num/den — the gear fires once every den ticks of
    the clock, num times per den (e.g. 3/7 fires 3 times every 7 ticks).
    Closing the clock cascades and closes every gear attached to it.

    Returns: "OK GEAR OPEN id=g%08x clock=<clock_id> name=<name> ratio=<p>/<q>"
    or "ERROR not_found: <clock_id>" if the clock doesn't exist."""
    err = _bad_twin_id(clock_id)
    if err:
        return err
    return query_daemon(f"GEAR OPEN {clock_id} {name} {num}/{den}")

@mcp.tool()
def dagdb_gear_state(id: str) -> str:
    """Read-only: report a gear's fire count and current phase, and the
    last latched (tick, value) if it has a latch.

    Returns: "OK GEAR STATE id=<id> fires=<n> phase=<a>/<q>
    latched_tick=<t|none> latched_value=<v|none>"."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"GEAR STATE {id}")

@mcp.tool()
def dagdb_xconv_check(nA: int, nB: int, kA: int, kB: int, warmup: int) -> str:
    """Read-only. Caller must first write Float32 arrays a, b, kA, kB to
    /tmp/dagdb_shm_file starting at byte offset 8 (a has nA samples, b has
    nB, kernel kA has kA taps, kernel kB has kB taps — lengths must match
    the counts passed here) before calling this tool. Checks that
    convolving a with kernel kA and b with kernel kB agree (after
    discarding the first `warmup` samples) — the smoother-reproducing-
    across-the-bridge check from the summer's E2v2 work.

    Returns: "OK XCONV CHECK residual=<d> compared=<n>"."""
    return query_daemon(f"XCONV CHECK {nA} {nB} {kA} {kB} {warmup}")

@mcp.tool()
def dagdb_xconv_sealed(id: str, n: int, warmup: int = 0) -> str:
    """Read-only: the court's FROZEN sealed cross-convolution residual
    (docs/contracts/KERNELS_GATES_FROZEN.md, gates K1-K3) against a loaded
    kernel pair `id` (from dagdb_kernel_load) — window [warmup, n) on both
    numerator and denominator, one-sided denominator max|yAB|+1e-300,
    float64 end to end. This is NOT dagdb_xconv_check (the "patrol check"
    above): that one compares over the full convolution length instead of
    the record window, a symmetric denominator instead of one-sided, and
    Float32 records/taps instead of Float64 — it stays as the standing
    cheap check, unchanged; this tool is the contract's finding.

    Caller must first write Float64 arrays a, b (each `n` samples) to
    /tmp/dagdb_shm_file starting at byte offset 8: a[0..n), then b[0..n)
    (rowSize 8, no gap between the two).

    `warmup`: 0 (default) means "use the pair's own warmup" — derived from
    TAU/SIGMA if the pair was loaded with them, else its declared WARMUP,
    else the call fails (a pair loaded without either has no default
    warmup and must be given one explicitly here). Any positive value here
    OVERRIDES the pair's own warmup and is reported as "declared, not
    derived" (derived=0).

    Returns: "OK XCONV SEALED id=<id> n=<n> warmup=<v> derived=<0|1>
    residual=<d> compared=<n-warmup>" or "ERROR bad_value: ..." (n < 2, or
    no warmup available and none given), "ERROR out_of_range: ..." (shm
    capacity, or warmup >= n), or "ERROR not_found: <id>"."""
    err = _bad_twin_id(id)
    if err:
        return err
    suffix = f" {warmup}" if warmup else ""
    return query_daemon(f"XCONV SEALED {id} {n}{suffix}")

@mcp.tool()
def dagdb_budget_sealed() -> str:
    """Open the sealed allocator layout — the frozen tariff table from
    market/pregate_allocator_v2.json (4 pockets x 8 tiers, minTier [4, 1])
    used by the twin spec's allocator court — as a budget layout (budget
    layout registry, prefix 'b'). No shm input; the table is compiled in.

    Returns: "OK BUDGET SEALED id=b%08x pockets=4 tiers=8 classes=2"."""
    return query_daemon("BUDGET SEALED")

@mcp.tool()
def dagdb_budget_open(n_pockets: int, n_tiers: int, n_classes: int) -> str:
    """Open a custom budget layout. Caller must first write to
    /tmp/dagdb_shm_file starting at byte offset 8: Float64 `cost`,
    row-major [n_pockets][n_tiers], followed by UInt32 `minTier`,
    length n_classes (the minimum tier index a claim of that class must
    reach to count as served). Ragged, non-finite, or out-of-range input
    is rejected with "ERROR bad_value".

    Returns: "OK BUDGET OPEN id=b%08x pockets=<p> tiers=<t> classes=<c>"."""
    return query_daemon(f"BUDGET OPEN {n_pockets} {n_tiers} {n_classes}")

@mcp.tool()
def dagdb_budget_allocate(id: str, budget: float, claims: list) -> str:
    """Read-only: given a layout `id` (from dagdb_budget_sealed or
    dagdb_budget_open) and a budget, decide which claims are served.
    `claims` is a list of (pocket, class_index) integer pairs, sent as
    "<pocket>:<class> ..." tokens.

    Returns: "OK BUDGET ALLOCATE id=<id> budget=<b> value=<v> cost=<c>
    served=<k> purchases=<pocket:tier,...>"."""
    err = _bad_twin_id(id)
    if err:
        return err
    claim_str = " ".join(f"{int(pocket)}:{int(class_index)}" for pocket, class_index in claims)
    return query_daemon(f"BUDGET ALLOCATE {id} {budget} {claim_str}")

@mcp.tool()
def dagdb_alarm_load(path: str, sha256: str = None) -> str:
    """Load an alarm-stream fixture (alarm registry, prefix 'a') — the
    JSON dict of AlarmRecord entries (quiet/liar/deep/drift + the cal0
    control) described in §0 of the twin-spec plan. `path` is checked
    against the daemon's guardPath (must be inside its data root). Pass
    `sha256` (the 64-hex-char pinned digest, e.g.
    AlarmFixture.sealedSHA256) to fail loudly on any mismatch rather than
    silently loading a different fixture.

    Returns: "OK ALARM LOAD id=a%08x records=<n> control=<0|1> sha256=<hex>
    quiet=<n> liar=<n> deep=<n> drift=<n> ears=A<a>/B<b>/C<c>" or
    "ERROR io: <reason>" (missing file, outside data root, or sha256
    mismatch — an unexpected fixture is a finding, never a silent skip,
    per §0.16)."""
    suffix = f" SHA {sha256}" if sha256 else ""
    return query_daemon(f"ALARM LOAD {path}{suffix}")

@mcp.tool()
def dagdb_alarm_frame(id: str, idx: int) -> str:
    """Read-only: report one alarm record's culprit classification.

    Returns: "OK ALARM FRAME id=<id> idx=<idx> class=<quiet|liar|deep|drift>
    ear=<A|B|C|none> label=<label|none> pocket=<p|none> burst=<0|1>"."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"ALARM FRAME {id} {idx}")

@mcp.tool()
def dagdb_alarm_court(id: str, budget: float) -> str:
    """Read-only: replay the allocator court over the full alarm stream at
    one budget point — allocator/uniform/greedy/oracle arms, each frame
    src = t - delta with warmup/tail handling per AllocatorCourt.run.

    Returns: "OK ALARM COURT id=<id> budget=<b> misses=<m> served=<s>
    cost=<c> burst=<served>/<missed>/<total> max_spend_ratio=<r> ..." (the
    gate-1 table fields; see docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md for the
    sealed numbers this reproduces bit-for-bit)."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"ALARM COURT {id} {budget}")

@mcp.tool()
def dagdb_alarm_successor(id: str, budget: float, eps_m: float, eps_s: float, eps_n: float) -> str:
    """Read-only: the successor object's counting-hand totals over the
    corruption-model ε lattice (epsM = liar-ear-swap knob, epsS =
    drift-goes-unread knob, epsN = phantom-claim knob) at one budget point.

    Returns: "OK ALARM SUCCESSOR id=<id> budget=<b> misses_alloc=<m1>
    misses_greedy=<m2> cost_alloc=<c1> cost_greedy=<c2> ..." (the gate-2
    table fields; exactness depends on loop-order fidelity, §0.10)."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"ALARM SUCCESSOR {id} {budget} {eps_m} {eps_s} {eps_n}")

@mcp.tool()
def dagdb_alarm_corrupt(id: str, idx: int, eps_m: float, eps_s: float, eps_n: float) -> str:
    """Read-only: enumerate every (true-branch x phantom-subset) outcome
    for one alarm record under the corruption model — CorruptionModel.
    enumerateOutcomes(for:), weights summing to 1.0 exactly.

    shm layout: [u32 count][u32 40] header at offset 0, then `count`
    40-byte rows at offset 8, each:
        f64 weight | u32 nClaims | u32 reserved0 |
        5 x (u8 pocket, u8 row, u8 phantom, u8 pad) | 4 pad
    (row is 0=L, 1=D; unused claim slots beyond nClaims are zero-filled).

    Returns: "OK ALARM CORRUPT id=<id> idx=<idx> outcomes=<count>
    weight_sum=<w> shm_bytes=<40n> claims_truncated=<t>" (w is exactly 1.0
    over the full enumeration; t is how many rows lost a claim to the row's
    five slots — 0 under the sealed model, whose widest outcome is exactly
    five). Refuses by name if the rows do not fit this daemon's shm."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"ALARM CORRUPT {id} {idx} {eps_m} {eps_s} {eps_n}")

# --------------------------------------------------------------------
# VIEW (alarm-set derived views, spec line 4 second view family). One
# loaded cortex v4 world per open id (view registry, prefix 'v'); REFLEX/
# RUNG/CEILING/FEATURES read the sealed frame set — see
# docs/contracts/DERIVED_VIEWS_GATES_FROZEN.md gate V6 for the reply
# shapes and the gated numbers they reproduce.
# --------------------------------------------------------------------

@mcp.tool()
def dagdb_view_load(path: str, sha256: str = None) -> str:
    """Load the sealed cortex v4 world fixture (view registry, prefix 'v')
    — M frames x 8 stations x 64 samples (train/test), the 129x8 arrival
    table tau, and the world constants. `path` is checked against the
    daemon's guardPath (must be inside its data root). Pass `sha256` (the
    64-hex-char pinned digest, e.g. CortexFixture.sealedSHA256) to fail
    loudly on any mismatch rather than silently loading a different
    fixture.

    Returns: "OK VIEW LOAD id=v%08x train=6966 test=300 stations=8
    samples=64 candidates=129 sha256=<hex>" or "ERROR io: <reason>"
    (missing file, outside data root, sha256 mismatch, or a malformed npz
    layout — an unexpected fixture is a finding, never a silent skip)."""
    suffix = f" SHA {sha256}" if sha256 else ""
    return query_daemon(f"VIEW LOAD {path}{suffix}")

@mcp.tool()
def dagdb_view_reflex(id: str, S: int) -> str:
    """Read-only: the amended-letter reflex over the 300 sealed test
    frames at station-subset size S (1..8) — per-candidate least-squares
    fit against the S-station arrivals, tie rule at 1e-9 relative
    tolerance.

    Returns: "OK VIEW REFLEX id=<id> S=<S> reflex=<n> oracle=<n>
    tie_min=<n> tie_median=<d> tie_max=<n> frames_with_tie=<n>
    near_edge=<n>" (reflex/oracle/tie_*/frames_with_tie are gate V1-V3's
    numbers; near_edge is printed only, the V1 honest-clause floor)."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"VIEW REFLEX {id} {S}")

@mcp.tool()
def dagdb_view_rung(id: str, S: int) -> str:
    """Read-only: the geometry-then-energy rung at station-subset size S —
    reflex tied sets resolved by nearest standardized-feature class
    centroid (Euclidean, exact ties keep the lowest index). Centroids are
    recomputed from the 6966 train frames on every call.

    Returns: "OK VIEW RUNG id=<id> S=<S> hits=<n> min_margin=<d>" (hits is
    gate V4's number)."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"VIEW RUNG {id} {S}")

@mcp.tool()
def dagdb_view_ceiling(id: str, S: int) -> str:
    """Read-only: the arrival-geometry ceiling from tau alone at
    station-subset size S — exact-twin pairs (< 1e-9) and identifiable
    classes (unique + groups under the < 1.0 transitive-closure relation).

    Returns: "OK VIEW CEILING id=<id> S=<S> identifiable=<n> of=129
    ceiling=<%.6f> exact_twin_pairs=<n> unique=<n> groups=<n>" (gate V5's
    numbers)."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"VIEW CEILING {id} {S}")

@mcp.tool()
def dagdb_view_features(id: str, frame: int, S: int) -> str:
    """Read-only: the 3*S front-aligned energy features (station-major:
    per station in the S-subset, log front-window energy ratio / spectral
    centroid / log second-window energy ratio) of test frame `frame`
    (0..<300), standardized with the train set's mean/std at that S.

    shm layout: [u32 count=3*S][u32 4] header at offset 0, then `count`
    little-endian f32 values at offset 8.

    Returns: "OK VIEW FEATURES id=<id> frame=<frame> S=<S> count=<3*S>"."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"VIEW FEATURES {id} {frame} {S}")

@mcp.tool()
def dagdb_view_info(id: str) -> str:
    """Read-only: report a loaded view set's reference and fixture shape.

    Returns: "OK VIEW INFO id=<id> path=<path> sha256=<hex> train=<n>
    test=<n> stations=<n> samples=<n> candidates=<n>" or
    "ERROR not_found: <id>"."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"VIEW INFO {id}")

# --------------------------------------------------------------------
# Kernel: per-path kernel storage (spec line 6, second half). One loaded
# (kA, kB) pair per open id (kernel registry, prefix 'k'), persisted BY
# REFERENCE (path + sha256) — see docs/contracts/KERNELS_GATES_FROZEN.md
# gates K3/K4. dagdb_xconv_sealed (above, beside dagdb_xconv_check) is the
# court's residual over a loaded pair.
# --------------------------------------------------------------------

@mcp.tool()
def dagdb_kernel_load(path: str, sha256: str = "", tau_a: float = 0.0, tau_b: float = 0.0,
                       sigma: float = 0.0, warmup: int = 0) -> str:
    """Load a per-path kernel pair (kernel registry, prefix 'k') — a JSON
    file shaped like the sealed W1 kernels fixture: kA, kB (equal-length
    Double arrays, the root->A / root->B impulse responses), fs, and
    window_samples/ear_index_A/ear_index_B. `path` is checked against the
    daemon's guardPath (must be inside its data root).

    `sha256`: pass the 64-hex-char pinned digest to fail loudly on any
    mismatch; empty (default) computes and uses the file's own hash
    unchecked.

    `tau_a`/`tau_b`/`sigma`: the pair's path delays (seconds, from the tree
    metric — NOT read from the kernels file) and the source bank's
    Gaussian envelope sigma (seconds). All three zero (default) means
    "omit TAU/SIGMA" — the pair then has no derived warmup (K4) and
    dagdb_xconv_sealed needs an explicit warmup. Give all three together
    (any nonzero) to derive warmup = ceil((|tau_a-tau_b| + 3*sigma)*fs).

    `warmup`: an explicit declared warmup (used only when TAU/SIGMA are
    NOT given — TAU/SIGMA's derived warmup always wins when both are
    present). 0 (default) means "none declared".

    Returns: "OK KERNEL LOAD id=k%08x taps=<n> fs=<hz> window=<n>
    ears=<A>/<B> warmup=<v|none> derived=<0|1> sha256=<hex>" or
    "ERROR io: <reason>" (missing file, outside data root, sha256
    mismatch, or a malformed/empty kernel array — an unexpected fixture is
    a finding, never a silent skip)."""
    suffix = ""
    if sha256:
        suffix += f" SHA {sha256}"
    if tau_a or tau_b or sigma:
        suffix += f" TAU {tau_a} {tau_b} SIGMA {sigma}"
    if warmup:
        suffix += f" WARMUP {warmup}"
    return query_daemon(f"KERNEL LOAD {path}{suffix}")

@mcp.tool()
def dagdb_kernel_info(id: str) -> str:
    """Read-only: report a loaded kernel pair's reference, shape, and
    warmup resolution.

    Returns: "OK KERNEL INFO id=<id> path=<path> sha256=<hex> taps=<n>
    fs=<hz> window=<n> ears=<A>/<B> tau_a=<v|none> tau_b=<v|none>
    sigma=<v|none> warmup=<v|none> derived=<0|1>" or
    "ERROR not_found: <id>"."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"KERNEL INFO {id}")

# --------------------------------------------------------------------
# Hook: the attention hook (gate H5, docs/contracts/HOOK_GATES_FROZEN.md)
# — the sealed allocator court (AllocatorCourt.run) as a daemon-global
# ticked process. One open hook per id (hook registry, prefix 'h'), bound
# to an alarm set + budget layout (SEALED default) + frame budget + lag
# delta + lagged policy, and optionally a master clock (one CLOCK ADVANCE
# tick = one hook step; the hook then refuses dagdb_hook_step with
# "ERROR forbidden: bound to clock <c>"; CLOCK CLOSE cascades to it like a
# gear). Closing an alarm set or budget layout a live hook depends on is
# refused the same way, naming the hook. LIST/CLOSE route through
# dagdb_twin_list/dagdb_twin_close like every other registry.
# --------------------------------------------------------------------

@mcp.tool()
def dagdb_hook_open(alarm_id: str, layout_id: str = "SEALED", budget: float = 0.0,
                     delta: int = 3, policy: str = "allocator", clock_id: str = "") -> str:
    """Open a new attention hook (hook registry, prefix 'h') — the sealed
    allocator court as a daemon-global ticked process. Advances one frame
    per dagdb_hook_step call (or one per CLOCK ADVANCE tick if bound),
    reproducing AllocatorCourt.run's lagged-arm loop body frame by frame.

    `alarm_id`: an id from dagdb_alarm_load. `layout_id`: "SEALED" (the
    default) for SealedCourt.makeLayout(), or an id from
    dagdb_budget_open/dagdb_budget_sealed. `budget`: the per-frame budget B
    — must be finite and > 0; the Python-side default 0.0 exists only so
    every other argument can have a default too, and always fails loudly
    with "ERROR bad_value: ..." rather than silently opening a zero-budget
    hook — always pass a real budget. `delta`: the lag (default 3, the
    sealed Δ; must be >= 0). `policy`: "allocator" | "greedy" | "uniform"
    (default "allocator"; the budget is constant per hook — a different
    budget is a different hook, never a mid-run re-declaration).
    `clock_id`: "" (default) leaves the hook unbound, stepped only by
    dagdb_hook_step; a clock id binds it so CLOCK ADVANCE steps it once
    per tick (after the clock's gears) and dagdb_hook_step then refuses.

    Returns: "OK HOOK OPEN id=h%08x alarm=<id> layout=<id|SEALED> B=<b>
    delta=<d> policy=<p> clock=<c|none> frames=<n>" (frames = the alarm
    set's record count + delta) or "ERROR not_found: ..." (unknown alarm/
    layout/clock), "ERROR bad_value: ..." (budget not finite or <= 0), or
    "ERROR out_of_range: ..." (delta < 0)."""
    err = _bad_twin_id(alarm_id)
    if err:
        return err
    suffix = ""
    if delta != 3:
        suffix += f" DELTA {delta}"
    if policy != "allocator":
        suffix += f" POLICY {policy}"
    if clock_id:
        suffix += f" CLOCK {clock_id}"
    return query_daemon(f"HOOK OPEN {alarm_id} {layout_id} {budget}{suffix}")

@mcp.tool()
def dagdb_hook_step(id: str, n: int) -> str:
    """Advance a hook `n` frames, or until done, whichever comes first — a
    step past the last frame is a no-op (stepped=0, done=1). Refused with
    "ERROR forbidden: bound to clock <c>" if the hook is bound to a master
    clock (step it via dagdb_clock_advance instead).

    Returns: "OK HOOK STEP id=<id> t=<t> stepped=<taken> done=<0|1>
    served=<s> misses=<m> cost=<c>" or "ERROR not_found: <id>" /
    "ERROR out_of_range: n must be >= 1"."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"HOOK STEP {id} {n}")

@mcp.tool()
def dagdb_hook_state(id: str) -> str:
    """Read-only: a hook's live ArmResult snapshot, kept in sync frame by
    frame as it steps — bit-for-bit equal to AllocatorCourt.run's batch
    replay at every frame (gate H1).

    Returns: "OK HOOK STATE id=<id> t=<t> done=<0|1> served=<s>
    misses=<m> cost=<c> dummy=<n> dominated=<n> max_spend_ratio=<r>
    warmup_cost=<c> burst=<served>/<missed>/<total>" or
    "ERROR not_found: <id>"."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"HOOK STATE {id}")

@mcp.tool()
def dagdb_hook_ledger(id: str, from_: int = 0, count: int = 0) -> str:
    """Read-only: rows [from_, from_+count) of a hook's per-frame ledger
    (gate H2) — DERIVED, never stored; rebuilt by re-stepping. Leaving both
    `from_` and `count` at 0 (the default) returns every row.

    shm layout: [u32 count][u32 40] header at offset 0, then `count`
    40-byte rows at offset 8, each:
        u32 t | i32 src | u8 judged | u8 outcome (0 none, 1 hit, 2 miss) |
        i8 tier (-1 none) | i8 pocket (-1 none) | 4 pad (aligns the two f64
        fields below to an 8-byte boundary) | f64 spend | f64
        cumulativeCost | u8 countsTowardCost | 7 pad = 40 bytes/row.

    Returns: "OK HOOK LEDGER id=<id> from=<f> count=<c> of=<total>" or
    "ERROR not_found: <id>" / "ERROR out_of_range: ..." (bad range, or the
    requested rows don't fit shm capacity)."""
    err = _bad_twin_id(id)
    if err:
        return err
    if from_ == 0 and count == 0:
        return query_daemon(f"HOOK LEDGER {id}")
    return query_daemon(f"HOOK LEDGER {id} {from_} {count}")

@mcp.tool()
def dagdb_hook_info(id: str) -> str:
    """Read-only: a hook's fixed parameters plus its current position.

    Returns: "OK HOOK INFO id=<id> alarm=<id> layout=<id|SEALED> B=<b>
    delta=<d> policy=<p> clock=<c|none> frames=<n> t=<t> done=<0|1>" or
    "ERROR not_found: <id>"."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"HOOK INFO {id}")

# --------------------------------------------------------------------
# BANK (spec 8, the waveform mouth, the interface phase). One frozen bank of T×K atoms
# per open id (bank registry, prefix 'w'); GENERATE is one matrix product
# W = Φ·C, FIT is a least-squares solve for the coefficients that best
# reproduce a target waveform in the bank's span.
# --------------------------------------------------------------------

@mcp.tool()
def dagdb_bank_open(name: str, T: int = 0, fs: float = 0, f0: float = 0,
                     H: int = 0, centers: int = 0, freqs: int = 0, sigma_frac: float = 0,
                     aliased: bool = False) -> str:
    """Open a new named waveform bank (bank registry, prefix 'w') — a frozen
    T×K matrix of atoms (harmonic cos/sin columns plus Gabor atoms on a
    center/frequency grid), each column unit-normalized.

    All seven of T/fs/f0/H/centers/freqs/sigma_frac left at their default
    (0) opens `WaveBank.Spec.referenceNyquistSafe`, the repaired bank
    (T=4096, fs=3000, f0=60, H=24, centers=8, freqs=6, sigma_frac=0.02,
    K=144). Otherwise pass every one: T samples, fs sample rate (Hz), f0
    fundamental (Hz), H harmonic count, centers/freqs the Gabor grid
    dimensions, sigma_frac the Gabor envelope width as a fraction of the
    record length. K = 2*H + 2*centers*freqs is derived, not passed.

    A spec whose top harmonic reaches or exceeds Nyquist (H*f0 >= fs/2) is
    refused with "ERROR bad_value: ..." naming the first harmonic that
    folds back, unless `aliased=True` — set it deliberately when you want
    the sealed 160-atom CONTROL bank (H=32 at the reference rates: harmonics
    26..32 alias exactly onto 24..18, fourteen of its atoms are dependent)
    or any other spec you know aliases.

    Returns: "OK BANK OPEN id=w%08x name=<name> T=<T> K=<K> atoms_bytes=<T*K*4>
    rank=<int> cond=<d>" (rank = count of singular values above
    sigma_max*1e-9; cond = sigma_max/sigma_min over all K singular values,
    printed for diagnosis, not gated) or "ERROR bad_value: <reason>" if the
    spec doesn't admit a bank (samples out of [2, 1<<20], any rate/frac
    non-positive or non-finite, H < 1, atomCount out of [1, min(4096, T)])
    or reaches Nyquist without `aliased=True`."""
    if T == 0 and fs == 0 and f0 == 0 and H == 0 and centers == 0 and freqs == 0 and sigma_frac == 0:
        return query_daemon(f"BANK OPEN {name}")
    suffix = " ALIASED" if aliased else ""
    return query_daemon(f"BANK OPEN {name} {T} {fs} {f0} {H} {centers} {freqs} {sigma_frac}{suffix}")

@mcp.tool()
def dagdb_bank_generate(id: str, M: int) -> str:
    """Read-only (writes shm only, same class as RECORD REPLAY): generate M
    waveform columns as one matrix product W = Φ·C. Caller must first write
    Float32 coefficients C, K*M values row-major (C[k*M+m]), to
    /tmp/dagdb_shm_file starting at byte offset 8.

    shm out: [u32 T*M][u32 4] header, then Float32 W, T*M values row-major
    (W[t*M+m]). Read with numpy.frombuffer(..., dtype=np.float32, count=T*M)
    after skipping the 8-byte header.

    Returns: "OK BANK GENERATE id=<id> T=<T> M=<M> samples=<T*M>
    elapsed_ms=<f>" or "ERROR out_of_range: ..." naming which bound failed
    (input 8+K*M*4 or output 8+T*M*4 exceeding shm capacity) or
    "ERROR not_found: <id>"."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"BANK GENERATE {id} {M}")

@mcp.tool()
def dagdb_bank_fit(id: str) -> str:
    """Read-only: least-squares fit c* = argmin ‖x − Φc‖ for a target
    waveform against the bank's atoms. Caller must first write Float32
    target x, T values, to /tmp/dagdb_shm_file starting at byte offset 8.

    shm out: [u32 K][u32 4] header, then Float32 coefficients, K values.

    Returns: "OK BANK FIT id=<id> residual=<d> norm=<d> coefficients=<K>"
    (residual = ‖x − Φc*‖₂ / ‖x‖₂, both norms in Double; norm = ‖x‖₂) or
    "ERROR not_found: <id>"."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"BANK FIT {id}")

@mcp.tool()
def dagdb_bank_noise(id: str, seed: int, n: int) -> str:
    """Read-only: the out-of-bank noise law (spec 8 gate G3) — n
    independent-ish Gaussian-noise probes, each fit against the bank, with
    the residual's theoretical expectation sqrt(1 - K/T) for comparison.
    `seed` (>= 0) advances a fixed PCG stream that many draws before
    drawing; `n` (1..200) is the probe count.

    Returns: "OK BANK NOISE id=<id> n=<n> expected=<d> mean=<d> min=<d>
    max=<d>" or "ERROR out_of_range: ..." if seed < 0 or n outside
    [1, 200], or "ERROR not_found: <id>"."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"BANK NOISE {id} {seed} {n}")

@mcp.tool()
def dagdb_bank_bench(id: str, M: int, reps: int) -> str:
    """Read-only: GENERATE throughput benchmark (spec 8 gate G6, printed,
    not gated) — best of `reps` timed calls to generate M columns, after
    one untimed warm-up call. M clamped to [1, 100000], reps to [1, 20].

    Returns: "OK BANK BENCH id=<id> M=<M> reps=<reps> best_ms=<f>
    samples_per_s=<f>" or "ERROR out_of_range: ..." if M or reps is
    outside its range, or "ERROR not_found: <id>"."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"BANK BENCH {id} {M} {reps}")

@mcp.tool()
def dagdb_bank_info(id: str) -> str:
    """Read-only: report a bank's spec, derived atom count, and its
    declaration (rank and condition number, recomputed on every call).

    Returns: "OK BANK INFO id=<id> name=<name> T=<T> fs=<fs> f0=<f0>
    H=<H> centers=<centers> freqs=<freqs> sigma_frac=<frac> K=<K>
    rank=<int> cond=<d>" or "ERROR not_found: <id>"."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"BANK INFO {id}")

# --------------------------------------------------------------------
# FOLD (gate F4, docs/contracts/FOLD_API_GATES_FROZEN.md) — the tier-ladder
# fold (Kron/Schur elimination of a rank ring at a time, operator stored to
# Float32 between folds, solves in Float64) over the daemon's CURRENT
# fabric lanes. No registry, no id, no WAL — the handler keeps only the
# last result; a FOLD RUN replaces it. Every verb is read-only, including
# RUN (it never writes the fabric, only reads it and writes shm).
# --------------------------------------------------------------------

@mcp.tool()
def dagdb_fold_run(max_rank: int, keep_rank: int, f1: int, f2: int, f3: int = -1, checkpoints: str = "") -> str:
    """Fold the graph's CURRENT lanes (neighbors, edge weights,
    nodeValue-as-leak, rank) from `max_rank` down to `keep_rank`, one rank
    ring eliminated per fold via dense symmetric solve + Schur complement.
    Replaces the daemon's one stored fold result (`lastFold`) — every other
    FOLD verb reads back from this call, and errors "not_found" before the
    first one. Because it replaces daemon-global state, FOLD RUN is NOT
    allowed inside a READER session (the other four FOLD verbs are), and it
    is not on the web bridge's read-only allowlist.

    Args:
        max_rank: highest rank ring to start folding from.
        keep_rank: the fold stops once only nodes at rank <= keep_rank
            remain (must be >= 0 and < max_rank).
        f1, f2: source node indices (row-major), each folded through the
            ladder alongside the operator. Must be valid node indices.
        f3: optional third source node index; -1 (default) means no f3 —
            its folded/tier values come back as zero vectors.
        checkpoints: comma-separated rank levels to snapshot mid-fold (e.g.
            "19,15,11,7"), each strictly between keep_rank and max_rank.
            Empty string (default) records only the final tier.

    shm out: [u32 k*k][u32 4] header, then Float32 finalOperator, k*k
    values row-major (k = kept node count).

    Returns: "OK FOLD RUN kept=<k> folds=<n> bytes=<k*k*4> wall_ms=<f>" or
    "ERROR out_of_range: ..." (bad keep_rank/max_rank ordering, f1/f2/f3
    out of range, a checkpoint outside (keep_rank, max_rank), or the
    result's k*k*4 bytes exceeding shm capacity — checked before the fold
    runs)."""
    checkpoints = checkpoints.strip()
    # f3 must appear if CHECK does (the daemon grammar is positional: [<f3>]
    # [CHECK ...]) — pass it explicitly whenever either is non-default;
    # "-1" round-trips through the parser exactly like omitting it.
    parts = [str(max_rank), str(keep_rank), str(f1), str(f2)]
    if f3 != -1 or checkpoints:
        parts.append(str(f3))
    if checkpoints:
        parts += ["CHECK", checkpoints]
    return query_daemon("FOLD RUN " + " ".join(parts))

@mcp.tool()
def dagdb_fold_kept() -> str:
    """Read-only: the kept node ids from the last FOLD RUN.

    shm out: [u32 k][u32 8] header, then u64 keptIds, k values, row-major
    node index.

    Returns: "OK FOLD KEPT kept=<k>" or "ERROR not_found: no fold result yet"."""
    return query_daemon("FOLD KEPT")

@mcp.tool()
def dagdb_fold_source(which: int) -> str:
    """Read-only: the folded source vector (f1=1, f2=2, f3=3) from the last
    FOLD RUN, at the kept set's final size. `which=3` with no f3 given to
    RUN returns a vector of zeros — the library folds a zero right-hand
    side through the ladder rather than special-casing it.

    shm out: [u32 k][u32 4] header, then Float32 foldedSource, k values.

    Returns: "OK FOLD SOURCE which=<i> kept=<k>" or "ERROR not_found: no
    fold result yet"."""
    return query_daemon(f"FOLD SOURCE {which}")

@mcp.tool()
def dagdb_fold_tier(level: str, which: int) -> str:
    """Read-only: one checkpoint tier's solved answer (f1=1, f2=2, f3=3)
    from the last FOLD RUN. `level` is "final" or one of the numeric
    checkpoint levels passed to FOLD RUN's `checkpoints`.

    shm out: [u32 m][u32 8] header, then Float64 tierAnswer, m values (m =
    the kept-set size at that checkpoint).

    Returns: "OK FOLD TIER level=<level> which=<i> count=<m>" or
    "ERROR not_found: ..." if `level` wasn't checkpointed, `which=3` with no
    f3 given to RUN, or no fold result yet."""
    return query_daemon(f"FOLD TIER {level} {which}")

@mcp.tool()
def dagdb_fold_info() -> str:
    """Read-only: a summary of the last FOLD RUN — no shm output.

    Returns: "OK FOLD INFO kept=<k> folds=<n> tiers=<comma-separated keys,
    numeric descending then final> bytes=<k*k*4> wall_ms=<f>" or
    "ERROR not_found: no fold result yet"."""
    return query_daemon("FOLD INFO")

# --------------------------------------------------------------------
# Tiled — steps one (gate T5, docs/contracts/TILING_GATES_FROZEN.md) AND
# two (ticking across tiles, docs/contracts/TICKING_GATES_FROZEN.md).
# Cross-tile query routers over tile directories split from the daemon's
# CURRENT engine by rank range. Deliberately NOT a twin registry: a router
# is never persisted, never WAL-logged, never part of a snapshot — the
# tile directory on disk IS the durable state; TILED OPEN only rebuilds an
# in-memory view of it, recovering any dangling flush and completing a
# partial round first (so it never hands out a router over a torn world),
# THEN loading no tile bodies until the first query touches them.
# Ids are "x%08x" from a handler-local counter (a different shape from the
# twin registries' single-letter prefixes) — dagdb_twin_list/dagdb_twin_close
# do not reach them; use dagdb_query("TILED LIST") / dagdb_tiled_close
# instead. Ticking (TILED TICK) is now built — durable per-tile flush,
# BEGIN/COMMIT each round, crash recovery and partial-round completion at
# open. Remaining, not yet built: the pre-fetch thread (optional — changes
# no result if added), the cold tier, thermal pauses, the 10^11 run
# (docs/contracts/TICKING_GATES_FROZEN.md's "Not promised" list).
# --------------------------------------------------------------------

@mcp.tool()
def dagdb_save_tiled(dir: str, boundaries: str) -> str:
    """Split the daemon's CURRENT graph (engine + grid, as they stand right
    now) into tile directories under `dir`, one per rank range, plus a
    graph manifest. Read-only over the live graph — nothing in the running
    engine changes.

    Args:
        dir: output directory (guarded by DAGDB_DATA_ROOT like every other
            path-taking verb). The tile count is `len(boundaries) + 1`.
        boundaries: comma-separated ascending rank boundaries, no spaces,
            e.g. "5,11,17" for 4 tiles. At least one boundary is required.

    Returns: "OK SAVE TILED dir=<dir> tiles=<n> nodes=<N> crossings=<c>" or
    "ERROR bad_value: ..." (empty/unsorted/duplicate boundaries, OR a
    BACK_EDGE whose src and dst would fall in different tiles — "ERROR
    bad_value: back edge crosses a tile boundary (<src>→<dst>)", checked
    and refused BEFORE any directory is written) or
    "ERROR io: ..." (path/write failure)."""
    return query_daemon(f"SAVE TILED {dir} {boundaries}")

@mcp.tool()
def dagdb_tiled_open(dir: str, k: int = 2) -> str:
    """Open a cross-tile query router over a directory `dagdb_save_tiled`
    already wrote (reads `<dir>/manifest.json`; recovers any tile whose
    last flush crashed mid-way and completes a partial round left by a
    between-tiles interruption BEFORE returning — a torn world is never
    handed out — then loads no tile bodies until the first query touches
    them).

    Args:
        dir: the tile directory (same path passed to `dagdb_save_tiled`).
        k: max resident tiles (LRU eviction beyond this), 1...64, default 2.

    Returns: "OK TILED OPEN id=x%08x tiles=<n> nodes=<N> resident_max=<K>
    recovered=<n> completed=<m>" (recovered: tiles whose dangling
    TILE_FLUSH_BEGIN was fixed; completed: tiles ticked to catch a partial
    round up to the others) or "ERROR out_of_range: K ..." or "ERROR io:
    ..." (missing/corrupt manifest, or an unresolvable tear)."""
    return query_daemon(f"TILED OPEN {dir} {k}")

@mcp.tool()
def dagdb_tiled_bfs(id: str, global_id: int, depth: int, back: bool = False) -> str:
    """Cross-tile BFS (undirected, default) or ancestry (`back=True`,
    inputs-only) from a global node id, level-synchronous across tile
    boundaries — loads whatever tiles the frontier touches, evicting the
    least-recently-used tile past the router's K.

    Args:
        id: router id from `dagdb_tiled_open`.
        global_id: the packed GlobalNodeID (raw u64: tile in the high 24
            bits, local node id in the low 40) — NOT a plain engine index.
        depth: 0...12 (§6.1's cap; use `dagdb_tiled_select` for wider
            rank-range sweeps instead of a deep BFS).
        back: True for backward-only (inputs) expansion, matching
            ANCESTRY/BFS_DEPTHS BACKWARD's convention.

    shm out: [u32 count][u32 16] header, then 16-byte rows (u64 globalId,
    u32 depth, 4 bytes pad).

    Returns: "OK TILED BFS id=<id> seed=<global_id> depth=<d> back=<0|1>
    count=<n> loads=<n> evicts=<n>" or "ERROR not_found: ..." (unknown
    router id) or "ERROR io: ..." (a router error — depth cap exceeded, or
    a torn tile body's sha256 mismatch, recorded in `dagdb_tiled_status`'s
    refused count too)."""
    suffix = " BACK" if back else ""
    return query_daemon(f"TILED BFS {id} {global_id} {depth}{suffix}")

@mcp.tool()
def dagdb_tiled_select(id: str, truth: int, rank_lo: int, rank_hi: int) -> str:
    """Cross-tile truth/rank-range select: every tile whose rank span could
    overlap `[rank_lo, rank_hi]` is loaded and queried against its own
    truth/rank secondary index.

    shm out: [u32 count][u32 8] header, then u64 global ids, sorted
    ascending.

    Returns: "OK TILED SELECT id=<id> truth=<t> lo=<lo> hi=<hi> count=<n>"
    or "ERROR not_found: ..." or "ERROR io: ..."."""
    return query_daemon(f"TILED SELECT {id} {truth} {rank_lo} {rank_hi}")

@mcp.tool()
def dagdb_tiled_status(id: str) -> str:
    """One router's residency/load/evict/refusal counters, plus its world
    epoch.

    Returns: "OK TILED STATUS id=<id> resident=<n>/<K> loads=<n>
    evicts=<n> refused=<n> last=<error|none> epoch=<min>/<max>" (min/max
    over every tile's own last-flushed epoch — equal for a router, which
    never opens or answers over a tear) or "ERROR not_found: ...".
    `dagdb_status`'s own STATUS line carries `tiled_open=<n>` (routers are
    NOT counted in that line's `twin_open`, since they aren't a twin
    registry)."""
    return query_daemon(f"TILED STATUS {id}")

@mcp.tool()
def dagdb_tiled_tick(id: str, n: int = 1, sync: bool = False) -> str:
    """Advance the tiled world `n` ticks — durable: every tile is ticked
    and flushed to disk (BEGIN, body, halo strip, meta, manifest entry,
    COMMIT, in that order) each round, so a crash mid-flush is detected
    and recovered the next time the directory is opened. Rank mode
    (leaves-up, ranks max→0 within one world tick) unless `sync=True`
    (ping-pong, one hop per world tick).

    Args:
        id: router id from `dagdb_tiled_open`.
        n: ticks to run, 1...10000, default 1.
        sync: True for sync mode instead of rank mode.

    Returns: "OK TILED TICK id=<id> ticks=<epoch after> tiles_ticked=<n>
    loads=<n> evicts=<n> flushes=<n> halo_bytes=<n>" or "ERROR
    out_of_range: n ..." or "ERROR not_found: ..." or "ERROR io: ..."
    (a router error — a stale halo strip that couldn't regenerate, a
    manifest/sidecar sha256 disagreement on a clean tile, etc.)."""
    suffix = " SYNC" if sync else ""
    return query_daemon(f"TILED TICK {id} {n}{suffix}")

@mcp.tool()
def dagdb_tiled_get_truth(id: str, global_id: int) -> str:
    """One node's current truth byte through an open router — a cheap
    readback that doesn't need a BFS/SELECT.

    Args:
        id: router id from `dagdb_tiled_open`.
        global_id: the packed GlobalNodeID (raw u64) — same form
            `dagdb_tiled_bfs`/`dagdb_tiled_select` take and return.

    Returns: "OK TILED GET id=<id> node=<global_id> truth=<0|1|2>" or
    "ERROR out_of_range: node ..." (no such node) or "ERROR not_found:
    ..." (unknown router id)."""
    return query_daemon(f"TILED GET {id} {global_id} TRUTH")

@mcp.tool()
def dagdb_tiled_list() -> str:
    """Every open router: id, source directory, tile count, node count,
    resident_max.

    Returns: "OK TILED LIST count=<n> [id@dir=... tiles=... nodes=...
    resident_max=... ...]"."""
    return query_daemon("TILED LIST")

@mcp.tool()
def dagdb_tiled_close(id: str) -> str:
    """Close a router. Nothing to flush — routers aren't persisted (the
    tile directory on disk is already the durable state).

    Returns: "OK TILED CLOSE id=<id> open=<n>" or "ERROR not_found: ...".
    """
    return query_daemon(f"TILED CLOSE {id}")

@mcp.tool()
def dagdb_twin_list(kind: str) -> str:
    """List open ids in one twin registry, selected by its id-prefix
    letter: s stream, t record, n rings, c clock, g gear, b budget layout,
    a alarm set, w wave bank, v derived-view set, k kernel pair, h
    attention hook.

    Returns: "OK <VERB> LIST count=<n> [id id ...]" or
    "ERROR bad_id: unknown kind ..." if `kind` isn't one of stncgbawvkh."""
    verb = _TWIN_PREFIX_VERB.get(kind)
    if verb is None:
        return f"ERROR bad_id: unknown kind {kind!r} (expected one of s t n c g b a w v k h)"
    return query_daemon(f"{verb} LIST")

@mcp.tool()
def dagdb_twin_close(id: str) -> str:
    """Close any twin registry entry, routed to the right verb by the id's
    prefix letter (s->STREAM, t->RECORD, n->RINGS, c->CLOCK, g->GEAR,
    b->BUDGET, a->ALARM, w->BANK, v->VIEW, k->KERNEL, h->HOOK). Closing a
    clock cascades to its gears AND any hooks bound to it; closing an
    alarm set or budget layout a live hook depends on is refused with
    "ERROR forbidden: ..." naming the hook.

    Returns: "OK <VERB> CLOSE id=<id>" (plus gears_closed=<n>/
    hooks_closed=<n> for a clock), or "ERROR bad_id: ..." if `id` doesn't
    match the twin id shape."""
    err = _bad_twin_id(id)
    if err:
        return err
    verb = _TWIN_PREFIX_VERB[id[0]]
    return query_daemon(f"{verb} CLOSE {id}")

if __name__ == "__main__":
    # Verify daemon is running
    status = query_daemon("STATUS")
    if status.startswith("OK"):
        print(f"DagDB MCP Server starting — daemon: {status}")
    else:
        print(f"WARNING: daemon not responding: {status}")
        print("Start with: ./dagdb start --data sample_db/")

    mcp.run(transport="stdio")
