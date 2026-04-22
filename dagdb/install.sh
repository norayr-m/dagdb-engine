#!/bin/bash
# DagDB — One-command install and test
# Usage: ./install.sh
#
# What it does:
#   1. Builds the engine (swift build)
#   2. Runs tests (swift test)
#   3. Starts the daemon
#   4. Runs a quick smoke test
#   5. Shows you the commands
#
# Requirements: macOS 14+, Apple Silicon, Xcode CLI tools

set -e

echo "══════════════════════════════════════════════════════════"
echo "  DagDB Installer"
echo "══════════════════════════════════════════════════════════"
echo ""

# Check Apple Silicon
if [ "$(uname -m)" != "arm64" ]; then
    echo "  ERROR: DagDB requires Apple Silicon (M1/M2/M3/M4/M5)"
    exit 1
fi

# Check Swift
if ! command -v swift &>/dev/null; then
    echo "  ERROR: Swift not found. Install Xcode Command Line Tools:"
    echo "         xcode-select --install"
    exit 1
fi
echo "  ✓ Swift $(swift --version 2>&1 | head -1 | sed 's/.*version //' | sed 's/ .*//')"

# Build
echo ""
echo "  Building..."
swift build 2>&1 | tail -1
echo "  ✓ Build complete"

# Test
echo ""
echo "  Running tests..."
RESULT=$(swift test 2>&1)
PASSED=$(echo "$RESULT" | grep -o "Executed [0-9]* tests, with 0 failures" | head -1)
if [ -n "$PASSED" ]; then
    echo "  ✓ $PASSED"
else
    echo "  ✗ Some tests failed. Run 'swift test' for details."
    exit 1
fi

# Kill any existing daemon
pkill -f dagdb-daemon 2>/dev/null || true
sleep 1

# Start daemon
echo ""
echo "  Starting daemon (256x256 grid = 65,536 nodes)..."
.build/debug/dagdb-daemon --grid 256 &>/dev/null &
DAEMON_PID=$!
sleep 2

# Smoke test
echo ""
echo "  Smoke test..."
STATUS=$(echo 'STATUS' | nc -U /tmp/dagdb.sock 2>/dev/null)
if echo "$STATUS" | grep -q "OK STATUS"; then
    echo "  ✓ $STATUS"
else
    echo "  ✗ Daemon not responding. Check: .build/debug/dagdb-daemon --grid 256"
    kill $DAEMON_PID 2>/dev/null
    exit 1
fi

TICK=$(echo 'TICK 10' | nc -U /tmp/dagdb.sock 2>/dev/null)
echo "  ✓ $TICK"

INFO=$(echo 'GRAPH INFO' | nc -U /tmp/dagdb.sock 2>/dev/null)
echo "  ✓ $INFO"

# Done
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  DagDB is running! Daemon PID: $DAEMON_PID"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "  Try these commands (in any terminal):"
echo ""
echo "    echo 'STATUS' | nc -U /tmp/dagdb.sock"
echo "    echo 'TICK 100' | nc -U /tmp/dagdb.sock"
echo "    echo 'NODES AT RANK 0' | nc -U /tmp/dagdb.sock"
echo "    echo 'SET 0 TRUTH 1' | nc -U /tmp/dagdb.sock"
echo "    echo 'TRAVERSE FROM 0 DEPTH 3' | nc -U /tmp/dagdb.sock"
echo "    echo 'GRAPH INFO' | nc -U /tmp/dagdb.sock"
echo ""
echo "  To stop: kill $DAEMON_PID"
echo ""
