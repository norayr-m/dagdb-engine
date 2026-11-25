# MCP server

`dagdb/mcp_server.py` exposes 116 tools over the Model Context
Protocol. `mcpo` bridges them to HTTP on port 8787.

---

## Surface

- **Base URL:** `http://localhost:8787/dagdb/`
- **Tool catalog:** `http://localhost:8787/dagdb/openapi.json`
- **Swagger UI:** `http://localhost:8787/docs`
- **Config:** `dagdb/mcpo_config.json` (gitignored — has absolute
  paths)
- **Supervisor:** `~/Library/LaunchAgents/com.dagdb.mcpo.plist`

Every tool returns the daemon's raw DSL response verbatim (`OK …`
or `ERROR <category>: <detail>`).

---

## Core tools (37 of the 116)

The other 79 cover back edges and LUT composition, the other bulk
installs, ternary nodes, the twin verb families (STREAM, HEADER,
RECORD, RINGS, CLOCK, GEAR, XCONV, BUDGET, ALARM, VIEW, KERNEL, HOOK,
BANK, FOLD, TWIN) and the tiled router. The tool catalog
(`openapi.json`, above) lists every one with its arguments.

### Lifecycle + info

- `dagdb_status()`
- `dagdb_graph_info()`
- `dagdb_validate()`
- `dagdb_tick(count=1)`
- `dagdb_eval()`
- `dagdb_query(command)` — pass-through for arbitrary DSL

### Read

- `dagdb_nodes(rank=0)`
- `dagdb_traverse(node, depth=2)`
- `dagdb_bfs_depths(seed, backward=False)`
- `dagdb_select_by_truth_rank(truth, rank_lo, rank_hi)`
- `dagdb_ancestry(node, depth)`
- `dagdb_similar_decisions(node, depth, k, among_truth=-1)`
- `dagdb_hive_query(truth=-1, rank_lo=-1, rank_hi=-1, limit=100)`
- `dagdb_distance(metric, rank_range_a, rank_range_b)`

### Mutate

- `dagdb_set_truth(node, value)`
- `dagdb_set_rank(node, rank)`
- `dagdb_set_lut(node, gate)`
- `dagdb_connect(source, target)`
- `dagdb_clear_edges(node)`
- `dagdb_set_ranks_bulk()` — reads a client frame: `[u32 nodeCount][u32 0x314D4801]`
  at shm bytes 0..7, `u64[nodeCount]` at offset 8 (Shared memory input, below)

### Persistence

- `dagdb_save(path, compressed=False)`
- `dagdb_load(path)`
- `dagdb_export_morton(dir)`
- `dagdb_import_morton(dir)`

### JSON / CSV

- `dagdb_save_json(path)` · `dagdb_load_json(path)`
- `dagdb_save_csv(dir)` · `dagdb_load_csv(dir)`

### Backup chain

- `dagdb_backup_init(dir)` · `dagdb_backup_append(dir)`
- `dagdb_backup_restore(dir)` · `dagdb_backup_compact(dir)`
- `dagdb_backup_info(dir)`

### MVCC reader sessions

- `dagdb_open_reader()` · `dagdb_close_reader(session_id)`
- `dagdb_list_readers()`
- `dagdb_reader_query(session_id, command)`

---

## Shared memory results

Most read-path tools write their results to the daemon's result file
(the path given to `--shm-file`; `SHM_FILE` in the examples below)
with an 8-byte header + typed records starting at offset 8. The
MCP response is a one-line status; the client reads shm for the
actual data.

Layouts per tool — see [`data-and-persistence.md`](data-and-persistence.md)
or [`dsl.md`](dsl.md).

Python read template:

```python
import mmap, numpy as np

def read_shm(dtype, count_multiplier=1):
    with open(SHM_FILE, "rb") as f:
        header = f.read(8)
        count = int.from_bytes(header[:4], "little")
        nbytes = count * dtype().itemsize * count_multiplier
        f.seek(8)
        return np.frombuffer(f.read(nbytes), dtype=dtype)

# After dagdb_bfs_depths(seed=0):
depths = read_shm(np.int32)           # length = nodeCount

# After dagdb_ancestry(node=0, depth=5):
ancestry = read_shm(np.int32, 2)       # pairs (node, depth)
pairs = ancestry.reshape(-1, 2)

# After dagdb_select_by_truth_rank(truth=2, rank_lo=0, rank_hi=1000):
ids = read_shm(np.int32)
```

## Shared memory input (client frames)

The tools that read their input from the same file (the bulk
installers, `dagdb_ttable_bulk`, `dagdb_xconv_check`,
`dagdb_xconv_sealed`, `dagdb_budget_open`, `dagdb_bank_generate`,
`dagdb_bank_fit`, and `CONNECT_BACK_BULK` / `SET_TRUTH_BULK` through
`dagdb_query`) read only a frame the caller wrote for that verb
(client_protocol 2; STATUS ends with `client_protocol=2`):
the header `[u32 count][u32 0x314D4800 | code]` little-endian at bytes
0..7, then the payload at offset 8. The codes and each verb's count
are in [`dsl.md`](dsl.md) § Input frames: 1 `SET_RANKS_BULK` …
14 `BANK FIT`. A frame without the header (a previous tool's result, a
never-written file) or one marked for another verb is refused as
`ERROR stale_frame: …`, a wrong count as `ERROR bad_value: … frame
count …`; nothing is written. Every command that writes the shm clears
the mark, so write the header with every frame.

Python write template:

```python
import mmap, struct, numpy as np

CODES = {"SET_RANKS_BULK": 1, "SET_LUTS_BULK": 2, "SET_NEIGHBORS_BULK": 3,
         "SET_MODES_BULK": 4, "SET_TTABLE_IDS_BULK": 5, "SET_THRESH_BULK": 6,
         "TTABLE_BULK": 7, "CONNECT_BACK_BULK": 8, "SET_TRUTH_BULK": 9,
         "XCONV CHECK": 10, "XCONV SEALED": 11, "BUDGET OPEN": 12,
         "BANK GENERATE": 13, "BANK FIT": 14}

def write_frame(verb, count, payload, path=SHM_FILE):
    """[u32 count][u32 0x314D4800 | code] at bytes 0..7, the payload from 8."""
    b = np.ascontiguousarray(payload).view(np.uint8).ravel()
    with open(path, "r+b") as f:
        mm = mmap.mmap(f.fileno(), 0)
        mm[0:8] = struct.pack("<II", count, 0x314D4800 | CODES[verb])
        mm[8:8 + b.size] = b.tobytes()
        mm.close()

# Before dagdb_set_ranks_bulk(), N = nodeCount:
write_frame("SET_RANKS_BULK", N, ranks.astype(np.uint64))
# Before dagdb_set_neighbors_bulk(): the count is nodes, not slots
write_frame("SET_NEIGHBORS_BULK", N, nb.astype(np.int32))      # nb holds N*6
```

---

## HTTP examples

```
curl -s -X POST http://localhost:8787/dagdb/dagdb_status \
     -H "Content-Type: application/json" -d '{}'

curl -s -X POST http://localhost:8787/dagdb/dagdb_bfs_depths \
     -H "Content-Type: application/json" \
     -d '{"seed": 42}'

curl -s -X POST http://localhost:8787/dagdb/dagdb_similar_decisions \
     -H "Content-Type: application/json" \
     -d '{"node": 42, "depth": 2, "k": 5, "among_truth": 2}'
```

---

## Restart cycle

The running mcpo caches config in memory. Edit
`dagdb/mcpo_config.json` or `dagdb/mcp_server.py`, then:

```
launchctl unload ~/Library/LaunchAgents/com.dagdb.mcpo.plist
launchctl load   ~/Library/LaunchAgents/com.dagdb.mcpo.plist
```

Or simply reboot — the agent auto-starts at login.

When you update `mcp_server.py`, LLM tool surfaces only refresh on
the next relaunch. Until then clients see the old tool set.
