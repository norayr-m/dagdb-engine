# Changes

Session-by-session log. Most recent first. Humble disclaimer: amateur
engineering project, no competitive claims.

---

## 2026-09-09 — startup recovery (roadmap item 4)

Branch `dag/startup-recovery` off main. One gap, found by the socket
smoke on 2026-09-06: a daemon restart after `SAVE` came up empty because
`SAVE` checkpoints the WAL, startup replays only records past the last
checkpoint, and nothing loaded the snapshot.

- `DagDBStartup.recover` (DaemonKit): optional snapshot load (env
  `DAGDB_STARTUP_LOAD`) BEFORE WAL replay, in one function that
  `main.swift` and the tests share. Missing file = first boot, starts
  empty. Unreadable file or a path outside the data root = fatal exit 2:
  starting empty over a WAL whose checkpoint already assumes that state
  would silently diverge. WAL replay failure keeps the old "continue
  without WAL" behaviour. A snapshot older than the WAL's last checkpoint
  prints a WARN (ticks are the only shared clock, so this catches some
  misconfigurations, not all).
- `DagDBCommandHandler.durableSnapshot(path:compressed:)`: snapshot then
  WAL checkpoint, factored out of `SAVE`; the autosave on graceful
  shutdown now uses it too. Before, the autosave wrote no checkpoint —
  with a startup load in place that would have replayed the tail twice,
  and `RECORD SLICE`, `RINGS WRITE`, `CLOCK ADVANCE` are not idempotent.
- `main.swift`: the WAL block moved below the data-root/index setup so
  recovery can use them; handler starts at the snapshot's tick count;
  stdout line-buffered (`setlinebuf`) so a redirected or launchd log
  shows startup lines before a hard kill.
- Tests: `StartupRecoveryTests` (7) — restart after SAVE restores graph +
  twin with no LOAD and replays exactly the post-SAVE tail; nothing
  configured = no-op; missing snapshot starts empty and replays the whole
  log (tick-derived truth is not recoverable from the log alone, which is
  the reason the snapshot load exists); outside-root and `..` rejected;
  corrupt snapshot throws; durable snapshot → 0 records replayed; older
  snapshot warns. Suite 446 (9 fixture-gated skips).
- Live socket smoke `examples/twin_primitives/socket_smoke.sh`: 23/23 on
  the wire — SAVE, hard kill, restart with no LOAD (`twin_open=4`, stream
  state byte-identical, `fires=4285`, truth restored, 0 records replayed);
  graceful stop then restart (autosave + checkpoint, 0 replayed); tail
  then hard kill (exactly 2 replayed); corrupt and out-of-root snapshots
  exit 2. Refuses to run while any daemon is alive (shared shm file).
- Not done: the prod launchd plist still lacks `DAGDB_STARTUP_LOAD`;
  adding `…/prod/auto.dags` there is a config change for the operator to make.

---

## 2026-09-06 — interface phase

Branch `dag/p4-interface`, off main at the 2026-09-05 twin-primitives
merge (baseline 249/249). One goal: make the seven twin-spec primitives
restorable (state-bearing inits + Codable) and reachable over the
daemon (DSL + MCP), and add the spec-4 alarm-stream type whose engine
implementation reproduces the sealed allocator court and successor
lattice bit-for-bit. Full suite at the end of the phase: **439 tests,
9 skipped (fixture-gated), 0 failures** (`swift test`, 2026-09-06).
Merged to main 2026-09-06 (rollback tag `pre-merge-p4-20260906`).

**Contract, frozen before any gate code:**
`docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md` commits the two gate tables as the
frozen criterion — prior work the two Python courts
(`market/build_court_allocator_runs.py` / `court_allocator_runs.json`,
`market/build_pregate_successor.py` / `pregate_successor_v1.json`),
delta = engine (Swift) re-implementation, run kind **control /
re-derivation**, never a claim. **AMENDMENT 1** (2026-09-06, an independent
hostile read, applied before any gate code existed, no number moved):
restore path keeps drop-with-WARN on a missing/mismatched alarm file,
but the **gate path is different — fixture absent → `XCTSkip` with a
printed reason; fixture present with hash ≠ pinned → the test FAILS,
printed as a finding, never skips, never warns.** Also corrected: the
frame-level burst phrase is NOT implemented (116 = pocket 6 count, not
150 = every non-quiet frame); the partial-tier/merge-rule coincidence
reason (pocket-6 r7 affordability is necessary, not sufficient — the
one-slot fact makes it infeasible to beat, and the best partial combo
loses on cost); the residual tie-break is unexercised on this object;
gate-2 exactness comes from every intermediate being an exact dyadic
rational inside 53 bits (not from loop-order superstition, though the
Python loop order is still mirrored, harmlessly); the gate-2 diagonal
column is **retention scoring** (a coincidental rescue counts; a
phantom is never itself a judged alarm).

**§0 conventions (17, resolved sealed-record ambiguities, sent out
for an independent hostile read), in brief:** file order reconstructed from
`(block rank quiet<liar<deep<drift, numeric suffix)`, 1-based `idx`;
`cal0_1` kept as `AlarmFixture.control`, never an `AlarmRecord`
(`records.count == 200`); quiet culprits carry `claim == nil` (buy
nothing under allocator/greedy/oracle, uniform still pays 472); drift
has `ear == nil`, pocket 6, row `L`; burst is alarm-level
(`pocket == 6`), the frame-level phrase is not implemented; phantoms
are `SealedClaim` values only, never an `AlarmRecord`; sealed ids
(pockets 3..6, tiers r3..r10) convert to `BudgetLayout`'s zero-based
indices via `pocketIndex(p) = p−3`, `tierIndex(r) = r−3`, `L→0`/`D→1`;
the merge rule and the successor's partial-tier options coincide in
value on the sealed grid only (pocket-6 r7 is affordable everywhere
non-cut, the cheapest r7 pair never is) — not rule equivalence; the
tie-break is unexercised on this object; gate 1 covers all 5 grid
points, gate 2 the 4 non-cut points (k7=0 is cut by the successor);
greedy/uniform are court rules (`AllocatorCourt`/`SuccessorCourt`),
not primitives, so gate and daemon share one implementation; twin
registries are daemon-global (a `READER` session may only read them);
id format is `"<letter>%08x"` of a per-registry counter that never
reuses a value, prefixes `s`/`t`/`n`/`c`/`g`/`b`/`a`; WAL logs
post-state for `STREAM NEXT` (O(1) replay), the count for
`RECORD SLICE`, the values for `RINGS WRITE`, `n`+value for
`CLOCK ADVANCE`; alarm sets persist by reference (path + sha256), a
missing/mismatched file on **restore** drops that entry with a stderr
`WARN` rather than refusing the whole load — the gate path's
wrong-hash-FAILS rule (above) is stricter and does not apply to
restore.

**Gate numbers reproduced bit-for-bit (T4, `SealedGateTests`, run
against the real 29 MB fixture, `DAGDB_W2_FIXTURE` set):**
- **Gate 1** (allocator-court replay): 5 budget-grid points × 4 arms
  (allocator, uniform, greedy, oracle), every field exact — misses,
  served, cost, dummy, dominated, per-class/per-ear tallies, burst,
  `maxSpendRatio`, `servedTrialIds`. Allocator == oracle at every
  point (P0 0/150/819218 … P4 100/50/4900).
- **Gate 2** (successor dyadic ε lattice): 4 non-cut budget points ×
  4 sweeps (m, s, n, diag) × 5 ε values {0, .25, .5, .75, 1}, compared
  with exact `XCTAssertEqual` on `Double` (never `accuracy:`) —
  misses_alloc, misses_greedy, cost_alloc all exact. Anchors: the
  corner (εm=1, εs=1, εn=0) gives misses = 100.0 exactly at all four
  points under both policies; `max |1 − weightSum| == 0.0` over the
  full 65-point lattice.

**Per-task entries (each is one commit on `dag/p4-interface`):**
- **Contract first** — `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md` committed before any
  gate code exists; the §0 conventions list sent out for an independent hostile
  read, applied as AMENDMENT 1 the same day.
- **T1a** — `NamedStream`/`StreamHeader`/`StreamRecord` gain
  state-bearing inits and `Codable` (public `Slice` init), so a
  daemon-held stream/record survives a restart in O(1) rather than
  redrawing.
- **T1b** — `BudgetLayout`/`CrossConvolutionCheck`/`GearedRings`/
  `MasterClock`+`GearRatio`+`PhaseGear` gain state-bearing inits,
  `Codable`, public output-struct inits, and throwing shape guards
  (`validationError`, `shapeViolation`) so a daemon front door can
  reject a bad shape with `ERROR bad_value` instead of trapping.
- **T2** — `AlarmRecord` + `SealedCourt` (sealed pocket/tier/tariff
  mapping) + `AlarmFixture` (SHA-pinned loader, env
  `DAGDB_W2_FIXTURE`, skip-if-absent) — twin spec line 4's fixed
  vocabulary, reconstructing file order from the sealed keys.
- **T3** — `CorruptionModel` (εm/εs/εn exact-enumeration weights,
  phantoms as `SealedClaim` values, never as `AlarmRecord`s) +
  `SuccessorCourt` (the counting hand: `allocatorDecide`,
  `greedyDecide`, `classStats`, `frameTotals`).
- **T4** — `AllocatorCourt` (mirrors `run_point` bit-for-bit) + the
  two sealed gates in `SealedGateTests`, against
  `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md`; wrong-hash-fails rule applied.
- **T5** — `TwinRegistry<Entry>` (the generalized reader-session
  pattern) + `TwinState` (one daemon-global instance of all seven
  registries, `TwinOp` apply, `Codable` `Snapshot`, `export`/`restore`).
- **T6** — WAL opcodes `0x20`–`0x2B`, `TwinWALCodec` (encode/decode,
  little-endian, malformed payload skipped not fatal),
  `DagDBWAL.replay(twin:)`.
- **T7** — Snapshot **v7**: `TWIN` section (magic `"TWIN"` + u32
  length + sorted-keys JSON) between the WGTS lane section and the
  ENVS trailer; loads v1..v7; a v≤6 file resets the twin state.
- **T8.1** — `TwinCommand` grammar (47 verb-lines), `DSLParser+Twin`,
  handler dispatch skeleton + the `READER` read-only allowlist, and
  the shared `HandlerFixture` test helper. Stub replies until T8.2–T8.5.
- **T8.2** — real STREAM/HEADER/RECORD handlers (log-first WAL
  pattern); `twinState` wired into the daemon's replay and save paths.
- **T8.3** — real RINGS/CLOCK/GEAR handlers; found and fixed a gear-
  close bug the same session: closing a `GEAR` left its id inside the
  owning `CLOCK`'s `gearIds`, so a later `CLOCK ADVANCE` would trip on
  a stale gear id — `TwinState.apply(.close)` on a `g` id now prunes
  the gear from its clock's `gearIds` before closing it.
- **T8.4** — real XCONV CHECK (reads two records + two path kernels
  out of shm, runs the sealed W1 identity, never touches the WAL) and
  BUDGET OPEN/SEALED/ALLOCATE/INFO/CLOSE/LIST handlers.
  (compatibility entry point; not the court's sealed cross-convolution; see XCONV SEALED (next window))
- **T8.5** — real ALARM handlers: LOAD (guardPath first, then
  SHA-pinned load — any `AlarmFixture.FixtureError`, including a
  hash mismatch, becomes `ERROR io:` containing the literal phrase
  "sha256 mismatch"), INFO/FRAME/COURT/SUCCESSOR/CORRUPT as pure reads
  over `AllocatorCourt`/`SuccessorCourt`/`CorruptionModel`.
- **T9** — MCP wrappers (26 twin verb tools) in `mcp_server.py`, the
  `dagdb_query` catalog's `Twin:` block + id-prefix map, the
  `dagdb_reader_query` allowed-list update; `web/bridge.py` gains
  `READ_ONLY_TWIN` (a set of `(verb, subverb)` pairs mirroring
  `TwinCommand.isReadOnly`) checked alongside the existing
  single-token `READ_ONLY_VERBS`.

**Live daemon socket smoke (2026-09-06, scratch env, concurrent with
this writeup):** 10 of 13 checks passed on the wire as expected —
`STATUS twin_open=`, `STREAM OPEN`/`STREAM NEXT` (the six reference
words read back from shm exactly), `CLOCK`/`GEAR` (`fires=4285`),
`BUDGET SEALED`/`BUDGET ALLOCATE` (`served=3 cost=5618.0`),
`HEADER CHECK` (`combBelowNyquist`), `SAVE` to a v7 snapshot, and an
explicit `LOAD` restoring the full twin state exactly (`draws=6`,
`fires=4285`, `twin_open=4`). The remaining 3 expectations exposed a
**pre-existing, pre-existing gap**: a plain daemon **restart** after `SAVE`
(no explicit `LOAD`) comes up with empty twin state — `SAVE`
checkpoints the WAL and startup only replays records past the last
checkpoint, with nothing auto-loading a snapshot at startup. Same
behavior for ordinary graph state (the prod launchd plist passes no
load step either); tracked as a new roadmap item, not an interface-phase defect.

---

## 2026-05-13 → 2026-09-05 — bulk verbs to twin-spec primitives

Ten sessions, May to September: bulk DSL
install verbs, a full Fable source-review sweep and its fixes,
nested-LUT microcircuits sanitized for the public tree, tick-
performance compaction, G73 durability hardening, weight-lane
persistence (E1) and its raw-throughput riders (E2/E3), a roadmap
draft, and seven twin-spec primitives merged to main. Full Swift
suite: **165 → 191** (June) → **218** (Aug 22) → **249** (Aug 30,
holds through the Sep 5 merge).

### 2026-05-13 — bulk-install DSL verbs for microcircuit compilation

`SET_LUTS_BULK` and `SET_NEIGHBORS_BULK` parallel the existing
`SET_RANKS_BULK`: each reads a vector from shm and memcpys it into
the matching engine buffer in one round-trip. Motivation: compiling
continuous-function approximators (EDT-style microcircuits) one
round-trip per node made a million-node graph build take a million
round-trips through `SET LUT` + `CONNECT`; bulk install collapses
the same compile to three shm writes (ranks + LUTs + neighbours) and
three verbs. Both bypass per-node WAL and rank-monotonicity
validation, matching the `SET_RANKS_BULK` contract (pair with
`VALIDATE` if the caller's compiler isn't trusted); both rejected
inside reader sessions. New `docs/wiki/microcircuit-compilation.md`
walks the recipe end to end — compile-time vs. eval-time speed, LUT
input packing, `BACK_EDGE` for recurrence instead of growing rank
depth, a worked x² example, and an anti-pattern list.

### Fable review fixes (June)

A full Fable source-review pass (engine, persistence, daemon, tile
layer, Python surface, tests) produced a findings report with one
live correctness bug, two crash/corruption hazards, Python contract
bugs, a security hole, and a structural test gap. All fixed in one
06-09 session bar one deferred item:

- **C1** — the reader-session snapshot copied `n*4` bytes of the
  rank buffer, but rank is u64 (`n*8`); every `OPEN_READER` session
  returned correct ranks for the lower half of the graph and
  zero/garbage for the upper half — silently wrong data on the
  shipped MVCC path. Fixed the copy width and strengthened four
  other tests that only checked the lower half and would have
  passed on this bug class.
- **H1** — a corrupt/crafted snapshot's back-edge trailer could
  carry a `dst` past `nodeCount`, corrupting the heap via an
  unchecked `isRegisterBuf` write; now bounds-checked and throws,
  matching what the WAL replay path already did.
- **H2** — a snapshot truncated mid-write (the crash-during-write
  case) trapped on an out-of-range `subdata` slice and killed the
  daemon instead of throwing; added length guards before both
  subdata calls.
- **P1-P3** — Python docstrings and helpers still claimed u32 for
  the bulk-rank vector after the daemon moved to u64; the two new
  bulk verbs were invisible to MCP clients; the "unbounded" rank cap
  used for hive queries was still 2^32-1 on a u64 axis. All
  corrected; the MCP query catalog regenerated from the actual
  parser surface (~20 missing verbs restored).
- **S1/S2/S3/B4** — the WebSocket browser bridge relayed any
  received string to the daemon's full write surface with no
  allowlist or Origin check; now read-only by default with an
  opt-in write flag, an Origin allowlist, control-char rejection
  (defends against command smuggling), and a socket timeout so a
  stalled daemon can't wedge an executor thread forever.
  `mcp_server.py`'s auto-`pip install` on import was deleted in
  favor of a printed instruction.
- **T1** — the DSL parser and command handler lived inside the
  daemon's executable target, untestable by the suite (the same
  drift hazard that hid C1 one layer up); extracted into a new
  `DagDBDaemonKit` library target with a testable
  `DagDBCommandHandler`.
- **T2-T4** — regression coverage for the fixes above, plus
  invariant-locking tests (GPU-vs-reference LUT6 equivalence,
  race-free 7-coloring, colour-group partition, chained `BACK_EDGE`
  one-tick latch), plus per-test temp directories so concurrent
  `swift test` runs stop racing on shared `/tmp` fixture names (the
  several branches share one working directory).

Full suite climbed **165 → 191** across the sweep (README corrected
06-24 after an adversarial read of the deck claims caught the stale
figure).

### Nested-LUT microcircuit + public-tree sanitization (July 1-2)

Committed the composition claim behind the microcircuit-compilation
recipe: a 40-gate, depth-7 LUT6 network (Wallace carry-save adder)
computes 4-bit × 4-bit multiplication exactly for all 256 inputs on
the Metal engine — P3..P7 need all 8 input bits, beyond any single
LUT6. Suite **191 → 192**. New `docs/wiki/nested-luts.md` documents
the single-LUT6 ceiling and the build idioms.

Same window, a honesty and public-tree sanitization pass:

- The 14 GCUPS figure quoted on the site and in doc comments
  belonged to the Savanna engine, not DagDB (DagDB's own
  measured number is 0.71 GCUPS at 1M nodes) — corrected across the
  slide deck, site HTML, and source doc comments.
- Deployment names, internal task lists, and inter-agent work-order
  prose were genericized or removed from the AC-3 example and
  troubleshooting docs ahead of the public push, matching the
  public-release sanitization pass.
- License/NOTICE aligned to Apache 2.0 at both repo levels (stops
  the GPL drift recurring from dev); the AC-3 Australia example was
  actually run against a scratch daemon (exit 0, converges in 2
  ticks) and the receipt committed — the package had existed since
  June, only the run receipt was missing.

### Tick-perf compaction + TICK_SYNC + AC-3 XCTest (July 7)

- **Per-(rank,color) compacted dispatch** becomes the default
  rank-mode tick path: a flat segment buffer + offset table, lazily
  rebuilt on a dirty flag; the old per-tick full scan (`tickLegacy`)
  kept as independent ground truth. Verified bit-for-bit against
  legacy across 20 seeded random graphs × 8 ticks. All 8
  `truthRankIndex.markDirty()` call sites (every rank-mutating
  daemon path) now also invalidate the compacted segments, so the
  fast path can never evaluate stale topology.
- **`TICK_SYNC`** adds a double-buffered synchronous tick mode
  (kernel + engine + DSL verb) for workloads needing simultaneous
  rather than rank-ordered updates (registers latch in-kernel, as in
  rank mode). Verified against a CPU double-buffer reference across
  10 seeded graphs × 10 ticks.
- **Benchmark receipt** — a 50-tick committed run, three modes, two
  rank spreads, honest ranges (thermal variance ~2x run to run).
  Compacted dispatch wins every shallow-spread run; a 16-band spread
  is documented unstable (latency-bound small dispatches) rather
  than tuned on noisy data. `TICK_SYNC` holds ~3.5 GCUPS stable — no
  Savanna-parity claim.
- **AC-3 Australia as an engine-level XCTest** ports the daemon-level
  demo to a committed regression: the 96-node `BACK_EDGE` encoding
  ticks the 21 domain registers against the pure-Python synchronous
  AC-3 reference, converging at tick 2 (tick 3 confirms the fixed
  point). Closes the run-receipt gap flagged in the sanitization
  pass above.
- Removed a redundant placeholder test made dead by the real
  `DagDBCommandHandlerTests`; documented the reserved `nf` snapshot
  header field with an honest one-liner instead of a bare
  placeholder comment.

(Same window, 07-15, unrelated: `image_mcp.py` prepends `/usr/sbin`
to `PATH` so the mflux `system_profiler` probe survives MCP's
PATH-stripping — battle-tested.)

### G73 durability (July 31)

Four-step durability hardening plus a stress probe:

- **Torn-tail audit** — WAL replay already tolerated a
  partially-written last record correctly (stops at the first
  record whose declared length overruns the remaining bytes,
  reports the byte offset); no code change needed, pinned with a
  deterministic truncated-WAL fixture.
- **Group-commit fsync policy** — the appender gains a
  `.grouped(n, ms)` mode alongside the default `.everyRecord`; a
  single serial queue owns every write, `F_FULLFSYNC`, and the
  deferred-fsync timer so they can't race each other. In grouped
  mode a record is visible to replay immediately but its fsync
  defers to the earlier of n unsynced records / ms elapsed / an
  explicit barrier — a crash loses at most the unsynced tail,
  bounded by n. Forced barriers on snapshot save and daemon
  shutdown. Production ignores the env override and always runs
  `.everyRecord` (asserted at startup).
- **Snapshot SHA-256 side-by-side manifest** — `save()` hashes the
  final on-disk bytes after the atomic rename and writes a `.sha256`
  manifest; `load()` verifies it before touching any buffer (a bad
  digest refuses with a named error, no half-load; a missing
  manifest warns and accepts, so legacy snapshots keep loading).
- **Kill-9 stress probe** — a scratch daemon (never prod, own socket
  and data root) driven at ~1k ops/s under grouped commit, killed
  mid-write, restarted via WAL replay, then SAVE/LOAD round-tripped
  through the new manifest. 10/10 clean; the loss bound matches the
  group-commit N (kill -9 can't induce the media-loss case
  `F_FULLFSYNC` actually guards against — that's what the
  deterministic torn-tail fixture from step one covers instead).

Separately, a 16-rank / N=5 cell run confirmed the July "unstable"
compaction reading from the tick-perf benchmark was thermal, not a
correctness issue: stable, ~1.75x compaction speedup every run.

### E1 — weight-lane persistence (Aug 22)

The engine has carried Float edge weights and a weighted GPU tick
kernel since birth, but neither lane survived save/load and the WAL
couldn't record weight writes — this closed the gap. New `nodeValue`
Float lane (solver state; the legacy Int16 activation lane stays).
Snapshot v6 adds a `WGTS` section between the back-edge section and
the trailer, storing only non-default lanes so boolean-mode
snapshots pay 5 bytes; both lanes reset to defaults on every load
path (fixes a latent stale-lane-after-load hazard on pre-v6 files).
Loader accepts v1..v6. WAL gains `setEdgeWeight`/`setActivation`/
`setNodeValue` opcodes with the same bounds discipline as the
existing ones. 7 new tests (roundtrip, default-lane economy,
compressed path, WAL replay incl. rejection) — suite **217**. Daemon
`SET WEIGHT` / `SET VALUE` commands followed the same day (log-first,
bounds-checked, finite-only values); `CURRENT_STATE.md` refreshed —
suite **218/218**.

### E2 runner (Aug 22)

`E2Runner`, a new executable target: a frozen-schedule smoother
built directly on the engine. Maps a row-major reference contract
onto the engine's own Morton wiring (`grid.mortonRank`/
`mortonToNode`, no rule duplication); G2 conductances from a frozen
LCG in lexicographic edge order written into the engine's edge-weight
lane; Float64 accumulation over the Float32 `nodeValue` storage lane;
per-cell fresh schedule stream (seed 77, slot-order consumption,
skipping absent slots); D=0 structurally trapped per the contract.
Control mode traces the first 100 rounds (sup norm, hash, vectors)
and merges in the Python reference trace for comparison — E2Runner
builds raw outputs only, a separate judge owns the pass/fail ratios.
A second pass added per-profile tolerance and output naming.

### E3 ladder (Aug 26)

`E3Ladder`, another new executable target: an exact tier ladder run
on the same engine lanes (ranks/leaks/weights fabric-resident,
fp32-per-rung storage, Accelerate-backed folds), producing tier
answers alongside their folded sources. A second pass moved the
third injection (f3) to rank 20 so it folds first — the worst
rolling case. A third pass parameterized the G2 seed and injection
nodes so different runs can compare as calibration twins rather than
one-off scripts.

### Roadmap draft + seven twin-spec primitives (Aug 30)

A roadmap draft (`ROADMAP_DRAFT.md`) distilled from the sealed E1-E3
record, refined against a "twin spec" list of primitives a
drift-twin engine needs. Seven of those lines shipped the same day,
each a small sealed engine primitive with its own test file:

- **`NamedStream`** (twin spec line 3 foundation) — PCG64 XSL-RR
  128/64 generator with a numpy state-bridge and pinned test vectors.
- **`StreamHeader`** (line 7) — the "t-zero law" as an engine
  admission check: seven declared quantities, arithmetic refusals
  for inadmissible headers.
- **`StreamRecord`** (line 3) — slice replay bit-for-bit from
  boundary states; inadmissible headers refused at birth.
- **`BudgetLayout`** (line 5) — twice-sealed decision letters
  encoded as engine logic: merge, min-cost tie-break, lexicographic
  residual.
- **`CrossConvolutionCheck`** (line 6) — the sealed W1 identity as a
  standing engine check (pass / scream / flash states).
- **`GearedRings`** (line 1, memory half) — a sealed odometer as a
  recording primitive: signed extremum recall across orders of lag.
- **`MasterClock` + `PhaseGear`** (line 2) — one tick, rational
  gears, drift-free by integer arithmetic, with a latch.

Suite reaches **249**.

### Merge to main (2026-09-05)

`dag/twin-r3-replay` merged to main: twin spec lines 1, 2, 3, 5, 6,
7 — named streams, t-zero header, slice replay, budget layout,
cross-convolution check, geared rings, master clock. **249 tests**,
no regressions from the Aug 30 branch tip.

---

## 2026-05-11 — u64 scar fix + docs current-state pass

### u64 scar fix (`dag/u64-scar-fix`)

Codex flagged 2026-05-09: the daemon's `NODES AT RANK` filter still
narrowed rank queries to `UInt32`, hiding any node whose rank
exceeded 2^32 − 1. Both call sites (writer + reader-session mirror)
now compare against `UInt64(r)`. Rank storage was widened to u64
in T1b; the filter expression had not caught up.

Acceptance test `DagDBU64RankTests` (three cases) exercises the
engine rank buffer and the filter expression at 2^32 + 4. Codex's
explicit pattern — `SET 0 RANK 4294967300; NODES AT RANK 4294967300`
returns node 0 — is covered. Full Swift suite **162 → 165 green,
zero failures.**

Merged to main and promoted to prod via launchctl bootout/bootstrap
the same day. Live daemon's `NODES AT RANK 4294967300` now returns
`OK NODES rows=0` cleanly; the old binary would have trapped on
the same input.

### Docs current-state pass (`dag/docs-current-state`)

Codex's priority #3. New `CURRENT_STATE.md` at repo root: canonical
pointer for snapshot version, test count, daemon supervision, DSL
drift, per-node footprints. Inline drift fixed in:

- `README.md` — test count 98 → 165; `SET_RANKS_BULK` u32 → u64
  wording; tree-listing test count.
- `ARCHITECTURE.md` — snapshot version list updated through v5;
  per-suite test breakdown converted to a topical map (count
  drifts faster than the headline); total 98 → 165.
- `CONTRIBUTING.md` — test count and Python-pytest status.
- `dagdb/README.md`, `site/README.md` — test count + version.
- `docs/wiki/data-and-persistence.md` — snapshot row to v5,
  42 B/node body, fixed trailers.
- `docs/wiki/dsl.md` — `<u32>` rank → `<u64>`; version list
  through v5.
- `docs/wiki/mvcc.md` — per-session RAM cost 38 → 42 B/node.
- `docs/wiki/back-edges.md` — 120 figure marked as the
  back-edge-landing snapshot; current count cross-referenced.
- `docs/wiki/quick-start.md`, `docs/bfs_usage.md` — Swift count
  and Python collection-error caveat; bulk example widened to u64.
- `docs/wiki/README.md` — T3 description widened to u64.

Surfaces left alone: `dev-test-prod-memo-2026-05-01.md` keeps its
"a separate supervisor will own prod" framing as a forward-looking plan the
launchctl-current state has not flipped to; `tiled-streaming.md`
and the 04-29 memo keep their landing-time numbers with a pointer
to `CURRENT_STATE.md` where needed.

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
  an archive directory outside this repository alongside other deprecated
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
