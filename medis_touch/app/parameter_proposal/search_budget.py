"""Explicit compute/search budgets for the adaptive optimizer."""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class SearchBudget:
    max_candidates: int = 250
    max_statistical_survivors: int = 40
    max_walk_forward_survivors: int = 15
    max_robustness_survivors: int = 5
    max_holdout_finalists: int = 2

    def __post_init__(self) -> None:
        values = (
            self.max_candidates,
            self.max_statistical_survivors,
            self.max_walk_forward_survivors,
            self.max_robustness_survivors,
            self.max_holdout_finalists,
        )
        if any(value < 1 for value in values):
            raise ValueError("search budget limits must be positive")
        if not (
            self.max_candidates >= self.max_statistical_survivors >= self.max_walk_forward_survivors
            >= self.max_robustness_survivors >= self.max_holdout_finalists
        ):
            raise ValueError("search budget must monotonically decrease through the validation funnel")


def bounded(items, limit: int):
    """Return at most ``limit`` items without materialising an unbounded stream."""
    for index, item in enumerate(items):
        if index >= limit:
            break
        yield item
