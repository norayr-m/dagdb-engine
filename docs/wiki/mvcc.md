# MVCC reader sessions

Snapshot-on-read isolation. Readers get a stable point-in-time
view; writers proceed unblocked on the primary engine.

---

## Why it exists

The daemon accepts connections in a single-threaded serial loop.
Before MVCC, a long-running read command (`BFS_DEPTHS` on a
million nodes, a `DISTANCE` computation, a large `TRAVERSE`)
blocked every other command behind it. Every concurrent writer
had to wait.

MVCC decouples the two. A reader opens a session at time T;
subsequent queries against that session see state as of T,
immune to any mutations on the primary in the meantime. Writers
progress unblocked.

---

## Lifecycle

```
OPEN_READER
  → OK OPEN_READER id=r69e7340f00000001 tick=0 open_sessions=1
```

On open, the daemon `memcpy`s the six primary buffers into a
fresh `DagDBEngine`. Session owns that independent copy. Cost:
≈ 38 bytes × nodeCount RAM (≈ 38 MB for a 1 M-node graph).

```
READER <id> <inner read-only command>
```

Routes the inner command to the session's snapshot engine.

```
CLOSE_READER <id>
  → OK CLOSE_READER id=<id> open_sessions=0

LIST_READERS
  → OK LIST_READERS open_sessions=2 id@tick=10 id@tick=20
```

---

## Allowed inner commands

Every read-only verb in the DSL is valid inside the `READER`
envelope:

- `STATUS`
- `GRAPH INFO`
- `NODES [AT RANK <n>] [WHERE …]`
- `TRAVERSE FROM <node> DEPTH <d>`
- `BFS_DEPTHS FROM <seed> [BACKWARD]`
- `DISTANCE <metric> <rangeA> <rangeB>`
- `SELECT truth <k> rank <lo>-<hi>`
- `ANCESTRY FROM <node> DEPTH <d>`
- `VALIDATE`

---

## Rejected inner commands

All mutations, plus a few reads that don't make sense in a session:

- **Writes** (`SET`, `CONNECT`, `CLEAR`, `SET_RANKS_BULK`,
  `BACKUP_*`, `SAVE*`, `LOAD*`, `EXPORT`, `IMPORT`) — sessions are
  read-only by design.
- **`TICK`, `EVAL`** — both mutate the snapshot's buffers via the
  GPU kernel. Rejected even though technically isolated from
  primary.
- **Nested `READER`** — no session inside a session.
- **`SIMILAR_DECISIONS`** — builds per-candidate subgraphs across
  the whole graph. Too expensive for the session model; go
  through the primary.

Rejected commands return `ERROR forbidden: command not allowed in
reader session (read-only)` or similar.

---

## Example

```
# Open a session.
echo "OPEN_READER" | nc -U /tmp/dagdb.sock
# → OK OPEN_READER id=r69e7340f00000001 tick=42 open_sessions=1

SID=r69e7340f00000001

# Writes on primary continue — reader unaffected.
echo "SET 0 TRUTH 2" | nc -U /tmp/dagdb.sock
echo "SET 7 RANK 1000000" | nc -U /tmp/dagdb.sock

# Queries against the session see state as of tick=42.
echo "READER $SID BFS_DEPTHS FROM 42" | nc -U /tmp/dagdb.sock
echo "READER $SID SELECT truth 2 rank 0-4294967295" | nc -U /tmp/dagdb.sock
echo "READER $SID ANCESTRY FROM 42 DEPTH 5" | nc -U /tmp/dagdb.sock

# Close when done.
echo "CLOSE_READER $SID" | nc -U /tmp/dagdb.sock
```

From the MCP:

```python
sid = dagdb_open_reader()  # returns "OK OPEN_READER id=<sid> tick=…"
# parse the id out of the OK line

dagdb_reader_query(sid, "BFS_DEPTHS FROM 42")
dagdb_reader_query(sid, "SELECT truth 2 rank 0-1000000")
dagdb_reader_query(sid, "ANCESTRY FROM 42 DEPTH 5")

dagdb_close_reader(sid)
```

---

## What isolation buys you

- **Consistent multi-query reads.** Three sequential queries
  against the same session all see the same state.
- **Writers unblocked.** While a long read traverses a 1 M-node
  graph on the snapshot, the primary keeps accepting `SET`,
  `CONNECT`, `SAVE`, etc.
- **No version-map complexity.** No `xmin` / `xmax`, no VACUUM,
  no GC thread. Opening a session is one `memcpy` at the cost of
  one buffer snapshot in RAM.

---

## What it doesn't give you

- **No multi-version writes.** There's still one writer at a time
  (serial accept). Concurrent writers aren't unblocked by sessions
  — they're unblocked from *readers*, not from each other.
- **No versioned history.** A session sees state as of its open
  time, full stop. It can't walk backwards to an earlier point.
- **No sub-snapshot granularity.** You can't share one snapshot
  across many sessions cheaply; each `OPEN_READER` does a fresh
  full copy.

For sub-snapshot isolation or for true multi-version history,
you'd need to move from snapshot-on-read to per-node versioning
+ GC. That's a bigger architectural change, deferred.

---

## Session ids

17 chars, deterministic-ordered:

```
r  + 8 hex chars (UInt32(epoch_secs))
   + 8 hex chars (UInt32(monotone_counter))

= r69e7340f00000001
  r69e73411000000a2
```

Collision-free in practice: the counter is monotone, and the
timestamp prefix changes every second.

---

## Memory cost

`OPEN_READER` allocates one full snapshot:

```
rank:      nodeCount * 4 B
truth:     nodeCount * 1 B
nodeType:  nodeCount * 1 B
lut6Low:   nodeCount * 4 B
lut6High:  nodeCount * 4 B
neighbors: nodeCount * 24 B
         = nodeCount * 38 B total
```

For a 1 M-node graph, ≈ 38 MB per session. On the default
`--grid 1024` daemon, 10 simultaneous sessions cost ≈ 380 MB.
Manageable on UMA; budget it if you open many.

`CLOSE_READER` releases the snapshot engine (ARC drops it on next
collection cycle).

`closeAll()` on the `DagDBReaderSessionManager` releases all
sessions at once — useful for clean shutdown.
