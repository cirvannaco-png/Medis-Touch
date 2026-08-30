//+------------------------------------------------------------------+
//|                                      Trading/OutcomeTracker.mqh   |
//+------------------------------------------------------------------+
#ifndef OUTCOMETRACKER_MQH
#define OUTCOMETRACKER_MQH

#include "../Core/Config.mqh"
#include "../Core/SignalLogger.mqh"
#include "../Analysis/TFContext.mqh"
#include "RiskEngine.mqh"
#include "CalibrationEngine.mqh"
// v2.11 — optional publisher hook so a resolved/no-fill setup can be
// POSTed to the bridge (POST /outcome) right alongside the existing
// local-CSV LogOutcome() call. Include-guarded, so it's harmless that
// the main .mq5 also includes this later for g_publisher itself.
#include "../Signals/SignalPublisher.mqh"

// SCOPE / HONEST LIMITATIONS — read before trusting the numbers this
// produces:
//  1. Tracking is fill-confirmed: a setup sits in a "pending" state from
//     generation until price actually trades to entryRef (the near edge
//     of the entry zone — entry_bottom for buys, entry_top for sells).
//     MFE/MAE and all $ simulation only start from that touch onward. If
//     price never comes back (or blows through the SL level without ever
//     touching entry), the setup resolves as Invalidated_NoFill /
//     Timeout_NoFill and contributes nothing to stats — it was never a
//     real trade.
//  2. v2.7 — THIS IS NOW A FULL TRADE SIMULATOR, not a price-level
//     outcome tracker. It reproduces CPositionManager's actual live
//     management logic bar-by-bar (Execution/PositionManager.mqh):
//     breakeven at InpBreakEvenAtR, a single partial close at
//     InpPartialAtR (InpPartialFraction of the ORIGINAL volume — not a
//     second partial at TP2; TP1/TP2 remain informational touch-flags
//     only, exactly like they are in live trading, where the broker-side
//     order is always bounded by stop_loss/final_tp and only the STOP
//     moves), then an ATR-multiple trailing stop on the runner. Position
//     sizing uses CRiskEngine.CalculateLotSize with the same entry
//     convention (entry_top for buy / entry_bottom for sell) the live EA
//     sizes against, so simulated $ figures reflect what the same inputs
//     would actually have traded. Commission, spread, and slippage are
//     applied as real transaction costs on every fill (entry, the
//     partial, and the final close), not bolted on afterward.
//  3. SAME-BAR EVENT COLLISIONS (the "conservative bias" issue): a
//     single bar can touch the stop AND a favorable trigger (final TP,
//     the breakeven trigger, or the partial trigger) in the same bar.
//     Which happened first can't be known from OHLC alone. This is
//     resolved via InpFillPolicy, generalized from v2.1's SL-vs-TP-only
//     logic to ANY adverse-level-vs-favorable-level collision:
//       FILL_CONSERVATIVE    - assume the adverse (stop) side first (old
//                               default, never overstates results)
//       FILL_OPTIMISTIC      - assume the favorable side first (for
//                               comparison only — never understates)
//       FILL_NEAREST         - whichever level the bar's open sits closer
//                               to is assumed to have been hit first
//       FILL_INTRABAR_REPLAY - steps through InpReplayTF bars inside the
//                               ambiguous bar to find the real order;
//                               falls back to Ambiguous if unavailable
//       FILL_AMBIGUOUS        - don't guess; counted separately, excluded
//                               from every win/loss/$ statistic
//  4. TRAILING STOP UPDATES ARE DEFERRED TO THE NEXT BAR, DELIBERATELY —
//     unlike the discrete R-triggers above (breakeven/partial), a
//     trailing stop recalculates continuously. Computing a tighter trail
//     from a bar's OWN favorable extreme and then checking that SAME
//     bar's OWN adverse extreme against it would silently assume the
//     best possible trail happened before any pullback within the bar —
//     a real lookahead bias, not a defensible ambiguity. So: a bar's
//     trail tightening takes effect starting the following bar. This is
//     the standard "trail updates on bar close" convention used by most
//     bar-based backtesters, stated explicitly rather than hidden.
//  5. Timeout ("Timeout" / "Timeout_NoFill") fires after InpMaxTrackingBars
//     entry-timeframe bars — a housekeeping cutoff, not a trading rule. A
//     filled trade that times out is still closed at that bar's close and
//     fully costed/counted, same as any other resolution.
//  6. Win / loss / scratch are now decided by NET REALIZED $ (after
//     commission, spread, slippage) — see OutcomeStats in Core/Config.mqh.
//     A trade whose final price-level event is "BreakEven_Hit" can still
//     be a net winner (it banked a profitable partial first); a trade
//     labeled "FinalTP_Hit" is always a winner. Read the label as "what
//     level ended it," and the $ fields as "what it actually made."
//  7. Every $ figure assumes ONE simulated position sized independently
//     per setup — it does NOT model portfolio-level exposure caps
//     (Portfolio/PortfolioManager.mqh isn't consulted here), so these
//     numbers answer "how good is the signal + management logic," not
//     "what would my account equity curve have looked like." Feeding
//     PortfolioManager into this simulator is a reasonable next step, not
//     something this file claims to already do.
// PendingSetup is defined in Core/Config.mqh (needs to be a complete
// type in SignalLogger.mqh too, for LogOutcome's signature).
class COutcomeTracker
  {
private:
   PendingSetup      m_pending[];
   int               m_count;
   int               m_maxBars;
   CSignalLogger*    m_logger;
   string            m_symbol;
   ENUM_TIMEFRAMES   m_entryTF;
   ENUM_FILL_POLICY  m_fillPolicy;
   ENUM_TIMEFRAMES   m_replayTF;
   OutcomeStats      m_stats;

   // --- v2.7 simulation configuration ---
   CRiskEngine       m_risk;
   double            m_riskPercent;          // matches InpRiskPercentPerTrade
   bool              m_allowMinLotOverride;  // simulator default: true (see ConfigureSimulation)
   double            m_breakEvenAtR;         // matches InpBreakEvenAtR
   double            m_partialAtR;           // matches InpPartialAtR
   double            m_partialFraction;      // matches InpPartialFraction
   double            m_trailAtrMult;         // matches InpTrailATRMult
   double            m_commissionPerLot;     // round-turn $ per 1.0 lot
   double            m_spreadPoints;         // simulated spread, in points
   double            m_slippagePoints;       // simulated adverse slippage per fill, in points

   // v2.9: feeds every resolved trade's (confidence, netPnL) into the
   // calibration bucket engine — see CalibrationEngine.mqh for scope/limits.
   CCalibrationEngine m_calibration;
   bool              m_calibrationEnabled;
   // v2.10 - DIAGNOSTIC-ONLY confidence decay. Half-life in unfilled bars;
   // <= 0 disables decay (confidenceDecayed stays == confidenceAtSignal).
   double            m_decayHalfLifeBars;
   // v2.11 — optional bridge publishing. NULL publisher = fully
   // backward compatible no-op (see ConfigurePublishing).
   CSignalPublisher* m_publisher;
   string            m_weightVersion;

   void              RemoveAt(int idx);
   // Pre-fill resolutions only (Invalidated_NoFill / Timeout_NoFill) —
   // never a real trade, so no $ accounting applies. Post-fill
   // resolutions go through FinalizeExit() instead.
   void              Resolve(int idx, string outcome, double exitPrice);

   double            PointSize() const;
   double            ValuePerUnitDistance() const;
   double            ApplyEntryCosts(double rawPrice, bool isBuy) const;
   double            ApplyExitCosts(double rawPrice, bool isBuy) const;
   string            SLHitLabel(const PendingSetup &p) const;

   // Closes `closeLots` of p's position at rawExitPrice (cost-adjusted
   // internally), updating p's running $ fields and remainingLots.
   void              CloseSlice(PendingSetup &p, double closeLots, double rawExitPrice, bool isBuy);
   void              ApplyPartial(PendingSetup &p, double triggerPrice, bool isBuy);

   // Which of two price levels was touched first within bar0, per
   // m_fillPolicy. adverseLevel is always the stop-side level (below
   // price for a buy, above for a sell); favorableLevel is always a
   // target/trigger level (above for a buy, below for a sell). Only
   // meaningful — and only called — when the caller has already
   // confirmed BOTH levels were touched this bar.
   bool              ResolveOrder(bool isBuy, CandleData &bar0, double adverseLevel, double favorableLevel, bool &ambiguous);
   bool              IntrabarReplayGeneric(bool isBuy, CandleData &bar0, double adverseLevel, double favorableLevel, bool &favorableFirst);
   // Full-close collision between the current stop and the final TP —
   // thin wrapper over ResolveOrder producing the outcome label/price.
   string            ResolveCollision(bool isBuy, CandleData &bar0, double adverseLevel, double favorableLevel,
                                      double &outExitPrice, bool &ambiguous);

   // Post-fill bar processing: the breakeven -> partial -> trailing
   // cascade described in the file header. May resolve (and remove) the
   // trade; if not, leaves it pending for the next bar.
   void              ProcessFilledBar(int idx, CandleData &bar0);
   // v2.10. Recomputes p.confidenceDecayed from p.decayBars. Pure
   // bookkeeping: no caller reads the result to cancel, re-rank or re-size
   // anything - see the PendingSetup v2.10 block in Config.mqh.
   void              ApplyDecay(PendingSetup &p) const;
   // v2.11. Shared by FinalizeExit() and Resolve() — no-ops silently if
   // m_publisher is NULL (publishing not configured) or p.decisionId < 0
   // (this setup was never routed through a decision, so there is no
   // valid signal_id to attach an outcome to — see Config.mqh
   // PendingSetup.decisionId). `coarseOutcome` is the already-normalized
   // "win"/"loss"/"scratch"/"no_fill"/"ambiguous" label — callers compute
   // this, not this function, so the win/loss/scratch epsilon logic lives
   // in exactly one place (FinalizeExit's existing m_stats classification).
   void              PublishIfConfigured(const PendingSetup &p, string coarseOutcome, bool ambiguous);
   // Closes the trade's remaining lots (if any), logs it, updates
   // m_stats, and removes it from the pending array.
   void              FinalizeExit(int idx, PendingSetup &p, string outcome, double rawExitPrice,
                                  bool sameBarCollision, bool ambiguous);

public:
                     COutcomeTracker();
   void              Init(CSignalLogger* logger, string symbol, ENUM_TIMEFRAMES entryTF, int maxBars,
                          ENUM_FILL_POLICY fillPolicy = FILL_CONSERVATIVE, ENUM_TIMEFRAMES replayTF = PERIOD_M1);
   // v2.7 — separated from Init() so the fill-policy/tracking-window
   // config and the simulation-economics config can each default
   // independently. Call once, right after Init(). Pass the SAME
   // InpBreakEvenAtR/InpPartialAtR/InpPartialFraction/InpTrailATRMult/
   // InpRiskPercentPerTrade values driving CPositionManager /
   // CRiskEngine live, so simulated results actually predict live
   // behavior instead of quietly drifting from it.
   void              ConfigureSimulation(double riskPercent, bool allowMinLotOverride,
                                         double breakEvenAtR, double partialAtR, double partialFraction,
                                         double trailAtrMult, double commissionPerLot,
                                         double spreadPoints, double slippagePoints);
   void              AddSetup(TradeSetup &setup, long decisionId = -1);
   void              Update(CTFContext* fvgCtx);
   int               ActiveCount() const { return m_count; }
   OutcomeStats      GetStats() const { return m_stats; }
   bool              GetFillState(datetime creation_time, bool &filled, double &fillPrice, datetime &fillTime, int &barsToFill);
   // v2.9. Call once after Init(), same pattern as ConfigureSimulation().
   // OFF by default — calibration data is only meaningful once you've
   // deliberately decided to start collecting it (see CalibrationEngine.mqh
   // limitation #4 re: resetting after scoring-formula changes).
   // v2.10. Half-life, in unfilled bars, of the diagnostic confidence
   // decay. 12 bars is the spec's starting point, not a fitted value.
   void              ConfigureConfidenceDecay(double halfLifeBars = 12.0) { m_decayHalfLifeBars = halfLifeBars; }
   void              ConfigureCalibration(bool enabled, int minSample = 30) { m_calibrationEnabled = enabled; m_calibration.Init(m_symbol, minSample); }
   // v2.11. OFF by default (NULL publisher) — call once after Init(),
   // same pattern as ConfigureSimulation/ConfigureCalibration. When set,
   // FinalizeExit() and Resolve() push every outcome to the bridge in
   // addition to the existing local-CSV LogOutcome() call.
   void              ConfigurePublishing(CSignalPublisher* publisher, string weightVersion)
     { m_publisher = publisher; m_weightVersion = weightVersion; }
   double            GetCalibratedProbability(double confidence, int &sampleSizeOut, bool &hasEnoughDataOut) const
     { return m_calibration.GetCalibratedProbability(confidence, sampleSizeOut, hasEnoughDataOut); }
   const CCalibrationEngine* CalibrationEngine() const { return GetPointer(m_calibration); }
  };
//+------------------------------------------------------------------+
COutcomeTracker::COutcomeTracker() : m_count(0), m_maxBars(100), m_logger(NULL),
                                      m_fillPolicy(FILL_CONSERVATIVE), m_replayTF(PERIOD_M1),
                                      m_riskPercent(0.5), m_allowMinLotOverride(true),
                                      m_breakEvenAtR(1.0), m_partialAtR(2.0), m_partialFraction(0.5),
                                      m_trailAtrMult(1.5), m_commissionPerLot(7.0),
                                      m_spreadPoints(10.0), m_slippagePoints(2.0), m_calibrationEnabled(false),
                                      m_decayHalfLifeBars(12.0), m_publisher(NULL), m_weightVersion("")
  {
   ZeroMemory(m_stats);
  }
//+------------------------------------------------------------------+
void COutcomeTracker::Init(CSignalLogger* logger, string symbol, ENUM_TIMEFRAMES entryTF, int maxBars,
                           ENUM_FILL_POLICY fillPolicy, ENUM_TIMEFRAMES replayTF)
  {
   m_logger = logger;
   m_symbol = symbol;
   m_entryTF = entryTF;
   m_maxBars = MathMax(5, maxBars);
   m_fillPolicy = fillPolicy;
   m_replayTF = replayTF;
   m_count = 0;
   ZeroMemory(m_stats);
   ArrayFree(m_pending);
  }
//+------------------------------------------------------------------+
void COutcomeTracker::ConfigureSimulation(double riskPercent, bool allowMinLotOverride,
                                          double breakEvenAtR, double partialAtR, double partialFraction,
                                          double trailAtrMult, double commissionPerLot,
                                          double spreadPoints, double slippagePoints)
  {
   m_riskPercent = (riskPercent > 0) ? riskPercent : 0.5;
   m_allowMinLotOverride = allowMinLotOverride;
   m_breakEvenAtR = breakEvenAtR;
   m_partialAtR = partialAtR;
   m_partialFraction = MathMax(0.0, MathMin(1.0, partialFraction));
   m_trailAtrMult = trailAtrMult;
   m_commissionPerLot = MathMax(0.0, commissionPerLot);
   m_spreadPoints = MathMax(0.0, spreadPoints);
   m_slippagePoints = MathMax(0.0, slippagePoints);
  }
//+------------------------------------------------------------------+
double COutcomeTracker::PointSize() const
  {
   return SymbolInfoDouble(m_symbol, SYMBOL_POINT);
  }
//+------------------------------------------------------------------+
double COutcomeTracker::ValuePerUnitDistance() const
  {
   double tickSize = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return 0.0;
   return tickValue / tickSize;
  }
//+------------------------------------------------------------------+
// Opening a buy = buying = the adverse fill is a HIGHER price (you pay
// the ask, plus slippage). Opening a sell = selling = adverse is LOWER.
double COutcomeTracker::ApplyEntryCosts(double rawPrice, bool isBuy) const
  {
   double costPoints = (m_spreadPoints / 2.0 + m_slippagePoints) * PointSize();
   return isBuy ? rawPrice + costPoints : rawPrice - costPoints;
  }
//+------------------------------------------------------------------+
// Closing a buy = selling = adverse is LOWER. Closing a sell = buying =
// adverse is HIGHER. Applied identically to the partial close and the
// final close — both are real fills that cross the spread and can slip.
double COutcomeTracker::ApplyExitCosts(double rawPrice, bool isBuy) const
  {
   double costPoints = (m_spreadPoints / 2.0 + m_slippagePoints) * PointSize();
   return isBuy ? rawPrice - costPoints : rawPrice + costPoints;
  }
//+------------------------------------------------------------------+
string COutcomeTracker::SLHitLabel(const PendingSetup &p) const
  {
   if(!p.beDone) return "SL_Hit";
   if(!p.partialDone) return "BreakEven_Hit";
   return "Trail_Hit";
  }
//+------------------------------------------------------------------+
void COutcomeTracker::CloseSlice(PendingSetup &p, double closeLots, double rawExitPrice, bool isBuy)
  {
   if(closeLots <= 0 || p.lots <= 0) return;
   double exitPrice = ApplyExitCosts(rawExitPrice, isBuy);
   double valuePerUnit = ValuePerUnitDistance();
   double direction = isBuy ? 1.0 : -1.0;
   double grossPnL = direction * (exitPrice - p.entryFillPrice) * closeLots * valuePerUnit;
   double commission = m_commissionPerLot * closeLots;

   p.realizedPnL += (grossPnL - commission);
   p.totalCommission += commission;
   p.totalSpreadCost += (m_spreadPoints / 2.0) * PointSize() * closeLots * valuePerUnit;
   p.totalSlippageCost += m_slippagePoints * PointSize() * closeLots * valuePerUnit;
   p.remainingLots -= closeLots;
   if(p.remainingLots < 0) p.remainingLots = 0;
  }
//+------------------------------------------------------------------+
void COutcomeTracker::ApplyPartial(PendingSetup &p, double triggerPrice, bool isBuy)
  {
   if(p.lots > 0)
     {
      double closeLots = p.lots * m_partialFraction;
      CloseSlice(p, closeLots, triggerPrice, isBuy);
     }
   p.partialDone = true;
  }
//+------------------------------------------------------------------+
bool COutcomeTracker::IntrabarReplayGeneric(bool isBuy, CandleData &bar0, double adverseLevel, double favorableLevel, bool &favorableFirst)
  {
   // NOTE: ENUM_TIMEFRAMES values are bit-encoded, NOT a simple ordering
   // by duration — comparing them directly with >=/<= is a classic MQL5
   // bug. PeriodSeconds() gives the actual bar duration.
   int replaySecs = PeriodSeconds(m_replayTF);
   int entrySecs  = PeriodSeconds(m_entryTF);
   if(replaySecs <= 0 || entrySecs <= 0 || replaySecs >= entrySecs) return false;
   datetime barEnd = bar0.time + entrySecs;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(m_symbol, m_replayTF, bar0.time, barEnd - 1, rates);
   if(copied <= 0) return false;
   for(int i = copied - 1; i >= 0; i--) // oldest-to-newest, real chronological order
     {
      bool adverseHere = isBuy ? (rates[i].low <= adverseLevel) : (rates[i].high >= adverseLevel);
      bool favorableHere = isBuy ? (rates[i].high >= favorableLevel) : (rates[i].low <= favorableLevel);
      if(adverseHere && !favorableHere) { favorableFirst = false; return true; }
      if(favorableHere && !adverseHere) { favorableFirst = true;  return true; }
      if(adverseHere && favorableHere)  { favorableFirst = false; return true; } // gap-through even the replay bar — conservative within the replay itself
     }
   return false; // replay never actually confirmed either level
  }
//+------------------------------------------------------------------+
bool COutcomeTracker::ResolveOrder(bool isBuy, CandleData &bar0, double adverseLevel, double favorableLevel, bool &ambiguous)
  {
   ambiguous = false;
   switch(m_fillPolicy)
     {
      case FILL_OPTIMISTIC:
         return true;

      case FILL_NEAREST:
        {
         double distAdverse = MathAbs(bar0.open - adverseLevel);
         double distFavorable = MathAbs(bar0.open - favorableLevel);
         return (distFavorable < distAdverse);
        }

      case FILL_INTRABAR_REPLAY:
        {
         bool favorableFirst;
         if(IntrabarReplayGeneric(isBuy, bar0, adverseLevel, favorableLevel, favorableFirst))
            return favorableFirst;
         ambiguous = true;
         return false;
        }

      case FILL_AMBIGUOUS:
         ambiguous = true;
         return false;

      case FILL_CONSERVATIVE:
      default:
         return false;
     }
  }
//+------------------------------------------------------------------+
string COutcomeTracker::ResolveCollision(bool isBuy, CandleData &bar0, double adverseLevel, double favorableLevel,
                                         double &outExitPrice, bool &ambiguous)
  {
   bool favorableFirst = ResolveOrder(isBuy, bar0, adverseLevel, favorableLevel, ambiguous);
   if(ambiguous) { outExitPrice = bar0.close; return "Ambiguous_SLandTP"; }
   if(favorableFirst) { outExitPrice = favorableLevel; return "FinalTP_Hit"; }
   outExitPrice = adverseLevel; return "SL_Hit";
  }
//+------------------------------------------------------------------+
void COutcomeTracker::FinalizeExit(int idx, PendingSetup &p, string outcome, double rawExitPrice,
                                   bool sameBarCollision, bool ambiguous)
  {
   bool isBuy = (p.setup.type == ORDER_TYPE_BUY);
   if(p.remainingLots > 0)
      CloseSlice(p, p.remainingLots, rawExitPrice, isBuy); // ambiguous or not, bar0.close/the level itself is a real known price — only the LABEL stays ambiguous
   p.sameBarCollision = sameBarCollision;

   if(p.lots > 0)
     {
      if(ambiguous)
         m_stats.ambiguous++;
      else
        {
         if(p.realizedPnL > 0.0000001)      m_stats.wins++;
         else if(p.realizedPnL < -0.0000001) m_stats.losses++;
         else                                m_stats.scratches++;
         m_stats.resolvedCount++;
         m_stats.netPnL += p.realizedPnL;
         if(p.realizedPnL > 0) m_stats.grossProfit += p.realizedPnL;
         else                  m_stats.grossLoss += (-p.realizedPnL);
         m_stats.totalCommission += p.totalCommission;
         m_stats.totalSpreadCost += p.totalSpreadCost;
         m_stats.totalSlippageCost += p.totalSlippageCost;

         double oneRDollar = p.mgmtRiskDist * ValuePerUnitDistance() * p.lots;
         if(oneRDollar > 0) m_stats.sumRMultiple += p.realizedPnL / oneRDollar;

         // v2.9: feed this resolved, sized, non-ambiguous trade into the
         // calibration engine. p.setup.confidence is the RAW score at
         // signal time — see CalibrationEngine.mqh limitation #4 about
         // what happens to this data across a scoring-formula change.
         if(m_calibrationEnabled)
            m_calibration.Record(p.setup.confidence, p.realizedPnL);
        }
     }

   m_pending[idx] = p;
   if(m_logger != NULL)
      m_logger.LogOutcome(m_pending[idx], m_symbol, m_entryTF, outcome, rawExitPrice, m_fillPolicy);
   // v2.11 — same classification epsilons as the m_stats block above,
   // kept in exactly one place logically (this block feeds both); lots<=0
   // mirrors the doc comment at the top of this file: "excluded from
   // every $ stat" because sizing was impossible, so it's reported as
   // scratch (no informative PnL) rather than a fabricated win/loss.
   string coarseOutcome;
   if(ambiguous)                              coarseOutcome = "ambiguous";
   else if(p.lots <= 0)                       coarseOutcome = "scratch";
   else if(p.realizedPnL > 0.0000001)         coarseOutcome = "win";
   else if(p.realizedPnL < -0.0000001)        coarseOutcome = "loss";
   else                                        coarseOutcome = "scratch";
   PublishIfConfigured(m_pending[idx], coarseOutcome, ambiguous);
   RemoveAt(idx);
  }
void COutcomeTracker::PublishIfConfigured(const PendingSetup &p, string coarseOutcome, bool ambiguous)
  {
   if(m_publisher == NULL) return;
   if(p.decisionId < 0) return; // no decision was ever minted for this setup — no valid signal_id to attach to

   bool isBuy = (p.setup.type == ORDER_TYPE_BUY);
   double realizedR = 0.0, mfeR = 0.0, maeR = 0.0;
   if(coarseOutcome != "no_fill" && coarseOutcome != "ambiguous" && p.mgmtRiskDist > 0)
     {
      double oneRDollar = p.mgmtRiskDist * ValuePerUnitDistance() * p.lots;
      if(oneRDollar > 0) realizedR = p.realizedPnL / oneRDollar;
      mfeR = isBuy ? (p.mfePrice - p.sizingEntryPrice) / p.mgmtRiskDist
                   : (p.sizingEntryPrice - p.mfePrice) / p.mgmtRiskDist;
      maeR = isBuy ? (p.sizingEntryPrice - p.maePrice) / p.mgmtRiskDist
                   : (p.maePrice - p.sizingEntryPrice) / p.mgmtRiskDist;
     }

   string signalId = m_publisher.SignalIdForDecision(p.decisionId);
   string direction = isBuy ? "BUY" : "SELL";
   SetupReasons r = p.setup.reasons;

   m_publisher.PublishOutcome(signalId, m_symbol, direction, coarseOutcome, realizedR, mfeR, maeR,
                              p.barsElapsed, p.barsToFill, p.filled,
                              EnumToString(r.vol_regime), EnumToString(r.session), EnumToString(r.sweep_grade),
                              r.htf_ob_confluence, p.confidenceAtSignal, p.confidenceDecayed, p.decayBars);
  }
//+------------------------------------------------------------------+
  {
   PendingSetup p;
   ZeroMemory(p);
   p.setup = setup;
   p.decisionId = decisionId; // -1 unless the caller passed the real one post-Decide() — see Config.mqh
   bool isBuy = (setup.type == ORDER_TYPE_BUY);
   p.entryRef = isBuy ? setup.entry_bottom : setup.entry_top;
   p.riskDist = MathAbs(p.entryRef - setup.stop_loss);
   p.mfePrice = p.entryRef;
   p.maePrice = p.entryRef;
   p.tp1Hit = false;
   p.tp2Hit = false;
   p.barsElapsed = 0;
   p.lastBarTime = 0; // set on first Update() call
   p.filled = false;
   p.fillTime = 0;
   p.barsToFill = 0;
   p.sameBarCollision = false;
   p.confidenceAtSignal = setup.confidence;
   p.confidenceDecayed = setup.confidence;
   p.decayBars = 0;

   // --- v2.7: sizing at signal time, matching the live EA exactly (it
   // sizes and submits at decision time too — a pending order's volume
   // doesn't get re-evaluated when it eventually fills bars later). ---
   p.sizingEntryPrice = isBuy ? setup.entry_top : setup.entry_bottom;
   p.mgmtRiskDist = MathAbs(p.sizingEntryPrice - setup.stop_loss);
   bool exceededBudget = false;
   p.lots = (p.mgmtRiskDist > 0)
            ? m_risk.CalculateLotSize(m_symbol, m_riskPercent, p.sizingEntryPrice, setup.stop_loss,
                                      false, m_allowMinLotOverride, exceededBudget)
            : 0.0;
   p.currentSL = setup.stop_loss;
   p.beDone = false;
   p.partialDone = false;
   p.remainingLots = p.lots;
   p.entryFillPrice = 0.0;
   p.realizedPnL = 0.0;
   p.totalCommission = 0.0;
   p.totalSpreadCost = 0.0;
   p.totalSlippageCost = 0.0;

   int n = m_count++;
   ArrayResize(m_pending, m_count);
   m_pending[n] = p;
  }
//+------------------------------------------------------------------+
void COutcomeTracker::RemoveAt(int idx)
  {
   for(int i = idx; i < m_count - 1; i++)
      m_pending[i] = m_pending[i + 1];
   m_count--;
   ArrayResize(m_pending, m_count);
  }
//+------------------------------------------------------------------+
void COutcomeTracker::Resolve(int idx, string outcome, double exitPrice)
  {
   if(m_logger != NULL)
      m_logger.LogOutcome(m_pending[idx], m_symbol, m_entryTF, outcome, exitPrice, m_fillPolicy);
   // v2.11 — Resolve() is exclusively the pre-fill NoFill path (see class
   // header point 1); always "no_fill" regardless of the specific label
   // (Invalidated_NoFill/Timeout_NoFill) passed in, since neither
   // contributes anything the outcome schema's win/loss/scratch/no_fill/
   // ambiguous set needs to distinguish further.
   PublishIfConfigured(m_pending[idx], "no_fill", false);
   RemoveAt(idx);
  }
//+------------------------------------------------------------------+
// The breakeven -> partial -> trailing cascade. See the file header for
// the full reasoning; this loop can advance more than one stage within a
// single bar (a big enough bar can plausibly cross breakeven AND the
// partial trigger AND still get stopped, all in one candle) but is
// bounded so a malformed state can never spin forever.
void COutcomeTracker::ProcessFilledBar(int idx, CandleData &bar0)
  {
   PendingSetup p = m_pending[idx];
   bool isBuy = (p.setup.type == ORDER_TYPE_BUY);
   double finalTP = p.setup.final_tp;

   int guard = 0;
   while(guard++ < 6)
     {
      double adverseLevel = p.currentSL;
      bool adverseTouched = isBuy ? (bar0.low <= adverseLevel) : (bar0.high >= adverseLevel);
      bool tpTouched = isBuy ? (bar0.high >= finalTP) : (bar0.low <= finalTP);

      // 1. Final TP vs the current stop — a full close either way,
      // highest priority regardless of what stage we're in.
      if(adverseTouched && tpTouched)
        {
         double exitPrice; bool ambiguous;
         string outcome = ResolveCollision(isBuy, bar0, adverseLevel, finalTP, exitPrice, ambiguous);
         if(outcome == "SL_Hit") outcome = SLHitLabel(p);
         FinalizeExit(idx, p, outcome, exitPrice, true, ambiguous);
         return;
        }
      if(tpTouched)
        {
         FinalizeExit(idx, p, "FinalTP_Hit", finalTP, false, false);
         return;
        }

      // 2a. Breakeven stage.
      if(!p.beDone)
        {
         double beTrigger = isBuy ? p.sizingEntryPrice + m_breakEvenAtR * p.mgmtRiskDist
                                   : p.sizingEntryPrice - m_breakEvenAtR * p.mgmtRiskDist;
         bool beTouched = isBuy ? (bar0.high >= beTrigger) : (bar0.low <= beTrigger);

         if(adverseTouched && beTouched)
           {
            bool ambiguous;
            bool favorableFirst = ResolveOrder(isBuy, bar0, adverseLevel, beTrigger, ambiguous);
            if(ambiguous) { FinalizeExit(idx, p, "Ambiguous_SLandBE", bar0.close, true, true); return; }
            if(!favorableFirst) { FinalizeExit(idx, p, SLHitLabel(p), adverseLevel, false, false); return; }
            p.currentSL = p.sizingEntryPrice;
            p.beDone = true;
            m_pending[idx] = p;
            continue; // keep cascading — this same bar might reach further
           }
         if(adverseTouched) { FinalizeExit(idx, p, SLHitLabel(p), adverseLevel, false, false); return; }
         if(beTouched)
           {
            p.currentSL = p.sizingEntryPrice;
            p.beDone = true;
            m_pending[idx] = p;
            continue;
           }
         break; // nothing happened this bar
        }

      // 2b. Partial stage (only reachable once breakeven is done, same
      // order CPositionManager enforces).
      if(!p.partialDone)
        {
         double partialTrigger = isBuy ? p.sizingEntryPrice + m_partialAtR * p.mgmtRiskDist
                                        : p.sizingEntryPrice - m_partialAtR * p.mgmtRiskDist;
         bool partialTouched = isBuy ? (bar0.high >= partialTrigger) : (bar0.low <= partialTrigger);

         if(adverseTouched && partialTouched)
           {
            bool ambiguous;
            bool favorableFirst = ResolveOrder(isBuy, bar0, adverseLevel, partialTrigger, ambiguous);
            if(ambiguous) { FinalizeExit(idx, p, "Ambiguous_SLandPartial", bar0.close, true, true); return; }
            if(!favorableFirst) { FinalizeExit(idx, p, SLHitLabel(p), adverseLevel, false, false); return; }
            ApplyPartial(p, partialTrigger, isBuy);
            m_pending[idx] = p;
            continue;
           }
         if(adverseTouched) { FinalizeExit(idx, p, SLHitLabel(p), adverseLevel, false, false); return; }
         if(partialTouched)
           {
            ApplyPartial(p, partialTrigger, isBuy);
            m_pending[idx] = p;
            continue;
           }
         break;
        }

      // 3. Pure runner — the stop only trails (never widens). A hit on
      // the CURRENT stop (set going into this bar) still ends the trade;
      // any tightening computed from THIS bar's own favorable extreme is
      // deferred to the next bar (see file header, point 4).
      if(adverseTouched) { FinalizeExit(idx, p, SLHitLabel(p), adverseLevel, false, false); return; }

      if(bar0.atr > 0)
        {
         double favPrice = isBuy ? bar0.high : bar0.low;
         double newTrail = isBuy ? favPrice - m_trailAtrMult * bar0.atr : favPrice + m_trailAtrMult * bar0.atr;
         bool improved = isBuy ? (newTrail > p.currentSL) : (newTrail < p.currentSL);
         if(improved) p.currentSL = newTrail;
        }
      break;
     }

   if(p.barsElapsed >= m_maxBars)
     {
      FinalizeExit(idx, p, "Timeout", bar0.close, false, false);
      return;
     }
   m_pending[idx] = p;
  }
//+------------------------------------------------------------------+
void COutcomeTracker::ApplyDecay(PendingSetup &p) const
  {
   if(m_decayHalfLifeBars <= 0.0 || p.decayBars <= 0)
     {
      p.confidenceDecayed = p.confidenceAtSignal;
      return;
     }
   double factor = MathPow(0.5, (double)p.decayBars / m_decayHalfLifeBars);
   p.confidenceDecayed = p.confidenceAtSignal * factor;
  }
//+------------------------------------------------------------------+
void COutcomeTracker::Update(CTFContext* fvgCtx)
  {
   if(fvgCtx == NULL || fvgCtx.candles.Total() == 0) return;
   CandleData bar0 = fvgCtx.candles.GetCandle(0);

   for(int i = m_count - 1; i >= 0; i--)
     {
      PendingSetup p = m_pending[i];
      bool isBuy = (p.setup.type == ORDER_TYPE_BUY);

      if(p.lastBarTime == 0)
         p.lastBarTime = bar0.time;
      else if(bar0.time != p.lastBarTime)
        {
         p.barsElapsed++;
         p.lastBarTime = bar0.time;
         // v2.10: only UNFILLED bars decay. Once price has traded the
         // zone, the evidence was either right or wrong on its own terms;
         // staleness stops being the question.
         if(!p.filled)
           {
            p.decayBars++;
            ApplyDecay(p);
           }
        }
      m_pending[i] = p;

      // --- Fill confirmation gate ---
      if(!p.filled)
        {
         bool touchedEntry = isBuy ? (bar0.low <= p.entryRef) : (bar0.high >= p.entryRef);
         if(touchedEntry)
           {
            p.filled = true;
            p.fillTime = bar0.time;
            p.barsToFill = p.barsElapsed;
            p.mfePrice = p.entryRef;
            p.maePrice = p.entryRef;
            p.currentSL = p.setup.stop_loss;
            p.remainingLots = p.lots;
            if(p.lots > 0)
              {
               p.entryFillPrice = ApplyEntryCosts(p.sizingEntryPrice, isBuy);
               double valuePerUnit = ValuePerUnitDistance();
               p.totalSpreadCost = (m_spreadPoints / 2.0) * PointSize() * p.lots * valuePerUnit;
               p.totalSlippageCost = m_slippagePoints * PointSize() * p.lots * valuePerUnit;
              }
            m_pending[i] = p;
           }
         else
           {
            bool invalidated = isBuy ? (bar0.low <= p.setup.stop_loss) : (bar0.high >= p.setup.stop_loss);
            if(invalidated)
              {
               Resolve(i, "Invalidated_NoFill", bar0.close);
               continue;
              }
            if(p.barsElapsed >= m_maxBars)
              {
               Resolve(i, "Timeout_NoFill", bar0.close);
               continue;
              }
            continue;
           }
        }

      // Update MFE/MAE using this bar's full range (unchanged from v2.1 —
      // still measured against the original entryRef/riskDist, independent
      // of where the simulated stop has since moved to).
      if(isBuy)
        {
         if(bar0.high > p.mfePrice) p.mfePrice = bar0.high;
         if(bar0.low  < p.maePrice) p.maePrice = bar0.low;
        }
      else
        {
         if(bar0.low  < p.mfePrice) p.mfePrice = bar0.low;
         if(bar0.high > p.maePrice) p.maePrice = bar0.high;
        }
      m_pending[i] = p;

      // TP1/TP2 stay informational touch-flags only — see file header
      // point 2 on why they don't drive any $ event.
      if(isBuy)
        {
         if(!p.tp1Hit && bar0.high >= p.setup.tp1) m_pending[i].tp1Hit = true;
         if(!p.tp2Hit && bar0.high >= p.setup.tp2) m_pending[i].tp2Hit = true;
        }
      else
        {
         if(!p.tp1Hit && bar0.low <= p.setup.tp1) m_pending[i].tp1Hit = true;
         if(!p.tp2Hit && bar0.low <= p.setup.tp2) m_pending[i].tp2Hit = true;
        }

      ProcessFilledBar(i, bar0); // may resolve and remove index i
     }
  }
//+------------------------------------------------------------------+
bool COutcomeTracker::GetFillState(datetime creation_time, bool &filled, double &fillPrice, datetime &fillTime, int &barsToFill)
  {
   for(int i = 0; i < m_count; i++)
     {
      if(m_pending[i].setup.creation_time != creation_time) continue;
      filled     = m_pending[i].filled;
      fillPrice  = m_pending[i].entryRef;
      fillTime   = m_pending[i].fillTime;
      barsToFill = m_pending[i].barsToFill;
      return true;
     }
   return false;
  }
#endif
//+------------------------------------------------------------------+
