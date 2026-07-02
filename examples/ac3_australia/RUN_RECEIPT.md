# AC-3 Australia — run receipt

**Date:** 2026-07-02
**Result:** `verify.py` exit 0 — **all 3 ticks match, BACK_EDGE verified.**

## Setup

- Daemon: `dagdb-daemon --grid 256` (test env, scratch instance,
  Apple M5 Max, maxRank 16), post-review binary.
- Graph: 21 register + support + keep nodes per
  `dagdb_encoding_spec.md` — canonical Russell–Norvig Australia
  3-coloring with WA pre-assigned to red.
- Reference: `reference_ac3.py` (pure-Python synchronous AC-3),
  compared cell-by-cell per tick.

## Output (verbatim tail)

```
Building reference trajectory (Python)...
  reference converged in 2 ticks
Setting up DagDB graph...
  21 registers allocated
Verifying initial state...
  tick=0  OK  WA={red} NT={blue,green,red} SA={blue,green,red} ...
Running ticks and comparing...
  tick=1   OK  WA={red} NT={blue,green} SA={blue,green} ...
  tick=2 * OK  (fixed point)
All 3 ticks match. BACK_EDGE verified.
```

## Status

This closes the provenance gap flagged in the 2026-06-24 deck-claims
audit: AC-3 on DagDB is **demonstrated** — committed encoding spec +
committed verifier + this run receipt. Still not a committed XCTest
(the verifier needs a live daemon); porting to an engine-level XCTest
(like `DagDBMicrocircuitTests`) is the remaining upgrade.
