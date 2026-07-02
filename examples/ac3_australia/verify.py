"""Verification harness — compares DagDB AC-3 trajectory to Python reference.

Fill in `setup_dagdb_graph()` and `read_dagdb_domains()` once the
BACK_EDGE engine ships. The comparison logic and reference loading
are done.

Run after the engine + encoding land:

    python3 verify.py

Exit 0 if DagDB matches Python reference per tick. Exit 1 with a
diff readout if any tick differs.
"""

from __future__ import annotations
import socket
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from australia import REGIONS, COLORS, initial_domains
from reference_ac3 import ac3_synchronous, domain_repr


SOCKET_PATH = "/tmp/dagdb.sock"
MAX_TICKS = 16


def dsl(cmd: str) -> str:
    """Send one DSL command, return response (newline-stripped)."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(SOCKET_PATH)
        s.sendall((cmd + "\n").encode())
        return s.recv(65536).decode().strip()


def _expect_ok(resp: str, ctx: str) -> None:
    """Raise if the daemon response doesn't start with `OK`."""
    if not resp.startswith("OK"):
        raise RuntimeError(f"{ctx}: {resp}")


# LUT6 truth tables for "AND of N inputs" with the inputs sitting in
# slots 0..N-1. Higher slots are don't-cares: the LUT bit is 1 iff the
# low N bits of the index are all set.
_AND_LUT = {
    1: 0xAAAAAAAAAAAAAAAA,   # bit k = 1 iff k & 0x01 == 0x01 (= IDENTITY)
    3: 0x8080808080808080,   # bit k = 1 iff k & 0x07 == 0x07
    4: 0x8000800080008000,   # bit k = 1 iff k & 0x0F == 0x0F
    6: 0x8000000000000000,   # bit k = 1 iff k & 0x3F == 0x3F (= AND6 preset)
}
# 2-input OR with inputs at slots 0 and 1: bit k = 1 iff k & 0x3 != 0.
_OR2_LUT = 0xEEEEEEEEEEEEEEEE


def setup_dagdb_graph() -> dict[tuple[str, str], int]:
    """Build the 96-node AC-3 graph per `dagdb_encoding_spec.md`.

    Layout:
      0..20  registers   (rank 2)
      21..74 supports    (rank 1)
      75..95 keeps       (rank 0)

    Returns a map from (region, color) to register node ID.
    """
    region_idx = {r: i for i, r in enumerate(REGIONS)}

    # Canonical neighbor order (sorted by region index) — picked once,
    # used for both the support-node ID layout and the keep-node wiring.
    from australia import neighbors as _nbrs
    nbrs = {r: sorted(_nbrs(r), key=lambda x: region_idx[x]) for r in REGIONS}

    # Register IDs: 0..20, ordered by (region_idx, color_idx).
    register_map: dict[tuple[str, str], int] = {}
    for r_idx, r in enumerate(REGIONS):
        for c_idx, c in enumerate(COLORS):
            register_map[(r, c)] = r_idx * 3 + c_idx

    # Support IDs: 21..74, ordered by (region, color, neighbor_idx).
    support_map: dict[tuple[str, str, str], int] = {}
    next_id = 21
    for r in REGIONS:
        for c in COLORS:
            for n in nbrs[r]:
                support_map[(r, c, n)] = next_id
                next_id += 1
    if next_id != 75:
        raise RuntimeError(f"support block size mismatch: ended at {next_id}, expected 75")

    # Keep IDs: 75..95, parallel to register layout.
    keep_map: dict[tuple[str, str], int] = {}
    for r_idx, r in enumerate(REGIONS):
        for c_idx, c in enumerate(COLORS):
            keep_map[(r, c)] = 75 + r_idx * 3 + c_idx

    # 1) Set ranks for all 96 nodes.
    for nid in range(0, 21):
        _expect_ok(dsl(f"SET {nid} RANK 2"), f"set rank reg {nid}")
    for nid in range(21, 75):
        _expect_ok(dsl(f"SET {nid} RANK 1"), f"set rank support {nid}")
    for nid in range(75, 96):
        _expect_ok(dsl(f"SET {nid} RANK 0"), f"set rank keep {nid}")

    # 2) Set LUTs.
    #    Registers: identity (won't fire — rank kernel skips registers).
    for nid in range(0, 21):
        _expect_ok(dsl(f"SET {nid} LUT IDENTITY"), f"set lut reg {nid}")
    #    Supports: 2-input OR.
    for nid in range(21, 75):
        _expect_ok(dsl(f"SET {nid} LUT 0x{_OR2_LUT:016X}"), f"set lut support {nid}")
    #    Keeps: AND_(1 + |neighbors(R)|) — fan-in includes the self domain.
    for r in REGIONS:
        fanin = 1 + len(nbrs[r])
        lut = _AND_LUT[fanin]
        for c in COLORS:
            kid = keep_map[(r, c)]
            _expect_ok(dsl(f"SET {kid} LUT 0x{lut:016X}"), f"set lut keep {kid}")

    # 3) Set initial register truths from `australia.initial_domains()`.
    init = initial_domains()
    for r in REGIONS:
        for c in COLORS:
            rid = register_map[(r, c)]
            truth = 1 if c in init[r] else 0
            _expect_ok(dsl(f"SET {rid} TRUTH {truth}"), f"set truth reg {rid}")

    # 4) Combinational wiring — must precede CONNECT BACK so the registers
    #    have zero combinational fan-in when we declare the back-edges.
    #    (In this encoding registers are pure sources, so they always have
    #    zero combinational in-degree — order is robust.)

    #    Support inputs: domain(N, c1) and domain(N, c2) where {c1,c2} =
    #    COLORS \ {c}. Slot 0 = the lower-index other-color.
    for r in REGIONS:
        for c in COLORS:
            other = [oc for oc in COLORS if oc != c]
            for n in nbrs[r]:
                sid = support_map[(r, c, n)]
                _expect_ok(dsl(f"CONNECT FROM {register_map[(n, other[0])]} TO {sid}"),
                           f"connect support {sid} slot 0")
                _expect_ok(dsl(f"CONNECT FROM {register_map[(n, other[1])]} TO {sid}"),
                           f"connect support {sid} slot 1")

    #    Keep inputs: slot 0 = domain(R, c); slots 1..N = supports for R.
    for r in REGIONS:
        for c in COLORS:
            kid = keep_map[(r, c)]
            _expect_ok(dsl(f"CONNECT FROM {register_map[(r, c)]} TO {kid}"),
                       f"connect keep {kid} slot 0")
            for n in nbrs[r]:
                _expect_ok(dsl(f"CONNECT FROM {support_map[(r, c, n)]} TO {kid}"),
                           f"connect keep {kid} support {n}")

    # 5) BACK_EDGEs: keep(R, c) → domain(R, c).
    for r in REGIONS:
        for c in COLORS:
            kid = keep_map[(r, c)]
            rid = register_map[(r, c)]
            _expect_ok(dsl(f"CONNECT BACK FROM {kid} TO {rid}"),
                       f"connect back keep {kid} → register {rid}")

    # 6) Validate the full graph.
    _expect_ok(dsl("VALIDATE"), "VALIDATE")

    return register_map


def read_dagdb_domains(register_map: dict[tuple[str, str], int]) -> dict[str, set[str]]:
    """Read current register truths via `GET <node> TRUTH`, decode back
    to `{region: {colors}}`."""
    domains: dict[str, set[str]] = {r: set() for r in REGIONS}
    for (region, color), nid in register_map.items():
        resp = dsl(f"GET {nid} TRUTH")
        if not resp.startswith("OK"):
            raise RuntimeError(f"GET {nid} TRUTH failed: {resp}")
        # "OK GET node=<n> truth=<v>" — pull `truth=`.
        parts = resp.split()
        truth_field = next((p for p in parts if p.startswith("truth=")), None)
        if truth_field is None:
            raise RuntimeError(f"GET {nid} TRUTH unparseable: {resp}")
        truth_val = int(truth_field.split("=", 1)[1])
        if truth_val == 1:
            domains[region].add(color)
    return domains


def diff_domains(
    ref: dict[str, set[str]], dagdb: dict[str, set[str]]
) -> list[str]:
    diffs = []
    for region in REGIONS:
        if ref[region] != dagdb[region]:
            diffs.append(
                f"  {region}: ref={sorted(ref[region])} dagdb={sorted(dagdb[region])}"
            )
    return diffs


def main() -> int:
    print("AC-3 Australia BACK_EDGE verification")
    print("=" * 60)

    print("Building reference trajectory (Python)...")
    ref_trajectory = ac3_synchronous()
    print(f"  reference converged in {len(ref_trajectory) - 1} ticks")
    print()

    print("Setting up DagDB graph...")
    register_map = setup_dagdb_graph()
    print(f"  {len(register_map)} registers allocated")
    print()

    print("Verifying initial state...")
    dagdb_state = read_dagdb_domains(register_map)
    diffs = diff_domains(ref_trajectory[0], dagdb_state)
    if diffs:
        print("  INITIAL STATE MISMATCH:")
        for d in diffs:
            print(d)
        return 1
    print(f"  tick=0  OK  {domain_repr(dagdb_state)}")

    print()
    print("Running ticks and comparing...")
    for tick in range(1, len(ref_trajectory)):
        resp = dsl("TICK 1")
        if not resp.startswith("OK"):
            print(f"  tick={tick} DAEMON ERROR: {resp}")
            return 1

        dagdb_state = read_dagdb_domains(register_map)
        diffs = diff_domains(ref_trajectory[tick], dagdb_state)

        if diffs:
            print(f"  tick={tick}  MISMATCH:")
            for d in diffs:
                print(d)
            print(f"  reference: {domain_repr(ref_trajectory[tick])}")
            print(f"  dagdb:     {domain_repr(dagdb_state)}")
            return 1

        marker = "*" if tick == len(ref_trajectory) - 1 else " "
        print(f"  tick={tick} {marker} OK  {domain_repr(dagdb_state)}")

    print()
    print(f"All {len(ref_trajectory)} ticks match. BACK_EDGE verified.")
    print("Tag suggestion: back_edge_v1")
    return 0


if __name__ == "__main__":
    sys.exit(main())
