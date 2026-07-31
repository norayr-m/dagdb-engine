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

Usage: python3 mcp_server.py
Requires: pip install mcp
Daemon must be running: ./dagdb start --data sample_db/
"""

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
    DISTANCE, VALIDATE, STATUS. Writes are rejected.

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

if __name__ == "__main__":
    # Verify daemon is running
    status = query_daemon("STATUS")
    if status.startswith("OK"):
        print(f"DagDB MCP Server starting — daemon: {status}")
    else:
        print(f"WARNING: daemon not responding: {status}")
        print("Start with: ./dagdb start --data sample_db/")

    mcp.run(transport="stdio")
