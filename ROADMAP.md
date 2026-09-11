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
| 1 | Ranked-shell state + fold ladder, per-edge fold weights persisted | **Done** | E1 weight lanes (snapshot v6), E3Ladder — 927× compression at 1e-7 over 19 folds (E3v3 court, 30/30) |
| 2 | One master clock, rational gears, no second clock | **Done** | `MasterClock.swift` + `PhaseGear`; integer-exact 6:1 ladder; tests |
| 3 | Deterministic replay, bit-for-bit slices | **Done** | `NamedStream` (PCG64, numpy state-bridge, pinned vectors) + `StreamRecord` |
| 4 | Alarm-stream contract (W2-shape records; corruption on READ side only) | **Done** (code, gated) | `AlarmRecord`/`SealedCourt`/`AlarmFixture`/`CorruptionModel`/`SuccessorCourt`/`AllocatorCourt`; both sealed gates reproduce `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md` bit-for-bit — gated on the out-of-repo `DAGDB_W2_FIXTURE`, skips (not fails) when unset; on `dag/p4-interface`, not yet merged to main |
| 5 | Per-frame budget layout (knapsack primitive) | **Done** | `BudgetLayout.swift` — claim merge, min-cost tie, lexicographic residual; tests reproduce the sealed letters |
| 6 | Cross-convolution self-test | **Done** | `CrossConvolutionCheck.swift` — pass / scream / flash; W1 identity |
| 7 | Mandatory time-domain header (t-zero law) | **Done** | `StreamHeader.swift` — seven declared quantities, arithmetic refusals |
| 8 | Waveform mouth as matmul (bank Φ, generate = Φ@C) | **Next** | measured feasibility 2.23e9 samples/s on this machine; engine hosting not built |
| 9 | LUT nesting for the attention cascade (ternary patrol → float fovea) | **Waits on Hex** | design only; the hex-attention seam; not sealed |

Seven of nine on main as of 2026-09-06 (rollback anchors
`pre-merge-twin-r3-20260905` and `pre-merge-p4-20260906`; spec 4 gated
on the out-of-repo fixture); 446 tests on main as of 2026-09-09.

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
2. **Spec 8 — waveform mouth.** Host the harmonic/Gabor bank in engine
   lanes; generation as one matrix product at memory bandwidth;
   out-of-bank residual reported, never hidden. Gate: residual ≈ 1 on a
   deliberately out-of-bank input printed by the engine itself.
3. **DSL/daemon exposure of the twin primitives.** Today they are
   library types with tests; the twin needs them over the socket.
   Gate: every primitive reachable by one daemon command with a
   round-trip test.
4. **Startup snapshot load before WAL replay — DONE 2026-09-09**
   (opt-in `DAGDB_STARTUP_LOAD`; `DagDBStartup.recover`; autosave now
   checkpoints the WAL). Gate met: socket smoke 23/23 including the
   restart step; `StartupRecoveryTests` 7/7. Open: the prod plist does
   not set the var yet.
5. **Fold API.** E3Ladder promoted from runner to library call:
   `fold(subtree, rank) → boundary operator + printed floor/price`.
   Gate: identical numbers to the E3v3 runner on the frozen objects.
6. **Alarm/attention hooks.** The sealed allocator as an engine feature:
   consume an alarm set, spend a budget against a stored tariff.
   Depends on 1 and 5.
7. **Tiling road.** `TiledGraphRouter` from scaffold to routing;
   `TileHalo` carrying float lanes. Serves scale; routing scheme still
   open (hex hierarchy where topology permits — printed caveat).
8. **Liver twin plugin surface.** Blocked on that twin's spec (state
   model, kernels, observables). Placeholder until it lands.
9. **Spec 9 / hex seam.** Handover of hex-attention artefacts to the
   hex-attention line; the engine hosts the nesting, that line owns
   the cascade.

## Gates that every item passes

- A frozen contract before any number exists — object, method, floor
  of the instrument, prior work and the run's kind (claim / control /
  re-derivation), PASS criterion as a number.
- Blinded rooms; a mechanical notary; a hostile read by the other lane.
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
