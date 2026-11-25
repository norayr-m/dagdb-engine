# DagDB Roadmap

*Last refreshed: 2026-09-10. Supersedes an earlier draft (v0,
2026-08-30).*

> **Humble disclaimer.** Amateur engineering project. We are not HPC
> professionals and make no competitive claims. All numbers come from
> one M5 Max laptop, no controlled benchmark, no peer review. Errors
> likely. Numbers speak.

## North star

DagDB is the **body of the digital twin**: the general engine on which
the twin's organs execute — state that persists, a single clock, exact
replay, memory across orders of time, folding that summarises a region
exactly at its boundary. Everything on this roadmap is ranked by how
directly it serves that body. The twin's requirements arrive as a
numbered spec list from the twin project; this roadmap is the engine's
answer to that list.

The twin's own purpose — what the body is *for* — is rare-event
detection on distribution networks at parts-per-billion duty: sub-
millisecond transients in continuous multi-day streams. Every engine
feature below can be traced to that yardstick or is honestly labelled
infrastructure.

## Status of the twin spec (nine lines, 2026-08-30)

| # | Requirement | Status | Evidence |
|---|---|---|---|
| 1 | Ranked-shell state + fold ladder, per-edge fold weights persisted | **Done** | weight lanes (snapshot v6), E3Ladder — 927× compression at 1e-7 over 19 folds (a ratio the out-of-repo sealed court computed from the `e3-ladder` CLI's raw outputs on its 44 × 44 hex-grid objects, 30/30; no test in this repository checks the ratio); the ladder as a library call + daemon verb, `LadderFold.swift` + `FOLD` verb family, bit for bit against the sealed runner's frozen objects — merged 2026-09-10 |
| 2 | One master clock, rational gears, no second clock | **Done** | `MasterClock.swift` + `PhaseGear`; integer-exact 6:1 ladder; tests |
| 3 | Deterministic replay, bit-for-bit slices | **Done** | `NamedStream` (PCG64, numpy state-bridge, pinned vectors) + `StreamRecord` |
| 4 | Alarm-stream contract (records shaped like the sealed `DAGDB_W2_FIXTURE` set; corruption on READ side only) | **Done** (code, gated) | `AlarmRecord`/`SealedCourt`/`AlarmFixture`/`CorruptionModel`/`SuccessorCourt`/`AllocatorCourt`; both sealed gates reproduce `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md` bit-for-bit — gated on the out-of-repo `DAGDB_W2_FIXTURE`, skips (not fails) when unset; merged 2026-09-10 to main |
| 5 | Per-frame budget layout (knapsack primitive) | **Done** | `BudgetLayout.swift` — claim merge, min-cost tie, lexicographic residual; tests reproduce the sealed courts' decision rules; spent on the clock by the hook — `AttentionHook.swift`, `HOOK` verb family |
| 6 | Cross-convolution self-test | **Done** | `SealedCrossConvolution.swift` — the out-of-repo court's own frozen residual R (window [warmup, n), one-sided denominator, float64), reproducing the court's four lines exactly; `KernelPair` stores per-path kernels by reference, `KERNEL`/`XCONV SEALED` verb family — merged 2026-09-10. `CrossConvolutionCheck.swift` (pass/scream/flash, 2026-08-30) is now the **deprecated patrol check**: it compares past the record's end with a symmetric denominator and Float32 inputs, and flips the court's pass/fail verdict on 50 of the 190 sealed records (all true recordings) — kept wired for compatibility, no longer the engine's standing cross-convolution check |
| 7 | Mandatory time-domain header (t-zero law) | **Done** | `StreamHeader.swift` — seven declared quantities, arithmetic refusals |
| 8 | Waveform mouth as matmul (bank Φ, generate = Φ@C) | **Done** (code, gated: contract path) | `WaveBank.swift` + `BANK` verb family — default bank K=144 (repaired, full rank), the sealed K=160 control kept and reachable with `ALIASED`; merged 2026-09-10 to main |
| 9 | LUT nesting for the attention cascade (ternary patrol → float fovea) | **Waits on the hex-attention line** | design only; the hex-attention seam; not sealed |

Seven of nine on main as of 2026-09-06 (rollback anchors
`pre-merge-twin-r3-20260905` and `pre-merge-p4-20260906`; the alarm-stream
contract gated on the out-of-repo fixture); 446 tests on main as of 2026-09-09, 1,519
on 2026-11-19 and 1,540 on 2026-11-24 (49 skips, 48 of them fixture-gated, 0 failures; how it was run is
in `CURRENT_STATE.md`, Test suite). The waveform mouth
done 2026-09-10 — 506
tests. The fold ladder promoted to library + daemon verb on
2026-09-10 — 544 tests, 10 fixture-gated skips without `DAGDB_E3_RUNS`
set (9 with it).

The alarm-stream contract gained a second view family on 2026-09-10 —
alarm-set
derived views (`NpzReader`/`CortexFixture`/`DerivedViews`, `VIEW` verb
family) beside the allocator court above: the reflex,
the geometry-then-energy rung, and the arrival-geometry ceiling,
gated on a second out-of-repo fixture (`DAGDB_CORTEX_V4_FIXTURE`).
Every view's numbers and the daemon verbs
held exactly at S = 2/4/6/8. 570 tests then.

## Milestones delivered (2026)

- **May** — database core complete: ranked DAG, LUT6, ternary state,
  Morton + 7-colouring, snapshot/WAL/backup chain, MVCC readers,
  secondary index, distance metrics, CLI/daemon/MCP/Postgres surfaces.
- **June** — full external source review absorbed: 13 findings fixed
  (reader-session copy bug, snapshot hardening, bridge security, test
  isolation); daemon command layer extracted.
- **July** — nested-LUT microcircuits (mult4 exact on engine); tick
  performance recovery (compacted per-rank/colour dispatch, TICK_SYNC
  double-buffered mode, ~1.75–2× on the 16-rank cell); durability
  hardening (WAL group-commit fsync policy, SHA-256 snapshot manifest, kill-9
  probe 10/10); public sanitisation pass.
- **August** — weight/value lanes persisted (snapshot v6, WAL opcodes,
  daemon commands); smoother on the engine sealed against the
  asynchronous price curves (8/8, bridge bit-for-bit); exact tier
  ladder on engine lanes (30/30); seven twin-spec primitives.
- **September** — twin primitives merged to main; documentation set
  (this file, PROJECT_PLAN, CAPABILITIES, CHANGES, demo). Then the
  interface phase (merged 2026-09-06): the
  alarm-stream contract as engine type, both sealed gates
  reproduced bit-for-bit, all seven primitives + alarm-stream types
  wired to the DSL/daemon/MCP, WAL opcodes 0x20–0x2B, snapshot v7.

## Next (in dependency order)

1. **Alarm-stream contract as engine type.** The interface
   between hearing and dispatch; corruption models compose on the read
   side only. Gate: reproduce the successor court's sealed records
   bit-for-bit through the new type.
2. **Waveform mouth — DONE 2026-09-10**. `WaveBank`: generation W = Φ·C
   is one `cblas_sgemm` call; fit is LAPACK `dgelsd` (SVD); the bank
   declares its own rank/condition number at creation. Checks: the bank
   Φ, the generation W, the out-of-bank law, the probe fit, the in-bank
   residual and the daemon verbs hold; throughput and the control bank's
   declared rank are printed — engine out-of-bank residual mean 0.981743
   on the repaired (K=144) bank against the law 0.982265, reported by
   the engine itself, never hidden.
3. **DSL/daemon exposure of the twin primitives.** Today they are
   library types with tests; the twin needs them over the socket.
   Gate: every primitive reachable by one daemon command with a
   round-trip test.
4. **Startup snapshot load before WAL replay — DONE 2026-09-09**
   (opt-in `DAGDB_STARTUP_LOAD`; `DagDBStartup.recover`; autosave now
   checkpoints the WAL). Met: socket smoke 23/23 including the
   restart step; `StartupRecoveryTests` 7/7. Open: the prod plist does
   not set the var yet.
5. **Fold API — DONE 2026-09-10**. E3Ladder promoted from runner
   to library call, `LadderFold.run(object:schedule:sources:)`, and a
   daemon verb, `FOLD RUN/KEPT/SOURCE/TIER/INFO`, arithmetic
   unchanged. Checks met: the control object, the court ladders, the
   rebuilt runner and the daemon verbs bit-for-bit against the sealed
   runner's frozen objects; the per-fold price printed.
6. **Cross-convolution self-test, second half — per-path kernel storage — DONE 2026-09-10**.
   `KernelPair`
   stores per-path kernels by reference (path + sha256), a per-pair
   warmup declared or derived from τ_A/τ_B/σ_source; `SealedCrossConvolution`
   is the out-of-repo court's own frozen residual R (window [warmup, n), one-sided
   denominator, float64 end to end), reached over the socket as
   `XCONV SEALED`. Checks: the standing relative bound holds on all
   190 sealed trials; every court line (the court's four) is reproduced
   exactly; storage and reach over the socket; the warmup derives as 185
   for the sealed set. **Deprecation, in the same
   change:** the pre-existing `XCONV CHECK` (`CrossConvolutionCheck`,
   2026-08-30) is not the court's R — full-length window, symmetric
   denominator, Float32 — and flips the court's pass/fail verdict on 50
   of the 190 sealed records (all true recordings). It stays wired for
   compatibility, documented as the patrol check; `XCONV SEALED` is
   the standing cheap cross-convolution check from here.
7. **Alarm/attention hooks — DONE 2026-09-10**. The sealed allocator court as a
   daemon-global ticked process, `AttentionHook`: one hook = one alarm
   set + one budget layout (sealed by default) + a per-frame budget B
   + a lag Δ (3) + one of three lagged policies (allocator, greedy,
   uniform — the oracle has no lag, stays a court arm) + an optional
   master clock; one step advances the frame counter by one, reads the
   lagged source, books a purchase under the court's own arithmetic,
   and appends one derived ledger row. Bound to a clock, one CLOCK
   ADVANCE tick is one hook step, applied after that tick's gears — no
   batch call. Checks: `hook.result == AllocatorCourt.run(...)[policy]`
   bit for bit at all 5 sealed budget points × 3 policies; the
   per-frame ledger's identities hold over the 203 sealed rows;
   WAL replay and snapshot restore reproduce both; bound and
   unbound hooks agree, one driver only; the daemon verb family
   round-trips exactly over the socket. Depends on 1 and 5. The
   derived views (the alarm-stream contract's second view
   family, above) remain a candidate feed for this hook — reflex tied
   sets and the rung's centroid distances are the kind of per-frame
   signal a budget-spending allocator would consume — but nothing
   wires them together yet.
8. **Tiling road.** `TiledGraphRouter` from scaffold to routing;
   `TileHalo` carrying float lanes. Serves scale; routing scheme still
   open (hex hierarchy where topology permits — printed caveat).
   **Step one DONE** (2026-09-10): tile files
   (`TiledGraphFiles.write`), router load/evict with LRU + a
   torn-tile refusal (`TiledGraphRouter`), cross-tile BFS/ancestry/
   select agreeing with the single engine exactly, and the daemon
   surface — `SAVE TILED`, `TILED OPEN/BFS/SELECT/STATUS/LIST/CLOSE`
   — plus the MCP/bridge wrappers.
   **Step two DONE** (2026-09-10): ticking
   across tiles — ghost registers as inputs for cross-tile sources,
   descending-rank world ticks with fresh halos each round, per-tile
   flush (BEGIN/body/strip/meta/manifest entry/COMMIT) with crash
   recovery at both crash points, per-tile epochs (no router-global
   counter — the router's epoch is the (min, max) over every tile),
   writer/reader roles at open (a writer recovers and completes any
   partial round before answering; a reader refuses a torn world by
   name), and the daemon surface — `TILED TICK`/`TILED GET`, `TILED
   OPEN`'s `recovered=/completed=`, `SAVE TILED`'s cross-tile-
   BACK_EDGE refusal — plus the MCP/bridge wrappers.
   Still open (explicitly not promised by either step): the
   pre-fetch thread (optional — it would change no result
   if added), the cold tier, thermal pauses, the 10¹¹-node run,
   `TILED BACKUP`; routing scheme itself (hex hierarchy) unchanged
   from before.
9. **Liver twin plugin surface.** Blocked on that twin's spec (state
   model, kernels, observables). Placeholder until it lands.
10. **LUT nesting / hex seam.** Handover of hex-attention artefacts to a
    later line when it exists; the engine hosts the nesting, that
    later line owns the cascade.

## Gates that every item passes

- A frozen contract before any number exists — object, method, floor
  of the instrument, prior work and the run's kind (claim / control /
  re-derivation), PASS criterion as a number.
- Blinded rooms; a mechanical notary; an independent adversarial review.
- Merge to main only with a proven rollback anchor before and a green
  full suite after.
- Documentation updated in the same change (CHANGES, CURRENT_STATE,
  dashboard ledger).

## Not on this roadmap, by policy

- No real grid data, no real network topologies — synthetic and
  standard test feeders only.
- No distributed multi-machine mode; one machine holds the world.
- No float in the ternary core; float lives in parallel lanes beside
  the 42-byte record.
- No benchmark claims against other systems.
