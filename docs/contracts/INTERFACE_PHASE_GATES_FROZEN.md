# Interface-phase gate contract — FROZEN 2026-09-06 (before any gate code exists)

> Amateur engineering project; no competitive claims; errors likely.

**Kind of run:** CONTROL / RE-DERIVATION — not a claim. The engine
re-implements two courts that already sealed these numbers in Python;
a PASS proves the engine reproduces the sealed record, nothing more.

**Prior work (frozen):**
- Allocator court: its frozen contract, Python runner and sealed
  record (`court_allocator_runs.json`), judged by the other lane;
  held outside this repository.
- Successor court: its frozen contract, pre-gate script and sealed
  record (`pregate_successor_v1.json`); the corruption-model paragraph
  (2026-08-26) verbatim in that script; held outside this repository.
- Sealed stream: `w2_records.json`, 201 entries,
  SHA-256 `be5c431f8ba410c632bbb18b89bce2b93d74dfcbc7f069ea9051f44e37618303`
  (manifest `FIXTURES.sha256`, same location). Lives OUT of this repo; tests
  read it from `DAGDB_W2_FIXTURE` and skip with a printed reason if absent.

**Delta over prior work:** the derived per-frame view, the allocator
court procedure, and the successor enumeration exist as engine (Swift)
types reachable over the daemon; the Python courts are the reference.

**Instrument floor:** integer counts and exact dyadic weights; gate 2
Doubles are compared with exact equality because the enumeration is a
finite sum of dyadic products in a fixed order (§0.10); no tolerance.


## AMENDMENT 1 — 2026-09-06, independent hostile read (pre-gate; no number moved)

Rulings applied verbatim before any gate code exists:
- **15 AMENDED:** restore path keeps drop-with-WARN; **gate path: fixture
  absent → XCTSkip with printed reason; fixture present with hash ≠ pinned
  → FAIL printed as a finding, never skip, never warn.** A changed seal is
  the one event the gate exists to catch.
- **1 (witness):** the reviewer checked the sealed file that day: inside every block the
  file order IS the numeric-suffix order, all 200 — closes the gap the
  key-name reconstruction depends on.
- **5 (reason corrected):** the letter's frame-level burst phrase, taken
  literally on one-alarm frames, would count every non-quiet frame (150);
  the sealed number is 116 = liar_C 16 + deep 50 + drift 50 = pocket 6, the
  letter's own parenthesis. The frame-level phrase is NOT to be
  implemented; the code comment must say so.
- **8 (reason corrected):** pocket-6 r7 affordability is necessary, not
  sufficient. Partial tiers never win here because a mixed (D,L) pattern
  occurs only at pocket 6 under a true deep claim; every other pocket then
  holds ≤ 1 claim; the one-slot fact makes 6@r7 + X@r7 infeasible; the best
  partial combo 6@r4 + X@r7 ties 6@r7 on value 2 and loses on cost
  (1458 + ≥ 10952 > 5618). The measurement room used no partial tiers and matched all 160
  body cells at zero difference.
- **9 (addition):** on this object no two distinct feasible served sets tie
  on (value, cost) at all — purchasable shapes are one r7 pocket, 6@r4, or
  6@r4 plus one r7 pocket, all cost sums distinct. The tie-break is
  **unexercised**; a passing gate is never evidence for lexSmaller.
- **10 (source of exactness corrected):** on the dyadic five every
  intermediate is an exact dyadic rational inside 53 bits (phantom weight
  denominator ≤ 2^16, branch weight ≤ 2^3, cost < 2^21), so any summation
  order gives the same Double; mirroring the Python loops is harmless, not
  load-bearing. Over the 65-point lattice that bound breaks (q = i/256) —
  gate 2 stays on the five; the 65-point weight-sum anchor is exact
  because it carries no cost factor. Feasibility test mirrored:
  `total_cost > B + 1e-9` (harmless: cost sums are integers, every B ≥ 0.02
  from an integer).
- **Scoring named:** the gate-2 diagonal column (83.3047 / 82.4062 /
  82.4062 / 83.5) is **retention scoring** — served = the bought tier holds
  the TRUE culprit in its true pocket; coincidental rescue counts; "a
  phantom purchase serves no one" is narrowed to "a phantom is never a
  judged alarm". The measurement room's no-rescue numbers (100 at every point) are NOT a
  target.
- 4: ear stays nil for drift; pocket 6 comes from the map key
  `drift_deeper_endpoint_C`; no derived label stored on a sealed type.
- 7: quiet has no class index; never mint one.
- READ class lives on the outcome, never on the sealed record.

**PASS criterion:** every number in the two tables below reproduced
exactly; any deviation = FAIL (a finding), never a moved threshold.

## §0 Conventions adopted (sealed-record ambiguities, resolved here; sent out for an independent hostile read before any gate code)

1. **File order.** Swift `Dictionary` decoding loses JSON key order; the court relies on file order. Order is reconstructed from key names `(<block rank quiet<liar<deep<drift>, <numeric suffix>)`, 1-based `idx`. The court's `record_block_order_ok` self-check proves file order equals block order; the loader's `sealedStops()` asserts the key set is exactly `{quiet,liar,deep,drift}_1..50 + cal0_1`.
2. **cal0.** `cal0_1` is kept as `AlarmFixture.control`, never an `AlarmRecord`; `records.count == 200`.
3. **Quiet.** `AlarmRecord.claim == nil`. A quiet-sourced judged frame buys nothing for allocator/greedy/oracle; uniform still pays 472.
4. **Drift.** `ear == nil`, pocket 6, value row L, label `"drift"`.
5. **Burst.** Alarm-level: `isBurst == (pocket == 6)`. Frame-level equals alarm-level in the allocator court (one alarm per frame); the successor object defines no burst metric.
6. **Phantoms** are `SealedClaim` values only (`pocket`, `row: .L`, `isPhantom: true`); never an `AlarmRecord`.
7. **Index collision.** Sealed ids stay on `AlarmRecord`/`SealedClaim` (pockets 3..6, tiers r3..r10). `SealedCourt` converts: `pocketIndex(p) = p − 3`, `tierIndex(r) = r − 3`, class index by value row `L → 0` (minTier 4 = r7), `D → 1` (minTier 1 = r4). `BudgetLayoutTests.swift` untouched.
8. **Merge rule vs successor partial-tier options** coincide on the sealed grid because pocket-6 r7 (5618) is affordable at every non-cut point (min B 7426.47) and the cheapest r7 pair (16570) exceeds every B. The gate pins numbers, not rule equivalence; a code comment states this.
9. **Residual tie-break.** Successor's served-tuple key and `BudgetLayout.lexSmaller` agree whenever all costs are positive (min 8).
10. **Bit-for-bit Doubles (gate 2).** Summation order mirrors the Python loops exactly: outer `true_branches` (home, other1, other2 with `OTHER_EARS` A→[B,C], B→[A,C], C→[A,B]), inner `phantom_subsets` mask 0..15 with weight product over bits i=0..3, `q = eps_n / 4.0`; per class `weightSum += w; cost += w*c; miss += w*(hit?0:1)`; totals in order liar_A, liar_B, liar_C, deep, drift, then quiet cost; `eps = Double(i)/64.0`. Tests use exact `XCTAssertEqual`, never `accuracy:`.
11. Gate 1 covers all 5 grid points; gate 2 covers the 4 non-cut points (k7=0 cut by the successor).
12. Greedy and uniform arms are court rules, not primitives; they live in `AllocatorCourt`/`SuccessorCourt` so gate and daemon share one implementation.
13. **Twin registries are daemon-global.** `READER <id> <twin verb>` permits only read verbs; mutating twin verbs return `ERROR forbidden:`.
14. **Id prefixes** (reader ids own `r`): `s` stream, `t` record, `n` rings, `c` clock, `g` gear, `b` budget layout, `a` alarm set. Format `"<letter>%08x"` from a per-registry counter; counters persist.
15. **WAL semantics.** `STREAM NEXT` logs the post-state (O(1) replay); `RECORD SLICE` logs the count; `RINGS WRITE` logs the values; `CLOCK ADVANCE` logs `n` + value. Alarm sets persist **by reference** (path + sha256); a missing/mismatched file on restore drops that entry with a stderr `WARN`, never refusing the load.
16. Fixture-dependent tests `throw XCTSkip("DAGDB_W2_FIXTURE not set — sealed gate skipped")` (precedent `DagDBTickPerfTests.swift:206`); `CURRENT_STATE.md`'s "no skips" claim is amended.


## Sealed literals (from `pregate_allocator_v2.json`, `court_allocator_runs.json`, `pregate_successor_v1.json`, held outside this repository)

- Tariff `answer_cost_flops[pocket][r3..r10]` (= 2m²): p3 `18,162,800,3872,15138,60552,253472,1051250` (m `3,9,20,44,87,174,356,725`); p4 `8,50,338,2048,12168,55112,240818,996872` (m `2,5,13,32,78,166,347,706`); p5 `18,162,722,2738,10952,46208,189728,781250` (m `3,9,19,37,74,152,308,625`); p6 `18,98,338,1458,5618,22050,85698,328050` (m `3,7,13,27,53,105,207,405`). Uniform frame cost 162+50+162+98 = 472.
- Value rows: L = 1 iff r ≥ 7; D = 1 iff r ≥ 4; quiet all 0. EAR→pocket A3 B5 C6; deep 6; drift 6. Δ=3; dummy tier 3; dominated {8,9,10}; uniform tier 4.
- Budget grid `(B, k7)`: `(16164.352484758914,4) (13491.480553724456,3) (11528.02214532872,2) (7426.473868436935,1) (3128.126645687496,0)`.
- Class counts: quiet 50, liar_A 17, liar_B 17, liar_C 16, deep 50, drift 50. Blocks: quiet 1–50, liar 51–100, deep 101–150, drift 151–200.
- **Gate 1 table** (allocator == oracle at every point): P0 misses 0 served 150 cost 819218; P1 17/133/561872; P2 17/133/561872; P3 34/116/375688; P4 100/50/4900. Greedy cost: 1095218, 903696, 903696, 764058, 229274 (misses/served as allocator). Uniform: 100/50/94400 at all points, warmup_cost_excluded 1416, per_class deep 50/0, liar 0/50, drift 0/50, burst 50/66/116. Per-ear served/missed: P0 A17/0 B17/0 C16/0; P1,P2 A0/17 B17/0 C16/0; P3 A0/17 B0/17 C16/0; P4 all missed. Burst allocator 116/0/116 at P0–P3, 50/66/116 at P4. max_spend_ratio allocator: 0.9365051903114187, 0.811771544004234, 0.9500328731097962, 0.7564828341855369, 0.03132865484685697 (greedy P4: 0.8752842548030039; uniform: 0.029200056138656998, 0.03498504097607729, 0.04094371038237982, 0.06355640757130178, 0.15088903150731112). dummy = dominated = 0 everywhere; served_trial_ids count 150.
- **Gate 2 table**, ε ∈ {0, .25, .5, .75, 1} as `misses_alloc | misses_greedy | cost_alloc`:
  - P0 m: `0,12.5,25,37.5,50 | same | 819218,817361.25,815504.5,813647.75,811791`; s: `0,12.5,25,37.5,50 | same | 819218,748993,678768,608543,538318`; n: `0,3.8014984130859375,6.769287109375,8.993637084960938,10.55859375 | 0,22.4775390625,42.2734375,59.5576171875,74.5 | 819218,1041690.066192627,1213177.9028320312,1340986.4319152832,1431884.6953125`; diag: `0,26.718769073486328,48.9779052734375,67.59994125366211,83.3046875 | 0,43.032386779785156,75.825927734375,100.32415008544922,118.1875 | 819218,1000275.4085350037,1177890.404663086,1341537.1816596985,1483686.75390625`.
  - P1 m: `17,25.25,33.5,41.75,50 | same | 561872,561907.5,561943,561978.5,562014`; s: `17,29.5,42,54.5,67 | same | 561872,491647,421422,351197,280972`; n: `17,17.99609375,18.859375,19.58984375,20.1875 | 17,39.4775390625,59.2734375,76.5576171875,91.5 | 561872,750619.064453125,909904.546875,1041813.880859375,1148432.5`; diag: `17,37.34912109375,54.90234375,69.85595703125,82.40625 | 17,56.048011779785156,85.388427734375,106.96477508544922,122.4375 | 561872,701026.6247558594,845521.25390625,988514.2438964844,1124046.25`.
  - P2 m/s: identical to P1; n misses identical to P1, cost `561872,672415.3046875,773656.21875,865594.7421875,948230.875`; diag misses identical to P1, cost `561872,614551.3134765625,680451.1640625,756379.4169921875,839143.9375`.
  - P3 m: `34,38,42,46,50 | same | 375688,377092.5,378497,379901.5,381306`; s: `34,46.5,59,71.5,84 | same | 375688,305463,235238,165013,94788`; n: `34,34,34,34,34 | 34,54.4189453125,72.2890625,87.7802734375,101.0625 | 375688,422432.5,469177,515921.5,562666`; diag: `34,49.46875,62.875,74.21875,83.5 | 34,67.37079620361328,92.302978515625,110.55953216552734,123.6328125 | 375688,357913.28125,348741.125,348171.53125,356204.5`.
  - Anchors: misses0 `[0,17,17,34]`; corner (εm=1, εs=1, εn=0) → 100.0 exactly at all four points, both policies; `max |1 − weightSum| == 0.0` over the full 65-point lattice.

---


