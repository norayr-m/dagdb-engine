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
  dagdb_twin_list/dagdb_twin_close         — cross-registry list/close by id prefix

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

def query_daemon(cmd: str) -> str:
    """Send a command to the daemon and return the response."""
    # Reject control characters (Fable review S3, defense-in-depth). The
    # daemon contract is one command per connection; an embedded newline in a
    # path argument could smuggle a second command line. Legitimate commands
    # and paths never contain control chars.
    if any(ord(c) < 0x20 and c not in "\t" for c in cmd.strip()):
        return "ERROR: command contains control characters"
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
# clock, g gear, b budget layout, a alarm set. Wrappers below validate any
# id argument against this shape client-side, before touching the socket —
# a malformed id can never be a legitimate reply from any registry, so
# there is nothing to gain by round-tripping it to the daemon.
_TWIN_ID_RE = re.compile(r"^[stncgba][0-9a-f]{8}$")
_TWIN_PREFIX_VERB = {
    "s": "STREAM", "t": "RECORD", "n": "RINGS", "c": "CLOCK",
    "g": "GEAR", "b": "BUDGET", "a": "ALARM",
}

def _bad_twin_id(id: str):
    """Return an "ERROR bad_id: ..." string if `id` doesn't match the twin
    id shape, else None. No daemon round-trip on mismatch."""
    if not _TWIN_ID_RE.match(id or ""):
        return f"ERROR bad_id: {id!r} does not match ^[stncgba][0-9a-f]{{8}}$"
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

    Twin id prefixes (per-registry counter, format "<letter>%08x"):
        s stream · t record · n rings · c clock · g gear · b budget layout · a alarm set

    LUT presets: AND OR XOR MAJ IDENTITY CONST0 CONST1 VETO NOR NAND AND3 OR3 MAJ3.
    Distance metrics: jaccardNodes jaccardEdges rankL1 rankL2 typeL1 boundedGED wlL1 spectralL2."""
    return query_daemon(command)

@mcp.tool()
def dagdb_nodes(rank: int = 0) -> str:
    """List all nodes at a specific rank. Rank 0 = root, higher = leaves."""
    return query_daemon(f"NODES AT RANK {rank}")

@mcp.tool()
def dagdb_traverse(node: int, depth: int = 2) -> str:
    """Walk the graph from a starting node to a given depth. Returns visited nodes with their truth states."""
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
    """Evaluate the graph (tick + return root nodes)."""
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

    Bypasses rank-monotonicity validation (matches SET_RANKS_BULK) —
    run dagdb_validate afterwards if you don't fully trust the table."""
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
    weight_sum=<w>" (w is exactly 1.0 over the full enumeration)."""
    err = _bad_twin_id(id)
    if err:
        return err
    return query_daemon(f"ALARM CORRUPT {id} {idx} {eps_m} {eps_s} {eps_n}")

@mcp.tool()
def dagdb_twin_list(kind: str) -> str:
    """List open ids in one twin registry, selected by its id-prefix
    letter: s stream, t record, n rings, c clock, g gear, b budget layout,
    a alarm set.

    Returns: "OK <VERB> LIST count=<n> [id id ...]" or
    "ERROR bad_id: unknown kind ..." if `kind` isn't one of stncgba."""
    verb = _TWIN_PREFIX_VERB.get(kind)
    if verb is None:
        return f"ERROR bad_id: unknown kind {kind!r} (expected one of s t n c g b a)"
    return query_daemon(f"{verb} LIST")

@mcp.tool()
def dagdb_twin_close(id: str) -> str:
    """Close any twin registry entry, routed to the right verb by the id's
    prefix letter (s->STREAM, t->RECORD, n->RINGS, c->CLOCK, g->GEAR,
    b->BUDGET, a->ALARM). Closing a clock cascades to its gears.

    Returns: "OK <VERB> CLOSE id=<id>" (plus gears_closed=<n> for a clock),
    or "ERROR bad_id: ..." if `id` doesn't match the twin id shape."""
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
