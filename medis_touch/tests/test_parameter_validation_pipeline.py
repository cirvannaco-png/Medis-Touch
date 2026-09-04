from datetime import datetime, timedelta, timezone

import pytest

from app.parameter_proposal.bounds import PARAMETERS
from app.parameter_proposal.config.canonical import canonical_json, config_hash
from app.parameter_proposal.config.schema import validate_parameter_set
from app.parameter_proposal.models import ParameterSet
from app.parameter_proposal.multiple_testing import holm_bonferroni
from app.parameter_proposal.paired_stats import paired_mean_test
from app.parameter_proposal.search_budget import SearchBudget
from app.parameter_proposal.walk_forward import make_windows


def parameter_set():
    return ParameterSet({name: spec.default for name, spec in PARAMETERS.items()}, "champion-v1")


def test_config_hash_is_order_independent():
    values = {"b": 2, "a": 1}
    assert canonical_json(values) == '{"a":1,"b":2}'
    assert config_hash(values) == config_hash({"a": 1, "b": 2})


def test_parameter_schema_is_fail_closed():
    current = parameter_set()
    assert validate_parameter_set(current)[0]
    invalid = ParameterSet({**current.values, "ensemble_threshold": 100}, current.parent_version)
    ok, failures = validate_parameter_set(invalid)
    assert not ok
    assert "ensemble_threshold:above_maximum" in failures


def test_search_budget_monotonically_reduces_compute():
    budget = SearchBudget()
    assert budget.max_candidates >= budget.max_statistical_survivors
    assert budget.max_statistical_survivors >= budget.max_walk_forward_survivors
    assert budget.max_walk_forward_survivors >= budget.max_robustness_survivors
    assert budget.max_robustness_survivors >= budget.max_holdout_finalists


def test_holm_bonferroni_controls_familywise_search():
    result = holm_bonferroni([0.001, 0.02, 0.4])
    assert result[0].adjusted_p <= result[1].adjusted_p
    assert result[0].reject
    assert not result[2].reject


def test_paired_test_requires_equal_opportunities():
    result = paired_mean_test([0.0, 0.0, 0.0], [1.0, 1.0, 1.0])
    assert result.n == 3
    assert result.mean_delta == pytest.approx(1.0)
    with pytest.raises(ValueError, match="equal length"):
        paired_mean_test([0.0], [0.0, 1.0])


def test_walk_forward_windows_are_temporal_and_purged():
    start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    rows = [{"received_at": start + timedelta(days=i)} for i in range(50)]
    windows = make_windows(rows, train_days=14, test_days=7, step_days=7, purge_days=2)
    assert windows
    first = windows[0]
    assert first.train_end + timedelta(days=2) == first.test_start
    assert first.train_end <= first.test_start
