# BFS primitive — usage cheat sheet

> Amateur engineering project. Shipped 2026-04-20, updated for u32
> rank + MVCC on 2026-04-21.

## From Swift (library)

```swift
import DagDB

let grid = HexGrid(width: 32, height: 32)
let state = DagDBState(width: 32, height: 32)
let engine = try DagDBEngine(grid: grid, state: state, maxRank: 200)

// ... ingest protein contact graph into engine buffers ...
// single-node-per-residue: node i = residue i at rank (maxRank - i)
// one edge per contact (p, q) with p < q: src = p, dst = q

let r = try DagDBBFS.bfsDepthsUndirected(
    engine: engine, nodeCount: engine.nodeCount, from: seedResidue
)
// r.depths: [Int32] of length nodeCount
// r.reached, r.maxDepth, r.elapsedMs available
// -1 for unreachable, 0 for the seed, positive = depth
```

## From the daemon DSL

```
BFS_DEPTHS FROM 42                  # undirected (default)
BFS_DEPTHS FROM 42 BACKWARD         # follow inputs[] only
```

Response:

```
OK BFS_DEPTHS seed=42 dir=undirected reached=198 max_depth=9
              elapsed=0.7ms shm_bytes=4096
```

Under a reader session (point-in-time snapshot):

```
OPEN_READER                                # → OK OPEN_READER id=r…
READER <id> BFS_DEPTHS FROM 42
CLOSE_READER <id>
```

## From Python / MCP

```python
# Via MCP tool
dagdb_bfs_depths(seed=42)                # undirected
dagdb_bfs_depths(seed=42, backward=True) # backward

# Under a reader session
sid = dagdb_open_reader()                # returns "OK OPEN_READER id=…"
dagdb_reader_query(sid, "BFS_DEPTHS FROM 42")
dagdb_close_reader(sid)

# Zero-copy numpy view of the depth vector
import numpy as np
with open("/tmp/dagdb_shm_file", "rb") as f:
    buf = f.read()
node_count = int.from_bytes(buf[0:4], "little")
depths = np.frombuffer(buf[8:8 + node_count*4], dtype=np.int32)
# depths.shape == (node_count,)
# depths[i] = BFS depth of node i from seed, or -1 if unreachable
```

## Ingestion pattern (single-node-per-residue)

Each residue is one DagDB node. Rank assignment:
`rank(node_i) = maxRank - seqIndex(i)`. Every contact `(p, q)` with
`p < q` becomes one directed edge from node `p` to node `q`.

Python pseudo-code using the new `SET_RANKS_BULK` fast path:

```python
import numpy as np
from dagdb.plugins.biology.rank_policies import SequencePositionPolicy

N = len(residues)
max_rank = N                    # u32 now — up to 4 294 967 295

# 1. Compute rank vector via the plugin Protocol
policy = SequencePositionPolicy()
ranks = policy.assign_ranks(
    node_count=N, max_rank=max_rank,
    seq_indices=np.arange(N),
)

# 2. Write ranks to shm at offset 8, then bulk-commit in one round-trip
import mmap
with open("/tmp/dagdb_shm_file", "r+b") as f:
    mm = mmap.mmap(f.fileno(), 8 + N * 4)
    mm[8 : 8 + N * 4] = ranks.tobytes()
    mm.close()

dagdb_set_ranks_bulk()          # daemon memcpys into rankBuf

# 3. Set LUTs + connect edges
for i in range(N):
    dagdb_set_lut(node=i, gate="IDENTITY")

for p, q in contacts:            # contacts must be (low, high)
    assert p < q
    dagdb_connect(source=p, target=q)

# 4. Run BFS from seed
dagdb_bfs_depths(seed=0)
# Parse numpy view of shm as above
```

## No more u8 rank limit

Rank is now `UInt32`. Caps per-instance rank at 4 294 967 295.
Biology ingestion comfortably scales to full-chain proteins; Loom
insert-counter scales to billions of events.

## Verification against a reference BFS

Run a reference CSR BFS on the same graph and DagDB on the same
residue ordering — depth vectors should be identical. If they
diverge, the most likely cause is an edge that violates the rank
rule on insert (the validator would have rejected it) or a contact
pair passed in the wrong order (`p` must be less than `q`).

## Truth-filtered hive queries

Once ingestion is done, the secondary index enables
`(truth, rank-range)` lookups:

```
SELECT truth 2 rank 0-1000      # first 1000 dialogue_turn events
```

Results land as `Int32[]` in shm starting at offset 8.

For provenance:

```
ANCESTRY FROM <node> DEPTH 5    # reverse BFS bounded at depth 5
                                 # output: (node, depth) pairs
```

For similarity:

```
SIMILAR_DECISIONS TO <node> DEPTH 2 K 5 AMONG TRUTH 2
                                 # top-5 nodes by WL-1 distance on
                                 # the local ancestral subgraph
```

---

*dag · e150ed22 · amateur engineering, errors likely, no competitive claims*
