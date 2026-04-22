"""
loom_to_dagdb.adapter
---------------------

Pure-function event → DagNode translator for the event-log-to-DagDB migration
(adapter ticket).

No DagDB daemon dependency: this module only produces the values that a
caller will hand to the DagDB Python client. That means it is trivially
unit-testable and safe to drop into capture_latest.py once T1 (u32 rank
refactor) ships on Tuesday.

Schema (locked 2026-04-20 via Dag's review):
- rank       = MAX_RANK - insertCounter()        strictly monotonic, u32
- truth      = event-type code (per-instance)    1-31 core, 32-255 plugin
- lut        = LUT6Preset.identity               no compute on event nodes
- neighbors  = <= 6 causal parents               (6-input bound)
- sidecar    = the original Loom JSONL entry     keyed by node_id

Truth codes (core, 1-31):
    1 = response
    2 = dialogue_turn
    3 = ceremony
    4 = drop_written      (reserved, not emitted yet)
    5 = meeting_contribution (reserved)
    6 = bzz               (reserved)
    7 = status            (reserved)

Edge kinds (all point newer -> older):
    prev_by_agent          most recent prior event by the same agent
    parent_response        for a bzz / dialogue turn: the response it came from
    dialogue_prev_turn     previous turn in the same dialogue thread
    meeting_parent         the meeting context this contribution belongs to
    cites_drop             any drop referenced in the event body (cap 4)
    triggered_by_external  externally-triggered kickoffs, operator injections

Slot accounting is per-parent, not per-kind. cites_drop is capped at 4 so
prev_by_agent / parent_response / dialogue_prev_turn stay addressable.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Iterable, Optional, Protocol, runtime_checkable

try:
    import numpy as np
except ImportError:  # tests run without numpy; adapter uses plain lists as fallback
    np = None  # type: ignore

# --- Constants -----------------------------------------------------------

MAX_RANK_U32 = (1 << 32) - 1  # 4 294 967 295

LUT6_IDENTITY = 0xFFFFFFFFFFFFFFFF  # placeholder; DagDB defines its own const

# Truth codes (core: 1-31)
TRUTH = {
    "response": 1,
    "dialogue_turn": 2,
    "ceremony": 3,
    "drop_written": 4,
    "meeting_contribution": 5,
    "bzz": 6,
    "status": 7,
}

# Per-parent cap on cites_drop edges
CITES_DROP_CAP = 4

# Six neighbour slots total
MAX_NEIGHBORS = 6


# --- RankPolicy protocol (matches plugins/biology/rank_policies.py) -----


@runtime_checkable
class RankPolicy(Protocol):
    """
    Assign DagDB ranks to a batch of nodes.

    Mirrors the Protocol Dag shipped in the biology plugin today. The Loom
    uses single-node inserts, not batches, but conforms to the same shape so
    that a future unified rank-policy module can host all implementations.
    """

    def assign_ranks(self, node_count: int, max_rank: int, **context) -> list[int]:
        ...


class LoomInsertCounterPolicy:
    """
    The Loom's rank policy: strict insert-counter. The policy is stateless —
    the caller hands in the current counter value via context. This deviates
    from Dag's initial sketch (which held the counter internally) to keep
    the adapter purely functional and easy to test.

    Usage:
        policy = LoomInsertCounterPolicy()
        ranks = policy.assign_ranks(node_count=1, max_rank=MAX_RANK_U32,
                                    counter=ctx.next_counter)
        # ranks[0] == MAX_RANK_U32 - ctx.next_counter
    """

    def assign_ranks(self, node_count: int, max_rank: int, **context) -> list[int]:
        if node_count != 1:
            raise ValueError("Loom inserts one node at a time")
        counter = context.get("counter")
        if counter is None:
            raise ValueError("LoomInsertCounterPolicy requires counter= in context")
        return [max_rank - counter]


# --- Node shape ----------------------------------------------------------


@dataclass
class DagNodeRecord:
    """What a single Loom event becomes in the DagDB Loom instance."""

    node_id: int
    rank: int
    truth: int
    lut: int = LUT6_IDENTITY
    neighbors: list[int] = field(default_factory=list)
    sidecar: dict = field(default_factory=dict)

    def assert_valid(self) -> None:
        assert 0 <= self.rank <= MAX_RANK_U32, f"rank {self.rank} out of u32 range"
        assert 1 <= self.truth <= 255, f"truth {self.truth} out of byte range"
        assert len(self.neighbors) <= MAX_NEIGHBORS, (
            f"node {self.node_id} has {len(self.neighbors)} parents > {MAX_NEIGHBORS}"
        )
        for n in self.neighbors:
            assert n < self.node_id, (
                f"parent {n} of node {self.node_id} violates rank invariant"
            )


# --- Context the adapter reads from (not written to) --------------------


@dataclass
class IngestContext:
    """
    State the caller maintains across calls to event_to_node().

    The adapter is a pure function over (event, context) -> (node, context').
    The context tracks: next insert counter, last event per agent, active
    dialogue thread state, and a lookup from drop filename -> node_id.

    The caller (Stop-hook, backfill script) owns the context. The adapter
    does not mutate it in place — call apply_ingest() to get the updated
    context.
    """

    next_counter: int = 0
    last_event_by_agent: dict[str, int] = field(default_factory=dict)
    # dialogue_key = (topic, file) -> last_turn_node_id
    last_dialogue_turn: dict[tuple[str, str], int] = field(default_factory=dict)
    # drop_filename -> node_id; populated when a drop_written event is ingested
    drop_node_by_filename: dict[str, int] = field(default_factory=dict)


# --- Core adapter --------------------------------------------------------


_DROP_CITATION = re.compile(r"\b(\d{4}-\d{2}-\d{2}_[\w.-]+_v\d+\.md)\b")


def _extract_drop_citations(event: dict) -> list[str]:
    """Find drop filenames mentioned in the event body (cap at 4)."""
    body = (event.get("summary") or "") + " " + (event.get("body") or "")
    hits = _DROP_CITATION.findall(body)
    seen: list[str] = []
    for h in hits:
        if h not in seen:
            seen.append(h)
        if len(seen) >= CITES_DROP_CAP:
            break
    return seen


_DEFAULT_POLICY = LoomInsertCounterPolicy()


def event_to_node(
    event: dict,
    ctx: IngestContext,
    policy: RankPolicy = _DEFAULT_POLICY,
    max_rank: int = MAX_RANK_U32,
) -> DagNodeRecord:
    """
    Map one Loom JSONL entry to a DagNodeRecord. Pure function: produces a
    record based on the event and the current context. Does NOT mutate ctx.
    Caller uses apply_ingest() to fold the record back into a new context.

    `policy` defaults to LoomInsertCounterPolicy and can be swapped for any
    RankPolicy implementation (tests, alternate event substrates).
    """
    event_type = event["event"]
    truth = TRUTH.get(event_type)
    if truth is None:
        raise ValueError(f"unknown event type: {event_type!r}")

    node_id = ctx.next_counter
    rank = policy.assign_ranks(
        node_count=1, max_rank=max_rank, counter=node_id
    )[0]

    agent = event.get("agent", "unknown")
    parents: list[int] = []

    # prev_by_agent: most recent prior event by same agent
    prev = ctx.last_event_by_agent.get(agent)
    if prev is not None:
        parents.append(prev)

    # parent_response / dialogue_prev_turn for dialogue_turn events
    if event_type == "dialogue_turn":
        topic = event.get("topic", "")
        dfile = event.get("file", "")
        prev_turn = ctx.last_dialogue_turn.get((topic, dfile))
        if prev_turn is not None and prev_turn != prev:  # don't double-count
            parents.append(prev_turn)

    # cites_drop: referenced drops (cap 4)
    citations = _extract_drop_citations(event)
    remaining_slots = MAX_NEIGHBORS - len(parents)
    for fname in citations[:remaining_slots]:
        node = ctx.drop_node_by_filename.get(fname)
        if node is not None and node not in parents:
            parents.append(node)

    record = DagNodeRecord(
        node_id=node_id,
        rank=rank,
        truth=truth,
        neighbors=parents,
        sidecar=dict(event),
    )
    record.assert_valid()
    return record


def apply_ingest(record: DagNodeRecord, ctx: IngestContext) -> IngestContext:
    """Return a new context with `record` folded in. Caller chains these."""
    agent = record.sidecar.get("agent", "unknown")
    event_type = record.sidecar.get("event")

    new_ctx = IngestContext(
        next_counter=ctx.next_counter + 1,
        last_event_by_agent={**ctx.last_event_by_agent, agent: record.node_id},
        last_dialogue_turn=dict(ctx.last_dialogue_turn),
        drop_node_by_filename=dict(ctx.drop_node_by_filename),
    )

    if event_type == "dialogue_turn":
        topic = record.sidecar.get("topic", "")
        dfile = record.sidecar.get("file", "")
        new_ctx.last_dialogue_turn[(topic, dfile)] = record.node_id

    if event_type == "drop_written":
        fname = record.sidecar.get("drop_filename")
        if fname:
            new_ctx.drop_node_by_filename[fname] = record.node_id

    return new_ctx


def ingest_stream(
    events: Iterable[dict],
    ctx: Optional[IngestContext] = None,
    policy: RankPolicy = _DEFAULT_POLICY,
    max_rank: int = MAX_RANK_U32,
) -> tuple[list[DagNodeRecord], IngestContext]:
    """Fold an ordered stream of events into records + final context."""
    ctx = ctx or IngestContext()
    records: list[DagNodeRecord] = []
    for event in events:
        record = event_to_node(event, ctx, policy=policy, max_rank=max_rank)
        ctx = apply_ingest(record, ctx)
        records.append(record)
    return records, ctx
