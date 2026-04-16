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

**Step 1: Build**

```bash
swift build
```

**Step 2: Run tests**

```bash
swift test
```

**Step 3: Start the daemon** (keep this terminal open)

```bash
.build/debug/dagdb-daemon --grid 256
```

**Step 4: Query it** (open a second terminal)

```bash
echo 'STATUS' | nc -U /tmp/dagdb.sock
echo 'TICK 10' | nc -U /tmp/dagdb.sock
echo 'GRAPH INFO' | nc -U /tmp/dagdb.sock
echo 'SET 0 TRUTH 1' | nc -U /tmp/dagdb.sock
echo 'NODES AT RANK 0' | nc -U /tmp/dagdb.sock
echo 'TRAVERSE FROM 0 DEPTH 2' | nc -U /tmp/dagdb.sock
```

That's it. No PostgreSQL needed. No Rust needed. Just Swift and netcat.

## SQL Access (Optional, Advanced)

If you want SQL access via PostgreSQL, you need PostgreSQL 17 and Rust installed. See `pg_dagdb/` directory for the pgrx extension. The daemon must be running first.

**What is Cargo?** Cargo is the Rust package manager and build tool — like `pip` for Python or `npm` for JavaScript. `cargo build` compiles Rust code. `cargo install` installs Rust tools. [Install Rust](https://rustup.rs/) to get it.

**What is pgrx?** A Rust framework for building PostgreSQL extensions. It generates the C glue code that Postgres needs, so you write Rust instead of C.

```bash
# Install prerequisites
brew install postgresql@17
cargo install cargo-pgrx

# Build and install the extension
cd pg_dagdb
cargo pgrx install --pg-config=/opt/homebrew/opt/postgresql@17/bin/pg_config

# Create database and use it
createdb dagdb
psql dagdb -c "CREATE EXTENSION pg_dagdb;"
psql dagdb -c "SELECT * FROM dagdb_exec('STATUS');"
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
