"""rankPolicy protocol + three default implementations.

T2 from sprint ticket list. Shipped 2026-04-20.

Core DagDB enforces `rank(src) > rank(dst)` on insert. It never
computes rank. This module owns rank assignment for biology-style
ingestion, where the plugin decides the policy based on the shape
of the input graph.

Three defaults cover the regimes we know about today:

- `SequencePositionPolicy`   — single chain; rank = max - seqIndex.
- `ChainBandPolicy`          — multi-chain assembly; each chain
                                gets its own rank band; inter-chain
                                edges flow higher-chain-id → lower.
- `TopologicalSortPolicy`    — symmetric oligomers / general graphs;
                                BFS-depth from a chosen root; rank
                                = max - depth.

All three return a numpy uint32 array of length `node_count`. Even
while DagDB core runs on u8 rank (pre-T1), the Python plugin
computes in u32 — it will truncate to u8 on the wire until Tuesday,
and widen automatically once T1 lands and SET_RANKS_BULK (T3) ships.

Amateur engineering project. Errors likely. No competitive claims.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from typing import Protocol, runtime_checkable

import numpy as np


# -----------------------------------------------------------------------------
# Protocol
# -----------------------------------------------------------------------------


@runtime_checkable
class RankPolicy(Protocol):
    """A rank-assignment policy for biology-style DagDB ingestion.

    Returns a numpy uint32 array of length `node_count`. Value at
    index i is the rank for DagDB node i. Caller is responsible for
    choosing an edge set compatible with the assignment so the
    rank-monotonicity invariant holds on insert.
    """

    def assign_ranks(
        self,
        node_count: int,
        max_rank: int,
        **context,
    ) -> np.ndarray:
        ...


# -----------------------------------------------------------------------------
# Default 1: sequence-position (single chain)
# -----------------------------------------------------------------------------


@dataclass
class SequencePositionPolicy:
    """Single-chain policy. `rank[i] = max_rank - seq_indices[i]`.

    Edges `(p, q)` with `seq_indices[p] < seq_indices[q]` ingest
    cleanly (rank(p) > rank(q)). This is the canonical policy for
    the 7-protein certification pilot on single-chain proteins.

    Required context:
        seq_indices: np.ndarray[int] of length node_count.
                     Sequence position of each node within its chain.
                     Values must satisfy `seq_indices[i] < max_rank`.
    """

    def assign_ranks(
        self,
        node_count: int,
        max_rank: int,
        *,
        seq_indices: np.ndarray,
    ) -> np.ndarray:
        if len(seq_indices) != node_count:
            raise ValueError(
                f"seq_indices length {len(seq_indices)} != node_count {node_count}"
            )
        seq = np.asarray(seq_indices, dtype=np.int64)
        if seq.max() >= max_rank:
            raise ValueError(
                f"max seq_index {int(seq.max())} >= max_rank {max_rank}"
            )
        if seq.min() < 0:
            raise ValueError(f"seq_indices has negative values")
        return (np.uint32(max_rank) - seq.astype(np.uint32))


# -----------------------------------------------------------------------------
# Default 2: chain-band (multi-chain assembly)
# -----------------------------------------------------------------------------


@dataclass
class ChainBandPolicy:
    """Multi-chain assembly policy. Each chain occupies a rank band.

    Layout:
        band_width = ceil(max_rank / num_chains)
        for node i on chain c at position p within that chain:
            rank[i] = (c + 1) * band_width - 1 - p

    Chain 0 occupies the lowest rank band; chain `num_chains - 1`
    the highest. Inter-chain contacts `(src, dst)` ingest cleanly
    when `chain_id[src] > chain_id[dst]`. Intra-chain contacts
    ingest when `pos_in_chain[src] < pos_in_chain[dst]`.

    Required context:
        chain_id: np.ndarray[int] length node_count. 0 ≤ values.
        pos_in_chain: np.ndarray[int] length node_count.
                      Position within the node's own chain.
    """

    def assign_ranks(
        self,
        node_count: int,
        max_rank: int,
        *,
        chain_id: np.ndarray,
        pos_in_chain: np.ndarray,
    ) -> np.ndarray:
        if len(chain_id) != node_count or len(pos_in_chain) != node_count:
            raise ValueError("chain_id / pos_in_chain length mismatch")
        cid = np.asarray(chain_id, dtype=np.int64)
        pic = np.asarray(pos_in_chain, dtype=np.int64)
        if cid.min() < 0 or pic.min() < 0:
            raise ValueError("chain_id / pos_in_chain must be non-negative")

        num_chains = int(cid.max()) + 1
        band_width = (max_rank + num_chains - 1) // num_chains  # ceil
        if band_width <= int(pic.max()):
            raise ValueError(
                f"band_width {band_width} cannot hold chain with "
                f"max pos_in_chain {int(pic.max())}. Either raise "
                f"max_rank or reduce chain lengths."
            )

        bases = (cid + 1) * band_width - 1
        ranks = (bases - pic).astype(np.uint32)
        return ranks


# -----------------------------------------------------------------------------
# Default 3: topological-sort (BFS-depth from root)
# -----------------------------------------------------------------------------


@dataclass
class TopologicalSortPolicy:
    """BFS-depth from a chosen root. `rank[i] = max_rank - bfs_depth(i)`.

    For graphs without a natural sequence order (symmetric
    oligomers, contact networks without canonical chain direction),
    pick a root node and compute undirected BFS depths. Each depth
    layer becomes a rank. Deepest node gets rank `max_rank -
    max_depth`; disconnected nodes land one rank below that.

    Edges `(p, q)` with `depth[p] < depth[q]` ingest cleanly under
    the `rank(src) > rank(dst)` rule. Caller must pick an edge
    orientation consistent with BFS layers — typically: orient each
    undirected contact so it points from the lower-depth node to the
    higher-depth one.

    Required context:
        adjacency: list[list[int]] of length node_count. Undirected
                   neighbour list. adjacency[i] = list of neighbour
                   node ids.
        root:      int, node id from which to run BFS.
    """

    def assign_ranks(
        self,
        node_count: int,
        max_rank: int,
        *,
        adjacency: list,
        root: int,
    ) -> np.ndarray:
        if len(adjacency) != node_count:
            raise ValueError(
                f"adjacency length {len(adjacency)} != node_count {node_count}"
            )
        if not (0 <= root < node_count):
            raise ValueError(f"root {root} out of range [0, {node_count})")

        depth = np.full(node_count, -1, dtype=np.int64)
        depth[root] = 0
        q = deque([root])
        while q:
            v = q.popleft()
            for w in adjacency[v]:
                if depth[w] < 0:
                    depth[w] = depth[v] + 1
                    q.append(w)

        reached = depth >= 0
        max_depth = int(depth[reached].max()) if reached.any() else 0
        if max_depth >= max_rank:
            raise ValueError(
                f"BFS max_depth {max_depth} >= max_rank {max_rank}; "
                f"raise max_rank or pick a more central root."
            )

        # Disconnected components land one step deeper than the deepest
        # reachable node so they still receive a valid rank.
        depth[~reached] = max_depth + 1
        if (max_depth + 1) >= max_rank:
            raise ValueError(
                f"Disconnected-node fallback depth {max_depth + 1} >= "
                f"max_rank {max_rank}."
            )

        return (np.uint32(max_rank) - depth.astype(np.uint32))


# -----------------------------------------------------------------------------
# Self-test (run directly)
# -----------------------------------------------------------------------------


def _selftest() -> None:
    """Quick sanity checks. Run with `python rank_policies.py`."""

    # --- SequencePositionPolicy ---
    pol = SequencePositionPolicy()
    ranks = pol.assign_ranks(
        node_count=5, max_rank=10,
        seq_indices=np.array([0, 1, 2, 3, 4]),
    )
    assert list(ranks) == [10, 9, 8, 7, 6], f"SeqPos: {ranks}"
    assert ranks.dtype == np.uint32

    # Rank monotonicity: for any edge (p, q) with p < q, rank(p) > rank(q)
    for p in range(5):
        for q in range(p + 1, 5):
            assert ranks[p] > ranks[q]

    # --- ChainBandPolicy ---
    # 2 chains, 3 nodes each
    pol = ChainBandPolicy()
    ranks = pol.assign_ranks(
        node_count=6, max_rank=100,
        chain_id=np.array([0, 0, 0, 1, 1, 1]),
        pos_in_chain=np.array([0, 1, 2, 0, 1, 2]),
    )
    # band_width = ceil(100 / 2) = 50
    # chain 0 (ids 0..2): base = 49; ranks = 49, 48, 47
    # chain 1 (ids 3..5): base = 99; ranks = 99, 98, 97
    assert list(ranks) == [49, 48, 47, 99, 98, 97], f"ChainBand: {ranks}"
    # Intra-chain: earlier position > later position (rank-wise)
    assert ranks[0] > ranks[1] > ranks[2]
    assert ranks[3] > ranks[4] > ranks[5]
    # Inter-chain: chain 1 > chain 0 entirely
    assert ranks[3:].min() > ranks[:3].max()

    # --- TopologicalSortPolicy ---
    # 4-node cycle: 0 - 1 - 2 - 3 - 0. Root = 0. BFS depths: 0,1,2,1.
    pol = TopologicalSortPolicy()
    adj = [[1, 3], [0, 2], [1, 3], [0, 2]]
    ranks = pol.assign_ranks(
        node_count=4, max_rank=10, adjacency=adj, root=0,
    )
    # depths = [0, 1, 2, 1] → ranks = [10, 9, 8, 9]
    assert list(ranks) == [10, 9, 8, 9], f"TopoSort: {ranks}"

    # --- TopologicalSortPolicy with disconnected node ---
    adj = [[1], [0], []]
    ranks = pol.assign_ranks(
        node_count=3, max_rank=10, adjacency=adj, root=0,
    )
    # depths = [0, 1, -1 → 2]; ranks = [10, 9, 8]
    assert list(ranks) == [10, 9, 8], f"TopoSort disc: {ranks}"

    # --- Protocol runtime check ---
    assert isinstance(SequencePositionPolicy(), RankPolicy)
    assert isinstance(ChainBandPolicy(), RankPolicy)
    assert isinstance(TopologicalSortPolicy(), RankPolicy)

    # --- Error paths ---
    pol = SequencePositionPolicy()
    try:
        pol.assign_ranks(node_count=3, max_rank=5,
                          seq_indices=np.array([0, 1, 10]))
        assert False, "expected ValueError on seq >= max_rank"
    except ValueError:
        pass

    print("rank_policies.py selftest: OK")


if __name__ == "__main__":
    _selftest()
