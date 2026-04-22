# Quick start

Five minutes from cold repo to running daemon + a first query.

---

## Build

```
cd dagdb
swift build -c release
```

First build is ~30 s; subsequent are under 3 s.

## Run the daemon

```
.build/release/dagdb-daemon --grid 1024 --socket /tmp/dagdb.sock
```

Grid 1024 gives you 1 048 576 nodes. Start smaller (e.g. `--grid 32`
for 1024 nodes) if you're just poking around.

Optional — enable the write-ahead log:

```
DAGDB_WAL=~/.dagdb/live.wal .build/release/dagdb-daemon --grid 1024
```

Optional — autosnapshot on graceful shutdown:

```
DAGDB_AUTOSAVE=~/.dagdb/autosave.dags .build/release/dagdb-daemon --grid 1024
```

See [`data-and-persistence.md`](data-and-persistence.md) for why
these paths stay outside the repo.

## Talk to it

```
echo "STATUS" | nc -U /tmp/dagdb.sock
```

Expected:

```
OK STATUS nodes=1048576 ticks=0 gpu=Apple M5 Max grid=1024x1024 maxRank=16
```

## Seed a tiny chain

```
echo "SET 0 RANK 100"              | nc -U /tmp/dagdb.sock
echo "SET 1 RANK 99"               | nc -U /tmp/dagdb.sock
echo "SET 2 RANK 98"               | nc -U /tmp/dagdb.sock
echo "SET 0 LUT IDENTITY"          | nc -U /tmp/dagdb.sock
echo "SET 1 LUT IDENTITY"          | nc -U /tmp/dagdb.sock
echo "SET 2 LUT IDENTITY"          | nc -U /tmp/dagdb.sock
echo "CONNECT FROM 0 TO 1"         | nc -U /tmp/dagdb.sock
echo "CONNECT FROM 1 TO 2"         | nc -U /tmp/dagdb.sock
```

## Query

Ancestors of node 2:

```
echo "ANCESTRY FROM 2 DEPTH 5" | nc -U /tmp/dagdb.sock
# OK ANCESTRY from=2 depth=5 count=3 elapsed=0.1ms shm_bytes=24
```

Secondary-index select on a `truth` bucket:

```
echo "SELECT truth 0 rank 0-1000" | nc -U /tmp/dagdb.sock
```

Open a reader session (snapshot-on-read):

```
echo "OPEN_READER" | nc -U /tmp/dagdb.sock
# OK OPEN_READER id=r69e76bde00000001 tick=0 open_sessions=1

echo "READER r69e76bde00000001 ANCESTRY FROM 2 DEPTH 5" \
  | nc -U /tmp/dagdb.sock
```

## Save and restore

```
echo "SAVE ~/.dagdb/tinychain.dags COMPRESSED" | nc -U /tmp/dagdb.sock
# later:
echo "LOAD ~/.dagdb/tinychain.dags"            | nc -U /tmp/dagdb.sock
```

Snapshots outside the repo are always safe; the repo's gitignore
also blocks `.dags` anywhere inside the tree as a second line of
defence.

## Python / MCP

If you have `mcpo` running (the launchd agent does this
automatically), HTTP clients see the same API:

```
curl -s -X POST http://localhost:8787/dagdb/dagdb_status \
     -H "Content-Type: application/json" -d '{}'
```

37 endpoints under `/dagdb/`. See [`mcp.md`](mcp.md).

## Run the tests

```
cd dagdb
swift test                                        # 98 Swift tests, ~2.8 s
python3 plugins/biology/rank_policies.py          # self-test
python3 -m pytest plugins/loom/test_adapter.py -q # 16 pytest tests
```

## Where to go next

- [`data-and-persistence.md`](data-and-persistence.md) —
  understand exactly where each file goes before you save anything
  real.
- [`dsl.md`](dsl.md) — every DSL command.
- [`queries.md`](queries.md) — BFS, distance metrics, similarity.
- [`mvcc.md`](mvcc.md) — reader sessions.
