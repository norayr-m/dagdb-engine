#!/bin/zsh
# start_sandbox.sh — run one DagDB daemon whose every file lives under ONE root, failing closed.
#
#   scripts/start_sandbox.sh <root> [grid] [maxRank]     start (background), print the socket
#   scripts/start_sandbox.sh <root> stop                 SIGTERM the daemon recorded in <root>/daemon.pid
#
# Everything the daemon writes goes under <root>: data root (guardPath), WAL, result-row file
# (--shm-file), socket, pid, stdout log (the log echoes command responses, so it is content and
# stays under the root). Nothing goes to /tmp or ~/dag_databases. DAGDB_ENV is unset on purpose:
# an env-bound daemon forces its data root to ~/dag_databases/<env>.
# If <root> sits under /Volumes/<vol> and that volume is not mounted, it refuses (exit 3).
# The daemon is launched with MallocLargeCache=0, so freed large blocks go back to
# the OS between commands (the memory budget reads the process's phys_footprint, which counts the
# blocks malloc keeps); DAGDB_SANDBOX_MEM_BUDGET_GB=<G> passes --mem-budget-gb <G>. After the start
# it prints the budget in effect, from the daemon's own log line. Any other launcher should set
# MallocLargeCache=0 itself.
set -eu
ROOT=${1:?usage: start_sandbox.sh <root> [grid] [maxRank] | <root> stop}
HERE=${0:A:h}
BIN=${DAGDB_DAEMON_BIN:-$HERE/../.build/release/dagdb-daemon}

if [[ $ROOT == /Volumes/* ]]; then
  VOL=/Volumes/${${ROOT#/Volumes/}%%/*}
  if ! mount | grep -q " on $VOL "; then
    print -u2 "REFUSED: $VOL is not mounted; the sandbox root must be on it (fail closed)"; exit 3
  fi
fi

if [[ ${2:-} == stop ]]; then
  [[ -f $ROOT/daemon.pid ]] || { print -u2 "no daemon.pid under $ROOT"; exit 1 }
  kill -TERM $(<$ROOT/daemon.pid) && rm -f $ROOT/daemon.pid && print "stopped"; exit 0
fi

GRID=${2:-256}; MAXRANK=${3:-16}
# Before launch: a binary built before --shm-file would write to /tmp before any check could stop it.
[[ -x $BIN ]] || { print -u2 "REFUSED: no daemon binary at $BIN"; exit 8 }
grep -aq 'Result-row file (--shm-file)' $BIN || { print -u2 "REFUSED: $BIN predates --shm-file; rebuild: swift build -c release --product dagdb-daemon"; exit 7 }
mkdir -p $ROOT; chmod 700 $ROOT
SOCK=$ROOT/dagdb.sock
(( ${#SOCK} < 104 )) || { print -u2 "REFUSED: socket path ${#SOCK} chars, the limit is 103"; exit 4 }
if [[ -f $ROOT/daemon.pid ]] && kill -0 $(<$ROOT/daemon.pid) 2>/dev/null; then
  print -u2 "REFUSED: a daemon is already running for this root (pid $(<$ROOT/daemon.pid))"; exit 5
fi
rm -f $SOCK
BUDGET_ARGS=()
[[ -n ${DAGDB_SANDBOX_MEM_BUDGET_GB:-} ]] && BUDGET_ARGS=(--mem-budget-gb $DAGDB_SANDBOX_MEM_BUDGET_GB)
# DAGDB_SANDBOX_WAL=off runs the daemon without a write-ahead log (timing runs that never
# need replay); anything else — the default — keeps the WAL under the root as before.
if [[ ${DAGDB_SANDBOX_WAL:-on} == off ]]; then
  env -u DAGDB_ENV -u DAGDB_WAL DAGDB_DATA_ROOT=$ROOT MallocLargeCache=0 \
    nohup $BIN --grid $GRID --max-rank $MAXRANK --socket $SOCK --shm-file $ROOT/dagdb_shm $BUDGET_ARGS \
    > $ROOT/daemon.log 2>&1 &
else
  env -u DAGDB_ENV DAGDB_DATA_ROOT=$ROOT DAGDB_WAL=$ROOT/dagdb.wal MallocLargeCache=0 \
    nohup $BIN --grid $GRID --max-rank $MAXRANK --socket $SOCK --shm-file $ROOT/dagdb_shm $BUDGET_ARGS \
    > $ROOT/daemon.log 2>&1 &
fi
print $! > $ROOT/daemon.pid
for i in {1..80}; do [[ -S $SOCK ]] && break; sleep 0.25; done
[[ -S $SOCK ]] || { print -u2 "daemon did not open its socket; see $ROOT/daemon.log"; exit 6 }
# Fail closed on a stale binary: a daemon built before --shm-file ignores the flag and writes its
# result rows to /tmp/dagdb_shm_file. The result file must exist under the root, and the log must say so.
if [[ ! -f $ROOT/dagdb_shm ]] || ! grep -q "Shared memory: .* at $ROOT/dagdb_shm" $ROOT/daemon.log; then
  kill -TERM $(<$ROOT/daemon.pid) 2>/dev/null; rm -f $ROOT/daemon.pid
  print -u2 "REFUSED: the daemon did not put its result file under the root (binary older than --shm-file?): $BIN"
  print -u2 "         rebuild with: swift build -c release --product dagdb-daemon"; exit 7
fi
# The budget in effect, as the daemon states it (an older binary states none).
BLINE=$(grep -m1 "Memory budget: " $ROOT/daemon.log 2>/dev/null || true)
if [[ -n $BLINE ]]; then
  print "memory budget ${${BLINE#*Memory budget: }%% MallocLargeCache=*} (launched with MallocLargeCache=0)"
else
  print "memory budget: not stated by this binary (an older build); launched with MallocLargeCache=0"
fi
# The QoS the daemon runs at, the condition its time bounds hold under.
QLINE=$(grep -m1 "  QoS: " $ROOT/daemon.log 2>/dev/null || true)
if [[ -n $QLINE ]]; then
  print "qos ${QLINE#*QoS: }"
else
  print "qos: not stated by this binary (an older build)"
fi
print "socket $SOCK"
