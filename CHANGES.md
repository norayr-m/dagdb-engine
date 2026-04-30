# Changes

Session-by-session log. Most recent first. Humble disclaimer: amateur
engineering project, no competitive claims.

---

## 2026-04-29 — BACK_EDGE primitive + bitwise LUT composition (vNext, version-bump pending)

Two engine features landed since v0.1.1 (2026-04-23). Version bump
held pending Norayr's trigger; this entry placeholds the release
notes so the next tag has them ready.

### BACK_EDGE primitive

A typed second edge type that latches `truth[src]` into `truth[dst]`
at tick boundary, after the combinational pass settles. The
synchronous-circuit register pattern applied to a 6-bounded ranked
DAG with GPU-evaluated truth tables. Unlocks in-substrate iteration
to convergence — belief propagation, AC-3 constraint propagation,
Hopfield-style associative recall, Boolean networks with feedback.

- **Engine**: two-phase CPU latch on `.shared truthState` (snapshot
  every back-edge src first, then write every dst). `is_register[]`
  flag in the rank kernel; combinational pass skips registers.
- **Validation**: `engine.addBackEdge` rejects if dst has
  combinational fan-in; `graph.connect` rejects if dst is a
  back-edge destination. A node is either combinational or a
  register, not both.
- **DSL** (and MCP): `CONNECT BACK FROM <src> TO <dst>`,
  `CLEAR <node> BACK_EDGES`, `GET <node> TRUTH`, `SET <node> LUT
  0x<hex>` for arbitrary 64-bit LUT integers.
- **WAL**: opcodes `0x10` (`CONNECT_BACK`) and `0x11`
  (`CLEAR_BACK_EDGES`); replay reconstructs the back-edge buffer.
  `CHECKPOINT` survival tested.
- **Snapshot**: format v3 → v4. v4 appends a back-edge trailer
  (u32 count + entries) after body. v3 files load with empty
  back-edge list (forward migration). v4 always writes.
- **Verification**: 1-bit toggle (6 ticks, register flips
  0/1/0/1/0/1), 4-bit ripple counter (17 ticks, 0 → 15 → 0 wrap),
  AC-3 Australia 3-coloring with WA pre-assigned red — converges in
  2 synchronous ticks, per-tick equality with the pure-Python
  `examples/ac3_australia/reference_ac3.py`.
- **Tests**: 120 Swift green (was 104; +16 across the back-edge
  work).
- **Out of scope**: transform-LUTs on registers and a GPU latch
  kernel deferred to v2 of the primitive.

See [`docs/wiki/back-edges.md`](docs/wiki/back-edges.md) for the full
feature page.

### COMPOSE — bitwise LUT composition at runtime

```
COMPOSE AND <src1> <src2> INTO <dst>     # dst.LUT = src1.LUT & src2.LUT
COMPOSE OR  <src1> <src2> INTO <dst>     # dst.LUT = src1.LUT | src2.LUT
COMPOSE XOR <src1> <src2> INTO <dst>     # dst.LUT = src1.LUT ^ src2.LUT
COMPOSE NOT <src>         INTO <dst>     # dst.LUT = ~src.LUT
```

Foundation for graph-simplification passes (collapse a fused subtree
into one node), policy composition ("fires when all of {a, b, c}
agree"), and any case where you'd otherwise evaluate a tree of
intermediate nodes per tick. WAL-logs the equivalent `SET_LUT` if
enabled. Rejected inside reader sessions. Returns
`OK COMPOSE op=<OP> src1=<i> src2=<j|—> dst=<k> lut=0x<hex>`.

### Other docs additions

- `docs/wiki/back-edges.md` — new feature page.
- `docs/wiki/dsl.md` — adds the back-edge verbs, `GET <node> TRUTH`,
  `SET <node> LUT 0x<hex>`, and the COMPOSE section.
- `docs/wiki/mcp.md` — `dagdb_compose_lut`, `dagdb_connect_back`,
  `dagdb_clear_back_edges` (40 tools total).
- `docs/wiki/data-and-persistence.md` — snapshot format-version
  table, WAL opcode table.
- `README.md` Features → Core engine — BACK_EDGE bullet, COMPOSE
  callout in the LUT6 line.
- `site/index.html` — comment-slot reserving a future BACK_EDGE
  detailed slide before the Roadmap section.

---

## 2026-04-21 (pm) — T1b u64 rank widen + tiled-streaming spec

### T1b — u32 → u64 rank refactor

Follow-on to T1. Rank field widens from 32-bit to 64-bit across
the full stack to support the 10¹¹-on-laptop stretch target (via
tiled streaming, spec below).

- **Core**: `DagDBState.rank: [UInt64]`, `rankBuf` allocation 4 →
  8 bytes/node, `bindMemory(to: UInt64.self)` everywhere.
- **Shader**: `uint64_t* rank` + `uint64_t& current_rank` in both
  `Shaders/dagdb.metal` and the inline fallback source.
- **Snapshot format v3**: 42 B/node body. Header unchanged. Load
  is backward-compat with v1 (u8, widens) and v2 (u32, widens);
  save always writes v3.
- **WAL `SET_RANK` v3 payload**: u32 node + u64 rank = 12 bytes.
  Replay accepts v1 (5 B) and v2 (8 B).
- **Shm row v3**: 12 B → 24 B per row. Layout: u64 node + u64
  rank + u8 truth + u8 type + 6 pad. Python MCP readers must
  update row stride.
- **DSL parser**: RANK / DISTANCE / SELECT rank args parsed as
  UInt64.
- **Secondary index** (`TruthRankIndex`) keys UInt64.
- **Distance module** rank-profile histogram keys UInt64.

Acceptance criterion (per coordination call): `rank=300` (u8-impossible) and
`rank=4_294_967_300` (u32-impossible) both round-trip through
SAVE/LOAD. Green: `testU64RankRoundTrip` in
`Tests/DagDBTests/DagDBSnapshotTests.swift`.

Full test suite: **98 Swift + 16 Python = 114 green, no skips**.

Phase 2b (neighbor i32 → i64 widening) **deferred** per the coordination
call: doubling the neighbor buffer drops the single-engine
ceiling ~40 % on M5 UMA without unlocking addressing we could
physically allocate. Will revisit if/when a single tile
approaches 2 × 10⁹ distinct node IDs.

### Tiled-streaming spec

New internal doc at `docs/tiled-streaming.md`. Frames Savanna's
existence proof (100 B cells / 9 hr / 500 GB / single M5) as the
pattern DagDB inherits for the stretch target. Covers scale
regimes (when to tile and when not to), rank-range tile mapping
aligned with the rank-monotone invariant, hot/cold buffer
decisions, tile file format reuse of `TileHalo.swift`, Metal
kernel dispatch per-tile, sparse BFS with continuation queue,
thermal discipline, open questions.

Internal only. No code yet. Build follows spec after it matures.

### Daemon bounce #2

the launchd daemon was bounced onto the u64 binary. Verify
pass: all five gates green (u64 rank surface accepts 2⁶³-1 and
> 2⁶³, BFS_DEPTHS callable, shm + socket 0600, DATA_ROOT
enforcement, SAVE file size byte-exact match for v3 format —
44 040 224 bytes = 32 header + 42 × 1 048 576 body). MVCC,
ANCESTRY, SET_RANKS_BULK all still surface-exposed.

### Security + data-root hardening

- shm file mode 0o666 → 0o600 + explicit chmod.
- Unix socket chmod 0o600 after bind.
- `guardPath()` rejects `..` traversal and out-of-root paths
  under `DAGDB_DATA_ROOT`. Applied to every file-path DSL verb.
- `~/dag_databases/` as the single persistent DB root (plist env
  vars `DAGDB_DATA_ROOT`, `DAGDB_WAL`, `DAGDB_AUTOSAVE`).
- Gitignore allow-list tightened to ONE sample
  (`dagdb/sample_db/demo_graph.dagdb`); `liver.dagdb` moved to
  `~/dag_databases/`.

---

## 2026-04-21 (am) — consolidation and archive

- `ARCHIVE/1_Active_Doing_Graph_Database/` — tree 2 (the original
  `dagdb-engine` staging repo) moved into
  `~/000_AI_Work/0_Projects/ARCHIVE/` alongside other deprecated
  projects. The DagDB codebase under 004 is now unambiguously
  canonical.
- `dagdb/mcpo_config.json` — mcpo config relocated into 004. `dagdb`
  endpoint points at 004's mcp_server.py; the three non-DagDB MCP
  scripts (dialogue, image, diagram) still resolve via the ARCHIVE/
  path (no canonical home yet).
- `~/Library/LaunchAgents/com.hari.dagdb.plist` — rewired to the 004
  release binary + grid 1024. Old plist backed up as `.pre-t1.bak`.
- `~/Library/LaunchAgents/com.dagdb.mcpo.plist` — rewired to 004's
  mcpo config. Old plist backed up as `.pre-archive.bak`.
- The full Pass 1 re-run landed clean on the new
  launchd-supervised daemon: **694 Loom events** (archives + live
  JSONL), ~140 ms wall clock, ~5 k events/sec, zero schema errors.
  Fallback import deleted from `capture_latest.py`; adapter resolves
  exclusively via `dagdb.plugins.loom.adapter` from 004.

## 2026-04-20 — rank-widening sprint

Seven tickets shipped against the rank-widening + MVCC sprint:

### T1 — u32 rank refactor (commit `7d49476`)

Rank `UInt8` → `UInt32` across the whole stack. Caps per-instance
rank at 4.3 billion; unblocks Loom's insert-counter and
full-protein biology ingestion (> 255 residues).

- Core: `DagDBState.rank`, `DagDBEngine.rankBuf`, `readRanks`,
  validator.
- Metal shader (both `.metal` file and inline source): `DagNode`
  rank `uint8_t` → `uint32_t`; `current_rank` widened.
- Snapshot v2 (rank = 4 bytes/node; body 35N → 38N). Load accepts
  v1 (u8) and v2 (u32). Save always writes v2.
- WAL `SET_RANK` payload 5 → 8 bytes. Replay accepts both.
- JSONIO + CSV parse rank as `UInt32`.
- Backup chain segment sizes updated.
- Distance module: rank-profile histogram dense `[256]` → sparse
  `[UInt32: Int]`.
- Daemon: shm result row layout 8 → 12 bytes (rank field widened);
  `Predicate.evaluate` takes `UInt32`; DSL parser widened.

### T2 — rankPolicy protocol + three defaults (commit `c73b824`)

Python module `dagdb/plugins/biology/rank_policies.py`:

- `RankPolicy` Protocol — `assign_ranks(node_count, max_rank,
  **context) → numpy.uint32` array.
- `SequencePositionPolicy` — single chain.
- `ChainBandPolicy` — multi-chain assembly, rank bands per chain.
- `TopologicalSortPolicy` — BFS-depth from a chosen root;
  disconnected components land one depth deeper.
- Self-test covers monotonicity, inter-chain ordering, and a
  4-node cycle with BFS from root-0.

### T3 — SET_RANKS_BULK DSL (commit `579ff1d`)

New DSL command + MCP tool. Plugin writes a precomputed u32 rank
vector of length `nodeCount` to shm offset 8, calls
`SET_RANKS_BULK`, daemon commits to `rankBuf` in one round-trip. No
per-insert validation — pair with `VALIDATE` if paranoid.

### T7 — MVCC snapshot-on-read (commit `d4b008d`)

Reader sessions:

- `DagDBReaderSession` + `DagDBReaderSessionManager`.
- `OPEN_READER` memcpys the six primary buffers into a fresh
  `DagDBEngine`. Returns a 17-char session id.
- `READER <id> <inner>` routes a read-only inner command to the
  session's snapshot. Writes, `EVAL`, nested sessions,
  `SIMILAR_DECISIONS` all rejected with `ERROR forbidden:`.
- `CLOSE_READER` / `LIST_READERS` for lifecycle + introspection.
- 9 tests: isolation under mid-session mutation, multi-session
  independence, u32 rank fidelity in the snapshot, neighbours-buffer
  copy integrity, unique ids across 10 opens.

### T15 — secondary index (truth, rank-range) (commit `8876feb`)

`TruthRankIndex`:

- Per-truth-code rank-sorted list of `(rank, nodeId)` tuples.
- Lazy rebuild on dirty flag. Mutations that can change `(truth,
  rank)` flip the flag; next `SELECT` rebuilds once.
- Lookup: O(log N + matches) via binary search for the first rank
  ≥ lo, linear scan while rank ≤ hi.
- DSL `SELECT truth <k> rank <lo>-<hi>` — matching node IDs written
  to shm at offset 8 as `Int32[]`.
- MCP tool `dagdb_select_by_truth_rank`.
- 11 tests including a Loom-specific "last-N dialogue_turn events"
  scenario under insert-counter rank.

### T8 — ANCESTRY / SIMILAR_DECISIONS / HIVE_QUERY (commit `1e5c410`)

Three agent-friendly hive-query primitives:

- **`ANCESTRY FROM <node> DEPTH <d>`** — reverse BFS bounded by
  depth. Output: `(Int32 node, Int32 depth) × count`.
- **`SIMILAR_DECISIONS TO <node> DEPTH <d> K <k> [AMONG TRUTH <t>]`**
  — WL-1 histogram L1 distance over per-candidate local ancestral
  subgraphs. Output: `(Int32 node, Float32 distance) × k`.
- **`HIVE_QUERY …`** — MCP-level alias over `SELECT`; sidecar
  filters client-side.

### Error taxonomy (same commit)

All daemon responses now carry `ERROR <category>: <detail>` prefix.
Nine categories: `out_of_range`, `dsl_parse`, `unknown_command`,
`schema`, `io`, `wal`, `bfs`, `not_found`, `forbidden`. Additive —
existing payload preserved after the prefix.

### BFS primitive (earlier on the same day, commit `c1c306c`)

`DagDBBFS.swift`:

- `bfsDepthsUndirected(from:)` — merge inputs + on-the-fly fanout.
- `bfsDepthsBackward(from:)` — follow inputs only.
- DSL `BFS_DEPTHS FROM <seed> [BACKWARD]`; zero-copy Int32 vector
  to shm.
- MCP `dagdb_bfs_depths`.
- Caught and corrected a dual-node encoding bug in the same
  session: under bipartite B→A edges, BFS shortcut collapses
  contact-graph geodesics. Switched to single-node-per-residue
  encoding with `rank = maxRank - seqIndex`. Amendment drop
  captured the fix; tests updated.

### Rename `legacy/` → `dagdb/` (commit `c184721`)

The "legacy" label was an artefact of 2026-04-19's `git subtree add
--prefix=legacy` — backwards in meaning since all live work
happened inside it. `git mv` preserved blame. Path references
updated across README, ARCHITECTURE, CHANGES, CONTRIBUTING, docs,
dashboard features.yaml, gitignore. Fresh `.build` clean-rebuild
(Swift's precompiled module cache baked the old path in).

### Consolidation into 004 (commit post-rename)

Pulled forward from tree 2:

- `dagdb/plugins/loom/` — the pure-function adapter, backfill
  script, 16-test pytest suite. `capture_latest.py` now imports
  from `dagdb.plugins.loom.adapter`.

## 2026-04-19 — first four phases

- **Phase 0 — merge.** `git subtree add --prefix=legacy` pulled
  tree 2's `norayr-m/dagdb-engine` repo into 004 under `legacy/`.
  38-commit history preserved. Tagged tree 2
  `pre-merge-2026-04-19` as safety. Both builds green post-merge.
- **Phase 1 — dashboard.** `dashboard/features.yaml` +
  `gen_dashboard.py` + dark-gold `index.html`. Auto-refresh every
  30 s in Chrome. `--watch` flag regenerates every 10 s.
- **Phase 2 — ACID atomic-save.** `DagDBSnapshot.save` rewritten:
  tmp + `F_FULLFSYNC` + `replaceItemAt` + dir fsync. Three
  durability tests: dangling `.tmp` ignored, successful save leaves
  no tmp, overwrite is atomic. A and D become **pass**.
- **Phase 3 — JSON + CSV IO.** `DagDBJSONIO.swift`. JSON
  (`dagdb-json` v1) mirrors the six engine buffers; CSV is two
  files (`nodes.csv` + `edges.csv`). Atomic-save + pre-commit rank
  validation. Five round-trip tests.
- **Phase 4 — subgraph distances.** `DagDBDistance.swift` — Jaccard
  (nodes + edges), rank-profile L1/L2, nodeType L1, bounded GED,
  WL-1, spectral L2 via inline Jacobi eigensolver. 9 tests.
- **Docs layer.** Wrote README / ARCHITECTURE / CONTRIBUTING /
  `docs/engine.md`, copied `legacy/LICENSE` to the root, hardened
  `.gitignore`. Humble disclaimer on every top-level doc. Did not
  push anywhere.

Ended 2026-04-19 with 51 / 51 tests green (from a 27-test baseline).

---

## Running test counts by date

| Date | Swift | Python | Total | Delta |
|---|---:|---:|---:|---|
| 2026-04-18 baseline | 27 | — | 27 | — |
| 2026-04-19 evening | 51 | — | 51 | +24 (snapshot, JSONIO, distance) |
| 2026-04-20 evening | 98 | 16 + 11 | 125 | +47 Swift, +27 Python |
| 2026-04-21 | 98 | 16 | 114 green | rank-policy self-test folded into adapter tests |

(The 11-count for rank-policy self-test is a single Python script
with multiple asserts, not a pytest suite — counted once as a
smoke check, not tracked day-by-day.)

---

## Deferred / parked

- **Dense Laplacian → Accelerate / LAPACK.** Current Jacobi
  eigensolver is self-contained but O(n³). Fine up to ~300-node
  subgraphs. Larger work (protein complexes, whole graphs) wants
  `dsyevd_` through `Accelerate`.
- **Threaded daemon accept.** Serial loop today. Full MVCC (per-node
  versions + GC) is a separate future step after threading.
- **`WHERE … AND …` compound predicates.** DSL supports one
  field-op-value per clause. Compose client-side.
- **Cross-project MCP scripts** (`dialogue_mcp.py`, `image_mcp.py`,
  `diagram_mcp.py`, `kokoro_tts_proxy.py`) — live in ARCHIVE/ for
  now. Proper home TBD.

---

## Humble disclaimer

Amateur engineering project. Research prototype. Errors likely.
Numbers speak. No competitive claims.
