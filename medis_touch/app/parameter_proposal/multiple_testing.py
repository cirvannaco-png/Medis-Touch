"""Family-wise error control for bounded candidate searches."""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class AdjustedPValue:
    index: int
    raw_p: float
    adjusted_p: float
    reject: bool


def holm_bonferroni(p_values: list[float], *, alpha: float = 0.05) -> list[AdjustedPValue]:
    """Apply Holm's step-down correction without scipy."""
    if not 0 < alpha < 1:
        raise ValueError("alpha must be in (0, 1)")
    if any(not 0 <= p <= 1 for p in p_values):
        raise ValueError("p-values must be in [0, 1]")
    ranked = sorted(enumerate(p_values), key=lambda item: item[1])
    adjusted: dict[int, float] = {}
    running = 0.0
    m = len(p_values)
    for rank, (index, p_value) in enumerate(ranked):
        value = min(1.0, (m - rank) * p_value)
        running = max(running, value)
        adjusted[index] = running
    return [
        AdjustedPValue(i, p, adjusted[i], adjusted[i] < alpha)
        for i, p in enumerate(p_values)
    ]
