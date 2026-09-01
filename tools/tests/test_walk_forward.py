"""
tools/tests/test_walk_forward.py — zero coverage existed on this file
before this suite. Covers split_train_holdout()'s window-boundary math
directly (easy to get an off-by-one on which side of holdout_start a row
lands), compute_walk_forward_report()'s three verdict states, and pins
down that ingest_tester_csv() is a deliberate stub, not a silently
broken implementation, per its own docstring.
"""
import pytest
from datetime import datetime, timedelta, timezone

from walk_forward import compute_walk_forward_report, ingest_tester_csv, split_train_holdout

NOW = datetime(2026, 8, 1, tzinfo=timezone.utc)


def test_split_train_holdout_boundary_placement(make_outcome):
    rows = [
        make_outcome(received_at=NOW - timedelta(weeks=5)),   # older than the 4-week reference window -> dropped
        make_outcome(received_at=NOW - timedelta(weeks=3)),   # in reference, before holdout -> train
        make_outcome(received_at=NOW - timedelta(days=3)),    # inside the 1-week holdout window -> holdout
        make_outcome(received_at=NOW - timedelta(hours=1)),   # inside holdout -> holdout
    ]
    train, holdout = split_train_holdout(rows, reference_weeks=4, holdout_weeks=1, now=NOW)
    assert len(train) == 1
    assert len(holdout) == 2


def test_split_train_holdout_drops_rows_with_no_received_at(make_outcome):
    rows = [make_outcome(received_at=None), make_outcome(received_at=NOW - timedelta(days=1))]
    train, holdout = split_train_holdout(rows, reference_weeks=4, holdout_weeks=1, now=NOW)
    assert (len(train) + len(holdout)) == 1  # the None-received_at row must be silently excluded, not crash


def test_walk_forward_verdict_insufficient_data_with_no_resolved_rows(make_outcome):
    rows = [make_outcome(weight_version="v2.11-baseline", outcome="no_fill", received_at=NOW - timedelta(days=1))]
    report = compute_walk_forward_report(rows, "v2.11-baseline", reference_weeks=4, holdout_weeks=1)
    assert report["verdict"] == "insufficient_data"
    assert report["overlap"] is None


def test_walk_forward_verdict_consistent_when_train_and_holdout_agree(make_outcome):
    wv = "v2.11-baseline"
    rows = []
    # Train: ~50% win rate, well inside the reference window but outside holdout
    for i in range(40):
        rows.append(make_outcome(
            weight_version=wv, outcome=("win" if i % 2 == 0 else "loss"), realized_r=(1.0 if i % 2 == 0 else -1.0),
            received_at=NOW - timedelta(weeks=2, days=i % 5),
        ))
    # Holdout: also ~50% win rate, inside the 1-week holdout window
    for i in range(40):
        rows.append(make_outcome(
            weight_version=wv, outcome=("win" if i % 2 == 0 else "loss"), realized_r=(1.0 if i % 2 == 0 else -1.0),
            received_at=NOW - timedelta(hours=i),
        ))
    report = compute_walk_forward_report(rows, wv, reference_weeks=4, holdout_weeks=1)
    assert report["verdict"] == "consistent"
    assert report["overlap"] is True


def test_walk_forward_verdict_diverged_when_holdout_regresses(make_outcome):
    wv = "v2.11-baseline"
    rows = []
    # Train: strong win rate
    for i in range(60):
        rows.append(make_outcome(
            weight_version=wv, outcome=("win" if i < 50 else "loss"), realized_r=(1.0 if i < 50 else -1.0),
            received_at=NOW - timedelta(weeks=2, hours=i),
        ))
    # Holdout: weak win rate -- a genuine regression, not noise
    for i in range(60):
        rows.append(make_outcome(
            weight_version=wv, outcome=("win" if i < 10 else "loss"), realized_r=(1.0 if i < 10 else -1.0),
            received_at=NOW - timedelta(hours=i),
        ))
    report = compute_walk_forward_report(rows, wv, reference_weeks=4, holdout_weeks=1)
    assert report["verdict"] == "diverged"
    assert report["overlap"] is False


def test_walk_forward_filters_to_requested_weight_version_only(make_outcome):
    rows = [
        make_outcome(weight_version="v2.11-baseline", outcome="win", realized_r=1.0, received_at=NOW - timedelta(hours=1)),
        make_outcome(weight_version="v2.10-old", outcome="win", realized_r=1.0, received_at=NOW - timedelta(hours=1)),
    ]
    report = compute_walk_forward_report(rows, "v2.11-baseline", reference_weeks=4, holdout_weeks=1)
    # Only the matching weight_version's row should ever reach the
    # holdout report -- a stray other-version row leaking in would
    # silently pollute the comparison this whole function exists for.
    assert report["holdout"]["coverage"]["total_signals"] == 1


def test_ingest_tester_csv_is_a_documented_stub_not_silently_broken():
    with pytest.raises(NotImplementedError):
        ingest_tester_csv("/nonexistent/path.csv")
