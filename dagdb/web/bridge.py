#!/usr/bin/env python3
"""DagDB WebSocket Bridge — connects browser to daemon via Unix socket.

Browser ←WebSocket→ bridge.py ←Unix Socket→ dagdb_daemon

Usage: python3 bridge.py [--port 9100] [--socket /tmp/dagdb.sock]
"""

import asyncio
import websockets
import socket
import json
import sys
import os

DAEMON_SOCK = os.environ.get("DAGDB_SOCK", "/tmp/dagdb.sock")
WS_PORT = int(os.environ.get("DAGDB_WS_PORT", "9100"))

# Security (Fable review S1/S3). This bridge relays commands from a browser
# to the daemon's full DSL surface. Any local process — including any web
# page's JavaScript opening ws://localhost:<port> — can reach it. Two
# defenses, both on by default:
#   1. Read-only by default. Only clearly non-mutating verbs are allowed.
#      A drive-by page can at most read graph state, never SAVE/LOAD/SET/etc.
#      Set DAGDB_WS_ALLOW_WRITE=1 to expose the full write surface (only do
#      this for a trusted local UI).
#   2. Origin allowlist. Connections from arbitrary web origins are rejected.
#      Set DAGDB_WS_ALLOW_ORIGINS to a comma-separated list to override; the
#      default permits only localhost origins and origin-less clients
#      (native tools, file://).
READ_ONLY_VERBS = {
    "STATUS", "GRAPH", "NODES", "GET", "TRAVERSE", "BFS_DEPTHS",
    "ANCESTRY", "SIMILAR_DECISIONS", "SELECT", "DISTANCE", "VALIDATE",
    "LIST_READERS", "OPEN_READER", "CLOSE_READER", "READER",
}
ALLOW_WRITE = os.environ.get("DAGDB_WS_ALLOW_WRITE", "0") == "1"
_default_origins = "http://localhost,http://127.0.0.1,https://localhost,null"
ALLOW_ORIGINS = {
    o.strip()
    for o in os.environ.get("DAGDB_WS_ALLOW_ORIGINS", _default_origins).split(",")
    if o.strip()
}

def _origin_allowed(origin) -> bool:
    # No Origin header → native client (nc, a script), not a browser page. Allow.
    if origin is None:
        return True
    # Browsers send scheme://host[:port]; match on the scheme://host prefix so
    # an ephemeral UI port doesn't have to be enumerated.
    for allowed in ALLOW_ORIGINS:
        if origin == allowed or origin.startswith(allowed + ":"):
            return True
    return False

def _command_allowed(cmd: str) -> bool:
    if ALLOW_WRITE:
        return True
    verb = cmd.split(None, 1)[0].upper() if cmd else ""
    return verb in READ_ONLY_VERBS

def query_daemon(cmd: str) -> str:
    """Send a command to the daemon and return the response."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(10)  # don't wedge an executor thread on a stalled daemon
        s.connect(DAEMON_SOCK)
        s.sendall((cmd + "\n").encode())
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

def _get_origin(websocket):
    # websockets API moved the request headers around across versions.
    for getter in (
        lambda: websocket.request.headers.get("Origin"),
        lambda: websocket.request_headers.get("Origin"),
    ):
        try:
            return getter()
        except Exception:
            continue
    return None

async def handler(websocket):
    """Handle one WebSocket client."""
    origin = _get_origin(websocket)
    if not _origin_allowed(origin):
        print(f"  Rejected client from disallowed origin: {origin!r}")
        await websocket.close(code=1008, reason="origin not allowed")
        return
    print(f"  Client connected: {websocket.remote_address} (origin={origin!r})")
    try:
        async for message in websocket:
            cmd = message.strip()
            if not cmd:
                continue
            # Reject control chars: a newline could smuggle a second command
            # line past the single-command-per-message contract.
            if any(ord(c) < 0x20 for c in cmd):
                await websocket.send("ERROR: command contains control characters")
                continue
            if not _command_allowed(cmd):
                await websocket.send(
                    "ERROR: write commands are disabled on this bridge "
                    "(set DAGDB_WS_ALLOW_WRITE=1 to enable for a trusted UI)"
                )
                continue
            # Run daemon query in thread pool (it blocks)
            loop = asyncio.get_event_loop()
            response = await loop.run_in_executor(None, query_daemon, cmd)
            await websocket.send(response)
    except websockets.exceptions.ConnectionClosed:
        pass
    print(f"  Client disconnected: {websocket.remote_address}")

async def main():
    print(f"══════════════════════════════════════════════════")
    print(f"  DagDB WebSocket Bridge")
    print(f"  Browser → ws://localhost:{WS_PORT} → {DAEMON_SOCK}")
    print(f"══════════════════════════════════════════════════")

    # Verify daemon is running
    test = query_daemon("STATUS")
    if test.startswith("OK"):
        print(f"  Daemon: {test}")
    else:
        print(f"  WARNING: Daemon not responding: {test}")

    mode = "READ-WRITE (DAGDB_WS_ALLOW_WRITE=1)" if ALLOW_WRITE else "READ-ONLY"
    async with websockets.serve(handler, "localhost", WS_PORT):
        print(f"  Listening on ws://localhost:{WS_PORT}  [{mode}]")
        print(f"  Allowed origins: {sorted(ALLOW_ORIGINS)} (+ origin-less)")
        print(f"  Open the DagDB UI in Chrome to connect.")
        await asyncio.Future()  # run forever

if __name__ == "__main__":
    # Parse args
    args = sys.argv[1:]
    for i, a in enumerate(args):
        if a == "--port" and i + 1 < len(args):
            WS_PORT = int(args[i + 1])
        if a == "--socket" and i + 1 < len(args):
            DAEMON_SOCK = args[i + 1]

    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n  Bridge stopped.")
