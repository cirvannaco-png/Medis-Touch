"""Tests for the numeric parameter-proposal engine."""

import pytest

from app.parameter_proposal.bounds import PARAMETERS
from app.parameter_proposal.candidates import generate_candidates
from app.parameter_proposal.gates import (
    parameter_movement_ok,
    regime_gate,
    statistical_gate,
)
from app.parameter_proposal.models import ParameterSet
from app.parameter_proposal.objective import objective, score_evaluation
from app.parameter_proposal.proposer import ParameterProposalEngine
from app.parameter_proposal.robustness import evaluate_robustness
from app.parameter_proposal.statistics import bootstrap_mean_ci
from app.parameter_proposal.versioning import (
    configuration_hash,
    configuration_version,
)


def current_set():
    return ParameterSet(
        values={name: spec.default for name, spec in PARAMETERS.items()},
        parent_version="mtcfg_base",
    )


def make_evaluation(trades=400, expectancy_r=0.30, profit_factor=1.4,
                    max_drawdown_r=3.0, expected_shortfall_r=-1.0,
                    win_rate=0.55, turnover=1.0, regime_score=0.2):
    return score_evaluation(
        trades=trades,
        expectancy_r=expectancy_r,
        profit_factor=profit_factor,
        max_drawdown_r=max_drawdown_r,
        expected_shortfall_r=expected_shortfall_r,
        win_rate=win_rate,
        turnover=turnover,
        by_regime={"trend": regime_score, "range": regime_score},
        by_session={"london": regime_score},
        by_symbol={"XAUUSD": regime_score},
    )


class FakeEvaluator:
    """Better objective for any candidate that differs from the baseline."""

    def __init__(self):
        self.baseline_values = None

    def evaluate(self, parameter_set):
        if self.baseline_values is None:
            self.baseline_values = dict(parameter_set.values)
            return make_evaluation()
        if parameter_set.values == self.baseline_values:
            return make_evaluation()
        return make_evaluation(expectancy_r=0.45, regime_score=0.25)

    def evaluate_neighbors(self, parameter_set):
        return [make_evaluation(expectancy_r=0.44, regime_score=0.24) for _ in range(4)]


# --- candidates -----------------------------------------------------------

def test_candidates_are_bounded_and_off_default():
    current = current_set()
    candidates = generate_candidates(current, PARAMETERS)
    assert candidates, "expected candidates"
    for cand in candidates:
        changed = [n for n in current.values if cand.values[n] != current.values[n]]
        assert len(changed) == 1  # single-parameter moves only
        spec = PARAMETERS[changed[0]]
        assert spec.minimum <= cand.values[changed[0]] <= spec.maximum


def test_candidates_respect_max_count():
    current = current_set()
    assert len(generate_candidates(current, PARAMETERS, max_candidates=5)) == 5


def test_immutable_spec_not_moved():
    current = current_set()
    specs = dict(PARAMETERS)
    spec = specs["ensemble_threshold"]
    specs["ensemble_threshold"] = type(spec)(
        spec.name, spec.kind, spec.minimum, spec.maximum, spec.step,
        spec.default, mutable=False,
    )
    candidates = generate_candidates(current, specs)
    assert all(c.values["ensemble_threshold"] == current.values["ensemble_threshold"]
               for c in candidates)


# --- gates ----------------------------------------------------------------

def test_movement_gate_accepts_small_move():
    current = current_set()
    values = dict(current.values)
    values["ensemble_threshold"] = 63
    ok, failures = parameter_movement_ok(current, ParameterSet(values, "v"), PARAMETERS)
    assert ok, failures


def test_movement_gate_rejects_large_move():
    current = current_set()
    values = dict(current.values)
    values["ensemble_threshold"] = 80  # exceeds absolute change 5
    ok, failures = parameter_movement_ok(current, ParameterSet(values, "v"), PARAMETERS)
    assert not ok
    assert any("ensemble_threshold" in f for f in failures)


def test_movement_gate_rejects_out_of_bounds():
    current = current_set()
    values = dict(current.values)
    values["freshness_bars"] = 99
    ok, _ = parameter_movement_ok(current, ParameterSet(values, "v"), PARAMETERS)
    assert not ok


def test_statistical_gate():
    baseline = make_evaluation(expectancy_r=0.30)
    good = make_evaluation(expectancy_r=0.40)
    ok, _ = statistical_gate(baseline, good)
    assert ok
    few_trades = make_evaluation(expectancy_r=0.40, trades=50)
    ok, failures = statistical_gate(baseline, few_trades)
    assert not ok and "insufficient_candidate_trades" in failures
    tiny_gain = make_evaluation(expectancy_r=0.31)
    ok, failures = statistical_gate(baseline, tiny_gain)
    assert not ok and "expectancy_improvement_too_small" in failures
    low_pf = make_evaluation(expectancy_r=0.40, profit_factor=1.01)
    ok, failures = statistical_gate(baseline, low_pf)
    assert not ok and "candidate_profit_factor_too_low" in failures


def test_regime_gate():
    base = {"trend": 0.4, "range": 0.2}
    ok, _ = regime_gate(base, {"trend": 0.35, "range": 0.19})
    assert ok
    ok, failures = regime_gate(base, {"trend": 0.1, "range": 0.19})
    assert not ok and any("trend" in f for f in failures)
    ok, failures = regime_gate(base, {"trend": 0.35})
    assert not ok and any("range" in f for f in failures)


# --- statistics / objective / versioning ----------------------------------

def test_bootstrap_ci_deterministic_and_brackets_mean():
    returns = [0.1, -0.2, 0.3, 0.05, -0.1, 0.2, 0.15, -0.05]
    mean, lo, hi = bootstrap_mean_ci(returns, iterations=500, seed=7)
    assert lo <= mean <= hi
    assert bootstrap_mean_ci(returns, iterations=500, seed=7) == (mean, lo, hi)
    with pytest.raises(ValueError):
        bootstrap_mean_ci([0.1])


def test_objective_penalizes_drawdown_and_turnover():
    better = objective(0.5, 2.0, -1.0, 1.0)
    worse = objective(0.5, 6.0, -2.0, 3.0)
    assert better > worse


def test_versioning_is_deterministic_and_order_insensitive():
    a = {"x": 1, "y": [1, 2]}
    b = {"y": [1, 2], "x": 1}
    assert configuration_hash(a) == configuration_hash(b)
    assert configuration_version(a).startswith("mtcfg_")
    assert configuration_version(a) == configuration_version(b)


# --- robustness / proposer --------------------------------------------------

def test_robustness_no_neighbors_fails():
    class Empty:
        def evaluate_neighbors(self, ps):
            return []

        def evaluate(self, ps):
            return make_evaluation()

    result = evaluate_robustness(current_set(), Empty())
    assert not result.stable


def test_proposer_emits_pending_approval_proposals():
    engine = ParameterProposalEngine(FakeEvaluator())
    proposals = engine.propose(current_set())
    assert proposals, "expected at least one proposal from the fake evaluator"
    for p in proposals:
        assert p.status == "PENDING_APPROVAL"
        assert p.gates_failed == ()
        assert "statistical" in p.gates_passed
        assert p.proposal_id.startswith("pp_")
    objectives = [p.candidate.objective for p in proposals]
    assert objectives == sorted(objectives, reverse=True)


def test_proposer_returns_empty_when_no_improvement():
    class Flat:
        def evaluate(self, ps):
            return make_evaluation()

        def evaluate_neighbors(self, ps):
            return [make_evaluation()]

    engine = ParameterProposalEngine(Flat())
    assert engine.propose(current_set()) == []
