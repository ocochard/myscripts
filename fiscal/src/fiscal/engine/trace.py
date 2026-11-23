"""Explainable computation trace: every step records its outputs and the rules it used."""

from __future__ import annotations

from decimal import Decimal

from pydantic import BaseModel, Field

Value = Decimal | int | bool | str


class UnsupportedCase(Exception):
    """The household uses a mechanism the engine does not model yet.

    Raised instead of returning a silently wrong number.
    """


class Step(BaseModel):
    name: str
    values: dict[str, Value]
    refs: list[str] = Field(default_factory=list)


class Trace(BaseModel):
    steps: list[Step] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)

    def add(self, name: str, refs: list[str] | None = None, **values: Value) -> None:
        self.steps.append(Step(name=name, values=values, refs=refs or []))

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)

    def flat(self) -> dict[str, Value]:
        return {f"{s.name}.{k}": v for s in self.steps for k, v in s.values.items()}
