# Twin primitives demo

A runnable walk through the seven twin-spec primitives in `DagDB`
(`NamedStream`, `StreamHeader`, `StreamRecord`, `GearedRings`,
`MasterClock`/`PhaseGear`, `CrossConvolutionCheck`, `BudgetLayout`) plus,
as of the interface phase (2026-09-06), the sealed alarm-stream court
types (`SealedCourt`, `AlarmFixture`, `AllocatorCourt` — twin spec line 4)
and a Codable restart round-trip.

Source: `dagdb/Sources/TwinDemo/main.swift`. It calls each primitive's public
API exactly as `dagdb/Tests/DagDBTests/*` does — same seeds, same fixtures —
and prints what happened. Nothing below is invented; it is the actual
program output, pasted verbatim, from a run with `DAGDB_W2_FIXTURE` set to
the real sealed fixture (2026-09-06).

## How to run

```
cd dagdb
swift build -c release --product dagdb-twin-demo
swift run -c release dagdb-twin-demo
```

### Live socket smoke (startup recovery)

```
examples/twin_primitives/socket_smoke.sh
```

Builds the release daemon, runs it on a scratch data root under
`~/dag_databases/test/` with `DAGDB_WAL`, `DAGDB_AUTOSAVE` and
`DAGDB_STARTUP_LOAD` set, and checks 23 things on the wire: `SAVE`, hard
kill, restart with no `LOAD` (stream state byte-identical, `fires=4285`,
truth back, 0 records replayed); graceful stop (autosave + checkpoint)
then restart; a tail then a hard kill (exactly the tail replayed);
corrupt and out-of-root snapshots exit 2. Refuses to run while any
`dagdb-daemon` is alive, because every daemon shares one shm backing
file. Result 2026-09-09: `pass=23 fail=0`.

Steps [1]–[9] need nothing beyond the build. Step [10] (the sealed gate-1
grid) needs the real, SHA-pinned, out-of-repo W2 fixture:

```
DAGDB_W2_FIXTURE=/path/to/w2_records.json swift run -c release dagdb-twin-demo
```

Without the environment variable, step [10] prints a skip reason instead of
the grid — see `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md` for the fixture's SHA-256
pin and where it lives. Runtime is well under a second once built either
way (all steps here are pure, in-memory arithmetic — no GPU, no daemon; step
[10] reads one 29 MB JSON file).

## What you are looking at

**[1] NamedStream.** Two independent `NamedStream` generators are seeded
with the identical PCG64 state (the same numpy reference vector the test
suite pins). Their first four draws are printed side by side and asserted
equal — the point being that the generator is a pure function of its seed
state, so a fixture printed once on the python side reproduces bit-for-bit
on the Swift side.

**[2] StreamHeader.** A `StreamHeader` models seven declared quantities
(signal band, τ-window, comb rate, first echo, record window, step, clock
floor) and refuses to be admissible if they're inconsistent. The demo shows
one admissible header (the sealed W1-like regime: 1.5 kHz band, 3 kHz comb,
0.6827 s window), then three of the four probe deaths the type exists to
catch: a signal band dropped so its period exceeds the τ-window (reads as a
constant), a comb rate dropped below twice the signal band (aliasing), and
an echo moved earlier than the record window closes (a dirty frame). Each
refusal prints the violation's own description.

**[3] StreamRecord.** A `StreamRecord` binds an admissible header to a named
generator and records slices, each capturing the generator's state *at
entry*. The demo records three slices, then replays the middle one from
nothing but its stored entry state — reseeding a fresh generator from those
words and redrawing. The replayed payload is printed next to the stored
payload and asserted bit-for-bit equal; `verify()` is also called over the
whole record and its empty failure list is printed.

**[4] GearedRings.** A six-ringed gear-6 odometer (32 cells/ring in the
sealed shape; the demo uses a smaller 4-ring/8-cell shape for a short run)
records 1500 ticks of near-silent alternating noise with one signed spike
(value 7.5) planted at tick 250. `recall(lag:)` is called for the exact lag
back to that tick; the demo prints the recalled value, the exact tick it
happened, and which ring resolved it, and asserts the value and tick match
the plant exactly.

**[5] MasterClock + PhaseGear.** Four `PhaseGear`s are driven off one
`MasterClock` with ratios 1/1, 1/6, 1/36, 1/216 — a 6:1 ladder. After 2160
master ticks, each gear's fire count is printed next to
`floor(N × p / q)`; the demo asserts they match exactly, i.e. the phase
accumulator produces integer fire counts with no drift.

**[6] CrossConvolutionCheck.** A common source signal is pushed through two
path kernels (A and B) to make two synthetic "ears." The identity under
test is `kB ⋆ a == kA ⋆ b`: pushing recording A through ear B's kernel must
equal pushing recording B through ear A's kernel, for any genuine
common-source pair. The demo prints three residuals: the true pair (passes,
residual at the Float32 storage floor — a "pass"), ear B replaced with
unrelated noise (residual near 1 — a "scream," a forged recording), and
kernel B scaled by 1.2x (a middling residual — a "flash," a corrupted path
model, distinct from a full scream).

**[7] BudgetLayout.** One frame's cost table (4 pockets × 8 tiers, the
sealed court numbers) is used for two small allocations. The first plants
two claims in pocket 0 and one in pocket 3: the two pocket-0 claims *merge*
into a single purchase (their read values add, one purchase price is paid),
and that merged value of 2 beats pocket 3's lone value of 1, even though
pocket 3 is cheaper — demonstrating the colocation merge rule. The second
allocation puts one claim in pocket 0 and one in pocket 3 with equal read
value (1 each) and a budget that can't afford both: the allocator picks
pocket 3, the *cheaper* purchase, demonstrating the min-cost tie-break.

**[8] NamedStream Codable round-trip.** A fresh stream draws 6 words
(mirroring `TwinCodableStreamTests.swift`'s fixture), is JSON-encoded and
decoded, and the decoded copy is asserted equal to the original. Both the
original and the decoded copy then draw one more word each; the demo prints
both and asserts they match — the property a daemon restart needs: a stream
held in `TwinState` can be reconstructed from its JSON snapshot and continue
the identical sequence, in O(1), never redrawing the words already spent.

**[9] SealedCourt legal miss.** Two claims — liar_A (sealed pocket 3) and
liar_B (sealed pocket 5), both value row L (needs tier r7) — are allocated
against `SealedCourt.makeLayout()` at budget 13491.480553724456 (the sealed
grid's P1 point). Pocket 3's r7 tariff (15138) exceeds the budget; pocket
5's r7 tariff (10952) does not. The allocator serves pocket 5 and misses
pocket 3 — not because anything is malformed about liar_A's claim, only
because it is priced out at this budget. This is the mechanism behind the
sealed gate 1 table's per-ear row at P1 (`ears=A0/17 B17/0`).

**[10] AllocatorCourt sealed gate-1 grid.** When `DAGDB_W2_FIXTURE` is set,
the demo loads the real 200-record fixture (SHA-256 verified against the
pinned hash), runs `AllocatorCourt.runGrid`, and prints the allocator arm's
misses/served/cost at each of the five sealed budget-grid points — the
same numbers frozen in `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md`'s gate 1 table.
When the variable is unset, it prints the skip reason instead of guessing.

## Expected output

```
=== [1] NamedStream: deterministic draws ===
stream A, first 4 draws (seed 0x853c49e6..da3e39cb):
  0x742924eb84751ccd
  0x20d6bcdf1e644368
  0xfd2027823296dda3
  0x0ab11e1c7b578eed
stream B, same seed, first 4 draws:
  0x742924eb84751ccd
  0x20d6bcdf1e644368
  0xfd2027823296dda3
  0x0ab11e1c7b578eed
A == B: true  (identical seeds, identical sequence, verified by equality assert)

=== [2] StreamHeader: t-zero admissibility and refusals ===
admissible header (1.5 kHz band, 3 kHz comb, 0.6827 s window): isAdmissible = true
refusal 1 — signal wider than window (band dropped to 1 Hz): signal period exceeds tau window (reads as constant)
refusal 2 — comb below Nyquist (comb dropped to 2000 Hz): comb rate below 2x signal band (aliasing)
refusal 3 — record outlives echo (echo moved to 0.5 s): record window reaches the first echo (dirty frame)

=== [3] StreamRecord: record and bit-exact replay from boundary state ===
recorded slice 1: 7 draws, entry draw index 5
stored payload:  0xd3cc3d10a0f5ae56 0x0f7335761d46764a 0x7be48d99e6014011 0x81109e4bc5f7b13d 0x803dc4cb2de38b1b 0x010929bd5cf484a7 0x2caa508c2568e242
replayed payload:0xd3cc3d10a0f5ae56 0x0f7335761d46764a 0x7be48d99e6014011 0x81109e4bc5f7b13d 0x803dc4cb2de38b1b 0x010929bd5cf484a7 0x2caa508c2568e242
bit-exact equality: true
full-record verify() failing indices: []  (empty == every slice replays)

=== [4] GearedRings: signed extremum recall across lag ===
planted value 7.5 at tick 250, 1500 ticks written, recalled at lag 1250:
  value = 7.5, tick = 250, ring = 3, span length = 216

=== [5] MasterClock + PhaseGear: 6:1 ladder, exact fire counts ===
N = 2160 master ticks; ladder ratios 1/1, 1/6, 1/36, 1/216:
  band0 (1/1): fires = 2160, floor(N*p/q) = 2160, exact = true
  band1 (1/6): fires = 360, floor(N*p/q) = 360, exact = true
  band2 (1/36): fires = 60, floor(N*p/q) = 60, exact = true
  band3 (1/216): fires = 10, floor(N*p/q) = 10, exact = true

=== [6] CrossConvolutionCheck: pass, scream, flash ===
true signal (kB*a vs kA*b, same source through both ears): residual = 6.001943919247178e-08, passes(1e-6) = true
forged recording (ear B replaced with unrelated noise): residual = 0.9872788260562675  (a scream)
twisted path model (kernel B scaled 1.2x): residual = 0.16666670401869826  (a flash, not a scream)

=== [7] BudgetLayout: claim merge and the min-cost tie rule ===
merge: two claims in pocket 0 + one claim in pocket 3, budget 16164
  served pockets = [0], purchases = 1, readValue = 2, totalCost = 15138.0
  (pocket 0's two claims merged into one purchase; value 2 beats pocket 3's lone value 1)
min-cost tie: one claim each in pockets 0 and 3, budget 16164
  served pockets = [3], readValue = 1, totalCost = 5618.0
  (equal value 1 vs 1; pocket 3's cheaper purchase wins the legal tie)

=== [8] NamedStream: Codable round-trip mid-sequence ===
stream after 6 draws: name=codable-demo draws=6
decoded == original: true
next draw from original: 0x0f7335761d46764a
next draw from decoded:  0x0f7335761d46764a
(a daemon-held stream survives a restart in O(1) — restore from the boundary, never redraw)

=== [9] SealedCourt: legal miss at B=13491.480553724456 ===
claims: liar_A (sealed pocket 3) + liar_B (sealed pocket 5), budget 13491.480553724456
  served sealed pockets = [5], readValue = 1, totalCost = 10952.0
  (liar_A's pocket 3 at r7 costs 15138.0, over budget;
   liar_B's pocket 5 at r7 costs 10952.0, affordable —
   liar_A legally misses even though nothing is wrong with its claim, only its price)

=== [10] AllocatorCourt: sealed gate-1 grid (env-gated) ===
loaded 200 records (sha256 verified against the pinned sealed hash)
  B=16164.352484758914 k7=4: misses=0 served=150 cost=819218.0
  B=13491.480553724456 k7=3: misses=17 served=133 cost=561872.0
  B=11528.02214532872 k7=2: misses=17 served=133 cost=561872.0
  B=7426.473868436935 k7=1: misses=34 served=116 cost=375688.0
  B=3128.126645687496 k7=0: misses=100 served=50 cost=4900.0

=== twin demo complete: steps [1]-[10] exercised, all preconditions held ===
```

The [10] block above is from a run with `DAGDB_W2_FIXTURE` set to the real
sealed fixture; the five lines match `docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md`'s
gate 1 table exactly (misses/served/cost at each of the five budget-grid
points). Without the environment variable, step [10] instead prints:

```
=== [10] AllocatorCourt: sealed gate-1 grid (env-gated) ===
DAGDB_W2_FIXTURE not set — sealed gate-1 grid skipped (see docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md)
```

All seven twin primitives plus the sealed alarm-stream court types are
covered — none omitted.

## Socket walkthrough

The same primitives are reachable live over the daemon socket
(`docs/wiki/dsl.md`'s "Twin primitives" section has the full grammar). This
walks the `STREAM` verbs by hand — start the daemon on a scratch data root
first (do not point this at a production socket):

```
printf 'STREAM OPEN demo 0x853c49e6748fea9b 0xda3e39cb94b95bdb 0x5851f42d4c957f2d 0x14057b7ef767814f\n' | nc -U /tmp/dagdb.sock
# → OK STREAM OPEN id=s00000001 name=demo draws=0
```

Draw six words (shm holds `[u32 count][u32 8][u64 x 6]` at offset 8 —
read it with a numpy `uint64` view, offset 16 bytes past the header):

```
printf 'STREAM NEXT s00000001 6\n' | nc -U /tmp/dagdb.sock
# → OK STREAM NEXT id=s00000001 n=6 draws=6 state=0x...:0x... shm_bytes=48
```

Open the sealed budget layout and allocate against it — the same claims
step [9] above ran in-process, now over the socket:

```
printf 'BUDGET SEALED\n' | nc -U /tmp/dagdb.sock
# → OK BUDGET SEALED id=b00000001 pockets=4 tiers=8 classes=2

printf 'BUDGET ALLOCATE b00000001 13491.480553724456 0:0 2:0\n' | nc -U /tmp/dagdb.sock
# → OK BUDGET ALLOCATE id=b00000001 value=1 cost=10952.0 served=2 purchases=2:4:10952.0:1
#   (pocket index 0 = sealed pocket 3 = liar_A, pocket index 2 = sealed
#   pocket 5 = liar_B, purchase tier 4 = SealedCourt.tierIndex(7) = sealed
#   tier r7 — SealedCourt.pocketIndex/sealedPocket/tierIndex convert
#   between the daemon's zero-based indices and the sealed numbers;
#   liar_A is absent from `served`, matching step [9])
```

## Verification

`swift test` from `dagdb/` reports **446 tests, 9 skipped (fixture-gated),
0 failures** as of 2026-09-09 (main) — up from the 249/0-skip baseline at the 2026-09-05
twin-primitives merge. The 9 skips are the `SealedGateTests`/
`TwinAlarmCommandTests` cases that need `DAGDB_W2_FIXTURE` set; adding the
`dagdb-twin-demo` executable target and its `Sources/TwinDemo/` directory
does not touch any existing target and does not break
the package.
