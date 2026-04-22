# DagDB 4-Cycle Runtime Engine

> **Humble disclaimer.** Amateur engineering project. Research prototype.
> We are not HPC professionals and make no competitive claims. Numbers
> speak. Errors likely.

A forward-only runtime that executes "thoughts" on a DagDB substrate.
Paper 4 scaffold. Lives at the repo root (`Sources/`, `Package.swift`)
so it can be built independently of the database layer under `dagdb/`.

One thought = one full 4-cycle engine pass:

```
Queen₀ ──forward wave──▶ Leaves
                            │ mirror
Mirror-Queen ◀─backward wave─ Mirror-Leaves
                            │ mirror at queen
... next thought extends forward in rank ...
```

The engine does NOT backpropagate. All passes are forward in rank
number. The "backward" wave is backward topologically but forward in
rank — it travels through the mirrored copy of the DAG.

## Relation to Γ (from DRT v2)

Γ is local, the engine is the orchestration. A single Γ_{ij} is the
growth operator for the j-th observer of the i-th external subject —
acting on the observer's internal basis of the subgraph about subject
i. The 4-cycle engine is the runtime schedule that fires the right
Γ_{ij} at the right tick.

The brain has an **empathic mirror land** — a region functioning as a
parallel graph processor hosting many Γ_{ij} concurrently. The mirror
neuron system is the biological analog. The engine runs not a single
4-cycle snake but a dynamic ensemble of many 4-cycle snakes, each with
its own Γ_{ij} set, each terminating when its local e-collapse fires.

| level | object |
|---|---|
| single direction | basis vector e_{ij,p} inside observer j's space for subject i |
| single observer | Γ_{ij} acting on H_{ij}(t) |
| parallel processor | many Γ_{ij} firing concurrently = empathic mirror land |
| one thought on one subject | one 4-cycle snake completing |
| whole-brain activity | dynamic ensemble of many concurrent 4-cycle snakes |

## Completeness (informal claim)

If the solution to a given query is reachable within the closure of
the loadable library under the Turing alphabet (the set of subgraph
primitives the engine can combine), then sufficient epochs guarantee
e-collapse. Time to convergence is unbounded; eventual outcome is
assured. Unsolvable queries never converge — the engine expands
without bound. This matches the relationship between Turing-
completeness and the halting problem: convergence is semi-decidable.

## Core properties

- **Forward-only** — no gradient descent anywhere.
- **VBR loops** — variable-bit-rate rigor: cheap pass first, deepen
  only on high-complexity nodes.
- **Two mirrors** — reflect at leaves, reflect at queen. Ouroboros
  prevented by topology (rank monotonicity), not by dynamical rules.
- **4-cycle** — forward descend, mirror-at-leaves, backward ascend,
  mirror-at-queen. One cycle = one thought.
- **Deterministic** — tick function from (graph, state) → (graph',
  state').
- **Complexity-on-demand** — subgraphs get loaded from the library as
  the wave needs them, not pre-loaded.
- **e-collapse convergence** — entropy grows during fat phase, flips
  sign after Winston threshold, snake thins.
- **Structural learning** — Γ_i grows the functional subspace
  Darwinian-style. Used directions stay, silent ones decay. No
  weights.

## Inputs / outputs

**Inputs**
- Query (a pattern or question placed at the queen).
- DagDB substrate with subgraphs stored across ranks.
- Library (external knowledge loaded into the DAG on demand).
- Budget B (computational budget — bounds the accessibility norm).

**Outputs**
- Answer (the aggregate at the mirror-queen after convergence).
- Updated DagDB (new scaffold: the subgraphs that contributed to the
  successful e-collapse are now permanent).
- VBR receipt (what rigor class each tick lived in; telemetry only).

## Build and run (engine layer only)

```
swift build
.build/debug/dagdb-engine-cli
```

See `Sources/DagDBEngine/` and `Sources/DagDBCLI/`. The engine depends
on nothing under `dagdb/` — the two layers are decoupled.

## Not in scope (for the engine layer)

- GPU acceleration (lives in the database layer under `dagdb/`).
- Weight-based learning of any kind.
- Cycles in the graph topology.
- Probabilistic sampling inside the engine.

## Paper

The paper scaffold is in `paper/dagdb_intermezzo.tex` (PDF alongside).
