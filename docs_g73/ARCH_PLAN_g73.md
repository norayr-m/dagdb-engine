# ARCH + PLAN — G73 (frozen 2026-08-01)

## Architecture / failure surfaces
- Appender gains a policy enum: .everyRecord (default) / .grouped(n,ms).
  Grouped path: records appended to the OS file immediately (write()),
  fsync deferred to the earlier of n-records/т-timer/explicit barrier
  (snapshot start, daemon shutdown, env switch = forced sync points).
- Failure surfaces named: (a) timer thread vs appender race → single
  serial queue owns both; (b) torn last record after crash → replay
  already tolerates partial tail? VERIFY; if not, add length-prefix
  validation and stop-at-first-torn-record with counter surfaced;
  (c) manifest written AFTER rename → crash between rename and manifest
  leaves snapshot unverifiable → write manifest to tmp and rename it
  FIRST, snapshot second? NO — snapshot first, manifest second, loader
  treats missing manifest as legacy-accept + warn (migration), bad
  manifest as refuse. Explicitly frozen here.
- F_FULLFSYNC: prod env only (perf cost measured in the probe run).

## Plan (each step lands with its test)
1. Torn-tail audit + fixture test (pre-existing behavior pinned FIRST —
   no feature before the current truth is tested).
2. Policy enum + grouped fsync + forced barriers; unit tests: bound
   honored (records since last sync ≤ n), barrier flushes, default
   unchanged (per-record path byte-identical behavior).
3. SHA-256 manifest write+verify; tests: good load, corrupted byte =
   refuse, missing manifest = warn+accept.
4. examples/g73_fsync_stress/ external probe + README; acceptance test
   in suite (deterministic torn-tail fixture).
Gate: full suite green + all new tests + probe 10/10 iterations clean.
