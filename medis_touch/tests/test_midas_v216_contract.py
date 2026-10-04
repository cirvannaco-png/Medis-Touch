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


def test_v217_regime_gate_is_explicit_and_closed_bar_based():
    c = read("EA/includes/Regime/RegimeDetector.mqh")
    assert "bool                 AllowsSetup" in c
    assert "return REGIME_UNDEFINED;" in c
    assert "market transition: wait for regime resolution" in c
    assert "RecentBOSAgeBars" in c
    assert "phase != PHASE_UNDEFINED" in c


def test_v217_target_engine_uses_executable_entry_and_directional_liquidity():
    c = read("EA/includes/Trading/TradeZone.mqh")
    assert "ResolveExecutionEntry(setup)" in c
    t = read("EA/includes/Trading/Targets.mqh")
    assert "ENUM_LIQ_TYPE wantedType" in t
    assert "setup.target_plan_valid" in t
    assert "setup.tp1_quality" in t


def test_v217_target_calibration_tracks_context_and_tp_hit_probability():
    c = read("EA/includes/Trading/CalibrationEngine.mqh")
    assert c.count("double GetTargetCalibratedProbability(") == 1
    assert "targetIndex < 1 || targetIndex > 3" in c
    assert "m_contextTpHits" in c
    assert "m_contextTpMisses" in c
    assert "m_tpHits" in c
    assert "m_tpMisses" in c
    assert "if(tp1Hit) m_tpHits[0][b]++; else m_tpMisses[0][b]++;" in c
    assert "int contextN = ch + cm;" in c

def test_v217_calibration_record_scope_is_compile_safe():
    c = read("EA/includes/Trading/OutcomeTracker.mqh")
    assert "if(m_calibrationEnabled)" in c
    assert "bool tp3Reached = (outcome == \"FinalTP_Hit\");" in c
    assert "if(m_calibrationEnabled)\n           {\n            bool tp3Reached" in c


def test_v217_calibration_gate_remains_opt_in():
    c = read("EA/MedisTouch_v2.8.mq5")
    assert "InpUseCalibratedGate = false" in c
    assert "GetContextCalibratedProbability" in c


def test_v217_position_management_matches_target_plan():
    c = read("EA/includes/Execution/PositionManager.mqh")
    assert "dec.setup.tp1" in c
    assert "dec.setup.tp2" in c
    assert "lockSL = tp1" in c


def test_v217_risk_requires_validated_target_plan():
    c = read("EA/includes/Trading/RiskEngine.mqh")
    assert "if(!setup.target_plan_valid) return false;" in c

def test_v217_tradezone_rejects_invalid_target_plan_before_persistence():
    c = read("EA/includes/Trading/TradeZone.mqh")
    assert c.count("if(!setup.target_plan_valid)") == 2
    assert c.count("setup.status = SETUP_INVALIDATED;") >= 2
    assert c.count("setup.rejection_reason = SETUP_REJECT_REWARD;") >= 2

def test_v217_indicator_uses_same_min_rr_as_live_trade_decision():
    c = read("EA/MedisTouch_Indicator_v2.8.mq5")
    assert "InpMinRiskReward);" in c

def test_v217_live_tp1_milestone_cannot_depend_on_be_threshold():
    c = read("EA/includes/Execution/PositionManager.mqh")
    assert "state == TS_FILLED && tp1Reached" in c
    assert "ModifySLTP(ticket, entry, dec.setup.final_tp)" in c

def test_v217_simulated_tp1_milestone_cannot_depend_on_be_threshold():
    c = read("EA/includes/Trading/OutcomeTracker.mqh")
    assert "double earlyTP1 = p.setup.tp1;" in c
    assert "earlyTP1Touched" in c

def test_v217_decision_store_persists_target_plan_validity_for_restart():
    c = read("EA/includes/Decision/DecisionStore.mqh")
    assert "string parts[25]" in c
    assert "parts[24] = rec.setup.target_plan_valid ? \"1\" : \"0\";" in c
    assert "for(int i = 1; i < 25; i++)" in c
    assert "if(n > 24) rec.setup.target_plan_valid = (f[24] == \"1\");" in c

def test_v217_outcome_mfe_mae_uses_management_risk_basis():
    c = read("EA/includes/Core/SignalLogger.mqh")
    assert "p.mgmtRiskDist > 0" in c
    assert "p.mfePrice - p.sizingEntryPrice" in c
    assert "p.sizingEntryPrice - p.maePrice" in c


def test_risk_engine_uses_broker_native_profit_and_margin():
    c = read("EA/includes/Trading/RiskEngine.mqh")
    assert "OrderCalcProfit" in c
    assert "OrderCalcMargin" in c


def test_mql5_version_is_217():
    for path in ("EA/MedisTouch_v2.8.mq5", "EA/MedisTouch_Indicator_v2.8.mq5"):
        c = read(path)
        assert '#property version   "2.17"' in c
