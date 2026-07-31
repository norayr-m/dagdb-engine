#!/usr/bin/env bash
# G73 fsync/durability kill-9 stress probe.
#
# Builds the daemon (release) and runs the kill-9 recovery driver for 10
# iterations against a SCRATCH daemon on its own unix socket. Never touches
# the prod /tmp/dagdb.sock and never uses launchctl. Exit 0 only if every
# iteration recovers within the frozen group-commit loss bound and the
# snapshot manifest verifies.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"       # .../dagdb/examples/g73_fsync_stress -> .../dagdb

cd "$REPO"
echo "==> building dagdb-daemon (release)"
swift build -c release --product dagdb-daemon >/dev/null

export DAGDB_DAEMON="$REPO/.build/release/dagdb-daemon"
exec python3 "$HERE/driver.py"
