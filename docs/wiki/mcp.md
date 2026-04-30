# MCP server

`dagdb/mcp_server.py` exposes 37 tools over the Model Context
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

## Tools (40)

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
- `dagdb_set_lut(node, gate)` — `gate` accepts a named preset
  (`AND`, `OR`, `XOR`, `MAJ`, …) or a 64-bit hex literal in `0x…`
  form (16 hex digits).
- `dagdb_compose_lut(op, src1, dst, src2=-1)` — bitwise composition
  of source LUTs into the destination LUT in one round-trip.
  `op` is one of `AND`, `OR`, `XOR`, `NOT`. For unary `NOT`, omit
  `src2`. Foundation for graph-simplification passes (collapse a
  fused subtree into one node) and policy composition.
- `dagdb_connect(source, target)`
- `dagdb_clear_edges(node)`
- `dagdb_connect_back(source, target)` — register a typed BACK_EDGE
  that latches `truth[source]` into `truth[target]` at every tick
  boundary. `target` must have zero combinational fan-in. See
  [`back-edges.md`](back-edges.md) for the register-pattern
  semantics.
- `dagdb_clear_back_edges(node)` — remove every back-edge whose
  destination is `node`; clears the register flag.
- `dagdb_set_ranks_bulk()`

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

Most read-path tools write their results to `/tmp/dagdb_shm_file`
with an 8-byte header + typed records starting at offset 8. The
MCP response is a one-line status; the client reads shm for the
actual data.

Layouts per tool — see [`data-and-persistence.md`](data-and-persistence.md)
or [`dsl.md`](dsl.md).

Python read template:

```python
import mmap, numpy as np

def read_shm(dtype, count_multiplier=1):
    with open("/tmp/dagdb_shm_file", "rb") as f:
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
