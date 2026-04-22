# Troubleshooting

In order of frequency, by observed symptom.

---

## "Command not recognised" on a new DSL verb

**Symptom.** `ERROR unknown_command: BFS_DEPTHS FROM 42` (or
`SELECT`, `ANCESTRY`, `SIMILAR_DECISIONS`, `OPEN_READER`, …).

**Cause.** The running daemon binary is older than the source
tree. The launchd supervisor caches the binary it was given in its
plist; rebuilds of the source don't automatically restart.

**Fix.**

```
cd dagdb
swift build -c release
launchctl unload ~/Library/LaunchAgents/com.hari.dagdb.plist
launchctl load   ~/Library/LaunchAgents/com.hari.dagdb.plist
echo "STATUS" | nc -U /tmp/dagdb.sock
```

Or simpler: reboot — launchd auto-starts the agent from the plist,
picking up the fresh binary.

---

## MCP tool not visible via HTTP

**Symptom.** `http://localhost:8787/dagdb/<new_tool>` returns 404,
but the daemon knows the matching DSL.

**Cause.** mcpo caches the tool list from `mcp_server.py` at its
own startup. A newer `mcp_server.py` doesn't show until mcpo
restarts.

**Fix.**

```
launchctl unload ~/Library/LaunchAgents/com.dagdb.mcpo.plist
launchctl load   ~/Library/LaunchAgents/com.dagdb.mcpo.plist

# Verify:
curl -s http://localhost:8787/dagdb/openapi.json \
  | python3 -c "import json,sys; print(len(json.load(sys.stdin)['paths']))"
```

If the count is still wrong, check `dagdb/mcpo_config.json` —
`dagdb` entry should point at `004/dagdb/mcp_server.py`.

---

## "Socket is not connected" transient

**Symptom.** `OSError: [Errno 57] Socket is not connected` mid-run.

**Cause.** Daemon briefly unavailable — typical during a launchd
restart cycle, or under very high burst rate (observed once during stress testing
in ~1500 ops during Pass 1 backfill).

**Fix.**

- Check the daemon is up: `echo STATUS | nc -U /tmp/dagdb.sock`.
- For scripts, add a single retry inside the write path. Or route
  failures through the retry queue (T6 pattern):
  ```python
  resp = _dagdb_write_raw(record)
  if not resp.startswith("OK"):
      _retry_queue.append(record)
  ```

If it's chronic, check `/tmp/dagdb.log` for daemon crashes.

---

## Stale build / module-cache errors

**Symptom.** `SwiftShims.pcm was compiled with module cache path
'<OLD_PATH>/…', but the path is currently '<NEW_PATH>/…'`

**Cause.** Swift's precompiled-module cache baked in the old path
from before a rename or directory move.

**Fix.**

```
cd dagdb
rm -rf .build
swift build -c release
```

Happens after any `git mv` that renames the project dir. Not a
real error — just the cache needs regenerating.

---

## Tests pass but `swift test` output looks garbled

**Symptom.** Interleaved XCTest output mixed with engine boot logs
(7-colour groups, GPU name, etc.).

**Cause.** Each `DagDBEngine` init prints a boot banner. Tests
that create multiple engines create multiple banners.

**Not a bug.** The tests still pass. Filter to a specific suite
for quieter output:

```
swift test --filter DagDBSnapshotTests
```

---

## `ERROR schema: rank violation` during ingest

**Symptom.** `CONNECT FROM <p> TO <q>` rejected with
`ERROR schema: rank violation: src(<p>) rank=<r_p> must be > dst(<q>)
rank=<r_q>`.

**Cause.** The edge goes the wrong way for DagDB's invariant.
Under `rank(src) > rank(dst)`, sources must have higher rank
numbers than destinations.

**Fix.**

- Under the adapter's `rank = maxRank - insert_counter` convention,
  parents (older events) have HIGHER rank than children. Ingestion
  of event N with parent P means `CONNECT FROM P TO N` (P's rank >
  N's rank).
- Under biology's `rank = maxRank - seqIndex`, contacts `(low, high)`
  in sequence order ingest as `CONNECT FROM low TO high` (low has
  higher rank than high).
- If you're using a custom rank policy: make sure the policy's
  assignment satisfies `rank(src) > rank(dst)` for every edge
  you'll emit afterwards. The biology `rank_policies.py` Protocol
  gives you three pre-validated defaults.

---

## Reader session rejects my command

**Symptom.** `ERROR forbidden: command not allowed in reader
session (read-only)`.

**Cause.** The `READER <id> <inner>` envelope only allows
read-only commands. Writes, `EVAL`, nested `READER`, and
`SIMILAR_DECISIONS` are rejected by design.

**Fix.** Move the write off the session path (call it directly
against the primary), then optionally re-open a new session to see
the updated state. For mass-computation reads like
`SIMILAR_DECISIONS`, also call against the primary — the results
don't need point-in-time isolation.

---

## `SELECT` returns stale data

**Symptom.** `SELECT truth k rank lo-hi` returns fewer matches
than expected, even though fresh inserts happened recently.

**Almost never happens — but** if it does: check that the dirty
flag was flipped. Mutations that trigger rebuild:
`SET_TRUTH`, `SET_RANK`, `SET_RANKS_BULK`, `LOAD`, `LOAD_JSON`,
`LOAD_CSV`, `IMPORT`, `BACKUP_RESTORE`.

`CONNECT`, `CLEAR`, `TICK`, `EVAL` do NOT flip the flag — they
don't change `(truth, rank)`. That's correct.

If a non-flipping write path somehow did move a node's truth or
rank, `SELECT` would stay stale until the next flipping mutation
or a daemon restart (which clears the index entirely). Report it
— it would be a bug.

---

## Backup chain too big

**Symptom.** `BACKUP INFO <dir>` reports many diffs, restore is
slow.

**Fix.** Compact.

```
echo "BACKUP COMPACT <dir>" | nc -U /tmp/dagdb.sock
```

Compact folds the whole chain into a new base, deletes the diffs.
Run periodically; there's no auto-compaction.

---

## Launchd brings back the wrong binary after a restart

**Symptom.** After reboot, `STATUS` shows `grid=256` and new DSL
verbs return `unknown_command`.

**Cause.** Launchd plist points at an old binary path.

**Fix.** Check the plist:

```
cat ~/Library/LaunchAgents/com.hari.dagdb.plist | grep -E "Program|Grid"
```

Path should be
`/Users/<you>/000_AI_Work/0_Projects/004_Active_Doing_DagDB/dagdb/.build/release/dagdb-daemon`
and grid 1024. If not, update and reload:

```
launchctl unload ~/Library/LaunchAgents/com.hari.dagdb.plist
# edit the plist
launchctl load   ~/Library/LaunchAgents/com.hari.dagdb.plist
```

---

## Nothing I've done shows up after killing the daemon

**Symptom.** Daemon restarts, graph is empty.

**Cause.** DagDB holds state in memory only. SAVE or WAL or
autosave must be explicitly enabled for state to survive a
restart.

**Fix.**

```
# One-shot save:
echo "SAVE /path/outside/the/repo/snap.dags" | nc -U /tmp/dagdb.sock

# Or enable autosave on the daemon's next start:
DAGDB_AUTOSAVE=/path/outside/the/repo/auto.dags ./dagdb-daemon --grid 1024

# Or WAL for continuous durability:
DAGDB_WAL=/path/outside/the/repo/live.wal ./dagdb-daemon --grid 1024
```

See [`data-and-persistence.md`](data-and-persistence.md) for
where paths should live.

---

## "Why is this file in my `git status`?"

**Symptom.** A `.dags` or `.dagdb` snapshot shows up as untracked.

**Shouldn't happen** — both extensions are gitignored at the repo
root and inside `dagdb/`. If it does:

```
git check-ignore -v <path>
```

If empty, the file slipped through. Add the pattern to
`.gitignore`, commit, and use one of the convention dirs
(`.dagdb-local/`, `data/`, `scratch/`) for future saves.
