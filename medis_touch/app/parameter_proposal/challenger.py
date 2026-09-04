"""Champion/challenger validation helpers kept off the live execution path."""
from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass

from .models import ParameterSet
from .multiple_testing import holm_bonferroni
from .paired_stats import PairedTestResult, paired_mean_test


@dataclass(frozen=True)
class ChallengerResult:
    candidate: ParameterSet
    test: PairedTestResult
    adjusted_p: float
    promoted: bool


def compare_candidates(
    champion: Sequence[float],
    candidates: Sequence[tuple[ParameterSet, Sequence[float]]],
    *,
    alpha: float = 0.05,
    minimum_mean_delta: float = 0.05,
) -> list[ChallengerResult]:
    """Compare challengers on the same opportunity vector as the champion."""
    tests = [paired_mean_test(champion, outcomes, alpha=alpha) for _, outcomes in candidates]
    adjusted = holm_bonferroni([test.p_value for test in tests], alpha=alpha)
    return [
        ChallengerResult(
            candidate=pair[0],
            test=test,
            adjusted_p=adj.adjusted_p,
            promoted=adj.reject and test.mean_delta >= minimum_mean_delta,
        )
        for pair, test, adj in zip(candidates, tests, adjusted)
    ]
