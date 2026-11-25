#!/usr/bin/env python3
"""gen_dags.py — Generate a DagDB snapshot file (.dags v1) at arbitrary scale.

Writes the full binary format directly — NO socket, NO DSL — so we can build
multi-million-node graphs in seconds for bulk-load benchmarks.

Format (matches DagDBSnapshot.swift):
  Header (32 B):
    magic  'DAGS'   (4)
    version u32 = 1
    nodeCount u32
    gridW u32
    gridH u32
    tickCount u32
    reserved u32 = 0
    reserved2 u32 = 0
  Body:
    rank[N]       u8
    truth[N]      u8
    nodeType[N]   u8
    lut6Low[N]    u32 little-endian
    lut6High[N]   u32 little-endian
    neighbors[6N] i32 little-endian

Graph shape: random ranked tree with ≤6 fan-in per aggregator.
Leaves default to CONST1 (TRUTH=1). Aggregators default to MAJ.

--v8 writes the v8 layout instead: the same 32-byte header with bodyBytes@28 =
0xFFFFFFFF and a u64 body length after it; the body is rank[N] u64 · truth ·
nodeType · lut6Low · lut6High · neighbors · mode[N] u8 · ttableId[N] u16 ·
thrLo[N] f32 · thrHi[N] f32 (53 B/node); then the back-edge section (count
0), the WGTS section (no lanes), the TERN section ("TERN" · u8 flags · u32
table count · 729 B per table), the TWIN section (empty) and the ENVS
trailer (unspecified).
--ternary (implies --v8) makes every aggregator a TTABLE node reading table
0 = TSUM over six slots (the sign of the sum of its input trits); leaves stay
binary CONST1, which ternary readers read as +1.

Usage:
  ./gen_dags.py --grid 4096 --nodes 10000000 --out /tmp/big.dags
  ./gen_dags.py --grid 64 --nodes 2000 --ternary --out graph_v8.dags
"""

import argparse
import numpy as np
import struct
import time
from pathlib import Path

MAGIC = b"DAGS"
VERSION = 1
HEADER_SIZE = 32

# LUT6 presets (match Swift LUT6Preset)
LUT_CONST1   = (1 << 64) - 1       # all bits set
LUT_CONST0   = 0
LUT_MAJ6     = 0xFEE8_E880_E880_8000  # majority of 6 inputs
LUT_AND6     = 0x8000_0000_0000_0000  # only 0b111111
LUT_OR6      = 0xFFFF_FFFF_FFFF_FFFE  # any input high


def build_graph(n_leaves: int, fanout: int = 6):
    """Build a random ranked tree reducing n_leaves → 1 root via fanout.

    Returns (n_total, rank[], truth[], nodeType[], lut_low[], lut_high[], neighbors[]).
    Layout in node-id space: leaves first, then each rank above.
    """
    nodes_per_rank = []
    rem = n_leaves
    nodes_per_rank.append(rem)
    while rem > 1:
        rem = (rem + fanout - 1) // fanout
        nodes_per_rank.append(rem)
    max_rank = len(nodes_per_rank) - 1

    # id layout: leaves at ids [0..n_leaves), then rank-1 block, rank-2 block, ...
    # rank[leaves] = max_rank (highest), rank[root] = 0
    offsets = [0]
    for k in nodes_per_rank:
        offsets.append(offsets[-1] + k)
    n_total = offsets[-1]

    rank     = np.zeros(n_total, dtype=np.uint8)
    truth    = np.zeros(n_total, dtype=np.uint8)
    nodeType = np.zeros(n_total, dtype=np.uint8)
    lut_low  = np.zeros(n_total, dtype=np.uint32)
    lut_high = np.zeros(n_total, dtype=np.uint32)
    neighbors = np.full(n_total * 6, -1, dtype=np.int32)

    # Leaves (rank = max_rank)
    lo, hi = offsets[0], offsets[1]
    rank[lo:hi]     = max_rank
    truth[lo:hi]    = 1
    lut_low[lo:hi]  = np.uint32(LUT_CONST1 & 0xFFFFFFFF)
    lut_high[lo:hi] = np.uint32((LUT_CONST1 >> 32) & 0xFFFFFFFF)

    # Aggregators at each higher rank
    for level in range(1, len(nodes_per_rank)):
        rank_val = max_rank - level
        src_lo, src_hi = offsets[level - 1], offsets[level]
        dst_lo, dst_hi = offsets[level], offsets[level + 1]
        n_src = src_hi - src_lo

        rank[dst_lo:dst_hi]     = rank_val
        lut_low[dst_lo:dst_hi]  = np.uint32(LUT_MAJ6 & 0xFFFFFFFF)
        lut_high[dst_lo:dst_hi] = np.uint32((LUT_MAJ6 >> 32) & 0xFFFFFFFF)

        # Each destination aggregator gets up to `fanout` consecutive sources.
        # Vectorized edge wiring.
        for slot in range(fanout):
            # source id = src_lo + (dst_index * fanout + slot), if in range
            dst_indices = np.arange(dst_hi - dst_lo)
            src_ids = src_lo + dst_indices * fanout + slot
            valid = src_ids < src_hi
            # neighbors[dst * 6 + slot] = src
            dst_ids = dst_lo + dst_indices[valid]
            neighbors[dst_ids * 6 + slot] = src_ids[valid]

    return {
        "n_total": n_total,
        "max_rank": max_rank,
        "rank": rank,
        "truth": truth,
        "nodeType": nodeType,
        "lut_low": lut_low,
        "lut_high": lut_high,
        "neighbors": neighbors,
        "offsets": offsets,
    }


def write_dags(path: str, grid_w: int, grid_h: int, node_cap: int, g: dict):
    """Write a .dags snapshot. Pads graph buffers up to node_cap."""
    n = node_cap
    if g["n_total"] > n:
        raise ValueError(f"graph has {g['n_total']} nodes > capacity {n}")

    # Pad buffers
    def pad(arr, size, fill=0):
        out = np.full(size, fill, dtype=arr.dtype)
        out[:arr.shape[0]] = arr
        return out

    rank     = pad(g["rank"],     n)
    truth    = pad(g["truth"],    n)
    nodeType = pad(g["nodeType"], n)
    lut_low  = pad(g["lut_low"],  n)
    lut_high = pad(g["lut_high"], n)
    neighbors = np.full(n * 6, -1, dtype=np.int32)
    neighbors[:g["neighbors"].shape[0]] = g["neighbors"]

    t0 = time.time()
    with open(path, "wb") as f:
        # Header
        f.write(MAGIC)
        f.write(struct.pack("<IIIIIII", VERSION, n, grid_w, grid_h, 0, 0, 0))
        # Body
        f.write(rank.tobytes())
        f.write(truth.tobytes())
        f.write(nodeType.tobytes())
        f.write(lut_low.tobytes())
        f.write(lut_high.tobytes())
        f.write(neighbors.tobytes())
    elapsed = time.time() - t0
    size = Path(path).stat().st_size
    return size, elapsed


def tsum6_table():
    """Table bytes of TSUM over six slots: index = Σ 3^d (t_d + 1)."""
    out = np.empty(729, dtype=np.uint8)
    for i in range(729):
        v, s = i, 0
        for _ in range(6):
            s += v % 3 - 1
            v //= 3
        out[i] = 1 if s > 0 else (0 if s < 0 else 2)   # +1 → 1, −1 → 0, 0 → 2
    return out


def write_dags_v8(path: str, grid_w: int, grid_h: int, node_cap: int, g: dict, ternary: bool):
    n = node_cap
    if g["n_total"] > n:
        raise ValueError(f"graph has {g['n_total']} nodes > capacity {n}")

    def pad(arr, size, dtype, fill=0):
        out = np.full(size, fill, dtype=dtype)
        out[:arr.shape[0]] = arr
        return out

    rank = pad(g["rank"].astype(np.uint64), n, np.uint64)
    truth = pad(g["truth"], n, np.uint8)
    nodeType = pad(g["nodeType"], n, np.uint8)
    lut_low = pad(g["lut_low"], n, np.uint32)
    lut_high = pad(g["lut_high"], n, np.uint32)
    neighbors = np.full(n * 6, -1, dtype=np.int32)
    neighbors[:g["neighbors"].shape[0]] = g["neighbors"]
    mode = np.zeros(n, dtype=np.uint8)
    ttable_id = np.zeros(n, dtype=np.uint16)
    thr = np.zeros(n, dtype=np.float32)
    library = np.zeros(0, dtype=np.uint8)
    if ternary:
        aggregators = np.arange(g["offsets"][1], g["n_total"])
        mode[aggregators] = 1          # TTABLE
        library = tsum6_table()
        truth[aggregators] = 2         # start at 0 (UNDEFINED), a legal ternary byte

    body = b"".join(a.astype(a.dtype.newbyteorder("<")).tobytes() for a in
                    (rank, truth, nodeType, lut_low, lut_high, neighbors, mode, ttable_id, thr, thr))
    assert len(body) == 53 * n
    t0 = time.time()
    with open(path, "wb") as f:
        f.write(MAGIC)
        f.write(struct.pack("<IIIIIII", 8, n, grid_w, grid_h, 0, 0, 0xFFFFFFFF))
        f.write(struct.pack("<Q", len(body)))
        f.write(body)
        f.write(struct.pack("<I", 0))                       # back edges: none
        f.write(b"WGTS" + bytes([0]))                       # no weight lanes
        count = len(library) // 729
        f.write(b"TERN" + bytes([1 if count else 0]) + struct.pack("<I", count))
        f.write(library.tobytes())
        f.write(b"TWIN" + struct.pack("<I", 0))             # no twin state
        f.write(b"ENVS" + bytes([0]))                       # env unspecified
    elapsed = time.time() - t0
    return Path(path).stat().st_size, elapsed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--grid", type=int, default=4096, help="grid dimension (NxN)")
    ap.add_argument("--nodes", type=int, default=10_000_000, help="number of leaf nodes")
    ap.add_argument("--fanout", type=int, default=6)
    ap.add_argument("--out", default="/tmp/big.dags")
    ap.add_argument("--v8", action="store_true", help="write the v8 layout (ternary contract)")
    ap.add_argument("--ternary", action="store_true",
                    help="v8 with every aggregator a TTABLE node (TSUM over six slots)")
    args = ap.parse_args()

    node_cap = args.grid * args.grid
    print(f"Grid: {args.grid}x{args.grid} = {node_cap:,} slots")
    print(f"Building ranked tree from {args.nodes:,} leaves (fanout {args.fanout})...")

    t0 = time.time()
    g = build_graph(args.nodes, args.fanout)
    t_build = time.time() - t0
    print(f"  Graph: {g['n_total']:,} total nodes across {g['max_rank']+1} ranks (built in {t_build:.2f}s)")
    print(f"  Rank sizes: {[g['offsets'][i+1] - g['offsets'][i] for i in range(g['max_rank']+1)]}")

    if args.v8 or args.ternary:
        size, elapsed = write_dags_v8(args.out, args.grid, args.grid, node_cap, g, args.ternary)
    else:
        size, elapsed = write_dags(args.out, args.grid, args.grid, node_cap, g)
    print(f"  Wrote {size:,} bytes ({size/1e6:.1f} MB) in {elapsed:.2f}s to {args.out}")
    print(f"  Throughput: {size / elapsed / 1e6:.0f} MB/s")


if __name__ == "__main__":
    main()
