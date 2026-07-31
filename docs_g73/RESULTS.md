# G73 — fsync/durability hardening: RESULTS

Branch `dag/g73-fsync`. Implemented per the frozen `SPEC_g73.md` /
`ARCH_PLAN_g73.md`. Plan order followed exactly.

## Per-step receipt

**Step 1 — torn-tail audit + fixture test.**
Audit finding: WAL replay ALREADY tolerates a partially-written last record.
Both passes stop at the first record whose declared length prefix does not fit
the remaining file bytes, and the offset is surfaced via
`ReplayResult.truncatedAtOffset`. No crash, no mis-read → no replay-code change
needed. Pinned with `testTornTailFixtureDeterministic`: a hand-truncated
3-record WAL, chopped at both a torn-payload boundary (file→40 B) and a
torn-length-prefix boundary (file→38 B); both replay the two whole records,
leave the torn one unapplied, and report `truncatedAtOffset == 36`.

**Step 2 — WAL group-commit policy + forced barriers.**
`Appender.FsyncPolicy`: `.everyRecord` (default, byte-identical to pre-G73) /
`.grouped(n, ms)`. A single serial `DispatchQueue` owns every fd write, the
`F_FULLFSYNC` calls, and the deferred-fsync `DispatchSourceTimer` — timer and
appends never race (arch failure surface (a)). Grouped: record `write()`-en
immediately (visible to replay), fsync deferred to the earlier of n unsynced
records / ms elapsed / an explicit `barrier()`. `unsyncedCount` exposed for the
bound test. Bad config (n≤0 or ms≤0) degrades to `.everyRecord`. Forced
barriers wired at snapshot start (command handler `.save`) and daemon graceful
shutdown. Config `DAGDB_WAL_FSYNC=grouped:N:MS`; **prod ignores the var**
(always everyRecord + F_FULLFSYNC, asserted in `main`).
Tests: default-unchanged, grouped-bound-honored (≤ n at all times),
barrier-flush, timer-flush, bad-config-degrade.

**Step 3 — snapshot SHA-256 manifest.**
`save()` hashes the FINAL on-disk snapshot bytes and writes `<snap>.sha256`
AFTER the atomic rename (frozen decision), then F_FULLFSYNCs manifest + dir.
`load()` verifies BEFORE any buffer is touched: good → proceed; mismatch →
refuse with named `SnapError.manifestMismatch` (no half-load); missing → warn
+ accept (legacy). New `verifyManifest` flag (default true).
Tests: good-load, one-flipped-byte-refuses (and zero buffers touched),
missing-manifest-warns-and-accepts. Two pre-existing corruption tests
(back-edge range guard, body truncation guard) updated to `verifyManifest:false`
so they still reach the deeper parse guards they target.

**Step 4 — kill-9 stress probe + README.**
`examples/g73_fsync_stress/{probe.sh, driver.py, README.md}`. Scratch daemon on
its own unix socket (never prod `/tmp/dagdb.sock`, never launchctl), fresh WAL +
throwaway `DAGDB_DATA_ROOT`, `grouped:64:200`. ~1k SET-TRUTH ops/s, `kill -9`
mid-write, restart → WAL replay, GET every acked node, then SAVE (asserts
`.sha256` present) + LOAD (asserts manifest verifies). 10 iterations. Every
daemon SIGKILLed in `finally`.

## Probe run (10/10 clean)

Policy `grouped:64:200`, loss bound = 64, grid 64×64, 1500 writes/iter cap.

| iter | acked | survived | loss | bound | manifest | load | result |
|-----:|------:|---------:|-----:|------:|:--------:|:----:|:------:|
| 1  | 660  | 660  | 0 | 64 | ok | ok | PASS |
| 2  | 630  | 630  | 0 | 64 | ok | ok | PASS |
| 3  | 671  | 671  | 0 | 64 | ok | ok | PASS |
| 4  | 765  | 765  | 0 | 64 | ok | ok | PASS |
| 5  | 747  | 747  | 0 | 64 | ok | ok | PASS |
| 6  | 763  | 763  | 0 | 64 | ok | ok | PASS |
| 7  | 805  | 805  | 0 | 64 | ok | ok | PASS |
| 8  | 654  | 654  | 0 | 64 | ok | ok | PASS |
| 9  | 1001 | 1001 | 0 | 64 | ok | ok | PASS |
| 10 | 638  | 638  | 0 | 64 | ok | ok | PASS |

**Observed loss: 0 in every iteration** — within the bound (0 ≤ 64).

### Honest caveat on the observed 0

`kill -9` kills the process, not the drive. The OS keeps
`write()`-en-but-unsynced bytes in its buffer cache, so a same-machine restart
replays them all → 0 loss. The group-commit bound of N records is the
**media-loss** window that only a real power cut (or a drive dropping its write
cache) would open — precisely what `F_FULLFSYNC` closes. This probe validates
the recovery path and the bound's ceiling, not the physical loss. Under actual
power loss, grouped commit can lose up to N records; that is the durability the
caller trades away by opting into `grouped`, and why prod is hard-pinned to
per-record + F_FULLFSYNC.

## Gate

`swift test -c release` full suite green (201 base + 9 new = 210, 0 failures);
probe 10/10 clean.

---
This is an amateur engineering project. We are not HPC professionals and make
no competitive claims.
