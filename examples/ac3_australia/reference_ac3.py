"""Pure-Python AC-3 reference for Australia 3-coloring with WA=red.

Ground truth for the DagDB BACK_EDGE verification. The DagDB
implementation must produce identical per-tick domain trajectories.

Two modes:
- `ac3_classic` — textbook queue-based AC-3 (variable-arc granularity).
  Used as algorithmic reference.
- `ac3_synchronous` — synchronous-tick AC-3 where every region's
  domain is updated simultaneously each tick. This is the version
  DagDB will mirror exactly (BACK_EDGE latches all domains at tick
  boundary, so updates are synchronous, not arc-by-arc).

The synchronous variant is what the DagDB encoding reproduces. Tick
trajectory of `ac3_synchronous` is the per-tick comparison target.
"""

from __future__ import annotations
from australia import REGIONS, COLORS, ADJACENCIES, neighbors, initial_domains


def has_support(region: str, color: str, neighbor_domain: set[str]) -> bool:
    """True if the neighbor has at least one color != `color`."""
    return any(c != color for c in neighbor_domain)


def synchronous_step(
    domains: dict[str, set[str]],
) -> dict[str, set[str]]:
    """One synchronous AC-3 step: every region recomputed from snapshot."""
    new_domains: dict[str, set[str]] = {}
    for region in REGIONS:
        kept: set[str] = set()
        for color in domains[region]:
            ok = True
            for nb in neighbors(region):
                if not has_support(region, color, domains[nb]):
                    ok = False
                    break
            if ok:
                kept.add(color)
        new_domains[region] = kept
    return new_domains


def ac3_synchronous(
    domains: dict[str, set[str]] | None = None,
    max_ticks: int = 64,
) -> list[dict[str, set[str]]]:
    """Run synchronous AC-3 to fixed point; return per-tick trajectory."""
    state = initial_domains() if domains is None else {k: set(v) for k, v in domains.items()}
    trajectory: list[dict[str, set[str]]] = [state]
    for _ in range(max_ticks):
        nxt = synchronous_step(state)
        trajectory.append(nxt)
        if nxt == state:
            return trajectory
        state = nxt
    raise RuntimeError(f"did not converge in {max_ticks} ticks")


def ac3_classic(domains: dict[str, set[str]] | None = None) -> dict[str, set[str]]:
    """Textbook queue-based AC-3. Result-equivalent at fixed point."""
    state = initial_domains() if domains is None else {k: set(v) for k, v in domains.items()}
    queue: list[tuple[str, str]] = []
    for pair in ADJACENCIES:
        a, b = tuple(pair)
        queue.append((a, b))
        queue.append((b, a))
    while queue:
        xi, xj = queue.pop(0)
        revised = False
        to_remove = set()
        for color in state[xi]:
            if not has_support(xi, color, state[xj]):
                to_remove.add(color)
        if to_remove:
            state[xi] -= to_remove
            revised = True
        if revised:
            for xk in neighbors(xi):
                if xk != xj:
                    queue.append((xk, xi))
    return state


def domain_repr(domains: dict[str, set[str]]) -> str:
    parts = []
    for region in REGIONS:
        colors = sorted(domains[region])
        parts.append(f"{region}={'{' + ','.join(colors) + '}'}")
    return " ".join(parts)


def main() -> None:
    print("AC-3 Australia 3-coloring with WA=red")
    print("=" * 60)
    print("Initial:")
    print(f"  {domain_repr(initial_domains())}")
    print()
    print("Synchronous trajectory:")
    trajectory = ac3_synchronous()
    for i, state in enumerate(trajectory):
        marker = "*" if i == len(trajectory) - 1 else " "
        print(f"  tick={i:>2} {marker} {domain_repr(state)}")
    print()
    print(f"Converged in {len(trajectory) - 1} synchronous ticks.")
    print()
    classic = ac3_classic()
    print("Classic AC-3 (queue-based) result:")
    print(f"  {domain_repr(classic)}")
    print()
    if trajectory[-1] == classic:
        print("Synchronous fixed-point matches classic AC-3 result. OK.")
    else:
        print("MISMATCH between synchronous and classic. Investigate.")


if __name__ == "__main__":
    main()
