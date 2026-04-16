# DagDB Engine

6-bounded ranked DAG database engine. Swift + Metal GPU compute on Apple Silicon.

## Presentations

- **[DagDB Overview](https://norayr-m.github.io/DagDB/)** — 24 slides: spec, architecture, LUT6, Morton Z-curve, Carlos Delta
- **[SQL Architecture: The Fork Problem](https://norayr-m.github.io/DagDB/sql-architecture.html)** — 26 slides: Postgres fork() vs Metal, daemon solution, DSL, UMA zero-copy
- **[Podcast (30 min)](https://norayr-m.github.io/DagDB/podcast.html)** — Emma-narrated audio walkthrough with chapters and speed control

## Demos

- **[Grid Demo](https://norayr-m.github.io/DagDB/grid-demo.html)** — Interactive ranked power grid visualization
- **[City Demo](https://norayr-m.github.io/DagDB/citydrt.html)** — City infrastructure variant

## What It Does

Every node connects to at most **6 directed edges**. Each node has a programmable **LUT6** (64-bit lookup table) that can implement any Boolean function of its 6 inputs. Nodes are organized in **ranks** (leaves to root) and evaluated leaves-up in parallel on the GPU.

## Architecture

```
DagDB/
├── Sources/
│   ├── DagDB/                    (core library)
│   │   ├── DagDBEngine.swift     (Metal GPU engine)
│   │   ├── DagDBState.swift      (node state buffers + LUT6 presets)
│   │   ├── DagDBGraph.swift      (graph builder: hub split, ghost nodes)
│   │   ├── DagDBEngine+Graph.swift (micro-time resonance, Paradox Horizon)
│   │   ├── DagDBDelta.swift      (Carlos Delta persistence, time-travel)
│   │   ├── HexGrid.swift         (Morton Z-curve, 7-coloring)
│   │   └── Shaders/dagdb.metal   (LUT6 + weighted tick kernels)
│   │
│   ├── DagDBDaemon/              (GPU daemon server)
│   │   ├── main.swift            (socket listener + shared memory)
│   │   ├── SocketServer.swift    (Unix domain socket)
│   │   └── DSLParser.swift       (graph query DSL)
│   │
│   └── DagDBCLI/main.swift       (test harness)
│
├── pg_dagdb/                     (PostgreSQL extension, Rust/pgrx)
│   ├── Cargo.toml
│   └── src/lib.rs                (dagdb_exec SQL function)
│
└── Tests/DagDBTests/             (27 tests, all pass)
```

## Quick Start

```bash
# Build
swift build

# Run tests (27/27)
swift test

# Start the daemon
.build/debug/dagdb-daemon --grid 256

# Test with netcat (in another terminal)
echo 'STATUS' | nc -U /tmp/dagdb.sock
echo 'TICK 10' | nc -U /tmp/dagdb.sock
echo 'NODES AT RANK 0' | nc -U /tmp/dagdb.sock
```

## SQL Access (Daemon + Postgres)

Requires PostgreSQL 17 + Rust. See `pg_dagdb/` for the pgrx extension.

```bash
# Start daemon (terminal 1)
.build/debug/dagdb-daemon --grid 256

# In psql (terminal 2):
CREATE EXTENSION pg_dagdb;
SELECT * FROM dagdb_exec('STATUS');
SELECT * FROM dagdb_exec('TICK 100');
SELECT * FROM dagdb_exec('NODES AT RANK 2 WHERE truth=1');
SELECT * FROM dagdb_exec('TRAVERSE FROM 42 DEPTH 3');
```

## Test Results

```
27/27 tests pass
1K nodes: 0.45 ms/tick
1M nodes: 0.71 GCUPS
All 7 verification gates: GREEN
```

## Requirements

- macOS 14+ (Sonoma)
- Apple Silicon (M1/M2/M3/M4/M5)
- Swift 5.9+
- PostgreSQL 17 + Rust (for pg_dagdb extension, optional)

## Humble Disclaimer

This is an amateur engineering project. We are not HPC or database professionals and make no competitive claims. Numbers speak; ego does not. Errors likely.
