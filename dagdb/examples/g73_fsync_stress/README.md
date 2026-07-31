# G73 fsync/durability kill-9 stress probe

Exercises the G73 durability hardening end to end against a **scratch** DagDB
daemon:

- WAL group-commit policy (`DAGDB_WAL_FSYNC=grouped:N:MS`),
- kill -9 mid-write, restart, WAL replay,
- snapshot SHA-256 manifest (SAVE writes `<snap>.sha256`, LOAD verifies it).

## Run

```
./probe.sh
```

It builds `dagdb-daemon` in release, then runs `driver.py` for 10 iterations.
Exit 0 iff every iteration recovers within the frozen loss bound and the
manifest verifies. Override iterations with `G73_ITERS=N`.

## What each iteration does

1. Start a scratch daemon on its **own** unix socket
   (`/tmp/dagdb_g73_stress_<pid>_<i>.sock` — never the prod `/tmp/dagdb.sock`),
   with a fresh WAL and `DAGDB_DATA_ROOT` pointing at a throwaway temp dir.
   Policy is `grouped:64:200`, so the loss bound is 64 records.
2. Drive ~1k `SET … TRUTH 1` ops/s, counting acks, and `kill -9` the daemon at
   a random point mid-write.
3. Restart the daemon on the same WAL (it replays), then `GET … TRUTH` every
   acked node and count survivors. `loss = acked − survived` must be
   `0 ≤ loss ≤ 64`.
4. `SAVE` a snapshot, assert the `.sha256` manifest exists, `LOAD` it back and
   assert the manifest verifies.

Every daemon is `SIGKILL`ed in a `finally` block; sockets and temp dirs are
removed.

## Honest caveat on the loss bound

`kill -9` terminates the **process**; the OS keeps `write()`-en-but-not-yet-
`fsync`'d bytes in its buffer cache, so a restart replays them and the observed
loss is **0**. The group-commit bound of N records is the **media-loss** window
that only a real power cut (or a drive that drops its write cache) would open —
exactly what `F_FULLFSYNC` exists to close. This probe cannot induce that on a
running machine, so it validates the recovery *path* and the bound's *ceiling*,
not the physical loss itself. `0 ≤ N` holds; do not read the 0 as proof that
grouped commit is free — under power loss it can lose up to N.

This is an amateur engineering project. We are not HPC professionals and make
no competitive claims.
