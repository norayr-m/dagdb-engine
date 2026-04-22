# Plugins

Two Python plugins live under `dagdb/plugins/`. Both use the DagDB
daemon via Unix socket or MCP; neither runs inside the daemon
process.

---

## `dagdb/plugins/biology/rank_policies.py`

A `RankPolicy` Protocol + three default implementations. Computes a
`numpy.uint32` rank vector for a given graph shape; caller commits
it via `SET_RANKS_BULK` or per-node `SET … RANK …`.

### Protocol

```python
from typing import Protocol, runtime_checkable
import numpy as np

@runtime_checkable
class RankPolicy(Protocol):
    def assign_ranks(
        self,
        node_count: int,
        max_rank: int,
        **context,
    ) -> np.ndarray:   # np.uint32, length node_count
        ...
```

### `SequencePositionPolicy`

Single chain. `rank[i] = max_rank - seq_indices[i]`.

```python
from dagdb.plugins.biology.rank_policies import SequencePositionPolicy
import numpy as np

policy = SequencePositionPolicy()
ranks = policy.assign_ranks(
    node_count=100,
    max_rank=100,
    seq_indices=np.arange(100),
)
# ranks[0] == 100, ranks[99] == 1
```

### `ChainBandPolicy`

Multi-chain assembly. Each chain gets a rank band of width
`ceil(max_rank / num_chains)`; inter-chain edges flow from the
higher-chain-id band to the lower.

```python
from dagdb.plugins.biology.rank_policies import ChainBandPolicy
import numpy as np

# Two chains of three residues each.
policy = ChainBandPolicy()
ranks = policy.assign_ranks(
    node_count=6, max_rank=100,
    chain_id=np.array([0, 0, 0, 1, 1, 1]),
    pos_in_chain=np.array([0, 1, 2, 0, 1, 2]),
)
# → [49, 48, 47, 99, 98, 97] with band_width=50
```

### `TopologicalSortPolicy`

BFS-depth from a chosen root. Disconnected components land one
depth deeper than the deepest reachable node.

```python
from dagdb.plugins.biology.rank_policies import TopologicalSortPolicy

# 4-node cycle: 0-1-2-3-0. Root=0.
policy = TopologicalSortPolicy()
ranks = policy.assign_ranks(
    node_count=4, max_rank=10,
    adjacency=[[1, 3], [0, 2], [1, 3], [0, 2]],
    root=0,
)
# depths [0,1,2,1] → ranks [10, 9, 8, 9]
```

### Self-test

```
python3 dagdb/plugins/biology/rank_policies.py
# → "rank_policies.py selftest: OK"
```

---

## `dagdb/plugins/loom/`

Loom event ingestion for the 2026-04-20 rank-widening + MVCC sprint.
Four files:

| File | Purpose |
|---|---|
| `__init__.py` | Empty namespace marker. |
| `adapter.py` | Pure-function `event_to_node` + `apply_ingest` + `IngestContext` dataclass. |
| `backfill.py` | One-shot JSONL → DagDB ingester with `--reset-ctx` and `--start N` resume. |
| `test_adapter.py` | 16 pytest tests. |

### Using the adapter in a Stop hook

```python
from dagdb.plugins.loom.adapter import (
    event_to_node,
    apply_ingest,
    IngestContext,
    load_ctx,
    save_ctx,
)

CTX_PATH = "/Users/you/jarvis_workspace/dagdb_ingest_ctx.json"

def on_stop_hook(event: dict) -> None:
    ctx = load_ctx(CTX_PATH) or IngestContext()
    record = event_to_node(event, ctx)
    if _submit_insert_over_socket(record):
        ctx = apply_ingest(record, ctx)
        save_ctx(ctx, CTX_PATH)
```

`record` is a `DagNodeRecord` — a namedtuple of `node_id`, `rank`,
`truth`, `lut`, `neighbors`, `sidecar`. `_submit_insert_over_socket`
is your wire code (MCP call, raw socket, PG extension, whatever).

### Ingest context

```python
@dataclass
class IngestContext:
    next_counter: int = 0
    last_event_by_agent: dict[str, int] = field(default_factory=dict)
    last_dialogue_turn: dict[tuple[str, str], int] = field(default_factory=dict)
    drop_node_by_filename: dict[str, int] = field(default_factory=dict)
```

Rank for new nodes is `MAX_RANK - next_counter`. The context is
serialised to a JSON file; tuple keys in `last_dialogue_turn`
round-trip via a `\x01` delimiter.

### Backfill

Re-ingest the full Loom history. Tested against 694 events in ~140
ms wall clock on the grid-1024 daemon.

```
python3 dagdb/plugins/loom/backfill.py --all --reset-ctx
python3 dagdb/plugins/loom/backfill.py --start 259     # resume
```

`--reset-ctx` wipes `dagdb_ingest_ctx.json` and re-seeds from
`next_counter=0`. `--start N` resumes from Loom event N (safe only
if the context file already reflects events 0..N-1).

### Schema

Each Loom event becomes one DagDB node:

| Field | Value |
|---|---|
| `rank` | `MAX_RANK - insert_counter` (strictly monotonic, u32) |
| `truth` | event-type code: `1` = response, `2` = dialogue_turn, `3` = ceremony, `4` = drop_written (plus other event types up to 31 for core, 32-255 reserved for plugins) |
| `lut` | `IDENTITY` for every event node |
| `neighbors[0..5]` | up to 6 causal parents: `prev_by_agent`, `parent_response`, `dialogue_prev_turn`, `meeting_parent`, `cites_drop` (cap 4), `triggered_by_external` |
| sidecar JSON | the original Loom JSONL entry verbatim |

### Tests

```
python3 -m pytest dagdb/plugins/loom/test_adapter.py -q
# 16 passed in ~30 ms
```

Coverage: `event_to_node` round-trip, `apply_ingest` mutation,
context serialisation (including tuple-keyed dicts), rank
monotonicity, cites-drop cap, schema compliance.

---

## Where plugins live on disk

Under `dagdb/plugins/`:

```
dagdb/plugins/
├── biology/
│   ├── __init__.py
│   └── rank_policies.py      # Protocol + 3 defaults + self-test
└── loom/
    ├── __init__.py
    ├── adapter.py             # T4 pure-function translator
    ├── backfill.py            # JSONL → DagDB one-shot script
    └── test_adapter.py        # 16 pytest tests
```

Ingest context and backfill debug outputs live outside the repo
by convention:

- `~/jarvis_workspace/dagdb_ingest_ctx.json` — Loom ingest state.
- `dagdb/plugins/loom/_backfill_out/` — gitignored backfill debug
  artefacts.
