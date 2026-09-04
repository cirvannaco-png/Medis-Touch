"""Low-dependency paired statistical tests for challenger evaluation."""
from __future__ import annotations

import math
from collections.abc import Sequence
from dataclasses import dataclass
from statistics import mean, stdev


@dataclass(frozen=True)
class PairedTestResult:
    n: int
    mean_delta: float
    standard_error: float
    t_statistic: float
    p_value: float
    significant: bool


def _normal_two_sided_p(z: float) -> float:
    return math.erfc(abs(z) / math.sqrt(2.0))


def paired_mean_test(
    baseline: Sequence[float],
    candidate: Sequence[float],
    *,
    alpha: float = 0.05,
) -> PairedTestResult:
    """Paired t-style test on identical opportunity IDs.

    Pairing is mandatory: callers must align observations from the same
    market opportunities before invoking this function. This controls much
    of the variance that otherwise makes small trading improvements look
    significant when opportunity composition changed.
    """
    if len(baseline) != len(candidate):
        raise ValueError("paired samples must have equal length")
    deltas = [float(c) - float(b) for b, c in zip(baseline, candidate)]
    n = len(deltas)
    if n < 2:
        raise ValueError("at least two paired observations are required")
    avg = mean(deltas)
    sd = stdev(deltas)
    se = sd / math.sqrt(n)
    if se == 0:
        p = 0.0 if avg != 0 else 1.0
        t_stat = math.inf if avg > 0 else -math.inf if avg < 0 else 0.0
    else:
        t_stat = avg / se
        p = _normal_two_sided_p(t_stat)
    return PairedTestResult(n, avg, se, t_stat, p, p < alpha and avg > 0)
