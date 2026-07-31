# ARCH — tick perf recovery

## A. Per-(rank,color) compacted dispatch (default rank path)

- New engine state: one flat `MTLBuffer` of UInt32 node ids
  (nodeCount entries) laid out as concatenated per-(rank,color)
  segments, plus a CPU-side `[(offset, count)]` table indexed by
  rank*7+color, plus `rankTopologyDirty: Bool`.
- Build: one CPU pass over rankBuf + the 7 color groups (O(N)); write
  ids into the flat buffer segment-by-segment. Runs lazily at the top
  of `tick()` when dirty; set dirty in init and expose
  `markRankTopologyDirty()` for the daemon handler (SET RANK,
  SET_RANKS_BULK, LOAD) and any engine-internal rank writes.
- Dispatch: same `dagdb_tick_rank` pipeline, same buffers, but bind
  the flat buffer at the segment offset (`setBuffer(_, offset:
  off*4, index: 5)`) with `group_size = count`, skipping empty
  segments. The kernel's `rank[node] != current_rank` check remains
  as a harmless invariant (always false-skip = never skips).
- Ranks > 0 nodes only where present: segments empty for unused
  (rank,color) pairs → encoder count drops from 112 to
  (#non-empty pairs).

## B. TICK_SYNC (opt-in synchronous mode)

- New kernel `dagdb_tick_sync(truth_in, truth_out, lut_lo, lut_hi,
  neighbors, is_register, node_count)`: for every node — registers
  copy their own previous value (`truth_out[i] = truth_in[i]`),
  others gather 6 neighbor bits FROM `truth_in` and write
  `eval_lut6` to `truth_out`. One dispatch over nodeCount.
- Added to BOTH `Shaders/dagdb.metal` and the embedded
  `metalShaderSource` fallback string (they must stay in sync — the
  bundle path is primary, source path is the fallback).
- Engine: `truthStateBuf` becomes `public private(set) var`; allocate
  `truthStateBuf2` (same size) at init; `tickSync(tickNumber:)`
  dispatches, swaps the two buffer references, then runs the existing
  `latchBackEdges()` (register semantics identical to rank mode:
  latch reads post-pass source values).
- All external reads (readTruthStates, handler shm export, snapshot)
  go through the property — swap-safe by construction; a test locks
  this (write via sync tick, read via readTruthStates).
- DSL: `TICK_SYNC <n>` verb (parser + handler), additive.

## Failure surfaces → catching test

- Segment table stale after rank mutation → C2 test mutates ranks all
  three ways and compares against a fresh engine.
- Offset arithmetic (byte vs element) in setBuffer → C1 bit-for-bit
  vs legacy on random graphs would fail on any misalignment.
- Embedded-source drift (bundle vs string) → test compiles the
  embedded string explicitly and asserts `dagdb_tick_sync` exists.
- Buffer-swap aliasing (external code caching the old MTLBuffer
  reference) → repo grep for direct `truthStateBuf` captures + the
  property-read test; handler writes truth via engine property only.
- Registers in sync mode double-latching (kernel copy + latch phase)
  → C3's CPU reference implements exactly kernel-copy-then-latch;
  any double-apply diverges on the toggle circuit within 2 ticks.
- Legacy path rot (kept only for tests) → `tickLegacy` is
  `@_spi(Testing)`-style internal, exercised by C1/C2 every suite run.
