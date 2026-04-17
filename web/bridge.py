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

def query_daemon(cmd: str) -> str:
    """Send a command to the daemon and return the response."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
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

async def handler(websocket):
    """Handle one WebSocket client."""
    print(f"  Client connected: {websocket.remote_address}")
    try:
        async for message in websocket:
            cmd = message.strip()
            if not cmd:
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

    async with websockets.serve(handler, "localhost", WS_PORT):
        print(f"  Listening on ws://localhost:{WS_PORT}")
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
