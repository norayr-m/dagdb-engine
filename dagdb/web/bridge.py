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
# OPEN_READER and CLOSE_READER are deliberately NOT here (gate D5, audit B
# finding 24): OPEN_READER allocates a whole snapshot engine per call and
# registers it daemon-globally — an unauthenticated page could grow the
# daemon's memory without bound — and CLOSE_READER destroys a session
# another client owns. Neither is a read. LIST_READERS is a read and stays.
# READER stays, but its INNER command is classified too (finding 25).
READ_ONLY_VERBS = {
    "STATUS", "GRAPH", "NODES", "GET", "TRAVERSE", "BFS_DEPTHS",
    "ANCESTRY", "SIMILAR_DECISIONS", "SELECT", "DISTANCE", "VALIDATE",
    "LIST_READERS", "READER",
}
# Twin-spec verbs (interface phase, 2026-09) are two-token commands (VERB SUBVERB ...) — a
# single-token allowlist can't express "STREAM STATE read-only, STREAM
# OPEN not". This mirrors TwinCommand.isReadOnly (§0.13: twin registries
# are daemon-global, so a mutating twin verb is never safe to expose here
# even though it isn't gated by a READER session).
READ_ONLY_TWIN = {
    ("STREAM", "STATE"), ("STREAM", "LIST"),
    ("HEADER", "CHECK"),
    ("RECORD", "REPLAY"), ("RECORD", "VERIFY"), ("RECORD", "INFO"), ("RECORD", "LIST"),
    ("RINGS", "RECALL"), ("RINGS", "INFO"), ("RINGS", "LIST"),
    ("CLOCK", "STATE"), ("CLOCK", "LIST"),
    ("GEAR", "STATE"),
    ("XCONV", "CHECK"), ("XCONV", "SEALED"),
    ("BUDGET", "ALLOCATE"), ("BUDGET", "INFO"), ("BUDGET", "LIST"),
    ("ALARM", "INFO"), ("ALARM", "LIST"), ("ALARM", "FRAME"),
    ("ALARM", "COURT"), ("ALARM", "SUCCESSOR"), ("ALARM", "CORRUPT"),
    ("BANK", "GENERATE"), ("BANK", "FIT"), ("BANK", "NOISE"),
    ("BANK", "BENCH"), ("BANK", "INFO"), ("BANK", "LIST"),
    ("VIEW", "REFLEX"), ("VIEW", "RUNG"), ("VIEW", "CEILING"),
    ("VIEW", "FEATURES"), ("VIEW", "INFO"), ("VIEW", "LIST"),
    ("KERNEL", "INFO"), ("KERNEL", "LIST"),
    # FOLD (gate F4): pure computation over the daemon's CURRENT lanes,
    # nothing persisted. FOLD RUN is NOT on this list (gate D5, audit B
    # finding 18): it assigns the daemon-global last-fold result that
    # KEPT/SOURCE/TIER/INFO read, so a browser could overwrite what the
    # primary session sees. Mirrors TwinCommand.isReadOnly.
    ("FOLD", "KEPT"), ("FOLD", "SOURCE"),
    ("FOLD", "TIER"), ("FOLD", "INFO"),
    # HOOK (gate H5): STATE/LEDGER/INFO/LIST look at a hook without
    # mutating it; OPEN/STEP/CLOSE stay off this allowlist (mirrors
    # TwinCommand.isReadOnly).
    ("HOOK", "STATE"), ("HOOK", "LEDGER"), ("HOOK", "INFO"), ("HOOK", "LIST"),
    # TILED (gate T5, docs/contracts/TILING_GATES_FROZEN.md; ticking across
    # tiles, docs/contracts/TICKING_GATES_FROZEN.md): NOT a twin verb —
    # routers aren't a twin registry (TiledGraphRouter's own header
    # comment) — but they land in this same set because `_command_allowed`
    # below is a generic (verb, subverb) two-token check, not twin-specific.
    # BFS/SELECT/STATUS/LIST/GET are read-only (mirrors the daemon's
    # reader-session split — GET is a truth readback, no different from
    # BFS/SELECT); OPEN/CLOSE mutate the router registry, SAVE TILED writes
    # to disk, and TICK mutates (flushes every tile to disk), so those four
    # stay off this allowlist. Note (gate D5, audit B finding 19): tile
    # residency is a CACHE, not graph state, which is why the queries stay
    # here — but `TILED STATUS`'s loads=/evicts= are ROUTER-WIDE counters
    # that any session's query moves, this bridge's included. They report
    # the router, not the caller.
    ("TILED", "BFS"), ("TILED", "SELECT"), ("TILED", "STATUS"), ("TILED", "LIST"),
    ("TILED", "GET"),
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

def _command_allowed(cmd: str, _depth: int = 0) -> bool:
    if ALLOW_WRITE:
        return True
    tokens = cmd.split(None, 2)
    verb = tokens[0].upper() if tokens else ""
    subverb = tokens[1].upper() if len(tokens) > 1 else ""
    # Gate D5, audit B finding 25: `READER <session-id> <anything>` used to
    # pass on the verb READER alone, so the INNER command was gated only by
    # the daemon's own reader matrix. Classify the inner command instead.
    # `_depth` stops a nested `READER x READER y ...` from recursing; the
    # daemon refuses nested sessions anyway.
    if verb == "READER":
        if _depth or len(tokens) < 3:
            return False
        return _command_allowed(tokens[2], _depth + 1)
    return verb in READ_ONLY_VERBS or (verb, subverb) in READ_ONLY_TWIN

# Gate D4, audit B findings 1 and 27. The daemon frames a command at
# MAX_COMMAND_BYTES plus a newline and refuses anything that reaches the cap
# without one. A client that sends more cannot tell a complete command from a
# truncated one, so it refuses with the daemon's own wording instead.
MAX_COMMAND_BYTES = 4095
TOO_LONG = f"ERROR too_long: command exceeds {MAX_COMMAND_BYTES} bytes"


def query_daemon(cmd: str) -> str:
    """Send a command to the daemon and return the response."""
    if len(cmd.strip().encode()) > MAX_COMMAND_BYTES:
        return TOO_LONG
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
