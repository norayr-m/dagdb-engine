# Nested LUTs — compiled microcircuits on the DAG

## The idea in one paragraph

A single DagDB node is one **LUT6**: a 64-bit truth table mapping six
input bits to one output bit. On its own that is tiny — you cannot put
Ohm's law in one lookup table. Nested LUTs remove the ceiling: wire many
LUT6 nodes together across ranks — the output of one feeding an input
slot of the next — and the group becomes a compiled Boolean
**microcircuit**. Because Boolean circuits are universal, a LUT6 network
can approximate any function over quantized inputs to arbitrary
precision: pick fixed-point widths, quantize the range, compile the
arithmetic into gates. A node stops being "one small truth table" and
becomes "a circuit that lives at a graph address." Depth buys precision.

## Why nesting is *necessary*, not just nice

A LUT6 reads at most **6 input bits**. Any function of more than 6 bits
is therefore out of reach for a single node — not approximately, but
provably: a 6-of-N input projection merges input pairs that need
different outputs.

This is measurable. For the 4-bit × 4-bit product `P = I·R`
(8 input bits, 8 output bits), an exhaustive census shows how many
input bits each product bit depends on:

| bit | P₀ | P₁ | P₂ | P₃ | P₄ | P₅ | P₆ | P₇ |
|-----|----|----|----|----|----|----|----|----|
| depends on | 2 | 4 | 6 | **8** | **8** | **8** | **8** | **8** |

P₂ is the last bit a single LUT6 could ever compute. Five of eight
bits are beyond any single node.

## The demonstrated microcircuit (committed test)

`Tests/DagDBTests/DagDBMicrocircuitTests.swift` builds Ohm's law
`V = I·R` (4-bit × 4-bit → exact 8-bit product) as a real nested
network and verifies it exhaustively on the Metal engine:

| | |
|---|---|
| gates | **40 LUT6 nodes** — 16 AND2 partial products + carry-save (Wallace) XOR/MAJ adders |
| edges | 96 (max fan-in 3; the engine allows 6) |
| depth | **7 ranks** — one `TICK` settles the whole network |
| result | exact `I×R` for **all 256 inputs**, verified on GPU |

The honest baseline: the **optimal** single LUT6 per output bit, found
by exhaustive search over all 28 six-of-eight input subsets with
majority-vote truth tables — the best any single node can possibly do:

| bit | P₀ | P₁ | P₂ | P₃ | P₄ | P₅ | P₆ | P₇ |
|-----|----|----|----|----|----|----|----|----|
| optimal single LUT6, errors/256 | 0 | 0 | 0 | **56** | **52** | **36** | **14** | **4** |
| nested network, errors/256 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

Numerically the best single-LUT6 bank reconstructs the product with an
RMS error of 14.9 LSBs (5.8 % of full scale, worst error 48); the
nested network is exact.

## How to build one (the idioms)

1. **Gates are LUTs.** Any k-input gate (k ≤ 6) is one node: build the
   64-bit LUT by evaluating the gate over all input indices (absent
   neighbor slots read 0, so replicate over don't-cares).
2. **Slot order = LUT bit order.** The i-th `CONNECT` into a node lands
   in input slot i, which is LUT index bit i. Wire each gate's inputs
   in the order its truth table expects.
3. **Ranks by longest path to outputs.** `rank(output) = 0`,
   `rank(gate) = 1 + max(rank(consumers))`. This satisfies the engine
   invariant `rank(src) > rank(dst)` on every edge by construction.
   Set all ranks before connecting (CONNECT validates ranks).
4. **Depth budget.** Depth must fit under the daemon's `maxRank`
   (default 16). Prefer carry-save (Wallace) reduction over
   ripple-carry chains — the mult4 array multiplier is depth ~16 as a
   ripple design and depth 7 carry-save.
5. **Inputs are constant LUTs.** A node with no in-edges evaluates
   `LUT[0]`, so drive test vectors by setting input nodes' LUTs to
   `CONST0`/`CONST1`. One `TICK` then propagates inputs → outputs,
   because the engine evaluates ranks top-down within a single tick.

## Performance framing (honest numbers)

Evaluation runs at the substrate's measured rate — **0.71 GCUPS at
1M nodes** on an M5 Max (see [Benchmarks](Benchmarks.md)) — in
parallel across every microcircuit instance on the graph. The win is
not per-gate speed; it is that a compiled network evaluates *in place,
on graph data, next to the rest of the DAG*, with mid-tick
introspection of any internal node.

## Scope honesty

Demonstrated: forward-mode compilation of a **known** function into an
exact nested network, verified exhaustively. Not demonstrated: adaptive
runtime refinement, assimilation from measurements (the inverse
problem), automatic synthesis from arbitrary specs, or wide operands.
Those are design directions, not claims.

See also: [Microcircuit compilation](microcircuit-compilation.md)
(bulk-install recipe for many instances), [Invariants](invariants.md),
[DSL](dsl.md).
