# Changes

Session-by-session log. Most recent first. Humble disclaimer: amateur
engineering project, no competitive claims.

---

## 2026-09-12 — post-merge follow-up: the nine edits five branches could not make inside their own scope

Branch `main`, after the five repair branches merged (backup, daemon
bounds, core durability, subsystems α and β). Criterion:
`docs/contracts/POST_MERGE_FOLLOWUP_2026-09-12.md`. Each item was
deferred by its own branch's contract because it crossed a file another
branch owned; each is gated here on merged main.

- **F1 · `HexGrid.init(width:height:)` throws.** It used to guard with a
  `precondition`, so a grid outside the 16-bit Morton encoding or above
  the `Int32` node index space aborted the process rather than returning
  a refusal a caller could catch, and the gate had to be written against
  the separate `validated(width:height:)`. The initialiser now refuses
  by name what `validated` refused; `validated` is a thin alias over it,
  and there is no non-throwing construction path left that skips the
  check. The two-argument initialiser has 79 call sites across Sources
  and Tests, found by the compiler: 68 now take `try` directly and 11
  sit inside an expression an outer `try` already covers.
- **F2 · `BFS_DEPTHS` prints the disclosure its result carries.** The
  walk excludes BACK_EDGEs — they are tick-boundary latches, not edges
  the rank order constrains — and the library result has said so since
  the core branch. The reply now carries ` back_edges=excluded
  back_edge_count=<n>`, on the primary and reader-session forms alike.
- **F3 · `ALARM SUCCESSOR` validates its counts first.** A class label
  declared in `classSpecs` but absent from the loaded fixture's own
  counts contributed zero silently, leaving the totals short by a whole
  class. The handler calls `SuccessorCourt.validate(counts:)` at the
  door and passes the named refusal through as `ERROR out_of_range:
  missing class count <label>`; an accepted table appends
  ` missing_class_counts=<n>`.
- **F4 · `HEADER CHECK` and `RECORD OPEN` agree.** A declared clock-sync
  floor coarser than the integrator step, or one reaching the record
  window, made `RECORD OPEN` refuse while `HEADER CHECK` answered
  `admissible=1`. The check now judges the clock-sync half too and names
  it — `floorAboveStep(<floor>,<step>)`,
  `floorOutlivesRecord(<floor>,<window>)` — in the same
  `FAIL HEADER CHECK violations=<k>` line as the body violations. A
  single-clock stream declares floor 0 and is unaffected.
- **F5 · every daemon verb goes through the throwing door beside it.**
  Subsystems α could not make its seven public entry points throw
  (daemon and demo files outside its scope called them), so their
  refusals travelled as a stderr line plus a `refusal` field on an empty
  or default-valued result — which the daemon printed under an `OK`
  line. Switched, one verb at a time: `FOLD RUN` → `runChecked`,
  `BANK GENERATE` → `generateChecked`, `KERNEL LOAD`/`KERNEL INFO`/
  `XCONV SEALED` → `checkedWarmup`, the four `VIEW` read verbs →
  `checkStations`, and `BANK OPEN`/`BANK INFO` → `declarationChecked`.
  Each refusal now reaches the wire as `ERROR bad_value: <VERB>
  refused: <reason>` (the `VIEW` verbs keep their existing
  `ERROR out_of_range: S …` wording and append the library's own
  reason). Two consequences worth naming: `KERNEL LOAD` resolves the
  warmup before the id is minted and before the op reaches the WAL, so a
  refused load installs nothing — the refusal itself already came from
  the library loader as `ERROR io: bad layout: …`, so F5 changed the
  order there, not the answer, and the handler's own wording for that
  case is defence in depth; and a refused `FOLD RUN` no longer
  overwrites the stored last-fold result with an empty one.
  `declarationChecked` is the one split: its stricter clause — any bank
  whose smallest singular value sits at or below the rank threshold — is
  DISCLOSED as a new ` rank_deficient=<0|1>` field rather than refused,
  because the sealed 160-atom control bank is deliberately rank
  deficient (146 of 160) and its printed `rank=146` is a frozen gate.
  What is refused is a declaration whose LAPACK solve failed or whose
  smallest singular value is zero or non-finite — numbers that state
  nothing.
- **F6 · the daemon verifier's live scenario, gated.** `CONNECT BACK
  FROM 3 TO 5`; `CONNECT FROM 7 TO 5` refused by name; slot `5·6+0 := 7`
  installed through `SET_NEIGHBORS_BULK`, whose reply says
  `validation=skipped skipped=back_edge_register_fanin
  recheck=VALIDATE`. On the daemon branch alone `VALIDATE` had no
  register invariant — that clause is the core branch's — so the reply
  pointed the caller at a re-check that could not fire. On merged main
  it fires: `FAIL VALIDATE register invariant: node 5 is a BACK_EDGE
  destination (register) but has a combinational input at slot 0 (source
  node 7)`. Now a test, and it fails if the invariant is removed.
- **F7 · the daemon verifier's own follow-ups.** (a) The vector-writer
  test's four checks shared one shm header and read it as `0` after each
  writer, so removing ONE guard failed all four; the header is poisoned
  with a sentinel between writers instead, and removing `writeU64Vector`'s
  guard now fails exactly one check. (b) `SocketServer.handleClient`'s
  comment claimed the over-long tail was drained and discarded; the code
  never drained it. **The comment is withdrawn, the behaviour kept** —
  this server serves one command per connection and closes on return, so
  a drained tail would be thrown away by the close anyway; the tail is
  unbounded and this is the single-threaded accept loop, so draining
  would let one client hold it for as long as it kept writing; and
  `SO_NOSIGPIPE` already means a client still writing takes EPIPE on its
  own write and can still read the refusal. "A second command on the
  same connection" is not a shape this server has, so the new framing
  test drives the property that is actually at stake: the accept loop
  keeps serving after a refused over-long command. (c) `mcp_server.py`'s
  length check gained a pytest file of its own (six cases, including a
  multibyte one); removing the check fails four of them.
- **F8 · audit C findings 24–25 confirmed closed by β's tests.** Finding
  25 (a key whose `class` disagrees with its own prefix) is closed by
  `test49FixtureLoadRefusesClassPrefixMismatch`, and the duplicate-index
  consequence by `test49HookRefusesDuplicateRecordIndex`. Finding 24's
  own refusal at the loader — two distinct JSON keys reconstructing to
  one position — was **ungated**, and the comment standing beside it said
  a genuine position collision was something JSON could not express.
  That was wrong: the suffix is parsed with `Int(...)`, so `quiet_1` and
  `quiet_01` are two distinct keys at one position, each passing the
  class/prefix check. Gated now by
  `test49FixtureLoadRefusesTwoKeysAtTheSamePosition`, and the comment
  corrected.

**Also repaired, and not one of the nine:** merged `main` did not
compile. β's rank-bound fixture test called
`DagDBEngine.addBackEdgeUnchecked` and `clearBackEdges(toNode:)`
without `try`; the core branch had made both throwing (C4). Two tokens,
in β's own test file — a plain merge collision, found by the first build
of the session and named here because nothing else would have.

**S5 · the closing letter of the subsystems contract, four items.** The
blind verifier's verdict over both halves left S1 failing on one finding
and listed three more things to close before anything is pushed; all four
are closed here, on merged `main`. (i) Finding 33's own edge is reached at
last: a bank built from a legal spec has one column of its generated
matrix overwritten with NaN by the test — the production type gains no
setter, no initialiser and no debug hook for it — and `declaration()` is
taken over that matrix. Observed on this platform: Accelerate's `dgesdd_`
returns `info = 0` and hands back NaN singular values, so the branch that
fires is the non-finite one (`smallest singular value is nan … rank 0 of
6 … its condition number is not finite`), `declarationChecked` throws
with those same words, and the `info != 0` branch is recorded UNEVALUABLE
here — the test asserts whichever branch fires, so a LAPACK that does
report the failure is gated too, and the uncorrupted bank beside it still
declares rank 6 of 6 at condition 1.33. (ii) The two remaining
`precondition` traps on public paths become thrown errors: `GearedRings`'
memberwise initialiser throws `badShape` carrying the validator's own
message instead of aborting on it, and `GearRatio.init(_:over:)` and
`composed(with:)` throw a named error for a zero component, for a
numerator that can wrap the phase accumulator, and for a product that
does not fit even after cross-reducing — `GearRatio.reduced` is now
`try?` over that single door. Every call site in the sources, the demo
and the tests takes `try`; both doors are gated by driving six
out-of-range shapes and seven out-of-range ratios through them and reading
the refusals back. (iii) The six assertions the verifier found comparing
a value to itself are rewritten against a value the test derives
independently: F13's `adjacent + skipping == crossings` identity — true
by construction, since the writer computes skipping as the difference —
is replaced by a walk over the manifest's own crossings lists, classifying
each crossing by whether its remote node sits on the next tile or further
up (204/200/4 at four tiles, 351/329/22 at six, 450/416/34 at eight, all
three matching the report); F42's three lines on a local array are
replaced by re-deriving the winner, the tied set and the minimum from the
residual vector each decision carries, over both frames and two station
counts, with the tied set proved free of non-finite residuals; F33's
zero-σ block, which built a `Declaration` literal and asserted its own
fields back, is deleted and the real zero guard is reached by (i)'s NaN
bank; F23's closing line, which asserted only that a constant is 64
characters long, now measures the cortex fixture's sha256 with an outside
hasher and compares it to the pin the loader defaults to (and asserts
nothing, without skipping, when that fixture is not present); test 53's
restatement of the code's own enumeration is replaced by building the
power set of the sealed pocket list in the test and matching it mask for
mask; and test 46's field-versus-parameter comparison is replaced by
walking the hook's per-frame ledger for the frames that run before the
first judged one and the frames appended beyond the fixture's length,
with the court's declared numbers matched against that walk at five
lags. (iv) Finding 56's decode end is gated with records written byte by
byte in the test, never by the encoder: a `hookOpen` whose four-byte
`delta` slot has its top bit set, and a `hookStep` carrying the widest
u32 count. Reading the letter plainly, its window `0..<2^32` is exactly
what a u32 slot can spell, so there is no byte string for the decode end
to refuse — what it must not do is hand back something outside that
window, and what is asserted is that it does not: the slot decodes to the
positive value those bytes spell rather than a negative one, re-encodes
to the very bytes it was read from (both ends, one window), one past the
window has no four-byte spelling at all and is refused at the encode end,
and a count of 4 294 967 295 fed to a real hook steps its 153 frames and
stops instead of commanding 2^32 of them.

---

## 2026-09-12 — audit C scope β: the newer subsystems refuse by name (courts, twin WAL, clocks, streams, fixtures)

Branch `dag/subsystems-b`. Criterion:
`docs/contracts/SUBSYSTEMS_BOUNDS_GATES_FROZEN.md` over
`docs/contracts/AUDIT_C_subsystems.md` findings **45–73** and test items
**74, 77, 84** — the β half of the two-builder split (α holds the tile
files, router, npz/cortex/kernel/wave/ladder/derived-views family and
findings 1–44). One file family, one rule: *refuse or count, never
silently; name the true extent; a fix ships with a gate that reaches the
edge.* Every gate below builds its failing input by hand — a
hand-written WAL payload, a corrupted snapshot field, an out-of-range
argument — never something the writer under test produced.

### The courts

- **45 · the literal 200.** `AllocatorCourt.run` looped `1...(200 +
  delta)` and judged `srcIdx <= 200`, while `AttentionHook` derived the
  same quantity from `records.count`. On a 250-record fixture the court
  silently dropped the tail (served 115 against the hook's 165); on a
  150-record one the two happened to agree, because the court's extra
  frames resolved to no record and cost nothing. Both now read
  `records.count`, and the loop bound can no longer invert on an empty
  or shorter-than-delta fixture. **The sealed 200-record table is
  unmoved** — every arm's served/misses/cost/burst/`servedTrialIds` at
  all five budget points is identical before and after, pinned as
  literals in the new gate — and hook and court now agree bit for bit at
  150, 200 and 250 records.
- **46 · warm-up and tail frame counts.** `warmupFramesExcluded` and
  `tailFramesAppended` were `let … = 3` on every `ArmResult` while
  `delta` was a parameter. They now come from `delta`; at the sealed
  delta they still print 3.
- **47 · a pocket outside 3…6.** `cheapestValue1Tier`,
  `deepestAffordableTier`, `SuccessorCourt.allocatorDecide` and
  `greedyDecide` all took an arbitrary `Int` and then indexed
  `layout.cost` or force-unwrapped `SealedCourt.tariff[pocket]!`. All
  four traps are gone: the public front doors refuse by name
  (`CourtError.pocketOutOfRange`), and the internal replay paths — whose
  pockets come from an `AlarmRecord` and are 3, 5 or 6 by construction —
  use total variants that compute the identical numbers on a valid
  pocket.
- **48 · per-class tallies.** Optional chaining dropped the increment
  for any class or ear outside the seeded buckets while the global count
  still counted it. Both are `default:` subscripts now, and the gate
  asserts per-class totals sum to `served + misses` over 200- and
  250-record fixtures, on the court and on the hook.
- **49 · a duplicate record index.** `Dictionary(uniqueKeysWithValues:)`
  trapped on one. Per the ruling the refusal lands at the fixture door:
  `AlarmFixture.load` now refuses two entries that reconstruct to the
  same (class block, suffix) position, and a key whose `class` field
  disagrees with its own prefix — so a loaded fixture cannot carry a
  duplicate index at all. `AttentionHook.init` refuses one by name for
  hand-built arrays, and the court's index map is keep-first rather than
  trapping.
- **50 / 77 · claimed-pocket ceilings.** The successor's cartesian
  product over occupied pockets had no ceiling; it now refuses above
  `BudgetLayout.maxClaimedPockets`. `BudgetLayout.allocate`'s own
  20-pocket guard was real code with no test — a 21-pocket claim set now
  drives it, and the at-the-ceiling case still lays out.
- **51 · a class label absent from the counts.** `counts[label] ?? 0`
  contributed zero silently: with drift dropped from the table, expected
  misses went from 25.0 to 0.0 without a word.
  `SuccessorCourt.validate(counts:)` now refuses the first missing label
  by name, and `frameTotals` — whose signature is pinned by a non-β
  caller — reports the same fact in a new `missingClassCounts` field
  rather than folding it into zero.
- **52 · `allocate` never called `claimError`.** The validator written
  for exactly the two bounds `allocate` indexes on is now called first;
  a claim with pocket 99 or classIndex 7 throws instead of trapping.
- **53 · the phantom mask count.** `0..<16` over `0..<4` indexing a
  variable-length pocket list. Both come from
  `SealedCourt.pockets.count` now, as does the per-pocket probability;
  on the sealed four pockets the 16 masks and their weights are
  unchanged.

### The twin WAL, snapshot and registries

- **54 · count prefixes.** Every `u32` element count is bounded by the
  payload bytes actually remaining before anything is reserved. A
  20-byte `ringsWrite` declaring `0xFFFFFFFF` values used to reserve
  about 17 GB and then return nil; it returns nil first. The bound is a
  named helper the gate drives directly.
- **55 · a string longer than its length field.** Encode wrote a
  truncated `u16` length beside the full bytes — silent corruption for
  any path at or above 64 KiB. It refuses by name now; a string exactly
  at the field's width still round-trips.
- **56 · delta and count outside `0..<2^32`.** A negative hook `delta`
  round-tripped as 4 294 967 295 and was then added to `records.count`
  as a frame budget; a hook-step count of −5 came back as 4 294 967 291.
  Both refuse at encode. On the decode side the slot is a `u32`, so
  every decoded value is inside the window by construction — the gate
  proves the round-trip at 0, 3 and `UInt32.max`.
- **57 / 58 · bank specs.** A `bankOpen` payload with `samples = 2^63`
  trapped inside a decoder documented to return nil on anything
  malformed; it decodes to nil. Encode validates the spec before any
  non-truncating width conversion, so a negative field refuses instead
  of trapping.
- **59 · a minted id that collides.** Ids format only the low 32 bits of
  a `UInt64` counter, and the minting path had no duplicate check — past
  2^32 opens it silently overwrote a live entry. It now refuses with the
  same `duplicateId` the explicit-id path uses; the live entry survives
  with its own value.
- **60 / 84 · snapshot `formatVersion`.** Decoded and never compared. A
  version-2 snapshot would have restored the bank, view, kernel and hook
  registries *empty* and reported success. Any version but 1 is refused
  by name.
- **61 · the drop-one policy, as declared.** A missing or
  hash-mismatched alarm file drops one entry with one warning — but the
  hook pass then threw `notFound` for any hook bound to it, turning the
  documented drop into a whole-restore refusal. Such a hook is now
  dropped with its own warning. A hook naming an alarm that was never in
  the snapshot is corruption and still refuses.
- **62 · restore lands where it recorded.** Re-stepping is bounded by
  the hook's own frame count, so a snapshot recording frame 10 000
  restored silently at frame 153. Restore now asserts the rebuilt frame
  equals the recorded one and names both numbers when it does not.
- **63 · replay caps.** `recordSlice` drew and `clockAdvance` ticked
  whatever count the WAL carried — one 20-byte record could command up
  to 2^64 iterations. Both refuse above **10 000**, the same ceiling the
  daemon's own verbs use, stated once and used in both places; 10 000
  exactly still runs.

### Clocks, rings, streams, fixtures

- **64 / 65 · ring shapes.** `spanLength` accumulates a *wrapping*
  multiply, so a gear whose `gear^(rings−1)` overflows wrapped the
  coarsest span to zero and the next write divided by it.
  `shapeViolation` now bounds the gear with overflow-reporting
  arithmetic, and the memberwise initializer routes through
  `shapeViolation` instead of its own looser preconditions. The sealed
  6 × 6 × 32 shape is unaffected.
- **66 · `composed(with:)`.** It multiplied before reducing and trapped
  on overflow even when the reduced ratio was small. It cross-reduces
  first and reports overflow instead of trapping; 1/6 ∘ 1/6 is still
  1/36.
- **67 · a numerator that wraps the accumulator.** `GearRatio.reduced`
  now refuses any numerator that could carry `accumulator + num` past
  `UInt64.max`, and decode refuses the same. Before the fix a ratio of
  `UInt64.max / 2` fired 9 223 372 036 854 775 807 times on its first
  tick and **zero** on its second.
- **68 · a restored gear above its invariant.** A decoded `PhaseGear`
  with `accumulator = 100` against denominator 7 fired 14 times on its
  first tick. Decode and the state-bearing initializer both refuse it.
- **69 · draws that disagree with the slices.** A record could be built
  or decoded with a generator claiming 99 draws against slices
  accounting for 12. Slice indices, payload lengths, entry-draw chaining
  and the generator's own counter are now checked at the state-bearing
  initializer and at decode.
- **70 · slice counts.** `recordSlice(count:)` looped `0..<count` on a
  public unbounded `Int` — `-1` trapped. Negative and above-10 000
  counts refuse by name; 0 and exactly 10 000 are legal.
- **71 · the seventh t-zero quantity.** The clock sync floor was
  declared and never compared: a floor of 10⁹ seconds against a 1 ms
  step and a 1 s record window produced no violation at all. It is now
  **compared**, not documented as advisory — a declared floor must be no
  coarser than the integrator step and must sit inside the record
  window. A single-clock stream declares 0 and is untouched, which is
  every sealed fixture.
- **72 / 73 · the rank-bound fixture.** `install(into:)` left a reused
  engine's back edges, register flags, node types and analogue buffers
  in place on an object documented as a purely combinational DAG, and
  used a `precondition` — a process abort — for the size check. It now
  refuses a non-empty back-edge registry and a wrong grid size by name,
  and clears the buffers it is responsible for.
- **23 / 24 / 25, the alarm-fixture half.** These are numbered in α's
  range but live in a β file, and finding 49's ruling names them: the
  SHA pin now **defaults** to the sealed constant (passing nil is an
  explicit opt-out that says `WARN unpinned fixture` once), duplicate
  reconstructed positions are refused, and a class field disagreeing
  with its key prefix is refused.

### Test items

- **74** · the v7 empty-TWIN byte guard compared `bytesWritten` against
  a term-by-term restatement of the sum the writer builds that value
  from — the writer grading its own arithmetic. It now compares against
  the file's own size from `FileManager`, the pattern the WAL tests
  already use; the term sum is kept beside it as the layout
  documentation it always was.
- **77** · `BudgetLayout.maxClaimedPockets` gets its 21-pocket fixture.
- **84** · the snapshot `formatVersion` gets its negative fixture.

### Notes

- The sealed W2 alarm fixture (29 MB, by reference via
  `DAGDB_W2_FIXTURE`) is not present on this machine, so the sealed
  gate-1 tests skip as they always have. The S3 receipt is carried
  instead by a synthetic fixture of the sealed shape (50 quiet, 17/17/16
  liar A/B/C, 50 deep, 50 drift): the court reads only class, pocket and
  index, so it reproduces the sealed arm numbers exactly, and the gate
  pins every one of them as a literal captured *before* the repair.
- Existing reply lines are unchanged except by appended refusals; see
  `docs/wiki/dsl.md` for the three verbs that gained one and
  `docs/wiki/data-and-persistence.md` for the full list of twin WAL and
  snapshot refusals.
## 2026-09-12 — subsystems bounds, scope α: the tile files, the npz reader, the kernels, the bank, the fold, the derived views

Branch `dag/subsystems-a`. Answers the α half of
`docs/contracts/SUBSYSTEMS_BOUNDS_GATES_FROZEN.md` — audit C findings 1-44
and test items 75, 76, 78-83. The β half (findings 45-73, the courts and
the twin WAL) is a separate branch and separate files.

The contract's general letter, applied throughout: **refuse or count,
never silently; name the true extent; a fix ships with a gate that reaches
the edge.** Every new gate's failing input is built BY HAND — a
hand-assembled `.npy`, a hand-written `DAHA` header, a corrupted JSON
field, an out-of-range argument — never something the writer under test
produced, which is item 75's complaint about the old version test.

### The tile files and the router (findings 1-17)

- **Three counts, one truth (4, 5, 7, 12).** A tile's node count is
  written in three independent places — the manifest entry, `meta.json`,
  and `body.dags`'s own header field — and nothing compared them. The
  engine was sized from the MANIFEST's (an unbounded `u64` out of a JSON
  file: above `Int.max` the conversion trapped, below it an arbitrarily
  large Metal allocation preceded the body's own check), while every
  buffer bound afterwards used META's. All three must now agree, checked
  BEFORE any engine is allocated, with the refusal naming all three; a
  manifest count above the graph's `globalNodeCount` is refused without
  reading the body at all. Alongside: a crossing naming a local at or past
  the tile's own node count is refused rather than read out of bounds into
  a strip; the body's `-2` slot count per local must equal the crossings
  `meta.json` lists for that local (more slots trapped, fewer wired the
  graph wrong and left a sentinel); and `engineIndexOf` is validated for
  length and range once at router open.
- **Formats refuse versions that are not their own (1, 2, 3).** The
  rank-halo reader refused nothing, though a `badVersion` case existed for
  it; the manifest's `format`/`version` were stamped and never read back;
  the parity strip's `strip_kind` was read and returned unchecked.
- **Epochs (9, 10).** A tile epoch that would not fit `body.dags`'s 32-bit
  tick field is refused by name at flush, before the BEGIN record is
  written — it used to truncate silently at both the tick call and the
  save, and past 2^32 the body-vs-meta check would then have refused every
  subsequent load of the world. **Widening that header field to 64 bits is
  recorded as a core-format letter for a later window**, not done here. A
  `TILE_FLUSH_BEGIN` at epoch 0 is refused rather than underflowing
  recovery's `epoch - 1`.
- **A torn `flush.wal` is torn, never "clean" (11).** The file is
  unfsynced appended text and the reader returned `nil` — i.e. clean — for
  anything that was not a well-formed four-field BEGIN. A half-written
  final record, an unknown verb, and a three-field BEGIN predating the
  mode field all read as committed and the tile loaded. The last record is
  now classified clean / pending / torn, and a torn wal refuses at tile
  load and at router open.
- **The halo's provenance means what the doc says (14).** `source_tile_id`
  is documented as "the most-referenced foreign tile" and the writer
  recorded the FIRST one. It is the mode now, ties to the lowest id.
- **Counted, not lost (13).** `WriteReport.perBoundary` counts only
  crossings whose remote tile is exactly `k + 1`, while `crossings` counts
  every one — a silent undercount for any 3-ring edge that skips a tile.
  The gap is now an appended `crossingsSkippingATile`, and
  `sum(perBoundary.up) + crossingsSkippingATile == crossings` is an
  identity the gate asserts. On side 16 it is 4 crossings at 4 tiles, 22
  at 6, 34 at 8.
- **The router's own bounds (8, 15, 16, 17).** The resident-source ghost
  fast path bounds the foreign local id against the source tile's node
  count, as `truth(of:)` already did; `maxResidentTiles < 1` is refused at
  init (both load paths evict exactly one before inserting one, so at
  K <= 0 the resident set grew past K); `status()` counts the TICKING
  path's residency, high-water mark and refusals, not the query path's
  alone — a router mid-tick reported zero residency; and
  `worldTick(count:)` refuses a negative count instead of trapping.
- **The fixtures (18, 19).** `TiledFixture.populate` binds every Metal
  buffer at the GRID's size and the engine/grid pairing was "the caller's
  responsibility"; it throws on a mismatch now. `seeds(for:)` refuses an
  object whose centre it cannot address rather than trapping.

### The npz reader and the sha-pinned fixtures (findings 20-23)

- An `.npy` major version other than 1, 2 or 3 was parsed as if it were
  v2 — 0, 4 and 255 included. Both version bytes are read and refused by
  name now, and a v3 header is decoded as utf-8, as v3 declares.
- A negative shape component made the element count negative and the
  payload guard then reported a size error rather than naming the bad
  shape; a crafted shape overflowed a non-wrapping multiply and TRAPPED.
  Both are named refusals, and the byte count is overflow-reported too.
- zip64 placeholders (`0xFFFF` / `0xFFFFFFFF`) in the
  end-of-central-directory or in a central record are refused as "zip64
  not supported", named, instead of being taken at face value or surfacing
  as a generic truncation.
- **The sha pin defaults to the sealed constant.** `CortexFixture.load`
  and `KernelPair.load` applied their pin only when the caller passed one,
  while the types' own docs call the fixtures SHA-pinned. The pin is the
  default now; `nil` is an explicit opt-out that prints
  `WARN unpinned fixture` once. `KernelPair` gained the `sealedSHA256`
  constant it lacked, equal to the recorded sha of the sealed W1 file.

### The kernels and the cross-convolution (findings 26-30)

- A non-finite `fs`/τ or a non-finite or negative σ is refused at
  `KernelPair.init` — `Int(inf)`/`Int(nan)` trapped inside the derived
  warmup, and a negative σ produced a negative warmup silently. A
  non-integral or out-of-`Int` `window_samples` is refused instead of
  being truncated by `NSNumber.intValue`. A resolved warmup that leaves no
  comparison window against `window_samples` is refused at load.
- **Cross-convolution, per the contract's ruling.** The class stays,
  deprecated as it is, and becomes honest: the compared window stops at
  the RECORD's end (`min(a.count, b.count)`), never `taps − 1` samples
  into the convolution tail; `warmup >= n` is refused by name rather than
  clamped; and `Result.passes(tolerance:)` is **false** whenever
  `comparedSamples == 0`. A check that compared nothing used to report
  residual 0 and pass every tolerance.

### The bank (findings 31-35)

- **The Nyquist rule covers every atom family**, per the ruling. The
  refusal is now stated over the Gabor columns too — the highest Gabor
  centre (fs/4 by construction) plus that atom's bandwidth
  `1/(2*pi*sigma_t)` against fs/2 — with the same `ALIASED` opt-out. Both
  sealed banks stay clear of it (about 5.8 Hz of bandwidth against a
  750 Hz grid top), so the sealed fixtures still open and no printed
  number moves. The harmonic the message names is clamped into `1...H`:
  for `H*f0` exactly at Nyquist it used to name `H + 1`, an atom the bank
  does not contain.
- `declaration()` discarded LAPACK's `info` from both `dgesdd_` calls and
  divided by `sigmaMin` with no zero guard. `info` is captured and named,
  the condition number is stated as infinite rather than computed from a
  zero, and `declarationChecked()` refuses to hand back a declaration
  whose smallest singular value sits at or below the rank threshold — the
  condition number is not a usable statement about such a bank. The sealed
  CONTROL bank (deliberately rank-deficient, 146 of 160) keeps declaring
  silently.
- `generate` had no ceiling on M: `Int32(M)` trapped above 2^31 and below
  that `T * M` sized an unbounded uninitialized allocation, though `bench`
  had clamped M at 100 000 all along. That clamp is the declared ceiling
  now, refused past by name, and a coefficient count other than `K * M` is
  named rather than answered with an empty array indistinguishable from an
  empty request.

### The fold (findings 36-40)

- **A node above the schedule is refused before the first fold**, per the
  ruling. The fold loop is bounded by `schedule.maxRank`, and a node above
  it is in neither the ring nor the keep set, so it was DROPPED at the
  first fold with its row and column of the operator — silently. Both
  frozen schedules sit exactly AT the bound with zero headroom (control
  side 12 reaches rank 6 against maxRank 6; court side 44 reaches 22
  against 22); that is now a fact the gate prints, via
  `scheduleHeadroom`, not an assumption. `eliminated + kept == nodeCount`
  is asserted after every fold on the frozen object.
- An out-of-range `f1`/`f2` source index is refused (only `f3` was
  guarded, and only against negatives). Both `dgesv_` preconditions —
  which ABORTED the process on a singular operator reachable from the
  public entry point — are named refusals. A rank the engine's `u64` lane
  holds but `Int` cannot represent is refused rather than converted.
- The price table is measured, not restated: `serializedFinalOperator()`
  and `serializedTierSources(_:)` hand back the real payloads, and the
  gate stats them on disk against `finalBytes` and `Tier.bytes` instead of
  recomputing `k*k*4` — a check that could not fail.

### The derived views (findings 41-44)

- A station count above `fixture.stations` is refused by name on every
  public entry point. Above it, `tau[c*stride + s]` read silently into the
  NEXT candidate's row for every candidate but the last, and the frame
  index then trapped.
- A failed least-squares solve no longer produces a scorable residual: the
  candidate is skipped (kept out of both the minimum and the tied set) and
  COUNTED — `skipped` on the decision, `skippedTotal` on the summary.
  Pre-audit a LAPACK failure was scored from a fabricated
  `(alpha, beta) = (0, 0)` and could win the tie-break. Nothing is skipped
  on a well-posed fixture, which is the receipt that no sealed number can
  have moved by this.
- The 16-sample front window is gated as a CONTROL on a frame whose
  arrival lands within 16 samples of the end: the test recomputes the
  short-window convention independently and pins which convention this
  engine implements (zero-filled 16 samples, bins `k*fs/16`), and shows
  the two agree exactly when both windows are inside the record.
- A non-finite `k = 1/(speed * dt * os)` is refused — `CortexFixture` pins
  only FS and OS, so a zero speed or dt made every class size 1 and the
  ceiling 1.0, silently.

### Refusals that could not be a throw

`LadderFold.run`, `LadderFold.Object(engine:grid:)`, `WaveBank.generate`,
`WaveBank.declaration`, `TiledFixture.seeds`, `KernelPair.warmup` and the
`DerivedViews` entry points are all NON-throwing public functions called
from outside this branch's file set. Their refusals therefore travel the
way the contract's general letter allows in place of a throw: a named
`ERROR <subsystem>:` line carrying the value and the true extent, plus an
appended `refusal` field on the returned value — and, for callers who want
a throw, a new checked door beside each (`runChecked`, `declarationChecked`,
`generateChecked`, `checkedWarmup`, `checkStations`) together with a public
validator (`violation`, `generateViolation`, `warmupViolation`,
`stationsViolation`) that names the same message without computing
anything. Every appended field defaults, so no existing caller changes.

### Gates

Two new files, 44 tests: `SubsystemsBoundsTiledTests` (findings 1-19,
items 75, 76, 78, 81, 82) and `SubsystemsBoundsTwinTests` (findings 20-44,
items 79, 80, 83). The sealed courts in the tree are unchanged — the
kernels' residual fixture, the tiling and ticking three-way equalities and
the mouth's declaration rank all pass on their existing literals, which is
the receipt the contract's S3 gate asks for.
## 2026-09-12 — core durability: the log logs everything, and every refusal is by name

Branch `dag/core-durability`. Gate contract:
`docs/contracts/CORE_DURABILITY_GATES_FROZEN.md`, frozen before any code
from `docs/contracts/AUDIT_A_engine_core.md` (48 findings, every one
public in shipped v0.2.0). Findings 1–2, 34–40 and 45 — the two known
backup defects, the seven backup follow-ups, and the backup-test fixture
that gates finding 1 — are the backup family and are repaired on their
own branch. Ten findings, so the 38 that remain are this pass. (The
frozen contract's preamble says "six backup follow-ups"; 34 through 40
is seven. Counted, not quoted.)

**The family, in one sentence.** Forty-odd independent-looking findings
are three habits: a write that is not logged, a read that is not bounded,
and a failure that is not named. The ruling applied throughout is the
one the contract froze — **refuse or count, never silently; name the
true extent.**

### C1 · The WAL logs every mutation, and replay says what it skipped
*(findings 28, 29, 30, 31, 32, 33)*

- **WAL version 1 → 2**, with five new opcodes for the writes that
  bypassed the log against the file's own header promise: `CONNECT`
  (0x12, carrying the SLOT the daemon chose, so replay reproduces the
  table whatever state it starts from), `CLEAR_EDGES` (0x13),
  `SET_RANKS_BULK` (0x14), `SET_LUTS_BULK` (0x15),
  `SET_NEIGHBORS_BULK` (0x16). Appended BEFORE the buffer write at all
  five daemon sites. A version-1 file still replays in full; a version
  above 2 is refused by name; the appender keeps an existing file's
  declared version and refuses by name an opcode that version cannot
  describe, so a v1 log never gains a record a v1 reader would count as
  unknown.
- **`ReplayResult` gains `recordsSkipped`, `skipReasons` and
  `fileVersion`.** The histogram is bad length / out-of-range index /
  unknown opcode. Startup prints the count on every boot and the
  histogram whenever it is non-zero. A replay that applied nothing used
  to return success in silence.
- **`SET_RANK` widths are a version question.** Under version 2 the
  payload is 12 bytes or the record is torn and counted; the legacy 8-
  and 5-byte widths are accepted only under version 1, where they are
  genuine. A 12-byte record torn to 8 used to be applied as a real rank
  write.
- **A `CHECKPOINT` payload is exactly 8 bytes.** Any other width is a
  torn checkpoint: not a replay boundary, and counted. The replay window
  now starts past the checkpoint record's own measured length instead of
  a hardcoded 8, so a short checkpoint can no longer swallow the record
  that follows it.
- **`truncate` refuses while an `Appender` is open** — the decision, of
  the two the contract allowed. It renames a fresh inode over the path
  and a live appender holds an `O_APPEND` descriptor on the old one;
  reopening that descriptor would mean carrying an appender through a
  static function at every call site and would still race with a
  concurrent append between rename and reopen. A refusal has no window,
  and the daemon never needs the call — a durable snapshot writes a
  `CHECKPOINT` into the live log rather than truncating it.
- **Control gate.** A graph built through every mutating verb with the
  WAL on, the daemon discarded without `SAVE`, replayed from the log
  alone into a fresh engine: every buffer equal node for node. Before:
  rank 55 slots wrong, both LUT halves 63 wrong, the neighbour table 322
  slots wrong, six records applied out of thirteen writes.

### C2 · A SAVE that returns success can be LOADed *(3, 4, 5, 8, 11)*

- `zlibCompress` sized its destination at `input.count`; zlib expands
  incompressible input, the encode returned 0, and `save` wrote a header
  claiming a compressed body of **zero bytes**, wrote a matching SHA-256
  manifest, and returned success. It now sizes to the deflate bound and
  grows if the encoder still refuses.
- `save` refuses by name an empty compressed body and a body that does
  not decode back to exactly `nodeCount × 42`.
- `buildHeader` refuses by name any 32-bit field it cannot hold
  (`nodeCount`, `gridW`, `gridH`, `bodyBytes`) instead of trapping on the
  conversion.
- Lane-flag bits 3–7 are refused as an unknown lane. They used to be
  ignored, which mis-computed the read offset and surfaced later as an
  "ENVS magic mismatch" blaming the trailer.
- `load` calls `markRankTopologyDirty()` itself. The daemon compensated;
  the library API did not, so an embedder that loaded and then ticked
  dispatched the pre-load rank topology.

### C3 · VALIDATE covers what the engine evaluates *(9, 10)*

Adds the register invariant `DagDBState`'s doc already claimed VALIDATE
enforced (a BACK_EDGE destination with zero combinational fan-in), the
range of every back-edge index, and the agreement between the register
flag buffer and the back-edge destination list in both directions. The
rank-bound line keeps its old sentence verbatim and appends the
dispatch's own thresholds: `maxRank` alone conflated a rank the dispatch
reaches (computed — the stale-bound warning) with a rank at or above
`effectiveRankCount` (computed by nobody). The coverage is now a printed
number, not an inference.

### C4 · Public engine APIs do not read or write past their buffers
*(13, 14, 15, 16, 17, 18, 19)*

`clearBackEdges(toNode:)` and `addBackEdgeUnchecked` throw
`nodeIndexOutOfRange`; `isRegister(node:)` answers `false` for a node the
engine does not have rather than reading for it; `writeTruthStates`
refuses a short array instead of clamping and leaving the tail at its
previous values; the engine `init` refuses a `state.nodeCount` that is
not `grid.nodeCount`, which used to make every `makeBuffer(bytes:length:)`
read past the caller's arrays; the `+Graph` convenience init installs its
back edges through the checked path, which is what lets `latchBackEdges`
trust the lists on every tick. **`dagdb_tick_rank` now takes
`node_count`**, in the bundled shader and in the inline fallback both,
and treats a neighbour index at or past it exactly as `-1` — the same
guard `dagdb_reset_rank` and `dagdb_tick_sync` always had.

### C5 · Grid files are versioned and length-checked *(21, 22, 23, 24)*

`HexGrid.save` writes a `DAGG` magic and a version. `HexGrid.load`
throws `GridError` instead of returning nil, and checks all six sections
against `n`, the colour-group total, and every index each section
carries. Construction refuses by name a grid the Morton layout cannot
encode: `width ≤ 65536`, `height ≤ 32768`, `(width − 1) / 2 ≤ 32768`
(the negative cube-row fold's signed range), `width × height ≤
Int32.max`. See the deviation note at the end for why the refusal lives
in `HexGrid.validated` beside the plain initializer rather than in it.

### C6 · BFS is bounded and says what it excludes *(25, 26, 27)*

Both walks check every neighbour index against `nodeCount` — the same
bound the fanout build ten lines above already applied; the asymmetry
inside one function was the whole finding, and it was a hard array trap,
not a wrong answer. Both refuse a `nodeCount` that is not the engine's,
which was used as the `capacity:` for `bindMemory` on the engine's own
buffers. `TruthRankIndex` names the same disagreement on stderr and in
`lastRefusal` and builds over the engine's count.

**The decision: back edges are EXCLUDED, and disclosed.** `Result` gains
`backEdgesExcluded` (always true), `backEdgeCount` (how many were left
out) and `disclosure` (`back_edges=excluded`). Both walks read
`neighborsBuf`, the combinational edge table; BACK_EDGEs are
tick-boundary latches the rank order does not constrain and the engine
evaluates in a separate phase. Folding a latch into a geodesic distance
would silently change every number this API has returned since it
shipped, for the protein contact-graph work it was built for. Naming the
omission costs nothing and changes nothing.

### C7 · Reader sessions see the whole graph *(41, 42, 43)*

`open` copies all ten persisted lanes and installs the back edges
through the checked installer. It used to copy six, so every session saw
registers as ordinary combinational nodes and all weights at 1.0, and a
session on a graph with a BACK_EDGE diverged from the primary on the
first tick. The destination grid's node count must equal the primary's
or the open is refused by name — it used to be a heap overwrite. The
session id's time field is 64-bit.

### C8 · Morton export/import carry all ten lanes and the back edges
*(6, 7)*

`EXPORT MORTON` keeps the six original files unchanged and adds
`edge_weights.bin`, `activation.bin`, `node_value.bin`,
`is_register.bin` and `back_edges.bin`. `IMPORT MORTON` reads them when
present, resets what `LOAD` resets when they are not, and marks the rank
topology dirty — it used to leave the previous graph's registers
flagged, so every node at those indices was skipped by every rank tick.
`OK EXPORT bytes=` reports what was written instead of `nodeCount × 42`.

### C9 · `exportNeighborTable` refuses a seventh edge *(44)*

By name. `connect` guards the six-slot bound and `validate` reports it,
but the exporter is the path the engine's convenience init takes and that
init never calls `validate`; a seventh entry wrote `nb[idx * 6 + 6]`,
which is the next node's first slot. `exportState` gets the same guard
for the same reason on the weight lane.

### C10 · Fixtures that reach the edge *(46, 47, 48; 45 is the backup branch's)*

Hand-built v1…v6 snapshot files, byte by byte from the layout in
`DagDBSnapshot.swift`'s own header, load and reproduce a known graph —
including v1's `bodyBytes == 0` legacy fallback and the 1- and 4-byte
rank widening loops, which had no fixture at all. Hand-built legacy WAL
rank records of 5 and 8 bytes replay under version 1. A rank at or above
`nodeCount` written directly into the buffer is named by `VALIDATE` and
left out of the dispatch, with `nodes_computed` one short on the wire.
**Finding, stated rather than implied: the v1…v6 load paths were already
correct.** These fixtures found no defect; what was missing was the
fixtures, exactly as finding 46 said.

### Documented rather than changed — the UNDEFINED collapse *(20)*

`eval_lut6` returns one bit, and every tick writes 0 or 1 into
`truth_state`, while the truth state is tri-valued (`TRUTH_UNDEFINED =
2`). An UNDEFINED node is therefore collapsed to FALSE by the next tick
in both rank and sync mode; only `tickWithResonance` ever writes 2, at
the micro-tick edge, and nothing preserves it afterwards. The frozen
contract's "not promised" list rules tri-valued evaluation out of this
pass, so this is **the kernel's semantics, now written down** in the
shader beside `eval_lut6` and here — not a defect left unnamed. Changing
it means a two-bit LUT result and a truth lattice for the LUT inputs,
which is a design question and not a repair.

### Reply lines

Every existing reply line is unchanged except by appended fields:

- `FAIL VALIDATE rank bound: …` — two clauses appended (see C3).
- `OK EXPORT bytes=<b>` — same line, honest value (see C8).
- Startup: `WAL: replayed <n> records past epoch <e>` gains
  `(log v<v>, skipped=<n>)`, and a second line carries the histogram
  when anything was skipped.
- `DagDBBFS.Result` gains `backEdgesExcluded`, `backEdgeCount` and
  `disclosure`; `ReplayResult` gains `recordsSkipped`, `skipReasons`,
  `fileVersion`.

### Deviations from the contract, with reasons

1. **C1b, the `LOAD` reply.** The contract asks for `recordsSkipped` on
   "the daemon's startup line and `LOAD` reply". There is no WAL replay
   on the `LOAD` path in this tree — the only replay is startup recovery
   — so the count is printed on the startup replay line only. Printing
   it on the snapshot `LOAD` reply would attribute a number to an
   operation that did not produce it.
2. **C5, where the grid refusal lives.** `HexGrid.init(width:height:)`
   could not be made throwing: one of its call sites is in
   `DagDBBackup.swift`, which this branch must not touch (it is being
   repaired on another branch). The refusal is therefore
   `HexGrid.validated(width:height:) throws` and
   `HexGrid.refusalReason(width:height:) -> String?`, with the plain
   initializer trapping on the same named reason. When the backup branch
   lands, the initializer can be made throwing in one edit.
3. **C6, the BFS daemon reply.** The contract asks that the daemon reply
   print `back_edges=excluded`. That is a change to
   `DagDBCommandHandler.swift` beyond what C1 needs, and this branch was
   instructed to change nothing else in that file — a concurrent builder
   is working on the daemon's bounds in the same `case .bfsDepths`
   block. The disclosure is on `DagDBBFS.Result` and gated there; adding
   the field to the reply is one line whenever the two branches meet.
4. **One compile-forced edit to the handler beyond C1.** Making
   `DagDBEngine.clearBackEdges(toNode:)` throwing (C4) forces a
   `do`/`catch` at its one daemon call site. The guard above it already
   covers the case; the catch is what the signature requires, not a
   second policy.
5. **Two refusals are values, not throws.** `isRegister(node:)` answers
   `false` for a node the engine does not have, and `TruthRankIndex`
   records its refusal in `lastRefusal` and on stderr while building over
   the engine's own count. Both are called from non-throwing predicates
   on the daemon's read path, and making either throw would mean editing
   the handler beyond C1 (see 3). Both are gated.
6. **C8 takes "carry", not "refuse".** The contract offers either;
   its gate is a round-trip on a graph with registers and non-default
   lanes, which a refusal cannot pass. `is_register.bin` is written for
   external readers but not read back — the register flags are rebuilt
   from `back_edges.bin`, so the two can never disagree.
7. **C10 found no defect in the v1…v6 load paths.** The fixtures were
   what was missing. Stated here rather than quietly filed as a pass.

### C12 · the closing letter — three gates tightened after the blind verifier

The verifier passed the engine work and found three gates weaker than the
letter. AMENDMENT 2 of the contract records its verdict; this is the pass
that answers it.

- **(i) C1's control compares against values the TEST set.** It used to
  compare a replayed engine against the live engine that produced the log
  — two objects sharing the buffer layout, the opcode table and the apply
  path, so one bug could cancel another. The expectation is now literals
  and a seeded formula written down in the test and mutated alongside each
  command. It also issues **every mutating form the parser has, 16 of 16**
  (20 commands): the old control missed `CLEAR <n> BACK_EDGES` and all
  four `COMPOSE` forms. `nodeType` and `activation`, which no verb can
  write, are set NON-default through the library in the source engine, so
  asserting the replayed engine holds the defaults is a comparison that
  can fail rather than zero against zero; the reason is in the assertion
  message. Falsified: dropping `COMPOSE`'s WAL append makes the control
  fail on the `lut` lane.
- **(ii) Finding 20's collapse is tested, not only documented.** An
  UNDEFINED truth (2) becomes FALSE (0) at the next tick in rank mode and
  in sync mode, and an UNDEFINED input reads as bit 0 for a consumer's LUT
  index. The doc stays as written; it is now checked rather than trusted,
  and the day the kernel goes tri-valued this test is what says the doc
  must change with it.
- **(iii) `CONNECT BACK` logs before it applies.** The WAL header promises
  that for every mutation and this verb did the opposite, excused by a
  comment claiming `addBackEdge` is idempotent on duplicates — it is not,
  it appends a second entry. The engine's back-edge path is split into
  `validateBackEdge` (checks, mutates nothing) and
  `registerValidatedBackEdge` (applies), so the handler validates, logs,
  then applies. A refused edge writes no record; a log that refuses the
  record leaves the edge unregistered. The comment is withdrawn.
  **Gating the order:** a kill between the append and the buffer write is
  not simulable, so the gate is its consequence — an appender that refuses
  must leave the engine untouched. A real refusing appender cannot be made
  on this machine (the descriptor is opened `O_WRONLY` at init, so a later
  `chmod` does not reach it, and an unwritable path makes `init` throw), so
  `Appender` carries one internal, default-off `refuseAppendsForGate` flag,
  set by no code outside a test. Falsified: restoring apply-then-log makes
  the gate fail with the edge registered and the log empty — exactly the
  state a crash in that window used to leave.
- **The same defect is still live one verb over, and this is the only
  place that says so.** `RECORD OPEN` appends its twin-WAL record before
  `twin.apply` runs, and `twin.apply` is what refuses an inadmissible
  clock-sync floor — so a refused open leaves a record behind for an
  operation that did not happen, which is the durability statement the WAL
  header forbids, in the same direction (iii) fixed. It is not fixed here
  because it was found while gating (iii) and the fix is the same surgery
  on a different path: validate, then log, then apply, with the order
  gated by an appender that refuses. It is the first letter of the next
  window.

### Tests changed rather than added

Two assertions that pinned the whole `VALIDATE` rank-bound line
(`RankBoundTests`, `RankBoundDaemonTests`) now carry the appended
coverage clause. Four call sites gained `try` because their callee
became throwing (`DagDBTests`, `SlimeMoldPerfScoutTests`,
`TiledGraphFiles`, `DagDBEngine+Graph`). Nothing else in the existing
suite moved.

---

## 2026-09-12 — daemon bounds: refuse or count, never silently (audit B, gates D1–D10)

Branch `dag/daemon-bounds`. Answers
`docs/contracts/DAEMON_BOUNDS_GATES_FROZEN.md`, frozen before any code
from `docs/contracts/AUDIT_B_daemon.md` — 27 findings, all in the
shipped tree. Kind of run: INTERFACE throughout.

- **The family in one sentence.** Values taken from the wire were
  bounded above but not below, or not at all; the shared-memory READ
  side checked capacity and the WRITE side did not; two verbs sat on
  the reader allowlist and mutated daemon-global state; one bulk
  installer skipped an invariant nothing could re-check; the socket
  parsed a truncated prefix as a complete command; four loops ran
  unbounded on the single-threaded accept loop. The ruling applied
  everywhere: **refuse or count, never silently, and name the true
  extent in the refusal.**

- **D1 · every wire integer bounded on BOTH sides (findings 2, 3, 4, 5,
  21, 22).** `TRAVERSE FROM -1` reached `ranks[node]` and trapped; the
  five `SET` verbs, `CLEAR … EDGES` and `GET … TRUTH` reached raw
  pointer subscripts with no `>= 0` check at all — with the WAL off
  (the default) a negative id wrote BEFORE the Metal buffer and the
  daemon answered `OK SET node=-1 truth=1`. `TICK -1` built a reversed
  range and trapped. Every node id, depth, count and offset now carries
  `ERROR out_of_range: <name> <v> not in 0..<<extent>`, naming the
  value and the true extent; the counts that drive loops carry a stated
  cap in `TILED TICK`'s closed-range vocabulary — `TICK`, `TICK_SYNC`,
  `CLOCK ADVANCE` at 10,000 per command, `BANK NOISE`'s seed at
  1,000,000. `tickCount` stays `UInt32` (it is a field in the snapshot
  header and the WAL checkpoint epoch — widening it is an on-disk
  format change, not a daemon one), so a tick that would carry it past
  `4294967295` is refused by name instead of trapping on the `+= 1`.

- **D2 · every shared-memory write checks capacity (findings 6, 7, 8, 9,
  10, 20).** `writeU64Vector`, `writeFloatVector`, `writeDoubleVector`,
  `writeResults`, `writeTiledBFSRows` and `writeCorruptionOutcomes` now
  refuse with `ERROR out_of_range: result needs <bytes> bytes, shm
  holds <capacity>` before writing a byte — the read side always did
  this; the write side never did, and on a 64-byte mapping the test for
  it segfaulted. `TRAVERSE` gained a global visited set, so a node
  reachable at several depths is reported once and the row count is
  bounded by `nodeCount` (it wrote 1,846 rows into a 64-row mapping
  before). `STREAM NEXT`'s `n` and `RECORD SLICE`'s `count` are bounded
  by the real capacity rather than by a hardcoded `nodeCount * 3`
  restatement of it — the same number for a default daemon, a different
  one whenever the mapping is sized independently.

- **D3 · wire arithmetic cannot trap (finding 23).** Four byte-count
  sites (`BUDGET OPEN`'s `nPockets × nTiers × 8`, `XCONV CHECK`'s
  `(nA+nB+kA+kB) × 4`, `XCONV SEALED`'s `2 × n × 8`, `HOOK LEDGER`'s
  `from + count`) computed products and sums of unbounded signed wire
  integers, and Swift traps on `Int` overflow — so the capacity guard
  sitting right behind each of them never got to fire. All four now use
  overflow-reporting operations and refuse by name.

- **D4 · framing (findings 1, 27).** The socket did ONE 4,095-byte
  read, trimmed it, and parsed the result as a complete command: a
  5,000-byte `RINGS WRITE` was answered over the truncated prefix. The
  server now reads until the newline, completes a short read by reading
  again, and answers a line that reaches the cap without one with
  `ERROR too_long: command exceeds 4095 bytes` — never parsing it. Both
  Python clients refuse an over-long line themselves, in the same
  wording. `SocketServer` moved from the daemon executable into
  `DagDBDaemonKit` so the contract is driven over a real AF_UNIX socket
  in the suite (the socket smoke the ticking contract also owed); the
  accepted fd carries `SO_NOSIGPIPE`, so a client that hangs up
  mid-reply can no longer kill the daemon.

- **D5 · the reader allowlist is true (findings 18, 19, 24, 25).**
  `FOLD RUN` was marked read-only while it assigned the daemon-global
  last-fold result that `FOLD KEPT/SOURCE/TIER/INFO` read — a reader
  session overwrote what the primary saw, and the existing test could
  not catch it (it asserted only that the reader's own replies began
  `OK`). `FOLD RUN` is now forbidden to readers, with its own refusal
  line; the four look-only verbs stay allowed. The bridge dropped
  `OPEN_READER` (allocates a snapshot engine per call, daemon-globally)
  and `CLOSE_READER` (destroys another client's session) from its
  read-only set, and `_command_allowed` now classifies the INNER
  command of `READER <id> <cmd>` instead of passing on the verb
  `READER` alone. TILED queries stay reader-allowed — tile residency is
  a cache, not graph state — and `TILED STATUS`'s `loads=`/`evicts=`
  are documented as router-wide counters any session's query moves.

- **D6 · the bulk installers (findings 12, 13, 15).**
  `SET_NEIGHBORS_BULK` read `nodeCount × 6 × 4` bytes without ever
  consulting the mapping's real size, and range-checked no element at
  all, so any `Int32` landed in `neighborsBuf` and was indexed by the
  Metal kernel. It now checks capacity, then range-checks the WHOLE
  vector against `[-1, nodeCount)` before writing one word, naming the
  first offending slot. Both bulk installers now disclose the invariant
  they skip (`validation=skipped skipped=… recheck=VALIDATE`).

- **D7 · replies say what they omitted (findings 11, 16, 17).** `EVAL`
  carries `scope=roots` and the same `nodes_computed`/`ranks=`/`bound=`
  disclosure `TICK` prints — it ticks the whole graph and reports only
  rank-0 roots. `NODES` carries `omitted=<n>` for the rank-0/truth-0
  nodes its default filter drops (disclosed, not changed). `ALARM
  CORRUPT` carries `claims_truncated=<t>`; the row keeps its five claim
  slots, which is exactly the sealed model's widest outcome, so the
  count is 0 today — but the reply states it rather than leave it to be
  assumed.

- **D8 · unbounded work refuses (finding 26).** `SIMILAR_DECISIONS`
  runs one backward BFS per candidate over every node, with no bound
  independent of `k`, on the single-threaded accept loop — and it sits
  on the web bridge's read-only allowlist. It now refuses above a
  stated 4,096-candidate pool and points at the `AMONG TRUTH` filter.

- **D9 · the three checks that could not fail, rewritten.** The stream
  test computed its "too many" from the same expression the handler
  used for its bound, so it compared the bound to itself; the fold test
  asserted only that a reader's replies began `OK`; the tiled test
  asserted only which verbs return `OK` versus `ERROR forbidden`. All
  three now derive their expectation independently of the code under
  test. `TRAVERSE` — the verb that trapped on a negative seed and
  overran the mapping on a deep walk — had no test at all; it has one
  now.

- **Not promised, and not done:** a multi-threaded accept loop;
  per-session fold state (the reader is refused instead); reworking
  `NODES`'s default filter (disclosed, not changed). The register
  invariant in `VALIDATE` and the WAL opcodes for the new refusals
  belong to the core branch and are not in this one.

---

## 2026-09-12 — the backup chain kept half the ranks and four whole buffers were never in it

Branch `dag/backup-rank-width`. Answers
`docs/contracts/BACKUP_RANK_WIDTH_GATES_FROZEN.md` and its
`AMENDMENT 1`, both frozen before any code.

- **Defect one, as read from the source.** The engine's rank buffer has
  been 8 bytes per node since the u64 widening (`DagDBEngine.init`
  allocates `nodeCount * 8`). `DagDBBackup` still treated it as 4 in
  three places: the capture into the tip (`readEngineBuffers`), the
  rank segment of every `.diff`, and the `memcpy` back on restore — the
  comment beside the segment table read "u32 post-u32-widen
  (2026-04-20)", written the day before the widening and never
  revisited. Four bytes per node over an eight-byte-per-node buffer
  covers, by bytes, the complete ranks of nodes `0 ..< N/2` and none of
  the ranks of nodes `N/2 ..< N`. INIT, APPEND and RESTORE therefore
  kept half the graph's ranks and dropped the other half, silently, with
  `OK` on the wire — and rank is the field that orders the computation.
- **Defect two, found while freezing the first.** The diff carried six
  buffers; the snapshot carries ten plus the back edges. A graph
  restored from a backup lost every back edge (and with it every
  register, since a register is a back-edge destination), every edge
  weight, every activation and every node value. Registers and weights
  change what the tick computes.
- **The fingerprint.** Three probes on the side-8 fixture (N = 64):
  node 0, node N/2 = 32, node N−1 = 63. Ranks set, APPENDed, overwritten,
  RESTOREd. Before the fix the restore returned node 0's rank exactly
  and gave back the overwritten values for nodes 32 and 63 — the
  asymmetry is the byte arithmetic's own signature. The coverage gate
  failed, before the fix, on `isRegister`, `edgeWeights`, `activation`,
  `nodeValue` and the back-edge list, and the two engines' truth buffers
  diverged after a single rank-mode tick.
- **Format 2.** `diffVersion` 1 → 2. The rank segment is `nodeCount * 8`
  at all three sites, and the diff now carries every buffer the snapshot
  carries: rank, truth, nodeType, both LUT halves, neighbours,
  isRegister, edgeWeights, activation, nodeValue — XOR-diffed byte-wise
  — plus the back-edge section, carried whole and un-XORed per diff
  because it is variable-length. On restore the back edges go back
  through the engine's own add path, so the latch list and the register
  flags stay consistent, exactly as the snapshot loader does it. Restore
  also marks the rank topology dirty, so the next tick rebuilds its
  segment table.
- **Refusal, not silent partial restore.** A chain whose diffs carry
  version 1 is refused by name on RESTORE and on APPEND: `ERROR io:
  backup format 1 carries 4 of 8 rank bytes per node and no registers,
  back edges, weights, activation or node values; cannot restore ranks
  for nodes N/2..<N; re-create the backup`. There is no migration and
  there cannot be one — the bytes were never written. `BACKUP INFO` is
  read-only, so it names the format and repeats the sentence as a
  caveat without refusing.
- **Wire.** `OK BACKUP_RESTORE` gains `rank_bytes=<8·N>`;
  `OK BACKUP_APPEND` and `OK BACKUP_INFO` gain `format=2`; RESTORE and
  INFO both print `twin=not_covered`, because twin registries are not
  in the backup and saying so is cheaper than finding out. Existing
  fields and their order are unchanged.
- **Order, identity, integrity (amendment 2).** Five more findings in
  the same file, from an independent audit, fixed in the same pass:
  - `xor`/`xorInPlace` clamped with `min(a.count, b.count)` — the exact
    mechanism that let a 4-byte rank segment ride an 8-byte buffer
    without a word. Lengths must now agree; a disagreement is refused
    by name (`backup diff <n> segment <name> is <a> bytes, expected
    <b>`) before a byte is applied.
  - Diffs applied in filename order, so `100000.diff` would have been
    replayed before `99999.diff`. They now apply in the order of the
    sequence number in each diff's own header — the field the old code
    called "informational" — and a gap or a duplicate in that sequence
    is refused by name. APPEND writes the next number and refuses to
    overwrite a file already sitting on it.
  - Diffs carried no integrity check, while the base has had a sha256
    manifest since G73. Every diff now writes a `.sha256` sidecar and
    is verified against it before anything in it is decoded; a missing
    sidecar is refused too (unlike the base's pre-manifest case, every
    format-2 diff is written with one).
  - COMPACT wrote its new base out of the CALLER's engine and the
    CALLER's tick count. It now replays the chain into scratch, writes
    the base from that at the chain's own tick count, and does not read
    or change the live engine at all — a compaction cannot inherit a
    mutation the chain does not hold. `DagDBBackup.compact` therefore
    no longer takes an engine or a tick count.
  - Bases written by INIT and COMPACT pass `twin: nil` explicitly, to
    match what the wire says.
- **After the blind verifier (amendment 4).** Every gate passed under an
  independent reader that re-narrowed the rank segment in the source and
  watched the fingerprint come back. It left one residual, closed here:
  the back-edge section was the only segment whose length was checked
  against the file's OWN declared prefix rather than against a size
  derived from the object, and the guard was `>=` — a blob padded from
  12 bytes to 20 with the pair count left at 1, sidecar rewritten, was
  accepted silently. The section's length must now equal `4 + 8 × pair
  count` exactly, refused by name otherwise. Two fixtures hardened with
  it: the coverage gate's registers moved into the upper half of the
  buffer, its un-restored twin is now built independently from the same
  values instead of memcpy'd from the buffers under test, and the
  ordering gate renames to five and six digits as the letter says.
- **Gates.** B1 (fingerprint) and B5 (coverage, including a rank-mode
  tick that must match the un-restored engine bit for bit) recorded
  failing first, then passing. B2 gates the refusal against a
  version-1 chain written by hand in the test — no old code was kept
  to produce one. B3 repeats B1 over the DSL and pins every reply line.
  B6 (short segment), B7 (order, gap, duplicate, occupied slot), B8
  (corrupt diff, missing sidecar) and B9 (compaction source and tick
  count) were likewise recorded failing first against the committed
  code, where every one of them passed silently. B4: full suite green.

---

## 2026-09-11 — third pass: the strip's register byte becomes two bytes (ticking step two, amendment 8)

Branch `dag/ticking`. Answers `AMENDMENT 8` of
`docs/contracts/TICKING_GATES_FROZEN.md`, which accepted the second pass
and found a second instance of finding A — this time not in the ticker
but in the FILE the ticker writes.

- **The defect in one sentence.** One file, `halo_lower.<parity>.bin`,
  serves two readers. A rank-mode reader at round `k` wants a register's
  value BEFORE that round's latch; a sync-mode reader at round `k + 1`
  opens the same parity file wanting the world's vector at `k`, which is
  the value AFTER it. With a single truth byte per entry the two
  contradict each other, so a rank round followed by a sync round read a
  byte that was wrong for one of them — and a strip rebuilt from a
  committed body could not produce the pre-latch byte at all, which a
  rank-mode partial-round completion after crash-recovery case (ii) then
  reads. Neither case was gated.
- **Strip format v2 — two truth bytes per entry.** The parity strips now
  carry `truth_pre` and `truth_post` per entry: `u64 local_id + u8
  truth_pre + u8 truth_post + u8 type + 5 pad`. Header version bumped 1
  → 2, and `readLowerStripFile` refuses any other version by name.
  `truth_pre` and `truth_post` are equal for every combinational source
  (the kernel writes it during the pass; the latch never touches it) and
  differ only on registers. The entry is still **16 bytes** — the second
  truth byte came out of v1's six pad bytes — so `halo_bytes` at side 128
  × 8 tiles stays 41,328. Amendment 8 expected the entry size to change;
  it did not, and the figure is printed, not predicted. The step-one
  `halo_upper.bin` / `halo_lower.bin` snapshots (written once at tiling
  time, read by the query path, never by the ticker) stay at v1.
- **Who takes which byte.** Rank-mode ghosts take `truth_pre` from the
  source's strip at `k`; sync-mode ghosts take `truth_post` from the
  parity `k − 1` strip. The resident-buffer fast path and the
  `ghostPopulationDisabled` path (W7b's switch) agree with those choices
  byte for byte — the register pre-latch bytes are now recorded in BOTH
  modes, not rank only, so the file a sync reader opens one round later
  is correct whatever mode wrote it.
- **Regeneration reconstructs both bytes.** Recovery case (ii) and
  `regenerateStaleLowerStrip` take `truth_post` straight off the
  committed body at `k` and, for a register, `truth_pre` from that same
  source's `truth_post` in the previous-parity strip (its value at
  `k − 1` IS its pre-latch value at `k`); at `k = 0` both bytes are the
  saved truth. A register entry whose previous-parity strip is missing or
  itself behind is refused as `haloStale` rather than written with a byte
  the repair cannot justify. The second pass stated this gap as
  out-of-reach for a rank-mode reader; it was not. `SAVE TILED` writes
  both bytes equal to the saved truth in both parity strips (at rest
  there is no round, so no latch to be before or after).
- **Gate (i) — mode sequences** (`TiledModeSequenceTests`). The reference
  evaluator takes a mode SEQUENCE (`TiledReference.tick(_:mode:)` /
  `run(from:modes:)`). `rank, sync, rank, sync, …` and
  `sync, rank, rank, sync, …` over 12 rounds, three-way (tiled ==
  untiled == reference) on sides 16 / 44 / 128 at K ∈ {1, 2}, with each
  round's mode read back off its own `TILE_FLUSH_BEGIN` record on every
  tile, and the per-round change count asserted non-zero. Side 44 ×
  4 tiles, alternating: 1298 then 66 every later round. Side 44,
  `sync,rank,rank,sync` repeated: 1258, 870, 116, 66, 102, 116, 116, 66,
  102, 116, 116, 66. Discrimination checked, not assumed: with the strip
  collapsed back to one byte, every sync round that follows a rank round
  moves 6 of 1936 nodes off the reference at side 44.
- **Gate (ii) — case (ii) recovery then a rank-mode completion across a
  register.** Side 44 × 4 tiles: the register chosen from the object
  (node 25, owned by tile 3, read by node 52 in tile 2 — one reader
  below). Crash point (ii) forged on tile 3 at `k = 3` (body renamed,
  strip deleted, meta and manifest entry rolled back, dangling BEGIN),
  and every tile below it rolled back to `k − 1` with clean WALs. Writer
  open recovers the tile, regenerates both bytes (`truth_pre` = 0 = the
  register's value at `k − 1`, `truth_post` = 1 = its value at `k`),
  completes the round for the three tiles below, and the world equals the
  reference at `k` bit for bit, reader 52 included, at K = 1 and K = 2.
  Discrimination checked: with the old post-latch-only repair, 11 of 1936
  bytes differ and reader 52 is one of them.
- **Gate (iii) — finding A's reproduction re-stated on the two-byte
  format.** The committed strip's `truth_pre` is asserted to be the
  register's pre-latch byte AND `truth_post` its post-latch byte; forcing
  the rank-mode reader's byte to the post-latch value then moves 1 / 1 /
  22 nodes on sides 16 / 44 / 128, its top-rank readers among them.
- **Suite: 830 tests, 45 fixture-gated skips, 0 failures, 820 s.** W6 at
  side 128 × 8 tiles, K = 1: rank tick 5.502 ms per tile, sync 3.947;
  flush 46.414 ms rank / 42.477 ms sync per tile; halo_bytes 41,328;
  8 loads, 7 evicts per world tick, both modes.
- Docs: `docs/tiled-streaming.md` gains §4.2.1 (the parity strips and
  their two bytes, written for an independent parser) and an AMENDMENT 8
  note in §7.2; `CAPABILITIES.md`'s ticking block says which reader takes
  which byte.

---

## 2026-09-11 — second pass: main merged, the reference put back on the letter, the register latch-timing defect fixed (ticking step two, amendment 7)

Branch `dag/ticking`. Answers `AMENDMENT 7` of
`docs/contracts/TICKING_GATES_FROZEN.md`, which accepted most of the
first pass and rejected two things by name.

- **`main` merged in (`git merge main`, no rebase).** Main carries the
  rank-bound correction — `DagDBEngine` now derives
  `effectiveRankCount = max(maxRank, highestRankPresent + 1)` and
  dispatches every rank level that holds a node, instead of dropping
  everything at or above its configured bound. One conflict, in
  `CHANGES.md`: two whole session sections, kept BOTH, ordered
  2026-09-11 ticking / 2026-09-10 ticking / 2026-09-10 rank-bound /
  2026-09-10 tiling. `CURRENT_STATE.md`, `ROADMAP.md`,
  `CAPABILITIES.md`, `docs/tiled-streaming.md`, `docs/wiki/dsl.md` and
  `DagDBCommandHandler.swift` auto-merged; the handler's STATUS line
  keeps main's `ranks=`/`rank_max=`/`bound=` fields.
- **The reference carries the letter, not the engine's old bound
  (finding B).** `TiledReference` swept from the engine's last
  dispatched rank level in the first pass, because the engine on this
  branch dropped side 128's outermost ring (rank 64 = its bucket
  count). With `main` merged the engine computes that ring, so the
  reference now sweeps from the HIGHEST RANK PRESENT as amendment 6
  says, with no bound, and the three-way equality holds at side 128
  with rank 64 computed on both sides. Side 128's first rank-mode tick
  moves 11,053 of 16,384 bytes now (10,726 with the ring frozen).
- **Finding A — the register latch-timing defect, fixed instead of
  designed around.** The untiled engine evaluates every rank and THEN
  latches, so a node reading a register sees its PRE-latch byte. The
  tiled ticker latches each tile at the end of that tile's own tick and
  flushes, so a reader in a lower tile was taking the POST-latch byte
  out of the strip. The first pass removed every cross-tile slot
  pointing at a register, which made W1 pass on an object that could
  not exhibit the defect; amendment 7 rejected that. Now:
  - the generator KEEPS those readers, and **chooses** which node at a
    usable rank level becomes the register by how many of the three
    frozen tilings its ALREADY-DRAWN incoming edges cross (ties by
    lowest Morton index). That selection is necessary and is not a
    fabricated edge: almost every drawn edge spans exactly one rank,
    and a register never sits at a boundary, so a blindly-picked
    register is read only from the rank below it — inside its own tile.
    Measured with the blind pick: **zero** cross-tile register readers
    on all three sides and all three tilings. With the selection:
    side 16 — 0 / 1 / 1 edges for the 2- / 4- / 8-tilings; side 44 —
    2 / 6 / 14; side 128 — 2 / 7 / 15.
  - `TiledGraphRouter.tickAndFlushOneTile` reads every register's truth
    BEFORE calling the tick (the kernel never writes a register, so
    that byte is the pre-latch one) and `TiledGraphFiles.writeLowerStrip`
    writes it into the strip through a new `truthOverrides` argument.
    Rank mode only — a sync-mode strip is read one world tick later as
    the previous vector, which is the post-latch byte it already
    carries.
  - the same byte overrides the resident-buffer fast path. At K >= 2 a
    reader can find its source tile still resident and read the live
    buffer instead of the strip; that buffer is already past the latch.
    W1 failed at side 16, tiles 4, K = 2, rank mode on exactly this
    before the fast path was covered — the strip fix alone was not
    enough.
  - a register is therefore ALREADY "the previous world tick's value"
    in rank mode, so W7b's ghost-population switch leaves it alone (it
    carries no fresh information across a boundary to delete), and
    `TiledReference.oddInputChangeSet` skips register sources: both
    runs read the same byte for them.
  - two repair paths cannot reproduce a pre-latch byte and say so in
    the code: recovery case (ii) and `regenerateStaleLowerStrip` both
    rebuild a strip from a body that is already AT the epoch, where the
    register's earlier value is gone. Both feed only sync's reader,
    which wants the post-latch byte they write.
  - **Gated.** (a) W1/W2 hold three-way with the readers present, and
    the count is printed beside the gate
    (`W1W2-REGISTER-CROSSINGS`), asserted per side in
    `testFindingACrossTileRegisterReadersExist`. (b)
    `testFindingAReproduction_*` parses the committed rank-mode strip
    and asserts the register entry equals the PRE-latch byte (and
    differs from the post-latch one), then forces that entry to the
    POST-latch byte and asserts the world tick differs from the
    reference: 1 node at side 16 × 4, 1 at side 44 × 4, 22 at side
    128 × 8. The defect is reproducible on demand.
- **Kept as built, adopted by amendment 7:** the corrections to letters
  3 and 4 (the node-local odd-input derivation asserted by equality;
  `Δ_e ⊇ readers(e)` asserted in sync mode only, with the
  top-reader-rank theorem in rank mode), the register placement rule,
  the rank-mode perturbation hook, the symlinked reference, W7b at two
  points of the trajectory.
- **W6 (printed, not gated)**, side 128 × 8 tiles, K = 1, this run:
  rank `tick_ms_per_tile(max)=5.688 flush_ms_per_tile(max)=42.394
  halo_bytes=41328 loads=8 evicts=7`; sync
  `tick_ms_per_tile(max)=4.095 flush_ms_per_tile(max)=43.868
  halo_bytes=41328 loads=8 evicts=7`. `halo_bytes` did NOT return to the
  pre-repair 41,440 as expected — it is 41,328, exactly where the first
  pass left it. Each of the 8 lower strips is a 40-byte header plus 16
  bytes per DISTINCT cross-tile source, so 41,440 is 2,570 sources and
  41,328 is 2,563: seven fewer. The loss is not the cleared readers
  (that change is undone here) but the register construction itself —
  every `R` gives up all six of its slots and every `S` five of its six,
  which stops 56 + 56 nodes at side 128 from being READERS, and for
  seven sources that reader was the last one across their boundary.
  Restoring the readers put 14 registers back into the side-128
  8-tiling's strips, and the changed register SELECTION took about as
  many other sources out; side 44 moved 367 → 370 entries.
- **Full suite: 823 Swift XCTest cases, 45 skipped (unchanged), 0
  failures, 731.841 s.**

---

## 2026-09-11 — the repaired objects, the reference evaluator, W7 (ticking step two, amendments 4–6)

Branch `dag/ticking`. Repairs the two findings of the blind verifier's
2026-09-10 verdict (`docs/contracts/VERIFIER_TICKING_2026-09-10.md`)
and builds amendments 4, 5 and 6 of
`docs/contracts/TICKING_GATES_FROZEN.md`. Kind of run: CONTROL /
RE-DERIVATION throughout — this is the session that makes the
control able to fail.

- **The repaired objects (amendment 6, letter 1).** `TiledFixture`
  used to leave every LUT6 at its constructed zero — the constant-0
  function — so after one tick the world was all zeros and static, and
  every equality gate in the contract was true of a world where
  nothing depended on anything. The generator now, AFTER its frozen
  rank/truth/edge draws (those three streams are bit-identical to
  before): draws one `next64() & 1` per node from a new
  `NamedStream("tiling-luts-<side>")` and writes `bit(idx) =
  (popcount(idx & presentMask) + choice) & 1` — parity or complemented
  parity over that node's present slots, so every node is fully
  sensitive on every input; then builds one period-2 register
  oscillator per usable rank level: `R` (register, slots cleared) ←
  back edge ← `S` at rank `r − 1` whose only input is `R` through the
  complemented single-input parity, so `R_{k+1} = ¬R_k`. A level is
  usable when `r >= 2` and `r` is a boundary of NONE of the frozen
  2/4/8 tilings — a pair straddling a boundary would be a cross-tile
  back edge, which `SAVE TILED` refuses, and rank 0 holds the single
  centre node that the tiling contract's own query seeds start from.
  Registers per side: 1 (side 16), 14 (44), 56 (128). Every other slot
  pointing at an `R` is cleared, so a register's only reader is its
  own `S`, in its own tile: the tiled ticker latches at the end of
  each tile's tick and then flushes, so a cross-tile reader of a
  register would see the POST-latch value where the untiled engine
  shows it the PRE-latch one, and W1 would fail on a correct engine.
- **Tile bodies carry their registers.** `TiledGraphFiles.write` now
  re-registers each tile's intra-tile back edges on the tile-local
  engine before saving (the v7 snapshot section already had the
  format), `loadTileWithGhosts` re-registers them on the ghosted
  engine, and `scratchRealEngine` carries them into the flushed body.
  Without all three a ticked tile silently loses its registers one
  flush in. Gated by `testTileBodiesCarryRegisters` (sides 16/44 ×
  tilings 2/4/8, query path and ticker path).
- **The reference evaluator (amendment 6, letter 2).**
  `Tests/DagDBTests/TiledReference.swift` — a test-side evaluator of
  the same graph, built from the raw buffers (ranks, slots, LUTs,
  register flags, back edges) and written from the contract's
  paragraph plus the kernel's bit rule, which never calls
  `DagDBEngine`. W1 and W2 are now three-way: **tiled == untiled ==
  reference**, bit for bit, at N ∈ {1, 2, 5, 12} on every side ×
  tiling × K. It is gated against the untiled engine first
  (`testReferenceMatchesUntiledEngine_rank/_sync`, 12 ticks, exact).
  One correction the first run forced: the letter says "ranks
  evaluated from the highest present down to 0", but `DagDBEngine.tick`
  dispatches `maxRank − 1 … 0` and `rebuildCompaction` drops any node
  whose rank is `>= maxRank`, so at side 128 — whose top rank is
  exactly 64, the engine's bucket count — the top level is never
  evaluated in rank mode. The literal reading disagreed with the
  engine on 4165 of 16384 bytes at every tick; the reference now
  carries the engine's dispatch bound. `dagdb_tick_sync` has no such
  bound and needed none.
- **`SAVE TILED` writes one epoch everywhere (amendment 4, letter 1).**
  It used to stamp the saved tick count on the manifest entry alone
  and hard-code 0 into `meta.json`, the body header and the single
  parity strip — so sync's first world tick at `k + 1` looked for a
  `k` strip that never existed and refused `haloStale` forever. Now
  the saved count goes on all four, and BOTH parity strips are written
  (parity `k mod 2` at `k`, the other parity carrying the same truths
  at `k − 1`; both at 0 when `k = 0`). Gated by a test that parses the
  four places with its own byte reader, plus the **four-cell grid**
  `{rank, sync} × {saved 0, saved 4} × {library worldTick, daemon
  TILED TICK}` — eight cells, each compared against the reference
  after the same number of ticks, none by implication.
- **W7 · discrimination (amendments 5 and 6, letters 3–6)**, new file
  `Tests/DagDBTests/TiledW7Tests.swift`:
  - **W7a** perturbs one committed strip entry at a time and asserts
    the engine's change set EQUALS the reference's `Δ_e`: side 44 × 4
    tiles, K = 1, all 367 strip entries in both modes; side 128 × 8, a
    seeded sample of 64. |Δ_e| at side 44 rank: min 1, median 25, max
    99 (sync: 1 / 2 / 6). In SYNC mode the perturbation is a real edit
    of a real committed file (sync reads the `k − 1` parity strip,
    which the round does not rewrite); in RANK mode the source tile
    re-flushes its own epoch-`k` strip earlier in the same round, so a
    pre-tick file edit is provably overwritten before any reader sees
    it and the same perturbation is delivered through a test-only
    router hook at the reader's input.
  - **W7b** runs the engine with its ghosts held at the previous world
    tick (test-only `ghostPopulationDisabled`) and asserts it equals
    the reference's `stale`, while the ordinary run equals `fresh`.
  - **W7c** asserts the per-tick change count equals the reference's,
    printed, 12 ticks, both modes, all three sides. Rank mode settles
    to 3 / 69 / 377 changed bytes per tick (sides 16 / 44 / 128) — the
    line that read 1308 then 0, 0, 0 before this session.
  - **W7d** asserts a varying register per tile, from the reference's
    vectors, for every tiling of every side, with the one structural
    exception named and asserted rather than passed over (see below).
- **Two of the reserve tier's own numbers were wrong, the same way it
  warned about.** Amendment 6 named two arithmetic traps in amendment
  5 and then reproduced the family twice more. (i) Letter 4's `|D| >=
  (crossings whose source changed)` counts EDGES against a set of
  NODES: side 16, tick 1, 105 crossings moved and `|D| = 68`, because
  several crossings land on one reader and an even number of them
  cancels under parity. Replaced by an exact node-local derivation
  (`TiledReference.oddInputChangeSet`) that `D` is asserted EQUAL to.
  (ii) Letter 3's `Δ_e ⊇ readers(e)` holds in sync mode (one hop) but
  not in rank mode, which propagates through every rank inside one
  tick: a reader can have a second input that is itself downstream of
  the same perturbation, and two flipped inputs cancel. 32 of side
  44's 367 entries have such a cancelled reader. What is asserted
  instead is a theorem: every reader at the MAXIMUM reader rank flips
  (nothing the perturbation reaches lies above that rank), hence
  `|Δ_e| >= 1` always.
- **One gate the object cannot satisfy, stated as a derived fact.**
  "Every tile holds at least one register" is unreachable for side 16:
  an oscillator needs `rank(R) = rank(S) + 1` (the snapshot validator
  requires `src rank > dst rank` on every combinational edge) with
  both ends in one tile under ALL THREE frozen tilings, and side 16's
  rank range is 0…8 while the union of its 2/4/8 boundaries is
  {1…7} — rank 8 is the only usable level, so only the top tile of
  each tiling carries one. Side 44's 8-tiling has the same hole in
  tile 0 (span {0, 1}, and rank 0 is the reserved query seed). W7d
  asserts that every register-less tile is exactly one of these, by
  recomputing the usable levels.
- **W6 (printed, not gated)**, side 128 × 8 tiles, K = 1, this run:
  rank `tick_ms_per_tile(max)=5.340 flush_ms_per_tile(max)=45.420
  halo_bytes=41328 loads=8 evicts=7`; sync
  `tick_ms_per_tile(max)=4.121 flush_ms_per_tile(max)=43.917
  halo_bytes=41328 loads=8 evicts=7`. `halo_bytes` moved from 41,440
  to 41,328 because the registers' cleared fan-out removes a few
  crossings.
- **Full suite: 810 Swift XCTest cases, 45 skipped (unchanged), 0
  failures, 743.951 s.** Amendment 1's recorded "761 tests / flush
  <= 30 ms" and the verifier's "782 tests" are both superseded by this
  line.

---

## 2026-09-10 — ticking across tiles (tiling step two)

Branch `dag/ticking`. Roadmap item 8, step two of
`docs/tiled-streaming.md`'s build order (spec step 5, minus the
optional pre-fetch thread). Gate contract:
`docs/contracts/TICKING_GATES_FROZEN.md` (W1–W6, amendments 1–3).
Kind of run: CONTROL / RE-DERIVATION for W1 (rank-mode world ticks
equal the untiled engine, bit for bit), W2 (sync-mode, likewise), and
W5 (daemon ticks equal router ticks, bit for bit); INTERFACE for the
daemon verbs (`TILED TICK`/`TILED GET`) and the manifest/recovery
machinery; MEASUREMENT for W6 (printed, not gated).

- **Library work already in the tree at session start (K-S1, prior
  build)**: ghost registers as a parallel resident type
  (`TickResidentTile`, independent of the query path's `ResidentTile`
  so a ghosted engine's rewritten `-2` slots never leak into BFS/
  SELECT's own sentinel handling); descending-rank-order world ticks
  with fresh halos each round (rank mode: sources' CURRENT truth if
  resident+ticked this round, else their committed strip; sync mode:
  always the previous round's committed strip, ping-pong by epoch
  parity so k−1 survives the k write); sync from parity strips
  (`halo_lower.<epoch mod 2>.bin`); per-tile flush BEGIN/COMMIT to
  `flush.wal`; crash recovery at both crash points (body behind the
  BEGIN's epoch, or body already there but strip/meta/manifest not yet
  rewritten).
- **This session — the manifest rule (contract amendment 1).** A
  ticked tile's body changes every world tick, so the manifest's
  `bodySHA256` snapshotted at tiling time can't stay the authority for
  it. Every tile flush now rewrites that tile's manifest entry
  (`bodySHA256` = the freshly written body's sha256, `tickEpoch` = the
  flushed epoch) atomically — temp file, then rename — BEFORE the
  `TILE_FLUSH_COMMIT` line, in the order BEGIN → body → strip → meta →
  manifest entry → COMMIT. The ticker's old bypass of the hash check
  is gone: `loadTileWithGhosts` now checks the manifest-recorded
  `bodySHA256` exactly as the query path's `loadTile` does — one
  authority for both paths (amendment 2, letter 1). Recovery precedes
  that check: a tile whose `flush.wal` ends in an unmatched
  `TILE_FLUSH_BEGIN` is fixed FIRST (case i re-ticks with the
  interrupted tick's own ghost inputs; case ii regenerates the strip,
  meta and manifest entry from the already-committed body), and the
  hash check only ever runs on a tile whose `flush.wal` is clean.
- **Per-tile epochs, no router-global counter (amendment 2, letter
  2).** The K-S1 manifest carried one graph-level `tickCount`; that's
  gone. Each `TileEntry` now carries its OWN `tickEpoch`, written at
  `SAVE TILED` time (the daemon's tickCount) and rewritten by every
  flush. The router holds no global tick counter — its notion of "the
  world's epoch" is the (min, max) over every tile's `tickEpoch`.
  `TILED STATUS` prints `epoch=<min>/<max>`; `TILED TICK` prints the
  max after; `WorldTickReport.epoch` is that same max.
- **The partial round, and roles at open (amendment 2's consequence,
  refined by amendment 3).** A crash BETWEEN two tiles' flushes (not
  mid-flush) leaves every `flush.wal` clean but the tiles' epochs
  mixed — some at k, the rest still at k−1. A mixed-epoch world must
  never answer a query, so `TiledGraphRouter.init` now takes a `role`:
  **writer** (the default, and the daemon's `TILED OPEN`) recovers any
  dangling flush, then ticks the tiles still behind up to the max
  epoch (that round's own inputs — rank: sources' strips at max; sync:
  at max−1) before returning, so a writer's world is never torn when
  it starts answering; **reader** refuses outright over a torn world
  (`RouterError.worldTorn(min, max)`) rather than recovering or
  ticking. `worldTick` itself now only ever starts from `min == max`
  (defensively refuses `worldTorn` otherwise — a writer's own `init`
  already closed that gap). The public `recover(mode:)` call is gone;
  recovery and partial-round completion both run automatically inside
  a writer's `init`, reported via `OpenReport(recovered:, completed:)`.
  The partial round's OWN mode is read off the tiles already at max —
  their last committed `TILE_FLUSH_BEGIN`'s third field (the BEGIN
  record now carries `TILE_FLUSH_BEGIN <tile> <epoch> <rank|sync>`) —
  never a caller-supplied mode; disagreement among them is refused by
  name (`RouterError.partialRoundModeMismatch`) with nothing rewritten.
- **W5 (daemon verbs).** `TILED TICK <id> [<n>] [SYNC]` → `OK TILED
  TICK id=<id> ticks=<epoch after> tiles_ticked=<n> loads=<n>
  evicts=<n> flushes=<n> halo_bytes=<n>` (n defaults 1, checked
  1...10000; SYNC selects sync mode); `TILED GET <id> <globalId>
  TRUTH` → `OK TILED GET id=<id> node=<globalId> truth=<0|1|2>`.
  `TILED OPEN`'s OK line gained `recovered=<n> completed=<m>`. `SAVE
  TILED` now refuses a cross-tile BACK_EDGE before writing anything:
  `ERROR bad_value: back edge crosses a tile boundary (<src>→<dst>)`
  (the check lives in `TiledGraphFiles.write` itself, so the library
  path refuses too, not just the daemon's). Reader sessions may run
  `TILED GET` (read-only, like BFS/SELECT/STATUS/LIST); `TILED TICK`
  is forbidden there (it flushes every tile to disk). MCP:
  `dagdb_tiled_tick`, `dagdb_tiled_get_truth`; the `dagdb_query`
  catalog's TILED block updated (ticking is built; pre-fetch and the
  cold tier remain). bridge.py's read-only allowlist gained `TILED
  GET`.
- **W6 (printed, not gated)**, side 128 × 8 tiles, K = 1 — this run's
  numbers: rank mode tick_ms_per_tile(max)=5.210 flush_ms_per_tile(max)=42.923
  halo_bytes=41440 loads=8 evicts=7 tiles_ticked=8; sync mode
  tick_ms_per_tile(max)=3.819 flush_ms_per_tile(max)=42.250
  halo_bytes=41440 loads=8 evicts=7 tiles_ticked=8. (K-S1's own run
  printed tick ≤5.4 ms, flush ≤30 ms per tile — this session's flush
  numbers run higher, likely disk-state/thermal variance between runs
  on the same machine, not a regression in the mechanism; the gate is
  printed, not asserted, precisely because these numbers move run to
  run.)
- **Tests**: `Tests/DagDBTests/TiledWorldTickTests.swift` gained the
  manifest-refresh pair (rank/sync, decoding `manifest.json` off disk
  and recomputing every tile's sha256 independently), the clean-but-
  disagreeing hash-mismatch case (untouched tiles proven byte-
  identical after the refusal), and the partial-round suite (reader-
  before/writer-completes/reader-after sequencing, the mode-mismatch
  refusal with nothing rewritten) — `Tests/DagDBDaemonKitTests/
  TiledCommandTests.swift` gained the W5 daemon-vs-router tick parity
  tests (rank and sync, 5 ticks then 3 more, 64 seeded `TILED GET`
  checks against the daemon's own truth buffer), the saved-tickCount-
  nonzero case, the cross-tile-BACK_EDGE refusal, the daemon-side
  partial-round-at-open case, and the `TILED TICK`/`TILED GET` DSL
  grammar. One test fixture fix along the way:
  `Tests/DagDBDaemonKitTests/HandlerFixture.swift` gained an optional
  `maxRank` parameter (default 8, unchanged) — a side-44 fixture's
  Chebyshev-derived ranks reach 22, and rank-mode `TICK` is bounded by
  the engine's allocated `maxRank` bucket count (`TICK_SYNC` isn't,
  which is why this only bit the new rank-mode daemon tests).
  Full suite at the time of this entry: **782 Swift XCTest cases, 45
  skipped, 0 failures** — superseded by the 2026-09-11 entry above
  (810 cases, 45 skipped, 0 failures), which also rebuilt the objects
  these numbers were measured on.

**Not done** (the contract's "Not promised" list): the pre-fetch
thread (optional — the letters say it changes no result if added),
the cold tier, thermal pauses, the 10¹¹-node run, `TILED BACKUP`.
---

## 2026-09-10 — correction: the rank bound stopped bounding the computation

Branch `dag/rank-bound`, built on `main`. Gate contract:
`docs/contracts/RANK_BOUND_GATES_FROZEN.md` (R1–R5, amendments 1–2).
Kind of run: CONTROL / RE-DERIVATION for R1 (both tick modes must
agree, and both must equal an expectation computed on the CPU outside
the engine), INTERFACE for R2–R4.

**The defect.** `DagDBEngine.rebuildCompaction()` put a node in its
(rank, colour) dispatch bucket only when its rank was below the
configured `maxRank`, and both rank-mode loops strode over exactly
those levels. A node at or above `maxRank` was therefore never
computed by rank-mode `TICK` — while `tickSync` dispatches over all
nodes and did compute it. Nothing refused the state: `SET RANK`
checked only that the node index existed, and the bulk rank commit
said in its own comment that it skipped validation. The daemon
answered `TICK` with `OK` and a rising tick count while part of the
graph stood still. Present in the engine as shipped, including public
v0.2.0.

**The path that reaches it in the field** (the hole named by an independent hostile read, adopted as R1):
not a hand-injected rank, but a restore. A graph saved from a daemon
configured with a large bound and loaded into one configured with a
small one carries ranks above the running bound without touching any
refused verb — and moving a graph between configurations is exactly
what SAVE/LOAD is for.

**Ruled: compute, do not refuse.** The bound is an allocation hint,
not a property of the graph — the field's own comment calls it
"Number of ranks in the DAG" and defaults it to 16 — and nothing in
Metal is sized by it. The segment table and the rank loop are
CPU-side, so covering every rank present costs a longer loop over
mostly-empty segments and nothing else. Refusing instead would leave
a graph restored under a smaller bound dead in rank mode until the
operator restarted the daemon.

- **R1 (the fix).** `rebuildCompaction()` now scans `rankBuf` for the
  highest rank actually present and sizes the buckets and the segment
  table to `effectiveRankCount = max(maxRank, highestRankPresent + 1)`;
  both rank-mode loops (`tick`, `tickLegacy`) stride over
  `effectiveRankCount`. `maxRank` keeps its meaning everywhere else —
  engine init, STATUS, the fold schedules. `effectiveRankCount` and
  `highestRankPresent` are public read-only on the engine. The scan is
  clamped at `nodeCount`, so a corrupt buffer carrying an absurd rank
  cannot turn the table allocation into a denial of service.
- **R2 (the operation says how much it did).** `OK TICK` and
  `OK TICK_SYNC` now carry ` nodes_computed=<n>` always — the whole
  command's node-evaluations, per-tick slots times the tick count —
  and, when the graph reaches past the configured bound, also the
  bound pair: rank mode prints ` ranks=<levels> bound=<maxRank>` (the
  levels it dispatched), sync mode prints
  ` rank_max=<highest> bound=<maxRank>` — the same news as a fact about
  the graph, because sync does not dispatch by rank and `ranks=` there
  would imply a bounded dispatch it never performed. A
  restored-under-a-smaller-bound graph announces itself on the wire at
  the first tick either way.
- **R3 (the door).** `SET <node> RANK <v>` with `v >= nodeCount` is
  refused with `ERROR out_of_range: rank <v> not in 0..<<nodeCount>`
  and the rank buffer is untouched; no valid DAG on N nodes holds a
  rank of N or more. `SET_RANKS_BULK` checks the whole vector before
  writing anything and names the first offending node. A rank in
  `[maxRank, nodeCount)` is accepted and computed — that is the point.
- **R4 (pre-existing state, catchable without ticking).** `VALIDATE`
  adds a rank-bound line naming the count of nodes at or above the
  running bound, the first of them, and the highest rank found —
  reported after the edge checks, so a genuine edge violation still
  surfaces first. The load path does NOT refuse: a snapshot written
  under any bound still loads. `STATUS` prints `ranks=<levels>` and
  `rank_max=<highest present>` beside the existing `maxRank=`, so a
  health check compares two printed numbers instead of doing
  arithmetic on one. Every field STATUS printed before is still
  printed, in the same relative order.
- **R5 (no regression).** Full suite green: 761 tests, 45 skipped, 0
  failures.

New: `dagdb/Sources/DagDB/RankBoundFixture.swift` (the 22-level object,
one edge crossing rank 8), `dagdb/Tests/DagDBTests/RankBoundTests.swift`
(R1 control, expectation re-derived in the test from the LUT6 tables
and the neighbour slots), and
`dagdb/Tests/DagDBDaemonKitTests/RankBoundDaemonTests.swift` (R2–R4 on
the wire — the contract names `HandlerFixture`, which lives in that
target).

The third rank-mode loop, fixed with the other two:
`DagDBEngine+Graph.tickWithResonance` — a public method with no caller
in the tree — strode over `maxRank` and carried the identical defect.
The builder named it rather than touching it, correctly, since it sits
outside the contract's scope. It is fixed here anyway by the same
mechanism (`ensureRankTopology()` then `effectiveRankCount`), because
shipping a correction for one instance of a defect while a second
instance of it stands in the same file is the very shape this contract
was written against. It is NOT separately gated — nothing calls it —
and that is stated rather than implied.

---

## 2026-09-10 — tiling, step one: tile files, router load/evict, cross-tile BFS/select

Branch `dag/tiling`, built on `main`. Roadmap item 8, step one of
`docs/tiled-streaming.md`'s build order (spec steps 3–4). Gate
contract: `docs/contracts/TILING_GATES_FROZEN.md` (T1–T6, amendments
1–2). Kind of run: CONTROL / RE-DERIVATION for the cross-tile queries
(tiled == untiled, exactly), INTERFACE for the files and daemon verbs,
MEASUREMENT for load/evict cost — no new number, the single engine's
own answers are the truth.

- **T1 (tile files).** `TiledGraphFiles.write` splits a DAG by rank
  range into `tile_<lo>_<hi>/{body.dags, halo_lower.bin, halo_upper.bin,
  meta.json}` plus a graph `manifest.json` (tile list, crossings,
  per-tile body sha256). `body.dags` is the CURRENT snapshot format
  (v7), not a frozen v3 — the contract's one amendment to the spec's
  wording. This session added a second entry point,
  `TiledGraphFiles.write(engine:grid:dataRoot:name:boundaries:)`,
  splitting the DAEMON'S OWN live engine directly (`SAVE TILED`'s
  object) rather than only a `TiledFixture.Object` — it scans
  `rankBuf` for the true highest rank present instead of trusting
  `engine.maxRank` (that's an allocated bucket count, not necessarily
  the highest rank actually written), so `runSelect`'s overlap test
  stays correct for a live engine whose rank lane doesn't use every
  allocated level. `TiledFixture.populate(engine:grid:side:)` was
  split out of `TiledFixture.generate` so a caller that already owns
  an engine (a daemon test fixture) can write the frozen object into
  it directly; `generate` is now a thin wrapper around it.
- **T2 (tiled == untiled).** Cross-tile `runBFS` (undirected/backward,
  level-synchronous across tiles, minimum depth over all paths),
  `runAncestry`, `runSelect` on `TiledGraphRouter` match the single
  engine's `DagDBBFS.bfsDepthsUndirected`/`bfsDepthsBackward` and the
  truth/rank secondary index exactly, independent of K.
- **T3/T4 (router).** LRU load/evict bounded by K; a torn tile body
  (sha256 mismatch against the manifest) is refused, never loaded
  silently, and the refusal is recorded (`TILED STATUS`'s
  `refused=<n> last=<error>`).
- **T5 (daemon, this session's main build).** `SAVE TILED <dir>
  <b1,b2,...>` → `OK SAVE TILED dir=<dir> tiles=<n> nodes=<N>
  crossings=<c>`; `TILED OPEN <dir> [<K>]` → `OK TILED OPEN
  id=x%08x tiles=<n> nodes=<N> resident_max=<K>`; `TILED BFS <id>
  <globalId> <depth> [BACK]` → shm `[u32 count][u32 16]` rows (u64
  global id, u32 depth, 4 pad) → `OK TILED BFS ... count= loads=
  evicts=`; `TILED SELECT <id> <truth> <lo> <hi>` → shm `[u32
  count][u32 8]` sorted u64 ids → `OK TILED SELECT ... count=`;
  `TILED STATUS <id>` → `OK TILED STATUS id= resident=<n>/<K> loads=
  evicts= refused=<n> last=<error|none>`; `TILED LIST` / `TILED CLOSE
  <id>`. Routers live on the HANDLER (`tiledRouters: [String:
  TiledRouterEntry]`), NOT in `TwinState` — a router is never
  persisted, never WAL-logged, never part of a snapshot; the tile
  directory on disk IS the durable state. `STATUS` gained
  `tiled_open=<n>`; routers do NOT count toward `twin_open`.
  `TiledGraphRouter` is a Swift actor and the handler's dispatch is
  synchronous, so one small helper (`runTiledSync`, in the new
  `DagDBCommandHandler+Tiled.swift`) bridges a single actor call
  through a `DispatchSemaphore`-blocked `Task` — the daemon's existing
  one-command-at-a-time serialization is unchanged, this only gives
  the synchronous dispatcher a way to make one `await` call and wait
  for it. Reader sessions may run `BFS`/`SELECT`/`STATUS`/`LIST`;
  `OPEN`/`CLOSE`/`SAVE TILED` are forbidden there (mutate the router
  registry or the filesystem). MCP: `dagdb_save_tiled`,
  `dagdb_tiled_open/bfs/select/status/close`; bridge.py's read-only
  allowlist gained the four read-only TILED sub-verbs.
- **Tests**: `Tests/DagDBDaemonKitTests/TiledCommandTests.swift` (26
  cases — DSL grammar, SAVE TILED/TILED OPEN summary lines checked
  against an independently computed `WriteReport` rather than
  hardcoded numbers, TILED BFS/SELECT cross-checked row-for-row
  against the daemon's own `BFS_DEPTHS`/`SELECT` verbs, the T4 torn-
  body refusal end to end over the socket, the reader-session split,
  `TILED CLOSE` → `LIST count=0`). Full suite: **752 Swift XCTest
  cases, 45 skipped (unchanged from baseline), 0 failures.**

**Not done** (explicitly out of this contract's scope, per its "Not
promised" list — steps 5–6 of the spec's build order): pre-fetch,
ticking across tiles, the cold tier, thermal pauses, the 10¹¹-node
run, `TILED BACKUP`.

---

## 2026-09-10 — attention hook: the sealed allocator as a ticked process (roadmap item 7)

Branch `dag/hook`, built on `main`. Roadmap item 7: the sealed
allocator court as a daemon-global ticked engine process. Instead of
one batch `AllocatorCourt.run` call, an attention "hook" is bound to
an alarm set, a budget layout (the tariff; sealed by default), a
per-frame budget B, a lag Δ (3), and one of three lagged policies
(allocator, greedy, uniform — the oracle has no lag and stays a court
arm, not a hook policy) plus, optionally, a master clock. Each `HOOK
STEP` advances the hook's frame counter t by one: at frame t it reads
the alarm of source frame t − Δ, decides what to buy under B (cheapest
tier with read value 1 in the claimed pocket for allocator, the
deepest affordable tier in the source alarm's pocket for greedy,
nothing decided for uniform beyond its flat frame cost), books the
purchase, and appends one line to its ledger. Bound to a clock, one
CLOCK ADVANCE tick is exactly one hook step, applied after the gears —
attention is spent on the engine's clock, not by a batch call. Kind of
run: CONTROL / RE-DERIVATION against the sealed allocator court (P4
gate 1) — no new number.

Gate contract: `docs/contracts/HOOK_GATES_FROZEN.md` (H1–H6, amendment
1 fixing the ledger row layout at 40 bytes aligned and the
countsTowardCost-on-a-judged-non-quiet-miss letter).

- H1 (ledger equals the court, control): `hook.result ==
  AllocatorCourt.run(records:budget:)[policy]` — Swift `Equatable`, no
  tolerance — held at all 5 sealed grid points × 3 policies.
- H2 (per-frame ledger, interface): one row per step — t, src, judged,
  outcome ∈ {hit, miss, none}, class, ear, pocket, tierBought, spend,
  countsTowardCost, cumulativeCost. A judged frame whose source is
  quiet is `none`: allocator/greedy buy and book nothing, uniform pays
  its flat frame cost and books cost with no hit/miss. Warm-up rows (t
  = 1..Δ) are `judged = false`; uniform books their spend into
  `warmupCostExcluded` (never into `cost`) and still updates
  `maxSpendRatio`; allocator/greedy warm-up rows spend 0.
  `cumulativeCost` is judged spend only. Identities held over the 203
  sealed rows. The ledger is DERIVED, never stored — rebuilt by
  re-stepping.
- H3 (persistence and replay): WAL opcode 0x2F (`hookOpen`) / 0x30
  (`hookStep`); snapshot v7's `hooks` field persists parameters plus
  the frame counter t only, the ledger rebuilt by re-stepping on
  restore. Closing an alarm set or budget layout a hook depends on
  refuses: `ERROR forbidden: hook <h> depends on <id>`.
- H4 (clock binding, ruled): a hook bound to a clock has one driver —
  `HOOK STEP` refuses `ERROR forbidden: bound to clock <c>`; `CLOCK
  ADVANCE` steps every bound hook once per tick, after the gears;
  `CLOCK CLOSE` cascades to bound hooks (`hooks_closed=<n>` beside
  `gears_closed=<n>`), same shape as a gear. Bound and unbound hooks
  gave equal results at one grid point, asserted both ways.
- H5 (daemon): `HOOK OPEN/STEP/STATE/LEDGER/INFO/LIST/CLOSE` over the
  socket, DSL, MCP, and the web bridge; reader sessions may run
  STATE/LEDGER/INFO/LIST, never OPEN/STEP/CLOSE. The ledger's shm row
  is 40 bytes fixed-width, 8-byte aligned. Over the socket, `HOOK
  STATE` after 203 steps at the richest sealed grid point prints
  `served=150 misses=0 cost=819218.0` for the allocator policy (the P4
  line) and `served=50 misses=100 cost=94400.0` for uniform.
- H6 (printed, not gated): ≈0.9 µs per step (allocator policy, sealed
  layout, debug build); cumulative cost 0 / 501710 / 538024 / 819218
  at t = 50/100/150/203 at the richest sealed grid point.

New engine surface: `AttentionHook` (`dagdb/Sources/DagDB/
AttentionHook.swift`) — fixed params (alarm id, layout id or nil for
the sealed default, budget B, lag Δ, policy, optional clock id),
`step()`/`step(n:)`, the derived per-frame ledger. An eleventh
daemon-global registry (`TwinState.hooks`, prefix `h`) plus
`ClockEntry.hookIds` (hooks a clock drives, stepped after its gears,
closed on `CLOCK CLOSE`). Wired over the daemon socket/DSL/MCP/bridge
as `HOOK OPEN/STEP/STATE/LEDGER/INFO/LIST/CLOSE`
(`dagdb/Sources/DagDBDaemonKit/DagDBCommandHandler+TwinHook.swift`,
`DSLParser+Twin.swift` `parseHook`).

Results: H1 `==` at all 5 grid points × 3 policies; H4 bound vs
unbound equal; H5 lines exact over the socket; H6 ≈ 0.9 µs/step,
cumulative cost 0/501710/538024/819218 at t = 50/100/150/203.

Suite: 710 tests. 45 skips with neither fixture env set (30 with the
`DAGDB_W2_FIXTURE` fixture alone — the sealed hook tests are gated on
the same W2 fixture as the allocator court, no new fixture). 0
failures.

Not done: not merged to main (Haruth merges); the hook does not yet
consume the derived-views feed (roadmap item 7's own note on that);
no `HOOK BUDGET` re-declaration (ruled out — a different B is a
different hook).

---

## 2026-09-10 — kernels: per-path storage and the sealed cross-convolution residual (spec line 6)

Branch `dag/kernels`. The second half of spec line 6: per-path
kernels (impulse responses root→ear, 2048 taps at fs = 3000 Hz)
stored in the engine by reference and by id, a per-pair warmup
declared or derived, and the cross-convolution identity
kB ⋆ a = kA ⋆ b judged by the W1 court's own frozen residual R —
not the engine's pre-existing `CrossConvolutionCheck.check` ("XCONV
CHECK", the standing patrol check from the summer's twin-primitives
pass). Kind of run: CONTROL / RE-DERIVATION against the sealed W1
court (PASS: G0 bridge, G1 court 50/50, G2 fakes 50/50, G3 perturbed
50/50).

One finding, stated up front by the contract itself: `XCONV CHECK`
is NOT the court's R. It compares over the full convolution length
(n + m − 1 samples) instead of the record window, divides by a
symmetric denominator `max(|kB⋆a|, |kA⋆b|)` instead of the one-sided
`max|kB⋆a| + 1e-300`, and takes Float32 records and taps instead of
Float64 end to end. On the 190 sealed W1 trials the patrol check
flips 50 of 190 court gates — every one of them a TRUE court
recording — because it compares past where the identity actually
holds. `XCONV CHECK` stays wired, documented as a compatibility
patrol check, not a court check; `XCONV SEALED` is now spec line 6's
standing cheap check.

Gate contract: `docs/contracts/KERNELS_GATES_FROZEN.md` (K1–K5, 3
amendments — the trial count corrected to 190, K1's absolute bound
recorded as an expected FAIL at the float64 floor and replaced as
the standing gate by a relative bound K1', and XCONV CHECK formally
deprecated in favor of XCONV SEALED).

- K1 (absolute, frozen, recorded as a floor finding): FAIL on 2 of
  190 trials — fake_34 (R 16.44) and fake_48 (R 24.70) miss the
  2.533e-14 absolute control tolerance by 3.9e-14 / 6.4e-14, relative
  2.4e-15 / 2.6e-15 — the float64 summation-order floor of two
  different convolution orders, not the identity. K1' (amendment 3,
  the standing gate): |R_engine − R_python| ≤ 3e-15·max(1, R_python)
  holds on all 190.
- K2 every court line re-derived: G0 6.151e-15 vs the court's
  4.101e-15 (both ≤ 2.533e-14, the printed digits are summation-order
  noise at the floor); worst court trial 5.415e-03, 50/50 within
  tolerance; fakes 50/50 over 10×tolerance; perturbed 50/50 over
  tolerance, quartiles 1.019e-01 / 1.032e-01 / 1.052e-01; cal
  reference max 3.348e-03 (not gated).
- K3 storage and reach: `KERNEL LOAD`/`INFO`/`LIST`/`CLOSE` and
  `XCONV SEALED` over the socket, DSL, and MCP; kernels persist BY
  REFERENCE (path + sha256), never their taps — registry prefix `k`,
  WAL opcode 0x2E, snapshot v7's `kernels` field (tolerant decode); a
  missing or hash-changed file on restore drops that entry with a
  WARN, same rule as ALARM/VIEW/BANK.
- K4 warmup = ceil((|τ_A − τ_B| + 3·σ_source)·fs), 185 for W1,
  derived from τ_A/τ_B/σ_source DECLARED on `KERNEL LOAD` (never read
  from the kernels file); an explicit warmup on `XCONV SEALED`
  overrides and prints "declared, not derived"; a pair loaded without
  TAU/SIGMA has no default and `XCONV SEALED` then requires one
  explicitly.
- K5 printed, not gated: wall ms per sealed check; the patrol
  check's residual beside the sealed R, attributed to its three
  formula differences separately (full-length window, symmetric
  denominator, float32 inputs) — each attributed variant matches its
  numpy reference to ≤ 6.4e-14; max |R_patrol − R_sealed| = 23.68 at
  fake_48.

New engine surface: `KernelPair` (load-by-path with sha check, the
K4 derived-warmup rule) and `SealedCrossConvolution` (the frozen
formula plus the K5 attribution breakdown) in `dagdb/Sources/DagDB/`;
wired over the daemon socket/DSL/MCP as `KERNEL LOAD/INFO/LIST/CLOSE`
+ `XCONV SEALED`
(`dagdb/Sources/DagDBDaemonKit/DagDBCommandHandler+TwinKernel.swift`,
`DSLParser+Twin.swift` `parseKernel`). Read-only for reader sessions:
`XCONV SEALED`, `KERNEL INFO`, `KERNEL LIST`.

Fixtures: `dagdb/Tests/Fixtures/w1_kernels.json` (in repo, 144,554
bytes, sha256 pinned) and `w1_residuals_v1.json` (in repo, ≈34 KB,
the frozen-formula reference per trial plus the court's gate lines,
sha256 pinned, produced by `dagdb/scripts/w1_residuals.py`); the 190
W1 records themselves (18,580,321 bytes) stay out of repo, env
`DAGDB_W1_RECORDS`, sha256 pinned — absent skips the sealed tests,
present with the wrong hash FAILs, never a silent load of a
different fixture. The sealed run takes ≈10 minutes in a debug
build.

Suite: 655 tests, 39 skips without `DAGDB_W1_RECORDS` set (5 new
kernel skips: 3 in `SealedCrossConvolutionTests`, 2 in
`TwinKernelCommandTests`, on top of the prior branch's skips), 0
failures.

Not done: not merged to main (Haruth merges); kernels do not yet feed
the allocator court or the derived views.

---

## 2026-09-10 — derived views (spec line 4, second view family)

Branch `dag/derived-views`. A second view family over the alarm-set
world, sitting beside the allocator court that already covers spec
line 4: three views the twin's cortex lane needs, each judged against
numbers its own reference hand sealed the same day — front-aligned
energy features and a geometry-then-energy rung, the amended-letter
reflex with its tied sets and oracle-tie count, and the
arrival-geometry ceiling from τ alone. Kind of run: CONTROL /
RE-DERIVATION — every pin already exists, no learner number is asked
of the engine.

Gate contract: `docs/contracts/DERIVED_VIEWS_GATES_FROZEN.md` (1
amendment, letter e3's 3·S pair count; no gate bound moved). All gates
held exactly at S = 2/4/6/8:

- V1 Reflex hits: 3 / 11 / 15 / 18.
- V2 Oracle-tie hits: 233 / 72 / 76 / 65.
- V3 Tied sets: size min/median/max 52/77.0/129 · 1/5.0/129 ·
  1/4.0/129 · 1/2.0/23; frames with a tie (size > 1) = 300/253/242/231.
- V4 Geometry-then-energy hits (centroids from the 6966 train frames):
  38 / 28 / 29 / 39.
- V5 Ceiling: 0.069767 / 0.147287 / 0.209302 / 0.271318 (identifiable
  9/19/27/35 = unique 3/8/12/15 + groups 6/11/15/20; exact-twin pairs
  2495/1015/711/467).
- V6 daemon interface (VIEW LOAD/REFLEX/RUNG/CEILING/FEATURES/INFO/
  LIST/CLOSE, exact reply shapes) holds.
- V7 printed, not gated: wall time per view; near-edge candidate
  counts 22048/3814/2640/1017; rung margin (second − best distance,
  min over tied frames) 7.1e-4/1.6e-3/8.1e-4/2.1e-4.

New engine surface: a hand-rolled `NpzReader` for STORED
(uncompressed) npz archives — zip central-directory sizes, npy v1–v3
headers, f4/f8/i8 — no third-party code, because the fixture
(`cortex_v4_world.npz`, 15,145,646 bytes, out of repo, env
`DAGDB_CORTEX_V4_FIXTURE`, sha-pinned, skip if absent / FAIL on hash
mismatch) needed reading. `CortexFixture` loads and validates it
(shapes, label range 0..128, 6966 = 129·54 with every class exactly
54). `DerivedViews` computes the three views, the per-candidate
least-squares fit going through LAPACK `dgelsd_` (Accelerate) with one
workspace query per frame. Wired over the daemon socket/DSL/MCP/bridge
as an eight-verb `VIEW` family (LOAD/REFLEX/RUNG/CEILING/FEATURES/
INFO/LIST/CLOSE), registry prefix `v`, WAL opcode 0x2D, snapshot
`views` field (tolerant decode); view sets persist BY REFERENCE (path
+ sha256) — a missing or changed file on restore drops that entry with
a WARN, same rule as ALARM. Read-only for reader sessions: REFLEX,
RUNG, CEILING, FEATURES, INFO, LIST.

Tasks: V-S1 built `NpzReader` + `CortexFixture` and surfaced the
label/shape assertions. V-S2 built `DerivedViews` (arrivals, the
amended reflex with tied sets and the printed near-edge floor,
front-aligned energy features with 3·S per-(station, channel)
standardization, the centroid rung, and the ceiling under both
relations) — V1–V5 exact at every S. V-S3 wired the daemon `VIEW` verb
family, MCP tools, and the bridge's read-only allowlist.

Suite: 570 tests. 32 skips with neither fixture env set (the 9
pre-existing `DAGDB_W2_FIXTURE`-gated skips, unchanged, plus 23 new
`DAGDB_CORTEX_V4_FIXTURE`-gated skips: 14 in `TwinViewCommandTests`, 6
in `CortexFixtureTests`, 3 in `DerivedViewsTests`); 9 skips with
`DAGDB_CORTEX_V4_FIXTURE` set (the pre-existing `DAGDB_W2_FIXTURE`
skips only — unrelated fixture, still unset). 0 failures.

Not done: not merged to main (Haruth merges); the views registry does
not yet feed the allocator court (spec line 4's first family) or the
tick loop.

---

## 2026-09-10 — fold API (roadmap item 3)

Branch `dag/fold-api`. The E3 tier ladder — Kron/Schur fold of a rank
ring into the kept set, operator stored to Float32 between folds,
solves in Float64 via LAPACK `dgesv` — moved out of the sealed runner
(`E3Ladder/main.swift`, last arithmetic change 2026-08-26) into a
library call, `LadderFold.run(object:schedule:sources:)`, arithmetic
unchanged, and a daemon verb, `FOLD`. `e3-ladder` is now a thin CLI
over the library. `LadderFold.Object(engine:grid:)` reads the daemon's
own lanes — neighbors, edge weights, `nodeValue` as leak, rank — back
exactly as the runner's `Ladder.init` did; `LadderFold.Objects.control`/
`.court` write the frozen court objects INTO those same lanes before
reading them back, so a fresh daemon (neighbor table wiped, edges come
from `CONNECT`) folds whatever graph the lanes currently hold, hex
adjacency only if it was written there.

Gate contract: `docs/contracts/FOLD_API_GATES_FROZEN.md` (F1–F5). All
gates held:

- F1 control (in repo, `dagdb/Tests/Fixtures/e3_control_engine.json`,
  sha pinned): `kept_nodes`, `final_operator`, `folded_f1` bit-for-bit.
- F2 court ladders (out of repo, `DAGDB_E3_RUNS`; skip if absent, FAIL
  on hash mismatch): G1/G2 bit-for-bit against the sealed run files —
  G1 19 folds, ~153 s in a debug build (the court's ~1.6 s/profile was
  a release build).
- F3 the rebuilt `e3-ladder control` CLI's output sha equals the
  control fixture's pin.
- F4 daemon verbs — `FOLD RUN <maxRank> <keepRank> <f1> <f2> [<f3>]
  [CHECK l1,l2,...]`, `FOLD KEPT`, `FOLD SOURCE <1|2|3>`, `FOLD TIER
  <level|final> <1|2|3>`, `FOLD INFO` — bit-identical to the library
  call over the socket; all read-only, nothing persisted (the last
  result is held in the handler, recomputable from the lanes); a FOLD
  verb before any RUN is `ERROR not_found`. A FOLD RUN whose predicted
  kept-set size would overflow shm is rejected before any O(k³) work
  runs, via a configurable `shmBytes` capacity on the handler.
- F5 price, printed not gated: per fold, ring/eliminated/kept/wall ms;
  per tier, bytes = k²·4 + k·3·4.

Test suite: 544 Swift XCTest cases, 10 fixture-gated skips without
`DAGDB_E3_RUNS` set (9 with it). New: `LadderFoldTests.swift` (5,
library-level F1/F2/F3) and `TwinFoldCommandTests.swift` (17,
daemon-level F4), plus new `parseFold` grammar cases in
`DSLParserTwinTests.swift`.

Tasks: F-S1 built `LadderFold` against the frozen contract, moved the
runner's arithmetic verbatim, closed F1–F3. F-S2 wired the `FOLD` verb
family over the daemon socket, DSL grammar, and MCP, closed F4/F5.

---

## 2026-09-10 — spec 8 waveform mouth

Branch `dag/spec8-mouth`. Spec 8 of the twin's nine-line list: a frozen
bank Φ of T×K atoms (harmonic cos/sin columns plus Gabor atoms on a
center/frequency grid, each column unit-normalized), hosted by the
engine as `WaveBank`. Generating M waveforms is one matrix product
W = Φ·C via `cblas_sgemm`; fitting a target waveform back to
coefficients is a least-squares solve via LAPACK `dgelsd` (SVD); the
bank declares its own rank and condition number (`dgesdd`) at creation,
printed before any probe. Wired over the daemon socket and MCP as an
eight-verb `BANK` family (OPEN/GENERATE/FIT/NOISE/BENCH/INFO/LIST/
CLOSE), WAL opcode 0x2C, snapshot v7's `banks` field, following the same
log-first pattern as the other twin verb families.

Gate contract: `docs/contracts/SPEC8_MOUTH_GATES_FROZEN.md` (3
amendments, no gate bound moved). All gates held:

- G1 Φ bridge (control): max diff 0.0 against the numpy mouth (tol 2e-6).
- G2 W bridge (control): max diff 0.0, Frobenius relative error 2.1e-7.
- G3 out-of-bank noise law (claim, control bank): engine mean
  0.9816015 vs. law √(1−160/4096) = 0.9802742 (per-seed range
  0.9750986–0.9855909, bands 0.035 per seed / 0.008 mean); numpy mean
  0.9823351 printed beside it.
- G4 probe bridge (control): engine residual 0.9989332144 vs. the
  fixture's numpy residual 0.9989332557 (tol 1e-3).
- G5 in-bank sanity: residual ~1e-7 (bound 1e-5).
- G6 throughput (measured, not gated): 2.46e9 samples/s at K=160,
  2.83e9 at K=144, M=10000, best-of-3 — beside the numpy mouth's
  2.23e9 (control) / 1.95e9 (repair, one timing).
- G7 daemon round trips (WAL replay, snapshot v7 save/load) hold.
- G8 declaration: control bank rank 146 of K=160 (cond 5.6e15
  printed); repaired bank K=144, rank 144, cond 2.666132 (tol 0.01);
  aliasing message names harmonic 26 at 1560 Hz against Nyquist
  1500 Hz (fs 3000); repaired-bank probe residual 0.998949, noise
  mean 0.981743 vs. law 0.982265.

Finding: the sealed 160-atom reference bank is rank-deficient — at
H=32, harmonics 26..32 lie above Nyquist and alias exactly onto
harmonics 24..18, so fourteen of its atoms are linearly dependent
(true deficiency, float64 condition number 2.408e12, not a float32
artifact). The twin lane diagnosed and repaired it: H=24 keeps every
harmonic below Nyquist, giving K=144, full rank 144, condition number
2.666. The engine keeps the 160-atom bank as the sealed CONTROL object
for G1–G5 and adopts the repaired bank (K=144) as the default the
daemon opens; a spec whose top harmonic reaches Nyquist is refused
unless the caller writes `ALIASED` on the OPEN line.

Tasks: S1 built the library (`WaveBank.swift`) against the frozen spec
and surfaced the rank-deficiency finding. S2 wired the daemon/DSL/MCP
`BANK` verb family and the WAL/snapshot persistence. S3 ran G1–G7
against the fixture and the live socket. S3b re-derived amendment 2's
noise-law literal, caught a second author arithmetic slip (amendment
3), and closed out G8.

Suite: 506 tests, 9 fixture-gated skips (unchanged set), 0 failures.

Not done: the bank is not fused into the tick loop; no Metal path
(Accelerate on the CPU side of the UMA is the host).

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
  several checkouts share one dagdb working directory).

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
