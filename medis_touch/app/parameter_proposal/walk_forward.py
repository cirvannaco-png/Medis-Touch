"""Purged walk-forward validation for replay-backed parameter candidates.

This module is intentionally independent of the live execution path. It accepts
an evaluator/replay callback and never shuffles temporal observations.
"""
from __future__ import annotations

from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

from .models import Evaluation, ParameterSet


@dataclass(frozen=True)
class WalkForwardWindow:
    train_start: datetime
    train_end: datetime
    test_start: datetime
    test_end: datetime


@dataclass(frozen=True)
class WalkForwardResult:
    passed: bool
    windows: tuple[WalkForwardWindow, ...]
    train: tuple[Evaluation, ...]
    test: tuple[Evaluation, ...]
    median_test_objective: float
    worst_test_objective: float
    reason: str | None = None


def make_windows(
    rows: Sequence[Any],
    *,
    timestamp_field: str = "received_at",
    train_days: int = 28,
    test_days: int = 7,
    step_days: int = 7,
    purge_days: int = 1,
) -> tuple[WalkForwardWindow, ...]:
    timestamps = sorted(
        value for value in (_timestamp(row, timestamp_field) for row in rows) if value is not None
    )
    if not timestamps:
        return ()
    start, end = timestamps[0], timestamps[-1]
    cursor = start
    windows: list[WalkForwardWindow] = []
    while cursor + timedelta(days=train_days + purge_days + test_days) <= end:
        train_end = cursor + timedelta(days=train_days)
        test_start = train_end + timedelta(days=purge_days)
        test_end = test_start + timedelta(days=test_days)
        windows.append(WalkForwardWindow(cursor, train_end, test_start, test_end))
        cursor += timedelta(days=step_days)
    return tuple(windows)


def _timestamp(row: Any, field: str) -> datetime | None:
    value = row.get(field) if isinstance(row, dict) else getattr(row, field, None)
    return value if isinstance(value, datetime) else None


def _slice(rows: Iterable[Any], start: datetime, end: datetime, field: str) -> tuple[Any, ...]:
    return tuple(row for row in rows if (ts := _timestamp(row, field)) is not None and start <= ts < end)


def validate_candidate(
    candidate: ParameterSet,
    baseline: ParameterSet,
    rows: Sequence[Any],
    replay: Callable[[ParameterSet, Sequence[Any]], Iterable[Any]],
    score: Callable[[Iterable[Any]], Evaluation],
    *,
    timestamp_field: str = "received_at",
    windows: tuple[WalkForwardWindow, ...] | None = None,
    minimum_test_trades: int = 100,
    minimum_median_improvement: float = 0.0,
    maximum_window_degradation: float = 0.25,
) -> WalkForwardResult:
    """Validate a candidate on sequential, purged test windows."""
    windows = windows or make_windows(rows, timestamp_field=timestamp_field)
    if not windows:
        return WalkForwardResult(False, (), (), (), 0.0, 0.0, "insufficient_temporal_history")

    train_evals: list[Evaluation] = []
    test_evals: list[Evaluation] = []
    baseline_test_evals: list[Evaluation] = []
    for window in windows:
        train_rows = _slice(rows, window.train_start, window.train_end, timestamp_field)
        test_rows = _slice(rows, window.test_start, window.test_end, timestamp_field)
        if not train_rows or not test_rows:
            return WalkForwardResult(False, windows, tuple(train_evals), tuple(test_evals), 0.0, 0.0, "empty_window")

        train_candidate = tuple(replay(candidate, train_rows))
        test_candidate = tuple(replay(candidate, test_rows))
        test_baseline = tuple(replay(baseline, test_rows))
        try:
            train_evals.append(score(train_candidate))
            base_test = score(test_baseline)
            cand_test = score(test_candidate)
        except ValueError:
            return WalkForwardResult(False, windows, tuple(train_evals), tuple(test_evals), 0.0, 0.0, "unresolved_window")
        if cand_test.trades < minimum_test_trades:
            return WalkForwardResult(False, windows, tuple(train_evals), tuple(test_evals), 0.0, 0.0, "insufficient_test_trades")
        test_evals.append(cand_test)
        baseline_test_evals.append(base_test)
        improvement = cand_test.objective - base_test.objective
        if base_test.objective > 0 and improvement / base_test.objective < -maximum_window_degradation:
            return WalkForwardResult(False, windows, tuple(train_evals), tuple(test_evals), 0.0, 0.0, "window_degradation")

    improvements = [evaluation.objective for evaluation in test_evals]
    baseline_objectives = [evaluation.objective for evaluation in baseline_test_evals]
    deltas = [candidate_objective - baseline_objective for candidate_objective, baseline_objective in zip(improvements, baseline_objectives)]
    ordered = sorted(improvements)
    median = ordered[len(ordered) // 2] if ordered else 0.0
    worst = min(improvements) if improvements else 0.0
    passed = sum(delta >= minimum_median_improvement for delta in deltas) >= (len(deltas) + 1) // 2
    return WalkForwardResult(passed, windows, tuple(train_evals), tuple(test_evals), median, worst, None if passed else "median_test_improvement_failed")
