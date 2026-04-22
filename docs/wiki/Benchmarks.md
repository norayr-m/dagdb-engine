# Benchmarks

> Amateur engineering project. One M5 Max laptop. No controlled
> benchmark, no peer review. Numbers below are reproducible from
> the repo today — if a row cannot be regenerated right now, it is
> not listed.

Every row pairs a number with the command that produces it. If a
number drifts when you run the same command, trust the new number
— this file, not the code, is the thing that can go stale.

---

## Test suites

| Suite | Count | Wall time | Command |
|---|---|---|---|
| Swift `DagDBPackageTests` (all suites) | **98 cases** | ~2.9 s | `cd dagdb && swift test` |
| Python Loom adapter | **16 cases** | ~0.03 s | `cd dagdb/plugins/loom && python3 -m pytest -q` |

Per-suite Swift breakdown:

| Swift suite | Cases |
|---|---|
| `DagDBTests` (engine core, LUT, ticks, state) | 27 |
| `DagDBDistanceTests` (8 metrics) | 15 |
| `DagDBSecondaryIndexTests` (TruthRankIndex) | 11 |
| `DagDBSnapshotTests` (v1/v2 save/load/validate) | 10 |
| `DagDBReaderSessionTests` (MVCC) | 9 |
| `DagDBWALTests` (append / replay / truncate) | 8 |
| `DagDBBFSTests` (bfsDepths undirected / backward) | 7 |
| `DagDBBackupTests` (base + diff chain) | 6 |
| `DagDBJSONIOTests` (JSON round-trip + CSV) | 5 |
| **Total** | **98** |

No tests are marked pending, skipped, or xfail. All green.

---

## Ingestion — Loom Pass 1

From a live event-stream source, indexed into DagDB.

| Metric | Value | Source |
|---|---|---|
| Events ingested | **694** (nodes 0–693) | `vpt-to-dag_pass1-green-numbers` drop, 2026-04-21 |
| Aggregate wall time | ~140 ms | same |
| Rate | ~4.6–5.2 k events/sec | same |
| Schema invariants holding | 5 of 5 (rank monotonicity, 6-bound, no self-loops, no duplicate edges, bounded inputs) | on-ingest validator |
| Adapter origin | `dagdb.plugins.loom.adapter` | `event_to_node.__module__` |

Reproduce:

```
cd dagdb
python3 plugins/loom/backfill.py <path-to-your-loom.jsonl>
```

(Point it at your own Loom JSONL event log; none ship with the
repo.)

---

## Engine capacity

| Property | Value | Evidence |
|---|---|---|
| Grid for daemon default | 1024 × 1024 = **1 048 576 nodes** | `echo STATUS \| nc -U /tmp/dagdb.sock` |
| Rank address space | 64-bit: 0 to 1.8 × 10¹⁹ (u64) | Snapshot format v3, u64 rank buffer. Test: `testU64RankRoundTrip` in `DagDBSnapshotTests`. |
| Snapshot body size | **42 B / node** raw (v3, u64 rank) | `DagDBSnapshot.save` body layout |
| Snapshot header size | 32 B fixed | `DagDBSnapshot.save` |
| Snapshot-v3 full size at 1 M nodes | ~42 MB uncompressed (exactly 44 040 224 B incl. 32 B header) | `SAVE path.dags`, then `ls -l` |
| Snapshot-v3 zlib-compressed | typically ~11 MB on sparse data | `SAVE path.dags COMPRESSED` |
| Shared-memory result buffer | 8 B header + 24 B/row × nodeCount (v3: u64 node + u64 rank + u8 truth + u8 type + 6 pad) | `main.swift` constants |

The compressed ratio depends on truth / rank density. Sparse
graphs compress well; fully-populated ones less. We don't claim a
universal compression ratio.

---

## Backup chain

From the `DagDBBackupTests` suite (passing). Single-bit flip of
one node, then `BACKUP APPEND`:

| Metric | Typical value |
|---|---|
| Base file size | full snapshot size (matches `SAVE`) |
| Diff file size | **< 5 %** of raw state size for single-bit mutations |
| Diff segments | 6 zlib-compressed XOR chunks |
| Restore cost | base read + replay of every diff |

Reproduce:

```
cd dagdb && swift test --filter DagDBBackupTests
```

---

## What we do not benchmark here

Absent on purpose:

- **Comparative numbers vs other graph DBs.** Not our fight; we
  do not claim to beat Neo4j / Dgraph / TigerGraph. If you want
  a comparison, set one up yourself; our humble disclaimer
  stands.
- **Amortised throughput at billion-node scale.** We have
  tested at 1 M nodes. The u64 rank is designed to admit
  much larger (10¹⁹ address range), but we have not run the
  experiment; see `docs/tiled-streaming.md` for the
  10¹¹-on-laptop spec.
- **BFS latency on arbitrary graphs.** The primitive is
  exercised by `DagDBBFSTests`, but we do not have a stable
  published latency number.
- **GPU vs CPU crossover.** Metal tick kernel benchmarks have
  not been re-run post-u32 refactor. When re-run, they land
  here.

Anything that lands here later must come with a repro command.
If you read a line in this file and cannot regenerate the
number, please flag it — the code is the source of truth.

---

## How to add a row

1. Run the command yourself first.
2. If the number is surprising, run it again.
3. Commit the row with the command in the same cell as the
   number. No prose-only claims.
4. Every row must include the path to the file or test that
   can reproduce it.

This page was written 2026-04-21 after the rank-widening sprint
ship-storm. Regenerate the test-count rows on any day you ship;
the event-ingestion Pass 1 row will be restated as it re-runs.
