"""
tools/tests/test_metrics_engine.py — zero coverage existed on this file
before this suite, despite it being the report every downstream tool
(gating.py, walk_forward.py) is built on top of. Focused on the
arithmetic that's easy to get subtly wrong: no_fill/ambiguous rows must
count toward coverage but never expectancy, decile bucket boundaries,
and compute_regime_matrix's profit-factor/drawdown math against a
hand-computed sequence.
"""
from datetime import datetime, timedelta, timezone

from metrics_engine import compute_regime_matrix, compute_report


def test_compute_report_totals_and_no_fill_rate(make_outcome):
    rows = [
        make_outcome(outcome="win", realized_r=1.0),
        make_outcome(outcome="loss", realized_r=-1.0),
        make_outcome(outcome="no_fill", realized_r=None),
        make_outcome(outcome="no_fill", realized_r=None),
    ]
    report = compute_report(rows)
    cov = report["coverage"]
    assert cov["total_signals"] == 4
    assert cov["no_fill_count"] == 2
    assert cov["no_fill_rate"] == 0.5


def test_no_fill_and_ambiguous_excluded_from_expectancy(make_outcome):
    rows = [
        make_outcome(outcome="win", realized_r=2.0),
        make_outcome(outcome="no_fill", realized_r=None),
        make_outcome(outcome="ambiguous", realized_r=None),
    ]
    exp = compute_report(rows)["expectancy"]
    # resolved_count must be 1 (the win only) -- a no_fill/ambiguous row
    # contributing to expectancy's denominator would silently understate
    # win rate and avg R for every symbol with a lot of missed fills.
    assert exp["resolved_count"] == 1
    assert exp["overall_win_rate"] == 1.0
    assert exp["overall_avg_r"] == 2.0


def test_directional_bias_breakdown(make_outcome):
    rows = [
        make_outcome(direction="BUY", outcome="win", realized_r=1.0),
        make_outcome(direction="BUY", outcome="no_fill"),
        make_outcome(direction="SELL", outcome="win", realized_r=1.0),
    ]
    bias = compute_report(rows)["coverage"]["directional_bias"]
    assert bias["BUY"]["count"] == 2
    assert bias["BUY"]["no_fill_rate"] == 0.5
    assert bias["SELL"]["count"] == 1
    assert bias["SELL"]["no_fill_rate"] == 0.0


def test_by_regime_bucketing_untagged_and_win_rate(make_outcome):
    rows = [
        make_outcome(regime="TRENDING", outcome="win", realized_r=1.0),
        make_outcome(regime="TRENDING", outcome="loss", realized_r=-1.0),
        make_outcome(regime=None, outcome="win", realized_r=1.0),  # untagged
    ]
    report = compute_report(rows)
    by_regime_cov = report["coverage"]["by_regime"]
    by_regime_exp = report["expectancy"]["by_regime"]
    assert by_regime_cov["TRENDING"]["total"] == 2
    assert by_regime_exp["TRENDING"]["win_rate"] == 0.5
    assert "(untagged)" in by_regime_cov  # None must not be silently dropped


def test_confidence_deciles_bucket_boundaries(make_outcome):
    rows = [
        make_outcome(outcome="win", realized_r=1.0, confidence_at_signal=65.0),
        make_outcome(outcome="loss", realized_r=-1.0, confidence_at_signal=69.9),
        make_outcome(outcome="win", realized_r=2.0, confidence_at_signal=70.0),  # next bucket up
    ]
    deciles = compute_report(rows)["expectancy"]["realized_r_by_confidence_decile"]
    assert deciles["60-70"]["n"] == 2
    assert deciles["60-70"]["avg_r"] == 0.0  # (1.0 + -1.0) / 2
    assert deciles["70-80"]["n"] == 1
    assert deciles["70-80"]["avg_r"] == 2.0


def test_htf_ob_aligned_none_maps_to_not_aligned_not_dropped(make_outcome):
    rows = [
        make_outcome(outcome="win", realized_r=1.0, htf_ob_aligned=True),
        make_outcome(outcome="loss", realized_r=-1.0, htf_ob_aligned=None),
    ]
    by_align = compute_report(rows)["expectancy"]["by_htf_ob_aligned"]
    assert by_align["aligned"]["resolved_count"] == 1
    assert by_align["not_aligned"]["resolved_count"] == 1


def test_compute_regime_matrix_excludes_unresolved(make_outcome):
    rows = [
        make_outcome(symbol="XAUUSD", outcome="win", realized_r=1.0),
        make_outcome(symbol="XAUUSD", outcome="no_fill"),
    ]
    matrix = compute_regime_matrix(rows)
    assert len(matrix) == 1
    assert matrix[0]["trades"] == 1


def test_compute_regime_matrix_profit_factor_and_drawdown_hand_computed(make_outcome):
    # Chronological R sequence: +1, -0.5, +2, -3, +1
    # cumulative: 1, 0.5, 2.5, -0.5, 0.5  ->  running peak: 1, 1, 2.5, 2.5, 2.5
    # drawdown (peak-cum): 0, 0.5, 0, 3.0, 2.0  -> max_dd = 3.0
    # gains = 1+2+1 = 4, losses_abs = 0.5+3 = 3.5 -> pf = 4/3.5
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    r_sequence = [1.0, -0.5, 2.0, -3.0, 1.0]
    rows = [
        make_outcome(
            symbol="XAUUSD", session="London", regime="TRENDING",
            outcome=("win" if r > 0 else "loss"), realized_r=r,
            received_at=base + timedelta(hours=i),
        )
        for i, r in enumerate(r_sequence)
    ]
    matrix = compute_regime_matrix(rows)
    assert len(matrix) == 1
    bucket = matrix[0]
    assert bucket["symbol"] == "XAUUSD"
    assert bucket["session"] == "London"
    assert bucket["regime"] == "TRENDING"
    assert bucket["trades"] == 5
    assert bucket["win_rate"] == 3 / 5
    assert bucket["avg_r"] == 0.5 / 5
    assert bucket["profit_factor"] == 4.0 / 3.5
    assert bucket["max_drawdown_r"] == 3.0


def test_compute_regime_matrix_pf_is_none_with_no_losses(make_outcome):
    rows = [make_outcome(outcome="win", realized_r=1.0, received_at=datetime.now(timezone.utc))]
    matrix = compute_regime_matrix(rows)
    # No losses -> profit factor is genuinely undefined, must be None,
    # never a fabricated large number or float("inf") -- see the
    # function's own docstring on this exact point.
    assert matrix[0]["profit_factor"] is None
