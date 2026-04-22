"""Unit tests for the event-log to DagDB adapter. No daemon required."""

import json
import os
from pathlib import Path

from adapter import (
    CITES_DROP_CAP,
    MAX_NEIGHBORS,
    MAX_RANK_U32,
    TRUTH,
    DagNodeRecord,
    IngestContext,
    LoomInsertCounterPolicy,
    RankPolicy,
    apply_ingest,
    event_to_node,
    ingest_stream,
)


def test_first_event_has_no_parents():
    ctx = IngestContext()
    ev = {
        "ts": "2026-04-20T10:00:00+00:00",
        "agent": "hari",
        "branch": "main",
        "event": "response",
        "summary": "first event ever",
    }
    rec = event_to_node(ev, ctx)
    assert rec.node_id == 0
    assert rec.rank == MAX_RANK_U32
    assert rec.truth == TRUTH["response"]
    assert rec.neighbors == []


def test_prev_by_agent_chains():
    ev1 = {"ts": "t1", "agent": "dag", "event": "response", "summary": "a"}
    ev2 = {"ts": "t2", "agent": "dag", "event": "response", "summary": "b"}
    records, ctx = ingest_stream([ev1, ev2])
    assert records[0].neighbors == []
    assert records[1].neighbors == [0], "ev2 should cite ev1 as prev_by_agent"
    assert ctx.last_event_by_agent == {"dag": 1}


def test_different_agents_dont_chain():
    ev1 = {"ts": "t1", "agent": "dag", "event": "response", "summary": "a"}
    ev2 = {"ts": "t2", "agent": "fold", "event": "response", "summary": "b"}
    records, _ = ingest_stream([ev1, ev2])
    assert records[1].neighbors == [], "fold has no prior event of his own"


def test_dialogue_turn_chains_both_ways():
    ev1 = {"ts": "t1", "agent": "dag", "event": "response", "summary": "a"}
    ev2 = {
        "ts": "t2",
        "agent": "dag",
        "event": "dialogue_turn",
        "partner": "fold",
        "turn": 1,
        "max": 4,
        "topic": "X",
        "file": "/loom/X.md",
    }
    ev3 = {
        "ts": "t3",
        "agent": "fold",
        "event": "dialogue_turn",
        "partner": "dag",
        "turn": 2,
        "max": 4,
        "topic": "X",
        "file": "/loom/X.md",
    }
    records, _ = ingest_stream([ev1, ev2, ev3])
    # ev2: prev_by_agent=ev1 (dag's prior), no dialogue_prev_turn yet
    assert records[1].neighbors == [0]
    # ev3: prev_by_agent=none (fold's first event), dialogue_prev_turn=ev2
    assert records[2].neighbors == [1]


def test_dialogue_turn_separate_threads_dont_cross():
    """Two dialogue threads on different topics should not cross-reference."""
    threadA = {
        "ts": "t2", "agent": "dag", "event": "dialogue_turn",
        "partner": "fold", "turn": 1, "max": 4,
        "topic": "A", "file": "/loom/A.md",
    }
    threadB = {
        "ts": "t3", "agent": "dag", "event": "dialogue_turn",
        "partner": "fold", "turn": 1, "max": 4,
        "topic": "B", "file": "/loom/B.md",
    }
    records, _ = ingest_stream([threadA, threadB])
    # threadB has prev_by_agent=threadA but no dialogue_prev_turn
    # (different (topic, file))
    assert records[1].neighbors == [0]  # just prev_by_agent


def test_cites_drop_capped_at_4():
    body_with_5_drops = " ".join(
        f"2026-04-20_hari-to-{x}_topic_HARI_v1.md" for x in ["a", "b", "c", "d", "e"]
    )
    ev = {
        "ts": "t1", "agent": "hari", "event": "response",
        "summary": body_with_5_drops,
    }
    rec = event_to_node(ev, IngestContext())
    # No drops exist in context yet, so no cites_drop edges actually added.
    # But the extract step should still find at most 4 regex matches internally.
    from adapter import _extract_drop_citations
    hits = _extract_drop_citations(ev)
    assert len(hits) == CITES_DROP_CAP


def test_cites_drop_edges_added_when_drop_exists():
    # Pre-seed context with a drop node at id=0
    ctx = IngestContext(
        next_counter=1,
        last_event_by_agent={},
        drop_node_by_filename={"2026-04-20_hari-to-dag_x_HARI_v1.md": 0},
    )
    ev = {
        "ts": "t1", "agent": "fold", "event": "response",
        "summary": "saw 2026-04-20_hari-to-dag_x_HARI_v1.md, responding now",
    }
    rec = event_to_node(ev, ctx)
    assert 0 in rec.neighbors, "the cited drop node should appear as a parent"


def test_max_neighbours_enforced():
    # Pre-seed ctx with prev_by_agent + 5 drop nodes that get cited
    ctx = IngestContext(
        next_counter=10,
        last_event_by_agent={"fold": 0},
        drop_node_by_filename={
            f"2026-04-20_x-to-y_s{i}_T_v1.md": i + 1 for i in range(5)
        },
    )
    body = " ".join(
        f"2026-04-20_x-to-y_s{i}_T_v1.md" for i in range(5)
    )
    ev = {"ts": "t1", "agent": "fold", "event": "response", "summary": body}
    rec = event_to_node(ev, ctx)
    assert len(rec.neighbors) <= MAX_NEIGHBORS
    assert rec.neighbors[0] == 0, "prev_by_agent stays first"
    assert len(rec.neighbors) == 5, (
        "1 prev_by_agent + 4 cites_drop (cap) = 5 total"
    )


def test_rank_is_strictly_monotonic_decreasing():
    events = [
        {"ts": f"t{i}", "agent": "dag", "event": "response", "summary": f"e{i}"}
        for i in range(100)
    ]
    records, _ = ingest_stream(events)
    ranks = [r.rank for r in records]
    assert ranks == sorted(ranks, reverse=True), "ranks must strictly decrease"
    assert all(records[i].neighbors == [i - 1] for i in range(1, 100))


def test_unknown_event_type_raises():
    ev = {"ts": "t1", "agent": "hari", "event": "totally_made_up", "summary": ""}
    try:
        event_to_node(ev, IngestContext())
    except ValueError as e:
        assert "totally_made_up" in str(e)
    else:
        assert False, "expected ValueError for unknown event type"


def test_loom_policy_conforms_to_rank_policy_protocol():
    """LoomInsertCounterPolicy must satisfy the RankPolicy Protocol at runtime."""
    policy = LoomInsertCounterPolicy()
    assert isinstance(policy, RankPolicy)


def test_loom_policy_requires_counter_in_context():
    policy = LoomInsertCounterPolicy()
    try:
        policy.assign_ranks(node_count=1, max_rank=MAX_RANK_U32)
    except ValueError as e:
        assert "counter" in str(e)
    else:
        assert False, "expected ValueError when counter missing"


def test_loom_policy_rejects_batch_inserts():
    policy = LoomInsertCounterPolicy()
    try:
        policy.assign_ranks(node_count=5, max_rank=MAX_RANK_U32, counter=0)
    except ValueError as e:
        assert "one node at a time" in str(e)
    else:
        assert False, "expected ValueError on batch insert"


def test_custom_policy_swaps_cleanly():
    """event_to_node accepts any RankPolicy implementation."""

    class SquashEveryOtherPolicy:
        """Toy policy: half the rank space for testing."""
        def assign_ranks(self, node_count, max_rank, **ctx):
            return [max_rank // 2 - ctx["counter"]]

    ev = {"ts": "t1", "agent": "dag", "event": "response", "summary": "x"}
    rec = event_to_node(ev, IngestContext(), policy=SquashEveryOtherPolicy())
    assert rec.rank == MAX_RANK_U32 // 2


def test_assert_valid_catches_rank_violation():
    """A parent with higher node_id than self should be rejected by assert_valid."""
    bad = DagNodeRecord(
        node_id=3,
        rank=10,
        truth=1,
        neighbors=[5],  # future node, violates rank invariant
    )
    try:
        bad.assert_valid()
    except AssertionError as e:
        assert "rank invariant" in str(e)
    else:
        assert False, "expected AssertionError on future-parent"


def test_real_loom_sample_ingests_cleanly():
    """Soak test: ingest the first N entries of a real Loom JSONL.
    Opt-in: set DAGDB_LOOM_TEST_JSONL env var to a path. Skipped
    by default so the public test suite is hermetic."""
    env_path = os.environ.get("DAGDB_LOOM_TEST_JSONL")
    if not env_path:
        return  # skip: no user-supplied JSONL
    path = Path(env_path).expanduser()
    if not path.exists():
        return  # skip: path doesn't exist

    events: list[dict] = []
    with path.open() as f:
        for line in f:
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass  # tolerate malformed
            if len(events) >= 200:
                break

    records, ctx = ingest_stream(events)
    assert len(records) == len(events)
    # All ranks monotonically decrease
    ranks = [r.rank for r in records]
    assert ranks == sorted(ranks, reverse=True)
    # All node_ids are contiguous 0..N-1
    assert [r.node_id for r in records] == list(range(len(records)))
    # All events produced at most MAX_NEIGHBORS parents
    assert all(len(r.neighbors) <= MAX_NEIGHBORS for r in records)
    # Rank invariant holds across all records
    for r in records:
        r.assert_valid()


if __name__ == "__main__":
    import sys
    tests = [v for k, v in globals().items() if k.startswith("test_") and callable(v)]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"  ok  {t.__name__}")
        except Exception as e:
            failed += 1
            print(f"  FAIL {t.__name__}: {e}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    sys.exit(failed)
