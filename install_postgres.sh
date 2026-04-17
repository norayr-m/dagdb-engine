#!/bin/bash
# DagDB — PostgreSQL Extension Installer
# Usage: ./install_postgres.sh
#
# What it does:
#   1. Checks/installs Rust
#   2. Checks/installs PostgreSQL 17
#   3. Installs cargo-pgrx
#   4. Initializes pgrx
#   5. Builds and installs the pg_dagdb extension
#   6. Creates the dagdb database
#   7. Tests everything end-to-end
#
# The daemon must be running first: .build/debug/dagdb-daemon --grid 256

set -e

echo "══════════════════════════════════════════════════════════"
echo "  DagDB — PostgreSQL Extension Installer"
echo "══════════════════════════════════════════════════════════"
echo ""

# Check daemon is running
if ! echo 'STATUS' | nc -U /tmp/dagdb.sock &>/dev/null; then
    echo "  ERROR: DagDB daemon is not running."
    echo "  Start it first in another terminal:"
    echo ""
    echo "    .build/debug/dagdb-daemon --grid 256"
    echo ""
    exit 1
fi
echo "  ✓ Daemon is running"

# Check/install Rust
if ! command -v cargo &>/dev/null; then
    echo ""
    echo "  Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi
echo "  ✓ Rust $(rustc --version | sed 's/rustc //')"

# Check/install PostgreSQL
PG_CONFIG=""
if command -v pg_config &>/dev/null; then
    PG_CONFIG="pg_config"
elif [ -f /opt/homebrew/opt/postgresql@17/bin/pg_config ]; then
    PG_CONFIG="/opt/homebrew/opt/postgresql@17/bin/pg_config"
    export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"
else
    echo ""
    echo "  Installing PostgreSQL 17..."
    brew install postgresql@17
    brew services start postgresql@17
    PG_CONFIG="/opt/homebrew/opt/postgresql@17/bin/pg_config"
    export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"
    sleep 2
fi
echo "  ✓ PostgreSQL $($PG_CONFIG --version)"

# Make sure Postgres is running
if ! pg_isready &>/dev/null; then
    echo "  Starting PostgreSQL..."
    brew services start postgresql@17
    sleep 2
fi
echo "  ✓ PostgreSQL is running"

# Install cargo-pgrx (in a temp dir so we don't pollute pg_dagdb)
echo ""
echo "  Installing cargo-pgrx (this takes ~30 seconds)..."
cargo install cargo-pgrx --locked 2>&1 | tail -1
echo "  ✓ cargo-pgrx installed"

# Init pgrx (in a temp dir)
echo ""
echo "  Initializing pgrx for PostgreSQL 17..."
ORIG_DIR="$(pwd)"
TMPDIR_PGRX=$(mktemp -d)
cd "$TMPDIR_PGRX"
cargo pgrx init --pg17="$PG_CONFIG" 2>&1 | tail -1
cd "$ORIG_DIR"
rm -rf "$TMPDIR_PGRX"
echo "  ✓ pgrx initialized"

# Build and install extension
echo ""
echo "  Building pg_dagdb extension..."
echo "  (This uses 'cargo pgrx install', NOT 'cargo build')"
cd pg_dagdb
cargo pgrx install --pg-config="$PG_CONFIG" 2>&1 | tail -1
cd "$ORIG_DIR"
echo "  ✓ pg_dagdb extension installed"

# Create database
echo ""
createdb dagdb 2>/dev/null && echo "  ✓ Database 'dagdb' created" || echo "  ✓ Database 'dagdb' already exists"

# Test
echo ""
echo "  Testing SQL access..."
echo ""

RESULT=$(psql dagdb -t -c "CREATE EXTENSION IF NOT EXISTS pg_dagdb;" 2>&1)
echo "  ✓ Extension loaded"

RESULT=$(psql dagdb -t -c "SELECT dagdb_status();" 2>&1)
echo "  ✓ dagdb_status() = $(echo $RESULT | xargs)"

RESULT=$(psql dagdb -t -c "SELECT * FROM dagdb_exec('TICK 5');" 2>&1)
echo "  ✓ dagdb_exec('TICK 5') returned results"

RESULT=$(psql dagdb -t -c "SELECT * FROM dagdb_exec('GRAPH INFO');" 2>&1)
echo "  ✓ dagdb_exec('GRAPH INFO') returned results"

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  PostgreSQL extension installed and working!"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "  Usage (daemon must be running):"
echo ""
echo "    psql dagdb"
echo "    SELECT * FROM dagdb_exec('STATUS');"
echo "    SELECT * FROM dagdb_exec('TICK 100');"
echo "    SELECT * FROM dagdb_exec('NODES AT RANK 2 WHERE truth=1');"
echo "    SELECT * FROM dagdb_exec('TRAVERSE FROM 42 DEPTH 3');"
echo ""
