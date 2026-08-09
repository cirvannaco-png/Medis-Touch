//+------------------------------------------------------------------+
//|                                                   MedisTouch.mq5  |
//|                                            Medis Touch Indicator  |
//+------------------------------------------------------------------+
#property copyright "Medis Touch"
#property version   "2.80"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

#include "includes/Core/Config.mqh"
#include "includes/Core/CandleData.mqh"
#include "includes/Core/ObjectManager.mqh"
#include "includes/Core/SignalLogger.mqh"
#include "includes/Analysis/TFContext.mqh"
#include "includes/Analysis/Scoring.mqh"
#include "includes/Trading/TradeZone.mqh"
#include "includes/Trading/RiskEngine.mqh"
#include "includes/Trading/OutcomeTracker.mqh"
#include "includes/UI/Dashboard.mqh"
#include "includes/UI/Visuals.mqh"

// --- Input Parameters ---
input group "General"
input int InpMaxHistoryBars = 500;          // Max history bars per timeframe context

input group "Structure"
input int InpSwingStrength = 3;             // Swing fractal bars left/right

input group "Per-Concept Timeframes"
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_D1;   // Trend bias timeframe
input ENUM_TIMEFRAMES InpBOSTF = PERIOD_H4;     // BOS / CHoCH timeframe
input ENUM_TIMEFRAMES InpLiquidityTF = PERIOD_M15; // Liquidity sweep timeframe
input ENUM_TIMEFRAMES InpFVGTF = PERIOD_M15;    // FVG / entry-zone timeframe
// S/R zones and the live price reference always use the chart's own timeframe.

input group "Fair Value Gaps"
input double InpFVGMinSizeATR = 0.1;        // Minimum FVG size as ATR fraction

input group "Liquidity"
input double InpInternalLiqThresholdATR = 0.2; // Internal liquidity threshold ATR

input group "Risk"
input double InpMinRiskReward = 1.5;
input double InpMaxSLDistanceATR = 1.5;

input group "Inducement Engine (v2.1)"
input int    InpImpulseLookbackBars = 40;   // How far back to search for a qualifying impulse
input double InpImpulseATRMult = 1.2;       // Min bar-range/ATR to count as a displacement bar
input double InpImpulseBodyRatio = 0.6;     // Min body/range ratio for a displacement bar
input double InpEqualTolATR = 0.2;          // Tolerance band for "equal" highs/lows (as ATR fraction)
input int    InpMaxLegExtend = 10;          // Max bars to extend an impulse leg outward
input bool   InpRequirePremiumDiscount = true;  // Buys must be in discount / sells in premium of the impulse range
input bool   InpRequireDistributionPhase = false; // Only allow entries in the Distribution phase (heuristic — see MarketPhase.mqh)
input int    InpPhaseRangeLookback = 20;    // Bars used to judge range compression for Accumulation
input double InpPhaseCompressionATRMult = 2.5; // Range/ATR ceiling still considered "compressed"

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

input group "Declutter / Visuals"
input bool InpShowFVGs = true;
input bool InpShowLiquidity = true;
input bool InpShowDashboard = true;
input int InpMaxBOSDraw = 5;                // Most-recent BOS lines kept on chart
input int InpMaxFVGDraw = 4;                // Fresh/tested FVG zones kept on chart
input int InpMaxLiquidityDraw = 4;          // Liquidity pool lines kept on chart
input int InpMaxSRDraw = 4;                 // Strongest S/R zones kept on chart

input group "Alerts & Logging"
input bool InpAlertOnSetup = false;
input bool InpLogSignals = true;            // Write each new setup to a CSV in MQL5/Files
input bool InpTrackOutcomes = true;         // Track each setup to SL/TP/timeout and log the result
input int InpMaxTrackingBars = 100;         // Timeout after this many entry-TF bars unresolved
input int InpSessionGMTOffsetOverride = 999; // 999 = auto-detect broker's GMT offset; else force hours (e.g. 3 for GMT+3)

input group "Outcome Fill Policy (same-bar SL/TP resolution)"
input ENUM_FILL_POLICY InpFillPolicy = FILL_CONSERVATIVE; // How to resolve a bar that touches both SL and TP
input ENUM_TIMEFRAMES  InpReplayTF = PERIOD_M1;            // Lower TF used by FILL_INTRABAR_REPLAY

input group "Trade Simulator (v2.7)"
// The indicator doesn't manage live positions, so — unlike the EA — it
// has no existing risk%/breakeven/partial/trail inputs to reuse. These
// exist purely to drive COutcomeTracker's simulation and should be kept
// identical to whatever the EA is actually configured with, or the
// simulated stats here won't predict what the EA would really do.
input double InpSimRiskPercentPerTrade = 0.5;   // % of account equity risked per trade — match the EA's InpRiskPercentPerTrade
input bool   InpSimAllowMinLotOverride = true;  // true = every filled setup gets sized (min-lot floor); false = mirror the EA's exact reject-below-minimum behavior
input double InpSimBreakEvenAtR = 1.0;          // move SL to entry once price is this many R in favor — match the EA's InpBreakEvenAtR
input double InpSimPartialAtR = 2.0;            // take the partial once price is this many R in favor — match the EA's InpPartialAtR
input double InpSimPartialFraction = 0.5;       // fraction of volume closed at the partial — match the EA's InpPartialFraction
input double InpSimTrailATRMult = 1.5;          // runner trail distance, as an ATR multiple — match the EA's InpTrailATRMult
input double InpSimCommissionPerLot = 7.0;      // round-turn $ commission per 1.0 lot
input double InpSimSpreadPoints = 10.0;         // simulated spread, in points
input double InpSimSlippagePoints = 2.0;        // simulated adverse slippage per fill, in points

// --- Global objects ---
CTFContextPool     g_pool;
CObjectManager     g_objMan("Medis_");
CScoringEngine     g_scoring;
CTradeDecision     g_decision;
CRiskEngine        g_risk;
CVisuals           g_visuals;
CDashboard         g_dashboard;
CSignalLogger      g_logger;
COutcomeTracker    g_tracker;

CTFContext*        g_chartCtx = NULL;
CTFContext*        g_trendCtx = NULL;
CTFContext*        g_bosCtx = NULL;
CTFContext*        g_liqCtx = NULL;
CTFContext*        g_fvgCtx = NULL;
CTFContext*        g_htfObCtx = NULL;   // v2.8

TradeSetup         g_lastSetup;
datetime           g_lastAlertTime = 0;
datetime           g_lastLoggedTime = 0;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_pool.Configure(_Symbol, InpMaxHistoryBars, InpSwingStrength, InpFVGMinSizeATR, InpInternalLiqThresholdATR,
                    InpRVOLLookback, InpVALookbackBars, InpVANumBins, InpVAPercent / 100.0,
                    InpOBDisplacementATRMult, InpOBMinBodyRatio);

   // Requesting each timeframe through the pool: identical timeframes
   // (e.g. if you set InpBOSTF and InpLiquidityTF both to H4) collapse
   // onto ONE shared context automatically instead of computing twice.
   g_chartCtx = g_pool.Get(_Period);
   g_trendCtx = g_pool.Get(InpTrendTF);
   g_bosCtx   = g_pool.Get(InpBOSTF);
   g_liqCtx   = g_pool.Get(InpLiquidityTF);
   g_fvgCtx   = g_pool.Get(InpFVGTF);
   g_htfObCtx = g_pool.Get(InpHtfObTF);

   if(g_chartCtx == NULL || g_trendCtx == NULL || g_bosCtx == NULL || g_liqCtx == NULL || g_fvgCtx == NULL || g_htfObCtx == NULL)
     {
      Print("MedisTouch: failed to initialize one or more timeframe contexts.");
      return INIT_FAILED;
     }

   // S/R zones use the chart's own context (g_chartCtx) — that's the
   // resolution you're actually looking at and trading off of.
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
   g_decision.Init(&g_chartCtx.candles, g_fvgCtx, g_liqCtx, &g_scoring);
   g_visuals.Init(&g_objMan);
   g_logger.Init(_Symbol, InpSessionGMTOffsetOverride);
   g_tracker.Init(&g_logger, _Symbol, InpFVGTF, InpMaxTrackingBars, InpFillPolicy, InpReplayTF);
   g_tracker.ConfigureSimulation(InpSimRiskPercentPerTrade, InpSimAllowMinLotOverride,
                                 InpSimBreakEvenAtR, InpSimPartialAtR, InpSimPartialFraction, InpSimTrailATRMult,
                                 InpSimCommissionPerLot, InpSimSpreadPoints, InpSimSlippagePoints);
   g_dashboard.Init(&g_objMan, g_trendCtx, g_bosCtx, g_liqCtx, &g_scoring, &g_decision, _Symbol, &g_tracker);

   ZeroMemory(g_lastSetup);
   return INIT_SUCCEEDED;
  }
//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   g_pool.DetectAll();
   if(g_chartCtx == NULL || !g_chartCtx.candles.IsReady())
      return rates_total;

   double currentATR = g_fvgCtx.candles.GetATR(0); // same ATR basis used for SL sizing in TradeZone

   TradeSetup buySetup = g_decision.GenerateBuySetup();
   TradeSetup sellSetup = g_decision.GenerateSellSetup();

   g_lastSetup.active = false;
   if(buySetup.active && (!sellSetup.active || buySetup.confidence >= sellSetup.confidence))
     {
      if(g_risk.ValidateSetup(buySetup, InpMinRiskReward, InpMaxSLDistanceATR, currentATR))
         g_lastSetup = buySetup;
     }
   else if(sellSetup.active)
     {
      if(g_risk.ValidateSetup(sellSetup, InpMinRiskReward, InpMaxSLDistanceATR, currentATR))
         g_lastSetup = sellSetup;
     }

   if(g_lastSetup.active && g_lastSetup.creation_time != g_lastAlertTime)
     {
      if(InpAlertOnSetup)
         Alert(StringFormat("MedisTouch %s: %s setup, confidence %.0f%%",
               _Symbol, g_lastSetup.type == ORDER_TYPE_BUY ? "BUY" : "SELL", g_lastSetup.confidence));
      g_lastAlertTime = g_lastSetup.creation_time;
     }

   bool isNewSetup = (g_lastSetup.active && g_lastSetup.creation_time != g_lastLoggedTime);
   if(isNewSetup)
     {
      if(InpLogSignals)
        {
         ENUM_TREND_STATE t = g_trendCtx.trend.GetCurrentTrend();
         g_logger.LogSetup(g_lastSetup, _Symbol, InpFVGTF, EnumToString(t));
        }
      if(InpTrackOutcomes)
         g_tracker.AddSetup(g_lastSetup);
      g_lastLoggedTime = g_lastSetup.creation_time;
     }

   if(InpTrackOutcomes)
      g_tracker.Update(g_fvgCtx);

   g_visuals.ClearAll();
   g_visuals.DrawBOS(&g_bosCtx.bos, InpMaxBOSDraw);
   g_visuals.DrawCHOCH(&g_bosCtx.choch);
   if(InpShowFVGs) g_visuals.DrawFVG(&g_fvgCtx.fvg, InpMaxFVGDraw);
   if(InpShowLiquidity) g_visuals.DrawLiquidity(&g_liqCtx.liquidity, InpMaxLiquidityDraw);
   g_visuals.DrawSR(&g_chartCtx.sr, InpMaxSRDraw);

   bool   setupFilled    = false;
   double setupFillPrice = 0.0;
   datetime setupFillTime = 0;
   int    setupBarsToFill = 0;
   if(InpTrackOutcomes && g_lastSetup.active)
      g_tracker.GetFillState(g_lastSetup.creation_time, setupFilled, setupFillPrice, setupFillTime, setupBarsToFill);
   g_visuals.DrawTradeSetup(g_lastSetup, setupFilled, setupFillPrice, setupFillTime);

   if(InpShowDashboard)
      g_dashboard.Update();

   return rates_total;
  }
//+------------------------------------------------------------------+
