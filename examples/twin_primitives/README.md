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

### BANK over the socket

Spec 8's waveform mouth (branch `dag/spec8-mouth`, 2026-09-10, not yet
merged to main) — a frozen bank Φ hosted by the engine, `GENERATE` is
one matrix product, `FIT` a least-squares solve. The reply lines below
are test-log output of 2026-09-10 — `TwinBankCommandTests.swift`'s
assertions for the `OK ...` shape, id, K, and rank fields; the printed
`residual=`/`cond=`/throughput values that no test pins to an exact
number come from the same day's engine-printed run recorded in the
gate contract (`docs/contracts/SPEC8_MOUTH_GATES_FROZEN.md`, amendment
3) — not a live `nc` capture. The grammar is identical over the real
socket (`docs/wiki/dsl.md`'s "BANK" subsection).

Default `OPEN` (no numbers) opens the repaired bank, K=144, full rank:

```
printf 'BANK OPEN mouth\n' | nc -U /tmp/dagdb.sock
# → OK BANK OPEN id=w00000001 name=mouth T=4096 K=144 atoms_bytes=2359296 rank=144 cond=2.666132
```

The sealed 160-atom CONTROL bank needs its seven numbers plus `ALIASED`
— fourteen of its atoms alias above Nyquist, so it opens rank-deficient:

```
printf 'BANK OPEN mouth 4096 3000 60 32 8 6 0.02 ALIASED\n' | nc -U /tmp/dagdb.sock
# → OK BANK OPEN id=w00000001 name=mouth T=4096 K=160 atoms_bytes=2621440 rank=146 cond=5.6e+15
```

`FIT` (target waveform written to shm at offset 8 first) reports the
residual the engine actually got, not a canned number:

```
printf 'BANK FIT w00000001\n' | nc -U /tmp/dagdb.sock
# → OK BANK FIT id=w00000001 residual=<d> norm=<d> coefficients=160
```

`NOISE` prints the out-of-bank law (gate G3) beside the engine's own
measurement — 20 probes on the control bank:

```
printf 'BANK NOISE w00000001 0 20\n' | nc -U /tmp/dagdb.sock
# → OK BANK NOISE id=w00000001 n=20 expected=0.98027419633488 mean=<d> min=<d> max=<d>
```

`BENCH` is the throughput measurement (gate G6, printed, not gated):

```
printf 'BANK BENCH w00000001 1000 2\n' | nc -U /tmp/dagdb.sock
# → OK BANK BENCH id=w00000001 M=1000 reps=2 best_ms=<f> samples_per_s=<f>
```

### VIEW over the socket

Spec line 4's second view family (branch `dag/derived-views`,
2026-09-10, off `dag/spec8-mouth`, merged with `main` here) — three
alarm-set derived views (reflex, geometry-then-energy rung,
arrival-geometry ceiling) over the sealed cortex v4 world. The fixture
(`cortex_v4_world.npz`, 15,145,646 bytes) lives OUT of this repo, at
whatever path `DAGDB_CORTEX_V4_FIXTURE` names, and is sha256-pinned —
`VIEW LOAD` fails loudly (`ERROR io: sha256 mismatch: ...`) on any
hash that doesn't match, it never silently loads a different fixture.
The reply lines below are test-log output of 2026-09-10 —
`TwinViewCommandTests.swift`'s exact-line assertions for LOAD,
REFLEX (S=8 and S=2), CEILING, and the LIST/INFO/CLOSE lifecycle;
`RUNG`'s `hits=` is pinned the same way but its line is asserted as a
prefix (min_margin is a printed floor, not gated). The grammar is
identical over the real socket (`docs/wiki/dsl.md`'s "VIEW"
subsection).

```
printf 'VIEW LOAD /path/to/cortex_v4_world.npz SHA 7d732e58a4e68fc7c6357ce75346984b39aec1d71c4dccd4c76a666543890bc2\n' | nc -U /tmp/dagdb.sock
# → OK VIEW LOAD id=v00000001 train=6966 test=300 stations=8 samples=64 candidates=129 sha256=7d732e58a4e68fc7c6357ce75346984b39aec1d71c4dccd4c76a666543890bc2
```

`REFLEX` at S=8 (gate V1-V3's numbers; `near_edge` is printed only,
the V1 honest-clause floor):

```
printf 'VIEW REFLEX v00000001 8\n' | nc -U /tmp/dagdb.sock
# → OK VIEW REFLEX id=v00000001 S=8 reflex=18 oracle=65 tie_min=1 tie_median=2.0 tie_max=23 frames_with_tie=231 near_edge=<n>
```

...and at S=2, where the sparser station subset widens every tie:

```
printf 'VIEW REFLEX v00000001 2\n' | nc -U /tmp/dagdb.sock
# → OK VIEW REFLEX id=v00000001 S=2 reflex=3 oracle=233 tie_min=52 tie_median=77.0 tie_max=129 frames_with_tie=300 near_edge=<n>
```

`RUNG` resolves the reflex tied set by nearest standardized-feature
class centroid (gate V4's `hits=`):

```
printf 'VIEW RUNG v00000001 8\n' | nc -U /tmp/dagdb.sock
# → OK VIEW RUNG id=v00000001 S=8 hits=39 min_margin=<d>
```

`CEILING` reads τ alone, no frame data (gate V5's numbers, printed at
six decimals):

```
printf 'VIEW CEILING v00000001 8\n' | nc -U /tmp/dagdb.sock
# → OK VIEW CEILING id=v00000001 S=8 identifiable=35 of=129 ceiling=0.271318 exact_twin_pairs=467 unique=15 groups=20
```

`LIST`/`CLOSE` (`INFO` before close reports the same `path=`/`sha256=`
`VIEW LOAD` returned):

```
printf 'VIEW LIST\n' | nc -U /tmp/dagdb.sock
# → OK VIEW LIST count=1 v00000001

printf 'VIEW CLOSE v00000001\n' | nc -U /tmp/dagdb.sock
# → OK VIEW CLOSE id=v00000001
```

### FOLD over the socket

The E3 tier ladder (branch `dag/fold-api`, built on `dag/spec8-mouth`,
2026-09-10, merged to main 2026-09-10) — Kron/Schur fold of a rank ring
into the kept set, operator stored to Float32 between folds, solved in
Float64 via LAPACK `dgesv`, moved verbatim out of the sealed
`E3Ladder` runner into `LadderFold.run`. `FOLD` is the one twin verb
family that mints no id and writes no WAL: it folds whatever graph
currently sits in the engine's own lanes (neighbors, edge weights,
`nodeValue` as leak, rank) — a freshly booted daemon starts with the
neighbor table wiped, so this walkthrough needs those lanes populated
first (the same control object `LadderFoldTests`/`TwinFoldCommandTests`
build: side 12, `LadderFold.Objects.control`). The reply lines below
are test-log output of 2026-09-10 —
`TwinFoldCommandTests.swift`'s assertions for the `OK ...` shape,
`kept=`/`folds=`/`bytes=` fields, and the `ERROR ...` prefixes — not a
live `nc` capture; `wall_ms=` varies run to run. The grammar is
identical over the real socket (`docs/wiki/dsl.md`'s "FOLD"
subsection).

`FOLD RUN` folds the control object down from rank 6 to rank 3 (144
nodes in, 49 kept):

```
printf 'FOLD RUN 6 3 78 78\n' | nc -U /tmp/dagdb.sock
# → OK FOLD RUN kept=49 folds=3 bytes=9604 wall_ms=<f>
```

`FOLD KEPT`, `FOLD SOURCE`, and `FOLD TIER` read back from that same
result — nothing is recomputed, nothing is persisted:

```
printf 'FOLD KEPT\n' | nc -U /tmp/dagdb.sock
# → OK FOLD KEPT kept=49

printf 'FOLD SOURCE 1\n' | nc -U /tmp/dagdb.sock
# → OK FOLD SOURCE which=1 kept=49

printf 'FOLD SOURCE 3\n' | nc -U /tmp/dagdb.sock
# → OK FOLD SOURCE which=3 kept=49   (no f3 given to RUN — a zero vector)

printf 'FOLD TIER final 1\n' | nc -U /tmp/dagdb.sock
# → OK FOLD TIER level=final which=1 count=49

printf 'FOLD INFO\n' | nc -U /tmp/dagdb.sock
# → OK FOLD INFO kept=49 folds=3 tiers=final bytes=9604 wall_ms=<f>
```

Asking for `f3`'s tier when `RUN` was never given an `f3`, or for a
checkpoint level `RUN` never recorded, is `ERROR not_found`, the same
as any FOLD verb before the first `FOLD RUN`:

```
printf 'FOLD TIER final 3\n' | nc -U /tmp/dagdb.sock
# → ERROR not_found: FOLD RUN was called without f3
```

Passing `CHECK <levels>` on `RUN` snapshots mid-fold tiers too, and
`FOLD INFO` lists them in fold order, `final` last:

```
printf 'FOLD RUN 6 3 78 78 CHECK 5,4\n' | nc -U /tmp/dagdb.sock
# → OK FOLD RUN kept=49 folds=3 bytes=9604 wall_ms=<f>

printf 'FOLD INFO\n' | nc -U /tmp/dagdb.sock
# → OK FOLD INFO kept=49 folds=3 tiers=5,4,final bytes=9604 wall_ms=<f>
```

Every FOLD verb is read-only, `RUN` included, so a reader session may
run all five:

```
printf 'READER <id> FOLD RUN 6 3 78 78\n' | nc -U /tmp/dagdb.sock
# → OK FOLD RUN session=<id> kept=49 folds=3 bytes=9604 wall_ms=<f>
```

### KERNEL and XCONV SEALED over the socket

Spec line 6's second half (branch `dag/kernels`, 2026-09-10, built on
`main`, not yet merged) — per-path kernels stored by reference, and
the W1 court's own frozen cross-convolution residual R reached over
the socket as `XCONV SEALED`, distinct from the pre-existing `XCONV
CHECK` (now documented as the deprecated patrol check). The kernels
fixture (`w1_kernels.json`, 144,554 bytes) is IN-REPO at
`dagdb/Tests/Fixtures/w1_kernels.json`, sha256-pinned, always
available; the 190 W1 records it is checked against
(`w1_records.json`, 18,580,321 bytes) live OUT of this repo, at
whatever path `DAGDB_W1_RECORDS` names, also sha256-pinned. The reply
line below is `TwinKernelCommandTests.swift`'s exact-line assertion
for `KERNEL LOAD` (`testKernelLoadExactOKLine`) — not a live `nc`
capture. The grammar is identical over the real socket
(`docs/wiki/dsl.md`'s "KERNEL / XCONV SEALED" subsection).

`KERNEL LOAD` with `TAU`/`SIGMA` declared derives the W1 warmup (K4):

```
printf 'KERNEL LOAD dagdb/Tests/Fixtures/w1_kernels.json SHA 2523d3a8a4de44b56268ee31a703b6bcc6522c7c66a305651f8ec7c03e5c56b8 TAU 0.18227148035108542 0.18382585465904366 SIGMA 0.02\n' | nc -U /tmp/dagdb.sock
# → OK KERNEL LOAD id=k00000001 taps=2048 fs=3000 window=2048 ears=170/236 warmup=185 derived=1 sha256=2523d3a8a4de44b56268ee31a703b6bcc6522c7c66a305651f8ec7c03e5c56b8
```

`XCONV SEALED` (records `a`, `b` written to shm as f64 at offset 8,
`b` immediately after `a`, first) reports the sealed residual for a
loaded pair — the same Double the court's own numpy formula prints,
string-equal:

```
printf 'XCONV SEALED k00000001 2048 185\n' | nc -U /tmp/dagdb.sock
# → OK XCONV SEALED id=k00000001 n=2048 warmup=185 derived=0 residual=<R Double> compared=1863
```

`KERNEL INFO`/`LIST`/`CLOSE` round out the lifecycle:

```
printf 'KERNEL INFO k00000001\n' | nc -U /tmp/dagdb.sock
# → OK KERNEL INFO id=k00000001 path=dagdb/Tests/Fixtures/w1_kernels.json sha256=2523d3a8a4de44b56268ee31a703b6bcc6522c7c66a305651f8ec7c03e5c56b8 taps=2048 fs=3000 window=2048 ears=170/236 tau_a=0.18227148035108542 tau_b=0.18382585465904366 sigma=0.02 warmup=185 derived=1

printf 'KERNEL LIST\n' | nc -U /tmp/dagdb.sock
# → OK KERNEL LIST count=1 k00000001

printf 'KERNEL CLOSE k00000001\n' | nc -U /tmp/dagdb.sock
# → OK KERNEL CLOSE id=k00000001
```

On the 190 sealed W1 records (`DAGDB_W1_RECORDS` set), the frozen
gate contract (`docs/contracts/KERNELS_GATES_FROZEN.md`) holds: K2
reproduces every court line (worst court trial 5.415e-03, 50/50
within tolerance; fakes 50/50; perturbed 50/50, quartiles
1.019e-01/1.032e-01/1.052e-01); K1' (the standing relative bound)
holds on all 190; K5 shows the deprecated `XCONV CHECK` would flip 50
of 190 court gates — all true recordings — max |R_patrol − R_sealed|
= 23.7.

### HOOK over the socket

Roadmap item 7 (branch `dag/hook`, 2026-09-10, built on `main`, not
yet merged) — the sealed allocator court (`AllocatorCourt.run`) as a
daemon-global ticked process: instead of one batch replay call, a hook
advances one frame per `HOOK STEP`, appending one derived ledger row
each time, reproducing the court's `ArmResult` bit for bit at every
sealed budget grid point for all three lagged policies (allocator,
greedy, uniform — the oracle has no lag and stays a court arm, never a
hook policy). Bound to a clock, one `CLOCK ADVANCE` tick is exactly
one hook step, applied after that tick's gears. The reply lines below
are `TwinHookCommandTests.swift`'s exact-line assertions
(`testHookOpenSealedLayoutDefaultDeltaPolicy`,
`testSealedHookStepAllocatorRichestPoint`,
`testSealedHookStepUniformPolicyRichestPoint`,
`testHookBoundToClockRefusesStepAndMatchesUnboundOnAdvance`,
`testClockCloseCascadesToBoundHook`) — not a live `nc` capture; the
grammar is identical over the real socket (`docs/wiki/dsl.md`'s
"HOOK" subsection).

A hook needs a loaded alarm set first — the same sealed W2 records the
allocator court itself replays (200 judged records, sha256-pinned):

```
printf 'ALARM LOAD <path to w2_records.json> SHA be5c431f8ba410c632bbb18b89bce2b93d74dfcbc7f069ea9051f44e37618303\n' | nc -U /tmp/dagdb.sock
# → OK ALARM LOAD id=a00000001 records=200 control=<0|1> sha256=be5c431f8ba410c632bbb18b89bce2b93d74dfcbc7f069ea9051f44e37618303 quiet=<n> liar=<n> deep=<n> drift=<n> ears=A<n>/B<n>/C<n>
```

Opening a hook against that alarm set at the richest sealed budget
point (B = 16164.352484758914, the interface-phase gate-1 grid's richest point) and
stepping it to completion (203 = 200 judged frames + Δ 3) reproduces
the allocator court's line bit for bit:

```
printf 'HOOK OPEN a00000001 SEALED 16164.352484758914\n' | nc -U /tmp/dagdb.sock
# → OK HOOK OPEN id=h00000001 alarm=a00000001 layout=SEALED B=16164.352484758914 delta=3 policy=allocator clock=none frames=203

printf 'HOOK STEP h00000001 203\n' | nc -U /tmp/dagdb.sock
# → OK HOOK STEP id=h00000001 t=203 stepped=203 done=1 served=150 misses=0 cost=819218.0

printf 'HOOK STATE h00000001\n' | nc -U /tmp/dagdb.sock
# → OK HOOK STATE id=h00000001 t=203 done=1 served=150 misses=0 cost=819218.0 dummy=<n> dominated=<n> max_spend_ratio=<f> warmup_cost=<f> burst=<s>/<m>/<t>
```

The uniform policy pays its flat frame cost on every judged frame
(quiet sources included) instead of buying by value, at the same
budget point:

```
printf 'HOOK OPEN a00000001 SEALED 16164.352484758914 POLICY uniform\n' | nc -U /tmp/dagdb.sock
# → OK HOOK OPEN id=h00000002 alarm=a00000001 layout=SEALED B=16164.352484758914 delta=3 policy=uniform clock=none frames=203

printf 'HOOK STEP h00000002 203\n' | nc -U /tmp/dagdb.sock
# → OK HOOK STEP id=h00000002 t=203 stepped=203 done=1 served=50 misses=100 cost=94400.0
```

`HOOK LEDGER` reads back the per-frame rows the two steps above
appended — 40-byte fixed-width shm rows, DERIVED (never stored,
rebuilt by re-stepping on restore):

```
printf 'HOOK LEDGER h00000001\n' | nc -U /tmp/dagdb.sock
# → OK HOOK LEDGER id=h00000001 from=0 count=203 of=203
```

**Clock-bound variant.** A hook opened with `CLOCK <c>` steps only
when that clock advances, once per tick, after the tick's gears; it
refuses `HOOK STEP` directly so its frame counter has exactly one
driver, and a bound hook run to completion via `CLOCK ADVANCE` matches
an otherwise-identical unbound hook stepped directly, field for field
(H4):

```
printf 'CLOCK OPEN\n' | nc -U /tmp/dagdb.sock
# → OK CLOCK OPEN id=c00000001

printf 'HOOK OPEN a00000001 SEALED 16164.352484758914 CLOCK c00000001\n' | nc -U /tmp/dagdb.sock
# → OK HOOK OPEN id=h00000003 alarm=a00000001 layout=SEALED B=16164.352484758914 delta=3 policy=allocator clock=c00000001 frames=203

printf 'HOOK STEP h00000003 1\n' | nc -U /tmp/dagdb.sock
# → ERROR forbidden: bound to clock c00000001

printf 'CLOCK ADVANCE c00000001 203\n' | nc -U /tmp/dagdb.sock
# → OK CLOCK ADVANCE id=c00000001 n=203 tick=203 gears=0

printf 'HOOK STATE h00000003\n' | nc -U /tmp/dagdb.sock
# → OK HOOK STATE id=h00000003 t=203 done=1 served=150 misses=0 cost=819218.0 dummy=<n> dominated=<n> max_spend_ratio=<f> warmup_cost=<f> burst=<s>/<m>/<t>
#   (field for field the same as the unbound hook's HOOK STATE above, id aside)
```

Closing that clock cascades to every hook still bound to it, the same
way it cascades to gears, and reports the count:

```
printf 'CLOCK CLOSE c00000001\n' | nc -U /tmp/dagdb.sock
# → OK CLOCK CLOSE id=c00000001 gears_closed=0 hooks_closed=1
```

Every mutating `HOOK` verb (`OPEN`/`STEP`/`CLOSE`) is forbidden inside
a reader session; `STATE`/`LEDGER`/`INFO`/`LIST` are read-only and
permitted, same shape as every other twin family. Closing the alarm
set or budget layout a live hook depends on is refused the same way,
naming the hook — with `h00000002` closed first so `h00000001` is the
only hook left depending on `a00000001`:

```
printf 'HOOK CLOSE h00000002\n' | nc -U /tmp/dagdb.sock
# → OK HOOK CLOSE id=h00000002

printf 'ALARM CLOSE a00000001\n' | nc -U /tmp/dagdb.sock
# → ERROR forbidden: hook h00000001 depends on a00000001
```

### TILED over the socket

Tiling, step one (roadmap item 8, `docs/contracts/TILING_GATES_FROZEN.md`
T5). **Not a twin primitive** — a `TiledGraphRouter` is never
persisted, never WAL-logged, never part of a snapshot; the tile
directory `SAVE TILED` writes IS the durable state, and `TILED OPEN`
just rebuilds an in-memory view of it. Ids are `x%08x` from a
handler-local counter, not the twin registries' single-letter
prefixes.

Reply lines below are real, captured from
`TiledCommandTests.testSaveTiledSummaryLine` against the frozen
side-44 fixture object (44×44 grid, boundaries `5,11,17` → 4 tiles):

```
printf 'SAVE TILED /tmp/dagdb_tiles/g44 5,11,17\n' | nc -U /tmp/dagdb.sock
# → OK SAVE TILED dir=/tmp/dagdb_tiles/g44 tiles=4 nodes=1936 crossings=731

printf 'TILED OPEN /tmp/dagdb_tiles/g44 2\n' | nc -U /tmp/dagdb.sock
# → OK TILED OPEN id=x00000001 tiles=4 nodes=1936 resident_max=2

# globalId 0 = tile 0, local node 0 — the centre node of the frozen
# object always sorts first within tile 0 (rank 0 is the unique
# minimum). Undirected BFS at depth 6 crosses into tile 1 (loads=2).
printf 'TILED BFS x00000001 0 6\n' | nc -U /tmp/dagdb.sock
# → OK TILED BFS id=x00000001 seed=0 depth=6 back=0 count=196 loads=2 evicts=0

printf 'TILED SELECT x00000001 0 0 21\n' | nc -U /tmp/dagdb.sock
# → OK TILED SELECT id=x00000001 truth=0 lo=0 hi=21 count=601

# cumulative counters across BOTH calls above (K=2 forced one eviction
# by the time SELECT swept all 4 tiles):
printf 'TILED STATUS x00000001\n' | nc -U /tmp/dagdb.sock
# → OK TILED STATUS id=x00000001 resident=2/2 loads=4 evicts=2 refused=0 last=none

printf 'TILED LIST\n' | nc -U /tmp/dagdb.sock
# → OK TILED LIST count=1 x00000001@dir=<dir> tiles=4 nodes=1936 resident_max=2

printf 'TILED CLOSE x00000001\n' | nc -U /tmp/dagdb.sock
# → OK TILED CLOSE id=x00000001 open=0
```

`STATUS`'s own reply gains `tiled_open=<n>`, counted separately from
`twin_open=<n>`:

```
printf 'STATUS\n' | nc -U /tmp/dagdb.sock
# → OK STATUS nodes=<N> ticks=<n> gpu=<name> grid=<w>x<h> maxRank=<r> twin_open=0 tiled_open=0
```

`TILED BFS`/`SELECT`/`STATUS`/`LIST` are read-only and permitted
inside a reader session; `TILED OPEN`/`CLOSE` and `SAVE TILED` are
forbidden there (mutate the router registry or the filesystem). A torn
tile body (its `body.dags` sha256 no longer matching the manifest) is
refused, never loaded silently — the router error surfaces as `ERROR
io: ...` and the refusal is recorded in the next `TILED STATUS`'s
`refused=<n>`.

## Verification

`swift test` from `dagdb/` reports **446 tests, 9 skipped (fixture-gated),
0 failures** as of 2026-09-09 (main) — up from the 249/0-skip baseline at the 2026-09-05
twin-primitives merge. On branch `dag/spec8-mouth` (2026-09-10, not yet
merged) the spec-8 waveform mouth adds to **506 tests, same 9 skips, 0
failures**. On branch `dag/fold-api` (2026-09-10, built on
`dag/spec8-mouth`, merged to main 2026-09-10) the fold API adds to **544 tests,
10 skipped without `DAGDB_E3_RUNS` set (9 with it), 0 failures** — the
tenth skip is the out-of-repo E3 court fixture (`LadderFoldTests`'s
`testF2CourtLaddersBitForBit`), same skip-if-absent/FAIL-on-mismatch
rule as the W2 fixture below. The 9 skips are the `SealedGateTests`/
`TwinAlarmCommandTests` cases that need `DAGDB_W2_FIXTURE` set; adding the
`dagdb-twin-demo` executable target and its `Sources/TwinDemo/` directory
does not touch any existing target and does not break
the package. On branch `dag/derived-views` (2026-09-10, off
`dag/spec8-mouth`, merged with `main` here) the alarm-set derived views add to
**570 tests, 0 failures**: **32 skipped** with neither fixture env set
(the same 9 `DAGDB_W2_FIXTURE` skips, unchanged, plus 23 new
`DAGDB_CORTEX_V4_FIXTURE`-gated skips), **9 skipped** with
`DAGDB_CORTEX_V4_FIXTURE` set alone (the `DAGDB_W2_FIXTURE` skips
only — a different fixture, still unset). **Merged (this branch,
`dag/derived-views` merged with `main`, 2026-09-10): 607 tests, 0
failures — 33 skipped with neither fixture env set (the 32
derived-views skips above plus the FOLD F2 skip), 10 skipped with
`DAGDB_CORTEX_V4_FIXTURE` set alone (the 9 W2 skips plus the FOLD F2
skip).** On branch `dag/kernels` (2026-09-10, built on `main`, not
yet merged) the per-path kernel storage and sealed cross-convolution
residual (`KernelPair`, `SealedCrossConvolution`, `KERNEL` verb
family, `XCONV SEALED`) add to **655 tests, 39 skipped with neither
fixture env set** (the 33 skips above plus 5 new
`DAGDB_W1_RECORDS`-gated skips — 3 in `SealedCrossConvolutionTests`,
2 in `TwinKernelCommandTests`), **0 failures**. The in-repo kernels
fixtures (`w1_kernels.json`, `w1_residuals_v1.json`) are sha-checked
and never skip; the sealed run against the 190 out-of-repo W1
records takes ≈10 minutes in a debug build. On branch `dag/hook`
(2026-09-10, built on `main`, not yet merged) the attention hook
(`AttentionHook`, `HOOK` verb family) adds to **710 tests: 45 skipped
with neither fixture env set, 30 skipped with `DAGDB_W2_FIXTURE` set
alone**, **0 failures** — no new fixture, the two sealed hook tests
(`testSealedHookStepAllocatorRichestPoint`,
`testSealedHookStepUniformPolicyRichestPoint`) are gated on the same
`DAGDB_W2_FIXTURE` the allocator court already uses.
