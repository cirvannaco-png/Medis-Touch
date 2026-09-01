"""
tools/tests/test_gating.py — zero coverage existed on this file before
this suite. gating.py's own docstring spells out four things that must
never silently degrade: mixed live/synthetic cycles must raise, an
untagged cycle must raise, overlapping CIs must mean HOLD not a coin
flip, and a genuine direction contradiction must ROLLBACK rather than
average itself away. Each gets a direct test.
"""
from gating import GatingError, _validate_cycles, decide
from stats import wilson_ci

WV = "v2.11-candidate"


def _cycle(cycle_id, source, win_rate_stat, generated_at="2026-01-01T00:00:00+00:00"):
    """
    Builds a cycle dict in the exact shape compute_report() produces
    (see metrics_engine.py) but only populates win_rate -- decide()'s
    _extract_stat() falls back to Stat.empty(0) for a metric key that
    isn't present, so confidence_auc/confidence_r_correlation are safe
    to leave out when a test only needs to drive win_rate.
    """
    return {
        "cycle_id": cycle_id,
        "source": source,
        "generated_at": generated_at,
        "expectancy": {"by_weight_version_stats": {WV: {"win_rate": win_rate_stat.to_dict()}}},
    }


# --- _validate_cycles ------------------------------------------------

def test_validate_cycles_rejects_empty_history():
    try:
        _validate_cycles([], WV)
        assert False, "expected GatingError"
    except GatingError as e:
        assert "empty" in str(e).lower()


def test_validate_cycles_rejects_mixed_sources():
    cycles = [_cycle("c0", "live", wilson_ci(50, 100)), _cycle("c1", "synthetic", wilson_ci(50, 100))]
    try:
        _validate_cycles(cycles, WV)
        assert False, "expected GatingError"
    except GatingError as e:
        assert "mixes synthetic and live" in str(e)


def test_validate_cycles_rejects_missing_tags():
    cycles = [{"expectancy": {}}]  # no source, no cycle_id
    try:
        _validate_cycles(cycles, WV)
        assert False, "expected GatingError"
    except GatingError as e:
        assert "missing required" in str(e)


def test_validate_cycles_accepts_pure_live_history():
    cycles = [_cycle("c0", "live", wilson_ci(50, 100)), _cycle("c1", "live", wilson_ci(52, 100))]
    _validate_cycles(cycles, WV)  # must not raise


# --- decide() ----------------------------------------------------------

def test_decide_insufficient_data_below_persistence_threshold():
    cycles = [_cycle("c0", "live", wilson_ci(50, 100)), _cycle("c1", "live", wilson_ci(55, 100))]
    d = decide(cycles, WV)  # 2 cycles < min_persistence(2)+1
    assert d.action == "INSUFFICIENT_DATA"
    assert d.cycles_considered == 2


def test_decide_holds_when_cis_overlap_throughout():
    cycles = [
        _cycle("c0", "live", wilson_ci(48, 100)),
        _cycle("c1", "live", wilson_ci(50, 100)),
        _cycle("c2", "live", wilson_ci(52, 100)),
    ]
    d = decide(cycles, WV)
    assert d.action == "HOLD"


def test_decide_promotes_on_persistent_improvement():
    cycles = [
        _cycle("c0", "live", wilson_ci(20, 100)),
        _cycle("c1", "live", wilson_ci(50, 100)),
        _cycle("c2", "live", wilson_ci(85, 100)),
    ]
    d = decide(cycles, WV)
    assert d.action == "PROMOTE"
    assert d.cycles_considered == 3


def test_decide_rolls_back_on_persistent_regression():
    cycles = [
        _cycle("c0", "live", wilson_ci(85, 100)),
        _cycle("c1", "live", wilson_ci(50, 100)),
        _cycle("c2", "live", wilson_ci(20, 100)),
    ]
    d = decide(cycles, WV)
    assert d.action == "ROLLBACK"


def test_decide_rolls_back_on_contradiction_not_average():
    # up then down for the same metric -- must ROLLBACK with a
    # CONTRADICTION reason, never quietly resolve to HOLD/PROMOTE.
    cycles = [
        _cycle("c0", "live", wilson_ci(20, 100)),
        _cycle("c1", "live", wilson_ci(80, 100)),
        _cycle("c2", "live", wilson_ci(20, 100)),
    ]
    d = decide(cycles, WV)
    assert d.action == "ROLLBACK"
    assert any("CONTRADICTION" in line for line in d.reasoning)


def test_decide_refuses_mixed_source_history():
    cycles = [
        _cycle("c0", "live", wilson_ci(50, 100)),
        _cycle("c1", "synthetic", wilson_ci(60, 100)),
        _cycle("c2", "live", wilson_ci(70, 100)),
    ]
    try:
        decide(cycles, WV)
        assert False, "expected GatingError"
    except GatingError:
        pass
