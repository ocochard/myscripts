"""Node-by-node diff of two computations (base vs scenario)."""

from __future__ import annotations

from decimal import Decimal

from .engine.pipeline import Resultat
from .engine.trace import Value


def _flat(r: Resultat) -> dict[str, Value]:
    return {f"{s.name}.{k}": v for s in r.steps for k, v in s.values.items()}


def diff(base: Resultat, other: Resultat) -> list[tuple[str, Value | None, Value | None, Decimal | None]]:
    a, b = _flat(base), _flat(other)
    rows = []
    for key in list(dict.fromkeys([*a, *b])):
        va, vb = a.get(key), b.get(key)
        if va == vb:
            continue
        delta = vb - va if isinstance(va, Decimal) and isinstance(vb, Decimal) else None
        rows.append((key, va, vb, delta))
    return rows
