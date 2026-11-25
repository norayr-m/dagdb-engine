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
| `.dags` | `SAVE`, `SAVE JSON` (…no, JSON writes `.json`), `BACKUP INIT / COMPACT` | Binary snapshot **v5** (env-origin trailer; v3 body geometry). 32 B header + 42 N-byte body + fixed trailers (back-edge in v4, env in v5), zlib-compressed if requested. | ≈ 42 MB raw, ≈ 11 MB zlib |
| `.dagdb` | Legacy naming (the original `dagdb-engine` used this extension). Accepted by `LOAD`. | Binary snapshot. | Same as `.dags`. |
| `.dagb` | `DagDBDelta` time-series recorder (Savanna playback). | `DAGB` header + per-frame zlib. | Depends on frame count. |
| `.diff` | `BACKUP APPEND` | `DAGD` header (format **2**) + 10 zlib-compressed XOR segments + the back-edge section carried whole. (Format 1, retired, carried 6 segments.) | Typically < 5 % of raw snapshot size per diff. |
| `.wal` | `DAGDB_WAL` daemon mode | `DAGW` header (**version 3**; **4** in place once an import carrying S1–S3 is logged) + length-prefixed records. See "The WAL" below. | Grows with mutation count; `CHECKPOINT` + truncate bounds it. |
| `.json` | `SAVE JSON` | `dagdb-json` v1 mirror of the six engine buffers. | ≈ 5× raw (text). |
| `nodes.csv` / `edges.csv` | `SAVE CSV <dir>` | Two files. | Text; scales linearly. |
| (a directory) | `EXPORT MORTON <dir>` | **Eleven** raw buffer files — the six body lanes `rank.bin`, `truth.bin`, `nodeType.bin`, `lut_low.bin`, `lut_high.bin`, `neighbors.bin`, plus `edge_weights.bin`, `activation.bin`, `node_value.bin`, `is_register.bin` and `back_edges.bin`. See "Morton export" below. | Body ≈ 42 B/node, lanes ≈ 31 B/node more; no compression. |
| (a file) | `HexGrid.save(to:)` (library API) | `DAGG` header + six length-checked sections. See "The grid file" below. | ≈ 37 B/node. |

---

## The WAL

`DAGW` (4 B) + `version` u32 + `nodeCount` u32 + reserved u32, then
records of `length` u32 (payload only) + `opcode` u8 + payload.

**Version 3** (the opcodes below `0x40`–`0x50`: the ternary ones, IMPORT
MORTON's, CONNECT_BACK_BULK's and SET_TRUTH_BULK's, SET_LUTS' and SET_TRUTH
FILL's; version 2 dates from 2026-09-12). Version 1 and 2 files still replay in
full — their opcode sets are subsets — and a version above 6 is refused by
name. The appender keeps an existing file's declared version and refuses by
name any opcode that version does not describe, so a v1 log never gains a
record a v1 reader would not understand.

**Version 4** (the slot model): a version-3 log in which an `IMPORT_PART` / `IMPORT_MORTON`
record may install S1–S3 slots (a duplicate source, a slot self-loop, a rank
inversion). No record layout and no other record's meaning changes. It is
content-gated: a fresh log is still stamped 3, and the first import whose slots
hold S1–S3 rewrites the header's version field from 3 to 4 in place (4 bytes at
offset 4, `F_FULLFSYNC`) before its record(s); a header that cannot be written
refuses the import (`ERROR wal: append: header: …; nothing appended`). Why: a
build before the slot model replays an import record by re-running the import with its
own DAG rule, refuses an S1–S3 import, names it and applies every later record
onto the pre-import graph — a mixture. A v4 header makes that build refuse the
whole log by version instead (`WAL: replay failed: version 4 — continuing
without WAL`): it applies nothing and leaves the log's bytes as they were, and
this build later recovers the disk whole. A log that never took such an import
stays v3 and both builds read it. A crash between the header write and the
record leaves a v4 log holding only v3 records: this build replays it, an
older one refuses it. A planned per-record checksum is to take version 7.

**Version 5** (tick notes):
a version-4 log that may carry `TICK_NOTE` records (`0x52`). On demand, as
for version 4: the first note rewrites the header's version field to 5 in place
(fsynced) before its record; a log with no tick command keeps its version. A
v2–v4 log is upgraded; a v1 log is not (its legacy `SET_RANK` widths are read
only under version 1) and takes no note. An older build refuses a v5
log by name (`WAL: replay failed: version 5 — continuing without WAL`).

**Version 6** (hook sweeps): a version-5 log that may carry `TWIN_HOOK_SWEEP` records (`0x31`),
which remove hook ids from their clocks. On demand, as for version 5: the first
sweep record rewrites the header's version field to 6 (fsynced) before it; a
log that never takes one keeps its version. Two writers: `HOOK CLOSE` of a
hook bound to a clock (the close's `TWIN_CLOSE` and the sweep of its id, in one
append, whole or not at all), and the one sweep after a recovery that found
hook ids an older log or snapshot left on a clock (the boot line
`Twin: swept <n> dangling hook ids left by pre-HOOK1 logs (<n> removed …)`,
`0 removed` included). A v2–v5 log is upgraded; a v1 log is not, so on it
`HOOK CLOSE` of a bound hook refuses by name with nothing written, and names
the way out: SAVE to the startup snapshot path, stop the
daemon, move the log aside and start it again; it loads the snapshot and
opens a fresh version-3 log. The same remedy is named by every refusal a
log's version causes, by the boot line when the sweep cannot be written, and
by `CLOCK ADVANCE` on a clock whose id the sweep could not remove. With the
WAL off nothing records the sweep: the boot line says it is not logged and
repeats at every boot until a SAVE to the startup snapshot writes the state
without the ids. An older
build refuses a v6 log by name (`WAL: replay failed: version 6 —
continuing without WAL`). Replay keeps `TWIN_CLOSE`'s old meaning for a hook
(the hook alone), so a log written by an older build replays as its daemon ran it: a
`CLOCK ADVANCE` whose clock still holds a closed hook's id (the era marker)
replays as one tick and the stop that daemon made live, and the boot counts it
under its own word (`pre_hook1_stop=<k>`, each named), never under `skipped`.

**Slot shapes on replay.** Replayed import records run under the
slot model at every version. An older `SET_NEIGHBORS_BULK` record may
give a register a slot (S4, which the slot model refuses live): it replays as logged, so
recovery equals what that daemon held, and is named on the boot's line
`WAL: applied <k> record(s) as logged that this build refuses live — …`; the
boot then prints `WARN: the recovered state holds <k> slot(s) into a register
(S4) …` naming every such slot (register, slot, source) and the way out
(`CLEAR <dst> EDGES` or `CLEAR <dst> BACK_EDGES`), since SAVE, the autosave
and the writers refuse that state.

**`.dags` and the slot model (no version bump).** Every
`.dags` version 1–8 loads under the slot model: a source out of range is
refused, S1–S3 load. SAVE writes S1–S3 graphs in the same version-7/8 layout,
byte-identical for legal graphs. A build before the slot model refuses such a file by its
own DAG rule, by name, before anything is committed (LOAD: `ERROR io: load:
validation: …`; `DAGDB_STARTUP_LOAD`: exit 2; TILED OPEN: refused), and its
BACKUP RESTORE — which never checked slots — reads a chain holding them with
the same meaning. JSON, CSV and EXPORT directories: no version change either
(an old build refuses S1–S3 in them by its own rule).

| Opcode | Name | Payload | Bytes |
|---|---|---|---|
| `0x01` | `SET_TRUTH` | u32 node + u8 value | 5 |
| `0x02` | `SET_RANK` | u32 node + u64 rank | 12 |
| `0x03` | `SET_LUT` | u32 node + u64 lut | 12 |
| `0x04` | `SET_EDGE_WEIGHT` | u32 node + u8 dir + f32 | 9 |
| `0x05` | `SET_ACTIVATION` | u32 node + i16 | 6 |
| `0x06` | `SET_NODE_VALUE` | u32 node + f32 | 8 |
| `0x10` | `CONNECT_BACK` | u32 src + u32 dst | 8 |
| `0x11` | `CLEAR_BACK_EDGES` | u32 dst | 4 |
| `0x12` | `CONNECT` *(v2)* | u32 dst + u8 slot + i32 src | 9 |
| `0x13` | `CLEAR_EDGES` *(v2)* | u32 node | 4 |
| `0x14` | `SET_RANKS_BULK` *(v2)* | u32 n + u64 rank[n] | 4 + 8n |
| `0x15` | `SET_LUTS_BULK` *(v2)* | u32 n + u64 lut[n] | 4 + 8n |
| `0x16` | `SET_NEIGHBORS_BULK` *(v2)* | u32 n + i32 nb[n·6] | 4 + 24n |
| `0x20`–`0x30` | twin registry ops | per `TwinWALCodec` | varies |
| `0x31` *(v6)* | `TWIN_HOOK_SWEEP`: hook ids removed from their clocks | u32 k + k × (clock id, hook id), u16-length strings | 4 + 4k at least |
| `0x40`–`0x4A` *(v3)* | ternary writes: `SET_MODE`, `SET_TTABLE_ID`, `SET_THRESH`, `SET_TRIT`, `TTABLE DEFINE/PRESET`, `COMPOSE` on tables, the three ternary bulks, `TTABLE_BULK` | per `DagDBWAL.swift`'s header comment | varies |
| `0x4B`–`0x4C` *(v3)* | `IMPORT_PART`, `IMPORT_MORTON`: the bytes of every file the import read | per `DagDBWAL.swift` | the import's size |
| `0x4D`–`0x4E` *(v3)* | `CONNECT_BACK_BULK`, `SET_TRUTH_BULK` | u32 k + k rows | 4 + 8k, 4 + 5k |
| `0x4F` *(v3)* | `SET_LUTS` by selection | selector, range, FILL value or MAP mask + pairs | 26, 27 + 16p |
| `0x50` *(v3)* | `SET_TRUTH … FILL` by selection | u8 selector + u64 lo + u64 hi + u8 value | 18 |
| `0x51` *(any version)* | `SNAPSHOT_BIND`: a durable snapshot's own WAL position | u64 epoch + the SHA-256 of the snapshot file | 40 |
| `0x52` *(v5)* | `TICK_NOTE`: advisory, never applied, written unsynced; one per tick command that ran | u64 the daemon's tick total after it | 8 |
| `0x53` *(v5)* | `COUNTER_DROP`: advisory, never applied, unsynced; the tick counter moved within a life, up or down, by anything but a tick and with no successful durable rebase (a LOAD / LOAD JSON whose rebase failed) | u64 the counter after the change | 8 |
| `0xF0` | `CHECKPOINT` | u64 epoch | 8 |

**Where replay starts (2026-10-19).** Every durable snapshot
— `SAVE`, the autosave, a loader's rebase — writes its `.tmp` file,
fsyncs it, hashes it, and appends and fsyncs a `SNAPSHOT_BIND` record
carrying that digest **before** the rename that makes the file the
snapshot; then the rename, the `.sha256` manifest (the replaced file's
old manifest is removed before the rename), and the `CHECKPOINT`. The
daemon runs one command at a time, so the bind record's position is
exactly the WAL position the file holds. Startup recovery hands replay the
digest of the snapshot it loaded and starts after the **last** bind record
carrying it, whatever checkpoints exist; with none (a snapshot or log from
an older build, a snapshot written without a WAL), after the last
`CHECKPOINT`, as before. In older builds a kill between the rename and the
checkpoint's fsync recovered the new snapshot and replayed the records
written before it a second time, and a failed checkpoint append was
swallowed under a plain `OK SAVE`. Now a bind record that cannot be
appended refuses the snapshot before the rename (`ERROR wal: SAVE refused:
…; nothing renamed`), and a checkpoint that cannot be appended is named in
the reply (`OK SAVE … WARN wal: checkpoint not written (…)`) — recovery is
unaffected, the snapshot is bound. The checkpoint remains for older
readers. A snapshot older than the log's last checkpoint (the
startup path pointing at an older file) now gets the logged records since
it replayed, not skipped; the boot still warns, because the ticks since it
are not in the log.

**No snapshot loaded: the whole log (2026-10-20).** When
startup loads no snapshot — `DAGDB_STARTUP_LOAD` unset, or set to a file
not written yet — the engine is empty and replay starts at the log's
header, ignoring every `CHECKPOINT` and `SNAPSHOT_BIND`: those mark where
some OTHER snapshot's contents end (a `SAVE` to another path), and that
snapshot is not the base. In older builds such a start replayed only the
records after the last checkpoint onto the empty engine. The boot says so
when the log holds a bind record or a checkpoint past epoch 0:
`WAL: no snapshot loaded — the whole log was replayed over the empty engine; …`.

**A torn append is never applied, and nothing follows it.**
A record is appended with `write(2)`; a crash, or a write that fails, can
leave its first k bytes. The appender keeps one invariant: the log ends at
a record boundary whenever an append starts. A write that fails after k
bytes cuts the log back to the record's start (fsynced) before the error is
returned (`ERROR wal: append: io: write record: k/n errno=…; the partial
record cut from the log …`); if that cut itself fails, the appender refuses
every later append, so no record is ever written after the torn bytes. A
crash leaves them as the log's tail: replay drops a record whose declared
length runs past the file's end (`truncatedAtOffset`), and the next start
cuts them before its first append (`WAL: cut <n> byte(s) at offset <o>: …`).
An `IMPORT MORTON` written as several records (`IMPORT_PART`… then
`IMPORT_MORTON`, above 2 GiB) is one unit: a failure part-way cuts the log
back to its first part, and parts a crash left without their closing record
are cut at the next start — left in place, a later import would stage them
on replay. In older builds the torn bytes stayed and the next record was
appended inside the torn record's declared length, so the next replay read
the later records misaligned (applied with garbage, skipped, or trapped).
The model is the one a kill or a failed write gives: a record's bytes reach
the file as a prefix. A power loss that persists a record's later pages
without its earlier ones is not detectable without a per-record checksum,
which this format does not carry.

**What the WAL does not carry.** `TICK` (and `TICK UNTIL_STABLE`,
`TICK_SYNC`) writes no record: a restart recovers tick-computed truth only
as far as the last durable snapshot. Each tick
command that ran (TICK, TICK_SYNC, TICK UNTIL_STABLE, EVAL) appends one
advisory 13-byte `TICK_NOTE` carrying the tick total. It is written
unsynced: it reaches the disk with the next synced write, a
`SAVE` or a checkpoint, so a kill -9 loses none and a power loss can lose
the latest. The boot says what was lost, after replay, relative to the state
it recovered: `WAL: at least <L> ticks were not recovered
(highest logged total <T>, recovered tick count <S>); the recovered truth is
the pre-tick state; earlier restarts, a command interrupted before it
replied, and a power loss can each hide more` (T the highest total among the
notes after the loaded snapshot's position, S the recovered tick count, 0
with no snapshot, L = T − S); `WAL: no lost ticks logged (highest logged
total <T>, recovered tick count <S>; earlier restarts, an interrupted
command, or a power loss can hide ticks)` when L = 0; and
`WAL: tick history unknown` when the log holds no note (a v1–v4 log), never
"0 lost" (with the reason when a total cannot be set against S, e.g. one
above the u32 tick counter's range, or a `COUNTER_DROP` in the window:
`WAL: tick history unknown (the tick counter moved within this window
without a durable rebase: a load whose rebase failed)`). STATUS is unchanged. TILED TICK's per-tile `flush.wal` is not
covered. The four loaders that replace the
engine's state from a file — `LOAD`, `LOAD JSON`, `LOAD CSV`,
`BACKUP RESTORE` — write no record either. Instead (since 2026-10-19),
with the WAL on and `DAGDB_STARTUP_LOAD` set, a successful load ends with
`SAVE`'s own durable snapshot to the startup path (its bind record and
`CHECKPOINT`, below), so recovery restarts from the loaded state, and the reply ends
`wal_base=<path>`. In older builds a restart rebuilt on the snapshot from
before the load, and every later record — the relative ones above all
(`SET_LUTS … MAP`, a `RANK` selection, `SET_TRUTH RANK … FILL`) — landed
on the wrong base. With the WAL on and no `DAGDB_STARTUP_LOAD`, a restart
replays the whole log over an empty engine (below); that
recovers neither a `SAVE`, a `TICK` nor a loader, and the loaders behave as
before there. `IMPORT
MORTON` is logged (`0x4B`/`0x4C`) and needs no snapshot.

The five version-2 opcodes are the combinational-edge and bulk writes that
used to bypass the log entirely, against this file's own promise that every
mutation is appended before it is applied. `CONNECT` carries the SLOT the
daemon chose rather than re-deriving "first free slot" at replay, so the
table comes back the same whatever state replay starts from. The three bulk
installs carry their whole vector because they overwrite the buffer
wholesale; `n` must equal the log's node count or the record is counted as
out-of-range, not applied.

**Payload widths are a version question.** Under version 2 a `SET_RANK`
payload is 12 bytes or the record is torn. Under version 1 the legacy
widths 8 (u32 rank) and 5 (u8 rank) are genuine and still replay. A
`CHECKPOINT` payload is exactly 8 bytes; any other width is a torn
checkpoint — it is not a replay boundary, and the replay window starts past
the last well-formed checkpoint record's own measured length, never a
hardcoded one.

**The replay report.** `DagDBWAL.ReplayResult` carries, beside
`recordsApplied`, `recordsAfterCheckpoint`, `checkpointEpoch`, `elapsedMs`
and `truncatedAtOffset`:

- `fileVersion` — the header's version, 1 or 2.
- `recordsSkipped` — records inside the replay window that were walked past
  instead of applied.
- `skipReasons` — the histogram: `badLength` (payload does not match the
  opcode's shape, or a legacy width no longer legal at this version, or a
  twin payload that does not decode), `outOfRangeIndex` (well-formed but
  names something this engine cannot address — a node at or past
  `nodeCount`, a direction outside 0…5, a bulk vector of the wrong length,
  or a twin id the registry rejects), `unknownOpcode`. `.line` renders it as
  `bad_length=<n> out_of_range=<n> unknown_opcode=<n>`.

- `boundAtOffset`, `boundEpoch`, `bindRecords` — the bind
  record that started the window (nil when the last checkpoint did), its
  epoch, and how many well-formed bind records the log holds.

Startup recovery prints the count on every boot and the histogram whenever
it is non-zero, and says when the snapshot's own bind record started the
window:

```
  WAL: replayed 12 records past epoch 4 (log v2, skipped=0)
  WAL: skipped 3 record(s) — bad_length=2 out_of_range=1 unknown_opcode=0
  WAL: the window starts after the snapshot's own bind record (offset 865, epoch 1), not the last checkpoint
  WAL: no snapshot loaded — the whole log was replayed over the empty engine; its checkpoints (last epoch 0) and 1 bind record(s) belong to snapshots this start did not load
  WAL: cut 6 byte(s) at offset 821: a record cut short (its declared length runs past the end of the file) — replay did not apply them; the next record starts at a record boundary
```

**Truncate refuses while an appender is open.** `DagDBWAL.truncate` renames
a fresh inode over the path; a live `Appender` holds an `O_APPEND`
descriptor on the old one and would keep writing to an unlinked file.
Release the appender first. The daemon's own sequence never needs it — a
durable snapshot writes a `SNAPSHOT_BIND` record and a `CHECKPOINT` into the
live log instead.

---

## Morton export

`EXPORT MORTON <dir>` writes the six body lanes under their original names,
contents and layout, plus five files for the state the six never carried:

| File | Contents |
|---|---|
| `edge_weights.bin` | f32 × nodeCount × 6 |
| `activation.bin` | i16 × nodeCount |
| `node_value.bin` | f32 × nodeCount |
| `is_register.bin` | u8 × nodeCount (1 = back-edge destination) |
| `back_edges.bin` | u32 count + count × (u32 src + u32 dst) |

`IMPORT MORTON` requires the six and reads the five when present. A
directory holding only the original six still imports; the lanes it does
not carry come back at their defaults (weights 1.0, activation 0, value
0.0, no registers), exactly as `LOAD` resets them, rather than leaving the
destination's previous graph in place. Import marks the rank topology
dirty. The register flags are rebuilt from `back_edges.bin`, so
`is_register.bin` is written for external readers and not read back.

---

## The grid file

`HexGrid.save(to:)` / `HexGrid.load(from:)`:

```
Header (16 B): "DAGG" (4) + version u32 (=1) + width u32 + height u32
Then, no padding, in order:
  neighbors     Int32  × n·6
  mortonOrder   UInt32 × n
  mortonToNode  Int32  × n
  mortonRank    Int32  × n
  colors        UInt8  × n
  7 × (UInt32 count + Int32 × count)      — the colour groups
```

`load` throws `HexGrid.GridError` rather than returning nil: a bad magic,
an unknown version, any section short of `n`, a colour-group total that is
not `n`, or any index a section carries that is outside `[0, n)` is refused
by name. Before this the file had no magic and no version, only the
neighbour section's length was checked, and a short file produced a grid
whose arrays were shorter than the node count it advertised.

**What the Morton layout can encode.** The code packs two 16-bit axes. `q`
is the column, so `width ≤ 65536`. `cubeR = r − (c − (c & 1)) / 2` is the
cube row; it is negative for any `width ≥ 3` at low rows and folds as
two's complement, injective exactly while `cubeR ∈ [−32768, 32767]` —
so `height ≤ 32768` and `(width − 1) / 2 ≤ 32768`. The node index space is
`Int32`, so `width × height ≤ 2147483647`. A grid outside that is refused
by name at construction (`HexGrid.validated(width:height:)`, or
`HexGrid.refusalReason` to ask without building) rather than aliased. The
10^11-node target is the tiled world's, across many grids, not one.

---

## Where DagDB's own processes write

### Live daemon runtime files (always in `/tmp`)

| Path | Purpose | Lifetime |
|---|---|---|
| `/tmp/dagdb.sock` | Unix domain socket the daemon listens on. | While daemon runs. Gone on clean shutdown. |
| the `--shm-file` path | Shared-memory query-result buffer. Client reads `Int32` / tuple records starting at offset 8. | While daemon runs. Recreated every startup. |
| `/tmp/dagdb.log` | Daemon stdout+stderr (launchd plist config). | Appended to; rotate manually if it grows. |

None of these are inside the repo. None should be touched by `git`.

### Daemon-level persistence (wired in the launchd plist)

The plist at `~/Library/LaunchAgents/com.dagdb.daemon.plist` ships
these envs:

| Env | Value | Effect |
|---|---|---|
| `DAGDB_DATA_ROOT` | `~/dag_databases` | `guardPath()` rejects any client-supplied path outside this root. Single source of truth for DB storage on this machine. |
| `DAGDB_WAL` | `~/dag_databases/live.wal` | Appends a record for the logged writes (`SET`, `CONNECT`, the bulk verbs, `SET_LUTS`, `SET_TRUTH … FILL`, `IMPORT MORTON`, the ternary writes, the twin registry ops; the opcode table above) before applying them; `TICK` and the four loaders (`LOAD`, `LOAD JSON`, `LOAD CSV`, `BACKUP RESTORE`) write none — see "What the WAL does not carry" above. Replayed on next daemon start, past the loaded snapshot's own bind record (without one, the last checkpoint); with no snapshot loaded, the whole log. A record a crash or a failed write cut short is never applied, and nothing is appended after it. |
| `DAGDB_AUTOSAVE` | `~/dag_databases/auto.dags` | On SIGTERM / SIGINT writes a durable `.dags` snapshot (bind record + checkpoint, as `SAVE`) and exits. It runs only between commands: the command in flight completes, a command not yet started is refused (`ERROR shutdown: the daemon is shutting down; the command was not run`), then the WAL barrier, the snapshot, the exit. In older builds a raw signal handler ran it inside the interrupted command (a half-applied state snapshotted and bound; inside a WAL append, a libdispatch trap and no snapshot). NOT loaded by itself — pair it with `DAGDB_STARTUP_LOAD`. |
| `DAGDB_STARTUP_LOAD` | `~/dag_databases/auto.dags` | (2026-09-09, opt-in) Loads this snapshot at startup, before WAL replay, so a restart after `SAVE`/autosave needs no operator `LOAD`. Missing file = start empty; unreadable or outside the data root = the daemon refuses to start (exit 2). Point it at the file the last `SAVE`/autosave wrote. |

All of them point inside `~/dag_databases/`. Change them in the plist
and `launchctl unload && launchctl load` to pick up new values.

### Launchd plists (outside the repo)

Live under `~/Library/LaunchAgents/`, not in git:

- `com.dagdb.daemon.plist` — supervises the daemon, points at
  `dagdb/.build/release/dagdb-daemon --grid 1024 --shm-file <path>`
  (`--shm-file` is required).
- `com.dagdb.mcpo.plist` — supervises `mcpo` (the MCP HTTP bridge).

### Biology and Loom plugins

Plugin runtime writes (user-configurable; defaults below):

| File | Used by | Default |
|---|---|---|
| `<workspace>/dagdb_ingest_ctx.json` | Loom ingest-context persistence (the Loom adapter). | Home dir, outside repo. |
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

Continuous durability comes from the plist's `DAGDB_WAL` and
`DAGDB_AUTOSAVE`, within what the WAL carries (the opcode table above):
the write verbs are logged, `TICK` is not, so after a hard kill the ticks since the last
durable snapshot are not recovered — `SAVE` to the startup path after
ticks you want to keep. For the state to come back on the next start
without an operator `LOAD`, the daemon also needs `DAGDB_STARTUP_LOAD`
set to the autosave path (opt-in since 2026-09-09); with it set, the four
loaders move recovery's base to the state they loaded.

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
├── base.dags.sha256             # its manifest
├── 00001.diff                   # XOR diff vs tip after base
├── 00001.diff.sha256            # its sidecar, verified before decode
├── 00002.diff                   # XOR diff vs tip after 00001
├── 00002.diff.sha256
├── 00003.diff                   # …
└── …
```

The filename is a convenience; the **sequence number in each diff's
own header** is what orders a replay, so a renamed diff
(`100000.diff` sorts before `99999.diff`) still applies in the right
place. A gap or a duplicate in that sequence is refused by name, and
`BACKUP APPEND` refuses to write over a file already occupying the
next slot.

`BACKUP COMPACT <dir>` folds the whole chain back into a single
`base.dags`, deletes the diffs. `BACKUP RESTORE <dir>` replays the
chain into the live engine.

### What a `.diff` covers — and what it does not

Format 2 (2026-09-12) carries the same per-node state the snapshot
carries, minus the twin registries:

| Segment | Size | How |
|---|---|---|
| rank | 8·N | XOR vs tip |
| truth, nodeType, isRegister | N each | XOR vs tip |
| lut6Low, lut6High, nodeValue | 4·N each | XOR vs tip |
| activation | 2·N | XOR vs tip |
| neighbours, edgeWeights | 24·N each | XOR vs tip |
| back edges | exactly 4 + 8 × pair count | carried whole, un-XORed (variable length) |

On restore the back edges go back through the engine's own add path,
so the latch list and the `isRegister` flags stay consistent — the same
route the snapshot loader takes.

**Not covered: twin state** (streams, rings, clocks, banks, alarms,
folds, views). A restore leaves open twin objects as they are, and both
`BACKUP INFO` and `OK BACKUP_RESTORE` print `twin=not_covered`. The
snapshot's v7 `TWIN` section does carry them; the backup does not,
because by-reference entries need the snapshot's path/sha rules and
that is not a byte-XOR.

A segment whose length disagrees with the buffer it patches is
refused by name — nothing is clamped to the shorter of the two, which
is how a 4-byte rank segment rode an 8-byte rank buffer for months.
The back-edge section is measured against its own pair count, not
against the size the file declares for it: a section that says one
pair must be twelve bytes, and a padded one is refused by name. A
length nobody derives is a length nobody checks.

`BACKUP COMPACT` writes its new base from the chain's own replayed
tip, at the chain's own tick count; it does not read or change the
live engine, so a compaction cannot inherit a mutation the chain does
not hold. Before it writes or deletes anything, the daemon's `BACKUP
COMPACT` asks that tip every rule `BACKUP RESTORE` asks — the back-edge
list's range and CONNECT BACK's rules, the slots against the
persistence rule, the register flags against the list, the ternary
rules — in RESTORE's order and words (`nothing written` for `nothing
restored`): it refuses exactly the chains RESTORE refuses,
so a refused chain never becomes restorable by being compacted.

**Format 1 is refused, not migrated.** It sized the rank segment at 4
bytes per node — the complete ranks of nodes `0..<N/2`, none of the
ranks of nodes `N/2..<N` — and carried no registers, back edges,
weights, activation or node values at all. Those bytes were never
written, so `BACKUP RESTORE` and `BACKUP APPEND` refuse a format-1
chain by name and `BACKUP INFO` names it as a caveat. Re-create the
backup with `BACKUP INIT`.

All diffs are gitignored via `*.diff`. `base.dags` is gitignored
via `*.dags`.

---

## Shared memory record layouts

Query results land in the daemon's `--shm-file` after an 8-byte header
(`[u32 count][u32 reserved]`). Record shapes per command:

| DSL | Record bytes | Fields |
|---|---|---|
| `NODES`, `EVAL`, `TRAVERSE` | 24 (v3, post-u64) | `u64 node`, `u64 rank`, `u8 truth`, `u8 type`, `u8 mode` (byte 18), 5 pad (bytes 19–23, written 0) |
| `BFS_DEPTHS` | 4 | `i32 depth` (indexed by node, not by match) |
| `SELECT` | 4 | `i32 node` |
| `ANCESTRY` | 8 | `i32 node`, `i32 depth` |
| `SIMILAR_DECISIONS` | 8 | `i32 node`, `f32 distance` |

Readers `mmap` the file and slice; no copies needed.

---

## What the twin WAL and the twin snapshot refuse

The twin registries (streams, records, rings, clocks, gears, budget
layouts, alarm sets, wave banks, views, kernel pairs, attention hooks)
persist two ways: as `TwinOp` records inside the WAL, and as the `TWIN`
section of a v7 `.dags` snapshot. Both are read back from bytes a
process did not write, so both refuse rather than trust. The list below
is what they refuse, and why.

**The WAL codec (`TwinWALCodec`).** Decode never throws — its contract
is `nil` on anything malformed, which WAL replay treats as "skip this
record". What that now covers:

- **A count prefix that overshoots its own payload.** Every `u32`
  element count (ring values, budget-layout rows and columns, the
  minTier vector) is checked against the bytes actually remaining
  before a single element is reserved. A 20-byte `ringsWrite` record
  declaring 4 294 967 295 values used to reserve about 17 GB and then
  return `nil`; it now returns `nil` first.
- **A bank spec wider than the machine.** A `bankOpen` payload whose
  sample count exceeds `Int.max` decodes to `nil` instead of trapping
  on the conversion, and a spec the wave bank's own validator rejects
  decodes to `nil` too.
- **On the encode side, which may throw**: a string whose UTF-8 length
  will not fit the 16-bit length field (alarm, view and kernel records
  carry filesystem paths, so this is reachable) refuses rather than
  writing a truncated length beside the full bytes; an `Int` field
  outside `0..<2^32` — a hook's lag `delta`, a hook-step count —
  refuses rather than round-tripping a negative as ≈4.29 × 10⁹; and a
  `bankOpen` spec is validated before any width conversion.

**Replay caps.** Two ops carry a count that commands work rather than
describing bytes: `recordSlice` (draws that many values) and
`clockAdvance` (steps every attached gear and hook that many times).
The record is 20 bytes either way, so the payload ceiling bounds
nothing. Both refuse a count above **10 000** on replay — the same
ceiling the daemon's own `RECORD SLICE` and `CLOCK ADVANCE` verbs
apply, stated once and used in both places.

**The snapshot (`TwinState.Snapshot`).**

- **`formatVersion` must be 1.** It was decoded and never compared, so
  a snapshot from a future version that reshaped the bank, view, kernel
  or hook registries would have restored those registries *empty* and
  reported success. Any other version is now refused by name at decode.
- **A missing or hash-mismatched alarm file drops one entry, not the
  restore** — that was always the documented policy, and it now
  actually holds: an attention hook bound to a dropped alarm set is
  dropped with its own warning instead of failing the whole restore.
  A hook naming an alarm that was never in the snapshot is real
  corruption and still refuses.
- **A hook restores at the frame it recorded, or not at all.** The
  ledger is derived, never stored: restore rebuilds it by re-stepping
  `t` times. Re-stepping is bounded by the hook's own frame count, so a
  snapshot whose `t` exceeded it used to restore silently at a
  *different* frame. Restore now asserts the rebuilt frame equals the
  recorded one and refuses by name otherwise.
- **A phase gear must satisfy its own invariant.** `accumulator <
  denominator` is what the gear maintains while running; a decoded gear
  above it would fire `accumulator/den` extra times on its next tick.
  Decode and the state-bearing initializer both refuse it. A gear ratio
  whose numerator could wrap the accumulator is refused at the same
  door.
- **A stream record's slices and its generator must tell one story.**
  Slice indices are consecutive, each payload matches the count it
  declares, entry draw counters chain, and the last slice's end equals
  the generator's own draw counter. A hand-edited snapshot that
  disagrees is refused at decode and at the state-bearing initializer.

---

## Humble disclaimer

This is a research prototype. Every guarantee above comes from
reading the code on 2026-04-21 and running the tests on one
machine. If something doesn't match reality when you run it, the
code is the source of truth; this page may be stale.
