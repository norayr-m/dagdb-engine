# Queries

Five read primitives on DagDB, ordered by abstraction level:

1. **`NODES` / `TRAVERSE`** — legacy low-level reads.
2. **`SELECT truth k rank lo-hi`** — secondary-indexed fast path.
3. **`BFS_DEPTHS`** — depth vector from a seed.
4. **`DISTANCE`** — eight subgraph similarity metrics.
5. **`ANCESTRY` / `SIMILAR_DECISIONS`** — hive-friendly provenance
   and similarity wrappers.

All five can run against a reader-session snapshot via the
`READER <id> <inner>` envelope — see [`mvcc.md`](mvcc.md).

---

## 1. `NODES` / `TRAVERSE`

Filter by rank / truth / type, or walk k ranks from a seed.

```
NODES AT RANK 2                     # all rank-2 nodes
NODES WHERE truth=1                  # all TRUE nodes
TRAVERSE FROM 42 DEPTH 3             # walk 3 ranks from node 42
```

Both emit `(node, rank, truth, type)` rows to shared memory. One
predicate per clause — compose in the client if you need
conjunction.

Linear scan. Fine at thousands of nodes, poor at millions. For
typed-event queries on large graphs use `SELECT` instead.

---

## 2. `SELECT` — secondary index

`TruthRankIndex` — per-truth-code rank-sorted list of `(rank,
nodeId)`. Lazy rebuild; lookup O(log N + matches).

```
SELECT truth 2 rank 1000000-1000099    # last 100 dialogue_turns
SELECT truth 4 rank 0-4294967295        # all drop_written events
```

Output: Int32 node IDs to shm at offset 8.

**Rebuild trigger.** The dirty flag flips on `SET_TRUTH`,
`SET_RANK`, `SET_RANKS_BULK`, `LOAD`, `LOAD_JSON`, `LOAD_CSV`,
`IMPORT`, `BACKUP_RESTORE`. Next `SELECT` rebuilds once
(O(N log N)).

**Memory.** ≈ 12 bytes × N entries per active truth bucket.

---

## 3. `BFS_DEPTHS` — per-node depth vector

Two flavours:

```
BFS_DEPTHS FROM 42                     # undirected: inputs ∪ fanout
BFS_DEPTHS FROM 42 BACKWARD            # backward: follow inputs only
```

Output: `Int32[nodeCount]` to shm, starting at offset 8.
`depth[i] == -1` means unreachable, `0` = seed, positive = depth.

**Undirected** merges `inputs[]` with an on-the-fly fanout table —
right choice for protein contact graphs or Loom dialogue chains
where edges are stored one-directional but meant to be
bidirectional. Build cost: O(N·6) for the fanout linked lists.

**Backward** follows only `inputs[]` — right for explicit
parent-to-child DAG walks.

Results are graph geodesics. See [`bfs_usage.md`](../bfs_usage.md)
for the full reference.

---

## 4. Subgraph distances

Eight built-in metrics over `DagSubgraph` (node-set or
rank-range):

```
DISTANCE <metric> <loA>-<hiA> <loB>-<hiB>
```

| Metric | Idea | Cost |
|---|---|---|
| `jaccardNodes` | Node-set symdiff / union | O(\|A\|+\|B\|) |
| `jaccardEdges` | Induced-edge symdiff / union | O(\|A\|+\|B\|+E) |
| `rankL1`, `rankL2` | Sparse histogram of ranks | O(\|A\|+\|B\|) |
| `typeL1` | Histogram over node-type byte | O(\|A\|+\|B\|) |
| `boundedGED` | Node + induced-edge symdiff count | O(\|A\|+\|B\|+E) |
| `wlL1` | Weisfeiler-Lehman-1 histogram L1 | O((\|A\|+\|B\|)·deg) |
| `spectralL2` | L2 over Laplacian eigenvalues (Jacobi) | O(n³) per side |

All symmetric, all return [0, 1] except `boundedGED` (returns the
edit-count integer cast to Double).

`spectralL2` uses an inline Jacobi eigensolver — self-contained,
no `Accelerate` dependency. Fine up to ~300-node subgraphs.

---

## 5. `ANCESTRY` — bounded reverse BFS

```
ANCESTRY FROM 693 DEPTH 5
# OK ANCESTRY from=693 depth=5 count=14 elapsed=0.2ms shm_bytes=112
```

Returns `(Int32 node, Int32 depth)` pairs to shm, sorted by depth
ascending. Seed appears at depth=0.

Under Loom causal-parent semantics (`prev_by_agent`,
`parent_response`, `dialogue_prev_turn`, `meeting_parent`,
`cites_drop`, `triggered_by_external`) this is the full provenance
subgraph of an event.

---

## 6. `SIMILAR_DECISIONS` — top-K by WL-1 distance

```
SIMILAR_DECISIONS TO 42 DEPTH 2 K 5 AMONG TRUTH 2
```

For each candidate node (filtered by `AMONG TRUTH t` if given,
otherwise all other nodes), compute its local ancestral subgraph
up to `DEPTH d`, build a WL-1 histogram, take L1 distance against
the query's. Return top-K sorted ascending.

Output: `(Int32 node, Float32 distance) × k` to shm.

**Cost:** O(C · 6^d) where C is the candidate pool. Narrow via
`AMONG TRUTH t` on typed graphs.

**Not allowed inside a reader session** — the candidate scan is
expensive and sessions are for point-in-time reads, not mass
computation. Rejected with `ERROR forbidden:`.

---

## 7. `HIVE_QUERY` — MCP-level convenience

Thin alias over `SELECT` for the common `(truth, rank-range)`
hive query. Only available through MCP, not as a DSL verb.

```python
dagdb_hive_query(truth=2, rank_lo=1000000, rank_hi=1000099, limit=100)
```

Sidecar-level filters (by agent, timestamp, event-type name)
happen client-side on the returned node IDs.

---

## Picking the right primitive

- "All dialogue turns today" → `SELECT truth 2 rank <now-K>-<now>`
- "Where did this decision come from?" → `ANCESTRY FROM <n> DEPTH
  <d>`
- "What past decisions looked like this one?" →
  `SIMILAR_DECISIONS TO <n> DEPTH 2 K 5 AMONG TRUTH <same>`
- "How similar are these two event classes?" →
  `DISTANCE wlL1 <rangeA> <rangeB>`
- "Walk forward through the DAG" → `TRAVERSE FROM <n> DEPTH <k>`
- "Full graph geodesics from a seed" → `BFS_DEPTHS FROM <n>`

Every one of them can run against a stable point-in-time snapshot
via the reader-session envelope.
