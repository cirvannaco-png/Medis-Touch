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
input double InpSLBufferATR = 0.25;        // invalidation margin beyond FVG far edge, in ATR (audit #23 fix)
input double InpMinStopSpreadMult = 3.0;   // floor: SL distance from entry never below (current spread * this) -- check against real Pepperstone/Exness spread in Tester

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

input group "Logging"
input bool   InpLogSignals = true;
input bool   InpTrackOutcomes = true;
input int    InpMaxTrackingBars = 100;
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
CProductionMonitor g_monitor;

datetime           g_lastLoggedTime = 0;
datetime           g_lastBarTime = 0;

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
   g_decision.Init(&g_chartCtx.candles, g_fvgCtx, g_liqCtx, &g_scoring, InpSLBufferATR, InpMinStopSpreadMult);
   g_logger.Init(_Symbol, InpSessionGMTOffsetOverride);
   g_tracker.Init(&g_logger, _Symbol, InpFVGTF, InpMaxTrackingBars, InpFillPolicy, InpReplayTF);
   // Deliberately the SAME values driving g_positions/g_risk below — so the
   // simulator's numbers actually predict what this EA, configured exactly
   // like this, would do.
   g_tracker.ConfigureSimulation(InpRiskPercentPerTrade, InpAllowMinLotOverride,
                                 InpBreakEvenAtR, InpPartialAtR, InpPartialFraction, InpTrailATRMult,
                                 InpSimCommissionPerLot, InpSimSpreadPoints, InpSimSlippagePoints);

   g_router.Init(_Symbol, InpEnableExecution, InpEnableSignals,
                InpMinConfidenceExecute, InpMinConfidenceSignal, InpFullRiskConfidence, InpMaxSpreadPoints);
   g_broker.Init(InpMagicNumber);
   g_monitor.Init(_Symbol, InpHeartbeatIntervalSec, InpMaxDrawdownAlertPercent);
   g_orders.Init(&g_broker, InpMaxOpenTrades, &g_monitor);
   g_positions.Init(&g_orders, &g_broker, InpBreakEvenAtR, InpPartialAtR, InpPartialFraction, InpTrailATRMult);

   g_store.Init(_Symbol);
   g_subscribers.Init();
   g_publisher.Init(_Symbol, &g_subscribers, InpWebRequestTimeoutMs);
   g_portfolio.Init(InpMaxPortfolioRiskPercent, InpMaxPositionsPerSymbol, InpMaxPositionsPerGroup, InpMagicNumber, &g_risk);
   g_riskGuard.Init(_Symbol, InpMaxDailyLossPercent, InpMaxDrawdownPercent, InpDeriskStartPercent, InpDeriskFloor);
   if(InpUseNewsFilter)
      g_newsFilter.Load(InpNewsFilterFile, InpNewsMinutesBefore, InpNewsMinutesAfter);

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
   g_publisher.Deinit();
   g_subscribers.Deinit();
   g_store.Deinit();
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

   TradeSetup chosen;
   ZeroMemory(chosen);
   if(buySetup.active && (!sellSetup.active || buySetup.confidence >= sellSetup.confidence))
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

   if(InpLogSignals)
     {
      ENUM_TREND_STATE t = g_trendCtx.trend.GetCurrentTrend();
      g_logger.LogSetup(chosen, _Symbol, InpFVGTF, EnumToString(t));
     }
   if(InpTrackOutcomes)
      g_tracker.AddSetup(chosen);
   g_tracker.Update(g_fvgCtx);

   // --- This is the seam the audit found missing: analysis -> decision -> action ---
   TradeDecisionRecord decision = g_router.Decide(chosen);
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
      g_publisher.Publish(decision);
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
