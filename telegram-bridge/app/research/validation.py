"""Leakage-resistant OOS, walk-forward and immutable holdout validation."""
from __future__ import annotations
from dataclasses import dataclass
from datetime import datetime, timedelta
from statistics import mean
from typing import Sequence

@dataclass(frozen=True)
class Window:
    train_start: datetime
    train_end: datetime
    test_start: datetime
    test_end: datetime


def _purge(w: Window, purge: timedelta) -> Window:
    # Test begins after the purge/embargo interval, preventing overlapping labels.
    return Window(w.train_start, w.train_end, max(w.test_start, w.train_end + purge), w.test_end)


def walk_forward_windows(start: datetime, end: datetime, train_days: int = 180, test_days: int = 30, step_days: int = 30, purge_days: int = 1) -> list[Window]:
    if not (start < end and train_days > 0 and test_days > 0 and step_days > 0):
        raise ValueError("invalid walk-forward parameters")
    out: list[Window] = []
    cursor = start
    while cursor + timedelta(days=train_days + purge_days + test_days) <= end:
        train_end = cursor + timedelta(days=train_days)
        test_start = train_end + timedelta(days=purge_days)
        test_end = test_start + timedelta(days=test_days)
        out.append(Window(cursor, train_end, test_start, test_end))
        cursor += timedelta(days=step_days)
    return out


def out_of_sample(observations: Sequence[dict], start: datetime, end: datetime, embargo: timedelta = timedelta(days=1)) -> list[dict]:
    if start >= end:
        raise ValueError("invalid OOS interval")
    # OOS is an explicit interval; observations at the boundary are excluded.
    return [o for o in observations if start < o["timestamp"] < end and o["timestamp"] >= start + embargo]


def holdout(observations: Sequence[dict], start: datetime, end: datetime, locked: bool) -> list[dict]:
    if not locked:
        raise PermissionError("holdout is immutable and must be locked before evaluation")
    return [o for o in observations if start <= o["timestamp"] <= end]


def expectancy(rs: Sequence[float]) -> float:
    return mean(rs) if rs else 0.0


def max_drawdown(rs: Sequence[float]) -> float:
    equity = peak = 0.0
    worst = 0.0
    for r in rs:
        equity += r
        peak = max(peak, equity)
        worst = min(worst, equity - peak)
    return worst
