//+------------------------------------------------------------------+
//|                                                MedisTouch_EA.mq5  |
//|                                   Medis Touch — Trading/Signal EA |
//+------------------------------------------------------------------+
// WHY THIS IS A SEPARATE FILE FROM MedisTouch.mq5:
// MQL5 does not allow trading calls (OrderSend, CTrade, etc.) from an
// indicator context (#property indicator_chart_window) — only from an
// Expert Advisor or Script. MedisTouch.mq5 stays exactly as it was: a
// chart indicator for visualization/dashboard use with zero execution
// risk. This file is the actual robot: same analysis engine, attached as
// an EA, running under OnTick() where trading is legal. Run them
// together on the same chart (indicator for the visuals you're used to,
// EA for the parts that touch money) or run this alone headless.
#property copyright "Medis Touch"
#property version   "2.80"
#property strict

#include "includes/Core/Config.mqh"
#include "includes/Core/CandleData.mqh"
#include "includes/Core/SignalLogger.mqh"
#include "includes/Analysis/TFContext.mqh"
#include "includes/Analysis/Scoring.mqh"
#include "includes/Trading/TradeZone.mqh"
#include "includes/Trading/RiskEngine.mqh"
#include "includes/Trading/OutcomeTracker.mqh"
#include "includes/Decision/DecisionEngine.mqh"
#include "includes/Decision/DecisionStore.mqh"
#include "includes/Execution/BrokerAdapter.mqh"
#include "includes/Execution/OrderManager.mqh"
#include "includes/Execution/PositionManager.mqh"
#include "includes/Recovery/RecoveryEngine.mqh"
#include "includes/Portfolio/PortfolioManager.mqh"
#include "includes/Portfolio/RiskGuard.mqh"
#include "includes/Core/NewsFilter.mqh"
#include "includes/Signals/SubscriberPlatform.mqh"
#include "includes/Signals/SignalPublisher.mqh"
#include "includes/Signals/ConfigSync.mqh"
#include "includes/Monitoring/ProductionMonitor.mqh"

// --- Analysis inputs: kept identical to MedisTouch.mq5 so both files
// analyze the same way if you point them at the same values. ---
input group "General"
input int    InpMaxHistoryBars = 500;

input group "Structure"
input int    InpSwingStrength = 3;

input group "Per-Concept Timeframes"
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_D1;
input ENUM_TIMEFRAMES InpBOSTF = PERIOD_H4;
input ENUM_TIMEFRAMES InpLiquidityTF = PERIOD_M15;
input ENUM_TIMEFRAMES InpFVGTF = PERIOD_M15;

input group "Fair Value Gaps"
input double InpFVGMinSizeATR = 0.1;

input group "Liquidity"
input double InpInternalLiqThresholdATR = 0.2;

input group "Risk (setup validation)"
input double InpMinRiskReward = 1.5;
input double InpMaxSLDistanceATR = 1.5;
input double InpSLBufferATR = 0.25;        // invalidation margin beyond FVG far edge, in ATR (audit #23 fix)
input double InpMinStopSpreadMult = 3.0;   // floor: SL distance from entry never below (current spread * this) -- check against real Pepperstone/Exness spread in Tester
input double InpMaxEntryDeviationATR = 0.15; // reject a market order if price drifted this many ATR from decision entry (audit #25 fix)

input group "Inducement Engine"
input int    InpImpulseLookbackBars = 40;
input double InpImpulseATRMult = 1.2;
input double InpImpulseBodyRatio = 0.6;
input double InpEqualTolATR = 0.2;
input int    InpMaxLegExtend = 10;
input bool   InpRequirePremiumDiscount = true;
input bool   InpRequireDistributionPhase = false;
input int    InpPhaseRangeLookback = 20;
input double InpPhaseCompressionATRMult = 2.5;

input group "Volume Engine (v2.6)"
input bool   InpRequireVolumeConfirmation = true; // Gate: reject setups below the RVOL threshold — ON for this compile/integration pass, see Analysis/Scoring.mqh
input double InpRVOLThreshold = 1.5;        // Min relative volume vs. the trailing average to count as "confirmed"
input int    InpRVOLLookback = 20;          // Bars averaged for the RVOL baseline

input group "Fibonacci Engine (v2.6)"
input bool   InpRequireFibonacciZone = true; // Gate: reject setups whose price isn't in the pullback zone — ON for this compile/integration pass
input double InpFibZoneMinPct = 50.0;       // Pullback zone start (% retracement)
input double InpFibZoneMaxPct = 61.8;       // Pullback zone end (% retracement)

input group "Value Area Engine (v2.6)"
input bool   InpRequireValueAreaLocation = false; // Gate: reject setups outside Value Area location rule — OFF, brand new & unbacktested, see Scoring.mqh
input int    InpVALookbackBars = 100;       // Bars used to build the volume profile
input int    InpVANumBins = 24;             // Price bins in the profile
input double InpVAPercent = 70.0;           // Value Area coverage, % of profiled volume (Market Profile convention = 70)

input group "HTF Order Block Engine (v2.8)"
input ENUM_TIMEFRAMES InpHtfObTF = PERIOD_H4;      // Must stay genuinely higher than InpFVGTF/InpBOSTF
input bool   InpRequireHtfOB = false;              // Gate: OFF by default, unbacktested — see Scoring.mqh
input double InpOBDisplacementATRMult = 1.5;       // Min displacement-leg range/ATR to qualify as an OB origin
input double InpOBMinBodyRatio = 0.5;              // Min body/range of the displacement candle
input double InpOBDistATRMax = 2.0;                // Max distance (in HTF ATR) from an OB midpoint that still counts

input group "Volatility Regime (v2.8)"
input bool   InpBlockLowVolRegime = false;         // Gate: OFF by default, unbacktested — see Scoring.mqh/VolatilityRegime.mqh
input int    InpVolRegimeLookback = 100;           // Bars of ATR history the percentile is computed against
input double InpVolRegimeLowPct = 0.25;            // Bottom quartile (default) = LOW regime
input double InpVolRegimeHighPct = 0.75;           // Top quartile (default) = HIGH regime

input group "Session Filter (v2.8)"
input bool   InpUseSessionFilter = true;           // ON by default — replaces "trade every session equally"
input bool   InpAllowTokyoSession = false;         // Tokyo-only hours (thin liquidity) — off by default
input bool   InpAllowLondonSession = true;
input bool   InpAllowNewYorkSession = true;
input bool   InpAllowLondonNYOverlap = true;       // highest-liquidity window; independent of the two flags above

input group "Sweep Quality / Chase Filter / FVG Proximity (v2.9)"
input bool   InpRequireMinSweepGrade = false;      // Gate: OFF by default, unbacktested — reject sweeps graded below InpMinSweepGrade
input int    InpMinSweepGrade = 2;                 // 1=C(any valid sweep), 2=B, 3=A — see ENUM_SWEEP_GRADE
input bool   InpRequireFreshSetup = false;         // Gate: OFF by default — hard-reject once TimeDecay() hits 0 bars-since-BOS
input int    InpMaxBarsSinceBOS = 5;               // Decay-to-zero cutoff (0/90/75/55/0% curve, see Inducement.mqh)
input bool   InpRequireChaseFilter = false;        // Gate: OFF by default — reject setups that ran too far past BOS before entry
input double InpMaxChaseDistATR = 0.75;            // Max (price - BOS close)/ATR in the trade direction before rejecting as "chased"
input double InpFVGMaxDistATR = 1.25;              // FVG proximity cap — tightened default from the old hardcoded 3.0 (see Scoring.mqh)
input double InpMinDirectionalAdvantage = 0.0;     // v2.9: min confidence-point edge BUY must have over SELL (or vice versa) to be selected; 0 = old ">="-only behavior, unvalidated nonzero values need ablation testing (review item "directional competition")

input group "Signal Lifecycle (v2.9)"
input bool   InpPublishLifecycleUpdates = false;   // OFF by default — requires the bridge to be on migration 0004+; a pre-0004 bridge will 404 the PATCH endpoint
input int    InpSignalExpiryBars = 12;             // unfilled for this many bars -> EXPIRED (review: "signal expiry")
input double InpSignalStaleChaseATR = 1.0;         // unfilled AND price has moved this many ATR past entry -> STALE (looser than InpMaxChaseDistATR's pre-entry gate — this is post-publish drift, not pre-entry rejection)
input double InpInvalidateOpposingConfidence = 70.0; // unfilled AND the opposite direction's confidence reaches this -> INVALIDATED

input group "Confidence Diagnostics (v2.10) - measured, NOT acted on"
// Every input in this group affects CSV columns and nothing else. The
// contradiction/environment/execution model and the confidence decay are
// logged beside each signal and its resolved outcome so the multiplicative
// score can be compared against the live additive one on YOUR data. None of
// them can change a confidence value, a filter verdict, a lot size, or an
// order. Promoting the model to live is a deliberate code change, not a
// setting - see the v2.10 block in Analysis/Scoring.mqh.
input double InpDiagContradictionWeight = 0.25;    // penalty per actively-contradicting condition (0 = disable the penalty)
input double InpDiagEnvWeight = 1.0;               // 0..1 blend of the environment component toward neutral (0 = ignore it)
input double InpDiagExecWeight = 1.0;              // 0..1 blend of the execution component toward neutral (0 = ignore it)
input double InpDiagDecayHalfLifeBars = 12.0;      // half-life, in UNFILLED bars, of the logged confidence decay (<=0 = no decay)

input group "Strategy Diagnostics (v2.12) - measured, NOT acted on"
// Same discipline as the v2.10 group above: every input here affects
// CSV columns (Regime, MomentumScore, BreakoutScore, BreakoutClass) and
// nothing else. See Regime/RegimeDetector.mqh and
// Strategies/MomentumBreakout.mqh. Strategy module #1 of the
// multi-strategy architecture — Mean Reversion and the Key-Level Price
// Action engine are not built yet; see docs/CHANGELOG.md v2.12 entry.
input int    InpMomentumBreakoutRecencyBars = 10;  // a BOS older than this many bars no longer counts as a live breakout read
input int    InpBreakoutLiqOverlapBars = 2;        // BOS/liquidity-sweep bar_index gap allowed before calling it a LIQUIDITY breakout
input int    InpBreakoutExtensionLookbackBars = 15; // window checked BEFORE the break bar for pre-existing extension
input double InpBreakoutExhaustionATRMult = 3.0;   // pre-break run, in ATR, above which a break is classified EXHAUSTION not EXPANSION
input int    InpMomentumLookbackBars = 10;         // window for the independent momentum score

input group "Mean Reversion Diagnostics (v2.13) - measured, NOT acted on"
// Same discipline as the v2.12 group above. See Strategies/MeanReversion.mqh.
// Strategy module #2 of the multi-strategy architecture — Key-Level
// Price Action is next, not built yet; see docs/CHANGELOG.md v2.13 entry.
input double InpReversionMinStretchATR = 1.0;      // value-area-edge stretch, in ATR, required for the stronger VALUE_FADE path
input double InpReversionSRZoneATRTolerance = 0.25; // how close price must be to an SR zone edge, in ATR, to count as "at" it
input double InpReversionWickRejectionRatio = 0.55; // wick length / total range required to call a candle a rejection
input int    InpReversionLiqRecencyBars = 10;      // how far back a confirming sweep still counts
input int    InpReversionTrendConflictRecencyBars = 10; // how far back an opposing BOS still counts as live conflict
input double InpReversionTrendConflictMinStrength = 0.5; // BOSEvent.strength threshold to flag TREND_CONFLICT

input group "Key-Level Reaction Diagnostics (v2.14) - measured, NOT acted on"
// Same discipline as the groups above. See Strategies/KeyLevelReaction.mqh.
// Strategy module #3 of the multi-strategy architecture. v2.17 wired in
// the three sources v2.14 left out: previous week high/low, session
// high/low, psychological levels — see docs/CHANGELOG.md v2.17 entry.
input int    InpKeyLevelLookbackBars = 5;          // closed bars examined for the reaction pattern
input double InpKeyLevelSearchATRMax = 3.0;        // max distance, in ATR, for a level to count as "in range"
input double InpKeyLevelTouchToleranceATRMult = 0.15; // how close a candle's range must come to the level, in ATR, to count as a touch
input int    InpKeyLevelAbsorptionMinTouches = 3;  // touches required, with no break/rejection, to call it ABSORPTION
input double InpKeyLevelWickRejectionRatio = 0.55; // wick/range ratio required to call a candle a rejection
input double InpKeyLevelRoundStep = 10.0;          // psychological round-number level spacing, in price units (XAUUSD: 10.0 == whole-$10 levels)

input group "Strategy Selection (v2.15) - measured, NOT acted on"
// FOURTH AND LAST LAYER added in this batch. See
// Strategies/StrategySelector.mqh. Compares the three strategy modules'
// scores above against the live SMC engine's own confidence, per
// regime, and records what WOULD have been selected — never sums
// scores, never touches setup.confidence, never gates a trade. Nothing
// further is added until v2.12-v2.15 have compiled and been
// forward-tested as one unit; see docs/CHANGELOG.md v2.15 entry.
input double InpMinSelectionScore = 60.0;          // a challenger strategy must clear this AND beat SMC confidence to be selected

input group "Logging"
input bool   InpLogSignals = true;
input bool   InpTrackOutcomes = true;
input int    InpMaxTrackingBars = 100;
input int    InpCalibrationMinSample = 30;         // v2.9: bucket sample size before GetCalibratedProbability() is trusted — see CalibrationEngine.mqh
input int    InpSessionGMTOffsetOverride = 999;
input ENUM_FILL_POLICY InpFillPolicy = FILL_CONSERVATIVE;
input ENUM_TIMEFRAMES  InpReplayTF = PERIOD_M1;

// --- Policy Engine inputs: this is what actually turns the robot on ---
input group "Policy — what this account does with a validated setup"
input bool   InpEnableExecution = false;        // master switch: place real orders on THIS account
input bool   InpEnableSignals = false;          // master switch: write to the signal feed for subscribers
input double InpMinConfidenceExecute = 70.0;    // setups below this confidence are never executed
input double InpMinConfidenceSignal = 60.0;     // setups below this confidence are never signaled
input double InpFullRiskConfidence = 85.0;      // below this (but above min-execute), risk is halved
input int    InpMaxSpreadPoints = 0;            // 0 = no spread gate; else reject execution above this spread

input group "Execution"
input bool   InpUseMarketOrders = true;         // true = market fill on signal bar; false = resting limit at the FVG
input double InpRiskPercentPerTrade = 0.5;      // % of account equity risked per trade at full confidence
input int    InpMaxOpenTrades = 3;
input ulong  InpMagicNumber = 987654321;
input bool   InpAllowMinLotOverride = false;    // if riskPercent's true size < broker min lot: false = skip the trade (keeps risk% exact), true = trade at min lot anyway (risks MORE than InpRiskPercentPerTrade — will be logged when it happens)
input double InpMaxDailyLossPercent = 3.0;      // real daily loss cap — no new trades once hit (0 = disabled)
input double InpMaxDrawdownPercent = 10.0;      // hard halt: trading stops entirely below this equity drawdown from peak (0 = disabled)
input double InpDeriskStartPercent = 5.0;       // drawdown %, from peak, where position size starts ramping down
input double InpDeriskFloor = 0.25;             // minimum size multiplier the de-risk ramp can reach (0.25 = never below 25% size)
input bool   InpUseNewsFilter = false;          // off by default — you maintain the CSV yourself, see Core/NewsFilter.mqh
input string InpNewsFilterFile = "MedisTouch_News.csv"; // MQL5/Files/<this>, format: YYYY.MM.DD,HH:MM,HIGH,Label
input int    InpNewsMinutesBefore = 15;
input int    InpNewsMinutesAfter = 5;
input int    InpNewsWarnMinutesBefore = 60;        // v2.9: soft-discount window, wider than the hard block above — see NewsFilter.mqh
input int    InpNewsWarnMinutesAfter = 30;
input double InpNewsWarnMultiplier = 0.85;         // confidence *= this while inside the warning window but outside the block window

input group "Position Management"
input double InpBreakEvenAtR = 1.0;             // move SL to entry once price is this many R in favor
input double InpPartialAtR = 2.0;               // take TP1 partial once price is this many R in favor
input double InpPartialFraction = 0.5;          // fraction of volume closed at TP1
input double InpTrailATRMult = 1.5;             // runner trail distance, as an ATR multiple

input group "Trade Simulator costs (v2.7) — the outcome tracker's backtest economics"
input double InpSimCommissionPerLot = 7.0;      // round-turn $ commission per 1.0 lot
input double InpSimSpreadPoints = 10.0;         // simulated spread, in points
input double InpSimSlippagePoints = 2.0;        // simulated adverse slippage per fill, in points

input group "Portfolio (account-wide, across every symbol this magic number trades)"
input double InpMaxPortfolioRiskPercent = 3.0;  // total open risk across the account, as % of equity
input int    InpMaxPositionsPerSymbol = 2;
input int    InpMaxPositionsPerGroup = 3;       // per correlation bucket — see Portfolio/PortfolioManager.mqh

input group "Signal Transport"
input int    InpWebRequestTimeoutMs = 5000;
input string InpBridgeApiKey = "";              // must match telegram-bridge's SECRET_KEY env var — sent as X-API-Key on every /signal POST. Leave blank and WebRequest is skipped (Publish() still writes the local CSV feed, nothing is transmitted).
// v2.11 — manual weight-set version tag. Bump this string by hand every
// time a scoring-formula change ships (same trigger as CalibrationEngine
// Reset() — see its limitation #4). Nothing enforces this yet; it exists
// so every signal AND its eventual outcome carry a queryable label for
// "which weight set produced this," which is the prerequisite for the
// statistical gating / promotion layer (steps 4-5) ever being able to
// tell one weight set's expectancy apart from another's in signal_outcomes.
input string InpWeightSetVersion = "v2.10-baseline";
// v2.11 — the operator's OWN bridge endpoint, for ConfigSync polling
// only. Deliberately separate from the subscriber-fan-out CSV
// (SubscriberPlatform.mqh) — that list is for broadcasting signals to
// potentially several parties, while config-sync is a private
// operational concern about THIS instance's own weight_version staying
// in sync with what was approved on YOUR bridge. Leave blank to disable
// config sync entirely (the default; opt-in). Same base URL you'd use
// as the /signal endpoint, e.g. "https://your-bridge.onrender.com/signal".
input string InpConfigSyncEndpoint = "";
input int    InpConfigSyncPollMinutes = 15; // how often OnTimer polls GET /config/{symbol}; irrelevant if InpConfigSyncEndpoint is blank

input group "Production Monitoring"
input int    InpHeartbeatIntervalSec = 60;
input double InpMaxDrawdownAlertPercent = 10.0;

// --- Global objects: analysis stack (mirrors MedisTouch.mq5) ---
CTFContextPool     g_pool;
CScoringEngine     g_scoring;
CTradeDecision     g_decision;     // analysis-layer setup generator (Trading/TradeZone.mqh)
CRiskEngine        g_risk;
CSignalLogger      g_logger;
COutcomeTracker    g_tracker;

CTFContext*        g_chartCtx = NULL;
CTFContext*        g_trendCtx = NULL;
CTFContext*        g_bosCtx = NULL;
CTFContext*        g_liqCtx = NULL;
CTFContext*        g_fvgCtx = NULL;
CTFContext*        g_htfObCtx = NULL;   // v2.8 — must stay a genuinely higher TF than g_fvgCtx/g_bosCtx

// --- Global objects: the new layer ---
CDecisionEngine    g_router;
CBrokerAdapter     g_broker;
COrderManager      g_orders;
CPositionManager   g_positions;
CDecisionStore     g_store;
CRecoveryEngine    g_recovery;
CPortfolioManager  g_portfolio;
CRiskGuard         g_riskGuard;
CNewsFilter        g_newsFilter;
CSubscriberPlatform g_subscribers;
CSignalPublisher   g_publisher;
CConfigSync        g_configSync;
CProductionMonitor g_monitor;

datetime           g_lastLoggedTime = 0;
datetime           g_lastBarTime = 0;

// v2.9 — signal lifecycle monitor state. Tracks only the single most
// recently published, still-unfilled decision — matches the existing
// g_lastLoggedTime dedup pattern (one active setup at a time is this
// EA's whole model; see the "already routed this exact setup" check
// above). g_lifecycleDecisionId==0 means "nothing pending to monitor".
long               g_lifecycleDecisionId = 0;
datetime           g_lifecycleCreationTime = 0;
TradeSetup         g_lifecycleSetup;
string             g_lifecycleStatus = "valid"; // last status pushed for this decision — avoids re-POSTing the same transition every tick

//+------------------------------------------------------------------+
int OnInit()
  {
   g_pool.Configure(_Symbol, InpMaxHistoryBars, InpSwingStrength, InpFVGMinSizeATR, InpInternalLiqThresholdATR,
                    InpRVOLLookback, InpVALookbackBars, InpVANumBins, InpVAPercent / 100.0,
                    InpOBDisplacementATRMult, InpOBMinBodyRatio);

   g_chartCtx = g_pool.Get(_Period);
   g_trendCtx = g_pool.Get(InpTrendTF);
   g_bosCtx   = g_pool.Get(InpBOSTF);
   g_liqCtx   = g_pool.Get(InpLiquidityTF);
   g_fvgCtx   = g_pool.Get(InpFVGTF);
   g_htfObCtx = g_pool.Get(InpHtfObTF);   // pool dedupes by TF, so if InpHtfObTF matches InpTrendTF this reuses that context

   if(g_chartCtx == NULL || g_trendCtx == NULL || g_bosCtx == NULL || g_liqCtx == NULL || g_fvgCtx == NULL || g_htfObCtx == NULL)
     {
      Print("MedisTouch EA: failed to initialize one or more timeframe contexts.");
      return INIT_FAILED;
     }
   if(InpHtfObTF <= InpFVGTF || InpHtfObTF <= InpBOSTF)
      Print("MedisTouch EA: WARNING — InpHtfObTF (", EnumToString(InpHtfObTF),
            ") is not strictly higher than InpFVGTF/InpBOSTF. HTF Order Block confluence ",
            "will be comparing zones on the same or a lower resolution than the entry timeframe, ",
            "which defeats the point of the filter even if InpRequireHtfOB is left OFF for diagnostics only.");

   g_scoring.Init(g_trendCtx, g_bosCtx, g_liqCtx, g_fvgCtx, g_chartCtx, &g_chartCtx.candles);
   g_scoring.ConfigureInducement(InpImpulseLookbackBars, InpImpulseATRMult, InpImpulseBodyRatio,
                                 InpEqualTolATR, InpMaxLegExtend,
                                 InpRequirePremiumDiscount, InpRequireDistributionPhase,
                                 InpPhaseRangeLookback, InpPhaseCompressionATRMult);
   g_scoring.ConfigureVolumeFibonacci(InpRequireVolumeConfirmation, InpRVOLThreshold,
                                      InpRequireFibonacciZone, InpFibZoneMinPct, InpFibZoneMaxPct);
   g_scoring.ConfigureValueArea(InpRequireValueAreaLocation);
   g_scoring.ConfigureHtfOrderBlock(g_htfObCtx, InpRequireHtfOB, InpOBDistATRMax);
   g_scoring.ConfigureVolatilityRegime(InpBlockLowVolRegime, InpVolRegimeLookback, InpVolRegimeLowPct, InpVolRegimeHighPct);
   g_scoring.ConfigureSessionFilter(InpUseSessionFilter, InpAllowTokyoSession, InpAllowLondonSession,
                                    InpAllowNewYorkSession, InpAllowLondonNYOverlap);
   g_scoring.ConfigureSweepQuality(InpRequireMinSweepGrade, (ENUM_SWEEP_GRADE)InpMinSweepGrade,
                                   InpRequireFreshSetup, InpMaxBarsSinceBOS);
   g_scoring.ConfigureChaseFilter(InpRequireChaseFilter, InpMaxChaseDistATR);
   g_scoring.ConfigureFVGProximity(InpFVGMaxDistATR);
   g_scoring.ConfigureLearnedDiagnostics(InpDiagContradictionWeight, InpDiagEnvWeight, InpDiagExecWeight);
   g_scoring.ConfigureStrategyDiagnostics(InpMomentumBreakoutRecencyBars, InpBreakoutLiqOverlapBars,
                                          InpBreakoutExtensionLookbackBars, InpBreakoutExhaustionATRMult,
                                          InpMomentumLookbackBars);
   g_scoring.ConfigureMeanReversionDiagnostics(InpReversionMinStretchATR, InpReversionSRZoneATRTolerance,
                                               InpReversionWickRejectionRatio, InpReversionLiqRecencyBars,
                                               InpReversionTrendConflictRecencyBars, InpReversionTrendConflictMinStrength);
   g_scoring.ConfigureKeyLevelDiagnostics(InpKeyLevelLookbackBars, InpKeyLevelSearchATRMax,
                                          InpKeyLevelTouchToleranceATRMult, InpKeyLevelAbsorptionMinTouches,
                                          InpKeyLevelWickRejectionRatio, InpKeyLevelRoundStep);
   g_scoring.ConfigureStrategySelection(InpMinSelectionScore);
   g_decision.Init(&g_chartCtx.candles, g_fvgCtx, g_liqCtx, &g_scoring, InpSLBufferATR, InpMinStopSpreadMult);
   g_logger.Init(_Symbol, InpSessionGMTOffsetOverride);
   g_tracker.Init(&g_logger, _Symbol, InpFVGTF, InpMaxTrackingBars, InpFillPolicy, InpReplayTF);
   // Deliberately the SAME values driving g_positions/g_risk below — so the
   // simulator's numbers actually predict what this EA, configured exactly
   // like this, would do.
   g_tracker.ConfigureSimulation(InpRiskPercentPerTrade, InpAllowMinLotOverride,
                                 InpBreakEvenAtR, InpPartialAtR, InpPartialFraction, InpTrailATRMult,
                                 InpSimCommissionPerLot, InpSimSpreadPoints, InpSimSlippagePoints);
   g_tracker.ConfigureCalibration(InpTrackOutcomes, InpCalibrationMinSample);
   // v2.10 diagnostics - see the "Confidence Diagnostics" input group.
   g_tracker.ConfigureConfidenceDecay(InpDiagDecayHalfLifeBars);

   g_router.Init(_Symbol, InpEnableExecution, InpEnableSignals,
                InpMinConfidenceExecute, InpMinConfidenceSignal, InpFullRiskConfidence, InpMaxSpreadPoints);
   g_broker.Init(InpMagicNumber);
   g_monitor.Init(_Symbol, InpHeartbeatIntervalSec, InpMaxDrawdownAlertPercent);
   g_orders.Init(&g_broker, InpMaxOpenTrades, &g_monitor);
   g_positions.Init(&g_orders, &g_broker, InpBreakEvenAtR, InpPartialAtR, InpPartialFraction, InpTrailATRMult);

   g_store.Init(_Symbol);
   g_subscribers.Init();
   g_publisher.Init(_Symbol, &g_subscribers, InpWebRequestTimeoutMs, InpBridgeApiKey);
   g_publisher.SetWeightVersion(InpWeightSetVersion);
   // v2.11 — dormant until InpConfigSyncEndpoint is set AND a real
   // promotion has happened on the bridge; see ConfigSync.mqh header.
   // EventSetTimer's argument is seconds, hence the *60.
   if(StringLen(InpConfigSyncEndpoint) > 0)
     {
      g_configSync.Init(_Symbol, InpConfigSyncEndpoint, InpBridgeApiKey, InpWeightSetVersion, InpWebRequestTimeoutMs);
      EventSetTimer(MathMax(60, InpConfigSyncPollMinutes * 60));
     }
   // v2.11 — lets the tracker push resolved outcomes to the bridge
   // (POST /outcome) the moment it resolves them, right alongside the
   // existing local-CSV LogOutcome() call. See OutcomeTracker.mqh
   // FinalizeExit()/Resolve() for the call sites.
   g_tracker.ConfigurePublishing(&g_publisher, InpWeightSetVersion);
   g_portfolio.Init(InpMaxPortfolioRiskPercent, InpMaxPositionsPerSymbol, InpMaxPositionsPerGroup, InpMagicNumber, &g_risk);
   g_riskGuard.Init(_Symbol, InpMaxDailyLossPercent, InpMaxDrawdownPercent, InpDeriskStartPercent, InpDeriskFloor);
   if(InpUseNewsFilter)
      g_newsFilter.Load(InpNewsFilterFile, InpNewsMinutesBefore, InpNewsMinutesAfter);
   // v2.9: wire the same CNewsFilter instance into scoring for the
   // soft-discount tier. If InpUseNewsFilter is false, the filter was
   // never Load()-ed (m_enabled stays false internally), so
   // GetRiskTier() always returns NEWS_NONE and this is a no-op —
   // consistent with every other OFF-by-default v2.9 gate.
   g_scoring.ConfigureNewsAwareness(GetPointer(g_newsFilter), InpNewsWarnMinutesBefore,
                                    InpNewsWarnMinutesAfter, InpNewsWarnMultiplier);

   // Recovery must run AFTER OrderManager/BrokerAdapter exist (it writes
   // into g_orders) and AFTER g_store is initialized (it reads decision
   // history from it), but BEFORE the first OnTick — a restarted EA
   // should never take a fresh tick believing it has zero open trades
   // when the broker actually shows some under our magic number.
   g_recovery.Init(&g_store, &g_orders, InpMagicNumber, _Symbol);
   int restoredCount = g_recovery.Recover();
   if(restoredCount > 0)
      PrintFormat("MedisTouch EA: recovery restored %d live trade(s) from a prior session.", restoredCount);

   // Decision IDs are the matching key Recovery relies on (order comment
   // "MT#<id>") — a fresh EA instance must never reissue an ID already
   // live on a broker-side ticket or already sitting in the decision
   // store. Seed the counter past the highest ID this session has ever
   // seen, every time, not just after a restart with open trades.
   TradeDecisionRecord priorDecisions[];
   int priorCount = g_store.LoadAll(priorDecisions);
   long maxId = 0;
   for(int i = 0; i < priorCount; i++)
      if(priorDecisions[i].decision_id > maxId) maxId = priorDecisions[i].decision_id;
   if(maxId > 0) g_router.SeedNextId(maxId + 1);

   if(!InpEnableExecution && !InpEnableSignals)
      Print("MedisTouch EA: both InpEnableExecution and InpEnableSignals are OFF. ",
            "Analysis and logging still run, but nothing will be executed or published.");

   return INIT_SUCCEEDED;
  }
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(StringLen(InpConfigSyncEndpoint) > 0)
      EventKillTimer();
   g_publisher.Deinit();
   g_subscribers.Deinit();
   g_store.Deinit();
  }
//+------------------------------------------------------------------+
// v2.11 — fires every InpConfigSyncPollMinutes when config sync is
// enabled (see OnInit's EventSetTimer call); does nothing otherwise,
// since EventSetTimer() is never called when InpConfigSyncEndpoint is
// blank, so OnTimer() simply never fires in that case.
void OnTimer()
  {
   g_configSync.Poll();
  }
//+------------------------------------------------------------------+
// v2.9 — signal lifecycle monitor (review: "SCANNING -> QUALIFIED ->
// POSTED -> ACTIVE -> TP/SL/EXPIRED/INVALIDATED"). Called every tick
// when InpPublishLifecycleUpdates is on; each check is cheap (a handful
// of comparisons + at most one CalculateConfidence() call), and the
// function returns immediately if nothing is being tracked.
//
// Deliberately does NOT handle TP/SL resolution — that's already
// covered by the existing PositionManager -> OutcomeTracker -> POST
// /trade closed_tp1/closed_tp2/closed_sl path. This only handles "this
// setup stopped being a valid reason to enter", which is a distinct
// question from "did a filled position hit its target".
void CheckSignalLifecycle(double currentAtr)
  {
   if(g_lifecycleDecisionId == 0) return;

   bool filled; double fillPrice; datetime fillTime; int barsToFill;
   bool haveState = g_tracker.GetFillState(g_lifecycleCreationTime, filled, fillPrice, fillTime, barsToFill);
   if(!haveState) { g_lifecycleDecisionId = 0; return; } // tracker no longer has this setup (fell off m_maxBars window) — nothing more to say

   if(filled)
     {
      // Filled — no longer a "will this get entered" question. Clear
      // tracking; TP/SL/close events take over from here via /trade.
      g_lifecycleDecisionId = 0;
      return;
     }

   bool isBuy = (g_lifecycleSetup.type == ORDER_TYPE_BUY);
   int barsSinceCreation = iBarShift(_Symbol, InpFVGTF, g_lifecycleCreationTime, false);

   // EXPIRED takes priority over STALE — an old-and-drifted setup should
   // report as expired, not stale, since expiry is the terminal state.
   if(barsSinceCreation >= InpSignalExpiryBars)
     {
      if(g_lifecycleStatus != "expired")
        {
         g_publisher.PublishStatusUpdate(g_lifecycleDecisionId, "expired",
                                         StringFormat("Unfilled for %d bars (max %d) — setup abandoned", barsSinceCreation, InpSignalExpiryBars));
         g_lifecycleStatus = "expired";
        }
      g_lifecycleDecisionId = 0; // terminal — stop tracking
      return;
     }

   // INVALIDATED: the opposite direction has since become a strong
   // setup in its own right — a real structural contradiction of the
   // original read, not just drift. Checked before STALE for the same
   // "worse state wins" reasoning as EXPIRED above.
   double oppositeConfidence = g_scoring.CalculateConfidence(!isBuy);
   if(oppositeConfidence >= InpInvalidateOpposingConfidence)
     {
      if(g_lifecycleStatus != "invalidated")
        {
         g_publisher.PublishStatusUpdate(g_lifecycleDecisionId, "invalidated",
                                         StringFormat("Opposing setup confidence reached %.0f — original read contradicted", oppositeConfidence));
         g_lifecycleStatus = "invalidated";
        }
      g_lifecycleDecisionId = 0; // terminal — stop tracking
      return;
     }

   // STALE: unfilled and price has drifted meaningfully past the
   // intended entry zone. Non-terminal — price can pull back into the
   // zone, so keep monitoring (but only publish the transition once).
   if(currentAtr > 0)
     {
      double entry = ResolveExecutionEntry(g_lifecycleSetup);
      double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double driftATR = MathAbs(price - entry) / currentAtr;
      bool wentWrongWay = isBuy ? (price > entry) : (price < entry); // "chased" means price ran further into the trade direction, unfilled
      if(wentWrongWay && driftATR >= InpSignalStaleChaseATR)
        {
         if(g_lifecycleStatus != "stale")
           {
            g_publisher.PublishStatusUpdate(g_lifecycleDecisionId, "stale",
                                            StringFormat("Price drifted %.2f ATR past the entry zone, unfilled", driftATR));
            g_lifecycleStatus = "stale";
           }
        }
      else if(g_lifecycleStatus == "stale" && driftATR < InpSignalStaleChaseATR * 0.5)
        {
         // Price came back — revert to VALID. Half the trigger distance
         // as a hysteresis band so this doesn't flip-flop every tick
         // right at the threshold.
         g_publisher.PublishStatusUpdate(g_lifecycleDecisionId, "valid", "Price returned toward the entry zone");
         g_lifecycleStatus = "valid";
        }
     }
  }
//+------------------------------------------------------------------+
void OnTick()
  {
   g_monitor.OnTickCheck(); // cheap, cadence-gated internally — safe to call every tick

   g_pool.DetectAll();
   if(g_chartCtx == NULL || !g_chartCtx.candles.IsReady()) return;

   double currentAtr = g_fvgCtx.candles.GetATR(0);

   // Manage everything already open before looking for anything new —
   // a break-even/trailing update should never wait behind new-setup work.
   g_positions.OnTick(currentAtr);
   g_orders.Prune();
   g_riskGuard.OnTick(); // cheap — daily rollover check + peak-equity/drawdown tracking

   if(InpPublishLifecycleUpdates)
      CheckSignalLifecycle(currentAtr);

   string haltReason;
   if(g_riskGuard.IsHardHalted(haltReason))
     {
      static datetime lastHaltLog = 0;
      if(TimeCurrent() - lastHaltLog > 3600) { PrintFormat("MedisTouch EA: no new trades — %s", haltReason); lastHaltLog = TimeCurrent(); }
      return;
     }
   if(g_riskGuard.IsDailyLossLimitHit(haltReason))
     {
      static datetime lastDailyLog = 0;
      if(TimeCurrent() - lastDailyLog > 3600) { PrintFormat("MedisTouch EA: no new trades — %s", haltReason); lastDailyLog = TimeCurrent(); }
      return;
     }
   string newsReason;
   if(InpUseNewsFilter && g_newsFilter.IsLocked(newsReason))
     {
      static datetime lastNewsLog = 0;
      if(TimeCurrent() - lastNewsLog > 300) { PrintFormat("MedisTouch EA: no new trades — %s", newsReason); lastNewsLog = TimeCurrent(); }
      return;
     }

   // Only evaluate for a NEW decision once per closed bar, same as the
   // indicator's OnCalculate cadence — a decision per bar, not per tick.
   datetime barTime = iTime(_Symbol, _Period, 0);
   bool isNewBar = (barTime != g_lastBarTime);
   g_lastBarTime = barTime;
   if(!isNewBar) return;

   TradeSetup buySetup = g_decision.GenerateBuySetup();
   TradeSetup sellSetup = g_decision.GenerateSellSetup();

   // v2.9 — directional competition (review: "don't force equal BUY/SELL
   // frequency; require a minimum probability/confidence advantage").
   // Previously this was a bare ">=", i.e. a 0.01-point edge could flip
   // direction — no different from a coin flip when both setups are
   // roughly equally valid. InpMinDirectionalAdvantage=0 preserves that
   // exact old behavior (default); a nonzero value requires the winning
   // side to actually be ahead by that many confidence points, and drops
   // the bar entirely (no trade either direction) when neither side
   // clears it — an ambiguous market gets skipped instead of arbitrarily
   // resolved. Needs the same ablation-test treatment as everything else
   // to find a real threshold; 0 ships as the safe default.
   TradeSetup chosen;
   ZeroMemory(chosen);
   double confDelta = buySetup.confidence - sellSetup.confidence;
   if(buySetup.active && sellSetup.active)
     {
      if(confDelta >= InpMinDirectionalAdvantage)
        {
         if(g_risk.ValidateSetup(buySetup, InpMinRiskReward, InpMaxSLDistanceATR, currentAtr))
            chosen = buySetup;
        }
      else if(-confDelta >= InpMinDirectionalAdvantage)
        {
         if(g_risk.ValidateSetup(sellSetup, InpMinRiskReward, InpMaxSLDistanceATR, currentAtr))
            chosen = sellSetup;
        }
      // else: neither side clears the advantage threshold — no trade,
      // market read as ambiguous rather than arbitrarily picking one.
     }
   else if(buySetup.active)
     {
      if(g_risk.ValidateSetup(buySetup, InpMinRiskReward, InpMaxSLDistanceATR, currentAtr))
         chosen = buySetup;
     }
   else if(sellSetup.active)
     {
      if(g_risk.ValidateSetup(sellSetup, InpMinRiskReward, InpMaxSLDistanceATR, currentAtr))
         chosen = sellSetup;
     }

   if(!chosen.active) return;
   if(chosen.creation_time == g_lastLoggedTime) return; // already routed this exact setup
   g_lastLoggedTime = chosen.creation_time;

   // v2.9: attach the empirical calibration read for this confidence
   // bucket to the chosen setup before it's logged/published — this is
   // what turns "confidence 78" into "confidence 78, historically wins
   // 63% of the time (114 comparable setups)" on the Telegram card.
   chosen.calibrated_probability = g_tracker.GetCalibratedProbability(chosen.confidence,
                                                                       chosen.calibration_sample,
                                                                       chosen.calibration_has_enough_data);

   if(InpLogSignals)
     {
      ENUM_TREND_STATE t = g_trendCtx.trend.GetCurrentTrend();
      g_logger.LogSetup(chosen, _Symbol, InpFVGTF, EnumToString(t));
     }

   // --- This is the seam the audit found missing: analysis -> decision -> action ---
   // v2.11: moved ABOVE AddSetup()/Update() (was below) so a decision_id
   // exists BEFORE the setup enters the tracker — without it, PendingSetup
   // has no valid signal_id to publish resolved outcomes under (see
   // Config.mqh PendingSetup.decisionId). Behavior is otherwise identical:
   // Decide() always ran unconditionally on `chosen` right after this
   // point before, so nothing about ITS timing or inputs has changed —
   // only AddSetup()/Update() now run a few lines later, still within the
   // same tick, still processing the same pending array.
   TradeDecisionRecord decision = g_router.Decide(chosen);

   if(InpTrackOutcomes)
      g_tracker.AddSetup(chosen, decision.decision_id);
   g_tracker.Update(g_fvgCtx);

   if(!decision.valid || decision.action == POLICY_IGNORE) return;

   // Persist BEFORE acting — Recovery must be able to find this decision
   // even if the terminal dies immediately after an order fills.
   g_store.Save(decision);

   if(decision.action == POLICY_EXECUTE_ONLY || decision.action == POLICY_EXECUTE_AND_SIGNAL)
     {
      double entry = ResolveExecutionEntry(chosen); // same price ValidateSetup() gated against — see Core/Config.mqh
      bool exceededRiskBudget = false;
      double lots = g_risk.CalculateLotSize(_Symbol, InpRiskPercentPerTrade, entry, chosen.stop_loss,
                                            decision.reduce_risk, InpAllowMinLotOverride, exceededRiskBudget,
                                            g_riskGuard.SizeMultiplier());
      if(lots <= 0)
         PrintFormat("MedisTouch EA: decision #%d skipped — %.2f%% risk at this stop distance is below the broker's minimum lot for %s.",
                     decision.decision_id, InpRiskPercentPerTrade, _Symbol);
      else
        {
         if(exceededRiskBudget)
            PrintFormat("MedisTouch EA: decision #%d executing at broker-minimum lot (%.2f) — actual risk exceeds InpRiskPercentPerTrade (%.2f%%).",
                        decision.decision_id, lots, InpRiskPercentPerTrade);

         double proposedRisk = g_risk.RiskAmountForLots(_Symbol, lots, entry, chosen.stop_loss);
         string blockReason;
         if(!g_portfolio.AllowNewTrade(_Symbol, proposedRisk, blockReason))
            PrintFormat("MedisTouch EA: decision #%d blocked by Portfolio Manager — %s", decision.decision_id, blockReason);
         else
           {
            ulong ticketOut = 0;
            double maxDeviation = InpMaxEntryDeviationATR * currentAtr;
            if(g_orders.Submit(decision, lots, InpUseMarketOrders, maxDeviation, ticketOut))
               g_store.SaveExecution(decision.decision_id, lots, ticketOut);
            else
               g_monitor.NotifyBrokerReject();
           }
        }
     }
   if(decision.action == POLICY_SIGNAL_ONLY || decision.action == POLICY_EXECUTE_AND_SIGNAL)
     {
      g_publisher.Publish(decision);
      // v2.9: start lifecycle-monitoring this decision. Overwrites
      // whatever was being tracked before — matches the
      // one-active-setup-at-a-time model g_lastLoggedTime already
      // assumes elsewhere in this function.
      g_lifecycleDecisionId = decision.decision_id;
      g_lifecycleCreationTime = chosen.creation_time;
      g_lifecycleSetup = chosen;
      g_lifecycleStatus = "valid";
     }
  }
//+------------------------------------------------------------------+
// C003 FIX: a resting limit order (InpUseMarketOrders = false) sits in
// TS_PENDING with the ORDER ticket recorded. Before this handler existed,
// nothing ever noticed that order fill — PositionManager only manages
// trades already at TS_FILLED or later, and OnTick() never polls pending
// orders for a fill. The trade sat invisible to break-even/partial/trail
// logic until the terminal restarted and Recovery() reconstructed state
// from broker-side truth. OnTradeTransaction fires synchronously the
// moment MT5 books the fill, so this closes the gap live instead of
// waiting for a restart. Market-order fills are untouched by this — those
// already transition to TS_FILLED inside COrderManager::Submit() in the
// same call that sends the order.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;

   // Only the deal that OPENS a position can be a pending order's first
   // fill — a closing or partial-closing deal also raises DEAL_ADD and
   // must not be mistaken for one.
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_IN) return;
   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;

   ulong orderTicket    = (ulong)HistoryDealGetInteger(trans.deal, DEAL_ORDER);
   ulong positionTicket = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   if(orderTicket == 0 || positionTicket == 0) return;

   double fillPrice = HistoryDealGetDouble(trans.deal, DEAL_PRICE); // FIX (#25): real fill price, straight off the deal record
   if(g_orders.MarkFilledFromPending(orderTicket, positionTicket, fillPrice))
      PrintFormat("MedisTouch EA: pending order #%d filled as position #%d at %.5f — caught live via OnTradeTransaction.",
                  orderTicket, positionTicket, fillPrice);
  }
//+------------------------------------------------------------------+
