# DagDB Roadmap

*Last refreshed: 2026-09-10. Owner: the engine keeper. Supersedes
`dagdb/ROADMAP_DRAFT.md` (v0, 2026-08-30).*

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
numbered spec list from the twin line; this roadmap is the engine's
answer to that list.

The twin's own purpose — what the body is *for* — is rare-event
detection on distribution networks at parts-per-billion duty: sub-
millisecond transients in continuous multi-day streams. Every engine
feature below can be traced to that yardstick or is honestly labelled
infrastructure.

## Status of the twin spec (nine lines, 2026-08-30)

| # | Requirement | Status | Evidence |
|---|---|---|---|
| 1 | Ranked-shell state + fold ladder, per-edge fold weights persisted | **Done** | E1 weight lanes (snapshot v6), E3Ladder — 927× compression at 1e-7 over 19 folds (E3v3 court, 30/30); the ladder as a library call + daemon verb, `LadderFold.swift` + `FOLD` verb family, `docs/contracts/FOLD_API_GATES_FROZEN.md` F1–F5 — on `dag/fold-api`, merged 2026-09-10 to main |
| 2 | One master clock, rational gears, no second clock | **Done** | `MasterClock.swift` + `PhaseGear`; integer-exact 6:1 ladder; tests |
| 3 | Deterministic replay, bit-for-bit slices | **Done** | `NamedStream` (PCG64, numpy state-bridge, pinned vectors) + `StreamRecord` |
| 4 | Alarm-stream contract (W2-shape records; corruption on READ side only) | **Done** (code, gated) | `AlarmRecord`/`SealedCourt`/`AlarmFixture`/`CorruptionModel`/`SuccessorCourt`/`AllocatorCourt`; both sealed gates reproduce `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md` bit-for-bit — gated on the out-of-repo `DAGDB_W2_FIXTURE`, skips (not fails) when unset; on `dag/p4-interface`, merged 2026-09-10 to main |
| 5 | Per-frame budget layout (knapsack primitive) | **Done** | `BudgetLayout.swift` — claim merge, min-cost tie, lexicographic residual; tests reproduce the sealed letters; spent on the clock by the hook — `AttentionHook.swift`, `HOOK` verb family, `docs/contracts/HOOK_GATES_FROZEN.md` |
| 6 | Cross-convolution self-test | **Done** | `SealedCrossConvolution.swift` — the W1 court's own frozen residual R (window [warmup, n), one-sided denominator, float64), reproducing the court's G0–G3 lines exactly; `KernelPair` stores per-path kernels by reference, `KERNEL`/`XCONV SEALED` verb family; `docs/contracts/KERNELS_GATES_FROZEN.md` K1–K5 — on `dag/kernels`, merged 2026-09-10 to main. `CrossConvolutionCheck.swift` (pass/scream/flash, 2026-08-30) is now the **deprecated patrol check**: it compares past the record's end with a symmetric denominator and Float32 inputs, and flips 50 of 190 court gates on the sealed records (all true recordings) — kept wired for compatibility, no longer the engine's standing cross-convolution check |
| 7 | Mandatory time-domain header (t-zero law) | **Done** | `StreamHeader.swift` — seven declared quantities, arithmetic refusals |
| 8 | Waveform mouth as matmul (bank Φ, generate = Φ@C) | **Done** (code, gated: contract path) | `WaveBank.swift` + `BANK` verb family; `docs/contracts/SPEC8_MOUTH_GATES_FROZEN.md` — default bank K=144 (repaired, full rank), the sealed K=160 control kept and reachable with `ALIASED`; on `dag/spec8-mouth`, merged 2026-09-10 to main |
| 9 | LUT nesting for the attention cascade (ternary patrol → float fovea) | **Waits on the hex-attention line** | design only; the hex-attention seam; not sealed |

Seven of nine on main as of 2026-09-06 (rollback anchors
`pre-merge-twin-r3-20260905` and `pre-merge-p4-20260906`; spec 4 gated
on the out-of-repo fixture); 446 tests on main as of 2026-09-09. Spec 8
done on branch `dag/spec8-mouth` (2026-09-10, merged 2026-09-10) — 506
tests. The fold ladder promoted to library + daemon verb on branch
`dag/fold-api` (2026-09-10, built on `dag/spec8-mouth`, not yet
merged) — 544 tests, 10 fixture-gated skips without `DAGDB_E3_RUNS`
set (9 with it).

Spec line 4 gained a second view family on branch `dag/derived-views`
(2026-09-10, off `dag/spec8-mouth`, merged 2026-09-10) — alarm-set
derived views (`NpzReader`/`CortexFixture`/`DerivedViews`, `VIEW` verb
family) beside the allocator court above: the amended-letter reflex,
the geometry-then-energy rung, and the arrival-geometry ceiling,
gated on a second out-of-repo fixture (`DAGDB_CORTEX_V4_FIXTURE`).
Gate contract: `docs/contracts/DERIVED_VIEWS_GATES_FROZEN.md` — V1–V6
held exactly at S = 2/4/6/8. 570 tests on that branch.

## Milestones delivered (2026)

- **May** — database core complete: ranked DAG, LUT6, ternary state,
  Morton + 7-colouring, snapshot/WAL/backup chain, MVCC readers,
  secondary index, distance metrics, CLI/daemon/MCP/Postgres surfaces.
- **June** — full external source review absorbed: 13 findings fixed
  (reader-session copy bug, snapshot hardening, bridge security, test
  isolation); daemon command layer extracted.
- **July** — nested-LUT microcircuits (mult4 exact on engine); tick
  performance recovery (compacted per-rank/colour dispatch, TICK_SYNC
  double-buffered mode, ~1.75–2× on the 16-rank cell); G73 durability
  (WAL group-commit fsync policy, SHA-256 snapshot manifest, kill-9
  probe 10/10); public sanitisation pass.
- **August** — weight/value lanes persisted (snapshot v6, WAL opcodes,
  daemon commands); smoother on the engine sealed against the
  asynchronous price curves (E2v2, 8/8, bridge bit-for-bit); exact tier
  ladder on engine lanes (E3v3, 30/30); seven twin-spec primitives.
- **September** — twin primitives merged to main; documentation set
  (this file, PROJECT_PLAN, CAPABILITIES, CHANGES, demo). Then the
  interface phase (merged 2026-09-06): spec 4
  alarm-stream contract as engine type, both sealed gates
  reproduced bit-for-bit, all seven primitives + alarm-stream types
  wired to the DSL/daemon/MCP, WAL opcodes 0x20–0x2B, snapshot v7.

## Next (in dependency order)

1. **Spec 4 — alarm-stream contract as engine type.** The interface
   between hearing and dispatch; corruption models compose on the read
   side only. Gate: reproduce the successor court's sealed records
   bit-for-bit through the new type.
2. **Spec 8 — waveform mouth — DONE 2026-09-10** (branch
   `dag/spec8-mouth`, merged 2026-09-10). `WaveBank`: generation W = Φ·C
   is one `cblas_sgemm` call; fit is LAPACK `dgelsd` (SVD); the bank
   declares its own rank/condition number at creation. Gate: G1–G5, G7
   hold, G6/G8(a) printed — engine out-of-bank residual mean 0.981743
   on the repaired (K=144) bank against the law 0.982265, reported by
   the engine itself, never hidden. Contract:
   `docs/contracts/SPEC8_MOUTH_GATES_FROZEN.md`.
3. **DSL/daemon exposure of the twin primitives.** Today they are
   library types with tests; the twin needs them over the socket.
   Gate: every primitive reachable by one daemon command with a
   round-trip test.
4. **Startup snapshot load before WAL replay — DONE 2026-09-09**
   (opt-in `DAGDB_STARTUP_LOAD`; `DagDBStartup.recover`; autosave now
   checkpoints the WAL). Gate met: socket smoke 23/23 including the
   restart step; `StartupRecoveryTests` 7/7. Open: the prod plist does
   not set the var yet.
5. **Fold API — DONE 2026-09-10** (branch `dag/fold-api`, built on
   `dag/spec8-mouth`, merged 2026-09-10). E3Ladder promoted from runner
   to library call, `LadderFold.run(object:schedule:sources:)`, and a
   daemon verb, `FOLD RUN/KEPT/SOURCE/TIER/INFO`, arithmetic
   unchanged. Gate met: F1–F4 bit-for-bit against the E3v3 runner's
   frozen objects, F5 price printed. Contract:
   `docs/contracts/FOLD_API_GATES_FROZEN.md`.
6. **Spec 6, second half — per-path kernel storage — DONE 2026-09-10**
   (branch `dag/kernels`, built on `main`, merged 2026-09-10). `KernelPair`
   stores per-path kernels by reference (path + sha256), a per-pair
   warmup declared or derived from τ_A/τ_B/σ_source; `SealedCrossConvolution`
   is the W1 court's own frozen residual R (window [warmup, n), one-sided
   denominator, float64 end to end), reached over the socket as
   `XCONV SEALED`. Gate: K1' (the standing relative bound) holds on all
   190 sealed W1 trials; K2 reproduces every court line (G0–G3) exactly;
   K3 storage/reach; K4 warmup = 185 for W1. Contract:
   `docs/contracts/KERNELS_GATES_FROZEN.md`. **Deprecation, in the same
   change:** the pre-existing `XCONV CHECK` (`CrossConvolutionCheck`,
   2026-08-30) is not the court's R — full-length window, symmetric
   denominator, Float32 — and flips 50 of 190 court gates (all true
   recordings) on the sealed records (K5). It stays wired for
   compatibility, documented as the patrol check; `XCONV SEALED` is
   spec line 6's standing cheap check from here.
7. **Alarm/attention hooks — DONE 2026-09-10** (branch `dag/hook`,
   built on `main`, merged 2026-09-10). The sealed allocator court as a
   daemon-global ticked process, `AttentionHook`: one hook = one alarm
   set + one budget layout (sealed by default) + a per-frame budget B
   + a lag Δ (3) + one of three lagged policies (allocator, greedy,
   uniform — the oracle has no lag, stays a court arm) + an optional
   master clock; one step advances the frame counter by one, reads the
   lagged source, books a purchase under the court's own arithmetic,
   and appends one derived ledger row. Bound to a clock, one CLOCK
   ADVANCE tick is one hook step, applied after that tick's gears — no
   batch call. Gate: `hook.result == AllocatorCourt.run(...)[policy]`
   bit for bit at all 5 sealed budget points × 3 policies (H1); the
   per-frame ledger's identities hold over the 203 sealed rows (H2);
   WAL replay and snapshot restore reproduce both (H3); bound and
   unbound hooks agree, one driver only (H4); the daemon verb family
   round-trips exactly over the socket (H5). Contract:
   `docs/contracts/HOOK_GATES_FROZEN.md`. Depends on 1 and 5. The
   derived views on `dag/derived-views` (spec line 4's second view
   family, above) remain a candidate feed for this hook — reflex tied
   sets and the rung's centroid distances are the kind of per-frame
   signal a budget-spending allocator would consume — but nothing
   wires them together yet.
8. **Tiling road.** `TiledGraphRouter` from scaffold to routing;
   `TileHalo` carrying float lanes. Serves scale; routing scheme still
   open (hex hierarchy where topology permits — printed caveat).
   **Step one DONE** (2026-09-10, branch `dag/tiling`): tile files
   (`TiledGraphFiles.write`, T1), router load/evict with LRU + T4's
   torn-tile refusal (`TiledGraphRouter`), cross-tile BFS/ancestry/
   select agreeing with the single engine exactly (T2), and the daemon
   surface — `SAVE TILED`, `TILED OPEN/BFS/SELECT/STATUS/LIST/CLOSE`
   (T5) — plus the MCP/bridge wrappers. Gate contract:
   `docs/contracts/TILING_GATES_FROZEN.md` (T1–T6, amendments 1–2).
   Still open (steps 2 and beyond, explicitly not promised by the
   step-one contract): pre-fetch, ticking across tiles, the cold tier,
   thermal pauses, the 10¹¹-node run, `TILED BACKUP`; routing scheme
   itself (hex hierarchy) unchanged from before.
9. **Liver twin plugin surface.** Blocked on that twin's spec (state
   model, kernels, observables). Placeholder until it lands.
10. **Spec 9 / hex seam.** Handover of hex-attention artefacts to a
    later line when it exists; the engine hosts the nesting, that
    later line owns the cascade.

## Gates that every item passes

- A frozen contract before any number exists — object, method, floor
  of the instrument, prior work and the run's kind (claim / control /
  re-derivation), PASS criterion as a number.
- Blinded rooms; a mechanical notary; an independent hostile read.
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
