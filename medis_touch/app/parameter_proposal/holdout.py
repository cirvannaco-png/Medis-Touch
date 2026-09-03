"""Independent final holdout validation.

The holdout is intentionally a one-shot gate: callers should invoke it only
for finalists after cheaper validation has passed.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Callable, Iterable, Sequence

from .models import Evaluation, ParameterSet


@dataclass(frozen=True)
class HoldoutResult:
    passed: bool
    baseline: Evaluation | None
    candidate: Evaluation | None
    improvement: float
    reason: str | None = None


def validate_holdout(
    candidate: ParameterSet,
    baseline: ParameterSet,
    rows: Sequence[Any],
    replay: Callable[[ParameterSet, Sequence[Any]], Iterable[Any]],
    score: Callable[[Iterable[Any]], Evaluation],
    *,
    start: datetime,
    end: datetime,
    minimum_trades: int = 300,
    minimum_improvement: float = 0.05,
) -> HoldoutResult:
    holdout = tuple(
        row for row in rows
        if isinstance(row, dict)
        and isinstance(row.get("received_at"), datetime)
        and start <= row["received_at"] < end
        or not isinstance(row, dict)
        and isinstance(getattr(row, "received_at", None), datetime)
        and start <= getattr(row, "received_at") < end
    )
    if not holdout:
        return HoldoutResult(False, None, None, 0.0, "empty_holdout")
    base_rows = tuple(replay(baseline, holdout))
    candidate_rows = tuple(replay(candidate, holdout))
    try:
        base = score(base_rows)
        cand = score(candidate_rows)
    except ValueError:
        return HoldoutResult(False, None, None, 0.0, "unresolved_holdout")
    improvement = cand.objective - base.objective
    if cand.trades < minimum_trades:
        return HoldoutResult(False, base, cand, improvement, "insufficient_holdout_trades")
    if improvement < minimum_improvement:
        return HoldoutResult(False, base, cand, improvement, "holdout_improvement_failed")
    return HoldoutResult(True, base, cand, improvement)
