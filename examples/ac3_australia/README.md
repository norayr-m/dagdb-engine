# AC-3 Australia — v1 reference demo for BACK_EDGE primitive

This directory contains the v1 verification demo for DagDB's BACK_EDGE
primitive: AC-3 arc consistency on the classic Australia map-coloring
problem. The demo proves that BACK_EDGE-driven iteration converges to
the same arc-consistent state as a known-correct Python reference.

## Why this demo

BACK_EDGE adds typed back-edges to DagDB so combinational logic can
latch state across tick boundaries (synchronous-circuit register
pattern). To verify the primitive works correctly, we need a
problem that:

- Has a known-correct ground truth (Python reference matches).
- Exercises iteration to convergence (multiple ticks, visible state
  change per tick).
- Is small enough to verify by hand and inspect tick-by-tick.
- Uses textbook semantics (any AI/CS reader recognizes it).

AC-3 on Australia map coloring fits all four. AC-3 is a constraint
propagation algorithm that iteratively prunes inconsistent values
from each variable's domain until no further pruning is possible.
Australia is the textbook AC-3 example (Russell & Norvig).

## Files

- `reference_ac3.py` — pure-Python AC-3 implementation. Ground truth.
  Run it; output is the converged domain assignment. The DagDB
  version must produce identical output.
- `australia.py` — problem definition (regions, adjacencies, color
  set). Imported by the reference; mirrored in the DagDB encoding.
- `dagdb_encoding_spec.md` — exact node layout for encoding the
  same problem on DagDB-with-BACK_EDGE.
- `verify.py` — comparison harness (run after the DagDB
  version exists; compares per-tick domain state between reference
  and DagDB).

## Problem variant

**Australia 3-coloring with pre-assignment.** Western Australia (WA)
is pre-assigned the color `red`. AC-3 must propagate this constraint:
WA's neighbors (NT, SA) lose `red` from their domains. Subsequent
arcs may further reduce.

3 colors instead of 4 because Australia is 3-chromatic; with 4
colors, no pre-assignment, AC-3 trivially leaves all domains intact
(boring). 3 colors + pre-assignment forces visible propagation.

## Expected behavior

- Initial state: WA domain = {red}, all others = {red, green, blue}.
- AC-3 processes adjacency arcs in queue order.
- After convergence: WA={red}, NT={green,blue}, SA={green,blue},
  Q={red,green,blue}, NSW={red,green,blue}, V={red,green,blue},
  T={red,green,blue}.
- Convergence in ~3–5 AC-3 iterations (Python). Equivalent number of
  DagDB ticks (one tick = one iteration of "propagate all arcs").

Note that AC-3 does not produce a unique coloring — it produces an
arc-consistent domain assignment. Full coloring requires backtracking
search on top of AC-3, which is out of scope for v1. The substrate
test is "did DagDB reach the same arc-consistent state as Python."

## How to use this

1. Read `dagdb_encoding_spec.md` to understand node layout.
2. Build the encoding: register nodes for `domain(region, color)`,
   combinational nodes for `support` and `keep` computations,
   BACK_EDGEs from `keep` outputs back to `domain` registers.
3. Run the simulation in DagDB.
4. Read back domain state at each tick via NODES or shm export.
5. Run `verify.py` to compare DagDB tick-trajectory to Python
   reference. Per-cell match.

If Python and DagDB agree on every tick, BACK_EDGE works.

## Status

Verified — see `RUN_RECEIPT.md` (2026-07-02): `verify.py` exit 0,
all ticks match the Python reference, fixed point in 2 ticks.
