"""Decimal money helpers and YAML loading that never goes through float."""

from __future__ import annotations

from decimal import ROUND_FLOOR, ROUND_HALF_UP, Decimal
from pathlib import Path
from typing import Annotated, Any

import yaml
from pydantic import Field

D = Decimal
ZERO = Decimal(0)

Money = Annotated[Decimal, Field(ge=0)]
SignedMoney = Decimal
Rate = Annotated[Decimal, Field(ge=0, le=1)]


def euro_floor(x: Decimal) -> Decimal:
    return x.quantize(D(1), rounding=ROUND_FLOOR)


def euro_round(x: Decimal) -> Decimal:
    return x.quantize(D(1), rounding=ROUND_HALF_UP)


def clamp0(x: Decimal) -> Decimal:
    return x if x > 0 else ZERO


class _DecimalLoader(yaml.SafeLoader):
    """SafeLoader that parses floats (and ints) as Decimal to keep 0.1 exact."""


def _decimal(loader: yaml.SafeLoader, node: yaml.Node) -> Decimal:
    return Decimal(loader.construct_scalar(node).replace("_", ""))  # type: ignore[arg-type]


_DecimalLoader.add_constructor("tag:yaml.org,2002:float", _decimal)


def load_yaml(path: str | Path) -> Any:
    with open(path, encoding="utf-8") as fh:
        return yaml.load(fh, Loader=_DecimalLoader)  # noqa: S506 - SafeLoader subclass
