"""
tools/tests/test_stats.py — the shared math foundation gating.py,
metrics_engine.py, and walk_forward.py all build their CIs on. Zero
coverage existed anywhere in this codebase before this file; these
mostly pin down the edge cases the module's own docstrings call out by
name (empty samples, single-class AUC, n<4 Pearson, zero variance) so a
future refactor can't quietly break one without a test noticing.
"""
import math

from stats import Stat, auc_with_ci, direction, intervals_overlap, pearson_ci, wilson_ci


def test_wilson_ci_empty_sample_is_not_estimable():
    s = wilson_ci(0, 0)
    assert s.value is None
    assert not s.is_estimable


def test_wilson_ci_matches_known_point_estimate():
    s = wilson_ci(successes=50, n=100)
    assert s.value == 0.5
    assert s.ci_low < 0.5 < s.ci_high
    assert 0.0 <= s.ci_low and s.ci_high <= 1.0


def test_wilson_ci_narrows_with_more_data():
    small = wilson_ci(5, 10)
    large = wilson_ci(500, 1000)
    assert (large.ci_high - large.ci_low) < (small.ci_high - small.ci_low)


def test_auc_requires_both_classes():
    assert not auc_with_ci([80.0, 90.0], []).is_estimable
    assert not auc_with_ci([], [10.0, 20.0]).is_estimable


def test_auc_perfect_separation_is_one():
    s = auc_with_ci(win_scores=[90.0, 85.0, 80.0], loss_scores=[20.0, 15.0, 10.0])
    assert s.value == 1.0


def test_auc_ties_count_as_half():
    # a win's score exactly equal to a loss's score -> that pair
    # contributes 0.5, not 0 or 1 (see the module's own comment on this)
    s = auc_with_ci(win_scores=[50.0], loss_scores=[50.0])
    assert s.value == 0.5


def test_pearson_requires_at_least_four_pairs():
    assert not pearson_ci([(1.0, 1.0), (2.0, 2.0), (3.0, 3.0)]).is_estimable


def test_pearson_perfect_positive_correlation():
    pairs = [(float(x), float(x)) for x in range(1, 6)]
    s = pearson_ci(pairs)
    # Not exactly 1.0 -- pearson_ci clamps to +/-0.999999 to keep atanh()
    # inside its domain (see the module's own comment on that guard).
    assert math.isclose(s.value, 1.0, abs_tol=1e-5)


def test_pearson_zero_variance_side_is_not_estimable():
    pairs = [(5.0, 1.0), (5.0, 2.0), (5.0, 3.0), (5.0, 4.0)]  # x never varies -> denom is 0
    assert not pearson_ci(pairs).is_estimable


def test_intervals_overlap_none_when_not_estimable():
    assert intervals_overlap(Stat.empty(0), wilson_ci(5, 10)) is None


def test_intervals_overlap_true_for_close_estimates():
    assert intervals_overlap(wilson_ci(50, 100), wilson_ci(52, 100)) is True


def test_intervals_overlap_false_for_clearly_different_estimates():
    assert intervals_overlap(wilson_ci(90, 100), wilson_ci(10, 100)) is False


def test_direction_up_down_flat():
    low, high = wilson_ci(10, 100), wilson_ci(90, 100)
    assert direction(low, high) == "up"
    assert direction(high, low) == "down"
    assert direction(low, low) == "flat"


def test_direction_none_when_not_estimable():
    assert direction(Stat.empty(0), wilson_ci(5, 10)) is None
