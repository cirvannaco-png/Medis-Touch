from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def test_live_trade_setup_has_first_class_invalidation_and_structural_validity():
    c = read("EA/includes/Core/Config.mqh")
    assert c.count("struct TradeSetup") == 1
    assert "double            invalidation;" in c
    assert "bool              structural_valid;" in c
    assert "ENUM_SETUP_STATUS status;" in c
    assert "string            setup_id;" in c


def test_fvg_formation_is_closed_bar_only():
    c = read("EA/includes/SmartMoney/FVG.mqh")
    assert "for(int i = 3; i < total; i++)" in c
    assert "m_degradeBars" in c
    assert "m_maxAgeBars" in c


def test_choch_cannot_break_from_live_bar_and_requires_swing_confirmation():
    c = read("EA/includes/Structure/CHOCH.mqh")
    assert "int confirmationShift = curr.bar_index - m_swings.Strength();" in c
    assert "for(int bar = confirmationShift; bar >= 1; bar--)" in c


def test_inducement_minor_swing_never_uses_candle_zero_as_neighbor():
    c = read("EA/includes/SmartMoney/Inducement.mqh")
    assert "if(idx < 2 || idx >= total - 1) return false;" in c


def test_value_area_profile_excludes_forming_bar():
    c = read("EA/includes/SmartMoney/ValueAreaEngine.mqh")
    assert "int bars = MathMin(m_lookbackBars, total - 1);" in c
    assert "for(int i = 1; i <= bars; i++)" in c


def test_broker_stop_validation_fails_closed_when_point_size_missing():
    c = read("EA/includes/Execution/BrokerAdapter.mqh")
    assert "if(point <= 0.0) return false;" in c
    assert "if(point <= 0.0) return true;" not in c


def test_tradezone_is_structurally_gated():
    c = read("EA/includes/Trading/TradeZone.mqh")
    assert '#include "../Analysis/StructuralValidator.mqh"' in c
    assert "if(!m_validator.Validate(true, sv))" in c
    assert "if(!m_validator.Validate(false, sv))" in c


def test_strategy_selector_runtime_overlay_is_not_mutating_live_setup():
    c = read("EA/includes/Trading/TradeZone.mqh")
    assert "RuntimeStrategyThreshold" not in c
    assert "ApplyRuntimeOverlay" not in c


def test_signal_payload_preserves_zone_invalidation_and_expiry():
    c = read("EA/includes/Signals/SignalPublisher.mqh")
    assert '\\\"expires_at\\\":%d' in c
    assert "entry_top" in c
    assert "entry_bottom" in c
    assert "invalidation" in c
    assert "structural_quality" in c


def test_decision_store_persists_v216_provenance():
    c = read("EA/includes/Decision/DecisionStore.mqh")
    for field in (
        "setup_id",
        "smc_chain_id",
        "rejection_reason",
        "family",
        "invalidation",
        "raw_confidence",
        "structural_valid",
        "structural_quality",
        "expiry_time",
    ):
        assert field in c


def test_risk_engine_uses_broker_native_profit_and_margin():
    c = read("EA/includes/Trading/RiskEngine.mqh")
    assert "OrderCalcProfit" in c
    assert "OrderCalcMargin" in c


def test_mql5_version_is_216():
    for path in ("EA/MedisTouch_v2.8.mq5", "EA/MedisTouch_Indicator_v2.8.mq5"):
        c = read(path)
        assert '#property version   "2.16"' in c
