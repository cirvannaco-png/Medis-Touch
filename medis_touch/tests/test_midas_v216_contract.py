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


def test_v219_tp1_precision_gate_is_explicit_and_fail_closed():
    cfg = read("EA/includes/Core/Config.mqh")
    main = read("EA/MedisTouch_v2.8.mq5")
    assert "tp1_calibration_sample" in cfg
    assert "tp1_calibration_context_used" in cfg
    assert "InpUseTP1PrecisionGate = true" in main
    assert "InpMinTP1PrecisionProbability = 87.0" in main
    assert "InpMinTP1PrecisionSample = 50" in main
    assert "InpRequireTP1ContextCalibration = true" in main
    assert "minSample" in main
    assert "contextOk" in main
    assert "winProbabilityOk" in main
    assert "tp1ProbabilityOk" in main
    assert "if(!precisionPass)" in main


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
    assert "ValidateSetup(buySetup, InpMinRiskReward, InpMaxSLDistanceATR, currentATR)" in c
    assert "ValidateSetup(sellSetup, InpMinRiskReward, InpMaxSLDistanceATR, currentATR)" in c

def test_v217_telemetry_preserves_64_bit_decision_identity():
    publisher = read("EA/includes/Signals/SignalPublisher.mqh")
    logger = read("EA/includes/Core/SignalLogger.mqh")
    assert '\\"decision_id\\":%I64d' in publisher
    assert "%I64d" in logger

def test_v227_precision_hardening_is_explicit_and_shared_by_ea_and_indicator():
    ea = read("EA/MedisTouch_v2.8.mq5")
    ind = read("EA/MedisTouch_Indicator_v2.8.mq5")
    chain = read("EA/includes/Analysis/SMCChain.mqh")
    validator = read("EA/includes/Analysis/StructuralValidator.mqh")
    zone = read("EA/includes/Trading/TradeZone.mqh")
    targets = read("EA/includes/Trading/Targets.mqh")
    assert "InpMinStructuralQuality = 60.0" in ea
    assert "InpMinChainRejectionRatio = 0.30" in ea
    assert "InpMaxFVGAgeBars = 8" in ea
    assert "InpMinChainDisplacementATR = 1.10" in ea
    assert "InpMinChainStructureStrength = 0.50" in ea
    assert "InpMinDirectionalAdvantage = 5.0" in ea
    assert "InpMinStructuralQuality = 60.0" in ind
    assert "InpMinChainRejectionRatio = 0.30" in ind
    assert "m_minRejectionRatio" in chain
    assert "ratio >= m_minRejectionRatio" in chain
    assert "m_minStructuralQuality" in zone
    assert "sv.structural_quality < m_minStructuralQuality" in zone
    assert "minRejectionRatio" in validator
    assert "tp1MinRR * riskDist" in targets


def test_v217_low_vol_gate_fails_closed_on_undefined_regime():
    c = read("EA/includes/Analysis/Scoring.mqh")
    assert "if(regime == VOL_REGIME_LOW || regime == VOL_REGIME_UNDEFINED)" in c

def test_v217_setup_dedup_commits_after_persistence_boundary():
    c = read("EA/MedisTouch_v2.8.mq5")
    assert "commit setup deduplication only after the decision boundary" in c
    assert "retry next evaluation; do not consume the setup" in c
    assert "g_lastSetupId = chosen.setup_id;" in c
def test_v217_live_tp1_milestone_cannot_depend_on_be_threshold():
    c = read("EA/includes/Execution/PositionManager.mqh")
    assert "state == TS_FILLED && tp1Reached" in c
    assert "ModifySLTP(ticket, entry, dec.setup.final_tp)" in c

def test_v217_simulated_tp1_milestone_cannot_depend_on_be_threshold():
    c = read("EA/includes/Trading/OutcomeTracker.mqh")
    assert "double earlyTP1 = p.setup.tp1;" in c
    assert "earlyTP1Touched" in c

def test_v217_simulated_tp2_collision_uses_fill_policy():
    c = read("EA/includes/Trading/OutcomeTracker.mqh")
    assert "Ambiguous_SLandTP2" in c
    assert "ResolveOrder(isBuy, bar0, adverseLevel, p.setup.tp2, ambiguous)" in c
    assert "if(!favorableFirst)" in c

def test_v217_simulator_does_not_manage_filled_trade_on_same_ohlc_bar():
    c = read("EA/includes/Trading/OutcomeTracker.mqh")
    assert "OHLC cannot tell whether the target/stop was reached before or" in c
    assert "m_pending[i] = p;" in c
    assert "continue;" in c
def test_v217_causal_fvg_must_be_temporally_between_structure_and_displacement():
    c = read("EA/includes/Analysis/SMCChain.mqh")
    assert "if(fvgLatestBar < structureBar || fvgLatestBar > displacementBar)" in c
    assert "the FVG must be formed by the" in c

def test_v217_continuation_invalidation_uses_causal_displacement_not_incidental_sweep():
    c = read("EA/includes/Analysis/SMCChain.mqh")
    assert "bool useSweepInvalidation = (family == SETUP_FAMILY_REVERSAL && haveSweep);" in c
    assert "CandleData thesisCandle = useSweepInvalidation" in c

def test_v217_choch_has_measurable_strength_and_hard_threshold():
    cfg = read("EA/includes/Core/Config.mqh")
    choch = read("EA/includes/Structure/CHOCH.mqh")
    chain = read("EA/includes/Analysis/SMCChain.mqh")
    assert "double            strength;" in cfg
    assert "bull.strength =" in choch
    assert "bear.strength =" in choch
    assert "if(c.structure_strength < m_minStructureStrength)" in chain

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



def test_v219_tp1_calibration_uses_realized_milestones_not_raw_ohlc_touches():
    c = read("EA/includes/Trading/OutcomeTracker.mqh")
    assert "p.tp1Hit = true;" in c
    assert "p.tp2Hit = true;" in c
    assert "Target milestones are set only by ProcessFilledBar()" in c
    assert "m_pending[i].tp1Hit = true;" not in c
    assert "m_pending[i].tp2Hit = true;" not in c


def test_v219_precision_gate_checks_profitable_outcome_and_tp1():
    c = read("EA/MedisTouch_v2.8.mq5")
    assert "winProbabilityOk" in c
    assert "tp1ProbabilityOk" in c
    assert "minSample" in c
    assert "tp1Sample" in c
    assert "chosen.calibration_context_used && chosen.tp1_calibration_context_used" in c
    assert "decision.action = POLICY_SIGNAL_ONLY;" in c


def test_v219_calibration_pools_only_adjacent_buckets_inside_same_context():
    c = read("EA/includes/Trading/CalibrationEngine.mqh")
    assert "pooledW += m_contextWins[r][f][pb];" in c
    assert "pooledHits += m_contextTpHits[t][r][f][pb];" in c
    assert "fromB = MathMax(0, b - 1)" in c
    assert "toB   = MathMin(NUM_BUCKETS - 1, b + 1)" in c


def test_mql5_version_is_219():
    for path in ("EA/MedisTouch_v2.8.mq5", "EA/MedisTouch_Indicator_v2.8.mq5"):
        c = read(path)
        assert '#property version   "2.27"' in c


def test_v220_tradezone_uses_validated_causal_chain_confidence():
    scoring = read("EA/includes/Analysis/Scoring.mqh")
    zone = read("EA/includes/Trading/TradeZone.mqh")
    assert "CalculateValidatedConfidence(bool forBuy, const SMCChain &chain)" in scoring
    assert "if(chain.status != CHAIN_VALID" in scoring
    assert "double score = 70.0 * quality / 100.0;" in scoring
    assert "score += 15.0 * TrendScore(forBuy);" in scoring
    start = scoring.index("double CScoringEngine::CalculateValidatedConfidence")
    end = scoring.index("double CScoringEngine::PipSize()", start)
    validated = scoring[start:end]
    assert "score += 15.0 * FVGScore(forBuy);" not in validated
    assert "m_scoring.CalculateValidatedConfidence(true, sv.chain)" in zone
    assert "m_scoring.CalculateValidatedConfidence(false, sv.chain)" in zone


def test_v220_calibration_population_is_versioned_with_new_confidence_semantics():
    cfg = read("EA/includes/Core/Config.mqh")
    main = read("EA/MedisTouch_v2.8.mq5")
    assert 'MIDAS_ENGINE_VERSION "2.27"' in cfg
    assert 'MIDAS_WEIGHT_SET_VERSION "SMC-CAUSAL-2.27"' in cfg
    assert 'InpWeightSetVersion = "SMC-CAUSAL-2.27"' in main
    assert '#property version   "2.27"' in main


def test_v221_precision_gate_tracks_before_execution_filter():
    c = read("EA/MedisTouch_v2.8.mq5")
    gate = c.index("if(InpUseTP1PrecisionGate &&")
    tracking = c.index("if(InpTrackOutcomes)\n      g_tracker.AddSetup(chosen, decision.decision_id);")
    assert tracking < gate
    assert "v2.21: shadow-track every policy-valid setup BEFORE the execution" in c


def test_v222_fvg_age_is_measured_from_closed_completion_bar():
    fvg = read("EA/includes/SmartMoney/FVG.mqh")
    chain = read("EA/includes/Analysis/SMCChain.mqh")
    assert "zone.bar_index - 2" in fvg
    assert "z.bar_index - 2" in chain


def test_v222_fvg_quality_is_not_double_normalized():
    c = read("EA/includes/Analysis/SMCChain.mqh")
    assert "FVGZone.width is already normalized" in c
    assert "MathMin(c.fvg.width, 1.0)" in c
    assert "c.fvg.width / fvgATR" not in c


def test_mql5_version_is_222():
    for path in ("EA/MedisTouch_v2.8.mq5", "EA/MedisTouch_Indicator_v2.8.mq5"):
        c = read(path)
        assert '#property version   "2.27"' in c


def test_v223_target_fallback_is_non_compounding_and_monotonic():
    t = read("EA/includes/Trading/Targets.mqh")
    assert "fallbackTp1RR = MathMax(tp1MinRR, 1.25)" in t
    assert "entryPrice, tp1MinRR * riskDist" in t
    assert "fallbackTp2RR = MathMax(MathMax(fallbackTp1RR + 0.5, 2.0), minRR + 0.5)" in t
    assert "fallbackTp3RR = MathMax(MathMax(fallbackTp2RR + 0.75, 3.0), minRR + 1.5)" in t
    assert "entryPrice + fallbackTp2Distance" in t
    assert "entryPrice + fallbackTp3Distance" in t
    assert "1.5R / 2.0R /" in t
    assert "3.0R ladder" in t


def test_mql5_version_is_223():
    for path in ("EA/MedisTouch_v2.8.mq5", "EA/MedisTouch_Indicator_v2.8.mq5"):
        c = read(path)
        assert '#property version   "2.27"' in c


def test_v224_single_direction_risk_validation_uses_closed_bar_atr():
    main = read("EA/MedisTouch_v2.8.mq5")
    assert "ValidateSetup(buySetup, InpMinRiskReward, InpMaxSLDistanceATR, analysisAtr)" in main
    assert "ValidateSetup(sellSetup, InpMinRiskReward, InpMaxSLDistanceATR, analysisAtr)" in main
    assert "ValidateSetup(buySetup, InpMinRiskReward, InpMaxSLDistanceATR, currentAtr)" not in main
    assert "ValidateSetup(sellSetup, InpMinRiskReward, InpMaxSLDistanceATR, currentAtr)" not in main


def test_v224_entry_drift_rejects_only_adverse_motion():
    om = read("EA/includes/Execution/OrderManager.mqh")
    assert "double adverseDrift" in om
    assert "Asymmetric bounded drift" in om
    assert "if(maxAdverseEntryDeviation > 0.0 && adverseDrift > maxAdverseEntryDeviation)" in om
    assert "double deviation = MathAbs(marketPrice - entry)" not in om


def test_mql5_version_is_224():
    for path in ("EA/MedisTouch_v2.8.mq5", "EA/MedisTouch_Indicator_v2.8.mq5"):
        c = read(path)
        assert '#property version   "2.27"' in c


def test_v225_entry_drift_is_asymmetric_but_bounded():
    om = read("EA/includes/Execution/OrderManager.mqh")
    main = read("EA/MedisTouch_v2.8.mq5")
    assert "maxAdverseEntryDeviation" in om
    assert "maxFavorableEntryDeviation" in om
    assert "double signedDrift" in om
    assert "double adverseDrift = MathMax(0.0, signedDrift);" in om
    assert "double favorableDrift = MathMax(0.0, -signedDrift);" in om
    assert "favorable drift" in om.lower()
    assert "InpMaxEntryDeviationATR = 0.15" in main
    assert "InpMaxFavorableEntryDeviationATR = 0.25" in main
    assert "maxAdverseDeviation = InpMaxEntryDeviationATR * analysisAtr" in main
    assert "maxFavorableDeviation = InpMaxFavorableEntryDeviationATR * analysisAtr" in main


def test_mql5_version_is_225():
    for path in ("EA/MedisTouch_v2.8.mq5", "EA/MedisTouch_Indicator_v2.8.mq5"):
        c = read(path)
        assert '#property version   "2.27"' in c
