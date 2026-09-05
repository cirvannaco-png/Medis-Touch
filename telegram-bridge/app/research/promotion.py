"""Champion/challenger comparison and fail-closed promotion gate."""
from __future__ import annotations
from dataclasses import dataclass
from math import sqrt
from statistics import mean
from typing import Sequence
from .validation import max_drawdown

@dataclass(frozen=True)
class GatePolicy:
    min_trades: int = 100
    min_expectancy_r: float = 0.05
    max_drawdown_r: float = -10.0
    min_win_rate: float = 0.45
    min_effect_size_r: float = 0.02
    require_holdout: bool = True

@dataclass(frozen=True)
class PromotionDecision:
    action: str
    reason: str
    champion_mean_r: float
    challenger_mean_r: float
    delta_r: float
    challenger_drawdown_r: float
    challenger_win_rate: float
    n: int


def compare(champion_rs: Sequence[float], challenger_rs: Sequence[float]) -> dict:
    n = min(len(champion_rs), len(challenger_rs))
    if n == 0:
        return {"n": 0, "delta_r": 0.0, "paired_mean_r": 0.0, "paired_se": 0.0}
    c, x = champion_rs[:n], challenger_rs[:n]
    diffs = [b - a for a, b in zip(c, x)]
    m = mean(diffs)
    se = (mean([(d - m) ** 2 for d in diffs]) ** 0.5 / sqrt(max(1, n - 1))) / sqrt(n) if n > 1 else 0.0
    return {"n": n, "delta_r": m, "paired_mean_r": m, "paired_se": se}


def gate(champion_rs: Sequence[float], challenger_rs: Sequence[float], policy: GatePolicy = GatePolicy(), holdout_passed: bool = False) -> PromotionDecision:
    n = len(challenger_rs)
    avg = mean(challenger_rs) if challenger_rs else 0.0
    win_rate = sum(r > 0 for r in challenger_rs) / n if n else 0.0
    dd = max_drawdown(challenger_rs)
    cmp = compare(champion_rs, challenger_rs)
    checks = [
        (n >= policy.min_trades, "insufficient sample"),
        (avg >= policy.min_expectancy_r, "expectancy below threshold"),
        (dd >= policy.max_drawdown_r, "drawdown breach"),
        (win_rate >= policy.min_win_rate, "win rate below threshold"),
        (cmp["delta_r"] >= policy.min_effect_size_r, "no practical paired improvement"),
        (not policy.require_holdout or holdout_passed, "holdout not passed"),
    ]
    failed = next((reason for ok, reason in checks if not ok), None)
    return PromotionDecision(
        "PROMOTE" if failed is None else "REJECT",
        "all promotion gates passed" if failed is None else failed,
        mean(champion_rs) if champion_rs else 0.0,
        avg,
        cmp["delta_r"], dd, win_rate, n,
    )
