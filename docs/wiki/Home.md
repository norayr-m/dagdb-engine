# Welcome to DagDB

> Amateur engineering project. We are not HPC professionals and make
> no competitive claims. Numbers speak. Errors likely.

Hi. If you've never heard of DagDB before, this is the right page.
Five-minute read.

---

## What is DagDB, in one paragraph

DagDB is a database where every record is a tiny Boolean-logic gate.
You wire the gates together into a graph, and the database evaluates
the whole graph on the GPU in parallel. The graph is acyclic and
each gate has at most six inputs. State persists like a real
database (snapshots, write-ahead log, multi-version reads). One
machine — currently a Mac — holds the whole thing.

If "tiny Boolean-logic gates" sounds hardware-y, that's because the
inspiration is the field-programmable gate array (FPGA): the same
truth-table-as-data trick lives at DagDB's core. The differences
from an FPGA are that DagDB is software, mutable while running, and
queryable like a database.

---

## A 30-second example

Build an `AND` gate from two inputs. The daemon speaks a small
text protocol over a Unix socket:

```
SET 0 RANK 1                # node 0 is an input — at rank 1
SET 1 RANK 1                # node 1 is an input — at rank 1
SET 2 RANK 0                # node 2 is the AND output — at rank 0
SET 2 LUT AND               # tell node 2 it computes "AND"
CONNECT FROM 0 TO 2         # wire input 0 into node 2
CONNECT FROM 1 TO 2         # wire input 1 into node 2
SET 0 TRUTH 1               # input 0 = true
SET 1 TRUTH 1               # input 1 = true
TICK 1                      # evaluate one step
GET 2 TRUTH                 # → OK GET node=2 truth=1
```

That's it. Three nodes, one tick, an AND gate runs.

You can scale this up. A Game of Life cell is ~9 inputs of logic,
which fits in two LUT6 nodes. A 1024×1024 Game of Life grid is
about two million nodes, ticks under 5 ms on an M5 Max GPU. We
have run 100 million live cells; the engineering goal is 100
billion (with tile streaming).

---

## What DagDB is good at

- **Storing structured Boolean computations.** Boolean networks,
  digital-circuit logic, constraint propagation, cellular automata,
  configurable per-node truth tables.
- **Iterating them in parallel.** GPU evaluation walks the graph
  rank-by-rank; on M5 Max we measure ~2 ms per tick at one million
  nodes.
- **Persisting them durably.** Snapshots are atomic on Apple SSDs
  (full F_FULLFSYNC discipline). A write-ahead log lets you replay
  every mutation. Multi-version reads (MVCC) let multiple clients
  query a consistent snapshot while writers continue.
- **Querying them as graphs.** Breadth-first search, ancestry
  walks, subgraph similarity (eight metrics including Jaccard,
  rank-L1, Weisfeiler-Lehman), and a fast secondary index for
  truth-by-rank lookups.
- **Carrying floating-point solver state alongside the gates.** A
  parallel `Float32` weight/value lane rides beside the Boolean
  record (per-edge weight, per-node value), so an iterative smoother
  or an exact tier-elimination solver can run directly on the
  engine's own fabric instead of a shadow array. Since 2026-09-05
  the engine also ships seven small "twin primitive" types —
  deterministic replayable random streams, a sealed knapsack
  allocator, a cross-ear identity check, a geared recording
  odometer, a rational-gear master clock — each one code for a
  frozen contract from outside work; they're tested library types
  today, not yet reachable through the DSL or MCP surface. 249 Swift
  tests green as of 2026-09-05. See `ARCHITECTURE.md` §13 for detail.

---

## What DagDB is NOT

We say this clearly because misreading the surface costs hours.

- **Not a general-purpose graph database.** No labels, no Cypher,
  no SQL, no edge properties, no full-text search. It's structurally
  much narrower than Neo4j or DGraph.
- **Not a relational database.** No tables, no joins, no schema
  beyond "every node is a Boolean gate with up to six inputs."
- **Not a programming language runtime.** Each node is a *Boolean
  function*. There are no variables, no loops, no recursion within
  a tick, no arithmetic types beyond what you encode bit-by-bit.
- **Not a general AI reasoner or thinking machine.** A LUT6-based
  DAG can express many useful things — constraint satisfaction,
  Boolean network dynamics, message-passing algorithms — but it
  doesn't have variables, quantifiers, search/planning, or
  probabilistic truth. It's a fast specialised substrate, not a
  general-purpose AI engine.
- **Not a neural network framework.** No floating-point weights,
  no gradients, no training loop. (You can encode a quantised
  Boolean neural network on it, but that's an application choice,
  not what the substrate provides.)
- **Not a SAT solver.** You can express SAT clauses on it and run
  propagation, but there's no built-in DPLL/CDCL — that's an
  application built on top.

If your problem doesn't fit naturally into "a fixed graph of
small Boolean functions, evaluated repeatedly," DagDB is probably
the wrong tool. Honest.

---

## What problems fit naturally

- **Cellular automata.** Game of Life, hex CA, Adamatzky-style
  Physarum networks — each cell is a few LUT6 nodes, neighbours
  wire up directly.
- **Digital circuits.** Counters, finite state machines, small
  CPUs — anything you would write in Verilog using `assign` and
  `reg` translates to LUT6 nodes plus (since BACK_EDGE) latches.
- **Constraint propagation.** Arc consistency (AC-3), unit
  propagation, propagator-based solvers. The substrate iterates
  to fixed points naturally.
- **Boolean network dynamics.** Kauffman-style random Boolean
  networks at the edge of chaos, attractor analysis, perturbation
  experiments.
- **Logic-circuit synthesis experiments.** And-inverter graphs
  (AIGs), reduced ordered binary decision diagrams (ROBDDs) —
  each node is one LUT6, composition operations work bit-wise on
  the truth-table integer.
- **Digital twins of biology where state is local + Boolean.**
  Hepatocyte signalling networks, gene regulatory networks where
  every interaction is small-fan-in.

---

## How DagDB is structured (one diagram)

A DagDB graph is a *ranked DAG*. Higher-rank nodes feed lower-rank
nodes. Every edge points from a higher-rank source to a lower-rank
destination. The whole graph is acyclic by construction.

```
   rank 2 (inputs)                     rank 1 (inner)         rank 0 (outputs)
       Leaf A ────────────────┐
                              │
                              ├───►  AND2 ────────────────────► OUT1
                              │
       Leaf B ────────────────┘                                   ▲
                                                                  │
       Leaf C ────────────────►  NOT  ──────► OR2 ────────────────┘
                                              ▲
       Leaf D ───────────────────────────────┘
```

Each tick:
1. Inputs (rank 2) hold their truth values.
2. The engine evaluates rank 1 from its inputs, in parallel on
   the GPU.
3. Then rank 0 from its inputs, also in parallel.
4. Each lower rank reads the values produced higher up.

That's all. No backtracking, no message passing, no scheduler.
Just rank-walk, parallel evaluation, repeat.

---

## What's a "LUT6"?

Every node carries a 64-bit integer that *is* its truth table.

```
Inputs      Bit position    Output
i5 i4 i3 i2 i1 i0   in 64-bit int    is f(i5..i0)
─────────────────   ──────────────   ─────────────
 0  0  0  0  0  0    bit 0           0 (e.g.)
 0  0  0  0  0  1    bit 1           1
 0  0  0  0  1  0    bit 2           0
 0  0  0  0  1  1    bit 3           1
 ...                 ...             ...
 1  1  1  1  1  1    bit 63          1
```

To compute the gate's output, the engine packs the six input
truths into a 6-bit index, looks up that bit in the LUT integer,
and the answer is the output. One memory read per evaluation. Same
trick FPGAs use.

This works for any function of up to six inputs. AND6 is one
specific 64-bit value (`0x8000000000000000`); OR2 is another
(`0xEEEEEEEEEEEEEEEE`); a custom 4-input majority is yet another.
You can compute these by hand, use named presets (`SET node LUT
AND`, `SET node LUT MAJ`, etc.), or compose two LUTs into a third
with `COMPOSE AND src1 src2 INTO dst` for graph simplification.

---

## State that persists between ticks (BACK_EDGE)

The DAG itself is acyclic — but real systems have feedback. DagDB
solves this with a typed second edge type called `BACK_EDGE`:

- A normal edge feeds combinational logic during a tick.
  Rank invariant holds.
- A `BACK_EDGE` from a "writer" node back to a register node
  *latches* between ticks. The engine evaluates all combinational
  logic first, then copies the writer's truth into the register's
  truth. That register reads its new value at the next tick.

This lets you build counters, finite state machines, Hopfield-style
recurrent networks, and constraint propagation algorithms that
iterate to fixed points — without violating the "graph is acyclic"
invariant. The cycle exists in time, not in the graph.

If you have used Verilog: combinational edges are `wire`,
`BACK_EDGE` destinations are `reg`. Same pattern.

---

## Five-minute path forward

1. **[quick-start.md](quick-start.md)** — build the daemon, open a
   socket, run a real query.
2. **[dsl.md](dsl.md)** — the full text protocol (SET, CONNECT,
   TICK, GET, NODES, EVAL, BFS_DEPTHS, SAVE, LOAD, …).
3. **[queries.md](queries.md)** — when to use BFS vs ancestry vs
   similarity vs the secondary index.
4. **[data-and-persistence.md](data-and-persistence.md)** — where
   bytes live on your disk, how to keep them out of git, the
   `DAGDB_DATA_ROOT` policy.

Want the deeper picture? See
[`ARCHITECTURE.md`](../../ARCHITECTURE.md) at the repo root for
internals; the
[`README.md`](README.md) page in this wiki is the complete topic
index.

---

## A note on honesty

DagDB is a single-developer-plus-AI experiment. The numbers we
quote are measured on one machine (an M5 Max). The architectural
moves — ranked DAG, LUT6, GPU-parallel evaluation, BACK_EDGE,
tile streaming for 10¹¹ — are individually known patterns from
prior art (FPGAs, Pregel-style vertex-centric compute, synchronous
digital circuits, the Tero/Adamatzky work on slime-mold computing).
What is novel is the combination as a single coherent engine, not
any single ingredient.

If something on this wiki turns out wrong when you build to it,
file an issue. The code is the source of truth; the docs lag.
