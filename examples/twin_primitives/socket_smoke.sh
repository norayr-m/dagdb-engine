#!/bin/zsh
# Live daemon socket smoke for startup recovery (roadmap item 4, 2026-09-09).
# Gate: a daemon restart after SAVE restores graph + twin state with NO
# operator LOAD; a graceful shutdown (autosave + checkpoint) replays 0
# records; a hard kill after a tail replays exactly the tail.
#
# Scratch only: its own data root under ~/dag_databases/test, its own socket.
# Refuses to run if any dagdb-daemon is alive (the shm backing file
# /tmp/dagdb_shm_file is shared by every daemon on this machine).
#
# Usage: examples/twin_primitives/socket_smoke.sh   (from the repo root)
set -u
if pgrep -f dagdb-daemon >/dev/null; then echo "REFUSED: a dagdb-daemon is running"; exit 2; fi
REPO=${0:A:h:h:h}
ROOT=~/dag_databases/test/startup_smoke_$$
TMP=${SMOKE_TMP:-${TMPDIR:-/tmp}}/dagdb_smoke_$$
SOCK=$TMP/smoke.sock
mkdir -p "$ROOT" "$TMP"
( cd "$REPO/dagdb" && swift build -c release --product dagdb-daemon 2>&1 | tail -1 )
BIN="$REPO/dagdb/.build/release/dagdb-daemon"
pass=0; fail=0
check() { # check <label> <actual> <expected-substring>
  if [[ "$2" == *"$3"* ]]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1: got '$2' want '*$3*'"; fi
}
say() { echo "$1" | nc -U "$SOCK"; }
start() { # start <logfile>
  DAGDB_DATA_ROOT="$ROOT" DAGDB_WAL="$ROOT/live.wal" DAGDB_STARTUP_LOAD="$ROOT/auto.dags" DAGDB_AUTOSAVE="$ROOT/auto.dags" \
    "$BIN" --grid 16 --socket "$SOCK" > "$1" 2>&1 &
  PID=$!
  for i in {1..100}; do [[ -S "$SOCK" ]] && break; sleep 0.1; done
  sleep 0.2
}
stop_hard() { kill -9 $PID 2>/dev/null; wait $PID 2>/dev/null; rm -f "$SOCK"; }
stop_soft() { kill -TERM $PID 2>/dev/null; wait $PID 2>/dev/null; rm -f "$SOCK"; }

echo "== A: work, SAVE, hard kill, restart (no LOAD)"
start "$TMP/a.log"
check "A0 startup empty"      "$(grep -c 'no snapshot at' $TMP/a.log)" "1"
say "STREAM OPEN ref 0x853c49e6748fea9b 0xda3e39cb94b95bdb 0x5851f42d4c957f2d 0x14057b7ef767814f" >/dev/null
check "A1 stream next 6"      "$(say 'STREAM NEXT s00000001 6')" "draws=6"
say "CLOCK OPEN" >/dev/null; say "GEAR OPEN c00000001 g 3/7" >/dev/null; say "CLOCK ADVANCE c00000001 10000" >/dev/null
check "A2 gear fires"         "$(say 'GEAR STATE g00000001')" "fires=4285"
check "A3 budget sealed"      "$(say 'BUDGET SEALED')" "id=b00000001"
say "SET 5 TRUTH 1" >/dev/null
S1=$(say 'STREAM STATE s00000001')
check "A4 save"               "$(say "SAVE $ROOT/auto.dags")" "OK SAVE"
stop_hard
start "$TMP/a2.log"
check "A5 startup loaded"     "$(grep -c 'Startup: loaded snapshot' $TMP/a2.log)" "1"
check "A6 replay 0 (checkpoint)" "$(grep -o 'replayed [0-9]* records' $TMP/a2.log)" "replayed 0 records"
check "A7 twin_open=4"        "$(say 'STATUS')" "twin_open=4"
check "A8 stream state exact" "$(say 'STREAM STATE s00000001')" "$S1"
check "A9 gear fires exact"   "$(say 'GEAR STATE g00000001')" "fires=4285"
check "A10 truth restored"    "$(say 'GET 5 TRUTH')" "truth=1"

echo "== B: tail, graceful stop (autosave + checkpoint), restart"
say "STREAM NEXT s00000001 2" >/dev/null
S2=$(say 'STREAM STATE s00000001')
check "B1 draws=8"            "$S2" "draws=8"
stop_soft
check "B2 autosave ran"       "$(grep -c 'Auto-snapshot: OK SAVE' $TMP/a2.log)" "1"
start "$TMP/b.log"
check "B3 replay 0 after autosave" "$(grep -o 'replayed [0-9]* records' $TMP/b.log)" "replayed 0 records"
check "B4 stream state exact" "$(say 'STREAM STATE s00000001')" "$S2"

echo "== C: tail, hard kill, restart = snapshot + exactly the tail"
say "STREAM NEXT s00000001 1" >/dev/null
say "SET 7 TRUTH 1" >/dev/null
S3=$(say 'STREAM STATE s00000001')
stop_hard
start "$TMP/c.log"
check "C1 replay 2 (the tail)" "$(grep -o 'replayed [0-9]* records' $TMP/c.log)" "replayed 2 records"
check "C2 stream state exact" "$(say 'STREAM STATE s00000001')" "$S3"
check "C3 truth from tail"    "$(say 'GET 7 TRUTH')" "truth=1"
check "C4 gear intact"        "$(say 'GEAR STATE g00000001')" "fires=4285"
stop_soft

echo "== D: refusals"
printf 'garbage' > "$ROOT/auto.dags"
DAGDB_DATA_ROOT="$ROOT" DAGDB_STARTUP_LOAD="$ROOT/auto.dags" "$BIN" --grid 16 --socket "$SOCK" > "$TMP/d.log" 2>&1; rc=$?
check "D1 corrupt snapshot fatal (exit 2)" "$rc" "2"
check "D1 message"            "$(grep -c 'FATAL: startup snapshot unreadable' $TMP/d.log)" "1"
DAGDB_DATA_ROOT="$ROOT" DAGDB_STARTUP_LOAD="/tmp/outside.dags" "$BIN" --grid 16 --socket "$SOCK" > "$TMP/d2.log" 2>&1; rc=$?
check "D2 outside data root fatal" "$rc" "2"
check "D2 message"            "$(grep -c 'FATAL: startup snapshot path rejected' $TMP/d2.log)" "1"

rm -rf "$ROOT"
echo "== result: pass=$pass fail=$fail (logs in $TMP)"
[[ $fail -eq 0 ]]
