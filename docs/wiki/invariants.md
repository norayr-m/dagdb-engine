# Invariants and error taxonomy

What DagDB enforces on every insert, and every error category it
can emit.

---

## Four invariants

**The slot model.**
Invariants 1–3 below are the **rank-mode DAG property**: `CONNECT` (the
authoring verb) enforces them, `VALIDATE` reports them, rank-mode `TICK`
refuses a graph breaking 1 or 2. They are no longer the **store's**
invariant: a duplicate source (S1), a slot self-loop (S2) and a rank
inversion (S3) are store shapes that `SAVE` writes and every loader loads,
and `TICK_SYNC` is defined on them (they enter through `SET_NEIGHBORS_BULK`,
`IMPORT MORTON` and the loaders). The store's invariants are 4 (a source in
range) and the register rule — a back-edge destination has no combinational
slot (S4) — enforced on every path: `CONNECT`, `CONNECT BACK`,
`SET_NEIGHBORS_BULK`, every loader (the v1 JSON/CSV loads against the list
they keep), `SAVE` and the daemon's writers.

### 1. Rank monotonicity

Every edge satisfies `rank(src) > rank(dst)`. Makes the graph
acyclic by construction. Enforced:

- On `CONNECT` — rejects with `ERROR schema: rank violation: …`
- On rank-mode `TICK` / `TICK UNTIL_STABLE` — `ERROR invalid_graph:
  rank-mode TICK refused, validation: …`, nothing ticked.
- On `TILED OPEN` (tile bodies) and `SAVE TILED` — a tiled graph is a
  rank-mode object.
- On `VALIDATE` — on-demand re-check of live state.

Not on `SAVE` or the loaders (S3 is a store shape).
Not re-checked after `SET_RANK` or `SET_RANKS_BULK` — those bypass
the per-edge check because they rewrite the rank buffer directly.
Follow up with `VALIDATE` if paranoid.

### 2. No self-loops

`src ≠ dst` on every edge. Enforced on `CONNECT`, rank-mode `TICK`,
`TILED OPEN` / `SAVE TILED` and `VALIDATE`; not on
`SAVE` or the loaders (S2 is a store shape).

### 3. No duplicate edges per node

A node's six input slots must reference distinct sources. Enforced
on `CONNECT` and `VALIDATE`; not on `SAVE`, `TILED OPEN`
or the loaders (S1 is a store shape; rank-mode `TICK` evaluates a
duplicate input twice).

### 4. Bounded inputs

Every `src ∈ [0, nodeCount)`. Enforced on `CONNECT`, `SET_NEIGHBORS_BULK`,
`SAVE` and every load (the one persistence rule:
`node <d> slot <k>: src <s> out of range`).

A node also has at most 6 inputs (the "6-bound" — the inputs array
is fixed-size). `CONNECT` that would be the 7th returns
`ERROR schema: node <dst> already has 6 edges (6-bounded)`.

---

## Error taxonomy

Every failing response starts with `ERROR <category>: <detail>`.
Nine categories:

### `out_of_range`

Node or index argument outside the valid range. Typical detail:
`node 9999999 out of range`.

### `dsl_parse`

Command verb recognised, but arguments bad. Typical:
- `unknown LUT preset: FOO`
- `unknown metric: foo — try jaccardNodes, …`
- `depth must be non-negative, got -3`

### `unknown_command`

Verb not recognised at all. Whole input echoed in the detail.

### `schema`

DAG-invariant violation. One of:
- `rank violation: src(<i>) rank=<r> must be > dst(<j>) rank=<s>`
- `self-loop: src == dst (<i>)`
- `duplicate edge: <i> → <j>`
- `node <j> already has 6 edges (6-bounded)`

### `io`

File-system error during save / load / export / import / backup.
Wraps the underlying `SnapError` / Foundation error.

### `wal`

Write-ahead log append or replay failure. Typical:
- `append: <underlying error>`
- `truncated: <where>`

### `bfs`

BFS primitive failed (seed out of range, depth < 0 etc.).

### `not_found`

Missing session id on `CLOSE_READER` or `READER <id> …`.
Missing file path on `LOAD`.

### `forbidden`

Attempt to do something a reader session doesn't allow. Typical:
- `command not allowed in reader session (read-only)`
- `EVAL not allowed in reader session (ticks mutate)`

---

## Regex matching

Scripts that parse error responses should match on category first:

```python
import re
m = re.match(r"^ERROR (\w+): (.*)$", response)
if m:
    category, detail = m.group(1), m.group(2)
    if category == "schema":
        # constraint violation — don't retry
    elif category == "io":
        # disk / network — retry may help
    elif category in ("out_of_range", "dsl_parse", "unknown_command"):
        # programmer error — fix the call
```

The additive prefix convention means the old error payload is
preserved after the category. Anything that used to match on e.g.
`"self-loop"` still works.

---

## Category → action guide

| Category | Retry? | Root cause |
|---|---|---|
| `out_of_range` | No | Programmer error — caller passed bad index |
| `dsl_parse` | No | Programmer error — bad arguments |
| `unknown_command` | No | Programmer error OR MCP server out of sync with daemon |
| `schema` | No | Data model violation — fix the graph |
| `io` | Maybe | Transient disk / path issue — check errno |
| `wal` | Maybe | Likely disk; may mean WAL corrupted |
| `bfs` | No | Programmer error — bad seed/depth |
| `not_found` | No | Session closed / file missing — caller state issue |
| `forbidden` | No | Wrong context — move call off the session, or open one |
| `shutdown` | After restart | The daemon is exiting (SIGTERM / SIGINT); the command was not run |

a retry queue checks `resp.startswith("OK")` — anything
not OK is requeued with backoff. For finer control the category
prefix gives a precise classifier.
