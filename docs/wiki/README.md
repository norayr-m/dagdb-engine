# DagDB Wiki

> Amateur engineering project. No competitive claims. Errors likely.

The practical manual. [`README.md`](../../README.md) at the repo
root is the pitch; [`ARCHITECTURE.md`](../../ARCHITECTURE.md) is the
internals. This wiki is what you read when you're using DagDB or
debugging it.

---

## Quick

If you only have five minutes:

1. **[quick-start.md](quick-start.md)** — build the daemon, open a
   socket, do a round-trip. Five commands, about 60 seconds if
   `swift` is cached.
2. **[data-and-persistence.md](data-and-persistence.md)** — where
   every persistent byte goes on your disk, what's safe to commit,
   what is not, and how to stop your own data from leaking to
   GitHub.
3. **[dsl.md](dsl.md)** — every DSL verb the daemon speaks.

If you have twenty minutes, read those three plus:

4. **[queries.md](queries.md)** — BFS, ancestry, similarity,
   secondary index, and when to use which.

---

## Topics

- **[quick-start.md](quick-start.md)** — build + run + first query.
- **[data-and-persistence.md](data-and-persistence.md)** — file
  layout, paths, git safety, backup, WAL, autosnapshot,
  `DAGDB_DATA_ROOT` policy.
- **[dsl.md](dsl.md)** — the daemon's command language.
- **[mcp.md](mcp.md)** — Python MCP surface (37 tools on port 8787).
- **[plugins.md](plugins.md)** — biology rank policies + Loom event
  adapter.
- **[queries.md](queries.md)** — BFS, subgraph distances,
  ancestry, similar-decisions, secondary index.
- **[mvcc.md](mvcc.md)** — reader sessions, snapshot-on-read.
- **[invariants.md](invariants.md)** — the four things DagDB
  enforces on every insert + the 9 error categories.
- **[back-edges.md](back-edges.md)** — typed second edge type for
  synchronous-circuit recurrence. Latches state across tick
  boundaries. Unlocks AC-3, Hopfield, Boolean networks with feedback.
- **[Benchmarks.md](Benchmarks.md)** — reproducible numbers, one
  command per row.
- **[troubleshooting.md](troubleshooting.md)** — things that go
  wrong, in order of frequency.

For the 4-cycle runtime (paper 4), see
[`docs/engine.md`](../engine.md).

---

## Status (2026-04-21)

- **Tests**: 98 Swift + 16 Python adapter, all green, no skips.
- **Daemon**: launchd-supervised on `/tmp/dagdb.sock`, grid 1024 ≈
  1 M nodes.
- **Loom Pass 1**: 694 events ingested end-to-end on the u32
  daemon; dual-write live through `capture_latest`.
- **MCP bridge**: `http://localhost:8787/dagdb/`, 37 tools.
- **Persistence root**: `~/dag_databases/`. Daemon enforces via
  `DAGDB_DATA_ROOT`. One allow-listed sample
  (`dagdb/sample_db/demo_graph.dagdb`) is tracked in git;
  everything else is private.

### Ship-storm 2026-04-21

Six engine changes landed in one day. In shipping order:

1. **T1 u32 rank** + **T1b u64 rank** — snapshot format widened to
   v3 (42 B/node, u64 rank). Load is backward-compat with v1 (u8)
   and v2 (u32); save always writes v3.
2. **T2 `rankPolicy` Protocol** + three defaults.
3. **T3 `SET_RANKS_BULK`** — shm-fed u32 vector rewrite.
4. **T7 MVCC snapshot-on-read** — `OPEN_READER` / `READER id …`.
5. **`bfsDepths` primitive** + `BFS_DEPTHS FROM <seed>` DSL.
6. **Loom Pass 1 complete** — 694 events, ~140 ms aggregate.

## Humble disclaimer

Numbers come from one M5 Max laptop. No peer review, no controlled
benchmark. Errors likely. Use at your own discretion.
