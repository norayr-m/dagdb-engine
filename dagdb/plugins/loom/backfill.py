"""
Loom → DagDB backfill (T5).

Reads every event from a Loom-formatted JSONL event log, runs the adapter over it, produces:
  - loom_backfill.json  — full graph: nodes + edges + sidecars
  - loom_backfill.mcp   — replay script of DagDB MCP calls the external runner loops through
  - loom_backfill.report.txt — statistics, invariant checks

Runs against the live Loom with no daemon dependency. Pure function. No
live writes. Safe to run as many times as we want.
"""

from __future__ import annotations

import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from adapter import (
    MAX_NEIGHBORS,
    MAX_RANK_U32,
    TRUTH,
    IngestContext,
    ingest_stream,
)

OUT_DIR = Path(__file__).parent / "_backfill_out"
OUT_DIR.mkdir(exist_ok=True)


def read_events(path: Path) -> list[dict]:
    events: list[dict] = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError as e:
                print(f"  WARN skipping malformed line: {e}", file=sys.stderr)
    return events


def write_backfill_json(records, path: Path) -> None:
    out = {
        "version": 1,
        "max_rank": MAX_RANK_U32,
        "truth_codes": TRUTH,
        "nodes": [
            {
                "node_id": r.node_id,
                "rank": r.rank,
                "truth": r.truth,
                "lut": r.lut,
                "neighbors": r.neighbors,
                "sidecar": r.sidecar,
            }
            for r in records
        ],
    }
    path.write_text(json.dumps(out, indent=2, default=str))


def write_mcp_replay(records, path: Path) -> None:
    """Generate the MCP call sequence the external runner loops through."""
    lines = ["# DagDB MCP replay — Loom backfill", ""]
    for r in records:
        lines.append(f"# node {r.node_id}  truth={r.truth}  parents={r.neighbors}")
        lines.append(f"dagdb_insert(node_id={r.node_id}, rank={r.rank}, truth={r.truth}, lut={r.lut})")
        for p in r.neighbors:
            lines.append(f"dagdb_connect(src={r.node_id}, dst={p})")
        lines.append(f"sidecar_write({r.node_id}, {json.dumps(r.sidecar)!r})")
        lines.append("")
    path.write_text("\n".join(lines))


def write_report(records, events, path: Path) -> None:
    n = len(records)
    if n == 0:
        path.write_text("(empty)\n")
        return

    lines: list[str] = []
    lines.append("Loom → DagDB backfill report")
    lines.append("=" * 60)
    lines.append(f"total events ingested:     {n}")
    lines.append(f"raw events in jsonl:       {len(events)}")
    lines.append("")

    # Event-type distribution
    lines.append("event types:")
    type_counts = Counter(r.truth for r in records)
    inv = {v: k for k, v in TRUTH.items()}
    for code, cnt in sorted(type_counts.items()):
        lines.append(f"  {inv.get(code, '?'):25s} truth={code}  {cnt:6d}  ({100*cnt/n:.1f}%)")
    lines.append("")

    # In-degree distribution
    lines.append("in-degree distribution:")
    indeg = Counter(len(r.neighbors) for r in records)
    for d in sorted(indeg):
        lines.append(f"  degree {d}:  {indeg[d]:6d}  ({100*indeg[d]/n:.1f}%)")
    lines.append("")

    # Per-agent chain length
    lines.append("per-agent event count (= chain length):")
    agent_counts: Counter = Counter()
    for r in records:
        agent_counts[r.sidecar.get("agent", "?")] += 1
    for agent, cnt in agent_counts.most_common():
        lines.append(f"  {agent:20s} {cnt:6d}")
    lines.append("")

    # Rank span
    lines.append(f"rank span:  min={records[-1].rank}  max={records[0].rank}")
    lines.append(f"rank used:  {records[0].rank - records[-1].rank + 1} of {MAX_RANK_U32 + 1}")
    lines.append("")

    # Invariant checks
    lines.append("invariant checks:")
    ok_rank_monotone = all(records[i].rank > records[i+1].rank for i in range(n-1))
    ok_parents_older = all(
        all(p < r.node_id for p in r.neighbors) for r in records
    )
    ok_neighbor_cap = all(len(r.neighbors) <= MAX_NEIGHBORS for r in records)
    ok_no_self_loops = all(r.node_id not in r.neighbors for r in records)
    ok_no_dup_edges = all(len(set(r.neighbors)) == len(r.neighbors) for r in records)

    for name, ok in [
        ("rank strictly monotone decreasing", ok_rank_monotone),
        ("all parents older than child", ok_parents_older),
        ("all nodes <= 6 parents", ok_neighbor_cap),
        ("no self-loops", ok_no_self_loops),
        ("no duplicate edges", ok_no_dup_edges),
    ]:
        lines.append(f"  [{'PASS' if ok else 'FAIL'}] {name}")
    lines.append("")

    # Dialogue thread reconstruction
    lines.append("dialogue threads reconstructed:")
    threads: dict[tuple[str, str], list[int]] = defaultdict(list)
    for r in records:
        if r.truth == TRUTH["dialogue_turn"]:
            key = (r.sidecar.get("topic", ""), r.sidecar.get("file", ""))
            threads[key].append(r.node_id)
    for (topic, file), members in threads.items():
        label = topic or "(no topic)"
        lines.append(f"  {label:40s} {len(members)} turns, nodes {members[0]}…{members[-1]}")
    lines.append("")

    # Largest in-degree examples
    lines.append("top 5 most-connected nodes (in-degree):")
    for r in sorted(records, key=lambda r: -len(r.neighbors))[:5]:
        agent = r.sidecar.get("agent", "?")
        event = r.sidecar.get("event", "?")
        lines.append(f"  node {r.node_id:5d}  agent={agent:8s} type={event:20s} parents={r.neighbors}")
    lines.append("")

    path.write_text("\n".join(lines))


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: backfill.py <path-to-loom.jsonl>", file=sys.stderr)
        return 2
    loom_path = Path(sys.argv[1]).expanduser()
    if not loom_path.exists():
        print(f"ERR: {loom_path} not found", file=sys.stderr)
        return 1

    print(f"reading events from {loom_path}...")
    events = read_events(loom_path)
    print(f"  {len(events)} events")

    print(f"ingesting through adapter...")
    records, ctx = ingest_stream(events)
    print(f"  produced {len(records)} records")
    print(f"  final counter: {ctx.next_counter}")

    print(f"writing backfill artifacts...")
    write_backfill_json(records, OUT_DIR / "loom_backfill.json")
    write_mcp_replay(records, OUT_DIR / "loom_backfill.mcp")
    write_report(records, events, OUT_DIR / "loom_backfill.report.txt")

    print(f"\nreport:")
    print((OUT_DIR / "loom_backfill.report.txt").read_text())
    return 0


if __name__ == "__main__":
    sys.exit(main())
