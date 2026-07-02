"""Australia map-coloring problem definition.

Shared by reference_ac3.py and the DagDB encoding (the encoder mirrors
these structures when laying out nodes).
"""

from __future__ import annotations
from typing import Iterable

REGIONS: tuple[str, ...] = ("WA", "NT", "SA", "Q", "NSW", "V", "T")

COLORS: tuple[str, ...] = ("red", "green", "blue")

ADJACENCIES: frozenset[frozenset[str]] = frozenset(
    frozenset(pair)
    for pair in (
        ("WA", "NT"),
        ("WA", "SA"),
        ("NT", "SA"),
        ("NT", "Q"),
        ("SA", "Q"),
        ("SA", "NSW"),
        ("SA", "V"),
        ("Q", "NSW"),
        ("NSW", "V"),
    )
)

PREASSIGNMENT: dict[str, str] = {"WA": "red"}


def initial_domains() -> dict[str, set[str]]:
    domains: dict[str, set[str]] = {}
    for region in REGIONS:
        if region in PREASSIGNMENT:
            domains[region] = {PREASSIGNMENT[region]}
        else:
            domains[region] = set(COLORS)
    return domains


def arcs() -> Iterable[tuple[str, str]]:
    for pair in ADJACENCIES:
        a, b = tuple(pair)
        yield (a, b)
        yield (b, a)


def neighbors(region: str) -> set[str]:
    out: set[str] = set()
    for pair in ADJACENCIES:
        if region in pair:
            other = next(r for r in pair if r != region)
            out.add(other)
    return out
