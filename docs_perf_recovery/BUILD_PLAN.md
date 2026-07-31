# BUILD_PLAN — tick perf recovery (branch dag/tick-perf)

## Step 1 — compaction (engine only)
Files: `DagDBEngine.swift` (segment table + flat buffer + dirty flag +
rebuild + new dispatch loop; legacy loop preserved as `tickLegacy`).
**Test:** new `DagDBTickPerfTests.testCompactedEqualsLegacyRandom` —
20 seeded random graphs (random ranks 0..15, LUTs, ≤6-fan-in edges
honoring rank order, some back-edges), 8 ticks each, truth states
bit-for-bit equal. Existing 192 suite green (compacted is default).

## Step 2 — invalidation
Files: `DagDBEngine.swift` (`markRankTopologyDirty`),
`DagDBCommandHandler.swift` (SET RANK / SET_RANKS_BULK / LOAD call it).
**Test:** `testRankMutationInvalidatesCompaction` — tick, mutate ranks
directly in rankBuf + mark dirty, tick; equals fresh-engine result.
Handler-level: SET RANK via handler then TICK matches expected truth.

## Step 3 — TICK_SYNC kernel + engine mode
Files: `Shaders/dagdb.metal`, embedded `metalShaderSource`,
`DagDBEngine.swift` (`truthStateBuf2`, `tickSync`).
**Test:** `testSyncEqualsCPUReference` — seeded random graphs incl.
registers, 10 ticks, bit-for-bit vs CPU double-buffer reference.
`testSyncDiffersFromRankOnChain` — depth-5 chain: rank TICK settles in
1, sync needs 5 (asserted inequality then equality at tick 5).
`testEmbeddedShaderCarriesSyncKernel` — compile the fallback string,
assert function present. `testReadThroughPropertyAfterSwap`.

## Step 4 — DSL verb
Files: `DSLParser.swift` (+ case), `DagDBCommandHandler.swift`.
**Test:** handler-level `TICK_SYNC 3` on the toggle register circuit →
counter advances 3; `TICK_SYNC` bad-arg → ERROR.

## Step 5 — benchmark (the honest receipt)
Files: `DagDBTickPerfTests.swift` (`testBenchmarkTickModes1M`).
1024×1024, two rank layouts (3-rank legacy shape; 16-rank spread =
worst-case early-out waste), 10 ticks per mode, print ms/tick + GCUPS
for legacy / compacted / sync.
**Test criterion:** correctness assertions only (modes produce
self-consistent states); numbers are printed + recorded, not asserted.

## Step 6 — results + docs + merge prep
results.md with the measured table + scope honesty; wiki Benchmarks
row; journal. Full suite green; commit sequence per step.

Gate: 14 free gates on SPEC+ARCH (run before Step 1).
