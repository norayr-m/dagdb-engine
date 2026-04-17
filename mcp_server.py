#!/usr/bin/env python3
"""DagDB MCP Server — expose the graph engine as MCP tools for LLMs.

Any LLM connected via MCP can query, evaluate, and manipulate the graph.

Tools:
  dagdb_status    — daemon status
  dagdb_tick      — run N ticks
  dagdb_query     — send any DSL command
  dagdb_nodes     — list nodes at a rank
  dagdb_traverse  — walk the graph from a node
  dagdb_set       — set truth/rank/LUT on a node
  dagdb_connect   — wire an edge
  dagdb_graph     — graph info
  dagdb_hex       — ASCII hex table view
  dagdb_show      — full ASCII visualization

Usage: python3 mcp_server.py
Requires: pip install mcp
Daemon must be running: ./dagdb start --data sample_db/
"""

import socket
import json
import sys
import os

# Check for mcp package
try:
    from mcp.server.fastmcp import FastMCP
except ImportError:
    print("Installing mcp package...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--break-system-packages", "mcp[cli]"])
    from mcp.server.fastmcp import FastMCP

DAEMON_SOCK = os.environ.get("DAGDB_SOCK", "/tmp/dagdb.sock")

def query_daemon(cmd: str) -> str:
    """Send a command to the daemon and return the response."""
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
    """Send any DSL command to the daemon. Commands: STATUS, TICK N, GRAPH INFO, NODES AT RANK N, NODES AT RANK N WHERE truth=1, TRAVERSE FROM node DEPTH n, SET node TRUTH 0|1, SET node RANK n, SET node LUT AND|OR|MAJ|XOR|ID|CONST0|CONST1, CLEAR node EDGES, CONNECT FROM src TO dst, EVAL."""
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
def dagdb_connect(source: int, target: int) -> str:
    """Wire an edge from source to target. Target reads from source. Max 6 edges per node. Clear edges first if needed."""
    return query_daemon(f"CONNECT FROM {source} TO {target}")

@mcp.tool()
def dagdb_clear_edges(node: int) -> str:
    """Clear all 6 edge slots on a node. Use before CONNECT to rewire."""
    return query_daemon(f"CLEAR {node} EDGES")

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

if __name__ == "__main__":
    # Verify daemon is running
    status = query_daemon("STATUS")
    if status.startswith("OK"):
        print(f"DagDB MCP Server starting — daemon: {status}")
    else:
        print(f"WARNING: daemon not responding: {status}")
        print("Start with: ./dagdb start --data sample_db/")

    mcp.run(transport="stdio")
