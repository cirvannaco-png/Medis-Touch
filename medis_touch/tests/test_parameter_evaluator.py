"""Tests for the real-outcome parameter evaluator."""
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import pytest

from app.parameter_proposal.bounds import PARAMETERS
from app.parameter_proposal.evaluator import OutcomeEvaluator
from app.parameter_proposal.models import ParameterSet
from app.parameter_proposal.proposer import ParameterProposalEngine


@dataclass
class Outcome:
    signal_id: str
    outcome: str
    realized_r: float | None
    regime: str | None = "trend"
    session: str | None = "london"
    symbol: str | None = "XAUUSD"
    received_at: datetime | None = None


def parameter_set() -> ParameterSet:
    return ParameterSet(
        values={name: spec.default for name, spec in PARAMETERS.items()},
        parent_version="mtcfg_base",
    )


def real_outcomes() -> list[Outcome]:
    start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    return [
        Outcome("s1", "win", 1.5, received_at=start),
        Outcome("s2", "loss", -1.0, regime="range", received_at=start + timedelta(hours=1)),
        Outcome("s3", "scratch", 0.0, received_at=start + timedelta(hours=2)),
        Outcome("s4", "no_fill", None, received_at=start + timedelta(hours=3)),
        Outcome("s5", "ambiguous", None, received_at=start + timedelta(hours=4)),
    ]


def test_evaluator_scores_replayed_real_outcomes_and_keeps_tags():
    calls = []

    def replay(candidate, rows):
        calls.append((candidate, tuple(rows)))
        return rows

    evaluation = OutcomeEvaluator(real_outcomes(), replay).evaluate(parameter_set())

    assert evaluation.trades == 3
    assert evaluation.expectancy_r == pytest.approx(1 / 6)
    assert evaluation.profit_factor == pytest.approx(1.5)
    assert evaluation.max_drawdown_r == pytest.approx(1.0)
    assert evaluation.expected_shortfall_r == pytest.approx(-1.0)
    assert evaluation.win_rate == pytest.approx(1 / 3)
    assert evaluation.turnover == pytest.approx(5 / 3)
    assert evaluation.by_regime == {"range": -1.0, "trend": 0.75}
    assert evaluation.by_session == {"london": pytest.approx(1 / 6)}
    assert evaluation.by_symbol == {"XAUUSD": pytest.approx(1 / 6)}
    assert calls[0][0] == parameter_set()
    assert len(calls[0][1]) == 5


def test_evaluator_requires_replay_and_never_scores_baseline_as_candidates():
    with pytest.raises(TypeError, match="replay"):
        OutcomeEvaluator(real_outcomes(), None)  # type: ignore[arg-type]


def test_evaluator_rejects_incomplete_resolved_outcomes():
    rows = [Outcome("broken", "win", None)]
    evaluator = OutcomeEvaluator(rows, lambda _, data: data)

    with pytest.raises(ValueError, match="realized_r"):
        evaluator.evaluate(parameter_set())


def test_evaluator_rejects_only_unresolved_outcomes():
    rows = [Outcome("missed", "no_fill", None)]
    evaluator = OutcomeEvaluator(rows, lambda _, data: data)

    with pytest.raises(ValueError, match="resolved"):
        evaluator.evaluate(parameter_set())


def test_neighbors_use_bounded_real_replays():
    seen = []

    def replay(candidate, rows):
        seen.append(candidate)
        return rows[:3]

    neighbors = list(OutcomeEvaluator(real_outcomes(), replay).evaluate_neighbors(parameter_set()))

    assert neighbors
    assert len(seen) == len(neighbors)
    assert all(evaluation.trades == 3 for evaluation in neighbors)


def test_live_proposals_reject_non_real_evaluators():
    with pytest.raises(RuntimeError, match="real outcomes"):
        ParameterProposalEngine(object()).propose_live(parameter_set())