# Data and persistence — where every byte lives

> Amateur engineering project. Errors likely.

This page is the direct answer to "**where are my database files,
and how do I keep them off GitHub?**"

---

## Short answer

1. **Single persistent DB root: `~/dag_databases/`.** Everything
   DagDB persists on this machine — WAL, autosave, backups, user
   snapshots — lives in that one directory. Created 0700, owner-only.
2. **Hardened at daemon level.** The launchd plist sets
   `DAGDB_DATA_ROOT=~/dag_databases`, so every `SAVE`/`LOAD`/`BACKUP`
   path is rejected by the daemon's `guardPath()` unless it resolves
   inside that root. Traversal segments (`..`) are rejected outright.
3. **Nothing is saved unless you ask — or autosave is enabled.** The
   daemon runs in memory. `DAGDB_WAL` and `DAGDB_AUTOSAVE` (both now
   set by the plist to `~/dag_databases/live.wal` and
   `~/dag_databases/auto.dags`) add continuous durability.
4. **The repo's `.gitignore` blocks every known output extension**
   (`.dags`, `.dagdb`, `.dagb`, `.diff`, `.wal`, `.log`). Even if
   you save inside the repo tree, `git add .` will not pick it up.
5. **Exactly one demo file is tracked on purpose**:
   `dagdb/sample_db/demo_graph.dagdb`. Any other `.dagdb` or `.dags`
   under the repo is ignored — no exceptions.
6. **Convention dirs** inside the repo — `.dagdb-local/`, `data/`,
   `scratch/` — are always-ignored for ad-hoc work. They exist only
   so you can keep short-lived scratch near the code; the real home
   for anything you want to keep is `~/dag_databases/`.

---

## The file types DagDB writes

| Extension | Written by | Format | Size per million nodes |
|---|---|---|---|
| `.dags` | `SAVE`, `SAVE JSON` (…no, JSON writes `.json`), `BACKUP INIT / COMPACT` | Binary snapshot v2. 32 B header + 38 N-byte body, zlib-compressed if requested. | ≈ 38 MB raw, ≈ 10 MB zlib |
| `.dagdb` | Legacy naming (the original `dagdb-engine` used this extension). Accepted by `LOAD`. | Binary snapshot. | Same as `.dags`. |
| `.dagb` | `DagDBDelta` time-series recorder (Savanna playback). | `DAGB` header + per-frame zlib. | Depends on frame count. |
| `.diff` | `BACKUP APPEND` | `DAGD` header + 6 zlib-compressed XOR segments. | Typically < 5 % of raw snapshot size per diff. |
| `.wal` | `DAGDB_WAL` daemon mode | `DAGW` header + length-prefixed records. | Grows with mutation count; `CHECKPOINT` + truncate bounds it. |
| `.json` | `SAVE JSON` | `dagdb-json` v1 mirror of the six engine buffers. | ≈ 5× raw (text). |
| `nodes.csv` / `edges.csv` | `SAVE CSV <dir>` | Two files. | Text; scales linearly. |
| (a directory) | `EXPORT MORTON <dir>` | Six raw buffer files — `rank.bin`, `truth.bin`, `nodeType.bin`, `lut_low.bin`, `lut_high.bin`, `neighbors.bin`. | Same as snapshot body; no compression. |

---

## Where DagDB's own processes write

### Live daemon runtime files (always in `/tmp`)

| Path | Purpose | Lifetime |
|---|---|---|
| `/tmp/dagdb.sock` | Unix domain socket the daemon listens on. | While daemon runs. Gone on clean shutdown. |
| `/tmp/dagdb_shm_file` | Shared-memory query-result buffer. Client reads `Int32` / tuple records starting at offset 8. | While daemon runs. Recreated every startup. |
| `/tmp/dagdb.log` | Daemon stdout+stderr (launchd plist config). | Appended to; rotate manually if it grows. |

None of these are inside the repo. None should be touched by `git`.

### Daemon-level persistence (wired in the launchd plist)

The plist at `~/Library/LaunchAgents/com.hari.dagdb.plist` ships
these envs:

| Env | Value | Effect |
|---|---|---|
| `DAGDB_DATA_ROOT` | `~/dag_databases` | `guardPath()` rejects any client-supplied path outside this root. Single source of truth for DB storage on this machine. |
| `DAGDB_WAL` | `~/dag_databases/live.wal` | Appends mutation WAL on every `SET`/`CONNECT`/`LOAD`. Replayed on next daemon start. |
| `DAGDB_AUTOSAVE` | `~/dag_databases/auto.dags` | Writes a `.dags` snapshot on SIGTERM / graceful exit. Loaded on next daemon start. |

All three point inside `~/dag_databases/`. Change them in the plist
and `launchctl unload && launchctl load` to pick up new values.

### Launchd plists (outside the repo)

Live under `~/Library/LaunchAgents/`, not in git:

- `com.hari.dagdb.plist` — supervises the daemon, points at
  `dagdb/.build/release/dagdb-daemon --grid 1024`.
- `com.dagdb.mcpo.plist` — supervises `mcpo` (the MCP HTTP bridge).

### Biology and Loom plugins

Plugin runtime writes (user-configurable; defaults below):

| File | Used by | Default |
|---|---|---|
| `~/jarvis_workspace/dagdb_ingest_ctx.json` | Loom ingest-context persistence (the T4 adapter). | Home dir, outside repo. |
| `dagdb/plugins/loom/_backfill_out/` | Backfill debug output. | **Gitignored.** |

---

## Where things live inside the repo

Tracked and safe to push:

```
dagdb/
├── Package.swift
├── Sources/                 # Swift source — safe
├── Tests/                   # Swift + Python tests — safe
├── plugins/                 # rank_policies.py + loom adapter — safe
├── pg_dagdb/                # Postgres extension — safe
├── web/bridge.py            # Browser bridge — safe
├── sample_db/
│   ├── demo_graph.dagdb     # The ONE tracked sample; everything else ignored
│   └── README.md            # About the demo data
├── mcp_server.py            # MCP shim — safe
└── …
```

Gitignored, never committed:

```
.build/                      # compiled Swift
.dagdb-local/                # convention: your DB work lives here
data/                        # convention: user data
scratch/                     # convention: experiments
mcpo_config.json             # has absolute machine paths
Sources/DagDBDaemon/*.bak    # sed backup artefacts
plugins/loom/_backfill_out/  # Loom backfill debug
__pycache__/                 # Python bytecode
.pytest_cache/               # pytest state
*.dags                       # every snapshot file
*.dagdb                      # except demo_graph.dagdb (one allow-listed sample)
*.dagb                       # every delta-codec file
*.diff                       # every backup-chain diff
*.wal                        # every write-ahead log
*.log                        # every stray log
```

---

## How to guarantee your own DB files never reach GitHub

### The policy

All persistent DB content on this machine lives under
`~/dag_databases/`. The daemon refuses to write anywhere else
(`DAGDB_DATA_ROOT` guard). The one exception is the single
allow-listed demo (`dagdb/sample_db/demo_graph.dagdb`) which is
intentionally tracked in git because the quick-start tutorial loads
it.

Two layers enforce this:

1. **Daemon guard** — any `SAVE`/`LOAD`/`BACKUP`/`EXPORT`/`IMPORT`/
   `SAVE_JSON`/`LOAD_JSON`/`SAVE_CSV`/`LOAD_CSV` with a path outside
   `~/dag_databases/` returns `ERROR io: path: '<p>' outside
   DAGDB_DATA_ROOT`. Traversal (`..`) is also rejected.
2. **Repo gitignore** — all known DB extensions (`*.dags`, `*.dagdb`,
   `*.dagb`, `*.diff`, `*.wal`, `*.log`) are blocked at both the 004
   root and `dagdb/`. Only `sample_db/demo_graph.dagdb` is
   allow-listed.

### Typical usage

```
# One-shot save (path MUST start with ~/dag_databases/):
echo "SAVE /Users/you/dag_databases/loom_2026-04-21.dags COMPRESSED" \
  | nc -U /tmp/dagdb.sock

# Backup chain:
echo "BACKUP INIT /Users/you/dag_databases/loom_chain/" \
  | nc -U /tmp/dagdb.sock

# Restore later:
echo "BACKUP RESTORE /Users/you/dag_databases/loom_chain/" \
  | nc -U /tmp/dagdb.sock
```

Continuous durability is already on via the plist's `DAGDB_WAL` and
`DAGDB_AUTOSAVE`. You don't need to issue `SAVE` unless you want a
named snapshot.

### Verifying before push

```
# What's new or modified?
git status

# What would `git add .` stage right now?
git add -n .

# If something unexpected shows up, don't commit it — add its path
# to .gitignore first, then git rm --cached <path> if needed.
```

### Verifying before push

```
# What's new or modified?
git status

# What would `git add .` stage right now?
git add -n .

# If something unexpected shows up, don't commit it — add its path
# to .gitignore first, then git rm --cached <path> if needed.
```

---

## Backup chain layout

When you `BACKUP INIT <dir>`, DagDB creates:

```
<dir>/
├── base.dags                    # full snapshot, zlib-compressed
├── 00001.diff                   # XOR diff vs tip after base
├── 00002.diff                   # XOR diff vs tip after 00001
├── 00003.diff                   # …
└── …
```

`BACKUP COMPACT <dir>` folds the whole chain back into a single
`base.dags`, deletes the diffs. `BACKUP RESTORE <dir>` replays the
chain into the live engine.

All diffs are gitignored via `*.diff`. `base.dags` is gitignored
via `*.dags`.

---

## Shared memory record layouts

Query results land at `/tmp/dagdb_shm_file` after an 8-byte header
(`[u32 count][u32 reserved]`). Record shapes per command:

| DSL | Record bytes | Fields |
|---|---|---|
| `NODES`, `EVAL`, `TRAVERSE` | 24 (v3, post-u64) | `u64 node`, `u64 rank`, `u8 truth`, `u8 type`, 6 pad |
| `BFS_DEPTHS` | 4 | `i32 depth` (indexed by node, not by match) |
| `SELECT` | 4 | `i32 node` |
| `ANCESTRY` | 8 | `i32 node`, `i32 depth` |
| `SIMILAR_DECISIONS` | 8 | `i32 node`, `f32 distance` |

Readers `mmap` the file and slice; no copies needed.

---

## Humble disclaimer

This is a research prototype. Every guarantee above comes from
reading the code on 2026-04-21 and running the tests on one
machine. If something doesn't match reality when you run it, the
code is the source of truth; this page may be stale.
