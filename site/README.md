# DagDB — presentation assets

Slides, podcasts, and demos for DagDB. The engine source lives
one level up in this same repo — browse [`../`](../) for code,
tests, docs, and the top-level README.

These assets used to live at `github.com/norayr-m/DagDB` as a
separate repository. They were folded in on 2026-04-22 so one
repository holds both the engine and the presentation material
it references. Old `norayr-m.github.io/DagDB/*` URLs redirect
here (or to archived copies).

## What is this?

Every node connects to at most **6 directed edges**. That single constraint makes the entire system viable:

- **LUT6**: Every 6-input Boolean function fits in one `UInt64` (64-bit lookup table)
- **ELLPACK**: Fixed 6 columns = GPU-friendly sparse matrix format
- **Morton Z-curve**: Connected nodes land in the same cache line
- **7-coloring**: Lock-free parallel update (no two adjacent nodes update simultaneously)
- **Carlos Delta Transport**: 50x compression, full ACID, bidirectional time-travel

## Assets

The slide decks, podcasts, and demos that built DagDB's public
story.

### Presentation

**[View the DagDB presentation — 24 slides](https://norayr-m.github.io/dagdb-engine/site/)**

Specification, architecture, and resolved design questions. Press Space to narrate, arrow keys to navigate.

### Podcast

**[Listen to the DagDB Podcast](https://norayr-m.github.io/dagdb-engine/site/podcast.html)** — 30 minutes, web player with chapter navigation and speed control. Covers both presentations end-to-end.

### SQL Architecture — The Fork Problem

**[View the SQL Architecture deep-dive](https://norayr-m.github.io/dagdb-engine/site/sql-architecture.html)**

26 slides on how to connect PostgreSQL to a Metal GPU engine. Covers the fatal `fork()` vs Metal collision, the daemon/shared-memory solution, and the graph DSL. Press Space to narrate.

### Proof-of-Concept Demos

- **[Grid Demo](https://norayr-m.github.io/dagdb-engine/site/grid-demo.html)** — Interactive ranked power-grid visualization (Substations, Feeders, Transformers, Meters).
- **[City Demo](https://norayr-m.github.io/dagdb-engine/site/citydrt.html)** — City infrastructure variant with Delta Replay Transport.

## Status

Engine landing: [`../README.md`](../README.md) — u64 rank, snapshot v3, MVCC snapshot-on-read, bfsDepths, rankPolicy, SET_RANKS_BULK, Loom adapter. 98 Swift + 16 Python tests green.

This subdirectory is curation + narration; the engine lives in [`../dagdb/`](../dagdb/).

## Humble Disclaimer

This is an amateur engineering project. We are not HPC or database professionals and make no competitive claims. Numbers speak; ego does not. Errors likely.
