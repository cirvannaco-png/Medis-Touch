from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any


@dataclass(frozen=True)
class ParameterSpec:
    name: str
    kind: str
    minimum: float | int | None
    maximum: float | int | None
    step: float | int | None
    default: Any
    mutable: bool = True
    max_relative_change: float = 0.20
    max_absolute_change: float | int | None = None


@dataclass(frozen=True)
class ParameterSet:
    values: dict[str, Any]
    parent_version: str


@dataclass(frozen=True)
class Evaluation:
    trades: int
    expectancy_r: float
    profit_factor: float
    max_drawdown_r: float
    expected_shortfall_r: float
    win_rate: float
    turnover: float
    objective: float
    by_regime: dict[str, float]
    by_session: dict[str, float]
    by_symbol: dict[str, float]


@dataclass(frozen=True)
class RobustnessResult:
    stable: bool
    neighborhood_score: float
    worst_neighbor_objective: float
    best_neighbor_objective: float
    degradation_pct: float


@dataclass(frozen=True)
class Proposal:
    proposal_id: str
    parameter_set: ParameterSet
    parent_version: str
    created_at: datetime
    baseline: Evaluation
    candidate: Evaluation
    robustness: RobustnessResult
    confidence: float
    reasons: tuple[str, ...]
    gates_passed: tuple[str, ...]
    gates_failed: tuple[str, ...]
    status: str
